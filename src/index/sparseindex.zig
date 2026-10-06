//! The sparse index: a directory the sparse cone leaves out, standing in
//! the index as one entry instead of one per file under it.
//!
//! A repository with a large tree and a narrow cone has most of its index
//! in directories nobody will check out, and every operation that walks the
//! index pays for them. git's answer is to collapse each such directory
//! into a single entry -- the path with a trailing `/`, mode `040000`, the
//! tree's object name, `skip-worktree` set -- and to mark the index with the
//! empty `sdir` extension so an older reader refuses it rather than
//! misreading it. Only cone mode allows it, because only a cone says of a
//! whole directory, without looking at the files in it, that it is out.
//!
//! The two moves here are git's own: `collapse` is `convert_to_sparse`, and
//! `expand` is `expand_index`, which with no patterns is
//! `ensure_full_index`. A collapse that cannot be done -- patterns that are
//! not a cone, an unmerged entry -- leaves the index full, which is always a
//! correct index. Both rebuild the cache tree afterwards, as git does, since
//! the entries it counts have changed.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");
const index_mod = @import("../index.zig");
const sparse = @import("../worktree/sparse.zig");
const fs = @import("../repo/fs.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Entry = index_mod.Entry;
const Odb = odb_mod.Odb;

/// Errors from expanding or collapsing.
pub const Error = error{
    /// A sparse directory names something that is not a tree.
    NotATree,
    /// Trees nested deeper than a walk will follow.
    TreeTooDeep,
} || Allocator.Error || odb_mod.Error || index_mod.ReadError ||
    object.TreeParseError || object.Tree.Builder.AddError;

/// How deep an expansion follows trees.
const max_depth: u32 = 256;

/// Whether the index holds any sparse directory entry.
pub fn hasSparseDirectories(index: *const Index) bool {
    for (index.entries.items) |entry| {
        if (entry.isSparseDirectory()) return true;
    }
    return false;
}

/// The sparse directory entry `path` lies under, or `null`. `path` is a
/// file's path; a sparse directory is found by its own name with the
/// trailing slash.
pub fn containing(index: *const Index, path: []const u8) ?*Entry {
    var end = path.len;
    while (std.mem.findScalarLast(u8, path[0..end], '/')) |slash| {
        end = slash;
        // A sparse directory's path is the directory with its slash.
        if (index.find(path[0 .. end + 1])) |entry| {
            if (entry.isSparseDirectory()) return entry;
        }
    }
    return null;
}

/// Replace sparse directory entries with the files under them.
///
/// With `patterns` `null`, or patterns that are not a cone, every one is
/// expanded and the index is full afterwards: git's `ensure_full_index`.
/// With a cone, only what the cone reaches into is expanded, and a
/// directory under it that the cone still leaves out stays one entry: git's
/// `expand_index`, which is what a change of patterns does first.
///
/// Every file that comes out of a sparse directory has `skip-worktree` set
/// and no stat, since none of them is in the working tree.
pub fn expand(gpa: Allocator, io: Io, index: *Index, db: *Odb, patterns: ?*const sparse.Patterns) Self.Error!void {
    if (!index.sparse and !hasSparseDirectories(index)) return;
    const cone: ?*const sparse.Cone = if (patterns) |p| (if (p.cone) |*c| c else null) else null;
    return expandSelected(gpa, io, index, db, cone, null);
}

/// Expand the sparse directories that are on the disk after all, and no
/// others.
///
/// A directory the cone leaves out is not normally there. When it is --
/// someone made it, or a tool wrote into it -- what is in it is either a
/// file the index holds or a new one, and to tell which, and to stage a new
/// one, the index needs its entries rather than the one that stands for
/// them. The rest of the index stays as sparse as it was.
pub fn expandPresent(gpa: Allocator, io: Io, wt: Io.Dir, index: *Index, db: *Odb) (Error || fs.StatError)!void {
    var present: std.StringHashMapUnmanaged(void) = .empty;
    defer present.deinit(gpa);
    for (index.entries.items) |entry| {
        if (!entry.isSparseDirectory()) continue;
        const found = (try fs.statAt(io, wt, entry.path[0 .. entry.path.len - 1])) orelse continue;
        if (found.kind != .directory) continue;
        try present.put(gpa, entry.path, {});
    }
    if (present.count() == 0) return;
    return expandSelected(gpa, io, index, db, null, &present);
}

/// git's `clear_skip_worktree_from_present_files`, which runs on every
/// index read in a sparse worktree: an entry marked `skip-worktree` whose
/// path is on the disk anyway -- a checkout with
/// `--ignore-skip-worktree-bits` brought it back -- loses the mark, so the
/// update that follows takes the file out again if it is unchanged. A
/// sparse directory that is on the disk expands the index and the pass
/// runs over every file. Returns how many entries lost the mark.
pub fn clearSkipFromPresent(gpa: Allocator, io: Io, wt: Io.Dir, index: *Index, db: *Odb) (Error || fs.StatError)!u32 {
    var cleared: u32 = 0;
    if (try clearSkipPass(io, wt, index, &cleared)) {
        try expand(gpa, io, index, db, null);
        _ = try clearSkipPass(io, wt, index, &cleared);
    }
    return cleared;
}

/// One pass of `clearSkipFromPresent`. A directory found missing is
/// remembered, and the paths under it are not looked up one by one, as
/// git's `path_found` does. Returns whether a sparse directory was found on
/// the disk, which stops the pass.
fn clearSkipPass(io: Io, wt: Io.Dir, index: *Index, cleared: *u32) fs.StatError!bool {
    var missing: []const u8 = "";
    for (index.entries.items) |*entry| {
        if (!entry.skip_worktree) continue;
        if (missing.len > 0 and std.mem.startsWith(u8, entry.path, missing) and
            entry.path.len > missing.len and entry.path[missing.len] == '/') continue;
        const sparse_dir = entry.isSparseDirectory();
        const path = if (sparse_dir) entry.path[0 .. entry.path.len - 1] else entry.path;
        if (try fs.statAt(io, wt, path)) |_| {
            if (sparse_dir) return true;
            entry.skip_worktree = false;
            cleared.* += 1;
            continue;
        }
        missing = path;
        var end: usize = 0;
        while (std.mem.findScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
            if (try fs.statAt(io, wt, path[0..slash]) == null) {
                missing = path[0..slash];
                break;
            }
        }
    }
    return false;
}

/// Expand the sparse directories named in `only`, or every one the cone
/// reaches into when `only` is `null`.
fn expandSelected(
    gpa: Allocator,
    io: Io,
    index: *Index,
    db: *Odb,
    cone: ?*const sparse.Cone,
    only: ?*const std.StringHashMapUnmanaged(void),
) Error!void {
    var out: std.ArrayList(Entry) = .empty;
    defer {
        for (out.items) |e| gpa.free(e.path);
        out.deinit(gpa);
    }
    try out.ensureTotalCapacity(gpa, index.entries.items.len);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);

    for (index.entries.items) |entry| {
        const keep = !entry.isSparseDirectory() or
            (cone != null and cone.?.match(entry.path[0 .. entry.path.len - 1], true) == .outside) or
            (only != null and !only.?.contains(entry.path));
        if (keep) {
            var copy = entry;
            copy.path = try gpa.dupe(u8, entry.path);
            out.append(gpa, copy) catch |err| {
                gpa.free(copy.path);
                return err;
            };
            continue;
        }
        path_buf.clearRetainingCapacity();
        try path_buf.appendSlice(gpa, entry.path);
        try expandTree(gpa, io, db, cone, entry.oid, &path_buf, &out, 0);
    }

    // The new entries take the old ones' place; the old paths go.
    for (index.entries.items) |e| gpa.free(e.path);
    index.entries.clearRetainingCapacity();
    try index.entries.appendSlice(gpa, out.items);
    out.clearRetainingCapacity();

    index.sparse = hasSparseDirectories(index);
    try rebuildCacheTree(io, index, db);
}

