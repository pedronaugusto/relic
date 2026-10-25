//! Which `<section>.<url>.<key>` settings apply to a URL: git's urlmatch.
//!
//! Both the URL and each pattern are normalized as git's `url_normalize`
//! normalizes them (scheme and host in lower case, `%XX` escapes only
//! where needed and in upper case, a default port dropped, leading zeros
//! of a port dropped, `.` and `..` resolved, a `/` path added), and a URL
//! git cannot normalize is refused with the reason git gives. A pattern
//! matches when the schemes are the same, its user (if it names one) is
//! the URL's, its host matches label by label with `*` for any one label,
//! the ports are the same and its path is a prefix of the URL's at a `/`.
//! Among the patterns that match, the longer host wins, then the longer
//! path, then the one naming the user: git's `cmp_matches`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const percent = @import("percent.zig");

/// Why a URL does not normalize, git's `url_normalize` errors in order.
pub const NormalizeError = error{
    /// "invalid URL scheme name or missing '://' suffix".
    InvalidUrlScheme,
    /// "invalid %XX escape sequence".
    InvalidEscape,
    /// "missing host and scheme is not 'file:'".
    MissingHost,
    /// "a 'file:' URL may not have a port number".
    FileUrlPort,
    /// "invalid characters in host name".
    InvalidHostName,
    /// "invalid port number": not digits, 0, or past 65535.
    InvalidPort,
    /// "invalid '..' path segment": one above the root.
    InvalidDotSegment,
};

/// All errors reported by this namespace.
pub const Error = NormalizeError || Allocator.Error;

/// A normalized URL and where its parts are in it: git's `url_info`.
pub const Info = struct {
    /// The normalized text, the caller's to free.
    url: []u8,
    scheme_len: usize,
    /// The user, percent-escaped as normalized; empty for `http://@host`.
    user: ?Part = null,
    /// The password, present when the user part held a `:`.
    password: ?Part = null,
    /// The host, absent for a `file:` URL without one.
    host: Part = .{ .off = 0, .len = 0 },
    port: Part = .{ .off = 0, .len = 0 },
    /// From the path to the end: the path and whatever query or fragment
    /// followed it.
    path_off: usize,
    path_len: usize,

    pub const Part = struct {
        off: usize,
        len: usize,

        pub fn of(part: Part, info: Info) []const u8 {
            return info.url[part.off..][0..part.len];
        }
    };

    pub fn deinit(info: *Info, gpa: Allocator) void {
        gpa.free(info.url);
        info.* = undefined;
    }
};

const url_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const url_digit = "0123456789";
const url_scheme_chars = url_alpha ++ url_digit ++ "+.-";
const url_host_chars = url_alpha ++ url_digit ++ ".-_[:]";
const url_unsafe_chars = " <>\"%{}|\\^`";
const url_reserved = ":/?#[]@" ++ "!$&'()*+,;=";

