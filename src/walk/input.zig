//! The walk's input seam: where bytes from outside enter the walk layer,
//! each read held to a limit named here. A file's contents are read here
//! and nowhere else in `walk/`; what reads the bytes these hand back parses
//! them as the input they are.

const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// `shallow`: one object name to a line, a boundary commit each. A
    /// GiB holds tens of millions of them, past any history's boundary.
    shallow,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .shallow => 1 << 30,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller and freed with `gpa`.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

test "a read within its limit is the file's bytes, and a file not there is FileNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shallow", .data = "boundary\n" });
    const bytes = try file(std.testing.io, tmp.dir, "shallow", std.testing.allocator, .shallow);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("boundary\n", bytes);
    try std.testing.expectError(error.FileNotFound, file(std.testing.io, tmp.dir, "absent", std.testing.allocator, .shallow));
}
