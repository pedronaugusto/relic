//! The Git LFS server a remote has, and how it is reached: where its API is,
//! who the person is to it, and the HTTP requests that carry both.
//!
//! Where the API is follows git-lfs's own search, because a repository set up
//! for git-lfs has to find the same server here: `lfs.pushurl` for an upload,
//! then `lfs.url`, then the remote's `lfspushurl` and `lfsurl`, then the
//! remote's own URL with `.git/info/lfs` added — `/info/lfs` when it already
//! ends in `.git`. Every URL is rewritten by `url.<base>.insteadOf` first.
//! `.lfsconfig` at the top of the working tree may set a few of these where
//! the configuration does not, the same few git-lfs lets it set, because the
//! file arrives with the repository and is not the person's. A remote reached
//! over ssh has its API at `https://<host><path>` unless the server says
//! otherwise: `ssh <host> git-lfs-authenticate <path> <operation>`, run with
//! the person's own ssh through `program.zig`, answers with the URL to use and
//! a header that authenticates to it. Before that, as git-lfs does unless
//! `lfs.<url>.sshtransfer` says `never`, `ssh <host> git-lfs-transfer <path>
//! <operation>` is tried, and a server that speaks it moves the objects and
//! the locks over ssh alone (`lfsssh.zig`). A repository on this machine has
//! no API at all; its objects are copied between the two stores.
//!
//! Who the person is follows git-lfs too. A request goes out without
//! credentials unless `lfs.<url>.access` says `basic`; a 401 turns basic on for
//! that URL, as git-lfs turns it on, and the request is made again with a
//! credential from the person's helpers through `credential.zig`. When the API
//! is on the host the remote itself is on, the credential asked for is the
//! remote's, so the one git already uses is the one found. A credential that
//! works is stored once and one that is refused is erased. What the server
//! taught — that a URL wants credentials, that it has no locking API — is kept
//! for the rest of the `Client`'s life and handed back in `learned`, under the
//! keys git-lfs writes, so a caller that wants git-lfs's habit of writing them
//! to the repository's configuration can: `Client.remember` does.
//!
//! The connection settings are git's where git-lfs reads them as git does,
//! and git-lfs's where it does not. The TLS ones — `http.sslVerify`,
//! `http.sslCAInfo`, `http.sslCAPath`, `http.sslCert`, `http.sslKey` and
//! their environment variables — come from `httpsettings.zig` for each
//! request's URL, as `smarthttp` takes them, and the connections are
//! relic's own (`httpclient.zig`): TLS inside a proxy's tunnel, a server
//! left unchecked where the settings say so. A client certificate is
//! refused by name, as `smarthttp` refuses it. The rest are git-lfs's own:
//! `http.extraHeader` is the values of the one best-matching
//! `http.<url>.extraHeader` key, by git-lfs's URL match, where git gathers
//! every matching key's and lets an empty one clear the list; the proxy
//! follows git-lfs's order (`proxyFor`), which is not curl's, and a tunnel
//! is asked for in Go's words; the timeouts are `lfs.dialtimeout`,
//! `lfs.tlstimeout` and `lfs.activitytimeout`, as git-lfs applies them
//! (`timeoutsFor`), and as many connections are kept as transfers run at
//! once; and the user agent is git-lfs's, which `http.userAgent` does not
//! change. The
//! credential helpers are asked as git asks them (`credential.zig`), with
//! the server's `LFS-Authenticate` and `WWW-Authenticate` values as
//! `wwwauth[]` unless `credential.<url>.skipwwwauth` says not to, which is
//! git-lfs's; where git-lfs's own conversation differs — it announces its
//! capabilities to a helper's `store` and `erase` too, and writes the keys
//! in no fixed order — git's is kept. A request that fails for want of a
//! credential, or that the server forbids, is described in
//! `Options.auth_failure`.
//!
//! relic reads no clock of its own. An action or a token the server says will
//! expire is not checked against one; a request refused because one has is
//! retried with a fresh batch, which is how git-lfs retries every failed
//! transfer anyway. Certificates to trust from `http.sslCAInfo` are checked
//! against the time when they are loaded, as `smarthttp` checks them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const config_mod = @import("config.zig");
const program = @import("program.zig");
const credential = @import("credential.zig");
const auth_mod = @import("auth.zig");
const httpsettings = @import("httpsettings.zig");
const url_mod = @import("url.zig");
const remote_mod = @import("remote.zig");
const repo_mod = @import("repo.zig");
const lfs = @import("lfs.zig");
const mimesniff = @import("mimesniff.zig");
const fs = @import("fs.zig");
const object = @import("object.zig");
const netrc_mod = @import("netrc.zig");
const timetext = @import("timetext.zig");
const lfsssh = @import("lfsssh.zig");
const httpclient = @import("httpclient.zig");

const Config = config_mod.Config;

/// What a request is for. The API has one endpoint for each, and git-lfs's
/// `lfs.pushurl` and `lfspushurl` apply to `upload` alone.
pub const Operation = enum {
    download,
    upload,
};

/// What the client calls itself. A server that treats git-lfs specially looks
/// for the `git-lfs/` in front.
pub const user_agent = "git-lfs/3 (relic)";

/// The widest zstd window a download is decoded with: git-lfs's decoder's
/// own limit, 512 MiB.
pub const zstd_window_max: u64 = 512 << 20;

/// The media type of the API's requests and answers.
pub const media_type = "application/vnd.git-lfs+json";

/// Errors from finding a server and talking to it.
pub const Error = error{
    /// There is no URL to find the server from: no `lfs.url`, no remote of
    /// that name with a URL, and the name is not a URL itself.
    LfsEndpointUnknown,
    /// `lfs.<url>.sshtransfer` is neither `negotiate` nor `never` — git-lfs
    /// takes `always` to mean the pure-ssh protocol and nothing else — and
    /// the pure-ssh protocol did not start. `Client.message` holds what ssh
    /// said.
    LfsAuthenticateDisabled,
    /// `git-lfs-authenticate` over ssh failed, after git-lfs's retries.
    /// `Client.message` holds what it said.
    LfsAuthenticateFailed,
    /// `lfs.<url>.access` asks for, or the server offers only, an
    /// authentication scheme other than basic: `negotiate` or `ntlm`.
    LfsAccessUnsupported,
    /// The server refused every credential. `Client.message` holds its
    /// reason.
    AuthenticationFailed,
    /// An answer that is not what the API sends: JSON that does not parse,
    /// a hash algorithm other than SHA-256, a content type that is not the
    /// API's.
    MalformedResponse,
    /// A status the operation cannot go past. `Client.message` holds it and
    /// the server's reason.
    HttpStatus,
    /// The server's own URL does not parse, or names no host.
    MalformedUrl,
    /// A redirect from `https` to `http`, which git-lfs refuses too.
    InsecureRedirect,
    /// More than three redirects of one request.
    TooManyRedirects,
    /// The connection failed, or broke. `Client.message` holds why.
    ConnectionFailed,
    /// `http.sslCert` or `http.sslKey`: the standard library's TLS client,
    /// which relic's connections speak TLS through, answers no server's
    /// request for a client certificate.
    SslClientCertificateUnsupported,
    /// `http.sslCAInfo` or `http.sslCAPath` names a file or directory that
    /// could not be read as certificates.
    SslCertificateUnreadable,
    /// An `http.*` value that does not parse.
    InvalidHttpSetting,
    /// A header from the configuration or from the server holds a line
    /// break, or has no name.
    InvalidHttpHeader,
    /// A proxy that does not parse, or that is not an HTTP proxy.
    InvalidProxy,
    /// ssh is a program, and the caller handed in no `program.Programs`.
    ProgramsNotGranted,
    /// A configuration value that does not unquote.
    MalformedValue,
    /// An answer larger than the operation reads.
    StreamTooLong,
    /// A zstd body whose frame asks for a window wider than
    /// `zstd_window_max`, which git-lfs's decoder refuses too.
    LfsZstdWindowTooLarge,
} || credential.Error || lfsssh.Error || Allocator.Error || Io.Cancelable;

//=====================================================================
// Settings
//=====================================================================

/// git-lfs's configuration: the repository's, and what `.lfsconfig` adds
/// where the repository's says nothing.
pub const Settings = struct {
    gpa: Allocator,
    config: *const Config,
    /// `.lfsconfig` from the top of the working tree. Only the keys git-lfs
    /// takes from it are read from it.
    file: ?Config = null,

    /// The keys `.lfsconfig` may set. Anything else in it is ignored, as
    /// git-lfs ignores it: the file comes with the repository.
    pub const file_keys = [_][]const u8{
        "lfs.allowincompletepush",
        "lfs.fetchexclude",
        "lfs.fetchinclude",
        "lfs.gitprotocol",
        "lfs.locksverify",
        "lfs.pushurl",
        "lfs.skipdownloaderrors",
        "lfs.url",
    };

    /// Errors from reading `.lfsconfig`.
    pub const LoadError = Allocator.Error || Io.Dir.ReadFileAllocError || config_mod.ParseError;

    /// Read `.lfsconfig` from `work_dir`, if there is one. `config` is
    /// borrowed for as long as the settings live.
    pub fn load(gpa: Allocator, io: Io, config: *const Config, work_dir: ?Io.Dir) LoadError!Settings {
        var s: Settings = .{ .gpa = gpa, .config = config };
        const wd = work_dir orelse return s;
        const text = (try fs.readFileAlloc(gpa, io, wd, ".lfsconfig", 1 << 20)) orelse return s;
        defer gpa.free(text);
        s.file = try Config.parseText(gpa, text, .local);
        return s;
    }

    /// The settings of `repo`, with `.lfsconfig` found where git-lfs finds
    /// it: `Repository.lfsconfigText`. `repo`'s configuration is borrowed.
    pub fn loadRepo(gpa: Allocator, io: Io, repo: *repo_mod.Repository) (LoadError || LfsconfigError)!Settings {
        var s: Settings = .{ .gpa = gpa, .config = &repo.config };
        const text = (try repo.lfsconfigText(io)) orelse return s;
        defer repo.gpa.free(text);
        s.file = try Config.parseText(gpa, text, .local);
        return s;
    }

    /// Release `.lfsconfig`. The configuration is the caller's.
    pub fn deinit(s: *Settings) void {
        if (s.file) |*f| f.deinit();
        s.* = undefined;
    }

    fn fileMayHold(entry: config_mod.Entry) bool {
        if (entry.subsection.len != 0) {
            // `remote.<name>.lfsurl` and `<section>.<url>.access`.
            if (std.ascii.eqlIgnoreCase(entry.section, "remote")) return std.ascii.eqlIgnoreCase(entry.name, "lfsurl");
            return std.ascii.eqlIgnoreCase(entry.name, "access");
        }
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ entry.section, entry.name }) catch return false;
        for (file_keys) |safe| {
            if (std.ascii.eqlIgnoreCase(safe, key)) return true;
        }
        return false;
    }

    fn lastEntry(s: *const Settings, full_name: []const u8) ?config_mod.Entry {
        if (s.config.find(full_name)) |entry| return entry;
        const file = if (s.file) |*f| f else return null;
        const split = config_mod.splitFullName(full_name) orelse return null;
        var found: ?config_mod.Entry = null;
        for (file.entries.items) |entry| {
            if (!entry.matches(split.section, split.subsection, split.name)) continue;
            if (!fileMayHold(entry)) continue;
            found = entry;
        }
        return found;
    }

    /// The value of `full_name`, unquoted into `a`: the configuration's
    /// last, else `.lfsconfig`'s.
    pub fn get(s: *const Settings, a: Allocator, full_name: []const u8) Error!?[]const u8 {
        const entry = s.lastEntry(full_name) orelse return null;
        return try unquoteValue(a, entry.value orelse "");
    }

    /// The value of `full_name` as a boolean, or `fallback` when it is not
    /// set or is not one.
    pub fn getBool(s: *const Settings, full_name: []const u8, fallback: bool) bool {
        const entry = s.lastEntry(full_name) orelse return fallback;
        const raw = entry.value orelse return true;
        var sfa = std.heap.stackFallback(1024, s.gpa);
        const a = sfa.get();
        const text = config_mod.unquote(a, raw) catch return fallback;
        defer a.free(text);
        return config_mod.parseBool(text) catch fallback;
    }

    /// The value of `full_name` as an integer, or `fallback` when it is not
    /// set or is not one.
    pub fn getInt(s: *const Settings, full_name: []const u8, fallback: i64) i64 {
        const entry = s.lastEntry(full_name) orelse return fallback;
        var sfa = std.heap.stackFallback(1024, s.gpa);
        const a = sfa.get();
        const text = config_mod.unquote(a, entry.value orelse "") catch return fallback;
        defer a.free(text);
        return config_mod.parseInt(text) catch fallback;
    }

    /// git-lfs's URL-scoped lookup: `<section>.<url>.<key>` for the
    /// configured URL that matches `url` best, else `<section>.<key>`. Every
    /// value of the winning key, oldest first, unquoted into `a`. A
    /// `section` with a dot in it, as `lfs.transfer`, is a section and the
    /// start of the subsection the URL follows.
    pub fn urlGetAll(s: *const Settings, a: Allocator, full_section: []const u8, url: []const u8, key: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const dot = std.mem.indexOfScalar(u8, full_section, '.');
        const section = full_section[0 .. dot orelse full_section.len];
        const prefix: ?[]const u8 = if (dot) |d| full_section[d + 1 ..] else null;
        const sources = [_]?*const Config{ s.config, if (s.file) |*f| f else null };
        for (sources, 0..) |maybe, source_index| {
            const config = maybe orelse continue;
            const best = bestUrlMatch(config, section, prefix, url, key, source_index == 1);
            if (best) |subsection| {
                for (config.entries.items) |entry| {
                    if (!entry.matches(section, subsection, key)) continue;
                    if (source_index == 1 and !fileMayHold(entry)) continue;
                    try out.append(a, try unquoteValue(a, entry.value orelse ""));
                }
                return out.items;
            }
        }
        for (sources, 0..) |maybe, source_index| {
            const config = maybe orelse continue;
            for (config.entries.items) |entry| {
                if (!entry.matches(section, prefix, key)) continue;
                if (source_index == 1 and !fileMayHold(entry)) continue;
                try out.append(a, try unquoteValue(a, entry.value orelse ""));
            }
            if (out.items.len != 0) return out.items;
        }
        return out.items;
    }

    /// The last value `urlGetAll` would give, or `null`.
    pub fn urlGet(s: *const Settings, a: Allocator, section: []const u8, url: []const u8, key: []const u8) Error!?[]const u8 {
        const values = try s.urlGetAll(a, section, url, key);
        return if (values.len == 0) null else values[values.len - 1];
    }
};

/// Errors from finding `.lfsconfig`.
pub const LfsconfigError = repo_mod.Repository.LfsconfigError;

fn unquoteValue(a: Allocator, raw: []const u8) Error![]const u8 {
    return config_mod.unquote(a, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    };
}

//=====================================================================
// URLs, matched as git-lfs matches them
//=====================================================================

