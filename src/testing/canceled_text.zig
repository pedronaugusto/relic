//! Cancellation in the line diffs relic runs (design §11): a unified body,
//! a blob merge, blame and range-diff ask at each step (a work unit of the
//! line diff, a commit of blame, a pair of range-diff's patches), so each
//! canceled at a point halfway through its own returns `error.Canceled`
//! there, on each backend, and each never canceled gives the answer it
//! gives without the wrapper.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const cancel = @import("cancel.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const blame = @import("../diff/blame.zig");
const blob_merge = @import("../merge/blob_merge.zig");
const range_diff = @import("../patch/range_diff.zig");
const hash = @import("../hash/hash.zig");

/// `lines` lines of four kinds in a seeded order: every line common, so a
/// minimal diff searches them all.
fn fourKinds(gpa: Allocator, lines: usize, seed: u64) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const text = try gpa.alloc(u8, 2 * lines);
    for (0..lines) |i| {
        text[2 * i] = 'a' + random.uintLessThan(u8, 4);
        text[2 * i + 1] = '\n';
    }
    return text;
}

const Texts = struct { ancestor: []const u8, ours: []const u8, theirs: []const u8 };

fn bodyLength(io: Io, t: *const Texts) !usize {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try diff.unifiedBody(std.testing.allocator, io, &out.writer, .{ .old = t.ancestor, .new = t.ours }, .{ .minimal = true });
    return out.written().len;
}

fn mergeLength(io: Io, t: *const Texts) !usize {
    var merged = try blob_merge.blobs(std.testing.allocator, io, .{ .ancestor = t.ancestor, .ours = t.ours, .theirs = t.theirs }, .{ .minimal = true });
    defer merged.deinit();
    return merged.bytes.len;
}

const History = struct {
    repo: *repo_mod.Repository,
    head: hash.Oid,
    old: range_diff.Range,
    new: range_diff.Range,
};

fn blameHunks(io: Io, h: *const History) !usize {
    var found = try blame.file(std.testing.allocator, io, h.repo.objectDatabase(), .{ .commit = h.head, .path = "log.txt" }, .{});
    defer found.deinit();
    return found.hunks.len;
}

fn rangePairs(io: Io, h: *const History) !usize {
    var result = try range_diff.compute(std.testing.allocator, io, h.repo, .{ .old = h.old, .new = h.new }, .{});
    defer result.deinit();
    return result.old.len + result.new.len;
}

/// `op` as a task on `io`, as the backend runs it.
fn asTask(io: Io, comptime op: anytype, context: anytype) !usize {
    var task = try io.concurrent(op, .{ io, context });
    return task.await(io);
}

/// `op` run counted, its answer the plain run's and its points at least
/// `least`, then canceled at the middle one of them.
fn halfway(io: Io, comptime op: anytype, context: anytype, least: u64) !void {
    const expected = try op(std.testing.io, context);
    try std.testing.expectEqual(expected, try asTask(cancel.counted(io), op, context));
    const points = cancel.points();
    try std.testing.expect(points >= least);
    try cancel.expectCanceled(io, points / 2, 0, op, .{context});
}

fn texts(t: *const Texts, io: Io) !void {
    try halfway(io, bodyLength, t, 100);
    try halfway(io, mergeLength, t, 100);
}

test "a unified body and a blob merge canceled halfway through their line diffs return Canceled, and give the same answer when never canceled, on each backend" {
    const gpa = std.testing.allocator;
    const ancestor = try fourKinds(gpa, 2000, 1);
    defer gpa.free(ancestor);
    const ours = try fourKinds(gpa, 2000, 2);
    defer gpa.free(ours);
    const theirs = try fourKinds(gpa, 2000, 3);
    defer gpa.free(theirs);
    const t: Texts = .{ .ancestor = ancestor, .ours = ours, .theirs = theirs };
    try cancel.eachBackend(&t, texts);
}

/// Commits of blame's history, and patches on each side of the range-diff.
const commits = 16;

fn history(h: *const History, io: Io) !void {
    // Each commit adds a line at the end: a diff with nothing to search,
    // which asks nothing, so the points are blame's own, one per commit.
    try halfway(io, blameHunks, h, commits);
    // No patch matches another exactly: every pair is diffed.
    try halfway(io, rangePairs, h, commits / 2 * (commits / 2));
}

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

test "blame canceled at a commit's point and range-diff at a pair's return Canceled, and give the same answer when never canceled, on each backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    var line: [64]u8 = undefined;
    for (0..commits) |i| {
        try log.appendSlice(gpa, try std.mem.print(&line, "entry {d}\n", .{i}));
        try git.writeFile(io, "log.txt", log.items);
        try git.exec(io, &.{ "add", "log.txt" });
        try git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&line, "entry {d}", .{i}) });
    }
    // Two sides of commits / 2 patches each from the tip, a file apiece,
    // every patch's text its own.
    try git.exec(io, &.{ "checkout", "-q", "-b", "left" });
    for (0..commits / 2) |i| {
        try git.writeFile(io, try std.mem.print(&line, "left{d}.txt", .{i}), try std.mem.print(line[32..], "left {d}\n", .{i}));
        try git.exec(io, &.{ "add", "-A" });
        try git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&line, "left {d}", .{i}) });
    }
    try git.exec(io, &.{ "checkout", "-q", "-b", "right", "left~" ++ std.fmt.comptimePrint("{d}", .{commits / 2}) });
    for (0..commits / 2) |i| {
        try git.writeFile(io, try std.mem.print(&line, "right{d}.txt", .{i}), try std.mem.print(line[32..], "right side {d}\n", .{i}));
        try git.exec(io, &.{ "add", "-A" });
        try git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&line, "right {d}", .{i}) });
    }

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const base = try oidOf(gpa, io, &git, "right~" ++ std.fmt.comptimePrint("{d}", .{commits / 2}));
    const h: History = .{
        .repo = &repo,
        .head = base,
        .old = .{ .base = base, .tip = try oidOf(gpa, io, &git, "left") },
        .new = .{ .base = base, .tip = try oidOf(gpa, io, &git, "right") },
    };
    try cancel.eachBackend(&h, history);
}
