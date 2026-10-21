//! `git last-modified`: for each path of a commit's tree, the commit that
//! last changed it.
//!
//! It is git 2.55's `builtin/last-modified.c`. The paths are the commit's
//! tree as a diff from the empty tree lists them: the top level by default,
//! `max_depth` levels down, or every file with `max_depth` `null`; subtrees
//! entered listed too with `trees`; only what `paths` names. The walk goes
//! back from the commit, newest generation and then newest date first,
//! each commit handing every path it holds unchanged to the first parent
//! that has it the same; a path a commit changed from every parent it has
//! is that commit's. A commit that `exclude` reaches, or the commit past
//! `max_count`, is a boundary: the paths still open that it holds as the
//! commit does are its, marked `boundary`. The entries come in git's order:
//! a boundary's in tree order, a commit's own in the order git's hash map
//! keeps the paths. Where a clock runs backwards and no commit-graph gives
//! generations, git can walk a commit before a child that hands it paths,
//! and stops on its own bug; such a commit is walked again here.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const diff = @import("../diff/diff.zig");
const pathspec = @import("../patterns.zig").pathspec;
const commit_graph = @import("../odb/commit_graph.zig");
const rev_parse = @import("rev_parse.zig");
const repo_mod = @import("../repo/repo.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from finding when paths last changed.
pub const Error = error{
    NotACommit,
    /// A depth with a wildcard in `paths`: "max-depth cannot be used with
    /// wildcard pathspecs".
    MaxDepthWithWildcard,
} || diff.Error || rev_parse.Error || commit_graph.Graph.Error || object.ParseError;

/// Where the walk starts and stops.
pub const Inputs = struct {
    /// The commit whose paths are asked about; `HEAD` when `null`.
    revision: ?[]const u8 = null,
    /// `^<rev>`, `--not`: commits whose history is a boundary.
    exclude: []const []const u8 = &.{},
};

/// Which paths, and how far back.
pub const Options = struct {
    /// `-- <paths>`.
    paths: ?*const pathspec.Pathspec = null,
    /// `--max-depth`: how many levels below the top are listed; `-r` is
    /// `null`, every file.
    max_depth: ?u32 = 0,
    /// `-t`: subtrees entered are listed too.
    trees: bool = false,
    /// `-n`: commits looked at before the next is a boundary.
    max_count: ?usize = null,
};

/// One path and the commit that last changed it.
pub const Entry = struct {
    path: []const u8,
    commit: Oid,
    /// The commit is a boundary, which git writes with `^` before it: the
    /// change may be older.
    boundary: bool,
};

/// Every path, in git's order.
pub const Result = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator.State,
    gpa: Allocator,
    entries: []const Entry,

    pub fn deinit(r: *Result) void {
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

pub fn lastModified(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!Result {
    if (options.max_depth != null) if (options.paths) |paths| if (paths.hasWildcard()) return error.MaxDepthWithWildcard;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    var graph = try repo.objectDatabase().commitGraph(io);
    defer if (graph) |*g| g.deinit();
    var lm: LastModified = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options, .graph = if (graph) |*g| g else null };
    defer lm.deinit();
    const target = try lm.commitOf(inputs.revision orelse "HEAD");
    var bottoms: std.ArrayList(*Node) = .empty;
    for (inputs.exclude) |name| try bottoms.append(a, try lm.node(try lm.commitOf(name)));
    const start = try lm.node(target);
    // A commit given both ways is uninteresting: no paths.
    const excluded = for (bottoms.items) |b| {
        if (b == start) break true;
    } else false;
    if (!excluded) try lm.populate(start);
    try lm.run(start, bottoms.items, excluded);
    return .{ .arena = arena_state.state, .gpa = gpa, .entries = lm.out.items };
}

const Node = struct {
    oid: Oid,
    parents: []const Oid,
    tree: Oid,
    time: i64,
    generation: u64,
    /// git's `PARENT1`: queued.
    queued: bool = false,
    /// Taken off the queue and walked.
    walked: bool = false,
    /// git's `PARENT2`: reached from a boundary.
    below: bool = false,
    /// The paths still to be placed, by index, or `null`.
    active: ?std.DynamicBitSetUnmanaged = null,
};

const Path = struct { oid: Oid, index: usize };

const Queued = struct { node: *Node, seq: u64 };

/// git's `compare_commits_by_gen_then_commit_date`, ties first in first
/// out as its priority queue keeps them.
fn byGenerationThenDate(_: void, x: Queued, y: Queued) std.math.Order {
    if (x.node.generation != y.node.generation) return std.math.order(y.node.generation, x.node.generation);
    if (x.node.time != y.node.time) return std.math.order(y.node.time, x.node.time);
    return std.math.order(x.seq, y.seq);
}

const Queue = std.PriorityQueue(Queued, void, byGenerationThenDate);

const LastModified = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,
    graph: ?*const commit_graph.Graph,
    nodes: Oid.Map(*Node) = .empty,
    /// The paths not yet placed, with the version the commit has.
    open: std.StringHashMapUnmanaged(Path) = .empty,
    /// Every path, by index: git's `all_paths`.
    all: []const []const u8 = &.{},
    out: std.ArrayList(Entry) = .empty,
    seq: u64 = 0,

    fn deinit(lm: *LastModified) void {
        var it = lm.nodes.valueIterator();
        while (it.next()) |n| if (n.*.active) |*bits| bits.deinit(lm.gpa);
        lm.nodes.deinit(lm.gpa);
    }

    fn commitOf(lm: *LastModified, name: []const u8) Error!Oid {
        return rev_parse.resolve(lm.gpa, lm.io, lm.repo, try lm.a.print("{s}^{{commit}}", .{name}));
    }

    fn node(lm: *LastModified, oid: Oid) Error!*Node {
        const entry = try lm.nodes.getOrPut(lm.gpa, oid);
        if (entry.found_existing) return entry.value_ptr.*;
        errdefer _ = lm.nodes.remove(oid);
        const db = lm.repo.objectDatabase();
        const found = try db.read(lm.io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        const commit = try object.Commit.parse(lm.a, lm.repo.objectFormat(), try lm.a.dupe(u8, found.bytes));
        const generation: u64 = blk: {
            const g = lm.graph orelse break :blk std.math.maxInt(u64);
            const at = g.find(oid) orelse break :blk std.math.maxInt(u64);
            break :blk (try g.commitAt(at)).generation orelse std.math.maxInt(u64);
        };
        const n = try lm.a.create(Node);
        n.* = .{ .oid = oid, .parents = commit.parents, .tree = commit.tree, .time = commit.committer.when_secs, .generation = generation };
        entry.value_ptr.* = n;
        return n;
    }

    fn diffOf(lm: *LastModified, old: ?Oid, new: Oid) Error!diff.Changes {
        return diff.tree(lm.gpa, lm.io, lm.repo.objectDatabase(), .{ .old = old, .new = new }, .{
            .paths = lm.options.paths,
            .max_depth = lm.options.max_depth,
            .trees = lm.options.trees,
        });
    }

    /// git's `populate_paths_from_revs`: the commit's paths, numbered in
    /// the order its hash map hands them back.
    fn populate(lm: *LastModified, start: *Node) Error!void {
        var changes = try lm.diffOf(null, start.tree);
        defer changes.deinit();
        var inserted: std.ArrayList([]const u8) = .empty;
        for (changes.items) |change| {
            const e = change.new orelse continue;
            const path = try lm.a.dupe(u8, e.path);
            try lm.open.put(lm.a, path, .{ .oid = e.oid, .index = 0 });
            try inserted.append(lm.a, path);
        }
        lm.all = try hashMapOrder(lm.a, inserted.items);
        for (lm.all, 0..) |path, i| lm.open.getPtr(path).?.index = i;
    }

    fn activeOf(lm: *LastModified, n: *Node) Allocator.Error!*std.DynamicBitSetUnmanaged {
        if (n.active == null) n.active = try .initEmpty(lm.gpa, lm.all.len);
        return &n.active.?;
    }

    fn release(lm: *LastModified, n: *Node) void {
        if (n.active) |*bits| bits.deinit(lm.gpa);
        n.active = null;
    }

    fn put(lm: *LastModified, queue: *Queue, n: *Node) Allocator.Error!void {
        try queue.push(lm.gpa, .{ .node = n, .seq = lm.seq });
        lm.seq += 1;
    }

    /// git's `last_modified_run`.
    fn run(lm: *LastModified, start: *Node, bottoms: []const *Node, excluded: bool) Error!void {
        var queue: Queue = .empty;
        defer queue.deinit(lm.gpa);
        var not_queue: Queue = .empty;
        defer not_queue.deinit(lm.gpa);
        for (bottoms) |b| {
            try lm.put(&not_queue, b);
            b.below = true;
        }
        if (!excluded and !start.queued) {
            try lm.put(&queue, start);
            start.queued = true;
            (try lm.activeOf(start)).setRangeValue(.{ .start = 0, .end = lm.all.len }, true);
        }
        var scratch: std.DynamicBitSetUnmanaged = try .initEmpty(lm.gpa, lm.all.len);
        defer scratch.deinit(lm.gpa);
        var popped: usize = 0;
        while (queue.pop()) |q| {
            const c = q.node;
            const active = try lm.activeOf(c);
            popped += 1;
            if ((lm.options.max_count != null and lm.options.max_count.? < popped) or c.below) {
                // A boundary, or past the count: what it holds as the
                // commit does is its.
                c.below = true;
                var changes = try lm.diffOf(null, c.tree);
                defer changes.deinit();
                for (changes.items) |change| {
                    const e = change.new orelse continue;
                    try lm.mark(e.path, e.oid, c, true);
                }
                lm.release(c);
                continue;
            }
            // Whatever the boundaries reach down to this generation.
            while (not_queue.pop()) |nq| {
                const n = nq.node;
                for (n.parents) |p| {
                    const parent = try lm.node(p);
                    if (!parent.below) {
                        try lm.put(&not_queue, parent);
                        parent.below = true;
                    }
                }
                if (n.generation < c.generation) break;
            }
            for (c.parents) |p| {
                try lm.processParent(&queue, &scratch, c, try lm.node(p));
                if (active.count() == 0) break;
            }
            // What no parent has the same is this commit's.
            if (active.count() != 0) {
                var it = active.iterator(.{});
                while (it.next()) |k| try lm.mark(lm.all[k], null, c, false);
            }
            c.walked = true;
            lm.release(c);
        }
    }

    /// git's `process_parent`: the paths `c` holds as `parent` does pass to
    /// it, and it is queued when it has any.
    fn processParent(lm: *LastModified, queue: *Queue, scratch: *std.DynamicBitSetUnmanaged, c: *Node, parent: *Node) Error!void {
        const active_c = try lm.activeOf(c);
        const active_p = try lm.activeOf(parent);
        var changes = try lm.diffOf(parent.tree, c.tree);
        defer changes.deinit();
        for (changes.items) |change| {
            const open = lm.open.get(change.path()) orelse continue;
            if (active_c.isSet(open.index)) scratch.set(open.index);
        }
        for (0..lm.all.len) |k| {
            if (active_c.isSet(k) and !scratch.isSet(k)) {
                active_c.unset(k);
                active_p.set(k);
            }
        }
        if (active_p.count() != 0 and !parent.queued) {
            parent.queued = true;
            try lm.put(queue, parent);
        } else if (active_p.count() != 0 and parent.walked) {
            // Walked already, which only a clock running backwards with no
            // generations does: git loses these paths and stops on its
            // "paths remaining" bug; they are walked again here.
            parent.walked = false;
            try lm.put(queue, parent);
        }
        if (!parent.queued) lm.release(parent);
        scratch.unsetAll();
    }

    /// git's `mark_path`: `path` is `commit`'s, when it is still open and,
    /// where `oid` is given, the commit has the version asked about.
    fn mark(lm: *LastModified, path: []const u8, oid: ?Oid, commit: *Node, boundary: bool) Allocator.Error!void {
        const open = lm.open.get(path) orelse return;
        if (oid) |o| if (!o.eql(open.oid)) return;
        const key = lm.all[open.index];
        try lm.out.append(lm.a, .{ .path = key, .commit = commit.oid, .boundary = boundary });
        _ = lm.open.remove(key);
    }
};

/// The order git's `hashmap` hands back `paths`, added in this order: FNV-1
/// hashes, 64 buckets to start, each new entry at the head of its bucket,
/// four times the buckets once more than 80% full, the old buckets
/// replayed in order into the new.
fn hashMapOrder(a: Allocator, paths: []const []const u8) Allocator.Error![]const []const u8 {
    var size: usize = 64;
    var heads = try a.alloc(?usize, size);
    @memset(heads, null);
    const next = try a.alloc(?usize, paths.len);
    const hashes = try a.alloc(u32, paths.len);
    for (paths, 0..) |path, i| {
        var h: u32 = 0x811c9dc5;
        for (path) |ch| h = (h *% 0x01000193) ^ ch;
        hashes[i] = h;
        const b = @as(usize, h) & (size - 1);
        next[i] = heads[b];
        heads[b] = i;
        if (i + 1 > size * 80 / 100) {
            const bigger = try a.alloc(?usize, size << 2);
            @memset(bigger, null);
            for (heads) |head| {
                var e = head;
                while (e) |at| {
                    const after = next[at];
                    const nb = @as(usize, hashes[at]) & ((size << 2) - 1);
                    next[at] = bigger[nb];
                    bigger[nb] = at;
                    e = after;
                }
            }
            heads = bigger;
            size <<= 2;
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (heads) |head| {
        var e = head;
        while (e) |at| : (e = next[at]) try out.append(a, paths[at]);
    }
    return out.items;
}
