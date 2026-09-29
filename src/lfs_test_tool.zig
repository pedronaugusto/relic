//! Native stand-ins for the credential, authenticate, and transfer programs
//! used by the LFS tests. A `.fixture` beside a copy gives it its arguments.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Run the credential, askpass, authentication, or transfer action in the sidecar.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 0) return error.MissingProgramName;
    const executable = try std.process.executablePathAlloc(io, arena);
    const stem = if (std.ascii.endsWithIgnoreCase(executable, ".exe")) executable[0 .. executable.len - 4] else executable;
    const sidecar = try std.fmt.allocPrint(arena, "{s}.fixture", .{executable});
    const description = try Io.Dir.cwd().readFileAlloc(io, sidecar, arena, .limited(16 << 10));
    var fields = std.mem.splitScalar(u8, description, '\n');
    const kind = fields.next() orelse return error.InvalidFixture;

    if (std.mem.eql(u8, kind, "askpass")) {
        const prompt = if (args.len > 1) args[1] else "";
        try appendLog(io, arena, stem, try std.fmt.allocPrint(arena, "{s}\n", .{prompt}));
        var buf: [4096]u8 = undefined;
        var out = Io.File.stdout().writerStreaming(io, &buf);
        try out.interface.writeAll(if (std.mem.startsWith(u8, prompt, "Username")) "ada\n" else "secret\n");
        try out.interface.flush();
    } else if (std.mem.eql(u8, kind, "credential") or std.mem.eql(u8, kind, "credential-verbatim") or std.mem.eql(u8, kind, "credential-person") or std.mem.eql(u8, kind, "password")) {
        const person_path = if (std.mem.eql(u8, kind, "credential-person")) fields.next() orelse "" else "";
        const person_stem = if (person_path.len == 0) stem else person_path;
        const user = if (std.mem.eql(u8, kind, "credential-person")) "" else fields.next() orelse return error.InvalidFixture;
        const password = if (std.mem.eql(u8, kind, "password") or std.mem.eql(u8, kind, "credential-person")) user else fields.next() orelse return error.InvalidFixture;
        const operation = if (args.len > 1) args[if (std.mem.eql(u8, kind, "credential-person")) args.len - 1 else 1] else "";
        if (std.mem.eql(u8, kind, "credential-person") and std.mem.eql(u8, operation, "relic-probe")) {
            var probe_buf: [64]u8 = undefined;
            var probe = Io.File.stdout().writerStreaming(io, &probe_buf);
            try probe.interface.writeAll("stand-in\n");
            try probe.interface.flush();
            return;
        }
        var input: std.ArrayList(u8) = .empty;
        var stdin_buf: [4096]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        try stdin.interface.appendRemainingUnlimited(arena, &input);
        var log_entry: std.ArrayList(u8) = .empty;
        try log_entry.print(arena, "== {s}\n", .{operation});
        var lines = std.mem.splitScalar(u8, input.items, '\n');
        if (std.mem.eql(u8, kind, "password") or std.mem.eql(u8, kind, "credential-person")) {
            try log_entry.appendSlice(arena, input.items);
        } else if (std.mem.eql(u8, kind, "credential-verbatim")) {
            var entries: std.ArrayList([]const u8) = .empty;
            while (lines.next()) |line| {
                if (line.len == 0) break;
                try entries.append(arena, line);
            }
            std.mem.sort([]const u8, entries.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            for (entries.items) |line| try log_entry.print(arena, "{s}\n", .{line});
        } else {
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "protocol=") or
                    std.mem.startsWith(u8, line, "host=") or
                    std.mem.startsWith(u8, line, "username=") or
                    std.mem.startsWith(u8, line, "password=") or
                    std.mem.startsWith(u8, line, "path="))
                {
                    try log_entry.print(arena, "{s}\n", .{line});
                }
            }
        }
        try appendLog(io, arena, person_stem, log_entry.items);
        if (std.mem.eql(u8, operation, "get")) {
            var buf: [4096]u8 = undefined;
            var out = Io.File.stdout().writerStreaming(io, &buf);
            if (std.mem.eql(u8, kind, "password")) {
                try out.interface.print("password={s}\n", .{password});
            } else if (std.mem.eql(u8, kind, "credential-person")) {
                const answer_path = try std.fmt.allocPrint(arena, "{s}.answer", .{person_stem});
                const answer = try Io.Dir.cwd().readFileAlloc(io, answer_path, arena, .limited(16 << 10));
                try out.interface.writeAll(answer);
            } else try out.interface.print("username={s}\npassword={s}\n", .{ user, password });
            try out.interface.flush();
        }
    } else if (std.mem.eql(u8, kind, "authenticate")) {
        const href = fields.next() orelse return error.InvalidFixture;
        const token = fields.next() orelse return error.InvalidFixture;
        const expiry = fields.next() orelse return error.InvalidFixture;
        var log_entry: std.ArrayList(u8) = .empty;
        for (args[1..], 0..) |arg, i| {
            if (i != 0) try log_entry.append(arena, ' ');
            try log_entry.appendSlice(arena, arg);
        }
        try log_entry.append(arena, '\n');
        try appendLog(io, arena, stem, log_entry.items);
        var buf: [4096]u8 = undefined;
        var out = Io.File.stdout().writerStreaming(io, &buf);
        try out.interface.print("{{\"href\":\"{s}\",\"header\":{{\"Authorization\":\"RemoteAuth {s}\"}}{s}}}", .{ href, token, expiry });
        try out.interface.flush();
    } else if (std.mem.eql(u8, kind, "transfer")) {
        const program = fields.next() orelse return error.InvalidFixture;
        const root = fields.next() orelse return error.InvalidFixture;
        const log_dir = fields.next() orelse return error.InvalidFixture;
        const extra = fields.next() orelse return error.InvalidFixture;
        var command: std.ArrayList([]const u8) = .empty;
        try command.appendSlice(arena, &.{ program, try std.fmt.allocPrint(arena, "--root={s}", .{root}), try std.fmt.allocPrint(arena, "--log={s}", .{log_dir}) });
        if (extra.len != 0) try command.append(arena, extra);
        try command.appendSlice(arena, args[1..]);
        var child = try std.process.spawn(io, .{ .argv = command.items, .environ_map = init.environ_map });
        defer child.kill(io);
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) std.process.exit(code),
            else => std.process.exit(255),
        }
    } else return error.InvalidFixture;
}

fn appendLog(io: Io, arena: Allocator, stem: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}.log", .{stem});
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, try file.length(io));
}
