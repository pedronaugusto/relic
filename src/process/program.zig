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
//! `credential.helper`, `core.sshCommand` — is a command line, and git runs
//! it the way a shell reads it when it holds anything a shell would
//! interpret, and directly otherwise; `Invocation.shell` does the same. Not
//! every program named in the configuration is a command line: git runs
//! `gpg.program` and its per-format siblings directly, as the path of one
//! program, so a path with a space in it works and a pipeline does not, and
//! `gpg.ssh.defaultKeyCommand` is split into words with no shell at all. A
//! hook is a file and runs directly. Running a command line needs `sh`,
//! which is every Unix's and which git for Windows installs.

const Self = @This();

const std = @import("std");
const suite = @import("../testing/helpers.zig");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const conduit = @import("conduit");
pub const Child = @import("child.zig").Child;
/// What a program's pipe holds now, read without waiting for more: once the
/// program has ended, the rest of what it wrote, even while something it
/// started still holds the pipe open.
pub const readAvailable = conduit.readAvailable;
pub const Term = conduit.Term;

/// The permission to run programs, and the environment they start from.
pub const Programs = struct {
    /// Usually the process's own, `std.process.Init.environ_map`. It is
    /// read, never changed.
    environ: *const Environ.Map,
    /// Override process creation for every program relic runs. The hook
    /// receives the fully prepared argv, environment, cwd and streams.
    /// Supply `terminate` as well when a timeout must end descendants.
    spawn: ?SpawnHook = null,
};

/// A caller-owned process launcher, used for hooks, filters and helpers.
pub const SpawnHook = struct {
    context: *anyopaque,
    /// `options` borrows the prepared command and environment for this call;
    /// spawn the child before returning rather than retaining them.
    start: *const fn (Allocator, Io, *anyopaque, Child.SpawnOptions) Child.SpawnError!Child,
    /// Called on cleanup after normal completion too, as well as on timeout
    /// and error paths. It must reap or kill the child; when absent, relic
    /// ends it through conduit. In `run` the child is already reaped by then:
    /// on a timeout conduit has killed it, and the hook ends what it left.
    terminate: ?*const fn (Io, *anyopaque, *Child) void = null,
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
    cwd: std.process.Child.Cwd = .inherit,
    /// Set on top of `Programs.environ`, after `unset`.
    set: []const Var = &.{},
    /// Removed from it: git clears a repository's own variables before it
    /// runs a program in another one.
    unset: []const []const u8 = &.{},
    /// Where the program's diagnostics go. A hook's reach the person, as
    /// git's do; a helper's are the caller's to show.
    stderr: enum { capture, inherit, ignore } = .capture,
    /// Where the program's standard output goes. `to_stderr` is this
    /// process's own standard error, which is where git sends most hooks'
    /// output so that it never mixes with what git itself prints; `inherit`
    /// is this process's standard output, where `pre-push`'s goes.
    stdout: enum { capture, inherit, to_stderr, ignore } = .capture,
};

pub const Error = error{
    /// The program's output passed `RunOptions`.
    OutputTooLong,
} || std.process.SpawnError || Child.SpawnError || Child.OutputError || Child.ExchangeError || conduit.InputWriter.StartError ||
    conduit.InputWriter.QueueError || Io.Timeout.Error || Io.Dir.RealPathError || Io.File.Reader.Error;

