//! git's smart HTTP protocol, over uplink's HTTP/1.1 client.
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
//! where it led; a redirect of a `POST` is not, whatever the setting, and
//! `false` follows none. A redirect goes only to a transport `policy`
//! allows, and one to another host or port takes no credential with it:
//! not the helpers', and not an `Authorization` or `Cookie` among
//! `http.extraHeader`, which curl does not carry to another host either. A server that answers with
//! a plain file listing — git's dumb protocol — is handed over as `Files`, its
//! listing and every later `GET` through the same settings (`dumb_http`). A
//! request that fits `http.postBuffer` is sent whole, gzipped when it is an
//! upload-pack request over a kilobyte, as git sends it; a larger one is
//! sent in chunks as it is written. Connections are kept between requests.
//!
//! `https://` is TLS from uplink's client, against the system's root
//! certificates, or against `http.sslCAInfo` in their place and
//! `http.sslCAPath` besides — a company's own authority, a self-hosted
//! server's — or against nothing at all when `http.sslVerify` is false,
//! which is then returned as a warning. That check needs the time, which
//! uplink reads. The settings are git's, scoped by
//! `http.<url>.*` and overridden by git's environment variables
//! (`http_settings.zig`), and a proxy is `http.proxy` or the one curl would
//! find in the environment: an `https` URL goes through it in a `CONNECT`
//! tunnel with TLS inside, an `http` one as a whole URL. A proxy's
//! credentials are the ones its URL carries, a username there with the
//! password from the person's helpers, as git fills them. Client certificates
//! come from `http.sslCert` and `http.sslKey`, or `http.proxySSLCert` and
//! `http.proxySSLKey` for an https proxy, and uplink presents them.
//!
//! The rest of a transfer is git's too: `http.cookieFile`'s cookies are
//! sent and, under `http.saveCookies`, written back when the conversation
//! ends; `http.lowSpeedLimit` over `http.lowSpeedTime` gives up on a
//! transfer that has slowed to a crawl; a 429 to the advertisement is
//! tried again as `http.maxRetries`, `http.retryAfter` and
//! `http.maxRetryTime` say; `http.version` keeps HTTP/1.1, or speaks HTTP/2
//! where TLS agrees it or a plain server takes `Upgrade: h2c`.
//! `http.sslVersion` is the lowest TLS version spoken with the server, and
//! `http.pinnedPubkey` the keys its certificate may hold (`pinned_key.zig`),
//! with nothing else checked under `http.sslVerify=false`, both as curl
//! holds the server to them for git.

const Self = @This();

const std = @import("std");
const warp = @import("warp");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const config_mod = @import("../config/config.zig");
const fs = @import("../fs/fs.zig");
const program = @import("../process.zig").program;
const pkt_line = @import("../codec.zig").pkt_line;
const url_mod = @import("url.zig");
const connection = @import("connection.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const http_settings = @import("http_settings.zig");
const Seconds = http_settings.Seconds;
const decimal = @import("../text.zig").decimal;
const date = @import("../text.zig").date;
const policy = @import("policy.zig");
const client_cert = @import("client_cert.zig");

/// The most a dumb server's file is read to: the `info/refs` listing,
/// `HEAD`, `objects/info/packs`, an alternates file or a pack index. git
/// reads each whole however long it is; past this one is
/// `DumbHttpFileTooLarge`, the size relic opens a pack index to.
pub const max_dumb_file_bytes: usize = 1 << 30;
const authorities = @import("authorities.zig");
const pinned_key = @import("pinned_key.zig");
const uplink = @import("uplink");
const cloak = @import("cloak");
const aegis = @import("aegis");
/// Whether relic was built with HTTP: the `http` build option.
const http_enabled = @import("relic_options").http;
const warning = @import("../report.zig").warning;

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
    /// The server speaks git's dumb HTTP protocol, a listing of files, to
    /// a service that has no dumb form: an archive.
    DumbHttpUnsupported,
    /// A push to a server that speaks git's dumb HTTP protocol, which git
    /// makes over WebDAV (`http-push`): nobody in the family serves one.
    DumbHttpPushUnsupported,
    /// A dumb server's file past `max_dumb_file_bytes`.
    DumbHttpFileTooLarge,
    /// The server asked for a client certificate and refused the one it
    /// was sent — or wanted one and was sent none. `Connection.message`
    /// names its TLS alert.
    ClientCertificateRejected,
    /// The server asked for a client certificate in signature schemes the
    /// key does not sign with.
    ClientCertificateSchemeUnsupported,
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
    /// A redirect led to a transport `policy` does not allow.
    TransportNotAllowed,
    /// A proxy the configuration or the environment names that does not
    /// parse.
    InvalidProxy,
    /// The proxy refused the credentials it was given, or wanted some and
    /// had none: status 407.
    ProxyAuthenticationFailed,
    /// The proxy refused the tunnel for another reason.
    ProxyRefused,
    /// `http.proxyAuthMethod` names a scheme relic does not answer with:
    /// negotiate, ntlm; or the proxy asks only in such a scheme.
    ProxyAuthMethodUnsupported,
    /// A SOCKS proxy could not reach the server, or a name it was to look
    /// up: `Connection.message` holds its reply code.
    ProxyHostUnreachable,
    /// A SOCKS4 proxy, which carries no IPv6 address, and a server that has
    /// only one.
    ProxyAddressUnsupported,
    /// A proxy's answer that is neither SOCKS nor HTTP.
    ProxyProtocolError,
    /// A URL no request can carry: a space or a control character in its
    /// path, which curl refuses too.
    MalformedUrl,
    /// relic was built without HTTP: its `http` build option is off.
    HttpUnavailable,
    /// The server answered 429 to every request `http.maxRetries` allows,
    /// or asked for a longer wait than `http.maxRetryTime`, or
    /// `http.retryAfter` is longer than it: `Connection.message` says which,
    /// as git says it.
    RateLimited,
    /// `http.sslVersion` names SSL 2 or 3, which curl's TLS libraries no
    /// longer speak and git fails on.
    SslVersionUnsupported,
    /// The server's key is none `http.pinnedPubkey` names: curl's
    /// `CURLE_SSL_PINNEDPUBKEYNOTMATCH`, its message curl's.
    PinnedPubkeyMismatch,
} || connection.Error || credential.Error || client_cert.Error;

/// How the conversation is made.
pub const Options = struct {
    /// The repository's configuration, for the `http.*` settings.
    config: ?*const config_mod.Config = null,
    /// The configured remote, for `remote.<name>.proxy`.
    remote_name: ?[]const u8 = null,
    /// Where a relative path setting is found from: `http_settings.Sources.base`.
    base: ?Io.Dir = null,
    /// The proxy, over the one `remote_name` and the settings choose.
    proxy: http_settings.Proxy = .auto,
    /// The permission to run credential helpers and `askpass`; its
    /// environment is also where `http_proxy`, `https_proxy`, `all_proxy`
    /// and `GIT_ASKPASS` are read.
    programs: ?program.Programs = null,
    /// Ask an upload-pack for protocol v2.
    protocol_v2: bool = true,
    /// Answers the credential prompt git would show on a terminal, when no
    /// helper has the answer. Without it nothing is asked.
    prompt: ?credential.Prompt = null,
    /// The caller's time, for a credential's expiry: `credential.Options.now`.
    now: ?std.Io.Timestamp = null,
    /// Filled in when the conversation fails for want of a credential.
    auth_failure: ?*auth.Failure = null,
    /// Whether the person named the remote: `policy.allowed`'s, for where
    /// a redirect leads.
    from_user: ?bool = null,
    /// Where what git would print as a warning goes: certificate checks
    /// turned off.
    warnings: ?*warning.Warnings = null,
};

