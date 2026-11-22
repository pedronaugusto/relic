//! An iconv measured into text, and read back: how tools/encodings.zig holds
//! relic to a platform's git whose iconv it cannot run where the tables are
//! written (designs/relic.md §14). Git for Windows' own libiconv-2.dll, of
//! the held PortableGit, is measured by a test on every Windows run
//! (src/testing/encoding.zig) and held to the record committed at
//! tools/git-for-windows-iconv.txt, which the Mac that writes the tables
//! reads; a record that differs fails the test with the one measured.
//!
//! A record names each label with the table its iconv converts it by, or as
//! refused (its iconv_open refuses the name either way). A table states
//! every sequence and character the generator asks about (`Table.covers`)
//! where the iconv differs from a default: a single byte or character is
//! refused unless stated, and a longer sequence, or two characters, reads
//! or writes as its parts do one by one (refused if any part is) unless
//! stated. Consecutive keys that read or write as consecutive values are
//! one line.
//!
//! A record is one or more parts, each measured alone (a test on Windows
//! measures one part, within a test's time), each its own `format` line on:
//!
//! ```
//! format 1
//! source <file> <sha256>          what the iconv came from
//! library <file> <sha256>         the iconv itself
//! table <n> plain|euc_jp|gb18030 [pairs] [wide]
//! m <byte> ...                    the bytes after which marks were measured
//! r <len> <first> <last> <cp>...|-|_   sequences of len bytes, read as cp, cp+1, ... (_: as nothing)
//! g <first> <last> <cp>|-         GB18030's four-byte sequences, by their index
//! w <first> <last> <bytes>        characters, written as bytes, bytes+1, ...
//! G <first> <last> <index>        characters, written as GB18030's four bytes
//! p <cp> <cp> <bytes>|-           two characters
//! end
//! label <label> <n>|refused
//! ```
//! Numbers are hexadecimal; sequences and bytes are big-endian numbers. A
//! table measures characters past the Basic Multilingual Plane only if
//! `wide`, and two characters only if `pairs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const format = 1;

/// iconv_open and iconv, of the library linked or of a DLL.
pub const Iconv = struct {
    open: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    convert: *const fn (*anyopaque, *?[*]u8, *usize, *?[*]u8, *usize) callconv(.c) usize,
};

const iconv_failed: usize = std.math.maxInt(usize);

/// A label's decoder, to UTF-8, and encoder, from UTF-8.
pub const Converter = struct {
    iconv: Iconv,
    decoder: *anyopaque,
    encoder: *anyopaque,

    /// Null where the iconv takes the label neither way or only one way.
    pub fn open(iconv: Iconv, label: []const u8) ?Converter {
        const decoder = openOne(iconv, "UTF-8", label) orelse return null;
        const encoder = openOne(iconv, label, "UTF-8") orelse return null;
        return .{ .iconv = iconv, .decoder = decoder, .encoder = encoder };
    }

    /// `bytes` read whole, in UTF-8, or null where the iconv stops.
    pub fn read(c: Converter, bytes: []const u8, out: []u8) ?[]const u8 {
        return run(c.iconv, c.decoder, bytes, out);
    }

    /// `utf8` written whole, or null where the iconv stops.
    pub fn write(c: Converter, utf8: []const u8, out: []u8) ?[]const u8 {
        return run(c.iconv, c.encoder, utf8, out);
    }
};

fn openOne(iconv: Iconv, to: []const u8, from: []const u8) ?*anyopaque {
    var t: [64:0]u8 = @splat(0);
    var f: [64:0]u8 = @splat(0);
    if (to.len >= t.len or from.len >= f.len) return null;
    @memcpy(t[0..to.len], to);
    @memcpy(f[0..from.len], from);
    const cd = iconv.open(&t, &f) orelse return null;
    if (@intFromPtr(cd) == iconv_failed) return null;
    return cd;
}

/// `in` whole through `cd` into `out`, from its initial state, or null where it stops.
fn run(iconv: Iconv, cd: *anyopaque, in: []const u8, out: []u8) ?[]const u8 {
    var no_in: ?[*]u8 = null;
    var no_len: usize = 0;
    var no_out: ?[*]u8 = null;
    var no_out_len: usize = 0;
    _ = iconv.convert(cd, &no_in, &no_len, &no_out, &no_out_len);
    var copy: [32]u8 = undefined;
    if (in.len > copy.len) return null;
    @memcpy(copy[0..in.len], in);
    var ip: ?[*]u8 = &copy;
    var il = in.len;
    var op: ?[*]u8 = out.ptr;
    var ol = out.len;
    if (iconv.convert(cd, &ip, &il, &op, &ol) == iconv_failed) return null;
    if (iconv.convert(cd, &no_in, &no_len, &op, &ol) == iconv_failed) return null;
    if (il != 0) return null;
    return out[0 .. out.len - ol];
}

const win32 = struct {
    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    /// What the DLL loads is looked for in its own directory first.
    const load_with_altered_search_path: u32 = 0x8;
};

/// The iconv a DLL at the absolute `path` exports, as GNU libiconv names it
/// (`libiconv_open`, `libiconv`) or as iconv.h does; on Windows.
pub fn dllIconv(a: Allocator, path: []const u8) !Iconv {
    if (comptime @import("builtin").os.tag == .windows) {
        const backslashed = try a.dupe(u8, path);
        std.mem.replaceScalar(u8, backslashed, '/', '\\');
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, backslashed);
        const module = win32.LoadLibraryExW(wide, null, win32.load_with_altered_search_path) orelse return error.DllNotLoaded;
        const open = win32.GetProcAddress(module, "libiconv_open") orelse win32.GetProcAddress(module, "iconv_open") orelse return error.NoIconvOpen;
        const convert = win32.GetProcAddress(module, "libiconv") orelse win32.GetProcAddress(module, "iconv") orelse return error.NoIconv;
        return .{ .open = @ptrCast(@alignCast(open)), .convert = @ptrCast(@alignCast(convert)) };
    } else return error.WindowsOnly;
}