pub const Outcome = struct {
    term: Term,
    /// Empty unless `Invocation.stdout` is `.capture`.
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

pub const RunOptions = struct {
    /// Bytes written to standard input before it closes.
    input: []const u8 = "",
    /// The most standard output kept, each stream alike.
    output: Io.Limit = .unlimited,
    /// One deadline for input, output, the exit status and cleanup.
    timeout: Io.Timeout = .none,
};

/// Run a program to its end: `input` on its standard input, which then
/// closes, and its output collected. The input is written while the output
/// is read, so neither side waits on a full pipe, and one deadline covers
/// the input, the output, the exit status and cleanup: conduit's
/// `Child.exchange`, which also serializes every allocation it makes on
/// `gpa`.
pub fn run(
    gpa: Allocator,
    io: Io,
    programs: Programs,
    invocation: Invocation,
    options: RunOptions,
) Self.Error!Outcome {
    var started = try start(gpa, io, programs, invocation);
    defer started.deinit(io);
    // A program that ends without reading all of its input is no error, as
    // git has it: conduit does not report the closed pipe.
    var output = try started.child.exchange(gpa, io, options.input, .{
        .max_bytes = options.output.toInt() orelse std.math.maxInt(usize),
        .timeout = options.timeout,
    });
    defer output.deinit();
    if (output.timedOut()) return error.Timeout;
    if (output.stdoutTruncated() or output.stderrTruncated()) return error.OutputTooLong;
    return .{ .term = output.term(), .stdout = output.takeStdout(), .stderr = output.takeStderr() };
}

/// A program running with its standard input and output as pipes, for a
/// conversation rather than one exchange: a long-running filter, a
/// transport over `ssh`.
pub const Running = struct {
    child: Child,
    spawn: ?SpawnHook,
    terminated: bool = false,
    environ: Environ.Map,
    line: CommandLine,
    gpa: Allocator,

    /// Close standard input, then wait for its end.
    pub fn wait(running: *Running, io: Io) Child.WaitError!Term {
        running.child.closeStdin(io);
        return try running.child.wait(io);
    }

    /// The caller's termination policy, or conduit's immediate kill and reap.
    pub fn kill(running: *Running, io: Io) void {
        if (running.terminated) return;
        running.terminated = true;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        if (running.spawn) |hook| {
            if (hook.terminate) |terminate| {
                terminate(io, hook.context, &running.child);
                return;
            }
        }
        // ziglint-ignore: Z026 killing cannot fail its caller; a child already gone has nothing left to reap
        _ = running.child.killWait(io, .zero) catch {};
    }

    /// Stop it if it is still running and release everything.
    pub fn deinit(running: *Running, io: Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        running.kill(io);
        running.child.deinit(io);
        running.environ.deinit();
        running.line.deinit(running.gpa);
        running.* = undefined;
    }
};

/// Start a program with piped standard input, and its standard output a
/// pipe unless `Invocation.stdout` sends it elsewhere.
pub fn start(gpa: Allocator, io: Io, programs: Programs, invocation: Invocation) Self.Error!Running {
    var environ = try programs.environ.clone(gpa);
    errdefer environ.deinit();
    // conduit's rule for an override: a later one wins, and a removal is
    // not an empty value
    for (invocation.unset) |name| try conduit.environ.apply(&environ, &.{.{ .name = name, .value = null }});
    for (invocation.set) |v| try conduit.environ.apply(&environ, &.{.{ .name = v.name, .value = v.value }});

    var line: CommandLine = try .init(gpa, invocation);
    errdefer line.deinit(gpa);
    // Windows looks for a bare name in this executable's directory and the
    // current one before `PATH`, where a working tree may have put one;
    // git for Windows looks in `PATH` alone, and so does this.
    if (builtin.target.os.tag == .windows and isBare(line.argv[0])) {
        line.program = try lookupOnPath(gpa, io, pathOf(&environ), line.argv[0]) orelse return error.FileNotFound;
        line.argv[0] = line.program;
    }

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd: ?[]const u8 = switch (invocation.cwd) {
        .inherit => null,
        .path => |path| path,
        .dir => |dir| cwd_buffer[0..try dir.realPath(io, &cwd_buffer)],
    };
    // Keep the default descendant policy: git helpers may deliberately leave
    // a credential-cache daemon running after their normal, reaped exit.
    const options: Child.SpawnOptions = .{
        .argv = line.argv,
        .cwd = cwd,
        .environ = &environ,
        .stdio = .{ .streams = .{
            .stdin = .pipe,
            .stdout = switch (invocation.stdout) {
                .capture => .pipe,
                .inherit => .inherit,
                .to_stderr => .{ .file = Io.File.stderr() },
                .ignore => .ignore,
            },
            .stderr = switch (invocation.stderr) {
                .capture => .pipe,
                .inherit => .inherit,
                .ignore => .ignore,
            },
        } },
    };
    const child = if (programs.spawn) |hook| try hook.start(gpa, io, hook.context, options) else try Child.spawn(gpa, io, options);
    return .{ .child = child, .spawn = programs.spawn, .environ = environ, .line = line, .gpa = gpa };
}

/// The argv a process is started with. A command line with nothing a shell
/// interprets runs directly; otherwise `sh -c '<line> "$@"' '<line>' args…`,
/// which is git's own spelling, so its arguments reach it as arguments and
/// never as text the shell reads again.
const CommandLine = struct {
    argv: [][]const u8,
    /// The `<line> "$@"` the argv points into, or empty.
    owned: []const u8 = "",
    /// The program `argv[0]` was found at, when it was looked up here.
    program: []const u8 = "",

    fn init(gpa: Allocator, invocation: Invocation) Allocator.Error!CommandLine {
        const argv = invocation.argv;
        std.debug.assert(argv.len > 0);
        if (!invocation.shell or !needsShell(argv[0])) return .{ .argv = try gpa.dupe([]const u8, argv) };
        const out = try gpa.alloc([]const u8, argv.len + 3);
        errdefer gpa.free(out);
        const owned = if (argv.len > 1) try gpa.print("{s} \"$@\"", .{argv[0]}) else "";
        out[0] = "sh";
        out[1] = "-c";
        out[2] = if (argv.len > 1) owned else argv[0];
        @memcpy(out[3..], argv);
        return .{ .argv = out, .owned = owned };
    }

    fn deinit(line: CommandLine, gpa: Allocator) void {
        gpa.free(line.argv);
        gpa.free(line.owned);
        gpa.free(line.program);
    }
};

/// Whether `name` is a program to be looked for rather than a path: no
/// separator of either kind and no drive.
fn isBare(name: []const u8) bool {
    return std.mem.findAny(u8, name, "/\\:") == null;
}

/// The `PATH` of an environment, whatever the case of its name, as Windows
/// spells it either way.
fn pathOf(environ: *const Environ.Map) ?[]const u8 {
    if (environ.get("PATH")) |value| return value;
    for (environ.keys(), environ.values()) |key, value| {
        if (std.ascii.eqlIgnoreCase(key, "PATH")) return value;
    }
    return null;
}

/// git's `path_lookup`: the first entry of `path` holding `name` -- on
/// Windows `name.exe`, then `name` -- and nowhere else: not the current
/// directory, which is often a working tree someone else wrote. An empty
/// entry is skipped. The result is `gpa`'s; `null` when no entry has it.
pub fn lookupOnPath(gpa: Allocator, io: Io, path: ?[]const u8, name: []const u8) Allocator.Error!?[]u8 {
    const list = path orelse return null;
    const windows = builtin.target.os.tag == .windows;
    const has_exe = name.len >= 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe");
    var entries = std.mem.splitScalar(u8, list, std.Io.Dir.path.delimiter);
    while (entries.next()) |raw| {
        const dir = if (windows) std.mem.trim(u8, raw, "\"") else raw;
        if (dir.len == 0) continue;
        for ([_]bool{ true, false }) |with_exe| {
            if (with_exe and (!windows or has_exe)) continue;
            const candidate = try gpa.print("{s}{c}{s}{s}", .{ dir, std.Io.Dir.path.sep, name, if (with_exe) ".exe" else "" });
            const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch null;
            if (stat) |found| if (found.kind != .directory) return candidate;
            gpa.free(candidate);
        }
    }
    return null;
}

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
    return std.mem.findAny(u8, line, "|&;<>()$`\\\"' \t\n*?[#~=%") != null;
}

