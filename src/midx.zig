//! The multi-pack index, read and encoded as an accelerator.
//!
//! It answers one question faster — which pack holds an object, when there
//! are many packs — and nothing depends on it. A repository that has one must
//! read the same when it is ignored, so this is only ever consulted before
//! the per-pack indexes, never instead of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const fs = @import("fs.zig");

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
} || Allocator.Error || Io.Dir.ReadFileAllocError;

/// Where an object lives.
pub const Located = struct {
    /// Which pack, as a position in `packNames`.
    pack: u32,
    offset: u64,
};

/// A multi-pack index, held in memory.
pub const Index = struct {
    gpa: Allocator,
    kind: hash.Kind,
    bytes: []const u8,
    /// How many objects it covers.
    count: u32,
    /// How many packs it covers.
    pack_count: u32,
    names_chunk_at: usize,
    names_chunk_len: usize,
    fanout_at: usize,
    oids_at: usize,
    offsets_at: usize,
    large_offsets_at: ?usize,

    /// Read `pack/multi-pack-index`, or `null` when there is none.
    pub fn open(gpa: Allocator, io: Io, pack_dir: Io.Dir, kind: hash.Kind) Error!?Index {
        const bytes = (try fs.readFileAlloc(gpa, io, pack_dir, "multi-pack-index", 1 << 30)) orelse
            return null;
        // parse takes ownership on success and failure.
        return try parse(gpa, kind, bytes);
    }

    /// Read a multi-pack index from bytes this takes ownership of.
    pub fn parse(gpa: Allocator, kind: hash.Kind, bytes: []const u8) Error!Index {
        errdefer gpa.free(bytes);
        if (bytes.len < 12) return error.NotAMultiPackIndex;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotAMultiPackIndex;
        if (bytes[4] != 1) return error.UnsupportedMidxVersion;
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
        const table_at: usize = 12;
        const table_len = (@as(usize, chunk_count) + 1) * 12;
        if (bytes.len < table_at + table_len) return error.CorruptMultiPackIndex;

        var names_at: ?usize = null;
        var names_end: usize = bytes.len;
        var fanout_at: ?usize = null;
        var oids_at: ?usize = null;
        var offsets_at: ?usize = null;
        var large_offsets_at: ?usize = null;

        var i: usize = 0;
        while (i <= chunk_count) : (i += 1) {
            const row = bytes[table_at + i * 12 ..];
            const id = row[0..4];
            const offset = std.mem.readInt(u64, row[4..12], .big);
            if (offset > bytes.len) return error.CorruptMultiPackIndex;
            const at: usize = @intCast(offset);
            if (std.mem.eql(u8, id, "PNAM")) {
                names_at = at;
                if (i + 1 <= chunk_count) {
                    const next = std.mem.readInt(u64, bytes[table_at + (i + 1) * 12 + 4 ..][0..8], .big);
                    if (next <= bytes.len) names_end = @intCast(next);
                }
            }
            if (std.mem.eql(u8, id, "OIDF")) fanout_at = at;
            if (std.mem.eql(u8, id, "OIDL")) oids_at = at;
            if (std.mem.eql(u8, id, "OOFF")) offsets_at = at;
            if (std.mem.eql(u8, id, "LOFF")) large_offsets_at = at;
        }

        const fanout = fanout_at orelse return error.CorruptMultiPackIndex;
        if (fanout + 1024 > bytes.len) return error.CorruptMultiPackIndex;
        const count = std.mem.readInt(u32, bytes[fanout + 255 * 4 ..][0..4], .big);

        const raw_len = kind.rawLen();
        const oids = oids_at orelse return error.CorruptMultiPackIndex;
        const offsets = offsets_at orelse return error.CorruptMultiPackIndex;
        if (oids + @as(usize, count) * raw_len > bytes.len) return error.CorruptMultiPackIndex;
        if (offsets + @as(usize, count) * 8 > bytes.len) return error.CorruptMultiPackIndex;

        if ((format.get(bytes, 12, chunk_count, "OIDF") orelse return error.CorruptMultiPackIndex).len != 1024 or
            (format.get(bytes, 12, chunk_count, "OIDL") orelse return error.CorruptMultiPackIndex).len != @as(usize, count) * raw_len or
            (format.get(bytes, 12, chunk_count, "OOFF") orelse return error.CorruptMultiPackIndex).len != @as(usize, count) * 8 or
            (format.get(bytes, 12, chunk_count, "PNAM") orelse return error.CorruptMultiPackIndex).len < pack_count) return error.CorruptMultiPackIndex;
        var result: Index = .{
            .gpa = gpa,
            .kind = kind,
            .bytes = bytes,
            .count = count,
            .pack_count = pack_count,
            .names_chunk_at = names_at orelse return error.CorruptMultiPackIndex,
            .names_chunk_len = names_end -| (names_at orelse 0),
            .fanout_at = fanout,
            .oids_at = oids,
            .offsets_at = offsets,
            .large_offsets_at = large_offsets_at,
        };
        try result.verify();
        return result;
    }

    /// The checksum that names a bitmap written beside this index.
    pub fn checksum(index: *const Index) Oid {
        return Oid.fromRaw(index.kind, index.bytes[index.bytes.len - index.kind.rawLen() ..]) catch unreachable;
    }

    /// Name-order position at a pseudo-pack position, when RIDX is present.
    pub fn reverseAt(index: *const Index, position: u32) Error!?u32 {
        if (position >= index.count) return error.CorruptMultiPackIndex;
        const chunk = format.get(index.bytes, 12, index.bytes[6], "RIDX") orelse return null;
        if (chunk.len != @as(usize, index.count) * 4) return error.CorruptMultiPackIndex;
        const value = std.mem.readInt(u32, chunk[@as(usize, position) * 4 ..][0..4], .big);
        if (value >= index.count) return error.CorruptMultiPackIndex;
        return value;
    }

    /// Check sorted names, fanout, pack names, offsets and reverse order.
    pub fn verify(index: *const Index) Error!void {
        var count: u32 = 0;
        for (0..256) |bucket| {
            while (count < index.count and index.nameAt(count).raw()[0] == bucket) : (count += 1) {
                if (count > 0 and index.nameAt(count - 1).order(index.nameAt(count)) != .lt) return error.CorruptMultiPackIndex;
                _ = try index.locate(count);
            }
            if (std.mem.readInt(u32, index.bytes[index.fanout_at + bucket * 4 ..][0..4], .big) != count) return error.CorruptMultiPackIndex;
        }
        for (0..index.pack_count) |i| if (index.packName(@intCast(i)) == null) return error.CorruptMultiPackIndex;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(index.gpa);
        for (0..index.count) |i| if (try index.reverseAt(@intCast(i))) |pos| {
            if ((try seen.getOrPut(index.gpa, pos)).found_existing) return error.CorruptMultiPackIndex;
        };
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
        var at = index.names_chunk_at;
        const end = index.names_chunk_at + index.names_chunk_len;
        var i: u32 = 0;
        while (at < end) {
            const nul = std.mem.indexOfScalarPos(u8, index.bytes[0..end], at, 0) orelse return null;
            if (i == position) {
                var name = index.bytes[at..nul];
                if (std.mem.endsWith(u8, name, ".idx")) name = name[0 .. name.len - 4];
                if (std.mem.endsWith(u8, name, ".pack")) name = name[0 .. name.len - 5];
                return name;
            }
            at = nul + 1;
            i += 1;
        }
        return null;
    }

    /// The name of the object at `position`.
    pub fn nameAt(index: *const Index, position: u32) Oid {
        const raw_len = index.kind.rawLen();
        return Oid.fromRaw(index.kind, index.bytes[index.oids_at + @as(usize, position) * raw_len ..][0..raw_len]) catch unreachable;
    }

    /// Where `oid` lives, or `null`.
    pub fn find(index: *const Index, oid: Oid) Error!?Located {
        if (oid.kind != index.kind) return null;
        const raw = oid.raw();
        var lo: u32 = if (raw[0] == 0)
            0
        else
            std.mem.readInt(u32, index.bytes[index.fanout_at + (@as(usize, raw[0]) - 1) * 4 ..][0..4], .big);
        var hi: u32 = std.mem.readInt(u32, index.bytes[index.fanout_at + @as(usize, raw[0]) * 4 ..][0..4], .big);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, index.nameAt(mid).raw(), raw)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return try index.locate(mid),
            }
        }
        return null;
    }

    pub fn locate(index: *const Index, position: u32) Error!Located {
        const row = index.bytes[index.offsets_at + @as(usize, position) * 8 ..];
        const pack = std.mem.readInt(u32, row[0..4], .big);
        const small = std.mem.readInt(u32, row[4..8], .big);
        if (pack >= index.pack_count) return error.CorruptMultiPackIndex;
        if (index.large_offsets_at == null or small & 0x8000_0000 == 0) return .{ .pack = pack, .offset = small };
        const large_at = index.large_offsets_at orelse return error.CorruptMultiPackIndex;
        const at = large_at + @as(usize, small & 0x7fff_ffff) * 8;
        const large_chunk = format.get(index.bytes, 12, index.bytes[6], "LOFF") orelse return error.CorruptMultiPackIndex;
        if (at + 8 > large_at + large_chunk.len) return error.CorruptMultiPackIndex;
        return .{ .pack = pack, .offset = std.mem.readInt(u64, index.bytes[at..][0..8], .big) };
    }
};

