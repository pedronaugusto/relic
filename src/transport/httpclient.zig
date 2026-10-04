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
//! came before. SOCKS4/4a/5/5h instead open a CONNECT tunnel for both
//! HTTP and HTTPS, with origin TLS started inside it. Every layer is a
//! `std.Io.Reader` and `std.Io.Writer` over
//! the one below, so a tunnel inside TLS inside TCP is the same code as TLS
//! alone. The parsing and the chunked framing are the standard library's.
//!
//! TLS is relic's own client (`tls/`): the standard library's, which
//! answers no server's request for a certificate, with client certificates
//! added — `Client.client_auth` for the server, `Proxy.client_auth` for an
//! `https` proxy. Every TLS connection relic makes goes through it.
//!
//! A connection whose response was read to its end and did not ask to be
//! closed is kept, and the next request to the same place goes over it, as
//! curl keeps one for git; a client used by several tasks at once keeps up
//! to `max_idle`, one per task, as Go's transport keeps them for git-lfs.
//! Each TLS handshake checks certificates against the current real time.
//!
//! Timeouts, when a caller sets them, are kept by a watchdog task beside
//! each connection: a connection that takes too long to make, a handshake
//! that takes too long, or a read or write that moves nothing for too long
//! has its socket shut, and the request fails as `TimedOut`. The standard
//! library's own connect timeout is not there yet on any system.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const tls = @import("tls.zig");
const httpauth = @import("httpauth.zig");
const socks = @import("socks.zig");
pub const SocksError = socks.Error;
const Certificate = std.crypto.Certificate;

/// Errors from making a connection or exchanging a request.
pub const Error = error{
    /// The TCP connection could not be made, or broke.
    ConnectionFailed,
    /// The TLS handshake failed: a certificate that is not trusted, a name
    /// that does not match, a protocol the other side does not speak.
    /// `Diagnostic.tls_error` says which.
    TlsFailed,
    /// The proxy refused the tunnel. `Diagnostic.proxy_status` holds its answer.
    ProxyRefused,
    /// The proxy wants credentials it was not given, or refused the ones it
    /// was: HTTP status 407 or a SOCKS authentication refusal.
    ProxyAuthenticationRequired,
    /// A response that is not HTTP/1.1.
    HttpProtocolError,
    /// The system's certificates could not be read.
    CertificateBundleUnreadable,
    /// A timeout in `Client.timeouts` ran out.
    TimedOut,
    /// The proxy asks to be answered only in schemes relic does not speak
    /// — Negotiate, NTLM — or none the credential's method allows.
    /// `Diagnostic.proxy_offered` names them.
    ProxyAuthMethodUnsupported,
    /// A body sent with a length was ended before that many bytes.
    BodyIncomplete,
    /// The server asked for a client certificate and refused the one it
    /// was sent, or wanted one and was sent none: its TLS alert is in
    /// `Diagnostic.tls_error`.
    ClientCertificateRejected,
    /// The server asked for a client certificate in signature schemes the
    /// key does not sign with.
    ClientCertificateSchemeUnsupported,
} || SocksError || Allocator.Error || Io.Cancelable;

/// Caller-owned failure details for one HTTP exchange. Initialize with `init`
/// and release with `deinit`. `connect`, `send` and `stream` clear it before
/// starting; its values survive failure and connection closure. Keep it alive
/// until the connection or response is released, or the stream is aborted or
/// finish fails.
/// Simultaneous exchanges must use separate diagnostics.
pub const Diagnostic = struct {
    /// The allocator for this diagnostic's owned copies.
    gpa: Allocator,
    /// Why the handshake failed, or the peer's client-certificate refusal.
    tls_error: ?anyerror = null,
    /// The proxy's refusal status: HTTP status or SOCKS reply code.
    proxy_status: ?u16 = null,
    /// The offered schemes that could not be answered, owned here.
    proxy_offered: ?[]const u8 = null,

    /// Use this allocator for the diagnostic's copies.
    pub fn init(gpa: Allocator) Diagnostic {
        return .{ .gpa = gpa };
    }

    /// Release the copies and clear every failure detail.
    pub fn deinit(d: *Diagnostic) void {
        d.clear();
    }

    fn clear(d: *Diagnostic) void {
        if (d.proxy_offered) |offered| d.gpa.free(offered);
        d.proxy_offered = null;
        d.proxy_status = null;
        d.tls_error = null;
    }

    fn setOffered(d: *Diagnostic, names: []const u8) Allocator.Error!void {
        const owned = try d.gpa.dupe(u8, names);
        if (d.proxy_offered) |previous| d.gpa.free(previous);
        d.proxy_offered = owned;
    }
};

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
    /// A SOCKS CONNECT tunnel, for HTTP and HTTPS alike.
    socks_version: ?socks.Version = null,
    /// The user and password the proxy is answered with, and which of its
    /// challenges may be answered.
    credential: ?Credential = null,
    /// The lines of a `CONNECT` after its `Host`, in order, as the caller's
    /// HTTP stack writes them. A line named `Proxy-Authorization` with an
    /// empty value stands for the answer to the proxy, written when there
    /// is one. `null` is curl's without a user agent: the answer, then
    /// `Proxy-Connection: Keep-Alive`.
    connect_headers: ?[]const http.Header = null,
    /// The certificate and key an `https` proxy that asks for one is
    /// answered with.
    client_auth: ?*const tls.ClientAuth = null,
    /// How an `https` proxy's certificate is checked: as the target's
    /// is, with `Client.verify` and the same authorities, as Go checks it
    /// for git-lfs; or always, against `Client.trustProxyFile`'s
    /// authorities or else the system's, as curl checks it for git.
    trust: enum { as_target, own } = .as_target,

    /// A proxy's credential.
    pub const Credential = struct {
        user: []const u8,
        password: []const u8,
        /// `any` sends nothing until the proxy asks, then answers the
        /// strongest scheme it offers, as curl's anyauth does; `basic`
        /// sends Basic from the first request, as curl does when Basic is
        /// all that is allowed; `digest` waits and answers Digest only.
        method: httpauth.Method = .any,
    };

    /// Parse HTTP(S) and SOCKS proxy URLs. Slices belong to `arena` or `raw`.
    /// Callers retain their HTTP default port; every SOCKS scheme uses 1080.
    pub fn parse(arena: Allocator, raw: []const u8, http_port: u16) (Allocator.Error || error{InvalidProxy})!Proxy {
        const text = if (std.mem.indexOf(u8, raw, "://") == null) try std.fmt.allocPrint(arena, "http://{s}", .{raw}) else raw;
        const uri = std.Uri.parse(text) catch return error.InvalidProxy;
        const version: ?socks.Version = if (std.ascii.eqlIgnoreCase(uri.scheme, "socks4")) .socks4 else if (std.ascii.eqlIgnoreCase(uri.scheme, "socks4a")) .socks4a else if (std.ascii.eqlIgnoreCase(uri.scheme, "socks5")) .socks5 else if (std.ascii.eqlIgnoreCase(uri.scheme, "socks5h")) .socks5h else null;
        const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
        if (version == null and !secure and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidProxy;
        const host = if (uri.host) |h| try h.toRawMaybeAlloc(arena) else return error.InvalidProxy;
        const unbracketed = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
        if (unbracketed.len == 0 or std.mem.indexOfAny(u8, unbracketed, "\x00\r\n") != null) return error.InvalidProxy;
        var proxy: Proxy = .{
            .host = unbracketed,
            .port = uri.port orelse if (version != null) 1080 else if (secure) 443 else http_port,
            .tls = secure,
            .socks_version = version,
        };
        if (uri.user != null or uri.password != null) proxy.credential = .{
            .user = if (uri.user) |u| try u.toRawMaybeAlloc(arena) else "",
            .password = if (uri.password) |p| try p.toRawMaybeAlloc(arena) else "",
        };
        return proxy;
    }
};

