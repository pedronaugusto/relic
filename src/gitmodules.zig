//! `.gitmodules`: which submodule lives at which path, and where its
//! repository comes from.
//!
//! The file is a configuration file and is read with the configuration
//! parser, but it arrives in a tree, and a tree is written by whoever wrote
//! it. Three values in it have been used against git. A name holding `..` as
//! a component puts a submodule's repository outside `.git/modules`, where
//! its hooks run on the next checkout. A url or a path beginning with `-`
//! reaches `git clone` as an option. git ignores all three with a warning,
//! and `git fsck` refuses them. Here each is left out of the parsed file and
//! listed in `Gitmodules.refused` with its reason, so a caller can say what
//! was dropped rather than find it missing.
//!
//! `checkName` and `checkUrl` are `git fsck`'s own rules, which are stricter
//! than what reading the file drops: a relative url that climbs onto the
//! host part of the url it is resolved against, and a url whose decoded form
//! carries a newline into a credential helper, are refused there as well.
//! `resolveUrl` is git's resolution of a url beginning `./` or `../`
//! against the superproject's own, including the colon a `host:path` url
//! turns into when its last directory is taken away.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");

/// Errors from reading `.gitmodules`.
pub const ParseError = error{
    /// `path`, `url`, `branch`, `update` or `ignore` written as a bare name,
    /// with no value. git stops reading the file there.
    MissingValue,
    /// `update` is not one of git's strategies, or is a `!command`, which
    /// git accepts from a repository's own configuration and never from a
    /// file that arrives in a tree.
    InvalidUpdate,
    /// `fetchRecurseSubmodules` is neither a boolean nor `on-demand`.
    InvalidFetchRecurse,
    /// `shallow` is not a boolean.
    InvalidShallow,
    /// A subsection name ending in an escaping backslash.
    MalformedSectionHeader,
} || config_mod.ParseError;

/// How a submodule is brought to the commit its superproject records.
pub const Update = union(enum) {
    /// Detach its `HEAD` at the commit. The default.
    checkout,
    /// Rebase its current branch onto the commit.
    rebase,
    /// Merge the commit into its current branch.
    merge,
    /// Leave it alone.
    none,
    /// `!command`: run the command in the submodule with the commit as its
    /// argument. Borrowed from the configuration it was read from.
    command: []const u8,

    /// git's `parse_submodule_update_strategy`, or `null` for a word that is
    /// not a strategy.
    pub fn parse(text: []const u8) ?Update {
        if (std.mem.eql(u8, text, "checkout")) return .checkout;
        if (std.mem.eql(u8, text, "rebase")) return .rebase;
        if (std.mem.eql(u8, text, "merge")) return .merge;
        if (std.mem.eql(u8, text, "none")) return .none;
        if (text.len > 0 and text[0] == '!') return .{ .command = text[1..] };
        return null;
    }

    /// The word git writes into `.git/config` for it.
    pub fn name(u: Update) []const u8 {
        return switch (u) {
            .checkout => "checkout",
            .rebase => "rebase",
            .merge => "merge",
            .none => "none",
            .command => "!command",
        };
    }
};

/// Which changes inside a submodule its superproject's status reports.
pub const Ignore = enum {
    /// Every change: a moved `HEAD`, modified content, untracked files.
    none,
    /// Everything but untracked files.
    untracked,
    /// Only a moved `HEAD`.
    dirty,
    /// Nothing.
    all,

    /// The setting's value, or `null` for one git does not know.
    pub fn parse(text: []const u8) ?Ignore {
        return std.meta.stringToEnum(Ignore, text);
    }
};

/// `fetchRecurseSubmodules`.
pub const FetchRecurse = enum { off, on, on_demand };

/// One `[submodule "<name>"]` section. Every slice is owned by the
/// `Gitmodules` it came from.
pub const Submodule = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    update: ?Update = null,
    ignore: ?Ignore = null,
    shallow: ?bool = null,
    fetch_recurse: ?FetchRecurse = null,
    /// When `path` was last set, counted in settings read. Two sections
    /// naming one path is resolved the way git's cache resolves it: the one
    /// that set it last owns it.
    path_set_at: u32 = 0,
};

