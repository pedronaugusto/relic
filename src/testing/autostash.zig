//! The autostash against git's: `merge --autostash` and `rebase
//! --autostash`, with `stash create` and `stash store` under them.
//!
//! Each test builds its fixture twice, as `history.zig` does, leaves the
//! same changes in both working trees, and runs git in one copy and this
//! package in the other. The stash an operation makes is the same commit on
//! both sides, so what is compared is everything git reads back, the stash
//! list among it. Where an operation stops, each side finishes the other's.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const history = @import("history.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const merging = @import("../commit/merging.zig");
const rebase = @import("../rebase/rebase.zig");
const stash = @import("../commit/stash.zig");
const commit_mod = @import("../commit/commit.zig");

const Oid = hash.Oid;
const Pair = history.Pair;
const who = history.who;
const expectSameState = history.expectSameState;
const gitMayFail = history.gitMayFail;

/// `a`, `b` and `c` from one base. `topic` changes `a`'s last line; `main`
/// changes `a`'s first line and `c`; `clash` changes `c` as `main` does
/// not. `behind` stays at the base.
fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "a", "1\n2\n3\n");
    try repo.writeFile(io, "b", "b\n");
    try repo.writeFile(io, "c", "c\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "branch", "behind" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try repo.writeFile(io, "a", "1\n2\nthree\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "topic a" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "clash", "main" });
    try repo.writeFile(io, "c", "clash\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "clash c" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "a", "one\n2\n3\n");
    try repo.writeFile(io, "c", "main\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "main a c" });
}

const merge_state = [_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "ORIG_HEAD", "AUTO_MERGE", "MERGE_AUTOSTASH" };

const rebase_state = [_][]const u8{
    "rebase-merge/autostash",      "rebase-merge/done", "rebase-merge/git-rebase-todo",
    "rebase-merge/head-name",      "rebase-merge/onto", "rebase-merge/orig-head",
    "rebase-merge/stopped-sha",    "REBASE_HEAD",       "ORIG_HEAD",
    "rebase-merge/rewritten-list", "MERGE_AUTOSTASH",
};

/// The same edits in both working trees.
fn bothWrite(pair: *Pair, io: Io, path: []const u8, bytes: []const u8) !void {
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.writeFile(io, path, bytes);
}

fn both(pair: *Pair, io: Io, args: []const []const u8) !void {
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, args);
}

fn oidOf(gpa: Allocator, io: Io, repo: *testgit.Repo, rev: []const u8) !Oid {
    const text = try repo.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

/// Merge `name` here, with the autostash asked for.
fn mergeHere(pair: *Pair, io: Io, name: []const u8, options: merging.Options) !merging.Outcome {
    var repo = try pair.open(io);
    defer repo.deinit(io);
    const target = try merging.resolve(pair.gpa, io, &repo, name);
    return merging.start(pair.gpa, io, &repo, target, options);
}

fn rebaseHere(pair: *Pair, io: Io, upstream: []const u8, options: rebase.Options) !rebase.Outcome {
    var repo = try pair.open(io);
    defer repo.deinit(io);
    var given = options;
    given.onto_name = upstream;
    return rebase.start(pair.gpa, io, &repo, try oidOf(pair.gpa, io, &pair.ours, upstream), given);
}

test "a merge puts the changes in its way aside and brings them back, applied or kept on the list, as git's does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            const logs = [_][]const u8{ "HEAD", "refs/heads/main", "refs/stash" };

            // A change the merge does not touch, and a staged one: both come
            // back, the staged one unstaged as `git stash apply` leaves it.
            try bothWrite(&pair, io, "b", "dirty\n");
            try bothWrite(&pair, io, "c", "staged\n");
            try both(&pair, io, &.{ "add", "c" });
            try pair.git.exec(io, &.{ "merge", "--autostash", "--no-edit", "topic" });
            {
                var outcome = try mergeHere(&pair, io, "topic", .{ .who = who, .autostash = true });
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.merged, outcome.result);
                try std.testing.expect(outcome.autostash != null);
                try std.testing.expectEqual(stash.Restored.applied, outcome.restored.?);
            }
            try expectSameState(&pair, io, &merge_state, &logs);

            // One that conflicts with what the merge brought: kept on the
            // list, its conflict in the working tree.
            try both(&pair, io, &.{ "reset", "-q", "--hard", "main~1" });
            try bothWrite(&pair, io, "a", "one\n2\nmine\n");
            try pair.git.exec(io, &.{ "merge", "--autostash", "--no-edit", "topic" });
            {
                var outcome = try mergeHere(&pair, io, "topic", .{ .who = who, .autostash = true });
                defer outcome.deinit();
                try std.testing.expectEqual(stash.Restored.conflicted, outcome.restored.?);
            }
            try expectSameState(&pair, io, &merge_state, &logs);

            // A fast-forward, by `merge.autoStash`.
            try both(&pair, io, &.{ "reset", "-q", "--hard" });
            try both(&pair, io, &.{ "checkout", "-q", "behind" });
            try both(&pair, io, &.{ "config", "merge.autoStash", "true" });
            try bothWrite(&pair, io, "b", "dirty again\n");
            try pair.git.exec(io, &.{ "merge", "topic" });
            {
                var outcome = try mergeHere(&pair, io, "topic", .{ .who = who });
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.fast_forward, outcome.result);
                try std.testing.expectEqual(stash.Restored.applied, outcome.restored.?);
            }
            try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/behind", "refs/stash" });

            // Nothing to merge: nothing put aside.
            try pair.git.exec(io, &.{ "merge", "topic" });
            {
                var outcome = try mergeHere(&pair, io, "topic", .{ .who = who });
                defer outcome.deinit();
                try std.testing.expectEqual(merging.Outcome.Result.up_to_date, outcome.result);
                try std.testing.expect(outcome.autostash == null);
            }
            try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/behind", "refs/stash" });

            // A value that is no boolean: git dies, and nothing moves.
            try both(&pair, io, &.{ "config", "merge.autoStash", "maybe" });
            try gitMayFail(io, &pair.git, &.{ "merge", "main" });
            try std.testing.expectError(error.NotABoolean, mergeHere(&pair, io, "main", .{ .who = who }));
            try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/behind", "refs/stash" });
        }
    }.inFormat);
}

