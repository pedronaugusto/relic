//! A native hook for the test suite. A copy beside a `.fixture` file runs
//! the action named there, so the same hook runs under git and relic on
//! Unix and Windows.

const std = @import("std");
const relic = @import("relic");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testprogram = @import("program.zig");

/// Run the hook action named by the sidecar beside this executable.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 0) return error.MissingProgramName;
    const executable = try std.process.executablePathAlloc(io, arena);
    const sidecar = try arena.print("{s}.fixture", .{executable});
    const description = try Io.Dir.cwd().readFileAlloc(io, sidecar, arena, .limited(4096));
    const newline = std.mem.findScalar(u8, description, '\n') orelse return error.InvalidFixture;
    const action = actions.get(description[0..newline]) orelse return error.InvalidFixture;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const hook: Hook = .{
        .arena = arena,
        .io = io,
        .args = args,
        .environ = init.environ_map,
        .data = description[newline + 1 ..],
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
    };
    const code = try action(&hook);
    try stdout.interface.flush();
    try stderr.interface.flush();
    if (code != 0) std.process.exit(code);
}

/// One run of the hook: its arguments and environment, the fixture's data
/// after the action's line, and the streams the action writes to.
const Hook = struct {
    arena: Allocator,
    io: Io,
    args: []const []const u8,
    environ: *const std.process.Environ.Map,
    data: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    /// The name git ran this hook as, without a Windows `.exe`.
    fn name(h: *const Hook) []const u8 {
        const raw_name = std.Io.Dir.path.basename(h.args[0]);
        return if (std.ascii.endsWithIgnoreCase(raw_name, ".exe")) raw_name[0 .. raw_name.len - 4] else raw_name;
    }

    /// The rest of standard input.
    fn readStdin(h: *const Hook) !std.ArrayList(u8) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(h.io, &stdin_buf);
        var input: std.ArrayList(u8) = .empty;
        try stdin.interface.appendRemainingUnlimited(h.arena, &input);
        return input;
    }
};

/// An action does what the fixture names and gives the status to exit with.
const Action = *const fn (h: *const Hook) anyerror!u8;

const actions: std.StaticStringMap(Action) = .initComptime(.{
    .{ "text", text },
    .{ "status", status },
    .{ "reject", reject },
    .{ "arg", arg },
    .{ "args_stdin", argsStdin },
    .{ "record_stdin", recordStdin },
    .{ "commit_record", commitRecord },
    .{ "rewrite_log", rewriteLog },
    .{ "signing_wrapper", signingWrapper },
    .{ "history_record", historyRecord },
    .{ "context", context },
});

/// Say the data.
fn text(h: *const Hook) !u8 {
    try h.stdout.writeAll(h.data);
    return 0;
}

/// Exit with the status the data names.
fn status(h: *const Hook) !u8 {
    return std.fmt.parseUnsigned(u8, std.mem.trim(u8, h.data, "\r\n"), 10);
}

/// Exit with the status on the data's first line, saying the rest and the
/// arguments on standard error.
fn reject(h: *const Hook) !u8 {
    const split = std.mem.findScalar(u8, h.data, '\n') orelse return error.InvalidFixture;
    const code = try std.fmt.parseUnsigned(u8, h.data[0..split], 10);
    try h.stderr.writeAll(h.data[split + 1 ..]);
    for (h.args[1..], 0..) |argument, i| {
        if (i != 0) try h.stderr.writeByte(' ');
        try h.stderr.writeAll(argument);
    }
    try h.stderr.writeByte('\n');
    return code;
}

/// Say the data and the first argument.
fn arg(h: *const Hook) !u8 {
    try h.stdout.writeAll(h.data);
    if (h.args.len > 1) try h.stdout.writeAll(h.args[1]);
    try h.stdout.writeByte('\n');
    return 0;
}

/// Say the hook's name and arguments, then copy standard input out.
fn argsStdin(h: *const Hook) !u8 {
    try h.stdout.writeAll(h.name());
    for (h.args[1..]) |argument| try h.stdout.print(" {s}", .{argument});
    try h.stdout.writeByte('\n');
    var stdin_buf: [4096]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(h.io, &stdin_buf);
    _ = try stdin.interface.streamRemaining(h.stdout);
    return 0;
}

