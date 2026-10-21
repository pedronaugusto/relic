//! The split index held to git 2.55's: the same operation in two twin
//! repositories, git's in one and relic's in the other, leaves the same
//! main file -- its own entries, its replacements, its deletions -- over
//! the same shared index, a new one written when git writes one, and git
//! reads relic's as its own.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const fs = @import("../fs/fs.zig");
const hash = @import("../hash/hash.zig");
const index_mod = @import("index.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("../checkout/checkout.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

const files = [_][]const u8{ "a", "b", "c", "d", "dir/e", "dir/f", "dir/g", "h", "i", "j" };

/// Ten files dated an hour back, so that no entry is racy against an
/// index written now, added by git under `settings`.
fn fixture(settings: []const []const u8) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    var at: usize = 0;
    while (at < settings.len) : (at += 2) try repo.exec(io, &.{ "config", settings[at], settings[at + 1] });
    for (files) |path| try repo.writeFile(io, path, path);
    try age(&repo, &files);
    try repo.exec(io, &.{ "add", "." });
    return repo;
}

fn age(repo: *testgit.Repo, paths: []const []const u8) !void {
    const past: i96 = (std.Io.Clock.real.now(io).toSeconds() - 3600) * std.time.ns_per_s;
    for (paths) |path| try fs.setTimestamps(io, repo.dir, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = past } } });
}

/// What the index file says, stat aside: its own entries (a replacement
/// unnamed), the shared positions it deletes and replaces, the shared
/// index's entries, and how many shared index files there are.
fn describe(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const bytes = try repo.readFile(io, ".git/index");
    defer gpa.free(bytes);
    var index = try index_mod.Index.parse(gpa, .sha1, bytes);
    defer index.deinit();
    var hex: [hash.max_hex_len]u8 = undefined;
    for (index.entries.items) |e| try out.print(gpa, "entry '{s}' {s} {o}\n", .{ e.path, e.oid.hex(&hex), e.diskMode() });
    if (index.split_delete) |bits| try out.print(gpa, "delete {any}\n", .{bits.positions});
    if (index.split_replace) |bits| try out.print(gpa, "replace {any}\n", .{bits.positions});
    if (index.split) |split| if (split.base) |base| {
        const name = try gpa.print(".git/sharedindex.{s}", .{base.hex(&hex)});
        defer gpa.free(name);
        const shared_bytes = try repo.readFile(io, name);
        defer gpa.free(shared_bytes);
        var shared = try index_mod.Index.parse(gpa, .sha1, shared_bytes);
        defer shared.deinit();
        for (shared.entries.items) |e| try out.print(gpa, "shared '{s}' {s}\n", .{ e.path, e.oid.hex(&hex) });
    };
    var git_dir = try repo.dir.openDir(io, ".git", .{ .iterate = true });
    defer git_dir.close(io);
    var count: usize = 0;
    var it = git_dir.iterate();
    while (try it.next(io)) |entry| count += @intFromBool(std.mem.startsWith(u8, entry.name, "sharedindex."));
    try out.print(gpa, "shared files {d}\n", .{count});
    return out.toOwnedSlice(gpa);
}

const Op = struct {
    /// Files written now, then added.
    write: []const []const u8 = &.{},
    /// Paths taken out of the index, as `rm --cached`.
    remove: []const []const u8 = &.{},
};

fn apply(theirs: *testgit.Repo, ours: *testgit.Repo, op: Op) !void {
    // Dated back too: which entries are racy is the clock's to say, and a
    // git built without nanosecond times reckons it by the second.
    for ([_]*testgit.Repo{ theirs, ours }) |repo| {
        for (op.write) |path| try repo.writeFile(io, path, "changed\n");
        try age(repo, op.write);
    }
    for (op.write) |path| try theirs.exec(io, &.{ "add", path });
    for (op.remove) |path| try theirs.exec(io, &.{ "rm", "-q", "--cached", path });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    // One write per git command, as git writes the index once for each.
    for (op.write) |path| {
        var locked = try native.lockIndex(io);
        defer locked.deinit(io);
        _ = try worktree.addAll(gpa, io, ours.dir, .{ .index = &locked.index, .db = native.objectDatabase() }, .{ .rules = try native.worktreeRules(), .prefix = path, .stage_deletions = false });
        try locked.commit(io);
    }
    for (op.remove) |path| {
        var locked = try native.lockIndex(io);
        defer locked.deinit(io);
        if (locked.index.cache_tree) |*tree| tree.invalidate(path);
        _ = locked.index.remove(path);
        try locked.commit(io);
    }
}

const Case = struct { settings: []const []const u8, op: Op, then: []const []const u8 = &.{} };

test "a split index is written as git writes it" {
    const split_on: []const []const u8 = &.{ "core.splitIndex", "true" };
    const cases = [_]Case{
        // One new entry: under the twenty percent, so the shared index stays.
        .{ .settings = split_on, .op = .{ .write = &.{"new"} } },
        // A changed entry is a replacement.
        .{ .settings = split_on, .op = .{ .write = &.{"b"} } },
        // A removed one, a deletion.
        .{ .settings = split_on, .op = .{ .remove = &.{"c"} } },
        // Both, and a new one.
        .{ .settings = split_on, .op = .{ .write = &.{ "dir/f", "new" }, .remove = &.{"h"} } },
        // Past the twenty percent: a new shared index.
        .{ .settings = split_on, .op = .{ .write = &.{ "n1", "n2", "n3" } } },
        .{ .settings = &.{ "core.splitIndex", "true", "splitIndex.maxPercentChange", "0" }, .op = .{ .write = &.{"new"} } },
        .{ .settings = &.{ "core.splitIndex", "true", "splitIndex.maxPercentChange", "100" }, .op = .{ .write = &.{ "n1", "n2", "n3", "n4" } } },
        // The old shared index goes when a new one is written past its expiry.
        .{ .settings = &.{ "core.splitIndex", "true", "splitIndex.maxPercentChange", "0", "splitIndex.sharedIndexExpire", "now" }, .op = .{ .write = &.{"new"} } },
        // Split while `core.splitIndex` is unset: kept as it is.
        .{ .settings = split_on, .then = &.{ "--unset", "core.splitIndex" }, .op = .{ .write = &.{"b"} } },
        // `false` writes it whole again.
        .{ .settings = split_on, .then = &.{ "core.splitIndex", "false" }, .op = .{ .write = &.{"b"} } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try fixture(case.settings);
        defer theirs.deinit();
        var ours = try fixture(case.settings);
        defer ours.deinit();
        if (case.then.len != 0) for ([_]*testgit.Repo{ &theirs, &ours }) |repo| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.append(gpa, "config");
            try args.appendSlice(gpa, case.then);
            try repo.exec(io, args.items);
        };
        try apply(&theirs, &ours, case.op);
        const want = try describe(&theirs);
        defer gpa.free(want);
        const got = try describe(&ours);
        defer gpa.free(got);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("split case {d}\n", .{n});
            return err;
        };
        // And git reads relic's as it reads its own.
        for ([_][]const []const u8{ &.{ "ls-files", "-s" }, &.{ "status", "--porcelain" } }) |args| {
            const git_sees = try theirs.run(io, args);
            defer gpa.free(git_sees);
            const relic_wrote = try ours.run(io, args);
            defer gpa.free(relic_wrote);
            try std.testing.expectEqualStrings(git_sees, relic_wrote);
        }
    }
}
