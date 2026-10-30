//! Times as the LFS API writes them, read into seconds since the epoch:
//! RFC 3339, which `expires_at` and a lock's `locked_at` are in, and the
//! HTTP date a `Retry-After` may be. Reading one never reads the clock;
//! what it is compared with is the caller's.

const std = @import("std");
const shakedown = @import("shakedown");
const Io = std.Io;
const date = @import("../text.zig").date;

/// A time as Go's `time.Time` holds one that was read from RFC 3339 text:
/// the instant, and the offset it was written with. Go's zero time,
/// `0001-01-01T00:00:00Z`, is the default and stands for no time, as git-lfs
/// takes `IsZero`.
pub const GoTime = struct {
    /// Seconds since the Unix epoch.
    unix: i64 = zero_unix,
    nanos: u32 = 0,
    /// Seconds east of UTC.
    offset: i32 = 0,

    pub const zero_unix: i64 = -62135596800;

    /// Whether this is Go's zero instant, whatever its offset.
    pub fn isZero(t: GoTime) bool {
        return t.unix == zero_unix and t.nanos == 0;
    }

    /// Nanoseconds since the Unix epoch, as a wide integer.
    pub fn nanoseconds(t: GoTime) i128 {
        return @as(i128, t.unix) * std.time.ns_per_s + t.nanos; // aegis: no-danger: Go's time as nanoseconds since the epoch, as git-lfs compares it
    }

    /// `text` as Go's `time.Parse(time.RFC3339, text)` reads it, which is how
    /// git-lfs reads `expires_at`, `locked_at` and an ssh `expires-at=`: four
    /// digits of year; two of month, day, minute and second; one or two of
    /// hour; fractional seconds after `.` or `,`, their first nine digits
    /// kept; `Z`, or an offset `±hh:mm` of at most 24 hours and 60 minutes.
    /// `null` for anything else, a day the month lacks among them.
    pub fn parse(text: []const u8) ?GoTime {
        var rest = text;
        const year = fixed(&rest, 4) orelse return null;
        if (!literal(&rest, '-')) return null;
        const month = fixed(&rest, 2) orelse return null;
        if (month < 1 or month > 12 or !literal(&rest, '-')) return null;
        const day = fixed(&rest, 2) orelse return null;
        if (!literal(&rest, 'T')) return null;
        const hour = loose(&rest) orelse return null;
        if (hour > 23 or !literal(&rest, ':')) return null;
        const minute = fixed(&rest, 2) orelse return null;
        if (minute > 59 or !literal(&rest, ':')) return null;
        const second = fixed(&rest, 2) orelse return null;
        if (second > 59) return null;
        var nanos: u32 = 0;
        if (rest.len >= 2 and (rest[0] == '.' or rest[0] == ',') and std.ascii.isDigit(rest[1])) {
            var n: usize = 1;
            while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
            for (1..10) |k| nanos = nanos * 10 + (if (k < n) rest[k] - '0' else 0);
            rest = rest[n..];
        }
        var offset: i32 = 0;
        if (rest.len >= 1 and rest[0] == 'Z') {
            rest = rest[1..];
        } else {
            if (rest.len < 6 or rest[3] != ':') return null;
            var h: []const u8 = rest[1..3];
            var m: []const u8 = rest[4..6];
            const oh = fixed(&h, 2) orelse return null;
            const om = fixed(&m, 2) orelse return null;
            if (oh > 24 or om > 60) return null;
            offset = @intCast((oh * 60 + om) * 60);
            switch (rest[0]) {
                '+' => {},
                '-' => offset = -offset,
                else => return null,
            }
            rest = rest[6..];
        }
        if (rest.len != 0) return null;
        const cal = date.Calendar.fromFields(year, month, day, hour, minute, second) orelse return null;
        const unix = std.math.sub(i64, cal.moment() orelse return null, offset) catch return null;
        return .{ .unix = unix, .nanos = nanos, .offset = offset };
    }

    /// Errors from `format`.
    pub const FormatError = Io.Writer.Error || error{UnwritableTime};

    /// The time as Go's `MarshalJSON` writes it, unquoted: RFC 3339 with
    /// as many fractional digits as it needs, in the offset it was read
    /// with, `Z` for none. An offset of 24 hours or more is
    /// `error.UnwritableTime`, as Go refuses to write it.
    pub fn format(t: GoTime, w: *Io.Writer) FormatError!void {
        // A year past four digits, or a time past what a timestamp holds,
        // has no RFC 3339 text.
        const local = std.math.add(i64, t.unix, t.offset) catch return error.UnwritableTime;
        const cal = date.calendarIn(local, 0) orelse return error.UnwritableTime;
        const year = std.math.cast(u14, cal.year) orelse return error.UnwritableTime;
        if (year > 9999) return error.UnwritableTime;
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ year, @as(u8, cal.month) + 1, cal.day, cal.hour, cal.minute, cal.second });
        if (t.nanos != 0) {
            var fraction: [9]u8 = undefined;
            _ = std.fmt.printInt(&fraction, t.nanos, 10, .lower, .{ .width = 9, .fill = '0' });
            try w.print(".{s}", .{std.mem.trimEnd(u8, &fraction, "0")});
        }
        if (t.offset == 0) return w.writeByte('Z');
        const east = @abs(t.offset);
        if (east / 3600 >= 24) return error.UnwritableTime;
        try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (t.offset < 0) '-' else '+'), east / 3600, (east / 60) % 60 });
    }

    /// A JSON string as Go's `Time.UnmarshalJSON` reads one: its text by
    /// `parse`, anything else refused. A `null`, which Go's leaves as it is,
    /// is the reading's to keep (`strand.core.Nulls.keep`).
    pub fn strandDeserialize(access: anytype) (@TypeOf(access.*).Error || error{InvalidTime})!GoTime {
        return parse(try access.read([]const u8)) orelse error.InvalidTime;
    }

    /// The time as Go's `MarshalJSON` writes it: `format`, as a string.
    pub fn strandSerialize(t: GoTime, access: anytype) (@TypeOf(access.*).Error || error{UnwritableTime})!void {
        var buffer: [48]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        t.format(&w) catch |err| return switch (err) {
            error.UnwritableTime => error.UnwritableTime,
            // unreachable: the longest time Go writes is 35 bytes.
            error.WriteFailed => unreachable,
        };
        try access.write(@as([]const u8, w.buffered()));
    }
};

