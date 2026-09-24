//! Test-only: the remotes the suite starts for itself.
//!
//! No test reaches a network it did not make. A remote here is git's own
//! programs on this machine: `git http-backend` behind an HTTP server the
//! test listens with on 127.0.0.1, `git-upload-pack` and `git-receive-pack`
//! behind a stand-in for `ssh` that ignores the host, and git fed on its
//! standard input when a fixture needs a pack made to order. The library
//! reaches all of them through the same code a real remote meets.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const program = @import("program.zig");
const testgit = @import("testgit.zig");

/// The environment a program started by a test sees: the test's own `PATH`,
/// isolated as `testgit.isolate` isolates git, and nothing else.
pub fn environ(gpa: Allocator) !Environ.Map {
    var map: Environ.Map = .init(gpa);
    errdefer map.deinit();
    const path = std.testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try map.put("PATH", path);
    try testgit.isolate(&map, testgit.no_home);
    return map;
}

/// Run `git` in `dir` with `input` on its standard input and the fixture
/// settings in front of `args`. The output is the caller's; a non-zero exit
/// is `error.GitFailed`, with git's diagnostics printed.
pub fn gitInput(gpa: Allocator, io: Io, dir: Io.Dir, args: []const []const u8, input: []const u8) ![]u8 {
    try testgit.requireGit(gpa, io);
    var env = try environ(gpa);
    defer env.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, &testgit.default_settings);
    try argv.appendSlice(gpa, args);
    var outcome = try program.run(.{ .environ = &env }, gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
    }, input, .{});
    defer gpa.free(outcome.stderr);
    if (!outcome.succeeded()) {
        std.debug.print("git {s} failed:\n{s}\n", .{ args[0], outcome.stderr });
        gpa.free(outcome.stdout);
        return error.GitFailed;
    }
    return outcome.stdout;
}

/// `gitInput` with the environment the caller gives rather than the
/// suite's own. A failure is reported only when `report` says so.
pub fn gitInputEnv(gpa: Allocator, io: Io, dir: Io.Dir, env: *const Environ.Map, args: []const []const u8, input: []const u8, report: bool) ![]u8 {
    try testgit.requireGit(gpa, io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, &testgit.default_settings);
    try argv.appendSlice(gpa, args);
    var outcome = try program.run(.{ .environ = env }, gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
    }, input, .{});
    defer gpa.free(outcome.stderr);
    if (!outcome.succeeded()) {
        if (report) std.debug.print("git {s} failed:\n{s}\n", .{ args[0], outcome.stderr });
        gpa.free(outcome.stdout);
        return error.GitFailed;
    }
    return outcome.stdout;
}

/// The absolute path of `dir`. The result is the caller's.
pub fn absolutePath(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    const path = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    return gpa.dupe(u8, path);
}

/// A history in a real repository, for a remote to be fetched from: files
/// that change a little each commit, a directory, a branch, a lightweight
/// tag and annotated tags, one of them on a commit below a tip.
pub fn historyRepo(gpa: Allocator, io: Io, commits: usize) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    try addCommits(gpa, io, &repo, 0, commits);
    try repo.exec(io, &.{ "tag", "light" });
    try repo.exec(io, &.{ "tag", "-a", "v1", "-m", "version one" });
    if (commits > 1) {
        try repo.exec(io, &.{ "tag", "-a", "old", "-m", "an old one", "HEAD~1" });
        try repo.exec(io, &.{ "branch", "side", "HEAD~1" });
    }
    return repo;
}

/// Add `count` commits to `repo`'s current branch, numbered from `first`.
pub fn addCommits(gpa: Allocator, io: Io, repo: *testgit.Repo, first: usize, count: usize) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..40) |line| try text.print(gpa, "line {d} of a file that is long enough to delta well\n", .{line});
    for (first..first + count) |i| {
        try text.print(gpa, "change {d}\n", .{i});
        try repo.writeFile(io, "src/a.txt", text.items);
        try repo.writeFile(io, "docs/b.md", text.items[0 .. text.items.len / 2]);
        var name_buf: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&name_buf, "files/{d}.txt", .{i}), "new\n");
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) });
    }
}

/// Write a stand-in for `ssh` into `dir` and return its absolute path. It
/// notes each argument it is given in `<itself>.log`, answers OpenSSH's
/// `-G` probe as OpenSSH does, skips the options, ignores the host, and runs
/// the command it was asked to run here — with git's own programs on the
/// path, as a login shell on a server has them. git's test suite does the
/// same.
pub fn fakeSsh(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try dir.writeFile(io, .{ .sub_path = "fake-ssh", .data =
        \\#!/bin/sh
        \\for a in "$@"; do printf '[%s]' "$a" >> "$0.log"; done; echo >> "$0.log"
        \\while [ $# -gt 0 ]; do
        \\  case "$1" in
        \\    -G) exit 0 ;;
        \\    -o|-p|-P) shift 2 ;;
        \\    -*) shift ;;
        \\    *) break ;;
        \\  esac
        \\done
        \\shift
        \\PATH="$(git --exec-path):$PATH" exec sh -c "$*"
        \\
    });
    const file = try dir.openFile(io, "fake-ssh", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
    const base = try absolutePath(gpa, io, dir);
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}/fake-ssh", .{base});
}

