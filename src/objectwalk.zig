//! Which objects one side has that the other lacks, and whether a set of
//! tips is whole.
//!
//! A push sends, and a fetch from a repository on this machine copies, the
//! objects reachable from what is wanted and not from what the other side
//! already has: `git rev-list --objects <want> --not <have>`. The commits
//! are walked newest first from both sets at once, each side's flag carried
//! down to the parents, and the walk stops once nothing left to walk can
//! still be wanted; the trees of the commits it stopped at are marked had,
//! so a file that did not change is not sent again. It is git's own
//! approximation and it has git's cost, which is the commits and trees
//! between the two sides and not the whole history.
//!
//! After a pack arrives, the tips it was fetched for are checked to be
//! whole: every object below them read, as far as the new pack reaches,
//! and every object outside it asked for by name. What the repository
//! already held is taken to be whole, which is the assumption git's own
//! check after a fetch makes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const revwalk = @import("revwalk.zig");
const ignore = @import("ignore.zig");
const indexpack = @import("indexpack.zig");

const Oid = hash.Oid;
const Odb = odb_mod.Odb;

/// Errors from walking objects.
pub const Error = error{
    /// An object below a tip is not in the database. `missing_out` names
    /// it.
    MissingObject,
    /// A commit named something that is not a commit as its parent, or a
    /// tree named a tree entry that is not a tree.
    UnexpectedObjectType,
} || odb_mod.Error || object.ParseError || Allocator.Error;

const flag_uninteresting: u8 = 1;
const flag_seen: u8 = 2;
const flag_popped: u8 = 4;

const Node = struct {
    flags: u8 = 0,
    time: i64 = 0,
    parents: []const Oid = &.{},
    tree: Oid,
    loaded: bool = false,
};

const Queued = struct {
    time: i64,
    oid: Oid,

    fn newerFirst(_: void, a: Queued, b: Queued) std.math.Order {
        if (a.time != b.time) return std.math.order(b.time, a.time);
        return a.oid.order(b.oid);
    }
};

/// Every object reachable from `include` and not from `exclude`, in `db`,
/// each with the path it was found at as its delta hint. A name in
/// `exclude` that `db` does not hold is passed over: it is the other
/// side's, and says nothing about this one.
pub fn missing(gpa: Allocator, io: Io, db: *Odb, include: []const Oid, exclude: []const Oid) Error!Odb.Collected {
    return missingWith(gpa, io, db, include, exclude, .{});
}

/// What a server's pack leaves out: git's `--filter` specs.
pub const Filter = union(enum) {
    none,
    /// `blob:none`: no blob.
    blob_none,
    /// `blob:limit=<n>`: no blob larger than `n` bytes.
    blob_limit: u64,
    /// `tree:<depth>`: no tree or blob at `depth` or deeper, a commit's
    /// root tree being at depth zero.
    tree_depth: u64,
    /// `object:type=<type>`: only objects of the type.
    object_type: object.Type,
    /// `sparse:oid=<blob>`: every tree, and the blobs the blob's
    /// sparse-checkout patterns take in, a path no pattern decides taking
    /// its directory's answer, as git's sparse filter decides. One to a
    /// filter.
    sparse: *const ignore.Rules,
    /// `combine:<a>+<b>…`: what every one of them keeps.
    combine: []const Filter,

    /// Whether what the filter keeps depends on where an object is met —
    /// its depth or its path — so a tree met again at another path is
    /// walked again.
    fn positional(f: Filter) bool {
        return switch (f) {
            .tree_depth, .sparse => true,
            .combine => |all| for (all) |part| {
                if (part.positional()) break true;
            } else false,
            else => false,
        };
    }

    /// The sparse patterns in the filter, when it has some.
    fn sparseRules(f: Filter) ?*const ignore.Rules {
        return switch (f) {
            .sparse => |rules| rules,
            .combine => |all| for (all) |part| {
                if (part.sparseRules()) |rules| break rules;
            } else null,
            else => null,
        };
    }
};

