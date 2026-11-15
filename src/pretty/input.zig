//! The pretty layer's input seam: where bytes from outside enter it, each read
//! held to a limit named here. A state file a rebase or a bisect leaves in the
//! git directory, read for the branch it names, is read here and nowhere else
//! in the pretty layer; what reads the bytes these hand back parses them as
//! the input they are.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much a read takes: each read names the kind of input it is.
pub const Limit = enum {
    /// A state file (`rebase-merge/head-name`, `BISECT_START`): a ref's
    /// name or an object id, one line.
    state_file,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return switch (limit) {
            .state_file => .literal("1MiB"),
        };
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

test "a read past its limit fails, and one within it is the file's bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "head-name", .data = "refs/heads/topic\n" });
    const bytes = try file(std.testing.io, tmp.dir, "head-name", std.testing.allocator, .state_file);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("refs/heads/topic\n", bytes);
    const big = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big", .data = big });
    try std.testing.expectError(error.StreamTooLong, file(std.testing.io, tmp.dir, "big", std.testing.allocator, .state_file));
}
