//! The index: `DIRC`, versions 2, 3 and 4.
//!
//! An extension whose signature begins with an upper-case letter is optional
//! and is kept byte for byte and written back; a lower-case one is mandatory
//! and is either understood or a named refusal, because quietly dissolving one
//! is data loss. `TREE`, `REUC`, `link` and `sdir` are understood.
//!
//! `sdir` marks a sparse index: a directory the sparse cone leaves out may
//! stand as one entry, its path ending in `/`, its mode `040000`, its name
//! the tree's, and `skip-worktree` set. Such an entry is read, kept and
//! written back as it is; `sparse_index` is what expands one into the files
//! under it and collapses them again.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.index.<name>`.

const ewah = @import("../codec.zig").ewah;

const std = @import("std");
const aegis = @import("aegis");
const decimal = @import("../text.zig").decimal;
const date = @import("../text.zig").date;
const shakedown = @import("shakedown");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const names_path = @import("../names.zig").path;
const varint = @import("../codec.zig").varint;
const untracked_mod = @import("untracked.zig");
const odb_mod = @import("../odb/odb.zig");
const testgit = @import("../testing/git.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// The signature every index begins with.
pub const magic = "DIRC";

/// Errors from reading an index.
pub const ReadError = error{
    /// The file did not begin `DIRC`.
    NotAnIndex,
    /// A version other than 2, 3 or 4.
    UnsupportedIndexVersion,
    /// The file ended inside an entry, an extension or the trailer.
    TruncatedIndex,
    /// The trailing checksum did not match the bytes before it.
    ChecksumMismatch,
    /// An extension whose signature begins with a lower-case letter, which
    /// makes it mandatory, and which this release does not implement. The
    /// name is in `unsupported_extension` on the index that refused.
    UnsupportedExtension,
    /// A directory entry in an index without `sdir`, or one whose path does
    /// not end in `/` or that is not at stage 0 -- or a path ending in `/`
    /// that is not a directory entry.
    InvalidSparseDirectory,
    /// A path that is empty, absolute, or holds a component a working tree
    /// must never be asked to create.
    InvalidEntryPath,
    /// Entries out of order, or a duplicate path and stage.
    UnsortedIndex,
    /// A split index whose shared file is not beside it.
    SharedIndexMissing,
    /// A split index whose `link` extension does not fit its shared index:
    /// bytes after its bitmaps, a position past the shared index's end, a
    /// replacement with a name or an addition without one (git's
    /// `read_link_extension` and `merge_base_index`).
    CorruptLinkExtension,
    /// A `TREE` extension that does not describe the entries it sits on.
    CorruptCacheTree,
    /// A `REUC` extension that ran off its own end.
    CorruptResolveUndo,
    /// An `FSMN` extension of a version other than 1 or 2, or one that ran
    /// off its own end.
    CorruptFsmonitor,
    /// An entry's extended flags hold a bit git does not know: "unknown
    /// index entry format".
    UnknownEntryFlags,
} || Allocator.Error || aegis.own.ReadFileError || ewah.Error || varint.Error;

/// Errors from writing an index.
pub const WriteError = error{
    /// A path longer than the format can carry.
    PathTooLong,
    /// More entries than the format counts: 2^32, git's `unsigned int`.
    TooManyEntries,
    /// Version 4 was asked for but the entries are not in an order its
    /// prefix compression can express.
    UnsupportedIndexVersion,
    /// Version 2 cannot encode skip-worktree or intent-to-add.
    ExtendedFlagsRequireVersion3,
    /// Two entries out of order, or one path and stage twice: an index git
    /// refuses to read, and this package too.
    UnsortedIndex,
    /// A split index asked of a sparse one: git's "cannot use split index
    /// with a sparse index".
    SparseSplitIndex,
    /// The shared index just written could not be found again.
    FileNotFound,
    /// The shared index just written could not be looked at.
    FileSystem,
} || fs.LockError || fs.CommitError || Allocator.Error;

/// One tracked path.
pub const Entry = struct {
    /// `/`-separated, relative to the working tree's root. Owned by the
    /// index.
    path: []const u8,
    oid: Oid,
    mode: object.Mode,
    /// The mode as the file spelled it, where that is not `mode.raw()`:
    /// git reads an entry's mode as it is (`create_from_disk`) and writes
    /// it back unchanged, where relic takes the mode git's consumers take
    /// (`Entry.modeOf`). Written back only while `mode` is still the one it
    /// spells.
    raw_mode: ?u32 = null,
    /// 0 for a merged entry; 1, 2 and 3 are a conflict's stages: the
    /// base's version, ours and theirs, as a merge, cherry-pick, revert or
    /// rebase that stops leaves them (`three_way.zig`).
    stage: u2 = 0,
    /// git's `assume-valid` bit: the caller has promised the file has not
    /// changed and the stat is not to be trusted against it.
    assume_valid: bool = false,
    /// The file is not meant to be in the working tree. Sparse checkout sets
    /// it.
    skip_worktree: bool = false,
    /// `git add -N`: the path is staged as existing with no content yet.
    intent_to_add: bool = false,
    /// git's `CE_FSMONITOR_VALID`: the file monitor has reported no change
    /// to the file since the index's `fsmonitor_token`, and the file was
    /// found the same as this entry after that. An entry made here starts
    /// without it. `worktree.fsmonitor.refresh` decides when it is believed.
    fsmonitor_valid: bool = false,
    stat: fs.Stat = .none,
    /// git's `ce->index`: one more than the position in a split index's
    /// shared index this entry was read from or last written to, or 0. A
    /// write compares the entry with that one to tell what is shared.
    shared_at: u32 = 0,

    /// The mode an index entry's raw bits are taken as: the spellings
    /// `Mode.fromRaw` knows, else git's `canon_mode`. No value is refused,
    /// as git's `do_read_index` refuses none.
    pub fn modeOf(raw: u32) object.Mode {
        return object.Mode.fromRaw(raw) catch object.Mode.canonical(raw);
    }

    /// The mode bits the entry is written with: its spelling as read while
    /// it still names `mode`, else `mode` itself.
    pub fn diskMode(e: Entry) u32 {
        const raw = e.raw_mode orelse return e.mode.raw();
        return if (modeOf(raw) == e.mode) raw else e.mode.raw();
    }

    /// Whether the entry needs the version 3 extended flag word.
    pub fn needsExtendedFlags(e: Entry) bool {
        return e.skip_worktree or e.intent_to_add;
    }

    /// Whether the entry is a sparse directory: a whole directory outside
    /// the sparse cone standing as one entry, named with a trailing `/`.
    pub fn isSparseDirectory(e: Entry) bool {
        return e.mode == .tree;
    }

    /// git's order: path as unsigned bytes, then stage.
    pub fn order(a: Entry, b: Entry) std.math.Order {
        const by_path = std.mem.order(u8, a.path, b.path);
        if (by_path != .eq) return by_path;
        return std.math.order(a.stage, b.stage);
    }
};

/// An extension this package does not interpret, kept exactly as it was read.
pub const RawExtension = struct {
    signature: [4]u8,
    /// Owned by the index.
    data: []const u8,

    /// Whether the extension is optional, which is what an upper-case first
    /// letter means.
    pub fn isOptional(e: RawExtension) bool {
        return e.signature[0] >= 'A' and e.signature[0] <= 'Z';
    }
};

/// One directory of a `CacheTree`.
pub const CacheTreeNode = struct {
    /// The directory's own name, without a slash. Empty at the root.
    name: []const u8,
    /// How many index entries this subtree covers, or -1 when the node
    /// is invalid and its tree must be rebuilt.
    entry_count: i64,
    /// The tree object, when the node is valid.
    oid: ?Oid,
    /// Sorted by name, which is the order the extension stores them in.
    children: std.ArrayList(CacheTreeNode),

    /// Whether this node's tree object may be used as it is.
    pub fn isValid(n: *const CacheTreeNode) bool {
        return n.entry_count >= 0 and n.oid != null;
    }

    fn deinit(n: *CacheTreeNode, gpa: Allocator) void {
        for (n.children.items) |*sub| sub.deinit(gpa);
        n.children.deinit(gpa);
        gpa.free(n.name);
        n.* = undefined;
    }

    /// git's order for the children of a node: by length, then by
    /// bytes.
    pub fn lessThan(_: void, a: CacheTreeNode, b: CacheTreeNode) bool {
        if (a.name.len != b.name.len) return a.name.len < b.name.len;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    fn child(n: *CacheTreeNode, name: []const u8) ?*CacheTreeNode {
        for (n.children.items) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

/// The `TREE` extension: a tree object name per directory, so `write-tree`
/// rebuilds only the directories that changed.
///
/// An invalidated node carries an entry count of -1 and no object name, which
/// is what an edit under it leaves behind.
/// Extensions an index read dropped because they could not be read.
pub const Dropped = struct {
    /// `TREE`, which git's `cache_tree_read` gives up on silently.
    cache_tree: bool = false,
    /// `REUC`: "Index records invalid resolve-undo information".
    resolve_undo: bool = false,
    /// `FSMN`: "corrupt fsmonitor extension".
    fsmonitor: bool = false,
    /// `UNTR`, which git's `read_untracked_extension` gives up on silently.
    untracked_cache: bool = false,

    /// Whether any was dropped.
    pub fn any(d: Dropped) bool {
        return d.cache_tree or d.resolve_undo or d.fsmonitor or d.untracked_cache;
    }
};

/// A split index: the shared index it stands on, as git's `split_index`
/// keeps it.
pub const Split = struct {
    /// The shared index's checksum, which names `sharedindex.<hex>`; `null`
    /// until one is written.
    base: ?Oid = null,
    /// The shared index's entries in its order, as read or last written:
    /// what `Entry.shared_at` counts in. Owned by the index.
    shared: std.ArrayList(Entry) = .empty,

    fn deinit(s: *Split, gpa: Allocator) void {
        for (s.shared.items) |e| gpa.free(e.path);
        s.shared.deinit(gpa);
        s.* = undefined;
    }
};

pub const CacheTree = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    root: CacheTreeNode,

    /// One directory: `CacheTreeNode`.
    /// An empty, wholly invalid cache tree — the state an index with no
    /// `TREE` extension is in.
    pub fn empty(gpa: Allocator) Allocator.Error!CacheTree {
        return .{
            .gpa = gpa,
            .root = .{ .name = try gpa.dupe(u8, ""), .entry_count = -1, .oid = null, .children = .empty },
        };
    }

    /// Release the tree.
    pub fn deinit(t: *CacheTree) void {
        t.root.deinit(t.gpa);
        t.* = undefined;
    }

    /// The node for a `/`-separated directory path, or `null`. The empty
    /// path is the root.
    pub fn get(t: *CacheTree, dir: []const u8) ?*CacheTreeNode {
        var node = &t.root;
        if (dir.len == 0) return node;
        var it = std.mem.splitScalar(u8, dir, '/');
        while (it.next()) |component| {
            if (component.len == 0) continue;
            node = node.child(component) orelse return null;
        }
        return node;
    }

    /// Mark the path's directory and every directory above it invalid.
    ///
    /// Called for every file an `addAll` touches; without it `write-tree`
    /// hands back a tree that describes what used to be there.
    pub fn invalidate(t: *CacheTree, path: []const u8) void {
        t.root.entry_count = -1;
        t.root.oid = null;
        var node = &t.root;
        var rest = path;
        while (std.mem.findScalar(u8, rest, '/')) |slash| {
            const component = rest[0..slash];
            rest = rest[slash + 1 ..];
            node = node.child(component) orelse return;
            node.entry_count = -1;
            node.oid = null;
        }
    }

    /// Drop every node, leaving an invalid root. Used when the whole index
    /// is replaced.
    pub fn invalidateAll(t: *CacheTree) void {
        for (t.root.children.items) |*child| child.deinit(t.gpa);
        t.root.children.clearRetainingCapacity();
        t.root.entry_count = -1;
        t.root.oid = null;
    }

    /// The deepest a tree, and so a cache tree, goes.
    const max_cache_tree_depth = object.max_tree_depth;

    /// The nodes are read depth first with a stack of their own, not by
    /// recursion: the extension is the file's to say how deep it goes, and
    /// a node costs at least a few bytes, so hostile bytes could otherwise
    /// nest deeper than any thread's stack.
    fn parse(gpa: Allocator, kind: Kind, data: []const u8) ReadError!CacheTree {
        var offset: usize = 0;
        const Open = struct { node: CacheTreeNode, wanted: u32 };
        var stack: std.ArrayList(Open) = .empty;
        defer {
            for (stack.items) |*open| open.node.deinit(gpa);
            stack.deinit(gpa);
        }
        // The root, or it is not the whole tree.
        if (data.len == 0 or data[0] != 0) return error.CorruptCacheTree;
        const first = try parseNode(gpa, kind, data, &offset);
        stack.append(gpa, .{ .node = first.node, .wanted = first.subtrees }) catch |err| {
            var node = first.node;
            node.deinit(gpa);
            return err;
        };
        while (true) {
            const top = &stack.items[stack.items.len - 1];
            if (top.node.children.items.len < top.wanted) {
                // No tree git writes nests deeper than `core.maxTreeDepth`,
                // and the nodes are freed and written by recursion.
                if (stack.items.len > max_cache_tree_depth) return error.CorruptCacheTree;
                const child = try parseNode(gpa, kind, data, &offset);
                stack.append(gpa, .{ .node = child.node, .wanted = child.subtrees }) catch |err| {
                    var node = child.node;
                    node.deinit(gpa);
                    return err;
                };
                continue;
            }
            const done = stack.pop().?;
            if (stack.items.len == 0) return .{ .gpa = gpa, .root = done.node };
            const parent = &stack.items[stack.items.len - 1].node;
            parent.children.append(gpa, done.node) catch |err| {
                var node = done.node;
                node.deinit(gpa);
                return err;
            };
        }
    }

    /// One node's own fields, and how many subtrees follow it. The list of
    /// children grows as they are read: the count is the file's word, and
    /// reserving it first would let four bytes ask for any amount.
    fn parseNode(gpa: Allocator, kind: Kind, data: []const u8, offset: *usize) ReadError!struct { node: CacheTreeNode, subtrees: u32 } {
        const nul = std.mem.findScalarPos(u8, data, offset.*, 0) orelse return error.CorruptCacheTree;
        const raw_name = data[offset.*..nul];
        offset.* = nul + 1;

        const entry_count: i64 = try treeInt(data, offset, ' ');
        const subtrees = try treeInt(data, offset, '\n');
        const subtree_count = std.math.cast(u32, subtrees) orelse return error.CorruptCacheTree;

        var oid: ?Oid = null;
        if (entry_count >= 0) {
            const raw_len = kind.rawLen();
            if (offset.* + raw_len > data.len) return error.CorruptCacheTree;
            oid = Oid.fromCut(kind, data[offset.*..][0..raw_len]);
            offset.* += raw_len;
        }

        return .{
            .node = .{
                .name = try gpa.dupe(u8, raw_name),
                .entry_count = entry_count,
                .oid = oid,
                .children = .empty,
            },
            .subtrees = subtree_count,
        };
    }

    /// git's `parse_int` in `cache-tree.c` and the byte after it: any number
    /// of minus signs, then decimal digits into an `int`, which wraps.
    fn treeInt(data: []const u8, offset: *usize, end: u8) ReadError!i32 {
        var at = offset.*;
        var negative = false;
        while (at < data.len and data[at] == '-') : (at += 1) negative = !negative;
        var value: i32 = 0;
        while (at < data.len and std.ascii.isDigit(data[at])) : (at += 1) value = value *% 10 +% @as(i32, data[at] - '0');
        if (at == offset.* or at >= data.len or data[at] != end) return error.CorruptCacheTree;
        offset.* = at + 1;
        return if (negative) 0 -% value else value;
    }

    fn write(t: *const CacheTree, w: *Io.Writer) Io.Writer.Error!void {
        try writeNode(&t.root, w);
    }

    fn writeNode(n: *const CacheTreeNode, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(n.name);
        try w.writeByte(0);
        try w.print("{d} {d}\n", .{ n.entry_count, n.children.items.len });
        if (n.entry_count >= 0) {
            if (n.oid) |oid| try w.writeAll(oid.raw());
        }
        for (n.children.items) |*child| try writeNode(child, w);
    }

    /// Errors from `rebuild`.
    pub const RebuildError = ReadError || odb_mod.Error || object.Tree.Builder.AddError;

    /// Rebuild every invalid node, writing the tree objects it needs, and
    /// return the root tree's name.
    ///
    /// A valid node is used as it stands, which is the difference between a
    /// warm `write-tree` and a cold one.
    pub fn rebuild(
        t: *CacheTree,
        io: Io,
        entries: []const Entry,
        db: *odb_mod.Odb,
    ) RebuildError!Oid {
        return t.rebuildInto(io, entries, db, null);
    }

    /// Errors from `rebuildInto`.
    pub const RebuildIntoError = ReadError || odb_mod.Error || object.Tree.Builder.AddError;

    /// `rebuild`, writing the tree objects into a pack the database is
    /// filling, when one is given, rather than as loose objects.
    pub fn rebuildInto(
        t: *CacheTree,
        io: Io,
        entries: []const Entry,
        db: *odb_mod.Odb,
        filling: ?odb_mod.Odb.OpenPack,
    ) RebuildIntoError!Oid {
        var consumed: usize = 0;
        const oid = try rebuildNode(t, io, &t.root, "", entries, &consumed, db, filling);
        if (consumed != entries.len) return error.CorruptCacheTree;
        return oid;
    }

    fn rebuildNode(
        t: *CacheTree,
        io: Io,
        node: *CacheTreeNode,
        prefix: []const u8,
        entries: []const Entry,
        consumed: *usize,
        db: *odb_mod.Odb,
        filling: ?odb_mod.Odb.OpenPack,
    ) (ReadError || odb_mod.Error || object.Tree.Builder.AddError)!Oid {
        // A valid node covers a known number of entries; skip over them.
        if (node.isValid()) {
            const count: usize = std.math.cast(usize, node.entry_count) orelse return error.CorruptCacheTree;
            const end = std.math.add(usize, consumed.*, count) catch return error.CorruptCacheTree;
            if (end > entries.len) return error.CorruptCacheTree;
            if (prefix.len == 0) {
                if (end != entries.len) return error.CorruptCacheTree;
            } else {
                for (entries[consumed.*..end]) |entry| {
                    if (!std.mem.startsWith(u8, entry.path, prefix)) return error.CorruptCacheTree;
                }
                if (end < entries.len and std.mem.startsWith(u8, entries[end].path, prefix)) {
                    return error.CorruptCacheTree;
                }
            }
            consumed.* = end;
            return node.oid.?;
        }

        // A sparse directory is its own tree: the entry names it, and the
        // node covers the one entry, which is how git records it.
        if (prefix.len != 0 and consumed.* < entries.len) {
            const first = entries[consumed.*];
            if (first.isSparseDirectory() and std.mem.eql(u8, first.path, prefix)) {
                for (node.children.items) |*child| child.deinit(t.gpa);
                node.children.clearRetainingCapacity();
                consumed.* += 1;
                node.entry_count = 1;
                node.oid = first.oid;
                return first.oid;
            }
        }

        var builder: object.Tree.Builder = .init(t.gpa, db.objectFormat());
        defer builder.deinit();
        const start = consumed.*;

        // Children that are still in the index keep their nodes; ones that
        // are not are dropped as the walk goes past them.
        var kept: std.ArrayList(CacheTreeNode) = .empty;
        errdefer {
            for (kept.items) |*n| n.deinit(t.gpa);
            kept.deinit(t.gpa);
        }

        while (consumed.* < entries.len) {
            const entry = entries[consumed.*];
            if (prefix.len != 0) {
                if (!std.mem.startsWith(u8, entry.path, prefix)) break;
            }
            const rest = entry.path[prefix.len..];
            if (rest.len == 0) {
                consumed.* += 1;
                continue;
            }
            if (std.mem.findScalar(u8, rest, '/')) |slash| {
                const dir_name = rest[0..slash];
                var child_node: CacheTreeNode = if (node.child(dir_name)) |existing| taken: {
                    const copy = existing.*;
                    existing.* = .{ .name = try t.gpa.dupe(u8, ""), .entry_count = -1, .oid = null, .children = .empty };
                    break :taken copy;
                } else .{
                    .name = try t.gpa.dupe(u8, dir_name),
                    .entry_count = -1,
                    .oid = null,
                    .children = .empty,
                };
                // taken out of the tree, the node is this walk's until it
                // is kept or dropped, and an error on the way frees it
                var held = true;
                errdefer if (held) child_node.deinit(t.gpa);
                const child_prefix = entry.path[0 .. prefix.len + slash + 1];
                const child_start = consumed.*;
                const child_oid = try t.rebuildNode(io, &child_node, child_prefix, entries, consumed, db, filling);
                child_node.entry_count = @intCast(consumed.* - child_start);
                child_node.oid = child_oid;
                // An empty directory produces no tree entry and no node.
                if (child_node.entry_count == 0) {
                    held = false;
                    child_node.deinit(t.gpa);
                } else {
                    try builder.add(.tree, dir_name, child_oid);
                    try kept.append(t.gpa, child_node);
                    held = false;
                }
            } else {
                // A staged conflict has no single tree to write.
                if (entry.stage != 0) return error.CorruptCacheTree;
                try builder.add(entry.mode, rest, entry.oid);
                consumed.* += 1;
            }
        }

        for (node.children.items) |*child| child.deinit(t.gpa);
        node.children.deinit(t.gpa);
        // git keeps a node's children shortest name first, and by bytes
        // among names of one length, and writes them in that order.
        std.mem.sort(CacheTreeNode, kept.items, {}, CacheTreeNode.lessThan);
        node.children = kept;

        const bytes = try builder.build();
        defer t.gpa.free(bytes);
        const oid = if (filling) |open| try db.writeInto(io, open, .tree, bytes) else try db.write(io, .tree, bytes);
        node.entry_count = @intCast(consumed.* - start);
        node.oid = oid;
        return oid;
    }
};

/// The `REUC` extension: what a conflict replaced, so `checkout --merge` and
/// `rerere forget` can put it back. Read and written back; a stage is added
/// to it with `Index.recordResolveUndo`.
pub const ResolveUndo = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    entries: std.ArrayList(Item),

    /// One path's three stages.
    pub const Item = struct {
        path: []const u8,
        modes: [3]u32,
        oids: [3]?Oid,
    };

    /// Release everything.
    pub fn deinit(r: *ResolveUndo) void {
        for (r.entries.items) |*item| r.gpa.free(item.path);
        r.entries.deinit(r.gpa);
        r.* = undefined;
    }

    fn parse(gpa: Allocator, kind: Kind, data: []const u8) ReadError!ResolveUndo {
        var result: ResolveUndo = .{ .gpa = gpa, .entries = .empty };
        errdefer result.deinit();
        var offset: usize = 0;
        while (offset < data.len) {
            const nul = std.mem.findScalarPos(u8, data, offset, 0) orelse return error.CorruptResolveUndo;
            const path = try gpa.dupe(u8, data[offset..nul]);
            errdefer gpa.free(path);
            offset = nul + 1;
            var modes: [3]u32 = @splat(0);
            for (&modes) |*mode| {
                const end = std.mem.findScalarPos(u8, data, offset, 0) orelse return error.CorruptResolveUndo;
                mode.* = decimal.whole(u32, data[offset..end], 8) orelse return error.CorruptResolveUndo;
                offset = end + 1;
            }
            var oids: [3]?Oid = @splat(null);
            const raw_len = kind.rawLen();
            for (modes, 0..) |mode, i| {
                if (mode == 0) continue;
                if (offset + raw_len > data.len) return error.CorruptResolveUndo;
                oids[i] = Oid.fromCut(kind, data[offset..][0..raw_len]);
                offset += raw_len;
            }
            try result.entries.append(gpa, .{ .path = path, .modes = modes, .oids = oids });
        }
        return result;
    }

    fn write(r: *const ResolveUndo, w: *Io.Writer) Io.Writer.Error!void {
        for (r.entries.items) |item| {
            try w.writeAll(item.path);
            try w.writeByte(0);
            for (item.modes) |mode| {
                try w.print("{o}", .{mode});
                try w.writeByte(0);
            }
            for (item.modes, item.oids) |mode, oid| {
                if (mode == 0) continue;
                try w.writeAll(oid.?.raw());
            }
        }
    }
};

/// The only version of `IEOT` there is.
const ieot_version: u32 = 1;

/// How an index is written.
/// Where split-index files live, the object format and an optional measured
/// filesystem timestamp resolution. Without a measurement, read probes it.
pub const ReadOptions = struct {
    git_dir: ?Io.Dir = null,
    kind: Kind,
    timestamp_resolution: ?fs.Resolution = null,
    /// What `Index.add` refuses, as `core.protectNTFS` and `core.protectHFS`
    /// say; git's defaults unless given.
    protect: names_path.Protect = .{},
};

pub const WriteOptions = struct {
    /// Which version to write. `auto` is git's rule: the version the index
    /// carries, the file's or `new_version` for one made here, with 2 and 3
    /// each written as the other when that is what the entries need --
    /// version 3 only while an entry needs an extended flag.
    version: Version = .auto,
    /// The version an index made here is first written in under `auto`:
    /// git's `index.version`, 3 when it is not set (and so 2 until an entry
    /// needs an extended flag). One the file carries is kept, as git keeps
    /// it. 2, 3 or 4.
    new_version: u32 = 3,
    /// Whether to write the all-zero trailer `index.skipHash` asks for.
    /// Reading one is always accepted; writing one is a choice.
    skip_hash: bool = false,
    /// Whether to keep the `TREE` extension. A caller that has invalidated
    /// it and does not want to rebuild may drop it.
    write_cache_tree: bool = true,
    /// Whether to write `EOIE`, the offset of the first extension.
    /// `null` writes one if the index that was read had one.
    end_of_index_entries: ?bool = null,
    /// How many blocks `IEOT` splits the entries into. Fewer than two writes
    /// no `IEOT`, which is git's own rule: a table of one block accelerates
    /// nothing. `null` uses as many blocks as the index that was read had.
    ///
    /// The number is a reader's business, not a writer's: it is how many
    /// pieces a reader may decode at once, and this package decodes one at a
    /// time whatever it says. It is here so that an index carrying a table
    /// keeps one, and so that a caller writing for a particular reader can
    /// say how many.
    entry_offset_blocks: ?u32 = null,
    /// How the lock behaves: whether to wait for a contended one, and how
    /// hard to push the bytes towards the disk before the rename.
    /// How the lock is taken and synced. The default syncs the index, as
    /// relic's `core.fsync` default does; `Repository.indexLock` gives what
    /// the repository's configuration says.
    lock: fs.LockFile.Options = .{ .sync = .per_file },
    /// Whether a racily clean entry's file holds something other than the
    /// entry says. Given, a racy entry is smudged only when it does, which
    /// is git's rule, and an index read and written back keeps its bytes;
    /// without it every racy entry is smudged, which is safe and costs the
    /// next status a hash of each. `Repository.writeIndex` gives one.
    racy: ?*const Racy = null,

    /// See `racy`.
    /// A node its owner embeds, found again from the node by `changed`.
    pub const Racy = struct {
        changed: *const fn (racy: *const Racy, index: *const Index, entry: Entry) bool,
    };

    /// The version to write.
    pub const Version = union(enum) {
        auto,
        v2,
        v3,
        v4,
    };
};

/// The index.
pub const Index = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    kind: Kind,
    /// The version the file on the disk carried, or 0 for one made here,
    /// which `WriteOptions.new_version` decides when it is first written:
    /// git's `istate->version`.
    version: u32 = 0,
    /// Sorted by path and then by stage.
    entries: std.ArrayList(Entry) = .empty,
    cache_tree: ?CacheTree = null,
    resolve_undo: ?ResolveUndo = null,
    /// `UNTR`, the untracked cache, kept true as entries come and go.
    untracked: ?untracked_mod.UntrackedCache = null,
    /// Optional extensions this package does not interpret, as they were
    /// read. They are not written back, as git writes back none it does not
    /// know: one such as `UNTR` describes the working tree as it was, which
    /// a write here does not keep true.
    unknown: std.ArrayList(RawExtension) = .empty,
    /// The mandatory extension that was refused, when `read` returned
    /// `error.UnsupportedExtension`. Four bytes, valid until `deinit`.
    unsupported_extension: [4]u8 = @splat(0),
    /// The optional extensions the file read carried that could not be
    /// read and were dropped, as git drops them: the index reads without
    /// them, and a caller may say so.
    dropped: Dropped = .{},
    /// The index file's own modification time in seconds, which is the racy
    /// cutoff. Zero for an index that has never been on a disk.
    racy_cutoff_sec: u32 = 0,
    racy_cutoff_nsec: u32 = 0,
    /// How fine a modification time the filesystem holding this index
    /// records, measured when it was read. It decides how much of an entry's
    /// nanosecond field the racy rule is allowed to believe.
    timestamp_resolution: fs.Resolution = .nanosecond,
    /// The split index this was read as, or is to be written as: git's
    /// `split_index`. `null` is written whole.
    split: ?Split = null,
    /// Whether the file read was a split index: its `link` extension came
    /// before the shared index was merged in.
    was_split: bool = false,
    /// Whether the file read carried an all-zero trailer, which is what
    /// `index.skipHash` writes.
    hash_was_skipped: bool = false,
    /// Whether the file read carried `EOIE`. Its contents are not kept:
    /// both it and `IEOT` are offsets into the file they are written in, so
    /// what survives a rewrite is that they were there and how the table was
    /// divided, and the numbers are taken again.
    had_end_of_index_entries: bool = false,
    /// How many blocks the `IEOT` the file read carried was divided into, or
    /// zero where there was none.
    entry_offset_blocks: u32 = 0,
    /// The token of the file monitor's last answer, from `FSMN`: what to ask
    /// it for changes since. `null` when the index carries none; owned.
    fsmonitor_token: ?[]u8 = null,
    /// Whether `worktree.fsmonitor.refresh` has asked the monitor since the
    /// index was read, which is what makes `Entry.fsmonitor_valid` true
    /// now and not only when the index was written.
    fsmonitor_refreshed: bool = false,
    /// Whether what the monitor vouches for changed in a way git writes the
    /// index for: a first token, more than a hundred paths named, an answer
    /// that took back what was vouched for, a file vouched for anew. git's
    /// status writes the index then, and only then for the monitor's sake;
    /// the token of an answer that changed nothing else is not kept.
    fsmonitor_changed: bool = false,
    /// Whether `worktree.status` put a file's new stat in an entry whose
    /// content had not changed: git's refresh, whose index `git status`
    /// and `git diff` write when they can (`refresh_index_quietly`,
    /// `repo_update_index_if_able`), so the next look takes the shortcut.
    stat_refreshed: bool = false,
    /// Whether the index is sparse: it carries `sdir`, and may hold sparse
    /// directory entries. `sparse_index.expand` clears it and
    /// `sparse_index.collapse` sets it; it decides whether `sdir` is written.
    sparse: bool = false,
    /// The spellings of `.git` another file system opens as it, which `add`
    /// refuses beside the plain one: `core.protectNTFS` and
    /// `core.protectHFS`, git's defaults unless the repository says.
    protect: names_path.Protect = .{},
    /// The delete mask a split index carried, until it is merged.
    split_delete: ?ewah.Bits = null,
    /// The replace mask a split index carried, until it is merged.
    split_replace: ?ewah.Bits = null,

    /// An empty index for a repository of `kind`.
    pub fn initEmpty(gpa: Allocator, kind: Kind) Index {
        return .{ .gpa = gpa, .kind = kind };
    }

    /// Release everything the index holds.
    pub fn deinit(index: *Index) void {
        for (index.entries.items) |e| index.gpa.free(e.path);
        index.entries.deinit(index.gpa);
        if (index.cache_tree) |*t| t.deinit();
        if (index.resolve_undo) |*r| r.deinit();
        if (index.untracked) |*u| u.deinit();
        if (index.split) |*s| s.deinit(index.gpa);
        for (index.unknown.items) |e| index.gpa.free(e.data);
        index.unknown.deinit(index.gpa);
        if (index.fsmonitor_token) |t| index.gpa.free(t);
        if (index.split_delete) |*b| b.deinit();
        if (index.split_replace) |*b| b.deinit();
        index.* = undefined;
    }

    /// Read the index at `sub_path` in `dir`.
    ///
    /// A missing file is an empty index, which is what git does: a repository
    /// with no `.git/index` has nothing staged. `git_dir` is where a split
    /// index's shared file is looked for, and may be the same directory.
    pub fn read(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, options: ReadOptions) Self.ReadError!Index {
        const git_dir = options.git_dir orelse dir;
        const kind = options.kind;
        const timestamp_resolution = options.timestamp_resolution;
        const bytes = (try fs.readFileAlloc(gpa, io, dir, sub_path, 1 << 31)) orelse {
            var empty = initEmpty(gpa, kind);
            empty.protect = options.protect;
            return empty;
        };
        defer gpa.free(bytes);

        var index = try parse(gpa, kind, bytes);
        errdefer index.deinit();
        index.protect = options.protect;

        if (dir.statFile(io, sub_path, .{})) |stat| {
            const s = fs.Stat.fromIo(stat, .{});
            index.racy_cutoff_sec = s.mtime_sec;
            index.racy_cutoff_nsec = s.mtime_nsec;
        } else |err| if (err == error.Canceled) return error.Canceled;
        // How much of that cutoff's nanoseconds means anything is a property
        // of the filesystem, and it is measured rather than assumed. It is
        // measured here because this is where the cutoff is taken and
        // because it is the filesystem the cutoff came from.
        index.timestamp_resolution = timestamp_resolution orelse try fs.probeTimestampResolution(io, dir);

        if (index.split) |split| if (split.base) |base| {
            try index.mergeShared(gpa, io, git_dir, base);
        };
        return index;
    }

    /// Read an index from bytes already in memory.
    ///
    /// A split index read this way keeps its `link` extension unresolved:
    /// `split.base` names the shared file and the entries are only the
    /// overlay. `read` is the call that merges them.
    pub fn parse(gpa: Allocator, kind: Kind, bytes: []const u8) Self.ReadError!Index {
        const raw_len = kind.rawLen();
        if (bytes.len < 12 + raw_len) return error.TruncatedIndex;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotAnIndex;
        const version = std.mem.readInt(u32, bytes[4..8], .big);
        if (version < 2 or version > 4) return error.UnsupportedIndexVersion;
        const entry_count = std.mem.readInt(u32, bytes[8..12], .big);

        const body = bytes[0 .. bytes.len - raw_len];
        const trailer = bytes[bytes.len - raw_len ..];

        var index: Index = .{ .gpa = gpa, .kind = kind, .version = version };
        errdefer index.deinit();

        if (std.mem.allEqual(u8, trailer, 0)) {
            // `index.skipHash` writes zeros rather than a hash. git accepts
            // it, so this does; what is written back is a real hash unless
            // the caller asks otherwise.
            index.hash_was_skipped = true;
        } else {
            var hasher: hash.Hasher = .init(kind);
            hasher.update(body);
            const computed = hasher.final();
            const stored = Oid.fromCut(kind, trailer);
            if (!computed.eql(stored)) return error.ChecksumMismatch;
        }

        var r: Io.Reader = .fixed(body[12..]);
        try index.entries.ensureTotalCapacity(gpa, @min(entry_count, 1 << 20));
        var previous_path: []const u8 = "";
        for (0..entry_count) |_| {
            const fixed = r.take(entry_fixed_len + raw_len) catch return error.TruncatedIndex;
            const entry = try parseEntry(gpa, kind, version, fixed, &r, previous_path);
            index.entries.append(gpa, entry) catch |err| {
                gpa.free(entry.path);
                return err;
            };
            previous_path = entry.path;
        }

        // What is left past the entries is extensions, each a signature
        // and a length; fewer bytes than a header are ignored, as git
        // ignores them.
        while (r.bufferedLen() >= 8) {
            const signature = (r.takeArray(4) catch return error.TruncatedIndex).*;
            const size = r.takeInt(u32, .big) catch return error.TruncatedIndex;
            const data = r.take(size) catch return error.TruncatedIndex;
            try index.readExtension(gpa, signature, data);
        }

        // A split index's overlay carries its replacements with empty names,
        // in the shared index's order rather than in path order, so both
        // checks wait until the `link` extension has been seen.
        for (index.entries.items) |e| {
            const trailing_slash = e.path.len != 0 and e.path[e.path.len - 1] == '/';
            if (e.isSparseDirectory() != trailing_slash) return error.InvalidSparseDirectory;
            if (e.isSparseDirectory() and (!index.sparse or e.stage != 0)) return error.InvalidSparseDirectory;
        }
        if (!index.was_split) {
            for (index.entries.items) |e| {
                if (e.path.len == 0) return error.InvalidEntryPath;
            }
            if (index.entries.items.len > 1) {
                for (index.entries.items[1..], index.entries.items[0 .. index.entries.items.len - 1]) |b, a| {
                    if (Entry.order(a, b) != .lt) return error.UnsortedIndex;
                }
            }
        }

        return index;
    }

    /// `FSMN`: a version, the token -- a NUL-terminated string from version
    /// 2, a time in nanoseconds in version 1 -- and a bitmap of the entries
    /// the monitor has not vouched for. A submodule is never vouched for. The
    /// bitmap counts the entries of the index it was written with, so a
    /// split index's, which counts the merged ones, is not believed.
    fn parseFsmonitor(index: *Index, gpa: Allocator, data: []const u8) ReadError!void {
        if (data.len < 4) return error.CorruptFsmonitor;
        var rest = data[4..];
        const token = switch (std.mem.readInt(u32, data[0..4], .big)) {
            1 => blk: {
                if (rest.len < 8) return error.CorruptFsmonitor;
                const nanoseconds = std.mem.readInt(u64, rest[0..8], .big);
                rest = rest[8..];
                break :blk try gpa.print("{d}", .{nanoseconds});
            },
            2 => blk: {
                const end = std.mem.findScalar(u8, rest, 0) orelse return error.CorruptFsmonitor;
                defer rest = rest[end + 1 ..];
                break :blk try gpa.dupe(u8, rest[0..end]);
            },
            else => return error.CorruptFsmonitor,
        };
        if (index.fsmonitor_token) |old| gpa.free(old);
        index.fsmonitor_token = token;
        if (rest.len < 4) return error.CorruptFsmonitor;
        const size = std.mem.readInt(u32, rest[0..4], .big);
        if (rest.len - 4 < size) return error.CorruptFsmonitor;
        var dirty = try ewah.read(gpa, rest[4..][0..size]);
        defer dirty.bits.deinit();
        const positions = dirty.bits.positions;
        const fits = positions.len == 0 or positions[positions.len - 1] < index.entries.items.len;
        if (index.was_split or !fits) return;
        var next: usize = 0;
        for (index.entries.items, 0..) |*entry, at| {
            const is_dirty = next < positions.len and positions[next] == at;
            if (is_dirty) next += 1;
            entry.fsmonitor_valid = !is_dirty and entry.mode != .gitlink;
        }
    }

    /// One extension the file carries, after the entries.
    fn readExtension(index: *Index, gpa: Allocator, signature: [4]u8, data: []const u8) ReadError!void {
        // an extension given twice: the later one stands, as in git
        // One that cannot be read is dropped and said, as git drops it.
        if (std.mem.eql(u8, &signature, "TREE")) {
            const tree = CacheTree.parse(gpa, index.kind, data) catch |err| switch (err) {
                error.CorruptCacheTree => null,
                else => |e| return e,
            };
            if (index.cache_tree) |*t| t.deinit();
            index.cache_tree = tree;
            index.dropped.cache_tree = tree == null;
        } else if (std.mem.eql(u8, &signature, "REUC")) {
            const undo = ResolveUndo.parse(gpa, index.kind, data) catch |err| switch (err) {
                error.CorruptResolveUndo => null,
                else => |e| return e,
            };
            if (index.resolve_undo) |*r| r.deinit();
            index.resolve_undo = undo;
            index.dropped.resolve_undo = undo == null;
        } else if (std.mem.eql(u8, &signature, "UNTR")) {
            const cache = try untracked_mod.parse(gpa, index.kind, data);
            if (index.untracked) |*u| u.deinit();
            index.untracked = cache;
            index.dropped.untracked_cache = cache == null;
        } else if (std.mem.eql(u8, &signature, "link")) {
            try index.parseLink(gpa, data);
        } else if (std.mem.eql(u8, &signature, "EOIE")) {
            // A cache of one byte offset into this very file. Copying it
            // into a file whose entries have moved would point it at the
            // wrong place, so what is kept is that it was there and the
            // offset is taken again on write.
            index.had_end_of_index_entries = true;
        } else if (std.mem.eql(u8, &signature, "IEOT")) {
            // The same, once per block of entries. How many blocks it
            // named is kept, because that is a reader's choice and not
            // something to invent; the offsets are taken again.
            if (data.len >= 4) {
                const version_field = std.mem.readInt(u32, data[0..4], .big);
                if (version_field == ieot_version) {
                    index.entry_offset_blocks = @intCast((data.len - 4) / 8);
                }
            }
        } else if (std.mem.eql(u8, &signature, "sdir")) {
            // It carries nothing; being there is what it says.
            index.sparse = true;
        } else if (std.mem.eql(u8, &signature, "FSMN")) {
            index.parseFsmonitor(gpa, data) catch |err| switch (err) {
                error.CorruptFsmonitor, error.TruncatedBitmap, error.CorruptBitmap, error.BitmapTooLarge => {
                    if (index.fsmonitor_token) |old| gpa.free(old);
                    index.fsmonitor_token = null;
                    index.dropped.fsmonitor = true;
                },
                else => |e| return e,
            };
        } else if (signature[0] >= 'A' and signature[0] <= 'Z') {
            const copy = try gpa.dupe(u8, data);
            index.unknown.append(gpa, .{ .signature = signature, .data = copy }) catch |err| {
                gpa.free(copy);
                return err;
            };
        } else {
            index.unsupported_extension = signature;
            return error.UnsupportedExtension;
        }
    }

    fn parseLink(index: *Index, gpa: Allocator, data: []const u8) ReadError!void {
        const raw_len = index.kind.rawLen();
        if (data.len < raw_len) return error.TruncatedIndex;
        const base = Oid.fromCut(index.kind, data[0..raw_len]);
        index.was_split = true;
        if (index.split) |*old| old.deinit(gpa);
        index.split = .{ .base = if (base.isZero()) null else base };

        var rest = data[raw_len..];
        if (rest.len == 0) {
            index.split_delete = null;
            index.split_replace = null;
            return;
        }
        var deletes = try ewah.read(gpa, rest);
        errdefer deletes.bits.deinit();
        rest = rest[deletes.len..];
        var replaces = try ewah.read(gpa, rest);
        // "garbage at the end of link extension"
        if (replaces.len != rest.len) {
            replaces.bits.deinit();
            return error.CorruptLinkExtension;
        }
        index.split_delete = deletes.bits;
        index.split_replace = replaces.bits;
    }

    fn mergeShared(index: *Index, gpa: Allocator, io: Io, git_dir: Io.Dir, base: Oid) ReadError!void {
        var hex: [hash.max_hex_len]u8 = undefined;
        var name_buf: [hash.max_hex_len + 16]u8 = undefined;
        // unreachable: a hex name is at most max_hex_len digits, the prefix twelve bytes
        const name = std.mem.print(&name_buf, "sharedindex.{s}", .{base.hex(&hex)}) catch unreachable;
        const shared_bytes = (try fs.readFileAlloc(gpa, io, git_dir, name, 1 << 31)) orelse
            return error.SharedIndexMissing;
        defer gpa.free(shared_bytes);
        // The file is named by its checksum, and git refuses one whose
        // checksum is another ("broken index, expect ...").
        const raw_len = index.kind.rawLen();
        if (shared_bytes.len < raw_len or !std.mem.eql(u8, shared_bytes[shared_bytes.len - raw_len ..], base.raw())) return error.ChecksumMismatch;

        var shared = try parse(gpa, index.kind, shared_bytes);
        defer shared.deinit();

        // Every path in `merged` is its own copy until it replaces the
        // overlay, so a refusal part way leaves the overlay whole for its
        // owner to release, and nothing is freed twice.
        var merged: std.ArrayList(Entry) = .empty;
        errdefer {
            for (merged.items) |e| gpa.free(e.path);
            merged.deinit(gpa);
        }

        // git's `merge_base_index`: no position past the shared index's end;
        // the overlay's first entries, each with an empty name, replace
        // positions in the shared index in order, before any is deleted, so
        // a position both replaced and deleted is gone; the rest are
        // additions, each with a name.
        for ([_]?ewah.Bits{ index.split_delete, index.split_replace }) |maybe| if (maybe) |bits| {
            if (bits.positions.len != 0 and bits.positions[bits.positions.len - 1] >= shared.entries.items.len) return error.CorruptLinkExtension;
        };
        var replacement: usize = 0;
        for (shared.entries.items, 0..) |base_entry, base_at| {
            const pos: u32 = @intCast(base_at);
            const replaced = if (index.split_replace) |bits| bits.isSet(pos) else false;
            if (replaced) {
                // "too many replacements"
                if (replacement >= index.entries.items.len) return error.CorruptLinkExtension;
                if (index.entries.items[replacement].path.len != 0) return error.CorruptLinkExtension;
                replacement += 1;
            }
            if (index.split_delete) |bits| {
                if (bits.isSet(pos)) continue;
            }
            try merged.ensureUnusedCapacity(gpa, 1);
            if (replaced) {
                var overlay = index.entries.items[replacement - 1];
                overlay.path = try gpa.dupe(u8, base_entry.path);
                overlay.shared_at = pos + 1;
                merged.appendAssumeCapacity(overlay);
                continue;
            }
            merged.appendAssumeCapacity(.{
                .path = try gpa.dupe(u8, base_entry.path),
                .oid = base_entry.oid,
                .mode = base_entry.mode,
                .raw_mode = base_entry.raw_mode,
                .stage = base_entry.stage,
                .assume_valid = base_entry.assume_valid,
                .skip_worktree = base_entry.skip_worktree,
                .intent_to_add = base_entry.intent_to_add,
                .stat = base_entry.stat,
                .shared_at = pos + 1,
            });
        }
        for (index.entries.items[replacement..]) |extra| {
            if (extra.path.len == 0) return error.CorruptLinkExtension;
            try merged.ensureUnusedCapacity(gpa, 1);
            var copy = extra;
            copy.path = try gpa.dupe(u8, extra.path);
            copy.shared_at = 0;
            merged.appendAssumeCapacity(copy);
        }

        std.mem.sort(Entry, merged.items, {}, lessThan);
        // What `parse` checks of an index that is not split, now that there
        // are paths to check: an overlay's additions carry their own.
        for (merged.items) |e| {
            if (e.path.len == 0) return error.InvalidEntryPath;
        }
        if (merged.items.len > 1) {
            for (merged.items[1..], merged.items[0 .. merged.items.len - 1]) |b, a| {
                if (Entry.order(a, b) != .lt) return error.UnsortedIndex;
            }
        }

        for (index.entries.items) |e| gpa.free(e.path);
        index.entries.deinit(gpa);
        index.entries = merged;
        // The shared entries stay: what the next write compares against.
        index.split.?.shared = shared.entries;
        shared.entries = .empty;

        if (index.split_delete) |*b| b.deinit();
        if (index.split_replace) |*b| b.deinit();
        index.split_delete = null;
        index.split_replace = null;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return Entry.order(a, b) == .lt;
    }

    /// An entry's fixed part, past its object name: its stat data (forty
    /// bytes, the object name after them) and its flags.
    const entry_fixed_len = 40 + 2;

    /// The entry whose fixed part is `b`, the rest of it taken from `r`:
    /// its extended flags, its path and, before version 4, the padding.
    fn parseEntry(
        gpa: Allocator,
        kind: Kind,
        version: u32,
        b: []const u8,
        r: *Io.Reader,
        previous_path: []const u8,
    ) ReadError!Entry {
        const raw_len = kind.rawLen();
        const flags = std.mem.readInt(u16, b[40 + raw_len ..][0..2], .big);
        // git reads the extended flag word whatever the version says, and
        // refuses a bit in it it does not know.
        const extended = flags & 0x4000 != 0;
        var skip_worktree = false;
        var intent_to_add = false;
        if (extended) {
            const extra = r.takeInt(u16, .big) catch return error.TruncatedIndex;
            if (extra & ~@as(u16, 0x6000) != 0) return error.UnknownEntryFlags;
            skip_worktree = extra & 0x4000 != 0;
            intent_to_add = extra & 0x2000 != 0;
        }

        var path: []const u8 = undefined;
        if (version >= 4) {
            const strip = try varint.takeOffset(r);
            if (strip > previous_path.len) return error.TruncatedIndex;
            const keep = previous_path[0 .. previous_path.len - strip];
            const suffix = r.takeSentinel(0) catch return error.TruncatedIndex;
            const joined = try gpa.alloc(u8, keep.len + suffix.len);
            @memcpy(joined[0..keep.len], keep);
            @memcpy(joined[keep.len..], suffix);
            path = joined;
        } else {
            const stated: usize = flags & 0x0fff;
            const found = r.takeSentinel(0) catch return error.TruncatedIndex;
            if (stated != 0x0fff and found.len != stated) return error.TruncatedIndex;
            // One to eight NULs pad the entry to a multiple of eight bytes.
            const unpadded = b.len + @as(usize, if (extended) 2 else 0) + found.len + 1;
            r.discardAll(std.mem.alignForward(usize, unpadded, 8) - unpadded) catch return error.TruncatedIndex;
            path = try gpa.dupe(u8, found);
        }
        errdefer gpa.free(path);

        // A path is not checked here, as git's `do_read_index` checks none:
        // the checkout that would write one refuses it (`names.path`), so an
        // index another platform wrote opens wherever git opens it. An empty
        // name is only legal in a split index's overlay, and a trailing
        // slash only on a sparse directory; both are checked once the
        // extensions have been read.

        const mode_raw = std.mem.readInt(u32, b[24..28], .big);
        const mode = Entry.modeOf(mode_raw);

        return .{
            .path = path,
            .oid = Oid.fromCut(kind, b[40..][0..raw_len]),
            .mode = mode,
            .raw_mode = if (mode_raw == mode.raw()) null else mode_raw,
            .stage = @truncate((flags >> 12) & 3),
            .assume_valid = flags & 0x8000 != 0,
            .skip_worktree = skip_worktree,
            .intent_to_add = intent_to_add,
            .stat = .{
                .ctime_sec = std.mem.readInt(u32, b[0..4], .big),
                .ctime_nsec = std.mem.readInt(u32, b[4..8], .big),
                .mtime_sec = std.mem.readInt(u32, b[8..12], .big),
                .mtime_nsec = std.mem.readInt(u32, b[12..16], .big),
                .dev = std.mem.readInt(u32, b[16..20], .big),
                .ino = std.mem.readInt(u32, b[20..24], .big),
                .uid = std.mem.readInt(u32, b[28..32], .big),
                .gid = std.mem.readInt(u32, b[32..36], .big),
                .size = std.mem.readInt(u32, b[36..40], .big),
            },
        };
    }

    /// The entries, sorted by path and then stage. Borrowed from the index.
    pub fn items(index: *const Index) []const Entry {
        return index.entries.items;
    }

    /// The entry for `path` at stage 0, or `null`. A bisection.
    pub fn find(index: *const Index, path: []const u8) ?*Entry {
        return index.findStage(path, 0);
    }

    /// The entry for `path` at `stage`, or `null`.
    pub fn findStage(index: *const Index, path: []const u8, stage: u2) ?*Entry {
        const probe: Entry = .{ .path = path, .oid = undefined, .mode = .file, .stage = stage };
        var lo: usize = 0;
        var hi: usize = index.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (Entry.order(index.entries.items[mid], probe)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return &index.entries.items[mid],
            }
        }
        return null;
    }

    /// Where `path` at `stage` would go, whether or not it is there.
    fn position(index: *const Index, path: []const u8, stage: u2) usize {
        const probe: Entry = .{ .path = path, .oid = undefined, .mode = .file, .stage = stage };
        var lo: usize = 0;
        var hi: usize = index.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (Entry.order(index.entries.items[mid], probe) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Whether any entry lies under the directory `dir`, which must not end
    /// in a slash.
    pub fn hasDirectory(index: *const Index, dir: []const u8) bool {
        var buf: [4096]u8 = undefined;
        if (dir.len + 1 > buf.len) return false;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = '/';
        const prefix = buf[0 .. dir.len + 1];
        const at = index.position(prefix, 0);
        if (at >= index.entries.items.len) return false;
        return std.mem.startsWith(u8, index.entries.items[at].path, prefix);
    }

    /// Errors from `add` and `addMany`.
    pub const AddError = Allocator.Error || error{
        /// A path git's `verify_path` refuses: an empty, `.` or `..`
        /// component, `.git` in any spelling `protect` names, `.gitmodules`
        /// for a symbolic link. git's `add_index_entry_with_check` refuses
        /// it ("invalid path"), so no tree or patch puts it in an index.
        UnsafePath,
    };

    /// Whether git's `verify_path` lets `entry`'s path into an index: a
    /// sparse directory is its directory's name with a `/` after it.
    pub fn verifyPath(index: *const Index, entry: Entry) AddError!void {
        const path = if (entry.isSparseDirectory()) entry.path[0 .. entry.path.len - 1] else entry.path;
        _ = names_path.checked(path, .{ .use = .worktree, .protect = index.protect, .symlink = entry.mode == .symlink }) catch return error.UnsafePath;
    }

    /// Add or replace an entry. `entry.path` is copied.
    pub fn add(index: *Index, entry: Entry) AddError!void {
        try index.verifyPath(entry);
        const at = index.position(entry.path, entry.stage);
        if (at < index.entries.items.len) {
            const existing = &index.entries.items[at];
            if (Entry.order(existing.*, entry) == .eq) {
                var replacement = entry;
                replacement.path = existing.path;
                existing.* = replacement;
                return;
            }
        }
        var copy = entry;
        copy.path = try index.gpa.dupe(u8, entry.path);
        errdefer index.gpa.free(copy.path);
        try index.entries.insert(index.gpa, at, copy);
        index.untrackedJoined(entry.path);
    }

    /// A path that joined or left the index: the untracked cache's
    /// directories for it are out of date, as git's
    /// `untracked_cache_add_to_index` and `untracked_cache_remove_from_index`
    /// say.
    fn untrackedJoined(index: *Index, path: []const u8) void {
        if (index.untracked) |*cache| cache.invalidatePath(path);
    }

    /// Add many entries at once: sorted among themselves and merged in.
    ///
    /// Inserting into a sorted list one entry at a time is quadratic in the
    /// number of entries, and a working-tree walk produces paths in tree
    /// order rather than index order, so it hits that every time. Each
    /// `path` is copied; an entry whose path and stage are already there is
    /// replaced.
    pub fn addMany(index: *Index, entries: []const Entry) AddError!void {
        if (entries.len == 0) return;
        for (entries) |entry| try index.verifyPath(entry);
        const gpa = index.gpa;
        // The new entries sorted among themselves, then merged with the
        // sorted list in one pass: a few entries added to a large index
        // cost a copy of it, not a sort.
        const fresh = try gpa.alloc(Entry, entries.len);
        defer gpa.free(fresh);
        var copied: usize = 0;
        errdefer for (fresh[0..copied]) |e| gpa.free(e.path);
        for (entries, fresh) |entry, *slot| {
            slot.* = entry;
            slot.path = try gpa.dupe(u8, entry.path);
            copied += 1;
        }
        var merged: std.ArrayList(Entry) = try .initCapacity(gpa, index.entries.items.len + fresh.len);
        errdefer merged.deinit(gpa);

        // A stable sort keeps a later duplicate after the earlier one, so
        // the last one added wins, which is what `add` does too.
        std.mem.sort(Entry, fresh, {}, lessThan);
        var kept: usize = 0;
        for (fresh, 0..) |entry, at| {
            if (at + 1 < fresh.len and Entry.order(fresh[at + 1], entry) == .eq) {
                gpa.free(entry.path);
                continue;
            }
            fresh[kept] = entry;
            kept += 1;
        }
        copied = 0;

        const old = index.entries.items;
        var i: usize = 0;
        var j: usize = 0;
        while (i < old.len or j < kept) {
            const order: std.math.Order = if (j == kept) .lt else if (i == old.len) .gt else Entry.order(old[i], fresh[j]);
            switch (order) {
                .lt => {
                    merged.appendAssumeCapacity(old[i]);
                    i += 1;
                },
                .gt => {
                    merged.appendAssumeCapacity(fresh[j]);
                    index.untrackedJoined(fresh[j].path);
                    j += 1;
                },
                .eq => {
                    gpa.free(old[i].path);
                    merged.appendAssumeCapacity(fresh[j]);
                    i += 1;
                    j += 1;
                },
            }
        }
        index.entries.deinit(gpa);
        index.entries = merged;
    }

    /// Remove every entry whose path is in `paths`, which must be sorted.
    ///
    /// One pass rather than one removal each, because removing from the
    /// middle of a sorted list is linear and doing it per path is quadratic.
    pub fn removeMany(index: *Index, paths: []const []const u8) void {
        if (paths.len == 0) return;
        // Every entry is decided before any path is freed: `paths` may
        // borrow the entries' own bytes. A kept entry is swapped forward,
        // so the dropped ones gather at the end, still whole, and go after.
        const list = index.entries.items;
        var write_at: usize = 0;
        for (list, 0..) |entry, read_at| {
            if (std.sort.binarySearch([]const u8, paths, entry.path, orderPath) != null) {
                index.untrackedJoined(entry.path);
                continue;
            }
            std.mem.swap(Entry, &list[write_at], &list[read_at]);
            write_at += 1;
        }
        for (list[write_at..]) |entry| index.gpa.free(entry.path);
        index.entries.shrinkRetainingCapacity(write_at);
    }

    /// Remove `path` at every stage. Returns how many entries went.
    /// `path` may be an entry's own: it is read before any is freed.
    pub fn remove(index: *Index, path: []const u8) usize {
        const at = index.position(path, 0);
        var end = at;
        while (end < index.entries.items.len and std.mem.eql(u8, index.entries.items[end].path, path)) end += 1;
        if (end == at) return 0;
        index.untrackedJoined(path);
        for (index.entries.items[at..end]) |e| index.gpa.free(e.path);
        index.entries.replaceRangeAssumeCapacity(at, end - at, &.{});
        return end - at;
    }

    /// Move the stage-0 entry at `from` to `to`, whole, as git's
    /// `rename_index_entry_at` does, and drop what it would collide with
    /// there, as `add_index_entry` replacing does: `to` at every stage, the
    /// entries under `to/`, and one for a directory above `to`. The cache
    /// tree forgets both paths. `false` when `from` has no stage-0 entry.
    pub fn rename(index: *Index, from: []const u8, to: []const u8) AddError!bool {
        const found = index.find(from) orelse return false;
        var moved = found.*;
        moved.path = to;
        // Refused before anything moves, so a refusal leaves the index whole.
        try index.verifyPath(moved);
        moved.shared_at = 0;
        if (index.cache_tree) |*tree| {
            tree.invalidate(from);
            tree.invalidate(to);
        }
        _ = index.remove(from);
        _ = index.remove(to);
        _ = try index.removeDirectory(to);
        var above = to;
        while (std.mem.findScalarLast(u8, above, '/')) |slash| {
            above = above[0..slash];
            _ = index.remove(above);
        }
        try index.add(moved);
        return true;
    }

    /// Remove every entry under the directory `dir`. Returns how many went.
    pub fn removeDirectory(index: *Index, dir: []const u8) Allocator.Error!usize {
        const prefix = try index.gpa.print("{s}/", .{dir});
        defer index.gpa.free(prefix);
        var removed: usize = 0;
        const at = index.position(prefix, 0);
        while (at < index.entries.items.len and std.mem.startsWith(u8, index.entries.items[at].path, prefix)) {
            index.untrackedJoined(index.entries.items[at].path);
            index.gpa.free(index.entries.items[at].path);
            _ = index.entries.orderedRemove(at);
            removed += 1;
        }
        return removed;
    }

    /// Remember a conflict stage that is leaving the index, as git's
    /// `record_resolve_undo` does when a resolution replaces one: the
    /// `REUC` extension gains the path, kept in path order, with the
    /// stage's mode and object. A stage-0 entry is not recorded.
    pub fn recordResolveUndo(index: *Index, entry: Entry) Allocator.Error!void {
        if (entry.stage == 0) return;
        if (index.resolve_undo == null) index.resolve_undo = .{ .gpa = index.gpa, .entries = .empty };
        const undo = &index.resolve_undo.?;
        var lo: usize = 0;
        var hi: usize = undo.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, undo.entries.items[mid].path, entry.path) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo == undo.entries.items.len or !std.mem.eql(u8, undo.entries.items[lo].path, entry.path)) {
            const path = try index.gpa.dupe(u8, entry.path);
            errdefer index.gpa.free(path);
            try undo.entries.insert(index.gpa, lo, .{ .path = path, .modes = @splat(0), .oids = @splat(null) });
        }
        const item = &undo.entries.items[lo];
        item.modes[entry.stage - 1] = entry.mode.raw();
        item.oids[entry.stage - 1] = entry.oid;
    }

    /// Remove `path`'s conflict stages, remembering each with
    /// `recordResolveUndo`, as git does when a stage-0 entry replaces them.
    /// Returns how many went.
    pub fn resolveStages(index: *Index, path: []const u8) Allocator.Error!usize {
        var removed: usize = 0;
        var at = index.position(path, 1);
        while (at < index.entries.items.len and std.mem.eql(u8, index.entries.items[at].path, path)) {
            const entry = index.entries.items[at];
            if (entry.stage == 0) {
                at += 1;
                continue;
            }
            try index.recordResolveUndo(entry);
            index.gpa.free(entry.path);
            _ = index.entries.orderedRemove(at);
            removed += 1;
        }
        return removed;
    }

    /// Forget what resolutions replaced, as git's `unpack_trees` does when
    /// its result becomes the index: a checkout, a reset or a merge leaves
    /// no `REUC` behind.
    pub fn dropResolveUndo(index: *Index) void {
        if (index.resolve_undo) |*undo| undo.deinit();
        index.resolve_undo = null;
    }

    /// Drop every entry, leaving the extensions alone.
    pub fn clear(index: *Index) void {
        if (index.untracked) |*cache| cache.invalidateAll();
        for (index.entries.items) |e| index.gpa.free(e.path);
        index.entries.clearRetainingCapacity();
    }

    /// Whether an entry is racily clean: its recorded modification time is
    /// not older than the index file's own, so the stat cannot prove the
    /// content is unchanged and it must be read.
    ///
    /// This is the rule that separates an `addAll` which notices a file
    /// rewritten inside one second from one which does not.
    pub fn isRacy(index: *const Index, entry: Entry) bool {
        if (index.racy_cutoff_sec == 0 and index.racy_cutoff_nsec == 0) return false;
        // A gitlink's stat says nothing about its content, which is always
        // looked at, so it is never racy: git's `is_racy_timestamp`.
        if (entry.mode == .gitlink) return false;
        if (entry.stat.mtime_sec > index.racy_cutoff_sec) return true;
        if (entry.stat.mtime_sec < index.racy_cutoff_sec) return false;
        // Equal seconds. A filesystem that keeps nothing below a second
        // cannot put the two in order at all, so everything written in the
        // index's own second is racy -- which is the measurement earning its
        // keep, because assuming nanoseconds here is how a file rewritten
        // inside one second goes unnoticed.
        if (!index.timestamp_resolution.hasSubsecond()) return true;
        if (entry.stat.mtime_nsec == 0 or index.racy_cutoff_nsec == 0) return true;
        const unit = index.timestamp_resolution.ns;
        return entry.stat.mtime_nsec / unit >= index.racy_cutoff_nsec / unit;
    }

    /// The version `write` would use under `options`.
    pub fn versionFor(index: *const Index, options: WriteOptions) u32 {
        return index.versionOver(index.entries.items, options);
    }

    /// The version a file holding `entries` is written in: under `auto`,
    /// 2 or 3 as they need, git's demotion, counted over what the file
    /// holds -- a split index's own entries, not its shared ones.
    fn versionOver(index: *const Index, entries: []const Entry, options: WriteOptions) u32 {
        return switch (options.version) {
            .v2 => 2,
            .v3 => 3,
            .v4 => 4,
            .auto => blk: {
                const carried = if (index.version != 0) index.version else options.new_version;
                if (carried != 2 and carried != 3) break :blk carried;
                for (entries) |e| {
                    if (e.needsExtendedFlags()) break :blk 3;
                }
                break :blk 2;
            },
        };
    }

    /// Make this a split index, as git's `add_split_index` does: its next
    /// write writes a shared index first.
    pub fn useSplit(index: *Index) void {
        if (index.split == null) index.split = .{};
    }

    /// Write it whole again, as git's `remove_split_index` has it.
    pub fn dropSplit(index: *Index) void {
        if (index.split) |*s| s.deinit(index.gpa);
        index.split = null;
        for (index.entries.items) |*e| e.shared_at = 0;
    }

    /// How many entries no shared index holds: what
    /// `splitIndex.maxPercentChange` weighs, as git's
    /// `too_many_not_shared_entries` counts them.
    pub fn notShared(index: *const Index) usize {
        var count: usize = 0;
        for (index.entries.items) |e| count += @intFromBool(e.shared_at == 0);
        return count;
    }

    /// git's `write_shared_index`: every entry written, with no extension
    /// but the offset tables `options` asks for, into `sharedindex.<hex>`
    /// in `git_dir`, named by its checksum, which becomes the split
    /// index's base; each entry is then shared at its place. Returns the
    /// new file's modification time, which is the time its expiry counts
    /// from.
    pub fn writeShared(index: *Index, io: Io, git_dir: Io.Dir, options: WriteOptions) Self.WriteError!Io.Timestamp {
        if (index.sparse) return error.SparseSplitIndex;
        var bytes: Io.Writer.Allocating = .init(index.gpa);
        defer bytes.deinit();
        index.writeBody(&bytes.writer, options, .{ .entries = index.entries.items, .extensions = false }) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        const written = bytes.written();
        const raw_len = index.kind.rawLen();
        const checksum = Oid.fromCut(index.kind, written[written.len - raw_len ..]);
        var hex: [hash.max_hex_len]u8 = undefined;
        var name_buf: [hash.max_hex_len + 16]u8 = undefined;
        // unreachable: a hex name is at most max_hex_len digits, the prefix twelve bytes
        const name = std.mem.print(&name_buf, "sharedindex.{s}", .{checksum.hex(&hex)}) catch unreachable;
        const buffer = try index.gpa.alloc(u8, 64 * 1024);
        defer index.gpa.free(buffer);
        var lock = try fs.LockFile.open(index.gpa, io, git_dir, .{ .sub_path = name, .buffer = buffer }, options.lock);
        defer lock.deinit(io);
        try lock.writer().writeAll(written);
        try lock.commit(io);

        var shared: std.ArrayList(Entry) = try .initCapacity(index.gpa, index.entries.items.len);
        errdefer {
            for (shared.items) |e| index.gpa.free(e.path);
            shared.deinit(index.gpa);
        }
        for (index.entries.items, 0..) |*e, at| {
            var copy = e.*;
            copy.path = try index.gpa.dupe(u8, e.path);
            shared.appendAssumeCapacity(copy);
            e.shared_at = @intCast(at + 1); // at most the count `writeBody` held to a u32
        }
        if (index.split) |*old| old.deinit(index.gpa);
        index.split = .{ .base = checksum, .shared = shared };
        const stat = git_dir.statFile(io, name, .{}) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.FileSystem,
        };
        return stat.mtime;
    }

    /// git's `clean_shared_index_files`: every other `sharedindex.*` in
    /// `git_dir` whose modification time is not after `expire`, in
    /// seconds, goes. An expiry of 0 is never.
    pub fn removeSharedBefore(index: *const Index, io: Io, git_dir: Io.Dir, expire: date.Expiry) void {
        if (expire.eql(.fromRaw(0))) return;
        const base = (index.split orelse return).base orelse return;
        var hex: [hash.max_hex_len]u8 = undefined;
        const current = base.hex(&hex);
        var dir = git_dir.openDir(io, ".", .{ .iterate = true }) catch |err| return std.log.warn("unable to open git dir: {t}", .{err});
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch |err| return std.log.warn("unable to read git dir: {t}", .{err})) |entry| {
            const rest = if (std.mem.startsWith(u8, entry.name, "sharedindex.")) entry.name["sharedindex.".len..] else continue;
            if (std.mem.eql(u8, rest, current)) continue;
            const stat = dir.statFile(io, entry.name, .{}) catch |err| {
                std.log.warn("could not stat '{s}': {t}", .{ entry.name, err });
                continue;
            };
            if (date.instant(stat.mtime).compare(expire) == .gt) continue;
            dir.deleteFile(io, entry.name) catch |err| std.log.warn("unable to unlink: {s}: {t}", .{ entry.name, err });
        }
    }

    /// The main file of a split index, as git's
    /// `prepare_to_write_split_index` lays it out: an entry the shared
    /// index holds at its place, unchanged and not racy, stays there; one
    /// changed is a replacement, written first with no name; the shared
    /// entries no entry holds any more are deleted; the rest are written
    /// after the replacements.
    fn writeSplitTo(index: *Index, w: *Io.Writer, options: WriteOptions, split: *const Split, base: Oid) WriteToError!void {
        if (index.sparse) return error.SparseSplitIndex;
        const gpa = index.gpa;
        const shared = split.shared.items;
        const matched = try gpa.alloc(bool, shared.len);
        defer gpa.free(matched);
        @memset(matched, false);
        var replace: std.ArrayList(u32) = .empty;
        defer replace.deinit(gpa);
        var written: std.ArrayList(Entry) = .empty;
        defer written.deinit(gpa);
        var fresh: std.ArrayList(Entry) = .empty;
        defer fresh.deinit(gpa);
        for (index.entries.items) |entry| {
            const at = entry.shared_at;
            if (at == 0 or at > shared.len or matched[at - 1] or !std.mem.eql(u8, shared[at - 1].path, entry.path)) {
                try fresh.append(gpa, entry);
                continue;
            }
            matched[at - 1] = true;
            // A racily clean entry goes into this file, where its stat can
            // be smudged, as git's does.
            if (sameOnDisk(entry, shared[at - 1]) and !index.isRacy(entry)) continue;
            try replace.append(gpa, at - 1);
            try written.append(gpa, entry);
        }
        // Positions rise, since the entries and the shared index are both
        // in path order.
        var delete: std.ArrayList(u32) = .empty;
        defer delete.deinit(gpa);
        for (matched, 0..) |m, at| if (!m) try delete.append(gpa, @intCast(at)); // below the shared index's count, a u32 in its file
        const nameless = written.items.len;
        try written.appendSlice(gpa, fresh.items);

        var link: std.ArrayList(u8) = .empty;
        defer link.deinit(gpa);
        try link.appendSlice(gpa, base.raw());
        for ([_][]const u32{ delete.items, replace.items }) |positions| {
            const bitmap = try ewah.writePositions(gpa, positions);
            defer gpa.free(bitmap);
            try link.appendSlice(gpa, bitmap);
        }
        return index.writeBody(w, options, .{ .entries = written.items, .nameless = nameless, .link = link.items });
    }

    /// Whether two entries say the same on the disk but for their names:
    /// git's `compare_ce_content`.
    fn sameOnDisk(a: Entry, b: Entry) bool {
        return std.meta.eql(a.stat, b.stat) and a.oid.eql(b.oid) and a.diskMode() == b.diskMode() and
            a.stage == b.stage and a.assume_valid == b.assume_valid and
            a.skip_worktree == b.skip_worktree and a.intent_to_add == b.intent_to_add;
    }

    /// Write the index to `sub_path` in `dir`, through `<sub_path>.lock`.
    ///
    /// A lock another writer holds is `error.LockHeld` and is left exactly as
    /// it was found.
    pub fn write(index: *Index, io: Io, dir: Io.Dir, sub_path: []const u8, options: WriteOptions) Self.WriteError!void {
        const buffer = try index.gpa.alloc(u8, 64 * 1024);
        defer index.gpa.free(buffer);
        var lock = try fs.LockFile.open(index.gpa, io, dir, .{ .sub_path = sub_path, .buffer = buffer }, options.lock);
        defer lock.deinit(io);
        try index.commitTo(io, &lock, options);
    }

    /// Write the index into `lock`, already held on the file it replaces,
    /// and put it in place: the end of a write whose lock was taken before
    /// the index was read, as git's `repo_hold_locked_index` takes it.
    pub fn commitTo(index: *Index, io: Io, lock: *fs.LockFile, options: WriteOptions) Self.WriteError!void {
        try index.writeTo(lock.writer(), options);
        try lock.commit(io);
        // The file just written is the racy cutoff from now on, as git's
        // `do_write_index` takes it: an entry written in its second is
        // racy for a caller that keeps this index and does not read it
        // again.
        if (lock.dir.statFile(io, lock.target, .{})) |stat| {
            const s = fs.Stat.fromIo(stat, .{});
            index.racy_cutoff_sec = s.mtime_sec;
            index.racy_cutoff_nsec = s.mtime_nsec;
        } else |err| if (err == error.Canceled) return error.Canceled;
    }

    /// Errors from `writeTo`.
    pub const WriteToError = Io.Writer.Error || WriteError;

    /// Append the index's bytes to `w`.
    ///
    /// Used by `write`, and by a caller that wants the bytes without a file —
    /// a test comparing them against git's, for instance.
    pub fn writeTo(index: *Index, w: *Io.Writer, options: WriteOptions) WriteToError!void {
        if (index.split) |*split| if (split.base) |base| return index.writeSplitTo(w, options, split, base);
        return index.writeBody(w, options, .{ .entries = index.entries.items });
    }

    /// What `writeBody` lays down.
    const Body = struct {
        entries: []const Entry,
        /// How many of `entries`, from the first, go with no name: a split
        /// index's replacements, which take their shared entries' names.
        nameless: usize = 0,
        /// The `link` extension's bytes, for a split index.
        link: ?[]const u8 = null,
        /// Whether the extensions that carry content go too: not into a
        /// shared index, which git writes with none of them.
        extensions: bool = true,
    };

    fn writeBody(index: *Index, w: *Io.Writer, options: WriteOptions, spec: Body) WriteToError!void {
        const entries = spec.entries;
        const version = index.versionOver(entries, options);
        aegis.assert.invariant(version >= 2, "version >= 2");
        aegis.assert.invariant(version <= 4, "version <= 4");
        index.version = version;
        // The entries rise, each path and stage once: what reading the
        // index back checks. The entries are the caller's to change, so
        // this is a refusal and not an assertion.
        if (index.entries.items.len > 1) for (1..index.entries.items.len) |i| {
            if (Entry.order(index.entries.items[i - 1], index.entries.items[i]) != .lt) return error.UnsortedIndex;
        };
        if (version == 2) {
            for (entries) |entry| {
                if (entry.needsExtendedFlags()) return error.ExtendedFlagsRequireVersion3;
            }
        }
        const raw_len = index.kind.rawLen();

        // The trailer is a hash of everything before it, so the body is
        // built first and handed over whole. An index is already in memory
        // entry by entry; holding its bytes once more costs nothing a
        // streaming hash would save.
        var body: Io.Writer.Allocating = .init(index.gpa);
        defer body.deinit();
        const out = &body.writer;

        var header: [12]u8 = undefined;
        @memcpy(header[0..4], magic);
        std.mem.writeInt(u32, header[4..8], version, .big);
        const entry_count = std.math.cast(u32, entries.len) orelse return error.TooManyEntries;
        std.mem.writeInt(u32, header[8..12], entry_count, .big);
        try out.writeAll(&header);

        // How the entries are divided for `IEOT`, and where each block
        // starts. A block boundary is a byte offset into this file, so the
        // table can only be built while the file is.
        const blocks: u32 = blk: {
            const want = options.entry_offset_blocks orelse index.entry_offset_blocks;
            const count: u32 = @intCast(entries.len);
            break :blk @min(want, count);
        };
        var table: std.ArrayList(OffsetBlock) = .empty;
        defer table.deinit(index.gpa);
        const per_block: usize = if (blocks > 1)
            (entries.len + blocks - 1) / blocks
        else
            0;
        var block_start: usize = body.written().len;
        var block_count: u32 = 0;

        var previous_path: []const u8 = "";
        for (entries, 0..) |entry, i| {
            const name = if (i < spec.nameless) "" else entry.path;
            if (name.len > std.math.maxInt(u16)) return error.PathTooLong;
            // A new block starts here. Its first entry shares no prefix with
            // the last entry of the block before it, so that a reader can
            // decode the blocks independently -- which is the only reason
            // the table exists.
            var starts_block = false;
            if (per_block != 0 and i != 0 and i % per_block == 0) {
                try table.append(index.gpa, .{ .offset = @intCast(block_start), .count = block_count });
                block_start = body.written().len;
                block_count = 0;
                starts_block = true;
            }
            try index.writeEntry(out, entry, name, version, previous_path, starts_block, options);
            previous_path = name;
            block_count += 1;
        }
        if (per_block != 0 and block_count != 0) {
            try table.append(index.gpa, .{ .offset = @intCast(block_start), .count = block_count });
        }

        // Where the entries end and the extensions begin, which is the one
        // number `EOIE` carries.
        const extensions_at: u32 = @intCast(body.written().len);

        try index.writeExtensions(out, table.items, extensions_at, options, spec);

        try w.writeAll(body.written());
        if (options.skip_hash) {
            const zeros: [hash.max_raw_len]u8 = @splat(0);
            try w.writeAll(zeros[0..raw_len]);
        } else {
            var hasher: hash.Hasher = .init(index.kind);
            hasher.update(body.written());
            const checksum = hasher.final();
            try w.writeAll(checksum.raw());
        }
        try w.flush();
    }

    /// One entry as `writeTo` lays it down at `version`: the fixed part,
    /// then the path, prefix-compressed against `previous` from version 4
    /// on unless the entry starts an `IEOT` block, and NUL-padded to eight
    /// bytes before it.
    fn writeEntry(index: *const Index, out: *Io.Writer, entry: Entry, name: []const u8, version: u32, previous: []const u8, starts_block: bool, options: WriteOptions) Io.Writer.Error!void {
        std.debug.assert(name.len <= std.math.maxInt(u16));
        aegis.assert.invariant(version >= 3 or !entry.needsExtendedFlags(), "version >= 3 or !entry.needsExtendedFlags()");
        const raw_len = index.kind.rawLen();
        var fixed: [40 + hash.max_raw_len + 4]u8 = @splat(0);

        // git truncates a racily-clean entry's recorded size to zero, so
        // that a later stat comparison cannot decide the file is
        // unchanged on the strength of a size that was never checked.
        var stat = entry.stat;
        if (index.isRacy(entry)) {
            const changed = if (options.racy) |r| r.changed(r, index, entry) else true;
            if (changed) stat.size = 0;
        }

        std.mem.writeInt(u32, fixed[0..4], stat.ctime_sec, .big);
        std.mem.writeInt(u32, fixed[4..8], stat.ctime_nsec, .big);
        std.mem.writeInt(u32, fixed[8..12], stat.mtime_sec, .big);
        std.mem.writeInt(u32, fixed[12..16], stat.mtime_nsec, .big);
        std.mem.writeInt(u32, fixed[16..20], stat.dev, .big);
        std.mem.writeInt(u32, fixed[20..24], stat.ino, .big);
        std.mem.writeInt(u32, fixed[24..28], entry.diskMode(), .big);
        std.mem.writeInt(u32, fixed[28..32], stat.uid, .big);
        std.mem.writeInt(u32, fixed[32..36], stat.gid, .big);
        std.mem.writeInt(u32, fixed[36..40], stat.size, .big);
        @memcpy(fixed[40..][0..raw_len], entry.oid.raw());

        const extended = entry.needsExtendedFlags() and version >= 3;
        var flags: u16 = @intCast(@min(name.len, 0x0fff));
        flags |= @as(u16, entry.stage) << 12;
        if (entry.assume_valid) flags |= 0x8000;
        if (extended) flags |= 0x4000;
        std.mem.writeInt(u16, fixed[40 + raw_len ..][0..2], flags, .big);
        var fixed_len: usize = 40 + raw_len + 2;
        if (extended) {
            var extra: u16 = 0;
            if (entry.skip_worktree) extra |= 0x4000;
            if (entry.intent_to_add) extra |= 0x2000;
            std.mem.writeInt(u16, fixed[fixed_len..][0..2], extra, .big);
            fixed_len += 2;
        }
        try out.writeAll(fixed[0..fixed_len]);

        if (version >= 4) {
            const shared = if (starts_block) 0 else commonPrefixLen(previous, name);
            var varint_buf: [16]u8 = undefined;
            const strip = varint.writeOffset(&varint_buf, previous.len - shared);
            try out.writeAll(strip);
            try out.writeAll(name[shared..]);
            try out.writeByte(0);
        } else {
            try out.writeAll(name);
            // One to eight NULs: enough to pad the entry to a multiple
            // of eight bytes, and never fewer than the one that
            // terminates the name.
            const padded = (fixed_len + name.len + 1 + 7) & ~@as(usize, 7);
            try out.splatByteAll(0, padded - fixed_len - name.len);
        }
    }

    /// The extensions after the entries, in git's order, `EOIE` last when
    /// asked for: it carries `extensions_at`, where the entries end.
    fn writeExtensions(index: *Index, out: *Io.Writer, table: []const OffsetBlock, extensions_at: u32, options: WriteOptions, spec: Body) (Io.Writer.Error || WriteError)!void {
        const raw_len = index.kind.rawLen();
        // `EOIE` also carries a hash over the header of every extension
        // written before it -- the four signature bytes and the four size
        // bytes, and none of the contents. It is fed as they go out.
        var ext_hasher: hash.Hasher = .init(index.kind);

        // `IEOT` goes first, so that a reader looking for it has the least
        // to walk past. It is git's own order.
        if (table.len != 0) {
            var ieot_body: Io.Writer.Allocating = .init(index.gpa);
            defer ieot_body.deinit();
            var version_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &version_bytes, ieot_version, .big);
            try ieot_body.writer.writeAll(&version_bytes);
            for (table) |block| {
                var pair: [8]u8 = undefined;
                std.mem.writeInt(u32, pair[0..4], block.offset, .big);
                std.mem.writeInt(u32, pair[4..8], block.count, .big);
                try ieot_body.writer.writeAll(&pair);
            }
            try writeExtension(out, "IEOT", ieot_body.written());
            hashExtensionHeader(&ext_hasher, "IEOT", ieot_body.written().len);
        }
        if (spec.link) |link| {
            try writeExtension(out, "link", link);
            hashExtensionHeader(&ext_hasher, "link", link.len);
        }
        if (spec.extensions) try index.writeContentExtensions(out, &ext_hasher, options);

        // `EOIE` is last, and is not part of its own hash.
        if (options.end_of_index_entries orelse index.had_end_of_index_entries) {
            var eoie_body: [4 + hash.max_raw_len]u8 = undefined;
            std.mem.writeInt(u32, eoie_body[0..4], extensions_at, .big);
            const digest = ext_hasher.final();
            @memcpy(eoie_body[4..][0..raw_len], digest.raw());
            try writeExtension(out, "EOIE", eoie_body[0 .. 4 + raw_len]);
        }
    }

    /// The extensions that carry the index's content, after `link`: the
    /// cache tree, resolve-undo, the untracked cache, the file monitor's
    /// token and `sdir`, in git's order.
    fn writeContentExtensions(index: *Index, out: *Io.Writer, ext_hasher: *hash.Hasher, options: WriteOptions) (Io.Writer.Error || WriteError)!void {
        if (options.write_cache_tree) {
            if (index.cache_tree) |*tree| {
                var tree_body: Io.Writer.Allocating = .init(index.gpa);
                defer tree_body.deinit();
                try tree.write(&tree_body.writer);
                try writeExtension(out, "TREE", tree_body.written());
                hashExtensionHeader(ext_hasher, "TREE", tree_body.written().len);
            }
        }
        if (index.resolve_undo) |*undo| {
            var undo_body: Io.Writer.Allocating = .init(index.gpa);
            defer undo_body.deinit();
            try undo.write(&undo_body.writer);
            try writeExtension(out, "REUC", undo_body.written());
            hashExtensionHeader(ext_hasher, "REUC", undo_body.written().len);
        }
        if (index.untracked) |*cache| {
            var untracked_body: Io.Writer.Allocating = .init(index.gpa);
            defer untracked_body.deinit();
            try cache.write(index.gpa, &untracked_body.writer, index.kind);
            try writeExtension(out, "UNTR", untracked_body.written());
            hashExtensionHeader(ext_hasher, "UNTR", untracked_body.written().len);
        }
        // `FSMN` after the untracked cache, as git writes them: version 2,
        // the token, and the entries not vouched for.
        if (index.fsmonitor_token) |token| {
            var fsmn_body: Io.Writer.Allocating = .init(index.gpa);
            defer fsmn_body.deinit();
            try index.writeFsmonitor(&fsmn_body.writer, token);
            try writeExtension(out, "FSMN", fsmn_body.written());
            hashExtensionHeader(ext_hasher, "FSMN", fsmn_body.written().len);
        }
        // `sdir` is empty, and last of the ones that carry the index's
        // content, which is where git writes it.
        if (index.sparse) {
            try writeExtension(out, "sdir", "");
            hashExtensionHeader(ext_hasher, "sdir", 0);
        }
    }

    fn writeFsmonitor(index: *Index, w: *Io.Writer, token: []const u8) (Allocator.Error || Io.Writer.Error)!void {
        var version: [4]u8 = undefined;
        std.mem.writeInt(u32, &version, 2, .big);
        try w.writeAll(&version);
        try w.writeAll(token);
        try w.writeByte(0);
        // git's bitmap ends at its last set bit.
        var bit_count: u32 = 0;
        for (index.entries.items, 0..) |entry, at| {
            if (!entry.fsmonitor_valid) bit_count = @intCast(at + 1); // at most the count `writeBody` held to a u32
        }
        const words = try index.gpa.alloc(u64, (bit_count + 63) / 64);
        defer index.gpa.free(words);
        @memset(words, 0);
        for (index.entries.items[0..bit_count], 0..) |entry, at| {
            if (!entry.fsmonitor_valid) words[at / 64] |= @as(u64, 1) << @as(u6, @truncate(at));
        }
        const bitmap = ewah.write(index.gpa, words, bit_count) catch |err| switch (err) {
            error.InvalidBitmapInput => unreachable, // the words hold the bits
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer index.gpa.free(bitmap);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(bitmap.len), .big); // at most 2^32 bits, compressed
        try w.writeAll(&size);
        try w.writeAll(bitmap);
    }

    /// One block of the index entry offset table: where it starts in the
    /// file, and how many entries it holds.
    const OffsetBlock = struct {
        offset: u32,
        count: u32,
    };

    /// Feed one extension's header -- signature and size, as they appear in
    /// the file -- to the hash `EOIE` carries.
    fn hashExtensionHeader(hasher: *hash.Hasher, signature: []const u8, size: usize) void {
        hasher.update(signature);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(size), .big);
        hasher.update(&bytes);
    }

    fn writeExtension(w: *Io.Writer, signature: []const u8, data: []const u8) Io.Writer.Error!void {
        try w.writeAll(signature);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(data.len), .big);
        try w.writeAll(&size);
        try w.writeAll(data);
    }

    /// Errors from `toBytes`.
    pub const ToBytesError = Allocator.Error || WriteError;

    /// The bytes `write` would produce. The result is the caller's.
    pub fn toBytes(index: *Index, options: WriteOptions) ToBytesError![]u8 {
        var out: Io.Writer.Allocating = .init(index.gpa);
        errdefer out.deinit();
        index.writeTo(&out.writer, options) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        return out.toOwnedSlice();
    }

    /// The cache tree, making an empty invalid one if the index has none.
    pub fn cacheTree(index: *Index) Allocator.Error!*CacheTree {
        if (index.cache_tree == null) index.cache_tree = try CacheTree.empty(index.gpa);
        return &index.cache_tree.?;
    }
};

