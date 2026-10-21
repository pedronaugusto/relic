//! `last_modified` against git 2.55's `git last-modified`: the same commit
//! for every path, the same boundaries, in the same order, at each depth,
//! under a pathspec, over a range, past a count, and with a commit-graph's
//! generations ordering the walk.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const repo_mod = @import("../repo/repo.zig");
const pathspec = @import("../patterns/pathspec.zig");
const last_modified = @import("../rev_walk/last_modified.zig");
const diff = @import("../diff/diff.zig");
const hash = @import("../hash/hash.zig");

/// Two lines of history that fork and merge twice, with nested folders, a
/// merge that brings a side's folder changes, a clock that runs backwards,
/// and a commit making again what a side made.
fn history(gpa: Allocator, io: Io, trap: bool) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    const Commit = struct { branch: []const u8, time: i64, from: ?u32 = null, merge: ?u32 = null, files: []const [2][]const u8 };
    const commits = [_]Commit{
        .{ .branch = "main", .time = 1000, .files = &.{ .{ "a", "1" }, .{ "dir/x", "x1" }, .{ "dir/sub/y", "y1" }, .{ "b.c", "c1" }, .{ "dir/sub/deep/q", "q1" } } }, // 1
        .{ .branch = "main", .time = 1100, .from = 1, .files = &.{.{ "a", "2" }} }, // 2
        .{ .branch = "side", .time = 1050, .from = 1, .files = &.{ .{ "dir/x", "x2" }, .{ "dir/sub/z", "z1" } } }, // 3
        .{ .branch = "main", .time = 1200, .from = 2, .merge = 3, .files = &.{ .{ "dir/x", "x2" }, .{ "dir/sub/z", "z1" } } }, // 4
        .{ .branch = "main", .time = 1150, .from = 4, .files = &.{ .{ "dir/sub/y", "y2" }, .{ "e.c", "e" } } }, // 5, before its parent
        .{ .branch = "other", .time = 1300, .from = 4, .files = &.{ .{ "a", "3" }, .{ "dir/sub/deep/q", "q2" } } }, // 6
        .{ .branch = "main", .time = 1400, .from = 5, .merge = 6, .files = &.{ .{ "a", "3" }, .{ "dir/sub/deep/q", "q2" }, .{ "b.c", "c2" } } }, // 7, an evil merge
        .{ .branch = "main", .time = 1500, .from = 7, .files = &.{ .{ "dir/w", "w" }, .{ "f", "1" } } }, // 8
        .{ .branch = "main", .time = 1500, .from = 8, .files = &.{.{ "f", "2" }} }, // 9, the same second
    };
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (commits, 1..) |c, mark| {
        try stream.print(gpa, "commit refs/heads/{s}\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 2\n{d}\n", .{ c.branch, mark, c.time, mark % 10 });
        if (c.from) |from| try stream.print(gpa, "from :{d}\n", .{from});
        if (c.merge) |merge| try stream.print(gpa, "merge :{d}\n", .{merge});
        for (c.files) |f| try stream.print(gpa, "M 100644 inline {s}\ndata {d}\n{s}\n", .{ f[0], f[1].len, f[1] });
        // The merge also takes the other side's `y`, which reaches `4`
        // through `6` while `5`, dated before `4`, is still to come.
        if (trap and mark == 7) try stream.appendSlice(gpa, "M 100644 inline dir/sub/y\ndata 2\ny1\n");
        try stream.append(gpa, '\n');
    }
    try stream.appendSlice(gpa, "done\n");
    const out = try testremote.gitInput(gpa, io, repo.dir, &.{ "fast-import", "--quiet", "--done" }, stream.items);
    gpa.free(out);
    try repo.exec(io, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    return repo;
}

const Case = struct {
    args: []const []const u8,
    inputs: last_modified.Inputs = .{},
    options: last_modified.Options = .{},
    specs: []const []const u8 = &.{},
};

const cases = [_]Case{
    .{ .args = &.{} },
    .{ .args = &.{"-r"}, .options = .{ .max_depth = null } },
    .{ .args = &.{ "-r", "-t" }, .options = .{ .max_depth = null, .trees = true } },
    .{ .args = &.{"--max-depth=1"}, .options = .{ .max_depth = 1 } },
    .{ .args = &.{ "--max-depth=1", "-t" }, .options = .{ .max_depth = 1, .trees = true } },
    .{ .args = &.{ "--", "dir" }, .specs = &.{"dir"} },
    .{ .args = &.{ "--max-depth=1", "--", "dir" }, .options = .{ .max_depth = 1 }, .specs = &.{"dir"} },
    .{ .args = &.{ "-r", "--", "dir/sub", "a" }, .options = .{ .max_depth = null }, .specs = &.{ "dir/sub", "a" } },
    .{ .args = &.{ "-r", "--", "*.c" }, .options = .{ .max_depth = null }, .specs = &.{"*.c"} },
    .{ .args = &.{ "-r", "main~2..main" }, .inputs = .{ .revision = "main", .exclude = &.{"main~2"} }, .options = .{ .max_depth = null } },
    .{ .args = &.{ "-r", "other", "^side" }, .inputs = .{ .revision = "other", .exclude = &.{"side"} }, .options = .{ .max_depth = null } },
    .{ .args = &.{ "-r", "-n", "3" }, .options = .{ .max_depth = null, .max_count = 3 } },
    .{ .args = &.{ "-r", "side" }, .inputs = .{ .revision = "side" }, .options = .{ .max_depth = null } },
};

