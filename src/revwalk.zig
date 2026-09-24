//! Walking history.
//!
//! Push the commits to start from, hide the ones whose ancestors are not
//! wanted, and take commits out one at a time. Nothing here needs a
//! commit-graph; a caller that has one hands it in and the answers do not
//! change, which is what an accelerator must mean.
//!
//! Neither a hidden commit nor an ancestry question walks the whole of
//! history. A walk with hidden commits takes the pushed and the hidden
//! together, newest first, as git's `limit_list` does, and stops once
//! nothing left can still be wanted; `isAncestor` paints down from both
//! commits as git's `paint_down_to_common` does, and stops once every
//! commit still queued is below a common one — or, with a commit-graph's
//! generation numbers, once the walk is below the ancestor's generation,
//! where it cannot be found. Both cost the commits between the two sides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const commitgraph = @import("commitgraph.zig");

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
    /// A commit-graph to take parents and times from, when the caller has
    /// one open. A commit the graph does not hold is read from the object
    /// database, so the answers do not depend on it — which is what an
    /// accelerator has to mean.
    graph: ?*const commitgraph.Graph = null,

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

        var loaded: std.AutoArrayHashMapUnmanaged(OidKey, Commit) = .empty;
        defer loaded.deinit(walk.gpa);
        errdefer for (loaded.values()) |commit| walk.gpa.free(commit.parents);
        if (walk.hidden.items.len == 0) {
            var queue: std.ArrayList(Oid) = .empty;
            defer queue.deinit(walk.gpa);
            for (walk.roots.items) |oid| try queue.append(walk.gpa, oid);
            var at: usize = 0;
            while (at < queue.items.len) : (at += 1) {
                const oid = queue.items[at];
                const key = OidKey.of(oid);
                if (loaded.contains(key)) continue;
                if (loaded.count() >= walk.max_commits) return error.WalkTooLong;
                const commit = try walk.load(io, oid);
                loaded.put(walk.gpa, key, commit) catch |err| {
                    walk.gpa.free(commit.parents);
                    return err;
                };
                for (commit.parents) |parent| try queue.append(walk.gpa, parent);
            }
        } else try walk.limit(io, &loaded);

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

    /// git's `limit_list`: the pushed and the hidden commits taken together,
    /// newest first, each hidden one's mark carried to its parents and to
    /// every commit below it already taken. A hidden commit ends the walk
    /// only once nothing queued is still wanted, nothing queued is as new as
    /// the last wanted commit, and five more have been taken — commit dates
    /// tie and drift, and the five are what lets a hidden line reach a
    /// commit taken as wanted before it. What is left wanted goes to
    /// `loaded`.
    fn limit(walk: *Walk, io: Io, loaded: *std.AutoArrayHashMapUnmanaged(OidKey, Commit)) Error!void {
        var state: Limited = .{ .walk = walk, .io = io };
        defer state.deinit();
        for (walk.hidden.items) |oid| try state.enqueue(oid, true);
        for (walk.roots.items) |oid| try state.enqueue(oid, false);

        const slop_default = 5;
        var slop: usize = slop_default;
        var last_wanted: i64 = std.math.maxInt(i64);
        var taken: std.ArrayList(OidKey) = .empty;
        defer taken.deinit(walk.gpa);
        while (state.wanted_queued != 0 or state.queue.count() != 0) {
            const item = state.queue.pop() orelse break;
            const node = state.nodes.getPtr(item.key).?;
            node.popped = true;
            const hidden = node.hidden;
            if (!hidden) state.wanted_queued -= 1;
            for (node.commit.parents) |parent| try state.enqueue(parent, hidden);
            if (hidden) {
                const next_item = state.queue.peek() orelse break;
                if (last_wanted <= next_item.time or state.wanted_queued != 0) {
                    slop = slop_default;
                } else {
                    slop -= 1;
                    if (slop == 0) break;
                }
                continue;
            }
            try taken.append(walk.gpa, item.key);
            last_wanted = item.time;
        }
        // A commit taken as wanted and reached by a hidden line afterwards
        // is left out, as git leaves it.
        for (taken.items) |key| {
            const node = state.nodes.getPtr(key).?;
            if (node.hidden) continue;
            try loaded.put(walk.gpa, key, node.commit);
            node.handed_over = true;
        }
    }

    const Limited = struct {
        walk: *Walk,
        io: Io,
        nodes: std.AutoHashMapUnmanaged(OidKey, Node) = .empty,
        queue: std.PriorityQueue(Queued, void, Queued.newerFirst) = .empty,
        wanted_queued: usize = 0,

        const Node = struct {
            commit: Commit,
            hidden: bool,
            popped: bool = false,
            handed_over: bool = false,
        };

        const Queued = struct {
            time: i64,
            key: OidKey,

            fn newerFirst(_: void, a: Queued, b: Queued) std.math.Order {
                if (a.time != b.time) return std.math.order(b.time, a.time);
                return std.mem.order(u8, &a.key.bytes, &b.key.bytes);
            }
        };

        fn deinit(l: *Limited) void {
            var it = l.nodes.valueIterator();
            while (it.next()) |node| {
                if (!node.handed_over) l.walk.gpa.free(node.commit.parents);
            }
            l.nodes.deinit(l.walk.gpa);
            l.queue.deinit(l.walk.gpa);
        }

        fn enqueue(l: *Limited, oid: Oid, hidden: bool) Error!void {
            const key = OidKey.of(oid);
            if (l.nodes.getPtr(key)) |node| {
                if (hidden and !node.hidden) try l.markHidden(key);
                return;
            }
            if (l.nodes.count() >= l.walk.max_commits) return error.WalkTooLong;
            const commit = try l.walk.load(l.io, oid);
            l.nodes.put(l.walk.gpa, key, .{ .commit = commit, .hidden = hidden }) catch |err| {
                l.walk.gpa.free(commit.parents);
                return err;
            };
            if (!hidden) l.wanted_queued += 1;
            try l.queue.push(l.walk.gpa, .{ .time = commit.time, .key = key });
        }

        /// Mark a commit hidden, and every commit below it already taken.
        fn markHidden(l: *Limited, start: OidKey) Error!void {
            var stack: std.ArrayList(OidKey) = .empty;
            defer stack.deinit(l.walk.gpa);
            try stack.append(l.walk.gpa, start);
            while (stack.pop()) |key| {
                const node = l.nodes.getPtr(key) orelse continue;
                if (node.hidden) continue;
                node.hidden = true;
                if (!node.popped) {
                    l.wanted_queued -= 1;
                } else {
                    for (node.commit.parents) |parent| try stack.append(l.walk.gpa, OidKey.of(parent));
                }
            }
        }
    };

    fn load(walk: *Walk, io: Io, oid: Oid) Error!Commit {
        // A commit-graph knows the parents a shallow repository does not
        // have, so it is not asked in one, as git does not ask it.
        if (walk.db.shallow.count() == 0) if (walk.graph) |graph| {
            if (graph.find(oid)) |position| {
                if (graph.commitAt(position)) |entry| {
                    if (graph.parentsOf(walk.gpa, position)) |parents| {
                        return .{ .oid = oid, .parents = parents, .time = entry.time };
                    } else |_| {}
                } else |_| {}
            }
        };
        const found = try walk.db.read(io, oid);
        defer walk.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(walk.gpa, walk.db.kind, found.bytes);
        defer commit.deinit();
        return .{
            .oid = oid,
            .parents = try walk.gpa.dupe(Oid, parentsOf(walk.db, oid, commit.parents)),
            .time = commit.committer.when_secs,
        };
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

/// A commit's parents as a walk sees them: none for a commit at a shallow
/// repository's boundary, whose parents are not in it.
pub fn parentsOf(db: *const odb_mod.Odb, oid: Oid, parents: []const Oid) []const Oid {
    return if (db.shallow.contains(oid)) &.{} else parents;
}

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
    return isAncestorWith(gpa, io, db, ancestor, descendant, .{});
}

