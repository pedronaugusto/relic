//! LFS's documented guarantees on what a server or a blob hands it, as
//! properties, each checked against a definition written from the doc, not
//! only "no crash": a pointer is read from a blob's first 1024 bytes,
//! trimmed, and one that is read has a lower-case SHA-256, its extensions
//! by priority, and encodes to bytes that read back as itself; a batch
//! answer is accepted exactly when every object is there and named by a
//! SHA-256, no action is `null`, and the hash algorithm is SHA-256's or
//! unnamed, its objects kept in order; and a server's headers are refused
//! exactly when a name is empty or holds a colon or a line break, or a
//! value holds a line break, a name given twice its last value.

const std = @import("std");
const shakedown = @import("shakedown");
const lfs = @import("lfs.zig");
const transfer = @import("transfer.zig");
const api = @import("api.zig");
const testing = std.testing;
const gen = shakedown.gen;
const Pointer = lfs.Pointer;

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

// Pointer.decode: "Read bytes as git-lfs reads them: the first 1024,
// trimmed." DecodeError.BadPointer: "an oid that is not sixty-four
// lower-case hexadecimal digits ... or two extensions at one priority".

const oid = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393";
const pointer_pieces = [_][]const u8{
    "version https://git-lfs.github.com/spec/v1\n", "version http://git-media.io/v/2\n", "version https://hawser.github.com/spec/v1\n",
    "version https://git-lfs.github.com/spec/v2\n", "oid sha256:" ++ oid ++ "\n",       "oid sha256:4D7A214614AB2935C943F9E0FF69D22EADBB8F32B1258DAAA5E2CA24D17E2393\n",
    "oid sha256:4d7a21\n",                          "oid sha1:" ++ oid ++ "\n",          "size 12345\n",
    "size 0\n",                                     "size -1\n",                         "size +7\n",
    "size 012\n",                                   "ext-0-foo sha256:" ++ oid ++ "\n",  "ext-1-bar sha256:" ++ oid ++ "\n",
    "ext-0-baz sha256:" ++ oid ++ "\n",             "ext-x-foo sha256:" ++ oid ++ "\n",  "\r\n",
    "\n",                                           " ",                                 "\t",
    "git-lfs",                                      "x",                                 "\x00",
};
const spaces = [_][]const u8{ " ", "\t", "\n", "\r", "\x0b", "\x0c" };

const Decoded = Pointer.DecodeError!Pointer;

fn expectSame(want: Decoded, got: Decoded) !void {
    const a = want catch |err| return testing.expectError(err, got);
    const b = try got;
    try testing.expectEqualSlices(u8, &a.oid, &b.oid);
    try testing.expectEqual(a.size, b.size);
    try testing.expectEqual(a.extension_count, b.extension_count);
    for (a.exts(), b.exts()) |x, y| {
        try testing.expectEqual(x.priority, y.priority);
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqualSlices(u8, &x.oid, &y.oid);
    }
}

fn anyPointer(_: void, case: *shakedown.Case) !void {
    var body_buffer: [512]u8 = undefined;
    const body = pieced(case.source, &body_buffer, &pointer_pieces, 6);
    const decoded = Pointer.decode(body);

    // Surrounding space changes nothing while the whole is in the first 1024.
    var padded_buffer: [lfs.pointer_size_cutoff + 64]u8 = undefined;
    const before = pieced(case.source, padded_buffer[0..256], &spaces, 40);
    @memcpy(padded_buffer[before.len..][0..body.len], body);
    const after = pieced(case.source, padded_buffer[before.len + body.len ..], &spaces, 40);
    try expectSame(decoded, Pointer.decode(padded_buffer[0 .. before.len + body.len + after.len]));

    // Only the first 1024 bytes decide: what follows them is never read.
    var long: [lfs.pointer_size_cutoff + 128]u8 = undefined;
    const head = long[0..lfs.pointer_size_cutoff];
    @memset(head, ' ');
    const at = gen.intRange(case.source, usize, 0, head.len - body.len);
    @memcpy(head[at..][0..body.len], body);
    case.source.bytes(long[head.len..]);
    try expectSame(Pointer.decode(head), Pointer.decode(&long));

    // What is read has a lower-case SHA-256, its extensions by priority,
    // one each, and, pointing at something, encodes to itself.
    const p = decoded catch return;
    for (p.oid) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    for (p.exts(), 0..) |ext, i| {
        for (ext.oid) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
        if (i > 0) try testing.expect(p.exts()[i - 1].priority < ext.priority);
    }
    if (p.size == 0) return;
    var encoded: [Pointer.max_encoded_len]u8 = undefined;
    try expectSame(p, Pointer.decode(try p.encodeBuf(&encoded)));
}

test "property: a pointer is read from a blob's first 1024 bytes, trimmed, and one read is canonical" {
    try shakedown.check(testing.allocator, {}, anyPointer, .{ .cases = 20000, .seed = 0x1f5 });
}

// parseBatch: "An answer that does not parse, whose objects are not named
// by a SHA-256, or that names another hash algorithm, is
// error.MalformedResponse"; BatchResponse: "its objects checked: none of
// them null"; ActionSet: "parseBatch refuses one that is null".

const batch_oids = [_][]const u8{ oid, "4D7A214614AB2935C943F9E0FF69D22EADBB8F32B1258DAAA5E2CA24D17E2393", oid[0..63], oid ++ "0", "", "g" ++ oid[1..] };

