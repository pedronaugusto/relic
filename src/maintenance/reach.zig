//! What git counts as reached, for `prune` (`reachable.c`'s
//! `mark_reachable_objects`) and for `repack` (`pack-objects --all
//! --reflog --indexed-objects`): every ref, every worktree's `HEAD`, index
//! and reflog entries, and for prune every rebase's state; then, for prune
//! and a cruft pack, the recent objects and what they reach.

const Self = @This();
const std = @import("std");
const date = @import("../text.zig").date;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const object_walk = @import("../walk/object.zig").walk;
const program = @import("../process/program.zig");
const Repository = repo_mod.Repository;

/// Failures of finding what is reached.
pub const Error = repo_mod.Error || refs_error || object_walk.Error || index_mod.ReadError || config_mod.ValueError || error{
    /// `gc.recentObjectsHook` is set and no `program.Programs` was given to
    /// run it.
    ProgramsNotGranted,
    /// A `gc.recentObjectsHook` command could not start, or ended with a
    /// failure: git dies, "unable to enumerate additional recent objects".
    RecentObjectsHookFailed,
    /// A line of a `gc.recentObjectsHook` command's output that is not one
    /// object name alone: git's "invalid extra cruft tip".
    InvalidRecentObject,
    /// A bare `gc.recentObjectsHook`, with no command. git reports it and
    /// runs none of the hooks; relic refuses rather than drop objects the
    /// others were set to keep.
    MissingValue,
};

const refs_error = @import("../refs/refs.zig").Store.ReadLogError;

/// What `reachableObjects` counts as reached.
pub const ReachOptions = struct {
    /// Objects kept besides what the repository names.
    heads: []const Oid = &.{},
    /// Unreached objects of this repository's own directory whose time is
    /// after this are kept, and what they reach as far as it is there:
    /// git's `mark_recent`, a cruft pack's objects each by its own time.
    /// So are those a `gc.recentObjectsHook` command names, whatever their
    /// time. 0 keeps none, and runs no hook.
    recent: date.Expiry = 0,
    /// What runs the `gc.recentObjectsHook` commands. With none given and
    /// a hook set, `error.ProgramsNotGranted`.
    programs: ?program.Programs = null,
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
    const starts = try collectStarts(gpa, arena, io, repo, .{ .heads = options.heads, .rebase_state = true });

    var reached: Oid.Set = .empty;
    errdefer reached.deinit(gpa);
    for (starts.blobs) |blob| try reached.put(gpa, blob.oid, {});
    {
        var walked = try object_walk.missing(gpa, io, repo.objectDatabase(), starts.roots, .{});
        defer walked.deinit();
        for (walked.entries) |entry| try reached.put(gpa, entry.oid, {});
    }
    if (options.recent != 0) try addRecent(gpa, io, repo, arena, &reached, starts.roots, options);
    return reached;
}

/// What a walk of everything reached starts from: the commits, trees and
/// tags named, and the index's blobs, which nothing walks below.
pub const Starts = struct {
    roots: []const Oid,
    blobs: []const Blob,

    /// A blob an index names, and the path it is at there.
    pub const Blob = struct { oid: Oid, path: []const u8 };
};

/// What `collectStarts` starts from.
pub const StartOptions = struct {
    heads: []const Oid = &.{},
    /// Every rebase's `autostash` and `orig-head`, which `prune` keeps
    /// (`add_rebase_files`) and `pack-objects --all` does not.
    rebase_state: bool,
};

