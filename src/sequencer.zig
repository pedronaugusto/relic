//! Replaying commits: `git cherry-pick` and `git revert`, one commit or a
//! sequence of them.
//!
//! A pick is a three-way merge of the commit into `HEAD` with the commit's
//! parent as the ancestor, and a revert the same with the two swapped; the
//! commit it makes keeps the original author, takes the original message
//! (with `-x` and `--signoff` lines added by git's trailer rules), and logs
//! `cherry-pick: <subject>` or `revert: <subject>`. A sequence keeps its
//! state where git keeps it -- `.git/sequencer/todo` with short names and
//! subjects, `head`, `abort-safety`, and `opts` holding only the options
//! that were asked for -- and a pick that stops leaves `CHERRY_PICK_HEAD`
//! or `REVERT_HEAD` and `MERGE_MSG`. That is the whole of the contract with
//! git: a sequence this stopped is continued, skipped or aborted by `git
//! cherry-pick`, and one git stopped is continued, skipped or aborted here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const merge = @import("merge.zig");
const threeway = @import("threeway.zig");
const reset = @import("reset.zig");
const head_mod = @import("head.zig");
const message = @import("message.zig");
const abbrev = @import("abbrev.zig");
const todo = @import("todo.zig");
const worktree = @import("worktree.zig");
const merging = @import("merging.zig");
const rerere = @import("rerere.zig");
const config_mod = @import("config.zig");
const repo_mod = @import("repo.zig");
const refs_mod = @import("refs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from replaying commits.
pub const Error = error{
    /// `.git/sequencer` already holds a cherry-pick or a revert.
    SequencerInProgress,
    /// There is no cherry-pick or revert to continue, skip or abort.
    NoSequencerInProgress,
    /// `MERGE_HEAD` is there: a merge is waiting to be concluded.
    MergeInProgress,
    /// `HEAD` names a branch with no commit yet, and the operation needs one.
    UnbornBranch,
    /// The commit is a merge and no mainline parent was named.
    MergeWithoutMainline,
    /// The mainline names a parent the commit does not have.
    NoSuchParent,
    /// The index still has conflicts.
    UnresolvedConflicts,
    /// A revert sequence was asked to cherry-pick, or the other way round.
    ActionMismatch,
    /// A state file that does not say what git writes there.
    MalformedState,
    /// The sequence was started with `--edit`, and an editor is not
    /// something this package opens.
    EditorRequested,
    /// The sequence names a merge strategy other than `ort` or
    /// `recursive`.
    UnsupportedStrategy,
    /// `commit.gpgSign`, or a sequence started with `-S`, asks for signed
    /// commits.
    SigningRequested,
    /// `revert.reference` asks for a message a person is meant to finish in
    /// an editor.
    RevertReferenceNeedsEditor,
    /// The commit would record no change and empty commits were not
    /// allowed; `CHERRY_PICK_HEAD` is left so the pick can be skipped or
    /// committed.
    EmptyCommit,
    /// The message left after cleanup is empty.
    EmptyMessage,
    /// A skip was asked for and nothing is waiting to be skipped.
    NothingToSkip,
    /// A name given names no commit.
    NotACommit,
} || threeway.Error || head_mod.Error || todo.ParseError || refs_mod.ReadError || rerere.Error ||
    config_mod.ParseError || config_mod.ValueError || repo_mod.WriteError;

/// Which replay.
pub const Action = enum {
    pick,
    revert,

    /// The word git uses in messages, logs and `todo` lines.
    pub fn name(a: Action) []const u8 {
        return switch (a) {
            .pick => "cherry-pick",
            .revert => "revert",
        };
    }

    fn command(a: Action) todo.Command {
        return switch (a) {
            .pick => .pick,
            .revert => .revert,
        };
    }

    fn headRef(a: Action) []const u8 {
        return switch (a) {
            .pick => "CHERRY_PICK_HEAD",
            .revert => "REVERT_HEAD",
        };
    }
};

/// What becomes of a commit that ends up changing nothing: `--empty`.
pub const Empty = enum {
    /// Stop, as git does unless asked otherwise.
    stop,
    /// Commit it anyway: `--empty=keep`, `--keep-redundant-commits`.
    keep,
    /// Leave it out: `--empty=drop`.
    drop,
};

/// How commits are replayed. Everything but `who`, `blocked` and
/// `conflict_style` is recorded in a sequence's `opts` when it differs from
/// git's default, so a continuation picks it up whichever side continues.
pub const Options = struct {
    /// Who commits, and when; also who the reflog lines are by. A pick
    /// keeps the original author; a revert is by this identity.
    who: object.Signature,
    /// Stage the result and do not commit: `--no-commit`.
    no_commit: bool = false,
    /// Keep a commit that was empty to begin with: `--allow-empty`.
    allow_empty: bool = false,
    /// Allow a commit with an empty message: `--allow-empty-message`.
    allow_empty_message: bool = false,
    /// What to do with one that becomes empty.
    empty: Empty = .stop,
    /// `--signoff`.
    signoff: bool = false,
    /// `-x`: note which commit a pick came from.
    record_origin: bool = false,
    /// `--ff`: move `HEAD` to the commit itself when its parent is `HEAD`.
    allow_ff: bool = false,
    /// `-m`: which parent of a merge commit is the mainline, from one.
    mainline: ?u32 = null,
    /// `-X ours` or `-X theirs`.
    favor: merge.Favor = .none,
    /// `--cleanup`: how the message is cleaned, in place of the default.
    cleanup: ?message.Cleanup = null,
    /// `null` asks `merge.conflictStyle`.
    conflict_style: ?merge.ConflictStyle = null,
    /// Treat a list of one commit as a sequence, with state in
    /// `.git/sequencer`, as git does for a range that names one commit. A
    /// single commit given on its own is otherwise picked without that
    /// state, as `git cherry-pick <commit>` does.
    sequence: bool = false,
    /// Where a refusal writes the path that caused it.
    blocked: ?*threeway.Blocked = null,
    /// Stage what a recorded resolution resolves: `--rerere-autoupdate`,
    /// `--no-rerere-autoupdate`, or `rerere.autoUpdate` when `null`.
    rerere_autoupdate: ?bool = null,
};

/// Why a replay stopped.
pub const Stop = enum {
    /// A pick or a revert conflicted; resolve, stage, and continue.
    conflict,
    /// A pick would change nothing and empty commits are not allowed; skip
    /// it, or commit it anyway.
    empty,
};

/// What a replay did.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// `null` when every commit was applied.
    stopped: ?Stop = null,
    /// The commit the replay stopped at.
    stopped_at: ?Oid = null,
    /// The paths left conflicted, sorted.
    conflicts: []const threeway.Conflict = &.{},
    /// The commits made, in order.
    made: []const Oid = &.{},

    /// Release the outcome.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// Cherry-pick `commits` in order onto `HEAD`.
pub fn pick(gpa: Allocator, io: Io, repo: *Repository, commits: []const Oid, options: Options) Error!Outcome {
    return start(gpa, io, repo, .pick, commits, options);
}

/// Revert `commits` in order.
pub fn revert(gpa: Allocator, io: Io, repo: *Repository, commits: []const Oid, options: Options) Error!Outcome {
    return start(gpa, io, repo, .revert, commits, options);
}

/// Whether a cherry-pick or revert is waiting: a sequence in
/// `.git/sequencer`, or a single pick's `CHERRY_PICK_HEAD` or `REVERT_HEAD`.
pub fn inProgress(io: Io, repo: *Repository) ?Action {
    if (lastCommand(repo.gpa, io, repo)) |action| return action;
    if (head_mod.stateExists(io, repo.git_dir, "CHERRY_PICK_HEAD")) return .pick;
    if (head_mod.stateExists(io, repo.git_dir, "REVERT_HEAD")) return .revert;
    return null;
}

//=========================================================================
// The state git keeps
//=========================================================================

const seq_dir = "sequencer";
const todo_path = "sequencer/todo";
const head_path = "sequencer/head";
const safety_path = "sequencer/abort-safety";
const opts_path = "sequencer/opts";

/// The action the first line of `.git/sequencer/todo` names, as
/// `sequencer_get_last_command` reads it.
fn lastCommand(gpa: Allocator, io: Io, repo: *Repository) ?Action {
    const text = (head_mod.readState(gpa, io, repo.git_dir, todo_path) catch return null) orelse return null;
    defer gpa.free(text);
    var at: usize = 0;
    while (at < text.len and (text[at] == ' ' or text[at] == '\t' or text[at] == '\r' or text[at] == '\n')) at += 1;
    const rest = text[at..];
    for ([_]Action{ .pick, .revert }) |action| {
        const word = action.command().name();
        const letter = action.command().letter();
        var after: ?[]const u8 = null;
        if (std.mem.startsWith(u8, rest, word)) after = rest[word.len..] else if (letter != null and rest.len != 0 and rest[0] == letter.?) after = rest[1..];
        if (after) |a| {
            if (a.len != 0 and (a[0] == ' ' or a[0] == '\t')) return action;
        }
    }
    return null;
}

/// The options git records in `.git/sequencer/opts`, in git's order.
///
/// A revert records `edit = false`, which is what `git revert --no-edit`
/// records: this package never opens an editor, and a revert is the one
/// command git would otherwise open one for when it continues in a
/// terminal.
fn writeOpts(gpa: Allocator, io: Io, repo: *Repository, action: Action, options: Options) Error!void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    var any = false;
    if (options.no_commit) {
        w.writeAll("[options]\n\tno-commit = true\n") catch return error.OutOfMemory;
        any = true;
    }
    if (action == .revert) {
        if (!any) w.writeAll("[options]\n") catch return error.OutOfMemory;
        any = true;
        w.writeAll("\tedit = false\n") catch return error.OutOfMemory;
    }
    const lines = [_]struct { on: bool, key: []const u8 }{
        .{ .on = options.allow_empty or options.empty == .keep, .key = "allow-empty" },
        .{ .on = options.allow_empty_message, .key = "allow-empty-message" },
        .{ .on = options.empty == .drop, .key = "drop-redundant-commits" },
        .{ .on = options.empty == .keep, .key = "keep-redundant-commits" },
        .{ .on = options.signoff, .key = "signoff" },
        .{ .on = options.record_origin, .key = "record-origin" },
        .{ .on = options.allow_ff, .key = "allow-ff" },
    };
    for (lines) |line| {
        if (!line.on) continue;
        if (!any) w.writeAll("[options]\n") catch return error.OutOfMemory;
        any = true;
        w.print("\t{s} = true\n", .{line.key}) catch return error.OutOfMemory;
    }
    if (options.mainline) |m| {
        if (!any) w.writeAll("[options]\n") catch return error.OutOfMemory;
        any = true;
        w.print("\tmainline = {d}\n", .{m}) catch return error.OutOfMemory;
    }
    if (options.favor == .ours or options.favor == .theirs) {
        if (!any) w.writeAll("[options]\n") catch return error.OutOfMemory;
        any = true;
        w.print("\tstrategy-option = {s}\n", .{@tagName(options.favor)}) catch return error.OutOfMemory;
    }
    if (options.rerere_autoupdate) |on| {
        if (!any) w.writeAll("[options]\n") catch return error.OutOfMemory;
        any = true;
        w.print("\tallow-rerere-auto = {s}\n", .{if (on) "true" else "false"}) catch return error.OutOfMemory;
    }
    if (options.cleanup) |mode| {
        if (!any) w.writeAll("[options]\n") catch return error.OutOfMemory;
        any = true;
        w.print("\tdefault-msg-cleanup = {s}\n", .{@tagName(mode)}) catch return error.OutOfMemory;
    }
    if (any) try head_mod.writeState(io, repo.git_dir, opts_path, out.written());
}

