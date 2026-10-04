//! git's strict date parser, `parse_date_basic` in `date.c`: what `git am`
//! makes of a mail's `Date:` header and what `GIT_AUTHOR_DATE` may say.
//!
//! RFC 2822 and its many mail-client variants, ISO 8601, `@<secs> <zone>`,
//! zone names, `dd.mm.yy` and `mm/dd/yy`: each read as git reads it, word
//! for word. Two things git takes from the machine are the caller's here:
//! the time now, which a date may not be more than ten days past when its
//! order is ambiguous, and the zone a date without one is taken in, which
//! git asks the C library's local time for.

const std = @import("std");

/// What a date came to.
pub const Parsed = struct {
    /// Seconds since the epoch.
    secs: i64,
    /// Minutes east of UTC.
    offset_minutes: i32,
};

/// Where a date without a zone is.
pub const Context = struct {
    /// The time now, in seconds since the epoch.
    now: i64,
    /// Minutes east of UTC that a date naming no zone is taken in.
    local_offset_minutes: i32 = 0,
};

const Tm = struct {
    year: i64 = -1,
    mon: i64 = -1,
    mday: i64 = -1,
    hour: i64 = -1,
    min: i64 = -1,
    sec: i64 = -1,
    wday: i64 = 0,
};

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_names = [_][]const u8{ "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays" };

const Zone = struct { name: []const u8, offset: i32, dst: i32 };
const timezone_names = [_]Zone{
    .{ .name = "IDLW", .offset = -12, .dst = 0 }, .{ .name = "NT", .offset = -11, .dst = 0 },
    .{ .name = "CAT", .offset = -10, .dst = 0 },  .{ .name = "HST", .offset = -10, .dst = 0 },
    .{ .name = "HDT", .offset = -10, .dst = 1 },  .{ .name = "YST", .offset = -9, .dst = 0 },
    .{ .name = "YDT", .offset = -9, .dst = 1 },   .{ .name = "PST", .offset = -8, .dst = 0 },
    .{ .name = "PDT", .offset = -8, .dst = 1 },   .{ .name = "MST", .offset = -7, .dst = 0 },
    .{ .name = "MDT", .offset = -7, .dst = 1 },   .{ .name = "CST", .offset = -6, .dst = 0 },
    .{ .name = "CDT", .offset = -6, .dst = 1 },   .{ .name = "EST", .offset = -5, .dst = 0 },
    .{ .name = "EDT", .offset = -5, .dst = 1 },   .{ .name = "AST", .offset = -3, .dst = 0 },
    .{ .name = "ADT", .offset = -3, .dst = 1 },   .{ .name = "WAT", .offset = -1, .dst = 0 },
    .{ .name = "GMT", .offset = 0, .dst = 0 },    .{ .name = "UTC", .offset = 0, .dst = 0 },
    .{ .name = "Z", .offset = 0, .dst = 0 },      .{ .name = "WET", .offset = 0, .dst = 0 },
    .{ .name = "BST", .offset = 0, .dst = 1 },    .{ .name = "CET", .offset = 1, .dst = 0 },
    .{ .name = "MET", .offset = 1, .dst = 0 },    .{ .name = "MEWT", .offset = 1, .dst = 0 },
    .{ .name = "MEST", .offset = 1, .dst = 1 },   .{ .name = "CEST", .offset = 1, .dst = 1 },
    .{ .name = "MESZ", .offset = 1, .dst = 1 },   .{ .name = "FWT", .offset = 1, .dst = 0 },
    .{ .name = "FST", .offset = 1, .dst = 1 },    .{ .name = "EET", .offset = 2, .dst = 0 },
    .{ .name = "EEST", .offset = 2, .dst = 1 },   .{ .name = "WAST", .offset = 7, .dst = 0 },
    .{ .name = "WADT", .offset = 7, .dst = 1 },   .{ .name = "CCT", .offset = 8, .dst = 0 },
    .{ .name = "JST", .offset = 9, .dst = 0 },    .{ .name = "EAST", .offset = 10, .dst = 0 },
    .{ .name = "EADT", .offset = 10, .dst = 1 },  .{ .name = "GST", .offset = 10, .dst = 0 },
    .{ .name = "NZT", .offset = 12, .dst = 0 },   .{ .name = "NZST", .offset = 12, .dst = 0 },
    .{ .name = "NZDT", .offset = 12, .dst = 1 },  .{ .name = "IDLE", .offset = 12, .dst = 0 },
};

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn matchString(date: []const u8, str: []const u8) usize {
    var i: usize = 0;
    while (i < date.len and date[i] != 0) : (i += 1) {
        const d = date[i];
        const s = at(str, i);
        if (d == s) continue;
        if (std.ascii.toUpper(d) == std.ascii.toUpper(s)) continue;
        if (!std.ascii.isAlphanumeric(d)) break;
        return 0;
    }
    return i;
}

