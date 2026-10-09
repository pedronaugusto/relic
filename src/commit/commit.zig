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

const Self = @This();

// The modules relic's API puts under this one, as `relic.commit.<name>`.
const message = @import("../object/message.zig");
const trailer = @import("../object/trailer.zig");
const head = @import("../repo/head.zig");
const reset = @import("reset.zig");

const signing = @import("../object/signing.zig");
const commithooks = @import("commithooks.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("../checkout.zig");
const index_mod = @import("../index/index.zig");
const hooks = @import("../hooks/hooks.zig");
const fs = @import("../fs.zig");

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
    /// A `--trailer` that is empty, or has no key before its separator.
    InvalidTrailer,
    /// The message is the template's, unedited but for blank lines and
    /// sign-offs: git's "you did not edit the message".
    TemplateUntouched,
} || trailer.Error || hooks.Error || commithooks.Error || repo_mod.WriteError || refs_mod.TransactionError || worktree.Error ||
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
    /// Caller-owned output for a refused write or failed signing program.
    diagnostic: ?*repo_mod.Diagnostic = null,
    /// `--trailer`: each `<key>`, `<key>=<value>` or `<key>:<value>` added
    /// to the message as `git interpret-trailers` adds it, before
    /// `prepare-commit-msg` runs, with the repository's `trailer.*` rules.
    trailers: []const []const u8 = &.{},
    /// What runs a `trailer.<name>.command` or `.cmd` those rules name.
    trailer_commands: ?trailer.Commands = null,
    /// The template the message was edited from, when it was: `commit.template`
    /// (`template` reads it) or git's `-t`. A message that is the template
    /// unedited is `error.TemplateUntouched`. git drops the template when a
    /// message is given with `-m`, which is what leaving this `null` is.
    template: ?[]const u8 = null,
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
pub fn commit(io: Io, repo: *Repository, request: Request, options: Options) Self.Error!Outcome {
    diagnostic.reset(options.diagnostic);
    const gpa = repo.allocator();
    if (repo.workDirectory() == null) return error.BareRepository;
    // Through the ref store: a reftable repository keeps the pick's and
    // the revert's refs in its tables, where no file says they are there.
    if (repo.refStore().special().exists(io, .merge_head) or
        repo.refStore().root().exists(gpa, io, .cherry_pick_head) or
        repo.refStore().root().exists(gpa, io, .revert_head)) return error.OperationInProgress;
    const cleanup = options.cleanup orelse try configuredCleanup(repo);

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const current: ?Oid = if (try repo.refStore().resolve(arena, io, "HEAD")) |r| r.oid else null;
    if (options.amend and current == null) return error.NothingToAmend;

    // The files named as git names them to a hook: `.git/index` and
    // `.git/COMMIT_EDITMSG` from the top of the working tree.
    const names = try commithooks.Hooks.init(arena, io, repo, .{ .runner = options.hooks, .verify = options.verify });
    const message_path = try names.path(arena, "COMMIT_EDITMSG");
    const env = try names.env(arena, request.author);

    if (options.hooks) |runner| {
        if (options.verify) _ = try runner.preCommit(io, env);
    }

    const comment = commentPrefix(repo);
    const first_message = try prepareMessage(arena, io, repo, request.message, cleanup, comment, options);
    try repo.gitDirectory().writeFile(io, .{ .sub_path = "COMMIT_EDITMSG", .data = first_message });

    // `pre-commit` may have staged something, so the index is read now and
    // not before.
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnmergedIndex;
    }
    const tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());

    // What the new commit sits on, and what an amend carries over.
    var parents: []const Oid = &.{};
    var carried: []const object.ExtraHeader = &.{};
    if (current) |tip| {
        const found = try repo.objectDatabase().read(io, tip);
        defer gpa.free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        const bytes = try arena.dupe(u8, found.bytes);
        const parsed = try object.Commit.parse(arena, repo.objectFormat(), bytes);
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
            parents = try arena.dupe(Oid, &.{tip});
            if (!options.allow_empty and parsed.tree.eql(tree)) return error.NothingToCommit;
        }
    } else if (!options.allow_empty and index.entries.items.len == 0) {
        return error.NothingToCommit;
    }

    if (options.hooks) |runner| {
        _ = try runner.prepareCommitMsg(io, env, message_path, .{ .source = .message, .commit = null });
        if (options.verify) _ = try runner.commitMsg(io, env, message_path);
    }

    const edited = try repo.gitDirectory().readFileAlloc(io, "COMMIT_EDITMSG", arena, .limited(1 << 30));
    const cleaned = try clean(arena, edited, cleanup, comment);
    try validateMessage(arena, cleaned, cleanup, comment, options);

    const new = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = parents,
        .author = request.author,
        .committer = request.committer,
        .message = cleaned,
        .extra = carried,
        .signing = options.signing,
    }, options.diagnostic);

    const action = if (current == null)
        "commit (initial)"
    else if (options.amend)
        "commit (amend)"
    else
        "commit";
    const subject_end = std.mem.findScalar(u8, cleaned, '\n') orelse cleaned.len;
    const log_message = try arena.print("{s}: {s}", .{ action, cleaned[0..subject_end] });
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
    try repo.writeIndex(io, &index);

    var outcome: Outcome = .{ .commit = new, .tree = tree, .previous = current };
    if (options.hooks) |runner| {
        outcome.post_commit = try runner.postCommit(io, env);
        if (options.amend and options.post_rewrite) {
            _ = try runner.postRewrite(io, .amend, &.{.{ .old = current.?, .new = new }});
        }
    }
    return outcome;
}

