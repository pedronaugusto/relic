//! The fixture harness: a real `git` on the machine, run in a temporary
//! directory, generating the bytes the suite compares against.
//!
//! The library starts a process only through `program.zig`, and only with the
//! permission its caller hands it. This file is test-only, and it exists so
//! that a format change in git arrives as a red build rather than as a silent
//! divergence. A machine with no `git` skips the tests that need one.
//!
//! Every invocation carries a fixed set of `-c` settings, so a fixture's
//! bytes do not depend on git's defaults drifting. A test that wants one of
//! those settings — the line-ending fixture wants `core.autocrlf` — takes it
//! out of `defaults` and puts it in the repository's own config, which is
//! where the library reads it from.
//!
//! And every git the harness starts runs in an environment of its own: a
//! scratch home, no system or global config, no repository variables
//! inherited from whoever ran the suite, no ssh or gpg agent, no prompt, and
//! fixed author and committer dates.
//! A test is a guest on the person's machine. It must not read their
//! `~/.gitconfig`, reach their credential helper and store a test password
//! in their keychain, sign with their keys, or push through their ssh agent
//! — and an environment that merely leaves those out by convention, test by
//! test, is one forgotten line from doing all of it.

const std = @import("std");
const suite = @import("helpers.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// The settings every invocation carries unless a test changes them.
pub const default_settings = [_][]const u8{
    "-c", "user.name=Fixture",
    "-c", "user.email=fixture@example.com",
    "-c", "commit.gpgsign=false",
    "-c", "tag.gpgsign=false",
    "-c", "gc.auto=0",
    "-c", "core.autocrlf=false",
    "-c", "core.safecrlf=false",
    "-c", "core.excludesFile=",
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=relic-no-hooks",
    "-c", "advice.detachedHead=false",
    "-c", "protocol.file.allow=always",
    "-c", "feature.manyFiles=false",
} ++ (if (builtin.target.os.tag == .windows) [_][]const u8{
    // Git for Windows defaults to Schannel, which uses the machine trust
    // store even when these fixtures provide a PEM through sslCAInfo.
    "-c", "http.sslBackend=openssl",
} else [_][]const u8{});

/// A scratch repository built by the real `git`.
pub const Repo = struct {
    gpa: Allocator,
    tmp: std.testing.TmpDir,
    /// The working tree's directory.
    dir: Io.Dir,
    /// The `-c` settings every invocation carries. A test may replace this
    /// with a shorter list to let a repository's own config decide.
    defaults: []const []const u8 = &default_settings,
    /// Whether to print what git said when it exits non-zero. A test that
    /// expects the failure — the one that holds `index.lock` while git tries
    /// to take it — turns this off, so a passing run says nothing.
    report_failures: bool = true,
    /// The environment git runs in, when a test needs one of its own — a
    /// fixed commit date, or a `GNUPGHOME` that is not the person's. `null`
    /// is the harness's isolated one; a test building its own starts from
    /// `isolatedEnviron` or passes its map through `isolate`.
    environ: ?*const Environ.Map = null,
    /// The scratch home the isolated environment points at: empty, and
    /// removed with the repository. A harness made around a directory the
    /// test owns, rather than by `init`, has none, and its git runs with
    /// `no_home`.
    home: ?std.testing.TmpDir = null,
    /// The isolated environment itself, made by `init`.
    isolated: ?Environ.Map = null,

    /// Make a temporary directory and run `git init` in it.
    ///
    /// Returns `error.SkipZigTest` when there is no usable `git`, so a
    /// machine without one runs the rest of the suite rather than failing.
    pub fn init(gpa: Allocator, io: Io, extra_args: []const []const u8) !Repo {
        try requireGit(gpa, io);
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var home = std.testing.tmpDir(.{ .iterate = true });
        errdefer home.cleanup();
        const home_path = try home.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(home_path);
        var isolated = try isolatedEnviron(gpa, home_path);
        errdefer isolated.deinit();

        var repo: Repo = .{ .gpa = gpa, .tmp = tmp, .dir = tmp.dir, .home = home, .isolated = isolated };
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "init", "-q", "-b", "main" });
        try argv.appendSlice(gpa, extra_args);
        try argv.append(gpa, ".");
        try repo.exec(io, argv.items);
        return repo;
    }

    /// Remove the directory and release everything.
    pub fn deinit(r: *Repo) void {
        if (r.isolated) |*map| map.deinit();
        if (r.home) |*home| home.cleanup();
        r.tmp.cleanup();
        r.* = undefined;
    }

    /// Run `git` in the repository and return its standard output, which is
    /// the caller's. `args` begins with the subcommand; `git` and the default
    /// settings are prepended. A non-zero exit is `error.GitFailed`.
    pub fn run(r: *Repo, io: Io, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(r.gpa);
        try argv.append(r.gpa, "git");
        try argv.appendSlice(r.gpa, r.defaults);
        try argv.appendSlice(r.gpa, args);

        var own: ?Environ.Map = null;
        defer if (own) |*map| map.deinit();
        const environ_map = r.environ orelse if (r.isolated) |*map| map else blk: {
            own = try isolatedEnviron(r.gpa, no_home);
            break :blk &own.?;
        };
        const result = try std.process.run(r.gpa, io, .{
            .argv = argv.items,
            .cwd = .{ .dir = r.dir },
            .environ_map = environ_map,
        });
        defer r.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                if (r.report_failures) {
                    std.debug.print("git {s} failed ({d}):\n{s}\n", .{ args[0], code, result.stderr });
                }
                r.gpa.free(result.stdout);
                return error.GitFailed;
            },
            else => {
                r.gpa.free(result.stdout);
                return error.GitFailed;
            },
        }
        return result.stdout;
    }

    /// The environment `run` starts git in: the test's own when it set one,
    /// the isolated one otherwise. For a test that starts git itself, in a
    /// repository `init` made.
    pub fn environMap(r: *const Repo) *const Environ.Map {
        return r.environ orelse &r.isolated.?;
    }

    /// Run `git` with `input` on its standard input and return its standard
    /// output, which is the caller's, whatever it exits with.
    pub fn runInput(r: *Repo, io: Io, args: []const []const u8, input: []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(r.gpa);
        try argv.append(r.gpa, "git");
        try argv.appendSlice(r.gpa, r.defaults);
        try argv.appendSlice(r.gpa, args);
        var own: ?Environ.Map = null;
        defer if (own) |*map| map.deinit();
        const environ_map = r.environ orelse if (r.isolated) |*map| map else blk: {
            own = try isolatedEnviron(r.gpa, no_home);
            break :blk &own.?;
        };
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .dir = r.dir },
            .environ_map = environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer child.kill(io);
        {
            var buf: [4096]u8 = undefined;
            var w = child.stdin.?.writer(io, &buf);
            try w.interface.writeAll(input);
            try w.interface.flush();
            child.stdin.?.close(io);
            child.stdin = null;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(r.gpa);
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.reader(io, &buf);
        try reader.interface.appendRemainingUnlimited(r.gpa, &out);
        _ = try child.wait(io);
        return out.toOwnedSlice(r.gpa);
    }

    /// Run `git` and keep what it said, whatever it exits with.
    pub fn capture(r: *Repo, io: Io, args: []const []const u8) !Captured {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(r.gpa);
        try argv.append(r.gpa, "git");
        try argv.appendSlice(r.gpa, r.defaults);
        try argv.appendSlice(r.gpa, args);
        var own: ?Environ.Map = null;
        defer if (own) |*map| map.deinit();
        const environ_map = r.environ orelse if (r.isolated) |*map| map else blk: {
            own = try isolatedEnviron(r.gpa, no_home);
            break :blk &own.?;
        };
        const result = try std.process.run(r.gpa, io, .{
            .argv = argv.items,
            .cwd = .{ .dir = r.dir },
            .environ_map = environ_map,
        });
        const code: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
    }

    /// Run `git` and discard its output.
    pub fn exec(r: *Repo, io: Io, args: []const []const u8) !void {
        const out = try r.run(io, args);
        r.gpa.free(out);
    }

    /// Run `git` and return its output with the trailing newline removed.
    pub fn line(r: *Repo, io: Io, args: []const []const u8) ![]u8 {
        const out = try r.run(io, args);
        defer r.gpa.free(out);
        var end = out.len;
        while (end > 0 and (out[end - 1] == '\n' or out[end - 1] == '\r')) end -= 1;
        return r.gpa.dupe(u8, out[0..end]);
    }

    /// Write a file in the working tree, making the directories it needs.
    pub fn writeFile(r: *Repo, io: Io, path: []const u8, bytes: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try r.dir.createDirPath(io, parent);
        try r.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    /// The `.git` directory, opened. The caller closes it.
    pub fn gitDir(r: *Repo, io: Io) !Io.Dir {
        return r.dir.openDir(io, ".git", .{ .iterate = true });
    }

    /// The whole of a file in the repository, as the caller's bytes.
    pub fn readFile(r: *Repo, io: Io, path: []const u8) ![]u8 {
        return r.dir.readFileAlloc(io, path, r.gpa, .limited(64 << 20));
    }
};

