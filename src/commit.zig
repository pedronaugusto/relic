//! Making a commit the way `git commit` does: its hooks in git's order, the
//! message cleaned as git cleans it, the tree from the index, and the branch
//! moved with its log.
//!
//! `Repository.writeCommit` is `git commit-tree`: it writes an object and
//! nothing else, and git runs no hook for it. This is the porcelain on top.
//! The order is git's own. `pre-commit` runs first, before anything is
//! written, and may change the index, so the index is read again after it.
//! The message goes into `COMMIT_EDITMSG`, where `prepare-commit-msg` and
//! then `commit-msg` may rewrite it, and what is in the file afterwards is
//! the message. Then the tree and the commit are written, `HEAD` moves —
//! the branch it names, under its lock, with a log line there and on
//! `HEAD` — and
//! `post-commit` runs last, when nothing it does can undo the commit.
//!
//! No editor is ever started: the caller supplies the message, which is
//! what `git commit -m` does, and the hooks are told so with
//! `GIT_EDITOR=:`. A merge, a cherry-pick or a revert in progress is a named
//! refusal rather than a commit that quietly drops the other parent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const index_mod = @import("index.zig");
const hooks = @import("hooks.zig");
const commithooks = @import("commithooks.zig");
const fs = @import("fs.zig");
const signing = @import("signing.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from committing.
pub const Error = error{
    /// A repository with no working tree has no index to commit.
    BareRepository,
    /// The index holds a conflict, which no tree can record.
    UnmergedIndex,
    /// The tree is the one the commit would sit on, and `allow_empty` was
    /// not asked for.
    NothingToCommit,
    /// The message is empty once cleaned, and `allow_empty_message` was not
    /// asked for.
    EmptyMessage,
    /// `amend` on a branch with no commit yet.
    NothingToAmend,
    /// `MERGE_HEAD`, `CHERRY_PICK_HEAD` or `REVERT_HEAD` is present, and a
    /// commit made here would not record what that operation needs.
    OperationInProgress,
    /// `commit.cleanup` names no mode git knows.
    InvalidCleanupMode,
} || hooks.Error || commithooks.Error || repo_mod.WriteError || refs_mod.TransactionError || worktree.Error ||
    index_mod.ReadError || Io.Dir.RealPathError || fs.CommitError || fs.LockError ||
    error{NameTooLong};

/// How a message is cleaned, from `commit.cleanup` or the caller.
pub const Cleanup = enum {
    /// Exactly as given.
    verbatim,
    /// Trailing whitespace off every line, runs of blank lines made one,
    /// blank lines off both ends, and a final newline. What git does to a
    /// message given with `-m`.
    whitespace,
    /// `whitespace`, and every line beginning with the comment character
    /// removed.
    strip,
};

/// How a commit is made.
pub const Options = struct {
    /// The hooks to run, or `null` to run none.
    hooks: ?*hooks.Runner = null,
    /// `false` skips `pre-commit` and `commit-msg`, as `--no-verify` does.
    /// `prepare-commit-msg` still runs, as it does in git.
    verify: bool = true,
    /// Replace the commit `HEAD` points at rather than add one after it.
    amend: bool = false,
    /// Commit a tree that is the same as the parent's.
    allow_empty: bool = false,
    /// Commit a message that is empty once cleaned.
    allow_empty_message: bool = false,
    /// How the message is cleaned. `null` asks `commit.cleanup`, whose
    /// default, with no editor, is `whitespace`.
    cleanup: ?Cleanup = null,
    /// `false` skips `post-rewrite` after an amend.
    post_rewrite: bool = true,
    /// Whether and how to sign it. By default `commit.gpgSign` decides,
    /// and signing needs the caller's `Programs`.
    signing: signing.Request = .{},
};

/// Who, when, and what to say. The times are the caller's, because nothing
/// in this package reads a clock.
pub const Request = struct {
    author: object.Signature,
    committer: object.Signature,
    message: []const u8,
};

/// What a commit made.
pub const Outcome = struct {
    commit: Oid,
    tree: Oid,
    /// The commit it replaced or followed, or `null` for the first.
    previous: ?Oid,
    /// How `post-commit` went. It cannot undo the commit; its status is
    /// the caller's to report.
    post_commit: hooks.Ran = .{},
};

/// `git commit -m <message>`: run the hooks, write the tree the index
/// describes and a commit of it, and move the branch `HEAD` is on.
pub fn commit(repo: *Repository, io: Io, request: Request, options: Options) Error!Outcome {
    const gpa = repo.gpa;
    if (repo.work_dir == null) return error.BareRepository;
    for ([_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD" }) |name| {
        if (repo.git_dir.access(io, name, .{})) |_| return error.OperationInProgress else |_| {}
    }
    const cleanup = options.cleanup orelse try configuredCleanup(repo);

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const current: ?Oid = if (try repo.refs.resolve(arena, io, "HEAD")) |r| r.oid else null;
    if (options.amend and current == null) return error.NothingToAmend;

    // The files named as git names them to a hook: `.git/index` and
    // `.git/COMMIT_EDITMSG` from the top of the working tree.
    const names = try commithooks.Hooks.init(arena, io, repo, options.hooks, options.verify);
    const message_path = try names.path(arena, "COMMIT_EDITMSG");
    const env = try names.env(arena, request.author);

    if (options.hooks) |runner| {
        if (options.verify) _ = try runner.preCommit(io, env);
    }

    const comment = commentPrefix(repo);
    const first_message = try clean(arena, request.message, cleanup, comment);
    try repo.git_dir.writeFile(io, .{ .sub_path = "COMMIT_EDITMSG", .data = first_message });

    // `pre-commit` may have staged something, so the index is read now and
    // not before.
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnmergedIndex;
    }
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);

    // What the new commit sits on, and what an amend carries over.
    var parents: []const Oid = &.{};
    var carried: []const object.ExtraHeader = &.{};
    if (current) |head| {
        const found = try repo.odb.read(io, head);
        defer gpa.free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        const bytes = try arena.dupe(u8, found.bytes);
        const parsed = try object.Commit.parse(arena, repo.kind, bytes);
        if (options.amend) {
            parents = parsed.parents;
            // An amend keeps the old commit's extra headers but not its
            // signature, which signed different bytes.
            var kept: std.ArrayList(object.ExtraHeader) = .empty;
            for (parsed.extra) |h| {
                if (std.mem.eql(u8, h.name, "gpgsig") or std.mem.eql(u8, h.name, "gpgsig-sha256")) continue;
                try kept.append(arena, h);
            }
            carried = kept.items;
        } else {
            parents = try arena.dupe(Oid, &.{head});
            if (!options.allow_empty and parsed.tree.eql(tree)) return error.NothingToCommit;
        }
    } else if (!options.allow_empty and index.entries.items.len == 0) {
        return error.NothingToCommit;
    }

    if (options.hooks) |runner| {
        _ = try runner.prepareCommitMsg(io, env, message_path, .message, null);
        if (options.verify) _ = try runner.commitMsg(io, env, message_path);
    }

    const edited = try repo.git_dir.readFileAlloc(io, "COMMIT_EDITMSG", arena, .limited(1 << 30));
    const message = try clean(arena, edited, cleanup, comment);
    if (!options.allow_empty_message and isEmpty(message, cleanup, comment)) return error.EmptyMessage;

    const new = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = parents,
        .author = request.author,
        .committer = request.committer,
        .message = message,
        .extra = carried,
        .signing = options.signing,
    });

    const action = if (current == null)
        "commit (initial)"
    else if (options.amend)
        "commit (amend)"
    else
        "commit";
    const subject_end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    const log_message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ action, message[0..subject_end] });
    const policy = repo.reflogPolicy();
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        tx.hooks = options.hooks;
        // Through `HEAD`, as git moves it: the branch `HEAD` names moves,
        // or `HEAD` itself when it is detached, and both logs say so.
        try tx.update("HEAD", .{ .direct = new }, if (current) |c| .{ .matches = c } else .must_not_exist);
        try tx.commit(io, .{ .who = request.committer, .message = log_message, .policy = policy });
    }

    // The cache tree now names every directory, and the index keeps it.
    try index.write(io, repo.git_dir, "index", .{});

    var outcome: Outcome = .{ .commit = new, .tree = tree, .previous = current };
    if (options.hooks) |runner| {
        outcome.post_commit = try runner.postCommit(io, env);
        if (options.amend and options.post_rewrite) {
            _ = try runner.postRewrite(io, .amend, &.{.{ .old = current.?, .new = new }});
        }
    }
    return outcome;
}

