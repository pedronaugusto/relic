//! `git history`: one commit rewritten where it stands, and everything
//! built on it replayed onto the rewrite, with no state kept between steps.
//!
//! It is git 2.56's `builtin/history.c`. `fixup` merges what is staged into
//! the commit; `reword` gives it a new message; `split` makes it two, the
//! first holding the changes the caller picked; `drop` takes it out. The
//! commits descending from it are replayed through `replay.plan` onto the
//! rewrite, and the branches on them and on the commit itself move in one
//! transaction -- every local branch that descends from it, or with
//! `UpdateRefs.head` only `HEAD`, which must. A merge among them is refused
//! before anything is written. Only `drop` touches the working tree, which
//! follows `HEAD` to its new tree. A message given is cleaned as git cleans
//! what its editor hands back.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const three_way = @import("../merge/three_way.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const message = @import("../object/message.zig");
const pretty = @import("../pretty/pretty.zig");
const replay = @import("replay.zig");
const worktree = @import("../checkout/checkout.zig");
const rev_walk = @import("../walk/walk.zig");
const rev_parse = @import("../repo/rev_parse.zig");
const repo_mod = @import("../repo/repo.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from rewriting history.
pub const Error = error{
    /// `fixup` with nothing staged against `HEAD`: "nothing to fixup: no
    /// staged changes".
    NothingStaged,
    /// `fixup` whose staged changes conflict with the commit: "fixup would
    /// produce conflicts; aborting".
    FixupConflicts,
    /// `fixup` leaving the commit empty under `Empty.abort`: "fixup makes
    /// commit %s empty".
    FixupMakesCommitEmpty,
    /// `fixup` leaving a root commit empty under `Empty.drop`: "cannot drop
    /// root commit".
    CannotDropRoot,
    /// `UpdateRefs.head` for a commit `HEAD` does not descend from:
    /// "rewritten commit must be an ancestor of HEAD".
    NotAncestorOfHead,
    /// `split`'s first tree the commit's parent's: "split commit is empty".
    SplitCommitEmpty,
    /// `split`'s first tree the commit's own: "split commit tree matches
    /// original commit".
    SplitMatchesOriginal,
    /// A message left empty once cleaned: "Aborting commit due to empty
    /// commit message".
    EmptyMessage,
    /// `fixup` with no index to read staged changes from.
    BareRepository,
    InvalidCommentString,
} || replay.Error || worktree.Error;

/// Which refs move: `--update-refs`.
pub const UpdateRefs = enum {
    /// Every local branch on the commit or descending from it, and a
    /// detached `HEAD`.
    branches,
    /// `HEAD` alone, which must descend from the commit.
    head,
};

/// How history is rewritten.
pub const Options = struct {
    /// Who commits, and when; also who the reflog lines are by.
    who: object.Signature,
    update_refs: UpdateRefs = .branches,
    /// `--dry-run`: the commits are made and the refs that would move
    /// returned, none moved.
    dry_run: bool = false,
    /// The `reference-transaction` hook, or `null` for none.
    hooks: ?*hooks_mod.Runner = null,
    diagnostic: ?*repo_mod.Diagnostic = null,
};

/// What a rewrite did.
pub const Outcome = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator.State,
    gpa: Allocator,
    /// The commit in the old one's place, or its parent where `fixup`
    /// dropped it.
    rewritten: Oid,
    /// The refs to move, in git's order: none when replaying a descendant
    /// stopped, as git then moves nothing.
    updates: []const replay.Update,
    /// Whether `updates` were made.
    updated: bool = false,
    /// Where replaying the descendants stopped.
    stopped: ?replay.Stop = null,

    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// `git history fixup <commit>`.
pub const FixupInputs = struct {
    commit: []const u8,
    /// `--reedit-message`: the message in place of the commit's own.
    message: ?[]const u8 = null,
    /// `--empty`: the commit, or a descendant, left with no change.
    empty: replay.Empty = .drop,
};

/// The changes staged against `HEAD` merged into `inputs.commit` -- `HEAD`
/// the base, the commit ours and the index theirs, as a cherry-pick of the
/// staged changes -- and the descendants replayed onto it.
pub fn fixup(gpa: Allocator, io: Io, repo: *Repository, inputs: FixupInputs, options: Options) Self.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    if (repo.workDirectory() == null) return error.BareRepository;
    const original = try commitOf(a, io, repo, inputs.commit);
    const head = try commitOf(a, io, repo, "HEAD");
    const head_tree = try repo.commitTree(io, head);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const index_tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());
    if (index_tree.eql(head_tree)) return error.NothingStaged;
    const original_tree = try repo.commitTree(io, original);
    var merged = try three_way.inCore(gpa, io, repo, .{ .base = head_tree, .ours = original_tree, .theirs = index_tree }, .{ .basic = true });
    defer merged.deinit();
    if (!merged.isClean()) return error.FixupConflicts;

    const parents = try parentsOf(a, io, repo, original);
    const parent_tree = if (parents.len != 0) try repo.commitTree(io, parents[0]) else repo.objectFormat().emptyTree();
    var dropped = false;
    if (merged.tree.eql(parent_tree)) switch (inputs.empty) {
        .drop => {
            if (parents.len == 0) return error.CannotDropRoot;
            dropped = true;
        },
        .keep => {},
        .abort => return error.FixupMakesCommitEmpty,
    };
    var h: History = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options };
    const range = try h.descendants(original);
    const rewritten = if (dropped) parents[0] else try h.commit(original, .{
        .parents = parents,
        .tree = merged.tree,
        .message = if (inputs.message) |text| try h.cleaned(text) else null,
    });
    return h.finish(&arena_state, .{ .range = range, .original = original, .rewritten = rewritten, .empty = inputs.empty, .action = "fixup", .name = inputs.commit });
}

