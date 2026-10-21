//! `rebase` with `rebase_merges` against git 2.55's `git rebase
//! --rebase-merges`: the sheet `plan` writes is the one git gives its
//! editor, and the rebase leaves the commits, refs and logs git's leaves.
//!
//! The branch has the shapes git's sheet has words for: two topics leaving
//! one commit (a `branch-point`), merged under a branch's name and under a
//! message's once the branch is gone, a cousin that left from upstream, an
//! octopus, and a commit upstream already has by patch id.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const suite = @import("helpers.zig");
const history = @import("history.zig");
const rebase = @import("../rebase/rebase.zig");

const Pair = history.Pair;
const who = history.who;

fn commitFile(io: Io, repo: *testgit.Repo, name: []const u8, subject: []const u8) !void {
    try repo.writeFile(io, name, subject);
    try repo.exec(io, &.{ "add", name });
    try repo.exec(io, &.{ "commit", "-q", "-m", subject });
}

fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try commitFile(io, repo, "a", "base");
    try commitFile(io, repo, "m1", "main one");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "cousin" });
    try commitFile(io, repo, "c1", "cousin work");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side", "main~1" });
    try commitFile(io, repo, "s1", "side one");
    try repo.writeFile(io, "dup", "d\n");
    try repo.exec(io, &.{ "add", "dup" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "dup change" });
    for ([_][]const u8{ "topic1", "topic2" }) |topic| {
        try repo.exec(io, &.{ "checkout", "-q", "-b", topic, "side" });
        try commitFile(io, repo, topic, topic);
    }
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.exec(io, &.{ "merge", "-q", "--no-ff", "--no-edit", "topic1" });
    try repo.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "Bring in the second topic: \xc3\xbcn\xc3\xafcode & co.", "topic2" });
    try repo.exec(io, &.{ "branch", "-D", "topic2" });
    try repo.exec(io, &.{ "merge", "-q", "--no-ff", "--no-edit", "cousin" });
    for ([_][]const u8{ "topic-a", "topic-b" }) |topic| {
        try repo.exec(io, &.{ "checkout", "-q", "-b", topic, "side" });
        try commitFile(io, repo, topic, topic);
    }
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "Octopus", "topic-a", "topic-b" });
    try commitFile(io, repo, "s9", "side last");
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "dup", "d\n");
    try repo.exec(io, &.{ "add", "dup" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "dup on main" });
    try commitFile(io, repo, "m3", "main three");
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

/// The instructions, without the help after them.
fn instructions(sheet: []const u8) []const u8 {
    return sheet[0 .. std.mem.find(u8, sheet, "\n# Rebase ") orelse sheet.len];
}

fn expectSame(pair: *Pair, io: Io) !void {
    try history.expectSameState(pair, io, &history.rebase_state, &.{ "HEAD", "refs/heads/side" });
    for ([_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
        &.{ "log", "--all", "--topo-order", "--format=%H %P%n%an <%ae> %ad%n%cn <%ce> %cd%n%B", "--date=raw" },
        &.{ "reflog", "show", "--format=%H %gs", "HEAD", "--" },
    }) |args| {
        const left = try pair.git.run(io, args);
        defer pair.gpa.free(left);
        const right = try pair.ours.run(io, args);
        defer pair.gpa.free(right);
        std.testing.expectEqualStrings(left, right) catch |err| {
            std.debug.print("git {s} differs\n", .{args[0]});
            return err;
        };
    }
}

test "rebase_merges writes git's sheet, labels and resets and merges, and makes the merges again as git does" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const cases = [_]struct { arg: []const u8, mode: rebase.RebaseMerges, config: []const []const u8 }{
                .{ .arg = "--rebase-merges", .mode = .no_rebase_cousins, .config = &.{} },
                .{ .arg = "--rebase-merges=rebase-cousins", .mode = .rebase_cousins, .config = &.{} },
                .{ .arg = "--rebase-merges", .mode = .no_rebase_cousins, .config = &.{ "rebase.maxLabelLength", "6" } },
            };
            for (cases) |case| {
                var pair: Pair = undefined;
                try Pair.init(gpa, io, &pair, format, script);
                defer pair.deinit();
                if (case.config.len != 0) for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", case.config[0], case.config[1] });

                const editor = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "keep-copy .git/relic-sheet");
                defer gpa.free(editor);
                try pair.env.put("GIT_SEQUENCE_EDITOR", editor);
                try pair.git.exec(io, &.{ "rebase", "-i", case.arg, "main" });
                _ = pair.env.swapRemove("GIT_SEQUENCE_EDITOR");
                const theirs = try pair.git.readFile(io, ".git/relic-sheet");
                defer gpa.free(theirs);
                try pair.git.dir.deleteFile(io, ".git/relic-sheet");

                var repo = try pair.open(io);
                defer repo.deinit(io);
                const main = try history.oidOf(gpa, io, &pair.ours, "main");
                const ours = try rebase.plan(gpa, io, &repo, main, .{ .who = who, .rebase_merges = case.mode });
                defer gpa.free(ours);
                std.testing.expectEqualStrings(instructions(theirs), instructions(ours)) catch |err| {
                    std.debug.print("{s} {s}: the sheets differ\n", .{ case.arg, if (case.config.len != 0) case.config[0] else "" });
                    return err;
                };
                var outcome = try rebase.start(gpa, io, &repo, main, .{ .who = who, .onto_name = "main", .interactive = true, .rebase_merges = case.mode });
                defer outcome.deinit();
                try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
                try expectSame(&pair, io);
            }
        }
    }.f);
}

test "rebase.rebaseMerges decides when nothing is given, and a mode git does not know is refused" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { value: []const u8, args: []const []const u8, given: ?rebase.RebaseMerges }{
        .{ .value = "rebase-cousins", .args = &.{ "rebase", "main" }, .given = null },
        .{ .value = "true", .args = &.{ "rebase", "--no-rebase-merges", "main" }, .given = .off },
        .{ .value = "true", .args = &.{ "rebase", "--rebase-merges=rebase-cousins", "main" }, .given = .rebase_cousins },
    };
    for (cases) |case| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, .files, script);
        defer pair.deinit();
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "rebase.rebaseMerges", case.value });
        try pair.git.exec(io, case.args);
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .rebase_merges = case.given });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
        try expectSame(&pair, io);
    }

    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "rebase.rebaseMerges", "cousins" });
    pair.git.report_failures = false;
    try std.testing.expectError(error.GitFailed, pair.git.exec(io, &.{ "rebase", "--rebase-merges", "main" }));
    var repo = try pair.open(io);
    defer repo.deinit(io);
    try std.testing.expectError(error.InvalidRebaseMergesSetting, rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .rebase_merges = .no_rebase_cousins }));
    try expectSame(&pair, io);
}
