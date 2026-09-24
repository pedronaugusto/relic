//! Merging a commit into the current branch: `git merge` with one head.
//!
//! What it leaves is git's in every file git reads back. A fast-forward
//! moves the branch and logs `merge <name>: Fast-forward`; a clean merge
//! commits with the message `git fmt-merge-msg` would write and logs `merge
//! <name>: Merge made by the 'ort' strategy.`; a conflicted one stops with
//! `MERGE_HEAD`, `MERGE_MSG` (with its `# Conflicts:` list), `MERGE_MODE`,
//! `ORIG_HEAD` and `AUTO_MERGE` written, so `git commit` or `git merge
//! --continue` finishes it and `git merge --abort` undoes it -- and the same
//! is true the other way round. Several merge bases are merged into one
//! first, as git does, nested conflict markers and all; an octopus of
//! several heads is not done here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const merge = @import("merge.zig");
const revwalk = @import("revwalk.zig");
const threeway = @import("threeway.zig");
const ort = @import("ort.zig");
const rerere = @import("rerere.zig");
const reset = @import("reset.zig");
const head_mod = @import("head.zig");
const message = @import("message.zig");
const wildmatch = @import("wildmatch.zig");
const worktree = @import("worktree.zig");
const repo_mod = @import("repo.zig");
const refs_mod = @import("refs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a merge.
pub const Error = error{
    /// `MERGE_HEAD` is there: a merge is already waiting to be concluded.
    MergeInProgress,
    /// `CHERRY_PICK_HEAD` or `REVERT_HEAD` is there: a cherry-pick or a
    /// revert is waiting to be concluded.
    SequencerInProgress,
    /// There is no merge to conclude or abort.
    NoMergeInProgress,
    /// `HEAD` names a branch with no commit yet.
    UnbornBranch,
    /// The two commits share no history and the caller did not allow it.
    UnrelatedHistories,
    /// `--ff-only` was asked for and the merge is not a fast-forward.
    NotFastForward,
    /// The name given does not name a commit.
    NotACommit,
    /// The name given is an annotated tag. git merges its commit and quotes
    /// the tag's message in the merge commit's; this release does not.
    AnnotatedTag,
    /// `merge.log` or `merge.branchdesc` asks for a message this release
    /// does not write.
    UnsupportedMergeMessage,
    /// `commit.gpgSign` asks for a signed commit, which this release does
    /// not make.
    SigningRequested,
    /// The index still has conflicts; they are resolved before a merge is
    /// concluded.
    UnresolvedConflicts,
    /// The message left after cleanup is empty.
    EmptyMessage,
} || threeway.Error || head_mod.Error || revwalk.Error || refs_mod.ReadError || repo_mod.WriteError || rerere.Error;

/// When a merge may be a fast-forward: `merge.ff` and `--ff`, `--no-ff`,
/// `--ff-only`.
pub const FastForward = enum { allow, never, only };

/// What the merged commit is, which decides the words the message uses.
pub const Kind = enum { branch, remote_branch, tag, commit };

/// A commit to merge and the name it was asked for by.
pub const Target = struct {
    oid: Oid,
    /// As the person typed it: `topic`, `origin/main`, a hex name. The
    /// message quotes it and the reflog names it. Borrowed.
    name: []const u8,
    kind: Kind,
};

/// Find what `name` means the way `git merge <name>` does: a full ref, then
/// `refs/<name>`, `refs/tags/<name>`, `refs/heads/<name>`,
/// `refs/remotes/<name>` and `refs/remotes/<name>/HEAD`, and otherwise an
/// object name or a unique prefix of one. `name` is borrowed by the result.
pub fn resolve(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) Error!Target {
    const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
    inline for (rules) |rule| {
        const full = try std.fmt.allocPrint(gpa, rule, .{name});
        defer gpa.free(full);
        if (std.mem.startsWith(u8, full, "refs/") or std.mem.eql(u8, rule, "{s}")) {
            if (repo.refs.resolve(gpa, io, full) catch null) |resolved| {
                defer gpa.free(resolved.name);
                const kind: Kind = if (std.mem.startsWith(u8, resolved.name, "refs/heads/"))
                    .branch
                else if (std.mem.startsWith(u8, resolved.name, "refs/tags/"))
                    .tag
                else if (std.mem.startsWith(u8, resolved.name, "refs/remotes/"))
                    .remote_branch
                else
                    .commit;
                return targetOf(io, repo, resolved.oid, name, kind);
            }
        }
    }
    const oid = repo.odb.findPrefix(io, name) catch return error.NotACommit;
    return targetOf(io, repo, oid, name, .commit);
}

fn targetOf(io: Io, repo: *Repository, oid: Oid, name: []const u8, kind: Kind) Error!Target {
    const header = try repo.odb.readHeader(io, oid);
    switch (header.type) {
        .commit => return .{ .oid = oid, .name = name, .kind = kind },
        .tag => return error.AnnotatedTag,
        else => return error.NotACommit,
    }
}

/// How a merge is made.
pub const Options = struct {
    /// Who commits, and when; also who the reflog lines are by.
    who: object.Signature,
    /// Who the merge commit is by. The committer when `null`.
    author: ?object.Signature = null,
    /// `null` asks `merge.ff`.
    fast_forward: ?FastForward = null,
    /// `false` stops before committing even a clean merge: `--no-commit`.
    commit: bool = true,
    /// The merge commit's message, in place of the one git would write.
    message: ?[]const u8 = null,
    /// `--signoff`.
    signoff: bool = false,
    /// `--allow-unrelated-histories`.
    allow_unrelated_histories: bool = false,
    /// `null` asks `merge.conflictStyle`.
    conflict_style: ?merge.ConflictStyle = null,
    /// `-X ours` or `-X theirs`.
    favor: merge.Favor = .none,
    /// Where a refusal writes the path that caused it.
    blocked: ?*threeway.Blocked = null,
    /// Stage what a recorded resolution resolves: `--rerere-autoupdate`,
    /// `--no-rerere-autoupdate`, or `rerere.autoUpdate` when `null`.
    rerere_autoupdate: ?bool = null,
};

/// What a merge did.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    result: Result,
    /// The commit `HEAD` now names: the fast-forward's target or the merge
    /// commit. `null` when nothing was committed.
    commit: ?Oid = null,
    /// The paths left conflicted, sorted.
    conflicts: []const threeway.Conflict = &.{},
    /// What git's merge says about the paths it merged, grouped by path.
    messages: []const ort.Message = &.{},
    /// Conflicted paths a resolution rerere recorded before resolved: in
    /// the working tree, and staged when `rerere_autoupdate` says so.
    reused: []const []const u8 = &.{},

    pub const Result = enum {
        /// The commit was already part of the branch; nothing changed.
        up_to_date,
        /// The branch moved forward to the commit.
        fast_forward,
        /// A merge commit was made.
        merged,
        /// The merge was clean and left staged, as `--no-commit` asks.
        staged,
        /// The merge stopped with conflicts.
        conflicted,
    };

    /// Release the outcome.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// Whether a merge is waiting to be concluded: `MERGE_HEAD` is there.
pub fn inProgress(io: Io, repo: *Repository) bool {
    return head_mod.stateExists(io, repo.git_dir, "MERGE_HEAD");
}

/// Merge `target` into the current branch.
pub fn start(gpa: Allocator, io: Io, repo: *Repository, target: Target, options: Options) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    if (inProgress(io, repo)) return error.MergeInProgress;
    if (head_mod.stateExists(io, repo.git_dir, "CHERRY_PICK_HEAD") or
        head_mod.stateExists(io, repo.git_dir, "REVERT_HEAD")) return error.SequencerInProgress;
    try refuseSigning(repo);
    if (repo.config.getBool("merge.log", false) catch true) return error.UnsupportedMergeMessage;
    if (repo.config.getBool("merge.branchdesc", false) catch true) return error.UnsupportedMergeMessage;

    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const ours = head.oid orelse return error.UnbornBranch;
    const fast_forward = options.fast_forward orelse configuredFastForward(repo);

    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (options.blocked) |b| b.set(entry.path);
            return error.UnmergedIndex;
        }
    }

    const bases = try revwalk.mergeBases(gpa, io, &repo.odb, ours, target.oid);
    defer gpa.free(bases);

    const reflog_action = try std.fmt.allocPrint(arena, "merge {s}", .{target.name});
    try head_mod.writeRef(io, repo, "ORIG_HEAD", ours);

    if (bases.len == 0 and !options.allow_unrelated_histories) return error.UnrelatedHistories;
    if (bases.len == 1 and bases[0].eql(target.oid)) {
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    }

    const our_tree = try repo.commitTree(io, ours);
    const their_tree = try repo.commitTree(io, target.oid);

    if (fast_forward != .never and bases.len == 1 and bases[0].eql(ours)) {
        var outcome = try threeway.apply(gpa, io, repo, &index, our_tree, our_tree, their_tree, .{ .blocked = options.blocked });
        defer outcome.deinit();
        try index.write(io, repo.git_dir, "index", .{});
        const log_message = try std.fmt.allocPrint(arena, "{s}: Fast-forward", .{reflog_action});
        try head_mod.advance(io, repo, head, target.oid, .{ .who = options.who, .message = log_message });
        try removeMergeState(io, repo);
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .fast_forward, .commit = target.oid };
    }
    if (fast_forward == .only) return error.NotFastForward;

    // The bases oldest first, as git hands them to its recursive merge.
    const reversed = try arena.alloc(Oid, bases.len);
    for (bases, 0..) |base, i| reversed[bases.len - 1 - i] = base;
    const style = options.conflict_style orelse configuredStyle(repo);
    var outcome = try threeway.applyCommits(gpa, io, repo, &index, ours, target.oid, reversed, .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .theirs = target.name },
            .favor = options.favor,
            .algorithm = .histogram,
        },
        .blocked = options.blocked,
    });
    defer outcome.deinit();
    try index.write(io, repo.git_dir, "index", .{});
    try head_mod.writeRef(io, repo, "AUTO_MERGE", outcome.auto_merge);

    const comment = message.commentString(repo.config.get("core.commentchar"), "");
    var msg: std.ArrayList(u8) = .empty;
    if (options.message) |text| {
        try msg.appendSlice(arena, text);
        if (msg.items.len != 0 and msg.items[msg.items.len - 1] != '\n') try msg.append(arena, '\n');
    } else {
        try msg.appendSlice(arena, try title(arena, io, repo, target, head));
    }
    const conflicts = try arena.dupe(threeway.Conflict, outcome.conflicts);
    for (conflicts) |*c| c.path = try arena.dupe(u8, c.path);
    const messages = try ort.dupeMessages(arena, outcome.messages);

    if (outcome.isClean() and options.commit) {
        // The sign-off goes on the commit and never into `MERGE_MSG`.
        if (options.signoff) try message.appendSignoff(arena, &msg, options.who, comment);
        const cleaned = try message.cleanup(arena, msg.items, cleanupMode(repo, false), comment);
        if (cleaned.len == 0) return error.EmptyMessage;
        const commit = try repo.writeCommit(io, .{
            .tree = outcome.tree.?,
            .parents = &.{ ours, target.oid },
            .author = options.author orelse options.who,
            .committer = options.who,
            .message = cleaned,
        });
        const log_message = try std.fmt.allocPrint(arena, "{s}: Merge made by the 'ort' strategy.", .{reflog_action});
        try head_mod.advance(io, repo, head, commit, .{ .who = options.who, .message = log_message });
        try removeMergeState(io, repo);
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .merged, .commit = commit, .messages = messages };
    }

    // Stopped: with conflicts, or before committing as asked.
    var hex: [hash.max_hex_len]u8 = undefined;
    try head_mod.writeState(io, repo.git_dir, "MERGE_HEAD", try std.fmt.allocPrint(arena, "{s}\n", .{target.oid.hex(&hex)}));
    if (!outcome.isClean()) {
        try msg.append(arena, '\n');
        try msg.appendSlice(arena, comment);
        try msg.appendSlice(arena, " Conflicts:\n");
        for (conflicts) |conflict| {
            try msg.appendSlice(arena, comment);
            try msg.append(arena, '\t');
            try msg.appendSlice(arena, conflict.path);
            try msg.append(arena, '\n');
        }
    }
    try head_mod.writeState(io, repo.git_dir, "MERGE_MSG", msg.items);
    try head_mod.writeState(io, repo.git_dir, "MERGE_MODE", if (fast_forward == .never) "no-ff" else "");
    var reused: []const []const u8 = &.{};
    if (!outcome.isClean()) reused = try runRerere(gpa, io, repo, &index, arena, options.rerere_autoupdate);
    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .result = if (outcome.isClean()) .staged else .conflicted,
        .conflicts = conflicts,
        .messages = messages,
        .reused = reused,
    };
}

