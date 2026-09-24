//! A clone reads the person's own configuration as git's does: the filters
//! `git lfs install` put in `~/.gitconfig` run during the checkout, with no
//! setting in the new repository.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const clone_mod = @import("clone.zig");
const object = @import("object.zig");
const userconfig = @import("userconfig.zig");
const testlfs = @import("testlfs.zig");
const lfstest = @import("lfstransfer_test.zig");
const testremote = @import("testremote.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

test "a clone checks out through the filters the person's ~/.gitconfig names, as git clone does with git-lfs installed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try lfstest.Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = "a large file, kept by LFS\n";
    {
        var seed = try fx.workRepo("seed", nobody);
        defer seed.close(io);
        try seed.writeFile(io, .{ .sub_path = ".gitattributes", .data = lfstest.attributes });
        try seed.writeFile(io, .{ .sub_path = "a.bin", .data = content });
        try fx.gitIn(seed, &.{ "add", "-A" });
        try fx.gitIn(seed, &.{ "commit", "-q", "-m", "files" });
        try fx.gitIn(seed, &.{ "lfs", "push", "origin", "main" });
        try fx.gitIn(seed, &.{ "push", "-q", "--no-verify", "origin", "main" });
    }
    // What `git lfs install` writes, in the person's own file and nowhere
    // else.
    for ([_][2][]const u8{
        .{ "filter.lfs.clean", "git-lfs clean -- %f" },
        .{ "filter.lfs.smudge", "git-lfs smudge -- %f" },
        .{ "filter.lfs.process", "git-lfs filter-process" },
        .{ "filter.lfs.required", "true" },
    }) |kv| try fx.gitIn(fx.tmp.dir, &.{ "config", "--global", kv[0], kv[1] });
    const url = try fx.url();
    defer gpa.free(url);

    // git's clone runs git-lfs's smudge from those filters.
    const by_git = try fx.path("by-git");
    defer gpa.free(by_git);
    try fx.gitIn(fx.tmp.dir, &.{ "clone", "-q", url, by_git });
    var git_dir = try fx.tmp.dir.openDir(io, "by-git", .{});
    defer git_dir.close(io);
    const theirs = try git_dir.readFileAlloc(io, "a.bin", gpa, .limited(1 << 20));
    defer gpa.free(theirs);
    try testing.expectEqualStrings(content, theirs);

    // relic's, handed the same person's configuration, checks out the same
    // file, and git finds the checkout clean.
    var locations = try userconfig.locate(gpa, io, &fx.env, fx.programs());
    defer locations.deinit();
    {
        var d = try fx.dir("by-relic");
        defer d.close(io);
        var repo = try clone_mod.clone(gpa, io, url, d, .{
            .who = test_who,
            .programs = fx.programs(),
            .user_config = locations.sources(),
            .home = locations.home,
        });
        defer repo.deinit(io);
        const ours = try d.readFileAlloc(io, "a.bin", gpa, .limited(1 << 20));
        defer gpa.free(ours);
        try testing.expectEqualStrings(content, ours);
        try testing.expect(repo.config.get("filter.lfs.process") != null);
        const status = try fx.gitOut(d, &.{ "status", "--porcelain" });
        defer gpa.free(status);
        try testing.expectEqualStrings("", status);
        // Nothing of the person's was written into the new repository.
        const local = try d.readFileAlloc(io, ".git/config", gpa, .limited(1 << 20));
        defer gpa.free(local);
        try testing.expect(std.mem.indexOf(u8, local, "filter") == null);
    }

    // Without it, the pointer is checked out, as git without git-lfs's
    // filters leaves it.
    {
        var d = try fx.dir("without");
        defer d.close(io);
        var repo = try clone_mod.clone(gpa, io, url, d, .{ .who = test_who, .programs = fx.programs() });
        defer repo.deinit(io);
        const ours = try d.readFileAlloc(io, "a.bin", gpa, .limited(1 << 20));
        defer gpa.free(ours);
        try testing.expect(std.mem.startsWith(u8, ours, "version https://git-lfs.github.com/spec/v1\n"));
    }
}

test "a clone given no settings of its own reaches the remote with the person's, as git clone does" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    // Only the person's own file says how to reach the remote.
    const text = try std.fmt.allocPrint(gpa, "[core]\n\tsshCommand = {s}\n", .{fake});
    defer gpa.free(text);
    try root.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = text });
    const url = try std.fmt.allocPrint(gpa, "ssh://example.invalid{s}/repo.git", .{root_path});
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
    try testing.expectEqualStrings(fake, repo.config.get("core.sshCommand").?);
    const local = try d.readFileAlloc(io, ".git/config", gpa, .limited(1 << 20));
    defer gpa.free(local);
    try testing.expect(std.mem.indexOf(u8, local, "sshCommand") == null);
}

test "a clone goes where url.<base>.insteadOf sends it and records the URL as given, as git clone does" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    // The person's own file names a short form for the server.
    const text = try std.fmt.allocPrint(gpa, "[url \"file://{s}/\"]\n\tinsteadOf = here:\n", .{root_path});
    defer gpa.free(text);
    try root.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = text });
    const global = try std.fmt.allocPrint(gpa, "{s}/gitconfig", .{root_path});
    defer gpa.free(global);
    try env.put("GIT_CONFIG_GLOBAL", global);

    const by_git = try std.fmt.allocPrint(gpa, "{s}/by-git", .{root_path});
    defer gpa.free(by_git);
    const cloned = try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "clone", "-q", "here:repo.git", by_git }, "", true);
    gpa.free(cloned);
    try root.dir.createDirPath(io, "by-relic");
    var d = try root.dir.openDir(io, "by-relic", .{ .iterate = true });
    defer d.close(io);
    var repo = try clone_mod.clone(gpa, io, "here:repo.git", d, .{
        .who = test_who,
        .programs = .{ .environ = &env },
        .user_config = .{ .global = .{ .dir = root.dir, .sub_path = "gitconfig" } },
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