/// An HTTP server on 127.0.0.1 that hands every request to
/// `git http-backend` as a CGI program, which is git's own smart HTTP
/// server. Every response closes its connection, so the server takes one
/// connection at a time and never waits on an idle one.
pub const HttpServer = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    port: u16,
    /// `GIT_PROJECT_ROOT`: the directory the URL's path is taken under.
    root: []u8,
    env: Environ.Map,
    options: HttpOptions,
    task: Io.Future(void) = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    /// One line per request: `<method> <target> <auth>`, where `<auth>` is
    /// `auth` when an `Authorization` header came and `-` when not.
    log: std.ArrayList(u8) = .empty,
    log_mutex: Io.Mutex = .init,
    /// How many connections were accepted.
    connections: u32 = 0,

    /// How the server behaves.
    pub const HttpOptions = struct {
        /// Answer 401 unless the request carries this user and password.
        basic_auth: ?struct { user: []const u8, password: []const u8 } = null,
        /// Also accept `Authorization: Bearer <token>`, and offer it in the
        /// 401's challenges after `Basic`.
        bearer: ?[]const u8 = null,
        /// The `text/plain` body of a 401, as a forge explains a refusal.
        refusal_text: ?[]const u8 = null,
        /// Keep a connection open for the next request, as a web server
        /// does; off, every answer closes it.
        keep_alive: bool = false,
        /// Serve upload-pack with this program — relic's own — as git's
        /// HTTP backend runs one, rather than with `git http-backend`.
        upload_pack: ?[]const u8 = null,
        /// Pass the client's `Git-Protocol` header to git. Off, git answers
        /// in v0 whatever the client asks.
        protocol_v2: bool = true,
        /// Answer a `GET` of `/moved/<rest>` with a redirect to `/<rest>`.
        redirect: bool = false,
    };

    /// Listen on an ephemeral port and serve the repositories under `root`.
    pub fn start(gpa: Allocator, io: Io, root: Io.Dir, options: HttpOptions) !*HttpServer {
        try testgit.requireGit(gpa, io);
        const s = try gpa.create(HttpServer);
        errdefer gpa.destroy(s);
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        var env = try environ(gpa);
        errdefer env.deinit();
        const root_path = try absolutePath(gpa, io, root);
        errdefer gpa.free(root_path);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .root = root_path,
            .env = env,
            .options = options,
        };
        s.task = io.concurrent(serve, .{s}) catch return error.SkipZigTest;
        return s;
    }

    /// Stop serving and release everything.
    pub fn stop(s: *HttpServer) void {
        const io = s.io;
        s.stopping.store(true, .release);
        // Wake the accept with a connection of its own.
        const address = Io.net.IpAddress.parse("127.0.0.1", s.port) catch unreachable;
        if (address.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
        s.task.await(io);
        s.listener.deinit(io);
        s.env.deinit();
        s.gpa.free(s.root);
        s.log.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    /// `http://127.0.0.1:<port>/<path>`. The result is the caller's.
    pub fn url(s: *const HttpServer, gpa: Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/{s}", .{ s.port, path });
    }

    /// The requests seen so far, one per line. The result is the caller's.
    pub fn requests(s: *HttpServer, gpa: Allocator) ![]u8 {
        s.log_mutex.lockUncancelable(s.io);
        defer s.log_mutex.unlock(s.io);
        return gpa.dupe(u8, s.log.items);
    }

    fn serve(s: *HttpServer) void {
        while (!s.stopping.load(.acquire)) {
            const stream = s.listener.accept(s.io) catch return;
            defer stream.close(s.io);
            if (s.stopping.load(.acquire)) return;
            s.handle(stream) catch {};
        }
    }

    fn handle(s: *HttpServer, stream: Io.net.Stream) !void {
        const io = s.io;
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        {
            s.log_mutex.lockUncancelable(io);
            defer s.log_mutex.unlock(io);
            s.connections += 1;
        }
        while (true) {
            var request = server.receiveHead() catch return;
            try s.answer(&request);
            if (!s.options.keep_alive) return;
        }
    }

    /// What git's HTTP backend does for upload-pack, with `program` as the
    /// upload-pack: the advertisement for `info/refs`, behind the service
    /// line in v0; one stateless request for a `POST`, inflated first when
    /// it came gzipped.
    fn serveUploadPack(
        s: *HttpServer,
        request: *std.http.Server.Request,
        arena: Allocator,
        program_path: []const u8,
        path: []const u8,
        body: []const u8,
        git_protocol: ?[]const u8,
        content_encoding: ?[]const u8,
    ) !void {
        const io = s.io;
        const info_refs = std.mem.endsWith(u8, path, "/info/refs");
        const repo_path = path[0 .. path.len - (if (info_refs) "/info/refs".len else "/git-upload-pack".len)];
        const full = try std.fmt.allocPrint(arena, "{s}{s}", .{ s.root, repo_path });
        var env = try s.env.clone(arena);
        const v2 = s.options.protocol_v2 and git_protocol != null and std.mem.indexOf(u8, git_protocol.?, "version=2") != null;
        if (v2) try env.put("GIT_PROTOCOL", "version=2");
        var input = body;
        if (content_encoding) |ce| if (std.ascii.eqlIgnoreCase(ce, "gzip")) {
            var in: Io.Reader = .fixed(body);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var inflate: std.compress.flate.Decompress = .init(&in, .gzip, &window);
            input = try inflate.reader.allocRemaining(arena, .limited(1 << 30));
        };
        var outcome = try program.run(.{ .environ = &env }, s.gpa, io, .{
            .argv = &.{ program_path, if (info_refs) "--advertise-refs" else "--stateless-rpc", full },
            .stderr = .capture,
        }, input, .{});
        defer outcome.deinit(s.gpa);
        var answer_bytes: std.ArrayList(u8) = .empty;
        if (info_refs and !v2) try answer_bytes.appendSlice(arena, "001e# service=git-upload-pack\n0000");
        try answer_bytes.appendSlice(arena, outcome.stdout);
        const content_type = if (info_refs) "application/x-git-upload-pack-advertisement" else "application/x-git-upload-pack-result";
        try request.respond(answer_bytes.items, .{
            .keep_alive = s.options.keep_alive,
            .extra_headers = &.{.{ .name = "Content-Type", .value = content_type }},
        });
    }

    fn answer(s: *HttpServer, request: *std.http.Server.Request) !void {
        const io = s.io;
        const gpa = s.gpa;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const method = request.head.method;
        const target = try arena.dupe(u8, request.head.target);
        var git_protocol: ?[]const u8 = null;
        var authorization: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        var content_encoding: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "git-protocol")) git_protocol = try arena.dupe(u8, header.value);
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) authorization = try arena.dupe(u8, header.value);
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) content_type = try arena.dupe(u8, header.value);
            if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) content_encoding = try arena.dupe(u8, header.value);
        }
        {
            s.log_mutex.lockUncancelable(io);
            defer s.log_mutex.unlock(io);
            try s.log.print(gpa, "{s} {s} {s}{s}\n", .{ @tagName(method), target, if (authorization != null) "auth" else "-", if (content_encoding != null) " gzip" else "" });
        }

        const question = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. question orelse target.len];
        const query = if (question) |q| target[q + 1 ..] else "";

        if (s.options.redirect and method == .GET and std.mem.startsWith(u8, path, "/moved/")) {
            const location = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ path["/moved".len..], if (query.len != 0) "?" else "", query });
            return request.respond("", .{ .status = .found, .keep_alive = s.options.keep_alive, .extra_headers = &.{.{ .name = "Location", .value = location }} });
        }

        var remote_user: ?[]const u8 = null;
        if (s.options.basic_auth) |auth| {
            const expected_plain = try std.fmt.allocPrint(arena, "{s}:{s}", .{ auth.user, auth.password });
            const encoder = std.base64.standard.Encoder;
            const expected = try arena.alloc(u8, "Basic ".len + encoder.calcSize(expected_plain.len));
            @memcpy(expected[0.."Basic ".len], "Basic ");
            _ = encoder.encode(expected["Basic ".len..], expected_plain);
            const bearer_ok = if (s.options.bearer) |token| blk: {
                const want = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
                break :blk authorization != null and std.mem.eql(u8, authorization.?, want);
            } else false;
            if (!bearer_ok and (authorization == null or !std.mem.eql(u8, authorization.?, expected))) {
                const basic: std.http.Header = .{ .name = "WWW-Authenticate", .value = "Basic realm=\"relic\"" };
                const bearer: std.http.Header = .{ .name = "WWW-Authenticate", .value = "Bearer realm=\"relic\"" };
                const plain: std.http.Header = .{ .name = "Content-Type", .value = "text/plain" };
                var challenge: std.ArrayList(std.http.Header) = .empty;
                try challenge.append(arena, basic);
                if (s.options.bearer != null) try challenge.append(arena, bearer);
                if (s.options.refusal_text != null) try challenge.append(arena, plain);
                return request.respond(s.options.refusal_text orelse "", .{ .status = .unauthorized, .keep_alive = s.options.keep_alive, .extra_headers = challenge.items });
            }
            remote_user = auth.user;
        }

        var body: []const u8 = "";
        if (method == .POST) {
            var body_buffer: [8192]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buffer);
            body = try body_reader.allocRemaining(arena, .limited(1 << 30));
        }

        if (s.options.upload_pack) |program_path| {
            if (std.mem.endsWith(u8, path, "/info/refs") and std.mem.eql(u8, query, "service=git-upload-pack") or
                std.mem.endsWith(u8, path, "/git-upload-pack"))
            {
                return s.serveUploadPack(request, arena, program_path, path, body, git_protocol, content_encoding);
            }
        }

        var cgi_env = try s.env.clone(arena);
        try cgi_env.put("GIT_PROJECT_ROOT", s.root);
        try cgi_env.put("GIT_HTTP_EXPORT_ALL", "1");
        try cgi_env.put("PATH_INFO", path);
        try cgi_env.put("REQUEST_METHOD", @tagName(method));
        try cgi_env.put("QUERY_STRING", query);
        try cgi_env.put("REMOTE_ADDR", "127.0.0.1");
        if (content_type) |ct| try cgi_env.put("CONTENT_TYPE", ct);
        if (content_encoding) |ce| try cgi_env.put("HTTP_CONTENT_ENCODING", ce);
        if (method == .POST) try cgi_env.put("CONTENT_LENGTH", try std.fmt.allocPrint(arena, "{d}", .{body.len}));
        if (s.options.protocol_v2) {
            if (git_protocol) |value| try cgi_env.put("GIT_PROTOCOL", value);
        }
        if (remote_user) |user| try cgi_env.put("REMOTE_USER", user);

        var outcome = try program.run(.{ .environ = &cgi_env }, gpa, io, .{
            .argv = &.{ "git", "http-backend" },
            .stderr = .capture,
        }, body, .{});
        defer outcome.deinit(gpa);
        const output = outcome.stdout;
        const split = std.mem.indexOf(u8, output, "\r\n\r\n") orelse return error.MalformedCgiResponse;
        var status: u16 = 200;
        var response_headers: std.ArrayList(std.http.Header) = .empty;
        var lines = std.mem.splitSequence(u8, output[0..split], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "status")) {
                status = std.fmt.parseInt(u16, value[0..3], 10) catch 500;
            } else try response_headers.append(arena, .{ .name = name, .value = value });
        }
        try request.respond(output[split + 4 ..], .{
            .status = @enumFromInt(status),
            .keep_alive = s.options.keep_alive,
            .extra_headers = response_headers.items,
        });
    }
};

