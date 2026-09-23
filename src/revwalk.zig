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
/// descendants is also a common ancestor, newest committer date first.
///
/// This is git's walk and git's order, which matters beyond speed: when there
/// is more than one base, the order is the order a merge folds them in. Both
/// commits' ancestries are painted down together, newest date first, until
/// only commits already known to be behind a common ancestor are left; the
/// common ones found are then checked against each other and any one another
/// can reach is dropped.
///
/// The result is the caller's. An empty result means the two commits share
/// no history, which is what an unrelated-histories merge looks like.
pub fn mergeBases(gpa: Allocator, io: Io, db: *odb_mod.Odb, a: Oid, b: Oid) Error![]Oid {
    if (a.eql(b)) {
        const out = try gpa.alloc(Oid, 1);
        out[0] = a;
        return out;
    }
    var painter: Painter = .{ .gpa = gpa, .io = io, .db = db };
    defer painter.deinit();

    var found: std.ArrayList(Oid) = .empty;
    defer found.deinit(gpa);
    try painter.paint(a, &.{b}, &found);

    var candidates: std.ArrayList(Oid) = .empty;
    errdefer candidates.deinit(gpa);
    for (found.items) |oid| {
        if (!painter.flagsOf(oid).stale) try candidates.append(gpa, oid);
    }
    if (candidates.items.len <= 1) return candidates.toOwnedSlice(gpa);

    // More than one: keep only those no other one reaches.
    const redundant = try gpa.alloc(bool, candidates.items.len);
    defer gpa.free(redundant);
    @memset(redundant, false);
    var others: std.ArrayList(Oid) = .empty;
    defer others.deinit(gpa);
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(gpa);
    for (candidates.items, 0..) |one, i| {
        if (redundant[i]) continue;
        others.clearRetainingCapacity();
        positions.clearRetainingCapacity();
        for (candidates.items, 0..) |other, j| {
            if (i == j or redundant[j]) continue;
            try others.append(gpa, other);
            try positions.append(gpa, j);
        }
        painter.clear();
        var ignored: std.ArrayList(Oid) = .empty;
        defer ignored.deinit(gpa);
        try painter.paint(one, others.items, &ignored);
        if (painter.flagsOf(one).parent2) redundant[i] = true;
        for (others.items, positions.items) |other, j| {
            if (painter.flagsOf(other).parent1) redundant[j] = true;
        }
    }
    var kept: std.ArrayList(Oid) = .empty;
    errdefer kept.deinit(gpa);
    for (candidates.items, redundant) |oid, is_redundant| {
        if (!is_redundant) try painter.insertByDate(&kept, oid);
    }
    candidates.deinit(gpa);
    return kept.toOwnedSlice(gpa);
}

