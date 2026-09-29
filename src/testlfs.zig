//! Test-only: an LFS server the suite starts for itself, and the stand-ins
//! the person's credential helper and ssh are replaced with.
//!
//! The server listens on 127.0.0.1 and speaks the Git LFS API as a hosting
//! service speaks it: the batch endpoint, the basic transfer adapter with a
//! verify action, and the locking API, with the lock's owner the person the
//! request authenticated as — by a basic credential, or by the token a
//! stand-in `git-lfs-authenticate` hands out. Every other path is handed to
//! `git http-backend`, so one server is the whole remote: git fetches and
//! pushes through it and git-lfs and relic find its LFS API where they derive
//! it from the remote's URL. Faults are queued by the test — a status, a
//! `Retry-After` — for the requests they are meant for.
//!
//! Nothing here reaches a person's own setup. Every program the suite runs
//! for these tests starts from `environ`: the test's `PATH`, a home
//! directory of its own, no system configuration, no terminal prompt.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const http = std.http;

const program = @import("program.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

/// The environment a program started by these tests sees: the test's
/// `PATH`, `home` as its home directory, no system configuration and no
/// terminal to prompt on. Nothing of the person's own configuration, agents
/// or keychain can be reached from it.
pub fn environ(gpa: Allocator, home: []const u8) !Environ.Map {
    var map: Environ.Map = .init(gpa);
    errdefer map.deinit();
    const path = std.testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try map.put("PATH", path);
    try map.put("HOME", home);
    try map.put("XDG_CONFIG_HOME", home);
    // Where git-lfs, and relic after it, make the directory for an ssh
    // control socket, which git-lfs never removes: the test's own.
    try map.put("XDG_RUNTIME_DIR", home);
    try map.put("GIT_CONFIG_NOSYSTEM", "1");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try map.put("GIT_LFS_SKIP_PUSH", "0");
    return map;
}

var lfs_checked = false;
var lfs_present = false;

/// `error.SkipZigTest` unless `git lfs` runs, with `env` and nothing else.
pub fn requireGitLfs(gpa: Allocator, io: Io, env: *const Environ.Map) !void {
    try testgit.requireGit(gpa, io);
    if (!lfs_checked) {
        lfs_checked = true;
        var outcome = program.run(.{ .environ = env }, gpa, io, .{ .argv = &.{ "git", "lfs", "version" } }, "", .{}) catch
            return error.SkipZigTest;
        defer outcome.deinit(gpa);
        lfs_present = outcome.succeeded();
    }
    if (!lfs_present) return error.SkipZigTest;
}

/// Run `git` with `env` and only `env`, in `dir`. The output is the
/// caller's; a failure is `error.GitFailed`, and what git said is printed
/// when `report` asks for it.
///
/// Hooks are kept in the home directory: git-lfs installs its own wherever
/// `core.hooksPath` points, and they must not land in a working tree.
pub fn git(gpa: Allocator, io: Io, dir: Io.Dir, env: *const Environ.Map, args: []const []const u8, report: bool) ![]u8 {
    const hooks = try std.fmt.allocPrint(gpa, "core.hooksPath={s}/hooks", .{env.get("HOME").?});
    defer gpa.free(hooks);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "-c", hooks });
    try argv.appendSlice(gpa, args);
    return testremote.gitInputEnv(gpa, io, dir, env, argv.items, "", report);
}

/// A user the server knows, and the password it takes for them.
pub const User = struct {
    name: []const u8,
    password: []const u8,
};

/// A token the server takes as `Authorization: RemoteAuth <token>` for a
/// user: what the stand-in `git-lfs-authenticate` hands out.
pub const Token = struct {
    token: []const u8,
    user: []const u8,
};

/// A lock the server holds.
pub const Lock = struct {
    id: []const u8,
    path: []const u8,
    owner: []const u8,
    locked_at: []const u8,
};

/// A failure the server is told to answer with, the next time a request of
/// its kind comes.
pub const Fault = struct {
    route: Route,
    status: u16 = 200,
    retry_after: ?[]const u8 = null,
    /// For a download: send the status and the whole length, then only
    /// half the bytes, and close — a connection that breaks off.
    cut: bool = false,

    pub const Route = enum { batch, download, upload, verify, locks };
};

