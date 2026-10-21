//! Remotes, as a repository's configuration describes them.
//!
//! `[remote "<name>"]` names the URLs, the fetch and push refspecs and what
//! happens to tags; `[url "<base>"] insteadOf` rewrites a URL before any of
//! it is used; `[branch "<name>"]` says which remote a branch follows and
//! which of its refs it merges. Everything here is read from a
//! `config.Config` and nothing is written: a person's remotes are theirs.
//!
//! The rewriting order is git's `alias_all_urls`: every `pushurl` is
//! rewritten with `insteadOf`; a remote with no `pushurl` pushes to each
//! `url` rewritten with `pushInsteadOf` where one matches; and only then is
//! each `url` rewritten with `insteadOf`. Of several bases that match, the
//! one with the longest match wins.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config/config.zig");
const refspec = @import("refspec.zig");
const hash = @import("../hash/hash.zig");

const Config = config_mod.Config;
const Refspec = refspec.Refspec;

/// Errors from reading a remote's settings.
pub const Error = error{
    /// A `remote.<name>.fetch` or `.push` value git would refuse. `Remote`
    /// carries the value in `invalid`.
    InvalidRefspec,
    /// A quoted configuration value that does not unquote.
    MalformedValue,
} || Allocator.Error;

/// What a fetch does with the tags a remote has.
pub const TagMode = enum {
    /// Follow them: fetch a tag when it points at something the fetch
    /// brought. git's default.
    auto,
    /// Fetch every tag, as `remote.<name>.tagOpt = --tags` asks.
    all,
    /// Fetch none, as `--no-tags` asks.
    none,
};

