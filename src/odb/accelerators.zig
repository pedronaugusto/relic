//! Repository operations for commit-graphs, multi-pack indexes and reachability bitmaps.
//! Format encoding stays with each format; object traversal stays with the database.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash.zig");
const fs = @import("../repo/fs.zig");
const object = @import("../object.zig");
const odb = @import("../odb.zig");
const graph_mod = @import("commitgraph.zig");
const diff = @import("../diff.zig");
const Oid = hash.Oid;
const revwalk_mod = @import("../revwalk.zig");
const odb_open = @import("open.zig");

/// Failures leave the old accelerator published and release this writer's locks.
pub const Error = odb.Error || graph_mod.Error || diff.Error || fs.LockError || fs.CommitError ||
    Io.Dir.SetTimestampsError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError || Io.Dir.Iterator.Error || Io.Dir.StatFileError || error{ InvalidGraphInput, UnsupportedBloomVersion, InvalidBloomSettings, ShallowCommitGraph, CommitGraphCycle };

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

/// How a published file's permissions are left: git's commit-graphs and
/// bitmaps read-only, its multi-pack index as the umask leaves it, each then
/// as `core.sharedRepository` asks.
const Mode = enum { read_only, umask };

fn publish(gpa: Allocator, io: Io, db: *const odb.Odb, dir: Io.Dir, path: []const u8, bytes: []const u8, sync: fs.Sync, mode: Mode) (Allocator.Error || fs.LockError || fs.CommitError)!void {
    var buffer: [8192]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, dir, path, &buffer, .{ .sync = sync, .shared = db.sharedPermissions() });
    defer lock.deinit(io);
    try lock.writer().writeAll(bytes);
    try lock.commit(io);
    if (mode == .read_only) fs.readOnlyObject(io, dir, path, db.sharedPermissions());
}

fn collectGraphNodes(arena: Allocator, io: Io, db: *odb.Odb, pending: *std.ArrayList(Oid), seen: *Oid.Set, nodes: *std.ArrayList(GraphNode)) Error!void {
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
}

/// Write the commits reachable from `tips`, including their parents, as git does.
/// A split write keeps the older layers until the chain file is atomically replaced.
/// A shallow database is refused because its absent parents cannot form a graph.
pub fn writeCommitGraph(gpa: Allocator, io: Io, db: *odb.Odb, tips: []const Oid, options: CommitGraphOptions) Self.Error!?Oid {
    if (db.shallow.count() != 0) return error.ShallowCommitGraph;
    const dir = db.objectsDirectory();
    var old = try graph_mod.Graph.open(gpa, io, dir, db.objectFormat());
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
    try collectGraphNodes(arena, io, db, &pending, &seen, &nodes);
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
    const checksum = Oid.fromRaw(db.objectFormat(), bytes[bytes.len - db.objectFormat().rawLen() ..]) catch unreachable; // unreachable: the slice is the last raw length of bytes the encoder wrote
    try fs.makeDirs(io, dir, "info", db.sharedPermissions());
    if (options.split == .none) {
        try publish(gpa, io, db, dir, "info/commit-graph", bytes, options.sync, .read_only);
        try removeIfPresent(io, dir, "info/commit-graphs/commit-graph-chain");
    } else {
        try fs.makeDirs(io, dir, "info/commit-graphs", db.sharedPermissions());
        // Take the chain lock before writing layers. Its rename is the only
        // point at which a reader begins to see the new chain.
        var buffer: [8192]u8 = undefined;
        var chain_lock = try fs.LockFile.open(gpa, io, dir, "info/commit-graphs/commit-graph-chain", &buffer, .{ .sync = options.sync, .shared = db.sharedPermissions() });
        defer chain_lock.deinit(io);
        var hex_buffer: [hash.max_hex_len]u8 = undefined;
        if (retained) |base| {
            // A formerly monolithic graph becomes the first immutable layer.
            var bottom = base;
            while (bottom.base) |lower| bottom = lower;
            const name = try std.fmt.allocPrint(arena, "info/commit-graphs/graph-{s}.graph", .{bottom.checksum().hex(&hex_buffer)});
            try publish(gpa, io, db, dir, name, bottom.bytes, options.sync, .read_only);
        }
        const name = try std.fmt.allocPrint(arena, "info/commit-graphs/graph-{s}.graph", .{checksum.hex(&hex_buffer)});
        try publish(gpa, io, db, dir, name, bytes, options.sync, .read_only);
        try bases.append(arena, checksum);
        for (bases.items) |base| {
            try chain_lock.writer().writeAll(base.hex(&hex_buffer));
            try chain_lock.writer().writeByte('\n');
        }
        try chain_lock.commit(io);
        fs.readOnlyObject(io, dir, "info/commit-graphs/commit-graph-chain", db.sharedPermissions());
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
    var hex: [hash.max_hex_len]u8 = undefined;
    if (options.split != .none) {
        var previous = if (old) |*value| value else null;
        while (previous) |layer| : (previous = layer.base) {
            var kept = false;
            for (bases.items) |base| if (base.eql(layer.checksum())) {
                kept = true;
                break;
            };
            if (kept) continue;
            const filename = try std.fmt.allocPrint(arena, "graph-{s}.graph", .{layer.checksum().hex(&hex)});
            fs.setTimestamps(io, graph_dir, filename, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, now) * std.time.ns_per_s } } }) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
    var iterator = graph_dir.iterate();
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

