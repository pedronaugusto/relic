//! Transport tests that stand relic beside git: the same fetches, the same
//! ssh arguments, the same credential helpers, over a stand-in ssh and over
//! an HTTP server serving `git http-backend`, each started by the test on
//! this machine.
//!
//! They live apart from `ssh.zig` and `smarthttp.zig` because they drive the
//! operations above those modules, which the modules themselves do not
//! import.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const config_mod = @import("config.zig");
const url_mod = @import("url.zig");
const credential = @import("credential.zig");
const repo_mod = @import("repo.zig");
const fetch_mod = @import("fetch.zig");
const transport = @import("transport.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const test_who: @import("object.zig").Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// A bare copy of a history under a directory an HTTP server serves.
fn servedRepo(gpa: Allocator, io: Io, root: *testing.TmpDir, commits: usize) !void {
    var source = try testremote.historyRepo(gpa, io, commits);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
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
            remote: usize = 0,
            received: u64 = 0,
            indexed: u64 = 0,
            fn report(context: ?*anyopaque, event: @import("progress.zig").Event) void {
                const self_: *@This() = @ptrCast(@alignCast(context.?));
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
    try testing.expect(std.mem.indexOf(u8, log, "GET /moved/repo.git/info/refs?service=git-upload-pack") != null);
    try testing.expect(std.mem.indexOf(u8, log, "POST /repo.git/git-upload-pack") != null);
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
    const secure = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/repo.git", .{server.port});
    defer gpa.free(secure);
    for ([_][]const u8{
        "[http]\nsslVerify = false\n",
        "[http]\nextraHeader = no colon here\n",
        "[http]\nsslCert = /etc/client.pem\n",
        "[http]\nsslCAInfo = /nonexistent/ca.pem\n",
    }, [_]anyerror{
        error.SslVerifyUnsupported,            error.InvalidHttpHeader,
        error.SslClientCertificateUnsupported, error.SslCertificateUnreadable,
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
    const base = try testremote.absolutePath(gpa, io, dir);
    defer gpa.free(base);
    const script = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\echo "== $1" >> "{s}/helper.log"
        \\while IFS= read -r line; do
        \\  echo "$line" >> "{s}/helper.log"
        \\done
        \\if [ "$1" = get ]; then echo username=ada; echo password={s}; fi
        \\
    , .{ base, base, password });
    defer gpa.free(script);
    try dir.writeFile(io, .{ .sub_path = "helper", .data = script });
    const file = try dir.openFile(io, "helper", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
    return std.fmt.allocPrint(gpa, "{s}/helper", .{base});
}

test "credentials come from a helper as git asks for them, are stored when they work and erased when not" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 1);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" } });
    defer server.stop();

    const with_userinfo = try std.fmt.allocPrint(gpa, "http://ada:secret@127.0.0.1:{d}/repo.git", .{server.port});
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
    const base = try testremote.absolutePath(gpa, io, tools.dir);
    defer gpa.free(base);
    const askpass_script = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\echo "$1" >> "{s}/askpass.log"
        \\case "$1" in Username*) echo ada;; *) echo secret;; esac
        \\
    , .{base});
    defer gpa.free(askpass_script);
    try tools.dir.writeFile(io, .{ .sub_path = "askpass", .data = askpass_script });
    {
        const file = try tools.dir.openFile(io, "askpass", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    const askpass = try std.fmt.allocPrint(gpa, "{s}/askpass", .{base});
    defer gpa.free(askpass);
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
        prompts: std.ArrayList(u8) = .empty,
        fn ask(context: ?*anyopaque, allocator: Allocator, field: credential.Field, prompt: []const u8) Allocator.Error!?[]u8 {
            const self_: *@This() = @ptrCast(@alignCast(context.?));
            try self_.prompts.appendSlice(testing.allocator, prompt);
            try self_.prompts.append(testing.allocator, '\n');
            return try allocator.dupe(u8, switch (field) {
                .username => "ada",
                .password => "secret",
            });
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
    const url_port = try std.fmt.allocPrint(gpa, "ssh://ada@example.invalid:2222{s}", .{source_path});
    defer gpa.free(url_port);
    const url_scp = try std.fmt.allocPrint(gpa, "example.invalid:{s}/it's", .{source_path});
    defer gpa.free(url_scp);
    const url_plain = try std.fmt.allocPrint(gpa, "ssh://example.invalid:22{s}", .{source_path});
    defer gpa.free(url_plain);
    const cases = [_]Case{
        .{ .url = url_port },
        .{ .url = url_scp },
        .{ .url = url_plain, .variant = "plink" },
        .{ .url = url_plain, .variant = "ssh" },
    };
    for (cases) |case| {
        tools.dir.deleteFile(io, "fake-ssh.log") catch {};
        var variant_buf: [64]u8 = undefined;
        const variant_setting = if (case.variant) |v| try std.fmt.bufPrint(&variant_buf, "ssh.variant={s}", .{v}) else "ssh.variant=auto";
        here.report_failures = case.variant == null;
        // git's own arguments, from the same stand-in. A plink given a
        // repository it cannot reach fails after it has been started, which
        // is all that is compared.
        if (here.run(io, &.{ "-c", variant_setting, "ls-remote", case.url })) |listed| {
            gpa.free(listed);
        } else |err| if (case.variant == null) return err;
        const theirs = try tools.dir.readFileAlloc(io, "fake-ssh.log", gpa, .unlimited);
        defer gpa.free(theirs);
        tools.dir.deleteFile(io, "fake-ssh.log") catch {};

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.print(gpa, "[core]\nsshCommand = {s}\n[ssh]\nvariant = {s}\n", .{ fake, case.variant orelse "auto" });
        var settings = try @import("config.zig").Config.parseText(gpa, text.items, .local);
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
        const url = try std.fmt.allocPrint(gpa, "ssh://example.invalid{s}", .{source_path});
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

test "a server's own authority, in http.sslCAInfo or http.sslCAPath, is trusted as git trusts it, and nothing else is" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const front = try testremote.TlsFront.start(gpa, io, server.port);
    defer front.stop(io);
    const url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/repo.git", .{front.port});
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
    const scoped = try std.fmt.allocPrint(gpa, "http.https://127.0.0.1:{d}.sslCAInfo", .{front.port});
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
            if (case.key) |key| try r.exec(io, &.{ "config", key, case.value });
        }
        if (case.env) |name| try case_env.put(name, case.value);
        const fetched = try testremote.gitInputEnv(gpa, io, by_git.dir, &case_env, &.{ "fetch", "-q", "origin" }, "", true);
        gpa.free(fetched);
        try relicFetch(gpa, io, by_relic.dir, &case_env);
        try expectSameFetch(gpa, io, &by_git, &by_relic);
    }
}

test "a proxy is gone through as git goes through it, and not for a host no_proxy names; https through one is refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root, 2);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const proxy = try testremote.Proxy.start(gpa, io);
    defer proxy.stop();
    const proxy_url = try proxy.url(gpa);
    defer gpa.free(proxy_url);
    const plain = try server.url(gpa, "repo.git");
    defer gpa.free(plain);

    const Case = struct {
        env: []const [2][]const u8 = &.{},
        config: []const [2][]const u8 = &.{},
        through: bool,
    };
    for ([_]Case{
        .{ .env = &.{.{ "http_proxy", proxy_url }}, .through = true },
        .{ .config = &.{.{ "http.proxy", proxy_url }}, .through = true },
        // curl reads no upper-case HTTP_PROXY, and so neither git nor relic
        // goes through it.
        .{ .env = &.{.{ "HTTP_PROXY", proxy_url }}, .through = false },
        .{ .env = &.{ .{ "http_proxy", proxy_url }, .{ "no_proxy", "127.0.0.1" } }, .through = false },
        .{ .env = &.{.{ "http_proxy", proxy_url }}, .config = &.{.{ "http.proxy", "" }}, .through = false },
    }) |case| {
        var env = try testremote.environ(gpa);
        defer env.deinit();
        for (case.env) |pair| try env.put(pair[0], pair[1]);
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
            try r.exec(io, &.{ "remote", "add", "origin", plain });
            for (case.config) |pair| try r.exec(io, &.{ "config", pair[0], pair[1] });
        }
        const fetched = try testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", true);
        gpa.free(fetched);
        const theirs = try proxy.take(gpa);
        defer gpa.free(theirs);
        try relicFetch(gpa, io, by_relic.dir, &env);
        const ours = try proxy.take(gpa);
        defer gpa.free(ours);
        try expectSameFetch(gpa, io, &by_git, &by_relic);
        try testing.expectEqual(case.through, theirs.len != 0);
        try testing.expectEqual(case.through, ours.len != 0);
        // The first request reaches the proxy in the same words.
        if (case.through) {
            const first_theirs = theirs[0..std.mem.indexOfScalar(u8, theirs, '\n').?];
            const first_ours = ours[0..std.mem.indexOfScalar(u8, ours, '\n').?];
            try testing.expectEqualStrings(first_theirs, first_ours);
        }
    }

    // https through a proxy: refused by name, and nothing reaches it.
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("https_proxy", proxy_url);
    const secure = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/repo.git", .{server.port});
    defer gpa.free(secure);
    try testing.expectError(error.HttpsProxyUnsupported, transport.Session.open(gpa, io, secure, .upload_pack, .sha1, .{ .programs = .{ .environ = &env } }));
    const seen = try proxy.take(gpa);
    defer gpa.free(seen);
    try testing.expectEqualStrings("", seen);
}
