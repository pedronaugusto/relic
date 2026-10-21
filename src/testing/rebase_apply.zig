//! `rebase` with the apply backend against git 2.55's `git rebase
//! --apply`: `format-patch` into `am --rebasing`. A clean rebase leaves
//! git's commits, refs, logs and notes; one that stops leaves git's
//! `rebase-apply`, which either side then continues, skips or aborts; and
//! the backend is chosen as git chooses it.
//!
//! The mails `rebase-apply` keeps (`0001`, ...) end in the signature of
//! whoever wrote them, git's version or none, and are not compared: only
//! their `From <commit>` lines are read back.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const history = @import("history.zig");
const rebase = @import("../rebase/rebase.zig");
const hash = @import("../hash/hash.zig");

const Pair = history.Pair;
const who = history.who;

const apply_state = [_][]const u8{
    "rebase-apply/next",            "rebase-apply/last",
    "rebase-apply/threeway",        "rebase-apply/quiet",
    "rebase-apply/sign",            "rebase-apply/utf8",
    "rebase-apply/keep",            "rebase-apply/messageid",
    "rebase-apply/scissors",        "rebase-apply/quoted-cr",
    "rebase-apply/apply-opt",       "rebase-apply/rebasing",
    "rebase-apply/applying",        "rebase-apply/abort-safety",
    "rebase-apply/original-commit", "rebase-apply/author-script",
    "rebase-apply/final-commit",    "rebase-apply/patch",
    "rebase-apply/head-name",       "rebase-apply/onto",
    "rebase-apply/orig-head",       "rebase-apply/rewritten",
    "rebase-apply/dirtyindex",      "rebase-apply/signoff",
    "rebase-apply/gpg_sign_opt",    "rebase-apply/allow_rerere_autoupdate",
    "REBASE_HEAD",                  "ORIG_HEAD",
    "AUTO_MERGE",
};

fn commitFile(io: Io, repo: *testgit.Repo, name: []const u8, text: []const u8, subject: []const u8) !void {
    try repo.writeFile(io, name, text);
    try repo.exec(io, &.{ "add", name });
    try repo.exec(io, &.{ "commit", "-q", "-m", subject });
}

/// `side`: a change to `shared` that `main` changes too, a rename, a
/// binary file and a commit `main` has as well; two of them noted.
fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "shared", "1\n2\n3\n4\n5\n6\n7\n8\n9\n");
    try repo.writeFile(io, "old-name", "a file that moves\nwith a few lines\nin it\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try commitFile(io, repo, "shared", "1\n2\nside\n4\n5\n6\n7\n8\n9\n", "side changes shared");
    try repo.exec(io, &.{ "notes", "add", "-m", "the first note" });
    try repo.exec(io, &.{ "mv", "old-name", "new-name" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "side renames" });
    try commitFile(io, repo, "bin", "\x00\x01binary\x00", "side adds a binary");
    try repo.exec(io, &.{ "notes", "add", "-m", "a note" });
    try commitFile(io, repo, "dup", "same\n", "side and main both");
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try commitFile(io, repo, "dup", "same\n", "main has it too");
    try commitFile(io, repo, "m", "m\n", "main moves");
    try repo.exec(io, &.{ "config", "notes.rewriteRef", "refs/notes/commits" });
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

/// `script` with `main` changing the line `side` changes: the first pick
/// stops.
fn conflictScript(io: Io, repo: *testgit.Repo) anyerror!void {
    try script(io, repo);
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try commitFile(io, repo, "shared", "1\n2\nmain\n4\n5\n6\n7\n8\n9\n", "main changes shared");
    try repo.exec(io, &.{ "checkout", "-q", "side" });
}

fn expectSame(pair: *Pair, io: Io) !void {
    try history.expectSameState(pair, io, &apply_state, &.{ "HEAD", "refs/heads/side" });
    for ([_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
        &.{ "log", "--all", "--topo-order", "--format=%H %P%n%an <%ae> %ad%n%cn <%ce> %cd%n%B", "--date=raw" },
        &.{ "reflog", "show", "--format=%H %gs", "HEAD", "--" },
        &.{ "reflog", "show", "--format=%H %gs", "refs/heads/side", "--" },
        &.{ "notes", "list" },
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

fn main(pair: *Pair, io: Io) !hash.Oid {
    return history.oidOf(pair.gpa, io, &pair.ours, "main");
}

test "the apply backend rebases as git's does: patches, renames and binaries applied, a commit upstream has left out, notes carried" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            try pair.git.exec(io, &.{ "rebase", "--apply", "main" });
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var outcome = try rebase.start(gpa, io, &repo, try main(&pair, io), .{ .who = who, .onto_name = "main", .backend = .apply });
            defer outcome.deinit();
            try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
            try std.testing.expectEqual(@as(usize, 3), outcome.rewritten.len);
            try expectSame(&pair, io);
        }
    }.f);
}

