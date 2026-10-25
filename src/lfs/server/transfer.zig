//! git-lfs's pure-ssh protocol, served: what `git-lfs-transfer <path>
//! <operation>` is on an ssh server, version 1 of it, as git-lfs's client
//! speaks it (`ssh.zig` is relic's).
//!
//! The server offers `version=1` and `locking`; the client says `version
//! 1`, then asks in requests -- a command, its arguments, and after a
//! delimiter its lines or its data -- and each is answered with a status,
//! its arguments, and after a delimiter its lines or its data. `batch`
//! answers each object with the action the connection's operation takes on
//! it: an upload of what the store lacks, a download of what it has, a
//! `noop` otherwise. `get-object`, `put-object` and `verify-object` move
//! and check an object through the store, its bytes carried in packets as
//! they come; an upload is kept only when its SHA-256 and length are the
//! ones it was sent for. `lock`, `list-lock` and `unlock` take, list and
//! give back locks on paths, kept as `server.zig` keeps them, in
//! `<git dir>/lfs/locks.json`. `quit` ends the connection.
//!
//! The objects are in the `server.Store` the caller gives, which carries
//! them (`server.Directory`); a store that only hands out links has nothing
//! to give over ssh. Who may do what is the caller's: `Caller.authorize` is
//! asked for each request with what it asks to do, as the HTTP backend asks
//! it, and says who the connection is -- the name a lock is held in -- or
//! no. Actions may carry an id and a token the caller makes and checks
//! (`Tokens`), which the client sends back with the object.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pkt_line = @import("../../codec.zig").pkt_line;
const local = @import("../../transport/local.zig");
const http_backend = @import("../../transport/http_backend.zig");
const decimal = @import("../../text.zig").decimal;
const lfs = @import("../lfs.zig");
const locks = @import("../locks.zig");
const lock_store = @import("lock_store.zig");
const server = @import("store.zig");

/// Errors from serving a connection: the conversation's, the store's and
/// the locks'.
pub const Error = error{
    /// The client sent something that is not the protocol.
    ProtocolError,
    /// Writing to the client failed.
    WriteFailed,
} || pkt_line.ReadError || server.Store.Error || lock_store.Error;

/// What `Caller.authorize` says of a request.
pub const Verdict = union(enum) {
    /// Go ahead, as this person, or as no one in particular.
    allow: ?[]const u8,
    /// No: 403.
    deny,
};

/// What the caller decides, and knows, that relic does not.
pub const Caller = struct {
    context: ?*anyopaque = null,
    /// Whether this connection may do what `access` names to the
    /// repository at `repository` (the path under the root), and as whom:
    /// ssh has authenticated it before the program starts.
    authorize: *const fn (context: ?*anyopaque, repository: []const u8, access: server.Access) Verdict,
    /// Seconds since the Unix epoch, when a lock is taken.
    now: *const fn (context: ?*anyopaque) i64,
};

/// The id and token an action carries, which the client sends back with
/// `get-object`, `put-object` and `verify-object`.
pub const Tokens = struct {
    context: ?*anyopaque = null,
    /// The id, token and lifetime for `oid`'s action, in `arena`.
    issue: *const fn (context: ?*anyopaque, arena: Allocator, oid: []const u8) Allocator.Error!Token,
    /// Whether `id` and `token`, as the client sent them, are `oid`'s.
    check: *const fn (context: ?*anyopaque, oid: []const u8, id: ?[]const u8, token: ?[]const u8) bool,
};

pub const Token = struct {
    id: []const u8,
    token: []const u8,
    /// Seconds it works for, `null` for no end said.
    expires_in: ?i64 = null,
};

/// How the connection is served.
pub const Options = struct {
    store: server.Store,
    caller: Caller,
    /// `null` gives actions no id or token, and asks for none back.
    tokens: ?Tokens = null,
    /// The most locks a page of a listing holds when the client names no
    /// limit.
    lock_page: u32 = 100,
};

