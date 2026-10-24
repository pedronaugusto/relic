//! `odb.Odb.stream` against git 2.55's objects: every object git wrote,
//! loose, packed whole and packed as a delta, from a mapped pack and by
//! positional reads, reads back as the bytes its name was made from; a
//! stored object that cannot give them fails as `read` does; and a
//! streamed object holds no more memory than the stream's buffers, past
//! `Options.max_object_bytes`, which `read` refuses.

const std = @import("std");
const fs = @import("../fs/fs.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const warp = @import("warp");
const shakedown = @import("shakedown");

const testgit = @import("git.zig");
const odb_mod = @import("../odb/odb.zig");
const hash = @import("../hash/hash.zig");

const Odb = odb_mod.Odb;
const Oid = hash.Oid;

/// Bytes no deflate shrinks, so a pack holds them as one long entry.
fn noise(buf: []u8, seed: u64) void {
    var x = seed;
    for (buf) |*b| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        b.* = @truncate(x >> 33);
    }
}

/// Text a delta against `text` with a line changed is much shorter than.
fn lines(gpa: Allocator, count: usize, changed: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..count) |i| {
        if (changed == i) {
            try out.print(gpa, "line {d} was changed here\n", .{i});
        } else {
            try out.print(gpa, "line {d} of a text git deltifies\n", .{i});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Read `s` to its end, in `chunk`-byte reads or, with `chunk` 0, pumped
/// to a writer, naming the bytes as git names an object of its type.
fn nameRead(gpa: Allocator, s: *Odb.Stream, chunk: usize) !Oid {
    var h: hash.Hasher = .init(.sha1);
    h.updateHeader(s.type.name(), s.size);
    var got: u64 = 0;
    if (chunk == 0) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try s.reader().streamRemaining(&out.writer);
        h.update(out.written());
        got = out.written().len;
    } else {
        const buf = try gpa.alloc(u8, chunk);
        defer gpa.free(buf);
        while (true) {
            const n = try s.reader().readSliceShort(buf);
            if (n == 0) break;
            h.update(buf[0..n]);
            got += n;
        }
    }
    try std.testing.expectEqual(s.size, got);
    return h.final();
}

/// Every object `git rev-list --objects --all` names, and the empty tree.
fn allObjects(gpa: Allocator, io: Io, git: *testgit.Repo) !std.ArrayList(Oid) {
    const listed = try git.run(io, &.{ "rev-list", "--objects", "--all" });
    defer gpa.free(listed);
    var oids: std.ArrayList(Oid) = .empty;
    errdefer oids.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, listed, '\n');
    while (it.next()) |line| try oids.append(gpa, try Oid.parse(.sha1, line[0..40]));
    try oids.append(gpa, hash.Kind.sha1.emptyTree());
    return oids;
}

fn checkAll(gpa: Allocator, io: Io, git: *testgit.Repo, options: odb_mod.Options) !struct { deltas: usize, objects: usize } {
    const git_dir = try git.gitDir(io);
    defer git_dir.close(io);
    var db = try Odb.open(gpa, io, git_dir, .sha1, options);
    defer db.deinit(io);
    var oids = try allObjects(gpa, io, git);
    defer oids.deinit(gpa);
    var deltas: usize = 0;
    for (oids.items, 0..) |oid, i| {
        if (!oid.eql(hash.Kind.sha1.emptyTree()) and (try db.placement(io, oid)).delta_base != null) deltas += 1;
        const s = try db.stream(io, oid);
        defer s.close(io);
        const header = try db.readHeader(io, oid);
        try std.testing.expectEqual(header.type, s.type);
        try std.testing.expectEqual(header.size, s.size);
        const chunks = [_]usize{ 0, 1, 997, 64 * 1024 };
        const named = try nameRead(gpa, s, chunks[i % chunks.len]);
        try std.testing.expect(named.eql(oid));
        // Past the end, nothing more.
        var one: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try s.reader().readSliceShort(&one));
    }
    return .{ .deltas = deltas, .objects = oids.items.len };
}