/// What an ancestry question may use.
pub const AncestryOptions = struct {
    /// A commit-graph whose generation numbers bound the walk. Without one,
    /// or for a commit it does not hold, the walk is bounded by the common
    /// history instead, and the answer is the same.
    graph: ?*const commitgraph.Graph = null,
};

/// `isAncestor`, with a commit-graph to bound the walk: git's
/// `repo_in_merge_bases`. Both commits are painted down, newest generation
/// then newest date first; a commit both reach is common and its parents
/// are not worth going on with; and the walk ends when nothing queued is
/// still worth it, or when it is below the ancestor's generation.
pub fn isAncestorWith(gpa: Allocator, io: Io, db: *odb_mod.Odb, ancestor: Oid, descendant: Oid, options: AncestryOptions) Error!bool {
    if (ancestor.eql(descendant)) return true;
    var paint: Paint = .{ .gpa = gpa, .io = io, .db = db, .graph = options.graph };
    defer paint.deinit();
    // A pointer into the map lasts until the next commit is read; the
    // values are taken while it does.
    const min_generation = (try paint.nodeOf(ancestor)).generation;
    const descendant_generation = (try paint.nodeOf(descendant)).generation;
    // A commit of a later generation than another cannot be its ancestor.
    if (min_generation > descendant_generation) return false;
    try paint.mark(ancestor, Paint.one);
    try paint.mark(descendant, Paint.two);

    while (paint.hasNonStale()) {
        const item = paint.queue.pop().?;
        const node = paint.nodes.getPtr(OidKey.of(item.oid)).?;
        if (node.generation < min_generation) break;
        var flags = node.flags & (Paint.one | Paint.two | Paint.stale);
        if (flags == Paint.one | Paint.two) flags |= Paint.stale;
        const parents = node.parents;
        for (parents) |parent| {
            const p = try paint.nodeOf(parent);
            if (p.flags & flags == flags) continue;
            try paint.mark(parent, flags);
        }
    }
    return paint.nodes.get(OidKey.of(ancestor)).?.flags & Paint.two != 0;
}

