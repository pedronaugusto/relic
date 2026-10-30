//! Transport tests that stand relic beside git: the same fetches, the same
//! ssh arguments, the same credential helpers, over a stand-in ssh and over
//! an HTTP server serving `git http-backend`, each started by the test on
//! this machine.
//!
//! They live apart from `ssh.zig` and `smart_http.zig` because they drive the
//! operations above those modules, which the modules themselves do not
//! import.

const warning = @import("../report.zig").warning;
const std = @import("std");
const suite = @import("../testing/helpers.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown");

const config_mod = @import("../config/config.zig");
const credential = @import("../wire.zig").credential;
const repo_mod = @import("../repo/repo.zig");
const fetch_mod = @import("fetch.zig");
const clone_mod = @import("clone.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const submodule = @import("../submodule/submodule.zig");
const transport = @import("transport.zig");
const uplink = @import("uplink");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const testlfs = @import("../testing/lfs.zig");
const object = @import("../object/object.zig");
const progress_mod = @import("../report.zig").progress;
const builtin = @import("builtin");
const push_mod = @import("push.zig");
const pull_mod = @import("pull.zig");
const program = @import("../process.zig").program;

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
    const theirs = try testgit.fetchRefs(by_git, io, format, false);
    defer gpa.free(theirs);
    const ours = try testgit.fetchRefs(by_relic, io, format, true);
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
        try testing.expect(outcome.objects > 0);
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

    var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{});
    defer session.deinit(io);
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
        var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config });
        session.deinit(io);
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
    try testing.expectError(error.HttpStatus, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &never }));
}

test "a cancel that lands in any read of a refused request comes back as Canceled, never as the refusal" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 1);
    // A refusal with a body to read: the forge's explanation, then the rest
    // read so the connection can carry the next request.
    // Long enough that its reads are its own, past the headers'.
    const text = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(text);
    @memset(text, 'x');
    text[text.len - 1] = '\n';
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" }, .refusal_text = text });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    const inputs: transport.Session.OpenInputs = .{ .service = .upload_pack, .kind = .sha1 };
    var reads: u32 = 0;
    {
        const faults = try shakedown.FaultIo.init(gpa, io, .{ .trace = .all });
        defer faults.deinit();
        if (transport.Session.open(gpa, faults.io(), url, inputs, .{})) |opened| {
            var session = opened;
            session.deinit(io);
            return error.TestUnexpectedResult;
        } else |err| try testing.expect(err != error.Canceled);
        for (faults.trace().records()) |record| {
            if (record.event.call == .net_read) reads += 1;
        }
    }
    try testing.expect(reads != 0);
    var n: u32 = 1;
    while (n <= reads) : (n += 1) {
        const plan = [_]shakedown.IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .net_read, .n = n } }, .fault = .cancel, .times = 1 }};
        const faults = try shakedown.FaultIo.init(gpa, io, .{ .plan = &plan });
        defer faults.deinit();
        if (transport.Session.open(gpa, faults.io(), url, inputs, .{})) |opened| {
            var session = opened;
            session.deinit(io);
            return error.TestUnexpectedResult;
        } else |err| testing.expectEqual(error.Canceled, err) catch |e| {
            std.debug.print("read {d} of {d} canceled: {t}\n", .{ n, reads, err });
            return e;
        };
    }
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
    try testing.expectError(error.CredentialValueUnsafe, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config }));
}

test "a transport the configuration or GIT_ALLOW_PROTOCOL refuses is not opened" {
    const gpa = testing.allocator;
    const io = testing.io;
    var config = try config_mod.Config.parseText(gpa, "[protocol \"http\"]\n\tallow = never\n", .local);
    defer config.deinit();
    try testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "http://127.0.0.1:1/repo.git", .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config }));
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_ALLOW_PROTOCOL", "https");
    try testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "/nonexistent/repo.git", .{ .service = .upload_pack, .kind = .sha1 }, .{ .programs = .{ .environ = &env } }));
    try testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "/nonexistent/repo.git", .{ .service = .upload_pack, .kind = .sha1 }, .{ .from_user = false }));
}

test "a malformed transfer.advertiseSID is refused, as git dies on it, where no session id was sent" {
    const gpa = testing.allocator;
    const io = testing.io;
    var served = try testgit.Repo.init(gpa, io, &.{"--bare"});
    defer served.deinit();
    const path = try testremote.absolutePath(gpa, io, served.dir);
    defer gpa.free(path);
    var config = try config_mod.Config.parseText(gpa, "[transfer]\n\tadvertiseSID = maybe\n", .local);
    defer config.deinit();
    try testing.expectError(error.NotABoolean, transport.Session.open(gpa, io, path, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config }));
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
    try testing.expectError(error.RepositoryNotFound, transport.Session.open(gpa, io, missing, .{ .service = .upload_pack, .kind = .sha1 }, .{}));

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
        try testing.expectError(expected, transport.Session.open(gpa, io, target, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config }));
    }
    // Over plain http git reads no TLS setting, and neither does relic.
    var plain = try config_mod.Config.parseText(gpa, "[http]\nsslVerify = false\n", .local);
    defer plain.deinit();
    var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &plain });
    session.deinit(io);
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
        var session = try transport.Session.open(gpa, io, with_userinfo, .{ .service = .upload_pack, .kind = .sha1 }, .{});
        session.deinit(io);
    }

    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    // Without a helper, a prompt, or the permission to run askpass, there
    // is nothing to ask.
    try testing.expectError(error.CredentialsUnavailable, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{}));

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
    try testing.expectError(error.CredentialsUnavailable, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .programs = .{ .environ = &env } }));
    {
        var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .programs = .{ .environ = &env }, .prompt = .{ .askpass = true } });
        session.deinit(io);
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
        fn ask(context: ?*anyopaque, field: credential.Field, prompt: []const u8, answer: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!bool {
            const self_: *Self = @ptrCast(@alignCast(context.?));
            try self_.prompts.appendSlice(testing.allocator, prompt);
            try self_.prompts.append(testing.allocator, '\n');
            try answer.writeAll(switch (field) {
                .username => "ada",
                .password => "secret",
            });
            return true;
        }
    };
    var asked: Asked = .{};
    defer asked.prompts.deinit(gpa);
    {
        var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .prompt = .{ .context = &asked, .ask = Asked.ask } });
        session.deinit(io);
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
        if (transport.Session.open(gpa, io, case.url, .{ .service = .upload_pack, .kind = .sha1 }, .{
            .programs = .{ .environ = &env },
            .config = &settings,
        })) |opened| {
            var session = opened;
            var refs = try session.listRefs(gpa, io, &.{});
            refs.deinit();
            session.deinit(io);
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
        try testing.expect(outcome.objects > 0);

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
/// What git says when `args` fails, as it must.
fn gitFailure(gpa: Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, &testgit.default_settings);
    try argv.appendSlice(gpa, args);
    var outcome = try program.run(gpa, io, .{ .environ = env }, .{ .argv = argv.items, .cwd = .{ .dir = dir } }, .{});
    gpa.free(outcome.stdout);
    if (outcome.succeeded()) {
        gpa.free(outcome.stderr);
        return error.TestUnexpectedResult;
    }
    return outcome.stderr;
}

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
        .{ .url = plain, .config = &.{.{ "http.proxy", proxy_url }}, .env = &.{ .{ "no_proxy", "" }, .{ "NO_PROXY", "127.0.0.1" } }, .through = builtin.target.os.tag != .windows },
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
        if (try testgit.gitAtLeast(gpa, io, 2, 46)) {
            try testing.expectEqualStrings(logs[0], logs[1]);
        } else {
            // Relic announces modern capabilities; the older reference
            // has none. All other helper fields and operations must match.
            const ordinary = try std.mem.replaceOwned(u8, gpa, logs[1], "== get\ncapability[]=authtype\ncapability[]=state\n", "== get\n");
            defer gpa.free(ordinary);
            try testing.expectEqualStrings(logs[0], ordinary);
        }
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

/// The lines of a Netscape cookie file that are cookies, a trailing `/`
/// of a path taken off as git's own test takes it (curl wrote one once),
/// sorted. The result is `arena`'s.
fn cookieLines(arena: Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or (line[0] == '#' and !std.mem.startsWith(u8, line, "#HttpOnly_"))) continue;
        try lines.append(arena, try std.mem.replaceOwned(u8, arena, line, "/\t", "\t"));
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return std.mem.join(arena, "\n", lines.items);
}

test "http.cookieFile's cookies are sent, its Set-Cookie lines among them, and http.saveCookies writes back the file curl writes for git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .set_cookie = "name=value" });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
        try r.exec(io, &.{ "remote", "add", "origin", url });
        // A header line with no domain goes to an address, as curl's table
        // keeps it; one for another domain goes nowhere here.
        try r.writeFile(io, "cookies.txt", "127.0.0.1\tFALSE\t/\tFALSE\t0\tothername\tothervalue\nSet-Cookie: plain=1\nSet-Cookie: scoped=2; Domain=example.com\n");
        try r.exec(io, &.{ "config", "http.cookieFile", "cookies.txt" });
        try r.exec(io, &.{ "config", "http.saveCookies", "true" });
    }
    const fetched = try testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", true);
    gpa.free(fetched);
    const by_git_cookies = try server.cookiesSeen(gpa);
    defer gpa.free(by_git_cookies);
    var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
    defer repo.deinit(io);
    var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } });
    outcome.deinit();
    try expectSameFetch(gpa, io, &by_git, &by_relic);
    const seen = try server.cookiesSeen(gpa);
    defer gpa.free(seen);
    // relic's requests carried the cookies git's did.
    try testing.expectEqualStrings(by_git_cookies, seen[by_git_cookies.len..]);
    try testing.expect(std.mem.find(u8, seen, "othername=othervalue") != null);
    try testing.expect(std.mem.find(u8, seen, "plain=1") != null);
    try testing.expect(std.mem.find(u8, seen, "scoped=2") == null);
    const git_file = try by_git.readFile(io, "cookies.txt");
    defer gpa.free(git_file);
    const relic_file = try by_relic.readFile(io, "cookies.txt");
    defer gpa.free(relic_file);
    try testing.expectEqualStrings(try cookieLines(arena, git_file), try cookieLines(arena, relic_file));
}

