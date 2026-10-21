//! relic's LFS server held to the real git-lfs: pushes, clones and pulls of
//! LFS files, and locks taken, listed, refused, broken and checked at a
//! push, by git and git-lfs against one uplink server that is relic's
//! smart HTTP and its LFS API together.
//!
//! Two people share it: ada and bob, each with a stand-in credential helper
//! of their own. Reading is open to anyone, writing and locks want a
//! person. Everything runs from the fixture's environment (a home of its
//! own, no system configuration), so nothing of the person running the
//! suite is reached.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const uplink = @import("uplink");
const testgit = @import("../testing/git.zig");
const testlfs = @import("../testing/lfs.zig");
const testremote = @import("../testing/remote.zig");
const program = @import("../process.zig").program;
const http_backend = @import("../transport/http_backend.zig");
const server = @import("server.zig");
const lt = @import("transfer_test.zig");

const users = [_][2][]const u8{ .{ "ada", "secret" }, .{ "bob", "hunter2" } };

/// Who a request's basic credentials name, when they are a user's.
fn userOf(request: *uplink.server.Request) ?[]const u8 {
    const header = request.headers.get("authorization") orelse return null;
    if (!std.mem.startsWith(u8, header, "Basic ")) return null;
    var buf: [128]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(header["Basic ".len..]) catch return null;
    if (len > buf.len) return null;
    decoder.decode(buf[0..len], header["Basic ".len..]) catch return null;
    for (users) |u| {
        const colon = u[0].len;
        if (len == colon + 1 + u[1].len and std.mem.eql(u8, buf[0..colon], u[0]) and buf[colon] == ':' and
            std.mem.eql(u8, buf[colon + 1 .. len], u[1])) return u[0];
    }
    return null;
}

const Policy = struct {
    asked: std.atomic.Value(u32) = .init(0),

    fn authorize(context: ?*anyopaque, request: *uplink.server.Request, repository: []const u8, access: server.Access) server.Verdict {
        const p: *Policy = @ptrCast(@alignCast(context.?));
        _ = p.asked.fetchAdd(1, .monotonic);
        std.debug.assert(std.mem.eql(u8, repository, "repo.git"));
        const who = userOf(request);
        if (request.headers.get("authorization") != null and who == null) return .{ .challenge = "Basic realm=\"Git LFS\"" };
        return switch (access) {
            .download => .{ .allow = who },
            .upload => if (who) |name| .{ .allow = name } else .{ .challenge = "Basic realm=\"Git LFS\"" },
            // Only ada breaks other people's locks.
            .force_unlock => if (who != null and std.mem.eql(u8, who.?, "ada")) .{ .allow = who } else .deny,
        };
    }

    fn now(_: ?*anyopaque) i64 {
        return 1_700_000_000;
    }

    fn gitUser(_: ?*anyopaque, request: *uplink.server.Request) ?[]const u8 {
        return userOf(request);
    }
};

fn runServer(s: *uplink.Server, io: Io, listener: *Io.net.Server) void {
    s.serve(io, listener) catch {}; // glint-ignore: Z026 -- the server stops when the test shuts it down; how is not the test's question
}

const Bench = struct {
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,

    fn git(b: Bench, dir: Io.Dir, args: []const []const u8) !void {
        b.gpa.free(try testlfs.git(b.gpa, b.io, dir, b.env, args, true));
    }

    fn gitOut(b: Bench, dir: Io.Dir, args: []const []const u8) ![]u8 {
        return testlfs.git(b.gpa, b.io, dir, b.env, args, true);
    }

    /// git, expected to fail saying `said` on its error stream.
    fn gitFails(b: Bench, dir: Io.Dir, args: []const []const u8, said: []const u8) !void {
        const hooks = try b.gpa.print("core.hooksPath={s}/hooks", .{b.env.get("HOME").?});
        defer b.gpa.free(hooks);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(b.gpa);
        try argv.append(b.gpa, "git");
        try argv.appendSlice(b.gpa, &testgit.default_settings);
        try argv.appendSlice(b.gpa, &.{ "-c", hooks });
        try argv.appendSlice(b.gpa, args);
        var outcome = try program.run(b.gpa, b.io, .{ .environ = b.env }, .{ .argv = argv.items, .cwd = .{ .dir = dir } }, .{});
        defer outcome.deinit(b.gpa);
        try testing.expect(!outcome.succeeded());
        if (std.mem.find(u8, outcome.stderr, said) == null) {
            std.debug.print("git {s} said:\n{s}\n", .{ args[0], outcome.stderr });
            return error.TestUnexpectedResult;
        }
    }

    fn gitWith(b: Bench, dir: Io.Dir, name: []const u8, value: []const u8, args: []const []const u8) !void {
        var env = try b.env.clone(b.gpa);
        defer env.deinit();
        try env.put(name, value);
        b.gpa.free(try testlfs.git(b.gpa, b.io, dir, &env, args, true));
    }
};

