//! Shallow history held to git's: clones cut by depth, by date and by ref,
//! fetches that deepen and unshallow, over HTTP in protocol v2 and v0 and
//! over ssh — and each repository read by the other side: git's `fsck`,
//! `rev-list` and `--is-shallow-repository` on what relic made, relic's
//! walks and fetches on what git made.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const revwalk = @import("revwalk.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const Oid = hash.Oid;
const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// A history of eight commits on `main`, a day apart, with a branch
/// `side` from the fourth, a lightweight tag on the second and an
/// annotated one on the sixth, written by `git fast-import` into
/// `<root>/repo.git`.
fn servedHistory(gpa: Allocator, io: Io, root: Io.Dir) !void {
    const root_path = try testremote.absolutePath(gpa, io, root);
    defer gpa.free(root_path);
    const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    var maker = try testgit.Repo.init(gpa, io, &.{});
    defer maker.deinit();
    try maker.exec(io, &.{ "init", "-q", "--bare", "-b", "main", bare });
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const day = 86400;
    for (1..9) |mark| {
        try stream.print(gpa, "commit refs/heads/main\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 2\n{d}\n", .{ mark, 1_600_000_000 + mark * day, mark });
        if (mark > 1) try stream.print(gpa, "from :{d}\n", .{mark - 1});
        try stream.print(gpa, "M 100644 inline file\ndata 2\n{d}\n\n", .{mark});
    }
    try stream.print(gpa, "commit refs/heads/side\nmark :20\ncommitter C <c@example.com> {d} +0000\ndata 5\nside\nfrom :4\nM 100644 inline side\ndata 5\nside\n\n", .{1_600_000_000 + 20 * day});
    try stream.appendSlice(gpa, "reset refs/tags/light\nfrom :2\n\n");
    try stream.print(gpa, "tag v6\nfrom :6\ntagger T <t@example.com> {d} +0000\ndata 3\nv6\n\n", .{1_600_000_000 + 30 * day});
    try stream.appendSlice(gpa, "done\n");
    var dir = try Io.Dir.cwd().openDir(io, bare, .{});
    defer dir.close(io);
    const out = try testremote.gitInput(gpa, io, dir, &.{ "fast-import", "--quiet", "--done" }, stream.items);
    gpa.free(out);
}

/// Run git in `dir`; its output, trimmed, is the caller's.
fn git(gpa: Allocator, io: Io, dir: Io.Dir, args: []const []const u8) ![]u8 {
    const out = try testremote.gitInput(gpa, io, dir, args, "");
    defer gpa.free(out);
    return gpa.dupe(u8, std.mem.trimEnd(u8, out, "\n"));
}

