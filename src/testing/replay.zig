//! `replay` against git 2.55's `git replay`: the same commits made, the
//! same refs moved and logged, the same updates printed, and the same
//! refusals.
//!
//! One script builds both copies with git's dates fixed, so a commit made
//! on either side has the same name. git replays in one copy and this
//! package in the other, and the refs, every commit they reach and the logs
//! of the refs that move are compared.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const history = @import("history.zig");
const replay = @import("../commit/replay.zig");

const Pair = history.Pair;
const who = history.who;
const gitMayFail = history.gitMayFail;

fn requireReplay(io: Io) !void {
    try testgit.requireGitVersion(std.testing.allocator, io, 2, 56);
}

/// `main` two commits past the base, `topic` three on the base with `mid`
/// at its second; `main` checked out.
fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "f", "1\n2\n3\n");
    try repo.writeFile(io, "g", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "t1", "t1\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add t1" });
    try repo.writeFile(io, "g", "a\nb\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "grow g" });
    try repo.exec(io, &.{ "branch", "mid" });
    try repo.writeFile(io, "t3", "t3\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add t3" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "f", "1\n2\nthree\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "three" });
    try repo.writeFile(io, "m", "m\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add m" });
}

/// `script`, with a `topic` commit that changes the line `main` changed,
/// and one that makes `main`'s change again.
fn clashScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try script(io, repo);
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    try repo.writeFile(io, "f", "1\n2\n3\n4\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "four" });
    try repo.exec(io, &.{ "branch", "again", "mid" });
    try repo.exec(io, &.{ "checkout", "-q", "again" });
    try repo.writeFile(io, "f", "1\n2\nthree\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "three again" });
    try repo.writeFile(io, "a", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add a" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
}

/// `script`, with `topic` merging a side branch: `side` forks from `mid`
/// with two commits, `topic` gains one more and merges it, `topic` ending
/// at the merge.
fn mergeScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try script(io, repo);
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side", "mid" });
    try repo.writeFile(io, "s1", "s1\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add s1" });
    try repo.writeFile(io, "g", "a\nb\nside\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "side g" });
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    try repo.writeFile(io, "t4", "t4\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add t4" });
    try repo.exec(io, &.{ "merge", "-q", "--no-edit", "side" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
}

fn same(pair: *Pair, io: Io, args: []const []const u8) !void {
    const gpa = pair.gpa;
    const left = try pair.git.run(io, args);
    defer gpa.free(left);
    const right = try pair.ours.run(io, args);
    defer gpa.free(right);
    std.testing.expectEqualStrings(left, right) catch |err| {
        std.debug.print("git {s} differs\n", .{args[0]});
        return err;
    };
}

/// Every ref, everything they reach, and the logs of `logs`.
fn expectSame(pair: *Pair, io: Io, names: []const []const u8) !void {
    try pair.ours.exec(io, &.{ "fsck", "--strict", "--no-progress", "--no-dangling" });
    try same(pair, io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    try same(pair, io, &.{ "rev-parse", "HEAD" });
    try same(pair, io, &.{ "log", "--all", "--topo-order", "--format=%H %P%n%an <%ae> %ad%n%cn <%ce> %cd%n%B", "--date=raw" });
    for (names) |name| try same(pair, io, &.{ "reflog", "show", "--format=%H %gn <%ge> %gd %gs", "--date=raw", name, "--" });
}

/// git's `update <ref> <new> <old>` lines for `updates`.
fn printed(gpa: Allocator, updates: []const replay.Update) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (updates) |u| {
        var new: [64]u8 = undefined;
        var old: [64]u8 = undefined;
        try out.print(gpa, "update {s} {s} {s}\n", .{ u.ref, u.new.hex(&new), u.old.hex(&old) });
    }
    return out.toOwnedSlice(gpa);
}

fn run(pair: *Pair, io: Io, inputs: replay.Inputs, options: replay.Options) !replay.Outcome {
    var repo = try pair.open(io);
    defer repo.deinit(io);
    return replay.replay(pair.gpa, io, &repo, inputs, options);
}

const topic_range: replay.Inputs = .{ .include = &.{"topic"}, .exclude = &.{"main"}, .target = .{ .onto = .{ .revision = "main" } } };
const logs = [_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/topic", "refs/heads/mid" };

test "replay --onto moves the branches the revisions name, and prints them under replay.refAction=print" {
    try requireReplay(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();

            // Printed first: nothing moves.
            try pair.ours.exec(io, &.{ "config", "replay.refAction", "print" });
            const want = try pair.git.run(io, &.{ "replay", "--ref-action=print", "--onto", "main", "main..topic" });
            defer gpa.free(want);
            var shown = try run(&pair, io, topic_range, .{ .who = who });
            defer shown.deinit();
            try std.testing.expect(!shown.updated);
            const got = try printed(gpa, shown.updates);
            defer gpa.free(got);
            try std.testing.expectEqualStrings(want, got);
            try pair.ours.exec(io, &.{ "config", "--unset", "replay.refAction" });

            try pair.git.exec(io, &.{ "replay", "--onto", "main", "main..topic" });
            var moved = try run(&pair, io, topic_range, .{ .who = who });
            defer moved.deinit();
            try std.testing.expect(moved.updated);
            try expectSame(&pair, io, &logs);
        }
    }.f);
}

test "replay --onto --contained moves every branch on a commit replayed; --ref moves only the one named" {
    try requireReplay(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();

            try pair.git.exec(io, &.{ "replay", "--onto", "main", "--ref", "refs/heads/new", "main..topic" });
            var one = try run(&pair, io, topic_range, .{ .who = who, .ref = "refs/heads/new" });
            defer one.deinit();
            try expectSame(&pair, io, &(logs ++ .{"refs/heads/new"}));

            try pair.git.exec(io, &.{ "replay", "--onto", "main", "--contained", "main..topic" });
            var all = try run(&pair, io, .{ .include = &.{"topic"}, .exclude = &.{"main"}, .target = .{ .onto = .{ .revision = "main", .contained = true } } }, .{ .who = who });
            defer all.deinit();
            try expectSame(&pair, io, &logs);
        }
    }.f);
}

