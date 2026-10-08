//! History simplified by paths, as git's `try_to_simplify_commit` does it
//! for `git rev-list <revs> -- <paths>` with its default simplification: a
//! commit whose tree is the same as a parent's wherever the paths reach is
//! TREESAME, and a merge the same as one of its parents that matter
//! follows that parent alone.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const pathspec = @import("../patterns/pathspec.zig");

const Oid = hash.Oid;

pub const Error = odb_mod.Error || object.TreeParseError || Allocator.Error || error{
    /// A tree nests deeper than `object.max_tree_depth`.
    TreeTooDeep,
};

/// Whether trees `a` and `b`, `null` for the empty tree, hold the same
/// entries everywhere `paths` names: git's `REV_TREE_SAME` from a tree
/// diff limited to the paths. A changed mode is a change.
pub fn sameWithin(gpa: Allocator, io: Io, db: *odb_mod.Odb, a: ?Oid, b: ?Oid, paths: *const pathspec.Pathspec) Self.Error!bool {
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(gpa);
    return sameUnder(gpa, io, db, a, b, paths, &prefix, 0);
}

fn readTree(gpa: Allocator, io: Io, db: *odb_mod.Odb, oid: ?Oid) Error!?[]const u8 {
    const id = oid orelse return null;
    const found = try db.read(io, id);
    if (found.type != .tree) {
        db.allocator().free(found.bytes);
        return error.UnexpectedObjectType;
    }
    defer db.allocator().free(found.bytes);
    const value = try gpa.dupe(u8, found.bytes);
    return value;
}

/// git's tree order: a subtree sorts as its name with a `/` after it.
fn order(x: object.Tree.Entry, y: object.Tree.Entry) std.math.Order {
    const n = @min(x.name.len, y.name.len);
    switch (std.mem.order(u8, x.name[0..n], y.name[0..n])) {
        .eq => {},
        else => |o| return o,
    }
    const cx: u8 = if (x.name.len > n) x.name[n] else if (x.mode.isTree()) '/' else 0;
    const cy: u8 = if (y.name.len > n) y.name[n] else if (y.mode.isTree()) '/' else 0;
    return std.math.order(cx, cy);
}

fn sameUnder(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    a_oid: ?Oid,
    b_oid: ?Oid,
    paths: *const pathspec.Pathspec,
    prefix: *std.ArrayList(u8),
    depth: u32,
) Error!bool {
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    const kind = db.objectFormat();
    const a_bytes = try readTree(gpa, io, db, a_oid);
    defer if (a_bytes) |bytes| gpa.free(bytes);
    const b_bytes = try readTree(gpa, io, db, b_oid);
    defer if (b_bytes) |bytes| gpa.free(bytes);
    var ai = object.Tree.parse(kind, a_bytes orelse "").iterate();
    var bi = object.Tree.parse(kind, b_bytes orelse "").iterate();
    var a_next = try ai.next();
    var b_next = try bi.next();
    const base = prefix.items.len;
    defer prefix.shrinkRetainingCapacity(base);
    while (a_next != null or b_next != null) {
        const which: std.math.Order = if (a_next == null) .gt else if (b_next == null) .lt else order(a_next.?, b_next.?);
        const entry = if (which == .gt) b_next.? else a_next.?;
        prefix.shrinkRetainingCapacity(base);
        try prefix.appendSlice(gpa, entry.name);
        const path = prefix.items;
        if (which == .eq) {
            const other = b_next.?;
            const changed = !entry.oid.eql(other.oid) or entry.mode != other.mode;
            if (changed) {
                if (entry.mode.isTree()) {
                    if (paths.couldMatchUnder(path)) {
                        try prefix.append(gpa, '/');
                        if (!try sameUnder(gpa, io, db, entry.oid, other.oid, paths, prefix, depth + 1)) return false;
                    }
                } else if (paths.matches(path)) return false;
            }
            a_next = try ai.next();
            b_next = try bi.next();
            continue;
        }
        // On one side only: added or removed whole.
        if (entry.mode.isTree()) {
            if (paths.couldMatchUnder(path)) {
                try prefix.append(gpa, '/');
                const only_a: ?Oid = if (which == .lt) entry.oid else null;
                const only_b: ?Oid = if (which == .gt) entry.oid else null;
                if (!try sameUnder(gpa, io, db, only_a, only_b, paths, prefix, depth + 1)) return false;
            }
        } else if (paths.matches(path)) return false;
        if (which == .lt) a_next = try ai.next() else b_next = try bi.next();
    }
    return true;
}
