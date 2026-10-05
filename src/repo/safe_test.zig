//! `safe.directory` and `safe.bareRepository` against git's: the same
//! repositories, the same settings, the same answer to whether a repository
//! may be used.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("../repo.zig");
const safe = @import("safe.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;

/// A scratch home whose `.gitconfig` is the global configuration both read.
const Home = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    fn init(gpa: Allocator, io: Io) !Home {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(h: *Home, gpa: Allocator) void {
        gpa.free(h.path);
        h.tmp.cleanup();
        h.* = undefined;
    }

    fn setGlobal(h: *Home, io: Io, text: []const u8) !void {
        try h.tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = text });
    }
};

/// Whether git, run in `dir` with `args` before `rev-parse --git-dir`, uses
/// a repository there.
fn gitUses(gpa: Allocator, io: Io, home: *const Home, dir: Io.Dir, assume_different: bool, args: []const []const u8) !bool {
    var env = try testgit.isolatedEnviron(gpa, home.path);
    defer env.deinit();
    const dir_path = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);
    try testgit.noRepositoryAbove(&env, dir_path);
    if (assume_different) try env.put("GIT_TEST_ASSUME_DIFFERENT_OWNER", "1");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);
    try argv.appendSlice(gpa, &.{ "rev-parse", "--git-dir" });
    const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = dir }, .environ_map = &env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Whether relic opens a repository at `dir` with the same settings.
fn relicUses(gpa: Allocator, io: Io, home: *const Home, dir: Io.Dir, assume_different: bool, overrides: []const []const u8, explicit: bool) !bool {
    var repo = Repository.open(gpa, io, dir, .{
        .global_config = .{ .dir = home.tmp.dir, .sub_path = ".gitconfig" },
        .home = home.path,
        .config_overrides = overrides,
        .ownership = if (assume_different) .assume_different else .check,
        .explicit = explicit,
        .discover = false,
    }) catch |err| switch (err) {
        error.DubiousOwnership, error.ImplicitBareRepository => return false,
        else => return err,
    };
    repo.deinit(io);
    return true;
}

fn expectSame(gpa: Allocator, io: Io, home: *const Home, dir: Io.Dir, assume_different: bool, overrides: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    for (overrides) |o| try args.appendSlice(gpa, &.{ "-c", o });
    const theirs = try gitUses(gpa, io, home, dir, assume_different, args.items);
    const ours = try relicUses(gpa, io, home, dir, assume_different, overrides, false);
    std.testing.expectEqual(theirs, ours) catch |err| {
        for (overrides) |o| std.debug.print("-c {s} ", .{o});
        std.debug.print("(assume different: {})\n", .{assume_different});
        return err;
    };
}

test "a repository another user owns is used only where safe.directory names it, as git's is" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!try testgit.gitAtLeast(gpa, io, 2, 46)) return error.SkipZigTest;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    try git.exec(io, &.{ "worktree", "add", "-q", "linked" });
    var home = try Home.init(gpa, io);
    defer home.deinit(gpa);
    const top = try git.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(top);
    const top_slash = try safe.normalize(gpa, top);
    defer gpa.free(top_slash);
    const linked = try std.fmt.allocPrint(gpa, "{s}/linked", .{top_slash});
    defer gpa.free(linked);
    const parent_star = try std.fmt.allocPrint(gpa, "{s}/*", .{std.fs.path.dirname(top_slash).?});
    defer gpa.free(parent_star);
    const own_star = try std.fmt.allocPrint(gpa, "{s}/*", .{top_slash});
    defer gpa.free(own_star);
    const elsewhere = try std.fmt.allocPrint(gpa, "{s}-elsewhere", .{top_slash});
    defer gpa.free(elsewhere);
    var linked_dir = try git.dir.openDir(io, "linked", .{ .iterate = true });
    defer linked_dir.close(io);

    for ([_]Io.Dir{ git.dir, linked_dir }) |dir| {
        // the current user's own repository needs no exception
        try expectSame(gpa, io, &home, dir, false, &.{});
        for ([_]?[]const u8{ null, "*", top_slash, linked, parent_star, own_star, elsewhere }) |value| {
            const global = if (value) |v| try std.fmt.allocPrint(gpa, "[safe]\n\tdirectory = {s}\n", .{v}) else try gpa.dupe(u8, "");
            defer gpa.free(global);
            try home.setGlobal(io, global);
            try expectSame(gpa, io, &home, dir, true, &.{});
            // an empty value forgets what came before it
            if (value) |v| {
                const reset = try std.fmt.allocPrint(gpa, "[safe]\n\tdirectory = {s}\n\tdirectory =\n", .{v});
                defer gpa.free(reset);
                try home.setGlobal(io, reset);
                try expectSame(gpa, io, &home, dir, true, &.{});
            }
        }
        try home.setGlobal(io, "");
        const on_command_line = try std.fmt.allocPrint(gpa, "safe.directory={s}", .{top_slash});
        defer gpa.free(on_command_line);
        try expectSame(gpa, io, &home, dir, true, &.{on_command_line});
        try expectSame(gpa, io, &home, dir, true, &.{"safe.directory=*"});
    }
    // the repository's own configuration cannot vouch for it
    try git.exec(io, &.{ "config", "safe.directory", "*" });
    try expectSame(gpa, io, &home, git.dir, true, &.{});
}

test "safe.bareRepository=explicit refuses a bare repository found by discovery, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!try testgit.gitAtLeast(gpa, io, 2, 46)) return error.SkipZigTest;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    try git.exec(io, &.{ "clone", "-q", "--bare", ".", "bare.git" });
    try git.exec(io, &.{ "worktree", "add", "-q", "linked" });
    var home = try Home.init(gpa, io);
    defer home.deinit(gpa);
    var bare = try git.dir.openDir(io, "bare.git", .{ .iterate = true });
    defer bare.close(io);
    var dot_git = try git.dir.openDir(io, ".git", .{ .iterate = true });
    defer dot_git.close(io);
    var admin = try git.dir.openDir(io, ".git/worktrees/linked", .{ .iterate = true });
    defer admin.close(io);
    for ([_][]const u8{ "", "[safe]\n\tbareRepository = all\n", "[safe]\n\tbareRepository = explicit\n" }) |global| {
        try home.setGlobal(io, global);
        for ([_]Io.Dir{ bare, dot_git, admin }) |dir| try expectSame(gpa, io, &home, dir, false, &.{});
        try expectSame(gpa, io, &home, bare, false, &.{"safe.bareRepository=all"});
    }
    // a git directory named outright is not checked
    try home.setGlobal(io, "[safe]\n\tbareRepository = explicit\n");
    try std.testing.expect(!try gitUses(gpa, io, &home, bare, false, &.{}));
    try std.testing.expect(try gitUses(gpa, io, &home, bare, false, &.{"--git-dir=."}));
    try std.testing.expect(try relicUses(gpa, io, &home, bare, false, &.{}, true));
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try std.testing.expectError(error.ImplicitBareRepository, Repository.open(gpa, io, bare, .{
        .global_config = .{ .dir = home.tmp.dir, .sub_path = ".gitconfig" },
        .home = home.path,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("safe.bareRepository", diagnostic.unsupported_setting);
}