/// How the proxy is being answered, once it has asked.
const ProxyAnswer = union(enum) {
    basic: []u8,
    digest: httpauth.Digest,

    fn deinit(a: *ProxyAnswer, gpa: Allocator) void {
        switch (a.*) {
            .basic => |v| gpa.free(v),
            .digest => |*d| d.deinit(gpa),
        }
    }
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
    /// The authorities an `https` proxy is checked against when
    /// `Proxy.trust` is `own`, under `bundle_lock`: those of
    /// `trustProxyFile`, or else the system's, read at the first such
    /// proxy.
    proxy_bundle: Certificate.Bundle = .empty,
    proxy_trusted: bool = false,
    /// How long each step may take.
    timeouts: Timeouts = .{},
    /// How many connections may be kept for the requests to come.
    max_idle: usize = 1,
    /// The connections kept, the most recently used last.
    idle: std.ArrayList(*Connection) = .empty,
    /// Held for `idle`, `connections` and the proxy answer below, so
    /// several tasks can send at once.
    lock: Io.Mutex = .init,
    /// The answer to the proxy's challenge, once it has asked.
    proxy_answer: ?ProxyAnswer = null,
    /// The certificate and key a server that asks for one is answered
    /// with; without it, one that asks is sent none.
    client_auth: ?*const tls.ClientAuth = null,
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
        if (c.proxy_answer) |*a| a.deinit(c.gpa);
        for (c.idle.items) |conn| conn.close();
        c.idle.deinit(c.gpa);
        c.bundle.deinit(c.gpa);
        c.proxy_bundle.deinit(c.gpa);
        c.* = undefined;
    }

    fn clock(c: *Client) Io.Timestamp {
        return Io.Clock.real.now(c.io);
    }

    fn noteUnwatched(c: *Client) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.unwatched += 1;
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

    /// Check an `https` proxy whose `trust` is `own` against the
    /// certificates in the PEM file at `path`, as curl's
    /// `CURLOPT_PROXY_CAINFO` for git's `http.proxySSLCAInfo`.
    pub fn trustProxyFile(c: *Client, path: []const u8) (Error || error{CertificateFileUnreadable})!void {
        c.bundle_lock.lockUncancelable(c.io);
        defer c.bundle_lock.unlock(c.io);
        c.proxy_bundle.addCertsFromFilePath(c.gpa, c.io, c.clock(), Io.Dir.cwd(), path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.CertificateFileUnreadable,
        };
        c.proxy_trusted = true;
    }

    fn ensureProxyTrusted(c: *Client) Error!void {
        c.bundle_lock.lockUncancelable(c.io);
        defer c.bundle_lock.unlock(c.io);
        if (c.proxy_trusted) return;
        c.proxy_bundle.rescan(c.gpa, c.io, c.clock()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.CertificateBundleUnreadable,
        };
        c.proxy_trusted = true;
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

    /// The `Proxy-Authorization` value for a request `method` to `uri` —
    /// the request target, `host:port` for a `CONNECT` — or `null` when
    /// the proxy is not answered yet. Into `gpa`.
    fn proxyAuthorization(c: *Client, method: []const u8, uri: []const u8) Allocator.Error!?[]u8 {
        const credential = (c.proxy orelse return null).credential orelse return null;
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.proxy_answer == null and credential.method == .basic) {
            c.proxy_answer = .{ .basic = try httpauth.basic(c.gpa, credential.user, credential.password) };
        }
        const answer = &(c.proxy_answer orelse return null);
        return switch (answer.*) {
            .basic => |v| try c.gpa.dupe(u8, v),
            .digest => |*d| try d.answer(c.gpa, credential.user, credential.password, method, uri),
        };
    }

    /// Take the challenges of a 407: whether the request is to be made
    /// again with an answer. `false` when there is no credential to answer
    /// with, or when the answer given was refused — a Digest nonce gone
    /// stale is answered again.
    fn proxyChallenged(c: *Client, head: *const Head, diagnostic: ?*Diagnostic) Error!bool {
        const credential = (c.proxy orelse return false).credential orelse return false;
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var challenges: std.ArrayList(httpauth.Challenge) = .empty;
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "proxy-authenticate")) continue;
            const list = httpauth.parse(arena, h.value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedChallenge => continue,
            };
            try challenges.appendSlice(arena, list);
        }
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.proxy_answer) |*previous| {
            // Answered and refused, unless the nonce only went stale.
            if (previous.* != .digest) return false;
            const fresh = for (challenges.items) |ch| {
                if (ch.scheme != .digest) continue;
                const stale = ch.param("stale") orelse continue;
                if (std.ascii.eqlIgnoreCase(stale, "true") and httpauth.Digest.speaks(ch)) break ch;
            } else return false;
            const next: httpauth.Digest = try .init(c.gpa, fresh, try c.cnonce(arena));
            previous.deinit(c.gpa);
            c.proxy_answer = .{ .digest = next };
            return true;
        }
        switch (try httpauth.pick(arena, challenges.items, credential.method)) {
            .digest => |ch| c.proxy_answer = .{ .digest = try .init(c.gpa, ch, try c.cnonce(arena)) },
            .basic => c.proxy_answer = .{ .basic = try httpauth.basic(c.gpa, credential.user, credential.password) },
            .unsupported => |names| {
                if (diagnostic) |d| try d.setOffered(names);
                return error.ProxyAuthMethodUnsupported;
            },
        }
        return true;
    }

    /// A client nonce for Digest as curl makes one: thirty-two random hex
    /// digits, in base64.
    fn cnonce(c: *Client, arena: Allocator) Allocator.Error![]u8 {
        var raw: [16]u8 = undefined;
        c.io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(hex.len));
        _ = std.base64.standard.Encoder.encode(out, &hex);
        return out;
    }

    /// A connection to `target`: a kept one when one goes there, a new one
    /// otherwise. `diagnostic` belongs to this exchange, or is `null`.
    pub fn connect(c: *Client, target: Target, diagnostic: ?*Diagnostic) Error!*Connection {
        if (diagnostic) |d| d.clear();
        return (try c.connectNoting(target, diagnostic)).conn;
    }

    fn connectNoting(c: *Client, target: Target, diagnostic: ?*Diagnostic) Error!struct { conn: *Connection, reused: bool } {
        if (c.takeIdle(target)) |conn| {
            conn.diagnostic = diagnostic;
            return .{ .conn = conn, .reused = true };
        }
        return .{ .conn = try Connection.open(c, target, diagnostic), .reused = false };
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
        conn.diagnostic = null;
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
    /// caller's to read and `deinit`. `diagnostic` belongs to this exchange,
    /// or is `null`.
    pub fn send(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, body: ?[]const u8, diagnostic: ?*Diagnostic) Error!Response {
        if (diagnostic) |d| d.clear();
        var response = try c.sendKept(method, target, path, headers, body, diagnostic);
        errdefer response.deinit();
        // A proxy that asks, for a request it is handed whole: answered,
        // and the request made again, as curl makes it again.
        if (response.head.status == .proxy_auth_required and c.proxy != null and !target.tls) {
            if (diagnostic) |d| d.proxy_status = 407;
            if (try c.proxyChallenged(&response.head, diagnostic)) {
                _ = response.reader().discardRemaining() catch {};
                response.deinit();
                response = try c.sendKept(method, target, path, headers, body, diagnostic);
            }
        }
        return response;
    }

    fn sendKept(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, body: ?[]const u8, diagnostic: ?*Diagnostic) Error!Response {
        const first = try c.connectNoting(target, diagnostic);
        return c.sendOn(first.conn, method, path, headers, body) catch |err| switch (err) {
            // A kept connection the server closed while it waited is
            // noticed only now; the request goes again on a new one, as
            // curl sends it again.
            error.ConnectionFailed => if (first.reused) c.sendOn(try Connection.open(c, target, diagnostic), method, path, headers, body) else err,
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
    /// Write through `Streaming.writer`, then call `Streaming.finish` for the
    /// response. Finish consumes the stream on success and failure; abort it
    /// only when giving up before finish.
    /// `diagnostic` belongs to this exchange, or is `null`.
    pub fn stream(c: *Client, method: http.Method, target: Target, path: []const u8, headers: []const http.Header, length: ?u64, buffer: []u8, diagnostic: ?*Diagnostic) Error!Streaming {
        const conn = try c.connect(target, diagnostic);
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

/// A request whose body is being sent, in chunks or with a known length.
/// Call `finish` or `abort` once; either consumes the stream.
pub const Streaming = struct {
    conn: *Connection,
    method: http.Method,
    body: http.BodyWriter,

    /// Where the body is written.
    pub fn writer(s: *Streaming) *Io.Writer {
        return &s.body.writer;
    }

    /// End the body and read the head of the response. Consumes the stream
    /// on every outcome: the response owns the connection on success, and
    /// failure closes it. Do not use or abort the stream after calling this.
    /// A body shorter than its declared length is `BodyIncomplete`.
    pub fn finish(s: *Streaming) Error!Response {
        const conn = s.conn;
        defer s.* = undefined;
        errdefer conn.close();
        s.body.writer.flush() catch return conn.writeFailed();
        switch (s.body.state) {
            .content_length => |left| if (left != 0) return error.BodyIncomplete,
            else => {},
        }
        s.body.endUnflushed() catch return conn.writeFailed();
        conn.flush() catch return conn.writeFailed();
        return conn.receive(s.method);
    }

    /// Give up before finish; consumes the stream and closes its connection.
    pub fn abort(s: *Streaming) void {
        s.conn.close();
        s.* = undefined;
    }
};

/// A response's head, read as HTTP/1.1 says: the status line, and the
/// headers that decide how the body is read. relic reads it itself, as it
/// makes every connection itself: nothing here reaches the standard
/// library's HTTP client.
pub const Head = struct {
    /// The head's bytes, which every slice here points into.
    bytes: []const u8,
    version: http.Version,
    status: http.Status,
    reason: []const u8,
    location: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// Whether the connection may carry another request after this one.
    keep_alive: bool,
    content_length: ?u64 = null,
    transfer_encoding: http.TransferEncoding = .none,
    content_encoding: http.ContentEncoding = .identity,

    /// A head that is not one HTTP/1.x allows.
    pub const ParseError = error{MalformedHead};

    /// Read `bytes`, a head up to and including its blank line.
    pub fn parse(bytes: []const u8) ParseError!Head {
        var lines = std.mem.splitSequence(u8, bytes, "\r\n");
        const first = lines.first();
        if (first.len < 12 or first[8] != ' ') return error.MalformedHead;
        const version: http.Version = if (std.mem.eql(u8, first[0..8], "HTTP/1.1"))
            .@"HTTP/1.1"
        else if (std.mem.eql(u8, first[0..8], "HTTP/1.0"))
            .@"HTTP/1.0"
        else
            return error.MalformedHead;
        for (first[9..12]) |c| if (!std.ascii.isDigit(c)) return error.MalformedHead;
        var head: Head = .{
            .bytes = bytes,
            .version = version,
            .status = @enumFromInt(std.fmt.parseUnsigned(u10, first[9..12], 10) catch return error.MalformedHead),
            .reason = std.mem.trimStart(u8, first[12..], " "),
            .keep_alive = version == .@"HTTP/1.1",
        };
        while (lines.next()) |line| {
            if (line.len == 0) return head;
            if (line[0] == ' ' or line[0] == '\t') return error.MalformedHead;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHead;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (name.len == 0) return error.MalformedHead;
            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                head.keep_alive = !std.ascii.eqlIgnoreCase(value, "close");
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                head.content_type = value;
            } else if (std.ascii.eqlIgnoreCase(name, "location")) {
                head.location = value;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                // `chunked` last, and at most one coding before it.
                var codings = std.mem.splitBackwardsScalar(u8, value, ',');
                const last = std.mem.trim(u8, codings.first(), " ");
                var before: ?[]const u8 = last;
                if (std.ascii.eqlIgnoreCase(last, "chunked")) {
                    if (head.transfer_encoding != .none) return error.MalformedHead;
                    head.transfer_encoding = .chunked;
                    before = codings.next();
                }
                if (before) |coding| {
                    if (head.content_encoding != .identity) return error.MalformedHead;
                    head.content_encoding = http.ContentEncoding.fromString(std.mem.trim(u8, coding, " ")) orelse return error.MalformedHead;
                }
                if (codings.next() != null) return error.MalformedHead;
            } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                const n = std.fmt.parseUnsigned(u64, value, 10) catch return error.MalformedHead;
                if (head.content_length) |was| if (was != n) return error.MalformedHead;
                head.content_length = n;
            } else if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
                if (head.content_encoding != .identity) return error.MalformedHead;
                head.content_encoding = http.ContentEncoding.fromString(value) orelse return error.MalformedHead;
            }
        }
        return error.MalformedHead;
    }

    /// Every header, in order.
    pub fn iterateHeaders(h: *const Head) http.HeaderIterator {
        return .init(h.bytes);
    }
};

/// A response: its head, owned, and its body, read through `reader`.
pub const Response = struct {
    conn: ?*Connection,
    /// The head's bytes, which `head` points into.
    head_bytes: []u8,
    head: Head,
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
    /// Whether the server asked for a client certificate.
    certificate_requested: bool = false,
};

/// A TLS alert's description as an error: `TlsAlertBadCertificate` and
/// the like.
fn alertError(description: std.crypto.tls.Alert.Description) anyerror {
    description.toError() catch |err| return err;
    return error.TlsAlert;
}

/// Whether a TLS alert is a server's refusal of a client certificate — or
/// of none — once it has asked for one. OpenSSL answers a missing one in
/// TLS 1.2 with `handshake_failure`.
fn refusesCertificate(description: std.crypto.tls.Alert.Description) bool {
    return switch (description) {
        .bad_certificate,
        .unsupported_certificate,
        .certificate_revoked,
        .certificate_expired,
        .certificate_unknown,
        .unknown_ca,
        .access_denied,
        .certificate_required,
        .handshake_failure,
        .decrypt_error,
        => true,
        else => false,
    };
}

/// One connection: TCP, and the layers on it.
pub const Connection = struct {
    client: *Client,
    /// Borrowed only while this connection belongs to its caller.
    diagnostic: ?*Diagnostic = null,
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

    fn open(c: *Client, target: Target, diagnostic: ?*Diagnostic) Error!*Connection {
        // A proxy that asks for an answer to a tunnel is asked again on a
        // new connection, as curl asks, with the answer; and once more for
        // a Digest nonce gone stale.
        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            var proxy_retry = false;
            return openOnce(c, target, &proxy_retry, diagnostic) catch |err| switch (err) {
                error.ProxyAuthenticationRequired => {
                    if (attempts < 2 and proxy_retry) continue;
                    return err;
                },
                else => return err,
            };
        }
    }

    fn openOnce(c: *Client, target: Target, proxy_retry: *bool, diagnostic: ?*Diagnostic) Error!*Connection {
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
        const connect_started = awakeNow(io);
        var net_stream = try dial(c, first_host, first_port);
        errdefer net_stream.close(io);
        {
            c.lock.lockUncancelable(io);
            defer c.lock.unlock(io);
            c.connections += 1;
        }

        conn.* = .{
            .client = c,
            .diagnostic = diagnostic,
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
                c.noteUnwatched();
            }
        }
        errdefer conn.stopWatching();

        if (c.proxy) |p| {
            if (p.socks_version) |version| {
                try conn.socksTunnel(p, version, target, connect_started);
            } else {
                if (p.tls) try conn.startTls(0, p.host);
                if (target.tls) {
                    try conn.tunnel(p, target, proxy_retry);
                } else conn.absolute_form = true;
            }
        }
        if (target.tls) try conn.startTls(1, target.host);
        return conn;
    }

    /// Make the TCP connection, within `Timeouts.connect` when there is
    /// one: the connect runs as its own task, raced against a sleep.
    fn dial(c: *Client, host: []const u8, port: u16) Error!Io.net.Stream {
        const io = c.io;
        const limit = c.timeouts.connect orelse return plainDial(io, host, port);
        const Race = union(enum) {
            connected: Error!Io.net.Stream,
            expired: Io.Cancelable!void,
        };
        var buffer: [2]Race = undefined;
        var race: Io.Select(Race) = .init(io, &buffer);
        race.concurrent(.connected, plainDial, .{ io, host, port }) catch {
            c.noteUnwatched();
            return plainDial(io, host, port);
        };
        race.concurrent(.expired, Io.sleep, .{ io, limit, .awake }) catch {
            while (race.cancel()) |late| switch (late) {
                .connected => |result| if (result) |stream| return stream else |_| {},
                .expired => {},
            };
            c.noteUnwatched();
            return plainDial(io, host, port);
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

    fn plainDial(io: Io, host: []const u8, port: u16) Error!Io.net.Stream {
        if (Io.net.IpAddress.parse(host, port)) |address| {
            return address.connect(io, .{ .mode = .stream }) catch |err| return switch (err) {
                error.Canceled => error.Canceled,
                else => error.ConnectionFailed,
            };
        } else |_| {}
        const host_name = Io.net.HostName.init(host) catch return error.ConnectionFailed;
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
        const sr: *Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", r)); // safe: this function is installed only on a Io.net.Stream.Reader's interface
        return @alignCast(@fieldParentPtr("stream_reader", sr)); // safe: the metered vtables are installed only on a Connection's own streams
    }

    fn ofWriter(w: *Io.Writer) *Connection {
        const sw: *Io.net.Stream.Writer = @alignCast(@fieldParentPtr("interface", w)); // safe: this function is installed only on a Io.net.Stream.Writer's interface
        return @alignCast(@fieldParentPtr("stream_writer", sw)); // safe: the metered vtables are installed only on a Connection's own streams
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
            // Observe the current operation after sampling the clock.
            // An operation begun after that sample is not expired yet;
            // its newer start must not underflow elapsed time.
            const now = awakeNow(io);
            const since = conn.busy_since.load(.acquire);
            const until = conn.handshake_until.load(.acquire);
            var expired = false;
            if (t.activity) |limit| {
                if (since != 0 and now >= since and now - since >= limit.nanoseconds) expired = true;
            }
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
        // A server that refused the client's certificate after a TLS 1.3
        // handshake the client thinks is done has sent its alert and
        // closed: the write that failed is the request, and the alert is
        // there to be read.
        for (conn.layers) |slot| if (slot) |layer| {
            if (!layer.certificate_requested) continue;
            _ = layer.client.reader.peekByte() catch {};
            if (layer.client.read_err != null) return conn.readFailed();
        };
        if (conn.missingCertificateReset()) return error.ClientCertificateRejected;
        return error.ConnectionFailed;
    }

    fn missingCertificateReset(conn: *Connection) bool {
        if (builtin.os.tag != .windows or conn.client.client_auth != null) return false;
        // Windows can report the server's TLS certificate refusal as a
        // socket reset before the TLS alert reaches the reader.
        for (conn.layers) |slot| if (slot) |layer| {
            if (layer.certificate_requested) return true;
        };
        return false;
    }

    fn readFailed(conn: *Connection) Error {
        if (conn.timed_out.load(.acquire)) return error.TimedOut;
        if (conn.stream_reader.err) |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        for (conn.layers) |slot| if (slot) |layer| {
            const err = layer.client.read_err orelse continue;
            // TLS 1.3 finishes the handshake before the server has read
            // the client's certificate: its refusal is the first thing
            // read.
            if (err == error.TlsAlert and layer.certificate_requested) {
                if (layer.client.alert) |alert| if (refusesCertificate(alert.description)) {
                    if (conn.diagnostic) |d| d.tls_error = alertError(alert.description);
                    return error.ClientCertificateRejected;
                };
            }
            return error.TlsFailed;
        };
        if (conn.missingCertificateReset()) return error.ClientCertificateRejected;
        return error.ConnectionFailed;
    }

    fn startTls(conn: *Connection, slot: usize, host: []const u8) Error!void {
        const c = conn.client;
        const gpa = c.gpa;
        // An `https` proxy of its own trust is always checked, as curl
        // checks it whatever `http.sslVerify` says.
        const own = slot == 0 and c.proxy.?.trust == .own;
        const verify = own or c.verify;
        if (own) try c.ensureProxyTrusted() else if (verify) try c.ensureTrusted();
        const layer = try gpa.create(TlsLayer);
        errdefer gpa.destroy(layer);
        layer.* = .{ .client = undefined, .read_buffer = undefined, .write_buffer = undefined };
        layer.read_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(layer.read_buffer);
        layer.write_buffer = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(layer.write_buffer);
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
        var alert_storage: std.crypto.tls.Alert = .{ .level = .fatal, .description = .close_notify };
        if (c.timeouts.handshake) |limit| {
            conn.handshake_until.store(awakeNow(c.io) + @as(u64, @intCast(limit.nanoseconds)), .release);
        }
        defer conn.handshake_until.store(0, .release);
        layer.client = tls.Client.init(conn.readerBelow(slot), conn.writerBelow(slot), .{
            .host = if (verify) .{ .explicit = host } else .no_verification,
            .ca = if (verify) .{ .bundle = .{
                .gpa = gpa,
                .io = c.io,
                .lock = &c.bundle_lock,
                .bundle = if (own) &c.proxy_bundle else &c.bundle,
            } } else .no_verification,
            .read_buffer = layer.read_buffer,
            .write_buffer = layer.write_buffer,
            .entropy = &entropy,
            .realtime_now = c.clock(),
            // HTTP says where a body ends, so an end without close_notify
            // is not a truncation it cannot see.
            .allow_truncation_attacks = true,
            .client_auth = if (slot == 0) c.proxy.?.client_auth else c.client_auth,
            .certificate_requested = &layer.certificate_requested,
            .alert = &alert_storage,
        }) catch |err| {
            if (conn.timed_out.load(.acquire)) return error.TimedOut;
            const named: anyerror = if (err == error.TlsAlert) alertError(alert_storage.description) else err;
            if (conn.diagnostic) |d| d.tls_error = named;
            if (err == error.TlsAlert and layer.certificate_requested and refusesCertificate(alert_storage.description)) {
                return error.ClientCertificateRejected;
            }
            return switch (err) {
                error.Canceled => error.Canceled,
                error.OutOfMemory => error.OutOfMemory,
                error.ClientCertificateSchemeUnsupported => error.ClientCertificateSchemeUnsupported,
                else => error.TlsFailed,
            };
        };
        conn.layers[slot] = layer;
    }

    /// Curl counts SOCKS negotiation, including local DNS, as connecting.
    /// Race the whole negotiation so a lookup is canceled on timeout too.
    fn socksTunnel(conn: *Connection, proxy: Proxy, version: socks.Version, target: Target, started: u64) Error!void {
        const c = conn.client;
        var limit = c.timeouts.handshake;
        if (c.timeouts.connect) |connect_limit| {
            const remaining = connect_limit.nanoseconds - @as(i96, awakeNow(c.io) - started);
            if (remaining <= 0) return error.TimedOut;
            if (limit == null or remaining < limit.?.nanoseconds) limit = .{ .nanoseconds = remaining };
        }
        const timeout = limit orelse return conn.socksHandshake(proxy, version, target);
        const Race = union(enum) { negotiated: Error!void, expired: Io.Cancelable!void };
        var buffer: [2]Race = undefined;
        var race: Io.Select(Race) = .init(c.io, &buffer);
        defer while (race.cancel()) |_| {};
        race.concurrent(.negotiated, socksHandshake, .{ conn, proxy, version, target }) catch {
            c.noteUnwatched();
            return conn.socksHandshake(proxy, version, target);
        };
        race.concurrent(.expired, Io.sleep, .{ c.io, timeout, .awake }) catch {
            while (race.cancel()) |late| switch (late) {
                .negotiated => |result| return result,
                .expired => {},
            };
            c.noteUnwatched();
            return conn.socksHandshake(proxy, version, target);
        };
        return switch (try race.await()) {
            .negotiated => |result| result,
            .expired => |result| if (result) |_| error.TimedOut else |err| err,
        };
    }

    fn socksHandshake(conn: *Connection, proxy: Proxy, version: socks.Version, target: Target) Error!void {
        const credential: ?socks.Credential = if (proxy.credential) |c| .{ .user = c.user, .password = c.password } else null;
        const host = if (target.host.len >= 2 and target.host[0] == '[' and target.host[target.host.len - 1] == ']') target.host[1 .. target.host.len - 1] else target.host;
        if ((version == .socks4 or version == .socks4a) and std.mem.indexOfScalar(u8, host, ':') != null) return error.ProxyAddressUnsupported;
        if (version == .socks5 or version == .socks5h) socks.authenticate(conn.reader(), conn.writer(), credential) catch |err| return conn.socksFailed(err);
        const literal = Io.net.IpAddress.parse(host, target.port) catch null;
        const address: ?Io.net.IpAddress = if (version == .socks4a) null else if (literal) |a| a else if (version == .socks5h) null else try resolveSocks(conn.client.io, host, target.port, version == .socks4);
        socks.request(conn.writer(), version, host, target.port, address, credential) catch |err| return conn.socksFailed(err);
        var status: u16 = 0;
        socks.reply(conn.reader(), version, &status) catch |err| {
            if (conn.diagnostic) |d| d.proxy_status = status;
            return conn.socksFailed(err);
        };
    }

    fn resolveSocks(io: Io, host: []const u8, port: u16, ipv4: bool) Error!Io.net.IpAddress {
        const name = Io.net.HostName.init(host) catch return error.ProxyHostUnreachable;
        var buffer: [32]Io.net.HostName.LookupResult = undefined;
        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buffer);
        var future = io.async(Io.net.HostName.lookup, .{ name, io, &queue, .{ .port = port, .family = if (ipv4) .ip4 else null } });
        defer future.cancel(io) catch {};
        var address: ?Io.net.IpAddress = null;
        while (true) {
            const result = queue.getOne(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => break,
            };
            switch (result) {
                .address => |a| {
                    // Zig's libc lookup may ignore LookupOptions.family.
                    // Enforce SOCKS4's IPv4 requirement here, and keep the
                    // first address in curl's preferred family for SOCKS5.
                    if (ipv4 and a != .ip4) continue;
                    if (address == null or (!ipv4 and address.? == .ip4 and a == .ip6)) address = a;
                },
                .canonical_name => {},
            }
        }
        future.await(io) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.ProxyHostUnreachable,
        };
        return address orelse error.ProxyHostUnreachable;
    }

    fn socksFailed(conn: *Connection, err: socks.WireError) Error {
        return switch (err) {
            error.ReadFailed, error.EndOfStream => conn.readFailed(),
            error.WriteFailed => conn.writeFailed(),
            else => |named| named,
        };
    }

    /// Ask the proxy for a tunnel to `target` with `CONNECT`, as curl asks.
    fn tunnel(conn: *Connection, proxy: Proxy, target: Target, proxy_retry: *bool) Error!void {
        const c = conn.client;
        const w = conn.writer();
        var authority_buf: [300]u8 = undefined;
        var host_buffer: [260]u8 = undefined;
        const host = try authorityHost(target.host, &host_buffer);
        const authority = std.fmt.bufPrint(&authority_buf, "{s}:{d}", .{ host, target.port }) catch return error.HttpProtocolError;
        const answer = try c.proxyAuthorization("CONNECT", authority);
        defer if (answer) |a| c.gpa.free(a);
        w.print("CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n", .{ authority, authority }) catch return conn.writeFailed();
        const default_lines = [_]http.Header{
            .{ .name = "Proxy-Authorization", .value = "" },
            .{ .name = "Proxy-Connection", .value = "Keep-Alive" },
        };
        for (proxy.connect_headers orelse &default_lines) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "proxy-authorization") and h.value.len == 0) {
                if (answer) |a| w.print("Proxy-Authorization: {s}\r\n", .{a}) catch return conn.writeFailed();
            } else w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return conn.writeFailed();
        }
        w.writeAll("\r\n") catch return conn.writeFailed();
        conn.flush() catch return conn.writeFailed();
        var r: http.Reader = .{ .in = conn.reader(), .interface = undefined, .state = .ready, .max_head_len = 16 * 1024 };
        const bytes = r.receiveHead() catch |err| return switch (err) {
            error.ReadFailed => conn.readFailed(),
            else => error.HttpProtocolError,
        };
        const head = Head.parse(bytes) catch return error.HttpProtocolError;
        const status = @intFromEnum(head.status);
        if (status / 100 == 2) return;
        if (conn.diagnostic) |d| d.proxy_status = status;
        if (status != 407) return error.ProxyRefused;
        if (try c.proxyChallenged(&head, conn.diagnostic)) {
            proxy_retry.* = true;
        }
        return error.ProxyAuthenticationRequired;
    }

    /// URL authorities bracket IPv6; the SOCKS wire uses its address bytes.
    fn authorityHost(host: []const u8, buffer: []u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, host, ':') != null and host[0] != '[') {
            return std.fmt.bufPrint(buffer, "[{s}]", .{host}) catch error.HttpProtocolError;
        }
        return host;
    }

    const BodyKind = union(enum) { none, content_length: usize, chunked };

    fn writeHead(conn: *Connection, method: http.Method, path: []const u8, headers: []const http.Header, body: BodyKind) Error!void {
        const w = conn.writer();
        const t = conn.target;
        var host_buffer: [260]u8 = undefined;
        const host = try authorityHost(t.host, &host_buffer);
        // A request a proxy is handed whole is answered for with its path
        // as the Digest target, as curl answers.
        const proxy_answer: ?[]u8 = if (conn.absolute_form)
            try conn.client.proxyAuthorization(@tagName(method), path)
        else
            null;
        defer if (proxy_answer) |a| conn.client.gpa.free(a);
        (write: {
            w.print("{s} ", .{@tagName(method)}) catch |e| break :write e;
            if (conn.absolute_form) {
                w.print("http://{s}", .{host}) catch |e| break :write e;
                if (t.port != 80) w.print(":{d}", .{t.port}) catch |e| break :write e;
            }
            w.print("{s} HTTP/1.1\r\nHost: {s}", .{ path, host }) catch |e| break :write e;
            if (t.port != (if (t.tls) @as(u16, 443) else 80)) w.print(":{d}", .{t.port}) catch |e| break :write e;
            w.writeAll("\r\n") catch |e| break :write e;
            if (proxy_answer) |a| w.print("Proxy-Authorization: {s}\r\n", .{a}) catch |e| break :write e;
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
        const head = Head.parse(head_bytes) catch return error.HttpProtocolError;
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
    defer client.deinit();
    client.proxy = .{ .host = "proxy.example.com", .port = 3128, .credential = .{ .user = "a", .password = "b", .method = .basic } };
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
    // A SOCKS5 tunnel can reach an IPv6 literal. Its HTTP authority still
    // uses URL brackets, even though the SOCKS address itself is binary.
    conn.target = .{ .tls = false, .host = "::1", .port = 80 };
    conn.absolute_form = false;
    conn.stream_writer.interface = .fixed(&out);
    try conn.writeHead(.GET, "/", &.{}, .none);
    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: [::1]\r\n\r\n", conn.stream_writer.interface.buffered());
    conn.target.port = 8080;
    conn.absolute_form = true;
    conn.stream_writer.interface = .fixed(&out);
    try conn.writeHead(.GET, "/", &.{}, .none);
    try std.testing.expectEqualStrings("GET http://[::1]:8080/ HTTP/1.1\r\nHost: [::1]:8080\r\nProxy-Authorization: Basic YTpi\r\n\r\n", conn.stream_writer.interface.buffered());
}

/// Test-only: a server on 127.0.0.1 that answers every request on a
/// connection with `ok`, or, `silent`, reads and never answers.
const TestServer = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    silent: bool,
    answer: []const u8,
    answerFor: ?*const fn ([]const u8) []const u8 = null,
    task: Io.Future(void) = undefined,
    group: Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(gpa: Allocator, io: Io, silent: bool) !*TestServer {
        return startAnswer(gpa, io, silent, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    }

    fn startAnswer(gpa: Allocator, io: Io, silent: bool, answer: []const u8) !*TestServer {
        return startRouted(gpa, io, silent, answer, null);
    }

    fn startRouted(gpa: Allocator, io: Io, silent: bool, answer: []const u8, answerFor: ?*const fn ([]const u8) []const u8) !*TestServer {
        const s = try gpa.create(TestServer);
        errdefer gpa.destroy(s);
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        s.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort(), .silent = silent, .answer = answer, .answerFor = answerFor };
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
            const answer = if (s.answerFor) |choose| choose(r.interface.buffered()[0..end]) else s.answer;
            r.interface.toss(end);
            if (s.silent) {
                while (true) r.interface.fillMore() catch return;
            }
            w.interface.writeAll(answer) catch return;
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
    try std.testing.expectError(error.TimedOut, handshaking.send(.GET, .{ .tls = true, .host = "127.0.0.1", .port = server.port }, "/", &.{}, null, null));

    var waiting: Client = .init(gpa, io);
    defer waiting.deinit();
    waiting.timeouts = .{ .activity = limit };
    try std.testing.expectError(error.TimedOut, waiting.send(.GET, .{ .tls = false, .host = "127.0.0.1", .port = server.port }, "/", &.{}, null, null));
    try std.testing.expectEqual(@as(usize, 0), waiting.idle.items.len);
    try std.testing.expectEqual(@as(u32, 0), waiting.unwatched);
}

test "a proxy challenge that cannot be answered releases its response" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestServer.startAnswer(gpa, io, false, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n");
    defer server.stop(gpa);
    var client: Client = .init(gpa, io);
    defer client.deinit();
    client.proxy = .{ .host = "127.0.0.1", .port = server.port, .credential = .{ .user = "a", .password = "b" } };
    var diagnostic: Diagnostic = .init(gpa);
    defer diagnostic.deinit();
    try std.testing.expectError(error.ProxyAuthMethodUnsupported, client.send(.GET, .{ .tls = false, .host = "git.example.com", .port = 80 }, "/", &.{}, null, &diagnostic));
    try std.testing.expectEqualStrings("Negotiate", diagnostic.proxy_offered.?);
    // std.testing.allocator must have no retained response or connection.
}

test "proxy challenges retain offered schemes when replacement allocation fails" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = .init(gpa, std.testing.io);
            defer client.deinit();
            client.proxy = .{ .host = "proxy.example.com", .port = 80, .credential = .{ .user = "a", .password = "b" } };
            var diagnostic: Diagnostic = .init(gpa);
            defer diagnostic.deinit();
            diagnostic.proxy_offered = try gpa.dupe(u8, "previous");
            const head = try Head.parse("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n");
            _ = client.proxyChallenged(&head, &diagnostic) catch |err| switch (err) {
                error.OutOfMemory => {
                    try std.testing.expectEqualStrings("previous", diagnostic.proxy_offered.?);
                    return err;
                },
                error.ProxyAuthMethodUnsupported => {
                    try std.testing.expectEqualStrings("Negotiate", diagnostic.proxy_offered.?);
                    return;
                },
                else => return err,
            };
            return error.TestUnexpectedResult;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
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
        fn run(c: *Client, t: Target, worker: usize) Error!void {
            for (0..5) |request| {
                var response = c.send(.GET, t, "/", &.{}, null, null) catch |err| {
                    std.debug.print("worker {d}, request {d}: send failed: {s}\n", .{ worker, request, @errorName(err) });
                    return err;
                };
                defer response.deinit();
                var body: [8]u8 = undefined;
                const n = response.reader().readSliceShort(&body) catch |err| {
                    const failure = response.failure();
                    std.debug.print("worker {d}, request {d}: body failed: {s} ({s})\n", .{ worker, request, @errorName(failure), @errorName(err) });
                    return failure;
                };
                if (!std.mem.eql(u8, body[0..n], "ok")) {
                    std.debug.print("worker {d}, request {d}: expected ok, got {any} (status {d})\n", .{ worker, request, body[0..n], @intFromEnum(response.head.status) });
                    return error.HttpProtocolError;
                }
            }
        }
    };
    var group: Io.Group = .init;
    var results: [4]Error!void = undefined;
    const Wrap = struct {
        fn run(c: *Client, t: Target, worker: usize, out: *Error!void) void {
            out.* = Task.run(c, t, worker);
        }
    };
    defer group.cancel(io);
    for (&results, 0..) |*out, worker| group.concurrent(io, Wrap.run, .{ &client, target, worker, out }) catch return error.SkipZigTest;
    try group.await(io);
    for (results) |result| try result;
    // Twenty requests, no more connections than tasks.
    if (client.connections > 4) std.debug.print("twenty requests opened {d} connections for four workers\n", .{client.connections});
    try std.testing.expect(client.connections <= 4);
    try std.testing.expect(client.idle.items.len <= 4);
}

