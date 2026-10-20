//! git's smart HTTP protocol, served: git's `http-backend` as a handler
//! for uplink's server.
//!
//! Repositories are found under a root, as `GIT_PROJECT_ROOT` names one:
//! `/<path>/info/refs?service=git-upload-pack` (or `git-receive-pack`) is
//! the advertisement, after a `# service=` line unless the client asked
//! for protocol v2 in its `Git-Protocol` header; a `POST` to
//! `/<path>/git-upload-pack` or `/<path>/git-receive-pack` is one request
//! of the stateless conversation, answered by relic's own servers
//! (`upload_pack.zig`, `receive_pack.zig`). A body the client compressed
//! is read through uplink, which undoes gzip.
//!
//! As git's: a repository is served when it has `git-daemon-export-ok`, or
//! when every one is (`Options.export_all`, `GIT_HTTP_EXPORT_ALL`);
//! `http.uploadpack` turns fetching off, and pushing is taken only from a
//! caller the server authenticated (`Caller.user`, git's `REMOTE_USER`)
//! unless `http.receivepack` says otherwise. A push's ref updates are
//! logged as that user, `<user>@http.<address>`. The dumb protocol's
//! files are not served.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const uplink = @import("uplink");
const object = @import("../object/object.zig");
const program = @import("../process.zig").program;
const pkt_line = @import("../codec.zig").pkt_line;
const protocol = @import("../wire.zig").protocol;
const percent = @import("../text.zig").percent;
const local = @import("local.zig");
const upload_pack = @import("upload_pack.zig");
const receive_pack = @import("receive_pack.zig");

const Request = uplink.server.Request;
const Response = uplink.server.Response;

/// Who sent a request, and the time, which the caller knows and relic
/// does not read.
pub const Caller = struct {
    context: ?*anyopaque = null,
    /// git's `REMOTE_USER`: the name the server authenticated `request`
    /// as, or `null` for none.
    user: *const fn (context: ?*anyopaque, request: *Request) ?[]const u8,
    /// Seconds since the Unix epoch, for a push's ref logs.
    now: *const fn (context: ?*anyopaque) i64,
};

/// What is served, and to whom.
pub const Options = struct {
    /// Serve every repository under the root, as `GIT_HTTP_EXPORT_ALL`;
    /// otherwise only one with `git-daemon-export-ok`.
    export_all: bool = false,
    /// Permission to run a repository's hooks when it is pushed to.
    /// Without it a repository with hooks refuses a push.
    programs: ?program.Programs = null,
    caller: Caller,
};

/// The repositories under one root, served.
pub const Backend = struct {
    gpa: Allocator,
    /// The root's absolute path.
    root: []const u8,
    options: Options,

    /// Serve the repositories under `root`, an absolute path, borrowed.
    pub fn init(gpa: Allocator, root: []const u8, options: Options) Backend {
        return .{ .gpa = gpa, .root = root, .options = options };
    }

    /// The handler to give uplink's server.
    pub fn handler(b: *Backend) uplink.server.Handler {
        return .init(b, serve);
    }

    /// Answer one request.
    pub fn serve(b: *Backend, io: Io, request: *Request, response: *Response) anyerror!void {
        var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = try percent.decode(arena, request.path, .decode);
        const route = Route.of(path) orelse return notFound(io, response);
        const relative = std.mem.trim(u8, path[0 .. path.len - route.suffix().len], "/");
        if (!safe(relative)) return notFound(io, response);
        const location = try std.Io.Dir.path.join(arena, &.{ b.root, relative });

        var remote = local.Remote.open(b.gpa, io, location, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return notFound(io, response),
        };
        defer remote.deinit(io);
        if (!b.options.export_all) {
            remote.repo.gitDirectory().access(io, "git-daemon-export-ok", .{}) catch return notFound(io, response);
        }

        const service: Service = switch (route) {
            .info_refs => Service.named(queryValue(request.query, "service") orelse "") orelse return notFound(io, response),
            .upload_pack => .upload_pack,
            .receive_pack => .receive_pack,
        };
        const user = b.options.caller.user(b.options.caller.context, request);
        if (!service.enabled(&remote, user)) return forbidden(io, response);

        const version = versionAsked(request);
        try response.header("Expires", "Fri, 01 Jan 1980 00:00:00 GMT");
        try response.header("Pragma", "no-cache");
        try response.header("Cache-Control", "no-cache, max-age=0, must-revalidate");
        switch (route) {
            .info_refs => {
                if (!request.method.eql(.GET) and !request.method.eql(.HEAD)) return methodNotAllowed(io, response);
                try response.header("Content-Type", try arena.print("application/x-git-{s}-advertisement", .{service.name()}));
                const w = try response.writer(io);
                if (version != .v2) {
                    try pkt_line.print("# service=git-{s}\n", .{service.name()}, w);
                    try pkt_line.flush(w);
                }
                try b.run(io, &remote, service, version, user, request, w, .advertise);
            },
            .upload_pack, .receive_pack => {
                if (!request.method.eql(.POST)) return methodNotAllowed(io, response);
                const expected = try arena.print("application/x-git-{s}-request", .{service.name()});
                const content_type = request.headers.get("content-type") orelse "";
                if (!std.mem.eql(u8, content_type, expected)) return plain(io, response, .unsupported_media_type, "Unsupported Media Type");
                try response.header("Content-Type", try arena.print("application/x-git-{s}-result", .{service.name()}));
                try b.run(io, &remote, service, version, user, request, try response.writer(io), .request);
            },
        }
        try response.end(io);
    }

    const Step = enum { advertise, request };

    fn run(b: *Backend, io: Io, remote: *local.Remote, service: Service, version: protocol.Version, user: ?[]const u8, request: *Request, w: *Io.Writer, step: Step) anyerror!void {
        // The servers read whole packets out of their reader's buffer.
        const buffer = try b.gpa.alloc(u8, pkt_line.max_line);
        defer b.gpa.free(buffer);
        var body = request.reader(io).limited(.unlimited, buffer);
        switch (service) {
            .upload_pack => {
                var server: upload_pack.Server = .init(b.gpa, io, remote, version, .{ .stateless = true });
                switch (step) {
                    .advertise => try server.advertise(w),
                    .request => try server.serveRequest(&body.interface, w),
                }
            },
            .receive_pack => {
                var who: object.Signature = .{ .name = "", .email = "", .when_secs = b.options.caller.now(b.options.caller.context), .offset_minutes = 0 };
                var email_buf: [256]u8 = undefined;
                if (user) |name| {
                    who.name = name;
                    var address_buf: [64]u8 = undefined;
                    const address = if (request.remote) |a| std.mem.print(&address_buf, "{f}", .{a}) catch "" else "";
                    // git names the address without its port.
                    const host = if (std.mem.findScalarLast(u8, address, ':')) |colon| address[0..colon] else address;
                    who.email = std.mem.print(&email_buf, "{s}@http.{s}", .{ name, std.mem.trim(u8, host, "[]") }) catch name;
                }
                var server: receive_pack.Server = try .init(b.gpa, io, remote, version, .{ .stateless = true, .who = who, .programs = b.options.programs });
                defer server.deinit();
                switch (step) {
                    .advertise => try server.advertise(w),
                    .request => try server.serveRequest(&body.interface, w),
                }
            },
        }
    }
};

