//! Running a person's programs: hooks, filters, credential helpers, `ssh`,
//! `gpg`.
//!
//! This is the only file in the library that starts a process, and it starts
//! one only through `Programs`, which the caller hands in. A caller that
//! hands in none gets what relic did before it ran anything: a setting that
//! would run a program is a named refusal, and a hook is not run. What a
//! program starts from is the caller's environment, never one relic reads for
//! itself, because the library has none of its own.
//!
//! A command read from a configuration file — `filter.<name>.clean`,
//! `credential.helper`, `core.sshCommand`, `gpg.program` — is a command line,
//! and git runs it the way a shell reads it when it holds anything a shell
//! would interpret, and directly otherwise; `Invocation.shell` does the same.
//! A hook is a file and runs directly. Running a command line needs `sh`,
//! which is every Unix's and which git for Windows installs.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Child = std.process.Child;

/// The permission to run programs, and the environment they start from.
pub const Programs = struct {
    /// Usually the process's own, `std.process.Init.environ_map`. It is
    /// read, never changed.
    environ: *const Environ.Map,
};

/// One variable set for a program on top of the environment it starts
/// from.
pub const Var = struct {
    name: []const u8,
    value: []const u8,
};

pub const Invocation = struct {
    /// The program and its arguments. With `shell`, the first is a command
    /// line and the rest are its arguments.
    argv: []const []const u8,
    /// Read `argv[0]` as git reads a configured command.
    shell: bool = false,
    cwd: Child.Cwd = .inherit,
    /// Set on top of `Programs.environ`, after `unset`.
    set: []const Var = &.{},
    /// Removed from it: git clears a repository's own variables before it
    /// runs a program in another one.
    unset: []const []const u8 = &.{},
    /// Where the program's diagnostics go. A hook's reach the person, as
    /// git's do; a helper's are the caller's to show.
    stderr: enum { capture, inherit, ignore } = .capture,
};

pub const Error = error{
    /// The program's output passed `Limits`.
    OutputTooLong,
} || Allocator.Error || std.process.SpawnError || Io.File.MultiReader.UnendingError ||
    Io.Timeout.Error || Child.WaitError || Io.ConcurrentError;

