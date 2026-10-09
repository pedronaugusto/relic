//! What the security suite builds its hostile inputs with: a repository
//! made by the machine's git, its object database open to relic, and trees
//! written byte for byte, so that a name no well-behaved git writes can
//! still reach relic the way a crafted history delivers it.

const std = @import("std");
const path_mod = @import("../../names/path.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("../git.zig");
const hash = @import("../../hash/hash.zig");
const odb_mod = @import("../../odb/odb.zig");
const index_mod = @import("../../index/index.zig");
const worktree = @import("../../checkout/checkout.zig");
const ignore = @import("../../patterns/ignore.zig");
const attributes = @import("../../patterns/attributes.zig");
const repo_mod = @import("../../repo/repo.zig");
const submodule = @import("../../submodule/submodule.zig");

const Oid = hash.Oid;

/// A repository and the stores a checkout writes through.
pub const Harness = struct {
    repo: testgit.Repo,
    git_dir: Io.Dir,
    db: odb_mod.Odb,
    index: index_mod.Index,
    rules: ignore.Rules,
    attrs: attributes.Attrs,

    pub fn init(gpa: Allocator, io: Io) !Harness {
        var repo = try testgit.Repo.init(gpa, io, &.{});
        errdefer repo.deinit();
        const git_dir = try repo.gitDir(io);
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
        errdefer db.deinit(io);
        return .{
            .repo = repo,
            .git_dir = git_dir,
            .db = db,
            .index = index_mod.Index.initEmpty(gpa, .sha1),
            .rules = try ignore.Rules.init(gpa, .{ .case_fold = false }),
            .attrs = try attributes.Attrs.init(gpa, .{ .case_fold = false }),
        };
    }

    pub fn deinit(h: *Harness, io: Io) void {
        h.attrs.deinit();
        h.rules.deinit();
        h.index.deinit();
        h.db.deinit(io);
        h.git_dir.close(io);
        h.repo.deinit();
        h.* = undefined;
    }

    pub fn worktreeRules(h: *Harness) worktree.Rules {
        return .{ .ignore = &h.rules, .attrs = &h.attrs };
    }

    /// Check `root` out into the working tree, and say which rule refused
    /// it, or `null` when it was written.
    pub fn checkout(h: *Harness, gpa: Allocator, io: Io, root: Oid) !?path_mod.Reason {
        var refusal: worktree.Refusal = .{};
        _ = worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = root }, .{
            .rules = h.worktreeRules(),
            .refusal = &refusal,
        }) catch |err| switch (err) {
            error.UnsafePath => return refusal.reason orelse error.TestUnexpectedResult,
            else => return err,
        };
        return null;
    }

    pub fn blob(h: *Harness, io: Io, bytes: []const u8) !Oid {
        return h.db.write(io, .blob, bytes);
    }

    pub fn writeTree(h: *Harness, gpa: Allocator, io: Io, entries: []const Entry) !Oid {
        return rawTree(gpa, io, &h.db, entries);
    }
};

/// One tree entry as it is stored: the mode's text, the name, the object.
pub const Entry = struct { mode: []const u8, name: []const u8, oid: Oid };

/// A tree with exactly these entries, in this order, whatever their names.
pub fn rawTree(gpa: Allocator, io: Io, db: *odb_mod.Odb, entries: []const Entry) !Oid {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (entries) |e| {
        try bytes.print(gpa, "{s} {s}\x00", .{ e.mode, e.name });
        try bytes.appendSlice(gpa, e.oid.raw());
    }
    return db.write(io, .tree, bytes.items);
}

/// The bytes of a tree with these entries, for a check that reads them.
pub fn treeBytes(gpa: Allocator, entries: []const Entry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    for (entries) |e| {
        try bytes.print(gpa, "{s} {s}\x00", .{ e.mode, e.name });
        try bytes.appendSlice(gpa, e.oid.raw());
    }
    return bytes.toOwnedSlice(gpa);
}

/// A submodule transport that clones with the machine's git, as the
/// suite's submodule tests do.
pub const GitClone = struct {
    git: *testgit.Repo,
    clones: u32 = 0,

    pub fn seam(t: *GitClone) submodule.Transport {
        return .{ .context = t, .cloneFn = clone, .fetchFn = fetch };
    }

    fn clone(gpa: std.mem.Allocator, io: Io, context: *anyopaque, url: []const u8, git_dir: Io.Dir) submodule.TransportError!void {
        const t: *GitClone = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a GitClone
        const target = git_dir.realPathFileAlloc(io, ".", gpa) catch return error.TransportFailed;
        defer gpa.free(target);
        t.git.exec(io, &.{ "clone", "-q", "--bare", url, target }) catch return error.TransportFailed;
        t.git.exec(io, &.{ "--git-dir", target, "config", "core.bare", "false" }) catch return error.TransportFailed;
        t.clones += 1;
    }

    fn fetch(_: std.mem.Allocator, _: Io, _: *anyopaque, _: *repo_mod.Repository, _: []const u8, _: Oid) submodule.TransportError!void {
        return error.TransportFailed;
    }
};
