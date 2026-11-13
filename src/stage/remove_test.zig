//! `rm` held to git 2.55's: the same repository, the same pathspecs, and
//! what each leaves compared -- the index, the working tree's files, and
//! whether it refused.

const std = @import("std");
const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");
const remove_mod = @import("remove.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

/// A history with what `rm` sorts: clean files, one changed in the
/// working tree, one staged, one both, a directory of files.
fn fixture() !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    for ([_][]const u8{ "clean.txt", "local.txt", "staged.txt", "both.txt", "dir/a.txt", "dir/sub/b.txt" }) |path| try repo.writeFile(io, path, "first\n");
    try repo.exec(io, &.{ "add", "." });
    try repo.exec(io, &.{ "commit", "-qm", "one" });
    try repo.writeFile(io, "local.txt", "changed in the working tree\n");
    try repo.writeFile(io, "staged.txt", "staged\n");
    try repo.exec(io, &.{ "add", "staged.txt" });
    try repo.writeFile(io, "both.txt", "staged\n");
    try repo.exec(io, &.{ "add", "both.txt" });
    try repo.writeFile(io, "both.txt", "and changed again\n");
    try repo.writeFile(io, "new.txt", "added, never committed\n");
    try repo.exec(io, &.{ "add", "new.txt" });
    return repo;
}

/// The index, the tree it writes, the working tree's files, and each
/// submodule's `.git` file and `core.worktree`.
pub fn state(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const listed = try repo.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(listed);
    try out.appendSlice(gpa, listed);
    const tree = try repo.run(io, &.{"write-tree"});
    defer gpa.free(tree);
    try out.print(gpa, "tree {s}", .{tree});
    var walker = try repo.dir.walk(gpa);
    defer walker.deinit();
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, ".git")) {
            const text = try entry.dir.readFileAlloc(io, ".git", gpa, .unlimited);
            defer gpa.free(text);
            try files.append(gpa, try gpa.print("{s}: {s}", .{ entry.path, text }));
            continue;
        }
        if (isGitDir(entry.path)) continue;
        try files.append(gpa, try gpa.print("{s}{s}", .{ entry.path, if (entry.kind == .directory) "/" else "" }));
    }
    std.mem.sort([]u8, files.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (files.items) |f| try out.print(gpa, "{s}\n", .{f});
    if (repo.dir.readFileAlloc(io, ".gitmodules", gpa, .unlimited)) |modules| {
        defer gpa.free(modules);
        try out.print(gpa, ".gitmodules:\n{s}", .{modules});
    } else |_| {}
    var gits = repo.dir.openDir(io, ".git/modules", .{ .iterate = true }) catch return out.toOwnedSlice(gpa);
    defer gits.close(io);
    var it = gits.iterate();
    while (try it.next(io)) |entry| {
        try out.print(gpa, "module {s}\n", .{entry.name});
        const config_path = try gpa.print("{s}/config", .{entry.name});
        defer gpa.free(config_path);
        const config = try gits.readFileAlloc(io, config_path, gpa, .unlimited);
        defer gpa.free(config);
        var lines = std.mem.splitScalar(u8, config, '\n');
        while (lines.next()) |line| if (std.mem.find(u8, line, "worktree") != null) try out.print(gpa, "{s}\n", .{line});
    }
    return out.toOwnedSlice(gpa);
}

/// A repository's own `.git`, or a submodule's, in a walker's path, whose
/// separator is the platform's: a backslash on Windows.
pub fn isGitDir(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, std.Io.Dir.path.sep);
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".git")) return true;
    return false;
}

