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
const shakedown = @import("shakedown");
const Rows = @import("rows.zig").Rows;
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
    var r: std.Io.Reader = .fixed(bytes);
    const bit_count = r.takeInt(u32, .big) catch return error.TruncatedBitmap;
    const word_count = r.takeInt(u32, .big) catch return error.TruncatedBitmap;
    if (bit_count > max_bits) return error.BitmapTooLarge;
    const table = Rows.cut(bytes, 8, word_count, 8) orelse return error.TruncatedBitmap;
    r.discardAll(table.bytes.len) catch return error.TruncatedBitmap;
    const last_rlw = r.takeInt(u32, .big) catch return error.TruncatedBitmap;
    if (word_count == 0) return error.CorruptBitmap;
    const word_total = wordsFor(bit_count);
    if (word_total > max_words) return error.BitmapTooLarge;
    const words = try gpa.alloc(u64, word_total);
    errdefer gpa.free(words);
    @memset(words, 0);
    // What is left to fill, and the stored words still to read.
    var rest = words;
    var stored: std.Io.Reader = .fixed(table.bytes);
    var last_header: usize = 0;
    while (stored.seek < table.bytes.len) {
        last_header = stored.seek / 8;
        const header = stored.takeInt(u64, .big) catch return error.CorruptBitmap;
        const run: u32 = @truncate(header >> 1);
        const literals: u31 = @truncate(header >> 33);
        if (run > rest.len) return error.CorruptBitmap;
        @memset(rest[0..run], if (header & 1 != 0) std.math.maxInt(u64) else 0);
        rest = rest[run..];
        if (literals > rest.len) return error.CorruptBitmap;
        for (rest[0..literals]) |*word| word.* = stored.takeInt(u64, .big) catch return error.CorruptBitmap;
        rest = rest[literals..];
    }
    if (last_rlw != last_header) return error.CorruptBitmap;
    if (words.len > 0 and bit_count % 64 != 0) words[words.len - 1] &= (@as(u64, 1) << @as(u6, @truncate(bit_count))) - 1;
    return .{ .words = words, .bit_count = bit_count, .len = r.seek };
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
    try shakedown.check(std.testing.allocator, {}, fuzzOne, .{});
}

fn fuzzOne(_: void, case: *shakedown.Case) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [512]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
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

/// The most words a bitmap holds: its bit count is 32 bits wide.
const max_words = 1 << 26;

/// The 64-bit words `bits` bits take.
fn wordsFor(bits: u32) usize {
    return (@as(usize, bits) >> 6) + @intFromBool(bits & 63 != 0);
}

/// Validate an encoded bitmap without expanding it. Reachability indexes use
/// this at open; only a requested commit's XOR chain needs decoded words.
pub fn encodedLength(bytes: []const u8, max_bits: u64) Error!usize {
    var r: std.Io.Reader = .fixed(bytes);
    const bits = r.takeInt(u32, .big) catch return error.TruncatedBitmap;
    const count = r.takeInt(u32, .big) catch return error.TruncatedBitmap;
    if (bits > max_bits) return error.BitmapTooLarge;
    if (count == 0) return error.CorruptBitmap;
    const table = Rows.cut(bytes, 8, count, 8) orelse return error.TruncatedBitmap;
    r.discardAll(table.bytes.len) catch return error.TruncatedBitmap;
    const last_rlw = r.takeInt(u32, .big) catch return error.TruncatedBitmap;
    // The words the bits still have room for.
    var room: u64 = wordsFor(bits);
    var stored: std.Io.Reader = .fixed(table.bytes);
    var last: usize = 0;
    while (stored.seek < table.bytes.len) {
        last = stored.seek / 8;
        const header = stored.takeInt(u64, .big) catch return error.CorruptBitmap;
        const run: u32 = @truncate(header >> 1);
        const literals: u31 = @truncate(header >> 33);
        room = std.math.sub(u64, room, run) catch return error.CorruptBitmap;
        room = std.math.sub(u64, room, literals) catch return error.CorruptBitmap;
        for (0..literals) |_| _ = stored.takeInt(u64, .big) catch return error.CorruptBitmap;
    }
    if (last_rlw != last) return error.CorruptBitmap;
    return r.seek;
}

/// Encode the bitmap with `positions` set, which must rise, as git's
/// `ewah_set` builds one bit at a time: it ends at its last set bit.
pub fn writePositions(gpa: Allocator, positions: []const u32) Allocator.Error![]u8 {
    var bit_count: u32 = 0;
    if (positions.len != 0) bit_count = positions[positions.len - 1] + 1;
    const words = try gpa.alloc(u64, wordsFor(bit_count));
    defer gpa.free(words);
    @memset(words, 0);
    for (positions) |p| words[p / 64] |= @as(u64, 1) << @intCast(p % 64);
    return write(gpa, words, bit_count) catch |err| switch (err) {
        error.InvalidBitmapInput => unreachable, // unreachable: the words hold every bit counted
        error.OutOfMemory => |e| return e,
    };
}

test "a bitmap of positions reads back as them" {
    const gpa = std.testing.allocator;
    for ([_][]const u32{ &.{}, &.{0}, &.{ 1, 5, 64, 200 }, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 70 } }) |positions| {
        const bytes = try writePositions(gpa, positions);
        defer gpa.free(bytes);
        var back = try read(gpa, bytes);
        defer back.bits.deinit();
        try std.testing.expectEqualSlices(u32, positions, back.bits.positions);
        try std.testing.expectEqual(bytes.len, back.len);
    }
}