/// A remote: where it is, and which refs go where.
///
/// Every slice is owned by the remote's arena.
pub const Remote = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// The configured name, or `null` for a remote named by its URL alone.
    name: ?[]const u8,
    /// Where it is fetched from, each rewritten by `insteadOf`.
    urls: []const []const u8,
    /// Where it is pushed to: `pushurl` if any, else `url` through
    /// `pushInsteadOf`, else `urls`.
    push_urls: []const []const u8,
    fetch: []const Refspec,
    push: []const Refspec,
    tags: TagMode = .auto,
    /// `remote.<name>.prune`, else `fetch.prune`; `null` when neither is set.
    prune: ?bool = null,
    /// `remote.<name>.pruneTags`, else `fetch.pruneTags`.
    prune_tags: ?bool = null,
    /// `remote.<name>.skipFetchAll`, or its older name `skipDefaultUpdate`,
    /// the last of the two deciding: left out of the remotes fetched
    /// together -- `fetch.all`, `maintenance`'s prefetch.
    skip_default_update: bool = false,
    /// `remote.<name>.negotiationRestrict`: the only refs a fetch
    /// negotiates from, when the caller names none.
    negotiation_restrict: []const []const u8 = &.{},
    /// `remote.<name>.negotiationInclude`: refs whose objects a fetch
    /// offers as haves whatever its negotiator chooses.
    negotiation_include: []const []const u8 = &.{},
    /// `remote.<name>.uploadpack`, the program a fetch asks the other side
    /// to run.
    upload_pack: ?[]const u8 = null,
    /// `remote.<name>.receivepack`, the program a push asks for.
    receive_pack: ?[]const u8 = null,
    /// `remote.<name>.mirror`.
    mirror: bool = false,
    /// The value that made `get` return `error.InvalidRefspec`, for a
    /// message.
    invalid: ?[]const u8 = null,

    /// Release everything.
    pub fn deinit(remote: *Remote) void {
        remote.arena.deinit();
        remote.* = undefined;
    }

    /// The remote configured as `name`, or — when there is no `remote.<name>`
    /// with a URL — a remote whose URL is `name` itself, which is how git
    /// reads `git fetch https://example.com/repo.git`.
    /// Its refspecs are read for `object_format`'s names, the repository's.
    pub fn get(gpa: Allocator, config: *const Config, object_format: hash.Kind, name: []const u8) Self.Error!Remote {
        var remote: Remote = .{
            .arena = .init(gpa),
            .name = null,
            .urls = &.{},
            .push_urls = &.{},
            .fetch = &.{},
            .push = &.{},
        };
        errdefer remote.arena.deinit();
        const arena = remote.arena.allocator();

        const url_key = try arena.print("remote.{s}.url", .{name});
        const configured = try resetList(arena, config, url_key);
        if (configured.len == 0) {
            remote.urls = try arena.dupe([]const u8, &.{try rewrite(arena, config, name, .fetch) orelse try arena.dupe(u8, name)});
            remote.push_urls = try pushUrlsFor(arena, config, &.{name});
            // git's `add_url_alias`: the name is the URL, and what the
            // configuration says of a remote by that name still holds.
            remote.fetch = try refspecsOf(arena, config, try arena.print("remote.{s}.fetch", .{name}), .fetch, object_format, &remote.invalid);
            remote.push = try refspecsOf(arena, config, try arena.print("remote.{s}.push", .{name}), .push, object_format, &remote.invalid);
            return remote;
        }

        remote.name = try arena.dupe(u8, name);
        const key = struct {
            fn of(comptime field: []const u8, a: Allocator, remote_name: []const u8) Allocator.Error![]u8 {
                return a.print("remote.{s}." ++ field, .{remote_name});
            }
        }.of;

        var urls: std.ArrayList([]const u8) = .empty;
        for (configured) |raw| try urls.append(arena, try rewrite(arena, config, raw, .fetch) orelse raw);
        remote.urls = urls.items;

        const pushurls = try resetList(arena, config, try key("pushurl", arena, name));
        if (pushurls.len != 0) {
            var rewritten: std.ArrayList([]const u8) = .empty;
            for (pushurls) |raw| try rewritten.append(arena, try rewrite(arena, config, raw, .fetch) orelse raw);
            remote.push_urls = rewritten.items;
        } else {
            remote.push_urls = try pushUrlsFor(arena, config, configured);
        }

        remote.fetch = try refspecsOf(arena, config, try key("fetch", arena, name), .fetch, object_format, &remote.invalid);
        remote.push = try refspecsOf(arena, config, try key("push", arena, name), .push, object_format, &remote.invalid);

        if (try valueOf(arena, config, try key("tagopt", arena, name))) |text| {
            if (std.mem.eql(u8, text, "--tags")) remote.tags = .all;
            if (std.mem.eql(u8, text, "--no-tags")) remote.tags = .none;
        }
        remote.prune = boolOf(config, try key("prune", arena, name)) orelse boolOf(config, "fetch.prune");
        remote.prune_tags = boolOf(config, try key("prunetags", arena, name)) orelse boolOf(config, "fetch.prunetags");
        {
            var it = config.iterate(&.{ try key("skipfetchall", arena, name), try key("skipdefaultupdate", arena, name) });
            while (it.next()) |entry| remote.skip_default_update = config_mod.parseBool(entry.value orelse "true") catch remote.skip_default_update;
        }
        remote.upload_pack = try valueOf(arena, config, try key("uploadpack", arena, name));
        remote.receive_pack = try valueOf(arena, config, try key("receivepack", arena, name));
        remote.mirror = boolOf(config, try key("mirror", arena, name)) orelse false;
        remote.negotiation_restrict = try resetList(arena, config, try key("negotiationrestrict", arena, name));
        remote.negotiation_include = try resetList(arena, config, try key("negotiationinclude", arena, name));
        return remote;
    }

    /// The ref here that tracks `name`, a ref on the remote: where a fetch
    /// of it lands by the remote's fetch refspecs, the first that maps it,
    /// as git's `remote_find_tracking` decides; `null` when none does or a
    /// negative refspec excludes it. The result is the caller's.
    pub fn trackingRef(remote: *const Remote, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        if (refspec.excluded(remote.fetch, name)) return null;
        for (remote.fetch) |spec| {
            if (spec.negative) continue;
            if (try spec.mapSource(gpa, name)) |tracking| return tracking;
        }
        return null;
    }

    /// The ref on the remote that `tracking`, a ref here, tracks: git's
    /// `remote_find_tracking` asked by destination, the first fetch
    /// refspec that maps to it deciding. `null` when none does, or when a
    /// negative refspec excludes what git's `query_matches_negative_refspec`
    /// finds for it: each pattern's mapping back, `tracking` itself for a
    /// matching refspec, and an exact refspec's source where that source is
    /// `tracking`, as git compares it. The result is the caller's.
    pub fn sourceOf(remote: *const Remote, gpa: Allocator, tracking: []const u8) Allocator.Error!?[]u8 {
        for (remote.fetch) |spec| {
            if (spec.negative) continue;
            const reversed: ?[]u8 = if (spec.pattern)
                try spec.mapDestination(gpa, tracking)
            else if (spec.matching or std.mem.eql(u8, spec.src, tracking))
                try gpa.dupe(u8, tracking)
            else
                null;
            const name = reversed orelse continue;
            defer gpa.free(name);
            if (refspec.excluded(remote.fetch, name)) return null;
        }
        for (remote.fetch) |spec| {
            if (spec.negative) continue;
            if (try spec.mapDestination(gpa, tracking)) |source| return source;
        }
        return null;
    }

    /// Whether `name` is a remote with a URL in `config`.
    pub fn exists(config: *const Config, name: []const u8) bool {
        for (config.entries.items) |entry| {
            if (entry.matches("remote", name, "url")) return true;
        }
        return false;
    }
};