/// Why a value was left out.
pub const Reason = enum {
    /// The name is empty, or holds `..` as a component under either
    /// separator.
    suspicious_name,
    /// A `path` or `url` beginning with `-`.
    option_like_value,
    /// An `ignore` that is not `none`, `untracked`, `dirty` or `all`.
    unknown_ignore_value,
};

/// A setting read and left out.
pub const Refused = struct {
    /// The subsection as written, unescaped.
    name: []const u8,
    /// The variable, lower-case.
    key: []const u8,
    /// Its value, when it had one.
    value: ?[]const u8,
    reason: Reason,
};

/// A parsed `.gitmodules`.
pub const Gitmodules = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// In the order their sections first appear.
    submodules: []Submodule,
    refused: []Refused,

    /// No submodules at all, which is what a missing file reads as.
    pub fn empty(gpa: Allocator) Gitmodules {
        return .{ .gpa = gpa, .arena = .{}, .submodules = &.{}, .refused = &.{} };
    }

    /// Read `text` the way git reads the working tree's `.gitmodules`: the
    /// last value of a setting wins, and a refused value leaves the one
    /// before it in place.
    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Gitmodules {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var config = try config_mod.Config.parseText(gpa, text, .local);
        defer config.deinit();

        var submodules: std.ArrayList(Submodule) = .empty;
        var refused: std.ArrayList(Refused) = .empty;
        var order: u32 = 0;
        for (config.entries.items) |entry| {
            order += 1;
            if (!std.ascii.eqlIgnoreCase(entry.section, "submodule")) continue;
            if (entry.subsection.len == 0) continue;
            const key = try std.ascii.allocLowerString(arena, entry.name);
            const value: ?[]const u8 = if (entry.value) |raw|
                config_mod.unquote(arena, raw) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.MalformedValue,
                }
            else
                null;

            const name = try unescapeSubsection(arena, entry.subsection);
            if (!checkName(name)) {
                try refused.append(arena, .{ .name = name, .key = key, .value = value, .reason = .suspicious_name });
                continue;
            }
            const sub = blk: {
                for (submodules.items) |*existing| {
                    if (std.mem.eql(u8, existing.name, name)) break :blk existing;
                }
                try submodules.append(arena, .{ .name = name });
                break :blk &submodules.items[submodules.items.len - 1];
            };

            if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "url")) {
                const v = value orelse return error.MissingValue;
                if (looksLikeOption(v)) {
                    try refused.append(arena, .{ .name = name, .key = key, .value = v, .reason = .option_like_value });
                    continue;
                }
                if (key[0] == 'p') {
                    sub.path = v;
                    sub.path_set_at = order;
                } else {
                    sub.url = v;
                }
            } else if (std.mem.eql(u8, key, "branch")) {
                sub.branch = value orelse return error.MissingValue;
            } else if (std.mem.eql(u8, key, "update")) {
                const v = value orelse return error.MissingValue;
                const parsed = Update.parse(v) orelse return error.InvalidUpdate;
                if (parsed == .command) return error.InvalidUpdate;
                sub.update = parsed;
            } else if (std.mem.eql(u8, key, "ignore")) {
                const v = value orelse return error.MissingValue;
                sub.ignore = Ignore.parse(v) orelse {
                    try refused.append(arena, .{ .name = name, .key = key, .value = v, .reason = .unknown_ignore_value });
                    continue;
                };
            } else if (std.mem.eql(u8, key, "shallow")) {
                // A bare name is true, as it is for every boolean.
                sub.shallow = if (value) |v| config_mod.parseBool(v) catch return error.InvalidShallow else true;
            } else if (std.mem.eql(u8, key, "fetchrecursesubmodules")) {
                sub.fetch_recurse = try parseFetchRecurse(value);
            }
        }
        return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .submodules = submodules.items,
            .refused = refused.items,
        };
    }

    /// Release everything.
    pub fn deinit(g: *Gitmodules) void {
        var arena = g.arena.promote(g.gpa);
        arena.deinit();
        g.* = undefined;
    }

    /// The submodule named `name`, or `null`.
    pub fn byName(g: *const Gitmodules, name: []const u8) ?*const Submodule {
        for (g.submodules) |*sub| {
            if (std.mem.eql(u8, sub.name, name)) return sub;
        }
        return null;
    }

    /// The submodule whose `path` is `path`, or `null`. Where two claim it,
    /// the one that claimed it last.
    pub fn byPath(g: *const Gitmodules, path: []const u8) ?*const Submodule {
        var found: ?*const Submodule = null;
        for (g.submodules) |*sub| {
            const p = sub.path orelse continue;
            if (!std.mem.eql(u8, p, path)) continue;
            if (found == null or sub.path_set_at > found.?.path_set_at) found = sub;
        }
        return found;
    }
};

