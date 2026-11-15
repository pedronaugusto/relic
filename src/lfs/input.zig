//! relic_lfs's input seam: where a file's bytes enter relic_lfs. An object
//! in a store (this repository's, a remote's, a reference directory's, the
//! file a custom transfer agent hands back), a working-tree file a filter
//! cleans, and a partial download kept for a resume are read here and
//! nowhere else in relic_lfs. Each read is held to a limit: a read into a
//! buffer to that buffer's length, a whole file to a limit named here, and
//! a stream to the buffer it is read through, its bytes handed on (hashed,
//! stored, sent) and never kept whole. What reads the bytes these hand back
//! checks them as the input they are: a pointer is decoded, an object is
//! hashed against its name and size.
//!
//! This is package plumbing, reached by no public name.

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How much of a file a whole read takes.
pub const Limit = enum {
    /// A working-tree file whose head reads as a pointer, kept whole by a
    /// clean as git-lfs keeps it: at most 2 GiB, the most a filter's
    /// output holds.
    pointer_file,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .pointer_file => 1 << 31,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller; one longer is `error.StreamTooLong`.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The bytes of `source` from `offset`, as many as `buffer` holds or the
/// file has: the count read, short only at the file's end.
pub fn at(io: Io, source: Io.File, buffer: []u8, offset: u64) Io.File.ReadPositionalError!usize {
    return source.readPositionalAll(io, buffer, offset);
}

/// A stream of `source` from its start, read through `buffer` (which may
/// be empty, for a reader read only by `readSliceShort` into the caller's
/// own chunk): its bytes are handed on as they come, never kept whole.
pub fn stream(io: Io, source: Io.File, buffer: []u8) Io.File.Reader {
    return source.reader(io, buffer);
}

test "a read into a buffer takes what fits, a stream reads all, and a whole read is the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "object", .data = "hello world\n" });
    const opened = try tmp.dir.openFile(io, "object", .{});
    defer opened.close(io);
    var head: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try at(io, opened, &head, 6));
    try std.testing.expectEqualStrings("world", &head);
    var buf: [4]u8 = undefined;
    var r = stream(io, opened, &buf);
    var all: [12]u8 = undefined;
    try r.interface.readSliceAll(&all);
    try std.testing.expectEqualStrings("hello world\n", &all);
    const whole = try file(io, tmp.dir, "object", std.testing.allocator, .pointer_file);
    defer std.testing.allocator.free(whole);
    try std.testing.expectEqualStrings("hello world\n", whole);
}
