//! object's documented guarantees as properties, each checked against a
//! definition written from the doc or from git's reader it names, not only
//! "no crash": a loose header is accepted exactly when it is the one
//! spelling of a header; a tree mode reads as git's `get_mode` and
//! `canon_mode`; an ident splits where `split_ident_line` splits it, and
//! one `write` accepts reads back as itself; a tree's entries come back in
//! the object's order, a cut or bad entry refused after the whole ones; and
//! a built tree holds its entries once each, sorted by git's key.

const std = @import("std");
const shakedown = @import("shakedown");
const object = @import("object.zig");
const hash = @import("../hash/hash.zig");
const testing = std.testing;
const gen = shakedown.gen;
const Mode = object.Mode;
const Signature = object.Signature;
const Tree = object.Tree;

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

// parseHeader: "a size with a leading zero, a sign or anything but digits is
// refused, because ... accepting one gives an object two spellings".

const header_pieces = [_][]const u8{
    "blob", "tree", "commit", "tag", "blub", "Blob",  " ",                    "  ",                   "\x00", "\t",
    "0",    "1",    "7",      "9",   "00",   "012",   "18446744073709551615", "18446744073709551616", "+",    "-",
    "_",    "x",    "0x1",    "1e3",
};

/// Whether `line` is `<type> <size>` as git writes it: one of the four
/// words, one space, and the size's decimal digits with no leading zero,
/// within 64 bits.
fn isSpelling(line: []const u8) bool {
    for ([_][]const u8{ "blob", "tree", "commit", "tag" }) |word| {
        if (line.len <= word.len + 1 or !std.mem.startsWith(u8, line, word) or line[word.len] != ' ') continue;
        const digits = line[word.len + 1 ..];
        for (digits) |c| if (c < '0' or c > '9') return false;
        if (digits.len > 1 and digits[0] == '0') return false;
        // All digits, so parseInt sees no sign or separator: it decides the range alone.
        _ = std.fmt.parseInt(u64, digits, 10) catch return false;
        return true;
    }
    return false;
}

fn anyHeader(_: void, case: *shakedown.Case) !void {
    var buffer: [96]u8 = undefined;
    const input = pieced(case.source, &buffer, &header_pieces, 8);
    const nul = std.mem.findScalar(u8, input, 0);
    const parsed = object.parseHeader(input) catch |err| {
        if (nul) |at| try testing.expect(!isSpelling(input[0..at])) else try testing.expectEqual(error.MissingHeaderTerminator, err);
        return;
    };
    // What it took is the one spelling of what it read, up to the first NUL.
    try testing.expectEqual(nul.? + 1, parsed.len);
    try testing.expect(isSpelling(input[0..nul.?]));
    var spelled: [48]u8 = undefined;
    const want = try std.fmt.bufPrint(&spelled, "{s} {d}\x00", .{ parsed.header.type.name(), parsed.header.size });
    try testing.expectEqualStrings(want, input[0..parsed.len]);
}

test "property: a loose header is accepted exactly when it is the one spelling of a header" {
    try shakedown.check(testing.allocator, {}, anyHeader, .{ .cases = 20000, .seed = 0x0b1 });
}

// Mode.parse: "`get_mode` reads octal digits, at least one and as many as
// there are, wrapping as C's `unsigned int` does, and `canon_mode` folds the
// value to one of the five. Anything but an octal digit is error.InvalidMode."
// Mode.text: "no leading zero".

/// git's `canon_mode` (cache.h), on the `S_IF*` bits.
fn canonMode(value: u32) Mode {
    const S_IFMT = 0o170000;
    return switch (value & S_IFMT) {
        0o100000 => if (value & 0o100 != 0) .exec else .file, // S_ISREG: S_IXUSR decides
        0o120000 => .symlink, // S_ISLNK
        0o040000 => .tree, // S_ISDIR
        else => .gitlink,
    };
}

const mode_pieces = [_][]const u8{ "0", "1", "4", "6", "7", "00", "100644", "100755", "100664", "40000", "040000", "120000", "160000", "8", "9", "x", "-", "+", " " };

