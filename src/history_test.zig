//! History editing against the real git.
//!
//! Each test builds one fixture twice from the same script and the same
//! fixed dates, so the two repositories are the same object for object. git
//! runs in one copy and this package in the other, and then everything git
//! reads back is compared: commit names, `git ls-files --stage`, `git status
//! --porcelain=v2`, the files in the working tree, the state files and the
//! reflogs. Where an operation stops, each side is also made to finish what
//! the other started.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const merging = @import("merging.zig");
const rerere = @import("rerere.zig");
const worktree = @import("worktree.zig");
const threeway = @import("threeway.zig");
const ort = @import("ort.zig");

const Oid = hash.Oid;

/// The date every commit in a fixture is made at, and the one this package
/// is told, so a commit made on either side has the same name.
pub const when: i64 = 1_700_000_000;

/// The identity `testgit` gives git, at `when`.
pub const who: object.Signature = .{
    .name = "Fixture",
    .email = "fixture@example.com",
    .when_secs = when,
    .offset_minutes = 0,
};

/// A fixture built once for git and once for this package.
pub const Pair = struct {
    gpa: Allocator,
    env: std.process.Environ.Map,
    git: testgit.Repo,
    ours: testgit.Repo,

    /// Build both copies with `script`, with git's dates fixed at `when`.
    /// The pair must not move once built: each copy points at `env`.
    pub fn init(gpa: Allocator, io: Io, pair: *Pair, script: *const fn (*testgit.Repo, Io) anyerror!void) !void {
        pair.gpa = gpa;
        pair.env = try testgit.datedEnv(gpa, when);
        errdefer pair.env.deinit();
        // An editor that accepts what it is given, for a `git commit` or a
        // `git rebase --continue` that would open one.
        try pair.env.put("GIT_EDITOR", "true");
        pair.git = try testgit.Repo.init(gpa, io, &.{});
        errdefer pair.git.deinit();
        pair.git.environ = &pair.env;
        pair.ours = try testgit.Repo.init(gpa, io, &.{});
        errdefer pair.ours.deinit();
        pair.ours.environ = &pair.env;
        try script(&pair.git, io);
        try script(&pair.ours, io);
    }

    pub fn deinit(pair: *Pair) void {
        pair.ours.deinit();
        pair.git.deinit();
        pair.env.deinit();
    }

    /// Open this package's copy.
    pub fn open(pair: *Pair, io: Io) !repo_mod.Repository {
        return repo_mod.Repository.open(pair.gpa, io, pair.ours.dir, .{});
    }
};

/// Run `git` and keep going whatever it exits with; what it left is what is
/// compared.
pub fn gitMayFail(repo: *testgit.Repo, io: Io, args: []const []const u8) !void {
    const was = repo.report_failures;
    repo.report_failures = false;
    defer repo.report_failures = was;
    repo.exec(io, args) catch |err| switch (err) {
        error.GitFailed => {},
        else => |e| return e,
    };
}

fn expectSameOutput(gpa: Allocator, io: Io, a: *testgit.Repo, b: *testgit.Repo, args: []const []const u8) !void {
    const was_a = a.report_failures;
    const was_b = b.report_failures;
    a.report_failures = false;
    b.report_failures = false;
    defer a.report_failures = was_a;
    defer b.report_failures = was_b;
    const left = a.run(io, args) catch |err| switch (err) {
        error.GitFailed => try gpa.dupe(u8, "<failed>"),
        else => |e| return e,
    };
    defer gpa.free(left);
    const right = b.run(io, args) catch |err| switch (err) {
        error.GitFailed => try gpa.dupe(u8, "<failed>"),
        else => |e| return e,
    };
    defer gpa.free(right);
    std.testing.expectEqualStrings(left, right) catch |err| {
        std.debug.print("git {s} differs\n", .{args[0]});
        return err;
    };
}

fn readOrMissing(gpa: Allocator, io: Io, repo: *testgit.Repo, path: []const u8) ![]u8 {
    return repo.dir.readFileAlloc(io, path, gpa, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => gpa.dupe(u8, "<missing>"),
        // A submodule's checkout, which `git status` has already compared.
        error.IsDir => gpa.dupe(u8, "<directory>"),
        else => |e| return e,
    };
}

/// Everything git reads back, compared between the two copies: `HEAD` and
/// what it names, the index, the status, every tracked file, the files
/// under `.git` in `state`, and the logs in `logs`.
pub fn expectSameState(
    pair: *Pair,
    io: Io,
    state: []const []const u8,
    logs: []const []const u8,
) !void {
    const gpa = pair.gpa;
    // Whatever this package wrote, git finds nothing wrong with it.
    try pair.ours.exec(io, &.{ "fsck", "--strict", "--no-progress", "--no-dangling" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "rev-parse", "HEAD" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "symbolic-ref", "-q", "HEAD" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "ls-files", "--stage" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "ls-files", "--resolve-undo" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "status", "--porcelain=v2", "--untracked-files=all" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "log", "--format=%H %P%n%an <%ae> %ad%n%cn <%ce> %cd%n%B", "--date=raw", "-5" });

    const listing = try pair.git.run(io, &.{ "ls-files", "-z" });
    defer gpa.free(listing);
    var paths = std.mem.splitScalar(u8, listing, 0);
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        const left = try readOrMissing(gpa, io, &pair.git, path);
        defer gpa.free(left);
        const right = try readOrMissing(gpa, io, &pair.ours, path);
        defer gpa.free(right);
        std.testing.expectEqualStrings(left, right) catch |err| {
            std.debug.print("working tree file {s} differs\n", .{path});
            return err;
        };
    }
    for (state) |name| {
        const path = try std.fmt.allocPrint(gpa, ".git/{s}", .{name});
        defer gpa.free(path);
        const left = try readOrMissing(gpa, io, &pair.git, path);
        defer gpa.free(left);
        const right = try readOrMissing(gpa, io, &pair.ours, path);
        defer gpa.free(right);
        std.testing.expectEqualStrings(left, right) catch |err| {
            std.debug.print("state file {s} differs\n", .{name});
            return err;
        };
    }
    for (logs) |name| {
        const path = try std.fmt.allocPrint(gpa, ".git/logs/{s}", .{name});
        defer gpa.free(path);
        const left = try readOrMissing(gpa, io, &pair.git, path);
        defer gpa.free(left);
        const right = try readOrMissing(gpa, io, &pair.ours, path);
        defer gpa.free(right);
        std.testing.expectEqualStrings(left, right) catch |err| {
            std.debug.print("log {s} differs\n", .{name});
            return err;
        };
    }
}

//=========================================================================
// Merge
//=========================================================================

/// `main` and `topic` diverged from one base: `f` changed on both sides
/// in the same line, `t1` and `t3` added on `topic`, `m` added on `main`.
fn divergedScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "f", "a\nb\nc\n");
    try repo.writeFile(io, "shared", "1\n2\n3\n4\n5\n6\n7\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "t1", "1\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.writeFile(io, "f", "a\nT\nc\n");
    try repo.writeFile(io, "shared", "1\n2\n3\n4\n5\n6\nseven\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "two conflicting" });
    try repo.writeFile(io, "t3", "3\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "three" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "f", "a\nM\nc\n");
    try repo.writeFile(io, "shared", "one\n2\n3\n4\n5\n6\n7\n");
    try repo.writeFile(io, "m", "main\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "mainc" });
}

/// The same, with the conflicting change on `topic` left out, so that the
/// two branches merge cleanly.
fn cleanScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try divergedScript(repo, io);
    try repo.exec(io, &.{ "checkout", "-q", "-b", "clean", "topic~2" });
    try repo.writeFile(io, "t3", "3\n");
    try repo.writeFile(io, "shared", "1\n2\n3\n4\n5\n6\nseven\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "three again" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
}

const merge_state = [_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "ORIG_HEAD", "AUTO_MERGE" };
const main_logs = [_][]const u8{ "HEAD", "refs/heads/main" };

test "a conflicted merge stops exactly where git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    for ([_][]const u8{ "merge", "diff3", "zdiff3" }) |style| {
        try pair.git.exec(io, &.{ "config", "merge.conflictStyle", style });
        try pair.ours.exec(io, &.{ "config", "merge.conflictStyle", style });
        try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const target = try merging.resolve(gpa, io, &repo, "topic");
            var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
            defer outcome.deinit();
            try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
            try std.testing.expectEqual(@as(usize, 1), outcome.conflicts.len);
            try std.testing.expectEqualStrings("f", outcome.conflicts[0].path);
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);

        // Each side undoes its own merge, and they agree on what is left.
        try pair.git.exec(io, &.{ "merge", "--abort" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            try merging.abort(gpa, io, &repo, who, null);
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);
    }
}

test "a clean merge commits what git commits, and a fast-forward moves as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, cleanScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "merge", "--no-edit", "clean" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "clean");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);

    // A branch behind the merge fast-forwards to it.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "-b", "behind", "main~1" });
    try pair.git.exec(io, &.{ "merge", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "main");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.fast_forward, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/behind" });

    // Merging it again is nothing to do, on both sides.
    try pair.git.exec(io, &.{ "merge", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "main");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.up_to_date, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/behind" });

    // `--no-ff` makes a commit where a fast-forward would do, and into a
    // branch other than main the message names the branch.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "branch", "early", "topic~2" });
        try r.exec(io, &.{ "checkout", "-q", "-b", "feature", "main~1" });
    }
    try pair.git.exec(io, &.{ "merge", "--no-ff", "--no-edit", "early" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "early");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .fast_forward = .never });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/feature" });
}