/// The sequences past one and two bytes an encoding is measured over.
pub const Space = enum { plain, euc_jp, gb18030 };

/// A mark, after which the composing encodings' letters are measured.
pub fn isMark(cp: u21) bool {
    return (cp >= 0x0300 and cp < 0x0370) or (cp >= 0x0591 and cp < 0x05c8);
}

/// Two characters are measured where the first is below this and the
/// second a mark, or a tone or sound mark of JIS X 0213's pairs.
const pair_below: u21 = 0x3100;

fn pairSecond(cp: u21) bool {
    return isMark(cp) or cp == 0x02e5 or cp == 0x02e9 or cp == 0x309a;
}

/// Every second character of a pair measured, in order.
const pair_seconds = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const u21 = &.{};
    for (0..pair_below) |cp| if (pairSecond(cp)) {
        list = list ++ .{@as(u21, cp)};
    };
    break :blk list;
};

/// A sequence of up to four bytes as one number: its length, then its value.
fn pack(bytes: []const u8) u64 {
    return (@as(u64, bytes.len) << 32) | std.mem.readVarInt(u32, bytes, .big);
}

fn unpack(key: u64, buf: *[4]u8) []const u8 {
    const len: usize = @intCast(key >> 32);
    std.mem.writeInt(u32, buf, @truncate(key), .big);
    return buf[4 - len ..];
}

fn inA1Fe(b: u8) bool {
    return b >= 0xa1 and b <= 0xfe;
}

/// GB18030's four-byte form: 81–FE, 30–39, 81–FE, 30–39.
fn gbForm(bytes: []const u8) bool {
    return bytes.len == 4 and bytes[0] >= 0x81 and bytes[0] <= 0xfe and bytes[1] >= 0x30 and bytes[1] <= 0x39 and
        bytes[2] >= 0x81 and bytes[2] <= 0xfe and bytes[3] >= 0x30 and bytes[3] <= 0x39;
}

fn gbIndex(bytes: []const u8) u32 {
    return ((@as(u32, bytes[0] - 0x81) * 10 + (bytes[1] - 0x30)) * 126 + (bytes[2] - 0x81)) * 10 + (bytes[3] - 0x30);
}

fn gbBytes(index: u32) [4]u8 {
    return .{ @intCast(0x81 + index / 12600), @intCast(0x30 + index / 1260 % 10), @intCast(0x81 + index / 10 % 126), @intCast(0x30 + index % 10) };
}

/// Every sequence measured, shortest first: each byte; two bytes from each
/// lead past ASCII; EUC-JP's three of JIS X 0212 and GB18030's four; and
/// after each byte but NUL, up to three of `marks`.
fn keys(a: Allocator, space: Space, marks: *const [256]bool) ![]u64 {
    var list: std.ArrayList(u64) = .empty;
    for (0..256) |b0| try list.append(a, pack(&.{@intCast(b0)}));
    for (0x80..256) |b0| for (0..256) |b1| try list.append(a, pack(&.{ @intCast(b0), @intCast(b1) }));
    if (space == .euc_jp) for (0xa1..0xff) |b1| for (0xa1..0xff) |b2| try list.append(a, pack(&.{ 0x8f, @intCast(b1), @intCast(b2) }));
    if (space == .gb18030) for (0x81..0xff) |b0| for (0x30..0x3a) |b1| for (0x81..0xff) |b2| for (0x30..0x3a) |b3| {
        try list.append(a, pack(&.{ @intCast(b0), @intCast(b1), @intCast(b2), @intCast(b3) }));
    };
    var ms: std.ArrayList(u8) = .empty;
    for (0x80..256) |b| if (marks[b]) try ms.append(a, @intCast(b));
    for (1..256) |b0_| for (ms.items) |m1| {
        const b0: u8 = @intCast(b0_);
        // Two bytes from a lead past ASCII are measured already.
        if (b0 < 0x80) try list.append(a, pack(&.{ b0, m1 }));
        for (ms.items) |m2| {
            // And EUC-JP's three.
            if (!(space == .euc_jp and b0 == 0x8f and inA1Fe(m1) and inA1Fe(m2))) try list.append(a, pack(&.{ b0, m1, m2 }));
            for (ms.items) |m3| try list.append(a, pack(&.{ b0, m1, m2, m3 }));
        }
    };
    return list.items;
}

/// Characters, in UTF-8: one sequence's reading, up to four.
const Text = struct {
    len: u8 = 0,
    bytes: [16]u8 = undefined,

    fn of(s: []const u8) !Text {
        var t: Text = .{};
        if (s.len > t.bytes.len) return error.ReadsAsMore;
        t.len = @intCast(s.len);
        @memcpy(t.bytes[0..s.len], s);
        return t;
    }

    fn slice(t: *const Text) []const u8 {
        return t.bytes[0..t.len];
    }
};

/// One character's or two's bytes, up to eight.
const Bytes = struct {
    len: u8 = 0,
    bytes: [8]u8 = undefined,

    fn of(s: []const u8) !Bytes {
        var b: Bytes = .{};
        if (s.len > b.bytes.len) return error.WritesAsMore;
        b.len = @intCast(s.len);
        @memcpy(b.bytes[0..s.len], s);
        return b;
    }

    fn slice(b: *const Bytes) []const u8 {
        return b.bytes[0..b.len];
    }

    fn value(b: *const Bytes) u64 {
        return std.mem.readVarInt(u64, b.slice(), .big);
    }

    fn ofValue(len: usize, v: u64) Bytes {
        var b: Bytes = .{ .len = @intCast(len) };
        var all: [8]u8 = undefined;
        std.mem.writeInt(u64, &all, v, .big);
        @memcpy(b.bytes[0..len], all[8 - len ..]);
        return b;
    }
};

fn concat(comptime T: type, parts: []const ?T) ?T {
    var out: T = .{};
    for (parts) |p| {
        const s = (p orelse return null).slice();
        if (out.len + s.len > out.bytes.len) return null;
        @memcpy(out.bytes[out.len..][0..s.len], s);
        out.len += @intCast(s.len);
    }
    return out;
}

