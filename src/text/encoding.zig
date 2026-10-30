//! Character sets, converted as git converts them through iconv: one
//! place for both of git's jobs.
//!
//! `working-tree-encoding`: a file kept in the working tree in UTF-16 or
//! UTF-32 and in the repository in UTF-8, converted as git's `convert.c`
//! converts it (`toUtf8`, `fromUtf8`). The names git reads for these are
//! taken: `UTF-16`, `UTF-16LE`, `UTF-16BE`, `UTF-32`, `UTF-32LE` and
//! `UTF-32BE`, with or without the hyphen and in any case, and git's own
//! `UTF-16LE-BOM` and `UTF-16BE-BOM`. Any other character set is a
//! conversion this package does not do, and `attributes.unsupported`
//! names it.
//!
//! git's rules for the byte order mark are kept. On the way in, `UTF-16`
//! and `UTF-32` need one, which says the byte order and is dropped, and the
//! names that state a byte order may not have one. On the way out, `UTF-16`
//! and `UTF-32` are written with one, in the byte order the platform's
//! iconv writes and so the platform's git: little-endian on Linux, whose C
//! library writes its own order, and big-endian elsewhere, where git uses
//! libiconv. An empty file is not converted either way.
//!
//! Text: a commit's message in its `encoding`, log output in
//! `i18n.logOutputEncoding`, a mail in its `charset` (`reencode`, git's
//! `reencode_string_len`, and `same`, its `same_encoding`), for the
//! character sets `Charset` names.
//!
//! Names: on macOS, under `core.precomposeUnicode`, a name read from a
//! directory in its decomposed spelling, composed as git's `readdir`
//! composes it through iconv's `UTF-8-MAC` (`precompose`).

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const shakedown = @import("shakedown");
const xenoglyph = @import("xenoglyph");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The encodings this converts to and from.
pub const Encoding = enum {
    utf16,
    utf16le,
    utf16be,
    utf16le_bom,
    utf16be_bom,
    utf32,
    utf32le,
    utf32be,

    /// The encoding `name` is, as git's `same_utf_encoding` compares
    /// names, or `null` for one this does not convert.
    pub fn fromName(name: []const u8) ?Encoding {
        const names = [_]struct { []const u8, Encoding }{
            .{ "16", .utf16 },             .{ "16LE", .utf16le },
            .{ "16BE", .utf16be },         .{ "16LE-BOM", .utf16le_bom },
            .{ "16BE-BOM", .utf16be_bom }, .{ "32", .utf32 },
            .{ "32LE", .utf32le },         .{ "32BE", .utf32be },
        };
        const rest = utfSuffix(name) orelse return null;
        for (names) |entry| {
            if (std.ascii.eqlIgnoreCase(rest, entry[0])) return entry[1];
        }
        return null;
    }

    fn unit(e: Encoding) Unit {
        return switch (e) {
            .utf16, .utf16le, .utf16be, .utf16le_bom, .utf16be_bom => .u16,
            .utf32, .utf32le, .utf32be => .u32,
        };
    }
};

const Unit = enum { u16, u32 };

/// What `name` is after git's `utf` prefix and its optional hyphen.
fn utfSuffix(name: []const u8) ?[]const u8 {
    if (name.len < 3 or !std.ascii.eqlIgnoreCase(name[0..3], "utf")) return null;
    const rest = name[3..];
    return if (rest.len > 0 and rest[0] == '-') rest[1..] else rest;
}

/// Whether `name` is UTF-8 by git's `same_encoding`, which is no
/// conversion at all.
pub fn isUtf8(name: []const u8) bool {
    if (utfSuffix(name)) |rest| {
        if (std.mem.eql(u8, rest, "8")) return true;
    }
    return std.ascii.eqlIgnoreCase(name, "UTF-8");
}

/// git's `same_encoding`: whether two names are one encoding, `null`
/// being UTF-8. Two `utf` names compare after the prefix and its
/// optional hyphen; any other two compare ignoring case.
pub fn same(x: ?[]const u8, y: ?[]const u8) bool {
    const s = x orelse "UTF-8";
    const d = y orelse "UTF-8";
    if (utfSuffix(s)) |sr| if (utfSuffix(d)) |dr| if (std.ascii.eqlIgnoreCase(sr, dr)) return true;
    return std.ascii.eqlIgnoreCase(s, d);
}