fn expectFile(io: Io, dir: Io.Dir, name: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(io, name, testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

fn expectStored(io: Io, store: Io.Dir, bytes: []const u8) !void {
    const oid = testlfs.sha256Hex(bytes);
    var buf: [256]u8 = undefined;
    const path = try std.mem.print(&buf, "repo.git/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
    try expectFile(io, store, path, bytes);
}

test "git-lfs pushes, clones, pulls and locks against relic's LFS server" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(root);
    for ([_][]const u8{ "home", "tools", "served", "store" }) |name| try tmp.dir.createDirPath(io, name);
    const home = try gpa.print("{s}/home", .{root});
    defer gpa.free(home);
    var env = try testlfs.environ(gpa, home);
    defer env.deinit();
    try testgit.noRepositoryAbove(&env, root);
    try testlfs.requireGitLfs(gpa, io, &env);
    const b: Bench = .{ .gpa = gpa, .io = io, .env = &env };

    var tools = try tmp.dir.openDir(io, "tools", .{});
    defer tools.close(io);
    const ada_helper = try testlfs.credentialHelper(gpa, io, tools, "ada-helper", "ada", "secret");
    defer gpa.free(ada_helper);
    const bob_helper = try testlfs.credentialHelper(gpa, io, tools, "bob-helper", "bob", "hunter2");
    defer gpa.free(bob_helper);

    // The served repository, and the store its objects go to.
    var served_root = try tmp.dir.openDir(io, "served", .{});
    defer served_root.close(io);
    try b.git(served_root, &.{ "init", "-q", "--bare", "-b", "main", "repo.git" });
    var served = try served_root.openDir(io, "repo.git", .{});
    defer served.close(io);
    try b.git(served, &.{ "config", "http.receivepack", "true" });
    const served_path = try gpa.print("{s}/served", .{root});
    defer gpa.free(served_path);
    var store_dir = try tmp.dir.openDir(io, "store", .{});
    defer store_dir.close(io);

    var policy: Policy = .{};
    var git_backend: http_backend.Backend = .init(gpa, served_path, .{ .export_all = true, .caller = .{ .user = Policy.gitUser, .now = Policy.now } });
    var directory: server.Directory = .{ .dir = store_dir };
    var backend: server.Backend = .init(gpa, served_path, .{
        .export_all = true,
        .store = directory.store(),
        .caller = .{ .context = &policy, .authorize = Policy.authorize, .now = Policy.now },
        .git = &git_backend,
    });
    var http_server = uplink.Server.init(gpa, .{}, backend.handler());
    defer http_server.deinit(io);
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var task = try io.concurrent(runServer, .{ &http_server, io, &listener });
    defer {
        http_server.shutdown(io);
        task.await(io);
    }
    const url = try gpa.print("http://127.0.0.1:{d}/repo.git", .{listener.socket.address.getPort()});
    defer gpa.free(url);
    const verify_key = try gpa.print("lfs.{s}/info/lfs.locksverify", .{url});
    defer gpa.free(verify_key);

    // git-lfs's filters, in the test's own home, and its hooks where the
    // suite's git keeps them.
    try b.git(tmp.dir, &.{ "lfs", "install", "--skip-repo" });

    // ada pushes two LFS files and a plain one: git-lfs's pre-push hook
    // uploads the objects through the batch API.
    try tmp.dir.createDirPath(io, "ada");
    var ada = try tmp.dir.openDir(io, "ada", .{});
    defer ada.close(io);
    try b.git(ada, &.{ "init", "-q", "-b", "main" });
    try b.git(ada, &.{ "lfs", "install", "--local" });
    try b.git(ada, &.{ "remote", "add", "origin", url });
    try b.git(ada, &.{ "config", "credential.helper", ada_helper });
    try b.git(ada, &.{ "config", verify_key, "true" });
    const big = try lt.noise(gpa, 300 * 1024, 1);
    defer gpa.free(big);
    try ada.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.bin filter=lfs diff=lfs merge=lfs -text lockable\n" });
    try ada.writeFile(io, .{ .sub_path = "a.bin", .data = big });
    try ada.writeFile(io, .{ .sub_path = "b.bin", .data = "b content\n" });
    try ada.writeFile(io, .{ .sub_path = "plain.txt", .data = "plain\n" });
    try b.git(ada, &.{ "add", "-A" });
    try b.git(ada, &.{ "commit", "-q", "-m", "first" });
    try b.git(ada, &.{ "push", "-q", "origin", "main" });
    try expectStored(io, store_dir, big);
    try expectStored(io, store_dir, "b content\n");
    // A push of the same objects again asks and sends nothing.
    try b.git(ada, &.{ "lfs", "push", "origin", "main" });

    // bob clones: the smudge filter downloads every object, anonymously.
    const bob_path = try gpa.print("{s}/bob", .{root});
    defer gpa.free(bob_path);
    try b.git(tmp.dir, &.{ "clone", "-q", url, bob_path });
    var bob = try tmp.dir.openDir(io, "bob", .{});
    defer bob.close(io);
    try expectFile(io, bob, "a.bin", big);
    try expectFile(io, bob, "b.bin", "b content\n");
    try b.git(bob, &.{ "config", "credential.helper", bob_helper });
    try b.git(bob, &.{ "config", verify_key, "true" });
    try b.git(bob, &.{ "lfs", "install", "--local" });

    // ada changes a file; bob pulls without smudging, then `git lfs pull`
    // puts the new content in place of the pointer.
    const changed = try lt.noise(gpa, 200 * 1024, 2);
    defer gpa.free(changed);
    try ada.writeFile(io, .{ .sub_path = "a.bin", .data = changed });
    try b.git(ada, &.{ "commit", "-q", "-am", "second" });
    try b.git(ada, &.{ "push", "-q", "origin", "main" });
    try b.gitWith(bob, "GIT_LFS_SKIP_SMUDGE", "1", &.{ "pull", "-q", "--ff-only", "origin", "main" });
    const pointer = try bob.readFileAlloc(io, "a.bin", gpa, .limited(1024));
    defer gpa.free(pointer);
    try testing.expect(std.mem.startsWith(u8, pointer, "version https://git-lfs.github.com/spec/v1\n"));
    try b.git(bob, &.{ "lfs", "pull", "origin" });
    try expectFile(io, bob, "a.bin", changed);
    // Every object bob now has is whole.
    try b.git(bob, &.{ "lfs", "fsck", "--objects" });

    // bob locks a.bin; ada sees it as bob's and cannot give it back.
    try b.git(bob, &.{ "lfs", "lock", "a.bin" });
    const listed = try b.gitOut(ada, &.{ "lfs", "locks" });
    defer gpa.free(listed);
    try testing.expect(std.mem.find(u8, listed, "a.bin") != null);
    try testing.expect(std.mem.find(u8, listed, "bob") != null);
    try b.gitFails(ada, &.{ "lfs", "lock", "a.bin" }, "lock already created");
    try b.gitFails(ada, &.{ "lfs", "unlock", "a.bin" }, "lock is owned by someone else");
    const theirs = try b.gitOut(bob, &.{ "lfs", "locks", "--verify" });
    defer gpa.free(theirs);
    try testing.expect(std.mem.find(u8, theirs, "O a.bin") != null);

    // A push of a file someone else holds is refused by git-lfs's lock
    // check against the verify endpoint.
    // git-lfs keeps a file someone else holds read-only.
    try ada.deleteFile(io, "a.bin");
    try ada.writeFile(io, .{ .sub_path = "a.bin", .data = "ada's edit\n" });
    try b.git(ada, &.{ "commit", "-q", "-am", "edit while locked" });
    try b.gitFails(ada, &.{ "push", "-q", "origin", "main" }, "Cannot update locked files.");

    // bob cannot break ada's lock; ada breaks bob's, and the push goes.
    try b.git(ada, &.{ "lfs", "lock", "b.bin" });
    try b.gitFails(bob, &.{ "lfs", "unlock", "--force", "b.bin" }, "Forbidden");
    try b.git(ada, &.{ "lfs", "unlock", "--force", "a.bin" });
    try b.git(ada, &.{ "push", "-q", "origin", "main" });
    try expectStored(io, store_dir, "ada's edit\n");
    try b.git(ada, &.{ "lfs", "unlock", "b.bin" });
    const none = try b.gitOut(bob, &.{ "lfs", "locks" });
    defer gpa.free(none);
    try testing.expectEqualStrings("", std.mem.trim(u8, none, " \n"));

    // The locks are kept as git-lfs keeps its own: a JSON array, now empty.
    try expectFile(io, served, "lfs/locks.json", "[]\n");
    try testing.expect(policy.asked.load(.monotonic) > 0);
}
