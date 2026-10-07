//! Merging commits into the current branch: `git merge`.
//!
//! What it leaves is git's in every file git reads back. A fast-forward
//! moves the branch and logs `merge <name>: Fast-forward`; a clean merge
//! commits with the message `git fmt-merge-msg` would write and logs `merge
//! <name>: Merge made by the 'ort' strategy.`; a conflicted one stops with
//! `MERGE_HEAD`, `MERGE_MSG` (with its `# Conflicts:` list), `MERGE_MODE`,
//! `ORIG_HEAD` and `AUTO_MERGE` written, so `git commit` or `git merge
//! --continue` finishes it and `git merge --abort` undoes it -- and the same
//! is true the other way round. Several merge bases are merged into one
//! first, as git does, nested conflict markers and all. Two or more heads
//! make an octopus, merged as git's `merge-octopus` merges them.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const merge = @import("../merge.zig");
const revwalk = @import("../revwalk.zig");
const threeway = @import("../merge/threeway.zig");
const refspec = @import("../transport/refspec.zig");
const signing_mod = @import("signing.zig");
const hooks_mod = @import("../repo/hooks.zig");
const commithooks = @import("commithooks.zig");
const program = @import("../repo/program.zig");
const filter = @import("../worktree/filter.zig");
const ort = @import("../merge/ort.zig");
const rerere = @import("../merge/rerere.zig");
const reset = @import("reset.zig");
const head_mod = @import("head.zig");
const message = @import("message.zig");
const glob_mod = @import("../text/glob.zig");
const worktree = @import("../worktree.zig");
const repo_mod = @import("../repo.zig");
const refs_mod = @import("../refs.zig");
const index_mod = @import("../index.zig");
const diagnostic = @import("../repo/diagnostic.zig");
const config = @import("../config.zig");

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
    /// No commit was named and `merge.defaultToUpstream` is off.
    NoMergeTarget,
    /// No commit was named and the current branch has no upstream:
    /// `branch.<name>.remote` and `branch.<name>.merge`.
    NoDefaultUpstream,
    /// The upstream's remote-tracking ref is not there: nothing has been
    /// fetched for it.
    UpstreamNotFetched,
    /// The index still has conflicts; they are resolved before a merge is
    /// concluded.
    UnresolvedConflicts,
    /// The message left after cleanup is empty.
    EmptyMessage,
} || threeway.Error || head_mod.Error || revwalk.Error || refs_mod.ReadError || repo_mod.WriteError || rerere.Error || commithooks.Error;

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
pub fn resolve(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) Self.Error!Target {
    const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
    inline for (rules) |rule| {
        const full = try gpa.print(rule, .{name});
        defer gpa.free(full);
        if (std.mem.startsWith(u8, full, "refs/") or std.mem.eql(u8, rule, "{s}")) {
            if (repo.refStore().resolve(gpa, io, full) catch null) |resolved| {
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

/// What `git merge` with no commit merges: the upstreams of the current
/// branch, each `branch.<name>.merge` as the remote-tracking ref the
/// remote's fetch refspecs map it to -- or the ref itself for a remote of
/// `.` -- named by its full name, as git names it in the message. More than
/// one is an octopus, `startHeads`. The names live in `arena`.
pub fn upstreams(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository) Self.Error![]const Target {
    if (!(repo.configuration().getBool("merge.defaulttoupstream", true) catch true)) return error.NoMergeTarget;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const branch = head.shortName() orelse return error.NoDefaultUpstream;
    const remote = repo.configuration().get(try arena.print("branch.{s}.remote", .{branch})) orelse
        return error.NoDefaultUpstream;
    const merges = try repo.configuration().all(try arena.print("branch.{s}.merge", .{branch}));
    defer repo.configuration().gpa.free(merges);
    if (merges.len == 0) return error.NoDefaultUpstream;
    const specs = try repo.configuration().all(try arena.print("remote.{s}.fetch", .{remote}));
    defer repo.configuration().gpa.free(specs);
    const out = try arena.alloc(Target, merges.len);
    for (merges, out) |merge_name, *target| {
        var name: []const u8 = try arena.dupe(u8, merge_name);
        if (!std.mem.eql(u8, remote, ".")) {
            const tracking: ?[]const u8 = for (specs) |text| {
                const spec = refspec.Refspec.parse(text, .fetch) catch continue;
                if (try spec.mapSource(arena, name)) |mapped| break mapped;
            } else null;
            name = tracking orelse return error.UpstreamNotFetched;
        }
        const resolved = (try repo.refStore().resolve(gpa, io, name)) orelse return error.UpstreamNotFetched;
        defer gpa.free(resolved.name);
        const kind: Kind = if (std.mem.startsWith(u8, name, "refs/heads/"))
            .branch
        else if (std.mem.startsWith(u8, name, "refs/tags/"))
            .tag
        else if (std.mem.startsWith(u8, name, "refs/remotes/"))
            .remote_branch
        else
            .commit;
        target.* = try targetOf(io, repo, resolved.oid, name, kind);
    }
    return out;
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
    /// `-X`: the strategy options, in the order given, as
    /// `strategy.Settings.apply` reads them.
    strategy_options: []const []const u8 = &.{},
    /// The filter drivers and relic's own LFS the merged files go through,
    /// as `Repository.loadFilters` gives them: `threeway.Options.filters`.
    filters: ?*const filter.Drivers = null,
    /// The permission to run the filters' programs.
    programs: ?program.Programs = null,
    /// The hooks to run, or `null` for none: `pre-merge-commit`,
    /// `prepare-commit-msg`, `commit-msg` and `post-merge`, as `git merge`
    /// runs them.
    hooks: ?*hooks_mod.Runner = null,
    /// `false` skips `pre-merge-commit` and `commit-msg`: `--no-verify`.
    verify: bool = true,
    /// Whether and how the commits are signed: `-S`, `-S<key>`,
    /// `--no-gpg-sign`, or `commit.gpgSign` by default, with the programs
    /// that sign.
    signing: signing_mod.Request = .{},
    /// Caller-owned output for a refused write or failed signing program.
    diagnostic: ?*repo_mod.Diagnostic = null,
    /// Where a refusal writes the path that caused it.
    blocked: ?*threeway.Blocked = null,
    /// Stage what a recorded resolution resolves: `--rerere-autoupdate`,
    /// `--no-rerere-autoupdate`, or `rerere.autoUpdate` when `null`.
    rerere_autoupdate: ?bool = null,
    /// Keep the inner merges' messages in `Outcome.messages`, as git does at
    /// `GIT_MERGE_VERBOSITY=5`.
    inner_messages: bool = false,
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
    return repo.refStore().special().exists(io, .merge_head);
}

/// Merge `target` into the current branch.
pub fn start(gpa: Allocator, io: Io, repo: *Repository, target: Target, options: Options) Self.Error!Outcome {
    return startHeads(gpa, io, repo, &.{target}, options);
}

/// Merge `targets` into the current branch, as `git merge` with them all
/// does. A target `HEAD` or another target already reaches is dropped
/// first. One left is merged by ort; two or more by git's octopus,
/// `threeway.applyOctopus`, whose commit leaves `HEAD` out of its parents
/// when a target already contains it and a fast-forward is allowed.
pub fn startHeads(gpa: Allocator, io: Io, repo: *Repository, targets: []const Target, options: Options) Self.Error!Outcome {
    diagnostic.reset(options.diagnostic);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    if (targets.len == 0) return error.NoMergeTarget;
    if (inProgress(io, repo)) return error.MergeInProgress;
    if (repo.refStore().root().exists(repo.gpa, io, .cherry_pick_head) or
        repo.refStore().root().exists(repo.gpa, io, .revert_head)) return error.SequencerInProgress;
    if (repo.configuration().getBool("merge.log", false) catch true) return error.UnsupportedMergeMessage;
    if (repo.configuration().getBool("merge.branchdesc", false) catch true) return error.UnsupportedMergeMessage;

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

    // One target needs no reducing: the merge bases below say whether
    // `HEAD` reaches it or it reaches `HEAD`.
    const reduced: Reduced = if (targets.len == 1) .{ .heads = targets, .head_subsumed = false } else try reduceParents(gpa, arena, io, repo, ours, targets);
    // The reflog names the targets left.
    var action: std.ArrayList(u8) = .empty;
    try action.appendSlice(arena, "merge");
    for (reduced.heads) |target| {
        try action.append(arena, ' ');
        try action.appendSlice(arena, target.name);
    }
    const reflog_action = action.items;
    if (reduced.heads.len > 1) return octopus(gpa, io, repo, &arena_instance, &index, head, reduced, reflog_action, fast_forward, options);

    try repo.refStore().root().write(repo.gpa, io, .orig_head, ours);
    if (reduced.heads.len == 0) return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    const target = reduced.heads[0];
    const bases = try revwalk.mergeBases(gpa, io, &repo.odb, ours, target.oid);
    defer gpa.free(bases);

    if (bases.len == 0 and !options.allow_unrelated_histories) return error.UnrelatedHistories;
    if (bases.len == 1 and bases[0].eql(target.oid)) {
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    }

    const our_tree = try repo.commitTree(io, ours);
    const their_tree = try repo.commitTree(io, target.oid);

    if (fast_forward != .never and bases.len == 1 and bases[0].eql(ours)) {
        var outcome = try threeway.apply(gpa, io, repo, &index, our_tree, our_tree, their_tree, .{ .blocked = options.blocked });
        defer outcome.deinit();
        try repo.writeIndex(io, &index);
        const log_message = try arena.print("{s}: Fast-forward", .{reflog_action});
        try head_mod.advance(io, repo, head, target.oid, .{ .who = options.who, .message = log_message });
        if (options.hooks) |runner| _ = try runner.postMerge(io, false);
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
            .algorithm = .histogram,
        },
        .strategy_options = options.strategy_options,
        .filters = options.filters,
        .programs = options.programs,
        .blocked = options.blocked,
        .inner_messages = options.inner_messages,
    });
    defer outcome.deinit();
    try repo.writeIndex(io, &index);
    try repo.refStore().root().write(repo.gpa, io, .auto_merge, outcome.auto_merge);
    return commitOrStop(gpa, io, repo, &arena_instance, &index, &outcome, .{
        .head = head,
        .parents = &.{ ours, target.oid },
        .merged = &.{target.oid},
        .title = try title(arena, repo, reduced.heads, head),
        .reflog_action = reflog_action,
        .strategy = "ort",
        .fast_forward = fast_forward,
    }, options);
}

/// The targets left once every one `HEAD` or another target reaches is
/// dropped, in the order given, the first of any repeated kept: git's
/// `reduce_parents`. `head_subsumed` says a target reaches `HEAD`.
const Reduced = struct {
    heads: []const Target,
    head_subsumed: bool,
};

fn reduceParents(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, ours: Oid, targets: []const Target) Error!Reduced {
    var oids: std.ArrayList(Oid) = .empty;
    try oids.append(arena, ours);
    for (targets) |target| try oids.append(arena, target.oid);
    const kept_oids = try reduceHeads(gpa, arena, io, repo, oids.items);
    var kept: std.ArrayList(Target) = .empty;
    var head_subsumed = true;
    for (kept_oids) |oid| {
        if (oid.eql(ours)) {
            head_subsumed = false;
            continue;
        }
        for (targets) |target| {
            if (target.oid.eql(oid)) break try kept.append(arena, target);
        }
    }
    return .{ .heads = kept.items, .head_subsumed = head_subsumed };
}

/// git's `reduce_heads`: `oids` in order, each only once, without any one
/// another reaches. The result lives in `arena`.
fn reduceHeads(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, oids: []const Oid) Error![]const Oid {
    var unique: std.ArrayList(Oid) = .empty;
    for (oids) |oid| {
        for (unique.items) |seen| {
            if (seen.eql(oid)) break;
        } else try unique.append(arena, oid);
    }
    var kept: std.ArrayList(Oid) = .empty;
    for (unique.items, 0..) |one, i| {
        const redundant = for (unique.items, 0..) |other, j| {
            if (i != j and try revwalk.isAncestor(gpa, io, &repo.odb, one, other)) break true;
        } else false;
        if (!redundant) try kept.append(arena, one);
    }
    return kept.items;
}

/// `git merge` with two or more commits left to merge: the octopus.
fn octopus(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    arena_instance: *std.heap.ArenaAllocator,
    index: *index_mod.Index,
    head: head_mod.Head,
    reduced: Reduced,
    reflog_action: []const u8,
    fast_forward: FastForward,
    options: Options,
) Error!Outcome {
    const arena = arena_instance.allocator();
    const ours = head.oid.?;
    const heads = try arena.alloc(Oid, reduced.heads.len);
    for (reduced.heads, heads) |target, *oid| oid.* = target.oid;
    try repo.refStore().root().write(repo.gpa, io, .orig_head, ours);
    if (!options.allow_unrelated_histories and !try shareHistory(gpa, arena, io, repo, ours, heads)) return error.UnrelatedHistories;
    // Up to date when `HEAD` reaches every head.
    for (heads) |one| {
        const bases = try revwalk.mergeBases(gpa, io, &repo.odb, ours, one);
        defer gpa.free(bases);
        if (bases.len == 0 or !bases[0].eql(one)) break;
    } else return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    if (fast_forward == .only) return error.NotFastForward;

    var outcome = try threeway.applyOctopus(gpa, io, repo, index, ours, heads, .{
        .blob = .{ .conflict_style = options.conflict_style orelse configuredStyle(repo) },
        .filters = options.filters,
        .programs = options.programs,
        .blocked = options.blocked,
    });
    defer outcome.deinit();
    try repo.writeIndex(io, index);
    var parents: std.ArrayList(Oid) = .empty;
    if (!reduced.head_subsumed or fast_forward == .never) try parents.append(arena, ours);
    try parents.appendSlice(arena, heads);
    return commitOrStop(gpa, io, repo, arena_instance, index, &outcome, .{
        .head = head,
        .parents = parents.items,
        .merged = heads,
        .title = try title(arena, repo, reduced.heads, head),
        .reflog_action = reflog_action,
        .strategy = "octopus",
        .fast_forward = fast_forward,
    }, options);
}

/// Whether the commits have any merge base at all, folded as git's
/// `get_octopus_merge_bases` folds them.
fn shareHistory(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, ours: Oid, heads: []const Oid) Error!bool {
    var bases: std.ArrayList(Oid) = .empty;
    try bases.append(arena, ours);
    for (heads) |one| {
        var next: std.ArrayList(Oid) = .empty;
        for (bases.items) |base| {
            const found = try revwalk.mergeBases(gpa, io, &repo.odb, one, base);
            defer gpa.free(found);
            try next.appendSlice(arena, found);
        }
        bases = next;
    }
    return bases.items.len != 0;
}

/// How a merge was made and what it merged, for its end.
const Made = struct {
    head: head_mod.Head,
    parents: []const Oid,
    /// What `MERGE_HEAD` lists.
    merged: []const Oid,
    title: []const u8,
    reflog_action: []const u8,
    /// The strategy the reflog names.
    strategy: []const u8,
    fast_forward: FastForward,
};

/// Commit a clean merge the index now holds, or stop with `MERGE_HEAD`,
/// `MERGE_MSG` and `MERGE_MODE` written for a person to finish it.
fn commitOrStop(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    arena_instance: *std.heap.ArenaAllocator,
    index: *index_mod.Index,
    outcome: *const threeway.Outcome,
    made: Made,
    options: Options,
) Error!Outcome {
    const arena = arena_instance.allocator();
    const comment = message.commentString(repo.configuration().get("core.commentchar"), "");
    var msg: std.ArrayList(u8) = .empty;
    // The message as given, byte for byte; git's own title has no newline
    // at its end.
    try msg.appendSlice(arena, options.message orelse made.title);
    const conflicts = try arena.dupe(threeway.Conflict, outcome.conflicts);
    for (conflicts) |*c| c.path = try arena.dupe(u8, c.path);
    const messages = try ort.dupeMessages(arena, outcome.messages);
    var merge_heads: std.ArrayList(u8) = .empty;
    for (made.merged) |oid| {
        var hex: [hash.max_hex_len]u8 = undefined;
        try merge_heads.appendSlice(arena, oid.hex(&hex));
        try merge_heads.append(arena, '\n');
    }

    if (outcome.isClean() and options.commit) {
        // `prepare_to_commit`: `pre-merge-commit` first, then the message,
        // signed off, into `MERGE_MSG` beside `MERGE_HEAD` for the message
        // hooks, and back out of it.
        const h = try commithooks.Hooks.init(arena, io, repo, options.hooks, options.verify);
        if (options.signoff) try message.appendSignoff(arena, &msg, options.who, try message.trailerSettings(arena, repo.configuration()));
        var text: []const u8 = msg.items;
        if (h.runner) |runner| {
            const e = try h.env(arena, null);
            if (h.verify) _ = try runner.block(io, "pre-merge-commit", .{ .set = &.{
                .{ .name = "GIT_INDEX_FILE", .value = e.index_path },
                .{ .name = "GIT_EDITOR", .value = ":" },
            } });
            try repo.refStore().special().write(repo.gpa, io, .merge_head, merge_heads.items);
            try head_mod.writeState(io, repo.git_dir, "MERGE_MSG", text);
            const message_path = try h.path(arena, "MERGE_MSG");
            _ = try runner.prepareCommitMsg(io, e, message_path, .merge, null);
            if (h.verify) _ = try runner.commitMsg(io, e, message_path);
            text = (try head_mod.readState(arena, io, repo.git_dir, "MERGE_MSG")) orelse "";
        }
        const cleaned = try message.cleanup(arena, text, cleanupMode(repo, false), comment);
        if (cleaned.len == 0) return error.EmptyMessage;
        const commit = try repo.writeCommit(io, .{
            .tree = outcome.tree.?,
            .parents = made.parents,
            .author = options.author orelse options.who,
            .committer = options.who,
            .message = cleaned,
            .signing = options.signing,
        }, options.diagnostic);
        const log_message = try arena.print("{s}: Merge made by the '{s}' strategy.", .{ made.reflog_action, made.strategy });
        try head_mod.advance(io, repo, made.head, commit, .{ .who = options.who, .message = log_message });
        // `post-merge` runs before the merge's files go, as in git.
        if (options.hooks) |runner| _ = try runner.postMerge(io, false);
        try removeMergeState(io, repo);
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .merged, .commit = commit, .messages = messages };
    }

    // Stopped: with conflicts, or before committing as asked.
    try repo.refStore().special().write(repo.gpa, io, .merge_head, merge_heads.items);
    // `MERGE_MSG` ends the message with a newline whatever it ended with.
    try msg.append(arena, '\n');
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
    try head_mod.writeState(io, repo.git_dir, "MERGE_MODE", if (made.fast_forward == .never) "no-ff" else "");
    var reused: []const []const u8 = &.{};
    if (!outcome.isClean()) reused = try runRerere(gpa, arena, io, repo, index, options.rerere_autoupdate);
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
    /// The hooks to run, or `null` for none: `git commit`'s `pre-commit`,
    /// `prepare-commit-msg` with `merge`, `commit-msg` and `post-commit`.
    hooks: ?*hooks_mod.Runner = null,
    /// `false` skips `pre-commit` and `commit-msg`: `--no-verify`.
    verify: bool = true,
    /// Whether and how the commits are signed: `-S`, `-S<key>`,
    /// `--no-gpg-sign`, or `commit.gpgSign` by default, with the programs
    /// that sign.
    signing: signing_mod.Request = .{},
    /// Caller-owned output for a refused write or failed signing program.
    diagnostic: ?*repo_mod.Diagnostic = null,
};

/// Commit the merge `MERGE_HEAD` describes, from the index as it stands:
/// what `git commit` and `git merge --continue` do once the conflicts are
/// resolved.
pub fn conclude(gpa: Allocator, io: Io, repo: *Repository, options: ConcludeOptions) Self.Error!Oid {
    diagnostic.reset(options.diagnostic);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const heads_text = (try repo.refStore().special().readAll(arena, io, .merge_head)) orelse return error.NoMergeInProgress;
    var parents: std.ArrayList(Oid) = .empty;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    try parents.append(arena, head.oid orelse return error.UnbornBranch);
    var lines = std.mem.tokenizeAny(u8, heads_text, "\r\n");
    while (lines.next()) |line| {
        try parents.append(arena, Oid.parse(repo.objectFormat(), std.mem.trim(u8, line, " \t")) catch return error.MalformedRef);
    }
    // `git commit` drops a parent another reaches unless the merge was
    // asked not to fast-forward: an octopus that went past `HEAD`.
    const mode = (try head_mod.readState(arena, io, repo.git_dir, "MERGE_MODE")) orelse "";
    const kept: []const Oid = if (std.mem.eql(u8, mode, "no-ff")) parents.items else try reduceHeads(gpa, arena, io, repo, parents.items);

    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnresolvedConflicts;
    }
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try repo.writeIndex(io, &index);

    const h = try commithooks.Hooks.init(arena, io, repo, options.hooks, options.verify);
    const author = options.author orelse options.who;
    const given = options.message orelse ((try head_mod.readState(arena, io, repo.git_dir, "MERGE_MSG")) orelse "");
    const raw = try h.beforeCommit(arena, io, repo, given, .merge, author);
    const comment = message.commentString(repo.configuration().get("core.commentchar"), raw);
    const cleaned = try message.cleanup(arena, raw, options.cleanup, comment);
    if (cleaned.len == 0) return error.EmptyMessage;
    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = kept,
        .author = options.author orelse options.who,
        .committer = options.who,
        .message = cleaned,
        .signing = options.signing,
    }, options.diagnostic);
    const log_message = try arena.print("commit (merge): {s}", .{message.subjectLine(cleaned)});
    try head_mod.advance(io, repo, head, commit, .{ .who = options.who, .message = log_message });
    try finishCommit(gpa, io, repo);
    try h.postCommit(arena, io, author);
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
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, who: object.Signature, blocked: ?*threeway.Blocked) Self.Error!void {
    if (!inProgress(io, repo)) return error.NoMergeInProgress;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const current = head.oid orelse return error.UnbornBranch;
    var index = try repo.openIndex(io);
    defer index.deinit();
    try reset.toTree(gpa, io, repo, &index, try repo.commitTree(io, current), .merge, blocked);
    try repo.writeIndex(io, &index);
    try removeMergeState(io, repo);
    // `git reset` records where it moved from and logs the move, even to
    // where it already was.
    try repo.refStore().root().write(repo.gpa, io, .orig_head, current);
    try head_mod.advance(io, repo, head, current, .{ .who = who, .message = "reset: moving to HEAD" });
}