/// The character sets commit messages, log output and mail are converted
/// between, as git converts them with iconv (`reencode_string_len`): text
/// in which every ASCII byte is itself. Another name is one this package
/// does not convert, which `reencode` refuses rather than leave the text
/// unconverted where git would convert it.
pub const Charset = enum {
    utf8,
    ascii,
    latin1,

    /// The spellings iconv takes for each, compared ignoring case; any
    /// `utf` name `isUtf8` says is UTF-8 is UTF-8 too, as git's
    /// `fallback_encoding` makes it.
    const ascii_names = [_][]const u8{ "US-ASCII", "ASCII", "ANSI_X3.4-1968", "ISO646-US", "US", "CSASCII", "ISO-IR-6", "IBM367", "CP367" };
    const latin1_names = [_][]const u8{ "ISO-8859-1", "ISO8859-1", "ISO_8859-1", "ISO_8859-1:1987", "LATIN1", "LATIN-1", "L1", "CP819", "IBM819", "ISO-IR-100", "CSISOLATIN1" };

    /// The character set `name` is, or `null` for one this does not
    /// convert.
    pub fn fromName(name: []const u8) ?Charset {
        if (isUtf8(name)) return .utf8;
        for (ascii_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .ascii;
        for (latin1_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .latin1;
        return null;
    }
};

/// Why `reencode` converts nothing.
pub const ReencodeError = error{
    /// `to` or `from` is a character set `Charset` does not name.
    UnsupportedEncoding,
} || Allocator.Error;

/// git's `reencode_string_len`: `src`, text in `from`, in `to`. `null`
/// where iconv stops: bytes that are not text in `from` (a broken UTF-8
/// sequence, a byte above 0x7f in ASCII) or a character `to` does not
/// have. git's callers keep the text as it was there, or refuse it. The
/// result is `a`'s.
pub fn reencode(a: Allocator, src: []const u8, to: []const u8, from: []const u8) ReencodeError!?[]u8 {
    const in = Charset.fromName(from) orelse return error.UnsupportedEncoding;
    const out_set = Charset.fromName(to) orelse return error.UnsupportedEncoding;
    var out: std.ArrayList(u8) = try .initCapacity(a, src.len + src.len / 2);
    defer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        const cp = decodeOne(in, src, &i) orelse return null;
        switch (out_set) {
            .ascii => {
                if (cp >= 0x80) return null;
                try out.append(a, @intCast(cp)); // aegis: no-danger(A010): below 0x80
            },
            .latin1 => {
                if (cp > 0xff) return null;
                try out.append(a, @intCast(cp)); // aegis: no-danger(A010): at most 0xff
            },
            .utf8 => {
                var buf: [4]u8 = undefined;
                // aegis: no-danger(A013): every decoded code point is a scalar value
                const encoded = encodeUtf8(cp, &buf) orelse unreachable;
                try out.appendSlice(a, encoded);
            },
        }
    }
    return try out.toOwnedSlice(a);
}

/// The name git's `readdir` gives on macOS under `core.precomposeUnicode`
/// for `name` as the directory spelled it, into `out`, which holds at least
/// `name.len` bytes; `null` when that is `name` itself.
///
/// git passes every name with a byte past ASCII through iconv from
/// `UTF-8-MAC` to `UTF-8` (`compat/precompose_utf8.c`) and keeps the name
/// as it is where iconv fails. macOS's iconv composes each character with
/// the one it has just written, when the pair has a primary composite: no
/// reordering of marks and no singletons (U+212B stays, where NFC gives
/// U+00C5), so a full NFC would differ. Its table stops before Unicode 5.0:
/// Balinese's vowel sign U+1B35 composes with nothing. And it refuses
/// anything outside the Basic Multilingual Plane, as it refuses a byte that
/// begins no valid character, where every later composition lies. Checked
/// over every code point and every pair of the plane against the iconv
/// macOS 26 ships.
pub fn precompose(name: []const u8, out: []u8) ?[]const u8 {
    assert(out.len >= name.len);
    for (name) |b| {
        if (b >= 0x80) break;
    } else return null;
    var len: usize = 0;
    // the character last written, and where it starts in `out`
    var last: ?u21 = null;
    var last_at: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const n = std.unicode.utf8ByteSequenceLength(name[i]) catch return null;
        if (n == 4 or i + n > name.len) return null;
        const c: u21 = switch (n) {
            1 => name[i],
            2 => std.unicode.utf8Decode2(name[i..][0..2].*) catch return null,
            3 => std.unicode.utf8Decode3(name[i..][0..3].*) catch return null,
            else => unreachable, // unreachable: a lead byte asks for one to four, and four is refused above
        };
        i += n;
        if (last) |l| if (c != 0x1b35) if (xenoglyph.normalize.compose(l, c)) |composite| {
            // A composite in the plane is never longer than its pair: the
            // second is at least U+0300, two bytes, so the pair is at least
            // three. What is written stays behind what is read.
            // unreachable: a composite is a scalar value, and `out` holds the name
            len = last_at + (std.unicode.utf8Encode(composite, out[last_at..]) catch unreachable);
            assert(len <= i);
            last = composite;
            continue;
        };
        last_at = len;
        // unreachable: `c` was decoded, and what is written stays behind what is read
        len += std.unicode.utf8Encode(c, out[len..]) catch unreachable;
        last = c;
    }
    if (std.mem.eql(u8, out[0..len], name)) return null;
    return out[0..len];
}