/// Apply what `.git/sequencer/opts` says on top of `options`.
fn readOpts(gpa: Allocator, io: Io, repo: *Repository, options: *Options) Error!void {
    const text = (try head_mod.readState(gpa, io, repo.git_dir, opts_path)) orelse return;
    defer gpa.free(text);
    try parseOpts(gpa, text, options);
}

/// Errors from reading the `opts` file.
const OptsError = error{ MalformedState, EditorRequested, SigningRequested, UnsupportedStrategy, OutOfMemory };

/// Read the settings in an `opts` file's text into `options`.
fn parseOpts(gpa: Allocator, text: []const u8, options: *Options) OptsError!void {
    var parsed = config_mod.Config.parseText(gpa, text, .local) catch return error.MalformedState;
    defer parsed.deinit();
    for (parsed.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "options")) continue;
        const value = entry.value orelse "true";
        // git reads these as a boolean or a number, a number being true
        // unless it is zero.
        const on = config_mod.parseBool(value) catch ((config_mod.parseInt(value) catch return error.MalformedState) != 0);
        const key = entry.name;
        if (std.mem.eql(u8, key, "no-commit")) {
            options.no_commit = on;
        } else if (std.mem.eql(u8, key, "edit")) {
            if (on) return error.EditorRequested;
        } else if (std.mem.eql(u8, key, "allow-empty")) {
            options.allow_empty = on;
        } else if (std.mem.eql(u8, key, "allow-empty-message")) {
            options.allow_empty_message = on;
        } else if (std.mem.eql(u8, key, "drop-redundant-commits")) {
            if (on) options.empty = .drop;
        } else if (std.mem.eql(u8, key, "keep-redundant-commits")) {
            if (on) options.empty = .keep;
        } else if (std.mem.eql(u8, key, "signoff")) {
            options.signoff = on;
        } else if (std.mem.eql(u8, key, "record-origin")) {
            options.record_origin = on;
        } else if (std.mem.eql(u8, key, "allow-ff")) {
            options.allow_ff = on;
        } else if (std.mem.eql(u8, key, "mainline")) {
            const n = config_mod.parseInt(value) catch return error.MalformedState;
            options.mainline = if (n > 0) std.math.cast(u32, n) orelse return error.MalformedState else null;
        } else if (std.mem.eql(u8, key, "strategy")) {
            if (!std.mem.eql(u8, value, "ort") and !std.mem.eql(u8, value, "recursive")) return error.UnsupportedStrategy;
        } else if (std.mem.eql(u8, key, "gpg-sign")) {
            return error.SigningRequested;
        } else if (std.mem.eql(u8, key, "strategy-option")) {
            if (std.mem.eql(u8, value, "ours")) options.favor = .ours else if (std.mem.eql(u8, value, "theirs")) options.favor = .theirs else return error.UnsupportedStrategy;
        } else if (std.mem.eql(u8, key, "default-msg-cleanup")) {
            options.cleanup = message.Cleanup.parse(value) orelse if (std.mem.eql(u8, value, "default")) null else return error.MalformedState;
        } else if (std.mem.eql(u8, key, "allow-rerere-auto")) {
            options.rerere_autoupdate = on;
        } else return error.MalformedState;
    }
}