const midx_mod = @import("midx.zig");
const pack_mod = @import("pack.zig");

/// A MIDX write's selection and reverse-order policy.
pub const MidxOptions = struct {
    preferred_pack: ?[]const u8 = null,
    reverse_index: bool = false,
    /// Keep a previous bitmap until writeMidxBitmap publishes its replacement.
    keep_bitmaps: bool = false,
    sync: fs.Sync = .none,
};

const PackInputs = struct {
    arena: std.heap.ArenaAllocator,
    packs: []midx_mod.WritePack,
    fn deinit(inputs: *PackInputs) void {
        inputs.arena.deinit();
        inputs.* = undefined;
    }
};

fn readPackInputs(gpa: Allocator, io: Io, dir: Io.Dir, kind: hash.Kind) MidxError!PackInputs {
    var result: PackInputs = .{ .arena = .init(gpa), .packs = &.{} };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var packs: std.ArrayList(midx_mod.WritePack) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "pack-") or !std.mem.endsWith(u8, entry.name, ".idx")) continue;
        var index = try pack_mod.Index.open(gpa, io, dir, entry.name, kind, 1 << 30);
        defer index.deinit();
        const base = entry.name[0 .. entry.name.len - 4];
        const pack_path = try std.fmt.allocPrint(arena, "{s}.pack", .{base});
        const stat = (try dir.statFile(io, pack_path, .{}));
        const objects = try arena.alloc(midx_mod.WriteEntry, index.count);
        for (objects, 0..) |*obj, i| obj.* = .{ .oid = index.nameAt(@intCast(i)), .offset = try index.offsetAt(@intCast(i)) };
        try packs.append(arena, .{ .name = try arena.dupe(u8, entry.name), .mtime = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)), .entries = objects });
    }
    result.packs = packs.items;
    return result;
}

/// Errors from selecting, publishing or expiring a multi-pack index.
pub const MidxError = odb.Error || midx_mod.Error || fs.LockError || fs.CommitError ||
    Io.Dir.Iterator.Error || Io.Dir.StatFileError || Io.Dir.DeleteFileError || error{ InvalidMidxInput, UnknownPreferredPack, EmptyPreferredPack };

