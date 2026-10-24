//! `--recurse-submodules` held to git 2.55's: one superproject built twice
//! by git with its dates fixed, so both have the same commits, then `git
//! checkout` or `git reset --hard` with the flag in one and relic's
//! checkout or reset with a `submodule.Mover` in the other, and what each
//! refused and left compared -- the superproject's index, files, `.git`
//! files and each repository's `core.worktree`, and every submodule's
//! `HEAD`, index and files.

const std = @import("std");
const testgit = @import("../testing/git.zig");
const remove_test = @import("../stage/remove_test.zig");
const repo_mod = @import("../repo/repo.zig");
const hash = @import("../hash/hash.zig");
const worktree = @import("../checkout/checkout.zig");
const reset = @import("../commit/reset.zig");
const submodule = @import("submodule.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

/// A superproject on `one` with the submodule `sub` (which, `nested`, has
/// `inner` of its own) at its first commit; `two` with `sub` (and `inner`)
/// moved on; `none` before `sub` was added. The repositories it was cloned
/// from are in `upstream`, which the superproject ignores.
pub fn fixture(nested: bool) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    try testgit.setDate(&repo.isolated.?, 1_700_000_000);
    try repo.writeFile(io, ".git/info/exclude", "upstream/\n");
    try repo.writeFile(io, "top", "top\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-qm", "base" });
    try repo.exec(io, &.{ "branch", "none" });

    try repo.exec(io, &.{ "init", "-q", "-b", "main", "upstream/inner" });
    try repo.writeFile(io, "upstream/inner/i", "i1\n");
    try repo.exec(io, &.{ "-C", "upstream/inner", "add", "-A" });
    try repo.exec(io, &.{ "-C", "upstream/inner", "commit", "-qm", "i1" });
    try repo.exec(io, &.{ "init", "-q", "-b", "main", "upstream/sub" });
    try repo.writeFile(io, "upstream/sub/s", "s1\n");
    try repo.writeFile(io, "upstream/sub/t", "t1\n");
    try repo.exec(io, &.{ "-C", "upstream/sub", "add", "-A" });
    if (nested) try repo.exec(io, &.{ "-C", "upstream/sub", "submodule", "add", "-q", "../inner", "inner" });
    try repo.exec(io, &.{ "-C", "upstream/sub", "commit", "-qm", "s1" });

    try repo.exec(io, &.{ "submodule", "add", "-q", "./upstream/sub", "sub" });
    if (nested) try repo.exec(io, &.{ "submodule", "update", "-q", "--init", "--recursive" });
    try repo.exec(io, &.{ "commit", "-qm", "one" });
    try repo.exec(io, &.{ "branch", "one" });

    try repo.writeFile(io, "upstream/inner/i", "i2\n");
    try repo.exec(io, &.{ "-C", "upstream/inner", "commit", "-qam", "i2" });
    try repo.writeFile(io, "upstream/sub/s", "s2\n");
    try repo.writeFile(io, "upstream/sub/u", "u2\n");
    try repo.exec(io, &.{ "-C", "upstream/sub", "add", "-A" });
    if (nested) {
        try repo.exec(io, &.{ "-C", "upstream/sub/inner", "pull", "-q", "origin", "main" });
        try repo.exec(io, &.{ "-C", "upstream/sub", "add", "inner" });
    }
    try repo.exec(io, &.{ "-C", "upstream/sub", "commit", "-qm", "s2" });
    try repo.exec(io, &.{ "-C", "sub", "pull", "-q", "origin", "main" });
    if (nested) try repo.exec(io, &.{ "-C", "sub", "submodule", "update", "-q", "--init", "--recursive" });
    try repo.exec(io, &.{ "commit", "-qam", "two" });
    try repo.exec(io, &.{ "branch", "two" });
    try repo.exec(io, &.{ "checkout", "-q", "--recurse-submodules", "one" });
    return repo;
}

/// What a case does to the fixture before it moves.
const Change = enum { none, modified, modified_moved, staged, untracked, inactive };

fn change(repo: *testgit.Repo, what: Change) !void {
    switch (what) {
        .none => {},
        // `t`, which `two` does not change, and `s`, which it does.
        .modified => try repo.writeFile(io, "sub/t", "local\n"),
        .modified_moved => try repo.writeFile(io, "sub/s", "local\n"),
        .staged => {
            try repo.writeFile(io, "sub/t", "staged\n");
            try repo.exec(io, &.{ "-C", "sub", "add", "t" });
        },
        .untracked => try repo.writeFile(io, "sub/u", "untracked\n"),
        .inactive => try repo.exec(io, &.{ "config", "submodule.sub.active", "false" }),
    }
}

const Command = enum { checkout, reset_hard };

const Case = struct { nested: bool = false, change: Change = .none, command: Command = .checkout, from: []const u8 = "one", to: []const u8 };