/// Write `abort-safety`: where `HEAD` is now, so an abort can tell whether
/// something else has moved it since.
fn updateAbortSafety(gpa: Allocator, io: Io, repo: *Repository) Error!void {
    if (!head_mod.stateExists(io, repo.git_dir, seq_dir)) return;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    var buf: [hash.max_hex_len + 1]u8 = undefined;
    var hex: [hash.max_hex_len]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}\n", .{if (head.oid) |oid| oid.hex(&hex) else ""}) catch unreachable;
    try head_mod.writeState(io, repo.git_dir, safety_path, text);
}

fn removeSequencerState(io: Io, repo: *Repository) Error!void {
    try repo.git_dir.deleteTree(io, seq_dir);
}

//=========================================================================
// One pick
//=========================================================================

/// What `do_pick_commit` needs to know about one run.
const Replay = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    repo: *Repository,
    action: Action,
    options: Options,
    comment: []const u8,
    abbrev_len: usize,
    made: std.ArrayList(Oid) = .empty,
    conflicts: []const threeway.Conflict = &.{},

    fn short(r: *Replay, oid: Oid) Error![]const u8 {
        var buf: [hash.max_hex_len]u8 = undefined;
        return r.arena.dupe(u8, try abbrev.unique(r.io, &r.repo.odb, oid, r.abbrev_len, &buf));
    }
};

