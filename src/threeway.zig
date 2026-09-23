//! A merge of three trees carried into the index and the working tree.
//!
//! Every command that edits history does this one step: git's merge,
//! cherry-pick, revert and rebase all merge two trees against a third and
//! leave the result where a person works. A resolved path is staged and
//! written; a conflicted one is left at stages 1, 2 and 3 with the
//! conflict-marked text in the file. What the step must never do is lose
//! work, so everything it would overwrite is checked before anything is
//! written: something staged is refused, as is a change in the working tree
//! to a path the merge rewrites or removes, and an untracked file where the
//! merge puts one. A path the merge does not touch keeps whatever changes it
//! has, and an ignored file in the way is replaced, both as in git.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const merge = @import("merge.zig");
const worktree = @import("worktree.zig");
const attributes = @import("attributes.zig");
const ignore = @import("ignore.zig");
const fs = @import("fs.zig");
const repo_mod = @import("repo.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Repository = repo_mod.Repository;

/// Errors from carrying a merge into the working tree.
pub const Error = error{
    /// The index already holds a conflict, which has to be resolved first.
    UnmergedIndex,
    /// The index does not describe the tree the merge starts from:
    /// something is staged.
    DirtyIndex,
    /// A path the merge rewrites or removes has changes in the working tree.
    LocalChangesWouldBeOverwritten,
    /// A file meets a directory and neither goes away. git moves the file
    /// aside to `<path>~<side>`, which this release does not.
    DirectoryFileConflict,
    /// The two sides hold different kinds of thing at one path -- a file and
    /// a symlink, say. git moves one of them aside, which this release does
    /// not.
    DistinctTypesConflict,
    /// Both sides moved a submodule to different commits. git merges them
    /// inside the submodule's own repository, which this release does not.
    SubmoduleConflict,
    /// The repository has no working tree.
    BareRepository,
} || merge.Error || worktree.Error || repo_mod.Error;

/// Where a refusal writes the path that caused it, so a caller can say which
/// file stood in the way without anything being allocated.
pub const Blocked = merge.Blocked;

/// How a merge is carried out.
pub const Options = struct {
    /// Labels, conflict style and favoured side for the content merges.
    /// The algorithm is histogram, which is what git's merge machinery
    /// diffs with.
    blob: merge.BlobOptions = .{ .algorithm = .histogram },
    /// Where a refusal writes the path that caused it.
    blocked: ?*Blocked = null,
};

/// One conflicted path.
pub const Conflict = struct {
    /// Owned by the outcome.
    path: []const u8,
    kind: merge.Conflict.Kind,
};

/// What a merge left behind.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// Sorted by path. Empty when the merge was clean.
    conflicts: []Conflict,
    /// The merged tree, when the merge was clean.
    tree: ?Oid,
    /// The tree of the working tree's merged state, markers and all: what
    /// git records as `AUTO_MERGE`. The merged tree when the merge was clean.
    auto_merge: Oid,
    /// Files written into the working tree.
    written: u32,
    /// Files removed from it.
    removed: u32,

    /// Whether every path reconciled.
    pub fn isClean(o: *const Outcome) bool {
        return o.conflicts.len == 0;
    }

    /// Release the outcome.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

const TreeEntry = struct { mode: object.Mode, oid: Oid };

/// Merge `theirs` into `ours` against `base`, trees all, and leave the result
/// in `index` and the repository's working tree.
///
/// `index` must describe `ours` exactly, with nothing staged beyond it:
/// `ours` is `HEAD`'s tree for a command that commits the result, and the
/// index's own tree for one that only stages it. The caller writes the index
/// afterwards; nothing about `HEAD` or any ref moves here.
pub fn apply(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *Index,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
    options: Options,
) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = repo.work_dir orelse return error.BareRepository;
    const db = &repo.odb;

    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (options.blocked) |b| b.set(entry.path);
            return error.UnmergedIndex;
        }
    }

    // The index must be exactly `ours`.
    var our_entries = try worktree.flatten(arena, io, db, ours);
    for (index.entries.items) |entry| {
        const want = our_entries.get(entry.path);
        if (want == null or want.?.mode != entry.mode or !want.?.oid.eql(entry.oid) or entry.intent_to_add) {
            if (options.blocked) |b| b.set(entry.path);
            return error.DirtyIndex;
        }
    }
    if (index.entries.items.len != our_entries.count()) {
        var it = our_entries.keyIterator();
        while (it.next()) |path| {
            if (index.find(path.*) == null) {
                if (options.blocked) |b| b.set(path.*);
                return error.DirtyIndex;
            }
        }
    }

    var rules = repo.worktreeRules();
    rules.required_filters = try repo.requiredFilters(arena);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;

    const drivers = try configuredDrivers(arena, repo);
    var result = try merge.treesWithOptions(gpa, io, db, base, ours, theirs, .{
        .content_merge = true,
        .blob = options.blob,
        .attributes = &attrs,
        .attributes_dir = wt,
        .configured_drivers = drivers,
        .renames = configuredRenames(repo),
        .blocked = options.blocked,
    });
    defer result.deinit();

    for (result.conflicts) |conflict| {
        const refusal: ?Error = switch (conflict.kind) {
            .directory_file => error.DirectoryFileConflict,
            .distinct_types => error.DistinctTypesConflict,
            else => if (isGitlink(conflict.ours) or isGitlink(conflict.theirs)) error.SubmoduleConflict else null,
        };
        if (refusal) |err| {
            if (options.blocked) |b| b.set(conflict.path);
            return err;
        }
    }

    // What each path the merge touches should hold in the working tree.
    var desired: std.StringArrayHashMapUnmanaged(?TreeEntry) = .empty;
    for (result.index.entries.items) |entry| {
        if (entry.stage != 0) continue;
        try desired.put(arena, try arena.dupe(u8, entry.path), .{ .mode = entry.mode, .oid = entry.oid });
    }
    for (result.conflicts) |conflict| {
        const side = conflict.result orelse continue;
        try desired.put(arena, try arena.dupe(u8, conflict.path), .{ .mode = side.mode, .oid = side.oid });
    }
    var our_it = our_entries.keyIterator();
    while (our_it.next()) |path| {
        if (!desired.contains(path.*)) try desired.put(arena, path.*, null);
    }

    var changes: std.ArrayList([]const u8) = .empty;
    for (desired.keys(), desired.values()) |path, want| {
        const have = our_entries.get(path);
        if (sameEntry(have, want)) continue;
        try changes.append(arena, path);
    }
    std.mem.sort([]const u8, changes.items, {}, lessThanPath);

    // Nothing is written until every change has been checked.
    var ignore_rules: ?ignore.Rules = null;
    defer if (ignore_rules) |*r| r.deinit();
    var loaded_ignores: std.StringHashMapUnmanaged(void) = .empty;
    for (changes.items) |path| {
        const want = desired.get(path).?;
        if (our_entries.contains(path)) {
            const entry = index.find(path).?;
            if (entry.skip_worktree) continue;
            if (try differsOnDisk(gpa, io, wt, index, entry.*, rules)) {
                if (options.blocked) |b| b.set(path);
                return error.LocalChangesWouldBeOverwritten;
            }
            continue;
        }
        if (want == null) continue;
        // A new file: nothing untracked may stand where it goes, nor where
        // any directory above it goes.
        var at: usize = 0;
        while (true) {
            const slash = std.mem.indexOfScalarPos(u8, path, at, '/');
            const prefix = if (slash) |s| path[0..s] else path;
            const is_last = slash == null;
            if (try fs.statAt(io, wt, prefix)) |found| {
                const blocks = if (found.kind == .directory)
                    is_last and !try directoryGoes(arena, io, wt, prefix, &our_entries, &desired)
                else if (our_entries.contains(prefix))
                    desired.get(prefix).? != null
                else
                    !try isIgnored(repo, io, wt, &ignore_rules, &loaded_ignores, arena, prefix, found.kind == .directory);
                if (blocks) {
                    if (options.blocked) |b| b.set(prefix);
                    return error.UntrackedWouldBeOverwritten;
                }
            }
            at = (slash orelse break) + 1;
        }
    }

    // Removals first, so that a directory the merge turns into a file is
    // gone before the file is written.
    var outcome_removed: u32 = 0;
    var outcome_written: u32 = 0;
    var i = changes.items.len;
    while (i > 0) {
        i -= 1;
        const path = changes.items[i];
        if (desired.get(path).? != null) continue;
        const entry = index.find(path).?;
        if (entry.skip_worktree) continue;
        try worktree.removeEntry(io, wt, path);
        outcome_removed += 1;
    }

    var stats: std.StringHashMapUnmanaged(fs.Stat) = .empty;
    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    for (result.conflicts) |conflict| try conflicted.put(arena, conflict.path, {});
    for (changes.items) |path| {
        const want = (desired.get(path).?) orelse continue;
        if (index.find(path)) |entry| {
            // A clean change to a path outside the sparse patterns stays out
            // of the working tree; a conflict is brought in, because someone
            // has to resolve it.
            if (entry.skip_worktree and !conflicted.contains(path)) continue;
        }
        if (try fs.statAt(io, wt, path)) |found| {
            if (found.kind == .directory) wt.deleteTree(io, path) catch {};
        }
        const written = try worktree.writeEntry(gpa, io, wt, db, path, want.mode, want.oid, rules);
        try stats.put(arena, path, written.stat);
        outcome_written += 1;
    }

    // The new index: unchanged entries keep what the old index knew about
    // them, changed ones take the stat of what was just written, and a
    // conflict is its stages.
    var fresh: std.ArrayList(index_mod.Entry) = .empty;
    for (result.index.entries.items) |entry| {
        var copy = entry;
        copy.path = try arena.dupe(u8, entry.path);
        if (entry.stage == 0) {
            if (index.find(entry.path)) |old| {
                if (old.oid.eql(entry.oid) and old.mode == entry.mode) {
                    copy = old.*;
                    copy.path = try arena.dupe(u8, entry.path);
                } else {
                    copy.skip_worktree = old.skip_worktree;
                }
            }
            if (stats.get(entry.path)) |stat| copy.stat = stat;
        }
        try fresh.append(arena, copy);
    }
    index.clear();
    try index.addMany(fresh.items);
    const cache_tree = try index.cacheTree();
    cache_tree.invalidateAll();

    const conflicts = try arena.alloc(Conflict, result.conflicts.len);
    for (result.conflicts, conflicts) |conflict, *out| {
        out.* = .{ .path = try arena.dupe(u8, conflict.path), .kind = conflict.kind };
    }
    std.mem.sort(Conflict, conflicts, {}, lessThanConflict);

    var merged_tree: ?Oid = null;
    var auto_merge: Oid = undefined;
    if (result.isClean()) {
        merged_tree = merge.tree(io, db, &result) catch |err| switch (err) {
            error.MergeConflict => unreachable,
            else => |e| return e,
        };
        cache_tree.root.entry_count = @intCast(index.entries.items.len);
        cache_tree.root.oid = merged_tree.?;
        auto_merge = merged_tree.?;
    } else {
        auto_merge = try merge.conflictedTree(gpa, io, db, &result);
    }
    try db.syncBatch(io);

    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .conflicts = conflicts,
        .tree = merged_tree,
        .auto_merge = auto_merge,
        .written = outcome_written,
        .removed = outcome_removed,
    };
}

