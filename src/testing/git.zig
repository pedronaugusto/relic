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
const git_release = @import("git_release.zig");
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
        try argv.append(r.gpa, program());
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
        try argv.append(r.gpa, program());
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
        try argv.append(r.gpa, program());
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

/// `default_settings` without `core.autocrlf=false`, for a test that sets
/// it in the repository's own config, where the library reads it.
pub const settings_without_autocrlf = blk: {
    const all = default_settings;
    var out: [all.len - 2][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < all.len) : (i += 2) {
        if (std.mem.eql(u8, all[i + 1], "core.autocrlf=false")) continue;
        out[n] = all[i];
        out[n + 1] = all[i + 1];
        n += 2;
    }
    break :blk out;
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
/// config not read at all, no terminal prompt, no repository looked for
/// above `testsRoot` (`noRepositoryAboveTests`), and git's author and
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
    try noRepositoryAboveTests(map);
    try setDate(map, fixture_date);
}

/// Keep git from looking for a repository above `testsRoot`, for an
/// environment `isolate` does not make: every test's directories live
/// under it, inside the checkout the suite runs from, and git looking
/// upwards from one would find that checkout: its configuration, or, where
/// a `.git` file above names nothing or the checkout is another user's, a
/// refusal.
pub fn noRepositoryAboveTests(map: *Environ.Map) !void {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    try map.put("GIT_CEILING_DIRECTORIES", try testsRoot(&root_buf));
}

/// Where `std.testing.tmpDir` makes every test's directories,
/// `.zig-cache/tmp`, absolute, in `buffer`: a place git can start in
/// that holds no repository, for a run with no directory of its own.
pub fn testsRoot(buffer: []u8) ![]const u8 {
    const io = std.testing.io;
    var root = try Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/tmp", .{});
    defer root.close(io);
    return buffer[0..try root.realPath(io, buffer)];
}

/// A home for gpg of a test's own, under the build's `gnupg-fixture-root`.
/// The default is `/tmp` (`.zig-cache/gpg` on Windows), short from any
/// checkout: gpg-agent's sockets are made in the home, and a socket path
/// past 104 bytes (macOS) or 108 (Linux) cannot be bound. Each home is
/// named `relic-gpg-` and a random suffix, with private permissions where
/// available, and `deinit` removes it after its daemons have stopped. The
/// environment `isolate` supplies carries nothing of the person's.
pub const GnupgHome = struct {
    gpa: Allocator,
    name: []u8,
    /// `name` as `GNUPGHOME` gives it to the `gpg` on the path: see
    /// `environValue`. `name` itself where the forms agree.
    value: []u8,

    /// Make one private scratch home for GnuPG.
    pub fn init(gpa: Allocator, io: Io) !GnupgHome {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        const prefix = "relic-gpg-";
        var name: [prefix.len + 16]u8 = undefined;
        @memcpy(name[0..prefix.len], prefix);
        _ = std.base64.url_safe_no_pad.Encoder.encode(name[prefix.len..], &random_bytes);
        const fixture_root = build_options.gnupg_fixture_root;
        // The root is made when missing; one that is there may be a link
        // (macOS's `/tmp`), which making a path through would refuse.
        const root = Io.Dir.cwd().realPathFileAlloc(io, fixture_root, gpa) catch |err| switch (err) {
            error.FileNotFound => made: {
                try Io.Dir.cwd().createDirPath(io, fixture_root);
                break :made try Io.Dir.cwd().realPathFileAlloc(io, fixture_root, gpa);
            },
            else => |e| return e,
        };
        defer gpa.free(root);
        const home_path = try std.Io.Dir.path.join(gpa, &.{ root, &name });
        std.debug.assert(std.Io.Dir.path.isAbsolute(home_path));
        errdefer gpa.free(home_path);
        try Io.Dir.createDirAbsolute(io, home_path, if (builtin.target.os.tag == .windows) .default_dir else .fromMode(0o700));
        const value = if (builtin.target.os.tag == .windows and try gpgNamesHomesAsMsys(gpa, io)) try msysPath(gpa, home_path) else try gpa.dupe(u8, home_path);
        return .{ .gpa = gpa, .name = home_path, .value = value };
    }

    /// Absolute path to the scratch home.
    pub fn path(home: *const GnupgHome) []const u8 {
        return home.name;
    }

    /// The home as `GNUPGHOME` is to name it to the `gpg` on the path.
    /// Git for Windows' gpg is an MSYS program, which takes a home that
    /// does not start with `/` as relative to where it runs, so it is
    /// given `D:\a\b` as `/d/a/b`, the form git's test suite gives it from
    /// its shell's `$(pwd)`; elsewhere, and to a gpg of Windows' own, the
    /// path as it is.
    pub fn environValue(home: *const GnupgHome) []const u8 {
        return home.value;
    }

    /// Remove the scratch home after its GnuPG daemons have stopped.
    pub fn deinit(home: *GnupgHome, io: Io) void {
        // glint-ignore: Z026 -- deinit cannot fail; a home left behind is a random name under the fixture root, holding only test keys
        Io.Dir.cwd().deleteTree(io, home.path()) catch {};
        home.gpa.free(home.name);
        home.gpa.free(home.value);
        home.* = undefined;
    }
};

