//! git-lfs's pure-ssh protocol, proven against git-lfs 3.8's own client.
//!
//! git-lfs does not ship a `git-lfs-transfer` server, so the suite brings
//! one (`lfs_transfer_helper.zig`), run through the same stand-in ssh as
//! the rest of the LFS tests. Each test has git-lfs and relic do the same
//! thing against it, and compares what the server was asked, line by line,
//! and what ssh was handed.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const repo_mod = @import("repo.zig");
const lfsapi = @import("lfsapi.zig");
const lfstransfer = @import("lfstransfer.zig");
const lfslocks = @import("lfslocks.zig");
const lfspush = @import("lfspush.zig");
const testlfs = @import("testlfs.zig");
const testremote = @import("testremote.zig");
const t = @import("lfstransfer_test.zig");

const Fixture = t.Fixture;

const ssh_url = "ssh://git@example.invalid:2222/org/repo.git";

/// An ssh remote whose server speaks the pure-ssh protocol: a fixture, the
/// stand-in ssh, and the stand-in `git-lfs-transfer` over a store of its
/// own.
const Ssh = struct {
    fx: *Fixture,
    fake_ssh: []u8,
    nobody: []u8,
    root: []u8,
    logs: Io.Dir,
    logs_path: []u8,

    fn init(extra: ?[]const u8) !Ssh {
        const gpa = testing.allocator;
        const io = testing.io;
        const fx = try Fixture.init(gpa, io, .{ .tokens = &.{.{ .token = "t0k3n", .user = "ada" }} });
        errdefer fx.deinit();
        const fake_ssh = try testremote.fakeSsh(gpa, io, fx.tools);
        const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
        const root = try fx.path("ssh-root");
        var logs = try fx.dir("transfer-logs");
        errdefer logs.close(io);
        const logs_path = try fx.path("transfer-logs");
        // With no `extra`, the server has no git-lfs-transfer at all.
        if (extra) |e| {
            const script = try testlfs.transferScript(gpa, io, fx.tools, root, logs_path, e);
            gpa.free(script);
        }
        return .{ .fx = fx, .fake_ssh = fake_ssh, .nobody = nobody, .root = root, .logs = logs, .logs_path = logs_path };
    }

    fn deinit(s: *Ssh) void {
        const gpa = testing.allocator;
        s.logs.close(testing.io);
        gpa.free(s.fake_ssh);
        gpa.free(s.nobody);
        gpa.free(s.root);
        gpa.free(s.logs_path);
        s.fx.deinit();
    }

    /// A working repository whose `origin` is the ssh remote.
    fn repo(s: *Ssh, name: []const u8, files: []const [2][]const u8) !Io.Dir {
        const d = try t.committed(s.fx, name, s.nobody, files);
        try s.point(d);
        return d;
    }

    fn point(s: *Ssh, d: Io.Dir) !void {
        try s.fx.gitIn(d, &.{ "remote", "set-url", "origin", ssh_url });
        try s.fx.gitIn(d, &.{ "config", "core.sshCommand", s.fake_ssh });
        try s.fx.gitIn(d, &.{ "config", "lfs.concurrenttransfers", "1" });
    }

    /// What the server was asked and what ssh was handed since the last
    /// call, the ssh socket's directory named the same whatever it was.
    fn take(s: *Ssh) ![2][]u8 {
        const gpa = testing.allocator;
        const io = testing.io;
        const asked = try testlfs.transferLog(gpa, io, s.logs);
        errdefer gpa.free(asked);
        var it = s.logs.iterate();
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        while (try it.next(io)) |e| try names.append(gpa, try gpa.dupe(u8, e.name));
        for (names.items) |n| try s.logs.deleteFile(io, n);
        const raw = s.fx.tools.readFileAlloc(io, "fake-ssh.log", gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, ""),
            else => |e| return e,
        };
        defer gpa.free(raw);
        s.fx.tools.deleteFile(io, "fake-ssh.log") catch {};
        // Only git-lfs's own conversations: `git lfs push` also asks git
        // for the remote's refs, which relic's push already knows.
        var lfs_only: std.ArrayList(u8) = .empty;
        defer lfs_only.deinit(gpa);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "[git-lfs-") == null) continue;
            try lfs_only.appendSlice(gpa, line);
            try lfs_only.append(gpa, '\n');
        }
        return .{ asked, try sockNamed(gpa, lfs_only.items) };
    }
};

