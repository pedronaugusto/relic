//! git's strict date parser, `parse_date_basic` in `date.c`: what `git am`
//! makes of a mail's `Date:` header and what `GIT_AUTHOR_DATE` may say; and
//! its approximate one, `approxidate_careful`, which reads `yesterday`,
//! `3.days.ago`, `last Friday at noon` and whatever the strict one reads,
//! for a reflog's `@{<date>}`.
//!
//! RFC 2822 and its many mail-client variants, ISO 8601, `@<secs> <zone>`,
//! zone names, `dd.mm.yy` and `mm/dd/yy`: each read as git reads it, word
//! for word. Two things git takes from the machine are the caller's here:
//! the time now, which a date may not be more than ten days past when its
//! order is ambiguous, and the zone a date without one is taken in, which
//! git asks the C library's local time for.

const std = @import("std");
const aegis = @import("aegis");
const ctype = @import("ctype.zig");
const shakedown = @import("shakedown");

/// What a date came to.
pub const Parsed = struct {
    /// Seconds since the epoch.
    secs: i64,
    /// Minutes east of UTC.
    offset_minutes: i32,
};

/// The moment `secs` seconds after the epoch, as a time that git's
/// seconds name.
pub fn timestamp(secs: i64) std.Io.Timestamp {
    return Expiry.fromRaw(secs).toTimestamp();
}

/// `t` in the whole seconds since the epoch git names it by, rounded down.
/// A moment past what 64 bits of seconds hold, which no clock reads, is
/// held at that end.
pub fn instant(t: std.Io.Timestamp) Expiry {
    return Expiry.fromTimestamp(t, .down) catch .fromRaw(if (t.nanoseconds < 0) std.math.minInt(i64) else std.math.maxInt(i64));
}

/// `instant(t)` as git's `time_t`.
pub fn seconds(t: std.Io.Timestamp) i64 {
    return instant(t).raw();
}

/// A span of git's seconds, as an `Expiry` moves by.
pub const Span = aegis.units.Duration(.second, i64);

/// `n` days, in seconds.
pub fn spanDays(comptime n: i64) Span {
    return comptime aegis.units.Duration(.day, i64).fromRaw(n).convert(.second, i64, .exact) catch @compileError("more days than 64 bits of seconds hold");
}

/// `n` hours, in seconds.
pub fn spanHours(comptime n: i64) Span {
    return comptime aegis.units.Duration(.hour, i64).fromRaw(n).convert(.second, i64, .exact) catch @compileError("more hours than 64 bits of seconds hold");
}

/// Where a date without a zone is.
pub const Context = struct {
    /// The time now; dates are reckoned from its whole seconds.
    now: std.Io.Timestamp,
    /// Minutes east of UTC that a date naming no zone is taken in.
    local_offset_minutes: i32 = 0,
};