const Picked = enum { committed, conflicted, empty, dropped, staged };

fn readCommit(r: *Replay, oid: Oid) Error!struct { bytes: []const u8, commit: object.Commit } {
    const found = try r.repo.odb.read(r.io, oid);
    defer r.repo.odb.gpa.free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const bytes = try r.arena.dupe(u8, found.bytes);
    const commit = try object.Commit.parse(r.arena, r.repo.kind, bytes);
    return .{ .bytes = bytes, .commit = commit };
}

/// `do_pick_commit` for a cherry-pick or a revert.
fn pickOne(r: *Replay, oid: Oid) Error!Picked {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    const arena = r.arena;

    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (r.options.blocked) |b| b.set(entry.path);
            return error.UnmergedIndex;
        }
    }
    // With `--no-commit` the merge starts from what is staged; otherwise
    // from `HEAD`, and the index must be `HEAD`.
    const head_tree: Oid = if (r.options.no_commit)
        try worktree.writeTree(gpa, io, &index, &repo.odb)
    else if (head.oid) |h|
        try repo.commitTree(io, h)
    else
        try emptyTree(repo, io);

    const picked = try readCommit(r, oid);
    const commit = picked.commit;
    var parent: ?Oid = null;
    if (commit.parents.len > 1) {
        const m = r.options.mainline orelse return error.MergeWithoutMainline;
        if (m == 0 or m > commit.parents.len) return error.NoSuchParent;
        parent = commit.parents[m - 1];
    } else if (r.options.mainline) |m| {
        if (m > 1) return error.NoSuchParent;
        if (commit.parents.len == 1) parent = commit.parents[0];
    } else if (commit.parents.len == 1) parent = commit.parents[0];

    const subject = message.subjectLine(commit.message);
    const short_name = try r.short(oid);
    const label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ short_name, subject });
    const parent_label = try std.fmt.allocPrint(arena, "parent of {s}", .{label});

    // `--ff`: the commit sits on `HEAD` already.
    if (r.options.allow_ff and !r.options.no_commit) {
        const ff = if (parent) |p| (head.oid != null and p.eql(head.oid.?)) else head.oid == null;
        if (ff) {
            const their_tree = commit.tree;
            var outcome = try threeway.apply(gpa, io, repo, &index, head_tree, head_tree, their_tree, .{ .blocked = r.options.blocked });
            defer outcome.deinit();
            try index.write(io, repo.git_dir, "index", .{});
            const log = try std.fmt.allocPrint(arena, "{s}: fast-forward", .{r.action.name()});
            try head_mod.advance(io, repo, head, oid, .{ .who = r.options.who, .message = log });
            try updateAbortSafety(gpa, io, repo);
            try r.made.append(arena, oid);
            return .committed;
        }
    }

    var msg: std.ArrayList(u8) = .empty;
    var base_tree: ?Oid = null;
    var next_tree: ?Oid = null;
    var base_label: []const u8 = undefined;
    var next_label: []const u8 = undefined;
    var author: ?object.Signature = null;
    switch (r.action) {
        .revert => {
            if (repo.config.getBool("revert.reference", false) catch false) return error.RevertReferenceNeedsEditor;
            base_tree = commit.tree;
            base_label = label;
            next_tree = if (parent) |p| try repo.commitTree(io, p) else null;
            next_label = if (parent != null) parent_label else "(empty tree)";
            try revertMessage(r, &msg, subject, oid, if (commit.parents.len > 1) parent else null);
        },
        .pick => {
            base_tree = if (parent) |p| try repo.commitTree(io, p) else null;
            base_label = if (parent != null) parent_label else "(empty tree)";
            next_tree = commit.tree;
            next_label = label;
            try msg.appendSlice(arena, message.fromSubject(commit.message));
            if (r.options.record_origin) {
                var hex: [hash.max_hex_len]u8 = undefined;
                try message.appendCherryPicked(arena, &msg, oid.hex(&hex), r.comment);
            }
            author = commit.author;
        },
    }
    if (r.options.signoff) try message.appendSignoff(arena, &msg, r.options.who, r.comment);

    const style = r.options.conflict_style orelse merging.configuredStyle(repo);
    var outcome = try threeway.apply(gpa, io, repo, &index, base_tree, head_tree, next_tree orelse try emptyTree(repo, io), .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .base = base_label, .theirs = next_label },
            .favor = r.options.favor,
            .algorithm = .histogram,
        },
        .blocked = r.options.blocked,
    });
    defer outcome.deinit();
    try index.write(io, repo.git_dir, "index", .{});
    try head_mod.writeRef(io, repo, "AUTO_MERGE", outcome.auto_merge);

    if (!outcome.isClean()) {
        try msg.append(arena, '\n');
        try msg.appendSlice(arena, r.comment);
        try msg.appendSlice(arena, " Conflicts:\n");
        for (outcome.conflicts) |conflict| {
            try msg.appendSlice(arena, r.comment);
            try msg.append(arena, '\t');
            try msg.appendSlice(arena, conflict.path);
            try msg.append(arena, '\n');
        }
        const copied = try arena.dupe(threeway.Conflict, outcome.conflicts);
        for (copied) |*c| c.path = try arena.dupe(u8, c.path);
        r.conflicts = copied;
    }
    try head_mod.writeState(io, repo.git_dir, "MERGE_MSG", msg.items);

    // The pseudo-ref a continuation reads the commit back from.
    const clean = outcome.isClean();
    switch (r.action) {
        .pick => if (!r.options.no_commit) try head_mod.writeRef(io, repo, "CHERRY_PICK_HEAD", oid),
        .revert => if ((r.options.no_commit and clean) or !clean) try head_mod.writeRef(io, repo, "REVERT_HEAD", oid),
    }
    if (!clean) {
        try updateAbortSafety(gpa, io, repo);
        // git runs rerere once the pick has stopped.
        _ = try rerere.afterStop(gpa, io, repo, &index, arena, r.options.rerere_autoupdate);
        return .conflicted;
    }

    // Whether the result changes anything, and what to do if not.
    var allow_empty_commit = false;
    const head_commit_tree = if (head.oid) |h| try repo.commitTree(io, h) else try emptyTree(repo, io);
    if (outcome.tree.?.eql(head_commit_tree)) {
        const parent_tree = if (commit.parents.len != 0) try repo.commitTree(io, commit.parents[0]) else try emptyTree(repo, io);
        const originally_empty = parent_tree.eql(commit.tree);
        if (originally_empty) {
            allow_empty_commit = r.options.allow_empty or r.options.empty == .keep;
        } else switch (r.options.empty) {
            .keep => allow_empty_commit = true,
            .drop => {
                try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
                try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
                try head_mod.deleteRef(io, repo, "AUTO_MERGE");
                try updateAbortSafety(gpa, io, repo);
                return .dropped;
            },
            .stop => {},
        }
    }
    if (r.options.no_commit) {
        try updateAbortSafety(gpa, io, repo);
        return .staged;
    }
    if (outcome.tree.?.eql(head_commit_tree) and !allow_empty_commit) {
        try updateAbortSafety(gpa, io, repo);
        return .empty;
    }

    const cleanup: message.Cleanup = r.options.cleanup orelse
        if (r.options.signoff or r.options.record_origin) .whitespace else configuredCleanup(repo);
    const cleaned = try message.cleanup(arena, msg.items, cleanup, r.comment);
    if (cleaned.len == 0 and !r.options.allow_empty_message) return error.EmptyMessage;
    const made = try repo.writeCommit(io, .{
        .tree = outcome.tree.?,
        .parents = if (head.oid) |h| &.{h} else &.{},
        .author = author orelse r.options.who,
        .committer = r.options.who,
        .message = cleaned,
    });
    const log = try std.fmt.allocPrint(arena, "{s}: {s}", .{ r.action.name(), firstLine(cleaned) });
    try head_mod.advance(io, repo, head, made, .{ .who = r.options.who, .message = log });
    try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
    try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
    try updateAbortSafety(gpa, io, repo);
    try r.made.append(arena, made);
    return .committed;
}

