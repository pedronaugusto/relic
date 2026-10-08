//! What a remote's URL names: which transport reaches it, and where.
//!
//! git reads four shapes. `scheme://[user[:password]@]host[:port]/path` is a
//! URL proper. `[user@]host:path`, with a colon before any slash, is the
//! scp-like shorthand for ssh. `file://path` and a plain path are a
//! repository on this machine. And `<helper>::<address>` hands the address to
//! a remote helper, as does a `<scheme>://` URL for a scheme relic does not
//! speak itself: `Url.parse` refuses both and `helperOf` names the helper.
//! The tests below hold each reading to git's own `url_is_local_not_ssh`
//! and `parse_connect_url`.

const Self = @This();
const std = @import("std");
const shakedown = @import("shakedown");
const builtin = @import("builtin");
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

/// Errors from reading a URL.
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
    pub const ParseError = Self.ParseError;
    scheme: Scheme,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// Empty for a local path; a non-local file authority is kept here.
    host: []const u8 = "",
    port: ?u16 = null,
    /// For ssh, the path spelling (use Identity for decoded bytes): `~user/repo` or
    /// `/srv/repo.git`, or `path/repo` relative to the login directory for
    /// the scp-like form. For a local path, the path. For http, the path
    /// part of the URL with its query, if any.
    path: []const u8,
    /// The text as given.
    raw: []const u8,

    /// Read a URL the way git decides what it names.
    pub fn parse(text: []const u8) Url.ParseError!Url {
        if (text.len == 0) return error.MalformedUrl;
        if (schemeEnd(text)) |sep| {
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
                // On Windows `file://C:/repo` is the path with its drive, as
                // git for Windows reads it.
                if (builtin.target.os.tag == .windows and rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') {
                    return .{ .scheme = .file, .path = rest, .raw = text };
                }
                // git for Windows keeps an authority as a UNC path.
                // On Unix only the path after the authority is used.
                const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
                const host = rest[0..slash];
                if (slash == rest.len) return error.MalformedUrl;
                if (builtin.target.os.tag == .windows and host.len != 0) {
                    return .{ .scheme = .file, .host = host, .path = text[sep + 1 ..], .raw = text };
                }
                return .{ .scheme = .file, .path = rest[slash..], .raw = text };
            }
            var url: Url = .{ .scheme = scheme, .path = "", .raw = text };
            const path_at = std.mem.findScalar(u8, rest, '/') orelse rest.len;
            try splitAuthority(&url, rest[0..path_at], true);
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
        if (isLocal(text)) return .{ .scheme = .local, .path = text, .raw = text };
        // git's transport_get recognizes a helper only after scheme characters.
        // A colon inside a bracketed host is part of that host.
        var helper_end: usize = 0;
        while (helper_end < text.len and (std.ascii.isAlphabetic(text[helper_end]) or
            (helper_end != 0 and (std.ascii.isDigit(text[helper_end]) or
                text[helper_end] == '+' or text[helper_end] == '-' or text[helper_end] == '.')))) : (helper_end += 1)
        {}
        if (std.mem.startsWith(u8, text[helper_end..], "::")) return error.UnsupportedTransport;

        var url: Url = .{ .scheme = .ssh, .path = "", .raw = text };
        const bracket = if (std.mem.find(u8, text, "@[")) |at| at + 1 else @as(usize, 0);
        const host_end = if (text[bracket] == '[') blk: {
            const close = std.mem.findScalarPos(u8, text, bracket + 1, ']') orelse return error.MalformedUrl;
            if (close + 1 >= text.len or text[close + 1] != ':') return error.MalformedUrl;
            break :blk close + 1;
        } else std.mem.findScalar(u8, text, ':').?;
        try splitAuthority(&url, text[0..host_end], false);
        if (url.host.len == 0) return error.MalformedUrl;
        url.path = text[host_end + 1 ..];
        if (url.path.len == 0) return error.MalformedUrl;
        if (std.mem.startsWith(u8, url.path, "/~")) url.path = url.path[1..];
        return url;
    }

    /// Whether the repository is on this machine.
    pub fn isLocalRepository(url: Url) bool {
        return url.scheme == .local or url.scheme == .file;
    }
};