/// An LFS server on 127.0.0.1.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    port: u16,
    options: Options,
    env: Environ.Map,
    git_root: ?[]u8 = null,
    task: Io.Future(void) = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    objects: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    locks: std.ArrayList(Lock) = .empty,
    next_lock: u32 = 1,
    faults: std.ArrayList(Fault) = .empty,
    log: std.ArrayList(u8) = .empty,
    /// One `<method> <oid> <header>=<value>` line per object moved, for the
    /// headers a test compares.
    object_log: std.ArrayList(u8) = .empty,
    zstd_window_log: ?u6 = null,
    /// How many download actions still to hand out already expiring, and
    /// how their expiry is written.
    expiring: u32 = 0,
    expiring_kind: Expiring = .in,
    /// One `<operation> <ref>` line per batch: the ref's name in quotes,
    /// `no name`, or `no ref`.
    batch_refs: std.ArrayList(u8) = .empty,

    /// How the server behaves.
    pub const Options = struct {
        /// Refuse every LFS request that does not authenticate as one of
        /// these, with a 401 that offers basic. Empty takes anyone, as
        /// `anonymous`.
        users: []const User = &.{},
        tokens: []const Token = &.{},
        /// Hand out a verify action with each upload.
        verify: bool = true,
        /// Say every object needs no further credential.
        authenticated: bool = false,
        /// The repositories `git http-backend` serves for every path that is
        /// not the LFS API's.
        git_root: ?Io.Dir = null,
        /// Answer the locking API, or 404 as a server without one does.
        locking: bool = true,
        /// The most locks one page of a listing holds.
        page_size: usize = 100,
        /// Where the actions point, in place of the server's own URL: a
        /// name only `url.<base>.insteadOf` can turn back into this server.
        href_base: ?[]const u8 = null,
        /// The transfer adapter the batch answer names.
        transfer: []const u8 = "basic",
        /// Send a whole object compressed when the client asks: zstd when
        /// its `Accept-Encoding` names zstd, else gzip when it names gzip.
        encode: bool = false,
        /// Ask for uploads in chunks, with `Transfer-Encoding: chunked` in
        /// the upload action's headers.
        chunked_uploads: bool = false,
    };

    /// Listen on an ephemeral port.
    pub fn start(gpa: Allocator, io: Io, options: Options) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        var env = try testremote.environ(gpa);
        errdefer env.deinit();
        s.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .options = options,
            .env = env,
        };
        if (options.git_root) |root| s.git_root = try testremote.absolutePath(gpa, io, root);
        errdefer if (s.git_root) |r| gpa.free(r);
        s.task = io.concurrent(serve, .{s}) catch return error.SkipZigTest;
        return s;
    }

    /// Stop serving and release everything.
    pub fn stop(s: *Server) void {
        const io = s.io;
        s.stopping.store(true, .release);
        const address = Io.net.IpAddress.parse("127.0.0.1", s.port) catch unreachable;
        if (address.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
        s.task.await(io);
        s.listener.deinit(io);
        s.env.deinit();
        if (s.git_root) |r| s.gpa.free(r);
        var it = s.objects.iterator();
        while (it.next()) |kv| {
            s.gpa.free(kv.key_ptr.*);
            s.gpa.free(kv.value_ptr.*);
        }
        s.objects.deinit(s.gpa);
        for (s.locks.items) |l| freeLock(s.gpa, l);
        s.locks.deinit(s.gpa);
        s.faults.deinit(s.gpa);
        s.log.deinit(s.gpa);
        s.object_log.deinit(s.gpa);
        s.batch_refs.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    /// `http://127.0.0.1:<port>/<path>`. The result is the caller's.
    pub fn url(s: *const Server, gpa: Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/{s}", .{ s.port, path });
    }

    /// Queue a fault.
    pub fn fail(s: *Server, fault: Fault) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.faults.append(s.gpa, fault);
    }

    /// Put an object on the server as if someone had pushed it.
    pub fn putObject(s: *Server, oid: []const u8, bytes: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.storeLocked(oid, bytes);
    }

    fn storeLocked(s: *Server, oid: []const u8, bytes: []const u8) !void {
        const gop = try s.objects.getOrPut(s.gpa, oid);
        if (gop.found_existing) {
            s.gpa.free(gop.value_ptr.*);
        } else gop.key_ptr.* = try s.gpa.dupe(u8, oid);
        gop.value_ptr.* = try s.gpa.dupe(u8, bytes);
    }

    /// The object's bytes, or `null`. The result is the caller's.
    pub fn object(s: *Server, gpa: Allocator, oid: []const u8) !?[]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const bytes = s.objects.get(oid) orelse return null;
        return try gpa.dupe(u8, bytes);
    }

    /// How many objects the server holds.
    pub fn objectCount(s: *Server) usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.objects.count();
    }

    /// The paths locked, and by whom, one `path owner` line each, sorted.
    /// The result is the caller's.
    pub fn lockListing(s: *Server, gpa: Allocator) ![]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }
        for (s.locks.items) |l| try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}\n", .{ l.path, l.owner }));
        std.mem.sort([]const u8, lines.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        for (lines.items) |l| try out.appendSlice(gpa, l);
        return out.toOwnedSlice(gpa);
    }

    /// Take a lock directly, as if someone else had.
    pub fn addLock(s: *Server, path: []const u8, owner: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        _ = try s.newLockLocked(path, owner);
    }

    /// The requests seen so far, one `<method> <path> <user>` line each,
    /// the query left off. The result is the caller's.
    pub fn requests(s: *Server, gpa: Allocator) ![]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return gpa.dupe(u8, s.log.items);
    }

    /// How an action is made to expire.
    pub const Expiring = enum { none, in, at };

    /// Hand out the next `count` download actions expiring: in a second,
    /// or at a time gone by.
    pub fn setExpiring(s: *Server, count: u32, kind: Expiring) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.expiring = count;
        s.expiring_kind = kind;
    }

    fn takeExpiring(s: *Server) Expiring {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.expiring == 0) return .none;
        s.expiring -= 1;
        return s.expiring_kind;
    }

    /// Encode zstd bodies as frames that declare a window of `log` bits,
    /// or, with `null`, as single-segment frames sized to the object.
    pub fn setZstdWindowLog(s: *Server, log: ?u6) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.zstd_window_log = log;
    }

    fn zstdWindowLog(s: *Server) ?u6 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.zstd_window_log;
    }

    /// Forget the requests seen so far.
    pub fn clearLog(s: *Server) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.log.clearRetainingCapacity();
        s.object_log.clearRetainingCapacity();
        s.batch_refs.clearRetainingCapacity();
    }

    /// The refs the batches seen so far named, one line each. The caller's.
    pub fn batchRefs(s: *Server, gpa: Allocator) ![]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return gpa.dupe(u8, s.batch_refs.items);
    }

    /// The headers of the object requests seen so far, sorted, one
    /// `<method> <oid> <header>=<value>` line each. The caller's.
    pub fn objectHeaders(s: *Server, gpa: Allocator) ![]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var it = std.mem.tokenizeScalar(u8, s.object_log.items, '\n');
        while (it.next()) |line| try lines.append(gpa, line);
        std.mem.sort([]const u8, lines.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (lines.items) |line| {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    fn logObject(s: *Server, method: http.Method, oid: []const u8, name: []const u8, value: ?[]const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.object_log.print(s.gpa, "{s} {s} {s}={s}\n", .{ @tagName(method), oid, name, value orelse "-" });
    }

    fn serve(s: *Server) void {
        while (!s.stopping.load(.acquire)) {
            const stream = s.listener.accept(s.io) catch return;
            defer stream.close(s.io);
            if (s.stopping.load(.acquire)) return;
            s.handle(stream) catch {};
        }
    }

    fn takeFault(s: *Server, route: Fault.Route) ?Fault {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.faults.items, 0..) |f, i| {
            if (f.route == route) {
                _ = s.faults.orderedRemove(i);
                return f;
            }
        }
        return null;
    }

    fn handle(s: *Server, stream: Io.net.Stream) !void {
        const io = s.io;
        const gpa = s.gpa;
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const method = request.head.method;
        // A request a client sent through this server as its proxy names
        // the whole URL; the host it was for is noted in the log.
        var target = try arena.dupe(u8, request.head.target);
        var proxied_for: ?[]const u8 = null;
        if (std.mem.startsWith(u8, target, "http://")) {
            const slash = std.mem.indexOfScalarPos(u8, target, "http://".len, '/') orelse target.len;
            proxied_for = target["http://".len..slash];
            target = target[slash..];
        }
        var authorization: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        var git_protocol: ?[]const u8 = null;
        var range: ?[]const u8 = null;
        var accept_encoding: ?[]const u8 = null;
        var transfer_encoding: ?[]const u8 = null;
        var content_length: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) transfer_encoding = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) content_length = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) accept_encoding = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "git-protocol")) git_protocol = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "range")) range = try arena.dupe(u8, h.value);
        }
        const question = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. question orelse target.len];
        const query = if (question) |q| target[q + 1 ..] else "";

        var body: []const u8 = "";
        if (method == .POST or method == .PUT) {
            var body_buffer: [8192]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buffer);
            body = try body_reader.allocRemaining(arena, .limited(1 << 30));
        }

        const lfs_at = std.mem.indexOf(u8, path, "/info/lfs");
        if (lfs_at == null) {
            const git_root = s.git_root orelse return request.respond("", .{ .status = .not_found, .keep_alive = false });
            try s.logRequest(method, path, "-");
            return s.cgi(&request, arena, git_root, method, path, query, content_type, git_protocol, body);
        }
        const prefix = path[0 .. lfs_at.? + "/info/lfs".len];
        const route = path[prefix.len..];

        const user = s.authenticate(authorization);
        if (range) |r| {
            const logged = try std.fmt.allocPrint(arena, "{s} range={s}", .{ user orelse "?", r });
            try s.logRequest(method, route, logged);
        } else if (proxied_for) |host| {
            const logged = try std.fmt.allocPrint(arena, "{s} proxied-for={s}", .{ user orelse "?", host });
            try s.logRequest(method, route, logged);
        } else try s.logRequest(method, route, user orelse "?");
        if (user == null) {
            return request.respond("{\"message\":\"Credentials needed\"}", .{
                .status = .unauthorized,
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "WWW-Authenticate", .value = "Basic realm=\"relic-lfs\"" },
                    .{ .name = "Content-Type", .value = "application/vnd.git-lfs+json" },
                },
            });
        }

        const base = if (s.options.href_base) |b|
            try std.fmt.allocPrint(arena, "{s}{s}", .{ b, prefix })
        else
            try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ s.port, prefix });
        if (method == .POST and std.mem.eql(u8, route, "/objects/batch")) {
            if (s.takeFault(.batch)) |f| return respondFault(&request, f);
            // A token is handed back in each action, as a hosting service
            // hands one back; a basic credential is not.
            const token: ?[]const u8 = if (authorization != null and std.mem.startsWith(u8, authorization.?, "RemoteAuth ")) authorization.? else null;
            return s.batch(&request, arena, base, body, token);
        }
        if (std.mem.startsWith(u8, route, "/objects/") and route.len == "/objects/".len + 64) {
            const oid = route["/objects/".len..];
            if (method == .GET) {
                try s.logObject(method, oid, "accept-encoding", accept_encoding);
                const fault = s.takeFault(.download);
                if (fault) |f| if (!f.cut) return respondFault(&request, f);
                const bytes = try s.object(arena, oid) orelse return request.respond("", .{ .status = .not_found, .keep_alive = false });
                if (fault != null) {
                    const out = request.server.out;
                    try out.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{bytes.len});
                    try out.writeAll(bytes[0 .. bytes.len / 2]);
                    try out.flush();
                    return;
                }
                if (range) |r| {
                    // `bytes=<first>-<last>`, as a client resuming asks.
                    const spec = if (std.mem.startsWith(u8, r, "bytes=")) r["bytes=".len..] else "";
                    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse spec.len;
                    const first = std.fmt.parseInt(usize, spec[0..dash], 10) catch bytes.len;
                    const last = if (dash + 1 < spec.len) std.fmt.parseInt(usize, spec[dash + 1 ..], 10) catch bytes.len - 1 else bytes.len - 1;
                    if (first >= bytes.len or last < first) return request.respond("", .{ .status = .range_not_satisfiable, .keep_alive = false });
                    const end = @min(last + 1, bytes.len);
                    const content_range = try std.fmt.allocPrint(arena, "bytes {d}-{d}/{d}", .{ first, end - 1, bytes.len });
                    return request.respond(bytes[first..end], .{ .status = .partial_content, .keep_alive = false, .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "application/octet-stream" },
                        .{ .name = "Content-Range", .value = content_range },
                    } });
                }
                if (s.options.encode and accept_encoding != null) {
                    const accepted = accept_encoding.?;
                    const zstd = std.mem.indexOf(u8, accepted, "zstd") != null;
                    if (zstd or std.mem.indexOf(u8, accepted, "gzip") != null) {
                        const encoded = if (zstd) try encodeZstd(arena, bytes, s.zstdWindowLog()) else try encodeGzip(arena, bytes);
                        return request.respond(encoded, .{ .keep_alive = false, .extra_headers = &.{
                            .{ .name = "Content-Type", .value = "application/octet-stream" },
                            .{ .name = "Content-Encoding", .value = if (zstd) "zstd" else "gzip" },
                        } });
                    }
                }
                return request.respond(bytes, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }} });
            }
            if (method == .PUT) {
                try s.logObject(method, oid, "content-type", content_type);
                if (s.options.chunked_uploads) {
                    try s.logObject(method, oid, "transfer-encoding", transfer_encoding);
                    try s.logObject(method, oid, "content-length", content_length);
                }
                if (s.takeFault(.upload)) |f| return respondFault(&request, f);
                if (!std.mem.eql(u8, &sha256Hex(body), oid)) return request.respond("", .{ .status = .bad_request, .keep_alive = false });
                try s.putObject(oid, body);
                return request.respond("", .{ .keep_alive = false });
            }
        }
        if (method == .POST and std.mem.eql(u8, route, "/verify")) {
            if (s.takeFault(.verify)) |f| return respondFault(&request, f);
            const Want = struct { oid: []const u8, size: u64 };
            const want = std.json.parseFromSliceLeaky(Want, arena, body, .{ .ignore_unknown_fields = true }) catch
                return request.respond("", .{ .status = .unprocessable_entity, .keep_alive = false });
            const have = try s.object(arena, want.oid) orelse return request.respond("", .{ .status = .not_found, .keep_alive = false });
            if (have.len != want.size) return request.respond("", .{ .status = .not_found, .keep_alive = false });
            return request.respond("", .{ .keep_alive = false });
        }
        if (std.mem.startsWith(u8, route, "/locks")) {
            if (!s.options.locking) return request.respond("", .{ .status = .not_found, .keep_alive = false });
            if (s.takeFault(.locks)) |f| return respondFault(&request, f);
            return s.locking(&request, arena, method, route, query, body, user.?);
        }
        return request.respond("", .{ .status = .not_found, .keep_alive = false });
    }

    fn logRequest(s: *Server, method: http.Method, path: []const u8, user: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.log.print(s.gpa, "{s} {s} {s}\n", .{ @tagName(method), path, user });
    }

    fn authenticate(s: *Server, authorization: ?[]const u8) ?[]const u8 {
        if (s.options.users.len == 0 and s.options.tokens.len == 0) return "anonymous";
        const auth = authorization orelse return null;
        if (std.mem.startsWith(u8, auth, "RemoteAuth ")) {
            for (s.options.tokens) |t| {
                if (std.mem.eql(u8, auth["RemoteAuth ".len..], t.token)) return t.user;
            }
            return null;
        }
        if (!std.mem.startsWith(u8, auth, "Basic ")) return null;
        var decoded: [512]u8 = undefined;
        const encoded = auth["Basic ".len..];
        const len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
        if (len > decoded.len) return null;
        std.base64.standard.Decoder.decode(decoded[0..len], encoded) catch return null;
        const plain = decoded[0..len];
        const colon = std.mem.indexOfScalar(u8, plain, ':') orelse return null;
        for (s.options.users) |u| {
            if (std.mem.eql(u8, plain[0..colon], u.name) and std.mem.eql(u8, plain[colon + 1 ..], u.password)) return u.name;
        }
        return null;
    }

    fn batch(s: *Server, request: *http.Server.Request, arena: Allocator, base: []const u8, body: []const u8, token: ?[]const u8) !void {
        const auth_header = if (token) |t| try std.fmt.allocPrint(arena, ",\"Authorization\":\"{s}\"", .{t}) else "";
        const Wanted = struct { oid: []const u8, size: u64 };
        const Ref = struct { name: ?[]const u8 = null };
        const Batch = struct { operation: []const u8, objects: []const Wanted, ref: ?Ref = null };
        const b = std.json.parseFromSliceLeaky(Batch, arena, body, .{ .ignore_unknown_fields = true }) catch
            return request.respond("{\"message\":\"malformed batch\"}", .{ .status = .unprocessable_entity, .keep_alive = false });
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const name: []const u8 = if (b.ref) |r| (if (r.name) |n| try std.fmt.allocPrint(arena, "\"{s}\"", .{n}) else "no name") else "no ref";
            try s.batch_refs.print(s.gpa, "{s} {s}\n", .{ b.operation, name });
        }
        const upload = std.mem.eql(u8, b.operation, "upload");
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("{{\"transfer\":\"{s}\",\"objects\":[", .{s.options.transfer});
        for (b.objects, 0..) |o, i| {
            if (i != 0) try w.writeByte(',');
            const have = try s.object(arena, o.oid);
            try w.print("{{\"oid\":\"{s}\",\"size\":{d}", .{ o.oid, o.size });
            if (s.options.authenticated) try w.writeAll(",\"authenticated\":true");
            if (upload) {
                if (have == null) {
                    const chunked = if (s.options.chunked_uploads) ",\"Transfer-Encoding\":\"chunked\"" else "";
                    try w.print(",\"actions\":{{\"upload\":{{\"href\":\"{s}/objects/{s}\",\"header\":{{\"X-Relic-Test\":\"upload\"{s}{s}}},\"expires_in\":3600}}", .{ base, o.oid, auth_header, chunked });
                    if (s.options.verify) try w.print(",\"verify\":{{\"href\":\"{s}/verify\",\"header\":{{\"X-Relic-Test\":\"verify\"{s}}}}}", .{ base, auth_header });
                    try w.writeByte('}');
                }
            } else if (have) |bytes| {
                if (bytes.len != o.size) {
                    try w.writeAll(",\"error\":{\"code\":422,\"message\":\"Object size does not match\"}");
                } else {
                    const expiry = switch (s.takeExpiring()) {
                        .none => "\"expires_at\":\"2099-01-01T00:00:00Z\"",
                        .in => "\"expires_in\":1,\"expires_at\":\"2099-01-01T00:00:00Z\"",
                        .at => "\"expires_at\":\"2000-01-01T00:00:00+01:00\"",
                    };
                    try w.print(",\"actions\":{{\"download\":{{\"href\":\"{s}/objects/{s}\",\"header\":{{\"X-Relic-Test\":\"download\"{s}}},{s}}}}}", .{ base, o.oid, auth_header, expiry });
                }
            } else {
                try w.writeAll(",\"error\":{\"code\":404,\"message\":\"Object does not exist\"}");
            }
            try w.writeByte('}');
        }
        try w.writeAll("],\"hash_algo\":\"sha256\"}");
        return request.respond(out.written(), .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/vnd.git-lfs+json" }} });
    }

    fn newLockLocked(s: *Server, path: []const u8, owner: []const u8) !Lock {
        const lock: Lock = .{
            .id = try std.fmt.allocPrint(s.gpa, "{d}", .{s.next_lock}),
            .path = try s.gpa.dupe(u8, path),
            .owner = try s.gpa.dupe(u8, owner),
            .locked_at = try std.fmt.allocPrint(s.gpa, "2026-09-24T10:{d:0>2}:00Z", .{s.next_lock % 60}),
        };
        s.next_lock += 1;
        try s.locks.append(s.gpa, lock);
        return lock;
    }

    fn locking(s: *Server, request: *http.Server.Request, arena: Allocator, method: http.Method, route: []const u8, query: []const u8, body: []const u8, user: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const json_header: []const http.Header = &.{.{ .name = "Content-Type", .value = "application/vnd.git-lfs+json" }};

        if (method == .POST and std.mem.eql(u8, route, "/locks")) {
            const Create = struct { path: []const u8 };
            const want = std.json.parseFromSliceLeaky(Create, arena, body, .{ .ignore_unknown_fields = true }) catch
                return request.respond("{\"message\":\"malformed\"}", .{ .status = .unprocessable_entity, .keep_alive = false, .extra_headers = json_header });
            for (s.locks.items) |l| {
                if (!std.mem.eql(u8, l.path, want.path)) continue;
                try w.writeAll("{\"lock\":");
                try writeLock(w, l);
                try w.writeAll(",\"message\":\"already created lock\"}");
                return request.respond(out.written(), .{ .status = .conflict, .keep_alive = false, .extra_headers = json_header });
            }
            const lock = try s.newLockLocked(want.path, user);
            try w.writeAll("{\"lock\":");
            try writeLock(w, lock);
            try w.writeByte('}');
            return request.respond(out.written(), .{ .status = .created, .keep_alive = false, .extra_headers = json_header });
        }
        if (method == .POST and std.mem.eql(u8, route, "/locks/verify")) {
            const Verify = struct { cursor: ?[]const u8 = null, limit: ?usize = null };
            const v = std.json.parseFromSliceLeaky(Verify, arena, if (body.len == 0) "{}" else body, .{ .ignore_unknown_fields = true }) catch
                return request.respond("{\"message\":\"malformed\"}", .{ .status = .unprocessable_entity, .keep_alive = false, .extra_headers = json_header });
            const pg = s.pageOf(v.cursor, v.limit);
            try w.writeAll("{\"ours\":[");
            var first = true;
            for (s.locks.items[pg.start..pg.end]) |l| {
                if (!std.mem.eql(u8, l.owner, user)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try writeLock(w, l);
            }
            try w.writeAll("],\"theirs\":[");
            first = true;
            for (s.locks.items[pg.start..pg.end]) |l| {
                if (std.mem.eql(u8, l.owner, user)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try writeLock(w, l);
            }
            try w.writeByte(']');
            if (pg.next) |next| try w.print(",\"next_cursor\":\"{s}\"", .{next});
            try w.writeByte('}');
            return request.respond(out.written(), .{ .keep_alive = false, .extra_headers = json_header });
        }
        if (method == .POST and std.mem.startsWith(u8, route, "/locks/") and std.mem.endsWith(u8, route, "/unlock")) {
            const id = route["/locks/".len .. route.len - "/unlock".len];
            const Unlock = struct { force: bool = false };
            const u = std.json.parseFromSliceLeaky(Unlock, arena, if (body.len == 0) "{}" else body, .{ .ignore_unknown_fields = true }) catch
                return request.respond("{\"message\":\"malformed\"}", .{ .status = .unprocessable_entity, .keep_alive = false, .extra_headers = json_header });
            for (s.locks.items, 0..) |l, i| {
                if (!std.mem.eql(u8, l.id, id)) continue;
                if (!std.mem.eql(u8, l.owner, user) and !u.force) {
                    try w.writeAll("{\"message\":\"lock is owned by someone else\"}");
                    return request.respond(out.written(), .{ .status = .forbidden, .keep_alive = false, .extra_headers = json_header });
                }
                try w.writeAll("{\"lock\":");
                try writeLock(w, l);
                try w.writeByte('}');
                const removed = s.locks.orderedRemove(i);
                defer freeLock(s.gpa, removed);
                return request.respond(out.written(), .{ .keep_alive = false, .extra_headers = json_header });
            }
            return request.respond("{\"message\":\"unable to find lock\"}", .{ .status = .not_found, .keep_alive = false, .extra_headers = json_header });
        }
        if (method == .GET and std.mem.eql(u8, route, "/locks")) {
            var path_filter: ?[]const u8 = null;
            var id_filter: ?[]const u8 = null;
            var cursor: ?[]const u8 = null;
            var limit: ?usize = null;
            var params = std.mem.splitScalar(u8, query, '&');
            while (params.next()) |param| {
                const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
                const value = try percentDecode(arena, param[eq + 1 ..]);
                const key = param[0..eq];
                if (std.mem.eql(u8, key, "path")) path_filter = value;
                if (std.mem.eql(u8, key, "id")) id_filter = value;
                if (std.mem.eql(u8, key, "cursor")) cursor = value;
                if (std.mem.eql(u8, key, "limit")) limit = std.fmt.parseInt(usize, value, 10) catch null;
            }
            const pg = s.pageOf(cursor, limit);
            try w.writeAll("{\"locks\":[");
            var first = true;
            for (s.locks.items[pg.start..pg.end]) |l| {
                if (path_filter) |p| if (!std.mem.eql(u8, p, l.path)) continue;
                if (id_filter) |p| if (!std.mem.eql(u8, p, l.id)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try writeLock(w, l);
            }
            try w.writeByte(']');
            if (pg.next) |next| try w.print(",\"next_cursor\":\"{s}\"", .{next});
            try w.writeByte('}');
            return request.respond(out.written(), .{ .keep_alive = false, .extra_headers = json_header });
        }
        return request.respond("", .{ .status = .not_found, .keep_alive = false });
    }

    const Page = struct { start: usize, end: usize, next: ?[]const u8 };

    /// A page of the locks, from the one whose id is `cursor`.
    fn pageOf(s: *Server, cursor: ?[]const u8, limit: ?usize) Page {
        var from: usize = 0;
        if (cursor) |c| {
            for (s.locks.items, 0..) |l, i| {
                if (std.mem.eql(u8, l.id, c)) from = i;
            }
        }
        const size = @min(limit orelse s.options.page_size, s.options.page_size);
        const end = @min(s.locks.items.len, from + size);
        return .{ .start = from, .end = end, .next = if (end < s.locks.items.len) s.locks.items[end].id else null };
    }

    fn cgi(
        s: *Server,
        request: *http.Server.Request,
        arena: Allocator,
        root: []const u8,
        method: http.Method,
        path: []const u8,
        query: []const u8,
        content_type: ?[]const u8,
        git_protocol: ?[]const u8,
        body: []const u8,
    ) !void {
        var cgi_env = try s.env.clone(arena);
        try cgi_env.put("GIT_PROJECT_ROOT", root);
        try cgi_env.put("GIT_HTTP_EXPORT_ALL", "1");
        try cgi_env.put("PATH_INFO", path);
        try cgi_env.put("REQUEST_METHOD", @tagName(method));
        try cgi_env.put("QUERY_STRING", query);
        try cgi_env.put("REMOTE_ADDR", "127.0.0.1");
        try cgi_env.put("REMOTE_USER", "tester");
        if (content_type) |ct| try cgi_env.put("CONTENT_TYPE", ct);
        if (git_protocol) |gp| try cgi_env.put("GIT_PROTOCOL", gp);
        if (method == .POST) try cgi_env.put("CONTENT_LENGTH", try std.fmt.allocPrint(arena, "{d}", .{body.len}));
        var outcome = try program.run(.{ .environ = &cgi_env }, s.gpa, s.io, .{ .argv = &.{ "git", "-c", "http.receivepack=true", "http-backend" } }, body, .{});
        defer outcome.deinit(s.gpa);
        const output = outcome.stdout;
        const split = std.mem.indexOf(u8, output, "\r\n\r\n") orelse return error.MalformedCgiResponse;
        var status: u16 = 200;
        var response_headers: std.ArrayList(http.Header) = .empty;
        var lines = std.mem.splitSequence(u8, output[0..split], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "status")) {
                status = std.fmt.parseInt(u16, value[0..3], 10) catch 500;
            } else try response_headers.append(arena, .{ .name = name, .value = value });
        }
        try request.respond(output[split + 4 ..], .{ .status = @enumFromInt(status), .keep_alive = false, .extra_headers = response_headers.items });
    }
};