/// The subject a reflog line quotes: up to the first newline.
fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

/// `commit.cleanup`, or the message as it is.
fn configuredCleanup(repo: *Repository) message.Cleanup {
    const text = repo.config.get("commit.cleanup") orelse return .verbatim;
    return message.Cleanup.parse(text) orelse .verbatim;
}

fn emptyTree(repo: *Repository, io: Io) Error!Oid {
    return repo.odb.write(io, .tree, "");
}

/// `sequencer_format_revert_message`: `Revert "<subject>"`, or `Reapply
/// "<subject>"` for a revert of a revert, and the commit reverted.
fn revertMessage(r: *Replay, msg: *std.ArrayList(u8), subject: []const u8, oid: Oid, merge_parent: ?Oid) Error!void {
    const arena = r.arena;
    const prefix = "Revert \"";
    if (std.mem.startsWith(u8, subject, prefix) and !std.mem.startsWith(u8, subject[prefix.len..], prefix)) {
        try msg.appendSlice(arena, "Reapply \"");
        try msg.appendSlice(arena, subject[prefix.len..]);
        try msg.append(arena, '\n');
    } else {
        try msg.appendSlice(arena, prefix);
        try msg.appendSlice(arena, subject);
        try msg.appendSlice(arena, "\"\n");
    }
    var hex: [hash.max_hex_len]u8 = undefined;
    try msg.appendSlice(arena, "\nThis reverts commit ");
    try msg.appendSlice(arena, oid.hex(&hex));
    if (merge_parent) |p| {
        try msg.appendSlice(arena, ", reversing\nchanges made to ");
        try msg.appendSlice(arena, p.hex(&hex));
    }
    try msg.appendSlice(arena, ".\n");
}

