//! git's `--format` placeholders for one commit: what `git log
//! --format=...` prints and what `git archive` substitutes for
//! `$Format:...$` in a file marked `export-subst`.
//!
//! Names, emails, dates in git's formats, object names whole and
//! abbreviated, subject, body, the `%+`, `%-` and `% ` modifiers, `%n`,
//! `%%` and `%xNN`, each as git's `pretty.c` writes it; an unknown
//! placeholder is written as it stands, as git writes it. What needs more
//! than the commit — decorations (`%d`, `%D`), `%(describe)`, signatures
//! (`%G?`), notes (`%N`), the mailmap (`%aN`, `%aE`), relative and human
//! dates, `%(trailers)`, wrapping, padding and colour — is refused as
//! `error.UnsupportedPlaceholder`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object_core.zig");
const odb_mod = @import("odb_core.zig");
const abbrev = @import("abbrev.zig");
const mailfmt = @import("mailfmt.zig");

const Oid = hash.Oid;

/// Errors from formatting.
pub const Error = error{
    /// A placeholder git understands that this does not produce.
    UnsupportedPlaceholder,
    NotACommit,
} || odb_mod.Error || object.ParseError || Allocator.Error;

/// What formatting needs besides the commit.
pub const Context = struct {
    /// The digits `%h`, `%t` and `%p` start from before they grow to be
    /// unique: `core.abbrev`'s length.
    abbrev_len: usize = abbrev.fallback,
};

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const DateMode = enum { normal, rfc2822, iso, iso_strict, short, unix };

fn writeDate(a: Allocator, out: *std.ArrayList(u8), sig: object.Signature, mode: DateMode) Allocator.Error!void {
    if (mode == .unix) {
        try out.print(a, "{d}", .{sig.when_secs});
        return;
    }
    const tz = mailfmt.tzInt(sig.offset_minutes);
    const c = mailfmt.civil(sig.when_secs + @as(i64, sig.offset_minutes) * 60);
    const sign: u8 = if (tz < 0) '-' else '+';
    const abs_tz = @abs(tz);
    switch (mode) {
        .normal => try out.print(a, "{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d} {c}{d:0>4}", .{ weekday_names[c.weekday], month_names[c.month - 1], c.day, c.hour, c.minute, c.second, c.year, sign, abs_tz }),
        .rfc2822 => try out.print(a, "{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>4}", .{ weekday_names[c.weekday], c.day, month_names[c.month - 1], c.year, c.hour, c.minute, c.second, sign, abs_tz }),
        .iso => try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>4}", .{ @as(u64, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second, sign, abs_tz }),
        .iso_strict => {
            try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second });
            if (tz == 0) try out.append(a, 'Z') else try out.print(a, "{c}{d:0>2}:{d:0>2}", .{ sign, abs_tz / 100, abs_tz % 100 });
        },
        .short => try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(c.year)), c.month, c.day }),
        .unix => unreachable,
    }
}

const Parsed = struct {
    oid: Oid,
    commit: object.Commit,
    raw: []const u8,
    /// The message after the blank line that ends the headers.
    message: []const u8,
};

fn getOneLine(msg: []const u8) usize {
    var i: usize = 0;
    while (i < msg.len) {
        const ch = msg[i];
        if (ch == 0) break;
        i += 1;
        if (ch == '\n') break;
    }
    return i;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!isSpace(c)) return false;
    return true;
}

fn skipBlankLines(msg: []const u8) []const u8 {
    var rest = msg;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0 or !isBlank(rest[0..len])) break;
        rest = rest[len..];
    }
    return rest;
}

fn uniqueHex(a: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid, len: usize) Error![]const u8 {
    var buf: [hash.max_hex_len]u8 = undefined;
    return a.dupe(u8, try abbrev.unique(io, db, oid, len, &buf));
}