const testing = std.testing;
const testgit = @import("../testing/git.zig");

fn testEnviron() !Environ.Map {
    var map = try testgit.programEnviron(testing.allocator);
    errdefer map.deinit();
    try map.put("RELIC_KEPT", "kept");
    try map.put("RELIC_GONE", "gone");
    return map;
}

/// A spawn hook that records it started and ended the child.
const SpawnHooks = struct {
    started: bool = false,
    /// The options carried the program, its argument and the variable set.
    prepared: bool = false,
    ended: bool = false,

    fn start(gpa: Allocator, io: Io, raw: *anyopaque, options: Child.SpawnOptions) Child.SpawnError!Child {
        const self: *SpawnHooks = @ptrCast(@alignCast(raw)); // safe: the test hands the hook a *SpawnHooks as its context
        self.started = true;
        const hooked = options.environ.?.get("RELIC_HOOKED") orelse "";
        self.prepared = std.mem.eql(u8, suite.path(.process_fixture), options.argv[0]) and
            std.mem.eql(u8, "copy", options.argv[1]) and
            std.mem.eql(u8, "hooked", hooked);
        return Child.spawn(gpa, io, options);
    }

    fn terminate(io: Io, raw: *anyopaque, child: *Child) void {
        const self: *SpawnHooks = @ptrCast(@alignCast(raw)); // safe: the test hands the hook a *SpawnHooks as its context
        self.ended = true;
        // ziglint-ignore: Z026 termination cannot fail its caller; a child already gone has nothing left to reap
        _ = child.killWait(io, .zero) catch {};
    }
};

test "Programs spawn hook receives prepared options and owns termination" {
    var env = try testEnviron();
    defer env.deinit();
    var hooks: SpawnHooks = .{};
    var outcome = try run(testing.allocator, testing.io, .{ .environ = &env, .spawn = .{
        .context = &hooks,
        .start = SpawnHooks.start,
        .terminate = SpawnHooks.terminate,
    } }, .{
        .argv = &.{ suite.path(.process_fixture), "copy" },
        .set = &.{.{ .name = "RELIC_HOOKED", .value = "hooked" }},
    }, .{
        .input = "hello",
    });
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", outcome.stdout);
    try testing.expect(hooks.started and hooks.ended);
    try testing.expect(hooks.prepared);
}

