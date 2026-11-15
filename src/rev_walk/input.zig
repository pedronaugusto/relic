//! The history walks' input seam: where the files they read from a
//! repository or a working tree enter them (a bisect's state, a mailmap),
//! each read held to a limit named here, and nowhere else in the layer;
//! what reads the bytes these hand back parses them as the file they are.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A bisect's own state (`BISECT_START`, `BISECT_TERMS`, `BISECT_LOG`
    /// and the rest): a name, its terms, and a line per step taken, which a
    /// bisect of any history keeps far under 64 MiB.
    bisect,
    /// A `.mailmap` or `mailmap.file`: a line per identity mapped, which the
    /// largest projects' keep in a few MiB.
    mailmap,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .bisect => 64 << 20,
            .mailmap => 256 << 20,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

test "a file is read whole within its limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "BISECT_TERMS", .data = "bad\ngood\n" });
    const bytes = try file(std.testing.io, tmp.dir, "BISECT_TERMS", std.testing.allocator, .bisect);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("bad\ngood\n", bytes);
}
