//! A three-way merge of trees, producing an index.
//!
//! Tree level only: where both sides changed the same path, the result is a
//! conflict recorded at index stages 1, 2 and 3 — the base, ours and theirs —
//! exactly as git leaves one. Merging the *contents* of a conflicted file is
//! a separate decision with its own heuristics and is not done here; the
//! caller has the three blobs and may do as it likes with them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");

const Oid = hash.Oid;

/// Errors from a merge.
pub const Error = error{
    /// A tree entry pointed at something that is not a tree.
    NotATree,
    /// The trees nest deeper than the walk will go.
    TreeTooDeep,
} || Allocator.Error || odb_mod.Error || object.TreeParseError ||
    object.Tree.Builder.AddError || index_mod.ReadError;

/// One side's view of a path.
pub const Side = struct {
    mode: object.Mode,
    oid: Oid,
};

/// A path both sides changed differently.
pub const Conflict = struct {
    /// Owned by the result.
    path: []const u8,
    /// Absent when the path was added on both sides.
    base: ?Side,
    /// Absent when our side deleted it.
    ours: ?Side,
    /// Absent when their side deleted it.
    theirs: ?Side,
    kind: Kind,

    /// Why the two sides could not be reconciled.
    pub const Kind = enum {
        /// Both sides changed the content, or the mode, differently.
        both_modified,
        /// One side changed it and the other deleted it.
        modify_delete,
        /// Both sides added it, with different content.
        both_added,
        /// One side has a file where the other has a directory.
        directory_file,
    };
};

/// What a merge produced.
pub const Result = struct {
    gpa: Allocator,
    /// The merged index: stage 0 for everything that reconciled, and stages
    /// 1, 2 and 3 for everything that did not. The caller owns it.
    index: index_mod.Index,
    arena: std.heap.ArenaAllocator.State,
    conflicts: []Conflict,

    /// Whether every path reconciled.
    pub fn isClean(r: *const Result) bool {
        return r.conflicts.len == 0;
    }

    /// Release everything.
    pub fn deinit(r: *Result) void {
        r.index.deinit();
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

const Entries = std.StringHashMapUnmanaged(Side);

/// Merge `ours` and `theirs` against their common ancestor `base`.
///
/// `base` may be `null`, which is what an unrelated-histories merge looks
/// like: every path that is in both sides and differs is a conflict.
pub fn trees(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
) Error!Result {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var base_entries: Entries = .empty;
    if (base) |oid| try flatten(arena, io, db, oid, "", &base_entries, 0);
    var our_entries: Entries = .empty;
    try flatten(arena, io, db, ours, "", &our_entries, 0);
    var their_entries: Entries = .empty;
    try flatten(arena, io, db, theirs, "", &their_entries, 0);

    var paths: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    inline for (.{ &base_entries, &our_entries, &their_entries }) |set| {
        var it = set.keyIterator();
        while (it.next()) |key| {
            const slot = try seen.getOrPut(arena, key.*);
            if (!slot.found_existing) try paths.append(arena, key.*);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var index: index_mod.Index = .initEmpty(gpa, db.kind);
    errdefer index.deinit();
    var conflicts: std.ArrayList(Conflict) = .empty;

    for (paths.items) |path| {
        const b = base_entries.get(path);
        const o = our_entries.get(path);
        const t = their_entries.get(path);

        // A directory on one side and a file on the other is a conflict
        // whatever the contents are, because one path cannot be both.
        if (isDirectoryOf(&our_entries, path) and t != null) {
            try conflicts.append(arena, .{
                .path = path,
                .base = b,
                .ours = o,
                .theirs = t,
                .kind = .directory_file,
            });
            try stageAll(&index, path, b, o, t);
            continue;
        }
        if (isDirectoryOf(&their_entries, path) and o != null) {
            try conflicts.append(arena, .{
                .path = path,
                .base = b,
                .ours = o,
                .theirs = t,
                .kind = .directory_file,
            });
            try stageAll(&index, path, b, o, t);
            continue;
        }

        if (sameSide(o, t)) {
            if (o) |side| try stage(&index, path, side, 0);
            continue;
        }
        if (sameSide(o, b)) {
            // Only their side moved.
            if (t) |side| try stage(&index, path, side, 0);
            continue;
        }
        if (sameSide(t, b)) {
            // Only our side moved.
            if (o) |side| try stage(&index, path, side, 0);
            continue;
        }

        const kind: Conflict.Kind = if (b == null)
            .both_added
        else if (o == null or t == null)
            .modify_delete
        else
            .both_modified;
        try conflicts.append(arena, .{ .path = path, .base = b, .ours = o, .theirs = t, .kind = kind });
        try stageAll(&index, path, b, o, t);
    }

    return .{
        .gpa = gpa,
        .index = index,
        .arena = arena_instance.state,
        .conflicts = conflicts.items,
    };
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn sameSide(a: ?Side, b: ?Side) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.mode == b.?.mode and a.?.oid.eql(b.?.oid);
}

fn isDirectoryOf(entries: *const Entries, path: []const u8) bool {
    // A path is a directory on this side when some entry lives under it.
    var it = entries.keyIterator();
    while (it.next()) |key| {
        if (key.len > path.len and std.mem.startsWith(u8, key.*, path) and key.*[path.len] == '/') {
            return true;
        }
    }
    return false;
}

fn stage(index: *index_mod.Index, path: []const u8, side: Side, at: u2) Allocator.Error!void {
    try index.add(.{
        .path = path,
        .oid = side.oid,
        .mode = side.mode,
        .stage = at,
    });
}

fn stageAll(index: *index_mod.Index, path: []const u8, b: ?Side, o: ?Side, t: ?Side) Allocator.Error!void {
    if (b) |side| try stage(index, path, side, 1);
    if (o) |side| try stage(index, path, side, 2);
    if (t) |side| try stage(index, path, side, 3);
}

fn flatten(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    tree_oid: Oid,
    prefix: []const u8,
    out: *Entries,
    depth: u32,
) Error!void {
    if (depth > 64) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.gpa.free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const parsed: object.Tree = .parse(db.kind, found.bytes);
    var it = parsed.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        if (entry.mode == .tree) {
            try flatten(arena, io, db, entry.oid, path, out, depth + 1);
            continue;
        }
        try out.put(arena, path, .{ .mode = entry.mode, .oid = entry.oid });
    }
}

/// The tree a clean merge produces, written to the object database.
///
/// `error.MergeConflict` when the merge is not clean; the caller inspects
/// the `Result` for the conflicts instead.
pub fn tree(
    io: Io,
    db: *odb_mod.Odb,
    result: *Result,
) (Error || error{MergeConflict})!Oid {
    if (!result.isClean()) return error.MergeConflict;
    const cache_tree = try result.index.cacheTree();
    cache_tree.invalidateAll();
    return cache_tree.rebuild(io, result.index.entries.items, db);
}
