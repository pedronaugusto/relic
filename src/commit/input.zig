//! The commit layer's input seam: where bytes from outside enter commits, notes and stashes,
//! each read held to a limit named here. A message file, a note a merge left to resolve and
//! a symbolic link's target are read here and nowhere else in the layer; what takes the bytes
//! these hand back parses them as the input they are.
const std = @import("std");
const aegis = @import("aegis");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A commit message: `COMMIT_EDITMSG` after the editor and the hooks, or the
    /// `commit.template` file. git reads it whole; a gigabyte is past any message.
    message,
    /// A note a notes merge left in `NOTES_MERGE_WORKTREE` to be resolved by hand,
    /// which becomes a blob: a message too, held to the same gigabyte.
    note,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .message, .note => 1 << 30,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The target of the symbolic link at `path` under `dir`, in `buf`: a path, which the
/// system holds to `buf`'s `Io.Dir.max_path_bytes`.
pub fn linkTarget(io: Io, dir: Io.Dir, path: []const u8, buf: *[Io.Dir.max_path_bytes]u8) Io.Dir.ReadLinkError![]u8 {
    const len = try dir.readLink(io, path, buf);
    return buf[0..len];
}

test "a read past its limit fails, and one within it is the file's bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "COMMIT_EDITMSG", .data = "subject\n" });
    const bytes = try file(io, tmp.dir, "COMMIT_EDITMSG", gpa, .message);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("subject\n", bytes);
    try std.testing.expectError(error.FileNotFound, file(io, tmp.dir, "missing", gpa, .note));
}