fn skipAlpha(date: []const u8) usize {
    var i: usize = 0;
    while (true) {
        i += 1;
        if (!std.ascii.isAlphabetic(at(date, i))) break;
    }
    return i;
}

fn matchAlpha(date: []const u8, tm: *Tm, offset: *i32) usize {
    for (month_names, 0..) |name, i| {
        const m = matchString(date, name);
        if (m >= 3) {
            tm.mon = @intCast(i);
            return m;
        }
    }
    for (weekday_names, 0..) |name, i| {
        const m = matchString(date, name);
        if (m >= 3) {
            tm.wday = @intCast(i);
            return m;
        }
    }
    for (timezone_names) |z| {
        const m = matchString(date, z.name);
        if (m >= 3 or m == z.name.len) {
            const off = z.offset + z.dst;
            if (offset.* == -1) offset.* = 60 * off;
            return m;
        }
    }
    if (matchString(date, "PM") == 2) {
        tm.hour = @mod(tm.hour, 12) + 12;
        return 2;
    }
    if (matchString(date, "AM") == 2) {
        tm.hour = @mod(tm.hour, 12);
        return 2;
    }
    if (at(date, 0) == 'T' and isDigit(at(date, 1)) and tm.hour == -1) {
        tm.min = 0;
        tm.sec = 0;
        return 1;
    }
    return skipAlpha(date);
}

fn tmToTime(tm: *const Tm) i64 {
    const mdays = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const year = tm.year - 70;
    const month = tm.mon;
    var day = tm.mday;
    if (year < 0 or year > 129) return -1;
    if (month < 0 or month > 11) return -1;
    if (month < 2 or @mod(year + 2, 4) != 0) day -= 1;
    if (tm.hour < 0 or tm.min < 0 or tm.sec < 0) return -1;
    return (year * 365 + @divTrunc(year + 1, 4) + mdays[@intCast(month)] + day) * 24 * 60 * 60 +
        tm.hour * 60 * 60 + tm.min * 60 + tm.sec;
}

fn setDate(year: i64, month: i64, day: i64, now_tm: ?*const Tm, now: i64, tm: *Tm) bool {
    if (!(month > 0 and month < 13 and day > 0 and day < 32)) return false;
    var check = tm.*;
    const r = if (now_tm != null) &check else tm;
    r.mon = month - 1;
    r.mday = day;
    if (year == -1) {
        if (now_tm == null) return true;
        r.year = now_tm.?.year;
    } else if (year >= 1970 and year < 2100) {
        r.year = year - 1900;
    } else if (year > 70 and year < 100) {
        r.year = year;
    } else if (year < 38) {
        r.year = year + 100;
    } else return false;
    if (now_tm == null) return true;
    const specified = tmToTime(r);
    if (specified != -1 and now + 10 * 24 * 3600 < specified) return false;
    tm.mon = r.mon;
    tm.mday = r.mday;
    if (year != -1) tm.year = r.year;
    return true;
}

fn setTime(hour: i64, minute: i64, second: i64, tm: *Tm) bool {
    if (0 <= hour and hour <= 24 and 0 <= minute and minute < 60 and 0 <= second and second <= 60) {
        tm.hour = hour;
        tm.min = minute;
        tm.sec = second;
        return true;
    }
    return false;
}

fn isDateKnown(tm: *const Tm) bool {
    return tm.year != -1 and tm.mon != -1 and tm.mday != -1;
}

/// strtol: optional whitespace and sign, then digits. Returns the value and
/// where it stopped.
fn strtol(s: []const u8, start: usize) struct { value: i64, end: usize } {
    var i = start;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const digits = i;
    var v: i64 = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) v = v *| 10 +| (s[i] - '0');
    if (i == digits) return .{ .value = 0, .end = start };
    return .{ .value = if (neg) -v else v, .end = i };
}

fn gmtime(secs: i64, tm: *Tm) void {
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    tm.year = (if (m <= 2) y + 1 else y) - 1900;
    tm.mon = m - 1;
    tm.mday = d;
    tm.hour = @divFloor(rem, 3600);
    tm.min = @divFloor(@mod(rem, 3600), 60);
    tm.sec = @mod(rem, 60);
    tm.wday = @mod(days + 4, 7);
}

