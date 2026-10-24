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
const fs = @import("../fs/fs.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const uplink = @import("uplink");
const sigv4 = uplink.wire.sigv4;
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
    const got = try fs.readWhole(dir, io, name, testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

fn expectStored(io: Io, store: Io.Dir, bytes: []const u8) !void {
    const oid = testlfs.sha256Hex(bytes);
    var buf: [256]u8 = undefined;
    const path = try std.mem.print(&buf, "repo.git/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
    try expectFile(io, store, path, bytes);
}

/// A remote served by relic: a bare `repo.git` under `served`, git's smart
/// HTTP and the LFS API on one uplink server, the test's own home and
/// tools, and git-lfs's filters installed there.
const World = struct {
    gpa: Allocator,
    io: Io,
    tmp: testing.TmpDir,
    root: []u8,
    env: std.process.Environ.Map,
    tools: Io.Dir,
    served: Io.Dir,
    served_path: []u8,
    policy: Policy = .{},
    git_backend: http_backend.Backend = undefined,
    backend: server.Backend = undefined,
    http_server: uplink.Server = undefined,
    listener: Io.net.Server = undefined,
    task: Io.Future(void) = undefined,
    serving: bool = false,
    url: []u8 = &.{},

    fn init(gpa: Allocator, io: Io) !*World {
        const w = try gpa.create(World);
        errdefer gpa.destroy(w);
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try testremote.absolutePath(gpa, io, tmp.dir);
        errdefer gpa.free(root);
        for ([_][]const u8{ "home", "tools", "served", "store" }) |name| try tmp.dir.createDirPath(io, name);
        const home = try gpa.print("{s}/home", .{root});
        defer gpa.free(home);
        var env = try testlfs.environ(gpa, home);
        errdefer env.deinit();
        try testlfs.requireGitLfs(gpa, io, &env);
        w.* = .{ .gpa = gpa, .io = io, .tmp = tmp, .root = root, .env = env, .tools = undefined, .served = undefined, .served_path = &.{} };
        w.tools = try tmp.dir.openDir(io, "tools", .{});
        const b = w.bench();
        var served_root = try tmp.dir.openDir(io, "served", .{});
        defer served_root.close(io);
        try b.git(served_root, &.{ "init", "-q", "--bare", "-b", "main", "repo.git" });
        w.served = try served_root.openDir(io, "repo.git", .{});
        try b.git(w.served, &.{ "config", "http.receivepack", "true" });
        w.served_path = try gpa.print("{s}/served", .{root});
        // git-lfs's filters, in the test's own home, and its hooks where
        // the suite's git keeps them.
        try b.git(tmp.dir, &.{ "lfs", "install", "--skip-repo" });
        return w;
    }

    fn bench(w: *World) Bench {
        return .{ .gpa = w.gpa, .io = w.io, .env = &w.env };
    }

    /// Start serving, the objects in `store`.
    fn serve(w: *World, store: server.Store) !void {
        const gpa = w.gpa;
        w.git_backend = .init(gpa, w.served_path, .{ .export_all = true, .caller = .{ .user = Policy.gitUser, .now = Policy.now } });
        w.backend = .init(gpa, w.served_path, .{
            .export_all = true,
            .store = store,
            .caller = .{ .context = &w.policy, .authorize = Policy.authorize, .now = Policy.now },
            .git = &w.git_backend,
        });
        w.http_server = uplink.Server.init(gpa, .{}, w.backend.handler());
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        w.listener = try address.listen(w.io, .{ .reuse_address = true });
        w.task = try w.io.concurrent(runServer, .{ &w.http_server, w.io, &w.listener });
        w.serving = true;
        w.url = try gpa.print("http://127.0.0.1:{d}/repo.git", .{w.listener.socket.address.getPort()});
    }

    /// A working repository with git-lfs's hooks, `origin` at the server
    /// and `helper` its credential helper.
    fn work(w: *World, name: []const u8, helper: []const u8) !Io.Dir {
        const b = w.bench();
        try w.tmp.dir.createDirPath(w.io, name);
        const d = try w.tmp.dir.openDir(w.io, name, .{});
        try b.git(d, &.{ "init", "-q", "-b", "main" });
        try b.git(d, &.{ "lfs", "install", "--local" });
        try b.git(d, &.{ "remote", "add", "origin", w.url });
        try b.git(d, &.{ "config", "credential.helper", helper });
        return d;
    }

    fn deinit(w: *World) void {
        const gpa = w.gpa;
        if (w.serving) {
            w.http_server.shutdown(w.io);
            w.task.await(w.io);
            w.http_server.deinit(w.io);
            w.listener.deinit(w.io);
            gpa.free(w.url);
        }
        w.served.close(w.io);
        w.tools.close(w.io);
        gpa.free(w.served_path);
        w.env.deinit();
        gpa.free(w.root);
        w.tmp.cleanup();
        gpa.destroy(w);
    }
};

test "git-lfs pushes, clones, pulls and locks against relic's LFS server" {
    const gpa = testing.allocator;
    const io = testing.io;
    const w = try World.init(gpa, io);
    defer w.deinit();
    const b = w.bench();
    const ada_helper = try testlfs.credentialHelper(gpa, io, w.tools, "ada-helper", "ada", "secret");
    defer gpa.free(ada_helper);
    const bob_helper = try testlfs.credentialHelper(gpa, io, w.tools, "bob-helper", "bob", "hunter2");
    defer gpa.free(bob_helper);
    var store_dir = try w.tmp.dir.openDir(io, "store", .{});
    defer store_dir.close(io);
    var directory: server.Directory = .{ .dir = store_dir };
    try w.serve(directory.store());
    const tmp = &w.tmp;
    const root = w.root;
    const url = w.url;
    const served = w.served;
    const verify_key = try gpa.print("lfs.{s}/info/lfs.locksverify", .{url});
    defer gpa.free(verify_key);

    // ada pushes two LFS files and a plain one: git-lfs's pre-push hook
    // uploads the objects through the batch API.
    var ada = try w.work("ada", ada_helper);
    defer ada.close(io);
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
    const pointer = try fs.readWhole(bob, io, "a.bin", gpa, .limited(1024));
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
    try testing.expect(w.policy.asked.load(.monotonic) > 0);
}

/// S3-compatible storage, in memory, that takes only what is signed: a
/// `GET` or `PUT` through a URL whose signature is the one `presign` makes
/// for exactly the URL sent, and a `HEAD` whose `Authorization` is the one
/// `sign` makes for it.
const FakeS3 = struct {
    gpa: Allocator,
    signer: sigv4.Signer,
    mutex: Io.Mutex = .init,
    objects: std.array_hash_map.String([]u8) = .empty,
    presigned: std.atomic.Value(u32) = .init(0),
    signed: std.atomic.Value(u32) = .init(0),

    fn deinit(f: *FakeS3) void {
        for (f.objects.keys(), f.objects.values()) |k, v| {
            f.gpa.free(k);
            f.gpa.free(v);
        }
        f.objects.deinit(f.gpa);
    }

    fn serve(f: *FakeS3, io: Io, request: *uplink.server.Request, response: *uplink.server.Response) anyerror!void {
        var arena_state: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sent = try arena.print("http://{s}{s}", .{ request.host, request.target });
        if (!try f.signedRight(arena, request, sent)) return uplink.server.Router.plain(io, response, .forbidden, "SignatureDoesNotMatch");
        const key = request.path;
        if (request.method.eql(.PUT)) {
            const body = try request.collect(f.gpa, io, .limited(1 << 24));
            errdefer f.gpa.free(body);
            try f.mutex.lock(io);
            defer f.mutex.unlock(io);
            const entry = try f.objects.getOrPut(f.gpa, key);
            if (entry.found_existing) f.gpa.free(entry.value_ptr.*) else entry.key_ptr.* = try f.gpa.dupe(u8, key);
            entry.value_ptr.* = body;
            return uplink.server.Router.plain(io, response, .ok, "");
        }
        try f.mutex.lock(io);
        const held: ?[]const u8 = if (f.objects.get(key)) |v| try arena.dupe(u8, v) else null;
        f.mutex.unlock(io);
        const bytes = held orelse return uplink.server.Router.plain(io, response, .not_found, "NoSuchKey");
        try response.header("Content-Type", "application/octet-stream");
        try response.setLength(bytes.len);
        if (request.method.eql(.HEAD)) return response.end(io);
        return response.send(io, bytes);
    }

    fn signedRight(f: *FakeS3, arena: Allocator, request: *uplink.server.Request, sent: []const u8) !bool {
        if (request.method.eql(.HEAD)) {
            const date = request.headers.get("x-amz-date") orelse return false;
            var signed: sigv4.Signed = undefined;
            try f.signer.sign(.{ .method = "HEAD", .url = try uplink.wire.url.parse(sent), .payload = sigv4.empty_payload }, timeOf(date) orelse return false, &signed);
            const ok = std.mem.eql(u8, signed.authorization(), request.headers.get("authorization") orelse "");
            if (ok) _ = f.signed.fetchAdd(1, .monotonic);
            return ok;
        }
        // What was signed is the URL up to its query; the query says when
        // and for how long.
        const q = std.mem.findScalar(u8, sent, '?') orelse return false;
        const query = sent[q + 1 ..];
        const date = paramOf(query, "X-Amz-Date") orelse return false;
        const expires = std.fmt.parseInt(u32, paramOf(query, "X-Amz-Expires") orelse return false, 10) catch return false;
        var out: Io.Writer.Allocating = .init(arena);
        try f.signer.presign(&out.writer, sent[0..q], .{ .method = request.method.name, .url = try uplink.wire.url.parse(sent[0..q]) }, timeOf(date) orelse return false, expires);
        const ok = std.mem.eql(u8, out.written(), sent);
        if (ok) _ = f.presigned.fetchAdd(1, .monotonic);
        return ok;
    }

    fn paramOf(query: []const u8, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len > key.len and std.mem.startsWith(u8, pair, key) and pair[key.len] == '=') return pair[key.len + 1 ..];
        }
        return null;
    }

    fn timeOf(date: []const u8) ?i64 {
        if (date.len != 16) return null;
        const n = struct {
            fn n(t: []const u8) ?u32 {
                return std.fmt.parseInt(u32, t, 10) catch null;
            }
        }.n;
        return uplink.wire.date.civil(n(date[0..4]) orelse return null, n(date[4..6]) orelse return null, n(date[6..8]) orelse return null, n(date[9..11]) orelse return null, n(date[11..13]) orelse return null, n(date[13..15]) orelse return null);
    }
};

test "git-lfs moves objects through URLs S3-compatible storage signed for relic's LFS server" {
    const gpa = testing.allocator;
    const io = testing.io;
    const w = try World.init(gpa, io);
    defer w.deinit();
    const b = w.bench();
    const ada_helper = try testlfs.credentialHelper(gpa, io, w.tools, "ada-helper", "ada", "secret");
    defer gpa.free(ada_helper);

    // The storage, on a server of its own.
    const signer: sigv4.Signer = .{ .key = .{ .access_key = "AKIDLOCAL", .secret_key = "local/secret+key", .session_token = "session" }, .region = "local-1" };
    var fake: FakeS3 = .{ .gpa = gpa, .signer = signer };
    defer fake.deinit();
    var storage = uplink.Server.init(gpa, .{}, .init(&fake, FakeS3.serve));
    defer storage.deinit(io);
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var task = try io.concurrent(runServer, .{ &storage, io, &listener });
    defer {
        storage.shutdown(io);
        task.await(io);
    }
    const endpoint = try gpa.print("http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    defer gpa.free(endpoint);
    var client: uplink.Client = .init(gpa, .{});
    defer client.deinit(io);
    var s3: server.S3 = .{ .gpa = gpa, .client = &client, .endpoint = endpoint, .bucket = "objects", .prefix = "lfs/", .signer = signer, .expires = .fromRaw(600) };
    try w.serve(s3.store());

    // ada's push goes straight to the storage.
    var ada = try w.work("ada", ada_helper);
    defer ada.close(io);
    const big = try lt.noise(gpa, 150 * 1024, 3);
    defer gpa.free(big);
    try ada.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.bin filter=lfs diff=lfs merge=lfs -text\n" });
    try ada.writeFile(io, .{ .sub_path = "a b.bin", .data = big });
    try b.git(ada, &.{ "add", "-A" });
    try b.git(ada, &.{ "commit", "-q", "-m", "first" });
    try b.git(ada, &.{ "push", "-q", "origin", "main" });
    const oid = testlfs.sha256Hex(big);
    const key = try gpa.print("/objects/lfs/repo.git/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
    defer gpa.free(key);
    try testing.expectEqualSlices(u8, big, fake.objects.get(key).?);
    // Asked again, the storage has it and nothing is sent.
    try b.git(ada, &.{ "lfs", "push", "origin", "main" });

    // A clone downloads it from the storage.
    const bob_path = try gpa.print("{s}/bob", .{w.root});
    defer gpa.free(bob_path);
    try b.git(w.tmp.dir, &.{ "clone", "-q", w.url, bob_path });
    var bob = try w.tmp.dir.openDir(io, "bob", .{});
    defer bob.close(io);
    try expectFile(io, bob, "a b.bin", big);
    try testing.expect(fake.presigned.load(.monotonic) >= 2);
    try testing.expect(fake.signed.load(.monotonic) >= 2);
}
