//! Reaching a remote over `git://`, git's own protocol, the way git's
//! `git_connect` reaches it: through the program `GIT_PROXY_COMMAND` or
//! `core.gitProxy` names for the host, else a TCP connection to the host's
//! port, 9418 unless the URL gives one.
//!
//! The first thing written is git daemon's request, one pkt-line:
//! `<service> <path>\0host=<host>\0`, and `\0version=2\0` after it when an
//! upload-pack is asked for protocol v2. From there the conversation is the
//! one ssh carries. A daemon that will not serve the path says so in an
//! `ERR` line, which the protocol reads as `error.RemoteError`.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const uplink = @import("uplink");
const http_enabled = @import("relic_options").http;

const fs = @import("../fs.zig");
const program = @import("../process.zig").program;
const config_mod = @import("../config/config.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const url_mod = @import("url.zig");
const connection = @import("connection.zig");

const Connection = connection.Connection;

/// The port git daemon listens on unless the URL names another.
pub const default_port: u16 = 9418;

/// Errors from starting a conversation over `git://`.
pub const Error = error{
    /// A proxy is configured, and the caller handed in no
    /// `program.Programs` to run it with.
    ProgramsNotGranted,
    /// A host beginning with `-`, which the proxy program would read as an
    /// option: git's "strange hostname".
    SuspiciousHostname,
    /// A newline in the host or the path, which would end the request's
    /// line early: git dies on it.
    NewlineInRequest,
    /// A `core.gitProxy` with no value, which git refuses.
    InvalidProxySetting,
    /// This build has no TCP dialer (relic built without `http`, so
    /// without uplink); a proxy still reaches the host.
    UnsupportedTransport,
    /// The host is no host name.
    InvalidHostName,
    /// The host has no address.
    NameNotResolved,
    /// The name was to be looked up with no task to spare, on a target
    /// with no lookup of its own.
    ConcurrencyUnavailable,
    /// The connection was not made in time.
    TimedOut,
} || connection.Error || program.Error;

/// How the conversation is started.
pub const Options = struct {
    /// The environment (`GIT_PROXY_COMMAND`, `GIT_OVERRIDE_VIRTUAL_HOST`)
    /// and the permission to run a proxy. Without it neither variable is
    /// read and a configured proxy is refused.
    programs: ?program.Programs = null,
    config: ?*const config_mod.Config = null,
    /// The program asked for on the remote side, in place of
    /// `git-upload-pack` or `git-receive-pack`.
    service_program: ?[]const u8 = null,
    /// Ask an upload-pack for protocol v2.
    protocol_v2: bool = true,
};

/// Reach `url`'s host and ask its daemon for `service` on `url`'s path.
pub fn connect(gpa: Allocator, io: Io, url: url_mod.Url, service: connection.Service, options: Options) Self.Error!*Connection {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = if (options.programs) |p| p.environ else null;
    // git's `hostandport`: the URL's target as written.
    const target = url.target();
    const virtual_host = if (environ) |e| e.get("GIT_OVERRIDE_VIRTUAL_HOST") orelse target else target;
    if (std.mem.findScalar(u8, virtual_host, '\n') != null or std.mem.findScalar(u8, url.path, '\n') != null) return error.NewlineInRequest;

    const host = if (url.user) |user| try arena.print("{s}@{s}", .{ user, url.host }) else url.host;
    const port = url.port orelse default_port;
    const conn = if (try proxyCommand(environ, options.config, target)) |command| proxied: {
        const programs = options.programs orelse return error.ProgramsNotGranted;
        if (host.len != 0 and host[0] == '-') return error.SuspiciousHostname;
        var port_buf: [8]u8 = undefined;
        // unreachable: a u16 is at most five digits
        const port_text = std.mem.print(&port_buf, "{d}", .{port}) catch unreachable;
        break :proxied try connection.Process.start(gpa, io, programs, .{
            .argv = &.{ command, host, port_text },
            .stderr = .inherit,
        });
    } else try dial(gpa, io, host, port);
    errdefer conn.deinit(io);

    // git keeps protocol v0 for every service but upload-pack.
    const v2 = options.protocol_v2 and service == .upload_pack;
    const w = try conn.request();
    writeRequest(w, options.service_program orelse service.name(), url.path, virtual_host, v2) catch |err| return conn.writeFailed(err);
    return conn;
}

/// git's request: `<service> <path>\0host=<host>\0`, then `\0version=2\0`
/// for protocol v2, as one pkt-line. Nothing else goes in it: older
/// daemons crash on any other field.
fn writeRequest(w: *Io.Writer, service: []const u8, path: []const u8, host: []const u8, v2: bool) (pkt_line.WriteError)!void {
    var line: [pkt_line.max_data]u8 = undefined;
    var fixed: Io.Writer = .fixed(&line);
    fixed.print("{s} {s}\x00host={s}\x00", .{ service, path, host }) catch return error.PacketTooLong;
    if (v2) fixed.writeAll("\x00version=2\x00") catch return error.PacketTooLong;
    try pkt_line.write(w, fixed.buffered());
}

/// The proxy git runs for `target` (the URL's `host[:port]`), as git's
/// `git_use_proxy` chooses it: `GIT_PROXY_COMMAND` if it is set, else the
/// first `core.gitProxy` that matches. A value matches every host, or with
/// ` for <domain>` a target that is the domain or ends with `.<domain>`;
/// `none` matches and names no proxy. An empty choice is none.
fn proxyCommand(environ: ?*const std.process.Environ.Map, config: ?*const config_mod.Config, target: []const u8) Self.Error!?[]const u8 {
    const chosen = choice: {
        if (environ) |e| if (e.get("GIT_PROXY_COMMAND")) |command| break :choice command;
        const c = config orelse return null;
        var entries = c.iterate(&.{"core.gitproxy"});
        while (entries.next()) |entry| {
            const value = entry.value orelse return error.InvalidProxySetting;
            const command = if (std.mem.find(u8, value, " for ")) |at| command: {
                const domain = value[at + " for ".len ..];
                if (!std.mem.endsWith(u8, target, domain)) continue;
                if (target.len != domain.len and target[target.len - domain.len - 1] != '.') continue;
                break :command value[0..at];
            } else value;
            break :choice if (std.mem.eql(u8, command, "none")) "" else command;
        }
        return null;
    };
    return if (chosen.len == 0) null else chosen;
}

/// A TCP connection to `host` on `port`, through the family's dialer,
/// with keepalive on as git's `enable_keepalive` turns it on (two hours
/// idle, the systems' own default).
fn dial(gpa: Allocator, io: Io, host: []const u8, port: u16) Self.Error!*Connection {
    if (comptime !http_enabled) return error.UnsupportedTransport;
    const dialed = uplink.net.dial(io, host, port, .{ .keepalive = .literal("7200s") }) catch |err| switch (err) {
        error.InvalidHostName => return error.InvalidHostName,
        error.NameNotResolved => return error.NameNotResolved,
        error.ConnectionFailed => return error.ConnectionFailed,
        error.TimedOut => return error.TimedOut,
        error.ConcurrencyUnavailable => return error.ConcurrencyUnavailable,
        error.Canceled => return error.Canceled,
    };
    return Socket.start(gpa, io, fs.OwnedStream.init(dialed.stream));
}

/// A conversation over a connected socket: one stream each way, the
/// server remembering it, as over a pipe.
const Socket = struct {
    gpa: Allocator,
    stream: fs.OwnedStream,
    read_buffer: []u8,
    write_buffer: []u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    connection: Connection,

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .deinit = deinit,
    };

    /// The conversation over `stream`, which it takes, closed by its
    /// connection's `deinit`.
    fn start(gpa: Allocator, io: Io, stream: fs.OwnedStream) Allocator.Error!*Connection {
        var held = stream;
        errdefer held.deinit(io);
        const s = try gpa.create(Socket);
        errdefer gpa.destroy(s);
        const read_buffer = try gpa.alloc(u8, pkt_line.max_line + 4);
        errdefer gpa.free(read_buffer);
        const write_buffer = try gpa.alloc(u8, 64 * 1024);
        s.* = .{
            .gpa = gpa,
            .stream = held.move(),
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .reader = undefined,
            .writer = undefined,
            .connection = .{ .context = s, .vtable = &vtable, .stateless = false },
        };
        const lent = s.stream.lend().get();
        s.reader = lent.reader(io, read_buffer);
        s.writer = lent.writer(io, write_buffer);
        return &s.connection;
    }

    fn of(context: *anyopaque) *Socket {
        return @ptrCast(@alignCast(context)); // safe: this vtable's context, a Socket, from start
    }

    fn advertisement(context: *anyopaque, _: *Connection) connection.Error!*Io.Reader {
        return &of(context).reader.interface;
    }

    fn request(context: *anyopaque, _: *Connection) connection.Error!*Io.Writer {
        return &of(context).writer.interface;
    }

    fn response(context: *anyopaque, c: *Connection) connection.Error!*Io.Reader {
        const s = of(context);
        s.writer.interface.flush() catch return failure(context, c);
        return &s.reader.interface;
    }

    fn failure(context: *anyopaque, c: *Connection) connection.Error {
        const s = of(context);
        if (s.reader.err) |err| if (err == error.Canceled) return error.Canceled;
        if (s.writer.err) |err| if (err == error.Canceled) return error.Canceled;
        c.message_len = 0;
        return error.ConnectionFailed;
    }

    fn deinit(io: Io, context: *anyopaque) void {
        const s = of(context);
        // A server that stopped reading has nothing more to hear; the
        // socket closes either way.
        // glint-ignore: Z026 -- the last bytes are a courtesy to a server that may have gone; closing ends the conversation regardless
        s.writer.interface.flush() catch {};
        s.stream.deinit(io);
        s.gpa.free(s.read_buffer);
        s.gpa.free(s.write_buffer);
        s.gpa.destroy(s);
    }
};
