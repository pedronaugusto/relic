//! Notes: text attached to objects without changing them, kept as commits
//! on `refs/notes/*` as git keeps them.
//!
//! A notes ref names a commit whose tree maps an object's name to a blob,
//! the name written whole or split into fanout directories, `ab/cdef…`, as
//! the tree grows. Which fanout git writes is decided by the shape of the
//! notes in memory -- a sixteen-way tree on the name's nibbles, whose parts
//! not yet looked at are kept as unread subtrees -- so that structure is
//! git's own here, step for step: what `git notes` writes after an add, a
//! removal or a merge is the tree git writes, byte for byte. Entries in a
//! notes tree that are not notes are kept and written back where they were.
//!
//! The commands are git's: `add`, `append`, `copy`, `remove`, `prune`, and
//! `merge` with the `manual`, `ours`, `theirs`, `union` and `cat_sort_uniq`
//! strategies, a manual merge leaving `NOTES_MERGE_PARTIAL`,
//! `NOTES_MERGE_REF` and `.git/NOTES_MERGE_WORKTREE` for `mergeCommit` or
//! `mergeAbort`. Each commit is made with git's message and the ref moved
//! with git's log line. A note is always given as content: git's editor
//! session (`-e`, or no message at all) is refused by name, as is `GIT_NOTES_REF`,
//! which a caller names with `ref` instead.
//!
//! `formatNote` writes a note the way `git log` shows it under a commit.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const revparse = @import("../revwalk/revparse.zig");
const revwalk = @import("../walk/walk.zig");
const message = @import("../object/message.zig");
const diff = @import("../diff/diff.zig");
const blobmerge = @import("../merge/blobmerge.zig");
const head_mod = @import("../repo/head.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// The ref notes live under when nothing else is configured.
pub const default_ref = "refs/notes/commits";

/// Errors from reading and writing notes.
pub const Error = error{
    /// A notes ref outside `refs/notes/`, which git refuses to change.
    RefOutsideNotes,
    /// `add` or `copy` onto an object that has a note, without `force`.
    NoteExists,
    /// `copy` from an object that has no note, or `remove` of one that has
    /// none without `ignore_missing`.
    NoteNotFound,
    /// No content was given: git would open an editor.
    EditorUnsupported,
    /// `-C` named something that is not a blob.
    NotABlob,
    /// Merging two notes refs that both do not exist.
    BothRefsEmpty,
    /// A remote notes ref that names nothing and is not a ref name either.
    BadRemoteRef,
    /// A merge is already in progress: `NOTES_MERGE_WORKTREE` holds files.
    MergeInProgress,
    /// `mergeCommit` with no merge in progress.
    NoMergeInProgress,
    /// `cat_sort_uniq` met a note that is not a blob.
    CombineFailed,
    /// A notes tree whose entries cannot be read as git reads them.
    MalformedNotesTree,
    /// `notes.mergeStrategy` names no strategy.
    InvalidStrategy,
} || Allocator.Error || odb_mod.Error || object.ParseError || object.TreeParseError || refs_mod.ReadError ||
    refs_mod.TransactionError || repo_mod.WriteError || revparse.Error || revwalk.Error || diff.Error ||
    head_mod.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    Io.Dir.DeleteFileError || Io.File.OpenError || Io.File.Writer.Error || Io.Dir.CreateDirPathError || Io.Dir.DeleteTreeError || error{ NameTooLong, NotACommit };

/// How a note added where one already is meets it: git's `combine_notes_*`.
pub const Combine = enum {
    /// Both, the old one first, a blank line between: what reading a tree
    /// with a note twice does, and `union`.
    concatenate,
    /// The new one.
    overwrite,
    /// The old one.
    ignore,
    /// Every line of either, sorted, each once.
    cat_sort_uniq,
};

/// The notes ref `core.notesRef` names, or `refs/notes/commits`. The
/// result is the caller's.
pub fn defaultRef(gpa: Allocator, repo: *const Repository) Allocator.Error![]u8 {
    if (repo.configuration().get("core.notesref")) |value| return gpa.dupe(u8, value);
    return gpa.dupe(u8, default_ref);
}

/// `expand_notes_ref`: `refs/notes/x` as given, `notes/x` and `x` as
/// `refs/notes/x`. The result is the caller's.
pub fn expandRef(gpa: Allocator, ref: []const u8) Allocator.Error![]u8 {
    if (std.mem.startsWith(u8, ref, "refs/notes/")) return gpa.dupe(u8, ref);
    if (std.mem.startsWith(u8, ref, "notes/")) return std.mem.concat(gpa, u8, &.{ "refs/", ref });
    return std.mem.concat(gpa, u8, &.{ "refs/notes/", ref });
}

// ---------------------------------------------------------------------------
// The notes tree in memory: git's `notes.c`.

const Leaf = struct {
    /// The object's name for a note. For a subtree, the prefix its path
    /// spells, zero-padded, with the prefix's length in the last byte.
    key: [hash.max_raw_len]u8,
    val: Oid,
};

const IntNode = struct {
    a: [16]Ptr = @splat(.empty),
};

const Ptr = union(enum) {
    empty,
    internal: *IntNode,
    note: *Leaf,
    subtree: *Leaf,
};

const NonNote = struct {
    path: []const u8,
    mode: u32,
    oid: Oid,
};

fn nibble(n: usize, key: []const u8) u4 {
    const byte = key[n >> 1];
    return @intCast(if (n & 1 == 0) byte >> 4 else byte & 0x0f);
}

/// A notes ref's tree, open: git's `struct notes_tree`.
pub const Notes = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    repo: *Repository,
    /// The notes ref it was read from. Owned.
    ref: []const u8,
    /// What `add` does where there is a note already, unless told.
    combine: Combine,
    root: *IntNode,
    non_notes: std.ArrayList(NonNote) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Whether anything has changed since it was read.
    dirty: bool = false,
    /// Where `writeTree` has got to in the non-notes, while it writes.
    writing: ?Writing = null,

    const Writing = struct { next_non_note: usize = 0 };

    fn rawLen(t: *const Notes) usize {
        return t.repo.objectFormat().rawLen();
    }

    fn keyIndex(t: *const Notes) usize {
        return t.rawLen() - 1;
    }

    /// `init_notes`: the notes `ref` names, read lazily. A ref that names
    /// nothing is an empty tree.
    pub fn open(gpa: Allocator, io: Io, repo: *Repository, ref: []const u8, combine: Combine) Self.Error!Notes {
        const root = try gpa.create(IntNode);
        root.* = .{};
        var t: Notes = .{
            .gpa = gpa,
            .repo = repo,
            .ref = undefined,
            .combine = combine,
            .root = root,
            .arena = .init(gpa),
        };
        t.ref = t.arena.allocator().dupe(u8, ref) catch |err| {
            t.deinit();
            return err;
        };
        errdefer t.deinit();
        const tip = revparse.resolve(gpa, io, repo, ref) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadRevision => return t,
            else => |e| return e,
        };
        const header = try repo.objectDatabase().readHeader(io, tip);
        const tree = switch (header.type) {
            .commit => try repo.commitTree(io, tip),
            .tree => tip,
            .tag => try repo.commitTree(io, try repo.peel(io, tip)),
            else => return t,
        };
        var leaf: Leaf = .{ .key = @splat(0), .val = tree };
        try t.loadSubtree(io, &leaf, t.root, 0);
        return t;
    }

    /// Release everything.
    pub fn deinit(t: *Notes) void {
        freeNode(t.gpa, t.root);
        t.gpa.destroy(t.root);
        t.non_notes.deinit(t.gpa);
        t.arena.deinit();
        t.* = undefined;
    }

    fn freeNode(gpa: Allocator, node: *IntNode) void {
        for (node.a) |p| switch (p) {
            .empty => {},
            .internal => |child| {
                freeNode(gpa, child);
                gpa.destroy(child);
            },
            .note, .subtree => |l| gpa.destroy(l),
        };
    }

    fn prefixMatches(t: *const Notes, key: []const u8, subtree_key: []const u8) bool {
        const len = subtree_key[t.keyIndex()];
        return std.mem.eql(u8, key[0..len], subtree_key[0..len]);
    }

    /// `note_tree_search`.
    fn search(t: *Notes, io: Io, tree: **IntNode, n: *usize, key: []const u8) ErrorNamespace.Error!*Ptr {
        while (true) {
            const p0 = tree.*.a[0];
            if (p0 == .subtree and t.prefixMatches(key, &p0.subtree.key)) {
                tree.*.a[0] = .empty;
                defer t.gpa.destroy(p0.subtree);
                try t.loadSubtree(io, p0.subtree, tree.*, n.*);
                continue;
            }
            const i = nibble(n.*, key);
            switch (tree.*.a[i]) {
                .internal => |child| {
                    tree.* = child;
                    n.* += 1;
                    continue;
                },
                .subtree => |l| {
                    if (t.prefixMatches(key, &l.key)) {
                        tree.*.a[i] = .empty;
                        defer t.gpa.destroy(l);
                        try t.loadSubtree(io, l, tree.*, n.*);
                        continue;
                    }
                    return &tree.*.a[i];
                },
                else => return &tree.*.a[i],
            }
        }
    }

    /// `note_tree_find`.
    fn find(t: *Notes, io: Io, key: []const u8) ErrorNamespace.Error!?*Leaf {
        var tree = t.root;
        var n: usize = 0;
        const p = try t.search(io, &tree, &n, key);
        if (p.* == .note and std.mem.eql(u8, p.note.key[0..t.rawLen()], key[0..t.rawLen()])) return p.note;
        return null;
    }

    /// `note_tree_consolidate`.
    fn consolidate(t: *Notes, tree: *IntNode, parent: *IntNode, index: u4) bool {
        var found: Ptr = .empty;
        for (tree.a) |p| {
            if (p != .empty) {
                if (found != .empty) return false;
                found = p;
            }
        }
        if (found != .empty and found != .note) return false;
        parent.a[index] = found;
        t.gpa.destroy(tree);
        return true;
    }

    /// `note_tree_remove`: the note keyed `key`, if there is one; its value
    /// is returned.
    fn removeKey(t: *Notes, io: Io, start: *IntNode, start_n: usize, key: []const u8) ErrorNamespace.Error!?Oid {
        var tree = start;
        var n = start_n;
        const p = try t.search(io, &tree, &n, key);
        if (p.* != .note) return null;
        const l = p.note;
        if (!std.mem.eql(u8, l.key[0..t.rawLen()], key[0..t.rawLen()])) return null;
        const val = l.val;
        t.gpa.destroy(l);
        p.* = .empty;
        if (n == 0) return val;
        var stack: [2 * hash.max_raw_len + 1]*IntNode = undefined;
        stack[0] = t.root;
        var i: usize = 0;
        while (i < n) : (i += 1) stack[i + 1] = stack[i].a[nibble(i, key)].internal;
        while (i > 0 and t.consolidate(stack[i], stack[i - 1], nibble(i - 1, key))) i -= 1;
        return val;
    }

    /// `note_tree_insert`. Takes `entry`.
    fn insert(t: *Notes, io: Io, start: *IntNode, start_n: usize, entry: *Leaf, kind: std.meta.Tag(Ptr), combine: Combine) ErrorNamespace.Error!void {
        // `entry` is this call's on every path, an error's too.
        var tree = start;
        var n = start_n;
        const p = t.search(io, &tree, &n, &entry.key) catch |err| {
            t.gpa.destroy(entry);
            return err;
        };
        switch (p.*) {
            .empty => {
                if (entry.val.isZero()) {
                    t.gpa.destroy(entry);
                } else {
                    p.* = if (kind == .note) .{ .note = entry } else .{ .subtree = entry };
                }
                return;
            },
            .note => |l| switch (kind) {
                .note => if (std.mem.eql(u8, l.key[0..t.rawLen()], entry.key[0..t.rawLen()])) {
                    defer t.gpa.destroy(entry);
                    if (l.val.eql(entry.val)) return;
                    try t.combineInto(io, &l.val, entry.val, combine);
                    if (l.val.isZero()) _ = try t.removeKey(io, tree, n, &entry.key);
                    return;
                },
                .subtree => if (t.prefixMatches(&l.key, &entry.key)) {
                    defer t.gpa.destroy(entry);
                    try t.loadSubtree(io, entry, tree, n);
                    return;
                },
                else => unreachable,
            },
            .subtree => |l| if (t.prefixMatches(&entry.key, &l.key)) {
                p.* = .empty;
                defer t.gpa.destroy(l);
                t.loadSubtree(io, l, tree, n) catch |err| {
                    t.gpa.destroy(entry);
                    return err;
                };
                return t.insert(io, tree, n, entry, kind, combine);
            },
            .internal => unreachable,
        }
        // A leaf that is not this one: both go one level down.
        if (entry.val.isZero()) {
            t.gpa.destroy(entry);
            return;
        }
        const node = try t.gpa.create(IntNode);
        node.* = .{};
        const old = p.*;
        const old_leaf = switch (old) {
            .note, .subtree => |l| l,
            else => unreachable,
        };
        t.insert(io, node, n + 1, old_leaf, std.meta.activeTag(old), combine) catch |err| {
            // The failed insert released the old leaf, and this one too.
            p.* = .empty;
            t.gpa.destroy(node);
            t.gpa.destroy(entry);
            return err;
        };
        p.* = .{ .internal = node };
        return t.insert(io, node, n + 1, entry, kind, combine);
    }

    /// `load_subtree`: read the tree behind `subtree` into `node` at level
    /// `n`.
    fn loadSubtree(t: *Notes, io: Io, subtree: *const Leaf, node: *IntNode, n: usize) ErrorNamespace.Error!void {
        const raw_len = t.rawLen();
        const found = try t.repo.objectDatabase().read(io, subtree.val);
        defer t.repo.objectDatabase().allocator().free(found.bytes);
        if (found.type != .tree) return error.MalformedNotesTree;
        const prefix_len: usize = subtree.key[t.keyIndex()];
        if (prefix_len >= raw_len or prefix_len * 2 < n) return error.MalformedNotesTree;
        var key: [hash.max_raw_len]u8 = @splat(0);
        @memcpy(key[0..prefix_len], subtree.key[0..prefix_len]);
        var it = object.Tree.parse(t.repo.objectFormat(), found.bytes).iterate();
        while (try it.next()) |entry| {
            const mode = entry.mode.raw();
            var kind: ?std.meta.Tag(Ptr) = null;
            if (entry.name.len == 2 * (raw_len - prefix_len)) {
                if (isReg(mode) and hexToBytes(key[prefix_len..raw_len], entry.name)) {
                    kind = .note;
                }
            } else if (entry.name.len == 2) {
                if (mode == 0o040000 and hexToBytes(key[prefix_len .. prefix_len + 1], entry.name)) {
                    const len = prefix_len + 1;
                    @memset(key[len .. raw_len - 1], 0);
                    key[raw_len - 1] = @intCast(len);
                    kind = .subtree;
                }
            }
            if (kind) |k| {
                const l = try t.gpa.create(Leaf);
                l.* = .{ .key = key, .val = entry.oid };
                try t.insert(io, node, n, l, k, .concatenate);
                continue;
            }
            // Not a note: its full path is the subtree's fanout, then the
            // entry's own name.
            var path: std.ArrayList(u8) = .empty;
            const a = t.arena.allocator();
            for (subtree.key[0..prefix_len]) |byte| try path.print(a, "{x:0>2}/", .{byte});
            try path.appendSlice(a, entry.name);
            try t.addNonNote(path.items, mode, entry.oid);
        }
    }

    /// `add_non_note`: kept sorted, a path already there replaced.
    fn addNonNote(t: *Notes, path: []const u8, mode: u32, oid: Oid) Allocator.Error!void {
        var lo: usize = 0;
        var hi: usize = t.non_notes.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, t.non_notes.items[mid].path, path)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    t.non_notes.items[mid].mode = mode;
                    t.non_notes.items[mid].oid = oid;
                    return;
                },
            }
        }
        try t.non_notes.insert(t.gpa, lo, .{ .path = path, .mode = mode, .oid = oid });
        if (t.writing) |*w| {
            // git's list is linked; one that lands before where the writer
            // has got to is never reached by it.
            if (w.next_non_note > lo) w.next_non_note += 1;
        }
    }

    /// The note on `object`, or `null`.
    pub fn get(t: *Notes, io: Io, obj: Oid) Self.Error!?Oid {
        const l = (try t.find(io, obj.raw())) orelse return null;
        return l.val;
    }

    /// `add_note`: put `note` on `object`, meeting a note already there as
    /// `combine` says (`null` is the tree's own). A zero `note` removes it.
    pub fn add(t: *Notes, io: Io, obj: Oid, note: Oid, combine: ?Combine) Self.Error!void {
        t.dirty = true;
        const l = try t.gpa.create(Leaf);
        l.* = .{ .key = @splat(0), .val = note };
        @memcpy(l.key[0..t.rawLen()], obj.raw());
        try t.insert(io, t.root, 0, l, .note, combine orelse t.combine);
    }

    /// `remove_note`: whether there was a note on `object` to remove.
    pub fn remove(t: *Notes, io: Io, obj: Oid) Self.Error!bool {
        const removed = try t.removeKey(io, t.root, 0, obj.raw());
        if (removed == null) return false;
        t.dirty = true;
        return true;
    }

    /// `copy_note`: `from`'s note onto `to`. With `force` false, a note on
    /// `to` is `error.NoteExists`.
    pub const CopyOptions = struct { force: bool = false, combine: ?Combine = null };
    pub fn copy(t: *Notes, io: Io, from: Oid, to: Oid, options: CopyOptions) Self.Error!void {
        const force = options.force;
        const combine = options.combine;
        const note = try t.get(io, from);
        const existing = try t.get(io, to);
        if (!force and existing != null) return error.NoteExists;
        if (note) |n| return t.add(io, to, n, combine);
        if (existing != null) return t.add(io, to, Oid.zero(t.repo.objectFormat()), combine);
    }

    /// One note: the object it is on and the blob it is.
    pub const Entry = struct { object: Oid, note: Oid };

    /// What `list` gathers, note by note.
    const Collect = struct {
        out: *std.ArrayList(Entry),
        gpa: Allocator,
        fn each(c: Collect, t2: *Notes, key: []const u8, val: Oid, path: []const u8) ErrorNamespace.Error!void {
            _ = path;
            try c.out.append(c.gpa, .{ .object = Oid.fromRaw(t2.repo.objectFormat(), key[0..t2.rawLen()]) catch unreachable, .note = val }); // unreachable: the key is cut to the format's raw length
        }
    };

    /// Every note, in the order `git notes list` prints them. Reads the
    /// whole tree. The result is the caller's.
    pub fn list(t: *Notes, gpa: Allocator, io: Io) Self.Error![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(gpa);
        try t.forEach(io, t.root, 0, 0, .{}, Collect{ .out = &out, .gpa = gpa });
        return out.toOwnedSlice(gpa);
    }

    const EachFlags = struct {
        yield_subtrees: bool = false,
        dont_unpack_subtrees: bool = false,
    };

    /// `determine_fanout`.
    fn determineFanout(tree: *const IntNode, n: usize, fanout: usize) usize {
        if (n % 2 != 0 or n > 2 * fanout) return fanout;
        for (tree.a) |p| switch (p) {
            .subtree, .internal => {},
            else => return fanout,
        };
        return fanout + 1;
    }

    /// `construct_path_with_fanout`.
    fn pathWithFanout(t: *const Notes, key: []const u8, fanout: usize, buf: []u8) []u8 {
        var hex_buf: [hash.max_hex_len]u8 = undefined;
        // unreachable: a raw name of the format's length is at most max_hex_len hex digits
        const hex = std.mem.print(&hex_buf, "{x}", .{key[0..t.rawLen()]}) catch unreachable;
        // Each fanout level is two of the name's digits and a slash, and
        // some of the name is left for the file.
        assert(2 * fanout < hex.len);
        assert(buf.len >= hex.len + fanout);
        var i: usize = 0;
        var j: usize = 0;
        var f = fanout;
        while (f > 0) : (f -= 1) {
            buf[i] = hex[j];
            buf[i + 1] = hex[j + 1];
            buf[i + 2] = '/';
            i += 3;
            j += 2;
        }
        @memcpy(buf[i .. i + hex.len - j], hex[j..]);
        return buf[0 .. i + hex.len - j];
    }

    /// `for_each_note_helper`.
    fn forEach(t: *Notes, io: Io, tree: *IntNode, n: usize, fanout_in: usize, flags: EachFlags, callback: anytype) ErrorNamespace.Error!void {
        const fanout = determineFanout(tree, n, fanout_in);
        var buf: [hash.max_hex_len + hash.max_raw_len + 2]u8 = undefined;
        var i: usize = 0;
        while (i < 16) {
            switch (tree.a[i]) {
                .internal => |child| try t.forEach(io, child, n + 1, fanout, flags, callback),
                .subtree => |l| {
                    if (n < 2 * fanout and flags.yield_subtrees) {
                        var path_len: usize = @as(usize, l.key[t.keyIndex()]) * 2 + fanout;
                        const full = t.pathWithFanout(&l.key, fanout, &buf);
                        _ = full;
                        if (buf[path_len - 1] != '/') {
                            buf[path_len] = '/';
                            path_len += 1;
                        }
                        try callback.each(t, &l.key, l.val, buf[0..path_len]);
                    }
                    if (n >= 2 * fanout or !flags.dont_unpack_subtrees) {
                        tree.a[i] = .empty;
                        defer t.gpa.destroy(l);
                        try t.loadSubtree(io, l, tree, n);
                        continue; // `goto redo`
                    }
                },
                .note => |l| {
                    const path = t.pathWithFanout(&l.key, fanout, &buf);
                    try callback.each(t, &l.key, l.val, path);
                },
                .empty => {},
            }
            i += 1;
        }
    }

    /// What `writeTree` writes, note by note.
    const TreeWriter = struct {
        root: *Stack,
        io: Io,
        fn each(w: TreeWriter, t2: *Notes, key: []const u8, val: Oid, path_in: []const u8) ErrorNamespace.Error!void {
            _ = key;
            var path = path_in;
            var mode: u32 = 0o100644;
            if (path[path.len - 1] == '/') {
                path = path[0 .. path.len - 1];
                mode = 0o040000;
            }
            try t2.writeNonNotesUntil(w.io, w.root, path);
            try w.root.add(w.io, t2, path, mode, val);
        }
    };

    /// `write_notes_tree`: write the tree objects and return the root's
    /// name. Parts never read are written as they were.
    pub fn writeTree(t: *Notes, io: Io) Self.Error!Oid {
        var root: Stack = .{};
        defer root.deinit(t.gpa);
        t.writing = .{};
        defer t.writing = null;
        try t.forEach(io, t.root, 0, 0, .{ .yield_subtrees = true, .dont_unpack_subtrees = true }, TreeWriter{ .root = &root, .io = io });
        try t.writeNonNotesUntil(io, &root, null);
        try root.finishSubtree(io, t);
        return t.repo.objectDatabase().write(io, .tree, root.buf.items);
    }

    /// `write_each_non_note_until`: the non-notes that sort before
    /// `note_path`, or all that are left; one at `note_path` itself gives
    /// way to the note.
    fn writeNonNotesUntil(t: *Notes, io: Io, root: *Stack, note_path: ?[]const u8) ErrorNamespace.Error!void {
        const w = &t.writing.?;
        while (w.next_non_note < t.non_notes.items.len) {
            const nn = t.non_notes.items[w.next_non_note];
            if (note_path) |p| {
                const order = std.mem.order(u8, nn.path, p);
                if (order == .gt) break;
                if (order == .lt) try root.add(io, t, nn.path, nn.mode, nn.oid);
            } else try root.add(io, t, nn.path, nn.mode, nn.oid);
            w.next_non_note += 1;
        }
    }

    /// `commit_notes`: when anything changed, a commit of the tree on top
    /// of the ref, and the ref moved to it with `notes: <msg>` in its log.
    /// `null` when nothing changed.
    pub fn commit(t: *Notes, io: Io, msg: []const u8, who: object.Signature) Self.Error!?Oid {
        if (!t.dirty) return null;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(t.gpa);
        try text.appendSlice(t.gpa, msg);
        if (text.items.len != 0 and text.items[text.items.len - 1] != '\n') try text.append(t.gpa, '\n');
        const parent = try t.repo.refStore().readOid(t.gpa, io, t.ref);
        const parents: []const Oid = if (parent) |p| &.{p} else &.{};
        const result = try t.commitWith(io, parents, text.items, who);
        const log = try std.mem.concat(t.gpa, u8, &.{ "notes: ", text.items });
        defer t.gpa.free(log);
        try updateRef(io, t.repo, t.ref, result, .any, log, who);
        return result;
    }

    /// `create_notes_commit` with the parents given.
    fn commitWith(t: *Notes, io: Io, parents: []const Oid, msg: []const u8, who: object.Signature) ErrorNamespace.Error!Oid {
        const tree = try t.writeTree(io);
        return t.repo.writeCommit(io, .{
            .tree = tree,
            .parents = parents,
            .author = who,
            .committer = who,
            .message = msg,
            .signing = .{ .sign = .never },
        }, null);
    }

    /// `prune_notes`: drop every note on an object the repository does not
    /// have. The objects pruned are returned, the caller's.
    pub const PruneOptions = struct { dry_run: bool = false };
    pub fn prune(t: *Notes, gpa: Allocator, io: Io, options: Notes.PruneOptions) Self.Error![]Oid {
        const dry_run = options.dry_run;
        const all = try t.list(gpa, io);
        defer gpa.free(all);
        var gone: std.ArrayList(Oid) = .empty;
        errdefer gone.deinit(gpa);
        var i = all.len;
        // git collects them onto the front of a list.
        while (i > 0) {
            i -= 1;
            if (try t.repo.objectDatabase().exists(io, all[i].object)) continue;
            try gone.append(gpa, all[i].object);
        }
        if (!dry_run) for (gone.items) |o| {
            _ = try t.remove(io, o);
        };
        return gone.toOwnedSlice(gpa);
    }

    /// git's `combine_notes_*` into `cur`.
    fn combineInto(t: *Notes, io: Io, cur: *Oid, new: Oid, how: Combine) ErrorNamespace.Error!void {
        switch (how) {
            .overwrite => cur.* = new,
            .ignore => {},
            .concatenate => {
                const new_msg = (try t.readBlob(io, new)) orelse return;
                defer t.repo.objectDatabase().allocator().free(new_msg);
                if (new_msg.len == 0) return;
                const cur_msg = (try t.readBlob(io, cur.*)) orelse {
                    cur.* = new;
                    return;
                };
                defer t.repo.objectDatabase().allocator().free(cur_msg);
                if (cur_msg.len == 0) {
                    cur.* = new;
                    return;
                }
                const keep = if (cur_msg[cur_msg.len - 1] == '\n') cur_msg[0 .. cur_msg.len - 1] else cur_msg;
                const joined = try std.mem.concat(t.gpa, u8, &.{ keep, "\n\n", new_msg });
                defer t.gpa.free(joined);
                cur.* = try t.repo.objectDatabase().write(io, .blob, joined);
            },
            .cat_sort_uniq => {
                var lines: std.ArrayList([]const u8) = .empty;
                defer lines.deinit(t.gpa);
                var held: [2]?[]u8 = .{ null, null };
                defer for (held) |h| if (h) |b| t.gpa.free(b);
                for ([_]Oid{ cur.*, new }, 0..) |oid, k| {
                    if (oid.isZero()) continue;
                    const found = t.repo.objectDatabase().read(io, oid) catch |err| switch (err) {
                        error.ObjectNotFound => return error.CombineFailed,
                        else => |e| return e,
                    };
                    if (found.type != .blob) {
                        t.repo.objectDatabase().allocator().free(found.bytes);
                        return error.CombineFailed;
                    }
                    held[k] = found.bytes;
                    var it = std.mem.splitScalar(u8, found.bytes, '\n');
                    while (it.next()) |line| if (line.len != 0) try lines.append(t.gpa, line);
                }
                std.mem.sort([]const u8, lines.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lessThan);
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(t.gpa);
                var last: ?[]const u8 = null;
                for (lines.items) |line| {
                    if (last) |l| if (std.mem.eql(u8, l, line)) continue;
                    try out.appendSlice(t.gpa, line);
                    try out.append(t.gpa, '\n');
                    last = line;
                }
                cur.* = try t.repo.objectDatabase().write(io, .blob, out.items);
            },
        }
    }

    /// A blob's bytes, owned by the object database's allocator, or `null`
    /// for the zero name, a missing object or one that is not a blob.
    fn readBlob(t: *Notes, io: Io, oid: Oid) ErrorNamespace.Error!?[]u8 {
        if (oid.isZero()) return null;
        const found = t.repo.objectDatabase().read(io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return null,
            else => |e| return e,
        };
        if (found.type != .blob) {
            t.repo.objectDatabase().allocator().free(found.bytes);
            return null;
        }
        return found.bytes;
    }
};