/// What git writes for `result` under `-z`.
fn written(gpa: Allocator, result: last_modified.Result) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (result.entries) |e| {
        var hex: [64]u8 = undefined;
        try out.print(gpa, "{s}{s}\t{s}\x00", .{ if (e.boundary) "^" else "", e.commit.hex(&hex), e.path });
    }
    return out.toOwnedSlice(gpa);
}

fn compareAll(gpa: Allocator, io: Io, repo: *testgit.Repo) !void {
    for (cases) |case| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "last-modified", "-z" });
        try args.appendSlice(gpa, case.args);
        const want = try repo.run(io, args.items);
        defer gpa.free(want);
        var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
        defer opened.deinit(io);
        var spec = try pathspec.parse(gpa, case.specs);
        defer spec.deinit();
        var options = case.options;
        if (case.specs.len != 0) options.paths = &spec;
        var result = try last_modified.lastModified(gpa, io, &opened, case.inputs, options);
        defer result.deinit();
        const got = try written(gpa, result);
        defer gpa.free(got);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("git last-modified", .{});
            for (case.args) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print("\n", .{});
            return err;
        };
    }
}

test "last_modified names the commit git last-modified names for every path, in its order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 55);
    var repo = try history(gpa, io, false);
    defer repo.deinit();
    try compareAll(gpa, io, &repo);
    // A commit-graph's generations order the walk.
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });
    try compareAll(gpa, io, &repo);
}

test "last_modified walks by generation, and places every path where the clock alone would lose some" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 55);
    var repo = try history(gpa, io, true);
    defer repo.deinit();
    // By date, git walks `4` before `5` and stops on its own bug.
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.exec(io, &.{ "last-modified", "-r" }));
    repo.report_failures = true;
    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    {
        var result = try last_modified.lastModified(gpa, io, &opened, .{}, .{ .max_depth = null });
        defer result.deinit();
        const files = try repo.run(io, &.{ "ls-tree", "-r", "--name-only", "-z", "HEAD" });
        defer gpa.free(files);
        try std.testing.expectEqual(std.mem.count(u8, files, "\x00"), result.entries.len);
    }
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });
    {
        // The graph git wrote carries the generations the walk orders by.
        var reopened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
        defer reopened.deinit(io);
        var graph = (try reopened.objectDatabase().commitGraph(io)).?;
        defer graph.deinit();
        try std.testing.expect(graph.hasGenerations());
    }
    try compareAll(gpa, io, &repo);
}

test "last_modified refuses a wildcard pathspec with a depth, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 55);
    var repo = try history(gpa, io, false);
    defer repo.deinit();
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.exec(io, &.{ "last-modified", "--", "*.c" }));
    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    var spec = try pathspec.parse(gpa, &.{"*.c"});
    defer spec.deinit();
    try std.testing.expectError(error.MaxDepthWithWildcard, last_modified.lastModified(gpa, io, &opened, .{}, .{ .paths = &spec }));
}

test "diff.tree lists what git diff-tree lists at each depth, with subtrees and under a pathspec" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 55);
    var repo = try history(gpa, io, false);
    defer repo.deinit();
    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    const Shape = struct { args: []const []const u8, max_depth: ?u32, trees: bool, specs: []const []const u8 = &.{} };
    const shapes = [_]Shape{
        .{ .args = &.{"--max-depth=0"}, .max_depth = 0, .trees = false },
        .{ .args = &.{"--max-depth=1"}, .max_depth = 1, .trees = false },
        .{ .args = &.{ "--max-depth=1", "-t" }, .max_depth = 1, .trees = true },
        .{ .args = &.{"-t"}, .max_depth = null, .trees = true },
        .{ .args = &.{ "--max-depth=0", "--", "dir/sub" }, .max_depth = 0, .trees = false, .specs = &.{"dir/sub"} },
        .{ .args = &.{ "--max-depth=1", "-t", "--", "dir", "a" }, .max_depth = 1, .trees = true, .specs = &.{ "dir", "a" } },
        .{ .args = &.{ "-t", "--", "dir/sub/deep" }, .max_depth = null, .trees = true, .specs = &.{"dir/sub/deep"} },
    };
    for ([_][2][]const u8{ .{ "main~4", "main" }, .{ "side", "other" } }) |range| for (shapes) |shape| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "diff-tree", "-r", "--name-status", "--no-renames", range[0], range[1] });
        try args.appendSlice(gpa, shape.args);
        const want = try repo.run(io, args.items);
        defer gpa.free(want);
        var spec = try pathspec.parse(gpa, shape.specs);
        defer spec.deinit();
        var changes = try diff.tree(gpa, io, opened.objectDatabase(), .{
            .old = try treeOf(gpa, io, &repo, range[0]),
            .new = try treeOf(gpa, io, &repo, range[1]),
        }, .{ .max_depth = shape.max_depth, .trees = shape.trees, .paths = if (shape.specs.len != 0) &spec else null });
        defer changes.deinit();
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        for (changes.items) |c| try got.print(gpa, "{c}\t{s}\n", .{ c.letter(), c.path() });
        std.testing.expectEqualStrings(want, got.items) catch |err| {
            std.debug.print("git diff-tree {s} {s}", .{ range[0], range[1] });
            for (shape.args) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print("\n", .{});
            return err;
        };
    };
}

fn treeOf(gpa: Allocator, io: Io, repo: *testgit.Repo, rev: []const u8) !hash.Oid {
    const spec = try std.mem.concat(gpa, u8, &.{ rev, "^{tree}" });
    defer gpa.free(spec);
    const hex = try repo.run(io, &.{ "rev-parse", spec });
    defer gpa.free(hex);
    return hash.Oid.parse(.sha1, std.mem.trimEnd(u8, hex, "\n"));
}