/// Remove what a merge in progress leaves: `MERGE_HEAD`, `MERGE_MSG`,
/// `MERGE_MODE`, `MERGE_RR` and `AUTO_MERGE`.
pub fn removeMergeState(io: Io, repo: *Repository) head_mod.Error!void {
    try repo.refStore().special().delete(io, .merge_head);
    for ([_][]const u8{ "MERGE_RR", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG" }) |name| {
        try head_mod.removeState(io, repo.git_dir, name);
    }
    try repo.refStore().root().delete(repo.gpa, io, .auto_merge);
}

fn configuredFastForward(repo: *Repository) FastForward {
    const text = repo.configuration().get("merge.ff") orelse return .allow;
    if (std.ascii.eqlIgnoreCase(text, "only")) return .only;
    const on = config.parseBool(text) catch return .allow;
    return if (on) .allow else .never;
}

/// `merge.conflictStyle`, or the plain style.
pub fn configuredStyle(repo: *Repository) merge.ConflictStyle {
    const text = repo.configuration().get("merge.conflictstyle") orelse return .merge;
    return merge.parseConflictStyle(text) orelse .merge;
}

/// The cleanup `git merge` uses: `commit.cleanup`, or whitespace alone when
/// no editor is involved.
fn cleanupMode(repo: *Repository, editor: bool) message.Cleanup {
    const text = repo.configuration().get("commit.cleanup") orelse return if (editor) .strip else .whitespace;
    if (std.mem.eql(u8, text, "default")) return if (editor) .strip else .whitespace;
    return message.Cleanup.parse(text) orelse .whitespace;
}

/// `git fmt-merge-msg`'s title: `Merge branch 'topic'`, and ` into <branch>`
/// unless the branch is one `merge.suppressDest` names -- `main` and
/// `master` when it names none. Several targets are grouped as git groups
/// them: the branches, remote-tracking branches and tags together, in that
/// order, and each commit on its own, the groups in the order they first
/// come: `Merge branches 'a' and 'b', tag 'v1'; commit 'abc1234'`.
fn title(arena: Allocator, repo: *Repository, targets: []const Target, head: head_mod.Head) Error![]const u8 {
    const current = head.shortName() orelse "HEAD";
    var suppressed = false;
    const patterns = try repo.configuration().all("merge.suppressdest");
    defer repo.configuration().gpa.free(patterns);
    var effective: std.ArrayList([]const u8) = .empty;
    if (patterns.len == 0) {
        try effective.appendSlice(arena, &.{ "main", "master" });
    } else for (patterns) |pattern| {
        if (pattern.len == 0) effective.clearRetainingCapacity() else try effective.append(arena, pattern);
    }
    for (effective.items) |pattern| {
        if (try glob_mod.matches(arena, pattern, current, .{})) suppressed = true;
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "Merge ");
    var local_done = false;
    for (targets, 0..) |target, i| {
        if (i != 0 and (target.kind == .commit or !local_done)) try out.appendSlice(arena, "; ");
        if (target.kind == .commit) {
            try out.print(arena, "commit '{s}'", .{target.name});
            continue;
        }
        if (local_done) continue;
        local_done = true;
        var separator: []const u8 = "";
        const groups = [_]struct { kind: Kind, one: []const u8, many: []const u8 }{
            .{ .kind = .branch, .one = "branch ", .many = "branches " },
            .{ .kind = .remote_branch, .one = "remote-tracking branch ", .many = "remote-tracking branches " },
            .{ .kind = .tag, .one = "tag ", .many = "tags " },
        };
        for (groups) |group| {
            var names: std.ArrayList([]const u8) = .empty;
            for (targets) |t| if (t.kind == group.kind) try names.append(arena, t.name);
            if (names.items.len == 0) continue;
            try out.appendSlice(arena, separator);
            separator = ", ";
            try out.appendSlice(arena, if (names.items.len == 1) group.one else group.many);
            for (names.items, 0..) |name, n| {
                if (n == names.items.len - 1 and n != 0) try out.appendSlice(arena, " and ") else if (n != 0) try out.appendSlice(arena, ", ");
                try out.print(arena, "'{s}'", .{name});
            }
        }
    }
    if (!suppressed) try out.print(arena, " into {s}", .{current});
    return out.items;
}
