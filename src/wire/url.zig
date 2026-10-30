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
const decimal = @import("../text.zig").decimal;
const percent = @import("../text.zig").percent;
const win32 = @import("../names.zig").path;
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

    /// Read a URL the way git decides what it names: `transport_get`
    /// chooses the transport (a scheme is matched exactly, so `SSH://` is
    /// the helper `git-remote-SSH`), then `parse_connect_url` and
    /// `get_host_and_port` split an ssh or file address.
    pub fn parse(text: []const u8) Url.ParseError!Url {
        if (text.len == 0) return error.MalformedUrl;
        if (schemeEnd(text)) |sep| {
            const scheme = nativeScheme(text[0..sep]) orelse return error.UnsupportedTransport;
            const rest = text[sep + 3 ..];
            return switch (scheme) {
                .file => parseFile(text, sep, rest),
                .ssh, .git => parseConnect(text, scheme, rest),
                .http, .https => parseHttp(text, scheme, rest),
                .local => unreachable,
            };
        }
        // `<helper>::<address>` is a helper's before anything else, and
        // `rsync:` is refused before a path or the scp-like form is read.
        if (helperNameEnd(text)) |_| return error.UnsupportedTransport;
        if (std.mem.startsWith(u8, text, "rsync:")) return error.UnsupportedTransport;
        // `parse_connect_url` takes what precedes any `://` as a scheme,
        // so a path or an scp-like address holding one is refused, as git
        // refuses it ("protocol './dir/ssh' is not supported").
        if (std.mem.find(u8, text, "://") != null) return error.UnsupportedTransport;
        if (isLocal(text)) return .{ .scheme = .local, .path = text, .raw = text };

        // The scp-like form: what precedes the first colon outside a
        // bracketed host is the ssh target, the rest the path.
        var url: Url = .{ .scheme = .ssh, .path = "", .raw = text };
        const colon = std.mem.findScalarPos(u8, text, bracketEnd(text), ':') orelse return error.MalformedUrl;
        try splitTarget(&url, text[0..colon]);
        url.path = homePath(text[colon + 1 ..]);
        return url;
    }

    fn parseFile(text: []const u8, sep: usize, rest: []const u8) Url.ParseError!Url {
        // On Windows `file://C:/repo` is the path with its drive, as
        // git for Windows reads it, a drive being any character before a
        // colon (`win32_has_dos_drive_prefix`).
        if (builtin.target.os.tag == .windows and win32.dosDrivePrefixLen(rest) != 0) {
            return .{ .scheme = .file, .path = rest, .raw = text };
        }
        // git for Windows keeps an authority as a UNC path, `//` and all,
        // once a separator of either kind follows it anywhere, brackets or
        // none: `parse_connect_url` by `offset_1st_component`.
        if (builtin.target.os.tag == .windows and rest.len != 0 and rest[0] != '/') {
            const end = std.mem.findAny(u8, rest, "/\\") orelse return error.MalformedUrl;
            return .{ .scheme = .file, .host = rest[0..end], .path = text[sep + 1 ..], .raw = text };
        }
        // On Unix only the path after the authority is used.
        const slash = std.mem.findScalarPos(u8, rest, bracketEnd(rest), '/') orelse return error.MalformedUrl;
        return .{ .scheme = .file, .path = rest[slash..], .raw = text };
    }

    /// `ssh://` and `git://`: the address ends at the first `/` after a
    /// bracketed host, and `/~user` asks for a path in a home directory,
    /// given to the remote command without its slash.
    fn parseConnect(text: []const u8, scheme: Scheme, rest: []const u8) Url.ParseError!Url {
        var url: Url = .{ .scheme = scheme, .path = "", .raw = text };
        const slash = std.mem.findScalarPos(u8, rest, bracketEnd(rest), '/') orelse return error.MalformedUrl;
        try splitTarget(&url, rest[0..slash]);
        url.path = homePath(rest[slash..]);
        return url;
    }

    /// `http://` and `https://` as curl and git's `credential_from_url`
    /// read them: the authority ends at the first `/`, `?` or `#`, the
    /// user at the first `@`, the password after the user's first `:`.
    fn parseHttp(text: []const u8, scheme: Scheme, rest: []const u8) Url.ParseError!Url {
        var url: Url = .{ .scheme = scheme, .path = "", .raw = text };
        const end = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
        var authority = rest[0..end];
        if (std.mem.findScalar(u8, authority, '@')) |at| {
            const userinfo = authority[0..at];
            authority = authority[at + 1 ..];
            if (std.mem.findScalar(u8, userinfo, ':')) |colon| {
                url.user = userinfo[0..colon];
                url.password = userinfo[colon + 1 ..];
            } else url.user = userinfo;
        }
        if (authority.len != 0 and authority[0] == '[') {
            const close = std.mem.findScalar(u8, authority, ']') orelse return error.MalformedUrl;
            url.host = authority[1..close];
            try httpPort(&url, authority[close + 1 ..]);
        } else if (std.mem.findScalar(u8, authority, ':')) |colon| {
            // An unbracketed IPv6 address has several colons and no port.
            if (std.mem.findScalarPos(u8, authority, colon + 1, ':') == null) {
                url.host = authority[0..colon];
                try httpPort(&url, authority[colon..]);
            } else url.host = authority;
        } else url.host = authority;
        if (url.host.len == 0) return error.MalformedUrl;
        url.path = rest[end..];
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

    pub fn parse(gpa: Allocator, text: []const u8) Identity.Error!Identity {
        const raw = try gpa.dupe(u8, text);
        errdefer gpa.free(raw);
        var decoded: ?[]u8 = null;
        errdefer if (decoded) |bytes| gpa.free(bytes);
        // Read the scheme before decoding: escapes cannot invent a transport.
        const sep = schemeEnd(raw);
        const decode = if (sep) |end| if (nativeScheme(raw[0..end])) |scheme| switch (scheme) {
            .ssh, .git, .file => true,
            .local, .http, .https => false,
        } else false else false;
        var parsed: Url = undefined;
        if (decode) {
            decoded = try gpa.dupe(u8, raw);
            const buffer = decoded.?;
            // Git leaves zero and malformed escapes literal.
            const end = sep.? + percent.decodeInto(buffer[sep.?..], buffer[sep.?..], .literal);
            parsed = try Url.parse(buffer[0..end]);
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
/// `http` and `https`, each spelled exactly so. `null` for every other URL,
/// `rsync:` among them, which git refuses rather than hand to a helper.
pub fn helperOf(text: []const u8) ?Helper {
    if (helperNameEnd(text)) |end| return .{ .name = text[0..end], .address = text[end + 2 ..] };
    if (std.mem.startsWith(u8, text, "rsync:")) return null;
    const sep = schemeEnd(text) orelse return null;
    if (nativeScheme(text[0..sep]) != null) return null;
    return .{ .name = text[0..sep], .address = text };
}

test "a helper is named by <helper>:: or by a scheme relic does not speak" {
    const ext = helperOf("ext::ssh -i key host %S repo").?;
    try testing.expectEqualStrings("ext", ext.name);
    try testing.expectEqualStrings("ssh -i key host %S repo", ext.address);
    const foo = helperOf("foo+bar://host/repo").?;
    try testing.expectEqualStrings("foo+bar", foo.name);
    try testing.expectEqualStrings("foo+bar://host/repo", foo.address);
    try testing.expectEqualStrings("1foo", helperOf("1foo://host/repo").?.name);
    try testing.expectEqualStrings("2x", helperOf("2x::addr").?.name);
    try testing.expectEqualStrings("SSH", helperOf("SSH://host/repo").?.name);
    try testing.expectEqualStrings("rsync", helperOf("rsync::addr").?.name);
    try testing.expectEqualStrings("", helperOf("::addr").?.name);
    try testing.expect(helperOf("rsync://host/repo") == null);
    try testing.expect(helperOf("https://example.com/repo") == null);
    try testing.expect(helperOf("ssh://host/repo") == null);
    try testing.expect(helperOf("host:a::b") == null);
    try testing.expect(helperOf("./ext::repo") == null);
    try testing.expect(helperOf("/srv/repo") == null);
}

/// The transports relic reaches itself, by their exact scheme: git's
/// `transport_get` compares with `starts_with`, so case counts.
fn nativeScheme(text: []const u8) ?Scheme {
    const names = [_]struct { []const u8, Scheme }{
        .{ "ssh", .ssh }, .{ "git+ssh", .ssh }, .{ "ssh+git", .ssh }, .{ "file", .file },
        .{ "git", .git }, .{ "http", .http },   .{ "https", .https },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}

/// git's `is_urlschemechar`: an ASCII letter or digit first, then `+`,
/// `-` and `.` as well.
fn isSchemeChar(first: bool, c: u8) bool {
    return std.ascii.isAlphanumeric(c) or (!first and (c == '+' or c == '-' or c == '.'));
}

/// Where a `<helper>::` prefix's name ends, or `null`: `transport_get`'s
/// run of scheme characters, then `::`. The run may be empty, so `::addr`
/// names the helper `git-remote-`, as git reads it.
fn helperNameEnd(text: []const u8) ?usize {
    var end: usize = 0;
    while (end < text.len and isSchemeChar(end == 0, text[end])) end += 1;
    return if (std.mem.startsWith(u8, text[end..], "::")) end else null;
}

/// git's `is_url`: scheme characters, then `://`. Where the scheme ends.
fn schemeEnd(text: []const u8) ?usize {
    var end: usize = 0;
    while (end < text.len and isSchemeChar(end == 0, text[end])) end += 1;
    return if (end != 0 and std.mem.startsWith(u8, text[end..], "://")) end else null;
}

/// git's `host_end` without its bracket removal: the offset of the `]`
/// closing a host bracketed at the start or after the first `@[`, where
/// the search for the path begins; 0 when there is none.
fn bracketEnd(text: []const u8) usize {
    const start = if (std.mem.find(u8, text, "@[")) |at| at + 1 else 0;
    if (start >= text.len or text[start] != '[') return 0;
    return std.mem.findScalarPos(u8, text, start + 1, ']') orelse 0;
}

/// The path git hands an ssh remote: it skips one byte when the second is
/// `~`, which turns `/~user/repo` into `~user/repo` (and, as git reads it,
/// `a~b` into `~b`).
fn homePath(path: []const u8) []const u8 {
    return if (path.len >= 2 and path[1] == '~') path[1..] else path;
}

/// Split an ssh target as git's `get_host_and_port` and `get_port` do,
/// and the user from the host at its last `@`, as ssh does. A bracketed
/// host loses its brackets; a port is C's `strtol` over the rest, 0 to
/// 65535; a colon followed by anything else stays in the host, and a colon
/// at the end is dropped. What follows a closing bracket up to the colon
/// is dropped, as git drops it.
fn splitTarget(url: *Url, target: []const u8) ParseError!void {
    const start = if (std.mem.find(u8, target, "@[")) |at| at + 1 else 0;
    if (start < target.len and target[start] == '[') {
        if (std.mem.findScalarPos(u8, target, start + 1, ']')) |close| {
            const prefix = target[0..start];
            var content = target[start + 1 .. close];
            const after = target[close + 1 ..];
            if (std.mem.findScalar(u8, after, ':')) |colon| {
                url.port = connectPort(after[colon + 1 ..]);
            }
            // Else `get_port` on the joined host, at its first colon; one in
            // the prefix leaves an `@` in what follows, never a port.
            if (url.port == null and std.mem.findScalar(u8, prefix, ':') == null) {
                if (std.mem.findScalar(u8, content, ':')) |colon| if (connectPort(content[colon + 1 ..])) |port| {
                    url.port = port;
                    content = content[0..colon];
                };
            }
            if (prefix.len == 0) return splitUser(url, content);
            // `user@[host]`: the joined target is the prefix and the
            // content, one slice of the text only while the content holds
            // no `@` of its own.
            if (std.mem.findScalar(u8, content, '@') != null) return error.MalformedUrl;
            url.user = prefix[0 .. prefix.len - 1];
            url.host = content;
            if (url.host.len == 0) return error.MalformedUrl;
            return;
        }
    }
    var host = target;
    if (std.mem.findScalar(u8, target, ':')) |colon| {
        if (connectPort(target[colon + 1 ..])) |port| {
            url.port = port;
            host = target[0..colon];
        } else if (colon + 1 == target.len) host = target[0..colon];
    }
    return splitUser(url, host);
}

fn splitUser(url: *Url, target: []const u8) ParseError!void {
    if (std.mem.findScalarLast(u8, target, '@')) |at| {
        url.user = target[0..at];
        url.host = target[at + 1 ..];
    } else url.host = target;
    if (url.host.len == 0) return error.MalformedUrl;
}

/// git's port test: `strtol` read something, it is all of the rest, and
/// the value is 0 to 65535 (` 22`, `+22` and `-0` among them).
fn connectPort(text: []const u8) ?u16 {
    const r = decimal.strtol(text, 10, 64);
    if (r.end == 0 or r.end != text.len or r.value < 0 or r.value > 65535) return null;
    return @intCast(r.value);
}

/// curl's port: decimal digits, at most 65535; an empty one is no port.
fn httpPort(url: *Url, suffix: []const u8) ParseError!void {
    if (suffix.len == 0) return;
    if (suffix[0] != ':') return error.MalformedUrl;
    if (suffix.len == 1) return;
    url.port = decimal.digits(u16, suffix[1..]) orelse return error.MalformedUrl;
}

/// git's `url_is_local_not_ssh`: no colon, or a slash before the first
/// colon, or, on Windows, a drive (`win32_has_dos_drive_prefix`) before a
/// path Windows would open as itself (`is_valid_win32_path`): `h:22:r` is
/// an ssh address there.
pub fn isLocal(text: []const u8) bool {
    const colon = std.mem.findScalar(u8, text, ':') orelse return true;
    if (std.mem.findScalar(u8, text, '/')) |slash| {
        if (slash < colon) return true;
    }
    return builtin.target.os.tag == .windows and win32.dosDrivePrefixLen(text) != 0 and win32.win32PathReason(text) == null;
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
    try testing.expectError(error.UnsupportedTransport, Url.parse("rsync:host"));
    try testing.expectError(error.UnsupportedTransport, Url.parse("SSH://example.com/repo"));
    try testing.expectError(error.MalformedUrl, Url.parse("https:///repo"));
    try testing.expectError(error.MalformedUrl, Url.parse("https://host:port/repo"));
    try testing.expectError(error.MalformedUrl, Url.parse("ssh://host"));
}

test "an ssh port is what strtol reads, and anything else stays in the host" {
    // git's get_host_and_port: ssh is handed `example.com:port` as the host.
    const named = try Url.parse("ssh://example.com:port/repo");
    try testing.expectEqualStrings("example.com:port", named.host);
    try testing.expectEqual(@as(?u16, null), named.port);
    try testing.expectEqual(@as(?u16, 22), (try Url.parse("ssh://host:+22/repo")).port);
    try testing.expectEqualStrings("host:65536", (try Url.parse("ssh://host:65536/repo")).host);
    // A colon at the end is dropped; an empty scp path is git's too.
    try testing.expectEqualStrings("host", (try Url.parse("ssh://host:/repo")).host);
    try testing.expectEqualStrings("", (try Url.parse("host:")).path);
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
    try shakedown.check(testing.allocator, {}, fuzzParse, .{});
}

fn fuzzParse(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
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
    // A bracketed host is no host to git for Windows: the UNC path runs to
    // the end. Elsewhere the path begins at the `/` after the brackets, and
    // there is none.
    if (builtin.target.os.tag == .windows) {
        try testing.expectEqualStrings("//[a???//]:2-a@", (try Url.parse("file://[a???//]:2-a@")).path);
    } else try testing.expectError(error.MalformedUrl, Url.parse("file://[a???//]:2-a@"));
    // git's `parse_connect_url` reads a scheme before any `://`.
    try testing.expectError(error.UnsupportedTransport, Url.parse("./folder/ssh://host/repo"));
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
    try testing.expect(isLocal(path));
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

/// All errors reported by this namespace.
pub const Error = ParseError || Url.ParseError || Identity.Error || Allocator.Error;
