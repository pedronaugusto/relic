//! The multi-pack index, read and encoded as an accelerator.
//!
//! It answers one question faster — which pack holds an object, when there
//! are many packs — and nothing depends on it. A repository that has one must
//! read the same when it is ignored, so this is only ever consulted before
//! the per-pack indexes, never instead of them.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const Rows = @import("../codec.zig").Rows;

const Oid = hash.Oid;

/// The four bytes a multi-pack index begins with.
pub const magic = "MIDX";

/// Errors from reading a multi-pack index.
pub const Error = error{
    /// The file did not begin `MIDX`.
    NotAMultiPackIndex,
    /// A version this release does not read.
    UnsupportedMidxVersion,
    /// The hash it was built with is not the repository's.
    ObjectFormatMismatch,
    /// A chunk ran off the end, or a required chunk is missing.
    CorruptMultiPackIndex,
    /// A chain of multi-pack indexes. This release reads one.
    ChainUnsupported,
} || Allocator.Error || aegis.own.ReadFileError;

/// Errors from reading a position in a held index: the file names a row
/// past one of its own tables.
pub const PositionError = error{CorruptMultiPackIndex};

/// Where an object lives.
pub const Located = struct {
    /// Which pack, as a position in `packNames`.
    pack: u32,
    offset: u64,
};

/// The pack names a multi-pack index holds: as many as its header counts,
/// fewer where its `PNAM` chunk ends first.
pub const PackNames = struct {
    split: std.mem.SplitIterator(u8, .scalar),
    /// How many the header counts.
    count: u32,
    /// How many `next` has given.
    taken: u32 = 0,

    /// The next name, without its extension, or `null` after the last.
    pub fn next(names: *PackNames) ?[]const u8 {
        if (names.taken == names.count) return null;
        var name = names.split.next() orelse return null;
        // What follows the last NUL is padding, never a name.
        if (names.split.index == null) return null;
        names.taken += 1;
        if (std.mem.endsWith(u8, name, ".idx")) name = name[0 .. name.len - 4];
        if (std.mem.endsWith(u8, name, ".pack")) name = name[0 .. name.len - 5];
        return name;
    }
};

