//! `branch` against git 2.55's `git branch`: a branch made at a start
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
