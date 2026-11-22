//! Native CI tool setup, cached outside the checkout and retried by preflight.
const std = @import("std");
const builtin = @import("builtin");
const git_release = @import("git_release");

/// The oldest Git the oldest-git job builds (`ci-setup-old`, a job of
/// ci/workflow.json's), and the LFS release every job installs; the release
/// every other job runs is `git_release.held`.
const floor_version = "2.39.5";
const floor_sha256 = "c58da92c378df4a986ca33266897a7397e86c22ee266a284d8c2432c39066b59";
const lfs_version = "3.8.0";
const make_flags = [_][]const u8{ "NO_TCLTK=1", "NO_GETTEXT=1", "NO_RUST=1" };

/// The suite's fixtures need Git 2.47 or later: git's development branch,
/// which the master job runs.
fn recent(text: []const u8) bool {
    const found = git_release.parse(text) orelse return false;
    return found.major > 2 or (found.major == 2 and found.minor >= 47);
}

/// Whether `git --version` said the release the comparisons are held to.
fn held(text: []const u8) bool {
    const found = git_release.parse(text) orelse return false;
    return found.eql(git_release.held);
}
const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    fn command(c: Context, argv: []const []const u8) !void {
        for (0..3) |attempt| {
            c.execute(argv) catch |err| {
                if (attempt == 2) return err;
                try report("CI tool command {s} failed; retry {d}/3\n", c.io, .{ argv[0], attempt + 2 });
                try std.Io.sleep(c.io, .fromSeconds(@as(i64, 5) << @intCast(attempt)), .awake);
                continue;
            };
            return;
        }
    }
    fn execute(c: Context, argv: []const []const u8) !void {
        var child = try std.process.spawn(c.io, .{ .argv = argv, .environ_map = c.env });
        const term = try child.wait(c.io);
        if (term != .exited or term.exited != 0) return error.ToolCommandFailed;
    }
    fn capture(c: Context, argv: []const []const u8) ![]const u8 {
        const result = try std.process.run(c.a, c.io, .{ .argv = argv, .environ_map = c.env });
        if (result.term != .exited or result.term.exited != 0) return error.ToolCommandFailed;
        return result.stdout;
    }
    fn exists(c: Context, path: []const u8) bool {
        std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
        return true;
    }
    fn fetch(c: Context, url: []const u8, file: []const u8, expected: []const u8) !void {
        var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
        defer client.deinit();
        var output: std.Io.Writer.Allocating = .init(c.a);
        defer output.deinit();
        const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &output.writer });
        if (response.status != .ok) return error.DownloadFailed;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(output.written(), &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected)) return error.DownloadDigestMismatch;
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = file, .data = output.written() });
    }
};

/// The gits the compatibility jobs of ci/workflow.json build themselves
/// (the oldest-git job, and the advisory git-master job); every other job
/// runs preflight's held git.
const Git = enum { master, floor };

