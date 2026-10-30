//! Dumb HTTP against git 2.56 (designs/relic.md §13): git's backend,
//! asked with no query string, answers as a static host would, `info/refs`
//! as the plain listing and every file as itself. Each case runs git's own
//! dumb client (`GIT_SMART_HTTP=0`) and relic's against the same server,
//! and compares what each made.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const object = @import("../object/object.zig");
const clone_mod = @import("../transport/clone.zig");
const transport = @import("../transport/transport.zig");
const fetch_mod = @import("../transport/fetch.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");

const who: object.Signature = .{ .name = "T", .email = "t@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// A server root holding repositories, and git's environment.
const Served = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    root: testing.TmpDir,
    root_path: []const u8,
    out: testing.TmpDir,
    out_path: []const u8,
    env: Environ.Map,
    server: *testremote.HttpServer,

    fn init(gpa: Allocator, io: Io, options: testremote.HttpServer.HttpOptions) !*Served {
        try testgit.requireGitVersion(gpa, io, 2, 56);
        const s = try gpa.create(Served);
        errdefer gpa.destroy(s);
        s.gpa = gpa;
        s.arena_state = .init(gpa);
        errdefer s.arena_state.deinit();
        const a = s.arena_state.allocator();
        s.root = testing.tmpDir(.{ .iterate = true });
        errdefer s.root.cleanup();
        s.root_path = try testremote.absolutePath(a, io, s.root.dir);
        s.out = testing.tmpDir(.{ .iterate = true });
        errdefer s.out.cleanup();
        s.out_path = try testremote.absolutePath(a, io, s.out.dir);
        s.env = try testremote.environ(gpa);
        errdefer s.env.deinit();
        try s.env.put("GIT_SMART_HTTP", "0");
        var opts = options;
        opts.static = true;
        s.server = try testremote.HttpServer.start(gpa, io, s.root.dir, opts);
        return s;
    }

    fn deinit(s: *Served) void {
        const gpa = s.gpa;
        s.server.stop();
        s.env.deinit();
        s.out.cleanup();
        s.root.cleanup();
        s.arena_state.deinit();
        gpa.destroy(s);
    }

    fn arena(s: *Served) Allocator {
        return s.arena_state.allocator();
    }

    /// git, in the output directory, under the dumb client's environment.
    fn git(s: *Served, io: Io, args: []const []const u8) ![]u8 {
        return testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, args, "", true);
    }

    /// The same, `""` when git fails.
    fn gitOrEmpty(s: *Served, io: Io, args: []const []const u8) ![]u8 {
        return testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, args, "", false) catch |err| switch (err) {
            error.GitFailed => "",
            else => |e| return e,
        };
    }

    /// `<root>/<name>`, a bare copy of `source`.
    fn publish(s: *Served, io: Io, source: *testgit.Repo, name: []const u8) ![]const u8 {
        const path = try std.Io.Dir.path.join(s.arena(), &.{ s.root_path, name });
        try source.exec(io, &.{ "clone", "-q", "--bare", ".", path });
        return path;
    }

    fn url(s: *Served, name: []const u8) ![]const u8 {
        return s.server.url(s.arena(), name);
    }

    /// An empty directory under the output, and its path.
    fn target(s: *Served, io: Io, name: []const u8) !struct { dir: Io.Dir, path: []const u8 } {
        try s.out.dir.createDirPath(io, name);
        return .{ .dir = try s.out.dir.openDir(io, name, .{ .iterate = true }), .path = try std.Io.Dir.path.join(s.arena(), &.{ s.out_path, name }) };
    }
};

/// What git and relic made are the same clone: refs, `HEAD`, remote and
/// branch configuration, the index and the work tree; and relic's is
/// whole.
fn expectSameClone(s: *Served, io: Io, theirs: []const u8, ours: []const u8, bare: bool) !void {
    var queries: std.ArrayList([]const []const u8) = .empty;
    try queries.appendSlice(s.arena(), &.{
        &.{ "for-each-ref", "--format=%(refname) %(objectname) %(*objectname) %(symref)" },
        &.{ "symbolic-ref", "-q", "HEAD" },
        &.{ "rev-parse", "HEAD" },
        &.{ "config", "--local", "--get-regexp", "^(remote|branch)\\." },
        &.{ "rev-parse", "--show-object-format" },
    });
    if (!bare) try queries.appendSlice(s.arena(), &.{ &.{ "ls-files", "-s" }, &.{ "status", "--porcelain" } });
    for (queries.items) |q| {
        const a = try s.gitOrEmpty(io, try std.mem.concat(s.arena(), []const u8, &.{ &.{ "-C", theirs }, q }));
        const b = try s.gitOrEmpty(io, try std.mem.concat(s.arena(), []const u8, &.{ &.{ "-C", ours }, q }));
        try testing.expectEqualStrings(a, b);
    }
    _ = try s.git(io, &.{ "-C", ours, "fsck", "--strict", "--no-dangling", "--no-progress" });
}

