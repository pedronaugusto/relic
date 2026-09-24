//! Locks against the in-test server, relic beside git-lfs: the locks one
//! takes the other lists, the owner is the one the server names, a lock
//! someone else holds is refused unless forced, the cache is where and what
//! git-lfs keeps, and lockable files end up with the permission bits git-lfs
//! gives them.
//!
//! Two people share the server: relic works as `ada`, git-lfs as `bob`, each
//! with a stand-in helper of their own. Everything runs from the fixture's
//! environment, so no helper, keychain or agent of the person running the
//! suite is reached.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const repo_mod = @import("repo.zig");
const lfsapi = @import("lfsapi.zig");
const lfslocks = @import("lfslocks.zig");
const testlfs = @import("testlfs.zig");
const lt = @import("lfstransfer_test.zig");

const Fixture = lt.Fixture;

const lockable_attributes = "*.bin filter=lfs diff=lfs merge=lfs -text lockable\n";

/// A remote with three files, cloned twice: `ours` for relic as ada, and
/// `theirs` for git-lfs as bob.
const Pair = struct {
    fx: *Fixture,
    ours: Io.Dir,
    theirs: Io.Dir,

    fn init(gpa: Allocator, io: Io) !Pair {
        const fx = try Fixture.init(gpa, io, .{ .users = &.{
            .{ .name = "ada", .password = "secret" },
            .{ .name = "bob", .password = "hunter2" },
        } });
        errdefer fx.deinit();
        const ada = try testlfs.credentialHelper(gpa, io, fx.tools, "ada-helper", "ada", "secret");
        defer gpa.free(ada);
        const bob = try testlfs.credentialHelper(gpa, io, fx.tools, "bob-helper", "bob", "hunter2");
        defer gpa.free(bob);
        var seed = try fx.workRepo("seed", bob);
        defer seed.close(io);
        try seed.writeFile(io, .{ .sub_path = ".gitattributes", .data = lockable_attributes });
        try seed.writeFile(io, .{ .sub_path = "x.bin", .data = "x content\n" });
        try seed.writeFile(io, .{ .sub_path = "y.bin", .data = "y content\n" });
        try seed.writeFile(io, .{ .sub_path = "plain.txt", .data = "not lockable\n" });
        try fx.gitIn(seed, &.{ "add", "-A" });
        try fx.gitIn(seed, &.{ "commit", "-q", "-m", "seed" });
        try fx.gitIn(seed, &.{ "lfs", "push", "origin", "main" });
        try fx.gitIn(seed, &.{ "push", "-q", "--no-verify", "origin", "main" });
        var ours = try fx.cloneRepo("ours", ada);
        errdefer ours.close(io);
        var theirs = try fx.cloneRepo("theirs", bob);
        errdefer theirs.close(io);
        for ([_]Io.Dir{ ours, theirs }) |d| try fx.gitIn(d, &.{ "lfs", "pull" });
        return .{ .fx = fx, .ours = ours, .theirs = theirs };
    }

    fn deinit(p: *Pair) void {
        p.ours.close(p.fx.io);
        p.theirs.close(p.fx.io);
        p.fx.deinit();
    }

    fn open(p: *Pair, repo: *repo_mod.Repository) !*lfsapi.Server {
        return lfsapi.Server.open(p.fx.gpa, p.fx.io, repo, "origin", .{ .programs = p.fx.programs() });
    }
};