fn respondFault(request: *http.Server.Request, f: Fault) !void {
    var headers: [2]http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Content-Type", .value = "application/vnd.git-lfs+json" };
    n += 1;
    if (f.retry_after) |r| {
        headers[n] = .{ .name = "Retry-After", .value = r };
        n += 1;
    }
    return request.respond("{\"message\":\"injected fault\"}", .{ .status = @enumFromInt(f.status), .keep_alive = false, .extra_headers = headers[0..n] });
}

fn writeLock(w: *std.Io.Writer, l: Lock) !void {
    try w.print("{{\"id\":\"{s}\",\"path\":", .{l.id});
    try std.json.Stringify.value(l.path, .{}, w);
    try w.print(",\"locked_at\":\"{s}\",\"owner\":{{\"name\":\"{s}\"}}}}", .{ l.locked_at, l.owner });
}

fn freeLock(gpa: Allocator, l: Lock) void {
    gpa.free(l.id);
    gpa.free(l.path);
    gpa.free(l.owner);
    gpa.free(l.locked_at);
}

fn percentDecode(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(a, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, if (text[i] == '+') ' ' else text[i]);
    }
    return out.items;
}

/// The SHA-256 of `bytes`, in lower-case hexadecimal.
/// `bytes` as a gzip stream of stored deflate blocks: framed, not made
/// smaller, which is all a client's decoder needs to be shown.
fn encodeGzip(arena: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, &.{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff });
    var at: usize = 0;
    while (true) {
        const n = @min(bytes.len - at, 65535);
        const last = at + n == bytes.len;
        try out.append(arena, if (last) 1 else 0);
        var lens: [4]u8 = undefined;
        std.mem.writeInt(u16, lens[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(n)), .little);
        try out.appendSlice(arena, &lens);
        try out.appendSlice(arena, bytes[at .. at + n]);
        at += n;
        if (last) break;
    }
    var footer: [8]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], std.hash.Crc32.hash(bytes), .little);
    std.mem.writeInt(u32, footer[4..8], @truncate(bytes.len), .little);
    try out.appendSlice(arena, &footer);
    return out.items;
}

