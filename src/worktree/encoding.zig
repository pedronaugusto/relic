//! `working-tree-encoding`: a file kept in the working tree in UTF-16 or
//! UTF-32 and in the repository in UTF-8, converted as git's `convert.c`
//! converts it through iconv.
//!
//! The names git reads for these are taken: `UTF-16`, `UTF-16LE`,
//! `UTF-16BE`, `UTF-32`, `UTF-32LE` and `UTF-32BE`, with or without the
//! hyphen and in any case, and git's own `UTF-16LE-BOM` and `UTF-16BE-BOM`.
//! Any other character set is a conversion this package does not do, and
//! `attributes.unsupported` names it.
//!
//! git's rules for the byte order mark are kept. On the way in, `UTF-16`
//! and `UTF-32` need one, which says the byte order and is dropped, and the
//! names that state a byte order may not have one. On the way out, `UTF-16`
//! and `UTF-32` are written with one, in the byte order the platform's
//! iconv writes and so the platform's git: little-endian on Linux, whose C
//! library writes its own order, and big-endian elsewhere, where git uses
//! libiconv. An empty file is not converted either way.

const Self = @This();

const std = @import("std");
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
    var endian: std.builtin.Endian = .big;
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
                    cp = 0x10000 + ((@as(u21, hi) - 0xd800) << 10) + (lo - 0xdc00);
                    i += 2;
                }
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidContent;
                try out.appendSlice(a, buf[0..n]);
            }
        },
        .u32 => {
            if (body.len % 4 != 0) return error.InvalidContent;
            var i: usize = 0;
            while (i < body.len) : (i += 4) {
                const value = std.mem.readInt(u32, body[i..][0..4], endian);
                if (value > 0x10ffff) return error.InvalidContent;
                const cp: u21 = @intCast(value); // safe: checked against U+10FFFF above
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidContent;
                try out.appendSlice(a, buf[0..n]);
            }
        },
    }
    return out.toOwnedSlice(a);
}

/// The byte order `UTF-16` and `UTF-32` are written in, with a mark: the
/// platform iconv's, which is the platform git's.
pub const written_order: std.builtin.Endian = if (builtin.os.tag == .linux) builtin.cpu.arch.endian() else .big;

/// `src`, UTF-8 from the repository, in encoding `e` for the working tree.
/// Empty content is returned as it is; content that is not UTF-8 is
/// `error.InvalidContent`, which git leaves unconverted.
pub fn fromUtf8(a: Allocator, e: Encoding, src: []const u8) Self.Error![]const u8 {
    if (src.len == 0) return src;
    const endian: std.builtin.Endian, const bom: []const u8 = switch (e) {
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
                try appendInt(u16, a, &out, @intCast(0xd800 + (v >> 10)), endian); // safe: v is below 2^20
                try appendInt(u16, a, &out, @intCast(0xdc00 + (v & 0x3ff)), endian); // safe: ten bits
            } else {
                try appendInt(u16, a, &out, @intCast(cp), endian); // safe: below 0x10000
            },
            .u32 => try appendInt(u32, a, &out, cp, endian),
        }
    }
    return out.toOwnedSlice(a);
}

fn appendInt(comptime T: type, a: Allocator, out: *std.ArrayList(u8), value: T, endian: std.builtin.Endian) Allocator.Error!void {
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
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
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
