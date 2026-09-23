//! What a remote's URL names: which transport reaches it, and where.
//!
//! git reads four shapes. `scheme://[user[:password]@]host[:port]/path` is a
//! URL proper. `[user@]host:path`, with a colon before any slash, is the
//! scp-like shorthand for ssh. `file://path` and a plain path are a
//! repository on this machine. And `<helper>::<address>` hands the address to
//! a remote helper, which relic does not run. The tests below hold each
//! reading to git's own `url_is_local_not_ssh` and `parse_connect_url`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The transport a URL is reached through.
pub const Scheme = enum {
    /// A path on this machine, as written: `../other`, `/srv/repo.git`.
    local,
    /// `file://`, which is also a path on this machine.
    file,
    /// `ssh://`, `git+ssh://`, `ssh+git://` and the scp-like shorthand.
    ssh,
    /// `git://`, the unauthenticated daemon.
    git,
    http,
    https,
};

pub const ParseError = error{
    /// A scheme relic has no transport for, or the `<helper>::` form, which
    /// runs a remote helper.
    UnsupportedTransport,
    /// A URL with no host where one is required, or a port that is not a
    /// number.
    MalformedUrl,
};

/// A URL, split. Every slice borrows the text it was parsed from.
pub const Url = struct {
    scheme: Scheme,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// Empty for a local path.
    host: []const u8 = "",
    port: ?u16 = null,
    /// For ssh, exactly what the remote command is given: `~user/repo` or
    /// `/srv/repo.git`, or `path/repo` relative to the login directory for
    /// the scp-like form. For a local path, the path. For http, the path
    /// part of the URL with its query, if any.
    path: []const u8,
    /// The text as given.
    raw: []const u8,

    /// Read a URL the way git decides what it names.
    pub fn parse(text: []const u8) ParseError!Url {
        if (text.len == 0) return error.MalformedUrl;
        if (std.mem.indexOf(u8, text, "://")) |sep| {
            const scheme_text = text[0..sep];
            const scheme: Scheme = if (std.ascii.eqlIgnoreCase(scheme_text, "ssh") or
                std.ascii.eqlIgnoreCase(scheme_text, "git+ssh") or
                std.ascii.eqlIgnoreCase(scheme_text, "ssh+git"))
                .ssh
            else if (std.ascii.eqlIgnoreCase(scheme_text, "file"))
                .file
            else if (std.ascii.eqlIgnoreCase(scheme_text, "git"))
                .git
            else if (std.ascii.eqlIgnoreCase(scheme_text, "http"))
                .http
            else if (std.ascii.eqlIgnoreCase(scheme_text, "https"))
                .https
            else
                return error.UnsupportedTransport;
            const rest = text[sep + 3 ..];
            if (scheme == .file) {
                // `file://host/path` names a host other than this one only
                // when it is not empty and not `localhost`; git refuses the
                // rest the same way.
                const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
                const host = rest[0..slash];
                if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.UnsupportedTransport;
                if (slash == rest.len) return error.MalformedUrl;
                return .{ .scheme = .file, .path = rest[slash..], .raw = text };
            }
            var url: Url = .{ .scheme = scheme, .path = "", .raw = text };
            const path_at = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            var authority = rest[0..path_at];
            if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
                const userinfo = authority[0..at];
                authority = authority[at + 1 ..];
                if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                    url.user = userinfo[0..colon];
                    url.password = userinfo[colon + 1 ..];
                } else url.user = userinfo;
            }
            try splitHostPort(&url, authority);
            if (url.host.len == 0) return error.MalformedUrl;
            url.path = rest[path_at..];
            if (scheme == .ssh or scheme == .git) {
                // `ssh://host/~user/repo` asks for a path relative to a home
                // directory, and the remote command is given it without the
                // leading slash.
                if (url.path.len >= 2 and url.path[0] == '/' and url.path[1] == '~') url.path = url.path[1..];
                if (url.path.len == 0) return error.MalformedUrl;
            }
            return url;
        }
        if (isLocal(text)) {
            // `<helper>::<address>` is the remote-helper form; a path cannot
            // hold `::` before a slash, so this is where it would land.
            return .{ .scheme = .local, .path = text, .raw = text };
        }
        if (std.mem.indexOf(u8, text, "::")) |_| {
            const colon = std.mem.indexOfScalar(u8, text, ':').?;
            if (text.len > colon + 1 and text[colon + 1] == ':') return error.UnsupportedTransport;
        }
        // The scp-like form: `[user@]host:path`, with the host optionally
        // in brackets so that it may hold a colon of its own.
        var url: Url = .{ .scheme = .ssh, .path = "", .raw = text };
        var rest = text;
        var host_end: usize = undefined;
        if (rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.MalformedUrl;
            if (close + 1 >= rest.len or rest[close + 1] != ':') return error.MalformedUrl;
            var inside = rest[1..close];
            if (std.mem.lastIndexOfScalar(u8, inside, '@')) |at| {
                url.user = inside[0..at];
                inside = inside[at + 1 ..];
            }
            // `[host:port]` is how the scp-like form carries a port.
            if (std.mem.lastIndexOfScalar(u8, inside, ':')) |colon| {
                if (std.mem.indexOfScalar(u8, inside[0..colon], ':') == null) {
                    url.host = inside[0..colon];
                    url.port = std.fmt.parseInt(u16, inside[colon + 1 ..], 10) catch return error.MalformedUrl;
                } else url.host = inside;
            } else url.host = inside;
            host_end = close + 1;
        } else {
            host_end = std.mem.indexOfScalar(u8, rest, ':').?;
            var host = rest[0..host_end];
            if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| {
                url.user = host[0..at];
                host = host[at + 1 ..];
            }
            url.host = host;
        }
        if (url.host.len == 0) return error.MalformedUrl;
        rest = rest[host_end + 1 ..];
        if (rest.len == 0) return error.MalformedUrl;
        url.path = rest;
        return url;
    }

    /// Whether the repository is on this machine.
    pub fn isLocalRepository(url: Url) bool {
        return url.scheme == .local or url.scheme == .file;
    }
};