/// An allocator-owned URL identity. `url` borrows only this owner's bytes;
/// raw text stays intact for transport and display. SSH, file and Git URL
/// forms decode before splitting, as Git does; scp shorthand, local paths
/// and HTTP URLs keep literal bytes. No equivalence policy is imposed.
pub const Identity = struct {
    gpa: Allocator,
    url: Url,
    raw: []u8,
    decoded: ?[]u8,

    pub const Error = Allocator.Error || Url.ParseError;

    pub fn parse(gpa: Allocator, text: []const u8) Error!Identity {
        const raw = try gpa.dupe(u8, text);
        errdefer gpa.free(raw);
        var decoded: ?[]u8 = null;
        errdefer if (decoded) |bytes| gpa.free(bytes);
        // Read the scheme before decoding: escapes cannot invent a transport.
        const sep = schemeEnd(raw);
        const decode = if (sep) |end| blk: {
            const scheme = raw[0..end];
            break :blk std.ascii.eqlIgnoreCase(scheme, "ssh") or
                std.ascii.eqlIgnoreCase(scheme, "git+ssh") or
                std.ascii.eqlIgnoreCase(scheme, "ssh+git") or
                std.ascii.eqlIgnoreCase(scheme, "file") or
                std.ascii.eqlIgnoreCase(scheme, "git");
        } else false;
        var parsed: Url = undefined;
        if (decode) {
            decoded = try gpa.dupe(u8, raw);
            const buffer = decoded.?;
            var read: usize = sep.?;
            var write: usize = read;
            while (read < buffer.len) {
                if (buffer[read] == '%' and buffer.len - read >= 3) {
                    const hi = std.fmt.charToDigit(buffer[read + 1], 16) catch null;
                    const lo = std.fmt.charToDigit(buffer[read + 2], 16) catch null;
                    if (hi != null and lo != null) {
                        const byte = hi.? * 16 + lo.?;
                        // Git leaves zero and malformed escapes literal.
                        if (byte != 0) {
                            buffer[write] = byte;
                            write += 1;
                            read += 3;
                            continue;
                        }
                    }
                }
                buffer[write] = buffer[read];
                write += 1;
                read += 1;
            }
            parsed = try Url.parse(buffer[0..write]);
            parsed.raw = raw;
        } else parsed = try Url.parse(raw);
        return .{ .gpa = gpa, .url = parsed, .raw = raw, .decoded = decoded };
    }

    pub fn deinit(identity: *Identity) void {
        if (identity.decoded) |bytes| identity.gpa.free(bytes);
        identity.gpa.free(identity.raw);
        identity.* = undefined;
    }
};

/// A URL scheme must precede :// at the start, not inside a local path.
/// A remote helper a URL names, and the address it is handed.
pub const Helper = struct {
    /// The helper's name: `git-remote-<name>` is the program.
    name: []const u8,
    /// What follows `::`, or the whole URL for `<scheme>://`.
    address: []const u8,
};

/// The remote helper `text` names, as git's `transport_get` decides it:
/// `<helper>::<address>`, or a `<scheme>://` URL whose scheme is not one
/// relic reaches itself — `ssh`, `git+ssh`, `ssh+git`, `file`, `git`,
/// `http` and `https`. `null` for every other URL.
pub fn helperOf(text: []const u8) ?Helper {
    var end: usize = 0;
    while (end < text.len and (std.ascii.isAlphabetic(text[end]) or
        (end != 0 and (std.ascii.isDigit(text[end]) or text[end] == '+' or text[end] == '-' or text[end] == '.')))) : (end += 1)
    {}
    if (end != 0 and std.mem.startsWith(u8, text[end..], "::")) return .{ .name = text[0..end], .address = text[end + 2 ..] };
    const sep = schemeEnd(text) orelse return null;
    const scheme = text[0..sep];
    for ([_][]const u8{ "ssh", "git+ssh", "ssh+git", "file", "git", "http", "https" }) |native| {
        if (std.ascii.eqlIgnoreCase(scheme, native)) return null;
    }
    return .{ .name = scheme, .address = text };
}