fn isReg(mode: u32) bool {
    return mode & 0o170000 == 0o100000;
}

fn hexToBytes(out: []u8, text: []const u8) bool {
    if (text.len != out.len * 2) return false;
    for (out, 0..) |*b, i| {
        const hi = std.fmt.charToDigit(text[2 * i], 16) catch return false;
        const lo = std.fmt.charToDigit(text[2 * i + 1], 16) catch return false;
        b.* = @intCast(hi * 16 + lo);
    }
    return true;
}

/// git's `tree_write_stack`: the trees being written, one per fanout
/// level, each holding its open subtree's two-character name.
const Stack = struct {
    buf: std.ArrayList(u8) = .empty,
    next: ?*Stack = null,
    path: [2]u8 = .{ 0, 0 },

    fn deinit(s: *Stack, gpa: Allocator) void {
        if (s.next) |n| {
            n.deinit(gpa);
            gpa.destroy(n);
        }
        s.buf.deinit(gpa);
        s.* = undefined;
    }

    fn entry(s: *Stack, gpa: Allocator, mode: u32, name: []const u8, oid: Oid) Allocator.Error!void {
        try s.buf.print(gpa, "{o} {s}\x00", .{ mode, name });
        try s.buf.appendSlice(gpa, oid.raw());
    }

    /// `tree_write_stack_finish_subtree`.
    fn finishSubtree(s: *Stack, io: Io, t: *Notes) Error!void {
        const n = s.next orelse return;
        try n.finishSubtree(io, t);
        const oid = try t.repo.objectDatabase().write(io, .tree, n.buf.items);
        n.buf.deinit(t.gpa);
        t.gpa.destroy(n);
        s.next = null;
        try s.entry(t.gpa, 0o040000, &s.path, oid);
        s.path = .{ 0, 0 };
    }

    /// `write_each_note_helper`.
    fn add(root: *Stack, io: Io, t: *Notes, path: []const u8, mode: u32, oid: Oid) Error!void {
        var tws = root;
        var n: usize = 0;
        while (3 * n < path.len) {
            const at = 3 * n;
            if (!(path.len > at + 2 and path[at] == tws.path[0] and path[at + 1] == tws.path[1] and path[at + 2] == '/')) break;
            n += 1;
            tws = tws.next orelse break;
        }
        try tws.finishSubtree(io, t);
        while (3 * n + 2 < path.len and path[3 * n + 2] == '/') {
            const child = try t.gpa.create(Stack);
            child.* = .{};
            tws.next = child;
            tws.path = .{ path[3 * n], path[3 * n + 1] };
            n += 1;
            tws = child;
        }
        try tws.entry(t.gpa, mode, path[3 * n ..], oid);
    }
};

