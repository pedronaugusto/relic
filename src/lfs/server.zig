//! A Git LFS server: the API git-lfs and relic's own client (`api.zig`,
//! `transfer.zig`, `locks.zig`) talk to, served as a handler for uplink's
//! server, beside git's own smart HTTP (`transport.http_backend`).
//!
//! Repositories are found under a root as `http_backend` finds them, and
//! a client finds the API where git-lfs derives it from the remote's URL:
//! `<repository>/info/lfs`. Under it, the batch API (`POST
//! /objects/batch`) answers each object a download or an upload names with
//! the actions that move it, or an error of the object's own; the locking
//! API (`POST /locks`, `GET /locks`, `POST /locks/verify`, `POST
//! /locks/<id>/unlock`) takes, lists, splits and gives back locks on paths.
//! Every answer is JSON as git-lfs's Go writes it, through the same types
//! the client reads it with.
//!
//! The objects are in a `Store` the caller gives. `Directory` keeps them
//! in a directory, a tree per repository laid out as git-lfs's own store,
//! and the backend carries them: its actions point back at itself (`GET`
//! and `PUT /objects/<oid>`), with the request's credentials, and an upload
//! is checked against its SHA-256 before it is kept. `S3` keeps them in
//! S3-compatible object storage, and its actions are URLs the storage
//! signed, which the client follows straight to it, and is asked through
//! uplink's client whether it holds an object. Either way an upload
//! comes with a `verify` action back to the backend, which asks the store.
//!
//! Who may do what is the caller's: `Caller.authorize` is asked for each
//! request, with what it asks to do, and says who the requester is, or
//! that credentials are wanted (401, with the challenge it names), or no
//! (403). Reading objects and listing locks is `download`; writing objects
//! and taking, verifying and giving back locks is `upload`; giving back a
//! lock someone else holds is `force_unlock` as well. A lock's owner is the
//! name `authorize` gave.
//!
//! git-lfs's pure-ssh protocol, `git-lfs-transfer`, is served over the
//! same store and locks by `Transfer`, for an ssh server to run.
//!
//! Locks are kept beside the repository, in `<git dir>/lfs/locks.json`, a
//! JSON array of them as git-lfs writes its cache, replaced under git's lock
//! file. A lock's ref is read and not kept: a lock is on a path, for every
//! branch, as most servers keep them.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const uplink = @import("uplink");
const fs = @import("../fs/fs.zig");
const percent = @import("../text.zig").percent;
const decimal = @import("../text.zig").decimal;
const http_backend = @import("../transport/http_backend.zig");
const local = @import("../transport/local.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("api.zig");
const transfer = @import("transfer.zig");
const locks = @import("locks.zig");
const lock_store = @import("server/lock_store.zig");
const server_store = @import("server/store.zig");
const strand = @import("strand");

const ErrorNamespace = @This();
const Request = uplink.server.Request;
const Response = uplink.server.Response;

/// Errors from answering a request.
pub const Error = Allocator.Error || Io.Cancelable || Response.Error || Store.Error || locks.WriteAnswerError || lock_store.Error ||
    transfer.WriteBatchError || Request.CollectError || fs.LockFile.OpenError || fs.CommitError ||
    Io.Dir.CreateDirPathError || aegis.own.ReadFileError || Io.File.Writer.Error;

/// git-lfs's pure-ssh protocol over the same store and locks:
/// `git-lfs-transfer`.
pub const Transfer = @import("server/transfer.zig");

pub const Access = server_store.Access;
pub const Store = server_store.Store;
pub const Directory = server_store.Directory;
pub const S3 = server_store.S3;
pub const Link = server_store.Link;

/// What `Caller.authorize` says of a request.
pub const Verdict = union(enum) {
    /// Go ahead, as this person, or as no one in particular. The name is
    /// copied before the request goes on.
    allow: ?[]const u8,
    /// Credentials are wanted: 401, with this as `LFS-Authenticate`, which
    /// is what git-lfs reads to ask its credential helpers (for example
    /// `Basic realm="Git LFS"`).
    challenge: []const u8,
    /// No: 403.
    deny,
};

/// What the caller decides, and knows, that relic does not.
pub const Caller = struct {
    context: ?*anyopaque = null,
    /// Whether `request` may do what `access` names to the repository at
    /// `repository` (the path under the root), and as whom.
    authorize: *const fn (context: ?*anyopaque, request: *Request, repository: []const u8, access: Access) Verdict,
    /// Seconds since the Unix epoch, when a lock is taken.
    now: *const fn (context: ?*anyopaque) i64,
};

/// What is served, and to whom.
pub const Options = struct {
    /// Serve every repository under the root, as `GIT_HTTP_EXPORT_ALL`;
    /// otherwise only one with `git-daemon-export-ok`.
    export_all: bool = false,
    store: Store,
    caller: Caller,
    /// git's requests, for every path that is not under `info/lfs`: one
    /// server is then the whole remote. `null` answers them 404.
    git: ?*http_backend.Backend = null,
    /// The scheme, host and port clients reach the server at, for the
    /// actions that point back at it; by default the request's own, `http`
    /// or `https` as it came.
    origin: ?[]const u8 = null,
    /// The most locks a page of a listing holds when the client names no
    /// limit.
    lock_page: u32 = 100,
};

/// The largest request body read: a batch of many thousand objects.
const max_body = 16 << 20;

/// The repositories under one root, their LFS objects and locks served.
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
        const at = lfsPath(request.path) orelse {
            if (b.options.git) |git| return git.serve(io, request, response);
            return uplink.server.Router.plain(io, response, .not_found, "Not Found");
        };
        var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const relative = std.mem.trim(u8, try percent.decode(arena, request.path[0..at], .decode), "/");
        const rest = try percent.decode(arena, request.path[at + "/info/lfs".len ..], .decode);

        var remote = (try http_backend.openServed(b.gpa, io, b.root, relative, b.options.export_all)) orelse
            return message(io, response, .not_found, "Not Found");
        defer remote.deinit(io);

        var call: Call = .{
            .b = b,
            .io = io,
            .arena = arena,
            .request = request,
            .response = response,
            .repository = relative,
            .remote = &remote,
            .base = try arena.print("{s}{s}/info/lfs", .{ try b.origin(arena, request), request.path[0..at] }),
        };
        const method = request.method;
        if (std.mem.eql(u8, rest, "/objects/batch")) {
            if (!method.eql(.POST)) return methodNotAllowed(io, response);
            return call.batch();
        }
        if (std.mem.eql(u8, rest, "/objects/verify")) {
            if (!method.eql(.POST)) return methodNotAllowed(io, response);
            return call.verify();
        }
        if (std.mem.startsWith(u8, rest, "/objects/")) {
            const oid = rest["/objects/".len..];
            if (!isOid(oid)) return message(io, response, .not_found, "Not Found");
            if (method.eql(.GET)) return call.download(oid[0..64]);
            if (method.eql(.PUT)) return call.upload(oid[0..64]);
            return methodNotAllowed(io, response);
        }
        if (std.mem.eql(u8, rest, "/locks")) {
            if (method.eql(.GET)) return call.listLocks();
            if (method.eql(.POST)) return call.createLock();
            return methodNotAllowed(io, response);
        }
        if (std.mem.eql(u8, rest, "/locks/verify")) {
            if (!method.eql(.POST)) return methodNotAllowed(io, response);
            return call.verifyLocks();
        }
        if (std.mem.startsWith(u8, rest, "/locks/") and std.mem.endsWith(u8, rest, "/unlock")) {
            if (!method.eql(.POST)) return methodNotAllowed(io, response);
            const id = rest["/locks/".len .. rest.len - "/unlock".len];
            if (id.len == 0) return message(io, response, .not_found, "Not Found");
            return call.unlock(id);
        }
        return message(io, response, .not_found, "Not Found");
    }

    fn origin(b: *const Backend, arena: Allocator, request: *const Request) Allocator.Error![]const u8 {
        if (b.options.origin) |o| return std.mem.trimEnd(u8, o, "/");
        return arena.print("{s}://{s}", .{ if (request.secure) "https" else "http", request.host });
    }
};