fn mode(io: Io, d: Io.Dir, path: []const u8) !u32 {
    const st = try d.statFile(io, path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

test "locks relic takes git lfs locks lists, and the other way round, with the owner the server names" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var pair = try Pair.init(gpa, io);
    defer pair.deinit();
    const fx = pair.fx;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repo = try repo_mod.Repository.open(gpa, io, pair.ours, .{});
    defer repo.deinit(io);
    const server = try pair.open(&repo);
    defer server.close();

    const taken = try lfslocks.lock(server, &repo, "x.bin", arena, .{});
    try testing.expectEqualStrings("ada", taken.locked.owner.?);
    try fx.gitIn(pair.theirs, &.{ "lfs", "lock", "y.bin" });

    // git-lfs lists both, with their owners.
    const listed = try fx.gitOut(pair.theirs, &.{ "lfs", "locks" });
    defer gpa.free(listed);
    try testing.expect(std.mem.indexOf(u8, listed, "x.bin\tada\tID:1") != null);
    try testing.expect(std.mem.indexOf(u8, listed, "y.bin\tbob\tID:2") != null);

    // relic lists both, and the server's split says whose is whose.
    var all = try lfslocks.list(server, &repo, .{}, .{});
    defer all.deinit();
    try testing.expectEqual(@as(usize, 2), all.locks.len);
    var split = try lfslocks.verify(server, &repo, .{});
    defer split.deinit();
    var table = try lfslocks.Table.fromVerified(gpa, split.ours, split.theirs);
    defer table.deinit();
    try testing.expectEqualStrings("bob", table.find("y.bin").?.owner.?);
    try testing.expectEqual(@as(?bool, false), table.find("y.bin").?.ours);
    try testing.expectEqual(@as(?bool, true), table.find("x.bin").?.ours);
    try testing.expect(table.find("plain.txt") == null);

    // A lock someone holds is theirs: taking it says who, and giving it
    // back is refused unless forced.
    const held = try lfslocks.lock(server, &repo, "y.bin", arena, .{});
    try testing.expectEqualStrings("bob", held.held.owner.?);
    try testing.expectError(error.LockOwnedByOther, lfslocks.unlockPath(server, &repo, "y.bin", false, arena, .{}));
    if (testlfs.git(gpa, io, pair.theirs, &fx.env, &.{ "lfs", "unlock", "x.bin" }, false)) |out| {
        gpa.free(out);
        return error.TestUnexpectedResult;
    } else |_| {}

    const broken = try lfslocks.unlockPath(server, &repo, "y.bin", true, arena, .{});
    try testing.expectEqualStrings("y.bin", broken.path);
    try fx.gitIn(pair.theirs, &.{ "lfs", "unlock", "--force", "x.bin" });
    const after = try fx.server.lockListing(gpa);
    defer gpa.free(after);
    try testing.expectEqualStrings("", after);
    try testing.expectError(error.LockNotFound, lfslocks.unlockPath(server, &repo, "x.bin", false, arena, .{}));
}

test "the lock cache is where git-lfs keeps it and what git-lfs writes, read both ways" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var pair = try Pair.init(gpa, io);
    defer pair.deinit();
    const fx = pair.fx;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try fx.server.addLock("y.bin", "bob");

    var repo = try repo_mod.Repository.open(gpa, io, pair.ours, .{});
    defer repo.deinit(io);
    const server = try pair.open(&repo);
    defer server.close();
    _ = try lfslocks.lock(server, &repo, "x.bin", arena, .{});
    var all = try lfslocks.list(server, &repo, .{}, .{});
    all.deinit();
    var split = try lfslocks.verify(server, &repo, .{});
    split.deinit();

    // git-lfs reads relic's cache, and says what it says live.
    for ([_][]const []const u8{ &.{ "lfs", "locks" }, &.{ "lfs", "locks", "--verify" } }) |args| {
        const live = try fx.gitOut(pair.ours, args);
        defer gpa.free(live);
        var cached_args: std.ArrayList([]const u8) = .empty;
        defer cached_args.deinit(gpa);
        try cached_args.appendSlice(gpa, args);
        try cached_args.append(gpa, "--cached");
        const cached = try fx.gitOut(pair.ours, cached_args.items);
        defer gpa.free(cached);
        try testing.expectEqualStrings(live, cached);
    }

    // relic reads git-lfs's cache, with no server.
    const listed = try fx.gitOut(pair.theirs, &.{ "lfs", "locks", "--verify" });
    gpa.free(listed);
    var theirs_repo = try repo_mod.Repository.open(gpa, io, pair.theirs, .{});
    defer theirs_repo.deinit(io);
    const store: @import("lfs.zig").Store = .{ .base = theirs_repo.common_dir, .root = "lfs" };
    var table = try lfslocks.Table.cached(gpa, io, &store, "refs/heads/main");
    defer table.deinit();
    try testing.expectEqualStrings("ada", table.find("x.bin").?.owner.?);
    try testing.expectEqual(@as(?bool, false), table.find("x.bin").?.ours);
    try testing.expectEqual(@as(?bool, true), table.find("y.bin").?.ours);
}