test "a merge one side stopped is concluded by the other" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    // git stops, this concludes; this stops, git concludes.
    try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
    }
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    // The copies swap roles: the one git stopped is concluded here.
    const git_stopped = &pair.git;
    const ours_stopped = &pair.ours;
    try ours_stopped.exec(io, &.{ "merge", "--continue" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, git_stopped.dir, .{});
        defer repo.deinit(io);
        _ = try merging.conclude(gpa, io, &repo, .{ .who = who });
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

test "a merge that would overwrite a local change is refused, and one it does not touch survives" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, cleanScript);
    defer pair.deinit();

    // A change to a file the merge rewrites.
    try pair.ours.writeFile(io, "shared", "local\n");
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "clean");
        var blocked: threeway.Blocked = .{};
        try std.testing.expectError(error.LocalChangesWouldBeOverwritten, merging.start(gpa, io, &repo, target, .{ .who = who, .blocked = &blocked }));
        try std.testing.expectEqualStrings("shared", blocked.path());
    }
    const kept = try pair.ours.readFile(io, "shared");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("local\n", kept);

    // A change to a file it does not touch goes through the merge.
    try pair.ours.exec(io, &.{ "checkout", "--", "shared" });
    try pair.ours.writeFile(io, "m", "local main\n");
    try pair.git.writeFile(io, "m", "local main\n");
    try pair.git.exec(io, &.{ "merge", "--no-edit", "clean" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "clean");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

/// Two branches that merged each other, so a merge between their tips has
/// two merge bases, which merge cleanly into one; then both change the same
/// line of `f`.
fn crissCrossScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "f", "a\nb\nc\n");
    try repo.writeFile(io, "g", "1\n2\n3\n4\n5\n6\n7\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try repo.writeFile(io, "g", "1\n2\n3\n4\n5\n6\nseven\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "side g" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "g", "one\n2\n3\n4\n5\n6\n7\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "main g" });
    try repo.exec(io, &.{ "branch", "main-g" });
    try repo.exec(io, &.{ "merge", "-q", "--no-edit", "side" });
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.exec(io, &.{ "merge", "-q", "--no-edit", "main-g" });
    try repo.writeFile(io, "f", "a\nSIDE\nc\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "side f" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "f", "a\nMAIN\nc\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "main f" });
}

test "a criss-cross merge folds its two bases into one, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, crissCrossScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "merge.conflictStyle", "diff3" });
    try gitMayFail(&pair.git, io, &.{ "merge", "side" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "side");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
    const marked = try pair.ours.readFile(io, "f");
    defer gpa.free(marked);
    try std.testing.expect(std.mem.indexOf(u8, marked, "||||||| merged common ancestors\n") != null);
}

test "a signed-off merge with its own message, and one stopped before committing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, cleanScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "merge", "--no-commit", "clean" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "clean");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .commit = false });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.staged, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
    try pair.git.exec(io, &.{ "merge", "--abort" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try merging.abort(gpa, io, &repo, who, null);
    }

    try pair.git.exec(io, &.{ "merge", "--signoff", "-m", "Bring in the clean work\n\nBecause it is ready.", "clean" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "clean");
        var outcome = try merging.start(gpa, io, &repo, target, .{
            .who = who,
            .signoff = true,
            .message = "Bring in the clean work\n\nBecause it is ready.",
        });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

//=========================================================================
// Cherry-pick and revert
//=========================================================================

const sequencer = @import("sequencer.zig");

const pick_state = [_][]const u8{
    "sequencer/todo",   "sequencer/head", "sequencer/abort-safety", "sequencer/opts",
    "CHERRY_PICK_HEAD", "REVERT_HEAD",    "MERGE_MSG",              "AUTO_MERGE",
    "ORIG_HEAD",
};

/// The commits `git rev-list --reverse <range>` lists, in that order. The
/// slice is the caller's.
fn revList(gpa: Allocator, io: Io, repo: *testgit.Repo, range: []const u8) ![]Oid {
    const text = try repo.run(io, &.{ "rev-list", "--reverse", range });
    defer gpa.free(text);
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| try out.append(gpa, try Oid.parse(.sha1, line));
    return out.toOwnedSlice(gpa);
}

fn oidOf(gpa: Allocator, io: Io, repo: *testgit.Repo, rev: []const u8) !Oid {
    const text = try repo.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

test "a cherry-pick sequence stops where git's does, and each side continues the other's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "main..topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = try revList(gpa, io, &pair.ours, "main..topic");
        defer gpa.free(commits);
        var outcome = try sequencer.pick(gpa, io, &repo, commits, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(sequencer.Stop.conflict, outcome.stopped.?);
        try std.testing.expectEqual(@as(usize, 1), outcome.made.len);
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);

    // Resolved the same way on both sides, and continued by the other.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    try pair.ours.exec(io, &.{ "cherry-pick", "--continue" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        var outcome = try sequencer.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expect(outcome.stopped == null);
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
}

test "a pick with -x, a sign-off and the other recorded options leaves git's opts and message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "-x", "-s", "--allow-empty", "--keep-redundant-commits", "-m", "1", "main..topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = try revList(gpa, io, &pair.ours, "main..topic");
        defer gpa.free(commits);
        var outcome = try sequencer.pick(gpa, io, &repo, commits, .{
            .who = who,
            .record_origin = true,
            .signoff = true,
            .allow_empty = true,
            .empty = .keep,
            .mainline = 1,
        });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);

    // git skips what this stopped at, and this aborts what git stopped at
    // once the copies swap.
    try pair.ours.exec(io, &.{ "cherry-pick", "--skip" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        var outcome = try sequencer.skip(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
}

test "a single pick and a revert sequence stop, abort and skip as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    // A single pick keeps no sequence.
    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "topic~1" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try sequencer.pick(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "topic~1")}, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(sequencer.Stop.conflict, outcome.stopped.?);
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
    try pair.git.exec(io, &.{ "cherry-pick", "--abort" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try sequencer.abort(gpa, io, &repo, who, null);
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);

    // A revert sequence; the revert of a revert is a reapply.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "checkout", "-q", "topic" });
        try r.exec(io, &.{ "revert", "--no-edit", "HEAD~2" });
        try r.writeFile(io, "f", "a\nX\nc\n");
        try r.exec(io, &.{ "commit", "-q", "-am", "x change" });
    }
    try gitMayFail(&pair.git, io, &.{ "revert", "--no-edit", "HEAD~1", "topic~3" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = [_]Oid{ try oidOf(gpa, io, &pair.ours, "HEAD~1"), try oidOf(gpa, io, &pair.ours, "topic~3") };
        var outcome = try sequencer.revert(gpa, io, &repo, &commits, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &.{ "HEAD", "refs/heads/topic" });

    // Aborting goes back to where the sequence began, on both sides.
    try pair.git.exec(io, &.{ "revert", "--abort" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try sequencer.abort(gpa, io, &repo, who, null);
    }
    try expectSameState(&pair, io, &pick_state, &.{ "HEAD", "refs/heads/topic" });
}

/// Commits whose messages exercise the trailer rules, and one that is
/// empty to begin with, on `side`; `main` has one change of its own.
fn trailersScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "a", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    const messages = [_][]const u8{
        "plain subject",
        "subject\n\nA body paragraph.",
        "subject\n\nAcked-by: Someone <s@example.com>",
        "subject\n\nSigned-off-by: Fixture <fixture@example.com>",
        "subject\n\nSigned-off-by: Fixture <fixture@example.com>\nReviewed-by: R <r@example.com>",
        "subject\n\nsome text\n(cherry picked from commit 1111111111111111111111111111111111111111)\nmore\nand more",
        "  \n\nleading blank lines\n\nbody  \n\n\n",
    };
    for (messages, 0..) |msg, i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}", .{i});
        try repo.writeFile(io, name, name);
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "--cleanup=verbatim", "-m", msg });
    }
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "empty from the start" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "m", "m\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "main change" });
}

test "picked messages take -x and sign-off lines by git's trailer rules" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, trailersScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "cherry-pick", "-x", "-s", "--allow-empty", "main..side" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = try revList(gpa, io, &pair.ours, "main..side");
        defer gpa.free(commits);
        var outcome = try sequencer.pick(gpa, io, &repo, commits, .{
            .who = who,
            .record_origin = true,
            .signoff = true,
            .allow_empty = true,
        });
        defer outcome.deinit();
        try std.testing.expect(outcome.stopped == null);
        try std.testing.expectEqual(commits.len, outcome.made.len);
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "log", "--format=%H%n%B", "main~8..main" });
}

test "a pick that becomes empty stops, and is dropped or kept when asked, as git's is" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, trailersScript);
    defer pair.deinit();

    // `f0` is picked once, and then again, when it changes nothing.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "cherry-pick", "side~7" });
    const empty_modes = [_]struct { args: []const []const u8, empty: sequencer.Empty }{
        .{ .args = &.{ "cherry-pick", "side~7" }, .empty = .stop },
        .{ .args = &.{ "cherry-pick", "--empty=drop", "side~7" }, .empty = .drop },
        .{ .args = &.{ "cherry-pick", "--empty=keep", "side~7" }, .empty = .keep },
    };
    for (empty_modes) |mode| {
        try gitMayFail(&pair.git, io, mode.args);
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var outcome = try sequencer.pick(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "side~7")}, .{ .who = who, .empty = mode.empty });
            defer outcome.deinit();
            if (mode.empty == .stop) try std.testing.expectEqual(sequencer.Stop.empty, outcome.stopped.?);
        }
        try expectSameState(&pair, io, &pick_state, &main_logs);
        if (mode.empty == .stop) {
            try pair.git.exec(io, &.{ "cherry-pick", "--skip" });
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var skipped = try sequencer.skip(gpa, io, &repo, .{ .who = who });
            skipped.deinit();
        }
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
}

/// A merge commit on `side`, to be picked against its first parent.
fn mergeCommitScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "a", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "feature" });
    try repo.writeFile(io, "feature", "f\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "feature work" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side", "main" });
    try repo.writeFile(io, "side", "s\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "side work" });
    try repo.exec(io, &.{ "merge", "-q", "--no-ff", "--no-edit", "feature" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "m", "m\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "main change" });
}

test "a merge commit is picked and reverted against the mainline parent it is given" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, mergeCommitScript);
    defer pair.deinit();

    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try std.testing.expectError(error.MergeWithoutMainline, sequencer.pick(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "side")}, .{ .who = who }));
    }
    try pair.git.exec(io, &.{ "cherry-pick", "-m", "1", "side" });
    try pair.git.exec(io, &.{ "revert", "--no-edit", "-m", "1", "HEAD" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var picked = try sequencer.pick(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "side")}, .{ .who = who, .mainline = 1 });
        defer picked.deinit();
        var reverted = try sequencer.revert(gpa, io, &repo, &.{picked.made[0]}, .{ .who = who, .mainline = 1 });
        defer reverted.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
}

