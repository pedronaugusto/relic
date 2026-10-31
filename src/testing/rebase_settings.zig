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

/// A rebase by git and by relic of a fresh pair, as `args` and `options` ask.
const ForkRebase = struct { args: []const []const u8, config: ?[]const u8 = null, options: rebase.Options, script: *const fn (Io, *testgit.Repo) anyerror!void = forkScript };

/// `cases` against git's in each ref format git writes, each in a pair of its own. A
/// pair is several processes of git's, slow to start on macOS and Windows, so a test
/// holds a few.
fn expectForkPoints(comptime cases: []const ForkRebase) !void {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
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

test "the fork point leaves out what the upstream dropped: by default for the branch's own upstream, and not by --no-fork-point or rebase.forkPoint false" {
    try expectForkPoints(&.{
        .{ .args = &.{"rebase"}, .options = .{ .who = who, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" }, .script = droppedScript },
        .{ .args = &.{ "rebase", "upstream" }, .options = .{ .who = who, .upstream_name = "upstream", .onto_name = "upstream" }, .script = droppedScript },
        .{ .args = &.{"rebase"}, .options = .{ .who = who, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" } },
        .{ .args = &.{ "rebase", "--no-fork-point" }, .options = .{ .who = who, .fork_point = false, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" } },
        .{ .args = &.{"rebase"}, .config = "false", .options = .{ .who = who, .default_upstream = true, .upstream_name = "refs/heads/upstream", .onto_name = "refs/heads/upstream" } },
    });
}

test "the fork point leaves out what the upstream dropped: not for an upstream named unless asked, and when asked, interactive too" {
    try expectForkPoints(&.{
        .{ .args = &.{ "rebase", "upstream" }, .options = .{ .who = who, .upstream_name = "upstream", .onto_name = "upstream" } },
        .{ .args = &.{ "rebase", "--fork-point", "upstream" }, .options = .{ .who = who, .fork_point = true, .upstream_name = "upstream", .onto_name = "upstream" } },
        .{ .args = &.{ "rebase", "-i", "--fork-point", "upstream" }, .options = .{ .who = who, .fork_point = true, .interactive = true, .upstream_name = "upstream", .onto_name = "upstream" } },
    });
}

const suite = @import("helpers.zig");

/// `side`: `first`, `second`, `fixup! first`, with `part` on `second`;
/// `main` moves on.
fn settingsScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try commitFile(io, repo, "a", "base");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try commitFile(io, repo, "f1", "first");
    try commitFile(io, repo, "f2", "second");
    try repo.exec(io, &.{ "branch", "part" });
    try repo.writeFile(io, "f1", "first, fixed");
    try repo.exec(io, &.{ "commit", "-q", "-am", "fixup! first" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try commitFile(io, repo, "m", "main moves");
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

const settings_state = history.rebase_state ++ [_][]const u8{
    "rebase-merge/reschedule-failed-exec", "rebase-merge/dropped",
    "rebase-merge/update-refs",            "rebase-merge/git-rebase-todo.backup",
};

fn expectSameSettings(pair: *Pair, io: Io) !void {
    try history.expectSameState(pair, io, &settings_state, &.{ "HEAD", "refs/heads/side", "refs/heads/part" });
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

test "rebase.autoSquash, rebase.updateRefs and rebase.rescheduleFailedExec decide what is not given, autoSquash only for an interactive rebase" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { config: []const u8, value: []const u8 = "true", args: []const []const u8, options: rebase.Options }{
        .{ .config = "rebase.autoSquash", .args = &.{ "rebase", "-i", "main" }, .options = .{ .who = who, .onto_name = "main", .interactive = true } },
        .{ .config = "rebase.autoSquash", .args = &.{ "rebase", "main" }, .options = .{ .who = who, .onto_name = "main" } },
        .{ .config = "rebase.autoSquash", .args = &.{ "rebase", "-i", "--no-autosquash", "main" }, .options = .{ .who = who, .onto_name = "main", .interactive = true, .autosquash = false } },
        .{ .config = "rebase.updateRefs", .args = &.{ "rebase", "main" }, .options = .{ .who = who, .onto_name = "main" } },
        .{ .config = "rebase.updateRefs", .args = &.{ "rebase", "--no-update-refs", "main" }, .options = .{ .who = who, .onto_name = "main", .update_refs = false } },
        .{ .config = "rebase.rescheduleFailedExec", .args = &.{ "rebase", "--exec", "false", "main" }, .options = .{ .who = who, .onto_name = "main", .exec = &.{"false"} } },
        .{ .config = "rebase.rescheduleFailedExec", .value = "false", .args = &.{ "rebase", "--reschedule-failed-exec", "--exec", "false", "main" }, .options = .{ .who = who, .onto_name = "main", .exec = &.{"false"}, .reschedule_failed_exec = true } },
    };
    for (cases) |case| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, .files, settingsScript);
        defer pair.deinit();
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", case.config, case.value });
        try history.gitMayFail(io, &pair.git, case.args);
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var options = case.options;
        options.programs = .{ .environ = &pair.env };
        var outcome = try rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), options);
        defer outcome.deinit();
        expectSameSettings(&pair, io) catch |err| {
            std.debug.print("{s}={s}: git {s} differs\n", .{ case.config, case.value, case.args[1] });
            return err;
        };
    }
}

test "rebase.instructionFormat writes the sheet's lines, and %h is the full name as git's sheet gives it" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "%h %an: %s", "#%s [%ae]" }) |format| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, .files, settingsScript);
        defer pair.deinit();
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "rebase.instructionFormat", format });
        const editor = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "keep-copy .git/relic-sheet");
        defer gpa.free(editor);
        try pair.env.put("GIT_SEQUENCE_EDITOR", editor);
        try pair.git.exec(io, &.{ "rebase", "-i", "main" });
        _ = pair.env.swapRemove("GIT_SEQUENCE_EDITOR");
        const theirs = try pair.git.readFile(io, ".git/relic-sheet");
        defer gpa.free(theirs);
        try pair.git.dir.deleteFile(io, ".git/relic-sheet");
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const ours = try rebase.plan(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), .{ .who = who });
        defer gpa.free(ours);
        try std.testing.expectEqualStrings(theirs[0 .. std.mem.find(u8, theirs, "\n# Rebase ") orelse theirs.len], ours[0 .. std.mem.find(u8, ours, "\n# Rebase ") orelse ours.len]);
    }
}