fn splitHostPort(url: *Url, authority: []const u8) ParseError!void {
    if (authority.len != 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.MalformedUrl;
        url.host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len == 0) return;
        if (after[0] != ':') return error.MalformedUrl;
        if (after.len == 1) return;
        url.port = std.fmt.parseInt(u16, after[1..], 10) catch return error.MalformedUrl;
        return;
    }
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        url.host = authority[0..colon];
        // `host:` with nothing after the colon is the default port.
        if (colon + 1 < authority.len) {
            url.port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.MalformedUrl;
        }
        return;
    }
    url.host = authority;
}

/// git's `url_is_local_not_ssh`: no colon, or a slash before the first
/// colon, or a DOS drive letter.
pub fn isLocal(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return true;
    if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
        if (slash < colon) return true;
    }
    return text.len >= 2 and std.ascii.isAlphabetic(text[0]) and text[1] == ':' and colon == 1;
}

/// The URL with any `user[:password]@` taken out, which is how git writes a
/// URL anywhere a person may read it: `FETCH_HEAD`, a reflog message. The
/// result is the caller's.
///
/// git's `transport_anonymize_url`: a path is copied as it is; a URL loses
/// the user part of its authority; the scp-like form loses everything up to
/// the `@` before its colon.
pub fn anonymize(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    if (std.mem.indexOf(u8, text, "://")) |sep| {
        const start = sep + 3;
        const path_at = std.mem.indexOfScalarPos(u8, text, start, '/') orelse text.len;
        if (std.mem.lastIndexOfScalar(u8, text[start..path_at], '@')) |at| {
            return std.mem.concat(gpa, u8, &.{ text[0..start], text[start + at + 1 ..] });
        }
        return gpa.dupe(u8, text);
    }
    if (isLocal(text)) return gpa.dupe(u8, text);
    const colon = std.mem.indexOfScalar(u8, text, ':').?;
    if (std.mem.indexOfScalar(u8, text[0..colon], '@')) |at| {
        return gpa.dupe(u8, text[at + 1 ..]);
    }
    return gpa.dupe(u8, text);
}

const testing = std.testing;