fn orderPath(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

test "an index written is an index read" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();

    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try index.add(.{ .path = "b/c.txt", .oid = oid, .mode = .file });
    try index.add(.{ .path = "a.txt", .oid = oid, .mode = .exec });
    try index.add(.{ .path = "z.txt", .oid = oid, .mode = .symlink, .skip_worktree = true });

    try std.testing.expectEqualStrings("a.txt", index.entries.items[0].path);
    try std.testing.expectEqualStrings("b/c.txt", index.entries.items[1].path);

    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    // One entry needs extended flags, so the version is 3.
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[4..8], .big));

    var back = try Index.parse(gpa, .sha1, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 3), back.entries.items.len);
    try std.testing.expect(back.entries.items[2].skip_worktree);
    try std.testing.expectEqual(object.Mode.exec, back.entries.items[0].mode);
    try std.testing.expect(back.find("b/c.txt") != null);
    try std.testing.expect(back.find("nope") == null);
    try std.testing.expect(back.hasDirectory("b"));
    try std.testing.expect(!back.hasDirectory("a"));
}

test "version 2 refuses entries whose extended flags would be lost" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    try index.add(.{
        .path = "outside.txt",
        .oid = Oid.zero(.sha1),
        .mode = .file,
        .skip_worktree = true,
    });

    try std.testing.expectError(
        error.ExtendedFlagsRequireVersion3,
        index.toBytes(.{ .version = .v2 }),
    );
}

