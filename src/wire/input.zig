//! The wire layer's input seam: where bytes from outside enter it. What a
//! server, a helper program or a credential daemon says, and the files the
//! wire reads (a cookie jar, a credential store, a pinned key), come in
//! through the functions here and nowhere else in the layer; everything
//! else parses what these hand back as the untrusted input it is. A whole
//! file is held to a limit named here; a reader made here is read through
//! the parser above it, which holds each read to its own bound (a pkt-line's
//! length, a request's most, a credential's).
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// How much of a whole file a read takes: each read names the file it is.
pub const Limit = enum {
    /// `http.pinnedPubkey`'s file: curl's `MAX_PINNED_PUBKEY_SIZE`, past
    /// which the file matches nothing.
    pinned_key,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return switch (limit) {
            .pinned_key => .literal("1MiB"),
        };
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the
/// caller; one longer is `error.StreamTooLong`.
pub fn wholeFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// A reader over a file the wire reads whole, a line at a time or into
/// wiped storage: a cookie jar, a credential store's file.
pub fn file(opened: Io.File, io: Io, buffer: []u8) Io.File.Reader {
    return opened.reader(io, buffer);
}

/// A reader over what a program the conversation runs writes on its
/// standard output: `ssh`, a service run on this machine, a proxy command.
pub fn programOutput(output: Io.File, io: Io, buffer: []u8) Io.File.Reader {
    return output.readerStreaming(io, buffer);
}

/// What a program wrote on its standard error, as much as `buffer` holds
/// and is there: `error.EndOfStream` once it is all read.
pub fn programError(stderr: Io.File, io: Io, buffer: []u8) Io.File.ReadStreamingError!usize {
    return stderr.readStreaming(io, &.{buffer});
}

/// A reader over a socket: a `git://` server, a credential daemon's client,
/// or the daemon answering one.
pub fn socket(stream: Io.net.Stream, io: Io, buffer: []u8) Io.net.Stream.Reader {
    return stream.reader(io, buffer);
}

test "a whole file past its limit is refused, and one within it is its bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "small", .data = "key\n" });
    const bytes = try wholeFile(io, tmp.dir, "small", gpa, .pinned_key);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("key\n", bytes);
    const big = try gpa.alloc(u8, 1024 * 1024 + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "big", .data = big });
    try std.testing.expectError(error.StreamTooLong, wholeFile(io, tmp.dir, "big", gpa, .pinned_key));
}