fn anyBatch(_: void, case: *shakedown.Case) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    var good = true;
    try w.writeAll("{\"transfer\":\"basic\"");
    switch (gen.intRange(case.source, u8, 0, 4)) {
        0 => {},
        1 => try w.writeAll(",\"hash_algo\":\"\""),
        2 => try w.writeAll(",\"hash_algo\":\"sha256\""),
        3 => {
            try w.writeAll(",\"hash_algo\":\"sha1\"");
            good = false;
        },
        else => {
            try w.writeAll(",\"hash_algo\":\"SHA256\"");
            good = false;
        },
    }
    try w.writeAll(",\"objects\":[");
    var oids: [5][]const u8 = undefined;
    var hrefs: [5]?[]const u8 = undefined;
    const n = gen.intRange(case.source, usize, 0, oids.len);
    for (0..n) |i| {
        if (i != 0) try w.writeByte(',');
        if (gen.intRange(case.source, u8, 0, 7) == 0) {
            try w.writeAll("null");
            good = false;
            oids[i] = "";
            hrefs[i] = null;
            continue;
        }
        const id = if (gen.boolean(case.source)) oid else gen.oneOf(case.source, []const u8, &batch_oids);
        var valid = id.len == 64;
        for (id) |c| valid = valid and (std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
        good = good and valid;
        oids[i] = id;
        hrefs[i] = null;
        try w.print("{{\"oid\":\"{s}\",\"size\":{d}", .{ id, gen.intRange(case.source, u32, 0, 1 << 20) });
        for ([_][]const u8{ "actions", "_links" }) |member| switch (gen.intRange(case.source, u8, 0, 3)) {
            0 => {},
            1 => {
                try w.print(",\"{s}\":{{\"download\":null}}", .{member});
                good = false;
            },
            else => {
                try w.print(",\"{s}\":{{\"download\":{{\"href\":\"https://h/{d}\"}}}}", .{ member, i });
                if (hrefs[i] == null) hrefs[i] = try std.fmt.allocPrint(arena, "https://h/{d}", .{i});
            },
        };
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    const answer = transfer.parseBatch(arena, .init(text.written())) catch |err| {
        try testing.expectEqual(error.MalformedResponse, err);
        try testing.expect(!good);
        return;
    };
    try testing.expect(good);
    // Every object, in the answer's order, with the action it was given.
    try testing.expectEqual(n, answer.objects.len);
    for (answer.objects, oids[0..n], hrefs[0..n]) |o, id, href| {
        try testing.expectEqualStrings(id, o.oid);
        if (href) |h| try testing.expectEqualStrings(h, o.action(.download).?.href) else try testing.expectEqual(null, o.action(.download));
    }
}

test "property: a batch answer is accepted exactly when its objects are there, named by a SHA-256, with no null action, under SHA-256" {
    try shakedown.check(testing.allocator, {}, anyBatch, .{ .cases = 20000, .seed = 0x1f6 });
}

// headersOf: "A name given twice is its last value"; checkHeader: "a name
// with no colon and no line break, a value with no line break" (and not
// empty).

const header_pieces = [_][]const u8{ "Authorization", "X-A", "a", "b c", ":", "\r", "\n", "\t", "\x00", "é", "Basic dXNlcg==" };

/// `bytes` as a JSON string, every control character escaped.
fn jsonString(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn anyHeaders(_: void, case: *shakedown.Case) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: [5][]const u8 = undefined;
    var values: [5][]const u8 = undefined;
    const n = gen.intRange(case.source, usize, 0, names.len);
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.writeAll("{\"href\":\"https://h\",\"header\":{");
    for (0..n) |i| {
        // Now and then a name given again.
        names[i] = if (i > 0 and gen.intRange(case.source, u8, 0, 3) == 0) names[gen.intRange(case.source, usize, 0, i - 1)] else try arena.dupe(u8, pieced(case.source, try arena.alloc(u8, 24), &header_pieces, 2));
        values[i] = try arena.dupe(u8, pieced(case.source, try arena.alloc(u8, 32), &header_pieces, 3));
        if (i != 0) try w.writeByte(',');
        try jsonString(w, names[i]);
        try w.writeByte(':');
        try jsonString(w, values[i]);
    }
    try w.writeAll("}}");

    // Each distinct name, and the last value it was given.
    var distinct: usize = 0;
    var good = true;
    for (0..n) |i| {
        const later = for (names[i + 1 .. n]) |other| {
            if (std.mem.eql(u8, other, names[i])) break true;
        } else false;
        if (later) continue;
        distinct += 1;
        const name_bad = names[i].len == 0 or std.mem.findAny(u8, names[i], ":\r\n") != null;
        const value_bad = std.mem.findAny(u8, values[i], "\r\n") != null;
        good = good and !name_bad and !value_bad;
    }
    const auth = api.parseAuthenticate(arena, .init(text.written())) catch |err| {
        try testing.expectEqual(error.InvalidHttpHeader, err);
        try testing.expect(!good);
        return;
    };
    try testing.expect(good);
    try testing.expectEqual(distinct, auth.headers.len);
    for (auth.headers) |h| {
        var last: ?[]const u8 = null;
        for (names[0..n], values[0..n]) |name, value| if (std.mem.eql(u8, name, h.name)) {
            last = value;
        };
        try testing.expectEqualStrings(last.?, h.value);
    }
}

test "property: a server's headers are refused exactly when HTTP's framing would break, a name given twice its last value" {
    try shakedown.check(testing.allocator, {}, anyHeaders, .{ .cases = 20000, .seed = 0x1f7 });
}