fn anyMode(_: void, case: *shakedown.Case) !void {
    var buffer: [40]u8 = undefined;
    const text = pieced(case.source, &buffer, &mode_pieces, 7);
    var octal = text.len != 0;
    for (text) |c| octal = octal and c >= '0' and c <= '7';
    const mode = Mode.parse(text) catch |err| {
        try testing.expectEqual(error.InvalidMode, err);
        try testing.expect(!octal);
        return;
    };
    try testing.expect(octal);
    // The value modulo 2^32: digits before the last eleven add multiples of 8^11 = 2^33.
    const tail = text[text.len - @min(text.len, 11) ..];
    const value: u32 = @truncate(try std.fmt.parseInt(u64, tail, 8));
    try testing.expectEqual(canonMode(value), mode);

    // Each mode's text has no leading zero and reads back as itself.
    const m = gen.enumValue(case.source, Mode);
    var text_buffer: [6]u8 = undefined;
    const written = m.text(&text_buffer);
    try testing.expect(written[0] != '0');
    try testing.expectEqual(@as(u64, m.raw()), try std.fmt.parseInt(u64, written, 8));
    try testing.expectEqual(m, try Mode.parse(written));
}

test "property: a tree mode reads as git's get_mode and canon_mode, and each mode's text reads back" {
    try shakedown.check(testing.allocator, {}, anyMode, .{ .cases = 20000, .seed = 0x0b2 });
}

// Signature.parse: "The name ends at the last non-space before the first
// `<`, the email at the first `>` after it, and the date starts after the
// last `>`. A line whose date or zone is missing or malformed is a person
// with no date." Signature.write: refuses what "cannot be read back".

const ident_pieces = [_][]const u8{ "Ada", "a@b", " ", "  ", "\t", "\r", "\x0b", "<", ">", "\n", "x", "Lovelace", "-", "+", "0", "1700000000", "+0130", "-0500" };

/// git's `isspace` (ctype.c's GIT_SPACE: tab, newline, carriage return and
/// space; not C's vertical tab or form feed), as `split_ident_line` trims.
fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn anyIdentLine(_: void, case: *shakedown.Case) !void {
    var buffer: [96]u8 = undefined;
    var len: usize = 0;
    const head = pieced(case.source, &buffer, &ident_pieces, 6);
    len = head.len;
    // A date and zone as git writes them, after the line's last `>`, or not.
    const dated = gen.boolean(case.source);
    const secs = gen.intRange(case.source, i64, -(1 << 40), 1 << 40);
    const minutes = gen.intRange(case.source, i16, -(99 * 60 + 59), 99 * 60 + 59);
    if (dated) {
        const abs = @abs(minutes);
        const tail = try std.fmt.bufPrint(buffer[len..], "> {d} {c}{d:0>2}{d:0>2}", .{ secs, @as(u8, if (minutes < 0) '-' else '+'), abs / 60, abs % 60 });
        len += tail.len;
    }
    const line = buffer[0..len];

    const lt = std.mem.findScalar(u8, line, '<');
    const gt = if (lt) |at| std.mem.findScalarPos(u8, line, at, '>') else null;
    const sig = Signature.parse(line) catch |err| {
        try testing.expectEqual(error.MalformedSignature, err);
        try testing.expect(lt == null or gt == null);
        return;
    };
    try testing.expect(lt != null and gt != null);
    var name_end = lt.?;
    while (name_end > 0 and space(line[name_end - 1])) name_end -= 1;
    try testing.expectEqualStrings(line[0..name_end], sig.name);
    try testing.expectEqualStrings(line[lt.? + 1 .. gt.?], sig.email);
    if (dated) {
        // The date after the last `>` is the one appended.
        try testing.expectEqual(secs, sig.when_secs);
        try testing.expectEqual(minutes, sig.offset_minutes);
    } else if (std.mem.findScalarLast(u8, line, '>')) |last| {
        // No digits after the last `>`: a person with no date.
        var at = last + 1;
        while (at < line.len and space(line[at])) at += 1;
        if (at < line.len and line[at] == '-') at += 1;
        if (at == line.len or !std.ascii.isDigit(line[at])) {
            try testing.expectEqual(@as(i64, 0), sig.when_secs);
            try testing.expectEqual(@as(i16, 0), sig.offset_minutes);
        }
    }
}