fn matchMultiNumber(num: i64, c: u8, date: []const u8, end_in: usize, tm: *Tm, ctx: Context) usize {
    var end = end_in;
    const n2 = strtol(date, end + 1);
    const num2 = n2.value;
    end = n2.end;
    var num3: i64 = -1;
    if (at(date, end) == c and isDigit(at(date, end + 1))) {
        const n3 = strtol(date, end + 1);
        num3 = n3.value;
        end = n3.end;
    }
    switch (c) {
        ':' => {
            if (num3 < 0) num3 = 0;
            if (setTime(num, num2, num3, tm)) {
                if (at(date, end) == '.' and isDigit(at(date, end + 1)) and isDateKnown(tm)) end = strtol(date, end + 1).end;
            } else return 0;
        },
        '-', '/', '.' => {
            var now_tm: Tm = .{};
            gmtime(ctx.now, &now_tm);
            if (num > 70) {
                if (setDate(num, num2, num3, null, ctx.now, tm)) return end;
                if (setDate(num, num3, num2, null, ctx.now, tm)) return end;
            }
            if (c != '.' and setDate(num3, num, num2, &now_tm, ctx.now, tm)) return end;
            if (setDate(num3, num2, num, &now_tm, ctx.now, tm)) return end;
            if (c == '.' and setDate(num3, num, num2, &now_tm, ctx.now, tm)) return end;
            return 0;
        },
        else => {},
    }
    return end;
}

fn nodate(tm: *const Tm) bool {
    return (tm.year & tm.mon & tm.mday & tm.hour & tm.min & tm.sec) < 0;
}

fn maybeIso8601(tm: *const Tm) bool {
    return tm.hour == -1 and tm.min == 0 and tm.sec == 0;
}

fn matchDigit(date: []const u8, tm: *Tm, offset: *i32, tm_gmt: *bool, ctx: Context) usize {
    var end: usize = 0;
    var num: i64 = 0;
    while (end < date.len and isDigit(date[end])) : (end += 1) num = num *| 10 +| (date[end] - '0');
    if (num >= 100000000 and nodate(tm)) {
        gmtime(num, tm);
        tm_gmt.* = true;
        return end;
    }
    switch (at(date, end)) {
        ':', '.', '/', '-' => if (isDigit(at(date, end + 1))) {
            const m = matchMultiNumber(num, date[end], date, end, tm, ctx);
            if (m != 0) return m;
        },
        else => {},
    }
    var n: usize = 0;
    while (true) {
        n += 1;
        if (!isDigit(at(date, n))) break;
    }
    if (n == 8 or n == 6) {
        const num1 = @divTrunc(num, 10000);
        const num2 = @divTrunc(@mod(num, 10000), 100);
        const num3 = @mod(num, 100);
        if (n == 8) {
            _ = setDate(num1, num2, num3, null, ctx.now, tm);
        } else if (n == 6 and setTime(num1, num2, num3, tm) and at(date, end) == '.' and isDigit(at(date, end + 1))) {
            end = strtol(date, end + 1).end;
        }
        return end;
    }
    if (maybeIso8601(tm)) {
        var num1 = num;
        var num2: i64 = 0;
        if (n == 4) {
            num1 = @divTrunc(num, 100);
            num2 = @mod(num, 100);
        }
        if ((n == 4 or n == 2) and !nodate(tm) and setTime(num1, num2, 0, tm)) return n;
        tm.min = -1;
        tm.sec = -1;
    }
    if (n == 4) {
        if (num <= 1400 and offset.* == -1) {
            const minutes = @mod(num, 100);
            const hours = @divTrunc(num, 100);
            offset.* = @intCast(hours * 60 + minutes);
        } else if (num > 1900 and num < 2100) tm.year = num - 1900;
        return n;
    }
    if (n > 2) return n;
    if (num > 0 and num < 32 and tm.mday < 0) {
        tm.mday = num;
        return n;
    }
    if (n == 2 and tm.year < 0) {
        if (num < 10 and tm.mday >= 0) {
            tm.year = num + 100;
            return n;
        }
        if (num >= 70) {
            tm.year = num;
            return n;
        }
    }
    if (num > 0 and num < 13 and tm.mon < 0) tm.mon = num - 1;
    return n;
}

