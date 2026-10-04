//! Repository operations for commit-graphs, multi-pack indexes and reachability bitmaps.
//! Format encoding stays with each format; object traversal stays with the database.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("hash.zig");
const fs = @import("fs.zig");
const object = @import("object_core.zig");
const odb = @import("odb_core.zig");
const graph_mod = @import("commitgraph.zig");
const diff = @import("diff_core.zig");
const Oid = hash.Oid;

/// Failures leave the old accelerator published and release this writer's locks.
pub const Error = odb.Error || graph_mod.Error || diff.Error || fs.LockError || fs.CommitError ||
    Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError || Io.Dir.Iterator.Error || Io.Dir.StatFileError || error{ InvalidGraphInput, UnsupportedBloomVersion, InvalidBloomSettings, ShallowCommitGraph, CommitGraphCycle };

/// Git's split-chain merge modes.
pub const Split = enum { none, merge, no_merge, replace };

/// How a graph is gathered and published.
pub const CommitGraphOptions = struct {
    split: Split = .none,
    size_multiple: u32 = 2,
    max_commits: u32 = 0,
    /// Inactive layers at or before this Unix time expire; null uses Git's current-time default.
    expire_time: ?i64 = null,
    generations: bool = true,
    changed_paths: ?graph_mod.bloom.Settings = null,
    /// Existing commits are retained, as in git without --split=replace.
    append: bool = true,
    sync: fs.Sync = .none,
};

const GraphNode = struct {
    oid: Oid,
    tree: Oid,
    parents: []const Oid,
    time: u64,
    level: u32 = 0,
    generation: u64 = 0,
    visiting: bool = false,

    fn byName(_: void, a: GraphNode, b: GraphNode) bool {
        return a.oid.order(b.oid) == .lt;
    }
};

fn publish(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8, sync: fs.Sync) (Allocator.Error || fs.LockError || fs.CommitError)!void {
    var buffer: [8192]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, dir, path, &buffer, .{ .sync = sync });
    defer lock.deinit(io);
    try lock.writer().writeAll(bytes);
    try lock.commit(io);
}