/// `text` normalized as git's `url_normalize`; with `globs`, a host may
/// hold `*`, as a configuration pattern's may (`url_normalize_pattern`).
pub fn normalize(gpa: Allocator, text: []const u8, globs: bool) Error!Info {
    var norm: std.ArrayList(u8) = .empty;
    errdefer norm.deinit(gpa);

    // The scheme, a letter first, then `://`; no escapes.
    const scheme_len = spanOf(text, 0, url_scheme_chars);
    if (scheme_len == 0 or !std.ascii.isAlphabetic(text[0]) or scheme_len + 3 > text.len or
        !std.mem.eql(u8, text[scheme_len..][0..3], "://")) return error.InvalidUrlScheme;
    for (text[0 .. scheme_len + 3]) |c| try norm.append(gpa, std.ascii.toLower(c));
    var i = scheme_len + 3;

    // A user and password, up to an `@` before the end of the authority.
    var info: Info = .{ .url = &.{}, .scheme_len = scheme_len, .path_off = 0, .path_len = 0 };
    const slash = std.mem.findAnyPos(u8, text, i, "/?#") orelse text.len;
    if (std.mem.findScalarPos(u8, text, i, '@')) |at| if (at < slash) {
        const user_off = norm.items.len;
        var user_len: usize = 0;
        if (at > i) {
            if (!try appendEscapes(gpa, &norm, text[i..at], url_reserved)) return error.InvalidEscape;
            if (std.mem.findScalar(u8, norm.items[user_off..], ':')) |colon| {
                const passwd_off = user_off + colon + 1;
                info.password = .{ .off = passwd_off, .len = norm.items.len - passwd_off };
                user_len = colon;
            } else user_len = norm.items.len - user_off;
        }
        info.user = .{ .off = user_off, .len = user_len };
        try norm.append(gpa, '@');
        i = at + 1;
    };

    // The host, without its port; no escapes.
    var has_host = true;
    if (i == text.len or std.mem.findScalar(u8, ":/?#", text[i]) != null) {
        if (!std.mem.startsWith(u8, norm.items, "file:")) return error.MissingHost;
        has_host = false;
    }
    const host_off = norm.items.len;
    var colon = slash;
    if (slash > i) {
        var c = slash - 1;
        while (c > i and text[c] != ':' and text[c] != ']') c -= 1;
        if (text[c] == ':') colon = c;
    }
    if (colon != slash and !has_host and colon + 1 != slash) return error.FileUrlPort;
    const host_span = spanOf(text, i, if (globs) url_host_chars ++ "*" else url_host_chars);
    if (host_span < colon - i) return error.InvalidHostName;
    for (text[i..colon]) |c| try norm.append(gpa, std.ascii.toLower(c));
    i = colon;

    // The port, unless it is the scheme's own; leading zeros dropped.
    var port_len: usize = 0;
    if (colon < slash) {
        var p = colon + 1;
        while (p < slash and text[p] == '0') p += 1;
        if (p == slash and text[p - 1] == '0') p -= 1;
        const digits = text[p..slash];
        if (digits.len == 0) {
            // `host:` is the default port.
        } else if (std.mem.eql(u8, digits, "80") and std.mem.startsWith(u8, norm.items, "http:")) {
            // http's own.
        } else if (std.mem.eql(u8, digits, "443") and std.mem.startsWith(u8, norm.items, "https:")) {
            // https's own.
        } else {
            if (spanOf(digits, 0, url_digit) < digits.len) return error.InvalidPort;
            const number: u32 = if (digits.len <= 5) std.fmt.parseInt(u32, digits, 10) catch unreachable else 0; // aegis: no-danger: at most five digits
            if (number == 0 or number > 65535) return error.InvalidPort;
            try norm.append(gpa, ':');
            info.port = .{ .off = norm.items.len, .len = digits.len };
            try norm.appendSlice(gpa, digits);
            port_len = digits.len;
        }
        i = slash;
    }
    if (has_host) info.host = .{ .off = host_off, .len = norm.items.len - host_off - (if (port_len != 0) port_len + 1 else 0) };

    // The path, `.` and `..` resolved after unescaping, delimiters kept
    // escaped, a `/` first.
    const path_off = norm.items.len;
    try norm.append(gpa, '/');
    if (i < text.len and text[i] == '/') i += 1;
    while (true) {
        const seg_off = norm.items.len;
        const next = std.mem.findAnyPos(u8, text, i, "/?#") orelse text.len;
        if (!try appendEscapes(gpa, &norm, text[i..next], url_reserved)) return error.InvalidEscape;
        var skip_slash = false;
        const seg = norm.items[seg_off..];
        if (std.mem.eql(u8, seg, ".")) {
            if (seg_off == path_off + 1) {
                norm.items.len -= 1;
                skip_slash = true;
            } else norm.items.len -= 2;
        } else if (std.mem.eql(u8, seg, "..")) {
            var prev = norm.items.len - 3;
            if (prev == path_off) return error.InvalidDotSegment;
            prev -= 1;
            while (norm.items[prev] != '/') prev -= 1;
            if (prev == path_off) {
                norm.items.len = prev + 1;
                skip_slash = true;
            } else norm.items.len = prev;
        }
        i = next;
        if (i >= text.len or text[i] != '/') break;
        i += 1;
        if (!skip_slash) try norm.append(gpa, '/');
    }
    info.path_off = path_off;
    info.path_len = norm.items.len - path_off;

    // The rest, escapes normalized only.
    if (i < text.len) {
        if (!try appendEscapes(gpa, &norm, text[i..], url_reserved)) return error.InvalidEscape;
    }
    info.url = try norm.toOwnedSlice(gpa);
    return info;
}

