//! A native hook for the test suite. A copy beside a `.fixture` file runs
//! the action named there, so the same hook runs under git and relic on
//! Unix and Windows.

const std = @import("std");
const relic = @import("relic");
const Io = std.Io;
const testprogram = @import("program.zig");

/// Run the hook action named by the sidecar beside this executable.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 0) return error.MissingProgramName;
    const executable = try std.process.executablePathAlloc(io, arena);
    const sidecar = try std.fmt.allocPrint(arena, "{s}.fixture", .{executable});
    const description = try Io.Dir.cwd().readFileAlloc(io, sidecar, arena, .limited(4096));
    const newline = std.mem.findScalar(u8, description, '\n') orelse return error.InvalidFixture;
    const action = description[0..newline];
    const data = description[newline + 1 ..];

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &stderr_buf);
    var code: u8 = 0;
    if (std.mem.eql(u8, action, "text")) {
        try stdout.interface.writeAll(data);
    } else if (std.mem.eql(u8, action, "status")) {
        code = try std.fmt.parseUnsigned(u8, std.mem.trim(u8, data, "\r\n"), 10);
    } else if (std.mem.eql(u8, action, "reject")) {
        const split = std.mem.findScalar(u8, data, '\n') orelse return error.InvalidFixture;
        code = try std.fmt.parseUnsigned(u8, data[0..split], 10);
        try stderr.interface.writeAll(data[split + 1 ..]);
        for (args[1..], 0..) |arg, i| {
            if (i != 0) try stderr.interface.writeByte(' ');
            try stderr.interface.writeAll(arg);
        }
        try stderr.interface.writeByte('\n');
    } else if (std.mem.eql(u8, action, "arg")) {
        try stdout.interface.writeAll(data);
        if (args.len > 1) try stdout.interface.writeAll(args[1]);
        try stdout.interface.writeByte('\n');
    } else if (std.mem.eql(u8, action, "args_stdin")) {
        const raw_name = std.fs.path.basename(args[0]);
        const name = if (std.ascii.endsWithIgnoreCase(raw_name, ".exe")) raw_name[0 .. raw_name.len - 4] else raw_name;
        try stdout.interface.writeAll(name);
        for (args[1..]) |arg| try stdout.interface.print(" {s}", .{arg});
        try stdout.interface.writeByte('\n');
        var stdin_buf: [4096]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        _ = try stdin.interface.streamRemaining(&stdout.interface);
    } else if (std.mem.eql(u8, action, "record_stdin")) {
        const split = std.mem.findScalar(u8, data, '\n') orelse return error.InvalidFixture;
        const path = data[0..split];
        const reject_state = std.mem.trim(u8, data[split + 1 ..], "\r\n");
        const state = if (args.len > 1) args[1] else "";
        var entry: std.ArrayList(u8) = .empty;
        try entry.print(arena, "{s}\n", .{state});
        var stdin_buf: [4096]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        try stdin.interface.appendRemainingUnlimited(arena, &entry);
        try appendFile(io, path, entry.items);
        if (reject_state.len != 0 and std.mem.eql(u8, state, reject_state)) code = 1;
    } else if (std.mem.eql(u8, action, "commit_record")) {
        const raw_name = std.fs.path.basename(args[0]);
        const name = if (std.ascii.endsWithIgnoreCase(raw_name, ".exe")) raw_name[0 .. raw_name.len - 4] else raw_name;
        var entry: std.ArrayList(u8) = .empty;
        try entry.print(arena, "{s} {d}", .{ name, args.len - 1 });
        for (args[1..]) |arg| {
            if (Io.Dir.cwd().openFile(io, arg, .{})) |file| {
                file.close(io);
                try entry.print(arena, " [{s}]", .{std.fs.path.basename(arg)});
            } else |_| try entry.print(arena, " {s}", .{arg});
        }
        if (try atGitTop(arena, io, init.environ_map)) try entry.appendSlice(arena, " top");
        if (init.environ_map.get("GIT_INDEX_FILE")) |index| {
            const actual = Io.Dir.cwd().realPathFileAlloc(io, index, arena) catch null;
            const normal = Io.Dir.cwd().realPathFileAlloc(io, ".git/index", arena) catch null;
            if (actual != null and normal != null and samePath(actual.?, normal.?)) try entry.appendSlice(arena, " index");
        }
        try entry.print(arena, " editor={s} author={s} <{s}> {s}\n", .{
            init.environ_map.get("GIT_EDITOR") orelse "",
            init.environ_map.get("GIT_AUTHOR_NAME") orelse "",
            init.environ_map.get("GIT_AUTHOR_EMAIL") orelse "",
            init.environ_map.get("GIT_AUTHOR_DATE") orelse "",
        });
        try appendFile(io, ".git/hook.log", entry.items);
        if (std.mem.eql(u8, data, "signoff") and args.len > 1) {
            try appendFile(io, args[1], "Signed-off-by: Hook <hook@example.com>\n");
        } else if (std.mem.eql(u8, data, "stage")) {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = "gen.txt", .data = "generated\n" });
            const git = try testprogram.path(arena, io, init.environ_map, "git");
            const staged = try std.process.run(arena, io, .{ .argv = &.{ git, "add", "gen.txt" }, .environ_map = init.environ_map });
            if (staged.term != .exited or staged.term.exited != 0) return error.GitFailed;
        }
    } else if (std.mem.eql(u8, action, "rewrite_log")) {
        var entry: std.ArrayList(u8) = .empty;
        for (args[1..], 0..) |arg, i| {
            if (i != 0) try entry.append(arena, ' ');
            try entry.appendSlice(arena, arg);
        }
        try entry.append(arena, '\n');
        var stdin_buf: [4096]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        var input: std.ArrayList(u8) = .empty;
        try stdin.interface.appendRemainingUnlimited(arena, &input);
        const git = try testprogram.path(arena, io, init.environ_map, "git");
        const head_result = try std.process.run(arena, io, .{ .argv = &.{ git, "rev-parse", "HEAD" }, .environ_map = init.environ_map });
        if (head_result.term != .exited or head_result.term.exited != 0) return error.GitFailed;
        const head = std.mem.trim(u8, head_result.stdout, "\r\n");
        var at: usize = 0;
        while (std.mem.findPos(u8, input.items, at, head)) |found| {
            try entry.appendSlice(arena, input.items[at..found]);
            try entry.appendSlice(arena, "NEW");
            at = found + head.len;
        }
        try entry.appendSlice(arena, input.items[at..]);
        try appendFile(io, ".git/rewrite.log", entry.items);
    } else if (std.mem.eql(u8, action, "signing_wrapper")) {
        const parent = std.fs.path.dirname(args[0]) orelse return error.InvalidFixture;
        const log = try std.fs.path.join(arena, &.{ parent, "log" });
        try appendFile(io, log, "used\n");
        var command: std.ArrayList([]const u8) = .empty;
        try command.append(arena, try testprogram.path(arena, io, init.environ_map, "ssh-keygen"));
        try command.appendSlice(arena, args[1..]);
        var child = try std.process.spawn(io, .{ .argv = command.items, .environ_map = init.environ_map });
        defer child.kill(io);
        const term = try child.wait(io);
        switch (term) {
            .exited => |status| if (status != 0) std.process.exit(status),
            else => std.process.exit(255),
        }
    } else if (std.mem.eql(u8, action, "history_record")) {
        const raw_name = std.fs.path.basename(args[0]);
        const name = if (std.ascii.endsWithIgnoreCase(raw_name, ".exe")) raw_name[0 .. raw_name.len - 4] else raw_name;
        var entry: std.ArrayList(u8) = .empty;
        try entry.appendSlice(arena, name);
        for (args[1..]) |arg| try entry.print(arena, " {s}", .{arg});
        if (try atGitTop(arena, io, init.environ_map)) try entry.appendSlice(arena, " top");
        try entry.print(arena, " index={s} editor={s} author={s} <{s}> {s}", .{
            init.environ_map.get("GIT_INDEX_FILE") orelse "",
            init.environ_map.get("GIT_EDITOR") orelse "",
            init.environ_map.get("GIT_AUTHOR_NAME") orelse "",
            init.environ_map.get("GIT_AUTHOR_EMAIL") orelse "",
            init.environ_map.get("GIT_AUTHOR_DATE") orelse "",
        });
        for ([_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "COMMIT_EDITMSG" }) |state| {
            const path = try std.fmt.allocPrint(arena, ".git/{s}", .{state});
            if (Io.Dir.cwd().openFile(io, path, .{})) |file| {
                file.close(io);
                try entry.print(arena, " {s}", .{state});
            } else |_| {}
        }
        try entry.appendSlice(arena, " stdin=[");
        var stdin_buf: [4096]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        var input: std.ArrayList(u8) = .empty;
        try stdin.interface.appendRemainingUnlimited(arena, &input);
        try appendTranslated(arena, &entry, input.items, ';');
        try entry.append(arena, ']');
        if (std.mem.eql(u8, name, "prepare-commit-msg") or std.mem.eql(u8, name, "commit-msg")) {
            if (args.len < 2) return error.MissingMessagePath;
            const message = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
            if (std.mem.eql(u8, init.environ_map.get("GIT_EDITOR") orelse "", ":")) {
                try entry.appendSlice(arena, " msg=[");
                try appendTranslated(arena, &entry, message, '|');
            } else {
                const stripped = try relic.repo.program.run(.{ .environ = init.environ_map }, arena, io, .{ .argv = &.{ "git", "stripspace", "-s" } }, message, .{});
                if (!stripped.succeeded()) return error.GitFailed;
                try entry.appendSlice(arena, " edited=[");
                try appendTranslated(arena, &entry, stripped.stdout, '|');
            }
            try entry.append(arena, ']');
        }
        try entry.append(arena, '\n');
        try appendFile(io, ".git/hook.log", entry.items);
    } else if (std.mem.eql(u8, action, "context")) {
        try stdout.interface.print("args={d}", .{args.len - 1});
        for (args[1..]) |arg| try stdout.interface.print(" {s}", .{arg});
        try stdout.interface.writeByte('\n');
        if (try atGitTop(arena, io, init.environ_map)) try stdout.interface.writeAll("top\n");
        try stdout.interface.print("dir={s} index={s} prefix={s} kept={s}\n", .{
            init.environ_map.get("GIT_DIR") orelse "unset",
            init.environ_map.get("GIT_INDEX_FILE") orelse "unset",
            init.environ_map.get("GIT_PREFIX") orelse "unset",
            init.environ_map.get("RELIC_KEPT") orelse "unset",
        });
        try stderr.interface.writeAll("to-stderr\n");
    } else return error.InvalidFixture;
    try stdout.interface.flush();
    try stderr.interface.flush();
    if (code != 0) std.process.exit(code);
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