/// git's dumb clone and relic's of `name`, compared.
fn cloneBoth(s: *Served, io: Io, name: []const u8, tag: []const u8, git_args: []const []const u8, options: clone_mod.Options) !struct { theirs: []const u8, ours: []const u8 } {
    const arena = s.arena();
    const remote = try s.url(name);
    const theirs = try std.Io.Dir.path.join(arena, &.{ s.out_path, try std.mem.concat(arena, u8, &.{ "git-", tag }) });
    _ = try s.git(io, try std.mem.concat(arena, []const u8, &.{ &.{ "clone", "-q" }, git_args, &.{ remote, theirs } }));
    const made = try s.target(io, try std.mem.concat(arena, u8, &.{ "relic-", tag }));
    var dir = made.dir;
    defer dir.close(io);
    var opts = options;
    opts.who = who;
    opts.programs = .{ .environ = &s.env };
    var repo = try clone_mod.clone(s.gpa, io, remote, dir, opts);
    repo.deinit(io);
    return .{ .theirs = theirs, .ours = made.path };
}

test "dumb HTTP: a clone of a repository all loose, all packed and mixed is the clone git's dumb client makes, and the refs are git's ls-remote" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 4);
    defer source.deinit();

    // All loose: a bare copy with its objects unpacked.
    const loose = try s.publish(io, &source, "loose.git");
    {
        const packs = try std.Io.Dir.path.join(s.arena(), &.{ loose, "objects", "pack" });
        _ = try s.git(io, &.{ "-C", loose, "repack", "-a", "-d", "-q" });
        const listed = try s.git(io, &.{ "-C", loose, "count-objects", "-v" });
        _ = listed;
        // Unpack every pack back into loose objects.
        var dir = try Io.Dir.cwd().openDir(io, packs, .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".pack")) try names.append(s.arena(), try s.arena().dupe(u8, entry.name));
        for (names.items) |name| {
            const pack_path = try std.Io.Dir.path.join(s.arena(), &.{ packs, name });
            const bytes = try Io.Dir.cwd().readFileAlloc(io, pack_path, s.arena(), .unlimited);
            const base = name[0 .. name.len - ".pack".len];
            for ([_][]const u8{ ".pack", ".idx", ".rev" }) |ext| dir.deleteFile(io, try std.mem.concat(s.arena(), u8, &.{ base, ext })) catch |err| switch (err) {
                // Not every git writes a reverse index.
                error.FileNotFound => {},
                else => |e| return e,
            };
            _ = try testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, &.{ "-C", loose, "unpack-objects", "-q" }, bytes, true);
        }
    }
    // All packed, the server's info files written as a static host needs.
    const packed_path = try s.publish(io, &source, "packed.git");
    _ = try s.git(io, &.{ "-C", packed_path, "repack", "-a", "-d", "-q" });
    _ = try s.git(io, &.{ "-C", packed_path, "update-server-info" });
    // Mixed: packed, then two commits more, loose.
    const mixed = try s.publish(io, &source, "mixed.git");
    _ = try s.git(io, &.{ "-C", mixed, "repack", "-a", "-d", "-q" });
    try testremote.addCommits(gpa, io, &source, 10, 2);
    try source.exec(io, &.{ "push", "-q", mixed, "HEAD:main" });

    for ([_][]const u8{ "loose.git", "packed.git", "mixed.git" }) |name| {
        const made = try cloneBoth(s, io, name, name, &.{}, .{ .who = who });
        try expectSameClone(s, io, made.theirs, made.ours, false);

        // The refs, as git's ls-remote lists them.
        const theirs = try s.git(io, &.{ "ls-remote", try s.url(name) });
        var session = try transport.Session.open(gpa, io, try s.url(name), .{ .service = .upload_pack }, .{ .who = who, .programs = .{ .environ = &s.env } });
        defer session.deinit(io);
        var refs = try session.listRefs(gpa, io, &.{});
        defer refs.deinit();
        var ours: std.ArrayList(u8) = .empty;
        for (refs.refs) |ref| {
            var hex: [64]u8 = undefined;
            try ours.print(s.arena(), "{s}\t{s}\n", .{ ref.oid.hex(&hex), ref.name });
        }
        try testing.expectEqualStrings(theirs, ours.items);
    }
}

