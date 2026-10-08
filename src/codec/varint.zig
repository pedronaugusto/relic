//! The two varints git uses, which are not the same encoding.
//!
//! The *size* varint carries seven bits per byte, little-endian, and is what a
//! delta's two sizes and a pack entry's length use. The *offset* varint adds
//! one at every continuation so that no value has two spellings, and is what
//! an `ofs-delta` base and an index v4 path prefix use. Reading one with the
//! other is the classic way to read a pack slightly wrong.

const std = @import("std");

/// Errors from reading a varint.
pub const Error = error{
    /// The bytes ended in the middle of the number.
    Truncated,
    /// More than 64 bits of value.
    Overflow,
};

/// Read an offset varint — the biased one. Returns the value and its length.
pub fn readOffset(bytes: []const u8) Error!struct { value: u64, len: usize } {
    if (bytes.len == 0) return error.Truncated;
    var i: usize = 0;
    var c = bytes[i];
    i += 1;
    var value: u64 = c & 0x7f;
    while (c & 0x80 != 0) {
        if (i >= bytes.len) return error.Truncated;
        value = std.math.add(u64, value, 1) catch return error.Overflow;
        c = bytes[i];
        i += 1;
        value = std.math.shlExact(u64, value, 7) catch return error.Overflow;
        value |= c & 0x7f;
    }
    return .{ .value = value, .len = i };
}

/// Write an offset varint into `buf`, which must hold at least ten bytes.
/// Returns the bytes written.
pub fn writeOffset(buf: []u8, value: u64) []const u8 {
    var scratch: [16]u8 = undefined;
    var pos: usize = scratch.len - 1;
    var v = value;
    scratch[pos] = @intCast(v & 0x7f);
    while (v >> 7 != 0) {
        v >>= 7;
        v -= 1;
        pos -= 1;
        scratch[pos] = @as(u8, 0x80) | @as(u8, @intCast(v & 0x7f));
    }
    const len = scratch.len - pos;
    @memcpy(buf[0..len], scratch[pos..]);
    return buf[0..len];
}

test "offset varints round trip and have one spelling each" {
    var buf: [16]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 129, 255, 16_383, 16_384, 1 << 40 }) |value| {
        const written = writeOffset(&buf, value);
        const read = try readOffset(written);
        try std.testing.expectEqual(value, read.value);
        try std.testing.expectEqual(written.len, read.len);
    }
}

test "a truncated offset varint is a named error" {
    try std.testing.expectError(error.Truncated, readOffset(&.{}));
    try std.testing.expectError(error.Truncated, readOffset(&.{0x80}));
}
