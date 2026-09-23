//! A repository held for days against a configuration another process
//! changes: `Repository.refreshConfig` against the real git.
//!
//! A `Repository` holds what its configuration files held at open. These
//! tests change them with `git config`, as a person in a terminal would,
//! and check that nothing moves until the refresh and that the refresh
//! reads what git reads.

const std = @import("std");
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
    try testing.expectEqualStrings("somethingNew", repo.unsupportedSetting());
    try expectValue(&repo, "user.name", "Ada");

    try git.exec(io, &.{ "config", "-f", ".git/config", "--unset", "extensions.somethingNew" });
    try git.exec(io, &.{ "config", "-f", ".git/config", "extensions.objectFormat", "sha256" });
    try testing.expectError(error.ObjectFormatChanged, repo.refreshConfig(io));
    try expectValue(&repo, "user.name", "Ada");

    try git.exec(io, &.{ "config", "-f", ".git/config", "--unset", "extensions.objectFormat" });
    try testing.expect(try repo.refreshConfig(io));
    try expectValue(&repo, "user.name", "Grace");
}
