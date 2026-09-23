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

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const refspec = @import("refspec.zig");

const Config = config_mod.Config;
const Refspec = refspec.Refspec;

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
    pub fn get(gpa: Allocator, config: *const Config, name: []const u8) Error!Remote {
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

        const url_key = try std.fmt.allocPrint(arena, "remote.{s}.url", .{name});
        const configured = try valuesOf(arena, config, url_key);
        if (configured.len == 0) {
            remote.urls = try arena.dupe([]const u8, &.{try rewrite(arena, config, name, .fetch) orelse try arena.dupe(u8, name)});
            remote.push_urls = try pushUrlsFor(arena, config, &.{name});
            return remote;
        }

        remote.name = try arena.dupe(u8, name);
        const key = struct {
            fn of(a: Allocator, remote_name: []const u8, comptime field: []const u8) Allocator.Error![]u8 {
                return std.fmt.allocPrint(a, "remote.{s}." ++ field, .{remote_name});
            }
        }.of;

        var urls: std.ArrayList([]const u8) = .empty;
        for (configured) |raw| try urls.append(arena, try rewrite(arena, config, raw, .fetch) orelse raw);
        remote.urls = urls.items;

        const pushurls = try valuesOf(arena, config, try key(arena, name, "pushurl"));
        if (pushurls.len != 0) {
            var rewritten: std.ArrayList([]const u8) = .empty;
            for (pushurls) |raw| try rewritten.append(arena, try rewrite(arena, config, raw, .fetch) orelse raw);
            remote.push_urls = rewritten.items;
        } else {
            remote.push_urls = try pushUrlsFor(arena, config, configured);
        }

        remote.fetch = try refspecsOf(arena, config, try key(arena, name, "fetch"), .fetch, &remote.invalid);
        remote.push = try refspecsOf(arena, config, try key(arena, name, "push"), .push, &remote.invalid);

        if (try valueOf(arena, config, try key(arena, name, "tagopt"))) |text| {
            if (std.mem.eql(u8, text, "--tags")) remote.tags = .all;
            if (std.mem.eql(u8, text, "--no-tags")) remote.tags = .none;
        }
        remote.prune = boolOf(config, try key(arena, name, "prune")) orelse boolOf(config, "fetch.prune");
        remote.prune_tags = boolOf(config, try key(arena, name, "prunetags")) orelse boolOf(config, "fetch.prunetags");
        remote.upload_pack = try valueOf(arena, config, try key(arena, name, "uploadpack"));
        remote.receive_pack = try valueOf(arena, config, try key(arena, name, "receivepack"));
        remote.mirror = boolOf(config, try key(arena, name, "mirror")) orelse false;
        return remote;
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
pub fn rewrite(gpa: Allocator, config: *const Config, url: []const u8, which: Rewrite) Error!?[]u8 {
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
        const raw = entry.value orelse continue;
        const prefix = unquote(gpa, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedValue,
        };
        if (prefix.len > best_len and std.mem.startsWith(u8, url, prefix)) {
            if (best_prefix.len != 0) gpa.free(best_prefix);
            best_prefix = prefix;
            best_len = prefix.len;
            best_base = entry.subsection;
        } else gpa.free(prefix);
    }
    const base = best_base orelse return null;
    return try std.mem.concat(gpa, u8, &.{ base, url[best_len..] });
}

/// A branch's upstream settings.
///
/// Every slice is owned by the arena.
pub const Branch = struct {
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
    pub fn get(gpa: Allocator, config: *const Config, name: []const u8) Error!Branch {
        var branch: Branch = .{ .arena = .init(gpa), .name = undefined };
        errdefer branch.arena.deinit();
        const arena = branch.arena.allocator();
        branch.name = try arena.dupe(u8, name);
        branch.remote = try valueOf(arena, config, try std.fmt.allocPrint(arena, "branch.{s}.remote", .{name}));
        branch.push_remote = try valueOf(arena, config, try std.fmt.allocPrint(arena, "branch.{s}.pushremote", .{name}));
        branch.merge = try valuesOf(arena, config, try std.fmt.allocPrint(arena, "branch.{s}.merge", .{name}));
        return branch;
    }

    /// The remote a fetch on this branch uses: `branch.<name>.remote`, else
    /// `origin`.
    pub fn fetchRemote(branch: *const Branch) []const u8 {
        return branch.remote orelse "origin";
    }

    /// The remote a push from this branch uses: `branch.<name>.pushRemote`,
    /// else `remote.pushDefault`, else `branch.<name>.remote`, else
    /// `origin`. `config` must be the one the branch was read from; the
    /// result borrows it or the branch.
    pub fn pushRemote(branch: *const Branch, config: *const Config) []const u8 {
        if (branch.push_remote) |name| return name;
        if (config.get("remote.pushdefault")) |name| {
            if (name.len != 0) return name;
        }
        return branch.remote orelse "origin";
    }
};

fn unquote(gpa: Allocator, raw: []const u8) (Allocator.Error || config_mod.ParseError)![]u8 {
    return config_mod.unquote(gpa, raw);
}

fn valueOf(arena: Allocator, config: *const Config, key: []const u8) Error!?[]const u8 {
    const raw = config.get(key) orelse return null;
    return unquote(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    };
}

/// Every value of a multi-valued key, with git's rule that an empty value
/// clears the ones before it.
fn valuesOf(arena: Allocator, config: *const Config, key: []const u8) Error![]const []const u8 {
    const raw = try config.all(key);
    defer config.gpa.free(raw);
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |value| {
        const text = unquote(arena, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedValue,
        };
        try out.append(arena, text);
    }
    return out.items;
}

fn refspecsOf(
    arena: Allocator,
    config: *const Config,
    key: []const u8,
    direction: refspec.Direction,
    invalid: *?[]const u8,
) Error![]const Refspec {
    const values = try valuesOf(arena, config, key);
    var out: std.ArrayList(Refspec) = .empty;
    for (values) |text| {
        const spec = Refspec.parse(text, direction) catch {
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
const testgit = @import("testgit.zig");

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

    var remote = try Remote.get(gpa, &config, "origin");
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

test "a name with no remote behind it is a URL" {
    const gpa = testing.allocator;
    var config = try Config.parseText(gpa,
        \\[url "https://mirror.example.com/"]
        \\    insteadOf = gh:
        \\
    , .local);
    defer config.deinit();
    var remote = try Remote.get(gpa, &config, "gh:org/repo");
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
    try testing.expectError(error.InvalidRefspec, Remote.get(gpa, &config, "bad"));
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
    try testing.expectEqualStrings("upstream", main.fetchRemote());
    try testing.expectEqualStrings("mine", main.pushRemote(&config));
    try testing.expectEqualStrings("refs/heads/main", main.merge[0]);
    var topic = try Branch.get(gpa, &config, "topic");
    defer topic.deinit();
    try testing.expectEqualStrings("fork", topic.pushRemote(&config));
    var none = try Branch.get(gpa, &config, "none");
    defer none.deinit();
    try testing.expectEqualStrings("origin", none.fetchRemote());
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
        var remote = try Remote.get(gpa, &config, name);
        defer remote.deinit();
        const fetch_url = try repo.line(io, &.{ "ls-remote", "--get-url", name });
        defer gpa.free(fetch_url);
        try testing.expectEqualStrings(fetch_url, remote.urls[0]);
        const push_url = try repo.line(io, &.{ "remote", "get-url", "--push", name });
        defer gpa.free(push_url);
        try testing.expectEqualStrings(push_url, remote.push_urls[0]);
    }
}
