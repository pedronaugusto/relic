//! The hooks' input seam: where the bytes of a hook's own file enter them,
//! each read held to a limit named here. A hook's file is read here and
//! nowhere else in the hooks; what reads the bytes these hand back parses
//! them as the file they are.
const std = @import("std");
const Io = std.Io;

/// How much of a hook's file a read takes: each read names why it reads.
pub const Limit = enum {
    /// Whether the hook is git-lfs's own: its hooks are a few lines, so a
    /// file past 1024 bytes is another's, and the byte past that says so.
    lfs_hook,
    /// The `#!` that marks a script, which Windows starts through its
    /// interpreter.
    shebang,

    pub fn bytes(comptime limit: Limit) usize {
        return switch (limit) {
            .lfs_hook => 1025,
            .shebang => 2,
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
    try tmp.dir.writeFile(io, .{ .sub_path = "hook", .data = "#!/bin/sh\n" });
    const file = try tmp.dir.openFile(io, "hook", .{});
    defer file.close(io);
    var buffer: [Limit.shebang.bytes()]u8 = undefined;
    try std.testing.expectEqualStrings("#!", try head(io, file, .shebang, &buffer));
    var whole: [Limit.lfs_hook.bytes()]u8 = undefined;
    try std.testing.expectEqualStrings("#!/bin/sh\n", try head(io, file, .lfs_hook, &whole));
}
