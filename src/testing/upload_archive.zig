//! relic's upload-archive as a program, for the suite: what real git is
//! handed as `git archive --remote=<path> --exec=<this>`, so the archive
//! git receives from relic's server can be compared with the one it
//! receives from its own.
//!
//! It takes git's arguments: the repository's path.
//!
//! `zig build test` builds this and hands the test binary its path through
//! `build_options`.

const std = @import("std");
const Io = std.Io;
const pkt_line = @import("relic").transport.pkt_line;
const local = @import("relic").transport.local;
const remote = @import("relic").archive.remote;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.NoRepository;

    var here = try local.Remote.open(gpa, io, args[1], .{});
    defer here.deinit(io);

    const in_buffer = try arena.alloc(u8, pkt_line.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try arena.alloc(u8, pkt_line.max_line);
    var out = Io.File.stdout().writerStreaming(io, out_buffer);
    var server: remote.Server = .{ .gpa = gpa, .io = io, .repo = &here.repo, .options = .{
        .programs = .{ .environ = init.environ_map },
        .now = Io.Clock.real.now(io),
    } };
    const served = try server.serve(&out.interface, &in.interface);
    try out.interface.flush();
    if (served == .refused) {
        var err_buffer: [256]u8 = undefined;
        var err = Io.File.stderr().writerStreaming(io, &err_buffer);
        try err.interface.print("fatal: sent error to the client: {s}\n", .{remote.died});
        try err.interface.flush();
        std.process.exit(128);
    }
}
