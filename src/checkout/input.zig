//! The working tree layer's input seam: where bytes from outside enter it, each read held to
//! a limit named here. A working-tree file's contents, a symbolic link's target, a worktree's
//! `gitdir` file, and the readers over a working-tree file, a filter program's output and the
//! fsmonitor daemon's connection are made here and nowhere else in `src/checkout`; what reads
//! the bytes these hand back parses them as the input they are.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How much of a file a whole read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A working-tree file read whole to be stored, hashed or compared: 2 GiB. A file past
    /// `core.bigFileThreshold` is streamed instead, so this is the most a read ever holds.
    blob,
    /// A worktree's `gitdir` file read for the path it names: a path, 4096 bytes.
    gitdir,
    /// A worktree's `gitdir` file read to judge it for pruning: 1 MiB, so a file too long to
    /// name a path is judged rather than stopping the prune.
    gitdir_judged,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .blob => 1 << 31,
            .gitdir => 4096,
            .gitdir_judged => 1 << 20,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The longest symbolic link target read: `PATH_MAX`, as git reads one (`strbuf_readlink`
/// gives up past it).
pub const max_link_len = 4096;

/// The target of the symbolic link at `path` under `dir`, in `buffer`.
pub fn link(io: Io, dir: Io.Dir, path: []const u8, buffer: *[max_link_len]u8) Io.Dir.ReadLinkError![]u8 {
    const len = try dir.readLink(io, path, buffer);
    return buffer[0..len];
}

/// A reader over an open working-tree file (or a file a filter wrote), positioned: what it
/// holds at once is `buffer`, and its caller reads the length the file's stat stated, or
/// streams it on to where it is written.
pub fn fileReader(io: Io, from: Io.File, buffer: []u8) Io.File.Reader {
    return from.reader(io, buffer);
}

/// A reader over a pipe, a filter program's output or the daemon's named pipe: what it holds at
/// once is `buffer`, and the protocol read through it (pkt-line) bounds each packet.
pub fn pipeReader(io: Io, from: Io.File, buffer: []u8) Io.File.Reader {
    return from.readerStreaming(io, buffer);
}

/// A reader over the fsmonitor daemon's socket: what it holds at once is `buffer`, and the
/// pkt-line protocol read through it bounds each packet.
pub fn streamReader(io: Io, from: Io.net.Stream, buffer: []u8) Io.net.Stream.Reader {
    return from.reader(io, buffer);
}

test "a read past its limit fails, and a link's target is the link's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "gitdir", .data = "/somewhere/.git\n" });
    const bytes = try file(io, tmp.dir, "gitdir", std.testing.allocator, .gitdir);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("/somewhere/.git\n", bytes);
    const big = try std.testing.allocator.alloc(u8, 4097);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "long", .data = big });
    try std.testing.expectError(error.StreamTooLong, file(io, tmp.dir, "long", std.testing.allocator, .gitdir));
    if (@import("builtin").os.tag == .windows) return;
    try tmp.dir.symLink(io, "gitdir", "pointer", .{});
    var buffer: [max_link_len]u8 = undefined;
    try std.testing.expectEqualStrings("gitdir", try link(io, tmp.dir, "pointer", &buffer));
}
