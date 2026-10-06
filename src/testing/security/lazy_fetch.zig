//! Lazy fetches: a partial clone's missing object fetched, while serving
//! or reading it, from the promisor remote its own configuration names --
//! a program of the repository's choosing. relic fetches a promised object
//! only through a `partial.Lazy` the caller installs on its own repository
//! (`transport/partial.zig`); the source of a local clone and a repository
//! being served (`transport/local.zig`, `transport/uploadpack.zig`) are
//! opened with none.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;

const clone_mod = @import("../../transport/clone.zig");
const object = @import("../../object.zig");
const testgit = @import("../git.zig");

test "CVE-2024-32465, t0411-clone-from-partial 'local clone must not fetch from promisor remote and execute script' and 'clone from file://... must not fetch'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    const owner_path = try owner.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(owner_path);
    try owner.exec(io, &.{ "init", "-q", "tmp" });
    try owner.writeFile(io, "tmp/a.t", "a\n");
    try owner.exec(io, &.{ "-C", "tmp", "add", "a.t" });
    try owner.exec(io, &.{ "-C", "tmp", "commit", "-q", "-m", "a" });
    try owner.exec(io, &.{ "-C", "tmp", "config", "uploadpack.allowfilter", "1" });
    try owner.exec(io, &.{ "clone", "-q", "--filter=blob:none", "--no-local", "--no-checkout", "tmp", "evil" });
    try owner.dir.deleteTree(io, "tmp");
    // The promisor remote's upload-pack, were anything to ask it, leaves
    // a mark.
    const marker = try std.fmt.allocPrint(gpa, "{s}/script-executed", .{owner_path});
    defer gpa.free(marker);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, marker, '\\', '/');
    const args = try std.fmt.allocPrint(gpa, "record '{s}'", .{marker});
    defer gpa.free(args);
    const fake = try testgit.fixtureCommand(gpa, build_options.process_fixture_path, args);
    defer gpa.free(fake);
    try owner.exec(io, &.{ "-C", "evil", "config", "remote.origin.uploadpack", fake });

    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    const who: object.Signature = .{ .name = "S", .email = "s@example.com", .when_secs = 1, .offset_minutes = 0 };
    const evil = try std.fmt.allocPrint(gpa, "{s}/evil", .{owner_path});
    defer gpa.free(evil);
    const file_url = try std.fmt.allocPrint(gpa, "file://{s}{s}", .{ if (builtin.os.tag == .windows) "/" else "", evil });
    defer gpa.free(file_url);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, file_url, '\\', '/');
    for ([_][]const u8{ evil, file_url }, [_][]const u8{ "clone1", "clone2" }) |url, name| {
        try owner.dir.createDirPath(io, name);
        var target = try owner.dir.openDir(io, name, .{ .iterate = true });
        defer target.close(io);
        // The blobs are missing and nothing brings them: the clone fails,
        // or leaves them missing; it never runs the promisor's program.
        if (clone_mod.clone(gpa, io, url, target, .{ .who = who, .programs = .{ .environ = &env } })) |opened| {
            var repo = opened;
            repo.deinit(io);
        } else |_| {}
        try std.testing.expectError(error.FileNotFound, owner.dir.access(io, "script-executed", .{}));
    }
}