/// Write the writable database's pack indexes into one MIDX. The digest names
/// a reachability bitmap; refreshing makes the database consult this index.
pub fn writeMidx(gpa: Allocator, io: Io, db: *odb.Odb, options: MidxOptions) Self.MidxError!?Oid {
    const dir = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
    defer dir.close(io);
    var inputs = try readPackInputs(gpa, io, dir, db.objectFormat());
    defer inputs.deinit();
    if (inputs.packs.len == 0) return null;
    // Existing MIDX entries have mtime zero in git's merge. New packs win
    // duplicates even when every filesystem timestamp falls in one second.
    if (try midx_mod.Index.open(gpa, io, dir, db.objectFormat())) |value| {
        var old = value;
        defer old.deinit();
        try old.verify();
        const arena = inputs.arena.allocator();
        var unchanged = inputs.packs.len == old.pack_count;
        for (inputs.packs) |p| {
            var present = false;
            for (0..old.pack_count) |i| if (std.mem.eql(u8, old.packName(@intCast(i)).?, p.name[0 .. p.name.len - 4])) {
                present = true;
                break;
            };
            unchanged = unchanged and present;
        }
        if (unchanged and (!options.reverse_index or (old.count > 0 and try old.reverseAt(0) != null))) {
            if (!options.keep_bitmaps) {
                try clearMidxBitmaps(gpa, io, dir, null);
                try db.refresh(io);
            }
            return old.checksum();
        }
        var preferred_name = options.preferred_pack;
        if (preferred_name == null and options.reverse_index) {
            var oldest: ?usize = null;
            for (inputs.packs, 0..) |p, i| if (p.entries.len != 0 and (oldest == null or p.mtime < inputs.packs[oldest.?].mtime)) {
                oldest = i;
            };
            if (oldest) |i| preferred_name = inputs.packs[i].name;
        }
        for (inputs.packs) |*p| {
            var old_position: ?u32 = null;
            for (0..old.pack_count) |i| if (std.mem.eql(u8, old.packName(@intCast(i)).?, p.name[0 .. p.name.len - 4])) {
                old_position = @intCast(i);
                break;
            };
            const pack_position = old_position orelse continue;
            p.previously_indexed = true;
            const preferred = if (preferred_name) |name| std.mem.startsWith(u8, name, p.name[0 .. p.name.len - 4]) else false;
            if (preferred) continue;
            var assigned: std.ArrayList(midx_mod.WriteEntry) = .empty;
            for (0..old.count) |i| {
                const located = try old.locate(@intCast(i));
                if (located.pack == pack_position) try assigned.append(arena, .{ .oid = old.nameAt(@intCast(i)), .offset = located.offset });
            }
            p.entries = assigned.items;
        }
    }
    const bytes = try midx_mod.encode(gpa, db.objectFormat(), inputs.packs, .{ .preferred_pack = options.preferred_pack, .reverse_index = options.reverse_index });
    defer gpa.free(bytes);
    // unreachable: the slice is the last raw length of bytes the encoder wrote
    const checksum = Oid.fromRaw(db.objectFormat(), bytes[bytes.len - db.objectFormat().rawLen() ..]) catch unreachable;
    try publish(gpa, io, db, dir, "multi-pack-index", bytes, options.sync, .umask);
    if (!options.keep_bitmaps) try clearMidxBitmaps(gpa, io, dir, null);
    try db.refresh(io);
    return checksum;
}

/// Remove packs to which the current MIDX assigns no objects, retaining .keep
/// and cruft (.mtimes) packs. This is git's separate expire step after repack.
pub fn expireMidx(gpa: Allocator, io: Io, db: *odb.Odb, sync: fs.Sync) Self.MidxError!u32 {
    const dir = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
    defer dir.close(io);
    var index = (try midx_mod.Index.open(gpa, io, dir, db.objectFormat())) orelse return 0;
    defer index.deinit();
    try index.verify();
    const counts = try gpa.alloc(u32, index.pack_count);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (0..index.count) |i| counts[(try index.locate(@intCast(i))).pack] += 1;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var removed: u32 = 0;
    // Close this process's pack handles before removing files, also on Windows.
    for (counts, 0..) |count, i| {
        if (count != 0) continue;
        const name = index.packName(@intCast(i)) orelse return error.CorruptMultiPackIndex;
        const keep = try std.fmt.allocPrint(arena, "{s}.keep", .{name});
        const cruft = try std.fmt.allocPrint(arena, "{s}.mtimes", .{name});
        if (try existsFile(io, dir, keep) or try existsFile(io, dir, cruft)) continue;
        for ([_][]const u8{ ".pack", ".idx", ".rev", ".bitmap" }) |extension| {
            const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, extension });
            try removeIfPresent(io, dir, path);
        }
        removed += 1;
    }
    if (removed > 0) _ = try writeMidx(gpa, io, db, .{ .sync = sync });
    return removed;
}

