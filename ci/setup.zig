//! Native CI tool setup, cached outside the checkout and retried by preflight.
const std = @import("std");
const builtin = @import("builtin");

/// The Git release the Linux jobs build, its published SHA-256, and the LFS
/// release every job installs.
const git_version = "2.55.0";
const git_sha256 = "457fdb04dc8728e007d4688695e6912e6f680727920f2a40bf11eacc17505357";
const floor_version = "2.39.5";
const floor_sha256 = "c58da92c378df4a986ca33266897a7397e86c22ee266a284d8c2432c39066b59";
const lfs_version = "3.8.0";
const make_flags = [_][]const u8{ "NO_TCLTK=1", "NO_GETTEXT=1", "NO_RUST=1" };

/// The suite's fixtures need Git 2.47 or later.
fn recent(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "git version ")) return false;
    var parts = std.mem.splitScalar(u8, text[12..], '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return major > 2 or (major == 2 and minor >= 47);
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

const Git = enum { release, master, floor };

fn buildGit(c: Context, root: []const u8, kind: Git) !void {
    const master = kind == .master;
    const name = switch (kind) {
        .release => "git",
        .master => "master",
        .floor => "old-git",
    };
    const prefix = try std.Io.Dir.path.join(c.a, &.{ root, name });
    if (!master and c.exists(try std.Io.Dir.path.join(c.a, &.{ prefix, "bin", "git" }))) return;
    try c.command(&.{ "sudo", "apt-get", "update" });
    try c.command(&.{ "sudo", "apt-get", "install", "-y", "--no-install-recommends", "build-essential", "gettext", "libcurl4-openssl-dev", "libexpat1-dev", "libssl-dev", "zlib1g-dev", "gnupg", "openssh-client" });
    const source = try std.Io.Dir.path.join(c.a, &.{ root, try c.a.print("{s}-source", .{name}) });
    if (master) {
        if (c.exists(source)) {
            try c.command(&.{ "git", "-C", source, "fetch", "--depth", "1", "origin", "master" });
            try c.command(&.{ "git", "-C", source, "checkout", "--detach", "FETCH_HEAD" });
        } else try c.command(&.{ "git", "clone", "--depth", "1", "https://github.com/git/git.git", source });
    } else {
        const archive = try std.Io.Dir.path.join(c.a, &.{ root, try c.a.print("{s}.tar.xz", .{name}) });
        const version = if (kind == .floor) floor_version else git_version;
        const digest = if (kind == .floor) floor_sha256 else git_sha256;
        try c.fetch(try c.a.print("https://mirrors.edge.kernel.org/pub/software/scm/git/git-{s}.tar.xz", .{version}), archive, digest);
        try std.Io.Dir.cwd().createDirPath(c.io, source);
        try c.command(&.{ "tar", "-xJf", archive, "-C", source, "--strip-components=1" });
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

fn lfs(c: Context, root: []const u8) !void {
    const bin = try std.Io.Dir.path.join(c.a, &.{ root, "lfs", "bin" });
    const executable = try std.Io.Dir.path.join(c.a, &.{ bin, if (builtin.target.os.tag == .windows) "git-lfs.exe" else "git-lfs" });
    if (c.exists(executable)) return;
    const asset, const digest = switch (builtin.target.os.tag) {
        .linux => .{ "git-lfs-linux-amd64-v3.8.0.tar.gz", "e455e00f15d9b95661b8d53498ffb0c3367962cf1ec73c31ab7369516cd6ab8d" },
        .macos => .{ "git-lfs-darwin-arm64-v3.8.0.zip", "caff76a7d070d8160c89bc39b6e85d98f24135b6fed038a3b4de2590d25102d8" },
        .windows => .{ "git-lfs-windows-amd64-v3.8.0.zip", "b62e7b8ceddee635f691233d77de8eaa4b213e9209e0173811d8cfa77f7882c1" },
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
    // The next hosted step must choose this Git before the runner's own.
    const path_file = c.env.get("GITHUB_PATH") orelse return error.HostedSetupOnly;
    const file = try std.Io.Dir.cwd().openFile(c.io, path_file, .{ .mode = .write_only });
    defer file.close(c.io);
    const at = (try file.stat(c.io)).size;
    const lfs_bin = try std.Io.Dir.path.join(c.a, &.{ root, "lfs", "bin" });
    try file.writePositionalAll(c.io, try c.a.print("{s}\n{s}\n", .{ bin, lfs_bin }), at);
    try report("{s}", c.io, .{version});
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
    if (!std.mem.eql(u8, init.environ_map.get("GITHUB_ACTIONS") orelse "", "true")) return error.HostedSetupOnly;
    const c: Context = .{ .a = a, .io = init.io, .env = init.environ_map };
    const args = try init.minimal.args.toSlice(a);
    const root = try std.Io.Dir.path.join(a, &.{ init.environ_map.get("RUNNER_TEMP") orelse return error.HostedSetupOnly, "preflight-tools" });
    try std.Io.Dir.cwd().createDirPath(c.io, root);
    if (args.len > 1 and std.mem.eql(u8, args[1], "old")) return old(c, root);
    const master = args.len > 1 and std.mem.eql(u8, args[1], "master");
    switch (builtin.target.os.tag) {
        .linux => try buildGit(c, root, if (master) .master else .release),
        .macos => {
            if (!recent(try c.capture(&.{ "git", "--version" }))) try c.command(&.{ "brew", "upgrade", "git" });
        },
        .windows => {
            if (!recent(try c.capture(&.{ "git", "--version" }))) try c.command(&.{ "choco", "upgrade", "git", "-y", "--no-progress" });
        },
        else => return error.UnsupportedHost,
    }
    if (!master) try lfs(c, root);
    const git = if (builtin.target.os.tag == .linux) try std.Io.Dir.path.join(a, &.{ root, if (master) "master" else "git", "bin", "git" }) else "git";
    if (!master) try selectLfs(c, root, git);
    const version = try c.capture(&.{ git, "--version" });
    if (!recent(version)) return error.GitTooOld;
    try report("{s}", c.io, .{version});
}

test "Git fixtures require 2.47 including Windows version suffixes" {
    try std.testing.expect(!recent("git version 2.46.3"));
    try std.testing.expect(recent("git version 2.47.0.windows.1"));
    try std.testing.expect(recent("git version 3.0.0"));
    try std.testing.expect(!recent("unexpected version"));
}
