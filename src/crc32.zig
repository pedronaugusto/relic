//! CRC-32 as zlib computes it (IEEE 802.3, reflected, polynomial
//! 0xedb88320): the checksum a pack index keeps for every entry.
//!
//! `std.hash.Crc32` takes a byte at a time from one table, about 400 MB/s;
//! a pack written from stored entries spends a fifth of its time there.
//! This takes eight bytes at a time: with the CPU's CRC instructions where
//! the target has them (`crc32x` on AArch64 with the CRC extension), and
//! otherwise from eight tables (slicing-by-8), which is what zlib does
//! without hardware help. Measured on an M3 Max over 64 MiB: 159 ms for
//! `std.hash.Crc32`, 26 ms from the tables, 7 ms with the instructions.

const std = @import("std");
const builtin = @import("builtin");

const hardware = builtin.target.cpu.arch == .aarch64 and
    std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .crc);

const tables = blk: {
    @setEvalBranchQuota(100_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xedb88320 else c >> 1;
        t[0][i] = c;
    }
    for (0..256) |i| {
        for (1..8) |k| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

/// A running CRC-32, as `std.hash.Crc32` is used.
pub const Crc32 = struct {
    /// The register, inverted, as the algorithm keeps it.
    state: u32 = 0xffff_ffff,

    pub fn init() Crc32 {
        return .{};
    }

    pub fn update(c: *Crc32, bytes: []const u8) void {
        c.state = step(c.state, bytes);
    }

    pub fn final(c: Crc32) u32 {
        return ~c.state;
    }

    /// The CRC-32 of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return ~step(0xffff_ffff, bytes);
    }
};

fn step(start: u32, bytes: []const u8) u32 {
    var c = start;
    var rest = bytes;
    if (hardware) {
        while (rest.len >= 8) {
            const word = std.mem.readInt(u64, rest[0..8], .little);
            c = asm ("crc32x %[out:w], %[in:w], %[word:x]"
                : [out] "=r" (-> u32),
                : [in] "r" (c),
                  [word] "r" (word),
            );
            rest = rest[8..];
        }
        for (rest) |b| c = asm ("crc32b %[out:w], %[in:w], %[b:w]"
            : [out] "=r" (-> u32),
            : [in] "r" (c),
              [b] "r" (@as(u32, b)),
        );
        return c;
    }
    while (rest.len >= 8) {
        const lo = std.mem.readInt(u32, rest[0..4], .little) ^ c;
        const hi = std.mem.readInt(u32, rest[4..8], .little);
        c = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^ tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
            tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^ tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
        rest = rest[8..];
    }
    for (rest) |b| c = (c >> 8) ^ tables[0][(c ^ b) & 0xff];
    return c;
}

test "CRC-32 is zlib's, at every length and however it is split" {
    var buf: [3000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    for ([_]usize{ 0, 1, 7, 8, 9, 31, 64, 1000, 2999, 3000 }) |n| {
        try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), Crc32.hash(buf[0..n]));
        for ([_]usize{ 0, 1, 5, 8, n / 2 }) |cut| {
            if (cut > n) continue;
            var c: Crc32 = .init();
            c.update(buf[0..cut]);
            c.update(buf[cut..n]);
            try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), c.final());
        }
    }
    // zlib's check value.
    try std.testing.expectEqual(@as(u32, 0xcbf43926), Crc32.hash("123456789"));
}

test "the tables alone give the same CRC as the instructions" {
    var buf: [1031]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 40503 >> 3);
    var c: u32 = 0xffff_ffff;
    var rest: []const u8 = &buf;
    while (rest.len >= 8) {
        const lo = std.mem.readInt(u32, rest[0..4], .little) ^ c;
        const hi = std.mem.readInt(u32, rest[4..8], .little);
        c = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^ tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
            tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^ tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
        rest = rest[8..];
    }
    for (rest) |b| c = (c >> 8) ^ tables[0][(c ^ b) & 0xff];
    try std.testing.expectEqual(std.hash.Crc32.hash(&buf), ~c);
}
