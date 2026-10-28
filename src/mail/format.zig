//! The pieces of an email git writes and reads: RFC 2047 encoded words,
//! RFC 822 quoting, and git's text wrapping, each as git's `pretty.c` and
//! `utf8.c` produce them. An RFC 2822 date is `text.date.show`'s.

const std = @import("std");
const ctype = @import("../text.zig").ctype;
const Allocator = std.mem.Allocator;

const unicode_width = @import("../text.zig").unicode_width;
const text_encoding = @import("../text.zig").encoding;

/// A calendar date and time of day.
pub const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};

/// The UTC calendar time of `secs` since the epoch.
pub fn civil(secs: i64) Civil {
    const days = @divFloor(secs, 86400);
    const rem: i64 = secs - days * 86400;
    // Howard Hinnant's days-to-civil
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const weekday = @mod(days + 4, 7);
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(rem, 3600)),
        .minute = @intCast(@divFloor(@mod(rem, 3600), 60)),
        .second = @intCast(@mod(rem, 60)),
        .weekday = @intCast(weekday),
    };
}

/// git's `non_ascii`: a byte with the high bit, or an escape.
pub fn nonAscii(c: u8) bool {
    return c >= 0x80 or c == 0x1b;
}

/// Whether `s` has a byte `nonAscii` calls so.
pub fn hasNonAscii(s: []const u8) bool {
    for (s) |c| if (nonAscii(c)) return true;
    return false;
}

fn isRfc822Special(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', ':', ';', '@', ',', '.', '"', '\\' => true,
        else => false,
    };
}

/// Whether a display name must be quoted.
pub fn needsRfc822Quoting(s: []const u8) bool {
    for (s) |c| if (isRfc822Special(c)) return true;
    return false;
}

