//! Submodule names: a `.gitmodules` name is a path under `.git/modules`,
//! so `../` in one puts a submodule's repository -- and its hooks --
//! anywhere, and a name inside another's (`a` and `a/hooks`) shares its
//! files. The owners are `submodule/gitmodules.zig` (the architecture's
//! `config/`) for the name rule, `submodule.zig` for the `modules/<name>`
//! layout, and `worktree/safepath.zig` with `object/fsck.zig` for a
//! `.gitmodules` that is a symbolic link.

const std = @import("std");
const path_mod = @import("../../names/path.zig");
const Io = std.Io;

const gitmodules = @import("../../config/gitmodules.zig");
const submodule = @import("../../submodule/submodule.zig");
const fsck = @import("../../object/fsck.zig");
const repo_mod = @import("../../repo/repo.zig");
const hostile = @import("hostile.zig");
const testgit = @import("../git.zig");

test "CVE-2018-11235, t7450-bad-git-dotfiles 'check names', 'fsck detects evil superproject' and 'refuse to load symlinked .gitmodules into index'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "valid", "valid/with/paths" }) |name| try std.testing.expect(gitmodules.checkName(name));
    for ([_][]const u8{ "", "../foo", "/../foo", "..\\foo", "\\..\\foo", "foo/..", "foo/../", "foo\\..", "foo\\..\\", "foo/../bar" }) |name| {
        try std.testing.expect(!gitmodules.checkName(name));
    }

    // An evil name is left out of what is read, and named.
    const evil = "[submodule \"../../modules/evil\"]\n\tpath = modules\n\turl = ./innocent\n";
    var parsed = try gitmodules.Gitmodules.parse(gpa, evil);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.submodules.len);
    try std.testing.expectEqual(gitmodules.Reason.suspicious_name, parsed.refused[0].reason);
    const finding = (try fsck.checkBlob(gpa, &fsck.baseline, .{ .oid = .zero(.sha1), .as = .modules, .bytes = evil }, .{ .sink = null })).?;
    try std.testing.expectEqual(fsck.Problem.gitmodules_name, finding.problem.?);

    // A `.gitmodules` that is a link: fsck names it, checkout refuses it.
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const target = try h.blob(io, "../../../../etc/passwd");
    for ([_][]const u8{ ".gitmodules", ".GITMODULES", "gitmod~1" }) |name| {
        const bytes = try hostile.treeBytes(gpa, &.{.{ .mode = "120000", .name = name, .oid = target }});
        defer gpa.free(bytes);
        const symlink = (try fsck.checkObject(gpa, &fsck.baseline, .{ .kind = .sha1, .oid = .zero(.sha1), .type = .tree, .bytes = bytes }, .{ .found = null, .sink = null })).?;
        try std.testing.expectEqual(fsck.Problem.gitmodules_symlink, symlink.problem.?);
        const tree = try h.writeTree(gpa, io, &.{.{ .mode = "120000", .name = name, .oid = target }});
        try std.testing.expectEqual(path_mod.Reason.symlinked_gitmodules, (try h.checkout(gpa, io, tree)).?);
    }
}

test "CVE-2019-1387, t7450-bad-git-dotfiles 'git dirs of sibling submodules must not be nested': a submodule's repository is never made inside another's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var nested = try testgit.Repo.init(gpa, io, &.{});
    defer nested.deinit();
    try nested.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "nested" });
    try nested.writeFile(io, ".gitmodules", "[submodule \"hippo\"]\n\turl = .\n\tpath = thing1\n[submodule \"hippo/hooks\"]\n\turl = .\n\tpath = thing2\n");
    const head = try nested.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const thing1 = try gpa.print("160000,{s},thing1", .{head});
    defer gpa.free(thing1);
    const thing2 = try gpa.print("160000,{s},thing2", .{head});
    defer gpa.free(thing2);
    try nested.exec(io, &.{ "update-index", "--add", "--cacheinfo", thing1, "--cacheinfo", thing2 });
    try nested.exec(io, &.{ "add", ".gitmodules" });
    try nested.exec(io, &.{ "commit", "-q", "-m", "nested" });
    const nested_path = try nested.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(nested_path);

    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    try owner.exec(io, &.{ "clone", "-q", nested_path, "c" });
    var c = owner;
    c.dir = try owner.dir.openDir(io, "c", .{ .iterate = true });
    defer c.dir.close(io);
    var repo = try repo_mod.Repository.open(gpa, io, c.dir, .{ .discover = false });
    defer repo.deinit(io);
    var t: hostile.GitClone = .{ .git = &c };
    if (submodule.update(gpa, io, &repo, .{ .init = true, .transport = t.seam() })) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.GitDirInsideGitDir, error.TransportFailed => {},
        else => return err,
    }
    // Never both: the one inside the other is not made.
    const outer = if (c.dir.access(io, ".git/modules/hippo/HEAD", .{})) true else |_| false;
    const inner = if (c.dir.access(io, ".git/modules/hippo/hooks/HEAD", .{})) true else |_| false;
    try std.testing.expect(!(outer and inner));
}