const Service = enum {
    upload_pack,
    receive_pack,

    fn named(text: []const u8) ?Service {
        if (std.mem.eql(u8, text, "git-upload-pack")) return .upload_pack;
        if (std.mem.eql(u8, text, "git-receive-pack")) return .receive_pack;
        return null;
    }

    fn name(s: Service) []const u8 {
        return switch (s) {
            .upload_pack => "upload-pack",
            .receive_pack => "receive-pack",
        };
    }

    /// git's `http.uploadpack` (on unless off) and `http.receivepack`
    /// (on for an authenticated caller unless set).
    fn enabled(s: Service, remote: *local.Remote, user: ?[]const u8) bool {
        const config = remote.repo.configuration();
        return switch (s) {
            .upload_pack => config.getBool("http.uploadpack", true) catch true,
            .receive_pack => if (config.find("http.receivepack") != null)
                config.getBool("http.receivepack", false) catch false
            else
                user != null and user.?.len != 0,
        };
    }
};

const Route = enum {
    info_refs,
    upload_pack,
    receive_pack,

    fn of(path: []const u8) ?Route {
        inline for (@typeInfo(Route).@"enum".field_names) |field| {
            const route = @field(Route, field);
            if (std.mem.endsWith(u8, path, route.suffix())) return route;
        }
        return null;
    }

    fn suffix(r: Route) []const u8 {
        return switch (r) {
            .info_refs => "/info/refs",
            .upload_pack => "/git-upload-pack",
            .receive_pack => "/git-receive-pack",
        };
    }
};

/// A repository path with no `..` and nothing absolute: git's
/// `daemon_avoid_alias`.
fn safe(relative: []const u8) bool {
    if (relative.len == 0) return false;
    var it = std.mem.splitAny(u8, relative, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return std.mem.findScalar(u8, relative, 0) == null and std.mem.findScalar(u8, relative, ':') == null;
}

fn queryValue(query: ?[]const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query orelse return null, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// The version the `Git-Protocol` header asks for, as git's server reads
/// `GIT_PROTOCOL`: the highest `version=` it names.
fn versionAsked(request: *const Request) protocol.Version {
    const header = request.headers.get("git-protocol") orelse return .v0;
    var best: protocol.Version = .v0;
    var it = std.mem.splitScalar(u8, header, ':');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "version=2")) best = .v2;
        if (std.mem.eql(u8, part, "version=1") and best == .v0) best = .v1;
    }
    return best;
}

fn plain(io: Io, response: *Response, status: std.http.Status, body: []const u8) anyerror!void {
    return uplink.server.Router.plain(io, response, status, body);
}

fn notFound(io: Io, response: *Response) anyerror!void {
    return plain(io, response, .not_found, "Not Found");
}

fn forbidden(io: Io, response: *Response) anyerror!void {
    return plain(io, response, .forbidden, "Forbidden");
}

fn methodNotAllowed(io: Io, response: *Response) anyerror!void {
    return plain(io, response, .method_not_allowed, "Method Not Allowed");
}

test "a repository path stays under the root" {
    try std.testing.expect(safe("a/b.git"));
    for ([_][]const u8{ "", "../x", "a/../b", "a//b", "./a", "c:x" }) |bad| try std.testing.expect(!safe(bad));
}