//=========================================================================
// Rebase
//=========================================================================

const rebase = @import("rebase.zig");

const rebase_state = [_][]const u8{
    "rebase-merge/author-script",             "rebase-merge/done",
    "rebase-merge/drop_redundant_commits",    "rebase-merge/keep_redundant_commits",
    "rebase-merge/end",                       "rebase-merge/git-rebase-todo",
    "rebase-merge/head-name",                 "rebase-merge/interactive",
    "rebase-merge/message",                   "rebase-merge/msgnum",
    "rebase-merge/no-reschedule-failed-exec", "rebase-merge/onto",
    "rebase-merge/orig-head",                 "rebase-merge/patch",
    "rebase-merge/rewritten-list",            "rebase-merge/stopped-sha",
    "rebase-merge/amend",                     "rebase-merge/current-fixups",
    "rebase-merge/message-squash",            "rebase-merge/message-fixup",
    "REBASE_HEAD",                            "ORIG_HEAD",
    "MERGE_MSG",                              "AUTO_MERGE",
    "CHERRY_PICK_HEAD",                       "MERGE_HEAD",
    "rebase-merge/strategy",                  "rebase-merge/strategy_opts",
};

/// The instructions of a sheet, without git's help below them, which says
/// what the installed git's version says.
fn expectSameSheet(pair: *Pair, io: Io, name: []const u8) !void {
    const gpa = pair.gpa;
    const left = try readOrMissing(gpa, io, &pair.git, name);
    defer gpa.free(left);
    const right = try readOrMissing(gpa, io, &pair.ours, name);
    defer gpa.free(right);
    const cut_left = left[0 .. std.mem.indexOf(u8, left, "\n#") orelse left.len];
    const cut_right = right[0 .. std.mem.indexOf(u8, right, "\n#") orelse right.len];
    try std.testing.expectEqualStrings(cut_left, cut_right);
}

test "a rebase that stops on a conflict leaves git's state, and either side finishes the other's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "topic" });
    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
    }
    try expectSameSheet(&pair, io, ".git/rebase-merge/git-rebase-todo.backup");
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{"status"});

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    try pair.ours.exec(io, &.{ "rebase", "--continue" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
        try std.testing.expectEqual(@as(usize, 3), outcome.rewritten.len);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

test "a clean rebase, an up-to-date one, and one onto another base land where git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, cleanScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "clean" });
    try pair.git.exec(io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/clean" });

    // Again: already there.
    try pair.git.exec(io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.up_to_date, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/clean" });

    // `--onto`: the last commit alone, onto the base.
    try pair.git.exec(io, &.{ "rebase", "--onto", "main~1", "clean~1" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "clean~1"), .{
            .who = who,
            .onto = try oidOf(gpa, io, &pair.ours, "main~1"),
            .onto_name = "main~1",
        });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/clean" });
}

/// Run `git rebase -i` with `sheet` as the edited todo list.
fn gitRebaseInteractive(repo: *testgit.Repo, io: Io, sheet: []const u8, args: []const []const u8) !void {
    try repo.writeFile(io, ".git/relic-todo", sheet);
    const env = @constCast(repo.environ.?);
    try env.put("GIT_SEQUENCE_EDITOR", "cp .git/relic-todo");
    defer _ = env.swapRemove("GIT_SEQUENCE_EDITOR");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(repo.gpa);
    try argv.appendSlice(repo.gpa, &.{ "rebase", "-i" });
    try argv.appendSlice(repo.gpa, args);
    try gitMayFail(repo, io, argv.items);
}

/// Five commits on `side` over `main`, each adding its own file, the last
/// two meant to be folded into the first.
fn sheetScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "base", "base\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    const subjects = [_][]const u8{ "first", "second", "third", "fixup! first", "squash! first" };
    for (subjects, 0..) |subject, i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file{d}", .{i});
        try repo.writeFile(io, name, subject);
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "-m", subject });
    }
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "main", "main\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "main moves on" });
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

fn sheetFor(gpa: Allocator, io: Io, repo: *testgit.Repo, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |line| {
        // `<command> <rev>` with the rev made a full name.
        var parts = std.mem.splitScalar(u8, line, ' ');
        const command = parts.next().?;
        try out.appendSlice(gpa, command);
        if (parts.next()) |rev| {
            try out.append(gpa, ' ');
            if (std.mem.eql(u8, command, "exec") or std.mem.eql(u8, command, "label") or std.mem.eql(u8, command, "reset")) {
                try out.appendSlice(gpa, rev);
            } else {
                const oid_text = try repo.line(io, &.{ "rev-parse", rev });
                defer gpa.free(oid_text);
                try out.appendSlice(gpa, oid_text);
            }
            while (parts.next()) |rest| {
                try out.append(gpa, ' ');
                try out.appendSlice(gpa, rest);
            }
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "an interactive rebase driven by a sheet does what git's does, line for line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, sheetScript);
    defer pair.deinit();

    const sheet = try sheetFor(gpa, io, &pair.git, &.{
        "pick side~4 # first",
        "fixup side~1",
        "squash side",
        "reword side~3",
        "drop side~2",
    });
    defer gpa.free(sheet);
    try gitRebaseInteractive(&pair.git, io, sheet, &.{"main"});
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .todo = sheet });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
}

test "an edit and a break stop where git's do, and each side continues the other's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, sheetScript);
    defer pair.deinit();

    const sheet = try sheetFor(gpa, io, &pair.git, &.{
        "edit side~4",
        "break",
        "pick side~3",
    });
    defer gpa.free(sheet);
    try gitRebaseInteractive(&pair.git, io, sheet, &.{"main"});
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .todo = sheet });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.edit, outcome.stopped.?);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{"status"});

    // Amend at the edit stop the same way on both sides, and swap.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "file0", "amended\n");
        try r.exec(io, &.{ "add", "file0" });
    }
    try pair.ours.exec(io, &.{ "rebase", "--continue" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.@"break", outcome.stopped.?);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
    try pair.git.exec(io, &.{ "rebase", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
}

/// `topic`'s commits, and on `main` the same changes made again -- one in
/// text, one in a binary file, one a change of mode -- so a rebase finds
/// them already upstream by patch id.
fn upstreamScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "text", "1\n2\n3\n");
    try repo.writeFile(io, "bin", "a\x00b");
    try repo.writeFile(io, "script", "echo\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "text", "1\n2\n3 changed\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "text change" });
    try repo.writeFile(io, "bin", "a\x00c");
    try repo.exec(io, &.{ "commit", "-q", "-am", "binary change" });
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "script" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "mode change" });
    try repo.writeFile(io, "own", "own\n");
    try repo.exec(io, &.{ "add", "own" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "topic's own" });
    try repo.exec(io, &.{ "checkout", "-q", "-f", "main" });
    try repo.writeFile(io, "other", "other\n");
    try repo.exec(io, &.{ "add", "other" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "main first" });
    for ([_][]const u8{ "topic~3", "topic~2", "topic~1" }) |rev| {
        try repo.exec(io, &.{ "cherry-pick", rev });
    }
    try repo.exec(io, &.{ "checkout", "-q", "-f", "topic" });
}

test "commits already upstream are left out by patch id, text, binary and mode alike" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, upstreamScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
        try std.testing.expectEqual(@as(usize, 1), outcome.rewritten.len);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

test "a rebase stopped on one side is skipped and aborted by the other" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "topic" });
    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
    }
    // Each skips the other's stop.
    try pair.ours.exec(io, &.{ "rebase", "--skip" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        var outcome = try rebase.skip(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });

    // A second run, aborted crosswise.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "reset", "-q", "--hard", "ORIG_HEAD" });
    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
    }
    try pair.ours.exec(io, &.{ "rebase", "--abort" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        try rebase.abort(gpa, io, &repo, who);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

test "autosquash moves fixup and squash commits where git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, sheetScript);
    defer pair.deinit();

    try pair.env.put("GIT_SEQUENCE_EDITOR", "true");
    try pair.git.exec(io, &.{ "rebase", "-i", "--autosquash", "main" });
    _ = pair.env.swapRemove("GIT_SEQUENCE_EDITOR");
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{
            .who = who,
            .onto_name = "main",
            .interactive = true,
            .autosquash = true,
        });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
}

test "an exec line runs only through the programs the caller hands in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, sheetScript);
    defer pair.deinit();

    const sheet = try sheetFor(gpa, io, &pair.git, &.{
        "pick side~4",
        "exec echo ran >> exec-log",
        "pick side~3",
        "exec false",
        "pick side~2",
    });
    defer gpa.free(sheet);
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try std.testing.expectError(error.ExecNotPermitted, rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .todo = sheet }));
        try std.testing.expect(!rebase.inProgress(io, &repo));
    }
    for ([_]*testgit.Repo{&pair.git}) |r| try r.writeFile(io, ".git/info/exclude", "exec-log\n");
    try pair.ours.writeFile(io, ".git/info/exclude", "exec-log\n");
    try gitRebaseInteractive(&pair.git, io, sheet, &.{"main"});
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{
            .who = who,
            .onto_name = "main",
            .todo = sheet,
            .programs = .{ .environ = &pair.env },
        });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.exec_failed, outcome.stopped.?);
        try std.testing.expectEqualStrings("false", outcome.exec.?);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
    const ran = try pair.ours.readFile(io, "exec-log");
    defer gpa.free(ran);
    try std.testing.expectEqualStrings("ran\n", ran);
}

test "labels, resets and merges rebuild a merge as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, mergeCommitScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "side" });
    const sheet = try sheetFor(gpa, io, &pair.git, &.{
        "label onto",
        "reset onto",
        "pick feature",
        "label feature",
        "reset onto",
        "pick side~1",
        "merge -C side feature # Merge branch 'feature' into side",
    });
    defer gpa.free(sheet);
    try gitRebaseInteractive(&pair.git, io, sheet, &.{"main"});
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .todo = sheet });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "for-each-ref", "refs/rewritten" });
}