test "a valid cache-tree root must cover every index entry" {
    const gpa = std.testing.allocator;
    var tree = try CacheTree.empty(gpa);
    defer tree.deinit();
    tree.root.entry_count = 0;
    tree.root.oid = Oid.zero(.sha1);

    const entries = [_]Entry{.{
        .path = "tracked.txt",
        .oid = Oid.zero(.sha1),
        .mode = .file,
    }};
    var unused_db: odb_mod.Odb = undefined;
    try std.testing.expectError(
        error.CorruptCacheTree,
        tree.rebuild(std.testing.io, &entries, &unused_db),
    );
}

test "a rebuild that meets a conflict frees the directory it took out of the tree" {
    const gpa = std.testing.allocator;
    var tree = try CacheTree.empty(gpa);
    defer tree.deinit();
    // the tree as a read left it, a directory holding a directory, with
    // the outer one invalidated by a change staged in it
    var sub: CacheTreeNode = .{ .name = try gpa.dupe(u8, "sub"), .entry_count = 1, .oid = Oid.zero(.sha1), .children = .empty };
    errdefer sub.deinit(gpa);
    var dir: CacheTreeNode = .{ .name = try gpa.dupe(u8, "dir"), .entry_count = -1, .oid = null, .children = .empty };
    errdefer dir.deinit(gpa);
    try dir.children.append(gpa, sub);
    try tree.root.children.append(gpa, dir);

    const entries = [_]Entry{.{ .path = "dir/a.txt", .oid = Oid.zero(.sha1), .mode = .file, .stage = 2 }};
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try odb_mod.Odb.openAt(gpa, std.testing.io, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(std.testing.io);
    try std.testing.expectError(error.CorruptCacheTree, tree.rebuild(std.testing.io, &entries, &db));
}

test "a cache tree cut short after a directory's name frees it once" {
    const gpa = std.testing.allocator;
    // the root names one subtree, which is missing
    try std.testing.expectError(error.CorruptCacheTree, CacheTree.parse(gpa, .sha1, "\x00-1 1\n"));
    // the subtree is read whole but names a child of its own that is missing
    try std.testing.expectError(error.CorruptCacheTree, CacheTree.parse(gpa, .sha1, "\x00-1 1\ndir\x00-1 1\n"));
}

test "an index that gives its cache tree twice keeps the later one and leaks neither" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    try index.add(.{ .path = "dir/a.txt", .oid = Oid.zero(.sha1), .mode = .file });
    const tree = try index.cacheTree();
    try tree.root.children.append(gpa, .{ .name = try gpa.dupe(u8, "dir"), .entry_count = -1, .oid = null, .children = .empty });
    const bytes = try index.toBytes(.{ .skip_hash = true });
    defer gpa.free(bytes);
    // the TREE extension, repeated just before the trailer
    const at = std.mem.find(u8, bytes, "TREE").?;
    const len = 8 + std.mem.readInt(u32, bytes[at + 4 ..][0..4], .big);
    const trailer = bytes.len - Kind.sha1.rawLen();
    const twice = try std.mem.concat(gpa, u8, &.{ bytes[0..trailer], bytes[at..][0..len], bytes[trailer..] });
    defer gpa.free(twice);
    var back = try Index.parse(gpa, .sha1, twice);
    defer back.deinit();
    try std.testing.expect(back.cache_tree != null);
}