test "a 429 is answered as git answers it: http.maxRetries requests in all, Retry-After or http.retryAfter, neither past http.maxRetryTime" {
    const gpa = testing.allocator;
    const io = testing.io;
    const Case = struct {
        times: u32,
        header: ?[]const u8 = null,
        max_retries: []const u8,
        retry_after: ?[]const u8 = null,
        max_retry_time: ?[]const u8 = null,
        /// null: fetched; else what git's error says, and relic's error.
        fails: ?struct { []const u8, anyerror } = null,
        waited: ?u64 = null,
    };
    const cases = [_]Case{
        .{ .times = 2, .max_retries = "3" },
        .{ .times = 1, .header = "1", .max_retries = "2", .waited = 1 },
        .{ .times = 1, .max_retries = "0", .fails = .{ "429", error.HttpStatus } },
        .{ .times = 3, .header = "1", .max_retries = "1", .fails = .{ "please try again in 1 seconds", error.RateLimited } },
        .{ .times = 3, .max_retries = "2", .fails = .{ "please try again later", error.RateLimited } },
        .{ .times = 1, .header = "100", .max_retries = "3", .max_retry_time = "3", .fails = .{ "greater than http.maxRetryTime (100 > 3 seconds)", error.RateLimited } },
        .{ .times = 1, .max_retries = "3", .retry_after = "100", .max_retry_time = "5", .fails = .{ "configured http.retryAfter exceeds http.maxRetryTime (100 > 5 seconds)", error.RateLimited } },
    };
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    for (cases) |case| {
        var env = try testremote.environ(gpa);
        defer env.deinit();
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }, 0..) |r, i| {
            const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .rate_limit = .{ .times = case.times, .retry_after = case.header } });
            defer server.stop();
            const url = try server.url(gpa, "repo.git");
            defer gpa.free(url);
            try r.exec(io, &.{ "config", "http.maxRetries", case.max_retries });
            if (case.retry_after) |v| try r.exec(io, &.{ "config", "http.retryAfter", v });
            if (case.max_retry_time) |v| try r.exec(io, &.{ "config", "http.maxRetryTime", v });
            if (i == 0) {
                var outcome = try program.run(gpa, io, .{ .environ = &env }, .{
                    .argv = &[_][]const u8{"git"} ++ testgit.default_settings ++ [_][]const u8{ "ls-remote", url },
                    .cwd = .{ .dir = r.dir },
                    .stderr = .capture,
                }, .{});
                defer outcome.deinit(gpa);
                if (case.fails) |f| {
                    try testing.expect(!outcome.succeeded());
                    try testing.expect(std.mem.find(u8, outcome.stderr, f[0]) != null);
                } else try testing.expect(outcome.succeeded());
                continue;
            }
            var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
            defer repo.deinit(io);
            var warnings: warning.Warnings = .init(gpa);
            defer warnings.deinit();
            const opened = transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = repo.configuration(), .warnings = &warnings });
            if (case.fails) |f| {
                try testing.expectError(f[1], opened);
                continue;
            }
            var session = try opened;
            session.deinit(io);
            if (case.waited) |seconds| {
                try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
                try testing.expectEqual(seconds, warnings.items.items[0].rate_limited.raw());
            } else try testing.expectEqual(@as(usize, 0), warnings.items.items.len);
            try testing.expectEqual(case.times, server.rate_limited);
        }
    }
}

test "a transfer slower than http.lowSpeedLimit for http.lowSpeedTime is given up on, as git gives it up" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .stall = .fromSeconds(4) });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_HTTP_LOW_SPEED_LIMIT", "1000");
    try env.put("GIT_HTTP_LOW_SPEED_TIME", "1");
    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| try r.exec(io, &.{ "remote", "add", "origin", url });
    var outcome = try program.run(gpa, io, .{ .environ = &env }, .{
        .argv = &[_][]const u8{"git"} ++ testgit.default_settings ++ [_][]const u8{ "fetch", "-q", "origin" },
        .cwd = .{ .dir = by_git.dir },
        .stderr = .capture,
    }, .{});
    defer outcome.deinit(gpa);
    try testing.expect(!outcome.succeeded());
    try testing.expect(std.ascii.findIgnoreCase(outcome.stderr, "too slow") != null);
    var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
    defer repo.deinit(io);
    try testing.expectError(error.ConnectionFailed, fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } }));
}

test "http.version and http.sslVersion as git reads them: an unknown value warned of, SSL 2 and 3 refused, a pinned key nothing can match refused before a connection" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    {
        var config = try config_mod.Config.parseText(gpa, "[http]\n\tversion = HTTP/3\n\tsslVersion = tlsv1.3\n", .local);
        defer config.deinit();
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        // On http, the TLS version is not read.
        var session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config, .warnings = &warnings });
        session.deinit(io);
        try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
        try testing.expectEqualStrings("unknown value given to http.version: 'HTTP/3'", try warnings.items.items[0].message(warnings.arena.allocator()));
    }
    const refused = [_]struct { []const u8, anyerror }{
        .{ "[http]\n\tsslVersion = sslv3\n", error.SslVersionUnsupported },
        // Nothing that can match fails before a connection.
        .{ "[http]\n\tpinnedPubkey = sha256//AAAA\n", error.PinnedPubkeyMismatch },
    };
    for (refused) |case| {
        var config = try config_mod.Config.parseText(gpa, case[0], .local);
        defer config.deinit();
        try testing.expectError(case[1], transport.Session.open(gpa, io, "https://127.0.0.1:1/repo.git", .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config }));
    }
    var config = try config_mod.Config.parseText(gpa, "[http]\n\tsslVersion = tlsv1.5\n", .local);
    defer config.deinit();
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    try testing.expectError(error.ConnectionFailed, transport.Session.open(gpa, io, "https://127.0.0.1:1/repo.git", .{ .service = .upload_pack, .kind = .sha1 }, .{ .config = &config, .warnings = &warnings }));
    try testing.expectEqualStrings("unsupported ssl version tlsv1.5: using default", try warnings.items.items[0].message(warnings.arena.allocator()));
}

test "http.sslVersion=tlsv1.3 and http.pinnedPubkey hold the server as curl holds it for git: the lowest version spoken, the keys its certificate may hold" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const old = try tlsFront(gpa, io, server, .{ .version = "-tls1_2" });
    defer old.stop(io);
    const front = try tlsFront(gpa, io, server, .{ .public_key = true });
    defer front.stop(io);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const keys = std.Io.Dir.path.dirname(front.cert_path).?;
    const pem = try std.Io.Dir.path.join(arena, &.{ keys, "pub.pem" });
    const der = try std.Io.Dir.path.join(arena, &.{ keys, "pub.der" });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try Io.Dir.cwd().readFileAlloc(io, der, arena, .limited(1 << 16)), &hash, .{});
    var spelled: [44]u8 = undefined;
    const right = try arena.print("sha256//{s}", .{std.base64.standard.Encoder.encode(&spelled, &hash)});
    const wrong = "sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    const Case = struct {
        front: *testremote.TlsFront,
        key: []const u8,
        value: []const u8,
        fetched: bool,
        // macOS's libcurl has no TLS 1.3 to be held to, and git fails there.
        git: bool = true,
        // `http.sslVerify=false`: the pins are checked alone.
        unverified: bool = false,
        refused: anyerror = error.PinnedPubkeyMismatch,
        // An outcome curl 8.18 changed, splitting the list at every `;`
        // (9f979ea683): a git built with an older curl has the other one.
        split: bool = false,
    };
    const split_at_each = try testgit.curlAtLeast(gpa, io, 8, 18);
    for ([_]Case{
        .{ .front = old, .key = "http.sslVersion", .value = "tlsv1.3", .fetched = false, .refused = error.TlsFailed },
        .{ .front = old, .key = "http.sslVersion", .value = "tlsv1.2", .fetched = true },
        .{ .front = front, .key = "http.sslVersion", .value = "tlsv1.3", .fetched = true, .git = builtin.os.tag != .macos },
        .{ .front = front, .key = "http.pinnedPubkey", .value = right, .fetched = true },
        .{ .front = front, .key = "http.pinnedPubkey", .value = try arena.print("{s};{s}", .{ wrong, right }), .fetched = true },
        .{ .front = front, .key = "http.pinnedPubkey", .value = wrong, .fetched = false },
        // Each `;` ends an entry, and one that is no hash ends the list.
        .{ .front = front, .key = "http.pinnedPubkey", .value = try arena.print("{s};x", .{right}), .fetched = true, .split = true },
        .{ .front = front, .key = "http.pinnedPubkey", .value = try arena.print("{s};x;{s}", .{ wrong, right }), .fetched = false, .split = true },
        .{ .front = front, .key = "http.pinnedPubkey", .value = pem, .fetched = true },
        .{ .front = front, .key = "http.pinnedPubkey", .value = der, .fetched = true },
        // A certificate holds the key but is not one.
        .{ .front = front, .key = "http.pinnedPubkey", .value = front.cert_path, .fetched = false },
        .{ .front = front, .key = "http.pinnedPubkey", .value = try std.Io.Dir.path.join(arena, &.{ keys, "missing" }), .fetched = false },
        // With nothing else checked the leaf's key is held to the pins, as
        // curl holds it under `CURLOPT_SSL_VERIFYPEER` off.
        .{ .front = front, .key = "http.pinnedPubkey", .value = right, .fetched = true, .unverified = true },
        .{ .front = front, .key = "http.pinnedPubkey", .value = wrong, .fetched = false, .unverified = true },
    }) |case| {
        errdefer std.debug.print("case: {s}={s}\n", .{ case.key, case.value });
        const url = try arena.print("https://127.0.0.1:{d}/repo.git", .{case.front.port});
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
            try r.exec(io, &.{ "remote", "add", "origin", url });
            try testremote.alreadyHas(gpa, io, root.dir, r);
            if (case.unverified) try r.exec(io, &.{ "config", "http.sslVerify", "false" }) else try r.exec(io, &.{ "config", "http.sslCAInfo", case.front.cert_path });
            try r.exec(io, &.{ "config", case.key, case.value });
        }
        if (case.fetched) try relicFetch(gpa, io, by_relic.dir, &env) else try testing.expectError(case.refused, relicFetch(gpa, io, by_relic.dir, &env));
        if (!case.git) continue;
        const git_fetched = if (case.split and !split_at_each) !case.fetched else case.fetched;
        if (!git_fetched) {
            const said = try gitFailure(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" });
            defer gpa.free(said);
            // curl's words for a key no pin names, which relic's error is.
            if (case.refused == error.PinnedPubkeyMismatch) try testing.expect(std.mem.find(u8, said, "public key does not match pinned public key") != null);
            continue;
        }
        gpa.free(try testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", true));
        if (case.fetched) try expectSameFetch(gpa, io, &by_git, &by_relic);
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
    var idle: uplink.Client = .init(gpa, .{ .timeouts = .{ .activity = .literal("10s") }, .redirects = .none });
    defer idle.deinit(io);
    {
        var response = try idle.send(io, .{ .url = first });
        defer response.deinit(io);
        try testing.expectEqual(std.http.Status.found, response.status);
        _ = try response.reader(io).discardRemaining();
    }
    // The first client's connection stays pooled while the second makes a
    // request. Closing it before this request would hide a serialized server.
    var active: uplink.Client = .init(gpa, .{ .timeouts = .{ .activity = .literal("10s") }, .redirects = .none });
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
    try repo.editConfig(io, &.{.{ .name = "protocol.version", .value = if (v2) "2" else "0" }}, .{});
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
    const gpa = testing.allocator;
    const Child = @import("../process.zig").program.Child;
    const Controlled = struct {
        const Self = @This();
        /// An `Io` that holds the fetch's read of the ssh's advertisement.
        const Hold = shakedown.Layer(struct { controlled: *Self }, .{ .operate = operate });
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
            _ = child.killWait(task_io, .fromRaw(0)) catch return;
            if (tracked) state.reaped = true;
        }

        fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            const l = Hold.of(userdata);
            const state = l.state.controlled;
            if (operation == .file_read_streaming and state.stdout != null and operation.file_read_streaming.file.handle == state.stdout.?) {
                // This is the fetch's advertisement read, after the real
                // child was spawned. Hold it until cancellation, so the
                // caller cannot race a completed or unstarted fetch.
                state.reading.set(l.base);
                state.never_answered.wait(l.base) catch |err| {
                    state.read_canceled = true;
                    return err;
                };
            }
            return l.base.vtable.operate(l.base.userdata, operation);
        }

        fn fetch(allocator: Allocator, task_io: Io, repo: *repo_mod.Repository, env: *const std.process.Environ.Map, state: *Self) void {
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
    var state: Controlled = .{};
    var hold: Controlled.Hold = .init(testing.io, .{ .controlled = &state });
    const io = hold.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ssh = try testremote.fakeSsh(gpa, io, tmp.dir);
    defer gpa.free(ssh);
    const sidecar = try gpa.print("{s}.fixture", .{ssh});
    defer gpa.free(sidecar);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sidecar, .data = "hang\n" });
    try tmp.dir.createDirPath(io, "repo");
    var repo_dir = try tmp.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);
    var made = try repo_mod.Repository.create(gpa, io, repo_dir, .{ .default_branch = "main" });
    made.deinit(io);
    const config = try gpa.print("[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tsshCommand = {s}\n[remote \"origin\"]\n\turl = ssh://example.invalid/r.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n", .{ssh});
    defer gpa.free(config);
    try repo_dir.writeFile(io, .{ .sub_path = ".git/config", .data = config });
    var repo = try repo_mod.Repository.open(gpa, io, repo_dir, .{ .discover = false });
    defer repo.deinit(io);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

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
            try repo.editConfig(io, &.{ .{ .name = "http.proxy", .value = "http://127.0.0.1:9" }, .{ .name = "remote.origin.proxy", .value = proxy_url } }, .{});
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
            try testing.expectError(error.ProxyAuthenticationFailed, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .proxy = .{ .url = text } }));
        }
    }
    // RFC 1928's reply codes, 1 to 8.
    const errors = [_]transport.Error{ error.ProxyRefused, error.ProxyRefused, error.ProxyHostUnreachable, error.ProxyHostUnreachable, error.ProxyRefused, error.ProxyHostUnreachable, error.ProxyRefused, error.ProxyAddressUnsupported };
    for (errors, 1..) |expected, code| {
        const proxy = try testremote.SocksProxy.start(gpa, io, .{ .reply_code = @intCast(code) });
        defer proxy.stop();
        const text = try proxy.url(gpa, "socks5h", "");
        defer gpa.free(text);
        try testing.expectError(expected, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{ .proxy = .{ .url = text } }));
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