fn person(a: Allocator, out: *std.ArrayList(u8), sig: object.Signature, part: u8) Error!usize {
    switch (part) {
        'n' => try out.appendSlice(a, sig.name),
        'e' => try out.appendSlice(a, sig.email),
        'l' => {
            const at = std.mem.indexOfScalar(u8, sig.email, '@') orelse sig.email.len;
            try out.appendSlice(a, sig.email[0..at]);
        },
        't' => try writeDate(a, out, sig, .unix),
        'd' => try writeDate(a, out, sig, .normal),
        'D' => try writeDate(a, out, sig, .rfc2822),
        'i' => try writeDate(a, out, sig, .iso),
        'I' => try writeDate(a, out, sig, .iso_strict),
        's' => try writeDate(a, out, sig, .short),
        'N', 'E', 'L', 'r', 'h' => return error.UnsupportedPlaceholder,
        else => return 0,
    }
    return 2;
}

fn sanitizedSubject(a: Allocator, out: *std.ArrayList(u8), msg: []const u8) Allocator.Error!void {
    const start = out.items.len;
    var space: u2 = 2;
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        const c = msg[i];
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_') {
            if (space == 1) try out.append(a, '-');
            space = 0;
            try out.append(a, c);
            if (c == '.') {
                while (i + 1 < msg.len and msg[i + 1] == '.') i += 1;
            }
        } else space |= 1;
    }
    while (out.items.len > start and (out.items[out.items.len - 1] == '.' or out.items[out.items.len - 1] == '-')) _ = out.pop();
}

/// One placeholder, `ph` being what follows the `%`. Returns how many
/// bytes it took, zero for one git does not know.
fn one(a: Allocator, io: Io, db: *odb_mod.Odb, ctx: Context, p: *const Parsed, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    if (ph.len == 0) return 0;
    switch (ph[0]) {
        'n' => {
            try out.append(a, '\n');
            return 1;
        },
        'x' => {
            if (ph.len >= 3) {
                const hi = std.fmt.charToDigit(ph[1], 16) catch return 0;
                const lo = std.fmt.charToDigit(ph[2], 16) catch return 0;
                try out.append(a, hi << 4 | lo);
                return 3;
            }
            return 0;
        },
        'C', 'w', '<', '>' => return error.UnsupportedPlaceholder,
        else => {},
    }
    if (std.mem.startsWith(u8, ph, "(describe") or std.mem.startsWith(u8, ph, "(decorate") or
        std.mem.startsWith(u8, ph, "(trailers") or std.mem.startsWith(u8, ph, "(count)") or
        std.mem.startsWith(u8, ph, "(total)")) return error.UnsupportedPlaceholder;
    var hexbuf: [hash.max_hex_len]u8 = undefined;
    switch (ph[0]) {
        'H' => {
            try out.appendSlice(a, p.oid.hex(&hexbuf));
            return 1;
        },
        'h' => {
            try out.appendSlice(a, try uniqueHex(a, io, db, p.oid, ctx.abbrev_len));
            return 1;
        },
        'T' => {
            try out.appendSlice(a, p.commit.tree.hex(&hexbuf));
            return 1;
        },
        't' => {
            try out.appendSlice(a, try uniqueHex(a, io, db, p.commit.tree, ctx.abbrev_len));
            return 1;
        },
        'P' => {
            for (p.commit.parents, 0..) |parent, i| {
                if (i > 0) try out.append(a, ' ');
                try out.appendSlice(a, parent.hex(&hexbuf));
            }
            return 1;
        },
        'p' => {
            for (p.commit.parents, 0..) |parent, i| {
                if (i > 0) try out.append(a, ' ');
                try out.appendSlice(a, try uniqueHex(a, io, db, parent, ctx.abbrev_len));
            }
            return 1;
        },
        'm' => return 0,
        'd', 'D', 'S', 'N' => return error.UnsupportedPlaceholder,
        'g' => return error.UnsupportedPlaceholder,
        'G' => return error.UnsupportedPlaceholder,
        'a' => return if (ph.len >= 2) person(a, out, p.commit.author, ph[1]) else 0,
        'c' => return if (ph.len >= 2) person(a, out, p.commit.committer, ph[1]) else 0,
        'e' => {
            if (p.commit.encoding) |e| try out.appendSlice(a, e);
            return 1;
        },
        'B' => {
            try out.appendSlice(a, cstr(p.message));
            return 1;
        },
        's', 'f', 'b' => {
            const msg = cstr(p.message);
            const subject = skipBlankLines(msg);
            // the subject paragraph and where the body starts
            var rest = subject;
            while (true) {
                const len = getOneLine(rest);
                if (len == 0 or isBlank(rest[0..len])) break;
                rest = rest[len..];
            }
            const body = skipBlankLines(rest);
            switch (ph[0]) {
                's' => {
                    var first = true;
                    var r = subject;
                    while (true) {
                        const len = getOneLine(r);
                        if (len == 0 or isBlank(r[0..len])) break;
                        var line = r[0..len];
                        while (line.len > 0 and isSpace(line[line.len - 1])) line = line[0 .. line.len - 1];
                        if (!first) try out.append(a, ' ');
                        try out.appendSlice(a, line);
                        first = false;
                        r = r[len..];
                    }
                },
                'f' => {
                    const eol = std.mem.indexOfScalar(u8, subject, '\n') orelse subject.len;
                    try sanitizedSubject(a, out, subject[0..eol]);
                },
                'b' => try out.appendSlice(a, body),
                else => unreachable,
            }
            return 1;
        },
        else => return 0,
    }
}