fn parseFetchRecurse(value: ?[]const u8) ParseError!FetchRecurse {
    const v = value orelse return .on;
    if (config_mod.parseBool(v)) |b| {
        return if (b) .on else .off;
    } else |_| {}
    if (std.mem.eql(u8, v, "on-demand")) return .on_demand;
    return error.InvalidFetchRecurse;
}

/// A quoted subsection's escapes: a backslash takes the next byte as it is.
fn unescapeSubsection(arena: Allocator, raw: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return arena.dupe(u8, raw);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            if (i == raw.len) return error.MalformedSectionHeader;
        }
        try out.append(arena, raw[i]);
    }
    return out.items;
}

/// git's `looks_like_command_line_option`.
fn looksLikeOption(value: []const u8) bool {
    return value.len > 0 and value[0] == '-';
}

/// Whether `name` may name a submodule: not empty, and no component `..`
/// under `/` or `\`, on every platform alike, which is git's
/// `check_submodule_name`.
pub fn checkName(name: []const u8) bool {
    if (name.len == 0) return false;
    var start: usize = 0;
    for (name, 0..) |c, i| {
        if (c == '/' or c == '\\') {
            if (std.mem.eql(u8, name[start..i], "..")) return false;
            start = i + 1;
        }
    }
    return !std.mem.eql(u8, name[start..], "..");
}

/// Whether a url begins `./` or `../`, under either separator, which is
/// what makes it relative to the superproject's.
pub fn isRelativeUrl(url: []const u8) bool {
    return startsWithDotSlash(url, true) or startsWithDotDotSlash(url, true);
}

fn isSep(c: u8, cross_platform: bool) bool {
    return c == '/' or ((cross_platform or builtin.os.tag == .windows) and c == '\\');
}

fn startsWithDotSlash(s: []const u8, cross_platform: bool) bool {
    return s.len >= 2 and s[0] == '.' and isSep(s[1], cross_platform);
}

fn startsWithDotDotSlash(s: []const u8, cross_platform: bool) bool {
    return s.len >= 3 and s[0] == '.' and s[1] == '.' and isSep(s[2], cross_platform);
}

/// Whether `git fsck` accepts `url` in a `.gitmodules`.
///
/// A url beginning `-` is refused. A relative one is refused when its
/// decoded form holds a newline, or when the `../` it begins with are
/// followed by `:` or `/`, which would climb into the host part of the url
/// it is resolved against. An `http`, `https`, `ftp` or `ftps` url — or one
/// of the `<transport>::<url>` spellings of those — is refused when it does
/// not survive normalisation (a bad `%` escape, no host, a port that is not
/// one, a `..` above the root) or when it decodes to a newline. Anything
/// else is left to the transport that reads it.
pub fn checkUrl(url: []const u8) bool {
    if (looksLikeOption(url)) return false;
    if (isRelativeUrl(url)) {
        if (decodesToNewline(url)) return false;
        var rest = url;
        var climbs: usize = 0;
        while (true) {
            if (startsWithDotDotSlash(rest, true)) {
                climbs += 1;
                rest = rest[3..];
            } else if (startsWithDotSlash(rest, true)) {
                rest = rest[2..];
            } else break;
        }
        if (climbs > 0 and rest.len > 0 and (rest[0] == ':' or rest[0] == '/')) return false;
        return true;
    }
    if (curlUrl(url)) |curl| return curlUrlIsSafe(curl);
    return true;
}