fn existsFile(io: Io, dir: Io.Dir, path: []const u8) Io.Dir.AccessError!bool {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

const bitmap_mod = @import("bitmap.zig");
const bitmap_store = @import("bitmap/reachability.zig");
const objectwalk = @import("../transport/objectwalk.zig");

/// How the optional bitmap extensions are written, with Git's defaults.
pub const BitmapOptions = struct {
    hash_cache: bool = true,
    /// Commits selected by pack.preferBitmapTips, supplied after ref-name matching.
    preferred_tips: []const Oid = &.{},
    lookup_table: bool = false,
    sync: fs.Sync = .none,
};
pub const BitmapError = Error || MidxError || revwalk_mod.Error || objectwalk.Error || bitmap_mod.Error || bitmap_store.Error || error{ InvalidBitmapInput, BitmapNotClosed };

fn storedBitmap(gpa: Allocator, io: Io, db: *odb.Odb) BitmapError!?bitmap_store.Store {
    return bitmap_store.Store.open(gpa, io, db.objectsDirectory(), db.objectFormat()) catch |err| {
        if (odb_open.readRefusal(err)) return err;
        return null;
    };
}

const BitmapCommit = struct {
    oid: Oid,
    position: u32,
    time: i64,
    parents: usize,
    needed: bool,
    fn newer(_: void, a: BitmapCommit, b: BitmapCommit) bool {
        return a.time > b.time;
    }
    fn older(_: void, a: BitmapCommit, b: BitmapCommit) bool {
        return a.time < b.time;
    }
};

fn selectedCommits(arena: Allocator, candidates: []BitmapCommit) Allocator.Error![]BitmapCommit {
    std.mem.sort(BitmapCommit, candidates, {}, BitmapCommit.newer);
    var selected: std.ArrayList(BitmapCommit) = .empty;
    if (candidates.len < 100) try selected.appendSlice(arena, candidates) else {
        var i: usize = 0;
        while (i < candidates.len) {
            const next: usize = if (i <= 100) 0 else if (i <= 20000) @min(i - 100, 100) else @max(@min(i - 20000, 5000), 100);
            if (i + next >= candidates.len) break;
            var chosen = candidates[i + next];
            for (candidates[i .. i + next + 1]) |candidate| {
                if (candidate.needed) {
                    chosen = candidate;
                    break;
                }
                if (candidate.parents > 1) chosen = candidate;
            }
            try selected.append(arena, chosen);
            i += next + 1;
        }
    }
    std.mem.sort(BitmapCommit, selected.items, {}, BitmapCommit.older);
    return selected.items;
}

fn buildBitmap(gpa: Allocator, io: Io, db: *odb.Odb, checksum: Oid, names: []const Oid, reverse: []const u32, tips: []const Oid, options: BitmapOptions, midx_bitmap: bool, previous_bitmap: ?*const bitmap_store.Store) BitmapError![]u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var positions: Oid.Map(u32) = .empty;
    for (reverse, 0..) |pos, i| try positions.put(arena, names[pos], @intCast(i));
    var needed: Oid.Set = .empty;
    for (options.preferred_tips) |oid| try needed.put(arena, oid, {});
    const word_count = (names.len + 63) / 64;
    var types: [4][]u64 = undefined;
    for (&types) |*words| {
        words.* = try arena.alloc(u64, word_count);
        @memset(words.*, 0);
    }
    var previous_positions: ?[]u32 = null;
    if (previous_bitmap) |previous| {
        previous_positions = try arena.alloc(u32, previous.reverse.len);
        // Resolve names once, as Git's bitmap mapping does. Every selected
        // bitmap can then translate a bit with one array lookup.
        for (previous.reverse, 0..) |old_name_position, old_position| {
            const pos = positions.get(previous.names[old_name_position]) orelse std.math.maxInt(u32);
            previous_positions.?[old_position] = pos;
            if (pos == std.math.maxInt(u32)) continue;
            const kind_index: usize = switch (previous.typeAt(@intCast(old_position))) {
                .commit => 0,
                .tree => 1,
                .blob => 2,
                .tag => 3,
            };
            setBit(types[kind_index], pos);
        }
    }
    var candidates: std.ArrayList(BitmapCommit) = .empty;
    for (names) |oid| {
        const pos = positions.get(oid).?;
        var known = false;
        for (types) |words| known = known or bitmap_mod.isSet(words, pos);
        if (known) continue;
        const header = try db.readHeader(io, oid);
        const kind_index: usize = switch (header.type) {
            .commit => 0,
            .tree => 1,
            .blob => 2,
            .tag => 3,
        };
        setBit(types[kind_index], pos);
    }
    var name_positions: Oid.Map(u32) = .empty;
    for (names, 0..) |oid, i| try name_positions.put(arena, oid, @intCast(i));
    var walk = revwalk_mod.Walk.init(gpa, db);
    defer walk.deinit();
    for (tips) |tip_oid| {
        var oid = tip_oid;
        var depth: usize = 0;
        while ((try db.readHeader(io, oid)).type == .tag) {
            if (depth >= 16) return error.InvalidBitmapInput;
            const found = try db.read(io, oid);
            defer db.allocator().free(found.bytes);
            var tag = try object.Tag.parse(gpa, db.objectFormat(), found.bytes);
            defer tag.deinit();
            oid = tag.target;
            depth += 1;
        }
        if ((try db.readHeader(io, oid)).type == .commit) try walk.push(oid);
    }
    while (try walk.next(io)) |commit| {
        const pos = name_positions.get(commit.oid) orelse continue;
        try candidates.append(arena, .{ .oid = commit.oid, .position = pos, .time = commit.time, .parents = commit.parents.len, .needed = needed.contains(commit.oid) });
    }
    const selected = try selectedCommits(arena, candidates.items);
    var cache: Oid.Map([]const u64) = .empty;
    var entries: std.ArrayList(bitmap_mod.WriteCommit) = .empty;
    var pending: std.ArrayList(Oid) = .empty;
    for (selected) |candidate| {
        const words = try arena.alloc(u64, word_count);
        @memset(words, 0);
        var reused = false;
        if (previous_bitmap) |previous| if (try previous.reach(gpa, candidate.oid)) |old_words| {
            defer gpa.free(old_words);
            for (old_words, 0..) |word, i| {
                var remaining = word;
                while (remaining != 0) {
                    const old_position: u32 = @intCast(i * 64 + @ctz(remaining));
                    const pos = previous_positions.?[old_position];
                    if (pos == std.math.maxInt(u32)) return error.BitmapNotClosed;
                    setBit(words, pos);
                    remaining &= remaining - 1;
                }
            }
            reused = true;
        };
        if (!reused) try pending.append(arena, candidate.oid);
        while (pending.pop()) |oid| {
            const pos = positions.get(oid) orelse return error.BitmapNotClosed;
            if (bitmap_mod.isSet(words, pos)) continue;
            if (cache.get(oid)) |previous| {
                for (words, previous) |*word, base| word.* |= base;
                continue;
            }
            setBit(words, pos);
            const header = try db.readHeader(io, oid);
            if (header.type == .blob) continue;
            const found = try db.read(io, oid);
            defer db.allocator().free(found.bytes);
            switch (header.type) {
                .commit => {
                    var commit = try object.Commit.parse(gpa, db.objectFormat(), found.bytes);
                    defer commit.deinit();
                    // Parents run before trees, so a cached ancestor can
                    // exclude its unchanged subtrees without reading them.
                    try pending.append(arena, commit.tree);
                    try pending.appendSlice(arena, commit.parents);
                },
                .tree => {
                    var iterator = object.Tree.parse(db.objectFormat(), found.bytes).iterate();
                    while (try iterator.next()) |entry| if (entry.mode != .gitlink) {
                        try pending.append(arena, entry.oid);
                    };
                },
                .tag => {
                    var tag = try object.Tag.parse(gpa, db.objectFormat(), found.bytes);
                    defer tag.deinit();
                    try pending.append(arena, tag.target);
                },
                .blob => unreachable,
            }
        }
        try cache.put(arena, candidate.oid, words);
        try entries.append(arena, .{ .position = candidate.position, .words = words });
    }
    var hashes: ?[]u32 = null;
    if (options.hash_cache) {
        hashes = try arena.alloc(u32, names.len);
        @memset(hashes.?, 0);
        if (midx_bitmap) {
            // Git carries existing cache entries when mapping an earlier bitmap
            // into MIDX order; otherwise the MIDX writer has no path strings.
            if (previous_bitmap) |previous| {
                for (previous.names, 0..) |oid, i| if (name_positions.get(oid)) |pos| {
                    hashes.?[pos] = previous.bitmap.nameHashAt(@intCast(i)) orelse 0;
                };
            }
        } else {
            var collected = try objectwalk.missingWith(gpa, io, db, tips, &.{}, .{ .use_bitmaps = false });
            defer collected.deinit();
            for (collected.entries) |entry| if (name_positions.get(entry.oid)) |pos| {
                hashes.?[pos] = bitmap_mod.nameHash(entry.hint);
            };
        }
    }
    return bitmap_mod.encode(gpa, db.objectFormat(), checksum, .{ types[0], types[1], types[2], types[3] }, entries.items, .{ .hash_cache = hashes, .lookup_table = options.lookup_table });
}