/// What the connection was started for: `git-lfs-transfer`'s second
/// argument.
pub const Operation = enum {
    upload,
    download,

    pub fn named(text: []const u8) ?Operation {
        return std.meta.stringToEnum(Operation, text);
    }
};

/// One request: its command, its arguments, and its lines. A request that
/// carries data -- `put-object` -- leaves it to be read by `answer`.
pub const Request = struct {
    command: []const u8,
    args: []const []const u8,
    lines: []const []const u8 = &.{},
    /// Data follows on the connection, to a flush.
    data: bool = false,

    /// The value of `key=` among the arguments.
    pub fn arg(r: Request, key: []const u8) ?[]const u8 {
        for (r.args) |a| {
            if (a.len > key.len and std.mem.startsWith(u8, a, key) and a[key.len] == '=') return a[key.len + 1 ..];
        }
        return null;
    }
};

/// A connection, request by request, for a caller that answers some of
/// them itself; `serve` is the whole of one.
pub const Session = struct {
    gpa: Allocator,
    io: Io,
    remote: *local.Remote,
    repository: []const u8,
    operation: Operation,
    options: Options,
    in: *Io.Reader,
    out: *Io.Writer,

    /// The server's first message: version 1, and locking.
    pub fn greet(s: *Session) Error!void {
        s.write(pkt_line.write(s.out, "version=1\n")) catch return error.WriteFailed;
        s.write(pkt_line.write(s.out, "locking\n")) catch return error.WriteFailed;
        s.write(pkt_line.flush(s.out)) catch return error.WriteFailed;
        s.out.flush() catch return error.WriteFailed;
    }

    fn write(_: *Session, wrote: anyerror!void) error{WriteFailed}!void {
        wrote catch return error.WriteFailed;
    }

    /// The next request, its strings in `arena`; `null` when the client
    /// has hung up.
    pub fn next(s: *Session, arena: Allocator) Error!?Request {
        const first = pkt_line.read(s.in) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        const command = switch (first) {
            .data => |d| try arena.dupe(u8, chomp(d.readForParse())),
            else => return error.ProtocolError,
        };
        var args: std.ArrayList([]const u8) = .empty;
        while (true) {
            switch (try pkt_line.read(s.in)) {
                .flush => return .{ .command = command, .args = args.items },
                .delim => break,
                .data => |d| try args.append(arena, try arena.dupe(u8, chomp(d.readForParse()))),
                .response_end => return error.ProtocolError,
            }
        }
        if (std.mem.startsWith(u8, command, "put-object ")) return .{ .command = command, .args = args.items, .data = true };
        var lines: std.ArrayList([]const u8) = .empty;
        while (true) {
            switch (try pkt_line.read(s.in)) {
                .flush => break,
                .data => |d| try lines.append(arena, try arena.dupe(u8, chomp(d.readForParse()))),
                else => return error.ProtocolError,
            }
        }
        return .{ .command = command, .args = args.items, .lines = lines.items };
    }

    /// Answer `req`; `false` once the client has said `quit`.
    pub fn answer(s: *Session, arena: Allocator, req: Request) Error!bool {
        const cmd = req.command;
        if (std.mem.eql(u8, cmd, "version 1")) {
            try s.status(200, &.{}, null);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            try s.status(200, &.{}, null);
            return false;
        } else if (std.mem.eql(u8, cmd, "batch")) {
            if (try s.allowed(if (s.operation == .upload) .upload else .download)) |_| try s.batch(arena, req);
        } else if (std.mem.startsWith(u8, cmd, "get-object ")) {
            if (try s.allowed(.download)) |_| try s.getObject(req, cmd["get-object ".len..]);
        } else if (std.mem.startsWith(u8, cmd, "put-object ")) {
            if (try s.allowed(.upload)) |_| try s.putObject(req, cmd["put-object ".len..]) else try s.skipData();
        } else if (std.mem.startsWith(u8, cmd, "verify-object ")) {
            if (try s.allowed(.upload)) |_| try s.verifyObject(req, cmd["verify-object ".len..]);
        } else if (std.mem.eql(u8, cmd, "lock")) {
            if (try s.allowed(.upload)) |user| try s.lock(arena, req, user);
        } else if (std.mem.eql(u8, cmd, "list-lock")) {
            if (try s.allowed(.download)) |user| try s.listLocks(arena, req, user);
        } else if (std.mem.startsWith(u8, cmd, "unlock ")) {
            if (try s.allowed(.upload)) |user| try s.unlock(arena, req, cmd["unlock ".len..], user);
        } else {
            if (req.data) try s.skipData();
            try s.status(400, &.{}, &.{"unknown command"});
        }
        return true;
    }

    /// Who the connection is, when it may do what `access` names; `null`
    /// once a 403 is answered.
    fn allowed(s: *Session, access: server.Access) Error!?Who {
        return switch (s.options.caller.authorize(s.options.caller.context, s.repository, access)) {
            .allow => |name| .{ .name = name },
            .deny => {
                try s.status(403, &.{}, &.{"forbidden"});
                return null;
            },
        };
    }

    const Who = struct { name: ?[]const u8 };

    fn batch(s: *Session, arena: Allocator, req: Request) Error!void {
        var lines: std.ArrayList([]const u8) = .empty;
        for (req.lines) |line| {
            var it = std.mem.splitScalar(u8, line, ' ');
            const oid = it.next() orelse continue;
            const size_text = it.next() orelse continue;
            if (!isOid(oid)) {
                try lines.append(arena, try arena.print("{s} {s} noop", .{ oid, size_text }));
                continue;
            }
            const have = (try s.options.store.size(s.io, s.repository, oid[0..64])) != null;
            const action: ?[]const u8 = switch (s.operation) {
                .upload => if (have) null else "upload",
                .download => if (have) "download" else null,
            };
            const name = action orelse {
                try lines.append(arena, try arena.print("{s} {s} noop", .{ oid, size_text }));
                continue;
            };
            var line_out: std.ArrayList(u8) = .empty;
            try line_out.print(arena, "{s} {s} {s}", .{ oid, size_text, name });
            if (s.options.tokens) |tokens| {
                const t = try tokens.issue(tokens.context, arena, oid);
                try line_out.print(arena, " id={s} token={s}", .{ t.id, t.token });
                if (t.expires_in) |secs| try line_out.print(arena, " expires-in={d}", .{secs});
            }
            try lines.append(arena, line_out.items);
        }
        try s.status(200, &.{"hash-algo=sha256"}, lines.items);
    }

    /// Whether the request carries what its action was given, when actions
    /// carry anything.
    fn tokenOk(s: *Session, req: Request, oid: []const u8) bool {
        const tokens = s.options.tokens orelse return true;
        return tokens.check(tokens.context, oid, req.arg("id"), req.arg("token"));
    }

    fn getObject(s: *Session, req: Request, oid: []const u8) Error!void {
        if (!isOid(oid)) return s.status(400, &.{}, &.{"not an object name"});
        if (!s.tokenOk(req, oid)) return s.status(403, &.{}, &.{"missing id or token"});
        const store = s.options.store;
        const read = store.vtable.read orelse return s.status(501, &.{}, &.{"the store does not carry objects"});
        const size = (try store.size(s.io, s.repository, oid[0..64])) orelse return s.status(404, &.{}, &.{"not found"});
        try s.writeLine("status 200\n");
        s.write(pkt_line.print(s.out, "size={d}\n", .{size})) catch return error.WriteFailed;
        s.write(pkt_line.delim(s.out)) catch return error.WriteFailed;
        var buffer: [pkt_line.max_data]u8 = undefined;
        var data: DataWriter = .init(s.out, &buffer);
        const pointer: lfs.Pointer = .{ .oid = oid[0..64].*, .size = size };
        // The status has gone: an object that vanished since its size was
        // read can only be cut short, which the client finds by its size.
        _ = try read(store.context, s.io, s.repository, &pointer, &data.interface);
        data.interface.flush() catch return error.WriteFailed;
        s.write(pkt_line.flush(s.out)) catch return error.WriteFailed;
        s.out.flush() catch return error.WriteFailed;
    }

    fn putObject(s: *Session, req: Request, oid: []const u8) Error!void {
        if (!isOid(oid) or !s.tokenOk(req, oid)) {
            try s.skipData();
            if (!isOid(oid)) return s.status(400, &.{}, &.{"not an object name"});
            return s.status(403, &.{}, &.{"missing id or token"});
        }
        const store = s.options.store;
        const write_object = store.vtable.write orelse {
            try s.skipData();
            return s.status(501, &.{}, &.{"the store does not carry objects"});
        };
        const size = decimal.digits(u64, req.arg("size") orelse "") orelse {
            try s.skipData();
            return s.status(400, &.{}, &.{"no size"});
        };
        var data: DataReader = .init(s.in);
        const pointer: lfs.Pointer = .{ .oid = oid[0..64].*, .size = size };
        const kept = write_object(store.context, s.io, s.repository, &pointer, &data.interface);
        if (data.bad) return error.ProtocolError;
        // What the store did not read is still the request's.
        try data.finish();
        kept catch |err| switch (err) {
            error.LfsObjectMismatch => return s.status(400, &.{}, &.{"the data is not the object"}),
            else => |e| return e,
        };
        try s.status(200, &.{}, null);
    }

    fn skipData(s: *Session) Error!void {
        var data: DataReader = .init(s.in);
        try data.finish();
    }

    fn verifyObject(s: *Session, req: Request, oid: []const u8) Error!void {
        if (!isOid(oid)) return s.status(400, &.{}, &.{"not an object name"});
        if (!s.tokenOk(req, oid)) return s.status(403, &.{}, &.{"missing id or token"});
        const size = (try s.options.store.size(s.io, s.repository, oid[0..64])) orelse return s.status(404, &.{}, &.{"not found"});
        if (req.arg("size")) |asked| if (decimal.digits(u64, asked) != size) return s.status(409, &.{}, &.{"not of that size"});
        try s.status(200, &.{}, null);
    }

    fn lock(s: *Session, arena: Allocator, req: Request, user: Who) Error!void {
        const path = req.arg("path") orelse return s.status(400, &.{}, &.{"no path"});
        var table = try lock_store.Table.take(s.gpa, arena, s.io, s.remote.repo.gitDirectory().get());
        defer table.deinit();
        for (table.list) |l| if (std.mem.eql(u8, l.path, path)) {
            return s.status(409, try lockArgs(arena, l), &.{"already locked"});
        };
        var raw: [16]u8 = undefined;
        s.io.random(&raw);
        const taken: locks.Lock = .{
            .id = try arena.print("{x}", .{&raw}),
            .path = path,
            .owner = user.name,
            .locked_at = .{ .unix = s.options.caller.now(s.options.caller.context) },
        };
        try table.save(try std.mem.concat(arena, locks.Lock, &.{ table.list, &.{taken} }));
        try s.status(201, try lockArgs(arena, taken), null);
    }

    fn listLocks(s: *Session, arena: Allocator, req: Request, user: Who) Error!void {
        const all = try lock_store.read(arena, s.io, s.remote.repo.gitDirectory().get());
        var matching: std.ArrayList(locks.Lock) = .empty;
        for (all) |l| {
            if (req.arg("path")) |p| if (!std.mem.eql(u8, l.path, p)) continue;
            if (req.arg("id")) |i| if (!std.mem.eql(u8, l.id, i)) continue;
            try matching.append(arena, l);
        }
        const limit = if (req.arg("limit")) |t| (decimal.goInt(usize, t) orelse s.options.lock_page) else s.options.lock_page;
        const page = lock_store.paged(matching.items, req.arg("cursor"), if (limit == 0) s.options.lock_page else limit);
        var lines: std.ArrayList([]const u8) = .empty;
        for (page.locks) |l| {
            try lines.append(arena, try arena.print("lock {s}", .{l.id}));
            try lines.append(arena, try arena.print("path {s} {s}", .{ l.id, l.path }));
            try lines.append(arena, try arena.print("locked-at {s} {s}", .{ l.id, try timeText(arena, l) }));
            if (l.owner) |owner| try lines.append(arena, try arena.print("ownername {s} {s}", .{ l.id, owner }));
            const ours = if (user.name) |me| if (l.owner) |o| std.mem.eql(u8, o, me) else false else false;
            try lines.append(arena, try arena.print("owner {s} {s}", .{ l.id, if (ours) "ours" else "theirs" }));
        }
        const args: []const []const u8 = if (page.next) |next_id| &.{try arena.print("next-cursor={s}", .{next_id})} else &.{};
        try s.status(200, args, lines.items);
    }

    fn unlock(s: *Session, arena: Allocator, req: Request, id: []const u8, user: Who) Error!void {
        var table = try lock_store.Table.take(s.gpa, arena, s.io, s.remote.repo.gitDirectory().get());
        defer table.deinit();
        const at = for (table.list, 0..) |l, i| {
            if (std.mem.eql(u8, l.id, id)) break i;
        } else return s.status(404, &.{}, &.{"no such lock"});
        const held = table.list[at];
        const mine = if (user.name) |me| if (held.owner) |o| std.mem.eql(u8, o, me) else false else false;
        if (!mine) {
            const force = if (req.arg("force")) |f| std.mem.eql(u8, f, "true") else false;
            if (!force) return s.status(403, &.{}, &.{"the lock is someone else's"});
            if (try s.allowed(.force_unlock) == null) return;
        }
        try table.save(try std.mem.concat(arena, locks.Lock, &.{ table.list[0..at], table.list[at + 1 ..] }));
        try s.status(200, try lockArgs(arena, held), null);
    }

    fn writeLine(s: *Session, text: []const u8) Error!void {
        s.write(pkt_line.write(s.out, text)) catch return error.WriteFailed;
    }

    /// `status <code>`, its arguments, and after a delimiter its lines.
    pub fn status(s: *Session, code: u16, args: []const []const u8, lines: ?[]const []const u8) Error!void {
        s.write(pkt_line.print(s.out, "status {d}\n", .{code})) catch return error.WriteFailed;
        for (args) |a| s.write(pkt_line.print(s.out, "{s}\n", .{a})) catch return error.WriteFailed;
        if (lines) |ls| {
            s.write(pkt_line.delim(s.out)) catch return error.WriteFailed;
            for (ls) |l| s.write(pkt_line.print(s.out, "{s}\n", .{l})) catch return error.WriteFailed;
        }
        s.write(pkt_line.flush(s.out)) catch return error.WriteFailed;
        s.out.flush() catch return error.WriteFailed;
    }
};