/// `topic` with two more branches at its first commit and a third checked
/// out there in a linked worktree.
fn branchesScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try cleanScript(repo, io);
    try repo.writeFile(io, ".git/info/exclude", "held-wt\n");
    try repo.exec(io, &.{ "branch", "part", "clean~1" });
    try repo.exec(io, &.{ "branch", "zpart", "clean~1" });
    try repo.exec(io, &.{ "worktree", "add", "-q", "-b", "held", "held-wt", "clean~1" });
    try repo.exec(io, &.{ "checkout", "-q", "clean" });
}

test "update-refs moves the other branches with the commits they point at, and not one checked out elsewhere" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, branchesScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "rebase", "--update-refs", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const sheet = try rebase.plan(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .update_refs = true });
        defer gpa.free(sheet);
        try std.testing.expect(std.mem.indexOf(u8, sheet, "update-ref refs/heads/zpart\nupdate-ref refs/heads/part\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, sheet, "# Ref refs/heads/held checked out at '") != null);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .update_refs = true });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/clean", "refs/heads/part", "refs/heads/zpart", "refs/heads/held" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "for-each-ref", "refs/heads" });
}

test "a branch named to rebase is switched to first, and a detached HEAD rebases where it stands" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, cleanScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "rebase", "main", "clean" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .branch = "clean" });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/clean", "refs/heads/main" });

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "--detach", "topic" });
    try gitMayFail(&pair.git, io, &.{ "rebase", "main~0" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main~0" });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

test "the messages a person would edit come from the caller, and land as an editor's would" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, sheetScript);
    defer pair.deinit();

    const sheet = try sheetFor(gpa, io, &pair.git, &.{
        "reword side~4",
        "pick side~3",
        "squash side~2",
    });
    defer gpa.free(sheet);
    // git's editor writes the same text over whatever it is shown.
    try pair.git.writeFile(io, ".git/relic-message", "Edited by hand\n\n# a comment the cleanup takes away\nwith a body\n");
    try pair.env.put("GIT_EDITOR", "cp .git/relic-message");
    try gitRebaseInteractive(&pair.git, io, sheet, &.{"main"});
    try pair.env.put("GIT_EDITOR", "true");

    const Editor = struct {
        seen: [4]rebase.MessageKind = undefined,
        count: usize = 0,
        fn edit(context: *anyopaque, kind: rebase.MessageKind, proposed: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(proposed.len != 0);
            self.seen[self.count] = kind;
            self.count += 1;
            return "Edited by hand\n\n# a comment the cleanup takes away\nwith a body\n";
        }
    };
    var editor: Editor = .{};
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{
            .who = who,
            .onto_name = "main",
            .todo = sheet,
            .messages = .{ .context = &editor, .editFn = Editor.edit },
        });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try std.testing.expectEqual(@as(usize, 2), editor.count);
    try std.testing.expectEqual(rebase.MessageKind.reword, editor.seen[0]);
    try std.testing.expectEqual(rebase.MessageKind.squash, editor.seen[1]);
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/side" });
}

/// `topic` renames a file and `main` edits it; before that, `topic`
/// renamed a file `main` leaves alone.
fn renameScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "moved", "1\n2\n3\n4\n5\n6\n7\n8\n");
    try repo.writeFile(io, "quiet", "q1\nq2\nq3\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "quiet" });
    try repo.exec(io, &.{ "mv", "quiet", "quiet-renamed" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "rename the quiet one" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.exec(io, &.{ "mv", "moved", "elsewhere" });
    try repo.writeFile(io, "elsewhere", "1\n2\n3\n4\n5\n6\n7\n8\n9\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "rename and extend" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "moved", "one\n2\n3\n4\n5\n6\n7\n8\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "edit in place" });
}

test "a merge carries one side's edit across the other side's rename, as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, renameScript);
    defer pair.deinit();

    // git follows `moved` to `elsewhere` and merges the edit into it.
    try pair.git.exec(io, &.{ "merge", "--no-edit", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

test "with renames off the same merge conflicts as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, renameScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "merge.renames", "false" });
    try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

/// `gone` adds a file and takes it away again.
fn goneScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try cleanScript(repo, io);
    try repo.exec(io, &.{ "checkout", "-q", "-b", "gone", "topic~3" });
    try repo.writeFile(io, "tmp", "for a while\n");
    try repo.exec(io, &.{ "add", "tmp" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add tmp" });
    try repo.exec(io, &.{ "rm", "-q", "tmp" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "remove tmp" });
    try repo.writeFile(io, "tmp", "in the way\n");
}

test "a pick refused for an untracked file goes back on the sheet, and continues once the file is gone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, goneScript);
    defer pair.deinit();

    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var blocked: threeway.Blocked = .{};
        try std.testing.expectError(error.UntrackedWouldBeOverwritten, rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .blocked = &blocked }));
        try std.testing.expectEqualStrings("tmp", blocked.path());
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/gone" });

    // Each continues the other's once the file is out of the way.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.dir.deleteFile(io, "tmp");
    try pair.ours.exec(io, &.{ "rebase", "--continue" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/gone" });
}

test "a cherry-pick sequence refused for an untracked file leaves what git's leaves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, goneScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "main" });
    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "gone~1", "gone" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = [_]Oid{ try oidOf(gpa, io, &pair.ours, "gone~1"), try oidOf(gpa, io, &pair.ours, "gone") };
        try std.testing.expectError(error.UntrackedWouldBeOverwritten, sequencer.pick(gpa, io, &repo, &commits, .{ .who = who }));
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);

    // With the file gone, each aborts the other's.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.dir.deleteFile(io, "tmp");
    try pair.ours.exec(io, &.{ "cherry-pick", "--abort" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
        defer repo.deinit(io);
        try sequencer.abort(gpa, io, &repo, who, null);
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
}

/// Paths each side turns into something the other cannot take as it is: a
/// file where the other made a directory, a symlink where the other kept a
/// file, and a file both sides renamed differently.
fn shapesScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "df", "a file\n");
    try repo.writeFile(io, "kind", "a regular file\n");
    try repo.writeFile(io, "twice", "one\ntwo\nthree\nfour\nfive\nsix\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.exec(io, &.{ "rm", "-q", "df" });
    try repo.writeFile(io, "df/inside", "now a directory\n");
    try repo.exec(io, &.{ "mv", "twice", "twice-topic" });
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "topic" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "df", "a file, changed\n");
    try repo.exec(io, &.{ "rm", "-q", "kind" });
    const link = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "somewhere");
    defer repo.gpa.free(link);
    const cacheinfo = try std.fmt.allocPrint(repo.gpa, "120000,{s},kind", .{std.mem.trimEnd(u8, link, "\n")});
    defer repo.gpa.free(cacheinfo);
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", cacheinfo });
    try repo.exec(io, &.{ "mv", "twice", "twice-main" });
    try repo.exec(io, &.{ "commit", "-q", "-am", "main" });
    try repo.exec(io, &.{ "checkout", "-q", "-f", "main" });
}

test "a file meeting a directory, a symlink meeting a file and a double rename stop as git's merge does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, shapesScript);
    defer pair.deinit();

    try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);

    // Each side aborts its own, and they agree on what is left.
    try pair.git.exec(io, &.{ "merge", "--abort" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try merging.abort(gpa, io, &repo, who, null);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

/// Two branches that each merged the other, with conflicting changes to
/// one file before, so their two merge bases conflict with each other.
fn conflictingBasesScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "f", "1\n2\n3\n4\n5\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "f", "1\ntopic\n3\n4\n5\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "topic one" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "f", "1\nmain\n3\n4\n5\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "main one" });
    try repo.exec(io, &.{ "merge", "-q", "-s", "ours", "--no-edit", "topic" });
    try repo.writeFile(io, "f", "1\nmain\n3\n4\nmain five\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "main two" });
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    try repo.exec(io, &.{ "merge", "-q", "-s", "ours", "--no-edit", "main~2" });
    try repo.writeFile(io, "f", "one\ntopic\n3\n4\n5\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "topic two" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
}

test "a criss-cross merge whose bases conflict leaves git's nested markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, conflictingBasesScript);
    defer pair.deinit();

    for ([_][]const u8{ "merge", "diff3" }) |style| {
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "merge.conflictStyle", style });
        try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const target = try merging.resolve(gpa, io, &repo, "topic");
            var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
            defer outcome.deinit();
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "merge", "--abort" });
    }
}

/// `main` moves a directory; `topic` edits a file in it and adds one.
fn movedDirectoryScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "lib/a", "a1\na2\na3\na4\na5\na6\n");
    try repo.writeFile(io, "lib/b", "b1\nb2\nb3\nb4\nb5\nb6\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "lib/a", "a1\na2\nA3\na4\na5\na6\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "edit a" });
    try repo.writeFile(io, "lib/c", "new\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add c" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.exec(io, &.{ "mv", "lib", "src" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "move lib" });
}

test "cherry-picks and a rebase follow a moved directory as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, movedDirectoryScript);
    defer pair.deinit();

    // The edit follows `lib/a` to `src/a`; the new file is a location
    // conflict, as git's default `merge.directoryRenames` makes it.
    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "topic~1", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = try revList(gpa, io, &pair.ours, "main..topic");
        defer gpa.free(commits);
        var outcome = try sequencer.pick(gpa, io, &repo, commits, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "cherry-pick", "--abort" });

    // Rebased the other way, the moved directory takes topic's commits.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "merge.directoryRenames", "true" });
        try r.exec(io, &.{ "checkout", "-q", "topic" });
    }
    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