fn same(comptime T: type, x: ?T, y: ?T) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?.slice(), y.?.slice());
}

/// The single character `t` holds, or null for none or more.
fn single(t: Text) ?u21 {
    const s = t.slice();
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n != s.len) return null;
    return std.unicode.utf8Decode(s) catch null;
}

fn utf8Into(buf: *[8]u8, cps: []const u21) []const u8 {
    var n: usize = 0;
    // unreachable: at most two scalar values of four bytes each
    for (cps) |cp| n += std.unicode.utf8Encode(cp, buf[n..]) catch unreachable;
    return buf[0..n];
}

/// The last character measured: the Basic Multilingual Plane's, or every
/// plane's for a `wide` table.
fn lastWritten(wide: bool) u21 {
    return if (wide) 0x10ffff else 0xffff;
}

fn isScalar(cp: u21) bool {
    return cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
}

/// A line's run being built: keys of one kind and length, consecutive, with
/// values consecutive too.
const Run = struct {
    kind: u8,
    len: usize,
    first: u64,
    last: u64,
    /// The first key's value; null for refusals.
    value: ?u64,
    /// A reading of more than one character, which is a line alone.
    text: ?Text = null,
    /// A writing's byte count.
    width: usize = 0,

    fn extends(r: Run, next: Run) bool {
        if (r.kind != next.kind or r.len != next.len or r.width != next.width) return false;
        if (r.text != null or next.text != null) return false;
        if (next.first != r.last + 1) return false;
        if (r.value == null or next.value == null) return r.value == null and next.value == null;
        return next.value.? == r.value.? + (next.first - r.first);
    }

    fn emit(r: Run, w: *Io.Writer) !void {
        switch (r.kind) {
            'r' => try w.print("r {d} {x} {x}", .{ r.len, r.first, r.last }),
            else => try w.print("{c} {x} {x}", .{ r.kind, r.first, r.last }),
        }
        if (r.text) |t| {
            // A reading of no characters, as of a shift alone.
            if (t.len == 0) try w.writeAll(" _");
            var view = std.unicode.Utf8View.initUnchecked(t.slice()).iterator();
            while (view.nextCodepoint()) |cp| try w.print(" {x}", .{cp});
        } else if (r.value) |v| {
            if (r.kind == 'w') {
                try w.print(" {x:0>[1]}", .{ v, r.width * 2 });
            } else try w.print(" {x}", .{v});
        } else try w.writeAll(" -");
        try w.writeByte('\n');
    }
};

const Lines = struct {
    w: *Io.Writer,
    run: ?Run = null,

    fn add(l: *Lines, r: Run) !void {
        if (l.run) |*prev| if (prev.extends(r)) {
            prev.last = r.first;
            return;
        };
        try l.flush();
        l.run = r;
    }

    fn flush(l: *Lines) !void {
        if (l.run) |r| try r.emit(l.w);
        l.run = null;
    }
};

/// A reading's run: one character, as a value; several, alone; none, a refusal.
fn readRun(bytes: []const u8, got: ?Text) Run {
    const gb = gbForm(bytes);
    const key: u64 = if (gb) gbIndex(bytes) else std.mem.readVarInt(u32, bytes, .big);
    var r: Run = .{ .kind = if (gb) 'g' else 'r', .len = bytes.len, .first = key, .last = key, .value = null };
    if (got) |t| if (single(t)) |cp| {
        r.value = cp;
    } else {
        r.value = 0;
        r.text = t;
    };
    return r;
}

/// The table of `c`, as `Table` reads it: `marks` are bytes after which
/// letters are measured besides those `c` reads as a mark itself.
pub fn recordTable(a: Allocator, w: *Io.Writer, c: Converter, l: Label) !void {
    const space = l.space;
    const extra_marks = &l.marks;
    var marks: [256]bool = @splat(false);
    var buf: [64]u8 = undefined;
    var singles: [256]?Text = @splat(null);
    for (0..256) |b| if (c.read(&.{@intCast(b)}, &buf)) |s| {
        singles[b] = try Text.of(s);
    };
    for (0x80..256) |b| {
        const own = if (singles[b]) |t| if (single(t)) |cp| isMark(cp) else false else false;
        marks[b] = own or extra_marks[b];
    }
    var any_mark = false;
    for (marks) |m| any_mark = any_mark or m;
    if (any_mark) {
        try w.writeAll("m");
        for (marks, 0..) |m, b| if (m) try w.print(" {x}", .{b});
        try w.writeByte('\n');
    }
    var lines: Lines = .{ .w = w };
    for (try keys(a, space, &marks)) |key| {
        var kb: [4]u8 = undefined;
        const bytes = unpack(key, &kb);
        const got: ?Text = if (c.read(bytes, &buf)) |s| try Text.of(s) else null;
        if (bytes.len == 1) {
            if (got != null) try lines.add(readRun(bytes, got));
            continue;
        }
        var parts: [4]?Text = undefined;
        for (bytes, 0..) |b, i| parts[i] = singles[b];
        if (!same(Text, got, concat(Text, parts[0..bytes.len]))) try lines.add(readRun(bytes, got));
    }
    try lines.flush();

    var writes: [pair_below]?Bytes = @splat(null);
    var cp: u21 = 0;
    while (cp <= lastWritten(l.wide)) : (cp += 1) {
        if (!isScalar(cp)) continue;
        var in: [8]u8 = undefined;
        const s = c.write(utf8Into(&in, &.{cp}), &buf) orelse continue;
        const got = try Bytes.of(s);
        if (cp < pair_below) writes[cp] = got;
        if (gbForm(s)) {
            try lines.add(.{ .kind = 'G', .len = 0, .first = cp, .last = cp, .value = gbIndex(s) });
        } else try lines.add(.{ .kind = 'w', .len = 0, .width = s.len, .first = cp, .last = cp, .value = got.value() });
    }
    try lines.flush();

    if (l.pairs) for (0..pair_below) |first_| for (pair_seconds) |second| {
        const first: u21 = @intCast(first_);
        var in: [8]u8 = undefined;
        const got: ?Bytes = if (c.write(utf8Into(&in, &.{ first, second }), &buf)) |s| try Bytes.of(s) else null;
        if (same(Bytes, got, concat(Bytes, &.{ writes[first], writes[second] }))) continue;
        if (got) |g| {
            try w.print("p {x} {x} {x:0>[3]}\n", .{ first, second, g.value(), g.len * 2 });
        } else try w.print("p {x} {x} -\n", .{ first, second });
    };
}

