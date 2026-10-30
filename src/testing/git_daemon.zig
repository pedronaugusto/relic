//! `git://` against git 2.56's own daemon (designs/relic.md §12): each
//! connection the test accepts on 127.0.0.1 is served by
//! `git daemon --inetd`, so the client's side is a real TCP connection.
//! Each case runs git and relic against the same daemon and compares what
//! each made, or what the daemon logged of what each asked.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const object = @import("../object/object.zig");
const clone_mod = @import("../transport/clone.zig");
const transport = @import("../transport/transport.zig");
const fetch_mod = @import("../transport/fetch.zig");
const push_mod = @import("../transport/push.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");

const who: object.Signature = .{ .name = "T", .email = "t@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// A daemon serving the repositories under a root, an output directory
/// both clients write in, and git's environment.
const Served = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    root: testing.TmpDir,
    root_path: []const u8,
    out: testing.TmpDir,
    out_path: []const u8,
    env: Environ.Map,
    server: *testremote.DaemonServer,

    fn init(gpa: Allocator, io: Io, options: testremote.DaemonServer.DaemonOptions) !*Served {
        try testgit.requireGitVersion(gpa, io, 2, 56);
        const s = try gpa.create(Served);
        errdefer gpa.destroy(s);
        s.gpa = gpa;
        s.arena_state = .init(gpa);
        errdefer s.arena_state.deinit();
        const a = s.arena_state.allocator();
        s.root = testing.tmpDir(.{ .iterate = true });
        errdefer s.root.cleanup();
        s.root_path = try testremote.absolutePath(a, io, s.root.dir);
        s.out = testing.tmpDir(.{ .iterate = true });
        errdefer s.out.cleanup();
        s.out_path = try testremote.absolutePath(a, io, s.out.dir);
        s.env = try testremote.environ(gpa);
        errdefer s.env.deinit();
        s.server = try testremote.DaemonServer.start(gpa, io, s.root.dir, options);
        return s;
    }

    fn deinit(s: *Served) void {
        const gpa = s.gpa;
        s.server.stop();
        s.env.deinit();
        s.out.cleanup();
        s.root.cleanup();
        s.arena_state.deinit();
        gpa.destroy(s);
    }

    fn arena(s: *Served) Allocator {
        return s.arena_state.allocator();
    }

    /// git, in the output directory.
    fn git(s: *Served, io: Io, args: []const []const u8) ![]u8 {
        return testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, args, "", true);
    }

    /// The same, `""` when git fails.
    fn gitOrEmpty(s: *Served, io: Io, args: []const []const u8) ![]u8 {
        return testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, args, "", false) catch |err| switch (err) {
            error.GitFailed => "",
            else => |e| return e,
        };
    }

    /// `<root>/<name>`, a bare copy of `source`.
    fn publish(s: *Served, io: Io, source: *testgit.Repo, name: []const u8) ![]const u8 {
        const path = try std.Io.Dir.path.join(s.arena(), &.{ s.root_path, name });
        try source.exec(io, &.{ "clone", "-q", "--bare", ".", path });
        return path;
    }

    fn url(s: *Served, name: []const u8) ![]const u8 {
        return s.server.url(s.arena(), name);
    }

    /// The daemon's log lines that say what a client asked for, from
    /// `from` on, each without the daemon's process id.
    fn asked(s: *Served, from: usize) ![]const u8 {
        const log = try s.server.logged(s.arena());
        var kept: std.ArrayList(u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, log[from..], '\n');
        while (lines.next()) |line| {
            const text = if (std.mem.find(u8, line, "] ")) |at| line[at + 2 ..] else line;
            if (std.mem.startsWith(u8, text, "Extended attribute") or std.mem.startsWith(u8, text, "Request ") or std.mem.endsWith(u8, text, "not allowed")) {
                try kept.print(s.arena(), "{s}\n", .{text});
            }
        }
        return kept.items;
    }

    fn logLength(s: *Served) !usize {
        return (try s.server.logged(s.arena())).len;
    }
};