fn configuredCleanup(repo: *Repository) error{InvalidCleanupMode}!Cleanup {
    const text = repo.config.get("commit.cleanup") orelse return .whitespace;
    // With no editor, `default` and `scissors` are both `whitespace`.
    if (std.mem.eql(u8, text, "default") or std.mem.eql(u8, text, "whitespace") or
        std.mem.eql(u8, text, "scissors")) return .whitespace;
    if (std.mem.eql(u8, text, "verbatim")) return .verbatim;
    if (std.mem.eql(u8, text, "strip")) return .strip;
    return error.InvalidCleanupMode;
}

fn commentPrefix(repo: *Repository) []const u8 {
    const text = repo.config.get("core.commentstring") orelse repo.config.get("core.commentchar") orelse return "#";
    // `auto` picks a character the message does not use, which only matters
    // to an editor's template; with no template it is `#`.
    if (text.len == 0 or std.mem.eql(u8, text, "auto")) return "#";
    return text;
}

fn clean(arena: Allocator, text: []const u8, cleanup: Cleanup, comment: []const u8) Allocator.Error![]const u8 {
    return switch (cleanup) {
        .verbatim => text,
        .whitespace => stripspace(arena, text, null),
        .strip => stripspace(arena, text, comment),
    };
}

/// Whether a cleaned message says nothing: every line blank or a comment.
fn isEmpty(message: []const u8, cleanup: Cleanup, comment: []const u8) bool {
    if (cleanup == .verbatim and message.len != 0) return false;
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, comment)) continue;
        for (line) |c| {
            if (!isSpace(c)) return false;
        }
    }
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// git's `stripspace`: trailing whitespace off every line, runs of blank
/// lines made one, blank lines off both ends, and a newline after the last
/// line. With `comment`, every line beginning with it goes too. The result
/// is the caller's.
pub fn stripspace(gpa: Allocator, text: []const u8, comment: ?[]const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var empties: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const len = if (eol) |e| e - i + 1 else text.len - i;
        const line = text[i .. i + len];
        i += len;
        if (comment) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) continue;
        }
        var kept = line.len;
        while (kept > 0 and isSpace(line[kept - 1])) kept -= 1;
        if (kept != 0) {
            if (empties > 0 and out.items.len > 0) try out.append(gpa, '\n');
            empties = 0;
            try out.appendSlice(gpa, line[0..kept]);
            try out.append(gpa, '\n');
        } else {
            empties += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

//=========================================================================
// Tests
//=========================================================================

const testing = std.testing;
const testgit = @import("testgit.zig");
const builtin = @import("builtin");

test "a message is cleaned the way git's stripspace cleans it" {
    const gpa = testing.allocator;
    const cases = [_]struct { in: []const u8, comment: ?[]const u8, out: []const u8 }{
        .{ .in = "subject", .comment = null, .out = "subject\n" },
        .{ .in = "\n\n  \nsubject  \n\n\n\nbody\t\n\n", .comment = null, .out = "subject\n\nbody\n" },
        .{ .in = "# note\nsubject\n#more\n\nbody\n", .comment = "#", .out = "subject\n\nbody\n" },
        .{ .in = " \n\t\n", .comment = null, .out = "" },
        .{ .in = "a\r\nb\r\n", .comment = null, .out = "a\nb\n" },
    };
    for (cases) |case| {
        const got = try stripspace(gpa, case.in, case.comment);
        defer gpa.free(got);
        try testing.expectEqualStrings(case.out, got);
    }
}

/// A twin pair: one repository git commits in and one relic commits in,
/// with the same hooks, the same files and the same fixed dates, so their
/// commits can be compared byte for byte.
const Twin = struct {
    git: testgit.Repo,
    relic: testgit.Repo,
    environ: std.process.Environ.Map,

    const when: i64 = 1_700_000_000;
    const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = when, .offset_minutes = 0 };

    fn init(gpa: Allocator, io: Io) !Twin {
        var git = try testgit.Repo.init(gpa, io, &.{});
        errdefer git.deinit();
        var relic = try testgit.Repo.init(gpa, io, &.{});
        errdefer relic.deinit();
        var environ = try testgit.programEnviron(gpa);
        errdefer environ.deinit();
        try environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
        try environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
        return .{ .git = git, .relic = relic, .environ = environ };
    }

    fn deinit(t: *Twin) void {
        t.environ.deinit();
        t.git.deinit();
        t.relic.deinit();
    }

    fn bind(t: *Twin) void {
        t.git.environ = &t.environ;
        t.relic.environ = &t.environ;
    }

    /// Put the same hook in both.
    fn hook(t: *Twin, io: Io, name: []const u8, body: []const u8) !void {
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".git/hooks/{s}", .{name});
        inline for (.{ &t.git, &t.relic }) |r| {
            try r.writeFile(io, path, body);
            const file = try r.dir.openFile(io, path, .{});
            defer file.close(io);
            try file.setPermissions(io, .fromMode(0o755));
        }
    }

    fn both(t: *Twin, io: Io, args: []const []const u8) !void {
        try t.git.exec(io, args);
        try t.relic.exec(io, args);
    }

    fn write(t: *Twin, io: Io, path: []const u8, bytes: []const u8) !void {
        try t.git.writeFile(io, path, bytes);
        try t.relic.writeFile(io, path, bytes);
    }

    /// `git commit` in the one, with its hooks.
    fn gitCommit(t: *Twin, io: Io, extra: []const []const u8) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(t.git.gpa);
        try args.appendSlice(t.git.gpa, &.{ "-c", "core.hooksPath=.git/hooks", "commit", "-q" });
        try args.appendSlice(t.git.gpa, extra);
        try t.git.exec(io, args.items);
    }

    fn relicCommit(t: *Twin, gpa: Allocator, io: Io, message: []const u8, options: Options) !Outcome {
        var repo = try Repository.open(gpa, io, t.relic.dir, .{});
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &t.environ }, .{ .output = .ignore });
        defer runner.deinit();
        var opts = options;
        opts.hooks = &runner;
        return commit(&repo, io, .{ .author = who, .committer = who, .message = message }, opts);
    }

    fn expectSame(t: *Twin, io: Io, args: []const []const u8) !void {
        const a = try t.git.run(io, args);
        defer t.git.gpa.free(a);
        const b = try t.relic.run(io, args);
        defer t.relic.gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }
};

