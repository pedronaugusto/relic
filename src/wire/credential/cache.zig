//! git's `credential-cache`, in process: credentials held in memory by a
//! daemon on a unix socket, for as long as each was stored for.
//!
//! The client is git's `credential-cache`: it connects to the socket,
//! writes `action=<action>` and `timeout=<seconds>` and then the helper's
//! input, shuts its side, and reads what the daemon answers to its end.
//! With no daemon there, `get` and `erase` answer nothing, as git's do; a
//! `store` starts one, which git does by running `git
//! credential-cache--daemon` and which a library cannot do for its caller:
//! the caller names how one starts (`credential.Options.cache_daemon`).
//!
//! The daemon is `cache/daemon.zig`'s.

const Self = @This();

const std = @import("std");
const reactor = @import("reactor");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    /// The socket cannot be reached for a reason other than no daemon
    /// listening there: git's "unable to connect to cache daemon".
    CacheUnreachable,
    /// The daemon's conversation broke: git's "unable to write to cache
    /// daemon" or "read error from cache daemon".
    CacheConversationFailed,
} || Allocator.Error || Io.Cancelable;

/// How a daemon starts where a `store` finds none listening. git runs
/// `git credential-cache--daemon <socket>` and waits until it listens;
/// relic leaves it to the caller, which may run `cache/daemon.zig`'s `Daemon`
/// on a task of its own (its `InProcess`) or start a process.
pub const Starter = struct {
    context: ?*anyopaque = null,
    /// Start a daemon at `socket`, an absolute path, returning once it
    /// listens.
    start: *const fn (context: ?*anyopaque, io: Io, socket: []const u8) StartError!void,
};

pub const StartError = error{
    /// git's "cache daemon did not start".
    CacheDaemonNotStarted,
} || Io.Cancelable;

/// What a client asks.
pub const Action = enum { get, store, erase, exit };

/// The seconds a credential is held for when the helper names none:
/// git's `--timeout` default.
pub const default_timeout: i32 = 900;

/// The most a request or an answer may hold; git reads any length.
pub const max_request = 1 << 20;

/// git's `get_socket_path`: `~/.git-credential-cache/socket` when that
/// directory is there, else `$XDG_CACHE_HOME/git/credential/socket`
/// (`~/.cache/git/credential/socket` without it); `null` with no home to
/// name either. `arena`'s.
pub fn defaultSocket(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    const home = environ.get("HOME");
    if (home) |h| {
        const old = try Io.Dir.path.join(arena, &.{ h, ".git-credential-cache" });
        if (Io.Dir.cwd().statFile(io, old, .{})) |st| {
            if (st.kind == .directory) return try Io.Dir.path.join(arena, &.{ old, "socket" });
        } else |_| {}
    }
    if (environ.get("XDG_CACHE_HOME")) |xdg| if (xdg.len != 0) {
        return try Io.Dir.path.join(arena, &.{ xdg, "git", "credential", "socket" });
    };
    const h = home orelse return null;
    return try Io.Dir.path.join(arena, &.{ h, ".cache", "git", "credential", "socket" });
}

/// What a client sends.
pub const Request = struct {
    action: Action,
    /// The seconds to hold a stored credential for.
    timeout: i32 = default_timeout,
    /// The helper's input, as git relays it.
    input: []const u8,
};

/// git's `send_request`: `req` to the daemon at `socket`, and what it
/// answers, `gpa`'s; `null` when no daemon listens there (the socket is
/// not there, or refuses), which git's `do_cache` passes over.
pub fn request(gpa: Allocator, io: Io, socket: []const u8, req: Request) Self.Error!?[]u8 {
    const address = Io.net.UnixAddress.init(socket) catch return error.CacheUnreachable;
    const stream = reactor.net.connectUnix(io, &address) catch |err| switch (err) {
        // Winsock's ENETDOWN for a directory missing on the way, which git
        // for Windows' `connection_fatally_broken` takes for no daemon, is
        // reactor's FileNotFound.
        error.FileNotFound, error.ConnectionRefused => return null,
        error.Canceled => return error.Canceled,
        else => return error.CacheUnreachable,
    };
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var w = stream.writer(io, &write_buffer);
    (write: {
        w.interface.print("action={t}\ntimeout={d}\n", .{ req.action, req.timeout }) catch |e| break :write e;
        w.interface.writeAll(req.input) catch |e| break :write e;
        w.interface.flush() catch |e| break :write e;
    }) catch return if (w.err) |e| (if (e == error.Canceled) error.Canceled else error.CacheConversationFailed) else error.CacheConversationFailed;
    stream.shutdown(io, .send) catch return error.CacheConversationFailed;

    var read_buffer: [1024]u8 = undefined;
    var r = stream.reader(io, &read_buffer);
    var answer: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, answer.items);
        answer.deinit(gpa);
    }
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => switch (r.err.?) {
                // The daemon closing on its side ends the answer: git's
                // `connection_closed`.
                error.ConnectionResetByPeer => break,
                error.Canceled => return error.Canceled,
                else => return error.CacheConversationFailed,
            },
        };
        if (answer.items.len + chunk.len > max_request) return error.CacheConversationFailed;
        try answer.appendSlice(gpa, chunk);
        r.interface.toss(chunk.len);
    }
    return try answer.toOwnedSlice(gpa);
}