/// A multi-pack index, held in memory.
pub const Index = struct {
    pub const Error = ErrorNamespace.Error;
    pub const PositionError = ErrorNamespace.PositionError;

    gpa: Allocator,
    kind: hash.Kind,
    /// The file, which the index owns and the tables below are cut from.
    bytes: []const u8,
    /// How many objects it covers: the rows of `oids`.
    count: u32,
    /// How many packs it covers.
    pack_count: u32,
    /// The pack names, NUL-terminated, in the order positions name them.
    pack_names: []const u8,
    /// How many names begin with a byte up to each byte.
    fanout_table: *const [256][4]u8,
    /// One name per object, in name order.
    oids: Rows,
    /// One row per object: its pack's position and its 4-byte offset.
    offsets: Rows,
    /// 8-byte offsets, which a 4-byte one with its high bit set names by
    /// row, where the index has a `LOFF` chunk. Without one, a 4-byte
    /// offset is the offset whatever its high bit, as git reads it.
    large: ?Rows,
    /// Name-order positions in pseudo-pack order, where the index has a
    /// `RIDX` chunk.
    reverse: ?Rows,

    /// `open`, with an index that does not read as one taken as no index:
    /// it is an accelerator, the database reads the same without it, and a
    /// writer replaces it. A refusal to read the file is still an error.
    pub fn openUsable(gpa: Allocator, io: Io, pack_dir: Io.Dir, kind: hash.Kind) Self.Error!?Index {
        return open(gpa, io, pack_dir, kind) catch |err| switch (err) {
            error.NotAMultiPackIndex,
            error.UnsupportedMidxVersion,
            error.ObjectFormatMismatch,
            error.CorruptMultiPackIndex,
            error.ChainUnsupported,
            => null,
            else => |e| e,
        };
    }

    /// Read `pack/multi-pack-index`, or `null` when there is none.
    pub fn open(gpa: Allocator, io: Io, pack_dir: Io.Dir, kind: hash.Kind) Self.Error!?Index {
        const bytes = (try fs.readFileAlloc(gpa, io, pack_dir, "multi-pack-index", 1 << 30)) orelse
            return null;
        // parse takes ownership on success and failure.
        const value = try parse(gpa, kind, bytes);
        return value;
    }

    /// Read a multi-pack index from bytes this takes ownership of.
    pub fn parse(gpa: Allocator, kind: hash.Kind, bytes: []const u8) Self.Error!Index {
        errdefer gpa.free(bytes);
        if (bytes.len < 12) return error.NotAMultiPackIndex;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotAMultiPackIndex;
        // Version 2 is version 1 with its pack names in any order, which
        // git 2.54 writes for a compaction or for `midx.version`.
        const version = bytes[4];
        if (version != 1 and version != 2) return error.UnsupportedMidxVersion;
        const midx_kind: hash.Kind = switch (bytes[5]) {
            1 => .sha1,
            2 => .sha256,
            else => return error.UnsupportedMidxVersion,
        };
        if (midx_kind != kind) return error.ObjectFormatMismatch;
        const chunk_count = bytes[6];
        if (bytes[7] != 0) return error.ChainUnsupported;
        const pack_count = std.mem.readInt(u32, bytes[8..12], .big);

        format.validate(kind, bytes, 12, chunk_count) catch return error.CorruptMultiPackIndex;
        const raw_len = kind.rawLen();
        const fanout_chunk = format.get(bytes, 12, chunk_count, "OIDF") orelse return error.CorruptMultiPackIndex;
        if (fanout_chunk.len != 1024) return error.CorruptMultiPackIndex;
        const fanout_table = std.mem.bytesAsValue([256][4]u8, fanout_chunk[0..1024]);
        const count = std.mem.readInt(u32, &fanout_table[255], .big);
        const oids = Rows.exactly(format.get(bytes, 12, chunk_count, "OIDL") orelse return error.CorruptMultiPackIndex, count, raw_len) orelse return error.CorruptMultiPackIndex;
        const offsets = Rows.exactly(format.get(bytes, 12, chunk_count, "OOFF") orelse return error.CorruptMultiPackIndex, count, 8) orelse return error.CorruptMultiPackIndex;
        const large: ?Rows = if (format.get(bytes, 12, chunk_count, "LOFF")) |chunk| .whole(chunk, 8) else null;
        const reverse: ?Rows = if (format.get(bytes, 12, chunk_count, "RIDX")) |chunk|
            Rows.exactly(chunk, count, 4) orelse return error.CorruptMultiPackIndex
        else
            null;
        const pack_names = format.get(bytes, 12, chunk_count, "PNAM") orelse return error.CorruptMultiPackIndex;
        if (pack_names.len < pack_count) return error.CorruptMultiPackIndex;
        var result: Index = .{
            .gpa = gpa,
            .kind = kind,
            .bytes = bytes,
            .count = @intCast(oids.count()),
            .pack_count = pack_count,
            .pack_names = pack_names,
            .fanout_table = fanout_table,
            .oids = oids,
            .offsets = offsets,
            .large = large,
            .reverse = reverse,
        };
        try result.verify();
        try result.checkNames(version);
        return result;
    }

    /// The checksum that names a bitmap written beside this index.
    pub fn checksum(index: *const Index) Oid {
        return Oid.fromCut(index.kind, index.bytes[index.bytes.len - index.kind.rawLen() ..]);
    }

    /// Name-order position at a pseudo-pack position, when RIDX is present.
    pub fn reverseAt(index: *const Index, position: u32) Self.PositionError!?u32 {
        const table = index.reverse orelse return null;
        const row = table.at(position) orelse return error.CorruptMultiPackIndex;
        const value = std.mem.readInt(u32, row[0..4], .big);
        if (value >= index.count) return error.CorruptMultiPackIndex;
        return value;
    }

    /// Check sorted names, fanout, pack names, offsets and reverse order.
    pub fn verify(index: *const Index) Self.Error!void {
        var count: u32 = 0;
        for (0..256) |bucket| {
            while (count < index.count and (try index.nameAt(count)).raw()[0] == bucket) : (count += 1) {
                if (count > 0 and (try index.nameAt(count - 1)).order(try index.nameAt(count)) != .lt) return error.CorruptMultiPackIndex;
                _ = try index.locate(count);
            }
            if (std.mem.readInt(u32, &index.fanout_table[bucket], .big) != count) return error.CorruptMultiPackIndex;
        }
        var names = index.packNames();
        while (names.next()) |_| {}
        if (names.taken != index.pack_count) return error.CorruptMultiPackIndex;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(index.gpa);
        for (0..index.count) |i| if (try index.reverseAt(@intCast(i))) |pos| {
            if ((try seen.getOrPut(index.gpa, pos)).found_existing) return error.CorruptMultiPackIndex;
        };
    }

    /// Each pack name is one file name in the pack directory, as git
    /// writes them, and in a version 1 index each is after the one before,
    /// which git refuses an index without. A name is a path something may
    /// later be opened or removed at, so one that leaves the directory is
    /// refused.
    fn checkNames(index: *const Index, version: u8) Self.Error!void {
        var previous: ?[]const u8 = null;
        var names = index.packNames();
        while (names.next()) |name| {
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.CorruptMultiPackIndex;
            if (std.mem.findAny(u8, name, "/\\:") != null) return error.CorruptMultiPackIndex;
            if (version == 1) if (previous) |before| {
                if (std.mem.order(u8, before, name) != .lt) return error.CorruptMultiPackIndex;
            };
            previous = name;
        }
        if (names.taken != index.pack_count) return error.CorruptMultiPackIndex;
    }

    /// Release the index.
    pub fn deinit(index: *Index) void {
        index.gpa.free(index.bytes);
        index.* = undefined;
    }

    /// The name of the pack at `position`, without its extension.
    ///
    /// The names are NUL-separated in the order the index uses them.
    pub fn packName(index: *const Index, position: u32) ?[]const u8 {
        var names = index.packNames();
        var i: u32 = 0;
        while (names.next()) |name| : (i += 1) if (i == position) return name;
        return null;
    }

    /// The names of the packs, in the order positions name them, without
    /// their extensions.
    pub fn packNames(index: *const Index) PackNames {
        return .{ .split = std.mem.splitScalar(u8, index.pack_names, 0), .count = index.pack_count };
    }

    /// The name of the object at `position`.
    pub fn nameAt(index: *const Index, position: u32) Self.PositionError!Oid {
        const row = index.oids.at(position) orelse return error.CorruptMultiPackIndex;
        return Oid.fromCut(index.kind, row);
    }

    /// How many names begin with a byte up to `bucket`.
    fn fanout(index: *const Index, bucket: u8) u32 {
        return std.mem.readInt(u32, &index.fanout_table[bucket], .big);
    }

    /// Where `oid` lives, or `null`.
    pub fn find(index: *const Index, oid: Oid) Self.PositionError!?Located {
        if (oid.kind != index.kind) return null;
        const raw = oid.raw();
        const from = if (raw[0] == 0) 0 else index.fanout(raw[0] - 1);
        const at = index.oids.lowerBound(from, index.fanout(raw[0]), 0, raw) orelse return error.CorruptMultiPackIndex;
        const row = index.oids.at(at) orelse return null;
        if (!std.mem.eql(u8, row, raw)) return null;
        return try index.locate(std.math.cast(u32, at) orelse return error.CorruptMultiPackIndex);
    }

    pub fn locate(index: *const Index, position: u32) Self.PositionError!Located {
        const row = index.offsets.at(position) orelse return error.CorruptMultiPackIndex;
        const pack = std.mem.readInt(u32, row[0..4], .big);
        const small = std.mem.readInt(u32, row[4..8], .big);
        if (pack >= index.pack_count) return error.CorruptMultiPackIndex;
        const table = index.large orelse return .{ .pack = pack, .offset = small };
        if (small & 0x8000_0000 == 0) return .{ .pack = pack, .offset = small };
        const large = table.at(small & 0x7fff_ffff) orelse return error.CorruptMultiPackIndex;
        return .{ .pack = pack, .offset = std.mem.readInt(u64, large[0..8], .big) };
    }
};

