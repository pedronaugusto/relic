//! The transport's input seam: where bytes from outside enter the push, the
//! fetch and the serving of either. A file read whole is held to a limit
//! named here; a reader over a program's output (a hook's, a helper's,
//! pack-objects') or over a file that holds a pack or a bundle is made
//! here, and what reads it (pkt-line, the bundle header, the pack indexer)
//! is the parse that holds it to its own limits. Nothing else in the
//! transport makes a reader over a file or a pipe, or reads a file whole.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much of a file a whole read takes: each read names the kind of
/// file it is.
pub const Limit = enum {
    /// A bundle list in config format, downloaded from a bundle URI: as
    /// much as a bundle file may be read for.
    bundle_list,
    /// A record a test wrote or a tool it ran made (a key, a hook's log):
    /// small text.
    test_record,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .bundle_list => 1 << 30,
            .test_record => 1024 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// A reader over what a program writes on `from` (a hook's or
/// pack-objects' output), read as it comes.
pub fn pipe(from: Io.File, io: Io, buffer: []u8) Io.File.Reader {
    return from.readerStreaming(io, buffer);
}

/// A reader over the file `opened`, from its start: a bundle, a pack a
/// download wrote, or a repository's file served as it is.
pub fn stored(opened: Io.File, io: Io, buffer: []u8) Io.File.Reader {
    return opened.reader(io, buffer);
}

/// What a program says on its error output, one read of it into `buffer`
/// as it comes: how many bytes, which may be none short of the end (std
/// allows a read of zero). Null where the program's words end: at the end
/// of the pipe, at a read that fails, or at a cancel, each of which ends a
/// relay of them as git's `copy_to_sideband` ends one.
pub fn said(from: Io.File, io: Io, buffer: []u8) ?usize {
    return from.readStreaming(io, &.{buffer}) catch null;
}