/// A date's calendar fields, as C's `struct tm` holds them: the year less
/// 1900, the month from zero.
pub const Tm = struct {
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
    while (i < s.len and ctype.isSpace(s[i])) i += 1;
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

/// The calendar a moment falls on: C's `struct tm` as `gmtime` fills it,
/// each field in its range.
pub const Calendar = struct {
    /// The year, in full.
    year: i64,
    /// From 0, January, to 11.
    month: u4,
    /// From 1 to 31.
    day: u5,
    /// From 0 to 23.
    hour: u5,
    /// From 0 to 59.
    minute: u6,
    /// From 0 to 59.
    second: u6,
    /// From 0, Sunday, to 6.
    weekday: u3,

    /// The day of the year, from 0.
    fn yearDay(cal: Calendar) u9 {
        const before = [12]u9{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        const leap_day: u9 = @intFromBool(cal.month > 1 and isLeap(cal.year));
        return before[cal.month] + leap_day + cal.day - 1;
    }

    /// A date and time of day as text writes them, in UTC: a year of at
    /// most four digits, the month from 1. `null` for one that does not
    /// exist: a month past 12, a day the month lacks, an hour past 23, a
    /// minute or a second past 59.
    pub fn fromFields(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) ?Calendar {
        if (year > 9999 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return null;
        const lengths = [12]u5{ 31, if (isLeap(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (day > lengths[month - 1]) return null;
        // The weekday is the one `calendarOf` finds for the moment.
        const date: Calendar = .{ .year = year, .month = @intCast(month - 1), .day = @intCast(day), .hour = @intCast(hour), .minute = @intCast(minute), .second = @intCast(second), .weekday = 0 };
        return calendarOf(date.moment() orelse return null);
    }

    /// The seconds after the epoch `cal` is, in UTC, its weekday not read:
    /// `calendarOf`'s inverse. `null` for a year past what a timestamp
    /// holds, which neither it nor `fromFields` makes.
    pub fn moment(cal: Calendar) ?i64 {
        // The year from March, and the day of that year.
        const y = std.math.sub(i64, cal.year, @intFromBool(cal.month < 2)) catch return null;
        const era = @divFloor(y, 400);
        const yoe = @mod(y, 400);
        const mp: i64 = @mod(@as(i64, cal.month) + 10, 12);
        const doy = @divFloor(153 * mp + 2, 5) + @as(i64, cal.day) - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        const eras = std.math.mul(i64, era, 146097) catch return null;
        const days = std.math.add(i64, eras, doe - 719468) catch return null;
        const time = @as(i64, cal.hour) * 3600 + @as(i64, cal.minute) * 60 + @as(i64, cal.second);
        return std.math.add(i64, std.math.mul(i64, days, 86400) catch return null, time) catch null;
    }
};

/// The calendar `secs` seconds after the epoch falls on, in UTC: C's
/// `gmtime`, by days counted in eras of 400 years from 0000-03-01.
fn calendarOf(secs: i64) Calendar {
    const days = @divFloor(secs, 86400);
    const time = @mod(secs, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    // The day of the era, the year of the era and the day of that year, from March.
    const doe = @mod(z, 146097);
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    // A day of a month of the year from March is the first to the 31st.
    aegis.assert.invariant(day >= 1 and day <= 31, "day >= 1 and day <= 31");
    const month = @mod(mp + 2, 12);
    return .{
        .year = yoe + era * 400 + @intFromBool(month < 2),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(@divFloor(time, 3600)),
        .minute = @intCast(@divFloor(@mod(time, 3600), 60)),
        .second = @intCast(@mod(time, 60)),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

/// `cal` as C's `struct tm`: the year less 1900, the month from zero.
fn tmOf(cal: Calendar) Tm {
    return .{ .year = cal.year - 1900, .mon = cal.month, .mday = cal.day, .hour = cal.hour, .min = cal.minute, .sec = cal.second, .wday = cal.weekday };
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
            const now_tm = tmOf(calendarOf(seconds(ctx.now)));
            if (num > 70) {
                if (setDate(num, num2, num3, null, seconds(ctx.now), tm)) return end;
                if (setDate(num, num3, num2, null, seconds(ctx.now), tm)) return end;
            }
            if (c != '.' and setDate(num3, num, num2, &now_tm, seconds(ctx.now), tm)) return end;
            if (setDate(num3, num2, num, &now_tm, seconds(ctx.now), tm)) return end;
            if (c == '.' and setDate(num3, num, num2, &now_tm, seconds(ctx.now), tm)) return end;
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
        tm.* = tmOf(calendarOf(num));
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
            _ = setDate(num1, num2, num3, null, seconds(ctx.now), tm);
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
    // A stamp past what a time holds is git's `TIME_MAX`, which it refuses.
    while (i < date.len and isDigit(date[i])) : (i += 1) {
        stamp = std.math.add(i64, std.math.mul(i64, stamp, 10) catch return null, date[i] - '0') catch return null;
    }
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
    const text = if (std.mem.findScalar(u8, text_in, 0)) |z| text_in[0..z] else text_in;
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

// ---------------------------------------------------------------------------
// approxidate
// ---------------------------------------------------------------------------

/// Read `text` as git's `approxidate_careful` does: a date the strict
/// parser reads is that date, and anything else is read word by word
/// against the time now, in the caller's zone. `null` where git reports an
/// error, which is text in which no word meant anything.
pub fn approximate(text_in: []const u8, ctx: Context) ?i64 {
    if (parse(text_in, ctx)) |p| return p.secs;
    const text = if (std.mem.findScalar(u8, text_in, 0)) |z| text_in[0..z] else text_in;
    var a: Approx = .{ .off = ctx.local_offset_minutes, .now_secs = seconds(ctx.now) };
    a.localtime(seconds(ctx.now), &a.tm);
    a.now = a.tm;
    a.tm.year = -1;
    a.tm.mon = -1;
    a.tm.mday = -1;
    var pos: usize = 0;
    while (pos < text.len) {
        const c = text[pos];
        if (isDigit(c)) {
            a.pendingNumber();
            pos += a.digit(text[pos..], ctx);
            a.touched = true;
            continue;
        }
        if (std.ascii.isAlphabetic(c)) {
            pos += a.alpha(text[pos..]);
            continue;
        }
        pos += 1;
    }
    a.pendingNumber();
    if (!a.touched) return null;
    const secs = a.update(0);
    return if (a.overflowed) null else secs;
}

/// An expiry: an entry dated before it goes, in seconds since the epoch
/// on the real clock. `never` is 0, which nothing is before; `now` and
/// `all` are the greatest time.
pub const Expiry = aegis.units.Instant(.real, .second, i64);

/// The greatest expiry, which every entry is before: `now`, `all`.
pub const expire_all: Expiry = .fromRaw(std.math.maxInt(i64));

/// git's `parse_expiry_date`: `never` and `false` are 0, `all` and `now`
/// the greatest time, and anything else a date as `approxidate_careful`
/// reads it against `clock`; `null` where git reports an error.
pub fn parseExpiry(value: []const u8, clock: Context) ?Expiry {
    if (std.mem.eql(u8, value, "never") or std.mem.eql(u8, value, "false")) return .fromRaw(0);
    if (std.mem.eql(u8, value, "all") or std.mem.eql(u8, value, "now")) return expire_all;
    return .fromRaw(approximate(value, clock) orelse return null);
}

test "the expiry words git reads" {
    const clock: Context = .{ .now = timestamp(1_700_000_000) };
    const day = 24 * 60 * 60;
    try std.testing.expectEqual(@as(?Expiry, .fromRaw(0)), parseExpiry("never", clock));
    try std.testing.expectEqual(@as(?Expiry, .fromRaw(0)), parseExpiry("false", clock));
    try std.testing.expectEqual(@as(?Expiry, expire_all), parseExpiry("now", clock));
    try std.testing.expectEqual(@as(?Expiry, expire_all), parseExpiry("all", clock));
    try std.testing.expectEqual(@as(?Expiry, .fromRaw(1_700_000_000 - 2 * day)), parseExpiry("2.days.ago", clock));
    try std.testing.expectEqual(@as(?Expiry, null), parseExpiry("not a date at all", clock));
}

/// `approxidate_str`'s state: the date being built, the time now, a
/// number waiting for the word that says what it counts, and whether any
/// word meant anything.
const Approx = struct {
    tm: Tm = .{},
    now: Tm = .{},
    now_secs: i64,
    /// Minutes east of UTC: the zone git's `mktime` and `localtime` use.
    off: i32,
    num: i64 = 0,
    touched: bool = false,
    /// The date went past what 64 bits of seconds hold, as a clock near
    /// their end takes it: no date.
    overflowed: bool = false,

    fn localtime(a: *Approx, secs: i64, tm: *Tm) void {
        const shifted = std.math.add(i64, secs, @as(i64, a.off) * 60) catch {
            a.overflowed = true;
            return;
        };
        tm.* = tmOf(calendarOf(shifted));
    }

    /// `mktime`: the fields normalized, in the caller's zone; null past what
    /// 64 bits of seconds hold.
    fn mktime(a: *const Approx, tm: *const Tm) ?i64 {
        const year = std.math.add(i64, tm.year, 1900 + @divFloor(tm.mon, 12)) catch return null;
        const first = monthStart(year, @intCast(@mod(tm.mon, 12))) orelse return null;
        const days = std.math.add(i64, first, tm.mday - 1) catch return null;
        const clock = tm.hour * 3600 + tm.min * 60 + tm.sec - @as(i64, a.off) * 60;
        return std.math.add(i64, std.math.mul(i64, days, 86400) catch return null, clock) catch null;
    }

    /// The date went past what 64 bits of seconds hold: no time to give.
    fn overflow(a: *Approx) i64 {
        a.overflowed = true;
        return 0;
    }

    /// git's `update_tm`: fill what is unset from now, go back `sec`
    /// seconds, and read the fields again. A negative day is a number of
    /// days back still to be taken, deferred until no day was named.
    fn update(a: *Approx, sec_in: i64) i64 {
        var sec = sec_in;
        if (a.tm.mday < 0) {
            const offset = a.tm.mday + 1;
            if (sec == 0 and offset < 0) sec = -offset * 24 * 60 * 60;
            a.tm.mday = a.now.mday;
        }
        if (a.tm.mon < 0) a.tm.mon = a.now.mon;
        if (a.tm.year < 0) {
            a.tm.year = a.now.year;
            if (a.tm.mon > a.now.mon) a.tm.year -= 1;
        }
        const n = std.math.sub(i64, a.mktime(&a.tm) orelse return a.overflow(), sec) catch return a.overflow();
        a.localtime(n, &a.tm);
        return n;
    }

    /// git's `pending_number`: a number no word claimed is a day of the
    /// month, a month or a year, whichever is still open.
    fn pendingNumber(a: *Approx) void {
        const number = a.num;
        if (number == 0) return;
        a.num = 0;
        if (a.tm.mday < 0 and number < 32) {
            a.tm.mday = number;
        } else if (a.tm.mon < 0 and number < 13) {
            a.tm.mon = number - 1;
        } else if (a.tm.year < 0) {
            if (number > 1969 and number < 2100) {
                a.tm.year = number - 1900;
            } else if (number > 69 and number < 100) {
                a.tm.year = number;
            } else if (number < 38) {
                a.tm.year = 100 + number;
            }
        }
    }

    /// git's `date_time`: the most recent `hour` o'clock, which may be
    /// yesterday's.
    fn atHour(a: *Approx, hour: u5) void {
        if (a.tm.mday < 0 and a.tm.hour < hour) a.tm.mday = -2;
        a.tm.hour = hour;
        a.tm.min = 0;
        a.tm.sec = 0;
    }

    fn meridiem(a: *Approx, pm: bool) void {
        var hour = a.tm.hour;
        if (a.num != 0) {
            hour = a.num;
            a.tm.min = 0;
            a.tm.sec = 0;
        }
        a.num = 0;
        a.tm.hour = @mod(hour, 12) + @as(i64, if (pm) 12 else 0);
    }

    /// The words git's `special` table names. Returns whether `word` is
    /// one.
    fn special(a: *Approx, date: []const u8) bool {
        const names = [_][]const u8{ "yesterday", "noon", "midnight", "tea", "PM", "AM", "never", "now", "today" };
        const which = for (names, 0..) |name, i| {
            if (matchString(date, name) == name.len) break i;
        } else return false;
        switch (which) {
            0 => {
                a.num = 0;
                a.tm.mday = -1;
                _ = a.update(24 * 60 * 60);
            },
            1 => {
                a.pendingNumber();
                a.atHour(12);
            },
            2 => {
                a.pendingNumber();
                a.atHour(0);
            },
            3 => {
                a.pendingNumber();
                a.atHour(17);
            },
            4 => a.meridiem(true),
            5 => a.meridiem(false),
            6 => {
                a.localtime(0, &a.tm);
                a.num = 0;
            },
            7 => {
                a.num = 0;
                _ = a.update(0);
            },
            8 => {
                if (a.tm.hour == a.now.hour and a.tm.min == a.now.min and a.tm.sec == a.now.sec) a.atHour(0);
                a.num = 0;
                a.tm.mday = -1;
                _ = a.update(0);
            },
            else => unreachable,
        }
        return true;
    }

    /// git's `approxidate_alpha`: one word. Returns its length.
    fn alpha(a: *Approx, date: []const u8) usize {
        const end = skipAlpha(date);
        for (month_names, 0..) |name, i| {
            if (matchString(date, name) >= 3) {
                a.tm.mon = @intCast(i); // a month's index, below 12
                a.touched = true;
                return end;
            }
        }
        if (a.special(date)) {
            a.touched = true;
            return end;
        }
        if (a.num == 0) {
            const number_names = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" };
            for (number_names, 1..) |name, i| {
                if (matchString(date, name) == name.len) {
                    a.num = @intCast(i); // one to ten
                    a.touched = true;
                    return end;
                }
            }
            if (matchString(date, "last") == 4) {
                a.num = 1;
                a.touched = true;
            }
            return end;
        }
        const units = [_]struct { name: []const u8, secs: i64 }{
            .{ .name = "seconds", .secs = 1 },
            .{ .name = "minutes", .secs = 60 },
            .{ .name = "hours", .secs = 60 * 60 },
            .{ .name = "days", .secs = 24 * 60 * 60 },
            .{ .name = "weeks", .secs = 7 * 24 * 60 * 60 },
        };
        for (units) |unit| {
            if (matchString(date, unit.name) >= unit.name.len - 1) {
                _ = a.update(unit.secs *% a.num);
                a.num = 0;
                a.touched = true;
                return end;
            }
        }
        for (weekday_names, 0..) |name, i| {
            if (matchString(date, name) >= 3) {
                var n = a.num - 1;
                a.num = 0;
                var diff = a.tm.wday - @as(i64, @intCast(i)); // aegis: no-danger: a weekday's index, below 7
                if (diff <= 0) n += 1;
                diff += 7 * n;
                _ = a.update(diff * 24 * 60 * 60);
                a.touched = true;
                return end;
            }
        }
        if (matchString(date, "months") >= 5) {
            _ = a.update(0);
            const n = a.tm.mon - a.num;
            a.num = 0;
            // git adds twelve and takes a year until the month is not
            // negative.
            a.tm.year += @divFloor(n, 12);
            a.tm.mon = @mod(n, 12);
            a.touched = true;
            return end;
        }
        if (matchString(date, "years") >= 4) {
            _ = a.update(0);
            a.tm.year -= a.num;
            a.num = 0;
            a.touched = true;
            return end;
        }
        return end;
    }

    /// git's `approxidate_digit`: a number, or a time or date written
    /// with `:`, `.`, `/` or `-`. Returns its length.
    fn digit(a: *Approx, date: []const u8, ctx: Context) usize {
        var end: usize = 0;
        var number: u64 = 0;
        while (end < date.len and isDigit(date[end])) : (end += 1) number = number *% 10 +% (date[end] - '0');
        switch (at(date, end)) {
            ':', '.', '/', '-' => if (isDigit(at(date, end + 1))) {
                // git's `timestamp_t` is unsigned and read as a long.
                const m = matchMultiNumber(@bitCast(number), date[end], date, end, &a.tm, ctx);
                if (m != 0) return m;
            },
            else => {},
        }
        // Zero-padding only for small numbers: "Dec 02", never "Dec 0002".
        // git keeps the number in an `int`.
        // wrapping into an `int`, as git's assignment does.
        if (date[0] != '0' or end <= 2) a.num = @as(i32, @truncate(@as(i64, @bitCast(number))));
        return end;
    }
};

/// Days from the epoch to the first of `month` (from 0) of `year`, in the
/// proleptic Gregorian calendar; null past what 64 bits hold.
fn monthStart(year_in: i64, month: u4) ?i64 {
    // The year from March, as eras count it.
    const year = if (month < 2) std.math.sub(i64, year_in, 1) catch return null else year_in;
    const era = @divFloor(year, 400);
    const yoe = @mod(year, 400);
    const mp: i64 = if (month > 1) @as(i64, month) - 2 else @as(i64, month) + 10;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + @divFloor(153 * mp + 2, 5);
    const days = std.math.mul(i64, era, 146097) catch return null;
    return std.math.add(i64, days, doe - 719468) catch null;
}

/// The date `secs` is in UTC, as `YYYY-MM-DD hh:mm:ss`.
fn formatUtc(buf: *[40]u8, secs: i64) []const u8 {
    const cal = calendarOf(secs);
    // A year before the first is written as 0, as in `show`.
    const year: u64 = std.math.cast(u64, cal.year) orelse 0;
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,     cal.month + 1, cal.day,
        cal.hour, cal.minute,    cal.second,
    }) catch unreachable; // aegis: no-danger: a u64 year is at most twenty bytes, the rest of the stamp fifteen
}

// ---------------------------------------------------------------------------
// show_date
// ---------------------------------------------------------------------------

/// How a date is shown: git's `date_mode`, as `--date=<mode>` and a
/// format's `:<mode>` name it.
pub const Mode = struct {
    kind: Kind = .normal,
    /// `-local`: in the machine's zone rather than the date's own.
    local: bool = false,
    /// The `strftime` format after `format:`, borrowed from the text the
    /// mode was parsed from.
    strftime: []const u8 = "",

    pub const Kind = enum { normal, relative, human, short, iso8601, iso8601_strict, rfc2822, strftime, raw, unix };

    /// git's `parse_date_format`, except `auto:`, which asks whether the
    /// output is a terminal: here it is never one. `null` where git says
    /// "unknown date format".
    pub fn parse(text_in: []const u8) ?Mode {
        var text = text_in;
        if (std.mem.startsWith(u8, text, "auto:")) text = "default";
        if (std.mem.eql(u8, text, "local")) text = "default-local";
        const kinds = [_]struct { []const u8, Kind }{
            .{ "relative", .relative },
            .{ "iso8601-strict", .iso8601_strict },
            .{ "iso-strict", .iso8601_strict },
            .{ "iso8601", .iso8601 },
            .{ "iso", .iso8601 },
            .{ "rfc2822", .rfc2822 },
            .{ "rfc", .rfc2822 },
            .{ "short", .short },
            .{ "default", .normal },
            .{ "human", .human },
            .{ "raw", .raw },
            .{ "unix", .unix },
            .{ "format", .strftime },
        };
        var mode: Mode = .{};
        var rest: []const u8 = undefined;
        for (kinds) |k| {
            if (std.mem.startsWith(u8, text, k[0])) {
                mode.kind = k[1];
                rest = text[k[0].len..];
                break;
            }
        } else return null;
        if (std.mem.startsWith(u8, rest, "-local")) {
            mode.local = true;
            rest = rest["-local".len..];
        }
        if (mode.kind == .strftime) {
            if (rest.len == 0 or rest[0] != ':') return null;
            mode.strftime = rest[1..];
        } else if (rest.len != 0) return null;
        return mode;
    }
};

/// The machine's zone at one moment: what git asks `localtime_r` for.
pub const LocalTime = struct {
    /// Minutes east of UTC.
    offset_minutes: i32,
    /// The zone's abbreviation, for `%Z`. Borrowed.
    name: []const u8 = "",
};

/// The machine's zone, which the caller knows and this does not.
pub const LocalZone = struct {
    context: *anyopaque,
    at: *const fn (context: *anyopaque, secs: i64) LocalTime,
};

/// What showing a date may need from the machine: the time now for
/// `relative` and `human`, the local zone for `human` and `-local`, and
/// the C locale's year width for `%x` (which varies between C libraries).
pub const Clock = struct {
    now: ?std.Io.Timestamp = null,
    local: ?LocalZone = null,
    /// Whether `%x` uses a four-digit year; `%D` always uses two digits.
    locale_date_full_year: bool = false,
};

/// Errors from showing a date.
pub const ShowError = errors: {
    break :errors error{
        /// A mode that needs the time now or the local zone, and a `Clock`
        /// without it.
        DateNeedsClock,
    } || std.Io.Writer.Error;
};

const short_weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const short_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const long_weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// git's `tz` integer, `+0130` as 130, in minutes east of UTC.
pub fn tzMinutes(tz: i32) i32 {
    // In unsigned arithmetic: the most negative `tz` has no positive i32,
    // and an object may carry any.
    const abs: u32 = @abs(tz);
    // cast: at most 2^31 / 100 * 60 + 99, which an i32 holds
    const minutes: i32 = @intCast(abs / 100 * 60 + abs % 100);
    return if (tz < 0) -minutes else minutes;
}

/// Minutes east of UTC as git's `tz` integer. An offset whose integer is
/// past what an `i32` holds, which no `tzMinutes` gives, is held at its end.
pub fn tzInt(offset_minutes: i32) i32 {
    // In unsigned arithmetic, as `tzMinutes`: the most negative offset has no positive i32.
    const abs: u32 = @abs(offset_minutes);
    const v: i32 = std.math.cast(i32, abs / 60 * 100 + abs % 60) orelse std.math.maxInt(i32);
    return if (offset_minutes < 0) -v else v;
}

fn printTz(w: *std.Io.Writer, tz: i32) std.Io.Writer.Error!void {
    // C's `%+05d`
    const sign: u8 = if (tz < 0) '-' else '+';
    try w.print("{c}{d:0>4}", .{ sign, @abs(tz) });
}

/// git's `show_date_relative`.
pub fn showRelative(w: *std.Io.Writer, secs: i64, now_at: std.Io.Timestamp) std.Io.Writer.Error!void {
    const now = seconds(now_at);
    if (now < secs) return w.writeAll("in the future");
    // Saturating: a date an object carries may be as far back as an i64
    // goes, and the difference past it is still "many years ago".
    var diff: i64 = now -| secs;
    if (diff < 90) return plural(w, diff, "second", " ago");
    diff = @divTrunc(diff +| 30, 60);
    if (diff < 90) return plural(w, diff, "minute", " ago");
    diff = @divTrunc(diff + 30, 60);
    if (diff < 36) return plural(w, diff, "hour", " ago");
    diff = @divTrunc(diff + 12, 24);
    if (diff < 14) return plural(w, diff, "day", " ago");
    if (diff < 70) return plural(w, @divTrunc(diff + 3, 7), "week", " ago");
    if (diff < 365) return plural(w, @divTrunc(diff + 15, 30), "month", " ago");
    if (diff < 1825) {
        const total_months = @divTrunc(diff * 12 * 2 + 365, 365 * 2);
        const years = @divTrunc(total_months, 12);
        const months = @rem(total_months, 12);
        if (months != 0) {
            try plural(w, years, "year", ", ");
            return plural(w, months, "month", " ago");
        }
        return plural(w, years, "year", " ago");
    }
    return plural(w, @divTrunc(diff + 183, 365), "year", " ago");
}

fn plural(w: *std.Io.Writer, n: i64, unit: []const u8, after: []const u8) std.Io.Writer.Error!void {
    try w.print("{d} {s}{s}{s}", .{ n, unit, if (n == 1) "" else "s", after });
}

/// The calendar `secs` falls on in zone `tz` (git's `+0100` as 100), as
/// git's `time_to_tm`, or `null` where its `gmtime_r` has none: a time the
/// zone moves past what a timestamp holds, or a year past what C's `int`
/// holds as `tm_year`. The one calendar relic shows a time on.
pub fn calendarIn(secs: i64, tz: i32) ?Calendar {
    const shifted = std.math.add(i64, secs, @as(i64, tzMinutes(tz)) * 60) catch return null;
    const cal = calendarOf(shifted);
    if (cal.year - 1900 < std.math.minInt(i32) or cal.year - 1900 > std.math.maxInt(i32)) return null;
    return cal;
}

/// `secs`, in the zone `tz` (git's `+0100` as 100), as `mode` shows it:
/// git's `show_date`, appended to `out`.
pub fn show(w: *std.Io.Writer, secs: i64, tz_in: i32, mode: Mode, clock: Clock) ShowError!void {
    var tz = tz_in;
    if (mode.kind == .unix) return w.print("{d}", .{secs});
    // `human` shows a date against the time now, in the local zone.
    var human: ?Human = null;
    if (mode.kind == .human) {
        const now = seconds(clock.now orelse return error.DateNeedsClock);
        const zone = clock.local orelse return error.DateNeedsClock;
        const now_tz = tzInt(zone.at(zone.context, now).offset_minutes);
        human = if (calendarIn(now, now_tz)) |cal| .{ .cal = cal, .tz = now_tz } else .{ .cal = calendarOf(0), .tz = 0 };
    }
    var zone_name: []const u8 = "";
    if (mode.local) {
        const zone = clock.local orelse return error.DateNeedsClock;
        const local = zone.at(zone.context, secs);
        tz = tzInt(local.offset_minutes);
        zone_name = local.name;
    }
    if (mode.kind == .raw) {
        try w.print("{d} ", .{secs});
        return printTz(w, tz);
    }
    if (mode.kind == .relative) return showRelative(w, secs, clock.now orelse return error.DateNeedsClock);
    const cal = calendarShown(secs, &tz);
    switch (mode.kind) {
        .short => try writeFixed(w, cal, tz, .short),
        .iso8601 => try writeFixed(w, cal, tz, .iso8601),
        .iso8601_strict => try writeFixed(w, cal, tz, .iso8601_strict),
        .rfc2822 => try writeFixed(w, cal, tz, .rfc2822),
        .strftime => try strftime(w, mode.strftime, secs, cal, tz, .{ .zone_name = if (mode.local) zone_name else null, .date_full_year = clock.locale_date_full_year }),
        else => try showNormal(w, secs, cal, tz, human, mode.local, clock),
    }
}

/// The forms `show` writes from the calendar in the date's own zone alone,
/// which ask nothing of the machine.
pub const Fixed = enum { short, iso8601, iso8601_strict, rfc2822 };

/// `secs`, in the zone `tz` (git's `+0100` as 100), in `form`: `show` in
/// that mode, with no clock to ask.
pub fn showFixed(w: *std.Io.Writer, secs: i64, tz_in: i32, form: Fixed) std.Io.Writer.Error!void {
    var tz = tz_in;
    const cal = calendarShown(secs, &tz);
    return writeFixed(w, cal, tz, form);
}

/// The calendar `show` writes `secs` on in zone `tz`. A time with no
/// calendar date is shown as the epoch in UTC, as git's `show_date` shows
/// it, and `tz` becomes 0.
fn calendarShown(secs: i64, tz: *i32) Calendar {
    return calendarIn(secs, tz.*) orelse epoch: {
        tz.* = 0;
        break :epoch calendarOf(0);
    };
}

fn writeFixed(w: *std.Io.Writer, cal: Calendar, tz: i32, form: Fixed) std.Io.Writer.Error!void {
    // A year before the first is written as 0.
    const year: u64 = std.math.cast(u64, cal.year) orelse 0;
    switch (form) {
        .short => try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ year, @as(u8, cal.month) + 1, cal.day }),
        .iso8601 => {
            try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{ year, @as(u8, cal.month) + 1, cal.day, cal.hour, cal.minute, cal.second });
            try printTz(w, tz);
        },
        .iso8601_strict => {
            try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ year, @as(u8, cal.month) + 1, cal.day, cal.hour, cal.minute, cal.second });
            if (tz == 0) {
                try w.writeByte('Z');
            } else {
                const abs: u32 = @abs(tz);
                try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (tz >= 0) '+' else '-'), abs / 100, abs % 100 });
            }
        },
        .rfc2822 => {
            try w.print("{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} ", .{ short_weekdays[cal.weekday], cal.day, short_months[cal.month], cal.year, cal.hour, cal.minute, cal.second });
            try printTz(w, tz);
        },
    }
}

