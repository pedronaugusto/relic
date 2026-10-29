//! A cruft pack's object times, `pack-<name>.mtimes`: when each object it
//! holds was last written or wanted, which `prune` and `repack --cruft`
//! date that object by instead of by the pack's own time.
//!
//! git writes one beside every cruft pack, and a pack with one is a cruft
//! pack. The format is git's (`pack-mtimes.c`, gitformat-pack): `MTME`,
//! version 1, the hash function's id — 1 for SHA-1, 2 for SHA-256 — then
//! one big-endian 32-bit time in seconds for each object in the order of
//! the `.idx`, the pack's checksum, and the checksum of everything before
//! it.

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const entry_mod = @import("pack/entry.zig");

const Oid = hash.Oid;

/// The size of the header: signature, version and hash id.
const header_len = 12;

/// Errors from reading one.
pub const ReadError = Allocator.Error || aegis.own.ReadFileError || error{
    /// Not a version 1 `.mtimes` of a known hash, or not the size its pack
    /// asks for: git's `load_pack_mtimes_file` refuses it, and dies where
    /// it needs the times.
    InvalidMtimes,
};

/// The times of `sub_path` in `dir`, beside a pack of `count` objects, one
/// for each in the order of its index; the caller owns them. git checks
/// the signature, the version, the hash id and the size, and neither
/// checksum: so does this.
pub fn read(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, count: u32) Self.ReadError![]u32 {
    const max = header_len + @as(usize, count) * 4 + 2 * hash.max_raw_len;
    const bytes = aegis.own.readFile(io, dir, sub_path, gpa, aegis.units.Bytes(u64).fromRaw(max + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidMtimes,
        else => |e| return e,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, count);
}

/// The times `bytes` holds for a pack of `count` objects.
pub fn parse(gpa: Allocator, bytes: []const u8, count: u32) Self.ReadError![]u32 {
    if (bytes.len < header_len) return error.InvalidMtimes;
    if (!std.mem.eql(u8, bytes[0..4], "MTME")) return error.InvalidMtimes;
    if (std.mem.readInt(u32, bytes[4..8], .big) != 1) return error.InvalidMtimes;
    const raw_len: usize = switch (std.mem.readInt(u32, bytes[8..12], .big)) {
        1 => hash.Kind.sha1.rawLen(),
        2 => hash.Kind.sha256.rawLen(),
        else => return error.InvalidMtimes,
    };
    if (bytes.len != header_len + @as(usize, count) * 4 + 2 * raw_len) return error.InvalidMtimes;
    const times = try gpa.alloc(u32, count);
    for (times, 0..) |*t, i| t.* = std.mem.readInt(u32, bytes[header_len + i * 4 ..][0..4], .big);
    return times;
}

/// Every failure of this module.
pub const Error = ReadError || WriteError;

/// Errors from writing one.
pub const WriteError = Allocator.Error || Io.File.OpenError || fs.SyncError || Io.Writer.Error;

/// What `write` writes: the times of a pack whose `.idx` holds `entries`,
/// sorted by name as `pack.writeIndexFile` leaves them, each looked up in
/// `times` (0 for one not there).
pub const WriteOptions = struct {
    kind: hash.Kind,
    entries: []const entry_mod.IndexEntry,
    times: *const Oid.Map(u32),
    pack_checksum: Oid,
    sync: fs.Sync = .none,
};

/// Write the `.mtimes` git's `write_mtimes_file` writes, to `sub_path` in
/// `dir`; a failed write leaves nothing there.
pub fn write(io: Io, dir: Io.Dir, sub_path: []const u8, options: WriteOptions) Self.WriteError!void {
    const kind = options.kind;
    var buffer: [8192]u8 = undefined;
    const file = try dir.createFile(io, sub_path, .{ .exclusive = false, .truncate = true });
    var failed = true;
    defer if (failed) {
        file.close(io);
        // The write's error is the one to report; a temporary left behind is what git gc prunes.
        fs.removeLeftover(io, dir, sub_path);
    };
    var fw = file.writer(io, &buffer);
    const out = &fw.interface;
    var hasher: hash.Hasher = .init(kind);
    var head: [header_len]u8 = undefined;
    @memcpy(head[0..4], "MTME");
    std.mem.writeInt(u32, head[4..8], 1, .big);
    std.mem.writeInt(u32, head[8..12], switch (kind) {
        .sha1 => 1,
        .sha256 => 2,
    }, .big);
    hasher.update(&head);
    try out.writeAll(&head);
    for (options.entries) |e| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, options.times.get(e.oid) orelse 0, .big);
        hasher.update(&bytes);
        try out.writeAll(&bytes);
    }
    const checksum = options.pack_checksum.raw()[0..kind.rawLen()];
    hasher.update(checksum);
    try out.writeAll(checksum);
    const own = hasher.final();
    try out.writeAll(own.raw()[0..kind.rawLen()]);
    try out.flush();
    try fs.syncFile(io, file, .{ .policy = options.sync });
    file.close(io);
    failed = false;
}

test "parse takes git's layout and refuses what git refuses" {
    const gpa = std.testing.allocator;
    var bytes: [header_len + 8 + 40]u8 = @splat(0);
    @memcpy(bytes[0..4], "MTME");
    std.mem.writeInt(u32, bytes[4..8], 1, .big);
    std.mem.writeInt(u32, bytes[8..12], 1, .big);
    std.mem.writeInt(u32, bytes[12..16], 1700000000, .big);
    std.mem.writeInt(u32, bytes[16..20], 7, .big);
    const times = try parse(gpa, &bytes, 2);
    defer gpa.free(times);
    try std.testing.expectEqualSlices(u32, &.{ 1700000000, 7 }, times);

    try std.testing.expectError(error.InvalidMtimes, parse(gpa, &bytes, 3));
    try std.testing.expectError(error.InvalidMtimes, parse(gpa, bytes[0..11], 0));
    var other = bytes;
    std.mem.writeInt(u32, other[4..8], 2, .big);
    try std.testing.expectError(error.InvalidMtimes, parse(gpa, &other, 2));
    other = bytes;
    std.mem.writeInt(u32, other[8..12], 3, .big);
    try std.testing.expectError(error.InvalidMtimes, parse(gpa, &other, 2));
    other = bytes;
    other[0] = 'X';
    try std.testing.expectError(error.InvalidMtimes, parse(gpa, &other, 2));
}