/// `text` with every `sock-<anything>/` directory named `sock-X/`.
fn sockNamed(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "sock-")) |i| {
        try out.appendSlice(gpa, text[at..i]);
        try out.appendSlice(gpa, "sock-X");
        at = std.mem.indexOfScalarPos(u8, text, i, '/') orelse text.len;
    }
    try out.appendSlice(gpa, text[at..]);
    return out.toOwnedSlice(gpa);
}

fn expectSame(a: [2][]u8, b: [2][]u8) !void {
    try testing.expectEqualStrings(a[0], b[0]);
    try testing.expectEqualStrings(a[1], b[1]);
}

fn free(pair: [2][]u8) void {
    testing.allocator.free(pair[0]);
    testing.allocator.free(pair[1]);
}

/// What relic's push does before it sends a ref, as git-lfs's pre-push
/// hook and `git lfs push` do: the locks checked, then the objects sent.
fn relicPrePush(fx: *Fixture, d: Io.Dir) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try repo_mod.Repository.open(gpa, io, d, .{});
    defer repo.deinit(io);
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    var collected = try @import("objectwalk.zig").missing(gpa, io, &repo.odb, &.{head.oid}, &.{});
    defer collected.deinit();
    var report: lfspush.Report = .init(gpa);
    defer report.deinit();
    try lfspush.beforePush(gpa, io, &repo, "origin", &.{"refs/heads/main"}, collected.entries, .{ .programs = fx.programs() }, .{ .report = &report });
    for (report.uploads) |r| try testing.expect(!r.isFailure());
}

test "objects go up and come down over git-lfs-transfer, asked for as git-lfs asks for them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var s = try Ssh.init("");
    defer s.deinit();
    const big = try t.noise(gpa, 200 * 1024, 41);
    defer gpa.free(big);
    const files = [_][2][]const u8{ .{ "a.bin", "small over ssh\n" }, .{ "b.bin", big } };

    // Up: git-lfs pushes into one store, relic into another, the same
    // objects.
    var up: [2][2][]u8 = undefined;
    for ([_][]const u8{ "up-git", "up-relic" }, 0..) |name, i| {
        var d = try s.repo(name, &files);
        defer d.close(io);
        if (i == 0) {
            try s.fx.gitIn(d, &.{ "lfs", "push", "origin", "main" });
        } else try relicPrePush(s.fx, d);
        up[i] = try s.take();
        // Each starts from an empty store.
        if (i == 0) try Io.Dir.cwd().deleteTree(io, s.root);
    }
    defer for (up) |p| free(p);
    try expectSame(up[0], up[1]);
    try testing.expect(std.mem.indexOf(u8, up[1][0], "> put-object ") != null);
    try testing.expect(std.mem.indexOf(u8, up[1][0], "> verify-object ") != null);
    try testing.expect(std.mem.indexOf(u8, up[1][1], "[-oControlMaster=yes][-oControlPath=") != null);
    try testing.expect(std.mem.indexOf(u8, up[1][1], "/home/sock-X/lfs.sock]") != null);

    // Down: each fetches what relic put there.
    var down: [2][2][]u8 = undefined;
    for ([_][]const u8{ "down-git", "down-relic" }, 0..) |name, i| {
        var d = try s.repo(name, &files);
        defer d.close(io);
        try t.emptyStore(s.fx, d);
        if (i == 0) {
            try s.fx.gitIn(d, &.{ "lfs", "fetch" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try t.openServer(s.fx, &repo);
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try t.expectNoFailures(&fetched);
        }
        const listing = try t.storeListing(s.fx, d);
        defer gpa.free(listing);
        try testing.expect(std.mem.indexOf(u8, listing, &testlfs.sha256Hex(big)) != null);
        down[i] = try s.take();
    }
    defer for (down) |p| free(p);
    try expectSame(down[0], down[1]);
    try testing.expect(std.mem.indexOf(u8, down[1][0], "> get-object ") != null);
    try testing.expect(std.mem.indexOf(u8, down[1][0], "refname=refs/heads/main") != null);
}

test "without git-lfs-transfer, or with one that will not speak version 1, git-lfs-authenticate and HTTP are used, as git-lfs falls back" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]?[]const u8{ null, "--no-version" }) |extra| {
        var s = try Ssh.init(extra);
        defer s.deinit();
        const href = try s.fx.server.url(gpa, "repo.git/info/lfs");
        defer gpa.free(href);
        const auth = try testlfs.authenticateScript(gpa, io, s.fx.tools, href, "t0k3n");
        gpa.free(auth);
        const content = "reached over HTTP after all\n";
        try s.fx.server.putObject(&testlfs.sha256Hex(content), content);
        var logs: [2][2][]u8 = undefined;
        for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
            var d = try s.repo(name, &.{.{ "a.bin", content }});
            defer d.close(io);
            try t.emptyStore(s.fx, d);
            if (i == 0) {
                try s.fx.gitIn(d, &.{ "lfs", "fetch" });
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                var fetched = try lfstransfer.fetch(server, &repo, .{});
                defer fetched.deinit();
                try t.expectNoFailures(&fetched);
            }
            logs[i] = try s.take();
        }
        defer for (logs) |p| free(p);
        try expectSame(logs[0], logs[1]);
        // Tried, then git-lfs-authenticate.
        try testing.expect(std.mem.indexOf(u8, logs[1][1], "[git-lfs-transfer /org/repo.git download]\n") != null);
        try testing.expect(std.mem.indexOf(u8, logs[1][1], "[git-lfs-authenticate /org/repo.git download]\n") != null);
    }
}

