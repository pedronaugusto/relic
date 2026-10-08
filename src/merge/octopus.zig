//! An octopus: several heads merged at once, as git's `merge-octopus`
//! merges them.
//!
//! The heads are taken one at a time, each against the result so far. A
//! head the result already holds is passed over; the first head, when it is
//! a fast-forward, is taken whole; every other is merged by `read-tree -m
//! --aggressive` against its merge bases with everything merged so far, and
//! what that leaves unmerged goes path by path through `merge-one-file`.
//! No renames are followed, and the file merges are `git merge-file`'s:
//! Myers, at its level, labelled with the names of `merge-one-file`'s
//! temporary files. Only the last head may leave conflicts for a person to
//! resolve; a conflict before it is the whole octopus failing, and git
//! then leaves everything as it was.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const revwalk = @import("../walk/walk.zig");
const worktree = @import("../checkout/checkout.zig");
const blobmerge = @import("blobmerge.zig");
const ort = @import("ort.zig");

const Oid = hash.Oid;
const Odb = odb_mod.Odb;
const Entry = worktree.TreeEntry;
const Map = std.StringHashMapUnmanaged(Entry);

/// Errors from an octopus.
pub const Error = error{
    /// The octopus gave up, as git's does with `Merge with strategy octopus
    /// failed`: a head before the last left a conflict, a head shares no
    /// history with what was merged before it, or a step would leave a file
    /// where a directory is.
    OctopusFailed,
    /// A head names something that is not a commit.
    NotACommit,
} || object.ParseError || worktree.Error || revwalk.Error || blobmerge.BlobError || odb_mod.Error;

/// How the file merges are made.
pub const Options = struct {
    /// `merge.conflictStyle`, which `git merge-file` reads.
    conflict_style: blobmerge.ConflictStyle = .merge,
};