/// How `missingWith` walks.
pub const MissingOptions = struct {
    /// Commits whose parents are not followed: a shallow clone's boundary,
    /// as the server draws it for one request.
    boundary: ?*const Oid.Set = null,
    /// What is left out. An object named in `include` is kept whatever the
    /// filter says, as git keeps one.
    filter: Filter = .none,
};

/// `missing`, walked with `options`.
pub fn missingWith(gpa: Allocator, io: Io, db: *Odb, include: []const Oid, exclude: []const Oid, options: MissingOptions) Error!Odb.Collected {
    var walk: Walk = .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .arena = .init(gpa),
        .boundary = options.boundary,
        .filter = options.filter,
        .positional = options.filter.positional(),
        .sparse = options.filter.sparseRules(),
    };
    defer walk.deinit();
    var collected: Odb.Collected = .{ .arena = .init(gpa), .entries = &.{} };
    errdefer collected.arena.deinit();
    const out_arena = collected.arena.allocator();

    var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
    defer entries.deinit(gpa);
    var pending_trees: std.ArrayList(Oid) = .empty;
    defer pending_trees.deinit(gpa);
    var pending_blobs: std.ArrayList(Oid) = .empty;
    defer pending_blobs.deinit(gpa);

    for (exclude) |tip| {
        if (!try db.exists(io, tip)) continue;
        const peeled = try walk.peel(tip, null);
        switch (peeled.type) {
            .commit => try walk.enqueue(peeled.oid, flag_uninteresting),
            .tree => try walk.markTreeHad(peeled.oid),
            .blob => try walk.had.put(gpa, peeled.oid, {}),
            .tag => unreachable,
        }
    }
    for (include) |tip| {
        var tags: std.ArrayList(Oid) = .empty;
        defer tags.deinit(gpa);
        const peeled = try walk.peel(tip, &tags);
        for (tags.items) |tag| {
            if (walk.had.contains(tag) or walk.added.contains(tag)) continue;
            try walk.added.put(gpa, tag, {});
            try entries.append(gpa, .{ .oid = tag });
        }
        switch (peeled.type) {
            .commit => {
                // Asked for by name: sent whatever the filter says, as git
                // sends a wanted commit under `object:type=blob`.
                try walk.named.put(gpa, peeled.oid, {});
                try walk.enqueue(peeled.oid, 0);
            },
            .tree, .blob => {
                // Asked for by name: sent whatever the filter says.
                try walk.named.put(gpa, peeled.oid, {});
                if (peeled.type == .tree) try pending_trees.append(gpa, peeled.oid) else try pending_blobs.append(gpa, peeled.oid);
            },
            .tag => unreachable,
        }
    }

    const commits = try walk.walkCommits();
    defer gpa.free(commits);

    // The trees of the commits the walk stopped at are what the other side
    // is known to have.
    var it = walk.nodes.iterator();
    while (it.next()) |kv| {
        const node = kv.value_ptr;
        if (node.flags & flag_uninteresting == 0 or !node.loaded) continue;
        try walk.markTreeHad(node.tree);
    }

    for (commits) |oid| {
        const node = walk.nodes.getPtr(oid).?;
        if (node.flags & flag_uninteresting != 0) continue;
        if (try walk.keeps(oid, .commit, 0, true)) try entries.append(gpa, .{ .oid = oid });
        try walk.addTree(node.tree, "", &entries, out_arena);
    }
    for (pending_trees.items) |tree| try walk.addTree(tree, "", &entries, out_arena);
    for (pending_blobs.items) |blob| {
        if (walk.had.contains(blob) or walk.added.contains(blob)) continue;
        try walk.added.put(gpa, blob, {});
        try entries.append(gpa, .{ .oid = blob });
    }

    collected.entries = try out_arena.dupe(odb_mod.PackEntry, entries.items);
    return collected;
}

