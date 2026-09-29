//! A push with LFS in it, relic's beside git's with git-lfs's pre-push hook:
//! the objects the pushed commits point at reach the server before the refs
//! do, only the ones it lacks are sent, a change to a file someone else has
//! locked is refused or reported as git-lfs refuses or reports it, and a
//! server without a locking API is remembered under git-lfs's own key.
//!
//! git's side runs the hooks `git lfs install` writes, kept in the fixture's
//! own home directory. Nothing of the person running the suite is reached.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const repo_mod = @import("repo.zig");
const push_mod = @import("push.zig");
const lfspush = @import("lfspush.zig");
const testlfs = @import("testlfs.zig");
const lt = @import("lfstransfer_test.zig");

const Fixture = lt.Fixture;

const test_who: @import("object.zig").Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

fn relicPush(fx: *Fixture, d: Io.Dir, report: *lfspush.Report) !push_mod.Outcome {
    var repo = try repo_mod.Repository.open(fx.gpa, fx.io, d, .{});
    defer repo.deinit(fx.io);
    return push_mod.push(fx.gpa, fx.io, &repo, "origin", .{
        .refspecs = &.{"refs/heads/main:refs/heads/main"},
        .who = test_who,
        .programs = fx.programs(),
        .lfs = .{ .report = report },
    });
}

fn serverMain(fx: *Fixture) ![]u8 {
    const u = try fx.url();
    defer fx.gpa.free(u);
    return fx.gitOut(fx.tmp.dir, &.{ "ls-remote", u, "refs/heads/main" });
}

test "a push uploads the LFS objects its commits point at, and only those the server lacks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .users = &.{.{ .name = "ada", .password = "secret" }} });
    defer fx.deinit();
    const ada = try testlfs.credentialHelper(gpa, io, fx.tools, "ada-helper", "ada", "secret");
    defer gpa.free(ada);
    var ours = try fx.workRepo("ours", ada);
    defer ours.close(io);
    const big = try lt.noise(gpa, 200 * 1024, 11);
    defer gpa.free(big);
    try ours.writeFile(io, .{ .sub_path = ".gitattributes", .data = lt.attributes });
    try ours.writeFile(io, .{ .sub_path = "big.bin", .data = big });
    try ours.writeFile(io, .{ .sub_path = "small.bin", .data = "small\n" });
    try fx.gitIn(ours, &.{ "add", "-A" });
    try fx.gitIn(ours, &.{ "commit", "-q", "-m", "one" });
    {
        var report: lfspush.Report = .init(gpa);
        defer report.deinit();
        var outcome = try relicPush(fx, ours, &report);
        defer outcome.deinit();
        try testing.expect(!outcome.anyRejected());
        try testing.expect(report.ran);
        try testing.expectEqual(@as(usize, 2), report.uploads.len);
    }
    try testing.expectEqual(@as(usize, 2), fx.server.objectCount());

    // A second commit sends only its own object.
    const more = try lt.noise(gpa, 50 * 1024, 12);
    defer gpa.free(more);
    try ours.writeFile(io, .{ .sub_path = "more.bin", .data = more });
    try fx.gitIn(ours, &.{ "add", "-A" });
    try fx.gitIn(ours, &.{ "commit", "-q", "-m", "two" });
    fx.server.clearLog();
    {
        var report: lfspush.Report = .init(gpa);
        defer report.deinit();
        var outcome = try relicPush(fx, ours, &report);
        defer outcome.deinit();
        try testing.expect(!outcome.anyRejected());
        try testing.expectEqual(@as(usize, 1), report.uploads.len);
    }
    const seen = try fx.server.requests(gpa);
    defer gpa.free(seen);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen, "PUT /objects/"));

    // git and git-lfs get it all back.
    var theirs = try fx.cloneRepo("theirs", ada);
    defer theirs.close(io);
    try fx.gitIn(theirs, &.{ "lfs", "pull" });
    for ([_][2][]const u8{ .{ "big.bin", big }, .{ "small.bin", "small\n" }, .{ "more.bin", more } }) |f| {
        const have = try theirs.readFileAlloc(io, f[0], gpa, .unlimited);
        defer gpa.free(have);
        try testing.expectEqualSlices(u8, f[1], have);
    }
}

