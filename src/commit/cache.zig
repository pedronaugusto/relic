//! Commits read once per repository handle: each one's tree and parents,
//! kept after the first read, as git keeps a parsed commit in its object
//! store. `main~40` then costs forty lookups and not forty inflates, and
//! a second expression walking the same commits reads none of them.
//!
//! An object never changes once written, so nothing here is ever stale and
//! nothing is checked. What the cache answers is the commit object as
//! written: grafts and the shallow boundary are for the walks to apply.
//! It holds at most `capacity` commits and starts over when full, so a
//! handle kept for days holds a bounded amount however much it walks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");

const Oid = hash.Oid;

/// A commit's tree and parents.
pub const Info = struct {
    tree: Oid,
    /// In the object's order; the caller's, from the allocator it gave.
    parents: []const Oid,
};

/// Errors from reading a commit through the cache.
pub const Error = odb_mod.Error || object.ParseError || error{
    /// The object is not a commit.
    UnexpectedObjectType,
};

pub const Cache = struct {
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator.State = .{},
    map: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, Entry) = .empty,

    /// How many commits are held before the cache starts over: a few
    /// hundred kilobytes to a megabyte.
    pub const capacity = 1 << 13;

    const Entry = struct { tree: Oid, parents: []const Oid };

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.map.deinit(gpa);
        var arena = c.arena.promote(gpa);
        arena.deinit();
        c.* = undefined;
    }

    /// `oid`'s tree and parents, the parents copied with `out`. With no
    /// `out` the parents come back empty, for a caller that wants the tree.
    pub fn get(c: *Cache, gpa: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid, out: ?Allocator) Error!Info {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const entry = c.map.get(oid.bytes) orelse try c.load(gpa, io, db, oid);
        return .{
            .tree = entry.tree,
            .parents = if (out) |a| try a.dupe(Oid, entry.parents) else &.{},
        };
    }

    fn load(c: *Cache, gpa: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid) Error!Entry {
        const found = try db.read(io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        var commit = try object.Commit.parse(gpa, db.objectFormat(), found.bytes);
        defer commit.deinit();
        if (c.map.count() >= capacity) {
            c.map.clearRetainingCapacity();
            var arena = c.arena.promote(gpa);
            _ = arena.reset(.retain_capacity);
            c.arena = arena.state;
        }
        var arena = c.arena.promote(gpa);
        defer c.arena = arena.state;
        const entry: Entry = .{ .tree = commit.tree, .parents = try arena.allocator().dupe(Oid, commit.parents) };
        try c.map.put(gpa, oid.bytes, entry);
        return entry;
    }
};
