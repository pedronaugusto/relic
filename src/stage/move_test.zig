//! `mv` held to git 2.56's: the same repository, the same operands, and
//! what each leaves compared -- the index and the tree it writes, the
//! working tree's files, a submodule's `.git` file and `core.worktree`,
//! and whether it refused.

const std = @import("std");
const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");
const move_mod = @import("move.zig");
const remove_test = @import("remove_test.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

/// Files and directories `mv` sorts: clean ones, one changed in the working
/// tree, one staged and never committed, one untracked, two directories.
fn fixture() !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    for ([_][]const u8{ "a.txt", "m.txt", "dir/b.txt", "dir/sub/c.txt", "other/o.txt" }) |path| try repo.writeFile(io, path, "first\n");
    try repo.exec(io, &.{ "add", "." });
    try repo.exec(io, &.{ "commit", "-qm", "one" });
    try repo.writeFile(io, "m.txt", "changed in the working tree\n");
    try repo.writeFile(io, "n.txt", "added, never committed\n");
    try repo.exec(io, &.{ "add", "n.txt" });
    try repo.writeFile(io, "u.txt", "untracked\n");
    return repo;
}

const Case = struct { args: []const []const u8, options: move_mod.Options };

fn compare(theirs: *testgit.Repo, ours: *testgit.Repo, n: usize, case: Case) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.append(gpa, "mv");
    try args.appendSlice(gpa, case.args);
    theirs.report_failures = false;
    var ran = try theirs.capture(io, args.items);
    defer ran.deinit(gpa);
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    const refused = blk: {
        var outcome = move_mod.move(gpa, io, &native, case.options) catch |err| switch (err) {
            error.DirectoryIntoItself => break :blk true,
            else => |e| return e,
        };
        defer outcome.deinit();
        break :blk outcome.refused();
    };
    std.testing.expectEqual(ran.code != 0, refused) catch |err| {
        std.debug.print("mv case {d}: git exited {d}: {s}\n", .{ n, ran.code, ran.stderr });
        return err;
    };
    const expected = try remove_test.state(theirs);
    defer gpa.free(expected);
    const actual = try remove_test.state(ours);
    defer gpa.free(actual);
    std.testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("mv case {d}: git said {s}\n", .{ n, ran.stderr });
        return err;
    };
}

