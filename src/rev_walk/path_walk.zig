//! The objects a history reaches, in batches by the path that reaches
//! them: git 2.55's path-walk (`path-walk.c`), which `git backfill` asks
//! for its blobs.
//!
//! The commits are walked first, as `git rev-list` walks them, and handed
//! back in one batch at the empty path. Their root trees, each once, make
//! the batch at the empty path for trees, with the trees of the hidden
//! parents at the walk's edge first when `edges` asks for them. Each tree
//! batch then gives its entries to the batches at their own paths, a
//! subtree's path ending in `/`; the batches come in git's order, every
//! blob batch ready before the next tree batch, each kind by path, so the
//! walk goes down the history's trees depth first. An object is in the
//! first batch that reaches it and no other, and a submodule is passed by.
//!
//! `paths` limits the walk as it limits `git rev-list -- <paths>`: the
//! commits are simplified to the ones that change what it names, and a
//! blob batch is handed back only at a path it names. A pathspec of plain
//! paths also passes by every entry that is neither on the way to one of
//! them nor under one, as git compares them: as directory prefixes of each
//! other, so `dir/` and `.` take in less than they name. Sparse-checkout
//! patterns pass by what they leave out: in cone mode each blob and, with
//! `sparse_trees`, each tree outside the cone; otherwise each blob no
//! pattern of its own path takes in. A `sparse:oid=` filter is such
//! patterns, in cone mode, with every tree walked.

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const walk_mod = @import("../walk/walk.zig");
const commit_graph = @import("../odb/commit_graph.zig");
const patterns = @import("../patterns.zig");
const filter_spec = @import("../wire.zig").filter_spec;
const rev_parse = @import("rev_parse.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const pathspec = patterns.pathspec;
const sparse = patterns.sparse;
const Bytes = aegis.units.Bytes(u64);

/// Errors from a path walk.
pub const Error = error{
    /// `tree:<depth>` with a depth: "tree:%lu filter not supported by the
    /// path-walk API".
    FilterNotSupported,
    /// `sparse:oid=` with `sparse` patterns given too: "sparse filter
    /// cannot be combined with existing sparse patterns".
    SparseFilterWithPatterns,
    /// "unable to access sparse blob in '<name>'".
    SparseBlobMissing,
    /// "sparse filter is not cone-mode compatible".
    SparseFilterNotCone,
} || walk_mod.Error || rev_parse.Error || config_mod.ValueError || filter_spec.Error || commit_graph.Graph.Error || object.ParseError || object.TreeParseError;

/// Where the history starts and stops.
pub const Inputs = struct {
    /// The commits walked from.
    include: []const Oid,
    /// `^<commit>`: commits whose history is left out.
    exclude: []const Oid = &.{},
};

/// What is walked and handed back.
pub const Options = struct {
    /// Which kinds of object come back. A walk without trees still goes
    /// through them to its blobs.
    commits: bool = true,
    trees: bool = true,
    blobs: bool = true,
    /// `-- <paths>`.
    paths: ?*const pathspec.Pathspec = null,
    /// `--first-parent`.
    first_parent: bool = false,
    /// `--edges`: the hidden parents of the commits walked give their
    /// trees too, ahead of the commits' own.
    edges: bool = false,
    /// Sparse-checkout patterns to walk within. A `sparse:oid=` filter
    /// cannot be given with them.
    sparse: ?*const sparse.Patterns = null,
    /// Whether `sparse` passes by trees outside the cone too, rather than
    /// only blobs.
    sparse_trees: bool = false,
    /// `--filter=<spec>`: `blob:none`, `blob:limit=`, `tree:0`,
    /// `object:type=`, `sparse:oid=` and `combine:` of them; another is
    /// `error.FilterNotSupported`.
    filter: ?[]const u8 = null,
};

/// The objects of one kind found at one path.
pub const Batch = struct {
    /// Empty for the commits and the root trees; a subtree's ends in `/`.
    path: []const u8,
    kind: object.Type,
    oids: []const Oid,
};

const List = struct {
    kind: object.Type,
    oids: std.ArrayList(Oid) = .empty,
};

const Queued = struct {
    /// git's `compare_by_type`: blobs before trees.
    rank: u1,
    path: []const u8,
    seq: u64,
};

fn byKindThenPath(_: void, a: Queued, b: Queued) std.math.Order {
    if (a.rank != b.rank) return std.math.order(a.rank, b.rank);
    return switch (std.mem.order(u8, a.path, b.path)) {
        .eq => std.math.order(a.seq, b.seq),
        else => |o| o,
    };
}

/// A walk in progress. `next` hands back the batches.
pub const PathWalk = struct {
    pub const Error = Self.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    db: *odb_mod.Odb,
    commits_wanted: bool,
    trees: bool,
    blobs: bool,
    blob_limit: ?Bytes = null,
    paths: ?*const pathspec.Pathspec,
    exact: bool,
    sparse: ?*const sparse.Patterns,
    sparse_trees: bool,
    /// The patterns a `sparse:oid=` filter named.
    filter_patterns: ?sparse.Patterns = null,
    lists: std.StringHashMapUnmanaged(*List) = .empty,
    queue: std.PriorityQueue(Queued, void, byKindThenPath) = .empty,
    pushed: std.StringHashMapUnmanaged(void) = .empty,
    seen: Oid.Set = .empty,
    seq: u64 = 0,
    commits: std.ArrayList(Oid) = .empty,
    commits_given: bool = false,
    /// The batch last handed back, released by the next call; a tree
    /// batch is first gone into.
    last: ?struct { path: []const u8, list: *List } = null,
    filtered: std.ArrayList(Oid) = .empty,

    /// Walk the commits and gather their trees. `repo` must outlive the
    /// walk.
    pub fn init(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!PathWalk {
        var pw: PathWalk = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .db = repo.objectDatabase(),
            .commits_wanted = options.commits,
            .trees = options.trees,
            .blobs = options.blobs,
            .paths = options.paths,
            .exact = if (options.paths) |p| p.items.len != 0 and p.isExact() else false,
            .sparse = options.sparse,
            .sparse_trees = options.sparse_trees,
        };
        errdefer pw.deinit();
        if (options.filter) |text| {
            const spec = try filter_spec.parse(pw.arena.allocator(), text);
            try pw.applyFilter(io, repo, spec);
        }
        try pw.walkCommits(io, repo, inputs, options);
        return pw;
    }

    pub fn deinit(pw: *PathWalk) void {
        const gpa = pw.gpa;
        pw.release();
        var lists = pw.lists.valueIterator();
        while (lists.next()) |list| {
            list.*.oids.deinit(gpa);
            gpa.destroy(list.*);
        }
        pw.lists.deinit(gpa);
        pw.queue.deinit(gpa);
        pw.pushed.deinit(gpa);
        pw.seen.deinit(gpa);
        pw.commits.deinit(gpa);
        pw.filtered.deinit(gpa);
        if (pw.filter_patterns) |*p| p.deinit();
        pw.arena.deinit();
        pw.* = undefined;
    }

    /// git's `prepare_filters`.
    fn applyFilter(pw: *PathWalk, io: Io, repo: *Repository, spec: filter_spec.Spec) Self.Error!void {
        switch (spec) {
            .blob_none => pw.blobs = false,
            .blob_limit => |limit| {
                if (limit.eql(.fromRaw(0))) {
                    pw.blobs = false;
                } else if (pw.blob_limit == null or limit.compare(pw.blob_limit.?) == .lt) pw.blob_limit = limit;
            },
            .tree_depth => |depth| {
                if (depth != 0) return error.FilterNotSupported;
                pw.trees = false;
                pw.blobs = false;
            },
            .object_type => |t| {
                pw.commits_wanted = pw.commits_wanted and t == .commit;
                pw.trees = pw.trees and t == .tree;
                pw.blobs = pw.blobs and t == .blob;
            },
            .sparse_oid => |name| {
                if (pw.sparse != null) return error.SparseFilterWithPatterns;
                const oid = rev_parse.resolve(pw.gpa, io, repo, name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                    else => return error.SparseBlobMissing,
                };
                const found = try pw.db.read(io, oid);
                defer pw.db.allocator().free(found.bytes);
                if (found.type != .blob) return error.SparseBlobMissing;
                const fold = try repo.configuration().getBool("core.ignorecase", false);
                var loaded = try sparse.Patterns.fromText(pw.gpa, found.bytes, .{ .cone = true, .case_fold = fold });
                if (loaded.cone == null) {
                    loaded.deinit();
                    return error.SparseFilterNotCone;
                }
                pw.filter_patterns = loaded;
                pw.sparse_trees = false;
            },
            .combine => |parts| for (parts) |part| try pw.applyFilter(io, repo, part),
        }
    }

    /// The commit walk, the root trees from it, and the commits' batch.
    fn walkCommits(pw: *PathWalk, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!void {
        const gpa = pw.gpa;
        var graph = try pw.db.commitGraph(io);
        defer if (graph) |*g| g.deinit();
        var w = walk_mod.Walk.init(gpa, pw.db);
        defer w.deinit();
        w.paths = options.paths;
        w.first_parent = options.first_parent;
        w.graph = if (graph) |*g| g else null;
        w.max_tree_depth = repo.settings().max_tree_depth;
        for (inputs.include) |oid| try w.push(oid);
        for (inputs.exclude) |oid| try w.hide(oid);
        try w.prepare(io);

        const root = try pw.listAt("", .tree);
        try pw.push("", .tree);
        if (options.edges) {
            // git's `mark_edges_uninteresting` with `show_edge`.
            var shown: Oid.Set = .empty;
            defer shown.deinit(gpa);
            while (try w.next(io)) |c| {
                for (c.parents) |parent| {
                    if (!w.isHidden(parent)) continue;
                    if ((try shown.getOrPut(gpa, parent)).found_existing) continue;
                    const tree = try pw.treeOf(io, parent);
                    if (!try pw.see(tree)) continue;
                    try root.oids.append(gpa, tree);
                }
            }
            w.reset();
        }
        while (try w.next(io)) |c| {
            if (c.treesame) continue;
            if (pw.commits_wanted) try pw.commits.append(gpa, c.oid);
            if (!pw.trees and !pw.blobs) continue;
            if (!try pw.see(c.tree)) continue;
            try root.oids.append(gpa, c.tree);
        }
    }

    fn treeOf(pw: *PathWalk, io: Io, commit: Oid) Self.Error!Oid {
        const found = try pw.db.read(io, commit);
        defer pw.db.allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var parsed = try object.Commit.parse(pw.gpa, pw.db.objectFormat(), found.bytes);
        defer parsed.deinit();
        return parsed.tree;
    }

    /// Mark `oid` seen; whether it was not before.
    fn see(pw: *PathWalk, oid: Oid) Allocator.Error!bool {
        return !(try pw.seen.getOrPut(pw.gpa, oid)).found_existing;
    }

    /// The list at `path`, made for `kind` if there is none. `path` is
    /// copied when a list is made.
    fn listAt(pw: *PathWalk, path: []const u8, kind: object.Type) Allocator.Error!*List {
        if (pw.lists.get(path)) |list| return list;
        const list = try pw.gpa.create(List);
        errdefer pw.gpa.destroy(list);
        list.* = .{ .kind = kind };
        try pw.lists.put(pw.gpa, try pw.arena.allocator().dupe(u8, path), list);
        return list;
    }

    /// git's `push_to_stack`: a path is queued once.
    fn push(pw: *PathWalk, path: []const u8, kind: object.Type) Allocator.Error!void {
        if (pw.pushed.contains(path)) return;
        const owned = pw.lists.getKey(path).?;
        try pw.pushed.put(pw.gpa, owned, {});
        try pw.queue.push(pw.gpa, .{ .rank = if (kind == .blob) 0 else 1, .path = owned, .seq = pw.seq });
        pw.seq += 1;
    }

    /// The next batch, or `null` at the end. The batch is the walk's until
    /// the next call.
    pub fn next(pw: *PathWalk, io: Io) Self.Error!?Batch {
        if (!pw.commits_given) {
            pw.commits_given = true;
            if (pw.commits.items.len != 0) return .{ .path = "", .kind = .commit, .oids = pw.commits.items };
        }
        if (pw.last) |last| if (last.list.kind == .tree) {
            for (last.list.oids.items) |tree| try pw.addEntries(io, last.path, tree);
        };
        pw.release();
        while (pw.queue.pop()) |queued| {
            const list = pw.lists.get(queued.path).?;
            if (list.oids.items.len == 0) {
                pw.drop(queued.path);
                continue;
            }
            if (list.kind == .blob) if (pw.paths) |paths| if (!paths.matches(queued.path)) continue;
            pw.last = .{ .path = queued.path, .list = list };
            const wanted = switch (list.kind) {
                .tree => pw.trees,
                .blob => pw.blobs,
                else => false,
            };
            if (!wanted) {
                if (list.kind == .tree) for (list.oids.items) |tree| try pw.addEntries(io, queued.path, tree);
                pw.release();
                continue;
            }
            if (list.kind == .blob) if (pw.blob_limit) |limit| {
                const kept = try pw.underLimit(io, queued.path, list, limit);
                return kept orelse continue;
            };
            return .{ .path = queued.path, .kind = list.kind, .oids = list.oids.items };
        }
        return null;
    }

    /// The blobs of `list` smaller than `limit`, or `null` for none.
    fn underLimit(pw: *PathWalk, io: Io, path: []const u8, list: *List, limit: Bytes) Self.Error!?Batch {
        pw.filtered.clearRetainingCapacity();
        for (list.oids.items) |oid| {
            const header = try pw.db.readHeader(io, oid);
            if (header.type != .blob or Bytes.fromRaw(header.size).compare(limit) == .lt) try pw.filtered.append(pw.gpa, oid);
        }
        if (pw.filtered.items.len == 0) {
            pw.release();
            return null;
        }
        return .{ .path = path, .kind = .blob, .oids = pw.filtered.items };
    }

    fn release(pw: *PathWalk) void {
        const last = pw.last orelse return;
        pw.last = null;
        pw.drop(last.path);
    }

    fn drop(pw: *PathWalk, path: []const u8) void {
        const removed = pw.lists.fetchRemove(path) orelse return;
        removed.value.oids.deinit(pw.gpa);
        pw.gpa.destroy(removed.value);
    }

    /// git's `add_tree_entries`: the entries of `tree`, at `base`, to the
    /// lists at their paths.
    fn addEntries(pw: *PathWalk, io: Io, base: []const u8, tree: Oid) Self.Error!void {
        const gpa = pw.gpa;
        const found = try pw.db.read(io, tree);
        defer pw.db.allocator().free(found.bytes);
        if (found.type != .tree) return error.UnexpectedObjectType;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(gpa);
        try path.appendSlice(gpa, base);
        var it = object.Tree.parse(pw.db.objectFormat(), found.bytes).iterate();
        while (try it.next()) |entry| {
            if (entry.mode == .gitlink) continue;
            const is_tree = entry.mode.isTree();
            if (!pw.blobs and !is_tree) continue;
            path.shrinkRetainingCapacity(base.len);
            try path.appendSlice(gpa, entry.name);
            if (is_tree) try path.append(gpa, '/');
            const name = if (is_tree) path.items[0 .. path.items.len - 1] else path.items;
            const kind: object.Type = if (is_tree) .tree else .blob;

            if (pw.seen.contains(entry.oid)) {
                // A tree already walked elsewhere is walked again where a
                // cone of a `sparse:oid=` filter takes it in, for the
                // blobs the cone takes in below it.
                const p = pw.sparsePatterns() orelse continue;
                if (!is_tree or p.cone == null or pw.sparse_trees or pw.lists.contains(path.items)) continue;
                if (!p.decides(name, .dir).?) continue;
                try (try pw.listAt(path.items, kind)).oids.append(gpa, entry.oid);
                try pw.push(path.items, kind);
                continue;
            }
            if (pw.sparsePatterns()) |p| {
                if (p.cone != null) {
                    if (!p.decides(name, if (is_tree) .dir else .file).? and (!is_tree or pw.sparse_trees)) continue;
                } else if (!is_tree and p.decides(name, .file) != true) continue;
            }
            if (pw.exact) if (!pw.onTheWay(name)) continue;
            _ = try pw.see(entry.oid);
            try (try pw.listAt(path.items, kind)).oids.append(gpa, entry.oid);
            try pw.push(path.items, kind);
        }
    }

    /// The sparse-checkout patterns walked within: the filter's, or the
    /// caller's.
    fn sparsePatterns(pw: *const PathWalk) ?*const sparse.Patterns {
        if (pw.filter_patterns) |*p| return p;
        return pw.sparse;
    }

    /// Whether `path` and an item of `paths` are each other's directory
    /// prefix, either way round.
    fn onTheWay(pw: *const PathWalk, path: []const u8) bool {
        for (pw.paths.?.items) |item| {
            if (dirPrefix(path, item.match) or dirPrefix(item.match, path)) return true;
        }
        return false;
    }
};

/// git's `dir_prefix`: `dir` begins `buf`, which ends there or goes on
/// with a `/`.
fn dirPrefix(buf: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, buf, dir) and (buf.len == dir.len or buf[dir.len] == '/');
}
