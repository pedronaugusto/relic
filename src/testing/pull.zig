//! `pull` against git's: a fetch and a merge or a rebase, each step held
//! to what `git pull` leaves.
//!
//! An upstream repository and two clones of it are built from one script
//! with git's dates fixed, so every commit is the same on each side. git
//! pulls into one clone and this package into the other, and everything
//! git reads back is compared: `HEAD`, the index, the working tree,
//! `FETCH_HEAD`, `ORIG_HEAD` and the logs of the branch, `HEAD` and the
//! remote-tracking branch.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const history = @import("history.zig");
const merging = @import("../commit/merging.zig");
const rebase = @import("../rebase/rebase.zig");
const pull = @import("../transport/pull.zig");

const Pair = history.Pair;
const who = history.who;
const expectSameState = history.expectSameState;
const gitMayFail = history.gitMayFail;

const state = [_][]const u8{ "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD", "MERGE_MSG", "AUTO_MERGE", "MERGE_AUTOSTASH" };
const logs = [_][]const u8{ "HEAD", "refs/heads/main", "refs/remotes/origin/main", "refs/stash" };

/// `a`, `b` and `c`, one commit.
fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "a", "1\n2\n3\n");
    try repo.writeFile(io, "b", "b\n");
    try repo.writeFile(io, "c", "c\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
}

/// Nothing: an unborn `main`.
fn empty(_: Io, _: *testgit.Repo) anyerror!void {}

/// Two clones of an upstream built by `script`, each tracking its `main`.
const Clones = struct {
    pair: Pair,
    upstream: testgit.Repo,
    url: []u8,

    fn init(gpa: Allocator, io: Io, c: *Clones, format: testgit.RefFormat, local: *const fn (Io, *testgit.Repo) anyerror!void) !void {
        try Pair.init(gpa, io, &c.pair, format, local);
        errdefer c.pair.deinit();
        c.upstream = try testgit.Repo.init(gpa, io, format.initArgs());
        errdefer c.upstream.deinit();
        c.upstream.environ = &c.pair.env;
        try script(io, &c.upstream);
        try c.upstream.exec(io, &.{ "branch", "topic" });
        try c.upstream.exec(io, &.{ "branch", "other" });
        c.url = try testremote.absolutePath(gpa, io, c.upstream.dir);
        errdefer gpa.free(c.url);
        try c.both(io, &.{ "remote", "add", "origin", c.url });
        try c.both(io, &.{ "fetch", "-q", "origin" });
        if (local != &empty) try c.both(io, &.{ "branch", "-q", "-u", "origin/main" });
    }

    fn deinit(c: *Clones) void {
        c.pair.gpa.free(c.url);
        c.upstream.deinit();
        c.pair.deinit();
    }

    fn both(c: *Clones, io: Io, args: []const []const u8) !void {
        for ([_]*testgit.Repo{ &c.pair.git, &c.pair.ours }) |r| try r.exec(io, args);
    }

    fn bothWrite(c: *Clones, io: Io, path: []const u8, bytes: []const u8) !void {
        for ([_]*testgit.Repo{ &c.pair.git, &c.pair.ours }) |r| try r.writeFile(io, path, bytes);
    }

    /// A commit upstream changing `path` to `bytes`.
    fn upstreamCommit(c: *Clones, io: Io, path: []const u8, bytes: []const u8, subject: []const u8) !void {
        try c.upstream.writeFile(io, path, bytes);
        try c.upstream.exec(io, &.{ "commit", "-q", "-am", subject });
    }

    /// The same commit in both clones.
    fn localCommit(c: *Clones, io: Io, path: []const u8, bytes: []const u8, subject: []const u8) !void {
        try c.bothWrite(io, path, bytes);
        try c.both(io, &.{ "commit", "-q", "-am", subject });
    }

    /// `pull` in this package's clone.
    fn pullHere(c: *Clones, io: Io, remote: ?[]const u8, given: Given) !pull.Outcome {
        var repo = try c.pair.open(io);
        defer repo.deinit(io);
        return pull.pull(c.pair.gpa, io, &repo, remote, .{
            .mode = given.mode,
            .fast_forward = given.fast_forward,
            .autostash = given.autostash,
            .reflog_action = given.action,
            .fetch = .{ .who = who, .refspecs = given.refspecs },
            .merge = .{ .who = who },
            .rebasing = .{ .who = who },
        });
    }

    fn expectSame(c: *Clones, io: Io) !void {
        try expectSameState(&c.pair, io, &state, &logs);
    }
};

