//! Cancellation in the working-tree scans (design §11): status, add,
//! checkout and grep ask once per file, so a scan canceled at a file's point
//! returns `error.Canceled` there, on each backend, and a scan never
//! canceled gives the answer it gives without the wrapper.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const cancel = @import("cancel.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("../checkout/checkout.zig");
const index_mod = @import("../index/index.zig");
const grep = @import("../grep.zig");
const hash = @import("../hash/hash.zig");

/// Files in the fixture, over four directories.
const files = 64;

fn fileName(buf: []u8, i: usize) []const u8 {
    return std.mem.print(buf, "d{d}/f{d}.txt", .{ i % 4, i }) catch unreachable; // unreachable: the buffer holds the longest name
}

/// Every file of the fixture written with `text` and the file's number.
fn writeAll(io: Io, git: *testgit.Repo, text: []const u8) !void {
    var name: [32]u8 = undefined;
    var body: [64]u8 = undefined;
    for (0..files) |i| {
        try git.writeFile(io, fileName(&name, i), try std.mem.print(&body, "{s} {d}\nneedle\n", .{ text, i }));
    }
}

/// A repository whose `files` files are committed once as "one" and once
/// as "two", the working tree at "two".
fn fixture(gpa: Allocator, io: Io) !testgit.Repo {
    var git = try testgit.Repo.init(gpa, io, &.{});
    errdefer git.deinit();
    try writeAll(io, &git, "one");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "tag", "one" });
    try writeAll(io, &git, "two");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    return git;
}

const Scan = struct {
    git: *testgit.Repo,
    repo: *repo_mod.Repository,
    index: *index_mod.Index,
    rules: worktree.Rules,
    tree: hash.Oid,
};

fn statusCount(io: Io, s: *const Scan) !usize {
    var status = try worktree.status(std.testing.allocator, io, s.git.dir, .{ .index = s.index, .db = s.repo.objectDatabase() }, .{ .rules = s.rules });
    defer status.deinit();
    return status.entries.len;
}

fn addCount(io: Io, s: *const Scan) !usize {
    var index = try s.repo.openIndex(io);
    defer index.deinit();
    _ = try worktree.addAll(std.testing.allocator, io, s.git.dir, .{ .index = &index, .db = s.repo.objectDatabase() }, .{ .rules = s.rules });
    return index.entries.items.len;
}

fn checkoutCount(io: Io, s: *const Scan) !usize {
    var index = try s.repo.openIndex(io);
    defer index.deinit();
    const outcome = try worktree.checkout(std.testing.allocator, io, s.git.dir, .{ .index = &index, .db = s.repo.objectDatabase(), .tree = s.tree }, .{ .force = true, .rules = s.rules });
    return outcome.written;
}

fn grepCount(io: Io, s: *const Scan) !usize {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const outcome = try grep.grep(std.testing.allocator, io, &out.writer, s.repo, .{ .patterns = &.{"needle"}, .threads = 1 });
    return outcome.files;
}

/// `op` as a task on `io`, as the backend runs it.
fn asTask(io: Io, comptime op: fn (Io, *const Scan) anyerror!usize, s: *const Scan) !usize {
    var task = try io.concurrent(op, .{ io, s });
    return task.await(io);
}

/// Each scan run counted, its answer the plain run's and its points at
/// least one per file, then canceled at the point of a file halfway.
/// Checkout goes last: it puts back the tree the scans before it compare.
fn scans(s: *const Scan, io: Io) !void {
    inline for (.{ statusCount, addCount, grepCount, checkoutCount }) |op| {
        const expected = try op(std.testing.io, s);
        try std.testing.expectEqual(expected, try asTask(cancel.counted(io), op, s));
        try std.testing.expect(cancel.points() >= files);
        try cancel.expectCanceled(io, files / 2, 0, op, .{s});
    }
}

test "status, add, checkout and grep canceled at a file's point return Canceled, and give the same answer when never canceled, on each backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try fixture(gpa, io);
    defer git.deinit();
    // Every file changed again, its stat no longer vouching for it, and a
    // new file beside each fourth.
    try writeAll(io, &git, "three");
    var name: [32]u8 = undefined;
    for (0..files / 4) |i| try git.writeFile(io, try std.mem.print(&name, "new{d}.txt", .{i}), "new\n");

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const tree_text = try git.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree_text);
    const scan: Scan = .{
        .git = &git,
        .repo = &repo,
        .index = &index,
        .rules = try repo.worktreeRules(),
        .tree = try hash.Oid.parse(.sha1, tree_text),
    };
    try cancel.eachBackend(&scan, scans);
}