fn spanOf(text: []const u8, start: usize, set: []const u8) usize {
    var n: usize = 0;
    while (start + n < text.len and std.mem.findScalar(u8, set, text[start + n]) != null) n += 1;
    return n;
}

/// git's `append_normalized_escapes` with no extra characters to escape:
/// a byte that must be escaped is (in upper case), one escaped that need
/// not be is not, unless it is one of `keep_escaped`. False for a `%` not
/// followed by two hexadecimal digits.
fn appendEscapes(gpa: Allocator, norm: *std.ArrayList(u8), from: []const u8, keep_escaped: []const u8) Allocator.Error!bool {
    var j: usize = 0;
    while (j < from.len) {
        var ch = from[j];
        j += 1;
        var was_escaped = false;
        if (ch == '%') {
            if (from.len - j < 2) return false;
            ch = percent.hexPair(from[j], from[j + 1]) orelse return false;
            j += 2;
            was_escaped = true;
        }
        if (ch <= 0x1f or ch >= 0x7f or std.mem.findScalar(u8, url_unsafe_chars, ch) != null or
            (was_escaped and std.mem.findScalar(u8, keep_escaped, ch) != null))
        {
            try norm.print(gpa, "%{X:0>2}", .{ch});
        } else try norm.append(gpa, ch);
    }
    return true;
}

/// How closely a pattern matched: git's `urlmatch_item`.
pub const Match = struct {
    /// The length of the pattern's normalized host.
    host_len: usize = 0,
    /// The length of the path matched, with its implicit final `/`.
    path_len: usize = 0,
    /// Whether the pattern named the URL's user.
    user_matched: bool = false,

    /// What an entry with no URL in its name matches with.
    pub const any: Match = .{};

    /// git's `cmp_matches`: the longer host, then the longer path, then
    /// the one naming the user.
    pub fn order(a: Match, b: Match) std.math.Order {
        if (a.host_len != b.host_len) return std.math.order(a.host_len, b.host_len);
        if (a.path_len != b.path_len) return std.math.order(a.path_len, b.path_len);
        if (a.user_matched != b.user_matched) return if (b.user_matched) .lt else .gt;
        return .eq;
    }
};

/// How `pattern` matches `url`, both normalized, or `null`: git's
/// `match_urls`.
pub fn match(url: Info, pattern: Info) ?Match {
    if (pattern.scheme_len != url.scheme_len or !std.mem.eql(u8, url.url[0..url.scheme_len], pattern.url[0..pattern.scheme_len])) return null;
    var user_matched = false;
    if (pattern.user) |want| {
        const have = url.user orelse return null;
        if (!std.mem.eql(u8, have.of(url), want.of(pattern))) return null;
        user_matched = true;
    }
    if (!hostMatches(url.host.of(url), pattern.host.of(pattern))) return null;
    if (!std.mem.eql(u8, url.port.of(url), pattern.port.of(pattern))) return null;
    const path_len = prefixMatch(url.url[url.path_off..], pattern.url[pattern.path_off..]);
    if (path_len == 0) return null;
    return .{ .host_len = pattern.host.len, .path_len = path_len, .user_matched = user_matched };
}

