//! The repository layer's input seam: where bytes from outside enter it,
//! each read held to a limit named here. A template's files and links, and
//! the index's trailing checksum, are read here and nowhere else in the
//! layer; what reads the bytes these hand back takes them as what they are.
//! Package plumbing, reached by no public name.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A file of a `git init` template, copied whole: a hook script or a
    /// description, which git copies whatever its size; 1 GiB keeps a
    /// stray file from taking all memory.
    template_file,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .template_file => 1 << 30,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The target of the symbolic link at `path` under `dir`, in `buffer`,
/// which holds the longest path the platform has.
pub fn link(io: Io, dir: Io.Dir, path: []const u8, buffer: *[Io.Dir.max_path_bytes]u8) Io.Dir.ReadLinkError![]u8 {
    return buffer[0..try dir.readLink(io, path, buffer)];
}

/// `buffer.len` bytes of `from` at `offset`: a fixed-size field such as
/// the checksum an index ends with. Fewer where the file ends first.
pub fn at(io: Io, from: Io.File, buffer: []u8, offset: u64) Io.File.ReadPositionalError![]u8 {
    return buffer[0..try from.readPositionalAll(io, buffer, offset)];
}