test "a multi-pack index that is not one is refused by name" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, "nope");
    try std.testing.expectError(error.NotAMultiPackIndex, Index.parse(gpa, .sha1, bytes));
}

test "fuzz: any bytes are an index or a named error" {
    try shakedown.check(std.testing.allocator, {}, fuzzMidx, .{});
}

fn fuzzMidx(_: void, case: *shakedown.Case) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [2048]u8 = undefined;
    const n = shakedown.gen.intRange(case.source, usize, 0, scratch.len);
    case.source.bytes(scratch[0..n]);
    const bytes = try gpa.dupe(u8, scratch[0..n]);
    var index = Index.parse(gpa, .sha1, bytes) catch return;
    defer index.deinit();
    // glint-ignore: Z026 -- refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
    _ = index.find(Oid.zero(.sha1)) catch {};
    _ = index.packName(0);
}

test "without a LOFF chunk a 4-byte offset with its high bit set is that offset, as git reads it" {
    const gpa = std.testing.allocator;
    const oid = try Oid.fromRaw(.sha1, &@as([20]u8, @splat(0x42)));
    // Past 2 GiB, inside 4 GiB: the writer, as git's, leaves LOFF out.
    const entries = [_]WriteEntry{.{ .oid = oid, .offset = 0x9000_0000 }};
    const packs = [_]WritePack{.{ .name = "pack-a.idx", .mtime = 0, .entries = &entries }};
    var index = try Index.parse(gpa, .sha1, try encode(gpa, .sha1, &packs, .{}));
    defer index.deinit();
    try std.testing.expectEqual(@as(?Rows, null), index.large);
    try std.testing.expectEqual(@as(u64, 0x9000_0000), (try index.find(oid)).?.offset);
    try std.testing.expectEqual(@as(?Located, null), try index.find(Oid.zero(.sha1)));
}

