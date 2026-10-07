//! Byte strings for test inputs.

/// `count` copies of `text`, end to end, known at compile time.
pub inline fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    const copies: [count][text.len]u8 = @splat(text[0..text.len].*);
    return @ptrCast(&copies); // safe: count arrays of text.len bytes lie end to end, text.len * count bytes
}

test "repeat lays the copies end to end" {
    const std = @import("std");
    try std.testing.expectEqualStrings("abababab", repeat("ab", 4));
    try std.testing.expectEqualStrings("x/ab/ab/y", "x" ++ repeat("/ab", 2) ++ "/y");
    try std.testing.expectEqual(0, repeat("ab", 0).len);
}