fn curlUrl(url: []const u8) ?[]const u8 {
    for ([_][]const u8{ "http::", "https::", "ftp::", "ftps::" }) |prefix| {
        if (std.mem.startsWith(u8, url, prefix)) return url[prefix.len..];
    }
    for ([_][]const u8{ "http://", "https://", "ftp://", "ftps://" }) |prefix| {
        if (std.mem.startsWith(u8, url, prefix)) return url;
    }
    return null;
}

/// `url_decode` leaves a `%` that is not followed by two hex digits as it
/// is, so only a well-formed escape can produce a newline.
fn decodesToNewline(url: []const u8) bool {
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] == '\n') return true;
        if (url[i] == '%' and i + 2 < url.len) {
            const byte = std.fmt.parseInt(u8, url[i + 1 .. i + 3], 16) catch continue;
            if (byte == '\n') return true;
        }
    }
    return false;
}

/// The parts of git's `url_normalize` that decide whether it fails, then
/// the newline check on what it would produce.
fn curlUrlIsSafe(url: []const u8) bool {
    if (std.mem.indexOfScalar(u8, url, '\n') != null) return false;
    // Every `%` must begin a two-digit escape.
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] != '%') continue;
        if (i + 2 >= url.len) return false;
        const byte = std.fmt.parseInt(u8, url[i + 1 .. i + 3], 16) catch return false;
        if (byte == '\n') return false;
        i += 2;
    }
    // A scheme, then `://`.
    const colon = std.mem.indexOf(u8, url, "://") orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(url[0])) return false;
    for (url[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    const after = url[colon + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    var authority = after[0..authority_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    // The host, then an optional port.
    var host = authority;
    if (host.len > 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return false;
        const port_part = host[close + 1 ..];
        host = host[0 .. close + 1];
        if (port_part.len > 0 and !validPort(port_part)) return false;
    } else if (std.mem.lastIndexOfScalar(u8, host, ':')) |port_at| {
        if (!validPort(host[port_at..])) return false;
        host = host[0..port_at];
    }
    if (host.len == 0) return false;
    // A `..` segment may not climb above the root.
    var depth: usize = 0;
    const path_end = std.mem.indexOfAny(u8, after[authority_end..], "?#") orelse after.len - authority_end;
    var segments = std.mem.splitScalar(u8, after[authority_end..][0..path_end], '/');
    _ = segments.next();
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            if (depth == 0) return false;
            depth -= 1;
        } else if (!std.mem.eql(u8, segment, ".")) {
            depth += 1;
        }
    }
    return true;
}

/// `:<digits>`, naming a port from 1 to 65535, or a bare `:` that names
/// none.
fn validPort(text: []const u8) bool {
    std.debug.assert(text[0] == ':');
    if (text.len == 1) return true;
    const port = std.fmt.parseInt(u32, text[1..], 10) catch return false;
    return port >= 1 and port <= 65535;
}

/// Errors from resolving a relative url.
pub const ResolveError = error{
    /// More `../` than the url it is resolved against has components.
    CannotStripComponent,
} || Allocator.Error;

/// Resolve `url`, which begins `./` or `../`, against `base`, the
/// superproject's own remote url, the way git's `relative_url` does. The
/// result is the caller's.
///
/// Each `../` takes the last `/`-separated component off `base`; where
/// there is no `/` left but there is a `:`, the `:` is the separator that
/// goes, and the two parts are joined with `:` rather than `/`, so
/// `host:repo` and `../sub` make `host:sub`. A `base` that is itself
/// relative stays relative, and `up_path` — `../` for each component of the
/// submodule's own path, when the url is for the submodule's own remote —
/// goes in front of it.
pub fn resolveUrl(gpa: Allocator, base: []const u8, url: []const u8, up_path: ?[]const u8) ResolveError![]u8 {
    if (!isLocalNotSsh(url) or isAbsolutePath(url)) return gpa.dupe(u8, url);
    std.debug.assert(base.len != 0);

    var remote: std.ArrayList(u8) = .empty;
    defer remote.deinit(gpa);
    try remote.appendSlice(gpa, base);
    if (isSep(remote.items[remote.items.len - 1], false)) remote.items.len -= 1;

    const is_relative = isLocalNotSsh(remote.items) and !isAbsolutePath(remote.items);
    if (is_relative and !startsWithDotSlash(remote.items, false) and !startsWithDotDotSlash(remote.items, false)) {
        try remote.insertSlice(gpa, 0, "./");
    }

    var rest = url;
    var colon_separated = false;
    while (rest.len > 0) {
        if (startsWithDotDotSlash(rest, false)) {
            rest = rest[3..];
            if (lastDirSep(remote.items)) |at| {
                remote.items.len = at;
            } else if (std.mem.lastIndexOfScalar(u8, remote.items, ':')) |at| {
                remote.items.len = at;
                colon_separated = true;
            } else {
                if (is_relative or std.mem.eql(u8, remote.items, ".")) return error.CannotStripComponent;
                remote.clearRetainingCapacity();
                try remote.append(gpa, '.');
            }
        } else if (startsWithDotSlash(rest, false)) {
            rest = rest[2..];
        } else break;
    }

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joined.appendSlice(gpa, remote.items);
    try joined.append(gpa, if (colon_separated) ':' else '/');
    try joined.appendSlice(gpa, rest);
    if (rest.len > 0 and rest[rest.len - 1] == '/') joined.items.len -= 1;

    const resolved = if (startsWithDotSlash(joined.items, false)) joined.items[2..] else joined.items;
    if (up_path == null or !is_relative) return gpa.dupe(u8, resolved);
    return std.mem.concat(gpa, u8, &.{ up_path.?, resolved });
}

/// git's `url_is_local_not_ssh`: no colon, or a slash before the first
/// one, or a drive letter on Windows.
fn isLocalNotSsh(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    if (std.mem.indexOfScalar(u8, url, '/')) |slash| {
        if (slash < colon) return true;
    }
    return builtin.os.tag == .windows and hasDriveLetter(url);
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return true;
    if (builtin.os.tag == .windows) {
        return (path.len > 0 and path[0] == '\\') or hasDriveLetter(path);
    }
    return false;
}

fn hasDriveLetter(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn lastDirSep(path: []const u8) ?usize {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (isSep(path[i], false)) return i;
    }
    return null;
}

//=========================================================================
// Tests
//=========================================================================

const testing = std.testing;
const testgit = @import("testgit.zig");

test "a section's settings are read, the last value winning" {
    var g = try Gitmodules.parse(testing.allocator,
        \\[submodule "vendor/lib"]
        \\    path = vendor/lib
        \\    url = ../lib
        \\    branch = stable
        \\    update = rebase
        \\    ignore = dirty
        \\    shallow
        \\    fetchRecurseSubmodules = on-demand
        \\[submodule "other"]
        \\    path = "other dir"
        \\    URL = ./other
        \\    url = ./other-moved
        \\
    );
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.submodules.len);
    const lib = g.byPath("vendor/lib").?;
    try testing.expectEqualStrings("vendor/lib", lib.name);
    try testing.expectEqualStrings("../lib", lib.url.?);
    try testing.expectEqualStrings("stable", lib.branch.?);
    try testing.expectEqual(Update.rebase, lib.update.?);
    try testing.expectEqual(Ignore.dirty, lib.ignore.?);
    try testing.expectEqual(true, lib.shallow.?);
    try testing.expectEqual(FetchRecurse.on_demand, lib.fetch_recurse.?);
    const other = g.byName("other").?;
    try testing.expectEqualStrings("other dir", other.path.?);
    try testing.expectEqualStrings("./other-moved", other.url.?);
    try testing.expect(g.byPath("nowhere") == null);
}

