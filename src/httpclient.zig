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
//! curl keeps one for git. The time, which a certificate check needs, is
//! read once per client.

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
} || Allocator.Error || Io.Cancelable;

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
    /// The connection kept for the next request.
    idle: ?*Connection = null,
    /// The proxy's status when it refused a tunnel.
    proxy_status: ?u16 = null,
    /// Why the last TLS handshake failed.
    tls_error: ?anyerror = null,
    /// How many connections were made, for a caller that watches reuse.
    connections: u32 = 0,

    /// A client with no proxy that checks certificates against the system's.
    pub fn init(gpa: Allocator, io: Io) Client {
        return .{ .gpa = gpa, .io = io };
    }

    /// Close the kept connection and release everything.
    pub fn deinit(c: *Client) void {
        if (c.idle) |conn| conn.close();
        c.idle = null;
        c.bundle.deinit(c.gpa);
        c.* = undefined;
    }

    fn clock(c: *Client) Io.Timestamp {
        if (c.now) |t| return t;
        const t = Io.Clock.real.now(c.io);
        c.now = t;
        return t;
    }

    /// Read the system's certificates into the bundle, which is then what
    /// is trusted, together with anything added after.
    pub fn trustSystem(c: *Client) Error!void {
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
        c.bundle.addCertsFromDir(c.gpa, c.io, c.clock(), dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.CertificateFileUnreadable,
        };
        c.trusted = true;
    }

    /// A connection to `target`: the kept one when it goes there, a new one
    /// otherwise.
    pub fn connect(c: *Client, target: Target) Error!*Connection {
        if (c.idle) |conn| {
            c.idle = null;
            if (conn.target.eql(target)) return conn;
            conn.close();
        }
        return Connection.open(c, target);
    }

    /// Give back a connection after its exchange: kept when `reusable`,
    /// closed otherwise.
    pub fn release(c: *Client, conn: *Connection, reusable: bool) void {
        if (!reusable) return conn.close();
        if (c.idle) |old| old.close();
        c.idle = conn;
    }

    /// Send a request and read the head of its response. `body` is sent
    /// whole with its length; `null` sends none. The response is the
    /// caller's to read and `deinit`.
    pub fn send(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, body: ?[]const u8) Error!Response {
        const reused = c.idle != null and c.idle.?.target.eql(target);
        return c.sendOnce(method, target, path, headers, body) catch |err| switch (err) {
            // A kept connection the server closed while it waited is
            // noticed only now; the request goes again on a new one, as
            // curl sends it again.
            error.ConnectionFailed => if (reused) c.sendOnce(method, target, path, headers, body) else err,
            else => err,
        };
    }

    fn sendOnce(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, body: ?[]const u8) Error!Response {
        const conn = try c.connect(target);
        var ok = false;
        defer if (!ok) conn.close();
        try conn.writeHead(method, path, headers, if (body) |b| .{ .content_length = b.len } else .none);
        if (body) |b| conn.writer().writeAll(b) catch return conn.writeFailed();
        conn.flush() catch return conn.writeFailed();
        const response = try conn.receive(method);
        ok = true;
        return response;
    }

    /// Start a request whose body is sent in chunks as it is written:
    /// `Streaming.writer`, then `Streaming.finish` for the response.
    pub fn stream(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, buffer: []u8) Error!Streaming {
        const conn = try c.connect(target);
        errdefer conn.close();
        try conn.writeHead(method, path, headers, .chunked);
        return .{
            .conn = conn,
            .method = method,
            .body = .{
                .http_protocol_output = conn.writer(),
                .state = .init_chunked,
                .writer = .{
                    .buffer = buffer,
                    .vtable = &.{
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

    /// End the body and read the head of the response.
    pub fn finish(s: *Streaming) Error!Response {
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

    /// The body, decompressed when the server compressed it.
    pub fn reader(r: *Response) *Io.Reader {
        return r.body;
    }

    /// Whether the body was read to its end, which is when the connection
    /// can carry another request.
    pub fn complete(r: *const Response) bool {
        return r.state.http_reader.state == .ready;
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
        const host_name = Io.net.HostName.init(first_host) catch return error.ConnectionFailed;
        var net_stream = host_name.connect(io, first_port, .{ .mode = .stream }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.ConnectionFailed,
        };
        errdefer net_stream.close(io);
        c.connections += 1;

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

        if (c.proxy) |p| {
            if (p.tls) try conn.startTls(0, p.host);
            if (target.tls) {
                try conn.tunnel(p, target);
            } else conn.absolute_form = true;
        }
        if (target.tls) try conn.startTls(1, target.host);
        return conn;
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
        if (conn.stream_writer.err) |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        return error.ConnectionFailed;
    }

    fn readFailed(conn: *Connection) Error {
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
        if (c.verify and !c.trusted) try c.trustSystem();
        const layer = try gpa.create(TlsLayer);
        errdefer gpa.destroy(layer);
        layer.read_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(layer.read_buffer);
        layer.write_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(layer.write_buffer);
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
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
            c.tls_error = err;
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
        if (proxy.authorization) |a| w.print("Proxy-Authorization: {s}\r\n", .{a}) catch return conn.writeFailed();
        w.writeAll("Proxy-Connection: Keep-Alive\r\n\r\n") catch return conn.writeFailed();
        conn.flush() catch return conn.writeFailed();
        var r: http.Reader = .{ .in = conn.reader(), .interface = undefined, .state = .ready, .max_head_len = 16 * 1024 };
        const bytes = r.receiveHead() catch |err| return switch (err) {
            error.ReadFailed => conn.readFailed(),
            else => error.HttpProtocolError,
        };
        const head = http.Client.Response.Head.parse(bytes) catch return error.HttpProtocolError;
        const status = @intFromEnum(head.status);
        if (status / 100 == 2) return;
        conn.client.proxy_status = status;
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
                error.HttpConnectionClosing => error.ConnectionFailed,
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