fn checkConcurrentTimeoutFallbacks(notify: bool, readiness_limit: Io.Duration) !void {
    const Controlled = struct {
        waiting: std.atomic.Value(usize) = .init(0),
        ready: Io.Event = .unset,
        waiting_on: *const anyopaque = undefined,
        notify: bool,
        threadlocal var state: ?*@This() = null;
        threadlocal var counted: bool = false;

        fn wait(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
            if (state) |control| {
                if (@as(*const anyopaque, ptr) == control.waiting_on and !counted) {
                    counted = true;
                    if (control.waiting.fetchAdd(1, .acq_rel) == 1 and control.notify) control.ready.set(std.testing.io);
                }
            }
            std.testing.io.vtable.futexWaitUncancelable(std.testing.io.userdata, ptr, expected);
        }

        fn connect(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
            return error.ConnectionRefused;
        }

        fn run(c: *Client, control: *@This(), result: *Error!Io.net.Stream) void {
            state = control;
            counted = false;
            defer state = null;
            var unrelated: u32 = 0;
            c.io.futexWaitUncancelable(u32, &unrelated, 1);
            if (counted) {
                result.* = error.HttpProtocolError;
                return;
            }
            result.* = Connection.dial(c, "127.0.0.1", 1);
        }
    };
    const io = std.testing.io;
    var state: Controlled = .{ .notify = notify };
    var vtable = io.vtable.*;
    vtable.concurrent = Io.failing.vtable.concurrent;
    vtable.groupConcurrent = Io.failing.vtable.groupConcurrent;
    vtable.futexWaitUncancelable = Controlled.wait;
    vtable.netConnectIp = Controlled.connect;
    const guarded: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var client: Client = .init(std.testing.allocator, guarded);
    defer client.deinit();
    state.waiting_on = &client.lock.state;
    client.timeouts.connect = .fromSeconds(10);
    // The hostname connector may wait on its own queues from threads
    // that have not entered this fixture's worker.
    var unrelated: u32 = 0;
    guarded.futexWaitUncancelable(u32, &unrelated, 1);
    try std.testing.expectEqual(@as(usize, 0), state.waiting.load(.acquire));
    var results: [2]Error!Io.net.Stream = undefined;
    var group: Io.Group = .init;
    defer group.cancel(io);
    // Both fallbacks arrive at the locked counter before either may
    // change it. Computing an increment outside the lock loses one.
    client.lock.lockUncancelable(guarded);
    {
        defer client.lock.unlock(guarded);
        for (&results) |*result| try group.concurrent(io, Controlled.run, .{ &client, &state, result });
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = readiness_limit, .clock = .awake });
        // A missed arrival must release the mutex before joining workers.
        // Spurious wakes share this deadline rather than starting it again.
        while (!state.ready.isSet()) {
            if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
            state.ready.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => return err,
            };
        }
    }
    try group.await(io);
    for (results) |result| try std.testing.expectError(error.ConnectionFailed, result);
    try std.testing.expectEqual(@as(u32, 2), client.unwatched);
}