/// The time now and the local zone, which `human` shows a date against.
const Human = struct { cal: Calendar, tz: i32 };

/// git's `show_date_normal`, which `human` shares.
fn showNormal(w: *std.Io.Writer, secs: i64, cal: Calendar, tz: i32, human: ?Human, local: bool, clock: Clock) ShowError!void {
    var hide_year = false;
    var hide_date = false;
    var hide_wday = false;
    var hide_time = false;
    var hide_seconds = false;
    var hide_tz = local;
    if (human) |now| {
        hide_tz = hide_tz or tz == now.tz;
        hide_year = cal.year == now.cal.year;
        if (hide_year and cal.month == now.cal.month) {
            if (cal.day > now.cal.day) {
                // a future date: think time zones
            } else if (cal.day == now.cal.day) {
                hide_date = true;
                hide_wday = true;
            } else if (@as(u6, cal.day) + 5 > now.cal.day) {
                hide_date = true;
            }
        }
        if (hide_wday) return showRelative(w, secs, clock.now orelse return error.DateNeedsClock);
        // git's `human` hides more once the year is known to be this one.
        if (now.cal.year != 1900) {
            hide_seconds = true;
            hide_tz = hide_tz or !hide_date;
            hide_wday = !hide_year;
            hide_time = !hide_year;
        }
    } else {
        // git compares with a zeroed `struct tm`, the year 1900, a date in which it shows
        // without its year, and a zone of -1.
        hide_tz = hide_tz or tz == -1;
        hide_year = cal.year == 1900;
    }
    // git writes each part with a space after it and trims the last
    // when the time is hidden: the parts, spaces between them.
    if (!hide_wday) try w.writeAll(short_weekdays[cal.weekday]);
    if (!hide_date) {
        if (!hide_wday) try w.writeByte(' ');
        try w.print("{s} {d}", .{ short_months[cal.month], cal.day });
    }
    if (!hide_time) {
        if (!hide_wday or !hide_date) try w.writeByte(' ');
        try w.print("{d:0>2}:{d:0>2}", .{ cal.hour, cal.minute });
        if (!hide_seconds) try w.print(":{d:0>2}", .{cal.second});
    }
    if (!hide_year) try w.print(" {d}", .{cal.year});
    if (!hide_tz) {
        try w.writeByte(' ');
        try printTz(w, tz);
    }
}