/// `git history reword <commit>`.
pub const RewordInputs = struct {
    commit: []const u8,
    /// The new message, as the editor would hand it back.
    message: []const u8,
};

/// `inputs.commit` with a new message, everything else kept, and the
/// descendants replayed onto it.
pub fn reword(gpa: Allocator, io: Io, repo: *Repository, inputs: RewordInputs, options: Options) Self.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    const original = try commitOf(a, io, repo, inputs.commit);
    var h: History = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options };
    const range = try h.descendants(original);
    const rewritten = try h.commit(original, .{
        .parents = try parentsOf(a, io, repo, original),
        .tree = try repo.commitTree(io, original),
        .message = try h.cleaned(inputs.message),
    });
    return h.finish(&arena_state, .{ .range = range, .original = original, .rewritten = rewritten, .empty = .abort, .action = "reword", .name = inputs.commit });
}

/// `git history split <commit>`.
pub const SplitInputs = struct {
    commit: []const u8,
    /// The first commit's tree: the commit's parent with the changes picked
    /// from it, what git's `add -p` over the commit leaves staged.
    first: Oid,
    /// The first commit's message, then the second's, as the editor would
    /// hand each back.
    messages: [2][]const u8,
};

/// `inputs.commit` made two: the changes picked, on its parent, then the
/// rest, on that; the descendants replayed onto the second.
pub fn split(gpa: Allocator, io: Io, repo: *Repository, inputs: SplitInputs, options: Options) Self.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    const original = try commitOf(a, io, repo, inputs.commit);
    var h: History = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options };
    const range = try h.descendants(original);
    const parents = try parentsOf(a, io, repo, original);
    if (parents.len > 1) return error.MergeCommit;
    const parent_tree = if (parents.len != 0) try repo.commitTree(io, parents[0]) else repo.objectFormat().emptyTree();
    const original_tree = try repo.commitTree(io, original);
    if (inputs.first.eql(parent_tree)) return error.SplitCommitEmpty;
    if (inputs.first.eql(original_tree)) return error.SplitMatchesOriginal;
    const first_message = try h.cleaned(inputs.messages[0]);
    const second_message = try h.cleaned(inputs.messages[1]);
    const first = try h.commit(original, .{ .parents = parents, .tree = inputs.first, .message = first_message });
    const second = try h.commit(original, .{ .parents = &.{first}, .tree = original_tree, .message = second_message });
    return h.finish(&arena_state, .{ .range = range, .original = original, .rewritten = second, .empty = .abort, .action = "split", .name = inputs.commit });
}

/// `git history drop <commit>`.
pub const DropInputs = struct {
    commit: []const u8,
    /// `--empty`: a descendant left with no change.
    empty: replay.Empty = .drop,
};

/// git 2.56's `git history drop`: `inputs.commit` taken out of history, its
/// descendants replayed onto its parent and the refs on it moved to the
/// parent. A root commit has no parent to replay onto and a merge is
/// refused. Where `HEAD`'s branch moves to another tree, the index and the
/// working tree follow it two ways, as git's `reset_working_tree` takes
/// them: checked before any ref moves, so a change of the caller's in the
/// way refuses the drop, and made after.
pub fn drop(gpa: Allocator, io: Io, repo: *Repository, inputs: DropInputs, options: Options) Self.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    const original = try commitOf(a, io, repo, inputs.commit);
    const parents = try parentsOf(a, io, repo, original);
    if (parents.len == 0) return error.CannotDropRoot;
    if (parents.len > 1) return error.MergeCommit;
    var h: History = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options };
    const range = try h.descendants(original);
    return h.finish(&arena_state, .{
        .range = range,
        .original = original,
        .rewritten = parents[0],
        .empty = inputs.empty,
        .action = "drop",
        .verb = "dropping",
        .name = inputs.commit,
        .moves_worktree = true,
    });
}