test "concurrent timeout fallbacks count each unwatched connection" {
    try checkConcurrentTimeoutFallbacks(true, .fromSeconds(10));
}

test "the HTTP counter fixture gives up when worker readiness is not signaled" {
    try std.testing.expectError(error.Timeout, checkConcurrentTimeoutFallbacks(false, .fromMilliseconds(10)));
}

fn checkWatchdogActivity(initial_start: u64, sampled: u64, fresh: u64) !void {
    const Controlled = struct {
        conn: *Connection,
        sleeps: usize = 0,
        shutdowns: usize = 0,
        fresh_expired: bool = false,
        sampled: u64,
        fresh: u64,

        fn sleep(context: ?*anyopaque, _: Io.Timeout) Io.Cancelable!void {
            const state: *@This() = @ptrCast(@alignCast(context.?)); // safe: this test Io carries a Controlled state as userdata
            state.sleeps += 1;
            if (state.sleeps == 2) state.fresh_expired = state.conn.timed_out.load(.acquire);
            if (state.sleeps > 2) return error.Canceled;
        }

        fn now(context: ?*anyopaque, _: Io.Clock) Io.Timestamp {
            const state: *@This() = @ptrCast(@alignCast(context.?)); // safe: this test Io carries a Controlled state as userdata
            if (state.sleeps == 1) {
                // Refresh activity while the clock is sampled. The cases
                // cover starts before and after the sample's timestamp.
                state.conn.busy_since.store(state.fresh, .release);
                return .{ .nanoseconds = state.sampled };
            }
            return .{ .nanoseconds = state.fresh + 10 * std.time.ns_per_s - 1 };
        }

        fn shutdown(context: ?*anyopaque, _: Io.net.Socket.Handle, _: Io.net.ShutdownHow) Io.net.ShutdownError!void {
            const state: *@This() = @ptrCast(@alignCast(context.?)); // safe: this test Io carries a Controlled state as userdata
            state.shutdowns += 1;
        }
    };
    var conn: Connection = undefined;
    conn.busy_since = .init(initial_start);
    conn.handshake_until = .init(0);
    conn.timed_out = .init(false);
    var state: Controlled = .{ .conn = &conn, .sampled = sampled, .fresh = fresh };
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = Controlled.sleep;
    vtable.now = Controlled.now;
    vtable.netShutdown = Controlled.shutdown;
    const io: Io = .{ .userdata = &state, .vtable = &vtable };
    var client: Client = .init(std.testing.allocator, io);
    defer client.deinit();
    client.timeouts.activity = .fromSeconds(10);
    conn.client = &client;
    conn.stream = .{ .socket = .{ .handle = undefined, .address = undefined } };

    Connection.watch(&conn);
    try std.testing.expectEqual(@as(usize, 2), state.sleeps);
    try std.testing.expect(!state.fresh_expired);
    // The same operation really does expire at its unchanged deadline.
    try std.testing.expect(conn.timed_out.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.shutdowns);
}

