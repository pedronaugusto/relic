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

// ---------------------------------------------------------------------------
// approxidate
// ---------------------------------------------------------------------------

/// Read `text` as git's `approxidate_careful` does: a date the strict
/// parser reads is that date, and anything else is read word by word
/// against the time now, in the caller's zone. `null` where git reports an
/// error, which is text in which no word meant anything.
pub fn approximate(text_in: []const u8, ctx: Context) ?i64 {
    if (parse(text_in, ctx)) |p| return p.secs;
    const text = if (std.mem.indexOfScalar(u8, text_in, 0)) |z| text_in[0..z] else text_in;
    var a: Approx = .{ .off = ctx.local_offset_minutes, .now_secs = ctx.now };
    a.localtime(ctx.now, &a.tm);
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
    return a.update(0);
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

    fn localtime(a: *const Approx, secs: i64, tm: *Tm) void {
        gmtime(secs + @as(i64, a.off) * 60, tm);
    }

    /// `mktime`: the fields normalized, in the caller's zone.
    fn mktime(a: *const Approx, tm: *const Tm) i64 {
        const year = tm.year + 1900 + @divFloor(tm.mon, 12);
        const mon = @mod(tm.mon, 12);
        const days = daysFromCivil(year, mon + 1, 1) + tm.mday - 1;
        return days * 86400 + tm.hour * 3600 + tm.min * 60 + tm.sec - @as(i64, a.off) * 60;
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
        const n = a.mktime(&a.tm) - sec;
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
    fn atHour(a: *Approx, hour: i64) void {
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
                a.tm.mon = @intCast(i); // safe: a month's index, below 12
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
                    a.num = @intCast(i); // safe: one to ten
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
                var diff = a.tm.wday - @as(i64, @intCast(i)); // safe: a weekday's index, below 7
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
                // safe: git's `timestamp_t` is unsigned and read as a long.
                const m = matchMultiNumber(@bitCast(number), date[end], date, end, &a.tm, ctx);
                if (m != 0) return m;
            },
            else => {},
        }
        // Zero-padding only for small numbers: "Dec 02", never "Dec 0002".
        // git keeps the number in an `int`.
        // safe: wrapping into an `int`, as git's assignment does.
        if (date[0] != '0' or end <= 2) a.num = @as(i32, @truncate(@as(i64, @bitCast(number))));
        return end;
    }
};

/// Days since the epoch of a proleptic Gregorian date, month 1 to 12.
fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The date `secs` is in UTC, as `YYYY-MM-DD hh:mm:ss`.
fn formatUtc(buf: []u8, secs: i64) []const u8 {
    var tm: Tm = .{};
    gmtime(secs, &tm);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)),
        @as(u32, @intCast(tm.mday)),        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),         @as(u32, @intCast(tm.sec)),
    }) catch unreachable;
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
/// `relative` and `human`, and the local zone for `human` and `-local`.
pub const Clock = struct {
    now: ?i64 = null,
    local: ?LocalZone = null,
};

/// Errors from showing a date.
pub const ShowError = error{
    /// A mode that needs the time now or the local zone, and a `Clock`
    /// without it.
    DateNeedsClock,
} || std.mem.Allocator.Error;

const short_weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const short_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const long_weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// git's `tz` integer, `+0130` as 130, in minutes east of UTC.
pub fn tzMinutes(tz: i32) i32 {
    const abs: i32 = @intCast(@abs(tz));
    const minutes = @divTrunc(abs, 100) * 60 + @rem(abs, 100);
    return if (tz < 0) -minutes else minutes;
}

/// Minutes east of UTC as git's `tz` integer.
pub fn tzInt(offset_minutes: i32) i32 {
    const abs: i32 = @intCast(@abs(offset_minutes));
    const v = @divTrunc(abs, 60) * 100 + @rem(abs, 60);
    return if (offset_minutes < 0) -v else v;
}

fn printTz(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tz: i32) std.mem.Allocator.Error!void {
    // C's `%+05d`
    const sign: u8 = if (tz < 0) '-' else '+';
    try out.print(gpa, "{c}{d:0>4}", .{ sign, @abs(tz) });
}

