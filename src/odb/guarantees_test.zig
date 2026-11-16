//! The pack index's documented guarantees as properties, each checked
//! against an index written by hand from git's format, not only "no
//! crash": an index of names, offsets and CRCs reads back so that every
//! name is found where it was written and no other is; names out of order
//! are `UnsortedIndex`; a fanout that falls, or that disagrees with the
//! names it indexes, is `CorruptIndexFanout` ("how a truncated or shuffled
//! index is caught before a lookup silently misses"); a changed byte is
//! `ChecksumMismatch`; a version 2 index of another version is
//! `UnknownIndexVersion`; and a large offset with no row is
//! `BadLargeOffset`.

const std = @import("std");
const shakedown = @import("shakedown");
const pack = @import("pack.zig");
const hash = @import("../hash/hash.zig");
const testing = std.testing;
const gen = shakedown.gen;
const Oid = hash.Oid;

const Object = struct { name: [32]u8, offset: u64, crc: u32 };

fn nameLess(len: usize, a: Object, b: Object) bool {
    return std.mem.order(u8, a.name[0..len], b.name[0..len]) == .lt;
}

/// The index's own digest over `bytes`, by std's hashes.
fn digest(kind: hash.Kind, bytes: []const u8, out: []u8) void {
    switch (kind) {
        .sha1 => std.crypto.hash.Sha1.hash(bytes, out[0..20], .{}),
        .sha256 => std.crypto.hash.sha2.Sha256.hash(bytes, out[0..32], .{}),
    }
}

const Mutation = enum { none, swap_names, fanout_short, fanout_falls, flip_byte, version, large_missing };

/// Up to twelve distinct names, their first bytes from a few so buckets are
/// shared, sorted as an index holds them.
const Drawn = struct { objects: [12]Object, n: usize };

fn drawObjects(source: *shakedown.Source, kind: hash.Kind, version: u32) Drawn {
    const raw_len = kind.rawLen();
    var d: Drawn = .{ .objects = undefined, .n = 0 };
    for (0..gen.intRange(source, usize, 0, d.objects.len)) |_| {
        var o: Object = .{ .name = undefined, .offset = 0, .crc = gen.int(source, u32) };
        source.bytes(o.name[0..raw_len]);
        o.name[0] = gen.oneOf(source, u8, &[_]u8{ 0, 1, 0x41, 0x42, 0xfe, 0xff });
        o.offset = if (version == 2 and gen.intRange(source, u8, 0, 3) == 0)
            gen.intRange(source, u64, 1 << 31, std.math.maxInt(u64))
        else
            gen.intRange(source, u32, 12, if (version == 2) (1 << 31) - 1 else std.math.maxInt(u32));
        const duplicate = for (d.objects[0..d.n]) |other| {
            if (std.mem.eql(u8, other.name[0..raw_len], o.name[0..raw_len])) break true;
        } else false;
        if (duplicate) continue;
        d.objects[d.n] = o;
        d.n += 1;
    }
    std.mem.sort(Object, d.objects[0..d.n], raw_len, nameLess);
    return d;
}

/// The mutation's change to the order the names are written in and to the
/// fanout written, and the error the index is then refused with.
fn corrupt(source: *shakedown.Source, mutation: Mutation, version: u32, n: usize, fanout: *[256]u32, written: *[12]Object) ?anyerror {
    switch (mutation) {
        .swap_names => if (n >= 2) {
            const i = gen.intRange(source, usize, 1, n - 1);
            std.mem.swap(Object, &written[i - 1], &written[i]);
            return error.UnsortedIndex;
        },
        .fanout_short => {
            // One bucket's end short of some of its names, still rising: the
            // names it leaves out begin with that bucket's byte, and a lookup
            // in the bucket would miss them. The last bucket, the count, stays.
            var buckets: [256]u8 = undefined;
            var count: usize = 0;
            for (0..255) |b| if (fanout[b] > (if (b == 0) 0 else fanout[b - 1])) {
                buckets[count] = @intCast(b);
                count += 1;
            };
            if (count != 0) {
                const b = buckets[gen.intRange(source, usize, 0, count - 1)];
                const before: u32 = if (b == 0) 0 else fanout[b - 1];
                fanout[b] -= gen.intRange(source, u32, 1, fanout[b] - before);
                return error.CorruptIndexFanout;
            }
        },
        .fanout_falls => {
            // A bucket that ends before the one ahead of it; the last bucket stays.
            const b = gen.intRange(source, usize, 0, 253);
            if (fanout[b] > 0) {
                fanout[b + 1] = fanout[b] - 1;
                return error.CorruptIndexFanout;
            }
        },
        .version => if (version == 2) return error.UnknownIndexVersion,
        else => {},
    }
    return null;
}

/// Which written name took the last large row: the one whose row is
/// dropped. Two names may share an offset, so it is known by its row.
const Encoded = struct { last_large: ?usize };

