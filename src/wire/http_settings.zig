//! The `http.*` settings for one URL, read the way git reads them.
//!
//! Every `http.<key>` may also be written `http.<url>.<key>`, and applies
//! then only to URLs the pattern matches — which is how a corporate proxy
//! is set for one host and a private CA for another. git reads the entries
//! in configuration order and lets one through only when it matches at
//! least as closely as the best one seen before it for the same key: an
//! exact host over a wildcard, a longer host, then a longer path, then a
//! pattern that names the user. A single-valued key ends as the last one
//! let through; `http.extraHeader` collects every one let through, an
//! empty value clearing the list, as git's own callback does.
//!
//! The environment overrides the files as it does for git:
//! `GIT_SSL_NO_VERIFY`, `GIT_SSL_CAINFO`, `GIT_SSL_CAPATH`, `GIT_SSL_CERT`,
//! `GIT_SSL_KEY` and `GIT_HTTP_USER_AGENT`; and a proxy is `http.proxy`,
//! else what curl reads for git — `https_proxy` or `HTTPS_PROXY` for
//! `https`, only the lower-case `http_proxy` for `http` (where a name has
//! case; on Windows it has none), then `all_proxy` or `ALL_PROXY` — unless
//! `no_proxy` or `NO_PROXY` names the host. An empty `http.proxy` turns
//! every proxy off.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const config_mod = @import("../config/config.zig");
const url_mod = @import("url.zig");
const urlmatch = @import("../text.zig").urlmatch;
const decimal = @import("../text.zig").decimal;
const Io = std.Io;
const uplink = @import("uplink");
const shakedown = @import("shakedown");
/// Whether relic was built with HTTP: the `http` build option.
const http_enabled = @import("relic_options").http;