/// A TLS front for a server on this machine: `python3`'s `ssl` module
/// terminating TLS on 127.0.0.1 with a certificate made here by `openssl`
/// for `127.0.0.1`, and handing the bytes to `backend_port`. The standard
/// library has a TLS client and no TLS server, and a test of what a client
/// trusts needs one. `error.SkipZigTest` where either program is missing.
pub const TlsFront = struct {
    gpa: Allocator,
    running: program.Running,
    env: Environ.Map,
    dir: std.testing.TmpDir,
    /// The port TLS is served on.
    port: u16,
    /// The certificate, which is its own authority: a PEM file.
    cert_path: []u8,
    /// A directory holding the certificate under its OpenSSL hash name,
    /// as `http.sslCAPath` wants one.
    ca_dir: []u8,

    const script =
        \\import select, socket, ssl, sys, threading
        \\cert, key, backend = sys.argv[1], sys.argv[2], int(sys.argv[3])
        \\client_ca, version = sys.argv[4], sys.argv[5]
        \\ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        \\ctx.load_cert_chain(cert, key)
        \\if client_ca:
        \\    ctx.verify_mode = ssl.CERT_REQUIRED
        \\    ctx.load_verify_locations(client_ca)
        \\if version == "1.2":
        \\    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
        \\ls = socket.socket()
        \\ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        \\ls.bind(("127.0.0.1", 0))
        \\ls.listen(16)
        \\print(ls.getsockname()[1], flush=True)
        \\# One thread per connection, and one TLS state used by it alone.
        \\def serve(c):
        \\    try: s = ctx.wrap_socket(c, server_side=True)
        \\    except Exception:
        \\        # The alert is sent; close without a reset, which would
        \\        # take it from the client before it is read.
        \\        try:
        \\            c.shutdown(socket.SHUT_WR); c.settimeout(5)
        \\            while c.recv(65536): pass
        \\        except Exception: pass
        \\        c.close(); return
        \\    u = socket.create_connection(("127.0.0.1", backend))
        \\    try:
        \\        while True:
        \\            ready = [s] if s.pending() else select.select([s, u], [], [])[0]
        \\            if s in ready:
        \\                d = s.recv(65536)
        \\                if not d: break
        \\                u.sendall(d)
        \\            if u in ready:
        \\                d = u.recv(65536)
        \\                if not d: break
        \\                s.sendall(d)
        \\    except Exception: pass
        \\    s.close(); u.close()
        \\while True:
        \\    c, _ = ls.accept()
        \\    threading.Thread(target=serve, args=(c,), daemon=True).start()
        \\
    ;

    /// How the front is set up besides its certificate.
    pub const Options = struct {
        /// Require a client certificate signed by the authority in this
        /// PEM file.
        client_ca: ?[]const u8 = null,
        /// Speak TLS 1.2 at most.
        tls12: bool = false,
        /// An RSA key for the front's own certificate, which TLS 1.2 needs
        /// for the ECDHE-RSA suites relic's client speaks.
        rsa: bool = false,
    };

    /// Make a certificate and start serving TLS in front of `backend_port`.
    pub fn start(gpa: Allocator, io: Io, backend_port: u16) !*TlsFront {
        return startWith(gpa, io, backend_port, .{});
    }

    /// `start`, set up as `options` says.
    pub fn startWith(gpa: Allocator, io: Io, backend_port: u16, options: Options) !*TlsFront {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const f = try gpa.create(TlsFront);
        errdefer gpa.destroy(f);
        var env = try environ(gpa);
        errdefer env.deinit();
        var dir = std.testing.tmpDir(.{ .iterate = true });
        errdefer dir.cleanup();
        const base = try absolutePath(gpa, io, dir.dir);
        defer gpa.free(base);
        const cert_path = try std.fs.path.join(gpa, &.{ base, "cert.pem" });
        errdefer gpa.free(cert_path);
        const key_path = try std.fs.path.join(gpa, &.{ base, "key.pem" });
        defer gpa.free(key_path);
        const ca_dir = try std.fs.path.join(gpa, &.{ base, "ca" });
        errdefer gpa.free(ca_dir);

        // An EC key, which the standard library's TLS client verifies, and
        // the address as both an IP and a DNS name: curl matches the first,
        // the standard library the second. `lfs.example.invalid` is the name
        // a test reaches it by through a proxy.
        var made = program.run(.{ .environ = &env }, gpa, io, .{ .argv = &.{
            "openssl",                             "req",                                                               "-x509",                                                                     "-newkey",
            if (options.rsa) "rsa:2048" else "ec", "-pkeyopt",                                                          if (options.rsa) "rsa_keygen_bits:2048" else "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout",                             key_path,                                                            "-out",                                                                      cert_path,
            "-days",                               "2",                                                                 "-subj",                                                                     "/CN=127.0.0.1",
            "-addext",                             "subjectAltName=IP:127.0.0.1,DNS:127.0.0.1,DNS:lfs.example.invalid",
        } }, "", .{}) catch return error.SkipZigTest;
        defer made.deinit(gpa);
        if (!made.succeeded()) return error.SkipZigTest;
        try dir.dir.createDirPath(io, "ca");
        try dir.dir.copyFile("cert.pem", dir.dir, "ca/cert.pem", io, .{});
        var rehash = program.run(.{ .environ = &env }, gpa, io, .{ .argv = &.{ "openssl", "rehash", ca_dir } }, "", .{}) catch null;
        if (rehash) |*r| r.deinit(gpa);

        var port_buf: [8]u8 = undefined;
        const backend = try std.fmt.bufPrint(&port_buf, "{d}", .{backend_port});
        var running = program.start(.{ .environ = &env }, gpa, io, .{
            .argv = &.{ "python3", "-c", script, cert_path, key_path, backend, options.client_ca orelse "", if (options.tls12) "1.2" else "" },
            .stderr = .ignore,
        }) catch return error.SkipZigTest;
        errdefer running.deinit(io);
        var line_buf: [32]u8 = undefined;
        var reader = running.child.stdout.?.readerStreaming(io, &line_buf);
        const line = reader.interface.takeDelimiterExclusive('\n') catch return error.SkipZigTest;
        const port = std.fmt.parseUnsigned(u16, std.mem.trim(u8, line, " \r"), 10) catch return error.SkipZigTest;
        f.* = .{ .gpa = gpa, .running = running, .env = env, .dir = dir, .port = port, .cert_path = cert_path, .ca_dir = ca_dir };
        return f;
    }

    /// Stop serving and release everything.
    pub fn stop(f: *TlsFront, io: Io) void {
        f.running.deinit(io);
        f.env.deinit();
        f.gpa.free(f.cert_path);
        f.gpa.free(f.ca_dir);
        f.dir.cleanup();
        f.gpa.destroy(f);
    }
};