/// Run `git rm` in `theirs` and `remove` in `ours`, and compare what each
/// refused and left.
fn compare(theirs: *testgit.Repo, ours: *testgit.Repo, n: usize, case: Case) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "rm", "-q" });
    try args.appendSlice(gpa, case.args);
    theirs.report_failures = false;
    var ran = try theirs.capture(io, args.items);
    defer ran.deinit(gpa);
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    const refused = blk: {
        var outcome = remove_mod.remove(gpa, io, &native, case.options) catch |err| switch (err) {
            error.PathspecUnmatched, error.NotRecursive, error.GitmodulesNotStaged => break :blk true,
            else => |e| return e,
        };
        defer outcome.deinit();
        break :blk outcome.refused() or outcome.sparse_only.len != 0;
    };
    std.testing.expectEqual(ran.code != 0, refused) catch |err| {
        std.debug.print("rm case {d}: git exited {d}: {s}\n", .{ n, ran.code, ran.stderr });
        return err;
    };
    const expected = try state(theirs);
    defer gpa.free(expected);
    const actual = try state(ours);
    defer gpa.free(actual);
    std.testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("rm case {d}\n", .{n});
        return err;
    };
}

const Case = struct { args: []const []const u8, options: remove_mod.Options };

test "rm removes, keeps and refuses what git's does" {
    const cases = [_]Case{
        .{ .args = &.{"clean.txt"}, .options = .{ .pathspecs = &.{"clean.txt"} } },
        .{ .args = &.{ "--cached", "clean.txt" }, .options = .{ .pathspecs = &.{"clean.txt"}, .cached = true } },
        .{ .args = &.{"local.txt"}, .options = .{ .pathspecs = &.{"local.txt"} } },
        .{ .args = &.{ "--cached", "local.txt" }, .options = .{ .pathspecs = &.{"local.txt"}, .cached = true } },
        .{ .args = &.{"staged.txt"}, .options = .{ .pathspecs = &.{"staged.txt"} } },
        .{ .args = &.{ "--cached", "staged.txt" }, .options = .{ .pathspecs = &.{"staged.txt"}, .cached = true } },
        .{ .args = &.{"both.txt"}, .options = .{ .pathspecs = &.{"both.txt"} } },
        .{ .args = &.{ "--cached", "both.txt" }, .options = .{ .pathspecs = &.{"both.txt"}, .cached = true } },
        .{ .args = &.{ "-f", "both.txt" }, .options = .{ .pathspecs = &.{"both.txt"}, .force = true } },
        .{ .args = &.{ "--cached", "new.txt" }, .options = .{ .pathspecs = &.{"new.txt"}, .cached = true } },
        .{ .args = &.{"dir"}, .options = .{ .pathspecs = &.{"dir"} } },
        .{ .args = &.{ "-r", "dir" }, .options = .{ .pathspecs = &.{"dir"}, .recursive = true } },
        .{ .args = &.{"dir/sub/b.txt"}, .options = .{ .pathspecs = &.{"dir/sub/b.txt"} } },
        .{ .args = &.{"*.txt"}, .options = .{ .pathspecs = &.{"*.txt"} } },
        .{ .args = &.{ "-f", "*.txt" }, .options = .{ .pathspecs = &.{"*.txt"}, .force = true } },
        .{ .args = &.{"missing.txt"}, .options = .{ .pathspecs = &.{"missing.txt"} } },
        .{ .args = &.{ "--ignore-unmatch", "missing.txt", "clean.txt" }, .options = .{ .pathspecs = &.{ "missing.txt", "clean.txt" }, .ignore_unmatch = true } },
        .{ .args = &.{ "-n", "clean.txt" }, .options = .{ .pathspecs = &.{"clean.txt"}, .dry_run = true } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try fixture();
        defer theirs.deinit();
        var ours = try fixture();
        defer ours.deinit();
        try compare(&theirs, &ours, n, case);
    }
}

/// Two submodules checked out in place, their `.git` still directories,
/// and one file in the superproject.
pub const Change = enum { none, untracked, modified, gitmodules };

pub fn submodules(change: Change) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    try repo.writeFile(io, "top", "top\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    for ([_][]const u8{ "sub", "other" }) |name| {
        try repo.exec(io, &.{ "init", "-q", "-b", "main", name });
        const file = try gpa.print("{s}/s", .{name});
        defer gpa.free(file);
        try repo.writeFile(io, file, "s1\n");
        try repo.exec(io, &.{ "-C", name, "add", "-A" });
        try repo.exec(io, &.{ "-C", name, "commit", "-q", "-m", "s1" });
        const url = try gpa.print("./{s}", .{name});
        defer gpa.free(url);
        try repo.exec(io, &.{ "submodule", "add", "-q", url, name });
    }
    try repo.exec(io, &.{ "commit", "-q", "-m", "add subs" });
    switch (change) {
        .none => {},
        .untracked => try repo.writeFile(io, "sub/new", "untracked\n"),
        .modified => try repo.writeFile(io, "sub/s", "changed\n"),
        .gitmodules => try repo.writeFile(io, ".gitmodules", "[submodule \"sub\"]\n\tpath = sub\n\turl = ./sub\n"),
    }
    return repo;
}