/// git's `show_date_relative`.
pub fn showRelative(gpa: std.mem.Allocator, out: *std.ArrayList(u8), secs: i64, now: i64) std.mem.Allocator.Error!void {
    if (now < secs) return out.appendSlice(gpa, "in the future");
    var diff: i64 = now - secs;
    if (diff < 90) return plural(gpa, out, diff, "second", " ago");
    diff = @divTrunc(diff + 30, 60);
    if (diff < 90) return plural(gpa, out, diff, "minute", " ago");
    diff = @divTrunc(diff + 30, 60);
    if (diff < 36) return plural(gpa, out, diff, "hour", " ago");
    diff = @divTrunc(diff + 12, 24);
    if (diff < 14) return plural(gpa, out, diff, "day", " ago");
    if (diff < 70) return plural(gpa, out, @divTrunc(diff + 3, 7), "week", " ago");
    if (diff < 365) return plural(gpa, out, @divTrunc(diff + 15, 30), "month", " ago");
    if (diff < 1825) {
        const total_months = @divTrunc(diff * 12 * 2 + 365, 365 * 2);
        const years = @divTrunc(total_months, 12);
        const months = @rem(total_months, 12);
        if (months != 0) {
            try plural(gpa, out, years, "year", ", ");
            return plural(gpa, out, months, "month", " ago");
        }
        return plural(gpa, out, years, "year", " ago");
    }
    return plural(gpa, out, @divTrunc(diff + 183, 365), "year", " ago");
}

fn plural(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: i64, unit: []const u8, after: []const u8) std.mem.Allocator.Error!void {
    try out.print(gpa, "{d} {s}{s}{s}", .{ n, unit, if (n == 1) "" else "s", after });
}

/// The calendar fields of `secs` shown in zone `tz`, as git's `time_to_tm`.
fn tmIn(secs: i64, tz: i32) Tm {
    var tm: Tm = .{};
    gmtime(secs + @as(i64, tzMinutes(tz)) * 60, &tm);
    return tm;
}

/// `secs`, in the zone `tz` (git's `+0100` as 100), as `mode` shows it:
/// git's `show_date`, appended to `out`.
pub fn show(gpa: std.mem.Allocator, out: *std.ArrayList(u8), secs: i64, tz_in: i32, mode: Mode, clock: Clock) ShowError!void {
    var tz = tz_in;
    if (mode.kind == .unix) return out.print(gpa, "{d}", .{secs});
    var human_tm: Tm = .{ .year = 0, .mon = 0, .mday = 0, .hour = 0, .min = 0, .sec = 0 };
    var human_tz: i32 = -1;
    if (mode.kind == .human) {
        const now = clock.now orelse return error.DateNeedsClock;
        const zone = clock.local orelse return error.DateNeedsClock;
        human_tz = tzInt(zone.at(zone.context, now).offset_minutes);
        human_tm = tmIn(now, human_tz);
    }
    var zone_name: []const u8 = "";
    if (mode.local) {
        const zone = clock.local orelse return error.DateNeedsClock;
        const local = zone.at(zone.context, secs);
        tz = tzInt(local.offset_minutes);
        zone_name = local.name;
    }
    if (mode.kind == .raw) {
        try out.print(gpa, "{d} ", .{secs});
        return printTz(gpa, out, tz);
    }
    if (mode.kind == .relative) return showRelative(gpa, out, secs, clock.now orelse return error.DateNeedsClock);
    const tm = tmIn(secs, tz);
    const year: i64 = tm.year + 1900;
    switch (mode.kind) {
        .short => try out.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(year, 0))), @as(u64, @intCast(tm.mon + 1)), @as(u64, @intCast(tm.mday)) }),
        .iso8601 => {
            try out.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{ @as(u64, @intCast(@max(year, 0))), @as(u64, @intCast(tm.mon + 1)), @as(u64, @intCast(tm.mday)), @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)), @as(u64, @intCast(tm.sec)) });
            try printTz(gpa, out, tz);
        },
        .iso8601_strict => {
            try out.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@max(year, 0))), @as(u64, @intCast(tm.mon + 1)), @as(u64, @intCast(tm.mday)), @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)), @as(u64, @intCast(tm.sec)) });
            if (tz == 0) {
                try out.append(gpa, 'Z');
            } else {
                const abs: u32 = @abs(tz);
                try out.print(gpa, "{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (tz >= 0) '+' else '-'), abs / 100, abs % 100 });
            }
        },
        .rfc2822 => {
            try out.print(gpa, "{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} ", .{ short_weekdays[@intCast(tm.wday)], tm.mday, short_months[@intCast(tm.mon)], year, @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)), @as(u64, @intCast(tm.sec)) });
            try printTz(gpa, out, tz);
        },
        .strftime => try strftime(gpa, out, mode.strftime, secs, tm, tz, if (mode.local) zone_name else null),
        else => try showNormal(gpa, out, secs, tm, tz, human_tm, human_tz, mode.local, clock),
    }
}

