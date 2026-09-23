//! Test-only: the remotes the suite starts for itself.
//!
//! No test reaches a network it did not make. A remote here is git's own
//! programs on this machine: `git http-backend` behind an HTTP server the
//! test listens with on 127.0.0.1, `git-upload-pack` and `git-receive-pack`
//! behind a stand-in for `ssh` that ignores the host, and git fed on its
//! standard input when a fixture needs a pack made to order. The library
//! reaches all of them through the same code a real remote meets.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const program = @import("program.zig");
const testgit = @import("testgit.zig");

/// The environment a program started by a test sees: the test's own `PATH`
/// and nothing else, so a person's settings cannot reach a fixture.
pub fn environ(gpa: Allocator) !Environ.Map {
    var map: Environ.Map = .init(gpa);
    errdefer map.deinit();
    const path = std.testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try map.put("PATH", path);
    // git refuses to run with no idea of a home directory on some systems;
    // one that holds nothing is enough.
    try map.put("HOME", if (builtin.os.tag == .windows) "C:\\" else "/nonexistent");
    try map.put("GIT_CONFIG_NOSYSTEM", "1");
    return map;
}

/// Run `git` in `dir` with `input` on its standard input and the fixture
/// settings in front of `args`. The output is the caller's; a non-zero exit
/// is `error.GitFailed`, with git's diagnostics printed.
pub fn gitInput(gpa: Allocator, io: Io, dir: Io.Dir, args: []const []const u8, input: []const u8) ![]u8 {
    try testgit.requireGit(gpa, io);
    var env = try environ(gpa);
    defer env.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, &testgit.default_settings);
    try argv.appendSlice(gpa, args);
    var outcome = try program.run(.{ .environ = &env }, gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
    }, input, .{});
    defer gpa.free(outcome.stderr);
    if (!outcome.succeeded()) {
        std.debug.print("git {s} failed:\n{s}\n", .{ args[0], outcome.stderr });
        gpa.free(outcome.stdout);
        return error.GitFailed;
    }
    return outcome.stdout;
}

/// The absolute path of `dir`. The result is the caller's.
pub fn absolutePath(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    const path = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    return gpa.dupe(u8, path);
}

/// A history in a real repository, for a remote to be fetched from: files
/// that change a little each commit, a directory, a branch, a lightweight
/// tag and annotated tags, one of them on a commit below a tip.
pub fn historyRepo(gpa: Allocator, io: Io, commits: usize) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    try addCommits(gpa, io, &repo, 0, commits);
    try repo.exec(io, &.{ "tag", "light" });
    try repo.exec(io, &.{ "tag", "-a", "v1", "-m", "version one" });
    try repo.exec(io, &.{ "tag", "-a", "old", "-m", "an old one", "HEAD~1" });
    try repo.exec(io, &.{ "branch", "side", "HEAD~1" });
    return repo;
}

/// Add `count` commits to `repo`'s current branch, numbered from `first`.
pub fn addCommits(gpa: Allocator, io: Io, repo: *testgit.Repo, first: usize, count: usize) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..40) |line| try text.print(gpa, "line {d} of a file that is long enough to delta well\n", .{line});
    for (first..first + count) |i| {
        try text.print(gpa, "change {d}\n", .{i});
        try repo.writeFile(io, "src/a.txt", text.items);
        try repo.writeFile(io, "docs/b.md", text.items[0 .. text.items.len / 2]);
        var name_buf: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&name_buf, "files/{d}.txt", .{i}), "new\n");
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) });
    }
}