test "a suspicious name and an option-like value are left out and listed" {
    var g = try Gitmodules.parse(testing.allocator,
        \\[submodule "../escape"]
        \\    path = escape
        \\    url = ./escape
        \\[submodule "ok"]
        \\    path = ok
        \\    url = ./ok
        \\    url = --upload-pack=touch${IFS}owned
        \\    path = -x
        \\    ignore = sometimes
        \\
    );
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.submodules.len);
    const ok = g.byName("ok").?;
    try testing.expectEqualStrings("./ok", ok.url.?);
    try testing.expectEqualStrings("ok", ok.path.?);
    try testing.expect(ok.ignore == null);
    try testing.expectEqual(@as(usize, 5), g.refused.len);
    try testing.expectEqual(Reason.suspicious_name, g.refused[0].reason);
    try testing.expectEqualStrings("../escape", g.refused[0].name);
    try testing.expectEqual(Reason.suspicious_name, g.refused[1].reason);
    try testing.expectEqual(Reason.option_like_value, g.refused[2].reason);
    try testing.expectEqualStrings("url", g.refused[2].key);
    try testing.expectEqual(Reason.option_like_value, g.refused[3].reason);
    try testing.expectEqualStrings("path", g.refused[3].key);
    try testing.expectEqual(Reason.unknown_ignore_value, g.refused[4].reason);
}

