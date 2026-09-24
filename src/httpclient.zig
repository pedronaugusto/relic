//! HTTP/1.1 over TCP and TLS, as git's transports need it and no more.
//!
//! The standard library's client cannot be told to trust a server without
//! checking its certificate, and the tunnel it opens through a proxy with
//! `CONNECT` carries plain HTTP — the TLS the `https` URL asked for is never
//! started inside it. A remote behind a company proxy, or one with a
//! certificate of its own that `http.sslVerify=false` is meant to accept,
//! needs both, so the connections are made here: a TCP stream, TLS on it
//! when the proxy itself is `https`, a `CONNECT` tunnel through the proxy
//! for an `https` target — or an absolute URL in the request line for an
//! `http` one, as curl sends it — and TLS for the target inside whatever
//! came before. Every layer is a `std.Io.Reader` and `std.Io.Writer` over
//! the one below, so a tunnel inside TLS inside TCP is the same code as TLS
//! alone. The parsing and the chunked framing are the standard library's.
//!
//! A connection whose response was read to its end and did not ask to be
//! closed is kept, and the next request to the same place goes over it, as
//! curl keeps one for git; a client used by several tasks at once keeps up
//! to `max_idle`, one per task, as Go's transport keeps them for git-lfs.
//! The time, which a certificate check needs, is read once per client.
//!
//! Timeouts, when a caller sets them, are kept by a watchdog task beside
//! each connection: a connection that takes too long to make, a handshake
//! that takes too long, or a read or write that moves nothing for too long
//! has its socket shut, and the request fails as `TimedOut`. The standard
//! library's own connect timeout is not there yet on any system.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// Errors from making a connection or exchanging a request.
pub const Error = error{
    /// The TCP connection could not be made, or broke.
    ConnectionFailed,
    /// The TLS handshake failed: a certificate that is not trusted, a name
    /// that does not match, a protocol the other side does not speak.
    /// `Client.tls_error` says which.
    TlsFailed,
    /// The proxy refused the tunnel. `Client.proxy_status` holds its answer.
    ProxyRefused,
    /// The proxy wants credentials it was not given, or refused the ones it
    /// was: status 407.
    ProxyAuthenticationRequired,
    /// A response that is not HTTP/1.1.
    HttpProtocolError,
    /// The system's certificates could not be read.
    CertificateBundleUnreadable,
    /// A timeout in `Client.timeouts` ran out.
    TimedOut,
    /// A body sent with a length was ended before that many bytes.
    BodyIncomplete,
} || Allocator.Error || Io.Cancelable;

/// How long each step may take; `null` is no limit.
pub const Timeouts = struct {
    /// Making the TCP connection, the name looked up included.
    connect: ?Io.Duration = null,
    /// One TLS handshake.
    handshake: ?Io.Duration = null,
    /// One read or write that moves no bytes: an answer that stops
    /// arriving, a server that stops taking a body.
    activity: ?Io.Duration = null,

    fn any(t: Timeouts) bool {
        return t.handshake != null or t.activity != null;
    }
};

/// Where a request goes.
pub const Target = struct {
    /// Whether TLS is spoken to it: `https`.
    tls: bool,
    host: []const u8,
    port: u16,

    /// Whether two targets are the same place.
    pub fn eql(a: Target, b: Target) bool {
        return a.tls == b.tls and a.port == b.port and std.ascii.eqlIgnoreCase(a.host, b.host);
    }
};

/// A proxy every connection goes through.
pub const Proxy = struct {
    host: []const u8,
    port: u16,
    /// An `https://` proxy: TLS to the proxy itself, and a tunnel inside.
    tls: bool = false,
    /// The `Proxy-Authorization` value, `Basic <base64>`, when there is one.
    authorization: ?[]const u8 = null,
    /// The lines of a `CONNECT` after its `Host`, in order, as the caller's
    /// HTTP stack writes them. `null` is curl's without a user agent:
    /// `Proxy-Authorization` when there is one, then
    /// `Proxy-Connection: Keep-Alive`.
    connect_headers: ?[]const http.Header = null,
};

