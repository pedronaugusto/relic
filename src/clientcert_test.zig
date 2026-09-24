//! Client certificates, proved against servers that require one: OpenSSL's
//! own `s_server -Verify 1` for relic's TLS client alone, in TLS 1.3 and
//! 1.2, and a TLS front that requires one before `git http-backend`, where
//! git and relic fetch side by side with the same settings and the same
//! credential helper.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const testing = std.testing;

const program = @import("program.zig");
const httpclient = @import("httpclient.zig");
const clientcert = @import("clientcert.zig");
const tls = @import("tls/root.zig");
const repo_mod = @import("repo.zig");
const fetch_mod = @import("fetch.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const test_who: @import("object.zig").Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };
const Pki = testremote.Pki;
const passphrase = testremote.Pki.passphrase;

/// `openssl s_server` requiring a client certificate the test authority
/// signed, answering each request with its status page.
const SServer = struct {
    running: program.Running,
    port: u16,

    fn start(gpa: Allocator, io: Io, pki: *Pki, version: []const u8) !SServer {
        var running = program.start(.{ .environ = &pki.env }, gpa, io, .{
            .argv = &.{
                "openssl", "s_server", "-accept", "127.0.0.1:0",          "-cert",   "server.pem", "-key",  "server.key",
                "-www",    "-Verify",  "1",       "-verify_return_error", "-CAfile", "ca.pem",     version,
            },
            .cwd = .{ .dir = pki.dir.dir },
            .stderr = .ignore,
        }) catch return error.SkipZigTest;
        errdefer running.deinit(io);
        var line_buf: [256]u8 = undefined;
        var reader = running.child.stdout.?.readerStreaming(io, &line_buf);
        while (true) {
            const line = reader.interface.takeDelimiterExclusive('\n') catch return error.SkipZigTest;
            reader.interface.toss(1);
            const prefix = "ACCEPT 127.0.0.1:";
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            const port = std.fmt.parseUnsigned(u16, std.mem.trim(u8, line[prefix.len..], " \r"), 10) catch return error.SkipZigTest;
            return .{ .running = running, .port = port };
        }
    }

    fn stop(s: *SServer, io: Io) void {
        s.running.deinit(io);
    }
};

/// relic's `GET /` to the server on `port`, trusting only `server.pem`:
/// the page, in `gpa`.
fn relicGet(gpa: Allocator, io: Io, pki: *Pki, port: u16, auth: ?*const tls.ClientAuth) ![]u8 {
    var client: httpclient.Client = .init(gpa, io);
    defer client.deinit();
    const server_cert = try pki.path("server.pem");
    defer gpa.free(server_cert);
    try client.trustFile(server_cert);
    client.client_auth = auth;
    var res = try client.send(.GET, .{ .tls = true, .host = "127.0.0.1", .port = port }, "/", &.{}, null);
    defer res.deinit();
    return res.reader().allocRemaining(gpa, .limited(1 << 20)) catch return res.failure();
}

test "relic's TLS client answers OpenSSL's demand for a certificate in TLS 1.3 and 1.2, with RSA, ECDSA and Ed25519 keys, plain and encrypted" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const pki = try Pki.make(gpa, io);
    defer pki.destroy();
    for ([_][]const u8{ "-tls1_3", "-tls1_2" }) |version| {
        var server = try SServer.start(gpa, io, pki, version);
        defer server.stop(io);
        const protocol = if (std.mem.eql(u8, version, "-tls1_3")) "Protocol  : TLSv1.3" else "Protocol  : TLSv1.2";
        for (Pki.kinds) |kind| {
            // RSA answers in PSS, as OpenSSL's own client does.
            const signed_with = if (std.mem.eql(u8, kind, "rsa"))
                "Peer signature type: rsa_pss_rsae_sha256"
            else if (std.mem.eql(u8, kind, "p256"))
                "Peer signature type: ecdsa_secp256r1_sha256"
            else if (std.mem.eql(u8, kind, "p384"))
                "Peer signature type: ecdsa_secp384r1_sha384"
            else
                "Peer signature type: ed25519";
            for ([_]bool{ false, true }) |encrypted| {
                var arena_state: std.heap.ArenaAllocator = .init(gpa);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const cert = try pki.path(try std.fmt.allocPrint(arena, "{s}.pem", .{kind}));
                defer gpa.free(cert);
                const key = try pki.path(try std.fmt.allocPrint(arena, "{s}.{s}", .{ kind, if (encrypted) "enc.key" else "key" }));
                defer gpa.free(key);
                var auth = try clientcert.load(gpa, arena, io, .{ .cert = cert, .key = key }, if (encrypted) passphrase else null);
                defer auth.deinit();
                const page = try relicGet(gpa, io, pki, server.port, &auth);
                defer gpa.free(page);
                try testing.expect(std.mem.indexOf(u8, page, protocol) != null);
                try testing.expect(std.mem.indexOf(u8, page, signed_with) != null);
                try testing.expect(std.mem.indexOf(u8, page, "Verify return code: 0 (ok)") != null);
            }
        }
        // No certificate, and one from an authority the server does not
        // trust, are refused by the server, and named for what they are.
        try testing.expectError(error.ClientCertificateRejected, relicGet(gpa, io, pki, server.port, null));
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const strange = try pki.path("p256.stranger.pem");
        defer gpa.free(strange);
        const strange_key = try pki.path("p256.key");
        defer gpa.free(strange_key);
        var stranger = try clientcert.load(gpa, arena_state.allocator(), io, .{ .cert = strange, .key = strange_key }, null);
        defer stranger.deinit();
        try testing.expectError(error.ClientCertificateRejected, relicGet(gpa, io, pki, server.port, &stranger));
    }
}

