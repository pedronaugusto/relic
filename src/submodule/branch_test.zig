//! `branch --recurse-submodules` held to git 2.55's: the superproject of
//! `move_test` built twice by git with its dates fixed, `git branch` with
//! the flag in one and `createBranches` in the other, and what each
//! refused and left compared -- in the superproject and every submodule,
//! the branches, what their logs say, and their tracking settings.

const std = @import("std");
const testgit = @import("../testing/git.zig");
const move_test = @import("move_test.zig");
const repo_mod = @import("../repo/repo.zig");
const object = @import("../object/object.zig");
const config_mod = @import("../config/config.zig");
const branch = @import("../commit/branch.zig");
const submodule = @import("submodule.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

const Prepare = enum { none, taken, inactive, autosetup_always };

const Case = struct { args: []const []const u8, start: []const u8 = "one", track: ?branch.Track = null, force: bool = false, prepare: Prepare = .none };

fn prepare(repo: *testgit.Repo, what: Prepare) !void {
    switch (what) {
        .none => {},
        .taken => try repo.exec(io, &.{ "-C", "sub/inner", "branch", "topic" }),
        .inactive => try repo.exec(io, &.{ "-C", "sub", "config", "submodule.inner.active", "false" }),
        .autosetup_always => try repo.exec(io, &.{ "-C", "sub", "config", "branch.autoSetupMerge", "always" }),
    }
}

/// Each repository's branches, what their logs say, and `branch.*`.
fn state(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    repo.report_failures = false;
    defer repo.report_failures = true;
    for ([_][]const u8{ ".", "sub", "sub/inner" }) |path| {
        for ([_][]const []const u8{
            &.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads" },
            &.{ "log", "-g", "--format=%gs", "topic", "--" },
            &.{ "config", "--get-regexp", "^branch\\." },
        }) |args| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.appendSlice(gpa, &.{ "-C", path });
            try argv.appendSlice(gpa, args);
            var ran = try repo.capture(io, argv.items);
            defer ran.deinit(gpa);
            try out.print(gpa, "{s} {s}: {d}\n{s}", .{ path, args[0], ran.code, ran.stdout });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn compare(n: usize, case: Case) !void {
    var theirs = try move_test.fixture(true);
    defer theirs.deinit();
    var ours = try move_test.fixture(true);
    defer ours.deinit();
    try prepare(&theirs, case.prepare);
    try prepare(&ours, case.prepare);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "-c", "submodule.propagateBranches=true", "branch", "--recurse-submodules" });
    try args.appendSlice(gpa, case.args);
    theirs.report_failures = false;
    var ran = try theirs.capture(io, args.items);
    defer ran.deinit(gpa);

    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
    var refusal: submodule.Refusal = .{};
    const refused = blk: {
        submodule.createBranches(gpa, io, &native, .{ .name = "topic", .start = case.start }, .{
            .who = who,
            .force = case.force,
            .track = case.track,
            .refusal = &refusal,
        }) catch |err| switch (err) {
            error.BranchExists, error.NotCloned => break :blk true,
            else => |e| return e,
        };
        break :blk false;
    };
    std.testing.expectEqual(ran.code != 0, refused) catch |err| {
        std.debug.print("case {d}: git exited {d}: {s}\n", .{ n, ran.code, ran.stderr });
        return err;
    };
    const expected = try state(&theirs);
    defer gpa.free(expected);
    const actual = try state(&ours);
    defer gpa.free(actual);
    std.testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("case {d}: git said {s}\n", .{ n, ran.stderr });
        return err;
    };
}

test "branch --recurse-submodules makes branches as git's does" {
    const cases = [_]Case{
        .{ .args = &.{"topic"} },
        .{ .args = &.{ "topic", "two" }, .start = "two" },
        .{ .args = &.{ "topic", "main" }, .start = "main" },
        .{ .args = &.{ "--track", "topic", "main" }, .start = "main", .track = .explicit },
        .{ .args = &.{ "--no-track", "topic", "main" }, .start = "main", .track = .never },
        .{ .args = &.{ "topic", "main" }, .start = "main", .prepare = .autosetup_always },
        .{ .args = &.{"topic"}, .prepare = .taken },
        .{ .args = &.{ "-f", "topic" }, .force = true, .prepare = .taken },
        .{ .args = &.{"topic"}, .prepare = .inactive },
    };
    for (cases, 0..) |case, n| try compare(n, case);
}

test "branch recurses only under submodule.propagateBranches" {
    const Want = union(enum) { recurse: bool, refused };
    const cases = [_]struct { text: []const u8, explicit: bool, want: Want }{
        .{ .text = "", .explicit = false, .want = .{ .recurse = false } },
        .{ .text = "", .explicit = true, .want = .refused },
        .{ .text = "[submodule]\n\trecurse = true\n", .explicit = false, .want = .{ .recurse = false } },
        .{ .text = "[submodule]\n\tpropagateBranches = true\n", .explicit = false, .want = .{ .recurse = false } },
        .{ .text = "[submodule]\n\tpropagateBranches = true\n", .explicit = true, .want = .{ .recurse = true } },
        .{ .text = "[submodule]\n\tpropagateBranches = true\n\trecurse = true\n", .explicit = false, .want = .{ .recurse = true } },
    };
    for (cases) |case| {
        var config = try config_mod.Config.parseText(gpa, case.text, .local);
        defer config.deinit();
        switch (case.want) {
            .recurse => |want| try std.testing.expectEqual(want, try submodule.branchesRecurse(&config, case.explicit)),
            .refused => try std.testing.expectError(error.BranchesNotPropagated, submodule.branchesRecurse(&config, case.explicit)),
        }
    }
}

test "checkout and reset recurse as --recurse-submodules or submodule.recurse says" {
    var unset = try config_mod.Config.parseText(gpa, "", .local);
    defer unset.deinit();
    var set = try config_mod.Config.parseText(gpa, "[submodule]\n\trecurse = true\n", .local);
    defer set.deinit();
    try std.testing.expect(!try submodule.updatesRecurse(&unset, null));
    try std.testing.expect(try submodule.updatesRecurse(&unset, true));
    try std.testing.expect(try submodule.updatesRecurse(&set, null));
    try std.testing.expect(!try submodule.updatesRecurse(&set, false));
}