//=========================================================================
// Sequences
//=========================================================================

fn newReplay(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, action: Action, options: Options) Error!Replay {
    if (repo.config.getBool("commit.gpgsign", false) catch false) return error.SigningRequested;
    return .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .repo = repo,
        .action = action,
        .options = options,
        .comment = message.commentString(repo.config.get("core.commentchar"), ""),
        .abbrev_len = abbrev.defaultLength(&repo.config, &repo.odb),
    };
}

fn start(gpa: Allocator, io: Io, repo: *Repository, action: Action, commits: []const Oid, options: Options) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    if (commits.len == 0) return error.NotACommit;
    if (merging.inProgress(io, repo)) return error.MergeInProgress;

    var r = try newReplay(gpa, arena, io, repo, action, options);

    if (commits.len == 1 and !options.sequence) {
        const picked = try pickOne(&r, commits[0]);
        return finishOutcome(&r, &arena_instance, picked, commits[0]);
    }

    if (lastCommand(gpa, io, repo) != null) return error.SequencerInProgress;
    // The sheet git writes: short names and first-line subjects.
    var items: std.ArrayList(todo.Item) = .empty;
    for (commits) |oid| {
        const read = try readCommit(&r, oid);
        try items.append(arena, .{ .command = action.command(), .commit = oid, .arg = message.subjectLine(read.commit.message) });
    }
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    if (head.oid == null and action == .revert) return error.UnbornBranch;
    repo.git_dir.createDir(io, seq_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SequencerInProgress,
        else => |e| return e,
    };
    var hex: [hash.max_hex_len]u8 = undefined;
    const head_text = if (head.oid) |oid| try std.fmt.allocPrint(arena, "{s}\n", .{oid.hex(&hex)}) else "\n";
    try head_mod.writeState(io, repo.git_dir, head_path, head_text);
    try writeOpts(gpa, io, repo, action, options);
    try updateAbortSafety(gpa, io, repo);
    return runSequence(&r, &arena_instance, items.items);
}

/// Work through `items`, writing what is left to `todo` before each one, as
/// `pick_commits` does; the sequencer's directory goes when the last one is
/// done.
fn runSequence(r: *Replay, arena_instance: *std.heap.ArenaAllocator, items: []const todo.Item) Error!Outcome {
    for (items, 0..) |item, at| {
        try saveTodo(r, items[at..]);
        const picked = try pickOne(r, item.commit.?);
        switch (picked) {
            .committed, .dropped, .staged => {},
            .conflicted, .empty => return finishOutcome(r, arena_instance, picked, item.commit.?),
        }
    }
    try removeSequencerState(r.io, r.repo);
    return finishOutcome(r, arena_instance, .committed, null);
}

fn finishOutcome(r: *Replay, arena_instance: *std.heap.ArenaAllocator, picked: Picked, at: ?Oid) Outcome {
    const stopped: ?Stop = switch (picked) {
        .conflicted => .conflict,
        .empty => .empty,
        else => null,
    };
    return .{
        .gpa = r.gpa,
        .arena = arena_instance.state,
        .stopped = stopped,
        .stopped_at = if (stopped != null) at else null,
        .conflicts = if (stopped == .conflict) r.conflicts else &.{},
        .made = r.made.items,
    };
}

fn saveTodo(r: *Replay, items: []const todo.Item) Error!void {
    const Shorten = struct {
        fn shorten(context: *anyopaque, oid: Oid, buf: *[hash.max_hex_len]u8) []const u8 {
            const replay: *Replay = @ptrCast(@alignCast(context));
            const text = abbrev.unique(replay.io, &replay.repo.odb, oid, replay.abbrev_len, buf) catch return oid.hex(buf);
            return text;
        }
    };
    const bytes = try todo.toBytes(r.arena, items, .{ .short = .{ .context = r, .shortenFn = Shorten.shorten } });
    try head_mod.writeState(r.io, r.repo.git_dir, todo_path, bytes);
}

/// How a sheet's names are resolved: any name a commit goes by, with its
/// tags peeled.
pub fn commitResolver(repo: *Repository, io: Io) ResolverContext {
    return .{ .repo = repo, .io = io };
}

/// The context `todo.parse` resolves names through.
pub const ResolverContext = struct {
    repo: *Repository,
    io: Io,

    pub fn resolver(c: *ResolverContext) todo.Resolver {
        return .{ .context = c, .resolveFn = resolveName };
    }

    fn resolveName(context: *anyopaque, text: []const u8) ?todo.Resolver.Resolved {
        const c: *ResolverContext = @ptrCast(@alignCast(context));
        const gpa = c.repo.gpa;
        var oid: ?Oid = null;
        if (text.len == c.repo.kind.hexLen()) oid = Oid.parse(c.repo.kind, text) catch null;
        if (oid == null) {
            const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
            inline for (rules) |rule| {
                if (oid == null) {
                    if (std.fmt.allocPrint(gpa, rule, .{text})) |full| {
                        defer gpa.free(full);
                        if (c.repo.refs.resolve(gpa, c.io, full) catch null) |resolved| {
                            gpa.free(resolved.name);
                            oid = resolved.oid;
                        }
                    } else |_| {}
                }
            }
        }
        if (oid == null) oid = c.repo.odb.findPrefix(c.io, text) catch null;
        const found = oid orelse return null;
        const peeled = c.repo.peel(c.io, found) catch return null;
        const read = c.repo.odb.read(c.io, peeled) catch return null;
        defer c.repo.odb.gpa.free(read.bytes);
        if (read.type != .commit) return null;
        var commit = object.Commit.parse(gpa, c.repo.kind, read.bytes) catch return null;
        defer commit.deinit();
        return .{ .oid = peeled, .parents = commit.parents.len };
    }
};