test "a remote's keywords come in colour as git push shows them, under color.remote and color.remote.<keyword>" {
    const gpa = testing.allocator;
    const io = testing.io;
    const side_band = @import("../wire.zig").side_band;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    var bare = try root.dir.openDir(io, "repo.git", .{});
    defer bare.close(io);
    const enabled = try testremote.gitInput(gpa, io, bare, &.{ "config", "http.receivepack", "true" }, "");
    gpa.free(enabled);
    // what git's t5409 sends, and the cases around a keyword's edges
    try testgit.fixtureHook(gpa, io, bare, "hooks/pre-receive", "text", "error: error\nERROR: also highlighted.\nhint: hint\nhinting: not highlighted\nsuccess: success\nwarning: warning\nprefixerror: error\n  error: leading space\nerror\nerrorx\n\twarning\ttab\nHint, Success and\x1b[31m colour\nwarning:\rhint:\n");
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    var client = try testgit.Repo.init(gpa, io, &.{});
    defer client.deinit();
    try client.exec(io, &.{ "remote", "add", "origin", url });
    try client.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "pushed" });
    var repo = try repo_mod.Repository.open(gpa, io, client.dir, .{});
    defer repo.deinit(io);

    const Heard = struct {
        text: std.ArrayList(u8) = .empty,
        fn report(context: ?*anyopaque, event: progress_mod.Event) void {
            const self_: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .remote => |t| self_.text.appendSlice(testing.allocator, t) catch @panic("out of memory"),
                else => {},
            }
        }
    };
    for ([_][]const []const u8{
        &.{ "-c", "color.remote=always" },
        &.{ "-c", "color.ui=always", "-c", "color.remote.hint=bold blue", "-c", "color.remote.error=nonsense", "-c", "color.remote.success=normal" },
        &.{ "-c", "color.remote=never", "-c", "color.ui=always" },
    }, 0..) |settings, i| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, settings);
        const git_ref = try gpa.print("HEAD:refs/heads/git-{d}", .{i});
        defer gpa.free(git_ref);
        try args.appendSlice(gpa, &.{ "push", "origin", git_ref });
        var pushed_git = try client.capture(io, args.items);
        defer pushed_git.deinit(gpa);
        // `remote: ` and the eight spaces git clears a line with where the
        // output is not a terminal
        var theirs: std.ArrayList(u8) = .empty;
        defer theirs.deinit(gpa);
        var lines = std.mem.splitScalar(u8, pushed_git.stderr, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "remote: ")) continue;
            var pieces = std.mem.splitScalar(u8, line["remote: ".len..], '\r');
            var first = true;
            while (pieces.next()) |piece| {
                if (!first) try theirs.append(gpa, '\r');
                first = false;
                const rest = if (std.mem.startsWith(u8, piece, "remote: ")) piece["remote: ".len..] else piece;
                try theirs.appendSlice(gpa, if (std.mem.endsWith(u8, rest, "        ")) rest[0 .. rest.len - 8] else rest);
            }
            try theirs.append(gpa, '\n');
        }

        var config_text: std.ArrayList(u8) = .empty;
        defer config_text.deinit(gpa);
        var at: usize = 1;
        while (at < settings.len) : (at += 2) {
            const s = settings[at];
            const eq = std.mem.findScalar(u8, s, '=').?;
            const dot = std.mem.findScalarLast(u8, s[0..eq], '.').?;
            const first_dot = std.mem.findScalar(u8, s, '.').?;
            if (dot == first_dot) {
                try config_text.print(gpa, "[{s}]\n\t{s} = {s}\n", .{ s[0..dot], s[dot + 1 .. eq], s[eq + 1 ..] });
            } else try config_text.print(gpa, "[{s} \"{s}\"]\n\t{s} = {s}\n", .{ s[0..first_dot], s[first_dot + 1 .. dot], s[dot + 1 .. eq], s[eq + 1 ..] });
        }
        var config = try config_mod.Config.parseText(gpa, config_text.items, .command);
        defer config.deinit();
        const colors = try side_band.RemoteColors.configured(&config, .{});
        var heard: Heard = .{};
        defer heard.text.deinit(testing.allocator);
        const relic_ref = try gpa.print("HEAD:refs/heads/relic-{d}", .{i});
        defer gpa.free(relic_ref);
        var pushed = try push_mod.push(gpa, io, &repo, "origin", .{
            .who = test_who,
            .programs = .{ .environ = &env },
            .refspecs = &.{relic_ref},
            .progress = .{ .context = &heard, .report = Heard.report, .remote_keywords = if (colors) |*c| c.keywords() else null },
        });
        defer pushed.deinit();
        try testing.expectEqualStrings(theirs.items, heard.text.items);
    }
}

test "a fetch stores fewer objects than fetch.unpackLimit loose and the rest in a pack, as git's fetch-pack does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    // Five commits: fifteen objects.
    var source = try testremote.historyRepo(gpa, io, 5);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const url = try gpa.print("file://{s}", .{source_path});
    defer gpa.free(url);
    const Case = struct { settings: []const [2][]const u8 = &.{}, keep: bool = false };
    const cases = [_]Case{
        .{},
        .{ .settings = &.{.{ "fetch.unpackLimit", "10" }} },
        .{ .settings = &.{.{ "fetch.unpackLimit", "20" }} },
        .{ .settings = &.{.{ "transfer.unpackLimit", "10" }} },
        .{ .settings = &.{ .{ "transfer.unpackLimit", "10" }, .{ "fetch.unpackLimit", "20" } } },
        .{ .settings = &.{.{ "fetch.unpackLimit", "0" }} },
        .{ .keep = true },
    };
    for (cases) |case| {
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| {
            try twin.exec(io, &.{ "remote", "add", "origin", url });
            for (case.settings) |kv| try twin.exec(io, &.{ "config", kv[0], kv[1] });
        }
        if (case.keep) try by_git.exec(io, &.{ "fetch", "--keep", "origin" }) else try by_git.exec(io, &.{ "fetch", "origin" });
        {
            var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
            defer repo.deinit(io);
            var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .keep = case.keep });
            defer outcome.deinit();
        }
        var stored: [2][]u8 = undefined;
        for ([_]*testgit.Repo{ &by_git, &by_relic }, 0..) |twin, i| {
            const counted = try twin.run(io, &.{ "count-objects", "-v" });
            defer gpa.free(counted);
            var kept: std.ArrayList(u8) = .empty;
            var lines = std.mem.tokenizeScalar(u8, counted, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "count:") or std.mem.startsWith(u8, line, "in-pack:") or std.mem.startsWith(u8, line, "packs:")) try kept.print(gpa, "{s}\n", .{line});
            }
            stored[i] = try kept.toOwnedSlice(gpa);
        }
        defer for (stored) |text| gpa.free(text);
        testing.expectEqualStrings(stored[0], stored[1]) catch |err| {
            std.debug.print("{any} keep={}\n", .{ case.settings, case.keep });
            return err;
        };
        try expectSameFetch(gpa, io, &by_git, &by_relic);
    }
}

/// The request lines git's upload-pack received, as its packet trace
/// shows them, less the ones that name a program or a session: what the
/// client chose to send, in its order.
fn serverHeard(gpa: Allocator, io: Io, trace_path: []const u8) ![]u8 {
    const traced = Io.Dir.cwd().readFileAlloc(io, trace_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return gpa.dupe(u8, ""),
        else => |e| return e,
    };
    defer gpa.free(traced);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, traced, '\n');
    while (lines.next()) |line| {
        const at = std.mem.find(u8, line, "upload-pack< ") orelse continue;
        const said = line[at + "upload-pack< ".len ..];
        if (std.mem.startsWith(u8, said, "agent=") or std.mem.startsWith(u8, said, "session-id=")) continue;
        if (!std.mem.startsWith(u8, said, "command=") and !std.mem.startsWith(u8, said, "server-option=") and !std.mem.startsWith(u8, said, "object-format=") and !std.mem.eql(u8, said, "0001")) continue;
        try out.print(gpa, "{s}\n", .{said});
    }
    return out.toOwnedSlice(gpa);
}