test "rebase.missingCommitsCheck=error refuses a sheet that leaves commits out, until it is corrected, as git's does" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, settingsScript);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "rebase.missingCommitsCheck", "error" });
    const first = try history.oidOf(gpa, io, &pair.ours, "side~2");
    const second = try history.oidOf(gpa, io, &pair.ours, "side~1");
    const fixup = try history.oidOf(gpa, io, &pair.ours, "side");
    var hex: [3][40]u8 = undefined;
    _ = first.hex(&hex[0]);
    _ = second.hex(&hex[1]);
    _ = fixup.hex(&hex[2]);
    const short = try gpa.print("pick {s} # first\npick {s} # second\n", .{ hex[0][0..], hex[1][0..] });
    defer gpa.free(short);
    try history.gitRebaseInteractive(io, &pair.git, short, &.{"main"});
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .todo = short });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.missing_commits, outcome.stopped.?);
    }
    try expectSameSettings(&pair, io);

    // Continued as it is, it is refused again; with the commit dropped by
    // name, it goes on.
    try history.gitMayFail(io, &pair.git, &.{ "rebase", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Stop.missing_commits, outcome.stopped.?);
    }
    try expectSameSettings(&pair, io);
    const corrected = try gpa.print("{s}drop {s} # fixup! first\n", .{ short, hex[2][0..] });
    defer gpa.free(corrected);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.writeFile(io, ".git/rebase-merge/git-rebase-todo", corrected);
    try pair.git.exec(io, &.{ "rebase", "--continue" });
    {
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.proceed(gpa, io, &repo, .{ .who = who });
        defer outcome.deinit();
        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
    }
    try expectSameSettings(&pair, io);
}

/// `side`: a commit whose change `main` makes too, with more beside it, so
/// no patch id leaves it out and it is dropped as empty; it has a note.
/// Then one more commit.
fn emptiedScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try commitFile(io, repo, "x", "old\n");
    try repo.exec(io, &.{ "config", "notes.rewriteRef", "refs/notes/commits" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try commitFile(io, repo, "x", "new\n");
    try repo.exec(io, &.{ "notes", "add", "-m", "a note on the change main has too" });
    try commitFile(io, repo, "z", "more\n");
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "x", "new\n");
    try repo.exec(io, &.{ "add", "x" });
    try commitFile(io, repo, "y", "main makes the change and more\n");
}

