//! A clone reads the person's own configuration as git's does: the filters
//! `git lfs install` put in `~/.gitconfig` run during the checkout, with no
//! setting in the new repository.

const std = @import("std");
const testing = std.testing;

const core = @import("relic_core");
const clone_mod = core.transport.clone;
const object = core.object;
const user_config = core.config.user;
const testlfs = @import("../testing/lfs.zig");
const lfstest = @import("transfer_test.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

test "a clone checks out through the filters the person's ~/.gitconfig names, as git clone does with git-lfs installed" {
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
    var locations = try user_config.locate(gpa, io, &fx.env, fx.programs());
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
        try testing.expect(repo.configuration().get("filter.lfs.process") != null);
        const status = try fx.gitOut(d, &.{ "status", "--porcelain" });
        defer gpa.free(status);
        try testing.expectEqualStrings("", status);
        // Nothing of the person's was written into the new repository.
        const local = try d.readFileAlloc(io, ".git/config", gpa, .limited(1 << 20));
        defer gpa.free(local);
        try testing.expect(std.mem.find(u8, local, "filter") == null);
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