/// Append the first argument and standard input to the file on the data's
/// first line; fail when the argument is the state on its second.
fn recordStdin(h: *const Hook) !u8 {
    const split = std.mem.findScalar(u8, h.data, '\n') orelse return error.InvalidFixture;
    const path = h.data[0..split];
    const reject_state = std.mem.trim(u8, h.data[split + 1 ..], "\r\n");
    const state = if (h.args.len > 1) h.args[1] else "";
    var entry: std.ArrayList(u8) = .empty;
    try entry.print(h.arena, "{s}\n", .{state});
    var stdin_buf: [4096]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(h.io, &stdin_buf);
    try stdin.interface.appendRemainingUnlimited(h.arena, &entry);
    try appendFile(h.io, path, entry.items);
    return if (reject_state.len != 0 and std.mem.eql(u8, state, reject_state)) 1 else 0;
}

/// Log a commit hook's view to `.git/hook.log`, then sign the message off
/// or stage a generated file when the data asks.
fn commitRecord(h: *const Hook) !u8 {
    const arena = h.arena;
    const io = h.io;
    var entry: std.ArrayList(u8) = .empty;
    try entry.print(arena, "{s} {d}", .{ h.name(), h.args.len - 1 });
    for (h.args[1..]) |argument| {
        if (Io.Dir.cwd().openFile(io, argument, .{})) |file| {
            file.close(io);
            try entry.print(arena, " [{s}]", .{std.Io.Dir.path.basename(argument)});
        } else |_| try entry.print(arena, " {s}", .{argument});
    }
    if (try atGitTop(arena, io, h.environ)) try entry.appendSlice(arena, " top");
    if (h.environ.get("GIT_INDEX_FILE")) |index| {
        const actual = Io.Dir.cwd().realPathFileAlloc(io, index, arena) catch null;
        const normal = Io.Dir.cwd().realPathFileAlloc(io, ".git/index", arena) catch null;
        if (actual != null and normal != null and samePath(actual.?, normal.?)) try entry.appendSlice(arena, " index");
    }
    try entry.print(arena, " editor={s} author={s} <{s}> {s}\n", .{
        h.environ.get("GIT_EDITOR") orelse "",
        h.environ.get("GIT_AUTHOR_NAME") orelse "",
        h.environ.get("GIT_AUTHOR_EMAIL") orelse "",
        h.environ.get("GIT_AUTHOR_DATE") orelse "",
    });
    try appendFile(io, ".git/hook.log", entry.items);
    if (std.mem.eql(u8, h.data, "signoff") and h.args.len > 1) {
        try appendFile(io, h.args[1], "Signed-off-by: Hook <hook@example.com>\n");
    } else if (std.mem.eql(u8, h.data, "stage")) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "gen.txt", .data = "generated\n" });
        const git = try testprogram.path(arena, io, h.environ, "git");
        const staged = try std.process.run(arena, io, .{ .argv = &.{ git, "add", "gen.txt" }, .environ_map = h.environ });
        if (staged.term != .exited or staged.term.exited != 0) return error.GitFailed;
    }
    return 0;
}

/// Log post-rewrite's arguments and input to `.git/rewrite.log`, with
/// HEAD's name written as NEW.
fn rewriteLog(h: *const Hook) !u8 {
    const arena = h.arena;
    var entry: std.ArrayList(u8) = .empty;
    for (h.args[1..], 0..) |argument, i| {
        if (i != 0) try entry.append(arena, ' ');
        try entry.appendSlice(arena, argument);
    }
    try entry.append(arena, '\n');
    const input = try h.readStdin();
    const git = try testprogram.path(arena, h.io, h.environ, "git");
    const head_result = try std.process.run(arena, h.io, .{ .argv = &.{ git, "rev-parse", "HEAD" }, .environ_map = h.environ });
    if (head_result.term != .exited or head_result.term.exited != 0) return error.GitFailed;
    const head = std.mem.trim(u8, head_result.stdout, "\r\n");
    var at: usize = 0;
    while (std.mem.findPos(u8, input.items, at, head)) |found| {
        try entry.appendSlice(arena, input.items[at..found]);
        try entry.appendSlice(arena, "NEW");
        at = found + head.len;
    }
    try entry.appendSlice(arena, input.items[at..]);
    try appendFile(h.io, ".git/rewrite.log", entry.items);
    return 0;
}

/// Note the use in `log` beside this program, then run ssh-keygen with the
/// arguments and end with its status.
fn signingWrapper(h: *const Hook) !u8 {
    const parent = std.Io.Dir.path.dirname(h.args[0]) orelse return error.InvalidFixture;
    const log = try std.Io.Dir.path.join(h.arena, &.{ parent, "log" });
    try appendFile(h.io, log, "used\n");
    var command: std.ArrayList([]const u8) = .empty;
    try command.append(h.arena, try testprogram.path(h.arena, h.io, h.environ, "ssh-keygen"));
    try command.appendSlice(h.arena, h.args[1..]);
    var child = try std.process.spawn(h.io, .{ .argv = command.items, .environ_map = h.environ });
    defer child.kill(h.io);
    const term = try child.wait(h.io);
    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(255),
    }
    return 0;
}