test "a stream reads every object git wrote as its name says: loose, packed whole and as a delta, mapped or read" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();

    const big = try gpa.alloc(u8, 300 * 1024 + 7);
    defer gpa.free(big);
    noise(big, 1);
    const one = try lines(gpa, 3000, null);
    defer gpa.free(one);
    const two = try lines(gpa, 3000, 1500);
    defer gpa.free(two);
    try git.writeFile(io, "big.bin", big);
    try git.writeFile(io, "text.txt", one);
    try git.writeFile(io, "empty", "");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.writeFile(io, "text.txt", two);
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });

    const loose = try checkAll(gpa, io, &git, .{});
    try std.testing.expectEqual(@as(usize, 0), loose.deltas);

    try git.exec(io, &.{ "repack", "-adq", "--window=10", "--depth=10" });
    for ([_]bool{ false, true }) |map| {
        const packed_counts = try checkAll(gpa, io, &git, .{ .map_packs = map });
        try std.testing.expectEqual(loose.objects, packed_counts.objects);
        try std.testing.expect(packed_counts.deltas > 0);
    }
}

/// `bytes` zlib-deflated, as a loose object's file holds its object.
fn zlib(gpa: Allocator, bytes: []const u8) ![]u8 {
    var compress = try warp.Compressor.init(gpa, .{ .level = 6, .max_input = .fromRaw(bytes.len) });
    defer compress.deinit();
    const frame: warp.Compressor.Frame = .{ .container = .zlib };
    const out = try gpa.alloc(u8, warp.Compressor.bound(bytes.len, frame));
    errdefer gpa.free(out);
    const n = try compress.compress(bytes, out, frame);
    return gpa.realloc(out, n);
}

/// What reading `oid` whole through a stream meets: the error opening it,
/// or the one `err` names after a failed read.
fn streamFailure(gpa: Allocator, io: Io, db: *Odb, oid: Oid) !void {
    const s = try db.stream(io, oid);
    defer s.close(io);
    _ = nameRead(gpa, s, 4096) catch |err| switch (err) {
        error.ReadFailed => return s.err().?,
        else => |e| return e,
    };
}

test "a loose object that cannot give its header's bytes fails a stream as it fails a read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var db = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer db.deinit(io);
    const oid = try db.write(io, .blob, "hello\n");
    var hex: [40]u8 = undefined;
    _ = oid.hex(&hex);
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.print(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });
    const good = try fs.readWhole(objects, io, path, gpa, .unlimited);
    defer gpa.free(good);

    const short = try zlib(gpa, "blob 10\x00hello\n");
    defer gpa.free(short);
    const long = try zlib(gpa, "blob 2\x00hello\n");
    defer gpa.free(long);
    const trailing = try std.mem.concat(gpa, u8, &.{ good, "garbage" });
    defer gpa.free(trailing);
    const cases = [_][]const u8{ short, long, trailing, good[0 .. good.len - 3], good[0 .. good.len / 2], "not zlib at all" };
    for (cases, 0..) |bytes, i| {
        try objects.deleteFile(io, path);
        try objects.writeFile(io, .{ .sub_path = path, .data = bytes });
        std.testing.expectError(error.CorruptLooseObject, db.read(io, oid)) catch |err| {
            std.debug.print("case {d}, read\n", .{i});
            return err;
        };
        std.testing.expectError(error.CorruptLooseObject, streamFailure(gpa, io, &db, oid)) catch |err| {
            std.debug.print("case {d}, stream\n", .{i});
            return err;
        };
    }
}

