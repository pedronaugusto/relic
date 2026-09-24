//! The media type of some bytes, told from their first 512 as the WHATWG's
//! MIME sniffing standard tells it, in the order and with the answers Go's
//! `http.DetectContentType` gives. git-lfs names an object's type this way
//! when it uploads one, and a server may keep what it was told.

const std = @import("std");

/// How much of the bytes is looked at.
pub const sniff_len = 512;

/// The media type of `data`: one of the table's, or `text/plain;
/// charset=utf-8` for bytes with no binary control character in them, or
/// `application/octet-stream`.
pub fn contentType(data: []const u8) []const u8 {
    const bytes = data[0..@min(data.len, sniff_len)];
    var first: usize = 0;
    while (first < bytes.len and isWhitespace(bytes[first])) first += 1;
    for (signatures) |sig| {
        if (sig.match(bytes, first)) return sig.type;
    }
    if (isText(bytes[first..])) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

fn isWhitespace(b: u8) bool {
    return switch (b) {
        '\t', '\n', 0x0c, '\r', ' ' => true,
        else => false,
    };
}

fn isText(bytes: []const u8) bool {
    for (bytes) |b| switch (b) {
        0x00...0x08, 0x0b, 0x0e...0x1a, 0x1c...0x1f => return false,
        else => {},
    };
    return true;
}

const Signature = struct {
    kind: union(enum) {
        /// A tag, matched without regard to case after any whitespace, and
        /// ended by a space or `>`.
        html: []const u8,
        exact: []const u8,
        masked: struct { mask: []const u8, pattern: []const u8, skip_whitespace: bool = false },
        mp4,
    },
    type: []const u8,

    fn match(sig: Signature, data: []const u8, first: usize) bool {
        switch (sig.kind) {
            .html => |tag| {
                const rest = data[first..];
                if (rest.len < tag.len + 1) return false;
                for (tag, rest[0..tag.len]) |t, d| {
                    const folded = if (t >= 'A' and t <= 'Z') d & 0xdf else d;
                    if (folded != t) return false;
                }
                return rest[tag.len] == ' ' or rest[tag.len] == '>';
            },
            .exact => |prefix| return std.mem.startsWith(u8, data, prefix),
            .masked => |m| {
                const rest = if (m.skip_whitespace) data[first..] else data;
                if (rest.len < m.pattern.len) return false;
                for (m.pattern, m.mask, rest[0..m.pattern.len]) |p, k, d| {
                    if (d & k != p) return false;
                }
                return true;
            },
            .mp4 => {
                if (data.len < 12) return false;
                const box: usize = std.mem.readInt(u32, data[0..4], .big);
                if (data.len < box or box % 4 != 0) return false;
                if (!std.mem.eql(u8, data[4..8], "ftyp")) return false;
                var at: usize = 8;
                while (at < box) : (at += 4) {
                    // The major brand's version is passed over.
                    if (at == 12) continue;
                    if (std.mem.eql(u8, data[at .. at + 3], "mp4")) return true;
                }
                return false;
            },
        }
    }
};

const html_type = "text/html; charset=utf-8";

fn html(tag: []const u8) Signature {
    return .{ .kind = .{ .html = tag }, .type = html_type };
}

fn exact(prefix: []const u8, media_type: []const u8) Signature {
    return .{ .kind = .{ .exact = prefix }, .type = media_type };
}

fn masked(mask: []const u8, pattern: []const u8, media_type: []const u8) Signature {
    return .{ .kind = .{ .masked = .{ .mask = mask, .pattern = pattern } }, .type = media_type };
}

const signatures = [_]Signature{
    html("<!DOCTYPE HTML"),
    html("<HTML"),
    html("<HEAD"),
    html("<SCRIPT"),
    html("<IFRAME"),
    html("<H1"),
    html("<DIV"),
    html("<FONT"),
    html("<TABLE"),
    html("<A"),
    html("<STYLE"),
    html("<TITLE"),
    html("<B"),
    html("<BODY"),
    html("<BR"),
    html("<P"),
    html("<!--"),
    .{ .kind = .{ .masked = .{ .mask = "\xff\xff\xff\xff\xff", .pattern = "<?xml", .skip_whitespace = true } }, .type = "text/xml; charset=utf-8" },
    exact("%PDF-", "application/pdf"),
    exact("%!PS-Adobe-", "application/postscript"),

    // Byte order marks.
    masked("\xff\xff\x00\x00", "\xfe\xff\x00\x00", "text/plain; charset=utf-16be"),
    masked("\xff\xff\x00\x00", "\xff\xfe\x00\x00", "text/plain; charset=utf-16le"),
    masked("\xff\xff\xff\x00", "\xef\xbb\xbf\x00", "text/plain; charset=utf-8"),

    // Images.
    exact("\x00\x00\x01\x00", "image/x-icon"),
    exact("\x00\x00\x02\x00", "image/x-icon"),
    exact("BM", "image/bmp"),
    exact("GIF87a", "image/gif"),
    exact("GIF89a", "image/gif"),
    masked("\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff", "RIFF\x00\x00\x00\x00WEBPVP", "image/webp"),
    exact("\x89PNG\x0d\x0a\x1a\x0a", "image/png"),
    exact("\xff\xd8\xff", "image/jpeg"),

    // Audio and video, in the standard's order.
    masked("\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff", "FORM\x00\x00\x00\x00AIFF", "audio/aiff"),
    masked("\xff\xff\xff", "ID3", "audio/mpeg"),
    masked("\xff\xff\xff\xff\xff", "OggS\x00", "application/ogg"),
    masked("\xff\xff\xff\xff\xff\xff\xff\xff", "MThd\x00\x00\x00\x06", "audio/midi"),
    masked("\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff", "RIFF\x00\x00\x00\x00AVI ", "video/avi"),
    masked("\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff", "RIFF\x00\x00\x00\x00WAVE", "audio/wave"),
    .{ .kind = .mp4, .type = "video/mp4" },
    exact("\x1a\x45\xdf\xa3", "video/webm"),

    // Fonts.
    masked(&(@as([34]u8, @splat(0)) ++ "\xff\xff".*), &(@as([34]u8, @splat(0)) ++ "LP".*), "application/vnd.ms-fontobject"),
    exact("\x00\x01\x00\x00", "font/ttf"),
    exact("OTTO", "font/otf"),
    exact("ttcf", "font/collection"),
    exact("wOFF", "font/woff"),
    exact("wOF2", "font/woff2"),

    // Archives.
    exact("\x1f\x8b\x08", "application/x-gzip"),
    exact("PK\x03\x04", "application/zip"),
    exact("Rar!\x1a\x07\x00", "application/x-rar-compressed"),
    exact("Rar!\x1a\x07\x01\x00", "application/x-rar-compressed"),

    exact("\x00\x61\x73\x6d", "application/wasm"),
};

const testing = std.testing;

test "bytes are named as Go's DetectContentType names them" {
    const cases = [_][2][]const u8{
        .{ "", "text/plain; charset=utf-8" },
        .{ "  \n<html>hi</html>", "text/html; charset=utf-8" },
        .{ "<HtMl ", "text/html; charset=utf-8" },
        .{ "<html", "text/plain; charset=utf-8" },
        .{ "<htmlx>", "text/plain; charset=utf-8" },
        .{ "<!-- x -->", "text/html; charset=utf-8" },
        .{ "\t<?xml version", "text/xml; charset=utf-8" },
        .{ "%PDF-1.7", "application/pdf" },
        .{ "%!PS-Adobe-3.0", "application/postscript" },
        .{ "\xfe\xff\x00h", "text/plain; charset=utf-16be" },
        .{ "\xef\xbb\xbfx", "text/plain; charset=utf-8" },
        .{ "\x00\x00\x01\x00\x01", "image/x-icon" },
        .{ "BM..", "image/bmp" },
        .{ "GIF89a", "image/gif" },
        .{ "RIFF\x01\x02\x03\x04WEBPVP8 ", "image/webp" },
        .{ "\x89PNG\r\n\x1a\n\x00", "image/png" },
        .{ "\xff\xd8\xff\xe0", "image/jpeg" },
        .{ "FORM\x00\x00\x00\x00AIFF", "audio/aiff" },
        .{ "ID3\x04", "audio/mpeg" },
        .{ "OggS\x00\x02", "application/ogg" },
        .{ "MThd\x00\x00\x00\x06\x00", "audio/midi" },
        .{ "RIFF\x00\x00\x00\x00AVI LIST", "video/avi" },
        .{ "RIFF\x00\x00\x00\x00WAVEfmt ", "audio/wave" },
        .{ "\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom", "video/mp4" },
        .{ "\x00\x00\x00\x18ftypiso5\x00\x00\x00\x00iso5dash", "application/octet-stream" },
        .{ "\x1a\x45\xdf\xa3\x01", "video/webm" },
        .{ "\x00\x01\x00\x00\x00", "font/ttf" },
        .{ "wOF2", "font/woff2" },
        .{ "\x1f\x8b\x08\x00", "application/x-gzip" },
        .{ "PK\x03\x04\x14", "application/zip" },
        .{ "Rar!\x1a\x07\x01\x00", "application/x-rar-compressed" },
        .{ "\x00asm\x01", "application/wasm" },
        .{ "plain words\r\n", "text/plain; charset=utf-8" },
        .{ "a\x1bb", "text/plain; charset=utf-8" },
        .{ "a\x00b", "application/octet-stream" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], contentType(c[0]));
    var eot: [40]u8 = @splat(0);
    eot[34] = 'L';
    eot[35] = 'P';
    try testing.expectEqualStrings("application/vnd.ms-fontobject", contentType(&eot));
    // Only the first 512 bytes count.
    var long: [600]u8 = @splat('a');
    long[512] = 0;
    try testing.expectEqualStrings("text/plain; charset=utf-8", contentType(&long));
}

test "fuzz: any bytes are named" {
    try testing.fuzz({}, fuzzSniff, .{});
}

fn fuzzSniff(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [600]u8 = undefined;
    const len = smith.slice(&scratch);
    try testing.expect(contentType(scratch[0..len]).len != 0);
}