test "lockable files are read-only unless the person holds the lock, with git-lfs's bits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var pair = try Pair.init(gpa, io);
    defer pair.deinit();
    const fx = pair.fx;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zero = "0000000000000000000000000000000000000000";

    var repo = try repo_mod.Repository.open(gpa, io, pair.ours, .{});
    defer repo.deinit(io);
    const server = try pair.open(&repo);
    defer server.close();

    // After a checkout, with no locks: every lockable file read-only.
    _ = try lfslocks.fixWriteFlags(gpa, io, &repo, null, .{});
    try fx.gitIn(pair.theirs, &.{ "lfs", "post-checkout", zero, "HEAD", "1" });
    for ([_][]const u8{ "x.bin", "y.bin", "plain.txt", ".gitattributes" }) |p| {
        try testing.expectEqual(try mode(io, pair.theirs, p), try mode(io, pair.ours, p));
    }
    try testing.expectEqual(@as(u32, 0), try mode(io, pair.ours, "x.bin") & 0o222);

    // Each takes a lock on a different file: the holder's file writable,
    // the other's still read-only.
    _ = try lfslocks.lock(server, &repo, "x.bin", arena, .{});
    try fx.gitIn(pair.theirs, &.{ "lfs", "lock", "y.bin" });
    try testing.expectEqual(try mode(io, pair.theirs, "y.bin"), try mode(io, pair.ours, "x.bin"));
    try testing.expectEqual(try mode(io, pair.theirs, "x.bin"), try mode(io, pair.ours, "y.bin"));
    try testing.expect(try mode(io, pair.ours, "x.bin") & 0o200 != 0);

    // A checkout keeps it so, from the cache alone.
    var split = try lfslocks.verify(server, &repo, .{});
    split.deinit();
    _ = try lfslocks.fixWriteFlags(gpa, io, &repo, null, .{});
    try fx.gitIn(pair.theirs, &.{ "lfs", "post-checkout", zero, "HEAD", "1" });
    try testing.expectEqual(try mode(io, pair.theirs, "y.bin"), try mode(io, pair.ours, "x.bin"));
    try testing.expectEqual(try mode(io, pair.theirs, "x.bin"), try mode(io, pair.ours, "y.bin"));

    // Giving the lock back makes the file read-only again.
    _ = try lfslocks.unlockPath(server, &repo, "x.bin", false, arena, .{});
    try fx.gitIn(pair.theirs, &.{ "lfs", "unlock", "y.bin" });
    try testing.expectEqual(try mode(io, pair.theirs, "y.bin"), try mode(io, pair.ours, "x.bin"));
    try testing.expectEqual(@as(u32, 0), try mode(io, pair.ours, "x.bin") & 0o222);
}

test "a server with no locking API is named" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .locking = false });
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    var d = try fx.workRepo("ours", nobody);
    defer d.close(io);
    var repo = try repo_mod.Repository.open(gpa, io, d, .{});
    defer repo.deinit(io);
    const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = fx.programs() });
    defer server.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try testing.expectError(error.LockingUnsupported, lfslocks.lock(server, &repo, "a.bin", arena_state.allocator(), .{ .ref = "refs/heads/main" }));
    try testing.expectError(error.LockingUnsupported, lfslocks.verify(server, &repo, .{ .ref = "refs/heads/main" }));
    try testing.expectError(error.LockingUnsupported, lfslocks.list(server, &repo, .{}, .{ .ref = "refs/heads/main" }));
}

