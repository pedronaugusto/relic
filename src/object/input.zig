//! The object layer's input seam: where a file's bytes enter it, each read
//! held to a limit named here. An `fsck.skipList` and the message file
//! `git interpret-trailers` is given are read here and nowhere else in the
//! layer; what takes the bytes these hand back parses them as the text they
//! are.

const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// An `fsck.skipList`: one object name a line, with comments. git reads
    /// it whole; a gigabyte is some twenty million names.
    skip_list,
    /// A commit message read from a file, as `git interpret-trailers <file>`
    /// reads it whole: a gigabyte, past any message git's own tools write.
    message,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .skip_list, .message => 1 << 30,
        });
    }
};

/// The errors of a read: the file's own, and `error.StreamTooLong` for one
/// past its limit.
pub const FileError = aegis.own.ReadFileError;

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) FileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

test "a read within its limit is the file's bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "list", .data = "# none\n" });
    const bytes = try file(std.testing.io, tmp.dir, "list", std.testing.allocator, .skip_list);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("# none\n", bytes);
    try std.testing.expectError(error.FileNotFound, file(std.testing.io, tmp.dir, "absent", std.testing.allocator, .message));
}
