//! Numbers in git's data, read by git's rules and no others. Zig's
//! `std.fmt.parseInt` takes a `+` and `_` between digits, which no git
//! reader does: each grammar here is one git uses.
//!
//! - `digits`: one or more ASCII digits and nothing else, git's
//!   `isdigit` loops and the strict fields of objects, indexes and packs.
//! - `strtol` and `strtoul`: C's, as git calls them, leading spaces, a sign
//!   and a base included, with where the number ended; `whole` is the same
//!   when the number must be all of the text (git's `strtol_i`,
//!   `strtoul_ui`).

const std = @import("std");

/// All errors reported by this namespace: none, a text that is no number
/// reads as `null`.
pub const Error = error{};

/// `text` read as one or more decimal digits and nothing else, or `null`
/// when it is not one or does not fit `T`.
pub fn digits(comptime T: type, text: []const u8) ?T {
    if (text.len == 0) return null;
    var value: T = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = std.math.mul(T, value, 10) catch return null;
        value = std.math.add(T, value, @intCast(c - '0')) catch return null;
    }
    return value;
}

/// `text` as Go's `strconv.ParseInt(text, 10, ...)` reads it, which is how
/// git-lfs reads its numbers: an optional sign, then decimal digits and
/// nothing else. `null` when it is not one or does not fit `T`.
pub fn goInt(comptime T: type, text: []const u8) ?T {
    if (text.len == 0) return null;
    const negative = text[0] == '-';
    const body = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    const magnitude = digits(u128, body) orelse return null;
    if (negative) {
        if (magnitude > @as(u128, 1) << 127) return null;
        const value: i128 = if (magnitude == @as(u128, 1) << 127) std.math.minInt(i128) else -@as(i128, @intCast(magnitude));
        return std.math.cast(T, value);
    }
    return std.math.cast(T, magnitude);
}

/// What C's `strtol` and `strtoul` read.
pub const Read = struct {
    /// The value, clamped as C clamps it when it overflowed.
    value: i128,
    /// How many bytes the number took: 0 when there was none, as C's
    /// `endptr` is the start then.
    end: usize,
    /// The value did not fit, C's `ERANGE`.
    overflow: bool,
};

/// C's `isspace` in the C locale, which `strtol` skips.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// C's `strtol(text, &end, base)` for a `long` of `bits` bits: leading
/// spaces, an optional sign, then digits of `base` (0 takes `0x` as
/// hexadecimal and a leading `0` as octal).
pub fn strtol(text: []const u8, base: u8, comptime bits: u16) Read {
    return read(text, base, std.math.minInt(@Int(.signed, bits)), std.math.maxInt(@Int(.signed, bits)), false);
}

/// C's `strtoul` for an unsigned long of `bits` bits: as `strtol`, a minus
/// sign negating the value modulo the type's range, as C does.
pub fn strtoul(text: []const u8, base: u8, comptime bits: u16) Read {
    return read(text, base, 0, std.math.maxInt(@Int(.unsigned, bits)), true);
}

fn read(text: []const u8, base_in: u8, min: i128, max: i128, unsigned: bool) Read {
    std.debug.assert(base_in == 0 or (base_in >= 2 and base_in <= 36));
    var i: usize = 0;
    while (i < text.len and isSpace(text[i])) i += 1;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var base: u8 = base_in;
    if ((base == 0 or base == 16) and i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X') and
        i + 2 < text.len and digitValue(text[i + 2]) < 16)
    {
        i += 2;
        base = 16;
    } else if (base == 0) {
        base = if (i < text.len and text[i] == '0') 8 else 10;
    }
    const first = i;
    var magnitude: u128 = 0;
    var overflow = false;
    while (i < text.len) : (i += 1) {
        const d = digitValue(text[i]);
        if (d >= base) break;
        if (!overflow) {
            const next = @as(u256, magnitude) * base + d;
            if (next > std.math.maxInt(u128)) overflow = true else magnitude = @intCast(next);
        }
    }
    if (i == first) return .{ .value = 0, .end = 0, .overflow = false };
    const limit: u128 = if (unsigned or !negative) @intCast(max) else @intCast(-min);
    if (overflow or magnitude > limit) {
        return .{ .value = if (unsigned) max else if (negative) min else max, .end = i, .overflow = true };
    }
    if (unsigned and negative) {
        // C's unsigned negation: the value modulo the type's range.
        const range: u128 = @as(u128, @intCast(max)) + 1;
        return .{ .value = @intCast((range - magnitude) % range), .end = i, .overflow = false };
    }
    const signed: i128 = @intCast(magnitude);
    return .{ .value = if (negative) -signed else signed, .end = i, .overflow = false };
}

fn digitValue(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => 36,
    };
}

/// `strtol` over all of `text` into `T`: git's `strtol_i` and `strtoul_ui`
/// pattern, a number that is the whole text, did not overflow and fits.
pub fn whole(comptime T: type, text: []const u8, base: u8) ?T {
    const info = @typeInfo(T).int;
    const r = if (info.signedness == .signed) strtol(text, base, 64) else strtoul(text, base, 64);
    if (r.end == 0 or r.end != text.len or r.overflow) return null;
    return std.math.cast(T, r.value);
}

test "digits are digits and nothing else" {
    try std.testing.expectEqual(@as(?u32, 42), digits(u32, "42"));
    try std.testing.expectEqual(@as(?u32, 7), digits(u32, "007"));
    for ([_][]const u8{ "", "+1", "-1", "1_0", " 1", "1 ", "0x1", "4294967296" }) |text| {
        try std.testing.expectEqual(@as(?u32, null), digits(u32, text));
    }
}

test "goInt reads as Go's strconv reads" {
    try std.testing.expectEqual(@as(?i64, -5), goInt(i64, "-5"));
    try std.testing.expectEqual(@as(?i64, 5), goInt(i64, "+5"));
    try std.testing.expectEqual(@as(?u64, null), goInt(u64, "-5"));
    for ([_][]const u8{ "", "+", "1_0", " 1", "0x1" }) |text| try std.testing.expectEqual(@as(?i64, null), goInt(i64, text));
}

test "strtol reads as C reads: spaces, a sign, a base, and where it stopped" {
    const r = strtol("  -12abc", 10, 64);
    try std.testing.expectEqual(@as(i128, -12), r.value);
    try std.testing.expectEqual(@as(usize, 5), r.end);
    try std.testing.expectEqual(@as(i128, 16), strtol("0x10", 0, 64).value);
    try std.testing.expectEqual(@as(i128, 8), strtol("010", 0, 64).value);
    try std.testing.expectEqual(@as(i128, 0), strtol("0x", 0, 64).value);
    try std.testing.expectEqual(@as(usize, 1), strtol("0x", 0, 64).end);
    try std.testing.expectEqual(@as(usize, 0), strtol("x", 10, 64).end);
    try std.testing.expectEqual(@as(usize, 0), strtol("-", 10, 64).end);
    const big = strtol("99999999999999999999", 10, 64);
    try std.testing.expect(big.overflow);
    try std.testing.expectEqual(@as(i128, std.math.maxInt(i64)), big.value);
    try std.testing.expectEqual(@as(i128, std.math.maxInt(u64)), strtoul("-1", 10, 64).value);
    try std.testing.expectEqual(@as(?u16, null), whole(u16, "1_0", 10));
    try std.testing.expectEqual(@as(?u16, 10), whole(u16, "+10", 10));
    try std.testing.expectEqual(@as(?u16, null), whole(u16, "10 ", 10));
    try std.testing.expectEqual(@as(?i32, -5), whole(i32, " -5", 10));
}
