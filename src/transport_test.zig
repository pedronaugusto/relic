//! Transport tests that stand relic beside git: the same fetches, the same
//! ssh arguments, the same credential helpers, over a stand-in ssh and over
//! an HTTP server serving `git http-backend`, each started by the test on
//! this machine.
//!
//! They live apart from `ssh.zig` and `smarthttp.zig` because they drive the
//! operations above those modules, which the modules themselves do not
//! import.

const std = @import("std");
const suite = @import("testing/helpers.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const config_mod = @import("config.zig");
const credential = @import("transport/credential.zig");
const repo_mod = @import("repo.zig");
const fetch_mod = @import("transport/fetch.zig");
const clone_mod = @import("transport/clone.zig");
const transport = @import("transport.zig");
const uplink = @import("dependencies.zig").uplink;
const testgit = @import("testing/git.zig");
const testremote = @import("testing/remote.zig");
const testlfs = @import("testing/lfs.zig");
const object = @import("object.zig");
const progress_mod = @import("transport/progress.zig");
const builtin = @import("builtin");
const warning = @import("repo/warning.zig");
const push_mod = @import("transport/push.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// A bare copy of a history under a directory an HTTP server serves.
fn servedRepo(gpa: Allocator, io: Io, root: *testing.TmpDir, commits: usize) !void {
    var source = try testremote.historyRepo(gpa, io, commits);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const bare = try gpa.print("{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
}

fn expectSameFetch(gpa: Allocator, io: Io, by_git: *testgit.Repo, by_relic: *testgit.Repo) !void {
    const format = "--format=%(refname) %(objectname) %(symref)";
    const theirs = try by_git.run(io, &.{ "for-each-ref", format });
    defer gpa.free(theirs);
    const ours = try by_relic.run(io, &.{ "for-each-ref", format });
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
    const head_theirs = try by_git.readFile(io, ".git/FETCH_HEAD");
    defer gpa.free(head_theirs);
    const head_ours = try by_relic.readFile(io, ".git/FETCH_HEAD");
    defer gpa.free(head_ours);
    try testing.expectEqualStrings(head_theirs, head_ours);
    try by_relic.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
}

test "a fetch over smart HTTP leaves what git fetch leaves, in v2 and in v0" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    for ([_]bool{ true, false }) |v2| {
        var root = testing.tmpDir(.{ .iterate = true });
        defer root.cleanup();
        try servedRepo(gpa, io, &root, 5);
        const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .protocol_v2 = v2 });
        defer server.stop();
        const url = try server.url(gpa, "repo.git");
        defer gpa.free(url);

        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| try twin.exec(io, &.{ "remote", "add", "origin", url });
        try by_git.exec(io, &.{ "fetch", "origin" });
        var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
        defer repo.deinit(io);
        // The server's progress comes to the caller, and only there.
        const Heard = struct {
            const Self = @This();
            remote: usize = 0,
            received: u64 = 0,
            indexed: u64 = 0,
            fn report(context: ?*anyopaque, event: progress_mod.Event) void {
                const self_: *Self = @ptrCast(@alignCast(context.?));
                switch (event) {
                    .remote => self_.remote += 1,
                    .received => |n| self_.received = n,
                    .indexed => |c| self_.indexed = c.done,
                    else => {},
                }
            }
        };
        var heard: Heard = .{};
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{
            .who = test_who,
            .programs = .{ .environ = &env },
            .progress = .{ .context = &heard, .report = Heard.report },
        });
        defer outcome.deinit();
        try testing.expect(outcome.pack != null);
        try testing.expect(heard.remote > 0);
        try testing.expect(heard.received > 0);
        try testing.expectEqual(@as(u64, outcome.objects), heard.indexed);
        try expectSameFetch(gpa, io, &by_git, &by_relic);
    }
}

test "the first request's redirect is followed, and the requests after it go where it led" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .redirect = true });
    defer server.stop();
    const url = try server.url(gpa, "moved/repo.git");
    defer gpa.free(url);

    var session = try transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{});
    defer session.close(io);
    var refs = try session.listRefs(gpa, io, &.{"refs/heads/"});
    defer refs.deinit();
    try testing.expect(refs.find("refs/heads/main") != null);
    const log = try server.requests(gpa);
    defer gpa.free(log);
    try testing.expect(std.mem.find(u8, log, "GET /moved/repo.git/info/refs?service=git-upload-pack") != null);
    try testing.expect(std.mem.find(u8, log, "POST /repo.git/git-upload-pack") != null);
}

test "a redirect to another server takes no credential with it, an extraHeader's Authorization included, as curl takes none for git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 1);
    const other = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer other.stop();
    const other_base = try gpa.print("http://127.0.0.1:{d}", .{other.port});
    defer gpa.free(other_base);
    const away = try testremote.HttpServer.start(gpa, io, root.dir, .{ .redirect = true, .redirect_to = other_base });
    defer away.stop();
    const here = try testremote.HttpServer.start(gpa, io, root.dir, .{ .redirect = true });
    defer here.stop();
    var config = try config_mod.Config.parseText(gpa, "[http]\n\textraHeader = Authorization: Bearer t0ken\n", .local);
    defer config.deinit();

    for ([_]*testremote.HttpServer{ here, away }) |server| {
        const url = try server.url(gpa, "moved/repo.git");
        defer gpa.free(url);
        var session = try transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .config = &config });
        session.close(io);
    }
    // The same server: every request with the header.
    const same = try here.requests(gpa);
    defer gpa.free(same);
    try testing.expect(std.mem.find(u8, same, "GET /moved/repo.git/info/refs?service=git-upload-pack auth\n") != null);
    try testing.expect(std.mem.find(u8, same, "GET /repo.git/info/refs?service=git-upload-pack auth\n") != null);
    // Another server: the first request with it, none after.
    const first = try away.requests(gpa);
    defer gpa.free(first);
    try testing.expect(std.mem.find(u8, first, "GET /moved/repo.git/info/refs?service=git-upload-pack auth\n") != null);
    const moved = try other.requests(gpa);
    defer gpa.free(moved);
    try testing.expect(std.mem.find(u8, moved, "GET /repo.git/info/refs?service=git-upload-pack -\n") != null);
    try testing.expect(std.mem.find(u8, moved, " auth") == null);

    // http.followRedirects=false follows none.
    var never = try config_mod.Config.parseText(gpa, "[http]\n\tfollowRedirects = false\n", .local);
    defer never.deinit();
    const url = try here.url(gpa, "moved/repo.git");
    defer gpa.free(url);
    try testing.expectError(error.HttpStatus, transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .config = &never }));
}

test "a redirect whose user decodes to a newline is refused before any helper hears of it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 1);
    const guarded = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" } });
    defer guarded.stop();
    const hostile = try gpa.print("http://u%0ahost=github.com@127.0.0.1:{d}", .{guarded.port});
    defer gpa.free(hostile);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .redirect = true, .redirect_to = hostile });
    defer server.stop();
    const url = try server.url(gpa, "moved/repo.git");
    defer gpa.free(url);
    // A helper is configured and no programs are granted: one reached
    // would be `ProgramsNotGranted`.
    var config = try config_mod.Config.parseText(gpa, "[credential]\n\thelper = store\n", .local);
    defer config.deinit();
    try testing.expectError(error.CredentialValueUnsafe, transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .config = &config }));
}

test "a transport the configuration or GIT_ALLOW_PROTOCOL refuses is not opened" {
    const gpa = testing.allocator;
    const io = testing.io;
    var config = try config_mod.Config.parseText(gpa, "[protocol \"http\"]\n\tallow = never\n", .local);
    defer config.deinit();
    try testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "http://127.0.0.1:1/repo.git", .upload_pack, .sha1, .{ .config = &config }));
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_ALLOW_PROTOCOL", "https");
    try testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "/nonexistent/repo.git", .upload_pack, .sha1, .{ .programs = .{ .environ = &env } }));
    try testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "/nonexistent/repo.git", .upload_pack, .sha1, .{ .from_user = false }));
}

