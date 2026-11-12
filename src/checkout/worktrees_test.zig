//! checkout/worktrees.zig under faults: a cancel while prune judges a worktree.
const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");
const testing_io = @import("../testing/io.zig");
const repo_mod = @import("../repo/repo.zig");
const worktrees = @import("worktrees.zig");
const prune = worktrees.prune;

test "a cancel that lands in judging a worktree to prune is returned, not taken for one to prune" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main");
    var main_dir = try tmp.dir.openDir(io, "main", .{ .iterate = true });
    defer main_dir.close(io);
    var repo = try repo_mod.Repository.create(gpa, io, main_dir, .{ .default_branch = "main" });
    defer repo.deinit(io);
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    // A worktree whose working tree is gone: one prune takes away.
    const gitdir_text = try std.mem.concat(gpa, u8, &.{ base, "/gone/.git\n" });
    defer gpa.free(gitdir_text);
    const Prune = struct {
        repo: *repo_mod.Repository,
        gitdir_text: []const u8,
        pub fn setUp(p: *@This(), _: *shakedown.FaultIo) !void {
            const real = std.testing.io;
            const common = p.repo.refStore().commonDir();
            try common.createDirPath(real, "worktrees/x");
            try common.writeFile(real, .{ .sub_path = "worktrees/x/gitdir", .data = p.gitdir_text });
        }
        pub fn run(p: *@This(), run_io: Io) !void {
            var outcome = try prune(std.testing.allocator, run_io, p.repo.refStore(), .{});
            outcome.deinit();
        }
        pub fn check(_: *@This(), check_io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
            try testing_io.cancelKept(check_io, result, injected);
        }
        pub fn tearDown(_: *@This()) void {}
    };
    var p: Prune = .{ .repo = &repo, .gitdir_text = gitdir_text };
    try testing_io.everyCancel(gpa, io, &p);
}
