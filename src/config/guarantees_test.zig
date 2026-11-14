//! config's documented guarantees as properties, each checked against the
//! git function the doc names, transcribed from git's C, not only "no
//! crash": `checkKey` is `git_config_parse_key`, `parseInteger` is
//! `git_parse_signed` and `git_parse_unsigned` (C's `strtoimax` and
//! `strtoumax` in base 0, a unit, and the type's range as git checks it),
//! `parseBool` is git's spellings and then `git_parse_int`, and `unquote`
//! is `parse_value`'s quotes and escapes.

const std = @import("std");
const shakedown = @import("shakedown");
const config = @import("config.zig");
const testing = std.testing;
const gen = shakedown.gen;

/// Up to `max` pieces drawn from `pieces`, joined into `buffer`, as many as fit.
fn pieced(s: *shakedown.Source, buffer: []u8, pieces: []const []const u8, max: usize) []u8 {
    var len: usize = 0;
    for (0..gen.intRange(s, usize, 0, max)) |_| {
        const piece = gen.oneOf(s, []const u8, pieces);
        if (len + piece.len > buffer.len) break;
        @memcpy(buffer[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buffer[0..len];
}

// checkKey: "the variable is what follows the last dot and must begin with
// a letter; it and the section hold only letters, digits and `-`; the
// subsection between them may hold anything but a line break ... A section
// may be empty only when a subsection follows it".

fn keyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

const key_pieces = [_][]const u8{ "a", "B", "1", "-", ".", "_", " ", "\n", "core", "x.y", "\xc3\xa9", "\"", "\\" };

fn anyKey(_: void, case: *shakedown.Case) !void {
    var buffer: [48]u8 = undefined;
    const full = pieced(case.source, &buffer, &key_pieces, 7);
    const first = std.mem.findScalar(u8, full, '.');
    const last = std.mem.findScalarLast(u8, full, '.');
    const want = blk: {
        if (first == null) break :blk false;
        const section = full[0..first.?];
        const name = full[last.? + 1 ..];
        const has_sub = first.? != last.?;
        if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) break :blk false;
        for (name) |c| if (!keyChar(c)) break :blk false;
        if (section.len == 0 and !has_sub) break :blk false;
        for (section) |c| if (!keyChar(c)) break :blk false;
        if (has_sub and std.mem.findScalar(u8, full[first.? + 1 .. last.?], '\n') != null) break :blk false;
        break :blk true;
    };
    const split = config.checkKey(full) catch |err| {
        try testing.expectEqual(error.InvalidKey, err);
        try testing.expect(!want);
        return;
    };
    try testing.expect(want);
    try testing.expectEqualStrings(full[0..first.?], split.section);
    try testing.expectEqualStrings(full[last.? + 1 ..], split.name);
    if (first.? == last.?) try testing.expectEqual(null, split.subsection) else try testing.expectEqualStrings(full[first.? + 1 .. last.?], split.subsection.?);
}

test "property: a key is checked and split as git's git_config_parse_key does" {
    try shakedown.check(testing.allocator, {}, anyKey, .{ .cases = 20000, .seed = 0xc01 });
}

// parseInteger: "git's git_parse_signed for a signed T and
// git_parse_unsigned for an unsigned one".

/// What git's parse gives: a value, `EINVAL` or `ERANGE`.
const Git = union(enum) { value: i128, invalid, range };

/// C's `strtoimax` (`signed`) or `strtoumax` in base 0: how far it reads,
/// the value, and whether it overflowed (`ERANGE`). `end` is 0 when no
/// digits were read, as C leaves `endptr` at the start.
fn strto(raw: []const u8, signed: bool) struct { end: usize, value: i128, overflow: bool } {
    var i: usize = 0;
    while (i < raw.len and (raw[i] == ' ' or (raw[i] >= '\t' and raw[i] <= '\r'))) i += 1;
    var negative = false;
    if (i < raw.len and (raw[i] == '+' or raw[i] == '-')) {
        negative = raw[i] == '-';
        i += 1;
    }
    var base: u8 = 10;
    if (i + 2 < raw.len and raw[i] == '0' and (raw[i + 1] == 'x' or raw[i + 1] == 'X') and std.ascii.isHex(raw[i + 2])) {
        base = 16;
        i += 2;
    } else if (i < raw.len and raw[i] == '0') base = 8;
    const start = i;
    var magnitude: u128 = 0;
    var big = false;
    while (i < raw.len) : (i += 1) {
        const digit = std.fmt.charToDigit(raw[i], base) catch break;
        if (magnitude > (1 << 100)) big = true else magnitude = magnitude * @as(u128, base) + digit;
    }
    if (i == start) return .{ .end = 0, .value = 0, .overflow = false };
    const overflow = big or if (signed)
        (if (negative) magnitude > @as(u128, 1) << 63 else magnitude > std.math.maxInt(i64))
    else
        magnitude > std.math.maxInt(u64);
    const value: i128 = if (overflow) 0 else if (negative) -@as(i128, @intCast(magnitude)) else @intCast(magnitude);
    return .{ .end = i, .value = value, .overflow = overflow };
}

/// git's `get_unit_factor`: nothing, or one of `k`, `m`, `g` in either case.
fn unitFactor(rest: []const u8) ?i128 {
    if (rest.len == 0) return 1;
    if (std.ascii.eqlIgnoreCase(rest, "k")) return 1024;
    if (std.ascii.eqlIgnoreCase(rest, "m")) return 1024 * 1024;
    if (std.ascii.eqlIgnoreCase(rest, "g")) return 1024 * 1024 * 1024;
    return null;
}

/// git's `git_parse_signed(value, &ret, max)`.
fn gitSigned(raw: []const u8, max: i128) Git {
    if (raw.len == 0) return .invalid;
    const r = strto(raw, true);
    if (r.overflow) return .range;
    if (r.end == 0) return .invalid;
    const factor = unitFactor(raw[r.end..]) orelse return .invalid;
    if ((r.value < 0 and @divTrunc(-max - 1, factor) > r.value) or (r.value > 0 and @divTrunc(max, factor) < r.value)) return .range;
    return .{ .value = r.value * factor };
}

/// git's `git_parse_unsigned(value, &ret, max)`.
fn gitUnsigned(raw: []const u8, max: i128) Git {
    if (raw.len == 0) return .invalid;
    if (std.mem.findScalar(u8, raw, '-') != null) return .invalid;
    const r = strto(raw, false);
    if (r.overflow) return .range;
    if (r.end == 0) return .invalid;
    const factor = unitFactor(raw[r.end..]) orelse return .invalid;
    if (r.value * factor > max) return .range;
    return .{ .value = r.value * factor };
}

fn expectGit(comptime T: type, raw: []const u8) !void {
    const info = @typeInfo(T).int;
    const want = if (info.signedness == .signed) gitSigned(raw, std.math.maxInt(T)) else gitUnsigned(raw, std.math.maxInt(T));
    const got = config.parseInteger(T, raw);
    switch (want) {
        .value => |v| try testing.expectEqual(@as(T, @intCast(v)), try got),
        .invalid => try testing.expectError(error.NotAnInteger, got),
        .range => try testing.expectError(error.OutOfRange, got),
    }
}

const number_pieces = [_][]const u8{
    " ",                   "\t",                  "\n",                   "+",                    "-",          "0",          "1",          "7",       "8",
    "9",                   "x",                   "X",                    "0x",                   "ff",         "F",          "k",          "K",       "m",
    "g",                   "G",                   "z",                    "2147483647",           "2147483648", "4294967295", "4294967296", "2097151", "2097152",
    "9223372036854775807", "9223372036854775808", "18446744073709551615", "18446744073709551616", "8388607",    "8388608",
};

fn anyInteger(_: void, case: *shakedown.Case) !void {
    var buffer: [64]u8 = undefined;
    const raw = pieced(case.source, &buffer, &number_pieces, 5);
    try expectGit(c_int, raw);
    try expectGit(i32, raw);
    try expectGit(i64, raw);
    try expectGit(isize, raw);
    try expectGit(u32, raw);
    try expectGit(c_uint, raw);
    try expectGit(c_ulong, raw);
    try expectGit(usize, raw);
}

test "property: a configured integer reads as git's git_parse_signed and git_parse_unsigned read it" {
    try shakedown.check(testing.allocator, {}, anyInteger, .{ .cases = 20000, .seed = 0xc02 });
}

// parseBool: "git's boolean spellings, and as git's git_config_bool falls
// back, any integer: zero is false, anything else true".

const bool_pieces = number_pieces ++ [_][]const u8{ "true", "TRUE", "yes", "On", "false", "No", "off", "tru", "y", "1" };

fn anyBool(_: void, case: *shakedown.Case) !void {
    var buffer: [64]u8 = undefined;
    const raw = pieced(case.source, &buffer, &bool_pieces, 3);
    const got = config.parseBool(raw);
    if (raw.len == 0) return testing.expectEqual(false, try got);
    for ([_][]const u8{ "true", "yes", "on" }) |word| if (std.ascii.eqlIgnoreCase(raw, word)) return testing.expectEqual(true, try got);
    for ([_][]const u8{ "false", "no", "off" }) |word| if (std.ascii.eqlIgnoreCase(raw, word)) return testing.expectEqual(false, try got);
    switch (gitSigned(raw, std.math.maxInt(c_int))) {
        .value => |v| try testing.expectEqual(v != 0, try got),
        .invalid, .range => try testing.expectError(error.NotABoolean, got),
    }
}

test "property: a configured boolean is git's spellings, else an int, zero false" {
    try shakedown.check(testing.allocator, {}, anyBool, .{ .cases = 20000, .seed = 0xc03 });
}

// unquote: "A value as git's parse_value reads it ... quotes removed, the
// escapes \n, \t, \b, \\ and \" applied, and a backslash before a line
// break joining the lines. Any other escape is error.MalformedValue".

/// git's `parse_value` over text with no comment and no line break of its
/// own: `get_next_char` folds CR LF to LF, so a backslash before a bare
/// CR is an unknown escape.
fn parseValue(raw: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
    var quote = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '"') {
            quote = !quote;
            continue;
        }
        if (c != '\\') {
            try out.append(gpa, c);
            continue;
        }
        i += 1;
        if (i == raw.len) return false;
        const escaped: u8 = switch (raw[i]) {
            '\n' => continue,
            '\r' => if (i + 1 < raw.len and raw[i + 1] == '\n') {
                i += 1;
                continue;
            } else return false,
            't' => '\t',
            'b' => 8,
            'n' => '\n',
            '\\', '"' => raw[i],
            else => return false,
        };
        try out.append(gpa, escaped);
    }
    return !quote;
}

const value_pieces = [_][]const u8{ "a", " ", "\t", "\"", "\\n", "\\t", "\\b", "\\\\", "\\\"", "\\\n", "\\\r\n", "\\\r", "\\x", "\\", "\xc3\xa9" };

fn anyValue(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    var buffer: [48]u8 = undefined;
    const raw = pieced(case.source, &buffer, &value_pieces, 8);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    const ok = try parseValue(raw, &want, gpa);
    const got = config.unquote(gpa, raw) catch |err| {
        try testing.expectEqual(error.MalformedValue, err);
        try testing.expect(!ok);
        return;
    };
    defer gpa.free(got);
    try testing.expect(ok);
    try testing.expectEqualStrings(want.items, got);
}

test "property: a value is unquoted as git's parse_value reads its quotes and escapes" {
    try shakedown.check(testing.allocator, {}, anyValue, .{ .cases = 20000, .seed = 0xc04 });
}