test "a missing repository, a dumb setting and a header that is not one are refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 1);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const missing = try server.url(gpa, "nothere.git");
    defer gpa.free(missing);
    try testing.expectError(error.RepositoryNotFound, transport.Session.open(gpa, io, missing, .upload_pack, .sha1, .{}));

    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    // The TLS ones are read for an https URL, and refused before anything
    // is sent.
    const secure = try gpa.print("https://127.0.0.1:{d}/repo.git", .{server.port});
    defer gpa.free(secure);
    for ([_][]const u8{
        "[http]\nextraHeader = no colon here\n",
        "[http]\nsslCert = /nonexistent/client.pem\n",
        "[http]\nsslCAInfo = /nonexistent/ca.pem\n",
        "[http]\nproxy = http://127.0.0.1:1\nproxyAuthMethod = ntlm\n",
    }, [_]anyerror{
        error.InvalidHttpHeader,        error.SslClientCertificateUnreadable,
        error.SslCertificateUnreadable, error.ProxyAuthMethodUnsupported,
    }) |text, expected| {
        var config = try config_mod.Config.parseText(gpa, text, .local);
        defer config.deinit();
        const target = if (expected == error.InvalidHttpHeader) url else secure;
        try testing.expectError(expected, transport.Session.open(gpa, io, target, .upload_pack, .sha1, .{ .config = &config }));
    }
    // Over plain http git reads no TLS setting, and neither does relic.
    var plain = try config_mod.Config.parseText(gpa, "[http]\nsslVerify = false\n", .local);
    defer plain.deinit();
    var session = try transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .config = &plain });
    session.close(io);
}

/// A credential helper that notes each operation and its input in `<dir>/helper.log`
/// and answers `get` with `ada` and `password`.
fn helperScript(gpa: Allocator, io: Io, dir: Io.Dir, password: []const u8) ![]u8 {
    const path = try testlfs.installProgram(gpa, io, dir, "helper", suite.path(.lfs_test_tool));
    errdefer gpa.free(path);
    const sidecar = try gpa.print("{s}.fixture", .{path});
    defer gpa.free(sidecar);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sidecar, .data = "credential-person\n" });
    const answer = try gpa.print("username=ada\npassword={s}\n", .{password});
    defer gpa.free(answer);
    try dir.writeFile(io, .{ .sub_path = "helper.answer", .data = answer });
    return path;
}

test "credentials come from a helper as git asks for them, are stored when they work and erased when not" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" } });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    for ([_][]const u8{ "secret", "wrong" }) |password| {
        var tools_git = testing.tmpDir(.{ .iterate = true });
        defer tools_git.cleanup();
        var tools_relic = testing.tmpDir(.{ .iterate = true });
        defer tools_relic.cleanup();
        const helper_git = try helperScript(gpa, io, tools_git.dir, password);
        defer gpa.free(helper_git);
        const helper_relic = try helperScript(gpa, io, tools_relic.dir, password);
        defer gpa.free(helper_relic);

        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        try by_git.exec(io, &.{ "remote", "add", "origin", url });
        try by_relic.exec(io, &.{ "remote", "add", "origin", url });
        try by_git.exec(io, &.{ "config", "credential.helper", helper_git });
        try by_relic.exec(io, &.{ "config", "credential.helper", helper_relic });

        const ok = std.mem.eql(u8, password, "secret");
        // git runs with no system or global configuration, so no helper of
        // the person running the suite is asked or told anything.
        const git_result = if (testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", ok)) |out| blk: {
            gpa.free(out);
            break :blk {};
        } else |err| err;
        var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
        defer repo.deinit(io);
        if (ok) {
            try git_result;
            var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } });
            outcome.deinit();
            try expectSameFetch(gpa, io, &by_git, &by_relic);
        } else {
            try testing.expectError(error.GitFailed, git_result);
            try testing.expectError(error.AuthenticationFailed, fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } }));
        }

        // The helpers were asked the same things in the same order: `get`,
        // then `store` or `erase`, each with the protocol, the host and the
        // user as git sends them.
        const theirs = try tools_git.dir.readFileAlloc(io, "helper.log", gpa, .unlimited);
        defer gpa.free(theirs);
        const ours = try tools_relic.dir.readFileAlloc(io, "helper.log", gpa, .unlimited);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
}

test "credentials in the URL, from askpass and from the caller's prompt are what git would send" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 1);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" } });
    defer server.stop();

    const with_userinfo = try gpa.print("http://ada:secret@127.0.0.1:{d}/repo.git", .{server.port});
    defer gpa.free(with_userinfo);
    {
        var session = try transport.Session.open(gpa, io, with_userinfo, .upload_pack, .sha1, .{});
        session.close(io);
    }

    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    // Without a helper, a prompt, or the permission to run askpass, there
    // is nothing to ask.
    try testing.expectError(error.CredentialsUnavailable, transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{}));

    // askpass: asked with git's own prompts.
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const askpass = try testlfs.installProgram(gpa, io, tools.dir, "askpass", suite.path(.lfs_test_tool));
    defer gpa.free(askpass);
    const askpass_sidecar = try gpa.print("{s}.fixture", .{askpass});
    defer gpa.free(askpass_sidecar);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = askpass_sidecar, .data = "askpass\n" });
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_ASKPASS", askpass);
    // askpass is a window in front of the person: without the caller's
    // leave it is not run, and there is still nothing to ask.
    try testing.expectError(error.CredentialsUnavailable, transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .programs = .{ .environ = &env } }));
    {
        var session = try transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .programs = .{ .environ = &env }, .prompt = .{ .askpass = true } });
        session.close(io);
    }
    const ours = try tools.dir.readFileAlloc(io, "askpass.log", gpa, .unlimited);
    defer gpa.free(ours);
    try tools.dir.deleteFile(io, "askpass.log");
    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var git_env = try testremote.environ(gpa);
    defer git_env.deinit();
    try git_env.put("GIT_ASKPASS", askpass);
    const listed = try testremote.gitInputEnv(gpa, io, by_git.dir, &git_env, &.{ "ls-remote", url }, "", true);
    gpa.free(listed);
    const theirs = try tools.dir.readFileAlloc(io, "askpass.log", gpa, .unlimited);
    defer gpa.free(theirs);
    try testing.expectEqualStrings(theirs, ours);

    // The caller's prompt, where no askpass is set.
    const Asked = struct {
        const Self = @This();
        prompts: std.ArrayList(u8) = .empty,
        fn ask(allocator: Allocator, context: ?*anyopaque, field: credential.Field, prompt: []const u8) Allocator.Error!?[]u8 {
            const self_: *Self = @ptrCast(@alignCast(context.?));
            try self_.prompts.appendSlice(testing.allocator, prompt);
            try self_.prompts.append(testing.allocator, '\n');
            const answer = try allocator.dupe(u8, switch (field) {
                .username => "ada",
                .password => "secret",
            });
            return answer;
        }
    };
    var asked: Asked = .{};
    defer asked.prompts.deinit(gpa);
    {
        var session = try transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .prompt = .{ .context = &asked, .ask = Asked.ask } });
        session.close(io);
    }
    try testing.expectEqualStrings(theirs, asked.prompts.items);
}