test "the watchdog cannot expire activity begun after its clock sample" {
    try checkWatchdogActivity(0, 1000, 2001);
}

test "the watchdog cannot expire activity refreshed before its clock sample" {
    try checkWatchdogActivity(1, 10 * std.time.ns_per_s, 10 * std.time.ns_per_s + 1);
}

test "a connection expires at its controlled connect deadline and cancels the dial" {
    const Controlled = struct {
        var active: *@This() = undefined;
        const base = std.testing.io;
        clock: std.atomic.Value(i64) = .init(0),
        connecting: Io.Event = .unset,
        timer_started: Io.Event = .unset,
        before_deadline: Io.Event = .unset,
        checked_before: Io.Event = .unset,
        at_deadline: Io.Event = .unset,
        never_connected: Io.Event = .unset,
        done: Io.Event = .unset,
        dial_canceled: std.atomic.Value(bool) = .init(false),
        requested_timeout: bool = false,
        result: Error!Io.net.Stream = undefined,

        fn now(context: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
            if (clock != .awake) return base.vtable.now(context, clock);
            return .{ .nanoseconds = active.clock.load(.acquire) };
        }

        fn connect(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
            const state = active;
            state.connecting.set(base);
            state.never_connected.wait(base) catch |err| {
                state.dial_canceled.store(true, .release);
                return err;
            };
            return error.ConnectionRefused;
        }

        fn sleep(_: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
            const state = active;
            const duration = timeout.duration;
            state.requested_timeout = duration.clock == .awake and duration.raw.nanoseconds == 200 * std.time.ns_per_ms;
            const deadline = state.clock.load(.acquire) + duration.raw.nanoseconds;
            state.timer_started.set(base);
            try state.before_deadline.wait(base);
            if (state.clock.load(.acquire) < deadline) {
                state.checked_before.set(base);
                try state.at_deadline.wait(base);
            }
        }

        fn run(client: *Client, state: *@This()) void {
            state.result = Connection.dial(client, "127.0.0.1", 1);
            state.done.set(base);
        }
    };
    const io = std.testing.io;
    var state: Controlled = .{};
    Controlled.active = &state;
    var vtable = io.vtable.*;
    vtable.now = Controlled.now;
    vtable.netConnectIp = Controlled.connect;
    vtable.sleep = Controlled.sleep;
    const controlled: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var client: Client = .init(std.testing.allocator, controlled);
    defer client.deinit();
    client.timeouts.connect = .fromMilliseconds(200);
    var task = try io.concurrent(Controlled.run, .{ &client, &state });
    defer task.cancel(io);
    const connect_watchdog: Io.Duration = .fromSeconds(5);
    const watchdog: Io.Timeout = .{ .duration = .{ .raw = connect_watchdog, .clock = .awake } };
    state.connecting.waitTimeout(io, watchdog) catch return error.ConnectReadinessWatchdogExpired;
    state.timer_started.waitTimeout(io, watchdog) catch return error.ConnectTimerWatchdogExpired;
    try std.testing.expect(state.requested_timeout);
    state.clock.store(199 * std.time.ns_per_ms, .release);
    state.before_deadline.set(io);
    state.checked_before.waitTimeout(io, watchdog) catch return error.ConnectBoundaryWatchdogExpired;
    try std.testing.expect(!state.done.isSet());
    try std.testing.expect(!state.dial_canceled.load(.acquire));
    state.clock.store(200 * std.time.ns_per_ms, .release);
    state.at_deadline.set(io);
    state.done.waitTimeout(io, watchdog) catch @panic("connect completion watchdog expired");
    task.await(io);
    try std.testing.expectError(error.TimedOut, state.result);
    try std.testing.expect(state.dial_canceled.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), client.unwatched);
}