/// git's `show_date_normal`, which `human` shares.
fn showNormal(gpa: std.mem.Allocator, out: *std.ArrayList(u8), secs: i64, tm: Tm, tz: i32, human_tm: Tm, human_tz: i32, local: bool, clock: Clock) ShowError!void {
    var hide_year = false;
    var hide_date = false;
    var hide_wday = false;
    var hide_time = false;
    var hide_seconds = false;
    var hide_tz = local or tz == human_tz;
    hide_year = tm.year == human_tm.year;
    if (hide_year) {
        if (tm.mon == human_tm.mon) {
            if (tm.mday > human_tm.mday) {
                // a future date: think time zones
            } else if (tm.mday == human_tm.mday) {
                hide_date = true;
                hide_wday = true;
            } else if (tm.mday + 5 > human_tm.mday) {
                hide_date = true;
            }
        }
    }
    if (hide_wday) return showRelative(gpa, out, secs, clock.now orelse return error.DateNeedsClock);
    if (human_tm.year != 0) {
        hide_seconds = true;
        hide_tz = hide_tz or !hide_date;
        hide_wday = !hide_year;
        hide_time = !hide_year;
    }
    if (!hide_wday) try out.print(gpa, "{s} ", .{short_weekdays[@intCast(tm.wday)]});
    if (!hide_date) try out.print(gpa, "{s} {d} ", .{ short_months[@intCast(tm.mon)], tm.mday });
    if (!hide_time) {
        try out.print(gpa, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)) });
        if (!hide_seconds) try out.print(gpa, ":{d:0>2}", .{@as(u64, @intCast(tm.sec))});
    } else {
        while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) _ = out.pop();
    }
    if (!hide_year) try out.print(gpa, " {d}", .{tm.year + 1900});
    if (!hide_tz) {
        try out.append(gpa, ' ');
        try printTz(gpa, out, tz);
    }
}

fn yearDay(tm: Tm) i64 {
    const year = tm.year + 1900;
    return daysFromCivil(year, tm.mon + 1, tm.mday) - daysFromCivil(year, 1, 1);
}