/// What the client calls itself. A server that treats git specially looks
/// for the `git/` in front.
pub const user_agent = "git/2.0 (relic 0.3)";

/// What the first request found: a smart server's conversation, or a
/// dumb server's files.
pub const Opened = union(enum) {
    pub const Error = Self.Error;

    smart: *Connection,
    dumb: Files,
};

/// Open a conversation with the service at `url`: smart HTTP, or for
/// upload-pack a dumb server's files, as git's `check_smart_http` tells
/// them apart.
pub fn connect(gpa: Allocator, io: Io, url: url_mod.Url, service: Service, options: Options) Self.Error!Opened {
    if (comptime !http_enabled) return error.HttpUnavailable;
    const h = try prepare(gpa, io, url, service, options);
    errdefer Http.deinit(io, h);
    // The advertisement is asked for here, so that what can go wrong with
    // the first request — a credential refused, no repository, a dumb
    // server to push to — is refused by its own name.
    switch (try h.advertisementInner()) {
        .smart => return .{ .smart = &h.connection },
        .dumb => |listing| switch (service) {
            .upload_pack => return .{ .dumb = .{ .h = h, .listing = listing } },
            .receive_pack => return error.DumbHttpPushUnsupported,
            .upload_archive => return error.DumbHttpUnsupported,
        },
    }
}

/// A dumb server's files, asked for through the conversation that found
/// it: its settings, credentials, proxy and TLS. A redirect is followed
/// only under `http.followRedirects=true`, as git's `initial` follows the
/// first request alone.
pub const Files = struct {
    pub const Error = Self.Error;

    h: *Http,
    /// `info/refs` as the server sent it; the files' own.
    listing: []const u8,

    /// The files under `url`, with no request made: an alternate a dumb
    /// server names, asked as its own repository is.
    pub fn open(gpa: Allocator, io: Io, url: url_mod.Url, options: Options) Self.Error!Files {
        if (comptime !http_enabled) return error.HttpUnavailable;
        var plain = options;
        plain.protocol_v2 = false;
        const h = try prepare(gpa, io, url, .upload_pack, plain);
        h.downloading = true;
        h.base_path = std.mem.trimEnd(u8, url.path, "/");
        return .{ .h = h, .listing = "" };
    }

    pub fn deinit(f: *Files, io: Io) void {
        Http.deinit(io, f.h);
        f.* = undefined;
    }

    /// `GET` of `suffix` under the repository, which begins with `/`: its
    /// body, read until the next `get`, or `null` for a 404, git's
    /// missing target. Any other status is refused as the conversation
    /// refuses it.
    pub fn get(f: *Files, suffix: []const u8) Self.Error!?*Io.Reader {
        const h = f.h;
        const res = try h.get(suffix);
        if (res.status == .not_found) return null;
        try h.checkStatus(res);
        return res.readerBuffered(h.io, h.body_buffer);
    }

    /// The repository's URL, where the first request's redirect led, in
    /// `arena`.
    pub fn baseUrl(f: *const Files, arena: Allocator) Allocator.Error![]const u8 {
        return f.h.origin.join(arena, f.h.base_path);
    }

    /// What failed last, in words: a status, a reason.
    pub fn message(f: *const Files) []const u8 {
        return f.h.connection.message();
    }
};

/// One `GET` of `url`, its body written to `w`: what git-remote-https's
/// `get` does for a bundle URI. git's `http.*` settings for the URL hold
/// and its credentials are asked for on a 401, as for a conversation; a
/// redirect is followed only under `http.followRedirects=true`, since
/// `initial` follows a conversation's first request and a download is
/// none. Any status but 200 is `HttpStatus`, as the helper's `get` fails.
pub fn download(gpa: Allocator, io: Io, w: *Io.Writer, url: url_mod.Url, options: Options) (Self.Error || Io.Writer.Error)!void {
    if (comptime !http_enabled) return error.HttpUnavailable;
    var plain = options;
    plain.protocol_v2 = false;
    const h = try prepare(gpa, io, url, .upload_pack, plain);
    defer Http.deinit(io, h);
    h.downloading = true;
    h.base_path = url.path;
    const res = try h.get("");
    if (res.status != .ok) return error.HttpStatus;
    const body = res.reader(io);
    _ = body.streamRemaining(w) catch |err| return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.ReadFailed => h.fail(error.ConnectionFailed, "the body was cut short"),
    };
}

/// The conversation's state, its client configured, before any request.
fn prepare(gpa: Allocator, io: Io, url: url_mod.Url, service: Service, options: Options) Self.Error!*Http {
    const h = try gpa.create(Http);
    errdefer gpa.destroy(h);
    h.* = .{
        .gpa = gpa,
        .io = io,
        .arena = .init(gpa),
        .client = undefined,
        .origin = undefined,
        .base_path = undefined,
        .service = service,
        .v2 = options.protocol_v2 and service == .upload_pack,
        .options = options,
        .post_buffer = undefined,
        .post = undefined,
        .body_buffer = undefined,
        .connection = .{ .context = h, .vtable = &Http.vtable, .stateless = true },
        .credentials = .{ .gpa = gpa, .url = url },
    };
    errdefer h.arena.deinit();
    errdefer h.credentials.deinit();
    errdefer if (h.proxy_credentials) |*p| p.deinit();
    errdefer if (h.proxy_secret) |*p| p.deinit();
    errdefer h.freeTls();

    const configured = try h.configure(url);
    // The client points at the authorities and certificates `configure`
    // keeps in `h`, which outlive it.
    h.client = .init(gpa, configured.client);
    errdefer h.client.deinit(io);
    errdefer h.endRequest();
    const settings = configured.settings;
    h.post_buffer = try h.arena.allocator().alloc(u8, (settings.post_buffer.convert(usize) catch return error.OutOfMemory).raw());
    h.body_buffer = try h.arena.allocator().alloc(u8, pkt_line.max_line);
    h.post = .{ .vtable = &.{ .drain = Http.drainPost }, .buffer = h.post_buffer };
    return h;
}

/// Where requests go: a scheme, a host and a port.
const Origin = struct {
    secure: bool,
    host: []const u8,
    port: u16,

    fn of(url: url_mod.Url) Origin {
        return .{
            .secure = url.scheme == .https,
            .host = url.host,
            .port = url.port orelse if (url.scheme == .https) 443 else 80,
        };
    }

    fn eql(a: Origin, b: Origin) bool {
        return a.secure == b.secure and a.port == b.port and std.ascii.eqlIgnoreCase(a.host, b.host);
    }

    /// The URL of `path` here, in `arena`.
    fn join(o: Origin, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
        const scheme = if (o.secure) "https" else "http";
        const v6 = std.mem.findScalar(u8, o.host, ':') != null;
        const open = if (v6) "[" else "";
        const shut = if (v6) "]" else "";
        if (o.port == @as(u16, if (o.secure) 443 else 80)) return arena.print("{s}://{s}{s}{s}{s}", .{ scheme, open, o.host, shut, path });
        return arena.print("{s}://{s}{s}{s}:{d}{s}", .{ scheme, open, o.host, shut, o.port, path });
    }
};