/// Append the files of the tree `oid` under `base`, which ends in `/`, in
/// index order -- which is tree order, since both put a directory where its
/// name with a slash would sort.
fn expandTree(
    gpa: Allocator,
    io: Io,
    db: *Odb,
    cone: ?*const sparse.Cone,
    oid: Oid,
    base: *std.ArrayList(u8),
    out: *std.ArrayList(Entry),
    depth: u32,
) Error!void {
    if (depth > max_depth) return error.TreeTooDeep;
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const tree: object.Tree = .parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    const base_len = base.items.len;
    while (try it.next()) |item| {
        base.shrinkRetainingCapacity(base_len);
        try base.appendSlice(gpa, item.name);
        if (item.mode == .tree) {
            // A directory the cone still leaves out stays collapsed.
            if (cone) |c| {
                if (c.match(base.items, true) == .outside) {
                    try base.append(gpa, '/');
                    try appendEntry(gpa, out, base.items, .tree, item.oid);
                    continue;
                }
            }
            try base.append(gpa, '/');
            try expandTree(gpa, io, db, cone, item.oid, base, out, depth + 1);
            continue;
        }
        try appendEntry(gpa, out, base.items, item.mode, item.oid);
    }
    base.shrinkRetainingCapacity(base_len);
}

fn appendEntry(gpa: Allocator, out: *std.ArrayList(Entry), path: []const u8, mode: object.Mode, oid: Oid) Allocator.Error!void {
    const owned = try gpa.dupe(u8, path);
    out.append(gpa, .{
        .path = owned,
        .oid = oid,
        .mode = mode,
        .skip_worktree = true,
    }) catch |err| {
        gpa.free(owned);
        return err;
    };
}