fn buildGit(c: Context, root: []const u8, kind: Git) !void {
    const master = kind == .master;
    const name = switch (kind) {
        .master => "master",
        .floor => "old-git",
    };
    const prefix = try std.Io.Dir.path.join(c.a, &.{ root, name });
    // A cached build is kept only while it is the release asked for.
    const built = try std.Io.Dir.path.join(c.a, &.{ prefix, "bin", "git" });
    if (!master and c.exists(built)) {
        const version = try c.capture(&.{ built, "--version" });
        if (std.mem.eql(u8, std.mem.trimEnd(u8, version, "\r\n"), "git version " ++ floor_version)) return;
        try std.Io.Dir.cwd().deleteTree(c.io, prefix);
    }
    try c.command(&.{ "sudo", "apt-get", "update" });
    try c.command(&.{ "sudo", "apt-get", "install", "-y", "--no-install-recommends", "build-essential", "gettext", "libcurl4-openssl-dev", "libexpat1-dev", "libssl-dev", "zlib1g-dev", "gnupg", "openssh-client" });
    const source = try std.Io.Dir.path.join(c.a, &.{ root, try c.a.print("{s}-source", .{name}) });
    if (master) {
        if (c.exists(source)) {
            try c.command(&.{ "git", "-C", source, "fetch", "--depth", "1", "origin", "master" });
            try c.command(&.{ "git", "-C", source, "checkout", "--detach", "FETCH_HEAD" });
        } else try c.command(&.{ "git", "clone", "--depth", "1", "https://github.com/git/git.git", source });
    } else {
        // The tree an attempt before this one unpacked and part built is
        // built on: preflight gives each attempt at the setup five minutes,
        // and a build cut short resumes where make stopped. A tree of
        // another release must not underlie this one.
        if (!wholeRelease(c.a, c.io, source, floor_version)) {
            const archive = try std.Io.Dir.path.join(c.a, &.{ root, try c.a.print("{s}.tar.xz", .{name}) });
            try c.fetch("https://mirrors.edge.kernel.org/pub/software/scm/git/git-" ++ floor_version ++ ".tar.xz", archive, floor_sha256);
            try std.Io.Dir.cwd().deleteTree(c.io, source);
            try std.Io.Dir.cwd().createDirPath(c.io, source);
            try c.command(&.{ "tar", "-xJf", archive, "-C", source, "--strip-components=1" });
            try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.Io.Dir.path.join(c.a, &.{ source, unpacked_marker }), .data = floor_version ++ "\n" });
        }
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "make", "-C", source, try c.a.print("-j{d}", .{try std.Thread.getCpuCount()}) });
    try args.appendSlice(c.a, if (master) &.{ "NO_TCLTK=1", "NO_GETTEXT=1" } else &make_flags);
    try args.append(c.a, try c.a.print("prefix={s}", .{prefix}));
    try args.append(c.a, "all");
    try c.command(args.items);
    args.items[args.items.len - 1] = "install";
    try c.command(args.items);
}

/// The file setup writes in a source tree once `tar` has unpacked all of
/// it, naming the release.
const unpacked_marker = "relic-unpacked";

/// Whether `source` holds git `version`'s release tarball, whole: setup
/// marks a tree only after `tar` unpacked it all, so a tree an attempt was
/// cut short in unpacking has no mark.
fn wholeRelease(a: std.mem.Allocator, io: std.Io, source: []const u8, version: []const u8) bool {
    const file = std.Io.Dir.path.join(a, &.{ source, unpacked_marker }) catch return false;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64)) catch return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, text, "\r\n"), version);
}

fn lfs(c: Context, root: []const u8) !void {
    const bin = try std.Io.Dir.path.join(c.a, &.{ root, "lfs", "bin" });
    const executable = try std.Io.Dir.path.join(c.a, &.{ bin, if (builtin.target.os.tag == .windows) "git-lfs.exe" else "git-lfs" });
    if (c.exists(executable)) return;
    // The host's own system and processor, from git-lfs's sha256sums.
    const arm = builtin.target.cpu.arch == .aarch64;
    if (!arm and builtin.target.cpu.arch != .x86_64) return error.UnsupportedHost;
    const asset, const digest = switch (builtin.target.os.tag) {
        .linux => if (arm)
            .{ "git-lfs-linux-arm64-v3.8.0.tar.gz", "ac9c8efac980bb0505ead384d087e2acb6486fd8498691a2165fa174ec6118c2" }
        else
            .{ "git-lfs-linux-amd64-v3.8.0.tar.gz", "e455e00f15d9b95661b8d53498ffb0c3367962cf1ec73c31ab7369516cd6ab8d" },
        .macos => if (arm)
            .{ "git-lfs-darwin-arm64-v3.8.0.zip", "caff76a7d070d8160c89bc39b6e85d98f24135b6fed038a3b4de2590d25102d8" }
        else
            .{ "git-lfs-darwin-amd64-v3.8.0.zip", "f1c17aeca0b4eaab9ea606226477dbed3b84b56fe0811a9f967d2ea2b2393c53" },
        .windows => if (arm)
            .{ "git-lfs-windows-arm64-v3.8.0.zip", "72403a96eae6689c3a4038c99e5d9e0938ef5552c71a234aef65ef0c314af081" }
        else
            .{ "git-lfs-windows-amd64-v3.8.0.zip", "b62e7b8ceddee635f691233d77de8eaa4b213e9209e0173811d8cfa77f7882c1" },
        else => return error.UnsupportedHost,
    };
    const archive = try std.Io.Dir.path.join(c.a, &.{ root, asset });
    try c.fetch(try c.a.print("https://github.com/git-lfs/git-lfs/releases/download/v{s}/{s}", .{ lfs_version, asset }), archive, digest);
    const unpacked = try std.Io.Dir.path.join(c.a, &.{ root, "lfs-unpacked" });
    try std.Io.Dir.cwd().createDirPath(c.io, unpacked);
    if (builtin.target.os.tag == .linux) try c.command(&.{ "tar", "-xzf", archive, "-C", unpacked }) else try c.command(&.{ "tar", "-xf", archive, "-C", unpacked });
    var directory = try std.Io.Dir.cwd().openDir(c.io, unpacked, .{ .iterate = true });
    defer directory.close(c.io);
    var walker = try directory.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (!std.mem.eql(u8, entry.basename, if (builtin.target.os.tag == .windows) "git-lfs.exe" else "git-lfs")) continue;
        try std.Io.Dir.cwd().createDirPath(c.io, bin);
        try directory.copyFile(entry.path, std.Io.Dir.cwd(), executable, c.io, .{});
        const file = try std.Io.Dir.cwd().openFile(c.io, executable, .{});
        defer file.close(c.io);
        if (std.Io.File.Permissions.has_executable_bit) try file.setPermissions(c.io, .executable_file);
        return;
    }
    return error.MissingLfsExecutable;
}