/// git's `paint_down_to_common`, with the commits it has read kept for the
/// next paint.
const Painter = struct {
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    commits: std.AutoHashMapUnmanaged(OidKey, Loaded) = .empty,
    flags: std.AutoHashMapUnmanaged(OidKey, Flags) = .empty,

    const Flags = packed struct { parent1: bool = false, parent2: bool = false, stale: bool = false, result: bool = false };
    const Loaded = struct { parents: []const Oid, time: i64 };
    const Queued = struct { oid: Oid, time: i64, order: u64 };

    fn deinit(p: *Painter) void {
        var it = p.commits.valueIterator();
        while (it.next()) |loaded| p.gpa.free(loaded.parents);
        p.commits.deinit(p.gpa);
        p.flags.deinit(p.gpa);
    }

    fn clear(p: *Painter) void {
        p.flags.clearRetainingCapacity();
    }

    fn flagsOf(p: *const Painter, oid: Oid) Flags {
        return p.flags.get(OidKey.of(oid)) orelse .{};
    }

    fn load(p: *Painter, oid: Oid) Error!Loaded {
        if (p.commits.get(OidKey.of(oid))) |loaded| return loaded;
        const found = try p.db.read(p.io, oid);
        defer p.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(p.gpa, p.db.kind, found.bytes);
        defer commit.deinit();
        const loaded: Loaded = .{ .parents = try p.gpa.dupe(Oid, commit.parents), .time = commit.committer.when_secs };
        errdefer p.gpa.free(loaded.parents);
        try p.commits.put(p.gpa, OidKey.of(oid), loaded);
        return loaded;
    }

    /// `commit_list_insert_by_date`: before the first one that is older, so
    /// a commit goes after those of the same date.
    fn insertByDate(p: *Painter, list: *std.ArrayList(Oid), oid: Oid) Error!void {
        const time = (try p.load(oid)).time;
        var at: usize = 0;
        while (at < list.items.len) : (at += 1) {
            if ((try p.load(list.items[at])).time < time) break;
        }
        try list.insert(p.gpa, at, oid);
    }

    fn byDate(_: void, x: Queued, y: Queued) std.math.Order {
        if (x.time != y.time) return std.math.order(y.time, x.time);
        return std.math.order(x.order, y.order);
    }

    /// Paint `one` and `twos` down, collecting every commit both reach first
    /// into `result` by date.
    fn paint(p: *Painter, one: Oid, twos: []const Oid, result: *std.ArrayList(Oid)) Error!void {
        var queue: std.PriorityQueue(Queued, void, byDate) = .empty;
        defer queue.deinit(p.gpa);
        var order: u64 = 0;

        try p.mark(one, .{ .parent1 = true });
        try queue.push(p.gpa, .{ .oid = one, .time = (try p.load(one)).time, .order = order });
        order += 1;
        for (twos) |two| {
            try p.mark(two, .{ .parent2 = true });
            try queue.push(p.gpa, .{ .oid = two, .time = (try p.load(two)).time, .order = order });
            order += 1;
        }

        while (p.hasNonStale(&queue)) {
            const item = queue.pop().?;
            var flags = p.flagsOf(item.oid);
            flags.result = false;
            if (flags.parent1 and flags.parent2 and !flags.stale) {
                var own = p.flagsOf(item.oid);
                if (!own.result) {
                    own.result = true;
                    try p.flags.put(p.gpa, OidKey.of(item.oid), own);
                    try p.insertByDate(result, item.oid);
                }
                flags.stale = true;
            }
            const loaded = try p.load(item.oid);
            for (loaded.parents) |parent| {
                const have = p.flagsOf(parent);
                if ((!flags.parent1 or have.parent1) and (!flags.parent2 or have.parent2) and
                    (!flags.stale or have.stale)) continue;
                try p.mark(parent, flags);
                try queue.push(p.gpa, .{ .oid = parent, .time = (try p.load(parent)).time, .order = order });
                order += 1;
            }
        }
    }

    fn mark(p: *Painter, oid: Oid, add: Flags) Error!void {
        const gop = try p.flags.getOrPut(p.gpa, OidKey.of(oid));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.parent1 = gop.value_ptr.parent1 or add.parent1;
        gop.value_ptr.parent2 = gop.value_ptr.parent2 or add.parent2;
        gop.value_ptr.stale = gop.value_ptr.stale or add.stale;
    }

    fn hasNonStale(p: *const Painter, queue: anytype) bool {
        for (queue.items) |item| {
            if (!p.flagsOf(item.oid).stale) return true;
        }
        return false;
    }
};

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

const testgit = @import("testgit.zig");

test "merge bases are git's, in git's order, through a criss-cross" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    repo.environ = &env;

    // Two branches that merge each other, twice, so that the tips have two
    // merge bases; the dates are fixed so the order is too.
    const steps = [_][]const []const u8{
        &.{ "commit", "-q", "--allow-empty", "-m", "root" },
        &.{ "checkout", "-q", "-b", "side" },
        &.{ "commit", "-q", "--allow-empty", "-m", "s1" },
        &.{ "checkout", "-q", "main" },
        &.{ "commit", "-q", "--allow-empty", "-m", "m1" },
        &.{ "branch", "m1" },
        &.{ "merge", "-q", "--no-ff", "-m", "m2", "side" },
        &.{ "checkout", "-q", "side" },
        &.{ "merge", "-q", "--no-ff", "-m", "s2", "m1" },
        &.{ "commit", "-q", "--allow-empty", "-m", "s3" },
        &.{ "checkout", "-q", "main" },
        &.{ "commit", "-q", "--allow-empty", "-m", "m3" },
    };
    for (steps, 0..) |step, i| {
        try testgit.setDate(&env, 1_700_000_000 + @as(i64, @intCast(i)) * 60);
        try repo.exec(io, step);
    }
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    for ([_][2][]const u8{ .{ "main", "side" }, .{ "side", "main" }, .{ "main", "m1" }, .{ "m1", "side" }, .{ "main", "main" } }) |pair| {
        const expected = try repo.run(io, &.{ "merge-base", "--all", pair[0], pair[1] });
        defer gpa.free(expected);
        const a_text = try repo.line(io, &.{ "rev-parse", pair[0] });
        defer gpa.free(a_text);
        const b_text = try repo.line(io, &.{ "rev-parse", pair[1] });
        defer gpa.free(b_text);
        const bases = try mergeBases(gpa, io, &db, try Oid.parse(.sha1, a_text), try Oid.parse(.sha1, b_text));
        defer gpa.free(bases);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        for (bases) |oid| {
            var hex: [hash.max_hex_len]u8 = undefined;
            try got.appendSlice(gpa, oid.hex(&hex));
            try got.append(gpa, '\n');
        }
        try std.testing.expectEqualStrings(expected, got.items);
    }
}
