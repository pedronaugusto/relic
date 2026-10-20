//! relic's smart HTTP server held to git: real git clones, fetches and
//! pushes over `http://` to repositories relic serves on uplink's server,
//! in protocol v2 and v0, a fetch's large request compressed as git sends
//! it, and ends where it ends against the same repositories on disk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const uplink = @import("uplink");
const testremote = @import("../testing/remote.zig");
const http_backend = @import("http_backend.zig");

/// The backend, with what the requests it saw were sent as.
const Served = struct {
    backend: http_backend.Backend,
    gzipped: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),

    fn serve(s: *Served, io: Io, request: *uplink.server.Request, response: *uplink.server.Response) anyerror!void {
        _ = s.requests.fetchAdd(1, .monotonic);
        if (request.headers.get("content-encoding")) |coding| {
            if (std.mem.eql(u8, coding, "gzip")) _ = s.gzipped.fetchAdd(1, .monotonic);
        }
        return s.backend.serve(io, request, response);
    }

    fn user(_: ?*anyopaque, _: *uplink.server.Request) ?[]const u8 {
        return "pusher";
    }

    fn now(_: ?*anyopaque) i64 {
        return 1_700_000_000;
    }
};

fn runServer(server: *uplink.Server, io: Io, listener: *Io.net.Server) void {
    server.serve(io, listener) catch {}; // glint-ignore: Z026 -- the server stops when the test shuts it down; how is not the test's question
}

