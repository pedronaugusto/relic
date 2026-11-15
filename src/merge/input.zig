//! The merge layer's input seam: where bytes from outside enter it, each read
//! held to a limit named here. A conflicted file rerere reads from the working
//! tree is read here and nowhere else in the merge layer; what reads the bytes
//! these hand back parses them as the input they are.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much a read takes: each read names the kind of input it is.
pub const Limit = enum {
    /// A conflicted file in the working tree, its markers rerere names:
    /// a file past `blob_merge.max_text_size` (1023 MiB) is merged as
    /// binary data, with no markers, so 1 GiB holds every one there is.
    conflicted_file,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return switch (limit) {
            .conflicted_file => .literal("1GiB"),
        };
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

test "a read within its limit is the file's bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "conflicted", .data = "<<<<<<<\na\n=======\nb\n>>>>>>>\n" });
    const bytes = try file(std.testing.io, tmp.dir, "conflicted", std.testing.allocator, .conflicted_file);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("<<<<<<<\na\n=======\nb\n>>>>>>>\n", bytes);
}