fn validateMessage(arena: Allocator, cleaned: []const u8, cleanup: Cleanup, comment: []const u8, options: Options) Error!void {
    if (!options.allow_empty_message and isEmpty(cleaned, cleanup, comment)) return error.EmptyMessage;
    if (!options.allow_empty_message) {
        if (options.template) |text| {
            if (try templateUntouched(arena, cleaned, text, cleanup, comment)) return error.TemplateUntouched;
        }
    }
}

fn prepareMessage(arena: Allocator, io: Io, repo: *Repository, input: []const u8, cleanup: Cleanup, comment: []const u8, options: Options) Error![]const u8 {
    var first_message = try clean(arena, input, cleanup, comment);
    if (options.trailers.len != 0) {
        // git's `validate_trailer_args`, then `amend_file_with_trailers`
        const settings = try message.trailerSettings(arena, repo.configuration());
        const cl_separators = try std.mem.concat(arena, u8, &.{ "=", settings.separators });
        for (options.trailers) |text| {
            if (text.len == 0) return error.InvalidTrailer;
            if (trailer.findSeparator(text, cl_separators)) |at| if (at == 0) return error.InvalidTrailer;
        }
        first_message = try trailer.amend(arena, io, first_message, .{ .settings = settings, .commands = options.trailer_commands, .trailers = options.trailers });
    }
    return first_message;
}

/// What `commit.template` holds: the text git starts a message from when
/// none is given, `null` when it is not set, cannot be read or is empty.
/// A path that is not absolute is the working tree's, where git runs
/// `commit`, and `~/` is the home the repository was opened with. The text
/// is `gpa`'s.
pub fn template(gpa: Allocator, io: Io, repo: *Repository) Allocator.Error!?[]u8 {
    const path = (try repo.configuration().getPath(gpa, "commit.template")) orelse return null;
    defer gpa.free(path);
    const dir = if (std.Io.Dir.path.isAbsolute(path)) Io.Dir.cwd() else repo.workDirectory() orelse Io.Dir.cwd();
    const text = dir.readFileAlloc(io, path, gpa, .limited(1 << 30)) catch return null;
    if (text.len == 0) {
        gpa.free(text);
        return null;
    }
    return text;
}

/// git's `template_untouched`: whether `text`, a cleaned message, is the template
/// cleaned the same way and nothing more than blank lines and
/// `Signed-off-by:` lines.
pub fn templateUntouched(arena: Allocator, text: []const u8, template_text: []const u8, cleanup: Cleanup, comment: []const u8) Allocator.Error!bool {
    if (cleanup == .verbatim and text.len != 0) return false;
    const cleaned = try stripspace(arena, template_text, if (cleanup == .strip) comment else null);
    const start = if (std.mem.startsWith(u8, text, cleaned)) cleaned.len else 0;
    return restIsEmpty(text, start);
}

