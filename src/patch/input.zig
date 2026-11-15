//! The patch layer's input seam: where bytes from outside enter it, each read
//! held to a limit named here. The working tree's copy of a path a patch
//! applies to (a file's bytes or a symbolic link's target) and the signature
//! file `format.signatureFile` names are read here and nowhere else in the
//! patch layer; what reads the bytes these hand back parses them as the input
//! they are.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much a read takes: each read names the kind of input it is.
pub const Limit = enum {
    /// A file of the working tree, read whole as the blob it would be
    /// stored as: no larger than the object database holds an object
    /// whole by default (`max_object_bytes`).
    worktree_file,
    /// `format.signatureFile`: the lines that end a patch mail.
    signature,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return switch (limit) {
            .worktree_file => .literal("2GiB"),
            .signature => .literal("1MiB"),
        };
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The target of the symbolic link at `path` under `dir`, in `buf`, whose
/// length is the limit: a longer target is `error.NameTooLong`.
pub fn link(io: Io, dir: Io.Dir, path: []const u8, buf: []u8) Io.Dir.ReadLinkError![]u8 {
    const n = try dir.readLink(io, path, buf);
    return buf[0..n];
}

test "a read past its limit fails, and one within it is the file's bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "signature", .data = "-- \nA. U. Thor\n" });
    const bytes = try file(std.testing.io, tmp.dir, "signature", std.testing.allocator, .signature);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("-- \nA. U. Thor\n", bytes);
    const big = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big", .data = big });
    try std.testing.expectError(error.StreamTooLong, file(std.testing.io, tmp.dir, "big", std.testing.allocator, .signature));
}