test "a !command update in .gitmodules is refused, as git refuses it" {
    try testing.expectError(error.InvalidUpdate, Gitmodules.parse(testing.allocator,
        \\[submodule "a"]
        \\    path = a
        \\    update = !rm -rf /
        \\
    ));
    try testing.expectError(error.InvalidUpdate, Gitmodules.parse(testing.allocator,
        \\[submodule "a"]
        \\    update = sideways
        \\
    ));
    try testing.expectError(error.MissingValue, Gitmodules.parse(testing.allocator,
        \\[submodule "a"]
        \\    url
        \\
    ));
    try testing.expectError(error.InvalidFetchRecurse, Gitmodules.parse(testing.allocator,
        \\[submodule "a"]
        \\    fetchRecurseSubmodules = sometimes
        \\
    ));
}

test "two sections naming one path: the later claim owns it" {
    var g = try Gitmodules.parse(testing.allocator,
        \\[submodule "first"]
        \\    path = shared
        \\[submodule "second"]
        \\    path = shared
        \\
    );
    defer g.deinit();
    try testing.expectEqualStrings("second", g.byPath("shared").?.name);
}

test "a quoted name's escapes are undone" {
    var g = try Gitmodules.parse(testing.allocator, "[submodule \"a\\\"b\\\\c\"]\n\tpath = p\n");
    defer g.deinit();
    try testing.expectEqualStrings("a\"b\\c", g.submodules[0].name);
}

test "names and urls: this refuses exactly what git fsck refuses" {
    const names = [_][]const u8{
        "..",   "a/../b", "a\\..\\b", "../a", "a/..", "foo/",  "-foo", "a/./b",
        ".git", "x/.git", "a:b",      "..a",  "a..",  "a/..b", "sub",
    };
    for (names) |name| {
        try expectFsckAgrees(name, "u", checkName(name) and checkUrl("u"));
    }
    const urls = [_][]const u8{
        "-u",             "./-u",              "http://h/%0a",       "../../../:x",
        "../:x",          "..//x",             "http::http://h/%0a", "https://h/a%0ab",
        "x%0ay",          "./x%0a",            "https:///x",         "file:///x%0a",
        "../sub",         "https://h:99999/x", "https://h:22/x",     "https://h/%zz",
        "https://h/../x", "https://h/a/../x",  "http::nohost",       "ssh://h/x",
        "user@h:repo",    "./a/../b",
    };
    for (urls) |url| {
        try expectFsckAgrees("n", url, checkUrl(url));
    }
}