/// A label to measure: its sequences, whether pairs and characters past
/// the Basic Multilingual Plane are measured, and the bytes after which to
/// measure marks besides its own (the standard's, which another iconv may
/// read as marks).
pub const Label = struct {
    label: []const u8,
    /// The part of the record it is in: every label of one encoding in one.
    part: u8 = 0,
    space: Space,
    pairs: bool = false,
    wide: bool = false,
    marks: [256]bool = @splat(false),
};

/// An encoding the standard reads sequence by sequence, by its tag in
/// xenoglyph: not the UTFs, the replacement and x-user-defined, and not
/// ISO-2022-JP, whose escapes change how every later byte reads.
pub fn tabled(tag: []const u8) bool {
    for ([_][]const u8{ "utf_8", "utf_16le", "utf_16be", "replacement", "x_user_defined", "iso_2022_jp" }) |t| {
        if (std.mem.eql(u8, t, tag)) return false;
    }
    return true;
}

/// Every label of the standard's `xg` (xenoglyph.encoding) that is tabled,
/// with what each is measured over: EUC-JP's and GB18030's longer
/// sequences; two characters for Big5 (HKSCS's Ê̄ and its kin) and the
/// composing windows-1255 and -1258; characters past the Basic
/// Multilingual Plane for Big5 and GB18030, which write them; and marks
/// after the bytes `legacy` (src/text/legacy.zig) reads as one.
pub fn labels(a: Allocator, comptime xg: type, comptime legacy: type) ![]Label {
    var list: std.ArrayList(Label) = .empty;
    var encodings: std.ArrayList(xg.Encoding) = .empty;
    for (xg.labels()) |l| {
        const tag = @tagName(l.encoding);
        if (!tabled(tag)) continue;
        const big5 = l.encoding == .big5;
        const ordinal = std.mem.findScalar(xg.Encoding, encodings.items, l.encoding) orelse blk: {
            try encodings.append(a, l.encoding);
            break :blk encodings.items.len - 1;
        };
        var marks: [256]bool = @splat(false);
        const standard: legacy.Legacy = .{ .encoding = l.encoding };
        for (0x80..256) |b| {
            var at: usize = 0;
            var cps: [2]u21 = undefined;
            const n = legacy.decodeAt(&standard, &.{@intCast(b)}, &at, &cps) orelse continue;
            marks[b] = n > 0 and isMark(cps[0]);
        }
        try list.append(a, .{
            .label = l.label,
            // GB18030's four bytes and every plane, and Big5's every plane
            // and pairs, are each a part's time: the rest share the others.
            .part = if (l.encoding == .gb18030) 0 else if (big5) 1 else @intCast(2 + ordinal % (part_count - 2)),
            .space = if (l.encoding == .euc_jp) .euc_jp else if (l.encoding == .gb18030) .gb18030 else .plain,
            .pairs = big5 or l.encoding == .windows_1255 or l.encoding == .windows_1258,
            .wide = big5 or l.encoding == .gb18030,
            .marks = marks,
        });
    }
    return list.items;
}

/// Measures each of `labels` through `iconv` into `w`, a table once for
/// the labels that convert alike, then reads the record back and holds it
/// to the iconv over everything it states.
pub fn record(a: Allocator, w: *Io.Writer, iconv: Iconv, source: [2][]const u8, library: [2][]const u8, to_measure: []const Label) !void {
    var whole: std.ArrayList(u8) = .empty;
    for (0..part_count) |part| try whole.appendSlice(a, try measurePart(a, iconv, source, library, to_measure, @intCast(part)));
    const text = whole.items;
    const read_back = try Recorded.parse(a, text);
    for (to_measure) |l| {
        const t = read_back.labels.get(l.label) orelse return error.LabelLost;
        const c = Converter.open(iconv, l.label);
        if ((t == null) != (c == null)) return error.RecordDiffers;
        if (c) |conv| try t.?.holdTo(a, conv);
    }
    try w.writeAll(text);
}

/// The parts of a record, each measured alone.
pub const part_count = 6;

/// Part `part` of the record of `all` through `iconv`, unchecked.
pub fn measurePart(a: Allocator, iconv: Iconv, source: [2][]const u8, library: [2][]const u8, all: []const Label, part: u8) ![]const u8 {
    var mine: std.ArrayList(Label) = .empty;
    for (all) |l| if (l.part == part) try mine.append(a, l);
    return measure(a, iconv, source, library, mine.items);
}

/// Part `part` of `text`, a record, or null where it has fewer.
pub fn partOf(text: []const u8, part: usize) ?[]const u8 {
    var start: usize = 0;
    var seen: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const end = (std.mem.findScalarPos(u8, text, at, '\n') orelse text.len - 1) + 1;
        if (std.mem.startsWith(u8, text[at..end], "format ")) {
            if (seen == part + 1) return text[start..at];
            if (seen == part) start = at;
            seen += 1;
        }
        at = end;
    }
    return if (seen == part + 1) text[start..] else null;
}