/// The commit `name` peels to.
fn commitOf(a: Allocator, io: Io, repo: *Repository, name: []const u8) Self.Error!Oid {
    return rev_parse.resolve(a, io, repo.revisionSource(), try a.print("{s}^{{commit}}", .{name}));
}

fn parentsOf(a: Allocator, io: Io, repo: *Repository, oid: Oid) Self.Error![]const Oid {
    const info = try repo.commitInfo(io, oid, a);
    return info.parents;
}

/// git's `setup_revwalk`: what is replayed onto the rewrite.
const Range = struct {
    include: []const []const u8,
    exclude: []const []const u8,
};

const Finish = struct {
    range: Range,
    original: Oid,
    rewritten: Oid,
    empty: replay.Empty,
    /// The subcommand, what it does, and the commit as named, for the
    /// reflog: `<action>: <verb> <name>`.
    action: []const u8,
    verb: []const u8 = "updating",
    name: []const u8,
    /// Whether the index and the working tree follow `HEAD`'s branch to
    /// its new tree, as `drop` takes them.
    moves_worktree: bool = false,
};

const History = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,

    /// The revisions whose history descends from `original`, git's
    /// `--ancestry-path=<original> ^<original>` with `HEAD` and, for
    /// `branches`, every local branch; a merge among them refused before
    /// anything is written, as `revwalk_contains_merges` refuses it.
    fn descendants(h: *History, original: Oid) Error!Range {
        var hex: [hash.max_hex_len]u8 = undefined;
        const name = try h.a.dupe(u8, original.hex(&hex));
        var include: std.ArrayList([]const u8) = .empty;
        switch (h.options.update_refs) {
            .head => {
                const head = try commitOf(h.a, h.io, h.repo, "HEAD");
                if (!try rev_walk.isAncestor(h.gpa, h.io, h.repo.objectDatabase(), .{ .ancestor = original, .descendant = head }, .{})) return error.NotAncestorOfHead;
            },
            .branches => {
                var listing = try h.repo.refStore().list(h.gpa, h.io, "refs/heads/");
                defer listing.deinit();
                for (listing.entries) |entry| try include.append(h.a, try h.a.dupe(u8, entry.name));
            },
        }
        try include.append(h.a, "HEAD");
        var walk: rev_walk.Walk = .init(h.gpa, h.repo.objectDatabase());
        defer walk.deinit();
        walk.ancestry_path = &.{original};
        for (include.items) |rev| try walk.push(try commitOf(h.a, h.io, h.repo, rev));
        try walk.hide(original);
        while (try walk.next(h.io)) |walked| {
            if (walked.parents.len > 1) return error.MergeCommit;
        }
        const exclude = try h.a.alloc([]const u8, 1);
        exclude[0] = name;
        return .{ .include = include.items, .exclude = exclude };
    }

    /// A message cleaned as git's `fill_commit_message` cleans what the
    /// editor hands back: comments and needless blank space gone, and
    /// nothing left refused.
    fn cleaned(h: *History, text: []const u8) Error![]const u8 {
        const comment = (try message.Comment.read(h.repo.configuration())).text();
        const out = try message.cleanup(h.a, text, .strip, comment);
        if (out.len == 0) return error.EmptyMessage;
        return out;
    }

    const Made = struct {
        parents: []const Oid,
        tree: Oid,
        /// The commit's own message where `null`.
        message: ?[]const u8,
    };

    /// git's `commit_tree_ext`: the original's author, its message unless
    /// another is given, its headers but the encoding and signatures; never
    /// signed.
    fn commit(h: *History, original: Oid, made: Made) Error!Oid {
        const db = h.repo.objectDatabase();
        const found = try db.read(h.io, original);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        const source = try object.Commit.parse(h.a, h.repo.objectFormat(), try h.a.dupe(u8, found.bytes));
        var extra: std.ArrayList(object.ExtraHeader) = .empty;
        for (source.extra) |header| {
            if (std.mem.eql(u8, header.name, "gpgsig") or std.mem.eql(u8, header.name, "gpgsig-sha256")) continue;
            try extra.append(h.a, header);
        }
        return h.repo.writeCommit(h.io, .{
            .tree = made.tree,
            .parents = made.parents,
            .author = source.author,
            .committer = h.options.who,
            .message = made.message orelse source.message,
            .extra = extra.items,
            .signing = .{ .sign = .never },
        }, .{ .diagnostic = h.options.diagnostic });
    }

    /// git's `handle_reference_updates`: the descendants replayed onto the
    /// rewrite, then the refs on the original itself, all moved together.
    fn finish(h: *History, arena_state: *std.heap.ArenaAllocator, f: Finish) Error!Outcome {
        var hex: [hash.max_hex_len]u8 = undefined;
        const onto = try h.a.dupe(u8, f.rewritten.hex(&hex));
        var planned = try replay.plan(h.gpa, h.io, h.repo, .{
            .include = f.range.include,
            .exclude = f.range.exclude,
            .ancestry_path = f.range.exclude,
            .target = .{ .onto = .{ .revision = onto } },
        }, .{ .who = h.options.who, .empty = f.empty, .diagnostic = h.options.diagnostic });
        defer planned.deinit();
        var outcome: Outcome = .{ .arena = undefined, .gpa = h.gpa, .rewritten = f.rewritten, .updates = &.{}, .stopped = planned.stopped };
        if (planned.stopped == null) {
            var updates: std.ArrayList(replay.Update) = .empty;
            for (planned.updates) |u| try updates.append(h.a, .{ .ref = try h.a.dupe(u8, u.ref), .old = u.old, .new = u.new });
            try h.onOriginal(f, &updates);
            outcome.updates = try updates.toOwnedSlice(h.a);
            const move = if (f.moves_worktree) try h.headMove(outcome.updates) else null;
            // git's dry run first: a change in the way refuses it all.
            if (move) |m| try h.moveWorktree(m, true);
            if (!h.options.dry_run) {
                const log = try h.a.print("{s}: {s} {s}", .{ f.action, f.verb, f.name });
                try replay.updateRefs(h.io, h.repo, outcome.updates, .{ .who = h.options.who, .message = log, .hooks = h.options.hooks });
                outcome.updated = true;
                if (move) |m| try h.moveWorktree(m, false);
            }
        }
        outcome.arena = arena_state.state;
        return outcome;
    }

    const Move = struct { old: Oid, new: Oid };

    /// git's `find_head_tree_change`: the trees `HEAD` moves between when
    /// `updates` move what it names, `null` where it does not move to
    /// another tree, or there is no working tree.
    fn headMove(h: *History, updates: []const replay.Update) Error!?Move {
        if (h.repo.workDirectory() == null) return null;
        const head = (try h.repo.refStore().read(h.a, h.io, "HEAD")) orelse return null;
        const target = switch (head) {
            .symbolic => |name| name,
            else => "HEAD",
        };
        for (updates) |u| {
            if (!std.mem.eql(u8, u.ref, target)) continue;
            const old = try h.repo.commitTree(h.io, u.old);
            const new = try h.repo.commitTree(h.io, u.new);
            return if (old.eql(new)) null else .{ .old = old, .new = new };
        }
        return null;
    }

    /// The index and the working tree moved two ways between `move`'s
    /// trees, or with `check` only checked, nothing written.
    fn moveWorktree(h: *History, move: Move, check: bool) Error!void {
        var locked = try h.repo.lockIndex(h.io);
        defer locked.deinit(h.io);
        var moved = try three_way.fastForward(h.gpa, h.io, h.repo, .{ .index = &locked.index, .old = move.old, .new = move.new }, .{ .dry_run = check });
        defer moved.deinit();
        if (!check) try locked.commit(h.io);
    }

    /// The branches, and `HEAD` as `update_refs` has it, on the original:
    /// `replay` moves only what is on the commits it replays.
    fn onOriginal(h: *History, f: Finish, updates: *std.ArrayList(replay.Update)) Error!void {
        const head = try h.repo.refStore().read(h.a, h.io, "HEAD");
        const detached = if (head) |ref| ref != .symbolic else true;
        var decorations = try pretty.Decorations.load(h.gpa, h.io, h.repo, .{});
        defer decorations.deinit();
        var node = decorations.of(f.original);
        while (node) |d| : (node = d.next) {
            if (d.kind != .local and d.kind != .head) continue;
            switch (h.options.update_refs) {
                .head => if (d.kind != .head) continue,
                .branches => if (d.kind == .head and !detached) continue,
            }
            try updates.append(h.a, .{ .ref = try h.a.dupe(u8, d.name), .old = f.original, .new = f.rewritten });
        }
    }
};
