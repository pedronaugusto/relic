//! A repository's configuration against the real git: the `includeIf`
//! conditions a person's `~/.gitconfig` uses, and a repository held for
//! days while another process changes its configuration.
//!
//! A `Repository` holds what its configuration files held at open. These
//! tests change them with `git config`, as a person in a terminal would,
//! and check that nothing moves until the refresh and that the refresh
//! reads what git reads.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const testgit = @import("testgit.zig");
const repo_mod = @import("repo.zig");

const Repository = repo_mod.Repository;
const testing = std.testing;

fn expectValue(repo: *const Repository, name: []const u8, want: ?[]const u8) !void {
    const got = repo.config.get(name);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "another process's git config is seen after refreshConfig, and not before" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "core.autocrlf", "input" });

    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    try expectValue(&repo, "core.autocrlf", "input");
    try testing.expect(!try repo.refreshConfig(io));

    // `input` and `false` are the same length, and the write lands inside
    // the second the file was read in: a stat on a file system that records
    // whole seconds would call the file unchanged.
    try git.exec(io, &.{ "config", "core.autocrlf", "false" });
    try git.exec(io, &.{ "config", "user.name", "Ada" });
    try expectValue(&repo, "core.autocrlf", "input");
    try testing.expect(try repo.config.isStale(io));

    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "core.autocrlf", "false");
    try expectValue(&repo, "user.name", "Ada");
    try testing.expect(!try repo.refreshConfig(io));

    try git.exec(io, &.{ "config", "--unset", "user.name" });
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "user.name", null);
}

test "an include that appears later and a worktree file the extension turns on are read by a refresh" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "include.path", "extra.config" });

    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    try expectValue(&repo, "fixture.value", null);

    try git.writeFile(io, ".git/extra.config", "[fixture]\n\tvalue = included\n");
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "fixture.value", "included");
    const read = try git.line(io, &.{ "config", "fixture.value" });
    defer gpa.free(read);
    try testing.expectEqualStrings(read, repo.config.get("fixture.value").?);

    try git.exec(io, &.{ "config", "extensions.worktreeConfig", "true" });
    try git.exec(io, &.{ "config", "--worktree", "fixture.scoped", "here" });
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "fixture.scoped", "here");
    try testing.expectEqual(.worktree, repo.config.origin("fixture.scoped").?.level);

    // A file the extension brought in is watched like the others.
    try git.exec(io, &.{ "config", "--worktree", "fixture.scoped", "there" });
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "fixture.scoped", "there");
}

test "a global file the caller named is read again, whether or not it was there at open" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var home = testing.tmpDir(.{});
    defer home.cleanup();

    var repo = try Repository.open(gpa, io, git.dir, .{
        .discover = false,
        .global_config = .{ .dir = home.dir, .sub_path = ".gitconfig" },
    });
    defer repo.deinit(io);
    try expectValue(&repo, "user.email", null);

    try home.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = "[user]\n\temail = ada@example.com\n" });
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "user.email", "ada@example.com");

    try home.dir.deleteFile(io, ".gitconfig");
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "user.email", null);
}

test "a configuration the repository can no longer be opened with is refused, and the one held is kept" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "user.name", "Ada" });

    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);

    // git itself will not run in a repository with an extension it does
    // not know, so the file is edited by name.
    try git.exec(io, &.{ "config", "-f", ".git/config", "core.repositoryformatversion", "1" });
    try git.exec(io, &.{ "config", "-f", ".git/config", "extensions.somethingNew", "true" });
    try git.exec(io, &.{ "config", "-f", ".git/config", "user.name", "Grace" });
    try testing.expectError(error.UnsupportedExtension, repo.refreshConfig(io));
    try testing.expectEqualStrings("somethingnew", repo.unsupportedSetting());
    try expectValue(&repo, "user.name", "Ada");

    try git.exec(io, &.{ "config", "-f", ".git/config", "--unset", "extensions.somethingNew" });
    try git.exec(io, &.{ "config", "-f", ".git/config", "extensions.objectFormat", "sha256" });
    try testing.expectError(error.ObjectFormatChanged, repo.refreshConfig(io));
    try expectValue(&repo, "user.name", "Ada");

    try git.exec(io, &.{ "config", "-f", ".git/config", "--unset", "extensions.objectFormat" });
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "user.name", "Grace");
}