test "nothing in relic names the standard library's HTTP client, whose CONNECT tunnel carries the request in the clear" {
    // The standard library's client opens a tunnel through a proxy and
    // never starts the TLS the https URL asked for inside it, and its
    // fallback sends the request to the proxy whole: an https request in
    // the clear either way. relic makes every connection here instead, and
    // this holds it to that: no source file names that client at all.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const needle = "http." ++ "Client";
    var src = try Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const text = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 << 20));
        defer gpa.free(text);
        files += 1;
        if (std.mem.indexOf(u8, text, needle)) |at| {
            std.debug.print("{s} names the standard library's HTTP client at byte {d}\n", .{ entry.path, at });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(files > 50);
}

test "every TLS connection is relic's own client: nothing outside src/tls names the standard library's" {
    // One TLS path: the one that answers a server's request for a client
    // certificate, and keeps the standard library's checks of the server's.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const needles = [_][]const u8{ "crypto.tls." ++ "Client", "= std.crypto." ++ "tls;" };
    var src = try Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "transport" ++ std.fs.path.sep_str ++ "tls" ++ std.fs.path.sep_str)) continue;
        const text = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 << 20));
        defer gpa.free(text);
        files += 1;
        for (needles) |needle| if (std.mem.indexOf(u8, text, needle)) |at| {
            std.debug.print("{s} names the standard library's TLS client at byte {d}\n", .{ entry.path, at });
            return error.TestUnexpectedResult;
        };
    }
    try std.testing.expect(files > 50);
}

