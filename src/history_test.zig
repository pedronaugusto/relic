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
const threeway = @import("threeway.zig");

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
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "rev-parse", "HEAD" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "symbolic-ref", "-q", "HEAD" });
    try expectSameOutput(gpa, io, &pair.git, &pair.ours, &.{ "ls-files", "--stage" });
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