fn matchTz(date: []const u8, offp: *i32) usize {
    var end: usize = 1;
    var hour: i64 = 0;
    while (end < date.len and isDigit(date[end])) : (end += 1) hour = hour *| 10 +| (date[end] - '0');
    const n = end - 1;
    var min: i64 = 0;
    if (n == 4) {
        min = @mod(hour, 100);
        hour = @divTrunc(hour, 100);
    } else if (n != 2) {
        min = 99;
    } else if (at(date, end) == ':') {
        const start = end + 1;
        var e = start;
        min = 0;
        while (e < date.len and isDigit(date[e])) : (e += 1) min = min *| 10 +| (date[e] - '0');
        end = e;
        if (end - 1 != 5) min = 99;
    }
    if (min < 60 and hour < 24) {
        var offset: i32 = @intCast(hour * 60 + min);
        if (date[0] == '-') offset = -offset;
        offp.* = offset;
    }
    return end;
}

fn matchObjectHeaderDate(date: []const u8) ?Parsed {
    if (date.len == 0 or !isDigit(date[0])) return null;
    var i: usize = 0;
    var stamp: i64 = 0;
    while (i < date.len and isDigit(date[i])) : (i += 1) stamp = stamp *| 10 +| (date[i] - '0');
    if (at(date, i) != ' ' or (at(date, i + 1) != '+' and at(date, i + 1) != '-')) return null;
    const sign = date[i + 1];
    const zstart = i + 2;
    var j = zstart;
    var ofs: i64 = 0;
    while (j < date.len and isDigit(date[j])) : (j += 1) ofs = ofs *| 10 +| (date[j] - '0');
    if ((j < date.len and date[j] != '\n') or j != zstart + 4) return null;
    var minutes: i32 = @intCast(@divTrunc(ofs, 100) * 60 + @mod(ofs, 100));
    if (sign == '-') minutes = -minutes;
    return .{ .secs = stamp, .offset_minutes = minutes };
}

const timestamp_max: i64 = ((2100 - 1970) * 365 + 32) * 24 * 60 * 60 - 1;

/// Read `text` as git's `parse_date` does; `null` where git says "invalid
/// date format".
pub fn parse(text_in: []const u8, ctx: Context) ?Parsed {
    const text = if (std.mem.indexOfScalar(u8, text_in, 0)) |z| text_in[0..z] else text_in;
    if (text.len > 0 and text[0] == '@') {
        if (matchObjectHeaderDate(text[1..])) |p| return p;
    }
    var tm: Tm = .{};
    var offset: i32 = -1;
    var tm_gmt = false;
    var pos: usize = 0;
    while (pos < text.len) {
        const c = text[pos];
        if (c == '\n') break;
        const rest = text[pos..];
        var m: usize = 0;
        if (std.ascii.isAlphabetic(c)) {
            m = matchAlpha(rest, &tm, &offset);
        } else if (isDigit(c)) {
            m = matchDigit(rest, &tm, &offset, &tm_gmt, ctx);
        } else if ((c == '-' or c == '+') and isDigit(at(rest, 1))) {
            m = matchTz(rest, &offset);
        }
        if (m == 0) m = 1;
        pos += m;
    }
    var secs = tmToTime(&tm);
    if (secs == -1) return null;
    if (offset == -1) offset = ctx.local_offset_minutes;
    if (!tm_gmt) {
        if (offset > 0 and @as(i64, offset) * 60 > secs) return null;
        if (offset < 0 and -@as(i64, offset) * 60 > timestamp_max - secs) return null;
        secs -= @as(i64, offset) * 60;
    }
    return .{ .secs = secs, .offset_minutes = offset };
}

test "mail dates read as git reads them" {
    const ctx: Context = .{ .now = 1_800_000_000 };
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = 60 }, parse("Tue, 14 Nov 2023 23:13:20 +0100", ctx).?);
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = 0 }, parse("14 Nov 2023 22:13:20 GMT", ctx).?);
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = -300 }, parse("2023-11-14 17:13:20 -0500", ctx).?);
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = 120 }, parse("@1700000000 +0200", ctx).?);
    try std.testing.expect(parse("not a date", ctx) == null);
}

test "fuzz: any text is a date or no date, never a crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            if (parse(buf[0..len], .{ .now = 1_700_000_000 })) |p| {
                try std.testing.expect(p.offset_minutes > -24 * 60 * 100 and p.offset_minutes < 24 * 60 * 100);
            }
        }
    }.one, .{});
}