/// What a `git` that may fail said: its exit code and both streams,
/// the caller's.
pub const Captured = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    /// Release both streams.
    pub fn deinit(c: *Captured, gpa: Allocator) void {
        gpa.free(c.stdout);
        gpa.free(c.stderr);
        c.* = undefined;
    }
};

/// A home that does not exist, for an environment built where there is no
/// directory to spare. git reads nothing from it and can write nothing to
/// it, which is what isolation asks.
pub const no_home = if (builtin.target.os.tag == .windows) "C:\\relic-test-no-home" else "/nonexistent/relic-test-home";

/// The variables `isolate` removes besides every `GIT_*` one: the agents
/// that hold a person's keys, the programs that would ask them for a
/// password, and the settings that move git's own config elsewhere.
const personal_variables = [_][]const u8{
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "SSH_ASKPASS",
    "SSH_ASKPASS_REQUIRE",
    "GPG_AGENT_INFO",
    "GPG_TTY",
    "GNUPGHOME",
    "XDG_CONFIG_HOME",
    "EMAIL",
};

/// The date every git a test starts commits, tags and logs with, unless the
/// test sets its own: `fixture_date` seconds past the epoch, UTC.
pub const fixture_date: i64 = 1_700_000_000;

/// Make `map` an environment no setting of the person's reaches: every
/// `GIT_*` variable and every entry of `personal_variables` removed, `HOME`
/// set to `home`, the global config read from `home` alone, the system
/// config not read at all, no terminal prompt, and git's author and
/// committer dates fixed at `fixture_date`. What else the map holds —
/// `PATH`, the locale, a test's own additions made afterwards — stays.
///
/// The dates are part of every commit's name. Left to the clock, a fixture
/// gets new names on every run, and with them a new order in every hash
/// table keyed by name: a test whose counts depend on that order passes or
/// fails by the second it ran in.
pub fn isolate(map: *Environ.Map, home: []const u8) !void {
    var i = map.count();
    while (i > 0) {
        i -= 1;
        const key = map.keys()[i];
        const personal = for (personal_variables) |name| {
            if (std.ascii.eqlIgnoreCase(key, name)) break true;
        } else false;
        if (personal or (key.len >= 4 and std.ascii.eqlIgnoreCase(key[0..4], "GIT_"))) {
            _ = map.swapRemove(key);
        }
    }
    try map.put("HOME", home);
    var global_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const sep = if (builtin.target.os.tag == .windows) "\\" else "/";
    try map.put("GIT_CONFIG_GLOBAL", try std.mem.print(&global_buf, "{s}" ++ sep ++ ".gitconfig", .{home}));
    try map.put("GIT_CONFIG_NOSYSTEM", "1");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try setDate(map, fixture_date);
}

