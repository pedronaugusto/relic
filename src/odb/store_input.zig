//! The object store's input seam: where the bytes of the files under
//! `objects/` that the database itself reads enter it. A loose object, a
//! pack entry streamed, a `.keep` marker and a cruft pack's `.mtimes` are
//! read here and nowhere else in the database; what reads the bytes these
//! hand back parses them as the file they are. Each read is held to a limit
//! named here: a whole file to `Limit`'s bytes, and a reader over an object
//! file to the length the object's own header states (`objectFile`).
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How much of a file a whole read takes: each read names the kind of file
/// it is.
pub const Limit = union(enum) {
    /// A `.keep` marker: git's is a line of text, relic's a header and one
    /// line per token holding the pack; a mebibyte is far past either.
    keep_marker,
    /// A cruft pack's `.mtimes`: at most these bytes, the size its pack's
    /// object count gives it (`mtimes.read` works it out).
    mtimes: aegis.units.Bytes(u64),

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return switch (limit) {
            .keep_marker => .literal("1MiB"),
            .mtimes => |most| most,
        };
    }
};

/// The file at `sub_path` under `dir`, at most `limit`'s bytes, owned by
/// the caller; one longer is `error.StreamTooLong`.
pub fn file(io: Io, dir: Io.Dir, sub_path: []const u8, gpa: Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, sub_path, gpa, limit.bytes());
}

/// A reader over an object file the database keeps (a loose object, or a
/// pack whose entry is streamed), reading ahead into `buffer`. Nothing read
/// through it is held past `buffer` and what its reader allots: an object is
/// inflated into the length its own header states, which the database
/// holds to `Options.max_object_bytes` where it keeps the object whole, and
/// a stream going on past that length is the object's corruption; a file
/// compared with another copy of it is compared a buffer at a time.
pub fn objectFile(io: Io, opened: Io.File, buffer: []u8) Io.File.Reader {
    return opened.reader(io, buffer);
}

test "a whole read past its limit fails, and one within it is the file's bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "small", .data = "MTME" });
    const bytes = try file(io, tmp.dir, "small", gpa, .{ .mtimes = .fromRaw(4) });
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("MTME", bytes);
    try std.testing.expectError(error.StreamTooLong, file(io, tmp.dir, "small", gpa, .{ .mtimes = .fromRaw(3) }));
}