/// `bytes` as one zstd frame of raw blocks, with its size in the header.
/// With `window_log`, the frame declares a window of that many bits in
/// place of its size, as a streaming encoder's frames do.
fn encodeZstd(arena: Allocator, bytes: []const u8, window_log: ?u6) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, &.{ 0x28, 0xb5, 0x2f, 0xfd });
    if (window_log) |log| {
        // No content size, a window descriptor, no checksum.
        try out.append(arena, 0x00);
        try out.append(arena, @as(u8, log - 10) << 3);
    } else {
        // A four-byte content size, one segment, no checksum, no
        // dictionary.
        try out.append(arena, 0xa0);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(bytes.len), .little);
        try out.appendSlice(arena, &size);
    }
    var at: usize = 0;
    while (true) {
        const n: usize = @min(bytes.len - at, 128 * 1024);
        const last = at + n == bytes.len;
        const header: u24 = @intCast((n << 3) | @intFromBool(last));
        var h: [3]u8 = undefined;
        std.mem.writeInt(u24, &h, header, .little);
        try out.appendSlice(arena, &h);
        try out.appendSlice(arena, bytes[at .. at + n]);
        at += n;
        if (last) break;
    }
    return out.items;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;
    return out;
}

/// Write an executable script at `name` in `dir`, and return its absolute
/// path, which is the caller's.
pub fn script(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, text: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
    const base = try testremote.absolutePath(gpa, io, dir);
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, name });
}