/// What git and relic made are the same clone: refs, `HEAD`, remote and
/// branch configuration, the index and the work tree; and relic's is
/// whole.
fn expectSameClone(s: *Served, io: Io, theirs: []const u8, ours: []const u8) !void {
    const queries = [_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname) %(*objectname) %(symref)" },
        &.{ "symbolic-ref", "-q", "HEAD" },
        &.{ "rev-parse", "HEAD" },
        &.{ "config", "--local", "--get-regexp", "^(remote|branch)\\." },
        &.{ "ls-files", "-s" },
        &.{ "status", "--porcelain" },
    };
    for (queries) |q| {
        const a = try s.gitOrEmpty(io, try std.mem.concat(s.arena(), []const u8, &.{ &.{ "-C", theirs }, q }));
        const b = try s.gitOrEmpty(io, try std.mem.concat(s.arena(), []const u8, &.{ &.{ "-C", ours }, q }));
        try testing.expectEqualStrings(a, b);
    }
    _ = try s.git(io, &.{ "-C", ours, "fsck", "--strict", "--no-dangling", "--no-progress" });
}

/// relic's listing of `remote`, as git's ls-remote prints one.
fn lsRemote(s: *Served, io: Io, remote: []const u8, options: transport.Options) ![]const u8 {
    var opts = options;
    opts.who = who;
    if (opts.programs == null) opts.programs = .{ .environ = &s.env };
    var session = try transport.Session.open(s.gpa, io, remote, .{ .service = .upload_pack }, opts);
    defer session.deinit(io);
    var refs = try session.listRefs(s.gpa, io, &.{});
    defer refs.deinit();
    var out: std.ArrayList(u8) = .empty;
    for (refs.refs) |ref| {
        var hex: [64]u8 = undefined;
        try out.print(s.arena(), "{s}\t{s}\n", .{ ref.oid.hex(&hex), ref.name });
    }
    return out.items;
}

test "git://: a clone, a fetch and ls-remote under protocol v0 and v2 are what git makes over the same daemon, and the daemon is asked as git asks it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    try source.exec(io, &.{ "tag", "-a", "v1", "-m", "one" });
    const served = try s.publish(io, &source, "repo.git");

    for ([_][]const u8{ "0", "2" }) |version| {
        var config = try config_mod.Config.parseText(gpa, try std.mem.concat(s.arena(), u8, &.{ "[protocol]\n\tversion = ", version, "\n" }), .local);
        defer config.deinit();
        const setting = try std.mem.concat(s.arena(), u8, &.{ "protocol.version=", version });
        const remote = try s.url("repo.git");

        // What each asked the daemon: the same request, the same host, and
        // the same protocol.
        const before_git = try s.logLength();
        const theirs_listed = try s.git(io, &.{ "-c", setting, "ls-remote", remote });
        const git_asked = try s.asked(before_git);
        const before_ours = try s.logLength();
        const ours_listed = try lsRemote(s, io, remote, .{ .config = &config });
        try testing.expectEqualStrings(git_asked, try s.asked(before_ours));
        try testing.expectEqualStrings(theirs_listed, ours_listed);
        try testing.expectEqual(std.mem.eql(u8, version, "2"), std.mem.find(u8, git_asked, "\"protocol\": version=2") != null);

        const theirs = try std.Io.Dir.path.join(s.arena(), &.{ s.out_path, try std.mem.concat(s.arena(), u8, &.{ "git-v", version }) });
        _ = try s.git(io, &.{ "-c", setting, "clone", "-q", remote, theirs });
        const ours_name = try std.mem.concat(s.arena(), u8, &.{ "relic-v", version });
        try s.out.dir.createDirPath(io, ours_name);
        const ours = try std.Io.Dir.path.join(s.arena(), &.{ s.out_path, ours_name });
        {
            var dir = try s.out.dir.openDir(io, ours_name, .{ .iterate = true });
            defer dir.close(io);
            var repo = try clone_mod.clone(gpa, io, remote, dir, .{ .who = who, .config = &config, .programs = .{ .environ = &s.env } });
            repo.deinit(io);
        }
        try expectSameClone(s, io, theirs, ours);

        // Two commits more on the server, fetched by each under the
        // version its repository names.
        try testremote.addCommits(gpa, io, &source, 10 * @as(usize, version[0] - '0' + 1), 2);
        try source.exec(io, &.{ "push", "-q", served, "HEAD:main" });
        for ([_][]const u8{ theirs, ours }) |clone| _ = try s.git(io, &.{ "-C", clone, "config", "protocol.version", version });
        _ = try s.git(io, &.{ "-C", theirs, "fetch", "-q", "origin" });
        {
            var dir = try s.out.dir.openDir(io, ours_name, .{});
            defer dir.close(io);
            var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
            defer repo.deinit(io);
            var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = who, .programs = .{ .environ = &s.env } });
            fetched.deinit();
        }
        try expectSameClone(s, io, theirs, ours);
    }
}