/// `n` digits off the front of `rest`.
fn fixed(rest: *[]const u8, n: usize) ?u32 {
    if (rest.len < n) return null;
    const value = digits(rest.*[0..n]) orelse return null;
    rest.* = rest.*[n..];
    return value;
}

/// One or two digits off the front of `rest`, as Go reads an hour.
fn loose(rest: *[]const u8) ?u32 {
    if (rest.len == 0 or !std.ascii.isDigit(rest.*[0])) return null;
    const n: usize = if (rest.len >= 2 and std.ascii.isDigit(rest.*[1])) 2 else 1;
    return fixed(rest, n);
}

fn literal(rest: *[]const u8, c: u8) bool {
    if (rest.len == 0 or rest.*[0] != c) return false;
    rest.* = rest.*[1..];
    return true;
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
    const cal = date.Calendar.fromFields(year, month, day, hour, minute, second) orelse return null;
    return cal.moment();
}

fn digits(text: []const u8) ?u32 {
    var n: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

const testing = std.testing;

test "RFC 3339 is read as Go's time.Parse reads it, and written as Go writes it" {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "1970-01-01T00:00:00Z", "1970-01-01T00:00:00Z" },
        .{ "2006-01-02T15:04:05-07:00", "2006-01-02T15:04:05-07:00" },
        .{ "2006-01-02T15:04:05.999999999Z", "2006-01-02T15:04:05.999999999Z" },
        .{ "2006-01-02T15:04:05.123456789123Z", "2006-01-02T15:04:05.123456789Z" },
        .{ "2006-01-02T15:04:05,5Z", "2006-01-02T15:04:05.5Z" },
        .{ "2006-01-02T15:04:05.500+00:00", "2006-01-02T15:04:05.5Z" },
        .{ "2006-01-02T5:04:05Z", "2006-01-02T05:04:05Z" },
        .{ "2006-01-02T15:04:05+07:60", "2006-01-02T15:04:05+08:00" },
        .{ "2000-02-29T00:00:00Z", "2000-02-29T00:00:00Z" },
        .{ "0000-01-01T00:00:00+01:00", "0000-01-01T00:00:00+01:00" },
        .{ "2006-01-02T15:04:05+24:00", null },
    };
    for (cases) |case| {
        const t = GoTime.parse(case[0]) orelse return error.TestUnexpectedResult;
        var buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        if (case[1]) |want| {
            try t.format(&w);
            try testing.expectEqualStrings(want, w.buffered());
        } else try testing.expectError(error.UnwritableTime, t.format(&w));
    }
    try testing.expectEqual(@as(i64, 1136239445), GoTime.parse("2006-01-02T15:04:05-07:00").?.unix);
    try testing.expectEqual(@as(i64, 1136127845), GoTime.parse("2006-01-02T15:04:05+24:00").?.unix);
    try testing.expect(GoTime.parse("0001-01-01T01:00:00+01:00").?.isZero());
    try testing.expect((GoTime{}).isZero());
    for ([_][]const u8{ "", "2006-01-02 15:04:05Z", "2006-01-02T15:04:05", "1900-02-29T00:00:00Z", "2006-13-02T15:04:05Z", "2006-01-02T15:04:05+0700", "2006-01-02T15:04:05.Z", "2006-01-02t15:04:05Z", "2006-01-02T15:04:60Z", "2006-02-30T15:04:05Z", "+2006-01-02T15:04:05Z", "2006-01-02T15:04:05 Z", "2006-01-02T15:04:05+25:00", "2006-01-02T15:04:05+07:61", "2006-01-02T24:04:05Z", "2006-01-02T15:04:05z" }) |bad| {
        try testing.expectEqual(@as(?GoTime, null), GoTime.parse(bad));
    }
}

test "HTTP dates are read to the second, as Go reads them" {
    try testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 UTC"));
    for ([_][]const u8{ "120", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994", "Sun, 06 Nov 1994 08:49:37 gmt", "Xyz, 06 Nov 1994 08:49:37 GMT" }) |bad| {
        try testing.expectEqual(@as(?i64, null), parseHttpDate(bad));
    }
}

test "fuzz: any text is a time or is not, and never a crash" {
    try shakedown.check(testing.allocator, {}, fuzzTimes, .{});
}

fn fuzzTimes(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [64]u8 = undefined;
    const len = shakedown.gen.intRange(case.source, usize, 0, scratch.len);
    case.source.bytes(scratch[0..len]);
    if (GoTime.parse(scratch[0..len])) |t| {
        var buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        // An offset Go refuses to write is an answer, not a crash.
        if (t.format(&w)) |_| {} else |_| {}
    }
    _ = parseHttpDate(scratch[0..len]);
}

/// All errors reported by this namespace.
pub const Error = error{ UnwritableTime, InvalidTime };
