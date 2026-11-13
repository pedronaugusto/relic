//! `submodule.DiffWriter` against git 2.55's `git diff --submodule=log`
//! and `--submodule=diff`: a submodule added, moved on, rewound, moved to
//! a commit on another line, moved to a commit it does not have, and
//! removed, with a nested submodule's own diff inside, in colour and
//! without, and by `diff.submodule`.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");
const hash = @import("../hash/hash.zig");
const diff = @import("../diff/diff.zig");
const paint = @import("../diff/paint.zig");
const submodule_diff = @import("diff.zig");
const move_test = @import("move_test.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

fn treeOf(repo: *repo_mod.Repository, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return repo.commitTree(io, try hash.Oid.parse(.sha1, text));
}

test "a submodule's change is git diff --submodule's: its log, or its own diff, nested ones within" {
    var git = try move_test.fixture(true);
    defer git.deinit();
    // a commit of the submodule's on another line than `two`'s
    try git.exec(io, &.{ "checkout", "-q", "--detach" });
    try git.writeFile(io, "sub/t", "t3\n");
    try git.exec(io, &.{ "-C", "sub", "commit", "-qam", "s3 on a side line" });
    try git.exec(io, &.{ "add", "sub" });
    try git.exec(io, &.{ "commit", "-qm", "side" });
    try git.exec(io, &.{ "branch", "side" });
    // and one the submodule does not have
    try git.exec(io, &.{ "update-index", "--cacheinfo", "160000,1234567890123456789012345678901234567890,sub" });
    try git.exec(io, &.{ "commit", "-qm", "missing" });
    try git.exec(io, &.{ "branch", "missing" });

    const pairs = [_][2][]const u8{
        .{ "none", "one" }, .{ "one", "two" },     .{ "two", "one" },  .{ "two", "side" },
        .{ "side", "two" }, .{ "one", "missing" }, .{ "one", "none" }, .{ "one", "one" },
    };
    const Mode = struct { format: diff.SubmoduleFormat, by_config: bool = false, color: bool = false };
    const modes = [_]Mode{
        .{ .format = .log },
        .{ .format = .diff },
        .{ .format = .log, .color = true },
        .{ .format = .diff, .color = true },
        .{ .format = .log, .by_config = true },
        .{ .format = .diff, .by_config = true },
    };
    for (modes) |mode| {
        if (mode.by_config) try git.exec(io, &.{ "config", "diff.submodule", @tagName(mode.format) });
        defer if (mode.by_config) git.exec(io, &.{ "config", "--unset", "diff.submodule" }) catch {};
        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        for (pairs) |pair| {
            var flag_buf: [32]u8 = undefined;
            const flag = try std.mem.print(&flag_buf, "--submodule={t}", .{mode.format});
            const args: []const []const u8 = if (mode.by_config)
                &.{ "diff", if (mode.color) "--color=always" else "--no-color", pair[0], pair[1] }
            else
                &.{ "diff", flag, if (mode.color) "--color=always" else "--no-color", pair[0], pair[1] };
            const theirs = try git.run(io, args);
            defer gpa.free(theirs);

            var changes = try diff.tree(gpa, io, repo.objectDatabase(), .{ .old = try treeOf(&repo, &git, pair[0]), .new = try treeOf(&repo, &git, pair[1]) }, .{ .renames = (try diff.RenameSettings.read(repo.configuration())).options() });
            defer changes.deinit();
            const colors: paint.Colors = .{};
            var base: diff.Options = .{ .colors = if (mode.color) &colors else null };
            if (!mode.by_config) base.submodule = mode.format;
            const options = try diff.configured(repo.configuration(), base);
            try std.testing.expectEqual(mode.format, options.submodule);
            var writer = try submodule_diff.DiffWriter.init(gpa, &repo, null);
            var ours: Io.Writer.Allocating = .init(gpa);
            defer ours.deinit();
            try diff.unified(gpa, io, &ours.writer, .{ .db = repo.objectDatabase(), .changes = changes.items, .submodules = writer.writer() }, options);
            std.testing.expectEqualStrings(theirs, ours.written()) catch |err| {
                std.debug.print("{s}..{s} {t} colour {} config {}\n", .{ pair[0], pair[1], mode.format, mode.color, mode.by_config });
                return err;
            };
        }
    }
}

test "diff.submodule is read as git reads it: a format it does not know keeps the last, no value is refused" {
    const config_mod = @import("../config/config.zig");
    var config = try config_mod.Config.parseText(gpa, "[diff]\n\tsubmodule = log\n\tsubmodule = nonsense\n", .local);
    defer config.deinit();
    try std.testing.expectEqual(diff.SubmoduleFormat.log, (try diff.configured(&config, .{})).submodule);
    var bare = try config_mod.Config.parseText(gpa, "[diff]\n\tsubmodule\n", .local);
    defer bare.deinit();
    try std.testing.expectError(error.InvalidDiffSetting, diff.configured(&bare, .{}));
}

test "a submodule's log or diff with no writer is refused by name" {
    var git = try move_test.fixture(false);
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var changes = try diff.tree(gpa, io, repo.objectDatabase(), .{ .old = try treeOf(&repo, &git, "one"), .new = try treeOf(&repo, &git, "two") }, .{});
    defer changes.deinit();
    var ours: Io.Writer.Allocating = .init(gpa);
    defer ours.deinit();
    try std.testing.expectError(error.NoSubmoduleWriter, diff.unified(gpa, io, &ours.writer, .{ .db = repo.objectDatabase(), .changes = changes.items }, .{ .submodule = .log }));
}

test "a cancel that lands in writing a submodule's log is returned, not written as a submodule that is not there" {
    const shakedown = @import("shakedown");
    const testing_io = @import("../testing/io.zig");
    var git = try move_test.fixture(true);
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var changes = try diff.tree(gpa, io, repo.objectDatabase(), .{ .old = try treeOf(&repo, &git, "one"), .new = try treeOf(&repo, &git, "two") }, .{});
    defer changes.deinit();

    const Write = struct {
        repo: *repo_mod.Repository,
        root: Io.Dir,
        changes: []const diff.Change,
        pub fn setUp(_: *@This(), _: *shakedown.FaultIo) !void {}
        pub fn run(w: *@This(), run_io: Io) !void {
            var writer = try submodule_diff.DiffWriter.init(gpa, w.repo, null);
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try diff.unified(gpa, run_io, &out.writer, .{ .db = w.repo.objectDatabase(), .changes = w.changes, .submodules = writer.writer() }, .{ .submodule = .log });
        }
        pub fn check(_: *@This(), check_io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
            try testing_io.cancelKept(check_io, result, injected);
        }
        // A cancel in the removal of the submodule's timestamp probe file
        // leaves it, as a leftover is left; the next run starts without it.
        pub fn tearDown(w: *@This()) void {
            var objects = w.root.openDir(io, ".git/modules/sub/objects", .{ .iterate = true }) catch return;
            defer objects.close(io);
            var it = objects.iterate();
            while (it.next(io) catch return) |entry| {
                if (std.mem.startsWith(u8, entry.name, "relic_tres_")) objects.deleteFile(io, entry.name) catch return;
            }
        }
    };
    var w: Write = .{ .repo = &repo, .root = git.dir, .changes = changes.items };
    try testing_io.everyCancel(gpa, io, &w);
}
