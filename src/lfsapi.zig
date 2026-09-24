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
//! a header that authenticates to it. A repository on this machine has no API
//! at all; its objects are copied between the two stores.
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
//! relic reads no clock. An action or a token the server says will expire is
//! not checked against one; a request refused because one has is retried with
//! a fresh batch, which is how git-lfs retries every failed transfer anyway.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const config_mod = @import("config.zig");
const program = @import("program.zig");
const credential = @import("credential.zig");
const url_mod = @import("url.zig");
const remote_mod = @import("remote.zig");
const repo_mod = @import("repo.zig");
const lfs = @import("lfs.zig");
const fs = @import("fs.zig");
const object = @import("object.zig");
const netrc_mod = @import("netrc.zig");

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

/// The media type of the API's requests and answers.
pub const media_type = "application/vnd.git-lfs+json";

/// Errors from finding a server and talking to it.
pub const Error = error{
    /// There is no URL to find the server from: no `lfs.url`, no remote of
    /// that name with a URL, and the name is not a URL itself.
    LfsEndpointUnknown,
    /// `lfs.<url>.sshtransfer` is `always`: git-lfs's pure-ssh protocol,
    /// which relic does not speak. Its default, `negotiate`, falls back to
    /// `git-lfs-authenticate`, which is what relic does.
    LfsSshTransferUnsupported,
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
    /// `http.sslVerify` is false, which the standard library's TLS client
    /// cannot honour and relic does not pretend to.
    SslVerifyUnsupported,
    /// `http.sslCAInfo`, `http.sslCAPath`, `http.sslCert` or `http.sslKey`.
    SslCertificateSettingUnsupported,
    /// A header from the configuration or from the server holds a line
    /// break, or has no name.
    InvalidHttpHeader,
    /// A proxy that does not parse.
    InvalidProxy,
    /// ssh is a program, and the caller handed in no `program.Programs`.
    ProgramsNotGranted,
    /// A configuration value that does not unquote.
    MalformedValue,
    /// An answer larger than the operation reads.
    StreamTooLong,
} || credential.Error || Allocator.Error || Io.Cancelable;

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
    /// it: `lfsconfigText`. `repo`'s configuration is borrowed.
    pub fn loadRepo(gpa: Allocator, io: Io, repo: *repo_mod.Repository) (LoadError || LfsconfigError)!Settings {
        var s: Settings = .{ .gpa = gpa, .config = &repo.config };
        const text = (try lfsconfigText(gpa, io, repo)) orelse return s;
        defer gpa.free(text);
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
    /// value of the winning key, oldest first, unquoted into `a`.
    pub fn urlGetAll(s: *const Settings, a: Allocator, section: []const u8, url: []const u8, key: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const sources = [_]?*const Config{ s.config, if (s.file) |*f| f else null };
        for (sources, 0..) |maybe, source_index| {
            const config = maybe orelse continue;
            const best = bestUrlMatch(config, section, url, key, source_index == 1);
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
                if (!entry.matches(section, null, key)) continue;
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
pub const LfsconfigError = Allocator.Error || Io.Dir.ReadFileAllocError ||
    @import("index.zig").ReadError || @import("odb.zig").Error || repo_mod.Error;

/// `.lfsconfig` as git-lfs finds it: the file at the top of the working
/// tree, else its version in the index, else its version in `HEAD`; only
/// `HEAD`'s in a bare repository. `null` when none of them has one. The
/// text is the caller's.
pub fn lfsconfigText(gpa: Allocator, io: Io, repo: *repo_mod.Repository) LfsconfigError!?[]u8 {
    if (repo.work_dir) |wd| {
        if (try fs.readFileAlloc(gpa, io, wd, ".lfsconfig", 1 << 20)) |text| return text;
        var index = repo.openIndex(io) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        if (index) |*ix| {
            defer ix.deinit();
            if (ix.find(".lfsconfig")) |entry| {
                if (entry.stage == 0 and (entry.mode == .file or entry.mode == .exec)) {
                    const found = try repo.odb.read(io, entry.oid);
                    return found.bytes;
                }
            }
        }
    }
    const tree = (try repo.headTree(io)) orelse return null;
    const found = try repo.odb.read(io, tree);
    defer repo.odb.gpa.free(found.bytes);
    const entry = (object.Tree.parse(repo.kind, found.bytes).find(".lfsconfig") catch return null) orelse return null;
    if (entry.mode != .file and entry.mode != .exec) return null;
    const blob = try repo.odb.read(io, entry.oid);
    return blob.bytes;
}

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
fn bestUrlMatch(config: *const Config, section: []const u8, url: []const u8, key: []const u8, from_file: bool) ?[]const u8 {
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
        const configured = UrlParts.parse(entry.subsection) orelse continue;
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
};

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

    const Variant = enum { ssh, simple, putty, tortoise };
    var variant: Variant = .ssh;
    var named: ?[]const u8 = environ.get("GIT_SSH_VARIANT");
    if (named == null) named = try settings.get(arena, "ssh.variant");
    var autodetect = true;
    if (named) |text| {
        if (std.mem.eql(u8, text, "auto")) {
            autodetect = true;
        } else {
            autodetect = false;
            variant = if (std.mem.eql(u8, text, "simple"))
                .simple
            else if (std.mem.eql(u8, text, "putty") or std.mem.eql(u8, text, "plink"))
                .putty
            else if (std.mem.eql(u8, text, "tortoiseplink"))
                .tortoise
            else
                .ssh;
        }
    }
    if (autodetect) {
        var base = program_name[if (std.mem.lastIndexOfAny(u8, program_name, "/\\")) |s| s + 1 else 0..];
        if (!std.mem.eql(u8, base, "ssh")) {
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
        }
        if (std.ascii.eqlIgnoreCase(base, "plink")) variant = .putty;
        if (std.ascii.eqlIgnoreCase(base, "tortoiseplink")) variant = .tortoise;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, command);
    if (variant == .tortoise) try argv.append(arena, "-batch");
    if (ssh.port) |port| {
        try argv.append(arena, if (variant == .putty or variant == .tortoise) "-P" else "-p");
        try argv.append(arena, port);
    }
    if (ssh.user_and_host.len != 0 and ssh.user_and_host[0] == '-') {
        if (variant == .ssh) {
            try argv.appendSlice(arena, &.{ "--", ssh.user_and_host });
        } else try argv.append(arena, std.mem.trimStart(u8, ssh.user_and_host, "-"));
    } else try argv.append(arena, ssh.user_and_host);
    try argv.append(arena, try std.fmt.allocPrint(arena, "git-lfs-authenticate {s} {s}", .{ ssh.path, @tagName(operation) }));
    return .{ .argv = argv.items, .shell = shell, .stderr = .capture, .unset = &program.repository_variables };
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
    return .{ .href = parsed.href, .headers = headers.items };
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
    http: http.Client,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    endpoints: [2]?Endpoint = .{ null, null },
    ssh_auth: [2]?SshAuth = .{ null, null },
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

    /// Open a client for `remote`. `settings` is borrowed.
    pub fn init(gpa: Allocator, io: Io, settings: *const Settings, remote: []const u8, where: Where, options: Options) Error!Client {
        var c: Client = .{
            .gpa = gpa,
            .io = io,
            .settings = settings,
            .remote = remote,
            .where = where,
            .options = options,
            .http = .{ .allocator = gpa, .io = io },
            .arena = .init(gpa),
        };
        errdefer c.arena.deinit();
        const config = settings.config;
        if (config.has("http.sslverify") and !(config.getBool("http.sslverify", true) catch true)) {
            return error.SslVerifyUnsupported;
        }
        for ([_][]const u8{ "http.sslcainfo", "http.sslcapath", "http.sslcert", "http.sslkey" }) |key| {
            if (config.has(key)) return error.SslCertificateSettingUnsupported;
        }
        try c.configureProxies();
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
        c.http.deinit();
        c.arena.deinit();
        c.* = undefined;
    }

    /// What the server or the program last said about a failure.
    pub fn message(c: *const Client) []const u8 {
        return c.message_buf[0..c.message_len];
    }

    fn setMessage(c: *Client, text: []const u8) void {
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
        if (c.ssh_auth[i]) |a| return a;
        const ssh = e.ssh orelse {
            c.ssh_auth[i] = .{};
            return .{};
        };
        const arena = c.arena.allocator();
        if (try c.settings.urlGet(arena, "lfs", e.original, "sshtransfer")) |mode| {
            if (std.mem.eql(u8, mode, "always")) return error.LfsSshTransferUnsupported;
        }
        const programs = c.options.programs orelse return error.ProgramsNotGranted;
        const invocation = try sshArguments(arena, programs.environ, c.settings, ssh, operation);
        const retries: usize = @intCast(@max(0, c.settings.getInt("lfs.ssh.retries", 5)));
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var outcome = try program.run(programs, c.gpa, c.io, invocation, "", .{ .output = .limited(1 << 20) });
            defer outcome.deinit(c.gpa);
            if (outcome.succeeded()) {
                const auth = try parseAuthenticate(arena, try arena.dupe(u8, outcome.stdout));
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
        /// Ask for the body as it is stored, not compressed on the way: an
        /// object, whose bytes a `Range` counts.
        identity: bool = false,
        /// Told of every chunk of an `object` body as it goes out.
        on_bytes: ?BytesSent = null,
        /// Where the bytes of an `object` body sent so far are counted, so a
        /// caller can take them back off its progress when the request
        /// fails.
        sent: ?*u64 = null,
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
                            if (!try cr.session.fill(c.io, c.credentialOptions())) {
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
                    return c.fail(error.AuthenticationFailed, "HTTP 401 from {s}", .{stripQuery(url)});
                }
                if (access == .none) {
                    if (!offers.basic and offers.other) return error.LfsAccessUnsupported;
                    try c.setAccess(access_url, .basic);
                    continue;
                }
                auth_attempts += 1;
                if (auth_attempts >= 3) return c.fail(error.AuthenticationFailed, "HTTP 401 from {s}", .{stripQuery(url)});
                continue;
            }
            if (status.class() == .success) {
                if (cred) |cr| {
                    try c.mutex.lock(c.io);
                    defer c.mutex.unlock(c.io);
                    if (!cr.approved) {
                        cr.approved = true;
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
        const uri = std.Uri.parse(request_url) catch return c.fail(error.MalformedUrl, "malformed URL {s}", .{stripQuery(request_url)});

        var headers: std.ArrayList(http.Header) = .empty;
        // `http.<url>.extraHeader`, as git-lfs adds it to every request.
        for (try c.extraHeaders(a, request_url)) |h| try headers.append(a, h);
        for (request.headers) |h| {
            try checkHeader(h.name, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "authorization") and auth_header != null) continue;
            try headers.append(a, h);
        }
        var content_type: ?[]const u8 = null;
        if (request.api) {
            try headers.append(a, .{ .name = "Accept", .value = media_type });
            if (request.body != .none) content_type = media_type ++ "; charset=utf-8";
        } else if (request.body == .object and !hasHeader(request.headers, "content-type")) {
            content_type = "application/octet-stream";
        }
        if (hasHeader(request.headers, "content-type")) content_type = null;

        ex.request = c.http.request(request.method, uri, .{
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .authorization = if (auth_header) |h| .{ .override = h } else .omit,
                .content_type = if (content_type) |t| .{ .override = t } else .default,
                .accept_encoding = if (request.identity) .{ .override = "identity" } else .default,
            },
            .extra_headers = headers.items,
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        }) catch |err| return c.fail(mapRequestError(err), "{s}: {s}", .{ @errorName(err), stripQuery(request_url) });
        ex.in_flight = true;
        errdefer ex.request.deinit();

        switch (request.body) {
            .none => {
                if (request.method.requestHasBody()) {
                    ex.request.sendBodyComplete(&.{}) catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)});
                } else {
                    ex.request.sendBodiless() catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)});
                }
            },
            .bytes => |bytes| {
                const copy = try a.dupe(u8, bytes);
                ex.request.sendBodyComplete(copy) catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)});
            },
            .object => |o| {
                const file = (o.store.open(c.io, &o.pointer) catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)})) orelse
                    return c.fail(error.HttpStatus, "object {s} is not in the store", .{&o.pointer.oid});
                defer file.close(c.io);
                ex.request.transfer_encoding = .{ .content_length = o.pointer.size };
                var body_buf: [64 * 1024]u8 = undefined;
                var body = ex.request.sendBody(&body_buf) catch |err| return c.fail(error.ConnectionFailed, "{s}", .{@errorName(err)});
                var chunk: [64 * 1024]u8 = undefined;
                var fr = file.reader(c.io, &.{});
                var left = o.pointer.size;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, chunk.len));
                    const n = fr.interface.readSliceShort(chunk[0..want]) catch return c.fail(error.ConnectionFailed, "upload: reading the object", .{});
                    if (n == 0) return c.fail(error.ConnectionFailed, "upload: the object is shorter than its pointer", .{});
                    body.writer.writeAll(chunk[0..n]) catch |err| return c.fail(error.ConnectionFailed, "upload: {s}", .{@errorName(err)});
                    left -= n;
                    if (request.sent) |count| count.* += n;
                    if (request.on_bytes) |cb| cb.add(cb.context, n);
                }
                body.end() catch |err| return c.fail(error.ConnectionFailed, "upload: {s}", .{@errorName(err)});
            },
        }
        ex.response = ex.request.receiveHead(&.{}) catch |err| return c.fail(mapRequestError(err), "{s}: {s}", .{ @errorName(err), stripQuery(request_url) });
        return ex;
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

    fn configureProxies(c: *Client) Error!void {
        const arena = c.arena.allocator();
        var configured: ?[]const u8 = null;
        if (try c.settings.get(arena, "http.proxy")) |text| {
            if (text.len != 0) configured = text;
        }
        for ([_]bool{ false, true }) |tls| {
            var text = configured;
            if (text == null) {
                const programs = c.options.programs orelse return;
                const names: []const []const u8 = if (tls)
                    &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }
                else
                    &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" };
                for (names) |name| {
                    if (programs.environ.get(name)) |value| {
                        if (value.len != 0) {
                            text = value;
                            break;
                        }
                    }
                }
            }
            const proxy_text = text orelse continue;
            const uri = std.Uri.parse(proxy_text) catch std.Uri.parseAfterScheme("http", proxy_text) catch return error.InvalidProxy;
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
                    .plain => 80,
                    .tls => 443,
                },
                .supports_connect = true,
            };
            if (tls) c.http.https_proxy = proxy else c.http.http_proxy = proxy;
        }
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
        c.noteStatus(ex, what);
        return if (status == .unauthorized or status == .forbidden) error.AuthenticationFailed else error.HttpStatus;
    }

    /// Keep an answer's status and the server's reason as the client's
    /// message.
    pub fn noteStatus(c: *Client, ex: *Exchange, what: []const u8) void {
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
    }
};