test "the trailer index.skipHash asks for is zeros, and reads back as skipped" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try index.add(.{ .path = "a.txt", .oid = oid, .mode = .file });

    const skipped = try index.toBytes(.{ .skip_hash = true });
    defer gpa.free(skipped);
    const raw_len = Kind.sha1.rawLen();
    try std.testing.expect(std.mem.allEqual(u8, skipped[skipped.len - raw_len ..], 0));

    var back = try Index.parse(gpa, .sha1, skipped);
    defer back.deinit();
    try std.testing.expect(back.hash_was_skipped);
    try std.testing.expectEqualStrings("a.txt", back.entries.items[0].path);

    // And the default is still a real hash, which the reader checks.
    const hashed = try index.toBytes(.{});
    defer gpa.free(hashed);
    try std.testing.expect(!std.mem.allEqual(u8, hashed[hashed.len - raw_len ..], 0));
    var checked = try Index.parse(gpa, .sha1, hashed);
    defer checked.deinit();
    try std.testing.expect(!checked.hash_was_skipped);
}

test "version 4 prefix compression round trips" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    for ([_][]const u8{ "dir/aaa.txt", "dir/aab.txt", "dir/sub/x", "other" }) |path| {
        try index.add(.{ .path = path, .oid = oid, .mode = .file });
    }
    const bytes = try index.toBytes(.{ .version = .v4 });
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, bytes[4..8], .big));

    var back = try Index.parse(gpa, .sha1, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 4), back.entries.items.len);
    try std.testing.expectEqualStrings("dir/aaa.txt", back.entries.items[0].path);
    try std.testing.expectEqualStrings("dir/aab.txt", back.entries.items[1].path);
    try std.testing.expectEqualStrings("dir/sub/x", back.entries.items[2].path);
    try std.testing.expectEqualStrings("other", back.entries.items[3].path);
}