test "a position past a multi-pack index's tables is refused, not read past" {
    const gpa = std.testing.allocator;
    const low = try Oid.fromRaw(.sha1, &@as([20]u8, @splat(0x11)));
    const high = try Oid.fromRaw(.sha1, &@as([20]u8, @splat(0xee)));
    const entries = [_]WriteEntry{ .{ .oid = low, .offset = 12 }, .{ .oid = high, .offset = 0x1_0000_0000 } };
    const packs = [_]WritePack{.{ .name = "pack-a.idx", .mtime = 0, .entries = &entries }};
    var index = try Index.parse(gpa, .sha1, try encode(gpa, .sha1, &packs, .{ .reverse_index = true }));
    defer index.deinit();
    try std.testing.expectEqual(@as(u32, 2), index.count);
    try std.testing.expect((try index.nameAt(1)).eql(high));
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), (try index.find(high)).?.offset);
    try std.testing.expectError(error.CorruptMultiPackIndex, index.nameAt(2));
    try std.testing.expectError(error.CorruptMultiPackIndex, index.locate(2));
    try std.testing.expectError(error.CorruptMultiPackIndex, index.reverseAt(2));
}

test "a refused on-disk multi-pack index releases its bytes once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "multi-pack-index", .data = "nope" });
    try std.testing.expectError(error.NotAMultiPackIndex, Index.open(gpa, io, tmp.dir, .sha1));
}

const format = @import("accelerators/chunks.zig");

/// One object's name and byte offset from a pack index.
pub const WriteEntry = struct { oid: Oid, offset: u64 };
/// A pack supplied to the writer. `mtime` is in whole seconds, as git compares it.
pub const WritePack = struct { name: []const u8, mtime: i64, entries: []const WriteEntry, previously_indexed: bool = false };
/// Git's preferred-pack and pseudo-pack-order options.
pub const WriteOptions = struct {
    preferred_pack: ?[]const u8 = null,
    reverse_index: bool = false,
};