test "a repository with git-lfs's hooks works on a machine without git-lfs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const hooks = @import("hooks.zig");
    const lfshooks = @import("lfshooks.zig");
    var pair = try Pair.init(gpa, io);
    defer pair.deinit();
    const fx = pair.fx;

    // The hooks are the ones `git lfs install` writes, and relic knows each.
    try fx.gitIn(pair.theirs, &.{ "lfs", "install", "--local" });
    var home_hooks = try fx.tmp.dir.openDir(io, "home/hooks", .{});
    defer home_hooks.close(io);
    try pair.ours.createDirPath(io, ".git/hooks");
    for (hooks.git_lfs_events) |event| {
        const text = try home_hooks.readFileAlloc(io, event, gpa, .limited(4096));
        defer gpa.free(text);
        try testing.expect(hooks.isGitLfsHook(event, text));
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".git/hooks/{s}", .{event});
        try pair.ours.writeFile(io, .{ .sub_path = path, .data = text });
        const file = try pair.ours.openFile(io, path, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }

    // No git-lfs anywhere on the path the hooks are run with.
    try fx.tmp.dir.createDirPath(io, "empty-path");
    const empty = try fx.path("empty-path");
    defer gpa.free(empty);
    var bare_env = try fx.env.clone(gpa);
    defer bare_env.deinit();
    try bare_env.put("PATH", empty);

    var repo = try repo_mod.Repository.open(gpa, io, pair.ours, .{});
    defer repo.deinit(io);
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    const zero = @import("hash.zig").Oid.zero(repo.kind);
    const place: hooks.Place = .{ .config = &repo.config, .git_dir = repo.git_dir, .common_dir = repo.common_dir, .work_dir = repo.work_dir };

    // Run as they are, they stop: git-lfs was not found.
    {
        var runner = try hooks.Runner.init(gpa, io, place, .{ .environ = &bare_env }, .{ .output = .capture });
        defer runner.deinit();
        const ran = try runner.postCheckout(io, zero, head.oid, .branch);
        try testing.expectEqual(@as(?u8, 2), ran.failure.?.status());
        try testing.expect(std.mem.indexOf(u8, runner.captured.items, "'git-lfs' was not found") != null);
    }
    // Handed to relic, they do git-lfs's work and succeed.
    var native: lfshooks.Native = .{ .gpa = gpa, .repo = &repo };
    var runner = try hooks.Runner.init(gpa, io, place, .{ .environ = &bare_env }, .{ .output = .capture, .lfs = native.lfsHooks() });
    defer runner.deinit();
    for ([_]hooks.Ran{
        try runner.postCheckout(io, zero, head.oid, .branch),
        try runner.postMerge(io, false),
        try runner.prePush(io, "origin", "http://unused.invalid/", &.{}),
    }) |ran| {
        try testing.expect(ran.succeeded());
        try testing.expect(ran.lfs_native);
    }
    try testing.expectEqual(@as(u32, 0), try mode(io, pair.ours, "x.bin") & 0o222);
    try testing.expect(try mode(io, pair.ours, "plain.txt") & 0o200 != 0);

    // After a commit, the files it changed are set as git-lfs sets them.
    try pair.ours.deleteFile(io, "y.bin");
    try pair.ours.writeFile(io, .{ .sub_path = "y.bin", .data = "changed\n" });
    try fx.gitIn(pair.ours, &.{ "-c", "core.hooksPath=/nonexistent", "commit", "-q", "-am", "change y" });
    try testing.expect(try mode(io, pair.ours, "y.bin") & 0o200 != 0);
    const index_path = try fx.path("ours/.git/index");
    defer gpa.free(index_path);
    const ran = try runner.postCommit(io, .{ .index_path = index_path });
    try testing.expect(ran.lfs_native and ran.succeeded());
    try testing.expectEqual(@as(u32, 0), try mode(io, pair.ours, "y.bin") & 0o222);
    try testing.expectEqualStrings("", runner.captured.items);
}
