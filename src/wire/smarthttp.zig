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
//! a plain file listing — git's dumb protocol — is refused by name. A
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
//! (`httpsettings.zig`), and a proxy is `http.proxy` or the one curl would
//! find in the environment: an `https` URL goes through it in a `CONNECT`
//! tunnel with TLS inside, an `http` one as a whole URL. A proxy's
//! credentials are the ones its URL carries, a username there with the
//! password from the person's helpers, as git fills them. Client certificates
//! come from `http.sslCert` and `http.sslKey`, or `http.proxySSLCert` and
//! `http.proxySSLKey` for an https proxy, and uplink presents them.

const Self = @This();

const std = @import("std");
const warp = @import("warp");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const config_mod = @import("../config/config.zig");
const program = @import("../process/program.zig");
const pktline = @import("../codec/pktline.zig");
const url_mod = @import("url.zig");
const connection = @import("connection.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const httpsettings = @import("httpsettings.zig");
const policy = @import("policy.zig");
const clientcert = @import("clientcert.zig");
const uplink = @import("uplink");
const tls = uplink.tls;
const warning = @import("../report/warning.zig");
const builtin = @import("builtin");

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
} || connection.Error || credential.Error || clientcert.Error;

/// How the conversation is made.
pub const Options = struct {
    /// The repository's configuration, for the `http.*` settings.
    config: ?*const config_mod.Config = null,
    /// The configured remote, for `remote.<name>.proxy`.
    remote_name: ?[]const u8 = null,
    /// The proxy, over the one `remote_name` and the settings choose.
    proxy: httpsettings.Proxy = .auto,
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
    now: ?i64 = null,
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

/// Open a smart HTTP conversation with the service at `url`.
pub fn connect(gpa: Allocator, io: Io, url: url_mod.Url, service: Service, options: Options) Self.Error!*Connection {
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
    errdefer h.freeTls();

    const configured = try h.configure(url);
    // The client points at the authorities and certificates `configure`
    // keeps in `h`, which outlive it.
    h.client = .init(gpa, configured.client);
    errdefer h.client.deinit(io);
    errdefer h.endRequest();
    const settings = configured.settings;
    h.post_buffer = try h.arena.allocator().alloc(u8, @intCast(settings.post_buffer));
    h.body_buffer = try h.arena.allocator().alloc(u8, pktline.max_line);
    h.post = .{ .vtable = &.{ .drain = Http.drainPost }, .buffer = h.post_buffer };
    // The advertisement is asked for here, so that what can go wrong with
    // the first request — a credential refused, no repository, a dumb
    // server — is refused by its own name.
    _ = try h.advertisementInner();
    return &h.connection;
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
    follow_redirects: httpsettings.FollowRedirects = .initial,
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
    /// `http.sslCAInfo` and `http.sslCAPath`, when they name authorities;
    /// `http.proxySSLCAInfo`, when it does.
    trust: ?tls.Trust = null,
    proxy_trust: ?tls.Trust = null,
    /// `http.sslCert` and its key, and the passphrase's credential when
    /// `http.sslCertPasswordProtected` asks for one.
    client_auth: ?tls.ClientAuth = null,
    cert_credentials: ?credential.Session = null,
    /// The same for an `https` proxy.
    proxy_client_auth: ?tls.ClientAuth = null,
    proxy_cert_credentials: ?credential.Session = null,
    /// A failure met inside a writer, which can only say that it failed.
    write_error: ?Error = null,

    /// What `configure` read: the settings, and the client they make.
    const Configured = struct {
        settings: httpsettings.Settings,
        client: uplink.Client.Options,
    };

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .close = close,
    };

    fn self(context: *anyopaque) *Http {
        return @ptrCast(@alignCast(context)); // safe: the context handed out with this vtable is an Http
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
        var settings = try httpsettings.resolveForRemote(arena, h.options.config, environ, url, h.options.remote_name);
        httpsettings.chooseProxy(&settings, h.options.proxy);
        var tls_options: tls.ClientOptions = .{};
        if (url.scheme == .https) {
            if (settings.ssl_cert) |cert| {
                h.client_auth = try h.clientCertificate(.{
                    .cert = try expandHome(arena, cert, environ),
                    .key = if (settings.ssl_key) |k| try expandHome(arena, k, environ) else null,
                    .cert_type = settings.ssl_cert_type,
                    .key_type = settings.ssl_key_type,
                }, settings.ssl_cert_password_protected, &h.cert_credentials);
                tls_options.client_auth = &h.client_auth.?;
            }
            if (!settings.ssl_verify) {
                tls_options.verify = .none;
                try warning.note(h.options.warnings, .{ .ssl_verify_disabled = settings.ssl_verify_from orelse "http.sslVerify" });
            } else if (settings.ca_info != null or settings.ca_path != null) {
                try h.trustAuthorities(settings, environ);
                tls_options.trust = &h.trust.?;
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
        h.extra_headers = extra.items;
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
                h.proxy_trust = .init(h.gpa);
                h.proxy_trust.?.addFile(h.io, Io.Dir.cwd(), file) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Canceled => error.Canceled,
                    else => h.fail(error.SslCertificateUnreadable, "http.proxySSLCAInfo"),
                };
                p.tls.trust = .{ .own = &h.proxy_trust.? };
            } else p.tls.trust = .{ .own = null };
            if (settings.proxy_ssl_cert) |cert| {
                h.proxy_client_auth = try h.clientCertificate(.{
                    .cert = cert,
                    .key = settings.proxy_ssl_key,
                }, settings.proxy_ssl_cert_password_protected, &h.proxy_cert_credentials);
                p.tls.client_auth = &h.proxy_client_auth.?;
            }
        };
        h.proxied = proxy != null;
        return .{
            .settings = settings,
            .client = .{
                .proxy = if (proxy) |p| .{ .fixed = p } else .none,
                .tls = tls_options,
                // One connection kept, as curl keeps one for git.
                .pool = .{ .max_idle_per_route = 1, .max_idle = 1 },
                // git's redirects and retries are its own, decided here.
                .redirects = .none,
                .retries = .none,
            },
        };
    }

    /// Read a client certificate and its key, as curl reads them for git.
    /// With `ask`, the passphrase is filled first — `protocol=cert`, the
    /// certificate's path — as git's `has_cert_password` fills it whether
    /// the key is encrypted or not; a certificate that cannot be used then
    /// has its passphrase rejected, as git rejects it on
    /// `CURLE_SSL_CERTPROBLEM`.
    fn clientCertificate(h: *Http, files: clientcert.Files, ask: bool, session_slot: *?credential.Session) Error!tls.ClientAuth {
        var passphrase: ?[]const u8 = null;
        if (ask) {
            session_slot.* = .forCertificate(h.gpa, files.cert);
            const session = &session_slot.*.?;
            if (try session.fill(h.io, h.credentialOptions())) passphrase = session.password;
        }
        return clientcert.load(h.gpa, h.io, files, .{ .arena = h.arena.allocator(), .passphrase = passphrase }) catch |err| {
            // Git for Windows leaves the helper's certificate passphrase in
            // place on a local key parse error; its curl backend does not
            // classify that error as a rejected credential.
            if (builtin.target.os.tag != .windows) {
                if (session_slot.*) |*session| try forgetRefused(h.io, session, h.credentialOptions());
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                error.SslClientKeyUnreadable, error.SslClientKeyPassphraseRequired, error.SslClientKeyPassphraseWrong => h.fail(err, clientcert.keyPath(files)),
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
        if (h.trust) |*t| t.deinit();
        if (h.proxy_trust) |*t| t.deinit();
        if (h.client_auth) |*a| a.deinit();
        if (h.proxy_client_auth) |*a| a.deinit();
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
    fn trustAuthorities(h: *Http, settings: httpsettings.Settings, environ: ?*const std.process.Environ.Map) Error!void {
        const arena = h.arena.allocator();
        h.trust = .init(h.gpa);
        const t = &h.trust.?;
        if (settings.ca_info) |raw| {
            t.addFile(h.io, Io.Dir.cwd(), try expandHome(arena, raw, environ)) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => h.fail(error.SslCertificateUnreadable, settings.ca_info_from orelse "http.sslCAInfo"),
            };
        } else {
            t.addSystem(h.io) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => h.fail(error.SslCertificateUnreadable, "the system's certificates"),
            };
        }
        if (settings.ca_path) |raw| {
            t.addDir(h.io, Io.Dir.cwd(), try expandHome(arena, raw, environ)) catch |err| return switch (err) {
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
        return std.Io.Dir.path.join(arena, &.{ home, path[2..] });
    }

    /// The proxy, and its credential: the user and password its URL
    /// carries, or a user there and the password from the person's helpers,
    /// as git's `init_curl_proxy_auth` fills it.
    fn configureProxy(h: *Http, raw: []const u8, method_name: []const u8) Error!uplink.Proxy {
        const arena = h.arena.allocator();
        var proxy = uplink.Proxy.parse(arena, raw, .curl) catch |err| return switch (err) {
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
            proxy.credential = .{
                .user = try arena.dupe(u8, session.username orelse ""),
                .password = try arena.dupe(u8, session.password orelse ""),
                .method = method,
            };
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
    /// so its connection can carry the next one.
    fn endRequest(h: *Http) void {
        if (h.in_flight) |*res| {
            // ziglint-ignore: Z026 a body left unread costs only the connection: deinit keeps it only when the response is complete
            _ = res.reader(h.io).discardRemaining() catch {};
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
            error.TlsFailed => h.fail(error.TlsFailed, if (d.tls_error) |e| @errorName(e) else "TLS handshake failed"),
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
            // git sets no timeout of these kinds, so none is set here.
            error.TimedOut => h.fail(error.ConnectionFailed, "timed out"),
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
                const location = res.headers.get("location") orelse return h.fail(error.HttpStatus, "a redirect with no Location");
                redirects += 1;
                if (redirects > 20) return h.fail(error.HttpStatus, "too many redirects");
                path = try h.follow(location, path);
                continue;
            }
            if (res.status == .unauthorized) {
                try h.keepChallenges(&res.headers);
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
            if (res.status.class() == .success and authorization != null) {
                try h.credentials.setChallenges(&.{});
                try h.credentials.approve(h.io, h.credentialOptions());
            }
            if (res.status.class() == .success) try h.approveCertificate();
            if (redirects > 0 and res.status.class() == .success) try h.rebase(path);
            return res;
        }
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
            else => return out.written(),
        };
        // ziglint-ignore: Z026 what was read is the text; the rest is read only so the connection can carry the next request
        _ = reader.streamRemaining(&out.writer) catch {};
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
            // ziglint-ignore: Z026 the description is a courtesy to the caller; the error, returned below, is the outcome
            described.setServerMessage(said) catch {};
            // ziglint-ignore: Z026 as above
            h.credentials.describeFailure(described, h.options.prompt != null) catch {};
        }
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.CredentialHelperQuit => error.CredentialHelperQuit,
            error.CredentialsUnavailable => error.CredentialsUnavailable,
            error.CredentialMultistageUnsupported => error.CredentialMultistageUnsupported,
            error.CredentialValueUnsafe => error.CredentialValueUnsafe,
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

    fn advertisementInner(h: *Http) Error!*Io.Reader {
        var suffix_buf: [64]u8 = undefined;
        // unreachable: the longer service name, git-receive-pack, makes 35 bytes
        const suffix = std.mem.print(&suffix_buf, "/info/refs?service={s}", .{h.service.name()}) catch unreachable;
        const res = try h.get(suffix);
        try h.checkStatus(res);
        var expected_buf: [64]u8 = undefined;
        // unreachable: the longer service name, git-receive-pack, makes 44 bytes
        const expected = std.mem.print(&expected_buf, "application/x-{s}-advertisement", .{h.service.name()}) catch unreachable;
        const content_type = res.headers.get("content-type") orelse "";
        if (!std.mem.eql(u8, content_type, expected)) return error.DumbHttpUnsupported;

        const body = res.readerBuffered(h.io, h.body_buffer);
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
        const h: *Http = @alignCast(@fieldParentPtr("post", w)); // safe: this function is installed only on a Http's post
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
        var compress = try warp.Compressor.init(arena, .{ .level = 9, .max_input = bytes.len });
        defer compress.deinit();
        const frame: warp.Compressor.Frame = .{ .container = .gzip };
        const out = try arena.alloc(u8, warp.Compressor.bound(bytes.len, frame));
        errdefer arena.free(out);
        const n = compress.compress(bytes, out, frame) catch unreachable; // bound reserves the complete stream
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

    fn close(io: Io, context: *anyopaque) void {
        const h = self(context);
        h.endRequest();
        h.client.deinit(io);
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
        try testing.expectEqual(tls.ClientOptions.Verify.none, configured.client.tls.verify);
        switch (proxy.tls.trust) {
            .own => |authorities| try testing.expectEqual(with_files, authorities != null),
            .as_target => return error.TestUnexpectedResult,
        }
        try testing.expectEqual(with_files, proxy.tls.client_auth != null);
    }
}