/// What an HTTP conversation with one URL is configured to do.
pub const Settings = struct {
    /// The proxy to go through, as written, or `null` for none.
    proxy: ?[]const u8 = null,
    /// Whether the server's certificate is checked.
    ssl_verify: bool = true,
    /// A file of certificates to trust in place of the system's.
    ca_info: ?[]const u8 = null,
    /// A directory of certificates to trust besides.
    ca_path: ?[]const u8 = null,
    /// A client certificate and its key.
    ssl_cert: ?[]const u8 = null,
    ssl_key: ?[]const u8 = null,
    /// `http.sslCertType` and `http.sslKeyType`: `PEM`, `DER`.
    ssl_cert_type: ?[]const u8 = null,
    ssl_key_type: ?[]const u8 = null,
    /// A client certificate and key for an `https` proxy, and whether its
    /// key's passphrase is asked for.
    proxy_ssl_cert: ?[]const u8 = null,
    proxy_ssl_key: ?[]const u8 = null,
    proxy_ssl_cert_password_protected: bool = false,
    /// `http.proxySSLCAInfo`: the authorities an `https` proxy is checked
    /// against, in place of the system's.
    proxy_ssl_ca_info: ?[]const u8 = null,
    /// Every `http.extraHeader` value, in order.
    extra_headers: []const []const u8 = &.{},
    /// `http.postBuffer`: the largest request sent whole.
    post_buffer: u64 = 1 << 20,
    /// `http.userAgent`, when set.
    user_agent: ?[]const u8 = null,
    /// `http.proxyAuthMethod`: `anyauth`, `basic`, `digest`, `negotiate`,
    /// `ntlm`.
    proxy_auth_method: []const u8 = "anyauth",
    /// `http.sslCertPasswordProtected`.
    ssl_cert_password_protected: bool = false,
    /// `http.followRedirects`.
    follow_redirects: FollowRedirects = .initial,
    /// Where each setting that was not the default came from, for a
    /// message: `http.https://git.example.com.sslcainfo` and the like.
    /// Only the TLS ones are kept.
    ca_info_from: ?[]const u8 = null,
    ssl_verify_from: ?[]const u8 = null,
    /// `http.version`: `HTTP/1.1` or `HTTP/2`, as written; anything else
    /// git warns of and leaves curl's default.
    http_version: ?[]const u8 = null,
    /// `http.sslVersion` or `GIT_SSL_VERSION`, as written: curl's names,
    /// `sslv2` to `tlsv1.3`; an empty one is curl's default.
    ssl_version: ?[]const u8 = null,
    /// `http.pinnedPubkey`: `sha256//<base64>` hashes, `;` between them,
    /// or a file holding the key.
    pinned_pubkey: ?[]const u8 = null,
    /// `http.cookieFile`: where cookies are read from, and written to
    /// when `http.saveCookies` says so.
    cookie_file: ?[]const u8 = null,
    save_cookies: bool = false,
    /// `http.lowSpeedLimit` and `http.lowSpeedTime`: a transfer slower
    /// than the limit, in bytes a second, for the time, in seconds, is
    /// given up on; only when both are above zero.
    low_speed_limit: i64 = -1,
    low_speed_time: i64 = -1,
    /// `http.retryAfter`, `http.maxRetries` and `http.maxRetryTime`: how
    /// a 429 is answered, in seconds and attempts.
    retry_after: i64 = 0,
    max_retries: i64 = 0,
    max_retry_time: i64 = 300,
    /// The variables among `GIT_HTTP_LOW_SPEED_*` and `GIT_HTTP_*RETR*`
    /// that are not a number, which git warns of and leaves as they were.
    env_unparsed: []const []const u8 = &.{},

    /// Take `http.<name>`'s `value` (`null` when it is written without
    /// `=`), from `origin`, as git's `http_options` takes it: a boolean
    /// bare is true and otherwise one of git's spellings, a string or a
    /// path must have a value, a path is interpolated (`~`, `~user`) and
    /// one marked `:(optional)` is dropped when no file is there, a number
    /// is an `int`. Every value git dies on is `error.InvalidHttpSetting`,
    /// for the settings relic does not use as well.
    fn take(
        settings: *Settings,
        arena: Allocator,
        io: Io,
        paths: Paths,
        name: []const u8,
        value: ?[]const u8,
        origin: []const u8,
        headers: *std.ArrayList([]const u8),
    ) Error!void {
        // `pin` is a path read as git reads one, or curl's `sha256//`
        // hashes, which name no file to be found from the base.
        const Kind = enum { boolean, integer, string, path, pin };
        const kinds = [_]struct { []const u8, Kind }{
            .{ "version", .string },                        .{ "sslverify", .boolean },
            .{ "sslcipherlist", .string },                  .{ "sslversion", .string },
            .{ "sslcert", .path },                          .{ "sslcerttype", .string },
            .{ "sslkey", .path },                           .{ "sslkeytype", .string },
            .{ "sslcapath", .path },                        .{ "sslcainfo", .path },
            .{ "sslcertpasswordprotected", .boolean },      .{ "ssltry", .boolean },
            .{ "schannelcheckrevoke", .boolean },           .{ "schannelusesslcainfo", .boolean },
            .{ "minsessions", .integer },                   .{ "maxrequests", .integer },
            .{ "lowspeedlimit", .integer },                 .{ "lowspeedtime", .integer },
            .{ "noepsv", .boolean },                        .{ "proxy", .string },
            .{ "proxyauthmethod", .string },                .{ "proxysslcert", .string },
            .{ "proxysslkey", .string },                    .{ "proxysslcainfo", .string },
            .{ "proxysslcertpasswordprotected", .boolean }, .{ "cookiefile", .path },
            .{ "savecookies", .boolean },                   .{ "useragent", .string },
            .{ "delegation", .string },                     .{ "pinnedpubkey", .pin },
            .{ "keepaliveidle", .integer },                 .{ "keepaliveinterval", .integer },
            .{ "keepalivecount", .integer },                .{ "retryafter", .integer },
            .{ "maxretries", .integer },                    .{ "maxretrytime", .integer },
        };
        var kind: ?Kind = null;
        for (kinds) |entry| {
            if (std.mem.eql(u8, name, entry[0])) kind = entry[1];
        }
        var flag = false;
        var number: i64 = 0;
        var text: ?[]const u8 = null;
        if (kind) |k| switch (k) {
            .boolean => flag = if (value) |v| config_mod.parseBool(v) catch return error.InvalidHttpSetting else true,
            .integer => {
                const n = config_mod.parseInteger(value orelse return error.InvalidHttpSetting) catch return error.InvalidHttpSetting;
                number = std.math.cast(i32, n) orelse return error.InvalidHttpSetting;
            },
            .string => text = value orelse return error.InvalidHttpSetting,
            .path => text = try pathValue(arena, io, paths, value),
            .pin => text = if (value != null and std.mem.startsWith(u8, value.?, "sha256//")) value else try pathValue(arena, io, paths, value),
        };

        if (std.mem.eql(u8, name, "proxy")) {
            settings.proxy = text;
        } else if (std.mem.eql(u8, name, "sslverify")) {
            settings.ssl_verify = flag;
            settings.ssl_verify_from = origin;
        } else if (std.mem.eql(u8, name, "sslcainfo")) {
            settings.ca_info = text;
            settings.ca_info_from = origin;
        } else if (std.mem.eql(u8, name, "sslcapath")) {
            settings.ca_path = text;
        } else if (std.mem.eql(u8, name, "sslcert")) {
            settings.ssl_cert = text;
        } else if (std.mem.eql(u8, name, "sslkey")) {
            settings.ssl_key = text;
        } else if (std.mem.eql(u8, name, "sslcerttype")) {
            settings.ssl_cert_type = text;
        } else if (std.mem.eql(u8, name, "sslkeytype")) {
            settings.ssl_key_type = text;
        } else if (std.mem.eql(u8, name, "proxysslcert")) {
            settings.proxy_ssl_cert = text;
        } else if (std.mem.eql(u8, name, "proxysslkey")) {
            settings.proxy_ssl_key = text;
        } else if (std.mem.eql(u8, name, "proxysslcainfo")) {
            settings.proxy_ssl_ca_info = text;
        } else if (std.mem.eql(u8, name, "proxysslcertpasswordprotected")) {
            settings.proxy_ssl_cert_password_protected = flag;
        } else if (std.mem.eql(u8, name, "extraheader")) {
            const header = value orelse return error.InvalidHttpSetting;
            if (header.len == 0) headers.clearRetainingCapacity() else try headers.append(arena, header);
        } else if (std.mem.eql(u8, name, "curloptresolve") or std.mem.eql(u8, name, "proactiveauth")) {
            if (value == null) return error.InvalidHttpSetting;
        } else if (std.mem.eql(u8, name, "emptyauth")) {
            if (value == null or !std.mem.eql(u8, value.?, "auto")) {
                if (value) |v| _ = config_mod.parseBool(v) catch return error.InvalidHttpSetting;
            }
        } else if (std.mem.eql(u8, name, "postbuffer")) {
            // `git_config_ssize_t`; below git's largest packet, that size.
            const n = config_mod.parseInteger(value orelse return error.InvalidHttpSetting) catch return error.InvalidHttpSetting;
            settings.post_buffer = @intCast(@max(n, large_packet_max));
        } else if (std.mem.eql(u8, name, "useragent")) {
            settings.user_agent = text;
        } else if (std.mem.eql(u8, name, "proxyauthmethod")) {
            settings.proxy_auth_method = text.?;
        } else if (std.mem.eql(u8, name, "followredirects")) {
            settings.follow_redirects = if (value != null and std.mem.eql(u8, value.?, "initial"))
                .initial
            else if (value == null or (config_mod.parseBool(value.?) catch return error.InvalidHttpSetting))
                .always
            else
                .never;
        } else if (std.mem.eql(u8, name, "sslcertpasswordprotected")) {
            settings.ssl_cert_password_protected = flag;
        } else settings.takeTransfer(name, flag, number, text);
    }

    /// The settings of how a transfer goes rather than where: the HTTP and
    /// TLS versions, a pinned key, cookies, the slow-transfer limit and
    /// the answer to a 429.
    fn takeTransfer(settings: *Settings, name: []const u8, flag: bool, number: i64, text: ?[]const u8) void {
        if (std.mem.eql(u8, name, "version")) {
            settings.http_version = text;
        } else if (std.mem.eql(u8, name, "sslversion")) {
            settings.ssl_version = text;
        } else if (std.mem.eql(u8, name, "pinnedpubkey")) {
            settings.pinned_pubkey = text;
        } else if (std.mem.eql(u8, name, "cookiefile")) {
            settings.cookie_file = text;
        } else if (std.mem.eql(u8, name, "savecookies")) {
            settings.save_cookies = flag;
        } else if (std.mem.eql(u8, name, "lowspeedlimit")) {
            settings.low_speed_limit = number;
        } else if (std.mem.eql(u8, name, "lowspeedtime")) {
            settings.low_speed_time = number;
        } else if (std.mem.eql(u8, name, "retryafter")) {
            settings.retry_after = number;
        } else if (std.mem.eql(u8, name, "maxretries")) {
            settings.max_retries = number;
        } else if (std.mem.eql(u8, name, "maxretrytime")) {
            settings.max_retry_time = number;
        }
    }

    /// A path setting as `config.pathSetting` reads it, every failure one
    /// git dies on; a relative path is found from `paths.base`, and made
    /// whole from it when one was given, so whatever opens the file finds
    /// the one git would.
    fn pathValue(arena: Allocator, io: Io, paths: Paths, raw: ?[]const u8) Error!?[]const u8 {
        const base = paths.base orelse Io.Dir.cwd();
        const read = config_mod.pathSetting(arena, io, base, paths.home, raw) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.MissingPath, error.UnexpandablePath, error.UnstatablePath => error.InvalidHttpSetting,
        };
        const path = read orelse return null;
        if (paths.base == null or std.Io.Dir.path.isAbsolute(path)) return path;
        const top = base.realPathFileAlloc(io, ".", arena) catch return error.InvalidHttpSetting;
        return try std.Io.Dir.path.join(arena, &.{ top, path });
    }

    /// Where a path setting's `~` and relative paths are found from.
    const Paths = struct { home: ?[]const u8, base: ?Io.Dir };

    /// What the environment says over the configuration, as git reads it:
    /// `GIT_SSL_*`, `GIT_HTTP_*`, `GIT_PROXY_SSL_*`, and the proxy
    /// variables unless the configuration named a proxy, `no_proxy`
    /// turning a proxy off for the hosts it names.
    fn takeEnvironment(settings: *Settings, arena: Allocator, env: *const Environ.Map, url: url_mod.Url, proxy_set: bool) Allocator.Error!void {
        if (env.get("GIT_SSL_NO_VERIFY") != null) {
            settings.ssl_verify = false;
            settings.ssl_verify_from = "GIT_SSL_NO_VERIFY";
        }
        if (env.get("GIT_SSL_CAINFO")) |v| {
            settings.ca_info = v;
            settings.ca_info_from = "GIT_SSL_CAINFO";
        }
        if (env.get("GIT_SSL_CAPATH")) |v| settings.ca_path = v;
        if (env.get("GIT_SSL_CERT")) |v| settings.ssl_cert = v;
        if (env.get("GIT_SSL_KEY")) |v| settings.ssl_key = v;
        if (env.get("GIT_HTTP_USER_AGENT")) |v| settings.user_agent = v;
        if (env.get("GIT_HTTP_PROXY_AUTHMETHOD")) |v| settings.proxy_auth_method = v;
        if (env.get("GIT_SSL_CERT_TYPE")) |v| settings.ssl_cert_type = v;
        if (env.get("GIT_SSL_KEY_TYPE")) |v| settings.ssl_key_type = v;
        // Set at all, these turn the prompt on, whatever they say, as git
        // reads them — the first for an https URL only.
        if (env.get("GIT_SSL_CERT_PASSWORD_PROTECTED") != null and url.scheme == .https) settings.ssl_cert_password_protected = true;
        if (env.get("GIT_PROXY_SSL_CERT")) |v| settings.proxy_ssl_cert = v;
        if (env.get("GIT_PROXY_SSL_KEY")) |v| settings.proxy_ssl_key = v;
        if (env.get("GIT_PROXY_SSL_CAINFO")) |v| settings.proxy_ssl_ca_info = v;
        if (env.get("GIT_PROXY_SSL_CERT_PASSWORD_PROTECTED") != null) settings.proxy_ssl_cert_password_protected = true;
        if (env.get("GIT_SSL_VERSION")) |v| settings.ssl_version = v;
        // git's `set_long_from_env`: C's `strtol` over the whole value, a
        // value that is not one warned of and left alone.
        var unparsed: std.ArrayList([]const u8) = .empty;
        const numbers = [_]struct { []const u8, *i64 }{
            .{ "GIT_HTTP_LOW_SPEED_LIMIT", &settings.low_speed_limit },
            .{ "GIT_HTTP_LOW_SPEED_TIME", &settings.low_speed_time },
            .{ "GIT_HTTP_RETRY_AFTER", &settings.retry_after },
            .{ "GIT_HTTP_MAX_RETRIES", &settings.max_retries },
            .{ "GIT_HTTP_MAX_RETRY_TIME", &settings.max_retry_time },
        };
        for (numbers) |entry| {
            const v = env.get(entry[0]) orelse continue;
            const read = decimal.strtol(v, 10, 64);
            if (read.overflow or read.end == 0 or read.end != v.len) {
                try unparsed.append(arena, entry[0]);
            } else entry[1].* = @intCast(read.value); // safe: strtol of 64 bits fits an i64
        }
        settings.env_unparsed = unparsed.items;
        if (!proxy_set) settings.proxy = uplink.Proxy.environmentValue(env, url.scheme == .https, .lowercase);
        if (settings.proxy) |_| {
            // git supplies an explicitly set lowercase list to curl even
            // when it is empty, overriding curl's environment fallback.
            const list = env.get("no_proxy") orelse uplink.Proxy.noProxyValue(env, .lowercase);
            const port = url.port orelse @as(u16, if (url.scheme == .https) 443 else 80);
            if (uplink.Proxy.bypassed(list, url.host, port, .lowercase)) settings.proxy = null;
        }
    }
};