test "the offset caches are written on request, and kept by an index that had them" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    for (0..7) |i| {
        var name: [32]u8 = undefined;
        try index.addMany(&.{.{
            .path = try std.mem.print(&name, "dir/file{d}.txt", .{i}),
            .oid = .zero(.sha1),
            .mode = .file,
            .stat = .{},
        }});
    }

    // Nothing asked for, nothing written: this is what stock git writes.
    const plain = try index.toBytes(.{});
    defer gpa.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "EOIE") == null);
    try std.testing.expect(std.mem.find(u8, plain, "IEOT") == null);

    const with = try index.toBytes(.{ .end_of_index_entries = true, .entry_offset_blocks = 3 });
    defer gpa.free(with);

    const ieot_at = std.mem.find(u8, with, "IEOT").?;
    const eoie_at = std.mem.find(u8, with, "EOIE").?;
    try std.testing.expect(ieot_at < eoie_at);

    // `EOIE` says where the extensions begin, which is where `IEOT`'s own
    // header is, and carries the hash of every extension header before it.
    const eoie = with[eoie_at + 8 ..][0..24];
    try std.testing.expectEqual(@as(u32, @intCast(ieot_at)), std.mem.readInt(u32, eoie[0..4], .big));
    const ieot_size = std.mem.readInt(u32, with[ieot_at + 4 ..][0..4], .big);
    var expected: hash.Hasher = .init(.sha1);
    expected.update("IEOT");
    var size_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_bytes, ieot_size, .big);
    expected.update(&size_bytes);
    try std.testing.expectEqualSlices(u8, expected.final().raw(), eoie[4..24]);

    // Three blocks over seven entries: three, three and one, each starting
    // where the table says.
    const table = with[ieot_at + 8 ..][0..ieot_size];
    try std.testing.expectEqual(ieot_version, std.mem.readInt(u32, table[0..4], .big));
    try std.testing.expectEqual(@as(usize, 3), (table.len - 4) / 8);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, table[4..8], .big));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, table[8..12], .big));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, table[16..20], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, table[24..28], .big));

    // An index read back from those bytes remembers that they were there and
    // how the table was divided, and writes them again unasked.
    var back = try Index.parse(gpa, .sha1, with);
    defer back.deinit();
    try std.testing.expect(back.had_end_of_index_entries);
    try std.testing.expectEqual(@as(u32, 3), back.entry_offset_blocks);
    const again = try back.toBytes(.{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, with, again);

    // And a caller that does not want them says so.
    const dropped = try back.toBytes(.{ .end_of_index_entries = false, .entry_offset_blocks = 0 });
    defer gpa.free(dropped);
    try std.testing.expectEqualSlices(u8, plain, dropped);
}

