//! The maintenance layer's input seam: where bytes from outside enter gc, repack and the
//! server info, each read held to a limit named here. A gc lock's holder, a rebase's state
//! lines and the server info files are read here and nowhere else in the layer; what takes
//! the bytes these hand back parses them as the input they are.
const std = @import("std");
const aegis = @import("aegis");
const fs = @import("../fs/fs.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = union(enum) {
    /// A rebase's `autostash` or `orig-head`: an object name and a line break.
    state_line,
    /// `objects/info/packs`: a line for each pack.
    pack_list,
    /// A file read only to compare with the `len` bytes about to replace it: one byte
    /// past them says that it differs, so no more is read.
    compared: usize,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .state_line => 4096,
            .pack_list => 1 << 24,
            .compared => |len| @as(u64, len) +| 1,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// What a `gc.pid` holds, at most: a process id, a blank and a host name.
pub const PidBuffer = [fs.max_host_name + 32]u8;

/// The `gc.pid` at `path` under `dir`, in `buf`: a longer one is cut at its size, past
/// which no holder git writes reaches.
pub fn pidFile(io: Io, dir: Io.Dir, path: []const u8, buf: *PidBuffer) Io.Dir.ReadFileError![]u8 {
    return dir.readFile(io, path, buf);
}

test "a read past its limit fails, and one within it is the file's bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "packs", .data = "P pack-1.pack\n" });
    const bytes = try file(io, tmp.dir, "packs", gpa, .pack_list);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("P pack-1.pack\n", bytes);
    try std.testing.expectError(error.StreamTooLong, file(io, tmp.dir, "packs", gpa, .{ .compared = 4 }));
}