test "replay --advance and --revert move the branch they name" {
    try requireReplay(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();

            try pair.git.exec(io, &.{ "replay", "--advance", "main", "main..topic" });
            var advanced = try run(&pair, io, .{ .include = &.{"topic"}, .exclude = &.{"main"}, .target = .{ .advance = "main" } }, .{ .who = who });
            defer advanced.deinit();
            try expectSame(&pair, io, &logs);

            try pair.git.exec(io, &.{ "replay", "--revert", "main", "main~2..main" });
            var reverted = try run(&pair, io, .{ .include = &.{"main"}, .exclude = &.{"main~2"}, .target = .{ .revert = "main" } }, .{ .who = who });
            defer reverted.deinit();
            try expectSame(&pair, io, &logs);
        }
    }.f);
}

test "replay moves a detached HEAD, and drops a commit left empty unless asked to keep or stop" {
    try requireReplay(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, clashScript);
            defer pair.deinit();
            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "--detach", "again" });

            // `three again` makes main's change again: dropped.
            try pair.git.exec(io, &.{ "replay", "--onto", "main", "main..HEAD" });
            var dropped = try run(&pair, io, .{ .include = &.{"HEAD"}, .exclude = &.{"main"}, .target = .{ .onto = .{ .revision = "main" } } }, .{ .who = who });
            defer dropped.deinit();
            try expectSame(&pair, io, &.{ "HEAD", "refs/heads/again" });

            var stopped = try run(&pair, io, .{ .include = &.{"again"}, .exclude = &.{"main"}, .target = .{ .onto = .{ .revision = "main" } } }, .{ .who = who, .empty = .abort });
            defer stopped.deinit();
            try std.testing.expectEqual(replay.Stop.Why.became_empty, stopped.stopped.?.why);
            try std.testing.expectEqual(@as(usize, 0), stopped.updates.len);

            try pair.ours.exec(io, &.{ "config", "replay.refAction", "print" });
            var kept = try run(&pair, io, .{ .include = &.{"again"}, .exclude = &.{"main"}, .target = .{ .onto = .{ .revision = "main" } } }, .{ .who = who, .empty = .keep });
            defer kept.deinit();
            try std.testing.expect(kept.stopped == null and !kept.updated);
            try std.testing.expectEqualStrings("refs/heads/again", kept.updates[0].ref);
        }
    }.f);
}