/// A URL split the way Go's `net/url` splits one, which is what git-lfs's
/// URL-scoped settings are matched with. Every slice borrows the text.
pub const UrlParts = struct {
    scheme: []const u8,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// `host[:port]` as written.
    authority: []const u8,
    /// The host without its port or brackets.
    host: []const u8,
    port: ?[]const u8 = null,
    /// The path, without a query or a fragment.
    path: []const u8,

    /// Split `text`, or `null` when it has no scheme.
    pub fn parse(text: []const u8) ?UrlParts {
        const sep = std.mem.indexOf(u8, text, "://") orelse return null;
        if (sep == 0) return null;
        for (text[0..sep]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
        }
        var parts: UrlParts = .{ .scheme = text[0..sep], .authority = "", .host = "", .path = "" };
        const rest = text[sep + 3 ..];
        const path_at = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var authority = rest[0..path_at];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            const userinfo = authority[0..at];
            authority = authority[at + 1 ..];
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                parts.user = userinfo[0..colon];
                parts.password = userinfo[colon + 1 ..];
            } else parts.user = userinfo;
        }
        parts.authority = authority;
        if (authority.len != 0 and authority[0] == '[') {
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
            parts.host = authority[1..close];
            const after = authority[close + 1 ..];
            if (after.len > 1 and after[0] == ':') parts.port = after[1..];
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            parts.host = authority[0..colon];
            if (colon + 1 < authority.len) parts.port = authority[colon + 1 ..];
        } else parts.host = authority;
        const tail = rest[path_at..];
        const end = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
        parts.path = tail[0..end];
        return parts;
    }

    /// The port, or the scheme's own.
    pub fn effectivePort(p: UrlParts) []const u8 {
        if (p.port) |port| return port;
        if (std.ascii.eqlIgnoreCase(p.scheme, "http")) return "80";
        if (std.ascii.eqlIgnoreCase(p.scheme, "https")) return "443";
        if (std.ascii.eqlIgnoreCase(p.scheme, "ssh")) return "22";
        return "";
    }
};

/// The subsection of the `<section>.<url>.<key>` that matches `url` best, by
/// git-lfs's rules: the scheme exactly, the host exactly or by `*` labels —
/// an exact label beating a wildcard — the port, the path by whole
/// components, and a user when the configured URL names one.
fn bestUrlMatch(config: *const Config, section: []const u8, prefix: ?[]const u8, url: []const u8, key: []const u8, from_file: bool) ?[]const u8 {
    const search = UrlParts.parse(url) orelse return null;
    var best: ?[]const u8 = null;
    var best_host: usize = 0;
    var best_path: usize = 0;
    var best_user: u1 = 0;
    for (config.entries.items) |entry| {
        if (entry.subsection.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(entry.section, section)) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, key)) continue;
        if (from_file and !Settings.fileMayHold(entry)) continue;
        var configured_url = entry.subsection;
        if (prefix) |p| {
            if (configured_url.len <= p.len or !std.mem.startsWith(u8, configured_url, p) or configured_url[p.len] != '.') continue;
            configured_url = configured_url[p.len + 1 ..];
        }
        const configured = UrlParts.parse(configured_url) orelse continue;
        if (!std.mem.eql(u8, search.scheme, configured.scheme)) continue;
        const host_score = compareHosts(search.host, configured.host);
        if (host_score == 0 or host_score < best_host) continue;
        if (!std.mem.eql(u8, search.effectivePort(), configured.effectivePort())) continue;
        const path_score = comparePaths(search.path, configured.path);
        if (path_score == 0) continue;
        var user: u1 = 0;
        if (configured.user) |want| {
            const have = search.user orelse continue;
            if (!std.mem.eql(u8, want, have)) continue;
            user = 1;
        }
        if (best == null or host_score > best_host or path_score > best_path or
            (path_score == best_path and user > best_user))
        {
            best = entry.subsection;
            best_host = host_score;
            best_path = path_score;
            best_user = user;
        }
    }
    return best;
}

fn compareHosts(search: []const u8, configured: []const u8) usize {
    const count = std.mem.count(u8, search, ".") + 1;
    if (std.mem.count(u8, configured, ".") + 1 != count) return 0;
    var score = count + 1;
    var s = std.mem.splitScalar(u8, search, '.');
    var c = std.mem.splitScalar(u8, configured, '.');
    while (s.next()) |label| {
        const want = c.next().?;
        if (std.mem.eql(u8, want, "*")) {
            score -= 1;
            continue;
        }
        if (!std.mem.eql(u8, label, want)) return 0;
    }
    return score;
}

/// Path components compared in order, each exact match worth two; a
/// `repo.git` followed by `info/lfs` matches a configured `repo` for one.
fn comparePaths(search_path: []const u8, configured_path: []const u8) usize {
    var search_parts: [64][]const u8 = undefined;
    var search_len: usize = 0;
    var it = std.mem.tokenizeScalar(u8, search_path, '/');
    while (it.next()) |part| {
        if (search_len == search_parts.len) return 0;
        search_parts[search_len] = part;
        search_len += 1;
    }
    var score: usize = 1;
    var i: usize = 0;
    var cit = std.mem.tokenizeScalar(u8, configured_path, '/');
    while (cit.next()) |element| : (i += 1) {
        if (i >= search_len) return 0;
        const found = search_parts[i];
        if (std.mem.eql(u8, element, found)) {
            score += 2;
            continue;
        }
        if (found.len >= 5 and std.mem.endsWith(u8, found, ".git") and i + 2 < search_len and
            std.mem.eql(u8, search_parts[i + 1], "info") and std.mem.eql(u8, search_parts[i + 2], "lfs") and
            std.mem.eql(u8, found[0 .. found.len - 4], element))
        {
            score += 1;
            continue;
        }
        return 0;
    }
    return score;
}

//=====================================================================
// Where the API is
//=====================================================================

/// Where a remote's LFS API is.
pub const Endpoint = struct {
    /// The API's URL: `https://host/repo.git/info/lfs` and the like, or a
    /// `file://` URL naming a repository on this machine, which has no API.
    url: []const u8,
    /// How `git-lfs-authenticate` is reached, for a remote reached over
    /// ssh.
    ssh: ?Ssh = null,
    /// The URL the endpoint was found from, before `.git/info/lfs` was
    /// added: what `lfs.<url>.sshtransfer` is matched against.
    original: []const u8,

    /// An ssh remote's host and path.
    pub const Ssh = struct {
        /// `user@host`, or `host`.
        user_and_host: []const u8,
        port: ?[]const u8 = null,
        /// What `git-lfs-authenticate` is given.
        path: []const u8,
    };

    /// Whether the endpoint is a repository on this machine.
    pub fn isLocal(e: Endpoint) bool {
        return std.mem.startsWith(u8, e.url, "file://");
    }

    /// The path of a repository on this machine, from its `file://` URL.
    pub fn localPath(e: Endpoint) ?[]const u8 {
        if (!e.isLocal()) return null;
        return e.url["file://".len..];
    }
};

/// What finding an endpoint may need besides the settings.
pub const Where = struct {
    /// The absolute path a relative local path is taken against: the
    /// working tree, or the repository of a bare one.
    base: ?[]const u8 = null,
    /// The repository's `FETCH_HEAD`, whose first line names the URL last
    /// fetched from: git-lfs's last resort for `origin`.
    fetch_head: ?[]const u8 = null,
};

/// Find the endpoint of `remote` — a remote's name or a URL — for
/// `operation`, as git-lfs finds it. Everything is allocated in `arena`.
pub fn findEndpoint(
    arena: Allocator,
    settings: *const Settings,
    remote: []const u8,
    operation: Operation,
    where: Where,
) Error!Endpoint {
    if (operation == .upload) {
        if (try settings.get(arena, "lfs.pushurl")) |u| return newEndpoint(arena, settings, operation, u, where.base);
    }
    if (try settings.get(arena, "lfs.url")) |u| return newEndpoint(arena, settings, operation, u, where.base);
    if (!std.mem.eql(u8, remote, "origin")) {
        if (try remoteEndpoint(arena, settings, remote, operation, where.base)) |e| return e;
    }
    if (try remoteEndpoint(arena, settings, "origin", operation, where.base)) |e| return e;
    // Nothing configured: the URL `FETCH_HEAD` says was last fetched from,
    // as a download endpoint whatever the operation, which is what
    // git-lfs does.
    if (where.fetch_head) |text| {
        if (fetchHeadUrl(text)) |u| return endpointFromCloneUrl(arena, settings, .download, u, where.base);
    }
    return error.LfsEndpointUnknown;
}

/// The URL on the first line of `FETCH_HEAD`, as git-lfs's pattern reads it:
/// an object name, an optional `not-for-merge`, and `'<ref>' of <url>` after
/// an optional `branch ` or `tag `; a URL of letters, digits and `/.-:_`.
pub fn fetchHeadUrl(text: []const u8) ?[]const u8 {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    var fields = std.mem.splitScalar(u8, line, '\t');
    const oid = fields.next() orelse return null;
    if (oid.len < 40 or oid.len > 64) return null;
    for (oid) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    const merge = fields.next() orelse return null;
    if (merge.len != 0 and !std.mem.eql(u8, merge, "not-for-merge")) return null;
    var rest = fields.rest();
    if (std.mem.startsWith(u8, rest, "branch ")) rest = rest["branch ".len..] else if (std.mem.startsWith(u8, rest, "tag ")) rest = rest["tag ".len..];
    if (rest.len == 0 or rest[0] != '\'') return null;
    const at = std.mem.lastIndexOf(u8, rest, "' of ") orelse return null;
    const url = std.mem.trim(u8, rest[at + "' of ".len ..], " \t\r");
    if (url.len == 0) return null;
    for (url) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/.-:_", c) == null) return null;
    }
    return url;
}

/// The remote git-lfs uses when none is named: for a download the branch's
/// `remote`, else `remote.lfsdefault`, else the only remote there is, else
/// `origin`; for an upload the branch's `pushRemote`, else
/// `remote.lfspushdefault`, else `remote.pushDefault`, else the download's.
/// `branch` is the branch `HEAD` is on, without `refs/heads/`.
pub fn defaultRemote(arena: Allocator, settings: *const Settings, branch: ?[]const u8, operation: Operation) Error![]const u8 {
    if (operation == .upload) {
        if (branch) |b| {
            if (try settings.get(arena, try std.fmt.allocPrint(arena, "branch.{s}.pushremote", .{b}))) |r| return r;
        }
        if (try settings.get(arena, "remote.lfspushdefault")) |r| return r;
        if (try settings.get(arena, "remote.pushdefault")) |r| return r;
    }
    if (branch) |b| {
        if (try settings.get(arena, try std.fmt.allocPrint(arena, "branch.{s}.remote", .{b}))) |r| return r;
    }
    if (try settings.get(arena, "remote.lfsdefault")) |r| return r;
    const names = try remote_mod.names(arena, settings.config);
    if (names.len == 1) return names[0];
    return "origin";
}

fn remoteEndpoint(arena: Allocator, settings: *const Settings, remote: []const u8, operation: Operation, base: ?[]const u8) Error!?Endpoint {
    if (operation == .upload) {
        const key = try std.fmt.allocPrint(arena, "remote.{s}.lfspushurl", .{remote});
        if (try settings.get(arena, key)) |u| return try newEndpoint(arena, settings, operation, u, base);
    }
    const key = try std.fmt.allocPrint(arena, "remote.{s}.lfsurl", .{remote});
    if (try settings.get(arena, key)) |u| return try newEndpoint(arena, settings, operation, u, base);
    const git_url = (try gitRemoteUrl(arena, settings, remote, operation == .upload)) orelse return null;
    return try endpointFromCloneUrl(arena, settings, operation, git_url, base);
}

/// The remote's own URL, as git-lfs asks for it: `pushurl` for a push, else
/// `url`, else the name itself when it is a URL.
pub fn gitRemoteUrl(arena: Allocator, settings: *const Settings, remote: []const u8, for_push: bool) Error!?[]const u8 {
    if (for_push) {
        const key = try std.fmt.allocPrint(arena, "remote.{s}.pushurl", .{remote});
        if (try settings.get(arena, key)) |u| return u;
    }
    const key = try std.fmt.allocPrint(arena, "remote.{s}.url", .{remote});
    if (try settings.get(arena, key)) |u| return u;
    // A name with a scheme, or with a colon as the scp-like form has one,
    // is a URL git-lfs takes as given.
    if (std.mem.indexOf(u8, remote, "://") != null) return remote;
    if (std.mem.indexOfScalar(u8, remote, ':') != null) return remote;
    if (std.mem.indexOfScalar(u8, remote, '/') != null) return remote;
    return null;
}

/// git-lfs's `NewEndpointFromCloneURL`: the endpoint, with `.git/info/lfs`
/// — or `/info/lfs` after a `.git` — added to anything but a local path.
fn endpointFromCloneUrl(arena: Allocator, settings: *const Settings, operation: Operation, raw: []const u8, base: ?[]const u8) Error!Endpoint {
    var e = try newEndpoint(arena, settings, operation, raw, base);
    var u = e.url;
    if (std.mem.endsWith(u8, u, "/")) u = u[0 .. u.len - 1];
    if (e.isLocal()) {
        e.url = u;
        return e;
    }
    const last_slash = std.mem.lastIndexOfScalar(u8, u, '/') orelse 0;
    const ext_start = std.mem.lastIndexOfScalar(u8, u, '.');
    const ends_git = if (ext_start) |dot| dot > last_slash and std.mem.eql(u8, u[dot..], ".git") else false;
    e.url = try std.fmt.allocPrint(arena, "{s}{s}", .{ u, if (ends_git) "/info/lfs" else ".git/info/lfs" });
    return e;
}

/// git-lfs's `NewEndpoint`: a URL, rewritten by `insteadOf`, read by its
/// scheme.
fn newEndpoint(arena: Allocator, settings: *const Settings, operation: Operation, raw_in: []const u8, base: ?[]const u8) Error!Endpoint {
    var raw = raw_in;
    if (operation == .upload) {
        if (try rewriteUrl(arena, settings, raw, .push)) |r| raw = r else if (try rewriteUrl(arena, settings, raw, .fetch)) |r| raw = r;
    } else if (try rewriteUrl(arena, settings, raw, .fetch)) |r| raw = r;

    if (raw.len == 0) return error.LfsEndpointUnknown;
    if (UrlParts.parse(raw)) |parts| {
        const scheme = parts.scheme;
        if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "file"))
        {
            return .{ .url = raw, .original = raw };
        }
        if (std.ascii.eqlIgnoreCase(scheme, "ssh") or std.ascii.eqlIgnoreCase(scheme, "git+ssh") or
            std.ascii.eqlIgnoreCase(scheme, "ssh+git"))
        {
            return sshEndpoint(arena, raw, parts);
        }
        if (std.ascii.eqlIgnoreCase(scheme, "git")) {
            // `git://` has no API; git-lfs asks `lfs.gitprotocol`'s scheme
            // at the same host and path.
            const protocol = (try settings.get(arena, "lfs.gitprotocol")) orelse "https";
            const u = try std.fmt.allocPrint(arena, "{s}{s}", .{ protocol, raw[scheme.len..] });
            return .{ .url = u, .original = u };
        }
        return error.LfsEndpointUnknown;
    }
    if (url_mod.isLocal(raw)) {
        const absolute = if (std.fs.path.isAbsolute(raw) or base == null)
            raw
        else
            try std.fs.path.resolve(arena, &.{ base.?, raw });
        const u = try localFileUrl(arena, absolute);
        return .{ .url = u, .original = u };
    }
    // `[user@]host:path`, or `[host:port]:path`.
    const parsed = url_mod.Url.parse(raw) catch return error.LfsEndpointUnknown;
    if (parsed.scheme != .ssh) return error.LfsEndpointUnknown;
    const user_and_host = if (parsed.user) |user| try std.fmt.allocPrint(arena, "{s}@{s}", .{ user, parsed.host }) else parsed.host;
    var port: ?[]const u8 = null;
    if (parsed.port) |p| port = try std.fmt.allocPrint(arena, "{d}", .{p});
    const path = parsed.path;
    return .{
        .url = try std.fmt.allocPrint(arena, "https://{s}/{s}", .{ parsed.host, path }),
        .ssh = .{ .user_and_host = user_and_host, .port = port, .path = std.mem.trimStart(u8, path, "/")[0..] },
        .original = raw,
    };
}