/// The superproject's state, and each submodule's `HEAD` and index.
fn state(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const top = try remove_test.state(repo);
    defer gpa.free(top);
    try out.appendSlice(gpa, top);
    for ([_][]const u8{ "sub", "sub/inner" }) |path| {
        const dot_git = try gpa.print("{s}/.git", .{path});
        defer gpa.free(dot_git);
        repo.dir.access(io, dot_git, .{}) catch continue;
        repo.report_failures = false;
        defer repo.report_failures = true;
        for ([_][]const []const u8{ &.{ "rev-parse", "HEAD" }, &.{ "ls-files", "-s" }, &.{ "status", "--porcelain", "--ignore-submodules=none" } }) |args| {
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

fn compare(n: usize, case: Case, built: *const [2]testgit.Repo) !void {
    const source = &built[@intFromBool(case.nested)];
    var theirs = try testgit.Repo.copyOf(gpa, io, source);
    defer theirs.deinit();
    var ours = try testgit.Repo.copyOf(gpa, io, source);
    defer ours.deinit();
    if (!std.mem.eql(u8, case.from, "one")) {
        try theirs.exec(io, &.{ "checkout", "-q", "--recurse-submodules", case.from });
        try ours.exec(io, &.{ "checkout", "-q", "--recurse-submodules", case.from });
    }
    try change(&theirs, case.change);
    try change(&ours, case.change);

    theirs.report_failures = false;
    var ran = switch (case.command) {
        .checkout => try theirs.capture(io, &.{ "checkout", "-q", "--recurse-submodules", case.to }),
        .reset_hard => try theirs.capture(io, &.{ "reset", "-q", "--hard", "--recurse-submodules", case.to }),
    };
    defer ran.deinit(gpa);
    const refused = try move(&ours, case);

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

/// The case's command in `repo` through relic: whether it was refused.
fn move(repo: *testgit.Repo, case: Case) !bool {
    const spec = try gpa.print("{s}^{{tree}}", .{case.to});
    defer gpa.free(spec);
    const tree_text = try repo.line(io, &.{ "rev-parse", spec });
    defer gpa.free(tree_text);
    const tree = try hash.Oid.parse(.sha1, tree_text);
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    var locked = try native.lockIndex(io);
    defer locked.deinit(io);
    var refusal: submodule.Refusal = .{};
    var mover: submodule.Mover = .{ .gpa = gpa, .repo = &native, .index = &locked.index, .options = .{ .refusal = &refusal } };
    var obstructions: worktree.Obstructions = .init(gpa);
    defer obstructions.deinit();
    switch (case.command) {
        .checkout => {
            var ignore_rules = try native.loadIgnore(io);
            defer ignore_rules.deinit();
            var attrs = try native.loadAttrs(io);
            defer attrs.deinit();
            var rules = try native.worktreeRules();
            rules.ignore = &ignore_rules;
            rules.attrs = &attrs;
            rules.submodules = mover.submodules();
            _ = worktree.checkout(gpa, io, native.workDirectory().?, .{ .index = &locked.index, .db = native.objectDatabase(), .tree = tree }, .{
                .rules = rules,
                .ignore = &ignore_rules,
                .obstructions = &obstructions,
            }) catch |err| switch (err) {
                error.SubmoduleNotUpdated, error.LocalChangesWouldBeOverwritten => return true,
                else => |e| return e,
            };
        },
        .reset_hard => reset.toTree(gpa, io, &native, .{
            .index = &locked.index,
            .tree = tree,
            .mode = .hard,
            .submodules = mover.submodules(),
            .obstructions = &obstructions,
        }) catch |err| switch (err) {
            error.SubmoduleNotUpdated => return true,
            else => |e| return e,
        },
    }
    try locked.commit(io);
    return false;
}

/// Every case, its number its place here.
const cases = [_]Case{
    .{ .to = "two" },
    .{ .to = "two", .change = .modified },
    .{ .to = "two", .change = .modified_moved },
    .{ .to = "two", .change = .staged },
    .{ .to = "two", .change = .untracked },
    .{ .to = "two", .change = .inactive },
    .{ .to = "none" },
    .{ .to = "none", .change = .modified },
    .{ .from = "none", .to = "one" },
    .{ .from = "two", .to = "one" },
    .{ .to = "two", .command = .reset_hard },
    .{ .to = "two", .command = .reset_hard, .change = .modified_moved },
    .{ .to = "two", .command = .reset_hard, .change = .staged },
    .{ .to = "one", .command = .reset_hard, .change = .modified },
    .{ .to = "none", .command = .reset_hard },
    .{ .to = "two", .nested = true },
    .{ .to = "none", .nested = true },
    .{ .from = "none", .to = "two", .nested = true },
    .{ .to = "two", .nested = true, .command = .reset_hard },
};

/// The cases `command` moves by. Each fixture is built once by git, and each
/// case moves two copies of it.
fn compareAll(command: Command) !void {
    var built: [2]testgit.Repo = .{ try fixture(false), undefined };
    defer built[0].deinit();
    built[1] = try fixture(true);
    defer built[1].deinit();
    for (cases, 0..) |case, n| if (case.command == command) try compare(n, case, &built);
}

test "checkout --recurse-submodules moves submodules as git's does" {
    try compareAll(.checkout);
}

test "reset --hard --recurse-submodules moves submodules as git's does" {
    try compareAll(.reset_hard);
}