/// A client: its proxy, what it trusts, and the connection it keeps.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    proxy: ?Proxy = null,
    /// Whether a server's certificate and name are checked.
    verify: bool = true,
    /// The certificates trusted. Empty and not `trusted` at the first TLS
    /// connection, the system's are read into it.
    bundle: Certificate.Bundle = .empty,
    /// Whether `bundle` holds what is to be trusted — the system's, or the
    /// caller's in their place.
    trusted: bool = false,
    bundle_lock: Io.RwLock = .init,
    /// The time certificates are checked against, read at the first TLS
    /// connection.
    now: ?Io.Timestamp = null,
    /// How long each step may take.
    timeouts: Timeouts = .{},
    /// How many connections may be kept for the requests to come.
    max_idle: usize = 1,
    /// The connections kept, the most recently used last.
    idle: std.ArrayList(*Connection) = .empty,
    /// Held for `idle`, `now`, `connections` and the two answers below, so
    /// several tasks can send at once.
    lock: Io.Mutex = .init,
    /// The proxy's status when it last refused a tunnel.
    proxy_status: ?u16 = null,
    /// Why the last TLS handshake failed.
    tls_error: ?anyerror = null,
    /// How many connections were made, for a caller that watches reuse.
    connections: u32 = 0,
    /// How many connections were made without their timeouts, because the
    /// `Io` could not run a watchdog beside them.
    unwatched: u32 = 0,

    /// A client with no proxy that checks certificates against the system's.
    pub fn init(gpa: Allocator, io: Io) Client {
        return .{ .gpa = gpa, .io = io };
    }

    /// Close the kept connections and release everything.
    pub fn deinit(c: *Client) void {
        for (c.idle.items) |conn| conn.close();
        c.idle.deinit(c.gpa);
        c.bundle.deinit(c.gpa);
        c.* = undefined;
    }

    fn clock(c: *Client) Io.Timestamp {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.now) |t| return t;
        const t = Io.Clock.real.now(c.io);
        c.now = t;
        return t;
    }

    fn note(c: *Client, comptime field: []const u8, value: anytype) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        @field(c, field) = value;
    }

    /// The system's certificates, read at the first handshake that needs
    /// them when nothing was trusted before.
    fn ensureTrusted(c: *Client) Error!void {
        c.bundle_lock.lockUncancelable(c.io);
        defer c.bundle_lock.unlock(c.io);
        if (c.trusted) return;
        try c.rescan();
    }

    /// Read the system's certificates into the bundle, which is then what
    /// is trusted, together with anything added after.
    pub fn trustSystem(c: *Client) Error!void {
        c.bundle_lock.lockUncancelable(c.io);
        defer c.bundle_lock.unlock(c.io);
        try c.rescan();
    }

    fn rescan(c: *Client) Error!void {
        c.bundle.rescan(c.gpa, c.io, c.clock()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.CertificateBundleUnreadable,
        };
        c.trusted = true;
    }

    /// Trust the certificates in the PEM file at `path`, which the bundle
    /// then holds in place of the system's unless `trustSystem` is called
    /// too.
    pub fn trustFile(c: *Client, path: []const u8) (Error || error{CertificateFileUnreadable})!void {
        c.bundle_lock.lockUncancelable(c.io);
        defer c.bundle_lock.unlock(c.io);
        c.bundle.addCertsFromFilePath(c.gpa, c.io, c.clock(), Io.Dir.cwd(), path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.CertificateFileUnreadable,
        };
        c.trusted = true;
    }

    /// Trust every certificate file in the directory at `path`.
    pub fn trustDirectory(c: *Client, path: []const u8) (Error || error{CertificateFileUnreadable})!void {
        var dir = Io.Dir.cwd().openDir(c.io, path, .{ .iterate = true }) catch return error.CertificateFileUnreadable;
        defer dir.close(c.io);
        c.bundle_lock.lockUncancelable(c.io);
        defer c.bundle_lock.unlock(c.io);
        c.bundle.addCertsFromDir(c.gpa, c.io, c.clock(), dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.CertificateFileUnreadable,
        };
        c.trusted = true;
    }

    /// A connection to `target`: a kept one when one goes there, a new one
    /// otherwise.
    pub fn connect(c: *Client, target: Target) Error!*Connection {
        return (try c.connectNoting(target)).conn;
    }

    fn connectNoting(c: *Client, target: Target) Error!struct { conn: *Connection, reused: bool } {
        if (c.takeIdle(target)) |conn| return .{ .conn = conn, .reused = true };
        return .{ .conn = try Connection.open(c, target), .reused = false };
    }

    fn takeIdle(c: *Client, target: Target) ?*Connection {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        var i = c.idle.items.len;
        while (i > 0) {
            i -= 1;
            const conn = c.idle.items[i];
            if (conn.target.eql(target)) return c.idle.orderedRemove(i);
        }
        return null;
    }

    /// Give back a connection after its exchange: kept when `reusable`,
    /// closed otherwise. The oldest kept one is closed to make room.
    pub fn release(c: *Client, conn: *Connection, reusable: bool) void {
        if (!reusable or conn.timed_out.load(.acquire) or c.max_idle == 0) return conn.close();
        const evicted = evicted: {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            c.idle.append(c.gpa, conn) catch break :evicted conn;
            if (c.idle.items.len > c.max_idle) break :evicted c.idle.orderedRemove(0);
            break :evicted null;
        };
        if (evicted) |old| old.close();
    }

    /// Send a request and read the head of its response. `body` is sent
    /// whole with its length; `null` sends none. The response is the
    /// caller's to read and `deinit`.
    pub fn send(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, body: ?[]const u8) Error!Response {
        const first = try c.connectNoting(target);
        return c.sendOn(first.conn, method, path, headers, body) catch |err| switch (err) {
            // A kept connection the server closed while it waited is
            // noticed only now; the request goes again on a new one, as
            // curl sends it again.
            error.ConnectionFailed => if (first.reused) c.sendOn(try Connection.open(c, target), method, path, headers, body) else err,
            else => err,
        };
    }

    fn sendOn(c: *Client, conn: *Connection, method: http.Method, path: []const u8, headers: []const http.Header, body: ?[]const u8) Error!Response {
        _ = c;
        var ok = false;
        defer if (!ok) conn.close();
        try conn.writeHead(method, path, headers, if (body) |b| .{ .content_length = b.len } else .none);
        if (body) |b| conn.writer().writeAll(b) catch return conn.writeFailed();
        conn.flush() catch return conn.writeFailed();
        const response = try conn.receive(method);
        ok = true;
        return response;
    }

    /// Start a request whose body is sent as it is written: in chunks, or
    /// with `length` as its `Content-Length` when it is given.
    /// `Streaming.writer`, then `Streaming.finish` for the response.
    pub fn stream(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, length: ?u64, buffer: []u8) Error!Streaming {
        const conn = try c.connect(target);
        errdefer conn.close();
        try conn.writeHead(method, path, headers, if (length) |n| .{ .content_length = n } else .chunked);
        return .{
            .conn = conn,
            .method = method,
            .body = .{
                .http_protocol_output = conn.writer(),
                .state = if (length) |n| .{ .content_length = n } else .init_chunked,
                .writer = .{
                    .buffer = buffer,
                    .vtable = if (length != null) &.{
                        .drain = http.BodyWriter.contentLengthDrain,
                        .sendFile = http.BodyWriter.contentLengthSendFile,
                    } else &.{
                        .drain = http.BodyWriter.chunkedDrain,
                        .sendFile = http.BodyWriter.chunkedSendFile,
                    },
                },
            },
        };
    }
};