/// What two shallow repositories are compared on: the boundary byte for
/// byte, every ref, the remote's configuration, how much history each
/// walk sees — and git's own check of the one relic made.
fn expectSameShallow(gpa: Allocator, io: Io, by_git: Io.Dir, by_relic: Io.Dir) !void {
    const theirs_shallow = by_git.readFileAlloc(io, ".git/shallow", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, "(none)"),
        else => |e| return e,
    };
    defer gpa.free(theirs_shallow);
    const ours_shallow = by_relic.readFileAlloc(io, ".git/shallow", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, "(none)"),
        else => |e| return e,
    };
    defer gpa.free(ours_shallow);
    try testing.expectEqualStrings(theirs_shallow, ours_shallow);
    for ([_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname) %(symref)" },
        &.{ "config", "--get-all", "remote.origin.fetch" },
        &.{ "rev-list", "--count", "--all" },
        &.{ "rev-parse", "--is-shallow-repository" },
    }) |args| {
        const theirs = try git(gpa, io, by_git, args);
        defer gpa.free(theirs);
        const ours = try git(gpa, io, by_relic, args);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    const checked = try git(gpa, io, by_relic, &.{ "fsck", "--strict", "--no-dangling" });
    gpa.free(checked);
    // And relic's own walk sees as much history as git's.
    var repo = try repo_mod.Repository.open(gpa, io, by_relic, .{});
    defer repo.deinit(io);
    const head_text = try git(gpa, io, by_relic, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    var walk: revwalk.Walk = .init(gpa, &repo.odb);
    defer walk.deinit();
    try walk.push(try Oid.parse(repo.kind, head_text));
    const count_text = try git(gpa, io, by_relic, &.{ "rev-list", "--count", "HEAD" });
    defer gpa.free(count_text);
    try testing.expectEqual(try std.fmt.parseUnsigned(usize, count_text, 10), try walk.count(io));
}

const Twins = struct {
    tmp: testing.TmpDir,
    by_git: Io.Dir,
    by_relic: Io.Dir,
    git_path: []u8,

    fn init(gpa: Allocator, io: Io) !Twins {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "by-git");
        try tmp.dir.createDirPath(io, "by-relic");
        const base = try testremote.absolutePath(gpa, io, tmp.dir);
        defer gpa.free(base);
        return .{
            .tmp = tmp,
            .by_git = try tmp.dir.openDir(io, "by-git", .{ .iterate = true }),
            .by_relic = try tmp.dir.openDir(io, "by-relic", .{ .iterate = true }),
            .git_path = try std.fs.path.join(gpa, &.{ base, "by-git" }),
        };
    }

    fn deinit(t: *Twins, gpa: Allocator, io: Io) void {
        t.by_git.close(io);
        t.by_relic.close(io);
        gpa.free(t.git_path);
        t.tmp.cleanup();
    }
};

test "a shallow clone is the one git makes, cut by depth, by date and by ref, in v2 and in v0" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedHistory(gpa, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    const Case = struct { git_args: []const []const u8, options: clone_mod.Options };
    const day = 86400;
    const since = 1_600_000_000 + 5 * day + 1;
    var since_arg_buf: [64]u8 = undefined;
    const since_arg = try std.fmt.bufPrint(&since_arg_buf, "--shallow-since={d}", .{since});
    const cases = [_]Case{
        .{ .git_args = &.{"--depth=1"}, .options = .{ .who = test_who, .depth = 1 } },
        .{ .git_args = &.{"--depth=3"}, .options = .{ .who = test_who, .depth = 3 } },
        .{ .git_args = &.{ "--depth=2", "--no-single-branch" }, .options = .{ .who = test_who, .depth = 2, .single_branch = false } },
        .{ .git_args = &.{ "--depth=2", "--branch=side" }, .options = .{ .who = test_who, .depth = 2, .branch = "side" } },
        .{ .git_args = &.{since_arg}, .options = .{ .who = test_who, .shallow_since = since } },
        .{ .git_args = &.{"--shallow-exclude=light"}, .options = .{ .who = test_who, .shallow_exclude = &.{"light"} } },
    };
    for ([_]bool{ true, false }) |v2| {
        const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .protocol_v2 = v2 });
        defer server.stop();
        const url = try server.url(gpa, "repo.git");
        defer gpa.free(url);
        for (cases) |case| {
            var twins = try Twins.init(gpa, io);
            defer twins.deinit(gpa, io);
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.appendSlice(gpa, &.{ "-c", if (v2) "protocol.version=2" else "protocol.version=0", "clone", "-q" });
            try args.appendSlice(gpa, case.git_args);
            try args.appendSlice(gpa, &.{ url, twins.git_path });
            const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, args.items, "", true);
            gpa.free(out);
            var options = case.options;
            options.programs = .{ .environ = &env };
            var repo = try clone_mod.clone(gpa, io, url, twins.by_relic, options);
            repo.deinit(io);
            try expectSameShallow(gpa, io, twins.by_git, twins.by_relic);
        }
    }
}