fn updateRef(io: Io, repo: *Repository, name: []const u8, new: Oid, expected: refs_mod.Expected, log: []const u8, who: object.Signature) Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(name, .{ .direct = new }, expected);
    try tx.commit(io, .{ .who = who, .message = log, .policy = repo.reflogPolicy() });
}

// ---------------------------------------------------------------------------
// The commands: git's `builtin/notes.c`.

/// One piece of a note, as `-m`, `-F` and `-C` give them.
pub const Content = union(enum) {
    /// `-m <text>` or `-F <file>`'s bytes: cleaned of surrounding blank
    /// lines and trailing whitespace unless `stripspace` says otherwise.
    text: []const u8,
    /// `-C <blob>`: that blob's bytes as they are.
    blob: Oid,
};

/// What `add` and `append` write.
pub const WriteOptions = struct {
    /// `--ref`: the notes ref, as `expandRef` reads it. `null` is
    /// `defaultRef`.
    ref: ?[]const u8 = null,
    /// Who makes the notes commit, and when.
    who: object.Signature,
    /// The note, in pieces joined by `separator`. Empty is git's editor,
    /// refused.
    contents: []const Content,
    /// `--separator`: what goes between pieces, a newline added when it
    /// does not end in one. `null` is `--no-separator`.
    separator: ?[]const u8 = "\n",
    /// `--[no-]stripspace`; `null` cleans the `text` pieces only.
    stripspace: ?bool = null,
    /// `--allow-empty`: keep an empty note rather than remove the note.
    allow_empty: bool = false,
    /// `-f`: `add` over a note that is there.
    force: bool = false,
};

