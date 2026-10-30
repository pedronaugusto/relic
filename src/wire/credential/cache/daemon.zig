//! git's `credential-cache--daemon`: credentials held in memory, on a
//! unix socket of the daemon's own, for as long as each was stored for.
//!
//! `Daemon.listen` makes the socket's directory, readable by its owner
//! alone, refused when it is looser, and binds the socket; `Daemon.run`
//! answers clients one at a time until it is told `exit` or has held
//! nothing for thirty seconds. It keeps time by the `Io` it runs on.
//! `InProcess` runs daemons on tasks of this process, as the `Starter` the
//! credential options take.

const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const parts_mod = @import("../parts.zig");
const cache = @import("../cache.zig");
const credential = @import("../../credential.zig");
const decimal = @import("../../../text.zig").decimal;
const date = @import("../../../text.zig").date;
const fs = @import("../../../fs/fs.zig");

const Session = credential.Session;
const Action = cache.Action;
const max_request = cache.max_request;

pub const Error = ListenError || RunError;

/// How a running daemon ends other than as it should: a request git's
/// daemon dies on, as `error.InvalidCredentialAnswer`, or no second task
/// to wait for a client beside its clock.
pub const RunError = Allocator.Error || Io.Cancelable || Io.ConcurrentError || error{InvalidCredentialAnswer};

pub const ListenError = error{
    /// git's "socket directory must be an absolute path".
    SocketPathNotAbsolute,
    /// The socket's directory is readable or writable by others: git's
    /// "The permissions on your socket directory are too loose".
    SocketDirectoryTooOpen,
    /// git's "unable to bind to '<path>'", the path too long among the
    /// reasons.
    CacheSocketUnbound,
} || Allocator.Error || Io.Cancelable || Io.Dir.CreateDirPathError || Io.Dir.StatFileError;

/// The seconds a daemon holding nothing waits for one before it ends, and
/// waits again whenever a credential leaves it.
const grace_seconds: i64 = 30;

/// Whether a directory has a mode its owner alone may read: not on
/// Windows, where git's own check sees no such bits.
const owner_only = builtin.target.os.tag != .windows;

/// The socket's directory as git makes it, its owner's alone.
const private_dir: Io.File.Permissions = if (owner_only) .fromMode(0o700) else .default_dir;

/// One credential the daemon holds: git's `credential_cache_entry`.
const Entry = struct {
    item: Session,
    /// Seconds since the epoch; zero once erased.
    expiration: i64,
};

