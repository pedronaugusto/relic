//! A pack's reverse index, `pack-<name>.rev`: its objects in the order they
//! sit in the pack, each named by its position in the `.idx`.
//!
//! git writes one beside every pack it indexes when `pack.writeReverseIndex`
//! is on, which it is by default since 2.41, and reads it to go from an
//! offset to an object without sorting the index each time. The format is
//! git's: `RIDX`, version 1, the hash function's id — 1 for SHA-1, 2 for
//! SHA-256 — then one big-endian 32-bit index position for each object by
//! ascending offset, the pack's checksum, and the checksum of everything
//! before it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const pack = @import("pack.zig");
const fs = @import("fs.zig");
const config_mod = @import("config.zig");

const Oid = hash.Oid;

/// Errors from writing one.
pub const Error = Allocator.Error || Io.File.OpenError || Io.File.SyncError || Io.Writer.Error;

/// Whether `config` asks for reverse indexes: `pack.writeReverseIndex`,
/// true when unset, as git has it since 2.41.
pub fn wanted(config: ?*const config_mod.Config) bool {
    const c = config orelse return true;
    return c.getBool("pack.writereverseindex", true) catch true;
}

/// Write the reverse index of a pack whose `.idx` holds `entries`, sorted
/// by name as `pack.writeIndexFile` leaves them, to `sub_path` in `dir`.
pub fn write(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    kind: hash.Kind,
    entries: []const pack.IndexEntry,
    pack_checksum: Oid,
    sync: fs.Sync,
) Error!void {
    const positions = try gpa.alloc(u32, entries.len);
    defer gpa.free(positions);
    for (positions, 0..) |*p, i| p.* = @intCast(i);
    std.mem.sort(u32, positions, entries, struct {
        fn lessThan(e: []const pack.IndexEntry, a: u32, b: u32) bool {
            return e[a].offset < e[b].offset;
        }
    }.lessThan);

    var buffer: [8192]u8 = undefined;
    const file = try dir.createFile(io, sub_path, .{ .exclusive = false, .truncate = true });
    var failed = true;
    defer if (failed) {
        file.close(io);
        dir.deleteFile(io, sub_path) catch {};
    };
    var fw = file.writer(io, &buffer);
    const out = &fw.interface;
    var hasher: hash.Hasher = .init(kind);

    var head: [12]u8 = undefined;
    @memcpy(head[0..4], "RIDX");
    std.mem.writeInt(u32, head[4..8], 1, .big);
    std.mem.writeInt(u32, head[8..12], switch (kind) {
        .sha1 => 1,
        .sha256 => 2,
    }, .big);
    hasher.update(&head);
    try out.writeAll(&head);
    for (positions) |p| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, p, .big);
        hasher.update(&bytes);
        try out.writeAll(&bytes);
    }
    const checksum = pack_checksum.raw()[0..kind.rawLen()];
    hasher.update(checksum);
    try out.writeAll(checksum);
    const own = hasher.final();
    try out.writeAll(own.raw()[0..kind.rawLen()]);
    try out.flush();
    switch (sync) {
        .none => {},
        .batch, .per_file => try file.sync(io),
    }
    file.close(io);
    failed = false;
}

const testing = std.testing;
const testremote = @import("testremote.zig");
const repo_mod = @import("repo.zig");

test "a pack relic writes has the reverse index git's index-pack writes for it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testremote.historyRepo(gpa, io, 6);
    defer source.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, source.dir, .{});
    defer repo.deinit(io);
    var collected = try repo.odb.collectAll(io, .{});
    defer collected.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const report = try repo.odb.writePack(io, tmp.dir, collected.entries, .{ .reverse_index = true });
    var hex: [hash.max_hex_len]u8 = undefined;
    const base = try std.fmt.allocPrint(gpa, "pack-{s}", .{report.name.hex(&hex)});
    defer gpa.free(base);
    const pack_name = try std.fmt.allocPrint(gpa, "{s}.pack", .{base});
    defer gpa.free(pack_name);
    const rev_name = try std.fmt.allocPrint(gpa, "{s}.rev", .{base});
    defer gpa.free(rev_name);
    const out = try testremote.gitInput(gpa, io, tmp.dir, &.{ "index-pack", "--rev-index", "-o", "check.idx", pack_name }, "");
    gpa.free(out);
    const ours = try tmp.dir.readFileAlloc(io, rev_name, gpa, .unlimited);
    defer gpa.free(ours);
    const theirs = try tmp.dir.readFileAlloc(io, "check.rev", gpa, .unlimited);
    defer gpa.free(theirs);
    try testing.expectEqualSlices(u8, theirs, ours);
}
