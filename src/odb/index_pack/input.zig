//! index-pack's input seam: where the bytes of a received pack enter. The
//! other side's stream is copied into a temporary pack as it arrives, and
//! that file is read back here and nowhere else in index-pack, each read
//! held to a buffer of a size named here or to a position bound its caller
//! names; what reads the bytes these hand back parses them as a pack.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// The temporary pack a receive copies the stream into: the receive opens
/// it, and closes it once the indexes are written.
pub const PackFile = aegis.own.Unowned(Io.File);

/// How much of the pack a reader holds at a time.
pub const Buffer = [64 * 1024]u8;

/// A reader of the pack through `buffer`, which holds at most a `Buffer`
/// of it at a time.
pub fn readPack(io: Io, file: PackFile, buffer: *Buffer) Io.File.Reader {
    return file.get().reader(io, buffer);
}

/// The pack's bytes from `at` up to `end`, at most as many as `buffer`
/// holds: the part of `buffer` read, short only where the file ends before
/// `end`.
pub fn readPackAt(io: Io, file: PackFile, buffer: []u8, at: u64, end: u64) Io.File.ReadPositionalError![]u8 {
    aegis.assert.invariant(at <= end, "a read starts at or before its bound");
    const left = std.math.cast(usize, end - at) orelse buffer.len;
    const n = try file.get().readPositionalAll(io, buffer[0..@min(buffer.len, left)], at);
    return buffer[0..n];
}

/// For an Io layer standing between a receive and the Io beneath it, a
/// test's fault layer: the pack's bytes at `at` into `data`'s buffers, read
/// with `io`, the Io beneath, as the layer's own `fileReadPositional`.
pub fn forwardRead(io: Io, file: Io.File, data: []const []u8, at: u64) Io.File.ReadPositionalError!usize {
    return file.readPositional(io, data, at);
}

test "a read stops at its bound, at the buffer's end, and at the file's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "pack", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "0123456789", 0);
    const pack: PackFile = .of(file);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("23", try readPackAt(io, pack, &buffer, 2, 4));
    try std.testing.expectEqualStrings("2345", try readPackAt(io, pack, &buffer, 2, 10));
    try std.testing.expectEqualStrings("89", try readPackAt(io, pack, &buffer, 8, 20));
    try std.testing.expectEqualStrings("", try readPackAt(io, pack, &buffer, 10, 20));
}