/// `url.<base>.insteadOf`, or `pushInsteadOf`, applied as git-lfs applies
/// it: the longest base wins.
fn rewriteUrl(arena: Allocator, settings: *const Settings, url: []const u8, which: remote_mod.Rewrite) Error!?[]const u8 {
    return remote_mod.rewrite(arena, settings.config, url, which) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    };
}

/// An `ssh://` URL: the host and port for ssh, the path for
/// `git-lfs-authenticate`, and `https://<host><path>` for the API.
fn sshEndpoint(arena: Allocator, raw: []const u8, parts: UrlParts) Error!Endpoint {
    // git-lfs reads the host as `name[:digits]` and gives up on anything
    // else, an IPv6 literal included.
    if (parts.host.len == 0 or std.mem.indexOfScalar(u8, parts.authority, '[') != null) return error.LfsEndpointUnknown;
    if (parts.port) |p| {
        for (p) |c| if (!std.ascii.isDigit(c)) return error.LfsEndpointUnknown;
    }
    const user_and_host = if (parts.user) |user|
        (if (user.len != 0) try std.fmt.allocPrint(arena, "{s}@{s}", .{ user, parts.host }) else parts.host)
    else
        parts.host;
    const path = try percentDecode(arena, parts.path);
    return .{
        .url = try std.fmt.allocPrint(arena, "https://{s}{s}", .{ parts.host, path }),
        .ssh = .{ .user_and_host = user_and_host, .port = parts.port, .path = path },
        .original = raw,
    };
}

/// `file://` and an absolute path, `/`-separated, as git-lfs writes one.
fn localFileUrl(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const slashed = try arena.dupe(u8, path);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, slashed, '\\', '/');
    if (slashed.len != 0 and slashed[0] != '/') return std.fmt.allocPrint(arena, "file:///{s}", .{slashed});
    return std.fmt.allocPrint(arena, "file://{s}", .{slashed});
}

fn percentDecode(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(a, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, text[i]);
    }
    return out.items;
}

//=====================================================================
// git-lfs-authenticate
//=====================================================================

/// What `git-lfs-authenticate` answered: where the API is, and a header
/// that authenticates to it.
pub const SshAuth = struct {
    href: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    /// `expires_in`, in seconds, when not zero; else `lfs.defaulttokenttl`
    /// when the answer gives no expiry at all.
    expires_in: i64 = 0,
    /// `expires_at`, in seconds since the epoch.
    expires_at: ?i64 = null,

    /// Whether the answer, given at `now`, expires within five seconds of
    /// it, as git-lfs's cache asks before it reuses one.
    pub fn expiredAt(a: SshAuth, now: i64) bool {
        return expiresWithin(now, a.expires_in, a.expires_at, 5);
    }
};

/// git-lfs's `IsExpiredAtOrIn` with the start and the check both at `now`:
/// an `in` that is not zero wins over `at`, and neither is no expiry.
pub fn expiresWithin(now: i64, in_s: i64, at: ?i64, margin_s: i64) bool {
    if (in_s != 0) return now + in_s < now + margin_s;
    const when = at orelse return false;
    return when < now + margin_s;
}

/// The program git-lfs runs to reach an ssh remote and the arguments it
/// hands it, for `git-lfs-authenticate <path> <operation>`. The program
/// comes from `GIT_SSH_COMMAND` or `core.sshCommand`, each a command line,
/// else `GIT_SSH`, else `ssh`; the port is `-p`, or `-P` to the PuTTY
/// family; a host beginning with `-` is fenced off with `--` for OpenSSH and
/// stripped of its dashes for anything else.
pub fn sshArguments(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    settings: *const Settings,
    ssh: Endpoint.Ssh,
    operation: Operation,
) Error!program.Invocation {
    const remote = try std.fmt.allocPrint(arena, "git-lfs-authenticate {s} {s}", .{ ssh.path, @tagName(operation) });
    return sshInvocation(arena, environ, settings, ssh, remote, null);
}

/// The ssh program git-lfs runs, and the option dialect it speaks.
pub const SshProgram = struct {
    command: []const u8,
    shell: bool,
    variant: enum { ssh, simple, putty, tortoise },
};

/// Which ssh git-lfs runs: `GIT_SSH_COMMAND`, else `GIT_SSH`, else
/// `core.sshCommand`, else `ssh`; its variant from `GIT_SSH_VARIANT` or
/// `ssh.variant`, else from the program's name.
pub fn sshProgram(arena: Allocator, environ: *const std.process.Environ.Map, settings: *const Settings) Error!SshProgram {
    var command: []const u8 = "";
    var shell = false;
    if (environ.get("GIT_SSH_COMMAND")) |line| {
        if (firstField(line)) |_| {
            command = line;
            shell = true;
        }
    }
    if (command.len == 0) {
        if (environ.get("GIT_SSH")) |path| {
            if (path.len != 0) command = path;
        }
    }
    if (command.len == 0) {
        if (try settings.get(arena, "core.sshcommand")) |line| {
            if (firstField(line)) |_| {
                command = line;
                shell = true;
            }
        }
    }
    if (command.len == 0) command = "ssh";
    const program_name = if (shell) firstField(command).? else command;

    var out: SshProgram = .{ .command = command, .shell = shell, .variant = .ssh };
    var named: ?[]const u8 = environ.get("GIT_SSH_VARIANT");
    if (named == null) named = try settings.get(arena, "ssh.variant");
    var autodetect = true;
    if (named) |name| {
        if (std.mem.eql(u8, name, "auto")) {
            autodetect = true;
        } else {
            autodetect = false;
            out.variant = if (std.mem.eql(u8, name, "simple"))
                .simple
            else if (std.mem.eql(u8, name, "putty") or std.mem.eql(u8, name, "plink"))
                .putty
            else if (std.mem.eql(u8, name, "tortoiseplink"))
                .tortoise
            else
                .ssh;
        }
    }
    if (autodetect) {
        var base = program_name[if (std.mem.lastIndexOfAny(u8, program_name, "/\\")) |sep| sep + 1 else 0..];
        if (!std.mem.eql(u8, base, "ssh")) {
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
        }
        if (std.ascii.eqlIgnoreCase(base, "plink")) out.variant = .putty;
        if (std.ascii.eqlIgnoreCase(base, "tortoiseplink")) out.variant = .tortoise;
    }
    return out;
}

/// OpenSSH's connection sharing, as git-lfs asks for it: the first
/// connection the master, the rest sharing its socket.
pub const Multiplex = struct {
    master: bool,
    control_path: []const u8,
};

/// The invocation of ssh that runs `remote_command` on the host, as
/// git-lfs starts it: the port is `-p`, or `-P` to the PuTTY family; a host
/// beginning with `-` is fenced off with `--` for OpenSSH and stripped of
/// its dashes for anything else; `multiplex` is asked of OpenSSH alone.
pub fn sshInvocation(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    settings: *const Settings,
    ssh: Endpoint.Ssh,
    remote_command: []const u8,
    multiplex: ?Multiplex,
) Error!program.Invocation {
    const prog = try sshProgram(arena, environ, settings);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, prog.command);
    if (prog.variant == .tortoise) try argv.append(arena, "-batch");
    if (multiplex) |m| {
        if (prog.variant == .ssh) {
            try argv.append(arena, if (m.master) "-oControlMaster=yes" else "-oControlMaster=no");
            try argv.append(arena, try std.fmt.allocPrint(arena, "-oControlPath={s}", .{m.control_path}));
        }
    }
    if (ssh.port) |port| {
        try argv.append(arena, if (prog.variant == .putty or prog.variant == .tortoise) "-P" else "-p");
        try argv.append(arena, port);
    }
    if (ssh.user_and_host.len != 0 and ssh.user_and_host[0] == '-') {
        if (prog.variant == .ssh) {
            try argv.appendSlice(arena, &.{ "--", ssh.user_and_host });
        } else try argv.append(arena, std.mem.trimStart(u8, ssh.user_and_host, "-"));
    } else try argv.append(arena, ssh.user_and_host);
    try argv.append(arena, remote_command);
    return .{ .argv = argv.items, .shell = prog.shell, .stderr = .capture, .unset = &program.repository_variables };
}

/// The first word of a command line, quotes taken off, or `null` for one
/// that is all white space: git-lfs's `QuotedFields(...)[0]`.
fn firstField(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '\'' or trimmed[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, trimmed, 1, trimmed[0])) |close| return trimmed[1..close];
    }
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

/// The messages that say the server has no `git-lfs-authenticate`, which
/// git-lfs takes as a reason to use the guessed endpoint rather than fail.
const authenticate_missing = [_][]const u8{
    "git-lfs-authenticate: not found",
    "git-lfs-authenticate: command not found",
    "git-lfs-authenticate: no such file",
    "command not found: git-lfs-authenticate",
};