/// git's `rest_is_empty`: nothing after `start` but whitespace and
/// sign-offs.
fn restIsEmpty(text: []const u8, start: usize) bool {
    const sign_off = "Signed-off-by: ";
    var i = start;
    while (i < text.len) {
        const eol = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
        if (eol - i >= sign_off.len and std.mem.startsWith(u8, text[i..], sign_off)) {
            i = eol + 1;
            continue;
        }
        while (i < eol) : (i += 1) {
            if (!isSpace(text[i])) return false;
        }
        i += 1;
    }
    return true;
}

fn configuredCleanup(repo: *Repository) error{InvalidCleanupMode}!Cleanup {
    const text = repo.configuration().get("commit.cleanup") orelse return .whitespace;
    // With no editor, `default` and `scissors` are both `whitespace`.
    if (std.mem.eql(u8, text, "default") or std.mem.eql(u8, text, "whitespace") or
        std.mem.eql(u8, text, "scissors")) return .whitespace;
    if (std.mem.eql(u8, text, "verbatim")) return .verbatim;
    if (std.mem.eql(u8, text, "strip")) return .strip;
    return error.InvalidCleanupMode;
}

fn commentPrefix(repo: *Repository) []const u8 {
    const text = repo.configuration().get("core.commentstring") orelse repo.configuration().get("core.commentchar") orelse return "#";
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
fn isEmpty(text: []const u8, cleanup: Cleanup, comment: []const u8) bool {
    if (cleanup == .verbatim and text.len != 0) return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
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
        const eol = std.mem.findScalarPos(u8, text, i, '\n');
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
const testgit = @import("../testing/git.zig");
const diagnostic = @import("../report.zig").diagnostic;

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
        t.* = undefined;
    }

    fn bind(t: *Twin) void {
        t.git.environ = &t.environ;
        t.relic.environ = &t.environ;
    }

    /// Put the same native hook in both repositories.
    fn fixtureHook(t: *Twin, io: Io, name: []const u8, action: []const u8, data: []const u8) !void {
        var path_buf: [96]u8 = undefined;
        const path = try std.mem.print(&path_buf, ".git/hooks/{s}", .{name});
        inline for (.{ &t.git, &t.relic }) |r| try testgit.fixtureHook(r.gpa, io, r.dir, path, action, data);
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

    fn relicCommit(t: *Twin, gpa: Allocator, io: Io, text: []const u8, options: Options) !Outcome {
        var repo = try Repository.open(gpa, io, t.relic.dir, .{});
        defer repo.deinit(io);
        var runner = try repo.hookRunner(io, .{ .environ = &t.environ }, .{ .output = .ignore });
        defer runner.deinit();
        var opts = options;
        opts.hooks = &runner;
        return commit(io, &repo, .{ .author = who, .committer = who, .message = text }, opts);
    }

    fn expectSame(t: *Twin, io: Io, args: []const []const u8) !void {
        const a = try t.git.run(io, args);
        defer t.git.gpa.free(a);
        const b = try t.relic.run(io, args);
        defer t.relic.gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }
};

test "a commit runs git's hooks in git's order with what git gives them, and writes git's commit" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    twin.bind();

    for ([_][]const u8{ "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit" }) |name| {
        try twin.fixtureHook(io, name, "commit_record", "");
    }
    // A commit-msg hook that rewrites the message, as a sign-off hook does.
    try twin.fixtureHook(io, "commit-msg", "commit_record", "signoff");
    // A pre-commit hook that stages a file, which the commit must include.
    try twin.fixtureHook(io, "pre-commit", "commit_record", "stage");

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
    try testing.expect(std.mem.find(u8, a, "prepare-commit-msg 2 [COMMIT_EDITMSG] message top index editor=:") != null);
}

test "a refusing pre-commit or commit-msg hook writes nothing, and --no-verify skips both" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    twin.bind();
    try twin.write(io, "a.txt", "a\n");
    try twin.both(io, &.{ "add", "a.txt" });

    try twin.fixtureHook(io, "pre-commit", "status", "1\n");
    var repo = try Repository.open(gpa, io, twin.relic.dir, .{});
    defer repo.deinit(io);
    var runner = try repo.hookRunner(io, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    const request: Request = .{ .author = Twin.who, .committer = Twin.who, .message = "a\n" };
    try testing.expectError(error.HookRejected, commit(io, &repo, request, .{ .hooks = &runner }));
    try testing.expectEqualStrings("pre-commit", runner.failure.event());
    try testing.expect((try repo.head(io)) == null);

    try twin.fixtureHook(io, "pre-commit", "status", "0\n");
    try twin.fixtureHook(io, "commit-msg", "status", "5\n");
    try testing.expectError(error.HookRejected, commit(io, &repo, request, .{ .hooks = &runner }));
    try testing.expectEqual(@as(?u32, 5), runner.failure.status());
    try testing.expect((try repo.head(io)) == null);

    try twin.fixtureHook(io, "pre-commit", "status", "1\n");
    const made = try commit(io, &repo, request, .{ .hooks = &runner, .verify = false });
    const moved = (try repo.head(io)).?;
    defer gpa.free(moved.name);
    try testing.expect(moved.oid.eql(made.commit));
}