/// git's `credential-cache--daemon`, on a socket of its own.
pub const Daemon = struct {
    pub const Error = ListenError || RunError;

    gpa: Allocator,
    io: Io,
    server: fs.OwnedServer,
    socket_path: []u8,
    entries: std.ArrayList(Entry) = .empty,
    /// git's `wait_for_entry_until`: when a daemon holding nothing ends.
    wait_until: ?i64 = null,

    /// git's `init_socket_directory` and `unix_stream_listen`: the socket's
    /// directory made, readable by its owner alone, or refused when it is
    /// there and looser; a socket file left there replaced; the socket
    /// bound. `socket_path` is copied.
    pub fn listen(gpa: Allocator, io: Io, socket_path: []const u8) ListenError!Daemon {
        if (!Io.Dir.path.isAbsolute(socket_path)) return error.SocketPathNotAbsolute;
        const dir = Io.Dir.path.dirname(socket_path) orelse return error.SocketPathNotAbsolute;
        if (Io.Dir.cwd().statFile(io, dir, .{})) |st| {
            if (owner_only and st.permissions.toMode() & 0o077 != 0) return error.SocketDirectoryTooOpen;
        } else |err| switch (err) {
            error.FileNotFound => {
                if (Io.Dir.path.dirname(dir)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
                Io.Dir.cwd().createDir(io, dir, private_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return error.CacheSocketUnbound,
                };
            },
            else => |e| return e,
        }
        removeSocket(io, socket_path);
        const address = Io.net.UnixAddress.init(socket_path) catch return error.CacheSocketUnbound;
        var server = address.listen(io, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.CacheSocketUnbound,
        };
        errdefer server.deinit(io);
        const path = try gpa.dupe(u8, socket_path);
        return .{ .gpa = gpa, .io = io, .server = .init(server), .socket_path = path };
    }

    /// The socket closed and removed, and every credential forgotten, its
    /// secrets wiped.
    pub fn deinit(d: *Daemon) void {
        d.server.deinit(d.io);
        removeSocket(d.io, d.socket_path);
        for (d.entries.items) |*e| e.item.deinit();
        d.entries.deinit(d.gpa);
        d.gpa.free(d.socket_path);
        d.* = undefined;
    }

    /// git's `serve_cache` loop: a client at a time, until one says `exit`
    /// or nothing has been held for the grace period. A request git's
    /// daemon dies on -- a boolean or a URL it cannot read -- ends it too,
    /// as `error.InvalidCredentialAnswer`.
    pub fn run(d: *Daemon) RunError!void {
        // However it ends, its socket goes, as git's tempfile does.
        defer removeSocket(d.io, d.socket_path);
        while (true) {
            const wait = d.checkExpirations() orelse return;
            var stream = (try d.acceptWithin(wait)) orelse continue;
            defer stream.deinit(d.io);
            if (try d.serveOne(stream.lend().get()) == .exit) {
                // The socket goes before the client hears the end, as
                // git's daemon removes it at exit and only then closes.
                removeSocket(d.io, d.socket_path);
                return;
            }
        }
    }

    fn now(d: *const Daemon) i64 {
        return date.seconds(Io.Clock.real.now(d.io));
    }

    /// git's `check_expirations`: each credential past its time let go,
    /// and the seconds until the next one is, or until a daemon holding
    /// nothing ends; `null` when it ends now.
    fn checkExpirations(d: *Daemon) ?i64 {
        const now_s = d.now();
        if (d.wait_until == null) d.wait_until = now_s + grace_seconds;
        var next: i64 = std.math.maxInt(i64);
        var i: usize = 0;
        while (i < d.entries.items.len) {
            const e = &d.entries.items[i];
            if (e.expiration <= now_s) {
                e.item.deinit();
                // git moves the last into the gap, so the order a lookup
                // sees is its.
                _ = d.entries.swapRemove(i);
                d.wait_until = now_s + grace_seconds;
            } else {
                next = @min(next, e.expiration);
                i += 1;
            }
        }
        if (d.entries.items.len == 0) {
            if (d.wait_until.? <= now_s) return null;
            next = d.wait_until.?;
        }
        return next - now_s;
    }

    const Woken = union(enum) {
        accepted: Io.net.Server.AcceptError!Io.net.Stream,
        slept: Io.Cancelable!void,
    };

    /// A client, or `null` when `seconds` pass with none.
    fn acceptWithin(d: *Daemon, seconds: i64) RunError!?fs.OwnedStream {
        var buffer: [2]Woken = undefined;
        var select: Io.Select(Woken) = .init(d.io, &buffer);
        try select.concurrent(.accepted, Io.net.Server.accept, .{ d.server.borrowMut(), d.io });
        // Concurrently too: `async` runs inline once the `Io`'s async
        // threads are taken, and the daemon would sleep through its wait
        // before it accepted anyone.
        select.concurrent(.slept, Io.sleep, .{ d.io, .fromSeconds(seconds), .real }) catch |err| {
            d.cancelRest(&select);
            return err;
        };
        const first = select.await() catch |err| {
            d.cancelRest(&select);
            return err;
        };
        const stream: ?fs.OwnedStream = switch (first) {
            // A failed accept is passed over, as git's "accept failed".
            .accepted => |r| if (r) |accepted| .init(accepted) else |_| null,
            .slept => null,
        };
        d.cancelRest(&select);
        return stream;
    }

    fn cancelRest(d: *Daemon, select: *Io.Select(Woken)) void {
        while (select.cancel()) |rest| switch (rest) {
            .accepted => |r| if (r) |s| s.close(d.io) else |_| {},
            .slept => {},
        };
    }

    const Served = enum { served, exit };

    /// git's `serve_one_client`.
    fn serveOne(d: *Daemon, stream: Io.net.Stream) RunError!Served {
        // Room for a usual request, so it seldom grows.
        var text = try aegis.SecretBytes.init(d.gpa, 1024);
        defer text.deinit();
        {
            var into = aegis.SecretBytes.Writer.init(&text);
            // No buffer of the reader's: each read lands in `text`'s own
            // storage, wiped as it grows and when it is let go.
            var r = stream.reader(d.io, &.{});
            // One byte past the most a request may be says it is longer.
            while (into.interface.end <= max_request) {
                _ = r.interface.stream(&into.interface, Io.Limit.limited(max_request + 1 - into.interface.end)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return .served,
                    // The writer fails only for want of memory.
                    error.WriteFailed => return error.OutOfMemory,
                };
            } else return .served;
            into.interface.flush() catch return error.OutOfMemory;
        }
        var req = (try readRequest(d.gpa, text.expose())) orelse return .served;
        defer req.session.deinit();
        switch (req.action) {
            .get => if (d.lookup(&req.session)) |e| {
                try sendAnswer(d.gpa, d.io, stream, &e.item, req.session.capa_authtype.helper);
            },
            .exit => return .exit,
            .erase => d.remove(&req.session, true),
            .store => {
                const c = &req.session;
                const whole = (c.username != null and c.password != null) or c.authtype != null or c.credential != null;
                // git warns of a missing timeout, a partial credential and
                // an ephemeral one, to a standard error that is gone.
                if (req.timeout >= 0 and whole and !c.ephemeral) {
                    d.remove(c, false);
                    try d.entries.append(d.gpa, .{ .item = c.*, .expiration = d.now() + req.timeout });
                    req.session = Session.forRequest(d.gpa);
                }
            },
        }
        return .served;
    }

    /// git's `lookup_credential`: the first held that matches.
    fn lookup(d: *Daemon, want: *const Session) ?*Entry {
        for (d.entries.items) |*e| {
            if (parts_mod.credentialMatch(want, &e.item, false)) return e;
        }
        return null;
    }

    /// git's `remove_credential`: each match let go at the next check.
    fn remove(d: *Daemon, want: *const Session, match_password: bool) void {
        for (d.entries.items) |*e| {
            if (parts_mod.credentialMatch(want, &e.item, match_password)) e.expiration = 0;
        }
    }
};

/// What a client sent: its action, the seconds it named, and the
/// credential, read as git's `credential_read` reads a helper's input.
const Request = struct {
    action: Action,
    timeout: i64,
    session: Session,
};

/// git's `read_request`: `action=` and `timeout=` lines -- the timeout as
/// C's `atoi` reads it -- then the credential; `null` for a request git
/// passes over (a first line that is no action, a second that is no
/// timeout, an action it does not know, a credential line with no `=`).
fn readRequest(gpa: Allocator, text: []const u8) (Allocator.Error || error{InvalidCredentialAnswer})!?Request {
    var rest = text;
    const action_line = nextLine(&rest);
    const timeout_line = nextLine(&rest);
    if (!std.mem.startsWith(u8, action_line, "action=")) return null;
    if (!std.mem.startsWith(u8, timeout_line, "timeout=")) return null;
    // git warns of an action it does not know and does nothing.
    const action = std.meta.stringToEnum(Action, action_line["action=".len..]) orelse return null;
    const read = decimal.strtol(timeout_line["timeout=".len..], 10, 32);
    // `credential_read` gives up at a line with no `=`, and the daemon
    // with it.
    var lines = rest;
    while (lines.len != 0) {
        const line = std.mem.trimEnd(u8, nextLine(&lines), "\r");
        if (line.len == 0) break;
        if (std.mem.findScalar(u8, line, '=') == null) return null;
    }
    var session = Session.forRequest(gpa);
    errdefer session.deinit();
    _ = session.readAnswer(.init(rest)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCredentialAnswer,
    };
    return .{ .action = action, .timeout = @intCast(read.value), .session = session };
}

/// The text to the next newline, which is taken: git's
/// `strbuf_getline_lf`.
fn nextLine(rest: *[]const u8) []const u8 {
    const nl = std.mem.findScalar(u8, rest.*, '\n') orelse {
        const line = rest.*;
        rest.* = "";
        return line;
    };
    const line = rest.*[0..nl];
    rest.* = rest.*[nl + 1 ..];
    return line;
}

/// The answer written and sent; a client gone before it is git's write to
/// a closed socket, which the daemon goes on from. A cancel is the
/// daemon's own end, and is returned.
/// `answer`, built in storage that is wiped when it is let go and sent
/// whole, so the credential in it is held nowhere else.
fn sendAnswer(gpa: Allocator, io: Io, stream: Io.net.Stream, e: *const Session, authtype_asked: bool) (Allocator.Error || Io.Cancelable)!void {
    var text = try aegis.SecretBytes.init(gpa, 256);
    defer text.deinit();
    {
        var into = aegis.SecretBytes.Writer.init(&text);
        // The writer fails only for want of memory.
        answer(&into.interface, e, authtype_asked) catch return error.OutOfMemory;
        into.interface.flush() catch return error.OutOfMemory;
    }
    var w = stream.writer(io, &.{});
    // A client that left has nothing waiting for this answer.
    w.interface.writeAll(text.expose()) catch {
        if (w.err) |err| if (err == error.Canceled) return error.Canceled;
    };
}

/// The socket file removed: one already gone is what was wanted.
fn removeSocket(io: Io, path: []const u8) void {
    fs.removeLeftover(io, Io.Dir.cwd(), path);
}

/// git's answer to `get` for a credential it holds: the `authtype`
/// capability, then what it holds, `authtype` and `credential` only to a
/// client that announced the capability.
fn answer(w: *Io.Writer, e: *const Session, authtype_asked: bool) Io.Writer.Error!void {
    try w.writeAll("capability[]=authtype\n");
    if (e.username) |v| try w.print("username={s}\n", .{v});
    if (e.password) |*v| try w.print("password={s}\n", .{v.expose()});
    if (authtype_asked) {
        if (e.authtype) |v| try w.print("authtype={s}\n", .{v});
        if (e.credential) |*v| try w.print("credential={s}\n", .{v.expose()});
    }
    if (e.password_expiry_utc != std.math.maxInt(u64)) try w.print("password_expiry_utc={d}\n", .{e.password_expiry_utc});
    if (e.oauth_refresh_token) |*v| try w.print("oauth_refresh_token={s}\n", .{v.expose()});
}

/// Daemons on tasks of this process, for as long as it runs: the
/// `cache.Starter` that serves a caller with no daemon process of its own.
/// A daemon that ends -- `exit`, nothing held, a request git's dies on --
/// takes its socket away and stays listed until `deinit`.
pub const InProcess = struct {
    pub const Error = cache.StartError;

    gpa: Allocator,
    io: Io,
    group: Io.Group = .init,
    daemons: Daemons = Daemons.init(.empty),

    const Daemons = aegis.BlockingGuarded(std.ArrayList(*Daemon));

    pub fn init(gpa: Allocator, io: Io) InProcess {
        return .{ .gpa = gpa, .io = io };
    }

    /// Every daemon stopped and forgotten, its secrets wiped.
    pub fn deinit(p: *InProcess) void {
        p.group.cancel(p.io);
        const daemons = p.daemons.teardown();
        for (daemons.items) |d| {
            d.deinit();
            p.gpa.destroy(d);
        }
        daemons.deinit(p.gpa);
        p.* = undefined;
    }

    pub fn starter(p: *InProcess) cache.Starter {
        return .{ .context = p, .start = start };
    }

    fn start(context: ?*anyopaque, io: Io, socket: []const u8) cache.StartError!void {
        const p: *InProcess = @ptrCast(@alignCast(context.?)); // aegis: no-danger(A019): the context `starter` hands out is this `InProcess`
        const d = p.gpa.create(Daemon) catch return error.CacheDaemonNotStarted;
        d.* = Daemon.listen(p.gpa, io, socket) catch |err| {
            p.gpa.destroy(d);
            return if (err == error.Canceled) error.Canceled else error.CacheDaemonNotStarted;
        };
        {
            var guard = p.daemons.acquire(io) catch |err| {
                d.deinit();
                p.gpa.destroy(d);
                return err;
            };
            defer guard.deinit(io);
            guard.value().append(p.gpa, d) catch {
                d.deinit();
                p.gpa.destroy(d);
                return error.CacheDaemonNotStarted;
            };
        }
        p.group.concurrent(io, serve, .{d}) catch {
            // Listening with no one to answer: no socket, rather.
            removeSocket(io, d.socket_path);
            return error.CacheDaemonNotStarted;
        };
    }

    fn serve(d: *Daemon) void {
        // glint-ignore: Z026 -- a daemon's end, however it comes, is its socket gone, which `run` sees to; no one waits on it
        d.run() catch {};
    }
};

const shakedown = @import("shakedown");
const url_mod = @import("../../url.zig");

test "a cancel that lands in sending an answer is the daemon's end, not lost with the client" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const served = try listener.accept(io);
    defer served.close(io);
    var e: Session = .{ .gpa = gpa, .url = try url_mod.Url.parse("https://example.com/r") };
    defer e.deinit();
    const plan = [_]shakedown.IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .net_write, .n = 1 } }, .fault = .cancel, .times = 1 }};
    const faults = try shakedown.FaultIo.init(gpa, io, .{ .plan = &plan });
    defer faults.deinit();
    try std.testing.expectError(error.Canceled, sendAnswer(gpa, faults.io(), served, &e, false));
}
