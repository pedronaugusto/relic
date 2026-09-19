//! The index: `DIRC`, versions 2, 3 and 4.
//!
//! An extension whose signature begins with an upper-case letter is optional
//! and is kept byte for byte and written back; a lower-case one is mandatory
//! and is either understood or a named refusal, because quietly dissolving one
//! is data loss. `TREE`, `REUC` and `link` are understood.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const fs = @import("fs.zig");
const varint = @import("varint.zig");
const ewah = @import("ewah.zig");
const odb_mod = @import("odb.zig");

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
    /// An entry's mode was not one git writes.
    InvalidMode,
    /// A path that is empty, absolute, or holds a component a working tree
    /// must never be asked to create.
    InvalidEntryPath,
    /// Entries out of order, or a duplicate path and stage.
    UnsortedIndex,
    /// A split index whose shared file is not beside it.
    SharedIndexMissing,
    /// A `TREE` extension that does not describe the entries it sits on.
    CorruptCacheTree,
    /// A `REUC` extension that ran off its own end.
    CorruptResolveUndo,
} || Allocator.Error || Io.Dir.ReadFileAllocError || ewah.Error || varint.Error;

/// Errors from writing an index.
pub const WriteError = error{
    /// A path longer than the format can carry.
    PathTooLong,
    /// Version 4 was asked for but the entries are not in an order its
    /// prefix compression can express.
    UnsupportedIndexVersion,
} || fs.LockError || fs.CommitError || Allocator.Error;