/// Errors from opening the repository a connection is for.
pub const OpenError = http_backend.OpenServedError;

/// One `git-lfs-transfer <path> <operation>` connection.
pub const Connection = struct {
    /// The directory the repositories are served from.
    root: []const u8,
    /// `<path>`: the repository under `root`, a path with no `..`, its
    /// leading `/` taken from the root.
    path: []const u8,
    operation: Operation,
    in: *Io.Reader,
    out: *Io.Writer,
};

/// Serve one connection. `false` when there is no repository at its path
/// to serve, and nothing was said.
pub fn serve(gpa: Allocator, io: Io, connection: Connection, options: Options) (Error || OpenError)!bool {
    const repository = std.mem.trim(u8, connection.path, "/");
    var remote = (try http_backend.openServed(gpa, io, connection.root, repository, true)) orelse return false;
    defer remote.deinit(io);
    var session: Session = .{ .gpa = gpa, .io = io, .remote = &remote, .repository = repository, .operation = connection.operation, .options = options, .in = connection.in, .out = connection.out };
    try session.greet();
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const req = (try session.next(arena_state.allocator())) orelse return true;
        if (!try session.answer(arena_state.allocator(), req)) return true;
    }
}

fn chomp(d: []const u8) []const u8 {
    return if (d.len != 0 and d[d.len - 1] == '\n') d[0 .. d.len - 1] else d;
}