fn setBit(words: []u64, pos: u32) void {
    words[pos / 64] |= @as(u64, 1) << @as(u6, @intCast(pos % 64));
}

/// Write a reachability bitmap for an existing pack. The pack must contain the
/// entire history of every commit it holds, as Git's FULL_DAG flag requires.
pub fn writePackBitmap(gpa: Allocator, io: Io, db: *odb.Odb, pack_name: []const u8, tips: []const Oid, options: BitmapOptions) Self.BitmapError!void {
    if (std.mem.indexOfAny(u8, pack_name, "/\\") != null or !std.mem.startsWith(u8, pack_name, "pack-")) return error.InvalidBitmapInput;
    const base = if (std.mem.endsWith(u8, pack_name, ".pack")) pack_name[0 .. pack_name.len - 5] else if (std.mem.endsWith(u8, pack_name, ".idx")) pack_name[0 .. pack_name.len - 4] else pack_name;
    const dir = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
    defer dir.close(io);
    const path = try std.fmt.allocPrint(gpa, "{s}.idx", .{base});
    defer gpa.free(path);
    var index = try pack_mod.Index.open(gpa, io, dir, path, db.objectFormat(), 1 << 30);
    defer index.deinit();
    const names = try gpa.alloc(Oid, index.count);
    defer gpa.free(names);
    const reverse = try gpa.alloc(u32, index.count);
    defer gpa.free(reverse);
    const offsets = try gpa.alloc(u64, index.count);
    defer gpa.free(offsets);
    for (names, reverse, offsets, 0..) |*oid, *pos, *offset, i| {
        oid.* = index.nameAt(@intCast(i));
        pos.* = @intCast(i);
        offset.* = try index.offsetAt(@intCast(i));
    }
    const Order = struct {
        fn less(context: []const u64, a: u32, b: u32) bool {
            return context[a] < context[b];
        }
    };
    std.mem.sort(u32, reverse, offsets, Order.less);
    // The writer owns this data across any implicit database refresh.
    var previous = try storedBitmap(gpa, io, db);
    defer if (previous) |*value| value.deinit();
    const bytes = try buildBitmap(gpa, io, db, index.pack_checksum, names, reverse, tips, options, false, if (previous) |*value| value else null);
    defer gpa.free(bytes);
    const target = try std.fmt.allocPrint(gpa, "{s}.bitmap", .{base});
    defer gpa.free(target);
    try publish(gpa, io, db, dir, target, bytes, options.sync, .read_only);
    try db.refresh(io);
}

