//! Native CI tool setup, cached outside the checkout and retried by preflight.
const std = @import("std");
const builtin = @import("builtin");
const pins = @import("git_checks.zig");
const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    fn command(c: Context, argv: []const []const u8) !void {
        for (0..3) |attempt| {
            c.execute(argv) catch |err| {
                if (attempt == 2) return err;
                std.debug.print("CI tool command {s} failed; retry {d}/3\n", .{ argv[0], attempt + 2 });
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

fn buildGit(c: Context, root: []const u8, master: bool) !void {
    const prefix = try std.fs.path.join(c.a, &.{ root, if (master) "master" else "git" });
    if (!master and c.exists(try std.fs.path.join(c.a, &.{ prefix, "bin", "git" }))) return;
    try c.command(&.{ "sudo", "apt-get", "update" });
    try c.command(&.{ "sudo", "apt-get", "install", "-y", "--no-install-recommends", "build-essential", "gettext", "libcurl4-openssl-dev", "libexpat1-dev", "libssl-dev", "zlib1g-dev", "gnupg", "openssh-client" });
    const source = try std.fs.path.join(c.a, &.{ root, if (master) "master-source" else "git-source" });
    if (master) {
        if (c.exists(source)) {
            try c.command(&.{ "git", "-C", source, "fetch", "--depth", "1", "origin", "master" });
            try c.command(&.{ "git", "-C", source, "checkout", "--detach", "FETCH_HEAD" });
        } else try c.command(&.{ "git", "clone", "--depth", "1", "https://github.com/git/git.git", source });
    } else {
        const archive = try std.fs.path.join(c.a, &.{ root, "git.tar.xz" });
        try c.fetch(try std.fmt.allocPrint(c.a, "https://mirrors.edge.kernel.org/pub/software/scm/git/git-{s}.tar.xz", .{pins.git_version}), archive, pins.git_sha256);
        try std.Io.Dir.cwd().createDirPath(c.io, source);
        try c.command(&.{ "tar", "-xJf", archive, "-C", source, "--strip-components=1" });
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "make", "-C", source, try std.fmt.allocPrint(c.a, "-j{d}", .{try std.Thread.getCpuCount()}) });
    try args.appendSlice(c.a, if (master) &.{ "NO_TCLTK=1", "NO_GETTEXT=1" } else &pins.make_flags);
    try args.append(c.a, try std.fmt.allocPrint(c.a, "prefix={s}", .{prefix}));
    try args.append(c.a, "all");
    try c.command(args.items);
    args.items[args.items.len - 1] = "install";
    try c.command(args.items);
}

fn lfs(c: Context, root: []const u8) !void {
    const bin = try std.fs.path.join(c.a, &.{ root, "lfs", "bin" });
    const executable = try std.fs.path.join(c.a, &.{ bin, if (builtin.os.tag == .windows) "git-lfs.exe" else "git-lfs" });
    if (c.exists(executable)) return;
    const asset, const digest = switch (builtin.os.tag) {
        .linux => .{ "git-lfs-linux-amd64-v3.8.0.tar.gz", "e455e00f15d9b95661b8d53498ffb0c3367962cf1ec73c31ab7369516cd6ab8d" },
        .macos => .{ "git-lfs-darwin-arm64-v3.8.0.zip", "caff76a7d070d8160c89bc39b6e85d98f24135b6fed038a3b4de2590d25102d8" },
        .windows => .{ "git-lfs-windows-amd64-v3.8.0.zip", "b62e7b8ceddee635f691233d77de8eaa4b213e9209e0173811d8cfa77f7882c1" },
        else => return error.UnsupportedHost,
    };
    const archive = try std.fs.path.join(c.a, &.{ root, asset });
    try c.fetch(try std.fmt.allocPrint(c.a, "https://github.com/git-lfs/git-lfs/releases/download/v{s}/{s}", .{ pins.lfs_version, asset }), archive, digest);
    const unpacked = try std.fs.path.join(c.a, &.{ root, "lfs-unpacked" });
    try std.Io.Dir.cwd().createDirPath(c.io, unpacked);
    if (builtin.os.tag == .linux) try c.command(&.{ "tar", "-xzf", archive, "-C", unpacked }) else try c.command(&.{ "tar", "-xf", archive, "-C", unpacked });
    var directory = try std.Io.Dir.cwd().openDir(c.io, unpacked, .{ .iterate = true });
    defer directory.close(c.io);
    var walker = try directory.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (!std.mem.eql(u8, entry.basename, if (builtin.os.tag == .windows) "git-lfs.exe" else "git-lfs")) continue;
        try std.Io.Dir.cwd().createDirPath(c.io, bin);
        try directory.copyFile(entry.path, std.Io.Dir.cwd(), executable, c.io, .{});
        const file = try std.Io.Dir.cwd().openFile(c.io, executable, .{});
        defer file.close(c.io);
        if (std.Io.File.Permissions.has_executable_bit) try file.setPermissions(c.io, .executable_file);
        return;
    }
    return error.MissingLfsExecutable;
}

fn old(c: Context) !void {
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = "/etc/apt/sources.list", .data = "deb http://archive.debian.org/debian bullseye main\n" });
    try std.Io.Dir.cwd().deleteTree(c.io, "/etc/apt/sources.list.d");
    try std.Io.Dir.cwd().createDirPath(c.io, "/etc/apt/sources.list.d");
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = "/etc/apt/preferences.d/archive", .data = "Package: *\nPin: release n=bullseye\nPin-Priority: 1001\n" });
    try c.command(&.{ "apt-get", "update" });
    try c.command(&.{ "apt-get", "install", "-y", "--no-install-recommends", "--allow-downgrades", "git", "ca-certificates", "gnupg", "openssh-client" });
    const version = try c.capture(&.{ "git", "--version" });
    if (!std.mem.startsWith(u8, version, "git version 2.30.2")) return error.WrongOldestGit;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!std.mem.eql(u8, init.environ_map.get("GITHUB_ACTIONS") orelse "", "true")) return error.HostedSetupOnly;
    const c: Context = .{ .a = a, .io = init.io, .env = init.environ_map };
    const args = try init.minimal.args.toSlice(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "old")) return old(c);
    const root = try std.fs.path.join(a, &.{ init.environ_map.get("RUNNER_TEMP") orelse return error.HostedSetupOnly, "preflight-tools" });
    try std.Io.Dir.cwd().createDirPath(c.io, root);
    const master = args.len > 1 and std.mem.eql(u8, args[1], "master");
    switch (builtin.os.tag) {
        .linux => try buildGit(c, root, master),
        .macos => {
            if (!pins.recent(try c.capture(&.{ "git", "--version" }))) try c.command(&.{ "brew", "upgrade", "git" });
        },
        .windows => {
            if (!pins.recent(try c.capture(&.{ "git", "--version" }))) try c.command(&.{ "choco", "upgrade", "git", "-y", "--no-progress" });
        },
        else => return error.UnsupportedHost,
    }
    if (!master) try lfs(c, root);
    const git = if (builtin.os.tag == .linux) try std.fs.path.join(a, &.{ root, if (master) "master" else "git", "bin", "git" }) else "git";
    const version = try c.capture(&.{ git, "--version" });
    if (!pins.recent(version)) return error.GitTooOld;
    std.debug.print("{s}", .{version});
}