test "server options go with each v2 request as git sends them, from the remote's settings or the caller's, and a v0 server is refused them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const fake = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(fake);
    const tools_path = try testremote.absolutePath(gpa, io, tools.dir);
    defer gpa.free(tools_path);
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const url = try gpa.print("example.invalid:{s}", .{source_path});
    defer gpa.free(url);

    const Case = struct { settings: []const [2][]const u8 = &.{}, given: ?[]const []const u8 = null };
    const cases = [_]Case{
        .{ .settings = &.{ .{ "remote.origin.serverOption", "first" }, .{ "remote.origin.serverOption", "second" } } },
        .{ .settings = &.{ .{ "remote.origin.serverOption", "gone" }, .{ "remote.origin.serverOption", "" }, .{ "remote.origin.serverOption", "kept" } } },
        .{ .settings = &.{.{ "remote.origin.serverOption", "configured" }}, .given = &.{ "given=1", "given two" } },
    };
    for (cases, 0..) |case, n| {
        var heard: [2][]u8 = undefined;
        for (0..2) |i| {
            var twin = try testgit.Repo.init(gpa, io, &.{});
            defer twin.deinit();
            try twin.exec(io, &.{ "remote", "add", "origin", url });
            try twin.exec(io, &.{ "config", "core.sshCommand", fake });
            for (case.settings) |kv| try twin.exec(io, &.{ "config", "--add", kv[0], kv[1] });
            const trace = try gpa.print("{s}/trace-{d}-{d}", .{ tools_path, n, i });
            defer gpa.free(trace);
            var env = try testremote.environ(gpa);
            defer env.deinit();
            try env.put("GIT_TRACE_PACKET", trace);
            if (i == 0) {
                var args: std.ArrayList([]const u8) = .empty;
                defer args.deinit(gpa);
                try args.appendSlice(gpa, &.{ "-c", "protocol.version=2", "fetch", "-q" });
                if (case.given) |given| for (given) |option| try args.appendSlice(gpa, &.{ "-o", option });
                try args.append(gpa, "origin");
                const out = try testremote.gitInputEnv(gpa, io, twin.dir, &env, args.items, "", true);
                gpa.free(out);
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, twin.dir, .{});
                defer repo.deinit(io);
                var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .server_options = case.given });
                defer outcome.deinit();
            }
            heard[i] = try serverHeard(gpa, io, trace);
        }
        defer for (heard) |text| gpa.free(text);
        try testing.expect(std.mem.find(u8, heard[0], "server-option=") != null);
        try testing.expectEqualStrings(heard[0], heard[1]);
    }

    // A v0 server takes none: git refuses, and so does relic.
    var twin = try testgit.Repo.init(gpa, io, &.{});
    defer twin.deinit();
    try twin.exec(io, &.{ "remote", "add", "origin", url });
    try twin.exec(io, &.{ "config", "core.sshCommand", fake });
    try twin.exec(io, &.{ "config", "protocol.version", "0" });
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const said = try gitFailure(gpa, io, twin.dir, &env, &.{ "fetch", "-q", "-o", "any", "origin" });
    defer gpa.free(said);
    try testing.expect(std.mem.find(u8, said, "server options require protocol version 2 or later") != null);
    var repo = try repo_mod.Repository.open(gpa, io, twin.dir, .{});
    defer repo.deinit(io);
    try testing.expectError(error.ServerOptionsNeedV2, fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .server_options = &.{"any"} }));
}

/// The haves git's upload-pack heard, and where each round ended, as its
/// packet trace shows them.
fn havesHeard(gpa: Allocator, io: Io, trace_path: []const u8) ![]u8 {
    const traced = try Io.Dir.cwd().readFileAlloc(io, trace_path, gpa, .unlimited);
    defer gpa.free(traced);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, traced, '\n');
    while (lines.next()) |line| {
        const at = std.mem.find(u8, line, "upload-pack< ") orelse continue;
        const said = std.mem.trimEnd(u8, line[at + "upload-pack< ".len ..], " ");
        if (std.mem.startsWith(u8, said, "have ") or std.mem.eql(u8, said, "done") or std.mem.eql(u8, said, "0000")) try out.print(gpa, "{s}\n", .{said});
    }
    return out.toOwnedSlice(gpa);
}

test "a fetch offers the haves git's negotiators offer: consecutive, skipping and noop, restricted and included, in v2 and v0" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const fake = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(fake);
    const tools_path = try testremote.absolutePath(gpa, io, tools.dir);
    defer gpa.free(tools_path);
    // The remote: five commits, then three more the fetch wants.
    var source = try testremote.historyRepo(gpa, io, 5);
    defer source.deinit();
    try testremote.addCommits(gpa, io, &source, 5, 3);
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const url = try gpa.print("example.invalid:{s}", .{source_path});
    defer gpa.free(url);

    const Case = struct { version: []const u8, settings: []const [2][]const u8 = &.{} };
    const cases = [_]Case{
        .{ .version = "2" },
        .{ .version = "0" },
        .{ .version = "2", .settings = &.{.{ "fetch.negotiationAlgorithm", "skipping" }} },
        .{ .version = "0", .settings = &.{.{ "fetch.negotiationAlgorithm", "skipping" }} },
        .{ .version = "2", .settings = &.{.{ "feature.experimental", "true" }} },
        .{ .version = "2", .settings = &.{.{ "fetch.negotiationAlgorithm", "noop" }} },
        .{ .version = "0", .settings = &.{.{ "fetch.negotiationAlgorithm", "noop" }} },
        .{ .version = "2", .settings = &.{.{ "remote.origin.negotiationRestrict", "refs/heads/other" }} },
        .{ .version = "0", .settings = &.{.{ "remote.origin.negotiationRestrict", "heads/o*" }} },
        .{ .version = "2", .settings = &.{ .{ "remote.origin.negotiationInclude", "refs/heads/other" }, .{ "fetch.negotiationAlgorithm", "skipping" } } },
        .{ .version = "0", .settings = &.{.{ "remote.origin.negotiationInclude", "refs/heads/other" }} },
    };
    for (cases, 0..) |case, n| {
        var heard: [2][]u8 = undefined;
        for (0..2) |i| {
            // The same history here in each: the remote's first five
            // commits and thirty of its own, on two branches.
            var twin = try testgit.Repo.init(gpa, io, &.{});
            defer twin.deinit();
            try testremote.addCommits(gpa, io, &twin, 0, 5);
            try testremote.addCommits(gpa, io, &twin, 100, 20);
            try twin.exec(io, &.{ "branch", "other", "HEAD~12" });
            try testremote.addCommits(gpa, io, &twin, 200, 10);
            try twin.exec(io, &.{ "remote", "add", "origin", url });
            try twin.exec(io, &.{ "config", "core.sshCommand", fake });
            try twin.exec(io, &.{ "config", "protocol.version", case.version });
            for (case.settings) |kv| try twin.exec(io, &.{ "config", kv[0], kv[1] });
            const trace = try gpa.print("{s}/haves-{d}-{d}", .{ tools_path, n, i });
            defer gpa.free(trace);
            var env = try testremote.environ(gpa);
            defer env.deinit();
            try env.put("GIT_TRACE_PACKET", trace);
            if (i == 0) {
                const out = try testremote.gitInputEnv(gpa, io, twin.dir, &env, &.{ "fetch", "-q", "origin", "main" }, "", true);
                gpa.free(out);
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, twin.dir, .{});
                defer repo.deinit(io);
                var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env }, .refspecs = &.{"main"} });
                defer outcome.deinit();
            }
            heard[i] = try havesHeard(gpa, io, trace);
        }
        defer for (heard) |text| gpa.free(text);
        testing.expectEqualStrings(heard[0], heard[1]) catch |err| {
            std.debug.print("protocol v{s}, {any}\ngit:\n{s}\nrelic:\n{s}\n", .{ case.version, case.settings, heard[0], heard[1] });
            return err;
        };
    }
}

test "several remotes are fetched as git fetches them: fetch.all and skipFetchAll, a group, several names, and fetch.parallel" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var sources: [3]testgit.Repo = undefined;
    var urls: [3][]u8 = undefined;
    for (&sources, &urls, 0..) |*source, *url, i| {
        source.* = try testgit.Repo.init(gpa, io, &.{});
        try testremote.addCommits(gpa, io, source, i * 10, 2 + i);
        const path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(path);
        url.* = try gpa.print("file://{s}", .{path});
    }
    defer for (&sources, urls) |*source, url| {
        source.deinit();
        gpa.free(url);
    };
    const Case = struct { git_args: []const []const u8, selection: fetch_mod.Selection, settings: []const [2][]const u8 = &.{} };
    const cases = [_]Case{
        .{ .git_args = &.{}, .selection = .{}, .settings = &.{.{ "fetch.all", "true" }} },
        .{ .git_args = &.{"--all"}, .selection = .{ .all = true }, .settings = &.{ .{ "remote.c.skipFetchAll", "false" }, .{ "remote.c.skipDefaultUpdate", "true" } } },
        .{ .git_args = &.{"two"}, .selection = .{ .names = &.{"two"} } },
        .{ .git_args = &.{ "--multiple", "a", "c" }, .selection = .{ .names = &.{ "a", "c" } } },
        .{ .git_args = &.{"two"}, .selection = .{ .names = &.{"two"} }, .settings = &.{.{ "fetch.parallel", "2" }} },
    };
    for (cases) |case| {
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| {
            for ([_][]const u8{ "a", "b", "c" }, urls) |name, url| try twin.exec(io, &.{ "remote", "add", name, url });
            try twin.exec(io, &.{ "config", "remote.c.skipFetchAll", "true" });
            try twin.exec(io, &.{ "config", "remotes.two", "a b" });
            for (case.settings) |kv| try twin.exec(io, &.{ "config", kv[0], kv[1] });
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "fetch", "-q" });
        try args.appendSlice(gpa, case.git_args);
        const out = try by_git.run(io, args.items);
        gpa.free(out);
        {
            var repo = try repo_mod.Repository.open(gpa, io, by_relic.dir, .{});
            defer repo.deinit(io);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const names = try fetch_mod.remotesToFetch(arena.allocator(), repo.configuration(), case.selection);
            var many = try fetch_mod.fetchMany(gpa, io, &repo, names, .{ .fetch = .{ .who = test_who, .programs = .{ .environ = &env } } });
            defer many.deinit();
            try testing.expect(!many.anyFailed());
        }
        const format = "--format=%(refname) %(objectname)";
        const theirs = try by_git.run(io, &.{ "for-each-ref", format });
        defer gpa.free(theirs);
        const ours = try by_relic.run(io, &.{ "for-each-ref", format });
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        // Fetched at once, the remotes' lines come in the order they end.
        var heads: [2][]u8 = undefined;
        for ([_]*testgit.Repo{ &by_git, &by_relic }, 0..) |twin, i| {
            const text = try twin.readFile(io, ".git/FETCH_HEAD");
            defer gpa.free(text);
            var lines: std.ArrayList([]const u8) = .empty;
            defer lines.deinit(gpa);
            var it = std.mem.tokenizeScalar(u8, text, '\n');
            while (it.next()) |line| try lines.append(gpa, line);
            std.mem.sort([]const u8, lines.items, {}, struct {
                fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lessThan);
            heads[i] = try std.mem.join(gpa, "\n", lines.items);
        }
        defer for (heads) |h| gpa.free(h);
        try testing.expectEqualStrings(heads[0], heads[1]);
    }
}