test "a command line reaches the shell as git hands it one, and its arguments stay arguments" {
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    const programs: Programs = .{ .environ = &environ };

    var outcome = try run(gpa, io, programs, .{
        .argv = &.{ "printf '%s|' \"$RELIC_SET\" \"$RELIC_KEPT\" \"$RELIC_GONE\"", "a b", "$HOME;x" },
        .shell = true,
        .set = &.{.{ .name = "RELIC_SET", .value = "set" }},
        .unset = &.{"RELIC_GONE"},
    }, .{});
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
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();

    const input = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i *% 31);
    var outcome = try run(gpa, io, .{ .environ = &environ }, .{ .argv = &.{ suite.path(.process_fixture), "copy" } }, .{
        .input = input,
    });
    defer outcome.deinit(gpa);
    try testing.expect(outcome.succeeded());
    try testing.expectEqualSlices(u8, input, outcome.stdout);
}

test "a failing program is its status, its diagnostics kept apart" {
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();

    var outcome = try run(gpa, io, .{ .environ = &environ }, .{
        .argv = &.{ suite.path(.process_fixture), "streams", "3" },
    }, .{
        .input = "ignored input",
    });
    defer outcome.deinit(gpa);
    try testing.expect(!outcome.succeeded());
    try testing.expectEqual(Term{ .exited = 3 }, outcome.term);
    try testing.expectEqualStrings("out\n", outcome.stdout);
    try testing.expectEqualStrings("err\n", outcome.stderr);
}

test "output sent elsewhere is not collected, and the status still is" {
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();

    var outcome = try run(gpa, io, .{ .environ = &environ }, .{
        .argv = &.{ suite.path(.process_fixture), "streams", "4" },
        .stdout = .ignore,
        .stderr = .ignore,
    }, .{});
    defer outcome.deinit(gpa);
    try testing.expectEqual(Term{ .exited = 4 }, outcome.term);
    try testing.expectEqualStrings("", outcome.stdout);
    try testing.expectEqualStrings("", outcome.stderr);

    var kept = try run(gpa, io, .{ .environ = &environ }, .{
        .argv = &.{ suite.path(.process_fixture), "stderr" },
        .stdout = .ignore,
    }, .{});
    defer kept.deinit(gpa);
    try testing.expect(kept.succeeded());
    try testing.expectEqualStrings("err\n", kept.stderr);
}

test "output past the limit is refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    try testing.expectError(error.OutputTooLong, run(gpa, io, .{ .environ = &environ }, .{
        .argv = &.{ suite.path(.process_fixture), "bytes" },
    }, .{ .output = .limited(1000) }));
}

test "timeout bounds a helper that closes its output and keeps running" {
    var env = try testEnviron();
    defer env.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(input);
    @memset(input, 'i');
    // Exercise both EOF followed by a wait, and a writer blocked on a child
    // that never reads. Ignored output also proves no reader is needed for
    // the deadline to apply.
    for ([_][]const u8{ "", input }) |bytes| {
        for ([_]bool{ false, true }) |capture| {
            const result = run(testing.allocator, testing.io, .{ .environ = &env }, .{
                .argv = &.{ suite.path(.process_fixture), "closed-output" },
                .stdout = if (capture) .capture else .ignore,
                .stderr = if (capture) .capture else .ignore,
                .cwd = .{ .dir = tmp.dir },
            }, .{ .input = bytes, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } } });
            defer if (result) |value| {
                var outcome = value;
                outcome.deinit(testing.allocator);
            } else |_| {};
            try testing.expectError(error.Timeout, if (result) |_| @as(Error!void, {}) else |err| @as(Error!void, err));
        }
    }
}

test "opposite full pipes refuse unavailable concurrency instead of deadlocking" {
    var env = try testEnviron();
    defer env.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: Io.Threaded = .init(testing.allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const input = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(input);
    @memset(input, 'i');
    for ([_]RunOptions{
        .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } } },
        .{},
    }) |limits| {
        const result = run(testing.allocator, threaded.io(), .{ .environ = &env }, .{
            .argv = &.{ suite.path(.process_fixture), "opposite-pipes" },
            .cwd = .{ .dir = tmp.dir },
        }, blk: {
            var run_with: RunOptions = limits;
            run_with.input = input;
            break :blk run_with;
        });
        defer if (result) |value| {
            var outcome = value;
            outcome.deinit(testing.allocator);
        } else |_| {};
        try testing.expectError(error.ConcurrencyUnavailable, if (result) |_| @as(Error!void, {}) else |err| @as(Error!void, err));
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var outcome = try run(arena.allocator(), testing.io, .{ .environ = &env }, .{
        .argv = &.{ suite.path(.process_fixture), "opposite-pipes" },
        .cwd = .{ .dir = tmp.dir },
    }, .{
        .input = input,
    });
    defer outcome.deinit(arena.allocator());
    try testing.expect(outcome.succeeded());
    try testing.expectEqual(input.len, outcome.stdout.len);
    for (outcome.stdout) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
}