/// How a merge waiting in the working tree is concluded.
pub const ConcludeOptions = struct {
    who: object.Signature,
    author: ?object.Signature = null,
    /// The message, in place of `MERGE_MSG`.
    message: ?[]const u8 = null,
    /// How the message is cleaned. `strip`, which drops the `# Conflicts:`
    /// list, is what `git commit` does when a person has seen the message in
    /// an editor; `git commit --no-edit` keeps comments and cleans only
    /// whitespace.
    cleanup: message.Cleanup = .strip,
};

/// Commit the merge `MERGE_HEAD` describes, from the index as it stands:
/// what `git commit` and `git merge --continue` do once the conflicts are
/// resolved.
pub fn conclude(gpa: Allocator, io: Io, repo: *Repository, options: ConcludeOptions) Error!Oid {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const heads_text = (try head_mod.readState(arena, io, repo.git_dir, "MERGE_HEAD")) orelse return error.NoMergeInProgress;
    try refuseSigning(repo);
    var parents: std.ArrayList(Oid) = .empty;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    try parents.append(arena, head.oid orelse return error.UnbornBranch);
    var lines = std.mem.tokenizeAny(u8, heads_text, "\r\n");
    while (lines.next()) |line| {
        try parents.append(arena, Oid.parse(repo.kind, std.mem.trim(u8, line, " \t")) catch return error.MalformedRef);
    }

    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnresolvedConflicts;
    }
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});

    const raw = options.message orelse ((try head_mod.readState(arena, io, repo.git_dir, "MERGE_MSG")) orelse "");
    const comment = message.commentString(repo.config.get("core.commentchar"), raw);
    const cleaned = try message.cleanup(arena, raw, options.cleanup, comment);
    if (cleaned.len == 0) return error.EmptyMessage;
    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = parents.items,
        .author = options.author orelse options.who,
        .committer = options.who,
        .message = cleaned,
    });
    const log_message = try std.fmt.allocPrint(arena, "commit (merge): {s}", .{message.subjectLine(cleaned)});
    try head_mod.advance(io, repo, head, commit, .{ .who = options.who, .message = log_message });
    try finishCommit(gpa, io, repo);
    return commit;
}

