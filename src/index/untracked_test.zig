//! The untracked cache held to git 2.55's: what git fills reads and writes
//! back unchanged, `core.untrackedCache` makes or drops one as git's
//! `tweak_untracked_cache` does, and the directories an add or a removal
//! invalidates are git's, so that git's next status stays right.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const fs = @import("../fs/fs.zig");
const hash = @import("../hash/hash.zig");
const index_mod = @import("index.zig");
const untracked = @import("untracked.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("../checkout/checkout.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

/// A working tree with tracked files, untracked ones at the top and in
/// directories, an untracked directory, and a `.gitignore` below the top.
fn fixture() !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    for ([_][]const u8{ "t.txt", "dir/t.txt", "dir/deep/t.txt", "dir/.gitignore" }) |path| try repo.writeFile(io, path, "tracked\n");
    try repo.writeFile(io, "dir/.gitignore", "*.log\n");
    try repo.exec(io, &.{ "add", "." });
    try repo.exec(io, &.{ "commit", "-qm", "one" });
    for ([_][]const u8{ "u.txt", "dir/u.txt", "dir/x.log", "dir/deep/u.txt", "new/a.txt", "new/b.txt" }) |path| try repo.writeFile(io, path, "untracked\n");
    return repo;
}

/// The bytes of the extension `signature` in a SHA-1 index file git or
/// relic wrote, or `null` when it carries none.
fn rawExtension(bytes: []const u8, signature: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.findPos(u8, bytes, at, signature)) |found| : (at = found + 1) {
        if (found + 8 > bytes.len) return null;
        const size = std.mem.readInt(u32, bytes[found + 4 ..][0..4], .big);
        if (found + 8 + size <= bytes.len - hash.Kind.sha1.rawLen()) return bytes[found + 8 ..][0..size];
    }
    return null;
}

/// The cache as a text that leaves out what the disk decides: each
/// directory, whether it is valid and check-only, whether it has a
/// `.gitignore` object, and what is untracked in it.
fn describe(out: *std.ArrayList(u8), cache: *const untracked.UntrackedCache) !void {
    try out.print(gpa, "flags {d} per-dir {s} ident-ok {}\n", .{ cache.dir_flags, cache.exclude_per_dir, cache.ident.len > 0 });
    if (cache.root) |root| try describeDir(out, root, 0);
}

fn describeDir(out: *std.ArrayList(u8), dir: *const untracked.Dir, depth: usize) !void {
    try out.appendNTimes(gpa, ' ', depth * 2);
    try out.print(gpa, "'{s}' valid={} check_only={} gitignore={}", .{ dir.name, dir.valid, dir.check_only, dir.exclude_oid != null });
    for (dir.untracked.items) |name| try out.print(gpa, " [{s}]", .{name});
    try out.append(gpa, '\n');
    for (dir.dirs.items) |child| try describeDir(out, child, depth + 1);
}

fn indexBytes(repo: *testgit.Repo) ![]u8 {
    return repo.readFile(io, ".git/index");
}

fn readIndex(repo: *testgit.Repo) !index_mod.Index {
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    return index_mod.Index.read(gpa, io, git_dir, "index", .{ .git_dir = git_dir, .kind = .sha1 });
}

test "an untracked cache git filled is read and written back byte for byte" {
    var repo = try fixture();
    defer repo.deinit();
    try repo.exec(io, &.{ "-c", "core.untrackedCache=true", "status", "--porcelain" });
    try repo.exec(io, &.{ "-c", "core.untrackedCache=true", "status", "--porcelain" });
    // Dated a minute on, so that no entry is racy against the index and
    // smudged on the way out.
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    const later: i96 = (std.Io.Clock.real.now(io).toSeconds() + 60) * std.time.ns_per_s;
    try fs.setTimestamps(io, git_dir, "index", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = later } } });
    const original = try indexBytes(&repo);
    defer gpa.free(original);
    try std.testing.expect(rawExtension(original, "UNTR") != null);

    var index = try readIndex(&repo);
    defer index.deinit();
    try std.testing.expect(index.untracked != null);
    try std.testing.expect(index.untracked.?.root != null);
    const written = try index.toBytes(.{});
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, original, written);
}