/// Where `/info/lfs` starts in a request's path, when the path is under
/// it.
fn lfsPath(path: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.findPos(u8, path, from, "/info/lfs")) |at| {
        const end = at + "/info/lfs".len;
        if (end == path.len or path[end] == '/') return at;
        from = at + 1;
    }
    return null;
}

/// One request, being answered.
const Call = struct {
    b: *Backend,
    io: Io,
    arena: Allocator,
    request: *Request,
    response: *Response,
    /// The repository's path under the root.
    repository: []const u8,
    remote: *local.Remote,
    /// `<origin>/<repository>/info/lfs`, as the client reached it.
    base: []const u8,
    /// Who `authorize` said the requester is.
    user: ?[]const u8 = null,

    /// Ask the caller; `false` when the request has been answered with a
    /// refusal.
    fn allowed(c: *Call, access: Access) ErrorNamespace.Error!bool {
        const caller = c.b.options.caller;
        switch (caller.authorize(caller.context, c.request, c.repository, access)) {
            .allow => |who| {
                if (who) |name| c.user = try c.arena.dupe(u8, name);
                return true;
            },
            .challenge => |value| {
                try c.response.header("LFS-Authenticate", value);
                try message(c.io, c.response, .unauthorized, "Authentication required");
                return false;
            },
            .deny => {
                try message(c.io, c.response, .forbidden, "Forbidden");
                return false;
            },
        }
    }

    fn body(c: *Call) ErrorNamespace.Error!lfsapi.Unparsed {
        return .init(try c.request.collect(c.arena, c.io, .limited(max_body)));
    }

    fn store(c: *const Call) Store {
        return c.b.options.store;
    }

    // The batch API

    fn batch(c: *Call) ErrorNamespace.Error!void {
        const asked = transfer.parseBatchRequest(c.arena, try c.body()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedResponse => return message(c.io, c.response, .unprocessable_entity, "Unprocessable Entity"),
        };
        const operation = std.meta.stringToEnum(lfsapi.Operation, asked.operation) orelse
            return message(c.io, c.response, .unprocessable_entity, "Unknown operation");
        if (asked.hash_algo.len != 0 and !std.mem.eql(u8, asked.hash_algo, "sha256"))
            return message(c.io, c.response, .conflict, "Unsupported hash algorithm");
        if (asked.transfers.len != 0) {
            for (asked.transfers) |t| {
                if (std.mem.eql(u8, t, "basic")) break;
            } else return message(c.io, c.response, .unprocessable_entity, "Only the basic transfer adapter is served");
        }
        if (!try c.allowed(switch (operation) {
            .download => .download,
            .upload => .upload,
        })) return;

        const authorization = c.request.headers.get("authorization");
        const objects = try c.arena.alloc(transfer.BatchObject, asked.objects.len);
        for (asked.objects, objects) |o, *answer| {
            answer.* = .{ .oid = o.oid, .size = o.size };
            if (!isOid(o.oid) or o.size < 0) {
                answer.@"error" = .{ .code = 422, .message = "Invalid object" };
                continue;
            }
            const pointer: lfs.Pointer = .{ .oid = o.oid[0..64].*, .size = @intCast(o.size) };
            const held = (try c.store().size(c.io, c.repository, &pointer.oid)) == pointer.size;
            switch (operation) {
                .download => {
                    if (!held) {
                        answer.@"error" = .{ .code = 404, .message = "Object does not exist" };
                        continue;
                    }
                    answer.actions = try c.actions(&.{.{ .download, try c.action(.download, &pointer, authorization) }});
                },
                .upload => {
                    // An object the store holds needs no actions.
                    if (held) continue;
                    answer.actions = try c.actions(&.{
                        .{ .upload, try c.action(.upload, &pointer, authorization) },
                        .{ .verify, try c.own(try c.arena.print("{s}/objects/verify", .{c.base}), authorization) },
                    });
                },
            }
            answer.authenticated = authorization != null;
        }
        var out: Io.Writer.Allocating = .init(c.arena);
        transfer.writeBatch(&out.writer, .{ .transfer = "basic", .objects = objects, .hash_algo = "sha256" }) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        return json(c.io, c.response, .ok, out.written());
    }

    fn actions(c: *Call, list: []const struct { transfer.Rel, transfer.Action }) Allocator.Error!transfer.ActionSet {
        const items = try c.arena.alloc(strand.core.Pair([]const u8, ?transfer.Action), list.len);
        for (list, items) |entry, *item| item.* = .{ .key = @tagName(entry[0]), .value = entry[1] };
        return .{ .items = items };
    }

    /// The action moving `pointer`: the store's link, or the backend's own
    /// URL.
    fn action(c: *Call, operation: lfsapi.Operation, pointer: *const lfs.Pointer, authorization: ?[]const u8) ErrorNamespace.Error!transfer.Action {
        const s = c.store();
        if (s.vtable.link) |link| {
            const l = try link(s.context, c.io, c.arena, c.repository, operation, pointer);
            return .{ .href = l.href, .header = l.header, .expires_in = l.expires_in };
        }
        return c.own(try c.arena.print("{s}/objects/{s}", .{ c.base, &pointer.oid }), authorization);
    }

    /// An action back at the backend, with the request's credentials, so
    /// the transfer is authorized as the batch was.
    fn own(c: *Call, href: []const u8, authorization: ?[]const u8) Allocator.Error!transfer.Action {
        const value = authorization orelse return .{ .href = href };
        const header = try c.arena.alloc(strand.core.Pair([]const u8, []const u8), 1);
        header[0] = .{ .key = "Authorization", .value = try c.arena.dupe(u8, value) };
        return .{ .href = href, .header = .{ .items = header } };
    }

    // Transfers through the backend

    fn download(c: *Call, oid: *const [64]u8) ErrorNamespace.Error!void {
        if (!try c.allowed(.download)) return;
        const s = c.store();
        const read = s.vtable.read orelse return message(c.io, c.response, .not_found, "Not Found");
        const size = (try s.size(c.io, c.repository, oid)) orelse return message(c.io, c.response, .not_found, "Object does not exist");
        const pointer: lfs.Pointer = .{ .oid = oid.*, .size = size };
        c.response.status = .ok;
        try c.response.header("Content-Type", "application/octet-stream");
        try c.response.setLength(size);
        const w = try c.response.writer(c.io);
        if (!try read(s.context, c.io, c.repository, &pointer, w)) {
            // Gone between the two questions: nothing has been sent yet
            // unless the object was, so the length said is what is owed.
            return message(c.io, c.response, .not_found, "Object does not exist");
        }
        try c.response.end(c.io);
    }

    fn upload(c: *Call, oid: *const [64]u8) ErrorNamespace.Error!void {
        if (!try c.allowed(.upload)) return;
        const s = c.store();
        const write = s.vtable.write orelse return message(c.io, c.response, .not_found, "Not Found");
        const length = c.request.headers.get("content-length") orelse return message(c.io, c.response, .length_required, "Length Required");
        const size = decimal.digits(u64, length) orelse return message(c.io, c.response, .bad_request, "Bad Request");
        const pointer: lfs.Pointer = .{ .oid = oid.*, .size = size };
        write(s.context, c.io, c.repository, &pointer, c.request.reader(c.io)) catch |err| switch (err) {
            error.LfsObjectMismatch => return message(c.io, c.response, .unprocessable_entity, "The upload is not the object it names"),
            else => |e| return e,
        };
        return json(c.io, c.response, .ok, "");
    }

    fn verify(c: *Call) ErrorNamespace.Error!void {
        if (!try c.allowed(.upload)) return;
        const asked = lfsapi.parseJson(transfer.RequestObject, c.arena, try c.body(), .program) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedResponse => return message(c.io, c.response, .unprocessable_entity, "Unprocessable Entity"),
        };
        if (!isOid(asked.oid)) return message(c.io, c.response, .unprocessable_entity, "Invalid object");
        const size = (try c.store().size(c.io, c.repository, asked.oid[0..64])) orelse
            return message(c.io, c.response, .not_found, "Object does not exist");
        if (size != asked.size) return message(c.io, c.response, .unprocessable_entity, "Object is not of that size");
        return json(c.io, c.response, .ok, "");
    }

    // The locking API

    fn createLock(c: *Call) ErrorNamespace.Error!void {
        if (!try c.allowed(.upload)) return;
        const asked = locks.parseRequest(locks.LockRequest, c.arena, try c.body()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedResponse => return message(c.io, c.response, .unprocessable_entity, "Unprocessable Entity"),
        };
        if (asked.path.len == 0) return message(c.io, c.response, .unprocessable_entity, "A lock needs a path");
        var table = try lock_store.Table.take(c.b.gpa, c.arena, c.io, c.remote.repo.gitDirectory().get());
        defer table.deinit();
        for (table.list) |l| if (std.mem.eql(u8, l.path, asked.path)) {
            return c.lockAnswer(.conflict, l, "lock already created");
        };
        var raw: [16]u8 = undefined;
        c.io.random(&raw);
        const taken: locks.Lock = .{
            .id = try c.arena.print("{x}", .{&raw}),
            .path = asked.path,
            .owner = c.user,
            .locked_at = .{ .unix = c.b.options.caller.now(c.b.options.caller.context) },
        };
        try table.save(try std.mem.concat(c.arena, locks.Lock, &.{ table.list, &.{taken} }));
        return c.lockAnswer(.created, taken, null);
    }

    fn listLocks(c: *Call) ErrorNamespace.Error!void {
        if (!try c.allowed(.download)) return;
        const query = c.request.query orelse "";
        const path = try queryValue(c.arena, query, "path");
        const id = try queryValue(c.arena, query, "id");
        const all = try lock_store.read(c.arena, c.io, c.remote.repo.gitDirectory().get());
        var matching: std.ArrayList(locks.Lock) = .empty;
        for (all) |l| {
            if (path) |p| if (!std.mem.eql(u8, l.path, p)) continue;
            if (id) |i| if (!std.mem.eql(u8, l.id, i)) continue;
            try matching.append(c.arena, l);
        }
        const limit = try c.pageLimit(try queryValue(c.arena, query, "limit"));
        const page = lock_store.paged(matching.items, try queryValue(c.arena, query, "cursor"), limit);
        var out: Io.Writer.Allocating = .init(c.arena);
        try c.written(locks.writeListPage(&out.writer, page.locks, page.next));
        return json(c.io, c.response, .ok, out.written());
    }

    fn verifyLocks(c: *Call) ErrorNamespace.Error!void {
        if (!try c.allowed(.upload)) return;
        const asked = locks.parseRequest(locks.VerifyRequest, c.arena, try c.body()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedResponse => return message(c.io, c.response, .unprocessable_entity, "Unprocessable Entity"),
        };
        const all = try lock_store.read(c.arena, c.io, c.remote.repo.gitDirectory().get());
        const limit: usize = if (asked.limit > 0) @intCast(asked.limit) else c.b.options.lock_page;
        const page = lock_store.paged(all, if (asked.cursor.len != 0) asked.cursor else null, limit);
        var ours: std.ArrayList(locks.Lock) = .empty;
        var theirs: std.ArrayList(locks.Lock) = .empty;
        for (page.locks) |l| {
            const mine = if (c.user) |me| if (l.owner) |o| std.mem.eql(u8, o, me) else false else false;
            try (if (mine) &ours else &theirs).append(c.arena, l);
        }
        var out: Io.Writer.Allocating = .init(c.arena);
        try c.written(locks.writeVerifyPage(&out.writer, ours.items, theirs.items, page.next));
        return json(c.io, c.response, .ok, out.written());
    }

    fn unlock(c: *Call, id: []const u8) ErrorNamespace.Error!void {
        if (!try c.allowed(.upload)) return;
        const asked = locks.parseRequest(locks.UnlockRequest, c.arena, try c.body()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedResponse => return message(c.io, c.response, .unprocessable_entity, "Unprocessable Entity"),
        };
        var table = try lock_store.Table.take(c.b.gpa, c.arena, c.io, c.remote.repo.gitDirectory().get());
        defer table.deinit();
        const at = for (table.list, 0..) |l, i| {
            if (std.mem.eql(u8, l.id, id)) break i;
        } else return message(c.io, c.response, .not_found, "Lock not found");
        const held = table.list[at];
        const mine = if (c.user) |me| if (held.owner) |o| std.mem.eql(u8, o, me) else false else false;
        if (!mine) {
            if (!asked.force) return c.lockAnswer(.forbidden, held, "lock is owned by someone else");
            if (!try c.allowed(.force_unlock)) return;
        }
        try table.save(try std.mem.concat(c.arena, locks.Lock, &.{ table.list[0..at], table.list[at + 1 ..] }));
        return c.lockAnswer(.ok, held, null);
    }

    fn lockAnswer(c: *Call, status: std.http.Status, l: ?locks.Lock, text: ?[]const u8) ErrorNamespace.Error!void {
        var out: Io.Writer.Allocating = .init(c.arena);
        try c.written(locks.writeLockAnswer(&out.writer, l, text));
        return json(c.io, c.response, status, out.written());
    }

    /// A lock answer written, or a time Go cannot write: a lock's time is
    /// the caller's clock, which is the caller's to keep in range.
    fn written(_: *Call, wrote: locks.WriteAnswerError!void) ErrorNamespace.Error!void {
        wrote catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.UnwritableTime => return error.UnwritableTime,
        };
    }

    fn pageLimit(c: *Call, text: ?[]const u8) ErrorNamespace.Error!usize {
        const t = text orelse return c.b.options.lock_page;
        // As the server's Go reads it: `strconv.Atoi`.
        const n = decimal.goInt(usize, t) orelse return c.b.options.lock_page;
        return if (n == 0) c.b.options.lock_page else n;
    }
};

