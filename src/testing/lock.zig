//! Holds a lock file the way a running git holds one, so the suite can prove
//! that a lock this package meets is reported and never broken.
//!
//! Argument one is the path to create with `O_CREAT|O_EXCL`. The process
//! creates it, writes `held` and a newline to standard output, and then blocks
//! until its standard input is closed, which is how the test lets it go. The
//! lock file is removed on the way out; a kill leaves it behind, which is the
//! stale lock the suite also tests.
//!
//! `zig build test` builds this and hands the test binary its path in
//! `RELIC_LOCK_HELPER`; the tests that need it are skipped without that.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingLockPath;

    const cwd: std.Io.Dir = .cwd();
    const file = try cwd.createFile(io, args[1], .{ .exclusive = true });
    defer {
        file.close(io);
        cwd.deleteFile(io, args[1]) catch {};
    }

    var out_buffer: [64]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    try out.interface.writeAll("held\n");
    try out.interface.flush();

    var in_buffer: [64]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    _ = in.interface.discardRemaining() catch {};
}