/// A bare copy of a history under a directory an HTTP server serves.
fn servedRepo(gpa: Allocator, io: Io, root: *testing.TmpDir) !void {
    var source = try testremote.historyRepo(gpa, io, 2);
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
    const format = "--format=%(refname) %(objectname)";
    const theirs = try by_git.run(io, &.{ "for-each-ref", format });
    defer gpa.free(theirs);
    const ours = try by_relic.run(io, &.{ "for-each-ref", format });
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
    try testing.expect(theirs.len != 0);
}

fn relicFetch(gpa: Allocator, io: Io, dir: Io.Dir, env: *const Environ.Map) !void {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = env } });
    outcome.deinit();
}

/// A credential helper that notes each operation and its input in
/// `<dir>/helper.log` and answers `get` with `answer`.
fn helperScript(gpa: Allocator, io: Io, dir: Io.Dir, answer: []const u8) ![]u8 {
    const base = try testremote.absolutePath(gpa, io, dir);
    defer gpa.free(base);
    const script = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\echo "== $1" >> "{s}/helper.log"
        \\while IFS= read -r line; do
        \\  echo "$line" >> "{s}/helper.log"
        \\done
        \\if [ "$1" = get ]; then echo password={s}; fi
        \\
    , .{ base, base, answer });
    defer gpa.free(script);
    try dir.writeFile(io, .{ .sub_path = "helper", .data = script });
    const file = try dir.openFile(io, "helper", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
    return std.fmt.allocPrint(gpa, "{s}/helper", .{base});
}

/// One side-by-side case: the settings both get, and what relic answers.
const Case = struct {
    kind: []const u8 = "p256",
    /// The certificate's file, `<kind>.pem` when `null`.
    cert: ?[]const u8 = null,
    /// The key's file; none for the key in the certificate's file.
    key: ?[]const u8 = "key",
    /// Ask the helper for the passphrase, and what it answers.
    protected: ?[]const u8 = null,
    /// What relic's fetch fails with, when it does; git fails too.
    refused: ?anyerror = null,
    /// Whether git is left out: a key OpenSSL would ask for on the terminal.
    relic_only: bool = false,
};