/// Write a MIDX with RIDX and BTMP, then the bitmap named by its checksum.
pub fn writeMidxBitmap(gpa: Allocator, io: Io, db: *odb.Odb, tips: []const Oid, midx_options: MidxOptions, options: BitmapOptions) Self.BitmapError!?Oid {
    var write_options = midx_options;
    write_options.reverse_index = true;
    write_options.keep_bitmaps = true;
    const checksum = (try writeMidx(gpa, io, db, write_options)) orelse return null;
    // Git leaves an unchanged MIDX and its valid existing bitmap alone, even
    // when the writer's extension settings have changed since publication.
    var previous = try storedBitmap(gpa, io, db);
    defer if (previous) |*value| value.deinit();
    if (previous) |value| if (value.bitmap.checksum.eql(checksum)) return checksum;
    const dir = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
    defer dir.close(io);
    var index = (try midx_mod.Index.open(gpa, io, dir, db.objectFormat())).?;
    defer index.deinit();
    const names = try gpa.alloc(Oid, index.count);
    defer gpa.free(names);
    const reverse = try gpa.alloc(u32, index.count);
    defer gpa.free(reverse);
    for (names, reverse, 0..) |*oid, *pos, i| {
        oid.* = index.nameAt(@intCast(i));
        pos.* = (try index.reverseAt(@intCast(i))).?;
    }
    const bytes = try buildBitmap(gpa, io, db, checksum, names, reverse, tips, options, true, if (previous) |*value| value else null);
    defer gpa.free(bytes);
    var hex: [hash.max_hex_len]u8 = undefined;
    const path = try std.fmt.allocPrint(gpa, "multi-pack-index-{s}.bitmap", .{checksum.hex(&hex)});
    defer gpa.free(path);
    try publish(gpa, io, db, dir, path, bytes, options.sync, .read_only);
    try clearMidxBitmaps(gpa, io, dir, path);
    try db.refresh(io);
    return checksum;
}