fn isLeap(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

/// The ISO 8601 week-based year and week of `cal`.
fn isoWeek(cal: Calendar) struct { year: i64, week: i64 } {
    const yday: i64 = cal.yearDay();
    const wday_mon = @mod(@as(i64, cal.weekday) + 6, 7); // Monday is 0
    const week = @divFloor(yday - wday_mon + 10, 7);
    if (week < 1) {
        const prev_days: i64 = if (isLeap(cal.year - 1)) 366 else 365;
        return .{ .year = cal.year - 1, .week = @divFloor(yday + prev_days - wday_mon + 10, 7) };
    }
    const days: i64 = if (isLeap(cal.year)) 366 else 365;
    if (week == 53 and yday - wday_mon + 3 >= days) return .{ .year = cal.year + 1, .week = 1 };
    return .{ .year = cal.year, .week = week };
}

/// `value` as C's `%0*d` writes it, `fmt` naming the width: a sign only where it is
/// negative, where Zig's formatting signs any signed value it pads.
fn writePadded(w: *std.Io.Writer, comptime fmt: []const u8, value: i64) std.Io.Writer.Error!void {
    if (std.math.cast(u64, value)) |unsigned| return w.print(fmt, .{unsigned});
    return w.print(fmt, .{value});
}

/// C-library details the caller supplies to `strftime`.
const StrftimeContext = struct {
    /// `%Z`'s text for a local date; `null` writes nothing for it, as git
    /// does for a date in its own zone.
    zone_name: ?[]const u8 = null,
    /// Whether the C locale's `%x` uses four year digits rather than two.
    date_full_year: bool = false,
};

/// git's `strbuf_addftime` over the C library's `strftime` in the C
/// locale: `%z`, `%Z` and `%s` as git rewrites them, every other
/// conversion the C library's, with machine details supplied in `context`.
fn strftime(w: *std.Io.Writer, fmt: []const u8, secs: i64, cal: Calendar, tz: i32, context: StrftimeContext) std.Io.Writer.Error!void {
    var rest = fmt;
    while (rest.len != 0) {
        if (rest[0] != '%' or rest.len < 2) {
            try w.writeByte(rest[0]);
            rest = rest[1..];
            continue;
        }
        // The conversion, after the E and O modifiers, which change nothing
        // in the C locale.
        const spec = if ((rest[1] == 'E' or rest[1] == 'O') and rest.len > 2) rest[0..3] else rest[0..2];
        rest = rest[spec.len..];
        const year = cal.year;
        // A year before the first is written as 0 in four digits, and as its last two
        // digits, which `@mod` keeps from 0 to 99.
        const full_year: u64 = std.math.cast(u64, year) orelse 0;
        const short_year: u7 = @intCast(@mod(year, 100));
        const hour12: u5 = if (cal.hour % 12 == 0) 12 else cal.hour % 12;
        const yday: i64 = cal.yearDay();
        switch (spec[spec.len - 1]) {
            '%' => try w.writeByte('%'),
            'a' => try w.writeAll(short_weekdays[cal.weekday]),
            'A' => try w.writeAll(long_weekdays[cal.weekday]),
            'b', 'h' => try w.writeAll(short_months[cal.month]),
            'B' => try w.writeAll(month_names[cal.month]),
            'c' => try w.print("{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{ short_weekdays[cal.weekday], short_months[cal.month], cal.day, cal.hour, cal.minute, cal.second, year }),
            'C' => try writePadded(w, "{d:0>2}", @divFloor(year, 100)),
            'd' => try w.print("{d:0>2}", .{cal.day}),
            'D' => try w.print("{d:0>2}/{d:0>2}/{d:0>2}", .{ cal.month + 1, cal.day, short_year }),
            'e' => try w.print("{d: >2}", .{cal.day}),
            'F' => try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ full_year, cal.month + 1, cal.day }),
            'g' => try writePadded(w, "{d:0>2}", @mod(isoWeek(cal).year, 100)),
            'G' => try w.print("{d}", .{isoWeek(cal).year}),
            'H' => try w.print("{d:0>2}", .{cal.hour}),
            'I' => try w.print("{d:0>2}", .{hour12}),
            'j' => try writePadded(w, "{d:0>3}", yday + 1),
            'k' => try w.print("{d: >2}", .{cal.hour}),
            'l' => try w.print("{d: >2}", .{hour12}),
            'm' => try w.print("{d:0>2}", .{cal.month + 1}),
            'M' => try w.print("{d:0>2}", .{cal.minute}),
            'n' => try w.writeByte('\n'),
            'p' => try w.writeAll(if (cal.hour < 12) "AM" else "PM"),
            'r' => try w.print("{d:0>2}:{d:0>2}:{d:0>2} {s}", .{ hour12, cal.minute, cal.second, if (cal.hour < 12) "AM" else "PM" }),
            'R' => try w.print("{d:0>2}:{d:0>2}", .{ cal.hour, cal.minute }),
            's' => try w.print("{d}", .{secs}),
            'S' => try w.print("{d:0>2}", .{cal.second}),
            't' => try w.writeByte('\t'),
            'T', 'X' => try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ cal.hour, cal.minute, cal.second }),
            'u' => try w.print("{d}", .{if (cal.weekday == 0) 7 else cal.weekday}),
            'U' => try writePadded(w, "{d:0>2}", @divFloor(yday + 7 - cal.weekday, 7)),
            'V' => try writePadded(w, "{d:0>2}", isoWeek(cal).week),
            'w' => try w.print("{d}", .{cal.weekday}),
            'W' => try writePadded(w, "{d:0>2}", @divFloor(yday + 7 - @mod(@as(i64, cal.weekday) + 6, 7), 7)),
            'x' => {
                try w.print("{d:0>2}/{d:0>2}/", .{ cal.month + 1, cal.day });
                if (context.date_full_year) try w.print("{d:0>4}", .{full_year}) else try w.print("{d:0>2}", .{short_year});
            },
            'y' => try w.print("{d:0>2}", .{short_year}),
            'Y' => try w.print("{d}", .{year}),
            'z' => try printTz(w, tz),
            'Z' => if (context.zone_name) |name| try w.writeAll(name),
            else => try w.writeAll(spec[spec.len - 2 ..]),
        }
    }
}