test "property: an ident line splits where git's split_ident_line splits it" {
    try shakedown.check(testing.allocator, {}, anyIdentLine, .{ .cases = 20000, .seed = 0x0b3 });
}

const person_pieces = [_][]const u8{ "Ada", "a@b", " ", "\t", "\r", "\x0b", "<", ">", "\n", "x", "", "é" };

fn anySignatureWritten(_: void, case: *shakedown.Case) !void {
    var name_buffer: [24]u8 = undefined;
    var email_buffer: [24]u8 = undefined;
    const sig: Signature = .{
        .name = pieced(case.source, &name_buffer, &person_pieces, 4),
        .email = pieced(case.source, &email_buffer, &person_pieces, 4),
        .when_secs = switch (gen.intRange(case.source, u2, 0, 3)) {
            0 => std.math.minInt(i64),
            1 => std.math.maxInt(i64),
            else => gen.int(case.source, i64),
        },
        .offset_minutes = gen.int(case.source, i16),
    };
    var out: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    sig.write(&w) catch |err| {
        try testing.expectEqual(error.InvalidSignature, err);
        return;
    };
    // Accepted: it reads back as exactly what was written.
    const back = try Signature.parse(w.buffered());
    try testing.expectEqualStrings(sig.name, back.name);
    try testing.expectEqualStrings(sig.email, back.email);
    try testing.expectEqual(sig.when_secs, back.when_secs);
    try testing.expectEqual(sig.offset_minutes, back.offset_minutes);
}

test "property: an ident write accepts reads back as itself" {
    try shakedown.check(testing.allocator, {}, anySignatureWritten, .{ .cases = 20000, .seed = 0x0b4 });
}

// Tree.Iterator: "A walk over the entries, in the order the object holds
// them"; TruncatedTree "An entry ran off the end of the object".

const tree_modes = [_]struct { text: []const u8, mode: ?Mode }{
    .{ .text = "100644", .mode = .file },   .{ .text = "100755", .mode = .exec },    .{ .text = "100664", .mode = .file },
    .{ .text = "40000", .mode = .tree },    .{ .text = "040000", .mode = .tree },    .{ .text = "120000", .mode = .symlink },
    .{ .text = "160000", .mode = .gitlink }, .{ .text = "0", .mode = .gitlink },     .{ .text = "", .mode = null },
    .{ .text = "10064x", .mode = null },    .{ .text = "-1", .mode = null },
};
const name_pieces = [_][]const u8{ "a", "b.c", " ", "/", "..", "é", "\xff", "-", "A" };

const kinds = [_]hash.Kind{ .sha1, .sha256 };

const Drawn = struct { mode_text: []const u8, mode: ?Mode, name: []const u8, raw: []const u8, start: usize, end: usize };

fn anyTree(_: void, case: *shakedown.Case) !void {
    const kind = gen.oneOf(case.source, hash.Kind, &kinds);
    var bytes: [512]u8 = undefined;
    var names: [6][16]u8 = undefined;
    var drawn: [6]Drawn = undefined;
    var len: usize = 0;
    const n = gen.intRange(case.source, usize, 0, drawn.len);
    // Written by hand, as the doc spells an entry: `<octal mode> SP <name> NUL <raw hash>`.
    for (drawn[0..n], names[0..n]) |*d, *name_buffer| {
        const m = gen.oneOf(case.source, @TypeOf(tree_modes[0]), &tree_modes);
        const name = pieced(case.source, name_buffer, &name_pieces, 3);
        const start = len;
        @memcpy(bytes[len..][0..m.text.len], m.text);
        len += m.text.len;
        bytes[len] = ' ';
        len += 1;
        @memcpy(bytes[len..][0..name.len], name);
        len += name.len;
        bytes[len] = 0;
        len += 1;
        const raw = bytes[len..][0..kind.rawLen()];
        case.source.bytes(raw);
        len += raw.len;
        d.* = .{ .mode_text = m.text, .mode = m.mode, .name = name, .raw = raw, .start = start, .end = len };
    }
    // Cut anywhere, the end among them.
    const cut = gen.intRange(case.source, usize, 0, len);
    var it = Tree.parse(kind, bytes[0..cut]).iterate();
    for (drawn[0..n]) |d| {
        if (d.start == cut) break;
        if (d.end > cut) {
            // An entry cut short is refused; with a good mode and name, as truncated.
            const err = if (it.next()) |_| return error.TestUnexpectedResult else |e| e;
            if (d.mode != null and d.name.len != 0) try testing.expectEqual(error.TruncatedTree, err);
            return;
        }
        if (d.mode == null) return testing.expectError(error.InvalidMode, it.next());
        if (d.name.len == 0) return testing.expectError(error.InvalidEntryName, it.next());
        const entry = (try it.next()).?;
        try testing.expectEqual(d.mode.?, entry.mode);
        try testing.expectEqualStrings(d.name, entry.name);
        try testing.expectEqualSlices(u8, d.raw, entry.oid.raw());
    }
    try testing.expectEqual(null, try it.next());
}