/// A hook body that records what it was given, in terms two repositories
/// in different places print alike.
const recorder =
    \\#!/bin/sh
    \\{
    \\  printf '%s %s' "$(basename "$0")" "$#"
    \\  for a in "$@"; do
    \\    if [ -f "$a" ]; then printf ' [%s]' "$(basename "$a")"; else printf ' %s' "$a"; fi
    \\  done
    \\  [ "$(pwd -P)" = "$(git rev-parse --show-toplevel)" ] && printf ' top'
    \\  [ "$GIT_INDEX_FILE" -ef .git/index ] && printf ' index'
    \\  printf ' editor=%s author=%s <%s> %s\n' "$GIT_EDITOR" "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "$GIT_AUTHOR_DATE"
    \\} >> .git/hook.log
    \\
;

test "a commit runs git's hooks in git's order with what git gives them, and writes git's commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    twin.bind();

    for ([_][]const u8{ "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit" }) |name| {
        try twin.hook(io, name, recorder);
    }
    // A commit-msg hook that rewrites the message, as a sign-off hook does.
    try twin.hook(io, "commit-msg", recorder ++ "echo 'Signed-off-by: Hook <hook@example.com>' >> \"$1\"\n");
    // A pre-commit hook that stages a file, which the commit must include.
    try twin.hook(io, "pre-commit", recorder ++ "echo generated > gen.txt && git add gen.txt\n");

    try twin.write(io, "a.txt", "a\n");
    try twin.both(io, &.{ "add", "a.txt" });

    try twin.gitCommit(io, &.{ "-m", "  first\n\n\ncommit  \n" });
    const made = try twin.relicCommit(gpa, io, "  first\n\n\ncommit  \n", .{});
    try testing.expect(made.previous == null);

    try twin.write(io, "a.txt", "b\n");
    try twin.both(io, &.{ "add", "a.txt" });
    try twin.gitCommit(io, &.{ "-m", "second" });
    _ = try twin.relicCommit(gpa, io, "second", .{});

    // The same commits, byte for byte, the same logs, and the same record of
    // which hook ran with what.
    try twin.expectSame(io, &.{ "cat-file", "commit", "HEAD" });
    try twin.expectSame(io, &.{ "cat-file", "commit", "HEAD~1" });
    try twin.expectSame(io, &.{ "reflog", "show", "--format=%H %gs", "refs/heads/main" });
    try twin.expectSame(io, &.{ "reflog", "show", "--format=%H %gs", "HEAD" });
    try twin.expectSame(io, &.{ "status", "--porcelain" });
    const a = try twin.git.readFile(io, ".git/hook.log");
    defer gpa.free(a);
    const b = try twin.relic.readFile(io, ".git/hook.log");
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expect(std.mem.indexOf(u8, a, "prepare-commit-msg 2 [COMMIT_EDITMSG] message top index editor=:") != null);
}

