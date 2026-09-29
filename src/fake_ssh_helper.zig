//! A native stand-in for ssh in the test suite. It records the original
//! arguments, answers git's configuration probe, and runs the remote command
//! locally with its standard streams inherited.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Answer an SSH probe or run the requested Git service locally.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 0) return error.MissingProgramName;
    const executable = try std.process.executablePathAlloc(io, arena);
    const stem = if (std.ascii.endsWithIgnoreCase(executable, ".exe")) executable[0 .. executable.len - 4] else executable;
    const fixture_path = try std.fmt.allocPrint(arena, "{s}.fixture", .{executable});
    const fixture = Io.Dir.cwd().readFileAlloc(io, fixture_path, arena, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const mode = std.mem.sliceTo(fixture, '\n');
    const message = if (mode.len < fixture.len) std.mem.trimEnd(u8, fixture[mode.len + 1 ..], "\r\n") else "";
    const log_name = try std.fmt.allocPrint(arena, "{s}.log", .{stem});
    const log = try Io.Dir.cwd().createFile(io, log_name, .{ .truncate = false, .read = true });
    defer log.close(io);
    var entry: std.ArrayList(u8) = .empty;
    for (args[1..]) |arg| try entry.print(arena, "[{s}]", .{arg});
    if (std.mem.eql(u8, mode, "auth") or std.mem.eql(u8, mode, "refuse")) {
        try entry.print(arena, " agent={s} home={s}", .{
            init.environ_map.get("SSH_AUTH_SOCK") orelse "",
            init.environ_map.get("HOME") orelse "",
        });
    }
    try entry.append(arena, '\n');
    try log.writePositionalAll(io, entry.items, try log.length(io));
    if (std.mem.eql(u8, mode, "warn") or std.mem.eql(u8, mode, "refuse")) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writerStreaming(io, &stderr_buf);
        try stderr.interface.print("{s}\n", .{message});
        try stderr.interface.flush();
        if (std.mem.eql(u8, mode, "refuse")) std.process.exit(255);
    }

    var at: usize = 1;
    while (at < args.len) {
        const arg = args[at];
        if (std.mem.eql(u8, arg, "-G")) return;
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "-P") or
            std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "-J") or std.mem.eql(u8, arg, "-F"))
        {
            at += 2;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            at += 1;
        } else break;
    }
    if (at >= args.len) return;
    at += 1; // The host is deliberately ignored.
    if (at >= args.len) return;

    var line: std.ArrayList(u8) = .empty;
    for (args[at..], 0..) |arg, i| {
        if (i != 0) try line.append(arena, ' ');
        try line.appendSlice(arena, arg);
    }
    const words = try parseWords(arena, line.items);
    if (words.len == 0) return;
    var command: std.ArrayList([]const u8) = .empty;
    if (std.mem.startsWith(u8, words[0], "git-") and
        (std.mem.eql(u8, words[0], "git-upload-pack") or
            std.mem.eql(u8, words[0], "git-receive-pack") or
            std.mem.eql(u8, words[0], "git-upload-archive")))
    {
        try command.appendSlice(arena, &.{ "git", words[0]["git-".len..] });
        try command.appendSlice(arena, words[1..]);
    } else try command.appendSlice(arena, words);
    if (std.mem.eql(u8, words[0], "git-lfs-transfer")) {
        const sibling = try std.fs.path.join(arena, &.{ std.fs.path.dirname(executable) orelse ".", if (builtin.os.tag == .windows) "git-lfs-transfer.exe" else "git-lfs-transfer" });
        if (Io.Dir.cwd().openFile(io, sibling, .{})) |file| {
            file.close(io);
            command.items[0] = sibling;
        } else |_| {}
    }
    const capture_sidecar = try std.fmt.allocPrint(arena, "{s}.capture", .{executable});
    const capture = Io.Dir.cwd().readFileAlloc(io, capture_sidecar, arena, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var child = std.process.spawn(io, .{ .argv = command.items, .environ_map = init.environ_map, .stdin = if (capture == null) .inherit else .pipe }) catch |err| {
        if (err == error.FileNotFound) std.process.exit(127);
        return err;
    };
    defer child.kill(io);
    var feeding: ?Io.Future(void) = null;
    if (capture) |path| {
        const pipe = child.stdin.?;
        child.stdin = null;
        feeding = try io.concurrent(teeStdin, .{ io, pipe, path });
    }
    defer if (feeding) |*task| task.cancel(io);
    const term = try child.wait(io);
    if (feeding) |*task| task.await(io);
    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(255),
    }
}

fn teeStdin(io: Io, pipe: Io.File, path: []const u8) void {
    defer pipe.close(io);
    const log = Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true }) catch return;
    defer log.close(io);
    var input_buf: [8192]u8 = undefined;
    var input = Io.File.stdin().readerStreaming(io, &input_buf);
    var pipe_buf: [8192]u8 = undefined;
    var output = pipe.writerStreaming(io, &pipe_buf);
    while (true) {
        input.interface.fillMore() catch break;
        const chunk = input.interface.buffered();
        if (chunk.len == 0) break;
        log.writePositionalAll(io, chunk, log.length(io) catch return) catch return;
        output.interface.writeAll(chunk) catch return;
        output.interface.flush() catch return;
        input.interface.tossBuffered();
    }
}

fn parseWords(arena: Allocator, line: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    const Quote = enum { none, single, double };
    var quote: Quote = .none;
    var began = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote == .none and (c == ' ' or c == '\t')) {
            if (began) {
                try words.append(arena, try word.toOwnedSlice(arena));
                began = false;
            }
            continue;
        }
        if (c == '\'' and quote != .double) {
            quote = if (quote == .single) .none else .single;
            began = true;
            continue;
        }
        if (c == '"' and quote != .single) {
            quote = if (quote == .double) .none else .double;
            began = true;
            continue;
        }
        if (c == '\\' and quote != .single and i + 1 < line.len and
            (line[i + 1] == '\\' or line[i + 1] == '\'' or line[i + 1] == '"' or line[i + 1] == ' '))
        {
            i += 1;
            try word.append(arena, line[i]);
            began = true;
            continue;
        }
        try word.append(arena, c);
        began = true;
    }
    if (quote != .none) return error.UnclosedQuote;
    if (began) try words.append(arena, try word.toOwnedSlice(arena));
    return words.toOwnedSlice(arena);
}
