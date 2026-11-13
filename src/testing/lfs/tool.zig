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
    const sidecar = try arena.print("{s}.fixture", .{executable});
    const description = try Io.Dir.cwd().readFileAlloc(io, sidecar, arena, .limited(16 << 10));
    var fields = std.mem.splitScalar(u8, description, '\n');
    const tool: Tool = .{
        .arena = arena,
        .io = io,
        .args = args,
        .environ = init.environ_map,
        .stem = if (std.ascii.endsWithIgnoreCase(executable, ".exe")) executable[0 .. executable.len - 4] else executable,
    };
    const kind = fields.next() orelse return error.InvalidFixture;

    if (std.mem.eql(u8, kind, "askpass")) {
        try askpass(&tool);
    } else if (std.mem.eql(u8, kind, "credential") or std.mem.eql(u8, kind, "credential-removable") or std.mem.eql(u8, kind, "credential-removable-verbatim") or std.mem.eql(u8, kind, "credential-verbatim") or std.mem.eql(u8, kind, "credential-person") or std.mem.eql(u8, kind, "password")) {
        try credential(&tool, kind, &fields);
    } else if (std.mem.eql(u8, kind, "authenticate")) {
        try authenticate(&tool, &fields);
    } else if (std.mem.eql(u8, kind, "transfer")) {
        try transfer(&tool, &fields);
    } else return error.InvalidFixture;
}

/// One run of the stand-in: its arguments and environment, and the stem of
/// its own path that names its log.
const Tool = struct {
    arena: Allocator,
    io: Io,
    args: []const []const u8,
    environ: *const std.process.Environ.Map,
    stem: []const u8,
};

/// The fixture's lines after its kind.
const Fields = std.mem.SplitIterator(u8, .scalar);

/// Answer git's askpass prompt: a username for a username, a password for
/// anything else, logging the prompt.
fn askpass(t: *const Tool) !void {
    const prompt = if (t.args.len > 1) t.args[1] else "";
    try appendLog(t.arena, t.io, t.stem, try t.arena.print("{s}\n", .{prompt}));
    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(t.io, &buf);
    try out.interface.writeAll(if (std.mem.startsWith(u8, prompt, "Username")) "ada\n" else "secret\n");
    try out.interface.flush();
}

/// A credential helper of the fixture's kind: log what git asks, forget
/// on `erase` when removable, and answer `get` with the fixture's
/// credential, a password alone, or a person's prepared answer.
fn credential(t: *const Tool, kind: []const u8, fields: *Fields) !void {
    const arena = t.arena;
    const io = t.io;
    const person = std.mem.eql(u8, kind, "credential-person");
    const person_path = if (person) fields.next() orelse "" else "";
    const person_stem = if (person_path.len == 0) t.stem else person_path;
    const user = if (person) "" else fields.next() orelse return error.InvalidFixture;
    const password = if (std.mem.eql(u8, kind, "password") or person) user else fields.next() orelse return error.InvalidFixture;
    const operation = if (t.args.len > 1) t.args[if (person) t.args.len - 1 else 1] else "";
    if (person and std.mem.eql(u8, operation, "relic-probe")) {
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
    try appendLog(arena, io, person_stem, try credentialLog(arena, kind, operation, input.items));
    const removable = std.mem.eql(u8, kind, "credential-removable") or std.mem.eql(u8, kind, "credential-removable-verbatim");
    const erased_path = if (removable) try arena.print("{s}.erased", .{t.stem}) else "";
    if (removable and std.mem.eql(u8, operation, "erase")) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = erased_path, .data = "" });
    }
    if (!std.mem.eql(u8, operation, "get")) return;
    if (removable) {
        if (Io.Dir.cwd().openFile(io, erased_path, .{})) |file| {
            file.close(io);
            return;
        } else |_| {}
    }
    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &buf);
    if (std.mem.eql(u8, kind, "password")) {
        try out.interface.print("password={s}\n", .{password});
    } else if (person) {
        const answer_path = try arena.print("{s}.answer", .{person_stem});
        const answer = try Io.Dir.cwd().readFileAlloc(io, answer_path, arena, .limited(16 << 10));
        try out.interface.writeAll(answer);
    } else try out.interface.print("username={s}\npassword={s}\n", .{ user, password });
    try out.interface.flush();
}

/// The log entry for one question to a credential helper: the operation,
/// then the input whole, its first block sorted, or only the fields a
/// credential is matched by, as the kind keeps it.
fn credentialLog(arena: Allocator, kind: []const u8, operation: []const u8, input: []const u8) ![]u8 {
    var log_entry: std.ArrayList(u8) = .empty;
    try log_entry.print(arena, "== {s}\n", .{operation});
    var lines = std.mem.splitScalar(u8, input, '\n');
    if (std.mem.eql(u8, kind, "password") or std.mem.eql(u8, kind, "credential-person")) {
        try log_entry.appendSlice(arena, input);
    } else if (std.mem.eql(u8, kind, "credential-verbatim") or std.mem.eql(u8, kind, "credential-removable-verbatim")) {
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
    return log_entry.items;
}

/// git-lfs-authenticate: log the arguments and answer with the fixture's
/// href, token and expiry.
fn authenticate(t: *const Tool, fields: *Fields) !void {
    const href = fields.next() orelse return error.InvalidFixture;
    const token = fields.next() orelse return error.InvalidFixture;
    const expiry = fields.next() orelse return error.InvalidFixture;
    var log_entry: std.ArrayList(u8) = .empty;
    for (t.args[1..], 0..) |arg, i| {
        if (i != 0) try log_entry.append(t.arena, ' ');
        try log_entry.appendSlice(t.arena, arg);
    }
    try log_entry.append(t.arena, '\n');
    try appendLog(t.arena, t.io, t.stem, log_entry.items);
    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(t.io, &buf);
    try out.interface.print("{{\"href\":\"{s}\",\"header\":{{\"Authorization\":\"RemoteAuth {s}\"}}{s}}}", .{ href, token, expiry });
    try out.interface.flush();
}

/// Run the fixture's transfer program over its root and log directory with
/// these arguments, and end with its status.
fn transfer(t: *const Tool, fields: *Fields) !void {
    const arena = t.arena;
    const program = fields.next() orelse return error.InvalidFixture;
    const root = fields.next() orelse return error.InvalidFixture;
    const log_dir = fields.next() orelse return error.InvalidFixture;
    const extra = fields.next() orelse return error.InvalidFixture;
    var command: std.ArrayList([]const u8) = .empty;
    try command.appendSlice(arena, &.{ program, try arena.print("--root={s}", .{root}), try arena.print("--log={s}", .{log_dir}) });
    if (extra.len != 0) try command.append(arena, extra);
    try command.appendSlice(arena, t.args[1..]);
    var child = try std.process.spawn(t.io, .{ .argv = command.items, .environ_map = t.environ });
    defer child.kill(t.io);
    const term = try child.wait(t.io);
    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(255),
    }
}

fn appendLog(arena: Allocator, io: Io, stem: []const u8, bytes: []const u8) !void {
    const path = try arena.print("{s}.log", .{stem});
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, try file.length(io));
}