/// A request whose body is being sent in chunks.
pub const Streaming = struct {
    conn: *Connection,
    method: http.Method,
    body: http.BodyWriter,

    /// Where the body is written.
    pub fn writer(s: *Streaming) *Io.Writer {
        return &s.body.writer;
    }

    /// End the body and read the head of the response. A body with a
    /// length that is short of it is `BodyIncomplete`, and the connection
    /// is closed.
    pub fn finish(s: *Streaming) Error!Response {
        s.body.writer.flush() catch return s.conn.writeFailed();
        switch (s.body.state) {
            .content_length => |left| if (left != 0) {
                s.conn.close();
                return error.BodyIncomplete;
            },
            else => {},
        }
        s.body.endUnflushed() catch return s.conn.writeFailed();
        s.conn.flush() catch return s.conn.writeFailed();
        return s.conn.receive(s.method);
    }

    /// Give up on the request; its connection is closed.
    pub fn abort(s: *Streaming) void {
        s.conn.close();
    }
};

/// A response: its head, owned, and its body, read through `reader`.
pub const Response = struct {
    conn: ?*Connection,
    /// The head's bytes, which `head` points into.
    head_bytes: []u8,
    head: http.Client.Response.Head,
    state: *Body,
    body: *Io.Reader,

    /// What reading the body needs, where it does not move.
    const Body = struct {
        http_reader: http.Reader,
        decompress: http.Decompress = undefined,
        decompress_buffer: []u8 = &.{},
        transfer_buffer: []u8,
    };

    /// The value of the first header named `name`, or `null`.
    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        var it = r.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// The body, decompressed when the server compressed it with gzip or
    /// deflate; a zstd body as it came, for the caller to decode with the
    /// window it allows.
    pub fn reader(r: *Response) *Io.Reader {
        return r.body;
    }

    /// Whether the body was read to its end, which is when the connection
    /// can carry another request.
    pub fn complete(r: *const Response) bool {
        return r.state.http_reader.state == .ready;
    }

    /// Why a read of the body failed: `TimedOut`, a TLS or HTTP framing
    /// failure, or the connection breaking.
    pub fn failure(r: *const Response) Error {
        const conn = r.conn orelse return error.ConnectionFailed;
        if (conn.timed_out.load(.acquire)) return error.TimedOut;
        if (r.state.http_reader.body_err != null) return error.HttpProtocolError;
        return conn.readFailed();
    }

    /// Release the response. Its connection is kept for the next request
    /// when the body was read to its end and the server did not ask to
    /// close.
    pub fn deinit(r: *Response) void {
        const conn = r.conn orelse return;
        const client = conn.client;
        const reusable = r.head.keep_alive and r.complete();
        client.gpa.free(r.head_bytes);
        client.gpa.free(r.state.transfer_buffer);
        if (r.state.decompress_buffer.len != 0) client.gpa.free(r.state.decompress_buffer);
        client.gpa.destroy(r.state);
        r.conn = null;
        client.release(conn, reusable);
    }
};

/// A TLS session over the layer below it, with its buffers.
const TlsLayer = struct {
    client: tls.Client,
    read_buffer: []u8,
    write_buffer: []u8,
};

