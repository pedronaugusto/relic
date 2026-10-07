//! The suite's custom transfer agent: git-lfs's protocol over its standard
//! input and output, the objects kept as files named by their SHA-256 in a
//! directory, and every line it was sent written to a log of its own, one
//! per process, so git-lfs and relic can be handed the same agent and what
//! each said to it compared.
//!
//! `relic-lfs-agent <objects-dir> <log-dir> [refuse-init]`

const std = @import("std");
const Io = std.Io;

const Message = struct {
    event: []const u8 = "",
    oid: []const u8 = "",
    size: u64 = 0,
    path: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.MissingArguments;
    const objects = args[1];
    const refuse_init = args.len > 3 and std.mem.eql(u8, args[3], "refuse-init");

    var raw: [12]u8 = undefined;
    io.random(&raw);
    const log_path = try arena.print("{s}/{x}.log", .{ args[2], &raw });
    const log = try Io.Dir.cwd().createFile(io, log_path, .{});
    defer log.close(io);
    var log_buf: [4096]u8 = undefined;
    var log_writer = log.writer(io, &log_buf);

    var in_buf: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;

    var line: Io.Writer.Allocating = .init(arena);
    while (true) {
        line.clearRetainingCapacity();
        _ = try in.interface.streamDelimiterEnding(&line.writer, '\n');
        if (in.interface.bufferedLen() == 0) return;
        in.interface.toss(1);
        try log_writer.interface.print("{s}\n", .{line.written()});
        try log_writer.interface.flush();
        const msg = try std.json.parseFromSliceLeaky(Message, arena, line.written(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (std.mem.eql(u8, msg.event, "init")) {
            try w.writeAll(if (refuse_init) "{\"error\":{\"code\":32,\"message\":\"refused by the agent\"}}\n" else "{}\n");
        } else if (std.mem.eql(u8, msg.event, "upload")) {
            const to = try arena.print("{s}/{s}", .{ objects, msg.oid });
            try Io.Dir.cwd().copyFile(msg.path, Io.Dir.cwd(), to, io, .{});
            try w.print("{{\"event\":\"progress\",\"oid\":\"{s}\",\"bytesSoFar\":{d},\"bytesSinceLast\":{d}}}\n", .{ msg.oid, msg.size, msg.size });
            try w.print("{{\"event\":\"complete\",\"oid\":\"{s}\"}}\n", .{msg.oid});
        } else if (std.mem.eql(u8, msg.event, "download")) {
            const from = try arena.print("{s}/{s}", .{ objects, msg.oid });
            const tmp = try arena.print("{s}/tmp-{s}-{x}", .{ objects, msg.oid, &raw });
            if (Io.Dir.cwd().copyFile(from, Io.Dir.cwd(), tmp, io, .{})) |_| {
                try w.print("{{\"event\":\"progress\",\"oid\":\"{s}\",\"bytesSoFar\":{d},\"bytesSinceLast\":{d}}}\n", .{ msg.oid, msg.size, msg.size });
                try w.print("{{\"event\":\"complete\",\"oid\":\"{s}\",\"path\":", .{msg.oid});
                try std.json.Stringify.value(tmp, .{}, w);
                try w.writeAll("}\n");
            } else |_| {
                try w.print("{{\"event\":\"complete\",\"oid\":\"{s}\",\"error\":{{\"code\":404,\"message\":\"no such object\"}}}}\n", .{msg.oid});
            }
        } else if (std.mem.eql(u8, msg.event, "terminate")) {
            return;
        } else return error.UnknownEvent;
        try w.flush();
    }
}
