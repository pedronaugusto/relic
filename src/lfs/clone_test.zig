//! A native LFS clone against git-lfs's server: content fetched during the
//! checkout, and pointers left by GIT_LFS_SKIP_SMUDGE.

const std = @import("std");
const transfer_test_mod = @import("transfer_test.zig");
const lfs_mod = @import("../testing/lfs.zig");
const lfs = @import("lfs.zig");
const clone = @import("clone.zig").clone;

test "native LFS clone fetches content and skip-smudge leaves pointers" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const lt = transfer_test_mod;
    const fx = try lt.Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const helper = try lfs_mod.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(helper);
    var source = try fx.workRepo("seed", helper);
    defer source.close(io);
    try source.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.bin filter=lfs\n" });
    try source.writeFile(io, .{ .sub_path = "one.bin", .data = "native clone payload\n" });
    try fx.gitIn(source, &.{ "add", "-A" });
    try fx.gitIn(source, &.{ "commit", "-q", "-m", "seed" });
    try fx.gitIn(source, &.{ "push", "-q", "--no-verify", "origin", "main" });
    var uploaded = try lt.relicUploadHead(fx, source, .{ .ref = "refs/heads/main" });
    defer uploaded.deinit();
    try testing.expectEqual(@as(usize, 0), uploaded.failures());
    const url = try fx.url();
    defer gpa.free(url);
    for ([_]bool{ false, true }) |skip| {
        const name = if (skip) "skip" else "native";
        try fx.tmp.dir.createDir(io, name, .default_dir);
        var target = try fx.tmp.dir.openDir(io, name, .{ .iterate = true });
        defer target.close(io);
        var env = try fx.env.clone(gpa);
        defer env.deinit();
        if (skip) try env.put("GIT_LFS_SKIP_SMUDGE", "1");
        var repository = try clone(gpa, io, url, target, .{
            .who = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 },
            .programs = .{ .environ = &env },
            .user_config = .{ .command = &.{ "filter.lfs.clean=git-lfs clean -- %f", "filter.lfs.smudge=git-lfs smudge -- %f", "filter.lfs.process=git-lfs filter-process" } },
        });
        defer repository.deinit(io);
        const bytes = try target.readFileAlloc(io, "one.bin", gpa, .limited(4096));
        defer gpa.free(bytes);
        if (skip) {
            const pointer = try lfs.Pointer.decode(bytes);
            try testing.expectEqual(@as(u64, "native clone payload\n".len), pointer.size);
        } else try testing.expectEqualStrings("native clone payload\n", bytes);
    }
}