/// One part's record of `to_measure` through `iconv`, unchecked.
pub fn measure(a: Allocator, iconv: Iconv, source: [2][]const u8, library: [2][]const u8, to_measure: []const Label) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const o = &out.writer;
    try o.print("format {d}\nsource {s} {s}\nlibrary {s} {s}\n", .{ format, source[0], source[1], library[0], library[1] });
    var tables: std.StringHashMapUnmanaged(usize) = .empty;
    var named: std.ArrayList(struct { []const u8, ?usize }) = .empty;
    for (to_measure) |l| {
        const c = Converter.open(iconv, l.label) orelse {
            try named.append(a, .{ l.label, null });
            continue;
        };
        var body: Io.Writer.Allocating = .init(a);
        try body.writer.print("{t}{s}{s}\n", .{ l.space, if (l.pairs) " pairs" else "", if (l.wide) " wide" else "" });
        try recordTable(a, &body.writer, c, l);
        const got = try tables.getOrPut(a, body.written());
        if (!got.found_existing) {
            got.value_ptr.* = tables.count() - 1;
            try o.print("table {d} {s}end\n", .{ got.value_ptr.*, body.written() });
        }
        try named.append(a, .{ l.label, got.value_ptr.* });
    }
    for (named.items) |n| if (n[1]) |t| {
        try o.print("label {s} {d}\n", .{ n[0], t });
    } else try o.print("label {s} refused\n", .{n[0]});
    return out.written();
}

/// A record, read.
pub const Recorded = struct {
    source: [2][]const u8,
    library: [2][]const u8,
    /// Each label's table; null where the iconv refuses it.
    labels: std.StringHashMapUnmanaged(?*const Table) = .empty,

    pub fn parse(a: Allocator, text: []const u8) !Recorded {
        var r: Recorded = .{ .source = undefined, .library = undefined };
        var source: ?[2][]const u8 = null;
        var library: ?[2][]const u8 = null;
        var tables: std.ArrayList(*Table) = .empty;
        // The first table of the part being read: each numbers its own from 0.
        var base: usize = 0;
        var current: ?*Table = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            if (line.len == 0) continue;
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = f.next() orelse continue;
            errdefer std.debug.print("record line {d}: {s}\n", .{ number, line });
            if (current) |t| {
                if (std.mem.eql(u8, kind, "end")) {
                    current = null;
                } else try t.parseLine(a, kind, &f);
                continue;
            }
            if (std.mem.eql(u8, kind, "format")) {
                if (try std.fmt.parseInt(u32, f.next() orelse return error.BadRecord, 10) != format) return error.OtherFormat;
                base = tables.items.len;
            } else if (std.mem.eql(u8, kind, "source") or std.mem.eql(u8, kind, "library")) {
                const named: [2][]const u8 = .{ f.next() orelse return error.BadRecord, f.next() orelse return error.BadRecord };
                // Every part's the same.
                const slot = if (kind[0] == 's') &source else &library;
                if (slot.*) |was| if (!std.mem.eql(u8, was[0], named[0]) or !std.mem.eql(u8, was[1], named[1])) return error.BadRecord;
                slot.* = named;
            } else if (std.mem.eql(u8, kind, "table")) {
                if (try std.fmt.parseInt(usize, f.next() orelse return error.BadRecord, 10) != tables.items.len - base) return error.BadRecord;
                const space = std.meta.stringToEnum(Space, f.next() orelse return error.BadRecord) orelse return error.BadRecord;
                const t = try a.create(Table);
                t.* = .{ .space = space };
                while (f.next()) |option| {
                    if (std.mem.eql(u8, option, "pairs")) {
                        t.pairs_measured = true;
                    } else if (std.mem.eql(u8, option, "wide")) {
                        t.wide = true;
                    } else return error.BadRecord;
                }
                try tables.append(a, t);
                current = t;
            } else if (std.mem.eql(u8, kind, "label")) {
                const label = f.next() orelse return error.BadRecord;
                const which = f.next() orelse return error.BadRecord;
                const t: ?*const Table = if (std.mem.eql(u8, which, "refused")) null else blk: {
                    const n = base + try std.fmt.parseInt(usize, which, 10);
                    if (n >= tables.items.len) return error.BadRecord;
                    break :blk tables.items[n];
                };
                if ((try r.labels.fetchPut(a, label, t)) != null) return error.BadRecord;
            } else return error.BadRecord;
        }
        if (current != null) return error.BadRecord;
        r.source = source orelse return error.BadRecord;
        r.library = library orelse return error.BadRecord;
        return r;
    }
};

