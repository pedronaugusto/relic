//! The run-length bitmap git stores a split index's two masks in.
//!
//! On the disk: the bit count, the word count, that many 64-bit words, and the
//! position of the last run word — every integer big-endian. A word is either
//! a run header, which says how many clean words of one value follow it and
//! how many literal words come after those, or one of those literals.
//!
//! Reading only. Nothing in this package writes one, because nothing here
//! writes a split index.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from reading a bitmap.
pub const Error = error{
    /// The bytes ended inside the header or inside the words.
    TruncatedBitmap,
    /// A run header asked for more words than the bitmap holds.
    CorruptBitmap,
};

/// A decoded bitmap: the positions whose bit is set, in ascending order.
pub const Bits = struct {
    gpa: Allocator,
    positions: []u32,

    /// Release the positions.
    pub fn deinit(b: *Bits) void {
        b.gpa.free(b.positions);
        b.* = undefined;
    }

    /// Whether `position` is set. A bisection, because the positions rise.
    pub fn isSet(b: Bits, position: u32) bool {
        return std.sort.binarySearch(u32, b.positions, position, order) != null;
    }

    fn order(key: u32, item: u32) std.math.Order {
        return std.math.order(key, item);
    }
};

/// Read a bitmap from the front of `bytes`. Returns the set positions and how
/// many bytes the bitmap took.
pub fn read(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!struct {
    bits: Bits,
    len: usize,
} {
    if (bytes.len < 8) return error.TruncatedBitmap;
    const bit_count = std.mem.readInt(u32, bytes[0..4], .big);
    const word_count = std.mem.readInt(u32, bytes[4..8], .big);
    const words_at: usize = 8;
    const words_end = words_at + @as(usize, word_count) * 8;
    if (bytes.len < words_end + 4) return error.TruncatedBitmap;
    // A bitmap cannot describe more bits than its words hold. Without this
    // a crafted header asks for four billion appends.
    if (@as(u64, bit_count) > @as(u64, word_count) * 64) return error.CorruptBitmap;

    var positions: std.ArrayList(u32) = .empty;
    errdefer positions.deinit(gpa);

    var word_index: u32 = 0;
    var bit_position: u64 = 0;
    while (word_index < word_count) {
        const header = std.mem.readInt(u64, bytes[words_at + @as(usize, word_index) * 8 ..][0..8], .big);
        word_index += 1;
        const run_bit = header & 1;
        const run_len: u64 = (header >> 1) & 0xffff_ffff;
        const literal_len: u64 = header >> 33;

        if (run_bit == 1) {
            var i: u64 = 0;
            while (i < run_len * 64) : (i += 1) {
                if (bit_position + i >= bit_count) break;
                try positions.append(gpa, @intCast(bit_position + i));
            }
        }
        bit_position += run_len * 64;

        if (word_index + literal_len > word_count) return error.CorruptBitmap;
        var l: u64 = 0;
        while (l < literal_len) : (l += 1) {
            const word = std.mem.readInt(u64, bytes[words_at + @as(usize, word_index) * 8 ..][0..8], .big);
            word_index += 1;
            var bit: u6 = 0;
            while (true) {
                if (word & (@as(u64, 1) << bit) != 0 and bit_position + bit < bit_count) {
                    try positions.append(gpa, @intCast(bit_position + bit));
                }
                if (bit == 63) break;
                bit += 1;
            }
            bit_position += 64;
        }
    }

    return .{
        .bits = .{ .gpa = gpa, .positions = try positions.toOwnedSlice(gpa) },
        .len = words_end + 4,
    };
}

test "an empty bitmap reads as no bits" {
    const gpa = std.testing.allocator;
    // bits 0, words 1, one empty run word, rlw position 0 -- which is what
    // git writes for a split index that deletes nothing.
    const bytes = [_]u8{
        0, 0, 0, 0,
        0, 0, 0, 1,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };
    var result = try read(gpa, &bytes);
    defer result.bits.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.bits.positions.len);
    try std.testing.expectEqual(@as(usize, 20), result.len);
}

test "a literal word yields its set bits" {
    const gpa = std.testing.allocator;
    var bytes: [8 + 16 + 4]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 70, .big); // 70 bits
    std.mem.writeInt(u32, bytes[4..8], 2, .big); // two words
    // Header: run length 0, one literal word.
    std.mem.writeInt(u64, bytes[8..16], @as(u64, 1) << 33, .big);
    std.mem.writeInt(u64, bytes[16..24], 0b1010, .big);
    var result = try read(gpa, &bytes);
    defer result.bits.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, result.bits.positions);
}

test "fuzz: any bytes are a bitmap or a named error" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [512]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var result = read(gpa, input) catch return;
    result.bits.deinit();
}