test "ssh is handed the same arguments git hands it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const fake = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(fake);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    // A path with a quote in it, to be quoted.
    try source.exec(io, &.{ "init", "-q", "--bare", "it's" });
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);

    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    try here.exec(io, &.{ "config", "core.sshCommand", fake });
    var repo = try repo_mod.Repository.open(gpa, io, here.dir, .{});
    defer repo.deinit(io);

    const Case = struct { url: []const u8, variant: ?[]const u8 = null };
    const drive_slash = if (builtin.target.os.tag == .windows) "/" else "";
    const url_port = try gpa.print("ssh://ada@example.invalid:2222{s}{s}", .{ drive_slash, source_path });
    defer gpa.free(url_port);
    const url_scp = try gpa.print("example.invalid:{s}/it's", .{source_path});
    defer gpa.free(url_scp);
    const url_plain = try gpa.print("ssh://example.invalid:22{s}{s}", .{ drive_slash, source_path });
    defer gpa.free(url_plain);
    const url_ipv6 = try gpa.print("[::1]:{s}", .{source_path});
    defer gpa.free(url_ipv6);
    const url_user_ipv6 = try gpa.print("ada@[::1]:{s}", .{source_path});
    defer gpa.free(url_user_ipv6);
    const url_inside = try gpa.print("ssh://[ada@::1]:2222{s}{s}", .{ drive_slash, source_path });
    defer gpa.free(url_inside);
    const url_scp_port = try gpa.print("[example.invalid:2222]:{s}", .{source_path});
    defer gpa.free(url_scp_port);
    const url_encoded = try gpa.print("ssh://ada@example.invalid:2222{s}{s}/it%27s", .{ drive_slash, source_path });
    defer gpa.free(url_encoded);
    const cases = [_]Case{
        .{ .url = url_encoded },
        .{ .url = url_ipv6 },
        .{ .url = url_user_ipv6 },
        .{ .url = url_inside },
        .{ .url = url_scp_port },
        .{ .url = url_port },
        .{ .url = url_scp },
        .{ .url = url_plain, .variant = "plink" },
        .{ .url = url_plain, .variant = "ssh" },
    };
    for (cases) |case| {
        tools.dir.deleteFile(io, "fake-ssh.log") catch |err| if (err != error.FileNotFound) return err;
        var variant_buf: [64]u8 = undefined;
        const variant_setting = if (case.variant) |v| try std.mem.print(&variant_buf, "ssh.variant={s}", .{v}) else "ssh.variant=auto";
        here.report_failures = case.variant == null;
        // git's own arguments, from the same stand-in. A plink given a
        // repository it cannot reach fails after it has been started, which
        // is all that is compared.
        if (here.run(io, &.{ "-c", variant_setting, "ls-remote", case.url })) |listed| {
            gpa.free(listed);
        } else |err| if (case.variant == null) return err;
        const theirs = try tools.dir.readFileAlloc(io, "fake-ssh.log", gpa, .unlimited);
        defer gpa.free(theirs);
        try tools.dir.deleteFile(io, "fake-ssh.log");

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.print(gpa, "[core]\nsshCommand = {s}\n[ssh]\nvariant = {s}\n", .{ fake, case.variant orelse "auto" });
        var settings = try config_mod.Config.parseText(gpa, text.items, .local);
        defer settings.deinit();
        if (transport.Session.open(gpa, io, case.url, .upload_pack, .sha1, .{
            .programs = .{ .environ = &env },
            .config = &settings,
        })) |opened| {
            var session = opened;
            var refs = try session.listRefs(gpa, io, &.{});
            refs.deinit();
            session.close(io);
        } else |err| if (case.variant == null) return err;
        const ours = try tools.dir.readFileAlloc(io, "fake-ssh.log", gpa, .unlimited);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
}

test "a fetch over ssh leaves what git fetch leaves, in v2 and in v0" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const fake = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(fake);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    for ([_][]const u8{ "ssh", "simple" }) |variant| {
        var source = try testremote.historyRepo(gpa, io, 4);
        defer source.deinit();
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(source_path);
        const drive_slash = if (builtin.target.os.tag == .windows) "/" else "";
        const url = try gpa.print("ssh://example.invalid{s}{s}", .{ drive_slash, source_path });
        defer gpa.free(url);

        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| {
            try twin.exec(io, &.{ "remote", "add", "origin", url });
            try twin.exec(io, &.{ "config", "core.sshCommand", fake });
            try twin.exec(io, &.{ "config", "ssh.variant", variant });
        }
        try by_git.exec(io, &.{ "fetch", "origin" });
        var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
        defer repo.deinit(io);
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{
            .who = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 },
            .programs = .{ .environ = &env },
        });
        defer outcome.deinit();
        try testing.expect(outcome.pack != null);

        const format = "--format=%(refname) %(objectname) %(symref)";
        const theirs = try by_git.run(io, &.{ "for-each-ref", format });
        defer gpa.free(theirs);
        const ours = try by_relic.run(io, &.{ "for-each-ref", format });
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        const head_theirs = try by_git.readFile(io, ".git/FETCH_HEAD");
        defer gpa.free(head_theirs);
        const head_ours = try by_relic.readFile(io, ".git/FETCH_HEAD");
        defer gpa.free(head_ours);
        try testing.expectEqualStrings(head_theirs, head_ours);
        try by_relic.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

/// Fetch `origin` into `repo` with relic, with `env` as the programs'
/// environment.
fn relicFetch(gpa: Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map) !void {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = env } });
    outcome.deinit();
}

/// The TLS front, answering for the served `repo.git` as `server` does.
fn tlsFront(gpa: Allocator, io: Io, server: *testremote.HttpServer, options: testremote.TlsFront.Options) !*testremote.TlsFront {
    const front = try testremote.TlsFront.start(gpa, io, options);
    errdefer front.stop(io);
    try front.mirrorRefs(io, server, "repo.git");
    return front;
}

test "a server's own authority, in http.sslCAInfo or http.sslCAPath, is trusted as git trusts it, and nothing else is" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try tlsFront(gpa, io, server, .{});
    defer front.stop(io);
    const url = try gpa.print("https://127.0.0.1:{d}/repo.git", .{front.port});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    // Untrusted, both refuse the server.
    {
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        try by_git.exec(io, &.{ "remote", "add", "origin", url });
        by_git.report_failures = false;
        try testing.expectError(error.GitFailed, by_git.run(io, &.{ "fetch", "-q", "origin" }));
        try testing.expect(std.meta.isError(relicFetch(gpa, io, by_git.dir, &env)));
    }
    // Trusted through the configuration, scoped to the server, or through
    // git's environment variable.
    const scoped = try gpa.print("http.https://127.0.0.1:{d}.sslCAInfo", .{front.port});
    defer gpa.free(scoped);
    const Case = struct { key: ?[]const u8, value: []const u8, env: ?[]const u8 = null };
    for ([_]Case{
        .{ .key = scoped, .value = front.cert_path },
        .{ .key = "http.sslCAPath", .value = front.ca_dir },
        .{ .key = null, .value = front.cert_path, .env = "GIT_SSL_CAINFO" },
    }) |case| {
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        var case_env = try env.clone(gpa);
        defer case_env.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
            try r.exec(io, &.{ "remote", "add", "origin", url });
            try testremote.alreadyHas(gpa, io, root.dir, r);
            if (case.key) |key| try r.exec(io, &.{ "config", key, case.value });
        }
        if (case.env) |name| try case_env.put(name, case.value);
        const fetched = testremote.gitInputEnv(gpa, io, by_git.dir, &case_env, &.{ "fetch", "-q", "origin" }, "", true) catch |err| {
            std.debug.print("certificate case: {?s}\n", .{case.key});
            return err;
        };
        gpa.free(fetched);
        try relicFetch(gpa, io, by_relic.dir, &case_env);
        try expectSameFetch(gpa, io, &by_git, &by_relic);
    }
}

