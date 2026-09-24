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
//! commits as git's `paint_down_to_common` does, and with a commit-graph's
//! generation numbers stops below the ancestor's generation. A shallow
//! repository's boundary commits have no parents here, and its commit-graph,
//! which knows parents the repository lacks, is not read.

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
    /// Newest committer date first, as `git rev-list` gives them: a
    /// queue by date, ties taken in the order the walk met them.
    date,
    /// `git rev-list --topo-order`: no parent before all of its children,
    /// and a line of history kept together, the tips in the order the date
    /// walk met them.
    topological,
};

/// One commit, with what the walk needed from it.
pub const Commit = struct {
    oid: Oid,
    /// Borrowed from the walk.
    parents: []const Oid,
    /// Committer time in seconds, which is what the date order uses.
    time: i64,
};

/// A history walk: `git rev-list`'s own, from the commits pushed, less
/// everything the hidden ones reach.
///
/// The walk is git's `revision.c`: a queue by committer date, ties taken
/// first in first out; with hidden commits the queue carries them too,
/// marking what they reach as it goes, and stops once nothing it still
/// holds can be wanted -- five commits past the point where every commit
/// left is hidden, as git's `limit_list` stops, which is also what makes a
/// commit with a skewed date come out where git's comes out. The
/// topological order is git's `sort_in_topological_order` in graph order
/// over what that walk found.
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

    /// The commits given, in the order given: git's pending list.
    pending: std.ArrayList(Pending) = .empty,
    nodes: std.AutoHashMapUnmanaged(OidKey, *Node) = .empty,
    /// Filled by `prepare`, consumed by `next`.
    ordered: std.ArrayList(Commit) = .empty,
    position: usize = 0,
    prepared: bool = false,

    const Pending = struct { oid: Oid, hidden: bool };

    const Node = struct {
        oid: Oid,
        parents: []const Oid = &.{},
        time: i64 = 0,
        parsed: bool = false,
        seen: bool = false,
        added: bool = false,
        uninteresting: bool = false,
    };

    const Queued = struct { node: *Node, seq: u64 };

    fn byDate(_: void, a: Queued, b: Queued) std.math.Order {
        if (a.node.time != b.node.time) return std.math.order(b.node.time, a.node.time);
        return std.math.order(a.seq, b.seq);
    }

    /// A walk over `db`.
    pub fn init(gpa: Allocator, db: *odb_mod.Odb) Walk {
        return .{ .gpa = gpa, .db = db };
    }

    /// Release everything.
    pub fn deinit(walk: *Walk) void {
        walk.clearNodes();
        walk.nodes.deinit(walk.gpa);
        walk.ordered.deinit(walk.gpa);
        walk.pending.deinit(walk.gpa);
        walk.* = undefined;
    }

    fn clearNodes(walk: *Walk) void {
        var it = walk.nodes.valueIterator();
        while (it.next()) |n| {
            walk.gpa.free(n.*.parents);
            walk.gpa.destroy(n.*);
        }
        walk.nodes.clearRetainingCapacity();
    }

    /// Start from this commit.
    pub fn push(walk: *Walk, oid: Oid) Allocator.Error!void {
        walk.prepared = false;
        try walk.pending.append(walk.gpa, .{ .oid = oid, .hidden = false });
    }

    /// Leave this commit and everything it reaches out of the walk.
    pub fn hide(walk: *Walk, oid: Oid) Allocator.Error!void {
        walk.prepared = false;
        try walk.pending.append(walk.gpa, .{ .oid = oid, .hidden = true });
    }

    fn nodeOf(walk: *Walk, oid: Oid) Error!*Node {
        const slot = try walk.nodes.getOrPut(walk.gpa, OidKey.of(oid));
        if (!slot.found_existing) {
            errdefer _ = walk.nodes.remove(OidKey.of(oid));
            if (walk.nodes.count() > walk.max_commits) return error.WalkTooLong;
            const created = try walk.gpa.create(Node);
            created.* = .{ .oid = oid };
            slot.value_ptr.* = created;
        }
        return slot.value_ptr.*;
    }

    /// `repo_parse_commit`: the parents and the date.
    fn parse(walk: *Walk, io: Io, n: *Node) Error!void {
        if (n.parsed) return;
        // A commit-graph knows the parents a shallow repository does not
        // have, so a shallow walk reads the commits themselves.
        if (walk.db.shallow.count() == 0) if (walk.graph) |graph| {
            if (graph.find(n.oid)) |position| {
                if (graph.commitAt(position)) |entry| {
                    if (graph.parentsOf(walk.gpa, position)) |parents| {
                        n.parents = parents;
                        n.time = entry.time;
                        n.parsed = true;
                        return;
                    } else |_| {}
                } else |_| {}
            }
        };
        const found = try walk.db.read(io, n.oid);
        defer walk.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(walk.gpa, walk.db.kind, found.bytes);
        defer commit.deinit();
        n.parents = try walk.gpa.dupe(Oid, parentsOf(walk.db, n.oid, commit.parents));
        n.time = commit.committer.when_secs;
        n.parsed = true;
    }

    /// `mark_parents_uninteresting`: through what has been read already.
    fn markParentsUninteresting(walk: *Walk, n: *Node) Error!void {
        var stack: std.ArrayList(*Node) = .empty;
        defer stack.deinit(walk.gpa);
        for (n.parents) |parent| try stack.append(walk.gpa, try walk.nodeOf(parent));
        while (stack.pop()) |c| {
            if (c.uninteresting) continue;
            c.uninteresting = true;
            for (c.parents) |parent| try stack.append(walk.gpa, try walk.nodeOf(parent));
        }
    }

    /// `process_parents`, into the date queue.
    fn processParents(walk: *Walk, io: Io, n: *Node, queue: anytype, seq: *u64) Error!void {
        if (n.added) return;
        n.added = true;
        for (n.parents) |parent_oid| {
            const p = try walk.nodeOf(parent_oid);
            if (n.uninteresting) p.uninteresting = true;
            try walk.parse(io, p);
            if (n.uninteresting and p.parents.len != 0) try walk.markParentsUninteresting(p);
            if (p.seen) continue;
            p.seen = true;
            try queue.push(walk.gpa, .{ .node = p, .seq = seq.* });
            seq.* += 1;
        }
    }

    fn everybodyUninteresting(queue: anytype) bool {
        for (queue.items) |q| {
            if (!q.node.uninteresting) return false;
        }
        return true;
    }

    /// Load and order the commits. `next` does this itself the first time.
    pub fn prepare(walk: *Walk, io: Io) Error!void {
        if (walk.prepared) return;
        walk.ordered.clearRetainingCapacity();
        walk.position = 0;
        walk.clearNodes();

        var queue: std.PriorityQueue(Queued, void, byDate) = .empty;
        defer queue.deinit(walk.gpa);
        var seq: u64 = 0;
        var limited = false;
        for (walk.pending.items) |given| {
            const n = try walk.nodeOf(given.oid);
            try walk.parse(io, n);
            if (given.hidden) {
                n.uninteresting = true;
                try walk.markParentsUninteresting(n);
                limited = true;
            }
            if (n.seen) continue;
            n.seen = true;
            try queue.push(walk.gpa, .{ .node = n, .seq = seq });
            seq += 1;
        }

        var list: std.ArrayList(*Node) = .empty;
        defer list.deinit(walk.gpa);
        if (limited) {
            // `limit_list`.
            const slop_start = 5;
            var slop: u32 = slop_start;
            var date: i64 = std.math.maxInt(i64);
            while (queue.pop()) |q| {
                const n = q.node;
                try walk.processParents(io, n, &queue, &seq);
                if (n.uninteresting) {
                    try walk.markParentsUninteresting(n);
                    // `still_interesting`.
                    if (queue.items.len == 0) break;
                    const top = queue.peek().?;
                    if (date <= top.node.time or !everybodyUninteresting(&queue)) {
                        slop = slop_start;
                    } else {
                        slop -= 1;
                        if (slop == 0) break;
                    }
                    continue;
                }
                date = n.time;
                try list.append(walk.gpa, n);
            }
        } else {
            while (queue.pop()) |q| {
                try walk.processParents(io, q.node, &queue, &seq);
                try list.append(walk.gpa, q.node);
            }
        }

        if (walk.sort == .topological) try walk.sortTopologically(&list);
        try walk.ordered.ensureTotalCapacity(walk.gpa, list.items.len);
        for (list.items) |n| {
            if (n.uninteresting) continue;
            walk.ordered.appendAssumeCapacity(.{ .oid = n.oid, .parents = n.parents, .time = n.time });
        }
        if (walk.reverse) std.mem.reverse(Commit, walk.ordered.items);
        walk.prepared = true;
    }

    /// `sort_in_topological_order` in graph order: the tips, in the order
    /// the walk found them, on a stack, and a parent pushed once its last
    /// child is out.
    fn sortTopologically(walk: *Walk, list: *std.ArrayList(*Node)) Error!void {
        var indegree: std.AutoHashMapUnmanaged(*Node, u32) = .empty;
        defer indegree.deinit(walk.gpa);
        for (list.items) |n| try indegree.put(walk.gpa, n, 1);
        for (list.items) |n| {
            for (n.parents) |parent| {
                const p = walk.nodes.get(OidKey.of(parent)) orelse continue;
                if (indegree.getPtr(p)) |d| {
                    if (d.* != 0) d.* += 1;
                }
            }
        }
        var stack: std.ArrayList(*Node) = .empty;
        defer stack.deinit(walk.gpa);
        for (list.items) |n| {
            if (indegree.get(n).? == 1) try stack.append(walk.gpa, n);
        }
        std.mem.reverse(*Node, stack.items);
        var out: std.ArrayList(*Node) = .empty;
        errdefer out.deinit(walk.gpa);
        try out.ensureTotalCapacity(walk.gpa, list.items.len);
        while (stack.pop()) |n| {
            for (n.parents) |parent| {
                const p = walk.nodes.get(OidKey.of(parent)) orelse continue;
                const d = indegree.getPtr(p) orelse continue;
                if (d.* == 0) continue;
                d.* -= 1;
                if (d.* == 1) try stack.append(walk.gpa, p);
            }
            indegree.getPtr(n).?.* = 0;
            out.appendAssumeCapacity(n);
        }
        list.deinit(walk.gpa);
        list.* = out;
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
    return mergeBasesWith(gpa, io, db, a, b, .{});
}

