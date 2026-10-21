//! `history` against git 2.55's `git history`: `fixup`, `reword` and
//! `split` each leave the same commits, refs and logs, print the same
//! updates on a dry run, and refuse what git refuses.
//!
//! One script builds both copies with git's dates fixed. git's editor is a
//! fixture that copies a message from a file; this package is handed the
//! same message. For `split`, git's `add -p` is answered on its standard
//! input, and this package is handed the tree that leaves.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const suite = @import("helpers.zig");
const history = @import("history.zig");
const replay = @import("../commit/replay.zig");
const rewrite = @import("../commit/history.zig");
const hash = @import("../hash/hash.zig");

const Pair = history.Pair;
const who = history.who;

fn requireHistory(io: Io) !void {
    try testgit.requireGitVersion(std.testing.allocator, io, 2, 55);
}

/// `main`: base, `two` changing `a` and `b`, `three`; `side` on `two` with
/// `four`; `main` checked out.
fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "a", "1\n2\n3\n");
    try repo.writeFile(io, "b", "x\ny\nz\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.writeFile(io, "a", "1\n2\nthree\n");
    try repo.writeFile(io, "b", "x\ny\nzed\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "two", "-m", "Two's body." });
    try repo.exec(io, &.{ "branch", "side" });
    try repo.writeFile(io, "c", "c\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "three" });
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.writeFile(io, "d", "d\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "four" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
}

const message = "Reworded\n\n# not kept\nWith a body.\n\n\n";

/// git's editor writes `message`.
fn useMessage(pair: *Pair, io: Io) !void {
    try pair.git.writeFile(io, ".git/relic-message", message);
    const editor = try testgit.fixtureCommand(pair.gpa, suite.path(.process_fixture), "copy-file .git/relic-message");
    defer pair.gpa.free(editor);
    try pair.env.put("GIT_EDITOR", editor);
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

/// Every ref, everything they reach, the index and the logs that move.
fn expectSame(pair: *Pair, io: Io) !void {
    try pair.ours.exec(io, &.{ "fsck", "--strict", "--no-progress", "--no-dangling" });
    try same(pair, io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    try same(pair, io, &.{ "rev-parse", "HEAD" });
    try same(pair, io, &.{ "ls-files", "--stage" });
    try same(pair, io, &.{ "log", "--all", "--topo-order", "--format=%H %P%n%an <%ae> %ad%n%cn <%ce> %cd%n%B", "--date=raw" });
    for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/side" }) |name| {
        try same(pair, io, &.{ "reflog", "show", "--format=%H %gn <%ge> %gd %gs", "--date=raw", name, "--" });
    }
}

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

test "history reword rewrites a message and moves the branches on and above it, or HEAD alone" {
    try requireHistory(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            try useMessage(&pair, io);
            var repo = try pair.open(io);
            defer repo.deinit(io);

            // A dry run first: nothing moves.
            const want = try pair.git.run(io, &.{ "history", "reword", "--dry-run", "main~1" });
            defer gpa.free(want);
            var dry = try rewrite.reword(gpa, io, &repo, .{ .commit = "main~1", .message = message }, .{ .who = who, .dry_run = true });
            defer dry.deinit();
            const got = try printed(gpa, dry.updates);
            defer gpa.free(got);
            try std.testing.expectEqualStrings(want, got);
            try std.testing.expect(!dry.updated);

            try pair.git.exec(io, &.{ "history", "reword", "--update-refs=head", "main~1" });
            var head = try rewrite.reword(gpa, io, &repo, .{ .commit = "main~1", .message = message }, .{ .who = who, .update_refs = .head });
            defer head.deinit();
            try expectSame(&pair, io);

            try pair.git.exec(io, &.{ "history", "reword", "side" });
            var branches = try rewrite.reword(gpa, io, &repo, .{ .commit = "side", .message = message }, .{ .who = who });
            defer branches.deinit();
            try expectSame(&pair, io);

            try std.testing.expectError(error.NotAncestorOfHead, rewrite.reword(gpa, io, &repo, .{ .commit = "side", .message = message }, .{ .who = who, .update_refs = .head }));
            try std.testing.expectError(error.EmptyMessage, rewrite.reword(gpa, io, &repo, .{ .commit = "side", .message = "# only a comment\n\n" }, .{ .who = who }));
        }
    }.f);
}

test "history fixup merges what is staged into a commit, and drops one it leaves empty" {
    try requireHistory(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            try useMessage(&pair, io);
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const both = [_]*testgit.Repo{ &pair.git, &pair.ours };

            try std.testing.expectError(error.NothingStaged, rewrite.fixup(gpa, io, &repo, .{ .commit = "main~1" }, .{ .who = who }));

            // `b`'s first line, which `two` did not touch, fixed in `two`,
            // with the message edited.
            for (both) |r| {
                try r.writeFile(io, "b", "X\ny\nzed\n");
                try r.exec(io, &.{ "add", "b" });
            }
            try pair.git.exec(io, &.{ "history", "fixup", "--reedit-message", "main~1" });
            var fixed = try rewrite.fixup(gpa, io, &repo, .{ .commit = "main~1", .message = message }, .{ .who = who });
            defer fixed.deinit();
            try expectSame(&pair, io);

            // `a`'s change in `two` undone: `two` is left empty and dropped.
            for (both) |r| {
                try r.writeFile(io, "a", "1\n2\n3\n");
                try r.writeFile(io, "b", "x\ny\nz\n");
                try r.exec(io, &.{ "add", "a", "b" });
            }
            try pair.git.exec(io, &.{ "history", "fixup", "main~1" });
            var dropped = try rewrite.fixup(gpa, io, &repo, .{ .commit = "main~1" }, .{ .who = who });
            defer dropped.deinit();
            try expectSame(&pair, io);

            // A staged change the commit conflicts with.
            for (both) |r| {
                try r.writeFile(io, "c", "see\n");
                try r.exec(io, &.{ "add", "c" });
            }
            try std.testing.expectError(error.FixupConflicts, rewrite.fixup(gpa, io, &repo, .{ .commit = "main~1" }, .{ .who = who }));
            pair.git.report_failures = false;
            try std.testing.expectError(error.GitFailed, pair.git.exec(io, &.{ "history", "fixup", "main~1" }));
        }
    }.f);
}

