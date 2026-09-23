//! Repositories inside a working tree that the index has no gitlink for,
//! against the real git: how `status` and `list` name them, and what
//! `addAll` stages for them.
//!
//! git never walks into one. Its status names it once, `sub/`, under every
//! untracked mode; its `add -A` stages it as a gitlink to the commit it has
//! checked out, and stops when there is none. A directory the index already
//! has files under is walked like any other, `.git` or not.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");

const Repository = repo_mod.Repository;
const testing = std.testing;

/// Tracked files, a `.gitignore`, and around them every shape the untracked
/// listing distinguishes: repositories with and without a commit, one that
/// is ignored, ones inside untracked directories, untracked directories
/// holding only ignored files or nothing at all, and a tracked directory
/// that has since gained a `.git`.
fn fixture(gpa: Allocator, io: Io) !testgit.Repo {
    var git = try testgit.Repo.init(gpa, io, &.{});
    errdefer git.deinit();
    try git.writeFile(io, "t.txt", "tracked\n");
    try git.writeFile(io, "tr/a.txt", "tracked\n");
    try git.writeFile(io, "grew/a.txt", "tracked\n");
    try git.writeFile(io, ".gitignore", "build/\n*.log\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });

    try git.writeFile(io, "sub/s.txt", "sub\n");
    try git.exec(io, &.{ "-C", "sub", "init", "-q", "-b", "main" });
    try git.exec(io, &.{ "-C", "sub", "add", "-A" });
    try git.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "sub" });

    try git.writeFile(io, "tr/new.txt", "untracked\n");
    try git.writeFile(io, "tr/q.log", "ignored\n");
    try git.writeFile(io, "tr/nd/e/z", "untracked\n");
    try git.writeFile(io, "u/v/w", "untracked\n");
    try git.writeFile(io, "u/x.log", "ignored\n");
    try git.writeFile(io, "m/f", "untracked\n");
    try git.writeFile(io, "m/x.log", "ignored\n");
    try git.writeFile(io, "m/ig/a.log", "ignored\n");
    try git.writeFile(io, "m/build/q/o", "ignored\n");
    try git.writeFile(io, "m/sub/g", "untracked\n");
    try git.writeFile(io, "m/r/f", "in a repository\n");
    try git.exec(io, &.{ "-C", "m/r", "init", "-q" });
    try git.writeFile(io, "n/b.log", "ignored\n");
    try git.writeFile(io, "n/ig/a.log", "ignored\n");
    try git.writeFile(io, "n/build/z", "ignored\n");
    try git.dir.createDirPath(io, "o/r");
    try git.exec(io, &.{ "-C", "o/r", "init", "-q" });
    try git.writeFile(io, "build2/build/z", "ignored\n");
    try git.dir.createDirPath(io, "ignr/build");
    try git.exec(io, &.{ "-C", "ignr/build", "init", "-q" });
    try git.dir.createDirPath(io, "empty/deeper/still");
    try git.writeFile(io, "build/p", "ignored\n");
    try git.writeFile(io, "build/x/o", "ignored\n");
    try git.writeFile(io, "grew/b.txt", "untracked\n");
    try git.exec(io, &.{ "-C", "grew", "init", "-q" });
    return git;
}

/// The lines of `git status --porcelain=v2` with the modes and object
/// names taken off a changed entry's line, sorted.
fn gitStatus(gpa: Allocator, io: Io, git: *testgit.Repo, untracked: []const u8, ignored: bool) ![]u8 {
    const mode = try std.fmt.allocPrint(gpa, "--untracked-files={s}", .{untracked});
    defer gpa.free(mode);
    const out = if (ignored)
        try git.run(io, &.{ "status", "--porcelain=v2", mode, "--ignored" })
    else
        try git.run(io, &.{ "status", "--porcelain=v2", mode });
    defer gpa.free(out);
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '?' or line[0] == '!') {
            try lines.append(gpa, try gpa.dupe(u8, line));
            continue;
        }
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next();
        const xy = fields.next().?;
        const sub = fields.next().?;
        for (0..5) |_| _ = fields.next();
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ xy, sub, fields.rest() }));
    }
    return joinSorted(gpa, lines.items);
}

fn letter(change: worktree.Change) u8 {
    return switch (change) {
        .unmodified => '.',
        .added, .untracked => 'A',
        .modified => 'M',
        .deleted => 'D',
        .type_changed => 'T',
        .ignored => '!',
    };
}