test "lfs.sshtransfer=always is the pure-ssh protocol or nothing, and never is git-lfs-authenticate alone, as git-lfs reads them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var s = try Ssh.init(null);
    defer s.deinit();
    const href = try s.fx.server.url(gpa, "repo.git/info/lfs");
    defer gpa.free(href);
    const auth = try testlfs.authenticateScript(gpa, io, s.fx.tools, href, "t0k3n");
    gpa.free(auth);
    const content = "only if asked the right way\n";
    try s.fx.server.putObject(&testlfs.sha256Hex(content), content);
    for ([_][]const u8{ "always", "never" }) |mode| {
        var logs: [2][2][]u8 = undefined;
        for ([_][]const u8{ "by-git", "by-relic" }, 0..) |base, i| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ base, mode });
            var d = try s.repo(name, &.{.{ "a.bin", content }});
            defer d.close(io);
            try t.emptyStore(s.fx, d);
            try s.fx.gitIn(d, &.{ "config", "lfs.sshtransfer", mode });
            const refused = std.mem.eql(u8, mode, "always");
            if (i == 0) {
                const run = testlfs.git(gpa, io, d, &s.fx.env, &.{ "lfs", "fetch" }, false);
                if (refused) try testing.expectError(error.GitFailed, run) else gpa.free(try run);
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                if (refused) {
                    try testing.expectError(error.LfsAuthenticateDisabled, lfstransfer.fetch(server, &repo, .{}));
                    try testing.expect(std.mem.startsWith(u8, server.client.message(), "git-lfs-authenticate has been disabled by request (lfs.sshtransfer=always)"));
                } else {
                    var fetched = try lfstransfer.fetch(server, &repo, .{});
                    defer fetched.deinit();
                    try t.expectNoFailures(&fetched);
                }
            }
            logs[i] = try s.take();
        }
        defer for (logs) |p| free(p);
        try expectSame(logs[0], logs[1]);
    }
}