/// Every configured remote's name, in the order the configuration first
/// mentions each. The result is the caller's; the names borrow `config`.
pub fn names(gpa: Allocator, config: *const Config) Allocator.Error![][]const u8 {
    return config.subsections(gpa, "remote");
}

fn pushUrlsFor(arena: Allocator, config: *const Config, urls: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (urls) |raw| {
        const rewritten = (try rewrite(arena, config, raw, .push)) orelse
            (try rewrite(arena, config, raw, .fetch)) orelse raw;
        try out.append(arena, rewritten);
    }
    return out.items;
}

/// Which rewrite rule applies: `insteadOf` for every use, `pushInsteadOf`
/// only for a push to a remote with no `pushurl`.
pub const Rewrite = enum { fetch, push };

/// `url` rewritten by the longest matching `url.<base>.insteadOf` (or
/// `pushInsteadOf`), or `null` when none matches. The result is `gpa`'s.
pub fn rewrite(gpa: Allocator, config: *const Config, url: []const u8, which: Rewrite) Self.Error!?[]u8 {
    const wanted = switch (which) {
        .fetch => "insteadof",
        .push => "pushinsteadof",
    };
    var best_len: usize = 0;
    var best_base: ?[]const u8 = null;
    var best_prefix: []u8 = &.{};
    defer if (best_prefix.len != 0) gpa.free(best_prefix);
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "url")) continue;
        if (entry.subsection.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, wanted)) continue;
        const prefix = try gpa.dupe(u8, entry.value orelse continue);
        if (prefix.len > best_len and std.mem.startsWith(u8, url, prefix)) {
            if (best_prefix.len != 0) gpa.free(best_prefix);
            best_prefix = prefix;
            best_len = prefix.len;
            best_base = entry.subsection;
        } else gpa.free(prefix);
    }
    const base = best_base orelse return null;
    const rewritten = try std.mem.concat(gpa, u8, &.{ base, url[best_len..] });
    return rewritten;
}

/// The fetch refspec `git remote add` and `git clone` write for the remote
/// `name`: every branch, forced, under `refs/remotes/<name>/`. The text is
/// the caller's; `Refspec.parse` reads it.
pub fn defaultFetchRefspec(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    return gpa.print("+refs/heads/*:refs/remotes/{s}/*", .{name});
}

/// A branch's upstream settings.
///
/// Every slice is owned by the arena.
pub const Branch = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// The branch's short name.
    name: []const u8,
    /// `branch.<name>.remote`.
    remote: ?[]const u8 = null,
    /// `branch.<name>.pushRemote`.
    push_remote: ?[]const u8 = null,
    /// `branch.<name>.merge`, each a ref on the remote.
    merge: []const []const u8 = &.{},

    /// Release everything.
    pub fn deinit(branch: *Branch) void {
        branch.arena.deinit();
        branch.* = undefined;
    }

    /// The settings for the branch `name`, short form.
    pub fn get(gpa: Allocator, config: *const Config, name: []const u8) Self.Error!Branch {
        var branch: Branch = .{ .arena = .init(gpa), .name = undefined };
        errdefer branch.arena.deinit();
        const arena = branch.arena.allocator();
        branch.name = try arena.dupe(u8, name);
        branch.remote = try valueOf(arena, config, try arena.print("branch.{s}.remote", .{name}));
        branch.push_remote = try valueOf(arena, config, try arena.print("branch.{s}.pushremote", .{name}));
        branch.merge = try valuesOf(arena, config, try arena.print("branch.{s}.merge", .{name}));
        return branch;
    }

    /// The remote a fetch on this branch uses, git's `remote_for_branch`:
    /// `branch.<name>.remote`, else `fallback`. `config` must be the one
    /// the branch was read from; the result borrows it or the branch.
    pub fn fetchRemote(branch: *const Branch, config: *const Config) []const u8 {
        return branch.remote orelse fallback(config);
    }

    /// The remote a push from this branch uses: `branch.<name>.pushRemote`,
    /// else `remote.pushDefault`, else `fetchRemote`. `config` must be the
    /// one the branch was read from; the result borrows it or the branch.
    pub fn pushRemote(branch: *const Branch, config: *const Config) []const u8 {
        if (branch.push_remote) |name| return name;
        if (config.get("remote.pushdefault")) |name| {
            if (name.len != 0) return name;
        }
        return branch.fetchRemote(config);
    }
};