/// What a test asks of `pull`.
const Given = struct {
    mode: ?pull.Mode = null,
    fast_forward: ?merging.FastForward = null,
    autostash: ?bool = null,
    action: ?[]const u8 = null,
    refspecs: []const []const u8 = &.{},
};

test "a pull fast-forwards, merges, and refuses diverged branches it was not told how to reconcile, as git pull does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var c: Clones = undefined;
            try Clones.init(gpa, io, &c, format, script);
            defer c.deinit();

            // Behind: a fast-forward, and a file staged beside it stays
            // staged, as git's two-way checkout keeps it.
            try c.upstreamCommit(io, "a", "1\n2\nup\n", "up a");
            try c.bothWrite(io, "new", "new\n");
            try c.both(io, &.{ "add", "new" });
            try c.pair.git.exec(io, &.{"pull"});
            {
                var outcome = try c.pullHere(io, null, .{});
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.fast_forward, outcome.result.?.merged.result);
            }
            try c.expectSame(io);
            try c.both(io, &.{ "commit", "-q", "-m", "new" });

            // Diverged, and nothing said: refused after the fetch.
            try c.upstreamCommit(io, "b", "up\n", "up b");
            try c.localCommit(io, "c", "mine\n", "mine c");
            try gitMayFail(io, &c.pair.git, &.{"pull"});
            try std.testing.expectError(error.DivergentBranches, c.pullHere(io, null, .{}));
            try c.expectSame(io);

            // `pull.ff=only` refuses it too, unless a rebase is asked for.
            try c.both(io, &.{ "config", "pull.ff", "only" });
            try gitMayFail(io, &c.pair.git, &.{"pull"});
            try std.testing.expectError(error.NotFastForward, c.pullHere(io, null, .{}));
            try c.expectSame(io);
            try c.both(io, &.{ "config", "--unset", "pull.ff" });

            // `pull.rebase=false`: a merge of `FETCH_HEAD`, named for where
            // it came from.
            try c.both(io, &.{ "config", "pull.rebase", "false" });
            try c.pair.git.exec(io, &.{"pull"});
            {
                var outcome = try c.pullHere(io, null, .{});
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result.?.merged.result);
            }
            try c.expectSame(io);

            // A conflict stops it, the fetched side named by its object.
            try c.upstreamCommit(io, "c", "theirs\n", "their c");
            try c.localCommit(io, "c", "ours\n", "our c");
            try gitMayFail(io, &c.pair.git, &.{"pull"});
            {
                var outcome = try c.pullHere(io, null, .{});
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result.?.merged.result);
            }
            try c.expectSame(io);
        }
    }.inFormat);
}

test "a pull rebases onto what it fetched, from where the branch forked when the upstream was rewritten, as git pull --rebase does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var c: Clones = undefined;
            try Clones.init(gpa, io, &c, format, script);
            defer c.deinit();

            try c.upstreamCommit(io, "a", "1\n2\nup\n", "up a");
            try c.localCommit(io, "b", "mine\n", "mine b");
            try c.pair.git.exec(io, &.{ "pull", "--rebase" });
            {
                var outcome = try c.pullHere(io, null, .{ .mode = .rebase, .action = "pull --rebase" });
                defer outcome.deinit();
                try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result.?.rebased.result);
            }
            try c.expectSame(io);

            // The upstream rewrites the commit the branch is on: the fork
            // point, in the remote-tracking branch's log, leaves it out.
            // Replayed, the old commit would conflict with its rewrite.
            try c.upstream.writeFile(io, "a", "1\n2\nrewritten\n");
            try c.upstream.exec(io, &.{ "commit", "-q", "-a", "--amend", "-m", "up a, rewritten" });
            try c.both(io, &.{ "config", "branch.main.rebase", "true" });
            try c.pair.git.exec(io, &.{"pull"});
            {
                var outcome = try c.pullHere(io, null, .{});
                defer outcome.deinit();
                try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result.?.rebased.result);
            }
            try c.expectSame(io);

            // Nothing new of its own: a fast-forward, not a rebase.
            try c.upstreamCommit(io, "c", "up\n", "up c");
            try c.both(io, &.{ "reset", "-q", "--hard", "origin/main" });
            try c.pair.git.exec(io, &.{"pull"});
            {
                var outcome = try c.pullHere(io, null, .{});
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.fast_forward, outcome.result.?.merged.result);
            }
            try c.expectSame(io);

            // Changes in the way: put aside and brought back.
            try c.upstreamCommit(io, "a", "1\n2\nupper\n", "upper a");
            try c.localCommit(io, "b", "mine again\n", "mine b again");
            try c.bothWrite(io, "c", "dirty\n");
            try c.both(io, &.{ "config", "pull.autostash", "true" });
            try c.pair.git.exec(io, &.{"pull"});
            {
                var outcome = try c.pullHere(io, null, .{});
                defer outcome.deinit();
                try std.testing.expect(outcome.result.?.rebased.restored != null);
            }
            try c.expectSame(io);
        }
    }.inFormat);
}