pub const Outcome = struct {
    term: Child.Term,
    stdout: []u8,
    /// Empty unless `Invocation.stderr` is `.capture`.
    stderr: []u8,

    /// Whether it exited with status zero.
    pub fn succeeded(outcome: Outcome) bool {
        return switch (outcome.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    pub fn deinit(outcome: *Outcome, gpa: Allocator) void {
        gpa.free(outcome.stdout);
        gpa.free(outcome.stderr);
        outcome.* = undefined;
    }
};

pub const Limits = struct {
    /// The most standard output kept, each stream alike.
    output: Io.Limit = .unlimited,
    timeout: Io.Timeout = .none,
};

/// Run a program to its end: `input` on its standard input, which then
/// closes, and its output collected. The input is written while the output
/// is read, so neither side waits on a full pipe.
pub fn run(
    programs: Programs,
    gpa: Allocator,
    io: Io,
    invocation: Invocation,
    input: []const u8,
    limits: Limits,
) Error!Outcome {
    var started = try start(programs, gpa, io, invocation);
    defer started.deinit(io);

    const stdin = started.child.stdin.?;
    started.child.stdin = null;
    var feeding = io.concurrent(feed, .{ io, stdin, input }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => blk: {
            // One task only: write it all first. Only a program that answers
            // before it has read its input can then wait on a full pipe.
            feed(io, stdin, input);
            break :blk null;
        },
    };
    defer if (feeding) |*f| f.cancel(io);

    const capture = started.child.stderr != null;
    var buffers: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    const files: []const Io.File = if (capture)
        &.{ started.child.stdout.?, started.child.stderr.? }
    else
        &.{started.child.stdout.?};
    // The layout is computed from the count, so a buffer for two holds one.
    const streams = buffers.toStreams();
    streams.len = @intCast(files.len);
    multi.init(gpa, io, streams, files);
    defer multi.deinit();

    while (multi.fill(64, limits.timeout)) |_| {
        if (limits.output.toInt()) |most| {
            for (0..files.len) |i| {
                if (multi.reader(i).buffered().len > most) return error.OutputTooLong;
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
    if (feeding) |*f| {
        f.await(io);
        feeding = null;
    }

    const term = try started.wait(io);
    const stdout = try multi.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = if (capture) try multi.toOwnedSlice(1) else try gpa.alloc(u8, 0);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn feed(io: Io, stdin: Io.File, input: []const u8) void {
    // A program that exits without reading its input is not a failure of
    // the writer: git ignores the broken pipe the same way.
    stdin.writeStreamingAll(io, input) catch {};
    stdin.close(io);
}

/// A program running with its standard input and output as pipes, for a
/// conversation rather than one exchange: a long-running filter, a
/// transport over `ssh`.
pub const Running = struct {
    child: Child,
    environ: Environ.Map,
    line: CommandLine,
    gpa: Allocator,

    /// Close what is still open, then wait for its end.
    pub fn wait(running: *Running, io: Io) Child.WaitError!Child.Term {
        if (running.child.stdin) |stdin| {
            stdin.close(io);
            running.child.stdin = null;
        }
        return running.child.wait(io);
    }

    /// Stop it if it is still running and release everything.
    pub fn deinit(running: *Running, io: Io) void {
        running.child.kill(io);
        running.environ.deinit();
        running.line.deinit(running.gpa);
        running.* = undefined;
    }
};

/// Start a program with piped standard input and output.
pub fn start(programs: Programs, gpa: Allocator, io: Io, invocation: Invocation) Error!Running {
    var environ = try programs.environ.clone(gpa);
    errdefer environ.deinit();
    for (invocation.unset) |name| _ = environ.orderedRemove(name);
    for (invocation.set) |v| try environ.put(v.name, v.value);

    const line: CommandLine = try .init(gpa, invocation);
    errdefer line.deinit(gpa);

    const child = try std.process.spawn(io, .{
        .argv = line.argv,
        .cwd = invocation.cwd,
        .environ_map = &environ,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = switch (invocation.stderr) {
            .capture => .pipe,
            .inherit => .inherit,
            .ignore => .ignore,
        },
    });
    return .{ .child = child, .environ = environ, .line = line, .gpa = gpa };
}

/// The argv a process is started with. A command line with nothing a shell
/// interprets runs directly; otherwise `sh -c '<line> "$@"' '<line>' args…`,
/// which is git's own spelling, so its arguments reach it as arguments and
/// never as text the shell reads again.
const CommandLine = struct {
    argv: [][]const u8,
    /// The `<line> "$@"` the argv points into, or empty.
    owned: []const u8 = "",

    fn init(gpa: Allocator, invocation: Invocation) Allocator.Error!CommandLine {
        const argv = invocation.argv;
        std.debug.assert(argv.len > 0);
        if (!invocation.shell or !needsShell(argv[0])) return .{ .argv = try gpa.dupe([]const u8, argv) };
        const out = try gpa.alloc([]const u8, argv.len + 3);
        errdefer gpa.free(out);
        const owned = if (argv.len > 1) try std.fmt.allocPrint(gpa, "{s} \"$@\"", .{argv[0]}) else "";
        out[0] = "sh";
        out[1] = "-c";
        out[2] = if (argv.len > 1) owned else argv[0];
        @memcpy(out[3..], argv);
        return .{ .argv = out, .owned = owned };
    }

    fn deinit(line: CommandLine, gpa: Allocator) void {
        gpa.free(line.argv);
        gpa.free(line.owned);
    }
};

/// The variables that point a git at one particular repository. A program
/// relic starts for a repository it has open is started without them, from
/// the directory it is to work in, so a variable the caller's own process
/// inherited cannot send it to a different repository. The list is git's
/// own `local_repo_env`.
pub const repository_variables = [_][]const u8{
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
};

/// Whether git would hand this command line to a shell: it holds a byte of
/// `|&;<>()$\`\\"' \t\n*?[#~=%`.
pub fn needsShell(line: []const u8) bool {
    return std.mem.indexOfAny(u8, line, "|&;<>()$`\\\"' \t\n*?[#~=%") != null;
}

const testing = std.testing;

fn testEnviron() !Environ.Map {
    var map: Environ.Map = .init(testing.allocator);
    errdefer map.deinit();
    const path = testing.environ.getAlloc(testing.allocator, "PATH") catch return error.SkipZigTest;
    defer testing.allocator.free(path);
    try map.put("PATH", path);
    try map.put("RELIC_KEPT", "kept");
    try map.put("RELIC_GONE", "gone");
    return map;
}

test "a command line reaches the shell as git hands it one, and its arguments stay arguments" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    const programs: Programs = .{ .environ = &environ };

    var outcome = try run(programs, gpa, io, .{
        .argv = &.{ "printf '%s|' \"$RELIC_SET\" \"$RELIC_KEPT\" \"$RELIC_GONE\"", "a b", "$HOME;x" },
        .shell = true,
        .set = &.{.{ .name = "RELIC_SET", .value = "set" }},
        .unset = &.{"RELIC_GONE"},
    }, "", .{});
    defer outcome.deinit(gpa);
    try testing.expect(outcome.succeeded());
    try testing.expectEqualStrings("set|kept||a b|$HOME;x|", outcome.stdout);
}

test "a command line with nothing to interpret runs directly" {
    try testing.expect(!needsShell("git-credential-store"));
    try testing.expect(!needsShell("/usr/bin/ssh"));
    try testing.expect(needsShell("ssh -i key"));
    try testing.expect(needsShell("f() { cat; }; f"));
    const direct: CommandLine = try .init(testing.allocator, .{ .argv = &.{ "cat", "x" }, .shell = true });
    defer direct.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), direct.argv.len);
    try testing.expectEqualStrings("cat", direct.argv[0]);
    const alone: CommandLine = try .init(testing.allocator, .{ .argv = &.{"cat | wc"}, .shell = true });
    defer alone.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), alone.argv.len);
    try testing.expectEqualStrings("cat | wc", alone.argv[2]);
    try testing.expectEqualStrings("cat | wc", alone.argv[3]);
}

test "input larger than a pipe goes in while output larger than a pipe comes out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();

    const input = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i *% 31);
    var outcome = try run(.{ .environ = &environ }, gpa, io, .{ .argv = &.{"cat"} }, input, .{});
    defer outcome.deinit(gpa);
    try testing.expect(outcome.succeeded());
    try testing.expectEqualSlices(u8, input, outcome.stdout);
}

test "a failing program is its status, its diagnostics kept apart" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();

    var outcome = try run(.{ .environ = &environ }, gpa, io, .{
        .argv = &.{"echo out; echo err >&2; exit 3"},
        .shell = true,
    }, "ignored input", .{});
    defer outcome.deinit(gpa);
    try testing.expect(!outcome.succeeded());
    try testing.expectEqual(Child.Term{ .exited = 3 }, outcome.term);
    try testing.expectEqualStrings("out\n", outcome.stdout);
    try testing.expectEqualStrings("err\n", outcome.stderr);
}

test "output past the limit is refused by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    try testing.expectError(error.OutputTooLong, run(.{ .environ = &environ }, gpa, io, .{
        .argv = &.{"head -c 100000 /dev/zero"},
        .shell = true,
    }, "", .{ .output = .limited(1000) }));
}
