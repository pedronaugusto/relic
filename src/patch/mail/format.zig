//! The pieces of an email git writes and reads: RFC 2822 dates, RFC 2047
//! encoded words, RFC 822 quoting, and git's text wrapping, each as git's
//! `date.c`, `pretty.c` and `utf8.c` produce them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const unicodewidth = @import("../../unicodewidth.zig");

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

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

/// git's `tz` integer for an offset in minutes: `+0100` is 100.
pub fn tzInt(offset_minutes: i32) i32 {
    const abs: i32 = @intCast(@abs(offset_minutes));
    const v = @divTrunc(abs, 60) * 100 + @rem(abs, 60);
    return if (offset_minutes < 0) -v else v;
}

/// `Tue, 14 Nov 2023 23:13:20 +0100`: git's `DATE_RFC2822`, in the
/// author's own zone.
pub fn writeRfc2822(w: *std.Io.Writer, secs: i64, offset_minutes: i32) std.Io.Writer.Error!void {
    const c = civil(secs + @as(i64, offset_minutes) * 60);
    const tz = tzInt(offset_minutes);
    const sign: u8 = if (tz < 0) '-' else '+';
    try w.print("{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>4}", .{
        weekday_names[c.weekday], c.day,    month_names[c.month - 1], c.year,
        c.hour,                   c.minute, c.second,                 sign,
        @abs(tz),
    });
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
pub fn appendRfc822Quoted(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    try out.append(gpa, '"');
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

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn isRfc2047Special(c: u8, kind: Rfc2047Kind) bool {
    if (nonAscii(c) or !isPrint(c)) return true;
    if (isSpace(c) or c == '=' or c == '?' or c == '_') return true;
    if (kind != .address) return false;
    return !(std.ascii.isAlphanumeric(c) or c == '!' or c == '*' or c == '+' or c == '-' or c == '/');
}

fn lastLineLength(buf: []const u8) usize {
    const nl = std.mem.lastIndexOfScalar(u8, buf, '\n') orelse return buf.len;
    return buf.len - (nl + 1);
}

/// Append `line` as RFC 2047 `Q`-encoded words in UTF-8, breaking before
/// 76 columns as git's `add_rfc2047` does, never inside a character.
pub fn appendRfc2047(gpa: Allocator, out: *std.ArrayList(u8), line: []const u8, kind: Rfc2047Kind) Allocator.Error!void {
    const max_encoded_length = 76;
    const encoding = "UTF-8";
    var line_len = lastLineLength(out.items);
    try out.print(gpa, "=?{s}?q?", .{encoding});
    line_len += encoding.len + 5;
    var at: usize = 0;
    while (at < line.len) {
        const chrlen: usize = if (unicodewidth.decode(line[at..])) |decoded| decoded.len else 1;
        const p = line[at .. at + chrlen];
        const special = chrlen > 1 or isRfc2047Special(p[0], kind);
        const encoded_len: usize = if (special) 3 * chrlen else 1;
        if (line_len + encoded_len + 2 > max_encoded_length) {
            try out.print(gpa, "?=\n =?{s}?q?", .{encoding});
            line_len = encoding.len + 5 + 1;
        }
        for (p) |b| {
            if (special) try out.print(gpa, "={X:0>2}", .{b}) else try out.append(gpa, b);
        }
        line_len += encoded_len;
        at += chrlen;
    }
    try out.appendSlice(gpa, "?=");
}

/// git's `strbuf_add_wrapped_text`: `text` wrapped at `width` columns, the
/// first line indented by `indent1` (negative: that many columns are
/// already used) and the rest by `indent2`. A zero `width` indents only.
pub fn appendWrapped(gpa: Allocator, out: *std.ArrayList(u8), text_in: []const u8, indent1: i32, indent2: i32, width: i32) Allocator.Error!void {
    // the text as git sees it: up to its first NUL
    const text = if (std.mem.indexOfScalar(u8, text_in, 0)) |z| text_in[0..z] else text_in;
    if (width <= 0) {
        try appendIndented(gpa, out, text, indent1, indent2);
        return;
    }
    const orig_len = out.items.len;
    var assume_utf8 = true;
    retry: while (true) {
        var pos: usize = 0;
        var bol: usize = 0;
        var indent = indent1;
        var w: i32 = indent1;
        var space: ?usize = null;
        if (indent < 0) {
            w = -indent;
            space = 0;
        }
        while (true) {
            while (escapeLen(text[pos..])) |skip| pos += skip;
            const c: u8 = if (pos < text.len) text[pos] else 0;
            if (c == 0 or isSpace(c)) {
                if (w <= width or space == null) {
                    var start = bol;
                    if (c == 0 and pos == start) return;
                    if (space) |s| {
                        start = s;
                    } else try out.appendNTimes(gpa, ' ', @intCast(@max(indent, 0)));
                    try out.appendSlice(gpa, text[start..pos]);
                    if (c == 0) return;
                    space = pos;
                    if (c == '\t') {
                        w |= 0x07;
                    } else if (c == '\n') {
                        const next = pos + 1;
                        space = next;
                        const nc: u8 = if (next < text.len) text[next] else 0;
                        if (nc == '\n') {
                            try out.append(gpa, '\n');
                            // new_line
                            try out.append(gpa, '\n');
                            pos = next + @intFromBool(isSpace(nc));
                            bol = pos;
                            space = null;
                            indent = indent2;
                            w = indent2;
                            continue;
                        } else if (!std.ascii.isAlphanumeric(nc)) {
                            try out.append(gpa, '\n');
                            pos = next + @intFromBool(next < text.len and isSpace(text[next]));
                            bol = pos;
                            space = null;
                            indent = indent2;
                            w = indent2;
                            continue;
                        } else {
                            try out.append(gpa, ' ');
                        }
                    }
                    w += 1;
                    pos += 1;
                } else {
                    // new_line
                    try out.append(gpa, '\n');
                    const s = space.?;
                    pos = s + @intFromBool(s < text.len and isSpace(text[s]));
                    bol = pos;
                    space = null;
                    indent = indent2;
                    w = indent2;
                }
                continue;
            }
            if (assume_utf8) {
                const decoded = unicodewidth.decode(text[pos..]) orelse {
                    assume_utf8 = false;
                    out.shrinkRetainingCapacity(orig_len);
                    continue :retry;
                };
                w += unicodewidth.width(decoded.char);
                pos += decoded.len;
            } else {
                w += 1;
                pos += 1;
            }
        }
    }
}

fn escapeLen(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != 0x1b or s[1] != '[') return null;
    var i: usize = 2;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == ';')) i += 1;
    if (i >= s.len or s[i] != 'm') return null;
    return i + 1;
}

