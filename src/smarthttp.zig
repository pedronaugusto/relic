//! git's smart HTTP protocol, over `std.http.Client`.
//!
//! The conversation is a `GET` of `<url>/info/refs?service=<service>`, whose
//! body is the service's advertisement, and then one `POST` to
//! `<url>/<service>` per request, whose body is the request and whose
//! response is the answer. The server keeps nothing between two requests,
//! which is why the connection says it is stateless and the protocol above
//! repeats in every request what the last one established. Protocol v2 is
//! asked for with a `Git-Protocol` header; a server that does not speak it
//! answers in v0 behind a `# service=` line, which is taken off here.
//!
//! A redirect of the first request is followed, as git's default
//! `http.followRedirects=initial` follows it, and the requests after it go
//! where it led; a redirect of a `POST` is not. A server that answers with
//! a plain file listing — git's dumb protocol — is refused by name.
//!
//! `https://` goes through the same client with TLS from `std.crypto.tls`,
//! against the system's root certificates, or against `http.sslCAInfo` in
//! their place and `http.sslCAPath` besides — a company's own authority, a
//! self-hosted server's. That check needs the time, and it is the one place
//! a clock is read. The settings are git's, scoped by `http.<url>.*` and
//! overridden by git's environment variables (`httpsettings.zig`), and a
//! proxy is `http.proxy` or the one curl would find in the environment.
//! What the standard library's client cannot do is refused by name rather
//! than done wrong: it always checks the server's certificate, so
//! `http.sslVerify=false` is refused rather than quietly checked anyway; it
//! cannot present a client certificate, so `http.sslCert` and `http.sslKey`
//! are refused too; and it speaks plain HTTP inside a `CONNECT` tunnel, so
//! an `https` URL with a proxy is refused rather than sent in the clear.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const config_mod = @import("config.zig");
const program = @import("program.zig");
const pktline = @import("pktline.zig");
const url_mod = @import("url.zig");
const connection = @import("connection.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const httpsettings = @import("httpsettings.zig");

const Connection = connection.Connection;
const Service = connection.Service;

/// Errors from a conversation over smart HTTP.
pub const Error = error{
    /// The server asked for credentials and none were accepted:
    /// `Connection.message` holds the status.
    AuthenticationFailed,
    /// The server has no repository there.
    RepositoryNotFound,
    /// Any other status than success. `Connection.message` holds it.
    HttpStatus,
    /// The server speaks git's dumb HTTP protocol, a listing of files,
    /// which relic does not read.
    DumbHttpUnsupported,
    /// `http.sslVerify` is false, or `GIT_SSL_NO_VERIFY` is set. The
    /// standard library's HTTP client always checks the server's
    /// certificate; the way to trust a server of one's own is
    /// `http.sslCAInfo`.
    SslVerifyUnsupported,
    /// `http.sslCert` or `http.sslKey`: the standard library's TLS client
    /// cannot present a client certificate.
    SslClientCertificateUnsupported,
    /// `http.sslCAInfo` or `http.sslCAPath` names a file or directory that
    /// could not be read as certificates.
    SslCertificateUnreadable,
    /// An `http.*` value that does not parse.
    InvalidHttpSetting,
    /// An `https` URL and a proxy to reach it through. The standard
    /// library's client opens the `CONNECT` tunnel and then speaks plain
    /// HTTP inside it, which would hand the request — credentials and all
    /// — to the proxy unencrypted; relic refuses rather than send it.
    HttpsProxyUnsupported,
    /// An `http.extraHeader` that is not `Name: value`, or that holds a line
    /// break.
    InvalidHttpHeader,
    /// A redirect of the first request led somewhere that is not the same
    /// service, which git refuses too.
    RedirectMismatch,
    /// A proxy the configuration or the environment names that does not
    /// parse.
    InvalidProxy,
} || connection.Error || credential.Error;

/// How the conversation is made.
pub const Options = struct {
    /// The repository's configuration, for the `http.*` settings.
    config: ?*const config_mod.Config = null,
    /// The permission to run credential helpers and `askpass`; its
    /// environment is also where `http_proxy`, `https_proxy`, `all_proxy`
    /// and `GIT_ASKPASS` are read.
    programs: ?program.Programs = null,
    /// Ask an upload-pack for protocol v2.
    protocol_v2: bool = true,
    /// Answers the credential prompt git would show on a terminal, when no
    /// helper has the answer. Without it nothing is asked.
    prompt: ?credential.Prompt = null,
    /// Filled in when the conversation fails for want of a credential.
    auth_failure: ?*auth.Failure = null,
};

/// What the client calls itself. A server that treats git specially looks
/// for the `git/` in front.
pub const user_agent = "git/2.0 (relic 0.3)";

/// Open a smart HTTP conversation with the service at `url`.
pub fn connect(gpa: Allocator, io: Io, url: url_mod.Url, service: Service, options: Options) Error!*Connection {
    const h = try gpa.create(Http);
    errdefer gpa.destroy(h);
    h.* = .{
        .gpa = gpa,
        .io = io,
        .arena = .init(gpa),
        .client = .{ .allocator = gpa, .io = io },
        .base = undefined,
        .service = service,
        .v2 = options.protocol_v2 and service == .upload_pack,
        .options = options,
        .transfer_buffer = undefined,
        .redirect_buffer = undefined,
        .post_buffer = undefined,
        .post = undefined,
        .connection = .{ .context = h, .vtable = &Http.vtable, .stateless = true },
        .credentials = .{ .gpa = gpa, .url = url },
    };
    errdefer h.arena.deinit();
    const arena = h.arena.allocator();
    errdefer h.client.deinit();
    errdefer h.credentials.deinit();
    errdefer h.endRequest();

    const settings = try h.configure(url);
    h.transfer_buffer = try arena.alloc(u8, pktline.max_line + 16);
    h.redirect_buffer = try arena.alloc(u8, 8 * 1024);
    h.post_buffer = try arena.alloc(u8, @intCast(settings.post_buffer));
    h.post = .{ .vtable = &.{ .drain = Http.drainPost }, .buffer = h.post_buffer };
    // The advertisement is asked for here, so that what can go wrong with
    // the first request — a credential refused, no repository, a dumb
    // server — is refused by its own name.
    _ = try h.advertisementInner();
    return &h.connection;
}

const Http = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    client: http.Client,
    /// `scheme://host[:port]/path`, without a trailing slash and without
    /// the credentials a URL may carry.
    base: []const u8,
    service: Service,
    v2: bool,
    options: Options,
    /// `http.extraHeader`, and the ones the protocol adds.
    extra_headers: []const http.Header = &.{},
    /// `http.userAgent`, or relic's own.
    user_agent: []const u8 = user_agent,
    in_flight: ?http.Client.Request = null,
    /// The URL of the request in flight, which it borrows.
    request_url: []u8 = &.{},
    body: http.BodyWriter = undefined,
    streaming: bool = false,
    transfer_buffer: []u8,
    redirect_buffer: []u8,
    post_buffer: []u8,
    post: Io.Writer,
    decompress: http.Decompress = undefined,
    decompress_buffer: []u8 = &.{},
    body_reader: *Io.Reader = undefined,
    advertised: bool = false,
    connection: Connection,
    credentials: credential.Session,
    /// A failure met inside a writer, which can only say that it failed.
    write_error: ?Error = null,

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .close = close,
    };

    fn self(context: *anyopaque) *Http {
        return @ptrCast(@alignCast(context));
    }

    /// The settings: TLS options relic cannot honour are refused, the
    /// certificates to trust loaded, the extra headers read, and a proxy
    /// set up.
    fn configure(h: *Http, url: url_mod.Url) Error!httpsettings.Settings {
        const arena = h.arena.allocator();
        // The base URL, without the userinfo, which becomes the credential.
        var base: std.ArrayList(u8) = .empty;
        try base.print(arena, "{s}://", .{@tagName(url.scheme)});
        if (std.mem.indexOfScalar(u8, url.host, ':') != null) {
            try base.print(arena, "[{s}]", .{url.host});
        } else try base.appendSlice(arena, url.host);
        if (url.port) |port| try base.print(arena, ":{d}", .{port});
        var path = url.path;
        while (path.len != 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        try base.appendSlice(arena, path);
        h.base = base.items;

        const environ: ?*const std.process.Environ.Map = if (h.options.programs) |p| p.environ else null;
        const settings = try httpsettings.resolve(arena, h.options.config, environ, url);
        if (url.scheme == .https) {
            if (!settings.ssl_verify) return h.fail(error.SslVerifyUnsupported, settings.ssl_verify_from orelse "http.sslVerify");
            if (settings.ssl_cert != null or settings.ssl_key != null) return h.fail(error.SslClientCertificateUnsupported, if (settings.ssl_cert != null) "http.sslCert" else "http.sslKey");
            if (settings.ca_info != null or settings.ca_path != null) try h.trust(settings, environ);
        }

        var headers: std.ArrayList(http.Header) = .empty;
        for (settings.extra_headers) |text| {
            if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidHttpHeader;
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidHttpHeader;
            const name = std.mem.trim(u8, text[0..colon], " \t");
            if (name.len == 0) return error.InvalidHttpHeader;
            try headers.append(arena, .{ .name = name, .value = std.mem.trim(u8, text[colon + 1 ..], " \t") });
        }
        if (h.v2) try headers.append(arena, .{ .name = "Git-Protocol", .value = "version=2" });
        h.extra_headers = headers.items;
        if (settings.user_agent) |agent| h.user_agent = agent;

        if (settings.proxy) |text| {
            if (url.scheme == .https) return h.fail(error.HttpsProxyUnsupported, text);
            try h.configureProxy(url, text);
        }
        return settings;
    }

    /// Trust `http.sslCAInfo` in place of the system's certificates, and
    /// `http.sslCAPath` besides them, as curl does for git.
    fn trust(h: *Http, settings: httpsettings.Settings, environ: ?*const std.process.Environ.Map) Error!void {
        const io = h.io;
        const now = Io.Clock.real.now(io);
        const bundle = &h.client.ca_bundle;
        const cwd = Io.Dir.cwd();
        if (settings.ca_info) |raw| {
            const file = try expandHome(h.arena.allocator(), raw, environ);
            bundle.addCertsFromFilePath(h.gpa, io, now, cwd, file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return h.fail(error.SslCertificateUnreadable, settings.ca_info_from orelse "http.sslCAInfo"),
            };
        } else {
            bundle.rescan(h.gpa, io, now) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return h.fail(error.SslCertificateUnreadable, "the system's certificates"),
            };
        }
        if (settings.ca_path) |raw| {
            const dir_path = try expandHome(h.arena.allocator(), raw, environ);
            var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return h.fail(error.SslCertificateUnreadable, "http.sslCAPath");
            defer dir.close(io);
            bundle.addCertsFromDir(h.gpa, io, now, dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return h.fail(error.SslCertificateUnreadable, "http.sslCAPath"),
            };
        }
        // Set, the client neither rescans the system nor reads the clock
        // again.
        h.client.now = now;
    }

    fn expandHome(arena: Allocator, path: []const u8, environ: ?*const std.process.Environ.Map) Allocator.Error![]const u8 {
        if (!std.mem.startsWith(u8, path, "~/")) return path;
        const env = environ orelse return path;
        const home = env.get("HOME") orelse return path;
        return std.fs.path.join(arena, &.{ home, path[2..] });
    }

    fn configureProxy(h: *Http, url: url_mod.Url, text: []const u8) Error!void {
        const arena = h.arena.allocator();
        const uri = std.Uri.parse(text) catch std.Uri.parseAfterScheme("http", text) catch return error.InvalidProxy;
        const protocol = http.Client.Protocol.fromUri(uri) orelse return error.InvalidProxy;
        const host = uri.getHostAlloc(arena) catch return error.InvalidProxy;
        var authorization: ?[]const u8 = null;
        if (uri.user != null or uri.password != null) {
            const value = try arena.alloc(u8, http.Client.basic_authorization.valueLengthFromUri(uri));
            authorization = http.Client.basic_authorization.value(uri, value);
        }
        const proxy = try arena.create(http.Client.Proxy);
        proxy.* = .{
            .protocol = protocol,
            .host = host,
            .authorization = authorization,
            .port = uri.port orelse switch (protocol) {
                .plain => 1080,
                .tls => 443,
            },
            // curl hands an http request to the proxy whole, with its
            // absolute URL, rather than asking for a tunnel.
            .supports_connect = false,
        };
        switch (url.scheme) {
            .https => h.client.https_proxy = proxy,
            else => h.client.http_proxy = proxy,
        }
    }

    /// Give back the request in flight, reading what is left of its body
    /// so its connection can be used again.
    fn endRequest(h: *Http) void {
        if (h.in_flight) |*req| {
            req.deinit();
            h.in_flight = null;
        }
        if (h.request_url.len != 0) {
            h.gpa.free(h.request_url);
            h.request_url = &.{};
        }
        if (h.decompress_buffer.len != 0) {
            h.gpa.free(h.decompress_buffer);
            h.decompress_buffer = &.{};
        }
        h.streaming = false;
    }

    fn headersFor(h: *const Http, authorization: ?[]const u8) http.Client.Request.Headers {
        return .{
            .user_agent = .{ .override = h.user_agent },
            .authorization = if (authorization) |a| .{ .override = a } else .omit,
        };
    }

    /// Open a request to `<base><suffix>`.
    fn open(h: *Http, method: http.Method, suffix: []const u8, authorization: ?[]const u8) Error!void {
        h.endRequest();
        h.request_url = try std.fmt.allocPrint(h.gpa, "{s}{s}", .{ h.base, suffix });
        const uri = std.Uri.parse(h.request_url) catch return h.fail(error.ConnectionFailed, "malformed URL");
        var extra: std.ArrayList(http.Header) = .empty;
        defer extra.deinit(h.gpa);
        try extra.appendSlice(h.gpa, h.extra_headers);
        try extra.append(h.gpa, .{ .name = "Pragma", .value = "no-cache" });
        if (method == .POST) {
            // The values live as long as the connection: the request is sent
            // after this returns.
            const arena = h.arena.allocator();
            try extra.append(h.gpa, .{
                .name = "Content-Type",
                .value = try std.fmt.allocPrint(arena, "application/x-{s}-request", .{h.service.name()}),
            });
            try extra.append(h.gpa, .{
                .name = "Accept",
                .value = try std.fmt.allocPrint(arena, "application/x-{s}-result", .{h.service.name()}),
            });
        }
        // The headers are copied into the request's own list, which must
        // outlive it: kept in the arena.
        const headers = try h.arena.allocator().dupe(http.Header, extra.items);
        h.in_flight = h.client.request(method, uri, .{
            .headers = h.headersFor(authorization),
            .extra_headers = headers,
            .keep_alive = true,
            .redirect_behavior = if (method == .GET) @enumFromInt(5) else .unhandled,
        }) catch |err| return h.fail(mapRequestError(err), @errorName(err));
    }

    fn credentialOptions(h: *const Http) credential.Options {
        return .{ .config = h.options.config, .programs = h.options.programs, .prompt = h.options.prompt };
    }

    fn fail(h: *Http, err: Error, text: []const u8) Error {
        h.connection.setMessage(text);
        return err;
    }

    fn mapRequestError(err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.ConnectionFailed,
        };
    }

    /// Send a `GET` and read its head, handling a request for credentials
    /// as git's `http_request_reauth` does: a 401 to a request that carried
    /// none fills one and tries again; a 401 to one that carried one
    /// rejects it and ends there.
    fn get(h: *Http, suffix: []const u8) Error!http.Client.Response {
        while (true) {
            const authorization = h.credentials.authorization();
            try h.open(.GET, suffix, authorization);
            const req = &h.in_flight.?;
            req.sendBodiless() catch |err| return h.fail(mapRequestError(err), @errorName(err));
            var head = req.receiveHead(h.redirect_buffer) catch |err| return h.fail(mapRequestError(err), @errorName(err));
            if (head.head.status == .unauthorized) {
                try h.keepChallenges(&head.head);
                const said = try h.serverText(&head);
                if (authorization != null) {
                    h.credentials.reject(h.io, h.credentialOptions()) catch |err| return h.authFailed(err, .refused, 401, said);
                    return h.authFailed(error.AuthenticationFailed, .refused, 401, said);
                }
                const filled = h.credentials.fill(h.io, h.credentialOptions()) catch |err| {
                    return h.authFailed(err, switch (err) {
                        error.CredentialHelperQuit => .helper_quit,
                        error.ProgramsNotGranted => .programs_not_granted,
                        else => .no_credential,
                    }, 401, said);
                };
                if (!filled) return h.authFailed(error.AuthenticationFailed, .declined, 401, said);
                continue;
            }
            if (head.head.status.class() == .success and authorization != null) {
                try h.credentials.setChallenges(&.{});
                try h.credentials.approve(h.io, h.credentialOptions());
            }
            return head;
        }
    }

    /// Keep the `WWW-Authenticate` values of a refusal for the helpers.
    fn keepChallenges(h: *Http, head: *const http.Client.Response.Head) Error!void {
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(h.gpa);
        var it = head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "www-authenticate")) try values.append(h.gpa, header.value);
        }
        try h.credentials.setChallenges(values.items);
    }

    /// The body of a refusal when it is `text/plain`, which is where a forge
    /// explains itself and what git shows as `remote:` lines. At most 4 KiB,
    /// in the connection's arena.
    fn serverText(h: *Http, res: *http.Client.Response) Error![]const u8 {
        const content_type = res.head.content_type orelse return "";
        if (!std.ascii.startsWithIgnoreCase(content_type, "text/plain")) return "";
        const reader = h.bodyOf(res) catch return "";
        var out: Io.Writer.Allocating = .init(h.arena.allocator());
        _ = reader.stream(&out.writer, .limited(4096)) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return out.written(),
        };
        _ = reader.streamRemaining(&out.writer) catch {};
        const text = out.written();
        return text[0..@min(text.len, 4096)];
    }

    /// End with `err`, describing it in the caller's `auth_failure`.
    fn authFailed(h: *Http, err: anyerror, reason: auth.Failure.Reason, status: u16, said: []const u8) Error {
        const trimmed = std.mem.trim(u8, said, " \t\r\n");
        var status_buf: [16]u8 = undefined;
        h.connection.setMessage(if (trimmed.len != 0) trimmed else std.fmt.bufPrint(&status_buf, "HTTP {d}", .{status}) catch "HTTP");
        if (h.options.auth_failure) |described| describe: {
            described.begin(h.gpa, reason, h.credentials.url.scheme, h.credentials.url.raw) catch break :describe;
            described.status = status;
            described.setServerMessage(said) catch {};
            h.credentials.describeFailure(described, h.options.prompt != null) catch {};
        }
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.CredentialHelperQuit => error.CredentialHelperQuit,
            error.CredentialsUnavailable => error.CredentialsUnavailable,
            error.CredentialMultistageUnsupported => error.CredentialMultistageUnsupported,
            error.ProgramsNotGranted => error.ProgramsNotGranted,
            error.AuthenticationFailed => error.AuthenticationFailed,
            else => error.AuthenticationFailed,
        };
    }

    fn checkStatus(h: *Http, res: *http.Client.Response) Error!void {
        const status = @intFromEnum(res.head.status);
        switch (res.head.status) {
            .ok => return,
            .unauthorized, .forbidden => {
                if (res.head.status == .unauthorized) try h.keepChallenges(&res.head);
                const said = try h.serverText(res);
                return h.authFailed(error.AuthenticationFailed, if (status == 403) .forbidden else .refused, status, said);
            },
            else => {
                const said = std.mem.trim(u8, try h.serverText(res), " \t\r\n");
                var buf: [32]u8 = undefined;
                const text = if (said.len != 0) said else std.fmt.bufPrint(&buf, "HTTP {d}", .{status}) catch "HTTP";
                return h.fail(if (res.head.status == .not_found) error.RepositoryNotFound else error.HttpStatus, text);
            },
        }
    }

    fn bodyOf(h: *Http, res: *http.Client.Response) Error!*Io.Reader {
        switch (res.head.content_encoding) {
            .identity => return res.reader(h.transfer_buffer),
            .gzip, .deflate => {
                h.decompress_buffer = try h.gpa.alloc(u8, std.compress.flate.max_window_len);
                return res.readerDecompressing(h.transfer_buffer, &h.decompress, h.decompress_buffer);
            },
            else => return h.fail(error.ProtocolError, "unsupported content encoding"),
        }
    }

    fn advertisement(context: *anyopaque, _: *Connection) connection.Error!*Io.Reader {
        return self(context).body_reader;
    }

    fn advertisementInner(h: *Http) Error!*Io.Reader {
        var suffix_buf: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "/info/refs?service={s}", .{h.service.name()}) catch unreachable;
        var res = try h.get(suffix);
        try h.checkStatus(&res);
        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "application/x-{s}-advertisement", .{h.service.name()}) catch unreachable;
        const content_type = res.head.content_type orelse "";
        if (!std.mem.eql(u8, content_type, expected)) return error.DumbHttpUnsupported;

        // A redirect moves the base for every request after this one.
        const final = h.in_flight.?.uri;
        var final_buf: std.Io.Writer.Allocating = .init(h.gpa);
        defer final_buf.deinit();
        final.writeToStream(&final_buf.writer, .{ .scheme = true, .authority = true, .path = true }) catch return error.OutOfMemory;
        const redirected = final_buf.written();
        if (!std.mem.eql(u8, redirected, h.request_url[0 .. h.request_url.len - suffix.len + "/info/refs".len])) {
            if (!std.mem.endsWith(u8, redirected, "/info/refs")) return error.RedirectMismatch;
            h.base = try h.arena.allocator().dupe(u8, redirected[0 .. redirected.len - "/info/refs".len]);
        }

        const body = try h.bodyOf(&res);
        // A v0 answer begins `# service=<name>` and a flush, which say what
        // the body is and nothing else.
        const first = body.peekArray(4) catch return error.RemoteHungUp;
        const len = pktline.parseLength(first) orelse return error.ProtocolError;
        if (len > 4) {
            const whole = body.peek(len) catch return error.RemoteHungUp;
            if (std.mem.startsWith(u8, whole[4..], "# service=")) {
                body.toss(len);
                const flush = body.takeArray(4) catch return error.RemoteHungUp;
                if (!std.mem.eql(u8, flush, "0000")) return error.ProtocolError;
            }
        }
        h.body_reader = body;
        h.advertised = true;
        return body;
    }

    fn request(context: *anyopaque, _: *Connection) connection.Error!*Io.Writer {
        const h = self(context);
        h.endRequest();
        h.post.end = 0;
        h.write_error = null;
        return &h.post;
    }

    /// The request writer's buffer is full: the request is too large to
    /// send whole, so it is sent in chunks from here on.
    fn drainPost(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const h: *Http = @alignCast(@fieldParentPtr("post", w));
        if (!h.streaming) {
            h.startStreaming() catch |err| {
                h.write_error = err;
                return error.WriteFailed;
            };
        }
        const out = &h.body.writer;
        out.writeAll(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            out.writeAll(slice) catch return error.WriteFailed;
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| out.writeAll(pattern) catch return error.WriteFailed;
        return consumed + pattern.len * splat;
    }

    fn startStreaming(h: *Http) Error!void {
        var suffix_buf: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "/{s}", .{h.service.name()}) catch unreachable;
        try h.open(.POST, suffix, h.credentials.authorization());
        const req = &h.in_flight.?;
        req.transfer_encoding = .chunked;
        h.body = req.sendBodyUnflushed(&.{}) catch |err| return h.fail(mapRequestError(err), @errorName(err));
        h.streaming = true;
    }

    fn response(context: *anyopaque, _: *Connection) connection.Error!*Io.Reader {
        const h = self(context);
        return h.responseInner() catch |err| return narrow(h, err);
    }

    fn responseInner(h: *Http) Error!*Io.Reader {
        if (h.write_error) |err| return err;
        if (h.streaming) {
            h.body.writer.writeAll(h.post.buffered()) catch return h.fail(error.ConnectionFailed, "write failed");
            h.post.end = 0;
            h.body.end() catch return h.fail(error.ConnectionFailed, "write failed");
            h.in_flight.?.connection.?.flush() catch return h.fail(error.ConnectionFailed, "write failed");
        } else {
            var suffix_buf: [64]u8 = undefined;
            const suffix = std.fmt.bufPrint(&suffix_buf, "/{s}", .{h.service.name()}) catch unreachable;
            try h.open(.POST, suffix, h.credentials.authorization());
            const req = &h.in_flight.?;
            req.sendBodyComplete(h.post.buffered()) catch |err| return h.fail(mapRequestError(err), @errorName(err));
            h.post.end = 0;
        }
        var res = h.in_flight.?.receiveHead(&.{}) catch |err| return h.fail(mapRequestError(err), @errorName(err));
        try h.checkStatus(&res);
        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "application/x-{s}-result", .{h.service.name()}) catch unreachable;
        if (!std.mem.eql(u8, res.head.content_type orelse "", expected)) return h.fail(error.ProtocolError, "unexpected content type");
        h.body_reader = try h.bodyOf(&res);
        return h.body_reader;
    }

    fn failure(context: *anyopaque, c: *Connection) connection.Error {
        const h = self(context);
        if (h.in_flight) |*req| {
            if (req.reader.body_err) |err| {
                c.setMessage(@errorName(err));
                return error.ConnectionFailed;
            }
        }
        return error.ConnectionFailed;
    }

    fn close(context: *anyopaque, io: Io) void {
        _ = io;
        const h = self(context);
        h.endRequest();
        h.client.deinit();
        h.credentials.deinit();
        h.arena.deinit();
        h.gpa.destroy(h);
    }

    /// An error of this module's own that the connection interface has no
    /// name for keeps its name in the message, and is the connection's
    /// failure.
    fn narrow(h: *Http, err: Error) connection.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.RemoteHungUp => error.RemoteHungUp,
            error.ProtocolError => error.ProtocolError,
            error.RemoteError => error.RemoteError,
            error.ConnectionFailed => error.ConnectionFailed,
            error.TransportProgramFailed => error.TransportProgramFailed,
            else => {
                if (h.connection.message_len == 0) h.connection.setMessage(@errorName(err));
                return error.ConnectionFailed;
            },
        };
    }
};