test "git clones, fetches and pushes over HTTP against relic's server, in v2 and v0" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    // The served repository: a history with a branch and tags, pushes
    // taken.
    var source = try testremote.historyRepo(gpa, io, 4);
    defer source.deinit();
    const served_path = try gpa.print("{s}/served.git", .{root_path});
    defer gpa.free(served_path);
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    try git(gpa, io, root.dir, &env, &.{ "clone", "-q", "--bare", source_path, served_path });
    var served_dir = try Io.Dir.cwd().openDir(io, served_path, .{});
    defer served_dir.close(io);
    try git(gpa, io, served_dir, &env, &.{ "config", "http.receivepack", "true" });
    try git(gpa, io, served_dir, &env, &.{ "config", "core.logAllRefUpdates", "true" });
    try served_dir.writeFile(io, .{ .sub_path = "git-daemon-export-ok", .data = "" });

    var served: Served = .{ .backend = .init(gpa, root_path, .{ .caller = .{ .user = Served.user, .now = Served.now } }) };
    var server = uplink.Server.init(gpa, .{}, .init(&served, Served.serve));
    defer server.deinit(io);
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var task = try io.concurrent(runServer, .{ &server, io, &listener });
    defer {
        server.shutdown(io);
        task.await(io);
    }
    const url = try gpa.print("http://127.0.0.1:{d}/served.git", .{listener.socket.address.getPort()});
    defer gpa.free(url);

    for ([_][]const u8{ "2", "0" }) |version| {
        const setting = try gpa.print("protocol.version={s}", .{version});
        defer gpa.free(setting);
        const clone_path = try gpa.print("{s}/clone-v{s}", .{ root_path, version });
        defer gpa.free(clone_path);
        try git(gpa, io, root.dir, &env, &.{ "-c", setting, "clone", "-q", url, clone_path });
        var clone = try Io.Dir.cwd().openDir(io, clone_path, .{});
        defer clone.close(io);
        try expectSameRefs(gpa, io, &env, clone, served_dir, "refs/remotes/origin/", "refs/heads/");

        // A push of new commits, a new branch and a tag over HTTP.
        try clone.writeFile(io, .{ .sub_path = "pushed.txt", .data = version });
        try git(gpa, io, clone, &env, &.{ "add", "pushed.txt" });
        try git(gpa, io, clone, &env, &.{ "-c", "user.name=P", "-c", "user.email=p@example.com", "commit", "-qm", "pushed" });
        const branch = try gpa.print("main:refs/heads/from-v{s}", .{version});
        defer gpa.free(branch);
        try git(gpa, io, clone, &env, &.{ "-c", setting, "push", "-q", "origin", "main", branch });
        try git(gpa, io, served_dir, &env, &.{ "fsck", "--strict", "--no-dangling" });
        const theirs = try line(gpa, io, &env, clone, "HEAD");
        defer gpa.free(theirs);
        const ours = try line(gpa, io, &env, served_dir, "refs/heads/main");
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        // Logged as the user the server authenticated.
        const logged = try testremote.gitInputEnv(gpa, io, served_dir, &env, &.{ "log", "-g", "-1", "--format=%gn <%ge>", "refs/heads/main" }, "", true);
        defer gpa.free(logged);
        try testing.expectEqualStrings("pusher <pusher@http.127.0.0.1>\n", logged);
    }

    // A fetch of many new branches: its request carries enough `want`s for
    // git to compress it.
    const behind_path = try gpa.print("{s}/behind", .{root_path});
    defer gpa.free(behind_path);
    try git(gpa, io, root.dir, &env, &.{ "-c", "protocol.version=0", "clone", "-q", url, behind_path });
    var behind = try Io.Dir.cwd().openDir(io, behind_path, .{});
    defer behind.close(io);
    for (0..40) |i| {
        var msg: [32]u8 = undefined;
        try git(gpa, io, source.dir, &env, &.{ "commit", "-q", "--allow-empty", "-m", try std.mem.print(&msg, "branch {d}", .{i}) });
        var name: [32]u8 = undefined;
        try git(gpa, io, source.dir, &env, &.{ "branch", try std.mem.print(&name, "many-{d}", .{i}) });
    }
    try git(gpa, io, source.dir, &env, &.{ "push", "-q", served_path, "refs/heads/many-*:refs/heads/many-*" });
    const before = served.gzipped.load(.monotonic);
    for ([_][]const u8{ "2", "0" }) |version| {
        const setting = try gpa.print("protocol.version={s}", .{version});
        defer gpa.free(setting);
        try git(gpa, io, behind, &env, &.{ "-c", setting, "fetch", "-q", "origin" });
    }
    try expectSameRefs(gpa, io, &env, behind, served_dir, "refs/remotes/origin/", "refs/heads/");
    try testing.expect(served.gzipped.load(.monotonic) > before);

    // Pushing is refused where the repository does not take it.
    try git(gpa, io, served_dir, &env, &.{ "config", "http.receivepack", "false" });
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, behind, &env, &.{ "push", "-q", "origin", "HEAD:refs/heads/refused" }, "", false));
}

fn git(gpa: Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    const out = try testremote.gitInputEnv(gpa, io, dir, env, args, "", true);
    gpa.free(out);
}

fn line(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, rev: []const u8) ![]u8 {
    return testremote.gitInputEnv(gpa, io, dir, env, &.{ "rev-parse", rev }, "", true);
}

/// `ours`'s refs under `ours_prefix` are `theirs`'s under `theirs_prefix`.
fn expectSameRefs(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, ours: Io.Dir, theirs: Io.Dir, ours_prefix: []const u8, theirs_prefix: []const u8) !void {
    const a = try testremote.gitInputEnv(gpa, io, ours, env, &.{ "for-each-ref", "--format=%(refname:lstrip=3) %(objectname)", ours_prefix }, "", true);
    defer gpa.free(a);
    const b = try testremote.gitInputEnv(gpa, io, theirs, env, &.{ "for-each-ref", "--format=%(refname:lstrip=2) %(objectname)", theirs_prefix }, "", true);
    defer gpa.free(b);
    var it = std.mem.tokenizeScalar(u8, b, '\n');
    while (it.next()) |ref| {
        if (std.mem.find(u8, a, ref) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ ref, a });
            return error.TestExpectedEqual;
        }
    }
}