/// The first line of each request a proxy saw, without the ones that
/// only asked for credentials again, as curl's first try without them does.
fn firstLines(gpa: Allocator, log: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var previous: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, previous)) continue;
        previous = line;
        try out.print(gpa, "{s}\n", .{line});
    }
    return out.toOwnedSlice(gpa);
}

test "a proxy is gone through as git goes through it: the whole URL for http, CONNECT and TLS inside for https, not where no_proxy says" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try tlsFront(gpa, io, server, .{});
    defer front.stop(io);
    const proxy = try testremote.Proxy.start(gpa, io, null);
    defer proxy.stop();
    const proxy_url = try proxy.url(gpa);
    defer gpa.free(proxy_url);
    const plain = try server.url(gpa, "repo.git");
    defer gpa.free(plain);
    const secure = try gpa.print("https://127.0.0.1:{d}/repo.git", .{front.port});
    defer gpa.free(secure);

    const Case = struct {
        url: []const u8,
        env: []const [2][]const u8 = &.{},
        config: []const [2][]const u8 = &.{},
        through: bool,
    };
    for ([_]Case{
        .{ .url = plain, .env = &.{.{ "http_proxy", proxy_url }}, .through = true },
        .{ .url = plain, .config = &.{.{ "http.proxy", proxy_url }}, .through = true },
        .{ .url = secure, .env = &.{.{ "https_proxy", proxy_url }}, .through = true },
        .{ .url = secure, .config = &.{.{ "http.proxy", proxy_url }}, .through = true },
        // On Windows environment names are case-insensitive, so asking for
        // http_proxy finds the value set as HTTP_PROXY.
        .{ .url = plain, .env = &.{.{ "HTTP_PROXY", proxy_url }}, .through = builtin.target.os.tag == .windows },
        .{ .url = secure, .env = &.{ .{ "https_proxy", proxy_url }, .{ "no_proxy", "127.0.0.1" } }, .through = false },
        .{ .url = plain, .env = &.{.{ "http_proxy", proxy_url }}, .config = &.{.{ "http.proxy", "" }}, .through = false },
    }, 0..) |case, case_index| {
        var env = try testremote.environ(gpa);
        defer env.deinit();
        for (case.env) |pair| try env.put(pair[0], pair[1]);
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
            try r.exec(io, &.{ "remote", "add", "origin", case.url });
            try r.exec(io, &.{ "config", "http.sslCAInfo", front.cert_path });
            if (case.url.ptr == secure.ptr) try testremote.alreadyHas(gpa, io, root.dir, r);
            for (case.config) |pair| try r.exec(io, &.{ "config", pair[0], pair[1] });
        }
        const fetched = try testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", true);
        gpa.free(fetched);
        const theirs = try proxy.take(gpa);
        defer gpa.free(theirs);
        const their_connects = try proxy.takeConnects(gpa);
        defer gpa.free(their_connects);
        try relicFetch(gpa, io, by_relic.dir, &env);
        const ours = try proxy.take(gpa);
        defer gpa.free(ours);
        const our_connects = try proxy.takeConnects(gpa);
        defer gpa.free(our_connects);
        try expectSameFetch(gpa, io, &by_git, &by_relic);
        testing.expectEqual(case.through, theirs.len != 0) catch |err| {
            std.debug.print("proxy case {d}, git, {s}\n", .{ case_index, case.url });
            return err;
        };
        testing.expectEqual(case.through, ours.len != 0) catch |err| {
            std.debug.print("proxy case {d}, relic, {s}\n", .{ case_index, case.url });
            return err;
        };
        // Every request reaches the proxy in the same words: an http one
        // whole, an https one as its tunnel.
        const theirs_lines = try firstLines(gpa, theirs);
        defer gpa.free(theirs_lines);
        const ours_lines = try firstLines(gpa, ours);
        defer gpa.free(ours_lines);
        try testing.expectEqualStrings(theirs_lines, ours_lines);
        // A tunnel is asked for in curl's words, line for line.
        try testing.expectEqual(case.through and case.url.ptr == secure.ptr, their_connects.len != 0);
        try testing.expectEqualStrings(their_connects, our_connects);
        // And what goes through it is TLS from the first byte, git's and
        // relic's alike: no request in the clear inside the tunnel.
        const tunnels = try proxy.expectTlsInTunnels();
        try testing.expectEqual(case.through and case.url.ptr == secure.ptr, tunnels != 0);
    }
}

test "a proxy given to a fetch or a clone stands over the configuration's and no_proxy" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const proxy = try testremote.Proxy.start(gpa, io, null);
    defer proxy.stop();
    const proxy_url = try proxy.url(gpa);
    defer gpa.free(proxy_url);
    const plain = try server.url(gpa, "repo.git");
    defer gpa.free(plain);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.exec(io, &.{ "remote", "add", "origin", plain });
    try r.exec(io, &.{ "config", "http.proxy", proxy_url });
    var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    // none: the configured proxy is passed over
    {
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .proxy = .none });
        outcome.deinit();
        const seen = try proxy.take(gpa);
        defer gpa.free(seen);
        try testing.expectEqual(@as(usize, 0), seen.len);
    }
    // left to the configuration, it is gone through
    {
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } });
        outcome.deinit();
        const seen = try proxy.take(gpa);
        defer gpa.free(seen);
        try testing.expect(seen.len != 0);
    }
    // given, it is gone through where no_proxy and the configuration
    // would go direct
    try env.put("no_proxy", "127.0.0.1");
    try r.exec(io, &.{ "config", "http.proxy", "" });
    var again = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer again.deinit(io);
    {
        var outcome = try fetch_mod.fetch(gpa, io, &again, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .proxy = .{ .url = proxy_url } });
        outcome.deinit();
        const seen = try proxy.take(gpa);
        defer gpa.free(seen);
        try testing.expect(seen.len != 0);
    }
    var target = testing.tmpDir(.{ .iterate = true });
    defer target.cleanup();
    var cloned = try clone_mod.clone(gpa, io, plain, target.dir, .{ .who = test_who, .programs = .{ .environ = &env }, .proxy = .{ .url = proxy_url } });
    defer cloned.deinit(io);
    const seen = try proxy.take(gpa);
    defer gpa.free(seen);
    try testing.expect(seen.len != 0);
}

