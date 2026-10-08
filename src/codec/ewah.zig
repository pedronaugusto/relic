//! The run-length bitmap git stores in split indexes and reachability bitmaps.
//!
//! On the disk: the bit count, the word count, that many 64-bit words, and the
//! position of the last run word — every integer big-endian. A word is either
//! a run header, which says how many clean words of one value follow it and
//! how many literal words come after those, or one of those literals.
//!
//! Encoding and decoding are shared by both formats. Decoding is bounded by
//! the caller's index size, rather than the compressed word count.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from reading a bitmap.
pub const Error = error{
    /// The bytes ended inside the header or inside the words.
    TruncatedBitmap,
    /// A run header asked for more words than the bitmap holds.
    CorruptBitmap,
    /// The caller did not authorize this many decoded bits.
    BitmapTooLarge,
};

/// A decoded bitmap: the positions whose bit is set, in ascending order.
pub const Bits = struct {
    pub const Error = ErrorNamespace.Error;

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

/// Errors from `read`.
pub const ReadError = Error || Allocator.Error;

/// Read a bitmap from the front of `bytes`. Returns the set positions and how
/// many bytes the bitmap took.
pub fn read(gpa: Allocator, bytes: []const u8) ReadError!struct {
    bits: Bits,
    len: usize,
} {
    const decoded = try readWords(gpa, bytes, 1 << 26);
    defer gpa.free(decoded.words);
    var positions: std.ArrayList(u32) = .empty;
    errdefer positions.deinit(gpa);
    for (decoded.words, 0..) |word, i| {
        var remaining = word;
        while (remaining != 0) {
            const bit = @ctz(remaining);
            const position = i * 64 + bit;
            if (position < decoded.bit_count) try positions.append(gpa, @intCast(position));
            remaining &= remaining - 1;
        }
    }
    return .{ .bits = .{ .gpa = gpa, .positions = try positions.toOwnedSlice(gpa) }, .len = decoded.len };
}

/// Errors from `readWords`.
pub const ReadWordsError = Error || Allocator.Error;

/// Decode into words, bounded by the number of bits the caller's index holds.
/// Clean runs are expanded into the output, never into an unbounded list of positions.
pub fn readWords(gpa: Allocator, bytes: []const u8, max_bits: u64) ReadWordsError!struct { words: []u64, bit_count: u32, len: usize } {
    if (bytes.len < 8) return error.TruncatedBitmap;
    const bit_count = std.mem.readInt(u32, bytes[0..4], .big);
    const word_count = std.mem.readInt(u32, bytes[4..8], .big);
    if (bit_count > max_bits) return error.BitmapTooLarge;
    const end = 8 + @as(usize, word_count) * 8;
    if (bytes.len < end + 4) return error.TruncatedBitmap;
    if (word_count == 0) return error.CorruptBitmap;
    const last_rlw = std.mem.readInt(u32, bytes[end..][0..4], .big);
    const words = try gpa.alloc(u64, (@as(usize, bit_count) + 63) / 64);
    errdefer gpa.free(words);
    @memset(words, 0);
    var at: usize = 0;
    var out: usize = 0;
    var last_header: usize = 0;
    while (at < word_count) {
        last_header = at;
        const header = std.mem.readInt(u64, bytes[8 + at * 8 ..][0..8], .big);
        at += 1;
        const run: usize = @intCast((header >> 1) & 0xffff_ffff);
        const literals: usize = @intCast(header >> 33);
        if (run > words.len - out or literals > words.len - out - run or literals > word_count - at) return error.CorruptBitmap;
        @memset(words[out .. out + run], if (header & 1 != 0) std.math.maxInt(u64) else 0);
        out += run;
        for (0..literals) |_| {
            words[out] = std.mem.readInt(u64, bytes[8 + at * 8 ..][0..8], .big);
            out += 1;
            at += 1;
        }
    }
    if (last_rlw != last_header) return error.CorruptBitmap;
    if (words.len > 0 and bit_count % 64 != 0) words[words.len - 1] &= (@as(u64, 1) << @as(u6, @intCast(bit_count % 64))) - 1;
    return .{ .words = words, .bit_count = bit_count, .len = end + 4 };
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

/// Errors from `write`.
pub const WriteError = Allocator.Error || error{InvalidBitmapInput};

/// Encode words with git's run headers. The caller chooses the logical bit size:
/// type maps end at their last set bit; reachability maps end at a word boundary.
pub fn write(gpa: Allocator, words: []const u64, bit_count: u32) WriteError![]u8 {
    if (@as(u64, bit_count) > @as(u64, words.len) * 64) return error.InvalidBitmapInput;
    var encoded: std.ArrayList(u64) = .empty;
    defer encoded.deinit(gpa);
    try encoded.append(gpa, 0);
    var rlw: usize = 0;
    for (words) |word| {
        const clean = word == 0 or word == std.math.maxInt(u64);
        const run_bit: u64 = if (word == std.math.maxInt(u64)) 1 else 0;
        const current = encoded.items[rlw];
        const run_len = (current >> 1) & 0xffff_ffff;
        const literals = current >> 33;
        if (clean) {
            if (literals == 0 and run_len < 0xffff_ffff and (run_len == 0 or (current & 1) == run_bit)) {
                encoded.items[rlw] = (current & ~@as(u64, 1)) | run_bit;
                encoded.items[rlw] += 2;
            } else {
                rlw = encoded.items.len;
                try encoded.append(gpa, run_bit | 2);
            }
        } else {
            if (literals == 0x7fff_ffff) {
                rlw = encoded.items.len;
                try encoded.append(gpa, 0);
            }
            encoded.items[rlw] += @as(u64, 1) << 33;
            try encoded.append(gpa, word);
        }
    }
    if (encoded.items.len > std.math.maxInt(u32)) return error.InvalidBitmapInput;
    const bytes = try gpa.alloc(u8, 12 + encoded.items.len * 8);
    std.mem.writeInt(u32, bytes[0..4], bit_count, .big);
    std.mem.writeInt(u32, bytes[4..8], @intCast(encoded.items.len), .big);
    for (encoded.items, 0..) |word, i| std.mem.writeInt(u64, bytes[8 + i * 8 ..][0..8], word, .big);
    std.mem.writeInt(u32, bytes[bytes.len - 4 ..][0..4], @intCast(rlw), .big);
    return bytes;
}

test "a compressed clean run may describe more bits than its encoded words" {
    const bytes = [_]u8{ 0, 0, 0x19, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 200, 0, 0, 0, 0 };
    var result = try read(std.testing.allocator, &bytes);
    defer result.bits.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.bits.positions.len);
}

/// Validate an encoded bitmap without expanding it. Reachability indexes use
/// this at open; only a requested commit's XOR chain needs decoded words.
pub fn encodedLength(bytes: []const u8, max_bits: u64) Error!usize {
    if (bytes.len < 8) return error.TruncatedBitmap;
    const bits = std.mem.readInt(u32, bytes[0..4], .big);
    if (bits > max_bits) return error.BitmapTooLarge;
    const count = std.mem.readInt(u32, bytes[4..8], .big);
    if (count == 0) return error.CorruptBitmap;
    const end = 8 + @as(usize, count) * 8;
    if (bytes.len < end + 4) return error.TruncatedBitmap;
    const max_words = (@as(u64, bits) + 63) / 64;
    var words: u64 = 0;
    var at: usize = 0;
    var last: usize = 0;
    while (at < count) {
        last = at;
        const header = std.mem.readInt(u64, bytes[8 + at * 8 ..][0..8], .big);
        at += 1;
        const run = (header >> 1) & 0xffff_ffff;
        const literals = header >> 33;
        if (literals > count - at or words + run + literals > max_words) return error.CorruptBitmap;
        words += run + literals;
        at += @intCast(literals);
    }
    if (std.mem.readInt(u32, bytes[end..][0..4], .big) != last) return error.CorruptBitmap;
    return end + 4;
}