/// The index's bytes up to its pack's name: header, fanout and tables.
fn encodeTables(gpa: std.mem.Allocator, source: *shakedown.Source, raw_len: usize, version: u32, mutation: Mutation, fanout: *const [256]u32, written: []const Object, bytes: *std.ArrayList(u8)) !Encoded {
    var large: [12]u64 = undefined;
    var large_count: u32 = 0;
    var e: Encoded = .{ .last_large = null };
    if (version == 2) {
        try bytes.appendSlice(gpa, "\xfftOc");
        var v: [4]u8 = undefined;
        std.mem.writeInt(u32, &v, if (mutation == .version) gen.oneOf(source, u32, &[_]u32{ 1, 3, 0x02000000 }) else 2, .big);
        try bytes.appendSlice(gpa, &v);
    }
    for (fanout) |f| {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, f, .big);
        try bytes.appendSlice(gpa, &word);
    }
    if (version != 2) {
        for (written) |o| {
            var word: [4]u8 = undefined;
            std.mem.writeInt(u32, &word, @intCast(o.offset), .big);
            try bytes.appendSlice(gpa, &word);
            try bytes.appendSlice(gpa, o.name[0..raw_len]);
        }
        return e;
    }
    for (written) |o| try bytes.appendSlice(gpa, o.name[0..raw_len]);
    for (written) |o| {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, o.crc, .big);
        try bytes.appendSlice(gpa, &word);
    }
    for (written, 0..) |o, at| {
        var word: [4]u8 = undefined;
        if (o.offset < 1 << 31) {
            std.mem.writeInt(u32, &word, @intCast(o.offset), .big);
        } else {
            std.mem.writeInt(u32, &word, 0x8000_0000 | large_count, .big);
            large[large_count] = o.offset;
            large_count += 1;
            e.last_large = at;
        }
        try bytes.appendSlice(gpa, &word);
    }
    // One large row too few: the last one names a row the table lacks.
    const kept = if (mutation == .large_missing and large_count != 0) large_count - 1 else large_count;
    for (large[0..kept]) |offset| {
        var row: [8]u8 = undefined;
        std.mem.writeInt(u64, &row, offset, .big);
        try bytes.appendSlice(gpa, &row);
    }
    return e;
}

/// Every name where it was written, the large one with no row refused by
/// name, and a name the index does not hold not found.
fn expectReadBack(source: *shakedown.Source, index: *const pack.Index, kind: hash.Kind, mutation: Mutation, version: u32, objects: []const Object, written: []const Object, last_large: ?usize) !void {
    const raw_len = kind.rawLen();
    for (objects, 0..) |o, i| {
        const oid = Oid.fromCut(kind, o.name[0..raw_len]);
        const rowless = if (last_large) |at| std.mem.eql(u8, written[at].name[0..raw_len], o.name[0..raw_len]) else false;
        if (mutation == .large_missing and rowless) {
            try testing.expectError(error.BadLargeOffset, index.find(oid));
            continue;
        }
        const found = (try index.find(oid)).?;
        try testing.expectEqual(@as(u32, @intCast(i)), found.index);
        try testing.expectEqual(o.offset, found.offset);
        try testing.expectEqual(if (version == 2) @as(?u32, o.crc) else null, found.crc);
        try testing.expect((try index.nameAt(@intCast(i))).eql(oid));
    }
    var other: [32]u8 = undefined;
    source.bytes(other[0..raw_len]);
    const held = for (objects) |o| {
        if (std.mem.eql(u8, o.name[0..raw_len], other[0..raw_len])) break true;
    } else false;
    if (!held) try testing.expectEqual(null, try index.find(Oid.fromCut(kind, other[0..raw_len])));
}

fn anyIndex(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    const kind = gen.oneOf(case.source, hash.Kind, &[_]hash.Kind{ .sha1, .sha256 });
    const raw_len = kind.rawLen();
    const version: u32 = if (gen.boolean(case.source)) 2 else 1;
    const drawn = drawObjects(case.source, kind, version);
    const objects = drawn.objects;
    const n = drawn.n;
    const mutation = gen.enumValue(case.source, Mutation);

    var fanout: [256]u32 = @splat(0);
    for (objects[0..n]) |o| for (o.name[0]..256) |b| {
        fanout[b] += 1;
    };
    // The order the names are written in, and the fanout written.
    var written = objects;
    var expect = corrupt(case.source, mutation, version, n, &fanout, &written);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const encoded = try encodeTables(gpa, case.source, raw_len, version, mutation, &fanout, written[0..n], &bytes);
    var pack_name: [32]u8 = undefined;
    case.source.bytes(pack_name[0..raw_len]);
    try bytes.appendSlice(gpa, pack_name[0..raw_len]);
    var sum: [32]u8 = undefined;
    digest(kind, bytes.items, &sum);
    try bytes.appendSlice(gpa, sum[0..raw_len]);
    if (mutation == .flip_byte and expect == null) {
        const at = gen.intRange(case.source, usize, 0, bytes.items.len - raw_len - 1);
        // Kept out of what is refused as itself before the digest is
        // read: a version 2 magic and version, a version 1 fanout.
        if (at >= @as(usize, if (version == 2) 8 else 1024)) {
            bytes.items[at] ^= gen.intRange(case.source, u8, 1, 255);
            expect = error.ChecksumMismatch;
        }
    }

    var index = pack.Index.parse(gpa, kind, try gpa.dupe(u8, bytes.items)) catch |err| {
        if (expect) |want| return testing.expectEqual(want, err);
        return err;
    };
    defer index.deinit();
    if (expect) |want| {
        std.debug.print("accepted an index that should be {t}\n", .{want});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(version, index.version);
    try testing.expectEqual(@as(u32, @intCast(n)), index.count);
    try testing.expect(index.pack_checksum.eql(Oid.fromCut(kind, pack_name[0..raw_len])));
    try expectReadBack(case.source, &index, kind, mutation, version, objects[0..n], written[0..n], encoded.last_large);
}

test "property: a pack index written by hand reads back, and each corruption the doc names is refused as itself" {
    try shakedown.check(testing.allocator, {}, anyIndex, .{ .cases = 4000, .seed = 0x1d1 });
}