test "locks are taken, listed, verified and given back over git-lfs-transfer, as git-lfs asks for them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var s = try Ssh.init("");
    defer s.deinit();
    var logs: [2][2][]u8 = undefined;
    for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
        var d = try s.repo(name, &.{ .{ "a.bin", "lock me\n" }, .{ "b.bin", "and me\n" } });
        defer d.close(io);
        // Someone else holds b.bin already.
        try Io.Dir.cwd().createDirPath(io, s.root);
        var root = try Io.Dir.cwd().openDir(io, s.root, .{});
        defer root.close(io);
        try root.createDirPath(io, "org/repo.git");
        try root.writeFile(io, .{ .sub_path = "org/repo.git/transfer-locks", .data = "7\tb.bin\tbob\n" });
        if (i == 0) {
            try s.fx.gitIn(d, &.{ "lfs", "lock", "a.bin" });
            try s.fx.gitIn(d, &.{ "lfs", "locks" });
            try s.fx.gitIn(d, &.{ "lfs", "locks", "--verify" });
            try testing.expectError(error.GitFailed, testlfs.git(gpa, io, d, &s.fx.env, &.{ "lfs", "lock", "b.bin" }, false));
            try s.fx.gitIn(d, &.{ "lfs", "unlock", "a.bin" });
        } else {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            {
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                const got = try lfslocks.lock(server, &repo, "a.bin", arena, .{});
                try testing.expectEqualStrings("ada", got.locked.owner.?);
            }
            {
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                var listed = try lfslocks.list(server, &repo, .{}, .{});
                defer listed.deinit();
                try testing.expectEqual(@as(usize, 2), listed.locks.len);
            }
            {
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                var verified = try lfslocks.verify(server, &repo, .{});
                defer verified.deinit();
                try testing.expectEqual(@as(usize, 1), verified.ours.len);
                try testing.expectEqualStrings("b.bin", verified.theirs[0].path);
            }
            {
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                const held = try lfslocks.lock(server, &repo, "b.bin", arena, .{});
                try testing.expectEqualStrings("bob", held.held.owner.?);
            }
            {
                const server = try t.openServer(s.fx, &repo);
                defer server.close();
                const released = try lfslocks.unlockPath(server, &repo, "a.bin", false, arena, .{});
                try testing.expectEqualStrings("a.bin", released.path);
            }
        }
        logs[i] = try s.take();
        try Io.Dir.cwd().deleteTree(io, s.root);
    }
    defer for (logs) |p| free(p);
    try expectSame(logs[0], logs[1]);
    try testing.expect(std.mem.indexOf(u8, logs[1][0], "> lock\n") != null);
    try testing.expect(std.mem.indexOf(u8, logs[1][0], "> unlock 8\n") != null);
}