test "a date before the first year shows its year signed, its century and two digits too" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // The last second of the year 1 BC, -0001-12-31 23:59:59 UTC.
    const secs: i64 = -62167219201;
    try show(&out.writer, secs, 0, .{ .kind = .strftime, .strftime = "%Y %C %y %F %j %U" }, .{});
    try std.testing.expectEqualStrings("-1 -1 99 0000-12-31 365 52", out.written());
    out.clearRetainingCapacity();
    try show(&out.writer, secs, 0, .{ .kind = .short }, .{});
    try std.testing.expectEqualStrings("0000-12-31", out.written());
}

test "a calendar's moment is the time it was made from, and a day that does not exist has none" {
    // Each side of the epoch, the eras' edges and the years fromFields takes.
    const times = [_]i64{ 0, -1, 86399, 86400, 951782400, 951868799, 1_700_000_000, -62167219200, -62167219201, 253402300799, -62135596800, std.math.maxInt(i64), std.math.minInt(i64) + 86400 * 366 };
    for (times) |t| {
        const cal = calendarOf(t);
        try std.testing.expectEqual(t, cal.moment().?);
        if (cal.year >= 0 and cal.year <= 9999) {
            const read = Calendar.fromFields(@intCast(cal.year), @as(u32, cal.month) + 1, cal.day, cal.hour, cal.minute, cal.second).?;
            try std.testing.expectEqual(cal, read);
        }
    }
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (0..10_000) |_| {
        const t = prng.random().intRangeAtMost(i64, -62167219200, 253402300799);
        const cal = calendarOf(t);
        try std.testing.expectEqual(t, cal.moment().?);
        try std.testing.expectEqual(cal, Calendar.fromFields(@intCast(cal.year), @as(u32, cal.month) + 1, cal.day, cal.hour, cal.minute, cal.second).?);
    }
    try std.testing.expectEqual(null, Calendar.fromFields(2023, 2, 29, 0, 0, 0));
    try std.testing.expect(Calendar.fromFields(2024, 2, 29, 0, 0, 0) != null);
    try std.testing.expectEqual(null, Calendar.fromFields(1900, 2, 29, 0, 0, 0));
    try std.testing.expect(Calendar.fromFields(2000, 2, 29, 0, 0, 0) != null);
    try std.testing.expectEqual(null, Calendar.fromFields(2023, 4, 31, 0, 0, 0));
    try std.testing.expectEqual(null, Calendar.fromFields(2023, 13, 1, 0, 0, 0));
    try std.testing.expectEqual(null, Calendar.fromFields(2023, 1, 1, 24, 0, 0));
    try std.testing.expectEqual(null, Calendar.fromFields(10000, 1, 1, 0, 0, 0));
    // A calendar no timestamp holds has no moment.
    var far = calendarOf(0);
    far.year = std.math.maxInt(i64);
    try std.testing.expectEqual(null, far.moment());
    far.year = std.math.minInt(i64);
    try std.testing.expectEqual(null, far.moment());
}