/// git's `ensure_utf8`, which every commit git writes with a UTF-8
/// `i18n.commitEncoding` passes through: each byte that does not begin a
/// valid UTF-8 character is taken as Latin-1 and written in UTF-8. Valid
/// is git's `has_invalid_utf8`'s: no overlong form, no surrogate, nothing
/// past U+10FFFF, and none of the noncharacters U+FDD0 to U+FDEF and
/// U+xxFFFE, U+xxFFFF. `text` itself when it is valid; else `a`'s.
pub fn ensureUtf8(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var bad = invalidUtf8At(text, 0) orelse return text;
    var out: std.ArrayList(u8) = try .initCapacity(a, text.len + 8);
    errdefer out.deinit(a);
    var from: usize = 0;
    while (true) {
        try out.appendSlice(a, text[from..bad]);
        const c = text[bad];
        // a byte that begins no valid character is at least 0x80
        aegis.assert.invariant(c >= 0x80, "c >= 0x80");
        try out.appendSlice(a, &.{ 0xc0 | (c >> 6), 0x80 | (c & 0x3f) });
        from = bad + 1;
        bad = invalidUtf8At(text, from) orelse break;
    }
    try out.appendSlice(a, text[from..]);
    return out.toOwnedSlice(a);
}

/// Where the first byte at or after `from` that begins no valid character
/// is, by git's `has_invalid_utf8`.
fn invalidUtf8At(text: []const u8, from: usize) ?usize {
    const max_codepoint = [_]u21{ 0x7f, 0x7ff, 0xffff, 0x10ffff };
    var i = from;
    while (i < text.len) {
        const lead = text[i];
        if (lead < 0x80) {
            i += 1;
            continue;
        }
        // how many more bytes the lead's high bits ask for: one to three
        var c = lead;
        var more: usize = 0;
        while (c & 0x40 != 0) : (more += 1) c <<= 1;
        if (more < 1 or more > 3 or text.len - (i + 1) < more) return i;
        var cp: u21 = (c & 0x7f) >> @intCast(more);
        for (text[i + 1 ..][0..more]) |b| {
            if (b & 0xc0 != 0x80) return i;
            cp = (cp << 6) | (b & 0x3f);
        }
        if (cp < max_codepoint[more - 1] + 1 or cp > max_codepoint[more]) return i;
        if (cp & 0x1ff800 == 0xd800) return i;
        if (cp & 0xfffe == 0xfffe) return i;
        if (cp >= 0xfdd0 and cp <= 0xfdef) return i;
        i += 1 + more;
    }
    return null;
}

/// `cp` as UTF-8 in `buf`, the bytes written; null where it is no scalar value.
fn encodeUtf8(cp: u21, buf: *[4]u8) ?[]const u8 {
    const n = std.unicode.utf8Encode(cp, buf) catch return null;
    // utf8Encode writes four bytes at most, the array's length.
    return if (n <= buf.len) buf[0..n] else null;
}