/// Upstream for the submodule fetches: `inner`; `lib`, holding `inner`;
/// and `super`, holding `lib` and, at `vendor/inner`, `inner` again; each
/// made in `work/<name>` and pushed to the bare one the server serves,
/// which hands out any commit asked for by name.
const SubmoduleWorld = struct {
    root: testing.TmpDir,
    work: testgit.Repo,
    server: *testremote.HttpServer,
    root_path: []u8,

    fn init(gpa: Allocator, io: Io) !SubmoduleWorld {
        var root = testing.tmpDir(.{ .iterate = true });
        errdefer root.cleanup();
        const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
        errdefer server.stop();
        const root_path = try testremote.absolutePath(gpa, io, root.dir);
        errdefer gpa.free(root_path);
        var work = try testgit.Repo.init(gpa, io, &.{});
        errdefer work.deinit();
        var world: SubmoduleWorld = .{ .root = root, .work = work, .server = server, .root_path = root_path };
        for ([_][]const u8{ "inner", "lib", "super" }) |name| {
            const bare = try gpa.print("{s}/{s}.git", .{ root_path, name });
            defer gpa.free(bare);
            try world.git(gpa, io, ".", &.{ "init", "-q", "--bare", "-b", "main", bare });
            try world.git(gpa, io, ".", &.{ "--git-dir", bare, "config", "uploadpack.allowAnySHA1InWant", "true" });
            try world.git(gpa, io, ".", &.{ "--git-dir", bare, "config", "uploadpack.allowFilter", "true" });
            try world.git(gpa, io, ".", &.{ "init", "-q", "-b", "main", name });
            const served = try world.url(gpa, name);
            defer gpa.free(served);
            try world.git(gpa, io, name, &.{ "remote", "add", "origin", served });
            // The server takes no pushes; each goes to the bare repository.
            try world.git(gpa, io, name, &.{ "remote", "set-url", "--push", "origin", bare });
            var dir = try world.work.dir.openDir(io, name, .{});
            defer dir.close(io);
            try dir.writeFile(io, .{ .sub_path = "README", .data = name });
            try world.git(gpa, io, name, &.{ "add", "README" });
            if (std.mem.eql(u8, name, "lib")) try world.git(gpa, io, name, &.{ "submodule", "add", "-q", "../inner.git", "inner" });
            if (std.mem.eql(u8, name, "super")) {
                try world.git(gpa, io, name, &.{ "submodule", "add", "-q", "../lib.git", "lib" });
                try world.git(gpa, io, name, &.{ "submodule", "add", "-q", "../inner.git", "vendor/inner" });
            }
            try world.git(gpa, io, name, &.{ "commit", "-q", "-m", name });
            try world.git(gpa, io, name, &.{ "push", "-q", "origin", "main" });
        }
        return world;
    }

    fn deinit(w: *SubmoduleWorld, gpa: Allocator) void {
        w.work.deinit();
        w.server.stop();
        gpa.free(w.root_path);
        w.root.cleanup();
    }

    fn url(w: *SubmoduleWorld, gpa: Allocator, name: []const u8) ![]u8 {
        const file = try gpa.print("{s}.git", .{name});
        defer gpa.free(file);
        return w.server.url(gpa, file);
    }

    fn git(w: *SubmoduleWorld, gpa: Allocator, io: Io, at: []const u8, args: []const []const u8) !void {
        var dir = try w.work.dir.openDir(io, at, .{});
        defer dir.close(io);
        const out = try testremote.gitInput(gpa, io, dir, args, "");
        gpa.free(out);
    }

    /// A clone of `super` with every submodule checked out, by git.
    fn twin(w: *SubmoduleWorld, gpa: Allocator, io: Io, name: []const u8) !void {
        const super_url = try w.url(gpa, "super");
        defer gpa.free(super_url);
        try w.git(gpa, io, ".", &.{ "clone", "-q", "--recurse-submodules", super_url, name });
    }

    /// The tree at `from` copied to `to`: a second twin, the same to the
    /// byte, for less than a second clone takes. A twin's submodules name
    /// their git directories by relative paths, so the copy is one too.
    fn copy(w: *SubmoduleWorld, gpa: Allocator, io: Io, from: []const u8, to: []const u8) !void {
        var source = try w.work.dir.openDir(io, from, .{ .iterate = true });
        defer source.close(io);
        try w.work.dir.createDirPath(io, to);
        var dest = try w.work.dir.openDir(io, to, .{});
        defer dest.close(io);
        try testgit.copyTree(gpa, io, source, dest);
    }

    /// A new commit of `inner`, pushed to `ref`, and, under `record`, the
    /// gitlinks above it moved to it and pushed.
    fn advance(w: *SubmoduleWorld, gpa: Allocator, io: Io, ref: []const u8, record: bool) !void {
        var inner = try w.work.dir.openDir(io, "inner", .{});
        defer inner.close(io);
        try inner.writeFile(io, .{ .sub_path = "README", .data = ref });
        try w.git(gpa, io, "inner", &.{ "commit", "-q", "--allow-empty", "-am", ref });
        const spec = try gpa.print("HEAD:{s}", .{ref});
        defer gpa.free(spec);
        try w.git(gpa, io, "inner", &.{ "push", "-q", "origin", spec });
        if (!record) return;
        for ([_][]const u8{ "lib/inner", "super/vendor/inner" }) |path| {
            try w.git(gpa, io, path, &.{ "fetch", "-q", "origin", ref });
            try w.git(gpa, io, path, &.{ "checkout", "-q", "FETCH_HEAD" });
        }
        try w.git(gpa, io, "lib", &.{ "commit", "-q", "-am", "move inner" });
        try w.git(gpa, io, "lib", &.{ "push", "-q", "origin", "main" });
        try w.git(gpa, io, "super/lib", &.{ "pull", "-q", "--no-recurse-submodules", "origin", "main" });
        try w.git(gpa, io, "super", &.{ "commit", "-q", "-am", "move lib and inner" });
        try w.git(gpa, io, "super", &.{ "push", "-q", "origin", "main" });
    }
};

/// Each git directory of two clones the same: refs and `FETCH_HEAD`.
fn expectSameSubmoduleFetch(gpa: Allocator, io: Io, world: *SubmoduleWorld) !void {
    for ([_][]const u8{ ".git", ".git/modules/lib", ".git/modules/lib/modules/inner", ".git/modules/vendor/inner" }) |git_dir| {
        var refs: [2][]u8 = undefined;
        var heads: [2][]u8 = undefined;
        for ([_][]const u8{ "by-git", "by-relic" }, &refs, &heads) |name, *listed, *head| {
            var dir = try world.work.dir.openDir(io, name, .{});
            defer dir.close(io);
            listed.* = try testremote.gitInput(gpa, io, dir, &.{ "--git-dir", git_dir, "for-each-ref", "--format=%(refname) %(objectname)" }, "");
            const path = try gpa.print("{s}/FETCH_HEAD", .{git_dir});
            defer gpa.free(path);
            head.* = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
                error.FileNotFound => try gpa.dupe(u8, "(none)"),
                else => return err,
            };
        }
        defer for (refs ++ heads) |d| gpa.free(d);
        try testing.expectEqualStrings(refs[0], refs[1]);
        try testing.expectEqualStrings(heads[0], heads[1]);
    }
}

test "a fetch goes into the submodules as git's fetch_submodules does: on demand, always, never, by their settings, for a commit by name, several at once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const Case = struct {
        /// The ref `inner`'s new commit goes to, and whether the gitlinks
        /// above it record it.
        ref: []const u8 = "refs/heads/main",
        record: bool = true,
        config: []const [2][]const u8 = &.{},
        git_args: []const []const u8 = &.{},
        options: fetch_mod.Options,
        /// The submodules relic's fetch says it went into.
        went: []const []const u8,
    };
    const cases = [_]Case{
        .{ .options = .{ .who = test_who }, .went = &.{ "lib", "lib/inner", "vendor/inner" } },
        .{ .git_args = &.{"--no-recurse-submodules"}, .options = .{ .who = test_who, .recurse_submodules = .off }, .went = &.{} },
        .{ .record = false, .options = .{ .who = test_who }, .went = &.{} },
        .{ .record = false, .git_args = &.{"--recurse-submodules"}, .options = .{ .who = test_who, .recurse_submodules = .on }, .went = &.{ "lib", "lib/inner", "vendor/inner" } },
        .{ .config = &.{.{ "fetch.recurseSubmodules", "false" }}, .options = .{ .who = test_who }, .went = &.{} },
        // The clone wrote `[submodule] active`, so `submodule.recurse` goes
        // there, before `[fetch]`, and the fetch's setting is the later.
        .{ .config = &.{ .{ "submodule.recurse", "false" }, .{ "fetch.recurseSubmodules", "true" } }, .record = false, .options = .{ .who = test_who }, .went = &.{ "lib", "lib/inner", "vendor/inner" } },
        .{ .config = &.{.{ "submodule.recurse", "true" }}, .record = false, .options = .{ .who = test_who }, .went = &.{ "lib", "lib/inner", "vendor/inner" } },
        .{ .config = &.{.{ "submodule.lib.fetchRecurseSubmodules", "true" }}, .record = false, .options = .{ .who = test_who }, .went = &.{ "lib", "lib/inner" } },
        .{ .ref = "refs/keep/aside", .options = .{ .who = test_who }, .went = &.{ "lib", "lib/inner", "vendor/inner" } },
        .{ .git_args = &.{ "-j", "2" }, .options = .{ .who = test_who, .submodule_jobs = 2 }, .went = &.{ "lib", "lib/inner", "vendor/inner" } },
    };
    // One world for every case, each cloned afresh from where the last
    // left it: what a case fetches is only its own advance.
    var world = try SubmoduleWorld.init(gpa, io);
    defer world.deinit(gpa);
    for (cases) |case| {
        for ([_][]const u8{ "by-git", "by-relic" }) |name| try world.work.dir.deleteTree(io, name);
        try world.twin(gpa, io, "by-git");
        try world.copy(gpa, io, "by-git", "by-relic");
        for (case.config) |pair| for ([_][]const u8{ "by-git", "by-relic" }) |name| try world.git(gpa, io, name, &.{ "config", pair[0], pair[1] });
        try world.advance(gpa, io, case.ref, case.record);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "fetch", "-q" });
        try argv.appendSlice(gpa, case.git_args);
        try world.git(gpa, io, "by-git", argv.items);

        var dir = try world.work.dir.openDir(io, "by-relic", .{});
        defer dir.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var options = case.options;
        options.programs = .{ .environ = &env };
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", options);
        defer outcome.deinit();
        try testing.expect(!outcome.anySubmoduleFailed());
        var went: std.ArrayList([]const u8) = .empty;
        defer went.deinit(gpa);
        for (outcome.submodules) |s| try went.append(gpa, s.path);
        std.mem.sort([]const u8, went.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        try testing.expectEqual(case.went.len, went.items.len);
        for (case.went, went.items) |want, got| try testing.expectEqualStrings(want, got);
        try expectSameSubmoduleFetch(gpa, io, &world);
    }
}