test "a proxy that asks is answered as curl answers for git: nothing first with anyauth, then Basic or Digest, MD5 or SHA-256" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try tlsFront(gpa, io, server, .{});
    defer front.stop(io);
    const plain = try server.url(gpa, "repo.git");
    defer gpa.free(plain);
    const secure = try gpa.print("https://127.0.0.1:{d}/repo.git", .{front.port});
    defer gpa.free(secure);

    const Case = struct { scheme: @FieldType(testremote.Proxy, "scheme"), method: ?[]const u8 = null, ok: bool = true };
    for ([_]Case{
        .{ .scheme = .basic },
        .{ .scheme = .basic, .method = "basic" },
        .{ .scheme = .digest_md5 },
        .{ .scheme = .digest_sha256 },
        .{ .scheme = .digest_md5, .method = "digest" },
        // Basic only, to a proxy that asks for Digest: refused, as git's is.
        .{ .scheme = .digest_md5, .method = "basic", .ok = false },
    }) |case| for ([_][]const u8{ plain, secure }) |url| {
        const proxy = try testremote.Proxy.startAsking(gpa, io, "ada:secret", case.scheme);
        defer proxy.stop();
        const proxy_url = try gpa.print("http://ada:secret@127.0.0.1:{d}", .{proxy.port});
        defer gpa.free(proxy_url);
        var env = try testremote.environ(gpa);
        defer env.deinit();
        try env.put("http_proxy", proxy_url);
        try env.put("https_proxy", proxy_url);
        // curl's Windows SSPI build cannot answer SHA-256 Digest. Git
        // returns CURLE_AUTH_ERROR after the first 407; relic still proves
        // that its own SHA-256 answer is accepted by this proxy.
        const git_ok = case.ok and !(builtin.target.os.tag == .windows and case.scheme == .digest_sha256);
        var logs: [2][]u8 = undefined;
        var results: [2]bool = undefined;
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }, 0..) |r, who| {
            try r.exec(io, &.{ "remote", "add", "origin", url });
            try r.exec(io, &.{ "config", "http.sslCAInfo", front.cert_path });
            if (url.ptr == secure.ptr) try testremote.alreadyHas(gpa, io, root.dir, r);
            if (case.method) |m| try r.exec(io, &.{ "config", "http.proxyAuthMethod", m });
            if (who == 0) {
                results[0] = if (testremote.gitInputEnv(gpa, io, r.dir, &env, &.{ "fetch", "-q", "origin" }, "", git_ok)) |out| blk: {
                    gpa.free(out);
                    break :blk true;
                } else |_| false;
            } else {
                results[1] = if (relicFetch(gpa, io, r.dir, &env)) true else |err| blk: {
                    try testing.expectEqual(error.ProxyAuthenticationFailed, err);
                    break :blk false;
                };
            }
            logs[who] = try proxy.takeAuth(gpa);
        }
        defer for (logs) |l| gpa.free(l);
        testing.expectEqual(git_ok, results[0]) catch |err| {
            std.debug.print("proxy auth git: {s} {?s} {s}\n{s}", .{ @tagName(case.scheme), case.method, url, logs[0] });
            return err;
        };
        testing.expectEqual(case.ok, results[1]) catch |err| {
            std.debug.print("proxy auth relic: {s} {?s} {s}\n", .{ @tagName(case.scheme), case.method, url });
            return err;
        };
        if (git_ok) try expectSameFetch(gpa, io, &by_git, &by_relic);
        // Every request the proxy saw, and how it was answered for, as it
        // was for git.
        if (case.ok and !git_ok) {
            const request = if (url.ptr == secure.ptr) "CONNECT" else "GET";
            var expected_buf: [32]u8 = undefined;
            const expected = try std.mem.print(&expected_buf, "{s} none refused\n", .{request});
            try testing.expectEqualStrings(expected, logs[0]);
            try testing.expect(std.mem.find(u8, logs[1], "digest taken\n") != null);
        } else {
            testing.expectEqualStrings(logs[0], logs[1]) catch |err| {
                std.debug.print("{s} {?s} {s}\n", .{ @tagName(case.scheme), case.method, url });
                return err;
            };
        }
    };
}

test "a proxy's credentials come from its URL, or its user's from the helpers, as git's do, and a refusal is named" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try tlsFront(gpa, io, server, .{});
    defer front.stop(io);
    const proxy = try testremote.Proxy.start(gpa, io, "ada:secret");
    defer proxy.stop();
    const plain = try server.url(gpa, "repo.git");
    defer gpa.free(plain);
    const secure = try gpa.print("https://127.0.0.1:{d}/repo.git", .{front.port});
    defer gpa.free(secure);

    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const Case = struct { url: []const u8, proxy_user: []const u8, helper_password: ?[]const u8 = null, ok: bool };
    for ([_]Case{
        .{ .url = plain, .proxy_user = "ada:secret", .ok = true },
        .{ .url = secure, .proxy_user = "ada:secret", .ok = true },
        .{ .url = plain, .proxy_user = "ada", .helper_password = "secret", .ok = true },
        .{ .url = secure, .proxy_user = "ada", .helper_password = "secret", .ok = true },
        .{ .url = plain, .proxy_user = "ada:wrong", .ok = false },
        .{ .url = secure, .proxy_user = "ada", .helper_password = "wrong", .ok = false },
    }) |case| {
        const proxy_url = try gpa.print("http://{s}@127.0.0.1:{d}", .{ case.proxy_user, proxy.port });
        defer gpa.free(proxy_url);
        var env = try testremote.environ(gpa);
        defer env.deinit();
        try env.put("http_proxy", proxy_url);
        try env.put("https_proxy", proxy_url);
        var logs: [2][]u8 = undefined;
        var logs_len: usize = 0;
        defer for (logs[0..logs_len]) |l| gpa.free(l);
        var results: [2]bool = undefined;
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }, 0..) |r, who| {
            try r.exec(io, &.{ "remote", "add", "origin", case.url });
            try r.exec(io, &.{ "config", "http.sslCAInfo", front.cert_path });
            if (case.url.ptr == secure.ptr) try testremote.alreadyHas(gpa, io, root.dir, r);
            if (case.helper_password) |password| {
                const helper = try helperScript(gpa, io, tools.dir, password);
                defer gpa.free(helper);
                try r.exec(io, &.{ "config", "credential.helper", helper });
            }
            tools.dir.deleteFile(io, "helper.log") catch |err| if (err != error.FileNotFound) return err;
            if (who == 0) {
                results[0] = if (testremote.gitInputEnv(gpa, io, r.dir, &env, &.{ "fetch", "-q", "origin" }, "", case.ok)) |out| blk: {
                    gpa.free(out);
                    break :blk true;
                } else |_| false;
            } else {
                results[1] = if (relicFetch(gpa, io, r.dir, &env)) true else |err| blk: {
                    try testing.expectEqual(error.ProxyAuthenticationFailed, err);
                    break :blk false;
                };
            }
            logs[logs_len] = tools.dir.readFileAlloc(io, "helper.log", gpa, .unlimited) catch try gpa.dupe(u8, "");
            logs_len += 1;
        }
        const seen = try proxy.take(gpa);
        gpa.free(seen);
        try testing.expectEqual(case.ok, results[0]);
        try testing.expectEqual(case.ok, results[1]);
        if (case.ok) try expectSameFetch(gpa, io, &by_git, &by_relic);
        // The helper was asked for the proxy's password as git asks, and
        // told to store or erase it as git tells it.
        try testing.expectEqualStrings(logs[0], logs[1]);
    }
}

test "an https server is fetched from unchecked when http.sslVerify says so, and the caller is told" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try tlsFront(gpa, io, server, .{});
    defer front.stop(io);
    const url = try gpa.print("https://127.0.0.1:{d}/repo.git", .{front.port});
    defer gpa.free(url);
    for ([_]bool{ false, true }) |through_env| {
        var env = try testremote.environ(gpa);
        defer env.deinit();
        if (through_env) try env.put("GIT_SSL_NO_VERIFY", "1");
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
            try r.exec(io, &.{ "remote", "add", "origin", url });
            try testremote.alreadyHas(gpa, io, root.dir, r);
            if (!through_env) try r.exec(io, &.{ "config", "http.sslVerify", "false" });
        }
        const fetched = try testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", true);
        gpa.free(fetched);
        var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
        defer repo.deinit(io);
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .warnings = &warnings });
        outcome.deinit();
        try expectSameFetch(gpa, io, &by_git, &by_relic);
        try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
        try testing.expectEqualStrings(if (through_env) "GIT_SSL_NO_VERIFY" else "http.sslverify", warnings.items.items[0].ssl_verify_disabled);
    }
}