/// What one iconv reads and writes, over what was measured.
pub const Table = struct {
    space: Space,
    /// Whether two characters were measured.
    pairs_measured: bool = false,
    /// Whether characters past the Basic Multilingual Plane were.
    wide: bool = false,
    marks: [256]bool = @splat(false),
    singles: [256]?Text = @splat(null),
    /// Sequences of two bytes or more that read otherwise than their bytes.
    reads: std.AutoHashMapUnmanaged(u64, ?Text) = .empty,
    writes: std.AutoHashMapUnmanaged(u21, Bytes) = .empty,
    /// Two characters that write otherwise than each alone, first's shifted past the second's.
    pairs: std.AutoHashMapUnmanaged(u64, ?Bytes) = .empty,

    /// Whether `bytes` was measured: what `keys` gives.
    pub fn covers(t: *const Table, bytes: []const u8) bool {
        return switch (bytes.len) {
            1 => true,
            2 => bytes[0] >= 0x80 or (bytes[0] != 0 and t.marks[bytes[1]]),
            3 => (t.space == .euc_jp and bytes[0] == 0x8f and inA1Fe(bytes[1]) and inA1Fe(bytes[2])) or
                (bytes[0] != 0 and t.marks[bytes[1]] and t.marks[bytes[2]]),
            4 => (t.space == .gb18030 and gbForm(bytes)) or
                (bytes[0] != 0 and t.marks[bytes[1]] and t.marks[bytes[2]] and t.marks[bytes[3]]),
            else => false,
        };
    }

    /// What the iconv reads `bytes` as, in UTF-8, into `out`; null where it stops.
    pub fn read(t: *const Table, bytes: []const u8, out: *[64]u8) error{NotMeasured}!?[]const u8 {
        if (!t.covers(bytes)) return error.NotMeasured;
        const got: ?Text = if (bytes.len == 1) t.singles[bytes[0]] else t.reads.get(pack(bytes)) orelse blk: {
            var parts: [4]?Text = undefined;
            for (bytes, 0..) |b, i| parts[i] = t.singles[b];
            break :blk concat(Text, parts[0..bytes.len]);
        };
        const g = got orelse return null;
        @memcpy(out[0..g.len], g.slice());
        return out[0..g.len];
    }

    /// What the iconv writes `cps`, one character or two, as, into `out`; null where it stops.
    pub fn write(t: *const Table, cps: []const u21, out: *[64]u8) error{NotMeasured}!?[]const u8 {
        const got: ?Bytes = switch (cps.len) {
            1 => blk: {
                if (cps[0] > lastWritten(t.wide)) return error.NotMeasured;
                break :blk t.writes.get(cps[0]);
            },
            2 => blk: {
                if (!t.pairs_measured or cps[0] >= pair_below or !pairSecond(cps[1])) return error.NotMeasured;
                break :blk t.pairs.get(pairKey(cps[0], cps[1])) orelse concat(Bytes, &.{ t.writes.get(cps[0]), t.writes.get(cps[1]) });
            },
            else => return error.NotMeasured,
        };
        const g = got orelse return null;
        @memcpy(out[0..g.len], g.slice());
        return out[0..g.len];
    }

    fn pairKey(first: u21, second: u21) u64 {
        return (@as(u64, first) << 21) | second;
    }

    fn parseLine(t: *Table, a: Allocator, kind: []const u8, f: *std.mem.TokenIterator(u8, .scalar)) !void {
        if (std.mem.eql(u8, kind, "m")) {
            while (f.next()) |b| t.marks[try std.fmt.parseInt(u8, b, 16)] = true;
            return;
        }
        if (std.mem.eql(u8, kind, "p")) {
            const first = try std.fmt.parseInt(u21, f.next() orelse return error.BadRecord, 16);
            const second = try std.fmt.parseInt(u21, f.next() orelse return error.BadRecord, 16);
            const bytes = f.next() orelse return error.BadRecord;
            const got: ?Bytes = if (std.mem.eql(u8, bytes, "-")) null else try hexBytes(bytes);
            try t.pairs.put(a, pairKey(first, second), got);
            return;
        }
        const len: usize = if (std.mem.eql(u8, kind, "r")) try std.fmt.parseInt(usize, f.next() orelse return error.BadRecord, 10) else 0;
        const first = try std.fmt.parseInt(u64, f.next() orelse return error.BadRecord, 16);
        const last = try std.fmt.parseInt(u64, f.next() orelse return error.BadRecord, 16);
        if (last < first) return error.BadRecord;
        const value_text = f.next() orelse return error.BadRecord;
        const refused = std.mem.eql(u8, value_text, "-");
        const nothing = std.mem.eql(u8, value_text, "_");
        switch (kind[0]) {
            'r', 'g' => {
                var cps: [4]u21 = undefined;
                var count: usize = 0;
                if (nothing) {
                    if (first != last or f.next() != null) return error.BadRecord;
                } else if (!refused) {
                    cps[0] = try std.fmt.parseInt(u21, value_text, 16);
                    count = 1;
                    while (f.next()) |more| : (count += 1) {
                        if (count == cps.len or first != last) return error.BadRecord;
                        cps[count] = try std.fmt.parseInt(u21, more, 16);
                    }
                }
                var key = first;
                while (key <= last) : (key += 1) {
                    var kb: [4]u8 = undefined;
                    const bytes: []const u8 = if (kind[0] == 'g') blk: {
                        kb = gbBytes(@intCast(key));
                        break :blk &kb;
                    } else blk: {
                        if (len == 0 or len > 4) return error.BadRecord;
                        std.mem.writeInt(u32, &kb, @intCast(key), .big);
                        break :blk kb[4 - len ..];
                    };
                    var got: ?Text = null;
                    if (!refused) {
                        var buf: [8]u8 = undefined;
                        if (nothing) {
                            got = .{};
                        } else if (count == 1) {
                            const cp: u21 = @intCast(cps[0] + (key - first));
                            got = try Text.of(utf8Into(&buf, &.{cp}));
                        } else {
                            var text: Text = .{};
                            for (cps[0..count]) |cp| {
                                const s = utf8Into(&buf, &.{cp});
                                @memcpy(text.bytes[text.len..][0..s.len], s);
                                text.len += @intCast(s.len);
                            }
                            got = text;
                        }
                    }
                    if (bytes.len == 1) {
                        t.singles[bytes[0]] = got;
                    } else try t.reads.put(a, pack(bytes), got);
                }
            },
            'w', 'G' => {
                if (refused or nothing) return error.BadRecord;
                const start: Bytes = if (kind[0] == 'G') try Bytes.of(&gbBytes(try std.fmt.parseInt(u32, value_text, 16))) else try hexBytes(value_text);
                var cp = first;
                while (cp <= last) : (cp += 1) {
                    const got: Bytes = if (kind[0] == 'G')
                        try Bytes.of(&gbBytes(gbIndex(start.slice()) + @as(u32, @intCast(cp - first))))
                    else
                        Bytes.ofValue(start.len, start.value() + (cp - first));
                    try t.writes.put(a, @intCast(cp), got);
                }
            },
            else => return error.BadRecord,
        }
    }

    /// Fails unless the table reads and writes as `c` does over everything measured.
    pub fn holdTo(t: *const Table, a: Allocator, c: Converter) !void {
        var mine: [64]u8 = undefined;
        var theirs: [64]u8 = undefined;
        for (try keys(a, t.space, &t.marks)) |key| {
            var kb: [4]u8 = undefined;
            const bytes = unpack(key, &kb);
            if (!sameSlice(try t.read(bytes, &mine), c.read(bytes, &theirs))) {
                std.debug.print("record: {x} reads otherwise\n", .{bytes});
                return error.RecordDiffers;
            }
        }
        var cp: u21 = 0;
        while (cp <= lastWritten(t.wide)) : (cp += 1) {
            if (!isScalar(cp)) continue;
            var in: [8]u8 = undefined;
            if (!sameSlice(try t.write(&.{cp}, &mine), c.write(utf8Into(&in, &.{cp}), &theirs))) {
                std.debug.print("record: U+{X:0>4} writes otherwise\n", .{cp});
                return error.RecordDiffers;
            }
        }
        if (t.pairs_measured) for (0..pair_below) |first| for (pair_seconds) |second| {
            const cps = [2]u21{ @intCast(first), second };
            var in: [8]u8 = undefined;
            if (!sameSlice(try t.write(&cps, &mine), c.write(utf8Into(&in, &cps), &theirs))) {
                std.debug.print("record: U+{X:0>4} U+{X:0>4} writes otherwise\n", .{ cps[0], cps[1] });
                return error.RecordDiffers;
            }
        };
    }
};