test "each shape of URL is read as git reads it" {
    {
        const url = try Url.parse("ssh://ada@example.com:2222/srv/repo.git");
        try testing.expectEqual(Scheme.ssh, url.scheme);
        try testing.expectEqualStrings("ada", url.user.?);
        try testing.expectEqualStrings("example.com", url.host);
        try testing.expectEqual(@as(?u16, 2222), url.port);
        try testing.expectEqualStrings("/srv/repo.git", url.path);
    }
    {
        const url = try Url.parse("git+ssh://example.com/~ada/repo");
        try testing.expectEqual(Scheme.ssh, url.scheme);
        try testing.expectEqualStrings("~ada/repo", url.path);
    }
    {
        const url = try Url.parse("ada@example.com:work/repo.git");
        try testing.expectEqual(Scheme.ssh, url.scheme);
        try testing.expectEqualStrings("ada", url.user.?);
        try testing.expectEqualStrings("example.com", url.host);
        try testing.expectEqualStrings("work/repo.git", url.path);
    }
    {
        const url = try Url.parse("[example.com:2200]:repo");
        try testing.expectEqualStrings("example.com", url.host);
        try testing.expectEqual(@as(?u16, 2200), url.port);
        try testing.expectEqualStrings("repo", url.path);
    }
    {
        const url = try Url.parse("https://ada:secret@example.com/org/repo.git");
        try testing.expectEqual(Scheme.https, url.scheme);
        try testing.expectEqualStrings("secret", url.password.?);
        try testing.expectEqualStrings("/org/repo.git", url.path);
    }
    {
        const url = try Url.parse("http://[::1]:8080/repo");
        try testing.expectEqualStrings("::1", url.host);
        try testing.expectEqual(@as(?u16, 8080), url.port);
    }
    try testing.expectEqual(Scheme.local, (try Url.parse("../other/repo")).scheme);
    try testing.expectEqual(Scheme.local, (try Url.parse("/srv/a:b")).scheme);
    try testing.expectEqual(Scheme.local, (try Url.parse("C:\\repos\\x")).scheme);
    {
        const url = try Url.parse("file:///srv/repo.git");
        try testing.expectEqual(Scheme.file, url.scheme);
        try testing.expectEqualStrings("/srv/repo.git", url.path);
    }
}

test "a transport relic does not have is refused by name" {
    try testing.expectError(error.UnsupportedTransport, Url.parse("rsync://example.com/repo"));
    try testing.expectError(error.UnsupportedTransport, Url.parse("ext::ssh -i key host %S repo"));
    try testing.expectError(error.UnsupportedTransport, Url.parse("file://elsewhere/repo"));
    try testing.expectError(error.MalformedUrl, Url.parse("ssh://example.com:port/repo"));
    try testing.expectError(error.MalformedUrl, Url.parse("https:///repo"));
    try testing.expectError(error.MalformedUrl, Url.parse("host:"));
}

test "a URL shown to a person loses its credentials" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "https://ada:secret@example.com/repo.git", "https://example.com/repo.git" },
        .{ "ssh://ada@example.com/repo", "ssh://example.com/repo" },
        .{ "ada@example.com:repo", "example.com:repo" },
        .{ "https://example.com/a@b", "https://example.com/a@b" },
        .{ "/srv/at@sign/repo", "/srv/at@sign/repo" },
    };
    for (cases) |case| {
        const out = try anonymize(gpa, case[0]);
        defer gpa.free(out);
        try testing.expectEqualStrings(case[1], out);
    }
}

test "fuzz: any bytes are a URL or a named error" {
    try testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    const url = Url.parse(input) catch |err| switch (err) {
        error.UnsupportedTransport, error.MalformedUrl => return,
    };
    // Every part is a view of the input.
    const base = @intFromPtr(input.ptr);
    for ([_]?[]const u8{ url.user, url.password, url.host, url.path }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        try testing.expect(@intFromPtr(p.ptr) >= base and @intFromPtr(p.ptr) + p.len <= base + input.len);
    }
    const shown = try anonymize(testing.allocator, input);
    defer testing.allocator.free(shown);
    try testing.expect(shown.len <= input.len);
}