/// Each git directory of two recursive clones the same: refs, `HEAD`, the
/// settings a clone and an update write, its lenders and its boundary.
fn expectSameRecursiveClone(gpa: Allocator, io: Io, world: *SubmoduleWorld) !void {
    for ([_][]const u8{ ".git", ".git/modules/lib", ".git/modules/lib/modules/inner", ".git/modules/vendor/inner" }) |git_dir| {
        var outs: [2][4][]u8 = undefined;
        for ([_][]const u8{ "by-git", "by-relic" }, &outs) |name, *out| {
            var dir = try world.work.dir.openDir(io, name, .{});
            defer dir.close(io);
            out[0] = testremote.gitInput(gpa, io, dir, &.{ "--git-dir", git_dir, "for-each-ref", "--format=%(refname) %(objectname) %(symref)" }, "") catch try gpa.dupe(u8, "(none)");
            out[1] = testremote.gitInput(gpa, io, dir, &.{ "--git-dir", git_dir, "config", "--local", "--get-regexp", "^(remote|branch|submodule|core\\.(bare|worktree))" }, "") catch try gpa.dupe(u8, "(none)");
            for ([_][]const u8{ "objects/info/alternates", "shallow" }, out[2..4]) |file, *content| {
                const path = try gpa.print("{s}/{s}", .{ git_dir, file });
                defer gpa.free(path);
                content.* = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
                    error.FileNotFound => try gpa.dupe(u8, "(none)"),
                    else => return err,
                };
            }
        }
        defer for (outs) |out| for (out) |o| gpa.free(o);
        for (outs[0], outs[1]) |theirs, ours| try testing.expectEqualStrings(theirs, ours);
    }
    var statuses: [2][]u8 = undefined;
    for ([_][]const u8{ "by-git", "by-relic" }, &statuses) |name, *out| {
        var dir = try world.work.dir.openDir(io, name, .{});
        defer dir.close(io);
        out.* = try testremote.gitInput(gpa, io, dir, &.{ "submodule", "status", "--recursive" }, "");
    }
    defer for (statuses) |s| gpa.free(s);
    try testing.expectEqualStrings(statuses[0], statuses[1]);
}

test "a clone with --recurse-submodules is git's: the pathspecs active, shallow and filtered submodules, and the lenders' own lending to them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const Case = struct {
        git_args: []const []const u8,
        options: clone_mod.Options,
        /// A recursive clone by git, at `lender`, borrowed from.
        lender: bool = false,
        config: []const config_mod.Sources.Pair = &.{},
        refused: ?anyerror = null,
        /// `inner` moved on past what the gitlinks record, first.
        advanced: bool = false,
    };
    const lender_ref = [_]clone_mod.Reference{.{ .path = "LENDER" }};
    const cases = [_]Case{
        .{ .git_args = &.{"--recurse-submodules"}, .options = .{ .who = test_who, .recurse_submodules = &.{} } },
        .{ .git_args = &.{"--recurse-submodules=lib"}, .options = .{ .who = test_who, .recurse_submodules = &.{"lib"} } },
        .{ .git_args = &.{ "--recurse-submodules", "--shallow-submodules" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .shallow_submodules = true } },
        .{ .git_args = &.{ "--recurse-submodules", "--filter=blob:none", "--also-filter-submodules" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .filter = "blob:none", .filter_submodules = true } },
        .{ .git_args = &.{ "-c", "clone.filterSubmodules=true", "--recurse-submodules", "--filter=blob:none" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .filter = "blob:none" }, .config = &.{.{ .name = "clone.filterSubmodules", .value = "true" }} },
        .{ .git_args = &.{ "--recurse-submodules", "--reference", "LENDER" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .reference = &lender_ref }, .lender = true },
        .{ .git_args = &.{ "--recurse-submodules", "--also-filter-submodules" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .filter_submodules = true }, .refused = error.FilterSubmodulesAlone },
        .{ .git_args = &.{ "--recurse-submodules", "--remote-submodules" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .remote_submodules = true }, .advanced = true },
        .{ .git_args = &.{"--remote-submodules"}, .options = .{ .who = test_who, .remote_submodules = true }, .advanced = true },
        .{ .git_args = &.{ "--recurse-submodules", "--jobs", "2" }, .options = .{ .who = test_who, .recurse_submodules = &.{}, .submodule_jobs = 2 }, .advanced = true },
    };
    for (cases) |case| {
        var world = try SubmoduleWorld.init(gpa, io);
        defer world.deinit(gpa);
        if (case.advanced) try world.advance(gpa, io, "refs/heads/main", false);
        const super_url = try world.url(gpa, "super");
        defer gpa.free(super_url);
        const lender = try gpa.print("{s}/lender", .{world.root_path});
        defer gpa.free(lender);
        if (case.lender) {
            var root = try world.work.dir.openDir(io, ".", .{});
            defer root.close(io);
            const out = try testremote.gitInput(gpa, io, root, &.{ "clone", "-q", "--recurse-submodules", super_url, lender }, "");
            gpa.free(out);
            try world.advance(gpa, io, "refs/heads/main", true);
        }
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        for (case.git_args) |arg| try argv.append(gpa, if (std.mem.eql(u8, arg, "LENDER")) lender else arg);
        // `-c` goes before `clone`.
        var git_argv: std.ArrayList([]const u8) = .empty;
        defer git_argv.deinit(gpa);
        if (argv.items.len > 1 and std.mem.eql(u8, argv.items[0], "-c")) {
            try git_argv.appendSlice(gpa, argv.items[0..2]);
            try git_argv.appendSlice(gpa, &.{ "clone", "-q" });
            try git_argv.appendSlice(gpa, argv.items[2..]);
        } else {
            try git_argv.appendSlice(gpa, &.{ "clone", "-q" });
            try git_argv.appendSlice(gpa, argv.items);
        }
        try git_argv.appendSlice(gpa, &.{ super_url, "by-git" });
        var root = try world.work.dir.openDir(io, ".", .{});
        defer root.close(io);
        const by_git = testremote.gitInputEnv(gpa, io, root, &env, git_argv.items, "", false);

        try root.createDirPath(io, "by-relic");
        var dir = try root.openDir(io, "by-relic", .{ .iterate = true });
        defer dir.close(io);
        var options = case.options;
        options.programs = .{ .environ = &env };
        options.user_config = .{ .pairs = case.config };
        const references = [_]clone_mod.Reference{.{ .path = lender }};
        if (case.lender) options.reference = &references;
        const made = clone_mod.clone(gpa, io, super_url, dir, options);
        if (case.refused) |err| {
            try testing.expectError(error.GitFailed, by_git);
            try testing.expectError(err, made);
            continue;
        }
        gpa.free(try by_git);
        var repo = try made;
        repo.deinit(io);
        try expectSameRecursiveClone(gpa, io, &world);
    }
}

test "a clone with --recurse-submodules runs post-checkout in the superproject and in each submodule, as git's does, and a failed one in the superproject leaves the submodules be" {
    // The hooks are shell scripts, run as files.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    for ([_]u8{ 0, 3 }) |status| {
        var world = try SubmoduleWorld.init(gpa, io);
        defer world.deinit(gpa);
        const super_url = try world.url(gpa, "super");
        defer gpa.free(super_url);
        // One hooks directory for every repository, by `core.hooksPath`
        // from the command line, whose post-checkout writes its arguments
        // where it runs.
        try world.work.dir.createDirPath(io, "hooks");
        const script = try gpa.print("#!/bin/sh\necho \"$@\" >> post-checkout.log\nexit {d}\n", .{status});
        defer gpa.free(script);
        try world.work.dir.writeFile(io, .{ .sub_path = "hooks/post-checkout", .data = script });
        try world.work.dir.setFilePermissions(io, "hooks/post-checkout", .fromMode(0o755), .{});
        const work_path = try testremote.absolutePath(gpa, io, world.work.dir);
        defer gpa.free(work_path);
        const hooks_path = try gpa.print("{s}/hooks", .{work_path});
        defer gpa.free(hooks_path);
        const setting = try gpa.print("core.hooksPath={s}", .{hooks_path});
        defer gpa.free(setting);

        var root = try world.work.dir.openDir(io, ".", .{});
        defer root.close(io);
        const by_git = testremote.gitInputEnv(gpa, io, root, &env, &.{ "-c", setting, "clone", "-q", "--recurse-submodules", super_url, "by-git" }, "", false);

        try root.createDirPath(io, "by-relic");
        var dir = try root.openDir(io, "by-relic", .{ .iterate = true });
        defer dir.close(io);
        var failure: hooks_mod.Failure = .{};
        const made = clone_mod.clone(gpa, io, super_url, dir, .{
            .who = test_who,
            .recurse_submodules = &.{},
            .programs = .{ .environ = &env },
            .user_config = .{ .pairs = &.{.{ .name = "core.hookspath", .value = hooks_path }} },
            .hooks = .{ .output = .ignore },
            .hook_failure = &failure,
        });
        if (status != 0) {
            try testing.expectError(error.GitFailed, by_git);
            try testing.expectError(error.HookRejected, made);
            try testing.expectEqual(@as(?u32, status), failure.status());
        } else {
            gpa.free(try by_git);
            var repo = try made;
            repo.deinit(io);
        }
        // What each repository's hook was given, or that none ran there.
        for ([_][]const u8{ "", "lib/", "lib/inner/", "vendor/inner/" }) |at| {
            var said: [2][]u8 = undefined;
            for ([_][]const u8{ "by-git", "by-relic" }, &said) |name, *out| {
                const path = try gpa.print("{s}/{s}post-checkout.log", .{ name, at });
                defer gpa.free(path);
                out.* = root.readFileAlloc(io, path, gpa, .limited(1 << 10)) catch |err| switch (err) {
                    error.FileNotFound => try gpa.dupe(u8, "(none)"),
                    else => return err,
                };
            }
            defer for (said) |o| gpa.free(o);
            testing.expectEqualStrings(said[0], said[1]) catch |err| {
                std.debug.print("status {d}: {s}post-checkout.log\n", .{ status, at });
                return err;
            };
            try testing.expectEqual(status != 0 and at.len != 0, std.mem.eql(u8, said[1], "(none)"));
        }
    }
}

test "submodule update --remote is git's: each submodule fetched and checked out at its remote-tracking branch, by its branch setting, the superproject's own, without a fetch, and refused where git dies" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const Case = struct {
        /// Where `inner`'s new commit goes.
        ref: []const u8 = "refs/heads/main",
        config: []const [2][]const u8 = &.{},
        /// Written into each twin's `.gitmodules`.
        gitmodules: []const [2][]const u8 = &.{},
        git_args: []const []const u8 = &.{},
        recursive: bool = false,
        fetch: bool = true,
        /// `vendor/inner` fetched once `inner` has moved, and `inner`
        /// moved again: a remote-tracking branch behind the remote's.
        prefetch: bool = false,
        /// The superproject's `HEAD` detached first.
        detached: bool = false,
        refused: ?anyerror = null,
        /// What the refusal names.
        setting: []const u8 = "",
    };
    const cases = [_]Case{
        .{},
        .{ .git_args = &.{"--recursive"}, .recursive = true },
        .{ .ref = "refs/heads/side", .config = &.{.{ "submodule.vendor/inner.branch", "side" }} },
        .{ .ref = "refs/heads/side", .gitmodules = &.{.{ "submodule.vendor/inner.branch", "side" }} },
        .{ .config = &.{.{ "submodule.vendor/inner.branch", "." }} },
        .{ .prefetch = true },
        .{ .git_args = &.{"--no-fetch"}, .fetch = false, .prefetch = true },
        .{ .config = &.{.{ "submodule.vendor/inner.branch", "." }}, .detached = true, .refused = error.NoSuperprojectBranch, .setting = "HEAD" },
        .{ .config = &.{.{ "submodule.vendor/inner.branch", "gone" }}, .refused = error.NoRemoteRevision, .setting = "refs/remotes/origin/gone" },
    };
    const twins = [_][]const u8{ "by-git", "by-relic" };
    var world = try SubmoduleWorld.init(gpa, io);
    defer world.deinit(gpa);
    for (cases) |case| {
        for (twins) |name| try world.work.dir.deleteTree(io, name);
        try world.twin(gpa, io, "by-git");
        try world.copy(gpa, io, "by-git", "by-relic");
        for (twins) |name| {
            for (case.config) |pair| try world.git(gpa, io, name, &.{ "config", pair[0], pair[1] });
            for (case.gitmodules) |pair| try world.git(gpa, io, name, &.{ "config", "-f", ".gitmodules", pair[0], pair[1] });
            if (case.detached) try world.git(gpa, io, name, &.{ "checkout", "-q", "--detach" });
        }
        try world.advance(gpa, io, case.ref, false);
        if (case.prefetch) {
            for (twins) |name| {
                const at = try gpa.print("{s}/vendor/inner", .{name});
                defer gpa.free(at);
                try world.git(gpa, io, at, &.{ "fetch", "-q" });
            }
            try world.advance(gpa, io, case.ref, false);
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "submodule", "update", "-q", "--remote" });
        try argv.appendSlice(gpa, case.git_args);
        var by_git_dir = try world.work.dir.openDir(io, "by-git", .{});
        defer by_git_dir.close(io);
        const by_git = testremote.gitInputEnv(gpa, io, by_git_dir, &env, argv.items, "", false);

        var dir = try world.work.dir.openDir(io, "by-relic", .{});
        defer dir.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var t: clone_mod.SubmoduleTransport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
        defer t.deinit();
        var refusal: submodule.Refusal = .{};
        const updated = submodule.update(gpa, io, &repo, .{
            .remote = true,
            .fetch = case.fetch,
            .recursive = case.recursive,
            .who = test_who,
            .transport = t.transport(),
            .refusal = &refusal,
        });
        if (case.refused) |err| {
            try testing.expectError(error.GitFailed, by_git);
            try testing.expectError(err, updated);
            try testing.expectEqualStrings("vendor/inner", refusal.path());
            try testing.expectEqualStrings(case.setting, refusal.setting());
            continue;
        }
        gpa.free(try by_git);
        _ = try updated;
        try expectSameRecursiveClone(gpa, io, &world);
    }
}

