//! Partial clones held to git's: clones filtered by `blob:none`,
//! `blob:limit` and `tree:0` over HTTP, a fetch into one, and a checkout
//! of git's partial clone whose files relic fetches only when it reads
//! them — each repository then read by git: `fsck`, `status`, the objects
//! `rev-list --missing=print` finds present and promised.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const partial = @import("partial.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const Oid = hash.Oid;
const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// A repository at `<root>/repo.git` that allows filters: two commits of
/// a small file, a large one and a directory, a branch and two tags.
fn served(gpa: Allocator, io: Io, root: Io.Dir) !void {
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..400) |i| try big.print(gpa, "a line of a file larger than a kilobyte, {d}\n", .{i});
    try source.writeFile(io, "big.txt", big.items);
    try source.exec(io, &.{ "add", "big.txt" });
    try source.exec(io, &.{ "commit", "-q", "-m", "big" });
    const root_path = try testremote.absolutePath(gpa, io, root);
    defer gpa.free(root_path);
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    try source.exec(io, &.{ "--git-dir", bare, "config", "uploadpack.allowFilter", "true" });
    try source.exec(io, &.{ "--git-dir", bare, "config", "uploadpack.allowAnySHA1InWant", "true" });
}

fn git(gpa: Allocator, io: Io, dir: Io.Dir, args: []const []const u8) ![]u8 {
    return testremote.gitInput(gpa, io, dir, args, "");
}

/// The `.promisor` files' contents in `dir`'s pack directory, sorted and
/// joined.
fn promisorFiles(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    var pack_dir = try dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".promisor")) continue;
        try texts.append(gpa, try pack_dir.readFileAlloc(io, entry.name, gpa, .unlimited));
    }
    std.mem.sort([]u8, texts.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (texts.items) |t| {
        try out.appendSlice(gpa, t);
        try out.appendSlice(gpa, "--\n");
    }
    return out.toOwnedSlice(gpa);
}

/// Every object git finds, `?` before the promised ones, sorted.
fn objectList(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    const out = try git(gpa, io, dir, &.{ "rev-list", "--objects", "--missing=print", "--all" });
    defer gpa.free(out);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    while (it.next()) |line| try lines.append(gpa, line);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return std.mem.join(gpa, "\n", lines.items);
}

fn expectSame(gpa: Allocator, io: Io, by_git: Io.Dir, by_relic: Io.Dir, compare_objects: bool) !void {
    for ([_][]const []const u8{
        &.{ "config", "--get-regexp", "^(core\\.repositoryformatversion|remote\\.|extensions\\.)" },
        &.{ "for-each-ref", "--format=%(refname) %(objectname) %(symref)" },
        &.{ "status", "--porcelain" },
        &.{ "ls-files", "-s" },
    }) |args| {
        const theirs = try git(gpa, io, by_git, args);
        defer gpa.free(theirs);
        const ours = try git(gpa, io, by_relic, args);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    const theirs_promisor = try promisorFiles(gpa, io, by_git);
    defer gpa.free(theirs_promisor);
    const ours_promisor = try promisorFiles(gpa, io, by_relic);
    defer gpa.free(ours_promisor);
    try testing.expectEqualStrings(theirs_promisor, ours_promisor);
    if (compare_objects) {
        const theirs = try objectList(gpa, io, by_git);
        defer gpa.free(theirs);
        const ours = try objectList(gpa, io, by_relic);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    const checked = try git(gpa, io, by_relic, &.{ "fsck", "--no-dangling" });
    gpa.free(checked);
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

test "a partial clone is the one git makes, filtered by blob:none, blob:limit, tree:0, combine:, sparse:oid= and object:type=" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    for ([_][]const u8{ "blob:none", "blob:limit=1k", "tree:0", "combine:blob:none+tree:1", "sparse:oid=main:big.txt", "object:type=tree" }) |spec| {
        var twins = try Twins.init(gpa, io);
        defer twins.deinit(gpa, io);
        const filter_arg = try std.fmt.allocPrint(gpa, "--filter={s}", .{spec});
        defer gpa.free(filter_arg);
        const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "clone", "-q", filter_arg, url, twins.git_path }, "", true);
        gpa.free(out);
        var repo = try clone_mod.clone(gpa, io, url, twins.by_relic, .{ .who = test_who, .filter = spec, .programs = .{ .environ = &env } });
        repo.deinit(io);
        // Which trees a tree:0 checkout fetches, and in how many packs, is
        // the lazy fetch's own business; what is there after is compared
        // for the blob filters.
        expectSame(gpa, io, twins.by_git, twins.by_relic, !std.mem.startsWith(u8, spec, "tree:") and !std.mem.startsWith(u8, spec, "combine:")) catch |err| {
            std.debug.print("with --filter={s}\n", .{spec});
            return err;
        };
    }

    // From a path the filter is ignored — everything is copied — and its
    // settings kept, as git's local clone keeps them; the caller is told.
    var local = try Twins.init(gpa, io);
    defer local.deinit(gpa, io);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const path = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    defer gpa.free(path);
    const cloned = try testremote.gitInputEnv(gpa, io, local.tmp.dir, &env, &.{ "clone", "-q", "--filter=blob:none", path, local.git_path }, "", true);
    gpa.free(cloned);
    var warnings: @import("warning.zig").Warnings = .init(gpa);
    defer warnings.deinit();
    var plain = try clone_mod.clone(gpa, io, path, local.by_relic, .{ .who = test_who, .filter = "blob:none", .warnings = &warnings });
    plain.deinit(io);
    try expectSame(gpa, io, local.by_git, local.by_relic, true);
    try testing.expectEqualStrings("--filter", warnings.items.items[0].ignored_for_local);
}