/// relic's listing of `remote`, as git's ls-remote prints one.
fn lsRemote(s: *Served, io: Io, remote: []const u8) ![]const u8 {
    var session = try transport.Session.open(s.gpa, io, remote, .{ .service = .upload_pack }, .{ .who = who, .programs = .{ .environ = &s.env } });
    defer session.deinit(io);
    var refs = try session.listRefs(s.gpa, io, &.{});
    defer refs.deinit();
    var out: std.ArrayList(u8) = .empty;
    for (refs.refs) |ref| {
        var hex: [64]u8 = undefined;
        try out.print(s.arena(), "{s}\t{s}\n", .{ ref.oid.hex(&hex), ref.name });
    }
    return out.items;
}

test "dumb HTTP: a SHA-256 repository, a detached HEAD and a HEAD naming no listed ref clone and list as git's dumb client has them" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();

    var sha256 = try testgit.Repo.init(gpa, io, &.{"--object-format=sha256"});
    defer sha256.deinit();
    try testremote.addCommits(gpa, io, &sha256, 0, 3);
    try sha256.exec(io, &.{ "tag", "-a", "v1", "-m", "one" });
    _ = try s.publish(io, &sha256, "sha256.git");

    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    const detached = try s.publish(io, &source, "detached.git");
    const side = try s.git(io, &.{ "-C", detached, "rev-parse", "side" });
    _ = try s.git(io, &.{ "-C", detached, "update-ref", "--no-deref", "HEAD", std.mem.trimEnd(u8, side, "\n") });
    const nowhere = try s.publish(io, &source, "nowhere.git");
    _ = try s.git(io, &.{ "-C", nowhere, "symbolic-ref", "HEAD", "refs/heads/gone" });

    for ([_][]const u8{ "sha256.git", "detached.git", "nowhere.git" }) |name| {
        const made = try cloneBoth(s, io, name, name, &.{}, .{ .who = who });
        try expectSameClone(s, io, made.theirs, made.ours, false);
        const remote = try s.url(name);
        try testing.expectEqualStrings(try s.git(io, &.{ "ls-remote", remote }), try lsRemote(s, io, remote));
    }
}

test "dumb HTTP: objects borrowed through http-alternates (/, ../ and a URL) and alternates come as git's dumb client takes them, and only under http.followRedirects=true" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    const base = try s.publish(io, &source, "base.git");
    _ = try s.git(io, &.{ "-C", base, "repack", "-a", "-d", "-q" });
    try testremote.addCommits(gpa, io, &source, 10, 1);
    try source.exec(io, &.{ "push", "-q", base, "HEAD:main" });

    const port_url = try s.url("base.git/objects");
    const Case = struct { name: []const u8, file: []const u8, text: []const u8 };
    const cases = [_]Case{
        .{ .name = "slash.git", .file = "http-alternates", .text = "/base.git/objects\n" },
        .{ .name = "dots.git", .file = "http-alternates", .text = "../../base.git/objects\n" },
        .{ .name = "url.git", .file = "http-alternates", .text = try std.mem.concat(s.arena(), u8, &.{ port_url, "\n" }) },
        .{ .name = "plain.git", .file = "alternates", .text = "../../base.git/objects\n" },
    };
    var config = try config_mod.Config.parseText(gpa, "[http]\n\tfollowRedirects = true\n", .command);
    defer config.deinit();
    for (cases) |case| {
        const borrower = try std.Io.Dir.path.join(s.arena(), &.{ s.root_path, case.name });
        _ = try s.git(io, &.{ "clone", "-q", "--bare", "--shared", base, borrower });
        const info = try std.Io.Dir.path.join(s.arena(), &.{ borrower, "objects", "info" });
        var dir = try Io.Dir.cwd().openDir(io, info, .{});
        defer dir.close(io);
        // Relative to the objects directory, git's own reads it as well.
        try dir.writeFile(io, .{ .sub_path = "alternates", .data = "../../base.git/objects\n" });
        try dir.writeFile(io, .{ .sub_path = case.file, .data = case.text });

        const made = try cloneBoth(s, io, case.name, case.name, &.{ "-c", "http.followRedirects=true" }, .{ .who = who, .config = &config });
        try expectSameClone(s, io, made.theirs, made.ours, false);
    }

    // Under git's default, `initial`, neither takes an alternate.
    const refused = try std.Io.Dir.path.join(s.arena(), &.{ s.out_path, "git-refused" });
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(s.arena(), io, s.out.dir, &s.env, &.{ "clone", "-q", try s.url("slash.git"), refused }, "", false));
    const made = try s.target(io, "relic-refused");
    var dir = made.dir;
    defer dir.close(io);
    try testing.expectError(error.ObjectMissing, clone_mod.clone(gpa, io, try s.url("slash.git"), dir, .{ .who = who, .programs = .{ .environ = &s.env } }));
}