/// Which redirects are followed, as git's `http.followRedirects` says.
pub const FollowRedirects = enum {
    /// None: a redirect is an error.
    never,
    /// Those of the first request of a conversation, git's default.
    initial,
    /// Every request's.
    always,
};

/// git's `LARGE_PACKET_MAX`, the least `http.postBuffer` git keeps.
const large_packet_max = 65520;

/// Errors from reading the settings.
pub const Error = error{
    /// A value that does not parse: a `http.sslVerify` that is not a
    /// boolean, a `http.postBuffer` that is not a size.
    InvalidHttpSetting,
    /// relic was built without HTTP: its `http` build option is off.
    HttpUnavailable,
} || Allocator.Error;

/// Which proxy an HTTP remote is reached through, chosen by the caller.
/// Other remotes do not read it.
pub const Proxy = union(enum) {
    /// git's choice: `remote.<name>.proxy`, then `http.proxy`, then the
    /// environment's, short of what `no_proxy` names.
    auto,
    /// None, whatever the configuration and the environment name.
    none,
    /// This one, a URL as `http.proxy` takes one, over the configuration,
    /// the environment and `no_proxy`; an empty one is none.
    url: []const u8,
};

/// The caller's choice of proxy put over what the settings found.
pub fn chooseProxy(s: *Settings, choice: Proxy) void {
    switch (choice) {
        .auto => {},
        .none => s.proxy = null,
        .url => |text| s.proxy = if (text.len == 0) null else text,
    }
}