test "submodules cloned several at once: one whose clone fails twice is named and nothing is checked out, as git's update_clone stops; a negative submodule.fetchJobs is refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var world = try SubmoduleWorld.init(gpa, io);
    defer world.deinit(gpa);
    const super_url = try world.url(gpa, "super");
    defer gpa.free(super_url);
    const missing = try world.url(gpa, "missing");
    defer gpa.free(missing);
    try world.git(gpa, io, ".", &.{ "clone", "-q", super_url, "by-git" });
    try world.git(gpa, io, "by-git", &.{ "submodule", "init" });
    try world.git(gpa, io, "by-git", &.{ "config", "submodule.vendor/inner.url", missing });
    try world.copy(gpa, io, "by-git", "by-relic");

    var by_git_dir = try world.work.dir.openDir(io, "by-git", .{});
    defer by_git_dir.close(io);
    var dir = try world.work.dir.openDir(io, "by-relic", .{});
    defer dir.close(io);
    var t: clone_mod.SubmoduleTransport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
    defer t.deinit();

    // git dies on the setting before it clones anything.
    try world.git(gpa, io, "by-relic", &.{ "config", "submodule.fetchJobs", "-1" });
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, by_git_dir, &env, &.{ "-c", "submodule.fetchJobs=-1", "submodule", "update", "-q" }, "", false));
    {
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        try testing.expectError(error.InvalidFetchJobs, submodule.update(gpa, io, &repo, .{ .transport = t.transport() }));
    }
    try world.git(gpa, io, "by-relic", &.{ "config", "--unset", "submodule.fetchJobs" });

    try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, by_git_dir, &env, &.{ "submodule", "update", "-q", "--jobs", "2" }, "", false));
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var refusal: submodule.Refusal = .{};
    try testing.expectError(error.TransportFailed, submodule.update(gpa, io, &repo, .{ .jobs = 2, .who = test_who, .transport = t.transport(), .refusal = &refusal }));
    try testing.expectEqualStrings("vendor/inner", refusal.path());
    try testing.expectEqualStrings(missing, refusal.setting());
    var kept = t.take(io);
    defer kept.auth_failure.deinit();
    try testing.expect(kept.failure != null);
    try testing.expectEqual(@as(u32, 1), kept.clones);
    // `lib` cloned and connected, and checked out by neither.
    for ([_]Io.Dir{ by_git_dir, dir }) |d| {
        try d.access(io, "lib/.git", .{});
        try testing.expectError(error.FileNotFound, d.access(io, "lib/README", .{}));
        try testing.expectError(error.FileNotFound, d.access(io, "vendor/inner/.git", .{}));
        try testing.expectError(error.FileNotFound, d.access(io, ".git/modules/vendor/inner/HEAD", .{}));
    }
}

test "a submodule whose clone fails is cloned again after the others, as git's update_clone retries it once, and one that fails again stops the update with nothing checked out" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    for ([_]u32{ 1, 2 }) |jobs| for ([_]u32{ 1, 2 }) |failures| {
        var world = try SubmoduleWorld.init(gpa, io);
        defer world.deinit(gpa);
        const super_url = try world.url(gpa, "super");
        defer gpa.free(super_url);
        try world.git(gpa, io, ".", &.{ "clone", "-q", super_url, "by-git" });
        try world.git(gpa, io, "by-git", &.{ "submodule", "init" });
        try world.copy(gpa, io, "by-git", "by-relic");
        var by_git_dir = try world.work.dir.openDir(io, "by-git", .{});
        defer by_git_dir.close(io);
        var dir = try world.work.dir.openDir(io, "by-relic", .{});
        defer dir.close(io);

        // The server fails `lib`'s first clone, or its first two, for
        // each in turn.
        var jobs_buf: [4]u8 = undefined;
        const jobs_text = try std.mem.print(&jobs_buf, "{d}", .{jobs});
        world.server.failFirst("lib.git", failures);
        const by_git = testremote.gitInputEnv(gpa, io, by_git_dir, &env, &.{ "submodule", "update", "-q", "--recursive", "--jobs", jobs_text }, "", false);
        world.server.failFirst("lib.git", failures);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var t: clone_mod.SubmoduleTransport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
        defer t.deinit();
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        var refusal: submodule.Refusal = .{};
        const updated = submodule.update(gpa, io, &repo, .{ .recursive = true, .jobs = jobs, .who = test_who, .transport = t.transport(), .warnings = &warnings, .refusal = &refusal });
        {
            var kept = t.take(io);
            kept.auth_failure.deinit();
        }
        // git's "Failed to clone 'lib'. Retry scheduled", either way.
        try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
        try testing.expectEqualStrings("lib", warnings.items.items[0].submodule_clone_retried);
        if (failures == 2) {
            try testing.expectError(error.GitFailed, by_git);
            try testing.expectError(error.TransportFailed, updated);
            try testing.expectEqualStrings("lib", refusal.path());
            // `vendor/inner` cloned, and nothing checked out by either.
            for ([_]Io.Dir{ by_git_dir, dir }) |d| {
                try d.access(io, "vendor/inner/.git", .{});
                try testing.expectError(error.FileNotFound, d.access(io, "vendor/inner/README", .{}));
                try testing.expectError(error.FileNotFound, d.access(io, "lib/README", .{}));
            }
            continue;
        }
        gpa.free(try by_git);
        const outcome = try updated;
        try testing.expectEqual(@as(u32, 2), outcome.cloned);
        try expectSameRecursiveClone(gpa, io, &world);
    };
}

test "an update goes on past submodules whose checkout git refuses and fails at the end naming each, as git's update_submodules does with two of three refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var world = try SubmoduleWorld.init(gpa, io);
    defer world.deinit(gpa);
    try world.twin(gpa, io, "by-git");
    // Upstream, inner's README changes and lib and the superproject record
    // it; the twin takes the superproject's record alone, and changes the
    // README in both of its inner checkouts, which git will not overwrite.
    try world.advance(gpa, io, "refs/heads/main", true);
    try world.git(gpa, io, "by-git", &.{ "pull", "-q", "--no-recurse-submodules" });
    for ([_][]const u8{ "by-git/lib/inner", "by-git/vendor/inner" }) |at| {
        var dir = try world.work.dir.openDir(io, at, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "README", .data = "local\n" });
    }
    try world.copy(gpa, io, "by-git", "by-relic");

    var by_git_dir = try world.work.dir.openDir(io, "by-git", .{});
    defer by_git_dir.close(io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, &testgit.default_settings);
    try argv.appendSlice(gpa, &.{ "submodule", "update", "-q", "--recursive" });
    var by_git = try program.run(gpa, io, .{ .environ = &env }, .{ .argv = argv.items, .cwd = .{ .dir = by_git_dir }, .stderr = .capture }, .{});
    defer by_git.deinit(gpa);
    // git's own exit status, and the submodules it names, in its order.
    try testing.expectEqual(program.Term{ .exited = 1 }, by_git.term);
    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);
    var lines = std.mem.splitScalar(u8, by_git.stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "Unable to checkout '") == null) continue;
        const marker = "in submodule path '";
        const at = (std.mem.find(u8, line, marker) orelse continue) + marker.len;
        try named.append(gpa, line[at .. std.mem.findScalarLast(u8, line, '\'') orelse continue]);
    }

    var dir = try world.work.dir.openDir(io, "by-relic", .{});
    defer dir.close(io);
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var t: clone_mod.SubmoduleTransport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
    defer t.deinit();
    var failed: submodule.Failed = .init(gpa);
    defer failed.deinit();
    var refusal: submodule.Refusal = .{};
    try testing.expectError(error.LocalModifications, submodule.update(gpa, io, &repo, .{ .recursive = true, .who = test_who, .transport = t.transport(), .failed = &failed, .refusal = &refusal }));
    try testing.expectEqualStrings("lib/inner", refusal.path());
    try testing.expectEqual(named.items.len, failed.items.items.len);
    for (named.items, failed.items.items) |path, failure| {
        try testing.expectEqualStrings(path, failure.refusal.path());
        try testing.expectEqual(error.LocalModifications, failure.err);
    }
    try testing.expectEqual(@as(usize, 2), named.items.len);
    // lib moved on in both, and each inner left as its change left it.
    try expectSameRecursiveClone(gpa, io, &world);
}