test "dumb HTTP: a fetch takes only what is missing, as the server's log shows, and its refs are git's" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{});
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    const served = try s.publish(io, &source, "repo.git");
    const made = try cloneBoth(s, io, "repo.git", "repo", &.{}, .{ .who = who });
    const before = try s.git(io, &.{ "-C", served, "rev-parse", "main" });

    try testremote.addCommits(gpa, io, &source, 10, 2);
    try source.exec(io, &.{ "push", "-q", served, "HEAD:main" });
    _ = try s.git(io, &.{ "-C", made.theirs, "fetch", "-q", "origin" });
    const seen_before = (try s.server.requests(s.arena())).len;
    {
        var dir = try Io.Dir.cwd().openDir(io, made.ours, .{});
        defer dir.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = who, .programs = .{ .environ = &s.env } });
        fetched.deinit();
    }
    try expectSameClone(s, io, made.theirs, made.ours, false);

    // Each object the new commits brought, asked for once, and no other.
    const new = try s.git(io, &.{ "-C", served, "rev-list", "--objects", "--no-object-names", "main", try std.mem.concat(s.arena(), u8, &.{ "^", std.mem.trimEnd(u8, before, "\n") }) });
    var wanted: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, new, '\n');
    while (lines.next()) |hex| try wanted.append(s.arena(), try std.mem.concat(s.arena(), u8, &.{ "GET /repo.git/objects/", hex[0..2], "/", hex[2..], " -" }));
    std.mem.sort([]const u8, wanted.items, {}, lessThan);
    var asked: std.ArrayList([]const u8) = .empty;
    var log = std.mem.tokenizeScalar(u8, (try s.server.requests(s.arena()))[seen_before..], '\n');
    while (log.next()) |line| if (std.mem.find(u8, line, "/objects/") != null) try asked.append(s.arena(), line);
    std.mem.sort([]const u8, asked.items, {}, lessThan);
    try testing.expectEqual(wanted.items.len, asked.items.len);
    for (wanted.items, asked.items) |w, a| try testing.expectEqualStrings(w, a);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `<root>/<name>`, a bare copy of `source` with every object loose.
fn publishLoose(s: *Served, io: Io, source: *testgit.Repo, name: []const u8) ![]const u8 {
    const path = try std.Io.Dir.path.join(s.arena(), &.{ s.root_path, name });
    _ = try s.git(io, &.{ "init", "-q", "--bare", "--initial-branch=main", path });
    _ = try s.git(io, &.{ "-C", path, "config", "receive.unpackLimit", "100000" });
    try source.exec(io, &.{ "push", "-q", "--mirror", path });
    return path;
}

/// git's dumb clone of `remote` fails, as relic's does with `expected`.
fn expectBothRefuse(s: *Served, io: Io, remote: []const u8, tag: []const u8, git_args: []const []const u8, options: clone_mod.Options, expected: anyerror) !void {
    const arena = s.arena();
    const theirs = try std.Io.Dir.path.join(arena, &.{ s.out_path, try std.mem.concat(arena, u8, &.{ "git-", tag }) });
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(arena, io, s.out.dir, &s.env, try std.mem.concat(arena, []const u8, &.{ &.{ "clone", "-q" }, git_args, &.{ remote, theirs } }), "", false));
    const made = try s.target(io, try std.mem.concat(arena, u8, &.{ "relic-", tag }));
    var dir = made.dir;
    defer dir.close(io);
    var opts = options;
    opts.programs = .{ .environ = &s.env };
    try testing.expectError(expected, clone_mod.clone(s.gpa, io, remote, dir, opts));
}

