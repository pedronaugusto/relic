//! `rebase`'s options and the settings behind them against git 2.55's
//! `git rebase`: each leaves the commits, refs and logs git's leaves.
//!
//! `--fork-point`: `side` was made from `upstream` when it had `u2`, and
//! `upstream` was rewritten since without it. git finds where `side`
//! forked from `upstream`'s reflog and leaves `u2` out, by default when
//! the upstream is the branch's own.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const history = @import("history.zig");
const rebase = @import("../rebase/rebase.zig");

const Pair = history.Pair;
const who = history.who;

fn commitFile(io: Io, repo: *testgit.Repo, name: []const u8, subject: []const u8) !void {
    try repo.writeFile(io, name, subject);
    try repo.exec(io, &.{ "add", name });
    try repo.exec(io, &.{ "commit", "-q", "-m", subject });
}

fn forkScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try commitFile(io, repo, "a", "base");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "upstream" });
    try commitFile(io, repo, "u1", "upstream one");
    try commitFile(io, repo, "u2", "upstream two");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try repo.exec(io, &.{ "config", "branch.side.remote", "." });
    try repo.exec(io, &.{ "config", "branch.side.merge", "refs/heads/upstream" });
    try commitFile(io, repo, "s1", "side one");
    try commitFile(io, repo, "s2", "side two");
    try repo.exec(io, &.{ "checkout", "-q", "upstream" });
    try repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try commitFile(io, repo, "u3", "upstream three");
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

/// `forkScript` with `upstream` only taken back: `side` is still a straight
/// line from it, and would be up to date but for the fork point.
fn droppedScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try forkScript(io, repo);
    try repo.exec(io, &.{ "update-ref", "-m", "back", "refs/heads/upstream", "upstream~1" });
}

fn expectSame(pair: *Pair, io: Io) !void {
    try history.expectSameState(pair, io, &history.rebase_state, &.{ "HEAD", "refs/heads/side" });
    for ([_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
        &.{ "log", "--all", "--topo-order", "--format=%H %P%n%an <%ae> %ad%n%cn <%ce> %cd%n%B", "--date=raw" },
    }) |args| {
        const left = try pair.git.run(io, args);
        defer pair.gpa.free(left);
        const right = try pair.ours.run(io, args);
        defer pair.gpa.free(right);
        try std.testing.expectEqualStrings(left, right);
    }
}

test "the fork point leaves out what the upstream dropped: by default for the branch's own upstream, when asked, and not when rebase.forkPoint is false" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const cases = [_]struct { args: []const []const u8, config: ?[]const u8 = null, options: rebase.Options, script: *const fn (Io, *testgit.Repo) anyerror!void = forkScript }{
                .{ .args = &.{"rebase"}, .options = .{ .who = who, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" }, .script = droppedScript },
                .{ .args = &.{ "rebase", "upstream" }, .options = .{ .who = who, .upstream_name = "upstream", .onto_name = "upstream" }, .script = droppedScript },
                .{ .args = &.{"rebase"}, .options = .{ .who = who, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" } },
                .{ .args = &.{ "rebase", "--no-fork-point" }, .options = .{ .who = who, .fork_point = false, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" } },
                .{ .args = &.{"rebase"}, .config = "false", .options = .{ .who = who, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" } },
                .{ .args = &.{ "rebase", "upstream" }, .options = .{ .who = who, .upstream_name = "upstream", .onto_name = "upstream" } },
                .{ .args = &.{ "rebase", "--fork-point", "upstream" }, .options = .{ .who = who, .fork_point = true, .upstream_name = "upstream", .onto_name = "upstream" } },
                .{ .args = &.{ "rebase", "-i", "--fork-point", "upstream" }, .options = .{ .who = who, .fork_point = true, .interactive = true, .upstream_name = "upstream", .onto_name = "upstream" } },
            };
            for (cases) |case| {
                var pair: Pair = undefined;
                try Pair.init(gpa, io, &pair, format, case.script);
                defer pair.deinit();
                if (case.config) |value| for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "rebase.forkPoint", value });
                try pair.git.exec(io, case.args);
                var repo = try pair.open(io);
                defer repo.deinit(io);
                var outcome = try rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "upstream"), case.options);
                defer outcome.deinit();
                expectSame(&pair, io) catch |err| {
                    std.debug.print("git {s} differs\n", .{case.args[case.args.len - 1]});
                    return err;
                };
            }
        }
    }.f);
}