test "each transfer worker has its own git-lfs-transfer, sharing the first's ssh session, as git-lfs's do" {
    const gpa = testing.allocator;
    const io = testing.io;
    var s = try Ssh.init("");
    defer s.deinit();
    var files: [6][2][]const u8 = undefined;
    var names: [6][8]u8 = undefined;
    var contents: [6][32]u8 = undefined;
    for (&files, 0..) |*f, i| {
        f[0] = try std.fmt.bufPrint(&names[i], "f{d}.bin", .{i});
        f[1] = try std.fmt.bufPrint(&contents[i], "worker object {d}\n", .{i});
    }
    {
        var d = try s.repo("seed", &files);
        defer d.close(io);
        try s.fx.gitIn(d, &.{ "lfs", "push", "origin", "main" });
        free(try s.take());
    }
    var listings: [2][]u8 = .{ &.{}, &.{} };
    defer for (listings) |l| gpa.free(l);
    var ssh_log: []u8 = &.{};
    defer gpa.free(ssh_log);
    for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
        var d = try s.repo(name, &files);
        defer d.close(io);
        try t.emptyStore(s.fx, d);
        try s.fx.gitIn(d, &.{ "config", "lfs.concurrenttransfers", "3" });
        if (i == 0) {
            try s.fx.gitIn(d, &.{ "lfs", "fetch" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try t.openServer(s.fx, &repo);
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try t.expectNoFailures(&fetched);
            try testing.expectEqual(@as(usize, 6), fetched.results.len);
        }
        listings[i] = try t.storeListing(s.fx, d);
        const taken = try s.take();
        gpa.free(taken[0]);
        if (i == 1) ssh_log = taken[1] else gpa.free(taken[1]);
    }
    try testing.expectEqualStrings(listings[0], listings[1]);
    // The first connection is the master; any other shares its socket.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, ssh_log, "[-oControlMaster=yes]"));
    const lines = std.mem.count(u8, ssh_log, "\n");
    try testing.expectEqual(lines - 1, std.mem.count(u8, ssh_log, "[-oControlMaster=no]"));
}

test "against a real git-lfs-transfer server, what git-lfs puts there relic gets, what relic puts there git-lfs gets, and the locks are shared" {
    const server_program = @import("build_options").lfs_transfer_server;
    if (server_program.len == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const fake_ssh = try testremote.fakeSsh(gpa, io, fx.tools);
    defer gpa.free(fake_ssh);
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    {
        const text = try std.fmt.allocPrint(gpa, "#!/bin/sh\nexec '{s}' \"$@\"\n", .{server_program});
        defer gpa.free(text);
        gpa.free(try testlfs.script(gpa, io, fx.tools, "git-lfs-transfer", text));
    }
    const remote_path = try fx.path("served/repo.git");
    defer gpa.free(remote_path);
    const url = try std.fmt.allocPrint(gpa, "ssh://git@example.invalid:2222{s}", .{remote_path});
    defer gpa.free(url);
    const Point = struct {
        fn at(f: *Fixture, d: Io.Dir, u: []const u8, ssh: []const u8) !void {
            try f.gitIn(d, &.{ "remote", "set-url", "origin", u });
            try f.gitIn(d, &.{ "config", "core.sshCommand", ssh });
        }
    };

    // git-lfs puts two objects there; relic fetches them.
    const first = "put there by git-lfs\n";
    const second = try t.noise(gpa, 150 * 1024, 51);
    defer gpa.free(second);
    {
        var d = try t.committed(fx, "by-git", nobody, &.{ .{ "a.bin", first }, .{ "b.bin", second } });
        defer d.close(io);
        try Point.at(fx, d, url, fake_ssh);
        try fx.gitIn(d, &.{ "lfs", "push", "origin", "main" });
    }
    {
        var d = try t.committed(fx, "relic-fetches", nobody, &.{ .{ "a.bin", first }, .{ "b.bin", second } });
        defer d.close(io);
        try Point.at(fx, d, url, fake_ssh);
        try t.emptyStore(fx, d);
        var repo = try repo_mod.Repository.open(gpa, io, d, .{});
        defer repo.deinit(io);
        const server = try t.openServer(fx, &repo);
        defer server.close();
        var fetched = try lfstransfer.fetch(server, &repo, .{});
        defer fetched.deinit();
        try t.expectNoFailures(&fetched);
        // Over the pure-ssh protocol, not a fallback.
        try testing.expect(try server.client.sshTransfer(.download) != null);
        for ([_][]const u8{ first, second }) |c| try testing.expect((try server.store().contains(io, &.{ .oid = testlfs.sha256Hex(c), .size = c.len })));
    }

    // relic puts a third; git-lfs fetches it.
    const third = "put there by relic\n";
    {
        var d = try t.committed(fx, "by-relic", nobody, &.{.{ "c.bin", third }});
        defer d.close(io);
        try Point.at(fx, d, url, fake_ssh);
        try relicPrePush(fx, d);
    }
    {
        var d = try t.committed(fx, "git-fetches", nobody, &.{.{ "c.bin", third }});
        defer d.close(io);
        try Point.at(fx, d, url, fake_ssh);
        try t.emptyStore(fx, d);
        try fx.gitIn(d, &.{ "lfs", "fetch" });
        const oid = testlfs.sha256Hex(third);
        var path_buf: [128]u8 = undefined;
        try t.expectFile(fx, d, try std.fmt.bufPrint(&path_buf, ".git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid }), third);
    }

    // A lock relic takes git-lfs lists, and one git-lfs takes relic
    // verifies as the person's own.
    var d = try t.committed(fx, "locks", nobody, &.{ .{ "a.bin", first }, .{ "b.bin", "b\n" } });
    defer d.close(io);
    try Point.at(fx, d, url, fake_ssh);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var repo = try repo_mod.Repository.open(gpa, io, d, .{});
    defer repo.deinit(io);
    {
        const server = try t.openServer(fx, &repo);
        defer server.close();
        _ = (try lfslocks.lock(server, &repo, "a.bin", arena, .{})).locked;
    }
    const listed = try fx.gitOut(d, &.{ "lfs", "locks" });
    defer gpa.free(listed);
    try testing.expect(std.mem.indexOf(u8, listed, "a.bin") != null);
    try fx.gitIn(d, &.{ "lfs", "lock", "b.bin" });
    {
        const server = try t.openServer(fx, &repo);
        defer server.close();
        var verified = try lfslocks.verify(server, &repo, .{});
        defer verified.deinit();
        try testing.expectEqual(@as(usize, 2), verified.ours.len);
    }
    {
        const server = try t.openServer(fx, &repo);
        defer server.close();
        _ = try lfslocks.unlockPath(server, &repo, "b.bin", false, arena, .{});
    }
    try fx.gitIn(d, &.{ "lfs", "unlock", "a.bin" });
    {
        const server = try t.openServer(fx, &repo);
        defer server.close();
        var none = try lfslocks.list(server, &repo, .{}, .{});
        defer none.deinit();
        try testing.expectEqual(@as(usize, 0), none.locks.len);
    }
}