/// A home for gpg of a test's own, under the build's `gnupg-fixture-root`.
/// The default is `.zig-cache/gpg`; a long checkout selects a short root
/// with `zig build test -Dgnupg-fixture-root=/short/path`. Each home has a
/// random name and private permissions where available, and `deinit`
/// removes it after its daemons have stopped. The environment `isolate`
/// supplies carries nothing of the person's.
pub const GnupgHome = struct {
    gpa: Allocator,
    name: []u8,

    /// Make one private scratch home for GnuPG.
    pub fn init(gpa: Allocator, io: Io) !GnupgHome {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var suffix: [16]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&suffix, &random_bytes);
        const fixture_root = build_options.gnupg_fixture_root;
        try Io.Dir.cwd().createDirPath(io, fixture_root);
        const root = try Io.Dir.cwd().realPathFileAlloc(io, fixture_root, gpa);
        defer gpa.free(root);
        const home_path = try std.Io.Dir.path.join(gpa, &.{ root, &suffix });
        std.debug.assert(std.Io.Dir.path.isAbsolute(home_path));
        errdefer gpa.free(home_path);
        try Io.Dir.createDirAbsolute(io, home_path, if (builtin.target.os.tag == .windows) .default_dir else .fromMode(0o700));
        return .{ .gpa = gpa, .name = home_path };
    }

    /// Absolute path to the scratch home.
    pub fn path(home: *const GnupgHome) []const u8 {
        return home.name;
    }

    /// Remove the scratch home after its GnuPG daemons have stopped.
    pub fn deinit(home: *GnupgHome, io: Io) void {
        // ziglint-ignore: Z026 deinit cannot fail; a home left behind is a random name under the fixture root, holding only test keys
        Io.Dir.cwd().deleteTree(io, home.path()) catch {};
        home.gpa.free(home.name);
        home.* = undefined;
    }
};