test "a push changing a file someone else has locked is refused or reported, as git-lfs's pre-push hook does" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .users = &.{
        .{ .name = "ada", .password = "secret" },
        .{ .name = "bob", .password = "hunter2" },
    } });
    defer fx.deinit();
    const ada = try testlfs.credentialHelper(gpa, io, fx.tools, "ada-helper", "ada", "secret");
    defer gpa.free(ada);
    const bob = try testlfs.credentialHelper(gpa, io, fx.tools, "bob-helper", "bob", "hunter2");
    defer gpa.free(bob);
    var seed = try fx.workRepo("seed", bob);
    defer seed.close(io);
    try seed.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.bin filter=lfs diff=lfs merge=lfs -text lockable\n" });
    try seed.writeFile(io, .{ .sub_path = "y.bin", .data = "y\n" });
    try fx.gitIn(seed, &.{ "add", "-A" });
    try fx.gitIn(seed, &.{ "commit", "-q", "-m", "seed" });
    try fx.gitIn(seed, &.{ "lfs", "push", "origin", "main" });
    try fx.gitIn(seed, &.{ "push", "-q", "--no-verify", "origin", "main" });
    try fx.gitIn(seed, &.{ "lfs", "lock", "y.bin" });

    // ada changes the file bob holds, in two clones: one pushed by relic,
    // one by git with git-lfs's hooks.
    const lfs_url = try fx.server.url(gpa, "repo.git/info/lfs");
    defer gpa.free(lfs_url);
    const key = try std.fmt.allocPrint(gpa, "lfs.{s}.locksverify", .{lfs_url});
    defer gpa.free(key);
    var clones: [2]Io.Dir = undefined;
    for ([_][]const u8{ "by-relic", "by-git" }, &clones) |name, *d| {
        d.* = try fx.cloneRepo(name, ada);
        try fx.gitIn(d.*, &.{ "lfs", "pull" });
        // git-lfs left it read-only, as a file someone else holds; ada
        // writes it anyway.
        try d.*.deleteFile(io, "y.bin");
        try d.*.writeFile(io, .{ .sub_path = "y.bin", .data = "changed by ada\n" });
        try fx.gitIn(d.*, &.{ "commit", "-q", "-am", "change" });
        try fx.gitIn(d.*, &.{ "config", key, "true" });
    }
    defer for (clones) |d| d.close(io);
    try fx.gitIn(clones[1], &.{ "lfs", "install", "--local" });

    const before = try serverMain(fx);
    defer gpa.free(before);
    {
        var report: lfspush.Report = .init(gpa);
        defer report.deinit();
        try testing.expectError(error.LfsLockedByOthers, relicPush(fx, clones[0], &report));
        try testing.expectEqual(@as(usize, 1), report.locked_by_others.len);
        try testing.expectEqualStrings("y.bin", report.locked_by_others[0].path);
        try testing.expectEqualStrings("bob", report.locked_by_others[0].owner.?);
        try testing.expectEqual(@as(usize, 0), report.uploads.len);
    }
    if (testlfs.git(gpa, io, clones[1], &fx.env, &.{ "push", "-q", "origin", "main" }, false)) |out| {
        gpa.free(out);
        return error.TestUnexpectedResult;
    } else |_| {}
    const after = try serverMain(fx);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);

    // With the check not asked for, both push, and relic says why git-lfs
    // would have warned.
    for (clones) |d| try fx.gitIn(d, &.{ "config", "--unset", key });
    {
        var report: lfspush.Report = .init(gpa);
        defer report.deinit();
        var outcome = try relicPush(fx, clones[0], &report);
        defer outcome.deinit();
        try testing.expect(!outcome.anyRejected());
        try testing.expectEqual(lfspush.LockCheck.verified, report.locks);
        try testing.expectEqualStrings("bob", report.locked_by_others[0].owner.?);
    }
    try fx.gitIn(clones[1], &.{ "pull", "-q", "--no-rebase", "-X", "theirs", "origin", "main" });
    try fx.gitIn(clones[1], &.{ "push", "-q", "origin", "main" });
}

test "a server without a locking API is remembered under git-lfs's key, as git-lfs remembers it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .locking = false });
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    var dirs: [2]Io.Dir = undefined;
    for ([_][]const u8{ "by-relic", "by-git" }, &dirs, 0..) |name, *d, i| {
        d.* = try fx.workRepo(name, nobody);
        try d.*.writeFile(io, .{ .sub_path = ".gitattributes", .data = lt.attributes });
        try d.*.writeFile(io, .{ .sub_path = name, .data = name });
        try d.*.writeFile(io, .{ .sub_path = "a.bin", .data = "same object\n" });
        try fx.gitIn(d.*, &.{ "add", "-A" });
        try fx.gitIn(d.*, &.{ "commit", "-q", "-m", name });
        if (i == 1) try fx.gitIn(d.*, &.{ "lfs", "install", "--local" });
    }
    defer for (dirs) |d| d.close(io);
    {
        var report: lfspush.Report = .init(gpa);
        defer report.deinit();
        var outcome = try relicPush(fx, dirs[0], &report);
        defer outcome.deinit();
        try testing.expect(!outcome.anyRejected());
        try testing.expectEqual(lfspush.LockCheck.unsupported, report.locks);
    }
    try fx.gitIn(dirs[1], &.{ "push", "-q", "--force", "origin", "main" });
    const ours = try fx.gitOut(dirs[0], &.{ "config", "--get-regexp", "locksverify" });
    defer gpa.free(ours);
    const theirs = try fx.gitOut(dirs[1], &.{ "config", "--get-regexp", "locksverify" });
    defer gpa.free(theirs);
    try testing.expectEqualStrings(theirs, ours);
}
