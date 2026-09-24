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
//! `https`, only the lower-case `http_proxy` for `http`, then `all_proxy`
//! or `ALL_PROXY` — unless `no_proxy` or `NO_PROXY` names the host. An
//! empty `http.proxy` turns every proxy off.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const config_mod = @import("config.zig");
const url_mod = @import("url.zig");

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
    /// Where each setting that was not the default came from, for a
    /// message: `http.https://git.example.com.sslcainfo` and the like.
    /// Only the TLS ones are kept.
    ca_info_from: ?[]const u8 = null,
    ssl_verify_from: ?[]const u8 = null,
};

/// Errors from reading the settings.
pub const Error = error{
    /// A value that does not parse: a `http.sslVerify` that is not a
    /// boolean, a `http.postBuffer` that is not a size.
    InvalidHttpSetting,
} || Allocator.Error;

/// The settings for `url`, from `config` and `environ`. Every slice is in
/// `arena`, or borrowed from `config` or `environ`.
pub fn resolve(arena: Allocator, config: ?*const config_mod.Config, environ: ?*const Environ.Map, url: url_mod.Url) Error!Settings {
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
            const value = config_mod.unquote(arena, raw) catch return error.InvalidHttpSetting;
            const origin = if (entry.subsection.len == 0)
                try std.fmt.allocPrint(arena, "http.{s}", .{name})
            else
                try std.fmt.allocPrint(arena, "http.{s}.{s}", .{ entry.subsection, name });
            if (std.mem.eql(u8, name, "proxy")) {
                s.proxy = value;
                proxy_set = true;
            } else if (std.mem.eql(u8, name, "sslverify")) {
                s.ssl_verify = if (entry.value == null) true else config_mod.parseBool(value) catch return error.InvalidHttpSetting;
                s.ssl_verify_from = origin;
            } else if (std.mem.eql(u8, name, "sslcainfo")) {
                s.ca_info = value;
                s.ca_info_from = origin;
            } else if (std.mem.eql(u8, name, "sslcapath")) {
                s.ca_path = value;
            } else if (std.mem.eql(u8, name, "sslcert")) {
                s.ssl_cert = value;
            } else if (std.mem.eql(u8, name, "sslkey")) {
                s.ssl_key = value;
            } else if (std.mem.eql(u8, name, "sslcerttype")) {
                s.ssl_cert_type = value;
            } else if (std.mem.eql(u8, name, "sslkeytype")) {
                s.ssl_key_type = value;
            } else if (std.mem.eql(u8, name, "proxysslcert")) {
                s.proxy_ssl_cert = value;
            } else if (std.mem.eql(u8, name, "proxysslkey")) {
                s.proxy_ssl_key = value;
            } else if (std.mem.eql(u8, name, "proxysslcainfo")) {
                s.proxy_ssl_ca_info = value;
            } else if (std.mem.eql(u8, name, "proxysslcertpasswordprotected")) {
                s.proxy_ssl_cert_password_protected = if (entry.value == null) true else config_mod.parseBool(value) catch return error.InvalidHttpSetting;
            } else if (std.mem.eql(u8, name, "extraheader")) {
                if (value.len == 0) headers.clearRetainingCapacity() else try headers.append(arena, value);
            } else if (std.mem.eql(u8, name, "postbuffer")) {
                const n = config_mod.parseInt(value) catch return error.InvalidHttpSetting;
                s.post_buffer = @intCast(std.math.clamp(n, 1024, 1 << 30));
            } else if (std.mem.eql(u8, name, "useragent")) {
                s.user_agent = value;
            } else if (std.mem.eql(u8, name, "proxyauthmethod")) {
                s.proxy_auth_method = value;
            } else if (std.mem.eql(u8, name, "sslcertpasswordprotected")) {
                s.ssl_cert_password_protected = if (entry.value == null) true else config_mod.parseBool(value) catch return error.InvalidHttpSetting;
            }
        }
    }
    s.extra_headers = headers.items;

    if (environ) |env| {
        if (env.get("GIT_SSL_NO_VERIFY") != null) {
            s.ssl_verify = false;
            s.ssl_verify_from = "GIT_SSL_NO_VERIFY";
        }
        if (env.get("GIT_SSL_CAINFO")) |v| {
            s.ca_info = v;
            s.ca_info_from = "GIT_SSL_CAINFO";
        }
        if (env.get("GIT_SSL_CAPATH")) |v| s.ca_path = v;
        if (env.get("GIT_SSL_CERT")) |v| s.ssl_cert = v;
        if (env.get("GIT_SSL_KEY")) |v| s.ssl_key = v;
        if (env.get("GIT_HTTP_USER_AGENT")) |v| s.user_agent = v;
        if (env.get("GIT_HTTP_PROXY_AUTHMETHOD")) |v| s.proxy_auth_method = v;
        if (env.get("GIT_SSL_CERT_TYPE")) |v| s.ssl_cert_type = v;
        if (env.get("GIT_SSL_KEY_TYPE")) |v| s.ssl_key_type = v;
        // Set at all, these turn the prompt on, whatever they say, as git
        // reads them — the first for an https URL only.
        if (env.get("GIT_SSL_CERT_PASSWORD_PROTECTED") != null and url.scheme == .https) s.ssl_cert_password_protected = true;
        if (env.get("GIT_PROXY_SSL_CERT")) |v| s.proxy_ssl_cert = v;
        if (env.get("GIT_PROXY_SSL_KEY")) |v| s.proxy_ssl_key = v;
        if (env.get("GIT_PROXY_SSL_CAINFO")) |v| s.proxy_ssl_ca_info = v;
        if (env.get("GIT_PROXY_SSL_CERT_PASSWORD_PROTECTED") != null) s.proxy_ssl_cert_password_protected = true;
        if (!proxy_set) {
            const names: []const []const u8 = if (url.scheme == .https)
                &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }
            else
                &.{ "http_proxy", "all_proxy", "ALL_PROXY" };
            for (names) |name| {
                const value = env.get(name) orelse continue;
                if (value.len == 0) continue;
                s.proxy = value;
                break;
            }
        }
        if (s.proxy) |_| {
            for ([_][]const u8{ "no_proxy", "NO_PROXY" }) |name| {
                const list = env.get(name) orelse continue;
                if (noProxy(list, url.host)) s.proxy = null;
                break;
            }
        }
    }
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

/// Whether a `no_proxy` list names `host`: `*`, the host itself, or a
/// domain it lies in, with or without a leading dot — curl's reading.
pub fn noProxy(list: []const u8, host: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, ", ");
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, "*")) return true;
        const domain = std.mem.trimStart(u8, entry, ".");
        if (std.ascii.eqlIgnoreCase(host, domain)) return true;
        if (host.len > domain.len and std.ascii.endsWithIgnoreCase(host, domain) and host[host.len - domain.len - 1] == '.') return true;
    }
    return false;
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
    // curl ignores an upper-case HTTP_PROXY, and so git does.
    try testing.expect(plain.proxy == null);
    const secure = try resolve(arena, &config, &env, try url_mod.Url.parse("https://git.example.com/r.git"));
    try testing.expectEqualStrings("http://secure:3128", secure.proxy.?);
    const inside = try resolve(arena, &config, &env, try url_mod.Url.parse("https://git.internal.example.com/r.git"));
    try testing.expect(inside.proxy == null);
    try testing.expect(noProxy("*", "anything"));
    try testing.expect(!noProxy("example.com", "badexample.com"));
}