/// `"name"`, with `"` and `\` escaped.
pub fn writeRfc822Quoted(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// Whether a header value must become encoded words.
pub fn needsRfc2047(s: []const u8) bool {
    for (s, 0..) |c, i| {
        if (nonAscii(c) or c == '\n') return true;
        if (i + 1 < s.len and c == '=' and s[i + 1] == '?') return true;
    }
    return false;
}

/// Where the encoded words go.
pub const Rfc2047Kind = enum { subject, address };

fn isPrint(c: u8) bool {
    return c >= 0x20 and c < 0x7f;
}

fn isRfc2047Special(c: u8, kind: Rfc2047Kind) bool {
    if (nonAscii(c) or !isPrint(c)) return true;
    if (ctype.isSpace(c) or c == '=' or c == '?' or c == '_') return true;
    if (kind != .address) return false;
    return !(std.ascii.isAlphanumeric(c) or c == '!' or c == '*' or c == '+' or c == '-' or c == '/');
}

/// `line`, text in `encoding`, as RFC 2047 `Q`-encoded words naming it,
/// on a line `column` columns in, breaking before 76 columns as git's
/// `add_rfc2047` does,
/// never inside a UTF-8 character; text in another encoding is taken a
/// byte to a character, as git takes it.
pub fn writeRfc2047(out: *std.Io.Writer, line: []const u8, encoding: []const u8, kind: Rfc2047Kind, column: usize) std.Io.Writer.Error!void {
    const max_encoded_length = 76;
    const utf8 = text_encoding.isUtf8(encoding);
    var line_len = column;
    try out.print("=?{s}?q?", .{encoding});
    line_len += encoding.len + 5;
    var at: usize = 0;
    while (at < line.len) {
        const chrlen: usize = if (!utf8) 1 else if (unicode_width.decode(line[at..])) |decoded| decoded.len else 1;
        const p = line[at .. at + chrlen];
        const special = chrlen > 1 or isRfc2047Special(p[0], kind);
        const encoded_len: usize = if (special) 3 * chrlen else 1;
        if (line_len + encoded_len + 2 > max_encoded_length) {
            try out.print("?=\n =?{s}?q?", .{encoding});
            line_len = encoding.len + 5 + 1;
        }
        for (p) |b| {
            if (special) try out.print("={X:0>2}", .{b}) else try out.writeByte(b);
        }
        line_len += encoded_len;
        at += chrlen;
    }
    try out.writeAll("?=");
}

/// git's `strbuf_add_wrapped_text`: `text` wrapped at `width` columns, the
/// first line indented by `indent1` (negative: that many columns are
/// already used) and the rest by `indent2`. A zero `width` indents only.
pub fn writeWrapped(out: *std.Io.Writer, text_in: []const u8, indent1: i32, indent2: i32, width: i32) std.Io.Writer.Error!void {
    // the text as git sees it: up to its first NUL
    const text = if (std.mem.findScalar(u8, text_in, 0)) |z| text_in[0..z] else text_in;
    if (width <= 0) {
        try writeIndented(out, text, indent1, indent2);
        return;
    }
    // git starts again counting bytes at the first character that does
    // not decode, dropping what it wrote: asked once, before writing.
    const assume_utf8 = decodable(text);
    {
        var pos: usize = 0;
        var bol: usize = 0;
        var indent = indent1;
        var w: i32 = indent1;
        var space: ?usize = null;
        if (indent < 0) {
            // Saturating: the most negative indent has no positive i32.
            w = 0 -| indent;
            space = 0;
        }
        while (true) {
            while (escapeLen(text[pos..])) |skip| pos += skip;
            const c: u8 = if (pos < text.len) text[pos] else 0;
            if (c == 0 or ctype.isSpace(c)) {
                if (w <= width or space == null) {
                    var start = bol;
                    if (c == 0 and pos == start) return;
                    if (space) |s| {
                        start = s;
                    } else try out.splatByteAll(' ', @abs(@max(indent, 0)));
                    try out.writeAll(text[start..pos]);
                    if (c == 0) return;
                    space = pos;
                    if (c == '\t') {
                        w |= 0x07;
                    } else if (c == '\n') {
                        const next = pos + 1;
                        space = next;
                        const nc: u8 = if (next < text.len) text[next] else 0;
                        if (nc == '\n') {
                            try out.writeByte('\n');
                            // new_line
                            try out.writeByte('\n');
                            pos = next + @intFromBool(ctype.isSpace(nc));
                            bol = pos;
                            space = null;
                            indent = indent2;
                            w = indent2;
                            continue;
                        } else if (!std.ascii.isAlphanumeric(nc)) {
                            try out.writeByte('\n');
                            pos = next + @intFromBool(next < text.len and ctype.isSpace(text[next]));
                            bol = pos;
                            space = null;
                            indent = indent2;
                            w = indent2;
                            continue;
                        } else {
                            try out.writeByte(' ');
                        }
                    }
                    w +|= 1;
                    pos += 1;
                } else {
                    // new_line
                    try out.writeByte('\n');
                    const s = space.?;
                    pos = s + @intFromBool(s < text.len and ctype.isSpace(text[s]));
                    bol = pos;
                    space = null;
                    indent = indent2;
                    w = indent2;
                }
                continue;
            }
            if (assume_utf8) {
                // unreachable: `decodable` decoded every character the wrap measures
                const decoded = unicode_width.decode(text[pos..]) orelse unreachable;
                // Saturating: a line past an i32 of columns is past any width.
                w +|= unicode_width.width(decoded.char);
                pos += decoded.len;
            } else {
                w +|= 1;
                pos += 1;
            }
        }
    }
}

/// Whether every character `strbuf_add_wrapped_text` measures decodes as
/// UTF-8: those it skips (colour escapes, white space) aside, in order.
fn decodable(text: []const u8) bool {
    var pos: usize = 0;
    while (true) {
        while (escapeLen(text[pos..])) |skip| pos += skip;
        if (pos >= text.len) return true;
        if (ctype.isSpace(text[pos])) {
            pos += 1;
            continue;
        }
        const decoded = unicode_width.decode(text[pos..]) orelse return false;
        pos += decoded.len;
    }
}

fn escapeLen(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != 0x1b or s[1] != '[') return null;
    var i: usize = 2;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == ';')) i += 1;
    if (i >= s.len or s[i] != 'm') return null;
    return i + 1;
}

fn writeIndented(out: *std.Io.Writer, text_in: []const u8, indent_in: i32, indent2: i32) std.Io.Writer.Error!void {
    var indent: i32 = if (indent_in < 0) 0 else indent_in;
    var text = text_in;
    while (text.len > 0) {
        const eol = std.mem.findScalar(u8, text, '\n');
        const len = if (eol) |e| e + 1 else text.len;
        try out.splatByteAll(' ', @abs(@max(indent, 0)));
        try out.writeAll(text[0..len]);
        text = text[len..];
        indent = indent2;
    }
}

test "encoded words, quoting and wrapping come out as git's" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("From: ");
    try writeRfc2047(&out.writer, "J\xc3\xb6hn D\xc5\x93", "UTF-8", .address, "From: ".len);
    try std.testing.expectEqualStrings("From: =?UTF-8?q?J=C3=B6hn=20D=C5=93?=", out.written());
    var wrapped: std.Io.Writer.Allocating = .init(gpa);
    defer wrapped.deinit();
    try writeWrapped(&wrapped.writer, "a b c", -9, 1, 78);
    try std.testing.expectEqualStrings("a b c", wrapped.written());
}

/// All errors reported by this namespace.
pub const Error = std.Io.Writer.Error || Allocator.Error;
