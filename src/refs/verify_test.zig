//! `refs.verify` against `git refs verify`: the same broken refs, the same
//! lines, in both ref formats and in a linked worktree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const verify = @import("verify.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;

/// git's lines and ours, each sorted: git walks the refs directory in the
/// order the filesystem gives.
fn expectSameLines(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *Repository, args: []const []const u8, options: verify.Options) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "refs", "verify" });
    try argv.appendSlice(gpa, args);
    var c = try git.capture(io, argv.items);
    defer c.deinit(gpa);
    var report = try verify.check(gpa, io, repo.refStore(), options);
    defer report.deinit();
    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    for (report.findings) |f| {
        const lead: []const u8 = if (f.level == .@"error") "error: " else "warning: ";
        try ours.print(gpa, "{s}{f}\n", .{ lead, f });
    }
    const theirs_sorted = try sortedLines(gpa, c.stderr);
    defer gpa.free(theirs_sorted);
    const ours_sorted = try sortedLines(gpa, ours.items);
    defer gpa.free(ours_sorted);
    try std.testing.expectEqualStrings(theirs_sorted, ours_sorted);
    try std.testing.expectEqual(c.code != 0, report.failed());
}

/// The lines of `text`, each a message that may itself hold newlines up
/// to the next `error: ` or `warning: `, sorted.
fn sortedLines(gpa: Allocator, text: []const u8) ![]u8 {
    var messages: std.ArrayList([]const u8) = .empty;
    defer messages.deinit(gpa);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        const next = text[i + 1 ..];
        if (next.len == 0 or std.mem.startsWith(u8, next, "error: ") or std.mem.startsWith(u8, next, "warning: ")) {
            try messages.append(gpa, text[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < text.len) try messages.append(gpa, text[start..]);
    std.mem.sort([]const u8, messages.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return std.mem.concat(gpa, u8, messages.items);
}

fn oneCommit(gpa: Allocator, io: Io, args: []const []const u8) !testgit.Repo {
    var git = try testgit.Repo.init(gpa, io, args);
    errdefer git.deinit();
    try git.writeFile(io, "f", "one\n");
    try git.exec(io, &.{ "add", "f" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    return git;
}

test "loose refs and root refs are verified as git verifies them, line for line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 47);
    var git = try oneCommit(gpa, io, &.{});
    defer git.deinit();
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const zero = "0000000000000000000000000000000000000000";
    var buf: [256]u8 = undefined;
    const Case = struct { path: []const u8, fmt: enum { oid_then, raw }, text: []const u8 };
    for ([_]Case{
        .{ .path = ".git/refs/heads/no-newline", .fmt = .oid_then, .text = "" },
        .{ .path = ".git/refs/heads/two-newlines", .fmt = .oid_then, .text = "\n\n" },
        .{ .path = ".git/refs/heads/garbage", .fmt = .oid_then, .text = " garbage\n" },
        .{ .path = ".git/refs/heads/tab-then", .fmt = .oid_then, .text = "\tmore\n" },
        .{ .path = ".git/refs/heads/nonsense", .fmt = .raw, .text = "nonsense\n" },
        .{ .path = ".git/refs/heads/short", .fmt = .raw, .text = "1234\n" },
        .{ .path = ".git/refs/heads/null", .fmt = .raw, .text = zero ++ "\n" },
        .{ .path = ".git/refs/heads/sym-no-newline", .fmt = .raw, .text = "ref: refs/heads/main" },
        .{ .path = ".git/refs/heads/sym-trailing", .fmt = .raw, .text = "ref: refs/heads/main\n\n " },
        .{ .path = ".git/refs/heads/sym-bad", .fmt = .raw, .text = "ref: refs/heads/../x\n" },
        .{ .path = ".git/refs/heads/sym-not-ref", .fmt = .raw, .text = "ref: elsewhere/x\n" },
        .{ .path = ".git/refs/heads/sym-root", .fmt = .raw, .text = "ref: ORIG_HEAD\n" },
        .{ .path = ".git/refs/heads/a..b", .fmt = .oid_then, .text = "\n" },
        .{ .path = ".git/refs/heads/skipped.lock", .fmt = .raw, .text = "not read\n" },
        .{ .path = ".git/refs/heads/.dot.lock", .fmt = .oid_then, .text = "\n" },
        .{ .path = ".git/ORIG_HEAD", .fmt = .oid_then, .text = " trailing\n" },
        .{ .path = ".git/BISECT_HEAD", .fmt = .raw, .text = "broken\n" },
    }) |case| {
        const bytes = switch (case.fmt) {
            .oid_then => try std.mem.print(&buf, "{s}{s}", .{ head, case.text }),
            .raw => case.text,
        };
        try git.writeFile(io, case.path, bytes);
    }
    if (builtin.target.os.tag != .windows) {
        try git.dir.symLink(io, "main", ".git/refs/heads/as-link", .{});
    }
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try expectSameLines(gpa, io, &git, &repo, &.{}, .{ .rules = &.{} });
    try expectSameLines(gpa, io, &git, &repo, &.{"--strict"}, .{ .rules = &.{ .strict = true } });

    // HEAD names no branch
    try git.exec(io, &.{ "symbolic-ref", "HEAD", "refs/tags/v1" });
    var again = try Repository.open(gpa, io, git.dir, .{});
    defer again.deinit(io);
    try expectSameLines(gpa, io, &git, &again, &.{}, .{ .rules = &.{} });
}

test "a packed-refs file is verified as git verifies it, line for line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 47);
    var git = try oneCommit(gpa, io, &.{});
    defer git.deinit();
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    var buf: [2048]u8 = undefined;
    inline for ([_][]const u8{
        "",
        "# pack-refs with: peeled fully-peeled sorted \n{0s} refs/heads/b\n{0s} refs/heads/a\n",
        "# pack-refs with: peeled fully-peeled \n{0s} refs/heads/b\n{0s} refs/heads/a\n",
        "# something else\n{0s} refs/heads/a\n",
        "{0s} refs/heads/a\n^{0s}\n{0s}refs/heads/nospace\n",
        "{0s} refs/heads/a\n^{0s} after\nnot-an-oid refs/heads/x\n",
        "{0s} refs/heads/a..b\n^short\n",
        "# pack-refs with: sorted \n{0s} refs/heads/a\n{0s} refs/heads/c",
        "{0s} refs/heads/n\x00ul\n",
    }) |template| {
        var stream: Io.Writer = .fixed(&buf);
        if (comptime template.len > 0) try stream.print(template, .{head});
        try git.writeFile(io, ".git/packed-refs", stream.buffered());
        var repo = try Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        try expectSameLines(gpa, io, &git, &repo, &.{}, .{ .rules = &.{} });
    }
}

test "a reftable stack's refs are verified as git verifies them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 47);
    var git = try oneCommit(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.exec(io, &.{ "symbolic-ref", "refs/heads/elsewhere", "refs/tags/v1" });
    try git.exec(io, &.{ "symbolic-ref", "HEAD", "refs/tags/v1" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try expectSameLines(gpa, io, &git, &repo, &.{}, .{ .rules = &.{} });
}

test "a linked worktree's refs are named under worktrees/<id>/, as git names them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 47);
    var git = try oneCommit(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "worktree", "add", "-q", "--detach", "wt" });
    try git.writeFile(io, ".git/worktrees/wt/refs/bisect/bad", "nonsense\n");
    try git.writeFile(io, ".git/worktrees/wt/ORIG_HEAD", "broken\n");
    var wt_dir = try git.dir.openDir(io, "wt", .{});
    defer wt_dir.close(io);
    var linked = try Repository.open(gpa, io, wt_dir, .{});
    defer linked.deinit(io);
    var main_repo = try Repository.open(gpa, io, git.dir, .{});
    defer main_repo.deinit(io);
    // git verifies every worktree in one run: the main one's lines and the
    // linked one's, together
    var c = try git.capture(io, &.{ "refs", "verify" });
    defer c.deinit(gpa);
    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    for ([_]struct { repo: *Repository, id: ?[]const u8 }{ .{ .repo = &main_repo, .id = null }, .{ .repo = &linked, .id = "wt" } }) |side| {
        var report = try verify.check(gpa, io, side.repo.refStore(), .{ .rules = &.{}, .worktree = side.id });
        defer report.deinit();
        for (report.findings) |f| try ours.print(gpa, "{s}{f}\n", .{ if (f.level == .@"error") "error: " else "warning: ", f });
    }
    const theirs_sorted = try sortedLines(gpa, c.stderr);
    defer gpa.free(theirs_sorted);
    const ours_sorted = try sortedLines(gpa, ours.items);
    defer gpa.free(ours_sorted);
    try std.testing.expectEqualStrings(theirs_sorted, ours_sorted);
}