test "an amend replaces the commit, keeps its parents, and tells post-rewrite" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    twin.bind();
    try twin.fixtureHook(io, "post-rewrite", "rewrite_log", "");
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
    try testing.expectError(error.NothingToCommit, commit(io, &repo, .{ .author = who, .committer = who, .message = "again" }, .{}));
    try testing.expectError(error.EmptyMessage, commit(io, &repo, .{ .author = who, .committer = who, .message = " \n\n" }, .{ .allow_empty = true }));
    const made = try commit(io, &repo, .{ .author = who, .committer = who, .message = "empty on purpose" }, .{ .allow_empty = true });
    try testing.expect(made.previous != null);

    try fixture.writeFile(io, ".git/MERGE_HEAD", "0000000000000000000000000000000000000000\n");
    try testing.expectError(error.OperationInProgress, commit(io, &repo, .{ .author = who, .committer = who, .message = "m" }, .{ .allow_empty = true }));
}

test "a message that is commit.template unedited is refused, as git commit refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit();
    const template_text = "Subject line\n\n# say what changed\nBody of the template.\n";
    for ([_]*testgit.Repo{ &twin.git, &twin.relic }) |r| {
        try r.writeFile(io, "template.txt", template_text);
        try r.exec(io, &.{ "config", "commit.template", "template.txt" });
        try r.writeFile(io, "a.txt", "a\n");
        try r.exec(io, &.{ "add", "a.txt" });
    }
    var repo = try Repository.open(gpa, io, twin.relic.dir, .{});
    defer repo.deinit(io);
    const text = (try template(gpa, io, &repo)).?;
    defer gpa.free(text);
    try testing.expectEqualStrings(template_text, text);
    // git's editor leaving the template as it was, with and without a
    // sign-off after it; under `strip`, since with any other cleanup the
    // status git adds below the template stays in the message
    twin.git.report_failures = false;
    for ([_][]const u8{"strip"}) |cleanup| {
        for ([_]bool{ false, true }) |signoff| {
            const mode = try gpa.print("commit.cleanup={s}", .{cleanup});
            defer gpa.free(mode);
            var theirs = try twin.git.capture(io, if (signoff) &.{ "-c", "core.editor=true", "-c", mode, "commit", "-q", "-s" } else &.{ "-c", "core.editor=true", "-c", mode, "commit", "-q" });
            defer theirs.deinit(gpa);
            errdefer std.debug.print("{s} {}: git {d}: {s}\n", .{ cleanup, signoff, theirs.code, theirs.stderr });
            try testing.expect(theirs.code != 0);
            try testing.expect(std.mem.find(u8, theirs.stderr, "you did not edit the message") != null);
            const edited_message = if (signoff) template_text ++ "\nSigned-off-by: Fixture <fixture@example.com>\n" else template_text;
            try twin.relic.exec(io, &.{ "config", "commit.cleanup", cleanup });
            _ = try repo.refreshConfig(io, null);
            try testing.expectError(error.TemplateUntouched, commit(io, &repo, .{ .author = Twin.who, .committer = Twin.who, .message = edited_message }, .{ .template = text }));
        }
    }
    // an edited one is committed, and a message given outright never asks
    _ = try commit(io, &repo, .{ .author = Twin.who, .committer = Twin.who, .message = "Subject line\n\nBody, edited.\n" }, .{ .template = text });
    try twin.relic.writeFile(io, "b.txt", "b\n");
    try twin.relic.exec(io, &.{ "add", "b.txt" });
    _ = try commit(io, &repo, .{ .author = Twin.who, .committer = Twin.who, .message = template_text }, .{});
}