/// The character at `src[i.*]` in `set`, `i` moved past it; `null` for
/// bytes that are not one.
fn decodeOne(set: Charset, src: []const u8, i: *usize) ?u21 {
    const b = src[i.*];
    switch (set) {
        .ascii, .latin1 => {
            if (set == .ascii and b >= 0x80) return null;
            i.* += 1;
            return b;
        },
        .utf8 => {
            const len = std.unicode.utf8ByteSequenceLength(b) catch return null;
            if (len > src.len - i.*) return null;
            const at = src[i.*..];
            const cp = switch (len) {
                1 => b,
                2 => std.unicode.utf8Decode2(at[0..2].*),
                3 => std.unicode.utf8Decode3(at[0..3].*),
                4 => std.unicode.utf8Decode4(at[0..4].*),
                // utf8ByteSequenceLength gives 1 to 4.
                else => return null,
            } catch return null;
            i.* += len;
            return cp;
        },
    }
}

/// Why content could not be converted.
pub const Error = error{
    /// `UTF-16` or `UTF-32` content without a byte order mark, which git
    /// requires so the byte order is known.
    BomRequired,
    /// `UTF-16LE`, `UTF-16BE`, `UTF-32LE` or `UTF-32BE` content that
    /// begins with a byte order mark, which git refuses: the name says the
    /// order, and the mark would become part of the text.
    BomProhibited,
    /// Bytes that are not text in the encoding: a broken surrogate pair, a
    /// value past U+10FFFF, or a last character cut short.
    InvalidContent,
} || Allocator.Error;

const bom16_be = "\xfe\xff";
const bom16_le = "\xff\xfe";
const bom32_be = "\x00\x00\xfe\xff";
const bom32_le = "\xff\xfe\x00\x00";

/// git's `validate_encoding`, which comes before a conversion in.
fn validate(e: Encoding, src: []const u8) Error!void {
    switch (e) {
        .utf16le, .utf16be => if (std.mem.startsWith(u8, src, bom16_be) or std.mem.startsWith(u8, src, bom16_le))
            return error.BomProhibited,
        .utf32le, .utf32be => if (std.mem.startsWith(u8, src, bom32_be) or std.mem.startsWith(u8, src, bom32_le))
            return error.BomProhibited,
        .utf16 => if (!std.mem.startsWith(u8, src, bom16_be) and !std.mem.startsWith(u8, src, bom16_le))
            return error.BomRequired,
        .utf32 => if (!std.mem.startsWith(u8, src, bom32_be) and !std.mem.startsWith(u8, src, bom32_le))
            return error.BomRequired,
        .utf16le_bom, .utf16be_bom => {},
    }
}

/// `src`, in encoding `e`, as UTF-8 for the repository. Empty content is
/// returned as it is.
pub fn toUtf8(a: Allocator, e: Encoding, src: []const u8) Self.Error![]const u8 {
    if (src.len == 0) return src;
    try validate(e, src);
    // git reads its `-BOM` names as plain `UTF-16`: the mark decides, and
    // without one iconv reads big-endian.
    var body = src;
    var endian: std.lang.Endian = .big;
    switch (e) {
        .utf16le, .utf32le => endian = .little,
        .utf16be, .utf32be => {},
        .utf16, .utf16le_bom, .utf16be_bom => if (std.mem.startsWith(u8, src, bom16_le)) {
            endian = .little;
            body = src[2..];
        } else if (std.mem.startsWith(u8, src, bom16_be)) {
            body = src[2..];
        },
        .utf32 => if (std.mem.startsWith(u8, src, bom32_le)) {
            endian = .little;
            body = src[4..];
        } else if (std.mem.startsWith(u8, src, bom32_be)) {
            body = src[4..];
        },
    }
    var out: std.ArrayList(u8) = try .initCapacity(a, body.len + body.len / 2);
    errdefer out.deinit(a);
    var buf: [4]u8 = undefined;
    switch (e.unit()) {
        .u16 => {
            if (body.len % 2 != 0) return error.InvalidContent;
            var i: usize = 0;
            while (i < body.len) : (i += 2) {
                const hi = std.mem.readInt(u16, body[i..][0..2], endian);
                var cp: u21 = hi;
                if (std.unicode.utf16IsLowSurrogate(hi)) return error.InvalidContent;
                if (std.unicode.utf16IsHighSurrogate(hi)) {
                    if (i + 4 > body.len) return error.InvalidContent;
                    const lo = std.mem.readInt(u16, body[i + 2 ..][0..2], endian);
                    if (!std.unicode.utf16IsLowSurrogate(lo)) return error.InvalidContent;
                    cp = std.unicode.utf16DecodeSurrogatePair(&.{ hi, lo }) catch return error.InvalidContent;
                    i += 2;
                }
                const encoded = encodeUtf8(cp, &buf) orelse return error.InvalidContent;
                try out.appendSlice(a, encoded);
            }
        },
        .u32 => {
            if (body.len % 4 != 0) return error.InvalidContent;
            var i: usize = 0;
            while (i < body.len) : (i += 4) {
                const value = std.mem.readInt(u32, body[i..][0..4], endian);
                if (value > 0x10ffff) return error.InvalidContent;
                const cp: u21 = @intCast(value); // checked against U+10FFFF above
                const encoded = encodeUtf8(cp, &buf) orelse return error.InvalidContent;
                try out.appendSlice(a, encoded);
            }
        },
    }
    return out.toOwnedSlice(a);
}