test "git's partial clone is checked out by relic, which fetches what it reads from the promisor remote" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    var twins = try Twins.init(gpa, io);
    defer twins.deinit(gpa, io);
    for ([_][]const u8{ "by-git", "by-relic", "lone" }) |name| {
        const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "clone", "-q", "--no-checkout", "--filter=blob:none", url, name }, "", true);
        gpa.free(out);
    }
    const checked_out = try testremote.gitInputEnv(gpa, io, twins.by_git, &env, &.{ "checkout", "-q", "main" }, "", true);
    gpa.free(checked_out);

    // A read of one promised object fetches that object.
    {
        var lone = try twins.tmp.dir.openDir(io, "lone", .{});
        defer lone.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, lone, .{});
        defer repo.deinit(io);
        const text = try git(gpa, io, lone, &.{ "rev-parse", "HEAD:big.txt" });
        defer gpa.free(text);
        const blob = try Oid.parse(repo.kind, std.mem.trimEnd(u8, text, "\n"));
        try testing.expectError(error.ObjectNotFound, repo.odb.read(io, blob));
        var lazy: partial.Lazy = .init(gpa, &repo, .{ .programs = .{ .environ = &env } });
        defer lazy.deinit();
        lazy.install();
        const found = try repo.odb.read(io, blob);
        gpa.free(found.bytes);
        try testing.expectEqual(@as(u32, 1), lazy.fetches);
    }

    // A checkout fetches its files in one request first, as git's does.
    var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
    defer repo.deinit(io);
    const head = (try repo.headTree(io)).?;
    var index = try repo.openIndex(io);
    defer index.deinit();
    try testing.expectError(error.ObjectNotFound, worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, head, .{ .rules = repo.worktreeRules() }));
    var lazy: partial.Lazy = .init(gpa, &repo, .{ .programs = .{ .environ = &env } });
    defer lazy.deinit();
    lazy.install();
    try lazy.prefetchTree(io, head);
    _ = try worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, head, .{ .rules = repo.worktreeRules() });
    try index.write(io, repo.git_dir, "index", .{});
    try testing.expectEqual(@as(u32, 1), lazy.fetches);
    try expectSame(gpa, io, twins.by_git, twins.by_relic, true);
}

test "a fetch into a partial clone is filtered, and its pack is a promisor's, as git's is" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    var twins = try Twins.init(gpa, io);
    defer twins.deinit(gpa, io);
    for ([_][]const u8{ "by-git", "by-relic" }) |name| {
        const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "clone", "-q", "--filter=blob:none", url, name }, "", true);
        gpa.free(out);
    }
    // A new commit with a new file on the remote.
    {
        var maker = try testgit.Repo.init(gpa, io, &.{});
        defer maker.deinit();
        const out = try testremote.gitInputEnv(gpa, io, maker.dir, &env, &.{ "pull", "-q", url, "main" }, "", true);
        gpa.free(out);
        try maker.writeFile(io, "new.txt", "new\n");
        try maker.exec(io, &.{ "add", "new.txt" });
        try maker.exec(io, &.{ "commit", "-q", "-m", "new" });
        const root_path = try testremote.absolutePath(gpa, io, root.dir);
        defer gpa.free(root_path);
        const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
        defer gpa.free(bare);
        try maker.exec(io, &.{ "push", "-q", bare, "HEAD:main" });
    }
    const out = try testremote.gitInputEnv(gpa, io, twins.by_git, &env, &.{ "fetch", "-q", "origin" }, "", true);
    gpa.free(out);
    var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
    defer repo.deinit(io);
    var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &env } });
    outcome.deinit();
    try expectSame(gpa, io, twins.by_git, twins.by_relic, true);
    const theirs = try twins.by_git.readFileAlloc(io, ".git/FETCH_HEAD", gpa, .unlimited);
    defer gpa.free(theirs);
    const ours = try twins.by_relic.readFileAlloc(io, ".git/FETCH_HEAD", gpa, .unlimited);
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}