fn queryValue(arena: Allocator, query: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        // As Go's `url.ParseQuery`: a `+` is a space.
        const spaced = try arena.dupe(u8, pair[eq + 1 ..]);
        std.mem.replaceScalar(u8, spaced, '+', ' ');
        return try percent.decode(arena, spaced, .decode);
    }
    return null;
}

fn isOid(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn json(io: Io, response: *Response, status: std.http.Status, bytes: []const u8) Response.Error!void {
    response.status = status;
    try response.header("Content-Type", lfsapi.media_type);
    return response.send(io, bytes);
}

/// An error, as the API's JSON: `{"message": ...}`.
fn message(io: Io, response: *Response, status: std.http.Status, text: []const u8) Response.Error!void {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // unreachable: every message is a constant far shorter than the buffer
    std.json.Stringify.value(.{ .message = text }, .{}, &w) catch unreachable;
    return json(io, response, status, w.buffered());
}

fn methodNotAllowed(io: Io, response: *Response) Response.Error!void {
    return message(io, response, .method_not_allowed, "Method Not Allowed");
}

test "the API is found under a repository's info/lfs" {
    try std.testing.expectEqual(@as(?usize, 9), lfsPath("/repo.git/info/lfs/objects/batch"));
    try std.testing.expectEqual(@as(?usize, 9), lfsPath("/repo.git/info/lfs"));
    try std.testing.expectEqual(@as(?usize, null), lfsPath("/repo.git/info/lfsx"));
    try std.testing.expectEqual(@as(?usize, null), lfsPath("/repo.git/info/refs"));
}

test "a page starts at its cursor and names the next" {
    const list = [_]locks.Lock{ .{ .id = "a", .path = "1" }, .{ .id = "b", .path = "2" }, .{ .id = "c", .path = "3" } };
    const first = lock_store.paged(&list, null, 2);
    try std.testing.expectEqual(@as(usize, 2), first.locks.len);
    try std.testing.expectEqualStrings("c", first.next.?);
    const second = lock_store.paged(&list, first.next, 2);
    try std.testing.expectEqualStrings("c", second.locks[0].id);
    try std.testing.expectEqual(@as(?[]const u8, null), second.next);
}