test "a fixed form is shown as show shows it, and asks no clock" {
    const gpa = std.testing.allocator;
    var fixed: std.Io.Writer.Allocating = .init(gpa);
    defer fixed.deinit();
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    // A date, one before the year 1, and one an hour's zone moves past
    // what a timestamp holds, shown as the epoch in UTC.
    const times = [_]struct { i64, i32 }{ .{ 1_700_000_000, -130 }, .{ -62167219201, 0 }, .{ std.math.maxInt(i64), 100 } };
    for (times) |t| {
        for ([_]Mode.Kind{ .short, .iso8601, .iso8601_strict, .rfc2822 }, [_]Fixed{ .short, .iso8601, .iso8601_strict, .rfc2822 }) |kind, form| {
            fixed.clearRetainingCapacity();
            shown.clearRetainingCapacity();
            try showFixed(&fixed.writer, t[0], t[1], form);
            try show(&shown.writer, t[0], t[1], .{ .kind = kind }, .{});
            try std.testing.expectEqualStrings(shown.written(), fixed.written());
        }
    }
    fixed.clearRetainingCapacity();
    try showFixed(&fixed.writer, 1_700_000_000, -130, .rfc2822);
    try std.testing.expectEqualStrings("Tue, 14 Nov 2023 20:43:20 -0130", fixed.written());
    fixed.clearRetainingCapacity();
    try showFixed(&fixed.writer, std.math.maxInt(i64), 100, .iso8601);
    try std.testing.expectEqualStrings("1970-01-01 00:00:00 +0000", fixed.written());
}

