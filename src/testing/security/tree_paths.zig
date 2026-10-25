//! A tree whose names git's `verify_path` refuses -- `..`, an absolute name,
//! `.git` in any spelling a protected file system opens as it -- or that
//! reaches through a symbolic link, delivered as a fetched history delivers
//! one. git refuses each at unpack-trees and at index add, before the
//! working tree is touched. relic 0.29.1 and before let `reset --hard` and a
//! merge delete such a path's directory first, and let an index take it.
//!
//! The repository is a directory inside the test's own temporary one, so a
//! name that climbs out of it reaches a victim the test owns.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("../git.zig");
const hostile = @import("hostile.zig");
const hash = @import("../../hash/hash.zig");
const repo_mod = @import("../../repo/repo.zig");
const worktree = @import("../../checkout/checkout.zig");
const reset = @import("../../commit/reset.zig");
const three_way = @import("../../merge/three_way.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// What each hostile name must leave alone: a directory beside the
/// repository, one inside its working tree, and its git directory.
const sentinels = [_][]const u8{ "victim/untracked", "repo/inside/untracked", "repo/.git/HEAD" };

const Fixture = struct {
    outer: testgit.Repo,
    /// The temporary directory's own path, for an absolute name.
    root: []u8,

    fn init(gpa: Allocator, io: Io) !Fixture {
        var outer = try testgit.Repo.init(gpa, io, &.{});
        errdefer outer.deinit();
        try outer.exec(io, &.{ "init", "-q", "repo" });
        // Every spelling git's own tests refuse is refused here too.
        try outer.exec(io, &.{ "-C", "repo", "config", "core.protectHFS", "true" });
        try outer.exec(io, &.{ "-C", "repo", "config", "core.protectNTFS", "true" });
        try outer.writeFile(io, "repo/file", "base\n");
        try outer.exec(io, &.{ "-C", "repo", "add", "-A" });
        try outer.exec(io, &.{ "-C", "repo", "commit", "-qm", "base" });
        try outer.writeFile(io, "victim/untracked", "mine\n");
        try outer.writeFile(io, "repo/inside/untracked", "mine\n");
        try outer.dir.createDirPath(io, "repo/a");
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const len = try outer.dir.realPath(io, &buf);
        return .{ .outer = outer, .root = try gpa.dupe(u8, buf[0..len]) };
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        gpa.free(f.root);
        f.outer.deinit();
    }

    /// Every sentinel still holds what it was given.
    fn expectSentinels(f: *Fixture, gpa: Allocator, io: Io) !void {
        var gone = false;
        for (sentinels) |path| {
            const bytes = f.outer.dir.readFileAlloc(io, path, gpa, .limited(4096)) catch |err| {
                std.debug.print("{s} is gone: {t}\n", .{ path, err });
                gone = true;
                continue;
            };
            gpa.free(bytes);
        }
        if (gone) return error.TestSentinelGone;
    }
};

/// The names, each one entry of a tree: climbing out, absolute, through a
/// directory, and `.git` as git, HFS+ and NTFS spell it.
fn hostileNames(arena: Allocator, root: []const u8) ![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "../victim",
        "a/../../victim",
        "a/../inside",
        try arena.print("{s}/victim", .{root}),
        ".git",
        ".GIT",
        ".g\u{200c}it",
        "git~1",
        ".git/hooks/post-checkout",
    });
}

/// A commit-less tree holding `name`, a directory where `mode` is one.
fn treeWith(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) !Oid {
    const db = repo.objectDatabase();
    const blob = try db.write(io, .blob, "hostile\n");
    return hostile.rawTree(gpa, io, db, &.{.{ .mode = "100644", .name = name, .oid = blob }});
}

fn headTree(gpa: Allocator, io: Io, f: *Fixture) !Oid {
    const text = try f.outer.run(io, &.{ "-C", "repo", "rev-parse", "HEAD^{tree}" });
    defer gpa.free(text);
    return Oid.parse(.sha1, std.mem.trim(u8, text, "\r\n"));
}

test "a tree path git's verify_path refuses is refused before reset --hard deletes anything" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (try hostileNames(arena_state.allocator(), f.root)) |name| {
        var dir = try f.outer.dir.openDir(io, "repo", .{});
        defer dir.close(io);
        var repo = try Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        const tree = try treeWith(gpa, io, &repo, name);
        var index = try repo.openIndex(io);
        defer index.deinit();
        std.testing.expectError(error.UnsafePath, reset.toTree(gpa, io, &repo, .{ .index = &index, .tree = tree, .mode = .hard })) catch |err| {
            std.debug.print("reset --hard to a tree holding '{s}'\n", .{name});
            return err;
        };
        try f.expectSentinels(gpa, io);
    }
}

test "a tree path git's verify_path refuses is refused before a merge touches the working tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    const base = try headTree(gpa, io, &f);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (try hostileNames(arena_state.allocator(), f.root)) |name| {
        var dir = try f.outer.dir.openDir(io, "repo", .{});
        defer dir.close(io);
        var repo = try Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        const theirs = try treeWith(gpa, io, &repo, name);
        var index = try repo.openIndex(io);
        defer index.deinit();
        const merged = three_way.apply(gpa, io, &repo, .{ .index = &index, .base = base, .ours = base, .theirs = theirs }, .{});
        if (merged) |_| {
            std.debug.print("a merge of a tree holding '{s}' was written\n", .{name});
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.UnsafePath => {},
            else => {
                std.debug.print("a merge of a tree holding '{s}': {t}\n", .{ name, err });
                return err;
            },
        }
        try f.expectSentinels(gpa, io);
    }
}

test "an index refuses a tree path git's verify_path refuses, as git's add_index_entry does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (try hostileNames(arena_state.allocator(), f.root)) |name| {
        var dir = try f.outer.dir.openDir(io, "repo", .{});
        defer dir.close(io);
        var repo = try Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        const tree = try treeWith(gpa, io, &repo, name);
        var index = try repo.openIndex(io);
        defer index.deinit();
        std.testing.expectError(error.UnsafePath, worktree.resetIndex(gpa, io, &index, repo.objectDatabase(), tree)) catch |err| {
            std.debug.print("an index reset to a tree holding '{s}'\n", .{name});
            return err;
        };
        for (index.entries.items) |e| try std.testing.expect(!std.mem.eql(u8, e.path, name));
    }
}

test "reset --hard deletes nothing through a symbolic link in the working tree" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    // An untracked link to the directory above the repository: the tree's
    // `link/victim` is the victim beside it.
    try f.outer.dir.symLink(io, "..", "repo/link", .{ .is_directory = true });
    var dir = try f.outer.dir.openDir(io, "repo", .{});
    defer dir.close(io);
    var repo = try Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    const tree = try treeWith(gpa, io, &repo, "link/victim");
    var index = try repo.openIndex(io);
    defer index.deinit();
    // glint-ignore: Z026 -- what is asserted is that nothing outside is deleted; which refusal the write through the link meets is the checkout's
    _ = reset.toTree(gpa, io, &repo, .{ .index = &index, .tree = tree, .mode = .hard }) catch {};
    try f.expectSentinels(gpa, io);
}
