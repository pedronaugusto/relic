//! Native process fixtures for testing input, output, exit status, and
//! the caller-owned spawn hook on every supported platform.

const std = @import("std");
const Io = std.Io;

/// Exercise process input, output, and status behavior for the test suite.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingMode;
    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = Io.File.stderr().writerStreaming(io, &err_buf);
    if (std.mem.eql(u8, args[1], "closed-output")) {
        Io.File.stdout().close(io);
        Io.File.stderr().close(io);
        try io.sleep(.fromSeconds(1), .awake);
        return;
    } else if (std.mem.eql(u8, args[1], "opposite-pipes")) {
        // End a broken implementation's deadlock without leaving a child
        // behind. A working runner drains output while it feeds input.
        const Guard = struct {
            fn stop(guard_io: Io) void {
                guard_io.sleep(.fromSeconds(1), .awake) catch return;
                std.process.exit(7);
            }
        };
        var guard = try io.concurrent(Guard.stop, .{io});
        defer guard.cancel(io);
        const block = "x" ** 1024;
        for (0..4096) |_| try out.interface.writeAll(block);
        try out.interface.flush();
        var in_buf: [4096]u8 = undefined;
        var in = Io.File.stdin().readerStreaming(io, &in_buf);
        _ = try in.interface.discardRemaining();
    } else if (std.mem.eql(u8, args[1], "copy")) {
        var in_buf: [4096]u8 = undefined;
        var in = Io.File.stdin().readerStreaming(io, &in_buf);
        _ = try in.interface.streamRemaining(&out.interface);
    } else if (std.mem.eql(u8, args[1], "upper") or std.mem.eql(u8, args[1], "lower") or
        std.mem.eql(u8, args[1], "tag") or std.mem.eql(u8, args[1], "drop-first-line") or
        std.mem.eql(u8, args[1], "crlf"))
    {
        var input: std.ArrayList(u8) = .empty;
        var in_buf: [4096]u8 = undefined;
        var in = Io.File.stdin().readerStreaming(io, &in_buf);
        try in.interface.appendRemainingUnlimited(init.arena.allocator(), &input);
        if (std.mem.eql(u8, args[1], "upper")) {
            for (input.items) |*byte| byte.* = std.ascii.toUpper(byte.*);
            try out.interface.writeAll(input.items);
        } else if (std.mem.eql(u8, args[1], "lower")) {
            for (input.items) |*byte| byte.* = std.ascii.toLower(byte.*);
            try out.interface.writeAll(input.items);
        } else if (std.mem.eql(u8, args[1], "tag")) {
            if (args.len < 3) return error.MissingPath;
            try out.interface.print("path={s}\n", .{args[2]});
            try out.interface.writeAll(input.items);
        } else if (std.mem.eql(u8, args[1], "drop-first-line")) {
            if (std.mem.findScalar(u8, input.items, '\n')) |at| try out.interface.writeAll(input.items[at + 1 ..]);
        } else {
            var start: usize = 0;
            while (start < input.items.len) {
                const end = std.mem.findScalarPos(u8, input.items, start, '\n') orelse input.items.len;
                const line = std.mem.trimEnd(u8, input.items[start..end], "\r");
                try out.interface.print("{s}\r\n", .{line});
                start = if (end == input.items.len) end else end + 1;
            }
        }
    } else if (std.mem.eql(u8, args[1], "streams")) {
        try out.interface.writeAll("out\n");
        try err.interface.writeAll("err\n");
    } else if (std.mem.eql(u8, args[1], "stderr")) {
        try err.interface.writeAll("err\n");
    } else if (std.mem.eql(u8, args[1], "bytes")) {
        const block = "x" ** 1024;
        for (0..100) |_| try out.interface.writeAll(block);
    } else if (std.mem.eql(u8, args[1], "reject-filter")) {
        try err.interface.writeAll("nope\n");
    } else if (std.mem.eql(u8, args[1], "touch")) {
        for (args[2..]) |name| {
            const file = try Io.Dir.cwd().createFile(io, name, .{});
            file.close(io);
        }
    } else if (std.mem.eql(u8, args[1], "copy-file")) {
        if (args.len < 4) return error.MissingPath;
        const contents = try Io.Dir.cwd().readFileAlloc(io, args[2], init.arena.allocator(), .limited(1 << 20));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = contents });
    } else if (std.mem.eql(u8, args[1], "fsmonitor")) {
        // A file monitor's hook, run in the working tree with a version and
        // a token: each question is logged to `.git/fsmonitor-log`, and the
        // answer is `.git/fsmonitor-v<version>`, or a failure without one.
        if (args.len < 4) return error.MissingPath;
        const arena = init.arena.allocator();
        const cwd = Io.Dir.cwd();
        const log = cwd.readFileAlloc(io, ".git/fsmonitor-log", arena, .limited(1 << 20)) catch "";
        try cwd.writeFile(io, .{ .sub_path = ".git/fsmonitor-log", .data = try std.fmt.allocPrint(arena, "{s}{s} {s}\n", .{ log, args[2], args[3] }) });
        const answer_path = try std.fmt.allocPrint(arena, ".git/fsmonitor-v{s}", .{args[2]});
        const answer = cwd.readFileAlloc(io, answer_path, arena, .limited(1 << 20)) catch std.process.exit(1);
        try out.interface.writeAll(answer);
    } else if (std.mem.eql(u8, args[1], "record")) {
        // What it was handed on its standard input, kept at a path, as a
        // credential helper or an upload-pack that must not have run
        // leaves nothing.
        if (args.len < 3) return error.MissingPath;
        var input: std.ArrayList(u8) = .empty;
        var in_buf: [4096]u8 = undefined;
        var in = Io.File.stdin().readerStreaming(io, &in_buf);
        try in.interface.appendRemainingUnlimited(init.arena.allocator(), &input);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = input.items });
    } else if (std.mem.eql(u8, args[1], "args")) {
        // Each argument as it arrived, each ended by a NUL: what a
        // command line quoted for this platform came back as.
        for (args[2..]) |arg| {
            try out.interface.writeAll(arg);
            try out.interface.writeByte(0);
        }
    } else if (!std.mem.eql(u8, args[1], "fail") and !std.mem.eql(u8, args[1], "silent")) return error.InvalidMode;
    try out.interface.flush();
    try err.interface.flush();
    if (std.mem.eql(u8, args[1], "fail")) std.process.exit(1);
    if (std.mem.eql(u8, args[1], "reject-filter")) std.process.exit(3);
    if (args.len > 2 and (std.mem.eql(u8, args[1], "streams") or std.mem.eql(u8, args[1], "stderr")))
        std.process.exit(try std.fmt.parseUnsigned(u8, args[2], 10));
}