/// Log a history command's hook to `.git/hook.log`: its name, arguments,
/// environment, the state files present, its input, and for a message
/// hook the message, stripped as git's editor would when there was one.
fn historyRecord(h: *const Hook) !u8 {
    const arena = h.arena;
    const io = h.io;
    const name = h.name();
    var entry: std.ArrayList(u8) = .empty;
    try entry.appendSlice(arena, name);
    for (h.args[1..]) |argument| try entry.print(arena, " {s}", .{argument});
    if (try atGitTop(arena, io, h.environ)) try entry.appendSlice(arena, " top");
    try entry.print(arena, " index={s} editor={s} author={s} <{s}> {s}", .{
        h.environ.get("GIT_INDEX_FILE") orelse "",
        h.environ.get("GIT_EDITOR") orelse "",
        h.environ.get("GIT_AUTHOR_NAME") orelse "",
        h.environ.get("GIT_AUTHOR_EMAIL") orelse "",
        h.environ.get("GIT_AUTHOR_DATE") orelse "",
    });
    for ([_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "COMMIT_EDITMSG" }) |state| {
        const path = try arena.print(".git/{s}", .{state});
        if (Io.Dir.cwd().openFile(io, path, .{})) |file| {
            file.close(io);
            try entry.print(arena, " {s}", .{state});
        } else |_| {}
    }
    try entry.appendSlice(arena, " stdin=[");
    const input = try h.readStdin();
    try appendTranslated(arena, &entry, input.items, ';');
    try entry.append(arena, ']');
    if (std.mem.eql(u8, name, "prepare-commit-msg") or std.mem.eql(u8, name, "commit-msg")) {
        if (h.args.len < 2) return error.MissingMessagePath;
        const message = try Io.Dir.cwd().readFileAlloc(io, h.args[1], arena, .limited(1 << 20));
        if (std.mem.eql(u8, h.environ.get("GIT_EDITOR") orelse "", ":")) {
            try entry.appendSlice(arena, " msg=[");
            try appendTranslated(arena, &entry, message, '|');
        } else {
            const stripped = try relic.repo.program.run(arena, io, .{ .environ = h.environ }, .{ .argv = &.{ "git", "stripspace", "-s" } }, .{
                .input = message,
            });
            if (!stripped.succeeded()) return error.GitFailed;
            try entry.appendSlice(arena, " edited=[");
            try appendTranslated(arena, &entry, stripped.stdout, '|');
        }
        try entry.append(arena, ']');
    }
    try entry.append(arena, '\n');
    try appendFile(io, ".git/hook.log", entry.items);
    return 0;
}

/// Say the arguments, whether this runs at the top of the work tree, and
/// the variables git sets for a hook; say something on standard error too.
fn context(h: *const Hook) !u8 {
    try h.stdout.print("args={d}", .{h.args.len - 1});
    for (h.args[1..]) |argument| try h.stdout.print(" {s}", .{argument});
    try h.stdout.writeByte('\n');
    if (try atGitTop(h.arena, h.io, h.environ)) try h.stdout.writeAll("top\n");
    try h.stdout.print("dir={s} index={s} prefix={s} kept={s}\n", .{
        h.environ.get("GIT_DIR") orelse "unset",
        h.environ.get("GIT_INDEX_FILE") orelse "unset",
        h.environ.get("GIT_PREFIX") orelse "unset",
        h.environ.get("RELIC_KEPT") orelse "unset",
    });
    try h.stderr.writeAll("to-stderr\n");
    return 0;
}

fn appendTranslated(arena: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8, replacement: u8) !void {
    for (bytes) |byte| try out.append(arena, if (byte == '\n') replacement else byte);
}

fn appendFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, try file.length(io));
}

fn atGitTop(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !bool {
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const git = try testprogram.path(arena, io, env, "git");
    const top = try std.process.run(arena, io, .{ .argv = &.{ git, "rev-parse", "--show-toplevel" }, .environ_map = env });
    if (top.term != .exited or top.term.exited != 0) return false;
    return samePath(cwd, std.mem.trim(u8, top.stdout, "\r\n"));
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        const x = if (left == '\\') '/' else left;
        const y = if (right == '\\') '/' else right;
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}