fn isGitlink(side: ?merge.Side) bool {
    return if (side) |s| s.mode == .gitlink else false;
}

fn sameEntry(a: anytype, b: ?TreeEntry) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.mode == b.?.mode and a.?.oid.eql(b.?.oid);
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanConflict(_: void, a: Conflict, b: Conflict) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Whether git's merge would follow renames: `merge.renames`, then
/// `diff.renames`, and on when neither says otherwise. `copies` is on.
fn configuredRenames(repo: *Repository) bool {
    for ([_][]const u8{ "merge.renames", "diff.renames" }) |key| {
        const text = repo.config.get(key) orelse continue;
        if (std.ascii.eqlIgnoreCase(text, "copies") or std.ascii.eqlIgnoreCase(text, "copy")) return true;
        return @import("config.zig").parseBool(text) catch true;
    }
    return true;
}

/// The names `merge.<name>.driver` configures.
fn configuredDrivers(arena: Allocator, repo: *Repository) Allocator.Error![]const []const u8 {
    const names = try repo.config.subsections(arena, "merge");
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const key = try std.fmt.allocPrint(arena, "merge.{s}.driver", .{name});
        if (repo.config.get(key) != null) try out.append(arena, name);
    }
    return out.items;
}

/// Whether the file at `entry.path` holds something other than what the
/// index says. A file that is not there has nothing to lose, which is how
/// git treats one deleted by hand.
pub fn differsOnDisk(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *const Index,
    entry: index_mod.Entry,
    rules: worktree.Rules,
) Error!bool {
    const found = (try fs.statAt(io, wt, entry.path)) orelse return false;
    if (found.kind == .directory) return true;
    const on_disk_mode: object.Mode = if (found.kind == .sym_link)
        .symlink
    else if (!rules.file_mode)
        (if (entry.mode == .exec) .exec else .file)
    else if (found.executable) .exec else .file;
    if (entry.mode == .gitlink) return false;
    if (on_disk_mode != entry.mode and !(entry.mode == .symlink and !rules.symlinks)) return true;
    if (!index.isRacy(entry) and entry.stat.matches(found.stat, rules.check_stat, rules.timestamp_resolution)) {
        return false;
    }
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const bytes = if (found.kind == .sym_link) blk: {
        var buf: [4096]u8 = undefined;
        const len = try wt.readLink(io, entry.path, &buf);
        break :blk try a.dupe(u8, buf[0..len]);
    } else try wt.readFileAlloc(io, entry.path, a, .limited(1 << 31));
    var content: []const u8 = bytes;
    if (rules.attrs) |attrs| {
        if (found.kind != .sym_link) {
            const applied = try attrs.lookup(a, entry.path, false);
            content = (try attributes.toGit(a, bytes, applied, rules.core)).bytes;
        }
    }
    return !hash.Hasher.object(index.kind, "blob", content).eql(entry.oid);
}

