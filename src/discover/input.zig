//! Discovery's input seam: where the bytes of a candidate git directory's
//! small files enter it (`HEAD`, its link target, `commondir`, a `.git`
//! file), each read held to a limit named here. These files are read here
//! and nowhere else in discovery; what reads the bytes these hand back
//! parses them as the file they are.
const std = @import("std");
const Io = std.Io;

/// How much of a file a read takes: each read names the file it reads.
pub const Limit = enum {
    /// `HEAD`, a file or a link, as git's `validate_headref` reads it: its
    /// first 256 bytes, room for `ref: refs/...` or an object name of
    /// either hash.
    head,
    /// `commondir`: one path and its line end.
    commondir,
    /// A file's first byte, read to learn whether it can be read at all.
    probe,

    pub fn bytes(comptime limit: Limit) usize {
        return switch (limit) {
            .head => 256,
            .commondir => Io.Dir.max_path_bytes + 2,
            .probe => 1,
        };
    }
};

/// The target of the link at `sub_path` under `dir`, at most `limit`'s
/// bytes, read into `buffer`.
pub fn link(io: Io, dir: Io.Dir, sub_path: []const u8, comptime limit: Limit, buffer: *[limit.bytes()]u8) Io.Dir.ReadLinkError![]u8 {
    const n = try dir.readLink(io, sub_path, buffer);
    return buffer[0..n];
}

/// The file at `sub_path` under `dir`, at most `limit`'s bytes, read into
/// `buffer`.
pub fn file(io: Io, dir: Io.Dir, sub_path: []const u8, comptime limit: Limit, buffer: *[limit.bytes()]u8) Io.Dir.ReadFileError![]u8 {
    return dir.readFile(io, sub_path, buffer);
}

/// The first bytes of `opened`, at most `limit`'s, read into `buffer`.
pub fn head(io: Io, opened: Io.File, comptime limit: Limit, buffer: *[limit.bytes()]u8) Io.File.ReadPositionalError![]u8 {
    const n = try opened.readPositionalAll(io, buffer, 0);
    return buffer[0..n];
}

test "a read is the file's bytes, never more than its limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    var buffer: [Limit.head.bytes()]u8 = undefined;
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", try file(io, tmp.dir, "HEAD", .head, &buffer));
    const opened = try tmp.dir.openFile(io, "HEAD", .{});
    defer opened.close(io);
    var one: [Limit.probe.bytes()]u8 = undefined;
    try std.testing.expectEqualStrings("r", try head(io, opened, .probe, &one));
}
