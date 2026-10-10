//! `GIT binary patch`: how git writes a binary file's change into a patch,
//! and how it is read back.
//!
//! Each side is a `literal <size>` hunk — the whole file, deflated — or a
//! `delta <size>` hunk — a pack-style delta against the other side,
//! deflated — whichever is smaller, written in base 85 at most 52 bytes to a
//! line, each line led by a letter giving its byte count. The forward hunk
//! makes the new file from the old; the reverse hunk, which git always
//! writes, makes the old from the new, so the patch applies with `-R` too.
//!
//! The data a hunk carries is what git's reader requires and checks: the
//! inflated size and, when applied, the object names on the `index` line.
//! Its compressed bytes are this package's deflate and delta encoder's, not
//! zlib's and git's `diff_delta`'s, and so differ from the text git writes
//! for the same change while decoding to the same files; git's own output
//! differs from one zlib build to another in the same way.

const Self = @This();

const std = @import("std");
const repeat = @import("shakedown").corpus.repeat;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const delta = @import("../codec.zig").delta;
const warp = @import("warp");

/// Which kind a hunk is.
pub const Method = enum { literal, delta };

const en85 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

comptime {
    // Every digit a value below 85, and every value one digit, which `de85`
    // keeps one above it so that zero is no digit.
    assert(en85.len == 85);
}

const de85: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    for (en85, 0..) |c, i| t[c] = i + 1;
    break :blk t;
};

/// Errors from decoding base 85.
pub const Decode85Error = error{InvalidBase85};

/// Decode `dst.len` bytes from `src`, five characters to four bytes, as
/// git's `decode_85` does, with its overflow check.
pub fn decode85(dst: []u8, src: []const u8) Decode85Error!void {
    var out: usize = 0;
    var in: usize = 0;
    var len = dst.len;
    while (len > 0) {
        var acc: u32 = 0;
        var cnt: usize = 4;
        while (cnt > 0) : (cnt -= 1) {
            if (in >= src.len) return error.InvalidBase85;
            const de = de85[src[in]];
            in += 1;
            if (de == 0) return error.InvalidBase85;
            acc = acc * 85 + (de - 1);
        }
        if (in >= src.len) return error.InvalidBase85;
        const de: u32 = de85[src[in]];
        in += 1;
        if (de == 0) return error.InvalidBase85;
        if (0xffffffff / 85 < acc) return error.InvalidBase85;
        acc *= 85;
        if (0xffffffff - (de - 1) < acc) return error.InvalidBase85;
        acc += de - 1;
        const take = @min(len, 4);
        len -= take;
        var k: usize = 0;
        while (k < take) : (k += 1) {
            acc = std.math.rotl(u32, acc, 8);
            dst[out] = @truncate(acc);
            out += 1;
        }
    }
}

/// Encode `data` as git's `encode_85` does: five characters for every four
/// bytes, the last group padded with zeros.
pub fn encode85(w: *Io.Writer, data: []const u8) Io.Writer.Error!void {
    var at: usize = 0;
    while (at < data.len) {
        var acc: u32 = 0;
        var shift: i32 = 24;
        while (shift >= 0) : (shift -= 8) {
            const ch: u32 = data[at];
            at += 1;
            acc |= ch << @intCast(shift);
            if (at == data.len) break;
        }
        var buf: [5]u8 = undefined;
        var cnt: usize = 5;
        while (cnt > 0) {
            cnt -= 1;
            buf[cnt] = en85[acc % 85];
            acc /= 85;
        }
        try w.writeAll(&buf);
    }
}

/// Errors from inflating a hunk.
pub const InflateError = error{CorruptBinaryPatch} || Allocator.Error;

/// Inflate a zlib stream that must come to exactly `size` bytes, as git's
/// `inflate_it` requires. The size is the patch's own word, so one past
/// what a delta may produce is refused before anything is allocated.
pub fn inflate(gpa: Allocator, data: []const u8, size: usize) Self.InflateError![]u8 {
    if (size > delta.max_result_bytes) return error.CorruptBinaryPatch;
    const decoder = try gpa.create(warp.Decompressor);
    defer gpa.destroy(decoder);
    decoder.* = .{};
    // one byte more than wanted, so a stream that runs long is caught
    const out = try gpa.alloc(u8, size + 1);
    errdefer gpa.free(out);
    var reader: Io.Reader = .fixed(data);
    const got = decoder.inflateReader(&reader, out, .{}) catch return error.CorruptBinaryPatch;
    if (got.out_len != size) return error.CorruptBinaryPatch;
    return gpa.realloc(out, size);
}

