//! `branch` against git 2.56's `git branch`: a branch made at a start
//! point, from a remote-tracking branch, a local one or a tag, sets up the
//! upstream git's does under each `branch.autoSetupMerge` and
//! `branch.autoSetupRebase`, writes git's reflog line, and refuses what git
//! refuses; `--set-upstream-to` likewise.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const history = @import("history.zig");
const branch = @import("../commit/branch.zig");

const Pair = history.Pair;
const who = history.who;

/// `main` and `topic`, a tag, and `origin` (a bare copy) fetched; `dup`
/// is a second remote whose fetch refspec lands in `origin`'s refs too,
/// left out of the configuration until a case adds it.
fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "a", "a\n");
    try repo.exec(io, &.{ "add", "a" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.exec(io, &.{ "tag", "v1" });
    try repo.writeFile(io, "a", "b\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "two" });
    try repo.exec(io, &.{ "branch", "topic" });
    try repo.exec(io, &.{ "clone", "-q", "--bare", ".", ".git/origin.git" });
    try repo.exec(io, &.{ "remote", "add", "origin", ".git/origin.git" });
    try repo.exec(io, &.{ "fetch", "-q", "origin" });
}

fn expectSame(pair: *Pair, io: Io) !void {
    for ([_][]const []const u8{
        &.{ "config", "--get-regexp", "^branch\\." },
        &.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads" },
    }) |args| {
        pair.git.report_failures = false;
        pair.ours.report_failures = false;
        const left = pair.git.run(io, args) catch try pair.gpa.dupe(u8, "");
        defer pair.gpa.free(left);
        const right = pair.ours.run(io, args) catch try pair.gpa.dupe(u8, "");
        defer pair.gpa.free(right);
        std.testing.expectEqualStrings(left, right) catch |err| {
            std.debug.print("git {s} differs\n", .{args[0]});
            return err;
        };
    }
}

fn expectSameLog(pair: *Pair, io: Io, name: []const u8) !void {
    const ref = try std.mem.concat(pair.gpa, u8, &.{ "refs/heads/", name });
    defer pair.gpa.free(ref);
    const left = try pair.git.run(io, &.{ "reflog", "show", "--format=%H %gn <%ge> %gs", ref, "--" });
    defer pair.gpa.free(left);
    const right = try pair.ours.run(io, &.{ "reflog", "show", "--format=%H %gn <%ge> %gs", ref, "--" });
    defer pair.gpa.free(right);
    try std.testing.expectEqualStrings(left, right);
}

const Case = struct {
    config: []const []const u8 = &.{},
    args: []const []const u8,
    name: []const u8,
    start: []const u8,
    options: branch.Options,
    err: ?anyerror = null,
};

test "a new branch tracks what git's tracks under each branch.autoSetupMerge and branch.autoSetupRebase" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const cases = [_]Case{
                .{ .args = &.{ "branch", "b1", "origin/topic" }, .name = "b1", .start = "origin/topic", .options = .{ .who = who } },
                .{ .args = &.{ "branch", "b2", "main" }, .name = "b2", .start = "main", .options = .{ .who = who } },
                .{ .config = &.{ "branch.autoSetupMerge", "always" }, .args = &.{ "branch", "b3", "main" }, .name = "b3", .start = "main", .options = .{ .who = who } },
                .{ .config = &.{ "branch.autoSetupMerge", "simple" }, .args = &.{ "branch", "topic2", "origin/topic" }, .name = "topic2", .start = "origin/topic", .options = .{ .who = who } },
                .{ .config = &.{ "branch.autoSetupMerge", "simple" }, .args = &.{ "branch", "-f", "topic", "origin/topic" }, .name = "topic", .start = "origin/topic", .options = .{ .who = who, .force = true } },
                .{ .config = &.{ "branch.autoSetupMerge", "inherit" }, .args = &.{ "branch", "b5", "b1" }, .name = "b5", .start = "b1", .options = .{ .who = who } },
                .{ .config = &.{ "branch.autoSetupMerge", "false" }, .args = &.{ "branch", "b6", "origin/main" }, .name = "b6", .start = "origin/main", .options = .{ .who = who } },
                .{ .config = &.{ "branch.autoSetupRebase", "always" }, .args = &.{ "branch", "b7", "origin/main" }, .name = "b7", .start = "origin/main", .options = .{ .who = who } },
                .{ .config = &.{ "branch.autoSetupRebase", "local" }, .args = &.{ "branch", "--track", "b8", "main" }, .name = "b8", .start = "main", .options = .{ .who = who, .track = .explicit } },
                .{ .config = &.{ "branch.autoSetupRebase", "remote" }, .args = &.{ "branch", "--track", "b9", "main" }, .name = "b9", .start = "main", .options = .{ .who = who, .track = .explicit } },
                .{ .args = &.{ "branch", "--no-track", "b10", "origin/main" }, .name = "b10", .start = "origin/main", .options = .{ .who = who, .track = .never } },
                .{ .args = &.{ "branch", "--track=inherit", "b11", "b1" }, .name = "b11", .start = "b1", .options = .{ .who = who, .track = .inherit } },
                .{ .args = &.{ "branch", "b12", "v1" }, .name = "b12", .start = "v1", .options = .{ .who = who } },
                .{ .args = &.{ "branch", "-f", "b2", "v1" }, .name = "b2", .start = "v1", .options = .{ .who = who, .force = true } },
                .{ .args = &.{ "branch", "--track", "b13", "v1" }, .name = "b13", .start = "v1", .options = .{ .who = who, .track = .explicit }, .err = error.UpstreamNotBranch },
                .{ .args = &.{ "branch", "b2", "main" }, .name = "b2", .start = "main", .options = .{ .who = who }, .err = error.BranchExists },
                .{ .args = &.{ "branch", "-f", "main", "v1" }, .name = "main", .start = "v1", .options = .{ .who = who, .force = true }, .err = error.BranchCheckedOut },
                .{ .args = &.{ "branch", "a..b", "main" }, .name = "a..b", .start = "main", .options = .{ .who = who }, .err = error.InvalidBranchName },
                .{ .args = &.{ "branch", "b14", "nothing" }, .name = "b14", .start = "nothing", .options = .{ .who = who }, .err = error.NotAValidObjectName },
                .{ .args = &.{ "branch", "b15", "main^{tree}" }, .name = "b15", .start = "main^{tree}", .options = .{ .who = who }, .err = error.NotAValidBranchPoint },
                .{ .config = &.{ "remote.dup.fetch", "+refs/heads/*:refs/remotes/origin/*" }, .args = &.{ "branch", "b16", "origin/main" }, .name = "b16", .start = "origin/main", .options = .{ .who = who }, .err = error.AmbiguousUpstream },
            };
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            for (cases) |case| {
                if (case.config.len != 0) for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", case.config[0], case.config[1] });
                var repo = try pair.open(io);
                defer repo.deinit(io);
                if (case.err) |want| {
                    pair.git.report_failures = false;
                    try std.testing.expectError(error.GitFailed, pair.git.exec(io, case.args));
                    pair.git.report_failures = true;
                    try std.testing.expectError(want, branch.create(gpa, io, &repo, .{ .name = case.name, .start = case.start }, case.options));
                } else {
                    try pair.git.exec(io, case.args);
                    var made = branch.create(gpa, io, &repo, .{ .name = case.name, .start = case.start }, case.options) catch |err| {
                        std.debug.print("git {s} {s}: {t}\n", .{ case.args[1], case.name, err });
                        return err;
                    };
                    defer made.deinit();
                    try expectSameLog(&pair, io, case.name);
                }
                expectSame(&pair, io) catch |err| {
                    std.debug.print("after git {s} {s}\n", .{ case.args[1], case.name });
                    return err;
                };
                if (case.config.len != 0) for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "--unset", case.config[0] });
            }
        }
    }.f);
}

