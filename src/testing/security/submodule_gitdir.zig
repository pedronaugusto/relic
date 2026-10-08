//! Submodule git directories: a submodule cloned into a path that already
//! holds files -- put there by a checkout that a short name or a stripped
//! trailing dot made land in the same place -- so that two submodules, or
//! a submodule and the superproject's own files, share one directory. The
//! owner is `submodule.zig`'s populate, which clones only into a path that
//! is new or empty, and `worktree/safepath.zig` for the names that alias
//! one another.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const submodule = @import("../../submodule/submodule.zig");
const repo_mod = @import("../../repo/repo.zig");
const safepath = @import("../../names/path.zig");
const hostile = @import("hostile.zig");
const testgit = @import("../git.zig");

test "CVE-2019-1349, t7450-bad-git-dotfiles 'prevent git~1 squatting on Windows': a submodule is not cloned into a path that already holds files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // On Windows the squatting paths themselves are refused: `d\a` is a
    // path and `d.` is `d`.
    if (builtin.target.os.tag == .windows) {
        try std.testing.expectEqual(safepath.Reason.separator_inside_component, safepath.check("d\\a", .worktree).?.reason);
        try std.testing.expectEqual(safepath.Reason.trailing_dot_or_space, safepath.check("d./a/x", .worktree).?.reason);
    }
    // Everywhere: files already in the submodule's path, as the aliased
    // checkout leaves them, keep the clone out.
    var upstream = try testgit.Repo.init(gpa, io, &.{});
    defer upstream.deinit();
    try upstream.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "initial" });
    const upstream_path = try upstream.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(upstream_path);
    var squatting = try testgit.Repo.init(gpa, io, &.{});
    defer squatting.deinit();
    try squatting.exec(io, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream_path, "d/a" });
    try squatting.exec(io, &.{ "commit", "-q", "-m", "module" });
    const squatting_path = try squatting.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(squatting_path);

    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    try owner.exec(io, &.{ "clone", "-q", squatting_path, "c" });
    var c = owner;
    c.dir = try owner.dir.openDir(io, "c", .{ .iterate = true });
    defer c.dir.close(io);
    try c.writeFile(io, "d/a/..git", "");
    try c.writeFile(io, "d/a/x", "x\n");

    var repo = try repo_mod.Repository.open(gpa, io, c.dir, .{ .discover = false });
    defer repo.deinit(io);
    var t: hostile.GitClone = .{ .git = &c };
    var refusal: submodule.Refusal = .{};
    try std.testing.expectError(error.DirectoryNotEmpty, submodule.update(gpa, io, &repo, .{ .init = true, .transport = t.seam(), .refusal = &refusal }));
    try std.testing.expectEqualStrings("d/a", refusal.path());
    try std.testing.expectEqual(@as(u32, 0), t.clones);
    try std.testing.expectError(error.FileNotFound, c.dir.access(io, "d/a/.git", .{}));
    try std.testing.expectError(error.FileNotFound, c.dir.access(io, ".git/modules/d/a", .{}));
}