test "a helper is named by <helper>:: or by a scheme relic does not speak" {
    const ext = helperOf("ext::ssh -i key host %S repo").?;
    try testing.expectEqualStrings("ext", ext.name);
    try testing.expectEqualStrings("ssh -i key host %S repo", ext.address);
    const foo = helperOf("foo+bar://host/repo").?;
    try testing.expectEqualStrings("foo+bar", foo.name);
    try testing.expectEqualStrings("foo+bar://host/repo", foo.address);
    try testing.expect(helperOf("https://example.com/repo") == null);
    try testing.expect(helperOf("ssh://host/repo") == null);
    try testing.expect(helperOf("host:a::b") == null);
    try testing.expect(helperOf("./ext::repo") == null);
    try testing.expect(helperOf("/srv/repo") == null);
}

fn schemeEnd(text: []const u8) ?usize {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return null;
    var end: usize = 1;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or
        text[end] == '+' or text[end] == '-' or text[end] == '.')) : (end += 1)
    {}
    return if (std.mem.startsWith(u8, text[end..], "://")) end else null;
}

fn splitAuthority(url: *Url, text: []const u8, password: bool) ParseError!void {
    var authority = text;
    // git accepts [user@host] as well as user@[host]. Unwrap the former
    // before finding the user, so its closing bracket cannot enter the host.
    if (authority.len != 0 and authority[0] == '[') {
        const close = std.mem.findScalar(u8, authority, ']') orelse return error.MalformedUrl;
        try splitAuthority(url, authority[1..close], password);
        try splitPort(url, authority[close + 1 ..]);
        return;
    }
    if (std.mem.findScalarLast(u8, authority, '@')) |at| {
        const userinfo = authority[0..at];
        authority = authority[at + 1 ..];
        if (password) {
            if (std.mem.findScalar(u8, userinfo, ':')) |colon| {
                url.user = userinfo[0..colon];
                url.password = userinfo[colon + 1 ..];
            } else url.user = userinfo;
        } else url.user = userinfo;
    }
    if (authority.len != 0 and authority[0] == '[') {
        const close = std.mem.findScalar(u8, authority, ']') orelse return error.MalformedUrl;
        try splitAuthority(url, authority[1..close], false);
        try splitPort(url, authority[close + 1 ..]);
        return;
    }
    // An unbracketed IPv6 address has several colons and no port. git's
    // get_host_and_port and get_port leave it whole too.
    if (std.mem.findScalar(u8, authority, ':')) |colon| {
        if (std.mem.findScalarPos(u8, authority, colon + 1, ':') == null) {
            url.host = authority[0..colon];
            return splitPort(url, authority[colon..]);
        }
    }
    url.host = authority;
}

fn splitPort(url: *Url, suffix: []const u8) ParseError!void {
    if (suffix.len == 0) return;
    if (suffix[0] != ':') return error.MalformedUrl;
    if (suffix.len == 1) return;
    url.port = std.fmt.parseInt(u16, suffix[1..], 10) catch return error.MalformedUrl;
}

/// git's `url_is_local_not_ssh`: no colon, or a slash before the first
/// colon, or a DOS drive letter on Windows.
pub fn isLocal(text: []const u8) bool {
    const colon = std.mem.findScalar(u8, text, ':') orelse return true;
    if (std.mem.findScalar(u8, text, '/')) |slash| {
        if (slash < colon) return true;
    }
    return builtin.target.os.tag == .windows and text.len >= 2 and
        std.ascii.isAlphabetic(text[0]) and text[1] == ':' and colon == 1;
}