test "--set-upstream-to sets an existing branch's upstream as git's does, and refuses a start that is no branch" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{ .{ "topic", "origin/topic" }, .{ "main", "topic" }, .{ "topic", "origin/main" } }) |set| {
        const arg = try std.mem.concat(gpa, u8, &.{ "--set-upstream-to=", set[1] });
        defer gpa.free(arg);
        try pair.git.exec(io, &.{ "branch", arg, set[0] });
        var repo = try pair.open(io);
        defer repo.deinit(io);
        _ = try branch.setUpstream(arena, io, &repo, set[0], set[1]);
        try expectSame(&pair, io);
    }
    pair.git.report_failures = false;
    try std.testing.expectError(error.GitFailed, pair.git.exec(io, &.{ "branch", "--set-upstream-to=v1", "topic" }));
    var repo = try pair.open(io);
    defer repo.deinit(io);
    try std.testing.expectError(error.UpstreamNotBranch, branch.setUpstream(arena, io, &repo, "topic", "v1"));
    try std.testing.expectError(error.NoSuchBranch, branch.setUpstream(arena, io, &repo, "nothing", "main"));
    try expectSame(&pair, io);
}

const merging = @import("../commit/merging.zig");

/// `main` and `topic` each with a commit of their own, both changing `a`.
fn divergedScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "a", "1\n2\n3\n");
    try repo.exec(io, &.{ "add", "a" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "a", "1\n2\ntopic\n");
    try repo.writeFile(io, "t", "t\n");
    try repo.exec(io, &.{ "add", "a", "t" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "topic work" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "a", "1\n2\nmain\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "main work" });
}

fn expectSameMerge(pair: *Pair, io: Io) !void {
    try history.expectSameState(pair, io, &.{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "ORIG_HEAD", "AUTO_MERGE" }, &.{ "HEAD", "refs/heads/main" });
}

test "branch.<name>.mergeOptions are git merge's options under the caller's, as git reads them" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { setting: []const u8, args: []const []const u8 = &.{ "merge", "topic" }, options: merging.Options, err: ?anyerror = null }{
        .{ .setting = "--no-commit", .options = .{ .who = who } },
        .{ .setting = "--no-commit", .args = &.{ "merge", "--commit", "-X", "theirs", "topic" }, .options = .{ .who = who, .commit = true, .strategy_options = &.{"theirs"} } },
        .{ .setting = "-Xours --signoff -m 'from the setting' -m \"and a body\"", .options = .{ .who = who } },
        .{ .setting = "--strategy-option=theirs --no-verify --cleanup=verbatim", .options = .{ .who = who } },
        .{ .setting = "  -q --stat --no-edit -sort --allow-unr --no-sign", .options = .{ .who = who } },
        .{ .setting = "--ff-only", .options = .{ .who = who }, .err = error.NotFastForward },
        .{ .setting = "--frobnicate", .options = .{ .who = who }, .err = error.InvalidMergeOptions },
        .{ .setting = "-m 'open", .options = .{ .who = who }, .err = error.InvalidMergeOptions },
    };
    for (cases) |case| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, .files, divergedScript);
        defer pair.deinit();
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "branch.main.mergeOptions", case.setting });
        try history.gitMayFail(io, &pair.git, case.args);
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const target = try merging.resolve(gpa, io, &repo, "topic");
        if (case.err) |want| {
            if (merging.start(gpa, io, &repo, target, case.options)) |done| {
                var outcome = done;
                outcome.deinit();
                std.debug.print("{s}: merged\n", .{case.setting});
                return error.TestExpectedError;
            } else |err| try std.testing.expectEqual(want, err);
        } else {
            var outcome = try merging.start(gpa, io, &repo, target, case.options);
            outcome.deinit();
        }
        expectSameMerge(&pair, io) catch |err| {
            std.debug.print("mergeOptions {s} differs\n", .{case.setting});
            return err;
        };
    }
}