test "a pull of named branches merges each as git pull does, and an unborn branch takes its first commit" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var c: Clones = undefined;
            try Clones.init(gpa, io, &c, format, script);
            defer c.deinit();

            try c.upstream.exec(io, &.{ "checkout", "-q", "topic" });
            try c.upstreamCommit(io, "b", "topic\n", "topic b");
            try c.upstream.exec(io, &.{ "checkout", "-q", "other" });
            try c.upstreamCommit(io, "c", "other\n", "other c");
            try c.upstream.exec(io, &.{ "checkout", "-q", "main" });
            try c.localCommit(io, "a", "mine\n2\n3\n", "mine a");
            try c.both(io, &.{ "config", "pull.rebase", "false" });

            try c.pair.git.exec(io, &.{ "pull", "origin", "topic" });
            {
                var outcome = try c.pullHere(io, "origin", .{ .refspecs = &.{"topic"} });
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result.?.merged.result);
            }
            try c.expectSame(io);

            // Two at once: an octopus, both named in its message.
            try c.both(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
            try c.pair.git.exec(io, &.{ "pull", "origin", "topic", "other" });
            {
                var outcome = try c.pullHere(io, "origin", .{ .refspecs = &.{ "topic", "other" } });
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result.?.merged.result);
            }
            try c.expectSame(io);

            // A URL with nothing named: its `HEAD`, named by the URL.
            try c.both(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
            try c.upstreamCommit(io, "b", "upstream\n", "up b");
            try c.pair.git.exec(io, &.{ "pull", c.url });
            {
                var outcome = try c.pullHere(io, c.url, .{});
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result.?.merged.result);
            }
            try c.expectSame(io);

            // Another remote with no branch named: nothing to merge.
            try c.both(io, &.{ "remote", "add", "second", c.url });
            try gitMayFail(io, &c.pair.git, &.{ "pull", "second" });
            try std.testing.expectError(error.BranchNotGiven, c.pullHere(io, "second", .{}));
            try c.expectSame(io);
        }
    }.inFormat);
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var c: Clones = undefined;
            try Clones.init(gpa, io, &c, format, empty);
            defer c.deinit();
            // A file staged on the unborn branch is kept beside the files
            // the first commit brings.
            try c.bothWrite(io, "staged", "staged\n");
            try c.both(io, &.{ "add", "staged" });
            try c.pair.git.exec(io, &.{ "pull", "origin", "main" });
            {
                var outcome = try c.pullHere(io, "origin", .{ .refspecs = &.{"main"} });
                defer outcome.deinit();
                try std.testing.expect(outcome.result.? == .initial);
            }
            try c.expectSame(io);
        }
    }.inFormat);
}

test "a pull whose fetch moves the branch checked out brings the working tree along, as git pull does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var c: Clones = undefined;
            try Clones.init(gpa, io, &c, format, script);
            defer c.deinit();
            try c.upstreamCommit(io, "a", "1\n2\nup\n", "up a");
            try c.pair.git.exec(io, &.{ "pull", "origin", "main:main" });
            {
                var outcome = try c.pullHere(io, "origin", .{ .refspecs = &.{"main:main"} });
                defer outcome.deinit();
                try std.testing.expect(outcome.moved_from != null);
                try std.testing.expectEqual(merging.Outcome.Result.up_to_date, outcome.result.?.merged.result);
            }
            try c.expectSame(io);
        }
    }.inFormat);
}