test "git and relic fetch from a server that requires a certificate alike: key beside or with the certificate, a passphrase from the helper, and the refusals" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const pki = try Pki.make(gpa, io);
    defer pki.destroy();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const client_ca = try pki.path("ca.pem");
    defer gpa.free(client_ca);

    // A certificate and its key in one file, as curl reads it when no key
    // file is named.
    {
        const cert = try pki.dir.dir.readFileAlloc(io, "rsa.pem", gpa, .unlimited);
        defer gpa.free(cert);
        const key = try pki.dir.dir.readFileAlloc(io, "rsa.key", gpa, .unlimited);
        defer gpa.free(key);
        const both = try std.mem.concat(gpa, u8, &.{ cert, key });
        defer gpa.free(both);
        try pki.dir.dir.writeFile(io, .{ .sub_path = "rsa.both.pem", .data = both });
    }

    for ([_]bool{ false, true }) |tls12| {
        const front = try testremote.TlsFront.startWith(gpa, io, server.port, .{ .client_ca = client_ca, .tls12 = tls12, .rsa = true });
        defer front.stop(io);
        const url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/repo.git", .{front.port});
        defer gpa.free(url);

        for ([_]Case{
            .{ .kind = "rsa" },
            .{ .kind = "p256" },
            .{ .kind = "p384" },
            .{ .kind = "ed25519" },
            .{ .kind = "rsa", .cert = "rsa.both.pem", .key = null },
            .{ .kind = "p256", .key = "enc.key", .protected = passphrase },
            .{ .kind = "p256", .key = "enc.key", .protected = "battery-staple", .refused = error.SslClientKeyPassphraseWrong },
            // Asked for whether the key needs it or not, as git asks.
            .{ .kind = "rsa", .protected = "unused" },
            .{ .kind = "p256", .key = "enc.key", .refused = error.SslClientKeyPassphraseRequired, .relic_only = true },
            .{ .kind = "p256", .cert = "p384.pem", .refused = error.SslClientKeyMismatch },
            .{ .kind = "p256", .cert = "p256.stranger.pem", .refused = error.ClientCertificateRejected },
        }) |case| {
            try sideBySide(gpa, io, pki, front, url, case);
        }
        // No certificate at all.
        try sideBySideWithout(gpa, io, front, url);
    }
}

fn sideBySide(gpa: Allocator, io: Io, pki: *Pki, front: *testremote.TlsFront, url: []const u8, case: Case) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const cert = try pki.path(case.cert orelse try std.fmt.allocPrint(arena, "{s}.pem", .{case.kind}));
    defer gpa.free(cert);
    const key: ?[]u8 = if (case.key) |k| try pki.path(try std.fmt.allocPrint(arena, "{s}.{s}", .{ case.kind, k })) else null;
    defer if (key) |k| gpa.free(k);

    var tools_git = testing.tmpDir(.{ .iterate = true });
    defer tools_git.cleanup();
    var tools_relic = testing.tmpDir(.{ .iterate = true });
    defer tools_relic.cleanup();
    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }, [_]Io.Dir{ tools_git.dir, tools_relic.dir }) |r, tools| {
        try r.exec(io, &.{ "remote", "add", "origin", url });
        try r.exec(io, &.{ "config", "http.sslCAInfo", front.cert_path });
        // curl's OpenSSL backend reads certificates from files; a
        // system's own backend may look in the person's keychain instead.
        try r.exec(io, &.{ "config", "http.sslBackend", "openssl" });
        try r.exec(io, &.{ "config", "http.sslCert", cert });
        if (key) |k| try r.exec(io, &.{ "config", "http.sslKey", k });
        if (case.protected) |answer| {
            try r.exec(io, &.{ "config", "http.sslCertPasswordProtected", "true" });
            const helper = try helperScript(gpa, io, tools, answer);
            defer gpa.free(helper);
            try r.exec(io, &.{ "config", "credential.helper", helper });
        }
    }

    const relic_result = relicFetch(gpa, io, by_relic.dir, &env);
    if (case.refused) |want| {
        try testing.expectError(want, relic_result);
    } else try relic_result;
    if (case.relic_only) return;

    const git_ok = if (testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", false)) |out| blk: {
        gpa.free(out);
        break :blk true;
    } else |_| false;
    if (case.refused != null) {
        try testing.expect(!git_ok);
    } else if (git_ok) {
        try expectSameFetch(gpa, io, &by_git, &by_relic);
    } else {
        // git's TLS library here may not sign with this key — LibreSSL's
        // does not with Ed25519 — where relic's does.
        try testing.expectEqualStrings("ed25519", case.kind);
    }
    if (case.protected != null) {
        const theirs = try tools_git.dir.readFileAlloc(io, "helper.log", gpa, .unlimited);
        defer gpa.free(theirs);
        const ours = try tools_relic.dir.readFileAlloc(io, "helper.log", gpa, .unlimited);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
}