/// The state of `isAncestorWith`'s walk.
const Paint = struct {
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    graph: ?*const commitgraph.Graph,
    nodes: std.AutoHashMapUnmanaged(OidKey, Node) = .empty,
    queue: std.PriorityQueue(Queued, void, Queued.order) = .empty,

    const one: u8 = 1;
    const two: u8 = 2;
    const stale: u8 = 4;
    /// A commit the graph does not hold: later than any it does.
    const infinity = std.math.maxInt(u64);

    const Node = struct {
        flags: u8 = 0,
        time: i64,
        generation: u64,
        parents: []const Oid,
    };

    const Queued = struct {
        generation: u64,
        time: i64,
        oid: Oid,

        fn order(_: void, a: Queued, b: Queued) std.math.Order {
            if (a.generation != b.generation) return std.math.order(b.generation, a.generation);
            if (a.time != b.time) return std.math.order(b.time, a.time);
            return a.oid.order(b.oid);
        }
    };

    fn deinit(p: *Paint) void {
        var it = p.nodes.valueIterator();
        while (it.next()) |node| p.gpa.free(node.parents);
        p.nodes.deinit(p.gpa);
        p.queue.deinit(p.gpa);
    }

    /// The commit, read once. The pointer lasts until the next one is
    /// read.
    fn nodeOf(p: *Paint, oid: Oid) Error!*Node {
        const gop = try p.nodes.getOrPut(p.gpa, OidKey.of(oid));
        if (gop.found_existing) return gop.value_ptr;
        errdefer _ = p.nodes.remove(OidKey.of(oid));
        if (p.db.shallow.count() == 0) if (p.graph) |graph| {
            if (graph.find(oid)) |position| {
                if (graph.commitAt(position)) |entry| {
                    if (graph.parentsOf(p.gpa, position)) |parents| {
                        gop.value_ptr.* = .{ .time = entry.time, .generation = entry.generation orelse infinity, .parents = parents };
                        return gop.value_ptr;
                    } else |_| {}
                } else |_| {}
            }
        };
        const found = try p.db.read(p.io, oid);
        defer p.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(p.gpa, p.db.kind, found.bytes);
        defer commit.deinit();
        gop.value_ptr.* = .{
            .time = commit.committer.when_secs,
            .generation = infinity,
            .parents = try p.gpa.dupe(Oid, parentsOf(p.db, oid, commit.parents)),
        };
        return gop.value_ptr;
    }

    fn mark(p: *Paint, oid: Oid, flags: u8) Error!void {
        const n = try p.nodeOf(oid);
        n.flags |= flags;
        try p.queue.push(p.gpa, .{ .generation = n.generation, .time = n.time, .oid = oid });
    }

    /// git's `queue_has_nonstale`.
    fn hasNonStale(p: *Paint) bool {
        for (p.queue.items) |item| {
            if (p.nodes.get(OidKey.of(item.oid)).?.flags & stale == 0) return true;
        }
        return false;
    }
};

fn reachable(gpa: Allocator, io: Io, db: *odb_mod.Odb, from: Oid, out: *Oid.Set) Error!void {
    var queue: std.ArrayList(Oid) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, from);
    while (queue.items.len != 0) {
        const oid = queue.pop().?;
        if (out.contains(oid)) continue;
        try out.put(gpa, oid, {});
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(gpa, db.kind, found.bytes);
        defer commit.deinit();
        for (parentsOf(db, oid, commit.parents)) |parent| try queue.append(gpa, parent);
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
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(gpa, db.kind, found.bytes);
        defer commit.deinit();
        for (parentsOf(db, oid, commit.parents)) |parent| try queue.append(gpa, parent);
    }
}

test "ancestry reports a missing commit instead of a negative answer" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var db = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{});
    defer db.deinit(io);

    const ancestor = try Oid.parse(.sha1, "1" ** 40);
    const missing = try Oid.parse(.sha1, "2" ** 40);
    try std.testing.expectError(error.ObjectNotFound, isAncestor(gpa, io, &db, ancestor, missing));
}