test "core.untrackedCache=true gives the index git's new cache, and false takes it away" {
    var repo = try fixture();
    defer repo.deinit();
    try repo.exec(io, &.{ "config", "core.untrackedCache", "true" });
    try repo.writeFile(io, "staged.txt", "s\n");
    try repo.exec(io, &.{ "add", "staged.txt" });
    const theirs = try indexBytes(&repo);
    defer gpa.free(theirs);

    // The same index written by relic, from no index at all.
    try repo.dir.deleteFile(io, ".git/index");
    {
        var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
        defer native.deinit(io);
        var locked = try native.lockIndex(io);
        defer locked.deinit(io);
        _ = try worktree.addAll(gpa, io, repo.dir, .{ .index = &locked.index, .db = native.objectDatabase() }, .{ .rules = try native.worktreeRules(), .prefix = "staged.txt" });
        try locked.commit(io);
    }
    const ours = try indexBytes(&repo);
    defer gpa.free(ours);
    try std.testing.expectEqualSlices(u8, rawExtension(theirs, "UNTR").?, rawExtension(ours, "UNTR").?);

    // git fills it; `false` drops what git filled.
    try repo.exec(io, &.{ "status", "--porcelain" });
    try repo.exec(io, &.{ "config", "core.untrackedCache", "false" });
    {
        var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
        defer native.deinit(io);
        var locked = try native.lockIndex(io);
        defer locked.deinit(io);
        try std.testing.expect(locked.index.untracked == null);
        try locked.commit(io);
    }
    const dropped = try indexBytes(&repo);
    defer gpa.free(dropped);
    try std.testing.expect(rawExtension(dropped, "UNTR") == null);
}

test "a path that joins or leaves the index invalidates git's directories, and git's status stays right" {
    const Change = struct { add: []const []const u8, remove: []const []const u8 };
    const changes = [_]Change{
        .{ .add = &.{"u.txt"}, .remove = &.{} },
        .{ .add = &.{"dir/deep/u.txt"}, .remove = &.{} },
        .{ .add = &.{"new/a.txt"}, .remove = &.{} },
        .{ .add = &.{}, .remove = &.{"dir/deep/t.txt"} },
        .{ .add = &.{}, .remove = &.{"t.txt"} },
        .{ .add = &.{"dir/u.txt"}, .remove = &.{"dir/t.txt"} },
    };
    for ([_][]const u8{ "normal", "all" }) |mode| for (changes, 0..) |change, n| {
        var theirs = try fixture();
        defer theirs.deinit();
        var ours = try fixture();
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |repo| {
            try repo.exec(io, &.{ "config", "status.showUntrackedFiles", mode });
            try repo.exec(io, &.{ "-c", "core.untrackedCache=true", "status", "--porcelain" });
        }
        for (change.add) |path| try theirs.exec(io, &.{ "add", path });
        for (change.remove) |path| try theirs.exec(io, &.{ "rm", "-q", "--cached", path });
        {
            var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
            defer native.deinit(io);
            var locked = try native.lockIndex(io);
            defer locked.deinit(io);
            for (change.add) |path| _ = try worktree.addAll(gpa, io, ours.dir, .{ .index = &locked.index, .db = native.objectDatabase() }, .{ .rules = try native.worktreeRules(), .prefix = path });
            for (change.remove) |path| {
                if (locked.index.cache_tree) |*tree| tree.invalidate(path);
                _ = locked.index.remove(path);
            }
            try locked.commit(io);
        }

        var described: [2]std.ArrayList(u8) = .{ .empty, .empty };
        defer for (&described) |*d| d.deinit(gpa);
        for ([_]*testgit.Repo{ &theirs, &ours }, &described) |repo, *out| {
            var index = try readIndex(repo);
            defer index.deinit();
            try describe(out, &(index.untracked orelse return error.TestExpectedCache));
        }
        std.testing.expectEqualStrings(described[0].items, described[1].items) catch |err| {
            std.debug.print("untracked case {d}, {s}\n", .{ n, mode });
            return err;
        };
        const want = try theirs.run(io, &.{ "-c", "core.untrackedCache=true", "status", "--porcelain" });
        defer gpa.free(want);
        const got = try ours.run(io, &.{ "-c", "core.untrackedCache=true", "status", "--porcelain" });
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
    };
}