test "a pull updates the submodules as git's does: checked out after a merge, rebased after a rebase, by --recurse-submodules or submodule.recurse, and a rebase of commits that record one refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const Case = struct {
        git_args: []const []const u8,
        mode: ?pull_mod.Mode = null,
        recurse: ?@import("../submodule/changes.zig").Recurse = null,
        config: []const [2][]const u8 = &.{},
        /// The pull updates the submodules.
        updates: bool = true,
        /// A commit of the twin's own records `vendor/inner` elsewhere.
        local_record: bool = false,
        refused: ?anyerror = null,
    };
    const cases = [_]Case{
        .{ .git_args = &.{"--recurse-submodules"}, .recurse = .on },
        .{ .git_args = &.{ "--rebase", "--recurse-submodules" }, .mode = .rebase, .recurse = .on },
        .{ .git_args = &.{"--recurse-submodules=on-demand"}, .recurse = .on_demand },
        .{ .git_args = &.{}, .config = &.{.{ "submodule.recurse", "true" }} },
        .{ .git_args = &.{"--no-recurse-submodules"}, .recurse = .off, .config = &.{.{ "submodule.recurse", "true" }}, .updates = false },
        .{ .git_args = &.{"--rebase"}, .mode = .rebase, .updates = false },
        .{ .git_args = &.{ "--rebase", "--recurse-submodules" }, .mode = .rebase, .recurse = .on, .local_record = true, .refused = error.LocallyRecordedSubmoduleChanges },
    };
    const twins = [_][]const u8{ "by-git", "by-relic" };
    var world = try SubmoduleWorld.init(gpa, io);
    defer world.deinit(gpa);
    for (cases, 0..) |case, n| {
        for (twins) |name| try world.work.dir.deleteTree(io, name);
        try world.twin(gpa, io, "by-git");
        for (case.config) |pair| try world.git(gpa, io, "by-git", &.{ "config", pair[0], pair[1] });
        if (case.local_record) {
            // `vendor/inner` at a commit of its own, recorded on the
            // twin's branch, so the branch and its upstream diverge.
            try world.git(gpa, io, "by-git/vendor/inner", &.{ "commit", "-q", "--allow-empty", "-m", "local" });
            try world.git(gpa, io, "by-git", &.{ "commit", "-q", "-am", "record inner" });
        }
        try world.copy(gpa, io, "by-git", "by-relic");
        try world.advance(gpa, io, "refs/heads/main", true);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "pull", "-q" });
        try argv.appendSlice(gpa, case.git_args);
        var by_git_dir = try world.work.dir.openDir(io, "by-git", .{});
        defer by_git_dir.close(io);
        const by_git = testremote.gitInputEnv(gpa, io, by_git_dir, &env, argv.items, "", false);
        // git's `GIT_REFLOG_ACTION`: `pull` and every argument it was given.
        const reflog_action = try std.mem.join(gpa, " ", argv.items);
        defer gpa.free(reflog_action);

        var dir = try world.work.dir.openDir(io, "by-relic", .{});
        defer dir.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var t: clone_mod.SubmoduleTransport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
        defer t.deinit();
        const pulled = pull_mod.pull(gpa, io, &repo, null, .{
            .mode = case.mode,
            .reflog_action = reflog_action,
            .fetch = .{ .who = test_who, .programs = .{ .environ = &env }, .recurse_submodules = case.recurse },
            .merge = .{ .who = test_who },
            .rebasing = .{ .who = test_who },
            .submodule_transport = t.transport(),
        });
        if (case.refused) |err| {
            try testing.expectError(error.GitFailed, by_git);
            try testing.expectError(err, pulled);
            continue;
        }
        gpa.free(by_git catch |err| {
            std.debug.print("case {d}: git pull failed\n", .{n});
            return err;
        });
        var outcome = try pulled;
        defer outcome.deinit();
        try testing.expectEqual(case.updates, outcome.submodules != null);
        try expectSameRecursiveClone(gpa, io, &world);
        // Each submodule's last `HEAD` log line: the pull's words, as git
        // hands them to its update's checkout.
        for ([_][]const u8{ "lib", "vendor/inner", "lib/inner" }) |path| {
            var said: [2][]u8 = undefined;
            for (twins, &said) |name, *out| {
                const at = try gpa.print("{s}/{s}", .{ name, path });
                defer gpa.free(at);
                var sub = try world.work.dir.openDir(io, at, .{});
                defer sub.close(io);
                out.* = try testremote.gitInput(gpa, io, sub, &.{ "reflog", "-1", "--format=%gs" }, "");
            }
            defer for (said) |o| gpa.free(o);
            try testing.expectEqualStrings(said[0], said[1]);
        }
    }
}

/// `world`'s twin, with every repository's pushes going to its bare
/// repository, and a new commit on the branch of `inner` (within `lib`),
/// of `lib` and of the superproject, each recording the one below.
fn changeUnderTwin(gpa: Allocator, io: Io, world: *SubmoduleWorld) !void {
    try world.twin(gpa, io, "twin");
    for ([_][2][]const u8{ .{ "twin", "super" }, .{ "twin/lib", "lib" }, .{ "twin/lib/inner", "inner" }, .{ "twin/vendor/inner", "inner" } }) |pair| {
        const bare = try gpa.print("{s}/{s}.git", .{ world.root_path, pair[1] });
        defer gpa.free(bare);
        try world.git(gpa, io, pair[0], &.{ "config", "remote.origin.pushurl", bare });
    }
    for ([_][]const u8{ "twin/lib/inner", "twin/lib", "twin" }) |path| {
        if (!std.mem.eql(u8, path, "twin")) try world.git(gpa, io, path, &.{ "checkout", "-q", "main" });
        var dir = try world.work.dir.openDir(io, path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "CHANGED", .data = path });
        try world.git(gpa, io, path, &.{ "add", "-A" });
        try world.git(gpa, io, path, &.{ "commit", "-q", "-m", "change" });
    }
}

test "a push goes into the submodules as git's transport_push does: check refuses, on-demand pushes them first, only pushes them alone, a submodule's only is on-demand" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const Case = struct {
        git_args: []const []const u8,
        options: push_mod.Options,
        /// Settings in the superproject, and in `lib`.
        config: []const [2][]const u8 = &.{},
        lib_config: []const [2][]const u8 = &.{},
        refused: ?anyerror = null,
    };
    const cases = [_]Case{
        .{ .git_args = &.{"--recurse-submodules=check"}, .options = .{ .who = test_who, .recurse_submodules = .check }, .refused = error.UnpushedSubmodules },
        .{ .git_args = &.{"--recurse-submodules=on-demand"}, .options = .{ .who = test_who, .recurse_submodules = .on_demand } },
        .{ .git_args = &.{"--recurse-submodules=only"}, .options = .{ .who = test_who, .recurse_submodules = .only } },
        .{ .git_args = &.{}, .options = .{ .who = test_who }, .config = &.{.{ "push.recurseSubmodules", "on-demand" }}, .lib_config = &.{.{ "push.recurseSubmodules", "only" }} },
        .{ .git_args = &.{}, .options = .{ .who = test_who }, .config = &.{.{ "submodule.recurse", "true" }} },
        .{ .git_args = &.{"--no-recurse-submodules"}, .options = .{ .who = test_who, .recurse_submodules = .no }, .config = &.{.{ "push.recurseSubmodules", "check" }} },
    };
    for (cases) |case| {
        var worlds: [2]SubmoduleWorld = .{ try SubmoduleWorld.init(gpa, io), try SubmoduleWorld.init(gpa, io) };
        defer for (&worlds) |*w| w.deinit(gpa);
        for (&worlds) |*world| {
            try changeUnderTwin(gpa, io, world);
            for (case.config) |pair| try world.git(gpa, io, "twin", &.{ "config", pair[0], pair[1] });
            for (case.lib_config) |pair| try world.git(gpa, io, "twin/lib", &.{ "config", pair[0], pair[1] });
        }
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "push", "-q" });
        try argv.appendSlice(gpa, case.git_args);
        var git_dir = try worlds[0].work.dir.openDir(io, "twin", .{});
        defer git_dir.close(io);
        const by_git = testremote.gitInputEnv(gpa, io, git_dir, &env, argv.items, "", false);

        var dir = try worlds[1].work.dir.openDir(io, "twin", .{});
        defer dir.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var options = case.options;
        options.programs = .{ .environ = &env };
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        options.warnings = &warnings;
        const pushed = push_mod.push(gpa, io, &repo, "origin", options);
        if (case.refused) |err| {
            try testing.expectError(error.GitFailed, by_git);
            try testing.expectError(err, pushed);
            try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
        } else {
            gpa.free(try by_git);
            var outcome = try pushed;
            outcome.deinit();
        }
        // Each upstream as git left its own.
        for ([_][]const u8{ "super", "lib", "inner" }) |name| {
            var listed: [2][]u8 = undefined;
            for (&worlds, &listed) |*world, *out| {
                const bare = try gpa.print("{s}/{s}.git", .{ world.root_path, name });
                defer gpa.free(bare);
                var root = try world.work.dir.openDir(io, ".", .{});
                defer root.close(io);
                out.* = try testremote.gitInput(gpa, io, root, &.{ "--git-dir", bare, "for-each-ref", "--format=%(refname) %(objectname)" }, "");
            }
            defer for (listed) |l| gpa.free(l);
            try testing.expectEqualStrings(listed[0], listed[1]);
        }
    }
}

test "a push to a remote group pushes each of its remotes in turn, as git 2.55's push_multiple does, and refuses --atomic across them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    // Two clones of the same history, one pushed from by git and one by
    // relic, each to bare repositories of its own: `a` behind by one,
    // `b` empty, and the group listing `a`, `b` and `a` again.
    for ([_][]const u8{ "git", "relic" }) |who| {
        const clone_path = try gpa.print("{s}/{s}", .{ root_path, who });
        defer gpa.free(clone_path);
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(source_path);
        try source.exec(io, &.{ "clone", "-q", source_path, clone_path });
        for ([_][]const u8{ "a", "b" }) |name| {
            const bare = try gpa.print("{s}/{s}-{s}.git", .{ root_path, who, name });
            defer gpa.free(bare);
            try source.exec(io, &.{ "init", "-q", "--bare", bare });
            if (name[0] == 'a') try source.exec(io, &.{ "push", "-q", bare, "HEAD~1:refs/heads/main" });
            try source.exec(io, &.{ "-C", clone_path, "remote", "add", name, bare });
        }
        try source.exec(io, &.{ "-C", clone_path, "config", "remotes.both", "a b a" });
    }
    var git_clone = try root.dir.openDir(io, "git", .{});
    defer git_clone.close(io);
    const out = try testremote.gitInputEnv(gpa, io, git_clone, &env, &.{ "push", "-q", "both", "main" }, "", true);
    gpa.free(out);
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, git_clone, &env, &.{ "push", "-q", "--atomic", "both", "main" }, "", false));

    var relic_clone = try root.dir.openDir(io, "relic", .{});
    defer relic_clone.close(io);
    var repo = try repo_mod.Repository.open(gpa, io, relic_clone, .{});
    defer repo.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const names = try push_mod.remotesToPush(arena_state.allocator(), repo.configuration(), "both");
    try testing.expectEqual(@as(usize, 3), names.len);
    var many = try push_mod.pushMany(gpa, io, &repo, names, .{ .who = test_who, .refspecs = &.{"main"}, .programs = .{ .environ = &env } });
    defer many.deinit();
    try testing.expect(!many.anyFailed());
    try testing.expectError(error.AtomicAcrossRemotes, push_mod.pushMany(gpa, io, &repo, names, .{ .who = test_who, .refspecs = &.{"main"}, .atomic = true }));
    for ([_][]const u8{ "a", "b" }) |name| {
        var listed: [2][]u8 = undefined;
        for ([_][]const u8{ "git", "relic" }, &listed) |who, *l| {
            const bare = try gpa.print("{s}/{s}-{s}.git", .{ root_path, who, name });
            defer gpa.free(bare);
            l.* = try testremote.gitInput(gpa, io, root.dir, &.{ "--git-dir", bare, "for-each-ref", "--format=%(refname) %(objectname)" }, "");
        }
        defer for (listed) |l| gpa.free(l);
        try testing.expect(listed[0].len != 0);
        try testing.expectEqualStrings(listed[0], listed[1]);
    }
}