const Walk = struct {
    gpa: Allocator,
    io: Io,
    db: *Odb,
    arena: std.heap.ArenaAllocator,
    nodes: Oid.Map(Node) = .empty,
    queue: std.PriorityQueue(Queued, void, Queued.newerFirst) = .empty,
    /// Commits in the queue that are still wanted.
    wanted_queued: usize = 0,
    /// Trees and blobs the other side is known to have.
    had: Oid.Set = .empty,
    /// Objects already listed.
    added: Oid.Set = .empty,
    /// Objects named in `include`, which no filter leaves out.
    named: Oid.Set = .empty,
    boundary: ?*const Oid.Set = null,
    filter: Filter = .none,
    /// `Filter.positional`: trees are walked once for every path they are
    /// met at, and an object is listed the first time the filter keeps it.
    positional: bool = false,
    /// `Filter.sparseRules`.
    sparse: ?*const ignore.Rules = null,
    /// A positional walk's trees, by name and path, already walked.
    visited: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(w: *Walk) void {
        w.nodes.deinit(w.gpa);
        w.queue.deinit(w.gpa);
        w.had.deinit(w.gpa);
        w.added.deinit(w.gpa);
        w.named.deinit(w.gpa);
        w.visited.deinit(w.gpa);
        w.arena.deinit();
    }

    /// Whether the filter keeps an object of `kind` at `depth` from its
    /// commit's root tree; `in_sparse` is whether the sparse patterns take
    /// its path in.
    fn keeps(w: *Walk, oid: Oid, kind: object.Type, depth: u64, in_sparse: bool) Error!bool {
        if (w.named.contains(oid)) return true;
        return w.keepsWith(w.filter, oid, kind, depth, in_sparse);
    }

    fn keepsWith(w: *Walk, filter: Filter, oid: Oid, kind: object.Type, depth: u64, in_sparse: bool) Error!bool {
        return switch (filter) {
            .none => true,
            .blob_none => kind != .blob,
            .blob_limit => |limit| kind != .blob or (try w.db.readHeader(w.io, oid)).size <= limit,
            .tree_depth => |max| (kind != .tree and kind != .blob) or depth < max,
            .object_type => |t| kind == t,
            .sparse => kind != .blob or in_sparse,
            .combine => |all| {
                for (all) |f| if (!try w.keepsWith(f, oid, kind, depth, in_sparse)) return false;
                return true;
            },
        };
    }

    /// The sparse patterns' answer for `path`: theirs when one decides,
    /// `inherited` — its directory's — when none does.
    fn sparseMatch(w: *const Walk, path: []const u8, is_dir: bool, inherited: bool) bool {
        const rules = w.sparse orelse return true;
        if (path.len == 0) return inherited;
        const m = rules.match(path, is_dir);
        return if (m.by != null) m.excluded else inherited;
    }

    /// Whether a tree at `depth` is walked into: `tree:<n>` stops walking
    /// where nothing below can be kept.
    fn descends(w: *Walk, depth: u64) bool {
        return descendsWith(w.filter, depth);
    }

    fn descendsWith(filter: Filter, depth: u64) bool {
        return switch (filter) {
            .tree_depth => |max| depth < max,
            .combine => |all| {
                for (all) |f| if (!descendsWith(f, depth)) return false;
                return true;
            },
            else => true,
        };
    }

    const Peeled = struct { oid: Oid, type: object.Type };

    /// Follow tags to what they name, noting each tag on the way.
    fn peel(w: *Walk, start: Oid, tags: ?*std.ArrayList(Oid)) Error!Peeled {
        var current = start;
        var depth: u8 = 0;
        while (depth < 16) : (depth += 1) {
            const header = try w.db.readHeader(w.io, current);
            if (header.type != .tag) return .{ .oid = current, .type = header.type };
            if (tags) |list| try list.append(w.gpa, current);
            const found = try w.db.read(w.io, current);
            defer w.db.gpa.free(found.bytes);
            var tag = try object.Tag.parse(w.gpa, w.db.kind, found.bytes);
            defer tag.deinit();
            current = tag.target;
        }
        return error.UnexpectedObjectType;
    }

    fn load(w: *Walk, oid: Oid) Error!*Node {
        const gop = try w.nodes.getOrPut(w.gpa, oid);
        if (!gop.found_existing) gop.value_ptr.* = .{ .tree = .zero(w.db.kind) };
        const node = gop.value_ptr;
        if (node.loaded) return node;
        const found = try w.db.read(w.io, oid);
        defer w.db.gpa.free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        var commit = try object.Commit.parse(w.gpa, w.db.kind, found.bytes);
        defer commit.deinit();
        // `load` may have grown the map; the pointer is taken again.
        const again = w.nodes.getPtr(oid).?;
        again.time = commit.committer.when_secs;
        const on_boundary = if (w.boundary) |b| b.contains(oid) else false;
        again.parents = if (on_boundary) &.{} else try w.arena.allocator().dupe(Oid, revwalk.parentsOf(w.db, oid, commit.parents));
        again.tree = commit.tree;
        again.loaded = true;
        return again;
    }

    fn enqueue(w: *Walk, oid: Oid, flags: u8) Error!void {
        const node = try w.load(oid);
        if (node.flags & flag_seen != 0) {
            if (flags & flag_uninteresting != 0) try w.markUninteresting(oid);
            return;
        }
        node.flags |= flag_seen | flags;
        if (node.flags & flag_uninteresting == 0) w.wanted_queued += 1;
        try w.queue.push(w.gpa, .{ .time = node.time, .oid = oid });
    }

    /// Mark a commit had, and every commit below it the walk has already
    /// been through.
    fn markUninteresting(w: *Walk, start: Oid) Error!void {
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(w.gpa);
        try stack.append(w.gpa, start);
        while (stack.pop()) |oid| {
            const node = w.nodes.getPtr(oid) orelse continue;
            if (node.flags & flag_uninteresting != 0) continue;
            node.flags |= flag_uninteresting;
            if (node.flags & flag_seen != 0 and node.flags & flag_popped == 0) w.wanted_queued -= 1;
            if (node.flags & flag_popped != 0) {
                for (node.parents) |parent| try stack.append(w.gpa, parent);
            }
        }
    }

    /// Take commits newest first until nothing queued is still wanted.
    /// Returns the wanted ones in the order taken; one marked had later is
    /// left for the caller to skip.
    ///
    /// git's `limit_list`: a had commit ends the walk only once nothing
    /// queued is still wanted, nothing queued is as new as the last wanted
    /// commit, and five more have been taken. Commit dates are not
    /// ordered — two made in one second tie, and clocks drift — and the
    /// five are what lets a had commit reach one taken as wanted before it
    /// and mark it had after all.
    fn walkCommits(w: *Walk) Error![]Oid {
        const slop_default = 5;
        var out: std.ArrayList(Oid) = .empty;
        errdefer out.deinit(w.gpa);
        var slop: usize = slop_default;
        var last_wanted: i64 = std.math.maxInt(i64);
        if (w.wanted_queued == 0) return out.toOwnedSlice(w.gpa);
        while (w.queue.pop()) |item| {
            const node = w.nodes.getPtr(item.oid).?;
            node.flags |= flag_popped;
            const uninteresting = node.flags & flag_uninteresting != 0;
            if (!uninteresting) w.wanted_queued -= 1;
            const time = node.time;
            const parents = node.parents;
            for (parents) |parent| {
                try w.enqueue(parent, if (uninteresting) flag_uninteresting else 0);
            }
            if (uninteresting) {
                const next = w.queue.peek() orelse break;
                if (last_wanted <= next.time or w.wanted_queued != 0) {
                    slop = slop_default;
                } else {
                    slop -= 1;
                    if (slop == 0) break;
                }
                continue;
            }
            try out.append(w.gpa, item.oid);
            last_wanted = time;
        }
        return out.toOwnedSlice(w.gpa);
    }

    /// Mark a tree and everything below it had.
    fn markTreeHad(w: *Walk, root: Oid) Error!void {
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(w.gpa);
        try stack.append(w.gpa, root);
        while (stack.pop()) |oid| {
            if (w.had.contains(oid)) continue;
            try w.had.put(w.gpa, oid, {});
            const found = w.db.read(w.io, oid) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => |e| return e,
            };
            defer w.db.gpa.free(found.bytes);
            if (found.type != .tree) continue;
            var entries = object.Tree.parse(w.db.kind, found.bytes).iterate();
            while (try entries.next()) |entry| {
                switch (entry.mode) {
                    .tree => try stack.append(w.gpa, entry.oid),
                    .gitlink => {},
                    else => try w.had.put(w.gpa, entry.oid, {}),
                }
            }
        }
    }

    /// List a tree and what is below it, less what is had or listed.
    fn addTree(
        w: *Walk,
        root: Oid,
        root_path: []const u8,
        out: *std.ArrayList(odb_mod.PackEntry),
        arena: Allocator,
    ) Error!void {
        // `inherited` is the sparse answer of the directory a tree is in;
        // the walk's root is outside every pattern, as git's is.
        const Item = struct { oid: Oid, path: []const u8, depth: u64, inherited: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(w.gpa);
        try stack.append(w.gpa, .{ .oid = root, .path = root_path, .depth = 0, .inherited = false });
        while (stack.pop()) |item| {
            if (w.had.contains(item.oid)) continue;
            var own = item.inherited;
            if (w.positional) {
                // Met again at this path: the same answers as before.
                const key = try std.mem.concat(arena, u8, &.{ item.oid.bytes[0..item.oid.kind.rawLen()], item.path });
                if ((try w.visited.getOrPut(w.gpa, key)).found_existing) continue;
                own = w.sparseMatch(item.path, true, item.inherited);
                if (!w.added.contains(item.oid) and try w.keeps(item.oid, .tree, item.depth, true)) {
                    try w.added.put(w.gpa, item.oid, {});
                    try out.append(w.gpa, .{ .oid = item.oid, .hint = item.path });
                }
            } else {
                if (w.added.contains(item.oid)) continue;
                try w.added.put(w.gpa, item.oid, {});
                if (try w.keeps(item.oid, .tree, item.depth, true)) try out.append(w.gpa, .{ .oid = item.oid, .hint = item.path });
            }
            if (!w.named.contains(item.oid) and !w.descends(item.depth + 1)) continue;
            const found = try w.db.read(w.io, item.oid);
            defer w.db.gpa.free(found.bytes);
            if (found.type != .tree) return error.UnexpectedObjectType;
            var entries = object.Tree.parse(w.db.kind, found.bytes).iterate();
            while (try entries.next()) |entry| {
                const path = if (item.path.len == 0)
                    try arena.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ item.path, entry.name });
                switch (entry.mode) {
                    .tree => try stack.append(w.gpa, .{ .oid = entry.oid, .path = path, .depth = item.depth + 1, .inherited = own }),
                    // A gitlink names a commit in another repository.
                    .gitlink => {},
                    else => {
                        if (w.had.contains(entry.oid) or w.added.contains(entry.oid)) continue;
                        if (w.positional) {
                            // Left out here, it may be kept where it is met
                            // again.
                            if (try w.keeps(entry.oid, .blob, item.depth + 1, w.sparseMatch(path, false, own))) {
                                try w.added.put(w.gpa, entry.oid, {});
                                try out.append(w.gpa, .{ .oid = entry.oid, .hint = path });
                            }
                        } else {
                            try w.added.put(w.gpa, entry.oid, {});
                            if (try w.keeps(entry.oid, .blob, item.depth + 1, true)) try out.append(w.gpa, .{ .oid = entry.oid, .hint = path });
                        }
                    },
                }
            }
        }
    }
};

