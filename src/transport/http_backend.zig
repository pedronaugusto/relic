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
//! logged as that user, `<user>@http.<address>`.
//!
//! The dumb protocol's files are served as git's are, unless
//! `http.getanyfile` is off: `HEAD`, `info/refs` without a service (every
//! ref, a tag's peeled object after it) and `objects/info/packs` made as
//! they are asked for, and the alternates files, loose objects, packs and
//! their indexes read from the repository, the last three marked to be
//! kept for a year.

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
const date = @import("../text.zig").date;
const upload_pack = @import("upload_pack.zig");
const receive_pack = @import("receive_pack.zig");

const ErrorNamespace = @This();
const Request = uplink.server.Request;
const Response = uplink.server.Response;

/// Errors from answering a request: the servers', and the response's.
pub const Error = upload_pack.Error || receive_pack.Error || Response.Error || pkt_line.WriteError;

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
    pub const Error = ErrorNamespace.Error;

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
        if (Dumb.of(path)) |dumb| if (dumb.kind != .info_refs or queryValue(request.query, "service") == null) {
            const relative = std.mem.trim(u8, path[0 .. path.len - dumb.suffix_len], "/");
            var remote = (try openServed(b.gpa, io, b.root, relative, b.options.export_all)) orelse return notFound(io, response);
            defer remote.deinit(io);
            return b.serveDumb(io, arena, &remote, dumb, path[path.len - dumb.suffix_len ..], request, response);
        };
        const route = Route.of(path) orelse return notFound(io, response);
        const relative = std.mem.trim(u8, path[0 .. path.len - route.suffix().len], "/");
        var remote = (try openServed(b.gpa, io, b.root, relative, b.options.export_all)) orelse return notFound(io, response);
        defer remote.deinit(io);

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
                    try pkt_line.print(w, "# service=git-{s}\n", .{service.name()});
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

    /// git's dumb handlers: `get_head`, `get_info_refs` with no service,
    /// `get_info_packs`, `get_text_file`, `get_loose_object`,
    /// `get_pack_file` and `get_idx_file`.
    fn serveDumb(b: *Backend, io: Io, arena: Allocator, remote: *local.Remote, dumb: Dumb, file: []const u8, request: *Request, response: *Response) anyerror!void {
        if (!request.method.eql(.GET) and !request.method.eql(.HEAD)) return methodNotAllowed(io, response);
        const config = remote.repo.configuration();
        if (!(config.getBool("http.getanyfile", true) catch true)) return forbidden(io, response);
        var body: std.ArrayList(u8) = .empty;
        switch (dumb.kind) {
            .head => {
                const head = try remote.listRefs(b.gpa, io, &.{"HEAD"});
                var listing = head;
                defer listing.deinit();
                if (listing.find("HEAD")) |ref| {
                    if (ref.symref_target) |target| {
                        if (!ref.unborn) try body.print(arena, "ref: {s}\n", .{target});
                    } else try body.print(arena, "{f}\n", .{ref.oid});
                }
                return sendText(io, response, "text/plain", body.items);
            },
            .info_refs => {
                try noCache(response);
                var listing = try remote.listRefs(b.gpa, io, &.{"refs/"});
                defer listing.deinit();
                for (listing.refs) |ref| {
                    if (!try remote.repo.objectDatabase().exists(io, ref.oid)) continue;
                    try body.print(arena, "{f}\t{s}\n", .{ ref.oid, ref.name });
                    if (ref.peeled) |peeled| try body.print(arena, "{f}\t{s}^{{}}\n", .{ peeled, ref.name });
                }
                return sendText(io, response, "text/plain", body.items);
            },
            .info_packs => {
                const db = remote.repo.objectDatabase();
                const packs = try db.listPacks(b.gpa, io, .own);
                defer b.gpa.free(packs);
                for (packs) |listed| try body.print(arena, "P {s}.pack\n", .{listed.name});
                try body.append(arena, '\n');
                try noCache(response);
                return sendText(io, response, "text/plain; charset=utf-8", body.items);
            },
            .alternates => {
                try noCache(response);
                return sendFile(io, arena, remote, file, "text/plain", response);
            },
            .loose, .pack, .idx => {
                const now = b.options.caller.now(b.options.caller.context);
                try response.header("Date", try rfc2822(arena, now));
                try response.header("Expires", try rfc2822(arena, now + 31536000));
                try response.header("Cache-Control", "public, max-age=31536000");
                const content_type = switch (dumb.kind) {
                    .loose => "application/x-git-loose-object",
                    .pack => "application/x-git-packed-objects",
                    else => "application/x-git-packed-objects-toc",
                };
                return sendFile(io, arena, remote, file, content_type, response);
            },
        }
    }

    /// git's `send_local_file`: a file of the git directory, with its length
    /// and time, or not found.
    fn sendFile(io: Io, arena: Allocator, remote: *local.Remote, file: []const u8, content_type: []const u8, response: *Response) anyerror!void {
        const sub_path = std.mem.trimStart(u8, file, "/");
        const opened = remote.repo.gitDirectory().get().openFile(io, sub_path, .{}) catch return notFound(io, response);
        defer opened.close(io);
        const stat = try opened.stat(io);
        try response.header("Content-Type", content_type);
        try response.header("Last-Modified", try rfc2822(arena, @intCast(date.seconds(stat.mtime))));
        try response.setLength(stat.size);
        const w = try response.writer(io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = opened.reader(io, &buffer);
        _ = try reader.interface.streamRemaining(w);
        try response.end(io);
    }

    const Step = enum { advertise, request };

    fn run(b: *Backend, io: Io, remote: *local.Remote, service: Service, version: protocol.Version, user: ?[]const u8, request: *Request, w: *Io.Writer, step: Step) ErrorNamespace.Error!void {
        // The servers read whole packets out of their reader's buffer.
        const buffer = try b.gpa.alloc(u8, pkt_line.max_line);
        defer b.gpa.free(buffer);
        var body = request.reader(io).limited(.unlimited, buffer);
        switch (service) {
            .upload_pack => {
                var server: upload_pack.Server = .init(b.gpa, io, remote, version, .{ .stateless = true });
                switch (step) {
                    .advertise => try server.advertise(w),
                    .request => try server.serveRequest(w, &body.interface),
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
                    .request => try server.serveRequest(w, &body.interface),
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

/// A dumb protocol path: which file, and how much of the path names it.
const Dumb = struct {
    kind: Kind,
    suffix_len: usize,

    const Kind = enum { head, info_refs, info_packs, alternates, loose, pack, idx };

    /// git's patterns, each at the end of the path.
    fn of(path: []const u8) ?Dumb {
        const fixed = [_]struct { suffix: []const u8, kind: Kind }{
            .{ .suffix = "/HEAD", .kind = .head },
            .{ .suffix = "/info/refs", .kind = .info_refs },
            .{ .suffix = "/objects/info/alternates", .kind = .alternates },
            .{ .suffix = "/objects/info/http-alternates", .kind = .alternates },
            .{ .suffix = "/objects/info/packs", .kind = .info_packs },
        };
        for (fixed) |f| if (std.mem.endsWith(u8, path, f.suffix)) return .{ .kind = f.kind, .suffix_len = f.suffix.len };
        // `/objects/xx/<38 or 62 hex>`
        for ([_]usize{ 38, 62 }) |rest| {
            const len = "/objects/".len + 2 + 1 + rest;
            if (path.len < len) continue;
            const tail = path[path.len - len ..];
            if (std.mem.startsWith(u8, tail, "/objects/") and hex(tail["/objects/".len..][0..2]) and tail["/objects/".len + 2] == '/' and hex(tail[tail.len - rest ..]))
                return .{ .kind = .loose, .suffix_len = len };
        }
        // `/objects/pack/pack-<40 or 64 hex>.pack` and `.idx`
        for ([_]struct { ext: []const u8, kind: Kind }{ .{ .ext = ".pack", .kind = .pack }, .{ .ext = ".idx", .kind = .idx } }) |e| {
            for ([_]usize{ 40, 64 }) |digits| {
                const len = "/objects/pack/pack-".len + digits + e.ext.len;
                if (path.len < len) continue;
                const tail = path[path.len - len ..];
                if (std.mem.startsWith(u8, tail, "/objects/pack/pack-") and std.mem.endsWith(u8, tail, e.ext) and hex(tail["/objects/pack/pack-".len..][0..digits]))
                    return .{ .kind = e.kind, .suffix_len = len };
            }
        }
        return null;
    }

    fn hex(text: []const u8) bool {
        for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
        return true;
    }
};

/// git's `hdr_nocache`.
fn noCache(response: *Response) Response.Error!void {
    try response.header("Expires", "Fri, 01 Jan 1980 00:00:00 GMT");
    try response.header("Pragma", "no-cache");
    try response.header("Cache-Control", "no-cache, max-age=0, must-revalidate");
}

/// git's `send_strbuf`.
fn sendText(io: Io, response: *Response, content_type: []const u8, body: []const u8) anyerror!void {
    try response.header("Content-Type", content_type);
    try response.setLength(body.len);
    try response.send(io, body);
}

/// `when` as git's `hdr_date` writes it: RFC 2822, in UTC.
fn rfc2822(arena: Allocator, when: i64) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    date.showFixed(&out.writer, when, 0, .rfc2822) catch return error.OutOfMemory;
    return out.written();
}

/// Errors from `openServed`.
pub const OpenServedError = Allocator.Error || Io.Cancelable;

/// The repository at `relative` under `root`, opened, when it is served:
/// a path with no `..` and nothing absolute in it, to a repository with
/// `git-daemon-export-ok` unless `export_all`. `null` for any other, which
/// a server answers as not found. The caller deinits it.
pub fn openServed(gpa: Allocator, io: Io, root: []const u8, relative: []const u8, export_all: bool) OpenServedError!?local.Remote {
    if (!safe(relative)) return null;
    const location = try std.Io.Dir.path.join(gpa, &.{ root, relative });
    defer gpa.free(location);
    var remote = local.Remote.open(gpa, io, location, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return null,
    };
    if (!export_all) {
        remote.repo.gitDirectory().get().access(io, "git-daemon-export-ok", .{}) catch {
            remote.deinit(io);
            return null;
        };
    }
    return remote;
}

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