test "a branch no local ref has is guessed from the one remote that has it, or checkout.defaultRemote's, as git's checkout does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const repo_mod = @import("../repo/repo.zig");
    const Guessed = struct { default_remote: ?[]const u8 = null, name: []const u8 };
    for ([_]Guessed{
        .{ .name = "only-origin" },
        .{ .name = "both" },
        .{ .name = "both", .default_remote = "upstream" },
        .{ .name = "both", .default_remote = "elsewhere" },
        .{ .name = "nowhere" },
        .{ .name = "only-upstream" },
    }, 0..) |case, n| {
        var repo = try testgit.Repo.init(gpa, io, &.{});
        defer repo.deinit();
        try repo.writeFile(io, "a", "a\n");
        try repo.exec(io, &.{ "add", "a" });
        try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
        try repo.exec(io, &.{ "remote", "add", "origin", "../origin" });
        try repo.exec(io, &.{ "remote", "add", "upstream", "../upstream" });
        try repo.exec(io, &.{ "config", "remote.upstream.fetch", "+refs/heads/*:refs/remotes/up/*" });
        for ([_][]const u8{ "refs/remotes/origin/only-origin", "refs/remotes/origin/both", "refs/remotes/up/both", "refs/remotes/up/only-upstream" }) |ref| try repo.exec(io, &.{ "update-ref", ref, "HEAD" });
        if (case.default_remote) |r| try repo.exec(io, &.{ "config", "checkout.defaultRemote", r });

        var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
        defer native.deinit(io);
        const guess = try branch.guessRemote(gpa, io, &native, case.name);
        defer if (guess.tracking) |t| gpa.free(t);

        repo.report_failures = false;
        const checked_out = repo.exec(io, &.{ "checkout", "-q", case.name });
        repo.report_failures = true;
        if (checked_out) |_| {
            const upstream = try repo.line(io, &.{ "rev-parse", "--symbolic-full-name", "@{upstream}" });
            defer gpa.free(upstream);
            std.testing.expectEqualStrings(upstream, guess.tracking orelse "") catch |err| {
                std.debug.print("guess case {d}\n", .{n});
                return err;
            };
        } else |_| {
            std.testing.expect(guess.tracking == null) catch |err| {
                std.debug.print("guess case {d}: git refused, relic chose {?s}\n", .{ n, guess.tracking });
                return err;
            };
        }
    }
}

