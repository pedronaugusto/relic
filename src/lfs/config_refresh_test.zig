//! What an LFS server teaches a client is written to the repository's
//! configuration as a refresh-aware write: another process's settings kept,
//! a value set in memory never written.

const std = @import("std");
const testing = std.testing;

const core = @import("relic_core");
const Repository = core.repo.Repository;
const testgit = @import("../testing/git.zig");
const lfsapi = @import("api.zig");
const lfs_settings = @import("settings.zig");

fn expectValue(repo: *const Repository, name: []const u8, want: ?[]const u8) !void {
    const got = repo.configuration().get(name);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "what an LFS server teaches is written without another process's settings lost or memory's written" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    try repo.editConfig(io, &.{.{ .name = "fixture.memory", .value = "only" }}, .{});
    try git.exec(io, &.{ "config", "fixture.external", "yes" });
    const settings: lfs_settings.Settings = .{ .gpa = gpa, .config = repo.configuration() };
    var client = try lfsapi.Client.open(gpa, io, &settings, .{ .remote = "origin", .where = .{}, .reach = .{} });
    defer client.deinit(io);
    try client.learnLocksVerify(io, "https://example.com/project", false);
    try client.remember(io, &repo);
    const file = try git.run(io, &.{ "config", "--file", ".git/config", "--get-regexp", "^(fixture|lfs)\\." });
    defer gpa.free(file);
    try testing.expectEqualStrings("fixture.external yes\nlfs.https://example.com/project.locksverify false\n", file);
    try expectValue(&repo, "lfs.https://example.com/project.locksverify", "false");
    try expectValue(&repo, "fixture.memory", "only");
}