test "a pack entry that does not inflate to its header's bytes fails a stream, mapped or read" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const big = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(big);
    noise(big, 2);
    try git.writeFile(io, "big.bin", big);
    const oid_text = try git.line(io, &.{ "hash-object", "-w", "big.bin" });
    defer gpa.free(oid_text);
    const oid = try Oid.parse(.sha1, oid_text);
    const name = try git.runInput(io, &.{ "pack-objects", "-q", ".git/objects/pack/pack" }, oid_text);
    defer gpa.free(name);
    try git.exec(io, &.{"prune-packed"});
    var pack_path_buf: [128]u8 = undefined;
    const pack_path = try std.mem.print(&pack_path_buf, ".git/objects/pack/pack-{s}.pack", .{std.mem.trimEnd(u8, name, "\n")});
    const stored = try fs.readWhole(git.dir, io, pack_path, gpa, .unlimited);
    defer gpa.free(stored);
    // A byte in the middle of the entry's stored blocks: the inflate goes
    // on to the end, where zlib's checksum fails.
    stored[stored.len / 2] ^= 0x55;
    try git.dir.deleteFile(io, pack_path);
    try git.dir.writeFile(io, .{ .sub_path = pack_path, .data = stored });

    const git_dir = try git.gitDir(io);
    defer git_dir.close(io);
    for ([_]bool{ false, true }) |map| {
        var db = try Odb.open(gpa, io, git_dir, .sha1, .{ .map_packs = map });
        defer db.deinit(io);
        try std.testing.expectError(error.CorruptPackEntry, streamFailure(gpa, io, &db, oid));
        try std.testing.expectError(error.CorruptPackEntry, db.read(io, oid));
    }
}

test "a streamed object holds no more than the stream's buffers, past the length read refuses" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const big = try gpa.alloc(u8, 3 * 1024 * 1024);
    defer gpa.free(big);
    noise(big, 3);
    const one = try lines(gpa, 3000, null);
    defer gpa.free(one);
    const two = try lines(gpa, 3000, 10);
    defer gpa.free(two);
    try git.writeFile(io, "big.bin", big);
    try git.writeFile(io, "text.txt", one);
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.writeFile(io, "text.txt", two);
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    const big_text = try git.line(io, &.{ "rev-parse", "HEAD:big.bin" });
    defer gpa.free(big_text);
    const big_oid = try Oid.parse(.sha1, big_text);
    const one_text = try git.line(io, &.{ "rev-parse", "HEAD~1:text.txt" });
    defer gpa.free(one_text);
    const two_text = try git.line(io, &.{ "rev-parse", "HEAD:text.txt" });
    defer gpa.free(two_text);
    const versions = [_]Oid{ try Oid.parse(.sha1, one_text), try Oid.parse(.sha1, two_text) };
    const git_dir = try git.gitDir(io);
    defer git_dir.close(io);

    const ceiling = 1024 * 1024;
    // Loose first, then packed: read by positions and mapped.
    for (0..3) |round| {
        if (round == 1) try git.exec(io, &.{ "repack", "-adq", "--window=10", "--depth=10" });
        var counting: shakedown.alloc.Counting = .init(gpa);
        var db = try Odb.open(counting.allocator(), io, git_dir, .sha1, .{ .map_packs = round == 2, .max_object_bytes = .fromRaw(ceiling) });
        defer db.deinit(io);
        try std.testing.expectError(error.ObjectTooLarge, db.read(io, big_oid));
        // Found and opened, the pack's index read: what is held from here
        // on is the stream's.
        (try db.stream(io, big_oid)).close(io);
        counting.resetPeak();
        const before = counting.live_bytes;
        {
            const s = try db.stream(io, big_oid);
            defer s.close(io);
            const named = try nameRead(gpa, s, 64 * 1024);
            try std.testing.expect(named.eql(big_oid));
        }
        std.testing.expect(counting.peak_bytes - before < ceiling / 2) catch |err| {
            std.debug.print("round {d}: {d} bytes held\n", .{ round, counting.peak_bytes - before });
            return err;
        };
        if (round == 0) continue;
        // git makes the shorter version a delta against the longer.
        const delta_oid = if ((try db.placement(io, versions[0])).delta_base != null) versions[0] else versions[1];
        try std.testing.expect((try db.placement(io, delta_oid)).delta_base != null);
        // A delta is made whole first, and only within the limit.
        var small = try Odb.open(gpa, io, git_dir, .sha1, .{ .map_packs = round == 2, .max_object_bytes = .fromRaw(two.len - 1) });
        defer small.deinit(io);
        try std.testing.expectError(error.ObjectTooLarge, small.stream(io, delta_oid));
    }
}