/// Where the settings for a URL come from.
pub const Sources = struct {
    config: ?*const config_mod.Config = null,
    environ: ?*const Environ.Map = null,
    /// The remote the URL is a named remote's: its `remote.<name>.proxy`
    /// overrides `http.proxy`, an empty value included; the environment's
    /// `no_proxy` still applies to it.
    remote_name: ?[]const u8 = null,
    /// Where a relative path setting (`http.sslCAInfo` and the rest) is
    /// found from, as git finds it from where it runs: the repository's
    /// working tree, else its git directory. `null` is the process's
    /// working directory.
    base: ?Io.Dir = null,
};

/// The settings for `url`, from `sources`. Every slice is in `arena`, or
/// borrowed from the configuration or the environment.
pub fn resolve(arena: Allocator, io: Io, url: url_mod.Url, sources: Sources) Self.Error!Settings {
    const config = sources.config;
    const environ = sources.environ;
    const remote_name = sources.remote_name;
    if (comptime !http_enabled) return error.HttpUnavailable;
    var s: Settings = .{};
    var headers: std.ArrayList([]const u8) = .empty;
    var proxy_set = false;
    if (config) |c| {
        // A URL git cannot normalize matches no pattern: only the
        // settings written without one apply.
        const normalized: ?urlmatch.Info = urlmatch.normalize(arena, url.raw, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        const home = if (environ) |env| env.get("HOME") else null;
        var best: std.StringHashMapUnmanaged(urlmatch.Match) = .empty;
        for (c.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "http")) continue;
            const matched: urlmatch.Match = if (entry.subsection.len == 0) .any else blk: {
                const have = normalized orelse continue;
                const pattern = urlmatch.normalize(arena, entry.subsection, true) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                break :blk urlmatch.match(have, pattern) orelse continue;
            };
            const name = try std.ascii.allocLowerString(arena, entry.name);
            const gop = try best.getOrPut(arena, name);
            if (gop.found_existing and matched.order(gop.value_ptr.*) == .lt) continue;
            gop.value_ptr.* = matched;
            const value: ?[]const u8 = if (entry.value) |raw| try arena.dupe(u8, raw) else null;
            const origin = if (entry.subsection.len == 0)
                try arena.print("http.{s}", .{name})
            else
                try arena.print("http.{s}.{s}", .{ entry.subsection, name });
            if (std.mem.eql(u8, name, "proxy")) proxy_set = true;
            try s.take(arena, io, .{ .home = home, .base = sources.base }, name, value, origin, &headers);
        }
    }
    s.extra_headers = headers.items;

    if (config) |c| if (remote_name) |name| {
        const key = try arena.print("remote.{s}.proxy", .{name});
        if (c.get(key)) |raw| {
            s.proxy = try arena.dupe(u8, raw);
            proxy_set = true;
        }
    };
    if (environ) |env| try s.takeEnvironment(arena, env, url, proxy_set);
    if (s.proxy) |p| {
        if (p.len == 0) s.proxy = null;
    }
    return s;
}

