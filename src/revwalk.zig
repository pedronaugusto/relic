//! Walking history.
//!
//! Push the commits to start from, hide the ones whose ancestors are not
//! wanted, and take commits out one at a time. Nothing here needs a
//! commit-graph; a caller that has one hands it in and the answers do not
//! change, which is what an accelerator must mean.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");

const Oid = hash.Oid;

/// Errors from a walk.
pub const Error = error{
    /// A commit named an object that is not a commit.
    NotACommit,
    /// The walk went deeper than `max_commits`, which a caller sets to
    /// bound a history it does not trust.
    WalkTooLong,
} || Allocator.Error || odb_mod.Error || object.ParseError;

/// The order commits come out in.
pub const Sort = enum {
    /// Newest committer date first, which is git's default for `rev-list`.
    date,
    /// Parents never before their children, and otherwise by date. What a
    /// caller building a graph needs.
    topological,
};

/// One commit, with what the walk needed from it.
pub const Commit = struct {
    oid: Oid,
    parents: []const Oid,
    /// Committer time in seconds, which is what the date order uses.
    time: i64,
};

/// A history walk.
pub const Walk = struct {
    gpa: Allocator,
    db: *odb_mod.Odb,
    sort: Sort = .date,
    /// Whether to hand the commits back oldest first once the order is
    /// decided.
    reverse: bool = false,
    /// A bound on how many commits will be loaded, so a hostile or
    /// enormous history cannot be walked without the caller asking for it.
    max_commits: usize = 1 << 22,

    roots: std.ArrayList(Oid) = .empty,
    hidden: std.ArrayList(Oid) = .empty,
    /// Filled by `prepare`, consumed by `next`.
    ordered: std.ArrayList(Commit) = .empty,
    position: usize = 0,
    prepared: bool = false,

    /// A walk over `db`.
    pub fn init(gpa: Allocator, db: *odb_mod.Odb) Walk {
        return .{ .gpa = gpa, .db = db };
    }

    /// Release everything.
    pub fn deinit(walk: *Walk) void {
        for (walk.ordered.items) |commit| walk.gpa.free(commit.parents);
        walk.ordered.deinit(walk.gpa);
        walk.roots.deinit(walk.gpa);
        walk.hidden.deinit(walk.gpa);
        walk.* = undefined;
    }

    /// Start from this commit.
    pub fn push(walk: *Walk, oid: Oid) Allocator.Error!void {
        walk.prepared = false;
        try walk.roots.append(walk.gpa, oid);
    }

    /// Leave this commit and everything it reaches out of the walk.
    pub fn hide(walk: *Walk, oid: Oid) Allocator.Error!void {
        walk.prepared = false;
        try walk.hidden.append(walk.gpa, oid);
    }

    /// Load and order the commits. `next` does this itself the first time.
    pub fn prepare(walk: *Walk, io: Io) Error!void {
        if (walk.prepared) return;
        for (walk.ordered.items) |commit| walk.gpa.free(commit.parents);
        walk.ordered.clearRetainingCapacity();
        walk.position = 0;

        var excluded: Oid.Set = .empty;
        defer excluded.deinit(walk.gpa);
        for (walk.hidden.items) |oid| {
            try walk.collectReachable(io, oid, &excluded);
        }

        var loaded: std.AutoArrayHashMapUnmanaged(OidKey, Commit) = .empty;
        defer loaded.deinit(walk.gpa);
        var queue: std.ArrayList(Oid) = .empty;
        defer queue.deinit(walk.gpa);
        for (walk.roots.items) |oid| try queue.append(walk.gpa, oid);

        while (queue.items.len != 0) {
            const oid = queue.orderedRemove(0);
            if (excluded.contains(oid)) continue;
            const key = OidKey.of(oid);
            if (loaded.contains(key)) continue;
            if (loaded.count() >= walk.max_commits) return error.WalkTooLong;
            const commit = try walk.load(io, oid);
            try loaded.put(walk.gpa, key, commit);
            for (commit.parents) |parent| {
                if (!excluded.contains(parent)) try queue.append(walk.gpa, parent);
            }
        }

        try walk.ordered.ensureTotalCapacity(walk.gpa, loaded.count());
        for (loaded.values()) |commit| walk.ordered.appendAssumeCapacity(commit);
        loaded.clearRetainingCapacity();

        switch (walk.sort) {
            .date => std.mem.sort(Commit, walk.ordered.items, {}, newerFirst),
            .topological => try walk.sortTopologically(),
        }
        if (walk.reverse) std.mem.reverse(Commit, walk.ordered.items);
        walk.prepared = true;
    }

    fn load(walk: *Walk, io: Io, oid: Oid) Error!Commit {
        const found = try walk.db.read(io, oid);
        defer walk.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(walk.gpa, walk.db.kind, found.bytes);
        defer commit.deinit();
        return .{
            .oid = oid,
            .parents = try walk.gpa.dupe(Oid, commit.parents),
            .time = commit.committer.when_secs,
        };
    }

    fn collectReachable(walk: *Walk, io: Io, from: Oid, out: *Oid.Set) Error!void {
        var queue: std.ArrayList(Oid) = .empty;
        defer queue.deinit(walk.gpa);
        try queue.append(walk.gpa, from);
        while (queue.items.len != 0) {
            const oid = queue.pop().?;
            if (out.contains(oid)) continue;
            try out.put(walk.gpa, oid, {});
            const commit = walk.load(io, oid) catch continue;
            defer walk.gpa.free(commit.parents);
            for (commit.parents) |parent| try queue.append(walk.gpa, parent);
        }
    }

    fn sortTopologically(walk: *Walk) Error!void {
        // Children first: a commit is emitted only once every commit that
        // names it as a parent already has been. Ties break by date, which
        // is what makes the order stable.
        std.mem.sort(Commit, walk.ordered.items, {}, newerFirst);

        var index: std.AutoHashMapUnmanaged(OidKey, usize) = .empty;
        defer index.deinit(walk.gpa);
        for (walk.ordered.items, 0..) |commit, i| try index.put(walk.gpa, OidKey.of(commit.oid), i);

        const in_degree = try walk.gpa.alloc(usize, walk.ordered.items.len);
        defer walk.gpa.free(in_degree);
        @memset(in_degree, 0);
        for (walk.ordered.items) |commit| {
            for (commit.parents) |parent| {
                if (index.get(OidKey.of(parent))) |at| in_degree[at] += 1;
            }
        }

        var out: std.ArrayList(Commit) = .empty;
        errdefer out.deinit(walk.gpa);
        try out.ensureTotalCapacity(walk.gpa, walk.ordered.items.len);
        var ready: std.ArrayList(usize) = .empty;
        defer ready.deinit(walk.gpa);
        for (in_degree, 0..) |degree, i| {
            if (degree == 0) try ready.append(walk.gpa, i);
        }
        var emitted = try walk.gpa.alloc(bool, walk.ordered.items.len);
        defer walk.gpa.free(emitted);
        @memset(emitted, false);

        while (ready.items.len != 0) {
            // The ready set is kept in date order, so a tie is broken the
            // same way every time.
            std.mem.sort(usize, ready.items, walk.ordered.items, readyNewerFirst);
            const at = ready.orderedRemove(0);
            if (emitted[at]) continue;
            emitted[at] = true;
            out.appendAssumeCapacity(walk.ordered.items[at]);
            for (walk.ordered.items[at].parents) |parent| {
                const parent_at = index.get(OidKey.of(parent)) orelse continue;
                in_degree[parent_at] -= 1;
                if (in_degree[parent_at] == 0) try ready.append(walk.gpa, parent_at);
            }
        }
        // A cycle cannot happen in a well-formed history; if one did, the
        // commits it holds are appended in date order rather than lost.
        for (walk.ordered.items, 0..) |commit, i| {
            if (!emitted[i]) out.appendAssumeCapacity(commit);
        }
        walk.ordered.deinit(walk.gpa);
        walk.ordered = out;
    }

    fn readyNewerFirst(commits: []const Commit, a: usize, b: usize) bool {
        return newerFirst({}, commits[a], commits[b]);
    }

    /// The next commit, or `null` at the end.
    pub fn next(walk: *Walk, io: Io) Error!?Commit {
        try walk.prepare(io);
        if (walk.position >= walk.ordered.items.len) return null;
        const commit = walk.ordered.items[walk.position];
        walk.position += 1;
        return commit;
    }

    /// How many commits the walk covers. Prepares it.
    pub fn count(walk: *Walk, io: Io) Error!usize {
        try walk.prepare(io);
        return walk.ordered.items.len;
    }

    /// Start again from the first commit without reloading anything.
    pub fn reset(walk: *Walk) void {
        walk.position = 0;
    }
};