test "an unknown optional extension is read and not written back, as git drops one it does not know" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const plain = try index.toBytes(.{});
    defer gpa.free(plain);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, plain[0 .. plain.len - 20]);
    try bytes.appendSlice(gpa, "ZZZZ\x00\x00\x00\x0copaque bytes");
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(bytes.items);
    try bytes.appendSlice(gpa, hasher.final().raw());

    var back = try Index.parse(gpa, .sha1, bytes.items);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 1), back.unknown.items.len);
    try std.testing.expectEqualStrings("ZZZZ", &back.unknown.items[0].signature);
    try std.testing.expectEqualStrings("opaque bytes", back.unknown.items[0].data);

    const again = try back.toBytes(.{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, plain, again);
}

test "an unknown mandatory extension is refused by name" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const plain = try index.toBytes(.{});
    defer gpa.free(plain);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, plain[0 .. plain.len - 20]);
    try bytes.appendSlice(gpa, "zzzz\x00\x00\x00\x01x");
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(bytes.items);
    try bytes.appendSlice(gpa, hasher.final().raw());
    try std.testing.expectError(error.UnsupportedExtension, Index.parse(gpa, .sha1, bytes.items));
}

test "a sparse directory entry reads and writes back, and needs sdir" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try index.add(.{ .path = "a.txt", .oid = oid, .mode = .file });
    try index.add(.{ .path = "out/", .oid = oid, .mode = .tree, .skip_worktree = true });
    index.sparse = true;
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "sdir\x00\x00\x00\x00") != null);

    var back = try Index.parse(gpa, .sha1, bytes);
    defer back.deinit();
    try std.testing.expect(back.sparse);
    try std.testing.expect(back.find("out/").?.isSparseDirectory());
    const again = try back.toBytes(.{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);

    // Without the extension the same entry is a corrupt index.
    index.sparse = false;
    const bare = try index.toBytes(.{});
    defer gpa.free(bare);
    try std.testing.expectError(error.InvalidSparseDirectory, Index.parse(gpa, .sha1, bare));
}