/// `git-lfs-authenticate`'s answer, read.
pub fn parseAuthenticate(arena: Allocator, bytes: []const u8) Error!SshAuth {
    const Answer = struct {
        href: ?[]const u8 = null,
        header: ?std.json.ArrayHashMap([]const u8) = null,
        expires_in: ?i64 = null,
        expires_at: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Answer, arena, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedResponse,
    };
    var headers: std.ArrayList(http.Header) = .empty;
    if (parsed.header) |map| {
        var it = map.map.iterator();
        while (it.next()) |kv| {
            try checkHeader(kv.key_ptr.*, kv.value_ptr.*);
            try headers.append(arena, .{ .name = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
    }
    return .{
        .href = parsed.href,
        .headers = headers.items,
        .expires_in = parsed.expires_in orelse 0,
        .expires_at = if (parsed.expires_at) |t| timetext.parseRfc3339(t) else null,
    };
}

/// A header the standard library can be handed: a name with no colon and no
/// line break, a value with no line break.
pub fn checkHeader(name: []const u8, value: []const u8) error{InvalidHttpHeader}!void {
    if (name.len == 0) return error.InvalidHttpHeader;
    if (std.mem.indexOfAny(u8, name, ":\r\n") != null) return error.InvalidHttpHeader;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidHttpHeader;
}

//=====================================================================
// The client
//=====================================================================

/// How a client behaves.
pub const Options = struct {
    /// The permission to run programs: ssh for an ssh remote, credential
    /// helpers and askpass for a server that wants a credential. Its
    /// environment is where `GIT_SSH_COMMAND`, `GIT_SSH` and the proxy
    /// variables are read.
    programs: ?program.Programs = null,
    /// What stands in for a terminal when a server asks for a credential no
    /// helper has.
    prompt: ?credential.Prompt = null,
    /// Filled in when a request fails for want of a credential, or is
    /// forbidden: see `auth.Failure`.
    auth_failure: ?*auth_mod.Failure = null,
    /// The time of the operation, in seconds since the epoch, which the
    /// library never reads for itself. With it, as git-lfs does with its
    /// clock: an action or a `git-lfs-authenticate` token that expires
    /// within five seconds of it is not used, a `Retry-After` given as a
    /// date is waited out, and `lfs/tmp` is swept after a transfer. Without
    /// it, none of that is done.
    now: ?i64 = null,
};

/// An access mode git-lfs records for a URL.
pub const Access = enum { none, basic };

/// Something a server taught, under the key git-lfs writes it to.
pub const Learned = struct {
    /// `lfs.<url>.access` or `lfs.<url>.locksverify`.
    key: []const u8,
    value: []const u8,
};

/// A connection to one remote's LFS server, for the life of one operation.
///
/// It is safe to use from several tasks at once: the transfers of one
/// operation share it, and what they learn about credentials is held under a
/// mutex.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    settings: *const Settings,
    /// The remote's name, or a URL.
    remote: []const u8,
    /// What a relative local path is taken against.
    where: Where,
    options: Options,
    /// One HTTP client for each set of connection settings the operation's
    /// URLs need: `transportFor`.
    transports: std.ArrayList(*Transport) = .empty,
    transport_mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    endpoints: [2]?Endpoint = .{ null, null },
    ssh_auth: [2]?SshAuth = .{ null, null },
    /// git-lfs's pure-ssh protocol for each operation: not tried yet, not
    /// used, or open.
    ssh_transfers: [2]SshTransferSlot = .{ .untried, .untried },
    /// What ssh said when the pure-ssh protocol did not start.
    ssh_failure: std.ArrayList(u8) = .empty,
    access: std.ArrayList(struct { url: []const u8, mode: Access }) = .empty,
    credentials: std.ArrayList(*Cred) = .empty,
    /// `~/.netrc`, read from the home directory in the environment the
    /// caller granted, and the hosts whose entry a server refused.
    netrc: ?netrc_mod.Netrc = null,
    netrc_refused: std.ArrayList([]const u8) = .empty,
    /// What the server taught, for `remember`.
    learned: std.ArrayList(Learned) = .empty,
    message_mutex: Io.Mutex = .init,
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,

    const Cred = struct {
        url: []const u8,
        session: credential.Session,
        approved: bool = false,
    };

    const SshTransferSlot = union(enum) { untried, none, open: *lfsssh.Transfer };

    /// An HTTP client and the settings it was made for: a proxy, the
    /// certificates to trust or none, and the timeouts.
    const Transport = struct {
        key: []const u8,
        arena: std.heap.ArenaAllocator,
        client: httpclient.Client,
    };

    /// Open a client for `remote`. `settings` is borrowed.
    pub fn init(gpa: Allocator, io: Io, settings: *const Settings, remote: []const u8, where: Where, options: Options) Error!Client {
        var c: Client = .{
            .gpa = gpa,
            .io = io,
            .settings = settings,
            .remote = remote,
            .where = where,
            .options = options,
            .arena = .init(gpa),
        };
        errdefer c.arena.deinit();
        try c.loadNetrc();
        return c;
    }

    /// `$HOME/.netrc`, or `_netrc` on Windows when there is no `.netrc`, as
    /// git-lfs reads it. One that does not parse is not used, as git-lfs
    /// does not use it.
    fn loadNetrc(c: *Client) Allocator.Error!void {
        const programs = c.options.programs orelse return;
        const home = programs.environ.get("HOME") orelse return;
        if (home.len == 0) return;
        var dir = Io.Dir.cwd().openDir(c.io, home, .{}) catch return;
        defer dir.close(c.io);
        const text = (fs.readFileAlloc(c.gpa, c.io, dir, ".netrc", 1 << 20) catch null) orelse
            (if (builtin.os.tag == .windows) (fs.readFileAlloc(c.gpa, c.io, dir, "_netrc", 1 << 20) catch null) else null) orelse
            return;
        defer c.gpa.free(text);
        c.netrc = netrc_mod.Netrc.parse(c.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedNetrc => null,
        };
    }

    /// The `Authorization` a netrc entry gives for `url`'s host, unless the
    /// server refused it already.
    fn netrcAuth(c: *Client, a: Allocator, url: []const u8) Allocator.Error!?struct { header: []const u8, host: []const u8 } {
        const n = &(c.netrc orelse return null);
        const parts = UrlParts.parse(url) orelse return null;
        for (c.netrc_refused.items) |h| {
            if (std.mem.eql(u8, h, parts.host)) return null;
        }
        const m = n.find(parts.host, parts.user) orelse return null;
        return .{ .header = try basicHeader(a, m.login, m.password), .host = parts.host };
    }

    /// Release everything, forgetting every credential.
    pub fn deinit(c: *Client) void {
        for (c.credentials.items) |cred| {
            cred.session.deinit();
            c.gpa.destroy(cred);
        }
        c.credentials.deinit(c.gpa);
        if (c.netrc) |*n| n.deinit();
        c.netrc_refused.deinit(c.gpa);
        c.access.deinit(c.gpa);
        c.learned.deinit(c.gpa);
        for (&c.ssh_transfers) |*slot| switch (slot.*) {
            .open => |t| t.close(),
            else => {},
        };
        c.ssh_failure.deinit(c.gpa);
        for (c.transports.items) |t| {
            t.client.deinit();
            t.arena.deinit();
            c.gpa.free(t.key);
            c.gpa.destroy(t);
        }
        c.transports.deinit(c.gpa);
        c.arena.deinit();
        c.* = undefined;
    }

    /// What the server or the program last said about a failure.
    pub fn message(c: *const Client) []const u8 {
        return c.message_buf[0..c.message_len];
    }

    /// Keep `text` as what `message` says.
    pub fn setMessage(c: *Client, text: []const u8) void {
        c.message_mutex.lockUncancelable(c.io);
        defer c.message_mutex.unlock(c.io);
        c.message_len = @min(text.len, c.message_buf.len);
        @memcpy(c.message_buf[0..c.message_len], text[0..c.message_len]);
    }

    fn fail(c: *Client, err: Error, comptime fmt: []const u8, args: anytype) Error {
        var buf: [512]u8 = undefined;
        c.setMessage(std.fmt.bufPrint(&buf, fmt, args) catch fmt);
        return err;
    }

    /// Write what the server taught to `repo`'s own configuration under
    /// git-lfs's keys, as git-lfs writes them, so the next operation — this
    /// package's or git-lfs's — starts from it. A value already set is left
    /// alone.
    pub fn remember(c: *Client, io: Io, repo: *repo_mod.Repository) config_mod.Config.SetError!void {
        var changed = false;
        for (c.learned.items) |l| {
            if (repo.config.get(l.key)) |existing| {
                if (std.mem.eql(u8, existing, l.value)) continue;
            }
            try repo.config.setIn(.local, l.key, l.value);
            changed = true;
        }
        if (changed) try repo.config.write(io, repo.common_dir, "config");
    }

    /// Describe a request that failed for want of a credential, or that the
    /// server forbade, in the caller's `auth_failure`. `cred` is the
    /// helpers' credential it was made with, when it was.
    fn describeRefusal(c: *Client, reason: auth_mod.Failure.Reason, status: u16, url: []const u8, said: []const u8, cred: ?*Cred) void {
        const described = c.options.auth_failure orelse return;
        const scheme: url_mod.Scheme = if (url_mod.Url.parse(url)) |u| u.scheme else |_| .https;
        described.begin(c.gpa, reason, scheme, url) catch return;
        described.status = status;
        described.setServerMessage(said) catch {};
        described.prompt_available = c.options.prompt != null;
        if (cred) |cr| cr.session.describeFailure(described, c.options.prompt != null) catch {};
    }

    /// The endpoint for `operation`, found once.
    pub fn endpoint(c: *Client, operation: Operation) Error!Endpoint {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        return c.endpointLocked(operation);
    }

    fn endpointLocked(c: *Client, operation: Operation) Error!Endpoint {
        const i = @intFromEnum(operation);
        if (c.endpoints[i]) |e| return e;
        const e = try findEndpoint(c.arena.allocator(), c.settings, c.remote, operation, c.where);
        c.endpoints[i] = e;
        return e;
    }

    /// The API's URL for `operation`, from `git-lfs-authenticate` when the
    /// remote is an ssh one, and the headers that go with it.
    pub fn apiBase(c: *Client, operation: Operation) Error!struct { url: []const u8, headers: []const http.Header } {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        const e = try c.endpointLocked(operation);
        const auth = try c.sshAuthLocked(e, operation);
        return .{ .url = auth.href orelse e.url, .headers = auth.headers };
    }

    fn sshAuthLocked(c: *Client, e: Endpoint, operation: Operation) Error!SshAuth {
        const i = @intFromEnum(operation);
        if (c.ssh_auth[i]) |a| {
            // git-lfs keeps an answer until it is five seconds from expiring.
            const now = c.options.now orelse return a;
            if (!a.expiredAt(now)) return a;
            c.ssh_auth[i] = null;
        }
        const ssh = e.ssh orelse {
            c.ssh_auth[i] = .{};
            return .{};
        };
        const arena = c.arena.allocator();
        if (try c.settings.urlGet(arena, "lfs", e.original, "sshtransfer")) |mode| {
            // git-lfs runs git-lfs-authenticate only for `negotiate` and
            // `never`; `always` is the pure-ssh protocol or nothing.
            if (!std.mem.eql(u8, mode, "negotiate") and !std.mem.eql(u8, mode, "never")) {
                return c.fail(error.LfsAuthenticateDisabled, "git-lfs-authenticate has been disabled by request (lfs.sshtransfer={s}){s}{s}", .{
                    mode,
                    if (c.ssh_failure.items.len != 0) ": " else "",
                    c.ssh_failure.items,
                });
            }
        }
        const programs = c.options.programs orelse return error.ProgramsNotGranted;
        const invocation = try sshArguments(arena, programs.environ, c.settings, ssh, operation);
        const retries: usize = @intCast(@max(0, c.settings.getInt("lfs.ssh.retries", 5)));
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var outcome = try program.run(programs, c.gpa, c.io, invocation, "", .{ .output = .limited(1 << 20) });
            defer outcome.deinit(c.gpa);
            if (outcome.succeeded()) {
                var auth = try parseAuthenticate(arena, try arena.dupe(u8, outcome.stdout));
                if (auth.expires_in == 0 and auth.expires_at == null) {
                    auth.expires_in = @max(0, c.settings.getInt("lfs.defaulttokenttl", 0));
                }
                c.ssh_auth[i] = auth;
                return auth;
            }
            const said = std.mem.trim(u8, outcome.stderr, " \t\r\n");
            const missing = switch (outcome.term) {
                .exited => |code| code == 127 or blk: {
                    var lower_buf: [1024]u8 = undefined;
                    const lower = std.ascii.lowerString(lower_buf[0..@min(said.len, lower_buf.len)], said[0..@min(said.len, lower_buf.len)]);
                    for (authenticate_missing) |needle| {
                        if (std.mem.indexOf(u8, lower, needle) != null) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
            if (missing) {
                // No git-lfs-authenticate on the server: the guessed
                // endpoint, as the server discovery specification says.
                c.ssh_auth[i] = .{};
                return .{};
            }
            if (attempt >= retries) {
                c.setMessage(said);
                return error.LfsAuthenticateFailed;
            }
        }
    }

    /// git-lfs's pure-ssh protocol for `operation`, when the remote is
    /// reached over ssh, `lfs.<url>.sshtransfer` is unset, `negotiate` or
    /// `always`, and `git-lfs-transfer` starts on the server; `null`
    /// otherwise, and the API over HTTP is used, as git-lfs uses it. The
    /// answer is found once per operation.
    pub fn sshTransfer(c: *Client, operation: Operation) Error!?*lfsssh.Transfer {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        const i = @intFromEnum(operation);
        switch (c.ssh_transfers[i]) {
            .open => |t| return t,
            .none => return null,
            .untried => {},
        }
        c.ssh_transfers[i] = .none;
        const e = try c.endpointLocked(operation);
        const ssh = e.ssh orelse return null;
        const arena = c.arena.allocator();
        if (try c.settings.urlGet(arena, "lfs", e.original, "sshtransfer")) |mode| {
            if (!std.mem.eql(u8, mode, "negotiate") and !std.mem.eql(u8, mode, "always")) return null;
        }
        const programs = c.options.programs orelse return error.ProgramsNotGranted;
        const remote = try std.fmt.allocPrint(arena, "git-lfs-transfer {s} {s}", .{ ssh.path, @tagName(operation) });
        var first = try sshInvocation(arena, programs.environ, c.settings, ssh, remote, null);
        var rest = first;
        var control_dir: ?[]const u8 = null;
        const prog = try sshProgram(arena, programs.environ, c.settings);
        if (prog.variant == .ssh and c.settings.getBool("lfs.ssh.automultiplex", builtin.os.tag != .windows)) {
            if (try controlDir(arena, c.io, programs.environ)) |dir| {
                control_dir = dir;
                const path = try std.fmt.allocPrint(arena, "{s}/lfs.sock", .{dir});
                first = try sshInvocation(arena, programs.environ, c.settings, ssh, remote, .{ .master = true, .control_path = path });
                rest = try sshInvocation(arena, programs.environ, c.settings, ssh, remote, .{ .master = false, .control_path = path });
            }
        }
        const t = lfsssh.Transfer.open(c.gpa, c.io, programs, first, rest, control_dir, &c.ssh_failure) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e2| return e2,
            else => {
                // Not there, or not speaking it: git-lfs-authenticate and
                // HTTP, as git-lfs falls back.
                if (control_dir) |d| Io.Dir.cwd().deleteTree(c.io, d) catch {};
                return null;
            },
        };
        c.ssh_transfers[i] = .{ .open = t };
        return t;
    }

    /// Forget `git-lfs-authenticate`'s answer, so the next request asks
    /// again: what a refused token calls for.
    fn dropSshAuth(c: *Client, operation: Operation) void {
        c.ssh_auth[@intFromEnum(operation)] = null;
    }

    fn accessFor(c: *Client, url: []const u8) Error!Access {
        const plain = try stripUserinfo(c.arena.allocator(), url);
        for (c.access.items) |entry| {
            if (std.mem.startsWith(u8, plain, entry.url)) return entry.mode;
        }
        const mode = (try c.settings.urlGet(c.arena.allocator(), "lfs", plain, "access")) orelse return .none;
        if (std.ascii.eqlIgnoreCase(mode, "basic") or std.ascii.eqlIgnoreCase(mode, "private")) return .basic;
        if (std.ascii.eqlIgnoreCase(mode, "none") or mode.len == 0) return .none;
        return error.LfsAccessUnsupported;
    }

    fn setAccess(c: *Client, url: []const u8, mode: Access) Error!void {
        const arena = c.arena.allocator();
        const plain = try arena.dupe(u8, try stripUserinfo(arena, url));
        try c.access.insert(c.gpa, 0, .{ .url = plain, .mode = mode });
        try c.learned.append(c.gpa, .{
            .key = try std.fmt.allocPrint(arena, "lfs.{s}.access", .{plain}),
            .value = @tagName(mode),
        });
    }

    /// Record that the server has no locking API, under
    /// `lfs.<url>.locksverify`, as git-lfs records it.
    pub fn learnLocksVerify(c: *Client, url: []const u8, value: bool) Error!void {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        const arena = c.arena.allocator();
        try c.learned.append(c.gpa, .{
            .key = try std.fmt.allocPrint(arena, "lfs.{s}.locksverify", .{try stripUserinfo(arena, url)}),
            .value = if (value) "true" else "false",
        });
    }

    /// The URL git-lfs asks the credential helpers about for a request to
    /// `request_url`: the request's own when it is on another host than the
    /// API, else the remote's own URL when that is on the API's host, else
    /// the API's. `null` when a URL carries a password, which is then the
    /// credential.
    fn credentialUrl(c: *Client, request_url: []const u8, operation: Operation) Error!struct { url: ?[]const u8, inline_auth: ?[]const u8 } {
        const arena = c.arena.allocator();
        const e = try c.endpointLocked(operation);
        const api_url = UrlParts.parse(e.url) orelse return .{ .url = request_url, .inline_auth = null };
        const req = UrlParts.parse(request_url) orelse return .{ .url = request_url, .inline_auth = null };
        if (!std.mem.eql(u8, req.scheme, api_url.scheme) or !std.mem.eql(u8, req.authority, api_url.authority)) {
            return .{ .url = request_url, .inline_auth = null };
        }
        if (api_url.password) |password| return .{ .url = null, .inline_auth = try basicHeader(arena, api_url.user orelse "", password) };
        if (try gitRemoteUrl(arena, c.settings, c.remote, operation == .upload)) |remote_url| {
            if (UrlParts.parse(remote_url)) |r| {
                if (std.mem.eql(u8, r.scheme, api_url.scheme) and std.mem.eql(u8, r.authority, api_url.authority)) {
                    if (r.password) |password| return .{ .url = null, .inline_auth = try basicHeader(arena, r.user orelse "", password) };
                    return .{ .url = remote_url, .inline_auth = null };
                }
            }
        }
        return .{ .url = e.url, .inline_auth = null };
    }

    fn credentialFor(c: *Client, url: []const u8) Error!*Cred {
        // One credential per URL for the operation, which is git-lfs's
        // in-memory cache: a helper is asked once, however many requests
        // follow.
        const key = credentialKey(url);
        for (c.credentials.items) |cred| {
            if (std.mem.eql(u8, credentialKey(cred.url), key)) return cred;
        }
        const owned_url = try c.arena.allocator().dupe(u8, url);
        const parsed = url_mod.Url.parse(owned_url) catch return error.MalformedUrl;
        const cred = try c.gpa.create(Cred);
        errdefer c.gpa.destroy(cred);
        cred.* = .{ .url = owned_url, .session = .{ .gpa = c.gpa, .url = parsed } };
        try c.credentials.append(c.gpa, cred);
        return cred;
    }

    fn credentialOptions(c: *const Client) credential.Options {
        return .{ .config = c.settings.config, .programs = c.options.programs, .prompt = c.options.prompt };
    }

    /// Everything a request needs besides its URL and method.
    pub const Request = struct {
        method: http.Method,
        /// Absolute. May carry a user and password, which become the
        /// credential.
        url: []const u8,
        /// The server's own headers for it: an action's, or
        /// `git-lfs-authenticate`'s.
        headers: []const http.Header = &.{},
        body: Body = .none,
        /// A JSON request to the API itself, whose content type and accept
        /// header are the API's.
        api: bool = false,
        /// The server said the request needs no credential of ours.
        authenticated: bool = false,
        /// The URL whose `lfs.<url>.access` decides whether a credential is
        /// sent. The request's own when `null`.
        access_url: ?[]const u8 = null,
        /// How often a request that could not be made at all is made again.
        network_retries: u32 = 0,
        /// The `Accept-Encoding` an object's download sends.
        accept: Accept = .default,
        /// Told of every chunk of an `object` body as it goes out.
        on_bytes: ?BytesSent = null,
        /// Where the bytes of an `object` body sent so far are counted, so a
        /// caller can take them back off its progress when the request
        /// fails.
        sent: ?*u64 = null,
    };

    /// What a download asks to have its body compressed with, as git-lfs's
    /// Go client asks.
    pub const Accept = enum {
        /// The HTTP client's own list, for the API.
        default,
        /// No `Accept-Encoding` at all: a request with a `Range`, whose
        /// bytes count from the object's start.
        none,
        gzip,
        /// Only when `lfs.transfer.httpDownloadEncoding` asks for it.
        zstd,
    };

    /// A callback for the bytes of a body as they go out.
    pub const BytesSent = struct {
        context: *anyopaque,
        add: *const fn (context: *anyopaque, n: u64) void,
    };

    /// What a request sends.
    pub const Body = union(enum) {
        none,
        bytes: []const u8,
        /// An object in a store, read again for every attempt.
        object: struct { store: *const lfs.Store, pointer: lfs.Pointer },
    };

    /// Make `request`, handling a credential the server asks for and the
    /// redirects git-lfs follows. The answer is open for its body and is the
    /// caller's to `close`, whatever its status.
    pub fn send(c: *Client, request: Request) Error!*Exchange {
        const operation: Operation = switch (request.method) {
            .POST, .PUT => .upload,
            else => .download,
        };
        // What one request works out for itself — the URL a redirect led
        // to, the header a credential became — lives here, since the
        // tasks of one operation send at once.
        var scratch_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        var url = request.url;
        var redirects: u8 = 0;
        var auth_attempts: u8 = 0;
        var retries_left = request.network_retries;
        const has_auth = hasHeader(request.headers, "authorization");
        // The last refusal's challenges and words, for the helpers and for
        // a failure's description.
        var challenges: []const []const u8 = &.{};
        var said: []const u8 = "";
        while (true) {
            var auth_header: ?[]const u8 = null;
            var cred: ?*Cred = null;
            var netrc_host: ?[]const u8 = null;
            var access: Access = .none;
            const access_url = request.access_url orelse url;
            {
                try c.mutex.lock(c.io);
                defer c.mutex.unlock(c.io);
                access = try c.accessFor(access_url);
                if (!request.authenticated and !has_auth and access == .basic) {
                    const found = try c.credentialUrl(url, operation);
                    if (found.inline_auth) |h| auth_header = try scratch.dupe(u8, h) else if (try c.netrcAuth(scratch, found.url.?)) |n| {
                        // `.netrc` comes before every helper, as in git-lfs,
                        // and what it gives is not stored with them.
                        auth_header = n.header;
                        netrc_host = n.host;
                    } else if (found.url) |cred_url| {
                        const cr = try c.credentialFor(cred_url);
                        if (cr.session.authorization() == null) {
                            // The server's challenges go to the helpers as
                            // `wwwauth[]`, unless git-lfs's
                            // `credential.<url>.skipwwwauth` says not.
                            const skip = gitLfsBool(try c.settings.urlGet(scratch, "credential", cred_url, "skipwwwauth"), false);
                            try cr.session.setChallenges(if (skip) &.{} else challenges);
                            const filled = cr.session.fill(c.io, c.credentialOptions()) catch |err| {
                                c.describeRefusal(switch (err) {
                                    error.CredentialHelperQuit => .helper_quit,
                                    error.ProgramsNotGranted => .programs_not_granted,
                                    else => .no_credential,
                                }, 401, url, said, cr);
                                return err;
                            };
                            if (!filled) {
                                c.describeRefusal(.declined, 401, url, said, cr);
                                return c.fail(error.AuthenticationFailed, "no credential for {s}", .{stripQuery(cred_url)});
                            }
                        }
                        const h = cr.session.authorization() orelse return error.AuthenticationFailed;
                        auth_header = try scratch.dupe(u8, h);
                        cred = cr;
                    }
                } else if (!request.authenticated and !has_auth) {
                    // A password in the URL is sent whatever the access
                    // mode, as git-lfs sends it.
                    if (UrlParts.parse(url)) |parts| {
                        if (parts.password) |password| auth_header = try basicHeader(scratch, parts.user orelse "", password);
                    }
                }
            }

            const ex = c.exchangeOnce(request, url, auth_header) catch |err| switch (err) {
                error.ConnectionFailed => {
                    if (retries_left > 0) {
                        retries_left -= 1;
                        continue;
                    }
                    return err;
                },
                else => return err,
            };
            const status = ex.status();
            if (status == .unauthorized) {
                const offers = ex.authenticateOffers();
                challenges = try ex.challenges(scratch);
                said = ex.refusalText(scratch);
                ex.close();
                try c.mutex.lock(c.io);
                defer c.mutex.unlock(c.io);
                if (cred) |cr| {
                    cr.approved = false;
                    try cr.session.reject(c.io, c.credentialOptions());
                }
                if (netrc_host) |h| {
                    try c.netrc_refused.append(c.gpa, try c.arena.allocator().dupe(u8, h));
                    continue;
                }
                if (has_auth) {
                    // A header the server itself handed over — an action's,
                    // or git-lfs-authenticate's — that it no longer takes.
                    c.dropSshAuth(operation);
                    c.describeRefusal(.refused, 401, url, said, null);
                    return c.fail(error.AuthenticationFailed, "HTTP 401 from {s}", .{stripQuery(url)});
                }
                if (access == .none) {
                    if (!offers.basic and offers.other) return error.LfsAccessUnsupported;
                    try c.setAccess(access_url, .basic);
                    continue;
                }
                auth_attempts += 1;
                if (auth_attempts >= 3) {
                    c.describeRefusal(.refused, 401, url, said, cred);
                    return c.fail(error.AuthenticationFailed, "HTTP 401 from {s}", .{stripQuery(url)});
                }
                continue;
            }
            if (status.class() == .success) {
                if (cred) |cr| {
                    try c.mutex.lock(c.io);
                    defer c.mutex.unlock(c.io);
                    if (!cr.approved) {
                        cr.approved = true;
                        try cr.session.setChallenges(&.{});
                        try cr.session.approve(c.io, c.credentialOptions());
                    }
                }
            }
            switch (status) {
                .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {
                    const location = ex.location() orelse {
                        ex.close();
                        return c.fail(error.HttpStatus, "redirect with no location from {s}", .{stripQuery(url)});
                    };
                    const next = try resolveLocation(scratch, url, location);
                    ex.close();
                    if (std.ascii.startsWithIgnoreCase(url, "https:") and std.ascii.startsWithIgnoreCase(next, "http:")) {
                        return error.InsecureRedirect;
                    }
                    redirects += 1;
                    if (redirects >= 3) return error.TooManyRedirects;
                    url = next;
                    continue;
                },
                else => return ex,
            }
        }
    }

    fn exchangeOnce(c: *Client, request: Request, url: []const u8, auth_header: ?[]const u8) Error!*Exchange {
        const ex = try c.gpa.create(Exchange);
        errdefer c.gpa.destroy(ex);
        ex.* = .{ .client = c, .arena = .init(c.gpa) };
        errdefer ex.arena.deinit();
        const a = ex.arena.allocator();

        const request_url = try a.dupe(u8, try stripUserinfo(a, url));
        const parsed = url_mod.Url.parse(request_url) catch return c.fail(error.MalformedUrl, "malformed URL {s}", .{stripQuery(request_url)});
        if ((parsed.scheme != .http and parsed.scheme != .https) or parsed.host.len == 0) {
            return c.fail(error.MalformedUrl, "malformed URL {s}", .{stripQuery(request_url)});
        }
        const target: httpclient.Target = .{
            .tls = parsed.scheme == .https,
            .host = parsed.host,
            .port = parsed.port orelse if (parsed.scheme == .https) 443 else 80,
        };
        const path = blk: {
            const p = parsed.path[0 .. std.mem.indexOfScalar(u8, parsed.path, '#') orelse parsed.path.len];
            break :blk if (p.len == 0 or p[0] == '?') try std.mem.concat(a, u8, &.{ "/", p }) else p;
        };

        // Go's order, as git-lfs's client writes a request: its user
        // agent, then the rest.
        var headers: std.ArrayList(http.Header) = .empty;
        try headers.append(a, .{ .name = "User-Agent", .value = user_agent });
        if (auth_header) |h| try headers.append(a, .{ .name = "Authorization", .value = h });
        // A server's `Transfer-Encoding: chunked` asks for the body in
        // chunks; that header, `Content-Length` and `Host` are never sent
        // as given, as git-lfs's client never sends them.
        var chunked = false;
        var content_type: ?[]const u8 = null;
        if (request.api) {
            try headers.append(a, .{ .name = "Accept", .value = media_type });
            if (request.body != .none) content_type = media_type ++ "; charset=utf-8";
        } else if (request.body == .object and !hasHeader(request.headers, "content-type")) {
            content_type = try c.objectContentType(a, request_url, request.body.object.store, &request.body.object.pointer);
        }
        if (hasHeader(request.headers, "content-type")) content_type = null;
        if (content_type) |t| try headers.append(a, .{ .name = "Content-Type", .value = t });
        // `http.<url>.extraHeader`, as git-lfs adds it to every request.
        for (try c.extraHeaders(a, request_url)) |h| {
            if (framingHeader(h.name)) continue;
            try headers.append(a, h);
        }
        for (request.headers) |h| {
            try checkHeader(h.name, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "authorization") and auth_header != null) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) chunked = std.mem.eql(u8, h.value, "chunked");
            if (framingHeader(h.name)) continue;
            try headers.append(a, h);
        }
        // What Go's transport asks for on its own, unless the request
        // counts bytes from a `Range`.
        switch (request.accept) {
            .default, .gzip => try headers.append(a, .{ .name = "Accept-Encoding", .value = "gzip" }),
            .zstd => try headers.append(a, .{ .name = "Accept-Encoding", .value = "zstd" }),
            .none => {},
        }

        const transport = try c.transportFor(a, request_url);
        ex.url = request_url;
        switch (request.body) {
            .none => {
                const body: ?[]const u8 = if (request.method.requestHasBody()) "" else null;
                ex.response = transport.send(request.method, target, path, headers.items, body) catch |err| return c.clientFailed(transport, err, request_url);
            },
            .bytes => |bytes| {
                ex.response = transport.send(request.method, target, path, headers.items, bytes) catch |err| return c.clientFailed(transport, err, request_url);
            },
            .object => |o| {
                const file = (o.store.open(c.io, &o.pointer) catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)})) orelse
                    return c.fail(error.HttpStatus, "object {s} is not in the store", .{&o.pointer.oid});
                defer file.close(c.io);
                const body_buf = try a.alloc(u8, 64 * 1024);
                var streaming = transport.stream(request.method, target, path, headers.items, if (chunked) null else o.pointer.size, body_buf) catch |err|
                    return c.clientFailed(transport, err, request_url);
                var sent_all = false;
                defer if (!sent_all) streaming.abort();
                var chunk: [64 * 1024]u8 = undefined;
                var fr = file.reader(c.io, &.{});
                var left = o.pointer.size;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, chunk.len));
                    const n = fr.interface.readSliceShort(chunk[0..want]) catch return c.fail(error.ConnectionFailed, "upload: reading the object", .{});
                    if (n == 0) return c.fail(error.ConnectionFailed, "upload: the object is shorter than its pointer", .{});
                    streaming.writer().writeAll(chunk[0..n]) catch return c.fail(error.ConnectionFailed, "upload: the connection broke", .{});
                    left -= n;
                    if (request.sent) |count| count.* += n;
                    if (request.on_bytes) |cb| cb.add(cb.context, n);
                }
                sent_all = true;
                ex.response = streaming.finish() catch |err| return c.clientFailed(transport, err, request_url);
            },
        }
        ex.in_flight = true;
        return ex;
    }

    /// An error of the HTTP client's, as this module names it, with why in
    /// the message. A timeout is a connection that failed, which git-lfs
    /// retries as it retries any.
    fn clientFailed(c: *Client, transport: *httpclient.Client, err: httpclient.Error, url: []const u8) Error {
        const where = stripQuery(url);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.ConnectionFailed => c.fail(error.ConnectionFailed, "the connection failed: {s}", .{where}),
            error.TimedOut => c.fail(error.ConnectionFailed, "timed out: {s}", .{where}),
            error.BodyIncomplete => c.fail(error.ConnectionFailed, "upload cut short: {s}", .{where}),
            error.TlsFailed => c.fail(error.ConnectionFailed, "TLS: {s}: {s}", .{ if (transport.tls_error) |e| @errorName(e) else "handshake failed", where }),
            error.ProxyAuthenticationRequired => c.fail(error.ConnectionFailed, "the proxy wants credentials: {s}", .{where}),
            error.ProxyRefused => c.fail(error.ConnectionFailed, "the proxy answered {d}: {s}", .{ transport.proxy_status orelse 0, where }),
            error.HttpProtocolError => c.fail(error.MalformedResponse, "not an HTTP answer, or an encoding it cannot read: {s}", .{where}),
            error.CertificateBundleUnreadable => c.fail(error.SslCertificateUnreadable, "the system's certificates", .{}),
        };
    }

    /// The type an upload is sent as when its action names none: told from
    /// the object's first bytes, as git-lfs tells it, unless
    /// `lfs.<url>.contenttype` turns that off.
    fn objectContentType(c: *Client, a: Allocator, url: []const u8, store: *const lfs.Store, pointer: *const lfs.Pointer) Error![]const u8 {
        const setting = try c.settings.urlGet(a, "lfs", url, "contenttype");
        if (!gitLfsBool(setting, true)) return "application/octet-stream";
        const file = (store.open(c.io, pointer) catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)})) orelse
            return c.fail(error.HttpStatus, "object {s} is not in the store", .{&pointer.oid});
        defer file.close(c.io);
        var head: [mimesniff.sniff_len]u8 = undefined;
        const n = file.readPositionalAll(c.io, &head, 0) catch return c.fail(error.ConnectionFailed, "upload: reading the object", .{});
        return mimesniff.contentType(head[0..n]);
    }

    fn extraHeaders(c: *Client, a: Allocator, url: []const u8) Error![]const http.Header {
        const values = try c.settings.urlGetAll(a, "http", url, "extraheader");
        var out: std.ArrayList(http.Header) = .empty;
        for (values) |text| {
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse continue;
            const name = std.mem.trim(u8, text[0..colon], " \t");
            const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
            try checkHeader(name, value);
            try out.append(a, .{ .name = name, .value = value });
        }
        return out.items;
    }

    /// The HTTP client for a request to `url`, with the settings git-lfs
    /// would use for it: git's TLS settings for the URL from
    /// `httpsettings.zig`, which git-lfs reads as git does, the proxy
    /// git-lfs's own rules choose (`proxyFor`), and git-lfs's timeouts
    /// (`timeoutsFor`). A client certificate is refused by name.
    fn transportFor(c: *Client, scratch: Allocator, request_url: []const u8) Error!*httpclient.Client {
        const url = url_mod.Url.parse(request_url) catch return c.fail(error.MalformedUrl, "malformed URL {s}", .{stripQuery(request_url)});
        const environ: ?*const std.process.Environ.Map = if (c.options.programs) |p| p.environ else null;
        const settings = httpsettings.resolve(scratch, c.settings.config, environ, url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidHttpSetting => return c.fail(error.InvalidHttpSetting, "an http.* setting for {s} does not parse", .{stripQuery(request_url)}),
        };
        var ca_info: ?[]const u8 = null;
        var ca_path: ?[]const u8 = null;
        var verify = true;
        if (url.scheme == .https) {
            if (settings.ssl_cert != null or settings.ssl_key != null) {
                return c.fail(error.SslClientCertificateUnsupported, "{s} asks for a client certificate", .{if (settings.ssl_cert != null) "http.sslCert" else "http.sslKey"});
            }
            verify = settings.ssl_verify;
            ca_info = settings.ca_info;
            ca_path = settings.ca_path;
        }
        const proxy = try c.proxyFor(scratch, request_url, url);
        const timeouts = try timeoutsFor(c.settings, scratch, url);
        const key = try std.fmt.allocPrint(scratch, "{s}\x00{s}\x00{s}\x00{}\x00{d}", .{
            proxy orelse "",
            ca_info orelse "",
            ca_path orelse "",
            verify,
            if (timeouts.activity) |d| d.nanoseconds else -1,
        });

        try c.transport_mutex.lock(c.io);
        defer c.transport_mutex.unlock(c.io);
        for (c.transports.items) |t| {
            if (std.mem.eql(u8, t.key, key)) return &t.client;
        }
        const t = try c.gpa.create(Transport);
        errdefer c.gpa.destroy(t);
        t.* = .{ .key = try c.gpa.dupe(u8, key), .arena = .init(c.gpa), .client = .init(c.gpa, c.io) };
        errdefer {
            t.client.deinit();
            t.arena.deinit();
            c.gpa.free(t.key);
        }
        t.client.verify = verify;
        t.client.timeouts = timeouts;
        // As many kept as transfers run at once, as git-lfs keeps them.
        t.client.max_idle = @intCast(@max(1, c.settings.getInt("lfs.concurrenttransfers", 8)));
        if (verify and (ca_info != null or ca_path != null)) try c.trust(&t.client, t.arena.allocator(), settings, environ);
        if (proxy) |text| try c.useProxy(&t.client, t.arena.allocator(), text);
        try c.transports.append(c.gpa, t);
        return &t.client;
    }

    /// Trust `http.sslCAInfo` in place of the system's certificates, and
    /// `http.sslCAPath` besides them, as `smarthttp` does for git.
    fn trust(c: *Client, client: *httpclient.Client, arena: Allocator, settings: httpsettings.Settings, environ: ?*const std.process.Environ.Map) Error!void {
        if (settings.ca_info) |raw| {
            const file = try expandHome(arena, raw, environ);
            client.trustFile(file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return c.fail(error.SslCertificateUnreadable, "{s}", .{settings.ca_info_from orelse "http.sslCAInfo"}),
            };
        } else {
            client.trustSystem() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return c.fail(error.SslCertificateUnreadable, "the system's certificates", .{}),
            };
        }
        if (settings.ca_path) |raw| {
            const dir_path = try expandHome(arena, raw, environ);
            client.trustDirectory(dir_path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return c.fail(error.SslCertificateUnreadable, "http.sslCAPath", .{}),
            };
        }
    }

    /// Send `client`'s requests through `text` as Go's client — git-lfs's —
    /// sends them: a plain HTTP request whole, with its absolute URL, and an
    /// `https` one through a `CONNECT` tunnel asked for in Go's words, the
    /// proxy's credential from its URL.
    fn useProxy(c: *Client, client: *httpclient.Client, arena: Allocator, text: []const u8) Error!void {
        const uri = std.Uri.parse(text) catch std.Uri.parseAfterScheme("http", text) catch return c.fail(error.InvalidProxy, "{s}", .{text});
        const tls = if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
            false
        else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
            true
        else
            return c.fail(error.InvalidProxy, "{s} is not an HTTP proxy", .{text});
        const host = uri.getHostAlloc(arena) catch return c.fail(error.InvalidProxy, "{s}", .{text});
        var authorization: ?[]const u8 = null;
        if (uri.user != null or uri.password != null) {
            const value = try arena.alloc(u8, http.Client.basic_authorization.valueLengthFromUri(uri));
            authorization = http.Client.basic_authorization.value(uri, value);
        }
        var lines: std.ArrayList(http.Header) = .empty;
        try lines.append(arena, .{ .name = "User-Agent", .value = "Go-http-client/1.1" });
        if (authorization) |value| try lines.append(arena, .{ .name = "Proxy-Authorization", .value = value });
        client.proxy = .{
            .host = host.bytes,
            .port = uri.port orelse if (tls) 443 else 80,
            .tls = tls,
            .authorization = authorization,
            .connect_headers = lines.items,
        };
    }

    /// The proxy git-lfs's rules choose for `url`, which are not curl's:
    /// `http.<url>.proxy` by git-lfs's URL match when it is not empty; else
    /// for an `https` URL `HTTPS_PROXY`, then `https_proxy`; then for any
    /// URL `HTTP_PROXY`, then `http_proxy` — never `all_proxy`. None for a
    /// host `NO_PROXY`, else `no_proxy`, names, or for `localhost` and a
    /// loopback address: `goProxyAllowed`.
    fn proxyFor(c: *Client, scratch: Allocator, request_url: []const u8, url: url_mod.Url) Error!?[]const u8 {
        const environ: ?*const std.process.Environ.Map = if (c.options.programs) |p| p.environ else null;
        var chosen: ?[]const u8 = null;
        if (try c.settings.urlGet(scratch, "http", request_url, "proxy")) |v| {
            if (v.len != 0) chosen = v;
        }
        if (chosen == null) {
            if (environ) |env| {
                const names: []const []const u8 = if (url.scheme == .https)
                    &.{ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy" }
                else
                    &.{ "HTTP_PROXY", "http_proxy" };
                for (names) |name| {
                    const value = env.get(name) orelse continue;
                    if (value.len == 0) continue;
                    chosen = value;
                    break;
                }
            }
        }
        const proxy = chosen orelse return null;
        var no_proxy: []const u8 = "";
        if (environ) |env| {
            no_proxy = env.get("NO_PROXY") orelse "";
            if (no_proxy.len == 0) no_proxy = env.get("no_proxy") orelse "";
        }
        const port = url.port orelse @as(u16, if (url.scheme == .https) 443 else 80);
        if (!goProxyAllowed(url.host, port, no_proxy)) return null;
        return proxy;
    }

    /// A request to the API for `operation`: `<endpoint>/<suffix>`, with
    /// `git-lfs-authenticate`'s headers for an ssh remote and the API's
    /// media type. A token the server refuses is asked for again once.
    pub fn api(c: *Client, operation: Operation, method: http.Method, suffix: []const u8, body: ?[]const u8, network_retries: u32) Error!*Exchange {
        var asked_again = false;
        while (true) {
            const base = try c.apiBase(operation);
            const e = try c.endpoint(operation);
            if (e.isLocal()) return c.fail(error.LfsEndpointUnknown, "{s} is a repository on this machine and has no LFS API", .{e.url});
            const url = try joinUrl(c.arena.allocator(), base.url, suffix);
            const ex = c.send(.{
                .method = method,
                .url = url,
                .headers = base.headers,
                .body = if (body) |b| .{ .bytes = b } else .none,
                .api = true,
                .access_url = e.url,
                .network_retries = network_retries,
            }) catch |err| switch (err) {
                error.AuthenticationFailed => {
                    if (base.headers.len != 0 and !asked_again) {
                        asked_again = true;
                        continue;
                    }
                    return err;
                },
                else => return err,
            };
            return ex;
        }
    }

    /// The JSON body of an API answer that is not a success: its `message`,
    /// or the status, kept as the client's message, and the error that
    /// names it.
    pub fn failStatus(c: *Client, ex: *Exchange, what: []const u8) Error {
        const status = ex.status();
        const said = c.noteStatusText(ex, what);
        if (status == .forbidden) {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.describeRefusal(.forbidden, 403, ex.url, said, null);
        }
        return if (status == .unauthorized or status == .forbidden) error.AuthenticationFailed else error.HttpStatus;
    }

    /// Keep an answer's status and the server's reason as the client's
    /// message.
    pub fn noteStatus(c: *Client, ex: *Exchange, what: []const u8) void {
        _ = c.noteStatusText(ex, what);
    }

    /// `noteStatus`, returning the server's reason, in the exchange's
    /// arena.
    fn noteStatusText(c: *Client, ex: *Exchange, what: []const u8) []const u8 {
        const status = ex.status();
        const body = ex.readAll(64 * 1024) catch "";
        const Reason = struct { message: ?[]const u8 = null };
        const reason = std.json.parseFromSliceLeaky(Reason, ex.arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch Reason{};
        var buf: [512]u8 = undefined;
        c.setMessage(std.fmt.bufPrint(&buf, "{s}: HTTP {d}{s}{s}", .{
            what,
            @intFromEnum(status),
            if (reason.message != null) ": " else "",
            reason.message orelse "",
        }) catch what);
        return reason.message orelse "";
    }
};

/// A request made and its answer, open for the body.
pub const Exchange = struct {
    client: *Client,
    arena: std.heap.ArenaAllocator,
    /// Where the request went, without a credential, in the exchange's
    /// arena.
    url: []const u8 = "",
    response: httpclient.Response = undefined,
    in_flight: bool = false,
    /// A zstd body's decoder, over the client's undecoded bytes.
    decompress: std.compress.zstd.Decompress = undefined,
    decompress_buffer: []u8 = &.{},
    body: ?*Io.Reader = null,

    /// The answer's status.
    pub fn status(ex: *const Exchange) http.Status {
        return ex.response.head.status;
    }

    /// A header of the answer, or `null`.
    pub fn header(ex: *const Exchange, name: []const u8) ?[]const u8 {
        return ex.response.header(name);
    }

    fn location(ex: *const Exchange) ?[]const u8 {
        return ex.response.head.location;
    }

    const Offers = struct { basic: bool = false, other: bool = false };

    /// The server's `LFS-Authenticate` values, then its `WWW-Authenticate`
    /// ones, into `a`: what git-lfs hands the helpers as `wwwauth[]`.
    fn challenges(ex: *const Exchange, a: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "lfs-authenticate", "www-authenticate" }) |name| {
            var it = ex.response.head.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) try out.append(a, try a.dupe(u8, h.value));
            }
        }
        return out.items;
    }

    /// What the server said in refusing, into `a`: the API's `message`, or
    /// a `text/plain` body, at most 4 KiB. Empty when it said nothing
    /// readable.
    fn refusalText(ex: *Exchange, a: Allocator) []const u8 {
        const content_type = ex.header("content-type") orelse return "";
        const body = ex.readAll(4096) catch return "";
        if (std.ascii.startsWithIgnoreCase(content_type, "text/plain")) return a.dupe(u8, body) catch "";
        if (std.ascii.indexOfIgnoreCase(content_type, "json") == null) return "";
        const Reason = struct { message: ?[]const u8 = null };
        const reason = std.json.parseFromSliceLeaky(Reason, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return "";
        return reason.message orelse "";
    }

    fn authenticateOffers(ex: *const Exchange) Offers {
        var offers: Offers = .{};
        var it = ex.response.head.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "www-authenticate") and !std.ascii.eqlIgnoreCase(h.name, "lfs-authenticate")) continue;
            const value = std.mem.trim(u8, h.value, " \t");
            const end = std.mem.indexOfAny(u8, value, " \t") orelse value.len;
            if (std.ascii.eqlIgnoreCase(value[0..end], "basic")) offers.basic = true else offers.other = true;
        }
        return offers;
    }

    /// `Retry-After` in seconds: a number, or an HTTP date counted from
    /// `Options.now` when the caller gave one.
    pub fn retryAfter(ex: *const Exchange) ?u64 {
        const value = ex.header("retry-after") orelse return null;
        return retryAfterSeconds(value, ex.client.options.now);
    }

    /// The body, read as it arrives, decompressed as its
    /// `Content-Encoding` says.
    pub fn reader(ex: *Exchange) Error!*Io.Reader {
        if (ex.body) |r| return r;
        const r = switch (ex.response.head.content_encoding) {
            // Only asked for by `Request.Accept.zstd`, and handed over by the
            // HTTP client as it came. The window is the one the first
            // frame's header asks for, as git-lfs's decoder gives it, up to
            // the same limit.
            .zstd => blk: {
                const raw = ex.response.reader();
                const window = try zstdWindow(raw);
                ex.decompress_buffer = try ex.arena.allocator().alloc(u8, window + std.compress.zstd.block_size_max);
                ex.decompress = .init(raw, ex.decompress_buffer, .{ .window_len = window });
                break :blk &ex.decompress.reader;
            },
            else => ex.response.reader(),
        };
        ex.body = r;
        return r;
    }

    /// The window a zstd body's first frame needs, read from its header
    /// without taking it off the stream: at least the standard's 8 MiB,
    /// and at most `zstd_window_max`, past which the body is refused.
    fn zstdWindow(raw: *Io.Reader) Error!u32 {
        const Header = std.compress.zstd.Decompress.Frame.Zstandard.Header;
        const head = raw.peek(18) catch raw.buffered();
        const default: u32 = std.compress.zstd.default_window_len;
        if (head.len < 5 or std.mem.readInt(u32, head[0..4], .little) != 0xFD2FB528) return default;
        var fixed: Io.Reader = .fixed(head[4..]);
        const frame = Header.decode(&fixed) catch return default;
        const size = frame.windowSize() orelse return default;
        if (size > zstd_window_max) return error.LfsZstdWindowTooLarge;
        return @intCast(@max(size, default));
    }

    /// The whole body, up to `limit` bytes, owned by the exchange.
    pub fn readAll(ex: *Exchange, limit: usize) Error![]const u8 {
        const r = try ex.reader();
        return r.allocRemaining(ex.arena.allocator(), .limited(limit)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.StreamTooLong,
            error.ReadFailed => ex.client.fail(error.ConnectionFailed, "reading the answer: {s}", .{ex.bodyError()}),
        };
    }

    /// The reason a read of the body failed.
    pub fn bodyError(ex: *const Exchange) []const u8 {
        return switch (ex.response.failure()) {
            error.TimedOut => "timed out",
            else => |err| @errorName(err),
        };
    }

    /// Give the connection back and release everything.
    pub fn close(ex: *Exchange) void {
        const c = ex.client;
        if (ex.in_flight) ex.response.deinit();
        ex.arena.deinit();
        c.gpa.destroy(ex);
    }
};