test "a branch a bisection started from is named with its worktree, as git 2.56's branch -d reports it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const repo_mod = @import("../repo/repo.zig");
    const head = @import("../repo/head.zig");
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try script(io, &repo);
    try repo.exec(io, &.{ "worktree", "add", "-q", "-b", "wt", "linked", "topic" });
    var linked = try repo.dir.openDir(io, "linked", .{ .iterate = true });
    defer linked.close(io);
    var in_linked: testgit.Repo = .{ .gpa = gpa, .tmp = undefined, .dir = linked };
    try in_linked.exec(io, &.{ "bisect", "start", "HEAD", "HEAD~1" });
    try repo.exec(io, &.{ "bisect", "start", "HEAD", "HEAD~1" });

    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "wt", "main", "topic" }) |name| {
        const ours = try head.bisectingBranch(arena, io, &native, try arena.print("refs/heads/{s}", .{name}));
        repo.report_failures = false;
        var ran = try repo.capture(io, &.{ "branch", "-d", name });
        repo.report_failures = true;
        defer ran.deinit(gpa);
        // git: "cannot delete branch '<name>' used by worktree at '<path>' for bisect"
        const marker = "' for bisect";
        const theirs: ?[]const u8 = if (std.mem.find(u8, ran.stderr, marker)) |end| blk: {
            const start = std.mem.findLast(u8, ran.stderr[0..end], "'").? + 1;
            break :blk ran.stderr[start..end];
        } else null;
        std.testing.expectEqualStrings(theirs orelse "", ours orelse "") catch |err| {
            std.debug.print("{s}: git said {s}\n", .{ name, ran.stderr });
            return err;
        };
    }
}

/// t3200's `--delete-merged` setup: `origin` with `main` and `next`, a
/// branch ahead, `fork` empty, `other` unrelated, `push.default=current`.
fn mergedScript(io: Io, repo: *testgit.Repo) anyerror!void {
    for ([_][]const []const u8{
        &.{ "commit", "-q", "--allow-empty", "-m", "base" },
        &.{ "checkout", "-q", "-b", "next" },
        &.{ "commit", "-q", "--allow-empty", "-m", "next-work" },
        &.{ "checkout", "-q", "main" },
        &.{ "init", "-q", "--bare", ".git/upstream.git" },
        &.{ "push", "-q", ".git/upstream.git", "main", "next" },
        &.{ "branch", "-q", "-D", "next" },
        &.{ "remote", "add", "-f", "origin", ".git/upstream.git" },
        &.{ "remote", "set-head", "origin", "main" },
        &.{ "branch", "-q", "--set-upstream-to=origin/main", "main" },
        &.{ "init", "-q", "--bare", ".git/fork.git" },
        &.{ "remote", "add", "fork", ".git/fork.git" },
        &.{ "init", "-q", "-b", "main", ".git/other" },
        &.{ "-C", ".git/other", "commit", "-q", "--allow-empty", "-m", "other-base" },
        &.{ "remote", "add", "other", ".git/other" },
        &.{ "config", "push.default", "current" },
        &.{ "fetch", "-q", "other" },
    }) |args| try repo.exec(io, args);
}

/// One `git branch [--dry-run] (--delete-merged <pattern>)... [<branch-pattern>...]`.
const MergedRun = struct {
    upstreams: []const []const u8,
    branches: []const []const u8 = &.{},
    dry_run: bool = false,
};