/// Check that everything below `tips` is present. Objects `fresh` holds —
/// the index of a pack just received — are read and walked into; any other
/// object is asked for by name only and taken to be whole, as what the
/// repository held before is. `fresh` of `null` walks everything.
///
/// The first object that is not there is `error.MissingObject`, and is
/// written to `missing_out` when one is given.
pub fn checkConnected(
    gpa: Allocator,
    io: Io,
    db: *Odb,
    tips: []const Oid,
    fresh: ?*const pack.Index,
    missing_out: ?*Oid,
) Error!void {
    return checkConnectedWith(gpa, io, db, tips, fresh, missing_out, .{});
}

/// What `checkConnectedWith` allows.
pub const ConnectedOptions = struct {
    /// The pack came from a partial clone's promisor remote, whose filter
    /// left objects out on purpose: an object the pack's objects name and
    /// the repository lacks is one the remote promises, as git's
    /// `--exclude-promisor-objects` reads it.
    promisor: bool = false,
};

/// `checkConnectedWith` for a pack just received, whose `links` were
/// collected as it was indexed. When they read whole and the pack is not a
/// promisor's, nothing is walked: every name the pack holds is looked up in
/// the pack and the database, and every tip, which is what git's index-pack
/// `--check-self-contained-and-connected` lets git's fetch skip its walk
/// for. Otherwise it walks, as `checkConnectedWith` does.
pub fn checkReceived(
    gpa: Allocator,
    io: Io,
    db: *Odb,
    tips: []const Oid,
    fresh: *const pack.Index,
    links: *const indexpack.Links,
    missing_out: ?*Oid,
    options: ConnectedOptions,
) Error!void {
    if (options.promisor or links.unreadable) return checkConnectedWith(gpa, io, db, tips, fresh, missing_out, options);
    if (try links.firstMissing(io, db, fresh)) |oid| {
        if (missing_out) |out| out.* = oid;
        return error.MissingObject;
    }
    for (tips) |tip| {
        if ((try fresh.find(tip)) != null) continue;
        if (try db.exists(io, tip)) continue;
        if (missing_out) |out| out.* = tip;
        return error.MissingObject;
    }
}

