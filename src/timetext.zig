//! Times as the LFS API writes them, read into seconds since the epoch:
//! RFC 3339, which `expires_at` and a lock's `locked_at` are in, and the
//! HTTP date a `Retry-After` may be. Reading one never reads the clock;
//! what it is compared with is the caller's.

const std = @import("std");

/// `2006-01-02T15:04:05Z07:00`, with or without fractional seconds, which
/// are dropped: Go's `time.RFC3339` layout, which git-lfs parses with. The
/// time is taken back to UTC by its offset. `null` for anything else.
pub fn parseRfc3339(text: []const u8) ?i64 {
    if (text.len < 20) return null;
    if (text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != 't') or text[13] != ':' or text[16] != ':') return null;
    const year = digits(text[0..4]) orelse return null;
    const month = digits(text[5..7]) orelse return null;
    const day = digits(text[8..10]) orelse return null;
    const hour = digits(text[11..13]) orelse return null;
    const minute = digits(text[14..16]) orelse return null;
    const second = digits(text[17..19]) orelse return null;
    var at: usize = 19;
    if (text[at] == '.') {
        at += 1;
        const start = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at == start) return null;
    }
    if (at >= text.len) return null;
    var offset: i64 = 0;
    switch (text[at]) {
        'Z', 'z' => {
            if (at + 1 != text.len) return null;
        },
        '+', '-' => {
            const rest = text[at + 1 ..];
            if (rest.len != 5 or rest[2] != ':') return null;
            const oh = digits(rest[0..2]) orelse return null;
            const om = digits(rest[3..5]) orelse return null;
            if (oh > 23 or om > 59) return null;
            offset = @as(i64, oh) * 3600 + @as(i64, om) * 60;
            if (text[at] == '-') offset = -offset;
        },
        else => return null,
    }
    const t = civil(year, month, day, hour, minute, second) orelse return null;
    return t - offset;
}

/// `Mon, 02 Jan 2006 15:04:05 GMT`: the HTTP date, as Go's `time.RFC1123`
/// layout reads it, which is how git-lfs reads a `Retry-After` that is not
/// a number. The zone is a name; an HTTP date's is always GMT, and any
/// name is taken as UTC.
pub fn parseHttpDate(text: []const u8) ?i64 {
    // "Mon, 02 Jan 2006 15:04:05 GMT"
    if (text.len < 29) return null;
    const weekdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    var known = false;
    for (weekdays) |w| {
        if (std.mem.eql(u8, text[0..3], w)) known = true;
    }
    if (!known or text[3] != ',' or text[4] != ' ' or text[7] != ' ' or text[11] != ' ' or text[16] != ' ') return null;
    if (text[19] != ':' or text[22] != ':' or text[25] != ' ') return null;
    const day = digits(text[5..7]) orelse return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month: u32 = 0;
    for (months, 1..) |m, i| {
        if (std.mem.eql(u8, text[8..11], m)) month = @intCast(i);
    }
    if (month == 0) return null;
    const year = digits(text[12..16]) orelse return null;
    const hour = digits(text[17..19]) orelse return null;
    const minute = digits(text[20..22]) orelse return null;
    const second = digits(text[23..25]) orelse return null;
    const zone = text[26..];
    if (zone.len < 3) return null;
    for (zone) |c| {
        if (!std.ascii.isUpper(c)) return null;
    }
    return civil(year, month, day, hour, minute, second);
}

fn digits(text: []const u8) ?u32 {
    var n: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// Seconds since the epoch of a UTC date and time, or `null` for one that
/// does not exist.
fn civil(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) ?i64 {
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const lengths = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > lengths[month - 1]) return null;
    // Howard Hinnant's days_from_civil.
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

const testing = std.testing;

test "RFC 3339 and HTTP dates are read to the second, as Go reads them" {
    try testing.expectEqual(@as(?i64, 0), parseRfc3339("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 4070908800), parseRfc3339("2099-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1136239445), parseRfc3339("2006-01-02T15:04:05-07:00"));
    try testing.expectEqual(@as(?i64, 1136214245), parseRfc3339("2006-01-02T15:04:05.999999999Z"));
    try testing.expectEqual(@as(?i64, 951782400), parseRfc3339("2000-02-29T00:00:00Z"));
    for ([_][]const u8{ "", "2006-01-02 15:04:05Z", "2006-01-02T15:04:05", "1900-02-29T00:00:00Z", "2006-13-02T15:04:05Z", "2006-01-02T15:04:05+0700", "2006-01-02T15:04:05.Z" }) |bad| {
        try testing.expectEqual(@as(?i64, null), parseRfc3339(bad));
    }
    try testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 UTC"));
    for ([_][]const u8{ "120", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994", "Sun, 06 Nov 1994 08:49:37 gmt", "Xyz, 06 Nov 1994 08:49:37 GMT" }) |bad| {
        try testing.expectEqual(@as(?i64, null), parseHttpDate(bad));
    }
}

test "fuzz: any text is a time or is not, and never a crash" {
    try testing.fuzz({}, fuzzTimes, .{});
}

fn fuzzTimes(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [64]u8 = undefined;
    const len = smith.slice(&scratch);
    _ = parseRfc3339(scratch[0..len]);
    _ = parseHttpDate(scratch[0..len]);
}