fn sameSlice(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

fn hexBytes(s: []const u8) !Bytes {
    if (s.len % 2 != 0 or s.len == 0) return error.BadRecord;
    var b: Bytes = .{ .len = @intCast(s.len / 2) };
    if (b.len > b.bytes.len) return error.BadRecord;
    _ = try std.fmt.hexToBytes(b.bytes[0..b.len], s);
    return b;
}

//=========================================================================
// A toy iconv, for the tests
//=========================================================================

/// "toy": ASCII; 80 for €; 90 40–4F for U+4E00–U+4E0F, 90 alone or before
/// any other byte refused; C1 for the acute accent, and e then C1 read as é,
/// which is written e C1 ("toy-twin" the same); A with the accent refused as two characters
/// though each writes alone; FF refused. "gb" is GB18030's four bytes for
/// U+10000 on (index 0x2E248 on) up to U+1000F, the rest refused. "none" opens neither way.
const toy = struct {
    var decoder_toy: u8 = 0;
    var encoder_toy: u8 = 0;
    var decoder_gb: u8 = 0;
    var encoder_gb: u8 = 0;

    fn open(to: [*:0]const u8, from: [*:0]const u8) callconv(.c) ?*anyopaque {
        const t = std.mem.span(to);
        const f = std.mem.span(from);
        if (std.mem.eql(u8, t, "UTF-8") and isToy(f)) return &decoder_toy;
        if (isToy(t) and std.mem.eql(u8, f, "UTF-8")) return &encoder_toy;
        if (std.mem.eql(u8, t, "UTF-8") and std.mem.eql(u8, f, "gb")) return &decoder_gb;
        if (std.mem.eql(u8, t, "gb") and std.mem.eql(u8, f, "UTF-8")) return &encoder_gb;
        return @ptrFromInt(iconv_failed);
    }

    fn isToy(name: []const u8) bool {
        return std.mem.eql(u8, name, "toy") or std.mem.eql(u8, name, "toy-twin");
    }

    fn convert(cd: *anyopaque, inbuf: *?[*]u8, inleft: *usize, outbuf: *?[*]u8, outleft: *usize) callconv(.c) usize {
        const in_ptr = inbuf.* orelse return 0;
        const in = in_ptr[0..inleft.*];
        var out: [64]u8 = undefined;
        const got = (if (cd == @as(*anyopaque, &decoder_toy))
            decodeToy(in, &out)
        else if (cd == @as(*anyopaque, &encoder_toy))
            encodeToy(in, &out)
        else if (cd == @as(*anyopaque, &decoder_gb))
            decodeGb(in, &out)
        else
            encodeGb(in, &out)) orelse return iconv_failed;
        if (got.len > outleft.*) return iconv_failed;
        @memcpy(outbuf.*.?[0..got.len], got);
        outbuf.* = outbuf.*.? + got.len;
        outleft.* -= got.len;
        inbuf.* = in_ptr + in.len;
        inleft.* = 0;
        return 0;
    }

    fn decodeToy(in: []const u8, out: *[64]u8) ?[]const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < in.len) : (i += 1) {
            const cp: u21 = switch (in[i]) {
                0...0x7f => if (in[i] == 'e' and i + 1 < in.len and in[i + 1] == 0xc1) blk: {
                    i += 1;
                    break :blk 0xe9;
                } else in[i],
                0x80 => 0x20ac,
                0x90 => blk: {
                    if (i + 1 >= in.len or in[i + 1] < 0x40 or in[i + 1] > 0x4f) return null;
                    i += 1;
                    break :blk 0x4e00 + @as(u21, in[i] - 0x40);
                },
                0xc1 => 0x301,
                else => return null,
            };
            n += std.unicode.utf8Encode(cp, out[n..]) catch return null;
        }
        return out[0..n];
    }

    fn encodeToy(in: []const u8, out: *[64]u8) ?[]const u8 {
        var n: usize = 0;
        var view = (std.unicode.Utf8View.init(in) catch return null).iterator();
        var prev: ?u21 = null;
        while (view.nextCodepoint()) |cp| : (prev = cp) {
            if (cp == 0x301 and prev == 'A') return null;
            switch (cp) {
                0...0x7f => out[n] = @intCast(cp),
                0x20ac => out[n] = 0x80,
                0x4e00...0x4e0f => {
                    out[n] = 0x90;
                    n += 1;
                    out[n] = @intCast(0x40 + cp - 0x4e00);
                },
                0x301 => out[n] = 0xc1,
                0xe9 => {
                    out[n] = 'e';
                    n += 1;
                    out[n] = 0xc1;
                },
                else => return null,
            }
            n += 1;
        }
        return out[0..n];
    }

    fn decodeGb(in: []const u8, out: *[64]u8) ?[]const u8 {
        if (in.len == 1 and in[0] < 0x80) {
            out[0] = in[0];
            return out[0..1];
        }
        if (!gbForm(in)) return null;
        const index = gbIndex(in);
        if (index < 0x2e248 or index > 0x2e248 + 0xf) return null;
        const n = std.unicode.utf8Encode(@intCast(0x10000 + index - 0x2e248), out) catch return null;
        return out[0..n];
    }

    fn encodeGb(in: []const u8, out: *[64]u8) ?[]const u8 {
        var view = (std.unicode.Utf8View.init(in) catch return null).iterator();
        const cp = view.nextCodepoint() orelse return null;
        if (view.nextCodepoint() != null) return null;
        if (cp < 0x80) {
            out[0] = @intCast(cp);
            return out[0..1];
        }
        if (cp < 0x10000 or cp > 0x1000f) return null;
        out[0..4].* = gbBytes(0x2e248 + @as(u32, cp - 0x10000));
        return out[0..4];
    }

    const iconv: Iconv = .{ .open = &open, .convert = &convert };
};

