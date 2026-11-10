//! A clone reads the person's own configuration as git's does: the remote
//! reached with the person's settings, where `url.<base>.insteadOf` sends
//! it. The filters `git lfs install` puts in `~/.gitconfig` are LFS's tests'
//! (`lfs/clone_config_test.zig`).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const clone_mod = @import("../transport/clone.zig");
const object = @import("../object/object.zig");
const testremote = @import("remote.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

test "a clone given no settings of its own reaches the remote with the person's, as git clone does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var source = try testremote.historyRepo(gpa, io, 3);
    defer source.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const bare = try gpa.print("{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    // Only the person's own file says how to reach the remote.
    const text = try gpa.print("[core]\n\tsshCommand = {s}\n", .{fake});
    defer gpa.free(text);
    try root.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = text });
    const url = try gpa.print("ssh://example.invalid{s}{s}/repo.git", .{ if (builtin.target.os.tag == .windows) "/" else "", root_path });
    defer gpa.free(url);

    try root.dir.createDirPath(io, "by-relic");
    var d = try root.dir.openDir(io, "by-relic", .{ .iterate = true });
    defer d.close(io);
    var repo = try clone_mod.clone(gpa, io, url, d, .{
        .who = test_who,
        .programs = .{ .environ = &env },
        .user_config = .{ .global = .{ .dir = root.dir, .sub_path = "gitconfig" } },
    });
    defer repo.deinit(io);
    const theirs = try source.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(theirs);
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings(theirs, head.oid.hex(&hex));
    // The setting was read, not written into the new repository.
    try testing.expectEqualStrings(fake, repo.configuration().get("core.sshCommand").?);
    const local = try d.readFileAlloc(io, ".git/config", gpa, .limited(1 << 20));
    defer gpa.free(local);
    try testing.expect(std.mem.find(u8, local, "sshCommand") == null);
}

test "a clone goes where url.<base>.insteadOf sends it and records the URL as given, as git clone does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const bare = try gpa.print("{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    // The person's own file names a short form for the server. It is the
    // home's `.gitconfig`, named by `GIT_CONFIG_GLOBAL` as well as found
    // through `HOME`.
    const url_root = try gpa.dupe(u8, root_path);
    defer gpa.free(url_root);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, url_root, '\\', '/');
    const text = try gpa.print("[url \"file://{s}/\"]\n\tinsteadOf = here:\n", .{url_root});
    defer gpa.free(text);
    try root.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = text });
    const global = try gpa.print("{s}/.gitconfig", .{root_path});
    defer gpa.free(global);
    try env.put("GIT_CONFIG_GLOBAL", global);
    try env.put("HOME", root_path);

    const by_git = try gpa.print("{s}/by-git", .{root_path});
    defer gpa.free(by_git);
    const cloned = try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "clone", "-q", "here:repo.git", by_git }, "", true);
    gpa.free(cloned);
    try root.dir.createDirPath(io, "by-relic");
    var d = try root.dir.openDir(io, "by-relic", .{ .iterate = true });
    defer d.close(io);
    var repo = try clone_mod.clone(gpa, io, "here:repo.git", d, .{
        .who = test_who,
        .programs = .{ .environ = &env },
        .user_config = .{ .global = .{ .dir = root.dir, .sub_path = ".gitconfig" } },
    });
    defer repo.deinit(io);
    var git_dir = try root.dir.openDir(io, "by-git", .{});
    defer git_dir.close(io);
    for ([_][]const []const u8{
        &.{ "config", "--local", "remote.origin.url" },
        &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
        &.{ "status", "--porcelain" },
    }) |args| {
        const theirs = try testremote.gitInputEnv(gpa, io, git_dir, &env, args, "", true);
        defer gpa.free(theirs);
        const ours = try testremote.gitInputEnv(gpa, io, d, &env, args, "", true);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
}