test "a filter the server does not know is left off with a warning and everything fetched, as git does, in v2 and v0" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, root.dir);
    {
        var bare = try root.dir.openDir(io, "repo.git", .{});
        defer bare.close(io);
        const out = try git(gpa, io, bare, &.{ "config", "uploadpack.allowFilter", "false" });
        gpa.free(out);
    }
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    for ([_][]const u8{ "2", "0" }) |version| {
        var twins = try Twins.init(gpa, io);
        defer twins.deinit(gpa, io);
        const setting = try std.fmt.allocPrint(gpa, "protocol.version={s}", .{version});
        defer gpa.free(setting);
        const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "-c", setting, "clone", "-q", "--filter=blob:none", url, twins.git_path }, "", true);
        gpa.free(out);
        const text = try std.fmt.allocPrint(gpa, "[protocol]\n\tversion = {s}\n", .{version});
        defer gpa.free(text);
        var settings = try @import("config.zig").Config.parseText(gpa, text, .command);
        defer settings.deinit();
        var warnings: @import("warning.zig").Warnings = .init(gpa);
        defer warnings.deinit();
        var repo = try clone_mod.clone(gpa, io, url, twins.by_relic, .{
            .who = test_who,
            .filter = "blob:none",
            .programs = .{ .environ = &env },
            .config = &settings,
            .warnings = &warnings,
        });
        repo.deinit(io);
        // Marked partial and its pack a promisor's, with nothing left out.
        try expectSame(gpa, io, twins.by_git, twins.by_relic, true);
        try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
        try testing.expect(warnings.items.items[0] == .filter_not_supported);
    }
}

test "a promised object is fetched from the next promisor remote when one fails, as git's lazy fetch goes on" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, root.dir);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const origin = try std.fmt.allocPrint(gpa, "file://{s}/repo.git", .{root_path});
    defer gpa.free(origin);
    const mirror = try std.fmt.allocPrint(gpa, "file://{s}/mirror.git", .{root_path});
    defer gpa.free(mirror);
    const mirror_path = try std.fmt.allocPrint(gpa, "{s}/mirror.git", .{root_path});
    defer gpa.free(mirror_path);
    {
        const out = try git(gpa, io, root.dir, &.{ "clone", "-q", "--mirror", origin, mirror_path });
        gpa.free(out);
        var m = try root.dir.openDir(io, "mirror.git", .{});
        defer m.close(io);
        for ([_][]const u8{ "uploadpack.allowFilter", "uploadpack.allowAnySHA1InWant" }) |key| {
            const set = try git(gpa, io, m, &.{ "config", key, "true" });
            gpa.free(set);
        }
    }
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var twins = try Twins.init(gpa, io);
    defer twins.deinit(gpa, io);
    // Two promisor remotes, the clone's own first and no longer there.
    for ([_][]const u8{ "by-git", "by-relic" }) |name| {
        const out = try testremote.gitInputEnv(gpa, io, twins.tmp.dir, &env, &.{ "clone", "-q", "--no-checkout", "--filter=blob:none", origin, name }, "", true);
        gpa.free(out);
        var d = try twins.tmp.dir.openDir(io, name, .{});
        defer d.close(io);
        for ([_][]const []const u8{
            &.{ "remote", "add", "mirror", mirror },
            &.{ "config", "remote.mirror.promisor", "true" },
            &.{ "config", "remote.origin.url", "file:///nowhere/repo.git" },
        }) |args| {
            const set = try git(gpa, io, d, args);
            gpa.free(set);
        }
    }
    const checked_out = try testremote.gitInputEnv(gpa, io, twins.by_git, &env, &.{ "checkout", "-q", "main" }, "", true);
    gpa.free(checked_out);

    var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
    defer repo.deinit(io);
    const names = blk: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const list = try partial.promisorRemotes(arena.allocator(), &repo.config);
        var joined: std.ArrayList(u8) = .empty;
        for (list) |n| try joined.print(gpa, "{s} ", .{n});
        break :blk try joined.toOwnedSlice(gpa);
    };
    defer gpa.free(names);
    try testing.expectEqualStrings("origin mirror ", names);
    const head = (try repo.headTree(io)).?;
    var index = try repo.openIndex(io);
    defer index.deinit();
    var lazy: partial.Lazy = .init(gpa, &repo, .{ .programs = .{ .environ = &env } });
    defer lazy.deinit();
    lazy.install();
    try lazy.prefetchTree(io, head);
    _ = try worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, head, .{ .rules = repo.worktreeRules() });
    try index.write(io, repo.git_dir, "index", .{});
    try expectSame(gpa, io, twins.by_git, twins.by_relic, true);

    // With no promisor remote that has them, the read fails by name.
    const set = try git(gpa, io, twins.by_relic, &.{ "config", "remote.mirror.url", "file:///nowhere/mirror.git" });
    gpa.free(set);
    try repo.config.set("remote.mirror.url", "file:///nowhere/mirror.git");
    const missing = try Oid.parse(repo.kind, "1111111111111111111111111111111111111111");
    try testing.expectError(error.PromisorFetchFailed, repo.odb.read(io, missing));
}
