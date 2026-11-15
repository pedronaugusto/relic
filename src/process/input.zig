//! The process layer's input seam: where the bytes of a program's own file
//! enter it, each read held to a limit named here. A program's file is read
//! here and nowhere else in the layer; what reads the bytes these hand back
//! parses them as the file they are.
const std = @import("std");
const Io = std.Io;

/// How much of a program's file a read takes: each read names why it reads.
pub const Limit = enum {
    /// The `#!` line git for Windows' `parse_interpreter` reads to start a
    /// script through its interpreter: its first 99 bytes.
    interpreter,

    pub fn bytes(comptime limit: Limit) usize {
        return switch (limit) {
            .interpreter => 99,
        };
    }
};

/// The first bytes of `file`, at most `limit`'s, read into `buffer`.
pub fn head(io: Io, file: Io.File, comptime limit: Limit, buffer: *[limit.bytes()]u8) Io.File.ReadPositionalError![]u8 {
    const n = try file.readPositionalAll(io, buffer, 0);
    return buffer[0..n];
}

test "a head is the file's first bytes, never more than its limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const long: [200]u8 = @splat('x');
    try tmp.dir.writeFile(io, .{ .sub_path = "script", .data = &long });
    const file = try tmp.dir.openFile(io, "script", .{});
    defer file.close(io);
    var buffer: [Limit.interpreter.bytes()]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 99), (try head(io, file, .interpreter, &buffer)).len);
}