/// A submodule checked out in place, which `main` moves one commit on and
/// `topic` two.
fn submoduleScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "top", "top\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "init", "-q", "-b", "main", "sub" });
    try repo.writeFile(io, "sub/s", "s1\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "s1" });
    try repo.exec(io, &.{ "submodule", "add", "-q", "./sub", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add sub" });
    try repo.writeFile(io, "sub/s", "s2\n");
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-am", "s2" });
    try repo.writeFile(io, "sub/s", "s3\n");
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-am", "s3" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.exec(io, &.{ "add", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "sub to s3" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "HEAD~1" });
    try repo.exec(io, &.{ "add", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "sub to s2" });
}

test "a submodule both sides moved forward is fast-forwarded as git's merge does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, submoduleScript);
    defer pair.deinit();

    try pair.git.exec(io, &.{ "merge", "--no-edit", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

/// The submodule's two sides diverge, and a merge of them exists in it.
fn divergedSubmoduleScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "top", "top\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "init", "-q", "-b", "main", "sub" });
    try repo.writeFile(io, "sub/s", "s1\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "s1" });
    try repo.exec(io, &.{ "submodule", "add", "-q", "./sub", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add sub" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "left" });
    try repo.writeFile(io, "sub/left", "l\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "left" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "right", "main" });
    try repo.writeFile(io, "sub/right", "r\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "right" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "joined" });
    try repo.exec(io, &.{ "-C", "sub", "merge", "-q", "--no-edit", "left" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "right" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.exec(io, &.{ "add", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "sub to right" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "left" });
    try repo.exec(io, &.{ "add", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "sub to left" });
}

test "a submodule the two sides took different ways is a conflict as git's merge leaves it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedSubmoduleScript);
    defer pair.deinit();

    try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
        try std.testing.expectEqual(ort.MessageKind.submodule_possible_resolution, outcome.messages[0].kind);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
}

/// Every file under `.git/rr-cache` and `.git/MERGE_RR`, compared between
/// the two copies.
fn expectSameRerere(pair: *Pair, io: Io) !void {
    const gpa = pair.gpa;
    var listings: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&listings) |*l| l.deinit(gpa);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }, 0..) |r, i| {
        const mr = try readOrMissing(gpa, io, r, ".git/MERGE_RR");
        defer gpa.free(mr);
        try listings[i].print(gpa, "MERGE_RR: {s}\n", .{mr});
        var cache = r.dir.openDir(io, ".git/rr-cache", .{ .iterate = true }) catch {
            try listings[i].appendSlice(gpa, "no rr-cache\n");
            continue;
        };
        defer cache.close(io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var walker = try cache.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                try listings[i].print(gpa, "directory {s}\n", .{entry.path});
                continue;
            }
            if (entry.kind != .file) continue;
            try names.append(gpa, try gpa.dupe(u8, entry.path));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        for (names.items) |name| {
            const sub = try std.fmt.allocPrint(gpa, ".git/rr-cache/{s}", .{name});
            defer gpa.free(sub);
            const bytes = try readOrMissing(gpa, io, r, sub);
            defer gpa.free(bytes);
            try listings[i].print(gpa, "{s}:\n{s}\n", .{ name, bytes });
        }
    }
    try std.testing.expectEqualStrings(listings[0].items, listings[1].items);
}

test "rerere takes down a conflict, records its resolution and replays it, as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "rerere.enabled", "true" });
        try r.exec(io, &.{ "tag", "before" });
    }

    // The conflict is taken down.
    try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
    try expectSameRerere(&pair, io);

    // Resolved and committed: the resolution is recorded.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved by hand\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    try pair.git.exec(io, &.{ "merge", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        _ = try merging.conclude(gpa, io, &repo, .{ .who = who });
    }
    try expectSameState(&pair, io, &merge_state, &main_logs);
    try expectSameRerere(&pair, io);

    // The same merge again: the resolution is replayed into the file and,
    // with autoupdate, staged.
    for ([_]bool{ false, true }) |autoupdate| {
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
            try r.exec(io, &.{ "config", "rerere.autoUpdate", if (autoupdate) "true" else "false" });
        }
        try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const target = try merging.resolve(gpa, io, &repo, "topic");
            var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
            defer outcome.deinit();
            try std.testing.expectEqual(@as(usize, 1), outcome.reused.len);
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);
        try expectSameRerere(&pair, io);
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "merge", "--abort" });
    }
}

test "rerere records a cherry-pick's and a rebase's resolutions and replays them, as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "rerere.enabled", "true" });
        try r.exec(io, &.{ "tag", "before" });
    }
    const conflicting = try oidOf(gpa, io, &pair.ours, "topic~1");

    // A cherry-pick stops; its conflict is taken down, resolved, and the
    // resolution recorded when the pick is continued.
    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "topic~1" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try sequencer.pick(gpa, io, &repo, &.{conflicting}, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
    try expectSameRerere(&pair, io);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nboth, by hand\nc\n");
        try r.writeFile(io, "shared", "one\n2\n3\n4\n5\n6\nseven\n");
        try r.exec(io, &.{ "add", "-A" });
    }
    try pair.git.exec(io, &.{ "cherry-pick", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try sequencer.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
    try expectSameRerere(&pair, io);

    // Picked again, the resolution is replayed.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
    try gitMayFail(&pair.git, io, &.{ "cherry-pick", "topic~1" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try sequencer.pick(gpa, io, &repo, &.{conflicting}, .{ .who = who });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &pick_state, &main_logs);
    try expectSameRerere(&pair, io);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "cherry-pick", "--abort" });

    // A rebase of topic meets the same conflict, and the resolution is
    // replayed and, with autoupdate, staged.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "rerere.autoUpdate", "true" });
        try r.exec(io, &.{ "checkout", "-q", "topic" });
    }
    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
    try expectSameRerere(&pair, io);
    try pair.git.exec(io, &.{ "rebase", "--abort" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try rebase.abort(gpa, io, &repo, who);
    }
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
    try expectSameRerere(&pair, io);
}

//=========================================================================
// Strategy options
//=========================================================================

/// `f` and `g` changed on both sides in a way whose conflict falls
/// differently under histogram, patience and minimal: `main` changes both
/// in one commit, `topic` each in a commit of its own.
fn algorithmScript(repo: *testgit.Repo, io: Io) anyerror!void {
    const base = "c\nc\ne\nf\nf\ne\nf\ne\nb\nf\n";
    const ours = "g\nb\nc\ne\ne\nf\nf\nf\nf\nc\n";
    const theirs = "c\ne\ne\ne\na\ne\nf\n";
    try repo.writeFile(io, "f", base);
    try repo.writeFile(io, "g", base);
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "f", theirs);
    try repo.exec(io, &.{ "commit", "-q", "-am", "f" });
    try repo.writeFile(io, "g", theirs);
    try repo.exec(io, &.{ "commit", "-q", "-am", "g" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "f", ours);
    try repo.writeFile(io, "g", ours);
    try repo.exec(io, &.{ "commit", "-q", "-am", "main" });
}

test "diff.algorithm and the strategy options choose the line diff of a merge, a cherry-pick and a rebase as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, algorithmScript);
    defer pair.deinit();

    const Variant = struct { config: ?[]const u8, words: []const []const u8 };
    const variants = [_]Variant{
        .{ .config = "patience", .words = &.{} },
        .{ .config = null, .words = &.{"diff-algorithm=minimal"} },
        // `patience` keeps the minimal that `diff.algorithm` asked for.
        .{ .config = "minimal", .words = &.{"patience"} },
        .{ .config = "patience", .words = &.{ "histogram", "find-renames=40%" } },
    };
    for (variants) |variant| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        for (variant.words) |word| try args.appendSlice(gpa, &.{ "-X", word });
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            if (variant.config) |value| {
                try r.exec(io, &.{ "config", "diff.algorithm", value });
            } else try gitMayFail(r, io, &.{ "config", "--unset", "diff.algorithm" });
        }

        // A merge of topic.
        const merge_args = try std.mem.concat(gpa, []const u8, &.{ &.{"merge"}, args.items, &.{"topic"} });
        defer gpa.free(merge_args);
        try gitMayFail(&pair.git, io, merge_args);
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const target = try merging.resolve(gpa, io, &repo, "topic");
            var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .strategy_options = variant.words });
            defer outcome.deinit();
            try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);
        try pair.git.exec(io, &.{ "merge", "--abort" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            try merging.abort(gpa, io, &repo, who, null);
        }

        // A cherry-pick of both of topic's commits stops on the first.
        const pick_args = try std.mem.concat(gpa, []const u8, &.{ &.{"cherry-pick"}, args.items, &.{"main..topic"} });
        defer gpa.free(pick_args);
        try gitMayFail(&pair.git, io, pick_args);
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const commits = [_]Oid{ try oidOf(gpa, io, &pair.ours, "topic~1"), try oidOf(gpa, io, &pair.ours, "topic") };
            var outcome = try sequencer.pick(gpa, io, &repo, &commits, .{ .who = who, .strategy_options = variant.words });
            defer outcome.deinit();
        }
        try expectSameState(&pair, io, &pick_state, &main_logs);
        try pair.git.exec(io, &.{ "cherry-pick", "--abort" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            try sequencer.abort(gpa, io, &repo, who, null);
        }

        // A rebase of topic stops on its first commit; each side finishes
        // the other's, whose second commit then conflicts under the
        // options read back from the other's state.
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "topic" });
        const rebase_args = try std.mem.concat(gpa, []const u8, &.{ &.{"rebase"}, args.items, &.{"main"} });
        defer gpa.free(rebase_args);
        try gitMayFail(&pair.git, io, rebase_args);
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .strategy_options = variant.words });
            defer outcome.deinit();
            try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
        }
        try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.writeFile(io, "f", "resolved\n");
            try r.exec(io, &.{ "add", "f" });
        }
        try gitMayFail(&pair.ours, io, &.{ "rebase", "--continue" });
        {
            var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
            defer repo.deinit(io);
            var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
            defer outcome.deinit();
            try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
        }
        try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.exec(io, &.{ "rebase", "--abort" });
            try r.exec(io, &.{ "checkout", "-q", "main" });
        }
    }
}

/// What `forget` did, in the words `git rerere forget` writes to its
/// standard error.
fn forgetWords(gpa: Allocator, forgotten: *const rerere.Forgotten) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (forgotten.unparsable) |p| try out.print(gpa, "error: could not parse conflict hunks in '{s}'\n", .{p});
    for (forgotten.unremembered) |p| try out.print(gpa, "error: no remembered resolution for '{s}'\n", .{p});
    for (forgotten.forgotten) |p| try out.print(gpa, "Updated preimage for '{s}'\nForgot resolution for '{s}'\n", .{ p, p });
    return out.toOwnedSlice(gpa);
}

fn joinLines(gpa: Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths) |p| try out.print(gpa, "{s}\n", .{p});
    return out.toOwnedSlice(gpa);
}