const Selected = struct {
    oid: Oid,
    offset: u64,
    pack: u32,
    original: u32,
    mtime: i64,
    preferred: bool,
    fn byName(_: void, a: Selected, b: Selected) bool {
        const order = a.oid.order(b.oid);
        if (order != .eq) return order == .lt;
        if (a.preferred != b.preferred) return a.preferred;
        if (a.mtime != b.mtime) return a.mtime > b.mtime;
        return a.original < b.original;
    }
};

fn samePackName(a: []const u8, b: []const u8) bool {
    const end_a = if (std.mem.endsWith(u8, a, ".pack")) a.len - 5 else if (std.mem.endsWith(u8, a, ".idx")) a.len - 4 else a.len;
    const end_b = if (std.mem.endsWith(u8, b, ".pack")) b.len - 5 else if (std.mem.endsWith(u8, b, ".idx")) b.len - 4 else b.len;
    return std.mem.eql(u8, a[0..end_a], b[0..end_b]);
}

/// Errors from `encode`.
pub const EncodeError = Allocator.Error || error{ InvalidMidxInput, UnknownPreferredPack, EmptyPreferredPack };

/// Encode git's MIDX version one, deduplicating by preferred pack, then newest pack.
/// The optional RIDX and BTMP chunks describe git's pseudo-pack order.
pub fn encode(gpa: Allocator, kind: hash.Kind, packs: []const WritePack, options: WriteOptions) EncodeError![]u8 {
    if (packs.len == 0 or packs.len > std.math.maxInt(u32)) return error.InvalidMidxInput;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const order = try arena.alloc(u32, packs.len);
    for (order, 0..) |*n, i| n.* = @intCast(i);
    const NameOrder = struct {
        fn less(context: []const WritePack, a: u32, b: u32) bool {
            return std.mem.order(u8, context[a].name, context[b].name) == .lt;
        }
    };
    std.mem.sort(u32, order, packs, NameOrder.less);
    const permutation = try arena.alloc(u32, packs.len);
    var preferred: ?u32 = null;
    for (order, 0..) |original, i| {
        permutation[original] = @intCast(i);
        if (i > 0 and std.mem.eql(u8, packs[order[i - 1]].name, packs[original].name)) return error.InvalidMidxInput;
        if (std.mem.findScalar(u8, packs[original].name, 0) != null or !std.mem.endsWith(u8, packs[original].name, ".idx")) return error.InvalidMidxInput;
        if (options.preferred_pack) |name| {
            if (samePackName(name, packs[original].name)) preferred = original;
        }
    }
    if (options.preferred_pack != null and preferred == null) return error.UnknownPreferredPack;
    if (options.reverse_index and preferred == null) for (packs, 0..) |p, i| {
        if (p.entries.len != 0 and (preferred == null or p.mtime < packs[preferred.?].mtime)) preferred = @intCast(i);
    };
    if (preferred) |p| if (packs[p].entries.len == 0) return error.EmptyPreferredPack;
    var all: std.ArrayList(Selected) = .empty;
    for (packs, 0..) |p, i| for (p.entries) |entry| {
        if (entry.oid.kind != kind or entry.offset < 12) return error.InvalidMidxInput;
        try all.append(arena, .{ .oid = entry.oid, .offset = entry.offset, .pack = permutation[i], .original = @intCast(i), .mtime = if (p.previously_indexed) 0 else p.mtime, .preferred = if (preferred) |preferred_index| preferred_index == i else false });
    };
    std.mem.sort(Selected, all.items, {}, Selected.byName);
    var entries: std.ArrayList(Selected) = .empty;
    for (all.items) |entry| {
        if (entries.items.len > 0 and entries.items[entries.items.len - 1].oid.eql(entry.oid)) continue;
        try entries.append(arena, entry);
    }
    if (entries.items.len > std.math.maxInt(u32)) return error.InvalidMidxInput;
    var buffers: [7]format.Buffer = undefined;
    for (&buffers) |*buffer| buffer.* = .{ .gpa = gpa };
    defer for (&buffers) |*buffer| buffer.deinit();
    for (order) |original| {
        try buffers[0].add(packs[original].name);
        try buffers[0].int(u8, 0);
    }
    while (buffers[0].bytes.items.len % 4 != 0) try buffers[0].int(u8, 0);
    var fanout: [256]u32 = @splat(0);
    var large = false;
    for (entries.items) |entry| {
        fanout[entry.oid.raw()[0]] += 1;
        if (entry.offset > 0xffff_ffff) large = true;
    }
    var total: u32 = 0;
    for (fanout) |count| {
        total += count;
        try buffers[1].int(u32, total);
    }
    var large_index: u32 = 0;
    for (entries.items) |entry| {
        try buffers[2].add(entry.oid.raw());
        try buffers[3].int(u32, entry.pack);
        try buffers[3].int(u32, if (large and entry.offset > 0x7fff_ffff) 0x8000_0000 | large_index else std.math.cast(u32, entry.offset) orelse return error.InvalidMidxInput);
        if (large and entry.offset > 0x7fff_ffff) {
            try buffers[4].int(u64, entry.offset);
            large_index += 1;
        }
    }
    // What `parse` and `nameAt` index by position: the names rising, one
    // fixed-width name and one pack-and-offset pair per object, and the
    // pack names padded to four bytes.
    std.debug.assert(total == entries.items.len);
    if (entries.items.len > 1) for (1..entries.items.len) |i| aegis.assert.invariant(entries.items[i - 1].oid.order(entries.items[i].oid) == .lt, "entries.items[i - 1].oid.order(entries.items[i].oid) == .lt");
    std.debug.assert(buffers[0].bytes.items.len % 4 == 0);
    std.debug.assert(buffers[2].bytes.items.len == entries.items.len * kind.rawLen());
    std.debug.assert(buffers[3].bytes.items.len == entries.items.len * 8);
    if (options.reverse_index) {
        const reverse = try arena.alloc(u32, entries.items.len);
        for (reverse, 0..) |*n, i| n.* = @intCast(i);
        const PackOrder = struct {
            fn less(context: []const Selected, a: u32, b: u32) bool {
                const x = context[a];
                const y = context[b];
                if (x.preferred != y.preferred) return x.preferred;
                if (x.pack != y.pack) return x.pack < y.pack;
                return x.offset < y.offset;
            }
        };
        std.mem.sort(u32, reverse, entries.items, PackOrder.less);
        const starts = try arena.alloc(u32, packs.len);
        @memset(starts, 0);
        const counts = try arena.alloc(u32, packs.len);
        @memset(counts, 0);
        for (reverse, 0..) |pos, i| {
            try buffers[5].int(u32, pos);
            const p = entries.items[pos].pack;
            if (counts[p] == 0) starts[p] = @intCast(i);
            counts[p] += 1;
        }
        for (starts, counts) |start, count| {
            try buffers[6].int(u32, start);
            try buffers[6].int(u32, count);
        }
    }
    var chunks: std.ArrayList(format.Chunk) = .empty;
    defer chunks.deinit(gpa);
    const ids = [_]*const [4]u8{ "PNAM", "OIDF", "OIDL", "OOFF", "LOFF", "RIDX", "BTMP" };
    for (&buffers, ids, 0..) |*buffer, id, i| if (i < 4 or (i == 4 and large) or (i > 4 and options.reverse_index)) {
        try chunks.append(gpa, .{ .id = id, .bytes = buffer.bytes.items });
    };
    var header: [12]u8 = .{ 'M', 'I', 'D', 'X', 1, if (kind == .sha1) 1 else 2, @intCast(chunks.items.len), 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, header[8..12], @intCast(packs.len), .big);
    return format.encode(gpa, kind, &header, chunks.items);
}