/// What Windows itself needs in the environment of a program it starts, and
/// a person does not set: `SystemRoot`, without which Winsock cannot load,
/// so that git's curl, started with nothing but `PATH`, cannot open a socket
/// and reports every server as one it could not connect to; and
/// `ProgramData`, without which Windows' OpenSSH exits 255 before a word.
const windows_system_variables = [_][]const u8{ "SystemRoot", "ProgramData" };

/// Carry `windows_system_variables` over from the test's own environment
/// into `map`, on Windows. Elsewhere there are none.
pub fn keepSystemVariables(gpa: Allocator, map: *Environ.Map) !void {
    if (builtin.target.os.tag != .windows) return;
    for (windows_system_variables) |name| {
        const value = std.testing.environ.getAlloc(gpa, name) catch continue;
        defer gpa.free(value);
        try map.put(name, value);
    }
}

/// Keep git from finding a repository above `dir`, an absolute path, for a
/// test that runs git outside any repository of its own. A test's
/// directories live inside the checkout the suite runs from, and git looking
/// upwards from one finds that checkout: its configuration, or, where the
/// checkout is a linked worktree or belongs to another user, a refusal.
pub fn noRepositoryAbove(map: *Environ.Map, dir: []const u8) !void {
    try map.put("GIT_CEILING_DIRECTORIES", std.Io.Dir.path.dirname(dir) orelse dir);
}

/// The test process's environment, isolated: see `isolate`.
pub fn isolatedEnviron(gpa: Allocator, home: []const u8) !Environ.Map {
    var map = try std.testing.environ.createMap(gpa);
    errdefer map.deinit();
    try isolate(&map, home);
    return map;
}

/// The environment a program the library starts runs in during a test: the
/// machine's `PATH` and what Windows needs (`keepSystemVariables`),
/// isolated as `isolate` isolates git, and nothing else, so no setting of
/// the person's reaches it. `error.SkipZigTest` where there is no `PATH`.
pub fn programEnviron(gpa: Allocator) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    const path = std.testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try map.put("PATH", path);
    try keepSystemVariables(gpa, &map);
    try isolate(&map, no_home);
    return map;
}