const Http = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    client: uplink.Client,
    /// Why the exchange under way failed, in detail.
    diagnostics: uplink.Diagnostics = .{},
    /// Where the repository is, and the path of its URL without a
    /// trailing slash; a redirect of the first request moves both.
    origin: Origin,
    base_path: []const u8,
    service: Service,
    v2: bool,
    options: Options,
    /// `http.extraHeader`, and the ones the protocol adds.
    extra_headers: []const http.Header = &.{},
    /// `http.userAgent`, or relic's own.
    user_agent: []const u8 = user_agent,
    /// `http.followRedirects`.
    follow_redirects: http_settings.FollowRedirects = .initial,
    /// A lone `GET` (`download`), not a conversation: its redirects are
    /// followed only when every request's are.
    downloading: bool = false,
    /// Whether requests go through a proxy.
    proxied: bool = false,
    in_flight: ?uplink.Response = null,
    streaming: ?uplink.Outgoing = null,
    post_buffer: []u8,
    post: Io.Writer,
    /// What a response's body is read through: room for the longest
    /// pkt-line, which is read whole where it lies.
    body_buffer: []u8,
    body_reader: *Io.Reader = undefined,
    connection: Connection,
    credentials: credential.Session,
    /// The proxy's credential, when its URL names a user.
    proxy_credentials: ?credential.Session = null,
    /// The user and password the proxy is answered with, which the
    /// client's proxy borrows until it is let go.
    proxy_secret: ?aegis.SecretBytes = null,
    /// `http.sslCAInfo` and `http.sslCAPath`, when they name authorities;
    /// `http.proxySSLCAInfo`, when it does.
    trust: ?cloak.Trust.Snapshot = null,
    proxy_trust: ?cloak.Trust.Snapshot = null,
    /// `http.sslCert` and its key, and the passphrase's credential when
    /// `http.sslCertPasswordProtected` asks for one.
    client_auth: ?cloak.ClientAuth = null,
    cert_credentials: ?credential.Session = null,
    /// The same for an `https` proxy.
    proxy_client_auth: ?cloak.ClientAuth = null,
    proxy_cert_credentials: ?credential.Session = null,
    /// A failure met inside a writer, which can only say that it failed.
    write_error: ?Error = null,
    /// `http.cookieFile`'s cookies, sent and kept by the client; written
    /// back to `cookie_jar_file` when the conversation ends, as curl
    /// writes its jar for git's `http.saveCookies`.
    cookies: ?uplink.CookieJar = null,
    cookie_jar_file: ?[]const u8 = null,
    /// How a 429 is answered: `http.retryAfter`, `http.maxRetries`,
    /// `http.maxRetryTime`.
    rate_limit: RateLimit = .{},

    /// git's answer to a 429, in time and attempts.
    const RateLimit = struct {
        retry_after: Seconds = .fromRaw(0),
        max_retries: i64 = 0,
        max_retry_time: Seconds = .fromRaw(300),
    };

    /// What `configure` read: the settings, and the client they make.
    const Configured = struct {
        settings: http_settings.Settings,
        client: uplink.Client.Options,
    };

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .deinit = deinit,
    };

    fn self(context: *anyopaque) *Http {
        return @ptrCast(@alignCast(context)); // aegis: no-danger: the context handed out with this vtable is an Http
    }

    /// The settings, and the client they make: certificates to trust
    /// loaded, checks turned off where git's settings say so, the extra
    /// headers read, and a proxy set up.
    fn configure(h: *Http, url: url_mod.Url) Error!Configured {
        const arena = h.arena.allocator();
        h.origin = .of(url);
        var path = url.path;
        while (path.len != 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        h.base_path = path;

        const environ: ?*const std.process.Environ.Map = if (h.options.programs) |p| p.environ else null;
        var settings = try http_settings.resolve(arena, h.io, url, .{ .config = h.options.config, .environ = environ, .remote_name = h.options.remote_name, .base = h.options.base });
        http_settings.chooseProxy(&settings, h.options.proxy);
        var tls_options: uplink.tls.ClientOptions = .{};
        if (url.scheme == .https) {
            tls_options.min_version = try h.sslVersion(settings.ssl_version);
            // Under `http.sslVerify=false` the pins are checked alone,
            // the leaf's key and nothing else, as curl checks them.
            if (settings.pinned_pubkey) |value| {
                tls_options.pins = try pinned_key.read(arena, h.io, value);
                // No key that can match fails every handshake, as curl
                // fails it: refused here.
                if (tls_options.pins.len == 0) return h.fail(error.PinnedPubkeyMismatch, pin_mismatch);
            }
            if (settings.ssl_cert) |cert| {
                h.client_auth = try h.clientCertificate(.{
                    .cert = cert,
                    .key = settings.ssl_key,
                    .cert_format = client_cert.Format.parse(settings.ssl_cert_type) catch return h.fail(error.SslCertTypeUnsupported, "http.sslCertType"),
                    .key_format = client_cert.Format.parse(settings.ssl_key_type) catch return h.fail(error.SslCertTypeUnsupported, "http.sslKeyType"),
                }, settings.ssl_cert_password_protected, &h.cert_credentials);
                tls_options.client_auth = h.client_auth;
            }
            if (!settings.ssl_verify) {
                tls_options.verify = .none;
                try warning.note(h.options.warnings, .{ .ssl_verify_disabled = settings.ssl_verify_from orelse "http.sslVerify" });
            } else if (settings.ca_info != null or settings.ca_path != null) {
                try h.trustAuthorities(settings);
                tls_options.trust = h.trust;
            }
        }

        var extra: std.ArrayList(http.Header) = .empty;
        for (settings.extra_headers) |text| {
            const colon = std.mem.findScalar(u8, text, ':') orelse return error.InvalidHttpHeader;
            const name = std.mem.trim(u8, text[0..colon], " \t");
            const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
            // A field that is not one would not be sent: refused here, by
            // the setting's name.
            if (!uplink.wire.fields.isToken(name) or !uplink.wire.fields.isFieldValue(value)) return h.fail(error.InvalidHttpHeader, "http.extraHeader");
            try extra.append(arena, .{ .name = name, .value = value });
        }
        if (h.v2) try extra.append(arena, .{ .name = "Git-Protocol", .value = "version=2" });
        h.extra_headers = try extra.toOwnedSlice(arena);
        if (settings.user_agent) |agent| {
            if (!uplink.wire.fields.isFieldValue(agent)) return h.fail(error.InvalidHttpHeader, "http.userAgent");
            h.user_agent = agent;
        }
        h.follow_redirects = settings.follow_redirects;

        var proxy: ?uplink.Proxy = null;
        if (settings.proxy) |text| proxy = try h.configureProxy(text, settings.proxy_auth_method);
        if (proxy) |*p| if (p.kind == .https) {
            // curl checks an https proxy on its own terms: always, against
            // `http.proxySSLCAInfo` or the system's authorities.
            if (settings.proxy_ssl_ca_info) |file| {
                var failed: authorities.Failed = undefined;
                h.proxy_trust = authorities.load(h.gpa, h.io, .{ .ca_info = file }, &failed) catch |err| return switch (err) {
                    error.SslCertificateUnreadable => h.fail(error.SslCertificateUnreadable, "http.proxySSLCAInfo"),
                    else => |e| e,
                };
                p.tls.trust = .{ .own = h.proxy_trust };
            } else p.tls.trust = .{ .own = null };
            if (settings.proxy_ssl_cert) |cert| {
                h.proxy_client_auth = try h.clientCertificate(.{
                    .cert = cert,
                    .key = settings.proxy_ssl_key,
                }, settings.proxy_ssl_cert_password_protected, &h.proxy_cert_credentials);
                p.tls.client_auth = h.proxy_client_auth;
            }
        };
        h.proxied = proxy != null;

        for (settings.env_unparsed) |name| try warning.note(h.options.warnings, .{ .http_env_unparsed = name });
        try h.loadCookies(settings);
        h.rate_limit = .{ .retry_after = settings.retry_after, .max_retries = settings.max_retries, .max_retry_time = settings.max_retry_time };
        var timeouts: uplink.Timeouts = .{};
        // git's `get_curl_handle`: both above zero, or neither applies.
        if (settings.low_speed_limit > 0 and settings.low_speed_time.compare(.fromRaw(0)) == .gt) timeouts.low_speed = .{
            .bytes_per_second = std.math.cast(u32, settings.low_speed_limit) orelse std.math.maxInt(u32),
            .window = settings.low_speed_time.convert(.nanosecond, u64, .exact) catch .fromRaw(std.math.maxInt(u64)),
        };
        return .{
            .settings = settings,
            .client = .{
                .proxy = if (proxy) |p| .{ .fixed = p } else .none,
                .tls = tls_options,
                .timeouts = timeouts,
                .http2 = try h.httpVersion(settings.http_version),
                .cookies = if (h.cookies) |*jar| jar else null,
                // One connection kept, as curl keeps one for git.
                .pool = .{ .max_idle_per_route = 1, .max_idle = 1 },
                // git's redirects and retries are its own, decided here:
                // a 429 is tried again beside a 401, in one loop, as
                // git's `http_request_recoverable` does.
                .redirects = .none,
                .retries = .none,
            },
        };
    }

    /// `http.version` as git's `get_curl_http_version_opt` reads it:
    /// `HTTP/1.1` alone, or `HTTP/2`, curl's `CURL_HTTP_VERSION_2_0`: agreed
    /// over TLS, and over plain HTTP asked for by `Upgrade: h2c`. Unset, or
    /// another value (warned of), is curl's default, HTTP/2 where TLS
    /// agrees it and HTTP/1.1 over plain HTTP.
    fn httpVersion(h: *Http, value: ?[]const u8) Error!@FieldType(uplink.Client.Options, "http2") {
        const text = value orelse return .negotiate;
        if (std.mem.eql(u8, text, "HTTP/1.1")) return .off;
        if (std.mem.eql(u8, text, "HTTP/2")) return .upgrade;
        try warning.note(h.options.warnings, .{ .http_version_unknown = text });
        return .negotiate;
    }

    /// The lowest TLS version `http.sslVersion` or `GIT_SSL_VERSION` lets
    /// the server speak, as curl takes it for git: `tlsv1` to `tlsv1.2`
    /// allow what relic speaks, TLS 1.2 and 1.3, and `tlsv1.3` TLS 1.3
    /// alone; SSL 2 and 3 are not built into curl's TLS libraries, and git
    /// fails on them. A name curl does not have is warned of, as git warns,
    /// and the default kept.
    fn sslVersion(h: *Http, value: ?[]const u8) Error!cloak.tls.Version {
        const text = value orelse return .tls12;
        if (text.len == 0) return .tls12;
        const allowed = [_][]const u8{ "tlsv1", "tlsv1.0", "tlsv1.1", "tlsv1.2" };
        for (allowed) |name| if (std.mem.eql(u8, text, name)) return .tls12;
        if (std.mem.eql(u8, text, "tlsv1.3")) return .tls13;
        if (std.mem.eql(u8, text, "sslv2") or std.mem.eql(u8, text, "sslv3")) {
            return h.fail(error.SslVersionUnsupported, text);
        }
        try warning.note(h.options.warnings, .{ .ssl_version_unknown = text });
        return .tls12;
    }

    /// `http.cookieFile` read into the client's jar, as curl reads it for
    /// git, and kept to be written back when `http.saveCookies` says so.
    /// `-` (curl's standard input) git refuses with a warning, as it
    /// refuses saving to an empty name. A file that cannot be read gives
    /// no cookies, as curl reads none from it.
    fn loadCookies(h: *Http, settings: http_settings.Settings) Error!void {
        var file = settings.cookie_file;
        if (file) |f| if (std.mem.eql(u8, f, "-")) {
            try warning.note(h.options.warnings, .cookie_file_stdin);
            file = null;
        };
        if (settings.save_cookies and (file == null or file.?.len == 0)) {
            try warning.note(h.options.warnings, .save_cookies_without_file);
        } else if (settings.save_cookies) h.cookie_jar_file = file;
        // curl turns its cookie engine on for any name, an empty one too.
        if (file == null) return;
        h.cookies = .init(h.gpa, .{});
        if (file.?.len == 0) return;
        const opened = Io.Dir.cwd().openFile(h.io, file.?, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        defer opened.close(h.io);
        var buffer: [8192]u8 = undefined;
        var reader = opened.reader(h.io, &buffer);
        h.cookies.?.load(h.io, &reader.interface) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // curl skips a line too long for its buffer, and stops at a
            // failed read with what it has.
            error.ReadFailed, error.StreamTooLong => {},
        };
    }

    /// Write the jar to `http.cookieFile`, as curl writes its cookie jar
    /// when git cleans up: every cookie that has not expired, those of the
    /// session included. A file that cannot be written is left, as curl
    /// leaves it.
    /// The jar written, as curl writes it when its handle is let go, under
    /// cancel protection: a cancel waits for the caller's next cancelation
    /// point, where it would have been lost with the write's error.
    fn saveCookies(h: *Http, io: Io) void {
        const path = h.cookie_jar_file orelse return;
        const jar = &(h.cookies orelse return);
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        var out: Io.Writer.Allocating = .init(h.gpa);
        defer out.deinit();
        jar.save(io, &out.writer, .{ .session = true }) catch return;
        fs.atomicWrite(io, Io.Dir.cwd(), path, out.written(), .{ .prefix = ".cookies-" }) catch return;
    }

    /// Read a client certificate and its key, as curl reads them for git.
    /// With `ask`, the passphrase is filled first — `protocol=cert`, the
    /// certificate's path — as git's `has_cert_password` fills it whether
    /// the key is encrypted or not. A certificate file that holds no
    /// certificate then has its passphrase rejected, as git rejects it on
    /// `CURLE_SSL_CERTPROBLEM`; a key that does not load keeps it, as curl
    /// 8.17 and later name that `CURLE_BAD_FUNCTION_ARGUMENT`, on which git
    /// rejects nothing.
    fn clientCertificate(h: *Http, files: client_cert.Files, ask: bool, session_slot: *?credential.Session) Error!cloak.ClientAuth {
        var passphrase: ?[]const u8 = null;
        if (ask) {
            session_slot.* = .forCertificate(h.gpa, files.cert);
            const session = &session_slot.*.?;
            if (try session.fill(h.io, h.credentialOptions())) passphrase = session.exposePassword();
        }
        return client_cert.load(h.gpa, h.io, files, .{ .passphrase = passphrase }) catch |err| {
            if (err == error.SslClientCertificateUnreadable) {
                if (session_slot.*) |*session| try forgetRefused(h.io, session, h.credentialOptions());
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                error.SslClientKeyUnreadable, error.SslClientKeyPassphraseRequired, error.SslClientKeyPassphraseWrong => h.fail(err, client_cert.keyPath(files)),
                else => h.fail(err, files.cert),
            };
        };
    }

    /// The certificate's passphrase worked: the helpers are told, once, as
    /// git tells them after a request that succeeds. The proxy's is not,
    /// as git does not.
    fn approveCertificate(h: *Http) Error!void {
        const session = &(h.cert_credentials orelse return);
        if (session.source != .helper and session.source != .prompt) return;
        try session.approve(h.io, h.credentialOptions());
        session.source = .url;
    }

    /// Free the authorities and certificates, which the client must no
    /// longer use.
    fn freeTls(h: *Http) void {
        if (h.trust) |t| t.deinit();
        if (h.proxy_trust) |t| t.deinit();
        if (h.client_auth) |a| a.deinit();
        if (h.proxy_client_auth) |a| a.deinit();
        if (h.cert_credentials) |*s| s.deinit();
        if (h.proxy_cert_credentials) |*s| s.deinit();
        h.trust = null;
        h.proxy_trust = null;
        h.client_auth = null;
        h.proxy_client_auth = null;
        h.cert_credentials = null;
        h.proxy_cert_credentials = null;
    }

    /// Trust `http.sslCAInfo` in place of the system's certificates, and
    /// `http.sslCAPath` besides them, as curl does for git.
    fn trustAuthorities(h: *Http, settings: http_settings.Settings) Error!void {
        // Configured paths come interpolated, as git's `git_config_pathname`
        // gives them; the environment's are used as they are.
        const sources: authorities.Sources = .{ .ca_info = settings.ca_info, .ca_path = settings.ca_path };
        var failed: authorities.Failed = undefined;
        h.trust = authorities.load(h.gpa, h.io, sources, &failed) catch |err| return switch (err) {
            error.SslCertificateUnreadable => h.fail(error.SslCertificateUnreadable, switch (failed) {
                .ca_info => settings.ca_info_from orelse "http.sslCAInfo",
                .system => "the system's certificates",
                .ca_path => "http.sslCAPath",
            }),
            else => |e| e,
        };
    }

    /// The proxy, and its credential: the user and password its URL
    /// carries, or a user there and the password from the person's helpers,
    /// as git's `init_curl_proxy_auth` fills it.
    fn configureProxy(h: *Http, raw: []const u8, method_name: []const u8) Error!uplink.Proxy {
        const arena = h.arena.allocator();
        var proxy = uplink.Proxy.parseKept(h.gpa, arena, &h.proxy_secret, raw, .lowercase) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidProxy => error.InvalidProxy,
        };
        if (proxy.kind.socks()) return proxy;
        // git's `http.proxyAuthMethod`: anyauth, basic, digest; negotiate
        // and ntlm need the system's security library; anything else git
        // warns of and treats as anyauth.
        const method: uplink.wire.auth.Method = if (std.ascii.eqlIgnoreCase(method_name, "anyauth"))
            .any
        else if (std.ascii.eqlIgnoreCase(method_name, "basic"))
            .basic
        else if (std.ascii.eqlIgnoreCase(method_name, "digest"))
            .digest
        else if (std.ascii.eqlIgnoreCase(method_name, "negotiate") or std.ascii.eqlIgnoreCase(method_name, "ntlm"))
            return h.fail(error.ProxyAuthMethodUnsupported, method_name)
        else blk: {
            try warning.note(h.options.warnings, .{ .proxy_auth_method_unknown = method_name });
            break :blk .any;
        };
        const text = if (std.mem.find(u8, raw, "://") == null) try arena.print("http://{s}", .{raw}) else raw;
        const proxy_url = url_mod.Url.parse(text) catch return error.InvalidProxy;
        if (proxy_url.user != null) {
            h.proxy_credentials = .{ .gpa = h.gpa, .url = proxy_url };
            const session = &h.proxy_credentials.?;
            if (!session.hasInitial()) {
                const filled = session.fill(h.io, h.credentialOptions()) catch |err| return h.proxyFailed(err);
                if (!filled) return h.fail(error.ProxyAuthenticationFailed, "no password for the proxy");
            }
            const user = session.username orelse "";
            const password = session.exposePassword() orelse "";
            var kept = try aegis.SecretBytes.init(h.gpa, user.len + password.len);
            // aegis: no-danger: the owner was made with exactly this capacity.
            kept.resizeWithinCapacity(user.len + password.len) catch unreachable;
            const bytes = kept.exposeMut();
            @memcpy(bytes[0..user.len], user);
            @memcpy(bytes[user.len..], password);
            if (h.proxy_secret) |*old| old.deinit();
            h.proxy_secret = kept;
            proxy.credential = .{ .user = bytes[0..user.len], .password = bytes[user.len..], .method = method };
        }
        // curl's CONNECT: the answer to the proxy, git's user agent, and a
        // keep-alive the tunnel asks for.
        proxy.connect_headers = try arena.dupe(http.Header, &.{
            .{ .name = "Proxy-Authorization", .value = "" },
            .{ .name = "User-Agent", .value = h.user_agent },
            .{ .name = "Proxy-Connection", .value = "Keep-Alive" },
        });
        return proxy;
    }

    fn proxyFailed(h: *Http, err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.ProgramsNotGranted => error.ProgramsNotGranted,
            error.CredentialHelperQuit => error.CredentialHelperQuit,
            error.CredentialsUnavailable => error.CredentialsUnavailable,
            error.CredentialValueUnsafe => error.CredentialValueUnsafe,
            error.InvalidCredentialSetting => error.InvalidCredentialSetting,
            error.InvalidCredentialAnswer => error.InvalidCredentialAnswer,
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
        if (h.proxy_credentials) |*session| try forgetRefused(h.io, session, h.credentialOptions());
        var buf: [32]u8 = undefined;
        return h.fail(error.ProxyAuthenticationFailed, std.mem.print(&buf, "proxy answered {d}", .{h.diagnostics.proxy_status orelse 407}) catch "proxy answered 407");
    }

    /// Tell the helpers to forget a refused credential, which is forgotten
    /// here whatever they say. git fails nothing over a helper that cannot
    /// forget, so only a cancellation, or memory running out, ends the
    /// operation.
    fn forgetRefused(io: Io, session: *credential.Session, options: credential.Options) error{ OutOfMemory, Canceled }!void {
        session.reject(io, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => {},
        };
    }

    /// Give back the request in flight, reading what is left of its body
    /// so its connection can carry the next one. A body left unread costs
    /// only the connection, which deinit keeps only when the response is
    /// complete; a cancel that lands in the reading is put back for the
    /// caller's next cancelation point.
    fn endRequest(h: *Http) void {
        if (h.in_flight) |*res| {
            _ = res.reader(h.io).discardRemaining() catch {
                if (res.failure() == error.Canceled) h.io.recancel();
            };
            res.deinit(h.io);
            h.in_flight = null;
        }
        if (h.streaming) |*s| {
            s.deinit(h.io);
            h.streaming = null;
        }
    }

    fn headers(h: *Http, arena: Allocator, post: bool, authorization: ?[]const u8, gzipped: bool) Allocator.Error![]const http.Header {
        var list: std.ArrayList(http.Header) = .empty;
        try list.append(arena, .{ .name = "User-Agent", .value = h.user_agent });
        if (authorization) |a| try list.append(arena, .{ .name = "Authorization", .value = a });
        try list.append(arena, .{ .name = "Accept-Encoding", .value = "deflate, gzip" });
        try list.appendSlice(arena, h.extra_headers);
        try list.append(arena, .{ .name = "Pragma", .value = "no-cache" });
        if (post) {
            try list.append(arena, .{
                .name = "Content-Type",
                .value = try arena.print("application/x-{s}-request", .{h.service.name()}),
            });
            try list.append(arena, .{
                .name = "Accept",
                .value = try arena.print("application/x-{s}-result", .{h.service.name()}),
            });
            if (gzipped) try list.append(arena, .{ .name = "Content-Encoding", .value = "gzip" });
        }
        return list.items;
    }

    fn credentialOptions(h: *const Http) credential.Options {
        return .{ .config = h.options.config, .programs = h.options.programs, .prompt = h.options.prompt, .now = h.options.now };
    }

    /// curl's words for a server key no pin names.
    const pin_mismatch = "SSL: public key does not match pinned public key";

    /// Whether the handshake failed on a pin: the chain verified and its key
    /// is none pinned, or, with nothing else checked, the leaf's is none.
    fn pinRefused(d: *const uplink.Diagnostics) bool {
        if (d.tls_verification) |e| if (e == error.PinMismatch) return true;
        if (d.tls_error) |e| if (e == error.PinMismatch) return true;
        return false;
    }

    fn fail(h: *Http, err: Error, text: []const u8) Error {
        h.connection.setMessage(text);
        return err;
    }

    /// What the client can fail with: a request, or the end of one whose
    /// body was written as it came.
    const ClientError = uplink.Client.SendError || uplink.Outgoing.FinishError;

    /// An error of the HTTP client's, as this module names it.
    fn clientFailed(h: *Http, err: ClientError) Error {
        const d = &h.diagnostics;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.ConnectionFailed => {
                var buf: [48]u8 = undefined;
                return h.fail(error.ConnectionFailed, std.mem.print(&buf, "the connection failed ({t})", .{d.stage}) catch "the connection failed");
            },
            error.NameNotResolved => h.fail(error.ConnectionFailed, "the host's name was not found"),
            error.ConcurrencyUnavailable => h.fail(error.ConnectionFailed, "no task to look the host up with"),
            error.TlsFailed => if (pinRefused(d)) h.fail(error.PinnedPubkeyMismatch, pin_mismatch) else h.fail(error.TlsFailed, if (d.tls_error) |e| @errorName(e) else "TLS handshake failed"),
            error.ProxyAuthenticationRequired => h.rejectProxy(),
            error.ProxyAuthMethodUnsupported => h.fail(error.ProxyAuthMethodUnsupported, if (d.proxy_offered.len != 0) d.proxy_offered.slice() else "the proxy's scheme"),
            error.ProxyRefused, error.ProxyHostUnreachable, error.ProxyAddressUnsupported, error.ProxyProtocolError => |named| {
                // The proxy's status, or its SOCKS reply code.
                var buf: [64]u8 = undefined;
                const said = if (d.proxy_status) |status| std.mem.print(&buf, "proxy answered {d}", .{status}) catch @errorName(named) else @errorName(named);
                return h.fail(switch (named) {
                    error.ProxyRefused => error.ProxyRefused,
                    error.ProxyHostUnreachable => error.ProxyHostUnreachable,
                    error.ProxyAddressUnsupported => error.ProxyAddressUnsupported,
                    else => error.ProxyProtocolError,
                }, said);
            },
            error.HttpProtocolError => h.fail(error.ProtocolError, "not an HTTP response"),
            error.CertificateBundleUnreadable => h.fail(error.SslCertificateUnreadable, "the system's certificates"),
            // The one timeout git sets: `http.lowSpeedLimit` over
            // `http.lowSpeedTime`, curl's "operation too slow".
            error.TimedOut => h.fail(error.ConnectionFailed, if (d.timeout == .low_speed) "operation too slow" else "timed out"),
            error.BodyIncomplete => h.fail(error.ConnectionFailed, "the body was cut short"),
            error.ClientCertificateRejected => h.fail(error.ClientCertificateRejected, if (d.tls_error) |e| @errorName(e) else "the server refused the certificate"),
            error.ClientCertificateSchemeUnsupported => h.fail(error.ClientCertificateSchemeUnsupported, "no signature scheme the server takes"),
            error.InvalidUrl => h.fail(error.MalformedUrl, "a URL no request can carry"),
            error.InvalidHeader => h.fail(error.InvalidHttpHeader, "http.extraHeader"),
            // unreachable: the origin is http or https, a whole body is bytes and a written one is chunked, `finish` runs once, the proxy is fixed, and no redirect, retry, credential or hook is uplink's
            error.UnsupportedScheme, error.InvalidBody, error.BodyReadFailed, error.BodyTooLong, error.ExchangeOver, error.InvalidProxy, error.BodyNotReplayable, error.TooManyRedirects, error.InsecureRedirect, error.InvalidRedirect, error.CredentialsUnavailable, error.PrepareFailed => unreachable,
        };
    }

    fn pathFor(h: *Http, suffix: []const u8) Allocator.Error![]const u8 {
        return h.arena.allocator().print("{s}{s}", .{ h.base_path, suffix });
    }

    /// Send a `GET` and read its head, following redirects as curl does for
    /// git and handling a request for credentials as git's
    /// `http_request_reauth` does: a 401 to a request that carried none
    /// fills one and tries again; a 401 to one that carried one rejects it
    /// and ends there.
    fn get(h: *Http, suffix: []const u8) Error!*uplink.Response {
        var path = try h.pathFor(suffix);
        var redirects: u8 = 0;
        var reauths: u8 = 0;
        var rate_limited: i64 = 0;
        while (true) {
            h.endRequest();
            const authorization = h.credentials.authorization();
            const arena = h.arena.allocator();
            const list = try h.headers(arena, false, authorization, false);
            h.in_flight = h.client.send(h.io, .{
                .url = try h.origin.join(arena, path),
                .headers = list,
                .diagnostics = &h.diagnostics,
            }) catch |err| return h.clientFailed(err);
            const res = &h.in_flight.?;
            if (h.proxied) try h.approveProxy();
            const status = @backingInt(res.status);
            if (status == 407) return h.rejectProxy();
            if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) {
                if (h.follow_redirects == .never) return h.fail(error.HttpStatus, "a redirect, and http.followRedirects is false");
                if (h.downloading and h.follow_redirects == .initial) return h.fail(error.HttpStatus, "a redirect of a download, which http.followRedirects=initial does not follow");
                const location = res.headers.get("location") orelse return h.fail(error.HttpStatus, "a redirect with no Location");
                redirects += 1;
                if (redirects > 20) return h.fail(error.HttpStatus, "too many redirects");
                path = try h.follow(location, path);
                continue;
            }
            if (res.status == .too_many_requests and h.rate_limit.max_retries != 0) {
                rate_limited += 1;
                try h.waitToRetry(res, rate_limited);
                continue;
            }
            if (res.status == .unauthorized) {
                try h.keepChallenges(&res.headers);
                const said = try h.serverText(res);
                if (authorization != null) {
                    // A conversation a helper said goes on (`continue=1`)
                    // asks it again; any other credential is refused.
                    if (!h.credentials.multistage) {
                        h.credentials.reject(h.io, h.credentialOptions()) catch |err| return h.authFailed(err, .refused, 401, said);
                        return h.authFailed(error.AuthenticationFailed, .refused, 401, said);
                    }
                    h.credentials.nextRound();
                }
                // git's `http_request_recoverable`: three requests at most.
                reauths += 1;
                if (reauths > 2) return h.authFailed(error.AuthenticationFailed, .refused, 401, said);
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
            if (res.status.class() == .success and authorization != null) {
                try h.credentials.setChallenges(&.{});
                try h.credentials.approve(h.io, h.credentialOptions());
            }
            if (res.status.class() == .success) try h.approveCertificate();
            if (redirects > 0 and res.status.class() == .success and !h.downloading) try h.rebase(path);
            return res;
        }
    }

    /// A 429 answered as git's `http_request_recoverable` answers it: up
    /// to `http.maxRetries` requests in all (with none, the 429 is an
    /// error like any status), each after the wait the server's
    /// `Retry-After` asks — seconds, or a date against the caller's `now`
    /// — or else `http.retryAfter`,
    /// neither longer than `http.maxRetryTime`. `attempts` is how many
    /// were answered 429.
    fn waitToRetry(h: *Http, res: *uplink.Response, attempts: i64) Error!void {
        const limit = h.rate_limit;
        // curl's `CURLINFO_RETRY_AFTER`, which git takes when above zero.
        const zero: Seconds = .fromRaw(0);
        var asked = zero;
        if (res.headers.get("retry-after")) |raw| {
            const value = std.mem.trim(u8, raw, " \t");
            const read = decimal.strtol(value, 10, 64);
            if (read.end != 0) {
                asked = .fromRaw(@intCast(@max(read.value, 0))); // aegis: no-danger: strtol of 64 bits fits an i64
            } else if (h.options.now) |now| if (uplink.wire.date.parse(value)) |at| {
                asked = .fromRaw(@max(at - date.seconds(now), 0));
            };
        }
        var buf: [160]u8 = undefined;
        if (limit.max_retries > 0 and attempts >= limit.max_retries) {
            const text = if (asked.compare(zero) == .gt)
                std.mem.print(&buf, "rate limited, please try again in {d} seconds", .{asked.raw()}) catch unreachable // unreachable: two numbers and a sentence fit
            else
                "rate limited, please try again later";
            return h.fail(error.RateLimited, text);
        }
        const delay = if (asked.compare(zero) == .gt) delay: {
            if (asked.compare(limit.max_retry_time) == .gt) return h.fail(error.RateLimited, std.mem.print(&buf, "response requested a delay greater than http.maxRetryTime ({d} > {d} seconds)", .{ asked.raw(), limit.max_retry_time.raw() }) catch unreachable); // unreachable: as above
            break :delay asked;
        } else delay: {
            if (limit.retry_after.compare(limit.max_retry_time) == .gt) return h.fail(error.RateLimited, std.mem.print(&buf, "configured http.retryAfter exceeds http.maxRetryTime ({d} > {d} seconds)", .{ limit.retry_after.raw(), limit.max_retry_time.raw() }) catch unreachable); // unreachable: as above
            break :delay limit.retry_after;
        };
        // The 429's body is read so its connection can carry the next.
        h.endRequest();
        if (delay.compare(zero) != .gt) return;
        // unreachable: the delay is above zero, and a second count of an i64 fits a u64 and std's nanoseconds.
        try warning.note(h.options.warnings, .{ .rate_limited = delay.convert(.second, u64, .exact) catch unreachable });
        try h.io.sleep(delay.toIoDuration(), .awake);
    }

    /// Where a redirect leads: the target and path after it, from a
    /// `Location` that is a whole URL or a path.
    fn follow(h: *Http, location: []const u8, from: []const u8) Error![]const u8 {
        const arena = h.arena.allocator();
        if (std.mem.find(u8, location, "://") != null) {
            const text = try arena.dupe(u8, location);
            const to = url_mod.Url.parse(text) catch return h.fail(error.HttpStatus, "a redirect to a URL that does not parse");
            if (to.scheme != .http and to.scheme != .https) return h.fail(error.HttpStatus, "a redirect to another protocol");
            const environ: ?*const std.process.Environ.Map = if (h.options.programs) |p| p.environ else null;
            if (!policy.allowed(policy.nameOf(to.scheme), .{ .config = h.options.config, .environ = environ, .from_user = h.options.from_user })) {
                return h.fail(error.TransportNotAllowed, policy.nameOf(to.scheme));
            }
            const moved: Origin = .of(to);
            // A credential goes only where it was given.
            if (!moved.eql(h.origin)) {
                h.credentials.deinit();
                h.credentials = .{ .gpa = h.gpa, .url = to };
                h.extra_headers = try withoutCredentials(arena, h.extra_headers);
            }
            h.origin = moved;
            return if (to.path.len == 0) "/" else to.path;
        }
        if (location.len != 0 and location[0] == '/') return arena.dupe(u8, location);
        // Relative to the directory of the request that was redirected.
        const dir_end = (std.mem.findScalarLast(u8, from[0 .. std.mem.findScalar(u8, from, '?') orelse from.len], '/') orelse 0) + 1;
        return arena.print("{s}{s}", .{ from[0..dir_end], location });
    }

    /// `headers` without the ones that carry a credential, which curl drops
    /// from a custom header list when a redirect leaves the host.
    fn withoutCredentials(arena: Allocator, headers_in: []const http.Header) Allocator.Error![]const http.Header {
        var kept: std.ArrayList(http.Header) = .empty;
        for (headers_in) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization") or std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
            try kept.append(arena, header);
        }
        return kept.items;
    }

    /// Keep the `WWW-Authenticate` values of a refusal for the helpers.
    fn keepChallenges(h: *Http, fields: *const uplink.Headers) Error!void {
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(h.gpa);
        var it = fields.iterator();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "www-authenticate")) try values.append(h.gpa, header.value);
        }
        try h.credentials.setChallenges(values.items);
    }

    /// The body of a refusal when it is `text/plain`, which is where a forge
    /// explains itself and what git shows as `remote:` lines. At most 4 KiB,
    /// in the connection's arena.
    fn serverText(h: *Http, res: *uplink.Response) Error![]const u8 {
        const content_type = res.headers.get("content-type") orelse return "";
        if (!std.ascii.startsWithIgnoreCase(content_type, "text/plain")) return "";
        const reader = res.reader(h.io);
        var out: Io.Writer.Allocating = .init(h.arena.allocator());
        _ = reader.stream(&out.writer, .limited(4096)) catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => if (res.failure() == error.Canceled) return error.Canceled else return out.written(),
            else => return out.written(),
        };
        // What was read is the text; the rest is read only so the
        // connection can carry the next request.
        _ = reader.streamRemaining(&out.writer) catch |err| switch (err) {
            error.ReadFailed => if (res.failure() == error.Canceled) return error.Canceled,
            else => {},
        };
        const text = out.written();
        return text[0..@min(text.len, 4096)];
    }

    /// End with `err`, describing it in the caller's `auth_failure`.
    fn authFailed(h: *Http, err: anyerror, reason: auth.Failure.Reason, status: u16, said: []const u8) Error {
        const trimmed = std.mem.trim(u8, said, " \t\r\n");
        var status_buf: [16]u8 = undefined;
        h.connection.setMessage(if (trimmed.len != 0) trimmed else std.mem.print(&status_buf, "HTTP {d}", .{status}) catch "HTTP");
        if (h.options.auth_failure) |described| describe: {
            described.begin(h.gpa, reason, h.credentials.url.scheme, h.credentials.url.raw) catch break :describe;
            described.status = status;
            // glint-ignore: Z026 -- the description is a courtesy to the caller; the error, returned below, is the outcome
            described.setServerMessage(said) catch {};
            // glint-ignore: Z026 -- as above
            h.credentials.describeFailure(described, h.options.prompt != null) catch {};
        }
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.CredentialHelperQuit => error.CredentialHelperQuit,
            error.CredentialsUnavailable => error.CredentialsUnavailable,
            error.CredentialValueUnsafe => error.CredentialValueUnsafe,
            error.InvalidCredentialSetting => error.InvalidCredentialSetting,
            error.InvalidCredentialAnswer => error.InvalidCredentialAnswer,
            error.ProgramsNotGranted => error.ProgramsNotGranted,
            error.AuthenticationFailed => error.AuthenticationFailed,
            else => error.AuthenticationFailed,
        };
    }

    fn checkStatus(h: *Http, res: *uplink.Response) Error!void {
        const status = @backingInt(res.status);
        switch (res.status) {
            .ok => return,
            .unauthorized, .forbidden => {
                if (res.status == .unauthorized) try h.keepChallenges(&res.headers);
                const said = try h.serverText(res);
                return h.authFailed(error.AuthenticationFailed, if (status == 403) .forbidden else .refused, status, said);
            },
            .proxy_auth_required => return h.rejectProxy(),
            else => {
                const said = std.mem.trim(u8, try h.serverText(res), " \t\r\n");
                var buf: [32]u8 = undefined;
                const text = if (said.len != 0) said else std.mem.print(&buf, "HTTP {d}", .{status}) catch "HTTP";
                return h.fail(if (res.status == .not_found) error.RepositoryNotFound else error.HttpStatus, text);
            },
        }
    }

    fn advertisement(context: *anyopaque, _: *Connection) connection.Error!*Io.Reader {
        return self(context).body_reader;
    }

    const Answer = union(enum) { smart: *Io.Reader, dumb: []const u8 };

    fn advertisementInner(h: *Http) Error!Answer {
        var suffix_buf: [64]u8 = undefined;
        // unreachable: the longer service name, git-receive-pack, makes 35 bytes
        const suffix = std.mem.print(&suffix_buf, "/info/refs?service={s}", .{h.service.name()}) catch unreachable;
        const res = try h.get(suffix);
        try h.checkStatus(res);
        var expected_buf: [64]u8 = undefined;
        // unreachable: the longer service name, git-receive-pack, makes 44 bytes
        const expected = std.mem.print(&expected_buf, "application/x-{s}-advertisement", .{h.service.name()}) catch unreachable;
        const content_type = res.headers.get("content-type") orelse "";
        if (!std.mem.eql(u8, content_type, expected)) {
            // git's `check_smart_http`: anything else is the dumb listing,
            // read whole as git reads it, and every request after it is a
            // download.
            var listing: std.ArrayList(u8) = .empty;
            res.reader(h.io).appendRemaining(h.arena.allocator(), &listing, .limited(max_dumb_file_bytes)) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ReadFailed => h.fail(error.ConnectionFailed, "the body was cut short"),
                error.StreamTooLong => h.fail(error.DumbHttpFileTooLarge, "the info/refs listing is larger than 1 GiB"),
            };
            h.downloading = true;
            return .{ .dumb = listing.items };
        }

        const body = res.readerBuffered(h.io, h.body_buffer);
        // A v0 answer begins `# service=<name>` and a flush, which say what
        // the body is and nothing else.
        const first = body.peekArray(4) catch return error.RemoteHungUp;
        const len = pkt_line.parseLength(first) orelse return error.ProtocolError;
        if (len > 4) {
            const whole = body.peek(len) catch return error.RemoteHungUp;
            if (std.mem.startsWith(u8, whole[4..], "# service=")) {
                body.toss(len);
                const flush = body.takeArray(4) catch return error.RemoteHungUp;
                if (!std.mem.eql(u8, flush, "0000")) return error.ProtocolError;
            }
        }
        h.body_reader = body;
        return .{ .smart = body };
    }

    /// Where the `GET` that was followed ended: its path is the new base,
    /// once `/info/refs` and the query are off it. `RedirectMismatch` when
    /// it does not end so.
    fn rebase(h: *Http, final_path: []const u8) Error!void {
        const without_query = final_path[0 .. std.mem.findScalar(u8, final_path, '?') orelse final_path.len];
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
        const h: *Http = @alignCast(@fieldParentPtr("post", w)); // aegis: no-danger: this function is installed only on a Http's post
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
        // unreachable: a service name is at most 16 bytes
        const suffix = std.mem.print(&suffix_buf, "/{s}", .{h.service.name()}) catch unreachable;
        const arena = h.arena.allocator();
        const list = try h.headers(arena, true, h.credentials.authorization(), false);
        h.streaming = h.client.begin(h.io, .{
            .method = .POST,
            .url = try h.origin.join(arena, try h.pathFor(suffix)),
            .headers = list,
            .diagnostics = &h.diagnostics,
        }) catch |err| return h.clientFailed(err);
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
            const finished = s.finish(h.io);
            s.deinit(h.io);
            h.streaming = null;
            h.in_flight = finished catch |err| return h.clientFailed(err);
        } else {
            var suffix_buf: [64]u8 = undefined;
            // unreachable: a service name is at most 16 bytes
            const suffix = std.mem.print(&suffix_buf, "/{s}", .{h.service.name()}) catch unreachable;
            var arena_state: std.heap.ArenaAllocator = .init(h.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var body: []const u8 = h.post.buffered();
            const gzipped = h.service == .upload_pack and body.len > gzip_threshold;
            if (gzipped) body = try gzip(arena, body);
            const list = try h.headers(arena, true, h.credentials.authorization(), gzipped);
            h.in_flight = h.client.send(h.io, .{
                .method = .POST,
                .url = try h.origin.join(arena, try h.pathFor(suffix)),
                .headers = list,
                .body = .{ .bytes = body },
                .diagnostics = &h.diagnostics,
            }) catch |err| return h.clientFailed(err);
            h.post.end = 0;
        }
        const res = &h.in_flight.?;
        try h.checkStatus(res);
        var expected_buf: [64]u8 = undefined;
        // unreachable: the longer service name, git-receive-pack, makes 37 bytes
        const expected = std.mem.print(&expected_buf, "application/x-{s}-result", .{h.service.name()}) catch unreachable;
        if (!std.mem.eql(u8, res.headers.get("content-type") orelse "", expected)) return h.fail(error.ProtocolError, "unexpected content type");
        h.body_reader = res.readerBuffered(h.io, h.body_buffer);
        return h.body_reader;
    }

    fn gzip(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
        var compress = try warp.Compressor.init(arena, .{ .level = 9, .max_input = .fromRaw(bytes.len) });
        defer compress.deinit();
        const frame: warp.Compressor.Frame = .{ .container = .gzip };
        const out = try arena.alloc(u8, warp.Compressor.bound(bytes.len, frame));
        errdefer arena.free(out);
        const n = compress.compress(bytes, out, frame) catch unreachable; // unreachable: bound reserves the complete stream
        return arena.realloc(out, n);
    }

    fn failure(context: *anyopaque, c: *Connection) connection.Error {
        const h = self(context);
        const res = &(h.in_flight orelse return error.ConnectionFailed);
        const err = res.failure();
        if (err == error.Canceled) return error.Canceled;
        c.setMessage(@errorName(err));
        return error.ConnectionFailed;
    }

    fn deinit(io: Io, context: *anyopaque) void {
        const h = self(context);
        h.endRequest();
        h.client.deinit(io);
        if (h.proxy_secret) |*p| p.deinit();
        h.saveCookies(io);
        if (h.cookies) |*jar| jar.deinit(io);
        h.credentials.deinit();
        if (h.proxy_credentials) |*p| p.deinit();
        h.freeTls();
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

const testing = std.testing;

test "an https proxy is checked against http.proxySSLCAInfo, or the system's, whatever http.sslVerify says, and answered with http.proxySSLCert" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "cert.pem", .data = @embedFile("../testing/certs/p256.cert.pem") });
    try tmp.dir.writeFile(io, .{ .sub_path = "key.pem", .data = @embedFile("../testing/certs/p256.sec1.pem") });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const escaped = try config_mod.escapeValue(gpa, base);
    defer gpa.free(escaped);
    const url = try url_mod.Url.parse("https://git.example.com/repo.git");
    for ([_]bool{ false, true }) |with_files| {
        const text = if (with_files)
            try gpa.print("[http]\nproxy = https://proxy.example:3128\nsslVerify = false\nproxySSLCAInfo = {0s}/cert.pem\nproxySSLCert = {0s}/cert.pem\nproxySSLKey = {0s}/key.pem\n", .{escaped})
        else
            try gpa.dupe(u8, "[http]\nproxy = https://proxy.example:3128\nsslVerify = false\n");
        defer gpa.free(text);
        var config = try config_mod.Config.parseText(gpa, text, .local);
        defer config.deinit();
        var h: Http = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .client = undefined,
            .origin = undefined,
            .base_path = undefined,
            .service = .upload_pack,
            .v2 = false,
            .options = .{ .config = &config },
            .post_buffer = undefined,
            .post = undefined,
            .body_buffer = undefined,
            .connection = .{ .context = undefined, .vtable = &Http.vtable, .stateless = true },
            .credentials = .{ .gpa = gpa, .url = url },
        };
        defer {
            h.freeTls();
            h.credentials.deinit();
            h.arena.deinit();
        }
        const configured = try h.configure(url);
        const proxy = configured.client.proxy.fixed;
        try testing.expectEqual(uplink.Proxy.Kind.https, proxy.kind);
        // `http.sslVerify` is the server's alone.
        try testing.expectEqual(uplink.tls.ClientOptions.Verify.none, configured.client.tls.verify);
        switch (proxy.tls.trust) {
            .own => |own| try testing.expectEqual(with_files, own != null),
            .as_target => return error.TestUnexpectedResult,
        }
        try testing.expectEqual(with_files, proxy.tls.client_auth != null);
    }
}
