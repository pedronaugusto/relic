//! git-lfs's configuration: the repository's, what `.lfsconfig` adds where
//! the repository's says nothing, and URL-scoped settings matched as git-lfs
//! matches them. The one reader of `.lfsconfig`: the store, the API and the
//! locks all take their settings from here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("../config/config.zig");
const decimal = @import("../text.zig").decimal;
const repo_mod = @import("../repo/repo.zig");

const Config = config_mod.Config;

/// What reading git-lfs's configuration can fail with.
pub const Error = Settings.Error;

/// The value git-lfs sees for `full_name` in `config`: the last one written
/// with a value. git-lfs reads `git config -l -z`, where a name written with
/// no `=` has no value line, and drops it (`git.ParseConfigEntries`).
pub fn configValue(config: *const config_mod.Config, full_name: []const u8) ?[]const u8 {
    const split = config_mod.splitFullName(full_name) orelse return null;
    var found: ?[]const u8 = null;
    for (config.entries.items) |entry| {
        if (!entry.matches(split.section, split.subsection, split.name)) continue;
        found = entry.value orelse continue;
    }
    return found;
}

/// git-lfs's `config.Bool`, which every boolean git-lfs setting is read
/// through: `fallback` for an empty value; `true`, `1`, `on`, `yes` and `t`
/// in any case are true, and anything else is false.
pub fn configBool(value: []const u8, fallback: bool) bool {
    if (value.len == 0) return fallback;
    for ([_][]const u8{ "true", "1", "on", "yes", "t" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    return false;
}

/// git-lfs's `config.Int`: `fallback` for an empty value or one Go's
/// `strconv.Atoi` refuses (`text.decimal.goInt`).
pub fn configInt(value: []const u8, fallback: i64) i64 {
    return decimal.goInt(i64, value) orelse fallback;
}

/// git-lfs's configuration: the repository's, and what `.lfsconfig` adds
/// where the repository's says nothing.
pub const Settings = struct {
    pub const Error = LoadRepoError;

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

    /// Errors from reading `.lfsconfig`'s text.
    pub const ParseError = Allocator.Error || config_mod.ParseError;

    /// `config` with `.lfsconfig`'s text, when there is one, as git-lfs
    /// finds it (`Repository.lfsconfigText`). `config` is borrowed for as
    /// long as the settings live; the text is not.
    pub fn parse(gpa: Allocator, config: *const Config, lfsconfig: ?[]const u8) ParseError!Settings {
        var s: Settings = .{ .gpa = gpa, .config = config };
        if (lfsconfig) |text| s.file = try Config.parseText(gpa, text, .local);
        return s;
    }

    /// Errors from `loadRepo`.
    pub const LoadRepoError = ParseError || LfsconfigError;

    /// The settings of `repo`, with `.lfsconfig` found where git-lfs finds
    /// it: `Repository.lfsconfigText`. `repo`'s configuration is borrowed.
    pub fn loadRepo(gpa: Allocator, io: Io, repo: *repo_mod.Repository) LoadRepoError!Settings {
        const text = try repo.lfsconfigText(io);
        defer if (text) |t| repo.allocator().free(t);
        return parse(gpa, repo.configuration(), text);
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
        const key = std.mem.print(&buf, "{s}.{s}", .{ entry.section, entry.name }) catch return false;
        for (file_keys) |safe| {
            if (std.ascii.eqlIgnoreCase(safe, key)) return true;
        }
        return false;
    }

    /// The value git-lfs reads from `entry`, or `null` where it reads none: a
    /// name written with no `=` is dropped from the `git config -l -z` it
    /// reads (`configValue`), and from `.lfsconfig` it takes only the
    /// keys the file may set.
    fn readValue(entry: config_mod.Entry, from_file: bool) ?[]const u8 {
        if (from_file and !fileMayHold(entry)) return null;
        return entry.value;
    }

    fn lastValue(s: *const Settings, full_name: []const u8) ?[]const u8 {
        if (configValue(s.config, full_name)) |value| return value;
        const file = if (s.file) |*f| f else return null;
        const split = config_mod.splitFullName(full_name) orelse return null;
        var found: ?[]const u8 = null;
        for (file.entries.items) |entry| {
            if (!entry.matches(split.section, split.subsection, split.name)) continue;
            found = readValue(entry, true) orelse continue;
        }
        return found;
    }

    /// The value of `full_name`, unquoted into `a`: the configuration's
    /// last, else `.lfsconfig`'s.
    pub fn get(s: *const Settings, a: Allocator, full_name: []const u8) Allocator.Error!?[]const u8 {
        const raw = s.lastValue(full_name) orelse return null;
        const value = try unquoteValue(a, raw);
        return value;
    }

    /// The value of `full_name` as git-lfs's `config.Bool` reads it
    /// (`configBool`): `fallback` when it is not set or is empty.
    pub fn getBool(s: *const Settings, full_name: []const u8, fallback: bool) bool {
        return configBool(s.lastValue(full_name) orelse "", fallback);
    }

    /// The value of `full_name` as git-lfs's `config.Int` reads it
    /// (`configInt`): `fallback` when it is not set or is not one.
    pub fn getInt(s: *const Settings, full_name: []const u8, fallback: i64) i64 {
        return configInt(s.lastValue(full_name) orelse "", fallback);
    }

    /// git-lfs's URL-scoped lookup: `<section>.<url>.<key>` for the
    /// configured URL that matches `url` best, else `<section>.<key>`. Every
    /// value of the winning key, oldest first, unquoted into `a`. A
    /// `section` with a dot in it, as `lfs.transfer`, is a section and the
    /// start of the subsection the URL follows.
    pub fn urlGetAll(s: *const Settings, a: Allocator, full_section: []const u8, url: []const u8, key: []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const dot = std.mem.findScalar(u8, full_section, '.');
        const section = full_section[0 .. dot orelse full_section.len];
        const prefix: ?[]const u8 = if (dot) |d| full_section[d + 1 ..] else null;
        const sources = [_]?*const Config{ s.config, if (s.file) |*f| f else null };
        for (sources, 0..) |maybe, source_index| {
            const config = maybe orelse continue;
            const best = bestUrlMatch(config, section, prefix, url, key, source_index == 1);
            if (best) |subsection| {
                for (config.entries.items) |entry| {
                    if (!entry.matches(section, subsection, key)) continue;
                    const value = readValue(entry, source_index == 1) orelse continue;
                    try out.append(a, try unquoteValue(a, value));
                }
                return out.items;
            }
        }
        for (sources, 0..) |maybe, source_index| {
            const config = maybe orelse continue;
            for (config.entries.items) |entry| {
                if (!entry.matches(section, prefix, key)) continue;
                const value = readValue(entry, source_index == 1) orelse continue;
                try out.append(a, try unquoteValue(a, value));
            }
            if (out.items.len != 0) return out.items;
        }
        return out.items;
    }

    /// The last value `urlGetAll` would give, or `null`.
    pub fn urlGet(s: *const Settings, a: Allocator, section: []const u8, url: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
        const values = try s.urlGetAll(a, section, url, key);
        return if (values.len == 0) null else values[values.len - 1];
    }
};

/// Errors from finding `.lfsconfig`.
pub const LfsconfigError = repo_mod.Repository.LfsconfigError;

fn unquoteValue(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const copy = try a.dupe(u8, raw);
    return copy;
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
        const sep = std.mem.find(u8, text, "://") orelse return null;
        if (sep == 0) return null;
        for (text[0..sep]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
        }
        var parts: UrlParts = .{ .scheme = text[0..sep], .authority = "", .host = "", .path = "" };
        const rest = text[sep + 3 ..];
        const path_at = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
        var authority = rest[0..path_at];
        if (std.mem.findScalarLast(u8, authority, '@')) |at| {
            const userinfo = authority[0..at];
            authority = authority[at + 1 ..];
            if (std.mem.findScalar(u8, userinfo, ':')) |colon| {
                parts.user = userinfo[0..colon];
                parts.password = userinfo[colon + 1 ..];
            } else parts.user = userinfo;
        }
        parts.authority = authority;
        if (authority.len != 0 and authority[0] == '[') {
            const close = std.mem.findScalar(u8, authority, ']') orelse return null;
            parts.host = authority[1..close];
            const after = authority[close + 1 ..];
            if (after.len > 1 and after[0] == ':') parts.port = after[1..];
        } else if (std.mem.findScalarLast(u8, authority, ':')) |colon| {
            parts.host = authority[0..colon];
            if (colon + 1 < authority.len) parts.port = authority[colon + 1 ..];
        } else parts.host = authority;
        const tail = rest[path_at..];
        const end = std.mem.findAny(u8, tail, "?#") orelse tail.len;
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
        if (Settings.readValue(entry, from_file) == null) continue;
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

test "a setting is read as git-lfs reads it: its config.Bool and config.Int, and a name with no value not there" {
    var config = try config_mod.Config.parseText(std.testing.allocator,
        \\[lfs]
        \\    on = t
        \\    word = sometimes
        \\    empty =
        \\    count = 1_000
        \\    bare = 7
        \\    bare
    , .local);
    defer config.deinit();
    try std.testing.expect(configBool(configValue(&config, "lfs.on").?, false));
    try std.testing.expect(!configBool(configValue(&config, "lfs.word").?, true));
    try std.testing.expect(configBool(configValue(&config, "lfs.empty").?, true));
    try std.testing.expect(!configBool("2", true));
    try std.testing.expectEqual(@as(i64, 8), configInt(configValue(&config, "lfs.count").?, 8));
    try std.testing.expectEqual(@as(i64, 8), configInt("1k", 8));
    try std.testing.expectEqual(@as(i64, -3), configInt("-3", 8));
    try std.testing.expectEqualStrings("7", configValue(&config, "lfs.bare").?);
}