/// A remote's LFS server and this repository's side of it, open for one
/// operation: the settings, the client, and the store objects come from and
/// go to.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    settings: Settings,
    client: Client,
    /// The repository's store and its fetch settings.
    lfs: lfs.Lfs,
    /// The working tree's absolute path, or the repository's for a bare
    /// one: what a relative local remote is taken against.
    base_path: [:0]u8,
    /// The remote's name, or a URL.
    remote: []u8,
    /// `FETCH_HEAD`, for the endpoint's last resort.
    fetch_head: ?[]u8 = null,
    /// The ref a download's batch names, as git-lfs names it whatever is
    /// fetched: `downloadRef`.
    download_ref: []u8 = &.{},

    /// Errors from opening a server.
    pub const OpenError = Error || Settings.LoadError || LfsconfigError || lfs.Lfs.LoadError || Io.Dir.RealPathFileAllocError;

    /// Open `remote` — a remote's name or a URL — of `repo`, or with `null`
    /// the remote git-lfs would use for a download: `defaultRemote`. Nothing
    /// is sent until an operation asks. `repo` is borrowed for as long as
    /// the server is open.
    pub fn open(gpa: Allocator, io: Io, repo: *repo_mod.Repository, remote: ?[]const u8, options: Options) OpenError!*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .settings = undefined,
            .client = undefined,
            .lfs = undefined,
            .base_path = undefined,
            .remote = undefined,
        };
        s.base_path = try (repo.work_dir orelse repo.common_dir).realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(s.base_path);
        const lfsconfig = try repo.lfsconfigText(io);
        defer if (lfsconfig) |t| repo.gpa.free(t);
        s.settings = .{ .gpa = gpa, .config = &repo.config };
        if (lfsconfig) |t| s.settings.file = try Config.parseText(gpa, t, .local);
        errdefer s.settings.deinit();
        {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const chosen = remote orelse blk: {
                // A branch with no commit yet is no branch to git-lfs, whose
                // current ref comes from resolving `HEAD`.
                const head = try repo.head(io);
                defer if (head) |h| gpa.free(h.name);
                const branch = if (head != null) try repo.refs.currentBranch(scratch.allocator(), io) else null;
                break :blk try defaultRemote(scratch.allocator(), &s.settings, branch, .download);
            };
            s.remote = try gpa.dupe(u8, chosen);
        }
        errdefer gpa.free(s.remote);
        s.fetch_head = try fs.readFileAlloc(gpa, io, repo.git_dir, "FETCH_HEAD", 1 << 20);
        errdefer if (s.fetch_head) |f| gpa.free(f);
        s.download_ref = try downloadRef(gpa, io, repo, &s.settings);
        errdefer gpa.free(s.download_ref);
        s.lfs = try lfs.Lfs.load(gpa, io, &repo.config, repo.common_dir, null, .{ .lfsconfig = lfsconfig });
        errdefer s.lfs.deinit();
        s.client = try Client.init(gpa, io, &s.settings, s.remote, .{ .base = s.base_path, .fetch_head = s.fetch_head }, options);
        return s;
    }

    /// Close everything.
    pub fn close(s: *Server) void {
        const gpa = s.gpa;
        s.client.deinit();
        s.lfs.deinit();
        s.settings.deinit();
        gpa.free(s.base_path);
        gpa.free(s.remote);
        if (s.fetch_head) |f| gpa.free(f);
        gpa.free(s.download_ref);
        gpa.destroy(s);
    }

    /// The repository's store.
    pub fn store(s: *const Server) *const lfs.Store {
        return &s.lfs.store;
    }
};