test "git://: a push goes where the daemon takes receive-pack, and where it does not, or the repository is not exported, the daemon's ERR line is the answer" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();

    {
        const s = try Served.init(gpa, io, .{ .receive_pack = true });
        defer s.deinit();
        const served = try s.publish(io, &source, "repo.git");
        const remote = try s.url("repo.git");
        try s.out.dir.createDirPath(io, "ours");
        var dir = try s.out.dir.openDir(io, "ours", .{ .iterate = true });
        defer dir.close(io);
        var repo = try clone_mod.clone(gpa, io, remote, dir, .{ .who = who, .programs = .{ .environ = &s.env } });
        defer repo.deinit(io);
        const ours = try std.Io.Dir.path.join(s.arena(), &.{ s.out_path, "ours" });
        try dir.writeFile(io, .{ .sub_path = "pushed.txt", .data = "pushed\n" });
        _ = try s.git(io, &.{ "-C", ours, "add", "pushed.txt" });
        _ = try s.git(io, &.{ "-C", ours, "commit", "-q", "-m", "pushed" });
        const before = try s.logLength();
        var pushed = try push_mod.push(gpa, io, &repo, "origin", .{ .who = who, .programs = .{ .environ = &s.env }, .refspecs = &.{"main"} });
        pushed.deinit();
        try testing.expectEqualStrings(try s.git(io, &.{ "-C", ours, "rev-parse", "main" }), try s.git(io, &.{ "-C", served, "rev-parse", "main" }));
        // git keeps protocol v0 for a push.
        const asked = try s.asked(before);
        try testing.expect(std.mem.find(u8, asked, "Request receive-pack for '/repo.git'") != null);
        try testing.expect(std.mem.find(u8, asked, "\"protocol\"") == null);
    }
    {
        const s = try Served.init(gpa, io, .{});
        defer s.deinit();
        _ = try s.publish(io, &source, "repo.git");
        const remote = try s.url("repo.git");
        try testing.expectError(error.GitFailed, testremote.gitInputEnv(s.arena(), io, source.dir, &s.env, &.{ "push", remote, "HEAD:refs/heads/other" }, "", false));
        try testing.expectError(error.RemoteError, transport.Session.open(gpa, io, remote, .{ .service = .receive_pack }, .{ .who = who, .programs = .{ .environ = &s.env } }));
    }
    {
        const s = try Served.init(gpa, io, .{ .export_all = false });
        defer s.deinit();
        const served = try s.publish(io, &source, "repo.git");
        const remote = try s.url("repo.git");
        try testing.expectError(error.GitFailed, testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, &.{ "ls-remote", remote }, "", false));
        try testing.expectError(error.RemoteError, lsRemote(s, io, remote, .{}));
        // Exported, it is served.
        var dir = try Io.Dir.cwd().openDir(io, served, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "git-daemon-export-ok", .data = "" });
        try testing.expectEqualStrings(try s.git(io, &.{ "ls-remote", remote }), try lsRemote(s, io, remote, .{}));
    }
}