const testing = std.testing;

test "the closest http.<url> section wins, and a looser one after it does not" {
    var config = try config_mod.Config.parseText(testing.allocator,
        \\[http]
        \\    proxy = http://everywhere:3128
        \\    extraHeader = X-A: 1
        \\[http "https://*.example.com"]
        \\    proxy = http://wild:3128
        \\[http "https://git.example.com/team"]
        \\    proxy = http://team:3128
        \\    sslCAInfo = /etc/team-ca.pem
        \\[http "https://git.example.com"]
        \\    proxy = http://host:3128
        \\    extraHeader = X-B: 2
        \\[http "https://other.example.com"]
        \\    proxy = http://never:3128
        \\
    , .local);
    defer config.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const team = try resolve(arena, testing.io, try url_mod.Url.parse("https://git.example.com/team/repo.git"), .{ .config = &config });
    try testing.expectEqualStrings("http://team:3128", team.proxy.?);
    try testing.expectEqualStrings("/etc/team-ca.pem", team.ca_info.?);
    try testing.expectEqualStrings("http.https://git.example.com/team.sslcainfo", team.ca_info_from.?);
    try testing.expectEqual(@as(usize, 2), team.extra_headers.len);

    const elsewhere = try resolve(arena, testing.io, try url_mod.Url.parse("https://git.example.com/solo/repo.git"), .{ .config = &config });
    try testing.expectEqualStrings("http://host:3128", elsewhere.proxy.?);
    try testing.expect(elsewhere.ca_info == null);

    const wild = try resolve(arena, testing.io, try url_mod.Url.parse("https://ci.example.com/repo.git"), .{ .config = &config });
    try testing.expectEqualStrings("http://wild:3128", wild.proxy.?);
    try testing.expectEqual(@as(usize, 1), wild.extra_headers.len);
}