test "an index cut short anywhere is refused or read whole, never read past" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try index.add(.{ .path = "dir/aaa.txt", .oid = oid, .mode = .file });
    try index.add(.{ .path = "dir/aab.txt", .oid = oid, .mode = .file, .intent_to_add = true });
    try index.add(.{ .path = "other", .oid = oid, .mode = .file });
    for ([_]WriteOptions{ .{ .version = .v3 }, .{ .version = .v4 } }) |options| {
        const bytes = try index.toBytes(options);
        defer gpa.free(bytes);
        const body = bytes[0 .. bytes.len - 20];
        // A trailer of zeros is one `index.skipHash` wrote, so each cut is
        // read past the checksum, by the entries and extensions themselves.
        for (12..body.len) |len| {
            const cut = try gpa.alloc(u8, len + 20);
            defer gpa.free(cut);
            @memcpy(cut[0..len], body[0..len]);
            @memset(cut[len..], 0);
            var back = Index.parse(gpa, .sha1, cut) catch continue;
            defer back.deinit();
            try std.testing.expectEqual(index.entries.items.len, back.entries.items.len);
        }
    }
}

test "a bad checksum is a named error" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    bytes[bytes.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, Index.parse(gpa, .sha1, bytes));
}

test "the racy rule uses the resolution the filesystem was measured to have" {
    var index: Index = .initEmpty(std.testing.allocator, .sha1);
    defer index.deinit();
    index.racy_cutoff_sec = 1000;
    index.racy_cutoff_nsec = 500_000_000;
    const entry: Entry = .{
        .path = "",
        .oid = undefined,
        .mode = .file,
        .stat = .{ .mtime_sec = 1000, .mtime_nsec = 100_000_000 },
    };

    // Nanoseconds kept: the entry is a tenth of a second older than the index
    // and the filesystem can say so, so it is not racy.
    index.timestamp_resolution = .nanosecond;
    try std.testing.expect(!index.isRacy(entry));

    // Seconds kept: the filesystem cannot put the two in order at all, so
    // anything written in the index's own second has to be read.
    index.timestamp_resolution = .second;
    try std.testing.expect(index.isRacy(entry));

    // Tenths of a second kept: the two still fall in different units, so the
    // entry is still older.
    index.timestamp_resolution = .{ .ns = 100_000_000, .measured = true };
    try std.testing.expect(!index.isRacy(entry));

    // An entry inside the same unit as the cutoff is racy whatever the unit,
    // because the filesystem cannot say which came first.
    const close: Entry = .{
        .path = "",
        .oid = undefined,
        .mode = .file,
        .stat = .{ .mtime_sec = 1000, .mtime_nsec = 540_000_000 },
    };
    index.timestamp_resolution = .{ .ns = 100_000_000, .measured = true };
    try std.testing.expect(index.isRacy(close));
}

test "an index read from a disk measures the filesystem it was read from" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var written: Index = .initEmpty(gpa, .sha1);
    defer written.deinit();
    try written.write(io, tmp.dir, "index", .{});

    var index = try Index.read(gpa, io, tmp.dir, "index", .{ .git_dir = tmp.dir, .kind = .sha1 });
    defer index.deinit();
    try std.testing.expect(index.timestamp_resolution.measured);
    try std.testing.expect(index.timestamp_resolution.ns >= 1);
    try std.testing.expect(index.timestamp_resolution.ns <= std.time.ns_per_s);
}

test "index read options preserve a measured resolution for both object formats" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ Kind.sha1, Kind.sha256 }) |kind| {
        var written: Index = .initEmpty(gpa, kind);
        defer written.deinit();
        try written.write(io, tmp.dir, "index", .{});
        const measured: fs.Resolution = .{ .ns = 100_000_000, .measured = true };
        var loaded = try Index.read(gpa, io, tmp.dir, "index", .{ .kind = kind, .timestamp_resolution = measured });
        defer loaded.deinit();
        try std.testing.expectEqual(kind, loaded.kind);
        try std.testing.expectEqual(measured, loaded.timestamp_resolution);
        try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
    }
}

test "the racy rule marks an entry whose time is not older than the index" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    index.racy_cutoff_sec = 1000;
    index.racy_cutoff_nsec = 500;
    try std.testing.expect(index.isRacy(.{ .path = "", .oid = undefined, .mode = .file, .stat = .{ .mtime_sec = 1000, .mtime_nsec = 500 } }));
    try std.testing.expect(index.isRacy(.{ .path = "", .oid = undefined, .mode = .file, .stat = .{ .mtime_sec = 1001, .mtime_nsec = 0 } }));
    try std.testing.expect(!index.isRacy(.{ .path = "", .oid = undefined, .mode = .file, .stat = .{ .mtime_sec = 999, .mtime_nsec = 999 } }));
}

test "an index git writes with names only Windows refuses is read, as git reads it" {
    // git itself refuses these names on Windows, so there is no such index
    // to read there.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const blob = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    for ([_][]const u8{ "drivers/i2c/aux.c", "a\tb", "t.", "con", "x:y" }) |path| {
        const info = try gpa.print("100644,{s},{s}", .{ blob, path });
        defer gpa.free(info);
        try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
    }
    const listed = try repo.run(io, &.{ "ls-files", "-z" });
    defer gpa.free(listed);
    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try Index.read(gpa, io, git_dir, "index", .{ .git_dir = git_dir, .kind = .sha1 });
    defer index.deinit();
    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    for (index.entries.items) |e| {
        try ours.appendSlice(gpa, e.path);
        try ours.append(gpa, 0);
    }
    try std.testing.expectEqualStrings(listed, ours.items);
}