/// Git's MIDX repack selection. Zero batch size selects all eligible packs;
/// a nonzero batch takes older packs whose estimated live size is below it.
pub const MidxRepackOptions = struct {
    batch_size: u64 = 0,
    pack_kept_objects: bool = false,
    pack: odb.PackOptions = .{},
    sync: fs.Sync = .none,
};

/// Repack objects assigned to at least two eligible MIDX packs. Old packs stay
/// until expireMidx, matching git's separate repack and expire subcommands.
pub fn repackMidx(gpa: Allocator, io: Io, db: *odb.Odb, options: MidxRepackOptions) Self.MidxError!?pack_mod.WriteReport {
    const dir = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
    defer dir.close(io);
    var index = (try midx_mod.Index.open(gpa, io, dir, db.objectFormat())) orelse return null;
    defer index.deinit();
    try index.verify();
    var inputs = try readPackInputs(gpa, io, dir, db.objectFormat());
    defer inputs.deinit();
    const arena = inputs.arena.allocator();
    const referenced = try arena.alloc(u32, index.pack_count);
    @memset(referenced, 0);
    for (0..index.count) |i| referenced[(try index.locate(@intCast(i))).pack] += 1;
    const eligible = try arena.alloc(bool, index.pack_count);
    @memset(eligible, false);
    const sizes = try arena.alloc(u64, index.pack_count);
    @memset(sizes, 0);
    const mtimes = try arena.alloc(i64, index.pack_count);
    @memset(mtimes, 0);
    for (0..index.pack_count) |i| {
        const base = index.packName(@intCast(i)) orelse return error.CorruptMultiPackIndex;
        const keep = try std.fmt.allocPrint(arena, "{s}.keep", .{base});
        const cruft = try std.fmt.allocPrint(arena, "{s}.mtimes", .{base});
        if ((!options.pack_kept_objects and try existsFile(io, dir, keep)) or try existsFile(io, dir, cruft)) continue;
        const path = try std.fmt.allocPrint(arena, "{s}.pack", .{base});
        const stat = try dir.statFile(io, path, .{});
        for (inputs.packs) |p| if (std.mem.eql(u8, p.name[0 .. p.name.len - 4], base) and p.entries.len != 0) {
            eligible[i] = true;
            mtimes[i] = p.mtime;
            const fraction = (@as(u64, referenced[i]) << 14) / p.entries.len;
            sizes[i] = ((fraction * stat.size) + (1 << 13)) >> 14;
            break;
        };
    }
    const order = try arena.alloc(u32, index.pack_count);
    for (order, 0..) |*p, i| p.* = @intCast(i);
    const Order = struct {
        fn less(times: []const i64, a: u32, b: u32) bool {
            return times[a] < times[b];
        }
    };
    std.mem.sort(u32, order, mtimes, Order.less);
    const selected = try arena.alloc(bool, index.pack_count);
    @memset(selected, false);
    var total: u64 = 0;
    var count_packs: usize = 0;
    for (order) |p| {
        if (options.batch_size != 0 and total >= options.batch_size) break;
        if (!eligible[p] or (options.batch_size != 0 and sizes[p] >= options.batch_size)) continue;
        selected[p] = true;
        count_packs += 1;
        total = std.math.add(u64, total, sizes[p]) catch std.math.maxInt(u64);
    }
    if (count_packs <= 1) return null;
    var entries: std.ArrayList(odb.PackEntry) = .empty;
    for (0..index.count) |i| if (selected[(try index.locate(@intCast(i))).pack]) {
        try entries.append(arena, .{ .oid = index.nameAt(@intCast(i)), .in_pack = true });
    };
    const written = try db.writePack(io, dir, entries.items, options.pack);
    try db.refresh(io);
    _ = try writeMidx(gpa, io, db, .{ .sync = options.sync });
    return written;
}

const repo_mod = @import("../repo.zig");
const config_mod = @import("../config.zig");

/// Failures while applying a repository's accelerator configuration.
pub const MaintenanceError = BitmapError || repo_mod.Error || config_mod.ValueError || error{ UnsupportedGenerationVersion, ReplacedCommitGraph };

/// The purpose selects Git's writeCommitGraph key and default.
pub const Maintenance = enum { gc, fetch };