/// Every worktree's index, every ref, every worktree's `HEAD`, the rebase
/// state as asked, every reflog entry whose object is there: what git's
/// reachability walks start from, in `arena`.
pub fn collectStarts(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, options: StartOptions) Self.Error!Starts {
    const db = repo.objectDatabase();
    const store = repo.refStore();
    var roots: std.ArrayList(Oid) = .empty;
    var blobs: std.ArrayList(Starts.Blob) = .empty;
    try roots.appendSlice(arena, options.heads);
    // Every worktree's index: this one's, the main worktree's from a
    // linked one, and every other linked worktree's.
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        try addIndex(arena, &index, &blobs, &roots);
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
        try addIndex(arena, &index, &blobs, &roots);
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
    if (options.rebase_state) {
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

    return .{ .roots = roots.items, .blobs = blobs.items };
}

/// git's `pack-objects --all --reflog --indexed-objects`: every object
/// `collectStarts` reaches without the rebase state, as a set to pack,
/// each with the path it was found at as its delta hint; `odb.Odb.Collected`
/// is the caller's.
pub fn reachableToPack(gpa: Allocator, io: Io, repo: *Repository, filter: object_walk.Filter) Self.Error!odb_mod.Odb.Collected {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const starts = try collectStarts(gpa, arena_instance.allocator(), io, repo, .{ .rebase_state = false });
    var walked = try object_walk.missing(gpa, io, repo.objectDatabase(), starts.roots, .{ .filter = filter });
    errdefer walked.deinit();
    if (starts.blobs.len == 0) return walked;
    const out = walked.arena.allocator();
    var seen: Oid.Set = .empty;
    defer seen.deinit(gpa);
    for (walked.entries) |entry| try seen.put(gpa, entry.oid, {});
    var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
    try entries.appendSlice(out, walked.entries);
    for (starts.blobs) |blob| {
        if ((try seen.fetchPut(gpa, blob.oid, {})) != null) continue;
        try entries.append(out, .{ .oid = blob.oid, .hint = try out.dupe(u8, blob.path) });
    }
    walked.entries = entries.items;
    return walked;
}

/// git's `add_unseen_recent_objects_to_traversal` for `mark_recent`: each
/// object of this repository's own directory newer than `options.recent`,
/// or named by a `gc.recentObjectsHook` command, that `reached` lacks, and
/// what it reaches short of `roots`, go into `reached`.
fn addRecent(gpa: Allocator, io: Io, repo: *Repository, arena: Allocator, reached: *Oid.Set, roots: []const Oid, options: ReachOptions) Self.Error!void {
    const db = repo.objectDatabase();
    const timed = try db.timedObjects(gpa, io, .{});
    defer gpa.free(timed);
    var hooked: ?Oid.Set = null;
    defer if (hooked) |*set| set.deinit(gpa);
    var unseen: std.ArrayList(Oid) = .empty;
    for (timed) |object| {
        if (object.time <= options.recent) {
            // git runs the hooks once, at the first object too old to
            // be recent by its time, reached or not.
            if (hooked == null) hooked = try hookedObjects(gpa, io, repo, options.programs);
            if (!hooked.?.contains(object.oid)) continue;
        }
        if (reached.contains(object.oid)) continue;
        try unseen.append(arena, object.oid);
    }
    if (unseen.items.len != 0) {
        // What the refs reach is walked already: the walk stops there.
        var walked = try object_walk.missing(gpa, io, db, unseen.items, .{ .exclude = roots, .ignore_missing_links = true });
        defer walked.deinit();
        for (walked.entries) |entry| try reached.put(gpa, entry.oid, {});
    }
}

/// git's `load_gc_recent_objects`: the objects every `gc.recentObjectsHook`
/// command names, each value run in turn through the shell where git runs,
/// one object name alone on each line it prints, in a set the caller owns.
/// A name that is not here counts for nothing, as in git.
pub fn hookedObjects(gpa: Allocator, io: Io, repo: *Repository, programs: ?program.Programs) Self.Error!Oid.Set {
    var set: Oid.Set = .empty;
    errdefer set.deinit(gpa);
    var it = repo.configuration().iterate(&.{"gc.recentobjectshook"});
    while (it.next()) |entry| {
        const command = entry.value orelse return error.MissingValue;
        var outcome = program.run(gpa, io, programs orelse return error.ProgramsNotGranted, .{
            .argv = &.{command},
            .shell = true,
            .cwd = .{ .dir = repo.topDirectory() },
            .unset = &program.repository_variables,
            .stderr = .inherit,
        }, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.RecentObjectsHookFailed,
        };
        defer outcome.deinit(gpa);
        // git's `strbuf_getline`: a line ends at a line feed, with a
        // carriage return before it dropped, and the last needs none.
        var lines = std.mem.splitScalar(u8, outcome.stdout, '\n');
        while (lines.next()) |raw| {
            if (lines.peek() == null and raw.len == 0) break;
            const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            const oid = Oid.parse(repo.objectFormat(), line) catch return error.InvalidRecentObject;
            try set.put(gpa, oid, {});
        }
        if (!outcome.succeeded()) return error.RecentObjectsHookFailed;
    }
    return set;
}

/// git's `do_add_index_objects_to_pending`: each entry's blob (a sparse
/// directory's tree is walked), each valid cache-tree node's tree, each
/// resolve-undo stage's blob. A submodule's commit is not this
/// repository's.
fn addIndex(arena: Allocator, index: *const index_mod.Index, blobs: *std.ArrayList(Starts.Blob), roots: *std.ArrayList(Oid)) Allocator.Error!void {
    for (index.entries.items) |entry| switch (entry.mode) {
        .gitlink => {},
        .tree => try roots.append(arena, entry.oid),
        else => try blobs.append(arena, .{ .oid = entry.oid, .path = try arena.dupe(u8, entry.path) }),
    };
    if (index.cache_tree) |*tree| try addCacheTree(arena, &tree.root, roots);
    if (index.resolve_undo) |*undo| for (undo.entries.items) |item| for (item.oids) |maybe| {
        if (maybe) |oid| try blobs.append(arena, .{ .oid = oid, .path = try arena.dupe(u8, item.path) });
    };
}

fn addCacheTree(arena: Allocator, node: *const index_mod.CacheTreeNode, roots: *std.ArrayList(Oid)) Allocator.Error!void {
    if (node.isValid()) try roots.append(arena, node.oid.?);
    for (node.children.items) |*child| try addCacheTree(arena, child, roots);
}