test "a response head is read as HTTP/1.1 says, and one that is not is refused" {
    const head = try Head.parse("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nContent-Encoding: gzip\r\nLocation: /x\r\n\r\n");
    try std.testing.expectEqual(http.Status.ok, head.status);
    try std.testing.expectEqual(@as(?u64, 12), head.content_length);
    try std.testing.expectEqual(http.ContentEncoding.gzip, head.content_encoding);
    try std.testing.expect(head.keep_alive);
    try std.testing.expectEqualStrings("/x", head.location.?);
    const chunked = try Head.parse("HTTP/1.0 404 Not Found\r\nTransfer-Encoding: gzip, chunked\r\nConnection: keep-alive\r\n\r\n");
    try std.testing.expectEqual(http.TransferEncoding.chunked, chunked.transfer_encoding);
    try std.testing.expectEqual(http.ContentEncoding.gzip, chunked.content_encoding);
    try std.testing.expect(chunked.keep_alive);
    try std.testing.expect(!(try Head.parse("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")).keep_alive);
    for ([_][]const u8{
        "HTTP/2 200 OK\r\n\r\n",
        "HTTP/1.1 2x0 OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        "HTTP/1.1 200 OK\r\n folded\r\n\r\n",
        "HTTP/1.1 200 OK\r\nNo-Colon\r\n\r\n",
        "HTTP/1.1 200 OK",
    }) |bytes| try std.testing.expectError(error.MalformedHead, Head.parse(bytes));
}

test "fuzz: any response head is read or refused by name" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const bytes = buf[0..smith.slice(&buf)];
            const head = Head.parse(bytes) catch return;
            var it = head.iterateHeaders();
            while (it.next()) |_| {}
        }
    }.one, .{ .corpus = &.{"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n"} });
}

const CertificateClock = struct {
    threadlocal var current: Io.Timestamp = .zero;
    threadlocal var reads: usize = 0;

    fn now(context: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        if (clock != .real) return std.testing.io.vtable.now(context, clock);
        reads += 1;
        return current;
    }

    fn io(vtable: *Io.VTable) Io {
        vtable.* = std.testing.io.vtable.*;
        vtable.now = now;
        return .{ .userdata = std.testing.io.userdata, .vtable = vtable };
    }
};

test "trust refresh samples certificate time even after a failed read" {
    var vtable: Io.VTable = undefined;
    var client: Client = .init(std.testing.allocator, CertificateClock.io(&vtable));
    defer client.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try @import("../testing/remote.zig").absolutePath(std.testing.allocator, std.testing.io, tmp.dir);
    defer std.testing.allocator.free(path);
    const absent = try std.fs.path.join(std.testing.allocator, &.{ path, "absent.pem" });
    defer std.testing.allocator.free(absent);
    CertificateClock.current = Io.Clock.real.now(std.testing.io);
    CertificateClock.reads = 0;
    try std.testing.expectError(error.CertificateFileUnreadable, client.trustFile(absent));
    CertificateClock.current.nanoseconds += std.time.ns_per_s;
    try std.testing.expectError(error.CertificateFileUnreadable, client.trustProxyFile(absent));
    try std.testing.expectEqual(@as(usize, 2), CertificateClock.reads);
}

test "new TLS connections check certificate validity at their own time" {
    const gpa = std.testing.allocator;
    const fixture_io = std.testing.io;
    const front = try @import("../testing/remote.zig").TlsFront.start(gpa, fixture_io, 1);
    defer front.stop(fixture_io);
    var vtable: Io.VTable = undefined;
    var client: Client = .init(gpa, CertificateClock.io(&vtable));
    defer client.deinit();
    var diagnostic: Diagnostic = .init(gpa);
    defer diagnostic.deinit();
    CertificateClock.current = Io.Clock.real.now(fixture_io);
    try client.trustFile(front.cert_path);
    const cert: Certificate = .{ .buffer = client.bundle.bytes.items, .index = 0 };
    const validity = (try cert.parse()).validity;
    const target: Target = .{ .tls = true, .host = "127.0.0.1", .port = front.port };
    CertificateClock.current.nanoseconds = @as(i96, validity.not_before + 1) * std.time.ns_per_s;
    (try client.connect(target, &diagnostic)).close();
    CertificateClock.current.nanoseconds = @as(i96, validity.not_after + 1) * std.time.ns_per_s;
    if (client.connect(target, &diagnostic)) |conn| {
        conn.close();
        return error.ExpiredCertificateAccepted;
    } else |err| try std.testing.expectEqual(error.TlsFailed, err);
    try std.testing.expectEqual(error.CertificateExpired, diagnostic.tls_error.?);
    CertificateClock.current.nanoseconds = @as(i96, validity.not_before - 1) * std.time.ns_per_s;
    try std.testing.expectError(error.TlsFailed, client.connect(target, &diagnostic));
    try std.testing.expectEqual(error.CertificateNotYetValid, diagnostic.tls_error.?);
    CertificateClock.current.nanoseconds = @as(i96, validity.not_before + 1) * std.time.ns_per_s;
    (try client.connect(target, &diagnostic)).close();
}

