//! The diff layer's input seam: where bytes from outside enter it, each read
//! held to a limit named here. The order file `diff.orderFile` names and the
//! working-tree copy a filter writes out for an external diff are read here
//! and nowhere else in the diff layer; what reads the bytes these hand back
//! parses them as the input they are.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much a read takes: each read names the kind of input it is.
pub const Limit = enum {
    /// `diff.orderFile`: a list of path patterns, one a line.
    order_file,
    /// A blob as the working tree holds it: no larger than the object
    /// database holds an object whole by default (`max_object_bytes`).
    blob,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return switch (limit) {
            .order_file => .literal("16MiB"),
            .blob => .literal("2GiB"),
        };
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// An open file from where it stands to its end, at most `limit`'s bytes,
/// owned by the caller; the file stays the caller's to close.
pub fn opened(io: Io, handle: Io.File, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadOpenedError![]u8 {
    return aegis.own.readOpened(io, handle, gpa, limit.bytes());
}

test "a read past its limit fails, and one within it is the file's bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "order", .data = "*.h\n*.c\n" });
    const bytes = try file(std.testing.io, tmp.dir, "order", std.testing.allocator, .order_file);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("*.h\n*.c\n", bytes);
    const big = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big", .data = big });
    try std.testing.expectError(error.StreamTooLong, file(std.testing.io, tmp.dir, "big", std.testing.allocator, .order_file));
}