/// What an octopus left.
pub const Result = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// The merged tree, when nothing is left conflicted.
    tree: ?Oid,
    /// What the working tree holds afterwards: the merged tree, with a
    /// conflicted file's merge, markers and all, or our side of it where
    /// `merge-one-file` merged nothing.
    worktree_tree: Oid,
    /// The paths left unmerged by the last head, sorted, with their stages.
    conflicted: []const ort.Conflicted,

    /// Release the result.
    pub fn deinit(r: *Result) void {
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

/// Merge `heads`, in order, into the commit `head`, as `git merge-octopus`
/// does: the heads are those `git merge` keeps once it has dropped every
/// one another reaches.
pub fn commits(gpa: Allocator, io: Io, db: *Odb, head: Oid, heads: []const Oid, options: Options) Self.Error!Result {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var o: Octopus = .{ .gpa = gpa, .arena = arena, .io = io, .db = db, .options = options };

    // MRC, the commits merged so far, and MRT, the tree they merged to.
    var merged_commits: std.ArrayList(Oid) = .empty;
    try merged_commits.append(arena, head);
    var current = try worktree.flatten(arena, io, db, try commitTree(o, head));
    var fast_forward_only = true;
    var last: ?Step = null;
    for (heads) |one| {
        if (last) |step| {
            // Only the last head may leave a conflict.
            if (step.failed) return error.OctopusFailed;
        }
        const common = try revwalk.mergeBasesMany(gpa, io, db, one, merged_commits.items, .{});
        defer gpa.free(common);
        if (common.len == 0) return error.OctopusFailed;
        if (contains(common, one)) continue;
        if (fast_forward_only and common.len == 1 and merged_commits.items.len == 1 and common[0].eql(merged_commits.items[0])) {
            // The first head merged is a fast-forward: its tree is the
            // result so far, and it is still a parent.
            current = try worktree.flatten(arena, io, db, try commitTree(o, one));
            merged_commits.items[0] = one;
            continue;
        }
        fast_forward_only = false;
        const bases = try arena.alloc(Map, common.len);
        for (common, bases) |base, *map| map.* = try worktree.flatten(arena, io, db, try commitTree(o, base));
        const theirs = try worktree.flatten(arena, io, db, try commitTree(o, one));
        const step = try o.step(bases, &current, &theirs);
        current = step.merged;
        last = step;
        try merged_commits.append(arena, one);
    }

    const step = last orelse Step{ .merged = current };
    var view = try step.merged.clone(arena);
    for (step.unmerged.items) |u| {
        if (u.worktree) |e| try view.put(arena, u.path, e);
    }
    try requireNoFileOverDirectory(arena, &view, step.unmerged.items);
    const worktree_tree = try o.writeTree(&view);
    const conflicted = try arena.alloc(ort.Conflicted, step.unmerged.items.len);
    for (step.unmerged.items, conflicted) |u, *c| {
        c.path = u.path;
        for (u.stages, &c.stages) |s, *out| out.* = if (s) |e| .{ .mode = e.mode.raw(), .oid = e.oid } else null;
    }
    std.mem.sort(ort.Conflicted, conflicted, {}, struct {
        fn lessThan(_: void, a: ort.Conflicted, b: ort.Conflicted) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .tree = if (conflicted.len == 0) worktree_tree else null,
        .worktree_tree = worktree_tree,
        .conflicted = conflicted,
    };
}

/// A path one head left unmerged.
const Unmerged = struct {
    path: []const u8,
    /// The first base that has the path, ours and theirs.
    stages: [3]?Entry,
    /// What the working tree has at the path.
    worktree: ?Entry,
};

/// What merging one head did.
const Step = struct {
    merged: Map,
    unmerged: std.ArrayList(Unmerged) = .empty,
    /// Some path was not resolved: the octopus fails if a head follows.
    failed: bool = false,
};

const Octopus = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    db: *Odb,
    options: Options,

    /// `read-tree -m --aggressive <bases> MRT <head>`, then `merge-index -o
    /// git-merge-one-file -a` over what is left unmerged.
    fn step(o: *Octopus, bases: []const Map, ours: *const Map, theirs: *const Map) Error!Step {
        var paths: std.array_hash_map.String(void) = .empty;
        for (bases) |*base| {
            var it = base.keyIterator();
            while (it.next()) |p| try paths.put(o.arena, p.*, {});
        }
        for ([_]*const Map{ ours, theirs }) |side| {
            var it = side.keyIterator();
            while (it.next()) |p| try paths.put(o.arena, p.*, {});
        }
        var out: Step = .{ .merged = .empty };
        const ancestors = try o.arena.alloc(?Entry, bases.len);
        for (paths.keys()) |path| {
            for (bases, ancestors) |*base, *a| a.* = base.get(path);
            const head = ours.get(path);
            const remote = theirs.get(path);
            switch (threewayMerge(ancestors, head, remote)) {
                .take => |e| try out.merged.put(o.arena, path, e),
                .remove => {},
                .unmerged => |stages| try o.mergeOneFile(&out, path, stages),
            }
        }
        return out;
    }

    /// `git-merge-one-file` for one path `read-tree` left unmerged.
    fn mergeOneFile(o: *Octopus, out: *Step, path: []const u8, stages: [3]?Entry) Error!void {
        const base, const ours, const theirs = stages;
        const keep: Unmerged = .{ .path = path, .stages = stages, .worktree = ours };
        if (base) |b| {
            const gone_ours = ours == null and (theirs == null or theirs.?.oid.eql(b.oid));
            const gone_theirs = theirs == null and ours != null and ours.?.oid.eql(b.oid);
            if (gone_ours or gone_theirs) {
                // Deleted in both, or deleted in one and unchanged in the
                // other -- unless the other changed its mode.
                if ((ours == null and !sameMode(b, theirs)) or (theirs == null and !sameMode(b, ours))) {
                    return o.fail(out, keep);
                }
                return;
            }
        } else if (ours != null and theirs == null) {
            return out.merged.put(o.arena, path, ours.?);
        } else if (ours == null and theirs != null) {
            return out.merged.put(o.arena, path, theirs.?);
        } else if (ours != null and theirs != null and ours.?.oid.eql(theirs.?.oid)) {
            // Added in both, identically.
            if (ours.?.mode != theirs.?.mode) return o.fail(out, keep);
            return out.merged.put(o.arena, path, ours.?);
        }
        // Changed in both, differently.
        const our = ours orelse return o.fail(out, keep);
        const their = theirs orelse return o.fail(out, keep);
        for ([_]object.Mode{ our.mode, their.mode }) |mode| {
            if (mode == .symlink or mode == .gitlink) return o.fail(out, keep);
        }
        const ancestor_text = if (base) |b| try o.readBlob(b.oid) else "";
        const our_text = try o.readBlob(our.oid);
        const their_text = try o.readBlob(their.oid);
        var clean = base != null and our.mode == their.mode;
        // `merge-file`'s result, written over our side; a binary file it
        // refuses stays ours.
        var merged_oid = our.oid;
        if (blobmerge.blobs(o.gpa, ancestor_text, our_text, their_text, .{
            .conflict_style = o.options.conflict_style,
            .labels = .{ .ours = try o.tempName(), .base = try o.tempName(), .theirs = try o.tempName() },
            .level = .zealous_alnum,
        })) |result| {
            var r = result;
            defer r.deinit();
            if (!r.isClean()) clean = false;
            merged_oid = try o.db.write(o.io, .blob, r.bytes);
        } else |err| switch (err) {
            error.BinaryBlob => clean = false,
            else => |e| return e,
        }
        const written: Entry = .{ .mode = our.mode, .oid = merged_oid };
        if (clean) return out.merged.put(o.arena, path, written);
        out.failed = true;
        try out.unmerged.append(o.arena, .{ .path = path, .stages = stages, .worktree = written });
    }

    fn fail(o: *Octopus, out: *Step, keep: Unmerged) Allocator.Error!void {
        out.failed = true;
        try out.unmerged.append(o.arena, keep);
    }

    fn readBlob(o: *Octopus, oid: Oid) Error![]const u8 {
        const found = try o.db.read(o.io, oid);
        defer o.db.allocator().free(found.bytes);
        return o.arena.dupe(u8, found.bytes);
    }

    /// A name as `git unpack-file` makes one, `mkstemp`'s: `.merge_file_`
    /// and six letters and digits.
    fn tempName(o: *Octopus) Allocator.Error![]const u8 {
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        var raw: [6]u8 = undefined;
        o.io.random(&raw);
        var name: [6]u8 = undefined;
        for (raw, &name) |r, *c| c.* = alphabet[r % alphabet.len];
        return o.arena.print(".merge_file_{s}", .{&name});
    }

    fn writeTree(o: *Octopus, map: *const Map) Error!Oid {
        var index: index_mod.Index = .initEmpty(o.gpa, o.db.objectFormat());
        defer index.deinit();
        var entries: std.ArrayList(index_mod.Entry) = .empty;
        var it = map.iterator();
        while (it.next()) |e| try entries.append(o.arena, .{ .path = e.key_ptr.*, .oid = e.value_ptr.oid, .mode = e.value_ptr.mode });
        try index.addMany(entries.items);
        return worktree.writeTree(o.gpa, o.io, &index, o.db);
    }
};

const Decision = union(enum) {
    take: Entry,
    remove,
    unmerged: [3]?Entry,
};

/// `threeway_merge` of `unpack-trees.c` under `--aggressive`, for an index
/// that is the head's tree.
fn threewayMerge(ancestors: []const ?Entry, head: ?Entry, remote: ?Entry) Decision {
    var any_missing = false;
    var none_exists = true;
    for (ancestors) |a| {
        if (a == null) any_missing = true else none_exists = false;
    }
    // Which ancestor each side still matches: `#16` when both do.
    var head_match: ?usize = null;
    var remote_match: ?usize = null;
    if (!same(remote, head)) {
        for (ancestors, 0..) |a, i| {
            if (same(a, head)) head_match = i;
            if (same(a, remote)) remote_match = i;
        }
    }
    // #14: only theirs changed.
    if (remote != null and head_match != null and remote_match == null) return .{ .take = remote.? };
    if (head) |h| {
        // #5ALT, #15: both the same.
        if (same(head, remote)) return .{ .take = h };
        // #13, #3ALT: only ours changed.
        if (remote_match != null and head_match == null) return .{ .take = h };
    }
    // #1
    if (head == null and remote == null and any_missing) return .remove;
    // Deleted in both, or deleted in one and unchanged in the other.
    if ((head == null and remote == null) or
        (head == null and remote != null and remote_match != null) or
        (remote == null and head != null and head_match != null)) return .remove;
    // Added in both, identically.
    if (none_exists and head != null and remote != null and same(head, remote)) return .{ .take = head.? };
    var stages: [3]?Entry = .{ null, head, remote };
    if (head_match == null or remote_match == null) {
        for (ancestors) |a| if (a) |e| {
            stages[0] = e;
            break;
        };
    }
    return .{ .unmerged = stages };
}

fn same(a: ?Entry, b: ?Entry) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.mode == y.mode and x.oid.eql(y.oid);
}