test "property: a tree's entries come back in the object's order, and a cut entry is refused after the whole ones" {
    try shakedown.check(testing.allocator, {}, anyTree, .{ .cases = 20000, .seed = 0x0b5 });
}

// Tree.Builder: "Entries may be added in any order; `write` sorts them by
// git's rule, which is the name for a blob and the name with `/` appended
// for a subtree"; a duplicate is DuplicateEntry.

fn sortKey(e: Tree.Entry, buffer: *[24]u8) []const u8 {
    @memcpy(buffer[0..e.name.len], e.name);
    if (e.mode != .tree) return buffer[0..e.name.len];
    buffer[e.name.len] = '/';
    return buffer[0 .. e.name.len + 1];
}

fn anyBuiltTree(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    const kind = gen.oneOf(case.source, hash.Kind, &kinds);
    var builder: Tree.Builder = .init(gpa, kind);
    defer builder.deinit();
    var names: [8][16]u8 = undefined;
    var added: [8]Tree.Entry = undefined;
    var count: usize = 0;
    for (&names) |*name_buffer| {
        if (!gen.boolean(case.source)) break;
        const name = pieced(case.source, name_buffer, &.{ "a", "b", ".", "c", "-", "0", "a.c" }, 3);
        const mode = gen.enumValue(case.source, Mode);
        var raw: [32]u8 = undefined;
        case.source.bytes(raw[0..kind.rawLen()]);
        const oid = hash.Oid.fromCut(kind, raw[0..kind.rawLen()]);
        var duplicate = false;
        for (added[0..count]) |e| duplicate = duplicate or std.mem.eql(u8, e.name, name);
        const bad = name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
        builder.add(mode, name, oid) catch |err| {
            try testing.expectEqual(if (bad) error.InvalidEntryName else error.DuplicateEntry, err);
            try testing.expect(bad or duplicate);
            continue;
        };
        try testing.expect(!bad and !duplicate);
        added[count] = .{ .mode = mode, .name = name, .oid = oid };
        count += 1;
    }
    const bytes = try builder.build();
    defer gpa.free(bytes);
    const tree = Tree.parse(kind, bytes);
    // Each added entry once, and found by its name.
    try testing.expectEqual(count, try tree.count());
    for (added[0..count]) |e| {
        const found = (try tree.find(e.name)).?;
        try testing.expectEqual(e.mode, found.mode);
        try testing.expect(found.oid.eql(e.oid));
    }
    // In git's order, strictly: no two keys equal.
    var it = tree.iterate();
    var previous: [24]u8 = undefined;
    var previous_len: ?usize = null;
    while (try it.next()) |entry| {
        var key_buffer: [24]u8 = undefined;
        const key = sortKey(entry, &key_buffer);
        if (previous_len) |l| try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, previous[0..l], key));
        @memcpy(previous[0..key.len], key);
        previous_len = key.len;
    }
}

test "property: a built tree holds each entry added once, sorted by git's key" {
    try shakedown.check(testing.allocator, {}, anyBuiltTree, .{ .cases = 20000, .seed = 0x0b6 });
}