/// `worktree.status` over the same repository, in the same shape.
fn relicStatus(gpa: Allocator, io: Io, git: *testgit.Repo, untracked: worktree.StatusOptions.Untracked, ignored: bool) ![]u8 {
    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = repo.worktreeRules();
    rules.ignore = &ignore_rules;
    var result = try worktree.status(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
        .rules = rules,
        .head_tree = try repo.headTree(io),
        .untracked = untracked,
        .include_ignored = ignored,
    });
    defer result.deinit();

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (result.entries) |entry| {
        const line = switch (entry.unstaged) {
            .untracked => try std.fmt.allocPrint(gpa, "? {s}", .{entry.path}),
            .ignored => try std.fmt.allocPrint(gpa, "! {s}", .{entry.path}),
            else => try std.fmt.allocPrint(gpa, "{c}{c} N... {s}", .{ letter(entry.staged), letter(entry.unstaged), entry.path }),
        };
        try lines.append(gpa, line);
    }
    return joinSorted(gpa, lines.items);
}

fn joinSorted(gpa: Allocator, lines: [][]const u8) ![]u8 {
    std.mem.sort([]const u8, lines, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |line| {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "status names each repository inside the working tree once, as git status does, under every untracked mode" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try fixture(gpa, io);
    defer git.deinit();

    const Mode = struct { git: []const u8, ours: worktree.StatusOptions.Untracked };
    const modes = [_]Mode{ .{ .git = "all", .ours = .all }, .{ .git = "normal", .ours = .normal }, .{ .git = "no", .ours = .no } };
    for (modes) |mode| {
        for ([_]bool{ false, true }) |ignored| {
            const theirs = try gitStatus(gpa, io, &git, mode.git, ignored);
            defer gpa.free(theirs);
            const ours = try relicStatus(gpa, io, &git, mode.ours, ignored);
            defer gpa.free(ours);
            testing.expectEqualStrings(theirs, ours) catch |err| {
                std.debug.print("--untracked-files={s} ignored={}\n", .{ mode.git, ignored });
                return err;
            };
        }
    }
}

test "list names a repository inside the working tree once, as git ls-files --others does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try fixture(gpa, io);
    defer git.deinit();

    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = repo.worktreeRules();
    rules.ignore = &ignore_rules;
    var listing = try worktree.list(gpa, io, repo.work_dir.?, &index, rules);
    defer listing.deinit();

    const out = try git.run(io, &.{ "ls-files", "--others", "--exclude-standard" });
    defer gpa.free(out);
    var theirs: std.ArrayList([]const u8) = .empty;
    defer theirs.deinit(gpa);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len != 0) try theirs.append(gpa, line);
    }
    const expected = try joinSorted(gpa, theirs.items);
    defer gpa.free(expected);
    const untracked = try gpa.dupe([]const u8, listing.untracked());
    defer gpa.free(untracked);
    const actual = try joinSorted(gpa, untracked);
    defer gpa.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "addAll stages a repository inside the working tree as the gitlink git add -A stages" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try fixture(gpa, io);
    defer git.deinit();
    // The two without a commit would stop both, as the next test shows.
    try git.dir.deleteTree(io, "m/r/.git");
    try git.dir.deleteTree(io, "o");
    try git.dir.deleteTree(io, "grew/.git");

    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = repo.worktreeRules();
    rules.ignore = &ignore_rules;
    const outcome = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = rules });
    try testing.expectEqual(@as(u32, 1), outcome.nested_repositories);
    const ours_tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});
    const ours = try git.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(ours);

    try git.exec(io, &.{ "read-tree", "HEAD" });
    try git.exec(io, &.{ "add", "-A" });
    const theirs = try git.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(theirs);
    try testing.expectEqualStrings(theirs, ours);
    try testing.expect(std.mem.indexOf(u8, ours, "160000 ") != null);
    const theirs_tree = try git.line(io, &.{"write-tree"});
    defer gpa.free(theirs_tree);
    var hex: [hash.max_hex_len]u8 = undefined;
    try testing.expectEqualStrings(theirs_tree, ours_tree.hex(&hex));
}

test "a repository inside the working tree with no commit stops addAll, as it stops git add -A" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "t.txt", "tracked\n");
    try git.writeFile(io, "empty/e.txt", "in a repository with no commit\n");
    try git.exec(io, &.{ "-C", "empty", "init", "-q" });

    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    var refusal: worktree.Refusal = .{};
    try testing.expectError(error.NoCommitCheckedOut, worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
        .rules = repo.worktreeRules(),
        .refusal = &refusal,
    }));
    try testing.expectEqualStrings("empty", refusal.path());

    git.report_failures = false;
    try testing.expectError(error.GitFailed, git.exec(io, &.{ "add", "-A" }));
}
