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

    /// How the server behaves.
    pub const HttpOptions = struct {
        /// Answer 401 unless the request carries this user and password.
        basic_auth: ?struct { user: []const u8, password: []const u8 } = null,
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
        const gpa = s.gpa;
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const method = request.head.method;
        const target = try arena.dupe(u8, request.head.target);
        var git_protocol: ?[]const u8 = null;
        var authorization: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "git-protocol")) git_protocol = try arena.dupe(u8, header.value);
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) authorization = try arena.dupe(u8, header.value);
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) content_type = try arena.dupe(u8, header.value);
        }
        {
            s.log_mutex.lockUncancelable(io);
            defer s.log_mutex.unlock(io);
            try s.log.print(gpa, "{s} {s} {s}\n", .{ @tagName(method), target, if (authorization != null) "auth" else "-" });
        }

        const question = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. question orelse target.len];
        const query = if (question) |q| target[q + 1 ..] else "";

        if (s.options.redirect and method == .GET and std.mem.startsWith(u8, path, "/moved/")) {
            const location = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ path["/moved".len..], if (query.len != 0) "?" else "", query });
            return request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "Location", .value = location }} });
        }

        var remote_user: ?[]const u8 = null;
        if (s.options.basic_auth) |auth| {
            const expected_plain = try std.fmt.allocPrint(arena, "{s}:{s}", .{ auth.user, auth.password });
            const encoder = std.base64.standard.Encoder;
            const expected = try arena.alloc(u8, "Basic ".len + encoder.calcSize(expected_plain.len));
            @memcpy(expected[0.."Basic ".len], "Basic ");
            _ = encoder.encode(expected["Basic ".len..], expected_plain);
            if (authorization == null or !std.mem.eql(u8, authorization.?, expected)) {
                return request.respond("", .{ .status = .unauthorized, .keep_alive = false, .extra_headers = &.{.{ .name = "WWW-Authenticate", .value = "Basic realm=\"relic\"" }} });
            }
            remote_user = auth.user;
        }

        var body: []const u8 = "";
        if (method == .POST) {
            var body_buffer: [8192]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buffer);
            body = try body_reader.allocRemaining(arena, .limited(1 << 30));
        }

        var cgi_env = try s.env.clone(arena);
        try cgi_env.put("GIT_PROJECT_ROOT", s.root);
        try cgi_env.put("GIT_HTTP_EXPORT_ALL", "1");
        try cgi_env.put("PATH_INFO", path);
        try cgi_env.put("REQUEST_METHOD", @tagName(method));
        try cgi_env.put("QUERY_STRING", query);
        try cgi_env.put("REMOTE_ADDR", "127.0.0.1");
        if (content_type) |ct| try cgi_env.put("CONTENT_TYPE", ct);
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
            .keep_alive = false,
            .extra_headers = response_headers.items,
        });
    }
};
