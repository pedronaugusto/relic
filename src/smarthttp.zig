//! git's smart HTTP protocol, over relic's own HTTP/1.1 client.
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
//! a plain file listing — git's dumb protocol — is refused by name. A
//! request that fits `http.postBuffer` is sent whole, gzipped when it is an
//! upload-pack request over a kilobyte, as git sends it; a larger one is
//! sent in chunks as it is written. Connections are kept between requests.
//!
//! `https://` is TLS from `std.crypto.tls`, against the system's root
//! certificates, or against `http.sslCAInfo` in their place and
//! `http.sslCAPath` besides — a company's own authority, a self-hosted
//! server's — or against nothing at all when `http.sslVerify` is false,
//! which is then returned as a warning. That check needs the time, and it
//! is the one place a clock is read. The settings are git's, scoped by
//! `http.<url>.*` and overridden by git's environment variables
//! (`httpsettings.zig`), and a proxy is `http.proxy` or the one curl would
//! find in the environment: an `https` URL goes through it in a `CONNECT`
//! tunnel with TLS inside, an `http` one as a whole URL. A proxy's
//! credentials are the ones its URL carries, a username there with the
//! password from the person's helpers, as git fills them. A client
//! certificate is refused by name: the standard library's TLS client cannot
//! present one.

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
const httpclient = @import("httpclient.zig");
const warning = @import("warning.zig");

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
    /// `http.sslCert` or `http.sslKey`: the standard library's TLS client
    /// cannot present a client certificate.
    SslClientCertificateUnsupported,
    /// `http.sslCAInfo` or `http.sslCAPath` names a file or directory that
    /// could not be read as certificates, or the system's could not be read.
    SslCertificateUnreadable,
    /// The TLS handshake failed: a certificate that is not trusted, a name
    /// that does not match. `Connection.message` names the reason.
    TlsFailed,
    /// An `http.*` value that does not parse.
    InvalidHttpSetting,
    /// An `http.extraHeader` that is not `Name: value`, or that holds a line
    /// break.
    InvalidHttpHeader,
    /// A redirect of the first request led somewhere that is not the same
    /// service, which git refuses too.
    RedirectMismatch,
    /// A proxy the configuration or the environment names that does not
    /// parse.
    InvalidProxy,
    /// The proxy refused the credentials it was given, or wanted some and
    /// had none: status 407.
    ProxyAuthenticationFailed,
    /// The proxy refused the tunnel for another reason.
    ProxyRefused,
    /// `http.proxyAuthMethod` names a scheme other than basic: digest,
    /// negotiate, ntlm.
    ProxyAuthMethodUnsupported,
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
    /// Where what git would print as a warning goes: certificate checks
    /// turned off.
    warnings: ?*warning.Warnings = null,
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
        .client = .init(gpa, io),
        .target = undefined,
        .base_path = undefined,
        .service = service,
        .v2 = options.protocol_v2 and service == .upload_pack,
        .options = options,
        .post_buffer = undefined,
        .post = undefined,
        .connection = .{ .context = h, .vtable = &Http.vtable, .stateless = true },
        .credentials = .{ .gpa = gpa, .url = url },
    };
    errdefer h.arena.deinit();
    errdefer h.client.deinit();
    errdefer h.credentials.deinit();
    errdefer h.endRequest();
    errdefer if (h.proxy_credentials) |*p| p.deinit();

    const settings = try h.configure(url);
    h.post_buffer = try h.arena.allocator().alloc(u8, @intCast(settings.post_buffer));
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
    client: httpclient.Client,
    /// Where the repository is, and the path of its URL without a
    /// trailing slash; a redirect of the first request moves both.
    target: httpclient.Target,
    base_path: []const u8,
    service: Service,
    v2: bool,
    options: Options,
    /// `http.extraHeader`, and the ones the protocol adds.
    extra_headers: []const http.Header = &.{},
    /// `http.userAgent`, or relic's own.
    user_agent: []const u8 = user_agent,
    in_flight: ?httpclient.Response = null,
    streaming: ?httpclient.Streaming = null,
    stream_buffer: []u8 = &.{},
    post_buffer: []u8,
    post: Io.Writer,
    body_reader: *Io.Reader = undefined,
    connection: Connection,
    credentials: credential.Session,
    /// The proxy's credential, when its URL names a user.
    proxy_credentials: ?credential.Session = null,
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

    fn targetOf(url: url_mod.Url) httpclient.Target {
        return .{
            .tls = url.scheme == .https,
            .host = url.host,
            .port = url.port orelse if (url.scheme == .https) 443 else 80,
        };
    }

    /// The settings: certificates to trust loaded, checks turned off where
    /// git's settings say so, the extra headers read, and a proxy set up.
    fn configure(h: *Http, url: url_mod.Url) Error!httpsettings.Settings {
        const arena = h.arena.allocator();
        h.target = targetOf(url);
        var path = url.path;
        while (path.len != 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        h.base_path = path;

        const environ: ?*const std.process.Environ.Map = if (h.options.programs) |p| p.environ else null;
        const settings = try httpsettings.resolve(arena, h.options.config, environ, url);
        if (url.scheme == .https) {
            if (settings.ssl_cert != null or settings.ssl_key != null) return h.fail(error.SslClientCertificateUnsupported, if (settings.ssl_cert != null) "http.sslCert" else "http.sslKey");
            if (!settings.ssl_verify) {
                h.client.verify = false;
                try warning.note(h.options.warnings, .{ .ssl_verify_disabled = settings.ssl_verify_from orelse "http.sslVerify" });
            } else if (settings.ca_info != null or settings.ca_path != null) try h.trust(settings, environ);
        }

        var extra: std.ArrayList(http.Header) = .empty;
        for (settings.extra_headers) |text| {
            if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidHttpHeader;
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidHttpHeader;
            const name = std.mem.trim(u8, text[0..colon], " \t");
            if (name.len == 0) return error.InvalidHttpHeader;
            try extra.append(arena, .{ .name = name, .value = std.mem.trim(u8, text[colon + 1 ..], " \t") });
        }
        if (h.v2) try extra.append(arena, .{ .name = "Git-Protocol", .value = "version=2" });
        h.extra_headers = extra.items;
        if (settings.user_agent) |agent| h.user_agent = agent;

        if (settings.proxy) |text| try h.configureProxy(text, settings.proxy_auth_method);
        return settings;
    }

    /// Trust `http.sslCAInfo` in place of the system's certificates, and
    /// `http.sslCAPath` besides them, as curl does for git.
    fn trust(h: *Http, settings: httpsettings.Settings, environ: ?*const std.process.Environ.Map) Error!void {
        const arena = h.arena.allocator();
        if (settings.ca_info) |raw| {
            h.client.trustFile(try expandHome(arena, raw, environ)) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => h.fail(error.SslCertificateUnreadable, settings.ca_info_from orelse "http.sslCAInfo"),
            };
        } else {
            h.client.trustSystem() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => h.fail(error.SslCertificateUnreadable, "the system's certificates"),
            };
        }
        if (settings.ca_path) |raw| {
            h.client.trustDirectory(try expandHome(arena, raw, environ)) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => h.fail(error.SslCertificateUnreadable, "http.sslCAPath"),
            };
        }
    }

    fn expandHome(arena: Allocator, path: []const u8, environ: ?*const std.process.Environ.Map) Allocator.Error![]const u8 {
        if (!std.mem.startsWith(u8, path, "~/")) return path;
        const env = environ orelse return path;
        const home = env.get("HOME") orelse return path;
        return std.fs.path.join(arena, &.{ home, path[2..] });
    }

    /// The proxy, and its credential: the user and password its URL
    /// carries, or a user there and the password from the person's helpers,
    /// as git's `init_curl_proxy_auth` fills it.
    fn configureProxy(h: *Http, raw: []const u8, method: []const u8) Error!void {
        const arena = h.arena.allocator();
        if (!std.ascii.eqlIgnoreCase(method, "anyauth") and !std.ascii.eqlIgnoreCase(method, "basic")) {
            return h.fail(error.ProxyAuthMethodUnsupported, method);
        }
        const text = if (std.mem.indexOf(u8, raw, "://") == null) try std.fmt.allocPrint(arena, "http://{s}", .{raw}) else raw;
        const proxy_url = url_mod.Url.parse(text) catch return error.InvalidProxy;
        if (proxy_url.scheme != .http and proxy_url.scheme != .https) return error.InvalidProxy;
        if (proxy_url.host.len == 0) return error.InvalidProxy;
        var proxy: httpclient.Proxy = .{
            .host = proxy_url.host,
            .port = proxy_url.port orelse if (proxy_url.scheme == .https) 443 else 1080,
            .tls = proxy_url.scheme == .https,
        };
        if (proxy_url.user != null) {
            h.proxy_credentials = .{ .gpa = h.gpa, .url = proxy_url };
            const session = &h.proxy_credentials.?;
            if (!session.hasInitial()) {
                const filled = session.fill(h.io, h.credentialOptions()) catch |err| return h.proxyFailed(err);
                if (!filled) return h.fail(error.ProxyAuthenticationFailed, "no password for the proxy");
            }
            if (session.authorization()) |value| proxy.authorization = try arena.dupe(u8, value);
        }
        // curl's CONNECT: the proxy's credential, git's user agent, and a
        // keep-alive the tunnel asks for.
        var lines: std.ArrayList(http.Header) = .empty;
        if (proxy.authorization) |value| try lines.append(arena, .{ .name = "Proxy-Authorization", .value = value });
        try lines.append(arena, .{ .name = "User-Agent", .value = h.user_agent });
        try lines.append(arena, .{ .name = "Proxy-Connection", .value = "Keep-Alive" });
        proxy.connect_headers = lines.items;
        h.client.proxy = proxy;
    }

    fn proxyFailed(h: *Http, err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.ProgramsNotGranted => error.ProgramsNotGranted,
            error.CredentialHelperQuit => error.CredentialHelperQuit,
            error.CredentialsUnavailable => error.CredentialsUnavailable,
            else => h.fail(error.ProxyAuthenticationFailed, @errorName(err)),
        };
    }

    /// The proxy took its credential: the helpers are told, as git tells
    /// them. Once.
    fn approveProxy(h: *Http) Error!void {
        const session = &(h.proxy_credentials orelse return);
        if (session.source != .helper and session.source != .prompt) return;
        session.approve(h.io, h.credentialOptions()) catch |err| return h.proxyFailed(err);
        session.source = .url;
    }

    /// The proxy refused it: the helpers are told to forget it.
    fn rejectProxy(h: *Http) Error {
        if (h.proxy_credentials) |*session| {
            session.reject(h.io, h.credentialOptions()) catch {};
        }
        var buf: [32]u8 = undefined;
        return h.fail(error.ProxyAuthenticationFailed, std.fmt.bufPrint(&buf, "proxy answered {d}", .{h.client.proxy_status orelse 407}) catch "proxy answered 407");
    }

    /// Give back the request in flight, reading what is left of its body
    /// so its connection can carry the next one.
    fn endRequest(h: *Http) void {
        if (h.in_flight) |*res| {
            _ = res.reader().discardRemaining() catch {};
            res.deinit();
            h.in_flight = null;
        }
        if (h.streaming) |*s| {
            s.abort();
            h.streaming = null;
        }
    }

    fn headers(h: *Http, arena: Allocator, method: http.Method, authorization: ?[]const u8, gzipped: bool) Allocator.Error![]const http.Header {
        var list: std.ArrayList(http.Header) = .empty;
        try list.append(arena, .{ .name = "User-Agent", .value = h.user_agent });
        if (authorization) |a| try list.append(arena, .{ .name = "Authorization", .value = a });
        try list.append(arena, .{ .name = "Accept-Encoding", .value = "deflate, gzip" });
        try list.appendSlice(arena, h.extra_headers);
        try list.append(arena, .{ .name = "Pragma", .value = "no-cache" });
        if (method == .POST) {
            try list.append(arena, .{
                .name = "Content-Type",
                .value = try std.fmt.allocPrint(arena, "application/x-{s}-request", .{h.service.name()}),
            });
            try list.append(arena, .{
                .name = "Accept",
                .value = try std.fmt.allocPrint(arena, "application/x-{s}-result", .{h.service.name()}),
            });
            if (gzipped) try list.append(arena, .{ .name = "Content-Encoding", .value = "gzip" });
        }
        return list.items;
    }

    fn credentialOptions(h: *const Http) credential.Options {
        return .{ .config = h.options.config, .programs = h.options.programs, .prompt = h.options.prompt };
    }

    fn fail(h: *Http, err: Error, text: []const u8) Error {
        h.connection.setMessage(text);
        return err;
    }

    /// An error of the HTTP client's, as this module names it.
    fn clientFailed(h: *Http, err: httpclient.Error) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.ConnectionFailed => h.fail(error.ConnectionFailed, "the connection failed"),
            error.TlsFailed => h.fail(error.TlsFailed, if (h.client.tls_error) |e| @errorName(e) else "TLS handshake failed"),
            error.ProxyAuthenticationRequired => h.rejectProxy(),
            error.ProxyRefused => {
                var buf: [32]u8 = undefined;
                return h.fail(error.ProxyRefused, std.fmt.bufPrint(&buf, "proxy answered {d}", .{h.client.proxy_status orelse 0}) catch "proxy refused");
            },
            error.HttpProtocolError => h.fail(error.ProtocolError, "not an HTTP response"),
            error.CertificateBundleUnreadable => h.fail(error.SslCertificateUnreadable, "the system's certificates"),
            // git sets no timeout of these kinds, so none is set here.
            error.TimedOut => h.fail(error.ConnectionFailed, "timed out"),
            error.BodyIncomplete => h.fail(error.ConnectionFailed, "the body was cut short"),
        };
    }

    fn pathFor(h: *Http, suffix: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(h.arena.allocator(), "{s}{s}", .{ h.base_path, suffix });
    }

    /// Send a `GET` and read its head, following redirects as curl does for
    /// git and handling a request for credentials as git's
    /// `http_request_reauth` does: a 401 to a request that carried none
    /// fills one and tries again; a 401 to one that carried one rejects it
    /// and ends there.
    fn get(h: *Http, suffix: []const u8) Error!*httpclient.Response {
        var path = try h.pathFor(suffix);
        var redirects: u8 = 0;
        while (true) {
            h.endRequest();
            const authorization = h.credentials.authorization();
            const list = try h.headers(h.arena.allocator(), .GET, authorization, false);
            h.in_flight = h.client.send(.GET, h.target, path, list, null) catch |err| return h.clientFailed(err);
            const res = &h.in_flight.?;
            if (h.client.proxy != null) try h.approveProxy();
            const status = @intFromEnum(res.head.status);
            if (status == 407) return h.rejectProxy();
            if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) {
                const location = res.head.location orelse return h.fail(error.HttpStatus, "a redirect with no Location");
                redirects += 1;
                if (redirects > 20) return h.fail(error.HttpStatus, "too many redirects");
                path = try h.follow(location, path);
                continue;
            }
            if (res.head.status == .unauthorized) {
                try h.keepChallenges(&res.head);
                const said = try h.serverText(res);
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
            if (res.head.status.class() == .success and authorization != null) {
                try h.credentials.setChallenges(&.{});
                try h.credentials.approve(h.io, h.credentialOptions());
            }
            if (redirects > 0 and res.head.status.class() == .success) try h.rebase(path);
            return res;
        }
    }

    /// Where a redirect leads: the target and path after it, from a
    /// `Location` that is a whole URL or a path.
    fn follow(h: *Http, location: []const u8, from: []const u8) Error![]const u8 {
        const arena = h.arena.allocator();
        if (std.mem.indexOf(u8, location, "://") != null) {
            const text = try arena.dupe(u8, location);
            const to = url_mod.Url.parse(text) catch return h.fail(error.HttpStatus, "a redirect to a URL that does not parse");
            if (to.scheme != .http and to.scheme != .https) return h.fail(error.HttpStatus, "a redirect to another protocol");
            const moved = targetOf(to);
            // A credential goes only where it was given.
            if (!moved.eql(h.target)) {
                h.credentials.deinit();
                h.credentials = .{ .gpa = h.gpa, .url = to };
            }
            h.target = moved;
            return if (to.path.len == 0) "/" else to.path;
        }
        if (location.len != 0 and location[0] == '/') return arena.dupe(u8, location);
        // Relative to the directory of the request that was redirected.
        const dir_end = (std.mem.lastIndexOfScalar(u8, from[0 .. std.mem.indexOfScalar(u8, from, '?') orelse from.len], '/') orelse 0) + 1;
        return std.fmt.allocPrint(arena, "{s}{s}", .{ from[0..dir_end], location });
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
    fn serverText(h: *Http, res: *httpclient.Response) Error![]const u8 {
        const content_type = res.head.content_type orelse return "";
        if (!std.ascii.startsWithIgnoreCase(content_type, "text/plain")) return "";
        const reader = res.reader();
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

    fn checkStatus(h: *Http, res: *httpclient.Response) Error!void {
        const status = @intFromEnum(res.head.status);
        switch (res.head.status) {
            .ok => return,
            .unauthorized, .forbidden => {
                if (res.head.status == .unauthorized) try h.keepChallenges(&res.head);
                const said = try h.serverText(res);
                return h.authFailed(error.AuthenticationFailed, if (status == 403) .forbidden else .refused, status, said);
            },
            .proxy_auth_required => return h.rejectProxy(),
            else => {
                const said = std.mem.trim(u8, try h.serverText(res), " \t\r\n");
                var buf: [32]u8 = undefined;
                const text = if (said.len != 0) said else std.fmt.bufPrint(&buf, "HTTP {d}", .{status}) catch "HTTP";
                return h.fail(if (res.head.status == .not_found) error.RepositoryNotFound else error.HttpStatus, text);
            },
        }
    }

    fn advertisement(context: *anyopaque, _: *Connection) connection.Error!*Io.Reader {
        return self(context).body_reader;
    }

    fn advertisementInner(h: *Http) Error!*Io.Reader {
        var suffix_buf: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "/info/refs?service={s}", .{h.service.name()}) catch unreachable;
        const res = try h.get(suffix);
        try h.checkStatus(res);
        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "application/x-{s}-advertisement", .{h.service.name()}) catch unreachable;
        const content_type = res.head.content_type orelse "";
        if (!std.mem.eql(u8, content_type, expected)) return error.DumbHttpUnsupported;

        const body = res.reader();
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
        return body;
    }

    /// Where the `GET` that was followed ended: its path is the new base,
    /// once `/info/refs` and the query are off it. `RedirectMismatch` when
    /// it does not end so.
    fn rebase(h: *Http, final_path: []const u8) Error!void {
        const without_query = final_path[0 .. std.mem.indexOfScalar(u8, final_path, '?') orelse final_path.len];
        if (!std.mem.endsWith(u8, without_query, "/info/refs")) return error.RedirectMismatch;
        h.base_path = without_query[0 .. without_query.len - "/info/refs".len];
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
        if (h.streaming == null) {
            h.startStreaming() catch |err| {
                h.write_error = err;
                return error.WriteFailed;
            };
        }
        const out = h.streaming.?.writer();
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
        const arena = h.arena.allocator();
        if (h.stream_buffer.len == 0) h.stream_buffer = try arena.alloc(u8, 64 * 1024);
        const list = try h.headers(arena, .POST, h.credentials.authorization(), false);
        h.streaming = h.client.stream(.POST, h.target, try h.pathFor(suffix), list, null, h.stream_buffer) catch |err| return h.clientFailed(err);
    }

    fn response(context: *anyopaque, _: *Connection) connection.Error!*Io.Reader {
        const h = self(context);
        return h.responseInner() catch |err| return narrow(h, err);
    }

    /// git gzips an upload-pack request that fits in one piece and is
    /// larger than a kilobyte; a push's pack is compressed already.
    const gzip_threshold = 1024;

    fn responseInner(h: *Http) Error!*Io.Reader {
        if (h.write_error) |err| return err;
        if (h.streaming) |*s| {
            s.writer().writeAll(h.post.buffered()) catch return h.fail(error.ConnectionFailed, "write failed");
            h.post.end = 0;
            h.in_flight = s.finish() catch |err| {
                h.streaming = null;
                return h.clientFailed(err);
            };
            h.streaming = null;
        } else {
            var suffix_buf: [64]u8 = undefined;
            const suffix = std.fmt.bufPrint(&suffix_buf, "/{s}", .{h.service.name()}) catch unreachable;
            var arena_state: std.heap.ArenaAllocator = .init(h.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var body: []const u8 = h.post.buffered();
            const gzipped = h.service == .upload_pack and body.len > gzip_threshold;
            if (gzipped) body = try gzip(arena, body);
            const list = try h.headers(arena, .POST, h.credentials.authorization(), gzipped);
            h.in_flight = h.client.send(.POST, h.target, try h.pathFor(suffix), list, body) catch |err| return h.clientFailed(err);
            h.post.end = 0;
        }
        const res = &h.in_flight.?;
        try h.checkStatus(res);
        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "application/x-{s}-result", .{h.service.name()}) catch unreachable;
        if (!std.mem.eql(u8, res.head.content_type orelse "", expected)) return h.fail(error.ProtocolError, "unexpected content type");
        h.body_reader = res.reader();
        return h.body_reader;
    }

    fn gzip(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
        var out: Io.Writer.Allocating = try .initCapacity(arena, bytes.len / 2 + 64);
        const window = try arena.alloc(u8, std.compress.flate.max_window_len);
        var compress = std.compress.flate.Compress.init(&out.writer, window, .gzip, .best) catch return error.OutOfMemory;
        compress.writer.writeAll(bytes) catch return error.OutOfMemory;
        compress.writer.flush() catch return error.OutOfMemory;
        compress.finish() catch return error.OutOfMemory;
        return out.written();
    }

    fn failure(context: *anyopaque, c: *Connection) connection.Error {
        const h = self(context);
        if (h.in_flight) |*res| {
            if (res.state.http_reader.body_err) |err| {
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
        if (h.proxy_credentials) |*p| p.deinit();
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