test "http.followRedirects is read as git reads it: initial, a boolean, scoped by URL" {
    var config = try config_mod.Config.parseText(testing.allocator,
        \\[http]
        \\    followRedirects = true
        \\[http "https://git.example.com"]
        \\    followRedirects = false
        \\[http "https://initial.example.com"]
        \\    followRedirects = initial
        \\[http "https://bad.example.com"]
        \\    followRedirects = sometimes
        \\
    , .local);
    defer config.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(FollowRedirects.initial, (try resolve(arena, testing.io, try url_mod.Url.parse("https://a.example.com/r"), .{})).follow_redirects);
    try testing.expectEqual(FollowRedirects.always, (try resolve(arena, testing.io, try url_mod.Url.parse("https://a.example.com/r"), .{ .config = &config })).follow_redirects);
    try testing.expectEqual(FollowRedirects.never, (try resolve(arena, testing.io, try url_mod.Url.parse("https://git.example.com/r"), .{ .config = &config })).follow_redirects);
    try testing.expectEqual(FollowRedirects.initial, (try resolve(arena, testing.io, try url_mod.Url.parse("https://initial.example.com/r"), .{ .config = &config })).follow_redirects);
    try testing.expectError(error.InvalidHttpSetting, resolve(arena, testing.io, try url_mod.Url.parse("https://bad.example.com/r"), .{ .config = &config }));
}

