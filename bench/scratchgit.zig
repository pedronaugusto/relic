//! A scratch repository built by the machine's `git`, for the regression
//! measurements: a temporary directory, a scratch home, no system or global
//! configuration, no repository variables from whoever runs it, no prompt,
//! fixed dates and a fixed set of `-c` settings. The same rules as relic's
//! own test harness, which is not part of its public module.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub var environment: Environ = undefined;

const TmpDir = struct {
    dir: Io.Dir,
    parent: Io.Dir,
    path: [24]u8,
    io: Io,

    fn init(io: Io) !TmpDir {
        var bytes: [12]u8 = undefined;
        io.random(&bytes);
        const path = std.fmt.bytesToHex(bytes, .lower);
        var parent = try Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/bench", .{});
        errdefer parent.close(io);
        const dir = try parent.createDirPathOpen(io, &path, .{ .open_options = .{ .iterate = true } });
        return .{ .dir = dir, .parent = parent, .path = path, .io = io };
    }

    fn cleanup(t: *TmpDir) void {
        t.dir.close(t.io);
        t.parent.deleteTree(t.io, &t.path) catch {};
        t.parent.close(t.io);
    }
};

const settings = [_][]const u8{
    "-c", "user.name=Fixture",
    "-c", "user.email=fixture@example.com",
    "-c", "commit.gpgsign=false",
    "-c", "tag.gpgsign=false",
    "-c", "gc.auto=0",
    "-c", "core.autocrlf=false",
    "-c", "core.safecrlf=false",
    "-c", "core.excludesFile=",
    "-c", "core.fsmonitor=",
    "-c", "core.hooksPath=relic-no-hooks",
    "-c", "protocol.file.allow=always",
    "-c", "feature.manyFiles=false",
};

/// What a person's environment may hold that a fixture must not reach.
const personal = [_][]const u8{ "SSH_AUTH_SOCK", "GPG_AGENT_INFO", "GNUPGHOME", "XDG_CONFIG_HOME", "EDITOR", "VISUAL", "PAGER" };

pub const Repo = struct {
    gpa: Allocator,
    tmp: TmpDir,
    home: TmpDir,
    /// The working tree's directory.
    dir: Io.Dir,
    environ: Environ.Map,

    /// A temporary directory with `git init -b main` run in it.
    pub fn init(gpa: Allocator, io: Io) !Repo {
        var tmp = try TmpDir.init(io);
        errdefer tmp.cleanup();
        var home = try TmpDir.init(io);
        errdefer home.cleanup();
        const home_path = try home.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(home_path);
        var map = try environment.createMap(gpa);
        errdefer map.deinit();
        var i = map.count();
        while (i > 0) {
            i -= 1;
            const key = map.keys()[i];
            const drop = std.mem.startsWith(u8, key, "GIT_") or for (personal) |name| {
                if (std.mem.eql(u8, key, name)) break true;
            } else false;
            if (drop) _ = map.swapRemove(key);
        }
        try map.put("HOME", home_path);
        const global = try std.Io.Dir.path.join(gpa, &.{ home_path, ".gitconfig" });
        defer gpa.free(global);
        try map.put("GIT_CONFIG_GLOBAL", global);
        try map.put("GIT_CONFIG_NOSYSTEM", "1");
        try map.put("GIT_TERMINAL_PROMPT", "0");
        try map.put("GIT_AUTHOR_DATE", "1700000000 +0000");
        try map.put("GIT_COMMITTER_DATE", "1700000000 +0000");
        var repo: Repo = .{ .gpa = gpa, .tmp = tmp, .home = home, .dir = tmp.dir, .environ = map };
        try repo.exec(io, &.{ "init", "-q", "-b", "main", "." });
        return repo;
    }

    pub fn deinit(r: *Repo) void {
        r.environ.deinit();
        r.home.cleanup();
        r.tmp.cleanup();
        r.* = undefined;
    }

    /// Runs `git <settings> <args>` in the working tree; a non-zero exit is
    /// `error.GitFailed`.
    pub fn exec(r: *Repo, io: Io, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(r.gpa);
        try argv.append(r.gpa, "git");
        try argv.appendSlice(r.gpa, &settings);
        try argv.appendSlice(r.gpa, args);
        const result = try std.process.run(r.gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = r.dir }, .environ_map = &r.environ });
        defer r.gpa.free(result.stdout);
        defer r.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("git {s} failed:\n{s}\n", .{ args[0], result.stderr });
            return error.GitFailed;
        }
    }

    /// Writes a file in the working tree, making the directories it needs.
    pub fn writeFile(r: *Repo, io: Io, path: []const u8, bytes: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try r.dir.createDirPath(io, parent);
        try r.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    /// The `.git` directory, opened. The caller closes it.
    pub fn gitDir(r: *Repo, io: Io) !Io.Dir {
        return r.dir.openDir(io, ".git", .{ .iterate = true });
    }
};