test "an idle kept connection does not block another client" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .keep_alive = true, .redirect = true });
    var stopped = false;
    defer if (!stopped) server.stop();
    const first = try server.url(gpa, "moved/first");
    defer gpa.free(first);
    const second = try server.url(gpa, "moved/second");
    defer gpa.free(second);
    var idle: uplink.Client = .init(gpa, .{ .timeouts = .{ .activity = .fromSeconds(10) }, .redirects = .none });
    defer idle.deinit(io);
    {
        var response = try idle.send(io, .{ .url = first });
        defer response.deinit(io);
        try testing.expectEqual(std.http.Status.found, response.status);
        _ = try response.reader(io).discardRemaining();
    }
    // The first client's connection stays pooled while the second makes a
    // request. Closing it before this request would hide a serialized server.
    var active: uplink.Client = .init(gpa, .{ .timeouts = .{ .activity = .fromSeconds(10) }, .redirects = .none });
    defer active.deinit(io);
    {
        var response = try active.send(io, .{ .url = second });
        defer response.deinit(io);
        try testing.expectEqual(std.http.Status.found, response.status);
        _ = try response.reader(io).discardRemaining();
    }
    try testing.expectEqual(@as(u32, 1), idle.stats().idle);
    try testing.expectEqual(@as(u64, 1), idle.stats().connections_opened);
    try testing.expectEqual(@as(u64, 1), active.stats().connections_opened);
    // Shutdown must also release handlers waiting on pooled connections.
    server.stop();
    stopped = true;
}

test "requests share one connection and a large upload-pack request is gzipped, as git's are" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 3);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    for ([_]bool{ true, false }) |v2| {
        const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .keep_alive = true, .protocol_v2 = v2 });
        defer server.stop();
        const url = try server.url(gpa, "repo.git");
        defer gpa.free(url);
        var logs: [2][]u8 = undefined;
        var connections: [2]u32 = undefined;
        for (0..2) |who| {
            // A repository with history of its own, so the negotiation
            // offers enough to pass a kilobyte.
            var r = try testgit.Repo.init(gpa, io, &.{});
            defer r.deinit();
            try testremote.addCommits(gpa, io, &r, 100, 40);
            try r.exec(io, &.{ "remote", "add", "origin", url });
            const before = server.connectionCount();
            const log_before = try server.requests(gpa);
            defer gpa.free(log_before);
            if (who == 0) {
                const out = try testremote.gitInputEnv(gpa, io, r.dir, &env, &.{ "-c", if (v2) "protocol.version=2" else "protocol.version=0", "fetch", "-q", "origin" }, "", true);
                gpa.free(out);
            } else try relicFetchV(gpa, io, r.dir, &env, v2, "origin");
            const log_after = try server.requests(gpa);
            defer gpa.free(log_after);
            logs[who] = try gpa.dupe(u8, log_after[log_before.len..]);
            connections[who] = server.connectionCount() - before;
        }
        defer for (logs) |l| gpa.free(l);
        try testing.expectEqualStrings(logs[0], logs[1]);
        try testing.expect(std.mem.find(u8, logs[1], " gzip") != null);
        try testing.expectEqual(connections[0], connections[1]);
    }
}

fn relicFetchV(gpa: Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map, v2: bool, remote: []const u8) !void {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    try repo.editConfig(io, &.{.{ .name = "protocol.version", .value = if (v2) "2" else "0" }}, null);
    var outcome = try fetch_mod.fetch(gpa, io, &repo, remote, .{ .who = test_who, .programs = .{ .environ = env } });
    outcome.deinit();
}

test "the negotiation git's fetch-pack makes is made byte for byte, over a pipe and over HTTP, in v0 and v2" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 3);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const ssh_path = try testremote.capturingSsh(gpa, io, tools.dir);
    defer gpa.free(ssh_path);

    // One history of its own, copied to both sides so the haves are the
    // same commits in the same order.
    var local = try testgit.Repo.init(gpa, io, &.{});
    defer local.deinit();
    try testremote.addCommits(gpa, io, &local, 100, 50);
    const local_path = try testremote.absolutePath(gpa, io, local.dir);
    defer gpa.free(local_path);

    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const http_url = try server.url(gpa, "repo.git");
    defer gpa.free(http_url);
    const drive_slash = if (builtin.target.os.tag == .windows) "/" else "";
    const ssh_url = try gpa.print("ssh://example.invalid{s}{s}/repo.git", .{ drive_slash, root_path });
    defer gpa.free(ssh_url);

    for ([_][]const u8{ ssh_url, http_url }) |url| for ([_]bool{ false, true }) |v2| {
        var sent: [2][]u8 = undefined;
        var requests: [2][]u8 = undefined;
        for (0..2) |who| {
            var twin = testing.tmpDir(.{ .iterate = true });
            defer twin.cleanup();
            const twin_path = try testremote.absolutePath(gpa, io, twin.dir);
            defer gpa.free(twin_path);
            var env = try testremote.environ(gpa);
            defer env.deinit();
            try env.put("GIT_SSH_COMMAND", ssh_path);
            const cloned = try testremote.gitInputEnv(gpa, io, twin.dir, &env, &.{ "clone", "-q", local_path, "." }, "", true);
            gpa.free(cloned);
            const added = try testremote.gitInputEnv(gpa, io, twin.dir, &env, &.{ "remote", "add", "far", url }, "", true);
            gpa.free(added);
            tools.dir.deleteFile(io, "sent") catch |err| if (err != error.FileNotFound) return err;
            const before = try server.requests(gpa);
            defer gpa.free(before);
            if (who == 0) {
                const out = try testremote.gitInputEnv(gpa, io, twin.dir, &env, &.{ "-c", if (v2) "protocol.version=2" else "protocol.version=0", "fetch", "-q", "far" }, "", true);
                gpa.free(out);
            } else try relicFetchV(gpa, io, twin.dir, &env, v2, "far");
            sent[who] = tools.dir.readFileAlloc(io, "sent", gpa, .unlimited) catch try gpa.dupe(u8, "");
            const after = try server.requests(gpa);
            defer gpa.free(after);
            requests[who] = try gpa.dupe(u8, after[before.len..]);
        }
        defer for (sent) |b| gpa.free(b);
        defer for (requests) |b| gpa.free(b);
        // What was written to ssh, but git's agent and the capabilities
        // that name it.
        const theirs = try withoutAgent(gpa, sent[0]);
        defer gpa.free(theirs);
        const ours = try withoutAgent(gpa, sent[1]);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        try testing.expectEqualStrings(requests[0], requests[1]);
    };
}