fn newerFirst(_: void, a: Commit, b: Commit) bool {
    if (a.time != b.time) return a.time > b.time;
    // Object name order breaks a tie, so a run is reproducible.
    return a.oid.order(b.oid) == .lt;
}

/// A hashable object name, for the maps the walk keeps.
const OidKey = struct {
    kind: hash.Kind,
    bytes: [hash.max_raw_len]u8,

    fn of(oid: Oid) OidKey {
        return .{ .kind = oid.kind, .bytes = oid.bytes };
    }
};

/// Every merge base of `a` and `b`: the common ancestors none of whose
/// descendants is also a common ancestor.
///
/// The result is the caller's. An empty result means the two commits share
/// no history, which is what an unrelated-histories merge looks like.
pub fn mergeBases(gpa: Allocator, io: Io, db: *odb_mod.Odb, a: Oid, b: Oid) Error![]Oid {
    var from_a: Oid.Set = .empty;
    defer from_a.deinit(gpa);
    try reachable(gpa, io, db, a, &from_a);

    var common: std.ArrayList(Oid) = .empty;
    defer common.deinit(gpa);
    var from_b: Oid.Set = .empty;
    defer from_b.deinit(gpa);
    try reachable(gpa, io, db, b, &from_b);

    var it = from_b.keyIterator();
    while (it.next()) |oid| {
        if (from_a.contains(oid.*)) try common.append(gpa, oid.*);
    }

    // A common ancestor that another common ancestor can reach is not a
    // merge base: it is behind one.
    var bases: std.ArrayList(Oid) = .empty;
    errdefer bases.deinit(gpa);
    for (common.items) |candidate| {
        var redundant = false;
        for (common.items) |other| {
            if (other.eql(candidate)) continue;
            var from_other: Oid.Set = .empty;
            defer from_other.deinit(gpa);
            try reachableExcluding(gpa, io, db, other, candidate, &from_other);
            if (from_other.contains(candidate)) {
                redundant = true;
                break;
            }
        }
        if (!redundant) try bases.append(gpa, candidate);
    }
    return bases.toOwnedSlice(gpa);
}