/// The remote of a detached `HEAD`, or of a branch that names none: the
/// only remote configured when there is just one, else `origin`, as git's
/// `remote_for_branch` falls back. The name borrows `config`.
pub fn fallback(config: *const Config) []const u8 {
    var only: ?[]const u8 = null;
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "remote") or entry.subsection.len == 0) continue;
        if (only) |name| {
            if (!std.mem.eql(u8, name, entry.subsection)) return "origin";
        } else only = entry.subsection;
    }
    return only orelse "origin";
}

fn valueOf(arena: Allocator, config: *const Config, key: []const u8) Error!?[]const u8 {
    const value = config.get(key) orelse return null;
    const copy = try arena.dupe(u8, value);
    return copy;
}

/// Every value of a multi-valued key.
fn valuesOf(arena: Allocator, config: *const Config, key: []const u8) Error![]const []const u8 {
    const raw = try config.all(key);
    defer config.gpa.free(raw);
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |value| try out.append(arena, try arena.dupe(u8, value));
    return out.items;
}

/// Whether the configuration says anything of a remote `name`: git's
/// `remote_is_configured`, a `remote.<name>.*` setting of any kind.
pub fn isConfigured(config: *const Config, name: []const u8) bool {
    for (config.entries.items) |entry| {
        if (entry.has_subsection and std.ascii.eqlIgnoreCase(entry.section, "remote") and std.mem.eql(u8, entry.subsection, name)) return true;
    }
    return false;
}

/// `remote.<name>.serverOption`, as git's transport takes it when its
/// caller names none: the values after the last empty one. The slice and
/// each value are `gpa`'s; `freeList` releases them.
pub fn serverOptions(gpa: Allocator, config: *const Config, remote_name: []const u8) Allocator.Error![][]u8 {
    const name = try gpa.print("remote.{s}.serveroption", .{remote_name});
    defer gpa.free(name);
    const raw = try config.all(name);
    defer config.gpa.free(raw);
    var start: usize = 0;
    for (raw, 0..) |value, i| if (value.len == 0) {
        start = i + 1;
    };
    const out = try gpa.alloc([]u8, raw.len - start);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |value| gpa.free(value);
        gpa.free(out);
    }
    for (raw[start..]) |value| {
        out[made] = try gpa.dupe(u8, value);
        made += 1;
    }
    return out;
}

/// Release what `serverOptions` returned.
pub fn freeList(gpa: Allocator, list: [][]u8) void {
    for (list) |value| gpa.free(value);
    gpa.free(list);
}

/// Every value of a list git resets with an empty value -- a remote's
/// `url` and `pushurl` (`add_url`), and its transport options
/// (`parse_transport_option`): the values after the last empty one.
pub fn resetList(arena: Allocator, config: *const Config, key: []const u8) Error![]const []const u8 {
    const raw = try config.all(key);
    defer config.gpa.free(raw);
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |value| {
        if (value.len == 0) {
            out.clearRetainingCapacity();
        } else try out.append(arena, try arena.dupe(u8, value));
    }
    return out.items;
}

fn refspecsOf(
    arena: Allocator,
    config: *const Config,
    key: []const u8,
    direction: refspec.Direction,
    object_format: hash.Kind,
    invalid: *?[]const u8,
) Error![]const Refspec {
    const values = try valuesOf(arena, config, key);
    var out: std.ArrayList(Refspec) = .empty;
    for (values) |text| {
        const spec = Refspec.parse(text, direction, object_format) catch {
            invalid.* = text;
            return error.InvalidRefspec;
        };
        try out.append(arena, spec);
    }
    return out.items;
}

