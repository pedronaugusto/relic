//! The index's documented guarantees as properties, each checked against an
//! index written by hand from git's format (versions 2, 3 and 4), not only
//! "no crash": its entries read back as written, field by field, the mode
//! as `Entry.modeOf` takes it and its spelling kept, and each found by its
//! path and stage; and entries out of git's order, or one path and stage
//! twice, are `UnsortedIndex` ("an index git refuses to read, and this
//! package too").

const std = @import("std");
const shakedown = @import("shakedown");
const index_mod = @import("index.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const testing = std.testing;
const gen = shakedown.gen;
const Index = index_mod.Index;

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

/// git's `encode_varint`, the offset varint a version 4 index strips a
/// path's shared prefix by.
fn varint(value: u64, out: *[16]u8) []const u8 {
    var pos: usize = out.len - 1;
    var v = value;
    out[pos] = @intCast(v & 127);
    while (v >> 7 != 0) {
        v >>= 7;
        v -= 1;
        pos -= 1;
        out[pos] = @intCast(128 | (v & 127));
    }
    return out[pos..];
}

const Written = struct {
    path: []const u8,
    stage: u2,
    raw_mode: u32,
    mode: object.Mode,
    assume_valid: bool,
    skip_worktree: bool,
    intent_to_add: bool,
    oid: [32]u8,
    stat: [9]u32,
};

/// Raw modes and what git's consumers take each as.
const modes = [_]struct { raw: u32, mode: object.Mode }{
    .{ .raw = 0o100644, .mode = .file },    .{ .raw = 0o100755, .mode = .exec }, .{ .raw = 0o120000, .mode = .symlink },
    .{ .raw = 0o160000, .mode = .gitlink }, .{ .raw = 0o100664, .mode = .file }, .{ .raw = 0o100700, .mode = .exec },
};

const path_pieces = [_][]const u8{ "a", "b", "a/", "a.c", "\xc3\xa9", "-", "0", "z" };

fn order(a: Written, b: Written) std.math.Order {
    const by_path = std.mem.order(u8, a.path, b.path);
    return if (by_path != .eq) by_path else std.math.order(a.stage, b.stage);
}

fn less(_: void, a: Written, b: Written) bool {
    return order(a, b) == .lt;
}

fn anyIndex(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    const kind = gen.oneOf(case.source, hash.Kind, &[_]hash.Kind{ .sha1, .sha256 });
    const raw_len = kind.rawLen();
    const version = gen.intRange(case.source, u32, 2, 4);
    var paths: [8][24]u8 = undefined;
    var entries: [8]Written = undefined;
    var n: usize = 0;
    for (&paths) |*buffer| {
        if (!gen.boolean(case.source)) break;
        // A path that is not empty and does not end in a slash, which only a
        // sparse directory may.
        var path = pieced(case.source, buffer[0..23], &path_pieces, 4);
        if (path.len == 0 or path[path.len - 1] == '/') {
            buffer[path.len] = 'x';
            path = buffer[0 .. path.len + 1];
        }
        const m = gen.oneOf(case.source, @TypeOf(modes[0]), &modes);
        const extended = version >= 3 and gen.boolean(case.source);
        var e: Written = .{
            .path = path,
            .stage = gen.int(case.source, u2),
            .raw_mode = m.raw,
            .mode = m.mode,
            .assume_valid = gen.boolean(case.source),
            .skip_worktree = extended and gen.boolean(case.source),
            .intent_to_add = extended and gen.boolean(case.source),
            .oid = undefined,
            .stat = undefined,
        };
        case.source.bytes(e.oid[0..raw_len]);
        for (&e.stat) |*v| v.* = gen.int(case.source, u32);
        const taken = for (entries[0..n]) |other| {
            if (order(other, e) == .eq) break true;
        } else false;
        if (taken) continue;
        entries[n] = e;
        n += 1;
    }
    std.mem.sort(Written, entries[0..n], {}, less);
    // Out of order, or one path and stage twice, now and then.
    var expect_unsorted = false;
    var count = n;
    if (n >= 2 and gen.intRange(case.source, u8, 0, 3) == 0) {
        const i = gen.intRange(case.source, usize, 1, n - 1);
        std.mem.swap(Written, &entries[i - 1], &entries[i]);
        expect_unsorted = true;
    } else if (n >= 1 and n < entries.len and gen.intRange(case.source, u8, 0, 3) == 0) {
        const i = gen.intRange(case.source, usize, 0, n - 1);
        std.mem.copyBackwards(Written, entries[i + 1 .. n + 1], entries[i..n]);
        count = n + 1;
        expect_unsorted = true;
    }

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, "DIRC");
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, version, .big);
    try bytes.appendSlice(gpa, &word);
    std.mem.writeInt(u32, &word, @intCast(count), .big);
    try bytes.appendSlice(gpa, &word);
    var previous: []const u8 = "";
    for (entries[0..count]) |e| {
        const start = bytes.items.len;
        // ctime, mtime, dev, ino, mode, uid, gid, size: the mode's word is
        // the fifth, between the stat's ino and uid.
        for (e.stat[0..6]) |v| {
            std.mem.writeInt(u32, &word, v, .big);
            try bytes.appendSlice(gpa, &word);
        }
        std.mem.writeInt(u32, &word, e.raw_mode, .big);
        try bytes.appendSlice(gpa, &word);
        for (e.stat[6..9]) |v| {
            std.mem.writeInt(u32, &word, v, .big);
            try bytes.appendSlice(gpa, &word);
        }
        try bytes.appendSlice(gpa, e.oid[0..raw_len]);
        const extended = e.skip_worktree or e.intent_to_add;
        var flags: u16 = @intCast(@min(e.path.len, 0xfff));
        flags |= @as(u16, e.stage) << 12;
        if (e.assume_valid) flags |= 0x8000;
        if (extended) flags |= 0x4000;
        var half: [2]u8 = undefined;
        std.mem.writeInt(u16, &half, flags, .big);
        try bytes.appendSlice(gpa, &half);
        if (extended) {
            var extra: u16 = 0;
            if (e.skip_worktree) extra |= 0x4000;
            if (e.intent_to_add) extra |= 0x2000;
            std.mem.writeInt(u16, &half, extra, .big);
            try bytes.appendSlice(gpa, &half);
        }
        if (version == 4) {
            var common: usize = 0;
            while (common < previous.len and common < e.path.len and previous[common] == e.path[common]) common += 1;
            var buffer: [16]u8 = undefined;
            try bytes.appendSlice(gpa, varint(previous.len - common, &buffer));
            try bytes.appendSlice(gpa, e.path[common..]);
            try bytes.append(gpa, 0);
        } else {
            try bytes.appendSlice(gpa, e.path);
            // One to eight NULs, to a multiple of eight.
            const unpadded = bytes.items.len - start + 1;
            try bytes.appendNTimes(gpa, 0, 1 + std.mem.alignForward(usize, unpadded, 8) - unpadded);
        }
        previous = e.path;
    }
    var sum: [32]u8 = @splat(0);
    if (gen.intRange(case.source, u8, 0, 4) != 0) switch (kind) {
        .sha1 => std.crypto.hash.Sha1.hash(bytes.items, sum[0..20], .{}),
        .sha256 => std.crypto.hash.sha2.Sha256.hash(bytes.items, sum[0..32], .{}),
    };
    try bytes.appendSlice(gpa, sum[0..raw_len]);

    var index = Index.parse(gpa, kind, bytes.items) catch |err| {
        if (expect_unsorted) return testing.expectEqual(error.UnsortedIndex, err);
        return err;
    };
    defer index.deinit();
    try testing.expect(!expect_unsorted);
    try testing.expectEqual(version, index.version);
    const items = index.items();
    try testing.expectEqual(count, items.len);
    for (entries[0..count], items) |want, got| {
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqualSlices(u8, want.oid[0..raw_len], got.oid.raw());
        try testing.expectEqual(want.stage, got.stage);
        try testing.expectEqual(want.mode, got.mode);
        try testing.expectEqual(if (want.raw_mode == want.mode.raw()) null else @as(?u32, want.raw_mode), got.raw_mode);
        try testing.expectEqual(want.assume_valid, got.assume_valid);
        try testing.expectEqual(want.skip_worktree, got.skip_worktree);
        try testing.expectEqual(want.intent_to_add, got.intent_to_add);
        const s = got.stat;
        try testing.expectEqualSlices(u32, &want.stat, &.{ s.ctime_sec, s.ctime_nsec, s.mtime_sec, s.mtime_nsec, s.dev, s.ino, s.uid, s.gid, s.size });
        try testing.expect(index.findStage(want.path, want.stage) != null);
    }
}

test "property: an index written by hand in any version reads back entry for entry, and one out of git's order is refused" {
    try shakedown.check(testing.allocator, {}, anyIndex, .{ .cases = 4000, .seed = 0x1e1 });
}