/// `bytes`, pkt-lines one to a line, with the value of every `agent=`
/// blanked — each side names itself — and so the length of its line.
fn withoutAgent(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = bytes;
    while (rest.len >= 4) {
        const len = std.fmt.parseUnsigned(u16, rest[0..4], 16) catch break;
        if (len < 4) {
            try out.print(gpa, "{s}\n", .{rest[0..4]});
            rest = rest[4..];
            continue;
        }
        if (len > rest.len) break;
        const payload = rest[4..len];
        rest = rest[len..];
        if (std.mem.find(u8, payload, "agent=")) |at| {
            const value_end = std.mem.findAnyPos(u8, payload, at + "agent=".len, " \n") orelse payload.len;
            try out.print(gpa, "????{s}{s}", .{ payload[0 .. at + "agent=".len], payload[value_end..] });
        } else try out.print(gpa, "{s}{s}", .{ rest[0..0], payload });
        try out.print(gpa, "|{d}\n", .{if (std.mem.find(u8, payload, "agent=") == null) len else 0});
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

test "a fetch cancelled while its ssh never answers stops and reaps the ssh" {
    // the stand-in is a shell script; Windows has no /bin/sh to run it
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const Child = @import("dependencies.zig").conduit.Child;
    const Controlled = struct {
        const Self = @This();
        threadlocal var active: ?*Self = null;
        reading: Io.Event = .unset,
        never_answered: Io.Event = .unset,
        canceled: Io.Event = .unset,
        stdout: ?Io.File.Handle = null,
        child: ?Child = null,
        reaped: bool = false,
        read_canceled: bool = false,
        failure: ?anyerror = null,

        fn start(allocator: Allocator, task_io: Io, raw: *anyopaque, options: Child.SpawnOptions) Child.SpawnError!Child {
            const state: *Self = @ptrCast(@alignCast(raw)); // safe: the test's spawn hook carries its Self state
            const child = try Child.spawn(allocator, task_io, options);
            for (options.argv) |arg| if (std.mem.eql(u8, arg, "-G")) return child;
            state.child = child;
            state.stdout = child.stdoutFile().?.handle;
            return child;
        }

        fn terminate(task_io: Io, raw: *anyopaque, child: *Child) void {
            const state: *Self = @ptrCast(@alignCast(raw)); // safe: the test's spawn hook carries its Self state
            const tracked = state.child != null and state.child.?.processId() == child.processId();
            _ = child.killWait(task_io, .zero) catch return;
            if (tracked) state.reaped = true;
        }

        fn operate(context: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            if (active) |state| {
                if (operation == .file_read_streaming and state.stdout != null and operation.file_read_streaming.file.handle == state.stdout.?) {
                    // This is the fetch's advertisement read, after the real
                    // child was spawned. Hold it until cancellation, so the
                    // caller cannot race a completed or unstarted fetch.
                    state.reading.set(testing.io);
                    state.never_answered.wait(testing.io) catch |err| {
                        state.read_canceled = true;
                        return err;
                    };
                }
            }
            return testing.io.vtable.operate(context, operation);
        }

        fn fetch(allocator: Allocator, task_io: Io, repo: *repo_mod.Repository, env: *const std.process.Environ.Map, state: *Self) void {
            active = state;
            defer active = null;
            var outcome = fetch_mod.fetch(allocator, task_io, repo, "origin", .{
                .who = test_who,
                .programs = .{ .environ = env, .spawn = .{ .context = state, .start = start, .terminate = terminate } },
            }) catch |err| {
                state.failure = err;
                return;
            };
            outcome.deinit();
        }

        fn cancel(task: *Io.Future(void), state: *Self) void {
            task.cancel(testing.io);
            state.canceled.set(testing.io);
        }
    };
    var vtable = testing.io.vtable.*;
    vtable.operate = Controlled.operate;
    const io: Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ssh", .data = "#!/bin/sh\n[ \"$1\" = \"-G\" ] && exit 1\nexec sleep 30\n" });
    try tmp.dir.setFilePermissions(io, "ssh", .fromMode(0o755), .{});
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "repo");
    var repo_dir = try tmp.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);
    var made = try repo_mod.Repository.init(gpa, io, repo_dir, .{});
    made.deinit(io);
    const config = try gpa.print("[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tsshCommand = {s}/ssh\n[remote \"origin\"]\n\turl = ssh://example.invalid/r.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n", .{root});
    defer gpa.free(config);
    try repo_dir.writeFile(io, .{ .sub_path = ".git/config", .data = config });
    var repo = try repo_mod.Repository.open(gpa, io, repo_dir, .{ .discover = false });
    defer repo.deinit(io);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    var state: Controlled = .{};
    var task = try testing.io.concurrent(Controlled.fetch, .{ gpa, io, &repo, &env, &state });
    defer task.cancel(testing.io);
    const ssh_watchdog: Io.Duration = .fromSeconds(5);
    const watchdog: Io.Timeout = .{ .duration = .{ .raw = ssh_watchdog, .clock = .awake } };
    state.reading.waitTimeout(testing.io, watchdog) catch return error.SshReadinessWatchdogExpired;
    var cancel = try testing.io.concurrent(Controlled.cancel, .{ &task, &state });
    defer cancel.cancel(testing.io);
    state.canceled.waitTimeout(testing.io, watchdog) catch @panic("ssh cancellation watchdog expired");
    cancel.await(testing.io);
    try testing.expectEqual(error.Canceled, state.failure.?);
    try testing.expect(state.read_canceled);
    try testing.expect(state.reaped);
}

/// The kind of target each SOCKS scheme names `localhost` as: a name where
/// the proxy looks it up, an IPv4 address for SOCKS4, either family for
/// SOCKS5.
fn socksKind(scheme: []const u8) []const u8 {
    if (std.mem.eql(u8, scheme, "socks4a") or std.mem.eql(u8, scheme, "socks5h")) return " name localhost:";
    if (std.mem.eql(u8, scheme, "socks4")) return " ipv4 127.0.0.1:";
    return " ipv";
}

/// git's fetch and relic's from the TLS front through the SOCKS proxy as
/// `scheme`, into repositories that have every object already: TLS to the
/// origin from the tunnel's first byte, the target named as the scheme
/// names it, and the same refs fetched.
fn socksHttpsFetch(gpa: Allocator, io: Io, root: *testing.TmpDir, proxy: *testremote.SocksProxy, front: *testremote.TlsFront, scheme: []const u8) !void {
    errdefer std.debug.print("SOCKS transfer case: {s} over https\n", .{scheme});
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const proxy_url = try proxy.url(gpa, scheme, "ada:secret@");
    defer gpa.free(proxy_url);
    const url = try gpa.print("https://localhost:{d}/repo.git", .{front.port});
    defer gpa.free(url);
    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
        try r.exec(io, &.{ "remote", "add", "origin", url });
        try testremote.alreadyHas(gpa, io, root.dir, r);
        try r.exec(io, &.{ "config", "http.proxy", proxy_url });
        // What is trusted is proved elsewhere; this proves TLS on the wire.
        try r.exec(io, &.{ "config", "http.sslVerify", "false" });
    }
    const tunnels = proxy.tunnelCounts().tls;
    const fetched = try testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", true);
    gpa.free(fetched);
    const theirs = try proxy.take(gpa);
    defer gpa.free(theirs);
    try relicFetch(gpa, io, by_relic.dir, &env);
    const ours = try proxy.take(gpa);
    defer gpa.free(ours);
    try expectSameFetch(gpa, io, &by_git, &by_relic);
    try testing.expect(std.mem.find(u8, theirs, socksKind(scheme)) != null);
    try testing.expect(std.mem.find(u8, ours, socksKind(scheme)) != null);
    try testing.expectEqual(tunnels + 2, proxy.tunnelCounts().tls);
}