/// Install a native hook fixture with `action` and `data` as its sidecar
/// description. Git and relic run the same executable under the hook name.
pub fn fixtureHook(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, action: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const executable = if (builtin.target.os.tag == .windows) try gpa.print("{s}.exe", .{path}) else try gpa.dupe(u8, path);
    defer gpa.free(executable);
    try Io.Dir.cwd().copyFile(suite.path(.hook_fixture), dir, executable, io, .{});
    if (builtin.target.os.tag != .windows) {
        const file = try dir.openFile(io, executable, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    const sidecar = try gpa.print("{s}.fixture", .{executable});
    defer gpa.free(sidecar);
    const description = try gpa.print("{s}\n{s}", .{ action, data });
    defer gpa.free(description);
    try dir.writeFile(io, .{ .sub_path = sidecar, .data = description });
}

/// A shell command naming one fixture executable and its fixed arguments.
/// Git runs configured filter and helper commands through `sh` on every OS.
pub fn fixtureCommand(gpa: Allocator, executable: []const u8, arguments: []const u8) ![]u8 {
    const path = try gpa.dupe(u8, executable);
    defer gpa.free(path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(gpa);
    try command.append(gpa, '\'');
    for (path) |byte| {
        if (byte == '\'') {
            try command.appendSlice(gpa, "'\\''");
        } else try command.append(gpa, byte);
    }
    try command.appendSlice(gpa, "' ");
    try command.appendSlice(gpa, arguments);
    return command.toOwnedSlice(gpa);
}

/// An isolated environment, as `isolatedEnviron` makes with no home, with
/// both of git's dates fixed at `secs` seconds past the epoch, UTC, for
/// `Repo.environ`. The caller releases it.
pub fn datedEnv(gpa: Allocator, secs: i64) !Environ.Map {
    var map = try isolatedEnviron(gpa, no_home);
    errdefer map.deinit();
    try setDate(&map, secs);
    return map;
}

/// Move both of git's dates in an environment made by `datedEnv` or
/// `isolate`.
pub fn setDate(map: *Environ.Map, secs: i64) !void {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{d} +0000", .{secs});
    try map.put("GIT_AUTHOR_DATE", text);
    try map.put("GIT_COMMITTER_DATE", text);
}

/// How many cases a random parity corpus runs: every one, or an eighth of
/// them under ThreadSanitizer, whose every allocation records a stack and
/// which is there to check threads, not the corpora's answers. The full
/// count runs in every other build.
pub fn corpusCases(full: usize) usize {
    return if (builtin.sanitize_thread) @max(2, full / 8) else full;
}

var git_checked: bool = false;
var git_present: bool = false;
var git_major: u32 = 0;
var git_minor: u32 = 0;

/// `error.SkipZigTest` unless a usable `git` is on the path.
pub fn requireGit(gpa: Allocator, io: Io) !void {
    if (!git_checked) {
        git_checked = true;
        var env = try isolatedEnviron(gpa, no_home);
        defer env.deinit();
        const result = std.process.run(gpa, io, .{ .argv = &.{ "git", "--version" }, .environ_map = &env }) catch {
            git_present = false;
            return error.SkipZigTest;
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        git_present = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (git_present) parseVersion(result.stdout);
    }
    if (!git_present) return error.SkipZigTest;
}

/// `error.SkipZigTest` unless the `git` on the path is at least `major.minor`.
///
/// For a fixture whose subject is something git gained in a named release.
/// An older git writes what it always wrote, and a comparison against that
/// proves nothing about the thing being tested — so the test says which
/// release it needs and stands aside on anything older, rather than
/// asserting a shape that git was never asked to produce.
pub fn requireGitVersion(gpa: Allocator, io: Io, major: u32, minor: u32) !void {
    if (!try gitAtLeast(gpa, io, major, minor)) return error.SkipZigTest;
}

/// Whether the `git` on the path is at least `major.minor`, for a test
/// that compares one thing against every git and another only against the
/// release that has it. `error.SkipZigTest` when there is no git at all.
pub fn gitAtLeast(gpa: Allocator, io: Io, major: u32, minor: u32) !bool {
    try requireGit(gpa, io);
    if (git_major > major) return true;
    return git_major == major and git_minor >= minor;
}

/// The two leading numbers of `git version 2.43.0`, which is the shape every
/// build of git prints — including the ones that add their own suffix, such
/// as `2.39.5 (Apple Git-154)` and `2.45.1.windows.1`. A line that does not
/// parse leaves the version at zero, which is older than anything asked for.
fn parseVersion(line: []const u8) void {
    const prefix = "git version ";
    const at = std.mem.find(u8, line, prefix) orelse return;
    var numbers = std.mem.splitScalar(u8, line[at + prefix.len ..], '.');
    const major_text = numbers.next() orelse return;
    const minor_text = numbers.next() orelse return;
    git_major = std.fmt.parseUnsigned(u32, std.mem.trim(u8, major_text, " \t\r\n"), 10) catch return;
    git_minor = std.fmt.parseUnsigned(u32, std.mem.trim(u8, minor_text, " \t\r\n"), 10) catch {
        git_major = 0;
        return;
    };
}

test "a git the harness runs reads no configuration but the harness's own" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const listed = try repo.run(io, &.{ "config", "--list", "--show-scope" });
    defer gpa.free(listed);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, listed, "\n"), '\n');
    while (lines.next()) |entry| {
        const scope = entry[0 .. std.mem.findScalar(u8, entry, '\t') orelse entry.len];
        if (!std.mem.eql(u8, scope, "command") and !std.mem.eql(u8, scope, "local")) {
            std.debug.print("a setting from outside the fixture: {s}\n", .{entry});
            return error.TestUnexpectedResult;
        }
    }
    // The home git sees is the scratch one, and it is empty. `git var`
    // names the global file from 2.42 on; git for Windows prints the path
    // with forward slashes, whichever it was given.
    var it = repo.home.?.dir.iterate();
    try std.testing.expectEqual(@as(?Io.Dir.Entry, null), try it.next(io));
    if (!try gitAtLeast(gpa, io, 2, 42)) return;
    const home = try repo.line(io, &.{ "var", "GIT_CONFIG_GLOBAL" });
    defer gpa.free(home);
    const scratch = try gpa.dupe(u8, repo.isolated.?.get("HOME").?);
    defer gpa.free(scratch);
    if (builtin.target.os.tag == .windows) {
        std.mem.replaceScalar(u8, home, '\\', '/');
        std.mem.replaceScalar(u8, scratch, '\\', '/');
    }
    try std.testing.expect(std.mem.startsWith(u8, home, scratch));
}

test "isolation takes out a person's repository variables, agents and prompts, and keeps the rest" {
    const gpa = std.testing.allocator;
    var map: Environ.Map = .init(gpa);
    defer map.deinit();
    for ([_][2][]const u8{
        .{ "PATH", "/bin" },
        .{ "LANG", "C" },
        .{ "GIT_DIR", "/elsewhere/.git" },
        .{ "GIT_WORK_TREE", "/elsewhere" },
        .{ "GIT_INDEX_FILE", "/elsewhere/index" },
        .{ "GIT_ASKPASS", "/usr/bin/ask" },
        .{ "GIT_SSH_COMMAND", "ssh -i key" },
        .{ "GIT_CONFIG_COUNT", "1" },
        .{ "SSH_AUTH_SOCK", "/tmp/agent" },
        .{ "SSH_ASKPASS", "/usr/bin/ask" },
        .{ "GPG_AGENT_INFO", "/tmp/gpg" },
        .{ "GNUPGHOME", "/home/person/.gnupg" },
        .{ "XDG_CONFIG_HOME", "/home/person/.config" },
        .{ "HOME", "/home/person" },
    }) |pair| try map.put(pair[0], pair[1]);
    try isolate(&map, "/scratch");

    for ([_][]const u8{
        "GIT_DIR",          "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_ASKPASS",    "GIT_SSH_COMMAND",
        "GIT_CONFIG_COUNT", "SSH_AUTH_SOCK", "SSH_ASKPASS",    "GPG_AGENT_INFO", "GNUPGHOME",
        "XDG_CONFIG_HOME",
    }) |name| try std.testing.expect(map.get(name) == null);
    try std.testing.expectEqualStrings("/bin", map.get("PATH").?);
    try std.testing.expectEqualStrings("C", map.get("LANG").?);
    try std.testing.expectEqualStrings("/scratch", map.get("HOME").?);
    try std.testing.expectEqualStrings("1", map.get("GIT_CONFIG_NOSYSTEM").?);
    try std.testing.expectEqualStrings("0", map.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expect(std.mem.startsWith(u8, map.get("GIT_CONFIG_GLOBAL").?, "/scratch"));
}

test "a repository variable in the environment cannot send the harness's git to another repository" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var other = try Repo.init(gpa, io, &.{});
    defer other.deinit();
    const other_git = try other.dir.realPathFileAlloc(io, ".git", gpa);
    defer gpa.free(other_git);

    // What a hook or a shell would have left behind, run through `isolate`.
    var env = try repo.isolated.?.clone(gpa);
    defer env.deinit();
    try env.put("GIT_DIR", other_git);
    try isolate(&env, repo.isolated.?.get("HOME").?);
    repo.environ = &env;
    const git_dir = try repo.line(io, &.{ "rev-parse", "--absolute-git-dir" });
    defer gpa.free(git_dir);
    try std.testing.expect(!std.mem.eql(u8, git_dir, other_git));
}

test "GnuPG test homes use the selected root and clean up independently" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = build_options.gnupg_fixture_root;
    var first = try GnupgHome.init(gpa, io);
    defer first.deinit(io);
    const removed = removed: {
        var second = try GnupgHome.init(gpa, io);
        defer second.deinit(io);
        break :removed try gpa.dupe(u8, second.path());
    };
    defer gpa.free(removed);
    const resolved = try Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings(resolved, std.Io.Dir.path.dirname(first.path()).?);
    try std.testing.expectEqualStrings(resolved, std.Io.Dir.path.dirname(removed).?);
    try std.testing.expect(!std.mem.eql(u8, first.path(), removed));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, removed, .{}));
    try Io.Dir.cwd().access(io, first.path(), .{});
}