test "an approximate date past what 64 bits of seconds hold is no date" {
    const ctx: Context = .{ .now = timestamp(1_700_000_000) };
    // A clock at the last second 64 bits hold, an hour east of UTC: its local time is past them.
    const end: Context = .{ .now = timestamp(std.math.maxInt(i64)), .local_offset_minutes = 60 };
    try std.testing.expectEqual(@as(?i64, null), approximate("yesterday", end));
    try std.testing.expectEqual(@as(?i64, null), approximate("3 days ago", end));
    // A day before the time now is a date.
    try std.testing.expectEqual(@as(?i64, 1_700_000_000 - 24 * 60 * 60), approximate("yesterday", ctx));
}

test "locale date year width changes percent x without changing percent D" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const secs: i64 = 1700270000;
    const mode: Mode = .{ .kind = .strftime, .strftime = "%x|%D" };
    try show(&out.writer, secs, 0, mode, .{});
    try std.testing.expectEqualStrings("11/18/23|11/18/23", out.written());
    out.clearRetainingCapacity();
    try show(&out.writer, secs, 0, mode, .{ .locale_date_full_year = true });
    try std.testing.expectEqualStrings("11/18/2023|11/18/23", out.written());
}

test "a date with no calendar day is shown as the epoch in UTC, and an extreme zone does not crash" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try show(&out.writer, std.math.maxInt(i64), 100, .{ .kind = .iso8601 }, .{});
    try std.testing.expectEqualStrings("1970-01-01 00:00:00 +0000", out.written());
    for ([_]i32{ std.math.minInt(i32), std.math.maxInt(i32), -1 }) |tz| {
        for ([_]i64{ std.math.minInt(i64), -1, 0, std.math.maxInt(i64) }) |secs| {
            inline for (.{ Mode{ .kind = .iso8601 }, Mode{ .kind = .rfc2822 }, Mode{ .kind = .short }, Mode{ .kind = .raw }, Mode{ .kind = .iso8601_strict }, Mode{ .kind = .relative } }) |mode| {
                out.clearRetainingCapacity();
                try show(&out.writer, secs, tz, mode, .{ .now = timestamp(1_700_000_000) });
            }
        }
    }
}