/// What `add` or `append` did.
pub const Outcome = enum { added, removed };

fn refFor(gpa: Allocator, repo: *const Repository, ref: ?[]const u8) Error![]u8 {
    const name = if (ref) |r| try expandRef(gpa, r) else try defaultRef(gpa, repo);
    errdefer gpa.free(name);
    if (!std.mem.startsWith(u8, name, "refs/notes/")) return error.RefOutsideNotes;
    return name;
}

fn appendSeparator(gpa: Allocator, buf: *std.ArrayList(u8), separator: ?[]const u8) Allocator.Error!void {
    const sep = separator orelse return;
    try buf.appendSlice(gpa, sep);
    if (sep.len == 0 or sep[sep.len - 1] != '\n') try buf.append(gpa, '\n');
}

/// `concat_messages`.
fn concatContents(gpa: Allocator, io: Io, repo: *Repository, options: WriteOptions) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (options.contents) |piece| {
        if (buf.items.len != 0) try appendSeparator(gpa, &buf, options.separator);
        var strip = false;
        switch (piece) {
            .text => |text| {
                try buf.appendSlice(gpa, text);
                strip = true;
            },
            .blob => |oid| {
                const found = try repo.objectDatabase().read(io, oid);
                defer repo.objectDatabase().allocator().free(found.bytes);
                if (found.type != .blob) return error.NotABlob;
                try buf.appendSlice(gpa, found.bytes);
            },
        }
        if (options.stripspace) |s| strip = s;
        if (strip) {
            const cleaned = try message.stripSpace(gpa, buf.items, null);
            buf.deinit(gpa);
            buf = .fromOwnedSlice(cleaned);
        }
    }
    return buf.toOwnedSlice(gpa);
}

/// `git notes add`: put the note on `obj`, replacing one there only with
/// `force`. An empty note removes the note unless `allow_empty`.
pub fn add(gpa: Allocator, io: Io, repo: *Repository, obj: Oid, options: WriteOptions) Self.Error!Outcome {
    if (options.contents.len == 0) return error.EditorUnsupported;
    const text = try concatContents(gpa, io, repo, options);
    defer gpa.free(text);
    const ref = try refFor(gpa, repo, options.ref);
    defer gpa.free(ref);
    var t = try Notes.open(gpa, io, repo, ref, .concatenate);
    defer t.deinit();
    if (try t.get(io, obj) != null and !options.force) return error.NoteExists;
    return writeNote("add", io, &t, obj, text, options);
}

fn writeNote(comptime verb: []const u8, io: Io, t: *Notes, obj: Oid, text: []const u8, options: WriteOptions) Error!Outcome {
    if (text.len != 0 or options.allow_empty) {
        const blob = try t.repo.objectDatabase().write(io, .blob, text);
        try t.add(io, obj, blob, .overwrite);
        _ = try t.commit(io, "Notes added by 'git notes " ++ verb ++ "'", options.who);
        return .added;
    }
    _ = try t.remove(io, obj);
    _ = try t.commit(io, "Notes removed by 'git notes " ++ verb ++ "'", options.who);
    return .removed;
}

/// `git notes append`: the note there, a separator, and the new text.
pub fn append(gpa: Allocator, io: Io, repo: *Repository, obj: Oid, options: WriteOptions) Self.Error!Outcome {
    if (options.contents.len == 0) return error.EditorUnsupported;
    var text: std.ArrayList(u8) = .fromOwnedSlice(try concatContents(gpa, io, repo, options));
    defer text.deinit(gpa);
    const ref = try refFor(gpa, repo, options.ref);
    defer gpa.free(ref);
    var t = try Notes.open(gpa, io, repo, ref, .concatenate);
    defer t.deinit();
    if (try t.get(io, obj)) |existing| {
        const found = try repo.objectDatabase().read(io, existing);
        defer repo.objectDatabase().allocator().free(found.bytes);
        var prev: std.ArrayList(u8) = .empty;
        defer prev.deinit(gpa);
        try prev.appendSlice(gpa, found.bytes);
        if (text.items.len != 0 and found.bytes.len != 0) try appendSeparator(gpa, &prev, options.separator);
        try text.insertSlice(gpa, 0, prev.items);
    }
    return writeNote("append", io, &t, obj, text.items, options);
}

/// How `copy` and `remove` work.
pub const RefOptions = struct {
    ref: ?[]const u8 = null,
    who: object.Signature,
    /// `copy -f`: over a note that is there.
    force: bool = false,
    /// `remove --ignore-missing`.
    ignore_missing: bool = false,
};

/// `git notes copy`: `from`'s note onto `to`.
pub const CopyRefOptions = struct { from: Oid, to: Oid, ref: ?[]const u8 = null, who: object.Signature, force: bool = false };
pub fn copy(gpa: Allocator, io: Io, repo: *Repository, options: CopyRefOptions) Self.Error!void {
    const from = options.from;
    const to = options.to;
    const ref = try refFor(gpa, repo, options.ref);
    defer gpa.free(ref);
    var t = try Notes.open(gpa, io, repo, ref, .concatenate);
    defer t.deinit();
    if (try t.get(io, to) != null and !options.force) return error.NoteExists;
    const note = (try t.get(io, from)) orelse return error.NoteNotFound;
    try t.add(io, to, note, .overwrite);
    _ = try t.commit(io, "Notes added by 'git notes copy'", options.who);
}