/// The byte order `UTF-16` and `UTF-32` are written in, with a mark: the
/// platform iconv's, which is the platform git's.
pub const written_order: std.lang.Endian = if (builtin.target.os.tag == .linux) builtin.target.cpu.arch.endian() else .big;

/// `src`, UTF-8 from the repository, in encoding `e` for the working tree.
/// Empty content is returned as it is; content that is not UTF-8 is
/// `error.InvalidContent`, which git leaves unconverted.
pub fn fromUtf8(a: Allocator, e: Encoding, src: []const u8) Self.Error![]const u8 {
    if (src.len == 0) return src;
    const endian: std.lang.Endian, const bom: []const u8 = switch (e) {
        .utf16le => .{ .little, "" },
        .utf16be => .{ .big, "" },
        .utf32le => .{ .little, "" },
        .utf32be => .{ .big, "" },
        .utf16le_bom => .{ .little, bom16_le },
        .utf16be_bom => .{ .big, bom16_be },
        .utf16 => .{ written_order, if (written_order == .little) bom16_le else bom16_be },
        .utf32 => .{ written_order, if (written_order == .little) bom32_le else bom32_be },
    };
    const view = std.unicode.Utf8View.init(src) catch return error.InvalidContent;
    var out: std.ArrayList(u8) = try .initCapacity(a, bom.len + src.len * 2);
    errdefer out.deinit(a);
    try out.appendSlice(a, bom);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (e.unit()) {
            .u16 => if (cp >= 0x10000) {
                const v = cp - 0x10000;
                try appendInt(u16, a, &out, @intCast(0xd800 + (v >> 10)), endian); // aegis: no-danger(A010): v is below 2^20
                try appendInt(u16, a, &out, @intCast(0xdc00 + (v & 0x3ff)), endian); // aegis: no-danger(A010): ten bits
            } else {
                try appendInt(u16, a, &out, @intCast(cp), endian); // aegis: no-danger(A010): below 0x10000
            },
            .u32 => try appendInt(u32, a, &out, cp, endian),
        }
    }
    // What `toUtf8` reads back: whole code units after the mark.
    assert((out.items.len - bom.len) % @as(usize, switch (e.unit()) {
        .u16 => 2,
        .u32 => 4,
    }) == 0);
    return out.toOwnedSlice(a);
}

fn appendInt(comptime T: type, a: Allocator, out: *std.ArrayList(u8), value: T, endian: std.lang.Endian) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, endian);
    try out.appendSlice(a, &bytes);
}

const testing = std.testing;

test "names are read as git compares them" {
    try testing.expectEqual(Encoding.utf16le, Encoding.fromName("UTF-16LE").?);
    try testing.expectEqual(Encoding.utf16le, Encoding.fromName("utf16le").?);
    try testing.expectEqual(Encoding.utf16be, Encoding.fromName("utf16be").?);
    try testing.expectEqual(Encoding.utf16be_bom, Encoding.fromName("UTF-16BE-BOM").?);
    try testing.expectEqual(Encoding.utf32, Encoding.fromName("Utf-32").?);
    try testing.expect(Encoding.fromName("SHIFT-JIS") == null);
    try testing.expect(Encoding.fromName("UTF-16-LE") == null);
    try testing.expect(isUtf8("utf8") and isUtf8("UTF-8") and !isUtf8("UTF-16"));
}