fn old(c: Context, root: []const u8) !void {
    try buildGit(c, root, .floor);
    const bin = try std.Io.Dir.path.join(c.a, &.{ root, "old-git", "bin" });
    const git = try std.Io.Dir.path.join(c.a, &.{ bin, "git" });
    const version = try c.capture(&.{ git, "--version" });
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, version, "\r\n"), "git version " ++ floor_version)) return error.WrongOldestGit;
    try lfs(c, root);
    try selectLfs(c, root, git);
    // The next hosted step must choose this Git before the runner's own, and
    // before preflight's held git, which an earlier step put first on the
    // path: the tests start the path's `git` (preflight's test runner keeps
    // every PREFLIGHT_ variable from them, PREFLIGHT_GIT too), and compare
    // against the oldest git where RELIC_GIT says so.
    try addToPath(c, &.{ bin, try std.Io.Dir.path.join(c.a, &.{ root, "lfs", "bin" }) });
    try addToEnv(c, &.{.{ "RELIC_GIT", "old" }});
    try report("{s}", c.io, .{version});
}

/// `dirs` on the path of the hosted steps after this one (`GITHUB_PATH`),
/// the first first; ahead of the runner's own, behind nothing setup did
/// not put there.
fn addToPath(c: Context, dirs: []const []const u8) !void {
    try appendPath(c.a, c.io, c.env.get("GITHUB_PATH") orelse return error.HostedSetupOnly, dirs);
}

/// `variables` set for the hosted steps after this one (`GITHUB_ENV`), each
/// over what an earlier step set.
fn addToEnv(c: Context, variables: []const [2][]const u8) !void {
    try appendEnv(c.a, c.io, c.env.get("GITHUB_ENV") orelse return error.HostedSetupOnly, variables);
}

/// `variables` appended to the environment file `env_file`, `name=value` a
/// line, in order: GitHub reads the file top to bottom, so a name's last
/// line is its value.
fn appendEnv(a: std.mem.Allocator, io: std.Io, env_file: []const u8, variables: []const [2][]const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, env_file, .{ .mode = .read_write });
    defer file.close(io);
    var at = (try file.stat(io)).size;
    for (variables) |variable| {
        const line = try a.print("{s}={s}\n", .{ variable[0], variable[1] });
        try file.writePositionalAll(io, line, at);
        at += line.len;
    }
}