test "a refusing pre-commit or commit-msg hook writes nothing, and --no-verify skips both" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    twin.bind();
    try twin.write(io, "a.txt", "a\n");
    try twin.both(io, &.{ "add", "a.txt" });

    try twin.hook(io, "pre-commit", "#!/bin/sh\nexit 1\n");
    var repo = try Repository.open(gpa, io, twin.relic.dir, .{});
    defer repo.deinit(io);
    var runner = try repo.hookRunner(io, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    const request: Request = .{ .author = Twin.who, .committer = Twin.who, .message = "a\n" };
    try testing.expectError(error.HookRejected, commit(&repo, io, request, .{ .hooks = &runner }));
    try testing.expectEqualStrings("pre-commit", runner.failure.event());
    try testing.expect((try repo.head(io)) == null);

    try twin.hook(io, "pre-commit", "#!/bin/sh\nexit 0\n");
    try twin.hook(io, "commit-msg", "#!/bin/sh\nexit 5\n");
    try testing.expectError(error.HookRejected, commit(&repo, io, request, .{ .hooks = &runner }));
    try testing.expectEqual(@as(?u8, 5), runner.failure.status());
    try testing.expect((try repo.head(io)) == null);

    try twin.hook(io, "pre-commit", "#!/bin/sh\nexit 1\n");
    const made = try commit(&repo, io, request, .{ .hooks = &runner, .verify = false });
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    try testing.expect(head.oid.eql(made.commit));
}