test "git://: core.gitProxy and GIT_PROXY_COMMAND choose the program git chooses, run with the host and the port" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    _ = try s.publish(io, &source, "repo.git");
    var tools = testing.tmpDir(.{});
    defer tools.cleanup();
    const proxy = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(proxy);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.mem.concat(s.arena(), u8, &.{ proxy, ".fixture" }), .data = try std.mem.concat(s.arena(), u8, &.{ "daemon\n", s.root_path, "\n" }) });
    const stem = if (std.mem.endsWith(u8, proxy, ".exe")) proxy[0 .. proxy.len - 4] else proxy;
    const proxy_log = try std.mem.concat(s.arena(), u8, &.{ stem, ".log" });

    const remote = try s.url("repo.git");
    // git's `hostandport`, which a `for` is matched against.
    const target = try std.fmt.allocPrint(s.arena(), "127.0.0.1:{d}", .{s.server.port});
    const Case = struct { settings: []const []const u8, env: ?[]const u8 = null, proxied: bool };
    const cases = [_]Case{
        .{ .settings = &.{proxy}, .proxied = true },
        .{ .settings = &.{try std.mem.concat(s.arena(), u8, &.{ proxy, " for 0.0.1:", target["127.0.0.1:".len..] })}, .proxied = true },
        .{ .settings = &.{try std.mem.concat(s.arena(), u8, &.{ proxy, " for ", target })}, .proxied = true },
        // The domain ends at a dot, or it is no match.
        .{ .settings = &.{try std.mem.concat(s.arena(), u8, &.{ proxy, " for 7.0.0.1:", target["127.0.0.1:".len..] })}, .proxied = false },
        // The host and the port: a host alone is no match.
        .{ .settings = &.{try std.mem.concat(s.arena(), u8, &.{ proxy, " for 127.0.0.1" })}, .proxied = false },
        // The first that matches is the one: `none` names no proxy.
        .{ .settings = &.{ try std.mem.concat(s.arena(), u8, &.{ "none for ", target }), proxy }, .proxied = false },
        .{ .settings = &.{ try std.mem.concat(s.arena(), u8, &.{ proxy, " for example.com" }), proxy }, .proxied = true },
        // The environment's command is over every setting, and an empty
        // one is none.
        .{ .settings = &.{"none"}, .env = proxy, .proxied = true },
        .{ .settings = &.{proxy}, .env = "", .proxied = false },
    };
    const expected = try s.git(io, &.{ "ls-remote", remote });
    for (cases) |case| {
        var env = try s.env.clone(s.arena());
        if (case.env) |command| try env.put("GIT_PROXY_COMMAND", command);
        var text: std.ArrayList(u8) = .empty;
        var git_args: std.ArrayList([]const u8) = .empty;
        try text.appendSlice(s.arena(), "[core]\n");
        for (case.settings) |value| {
            try text.print(s.arena(), "\tgitProxy = {s}\n", .{value});
            try git_args.appendSlice(s.arena(), &.{ "-c", try std.mem.concat(s.arena(), u8, &.{ "core.gitProxy=", value }) });
        }
        try git_args.appendSlice(s.arena(), &.{ "ls-remote", remote });
        var config = try config_mod.Config.parseText(gpa, text.items, .local);
        defer config.deinit();

        // git, and then relic: each through the proxy, or each not.
        for (0..2) |run| {
            Io.Dir.cwd().deleteFile(io, proxy_log) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            const listed = if (run == 0)
                try testremote.gitInputEnv(s.arena(), io, s.out.dir, &env, git_args.items, "", true)
            else
                try lsRemote(s, io, remote, .{ .config = &config, .programs = .{ .environ = &env } });
            try testing.expectEqualStrings(expected, listed);
            const logged = Io.Dir.cwd().readFileAlloc(io, proxy_log, s.arena(), .limited(4096)) catch |err| switch (err) {
                error.FileNotFound => "",
                else => |e| return e,
            };
            try testing.expectEqualStrings(if (case.proxied) try std.fmt.allocPrint(s.arena(), "[127.0.0.1][{d}]\n", .{s.server.port}) else "", logged);
        }
    }
}

test "git://: GIT_OVERRIDE_VIRTUAL_HOST and a ~user path reach the daemon as git sends them, and a newline in either is refused before anything is sent" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    _ = try s.publish(io, &source, "repo.git");

    var env = try s.env.clone(s.arena());
    try env.put("GIT_OVERRIDE_VIRTUAL_HOST", "virtual.example:1234");
    for ([_]struct { path: []const u8, env: *const Environ.Map }{
        .{ .path = "repo.git", .env = &env },
        .{ .path = "~someone/repo.git", .env = &s.env },
        .{ .path = "%7Esomeone/repo.git", .env = &s.env },
    }) |case| {
        const remote = try s.url(case.path);
        const before_git = try s.logLength();
        _ = testremote.gitInputEnv(s.arena(), io, s.out.dir, case.env, &.{ "ls-remote", remote }, "", false) catch |err| switch (err) {
            error.GitFailed => "",
            else => |e| return e,
        };
        const git_asked = try s.asked(before_git);
        try testing.expect(git_asked.len != 0);
        const before_ours = try s.logLength();
        _ = lsRemote(s, io, remote, .{ .programs = .{ .environ = case.env } }) catch |err| switch (err) {
            error.RemoteError => "",
            else => |e| return e,
        };
        try testing.expectEqualStrings(git_asked, try s.asked(before_ours));
    }

    // git dies on a newline in either, before it connects.
    try env.put("GIT_OVERRIDE_VIRTUAL_HOST", "virtual\nexample");
    const before = try s.logLength();
    try testing.expectError(error.NewlineInRequest, lsRemote(s, io, try s.url("repo.git"), .{ .programs = .{ .environ = &env } }));
    try testing.expectError(error.NewlineInRequest, lsRemote(s, io, try s.url("repo%0A.git"), .{}));
    try testing.expectEqual(before, try s.logLength());
}