/// `git notes remove`: the notes on `objects`. Without `ignore_missing`,
/// an object with no note is `error.NoteNotFound` and nothing is committed,
/// as git commits nothing then. Returns how many notes were removed.
pub fn remove(gpa: Allocator, io: Io, repo: *Repository, objects: []const Oid, options: RefOptions) Self.Error!usize {
    const ref = try refFor(gpa, repo, options.ref);
    defer gpa.free(ref);
    var t = try Notes.open(gpa, io, repo, ref, .concatenate);
    defer t.deinit();
    var removed: usize = 0;
    var missing = false;
    for (objects) |o| {
        if (try t.remove(io, o)) removed += 1 else missing = true;
    }
    if (missing and !options.ignore_missing) return error.NoteNotFound;
    _ = try t.commit(io, "Notes removed by 'git notes remove'", options.who);
    return removed;
}

/// `git notes prune`: drop the notes on objects the repository does not
/// have. The objects are returned, the caller's.
pub const PruneOptions = struct { ref: ?[]const u8 = null, who: object.Signature, dry_run: bool = false };
pub fn prune(gpa: Allocator, io: Io, repo: *Repository, options: PruneOptions) Self.Error![]Oid {
    const dry_run = options.dry_run;
    const ref = try refFor(gpa, repo, options.ref);
    defer gpa.free(ref);
    var t = try Notes.open(gpa, io, repo, ref, .concatenate);
    defer t.deinit();
    const gone = try t.prune(gpa, io, .{ .dry_run = dry_run });
    errdefer gpa.free(gone);
    if (!dry_run) _ = try t.commit(io, "Notes removed by 'git notes prune'", options.who);
    return gone;
}

/// The note on `obj` in `ref` (`null` for `defaultRef`), as bytes the
/// caller owns, or `null`.
pub fn show(gpa: Allocator, io: Io, repo: *Repository, ref: ?[]const u8, obj: Oid) Self.Error!?[]u8 {
    const name = try refFor(gpa, repo, ref);
    defer gpa.free(name);
    var t = try Notes.open(gpa, io, repo, name, .concatenate);
    defer t.deinit();
    const note = (try t.get(io, obj)) orelse return null;
    const found = try repo.objectDatabase().read(io, note);
    defer repo.objectDatabase().allocator().free(found.bytes);
    const bytes = try gpa.dupe(u8, found.bytes);
    return bytes;
}

/// Errors from `formatNote`.
pub const FormatNoteError = Error || Io.Writer.Error;

/// `format_note`: the note on `obj` in `t` as `git log` shows it under a
/// commit -- a blank line, `Notes:` (or `Notes (<name>):` for a ref other
/// than `refs/notes/commits`), and each line indented four spaces -- or,
/// with `raw`, the lines alone, as `%N` gives them. Nothing for an object
/// with no note.
pub const FormatOptions = struct { raw: bool = false };

pub fn formatNote(io: Io, t: *Notes, obj: Oid, w: *Io.Writer, options: FormatOptions) FormatNoteError!void {
    const raw = options.raw;
    const note = (try t.get(io, obj)) orelse return;
    const found = t.repo.objectDatabase().read(io, note) catch return;
    defer t.repo.objectDatabase().allocator().free(found.bytes);
    if (found.type != .blob) return;
    var msg = found.bytes;
    if (msg.len != 0 and msg[msg.len - 1] == '\n') msg = msg[0 .. msg.len - 1];
    if (!raw) {
        if (std.mem.eql(u8, t.ref, default_ref)) {
            try w.writeAll("\nNotes:\n");
        } else {
            var short = t.ref;
            if (std.mem.startsWith(u8, short, "refs/")) short = short[5..];
            if (std.mem.startsWith(u8, short, "notes/")) short = short[6..];
            try w.print("\nNotes ({s}):\n", .{short});
        }
    }
    var at: usize = 0;
    while (at < msg.len) {
        const end = std.mem.findScalarPos(u8, msg, at, '\n') orelse msg.len;
        if (!raw) try w.writeAll("    ");
        try w.writeAll(msg[at..end]);
        try w.writeByte('\n');
        at = end + 1;
    }
}

// ---------------------------------------------------------------------------
// Merging: git's `notes-merge.c`.

/// How a note changed on both sides is resolved.
pub const Strategy = enum {
    /// Leave it for a person: written to `NOTES_MERGE_WORKTREE`, with
    /// conflict markers when both sides changed it.
    manual,
    /// Keep the local note.
    ours,
    /// Take the remote note.
    theirs,
    /// Both, concatenated.
    @"union",
    /// Every line of both, sorted, each once.
    cat_sort_uniq,

    /// The strategy a `notes.mergeStrategy` value names, or `null`.
    pub fn parse(text: []const u8) ?Strategy {
        inline for (@typeInfo(Strategy).@"enum".field_names) |name| {
            if (std.mem.eql(u8, text, name)) return @field(Strategy, name);
        }
        return null;
    }
};

/// How `merge` merges.
pub const MergeOptions = struct {
    /// The local notes ref; `null` is `defaultRef`.
    ref: ?[]const u8 = null,
    who: object.Signature,
    /// `-s`; `null` reads `notes.<name>.mergeStrategy`, then
    /// `notes.mergeStrategy`, then `manual`.
    strategy: ?Strategy = null,
};

/// What a merge did.
pub const MergeOutcome = struct {
    pub const Error = ErrorNamespace.Error;

    /// The commit the local ref now names: the merge, a fast-forward, or
    /// the local commit when there was nothing to do. With conflicts, the
    /// partial merge `NOTES_MERGE_PARTIAL` names.
    result: Oid,
    /// The objects whose notes conflicted, in order; empty when the merge
    /// finished. Owned by the outcome.
    conflicts: []Oid,
    gpa: Allocator,

    pub fn deinit(m: *MergeOutcome) void {
        m.gpa.free(m.conflicts);
        m.* = undefined;
    }
};

/// The directory a manual merge leaves the conflicting notes in.
pub const merge_worktree = "NOTES_MERGE_WORKTREE";

const Pair = struct {
    obj: Oid,
    base: Oid,
    local: Oid,
    remote: Oid,
};

fn uninitialized(kind: hash.Kind) Oid {
    var o = Oid.zero(kind);
    @memset(o.bytes[0..kind.rawLen()], 0xff);
    return o;
}

/// `path_to_oid`: a notes path with its slashes taken out, if it is an
/// object's name.
fn pathToOid(kind: hash.Kind, path: []const u8) ?Oid {
    var hex: [hash.max_hex_len]u8 = undefined;
    var i: usize = 0;
    for (path) |c| {
        if (c == '/') continue;
        if (i == kind.hexLen()) return null;
        hex[i] = c;
        i += 1;
    }
    if (i != kind.hexLen()) return null;
    return Oid.parse(kind, hex[0..i]) catch null;
}

/// `find_notes_merge_pair_pos` over a list kept in object order.
fn pairPosition(pairs: []const Pair, obj: Oid) struct { index: usize, occupied: bool } {
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (obj.order(pairs[mid].obj)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return .{ .index = mid, .occupied = true },
        }
    }
    return .{ .index = lo, .occupied = false };
}

/// `git notes merge <remote>`: merge the remote notes ref into the local
/// one, moving the local ref unless there are conflicts.
pub fn merge(gpa: Allocator, io: Io, repo: *Repository, remote_in: []const u8, options: MergeOptions) Self.Error!MergeOutcome {
    const local_ref = try refFor(gpa, repo, options.ref);
    defer gpa.free(local_ref);
    // `expand_loose_notes_ref`: a name that resolves stays as it is.
    const remote_ref = if (revparse.resolve(gpa, io, repo, remote_in)) |_| try gpa.dupe(u8, remote_in) else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try expandRef(gpa, remote_in),
    };
    defer gpa.free(remote_ref);

    const strategy = options.strategy orelse configured: {
        const key = try gpa.print("notes.{s}.mergestrategy", .{local_ref["refs/notes/".len..]});
        defer gpa.free(key);
        for ([_][]const u8{ key, "notes.mergestrategy" }) |k| {
            if (repo.configuration().get(k)) |raw| break :configured Strategy.parse(raw) orelse return error.InvalidStrategy;
        }
        break :configured Strategy.manual;
    };

    const log = try gpa.print("notes: Merged notes from {s} into {s}", .{ remote_ref, local_ref });
    defer gpa.free(log);
    var commit_msg: std.ArrayList(u8) = .empty;
    defer commit_msg.deinit(gpa);
    try commit_msg.appendSlice(gpa, log["notes: ".len..]);

    var t = try Notes.open(gpa, io, repo, local_ref, .concatenate);
    defer t.deinit();

    const local = try repo.refStore().readOid(gpa, io, local_ref);
    const remote: ?Oid = revparse.resolve(gpa, io, repo, remote_ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            if (!ref_names.checkFormat(remote_ref, .{})) return error.BadRemoteRef;
            break :blk null;
        },
    };

    var conflicts: std.ArrayList(Oid) = .empty;
    errdefer conflicts.deinit(gpa);
    var result: Oid = undefined;
    if (local == null and remote == null) return error.BothRefsEmpty;
    if (local == null) {
        result = remote.?;
    } else if (remote == null) {
        result = local.?;
    } else {
        const bases = try revwalk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = local.?, .b = remote.? }, .{});
        defer gpa.free(bases);
        const base: ?Oid = if (bases.len == 0) null else bases[0];
        if (base != null and remote.?.eql(base.?)) {
            result = local.?;
        } else if (base != null and local.?.eql(base.?)) {
            result = remote.?;
        } else {
            const base_tree: ?Oid = if (base) |b| try repo.commitTree(io, b) else null;
            try mergeFromDiffs(gpa, io, repo, &t, strategy, base_tree, try repo.commitTree(io, local.?), try repo.commitTree(io, remote.?), local_ref, remote_ref, &commit_msg, &conflicts);
            result = try t.commitWith(io, &.{ local.?, remote.? }, commit_msg.items, options.who);
        }
    }
    if (conflicts.items.len == 0) {
        try updateRef(io, repo, local_ref, result, .any, log, options.who);
    } else {
        try updateRef(io, repo, ref_names.Root.notes_merge_partial.name(), result, .any, log, options.who);
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.change(ref_names.Root.notes_merge_ref.name(), .{ .symbolic = local_ref }, .any, .{ .no_deref = true });
        try tx.commit(io, null);
    }
    return .{ .result = result, .conflicts = try conflicts.toOwnedSlice(gpa), .gpa = gpa };
}

