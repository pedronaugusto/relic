//! git's C-style path quoting: how a path with a control character, a
//! quote, a backslash or (with `core.quotePath` on, its default) a byte
//! above 0x7f is written in a patch, a diffstat or a listing, and how such a
//! name is read back.
//!
//! A path that needs none of it is written bare. One that does is written
//! between double quotes with `\a \b \t \n \v \f \r \" \\` for those bytes
//! and three octal digits for every other byte that needs escaping, which
//! is `quote_c_style` in git's `quote.c`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How a byte is written inside quotes: its escape letter, `1` for three
/// octal digits, `-1` for itself, `0` for a byte above 0x7f, which is
/// itself unless `core.quotePath` asks for octal.
const lookup: [256]i8 = blk: {
    var t: [256]i8 = undefined;
    for (&t, 0..) |*v, i| {
        v.* = if (i < 0x20) 1 else if (i < 0x7f) -1 else if (i == 0x7f) 1 else 0;
    }
    t[0x07] = 'a';
    t[0x08] = 'b';
    t[0x09] = 't';
    t[0x0a] = 'n';
    t[0x0b] = 'v';
    t[0x0c] = 'f';
    t[0x0d] = 'r';
    t['"'] = '"';
    t['\\'] = '\\';
    break :blk t;
};

fn mustQuote(c: u8, fully: bool) bool {
    return @as(i16, lookup[c]) + @intFromBool(fully) > 0;
}

/// Whether `name` is written quoted. `fully` is `core.quotePath`, on by
/// default, under which a byte above 0x7f needs quoting too.
pub fn needsQuote(name: []const u8, fully: bool) bool {
    for (name) |c| if (mustQuote(c, fully)) return true;
    return false;
}

/// Write `name` as git writes a path: bare when nothing in it needs
/// quoting, otherwise between double quotes with its escapes.
pub fn write(w: *Io.Writer, name: []const u8, fully: bool) Io.Writer.Error!void {
    if (!needsQuote(name, fully)) return w.writeAll(name);
    try w.writeByte('"');
    try writeBody(w, name, fully);
    try w.writeByte('"');
}

/// The escaped text of `name` without the surrounding quotes, which is
/// what git writes for the parts of a name it quotes as one.
pub fn writeBody(w: *Io.Writer, name: []const u8, fully: bool) Io.Writer.Error!void {
    for (name) |c| {
        if (!mustQuote(c, fully)) {
            try w.writeByte(c);
            continue;
        }
        try w.writeByte('\\');
        const e = lookup[c];
        if (e >= ' ') {
            try w.writeByte(@intCast(e));
        } else {
            try w.writeByte('0' + ((c >> 6) & 3));
            try w.writeByte('0' + ((c >> 3) & 7));
            try w.writeByte('0' + (c & 7));
        }
    }
}

/// The width `write` gives `name`: its length, or the quoted length.
pub fn quotedLen(name: []const u8, fully: bool) usize {
    if (!needsQuote(name, fully)) return name.len;
    var n: usize = 2;
    for (name) |c| {
        if (!mustQuote(c, fully)) {
            n += 1;
        } else if (lookup[c] >= ' ') {
            n += 2;
        } else {
            n += 4;
        }
    }
    return n;
}

/// `name` quoted, allocated.
pub fn alloc(gpa: Allocator, name: []const u8, fully: bool) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, name, fully) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What `unquote` read.
pub const Unquoted = struct {
    /// The name, the caller's.
    name: []u8,
    /// How many bytes of the input the quoted name took, both quotes
    /// included.
    consumed: usize,
};

/// Read a quoted name at the start of `text`, which must begin with `"`.
/// `null` when it is not a well-formed quoted name, which is where git's
/// `unquote_c_style` gives up too: an unknown escape, an octal escape
/// whose first digit is above 3, or no closing quote.
pub fn unquote(gpa: Allocator, text: []const u8) Allocator.Error!?Unquoted {
    if (text.len == 0 or text[0] != '"') return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 1;
    while (i < text.len) {
        const c = text[i];
        i += 1;
        switch (c) {
            '"' => return .{ .name = try out.toOwnedSlice(gpa), .consumed = i },
            '\\' => {
                if (i >= text.len) break;
                const e = text[i];
                i += 1;
                const byte: u8 = switch (e) {
                    'a' => 0x07,
                    'b' => 0x08,
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'v' => 0x0b,
                    '\\', '"' => e,
                    '0'...'3' => blk: {
                        if (i + 2 > text.len) {
                            out.deinit(gpa);
                            return null;
                        }
                        const d1 = text[i];
                        const d2 = text[i + 1];
                        if (d1 < '0' or d1 > '7' or d2 < '0' or d2 > '7') {
                            out.deinit(gpa);
                            return null;
                        }
                        i += 2;
                        break :blk ((e - '0') << 6) | ((d1 - '0') << 3) | (d2 - '0');
                    },
                    else => {
                        out.deinit(gpa);
                        return null;
                    },
                };
                try out.append(gpa, byte);
            },
            // a NUL or a newline ends the line the name is on, as the C
            // string git scans ends
            0, '\n' => break,
            else => try out.append(gpa, c),
        }
    }
    out.deinit(gpa);
    return null;
}

test "a plain path is written bare and an odd one quoted as git quotes it" {
    const gpa = std.testing.allocator;
    const plain = try alloc(gpa, "src/main.zig", true);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("src/main.zig", plain);
    const odd = try alloc(gpa, "a\tb\"c\\d\x01\xc3\xa9", true);
    defer gpa.free(odd);
    try std.testing.expectEqualStrings("\"a\\tb\\\"c\\\\d\\001\\303\\251\"", odd);
    const loose = try alloc(gpa, "caf\xc3\xa9", false);
    defer gpa.free(loose);
    try std.testing.expectEqualStrings("caf\xc3\xa9", loose);
    try std.testing.expectEqual(odd.len, quotedLen("a\tb\"c\\d\x01\xc3\xa9", true));
}

test "a quoted name reads back, and a malformed one is refused" {
    const gpa = std.testing.allocator;
    const got = (try unquote(gpa, "\"a\\tb\\303\\251\" rest")).?;
    defer gpa.free(got.name);
    try std.testing.expectEqualStrings("a\tb\xc3\xa9", got.name);
    try std.testing.expectEqual(@as(usize, 14), got.consumed);
    try std.testing.expect((try unquote(gpa, "\"a\\q\"")) == null);
    try std.testing.expect((try unquote(gpa, "\"a\\400\"")) == null);
    try std.testing.expect((try unquote(gpa, "\"open")) == null);
    try std.testing.expect((try unquote(gpa, "bare")) == null);
}

/// All errors reported by this namespace.
pub const Error = Io.Writer.Error || Allocator.Error;