test "clone fetch and push cross each SOCKS tunnel as git crosses it, and a fetch TLS to the origin inside it" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    var bare = try root.dir.openDir(io, "repo.git", .{});
    defer bare.close(io);
    const enabled = try testremote.gitInput(gpa, io, bare, &.{ "config", "http.receivepack", "true" }, "");
    gpa.free(enabled);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try tlsFront(gpa, io, server, .{});
    defer front.stop(io);
    const proxy = try testremote.SocksProxy.start(gpa, io, .{ .credential = .{ .user = "ada", .password = "secret" } });
    defer proxy.stop();
    for ([_][]const u8{ "socks4", "socks4a", "socks5", "socks5h" }) |scheme| {
        try socksHttpsFetch(gpa, io, &root, proxy, front, scheme);
        {
            errdefer std.debug.print("SOCKS transfer case: {s} over http\n", .{scheme});
            var env = try testremote.environ(gpa);
            defer env.deinit();
            const proxy_url = try proxy.url(gpa, scheme, "ada:secret@");
            defer gpa.free(proxy_url);
            const url = try gpa.print("http://localhost:{d}/repo.git", .{server.port});
            defer gpa.free(url);
            // The same explicit -c spelling works with git's curl.
            const setting = try gpa.print("http.proxy={s}", .{proxy_url});
            defer gpa.free(setting);
            const config_text = try gpa.print("[http]\nproxy = {s}\n", .{proxy_url});
            defer gpa.free(config_text);
            var config = try config_mod.Config.parseText(gpa, config_text, .command);
            defer config.deinit();
            var git_work = testing.tmpDir(.{ .iterate = true });
            defer git_work.cleanup();
            const cloned = try testremote.gitInputEnv(gpa, io, git_work.dir, &env, &.{ "-c", setting, "clone", "-q", url, "clone" }, "", true);
            gpa.free(cloned);
            const theirs = try proxy.take(gpa);
            defer gpa.free(theirs);
            var ours = testing.tmpDir(.{ .iterate = true });
            defer ours.cleanup();
            var repo = try clone_mod.clone(gpa, io, url, ours.dir, .{ .who = test_who, .programs = .{ .environ = &env }, .config = &config });
            defer repo.deinit(io);
            const our_log = try proxy.take(gpa);
            defer gpa.free(our_log);
            try testing.expect(theirs.len != 0 and our_log.len != 0);
            const expected_kind = socksKind(scheme);
            try testing.expect(std.mem.find(u8, theirs, expected_kind) != null);
            try testing.expect(std.mem.find(u8, our_log, expected_kind) != null);
            var by_git = try git_work.dir.openDir(io, "clone", .{});
            defer by_git.close(io);
            try repo.editConfig(io, &.{ .{ .name = "http.proxy", .value = "http://127.0.0.1:9" }, .{ .name = "remote.origin.proxy", .value = proxy_url } }, null);
            var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } });
            defer fetched.deinit();
            const fetched_git = try testremote.gitInputEnv(gpa, io, by_git, &env, &.{ "-c", setting, "fetch", "-q", "origin" }, "", true);
            gpa.free(fetched_git);
            // Both clients push new objects, from identical commits.
            const commit_text = try gpa.print("{s} http\n", .{scheme});
            defer gpa.free(commit_text);
            for ([_]Io.Dir{ by_git, ours.dir }) |dir| {
                try dir.writeFile(io, .{ .sub_path = "socks.txt", .data = commit_text });
                const staged = try testremote.gitInput(gpa, io, dir, &.{ "add", "socks.txt" }, "");
                gpa.free(staged);
                const committed = try testremote.gitInput(gpa, io, dir, &.{ "commit", "-q", "-m", commit_text }, "");
                gpa.free(committed);
            }
            const git_ref = try gpa.print("refs/heads/socks-git-{s}", .{scheme});
            defer gpa.free(git_ref);
            const relic_ref = try gpa.print("refs/heads/socks-relic-{s}", .{scheme});
            defer gpa.free(relic_ref);
            const git_spec = try gpa.print("HEAD:{s}", .{git_ref});
            defer gpa.free(git_spec);
            const relic_spec = try gpa.print("HEAD:{s}", .{relic_ref});
            defer gpa.free(relic_spec);
            const pushed_git = try testremote.gitInputEnv(gpa, io, by_git, &env, &.{ "-c", setting, "push", "-q", "origin", git_spec }, "", true);
            gpa.free(pushed_git);
            var pushed = try push_mod.push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .refspecs = &.{relic_spec} });
            defer pushed.deinit();
            const git_refs = try testremote.gitInput(gpa, io, bare, &.{ "rev-parse", git_ref, relic_ref }, "");
            defer gpa.free(git_refs);
            var names = std.mem.tokenizeScalar(u8, git_refs, '\n');
            try testing.expectEqualStrings(names.next().?, names.next().?);
            const ours_head = try testremote.gitInput(gpa, io, ours.dir, &.{ "rev-parse", "HEAD" }, "");
            defer gpa.free(ours_head);
            const theirs_head = try testremote.gitInput(gpa, io, by_git, &.{ "rev-parse", "HEAD" }, "");
            defer gpa.free(theirs_head);
            try testing.expectEqualStrings(theirs_head, ours_head);
        }
    }
    const counts = proxy.tunnelCounts();
    try testing.expect(counts.tls > 0 and counts.plain > 0);
}

test "a SOCKS proxy's refusals reach a fetch by name: credentials refused, commands refused, hosts unreachable" {
    const gpa = testing.allocator;
    const io = testing.io;
    const url = "http://remote.invalid/repo.git";
    for ([_][]const u8{ "socks4a", "socks5h" }) |scheme| {
        const proxy = try testremote.SocksProxy.start(gpa, io, .{ .credential = .{ .user = "ada", .password = "secret" } });
        defer proxy.stop();
        for ([_][]const u8{ "wrong:secret@", "ada:wrong@", "" }) |userinfo| {
            // SOCKS4 authenticates the userid; its password is not sent.
            if (std.mem.eql(u8, scheme, "socks4a") and std.mem.eql(u8, userinfo, "ada:wrong@")) continue;
            const text = try proxy.url(gpa, scheme, userinfo);
            defer gpa.free(text);
            try testing.expectError(error.ProxyAuthenticationFailed, transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .proxy = .{ .url = text } }));
        }
    }
    // RFC 1928's reply codes, 1 to 8.
    const errors = [_]transport.Error{ error.ProxyRefused, error.ProxyRefused, error.ProxyHostUnreachable, error.ProxyHostUnreachable, error.ProxyRefused, error.ProxyHostUnreachable, error.ProxyRefused, error.ProxyAddressUnsupported };
    for (errors, 1..) |expected, code| {
        const proxy = try testremote.SocksProxy.start(gpa, io, .{ .reply_code = @intCast(code) });
        defer proxy.stop();
        const text = try proxy.url(gpa, "socks5h", "");
        defer gpa.free(text);
        try testing.expectError(expected, transport.Session.open(gpa, io, url, .upload_pack, .sha1, .{ .proxy = .{ .url = text } }));
    }
}

/// Whether git finds a log for `name` in `r`.
fn gitHasLog(io: Io, r: *testgit.Repo, name: []const u8) !bool {
    var captured = try r.capture(io, &.{ "reflog", "exists", name });
    defer captured.deinit(r.gpa);
    return captured.code == 0;
}

test "a fetch that prunes and a push that deletes leave no log of the gone remote-tracking ref, in files and reftable" {
    const gpa = testing.allocator;
    const io = testing.io;
    // A reftable repository is git 2.45's to make.
    const formats: []const []const []const u8 = if (try testgit.gitAtLeast(gpa, io, 2, 45))
        &.{ &.{}, &.{"--ref-format=reftable"} }
    else
        &.{&.{}};
    for (formats) |args| {
        var remote = try testgit.Repo.init(gpa, io, &.{"--bare"});
        defer remote.deinit();
        const remote_path = try testremote.absolutePath(gpa, io, remote.dir);
        defer gpa.free(remote_path);
        var work = try testgit.Repo.init(gpa, io, args);
        defer work.deinit();
        try work.writeFile(io, "f", "f\n");
        try work.exec(io, &.{ "add", "f" });
        try work.exec(io, &.{ "commit", "-q", "-m", "one" });
        try work.exec(io, &.{ "remote", "add", "origin", remote_path });
        try work.exec(io, &.{ "push", "-q", "origin", "main", "main:refs/heads/gone", "main:refs/heads/feature" });
        try work.exec(io, &.{ "fetch", "-q", "origin" });
        try testing.expect(try gitHasLog(io, &work, "refs/remotes/origin/gone"));
        try testing.expect(try gitHasLog(io, &work, "refs/remotes/origin/feature"));
        try remote.exec(io, &.{ "branch", "-D", "gone" });

        var repo = try repo_mod.Repository.open(gpa, io, work.dir, .{});
        defer repo.deinit(io);
        var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .prune = true });
        defer fetched.deinit();
        try testing.expectEqual(@as(usize, 1), fetched.pruned.len);
        try testing.expect(!try gitHasLog(io, &work, "refs/remotes/origin/gone"));

        var pushed = try push_mod.push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{":refs/heads/feature"} });
        defer pushed.deinit();
        try testing.expectEqual(push_mod.RefResult.Status.ok, pushed.refs[0].status);
        try testing.expect(!try gitHasLog(io, &work, "refs/remotes/origin/feature"));
        try testing.expect(try gitHasLog(io, &work, "refs/remotes/origin/main"));
    }
}
