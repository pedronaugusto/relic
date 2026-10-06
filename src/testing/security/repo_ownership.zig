//! Repository ownership: a repository another user put where relic will
//! look for one -- `/tmp`, a shared drive, the source of a local clone --
//! whose configuration and hooks would then run as the person. The owners
//! are `repo.zig`'s open (the architecture's `discover/`) with
//! `repo/safe.zig`: the working tree, the `.git` file and the git
//! directory must each be the person's, or be named by `safe.directory`
//! in configuration the repository cannot write; a bare repository found
//! by discovery needs `safe.bareRepository`; and a local clone's source
//! is opened the same way.

const std = @import("std");
const Io = std.Io;

const repo_mod = @import("../../repo.zig");
const safe = @import("../../repo/safe.zig");
const local = @import("../../transport/local.zig");
const testgit = @import("../git.zig");

const Repository = repo_mod.Repository;

/// A scratch home whose `.gitconfig` is the global configuration.
const Home = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    fn init(gpa: std.mem.Allocator, io: Io) !Home {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .path = try tmp.dir.realPathFileAlloc(io, ".", gpa) };
    }

    fn deinit(h: *Home, gpa: std.mem.Allocator) void {
        gpa.free(h.path);
        h.tmp.cleanup();
        h.* = undefined;
    }

    fn global(h: *Home, io: Io, text: []const u8) !void {
        try h.tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = text });
    }

    fn options(h: *const Home, ownership: safe.Ownership) Repository.OpenOptions {
        return .{
            .global_config = .{ .dir = h.tmp.dir, .sub_path = ".gitconfig" },
            .home = h.path,
            .ownership = ownership,
            .discover = false,
        };
    }
};

/// Whether relic uses the repository at `dir` with `options`.
fn uses(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, options: Repository.OpenOptions) !bool {
    var repo = Repository.open(gpa, io, dir, options) catch |err| switch (err) {
        error.DubiousOwnership, error.ImplicitBareRepository => return false,
        else => return err,
    };
    repo.deinit(io);
    return true;
}

/// `safe.directory = <path>` for the global configuration.
fn safeDirectory(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) ![]u8 {
    const path = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const normal = try safe.normalize(gpa, path);
    defer gpa.free(normal);
    return std.fmt.allocPrint(gpa, "[safe]\n\tdirectory = {s}\n", .{normal});
}

test "CVE-2022-24765, t0033-safe-directory: a repository another user owns is used only where protected configuration names it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var home = try Home.init(gpa, io);
    defer home.deinit(gpa);
    try std.testing.expect(try uses(gpa, io, git.dir, home.options(.check)));
    try std.testing.expect(!try uses(gpa, io, git.dir, home.options(.assume_different)));
    const named = try safeDirectory(gpa, io, git.dir);
    defer gpa.free(named);
    try home.global(io, named);
    try std.testing.expect(try uses(gpa, io, git.dir, home.options(.assume_different)));
    try home.global(io, "[safe]\n\tdirectory = *\n");
    try std.testing.expect(try uses(gpa, io, git.dir, home.options(.assume_different)));
    // An empty value forgets the ones before it.
    try home.global(io, "[safe]\n\tdirectory = *\n\tdirectory =\n");
    try std.testing.expect(!try uses(gpa, io, git.dir, home.options(.assume_different)));
    // 'ignoring safe.directory in repo config': the repository cannot
    // vouch for itself.
    try home.global(io, "");
    try git.exec(io, &.{ "config", "safe.directory", "*" });
    try std.testing.expect(!try uses(gpa, io, git.dir, home.options(.assume_different)));
}

test "CVE-2022-29187, t0033-safe-directory and t0034-root-safe-directory: the .git file and the git directory it names are checked with the working tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    try owner.exec(io, &.{ "init", "-q", "--separate-git-dir", "separate.git", "work" });
    var work = try owner.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);
    var home = try Home.init(gpa, io);
    defer home.deinit(gpa);
    var found = home.options(.assume_different);
    found.discover = true;
    try std.testing.expect(!try uses(gpa, io, work, found));
    const named = try safeDirectory(gpa, io, work);
    defer gpa.free(named);
    try home.global(io, named);
    try std.testing.expect(try uses(gpa, io, work, found));
}

test "git 2.38.0 safe.bareRepository, t0035-safe-bare-repository: a bare repository found by discovery is used only when explicit or allowed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    try git.exec(io, &.{ "clone", "-q", "--bare", ".", "outer-repo/bare-repo" });
    var bare = try git.dir.openDir(io, "outer-repo/bare-repo", .{ .iterate = true });
    defer bare.close(io);
    var dot_git = try git.dir.openDir(io, ".git", .{ .iterate = true });
    defer dot_git.close(io);
    var home = try Home.init(gpa, io);
    defer home.deinit(gpa);
    var found = home.options(.check);
    found.discover = true;

    try home.global(io, "[safe]\n\tbareRepository = explicit\n");
    try std.testing.expect(!try uses(gpa, io, bare, found));
    // A `.git` directory is not an embedded bare repository.
    try std.testing.expect(try uses(gpa, io, dot_git, found));
    // Named outright, it is used.
    var explicit = found;
    explicit.explicit = true;
    try std.testing.expect(try uses(gpa, io, bare, explicit));
    // The repository's own configuration cannot allow itself.
    try git.exec(io, &.{ "-C", "outer-repo/bare-repo", "config", "safe.bareRepository", "all" });
    try std.testing.expect(!try uses(gpa, io, bare, found));
    try home.global(io, "[safe]\n\tbareRepository = all\n");
    try std.testing.expect(try uses(gpa, io, bare, found));
}

test "CVE-2024-32004, t0033-safe-directory 'local clone of unowned repo refused in unsafe directory': a local clone's source is checked before its configuration is read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    const path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var home = try Home.init(gpa, io);
    defer home.deinit(gpa);
    try std.testing.expectError(error.DubiousOwnership, local.Remote.openWith(gpa, io, path, home.options(.assume_different)));
    const named = try safeDirectory(gpa, io, source.dir);
    defer gpa.free(named);
    try home.global(io, named);
    var remote = try local.Remote.openWith(gpa, io, path, home.options(.assume_different));
    remote.deinit(io);
    // What a plain `open` does: the source is checked as the person's.
    var plain = try local.Remote.open(gpa, io, path);
    plain.deinit(io);
}
