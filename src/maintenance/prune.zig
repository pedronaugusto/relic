//! git's `prune`: the loose objects nothing reaches go, with what
//! `reachable.c` counts as reached -- every ref, every worktree's `HEAD`,
//! index and rebase state, every reflog entry -- and the recent objects
//! that are spared with what they reach.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const object_walk = @import("../walk/object.zig").walk;
const gc = @import("gc.zig");
const date = @import("../text.zig").date;
const Repository = repo_mod.Repository;

/// Failures of `prune` and `reachableObjects`.
pub const Error = gc.Error || object_walk.Error || index_mod.ReadError || Repository.WriteShallowError || config_mod.ValueError || error{
    /// `extensions.preciousObjects` is set: git refuses to prune.
    PreciousObjects,
    /// A rebase's `autostash` or `orig-head` names no object git reads.
    InvalidRebaseState,
};

/// How `prune` runs: git's `prune` options.
pub const PruneOptions = struct {
    /// `--expire`: an unreachable loose object, or a temporary file, whose
    /// time is not after this goes, and unreachable objects newer than it
    /// are spared with what they reach. git's default takes every one;
    /// `gc` passes `gc.pruneExpire` (`pruneExpiry`).
    expire: gc.Expiry = gc.expire_all,
    /// `<head>...`: objects kept as if a ref named them.
    heads: []const Oid = &.{},
    /// `-n`: report and remove nothing.
    dry_run: bool = false,
};

/// What `prune` removed, or with `dry_run` would have.
pub const Report = struct {
    objects: odb_mod.Odb.PruneReport,
    /// Commits taken out of `.git/shallow`, which nothing reaches now.
    shallow_removed: u32 = 0,
};

/// git's `prune`: every loose object of this repository's own directory
/// that `reachableObjects` does not keep and whose time is not after
/// `expire` goes, then those a pack also holds, then stale temporary files;
/// in a shallow repository the boundary commits nothing reaches leave
/// `.git/shallow`.
pub fn prune(gpa: Allocator, io: Io, repo: *Repository, options: PruneOptions) Self.Error!Report {
    if (try repo.configuration().getBool("extensions.preciousobjects", false)) return error.PreciousObjects;
    var keep = try reachableObjects(gpa, io, repo, .{ .heads = options.heads, .recent = options.expire });
    defer keep.deinit(gpa);
    var report: Report = .{ .objects = try repo.objectDatabase().prune(io, .{ .keep = &keep, .expire = options.expire, .dry_run = options.dry_run }) };
    const db = repo.objectDatabase();
    if (db.shallow.count() != 0) {
        var gone: std.ArrayList(Oid) = .empty;
        defer gone.deinit(gpa);
        var it = db.shallow.keyIterator();
        while (it.next()) |oid| if (!keep.contains(oid.*)) try gone.append(gpa, oid.*);
        report.shallow_removed = @intCast(gone.items.len);
        if (!options.dry_run) {
            for (gone.items) |oid| _ = db.shallow.remove(oid);
            try repo.writeShallow(io);
        }
    }
    return report;
}

/// `gc.pruneExpire` as git's `gc` reads it: `2.weeks.ago` when unset,
/// `null` for `never`, which runs no prune.
pub fn pruneExpiry(repo: *Repository, clock: date.Context) Self.Error!?gc.Expiry {
    const value = repo.configuration().get("gc.pruneexpire") orelse "2.weeks.ago";
    const expiry = gc.parseExpiry(value, clock) orelse return error.InvalidExpiryDate;
    return if (expiry == 0) null else expiry;
}

/// What `reachableObjects` counts as reached.
pub const ReachOptions = struct {
    /// Objects kept besides what the repository names.
    heads: []const Oid = &.{},
    /// Unreached objects of this repository's own directory whose time is
    /// after this are kept, and what they reach as far as it is there:
    /// git's `mark_recent`. 0 keeps none.
    recent: gc.Expiry = 0,
};