test "overlapping proxy failures keep their own offered schemes and status" {
    const Fixture = struct {
        fn answer(request: []const u8) []const u8 {
            if (std.mem.indexOf(u8, request, "first.invalid") != null)
                return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n";
            if (std.mem.indexOf(u8, request, "second.invalid") != null)
                return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: NTLM\r\nContent-Length: 0\r\n\r\n";
            return "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
        }

        fn first(client: *Client, failed: *Io.Event, inspected: *Io.Event) !void {
            var diagnostic: Diagnostic = .init(client.gpa);
            defer diagnostic.deinit();
            try std.testing.expectError(error.ProxyAuthMethodUnsupported, client.connect(.{ .tls = true, .host = "first.invalid", .port = 443 }, &diagnostic));
            failed.set(client.io);
            const diagnostic_watchdog: Io.Duration = .fromSeconds(10);
            try inspected.waitTimeout(client.io, .{ .duration = .{ .raw = diagnostic_watchdog, .clock = .awake } });
            try std.testing.expectEqualStrings("Negotiate", diagnostic.proxy_offered.?);
            try std.testing.expectEqual(@as(?u16, 407), diagnostic.proxy_status);
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestServer.startRouted(gpa, io, false, "", Fixture.answer);
    defer server.stop(gpa);
    var client: Client = .init(gpa, io);
    defer client.deinit();
    client.proxy = .{ .host = "127.0.0.1", .port = server.port, .credential = .{ .user = "a", .password = "b" } };
    var diagnostic: Diagnostic = .init(gpa);
    defer diagnostic.deinit();
    var refused: Diagnostic = .init(gpa);
    defer refused.deinit();
    var failed: Io.Event = .unset;
    var inspected: Io.Event = .unset;
    var first = try io.concurrent(Fixture.first, .{ &client, &failed, &inspected });
    defer first.cancel(io) catch {};
    const diagnostic_watchdog: Io.Duration = .fromSeconds(10);
    try failed.waitTimeout(io, .{ .duration = .{ .raw = diagnostic_watchdog, .clock = .awake } });
    try std.testing.expectError(error.ProxyAuthMethodUnsupported, client.connect(.{ .tls = true, .host = "second.invalid", .port = 443 }, &diagnostic));
    try std.testing.expectEqualStrings("NTLM", diagnostic.proxy_offered.?);
    try std.testing.expectError(error.ProxyRefused, client.connect(.{ .tls = true, .host = "third.invalid", .port = 443 }, &refused));
    try std.testing.expectEqual(@as(?u16, 403), refused.proxy_status);
    inspected.set(io);
    try first.await(io);
}

test "overlapping TLS failures keep their own certificate diagnostic" {
    const Fixture = struct {
        fn expired(client: *Client, target: Target, time: u64, failed: *Io.Event, inspected: *Io.Event) !void {
            CertificateClock.current.nanoseconds = @as(i96, time) * std.time.ns_per_s;
            var diagnostic: Diagnostic = .init(client.gpa);
            defer diagnostic.deinit();
            try std.testing.expectError(error.TlsFailed, client.connect(target, &diagnostic));
            failed.set(client.io);
            const diagnostic_watchdog: Io.Duration = .fromSeconds(10);
            try inspected.waitTimeout(client.io, .{ .duration = .{ .raw = diagnostic_watchdog, .clock = .awake } });
            try std.testing.expectEqual(error.CertificateExpired, diagnostic.tls_error.?);
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const front = try @import("../testing/remote.zig").TlsFront.start(gpa, io, 1);
    defer front.stop(io);
    var vtable: Io.VTable = undefined;
    var client: Client = .init(gpa, CertificateClock.io(&vtable));
    defer client.deinit();
    CertificateClock.current = Io.Clock.real.now(io);
    try client.trustFile(front.cert_path);
    const cert: Certificate = .{ .buffer = client.bundle.bytes.items, .index = 0 };
    const validity = (try cert.parse()).validity;
    const target: Target = .{ .tls = true, .host = "127.0.0.1", .port = front.port };
    var failed: Io.Event = .unset;
    var inspected: Io.Event = .unset;
    var first = try io.concurrent(Fixture.expired, .{ &client, target, validity.not_after + 1, &failed, &inspected });
    defer first.cancel(io) catch {};
    const diagnostic_watchdog: Io.Duration = .fromSeconds(10);
    try failed.waitTimeout(io, .{ .duration = .{ .raw = diagnostic_watchdog, .clock = .awake } });
    var diagnostic: Diagnostic = .init(gpa);
    defer diagnostic.deinit();
    CertificateClock.current.nanoseconds = @as(i96, validity.not_before - 1) * std.time.ns_per_s;
    try std.testing.expectError(error.TlsFailed, client.connect(target, &diagnostic));
    try std.testing.expectEqual(error.CertificateNotYetValid, diagnostic.tls_error.?);
    inspected.set(io);
    try first.await(io);
}

test "a pooled connection drops its previous exchange's diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestServer.start(gpa, io, false);
    defer server.stop(gpa);
    var client: Client = .init(gpa, io);
    defer client.deinit();
    const target: Target = .{ .tls = false, .host = "127.0.0.1", .port = server.port };
    {
        var diagnostic: Diagnostic = .init(gpa);
        defer diagnostic.deinit();
        var response = try client.send(.GET, target, "/", &.{}, null, &diagnostic);
        const conn = response.conn.?;
        try std.testing.expect(conn.diagnostic == &diagnostic);
        _ = try response.reader().discardRemaining();
        response.deinit();
        try std.testing.expect(conn.diagnostic == null);
    }
    var diagnostic: Diagnostic = .init(gpa);
    defer diagnostic.deinit();
    diagnostic.tls_error = error.CertificateExpired;
    diagnostic.proxy_status = 407;
    try diagnostic.setOffered("previous");
    var response = try client.send(.GET, target, "/", &.{}, null, &diagnostic);
    defer response.deinit();
    try std.testing.expect(response.conn.?.diagnostic == &diagnostic);
    try std.testing.expect(diagnostic.tls_error == null);
    try std.testing.expect(diagnostic.proxy_status == null);
    try std.testing.expect(diagnostic.proxy_offered == null);
    try std.testing.expectEqual(@as(u32, 1), client.connections);
    _ = try response.reader().discardRemaining();
}

/// Test-only: finish must release the socket and every connection allocation,
/// including its watchdog, while preserving the error that ended the exchange.
fn checkStreamingFinishFailure(stage: enum { body_flush, body_end, connection_flush, head_read, malformed_head, allocation, incomplete }) !void {
    const Closed = struct {
        threadlocal var count: usize = 0;

        fn close(context: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
            count += handles.len;
            std.testing.io.vtable.netClose(context, handles);
        }

        fn fail(_: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    const io = std.testing.io;
    const server = try TestServer.startAnswer(std.testing.allocator, io, false, if (stage == .malformed_head) "not HTTP\r\n\r\n" else "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    defer server.stop(std.testing.allocator);
    var allocations: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var vtable = io.vtable.*;
    vtable.netClose = Closed.close;
    var client: Client = .init(allocations.allocator(), .{ .userdata = io.userdata, .vtable = &vtable });
    defer client.deinit();
    client.timeouts.activity = .fromSeconds(10);
    var buffer: [32]u8 = undefined;
    var streaming = try client.stream(.POST, .{ .tls = false, .host = "127.0.0.1", .port = server.port }, "/", &.{}, if (stage == .incomplete) 4 else null, &buffer, null);
    const conn = streaming.conn;
    try std.testing.expect(conn.watchdog != null);
    Closed.count = 0;
    // Clean up the unfixed implementation too, so the regression reports its
    // assertion instead of abandoning a socket and watchdog after failing.
    defer if (Closed.count == 0) conn.close();
    const expected: Error = switch (stage) {
        .body_flush, .body_end, .connection_flush => blk: {
            if (stage != .connection_flush) {
                try conn.flush();
                conn.stream_writer.interface.buffer = &.{};
            }
            conn.stream_writer.interface.vtable = &.{ .drain = Closed.fail };
            if (stage == .body_flush or stage == .connection_flush) try streaming.writer().writeAll("body");
            break :blk error.ConnectionFailed;
        },
        .head_read => blk: {
            conn.stream_reader.interface.vtable = Io.Reader.failing.vtable;
            break :blk error.ConnectionFailed;
        },
        .malformed_head => error.HttpProtocolError,
        .allocation => blk: {
            allocations.fail_index = allocations.alloc_index;
            break :blk error.OutOfMemory;
        },
        .incomplete => error.BodyIncomplete,
    };
    try std.testing.expectError(expected, streaming.finish());
    try std.testing.expectEqual(@as(usize, 1), Closed.count);
    try std.testing.expectEqual(allocations.allocated_bytes, allocations.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), client.idle.items.len);
}

test "streaming finish consumes its connection when the buffered body cannot be written" {
    try checkStreamingFinishFailure(.body_flush);
}

test "streaming finish consumes its connection when the chunk terminator cannot be written" {
    try checkStreamingFinishFailure(.body_end);
}

test "streaming finish consumes its connection when the connection cannot be flushed" {
    try checkStreamingFinishFailure(.connection_flush);
}

test "streaming finish consumes its connection when the response head cannot be read" {
    try checkStreamingFinishFailure(.head_read);
}

test "streaming finish consumes its connection when the response head is malformed" {
    try checkStreamingFinishFailure(.malformed_head);
}

test "streaming finish consumes its connection when the response cannot be allocated" {
    try checkStreamingFinishFailure(.allocation);
}

test "streaming finish consumes its connection when the body is incomplete" {
    try checkStreamingFinishFailure(.incomplete);
}

test "proxy URLs share SOCKS defaults and preserve IPv6 hosts and decoded credentials" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Proxy.parse(a, "SOCKS5H://us%65r:p%40ss@[::1]", 80);
    try std.testing.expectEqualStrings("::1", p.host);
    try std.testing.expectEqual(@as(u16, 1080), p.port);
    try std.testing.expectEqual(.socks5h, p.socks_version.?);
    try std.testing.expectEqualStrings("user", p.credential.?.user);
    try std.testing.expectEqualStrings("p@ss", p.credential.?.password);
    try std.testing.expect(!p.tls);
    for ([_][]const u8{ "unsupported://host", "socks5://", "socks5://host:bad", "socks5://h%00st" }) |text| {
        try std.testing.expectError(error.InvalidProxy, Proxy.parse(a, text, 80));
    }
    const explicit = try Proxy.parse(a, "socks4://user@host:7777", 80);
    try std.testing.expectEqual(@as(u16, 7777), explicit.port);
    try std.testing.expectEqualStrings("", explicit.credential.?.password);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Proxy.parse(failing.allocator(), "socks5h://us%65r@proxy", 80));
}

test "SOCKS local DNS enforces IPv4 and keeps the first address of the preferred family" {
    const testing = std.testing;
    const Mock = struct {
        fn lookup(_: ?*anyopaque, name: Io.net.HostName, results: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
            const io = testing.io;
            defer results.close(io);
            const addresses: []const Io.net.HostName.LookupResult = &.{
                .{ .address = .{ .ip6 = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = options.port } } },
                .{ .address = .{ .ip6 = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }, .port = options.port } } },
                .{ .address = .{ .ip4 = .loopback(options.port) } },
            };
            // The libc resolver in Zig 0.16 may return both families even
            // when LookupOptions.family asks for IPv4.
            const count: usize = if (std.mem.eql(u8, name.bytes, "ipv6-only")) 2 else 3;
            results.putAll(io, addresses[0..count]) catch |err| return switch (err) {
                error.Canceled => error.Canceled,
                error.Closed => unreachable,
            };
        }
    };
    var vtable = testing.io.vtable.*;
    vtable.netLookup = Mock.lookup;
    const io: Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    const four = try Connection.resolveSocks(io, "localhost", 80, true);
    try testing.expectEqual(Io.net.IpAddress.Family.ip4, std.meta.activeTag(four));
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &four.ip4.bytes);
    const five = try Connection.resolveSocks(io, "localhost", 80, false);
    try testing.expectEqual(Io.net.IpAddress.Family.ip6, std.meta.activeTag(five));
    try testing.expectEqual(@as(u8, 1), five.ip6.bytes[15]);
    try testing.expectError(error.ProxyHostUnreachable, Connection.resolveSocks(io, "ipv6-only", 80, true));
}