/// Read `.git/sequencer/todo`.
fn readTodo(r: *Replay) Error!todo.List {
    const text = (try head_mod.readState(r.arena, r.io, r.repo.git_dir, todo_path)) orelse return error.NoSequencerInProgress;
    var context: ResolverContext = .{ .repo = r.repo, .io = r.io };
    const list = try todo.parse(r.arena, text, context.resolver(), .{ .comment = r.comment });
    if (list.count() == 0) return error.MalformedState;
    for (list.items.items) |item| {
        if (item.command == .comment) continue;
        if (item.command != r.action.command()) return error.ActionMismatch;
    }
    return list;
}

/// Commit what is staged for the pick `CHERRY_PICK_HEAD` or `REVERT_HEAD`
/// names: what `git cherry-pick --continue` runs `git commit --no-edit
/// --cleanup=strip` for.
fn commitStaged(r: *Replay) Error!Oid {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    const arena = r.arena;
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (r.options.blocked) |b| b.set(entry.path);
            return error.UnresolvedConflicts;
        }
    }
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});

    const picked = try head_mod.readRef(gpa, io, repo, "CHERRY_PICK_HEAD");
    var author = r.options.who;
    if (picked) |oid| author = (try readCommit(r, oid)).commit.author;
    const head_tree = if (head.oid) |h| try repo.commitTree(io, h) else try emptyTree(repo, io);
    if (tree.eql(head_tree) and !r.options.allow_empty and r.options.empty != .keep) return error.EmptyCommit;

    const raw = (try head_mod.readState(arena, io, repo.git_dir, "MERGE_MSG")) orelse "";
    const cleaned = try message.cleanup(arena, raw, .strip, r.comment);
    if (cleaned.len == 0 and !r.options.allow_empty_message) return error.EmptyMessage;
    const made = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = if (head.oid) |h| &.{h} else &.{},
        .author = author,
        .committer = r.options.who,
        .message = cleaned,
    });
    const log = if (picked != null)
        try std.fmt.allocPrint(arena, "commit (cherry-pick): {s}", .{firstLine(cleaned)})
    else
        try std.fmt.allocPrint(arena, "commit: {s}", .{firstLine(cleaned)});
    try head_mod.advance(io, repo, head, made, .{ .who = r.options.who, .message = log });
    try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
    try head_mod.deleteRef(io, repo, "REVERT_HEAD");
    // The commit is `git commit`'s, which records resolutions as it ends.
    try rerere.afterCommit(gpa, io, repo);
    try r.made.append(arena, made);
    return made;
}

/// Continue the cherry-pick or revert that stopped, whoever stopped it:
/// commit what is staged for the one that stopped, then carry on with the
/// rest of the sequence.
pub fn proceed(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const action = inProgress(io, repo) orelse return error.NoSequencerInProgress;
    var opts = options;
    try readOpts(gpa, io, repo, &opts);
    var r = try newReplay(gpa, arena, io, repo, action, opts);

    if (!head_mod.stateExists(io, repo.git_dir, todo_path)) {
        _ = try commitStaged(&r);
        return finishOutcome(&r, &arena_instance, .committed, null);
    }
    const list = try readTodo(&r);
    if (head_mod.stateExists(io, repo.git_dir, "CHERRY_PICK_HEAD") or
        head_mod.stateExists(io, repo.git_dir, "REVERT_HEAD"))
    {
        _ = try commitStaged(&r);
    }
    try requireIndexIsHead(&r);
    // The first line is the pick that stopped, done now one way or another.
    var rest: std.ArrayList(todo.Item) = .empty;
    var first = true;
    for (list.items.items) |item| {
        if (item.command == .comment) continue;
        if (first) {
            first = false;
            continue;
        }
        try rest.append(arena, item);
    }
    if (rest.items.len == 0) {
        try removeSequencerState(io, repo);
        return finishOutcome(&r, &arena_instance, .committed, null);
    }
    return runSequence(&r, &arena_instance, rest.items);
}

fn requireIndexIsHead(r: *Replay) Error!void {
    var index = try r.repo.openIndex(r.io);
    defer index.deinit();
    var head = try head_mod.read(r.gpa, r.io, r.repo);
    defer head.deinit(r.gpa);
    const head_tree = if (head.oid) |h| try r.repo.commitTree(r.io, h) else try emptyTree(r.repo, r.io);
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnresolvedConflicts;
    }
    const tree = try worktree.writeTree(r.gpa, r.io, &index, &r.repo.odb);
    if (!tree.eql(head_tree)) return error.DirtyIndex;
}