test "dumb HTTP: a corrupt or missing object, a depth or a date, a push and a redirect after the first request are refused as git refuses them, and an exclusion besides; a filter fetches everything, as git's" {
    const gpa = testing.allocator;
    const io = testing.io;
    const s = try Served.init(gpa, io, .{ .files = true, .redirect_objects = true });
    defer s.deinit();
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    const blob_out = try source.run(io, &.{ "rev-parse", "HEAD:src/a.txt" });
    defer gpa.free(blob_out);
    const other_out = try source.run(io, &.{ "rev-parse", "HEAD:docs/b.md" });
    defer gpa.free(other_out);
    const blob = std.mem.trimEnd(u8, blob_out, "\n");
    const other = std.mem.trimEnd(u8, other_out, "\n");
    const fan = try std.mem.concat(s.arena(), u8, &.{ "objects/", blob[0..2], "/", blob[2..] });

    // A loose file that inflates to another object.
    const corrupt = try publishLoose(s, io, &source, "corrupt.git");
    {
        var dir = try Io.Dir.cwd().openDir(io, corrupt, .{});
        defer dir.close(io);
        const misnamed = try dir.readFileAlloc(io, try std.mem.concat(s.arena(), u8, &.{ "objects/", other[0..2], "/", other[2..] }), s.arena(), .unlimited);
        try dir.deleteFile(io, fan);
        try dir.writeFile(io, .{ .sub_path = fan, .data = misnamed });
    }
    // An object nowhere.
    const missing = try publishLoose(s, io, &source, "missing.git");
    {
        var dir = try Io.Dir.cwd().openDir(io, missing, .{});
        defer dir.close(io);
        try dir.deleteFile(io, fan);
    }
    const whole = try publishLoose(s, io, &source, "whole.git");
    _ = whole;

    // Followed only where every redirect is.
    try expectBothRefuse(s, io, try s.url("whole.git"), "initial", &.{}, .{ .who = who }, error.HttpStatus);
    var follow = try config_mod.Config.parseText(gpa, "[http]\n\tfollowRedirects = true\n", .command);
    defer follow.deinit();
    const git_follow = [_][]const u8{ "-c", "http.followRedirects=true" };
    {
        const made = try cloneBoth(s, io, "whole.git", "followed", &git_follow, .{ .who = who, .config = &follow });
        try expectSameClone(s, io, made.theirs, made.ours, false);
    }
    try expectBothRefuse(s, io, try s.url("corrupt.git"), "corrupt", &git_follow, .{ .who = who, .config = &follow }, error.CorruptObject);
    try expectBothRefuse(s, io, try s.url("missing.git"), "missing", &git_follow, .{ .who = who, .config = &follow }, error.ObjectMissing);
    try expectBothRefuse(s, io, try s.url("whole.git"), "depth", &(git_follow ++ [_][]const u8{ "--depth", "1" }), .{ .who = who, .config = &follow, .depth = 1 }, error.DumbHttpShallow);
    try expectBothRefuse(s, io, try s.url("whole.git"), "since", &(git_follow ++ [_][]const u8{"--shallow-since=2000-01-01"}), .{ .who = who, .config = &follow, .shallow_since = .fromNanoseconds(946_684_800 * std.time.ns_per_s) }, error.DumbHttpShallow);

    // An exclusion, which git's `fetch_dumb` drops without a word
    // (remote-curl.c:1175), handing back a whole clone: relic refuses it,
    // a deliberate difference.
    {
        const theirs = try std.Io.Dir.path.join(s.arena(), &.{ s.out_path, "git-exclude" });
        _ = try s.git(io, &(git_follow ++ [_][]const u8{ "clone", "-q", "--shallow-exclude=side", try s.url("whole.git"), theirs }));
        try testing.expectEqualStrings("false\n", try s.git(io, &.{ "-C", theirs, "rev-parse", "--is-shallow-repository" }));
        const made = try s.target(io, "relic-exclude");
        var dir = made.dir;
        defer dir.close(io);
        try testing.expectError(error.DumbHttpShallow, clone_mod.clone(gpa, io, try s.url("whole.git"), dir, .{ .who = who, .config = &follow, .shallow_exclude = &.{"side"}, .programs = .{ .environ = &s.env } }));
    }

    // A filter is never read: everything comes, and what each records of
    // it is git's.
    {
        const made = try cloneBoth(s, io, "whole.git", "filter", &(git_follow ++ [_][]const u8{"--filter=blob:none"}), .{ .who = who, .config = &follow, .filter = "blob:none" });
        try expectSameClone(s, io, made.theirs, made.ours, false);
    }

    // A push goes nowhere: git's needs WebDAV.
    try testing.expectError(error.DumbHttpPushUnsupported, transport.Session.open(gpa, io, try s.url("whole.git"), .{ .service = .receive_pack }, .{ .who = who, .programs = .{ .environ = &s.env } }));
}