/// `dirs` appended to the path file `path_file`, one a line, the last first.
/// The file is opened to read as well as write: its size is where they go,
/// and on Windows a handle opened only to write has no right to read the
/// file's attributes, so asking its size is AccessDenied (every Windows
/// shard of push run 44588375043).
fn appendPath(a: std.mem.Allocator, io: std.Io, path_file: []const u8, dirs: []const []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path_file, .{ .mode = .read_write });
    defer file.close(io);
    var at = (try file.stat(io)).size;
    // GitHub puts each line it reads ahead of the path so far, so the last
    // line written is the first on the path.
    var i = dirs.len;
    while (i > 0) {
        i -= 1;
        const line = try a.print("{s}\n", .{dirs[i]});
        try file.writePositionalAll(io, line, at);
        at += line.len;
    }
}

fn selectLfs(c: Context, root: []const u8, git: []const u8) !void {
    const bin = try std.Io.Dir.path.join(c.a, &.{ root, "lfs", "bin" });
    if (builtin.target.os.tag == .windows) {
        // Git searches its own exec directory before PATH. Replace its
        // bundled LFS with the verified cached version on this hosted runner.
        const exec_path = std.mem.trim(u8, try c.capture(&.{ git, "--exec-path" }), "\r\n");
        const source = try std.Io.Dir.path.join(c.a, &.{ bin, "git-lfs.exe" });
        const destination = try std.Io.Dir.path.join(c.a, &.{ exec_path, "git-lfs.exe" });
        try std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), destination, c.io, .{});
    }
    var env = try c.env.clone(c.a);
    defer env.deinit();
    const separator = if (builtin.target.os.tag == .windows) ";" else ":";
    try env.put("PATH", try c.a.print("{s}{s}{s}", .{ bin, separator, c.env.get("PATH") orelse "" }));
    const selected: Context = .{ .a = c.a, .io = c.io, .env = &env };
    const version = try selected.capture(&.{ git, "lfs", "version" });
    if (!std.mem.startsWith(u8, version, "git-lfs/" ++ lfs_version ++ " ")) return error.WrongLfsVersion;
    try report("{s}", c.io, .{version});
}

fn report(comptime format: []const u8, io: std.Io, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // A gate run here, outside GitHub Actions, installs nothing: the
    // machine's own git and git-lfs are what its tests run with, and the
    // tests stop at a git other than the release they are held to
    // (`relic-held-git`).
    if (!std.mem.eql(u8, init.environ_map.get("GITHUB_ACTIONS") orelse "", "true")) return;
    const c: Context = .{ .a = a, .io = init.io, .env = init.environ_map };
    const args = try init.minimal.args.toSlice(a);
    const root = try std.Io.Dir.path.join(a, &.{ init.environ_map.get("RUNNER_TEMP") orelse return error.HostedSetupOnly, "preflight-tools" });
    try std.Io.Dir.cwd().createDirPath(c.io, root);
    if (args.len > 1 and std.mem.eql(u8, args[1], "old")) return old(c, root);
    if (args.len > 1 and std.mem.eql(u8, args[1], "master")) return gitMaster(c, root);
    // Every other job runs preflight's held git, which a step before this
    // one built or installed and put first on the path, its program in
    // `PREFLIGHT_GIT`. What is left here is git-lfs, and on Linux the
    // signers the signing tests need (`testing/git.zig`'s `signersRequired`).
    if (builtin.target.os.tag == .linux) {
        try c.command(&.{ "sudo", "apt-get", "update" });
        try c.command(&.{ "sudo", "apt-get", "install", "-y", "--no-install-recommends", "gnupg", "openssh-client" });
    }
    const git = init.environ_map.get("PREFLIGHT_GIT") orelse "git";
    try lfs(c, root);
    try selectLfs(c, root, git);
    try addToPath(c, &.{try std.Io.Dir.path.join(a, &.{ root, "lfs", "bin" })});
    const version = c.capture(&.{ git, "--version" }) catch |err| {
        try report("relic's comparisons are held to git {f} (src/testing/git_release.zig), and this job has no git that runs ({s}): preflight's held git (ci/workflow.json `git`) puts it first on the path and in PREFLIGHT_GIT\n", c.io, .{ git_release.held, git });
        return err;
    };
    if (!held(version)) {
        try report("relic's comparisons are held to git {f} (src/testing/git_release.zig); this runner has {s}", c.io, .{ git_release.held, version });
        return error.NotTheHeldGit;
    }
    try report("{s}", c.io, .{version});
}