fn cstr(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, 0)) |z| s[0..z] else s;
}

/// The commit `oid` formatted by `format`, appended to `out`.
pub fn formatCommit(a: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid, format: []const u8, ctx: Context, out: *std.ArrayList(u8)) Error!void {
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const raw = try a.dupe(u8, found.bytes);
    const commit = try object.Commit.parse(a, db.objectFormat(), raw);
    const p: Parsed = .{ .oid = oid, .commit = commit, .raw = raw, .message = commit.message };
    var at: usize = 0;
    while (at < format.len) {
        const pct = std.mem.indexOfScalarPos(u8, format, at, '%') orelse {
            try out.appendSlice(a, format[at..]);
            break;
        };
        try out.appendSlice(a, format[at..pct]);
        var ph = format[pct + 1 ..];
        if (ph.len > 0 and ph[0] == '%') {
            try out.append(a, '%');
            at = pct + 2;
            continue;
        }
        // the modifiers: %+x, %-x, % x
        var magic: u8 = 0;
        if (ph.len > 0 and (ph[0] == '+' or ph[0] == '-' or ph[0] == ' ')) {
            magic = ph[0];
            ph = ph[1..];
            if (ph.len > 0 and ph[0] == 'w') {
                try out.append(a, '%');
                at = pct + 1;
                continue;
            }
        }
        const orig_len = out.items.len;
        const consumed = try one(a, io, db, ctx, &p, out, ph);
        if (consumed == 0) {
            try out.append(a, '%');
            at = pct + 1;
            continue;
        }
        if (magic != 0) {
            if (orig_len == out.items.len and magic == '-') {
                while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
            } else if (orig_len != out.items.len) {
                if (magic == '+') try out.insert(a, orig_len, '\n') else if (magic == ' ') try out.insert(a, orig_len, ' ');
            }
        }
        at = pct + 1 + @as(usize, @intFromBool(magic != 0)) + consumed;
    }
}

test "placeholders come out as git's do" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try writeDate(arena.allocator(), &out, .{ .name = "", .email = "", .when_secs = 1700000000, .offset_minutes = 60 }, .normal);
    try std.testing.expectEqualStrings("Tue Nov 14 23:13:20 2023 +0100", out.items);
    out.clearRetainingCapacity();
    try writeDate(arena.allocator(), &out, .{ .name = "", .email = "", .when_secs = 1700000000, .offset_minutes = 0 }, .iso_strict);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", out.items);
}