/// `checkConnected`, with `options`.
pub fn checkConnectedWith(
    gpa: Allocator,
    io: Io,
    db: *Odb,
    tips: []const Oid,
    fresh: ?*const pack.Index,
    missing_out: ?*Oid,
    options: ConnectedOptions,
) Error!void {
    var seen: Oid.Set = .empty;
    defer seen.deinit(gpa);
    // A tree names its blobs as blobs: one is only looked for, never read,
    // as git's rev-list reads none.
    const Item = struct { oid: Oid, blob: bool = false };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    for (tips) |tip| try stack.append(gpa, .{ .oid = tip });
    while (stack.pop()) |item| {
        const oid = item.oid;
        if (seen.contains(oid)) continue;
        try seen.put(gpa, oid, {});
        const in_fresh = if (fresh) |index| (try index.find(oid)) != null else false;
        if (item.blob and in_fresh) continue;
        const walk_into = if (fresh == null) !item.blob else in_fresh;
        if (!walk_into) {
            if (!try db.exists(io, oid)) {
                // A tip is never promised; what the pack's objects name is.
                const is_tip = for (tips) |tip| {
                    if (tip.eql(oid)) break true;
                } else false;
                if (options.promisor and !is_tip) continue;
                if (missing_out) |out| out.* = oid;
                return error.MissingObject;
            }
            continue;
        }
        const found = db.read(io, oid) catch |err| switch (err) {
            error.ObjectNotFound => {
                if (missing_out) |out| out.* = oid;
                return error.MissingObject;
            },
            else => |e| return e,
        };
        defer db.gpa.free(found.bytes);
        switch (found.type) {
            .blob => {},
            .commit => {
                var commit = try object.Commit.parse(gpa, db.kind, found.bytes);
                defer commit.deinit();
                try stack.append(gpa, .{ .oid = commit.tree });
                for (revwalk.parentsOf(db, oid, commit.parents)) |parent| try stack.append(gpa, .{ .oid = parent });
            },
            .tag => {
                var tag = try object.Tag.parse(gpa, db.kind, found.bytes);
                defer tag.deinit();
                try stack.append(gpa, .{ .oid = tag.target });
            },
            .tree => {
                var entries = object.Tree.parse(db.kind, found.bytes).iterate();
                while (try entries.next()) |entry| switch (entry.mode) {
                    .gitlink => {},
                    .tree => try stack.append(gpa, .{ .oid = entry.oid }),
                    else => try stack.append(gpa, .{ .oid = entry.oid, .blob = true }),
                };
            },
        }
    }
}