/// What else a merge-base computation may read from.
pub const BaseOptions = struct {
    /// Parents and dates from a commit-graph, for the commits it holds.
    /// The answer does not change.
    graph: ?*const commitgraph.Graph = null,
    /// Commits that exist only for the length of the computation.
    virtuals: []const Virtual = &.{},
};

/// A commit that exists only for the length of a computation: a recursive
/// merge's merged base, whose parents are the two bases it merged and whose
/// date is git's zero.
pub const Virtual = struct {
    oid: Oid,
    parents: []const Oid,
};

/// `mergeBases`, reading commits as `options` says.
pub fn mergeBasesWith(gpa: Allocator, io: Io, db: *odb_mod.Odb, a: Oid, b: Oid, options: BaseOptions) Error![]Oid {
    if (a.eql(b)) {
        const out = try gpa.alloc(Oid, 1);
        out[0] = a;
        return out;
    }
    var painter: Painter = .{ .gpa = gpa, .io = io, .db = db, .virtuals = options.virtuals, .graph = options.graph };
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
    virtuals: []const Virtual = &.{},
    graph: ?*const commitgraph.Graph = null,
    commits: std.AutoHashMapUnmanaged(OidKey, Loaded) = .empty,
    flags: std.AutoHashMapUnmanaged(OidKey, Flags) = .empty,
    /// How many entries in the queue are not stale, and how many of each
    /// commit's are: git scans its queue for one, which on a wide history
    /// is the whole cost of the walk.
    nonstale: usize = 0,
    queued_nonstale: std.AutoHashMapUnmanaged(OidKey, u32) = .empty,

    const Flags = packed struct { parent1: bool = false, parent2: bool = false, stale: bool = false, result: bool = false };
    const Loaded = struct { parents: []const Oid, time: i64, generation: u64 = infinity };
    const Queued = struct { oid: Oid, time: i64, generation: u64, order: u64 };
    /// git's `GENERATION_NUMBER_INFINITY`: a commit the graph does not hold.
    const infinity: u64 = std.math.maxInt(u64);

    /// Whether the queue goes by generation first, as git's does when the
    /// graph carries corrected commit dates.
    fn byGeneration(p: *const Painter) bool {
        const graph = p.graph orelse return false;
        return graph.hasGenerations();
    }

    fn deinit(p: *Painter) void {
        var it = p.commits.valueIterator();
        while (it.next()) |loaded| p.gpa.free(loaded.parents);
        p.commits.deinit(p.gpa);
        p.flags.deinit(p.gpa);
        p.queued_nonstale.deinit(p.gpa);
    }

    fn clear(p: *Painter) void {
        p.flags.clearRetainingCapacity();
        p.queued_nonstale.clearRetainingCapacity();
        p.nonstale = 0;
    }

    fn enqueue(p: *Painter, queue: anytype, item: Queued) Error!void {
        try queue.push(p.gpa, item);
        if (!p.flagsOf(item.oid).stale) {
            const slot = try p.queued_nonstale.getOrPut(p.gpa, OidKey.of(item.oid));
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
            p.nonstale += 1;
        }
    }

    fn dequeued(p: *Painter, oid: Oid) void {
        if (p.flagsOf(oid).stale) return;
        const slot = p.queued_nonstale.getPtr(OidKey.of(oid)) orelse return;
        if (slot.* == 0) return;
        slot.* -= 1;
        p.nonstale -= 1;
    }

    fn flagsOf(p: *const Painter, oid: Oid) Flags {
        return p.flags.get(OidKey.of(oid)) orelse .{};
    }

    fn load(p: *Painter, oid: Oid) Error!Loaded {
        if (p.commits.get(OidKey.of(oid))) |loaded| return loaded;
        for (p.virtuals) |v| {
            if (!v.oid.eql(oid)) continue;
            const loaded: Loaded = .{ .parents = try p.gpa.dupe(Oid, v.parents), .time = 0 };
            errdefer p.gpa.free(loaded.parents);
            try p.commits.put(p.gpa, OidKey.of(oid), loaded);
            return loaded;
        }
        if (p.db.shallow.count() == 0) if (p.graph) |graph| {
            if (graph.find(oid)) |position| {
                if (graph.commitAt(position)) |entry| {
                    if (graph.parentsOf(p.gpa, position)) |parents| {
                        const loaded: Loaded = .{ .parents = parents, .time = entry.time, .generation = entry.generation orelse infinity };
                        errdefer p.gpa.free(loaded.parents);
                        try p.commits.put(p.gpa, OidKey.of(oid), loaded);
                        return loaded;
                    } else |_| {}
                } else |_| {}
            }
        };
        const found = try p.db.read(p.io, oid);
        defer p.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(p.gpa, p.db.kind, found.bytes);
        defer commit.deinit();
        const loaded: Loaded = .{ .parents = try p.gpa.dupe(Oid, parentsOf(p.db, oid, commit.parents)), .time = commit.committer.when_secs };
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

    /// `compare_commits_by_gen_then_commit_date`.
    fn byGenerationThenDate(_: void, x: Queued, y: Queued) std.math.Order {
        if (x.generation != y.generation) return std.math.order(y.generation, x.generation);
        if (x.time != y.time) return std.math.order(y.time, x.time);
        return std.math.order(x.order, y.order);
    }

    fn queued(p: *Painter, oid: Oid, order: u64) Error!Queued {
        const loaded = try p.load(oid);
        return .{ .oid = oid, .time = loaded.time, .generation = if (p.byGeneration()) loaded.generation else 0, .order = order };
    }

    /// Paint `one` and `twos` down, collecting every commit both reach first
    /// into `result` by date.
    fn paint(p: *Painter, one: Oid, twos: []const Oid, result: *std.ArrayList(Oid)) Error!void {
        return p.paintFrom(one, twos, result, 0);
    }

    /// `paint_down_to_common`, stopping below `min_generation`.
    fn paintFrom(p: *Painter, one: Oid, twos: []const Oid, result: *std.ArrayList(Oid), min_generation: u64) Error!void {
        var queue: std.PriorityQueue(Queued, void, byGenerationThenDate) = .empty;
        defer queue.deinit(p.gpa);
        var order: u64 = 0;

        try p.mark(one, .{ .parent1 = true });
        try p.enqueue(&queue, try p.queued(one, order));
        order += 1;
        for (twos) |two| {
            try p.mark(two, .{ .parent2 = true });
            try p.enqueue(&queue, try p.queued(two, order));
            order += 1;
        }

        while (p.nonstale != 0) {
            const item = queue.pop().?;
            p.dequeued(item.oid);
            if (p.byGeneration() and item.generation < min_generation) break;
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
                try p.enqueue(&queue, try p.queued(parent, order));
                order += 1;
            }
        }
    }

    fn mark(p: *Painter, oid: Oid, add: Flags) Error!void {
        const gop = try p.flags.getOrPut(p.gpa, OidKey.of(oid));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (add.stale and !gop.value_ptr.stale) {
            // Its queued entries stop counting.
            if (p.queued_nonstale.getPtr(OidKey.of(oid))) |n| {
                p.nonstale -= n.*;
                n.* = 0;
            }
        }
        gop.value_ptr.parent1 = gop.value_ptr.parent1 or add.parent1;
        gop.value_ptr.parent2 = gop.value_ptr.parent2 or add.parent2;
        gop.value_ptr.stale = gop.value_ptr.stale or add.stale;
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

/// Whether `ancestor` is reachable from `descendant`: git's
/// `repo_in_merge_bases`, which paints both down by date and stops as soon
/// as nothing left to walk can decide it.
pub fn isAncestor(gpa: Allocator, io: Io, db: *odb_mod.Odb, ancestor: Oid, descendant: Oid) Error!bool {
    return isAncestorWith(gpa, io, db, ancestor, descendant, .{});
}

/// `isAncestor`, reading commits as `options` says.
pub fn isAncestorWith(gpa: Allocator, io: Io, db: *odb_mod.Odb, ancestor: Oid, descendant: Oid, options: BaseOptions) Error!bool {
    if (ancestor.eql(descendant)) return true;
    var painter: Painter = .{ .gpa = gpa, .io = io, .db = db, .virtuals = options.virtuals, .graph = options.graph };
    defer painter.deinit();
    var found: std.ArrayList(Oid) = .empty;
    defer found.deinit(gpa);
    var min_generation: u64 = 0;
    if (painter.byGeneration()) {
        // A commit newer than the one it might be an ancestor of is not one.
        const generation = (try painter.load(ancestor)).generation;
        if (generation > (try painter.load(descendant)).generation) return false;
        min_generation = generation;
    }
    try painter.paintFrom(ancestor, &.{descendant}, &found, min_generation);
    return painter.flagsOf(ancestor).parent2;
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

/// A fast-import stream for a random history: `branches` lines of work,
/// merges between them, and committer dates that tie and run backwards.
fn randomHistory(gpa: Allocator, random: std.Random, commits: usize, branches: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const tips = try gpa.alloc(usize, branches);
    defer gpa.free(tips);
    @memset(tips, 0);
    var date: i64 = 1_700_000_000;
    for (1..commits + 1) |mark| {
        const b = random.uintLessThan(usize, branches);
        switch (random.uintLessThan(u8, 10)) {
            0 => {}, // the same second as the last commit
            1 => date -= @as(i64, random.uintLessThan(u32, 5000)), // a clock behind
            else => date += @as(i64, random.uintLessThan(u32, 600)),
        }
        try out.print(gpa, "commit refs/heads/b{d}\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 3\nc{d}\n", .{ b, mark, date, mark % 10 });
        if (tips[b] != 0) try out.print(gpa, "from :{d}\n", .{tips[b]});
        const other = random.uintLessThan(usize, branches);
        if (other != b and tips[other] != 0 and tips[b] != 0 and random.uintLessThan(u8, 4) == 0) {
            try out.print(gpa, "merge :{d}\n", .{tips[other]});
        }
        try out.appendSlice(gpa, "deleteall\n\n");
        tips[b] = mark;
    }
    return out.toOwnedSlice(gpa);
}

fn expectWalkLikeRevList(gpa: Allocator, io: Io, repo: *testgit.Repo, db: *odb_mod.Odb, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "rev-list");
    try argv.appendSlice(gpa, args);
    const expected = try repo.run(io, argv.items);
    defer gpa.free(expected);

    var walk: Walk = .init(gpa, db);
    defer walk.deinit();
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--topo-order")) {
            walk.sort = .topological;
            continue;
        }
        if (std.mem.eql(u8, arg, "--reverse")) {
            walk.reverse = true;
            continue;
        }
        const hidden = arg[0] == '^';
        const name = if (hidden) arg[1..] else arg;
        const text = try repo.line(io, &.{ "rev-parse", name });
        defer gpa.free(text);
        const oid = try Oid.parse(.sha1, text);
        if (hidden) try walk.hide(oid) else try walk.push(oid);
    }
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    while (try walk.next(io)) |commit| {
        try got.appendSlice(gpa, commit.oid.hex(&hex));
        try got.append(gpa, '\n');
    }
    std.testing.expectEqualStrings(expected, got.items) catch |err| {
        for (args) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print(": rev-list differs\n", .{});
        return err;
    };
}

