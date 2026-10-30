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