/// One connection: TCP, and the layers on it.
pub const Connection = struct {
    client: *Client,
    target: Target,
    host_owned: []u8,
    stream: Io.net.Stream,
    stream_reader: Io.net.Stream.Reader,
    stream_writer: Io.net.Stream.Writer,
    stream_read_buffer: []u8,
    stream_write_buffer: []u8,
    /// TLS to an `https` proxy, then TLS to the target, as there are.
    layers: [2]?*TlsLayer = .{ null, null },
    /// Whether requests name the whole URL: through a proxy, to an `http`
    /// target.
    absolute_form: bool = false,
    /// When the read or write under way began, on the awake clock, plus
    /// one; zero when none is. Kept only when there is an activity timeout.
    busy_since: std.atomic.Value(u64) = .init(0),
    /// When the handshake under way must be done by, likewise.
    handshake_until: std.atomic.Value(u64) = .init(0),
    /// Set by the watchdog when it shut the socket.
    timed_out: std.atomic.Value(bool) = .init(false),
    watchdog: ?Io.Future(void) = null,
    /// The standard library's own reader and writer functions, which the
    /// metered ones call.
    plain_reader: *const Io.Reader.VTable = undefined,
    plain_writer: *const Io.Writer.VTable = undefined,

    fn open(c: *Client, target: Target) Error!*Connection {
        const gpa = c.gpa;
        const io = c.io;
        const conn = try gpa.create(Connection);
        errdefer gpa.destroy(conn);
        const host_owned = try gpa.dupe(u8, target.host);
        errdefer gpa.free(host_owned);
        const read_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(read_buffer);
        const write_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(write_buffer);

        const first_host = if (c.proxy) |p| p.host else target.host;
        const first_port = if (c.proxy) |p| p.port else target.port;
        var net_stream = try dial(c, first_host, first_port);
        errdefer net_stream.close(io);
        {
            c.lock.lockUncancelable(io);
            defer c.lock.unlock(io);
            c.connections += 1;
        }

        conn.* = .{
            .client = c,
            .target = .{ .tls = target.tls, .host = host_owned, .port = target.port },
            .host_owned = host_owned,
            .stream = net_stream,
            .stream_reader = net_stream.reader(io, read_buffer),
            .stream_writer = net_stream.writer(io, write_buffer),
            .stream_read_buffer = read_buffer,
            .stream_write_buffer = write_buffer,
        };
        errdefer conn.freeLayers();

        if (c.timeouts.any()) {
            if (c.timeouts.activity != null) conn.meter();
            if (io.concurrent(watch, .{conn})) |future| {
                conn.watchdog = future;
            } else |_| {
                c.note("unwatched", c.unwatched + 1);
            }
        }
        errdefer conn.stopWatching();

        if (c.proxy) |p| {
            if (p.tls) try conn.startTls(0, p.host);
            if (target.tls) {
                try conn.tunnel(p, target);
            } else conn.absolute_form = true;
        }
        if (target.tls) try conn.startTls(1, target.host);
        return conn;
    }

    /// Make the TCP connection, within `Timeouts.connect` when there is
    /// one: the connect runs as its own task, raced against a sleep.
    fn dial(c: *Client, host: []const u8, port: u16) Error!Io.net.Stream {
        const io = c.io;
        const host_name = Io.net.HostName.init(host) catch return error.ConnectionFailed;
        const limit = c.timeouts.connect orelse return plainDial(io, host_name, port);
        const Race = union(enum) {
            connected: Io.net.HostName.ConnectError!Io.net.Stream,
            expired: Io.Cancelable!void,
        };
        var buffer: [2]Race = undefined;
        var race: Io.Select(Race) = .init(io, &buffer);
        race.concurrent(.connected, Io.net.HostName.connect, .{ host_name, io, port, .{ .mode = .stream } }) catch {
            c.note("unwatched", c.unwatched + 1);
            return plainDial(io, host_name, port);
        };
        race.concurrent(.expired, Io.sleep, .{ io, limit, .awake }) catch {
            while (race.cancel()) |late| switch (late) {
                .connected => |result| if (result) |stream| return stream else |_| {},
                .expired => {},
            };
            c.note("unwatched", c.unwatched + 1);
            return plainDial(io, host_name, port);
        };
        const first = race.await() catch |err| {
            while (race.cancel()) |late| switch (late) {
                .connected => |result| if (result) |stream| stream.close(io) else |_| {},
                .expired => {},
            };
            return err;
        };
        // Whatever finished second is closed.
        while (race.cancel()) |late| switch (late) {
            .connected => |result| if (result) |stream| stream.close(io) else |_| {},
            .expired => {},
        };
        return switch (first) {
            .connected => |result| result catch |err| switch (err) {
                error.Canceled => error.Canceled,
                else => error.ConnectionFailed,
            },
            .expired => error.TimedOut,
        };
    }

    fn plainDial(io: Io, host_name: Io.net.HostName, port: u16) Error!Io.net.Stream {
        return host_name.connect(io, port, .{ .mode = .stream }) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            else => error.ConnectionFailed,
        };
    }

    /// Put the metered functions in front of the stream's own, so the
    /// watchdog sees when a read or write is under way.
    fn meter(conn: *Connection) void {
        conn.plain_reader = conn.stream_reader.interface.vtable;
        conn.plain_writer = conn.stream_writer.interface.vtable;
        conn.stream_reader.interface.vtable = &metered_reader;
        conn.stream_writer.interface.vtable = &metered_writer;
    }

    const metered_reader: Io.Reader.VTable = .{ .stream = meteredStream, .readVec = meteredReadVec };
    const metered_writer: Io.Writer.VTable = .{ .drain = meteredDrain, .sendFile = meteredSendFile };

    fn ofReader(r: *Io.Reader) *Connection {
        const sr: *Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", r));
        return @alignCast(@fieldParentPtr("stream_reader", sr));
    }

    fn ofWriter(w: *Io.Writer) *Connection {
        const sw: *Io.net.Stream.Writer = @alignCast(@fieldParentPtr("interface", w));
        return @alignCast(@fieldParentPtr("stream_writer", sw));
    }

    fn awakeNow(io: Io) u64 {
        return @intCast(Io.Clock.awake.now(io).nanoseconds + 1);
    }

    fn meteredStream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const conn = ofReader(r);
        conn.busy_since.store(awakeNow(conn.client.io), .release);
        defer conn.busy_since.store(0, .release);
        return conn.plain_reader.stream(r, w, limit);
    }

    fn meteredReadVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const conn = ofReader(r);
        conn.busy_since.store(awakeNow(conn.client.io), .release);
        defer conn.busy_since.store(0, .release);
        return conn.plain_reader.readVec(r, data);
    }

    fn meteredDrain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const conn = ofWriter(w);
        conn.busy_since.store(awakeNow(conn.client.io), .release);
        defer conn.busy_since.store(0, .release);
        return conn.plain_writer.drain(w, data, splat);
    }

    fn meteredSendFile(w: *Io.Writer, file_reader: *Io.File.Reader, limit: Io.Limit) Io.Writer.FileError!usize {
        const conn = ofWriter(w);
        return conn.plain_writer.sendFile(w, file_reader, limit);
    }

    /// The watchdog: every tenth of the shortest timeout, whether a read or
    /// write has been under way for longer than `activity`, or a handshake
    /// is past its time. Either shuts the socket, which ends what was
    /// waiting on it.
    fn watch(conn: *Connection) void {
        const io = conn.client.io;
        const t = conn.client.timeouts;
        var shortest: i96 = std.math.maxInt(i96);
        for ([_]?Io.Duration{ t.handshake, t.activity }) |d| {
            if (d) |v| shortest = @min(shortest, v.nanoseconds);
        }
        const tick: Io.Duration = .{ .nanoseconds = @max(@divTrunc(shortest, 10), std.time.ns_per_ms) };
        while (true) {
            io.sleep(tick, .awake) catch return;
            const now = awakeNow(io);
            var expired = false;
            if (t.activity) |limit| {
                const since = conn.busy_since.load(.acquire);
                if (since != 0 and now - since >= limit.nanoseconds) expired = true;
            }
            const until = conn.handshake_until.load(.acquire);
            if (until != 0 and now >= until) expired = true;
            if (expired) {
                conn.timed_out.store(true, .release);
                conn.stream.shutdown(io, .both) catch {};
                return;
            }
        }
    }

    fn stopWatching(conn: *Connection) void {
        if (conn.watchdog) |*future| future.cancel(conn.client.io);
        conn.watchdog = null;
    }

    fn freeLayers(conn: *Connection) void {
        const gpa = conn.client.gpa;
        for (&conn.layers) |*slot| if (slot.*) |layer| {
            gpa.free(layer.read_buffer);
            gpa.free(layer.write_buffer);
            gpa.destroy(layer);
            slot.* = null;
        };
    }

    /// End the TLS sessions politely, close the stream, release everything.
    pub fn close(conn: *Connection) void {
        const gpa = conn.client.gpa;
        const io = conn.client.io;
        var i: usize = conn.layers.len;
        while (i > 0) {
            i -= 1;
            if (conn.layers[i]) |layer| {
                layer.client.end() catch {};
                conn.flushFrom(i) catch {};
            }
        }
        conn.stopWatching();
        conn.stream.close(io);
        conn.freeLayers();
        gpa.free(conn.stream_read_buffer);
        gpa.free(conn.stream_write_buffer);
        gpa.free(conn.host_owned);
        gpa.destroy(conn);
    }

    /// The reader for the top layer.
    pub fn reader(conn: *Connection) *Io.Reader {
        var i: usize = conn.layers.len;
        while (i > 0) {
            i -= 1;
            if (conn.layers[i]) |layer| return &layer.client.reader;
        }
        return &conn.stream_reader.interface;
    }

    /// The writer for the top layer.
    pub fn writer(conn: *Connection) *Io.Writer {
        var i: usize = conn.layers.len;
        while (i > 0) {
            i -= 1;
            if (conn.layers[i]) |layer| return &layer.client.writer;
        }
        return &conn.stream_writer.interface;
    }

    fn readerBelow(conn: *Connection, slot: usize) *Io.Reader {
        var i = slot;
        while (i > 0) {
            i -= 1;
            if (conn.layers[i]) |layer| return &layer.client.reader;
        }
        return &conn.stream_reader.interface;
    }

    fn writerBelow(conn: *Connection, slot: usize) *Io.Writer {
        var i = slot;
        while (i > 0) {
            i -= 1;
            if (conn.layers[i]) |layer| return &layer.client.writer;
        }
        return &conn.stream_writer.interface;
    }

    /// Push everything written down through every layer to the socket.
    pub fn flush(conn: *Connection) Io.Writer.Error!void {
        return conn.flushFrom(conn.layers.len);
    }

    fn flushFrom(conn: *Connection, top: usize) Io.Writer.Error!void {
        var i: usize = @min(top + 1, conn.layers.len);
        while (i > 0) {
            i -= 1;
            if (conn.layers[i]) |layer| try layer.client.writer.flush();
        }
        try conn.stream_writer.interface.flush();
    }

    fn writeFailed(conn: *Connection) Error {
        if (conn.timed_out.load(.acquire)) return error.TimedOut;
        if (conn.stream_writer.err) |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        return error.ConnectionFailed;
    }

    fn readFailed(conn: *Connection) Error {
        if (conn.timed_out.load(.acquire)) return error.TimedOut;
        if (conn.stream_reader.err) |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        for (conn.layers) |slot| if (slot) |layer| {
            if (layer.client.read_err != null) return error.TlsFailed;
        };
        return error.ConnectionFailed;
    }

    fn startTls(conn: *Connection, slot: usize, host: []const u8) Error!void {
        const c = conn.client;
        const gpa = c.gpa;
        if (c.verify) try c.ensureTrusted();
        const layer = try gpa.create(TlsLayer);
        errdefer gpa.destroy(layer);
        layer.read_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(layer.read_buffer);
        layer.write_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(layer.write_buffer);
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
        if (c.timeouts.handshake) |limit| {
            conn.handshake_until.store(awakeNow(c.io) + @as(u64, @intCast(limit.nanoseconds)), .release);
        }
        defer conn.handshake_until.store(0, .release);
        layer.client = tls.Client.init(conn.readerBelow(slot), conn.writerBelow(slot), .{
            .host = if (c.verify) .{ .explicit = host } else .no_verification,
            .ca = if (c.verify) .{ .bundle = .{
                .gpa = gpa,
                .io = c.io,
                .lock = &c.bundle_lock,
                .bundle = &c.bundle,
            } } else .no_verification,
            .read_buffer = layer.read_buffer,
            .write_buffer = layer.write_buffer,
            .entropy = &entropy,
            .realtime_now = c.clock(),
            // HTTP says where a body ends, so an end without close_notify
            // is not a truncation it cannot see.
            .allow_truncation_attacks = true,
        }) catch |err| {
            if (conn.timed_out.load(.acquire)) return error.TimedOut;
            c.note("tls_error", err);
            return switch (err) {
                error.Canceled => error.Canceled,
                else => error.TlsFailed,
            };
        };
        conn.layers[slot] = layer;
    }

    /// Ask the proxy for a tunnel to `target` with `CONNECT`, as curl asks.
    fn tunnel(conn: *Connection, proxy: Proxy, target: Target) Error!void {
        const w = conn.writer();
        w.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ target.host, target.port, target.host, target.port }) catch return conn.writeFailed();
        if (proxy.connect_headers) |lines| {
            for (lines) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return conn.writeFailed();
        } else {
            if (proxy.authorization) |a| w.print("Proxy-Authorization: {s}\r\n", .{a}) catch return conn.writeFailed();
            w.writeAll("Proxy-Connection: Keep-Alive\r\n") catch return conn.writeFailed();
        }
        w.writeAll("\r\n") catch return conn.writeFailed();
        conn.flush() catch return conn.writeFailed();
        var r: http.Reader = .{ .in = conn.reader(), .interface = undefined, .state = .ready, .max_head_len = 16 * 1024 };
        const bytes = r.receiveHead() catch |err| return switch (err) {
            error.ReadFailed => conn.readFailed(),
            else => error.HttpProtocolError,
        };
        const head = http.Client.Response.Head.parse(bytes) catch return error.HttpProtocolError;
        const status = @intFromEnum(head.status);
        if (status / 100 == 2) return;
        conn.client.note("proxy_status", @as(?u16, status));
        return if (status == 407) error.ProxyAuthenticationRequired else error.ProxyRefused;
    }

    const BodyKind = union(enum) { none, content_length: usize, chunked };

    fn writeHead(conn: *Connection, method: http.Method, path: []const u8, headers: []const http.Header, body: BodyKind) Error!void {
        const w = conn.writer();
        const t = conn.target;
        (write: {
            w.print("{s} ", .{@tagName(method)}) catch |e| break :write e;
            if (conn.absolute_form) {
                w.print("http://{s}", .{t.host}) catch |e| break :write e;
                if (t.port != 80) w.print(":{d}", .{t.port}) catch |e| break :write e;
            }
            w.print("{s} HTTP/1.1\r\nHost: {s}", .{ path, t.host }) catch |e| break :write e;
            if (t.port != (if (t.tls) @as(u16, 443) else 80)) w.print(":{d}", .{t.port}) catch |e| break :write e;
            w.writeAll("\r\n") catch |e| break :write e;
            if (conn.absolute_form) if (conn.client.proxy.?.authorization) |a| {
                w.print("Proxy-Authorization: {s}\r\n", .{a}) catch |e| break :write e;
            };
            for (headers) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch |e| break :write e;
            switch (body) {
                .none => {},
                .content_length => |n| w.print("Content-Length: {d}\r\n", .{n}) catch |e| break :write e,
                .chunked => w.writeAll("Transfer-Encoding: chunked\r\n") catch |e| break :write e,
            }
            w.writeAll("\r\n") catch |e| break :write e;
        }) catch return conn.writeFailed();
    }

    fn receive(conn: *Connection, method: http.Method) Error!Response {
        const gpa = conn.client.gpa;
        const body = try gpa.create(Response.Body);
        errdefer gpa.destroy(body);
        body.* = .{
            .http_reader = .{ .in = conn.reader(), .interface = undefined, .state = .ready, .max_head_len = 64 * 1024 },
            .transfer_buffer = &.{},
        };
        const r = &body.http_reader;
        var bytes: []const u8 = undefined;
        while (true) {
            bytes = r.receiveHead() catch |err| return switch (err) {
                error.ReadFailed => conn.readFailed(),
                error.HttpConnectionClosing => if (conn.timed_out.load(.acquire)) error.TimedOut else error.ConnectionFailed,
                else => error.HttpProtocolError,
            };
            // An interim `100 Continue` is followed by the real answer.
            if (bytes.len >= 12 and std.mem.eql(u8, bytes[9..12], "100")) {
                r.state = .ready;
                continue;
            }
            break;
        }
        const head_bytes = try gpa.dupe(u8, bytes);
        errdefer gpa.free(head_bytes);
        const head = http.Client.Response.Head.parse(head_bytes) catch return error.HttpProtocolError;
        body.transfer_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(body.transfer_buffer);
        const status = @intFromEnum(head.status);
        const no_body = method == .HEAD or status == 204 or status == 304 or status / 100 == 1;
        const content_length: ?u64 = if (no_body) 0 else head.content_length;
        const transfer: http.TransferEncoding = if (no_body) .none else head.transfer_encoding;
        const reader_ptr = switch (head.content_encoding) {
            .identity => r.bodyReader(body.transfer_buffer, transfer, content_length),
            .gzip, .deflate => blk: {
                body.decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
                break :blk r.bodyReaderDecompressing(body.transfer_buffer, transfer, content_length, head.content_encoding, &body.decompress, body.decompress_buffer);
            },
            // Handed over as it came: the window a zstd frame needs is the
            // caller's to decide, and how much to spend on it.
            .zstd => r.bodyReader(body.transfer_buffer, transfer, content_length),
            else => return error.HttpProtocolError,
        };
        return .{ .conn = conn, .head_bytes = head_bytes, .head = head, .state = body, .body = reader_ptr };
    }
};