/// `git rerere status`, `remaining` and `diff` on git's copy, and the same
/// questions asked of this package on the other.
fn expectSameRerereReport(pair: *Pair, io: Io) !void {
    const gpa = pair.gpa;
    var repo = try pair.open(io);
    defer repo.deinit(io);
    {
        const want = try pair.git.run(io, &.{ "rerere", "status" });
        defer gpa.free(want);
        var got = try rerere.status(gpa, io, &repo);
        defer got.deinit();
        const text = try joinLines(gpa, got.paths);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(want, text);
    }
    {
        const want = try pair.git.run(io, &.{ "rerere", "remaining" });
        defer gpa.free(want);
        var got = try rerere.remaining(gpa, io, &repo);
        defer got.deinit();
        const text = try joinLines(gpa, got.paths);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(want, text);
    }
    {
        const want = try pair.git.run(io, &.{ "rerere", "diff" });
        defer gpa.free(want);
        const got = try rerere.diff(gpa, io, &repo);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "rerere's status, remaining, diff, forget and gc answer as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "rerere.enabled", "true" });
        try r.exec(io, &.{ "tag", "before" });
        try gitMayFail(r, io, &.{ "merge", "topic" });
    }
    try expectSameRerereReport(&pair, io);
    // Half resolved in the working tree: the diff from the preimage.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        const text = try readOrMissing(gpa, io, r, "f");
        defer gpa.free(text);
        const edited = try std.mem.replaceOwned(u8, gpa, text, "=======\n", "=======\nand one more line\n");
        defer gpa.free(edited);
        try r.writeFile(io, "f", edited);
    }
    try expectSameRerereReport(&pair, io);

    // Resolved and staged by git on both copies, which remembers the
    // stages; committed, which records the resolution.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved by hand\nc\n");
        try r.exec(io, &.{ "add", "-A" });
    }
    try expectSameRerereReport(&pair, io);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "commit", "-q", "--no-edit" });
    try expectSameRerere(&pair, io);

    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    // Nothing is old enough for the default ages.
    try pair.git.exec(io, &.{ "rerere", "gc" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try rerere.gc(gpa, io, &repo, now_s);
    }
    try expectSameRerere(&pair, io);

    // Forgotten: the conflict comes back from what the index remembers,
    // the resolution goes, and the preimage is written again. Forgotten a
    // second time, there is nothing left to forget.
    for (0..2) |_| {
        var git = try pair.git.capture(io, &.{ "rerere", "forget", "f" });
        defer git.deinit(gpa);
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var forgotten = try rerere.forget(gpa, io, &repo, &.{"f"});
        defer forgotten.deinit();
        const words = try forgetWords(gpa, &forgotten);
        defer gpa.free(words);
        try std.testing.expectEqualStrings(git.stderr, words);
        try expectSameRerere(&pair, io);
        try expectSameRerereReport(&pair, io);
    }

    // Run again, rerere records the resolution the working tree holds.
    try pair.git.exec(io, &.{"rerere"});
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var index = try repo.openIndex(io);
        defer index.deinit();
        var outcome = try rerere.run(gpa, io, &repo, &index, .{});
        defer outcome.deinit();
        try std.testing.expectEqual(@as(usize, 1), outcome.recorded_resolution.len);
    }
    try expectSameRerere(&pair, io);

    // A resolution a day in the future is already too old; a conflict
    // never resolved is kept for ever.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "gc.rerereResolved", "-1" });
        try r.exec(io, &.{ "config", "gc.rerereUnresolved", "never" });
    }
    try pair.git.exec(io, &.{ "rerere", "gc" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try rerere.gc(gpa, io, &repo, now_s);
    }
    try expectSameRerere(&pair, io);

    // The conflict met again is taken down again; kept while unresolved
    // conflicts are kept, pruned once they are not.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
        try gitMayFail(r, io, &.{ "merge", "topic" });
    }
    for ([_][]const u8{ "never", "-1" }) |age| {
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "gc.rerereUnresolved", age });
        try pair.git.exec(io, &.{ "rerere", "gc" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            try rerere.gc(gpa, io, &repo, now_s);
        }
        try expectSameRerere(&pair, io);
    }
}

test "an aborted, skipped or quit pick, merge or rebase leaves rerere's records as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "rerere.enabled", "true" });
        try r.exec(io, &.{ "tag", "before" });
    }
    const commits = [_]Oid{ try oidOf(gpa, io, &pair.ours, "topic~1"), try oidOf(gpa, io, &pair.ours, "topic") };

    for ([_][]const u8{ "--abort", "--skip", "--quit" }) |op| {
        try gitMayFail(&pair.git, io, &.{ "cherry-pick", "topic~1", "topic" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var outcome = try sequencer.pick(gpa, io, &repo, &commits, .{ .who = who });
            defer outcome.deinit();
        }
        try expectSameRerere(&pair, io);
        try gitMayFail(&pair.git, io, &.{ "cherry-pick", op });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            if (std.mem.eql(u8, op, "--abort")) {
                try sequencer.abort(gpa, io, &repo, who, null);
            } else if (std.mem.eql(u8, op, "--skip")) {
                var outcome = try sequencer.skip(gpa, io, &repo, .{ .who = who });
                outcome.deinit();
            } else try sequencer.quit(io, &repo);
        }
        try expectSameRerere(&pair, io);
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
            try gitMayFail(r, io, &.{ "cherry-pick", "--quit" });
        }
    }

    try gitMayFail(&pair.git, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who });
        defer outcome.deinit();
    }
    try pair.git.exec(io, &.{ "merge", "--abort" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try merging.abort(gpa, io, &repo, who, null);
    }
    try expectSameRerere(&pair, io);

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "topic" });
    try gitMayFail(&pair.git, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
    }
    try expectSameRerere(&pair, io);
    try pair.git.exec(io, &.{ "rebase", "--quit" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try rebase.quit(gpa, io, &repo);
    }
    try expectSameRerere(&pair, io);
}

test "adding a resolved file replaces its conflict and remembers the stages, as git add does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "tag", "before" });
    // Resolved by editing the file, and by deleting it.
    for ([_]bool{ false, true }) |delete| {
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
            try gitMayFail(r, io, &.{ "merge", "topic" });
            if (delete) {
                try r.dir.deleteFile(io, "f");
            } else try r.writeFile(io, "f", "a\nresolved by hand\nc\n");
        }
        try pair.git.exec(io, &.{ "add", "-A" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var index = try repo.openIndex(io);
            defer index.deinit();
            var ignore = try repo.loadIgnore(io);
            defer ignore.deinit();
            var attrs = try repo.loadAttrs(io);
            defer attrs.deinit();
            var rules = repo.worktreeRules();
            rules.ignore = &ignore;
            rules.attrs = &attrs;
            _ = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = rules });
            try index.write(io, repo.git_dir, "index", .{});
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);
    }
}

//=========================================================================
// Renormalizing, and files written through their attributes
//=========================================================================

/// `file.txt` and `gone.txt` committed with CRLF endings and no attributes;
/// `topic` edits the one, deletes the other and edits `id.txt`; `main`
/// sets `text=auto` and stores both again normalized, and asks for `ident`
/// on `id.txt`.
fn renormalizeScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "file.txt", "a\r\nb\r\nc\r\n");
    try repo.writeFile(io, "gone.txt", "x\r\ny\r\n");
    try repo.writeFile(io, "id.txt", "$Id$\nold\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "file.txt", "a\r\nB\r\nc\r\n");
    try repo.exec(io, &.{ "rm", "-q", "gone.txt" });
    try repo.writeFile(io, "id.txt", "$Id$\nnew\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "topic" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, ".gitattributes", "* text=auto\nid.txt ident\n");
    try repo.exec(io, &.{ "add", "--renormalize", "." });
    try repo.exec(io, &.{ "add", ".gitattributes" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "normalize" });
}

test "a merge renormalizes when asked and writes its files through their attributes, as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, renormalizeScript);
    defer pair.deinit();

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "tag", "before" });
    const Variant = struct { config: ?[]const u8, words: []const []const u8, clean: bool };
    for ([_]Variant{
        .{ .config = null, .words = &.{}, .clean = false },
        .{ .config = null, .words = &.{"renormalize"}, .clean = true },
        .{ .config = "true", .words = &.{}, .clean = true },
        .{ .config = "true", .words = &.{"no-renormalize"}, .clean = false },
    }) |variant| {
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            if (variant.config) |value| {
                try r.exec(io, &.{ "config", "merge.renormalize", value });
            } else try gitMayFail(r, io, &.{ "config", "--unset", "merge.renormalize" });
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.append(gpa, "merge");
        for (variant.words) |word| try args.appendSlice(gpa, &.{ "-X", word });
        try args.append(gpa, "topic");
        try gitMayFail(&pair.git, io, args.items);
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const target = try merging.resolve(gpa, io, &repo, "topic");
            var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .strategy_options = variant.words });
            defer outcome.deinit();
            try std.testing.expectEqual(variant.clean, outcome.result != .conflicted);
        }
        try expectSameState(&pair, io, &merge_state, &main_logs);
        // The id file went out with its $Id$ expanded, on both sides.
        const id = try readOrMissing(gpa, io, &pair.ours, "id.txt");
        defer gpa.free(id);
        try std.testing.expect(std.mem.startsWith(u8, id, "$Id: "));
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            gitMayFail(r, io, &.{ "merge", "--abort" }) catch {};
            try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
        }
    }
}

//=========================================================================
// Hooks
//=========================================================================

/// A hook that records what it was given: its arguments as they are, where
/// it runs, git's variables for it, which of a command's state files are
/// there, its standard input, and a message hook's file.
const recorder =
    \\#!/bin/sh
    \\{
    \\  printf '%s' "$(basename "$0")"
    \\  for a in "$@"; do printf ' %s' "$a"; done
    \\  [ "$(pwd -P)" = "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" ] && printf ' top'
    \\  printf ' index=%s editor=%s author=%s <%s> %s' "$GIT_INDEX_FILE" "$GIT_EDITOR" "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "$GIT_AUTHOR_DATE"
    \\  for f in MERGE_HEAD MERGE_MSG CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD COMMIT_EDITMSG; do [ -f ".git/$f" ] && printf ' %s' "$f"; done
    \\  printf ' stdin=['; tr '\n' ';'; printf ']'
    \\  case "$(basename "$0")" in prepare-commit-msg|commit-msg)
    \\    # Behind an editor the file also holds git's help for the person,
    \\    # which the commit strips; what is compared then is what it keeps.
    \\    if [ "$GIT_EDITOR" = ":" ]; then printf ' msg=['; tr '\n' '|' < "$1"; else printf ' edited=['; git stripspace -s < "$1" | tr '\n' '|'; fi
    \\    printf ']';;
    \\  esac
    \\  printf '\n'
    \\} >> .git/hook.log
    \\