test "a stopped merge keeps its autostash in MERGE_AUTOSTASH until either side commits or aborts it" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            const logs = [_][]const u8{ "HEAD", "refs/heads/main", "refs/stash" };
            const start = try pair.git.line(io, &.{ "rev-parse", "main" });
            defer gpa.free(start);

            for ([_]bool{ false, true }) |aborting| {
                try bothWrite(&pair, io, "b", "dirty\n");
                try gitMayFail(io, &pair.git, &.{ "merge", "--autostash", "clash" });
                {
                    var outcome = try mergeHere(&pair, io, "clash", .{ .who = who, .autostash = true });
                    defer outcome.deinit();
                    try std.testing.expectEqual(merging.Outcome.Result.conflicted, outcome.result);
                    try std.testing.expect(outcome.restored == null);
                }
                try expectSameState(&pair, io, &merge_state, &logs);

                // Each side finishes the merge the other started.
                if (aborting) {
                    try pair.ours.exec(io, &.{ "merge", "--abort" });
                    var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
                    defer repo.deinit(io);
                    try std.testing.expectEqual(stash.Restored.applied, (try merging.abort(gpa, io, &repo, .{ .who = who })).?);
                } else {
                    try bothWrite(&pair, io, "c", "resolved\n");
                    try both(&pair, io, &.{ "add", "c" });
                    try pair.ours.exec(io, &.{ "commit", "-q", "--no-edit" });
                    var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
                    defer repo.deinit(io);
                    const concluded = try merging.conclude(gpa, io, &repo, .{ .who = who, .cleanup = .whitespace });
                    try std.testing.expectEqual(stash.Restored.applied, concluded.restored.?);
                }
                try expectSameState(&pair, io, &merge_state, &logs);
                try both(&pair, io, &.{ "reset", "-q", "--hard", start });
            }
        }
    }.inFormat);
}

test "a rebase puts the changes in its way aside and brings them back where git's does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            try testgit.requireGitVersion(gpa, io, 2, 50);
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            const logs = [_][]const u8{ "HEAD", "refs/heads/topic", "refs/stash" };
            try both(&pair, io, &.{ "checkout", "-q", "topic" });
            const start = try pair.git.line(io, &.{ "rev-parse", "topic" });
            defer gpa.free(start);

            // Applied at the end.
            try bothWrite(&pair, io, "b", "dirty\n");
            try pair.git.exec(io, &.{ "rebase", "--autostash", "main" });
            {
                var outcome = try rebaseHere(&pair, io, "main", .{ .who = who, .autostash = true });
                defer outcome.deinit();
                try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
                try std.testing.expect(outcome.autostash != null);
                try std.testing.expectEqual(stash.Restored.applied, outcome.restored.?);
            }
            try expectSameState(&pair, io, &rebase_state, &logs);

            // Already there, by `rebase.autoStash`: put aside and given back.
            try both(&pair, io, &.{ "config", "rebase.autoStash", "true" });
            try pair.git.exec(io, &.{ "rebase", "main" });
            {
                var outcome = try rebaseHere(&pair, io, "main", .{ .who = who });
                defer outcome.deinit();
                try std.testing.expectEqual(rebase.Outcome.Result.up_to_date, outcome.result);
                try std.testing.expectEqual(stash.Restored.applied, outcome.restored.?);
            }
            try expectSameState(&pair, io, &rebase_state, &logs);

            // A change the replayed commits conflict with: kept on the list.
            try both(&pair, io, &.{ "reset", "-q", "--hard", start });
            try bothWrite(&pair, io, "a", "uno\n2\nthree\n");
            try pair.git.exec(io, &.{ "rebase", "main" });
            {
                var outcome = try rebaseHere(&pair, io, "main", .{ .who = who });
                defer outcome.deinit();
                try std.testing.expectEqual(stash.Restored.conflicted, outcome.restored.?);
            }
            try expectSameState(&pair, io, &rebase_state, &logs);

            // A sheet left empty: nothing to do, the work given back, and no
            // state left.
            try both(&pair, io, &.{ "reset", "-q", "--hard", start });
            try bothWrite(&pair, io, "b", "dirty\n");
            try history.gitRebaseInteractive(io, &pair.git, "", &.{ "--autostash", "main" });
            try std.testing.expectError(error.NothingToDo, rebaseHere(&pair, io, "main", .{ .who = who, .autostash = true, .todo = "" }));
            try expectSameState(&pair, io, &rebase_state, &logs);

            // A value that is no boolean: git dies before anything is put
            // aside.
            try both(&pair, io, &.{ "reset", "-q", "--hard", start });
            try bothWrite(&pair, io, "b", "dirty\n");
            try both(&pair, io, &.{ "config", "rebase.autoStash", "maybe" });
            try gitMayFail(io, &pair.git, &.{ "rebase", "main" });
            try std.testing.expectError(error.NotABoolean, rebaseHere(&pair, io, "main", .{ .who = who }));
            try expectSameState(&pair, io, &rebase_state, &logs);
        }
    }.inFormat);
}

