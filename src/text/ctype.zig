//! git's character classes, which are not C's: git replaces `isspace` and
//! friends with its own table (`sane_ctype`), where a space is one of
//! space, tab, newline and carriage return, never a vertical tab or a form
//! feed. Zig's `std.ascii.isWhitespace` takes those two as well, which
//! gives conflict names, `-w` diffs, mail headers and patch lines another
//! answer than git's.

/// All errors reported by this namespace: none.
pub const Error = error{};

/// The bytes git's `isspace` takes.
pub const space = " \t\n\r";

/// git's `isspace`.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Whether C's `char` is signed where relic runs (x86, every Apple and
/// Windows target), which is where git, comparing a `char`, reads a byte
/// with its high bit set as negative; where it is unsigned (Linux on ARM,
/// RISC-V, PowerPC) git reads it as it is.
pub const char_signed = (builtin.target.cCharSignedness() orelse .signed) == .signed;

/// A byte as git compares a `char` with an ASCII one: negative where
/// `char` is signed and the high bit is set.
pub fn asChar(c: u8) i16 {
    return if (char_signed) @as(i8, @bitCast(c)) else c;
}

const std = @import("std");
const builtin = @import("builtin");

test "a vertical tab and a form feed are not git's spaces" {
    for (space) |c| try std.testing.expect(isSpace(c));
    try std.testing.expect(!isSpace(0x0b));
    try std.testing.expect(!isSpace(0x0c));
    try std.testing.expect(std.ascii.isWhitespace(0x0b));
}