/// git's development branch, built for the advisory job that runs it,
/// first on the path of the steps after this one with its git-lfs, as the
/// oldest git is, and `RELIC_GIT=master`.
fn gitMaster(c: Context, root: []const u8) !void {
    if (builtin.target.os.tag != .linux) return error.UnsupportedHost;
    try buildGit(c, root, .master);
    const bin = try std.Io.Dir.path.join(c.a, &.{ root, "master", "bin" });
    const git = try std.Io.Dir.path.join(c.a, &.{ bin, "git" });
    const version = try c.capture(&.{ git, "--version" });
    if (!recent(version)) return error.GitTooOld;
    try lfs(c, root);
    try selectLfs(c, root, git);
    try addToPath(c, &.{ bin, try std.Io.Dir.path.join(c.a, &.{ root, "lfs", "bin" }) });
    try addToEnv(c, &.{.{ "RELIC_GIT", "master" }});
    try report("{s}", c.io, .{version});
}

test "the path file gets the directories after what it held, the first last, so first on the path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "path", .data = "D:\\runner\\bin\n" });
    const path_file = try std.Io.Dir.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "path" });
    defer gpa.free(path_file);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try appendPath(arena.allocator(), io, path_file, &.{ "tools\\git", "tools\\lfs" });
    const written = try tmp.dir.readFileAlloc(io, "path", gpa, .limited(4096));
    defer gpa.free(written);
    try std.testing.expectEqualStrings("D:\\runner\\bin\ntools\\lfs\ntools\\git\n", written);
}

test "the env file gets the variables after what it held, in order, so the last line of a name is its value" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "env", .data = "RELIC_GIT=master\n" });
    const env_file = try std.Io.Dir.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "env" });
    defer gpa.free(env_file);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try appendEnv(arena.allocator(), io, env_file, &.{ .{ "RELIC_GIT", "old" }, .{ "SECOND", "2" } });
    const written = try tmp.dir.readFileAlloc(io, "env", gpa, .limited(4096));
    defer gpa.free(written);
    try std.testing.expectEqualStrings("RELIC_GIT=master\nRELIC_GIT=old\nSECOND=2\n", written);
}

test "an unpacked tree is built on only when it is the release's, whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try std.Io.Dir.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    // cut short before its last member
    try std.testing.expect(!wholeRelease(a, io, source, "2.39.5"));
    // git's own version file is no mark
    try tmp.dir.writeFile(io, .{ .sub_path = "version", .data = "2.39.5\n" });
    try std.testing.expect(!wholeRelease(a, io, source, "2.39.5"));
    try tmp.dir.writeFile(io, .{ .sub_path = unpacked_marker, .data = "2.39.5\n" });
    try std.testing.expect(wholeRelease(a, io, source, "2.39.5"));
    try std.testing.expect(!wholeRelease(a, io, source, "2.39.4"));
    try std.testing.expect(!wholeRelease(a, io, source, "2.39"));
    try tmp.dir.writeFile(io, .{ .sub_path = unpacked_marker, .data = "2.39.4\n" });
    try std.testing.expect(!wholeRelease(a, io, source, "2.39.5"));
}

test "Git fixtures require 2.47 including Windows version suffixes" {
    try std.testing.expect(!recent("git version 2.46.3"));
    try std.testing.expect(recent("git version 2.47.0.windows.1"));
    try std.testing.expect(recent("git version 3.0.0"));
    try std.testing.expect(!recent("unexpected version"));
}

test "a runner's git is the held release, Windows' suffix and all, and no other" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(held(try std.mem.print(&buf, "git version {f}.windows.1\n", .{git_release.held})));
    try std.testing.expect(held(try std.mem.print(&buf, "git version {f}\n", .{git_release.held})));
    try std.testing.expect(!held("git version 2.39.5\n"));
    try std.testing.expect(!held("unexpected version"));
}
