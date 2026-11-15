//! The ref store's input seam: where the bytes of the files a ref store keeps enter it --
//! a loose ref and the symbolic link that can stand for one, `packed-refs`, and a reftable
//! table's header, footer and blocks -- each read held to a limit named here. These reads
//! happen here and nowhere else in the ref store; what reads the bytes they hand back parses
//! them as the format they are.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How much of a file a whole read takes: each names the kind of file it reads.
pub const Limit = enum {
    /// `packed-refs`, which git reads whole: 256 MiB holds millions of refs.
    packed_refs,
    /// Any file of a ref store read whole, as a test's before and after of the store.
    store_file,

    fn bytes(limit: Limit) usize {
        return switch (limit) {
            .packed_refs, .store_file => 1 << 28,
        };
    }
};

/// The most one positional read of a table takes: a block's 24-bit length, and what
/// deflate can add to a stream of that length (a deflated log block's).
pub const max_table_read: usize = std.math.maxInt(u24) + std.math.maxInt(u24) / 256 + 64;

/// The file at `path` under `dir` into `buffer`, which is the read's limit: a loose ref, of
/// which git reads no more than its first object name or `ref:` line. A longer file fills
/// the buffer and the rest is not read.
pub fn into(io: Io, dir: Io.Dir, path: []const u8, buffer: []u8) Io.Dir.ReadFileError![]u8 {
    return dir.readFile(io, path, buffer);
}

/// The target of the symbolic link at `path` under `dir` into `buffer`, which is the read's
/// limit; its length.
pub fn link(io: Io, dir: Io.Dir, path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    return dir.readLink(io, path, buffer);
}

/// Errors from reading an opened file whole.
pub const OpenedError = Io.File.Reader.Error || Allocator.Error || error{StreamTooLong};

/// The `open` file from its start to its end, at most `limit`'s bytes, the caller's. `size`
/// is the length a stat of the same file gave, so the read does not stat it again: std's
/// reader would, and keep a cancel that lands there in its `size_err`, unread.
pub fn opened(io: Io, open: Io.File, size: u64, gpa: Allocator, limit: Limit) OpenedError![]u8 {
    var reader = open.reader(io, &.{});
    reader.size = size;
    return reader.interface.allocRemaining(gpa, .limited(limit.bytes())) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse aegis.assert.never("a reader that failed a read keeps its error"),
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

/// The file at `path` under `dir`, whole, at most `limit`'s bytes, the caller's.
pub fn whole(io: Io, dir: Io.Dir, path: []const u8, gpa: Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, .fromRaw(limit.bytes()));
}

/// The bytes of a table's file, `held`, at `offset` into `buffer`, at most `max_table_read` of
/// them; how many it read, fewer where the file ends first.
pub fn table(io: Io, held: aegis.own.Unowned(Io.File), buffer: []u8, offset: u64) Io.File.ReadPositionalError!usize {
    aegis.assert.invariant(buffer.len <= max_table_read, "a table is read a block at most at a time");
    return held.get().readPositionalAll(io, buffer, offset);
}

test "each read is the file's bytes, no more than its limit takes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ref: ref", try into(io, tmp.dir, "HEAD", &buffer));
    const bytes = try whole(io, tmp.dir, "HEAD", gpa, .store_file);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", bytes);
    var opened_file = try tmp.dir.openFile(io, "HEAD", .{});
    defer opened_file.close(io);
    const read = try opened(io, opened_file, (try opened_file.stat(io)).size, gpa, .packed_refs);
    defer gpa.free(read);
    try std.testing.expectEqualStrings(bytes, read);
    var head: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try table(io, .of(opened_file), &head, 5));
    try std.testing.expectEqualStrings("refs", &head);
}