/// Write the commits reachable from `tips`, including their parents, as git does.
/// A split write keeps the older layers until the chain file is atomically replaced.
/// A shallow database is refused because its absent parents cannot form a graph.
pub fn writeCommitGraph(gpa: Allocator, io: Io, db: *odb.Odb, tips: []const Oid, options: CommitGraphOptions) Error!?Oid {
    if (db.shallow.count() != 0) return error.ShallowCommitGraph;
    const dir = db.objectsDirectory();
    var old = graph_mod.Graph.open(gpa, io, dir, db.objectFormat()) catch |err| {
        std.debug.print("open old graph: {s}\n", .{@errorName(err)});
        return err;
    };
    defer if (old) |*g| g.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var nodes: std.ArrayList(GraphNode) = .empty;
    var seen: Oid.Set = .empty;
    var pending: std.ArrayList(Oid) = .empty;
    try pending.appendSlice(arena, tips);
    if (old) |*g| if (options.append and options.split != .replace) {
        for (0..g.count) |i| try pending.append(arena, g.nameAt(@intCast(i)));
    };
    while (pending.pop()) |oid| {
        if ((try seen.getOrPut(arena, oid)).found_existing) continue;
        const found = try db.read(io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type == .tag) {
            var tag = try object.Tag.parse(arena, db.objectFormat(), found.bytes);
            defer tag.deinit();
            try pending.append(arena, tag.target);
            continue;
        }
        if (found.type != .commit) continue;
        var commit = try object.Commit.parse(arena, db.objectFormat(), found.bytes);
        defer commit.deinit();
        if (commit.committer.when_secs < 0) return error.InvalidGraphInput;
        const parents = try arena.dupe(Oid, commit.parents);
        try nodes.append(arena, .{ .oid = oid, .tree = commit.tree, .parents = parents, .time = @intCast(commit.committer.when_secs) });
        try pending.appendSlice(arena, parents);
    }
    if (nodes.items.len == 0) return null;
    std.mem.sort(GraphNode, nodes.items, {}, GraphNode.byName);
    var by_name: Oid.Map(usize) = .empty;
    for (nodes.items, 0..) |node, i| try by_name.put(arena, node.oid, i);
    // Compute both generations without recursion: a long first-parent history
    // costs a bounded heap stack, not one machine stack frame per commit.
    var stack: std.ArrayList(usize) = .empty;
    for (nodes.items, 0..) |_, i| {
        if (nodes.items[i].level != 0) continue;
        try stack.append(arena, i);
        while (stack.items.len != 0) {
            const at = stack.items[stack.items.len - 1];
            const node = &nodes.items[at];
            node.visiting = true;
            var wait = false;
            var level: u32 = 1;
            var generation = @max(node.time, 1);
            for (node.parents) |parent_name| {
                const parent = &nodes.items[by_name.get(parent_name) orelse return error.InvalidGraphInput];
                if (parent.level == 0) {
                    if (parent.visiting) return error.CommitGraphCycle;
                    try stack.append(arena, by_name.get(parent_name).?);
                    wait = true;
                    break;
                }
                level = @max(level, @min(parent.level + 1, 0x3fff_ffff));
                generation = @max(generation, parent.generation + 1);
            }
            if (wait) continue;
            node.level = level;
            node.generation = generation;
            node.visiting = false;
            _ = stack.pop();
        }
    }
    var retained: ?*const graph_mod.Graph = null;
    if (options.split != .none and options.split != .replace and options.append) {
        if (old) |*g| retained = g;
        var new_count = nodes.items.len - (if (retained) |g| g.count else @as(usize, 0));
        if (new_count == 0) return if (old) |*g| g.checksum() else null;
        if (options.split == .merge) while (retained) |g| {
            const multiple = if (options.size_multiple == 0) 2 else options.size_multiple;
            if (g.local_count > @as(u64, multiple) * new_count and (options.max_commits == 0 or new_count <= options.max_commits)) break;
            new_count += g.local_count;
            retained = g.base;
        };
    }
    const base_count = if (retained) |g| g.count else 0;
    var selected: std.ArrayList(GraphNode) = .empty;
    for (nodes.items) |node| {
        if (retained) |g| if (g.find(node.oid)) |pos| {
            if (pos < base_count) continue;
        };
        try selected.append(arena, node);
    }
    var positions: Oid.Map(u32) = .empty;
    for (selected.items, 0..) |node, i| try positions.put(arena, node.oid, base_count + @as(u32, @intCast(i)));
    var inputs: std.ArrayList(graph_mod.WriteCommit) = .empty;
    for (selected.items) |node| {
        const parents = try arena.alloc(u32, node.parents.len);
        for (node.parents, parents) |parent, *position| position.* = positions.get(parent) orelse (if (retained) |g| g.find(parent) else null) orelse return error.InvalidGraphInput;
        var changed: []const u8 = &.{};
        if (options.changed_paths) |settings| {
            const parent_tree: ?Oid = if (node.parents.len == 0) null else nodes.items[by_name.get(node.parents[0]).?].tree;
            var changes = try diff.tree(gpa, io, db, parent_tree, node.tree, .{});
            defer changes.deinit();
            const paths = try arena.alloc([]const u8, changes.items.len);
            for (changes.items, paths) |change, *path| path.* = change.path();
            changed = try graph_mod.bloom.build(arena, paths, settings);
        }
        try inputs.append(arena, .{ .oid = node.oid, .tree = node.tree, .parents = parents, .time = node.time, .level = node.level, .generation = node.generation, .changed_paths = changed });
    }
    var bases: std.ArrayList(Oid) = .empty;
    var g = retained;
    while (g) |base| : (g = base.base) try bases.append(arena, base.checksum());
    std.mem.reverse(Oid, bases.items);
    const bytes = try graph_mod.encode(gpa, db.objectFormat(), inputs.items, .{ .generations = options.generations and (if (retained) |base| base.hasGenerations() else true), .changed_paths = options.changed_paths, .bases = bases.items });
    defer gpa.free(bytes);
    const checksum = Oid.fromRaw(db.objectFormat(), bytes[bytes.len - db.objectFormat().rawLen() ..]) catch unreachable;
    try dir.createDirPath(io, "info");
    if (options.split == .none) {
        try publish(gpa, io, dir, "info/commit-graph", bytes, options.sync);
        try removeIfPresent(io, dir, "info/commit-graphs/commit-graph-chain");
    } else {
        try dir.createDirPath(io, "info/commit-graphs");
        // Take the chain lock before writing layers. Its rename is the only
        // point at which a reader begins to see the new chain.
        var buffer: [8192]u8 = undefined;
        var chain_lock = try fs.LockFile.open(gpa, io, dir, "info/commit-graphs/commit-graph-chain", &buffer, .{ .sync = options.sync });
        defer chain_lock.deinit(io);
        var hex_buffer: [hash.max_hex_len]u8 = undefined;
        if (retained) |base| {
            // A formerly monolithic graph becomes the first immutable layer.
            var bottom = base;
            while (bottom.base) |lower| bottom = lower;
            const name = try std.fmt.allocPrint(arena, "info/commit-graphs/graph-{s}.graph", .{bottom.checksum().hex(&hex_buffer)});
            try publish(gpa, io, dir, name, bottom.bytes, options.sync);
        }
        const name = try std.fmt.allocPrint(arena, "info/commit-graphs/graph-{s}.graph", .{checksum.hex(&hex_buffer)});
        try publish(gpa, io, dir, name, bytes, options.sync);
        try bases.append(arena, checksum);
        for (bases.items) |base| {
            try chain_lock.writer().writeAll(base.hex(&hex_buffer));
            try chain_lock.writer().writeByte('\n');
        }
        try chain_lock.commit(io);
        try removeIfPresent(io, dir, "info/commit-graph");
    }
    // Git marks merged-out layers at this write's time, then expires
    // inactive layers no newer than expire_time. Keep future-dated files.
    const now = Io.Clock.real.now(io).toSeconds();
    const expiry = options.expire_time orelse now;
    const graph_dir = dir.openDir(io, "info/commit-graphs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return checksum,
        else => return err,
    };
    defer graph_dir.close(io);
    var iterator = graph_dir.iterate();
    var hex: [hash.max_hex_len]u8 = undefined;
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "graph-") or !std.mem.endsWith(u8, entry.name, ".graph")) continue;
        const name = entry.name[6 .. entry.name.len - 6];
        var active = options.split != .none and std.mem.eql(u8, name, checksum.hex(&hex));
        for (bases.items) |base| if (options.split != .none and std.mem.eql(u8, name, base.hex(&hex))) {
            active = true;
            break;
        };
        if (active) continue;
        const stat = try graph_dir.statFile(io, entry.name, .{});
        const mtime = @divFloor(stat.mtime.nanoseconds, std.time.ns_per_s);
        if (mtime <= expiry) try removeIfPresent(io, graph_dir, entry.name);
    }
    return checksum;
}

fn removeIfPresent(io: Io, dir: Io.Dir, path: []const u8) Io.Dir.DeleteFileError!void {
    dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