/// An index's bytes with a `link` extension naming `base` put before the
/// trailer, and the trailer taken again.
fn withLink(gpa: Allocator, bytes: []const u8, base: Oid) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, bytes[0 .. bytes.len - 20]);
    try out.appendSlice(gpa, "link");
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, 20, .big);
    try out.appendSlice(gpa, &size);
    try out.appendSlice(gpa, base.raw());
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(out.items);
    try out.appendSlice(gpa, hasher.final().raw());
    return out.toOwnedSlice(gpa);
}

test "a split index is checked once merged: no empty name, no name twice, and the shared file the one its link names" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");

    var shared: Index = .initEmpty(gpa, .sha1);
    defer shared.deinit();
    try shared.add(.{ .path = "a", .oid = oid, .mode = .file });
    const shared_bytes = try shared.toBytes(.{});
    defer gpa.free(shared_bytes);
    const base = try Oid.fromRaw(.sha1, shared_bytes[shared_bytes.len - 20 ..]);
    var hex: [hash.max_hex_len]u8 = undefined;
    const shared_name = try gpa.print("sharedindex.{s}", .{base.hex(&hex)});
    defer gpa.free(shared_name);
    try tmp.dir.writeFile(io, .{ .sub_path = shared_name, .data = shared_bytes });

    // Overlays whose additions are an empty name, and the shared name again.
    const Case = struct { paths: []const []const u8, err: anyerror };
    for ([_]Case{
        .{ .paths = &.{ "", "b" }, .err = error.CorruptLinkExtension },
        .{ .paths = &.{"a"}, .err = error.UnsortedIndex },
    }) |case| {
        var overlay: Index = .initEmpty(gpa, .sha1);
        defer overlay.deinit();
        for (case.paths) |path| try overlay.entries.append(gpa, .{ .path = try gpa.dupe(u8, path), .oid = oid, .mode = .file });
        const plain = try overlay.toBytes(.{});
        defer gpa.free(plain);
        const linked = try withLink(gpa, plain, base);
        defer gpa.free(linked);
        try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = linked });
        try std.testing.expectError(case.err, Index.read(gpa, io, tmp.dir, "index", .{ .git_dir = tmp.dir, .kind = .sha1 }));
    }

    // A shared file under a name its checksum is not.
    const other = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const other_name = try gpa.print("sharedindex.{s}", .{other.hex(&hex)});
    defer gpa.free(other_name);
    try tmp.dir.writeFile(io, .{ .sub_path = other_name, .data = shared_bytes });
    var overlay: Index = .initEmpty(gpa, .sha1);
    defer overlay.deinit();
    const plain = try overlay.toBytes(.{});
    defer gpa.free(plain);
    const linked = try withLink(gpa, plain, other);
    defer gpa.free(linked);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = linked });
    try std.testing.expectError(error.ChecksumMismatch, Index.read(gpa, io, tmp.dir, "index", .{ .git_dir = tmp.dir, .kind = .sha1 }));
}

test "a split index's link is held to its shared index as git's merge_base_index holds it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const other_oid = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));

    var shared: Index = .initEmpty(gpa, .sha1);
    defer shared.deinit();
    try shared.add(.{ .path = "a", .oid = oid, .mode = .file });
    try shared.add(.{ .path = "b", .oid = oid, .mode = .file });
    const shared_bytes = try shared.toBytes(.{});
    defer gpa.free(shared_bytes);
    const base = try Oid.fromRaw(.sha1, shared_bytes[shared_bytes.len - 20 ..]);
    var hex: [hash.max_hex_len]u8 = undefined;
    const shared_name = try gpa.print("sharedindex.{s}", .{base.hex(&hex)});
    defer gpa.free(shared_name);
    try tmp.dir.writeFile(io, .{ .sub_path = shared_name, .data = shared_bytes });

    const Case = struct { deletes: u64, replaces: u64, overlay: []const []const u8, garbage: bool = false, want: ?[]const u8 };
    for ([_]Case{
        // `b` replaced by the overlay's nameless entry.
        .{ .deletes = 0, .replaces = 0b10, .overlay = &.{""}, .want = "a b2" },
        // Replaced and deleted: the replacement is taken, then the entry goes.
        .{ .deletes = 0b1, .replaces = 0b1, .overlay = &.{""}, .want = "b" },
        // Past the shared index's end, either bitmap.
        .{ .deletes = 0, .replaces = 0b100, .overlay = &.{""}, .want = null },
        .{ .deletes = 0b100, .replaces = 0, .overlay = &.{}, .want = null },
        // A replacement with a name, more replacements than entries.
        .{ .deletes = 0, .replaces = 0b1, .overlay = &.{"x"}, .want = null },
        .{ .deletes = 0, .replaces = 0b11, .overlay = &.{""}, .want = null },
        // Bytes after the bitmaps.
        .{ .deletes = 0, .replaces = 0, .overlay = &.{}, .garbage = true, .want = null },
    }) |case| {
        var overlay: Index = .initEmpty(gpa, .sha1);
        defer overlay.deinit();
        for (case.overlay) |path| try overlay.entries.append(gpa, .{ .path = try gpa.dupe(u8, path), .oid = other_oid, .mode = .file });
        const plain = try overlay.toBytes(.{});
        defer gpa.free(plain);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        try data.appendSlice(gpa, base.raw());
        for ([_]u64{ case.deletes, case.replaces }) |word| {
            const encoded = try ewah.write(gpa, &.{word}, 64);
            defer gpa.free(encoded);
            try data.appendSlice(gpa, encoded);
        }
        if (case.garbage) try data.append(gpa, 0);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, plain[0 .. plain.len - 20]);
        try out.appendSlice(gpa, "link");
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(data.items.len), .big);
        try out.appendSlice(gpa, &size);
        try out.appendSlice(gpa, data.items);
        var hasher: hash.Hasher = .init(.sha1);
        hasher.update(out.items);
        try out.appendSlice(gpa, hasher.final().raw());
        try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = out.items });

        const want = case.want orelse {
            try std.testing.expectError(error.CorruptLinkExtension, Index.read(gpa, io, tmp.dir, "index", .{ .git_dir = tmp.dir, .kind = .sha1 }));
            continue;
        };
        var index = try Index.read(gpa, io, tmp.dir, "index", .{ .git_dir = tmp.dir, .kind = .sha1 });
        defer index.deinit();
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        for (index.entries.items, 0..) |e, i| {
            if (i != 0) try got.append(gpa, ' ');
            try got.appendSlice(gpa, e.path);
            if (e.oid.eql(other_oid)) try got.append(gpa, '2');
        }
        try std.testing.expectEqualStrings(want, got.items);
    }
}

test "entries out of order are refused on the way out, not asserted" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try index.entries.append(gpa, .{ .path = try gpa.dupe(u8, "b"), .oid = oid, .mode = .file });
    try index.entries.append(gpa, .{ .path = try gpa.dupe(u8, "a"), .oid = oid, .mode = .file });
    try std.testing.expectError(error.UnsortedIndex, index.toBytes(.{}));
}

test "a cache tree nested past any tree, claiming more subtrees than it holds, or not the whole tree, is dropped without a crash, as git drops one it cannot read" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const plain = try index.toBytes(.{});
    defer gpa.free(plain);
    for ([_]usize{ 300_000, 0, 1 }) |depth| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        if (depth == 0) {
            try data.appendSlice(gpa, "\x00-1 4000000000\n");
        } else if (depth == 1) {
            // A root with a name: not the whole tree.
            try data.appendSlice(gpa, "x\x00-1 0\n");
        } else {
            try data.appendSlice(gpa, "\x00-1 1\n");
            for (0..depth) |_| try data.appendSlice(gpa, "x\x00-1 1\n");
        }
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, plain[0 .. plain.len - 20]);
        try bytes.appendSlice(gpa, "TREE");
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(data.items.len), .big);
        try bytes.appendSlice(gpa, &size);
        try bytes.appendSlice(gpa, data.items);
        var hasher: hash.Hasher = .init(.sha1);
        hasher.update(bytes.items);
        try bytes.appendSlice(gpa, hasher.final().raw());
        var read = try Index.parse(gpa, .sha1, bytes.items);
        defer read.deinit();
        try std.testing.expect(read.cache_tree == null);
        try std.testing.expect(read.dropped.cache_tree);
    }
}

test "a cache tree's counts are read as git's parse_int reads them" {
    var offset: usize = 0;
    try std.testing.expectEqual(@as(i32, -1), try CacheTree.treeInt("-1 ", &offset, ' '));
    offset = 0;
    try std.testing.expectEqual(@as(i32, 5), try CacheTree.treeInt("--5\n", &offset, '\n'));
    offset = 0;
    // A minus alone is a number, zero.
    try std.testing.expectEqual(@as(i32, 0), try CacheTree.treeInt("- ", &offset, ' '));
    for ([_][]const u8{ "+1 ", " 1 ", "1x ", "", "1" }) |text| {
        offset = 0;
        try std.testing.expectError(error.CorruptCacheTree, CacheTree.treeInt(text, &offset, ' '));
    }
}

test "an entry's extended flags are read in any version, and a bit git does not know is refused" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    index.version = 3;
    const oid = try Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    try index.add(.{ .path = "a", .oid = oid, .mode = .file, .skip_worktree = true });
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    // The same file said to be version 2.
    std.mem.writeInt(u32, bytes[4..8], 2, .big);
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(bytes[0 .. bytes.len - 20]);
    @memcpy(bytes[bytes.len - 20 ..], hasher.final().raw());
    var two = try Index.parse(gpa, .sha1, bytes);
    defer two.deinit();
    try std.testing.expect(two.entries.items[0].skip_worktree);
    // A bit beside skip-worktree and intent-to-add.
    const flags_at = 12 + 40 + 20 + 2;
    bytes[flags_at] |= 0x10;
    hasher = .init(.sha1);
    hasher.update(bytes[0 .. bytes.len - 20]);
    @memcpy(bytes[bytes.len - 20 ..], hasher.final().raw());
    try std.testing.expectError(error.UnknownEntryFlags, Index.parse(gpa, .sha1, bytes));
}

test "an entry's mode is read as git reads it, any bits, and written back as it was spelled" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = try Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    try index.add(.{ .path = "a", .oid = oid, .mode = .file });
    try index.add(.{ .path = "b", .oid = oid, .mode = .symlink });
    try index.add(.{ .path = "c", .oid = oid, .mode = .file });
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    // Spellings no git writes, which another tool's index may hold: a group-
    // writable file, a link with permission bits, and a device.
    const entry_len = 62 + 2; // the fixed part and a one-byte name, padded to eight
    for ([_]u32{ 0o100664, 0o120777, 0o060644 }, 0..) |raw, i| std.mem.writeInt(u32, bytes[12 + i * entry_len + 24 ..][0..4], raw, .big);
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(bytes[0 .. bytes.len - 20]);
    @memcpy(bytes[bytes.len - 20 ..], hasher.final().raw());
    var read = try Index.parse(gpa, .sha1, bytes);
    defer read.deinit();
    try std.testing.expectEqual(object.Mode.file, read.entries.items[0].mode);
    try std.testing.expectEqual(object.Mode.symlink, read.entries.items[1].mode);
    try std.testing.expectEqual(object.Mode.gitlink, read.entries.items[2].mode);
    // unchanged, each is written back as it was spelled
    const again = try read.toBytes(.{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    // a mode changed here is written as itself
    read.entries.items[0].mode = .exec;
    const changed = try read.toBytes(.{});
    defer gpa.free(changed);
    try std.testing.expectEqual(@as(u32, 0o100755), std.mem.readInt(u32, changed[12 + 24 ..][0..4], .big));
}

test "fuzz: any bytes are an index or a named error" {
    try shakedown.check(std.testing.allocator, {}, fuzzIndex, .{});
}

fn fuzzIndex(_: void, case: *shakedown.Case) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [4096]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    var index = Index.parse(gpa, .sha1, input) catch return;
    defer index.deinit();
    _ = index.find("a");
    const bytes = index.toBytes(.{}) catch return;
    gpa.free(bytes);
}

test "entries removed by the paths they hold themselves all go, and the rest stay in order" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const oid = Oid.zero(.sha1);
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |p| try index.add(.{ .path = p, .oid = oid, .mode = .file });
    for ([_]u2{ 1, 2, 3 }) |stage| try index.add(.{ .path = "f", .oid = oid, .mode = .file, .stage = stage });
    // The list borrows the entries' own bytes, as a caller's often does.
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(gpa);
    for (index.entries.items) |e| {
        if (!std.mem.eql(u8, e.path, "b") and !std.mem.eql(u8, e.path, "d")) try gone.append(gpa, e.path);
    }
    index.removeMany(gone.items);
    try std.testing.expectEqual(@as(usize, 2), index.entries.items.len);
    try std.testing.expectEqualStrings("b", index.entries.items[0].path);
    try std.testing.expectEqualStrings("d", index.entries.items[1].path);
}

test "a conflict's stages leave with their resolution remembered, in path order" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const one = try Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const two = try Oid.parse(.sha1, "2222222222222222222222222222222222222222");
    for ([_][]const u8{ "z", "m" }) |p| {
        try index.add(.{ .path = p, .oid = one, .mode = .file, .stage = 1 });
        try index.add(.{ .path = p, .oid = two, .mode = .exec, .stage = 3 });
    }
    try std.testing.expectEqual(@as(usize, 2), try index.resolveStages("z"));
    try std.testing.expectEqual(@as(usize, 2), try index.resolveStages("m"));
    try std.testing.expectEqual(@as(usize, 0), index.entries.items.len);
    const undo = index.resolve_undo.?;
    try std.testing.expectEqual(@as(usize, 2), undo.entries.items.len);
    try std.testing.expectEqualStrings("m", undo.entries.items[0].path);
    try std.testing.expectEqualStrings("z", undo.entries.items[1].path);
    try std.testing.expectEqual([3]u32{ 0o100644, 0, 0o100755 }, undo.entries.items[1].modes);
    try std.testing.expect(undo.entries.items[1].oids[1] == null);
    // Written and read back as git writes the extension.
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    var back = try Index.parse(gpa, .sha1, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 2), back.resolve_undo.?.entries.items.len);
    index.dropResolveUndo();
    try std.testing.expect(index.resolve_undo == null);
}

test "an entry added many at once replaces the one already there, whatever the count" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const old = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const new = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    var names: [300][16]u8 = undefined;
    var batch: [300]Entry = undefined;
    for (&batch, &names, 0..) |*entry, *name, i| {
        entry.* = .{ .path = try std.mem.print(name, "f{d:0>4}", .{i}), .oid = old, .mode = .file };
    }
    try index.addMany(&batch);
    for (&batch) |*entry| entry.oid = new;
    // In reverse, so that a sort has to move every one of them.
    std.mem.reverse(Entry, &batch);
    try index.addMany(&batch);
    try std.testing.expectEqual(@as(usize, 300), index.entries.items.len);
    for (index.entries.items) |entry| try std.testing.expect(entry.oid.eql(new));
}

/// All errors reported by this namespace.
pub const Error = ReadError || WriteError || CacheTree.RebuildError || CacheTree.RebuildIntoError || Index.WriteToError || Index.ToBytesError || Allocator.Error || Self.ReadError || Self.WriteError || Index.AddError;