fn mergeFromDiffs(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    t: *Notes,
    strategy: Strategy,
    base: ?Oid,
    local: Oid,
    remote: Oid,
    local_ref: []const u8,
    remote_ref: []const u8,
    commit_msg: *std.ArrayList(u8),
    conflicts: *std.ArrayList(Oid),
) Error!void {
    const kind = repo.objectFormat();
    const unset = uninitialized(kind);
    const zero = Oid.zero(kind);
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);

    // `diff_tree_remote`.
    {
        var changes = try diff.tree(gpa, io, repo.objectDatabase(), .{ .old = base, .new = remote }, .{});
        defer changes.deinit();
        for (changes.items) |c| {
            if (c.status != .added and c.status != .deleted and c.status != .modified) continue;
            const obj = pathToOid(kind, c.path()) orelse continue;
            const one = if (c.old) |e| e.oid else zero;
            const two = if (c.new) |e| e.oid else zero;
            const pos = pairPosition(pairs.items, obj);
            if (pos.occupied) {
                const mp = &pairs.items[pos.index];
                if (one.isZero()) mp.remote = two else if (two.isZero()) mp.base = one;
            } else {
                try pairs.insert(gpa, pos.index, .{ .obj = obj, .base = one, .local = unset, .remote = two });
            }
        }
    }
    // `diff_tree_local`.
    {
        var changes = try diff.tree(gpa, io, repo.objectDatabase(), .{ .old = base, .new = local }, .{});
        defer changes.deinit();
        for (changes.items) |c| {
            if (c.status != .added and c.status != .deleted and c.status != .modified) continue;
            const obj = pathToOid(kind, c.path()) orelse continue;
            const pos = pairPosition(pairs.items, obj);
            if (!pos.occupied) continue;
            const mp = &pairs.items[pos.index];
            const one = if (c.old) |e| e.oid else zero;
            const two = if (c.new) |e| e.oid else zero;
            if (two.isZero()) {
                if (mp.local.eql(unset)) mp.local = zero;
            } else if (one.isZero()) {
                mp.local = two;
            } else {
                mp.local = two;
            }
        }
    }
    // `merge_changes`.
    var has_worktree = false;
    for (pairs.items) |p| {
        if (p.base.eql(p.remote)) continue;
        if (p.local.eql(p.remote)) continue;
        if (p.local.eql(unset) or p.local.eql(p.base)) {
            try t.add(io, p.obj, p.remote, .overwrite);
            continue;
        }
        switch (strategy) {
            .ours => {},
            .theirs => try t.add(io, p.obj, p.remote, .overwrite),
            .@"union" => try t.add(io, p.obj, p.remote, .concatenate),
            .cat_sort_uniq => try t.add(io, p.obj, p.remote, .cat_sort_uniq),
            .manual => {
                if (!has_worktree) {
                    try commit_msg.appendSlice(gpa, "\n\nConflicts:\n");
                    try checkMergeWorktree(io, repo);
                    has_worktree = true;
                }
                try commit_msg.print(gpa, "\t{f}\n", .{p.obj});
                try writeConflict(gpa, io, repo, p, local_ref, remote_ref);
                _ = try t.remove(io, p.obj);
                try conflicts.append(gpa, p.obj);
            },
        }
    }
}

/// `check_notes_merge_worktree`: a merge already under way holds files in
/// the directory.
fn checkMergeWorktree(io: Io, repo: *Repository) Error!void {
    var dir = repo.gitDirectory().openDir(io, merge_worktree, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try repo.gitDirectory().createDirPath(io, merge_worktree);
            return;
        },
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    if (try it.next(io) != null) return error.MergeInProgress;
}

/// `merge_one_change_manual`'s file: the surviving side of a deletion, or
/// the three-way merge of the notes with conflict markers.
fn writeConflict(gpa: Allocator, io: Io, repo: *Repository, p: Pair, local_ref: []const u8, remote_ref: []const u8) Error!void {
    var name_buf: [hash.max_hex_len]u8 = undefined;
    const name = p.obj.hex(&name_buf);
    var dir = try repo.gitDirectory().openDir(io, merge_worktree, .{});
    defer dir.close(io);
    var bytes: []const u8 = undefined;
    var owned: ?[]u8 = null;
    defer if (owned) |b| gpa.free(b);
    var held: [3]?[]u8 = .{ null, null, null };
    defer for (held) |h| if (h) |b| repo.objectDatabase().allocator().free(b);
    const read = struct {
        fn f(i: Io, r: *Repository, oid: Oid, slot: *?[]u8) Error![]const u8 {
            if (oid.isZero()) return "";
            const found = try r.objectDatabase().read(i, oid);
            slot.* = found.bytes;
            if (found.type != .blob) return error.NotABlob;
            return found.bytes;
        }
    }.f;
    if (p.local.isZero()) {
        bytes = try read(io, repo, p.remote, &held[0]);
    } else if (p.remote.isZero()) {
        bytes = try read(io, repo, p.local, &held[0]);
    } else {
        const base = try read(io, repo, p.base, &held[0]);
        const ours = try read(io, repo, p.local, &held[1]);
        const theirs = try read(io, repo, p.remote, &held[2]);
        const style = if (repo.configuration().get("merge.conflictstyle")) |s| blobmerge.parseConflictStyle(s) orelse .merge else .merge;
        if (blobmerge.blobs(gpa, base, ours, theirs, .{
            .conflict_style = style,
            .labels = .{ .ours = local_ref, .theirs = remote_ref, .base = "" },
        })) |result_value| {
            owned = result_value.bytes;
            bytes = result_value.bytes;
        } else |err| switch (err) {
            // git keeps ours for a binary note, with a warning.
            error.BinaryBlob => bytes = ours,
            else => |e| return e,
        }
    }
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = file.writer(io, &wbuf);
    w.interface.writeAll(bytes) catch return w.err.?;
    w.interface.flush() catch return w.err.?;
}

/// `git notes merge --commit`: the notes resolved in
/// `NOTES_MERGE_WORKTREE` added to the partial merge, committed with its
/// message and parents, and the local ref moved to it; then the merge's
/// state removed. Returns the commit.
pub fn mergeCommit(gpa: Allocator, io: Io, repo: *Repository, who: object.Signature) Self.Error!Oid {
    const kind = repo.objectFormat();
    const partial = (try repo.refStore().root().read(gpa, io, .notes_merge_partial)) orelse return error.NoMergeInProgress;
    const found = try repo.objectDatabase().read(io, partial);
    defer repo.objectDatabase().allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    var commit = try object.Commit.parse(gpa, kind, found.bytes);
    defer commit.deinit();
    const parent: ?Oid = if (commit.parents.len != 0) commit.parents[0] else null;

    const local_ref = blk: {
        const target = (try repo.refStore().read(gpa, io, ref_names.Root.notes_merge_ref.name())) orelse return error.NoMergeInProgress;
        switch (target) {
            .symbolic => |name| break :blk name,
            .direct => return error.NoMergeInProgress,
        }
    };
    defer gpa.free(local_ref);

    var t = try Notes.open(gpa, io, repo, ref_names.Root.notes_merge_partial.name(), .overwrite);
    defer t.deinit();
    var dir = repo.gitDirectory().openDir(io, merge_worktree, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NoMergeInProgress,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const obj = Oid.parse(kind, e.name) catch continue;
        const bytes = try dir.readFileAlloc(io, e.name, gpa, .unlimited);
        defer gpa.free(bytes);
        const blob = try repo.objectDatabase().write(io, .blob, bytes);
        try t.add(io, obj, blob, null);
    }
    if (commit.message.len == 0) return error.MalformedObject;
    const result = try t.commitWith(io, commit.parents, commit.message, who);

    const subject = try message.onelineSubject(gpa, commit.message);
    defer gpa.free(subject);
    const log = try std.mem.concat(gpa, u8, &.{ "notes: ", std.mem.trim(u8, subject, " \t\n\r") });
    defer gpa.free(log);
    try updateRef(io, repo, local_ref, result, if (parent) |p| .{ .matches = p } else .any, log, who);
    try mergeAbort(io, repo);
    return result;
}

/// `git notes merge --abort`: `NOTES_MERGE_PARTIAL` and `NOTES_MERGE_REF`
/// removed, and the files in `NOTES_MERGE_WORKTREE`; the directory itself
/// stays, as git leaves it.
pub fn mergeAbort(io: Io, repo: *Repository) Self.Error!void {
    try repo.refStore().root().delete(repo.allocator(), io, .notes_merge_partial);
    try repo.refStore().root().delete(repo.allocator(), io, .notes_merge_ref);
    var dir = repo.gitDirectory().openDir(io, merge_worktree, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| repo.allocator().free(n);
        names.deinit(repo.allocator());
    }
    while (try it.next(io)) |e| try names.append(repo.allocator(), try repo.allocator().dupe(u8, e.name));
    for (names.items) |n| try dir.deleteTree(io, n);
}

const testgit = @import("../testing/git.zig");
const ref_names = @import("../names.zig").ref;

const fixture_when: i64 = 1_700_000_000;
const fixture_who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = fixture_when, .offset_minutes = 0 };