test "mv renames, moves into directories and refuses what git's does" {
    const cases = [_]Case{
        .{ .args = &.{ "a.txt", "z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "z.txt" } },
        .{ .args = &.{ "a.txt", "dir" }, .options = .{ .sources = &.{"a.txt"}, .destination = "dir" } },
        .{ .args = &.{ "a.txt", "dir/" }, .options = .{ .sources = &.{"a.txt"}, .destination = "dir/" } },
        .{ .args = &.{ "dir", "newdir" }, .options = .{ .sources = &.{"dir"}, .destination = "newdir" } },
        .{ .args = &.{ "dir/", "newdir/" }, .options = .{ .sources = &.{"dir/"}, .destination = "newdir/" } },
        .{ .args = &.{ "dir/sub", "other" }, .options = .{ .sources = &.{"dir/sub"}, .destination = "other" } },
        .{ .args = &.{ "dir/sub", "." }, .options = .{ .sources = &.{"dir/sub"}, .destination = "." } },
        .{ .args = &.{ "a.txt", "m.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "m.txt" } },
        .{ .args = &.{ "-f", "a.txt", "m.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "m.txt", .force = true } },
        .{ .args = &.{ "-f", "a.txt", "other" }, .options = .{ .sources = &.{"a.txt"}, .destination = "other", .force = true } },
        .{ .args = &.{ "u.txt", "x.txt" }, .options = .{ .sources = &.{"u.txt"}, .destination = "x.txt" } },
        .{ .args = &.{ "missing", "x.txt" }, .options = .{ .sources = &.{"missing"}, .destination = "x.txt" } },
        .{ .args = &.{ "dir", "dir/inner" }, .options = .{ .sources = &.{"dir"}, .destination = "dir/inner" } },
        .{ .args = &.{ "dir", "other" }, .options = .{ .sources = &.{"dir"}, .destination = "other" } },
        .{ .args = &.{ "dir/sub", "dir/b.txt" }, .options = .{ .sources = &.{"dir/sub"}, .destination = "dir/b.txt" } },
        .{ .args = &.{ "a.txt", "m.txt", "dir" }, .options = .{ .sources = &.{ "a.txt", "m.txt" }, .destination = "dir" } },
        .{ .args = &.{ "a.txt", "n.txt", "nodir" }, .options = .{ .sources = &.{ "a.txt", "n.txt" }, .destination = "nodir" } },
        .{ .args = &.{ "a.txt", "nodir/" }, .options = .{ .sources = &.{"a.txt"}, .destination = "nodir/" } },
        .{ .args = &.{ "-k", "u.txt", "a.txt", "dir" }, .options = .{ .sources = &.{ "u.txt", "a.txt" }, .destination = "dir", .skip_errors = true } },
        .{ .args = &.{ "-k", "a.txt", "m.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "m.txt", .skip_errors = true } },
        .{ .args = &.{ "-n", "a.txt", "z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "z.txt", .dry_run = true } },
        .{ .args = &.{ "m.txt", "z.txt" }, .options = .{ .sources = &.{"m.txt"}, .destination = "z.txt" } },
        .{ .args = &.{ "n.txt", "dir/sub" }, .options = .{ .sources = &.{"n.txt"}, .destination = "dir/sub" } },
        .{ .args = &.{ "dir/b.txt", "dir2" }, .options = .{ .sources = &.{"dir/b.txt"}, .destination = "dir2" } },
        .{ .args = &.{ "dir/sub/c.txt", "dir", "other" }, .options = .{ .sources = &.{ "dir/sub/c.txt", "dir" }, .destination = "other" } },
        .{ .args = &.{ "a.txt", "m.txt", "z.txt" }, .options = .{ .sources = &.{ "a.txt", "m.txt" }, .destination = "z.txt" } },
        .{ .args = &.{ "a.txt", "dir", "other" }, .options = .{ .sources = &.{ "a.txt", "dir" }, .destination = "other" } },
        .{ .args = &.{ "a.txt", "A.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "A.txt" } },
        .{ .args = &.{ "dir", "Dir" }, .options = .{ .sources = &.{"dir"}, .destination = "Dir" } },
        // git 2.56 checks a destination's leading directory before it moves
        // anything, a dry run and a skipping run included.
        .{ .args = &.{ "a.txt", "nodir/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "nodir/z.txt" } },
        .{ .args = &.{ "-n", "a.txt", "nodir/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "nodir/z.txt", .dry_run = true } },
        .{ .args = &.{ "-k", "a.txt", "nodir/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "nodir/z.txt", .skip_errors = true } },
        .{ .args = &.{ "a.txt", "m.txt/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "m.txt/z.txt" } },
        .{ .args = &.{ "a.txt", "dir/sub/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "dir/sub/z.txt" } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try fixture();
        defer theirs.deinit();
        var ours = try fixture();
        defer ours.deinit();
        try compare(&theirs, &ours, n, case);
    }
}

test "mv refuses a destination beyond a symbolic link, as git 2.56's does" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const cases = [_]Case{
        .{ .args = &.{ "a.txt", "link/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "link/z.txt" } },
        .{ .args = &.{ "-n", "a.txt", "link/sub/z.txt" }, .options = .{ .sources = &.{"a.txt"}, .destination = "link/sub/z.txt", .dry_run = true } },
        .{ .args = &.{ "a.txt", "link" }, .options = .{ .sources = &.{"a.txt"}, .destination = "link" } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try fixture();
        defer theirs.deinit();
        var ours = try fixture();
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |repo| try repo.dir.symLink(io, "dir", "link", .{ .is_directory = true });
        try compare(&theirs, &ours, n, case);
    }
}

test "mv takes a submodule's .gitmodules path and .git file along as git's does" {
    const Sub = struct { absorbed: bool, case: Case };
    const cases = [_]Sub{
        .{ .absorbed = false, .case = .{ .args = &.{ "sub", "sub2" }, .options = .{ .sources = &.{"sub"}, .destination = "sub2" } } },
        .{ .absorbed = true, .case = .{ .args = &.{ "sub", "sub2" }, .options = .{ .sources = &.{"sub"}, .destination = "sub2" } } },
        .{ .absorbed = true, .case = .{ .args = &.{ "sub", "other" }, .options = .{ .sources = &.{"sub"}, .destination = "other" } } },
        .{ .absorbed = true, .case = .{ .args = &.{ "sub", "other", "deps" }, .options = .{ .sources = &.{ "sub", "other" }, .destination = "deps" } } },
    };
    for (cases, 0..) |c, n| {
        var theirs = try withSubmodules(c.absorbed);
        defer theirs.deinit();
        var ours = try withSubmodules(c.absorbed);
        defer ours.deinit();
        try compare(&theirs, &ours, n, c.case);
    }

    // `.gitmodules` with changes not staged stops the move of a submodule.
    var theirs = try remove_test.submodules(.gitmodules);
    defer theirs.deinit();
    var ours = try remove_test.submodules(.gitmodules);
    defer ours.deinit();
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    try std.testing.expectError(error.GitmodulesNotStaged, move_mod.move(gpa, io, &native, .{ .sources = &.{"other"}, .destination = "elsewhere" }));
    theirs.report_failures = false;
    var ran = try theirs.capture(io, &.{ "mv", "other", "elsewhere" });
    defer ran.deinit(gpa);
    try std.testing.expect(ran.code != 0);
}

/// `remove_test`'s two submodules, a tracked directory `deps`, and with
/// `absorbed` their `.git` directories moved into the superproject's.
fn withSubmodules(absorbed: bool) !testgit.Repo {
    var repo = try remove_test.submodules(.none);
    errdefer repo.deinit();
    try repo.writeFile(io, "deps/keep", "keep\n");
    try repo.exec(io, &.{ "add", "deps" });
    try repo.exec(io, &.{ "commit", "-qm", "deps" });
    if (absorbed) try repo.exec(io, &.{ "submodule", "absorbgitdirs" });
    return repo;
}

test "mv moves across the sparse cone only when asked, as git's does" {
    const cases = [_]Case{
        .{ .args = &.{ "out/o.txt", "keep/" }, .options = .{ .sources = &.{"out/o.txt"}, .destination = "keep/" } },
        .{ .args = &.{ "--sparse", "out/o.txt", "keep/" }, .options = .{ .sources = &.{"out/o.txt"}, .destination = "keep/", .sparse = true } },
        .{ .args = &.{ "keep/k.txt", "out/" }, .options = .{ .sources = &.{"keep/k.txt"}, .destination = "out/" } },
        .{ .args = &.{ "--sparse", "keep/k.txt", "out/" }, .options = .{ .sources = &.{"keep/k.txt"}, .destination = "out/", .sparse = true } },
        .{ .args = &.{ "--sparse", "keep/k.txt", "out/x.txt" }, .options = .{ .sources = &.{"keep/k.txt"}, .destination = "out/x.txt", .sparse = true } },
        .{ .args = &.{ "-k", "out/o.txt", "top.txt", "keep/" }, .options = .{ .sources = &.{ "out/o.txt", "top.txt" }, .destination = "keep/", .skip_errors = true } },
        .{ .args = &.{ "top.txt", "keep/" }, .options = .{ .sources = &.{"top.txt"}, .destination = "keep/" } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try remove_test.sparse();
        defer theirs.deinit();
        var ours = try remove_test.sparse();
        defer ours.deinit();
        try compare(&theirs, &ours, n, case);
    }

    // A file with changes moved out of the cone stays on the disk.
    var theirs = try remove_test.sparse();
    defer theirs.deinit();
    var ours = try remove_test.sparse();
    defer ours.deinit();
    for ([_]*testgit.Repo{ &theirs, &ours }) |repo| try repo.writeFile(io, "keep/k.txt", "changed\n");
    try compare(&theirs, &ours, 100, .{ .args = &.{ "--sparse", "keep/k.txt", "out/" }, .options = .{ .sources = &.{"keep/k.txt"}, .destination = "out/", .sparse = true } });
}