test "replay stops at a conflict with nothing moved, and refuses what git refuses" {
    try requireReplay(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, clashScript);
            defer pair.deinit();

            try gitMayFail(io, &pair.git, &.{ "replay", "--onto", "main", "main..topic" });
            var conflicted = try run(&pair, io, topic_range, .{ .who = who });
            defer conflicted.deinit();
            try std.testing.expectEqual(replay.Stop.Why.conflicted, conflicted.stopped.?.why);
            try std.testing.expect(!conflicted.updated);
            const four = try pair.ours.run(io, &.{ "rev-parse", "topic" });
            defer gpa.free(four);
            var hex: [64]u8 = undefined;
            try std.testing.expectEqualStrings(std.mem.trimEnd(u8, four, "\n"), conflicted.stopped.?.commit.hex(&hex));
            try expectSame(&pair, io, &logs);

            const onto: replay.Target = .{ .onto = .{ .revision = "main" } };
            try std.testing.expectError(error.NoCommitsToReplay, run(&pair, io, .{ .include = &.{}, .target = onto }, .{ .who = who }));
            try std.testing.expectError(error.NotAReference, run(&pair, io, .{ .include = &.{"topic"}, .exclude = &.{"main"}, .target = .{ .advance = "main~1" } }, .{ .who = who }));
            try std.testing.expectError(error.MultipleRanges, run(&pair, io, .{ .include = &.{ "topic", "mid" }, .exclude = &.{"main"}, .target = .{ .revert = "main" } }, .{ .who = who }));
            try std.testing.expectError(error.RefWithMultipleRanges, run(&pair, io, .{ .include = &.{ "topic", "again" }, .exclude = &.{"main"}, .target = onto }, .{ .who = who, .ref = "refs/heads/x" }));
            try std.testing.expectError(error.InvalidRefName, run(&pair, io, topic_range, .{ .who = who, .ref = "heads/x" }));
            try std.testing.expectError(error.RefWithContained, run(&pair, io, .{ .include = &.{"topic"}, .target = .{ .onto = .{ .revision = "main", .contained = true } } }, .{ .who = who, .ref = "refs/heads/x" }));
            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "merge", "-q", "--no-edit", "mid" });
            try std.testing.expectError(error.MergeCommit, run(&pair, io, .{ .include = &.{"main"}, .exclude = &.{"main~1"}, .target = .{ .onto = .{ .revision = "main~1" } } }, .{ .who = who }));
            try pair.ours.exec(io, &.{ "config", "replay.refAction", "move" });
            try std.testing.expectError(error.InvalidRefAction, run(&pair, io, topic_range, .{ .who = who }));
            // git refuses each of these too.
            pair.git.report_failures = false;
            for ([_][]const []const u8{
                &.{ "replay", "--advance", "main~1", "main..topic" },
                &.{ "replay", "--revert", "main", "main..topic", "mid" },
                &.{ "replay", "--onto", "main", "--ref", "refs/heads/x", "main..topic", "again" },
                &.{ "replay", "--onto", "main", "--ref", "heads/x", "main..topic" },
                &.{ "replay", "--onto", "main~1", "main~1..main" },
            }) |args| try std.testing.expectError(error.GitFailed, pair.git.exec(io, args));
        }
    }.f);
}

test "replay --linearize drops the merges and lays the rest out in a line, its branch at the last commit made, as git 2.56's" {
    try requireReplay(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, mergeScript);
            defer pair.deinit();
            const onto: replay.Target = .{ .onto = .{ .revision = "main" } };
            try std.testing.expectError(error.MergeCommit, run(&pair, io, topic_range, .{ .who = who }));
            try std.testing.expectError(error.LinearizeWithContained, run(&pair, io, .{ .include = &.{"topic"}, .exclude = &.{"main"}, .target = .{ .onto = .{ .revision = "main", .contained = true } } }, .{ .who = who, .linearize = true }));
            try std.testing.expectError(error.LinearizeWithMultipleBranches, run(&pair, io, .{ .include = &.{ "topic", "side" }, .exclude = &.{"main"}, .target = onto }, .{ .who = who, .linearize = true }));
            pair.git.report_failures = false;
            for ([_][]const []const u8{
                &.{ "replay", "--onto", "main", "main..topic" },
                &.{ "replay", "--linearize", "--contained", "--onto", "main", "main..topic" },
                &.{ "replay", "--linearize", "--onto", "main", "main..topic", "main..side" },
            }) |args| try std.testing.expectError(error.GitFailed, pair.git.exec(io, args));
            pair.git.report_failures = true;

            try pair.git.exec(io, &.{ "replay", "--linearize", "--onto", "main", "main..topic" });
            var moved = try run(&pair, io, topic_range, .{ .who = who, .linearize = true });
            defer moved.deinit();
            try std.testing.expect(moved.updated);
            try expectSame(&pair, io, &.{ "HEAD", "refs/heads/main", "refs/heads/topic", "refs/heads/side" });
            // The line: every commit but the merge, one parent each.
            const merges = try pair.ours.run(io, &.{ "rev-list", "--merges", "main..topic" });
            defer gpa.free(merges);
            try std.testing.expectEqualStrings("", merges);
        }
    }.f);
}