/// A stand-in `git-lfs-transfer` in `dir`: relic's own server for the
/// pure-ssh protocol, keeping repositories under `root` and writing what
/// each connection was asked into `log_dir`. `extra` goes to it as well:
/// `--user=<name>`, `--no-version`.
pub fn transferScript(gpa: Allocator, io: Io, dir: Io.Dir, root: []const u8, log_dir: []const u8, extra: []const u8) ![]u8 {
    const text = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\exec '{s}' '--root={s}' '--log={s}' {s} "$@"
        \\
    , .{ @import("build_options").lfs_transfer_helper_path, root, log_dir, extra });
    defer gpa.free(text);
    return script(gpa, io, dir, "git-lfs-transfer", text);
}

/// What every connection to the stand-in `git-lfs-transfer` was asked,
/// one connection after another in the order of their text, from
/// `log_dir`. The caller's.
pub fn transferLog(gpa: Allocator, io: Io, log_dir: Io.Dir) ![]u8 {
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var it = log_dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        try texts.append(gpa, try log_dir.readFileAlloc(io, e.name, gpa, .unlimited));
    }
    std.mem.sort([]u8, texts.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (texts.items) |t| try out.appendSlice(gpa, t);
    return out.toOwnedSlice(gpa);
}

/// A stand-in credential helper at `<dir>/<name>`: it notes each operation
/// and the protocol, host, path, username and password it was given in
/// `<dir>/<name>.log`, and answers `get` with `user` and `password`.
pub fn credentialHelper(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, user: []const u8, password: []const u8) ![]u8 {
    const base = try testremote.absolutePath(gpa, io, dir);
    defer gpa.free(base);
    const text = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\log="{s}/{s}.log"
        \\echo "== $1" >> "$log"
        \\while IFS= read -r line; do
        \\  case "$line" in protocol=*|host=*|username=*|password=*|path=*) echo "$line" >> "$log";; esac
        \\done
        \\if [ "$1" = get ]; then echo username={s}; echo password={s}; fi
        \\
    , .{ base, name, user, password });
    defer gpa.free(text);
    return script(gpa, io, dir, name, text);
}