test "rm takes a submodule's working tree and .gitmodules section as git's does" {
    const cases = [_]struct { change: Change, case: Case }{
        .{ .change = .none, .case = .{ .args = &.{"sub"}, .options = .{ .pathspecs = &.{"sub"} } } },
        .{ .change = .none, .case = .{ .args = &.{ "--cached", "sub" }, .options = .{ .pathspecs = &.{"sub"}, .cached = true } } },
        .{ .change = .none, .case = .{ .args = &.{ "sub", "other" }, .options = .{ .pathspecs = &.{ "sub", "other" } } } },
        .{ .change = .untracked, .case = .{ .args = &.{"sub"}, .options = .{ .pathspecs = &.{"sub"} } } },
        .{ .change = .untracked, .case = .{ .args = &.{ "-f", "sub" }, .options = .{ .pathspecs = &.{"sub"}, .force = true } } },
        .{ .change = .modified, .case = .{ .args = &.{"sub"}, .options = .{ .pathspecs = &.{"sub"} } } },
        .{ .change = .modified, .case = .{ .args = &.{ "--cached", "sub" }, .options = .{ .pathspecs = &.{"sub"}, .cached = true } } },
        .{ .change = .gitmodules, .case = .{ .args = &.{"other"}, .options = .{ .pathspecs = &.{"other"} } } },
    };
    for (cases, 0..) |c, n| {
        var theirs = try submodules(c.change);
        defer theirs.deinit();
        var ours = try submodules(c.change);
        defer ours.deinit();
        try compare(&theirs, &ours, n, c.case);
    }
}

/// A cone-mode sparse checkout of `keep`: `out` is outside it.
pub fn sparse() !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    for ([_][]const u8{ "top.txt", "keep/k.txt", "out/o.txt" }) |path| try repo.writeFile(io, path, "first\n");
    try repo.exec(io, &.{ "add", "." });
    try repo.exec(io, &.{ "commit", "-qm", "one" });
    try repo.exec(io, &.{ "sparse-checkout", "set", "keep" });
    return repo;
}

test "rm leaves what lies outside the sparse cone, unless asked, as git's does" {
    const cases = [_]Case{
        .{ .args = &.{"out/o.txt"}, .options = .{ .pathspecs = &.{"out/o.txt"} } },
        .{ .args = &.{ "--sparse", "out/o.txt" }, .options = .{ .pathspecs = &.{"out/o.txt"}, .sparse = true } },
        .{ .args = &.{ "-r", "--sparse", "out" }, .options = .{ .pathspecs = &.{"out"}, .sparse = true, .recursive = true } },
        .{ .args = &.{"*.txt"}, .options = .{ .pathspecs = &.{"*.txt"} } },
        .{ .args = &.{ "top.txt", "out/o.txt" }, .options = .{ .pathspecs = &.{ "top.txt", "out/o.txt" } } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try sparse();
        defer theirs.deinit();
        var ours = try sparse();
        defer ours.deinit();
        try compare(&theirs, &ours, n, case);
    }
}