/// The URL with any `user[:password]@` taken out, which is how git writes a
/// URL anywhere a person may read it: `FETCH_HEAD`, a reflog message. The
/// result is the caller's.
///
/// git's `transport_anonymize_url`: a path is copied as it is; a URL loses
/// the user part of its authority; the scp-like form loses everything up to
/// the `@` before its colon.
pub fn anonymize(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    if (schemeEnd(text)) |sep| {
        const start = sep + 3;
        const path_at = std.mem.findScalarPos(u8, text, start, '/') orelse text.len;
        if (std.mem.findScalarLast(u8, text[start..path_at], '@')) |at| {
            return std.mem.concat(gpa, u8, &.{ text[0..start], text[start + at + 1 ..] });
        }
        return gpa.dupe(u8, text);
    }
    if (isLocal(text)) return gpa.dupe(u8, text);
    const colon = std.mem.findScalar(u8, text, ':').?;
    if (std.mem.findScalar(u8, text[0..colon], '@')) |at| {
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
    try testing.expectEqual(if (builtin.target.os.tag == .windows) Scheme.local else Scheme.ssh, (try Url.parse("C:\\repos\\x")).scheme);
    {
        const url = try Url.parse("file:///srv/repo.git");
        try testing.expectEqual(Scheme.file, url.scheme);
        try testing.expectEqualStrings("/srv/repo.git", url.path);
    }
    if (builtin.target.os.tag == .windows) {
        const url = try Url.parse("file://C:\\srv/repo.git");
        try testing.expectEqual(Scheme.file, url.scheme);
        try testing.expectEqualStrings("C:\\srv/repo.git", url.path);
    }
}

test "a transport relic does not have is refused by name" {
    try testing.expectError(error.UnsupportedTransport, Url.parse("rsync://example.com/repo"));
    try testing.expectError(error.UnsupportedTransport, Url.parse("ext::ssh -i key host %S repo"));
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
    const base = @intFromPtr(input.ptr); // safe: compared as a number, never dereferenced
    for ([_]?[]const u8{ url.user, url.password, url.host, url.path }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        try testing.expect(@intFromPtr(p.ptr) >= base and @intFromPtr(p.ptr) + p.len <= base + input.len); // safe: compared as numbers, never dereferenced
    }
    const shown = try anonymize(testing.allocator, input);
    defer testing.allocator.free(shown);
    try testing.expect(shown.len <= input.len);
}

test "bracketed remote identities follow git t5601 clone URLs" {
    // git's t/t5601-clone.sh: bracketed scp, SSH IPv6, home paths,
    // optional ports and users both inside and outside the brackets.
    const Case = struct { text: []const u8, user: ?[]const u8 = null, host: []const u8, port: ?u16 = null, path: []const u8 };
    const cases = [_]Case{
        .{ .text = "[::1]:owner/repo.git", .host = "::1", .path = "owner/repo.git" },
        .{ .text = "user@[::1]:rep/home/project", .user = "user", .host = "::1", .path = "rep/home/project" },
        .{ .text = "[user@::1]:123", .user = "user", .host = "::1", .path = "123" },
        .{ .text = "[::1]:/~repo", .host = "::1", .path = "~repo" },
        .{ .text = "host:/~repo", .host = "host", .path = "~repo" },
        .{ .text = "[myhost:123]:src", .host = "myhost", .port = 123, .path = "src" },
        .{ .text = "user@[myhost:123]:src", .user = "user", .host = "myhost", .port = 123, .path = "src" },
        .{ .text = "ssh://::1/home/user/repo", .host = "::1", .path = "/home/user/repo" },
        .{ .text = "ssh://user@::1/~repo", .user = "user", .host = "::1", .path = "~repo" },
        .{ .text = "ssh://[user@::1]:22/~repo", .user = "user", .host = "::1", .port = 22, .path = "~repo" },
        .{ .text = "ssh://user@[::1]:/home/user/repo", .user = "user", .host = "::1", .path = "/home/user/repo" },
        .{ .text = "ssh://user@domain@host:2222/owner/repo@work.git", .user = "user@domain", .host = "host", .port = 2222, .path = "/owner/repo@work.git" },
        .{ .text = "ssh://git@[::1]:2222/owner/repo.git", .user = "git", .host = "::1", .port = 2222, .path = "/owner/repo.git" },
    };
    for (cases) |case| {
        const parsed = try Url.parse(case.text);
        try testing.expectEqual(Scheme.ssh, parsed.scheme);
        if (case.user) |user| try testing.expectEqualStrings(user, parsed.user.?) else try testing.expect(parsed.user == null);
        try testing.expectEqualStrings(case.host, parsed.host);
        try testing.expectEqual(case.port, parsed.port);
        try testing.expectEqualStrings(case.path, parsed.path);
    }
    for ([_][]const u8{ "foo/bar:baz", "[foo]bar/baz:qux", "[foo/bar]:baz", "./ext::repo" }) |path| {
        const parsed = try Url.parse(path);
        try testing.expectEqual(Scheme.local, parsed.scheme);
        try testing.expectEqualStrings(path, parsed.path);
    }
    try testing.expectError(error.UnsupportedTransport, Url.parse("ext::ssh host repo"));
    // Double colons in the address do not make its host a helper.
    try testing.expectEqualStrings("a::b", (try Url.parse("host:a::b")).path);
}

test "file and local URL identities follow git path and scheme boundaries" {
    const remote_file = try Url.parse("file://server/share/repo.git");
    try testing.expectEqual(Scheme.file, remote_file.scheme);
    try testing.expectEqualStrings(if (builtin.target.os.tag == .windows) "server" else "", remote_file.host);
    try testing.expectEqualStrings(if (builtin.target.os.tag == .windows) "//server/share/repo.git" else "/share/repo.git", remote_file.path);
    const local_file = try Url.parse("file://localhost/srv/repo.git");
    try testing.expectEqualStrings(if (builtin.target.os.tag == .windows) "//localhost/srv/repo.git" else "/srv/repo.git", local_file.path);
    const embedded = try Url.parse("./folder/ssh://host/repo");
    try testing.expectEqual(Scheme.local, embedded.scheme);
    try testing.expectEqualStrings("./folder/ssh://host/repo", embedded.path);
    const helper_path = try Url.parse("./ext::repo");
    try testing.expectEqual(Scheme.local, helper_path.scheme);
}

test "local URL classification follows the platform and survives display" {
    // t5601: c:temp is SSH on Unix and a drive-relative path on Windows.
    const drive = try Url.parse("c:temp");
    try testing.expectEqual(if (builtin.target.os.tag == .windows) Scheme.local else Scheme.ssh, drive.scheme);
    if (builtin.target.os.tag != .windows) {
        try testing.expectEqualStrings("c", drive.host);
        try testing.expectEqualStrings("temp", drive.path);
    }
    const path = "./folder/ssh://user@host/repo";
    const parsed = try Url.parse(path);
    try testing.expectEqual(Scheme.local, parsed.scheme);
    const shown = try anonymize(testing.allocator, path);
    defer testing.allocator.free(shown);
    try testing.expectEqualStrings(path, shown);
}

test "file URL authorities follow git on this platform" {
    if (builtin.target.os.tag == .windows) {
        const parsed = try Url.parse("file://server/share/repo.git");
        try testing.expectEqualStrings("//server/share/repo.git", parsed.path);
        return;
    }
    const testgit = @import("../testing/git.zig");
    const io = testing.io;
    const gpa = testing.allocator;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    const path = try fixture.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    // connect.c uses only the slash onwards on Unix; this authority is
    // neither resolved nor opened. Windows retains it as a UNC path.
    const text = try gpa.print("file://elsewhere{s}", .{path});
    defer gpa.free(text);
    const parsed = try Url.parse(text);
    try testing.expectEqualStrings(path, parsed.path);
    try fixture.exec(io, &.{ "ls-remote", text });
}

test "decoded URL identities own their text and follow Git percent rules" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            const cases = [_][2][]const u8{
                .{ "ssh://ada%40example@[::1]:2222/%7Eada/a%20b%2Fc%25d+e", "~ada/a b/c%d+e" },
                .{ "file:///a%20b/%2520/%00/%GG/%2", "/a b/%20/%00/%GG/%2" },
                .{ "host:a%20b", "a%20b" },
                .{ "./a%20b", "./a%20b" },
                .{ "https://host/a%20b?q=%2F", "/a%20b?q=%2F" },
            };
            for (cases) |case| {
                const input = try testing.allocator.dupe(u8, case[0]);
                defer testing.allocator.free(input);
                var identity = try Identity.parse(gpa, input);
                defer identity.deinit();
                @memset(input, 'x');
                try testing.expectEqualStrings(case[0], identity.url.raw);
                try testing.expectEqualStrings(case[1], identity.url.path);
                if (identity.url.scheme == .ssh and identity.url.port != null) {
                    try testing.expectEqualStrings("ada@example", identity.url.user.?);
                    try testing.expectEqualStrings("::1", identity.url.host);
                    try testing.expectEqual(@as(?u16, 2222), identity.url.port);
                }
            }
        }
    };
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{});
    }
}