;

const recorded_hooks = [_][]const u8{
    "pre-merge-commit", "prepare-commit-msg", "commit-msg",   "pre-commit",
    "post-commit",      "post-merge",         "post-rewrite", "post-checkout",
    "pre-rebase",
};

/// Put the recorder in place for every hook a history command may run, in
/// both copies, and start both logs empty.
fn installRecorders(pair: *Pair, io: Io) !void {
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        for (recorded_hooks) |name| {
            const path = try std.fmt.allocPrint(pair.gpa, ".git/hooks/{s}", .{name});
            defer pair.gpa.free(path);
            try r.writeFile(io, path, recorder);
            const file = try r.dir.openFile(io, path, .{ .mode = .read_write });
            defer file.close(io);
            try file.setPermissions(io, .fromMode(0o755));
        }
        try r.writeFile(io, ".git/hook.log", "");
    }
}

/// The two hook logs are the same; both are emptied for what comes next.
fn expectSameHooks(pair: *Pair, io: Io) !void {
    const a = try readOrMissing(pair.gpa, io, &pair.git, ".git/hook.log");
    defer pair.gpa.free(a);
    const b = try readOrMissing(pair.gpa, io, &pair.ours, ".git/hook.log");
    defer pair.gpa.free(b);
    std.testing.expectEqualStrings(a, b) catch |err| {
        std.debug.print("hook logs differ\n", .{});
        return err;
    };
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.writeFile(io, ".git/hook.log", "");
}

/// git's side of a command, with the hooks on: the harness turns them off.
fn gitWithHooks(pair: *Pair, io: Io, args: []const []const u8) !void {
    const full = try std.mem.concat(pair.gpa, []const u8, &.{ &.{ "-c", "core.hooksPath=.git/hooks" }, args });
    defer pair.gpa.free(full);
    try gitMayFail(&pair.git, io, full);
}

test "a merge runs git merge's hooks, and a stopped one git commit's, as git's do" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, cleanScript);
    defer pair.deinit();
    try installRecorders(&pair, io);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "tag", "before" });

    // A merge that commits, with and without --no-verify.
    for ([_]bool{ true, false }) |verify| {
        try gitWithHooks(&pair, io, if (verify) &.{ "merge", "--no-edit", "clean" } else &.{ "merge", "--no-edit", "--no-verify", "clean" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
            defer runner.deinit();
            const target = try merging.resolve(gpa, io, &repo, "clean");
            var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .hooks = &runner, .verify = verify });
            defer outcome.deinit();
            try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result);
        }
        try expectSameHooks(&pair, io);
        try expectSameState(&pair, io, &merge_state, &main_logs);
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
    }

    // A fast-forward runs post-merge alone.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "checkout", "-q", "-b", "behind", "main~1" });
        try r.writeFile(io, ".git/hook.log", "");
    }
    try gitWithHooks(&pair, io, &.{ "merge", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        const target = try merging.resolve(gpa, io, &repo, "main");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .hooks = &runner });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.fast_forward, outcome.result);
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/behind" });
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "checkout", "-q", "main" });
        try r.writeFile(io, ".git/hook.log", "");
    }

    // A merge that stops runs nothing; the git commit that concludes it
    // runs its own four.
    try gitWithHooks(&pair, io, &.{ "merge", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .hooks = &runner });
        defer outcome.deinit();
        try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
    }
    try expectSameHooks(&pair, io);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    try gitWithHooks(&pair, io, &.{ "commit", "-q", "--no-edit" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        _ = try merging.conclude(gpa, io, &repo, .{ .who = who, .hooks = &runner, .cleanup = .whitespace });
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &(merge_state ++ .{"COMMIT_EDITMSG"}), &main_logs);
}

test "a cherry-pick and a revert run the sequencer's hooks, and a continued stop git commit's, as git's do" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    try installRecorders(&pair, io);

    const Step = struct { git: []const []const u8, action: sequencer.Action, rev: []const u8 };
    for ([_]Step{
        .{ .git = &.{ "cherry-pick", "topic~2" }, .action = .pick, .rev = "topic~2" },
        .{ .git = &.{ "revert", "--no-edit", "HEAD" }, .action = .revert, .rev = "HEAD" },
        .{ .git = &.{ "cherry-pick", "topic~1" }, .action = .pick, .rev = "topic~1" },
    }) |step| {
        const oid = try oidOf(gpa, io, &pair.ours, step.rev);
        try gitWithHooks(&pair, io, step.git);
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
            defer runner.deinit();
            const options: sequencer.Options = .{ .who = who, .hooks = &runner };
            var outcome = switch (step.action) {
                .pick => try sequencer.pick(gpa, io, &repo, &.{oid}, options),
                .revert => try sequencer.revert(gpa, io, &repo, &.{oid}, options),
            };
            defer outcome.deinit();
        }
        try expectSameHooks(&pair, io);
        try expectSameState(&pair, io, &(pick_state ++ .{"COMMIT_EDITMSG"}), &main_logs);
    }

    // The last one stopped: resolved, and continued.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nboth\nc\n");
        try r.writeFile(io, "shared", "one\n2\n3\n4\n5\n6\nseven\n");
        try r.exec(io, &.{ "add", "-A" });
    }
    try gitWithHooks(&pair, io, &.{ "cherry-pick", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        var outcome = try sequencer.proceed(gpa, io, &repo, .{ .who = who, .hooks = &runner });
        defer outcome.deinit();
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &(pick_state ++ .{"COMMIT_EDITMSG"}), &main_logs);
}

test "a rebase runs git rebase's hooks, stopped, continued and finished, as git's does" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "checkout", "-q", "topic" });
        try r.exec(io, &.{ "tag", "before" });
    }
    try installRecorders(&pair, io);

    try gitWithHooks(&pair, io, &.{ "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .upstream_name = "main", .hooks = &runner });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });

    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    try gitWithHooks(&pair, io, &.{ "rebase", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who, .hooks = &runner });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });

    // With --no-verify pre-rebase is passed over; up to date, nothing runs.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
    for ([_][]const u8{ "main~1", "main" }) |upstream| {
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.writeFile(io, ".git/hook.log", "");
        try gitWithHooks(&pair, io, &.{ "rebase", "--no-verify", upstream });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
            defer runner.deinit();
            var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, upstream), .{ .who = who, .onto_name = upstream, .upstream_name = upstream, .hooks = &runner, .verify = false });
            defer outcome.deinit();
        }
        try expectSameHooks(&pair, io);
        try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| gitMayFail(r, io, &.{ "rebase", "--abort" }) catch {};
    }
}

/// `topic` carries a commit, a `fixup!` of it and one more, off `main`.
fn fixupScript(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "f", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "f", "b\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "one" });
    try repo.writeFile(io, "f", "c\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "fixup! one" });
    try repo.writeFile(io, "g", "d\n");
    try repo.exec(io, &.{ "add", "g" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "h", "e\n");
    try repo.exec(io, &.{ "add", "h" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "main moves" });
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
}

test "a rebase's fixup runs the hooks of the amend it makes, as git's does" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, fixupScript);
    defer pair.deinit();
    try installRecorders(&pair, io);

    try pair.env.put("GIT_SEQUENCE_EDITOR", "true");
    try gitWithHooks(&pair, io, &.{ "rebase", "-i", "--autosquash", "main" });
    _ = pair.env.swapRemove("GIT_SEQUENCE_EDITOR");
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{
            .who = who,
            .onto_name = "main",
            .upstream_name = "main",
            .interactive = true,
            .autosquash = true,
            .hooks = &runner,
        });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

test "a rebase's squash and reword run the hooks of the commits git makes for them" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, fixupScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "commit", "-q", "--amend", "-m", "squash! one" });
        try r.exec(io, &.{ "tag", "before" });
    }
    try installRecorders(&pair, io);

    // The squash, through the editor the person has.
    try pair.env.put("GIT_SEQUENCE_EDITOR", "true");
    try gitWithHooks(&pair, io, &.{ "rebase", "-i", "--autosquash", "main" });
    _ = pair.env.swapRemove("GIT_SEQUENCE_EDITOR");
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{
            .who = who,
            .onto_name = "main",
            .upstream_name = "main",
            .interactive = true,
            .autosquash = true,
            .hooks = &runner,
        });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });

    // A reword of the last commit.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
        try r.writeFile(io, ".git/hook.log", "");
    }
    const one = try oidOf(gpa, io, &pair.ours, "topic~2");
    const squash = try oidOf(gpa, io, &pair.ours, "topic~1");
    const two = try oidOf(gpa, io, &pair.ours, "topic");
    var hex: [3][hash.max_hex_len]u8 = undefined;
    const sheet = try std.fmt.allocPrint(gpa, "pick {s} one\npick {s} squash! one\nreword {s} two\n", .{ one.hex(&hex[0]), squash.hex(&hex[1]), two.hex(&hex[2]) });
    defer gpa.free(sheet);
    try pair.git.writeFile(io, ".git/relic-sheet", sheet);
    try pair.env.put("GIT_SEQUENCE_EDITOR", "cp .git/relic-sheet");
    try gitWithHooks(&pair, io, &.{ "rebase", "-i", "main" });
    _ = pair.env.swapRemove("GIT_SEQUENCE_EDITOR");
    try pair.git.dir.deleteFile(io, ".git/relic-sheet");
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &pair.env }, .{ .output = .ignore });
        defer runner.deinit();
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{
            .who = who,
            .onto_name = "main",
            .upstream_name = "main",
            .todo = sheet,
            .hooks = &runner,
        });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameHooks(&pair, io);
    try expectSameState(&pair, io, &rebase_state, &.{ "HEAD", "refs/heads/topic" });
}