/// Commit a `.gitmodules` naming one submodule in a repository of its own,
/// ask `git fsck` about it, and compare its verdict with `accepted`. A
/// repository each, because fsck reads every `.gitmodules` in the history.
fn expectFsckAgrees(name: []const u8, url: []const u8, accepted: bool) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    for (name) |c| {
        if (c == '"' or c == '\\') try escaped.append(gpa, '\\');
        try escaped.append(gpa, c);
    }
    const text = try std.fmt.allocPrint(gpa, "[submodule \"{s}\"]\n\tpath = p\n\turl = {s}\n", .{ escaped.items, url });
    defer gpa.free(text);
    try git.writeFile(io, ".gitmodules", text);
    try git.exec(io, &.{ "add", ".gitmodules" });
    try git.exec(io, &.{ "commit", "-q", "-m", "probe" });
    git.report_failures = false;
    const fsck_ok = if (git.run(io, &.{ "fsck", "--no-progress", "--no-dangling" })) |out| blk: {
        gpa.free(out);
        break :blk true;
    } else |err| switch (err) {
        error.GitFailed => false,
        else => return err,
    };
    if (fsck_ok != accepted) {
        std.debug.print("name {s} url {s}: git fsck says {}, this says {}\n", .{ name, url, fsck_ok, accepted });
        return error.TestExpectedEqual;
    }
}