test "the byte order mark is required, prohibited or written as git says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BomRequired, toUtf8(a, .utf16, "a\x00"));
    try testing.expectError(error.BomProhibited, toUtf8(a, .utf16le, "\xff\xfea\x00"));
    try testing.expectError(error.BomProhibited, toUtf8(a, .utf32be, "\x00\x00\xfe\xff\x00\x00\x00a"));
    try testing.expectEqualStrings("a\xc3\xa9", try toUtf8(a, .utf16, "\xff\xfea\x00\xe9\x00"));
    try testing.expectEqualStrings("a", try toUtf8(a, .utf16, "\xfe\xff\x00a"));
    try testing.expectEqualStrings("\xf0\x9f\x98\x80", try toUtf8(a, .utf16be, "\xd8\x3d\xde\x00"));
    try testing.expectEqualStrings("", try toUtf8(a, .utf16, ""));
    try testing.expectError(error.InvalidContent, toUtf8(a, .utf16le, "a\x00b"));
    try testing.expectError(error.InvalidContent, toUtf8(a, .utf16le, "\x00\xd8a\x00"));
    try testing.expectError(error.InvalidContent, toUtf8(a, .utf32le, "\x00\x00\x11\x00"));

    try testing.expectEqualStrings("\xff\xfea\x00", try fromUtf8(a, .utf16le_bom, "a"));
    try testing.expectEqualStrings("\x00a", try fromUtf8(a, .utf16be, "a"));
    try testing.expectEqualStrings("\x3d\xd8\x00\xde", try fromUtf8(a, .utf16le, "\xf0\x9f\x98\x80"));
    try testing.expectEqualStrings("", try fromUtf8(a, .utf32, ""));
    try testing.expectError(error.InvalidContent, fromUtf8(a, .utf16le, "\xff"));
}

test "fuzz: any bytes convert in and back out to themselves, or are refused" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = shakedown.gen.intRange(case.source, usize, 0, buf.len);
            case.source.bytes(buf[0..len]);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for ([_]Encoding{ .utf16le, .utf16be, .utf32le, .utf32be }) |e| {
                const utf8 = toUtf8(a, e, buf[0..len]) catch continue;
                try testing.expectEqualSlices(u8, buf[0..len], try fromUtf8(a, e, utf8));
            }
        }
    }.one, .{});
}

test "text is reencoded as iconv converts it, and stops where iconv stops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("caf\xc3\xa9", (try reencode(a, "caf\xe9", "UTF-8", "ISO-8859-1")).?);
    try testing.expectEqualStrings("caf\xe9", (try reencode(a, "caf\xc3\xa9", "latin1", "utf8")).?);
    try testing.expectEqualStrings("plain", (try reencode(a, "plain", "US-ASCII", "UTF-8")).?);
    // a character Latin-1 does not have, a broken sequence, a high byte in ASCII
    try testing.expect(try reencode(a, "\xe2\x82\xac", "ISO-8859-1", "UTF-8") == null);
    try testing.expect(try reencode(a, "caf\xc3", "ISO-8859-1", "UTF-8") == null);
    try testing.expect(try reencode(a, "\xed\xa0\x80", "ISO-8859-1", "UTF-8") == null);
    try testing.expect(try reencode(a, "caf\xe9", "UTF-8", "US-ASCII") == null);
    try testing.expectError(error.UnsupportedEncoding, reencode(a, "x", "UTF-8", "EUC-JP"));
    try testing.expectError(error.UnsupportedEncoding, reencode(a, "x", "UTF-16", "UTF-8"));
    try testing.expect(same(null, "utf8") and same("UTF-8", "utf-8") and same("latin1", "LATIN1"));
    try testing.expect(!same("latin1", "ISO-8859-1") and !same(null, "ISO-8859-1"));
}

test "ensureUtf8 takes what is not UTF-8 as Latin-1, as git's commit_tree does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("caf\xc3\xa9", try ensureUtf8(a, "caf\xc3\xa9"));
    try testing.expectEqualStrings("caf\xc3\xa9!", try ensureUtf8(a, "caf\xe9!"));
    // a cut sequence: its lead, then the continuation alone
    try testing.expectEqualStrings("\xc3\xa2\xc2\x82x", try ensureUtf8(a, "\xe2\x82x"));
    // a noncharacter and an overlong form are not valid to git
    try testing.expectEqualStrings("\xc3\xaf\xc2\xbf\xc2\xbf", try ensureUtf8(a, "\xef\xbf\xbf"));
    try testing.expectEqualStrings("\xc3\x80\xc2\xaf", try ensureUtf8(a, "\xc0\xaf"));
}

