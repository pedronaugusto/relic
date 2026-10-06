//! Hooks written by a clone: git 2.39.4 added defence in depth around the
//! 2024 fixes -- no hooks while cloning, a protected `core.hooksPath` --
//! and took it back in 2.39.5 and 2.45.2 because it broke git-lfs and
//! git-annex. Its lesson is that the safety must come from checkout never
//! writing into `.git`, which `worktree.zig` (the architecture's
//! `checkout/`) refuses, and not from running no hook. relic's clone runs
//! none, and takes the person's `core.hooksPath` as git does.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const clone_mod = @import("../../transport/clone.zig");
const config_mod = @import("../../config.zig");
const object = @import("../../object.zig");
const testgit = @import("../git.zig");

test "git 2.39.4 defense-in-depth (reverted in 2.39.5 and 2.45.2), t5601-clone 'clone -c core.hooksPath=/dev/null works again'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "a", "one\n");
    try source.exec(io, &.{ "add", "a" });
    try source.exec(io, &.{ "commit", "-q", "-m", "one" });
    const path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);

    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    const owner_path = try owner.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(owner_path);
    // A hooks directory whose post-checkout leaves a mark: the person's
    // own, which git 2.45.2 runs after a clone's checkout and relic runs
    // no hook for at all.
    try owner.dir.createDirPath(io, "hooks");
    const marker = try std.fmt.allocPrint(gpa, "{s}/ran\n", .{owner_path});
    defer gpa.free(marker);
    try testgit.fixtureHook(gpa, io, owner.dir, "hooks/post-checkout", "record_stdin", marker);
    const null_device = if (builtin.os.tag == .windows) "NUL" else "/dev/null";
    for ([_][]const u8{ null_device, "hooks" }, [_][]const u8{ "c1", "c2" }) |hooks, name| {
        const hooks_path = if (std.mem.eql(u8, hooks, "hooks")) try std.fmt.allocPrint(gpa, "{s}/hooks", .{owner_path}) else try gpa.dupe(u8, hooks);
        defer gpa.free(hooks_path);
        const text = try std.fmt.allocPrint(gpa, "[core]\n\thooksPath = {s}\n", .{hooks_path});
        defer gpa.free(text);
        var config = try config_mod.Config.parseText(gpa, text, .local);
        defer config.deinit();
        try owner.dir.createDirPath(io, name);
        var target = try owner.dir.openDir(io, name, .{ .iterate = true });
        defer target.close(io);
        var env = try testgit.programEnviron(gpa);
        defer env.deinit();
        const who: object.Signature = .{ .name = "S", .email = "s@example.com", .when_secs = 1, .offset_minutes = 0 };
        var clone = try clone_mod.clone(gpa, io, path, target, .{ .who = who, .config = &config, .programs = .{ .environ = &env } });
        clone.deinit(io);
        try target.access(io, "a", .{});
        try std.testing.expectError(error.FileNotFound, owner.dir.access(io, "ran", .{}));
    }
}