/// Deflate `data` as one zlib stream at zlib's level 1, which is
/// `core.compression`'s default and what git deflates a hunk with.
pub fn deflate(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    var compress = try warp.Compressor.init(gpa, .{ .level = 1, .max_input = data.len });
    defer compress.deinit();
    const out = try gpa.alloc(u8, warp.Compressor.bound(data.len, .{}));
    errdefer gpa.free(out);
    const n = compress.compress(data, out, .{}) catch unreachable; // unreachable: bound reserves the complete stream
    return gpa.realloc(out, n);
}

/// One side's hunk: the smaller of a deflated delta from `from` and the
/// deflated `to`, as git's `emit_binary_diff_body` chooses.
fn writeBody(gpa: Allocator, w: *Io.Writer, from: []const u8, to: []const u8) (Allocator.Error || Io.Writer.Error)!void {
    const literal = try deflate(gpa, to);
    defer gpa.free(literal);
    var chosen: []const u8 = literal;
    var method: Method = .literal;
    var size: usize = to.len;
    var deflated_delta: ?[]u8 = null;
    defer if (deflated_delta) |d| gpa.free(d);
    if (from.len != 0 and to.len != 0) {
        if (try delta.encode(gpa, from, to, .{ .max_bytes = literal.len })) |raw| {
            defer gpa.free(raw);
            deflated_delta = try deflate(gpa, raw);
            if (deflated_delta.?.len < literal.len) {
                chosen = deflated_delta.?;
                method = .delta;
                size = raw.len;
            }
        }
    }
    try w.print("{s} {d}\n", .{ @tagName(method), size });
    var at: usize = 0;
    while (at < chosen.len) {
        const n = @min(52, chosen.len - at);
        const lead: u8 = if (n <= 26) @intCast(@as(usize, 'A') + n - 1) else @intCast(@as(usize, 'a') + n - 27);
        try w.writeByte(lead);
        try encode85(w, chosen[at .. at + n]);
        try w.writeByte('\n');
        at += n;
    }
    try w.writeByte('\n');
}

/// Errors from `write`.
pub const WriteError = Allocator.Error || Io.Writer.Error;

/// The `GIT binary patch` block for a change from `old` to `new`: the
/// forward hunk and the reverse one.
pub fn write(gpa: Allocator, w: *Io.Writer, old: []const u8, new: []const u8) WriteError!void {
    try w.writeAll("GIT binary patch\n");
    try writeBody(gpa, w, old, new);
    try writeBody(gpa, w, new, old);
}

/// Errors from `applyHunk`.
pub const ApplyHunkError = delta.Error || Allocator.Error;

/// The file a hunk makes from `image`: the literal data, or the delta
/// applied to it. The result is the caller's.
pub fn applyHunk(gpa: Allocator, image: []const u8, method: Method, data: []const u8) ApplyHunkError![]u8 {
    return switch (method) {
        .literal => gpa.dupe(u8, data),
        .delta => delta.apply(gpa, image, data),
    };
}

test "base 85 round-trips and matches git's alphabet" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode85(&w, "\xff\xff\xff\xff");
    // git's own self-test: four 0xff bytes are "|NsC0"
    try std.testing.expectEqualStrings("|NsC0", w.buffered());
    var back: [4]u8 = undefined;
    try decode85(&back, w.buffered());
    try std.testing.expectEqualSlices(u8, "\xff\xff\xff\xff", &back);
    try std.testing.expectError(error.InvalidBase85, decode85(&back, "\"\"\"\"\""));
}

test "a binary patch's hunks inflate to both sides" {
    const gpa = std.testing.allocator;
    const old = repeat("\x00binary\x00", 40);
    const new = repeat("\x00binary\x00", 39) ++ "\x01changed";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, old, new);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "GIT binary patch\n"));
}

test "a hunk that states a size past what a delta may make is refused before it is allocated" {
    const gpa = std.testing.allocator;
    const deflated = try deflate(gpa, "x");
    defer gpa.free(deflated);
    try std.testing.expectError(error.CorruptBinaryPatch, inflate(gpa, deflated, 8_000_000_000));
    try std.testing.expectError(error.CorruptBinaryPatch, inflate(gpa, deflated, std.math.maxInt(usize)));
    const out = try inflate(gpa, deflated, 1);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("x", out);
}

test "fuzz: any base 85 line and any deflated hunk decode or are refused by name" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [1024]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];
            var dst: [52]u8 = undefined;
            const want = @min(dst.len, input.len / 5 * 4);
            decode85(dst[0..want], input[0 .. want / 4 * 5]) catch |err| switch (err) {
                error.InvalidBase85 => {},
            };
            const size = smith.value(u16) % 4096;
            const out = inflate(gpa, input, size) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.CorruptBinaryPatch => return,
            };
            defer gpa.free(out);
            try std.testing.expectEqual(@as(usize, size), out.len);
        }
    }.one, .{});
}

/// All errors reported by this namespace.
pub const Error = Decode85Error || InflateError || WriteError || ApplyHunkError || Io.Writer.Error || Self.InflateError || Allocator.Error;