/// The first merge base of `a` and `b`, or `null` when they share no
/// history.
pub fn mergeBase(gpa: Allocator, io: Io, db: *odb_mod.Odb, a: Oid, b: Oid) Error!?Oid {
    const bases = try mergeBases(gpa, io, db, a, b);
    defer gpa.free(bases);
    if (bases.len == 0) return null;
    return bases[0];
}

/// Whether `ancestor` is reachable from `descendant`.
pub fn isAncestor(gpa: Allocator, io: Io, db: *odb_mod.Odb, ancestor: Oid, descendant: Oid) Error!bool {
    if (ancestor.eql(descendant)) return true;
    var seen: Oid.Set = .empty;
    defer seen.deinit(gpa);
    try reachable(gpa, io, db, descendant, &seen);
    return seen.contains(ancestor);
}

fn reachable(gpa: Allocator, io: Io, db: *odb_mod.Odb, from: Oid, out: *Oid.Set) Error!void {
    var queue: std.ArrayList(Oid) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, from);
    while (queue.items.len != 0) {
        const oid = queue.pop().?;
        if (out.contains(oid)) continue;
        try out.put(gpa, oid, {});
        const found = db.read(io, oid) catch continue;
        defer gpa.free(found.bytes);
        if (found.type != .commit) continue;
        var commit = object.Commit.parse(gpa, db.kind, found.bytes) catch continue;
        defer commit.deinit();
        for (commit.parents) |parent| try queue.append(gpa, parent);
    }
}

fn reachableExcluding(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    from: Oid,
    target: Oid,
    out: *Oid.Set,
) Error!void {
    var queue: std.ArrayList(Oid) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, from);
    while (queue.items.len != 0) {
        const oid = queue.pop().?;
        if (out.contains(oid)) continue;
        try out.put(gpa, oid, {});
        if (oid.eql(target)) continue;
        const found = db.read(io, oid) catch continue;
        defer gpa.free(found.bytes);
        if (found.type != .commit) continue;
        var commit = object.Commit.parse(gpa, db.kind, found.bytes) catch continue;
        defer commit.deinit();
        for (commit.parents) |parent| try queue.append(gpa, parent);
    }
}