/// Two repositories made the same way at the same date: git works in one
/// and this in the other, and what each leaves is compared.
const Twin = struct {
    env: std.process.Environ.Map,
    git: testgit.Repo,
    ours: testgit.Repo,

    fn init(gpa: Allocator, io: Io, t: *Twin, format: testgit.RefFormat, objects: usize) !void {
        t.env = try testgit.datedEnv(gpa, fixture_when);
        errdefer t.env.deinit();
        t.git = try testgit.Repo.init(gpa, io, format.initArgs());
        errdefer t.git.deinit();
        t.ours = try testgit.Repo.init(gpa, io, format.initArgs());
        errdefer t.ours.deinit();
        t.git.environ = &t.env;
        t.ours.environ = &t.env;
        for ([_]*testgit.Repo{ &t.git, &t.ours }) |r| {
            try r.writeFile(io, "a", "a\n");
            try r.exec(io, &.{ "add", "a" });
            try r.exec(io, &.{ "commit", "-q", "-m", "one" });
            try r.writeFile(io, "a", "b\n");
            try r.exec(io, &.{ "commit", "-q", "-am", "two" });
            var input: std.ArrayList(u8) = .empty;
            defer input.deinit(gpa);
            for (0..objects) |i| try input.print(gpa, "object {d}\n", .{i});
            try r.writeFile(io, "objects.txt", input.items);
            var i: usize = 0;
            var lines = std.mem.splitScalar(u8, input.items, '\n');
            while (lines.next()) |line| : (i += 1) {
                if (line.len == 0) continue;
                const name = try gpa.print("o{d}", .{i});
                defer gpa.free(name);
                try r.writeFile(io, name, line);
            }
        }
    }

    fn deinit(t: *Twin) void {
        t.ours.deinit();
        t.git.deinit();
        t.env.deinit();
        t.* = undefined;
    }

    fn blob(t: *Twin, io: Io, i: usize) !Oid {
        const name = try t.git.gpa.print("o{d}", .{i});
        defer t.git.gpa.free(name);
        const hex = try t.git.line(io, &.{ "hash-object", "-w", name });
        defer t.git.gpa.free(hex);
        const again = try t.ours.line(io, &.{ "hash-object", "-w", name });
        t.ours.gpa.free(again);
        return Oid.parse(.sha1, hex);
    }

    fn expectSame(t: *Twin, io: Io, args: []const []const u8) !void {
        const a = try gitOrFailed(io, &t.git, args);
        defer t.git.gpa.free(a);
        const b = try gitOrFailed(io, &t.ours, args);
        defer t.ours.gpa.free(b);
        std.testing.expectEqualStrings(a, b) catch |err| {
            std.log.err("git {any} differs", .{args});
            return err;
        };
    }

    fn expectSameState(t: *Twin, io: Io, refs: []const []const u8) !void {
        for (refs) |ref| {
            try t.expectSame(io, &.{ "rev-parse", "--verify", "-q", ref });
            try t.expectSame(io, &.{ "ls-tree", "-r", "-t", ref });
            try t.expectSame(io, &.{ "reflog", "show", "--format=%H %gs", ref });
        }
        try t.expectSame(io, &.{ "notes", "list" });
    }
};

fn gitOrFailed(io: Io, r: *testgit.Repo, args: []const []const u8) ![]u8 {
    r.report_failures = false;
    defer r.report_failures = true;
    return r.run(io, args) catch |err| switch (err) {
        error.GitFailed => r.gpa.dupe(u8, "<failed>"),
        else => |e| e,
    };
}

fn hexOf(oid: Oid, buf: *[hash.max_hex_len]u8) []const u8 {
    return oid.hex(buf);
}

test "notes added, appended, copied and removed are git's commits, trees and logs, fanout included" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            // `--separator` is git 2.42's.
            try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 42);
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var t: Twin = undefined;
            try Twin.init(gpa, io, &t, format, 140);
            defer t.deinit();
            var repo = try Repository.open(gpa, io, t.ours.dir, .{});
            defer repo.deinit(io);

            var objects: [140]Oid = undefined;
            for (&objects, 0..) |*o, i| o.* = try t.blob(io, i);
            try repo.objectDatabase().refresh(io);

            var hex: [hash.max_hex_len]u8 = undefined;
            var hex2: [hash.max_hex_len]u8 = undefined;
            // Enough notes that the tree fans out.
            for (objects, 0..) |o, i| {
                const msg = try gpa.print("  note {d}  \n\n\n", .{i});
                defer gpa.free(msg);
                try t.git.exec(io, &.{ "notes", "add", "-m", msg, hexOf(o, &hex) });
                _ = try add(gpa, io, &repo, o, .{ .who = fixture_who, .contents = &.{.{ .text = msg }} });
            }
            try t.expectSameState(io, &.{"refs/notes/commits"});

            // Append, with each separator and with -C.
            try t.git.exec(io, &.{ "notes", "append", "-m", "more", hexOf(objects[3], &hex) });
            _ = try append(gpa, io, &repo, objects[3], .{ .who = fixture_who, .contents = &.{.{ .text = "more" }} });
            try t.git.exec(io, &.{ "notes", "append", "--separator=--", "-m", "x", "-m", "y", hexOf(objects[4], &hex) });
            _ = try append(gpa, io, &repo, objects[4], .{ .who = fixture_who, .separator = "--", .contents = &.{ .{ .text = "x" }, .{ .text = "y" } } });
            try t.git.exec(io, &.{ "notes", "append", "--no-separator", "-C", hexOf(objects[9], &hex2), hexOf(objects[5], &hex) });
            _ = try append(gpa, io, &repo, objects[5], .{ .who = fixture_who, .separator = null, .contents = &.{.{ .blob = objects[9] }} });
            try t.git.exec(io, &.{ "notes", "add", "-f", "--allow-empty", "-m", "", hexOf(objects[6], &hex) });
            _ = try add(gpa, io, &repo, objects[6], .{ .who = fixture_who, .force = true, .allow_empty = true, .contents = &.{.{ .text = "" }} });
            try t.git.exec(io, &.{ "notes", "add", "-f", "-m", "  ", hexOf(objects[7], &hex) });
            _ = try add(gpa, io, &repo, objects[7], .{ .who = fixture_who, .force = true, .contents = &.{.{ .text = "  " }} });
            try t.expectSameState(io, &.{"refs/notes/commits"});
            try std.testing.expectError(error.NoteExists, add(gpa, io, &repo, objects[8], .{ .who = fixture_who, .contents = &.{.{ .text = "z" }} }));

            // Copy, onto a note and not.
            try t.git.exec(io, &.{ "notes", "copy", "-f", hexOf(objects[1], &hex2), hexOf(objects[2], &hex) });
            try copy(gpa, io, &repo, .{ .from = objects[1], .to = objects[2], .who = fixture_who, .force = true });
            const commit_hex = try t.git.line(io, &.{ "rev-parse", "HEAD" });
            defer gpa.free(commit_hex);
            try t.git.exec(io, &.{ "notes", "copy", hexOf(objects[1], &hex), "HEAD" });
            try copy(gpa, io, &repo, .{ .from = objects[1], .to = try Oid.parse(.sha1, commit_hex), .who = fixture_who });
            try t.expectSameState(io, &.{"refs/notes/commits"});

            // Remove most of them again, a missing one ignored, so the fanout
            // comes back in.
            var args: std.ArrayList([]const u8) = .empty;
            defer {
                for (args.items[3..]) |a| gpa.free(a);
                args.deinit(gpa);
            }
            try args.appendSlice(gpa, &.{ "notes", "remove", "--ignore-missing" });
            var removing: std.ArrayList(Oid) = .empty;
            defer removing.deinit(gpa);
            for (objects[0..120]) |o| {
                try args.append(gpa, try gpa.dupe(u8, hexOf(o, &hex)));
                try removing.append(gpa, o);
            }
            try t.git.exec(io, args.items);
            _ = try remove(gpa, io, &repo, removing.items, .{ .who = fixture_who, .ignore_missing = true });
            try t.expectSameState(io, &.{"refs/notes/commits"});
            try std.testing.expectError(error.NoteNotFound, remove(gpa, io, &repo, &.{objects[0]}, .{ .who = fixture_who }));

            // Under another ref, and shown as git log shows it.
            try t.git.exec(io, &.{ "notes", "--ref=other", "add", "-m", "line one\nline two", "HEAD" });
            _ = try add(gpa, io, &repo, try Oid.parse(.sha1, commit_hex), .{ .who = fixture_who, .ref = "other", .contents = &.{.{ .text = "line one\nline two" }} });
            try t.expectSameState(io, &.{ "refs/notes/commits", "refs/notes/other" });
            const shown = try t.git.run(io, &.{ "log", "-1", "--notes", "--notes=other", "--format=medium" });
            defer gpa.free(shown);
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            for ([_][]const u8{ "refs/notes/commits", "refs/notes/other" }) |ref| {
                var n = try Notes.open(gpa, io, &repo, ref, .concatenate);
                defer n.deinit();
                try formatNote(io, &n, try Oid.parse(.sha1, commit_hex), &out.writer, .{});
            }
            try std.testing.expect(std.mem.endsWith(u8, shown, out.written()));
        }
    }.inFormat);
}