test "a commit a rebase drops as empty is not rewritten, so its note is not copied, as git 2.56's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            for ([_]bool{ false, true }) |interactive| {
                var pair: Pair = undefined;
                try Pair.init(gpa, io, &pair, format, emptiedScript);
                defer pair.deinit();
                for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "checkout", "-q", "side" });
                try pair.git.exec(io, if (interactive) &.{ "rebase", "-i", "--empty=drop", "main" } else &.{ "rebase", "main" });
                var repo = try pair.open(io);
                defer repo.deinit(io);
                var outcome = try rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .interactive = interactive, .empty = if (interactive) .drop else null, .upstream_name = "main", .onto_name = "main" });
                defer outcome.deinit();
                try expectSame(&pair, io);
                const theirs = try pair.git.run(io, &.{ "notes", "list" });
                defer gpa.free(theirs);
                const ours = try pair.ours.run(io, &.{ "notes", "list" });
                defer gpa.free(ours);
                try std.testing.expectEqualStrings(theirs, ours);
            }
        }
    }.f);
}

/// `side`: a commit, one to fold into it, one whose change to `f` meets
/// `main`'s, and one more; `main` changes `f` its own way.
fn chainScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try commitFile(io, repo, "f", "base\n");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try commitFile(io, repo, "a", "first\n");
    try commitFile(io, repo, "b", "second\n");
    try commitFile(io, repo, "f", "side's change\n");
    try commitFile(io, repo, "c", "last\n");
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try commitFile(io, repo, "f", "main's change\n");
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

/// A sheet of `<command> <rev>` lines, each rev made a full name.
fn chainSheet(gpa: std.mem.Allocator, io: Io, repo: *testgit.Repo, lines: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |line| {
        const oid = try history.oidOf(gpa, io, repo, line[1]);
        var hex: [40]u8 = undefined;
        try out.print(gpa, "{s} {s}\n", .{ line[0], oid.hex(&hex) });
    }
    return out.toOwnedSlice(gpa);
}

const edited_text = "Edited by hand\n\n# a comment the cleanup takes away\nwith a body\n";

const Editor = struct {
    fn edit(_: *anyopaque, _: rebase.MessageKind, _: []const u8) ?[]const u8 {
        return edited_text;
    }
};

test "a fixup or squash that fails and is skipped leaves the chain as git 2.56's: the message cleaned, in the editor after a squash or a fixup -c" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const chains = [_][]const [2][]const u8{
        // Skipped at the chain's end, after a fixup, a squash, a fixup -c.
        &.{ .{ "pick", "side~3" }, .{ "fixup", "side~2" }, .{ "fixup", "side~1" }, .{ "pick", "side" } },
        &.{ .{ "pick", "side~3" }, .{ "squash", "side~2" }, .{ "fixup", "side~1" }, .{ "pick", "side" } },
        &.{ .{ "pick", "side~3" }, .{ "fixup -c", "side~2" }, .{ "squash", "side~1" } },
        // Skipped mid-chain, with a fixup after it.
        &.{ .{ "pick", "side~3" }, .{ "squash", "side~1" }, .{ "fixup", "side~2" }, .{ "pick", "side" } },
        // The chain's only one.
        &.{ .{ "pick", "side~3" }, .{ "fixup", "side~1" }, .{ "pick", "side" } },
    };
    for (chains) |chain| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, .files, chainScript);
        defer pair.deinit();
        const sheet = try chainSheet(gpa, io, &pair.git, chain);
        defer gpa.free(sheet);
        errdefer std.debug.print("sheet:\n{s}", .{sheet});
        // git's editor writes the same text over whatever it is shown.
        try pair.git.writeFile(io, ".git/relic-message", edited_text);
        const editor = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "copy-file .git/relic-message");
        defer gpa.free(editor);
        try pair.env.put("GIT_EDITOR", editor);
        try history.gitRebaseInteractive(io, &pair.git, sheet, &.{"main"});
        try history.gitMayFail(io, &pair.git, &.{ "rebase", "--skip" });
        var unused: u8 = 0;
        const messages: rebase.Messages = .{ .context = &unused, .editFn = Editor.edit };
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var outcome = try rebase.start(gpa, io, &repo, try history.oidOf(gpa, io, &pair.ours, "main"), .{ .who = who, .onto_name = "main", .todo = sheet, .messages = messages });
            defer outcome.deinit();
            try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
        }
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var outcome = try rebase.skip(gpa, io, &repo, .{ .who = who, .messages = messages });
            defer outcome.deinit();
        }
        try expectSame(&pair, io);
    }
}