fn isLeap(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

/// The ISO 8601 week-based year and week of `tm`.
fn isoWeek(tm: Tm) struct { year: i64, week: i64 } {
    const year = tm.year + 1900;
    const yday = yearDay(tm);
    const wday_mon = @mod(tm.wday + 6, 7); // Monday is 0
    var week = @divFloor(yday - wday_mon + 10, 7);
    if (week < 1) {
        const prev = year - 1;
        const prev_days: i64 = if (isLeap(prev)) 366 else 365;
        week = @divFloor(yday + prev_days - wday_mon + 10, 7);
        return .{ .year = prev, .week = week };
    }
    const days: i64 = if (isLeap(year)) 366 else 365;
    if (week == 53 and yday - wday_mon + 3 >= days) return .{ .year = year + 1, .week = 1 };
    return .{ .year = year, .week = week };
}

/// git's `strbuf_addftime` over the C library's `strftime` in the C
/// locale: `%z`, `%Z` and `%s` as git rewrites them, every other
/// conversion the C library's. `zone_name` is `%Z`'s text for a local
/// date; `null` writes nothing for it, as git does for a date in its own
/// zone.
pub fn strftime(gpa: std.mem.Allocator, out: *std.ArrayList(u8), fmt: []const u8, secs: i64, tm: Tm, tz: i32, zone_name: ?[]const u8) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%' or i + 1 >= fmt.len) {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        var j = i + 1;
        // the E and O modifiers change nothing in the C locale
        if ((fmt[j] == 'E' or fmt[j] == 'O') and j + 1 < fmt.len) j += 1;
        const conv = fmt[j];
        i = j + 1;
        const year = tm.year + 1900;
        const hour12: i64 = if (@mod(tm.hour, 12) == 0) 12 else @mod(tm.hour, 12);
        switch (conv) {
            '%' => try out.append(gpa, '%'),
            'a' => try out.appendSlice(gpa, short_weekdays[@intCast(tm.wday)]),
            'A' => try out.appendSlice(gpa, long_weekdays[@intCast(tm.wday)]),
            'b', 'h' => try out.appendSlice(gpa, short_months[@intCast(tm.mon)]),
            'B' => try out.appendSlice(gpa, month_names[@intCast(tm.mon)]),
            'c' => try out.print(gpa, "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{ short_weekdays[@intCast(tm.wday)], short_months[@intCast(tm.mon)], @as(u64, @intCast(tm.mday)), @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)), @as(u64, @intCast(tm.sec)), year }),
            'C' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@divFloor(year, 100)))}),
            'd' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(tm.mday))}),
            'D' => try out.print(gpa, "{d:0>2}/{d:0>2}/{d:0>2}", .{ @as(u64, @intCast(tm.mon + 1)), @as(u64, @intCast(tm.mday)), @as(u64, @intCast(@mod(year, 100))) }),
            'e' => try out.print(gpa, "{d: >2}", .{@as(u64, @intCast(tm.mday))}),
            'F' => try out.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(year, 0))), @as(u64, @intCast(tm.mon + 1)), @as(u64, @intCast(tm.mday)) }),
            'g' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@mod(isoWeek(tm).year, 100)))}),
            'G' => try out.print(gpa, "{d}", .{isoWeek(tm).year}),
            'H' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(tm.hour))}),
            'I' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(hour12))}),
            'j' => try out.print(gpa, "{d:0>3}", .{@as(u64, @intCast(yearDay(tm) + 1))}),
            'k' => try out.print(gpa, "{d: >2}", .{@as(u64, @intCast(tm.hour))}),
            'l' => try out.print(gpa, "{d: >2}", .{@as(u64, @intCast(hour12))}),
            'm' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(tm.mon + 1))}),
            'M' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(tm.min))}),
            'n' => try out.append(gpa, '\n'),
            'p' => try out.appendSlice(gpa, if (tm.hour < 12) "AM" else "PM"),
            'r' => try out.print(gpa, "{d:0>2}:{d:0>2}:{d:0>2} {s}", .{ @as(u64, @intCast(hour12)), @as(u64, @intCast(tm.min)), @as(u64, @intCast(tm.sec)), if (tm.hour < 12) "AM" else "PM" }),
            'R' => try out.print(gpa, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)) }),
            's' => try out.print(gpa, "{d}", .{secs}),
            'S' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(tm.sec))}),
            't' => try out.append(gpa, '\t'),
            'T', 'X' => try out.print(gpa, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(tm.hour)), @as(u64, @intCast(tm.min)), @as(u64, @intCast(tm.sec)) }),
            'u' => try out.print(gpa, "{d}", .{if (tm.wday == 0) 7 else tm.wday}),
            'U' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@divFloor(yearDay(tm) + 7 - tm.wday, 7)))}),
            'V' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(isoWeek(tm).week))}),
            'w' => try out.print(gpa, "{d}", .{tm.wday}),
            'W' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@divFloor(yearDay(tm) + 7 - @mod(tm.wday + 6, 7), 7)))}),
            'x' => try out.print(gpa, "{d:0>2}/{d:0>2}/{d:0>2}", .{ @as(u64, @intCast(tm.mon + 1)), @as(u64, @intCast(tm.mday)), @as(u64, @intCast(@mod(year, 100))) }),
            'y' => try out.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@mod(year, 100)))}),
            'Y' => try out.print(gpa, "{d}", .{year}),
            'z' => try printTz(gpa, out, tz),
            'Z' => if (zone_name) |name| try out.appendSlice(gpa, name),
            else => try out.appendSlice(gpa, fmt[i - 2 .. i]),
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
        const got = approximate(case.text, .{ .now = now + case.shift }) orelse {
            std.debug.print("{s}: no date\n", .{case.text});
            return error.TestUnexpectedResult;
        };
        var buf: [32]u8 = undefined;
        std.testing.expectEqualStrings(case.want, formatUtc(&buf, got)) catch |err| {
            std.debug.print("{s} (shifted {d}s)\n", .{ case.text, case.shift });
            return err;
        };
    }
    try std.testing.expect(approximate("unrecognized words", .{ .now = now }) == null);
    for ([_][]const u8{ "2147483647 months ago", "99999999999999999999 years ago", "4294967295.weeks.ago", "last 2147483647 sunday", "-1 days" }) |text| {
        _ = approximate(text, .{ .now = now });
    }
    try std.testing.expect(approximate("", .{ .now = now }) == null);
}

test "an approximate date is taken in the caller's zone" {
    // 2009-08-30 19:20:00 UTC is 21:20 at +0200, so midnight there is
    // 22:00 the day before in UTC.
    const ctx: Context = .{ .now = 1251660000, .local_offset_minutes = 120 };
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2009-08-29 22:00:00", formatUtc(&buf, approximate("today", ctx).?));
    try std.testing.expectEqualStrings("2009-08-30 10:00:00", formatUtc(&buf, approximate("noon", ctx).?));
}

test "fuzz: any text is an approximate date or none, never a crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            _ = approximate(buf[0..len], .{ .now = 1_700_000_000, .local_offset_minutes = -300 });
        }
    }.one, .{});
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