test "a request's head is written as curl writes it, direct and through a proxy" {
    // Written into a fixed buffer through a connection with no socket.
    var out: [512]u8 = undefined;
    var client: Client = .init(std.testing.allocator, std.testing.io);
    client.proxy = .{ .host = "proxy.example.com", .port = 3128, .authorization = "Basic YTpi" };
    var conn: Connection = undefined;
    conn.client = &client;
    conn.target = .{ .tls = false, .host = "git.example.com", .port = 8080 };
    conn.layers = .{ null, null };
    conn.absolute_form = true;
    conn.stream_writer.interface = .fixed(&out);
    try conn.writeHead(.GET, "/repo.git/info/refs?service=git-upload-pack", &.{.{ .name = "Git-Protocol", .value = "version=2" }}, .none);
    try std.testing.expectEqualStrings(
        "GET http://git.example.com:8080/repo.git/info/refs?service=git-upload-pack HTTP/1.1\r\n" ++
            "Host: git.example.com:8080\r\nProxy-Authorization: Basic YTpi\r\nGit-Protocol: version=2\r\n\r\n",
        conn.stream_writer.interface.buffered(),
    );
}

/// Test-only: a server on 127.0.0.1 that answers every request on a
/// connection with `ok`, or, `silent`, reads and never answers.
const TestServer = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    silent: bool,
    task: Io.Future(void) = undefined,
    group: Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(gpa: Allocator, io: Io, silent: bool) !*TestServer {
        const s = try gpa.create(TestServer);
        errdefer gpa.destroy(s);
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        s.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort(), .silent = silent };
        s.task = io.concurrent(serve, .{s}) catch return error.SkipZigTest;
        return s;
    }

    fn stop(s: *TestServer, gpa: Allocator) void {
        const io = s.io;
        s.stopping.store(true, .release);
        const address = Io.net.IpAddress.parse("127.0.0.1", s.port) catch unreachable;
        if (address.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
        s.task.await(io);
        s.group.cancel(io);
        s.listener.deinit(io);
        gpa.destroy(s);
    }

    fn serve(s: *TestServer) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            if (s.stopping.load(.acquire)) return stream.close(s.io);
            s.group.concurrent(s.io, handle, .{ s, stream }) catch stream.close(s.io);
        }
    }

    fn handle(s: *TestServer, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [256]u8 = undefined;
        var r = stream.reader(s.io, &read_buffer);
        var w = stream.writer(s.io, &write_buffer);
        while (true) {
            // One request's head, then the answer, unless silent.
            while (std.mem.indexOf(u8, r.interface.buffered(), "\r\n\r\n") == null) {
                r.interface.fillMore() catch return;
            }
            const end = std.mem.indexOf(u8, r.interface.buffered(), "\r\n\r\n").? + 4;
            r.interface.toss(end);
            if (s.silent) {
                while (true) r.interface.fillMore() catch return;
            }
            w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch return;
            w.interface.flush() catch return;
        }
    }
};