test "relative urls resolve exactly as git's own table says" {
    const gpa = testing.allocator;
    const Case = struct { base: []const u8, url: []const u8, up: ?[]const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .base = "../foo", .url = "../submodule", .up = "../", .want = "../../submodule" },
        .{ .base = "../foo/bar", .url = "../submodule", .up = "../", .want = "../../foo/submodule" },
        .{ .base = "../foo/submodule", .url = "../submodule", .up = "../", .want = "../../foo/submodule" },
        .{ .base = "./foo", .url = "../submodule", .up = "../", .want = "../submodule" },
        .{ .base = "./foo/bar", .url = "../submodule", .up = "../", .want = "../foo/submodule" },
        .{ .base = "../foo/bar", .url = "../sub/a/b/c", .up = "../../../", .want = "../../../../foo/sub/a/b/c" },
        .{ .base = "/abs/addtest", .url = "../repo", .up = "../", .want = "/abs/repo" },
        .{ .base = "foo/bar", .url = "../submodule", .up = "../", .want = "../foo/submodule" },
        .{ .base = "foo", .url = "../submodule", .up = "../", .want = "../submodule" },
        .{ .base = "../foo/bar", .url = "../sub/a/b/c", .up = null, .want = "../foo/sub/a/b/c" },
        .{ .base = "../foo/bar", .url = "../sub/a/b/c/", .up = null, .want = "../foo/sub/a/b/c" },
        .{ .base = "../foo/bar/", .url = "../sub/a/b/c", .up = null, .want = "../foo/sub/a/b/c" },
        .{ .base = "./foo/bar", .url = "../submodule", .up = null, .want = "foo/submodule" },
        .{ .base = "./foo", .url = "../submodule", .up = null, .want = "submodule" },
        .{ .base = "//somewhere else/repo", .url = "../subrepo", .up = null, .want = "//somewhere else/subrepo" },
        .{ .base = "//somewhere else/repo", .url = "../../subrepo", .up = null, .want = "//subrepo" },
        .{ .base = "//somewhere else/repo", .url = "../../../subrepo", .up = null, .want = "/subrepo" },
        .{ .base = "//somewhere else/repo", .url = "../../../../subrepo", .up = null, .want = "subrepo" },
        .{ .base = "/abs/.", .url = "../.", .up = null, .want = "/abs/." },
        .{ .base = "/abs", .url = "./.", .up = null, .want = "/abs/." },
        .{ .base = "/abs/home2/../remote", .url = "../bundle1", .up = null, .want = "/abs/home2/../bundle1" },
        .{ .base = "file:///tmp/repo", .url = "../subrepo", .up = null, .want = "file:///tmp/subrepo" },
        .{ .base = "foo", .url = "../submodule", .up = null, .want = "submodule" },
        .{ .base = "helper:://hostname/repo", .url = "../subrepo", .up = null, .want = "helper:://hostname/subrepo" },
        .{ .base = "helper:://hostname/repo", .url = "../../subrepo", .up = null, .want = "helper:://subrepo" },
        .{ .base = "helper:://hostname/repo", .url = "../../../subrepo", .up = null, .want = "helper::/subrepo" },
        .{ .base = "helper:://hostname/repo", .url = "../../../../subrepo", .up = null, .want = "helper::subrepo" },
        .{ .base = "helper:://hostname/repo", .url = "../../../../../subrepo", .up = null, .want = "helper:subrepo" },
        .{ .base = "helper:://hostname/repo", .url = "../../../../../../subrepo", .up = null, .want = ".:subrepo" },
        .{ .base = "ssh://hostname/repo", .url = "../subrepo", .up = null, .want = "ssh://hostname/subrepo" },
        .{ .base = "ssh://hostname/repo", .url = "../../subrepo", .up = null, .want = "ssh://subrepo" },
        .{ .base = "ssh://hostname/repo", .url = "../../../subrepo", .up = null, .want = "ssh:/subrepo" },
        .{ .base = "ssh://hostname/repo", .url = "../../../../subrepo", .up = null, .want = "ssh:subrepo" },
        .{ .base = "ssh://hostname/repo", .url = "../../../../../subrepo", .up = null, .want = ".:subrepo" },
        .{ .base = "ssh://hostname:22/repo", .url = "../subrepo", .up = null, .want = "ssh://hostname:22/subrepo" },
        .{ .base = "user@host:path/to/repo", .url = "../subrepo", .up = null, .want = "user@host:path/to/subrepo" },
        .{ .base = "user@host:repo", .url = "../subrepo", .up = null, .want = "user@host:subrepo" },
        .{ .base = "user@host:repo", .url = "../../subrepo", .up = null, .want = ".:subrepo" },
    };
    for (cases) |case| {
        const got = try resolveUrl(gpa, case.base, case.url, case.up);
        defer gpa.free(got);
        testing.expectEqualStrings(case.want, got) catch |err| {
            std.debug.print("base {s} url {s}\n", .{ case.base, case.url });
            return err;
        };
    }
    try testing.expectError(error.CannotStripComponent, resolveUrl(gpa, "./foo", "../../x", null));
    const absolute = try resolveUrl(gpa, "https://h/a", "/elsewhere", null);
    defer gpa.free(absolute);
    try testing.expectEqualStrings("/elsewhere", absolute);
}

test "fuzz: any bytes are a .gitmodules or a named error" {
    try std.testing.fuzz({}, fuzzGitmodules, .{});
}

fn fuzzGitmodules(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    _ = checkUrl(input);
    _ = checkName(input);
    if (isRelativeUrl(input)) {
        if (resolveUrl(gpa, "https://example.com/a/b", input, "../")) |resolved| {
            gpa.free(resolved);
        } else |_| {}
    }
    var g = Gitmodules.parse(gpa, input) catch return;
    defer g.deinit();
    for (g.submodules) |sub| {
        // Whatever was kept, the rules that decided what was left out hold.
        try testing.expect(checkName(sub.name));
        if (sub.url) |url| try testing.expect(!looksLikeOption(url));
        if (sub.path) |path| {
            try testing.expect(!looksLikeOption(path));
            try testing.expect(g.byPath(path) != null);
        }
        try testing.expect(g.byName(sub.name) != null);
    }
}