/// Certificates made for one test by `openssl`: an authority for clients,
/// a stranger no server trusts, a server certificate for 127.0.0.1, and
/// for each kind of key a client certificate the authority signed, the key
/// plain and encrypted, and one the stranger signed.
pub const Pki = struct {
    gpa: Allocator,
    dir: std.testing.TmpDir,
    base: []u8,
    env: Environ.Map,

    /// The kinds of key: RSA, ECDSA on P-256 and P-384, Ed25519.
    pub const kinds = [_][]const u8{ "rsa", "p256", "p384", "ed25519" };
    /// What every encrypted key opens with.
    pub const passphrase = "correct-horse";

    /// Make them all in a new temporary directory. `error.SkipZigTest`
    /// without `openssl`.
    pub fn make(gpa: Allocator, io: Io) !*Pki {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const p = try gpa.create(Pki);
        errdefer gpa.destroy(p);
        var env = try environ(gpa);
        errdefer env.deinit();
        var dir = std.testing.tmpDir(.{ .iterate = true });
        errdefer dir.cleanup();
        const base = try absolutePath(gpa, io, dir.dir);
        p.* = .{ .gpa = gpa, .dir = dir, .base = base, .env = env };
        errdefer gpa.free(base);
        try p.openssl(io, &.{ "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2", "-subj", "/CN=relic-test-ca" });
        try p.openssl(io, &.{ "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "stranger.key", "-out", "stranger.pem", "-days", "2", "-subj", "/CN=relic-test-stranger" });
        try p.openssl(io, &.{ "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.pem", "-days", "2", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1,DNS:127.0.0.1" });
        for (kinds) |kind| {
            const key = try std.fmt.allocPrint(gpa, "{s}.key", .{kind});
            defer gpa.free(key);
            const csr = try std.fmt.allocPrint(gpa, "{s}.csr", .{kind});
            defer gpa.free(csr);
            const cert = try std.fmt.allocPrint(gpa, "{s}.pem", .{kind});
            defer gpa.free(cert);
            const strange = try std.fmt.allocPrint(gpa, "{s}.stranger.pem", .{kind});
            defer gpa.free(strange);
            const enc = try std.fmt.allocPrint(gpa, "{s}.enc.key", .{kind});
            defer gpa.free(enc);
            const subject = try std.fmt.allocPrint(gpa, "/CN=client-{s}", .{kind});
            defer gpa.free(subject);
            const algorithm: []const []const u8 = if (std.mem.eql(u8, kind, "rsa"))
                &.{ "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048" }
            else if (std.mem.eql(u8, kind, "p256"))
                &.{ "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256" }
            else if (std.mem.eql(u8, kind, "p384"))
                &.{ "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384" }
            else
                &.{ "-algorithm", "ED25519" };
            var genpkey: std.ArrayList([]const u8) = .empty;
            defer genpkey.deinit(gpa);
            try genpkey.append(gpa, "genpkey");
            try genpkey.appendSlice(gpa, algorithm);
            try genpkey.appendSlice(gpa, &.{ "-out", key });
            try p.openssl(io, genpkey.items);
            try p.openssl(io, &.{ "req", "-new", "-key", key, "-subj", subject, "-out", csr });
            try p.openssl(io, &.{ "x509", "-req", "-in", csr, "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "7", "-days", "2", "-out", cert });
            try p.openssl(io, &.{ "x509", "-req", "-in", csr, "-CA", "stranger.pem", "-CAkey", "stranger.key", "-set_serial", "8", "-days", "2", "-out", strange });
            try p.openssl(io, &.{ "pkcs8", "-topk8", "-in", key, "-v2", "aes-256-cbc", "-passout", "pass:" ++ passphrase, "-out", enc });
        }
        // OpenSSL's older encrypted PEM, the only encrypted key git-lfs reads.
        try p.openssl(io, &.{ "rsa", "-in", "rsa.key", "-traditional", "-aes256", "-passout", "pass:" ++ passphrase, "-out", "rsa.legacy.key" });
        try p.openssl(io, &.{ "ec", "-in", "p256.key", "-aes128", "-passout", "pass:" ++ passphrase, "-out", "p256.legacy.key" });
        return p;
    }

    fn openssl(p: *Pki, io: Io, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(p.gpa);
        try argv.append(p.gpa, "openssl");
        try argv.appendSlice(p.gpa, args);
        var made = program.run(.{ .environ = &p.env }, p.gpa, io, .{
            .argv = argv.items,
            .cwd = .{ .dir = p.dir.dir },
        }, "", .{}) catch return error.SkipZigTest;
        defer made.deinit(p.gpa);
        if (!made.succeeded()) return error.SkipZigTest;
    }

    /// The absolute path of `name`, in `gpa`.
    pub fn path(p: *const Pki, name: []const u8) ![]u8 {
        return std.fs.path.join(p.gpa, &.{ p.base, name });
    }

    /// Remove them all.
    pub fn destroy(p: *Pki) void {
        p.env.deinit();
        p.dir.cleanup();
        p.gpa.free(p.base);
        p.gpa.destroy(p);
    }
};

/// A proxy on 127.0.0.1, as a company runs one: `CONNECT host:port` opens a
/// tunnel, and a request with an absolute URL is passed on to its host. It
/// notes each request's first line, so a test can say what went through it.
/// One connection at a time; every server the suite starts closes its
/// connections after one answer.
pub const Proxy = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    port: u16,
    task: Io.Future(void) = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    log: std.ArrayList(u8) = .empty,
    log_mutex: Io.Mutex = .init,
    /// Every `CONNECT`'s whole head, its user agent's version left out.
    connects: std.ArrayList(u8) = .empty,
    /// The first bytes the client sent inside each tunnel, up to 512.
    tunnel_starts: std.ArrayList([]u8) = .empty,
    /// `user:password` the proxy requires with `Proxy-Authorization: Basic`,
    /// answering 407 without it.
    basic: ?[]const u8 = null,
    /// How the proxy asks for `basic`'s credentials: Basic, or Digest with
    /// `qop=auth` and the algorithm named.
    scheme: enum { basic, digest_md5, digest_sha256 } = .basic,
    /// Every request's method and how it was answered for — `none`,
    /// `basic`, `digest` — and whether that was taken, one to a line.
    auth_log: std.ArrayList(u8) = .empty,

    /// Listen on an ephemeral port. With `basic`, a request without those
    /// credentials is answered 407.
    pub fn start(gpa: Allocator, io: Io, basic: ?[]const u8) !*Proxy {
        return startAsking(gpa, io, basic, .basic);
    }

    /// `start`, asking for `basic`'s credentials in `scheme`.
    pub fn startAsking(gpa: Allocator, io: Io, basic: ?[]const u8, scheme: @FieldType(Proxy, "scheme")) !*Proxy {
        const p = try gpa.create(Proxy);
        errdefer gpa.destroy(p);
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        p.* = .{ .gpa = gpa, .io = io, .listener = listener, .port = listener.socket.address.getPort(), .basic = basic, .scheme = scheme };
        p.task = io.concurrent(serve, .{p}) catch return error.SkipZigTest;
        return p;
    }

    /// Stop and release everything.
    pub fn stop(p: *Proxy) void {
        const io = p.io;
        p.stopping.store(true, .release);
        const address = Io.net.IpAddress.parse("127.0.0.1", p.port) catch unreachable;
        if (address.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
        p.task.await(io);
        p.listener.deinit(io);
        p.log.deinit(p.gpa);
        p.auth_log.deinit(p.gpa);
        p.connects.deinit(p.gpa);
        for (p.tunnel_starts.items) |b| p.gpa.free(b);
        p.tunnel_starts.deinit(p.gpa);
        p.gpa.destroy(p);
    }

    /// `http://127.0.0.1:<port>`. The result is the caller's.
    pub fn url(p: *const Proxy, gpa: Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{p.port});
    }

    /// The first line of every request so far, one per line, and forget
    /// them. The result is the caller's.
    pub fn take(p: *Proxy, gpa: Allocator) ![]u8 {
        p.log_mutex.lockUncancelable(p.io);
        defer p.log_mutex.unlock(p.io);
        defer p.log.clearRetainingCapacity();
        return gpa.dupe(u8, p.log.items);
    }

    /// Every `CONNECT` head so far, with a `User-Agent: git/` line's value
    /// cut after `git/`, and forget them. The result is the caller's.
    pub fn takeConnects(p: *Proxy, gpa: Allocator) ![]u8 {
        p.log_mutex.lockUncancelable(p.io);
        defer p.log_mutex.unlock(p.io);
        defer p.connects.clearRetainingCapacity();
        return gpa.dupe(u8, p.connects.items);
    }

    /// Check that every tunnel so far carried TLS from its first byte — a
    /// handshake record, `0x16 0x03` — and no request line in the clear,
    /// and forget them. Returns how many there were.
    pub fn expectTlsInTunnels(p: *Proxy) !usize {
        p.log_mutex.lockUncancelable(p.io);
        defer p.log_mutex.unlock(p.io);
        defer {
            for (p.tunnel_starts.items) |b| p.gpa.free(b);
            p.tunnel_starts.clearRetainingCapacity();
        }
        for (p.tunnel_starts.items) |bytes| {
            try std.testing.expect(bytes.len >= 2);
            try std.testing.expectEqual(@as(u8, 0x16), bytes[0]);
            try std.testing.expectEqual(@as(u8, 0x03), bytes[1]);
            try std.testing.expect(std.mem.indexOf(u8, bytes, " HTTP/1.") == null);
        }
        return p.tunnel_starts.items.len;
    }

    /// The auth log so far, and forget it. The result is the caller's.
    pub fn takeAuth(p: *Proxy, gpa: Allocator) ![]u8 {
        p.log_mutex.lockUncancelable(p.io);
        defer p.log_mutex.unlock(p.io);
        defer p.auth_log.clearRetainingCapacity();
        return gpa.dupe(u8, p.auth_log.items);
    }

    const digest_nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093";

    /// Whether `value` is a Digest answer to this proxy's challenge for
    /// `method` to `target`, worked out here from RFC 7616 alone.
    fn digestTaken(p: *Proxy, value: []const u8, method: []const u8, target: []const u8, credentials: []const u8) bool {
        var params: [16][2][]const u8 = undefined;
        var n: usize = 0;
        var rest = value["Digest ".len..];
        while (rest.len != 0 and n < params.len) {
            rest = std.mem.trimStart(u8, rest, " ,");
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break;
            const key = rest[0..eq];
            rest = rest[eq + 1 ..];
            var v: []const u8 = undefined;
            if (rest.len != 0 and rest[0] == '"') {
                const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return false;
                v = rest[1..end];
                rest = rest[end + 1 ..];
            } else {
                const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
                v = rest[0..end];
                rest = rest[end..];
            }
            params[n] = .{ key, v };
            n += 1;
        }
        const get = struct {
            fn of(list: []const [2][]const u8, key: []const u8) ?[]const u8 {
                for (list) |kv| if (std.mem.eql(u8, kv[0], key)) return kv[1];
                return null;
            }
        }.of;
        const list = params[0..n];
        const colon = std.mem.indexOfScalar(u8, credentials, ':').?;
        const user = credentials[0..colon];
        const password = credentials[colon + 1 ..];
        if (!std.mem.eql(u8, get(list, "username") orelse return false, user)) return false;
        if (!std.mem.eql(u8, get(list, "realm") orelse return false, "proxy")) return false;
        if (!std.mem.eql(u8, get(list, "nonce") orelse return false, digest_nonce)) return false;
        // curl names a request handed over whole by its path.
        const uri = if (std.mem.startsWith(u8, target, "http://")) blk: {
            const slash = std.mem.indexOfScalarPos(u8, target, "http://".len, '/') orelse target.len;
            break :blk target[slash..];
        } else target;
        if (!std.mem.eql(u8, get(list, "uri") orelse return false, uri)) return false;
        if (!std.mem.eql(u8, get(list, "qop") orelse return false, "auth")) return false;
        const nc = get(list, "nc") orelse return false;
        const cnonce = get(list, "cnonce") orelse return false;
        const given = get(list, "response") orelse return false;
        var buf: [4][128]u8 = undefined;
        const Hashes = struct {
            fn hex(sha256: bool, out: *[128]u8, parts: []const []const u8) []const u8 {
                if (sha256) {
                    var h = std.crypto.hash.sha2.Sha256.init(.{});
                    for (parts) |part| h.update(part);
                    const d = h.finalResult();
                    const x = std.fmt.bytesToHex(d, .lower);
                    @memcpy(out[0..x.len], &x);
                    return out[0..x.len];
                }
                var h = std.crypto.hash.Md5.init(.{});
                for (parts) |part| h.update(part);
                var d: [16]u8 = undefined;
                h.final(&d);
                const x = std.fmt.bytesToHex(d, .lower);
                @memcpy(out[0..x.len], &x);
                return out[0..x.len];
            }
        };
        const sha = p.scheme == .digest_sha256;
        const ha1 = Hashes.hex(sha, &buf[0], &.{ user, ":proxy:", password });
        const ha2 = Hashes.hex(sha, &buf[1], &.{ method, ":", uri });
        const want = Hashes.hex(sha, &buf[2], &.{ ha1, ":", digest_nonce, ":", nc, ":", cnonce, ":auth:", ha2 });
        return std.mem.eql(u8, want, given);
    }

    fn serve(p: *Proxy) void {
        while (!p.stopping.load(.acquire)) {
            const stream = p.listener.accept(p.io) catch return;
            defer stream.close(p.io);
            if (p.stopping.load(.acquire)) return;
            p.handle(stream) catch {};
        }
    }

    fn handle(p: *Proxy, client: Io.net.Stream) !void {
        const io = p.io;
        var client_read: [16 * 1024]u8 = undefined;
        var client_write: [16 * 1024]u8 = undefined;
        var from_client = client.reader(io, &client_read);
        var to_client = client.writer(io, &client_write);
        // The request's head.
        var head_len: usize = 0;
        while (true) {
            const seen = from_client.interface.buffered();
            if (std.mem.indexOf(u8, seen, "\r\n\r\n")) |end| {
                head_len = end + 4;
                break;
            }
            try from_client.interface.fillMore();
        }
        const head = from_client.interface.buffered()[0..head_len];
        const line_end = std.mem.indexOf(u8, head, "\r\n").?;
        const first = head[0..line_end];
        var words = std.mem.tokenizeScalar(u8, first, ' ');
        const method = words.next() orelse return error.BadRequest;
        const target = words.next() orelse return error.BadRequest;
        {
            p.log_mutex.lockUncancelable(io);
            defer p.log_mutex.unlock(io);
            try p.log.print(p.gpa, "{s} {s}\n", .{ method, target });
            if (std.mem.eql(u8, method, "CONNECT")) {
                var lines = std.mem.splitSequence(u8, head, "\r\n");
                while (lines.next()) |line| {
                    const agent = "User-Agent: git/";
                    const kept = if (std.mem.startsWith(u8, line, agent)) agent else line;
                    try p.connects.print(p.gpa, "{s}\n", .{kept});
                }
            }
        }
        if (p.basic) |credentials| {
            var expected_buf: [256]u8 = undefined;
            const encoder = std.base64.standard.Encoder;
            const encoded = encoder.encode(&expected_buf, credentials);
            var authorized = false;
            var given: []const u8 = "none";
            var lines = std.mem.splitSequence(u8, head, "\r\n");
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (!std.ascii.eqlIgnoreCase(line[0..colon], "proxy-authorization")) continue;
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                if (std.mem.startsWith(u8, value, "Basic ")) {
                    given = "basic";
                    if (p.scheme == .basic and std.mem.eql(u8, value["Basic ".len..], encoded)) authorized = true;
                } else if (std.mem.startsWith(u8, value, "Digest ")) {
                    given = "digest";
                    if (p.scheme != .basic and p.digestTaken(value, method, target, credentials)) authorized = true;
                } else given = "other";
            }
            {
                p.log_mutex.lockUncancelable(io);
                defer p.log_mutex.unlock(io);
                try p.auth_log.print(p.gpa, "{s} {s} {s}\n", .{ method, given, if (authorized) "taken" else "refused" });
            }
            if (!authorized) {
                const challenge = switch (p.scheme) {
                    .basic => "Basic realm=\"proxy\"",
                    .digest_md5 => "Digest realm=\"proxy\", nonce=\"" ++ digest_nonce ++ "\", qop=\"auth\", algorithm=MD5",
                    .digest_sha256 => "Digest realm=\"proxy\", nonce=\"" ++ digest_nonce ++ "\", qop=\"auth\", algorithm=SHA-256",
                };
                try to_client.interface.print("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{challenge});
                try to_client.interface.flush();
                return;
            }
        }

        var host_port: []const u8 = undefined;
        var rewritten: ?[]const u8 = null;
        var line_buf: [4096]u8 = undefined;
        if (std.mem.eql(u8, method, "CONNECT")) {
            host_port = target;
        } else {
            const prefix = "http://";
            if (!std.mem.startsWith(u8, target, prefix)) return error.BadRequest;
            const rest = target[prefix.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            host_port = rest[0..slash];
            rewritten = try std.fmt.bufPrint(&line_buf, "{s} {s} {s}", .{ method, if (slash < rest.len) rest[slash..] else "/", words.rest() });
        }
        const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.BadRequest;
        const port = try std.fmt.parseUnsigned(u16, host_port[colon + 1 ..], 10);
        // A name that is not an address is this machine: a test names a
        // host no resolver knows, for a client to send through the proxy.
        const address = Io.net.IpAddress.parse(host_port[0..colon], port) catch try Io.net.IpAddress.parse("127.0.0.1", port);
        const upstream = try address.connect(io, .{ .mode = .stream });
        defer upstream.close(io);
        var up_read: [16 * 1024]u8 = undefined;
        var up_write: [16 * 1024]u8 = undefined;
        var from_up = upstream.reader(io, &up_read);
        var to_up = upstream.writer(io, &up_write);

        if (rewritten) |line| {
            try to_up.interface.writeAll(line);
            try to_up.interface.writeAll(head[line_end..]);
        } else {
            try to_client.interface.writeAll("HTTP/1.1 200 Connection established\r\n\r\n");
            try to_client.interface.flush();
        }
        from_client.interface.toss(head_len);
        if (rewritten == null) {
            // What the client says first inside the tunnel.
            while (from_client.interface.bufferedLen() < 5) from_client.interface.fillMore() catch break;
            const seen = from_client.interface.buffered();
            const kept = try p.gpa.dupe(u8, seen[0..@min(seen.len, 512)]);
            p.log_mutex.lockUncancelable(io);
            defer p.log_mutex.unlock(io);
            p.tunnel_starts.append(p.gpa, kept) catch |err| {
                p.gpa.free(kept);
                return err;
            };
        }
        try to_up.interface.writeAll(from_client.interface.buffered());
        from_client.interface.tossBuffered();
        try to_up.interface.flush();

        var upward = try io.concurrent(copy, .{ &from_client.interface, &to_up.interface });
        copy(&from_up.interface, &to_client.interface);
        upward.cancel(io);
    }

    fn copy(from: *Io.Reader, to: *Io.Writer) void {
        while (true) {
            from.fillMore() catch return;
            to.writeAll(from.buffered()) catch return;
            from.tossBuffered();
            to.flush() catch return;
        }
    }
};