/// Leave out the pick that stopped and carry on with the rest.
pub fn skip(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Outcome {
    const action = inProgress(io, repo) orelse return error.NoSequencerInProgress;
    if (!head_mod.stateExists(io, repo.git_dir, action.headRef())) {
        if (!try abortIsSafe(gpa, io, repo)) return error.NothingToSkip;
    }
    try resetMerge(gpa, io, repo, try currentHead(gpa, io, repo), options.who, options.blocked);
    if (!head_mod.stateExists(io, repo.git_dir, seq_dir)) {
        const arena_instance: std.heap.ArenaAllocator = .init(gpa);
        return .{ .gpa = gpa, .arena = arena_instance.state };
    }
    return proceed(gpa, io, repo, options);
}

/// Stop the cherry-pick or revert and put `HEAD`, the index and the
/// working tree back to where it began -- unless something else has moved
/// `HEAD` since the sequence last did, in which case `HEAD` is left where it
/// is, as git leaves it. The state goes either way.
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, who: object.Signature, blocked: ?*threeway.Blocked) Error!void {
    const text = (try head_mod.readState(gpa, io, repo.git_dir, head_path)) orelse {
        if (!head_mod.stateExists(io, repo.git_dir, "CHERRY_PICK_HEAD") and
            !head_mod.stateExists(io, repo.git_dir, "REVERT_HEAD")) return error.NoSequencerInProgress;
        return resetMerge(gpa, io, repo, try currentHead(gpa, io, repo), who, blocked);
    };
    defer gpa.free(text);
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    const start_oid = Oid.parse(repo.kind, trimmed) catch return error.MalformedState;
    if (start_oid.isZero()) return error.UnbornBranch;
    if (try abortIsSafe(gpa, io, repo)) try resetMerge(gpa, io, repo, start_oid, who, blocked);
    try removeSequencerState(io, repo);
}

/// Forget the sequence and leave everything else as it is: `--quit`.
pub fn quit(io: Io, repo: *Repository) Error!void {
    try removeSequencerState(io, repo);
    try removeBranchState(io, repo);
}

/// Where `HEAD` is; git names it by its object name when it resets to it.
fn currentHead(gpa: Allocator, io: Io, repo: *Repository) Error!Oid {
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    return head.oid orelse error.UnbornBranch;
}

/// Whether `HEAD` is still where the sequence last put it.
fn abortIsSafe(gpa: Allocator, io: Io, repo: *Repository) Error!bool {
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const text = (try head_mod.readState(gpa, io, repo.git_dir, safety_path)) orelse {
        return head.oid == null;
    };
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return head.oid == null;
    const expected = Oid.parse(repo.kind, trimmed) catch return error.MalformedState;
    return head.oid != null and head.oid.?.eql(expected);
}

/// `git reset --merge <commit>`, `HEAD` when `target` is `null`: the index
/// and the working tree go back to the commit, keeping changes that were
/// never part of what is undone, `HEAD` moves there, `ORIG_HEAD` records
/// where it was, and every trace of a command in progress goes.
pub fn resetMerge(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    target: ?Oid,
    who: object.Signature,
    blocked: ?*threeway.Blocked,
) Error!void {
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const current = head.oid orelse return error.UnbornBranch;
    const to = target orelse current;
    var index = try repo.openIndex(io);
    defer index.deinit();
    try reset.toTree(gpa, io, repo, &index, try repo.commitTree(io, to), .merge, blocked);
    try index.write(io, repo.git_dir, "index", .{});
    try head_mod.writeRef(io, repo, "ORIG_HEAD", current);
    var buf: [hash.max_hex_len + 16]u8 = undefined;
    var hex: [hash.max_hex_len]u8 = undefined;
    const log = if (target) |oid|
        std.fmt.bufPrint(&buf, "reset: moving to {s}", .{oid.hex(&hex)}) catch unreachable
    else
        "reset: moving to HEAD";
    try head_mod.advance(io, repo, head, to, .{ .who = who, .message = log });
    try removeBranchState(io, repo);
}

/// `remove_branch_state`: the pseudo-refs and files a command in progress
/// leaves, all of them.
fn removeBranchState(io: Io, repo: *Repository) Error!void {
    try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
    try head_mod.deleteRef(io, repo, "REVERT_HEAD");
    try merging.removeMergeState(io, repo);
}

test "fuzz: any bytes are an opts file or a named error" {
    try std.testing.fuzz({}, fuzzOpts, .{});
}

fn fuzzOpts(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [256]u8 = undefined;
    const text = input[0..smith.slice(&input)];
    var options: Options = .{ .who = undefined };
    parseOpts(std.testing.allocator, text, &options) catch |err| switch (err) {
        error.MalformedState, error.EditorRequested, error.SigningRequested, error.UnsupportedStrategy => return,
        error.OutOfMemory => return err,
    };
}

test "an opts file with a mainline past any parent number is malformed" {
    var options: Options = .{ .who = undefined };
    try std.testing.expectError(error.MalformedState, parseOpts(std.testing.allocator, "[options]\n\tmainline = 99999999999\n", &options));
    try parseOpts(std.testing.allocator, "[options]\n\tmainline = 2\n\tsignoff = true\n", &options);
    try std.testing.expectEqual(@as(?u32, 2), options.mainline);
    try std.testing.expect(options.signoff);
}