const testing = std.testing;
const testgit = @import("testgit.zig");
const repo_mod = @import("repo.zig");

test "what is missing is what git rev-list --objects lists" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..6) |i| {
        var buf: [64]u8 = undefined;
        try repo.writeFile(io, "a.txt", try std.fmt.bufPrint(&buf, "version {d}\n", .{i}));
        try repo.writeFile(io, "dir/same.txt", "never changes\n");
        try repo.writeFile(io, try std.fmt.bufPrint(&buf, "dir/n{d}.txt", .{i % 3}), try std.fmt.bufPrint(&buf, "n {d}\n", .{i}));
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&buf, "c{d}", .{i}) });
        if (i == 1) try repo.exec(io, &.{ "branch", "side" });
    }
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.writeFile(io, "side.txt", "on the side\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "side" });
    try repo.exec(io, &.{ "tag", "-a", "t", "-m", "tag on side" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });

    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    const Case = struct { include: []const []const u8, exclude: []const []const u8 };
    const cases = [_]Case{
        .{ .include = &.{"main"}, .exclude = &.{} },
        .{ .include = &.{"main"}, .exclude = &.{"main~3"} },
        .{ .include = &.{ "main", "t" }, .exclude = &.{"side~1"} },
        .{ .include = &.{"t"}, .exclude = &.{"main"} },
        .{ .include = &.{"main"}, .exclude = &.{"main"} },
    };
    for (cases) |case| {
        var include: std.ArrayList(Oid) = .empty;
        defer include.deinit(gpa);
        var exclude: std.ArrayList(Oid) = .empty;
        defer exclude.deinit(gpa);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |o| gpa.free(o);
            owned.deinit(gpa);
        }
        try argv.appendSlice(gpa, &.{ "rev-list", "--objects" });
        for (case.include) |name| {
            const hex = try repo.line(io, &.{ "rev-parse", name });
            try owned.append(gpa, hex);
            try include.append(gpa, try Oid.parse(.sha1, hex));
            try argv.append(gpa, hex);
        }
        for (case.exclude) |name| {
            const hex = try repo.line(io, &.{ "rev-parse", name });
            try owned.append(gpa, hex);
            try exclude.append(gpa, try Oid.parse(.sha1, hex));
            const not = try std.fmt.allocPrint(gpa, "^{s}", .{hex});
            try owned.append(gpa, not);
            try argv.append(gpa, not);
        }
        const listed = try repo.run(io, argv.items);
        defer gpa.free(listed);
        var theirs: Oid.Set = .empty;
        defer theirs.deinit(gpa);
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        while (lines.next()) |line| try theirs.put(gpa, try Oid.parse(.sha1, line[0..40]), {});

        var ours = try missing(gpa, io, &opened.odb, include.items, exclude.items);
        defer ours.deinit();
        try testing.expectEqual(theirs.count(), ours.entries.len);
        for (ours.entries) |entry| try testing.expect(theirs.contains(entry.oid));
    }
}

test "a tip with an object missing below it is refused, and names the object" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const head_hex = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_hex);
    const blob_hex = try repo.line(io, &.{ "rev-parse", "HEAD:a.txt" });
    defer gpa.free(blob_hex);

    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    const head = try Oid.parse(.sha1, head_hex);
    try checkConnected(gpa, io, &opened.odb, &.{head}, null, null);

    const path = try std.fmt.allocPrint(gpa, ".git/objects/{s}/{s}", .{ blob_hex[0..2], blob_hex[2..] });
    defer gpa.free(path);
    try repo.dir.deleteFile(io, path);
    var gone: Oid = undefined;
    try testing.expectError(error.MissingObject, checkConnected(gpa, io, &opened.odb, &.{head}, null, &gone));
    try testing.expect(gone.eql(try Oid.parse(.sha1, blob_hex)));
}