/// Whether the directory at `dir_path` holds nothing but files `ours` tracks
/// and the merge removes, so that it may be replaced by a file.
fn directoryGoes(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    dir_path: []const u8,
    our_entries: anytype,
    desired: *const std.StringArrayHashMapUnmanaged(?TreeEntry),
) Error!bool {
    var dir = try wt.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, item.name });
        if (item.kind == .directory) {
            if (!try directoryGoes(arena, io, wt, path, our_entries, desired)) return false;
            continue;
        }
        if (!our_entries.contains(path)) return false;
        const want = desired.get(path) orelse return false;
        if (want != null) return false;
    }
    return true;
}

/// Whether an untracked path is ignored, reading the `.gitignore` files
/// along it the first time they are needed.
fn isIgnored(
    repo: *Repository,
    io: Io,
    wt: Io.Dir,
    rules: *?ignore.Rules,
    loaded: *std.StringHashMapUnmanaged(void),
    arena: Allocator,
    path: []const u8,
    is_dir: bool,
) Error!bool {
    if (rules.* == null) rules.* = try repo.loadIgnore(io);
    const r = &rules.*.?;
    var depth: u32 = 0;
    var at: usize = 0;
    while (true) : (depth += 1) {
        const base = path[0..at];
        if (!loaded.contains(base)) {
            try loaded.put(arena, try arena.dupe(u8, base), {});
            try r.addDirectory(io, wt, base, depth);
        }
        const slash = std.mem.indexOfScalarPos(u8, path, if (at == 0) 0 else at + 1, '/') orelse break;
        at = slash;
    }
    return r.matchPath(path, is_dir).excluded;
}
