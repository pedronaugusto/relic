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

const config_mod = @import("../config.zig");
const url_mod = @import("url.zig");
const uplink = @import("../dependencies.zig").uplink;
const shakedown = @import("../dependencies.zig").shakedown;

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

    /// Take `http.<name>`'s `value`, from `origin`; `bare` when it is
    /// written without `=`, which a boolean reads as true.
    fn take(
        settings: *Settings,
        arena: Allocator,
        name: []const u8,
        value: []const u8,
        bare: bool,
        origin: []const u8,
        headers: *std.ArrayList([]const u8),
    ) Error!void {
        if (std.mem.eql(u8, name, "proxy")) {
            settings.proxy = value;
        } else if (std.mem.eql(u8, name, "sslverify")) {
            settings.ssl_verify = if (bare) true else config_mod.parseBool(value) catch return error.InvalidHttpSetting;
            settings.ssl_verify_from = origin;
        } else if (std.mem.eql(u8, name, "sslcainfo")) {
            settings.ca_info = value;
            settings.ca_info_from = origin;
        } else if (std.mem.eql(u8, name, "sslcapath")) {
            settings.ca_path = value;
        } else if (std.mem.eql(u8, name, "sslcert")) {
            settings.ssl_cert = value;
        } else if (std.mem.eql(u8, name, "sslkey")) {
            settings.ssl_key = value;
        } else if (std.mem.eql(u8, name, "sslcerttype")) {
            settings.ssl_cert_type = value;
        } else if (std.mem.eql(u8, name, "sslkeytype")) {
            settings.ssl_key_type = value;
        } else if (std.mem.eql(u8, name, "proxysslcert")) {
            settings.proxy_ssl_cert = value;
        } else if (std.mem.eql(u8, name, "proxysslkey")) {
            settings.proxy_ssl_key = value;
        } else if (std.mem.eql(u8, name, "proxysslcainfo")) {
            settings.proxy_ssl_ca_info = value;
        } else if (std.mem.eql(u8, name, "proxysslcertpasswordprotected")) {
            settings.proxy_ssl_cert_password_protected = if (bare) true else config_mod.parseBool(value) catch return error.InvalidHttpSetting;
        } else if (std.mem.eql(u8, name, "extraheader")) {
            if (value.len == 0) headers.clearRetainingCapacity() else try headers.append(arena, value);
        } else if (std.mem.eql(u8, name, "postbuffer")) {
            const n = config_mod.parseInt(value) catch return error.InvalidHttpSetting;
            settings.post_buffer = @intCast(std.math.clamp(n, 1024, 1 << 30));
        } else if (std.mem.eql(u8, name, "useragent")) {
            settings.user_agent = value;
        } else if (std.mem.eql(u8, name, "proxyauthmethod")) {
            settings.proxy_auth_method = value;
        } else if (std.mem.eql(u8, name, "followredirects")) {
            settings.follow_redirects = if (std.mem.eql(u8, value, "initial"))
                .initial
            else if (bare or (config_mod.parseBool(value) catch return error.InvalidHttpSetting))
                .always
            else
                .never;
        } else if (std.mem.eql(u8, name, "sslcertpasswordprotected")) {
            settings.ssl_cert_password_protected = if (bare) true else config_mod.parseBool(value) catch return error.InvalidHttpSetting;
        }
    }

    /// What the environment says over the configuration, as git reads it:
    /// `GIT_SSL_*`, `GIT_HTTP_*`, `GIT_PROXY_SSL_*`, and the proxy
    /// variables unless the configuration named a proxy, `no_proxy`
    /// turning a proxy off for the hosts it names.
    fn takeEnvironment(settings: *Settings, env: *const Environ.Map, url: url_mod.Url, proxy_set: bool) void {
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
        if (!proxy_set) settings.proxy = uplink.Proxy.environmentValue(env, url.scheme == .https, .curl);
        if (settings.proxy) |_| {
            const port = url.port orelse @as(u16, if (url.scheme == .https) 443 else 80);
            if (uplink.Proxy.bypassed(uplink.Proxy.noProxyValue(env, .curl), url.host, port, .curl)) settings.proxy = null;
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

/// Errors from reading the settings.
pub const Error = error{
    /// A value that does not parse: a `http.sslVerify` that is not a
    /// boolean, a `http.postBuffer` that is not a size.
    InvalidHttpSetting,
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

/// The settings for `url`, from `config` and `environ`. Every slice is in
/// `arena`, or borrowed from `config` or `environ`.
pub fn resolve(arena: Allocator, config: ?*const config_mod.Config, environ: ?*const Environ.Map, url: url_mod.Url) Self.Error!Settings {
    return resolveForRemote(arena, config, environ, url, null);
}

/// A named remote's proxy overrides `http.proxy`, including an empty value.
/// The environment's `no_proxy` still applies to that proxy.
pub fn resolveForRemote(arena: Allocator, config: ?*const config_mod.Config, environ: ?*const Environ.Map, url: url_mod.Url, remote_name: ?[]const u8) Self.Error!Settings {
    var s: Settings = .{};
    var headers: std.ArrayList([]const u8) = .empty;
    var proxy_set = false;
    if (config) |c| {
        var best: std.StringHashMapUnmanaged(Score) = .empty;
        for (c.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "http")) continue;
            const score = if (entry.subsection.len == 0) Score.none else scoreOf(entry.subsection, url) orelse continue;
            const name = try std.ascii.allocLowerString(arena, entry.name);
            const gop = try best.getOrPut(arena, name);
            if (gop.found_existing and score.lessThan(gop.value_ptr.*)) continue;
            gop.value_ptr.* = score;
            const raw = entry.value orelse "";
            const value = try arena.dupe(u8, raw);
            const origin = if (entry.subsection.len == 0)
                try arena.print("http.{s}", .{name})
            else
                try arena.print("http.{s}.{s}", .{ entry.subsection, name });
            if (std.mem.eql(u8, name, "proxy")) proxy_set = true;
            try s.take(arena, name, value, entry.value == null, origin, &headers);
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
    if (environ) |env| s.takeEnvironment(env, url, proxy_set);
    if (s.proxy) |p| {
        if (p.len == 0) s.proxy = null;
    }
    return s;
}

/// How closely a pattern matched: git's `urlmatch` ordering.
const Score = struct {
    matched: bool,
    exact_host: bool = false,
    host_len: usize = 0,
    path_len: usize = 0,
    user: bool = false,

    const none: Score = .{ .matched = false };

    fn lessThan(a: Score, b: Score) bool {
        if (a.matched != b.matched) return !a.matched;
        if (a.exact_host != b.exact_host) return !a.exact_host;
        if (a.host_len != b.host_len) return a.host_len < b.host_len;
        if (a.path_len != b.path_len) return a.path_len < b.path_len;
        if (a.user != b.user) return !a.user;
        return false;
    }
};

/// How `pattern` matches `url`, or `null` when it does not.
fn scoreOf(pattern: []const u8, url: url_mod.Url) ?Score {
    const parsed = url_mod.Url.parse(pattern) catch return null;
    if (parsed.scheme != url.scheme) return null;
    var score: Score = .{ .matched = true };
    if (parsed.user) |user| {
        const theirs = url.user orelse return null;
        if (!std.mem.eql(u8, user, theirs)) return null;
        score.user = true;
    }
    var p = std.mem.splitScalar(u8, parsed.host, '.');
    var h = std.mem.splitScalar(u8, url.host, '.');
    score.exact_host = true;
    while (true) {
        const a = p.next();
        const b = h.next();
        if (a == null and b == null) break;
        if (a == null or b == null) return null;
        if (std.mem.eql(u8, a.?, "*")) {
            score.exact_host = false;
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(a.?, b.?)) return null;
    }
    score.host_len = parsed.host.len;
    const default_port: u16 = if (url.scheme == .https) 443 else 80;
    if ((parsed.port orelse default_port) != (url.port orelse default_port)) return null;
    const want = std.mem.trimEnd(u8, parsed.path, "/");
    if (want.len != 0) {
        if (!std.mem.startsWith(u8, url.path, want)) return null;
        if (url.path.len != want.len and url.path[want.len] != '/') return null;
    }
    score.path_len = want.len;
    return score;
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

    const team = try resolve(arena, &config, null, try url_mod.Url.parse("https://git.example.com/team/repo.git"));
    try testing.expectEqualStrings("http://team:3128", team.proxy.?);
    try testing.expectEqualStrings("/etc/team-ca.pem", team.ca_info.?);
    try testing.expectEqualStrings("http.https://git.example.com/team.sslcainfo", team.ca_info_from.?);
    try testing.expectEqual(@as(usize, 2), team.extra_headers.len);

    const elsewhere = try resolve(arena, &config, null, try url_mod.Url.parse("https://git.example.com/solo/repo.git"));
    try testing.expectEqualStrings("http://host:3128", elsewhere.proxy.?);
    try testing.expect(elsewhere.ca_info == null);

    const wild = try resolve(arena, &config, null, try url_mod.Url.parse("https://ci.example.com/repo.git"));
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
    try testing.expectEqual(FollowRedirects.initial, (try resolve(arena, null, null, try url_mod.Url.parse("https://a.example.com/r"))).follow_redirects);
    try testing.expectEqual(FollowRedirects.always, (try resolve(arena, &config, null, try url_mod.Url.parse("https://a.example.com/r"))).follow_redirects);
    try testing.expectEqual(FollowRedirects.never, (try resolve(arena, &config, null, try url_mod.Url.parse("https://git.example.com/r"))).follow_redirects);
    try testing.expectEqual(FollowRedirects.initial, (try resolve(arena, &config, null, try url_mod.Url.parse("https://initial.example.com/r"))).follow_redirects);
    try testing.expectError(error.InvalidHttpSetting, resolve(arena, &config, null, try url_mod.Url.parse("https://bad.example.com/r")));
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

    const plain = try resolve(arena, &config, &env, try url_mod.Url.parse("http://git.example.com/r.git"));
    try testing.expectEqualStrings("/etc/from-env.pem", plain.ca_info.?);
    // curl ignores an upper-case HTTP_PROXY, and so git does. On Windows a
    // variable's name has no case: `http_proxy` is the variable set as
    // `HTTP_PROXY`, and curl, asking for the one, is given the other.
    if (builtin.target.os.tag == .windows) {
        try testing.expectEqualStrings("http://upper:3128", plain.proxy.?);
    } else {
        try testing.expect(plain.proxy == null);
    }
    const secure = try resolve(arena, &config, &env, try url_mod.Url.parse("https://git.example.com/r.git"));
    try testing.expectEqualStrings("http://secure:3128", secure.proxy.?);
    const inside = try resolve(arena, &config, &env, try url_mod.Url.parse("https://git.internal.example.com/r.git"));
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
    const settings = try resolve(arena.allocator(), config, null, try url_mod.Url.parse("https://example.com/repo"));
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
    const named = try resolveForRemote(arena.allocator(), &config, &env, url, "origin");
    try testing.expectEqualStrings("socks5h://specific", named.proxy.?);
    const direct = try resolveForRemote(arena.allocator(), &config, &env, url, "direct");
    try testing.expect(direct.proxy == null);
    try env.put("no_proxy", ".example.com");
    const bypassed = try resolveForRemote(arena.allocator(), &config, &env, url, "origin");
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
    var s = try resolveForRemote(arena.allocator(), &config, &env, url, "origin");
    chooseProxy(&s, .auto);
    try testing.expect(s.proxy == null);
    chooseProxy(&s, .{ .url = "http://chosen:8080" });
    try testing.expectEqualStrings("http://chosen:8080", s.proxy.?);
    chooseProxy(&s, .none);
    try testing.expect(s.proxy == null);
    var t = try resolveForRemote(arena.allocator(), &config, null, url, "origin");
    try testing.expectEqualStrings("socks5h://specific", t.proxy.?);
    chooseProxy(&t, .none);
    try testing.expect(t.proxy == null);
    chooseProxy(&t, .{ .url = "" });
    try testing.expect(t.proxy == null);
}
