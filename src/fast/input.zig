//! fast-import and fast-export's input seam for the files they read: a marks
//! file enters here, held to the limit named here, and nowhere else in the
//! layer; what reads the bytes it hands back parses them as the marks they
//! are. The stream itself is the caller's reader, which the importer parses
//! a command at a time.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A marks file (`--import-marks`, `--export-marks`, the stream's
    /// `feature import-marks`): a line of a mark and an object name per
    /// object, under a hundred bytes, so 4 GiB holds tens of millions of
    /// objects, past any repository.
    marks,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .marks => 4 << 30,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

test "a marks file is read whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marks", .data = ":1 0123\n" });
    const bytes = try file(std.testing.io, tmp.dir, "marks", std.testing.allocator, .marks);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(":1 0123\n", bytes);
}