/// The ref git-lfs names in every download's batch, whatever the download
/// is for: the branch `HEAD` is on, or its `branch.<name>.merge` when that
/// is set; `HEAD` when it is detached; and nothing on a branch with no
/// commit yet, which git-lfs cannot resolve. The result is the caller's.
pub fn downloadRef(gpa: Allocator, io: Io, repo: *repo_mod.Repository, settings: *const Settings) (Error || @import("refs.zig").ReadError)![]u8 {
    const head = (try repo.head(io)) orelse return gpa.dupe(u8, "");
    defer repo.gpa.free(head.name);
    if (!std.mem.startsWith(u8, head.name, "refs/heads/")) return gpa.dupe(u8, head.name);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const key = try std.fmt.allocPrint(a, "branch.{s}.merge", .{head.name["refs/heads/".len..]});
    if (try settings.get(a, key)) |merge| return gpa.dupe(u8, merge);
    return gpa.dupe(u8, head.name);
}

fn expandHome(arena: Allocator, path: []const u8, environ: ?*const std.process.Environ.Map) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const env = environ orelse return path;
    const home = env.get("HOME") orelse return path;
    return std.fs.path.join(arena, &.{ home, path[2..] });
}

/// git-lfs's timeouts for a request to `url`: `lfs.dialtimeout` and
/// `lfs.tlstimeout` in seconds, 30 when unset or below one; and
/// `lfs.https://<host>.activitytimeout`, or `lfs.activitytimeout`, 30
/// when unset and none at all when zero or not a number. The host is
/// looked up under `https://` whatever the URL's scheme, as git-lfs looks
/// it up.
pub fn timeoutsFor(settings: *const Settings, scratch: Allocator, url: url_mod.Url) Error!httpclient.Timeouts {
    const dial = settings.getInt("lfs.dialtimeout", 0);
    const handshake = settings.getInt("lfs.tlstimeout", 0);
    const host_url = if (url.port) |port|
        try std.fmt.allocPrint(scratch, "https://{s}:{d}", .{ url.host, port })
    else
        try std.fmt.allocPrint(scratch, "https://{s}", .{url.host});
    var activity: i64 = 30;
    if (try settings.urlGet(scratch, "lfs", host_url, "activitytimeout")) |text| {
        activity = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t"), 10) catch 0;
    }
    return .{
        .connect = .fromSeconds(if (dial < 1) 30 else dial),
        .handshake = .fromSeconds(if (handshake < 1) 30 else handshake),
        .activity = if (activity > 0) .fromSeconds(activity) else null,
    };
}