test "an apply rebase that stops leaves git's rebase-apply, and each side continues, skips or aborts the other's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Then = enum { proceed, skip, abort };
    for ([_]Then{ .proceed, .skip, .abort }) |then| {
        for ([_]bool{ false, true }) |git_starts| {
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, .files, conflictScript);
            defer pair.deinit();
            try history.gitMayFail(io, &pair.git, &.{ "rebase", "--apply", "main" });
            if (git_starts) {
                try history.gitMayFail(io, &pair.ours, &.{ "rebase", "--apply", "main" });
            } else {
                var repo = try pair.open(io);
                defer repo.deinit(io);
                var outcome = try rebase.start(gpa, io, &repo, try main(&pair, io), .{ .who = who, .onto_name = "main", .backend = .apply });
                defer outcome.deinit();
                try std.testing.expectEqual(rebase.Stop.conflict, outcome.stopped.?);
            }
            try expectSame(&pair, io);

            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
                try r.writeFile(io, "shared", "1\n2\nboth\n4\n5\n6\n7\n8\n9\n");
                try r.exec(io, &.{ "add", "shared" });
            }
            switch (then) {
                .proceed => try pair.git.exec(io, &.{ "rebase", "--continue" }),
                .skip => try pair.git.exec(io, &.{ "rebase", "--skip" }),
                .abort => try pair.git.exec(io, &.{ "rebase", "--abort" }),
            }
            if (git_starts) {
                var repo = try pair.open(io);
                defer repo.deinit(io);
                switch (then) {
                    .proceed, .skip => {
                        var outcome = try (if (then == .proceed) rebase.proceed(gpa, io, &repo, .{ .who = who }) else rebase.skip(gpa, io, &repo, .{ .who = who }));
                        defer outcome.deinit();
                        try std.testing.expectEqual(rebase.Outcome.Result.done, outcome.result);
                    },
                    .abort => _ = try rebase.abort(gpa, io, &repo, .{ .who = who }),
                }
            } else {
                try pair.ours.exec(io, &.{ "rebase", switch (then) {
                    .proceed => "--continue",
                    .skip => "--skip",
                    .abort => "--abort",
                } });
            }
            expectSame(&pair, io) catch |err| {
                std.debug.print("{t} after {s} stopped\n", .{ then, if (git_starts) "git" else "relic" });
                return err;
            };
        }
    }
}

test "the backend is git's choice: rebase.backend, the options only merge has, and what --apply refuses" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // `rebase.backend=apply`, and a branch with nothing of its own, which
    // is fast-forwarded.
    for ([_][]const u8{ "side", "main~2" }) |start_at| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, .files, script);
        defer pair.deinit();
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.exec(io, &.{ "config", "rebase.backend", "apply" });
            try r.exec(io, &.{ "checkout", "-q", "-B", "side", start_at });
        }
        try pair.git.exec(io, &.{ "rebase", "main" });
        var repo = try pair.open(io);
        defer repo.deinit(io);
        var outcome = try rebase.start(gpa, io, &repo, try main(&pair, io), .{ .who = who, .onto_name = "main" });
        defer outcome.deinit();
        try expectSame(&pair, io);
    }

    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    const upstream = try main(&pair, io);
    pair.git.report_failures = false;
    const refusals = [_]struct { config: []const []const u8, args: []const []const u8, options: rebase.Options, err: anyerror }{
        .{ .config = &.{}, .args = &.{ "rebase", "--apply", "--autosquash", "main" }, .options = .{ .who = who, .backend = .apply, .autosquash = true }, .err = error.RequiresMergeBackend },
        .{ .config = &.{ "rebase.rebaseMerges", "true" }, .args = &.{ "rebase", "--apply", "main" }, .options = .{ .who = who, .backend = .apply }, .err = error.ApplyWithRebaseMerges },
        .{ .config = &.{ "rebase.backend", "patch" }, .args = &.{ "rebase", "main" }, .options = .{ .who = who }, .err = error.UnknownRebaseBackend },
    };
    for (refusals) |case| {
        if (case.config.len != 0) for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", case.config[0], case.config[1] });
        try std.testing.expectError(error.GitFailed, pair.git.exec(io, case.args));
        var repo = try pair.open(io);
        defer repo.deinit(io);
        try std.testing.expectError(case.err, rebase.start(gpa, io, &repo, upstream, case.options));
        if (case.config.len != 0) for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "--unset", case.config[0] });
    }
    try expectSame(&pair, io);
}
