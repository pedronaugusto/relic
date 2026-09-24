//! relic's upload-pack as a program, for the suite: what real git is handed
//! as `--upload-pack`, so a clone git makes from relic's server can be
//! compared with the one it makes from its own.
//!
//! It takes git's arguments: the repository's path last, and before it
//! `--stateless-rpc` (one request on standard input, as git's HTTP backend
//! runs it) and `--advertise-refs` (the first message only), with the
//! protocol version from `GIT_PROTOCOL` as git's own reads it.
//!
//! `zig build test` builds this and hands the test binary its path through
//! `build_options`.

const std = @import("std");
const Io = std.Io;
const pktline = @import("pktline.zig");
const local = @import("local.zig");
const uploadpack = @import("uploadpack.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stateless = false;
    var advertise_only = false;
    var path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--stateless-rpc")) {
            stateless = true;
        } else if (std.mem.eql(u8, arg, "--advertise-refs") or std.mem.eql(u8, arg, "--http-backend-info-refs")) {
            advertise_only = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // `--strict`, `--timeout=<n>`: nothing to do differently.
        } else path = arg;
    }
    const protocol_env = init.environ_map.get("GIT_PROTOCOL") orelse "";
    const version: @import("protocol.zig").Version = if (std.mem.indexOf(u8, protocol_env, "version=2") != null) .v2 else .v0;

    var remote = try local.Remote.open(gpa, io, path orelse return error.NoRepository);
    defer remote.deinit(io);
    var server: uploadpack.Server = .init(gpa, io, &remote, version, stateless, .{});

    const in_buffer = try arena.alloc(u8, pktline.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try arena.alloc(u8, pktline.max_line);
    var out = Io.File.stdout().writerStreaming(io, out_buffer);
    if (advertise_only) {
        try server.advertise(&out.interface);
        try out.interface.flush();
        return;
    }
    if (stateless) {
        try server.serveRequest(&in.interface, &out.interface);
    } else try server.serve(&in.interface, &out.interface);
    try out.interface.flush();
}