fn isOid(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// A lock's `locked-at`, as git-lfs's Go writes a time.
fn timeText(arena: Allocator, l: locks.Lock) Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    l.locked_at.format(&out.writer) catch return error.UnwritableTime;
    return out.written();
}

/// A lock's arguments in an answer: `id=`, `path=`, `locked-at=` and
/// `ownername=`.
fn lockArgs(arena: Allocator, l: locks.Lock) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, try arena.print("id={s}", .{l.id}));
    try out.append(arena, try arena.print("path={s}", .{l.path}));
    try out.append(arena, try arena.print("locked-at={s}", .{try timeText(arena, l)}));
    if (l.owner) |owner| try out.append(arena, try arena.print("ownername={s}", .{owner}));
    return out.items;
}

/// A request's data: its packets to the flush that ends them.
const DataReader = struct {
    in: *Io.Reader,
    interface: Io.Reader,
    pending: []const u8 = &.{},
    ended: bool = false,
    /// What came was not data packets and a flush.
    bad: bool = false,

    fn init(in: *Io.Reader) DataReader {
        return .{ .in = in, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const d: *DataReader = @alignCast(@fieldParentPtr("interface", r)); // aegis: no-danger: installed only on a DataReader's interface
        while (true) {
            if (d.pending.len != 0) {
                const n = limit.minInt(d.pending.len);
                if (n == 0) return 0;
                const written = try w.write(d.pending[0..n]);
                d.pending = d.pending[written..];
                return written;
            }
            if (d.ended) return error.EndOfStream;
            const packet = pkt_line.read(d.in) catch {
                d.bad = true;
                return error.ReadFailed;
            };
            switch (packet) {
                .flush => {
                    d.ended = true;
                    return error.EndOfStream;
                },
                .data => |bytes| d.pending = bytes.readForParse(),
                else => {
                    d.bad = true;
                    return error.ReadFailed;
                },
            }
        }
    }

    /// Take the rest to its flush.
    fn finish(d: *DataReader) Error!void {
        _ = d.interface.discardRemaining() catch {
            if (d.bad) return error.ProtocolError;
        };
        if (d.bad) return error.ProtocolError;
    }
};

/// An object's bytes as data packets.
const DataWriter = struct {
    out: *Io.Writer,
    interface: Io.Writer,

    fn init(out: *Io.Writer, buffer: []u8) DataWriter {
        return .{ .out = out, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const d: *DataWriter = @alignCast(@fieldParentPtr("interface", w)); // aegis: no-danger: installed only on a DataWriter's interface
        try d.packets(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try d.packets(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try d.packets(last);
            n += last.len;
        }
        return n;
    }

    fn packets(d: *DataWriter, bytes: []const u8) Io.Writer.Error!void {
        var left = bytes;
        while (left.len != 0) {
            const n = @min(left.len, pkt_line.max_data);
            pkt_line.write(d.out, left[0..n]) catch return error.WriteFailed;
            left = left[n..];
        }
    }
};

const testing = std.testing;
const repo_mod = @import("../../repo/repo.zig");

test "a connection is served whole: an object up, checked and down, a lock taken, listed and given back, as the protocol answers them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo.git");
    var repo_dir = try tmp.dir.openDir(io, "repo.git", .{});
    var made = try repo_mod.Repository.create(gpa, io, repo_dir, .{ .default_branch = "main", .bare = true });
    made.deinit(io);
    repo_dir.close(io);
    try tmp.dir.createDirPath(io, "objects");
    var objects = try tmp.dir.openDir(io, "objects", .{});
    defer objects.close(io);
    var directory: server.Directory = .{ .dir = objects };
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const content = "an object\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    var oid: [64]u8 = undefined;
    _ = std.mem.print(&oid, "{x}", .{&digest}) catch unreachable;

    // What a client asks, one request after another.
    var asked: Io.Writer.Allocating = .init(gpa);
    defer asked.deinit();
    const w = &asked.writer;
    try pkt_line.write(w, "version 1\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "batch\n");
    try pkt_line.delim(w);
    try pkt_line.print(w, "{s} {d}\n", .{ &oid, content.len });
    try pkt_line.flush(w);
    try pkt_line.print(w, "put-object {s}\n", .{&oid});
    try pkt_line.print(w, "size={d}\n", .{content.len});
    try pkt_line.delim(w);
    try pkt_line.write(w, content);
    try pkt_line.flush(w);
    try pkt_line.print(w, "verify-object {s}\n", .{&oid});
    try pkt_line.print(w, "size={d}\n", .{content.len});
    try pkt_line.flush(w);
    try pkt_line.print(w, "get-object {s}\n", .{&oid});
    try pkt_line.flush(w);
    try pkt_line.write(w, "lock\n");
    try pkt_line.write(w, "path=a.bin\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "lock\n");
    try pkt_line.write(w, "path=a.bin\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "list-lock\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "quit\n");
    try pkt_line.flush(w);

    const Who = struct {
        fn authorize(_: ?*anyopaque, _: []const u8, _: server.Access) Verdict {
            return .{ .allow = "ada" };
        }
        fn now(_: ?*anyopaque) i64 {
            return 1790244000;
        }
    };
    var in: Io.Reader = .fixed(asked.written());
    var in_buffer: [pkt_line.max_line]u8 = undefined;
    var limited = in.limited(.unlimited, &in_buffer);
    var answered: Io.Writer.Allocating = .init(gpa);
    defer answered.deinit();
    try testing.expect(try serve(gpa, io, .{ .root = root, .path = "/repo.git", .operation = .upload, .in = &limited.interface, .out = &answered.writer }, .{
        .store = directory.store(),
        .caller = .{ .authorize = Who.authorize, .now = Who.now },
    }));

    // Every answer, its status lines in order and what it carried.
    var out: Io.Reader = .fixed(answered.written());
    var out_buffer: [pkt_line.max_line]u8 = undefined;
    var out_limited = out.limited(.unlimited, &out_buffer);
    var said: std.ArrayList(u8) = .empty;
    defer said.deinit(gpa);
    while (true) {
        const packet = pkt_line.read(&out_limited.interface) catch break;
        switch (packet) {
            .data => |unparsed| {
                const d = unparsed.readForParse();
                try said.print(gpa, "{s}{s}", .{ d, if (d.len != 0 and d[d.len - 1] == '\n') "" else "\n" });
            },
            .delim => try said.appendSlice(gpa, "--\n"),
            .flush => try said.appendSlice(gpa, "==\n"),
            .response_end => break,
        }
    }
    const text = said.items;
    const expected_batch = try gpa.print("status 200\nhash-algo=sha256\n--\n{s} {d} upload\n==\n", .{ &oid, content.len });
    defer gpa.free(expected_batch);
    try testing.expect(std.mem.startsWith(u8, text, "version=1\nlocking\n==\nstatus 200\n==\n"));
    try testing.expect(std.mem.find(u8, text, expected_batch) != null);
    // The object went up, was found, and came down whole.
    try testing.expect(std.mem.find(u8, text, "status 200\nsize=10\n--\nan object\n==\n") != null);
    // A lock taken, refused twice, and listed as ours.
    try testing.expect(std.mem.find(u8, text, "status 201\n") != null);
    try testing.expect(std.mem.find(u8, text, "status 409\n") != null);
    try testing.expect(std.mem.find(u8, text, "path=a.bin\nlocked-at=2026-09-24T10:00:00Z\nownername=ada\n") != null);
    try testing.expect(std.mem.find(u8, text, " ours\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "status 200\n==\n"));
}
