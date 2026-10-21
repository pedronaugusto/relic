//! relic's receive-pack as a program, for the suite: what real git is
//! handed as `--receive-pack`, so what a push git makes to relic's server
//! does can be compared with what it does to git's own.
//!
//! It takes git's arguments: the repository's path last, and before it
//! `--stateless-rpc` (one request on standard input) and
//! `--advertise-refs` (the first message only), with the protocol version
//! from `GIT_PROTOCOL`. The refs are logged as `GIT_COMMITTER_NAME` and
//! `GIT_COMMITTER_EMAIL` at `GIT_COMMITTER_DATE` (seconds), and the hooks
//! run with this process's environment.
//!
//! `zig build test` builds this and hands the test binary its path through
//! `build_options`.

const std = @import("std");
const Io = std.Io;
const relic = @import("relic");
const pkt_line = relic.transport.pkt_line;
const local = relic.transport.local;
const receive_pack = relic.transport.receive_pack;
const protocol = relic.transport.protocol;

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
            // `--quiet`, `--skip-connectivity-check`: nothing to do differently.
        } else path = arg;
    }
    const env = init.environ_map;
    const protocol_env = env.get("GIT_PROTOCOL") orelse "";
    const version: protocol.Version = if (std.mem.find(u8, protocol_env, "version=2") != null)
        .v2
    else if (std.mem.find(u8, protocol_env, "version=1") != null) .v1 else .v0;
    const date = env.get("GIT_COMMITTER_DATE") orelse "0";
    const seconds = std.fmt.parseInt(i64, std.mem.trimStart(u8, date, "@")[0 .. std.mem.findScalar(u8, std.mem.trimStart(u8, date, "@"), ' ') orelse std.mem.trimStart(u8, date, "@").len], 10) catch 0;

    var remote = try local.Remote.open(gpa, io, path orelse return error.NoRepository, .{});
    defer remote.deinit(io);
    var server: receive_pack.Server = try .init(gpa, io, &remote, version, .{
        .stateless = stateless,
        .who = .{
            .name = env.get("GIT_COMMITTER_NAME") orelse "",
            .email = env.get("GIT_COMMITTER_EMAIL") orelse "",
            .when_secs = seconds,
            .offset_minutes = 0,
        },
        .programs = .{ .environ = env },
        .inherited_alternates = env.get("GIT_ALTERNATE_OBJECT_DIRECTORIES"),
        .service_dir = path.?,
    });
    defer server.deinit();

    const in_buffer = try arena.alloc(u8, pkt_line.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try arena.alloc(u8, pkt_line.max_line);
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