/// git's `mark_reachable_objects` with the reflogs: the objects every
/// worktree's index (its cache-tree and resolve-undo too), every ref,
/// every worktree's `HEAD`, every rebase's `autostash` and `orig-head`,
/// every reflog entry and `heads` reach, as a set the caller owns; then
/// the recent ones and what they reach. An object a ref or the index
/// names that is missing, or one missing below it, is an error, as git
/// dies on it; a reflog's missing object is passed over, as are missing
/// objects below a recent one.
pub fn reachableObjects(gpa: Allocator, io: Io, repo: *Repository, options: ReachOptions) Self.Error!Oid.Set {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const db = repo.objectDatabase();
    const store = repo.refStore();

    var reached: Oid.Set = .empty;
    errdefer reached.deinit(gpa);
    var roots: std.ArrayList(Oid) = .empty;
    try roots.appendSlice(arena, options.heads);

    // Every worktree's index: this one's, the main worktree's from a
    // linked one, and every other linked worktree's.
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        try addIndex(gpa, arena, &index, &reached, &roots);
    }
    const others = try store.otherWorktrees(arena, io);
    var admin_paths: std.ArrayList([]const u8) = .empty;
    if (repo.isLinkedWorktree()) try admin_paths.append(arena, ".");
    for (others) |id| try admin_paths.append(arena, try arena.print("worktrees/{s}", .{id}));
    for (admin_paths.items) |admin| {
        const path = try std.fs.path.join(arena, &.{ admin, "index" });
        var index = repo.openIndexAt(io, repo.commonDirectory(), path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer index.deinit();
        try addIndex(gpa, arena, &index, &reached, &roots);
    }

    // Every ref, and every worktree's `HEAD`.
    {
        var listed = try store.list(gpa, io, "refs/");
        defer listed.deinit();
        for (listed.entries) |entry| switch (entry.target) {
            .direct => |oid| try roots.append(arena, oid),
            .symbolic => if (try store.resolve(arena, io, entry.name)) |resolved| try roots.append(arena, resolved.oid),
        };
    }
    var heads: std.ArrayList([]const u8) = .empty;
    try heads.append(arena, "HEAD");
    if (repo.isLinkedWorktree()) try heads.append(arena, "main-worktree/HEAD");
    for (others) |id| try heads.append(arena, try arena.print("worktrees/{s}/HEAD", .{id}));
    for (heads.items) |name| if (try store.resolve(arena, io, name)) |resolved| try roots.append(arena, resolved.oid);

    // Every worktree's rebase state: git's `add_rebase_files`.
    {
        var git_dirs: std.ArrayList(Io.Dir) = .empty;
        try git_dirs.append(arena, repo.gitDirectory());
        if (repo.isLinkedWorktree()) try git_dirs.append(arena, repo.commonDirectory());
        var opened: std.ArrayList(Io.Dir) = .empty;
        defer for (opened.items) |d| d.close(io);
        for (others) |id| {
            const dir = repo.commonDirectory().openDir(io, try arena.print("worktrees/{s}", .{id}), .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            try opened.append(arena, dir);
            try git_dirs.append(arena, dir);
        }
        for (git_dirs.items) |dir| for ([_][]const u8{ "rebase-apply/autostash", "rebase-apply/orig-head", "rebase-merge/autostash", "rebase-merge/orig-head" }) |file| {
            const text = dir.readFileAlloc(io, file, arena, .limited(4096)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            const line = std.mem.trim(u8, text, " \t\r\n");
            if (line.len == 0) continue;
            // git's `get_oid_hex`: the name at the start, what follows it
            // not looked at.
            const hex_len = repo.objectFormat().hexLen();
            if (line.len < hex_len) continue;
            const oid = Oid.parse(repo.objectFormat(), line[0..hex_len]) catch continue;
            try roots.append(arena, oid);
        };
    }

    // Every reflog entry whose object is there.
    var logged: std.ArrayList(Oid) = .empty;
    for (try store.logNames(gpa, arena, io, .{ .every_worktree = true })) |name| {
        var log = try store.readLog(gpa, io, name);
        defer log.deinit();
        for (log.entries) |entry| for ([_]Oid{ entry.old, entry.new }) |oid| {
            if (oid.isZero() or !try db.exists(io, oid)) continue;
            try logged.append(arena, oid);
        };
    }
    try roots.appendSlice(arena, logged.items);

    {
        var walked = try object_walk.missing(gpa, io, db, roots.items, .{});
        defer walked.deinit();
        for (walked.entries) |entry| try reached.put(gpa, entry.oid, {});
    }

    if (options.recent != 0) {
        const recent = try db.recentObjects(gpa, io, options.recent);
        defer gpa.free(recent);
        var unseen: std.ArrayList(Oid) = .empty;
        for (recent) |oid| if (!reached.contains(oid)) try unseen.append(arena, oid);
        if (unseen.items.len != 0) {
            // What the refs reach is walked already: the walk stops there.
            var walked = try object_walk.missing(gpa, io, db, unseen.items, .{ .exclude = roots.items, .ignore_missing_links = true });
            defer walked.deinit();
            for (walked.entries) |entry| try reached.put(gpa, entry.oid, {});
        }
    }
    return reached;
}

/// git's `do_add_index_objects_to_pending`: each entry's blob (a sparse
/// directory's tree is walked), each valid cache-tree node's tree, each
/// resolve-undo stage's blob. A submodule's commit is not this
/// repository's.
fn addIndex(gpa: Allocator, arena: Allocator, index: *const index_mod.Index, reached: *Oid.Set, roots: *std.ArrayList(Oid)) Allocator.Error!void {
    for (index.entries.items) |entry| switch (entry.mode) {
        .gitlink => {},
        .tree => try roots.append(arena, entry.oid),
        else => try reached.put(gpa, entry.oid, {}),
    };
    if (index.cache_tree) |*tree| try addCacheTree(arena, &tree.root, roots);
    if (index.resolve_undo) |*undo| for (undo.entries.items) |item| for (item.oids) |maybe| {
        if (maybe) |oid| try reached.put(gpa, oid, {});
    };
}

fn addCacheTree(arena: Allocator, node: *const index_mod.CacheTreeNode, roots: *std.ArrayList(Oid)) Allocator.Error!void {
    if (node.isValid()) try roots.append(arena, node.oid.?);
    for (node.children.items) |*child| try addCacheTree(arena, child, roots);
}