test "history split makes a commit two, the picked changes first" {
    try requireHistory(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            try useMessage(&pair, io);
            var repo = try pair.open(io);
            defer repo.deinit(io);

            // `a`'s hunk picked, `b`'s left.
            const out = try testremote.gitInputEnv(gpa, io, pair.git.dir, &pair.env, &.{ "history", "split", "main~1" }, "y\nn\n", true);
            gpa.free(out);
            const tree_hex = try pair.git.run(io, &.{ "rev-parse", "main~2^{tree}" });
            defer gpa.free(tree_hex);
            const raw = try pair.git.run(io, &.{ "cat-file", "tree", std.mem.trimEnd(u8, tree_hex, "\n") });
            defer gpa.free(raw);
            const written = try testremote.gitInput(gpa, io, pair.ours.dir, &.{ "hash-object", "-t", "tree", "-w", "--stdin" }, raw);
            defer gpa.free(written);
            const first = try hash.Oid.parse(.sha1, std.mem.trimEnd(u8, written, "\n"));
            for ([_]struct { []const u8, anyerror }{ .{ "main~2^{tree}", error.SplitCommitEmpty }, .{ "main~1^{tree}", error.SplitMatchesOriginal } }) |case| {
                const hex = try pair.ours.run(io, &.{ "rev-parse", case[0] });
                defer gpa.free(hex);
                const tree = try hash.Oid.parse(.sha1, std.mem.trimEnd(u8, hex, "\n"));
                try std.testing.expectError(case[1], rewrite.split(gpa, io, &repo, .{ .commit = "main~1", .first = tree, .messages = .{ message, message } }, .{ .who = who }));
            }
            var split = try rewrite.split(gpa, io, &repo, .{ .commit = "main~1", .first = first, .messages = .{ message, message } }, .{ .who = who });
            defer split.deinit();
            try expectSame(&pair, io);
        }
    }.f);
}

test "history refuses a merge among what it would replay" {
    try requireHistory(std.testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            try useMessage(&pair, io);
            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "merge", "-q", "--no-edit", "side" });
            var repo = try pair.open(io);
            defer repo.deinit(io);
            try std.testing.expectError(error.MergeCommit, rewrite.reword(gpa, io, &repo, .{ .commit = "main~2", .message = message }, .{ .who = who }));
            pair.git.report_failures = false;
            try std.testing.expectError(error.GitFailed, pair.git.exec(io, &.{ "history", "reword", "main~2" }));
            try expectSame(&pair, io);
        }
    }.f);
}