fn toyRecord(a: Allocator) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const no_marks: [256]bool = @splat(false);
    try record(a, &out.writer, toy.iconv, .{ "toy.7z", "00" }, .{ "toy.dll", "11" }, &.{
        .{ .label = "toy", .space = .plain, .pairs = true, .marks = no_marks },
        .{ .label = "toy-twin", .space = .plain, .pairs = true, .marks = no_marks },
        .{ .label = "gb", .part = 1, .space = .gb18030, .wide = true, .marks = no_marks },
        .{ .label = "none", .part = 5, .space = .plain, .marks = no_marks },
    });
    return out.written();
}

test "a record reads back as the iconv reads and writes, over every sequence, character and pair measured, and one label's twin shares its table" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try toyRecord(a);
    const r = try Recorded.parse(a, text);
    try std.testing.expectEqualStrings("toy.7z", r.source[0]);
    try std.testing.expectEqualStrings("11", r.library[1]);
    try std.testing.expectEqual(@as(?*const Table, null), r.labels.get("none").?);
    try std.testing.expectEqual(r.labels.get("toy").?, r.labels.get("toy-twin").?);
    // `record` held the record to the iconv; here, that it would see a difference.
    const t = r.labels.get("toy").?.?;
    try t.holdTo(a, Converter.open(toy.iconv, "toy").?);
    try std.testing.expectError(error.RecordDiffers, t.holdTo(a, Converter.open(toy.iconv, "gb").?));
    try r.labels.get("gb").?.?.holdTo(a, Converter.open(toy.iconv, "gb").?);
    // The toy's measured: C1 is a mark, so letters were measured before it.
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("é", (try t.read("e\xc1", &out)).?);
    try std.testing.expectEqualStrings("a\u{301}", (try t.read("a\xc1", &out)).?);
    try std.testing.expectEqualStrings("\u{4e0f}", (try t.read("\x90\x4f", &out)).?);
    try std.testing.expectEqual(null, try t.read("\x90\x50", &out));
    try std.testing.expectEqual(null, try t.write(&.{ 'A', 0x301 }, &out));
    try std.testing.expectEqualStrings("e\xc1", (try t.write(&.{0xe9}, &out)).?);
    // What was not measured is no answer.
    try std.testing.expectError(error.NotMeasured, t.read("abc", &out));
    try std.testing.expectError(error.NotMeasured, t.read("\x81\x30\x81\x30", &out));
    try std.testing.expectError(error.NotMeasured, t.read("\x8f\xa1\xa1", &out));
    try std.testing.expectError(error.NotMeasured, t.write(&.{ 0x3100, 0x301 }, &out));
    try std.testing.expectError(error.NotMeasured, t.write(&.{ 'A', 'B' }, &out));
    // Past the Basic Multilingual Plane only where wide, two characters only where pairs.
    try std.testing.expectError(error.NotMeasured, t.write(&.{0x10000}, &out));
    const gb = r.labels.get("gb").?.?;
    try std.testing.expectEqualStrings("\x90\x30\x81\x30", (try gb.write(&.{0x10000}, &out)).?);
    try std.testing.expectError(error.NotMeasured, gb.write(&.{ 'e', 0x301 }, &out));
    // Runs: the sixteen CJK characters are one line each way, the GB18030 ones too.
    try std.testing.expect(std.mem.find(u8, text, "r 2 9040 904f 4e00\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "w 4e00 4e0f 9040\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "g 2e248 2e257 10000\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "G 10000 1000f 2e248\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "table 1") == null);
    // Six parts, each a record of its own: the toy's, GB's, three of none, and the refused label's.
    try std.testing.expect(std.mem.startsWith(u8, partOf(text, 1).?, "format 1\nsource toy.7z 00\nlibrary toy.dll 11\ntable 0 gb18030 wide\n"));
    try std.testing.expectEqualStrings("format 1\nsource toy.7z 00\nlibrary toy.dll 11\n", partOf(text, 2).?);
    try std.testing.expect(std.mem.endsWith(u8, partOf(text, 5).?, "label none refused\n"));
    try std.testing.expectEqual(null, partOf(text, 6));
    try std.testing.expectEqualStrings(text, try std.mem.concat(a, u8, &.{ partOf(text, 0).?, partOf(text, 1).?, partOf(text, 2).?, partOf(text, 3).?, partOf(text, 4).?, partOf(text, 5).? }));
    // Pairs: only the one that writes otherwise than its characters alone.
    try std.testing.expectEqual(1, std.mem.count(u8, text, "\np "));
    try std.testing.expect(std.mem.find(u8, text, "\np 41 301 -\n") != null);
}

test "a record refuses lines it cannot read, another format, and a label named twice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.OtherFormat, Recorded.parse(a, "format 2\n"));
    try std.testing.expectError(error.BadRecord, Recorded.parse(a, "format 1\ntable 0 plain\nr 1 41 41 41\n"));
    try std.testing.expectError(error.BadRecord, Recorded.parse(a, "format 1\ntable 0 plain\nr 1 42 41 41\nend\n"));
    try std.testing.expectError(error.BadRecord, Recorded.parse(a, "format 1\nsource s 0\nlibrary l 0\nlabel x refused\nlabel x refused\n"));
    try std.testing.expectError(error.BadRecord, Recorded.parse(a, "format 1\nsource s 0\nlibrary l 0\nlabel x 0\n"));
    try std.testing.expectError(error.BadRecord, Recorded.parse(a, "format 1\nsource s 0\nlibrary l 0\nformat 1\nsource t 0\nlibrary l 0\n"));
    try std.testing.expectError(error.BadRecord, Recorded.parse(a, "format 1\nlibrary l 0\n"));
    _ = try Recorded.parse(a, "format 1\nsource s 0\nlibrary l 0\nformat 1\nsource s 0\nlibrary l 0\n");
}