/// Whether a request to `host` on `port` goes through a proxy by Go's
/// rules, which git-lfs's client follows: never for `localhost` or a
/// loopback address, and not for a host `no_proxy` names — `*`, a domain
/// and the hosts under it, `.domain` or `*.domain` for the hosts under it
/// only, an address, or a range of addresses, each with a port or without.
pub fn goProxyAllowed(raw_host: []const u8, port: u16, no_proxy: []const u8) bool {
    const host = std.mem.trim(u8, std.mem.trim(u8, raw_host, " "), "[]");
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return false;
    const ip: ?Io.net.IpAddress = Io.net.IpAddress.parse(host, 0) catch null;
    if (ip) |a| if (isLoopback(a)) return false;
    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
    var it = std.mem.splitScalar(u8, no_proxy, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return false;
        if (std.mem.indexOfScalar(u8, entry, '/')) |slash| {
            // A range: `10.0.0.0/8`, `fd00::/8`.
            const base = Io.net.IpAddress.parse(entry[0..slash], 0) catch continue;
            const bits = std.fmt.parseInt(u8, entry[slash + 1 ..], 10) catch continue;
            if (ip) |a| if (inRange(a, base, bits)) return false;
            continue;
        }
        // `host:port` or `[v6]:port`, else the entry is all host.
        var entry_host = entry;
        var entry_port: []const u8 = "";
        if (splitHostPort(entry)) |hp| {
            entry_host = hp.host;
            entry_port = hp.port;
            if (entry_host.len == 0) continue;
        }
        if (Io.net.IpAddress.parse(entry_host, 0)) |entry_ip| {
            if (ip) |a| if (sameAddress(a, entry_ip) and (entry_port.len == 0 or std.mem.eql(u8, entry_port, port_text))) return false;
            continue;
        } else |_| {}
        if (ip != null) continue;
        var domain = entry_host;
        if (std.mem.startsWith(u8, domain, "*.")) domain = domain[1..];
        const match_host = domain[0] != '.';
        const suffix_ok = if (match_host)
            host.len > domain.len and std.ascii.endsWithIgnoreCase(host, domain) and host[host.len - domain.len - 1] == '.'
        else
            std.ascii.endsWithIgnoreCase(host, domain);
        const exact = match_host and std.ascii.eqlIgnoreCase(host, domain);
        if ((suffix_ok or exact) and (entry_port.len == 0 or std.mem.eql(u8, entry_port, port_text))) return false;
    }
    return true;
}

fn splitHostPort(text: []const u8) ?struct { host: []const u8, port: []const u8 } {
    if (text.len != 0 and text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return null;
        if (close + 1 >= text.len or text[close + 1] != ':') return null;
        return .{ .host = text[1..close], .port = text[close + 2 ..] };
    }
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    // More than one colon is an IPv6 address with no port.
    if (std.mem.indexOfScalarPos(u8, text, colon + 1, ':') != null) return null;
    return .{ .host = text[0..colon], .port = text[colon + 1 ..] };
}

fn addressBytes(a: Io.net.IpAddress, buf: *[16]u8) []const u8 {
    switch (a) {
        .ip4 => |v4| {
            buf[0..4].* = v4.bytes;
            return buf[0..4];
        },
        .ip6 => |v6| {
            // An IPv4 address written as IPv6 is that IPv4 address.
            if (std.mem.eql(u8, v6.bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                buf[0..4].* = v6.bytes[12..16].*;
                return buf[0..4];
            }
            buf.* = v6.bytes;
            return buf[0..16];
        },
    }
}

fn isLoopback(a: Io.net.IpAddress) bool {
    var buf: [16]u8 = undefined;
    const bytes = addressBytes(a, &buf);
    if (bytes.len == 4) return bytes[0] == 127;
    return std.mem.eql(u8, bytes, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
}

fn sameAddress(a: Io.net.IpAddress, b: Io.net.IpAddress) bool {
    var abuf: [16]u8 = undefined;
    var bbuf: [16]u8 = undefined;
    return std.mem.eql(u8, addressBytes(a, &abuf), addressBytes(b, &bbuf));
}

fn inRange(a: Io.net.IpAddress, base: Io.net.IpAddress, bits: u8) bool {
    var abuf: [16]u8 = undefined;
    var bbuf: [16]u8 = undefined;
    const x = addressBytes(a, &abuf);
    const y = addressBytes(base, &bbuf);
    if (x.len != y.len or bits > x.len * 8) return false;
    var i: usize = 0;
    while (i < bits) : (i += 1) {
        const mask = @as(u8, 0x80) >> @intCast(i % 8);
        if ((x[i / 8] & mask) != (y[i / 8] & mask)) return false;
    }
    return true;
}

/// A `Retry-After` value in seconds, as git-lfs reads it: a whole number,
/// or with `now` an HTTP date, a date gone by being no wait at all.
pub fn retryAfterSeconds(value: []const u8, now: ?i64) ?u64 {
    const text = std.mem.trim(u8, value, " \t");
    if (std.fmt.parseInt(u64, text, 10)) |n| return n else |_| {}
    const at = timetext.parseHttpDate(text) orelse return null;
    const from = now orelse return null;
    return @intCast(@max(0, at - from));
}

/// A private directory for OpenSSH's control socket, as git-lfs makes one:
/// in `XDG_RUNTIME_DIR`, else `/tmp` on macOS, whose own temporary
/// directory makes a socket path too long, else `TMPDIR` or `/tmp`. `null`
/// when none can be made, and ssh runs unshared.
fn controlDir(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    const base = environ.get("XDG_RUNTIME_DIR") orelse if (builtin.os.tag == .macos)
        "/tmp"
    else
        (environ.get("TMPDIR") orelse "/tmp");
    var name_buf: [64]u8 = undefined;
    const name = fs.tempName(io, &name_buf, "sock-");
    const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), name });
    const private: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    Io.Dir.cwd().createDir(io, dir, private) catch return null;
    return dir;
}

/// A boolean as git-lfs reads one: unset or empty is `fallback`, and a
/// word it does not know is false.
pub fn gitLfsBool(value: ?[]const u8, fallback: bool) bool {
    const v = value orelse return fallback;
    if (v.len == 0) return fallback;
    for ([_][]const u8{ "true", "1", "on", "yes", "t" }) |word| {
        if (std.ascii.eqlIgnoreCase(v, word)) return true;
    }
    return false;
}

/// A header the HTTP client writes itself, from the request, and never
/// from what a server or the configuration hands over.
fn framingHeader(name: []const u8) bool {
    for ([_][]const u8{ "content-length", "transfer-encoding", "host" }) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

fn hasHeader(headers: []const http.Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

/// `Basic <base64 of user:password>`.
fn basicHeader(a: Allocator, user: []const u8, password: []const u8) Allocator.Error![]const u8 {
    const plain = try std.fmt.allocPrint(a, "{s}:{s}", .{ user, password });
    const encoder = std.base64.standard.Encoder;
    const out = try a.alloc(u8, "Basic ".len + encoder.calcSize(plain.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = encoder.encode(out["Basic ".len..], plain);
    return out;
}

/// The URL without `user[:password]@`, in `a` when there was one to take
/// out.
pub fn stripUserinfo(a: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return url;
    const start = sep + 3;
    const path_at = std.mem.indexOfAnyPos(u8, url, start, "/?#") orelse url.len;
    const at = std.mem.lastIndexOfScalar(u8, url[start..path_at], '@') orelse return url;
    return std.mem.concat(a, u8, &.{ url[0..start], url[start + at + 1 ..] });
}

/// The URL without its query, which may hold a token, for a message.
pub fn stripQuery(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfScalar(u8, url, '?') orelse url.len];
}

/// `prefix` and `suffix` with one slash between them, as git-lfs joins
/// them.
pub fn joinUrl(a: Allocator, prefix: []const u8, suffix: []const u8) Allocator.Error![]const u8 {
    if (std.mem.endsWith(u8, prefix, "/")) return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, suffix });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, suffix });
}

/// `location` taken against `base`, as a redirect is.
fn resolveLocation(a: Allocator, base: []const u8, location: []const u8) Error![]const u8 {
    if (UrlParts.parse(location) != null) return a.dupe(u8, location);
    const sep = std.mem.indexOf(u8, base, "://") orelse return error.MalformedUrl;
    const origin_end = std.mem.indexOfAnyPos(u8, base, sep + 3, "/?#") orelse base.len;
    if (location.len != 0 and location[0] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ base[0..origin_end], location });
    const path_end = std.mem.indexOfAnyPos(u8, base, origin_end, "?#") orelse base.len;
    const dir_end = std.mem.lastIndexOfScalar(u8, base[origin_end..path_end], '/') orelse 0;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base[0 .. origin_end + dir_end], location });
}

/// The part of a URL that names a credential for git-lfs's cache:
/// the scheme, the host and the path.
fn credentialKey(url: []const u8) []const u8 {
    return stripQuery(url);
}

const testing = std.testing;

fn testSettings(text: []const u8, file_text: ?[]const u8) !struct { config: *Config, settings: Settings } {
    const config = try testing.allocator.create(Config);
    config.* = try Config.parseText(testing.allocator, text, .local);
    var settings: Settings = .{ .gpa = testing.allocator, .config = config };
    if (file_text) |t| settings.file = try Config.parseText(testing.allocator, t, .local);
    return .{ .config = config, .settings = settings };
}

fn freeSettings(t: anytype) void {
    var s = t.settings;
    s.deinit();
    t.config.deinit();
    testing.allocator.destroy(t.config);
}