test "a walk comes out in git rev-list's order: by date with its ties, hidden commits, topological, reversed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for (0..walk_seeds) |seed| try walkLikeRevList(gpa, io, seed);
}

const walk_seeds = testgit.corpusCases(8);

fn walkLikeRevList(gpa: Allocator, io: Io, seed: u64) !void {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    const stream = try randomHistory(gpa, prng.random(), 600, 2 + @as(usize, @intCast(seed % 5)));
    defer gpa.free(stream);
    const imported = try repo.runInput(io, &.{ "fast-import", "--quiet" }, stream);
    gpa.free(imported);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    const queries = [_][]const []const u8{
        &.{"b0"},
        &.{ "b0", "b1" },
        &.{ "b1", "^b2" },
        &.{ "^b0", "b3", "b2" },
        &.{ "--topo-order", "b0", "b1", "b2", "b3" },
        &.{ "--topo-order", "b2", "^b1" },
        &.{ "--reverse", "b3", "^b0" },
        &.{ "--topo-order", "--reverse", "b1" },
    };
    for (queries) |q| {
        // A branch this seed has no commit on is not a query.
        var known = true;
        for (q) |arg| {
            if (arg[0] == '-') continue;
            const name = if (arg[0] == '^') arg[1..] else arg;
            repo.report_failures = false;
            defer repo.report_failures = true;
            repo.exec(io, &.{ "rev-parse", "--verify", "-q", name }) catch {
                known = false;
            };
        }
        if (known) try expectWalkLikeRevList(gpa, io, &repo, &db, q);
    }

    // Merge bases and ancestry, read from the objects and from a
    // commit-graph with corrected dates, against git's.
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });
    const objects = try git_dir.openDir(io, "objects", .{});
    defer objects.close(io);
    var graph = (try commitgraph.Graph.open(gpa, io, objects, .sha1)).?;
    defer graph.deinit();
    const names = [_][]const u8{ "b0", "b1", "b2", "b3", "b4", "b5" };
    for (names) |x| {
        for (names) |y| {
            repo.report_failures = false;
            defer repo.report_failures = true;
            const x_text = repo.line(io, &.{ "rev-parse", "--verify", "-q", x }) catch continue;
            defer gpa.free(x_text);
            const y_text = repo.line(io, &.{ "rev-parse", "--verify", "-q", y }) catch continue;
            defer gpa.free(y_text);
            const xo = try Oid.parse(.sha1, x_text);
            const yo = try Oid.parse(.sha1, y_text);
            const expected = try repo.runInput(io, &.{ "merge-base", "--all", x, y }, "");
            defer gpa.free(expected);
            for ([_]?*const commitgraph.Graph{ null, &graph }) |g| {
                const bases = try mergeBasesWith(gpa, io, &db, xo, yo, .{ .graph = g });
                defer gpa.free(bases);
                var got: std.ArrayList(u8) = .empty;
                defer got.deinit(gpa);
                var hex: [hash.max_hex_len]u8 = undefined;
                for (bases) |b| {
                    try got.appendSlice(gpa, b.hex(&hex));
                    try got.append(gpa, '\n');
                }
                try std.testing.expectEqualStrings(expected, got.items);
                const ancestor = if (repo.exec(io, &.{ "merge-base", "--is-ancestor", x, y })) |_| true else |_| false;
                try std.testing.expectEqual(ancestor, try isAncestorWith(gpa, io, &db, xo, yo, .{ .graph = g }));
            }
        }
    }
}