test "approximate dates read as git's t0006 reads them" {
    // git's own vectors, in UTC, against 2009-08-30 19:20:00.
    const now: i64 = 1251660000;
    const hour = 60 * 60;
    const day = 24 * hour;
    const Case = struct { text: []const u8, want: []const u8, shift: i64 = 0 };
    const cases = [_]Case{
        .{ .text = "now", .want = "2009-08-30 19:20:00" },
        // Git recognizes the number word even among otherwise unknown words.
        .{ .text = "not one word", .want = "2009-08-01 19:20:00" },
        .{ .text = "today", .want = "2009-08-30 00:00:00" },
        .{ .text = "5 seconds ago", .want = "2009-08-30 19:19:55" },
        .{ .text = "5.seconds.ago", .want = "2009-08-30 19:19:55" },
        .{ .text = "10.minutes.ago", .want = "2009-08-30 19:10:00" },
        .{ .text = "yesterday", .want = "2009-08-29 19:20:00" },
        .{ .text = "3.days.ago", .want = "2009-08-27 19:20:00" },
        .{ .text = "12:34:56.3.days.ago", .want = "2009-08-27 12:34:56" },
        .{ .text = "3.weeks.ago", .want = "2009-08-09 19:20:00" },
        .{ .text = "3.months.ago", .want = "2009-05-30 19:20:00" },
        .{ .text = "2.years.3.months.ago", .want = "2007-05-30 19:20:00" },
        .{ .text = "6am yesterday", .want = "2009-08-29 06:00:00" },
        .{ .text = "6pm yesterday", .want = "2009-08-29 18:00:00" },
        .{ .text = "3:00", .want = "2009-08-30 03:00:00" },
        .{ .text = "15:00", .want = "2009-08-30 15:00:00" },
        .{ .text = "noon today", .want = "2009-08-30 12:00:00" },
        .{ .text = "today at noon", .want = "2009-08-30 12:00:00", .shift = -12 * hour },
        .{ .text = "noon today", .want = "2009-09-01 12:00:00", .shift = 36 * hour },
        .{ .text = "noon yesterday", .want = "2009-08-29 12:00:00" },
        .{ .text = "noon yesterday", .want = "2009-08-29 12:00:00", .shift = -12 * hour },
        .{ .text = "last Friday at noon", .want = "2009-08-28 12:00:00" },
        .{ .text = "last Friday at noon", .want = "2009-08-28 12:00:00", .shift = -12 * hour },
        .{ .text = "tea last saturday", .want = "2009-08-29 17:00:00" },
        .{ .text = "tea last saturday", .want = "2009-08-29 17:00:00", .shift = -12 * hour },
        .{ .text = "January 5th noon pm", .want = "2009-01-05 12:00:00" },
        .{ .text = "January 5th noon pm", .want = "2009-01-05 12:00:00", .shift = -12 * hour },
        .{ .text = "January 5th today pm", .want = "2009-01-30 12:00:00" },
        .{ .text = "10am noon", .want = "2009-08-29 12:00:00" },
        .{ .text = "January 5th yesterday", .want = "2009-01-29 19:20:00" },
        .{ .text = "January 5th yesterday", .want = "2008-12-31 19:20:00", .shift = 2 * day },
        .{ .text = "last tuesday", .want = "2009-08-25 19:20:00" },
        .{ .text = "July 5th", .want = "2009-07-05 19:20:00" },
        .{ .text = "06/05/2009", .want = "2009-06-05 19:20:00" },
        .{ .text = "06.05.2009", .want = "2009-05-06 19:20:00" },
        .{ .text = "Jan 5 today", .want = "2009-01-30 00:00:00" },
        .{ .text = "Jun 6, 5AM", .want = "2009-06-06 05:00:00" },
        .{ .text = "5AM Jun 6", .want = "2009-06-06 05:00:00" },
        .{ .text = "6AM, June 7, 2009", .want = "2009-06-07 06:00:00" },
        .{ .text = "2008-12-01", .want = "2008-12-01 19:20:00" },
        .{ .text = "2009-12-01", .want = "2009-12-01 19:20:00" },
        .{ .text = "2000 +0000", .want = "2000-08-30 19:20:00" },
        .{ .text = "@2000 +0000", .want = "1970-01-01 00:33:20" },
    };
    for (cases) |case| {
        const got = approximate(case.text, .{ .now = timestamp(now + case.shift) }) orelse {
            std.debug.print("{s}: no date\n", .{case.text});
            return error.TestUnexpectedResult;
        };
        var buf: [40]u8 = undefined;
        std.testing.expectEqualStrings(case.want, formatUtc(&buf, got)) catch |err| {
            std.debug.print("{s} (shifted {d}s)\n", .{ case.text, case.shift });
            return err;
        };
    }
    try std.testing.expect(approximate("unrecognized words", .{ .now = timestamp(now) }) == null);
    for ([_][]const u8{ "2147483647 months ago", "99999999999999999999 years ago", "4294967295.weeks.ago", "last 2147483647 sunday", "-1 days" }) |text| {
        _ = approximate(text, .{ .now = timestamp(now) });
    }
    try std.testing.expect(approximate("", .{ .now = timestamp(now) }) == null);
}

test "an approximate date is taken in the caller's zone" {
    // 2009-08-30 19:20:00 UTC is 21:20 at +0200, so midnight there is
    // 22:00 the day before in UTC.
    const ctx: Context = .{ .now = timestamp(1251660000), .local_offset_minutes = 120 };
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("2009-08-29 22:00:00", formatUtc(&buf, approximate("today", ctx).?));
    try std.testing.expectEqualStrings("2009-08-30 10:00:00", formatUtc(&buf, approximate("noon", ctx).?));
}

test "fuzz: any text is an approximate date or none, never a crash" {
    try shakedown.check(std.testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = shakedown.gen.intRange(case.source, usize, 0, buf.len);
            case.source.bytes(buf[0..len]);
            _ = approximate(buf[0..len], .{ .now = timestamp(1_700_000_000), .local_offset_minutes = -300 });
        }
    }.one, .{});
}

test "mail dates read as git reads them" {
    const ctx: Context = .{ .now = timestamp(1_800_000_000) };
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = 60 }, parse("Tue, 14 Nov 2023 23:13:20 +0100", ctx).?);
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = 0 }, parse("14 Nov 2023 22:13:20 GMT", ctx).?);
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = -300 }, parse("2023-11-14 17:13:20 -0500", ctx).?);
    try std.testing.expectEqual(Parsed{ .secs = 1700000000, .offset_minutes = 120 }, parse("@1700000000 +0200", ctx).?);
    try std.testing.expect(parse("not a date", ctx) == null);
    // A stamp past a time's range is not a stamp, as git's `TIME_MAX` is
    // not: the text goes on to the general reader, as in git.
    if (parse("@99999999999999999999 +0000", ctx)) |p| try std.testing.expect(p.secs != std.math.maxInt(i64));
}

test "fuzz: any text is a date or no date, never a crash" {
    try shakedown.check(std.testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = shakedown.gen.intRange(case.source, usize, 0, buf.len);
            case.source.bytes(buf[0..len]);
            if (parse(buf[0..len], .{ .now = timestamp(1_700_000_000) })) |p| {
                try std.testing.expect(p.offset_minutes > -24 * 60 * 100 and p.offset_minutes < 24 * 60 * 100);
            }
        }
    }.one, .{});
}

/// All errors reported by this namespace.
pub const Error = ShowError || std.mem.Allocator.Error;