test "the endpoint is found where git-lfs looks for it, in git-lfs's order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { config: []const u8, remote: []const u8 = "origin", op: Operation = .download, want: []const u8 };
    const cases = [_]Case{
        .{ .config = "[remote \"origin\"]\nurl = https://git.example.com/org/repo.git\n", .want = "https://git.example.com/org/repo.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = https://git.example.com/org/repo\n", .want = "https://git.example.com/org/repo.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = https://git.example.com/org/repo/\n", .want = "https://git.example.com/org/repo.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = git@git.example.com:org/repo.git\n", .want = "https://git.example.com/org/repo.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = ssh://git@git.example.com:2222/org/repo.git\n", .want = "https://git.example.com/org/repo.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = git://git.example.com/org/repo.git\n", .want = "https://git.example.com/org/repo.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = https://a/r.git\nlfsurl = https://lfs.example.com/r\n", .want = "https://lfs.example.com/r" },
        .{ .config = "[remote \"origin\"]\nurl = https://a/r.git\nlfsurl = https://lfs/r\nlfspushurl = https://push/r\n", .op = .upload, .want = "https://push/r" },
        .{ .config = "[remote \"origin\"]\nurl = https://a/r.git\npushurl = https://p/r.git\n", .op = .upload, .want = "https://p/r.git/info/lfs" },
        .{ .config = "[lfs]\nurl = https://lfs.example.com/all\n[remote \"origin\"]\nlfsurl = https://ignored\n", .want = "https://lfs.example.com/all" },
        .{ .config = "[lfs]\nurl = https://u\npushurl = https://p\n", .op = .upload, .want = "https://p" },
        .{ .config = "[remote \"other\"]\nurl = https://o/r.git\n[remote \"origin\"]\nurl = https://a/r.git\n", .remote = "other", .want = "https://o/r.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = https://a/r.git\n", .remote = "nothere", .want = "https://a/r.git/info/lfs" },
        .{ .config = "[url \"https://mirror.example.com/\"]\ninsteadOf = gh:\n[remote \"origin\"]\nurl = gh:org/repo\n", .want = "https://mirror.example.com/org/repo.git/info/lfs" },
        .{ .config = "", .remote = "https://direct.example.com/r.git", .want = "https://direct.example.com/r.git/info/lfs" },
        .{ .config = "[remote \"origin\"]\nurl = /srv/repo.git\n", .want = "file:///srv/repo.git" },
    };
    for (cases) |case| {
        var t = try testSettings(case.config, null);
        defer freeSettings(&t);
        const e = try findEndpoint(a, &t.settings, case.remote, case.op, .{ .base = "/work" });
        try testing.expectEqualStrings(case.want, e.url);
    }
    {
        var t = try testSettings("[remote \"origin\"]\nurl = ssh://git@host.example:2222/org/repo.git\n", null);
        defer freeSettings(&t);
        const e = try findEndpoint(a, &t.settings, "origin", .download, .{});
        try testing.expectEqualStrings("git@host.example", e.ssh.?.user_and_host);
        try testing.expectEqualStrings("2222", e.ssh.?.port.?);
        try testing.expectEqualStrings("/org/repo.git", e.ssh.?.path);
    }
    {
        var t = try testSettings("[remote \"origin\"]\nurl = host.example:org/repo.git\n", null);
        defer freeSettings(&t);
        const e = try findEndpoint(a, &t.settings, "origin", .download, .{});
        try testing.expectEqualStrings("host.example", e.ssh.?.user_and_host);
        try testing.expectEqualStrings("org/repo.git", e.ssh.?.path);
    }
    {
        var t = try testSettings("", null);
        defer freeSettings(&t);
        try testing.expectError(error.LfsEndpointUnknown, findEndpoint(a, &t.settings, "origin", .download, .{}));
    }
}

test ".lfsconfig sets only what git-lfs lets it, and the configuration wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = try testSettings("[lfs]\nfetchexclude = mine\n", "[lfs]\nurl = https://from-file/lfs\nfetchexclude = theirs\nconcurrenttransfers = 99\n" ++
        "[remote \"origin\"]\nlfsurl = https://remote-from-file\nurl = https://evil\n[lfs \"https://from-file/\"]\naccess = basic\n[core]\nsshCommand = evil\n");
    defer freeSettings(&t);
    try testing.expectEqualStrings("https://from-file/lfs", (try t.settings.get(a, "lfs.url")).?);
    try testing.expectEqualStrings("mine", (try t.settings.get(a, "lfs.fetchexclude")).?);
    try testing.expectEqual(@as(i64, 8), t.settings.getInt("lfs.concurrenttransfers", 8));
    try testing.expect((try t.settings.get(a, "remote.origin.url")) == null);
    try testing.expectEqualStrings("https://remote-from-file", (try t.settings.get(a, "remote.origin.lfsurl")).?);
    try testing.expect((try t.settings.get(a, "core.sshcommand")) == null);
    try testing.expectEqualStrings("basic", (try t.settings.urlGet(a, "lfs", "https://from-file/lfs", "access")).?);
}

test "URL-scoped settings match as git-lfs matches them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = try testSettings(
        \\[lfs]
        \\    locksverify = default
        \\[lfs "https://git.example.com"]
        \\    locksverify = host
        \\[lfs "https://git.example.com/org"]
        \\    locksverify = org
        \\[lfs "https://git.example.com/org/repo"]
        \\    locksverify = repo
        \\[lfs "https://*.example.com"]
        \\    locksverify = wildcard
        \\[lfs "https://ada@git.example.com/org"]
        \\    locksverify = ada
        \\
    , null);
    defer freeSettings(&t);
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "https://git.example.com/org/repo.git/info/lfs", "repo" },
        .{ "https://git.example.com/org/other.git/info/lfs", "org" },
        .{ "https://ada@git.example.com/org/other.git/info/lfs", "ada" },
        .{ "https://git.example.com/elsewhere", "host" },
        .{ "https://lfs.example.com/x", "wildcard" },
        .{ "https://git.example.com:8443/org", "default" },
        .{ "http://git.example.com/org", "default" },
    }) |case| {
        try testing.expectEqualStrings(case[1], (try t.settings.urlGet(a, "lfs", case[0], "locksverify")).?);
    }

    // A section with more in its name before the URL, as
    // `lfs.transfer.<url>.httpDownloadEncoding`.
    var u = try testSettings(
        \\[lfs "transfer"]
        \\    httpDownloadEncoding = gzip
        \\[lfs "transfer.https://git.example.com/org"]
        \\    httpDownloadEncoding = zstd
        \\[lfs "https://git.example.com/org"]
        \\    httpDownloadEncoding = not this
        \\
    , null);
    defer freeSettings(&u);
    try testing.expectEqualStrings("zstd", (try u.settings.urlGet(a, "lfs.transfer", "https://git.example.com/org/repo", "httpdownloadencoding")).?);
    try testing.expectEqualStrings("gzip", (try u.settings.urlGet(a, "lfs.transfer", "https://elsewhere.example.com/x", "httpdownloadencoding")).?);
}

test "ssh is started as git-lfs starts it for git-lfs-authenticate" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var t = try testSettings("", null);
    defer freeSettings(&t);
    const ssh: Endpoint.Ssh = .{ .user_and_host = "git@host", .port = "2222", .path = "/org/repo.git" };

    var inv = try sshArguments(a, &env, &t.settings, ssh, .download);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "ssh", "-p", "2222", "git@host", "git-lfs-authenticate /org/repo.git download" }), inv.argv);
    try testing.expect(!inv.shell);

    try env.put("GIT_SSH", "/usr/bin/plink.exe");
    inv = try sshArguments(a, &env, &t.settings, ssh, .upload);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "/usr/bin/plink.exe", "-P", "2222", "git@host", "git-lfs-authenticate /org/repo.git upload" }), inv.argv);

    try env.put("GIT_SSH_COMMAND", "ssh -i key");
    inv = try sshArguments(a, &env, &t.settings, .{ .user_and_host = "-oProxyCommand=x", .path = "r" }, .upload);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "ssh -i key", "--", "-oProxyCommand=x", "git-lfs-authenticate r upload" }), inv.argv);
    try testing.expect(inv.shell);
}

test "git-lfs-authenticate's answer is read, and a header with a line break is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const auth = try parseAuthenticate(a, "{\"href\":\"https://lfs.example.com/r\",\"header\":{\"Authorization\":\"RemoteAuth abc\"},\"expires_in\":3600}");
    try testing.expectEqualStrings("https://lfs.example.com/r", auth.href.?);
    try testing.expectEqualStrings("RemoteAuth abc", auth.headers[0].value);
    try testing.expectError(error.InvalidHttpHeader, parseAuthenticate(a, "{\"header\":{\"X\":\"a\\r\\nInjected: 1\"}}"));
    try testing.expectError(error.MalformedResponse, parseAuthenticate(a, "not json"));
}

test "fuzz: any answer from git-lfs-authenticate is read or refused by name" {
    try testing.fuzz({}, fuzzAuthenticate, .{});
}

fn fuzzAuthenticate(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [512]u8 = undefined;
    const n = smith.slice(&scratch);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const auth = parseAuthenticate(arena_state.allocator(), scratch[0..n]) catch |err| switch (err) {
        error.MalformedResponse, error.InvalidHttpHeader => return,
        else => return err,
    };
    for (auth.headers) |h| try checkHeader(h.name, h.value);
}

test "FETCH_HEAD's first line names the URL as git-lfs's pattern reads it" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    try testing.expectEqualStrings("https://git.example.com/r.git", fetchHeadUrl(oid ++ "\t\tbranch 'main' of https://git.example.com/r.git\n").?);
    try testing.expectEqualStrings("/srv/repo", fetchHeadUrl(oid ++ "\tnot-for-merge\ttag 'v1' of /srv/repo\n").?);
    try testing.expectEqualStrings("host:path", fetchHeadUrl(oid ++ "\t\t'HEAD' of host:path").?);
    try testing.expect(fetchHeadUrl(oid ++ "\t\tbranch 'main' of https://x/a b\n") == null);
    try testing.expect(fetchHeadUrl("xyz\t\tbranch 'main' of https://x\n") == null);
    try testing.expect(fetchHeadUrl("") == null);
}

test "git-lfs's timeouts are read as git-lfs reads them: 30 seconds unless set, the activity one by host under https" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { text: []const u8, url: []const u8, connect: i64, handshake: i64, activity: ?i64 };
    for ([_]Case{
        .{ .text = "", .url = "https://h/x", .connect = 30, .handshake = 30, .activity = 30 },
        .{ .text = "[lfs]\n\tdialtimeout = 0\n\ttlstimeout = 5\n\tactivitytimeout = 0\n", .url = "https://h/x", .connect = 30, .handshake = 5, .activity = null },
        .{ .text = "[lfs]\n\tdialtimeout = 7\n\tactivitytimeout = soon\n", .url = "http://h/x", .connect = 7, .handshake = 30, .activity = null },
        // The host's own, found under https:// even for an http URL.
        .{ .text = "[lfs]\n\tactivitytimeout = 9\n[lfs \"https://h\"]\n\tactivitytimeout = 3\n", .url = "http://h/x", .connect = 30, .handshake = 30, .activity = 3 },
        .{ .text = "[lfs \"https://other\"]\n\tactivitytimeout = 3\n", .url = "https://h/x", .connect = 30, .handshake = 30, .activity = 30 },
    }) |case| {
        var t = try testSettings(case.text, null);
        defer freeSettings(&t);
        const timeouts = try timeoutsFor(&t.settings, a, try url_mod.Url.parse(case.url));
        try testing.expectEqual(Io.Duration.fromSeconds(case.connect), timeouts.connect.?);
        try testing.expectEqual(Io.Duration.fromSeconds(case.handshake), timeouts.handshake.?);
        if (case.activity) |secs| try testing.expectEqual(Io.Duration.fromSeconds(secs), timeouts.activity.?) else try testing.expectEqual(@as(?Io.Duration, null), timeouts.activity);
    }
}

test "NO_PROXY and loopback addresses are read as Go's proxy rules read them" {
    const Case = struct { host: []const u8, port: u16 = 443, list: []const u8, proxied: bool };
    for ([_]Case{
        .{ .host = "localhost", .list = "", .proxied = false },
        .{ .host = "127.0.0.1", .list = "", .proxied = false },
        .{ .host = "127.8.9.10", .list = "", .proxied = false },
        .{ .host = "::1", .list = "", .proxied = false },
        .{ .host = "[::1]", .list = "", .proxied = false },
        .{ .host = "git.example.com", .list = "", .proxied = true },
        .{ .host = "git.example.com", .list = "*", .proxied = false },
        .{ .host = "git.example.com", .list = "example.com", .proxied = false },
        .{ .host = "example.com", .list = "example.com", .proxied = false },
        .{ .host = "badexample.com", .list = "example.com", .proxied = true },
        .{ .host = "example.com", .list = ".example.com", .proxied = true },
        .{ .host = "git.example.com", .list = ".example.com", .proxied = false },
        .{ .host = "example.com", .list = "*.example.com", .proxied = true },
        .{ .host = "git.EXAMPLE.com", .list = " other.org , Example.com ", .proxied = false },
        .{ .host = "git.example.com", .port = 443, .list = "example.com:8443", .proxied = true },
        .{ .host = "git.example.com", .port = 8443, .list = "example.com:8443", .proxied = false },
        .{ .host = "10.1.2.3", .list = "10.0.0.0/8", .proxied = false },
        .{ .host = "11.1.2.3", .list = "10.0.0.0/8", .proxied = true },
        .{ .host = "192.168.1.5", .list = "192.168.1.5", .proxied = false },
        .{ .host = "192.168.1.5", .port = 80, .list = "192.168.1.5:8080", .proxied = true },
        .{ .host = "fd00::1", .list = "fd00::/8", .proxied = false },
        .{ .host = "10.1.2.3", .list = "10.1.2.3.example", .proxied = true },
    }) |case| {
        testing.expectEqual(case.proxied, goProxyAllowed(case.host, case.port, case.list)) catch |err| {
            std.debug.print("{s}:{d} with NO_PROXY={s}\n", .{ case.host, case.port, case.list });
            return err;
        };
    }
}

test "Retry-After is a number of seconds, or a date counted from the time the caller gives" {
    try testing.expectEqual(@as(?u64, 120), retryAfterSeconds(" 120 ", null));
    try testing.expectEqual(@as(?u64, null), retryAfterSeconds("Sun, 06 Nov 1994 08:49:37 GMT", null));
    try testing.expectEqual(@as(?u64, 23), retryAfterSeconds("Sun, 06 Nov 1994 08:49:37 GMT", 784111777 - 23));
    try testing.expectEqual(@as(?u64, 0), retryAfterSeconds("Sun, 06 Nov 1994 08:49:37 GMT", 784111777 + 60));
    try testing.expectEqual(@as(?u64, null), retryAfterSeconds("soon", 0));
    // An expiry wins by `in` over `at`, and five seconds' margin is kept.
    try testing.expect(expiresWithin(1000, 4, null, 5));
    try testing.expect(!expiresWithin(1000, 5, 0, 5));
    try testing.expect(expiresWithin(1000, 0, 1004, 5));
    try testing.expect(!expiresWithin(1000, 0, 1005, 5));
    try testing.expect(!expiresWithin(1000, 0, null, 5));
}