fn boolOf(config: *const Config, key: []const u8) ?bool {
    if (!config.has(key)) return null;
    return config.getBool(key, false) catch null;
}

const testing = std.testing;
const testgit = @import("../testing/git.zig");

test "a configured remote carries its URLs, refspecs and tag rule" {
    const gpa = testing.allocator;
    var config = try Config.parseText(gpa,
        \\[remote "origin"]
        \\    url = https://example.com/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    fetch = ^refs/heads/wip
        \\    push = refs/heads/main:refs/heads/main
        \\    tagOpt = --no-tags
        \\    prune = true
        \\[fetch]
        \\    pruneTags = true
        \\
    , .local);
    defer config.deinit();

    var remote = try Remote.get(gpa, &config, .sha1, "origin");
    defer remote.deinit();
    try testing.expectEqualStrings("origin", remote.name.?);
    try testing.expectEqualStrings("https://example.com/repo.git", remote.urls[0]);
    try testing.expectEqualStrings("https://example.com/repo.git", remote.push_urls[0]);
    try testing.expectEqual(@as(usize, 2), remote.fetch.len);
    try testing.expect(remote.fetch[1].negative);
    try testing.expectEqual(@as(usize, 1), remote.push.len);
    try testing.expectEqual(TagMode.none, remote.tags);
    try testing.expectEqual(@as(?bool, true), remote.prune);
    try testing.expectEqual(@as(?bool, true), remote.prune_tags);
}

test "an empty url, pushurl or transport option clears the values before it, as git's add_url and parse_transport_option" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa,
        \\[remote "origin"]
        \\    url = https://example.com/old.git
        \\    url =
        \\    url = https://example.com/repo.git
        \\    pushurl = ssh://example.com/old.git
        \\    pushurl =
        \\    negotiationRestrict = refs/heads/old
        \\    negotiationRestrict =
        \\    negotiationRestrict = refs/heads/main
        \\    serverOption = old
        \\    serverOption =
        \\    serverOption = new
        \\[branch "main"]
        \\    merge = refs/heads/main
        \\    merge =
        \\
    , .local);
    defer config.deinit();
    var remote = try Remote.get(gpa, &config, .sha1, "origin");
    defer remote.deinit();
    try std.testing.expectEqual(@as(usize, 1), remote.urls.len);
    try std.testing.expectEqualStrings("https://example.com/repo.git", remote.urls[0]);
    // No push URL left: pushes go to the URL.
    try std.testing.expectEqualStrings("https://example.com/repo.git", remote.push_urls[0]);
    try std.testing.expectEqual(@as(usize, 1), remote.negotiation_restrict.len);
    try std.testing.expectEqualStrings("refs/heads/main", remote.negotiation_restrict[0]);
    const options = try serverOptions(gpa, &config, "origin");
    defer freeList(gpa, options);
    try std.testing.expectEqual(@as(usize, 1), options.len);
    try std.testing.expectEqualStrings("new", options[0]);
}

test "a remote ref is tracked where the first fetch refspec maps it, unless excluded" {
    const gpa = testing.allocator;
    var config = try Config.parseText(gpa,
        \\[remote "origin"]
        \\    url = https://example.com/repo.git
        \\    fetch = ^refs/heads/wip
        \\    fetch = +refs/heads/main:refs/remotes/mirror/main
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\[remote "bare"]
        \\    url = https://example.com/bare.git
        \\
    , .local);
    defer config.deinit();

    var origin = try Remote.get(gpa, &config, .sha1, "origin");
    defer origin.deinit();
    const main = (try origin.trackingRef(gpa, "refs/heads/main")).?;
    defer gpa.free(main);
    try testing.expectEqualStrings("refs/remotes/mirror/main", main);
    const topic = (try origin.trackingRef(gpa, "refs/heads/topic")).?;
    defer gpa.free(topic);
    try testing.expectEqualStrings("refs/remotes/origin/topic", topic);
    try testing.expect(try origin.trackingRef(gpa, "refs/heads/wip") == null);
    try testing.expect(try origin.trackingRef(gpa, "refs/tags/v1") == null);

    var bare = try Remote.get(gpa, &config, .sha1, "bare");
    defer bare.deinit();
    try testing.expect(try bare.trackingRef(gpa, "refs/heads/main") == null);
}

