//! Percent escapes as git reads them: `%` and two hex digits, each digit
//! by git's `hex2chr`, so a sign or a space is never a digit, and an escape
//! that is not one stays as it stands. The `%xHH` of a format string is the
//! same pair of digits.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The byte two hex digits name, or `null` when either is not one: git's
/// `hex2chr`.
pub fn hexPair(high: u8, low: u8) ?u8 {
    const h = digit(high) orelse return null;
    const l = digit(low) orelse return null;
    return h << 4 | l;
}

fn digit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// The byte the escape at `text[at]` names, when `text[at..]` begins with
/// `%` and two hex digits; `null` otherwise.
pub fn escapeAt(text: []const u8, at: usize) ?u8 {
    if (at + 3 > text.len or text[at] != '%') return null;
    return hexPair(text[at + 1], text[at + 2]);
}

/// What decoding does with an escape that names a zero byte.
pub const Nul = enum {
    /// Decode it, as git's `url_decode` does.
    decode,
    /// Keep it as written, as git's credential URL parsing does.
    literal,
};

/// `text` with every escape decoded, in `gpa`: git's `url_decode` (without
/// `+` for a space). An escape that is not one stays as it stands.
pub fn decode(gpa: Allocator, text: []const u8, nul: Nul) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, text.len);
    errdefer gpa.free(out);
    const len = decodeInto(out, text, nul);
    return gpa.realloc(out, len);
}

/// `decode` into `out`, which holds at least `text.len` bytes and may be
/// `text` itself: the decoded length.
pub fn decodeInto(out: []u8, text: []const u8, nul: Nul) usize {
    std.debug.assert(out.len >= text.len);
    var read: usize = 0;
    var write: usize = 0;
    while (read < text.len) {
        if (escapeAt(text, read)) |byte| if (byte != 0 or nul == .decode) {
            out[write] = byte;
            write += 1;
            read += 3;
            continue;
        };
        out[write] = text[read];
        write += 1;
        read += 1;
    }
    return write;
}

test "escapes are read as git reads them" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u8, 0x41), hexPair('4', '1'));
    try testing.expectEqual(@as(?u8, 0xff), hexPair('F', 'f'));
    // A sign is not a digit, as `parseInt` would take it.
    try testing.expectEqual(@as(?u8, null), hexPair('+', '1'));
    try testing.expectEqual(@as(?u8, null), hexPair(' ', '1'));
    try testing.expectEqual(@as(?u8, null), escapeAt("%4", 0));
    try testing.expectEqual(@as(?u8, '\n'), escapeAt("a%0a", 1));

    const gpa = testing.allocator;
    const plain = try decode(gpa, "a%20b%2%zz%+1%41", .decode);
    defer gpa.free(plain);
    try testing.expectEqualStrings("a b%2%zz%+1A", plain);
    const kept = try decode(gpa, "x%00y", .literal);
    defer gpa.free(kept);
    try testing.expectEqualStrings("x%00y", kept);
    const nul = try decode(gpa, "x%00y", .decode);
    defer gpa.free(nul);
    try testing.expectEqualStrings("x\x00y", nul);
}