fn appendIndented(gpa: Allocator, out: *std.ArrayList(u8), text_in: []const u8, indent_in: i32, indent2: i32) Allocator.Error!void {
    var indent: i32 = if (indent_in < 0) 0 else indent_in;
    var text = text_in;
    while (text.len > 0) {
        const eol = std.mem.indexOfScalar(u8, text, '\n');
        const len = if (eol) |e| e + 1 else text.len;
        try out.appendNTimes(gpa, ' ', @intCast(indent));
        try out.appendSlice(gpa, text[0..len]);
        text = text[len..];
        indent = indent2;
    }
}

test "an RFC 2822 date is the author's local time with git's zone text" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRfc2822(&w, 1700000000, 60);
    try std.testing.expectEqualStrings("Tue, 14 Nov 2023 23:13:20 +0100", w.buffered());
    w = .fixed(&buf);
    try writeRfc2822(&w, 0, -330);
    try std.testing.expectEqualStrings("Wed, 31 Dec 1969 18:30:00 -0530", w.buffered());
}

test "encoded words, quoting and wrapping come out as git's" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "From: ");
    try appendRfc2047(gpa, &out, "J\xc3\xb6hn D\xc5\x93", .address);
    try std.testing.expectEqualStrings("From: =?UTF-8?q?J=C3=B6hn=20D=C5=93?=", out.items);
    out.clearRetainingCapacity();
    try appendWrapped(gpa, &out, "a b c", -9, 1, 78);
    try std.testing.expectEqualStrings("a b c", out.items);
}