/// A request made and its answer, open for the body.
pub const Exchange = struct {
    client: *Client,
    arena: std.heap.ArenaAllocator,
    request: http.Client.Request = undefined,
    response: http.Client.Response = undefined,
    in_flight: bool = false,
    transfer_buffer: [16 * 1024]u8 = undefined,
    decompress: http.Decompress = undefined,
    decompress_buffer: []u8 = &.{},
    body: ?*Io.Reader = null,

    /// The answer's status.
    pub fn status(ex: *const Exchange) http.Status {
        return ex.response.head.status;
    }

    /// A header of the answer, or `null`.
    pub fn header(ex: *const Exchange, name: []const u8) ?[]const u8 {
        var it = ex.response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    fn location(ex: *const Exchange) ?[]const u8 {
        return ex.response.head.location;
    }

    const Offers = struct { basic: bool = false, other: bool = false };

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

    /// `Retry-After` in seconds, when it is given as a number.
    pub fn retryAfter(ex: *const Exchange) ?u64 {
        const value = ex.header("retry-after") orelse return null;
        return std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t"), 10) catch null;
    }

    /// The body, read as it arrives.
    pub fn reader(ex: *Exchange) Error!*Io.Reader {
        if (ex.body) |r| return r;
        const res = &ex.response;
        const r = switch (res.head.content_encoding) {
            .identity => res.reader(&ex.transfer_buffer),
            .gzip, .deflate => blk: {
                ex.decompress_buffer = try ex.arena.allocator().alloc(u8, std.compress.flate.max_window_len);
                break :blk res.readerDecompressing(&ex.transfer_buffer, &ex.decompress, ex.decompress_buffer);
            },
            else => return ex.client.fail(error.MalformedResponse, "unsupported content encoding", .{}),
        };
        ex.body = r;
        return r;
    }

    /// The whole body, up to `limit` bytes, owned by the exchange.
    pub fn readAll(ex: *Exchange, limit: usize) Error![]const u8 {
        const r = try ex.reader();
        return r.allocRemaining(ex.arena.allocator(), .limited(limit)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.StreamTooLong,
            error.ReadFailed => ex.client.fail(error.ConnectionFailed, "reading the answer: {s}", .{
                if (ex.response.request.reader.body_err) |e| @errorName(e) else "read failed",
            }),
        };
    }

    /// The reason a read of the body failed.
    pub fn bodyError(ex: *const Exchange) []const u8 {
        return if (ex.response.request.reader.body_err) |e| @errorName(e) else "read failed";
    }

    /// Give the connection back and release everything.
    pub fn close(ex: *Exchange) void {
        const c = ex.client;
        if (ex.in_flight) ex.request.deinit();
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
        const lfsconfig = try lfsconfigText(gpa, io, repo);
        defer if (lfsconfig) |t| gpa.free(t);
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
        gpa.destroy(s);
    }

    /// The repository's store.
    pub fn store(s: *const Server) *const lfs.Store {
        return &s.lfs.store;
    }
};

fn hasHeader(headers: []const http.Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

fn mapRequestError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.ConnectionFailed,
    };
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