fn repositoryTips(gpa: Allocator, io: Io, repo: *repo_mod.Repository) repo_mod.Error![]Oid {
    var listed = try repo.refStore().list(gpa, io, "refs/");
    defer listed.deinit();
    var tips: std.ArrayList(Oid) = .empty;
    errdefer tips.deinit(gpa);
    for (listed.entries) |entry| {
        const oid = switch (entry.target) {
            .direct => |oid| oid,
            .symbolic => blk: {
                const resolved = (try repo.refStore().resolve(gpa, io, entry.name)) orelse continue;
                defer gpa.free(resolved.name);
                break :blk resolved.oid;
            },
        };
        const peeled = try repo.peel(io, oid);
        if ((try repo.odb.readHeader(io, peeled)).type == .commit) try tips.append(gpa, peeled);
    }
    return tips.toOwnedSlice(gpa);
}

/// Apply gc.writeCommitGraph (default true) or fetch.writeCommitGraph (default false).
/// Fetch uses split chains; gc publishes a full graph. A shallow repository is skipped,
/// as Git skips it, and replace refs are refused by name.
pub fn writeConfiguredCommitGraph(gpa: Allocator, io: Io, repo: *repo_mod.Repository, purpose: Maintenance) Self.MaintenanceError!?Oid {
    const config = repo.configuration();
    if (!try config.getBool(if (purpose == .gc) "gc.writecommitgraph" else "fetch.writecommitgraph", purpose == .gc)) return null;
    if (repo.odb.shallow.count() != 0) return null;
    var replaced = try repo.refStore().list(gpa, io, "refs/replace/");
    defer replaced.deinit();
    if (replaced.entries.len != 0) return error.ReplacedCommitGraph;
    const generation_version = try config.getInt("commitgraph.generationversion", 2);
    if (generation_version != 1 and generation_version != 2) return error.UnsupportedGenerationVersion;
    const tips = try repositoryTips(gpa, io, repo);
    defer gpa.free(tips);
    var settings: ?graph_mod.bloom.Settings = null;
    var old = try graph_mod.Graph.open(gpa, io, repo.odb.objectsDirectory(), repo.objectFormat());
    defer if (old) |*g| g.deinit();
    if (old) |*g| if (g.count > 0) if (try g.changedPaths(g.count - 1)) |filter| {
        settings = filter.settings;
    };
    if (settings) |*value| {
        const version = try config.getInt("commitgraph.changedpathsversion", value.version);
        if (version != 1 and version != 2) return error.UnsupportedBloomVersion;
        value.version = @intCast(version);
    }
    return writeCommitGraph(gpa, io, &repo.odb, tips, .{ .split = if (purpose == .fetch) .merge else .none, .generations = generation_version == 2, .changed_paths = settings, .sync = repo.odb.settings().sync });
}

/// Repack the repository and apply its bitmap and gc.writeCommitGraph policies.
/// Object retention is the caller's RepackOptions; this hook does not prune refs or reflogs.
pub fn repackRepository(gpa: Allocator, io: Io, repo: *repo_mod.Repository, options: odb.Odb.RepackOptions) Self.MaintenanceError!odb.Odb.RepackReport {
    const report = try repo.odb.repack(io, options);
    const config = repo.configuration();
    if (report.written) |written| if (try config.getBool("repack.writebitmaps", true)) {
        const tips = try repositoryTips(gpa, io, repo);
        defer gpa.free(tips);
        var hex: [hash.max_hex_len]u8 = undefined;
        const name = try std.fmt.allocPrint(gpa, "pack-{s}", .{written.name.hex(&hex)});
        defer gpa.free(name);
        try writePackBitmap(gpa, io, &repo.odb, name, tips, .{ .hash_cache = try config.getBool("pack.writebitmaphashcache", true), .lookup_table = try config.getBool("pack.writebitmaplookuptable", false), .sync = repo.odb.settings().sync });
    };
    _ = try writeConfiguredCommitGraph(gpa, io, repo, .gc);
    return report;
}

fn clearMidxBitmaps(gpa: Allocator, io: Io, dir: Io.Dir, keep: ?[]const u8) MidxError!void {
    _ = gpa;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "multi-pack-index-") or !std.mem.endsWith(u8, entry.name, ".bitmap")) continue;
        if (keep) |name| if (std.mem.eql(u8, name, entry.name)) continue;
        try removeIfPresent(io, dir, entry.name);
    }
}