//=========================================================================
// Signing
//=========================================================================

/// A key of `format` made in `dir`, which holds nothing of the person's,
/// with both copies of `pair` set to sign with it. `false` when the program
/// that makes it is not installed.
fn makeSigningKey(pair: *Pair, io: Io, dir: []const u8, format: @import("signing.zig").Format) !bool {
    const gpa = pair.gpa;
    const gnupg_home = try std.fs.path.join(gpa, &.{ dir, "g" });
    defer gpa.free(gnupg_home);
    try pair.env.put("GNUPGHOME", gnupg_home);
    try pair.env.put("HOME", dir);
    switch (format) {
        .ssh => {
            const key = try std.fs.path.join(gpa, &.{ dir, "id" });
            defer gpa.free(key);
            const made = std.process.run(gpa, io, .{ .argv = &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", key }, .environ_map = &pair.env }) catch return false;
            gpa.free(made.stdout);
            gpa.free(made.stderr);
            const public_path = try std.fmt.allocPrint(gpa, "{s}.pub", .{key});
            defer gpa.free(public_path);
            const public = try Io.Dir.cwd().readFileAlloc(io, public_path, gpa, .limited(4096));
            defer gpa.free(public);
            const allowed = try std.fmt.allocPrint(gpa, "fixture@example.com namespaces=\"git\" {s}", .{public});
            defer gpa.free(allowed);
            const allowed_path = try std.fs.path.join(gpa, &.{ dir, "allowed" });
            defer gpa.free(allowed_path);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = allowed_path, .data = allowed });
            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
                try r.exec(io, &.{ "config", "gpg.format", "ssh" });
                try r.exec(io, &.{ "config", "user.signingKey", key });
                try r.exec(io, &.{ "config", "gpg.ssh.allowedSignersFile", allowed_path });
            }
        },
        .openpgp => {
            try Io.Dir.createDirAbsolute(io, gnupg_home, .fromMode(0o700));
            const made = std.process.run(gpa, io, .{ .argv = &.{
                "gpg",                  "--batch",                       "--quiet", "--passphrase", "",
                "--quick-generate-key", "Fixture <fixture@example.com>", "ed25519", "sign",         "never",
            }, .environ_map = &pair.env }) catch return false;
            gpa.free(made.stdout);
            gpa.free(made.stderr);
        },
        .x509 => unreachable,
    }
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "commit.gpgSign", "true" });
    return true;
}

/// git's verdict on a commit of the copy this package wrote to: `G` for a
/// good signature, `N` for none, and git's other letters.
fn signatureLetter(pair: *Pair, io: Io, rev: []const u8) !u8 {
    const out = try pair.ours.line(io, &.{ "log", "-1", "--format=%G?", rev });
    defer pair.gpa.free(out);
    return out[0];
}

/// A commit with its signature and its parents' names taken out: what two
/// signatures of the same commit differ by, and the parents they sign.
fn unsigned(pair: *Pair, io: Io, repo: *testgit.Repo, rev: []const u8) ![]u8 {
    const raw = try repo.run(io, &.{ "cat-file", "commit", rev });
    defer pair.gpa.free(raw);
    // A revert names the commit it reverts, its parent here, whose own
    // signature -- an OpenPGP one carries the second it was made -- is
    // not the other repository's: the name is compared as that parent's.
    const parent_rev = try std.fmt.allocPrint(pair.gpa, "{s}^", .{rev});
    defer pair.gpa.free(parent_rev);
    const parent = try repo.line(io, &.{ "rev-parse", parent_rev });
    defer pair.gpa.free(parent);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(pair.gpa);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var in_signature = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "gpgsig ")) {
            in_signature = true;
            continue;
        }
        if (in_signature and std.mem.startsWith(u8, line, " ")) continue;
        in_signature = false;
        if (std.mem.startsWith(u8, line, "parent ")) {
            try out.appendSlice(pair.gpa, "parent\n");
            continue;
        }
        if (std.mem.indexOf(u8, line, parent)) |at| {
            try out.appendSlice(pair.gpa, line[0..at]);
            try out.appendSlice(pair.gpa, "<parent>");
            try out.appendSlice(pair.gpa, line[at + parent.len ..]);
            try out.append(pair.gpa, '\n');
            continue;
        }
        try out.appendSlice(pair.gpa, line);
        try out.append(pair.gpa, '\n');
    }
    return out.toOwnedSlice(pair.gpa);
}

fn expectSignedAlike(pair: *Pair, io: Io, rev: []const u8) !void {
    try pair.ours.exec(io, &.{ "verify-commit", rev });
    try std.testing.expectEqual(@as(u8, 'G'), try signatureLetter(pair, io, rev));
    const a = try unsigned(pair, io, &pair.git, rev);
    defer pair.gpa.free(a);
    const b = try unsigned(pair, io, &pair.ours, rev);
    defer pair.gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

fn signedHistory(format: @import("signing.zig").Format) !void {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, divergedScript);
    defer pair.deinit();
    var keys = std.testing.tmpDir(.{});
    defer keys.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try gpa.dupe(u8, buf[0..try keys.dir.realPath(io, &buf)]);
    defer gpa.free(dir);
    if (!try makeSigningKey(&pair, io, dir, format)) return error.SkipZigTest;
    defer if (format == .openpgp) {
        const stopped = std.process.run(gpa, io, .{ .argv = &.{ "gpgconf", "--kill", "gpg-agent" }, .environ_map = &pair.env }) catch null;
        if (stopped) |s| {
            gpa.free(s.stdout);
            gpa.free(s.stderr);
        }
    };
    const programs: @import("program.zig").Programs = .{ .environ = &pair.env };
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "tag", "before" });

    // A merge commit, by commit.gpgSign.
    try pair.git.exec(io, &.{ "-c", "commit.gpgSign=true", "merge", "--no-edit", "-X", "theirs", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        var outcome = try merging.start(gpa, io, &repo, target, .{ .who = who, .strategy_options = &.{"theirs"}, .signing = .{ .programs = programs } });
        defer outcome.deinit();
    }
    try expectSignedAlike(&pair, io, "HEAD");

    // A pick and a revert.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
    try pair.git.exec(io, &.{ "-c", "commit.gpgSign=true", "cherry-pick", "topic~2" });
    try pair.git.exec(io, &.{ "-c", "commit.gpgSign=true", "revert", "--no-edit", "HEAD" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const options: sequencer.Options = .{ .who = who, .signing = .{ .programs = programs } };
        var picked = try sequencer.pick(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "topic~2")}, options);
        picked.deinit();
        var reverted = try sequencer.revert(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "HEAD")}, options);
        reverted.deinit();
    }
    try expectSignedAlike(&pair, io, "HEAD");
    try expectSignedAlike(&pair, io, "HEAD~1");

    // A pick that stops keeps the decision in its opts, and the commit that
    // continues it is signed; -S with a key names the key.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
    try gitMayFail(&pair.git, io, &.{ "-c", "commit.gpgSign=false", "cherry-pick", "-S", "topic~1", "topic" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const commits = [_]Oid{ try oidOf(gpa, io, &pair.ours, "topic~1"), try oidOf(gpa, io, &pair.ours, "topic") };
        try pair.ours.exec(io, &.{ "config", "commit.gpgSign", "false" });
        var outcome = try sequencer.pick(gpa, io, &repo, &commits, .{ .who = who, .signing = .{ .sign = .always, .programs = programs } });
        defer outcome.deinit();
    }
    // Earlier commits carry signatures of their own moment, so what is
    // compared is the recorded decision.
    {
        const a = try readOrMissing(gpa, io, &pair.git, ".git/sequencer/opts");
        defer gpa.free(a);
        const b = try readOrMissing(gpa, io, &pair.ours, ".git/sequencer/opts");
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nboth\nc\n");
        try r.writeFile(io, "shared", "one\n2\n3\n4\n5\n6\nseven\n");
        try r.exec(io, &.{ "add", "-A" });
    }
    try pair.git.exec(io, &.{ "-c", "commit.gpgSign=false", "cherry-pick", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try sequencer.proceed(gpa, io, &repo, .{ .who = who, .signing = .{ .programs = programs } });
        defer outcome.deinit();
    }
    try expectSignedAlike(&pair, io, "HEAD");
    try expectSignedAlike(&pair, io, "HEAD~1");

    // --no-gpg-sign wins over commit.gpgSign.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "config", "commit.gpgSign", "true" });
        try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
    }
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var picked = try sequencer.pick(gpa, io, &repo, &.{try oidOf(gpa, io, &pair.ours, "topic~2")}, .{ .who = who, .signing = .{ .sign = .never, .programs = programs } });
        picked.deinit();
    }
    try std.testing.expectEqual(@as(u8, 'N'), try signatureLetter(&pair, io, "HEAD"));

    // A rebase signs every commit it makes, and keeps -S in its state.
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.exec(io, &.{ "reset", "-q", "--hard", "before" });
        try r.exec(io, &.{ "checkout", "-q", "topic" });
    }
    try gitMayFail(&pair.git, io, &.{ "-c", "commit.gpgSign=true", "rebase", "main" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .signing = .{ .programs = programs } });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
    }
    // The commits already made carry signatures of their own moment, so
    // what is compared is the recorded decision.
    {
        const a = try readOrMissing(gpa, io, &pair.git, ".git/rebase-merge/gpg_sign_opt");
        defer gpa.free(a);
        const b = try readOrMissing(gpa, io, &pair.ours, ".git/rebase-merge/gpg_sign_opt");
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
    try expectSignedAlike(&pair, io, "HEAD");
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        try r.writeFile(io, "f", "a\nresolved\nc\n");
        try r.exec(io, &.{ "add", "f" });
    }
    try pair.git.exec(io, &.{ "-c", "commit.gpgSign=true", "rebase", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who, .signing = .{ .programs = programs } });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    for ([_][]const u8{ "HEAD", "HEAD~1", "HEAD~2" }) |rev| try expectSignedAlike(&pair, io, rev);
}

test "merges, picks, reverts and rebases are signed with an ssh key as git signs them" {
    try signedHistory(.ssh);
}

test "merges, picks, reverts and rebases are signed with an OpenPGP key as git signs them" {
    try signedHistory(.openpgp);
}