/// Collapse every directory the cone leaves out, whose entries are all
/// merged, all `skip-worktree` and none a gitlink, into one sparse
/// directory entry. Returns whether the index is sparse afterwards.
///
/// Patterns that are not a cone, or an index with an unmerged entry, leave
/// the index as it is and return false, which is git's rule: a full index
/// is never wrong, so a collapse that cannot be proven safe is not made.
/// The directories of the cone itself, and the root, are never collapsed.
pub fn collapse(gpa: Allocator, io: Io, index: *Index, db: *Odb, patterns: *const sparse.Patterns) Self.Error!bool {
    const cone = if (patterns.cone) |*c| c else return false;
    if (index.entries.items.len == 0) return false;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return false;
    }

    // The walk is over the cache tree, so it has to describe these entries.
    // git verifies it and rebuilds it when it does not; rebuilding it is
    // the same answer without the second pass.
    try rebuildCacheTree(io, index, db);
    const tree = &index.cache_tree.?;

    var out: std.ArrayList(Entry) = .empty;
    defer {
        for (out.items) |e| gpa.free(e.path);
        out.deinit(gpa);
    }
    try out.ensureTotalCapacity(gpa, index.entries.items.len);
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(gpa);
    if (!try collapseNode(gpa, cone, &tree.root, index.entries.items, &prefix, &out)) return false;

    for (index.entries.items) |e| gpa.free(e.path);
    index.entries.clearRetainingCapacity();
    try index.entries.appendSlice(gpa, out.items);
    out.clearRetainingCapacity();

    index.sparse = true;
    try rebuildCacheTree(io, index, db);
    return true;
}

/// git's `convert_to_sparse_rec` over one cache-tree node, whose entries
/// are `entries` and whose path is `prefix` (empty at the root, ending in
/// `/` below it). False when the cache tree does not describe the entries,
/// which leaves the index to stay full.
fn collapseNode(
    gpa: Allocator,
    cone: *const sparse.Cone,
    node: *const index_mod.CacheTree.Node,
    entries: []const Entry,
    prefix: *std.ArrayList(u8),
    out: *std.ArrayList(Entry),
) Error!bool {
    if (prefix.items.len != 0 and cone.match(prefix.items[0 .. prefix.items.len - 1], true) == .outside) {
        var convertible = node.oid != null;
        for (entries) |entry| {
            if (entry.stage != 0 or entry.mode == .gitlink or !entry.skip_worktree) {
                convertible = false;
                break;
            }
        }
        if (convertible) {
            try appendEntry(gpa, out, prefix.items, .tree, node.oid.?);
            return true;
        }
    }

    const base_len = prefix.items.len;
    var i: usize = 0;
    while (i < entries.len) {
        const entry = entries[i];
        const rest = entry.path[base_len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
        // A file of this directory. A sparse directory below it has a
        // slash and is taken with the node it names; one that is this
        // directory itself, which only a cone that has since widened can
        // leave, has none and is kept as it is.
        if (slash == rest.len) {
            var copy = entry;
            copy.path = try gpa.dupe(u8, entry.path);
            out.append(gpa, copy) catch |err| {
                gpa.free(copy.path);
                return err;
            };
            i += 1;
            continue;
        }
        const name = rest[0..slash];
        const child = findChild(node, name) orelse return false;
        const span = std.math.cast(usize, child.entry_count) orelse return false;
        if (span == 0 or i + span > entries.len) return false;
        try prefix.appendSlice(gpa, entry.path[base_len..][0 .. slash + 1]);
        const ok = try collapseNode(gpa, cone, child, entries[i..][0..span], prefix, out);
        prefix.shrinkRetainingCapacity(base_len);
        if (!ok) return false;
        i += span;
    }
    return true;
}

fn findChild(node: *const index_mod.CacheTree.Node, name: []const u8) ?*const index_mod.CacheTree.Node {
    for (node.children.items) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Throw the cache tree away and compute it again over the entries, which
/// is what git does after either move. An index with an unmerged entry has
/// no tree to compute, and is left with an invalid one.
fn rebuildCacheTree(io: Io, index: *Index, db: *Odb) Error!void {
    const tree = try index.cacheTree();
    tree.invalidateAll();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return;
    }
    _ = try tree.rebuild(io, index.entries.items, db);
}

//=========================================================================
// Tests
//
// git writes a sparse index when a cone-mode sparse checkout has
// `index.sparse` set, and a full one when it has not; the two are the
// fixtures here. What is compared is every entry's path, mode, object
// name, stage and flags, and the `TREE` extension byte for byte. A stat
// is not compared where git may have refreshed it and this has not.
//=========================================================================

pub const test_access = if (@import("builtin").is_test) struct {
    pub const hash = Self.hash;
    pub const object = Self.object;
    pub const odb_mod = Self.odb_mod;
    pub const index_mod = Self.index_mod;
    pub const sparse = Self.sparse;
    pub const fs = Self.fs;
    pub const Index = Self.Index;
    pub const Entry = Self.Entry;
    pub const Odb = Self.Odb;
    pub const max_depth = Self.max_depth;
    pub const expandSelected = Self.expandSelected;
    pub const expandTree = Self.expandTree;
    pub const appendEntry = Self.appendEntry;
    pub const collapseNode = Self.collapseNode;
    pub const findChild = Self.findChild;
    pub const rebuildCacheTree = Self.rebuildCacheTree;
} else struct {};