test "fuzz: Latin-1 converts to UTF-8 and back to itself" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = shakedown.gen.intRange(case.source, usize, 0, buf.len);
            case.source.bytes(buf[0..len]);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const utf8 = (try reencode(a, buf[0..len], "UTF-8", "ISO-8859-1")).?;
            try testing.expect(std.unicode.utf8ValidateSlice(utf8));
            try testing.expectEqualSlices(u8, buf[0..len], (try reencode(a, utf8, "ISO-8859-1", "UTF-8")).?);
            // any bytes as UTF-8: converted only where they are UTF-8
            if (try reencode(a, buf[0..len], "UTF-8", "UTF-8")) |same_bytes| {
                try testing.expectEqualSlices(u8, buf[0..len], same_bytes);
            } else try testing.expect(!std.unicode.utf8ValidateSlice(buf[0..len]));
        }
    }.one, .{});
}

test "a decomposed name is composed as macOS's iconv composes it for git" {
    const cases = [_]struct { in: []const u8, want: ?[]const u8 }{
        // ASCII and an already composed name are left alone
        .{ .in = "plain", .want = null },
        .{ .in = "caf\u{e9}", .want = null },
        .{ .in = "cafe\u{301}", .want = "caf\u{e9}" },
        .{ .in = "o\u{308}d/u\u{308}", .want = "\u{f6}d/\u{fc}" },
        // pairwise: a dot below then a circumflex compose, the other order
        // stops after the first; nothing is reordered
        .{ .in = "a\u{323}\u{302}", .want = "\u{1ead}" },
        .{ .in = "a\u{302}\u{323}", .want = "\u{e2}\u{323}" },
        .{ .in = "e\u{315}\u{300}", .want = null },
        // no singletons, no excluded composition
        .{ .in = "\u{212b}", .want = null },
        .{ .in = "\u{915}\u{93c}", .want = null },
        // Hangul jamo
        .{ .in = "\u{1100}\u{1161}\u{11a8}", .want = "\u{ac01}" },
        // Balinese composes in Unicode 5.0, after macOS's table
        .{ .in = "\u{1b05}\u{1b35}", .want = null },
        // outside the plane, or not UTF-8: iconv refuses and git keeps it
        .{ .in = "e\u{301}\u{1f600}", .want = null },
        .{ .in = "\u{11099}\u{110ba}", .want = null },
        .{ .in = "e\u{301}\xc0\x80", .want = null },
        .{ .in = "e\u{301}\xcc", .want = null },
    };
    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        const got = precompose(case.in, &buffer);
        if (case.want) |want| {
            try testing.expectEqualStrings(want, got orelse return error.TestExpectedEqual);
        } else try testing.expectEqual(null, got);
    }
}

test "fuzz: a composed name is never longer and composes to itself" {
    try shakedown.check(testing.allocator, {}, struct {
        // starters, the marks that compose with them, and bytes of no
        // character, in any order
        const pieces = [_][]const u8{ "a", "e", "o", "s", "/", "\u{3b1}", "\u{1100}", "\u{1161}", "\u{11a8}", "\u{915}", "\u{300}", "\u{301}", "\u{302}", "\u{308}", "\u{323}", "\u{327}", "\u{345}", "\u{93c}", "\u{1b35}", "\u{1f600}", "\xcc", "\xff" };
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var name: [128]u8 = undefined;
            var len: usize = 0;
            const count = shakedown.gen.intRange(case.source, usize, 0, 24);
            for (0..count) |_| {
                const piece = pieces[shakedown.gen.intRange(case.source, usize, 0, pieces.len - 1)];
                @memcpy(name[len..][0..piece.len], piece);
                len += piece.len;
            }
            var buffer: [128]u8 = undefined;
            const once = precompose(name[0..len], buffer[0..len]) orelse return;
            // `a` and U+0323 are three bytes, and so is U+1EA1
            try testing.expect(once.len <= len);
            var again: [128]u8 = undefined;
            try testing.expectEqual(null, precompose(once, again[0..once.len]));
        }
    }.one, .{});
}