/// Whether the `gpg` on the path names its homes as MSYS paths, as
/// Git for Windows' does: the home `gpg --version` reports starts with
/// `/`. `false` when there is no gpg to ask.
fn gpgNamesHomesAsMsys(gpa: Allocator, io: Io) !bool {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "gpg", "--version" } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
    while (lines.next()) |line| {
        const home = std.mem.cutPrefix(u8, line, "Home: ") orelse continue;
        return home.len != 0 and home[0] == '/';
    }
    return false;
}

/// `D:\a\b` as MSYS names it: `/d/a/b`. Anything without a drive is
/// only turned to `/`.
fn msysPath(gpa: Allocator, windows_path: []const u8) Allocator.Error![]u8 {
    const drive = windows_path.len >= 2 and windows_path[1] == ':' and std.ascii.isAlphabetic(windows_path[0]);
    const out = if (drive)
        try std.mem.concat(gpa, u8, &.{ "/", &.{std.ascii.toLower(windows_path[0])}, windows_path[2..] })
    else
        try gpa.dupe(u8, windows_path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

test "a Windows path is named as MSYS names it" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{ .{ "D:\\a\\relic\\gpg", "/d/a/relic/gpg" }, .{ "c:/x/y", "/c/x/y" }, .{ "\\\\server\\share", "//server/share" } }) |case| {
        const got = try msysPath(gpa, case[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

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

/// Keep git from looking for a repository above `dir`, an absolute path:
/// `dir` alone, for a test whose repository must be there or nowhere.
/// Above `testsRoot`, `noRepositoryAboveTests` already keeps git from
/// looking.
pub fn noRepositoryAbove(map: *Environ.Map, dir: []const u8) !void {
    try map.put("GIT_CEILING_DIRECTORIES", std.Io.Dir.path.dirname(dir) orelse dir);
}

/// The test process's environment, isolated: see `isolate`, with `PATH`
/// as `searchPath` makes it.
pub fn isolatedEnviron(gpa: Allocator, home: []const u8) !Environ.Map {
    var map = try std.testing.environ.createMap(gpa);
    errdefer map.deinit();
    const path = try searchPath(gpa);
    defer gpa.free(path);
    try map.put("PATH", path);
    try isolate(&map, home);
    return map;
}

//=====================================================================
// The tools on a hosted runner, as git_release.zig finds them.
//=====================================================================

const HostedGit = git_release.Hosted;

/// `null` off a hosted runner.
fn hostedGit() ?HostedGit {
    return git_release.hosted(std.testing.allocator, std.testing.environ);
}

fn hostedDirs(a: Allocator, git: ?HostedGit) ![]const []const u8 {
    return git_release.hostedDirs(a, std.testing.environ, git);
}

/// The `PATH` every program the suite starts sees: the hosted tools'
/// directories, then the test process's own `PATH` (the native floor job
/// installs its Git there). The caller frees it.
/// `error.SkipZigTest` where there is no `PATH`.
pub fn searchPath(gpa: Allocator) ![]u8 {
    const path = std.testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const dirs = try hostedDirs(arena.allocator(), hostedGit());
    return joinSearchPath(gpa, dirs, path);
}

fn joinSearchPath(gpa: Allocator, dirs: []const []const u8, rest: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (dirs) |dir| {
        try out.appendSlice(gpa, dir);
        try out.append(gpa, std.Io.Dir.path.delimiter);
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// Whether the signing comparisons must find their programs on this
/// machine rather than skip: a Linux hosted job installs them for every git
/// but the oldest, whose job runs without them.
pub fn hostedSigners() bool {
    const git = hostedGit() orelse return false;
    return builtin.target.os.tag == .linux and git != .old;
}

/// The git a test starts itself, with `std.process`: Zig looks a bare name
/// up in this process's own `PATH`, never in the child's, so on a hosted
/// runner the installed git is named by its path. Elsewhere it is `git`,
/// found as `searchPath` would find it. Found once; the build has asked it
/// for its release before the tests run (testing/held_git.zig).
pub fn program() []const u8 {
    if (program_state.load(.acquire) != 2) {
        if (program_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const found = git_release.program(arena.allocator(), std.testing.io, std.testing.environ);
            if (found.len <= program_buffer.len) {
                @memcpy(program_buffer[0..found.len], found);
                program_name = program_buffer[0..found.len];
            }
            git_version = probeVersion(program_name);
            program_state.store(2, .release);
        } else while (program_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return program_name;
}

var program_state: std.atomic.Value(u8) = .init(0);
var program_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
var program_name: []const u8 = "git";
/// The release of the git `program` found, `null` when there is none; one
/// whose `--version` names no release reads as 0.0.0.
var git_version: ?git_release.Version = null;

fn probeVersion(name: []const u8) ?git_release.Version {
    const gpa = std.testing.allocator;
    var env = isolatedEnviron(gpa, no_home) catch return null;
    defer env.deinit();
    const result = std.process.run(gpa, std.testing.io, .{ .argv = &.{ name, "--version" }, .environ_map = &env }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return git_release.parse(result.stdout) orelse .{ .major = 0, .minor = 0, .patch = 0 };
}

test "a hosted job's tools come before the machine's own, in order" {
    const gpa = std.testing.allocator;
    const sep = [1]u8{std.Io.Dir.path.delimiter};
    const joined = try joinSearchPath(gpa, &.{ "tools/git/bin", "tools/lfs/bin" }, "rest");
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("tools/git/bin" ++ sep ++ "tools/lfs/bin" ++ sep ++ "rest", joined);
    const alone = try joinSearchPath(gpa, &.{}, "rest");
    defer gpa.free(alone);
    try std.testing.expectEqualStrings("rest", alone);
    try std.testing.expectEqual(@as(usize, 0), (try hostedDirs(gpa, null)).len);
    try std.testing.expectEqual(@as(usize, 0), (try hostedDirs(gpa, .old)).len);
}

/// The environment a program the library starts runs in during a test: the
/// machine's `PATH` and what Windows needs (`keepSystemVariables`),
/// isolated as `isolate` isolates git, and nothing else, so no setting of
/// the person's reaches it. `error.SkipZigTest` where there is no `PATH`.
pub fn programEnviron(gpa: Allocator) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    const path = try searchPath(gpa);
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

/// `error.SkipZigTest` unless a usable `git` is on the path.
pub fn requireGit(gpa: Allocator, io: Io) !void {
    _ = gpa;
    _ = io;
    _ = program();
    if (git_version == null) return error.SkipZigTest;
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

/// Refs for a fetch comparison. Relic follows Git 2.48's automatic remote
/// HEAD policy; check that separately when the reference Git predates it.
/// Every other ref still has to match. The caller frees the result.
pub fn fetchRefs(r: *Repo, io: Io, format: []const u8, modern: bool) ![]u8 {
    const refs = try r.run(io, &.{ "for-each-ref", format });
    errdefer r.gpa.free(refs);
    if (!modern or try gitAtLeast(r.gpa, io, 2, 48)) return refs;
    const head = try r.line(io, &.{ "symbolic-ref", "refs/remotes/origin/HEAD" });
    defer r.gpa.free(head);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", head);
    try std.testing.expect(std.mem.startsWith(u8, refs, "refs/remotes/origin/HEAD "));
    const end = std.mem.findScalar(u8, refs, '\n') orelse return error.TestUnexpectedResult;
    const other = try r.gpa.dupe(u8, refs[end + 1 ..]);
    r.gpa.free(refs);
    return other;
}

/// The ref format a fixture's repositories are made with.
pub const RefFormat = enum {
    files,
    reftable,

    /// What `git init` is told: nothing for the files format, which
    /// every git writes and which no `--ref-format` before 2.45 names.
    pub fn initArgs(format: RefFormat) []const []const u8 {
        return switch (format) {
            .files => &.{},
            .reftable => &.{"--ref-format=reftable"},
        };
    }
};

/// The ref formats a comparison with git runs on: the files format, and
/// reftable where the git found writes it (2.45 and newer), so the floor's
/// git runs the comparison once. `error.SkipZigTest` when there is no git.
pub fn refFormats(gpa: Allocator, io: Io) ![]const RefFormat {
    return if (try gitAtLeast(gpa, io, 2, 45)) &.{ .files, .reftable } else &.{.files};
}

/// Run a comparison once for each ref format the git found writes
/// (`refFormats`), and say which one a failure was in.
pub fn eachRefFormat(in_format: *const fn (RefFormat) anyerror!void) !void {
    for (try refFormats(std.testing.allocator, std.testing.io)) |format| {
        in_format(format) catch |err| {
            if (err != error.SkipZigTest) std.debug.print("in the {t} ref format\n", .{format});
            return err;
        };
    }
}

/// Whether the `git` on the path is at least `major.minor`, for a test
/// that compares one thing against every git and another only against the
/// release that has it. `error.SkipZigTest` when there is no git at all.
pub fn gitAtLeast(gpa: Allocator, io: Io, major: u32, minor: u32) !bool {
    try requireGit(gpa, io);
    const found = git_version.?;
    if (found.major > major) return true;
    return found.major == major and found.minor >= minor;
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