const MergedCase = struct {
    what: []const u8,
    /// Branches made as t3200's `create_merged_branch` makes them: on
    /// `origin/next`, a commit ahead, pushed to it.
    merged: []const []const u8 = &.{},
    setup: []const []const []const u8 = &.{},
    runs: []const MergedRun,
};

/// git's lines for what `deleteMerged` did, `dry_run` or not, sorted:
/// git gives them in its hash set's order.
fn mergedLines(gpa: std.mem.Allocator, io: Io, repo: *testgit.Repo, outcome: *const branch.MergedOutcome, dry_run: bool) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (outcome.deleted) |d| {
        var hex_buf: [64]u8 = undefined;
        const hex = d.oid.hex(&hex_buf);
        const short = try repo.line(io, &.{ "rev-parse", "--short", hex });
        defer gpa.free(short);
        try lines.append(gpa, try std.mem.concat(gpa, u8, &.{ if (dry_run) "Would delete" else "Deleted", " branch ", d.name, " (was ", d.target orelse short, ")." }));
    }
    for (outcome.kept) |name| try lines.append(gpa, try std.mem.concat(gpa, u8, &.{ "Skipping '", name, "' (branch.", name, ".deleteMerged is false)" }));
    return sortedLines(gpa, lines.items);
}

fn sortedLines(gpa: std.mem.Allocator, lines: [][]const u8) ![]const u8 {
    std.mem.sort([]const u8, lines, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try out.appendSlice(gpa, l);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "delete-merged deletes the branches git 2.56's does, with what it says, and clears what it clears" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const cases = [_]MergedCase{
        .{
            .what = "a cloned main pushes to its upstream",
            .setup = &.{&.{ "checkout", "-q", "--detach" }},
            .runs = &.{.{ .upstreams = &.{"*/*"} }},
        },
        .{
            .what = "only the selected merged branches",
            .merged = &.{ "also-merged", "merged" },
            .setup = &.{
                &.{ "checkout", "-q", "-b", "unmerged", "--track", "origin/next" },
                &.{ "commit", "-q", "--allow-empty", "-m", "unmerged work" },
                &.{ "checkout", "-q", "-b", "tracks-other", "--track", "other/main" },
            },
            .runs = &.{
                .{ .upstreams = &.{"origin/next"}, .branches = &.{"merged"}, .dry_run = true },
                .{ .upstreams = &.{"origin/next"}, .branches = &.{"merged"} },
            },
        },
        .{
            .what = "main kept despite another push remote; a branch checked out, one whose upstream is gone",
            .merged = &.{ "on-next", "checked-out", "upstream-gone" },
            .setup = &.{
                &.{ "config", "remote.pushDefault", "fork" },
                &.{ "checkout", "-q", "-b", "local-to-delete", "--track", "main" },
                &.{ "config", "branch.upstream-gone.merge", "refs/heads/topic" },
                &.{ "checkout", "-q", "-b", "tracks-other", "--track", "other/main" },
                &.{ "checkout", "-q", "checked-out" },
            },
            .runs = &.{.{ .upstreams = &.{ "origin/*", "main" } }},
        },
        .{
            .what = "push refspecs mapped to the upstream",
            .setup = &.{
                &.{ "checkout", "-q", "-b", "topic" },
                &.{ "config", "remote.origin.push", "refs/heads/topic:refs/heads/published" },
                &.{ "push", "-q", "origin" },
                &.{ "branch", "-q", "--set-upstream-to=origin/published", "topic" },
                &.{ "checkout", "-q", "-b", "other-topic", "--track", "origin/published" },
                &.{ "checkout", "-q", "--detach" },
            },
            .runs = &.{.{ .upstreams = &.{"origin/published"} }},
        },
        .{
            .what = "the upstream of a branch that stays stays",
            .merged = &.{"feature"},
            .setup = &.{
                &.{ "checkout", "-q", "-b", "topic", "--track", "feature" },
                &.{ "commit", "-q", "--allow-empty", "-m", "topic work" },
            },
            .runs = &.{
                .{ .upstreams = &.{"origin/next"}, .dry_run = true },
                .{ .upstreams = &.{"origin/next"} },
            },
        },
        .{
            .what = "a kept base loses the upstream that went",
            .setup = &.{
                &.{ "branch", "-q", "--track", "lower", "origin/next" },
                &.{ "branch", "-q", "--track", "mid", "lower" },
                &.{ "checkout", "-q", "-b", "tip", "--track", "mid" },
                &.{ "commit", "-q", "--allow-empty", "-m", "tip work" },
            },
            .runs = &.{
                .{ .upstreams = &.{ "origin/next", "lower" }, .dry_run = true },
                .{ .upstreams = &.{ "origin/next", "lower" } },
            },
        },
        .{
            .what = "stacked branches whatever their names sort as",
            .setup = &.{
                &.{ "branch", "-q", "--track", "c-lower", "origin/next" },
                &.{ "branch", "-q", "--track", "b-mid", "c-lower" },
                &.{ "checkout", "-q", "-b", "a-tip", "--track", "b-mid" },
                &.{ "commit", "-q", "--allow-empty", "-m", "tip work" },
            },
            .runs = &.{
                .{ .upstreams = &.{ "origin/next", "c-*" } },
                .{ .upstreams = &.{ "origin/next", "c-*" } },
            },
        },
        .{
            .what = "branch.<name>.deleteMerged=false",
            .merged = &.{ "deleted", "kept" },
            .setup = &.{
                &.{ "config", "branch.kept.deleteMerged", "false" },
                &.{ "checkout", "-q", "--detach" },
            },
            .runs = &.{.{ .upstreams = &.{"origin/next"} }},
        },
    };
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            for (cases) |case| {
                var pair: Pair = undefined;
                try Pair.init(gpa, io, &pair, format, mergedScript);
                defer pair.deinit();
                for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
                    for (case.merged) |name| {
                        try r.exec(io, &.{ "checkout", "-q", "-b", name, "--track", "origin/next" });
                        const subject = try std.mem.concat(gpa, u8, &.{ name, " work" });
                        defer gpa.free(subject);
                        try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", subject });
                        const spec = try std.mem.concat(gpa, u8, &.{ name, ":next" });
                        defer gpa.free(spec);
                        try r.exec(io, &.{ "push", "-q", "origin", spec });
                    }
                    for (case.setup) |args| try r.exec(io, args);
                }
                for (case.runs, 0..) |run, n| {
                    var args: std.ArrayList([]const u8) = .empty;
                    defer args.deinit(gpa);
                    try args.append(gpa, "branch");
                    if (run.dry_run) try args.append(gpa, "--dry-run");
                    for (run.upstreams) |u| try args.appendSlice(gpa, &.{ "--delete-merged", u });
                    try args.appendSlice(gpa, run.branches);
                    var ran = try pair.git.capture(io, args.items);
                    defer ran.deinit(gpa);
                    try std.testing.expectEqual(0, ran.code);
                    var theirs_lines: std.ArrayList([]const u8) = .empty;
                    defer theirs_lines.deinit(gpa);
                    for ([_][]const u8{ ran.stdout, ran.stderr }) |text| {
                        var it = std.mem.tokenizeScalar(u8, text, '\n');
                        while (it.next()) |l| try theirs_lines.append(gpa, l);
                    }
                    const theirs = try sortedLines(gpa, theirs_lines.items);
                    defer gpa.free(theirs);

                    var repo = try pair.open(io);
                    defer repo.deinit(io);
                    var outcome = try branch.deleteMerged(gpa, io, &repo, .{ .upstreams = run.upstreams, .branches = run.branches }, .{ .dry_run = run.dry_run });
                    defer outcome.deinit();
                    const ours = try mergedLines(gpa, io, &pair.ours, &outcome, run.dry_run);
                    defer gpa.free(ours);
                    std.testing.expectEqualStrings(theirs, ours) catch |err| {
                        std.debug.print("{s}, run {d}\n", .{ case.what, n });
                        return err;
                    };
                    expectSame(&pair, io) catch |err| {
                        std.debug.print("{s}, run {d}\n", .{ case.what, n });
                        return err;
                    };
                }
            }
        }
    }.f);
}

test "delete-merged refuses a pattern that names no branch, as git 2.56's does" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, mergedScript);
    defer pair.deinit();
    pair.git.report_failures = false;
    try std.testing.expectError(error.GitFailed, pair.git.exec(io, &.{ "branch", "--delete-merged", "nope" }));
    var repo = try pair.open(io);
    defer repo.deinit(io);
    try std.testing.expectError(error.NotABranchOrPattern, branch.deleteMerged(gpa, io, &repo, .{ .upstreams = &.{"nope"} }, .{}));
}
