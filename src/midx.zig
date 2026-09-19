//! The multi-pack index, read as an accelerator.
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
        errdefer gpa.free(bytes);
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

        return .{
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

    fn locate(index: *const Index, position: u32) Error!Located {
        const row = index.bytes[index.offsets_at + @as(usize, position) * 8 ..];
        const pack = std.mem.readInt(u32, row[0..4], .big);
        const small = std.mem.readInt(u32, row[4..8], .big);
        if (small & 0x8000_0000 == 0) return .{ .pack = pack, .offset = small };
        const large_at = index.large_offsets_at orelse return error.CorruptMultiPackIndex;
        const at = large_at + @as(usize, small & 0x7fff_ffff) * 8;
        if (at + 8 > index.bytes.len) return error.CorruptMultiPackIndex;
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