/// A stand-in credential helper like `credentialHelper`, which notes every
/// line it is given, sorted within each call, since git-lfs writes them in
/// no fixed order.
pub fn credentialHelperVerbatim(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, user: []const u8, password: []const u8) ![]u8 {
    const base = try testremote.absolutePath(gpa, io, dir);
    defer gpa.free(base);
    const text = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\log="{s}/{s}.log"
        \\echo "== $1" >> "$log"
        \\sed '/^$/q' | grep -v '^$' | LC_ALL=C sort >> "$log"
        \\if [ "$1" = get ]; then echo username={s}; echo password={s}; fi
        \\
    , .{ base, name, user, password });
    defer gpa.free(text);
    return script(gpa, io, dir, name, text);
}

/// A stand-in `git-lfs-authenticate` in `dir`, which answers with `href` and
/// a `RemoteAuth <token>` header, and notes its arguments in
/// `<dir>/git-lfs-authenticate.log`.
pub fn authenticateScript(gpa: Allocator, io: Io, dir: Io.Dir, href: []const u8, token: []const u8) ![]u8 {
    return authenticateScriptExpiring(gpa, io, dir, href, token, ",\"expires_in\":3600");
}

/// `authenticateScript` with `expiry` — `,"expires_in":1` and the like, or
/// nothing — written after the header.
pub fn authenticateScriptExpiring(gpa: Allocator, io: Io, dir: Io.Dir, href: []const u8, token: []const u8, expiry: []const u8) ![]u8 {
    const base = try testremote.absolutePath(gpa, io, dir);
    defer gpa.free(base);
    const text = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\echo "$@" >> "{s}/git-lfs-authenticate.log"
        \\printf '{{"href":"{s}","header":{{"Authorization":"RemoteAuth {s}"}}{s}}}'
        \\
    , .{ base, href, token, expiry });
    defer gpa.free(text);
    return script(gpa, io, dir, "git-lfs-authenticate", text);
}

test "the test server answers a batch, a transfer and a lock as the API says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const s = try Server.start(gpa, io, .{});
    defer s.stop();
    try s.putObject(&sha256Hex("hello\n"), "hello\n");
    try std.testing.expectEqual(@as(usize, 1), s.objectCount());
    try s.addLock("a.bin", "bob");
    const listing = try s.lockListing(gpa);
    defer gpa.free(listing);
    try std.testing.expectEqualStrings("a.bin bob\n", listing);
}
