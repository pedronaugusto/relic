//! Protocol policy: a URL from a repository -- a submodule's, a server's
//! redirect -- that reaches a transport the person never chose, `ext::`
//! running a command above all. The owner is `transport/policy.zig` (the
//! architecture's `wire/policy`), which `transport.Session.open` asks for
//! every transport, a remote helper's included, and a redirect asks again.

const config_mod = @import("../../config/config.zig");
const std = @import("std");
const Io = std.Io;

const policy = @import("../../wire.zig").policy;
const transport = @import("../../transport/transport.zig");
const object = @import("../../object/object.zig");
const sub_transport = @import("../../submodule/transport.zig");
const testgit = @import("../git.zig");
const testremote = @import("../remote.zig");

test "CVE-2015-7545, t5812..t5815-proto-disable: ext:: is never allowed, file:// only when the person asked, and the allow-list is the whole answer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // git's defaults.
    try std.testing.expect(!policy.allowed("ext", .{ .config = null, .environ = null, .from_user = true }));
    try std.testing.expect(policy.allowed("file", .{ .config = null, .environ = null, .from_user = true }));
    try std.testing.expect(!policy.allowed("file", .{ .config = null, .environ = null, .from_user = false }));
    for ([_][]const u8{ "http", "https", "ssh", "git" }) |name| try std.testing.expect(policy.allowed(name, .{ .config = null, .environ = null, .from_user = false }));
    // `GIT_ALLOW_PROTOCOL` is the whole answer, configuration or not.
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("GIT_ALLOW_PROTOCOL", "https:file");
    var always = try config_mod.Config.parseText(gpa, "[protocol]\n\tallow = always\n", .local);
    defer always.deinit();
    try std.testing.expect(!policy.allowed("ssh", .{ .config = &always, .environ = &env, .from_user = true }));
    try std.testing.expect(policy.allowed("https", .{ .config = &always, .environ = &env, .from_user = true }));
    // `protocol.<name>.allow` over `protocol.allow`.
    var config = try config_mod.Config.parseText(gpa, "[protocol]\n\tallow = never\n[protocol \"https\"]\n\tallow = always\n", .local);
    defer config.deinit();
    try std.testing.expect(policy.allowed("https", .{ .config = &config, .environ = null, .from_user = false }));
    try std.testing.expect(!policy.allowed("ssh", .{ .config = &config, .environ = null, .from_user = true }));

    // An `ext::` URL runs nothing: it is refused before a helper starts.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var programs_env = try testgit.programEnviron(gpa);
    defer programs_env.deinit();
    const url = try gpa.print("ext::sh -c touch% {s}/pwned", .{dir});
    defer gpa.free(url);
    try std.testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{
        .programs = .{ .environ = &programs_env },
    }));
    // A path on this machine that the person did not name.
    try std.testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, dir, .{ .service = .upload_pack, .kind = .sha1 }, .{
        .from_user = false,
    }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pwned", .{}));
}

test "CVE-2015-7545, t5815-submodule-protos: a .gitmodules URL is not the person's, so ext:: and a path on this machine are refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(source_path);
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    const who: object.Signature = .{ .name = "S", .email = "s@example.com", .when_secs = 1, .offset_minutes = 0 };

    for ([_][]const u8{ "ext::sh -c touch% pwned", source_path }) |url| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var t = sub_transport.Transport.init(.{ .who = who, .programs = .{ .environ = &env } });
        defer t.deinit();
        const seam = t.transport();
        try std.testing.expectError(error.TransportFailed, seam.cloneFn(gpa, io, seam.context, url, tmp.dir));
        try std.testing.expectEqual(error.TransportNotAllowed, t.failure.?);
        try std.testing.expectEqual(@as(u32, 0), t.clones);
    }
}

/// A bare history under `root`, which an HTTP server there serves.
fn served(gpa: std.mem.Allocator, io: Io, root: *std.testing.TmpDir) !void {
    var source = try testremote.historyRepo(gpa, io, 1);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const bare = try gpa.print("{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
}

test "git 2.11.1, t5812-proto-disable-http 'curl limits redirects' and t5550-http-fetch-dumb 'redirects can be forbidden': a redirect goes to http(s) alone, and only where allowed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, &root);
    // A redirect to another protocol is refused, whatever it names.
    for ([_][]const u8{ "file:///tmp", "ftp://127.0.0.1", "ext::sh -c touch% pwned;" }) |to| {
        const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .redirect = true, .redirect_to = to });
        defer server.stop();
        const url = try server.url(gpa, "moved/repo.git");
        defer gpa.free(url);
        if (transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{})) |opened| {
            var session = opened;
            session.deinit(io);
            std.debug.print("a redirect to {s} was followed\n", .{to});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // `http.followRedirects=false` follows none; the default follows the
    // first request's and sends the rest where it led.
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .redirect = true });
    defer server.stop();
    const url = try server.url(gpa, "moved/repo.git");
    defer gpa.free(url);
    var never = try config_mod.Config.parseText(gpa, "[http]\n\tfollowRedirects = false\n", .local);
    defer never.deinit();
    try std.testing.expectError(error.HttpStatus, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &never }));
    var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{});
    defer session.deinit(io);
    var refs = try session.listRefs(gpa, io, &.{"refs/heads/"});
    defer refs.deinit();
    const log = try server.requests(gpa);
    defer gpa.free(log);
    try std.testing.expect(std.mem.find(u8, log, "POST /repo.git/git-upload-pack") != null);
    try std.testing.expect(std.mem.find(u8, log, "POST /moved/") == null);
}
