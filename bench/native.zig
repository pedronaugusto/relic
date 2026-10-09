//! Native cached-process round trips, timed through shakedown.bench.
//! Startup and shutdown are outside the clock; each measured request must
//! return identical bytes. --smoke checks the protocol without timing.
const std = @import("std");
const Io = std.Io;
const api = @import("relic").api;
const connection = api.transport.connection;
const benchmark = @import("shakedown").bench;

const Context = struct {
    conn: *connection.Connection,
    io: Io,
    checksum: u64 = 0,
    fn run(c: *Context, units: u64) !void {
        const request = &@as([256]u8, @splat('R'));
        for (0..units) |_| {
            const streams = try connection.Process.streams(c.conn, c.io);
            try streams.writer.writeAll(request);
            try streams.writer.flush();
            var answer: [256]u8 = undefined;
            try streams.reader.readSliceAll(&answer);
            if (!std.mem.eql(u8, request, &answer)) return error.WrongAnswer;
            c.checksum +%= answer[0];
        }
    }
};

fn echo(io: Io) !void {
    var in_buffer: [4096]u8 = undefined;
    var input = Io.File.stdin().readerStreaming(io, &in_buffer);
    var out_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(io, &out_buffer);
    while (true) {
        var bytes: [256]u8 = undefined;
        const n = try input.interface.readSliceShort(&bytes);
        if (n == 0) return;
        if (n != bytes.len) return error.ShortRequest;
        try output.interface.writeAll(&bytes);
        try output.interface.flush();
    }
}

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.run)).@"fn".return_type.?).error_union.error_set;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--echo")) return echo(io);
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var env = try init.minimal.environ.createMap(gpa);
    defer env.deinit();
    const executable = try Io.Dir.cwd().realPathFileAlloc(io, args[0], gpa);
    defer gpa.free(executable);
    const conn = try connection.Process.start(gpa, io, .{ .environ = &env }, .{ .argv = &.{ executable, "--echo" } });
    defer conn.deinit(io);
    var context: Context = .{ .conn = conn, .io = io };
    var out_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &out_buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){.{ .name = "native_cached_roundtrip_256", .unit = "roundtrip", .initial = 64, .run = Context.run }};
    try benchmark.run(WorkloadError, gpa, io, &output.interface, &context, &rows, .{ .commit = if (!smoke and args.len > 1) args[1] else "work-in-progress" }, .{ .smoke = smoke, .samples = 11, .minimum = .fromMilliseconds(5) });
    try output.interface.flush();
    if (context.checksum == 0) return error.NoWork;
}