/// git's `match_host`: label by label, a pattern label `*` matching any
/// one; a final `.` on either side ends the name.
fn hostMatches(url_host: []const u8, pattern_host: []const u8) bool {
    var url = url_host;
    var pat = pattern_host;
    while (url.len != 0 and pat.len != 0) {
        const url_next = std.mem.findScalar(u8, url, '.') orelse url.len;
        const pat_next = std.mem.findScalar(u8, pat, '.') orelse pat.len;
        if (!(pat_next == 1 and pat[0] == '*') and !std.mem.eql(u8, url[0..url_next], pat[0..pat_next])) return false;
        url = url[@min(url_next + 1, url.len)..];
        pat = pat[@min(pat_next + 1, pat.len)..];
    }
    return url.len == 0 and pat.len == 0;
}

/// git's `url_match_prefix`: the length matched with an implicit final
/// `/`, or 0.
fn prefixMatch(url: []const u8, prefix_in: []const u8) usize {
    var prefix = prefix_in;
    if (prefix.len == 0 or (prefix.len == 1 and prefix[0] == '/')) return if (url.len == 0 or url[0] == '/') 1 else 0;
    if (prefix[prefix.len - 1] == '/') prefix = prefix[0 .. prefix.len - 1];
    if (!std.mem.startsWith(u8, url, prefix)) return 0;
    if (url.len == prefix.len or url[prefix.len] == '/') return prefix.len + 1;
    return 0;
}

const testing = std.testing;

test "a URL normalizes as git's url_normalize does" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "HTTPS://Ada%3a@Example.COM:0443/a/./b/../c%7e/%2F?q=%41#F", "https://Ada%3A@example.com/a/c~/%2F?q=A#F" },
        .{ "http://example.com:80", "http://example.com/" },
        .{ "http://example.com:0008080/x/.", "http://example.com:8080/x" },
        .{ "file:///srv/repo", "file:///srv/repo" },
        .{ "http://[::1]:8080/x y", "http://[::1]:8080/x%20y" },
    };
    for (cases) |case| {
        var info = try normalize(gpa, case[0], false);
        defer info.deinit(gpa);
        try testing.expectEqualStrings(case[1], info.url);
    }
    try testing.expectError(error.InvalidUrlScheme, normalize(gpa, "1http://h", false));
    try testing.expectError(error.MissingHost, normalize(gpa, "http:///x", false));
    try testing.expectError(error.FileUrlPort, normalize(gpa, "file://:22/x", false));
    try testing.expectError(error.InvalidHostName, normalize(gpa, "http://*.h/x", false));
    try testing.expectError(error.InvalidPort, normalize(gpa, "http://h:0/x", false));
    try testing.expectError(error.InvalidPort, normalize(gpa, "http://h:65536/x", false));
    try testing.expectError(error.InvalidDotSegment, normalize(gpa, "http://h/../x", false));
    try testing.expectError(error.InvalidEscape, normalize(gpa, "http://h/%G0", false));
}

test "the closer pattern is the longer host, then path, then a named user" {
    const gpa = testing.allocator;
    var url = try normalize(gpa, "https://ada@git.example.com/team/repo.git", false);
    defer url.deinit(gpa);
    var wild = try normalize(gpa, "https://*.example.com", true);
    defer wild.deinit(gpa);
    var exact = try normalize(gpa, "https://git.example.com/team/", true);
    defer exact.deinit(gpa);
    var user = try normalize(gpa, "https://ada@git.example.com/team", true);
    defer user.deinit(gpa);
    var other = try normalize(gpa, "https://bob@git.example.com", true);
    defer other.deinit(gpa);
    const a = match(url, wild).?;
    const b = match(url, exact).?;
    const c = match(url, user).?;
    try testing.expect(match(url, other) == null);
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.lt, b.order(c));
    try testing.expectEqual(std.math.Order.lt, Match.any.order(a));
}