test "the environment overrides the files, and no_proxy names hosts as curl reads it" {
    var config = try config_mod.Config.parseText(testing.allocator,
        \\[http]
        \\    sslCAInfo = /etc/from-config.pem
        \\
    , .local);
    defer config.deinit();
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_SSL_CAINFO", "/etc/from-env.pem");
    try env.put("HTTP_PROXY", "http://upper:3128");
    try env.put("https_proxy", "http://secure:3128");
    try env.put("no_proxy", "localhost,.internal.example.com");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try resolve(arena, testing.io, try url_mod.Url.parse("http://git.example.com/r.git"), .{ .config = &config, .environ = &env });
    try testing.expectEqualStrings("/etc/from-env.pem", plain.ca_info.?);
    // curl ignores an upper-case HTTP_PROXY, and so git does. On Windows a
    // variable's name has no case: `http_proxy` is the variable set as
    // `HTTP_PROXY`, and curl, asking for the one, is given the other.
    if (builtin.target.os.tag == .windows) {
        try testing.expectEqualStrings("http://upper:3128", plain.proxy.?);
    } else {
        try testing.expect(plain.proxy == null);
    }
    const secure = try resolve(arena, testing.io, try url_mod.Url.parse("https://git.example.com/r.git"), .{ .config = &config, .environ = &env });
    try testing.expectEqualStrings("http://secure:3128", secure.proxy.?);
    const inside = try resolve(arena, testing.io, try url_mod.Url.parse("https://git.internal.example.com/r.git"), .{ .config = &config, .environ = &env });
    try testing.expect(inside.proxy == null);
}

test "HTTP settings preserve allocation resource failures" {
    var config = try config_mod.Config.parseText(testing.allocator, "[http]\nproxy = http://proxy:3128\n", .local);
    defer config.deinit();
    var no_resize = shakedown.alloc.NoResize.init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), allocationSettings, .{&config});
}

fn allocationSettings(gpa: Allocator, config: *const config_mod.Config) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const settings = try resolve(arena.allocator(), testing.io, try url_mod.Url.parse("https://example.com/repo"), .{ .config = config });
    try testing.expectEqualStrings("http://proxy:3128", settings.proxy.?);
}

test "a remote's SOCKS proxy overrides http.proxy and remains subject to no_proxy" {
    var config = try config_mod.Config.parseText(testing.allocator, "[http]\nproxy = http://general:3128\n[remote \"origin\"]\nproxy = socks5h://specific\n[remote \"direct\"]\nproxy =\n", .local);
    defer config.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("all_proxy", "socks4a://environment");
    const url = try url_mod.Url.parse("https://git.example.com/repo.git");
    const named = try resolve(arena.allocator(), testing.io, url, .{ .config = &config, .environ = &env, .remote_name = "origin" });
    try testing.expectEqualStrings("socks5h://specific", named.proxy.?);
    const direct = try resolve(arena.allocator(), testing.io, url, .{ .config = &config, .environ = &env, .remote_name = "direct" });
    try testing.expect(direct.proxy == null);
    try env.put("no_proxy", ".example.com");
    const bypassed = try resolve(arena.allocator(), testing.io, url, .{ .config = &config, .environ = &env, .remote_name = "origin" });
    try testing.expect(bypassed.proxy == null);
}

test "a proxy the caller chooses stands over the configuration, the environment and no_proxy" {
    var config = try config_mod.Config.parseText(testing.allocator, "[http]\nproxy = http://general:3128\n[remote \"origin\"]\nproxy = socks5h://specific\n", .local);
    defer config.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("no_proxy", ".example.com");
    const url = try url_mod.Url.parse("https://git.example.com/repo.git");
    var s = try resolve(arena.allocator(), testing.io, url, .{ .config = &config, .environ = &env, .remote_name = "origin" });
    chooseProxy(&s, .auto);
    try testing.expect(s.proxy == null);
    chooseProxy(&s, .{ .url = "http://chosen:8080" });
    try testing.expectEqualStrings("http://chosen:8080", s.proxy.?);
    chooseProxy(&s, .none);
    try testing.expect(s.proxy == null);
    var t = try resolve(arena.allocator(), testing.io, url, .{ .config = &config, .environ = null, .remote_name = "origin" });
    try testing.expectEqualStrings("socks5h://specific", t.proxy.?);
    chooseProxy(&t, .none);
    try testing.expect(t.proxy == null);
    chooseProxy(&t, .{ .url = "" });
    try testing.expect(t.proxy == null);
}