/// What `git commit` does to a stop's files once the commit that ends it is
/// made: `rerere.afterCommit`.
pub const finishCommit = rerere.afterCommit;

/// Run rerere on a stop: `rerere.afterStop`.
pub const runRerere = rerere.afterStop;

/// Undo a merge that stopped: `git merge --abort`, which is `git reset
/// --merge`. Changes a person made before the merge, to paths the merge did
/// not touch, survive it.
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, who: object.Signature, blocked: ?*threeway.Blocked) Error!void {
    if (!inProgress(io, repo)) return error.NoMergeInProgress;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const current = head.oid orelse return error.UnbornBranch;
    var index = try repo.openIndex(io);
    defer index.deinit();
    try reset.toTree(gpa, io, repo, &index, try repo.commitTree(io, current), .merge, blocked);
    try index.write(io, repo.git_dir, "index", .{});
    try removeMergeState(io, repo);
    // `git reset` records where it moved from and logs the move, even to
    // where it already was.
    try head_mod.writeRef(io, repo, "ORIG_HEAD", current);
    try head_mod.advance(io, repo, head, current, .{ .who = who, .message = "reset: moving to HEAD" });
}

/// Remove what a merge in progress leaves: `MERGE_HEAD`, `MERGE_MSG`,
/// `MERGE_MODE`, `MERGE_RR` and `AUTO_MERGE`.
pub fn removeMergeState(io: Io, repo: *Repository) head_mod.Error!void {
    for ([_][]const u8{ "MERGE_HEAD", "MERGE_RR", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG" }) |name| {
        try head_mod.removeState(io, repo.git_dir, name);
    }
    try head_mod.deleteRef(io, repo, "AUTO_MERGE");
}

/// `commit.gpgSign` asks for a signature this release cannot make.
pub fn refuseSigning(repo: *Repository) error{SigningRequested}!void {
    if (repo.config.getBool("commit.gpgsign", false) catch false) return error.SigningRequested;
}

fn configuredFastForward(repo: *Repository) FastForward {
    const text = repo.config.get("merge.ff") orelse return .allow;
    if (std.ascii.eqlIgnoreCase(text, "only")) return .only;
    const on = @import("config.zig").parseBool(text) catch return .allow;
    return if (on) .allow else .never;
}

/// `merge.conflictStyle`, or the plain style.
pub fn configuredStyle(repo: *Repository) merge.ConflictStyle {
    const text = repo.config.get("merge.conflictstyle") orelse return .merge;
    return merge.ConflictStyle.parse(text) orelse .merge;
}

/// The cleanup `git merge` uses: `commit.cleanup`, or whitespace alone when
/// no editor is involved.
fn cleanupMode(repo: *Repository, editor: bool) message.Cleanup {
    const text = repo.config.get("commit.cleanup") orelse return if (editor) .strip else .whitespace;
    if (std.mem.eql(u8, text, "default")) return if (editor) .strip else .whitespace;
    return message.Cleanup.parse(text) orelse .whitespace;
}

/// `git fmt-merge-msg`'s title: `Merge branch 'topic'`, and ` into <branch>`
/// unless the branch is one `merge.suppressDest` names -- `main` and
/// `master` when it names none.
fn title(arena: Allocator, io: Io, repo: *Repository, target: Target, head: head_mod.Head) Error![]const u8 {
    _ = io;
    const what = switch (target.kind) {
        .branch => "branch",
        .remote_branch => "remote-tracking branch",
        .tag => "tag",
        .commit => "commit",
    };
    const current = head.shortName() orelse "HEAD";
    var suppressed = false;
    const patterns = try repo.config.all("merge.suppressdest");
    defer repo.config.gpa.free(patterns);
    var effective: std.ArrayList([]const u8) = .empty;
    if (patterns.len == 0) {
        try effective.appendSlice(arena, &.{ "main", "master" });
    } else for (patterns) |pattern| {
        if (pattern.len == 0) effective.clearRetainingCapacity() else try effective.append(arena, pattern);
    }
    for (effective.items) |pattern| {
        if (wildmatch.match(pattern, current, .{ .pathname = true }) catch false) suppressed = true;
    }
    if (suppressed) return std.fmt.allocPrint(arena, "Merge {s} '{s}'\n", .{ what, target.name });
    return std.fmt.allocPrint(arena, "Merge {s} '{s}' into {s}\n", .{ what, target.name, current });
}