test "a notes tree's other entries and unread fanout survive an edit as git keeps them" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var t: Twin = undefined;
            try Twin.init(gpa, io, &t, format, 40);
            defer t.deinit();
            var hex: [hash.max_hex_len]u8 = undefined;
            var objects: [40]Oid = undefined;
            for (&objects, 0..) |*o, i| o.* = try t.blob(io, i);
            // A tree git would not write itself: a README beside the notes, one
            // note fanned out by hand and one flat, and a directory that is not a
            // fanout.
            for ([_]*testgit.Repo{ &t.git, &t.ours }) |r| {
                const note = try r.line(io, &.{ "hash-object", "-w", "objects.txt" });
                defer gpa.free(note);
                const h0 = hexOf(objects[0], &hex);
                const sub_listing = try gpa.print("100644 blob {s}\t{s}\n", .{ note, h0[2..] });
                defer gpa.free(sub_listing);
                const sub = try r.runInput(io, &.{"mktree"}, sub_listing);
                defer gpa.free(sub);
                var listing: std.ArrayList(u8) = .empty;
                defer listing.deinit(gpa);
                try listing.print(gpa, "100644 blob {s}\tREADME\n", .{note});
                try listing.print(gpa, "040000 tree {s}\t{s}\n", .{ std.mem.trimEnd(u8, sub, "\n"), h0[0..2] });
                try listing.print(gpa, "100644 blob {s}\t{s}\n", .{ note, hexOf(objects[1], &hex) });
                try listing.print(gpa, "040000 tree {s}\tnotes-dir\n", .{std.mem.trimEnd(u8, sub, "\n")});
                const tree = try r.runInput(io, &.{"mktree"}, listing.items);
                defer gpa.free(tree);
                const commit = try r.line(io, &.{ "commit-tree", "-m", "hand made", std.mem.trimEnd(u8, tree, "\n") });
                defer gpa.free(commit);
                try r.exec(io, &.{ "update-ref", "refs/notes/commits", commit });
            }
            var repo = try Repository.open(gpa, io, t.ours.dir, .{});
            defer repo.deinit(io);
            for (objects[2..], 2..) |o, i| {
                const msg = try gpa.print("n{d}", .{i});
                defer gpa.free(msg);
                try t.git.exec(io, &.{ "notes", "add", "-m", msg, hexOf(o, &hex) });
                _ = try add(gpa, io, &repo, o, .{ .who = fixture_who, .contents = &.{.{ .text = msg }} });
            }
            try t.git.exec(io, &.{ "notes", "remove", hexOf(objects[0], &hex) });
            _ = try remove(gpa, io, &repo, &.{objects[0]}, .{ .who = fixture_who });
            try t.expectSameState(io, &.{"refs/notes/commits"});
        }
    }.inFormat);
}

test "a fanout subtree that cannot be read is a named error, and nothing read before it leaks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.writeFile(io, "note.txt", "a note\n");
    const note = try r.line(io, &.{ "hash-object", "-w", "note.txt" });
    defer gpa.free(note);
    // A fanout directory whose tree is missing, and a flat note under the
    // same two digits, which reading has to look for inside it.
    const listing = try gpa.print("040000 tree {s}\tab\n100644 blob {s}\tab{s}\n", .{ &@as([40]u8, @splat('1')), note, &@as([38]u8, @splat('c')) });
    defer gpa.free(listing);
    const tree = try r.runInput(io, &.{ "mktree", "--missing" }, listing);
    defer gpa.free(tree);
    const commit = try r.line(io, &.{ "commit-tree", "-m", "broken fanout", std.mem.trimEnd(u8, tree, "\n") });
    defer gpa.free(commit);
    try r.exec(io, &.{ "update-ref", "refs/notes/commits", commit });
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    if (Notes.open(gpa, io, &repo, "refs/notes/commits", .concatenate)) |opened| {
        var notes = opened;
        defer notes.deinit();
        try std.testing.expectError(error.ObjectNotFound, notes.get(io, try Oid.parse(.sha1, "ab" ++ @as([38]u8, @splat('c')))));
    } else |err| try std.testing.expectEqual(error.ObjectNotFound, err);
}

test "notes merge under every strategy leaves what git notes merge leaves, and a manual one finishes the same" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const strategies = [_]?Strategy{ .ours, .theirs, .@"union", .cat_sort_uniq, .manual, null };
            for (strategies) |strategy| {
                var t: Twin = undefined;
                try Twin.init(gpa, io, &t, format, 8);
                defer t.deinit();
                var hex: [hash.max_hex_len]u8 = undefined;
                var objects: [8]Oid = undefined;
                for (&objects, 0..) |*o, i| o.* = try t.blob(io, i);
                // The same base, then each side changes, adds and deletes notes.
                for ([_]*testgit.Repo{ &t.git, &t.ours }) |r| {
                    for (objects[0..5], 0..) |o, i| {
                        const msg = try gpa.print("base {d}\nshared", .{i});
                        defer gpa.free(msg);
                        try r.exec(io, &.{ "notes", "add", "-m", msg, hexOf(o, &hex) });
                    }
                    try r.exec(io, &.{ "update-ref", "refs/notes/other", "refs/notes/commits" });
                    try r.exec(io, &.{ "notes", "add", "-f", "-m", "local 0\nshared", hexOf(objects[0], &hex) });
                    try r.exec(io, &.{ "notes", "remove", hexOf(objects[1], &hex) });
                    try r.exec(io, &.{ "notes", "add", "-m", "local new", hexOf(objects[5], &hex) });
                    try r.exec(io, &.{ "notes", "add", "-f", "-m", "same both", hexOf(objects[3], &hex) });
                    try r.exec(io, &.{ "notes", "--ref=other", "add", "-f", "-m", "remote 0\nshared", hexOf(objects[0], &hex) });
                    try r.exec(io, &.{ "notes", "--ref=other", "add", "-f", "-m", "remote 1", hexOf(objects[1], &hex) });
                    try r.exec(io, &.{ "notes", "--ref=other", "remove", hexOf(objects[2], &hex) });
                    try r.exec(io, &.{ "notes", "--ref=other", "add", "-f", "-m", "same both", hexOf(objects[3], &hex) });
                    try r.exec(io, &.{ "notes", "--ref=other", "add", "-m", "remote new", hexOf(objects[6], &hex) });
                    try r.exec(io, &.{ "notes", "--ref=other", "add", "-m", "remote add", hexOf(objects[5], &hex) });
                }
                var repo = try Repository.open(gpa, io, t.ours.dir, .{});
                defer repo.deinit(io);
                var args: std.ArrayList([]const u8) = .empty;
                defer args.deinit(gpa);
                try args.appendSlice(gpa, &.{ "notes", "merge" });
                if (strategy) |s| try args.appendSlice(gpa, &.{ "-s", @tagName(s) });
                try args.append(gpa, "other");
                gpa.free(try gitOrFailed(io, &t.git, args.items));
                var outcome = try merge(gpa, io, &repo, "other", .{ .who = fixture_who, .strategy = strategy });
                defer outcome.deinit();
                try t.expectSameState(io, &.{ "refs/notes/commits", "refs/notes/other" });
                try t.expectSame(io, &.{ "rev-parse", "--verify", "-q", ref_names.Root.notes_merge_partial.name() });
                try t.expectSame(io, &.{ "symbolic-ref", "-q", ref_names.Root.notes_merge_ref.name() });
                for (outcome.conflicts) |o| {
                    const path = try gpa.print(".git/NOTES_MERGE_WORKTREE/{s}", .{hexOf(o, &hex)});
                    defer gpa.free(path);
                    const a = try t.git.readFile(io, path);
                    defer gpa.free(a);
                    const b = try t.ours.readFile(io, path);
                    defer gpa.free(b);
                    try std.testing.expectEqualStrings(a, b);
                    try t.git.writeFile(io, path, "resolved\n");
                    try t.ours.writeFile(io, path, "resolved\n");
                }
                if (outcome.conflicts.len != 0) {
                    try t.git.exec(io, &.{ "notes", "merge", "--commit" });
                    _ = try mergeCommit(gpa, io, &repo, fixture_who);
                    try t.expectSameState(io, &.{ "refs/notes/commits", "refs/notes/other" });
                    try t.expectSame(io, &.{ "rev-parse", "--verify", "-q", ref_names.Root.notes_merge_partial.name() });
                }
            }
        }
    }.inFormat);
}

test "fuzz: any tree reads as notes or a named error, and edits keep exactly the notes a map keeps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.create(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    try std.testing.fuzz(&repo, fuzzNotes, .{});
}

fn fuzzNotes(repo: *Repository, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch: [512]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];

    // The bytes as a tree, read as a notes tree's root.
    {
        var t = try Notes.open(gpa, io, repo, default_ref, .concatenate);
        defer t.deinit();
        const tree = try repo.objectDatabase().write(io, .tree, input);
        var leaf: Leaf = .{ .key = @splat(0), .val = tree };
        if (t.loadSubtree(io, &leaf, t.root, 0)) {
            if (t.list(gpa, io)) |entries| gpa.free(entries) else |_| {}
        } else |_| {}
    }

    // The bytes as edits: two bytes of key prefix and an add or a removal,
    // checked against a map, then written and read back.
    var t = try Notes.open(gpa, io, repo, default_ref, .overwrite);
    defer t.deinit();
    var model: Oid.Map(Oid) = .empty;
    defer model.deinit(gpa);
    const note = try repo.objectDatabase().write(io, .blob, "note\n");
    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 3) {
        var key = Oid.zero(.sha1);
        key.bytes[0] = input[i];
        key.bytes[1] = input[i + 1] & 0xf3;
        key.bytes[19] = input[i + 2] >> 4;
        if (input[i + 2] & 1 == 0) {
            try t.add(io, key, note, null);
            try model.put(gpa, key, note);
        } else {
            _ = try t.remove(io, key);
            _ = model.remove(key);
        }
    }
    const written = try t.writeTree(io);
    var back = try Notes.open(gpa, io, repo, default_ref, .overwrite);
    defer back.deinit();
    var leaf: Leaf = .{ .key = @splat(0), .val = written };
    try back.loadSubtree(io, &leaf, back.root, 0);
    const entries = try back.list(gpa, io);
    defer gpa.free(entries);
    try std.testing.expectEqual(model.count(), entries.len);
    for (entries) |e| try std.testing.expect(model.get(e.object).?.eql(e.note));
}