test "a multi-pack index that is not one is refused by name" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, "nope");
    try std.testing.expectError(error.NotAMultiPackIndex, Index.parse(gpa, .sha1, bytes));
}

test "fuzz: any bytes are an index or a named error" {
    try std.testing.fuzz({}, fuzzMidx, .{});
}

fn fuzzMidx(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [2048]u8 = undefined;
    const n = smith.slice(&scratch);
    const bytes = try gpa.dupe(u8, scratch[0..n]);
    var index = Index.parse(gpa, .sha1, bytes) catch return;
    defer index.deinit();
    _ = index.find(Oid.zero(.sha1)) catch {};
    _ = index.packName(0);
}

test "a refused on-disk multi-pack index releases its bytes once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "multi-pack-index", .data = "nope" });
    try std.testing.expectError(error.NotAMultiPackIndex, Index.open(gpa, io, tmp.dir, .sha1));
}

const format = @import("accelerator_format.zig");

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

/// Encode git's MIDX version one, deduplicating by preferred pack, then newest pack.
/// The optional RIDX and BTMP chunks describe git's pseudo-pack order.
pub fn encode(gpa: Allocator, kind: hash.Kind, packs: []const WritePack, options: WriteOptions) (Allocator.Error || error{ InvalidMidxInput, UnknownPreferredPack, EmptyPreferredPack })![]u8 {
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
        if (std.mem.indexOfScalar(u8, packs[original].name, 0) != null or !std.mem.endsWith(u8, packs[original].name, ".idx")) return error.InvalidMidxInput;
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
        try buffers[3].int(u32, if (large and entry.offset > 0x7fff_ffff) 0x8000_0000 | large_index else @intCast(entry.offset));
        if (large and entry.offset > 0x7fff_ffff) {
            try buffers[4].int(u64, entry.offset);
            large_index += 1;
        }
    }
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