/// `git` run in `cwd` with `home` as its `HOME` and no system file, so the
/// `~/.gitconfig` it reads is the test's own. Its output, trimmed, or
/// `null` when it exits non-zero, which is what `git config --get` does
/// for a name that is not set.
fn gitWithHome(gpa: std.mem.Allocator, io: Io, cwd: Io.Dir, home: []const u8, args: []const []const u8) !?[]u8 {
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const path = testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try environ.put("PATH", path);
    try environ.put("HOME", home);
    try environ.put("GIT_CONFIG_NOSYSTEM", "1");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false" });
    try argv.appendSlice(gpa, args);
    const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = cwd }, .environ_map = &environ });
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return error.GitFailed,
    }
    return try gpa.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\n"));
}

/// Every `test.*` value git reads in `proj` against what the repository
/// holds, one by one.
fn expectIncludesAgree(gpa: std.mem.Allocator, io: Io, proj: Io.Dir, home: []const u8, repo: *const Repository) !void {
    const names = [_][]const u8{ "test.work", "test.icase", "test.never", "test.main", "test.feature", "test.local" };
    for (names) |name| {
        const theirs = try gitWithHome(gpa, io, proj, home, &.{ "config", "--get", name });
        defer if (theirs) |t| gpa.free(t);
        const ours = repo.config.get(name);
        if ((theirs == null) != (ours == null) or (theirs != null and !std.mem.eql(u8, theirs.?, ours.?))) {
            std.debug.print("{s}: git reads {?s}, this reads {?s}\n", .{ name, theirs, ours });
            return error.TestExpectedEqual;
        }
    }
}

test "includeIf gitdir:, gitdir/i: and onbranch: in ~/.gitconfig hold for a repository as they hold for git" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var home_buf: [4096]u8 = undefined;
    const home = home_buf[0..try home_tmp.dir.realPath(io, &home_buf)];

    try home_tmp.dir.createDirPath(io, "work/proj");
    var proj = try home_tmp.dir.openDir(io, "work/proj", .{ .iterate = true });
    defer proj.close(io);
    const inited = try gitWithHome(gpa, io, proj, home, &.{ "init", "-q", "-b", "main" });
    gpa.free(inited.?);

    try home_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = "[includeIf \"gitdir:~/work/\"]\n\tpath = ~/.gitconfig-work\n" ++
        "[includeIf \"gitdir/i:~/WORK/PROJ/.git\"]\n\tpath = .gitconfig-icase\n" ++
        "[includeIf \"gitdir:~/elsewhere/\"]\n\tpath = ~/.gitconfig-never\n" ++
        "[includeIf \"onbranch:main\"]\n\tpath = ~/.gitconfig-main\n" ++
        "[includeIf \"onbranch:feature/\"]\n\tpath = ~/.gitconfig-feature\n" });
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig-work", .data = "[test]\n\twork = yes\n" });
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig-icase", .data = "[test]\n\ticase = yes\n" });
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig-never", .data = "[test]\n\tnever = yes\n" });
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig-main", .data = "[test]\n\tmain = yes\n" });
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig-feature", .data = "[test]\n\tfeature = yes\n" });
    // The repository's own file may carry one too.
    try proj.writeFile(io, .{ .sub_path = ".git/local-include", .data = "[test]\n\tlocal = yes\n" });
    const set = try gitWithHome(gpa, io, proj, home, &.{ "config", "includeIf.onbranch:main.path", "local-include" });
    gpa.free(set.?);

    var repo = try Repository.open(gpa, io, proj, .{
        .discover = false,
        .global_config = .{ .dir = home_tmp.dir, .sub_path = ".gitconfig" },
        .home = home,
    });
    defer repo.deinit(io);
    try expectValue(&repo, "test.work", "yes");
    try expectValue(&repo, "test.icase", "yes");
    try expectValue(&repo, "test.main", "yes");
    try expectIncludesAgree(gpa, io, proj, home, &repo);

    // Another branch: no file changed, and the refresh still reads again.
    const committed = try gitWithHome(gpa, io, proj, home, &.{ "commit", "-q", "--allow-empty", "-m", "base" });
    gpa.free(committed.?);
    const switched = try gitWithHome(gpa, io, proj, home, &.{ "checkout", "-q", "-b", "feature/x" });
    gpa.free(switched.?);
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "test.main", null);
    try expectValue(&repo, "test.feature", "yes");
    try expectIncludesAgree(gpa, io, proj, home, &repo);
    try testing.expect(!try repo.refreshConfig(io));

    // A detached `HEAD` is on no branch.
    const detached = try gitWithHome(gpa, io, proj, home, &.{ "checkout", "-q", "--detach" });
    gpa.free(detached.?);
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "test.feature", null);
    try expectIncludesAgree(gpa, io, proj, home, &repo);
}