test "the default fetch refspec tracks every branch under the remote's name" {
    const gpa = testing.allocator;
    const text = try defaultFetchRefspec(gpa, "origin");
    defer gpa.free(text);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", text);
    const spec = try Refspec.parse(text, .fetch, .sha1);
    const mapped = (try spec.mapSource(gpa, "refs/heads/topic/one")).?;
    defer gpa.free(mapped);
    try testing.expectEqualStrings("refs/remotes/origin/topic/one", mapped);
}

test "a name with no remote behind it is a URL" {
    const gpa = testing.allocator;
    var config = try Config.parseText(gpa,
        \\[url "https://mirror.example.com/"]
        \\    insteadOf = gh:
        \\
    , .local);
    defer config.deinit();
    var remote = try Remote.get(gpa, &config, .sha1, "gh:org/repo");
    defer remote.deinit();
    try testing.expect(remote.name == null);
    try testing.expectEqualStrings("https://mirror.example.com/org/repo", remote.urls[0]);
    try testing.expectEqual(@as(usize, 0), remote.fetch.len);
}

test "a remote with a refspec git refuses is refused by name, with the value" {
    const gpa = testing.allocator;
    var config = try Config.parseText(gpa,
        \\[remote "bad"]
        \\    url = /srv/repo
        \\    fetch = refs/heads/*:refs/remotes/bad/main
        \\
    , .local);
    defer config.deinit();
    try testing.expectError(error.InvalidRefspec, Remote.get(gpa, &config, .sha1, "bad"));
}

test "branch settings choose the fetch and push remotes in git's order" {
    const gpa = testing.allocator;
    var config = try Config.parseText(gpa,
        \\[branch "main"]
        \\    remote = upstream
        \\    merge = refs/heads/main
        \\[branch "topic"]
        \\    remote = upstream
        \\    pushRemote = fork
        \\[remote]
        \\    pushDefault = mine
        \\
    , .local);
    defer config.deinit();
    var main = try Branch.get(gpa, &config, "main");
    defer main.deinit();
    try testing.expectEqualStrings("upstream", main.fetchRemote(&config));
    try testing.expectEqualStrings("mine", main.pushRemote(&config));
    try testing.expectEqualStrings("refs/heads/main", main.merge[0]);
    var topic = try Branch.get(gpa, &config, "topic");
    defer topic.deinit();
    try testing.expectEqualStrings("fork", topic.pushRemote(&config));
    var none = try Branch.get(gpa, &config, "none");
    defer none.deinit();
    try testing.expectEqualStrings("origin", none.fetchRemote(&config));
}

test "URL rewriting agrees with git ls-remote --get-url, for fetch and for push" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const settings = [_][2][]const u8{
        .{ "url.https://long.example.com/org/.insteadOf", "ex:org/" },
        .{ "url.https://short.example.com/.insteadOf", "ex:" },
        .{ "url.ssh://push.example.com/.pushInsteadOf", "https://long.example.com/" },
        .{ "remote.a.url", "ex:org/repo" },
        .{ "remote.b.url", "ex:other/repo" },
        .{ "remote.c.url", "https://long.example.com/x" },
        .{ "remote.d.url", "https://long.example.com/y" },
        .{ "remote.d.pushurl", "ex:org/pushed" },
    };
    for (settings) |kv| try repo.exec(io, &.{ "config", "--add", kv[0], kv[1] });

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var config = try Config.openFile(gpa, io, .{ .dir = git_dir, .sub_path = "config" }, .local, .{});
    defer config.deinit();

    for ([_][]const u8{ "a", "b", "c", "d" }) |name| {
        var remote = try Remote.get(gpa, &config, .sha1, name);
        defer remote.deinit();
        const fetch_url = try repo.line(io, &.{ "ls-remote", "--get-url", name });
        defer gpa.free(fetch_url);
        try testing.expectEqualStrings(fetch_url, remote.urls[0]);
        const push_url = try repo.line(io, &.{ "remote", "get-url", "--push", name });
        defer gpa.free(push_url);
        try testing.expectEqualStrings(push_url, remote.push_urls[0]);
    }
}