/// `"$5" != "$7"`: a missing side has no mode, which no mode equals.
fn sameMode(a: Entry, b: ?Entry) bool {
    const other = b orelse return false;
    return a.mode == other.mode;
}

fn contains(list: []const Oid, oid: Oid) bool {
    for (list) |one| if (one.eql(oid)) return true;
    return false;
}

fn commitTree(o: Octopus, commit: Oid) Error!Oid {
    const found = try o.db.read(o.io, commit);
    defer o.db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    var parsed = try object.Commit.parse(o.gpa, o.db.objectFormat(), found.bytes);
    defer parsed.deinit();
    return parsed.tree;
}

/// git's octopus cannot leave a file where its result has a directory.
fn requireNoFileOverDirectory(arena: Allocator, view: *const Map, unmerged: []const Unmerged) Error!void {
    var all: std.StringHashMapUnmanaged(void) = .empty;
    var it = view.keyIterator();
    while (it.next()) |p| try all.put(arena, p.*, {});
    for (unmerged) |u| try all.put(arena, u.path, {});
    var paths = all.keyIterator();
    while (paths.next()) |p| {
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, p.*, at, '/')) |slash| : (at = slash + 1) {
            if (all.contains(p.*[0..slash])) return error.OctopusFailed;
        }
    }
}

test "a path only one side changed is taken without a file merge" {
    const z: Oid = .zero(.sha1);
    var other = z;
    other.bytes[0] = 1;
    const base: Entry = .{ .mode = .file, .oid = z };
    const changed: Entry = .{ .mode = .file, .oid = other };
    try std.testing.expectEqual(changed, threewayMerge(&.{base}, base, changed).take);
    try std.testing.expectEqual(changed, threewayMerge(&.{base}, changed, base).take);
    try std.testing.expect(threewayMerge(&.{base}, null, base) == .remove);
    try std.testing.expect(threewayMerge(&.{null}, null, changed) == .take);
    try std.testing.expect(threewayMerge(&.{}, null, changed) == .unmerged);
}