test "a handshake or an answer that does not come is given up on as TimedOut, and the connection is not kept" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestServer.start(gpa, io, true);
    defer server.stop(gpa);
    const limit: Io.Duration = .fromMilliseconds(100);

    var handshaking: Client = .init(gpa, io);
    defer handshaking.deinit();
    handshaking.verify = false;
    handshaking.timeouts = .{ .handshake = limit };
    try std.testing.expectError(error.TimedOut, handshaking.send(.GET, .{ .tls = true, .host = "127.0.0.1", .port = server.port }, "/", &.{}, null));

    var waiting: Client = .init(gpa, io);
    defer waiting.deinit();
    waiting.timeouts = .{ .activity = limit };
    try std.testing.expectError(error.TimedOut, waiting.send(.GET, .{ .tls = false, .host = "127.0.0.1", .port = server.port }, "/", &.{}, null));
    try std.testing.expectEqual(@as(usize, 0), waiting.idle.items.len);
    try std.testing.expectEqual(@as(u32, 0), waiting.unwatched);
}

test "tasks sending at once through one client share the connections it keeps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestServer.start(gpa, io, false);
    defer server.stop(gpa);
    var client: Client = .init(gpa, io);
    defer client.deinit();
    client.max_idle = 4;
    client.timeouts = .{ .connect = .fromSeconds(10), .activity = .fromSeconds(10) };
    const target: Target = .{ .tls = false, .host = "127.0.0.1", .port = server.port };

    const Task = struct {
        fn run(c: *Client, t: Target) Error!void {
            for (0..5) |_| {
                var response = try c.send(.GET, t, "/", &.{}, null);
                defer response.deinit();
                var body: [8]u8 = undefined;
                const n = response.reader().readSliceShort(&body) catch return response.failure();
                if (!std.mem.eql(u8, body[0..n], "ok")) return error.HttpProtocolError;
            }
        }
    };
    var group: Io.Group = .init;
    var results: [4]Error!void = undefined;
    const Wrap = struct {
        fn run(c: *Client, t: Target, out: *Error!void) void {
            out.* = Task.run(c, t);
        }
    };
    for (&results) |*out| group.concurrent(io, Wrap.run, .{ &client, target, out }) catch return error.SkipZigTest;
    try group.await(io);
    for (results) |result| try result;
    // Twenty requests, no more connections than tasks.
    try std.testing.expect(client.connections <= 4);
    try std.testing.expect(client.idle.items.len <= 4);
}

test "a connection that is not taken within the connect timeout is given up on as TimedOut" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // A listener that accepts nothing and queues one connection: past the
    // queue the kernel leaves a connection unanswered, as a host behind a
    // firewall that drops it does.
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .kernel_backlog = 1 });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var client: Client = .init(gpa, io);
    defer client.deinit();
    client.timeouts = .{ .connect = .fromMilliseconds(200) };
    var held: std.ArrayList(*Connection) = .empty;
    defer {
        for (held.items) |conn| conn.close();
        held.deinit(gpa);
    }
    // Fill the queue — its length is the kernel's to choose — until a
    // connection is not taken.
    var timed_out = false;
    for (0..8) |_| {
        const started = Io.Clock.awake.now(io);
        const conn = client.connect(.{ .tls = false, .host = "127.0.0.1", .port = port }) catch |err| {
            try std.testing.expectEqual(error.TimedOut, err);
            const waited = started.durationTo(Io.Clock.awake.now(io));
            try std.testing.expect(waited.nanoseconds >= 150 * std.time.ns_per_ms);
            timed_out = true;
            break;
        };
        try held.append(gpa, conn);
    }
    try std.testing.expect(timed_out);
    try std.testing.expectEqual(@as(u32, 0), client.unwatched);
}