test "an amend replaces the commit, keeps its parents, and tells post-rewrite" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    twin.bind();
    try twin.hook(io, "post-rewrite", "#!/bin/sh\n{ echo \"$*\"; cat; } | sed \"s/$(git rev-parse HEAD)/NEW/\" >> .git/rewrite.log\n");
    try twin.write(io, "a.txt", "a\n");
    try twin.both(io, &.{ "add", "a.txt" });
    try twin.both(io, &.{ "commit", "-q", "-m", "one" });
    try twin.write(io, "b.txt", "b\n");
    try twin.both(io, &.{ "add", "b.txt" });
    try twin.both(io, &.{ "commit", "-q", "-m", "two" });
    try twin.write(io, "c.txt", "c\n");
    try twin.both(io, &.{ "add", "c.txt" });

    try twin.gitCommit(io, &.{ "--amend", "-m", "two, amended" });
    const made = try twin.relicCommit(gpa, io, "two, amended", .{ .amend = true });
    try testing.expect(made.previous != null);

    try twin.expectSame(io, &.{ "cat-file", "commit", "HEAD" });
    try twin.expectSame(io, &.{ "reflog", "show", "--format=%H %gs", "HEAD" });
    const a = try twin.git.readFile(io, ".git/rewrite.log");
    defer gpa.free(a);
    const b = try twin.relic.readFile(io, ".git/rewrite.log");
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "an unchanged tree, an empty message and a merge in progress are refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    try fixture.writeFile(io, "a.txt", "a\n");
    try fixture.exec(io, &.{ "add", "a.txt" });
    try fixture.exec(io, &.{ "commit", "-q", "-m", "one" });

    var repo = try Repository.open(gpa, io, fixture.dir, .{});
    defer repo.deinit(io);
    const who = Twin.who;
    try testing.expectError(error.NothingToCommit, commit(&repo, io, .{ .author = who, .committer = who, .message = "again" }, .{}));
    try testing.expectError(error.EmptyMessage, commit(&repo, io, .{ .author = who, .committer = who, .message = " \n\n" }, .{ .allow_empty = true }));
    const made = try commit(&repo, io, .{ .author = who, .committer = who, .message = "empty on purpose" }, .{ .allow_empty = true });
    try testing.expect(made.previous != null);

    try fixture.writeFile(io, ".git/MERGE_HEAD", "0000000000000000000000000000000000000000\n");
    try testing.expectError(error.OperationInProgress, commit(&repo, io, .{ .author = who, .committer = who, .message = "m" }, .{ .allow_empty = true }));
}