fn sideBySideWithout(gpa: Allocator, io: Io, front: *testremote.TlsFront, url: []const u8) !void {
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    try by_git.exec(io, &.{ "remote", "add", "origin", url });
    try by_git.exec(io, &.{ "config", "http.sslCAInfo", front.cert_path });
    try by_git.exec(io, &.{ "config", "http.sslBackend", "openssl" });
    try testing.expectError(error.ClientCertificateRejected, relicFetch(gpa, io, by_git.dir, &env));
    if (testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", false)) |out| {
        gpa.free(out);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "an https proxy that requires a certificate is answered with http.proxySSLCert and checked against http.proxySSLCAInfo, as git does both" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const pki = try Pki.make(gpa, io);
    defer pki.destroy();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedRepo(gpa, io, &root);
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const proxy = try testremote.Proxy.start(gpa, io, null);
    defer proxy.stop();
    const client_ca = try pki.path("ca.pem");
    defer gpa.free(client_ca);
    // TLS in front of the proxy makes it an https one.
    const front = try testremote.TlsFront.startWith(gpa, io, proxy.port, .{ .client_ca = client_ca });
    defer front.stop(io);
    const proxy_url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}", .{front.port});
    defer gpa.free(proxy_url);
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    const cert = try pki.path("p256.pem");
    defer gpa.free(cert);
    const key = try pki.path("p256.key");
    defer gpa.free(key);

    for ([_]bool{ true, false }) |with_certificate| {
        var env = try testremote.environ(gpa);
        defer env.deinit();
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| {
            try r.exec(io, &.{ "remote", "add", "origin", url });
            try r.exec(io, &.{ "config", "http.proxy", proxy_url });
            try r.exec(io, &.{ "config", "http.proxySSLCAInfo", front.cert_path });
            try r.exec(io, &.{ "config", "http.sslBackend", "openssl" });
            if (with_certificate) {
                try r.exec(io, &.{ "config", "http.proxySSLCert", cert });
                try r.exec(io, &.{ "config", "http.proxySSLKey", key });
            }
        }
        const git_ok = if (testremote.gitInputEnv(gpa, io, by_git.dir, &env, &.{ "fetch", "-q", "origin" }, "", with_certificate)) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |_| false;
        const theirs = try proxy.take(gpa);
        defer gpa.free(theirs);
        const relic_result = relicFetch(gpa, io, by_relic.dir, &env);
        const ours = try proxy.take(gpa);
        defer gpa.free(ours);
        try testing.expectEqual(with_certificate, git_ok);
        if (with_certificate) {
            try relic_result;
            try expectSameFetch(gpa, io, &by_git, &by_relic);
            try testing.expect(ours.len != 0);
            try testing.expectEqualStrings(theirs, ours);
        } else {
            try testing.expectError(error.ClientCertificateRejected, relic_result);
            try testing.expectEqual(@as(usize, 0), ours.len);
        }
    }
}