test "a stopped rebase keeps its autostash in rebase-merge until either side continues, aborts or quits it" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            try testgit.requireGitVersion(gpa, io, 2, 50);
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            const logs = [_][]const u8{ "HEAD", "refs/heads/clash", "refs/stash" };
            try both(&pair, io, &.{ "checkout", "-q", "clash" });
            const start = try pair.git.line(io, &.{ "rev-parse", "clash" });
            defer gpa.free(start);

            for ([_][]const u8{ "--continue", "--abort", "--quit" }) |how| {
                try bothWrite(&pair, io, "b", "dirty\n");
                try gitMayFail(io, &pair.git, &.{ "rebase", "--autostash", "main" });
                {
                    var outcome = try rebaseHere(&pair, io, "main", .{ .who = who, .autostash = true });
                    defer outcome.deinit();
                    try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
                }
                try expectSameState(&pair, io, &rebase_state, &logs);

                // Each side finishes the rebase the other started.
                var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
                defer repo.deinit(io);
                if (std.mem.eql(u8, how, "--continue")) {
                    try bothWrite(&pair, io, "c", "resolved\n");
                    try both(&pair, io, &.{ "add", "c" });
                    try pair.ours.exec(io, &.{ "rebase", "--continue" });
                    var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
                    defer outcome.deinit();
                    try std.testing.expectEqual(stash.Restored.applied, outcome.restored.?);
                } else if (std.mem.eql(u8, how, "--abort")) {
                    try pair.ours.exec(io, &.{ "rebase", "--abort" });
                    try std.testing.expectEqual(stash.Restored.applied, (try rebase.abort(gpa, io, &repo, .{ .who = who })).?);
                } else {
                    try pair.ours.exec(io, &.{ "rebase", "--quit" });
                    try std.testing.expectEqual(stash.Restored.stored, (try rebase.quit(gpa, io, &repo, .{ .who = who })).?);
                }
                try expectSameState(&pair, io, &rebase_state, &logs);
                try both(&pair, io, &.{ "reset", "-q", "--hard", start });
            }
        }
    }.inFormat);
}

test "stash create and store make and list what git's do, and store refuses a commit that is no stash" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();

            try bothWrite(&pair, io, "b", "dirty\n");
            const by_git = try pair.git.line(io, &.{ "stash", "create", "kept for later" });
            defer gpa.free(by_git);
            try pair.git.exec(io, &.{ "stash", "store", "-m", "kept", by_git });
            {
                var repo = try pair.open(io);
                defer repo.deinit(io);
                const made = (try stash.create(io, &repo, .{ .who = who, .message = "kept for later" })).?;
                var hex: [hash.max_hex_len]u8 = undefined;
                try std.testing.expectEqualStrings(by_git, made.hex(&hex));
                try stash.store(io, &repo, made, .{ .who = who, .message = "kept" });
                const head = try oidOf(gpa, io, &pair.ours, "HEAD");
                try std.testing.expectError(error.NotAStash, stash.store(io, &repo, head, .{ .who = who }));
            }
            // `create` leaves the working tree as it was.
            try expectSameState(&pair, io, &.{}, &.{"refs/stash"});
        }
    }.inFormat);
}

test "a commit brings back the MERGE_AUTOSTASH a squashed merge left, as git commit does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();

            try bothWrite(&pair, io, "b", "dirty\n");
            try both(&pair, io, &.{ "merge", "-q", "--squash", "--autostash", "topic" });
            try pair.git.exec(io, &.{ "commit", "-q", "-m", "squashed" });
            {
                var repo = try pair.open(io);
                defer repo.deinit(io);
                const outcome = try commit_mod.commit(io, &repo, .{ .author = who, .committer = who, .message = "squashed" }, .{});
                try std.testing.expectEqual(stash.Restored.applied, outcome.restored.?);
            }
            try expectSameState(&pair, io, &merge_state, &.{ "HEAD", "refs/heads/main", "refs/stash" });
        }
    }.inFormat);
}