/// One tracked path.
pub const Entry = struct {
    /// `/`-separated, relative to the working tree's root. Owned by the
    /// index.
    path: []const u8,
    oid: Oid,
    mode: object.Mode,
    /// 0 for a merged entry; 1, 2 and 3 are the merge stages, which this
    /// release reads and writes but never creates.
    stage: u2 = 0,
    /// git's `assume-valid` bit: the caller has promised the file has not
    /// changed and the stat is not to be trusted against it.
    assume_valid: bool = false,
    /// The file is not meant to be in the working tree. Sparse checkout sets
    /// it.
    skip_worktree: bool = false,
    /// `git add -N`: the path is staged as existing with no content yet.
    intent_to_add: bool = false,
    stat: fs.Stat = .none,

    /// Whether the entry needs the version 3 extended flag word.
    pub fn needsExtendedFlags(e: Entry) bool {
        return e.skip_worktree or e.intent_to_add;
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

/// The `TREE` extension: a tree object name per directory, so `write-tree`
/// rebuilds only the directories that changed.
///
/// An invalidated node carries an entry count of -1 and no object name, which
/// is what an edit under it leaves behind.
pub const CacheTree = struct {
    gpa: Allocator,
    root: Node,

    /// One directory.
    pub const Node = struct {
        /// The directory's own name, without a slash. Empty at the root.
        name: []const u8,
        /// How many index entries this subtree covers, or -1 when the node
        /// is invalid and its tree must be rebuilt.
        entry_count: i64,
        /// The tree object, when the node is valid.
        oid: ?Oid,
        /// Sorted by name, which is the order the extension stores them in.
        children: std.ArrayList(Node),

        /// Whether this node's tree object may be used as it is.
        pub fn isValid(n: *const Node) bool {
            return n.entry_count >= 0 and n.oid != null;
        }

        fn deinit(n: *Node, gpa: Allocator) void {
            for (n.children.items) |*sub| sub.deinit(gpa);
            n.children.deinit(gpa);
            gpa.free(n.name);
        }

        fn child(n: *Node, name: []const u8) ?*Node {
            for (n.children.items) |*c| {
                if (std.mem.eql(u8, c.name, name)) return c;
            }
            return null;
        }
    };

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
    pub fn get(t: *CacheTree, dir: []const u8) ?*Node {
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
        while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
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

    fn parse(gpa: Allocator, kind: Kind, data: []const u8) ReadError!CacheTree {
        var offset: usize = 0;
        var root = try parseNode(gpa, kind, data, &offset);
        errdefer root.deinit(gpa);
        return .{ .gpa = gpa, .root = root };
    }

    fn parseNode(gpa: Allocator, kind: Kind, data: []const u8, offset: *usize) ReadError!Node {
        const nul = std.mem.indexOfScalarPos(u8, data, offset.*, 0) orelse return error.CorruptCacheTree;
        const name = try gpa.dupe(u8, data[offset.*..nul]);
        errdefer gpa.free(name);
        offset.* = nul + 1;

        const space = std.mem.indexOfScalarPos(u8, data, offset.*, ' ') orelse return error.CorruptCacheTree;
        const entry_count = std.fmt.parseInt(i64, data[offset.*..space], 10) catch return error.CorruptCacheTree;
        offset.* = space + 1;

        const newline = std.mem.indexOfScalarPos(u8, data, offset.*, '\n') orelse return error.CorruptCacheTree;
        const subtree_count = std.fmt.parseInt(u32, data[offset.*..newline], 10) catch return error.CorruptCacheTree;
        offset.* = newline + 1;

        var oid: ?Oid = null;
        if (entry_count >= 0) {
            const raw_len = kind.rawLen();
            if (offset.* + raw_len > data.len) return error.CorruptCacheTree;
            oid = Oid.fromRaw(kind, data[offset.*..][0..raw_len]) catch unreachable;
            offset.* += raw_len;
        }

        var node: Node = .{
            .name = name,
            .entry_count = entry_count,
            .oid = oid,
            .children = .empty,
        };
        errdefer node.deinit(gpa);
        try node.children.ensureTotalCapacity(gpa, subtree_count);
        var i: u32 = 0;
        while (i < subtree_count) : (i += 1) {
            const child = try parseNode(gpa, kind, data, offset);
            node.children.appendAssumeCapacity(child);
        }
        return node;
    }

    fn write(t: *const CacheTree, w: *Io.Writer) Io.Writer.Error!void {
        try writeNode(&t.root, w);
    }

    fn writeNode(n: *const Node, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(n.name);
        try w.writeByte(0);
        try w.print("{d} {d}\n", .{ n.entry_count, n.children.items.len });
        if (n.entry_count >= 0) {
            if (n.oid) |oid| try w.writeAll(oid.raw());
        }
        for (n.children.items) |*child| try writeNode(child, w);
    }

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
    ) (ReadError || odb_mod.Error || object.Tree.Builder.AddError)!Oid {
        var consumed: usize = 0;
        const oid = try rebuildNode(t, io, &t.root, "", entries, &consumed, db);
        return oid;
    }

    fn rebuildNode(
        t: *CacheTree,
        io: Io,
        node: *Node,
        prefix: []const u8,
        entries: []const Entry,
        consumed: *usize,
        db: *odb_mod.Odb,
    ) (ReadError || odb_mod.Error || object.Tree.Builder.AddError)!Oid {
        // A valid node covers a known number of entries; skip over them.
        if (node.isValid()) {
            consumed.* += @intCast(node.entry_count);
            return node.oid.?;
        }

        var builder: object.Tree.Builder = .init(t.gpa, db.kind);
        defer builder.deinit();
        const start = consumed.*;

        // Children that are still in the index keep their nodes; ones that
        // are not are dropped as the walk goes past them.
        var kept: std.ArrayList(Node) = .empty;
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
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const dir_name = rest[0..slash];
                var child_node: Node = if (node.child(dir_name)) |existing| taken: {
                    const copy = existing.*;
                    existing.* = .{ .name = try t.gpa.dupe(u8, ""), .entry_count = -1, .oid = null, .children = .empty };
                    break :taken copy;
                } else .{
                    .name = try t.gpa.dupe(u8, dir_name),
                    .entry_count = -1,
                    .oid = null,
                    .children = .empty,
                };
                const child_prefix = entry.path[0 .. prefix.len + slash + 1];
                const child_start = consumed.*;
                const child_oid = try t.rebuildNode(io, &child_node, child_prefix, entries, consumed, db);
                child_node.entry_count = @intCast(consumed.* - child_start);
                child_node.oid = child_oid;
                // An empty directory produces no tree entry and no node.
                if (child_node.entry_count == 0) {
                    child_node.deinit(t.gpa);
                } else {
                    try builder.add(.tree, dir_name, child_oid);
                    try kept.append(t.gpa, child_node);
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
        node.children = kept;

        const bytes = try builder.build();
        defer t.gpa.free(bytes);
        const oid = try db.write(io, .tree, bytes);
        node.entry_count = @intCast(consumed.* - start);
        node.oid = oid;
        return oid;
    }
};

/// The `REUC` extension: what a conflict replaced, so `checkout --merge` can
/// put it back. Read, written back, never created here.
pub const ResolveUndo = struct {
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
            const nul = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse return error.CorruptResolveUndo;
            const path = try gpa.dupe(u8, data[offset..nul]);
            errdefer gpa.free(path);
            offset = nul + 1;
            var modes: [3]u32 = @splat(0);
            for (&modes) |*mode| {
                const end = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse return error.CorruptResolveUndo;
                mode.* = std.fmt.parseInt(u32, data[offset..end], 8) catch return error.CorruptResolveUndo;
                offset = end + 1;
            }
            var oids: [3]?Oid = @splat(null);
            const raw_len = kind.rawLen();
            for (modes, 0..) |mode, i| {
                if (mode == 0) continue;
                if (offset + raw_len > data.len) return error.CorruptResolveUndo;
                oids[i] = Oid.fromRaw(kind, data[offset..][0..raw_len]) catch unreachable;
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

/// How an index is written.
pub const WriteOptions = struct {
    /// Which version to write. `auto` is version 2, or version 3 when an
    /// entry needs an extended flag — which is git's own rule.
    version: Version = .auto,
    /// Whether to write the all-zero trailer `index.skipHash` asks for.
    /// Reading one is always accepted; writing one is a choice.
    skip_hash: bool = false,
    /// Whether to keep the `TREE` extension. A caller that has invalidated
    /// it and does not want to rebuild may drop it.
    write_cache_tree: bool = true,

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
    gpa: Allocator,
    kind: Kind,
    /// The version the file on the disk carried, or 2 for one made here.
    version: u32 = 2,
    /// Sorted by path and then by stage.
    entries: std.ArrayList(Entry) = .empty,
    cache_tree: ?CacheTree = null,
    resolve_undo: ?ResolveUndo = null,
    /// Optional extensions this package does not interpret, kept byte for
    /// byte and written back in the order they were read.
    unknown: std.ArrayList(RawExtension) = .empty,
    /// The mandatory extension that was refused, when `read` returned
    /// `error.UnsupportedExtension`. Four bytes, valid until `deinit`.
    unsupported_extension: [4]u8 = @splat(0),
    /// The index file's own modification time in seconds, which is the racy
    /// cutoff. Zero for an index that has never been on a disk.
    racy_cutoff_sec: u32 = 0,
    racy_cutoff_nsec: u32 = 0,
    /// The shared index a split index was built from, when there was one.
    split_base: ?Oid = null,
    /// Whether the file read was a split index. What is written back is
    /// always a complete index: no entry is lost, and git re-splits on its
    /// next write if `core.splitIndex` is still set.
    was_split: bool = false,
    /// Whether the file read carried an all-zero trailer, which is what
    /// `index.skipHash` writes.
    hash_was_skipped: bool = false,
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
        for (index.unknown.items) |e| index.gpa.free(e.data);
        index.unknown.deinit(index.gpa);
        index.* = undefined;
    }

    /// Read the index at `sub_path` in `dir`.
    ///
    /// A missing file is an empty index, which is what git does: a repository
    /// with no `.git/index` has nothing staged. `git_dir` is where a split
    /// index's shared file is looked for, and may be the same directory.
    pub fn read(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        git_dir: Io.Dir,
        kind: Kind,
    ) ReadError!Index {
        const bytes = (try fs.readFileAlloc(gpa, io, dir, sub_path, 1 << 31)) orelse
            return initEmpty(gpa, kind);
        defer gpa.free(bytes);

        var index = try parse(gpa, kind, bytes);
        errdefer index.deinit();

        if (dir.statFile(io, sub_path, .{})) |stat| {
            const s = fs.Stat.fromIo(stat);
            index.racy_cutoff_sec = s.mtime_sec;
            index.racy_cutoff_nsec = s.mtime_nsec;
        } else |_| {}

        if (index.split_base) |base| {
            try index.mergeShared(gpa, io, git_dir, base);
        }
        return index;
    }

    /// Read an index from bytes already in memory.
    ///
    /// A split index read this way keeps its `link` extension unresolved:
    /// `split_base` names the shared file and the entries are only the
    /// overlay. `read` is the call that merges them.
    pub fn parse(gpa: Allocator, kind: Kind, bytes: []const u8) ReadError!Index {
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
            const stored = Oid.fromRaw(kind, trailer) catch unreachable;
            if (!computed.eql(stored)) return error.ChecksumMismatch;
        }

        var offset: usize = 12;
        try index.entries.ensureTotalCapacity(gpa, @min(entry_count, 1 << 20));
        var previous_path: []const u8 = "";
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const read_entry = try parseEntry(gpa, kind, version, body, offset, previous_path);
            index.entries.append(gpa, read_entry.entry) catch |err| {
                gpa.free(read_entry.entry.path);
                return err;
            };
            offset = read_entry.next;
            previous_path = index.entries.items[index.entries.items.len - 1].path;
        }

        while (offset + 8 <= body.len) {
            const signature = body[offset..][0..4].*;
            const size = std.mem.readInt(u32, body[offset + 4 ..][0..4], .big);
            offset += 8;
            if (offset + size > body.len) return error.TruncatedIndex;
            const data = body[offset..][0..size];
            offset += size;

            if (std.mem.eql(u8, &signature, "TREE")) {
                index.cache_tree = try CacheTree.parse(gpa, kind, data);
            } else if (std.mem.eql(u8, &signature, "REUC")) {
                index.resolve_undo = try ResolveUndo.parse(gpa, kind, data);
            } else if (std.mem.eql(u8, &signature, "link")) {
                try index.parseLink(gpa, data);
            } else if (std.mem.eql(u8, &signature, "EOIE") or std.mem.eql(u8, &signature, "IEOT")) {
                // Both are caches of byte offsets into this very file.
                // Copying one into a file whose entries have moved would
                // point it at the wrong place, so they are recomputed on
                // write rather than preserved.
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

        // A split index's overlay carries its replacements with empty names,
        // in the shared index's order rather than in path order, so both
        // checks wait until the `link` extension has been seen.
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

    fn parseLink(index: *Index, gpa: Allocator, data: []const u8) ReadError!void {
        const raw_len = index.kind.rawLen();
        if (data.len < raw_len) return error.TruncatedIndex;
        const base = Oid.fromRaw(index.kind, data[0..raw_len]) catch unreachable;
        index.was_split = true;
        if (!base.isZero()) index.split_base = base;

        var rest = data[raw_len..];
        if (rest.len == 0) {
            index.split_delete = null;
            index.split_replace = null;
            return;
        }
        var deletes = try ewah.read(gpa, rest);
        errdefer deletes.bits.deinit();
        rest = rest[deletes.len..];
        const replaces = try ewah.read(gpa, rest);
        index.split_delete = deletes.bits;
        index.split_replace = replaces.bits;
    }

    fn mergeShared(index: *Index, gpa: Allocator, io: Io, git_dir: Io.Dir, base: Oid) ReadError!void {
        var hex: [hash.max_hex_len]u8 = undefined;
        var name_buf: [hash.max_hex_len + 16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "sharedindex.{s}", .{base.hex(&hex)}) catch unreachable;
        const shared_bytes = (try fs.readFileAlloc(gpa, io, git_dir, name, 1 << 31)) orelse
            return error.SharedIndexMissing;
        defer gpa.free(shared_bytes);

        var shared = try parse(gpa, index.kind, shared_bytes);
        defer shared.deinit();

        var merged: std.ArrayList(Entry) = .empty;
        errdefer {
            for (merged.items) |e| gpa.free(e.path);
            merged.deinit(gpa);
        }

        // The overlay's first entries, the ones with an empty path, replace
        // positions in the shared index in order; the rest are additions.
        var replacement: usize = 0;
        for (shared.entries.items, 0..) |base_entry, base_at| {
            const pos: u32 = @intCast(base_at);
            if (index.split_delete) |bits| {
                if (bits.isSet(pos)) continue;
            }
            if (index.split_replace) |bits| {
                if (bits.isSet(pos)) {
                    if (replacement >= index.entries.items.len) return error.TruncatedIndex;
                    var overlay = index.entries.items[replacement];
                    replacement += 1;
                    gpa.free(overlay.path);
                    overlay.path = try gpa.dupe(u8, base_entry.path);
                    try merged.append(gpa, overlay);
                    continue;
                }
            }
            try merged.append(gpa, .{
                .path = try gpa.dupe(u8, base_entry.path),
                .oid = base_entry.oid,
                .mode = base_entry.mode,
                .stage = base_entry.stage,
                .assume_valid = base_entry.assume_valid,
                .skip_worktree = base_entry.skip_worktree,
                .intent_to_add = base_entry.intent_to_add,
                .stat = base_entry.stat,
            });
        }
        for (index.entries.items[replacement..]) |extra| try merged.append(gpa, extra);

        // The entries consumed as replacements had their paths replaced
        // above; the ones appended are owned by `merged` now.
        index.entries.deinit(gpa);
        index.entries = merged;
        std.mem.sort(Entry, index.entries.items, {}, lessThan);

        if (index.split_delete) |*b| b.deinit();
        if (index.split_replace) |*b| b.deinit();
        index.split_delete = null;
        index.split_replace = null;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return Entry.order(a, b) == .lt;
    }

    const ParsedEntry = struct { entry: Entry, next: usize };

    fn parseEntry(
        gpa: Allocator,
        kind: Kind,
        version: u32,
        body: []const u8,
        start: usize,
        previous_path: []const u8,
    ) ReadError!ParsedEntry {
        const raw_len = kind.rawLen();
        const fixed = 40 + raw_len + 2;
        if (start + fixed > body.len) return error.TruncatedIndex;
        const b = body[start..];

        const flags = std.mem.readInt(u16, b[40 + raw_len ..][0..2], .big);
        const extended = flags & 0x4000 != 0;
        if (extended and version < 3) return error.TruncatedIndex;
        var at = fixed;
        var skip_worktree = false;
        var intent_to_add = false;
        if (extended) {
            if (start + at + 2 > body.len) return error.TruncatedIndex;
            const extra = std.mem.readInt(u16, b[at..][0..2], .big);
            at += 2;
            skip_worktree = extra & 0x4000 != 0;
            intent_to_add = extra & 0x2000 != 0;
        }

        var path: []const u8 = undefined;
        var next: usize = undefined;
        if (version >= 4) {
            const strip = try varint.readOffset(b[at..]);
            at += strip.len;
            if (strip.value > previous_path.len) return error.TruncatedIndex;
            const keep = previous_path[0 .. previous_path.len - strip.value];
            const suffix_end = std.mem.indexOfScalarPos(u8, body, start + at, 0) orelse return error.TruncatedIndex;
            const suffix = body[start + at .. suffix_end];
            const joined = try gpa.alloc(u8, keep.len + suffix.len);
            @memcpy(joined[0..keep.len], keep);
            @memcpy(joined[keep.len..], suffix);
            path = joined;
            next = suffix_end + 1;
        } else {
            const stated: usize = flags & 0x0fff;
            const nul = std.mem.indexOfScalarPos(u8, body, start + at, 0) orelse return error.TruncatedIndex;
            const found = body[start + at .. nul];
            if (stated != 0x0fff and found.len != stated) return error.TruncatedIndex;
            path = try gpa.dupe(u8, found);
            // One to eight NULs pad the entry to a multiple of eight bytes.
            const unpadded = at + found.len + 1;
            next = start + ((unpadded + 7) & ~@as(usize, 7));
            if (next > body.len) {
                gpa.free(path);
                return error.TruncatedIndex;
            }
        }
        errdefer gpa.free(path);

        // An empty name is only legal in a split index's overlay, which is
        // checked once the extensions have been read.
        if (path.len != 0 and (path[0] == '/' or !fs.isSafePath(path))) return error.InvalidEntryPath;

        const mode_raw = std.mem.readInt(u32, b[24..28], .big);
        const mode = object.Mode.fromRaw(mode_raw) catch return error.InvalidMode;

        return .{
            .entry = .{
                .path = path,
                .oid = Oid.fromRaw(kind, b[40..][0..raw_len]) catch unreachable,
                .mode = mode,
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
            },
            .next = next,
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

    /// Add or replace an entry. `entry.path` is copied.
    pub fn add(index: *Index, entry: Entry) Allocator.Error!void {
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
    }

    /// Remove `path` at every stage. Returns how many entries went.
    pub fn remove(index: *Index, path: []const u8) usize {
        var removed: usize = 0;
        const at = index.position(path, 0);
        while (at < index.entries.items.len and std.mem.eql(u8, index.entries.items[at].path, path)) {
            index.gpa.free(index.entries.items[at].path);
            _ = index.entries.orderedRemove(at);
            removed += 1;
        }
        return removed;
    }

    /// Remove every entry under the directory `dir`. Returns how many went.
    pub fn removeDirectory(index: *Index, dir: []const u8) Allocator.Error!usize {
        const prefix = try std.fmt.allocPrint(index.gpa, "{s}/", .{dir});
        defer index.gpa.free(prefix);
        var removed: usize = 0;
        const at = index.position(prefix, 0);
        while (at < index.entries.items.len and std.mem.startsWith(u8, index.entries.items[at].path, prefix)) {
            index.gpa.free(index.entries.items[at].path);
            _ = index.entries.orderedRemove(at);
            removed += 1;
        }
        return removed;
    }

    /// Drop every entry, leaving the extensions alone.
    pub fn clear(index: *Index) void {
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
        if (entry.stat.mtime_sec > index.racy_cutoff_sec) return true;
        if (entry.stat.mtime_sec < index.racy_cutoff_sec) return false;
        // Equal seconds: compare nanoseconds where both sides have them, and
        // treat the entry as racy where either side reports zero, because a
        // filesystem with second resolution cannot tell them apart.
        if (entry.stat.mtime_nsec == 0 or index.racy_cutoff_nsec == 0) return true;
        return entry.stat.mtime_nsec >= index.racy_cutoff_nsec;
    }

    /// The version `write` would use under `options`.
    pub fn versionFor(index: *const Index, options: WriteOptions) u32 {
        return switch (options.version) {
            .v2 => 2,
            .v3 => 3,
            .v4 => 4,
            .auto => blk: {
                for (index.entries.items) |e| {
                    if (e.needsExtendedFlags()) break :blk 3;
                }
                break :blk 2;
            },
        };
    }

    /// Write the index to `sub_path` in `dir`, through `<sub_path>.lock`.
    ///
    /// A lock another writer holds is `error.LockHeld` and is left exactly as
    /// it was found.
    pub fn write(index: *Index, io: Io, dir: Io.Dir, sub_path: []const u8, options: WriteOptions) WriteError!void {
        const buffer = try index.gpa.alloc(u8, 64 * 1024);
        defer index.gpa.free(buffer);
        var lock = try fs.LockFile.open(index.gpa, io, dir, sub_path, buffer);
        defer lock.deinit(io);
        try index.writeTo(lock.writer(), options);
        try lock.commit(io);
    }

    /// Append the index's bytes to `w`.
    ///
    /// Used by `write`, and by a caller that wants the bytes without a file —
    /// a test comparing them against git's, for instance.
    pub fn writeTo(index: *Index, w: *Io.Writer, options: WriteOptions) (Io.Writer.Error || WriteError)!void {
        const version = index.versionFor(options);
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
        std.mem.writeInt(u32, header[8..12], @intCast(index.entries.items.len), .big);
        try out.writeAll(&header);

        var previous_path: []const u8 = "";
        for (index.entries.items) |entry| {
            if (entry.path.len > std.math.maxInt(u16)) return error.PathTooLong;
            var fixed: [40 + hash.max_raw_len + 4]u8 = @splat(0);

            // git truncates a racily-clean entry's recorded size to zero, so
            // that a later stat comparison cannot decide the file is
            // unchanged on the strength of a size that was never checked.
            var stat = entry.stat;
            if (index.isRacy(entry) and entry.stage == 0) stat.size = 0;

            std.mem.writeInt(u32, fixed[0..4], stat.ctime_sec, .big);
            std.mem.writeInt(u32, fixed[4..8], stat.ctime_nsec, .big);
            std.mem.writeInt(u32, fixed[8..12], stat.mtime_sec, .big);
            std.mem.writeInt(u32, fixed[12..16], stat.mtime_nsec, .big);
            std.mem.writeInt(u32, fixed[16..20], stat.dev, .big);
            std.mem.writeInt(u32, fixed[20..24], stat.ino, .big);
            std.mem.writeInt(u32, fixed[24..28], entry.mode.raw(), .big);
            std.mem.writeInt(u32, fixed[28..32], stat.uid, .big);
            std.mem.writeInt(u32, fixed[32..36], stat.gid, .big);
            std.mem.writeInt(u32, fixed[36..40], stat.size, .big);
            @memcpy(fixed[40..][0..raw_len], entry.oid.raw());

            const extended = entry.needsExtendedFlags() and version >= 3;
            var flags: u16 = @intCast(@min(entry.path.len, 0x0fff));
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
                const shared = commonPrefixLen(previous_path, entry.path);
                var varint_buf: [16]u8 = undefined;
                const strip = varint.writeOffset(&varint_buf, previous_path.len - shared);
                try out.writeAll(strip);
                try out.writeAll(entry.path[shared..]);
                try out.writeByte(0);
            } else {
                try out.writeAll(entry.path);
                // One to eight NULs: enough to pad the entry to a multiple
                // of eight bytes, and never fewer than the one that
                // terminates the name.
                const padded = (fixed_len + entry.path.len + 1 + 7) & ~@as(usize, 7);
                try out.splatByteAll(0, padded - fixed_len - entry.path.len);
            }
            previous_path = entry.path;
        }

        if (options.write_cache_tree) {
            if (index.cache_tree) |*tree| {
                var tree_body: Io.Writer.Allocating = .init(index.gpa);
                defer tree_body.deinit();
                try tree.write(&tree_body.writer);
                try writeExtension(out, "TREE", tree_body.written());
            }
        }
        if (index.resolve_undo) |*undo| {
            var undo_body: Io.Writer.Allocating = .init(index.gpa);
            defer undo_body.deinit();
            try undo.write(&undo_body.writer);
            try writeExtension(out, "REUC", undo_body.written());
        }
        for (index.unknown.items) |extension| {
            try writeExtension(out, &extension.signature, extension.data);
        }

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

    fn writeExtension(w: *Io.Writer, signature: []const u8, data: []const u8) Io.Writer.Error!void {
        try w.writeAll(signature);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(data.len), .big);
        try w.writeAll(&size);
        try w.writeAll(data);
    }

    /// The bytes `write` would produce. The result is the caller's.
    pub fn toBytes(index: *Index, options: WriteOptions) (Allocator.Error || WriteError)![]u8 {
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

test "an unknown optional extension survives a round trip byte for byte" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    try index.unknown.append(gpa, .{
        .signature = "ZZZZ".*,
        .data = try gpa.dupe(u8, "opaque bytes"),
    });
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);

    var back = try Index.parse(gpa, .sha1, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 1), back.unknown.items.len);
    try std.testing.expectEqualStrings("ZZZZ", &back.unknown.items[0].signature);
    try std.testing.expectEqualStrings("opaque bytes", back.unknown.items[0].data);

    const again = try back.toBytes(.{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
}

test "an unknown mandatory extension is refused by name" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    try index.unknown.append(gpa, .{
        .signature = "zzzz".*,
        .data = try gpa.dupe(u8, "x"),
    });
    const bytes = try index.toBytes(.{});
    defer gpa.free(bytes);
    try std.testing.expectError(error.UnsupportedExtension, Index.parse(gpa, .sha1, bytes));
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

test "fuzz: any bytes are an index or a named error" {
    try std.testing.fuzz({}, fuzzIndex, .{});
}

fn fuzzIndex(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [4096]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var index = Index.parse(gpa, .sha1, input) catch return;
    defer index.deinit();
    _ = index.find("a");
    const bytes = index.toBytes(.{}) catch return;
    gpa.free(bytes);
}