test "a fetch deepens, and unshallows, as git fetch does, and a plain fetch into git's shallow clone works" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedHistory(gpa, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    // Both start from the clone git made.
    var twins = try Twins.init(gpa, io);
    defer twins.deinit(gpa, io);
    for ([_][]const u8{ "by-git", "by-relic" }) |name| {
        const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "clone", "-q", "--depth=1", url, name }, "", true);
        gpa.free(out);
    }

    // relic reads git's shallow repository: its walk stops at the boundary.
    {
        var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
        defer repo.deinit(io);
        try testing.expectEqual(@as(u32, 1), repo.odb.shallow.count());
    }

    const Step = struct { git_args: []const []const u8, options: fetch_mod.Options };
    for ([_]Step{
        // Nothing asked of the boundary: the tips move, the history is kept.
        .{ .git_args = &.{}, .options = .{ .who = test_who } },
        .{ .git_args = &.{"--deepen=2"}, .options = .{ .who = test_who, .deepen = 2 } },
        .{ .git_args = &.{"--depth=5"}, .options = .{ .who = test_who, .depth = 5 } },
        .{ .git_args = &.{"--unshallow"}, .options = .{ .who = test_who, .unshallow = true } },
    }, 0..) |step, i| {
        if (i == 0) {
            // A new commit on the remote for the plain fetch to bring.
            var maker = try testgit.Repo.init(gpa, io, &.{});
            defer maker.deinit();
            const out = try testremote.gitInputEnv(gpa, io, maker.dir, &env, &.{ "fetch", "-q", "--depth=1", url, "main" }, "", true);
            gpa.free(out);
            try maker.exec(io, &.{ "reset", "-q", "--hard", "FETCH_HEAD" });
            try maker.writeFile(io, "file", "ninth\n");
            try maker.exec(io, &.{ "commit", "-q", "-am", "ninth" });
            const root_path = try testremote.absolutePath(gpa, io, root.dir);
            defer gpa.free(root_path);
            const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
            defer gpa.free(bare);
            try maker.exec(io, &.{ "push", "-q", bare, "HEAD:main" });
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "fetch", "-q" });
        try args.appendSlice(gpa, step.git_args);
        try args.append(gpa, "origin");
        const out = try testremote.gitInputEnv(gpa, io, twins.by_git, &env, args.items, "", true);
        gpa.free(out);
        var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
        defer repo.deinit(io);
        var options = step.options;
        options.programs = .{ .environ = &env };
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", options);
        outcome.deinit();
        try expectSameShallow(gpa, io, twins.by_git, twins.by_relic);
        const theirs = try twins.by_git.readFileAlloc(io, ".git/FETCH_HEAD", gpa, .unlimited);
        defer gpa.free(theirs);
        const ours = try twins.by_relic.readFileAlloc(io, ".git/FETCH_HEAD", gpa, .unlimited);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    // Whole again: there is nothing left to unshallow.
    var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
    defer repo.deinit(io);
    try testing.expectError(error.NotShallow, fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .unshallow = true, .programs = .{ .environ = &env } }));
}

test "a shallow clone over ssh is git's, and one from a path is refused by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try servedHistory(gpa, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var tools = testing.tmpDir(.{ .iterate = true });
    defer tools.cleanup();
    const fake = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(fake);
    try env.put("GIT_SSH_COMMAND", fake);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const url = try std.fmt.allocPrint(gpa, "ssh://example.invalid{s}/repo.git", .{root_path});
    defer gpa.free(url);

    var twins = try Twins.init(gpa, io);
    defer twins.deinit(gpa, io);
    const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "clone", "-q", "--depth=2", url, twins.git_path }, "", true);
    gpa.free(out);
    var repo = try clone_mod.clone(gpa, io, url, twins.by_relic, .{ .who = test_who, .depth = 2, .programs = .{ .environ = &env } });
    repo.deinit(io);
    try expectSameShallow(gpa, io, twins.by_git, twins.by_relic);

    var local = testing.tmpDir(.{ .iterate = true });
    defer local.cleanup();
    const path = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    defer gpa.free(path);
    try testing.expectError(error.ShallowLocalUnsupported, clone_mod.clone(gpa, io, path, local.dir, .{ .who = test_who, .depth = 1 }));
}
