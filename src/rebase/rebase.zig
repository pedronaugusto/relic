//! Rebasing: replaying a branch's own commits on top of another commit,
//! `git rebase` with the merge backend, non-interactive or driven by an
//! instruction sheet the caller supplies.
//!
//! The commits to replay are git's: those on the branch and not upstream,
//! merges left out, oldest first in git's graph order, and a commit whose
//! patch id matches one upstream already has left out too, as git's
//! `--cherry-pick` walk leaves it out. They are replayed through git's
//! instruction sheet, and everything a rebase in progress keeps is kept
//! where git keeps it: `.git/rebase-merge/` with `git-rebase-todo`, `done`,
//! `head-name`, `onto`, `orig-head`, `msgnum`, `end`, `stopped-sha`,
//! `author-script`, `message`, `amend`, `rewritten-list` and the rest,
//! `REBASE_HEAD` and `ORIG_HEAD` beside it. So `git status` describes a
//! rebase this stopped, `git rebase --continue`, `--skip` and `--abort`
//! finish it, and a rebase git stopped is finished here. The reflog lines are
//! git's: `rebase (start): checkout <onto>`, `rebase (pick): <subject>`,
//! `rebase (finish): returning to <branch>`.
//!
//! There is no editor. An interactive rebase takes its sheet from the
//! caller, and a message a person would edit -- a `reword`, the combined
//! message of a `squash`, a commit made after a stop -- is offered to the
//! caller's `Messages`, and taken as git's editor would leave it untouched
//! when there is none. An `exec` line runs only through the `Programs` the
//! caller hands in. The commits a rebase rewrote come back as pairs, which is
//! what git hands its `post-rewrite` hook.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const state_file = @import("../repo/state.zig");
const shakedown = @import("shakedown");
const gitdate = @import("../text.zig").date;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const merge = @import("../merge/merge.zig");
const three_way = @import("../merge/three_way.zig");
const signing_mod = @import("../object/signing.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const commit_hooks_mod = @import("../commit/commit_hooks.zig");
const notes = @import("../commit/notes.zig");
const filter = @import("../checkout/filter.zig");
const strategy = @import("../merge/strategy.zig");
const reset = @import("../commit/reset.zig");
const head_mod = @import("../repo/head.zig");
const ref_names = @import("../names.zig").ref;
const message = @import("../object/message.zig");
const pretty = @import("../pretty/pretty.zig");
const trailer = @import("../object/trailer.zig");
const abbrev = @import("../odb/abbrev.zig");
const todo = @import("../commit/todo.zig");
const worktree = @import("../checkout/checkout.zig");
const merging = @import("../commit/merging.zig");
const stash = @import("../commit/stash.zig");
const sequencer = @import("../commit/sequencer.zig");
const patch_id = @import("../diff/patch_id.zig");
const rev_walk = @import("../walk/walk.zig");
const diff = @import("../diff/diff.zig");
const program = @import("../process.zig").program;
const repo_mod = @import("../repo/repo.zig");
const worktrees = @import("../checkout/worktrees.zig");
const rerere = @import("../merge/rerere.zig");
const diagnostic = @import("../report.zig").diagnostic;
const config_mod = @import("../config/config.zig");
const unicode_width = @import("../text.zig").unicode_width;
const rev_parse = @import("../rev_walk/rev_parse.zig");
const fork_point = @import("../rev_walk/fork_point.zig");
const am = @import("../patch/am.zig");
const format_patch = @import("../patch/format.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a rebase.
pub const Error = error{
    /// `author-script` holds a date git's `parse_date` does not read,
    /// which `git commit` dies on.
    InvalidDate,
    /// `merge.conflictStyle` is bare or names a style git does not know,
    /// which git dies on.
    InvalidConflictStyle,
    /// `core.commentChar` or `core.commentString` is one git dies on: no
    /// value, empty, or holding a line break.
    InvalidCommentString,
    /// `commit.cleanup` is bare or, where git dies on it, names no mode git
    /// knows.
    InvalidCleanupMode,
    /// `.git/rebase-merge` or `.git/rebase-apply` is there already.
    RebaseInProgress,
    /// There is no rebase to continue, skip or abort.
    NoRebaseInProgress,
    /// A merge, cherry-pick or revert is waiting to be concluded.
    OperationInProgress,
    /// The index or the working tree has changes; a rebase starts clean and
    /// continues without unstaged changes.
    DirtyWorktree,
    /// Something is staged at a stop that has no message to commit it with.
    StagedWithoutMessage,
    /// `HEAD` names a branch with no commit yet.
    UnbornBranch,
    /// The sheet ends up with nothing to do.
    NothingToDo,
    /// The sheet has an `exec` line and no `Programs` were handed in.
    ExecNotPermitted,
    /// A state file does not say what git writes there.
    MalformedState,
    /// A label or commit a `reset` or `merge` names does not resolve.
    UnknownLabel,
    /// `reset [new root]`, which git's `rebase -r --root` writes: a
    /// history replayed onto no commit, which this does not do.
    UnsupportedNewRoot,
    /// The rebase names a merge strategy other than `ort` or `recursive`.
    UnsupportedStrategy,
    /// The branch given does not name a branch or a commit.
    NotACommit,
    /// `rebase.rebaseMerges` is neither a boolean nor a mode git knows:
    /// "Unknown rebase-merges mode".
    InvalidRebaseMergesSetting,
    /// `rebase.backend` names neither `merge` nor `apply`: "Unknown rebase
    /// backend".
    UnknownRebaseBackend,
    /// The apply backend asked for with an option only the merge backend
    /// has: git's "<option> requires the merge backend", "apply options
    /// and merge options cannot be used together".
    RequiresMergeBackend,
    /// The apply backend asked for while `rebase.rebaseMerges` asks for the
    /// merges made again: "apply options are incompatible with
    /// rebase.rebaseMerges".
    ApplyWithRebaseMerges,
    /// The apply backend asked for while `rebase.updateRefs` asks for the
    /// other branches moved: "apply options are incompatible with
    /// rebase.updateRefs".
    ApplyWithUpdateRefs,
    /// `--continue` with changes in the working tree not staged, which
    /// the apply backend refuses: git's "You must edit all merge conflicts
    /// and then mark them as resolved using git add".
    UnstagedChanges,
    /// The commit is a merge; only `merge` and `drop` take one.
    MergeCommit,
    /// The message left after cleanup is empty.
    EmptyMessage,
} || sequencer.Error || merging.Error || program.Error || patch_id.Error || rev_walk.Error || worktrees.Error || notes.Error || rev_parse.Error || fork_point.Error || am.Error || format_patch.Error;

/// A message a person would be shown in an editor, and what they would
/// see.
pub const MessageKind = enum {
    /// A `reword`: the commit's message.
    reword,
    /// The combined message of a `squash` chain, or a `fixup -c`, with
    /// git's comments in it.
    squash,
    /// The message of a commit made after a stop, from what is staged.
    resolved,
    /// A `merge -c`: the original merge's message.
    merge,
};

/// Where the messages a person would edit go. `editFn` returns the message
/// to use, which is cleaned of comments as an edited one is, or `null` to
/// take the proposed one as an editor left untouched would.
pub const Messages = struct {
    context: *anyopaque,
    editFn: *const fn (context: *anyopaque, kind: MessageKind, proposed: []const u8) ?[]const u8,
};

/// What becomes of a commit that ends up changing nothing.
pub const Empty = enum {
    /// Leave it out, as a non-interactive rebase does.
    drop,
    /// Keep it.
    keep,
    /// Stop, as an interactive rebase does.
    stop,
};

/// How a rebase is made.
pub const Options = struct {
    /// Who commits, and when; also who the reflog lines are by. Replayed
    /// commits keep their authors.
    who: object.Signature,
    /// What to replay onto; `upstream` when `null`: `--onto`.
    onto: ?Oid = null,
    /// The name `onto` was given as, which the reflog quotes. The full
    /// object name when `null`.
    onto_name: ?[]const u8 = null,
    /// The branch to rebase, by its short name, in place of the current
    /// one: `git rebase <upstream> <branch>`.
    branch: ?[]const u8 = null,
    /// The upstream as it was given, which `pre-rebase` is told. The full
    /// object name when `null`.
    upstream_name: ?[]const u8 = null,
    /// The hooks to run, or `null` for none: `pre-rebase`, `post-checkout`
    /// when `onto` is checked out, `prepare-commit-msg` and `post-commit`
    /// around each commit, and `post-rewrite` at the end, as git runs them.
    hooks: ?*hooks_mod.Runner = null,
    /// `false` skips `pre-rebase`: `--no-verify`.
    verify: bool = true,
    /// Whether and how the commits are signed: `-S`, `-S<key>`,
    /// `--no-gpg-sign`, or `commit.gpgSign` by default, with the programs
    /// that sign. What was decided is kept between steps, as git keeps it.
    signing: signing_mod.Request = .{},
    /// Caller-owned output for a refused write or failed signing program.
    diagnostic: ?*repo_mod.Diagnostic = null,
    /// The sheet to work through in place of the one git would write: an
    /// interactive rebase, with the sheet a person would have left in the
    /// editor. `plan` gives the sheet to start from.
    todo: ?[]const u8 = null,
    /// `--interactive` with no sheet of its own: the generated sheet as it
    /// is, with an interactive rebase's defaults.
    interactive: bool = false,
    /// Move `fixup!`, `squash!` and `amend!` commits after their targets:
    /// `--autosquash`, `--no-autosquash`, or `rebase.autoSquash` for an
    /// interactive rebase (`interactive` or a sheet) when `null`.
    autosquash: ?bool = null,
    /// `--apply` or `--merge`. `null` is the merge backend where an option
    /// only it has is asked for (a sheet, `interactive`, `exec`,
    /// `autosquash`, `update_refs`, `empty`, `reapply_cherry_picks`,
    /// `strategy_options`, `keep_empty` off, merges made again), and
    /// `rebase.backend` otherwise. `.apply` with one of them is
    /// `RequiresMergeBackend`.
    backend: ?Backend = null,
    /// `--fork-point` or `--no-fork-point`: only the commits after the
    /// branch's fork point from the upstream (`rev_walk.fork_point`, by
    /// the reflog of the ref `upstream_name` names) are replayed, so a
    /// commit the upstream once had and dropped is not. `null` is git's
    /// default: on for a rebase onto the branch's own upstream
    /// (`default_upstream`), unless `rebase.forkPoint` is false.
    fork_point: ?bool = null,
    /// `upstream` is the branch's configured upstream, which
    /// `upstream_name` names, taken because no upstream was named: `git
    /// rebase` with no upstream.
    default_upstream: bool = false,
    /// `--rebase-merges[=<mode>]` or `--no-rebase-merges`; `null` takes
    /// `rebase.rebaseMerges`. The sheet then makes the merges again:
    /// `label`, `reset` and `merge` lines, as git writes them.
    rebase_merges: ?RebaseMerges = null,
    /// Add `update-ref` lines for the other branches that point at the
    /// replayed commits, so they move with them: `--update-refs`,
    /// `--no-update-refs`, or `rebase.updateRefs` when `null`.
    update_refs: ?bool = null,
    /// Keep commits that were empty to begin with.
    keep_empty: bool = true,
    /// What to do with one that becomes empty. `drop` for a
    /// non-interactive rebase and `stop` for an interactive one when
    /// `null`.
    empty: ?Empty = null,
    /// Replay commits already upstream too: `--reapply-cherry-picks`.
    reapply_cherry_picks: bool = false,
    /// Replay even commits that could be reused as they are:
    /// `--force-rebase`, `--no-ff`.
    force: bool = false,
    /// `--signoff`.
    signoff: bool = false,
    /// `-X`: the strategy options, in the order given, as
    /// `strategy.Settings.apply` reads them. Kept in `strategy_opts`
    /// between steps, with `strategy` naming ort as git's rebase does.
    strategy_options: []const []const u8 = &.{},
    /// The filter drivers and relic's own LFS the merged files go through,
    /// as `Repository.loadFilters` gives them: `three_way.Options.filters`.
    filters: ?*const filter.Drivers = null,
    /// `null` asks `merge.conflictStyle`.
    conflict_style: ?merge.ConflictStyle = null,
    /// `--exec`: commands to run after each commit.
    exec: []const []const u8 = &.{},
    /// Put a failed `exec` back on the sheet: `--reschedule-failed-exec`,
    /// `--no-reschedule-failed-exec`, or `rebase.rescheduleFailedExec`
    /// when `null`.
    reschedule_failed_exec: ?bool = null,
    /// Stage what a recorded resolution resolves: `--rerere-autoupdate`,
    /// `--no-rerere-autoupdate`, or `rerere.autoUpdate` when `null`.
    rerere_autoupdate: ?bool = null,
    /// The permission to run `exec` lines, and the filters' programs.
    programs: ?program.Programs = null,
    /// Where messages a person would edit go.
    messages: ?Messages = null,
    /// Where a refusal writes the path that caused it.
    blocked: ?*three_way.Blocked = null,
    /// The text the reflog lines begin with, before ` (start)`, ` (pick)`
    /// and the rest: git's `GIT_REFLOG_ACTION`, which `git pull` sets.
    /// `null` writes `rebase`. A rebase stopped and taken up again begins
    /// them with whatever that call is given, as a new git process does.
    reflog_action: ?[]const u8 = null,
    /// `--autostash`, `--no-autostash`, or `rebase.autoStash` when `null`:
    /// the changes in the index and the working tree are put aside in
    /// `rebase-merge/autostash` as the rebase starts, and brought back when
    /// it finishes, is aborted, or fails to begin. `Outcome.autostash` and
    /// `Outcome.restored`.
    autostash: ?bool = null,
};

/// Which of git's two ways a rebase replays the commits.
pub const Backend = enum {
    /// The sequencer, through an instruction sheet in `.git/rebase-merge`.
    merge,
    /// `--apply`: the commits written as `git format-patch` writes them
    /// and applied by `git am --rebasing`, in `.git/rebase-apply`.
    apply,

    fn dir(b: Backend) []const u8 {
        return switch (b) {
            .merge => "rebase-merge",
            .apply => "rebase-apply",
        };
    }
};

/// Whether the merges on the branch are made again, and where a branch
/// that did not leave from the branch's own commits goes.
pub const RebaseMerges = enum {
    /// The merges left out and their branches flattened.
    off,
    /// `no-rebase-cousins`: such a branch keeps the commit it left from.
    no_rebase_cousins,
    /// `rebase-cousins`: such a branch is moved onto `onto`.
    rebase_cousins,
};

/// Why a rebase stopped.
pub const Stop = enum {
    /// A pick conflicted; resolve, stage, and continue.
    conflict,
    /// An `edit` line: amend if you like, and continue.
    edit,
    /// A `break` line.
    @"break",
    /// An `exec` line failed, or left changes behind.
    exec_failed,
    /// A pick would change nothing and empty commits stop the rebase.
    empty,
    /// The sheet leaves out commits the rebase would replay, with no
    /// `drop` line for them, and `rebase.missingCommitsCheck` is `error`:
    /// nothing is applied. Correct `git-rebase-todo` and continue.
    missing_commits,
};

/// One rewritten commit: what `post-rewrite` is told.
pub const Rewritten = struct { old: Oid, new: Oid };

/// What a rebase did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    result: Result,
    /// Why it stopped, when it did.
    stopped: ?Stop = null,
    /// The commit it stopped at, when a commit was being applied.
    stopped_at: ?Oid = null,
    /// The `exec` line that failed, and how it exited.
    exec: ?[]const u8 = null,
    exec_status: u32 = 0,
    /// The paths left conflicted, sorted.
    conflicts: []const three_way.Conflict = &.{},
    /// When the rebase finished: every commit it rewrote and what it became.
    rewritten: []const Rewritten = &.{},
    /// The stash this start made of the changes in the rebase's way: git's
    /// "Created autostash".
    autostash: ?Oid = null,
    /// What became of the autostash when the rebase finished.
    restored: ?stash.Restored = null,

    pub const Result = enum {
        /// The branch already sat on the target; nothing was done.
        up_to_date,
        /// The rebase finished.
        done,
        /// It stopped; see `stopped`.
        stopped,
    };

    /// Release the outcome.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

//=========================================================================
// The state git keeps
//=========================================================================

/// Whether a rebase is waiting: `.git/rebase-merge` is there, or
/// `.git/rebase-apply` with no `git am` session in it.
pub fn inProgress(io: Io, repo: *Repository) bool {
    return backendInProgress(io, repo) != null;
}

/// The backend of the rebase that is waiting.
fn backendInProgress(io: Io, repo: *Repository) ?Backend {
    const dir = repo.gitDirectory();
    if (state_file.exists(io, dir, Backend.merge.dir())) return .merge;
    if (state_file.exists(io, dir, Backend.apply.dir()) and !state_file.exists(io, dir, "rebase-apply/applying")) return .apply;
    return null;
}

/// A running or resumed rebase: its options, its sheet, and where it is.
const Run = struct {
    gpa: Allocator,
    arena: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    io: Io,
    repo: *Repository,
    options: Options,
    comment: []const u8,
    /// How trailers are read, for `--signoff`.
    trailers: trailer.Settings,
    abbrev_len: usize,
    allow_ff: bool,
    empty: Empty,
    /// `rebase_merges`, or `rebase.rebaseMerges`, which is read and
    /// checked whichever decides, as git reads its configuration.
    merges: RebaseMerges,
    /// Whether the fork point limits the commits, `rebase.forkPoint`
    /// read the same way.
    fork_point: bool,
    /// The fork point found: git's `restrict_revision`.
    restrict: ?Oid = null,
    /// Which backend, and so which directory the state is in.
    backend: Backend = .merge,
    /// `autosquash`, `update_refs` and `reschedule_failed_exec`, or the
    /// settings behind them, which are read and checked whichever decides.
    autosquash: bool,
    update_refs: bool,
    reschedule_failed_exec: bool,
    /// What is left to do, the current instruction first.
    items: std.ArrayList(todo.Item) = .empty,
    done_nr: usize = 0,
    /// `current-fixups`: the fixups and squashes in the chain so far.
    fixups: std.ArrayList(u8) = .empty,
    fixup_count: usize = 0,
    /// The message being built for the current pick.
    msg: std.ArrayList(u8) = .empty,
    have_message: bool = false,
    conflicts: []const three_way.Conflict = &.{},
    /// The autostash this run made, and what became of one at its end.
    autostash: ?Oid = null,
    restored: ?stash.Restored = null,

    /// `name` in the backend's directory.
    fn statePath(r: *const Run, comptime name: []const u8) []const u8 {
        return switch (r.backend) {
            inline else => |b| comptime b.dir() ++ "/" ++ name,
        };
    }

    fn state(r: *Run, comptime name: []const u8, bytes: []const u8) Error!void {
        try state_file.write(r.io, r.repo.gitDirectory(), r.statePath(name), bytes);
    }

    fn readState(r: *Run, comptime name: []const u8) Error!?[]u8 {
        return state_file.read(r.arena, r.io, r.repo.gitDirectory(), r.statePath(name));
    }

    fn removeState(r: *Run, comptime name: []const u8) Error!void {
        try state_file.remove(r.io, r.repo.gitDirectory(), r.statePath(name));
    }

    fn hasState(r: *Run, comptime name: []const u8) bool {
        return state_file.exists(r.io, r.repo.gitDirectory(), r.statePath(name));
    }

    fn appendState(r: *Run, comptime name: []const u8, bytes: []const u8) Error!void {
        const old = (try r.readState(name)) orelse "";
        const joined = try std.mem.concat(r.arena, u8, &.{ old, bytes });
        try r.state(name, joined);
    }

    fn hex(r: *Run, oid: Oid) Error![]const u8 {
        var buf: [hash.max_hex_len]u8 = undefined;
        return r.arena.dupe(u8, oid.hex(&buf));
    }

    fn short(r: *Run, oid: Oid) Error![]const u8 {
        var buf: [hash.max_hex_len]u8 = undefined;
        return r.arena.dupe(u8, try abbrev.unique(r.io, r.repo.objectDatabase(), oid, r.abbrev_len, &buf));
    }

    fn head(r: *Run) Error!head_mod.Head {
        return head_mod.read(r.gpa, r.io, r.repo);
    }

    fn headOid(r: *Run) Error!Oid {
        var h = try r.head();
        defer h.deinit(r.gpa);
        return h.oid orelse error.UnbornBranch;
    }

    /// What the reflog lines begin with: git's `GIT_REFLOG_ACTION`.
    fn action(r: *const Run) []const u8 {
        return r.options.reflog_action orelse "rebase";
    }

    fn reflogMessage(r: *Run, sub: []const u8, tail: ?[]const u8) Error![]const u8 {
        if (tail) |t| return r.arena.print("{s} ({s}): {s}", .{ r.action(), sub, t });
        return r.arena.print("{s} ({s})", .{ r.action(), sub });
    }
};

fn newRun(gpa: Allocator, io: Io, arena_state: *std.heap.ArenaAllocator, repo: *Repository, options: Options) Error!Run {
    const interactive = options.interactive or options.todo != null;
    return .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .arena_state = arena_state,
        .io = io,
        .repo = repo,
        .options = options,
        .comment = (try message.Comment.read(repo.configuration())).text(),
        .trailers = try message.trailerSettings(arena_state.allocator(), repo.configuration()),
        .abbrev_len = abbrev.defaultLength(repo.configuration(), repo.objectDatabase()),
        .allow_ff = !options.force and !options.signoff,
        // git's default: stop interactively, keep with `--exec`, else drop.
        .empty = options.empty orelse if (interactive) .stop else if (options.exec.len != 0) .keep else .drop,
        .merges = blk: {
            const configured = try configuredRebaseMerges(repo.configuration());
            break :blk options.rebase_merges orelse configured;
        },
        .autosquash = blk: {
            const configured = try repo.configuration().getBool("rebase.autosquash", false);
            break :blk options.autosquash orelse (configured and interactive);
        },
        .update_refs = blk: {
            const configured = try repo.configuration().getBool("rebase.updaterefs", false);
            break :blk options.update_refs orelse configured;
        },
        .reschedule_failed_exec = blk: {
            const configured = try repo.configuration().getBool("rebase.reschedulefailedexec", false);
            break :blk options.reschedule_failed_exec orelse configured;
        },
        .fork_point = blk: {
            const configured = try repo.configuration().getBool("rebase.forkpoint", true);
            break :blk options.fork_point orelse (configured and options.default_upstream);
        },
    };
}

/// The outcome, which takes the run's arena over; the run is done with.
fn finishOutcome(r: *Run, result: Outcome.Result, stopped: ?Stop, at: ?Oid) Outcome {
    const state = r.arena_state.state;
    r.gpa.destroy(r.arena_state);
    return .{
        .gpa = r.gpa,
        .arena = state,
        .result = result,
        .stopped = stopped,
        .stopped_at = at,
        .conflicts = if (stopped == .conflict) r.conflicts else &.{},
        .autostash = r.autostash,
        .restored = r.restored,
    };
}

//=========================================================================
// Which commits
//=========================================================================

/// A commit read for the walk.
const Node = struct {
    oid: Oid,
    parents: []const Oid,
    time: i64,
    tree: Oid,
};

const Walker = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    repo: *Repository,
    nodes: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, Node) = .empty,

    fn load(w: *Walker, oid: Oid) Error!Node {
        if (w.nodes.get(oid.bytes)) |n| return n;
        const found = try w.repo.objectDatabase().read(w.io, oid);
        defer w.repo.objectDatabase().allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(w.gpa, w.repo.objectFormat(), found.bytes);
        defer commit.deinit();
        const node: Node = .{
            .oid = oid,
            .parents = try w.arena.dupe(Oid, commit.parents),
            .time = commit.committer.when_secs,
            .tree = commit.tree,
        };
        try w.nodes.put(w.arena, oid.bytes, node);
        return node;
    }
};

/// The commits on each side of `left...right`: reachable from one and not
/// from the other, in the order git's date-ordered walk meets them.
fn symmetricDifference(w: *Walker, left: Oid, right: Oid) Error!struct { left: []Oid, right: []Oid } {
    const Flags = packed struct { left: bool = false, right: bool = false, stale: bool = false };
    var flags: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, Flags) = .empty;
    const Queued = struct { oid: Oid, time: i64, order: u64 };
    const byDate = struct {
        fn cmp(_: void, a: Queued, b: Queued) std.math.Order {
            if (a.time != b.time) return std.math.order(b.time, a.time);
            return std.math.order(a.order, b.order);
        }
    }.cmp;
    var queue: std.PriorityQueue(Queued, void, byDate) = .empty;
    defer queue.deinit(w.gpa);
    var order: u64 = 0;
    try flags.put(w.arena, left.bytes, .{ .left = true });
    try queue.push(w.gpa, .{ .oid = left, .time = (try w.load(left)).time, .order = order });
    order += 1;
    const right_flags = flags.get(right.bytes) orelse Flags{};
    try flags.put(w.arena, right.bytes, .{ .left = right_flags.left, .right = true });
    try queue.push(w.gpa, .{ .oid = right, .time = (try w.load(right)).time, .order = order });
    order += 1;

    var lefts: std.ArrayList(Oid) = .empty;
    var rights: std.ArrayList(Oid) = .empty;
    var seen: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    while (true) {
        // Stop once only commits behind a common ancestor are left.
        var live = false;
        for (queue.items) |item| {
            if (!(flags.get(item.oid.bytes) orelse Flags{}).stale) live = true;
        }
        if (!live) break;
        const item = queue.pop().?;
        if ((try seen.getOrPut(w.arena, item.oid.bytes)).found_existing) continue;
        var f = flags.get(item.oid.bytes) orelse Flags{};
        if (f.left and f.right) f.stale = true;
        if (!f.stale) {
            if (f.left) try lefts.append(w.arena, item.oid) else if (f.right) try rights.append(w.arena, item.oid);
        }
        const node = try w.load(item.oid);
        for (node.parents) |parent| {
            const gop = try flags.getOrPut(w.arena, parent.bytes);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const before = gop.value_ptr.*;
            gop.value_ptr.left = before.left or f.left;
            gop.value_ptr.right = before.right or f.right;
            gop.value_ptr.stale = before.stale or f.stale;
            if (seen.contains(parent.bytes)) continue;
            try queue.push(w.gpa, .{ .oid = parent, .time = (try w.load(parent)).time, .order = order });
            order += 1;
        }
    }
    // A commit met on one side before the other side reached it is not on
    // that side after all.
    var final_left: std.ArrayList(Oid) = .empty;
    for (lefts.items) |oid| {
        const f = flags.get(oid.bytes).?;
        if (!f.right and !f.stale) try final_left.append(w.arena, oid);
    }
    var final_right: std.ArrayList(Oid) = .empty;
    for (rights.items) |oid| {
        const f = flags.get(oid.bytes).?;
        if (!f.left and !f.stale) try final_right.append(w.arena, oid);
    }
    return .{ .left = final_left.items, .right = final_right.items };
}

/// git's topological sort in graph order, then reversed: parents before
/// children, a branch's run kept together, the tips taken in the order the
/// walk met them.
fn graphOrderOldestFirst(w: *Walker, commits: []const Oid) Error![]Oid {
    var indegree: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, usize) = .empty;
    for (commits) |oid| try indegree.put(w.arena, oid.bytes, 1);
    for (commits) |oid| {
        for ((try w.load(oid)).parents) |parent| {
            if (indegree.getPtr(parent.bytes)) |d| {
                if (d.* != 0) d.* += 1;
            }
        }
    }
    // The tips, reversed: a stack pops the first one met first.
    var stack: std.ArrayList(Oid) = .empty;
    for (commits) |oid| {
        if (indegree.get(oid.bytes).? == 1) try stack.append(w.arena, oid);
    }
    std.mem.reverse(Oid, stack.items);
    var out: std.ArrayList(Oid) = .empty;
    while (stack.pop()) |oid| {
        for ((try w.load(oid)).parents) |parent| {
            const d = indegree.getPtr(parent.bytes) orelse continue;
            if (d.* == 0) continue;
            d.* -= 1;
            if (d.* == 1) try stack.append(w.arena, parent);
        }
        indegree.getPtr(oid.bytes).?.* = 0;
        try out.append(w.arena, oid);
    }
    std.mem.reverse(Oid, out.items);
    return out.items;
}

/// Whether a commit changes nothing against its first parent.
fn originallyEmpty(w: *Walker, oid: Oid) Error!bool {
    const node = try w.load(oid);
    const parent_tree = if (node.parents.len != 0) (try w.load(node.parents[0])).tree else try w.repo.objectDatabase().write(w.io, .tree, "");
    return parent_tree.eql(node.tree);
}

/// The sheet git writes for `upstream...orig_head`: `pick <name> # <subject>`
/// for each commit to replay, `# empty` after one that was empty to begin
/// with; with `--rebase-merges`, `make_script_with_merges`'s.
fn makeScript(r: *Run, upstream: Oid, orig_head: Oid) Error![]todo.Item {
    var w: Walker = .{ .gpa = r.gpa, .arena = r.arena, .io = r.io, .repo = r.repo };
    var sides = try symmetricDifference(&w, upstream, orig_head);
    if (r.restrict) |fork| sides.right = try leavingFrom(r, &w, sides.right, fork);
    const same = try upstreamHas(r, &w, sides.left, sides.right);
    const ordered = try graphOrderOldestFirst(&w, sides.right);
    if (r.merges != .off) return scriptWithMerges(r, &w, .{ .ordered = ordered, .same = &same, .upstream = upstream, .orig_head = orig_head, .cousins = r.merges == .rebase_cousins });

    var items: std.ArrayList(todo.Item) = .empty;
    for (ordered) |oid| {
        const node = try w.load(oid);
        if (node.parents.len > 1) continue;
        const empty = try originallyEmpty(&w, oid);
        if (!empty and same.contains(oid.bytes)) continue;
        if (empty and !r.options.keep_empty) continue;
        try items.append(r.arena, .{ .command = .pick, .commit = oid, .arg = try pickArg(r, oid, empty) });
    }
    return items.items;
}

/// The commits of `right` that `fork` does not reach: git's
/// `^<restrict_revision>`. What `fork` reaches of them is reached through
/// them alone, since none of them is the upstream's.
fn leavingFrom(r: *Run, w: *Walker, right: []Oid, fork: Oid) Error![]Oid {
    var on_side: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    for (right) |oid| try on_side.put(r.arena, oid.bytes, {});
    var reached: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(r.arena, fork);
    while (stack.pop()) |oid| {
        if (!on_side.contains(oid.bytes)) continue;
        if ((try reached.getOrPut(r.arena, oid.bytes)).found_existing) continue;
        try stack.appendSlice(r.arena, (try w.load(oid)).parents);
    }
    var kept: std.ArrayList(Oid) = .empty;
    for (right) |oid| if (!reached.contains(oid.bytes)) try kept.append(r.arena, oid);
    return kept.items;
}

/// git's `get_fork_point` of `upstream_name` and the branch, when the fork
/// point is asked for: `null` where the name is not one ref's, or no fork
/// point is found.
fn findForkPoint(r: *Run, orig_head: Oid) Error!?Oid {
    if (!r.fork_point) return null;
    const name = r.options.upstream_name orelse return null;
    const found = (try rev_parse.dwimRef(r.arena, r.io, r.repo, name)) orelse return null;
    if (found.count != 1) return null;
    return fork_point.forkPoint(r.gpa, r.io, r.repo, .{ .ref = found.ref, .commit = orig_head });
}

/// The commits of `right` whose patch id one of `left` has: what git's
/// `--cherry-mark` marks.
fn upstreamHas(r: *Run, w: *Walker, left: []const Oid, right: []const Oid) Error!std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) {
    var same: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    if (r.options.reapply_cherry_picks or left.len == 0 or right.len == 0) return same;
    // A file the attributes call binary is one by its names alone, as
    // git's patch ids take it.
    var attrs = try r.repo.loadAttrs(r.io);
    defer attrs.deinit();
    defer attrs.leave();
    const binary: diff.BinaryRule = .{ .attrs = &attrs, .work_dir = r.repo.workDirectory(), .config = r.repo.configuration() };
    var ids: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    for (left) |oid| {
        if ((try w.load(oid)).parents.len > 1) continue;
        const id = (try patch_id.ofCommit(r.gpa, r.io, r.repo.objectDatabase(), oid, binary)) orelse continue;
        try ids.put(r.arena, id.bytes, {});
    }
    for (right) |oid| {
        if ((try w.load(oid)).parents.len > 1) continue;
        const id = (try patch_id.ofCommit(r.gpa, r.io, r.repo.objectDatabase(), oid, binary)) orelse continue;
        if (ids.contains(id.bytes)) try same.put(r.arena, oid.bytes, {});
    }
    return same;
}

/// The line git's sheet gives a commit: `rebase.instructionFormat`'s
/// default, `# %s`, in the log's encoding; the `#` is git's own, whatever
/// the comment string.
fn sheetOneline(r: *Run, oid: Oid) Error![]const u8 {
    const config = r.repo.configuration();
    const set = config.get("rebase.instructionformat") orelse "";
    if (set.len == 0) {
        const commit = (try readIn(r, oid, try message.logOutputEncoding(config))).commit;
        return r.arena.print("# {s}", .{try message.onelineSubject(r.arena, commit.message)});
    }
    // `rebase.instructionFormat`, a `#` before it if it has none, with
    // git's sheet context: no abbreviation given, so `%h` is the full name.
    const format = if (set[0] == '#') set else try r.arena.print("# {s}", .{set});
    var out: std.ArrayList(u8) = .empty;
    try pretty.formatCommit(r.arena, r.io, .{ .db = r.repo.objectDatabase(), .oid = oid, .format = format }, &out, .{
        .output_encoding = try message.logOutputEncoding(config),
        .abbrev_len = r.repo.objectFormat().hexLen(),
    });
    return out.items;
}

/// A pick's line after its commit: the oneline, and `<comment> empty`
/// after a commit that was empty to begin with.
fn pickArg(r: *Run, oid: Oid, empty: bool) Error![]const u8 {
    const line = try sheetOneline(r, oid);
    if (!empty) return line;
    return r.arena.print("{s} {s} empty", .{ line, r.comment });
}

/// `rebase.rebaseMerges`: a boolean, or `rebase-cousins` or
/// `no-rebase-cousins`, the last setting deciding; another value is
/// refused wherever it is, as git dies on it reading its configuration.
fn configuredRebaseMerges(config: *const config_mod.Config) Error!RebaseMerges {
    var mode: RebaseMerges = .off;
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "rebase") or entry.subsection.len != 0) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, "rebasemerges")) continue;
        const value = entry.value orelse {
            mode = .no_rebase_cousins;
            continue;
        };
        if (config_mod.parseBool(value)) |on| {
            mode = if (on) .no_rebase_cousins else .off;
        } else |_| if (std.mem.eql(u8, value, "no-rebase-cousins")) {
            mode = .no_rebase_cousins;
        } else if (std.mem.eql(u8, value, "rebase-cousins")) {
            mode = .rebase_cousins;
        } else return error.InvalidRebaseMergesSetting;
    }
    return mode;
}

/// What `make_script_with_merges` works from.
const MergesScript = struct {
    /// The commits on the branch and not upstream, in the order git's
    /// walk gives them.
    ordered: []const Oid,
    /// The ones upstream has by patch id.
    same: *const std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void),
    upstream: Oid,
    orig_head: Oid,
    /// `rebase-cousins`.
    cousins: bool,
};

/// git's `label_state`: the label each commit has, and the labels taken.
const Labels = struct {
    r: *Run,
    by_commit: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, []const u8) = .empty,
    taken: std.StringHashMapUnmanaged(void) = .empty,
    /// `rebase.maxLabelLength`.
    max_len: i64,

    fn of(l: *const Labels, oid: Oid) ?[]const u8 {
        return l.by_commit.get(oid.bytes);
    }

    fn put(l: *Labels, oid: Oid, label: []const u8) Error!void {
        try l.taken.put(l.r.arena, label, {});
        try l.by_commit.put(l.r.arena, oid.bytes, label);
    }

    /// git's `label_oid`: the label `oid` has, or a new one made of
    /// `wanted` -- its letters and digits and UTF-8, the rest one dash
    /// between words, cut to the length -- and a number after it where it
    /// is taken, a full object name, or `#`. With no `wanted`, a commit
    /// that is not rebased, which has no label to make: its shortest
    /// unique name that no label is.
    fn make(l: *Labels, oid: Oid, wanted: ?[]const u8) Error![]const u8 {
        if (l.of(oid)) |label| return label;
        const r = l.r;
        var hex_buf: [hash.max_hex_len]u8 = undefined;
        const full = oid.hex(&hex_buf);
        var label: []const u8 = undefined;
        if (wanted) |text| {
            var buf: std.ArrayList(u8) = .empty;
            var is_utf8 = true;
            var i: usize = 0;
            while (i < text.len and @as(i64, @intCast(buf.items.len)) + 1 < l.max_len) : (i += 1) {
                const c = text[i];
                if (std.ascii.isAlphanumeric(c) or (!is_utf8 and c & 0x80 != 0)) {
                    try buf.append(r.arena, c);
                } else if (c & 0x80 != 0) {
                    if (unicode_width.decode(text[i..])) |char| {
                        if (@as(i64, @intCast(buf.items.len + char.len)) > l.max_len) break;
                        try buf.appendSlice(r.arena, text[i..][0..char.len]);
                        i += char.len - 1;
                    } else {
                        is_utf8 = false;
                        try buf.append(r.arena, c);
                    }
                } else if (buf.items.len != 0 and buf.items[buf.items.len - 1] != '-') {
                    // No dash first, and none twice.
                    try buf.append(r.arena, '-');
                }
            }
            if (buf.items.len == 0) try buf.print(r.arena, "rev-{s}", .{try r.short(oid)});
            label = buf.items;
            const hexlike = label.len == full.len and isHex(label);
            if (hexlike or std.mem.eql(u8, label, "#") or l.taken.contains(label)) {
                var n: usize = 2;
                while (true) : (n += 1) {
                    const numbered = try r.arena.print("{s}-{d}", .{ label, n });
                    if (!l.taken.contains(numbered)) {
                        label = numbered;
                        break;
                    }
                }
            }
        } else {
            label = try r.short(oid);
            if (l.taken.contains(label)) {
                var len = label.len + 1;
                while (len < full.len and l.taken.contains(full[0..len])) len += 1;
                label = try r.arena.dupe(u8, full[0..len]);
            }
        }
        try l.put(oid, label);
        return label;
    }
};

fn isHex(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// git's `make_script_with_merges`: each run of commits on the branch,
/// from a branch's tip back to where it leaves the branch's other runs,
/// written after a `reset` to where it starts and given `label`s where
/// another run starts from it or a merge takes it in; a merge made again
/// by `merge -C <commit>` with the labels of the tips it merges.
fn scriptWithMerges(r: *Run, w: *Walker, s: MergesScript) Error![]todo.Item {
    const a = r.arena;
    var labels: Labels = .{ .r = r, .max_len = try r.repo.configuration().getInt("rebase.maxlabellength", 255 - ".lock".len - 16) };
    // The merge base, where the walk's range begins, is `onto`.
    {
        const bases = try rev_walk.mergeBases(r.gpa, r.io, r.repo.objectDatabase(), .{ .a = s.upstream, .b = s.orig_head }, .{});
        defer r.gpa.free(bases);
        if (bases.len != 0) try labels.put(bases[0], "onto");
    }
    var branches = try pretty.Decorations.load(r.gpa, r.io, r.repo, &.{ .include = &.{"refs/heads/"} });
    defer branches.deinit();

    var interesting: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    var to_do: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, todo.Item) = .empty;
    var tips: std.ArrayList(Oid) = .empty;
    // First: each commit's line, and a label for each branch a merge takes
    // in.
    for (s.ordered) |oid| {
        try interesting.put(a, oid.bytes, {});
        const empty = try originallyEmpty(w, oid);
        if (!empty and s.same.contains(oid.bytes)) continue;
        if (empty and !r.options.keep_empty) continue;
        const node = try w.load(oid);
        if (node.parents.len < 2) {
            try to_do.put(a, oid.bytes, .{ .command = .pick, .commit = oid, .arg = try pickArg(r, oid, empty) });
            continue;
        }
        const line = try sheetOneline(r, oid);
        const from_message = mergedName(line);
        var arg: std.ArrayList(u8) = .empty;
        for (node.parents[1..]) |parent| {
            if (arg.items.len != 0) try arg.append(a, ' ');
            if (!interesting.contains(parent.bytes)) {
                try arg.appendSlice(a, try labels.make(parent, null));
                continue;
            }
            try tips.append(a, parent);
            // The branch at the tip, by its newest name, as git's first
            // decoration; a graft's is no branch.
            var wanted = from_message;
            if (branches.of(parent)) |d| if (std.mem.startsWith(u8, d.name, "refs/heads/")) {
                wanted = d.name["refs/heads/".len..];
            };
            try arg.appendSlice(a, try labels.make(parent, wanted));
        }
        try arg.print(a, " {s}", .{line});
        try to_do.put(a, oid.bytes, .{ .command = .merge, .commit = oid, .arg = arg.items });
    }

    // Second: a label where a second child leaves a commit, and the
    // branch's own tip last among the tips.
    var child_seen: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    for (s.ordered, 0..) |oid, i| {
        for ((try w.load(oid)).parents) |parent| {
            if (!interesting.contains(parent.bytes)) continue;
            if ((try child_seen.getOrPut(a, parent.bytes)).found_existing) _ = try labels.make(parent, "branch-point");
        }
        if (i == s.ordered.len - 1) try tips.append(a, oid);
    }

    // Third: from each tip back along first parents to a commit written
    // already or not rebased, then forwards from there.
    var items: std.ArrayList(todo.Item) = .empty;
    var shown: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    try items.append(a, .{ .command = .label, .arg = "onto" });
    for (tips.items) |tip| {
        if (shown.contains(tip.bytes)) continue;
        try items.append(a, .{ .command = .comment, .arg = "" });
        if (labels.of(tip)) |label| try items.append(a, .{ .command = .comment, .arg = try a.print("{s} Branch {s}", .{ r.comment, label }) });
        var run: std.ArrayList(Oid) = .empty;
        var at: ?Oid = tip;
        while (at) |oid| {
            if (!interesting.contains(oid.bytes) or shown.contains(oid.bytes)) break;
            try run.append(a, oid);
            const parents = (try w.load(oid)).parents;
            at = if (parents.len == 0) null else parents[0];
        }
        try items.append(a, try resetTo(r, &labels, at, s.cousins));
        var i = run.items.len;
        while (i > 0) {
            i -= 1;
            const oid = run.items[i];
            if (to_do.get(oid.bytes)) |item| try items.append(a, item);
            if (labels.of(oid)) |label| try items.append(a, .{ .command = .label, .arg = label });
            try shown.put(a, oid.bytes, {});
        }
    }
    return items.items;
}

/// Where a run of commits starts: `reset onto`, `reset [new root]` for a
/// run from a root commit, or the label of the commit it leaves from, with
/// its oneline. A commit not rebased is reset to by its own name, or, with
/// `rebase-cousins`, the run is moved to `onto`.
fn resetTo(r: *Run, labels: *Labels, from: ?Oid, cousins: bool) Error!todo.Item {
    const oid = from orelse return .{ .command = .reset, .arg = if (cousins) "onto" else "[new root]" };
    const to = labels.of(oid) orelse if (cousins) null else try labels.make(oid, null);
    if (to == null or std.mem.eql(u8, to.?, "onto")) return .{ .command = .reset, .arg = "onto" };
    return .{ .command = .reset, .arg = try r.arena.print("{s} {s}", .{ to.?, try sheetOneline(r, oid) }) };
}

/// The branch a merge's oneline names, which labels the tips it merged
/// when no branch does: `# Merge ... '<branch>'...`, `# Merge pull request
/// ... from <branch>`, or the whole oneline.
fn mergedName(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "# Merge ")) {
        const rest = line["# Merge ".len..];
        if (std.mem.findScalar(u8, rest, '\'')) |open| {
            if (std.mem.findScalar(u8, rest[open + 1 ..], '\'')) |close| return rest[open + 1 ..][0..close];
        }
    }
    if (std.mem.startsWith(u8, line, "# Merge pull request ")) {
        if (std.mem.find(u8, line["# Merge pull request ".len..], " from ")) |at| return line["# Merge pull request ".len + at + " from ".len ..];
    }
    return line;
}

//=========================================================================
// Autosquash and exec
//=========================================================================

/// `todo_list_rearrange_squash`: each `fixup!`, `squash!` and `amend!`
/// commit moved after the commit its subject names, and turned into the
/// instruction its prefix asks for.
fn rearrangeSquash(r: *Run, items: []todo.Item) Error![]todo.Item {
    const n = items.len;
    const next = try r.arena.alloc(?usize, n);
    const tail = try r.arena.alloc(?usize, n);
    const subjects = try r.arena.alloc(?[]const u8, n);
    var by_subject: std.StringHashMapUnmanaged(usize) = .empty;
    var by_commit: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, usize) = .empty;
    var rearranged = false;
    for (items, 0..) |*item, i| {
        next[i] = null;
        tail[i] = null;
        subjects[i] = null;
        const commit_oid = item.commit orelse continue;
        if (item.command == .drop) continue;
        if (item.command.isFixup()) return items;
        // git matches the subjects in UTF-8
        const commit = (try readIn(r, commit_oid, "UTF-8")).commit;
        const subject = try message.onelineSubject(r.arena, message.fromSubject(commit.message));
        subjects[i] = subject;
        var target: ?usize = null;
        if (skipFixupish(subject)) |first| {
            var p = first;
            while (true) {
                p = std.mem.trimStart(u8, p, " \t\n\r");
                p = skipFixupish(p) orelse break;
            }
            if (by_subject.get(p)) |at| {
                target = at;
            } else if (std.mem.findScalar(u8, p, ' ') == null) found_name: {
                var context: sequencer.ResolverContext = .{ .repo = r.repo, .io = r.io };
                const resolved = context.resolver().resolveFn(&context, p) orelse break :found_name;
                if (by_commit.get(resolved.oid.bytes)) |at| target = at;
            }
            if (target == null) {
                for (0..i) |j| {
                    if (subjects[j]) |s| {
                        if (std.mem.startsWith(u8, s, p)) {
                            target = j;
                            break;
                        }
                    }
                }
            }
        }
        if (target) |at| {
            rearranged = true;
            if (std.mem.startsWith(u8, subject, "fixup!")) {
                item.command = .fixup;
            } else if (std.mem.startsWith(u8, subject, "amend!")) {
                item.command = .fixup;
                item.replace_message = true;
            } else {
                item.command = .squash;
            }
            if (tail[at]) |t| {
                next[i] = next[t];
                next[t] = i;
            } else {
                next[i] = next[at];
                next[at] = i;
            }
            tail[at] = i;
        } else if (!by_subject.contains(subject)) {
            try by_subject.put(r.arena, subject, i);
        }
        try by_commit.put(r.arena, commit_oid.bytes, i);
    }
    if (!rearranged) return items;
    var out: std.ArrayList(todo.Item) = .empty;
    for (items, 0..) |item, i| {
        if (item.command.isFixup()) continue;
        var cur: ?usize = i;
        while (cur) |c| : (cur = next[c]) try out.append(r.arena, items[c]);
    }
    return out.items;
}

/// The subject after a `fixup!`, `squash!` or `amend!` prefix, or `null`.
fn skipFixupish(subject: []const u8) ?[]const u8 {
    for ([_][]const u8{ "fixup!", "amend!", "squash!" }) |prefix| {
        if (std.mem.startsWith(u8, subject, prefix)) return subject[prefix.len..];
    }
    return null;
}

/// `todo_list_add_exec_commands`: the commands after every `pick` or
/// `merge` and the fixups that follow it.
fn addExecCommands(r: *Run, items: []todo.Item, commands: []const []const u8) Error![]todo.Item {
    if (commands.len == 0) return items;
    var out: std.ArrayList(todo.Item) = .empty;
    var insert = false;
    for (items) |item| {
        if (insert and !item.command.isFixup()) {
            for (commands) |c| try out.append(r.arena, .{ .command = .exec, .arg = c });
            insert = false;
        }
        try out.append(r.arena, item);
        if (item.command == .pick or item.command == .merge) insert = true;
    }
    if (insert) {
        for (commands) |c| try out.append(r.arena, .{ .command = .exec, .arg = c });
    }
    return out.items;
}

//=========================================================================
// Starting
//=========================================================================

/// Where the rebase starts from: the branch and the commit it names.
const Tip = struct {
    /// `refs/heads/<name>`, or `null` for a detached rebase.
    head_name: ?[]const u8,
    orig_head: Oid,
};

fn resolveTip(r: *Run) Error!Tip {
    if (r.options.branch) |name| {
        const full = try r.arena.print("refs/heads/{s}", .{name});
        if (try r.repo.refStore().resolve(r.gpa, r.io, full)) |resolved| {
            defer r.gpa.free(resolved.name);
            return .{ .head_name = full, .orig_head = resolved.oid };
        }
        var context: sequencer.ResolverContext = .{ .repo = r.repo, .io = r.io };
        const found = context.resolver().resolveFn(&context, name) orelse return error.NotACommit;
        return .{ .head_name = null, .orig_head = found.oid };
    }
    var h = try r.head();
    defer h.deinit(r.gpa);
    return .{
        .head_name = if (h.branch) |b| try r.arena.dupe(u8, b) else null,
        .orig_head = h.oid orelse return error.UnbornBranch,
    };
}

/// Whether the index and the working tree are exactly `HEAD`'s, untracked
/// files aside: `require_clean_work_tree`.
fn requireClean(r: *Run) Error!void {
    return requireCleanWorkTree(r.gpa, r.io, r.repo, r.options.blocked);
}

/// git's `require_clean_work_tree` as a rebase asks it, and `git pull`
/// before it fetches: nothing staged against `HEAD` and nothing changed
/// in the working tree, untracked files aside. `error.DirtyWorktree`
/// otherwise, the first such path in `blocked`.
pub fn requireCleanWorkTree(gpa: Allocator, io: Io, repo: *Repository, blocked: ?*three_way.Blocked) Self.Error!void {
    var index = try repo.openIndex(io);
    defer index.deinit();
    const wt = repo.workDirectory() orelse return error.BareRepository;
    var rules = try repo.worktreeRules();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    const head_tree = try repo.headTree(io);
    var status = try worktree.status(gpa, io, wt, .{ .index = &index, .db = repo.objectDatabase() }, .{
        .rules = rules,
        .head_tree = head_tree,
        .untracked = .no,
    });
    defer status.deinit();
    if (!status.isClean()) {
        if (blocked) |b| b.set(status.entries[0].path);
        return error.DirtyWorktree;
    }
}

/// The sheet a rebase of the current branch onto `upstream` would work
/// through, as git gives it to a person to edit: short object names, the
/// subjects after them, and git's help below. Edit it and hand it back as
/// `Options.todo`. The result is the caller's.
pub fn plan(gpa: Allocator, io: Io, repo: *Repository, upstream: Oid, options: Options) Self.Error![]u8 {
    diagnostic.reset(options.diagnostic);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r = try newRun(gpa, io, &arena_state, repo, options);
    const tip = try resolveTip(&r);
    r.restrict = try findForkPoint(&r, tip.orig_head);
    var items = try makeScript(&r, upstream, tip.orig_head);
    if (items.len == 0) {
        const noop = try r.arena.alloc(todo.Item, 1);
        noop[0] = .{ .command = .noop };
        items = noop;
    }
    if (r.update_refs) items = try addUpdateRefCommands(&r, items, false);
    if (r.autosquash) items = try rearrangeSquash(&r, items);
    items = try addExecCommands(&r, items, options.exec);
    const onto = options.onto orelse upstream;
    return sheetText(&r, gpa, items, upstream, onto, tip.orig_head, true);
}

/// The sheet as git writes it for a person: the instructions and the
/// help. `short` shortens the object names.
fn sheetText(r: *Run, gpa: Allocator, items: []const todo.Item, upstream: Oid, onto: Oid, orig_head: Oid, short: bool) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const Shorten = struct {
        fn shorten(context: *anyopaque, oid: Oid, buf: *[hash.max_hex_len]u8) []const u8 {
            const run: *Run = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Run
            return abbrev.unique(run.io, run.repo.objectDatabase(), oid, run.abbrev_len, buf) catch oid.hex(buf);
        }
    };
    todo.format(&out.writer, items, .{
        .short = if (short) .{ .context = r, .shortenFn = Shorten.shorten } else null,
        .abbreviate_commands = r.repo.configuration().getBool("rebase.abbreviatecommands", false) catch false,
    }) catch return error.OutOfMemory;
    var count: usize = 0;
    for (items) |item| {
        if (item.command != .comment) count += 1;
    }
    const revisions = try r.arena.print("{s}..{s}", .{ try r.short(upstream), try r.short(orig_head) });
    var sheet = out.toArrayList();
    errdefer sheet.deinit(gpa);
    const check = r.repo.configuration().get("rebase.missingcommitscheck") orelse "";
    try todo.appendHelp(gpa, &sheet, .{
        .command_count = count,
        .revisions = revisions,
        .onto = try r.short(onto),
        .comment = r.comment,
        .missing_commits_error = std.ascii.eqlIgnoreCase(check, "error"),
    });
    return sheet.toOwnedSlice(gpa);
}

/// Rebase the current branch, or `options.branch`, onto `upstream` (or
/// `options.onto`).
pub fn start(gpa: Allocator, io: Io, repo: *Repository, upstream: Oid, options: Options) Self.Error!Outcome {
    diagnostic.reset(options.diagnostic);
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    arena_state.* = .init(gpa);
    errdefer {
        arena_state.deinit();
        gpa.destroy(arena_state);
    }
    var r = try newRun(gpa, io, arena_state, repo, options);
    // `git_rebase_config` reads `rebase.autoStash` with `git_config_bool`,
    // which dies on a value that is no boolean, asked for or not.
    const configured_autostash = try repo.configuration().getBool("rebase.autostash", false);

    if (inProgress(io, repo) or state_file.exists(io, repo.gitDirectory(), Backend.apply.dir())) return error.RebaseInProgress;
    r.backend = try backendOf(&r);
    if (merging.inProgress(io, repo) or sequencer.inProgress(io, repo) != null) return error.OperationInProgress;
    if (options.exec.len != 0 and options.programs == null) return error.ExecNotPermitted;

    const tip = try resolveTip(&r);
    const onto = options.onto orelse upstream;
    const onto_name = options.onto_name orelse try r.hex(onto);
    if (options.autostash orelse configured_autostash) {
        r.autostash = try stash.createAutostash(io, repo, autostashPlace(&r), .{ .who = options.who, .filters = options.filters, .programs = options.programs });
    }
    if (r.backend == .apply) return startApply(&r, upstream, tip, onto, onto_name) catch |err| {
        _ = try restoreAutostash(&r, true);
        try removeState(&r);
        return err;
    };
    const begun = begin(&r, upstream, tip, onto, onto_name) catch |err| {
        // git's `cleanup_autostash`: a rebase that does not begin gives the
        // work back, and leaves no state.
        _ = try restoreAutostash(&r, true);
        try removeState(&r);
        return err;
    };
    if (begun == .missing_commits) return finishOutcome(&r, .stopped, .missing_commits, null);
    if (begun == .up_to_date) {
        // `finish_rebase`, with nothing to finish.
        try repo.refStore().root().delete(repo.allocator(), io, .rebase_head);
        try repo.refStore().root().delete(repo.allocator(), io, .auto_merge);
        r.restored = try restoreAutostash(&r, true);
        try removeState(&r);
        return finishOutcome(&r, .up_to_date, null, null);
    }
    return runLoop(&r);
}

/// Where a rebase keeps its autostash: its backend's directory.
fn autostashPlace(r: *const Run) stash.Autostash {
    return .{ .file = r.statePath("autostash") };
}

/// Bring back the autostash, applied or, without `apply`, only put on the
/// stash list.
fn restoreAutostash(r: *Run, apply: bool) Error!?stash.Restored {
    return stash.restoreAutostash(r.io, r.repo, autostashPlace(r), .{
        .who = r.options.who,
        .apply = apply,
        .hooks = r.options.hooks,
        .filters = r.options.filters,
        .programs = r.options.programs,
    });
}

/// What every rebase does before its backend's own work: the working tree
/// must be clean, the fork point is found, a branch already on top of
/// `onto` in a straight line is up to date (`false`, the branch named to
/// rebase switched to), and `pre-rebase` may refuse.
fn prepare(r: *Run, upstream: Oid, tip: Tip, onto: Oid) Error!bool {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    const options = r.options;
    try requireClean(r);
    r.restrict = try findForkPoint(r, tip.orig_head);

    // Already on top of `onto`, with a straight line from it: nothing to do.
    const branch_base = blk: {
        const bases = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = onto, .b = tip.orig_head }, .{});
        defer gpa.free(bases);
        break :blk if (bases.len == 1) bases[0] else null;
    };
    const preemptive = !options.interactive and options.todo == null and options.exec.len == 0 and
        !r.autosquash and !options.force;
    if (preemptive and branch_base != null and branch_base.?.eql(onto)) up_to_date: {
        if (r.restrict) |fork| if (!fork.eql(onto)) break :up_to_date;
        const bases = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = upstream, .b = tip.orig_head }, .{});
        defer gpa.free(bases);
        if (bases.len != 1 or !bases[0].eql(onto)) break :up_to_date;
        if (!try isLinear(r, onto, tip.orig_head)) break :up_to_date;
        if (options.branch) |name| {
            // Switch to the branch, as git does before it says so.
            try checkoutTip(r, tip, name);
        }
        return false;
    }

    // `pre-rebase` may refuse, before anything is written.
    if (options.hooks) |runner| {
        if (options.verify) _ = try runner.preRebase(io, options.upstream_name orelse try r.hex(upstream), options.branch);
    }

    return true;
}

/// Everything a rebase does before its first instruction: the sheet
/// written and `onto` checked out, detached. `false` when the branch
/// already sits on `onto` and there is nothing to do, the branch named to
/// rebase switched to.
/// How a rebase's start went.
const Begun = enum { up_to_date, begun, missing_commits };

fn begin(r: *Run, upstream: Oid, tip: Tip, onto: Oid, onto_name: []const u8) Error!Begun {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    const options = r.options;
    if (!try prepare(r, upstream, tip, onto)) return .up_to_date;

    // git's `do_interactive_rebase` reads the sequencer's settings first.
    try sequencer.initConfig(repo);
    // The sheet.
    var items: []todo.Item = try makeScript(r, upstream, tip.orig_head);
    try repo.gitDirectory().createDirPath(io, Backend.merge.dir());
    try r.state("interactive", "");
    try writeBasicState(r, tip, onto);
    if (items.len == 0) {
        const noop = try r.arena.alloc(todo.Item, 1);
        noop[0] = .{ .command = .noop };
        items = noop;
    }
    if (r.update_refs) items = try addUpdateRefCommands(r, items, true);
    if (r.autosquash) items = try rearrangeSquash(r, items);
    items = try addExecCommands(r, items, options.exec);
    if (countCommands(items) == 0) return error.NothingToDo;
    // What a person would be given, and a backup of it.
    const shown = try sheetText(r, gpa, items, upstream, onto, tip.orig_head, true);
    defer gpa.free(shown);
    try r.state("git-rebase-todo", shown);
    const backup = try sheetText(r, gpa, items, upstream, onto, tip.orig_head, false);
    defer gpa.free(backup);
    try r.state("git-rebase-todo.backup", backup);

    // What they left: the caller's sheet, or the one written.
    const sheet = try message.stripSpace(r.arena, options.todo orelse shown, r.comment);
    if (sheet.len == 0) return error.NothingToDo;
    var context: sequencer.ResolverContext = .{ .repo = repo, .io = io };
    const list = try todo.parse(r.arena, sheet, context.resolver(), .{ .comment = r.comment, .rebase = true });
    if (options.todo) |left| if (try missingCommits(r, items, list.items.items)) {
        // `edit_todo_list`'s refusal: the sheet as it was left, `dropped`
        // marking it, and `onto` checked out for it to be corrected.
        try r.state("git-rebase-todo", left);
        try r.state("dropped", "");
        try checkoutOnto(r, onto, tip.orig_head, onto_name);
        return .missing_commits;
    };
    try r.items.appendSlice(r.arena, list.items.items);
    // The refs to move follow the sheet as it was left.
    try filterUpdateRefs(r);
    // A sheet that runs a program is refused before anything moves, not
    // halfway through it.
    if (options.programs == null) {
        for (r.items.items) |item| {
            if (item.command == .exec) return error.ExecNotPermitted;
        }
    }

    // Full names from here on, and the picks that can stay as they are
    // taken off the front.
    var base = onto;
    if (r.allow_ff) base = try skipUnnecessaryPicks(r, base);
    try saveTodo(r, 0);
    try r.state("end", try r.arena.print("{d}\n", .{r.done_nr + countCommands(r.items.items)}));

    // Detach at `onto`.
    try checkoutOnto(r, base, tip.orig_head, onto_name);
    return .begun;
}

/// git's `todo_list_check` under `rebase.missingCommitsCheck=error`:
/// whether a commit of `old` is in no line of `new`. `warn` and `ignore`,
/// and a value git does not know, which it ignores with a warning, let
/// the sheet stand.
fn missingCommits(r: *Run, old: []const todo.Item, new: []const todo.Item) Error!bool {
    const level = r.repo.configuration().get("rebase.missingcommitscheck") orelse return false;
    if (!std.ascii.eqlIgnoreCase(level, "error")) return false;
    var seen: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    for (new) |item| if (item.commit) |oid| try seen.put(r.arena, oid.bytes, {});
    for (old) |item| if (item.commit) |oid| if (!seen.contains(oid.bytes)) return true;
    return false;
}

fn isLinear(r: *Run, from: Oid, to: Oid) Error!bool {
    var at = to;
    var w: Walker = .{ .gpa = r.gpa, .arena = r.arena, .io = r.io, .repo = r.repo };
    while (!at.eql(from)) {
        const node = try w.load(at);
        if (node.parents.len != 1) return false;
        at = node.parents[0];
    }
    return true;
}

fn countCommands(items: []const todo.Item) usize {
    var n: usize = 0;
    for (items) |item| {
        if (item.command != .comment) n += 1;
    }
    return n;
}

/// `write_basic_state`, and the files the sequencer adds to it.
fn writeBasicState(r: *Run, tip: Tip, onto: Oid) Error!void {
    try r.state("head-name", try r.arena.print("{s}\n", .{tip.head_name orelse "detached HEAD"}));
    try r.state("onto", try r.arena.print("{s}\n", .{try r.hex(onto)}));
    try r.state("orig-head", try r.arena.print("{s}\n", .{try r.hex(tip.orig_head)}));
    if (r.options.strategy_options.len != 0) {
        try r.state("strategy", "ort\n");
        const line = try strategy.quote(r.arena, r.options.strategy_options);
        try r.state("strategy_opts", try r.arena.print("{s}\n", .{line}));
    }
    if (r.options.signoff) try r.state("signoff", "--signoff\n");
    // The signing decided on, as git's rebase records it: `-S` and the key.
    if (try sequencer.signs(r.repo, r.options.signing)) {
        try r.state("gpg_sign_opt", try r.arena.print("-S{s}\n", .{r.options.signing.key orelse ""}));
    }
    switch (r.empty) {
        .drop => try r.state("drop_redundant_commits", ""),
        .keep => try r.state("keep_redundant_commits", ""),
        .stop => {},
    }
    if (r.reschedule_failed_exec) {
        try r.state("reschedule-failed-exec", "");
    } else try r.state("no-reschedule-failed-exec", "");
    if (r.options.rerere_autoupdate) |on| {
        try r.state("allow_rerere_autoupdate", if (on) "--rerere-autoupdate\n" else "--no-rerere-autoupdate\n");
    }
}

/// Read back what `writeBasicState` wrote, whoever wrote it, as git's
/// `read_basic_state` and `read_populate_opts` read it: each one-line file
/// as `read_oneliner` takes it, the names as `get_oid_hex` reads them, a
/// value either does not know passed over as git passes it over.
fn readBasicState(r: *Run) Error!Tip {
    const head_name = state_file.oneliner((try r.readState("head-name")) orelse return error.MalformedState);
    // git always writes `orig-head`; an older one wrote `head`.
    const orig = (try r.readState("orig-head")) orelse (try r.readState("head")) orelse return error.MalformedState;
    if (r.hasState("signoff")) {
        r.options.signoff = true;
        r.allow_ff = false;
    }
    if (r.hasState("drop_redundant_commits")) r.empty = .drop else if (r.hasState("keep_redundant_commits")) r.empty = .keep else r.empty = .stop;
    r.reschedule_failed_exec = r.hasState("reschedule-failed-exec");
    if (try r.readState("allow_rerere_autoupdate")) |text| {
        const value = state_file.oneliner(text);
        if (std.mem.eql(u8, value, "--rerere-autoupdate")) r.options.rerere_autoupdate = true else if (std.mem.eql(u8, value, "--no-rerere-autoupdate")) r.options.rerere_autoupdate = false;
    }
    // git reads the strategy options only when a strategy is named.
    if (try r.readState("strategy")) |text| {
        const s = state_file.oneliner(text);
        if (s.len != 0) {
            if (!std.mem.eql(u8, s, "ort") and !std.mem.eql(u8, s, "recursive")) return error.UnsupportedStrategy;
            if (try r.readState("strategy_opts")) |line| {
                const words = strategy.split(r.arena, state_file.oneliner(line)) catch |err| switch (err) {
                    error.MalformedStrategyOptions => return error.MalformedState,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                r.options.strategy_options = try std.mem.concat(r.arena, []const u8, &.{ r.options.strategy_options, words });
            }
        }
    }
    // `-S<key>` signs with the key, or the default one; anything else is
    // passed over, leaving `commit.gpgSign` to decide.
    if (try r.readState("gpg_sign_opt")) |text| {
        const line = state_file.oneliner(text);
        if (std.mem.startsWith(u8, line, "-S")) {
            r.options.signing.sign = .always;
            r.options.signing.key = if (line.len == 2) null else try r.arena.dupe(u8, line[2..]);
        }
    }
    // `current_fixup_count`: one, and one more for each line after a
    // newline that is not itself empty, older gits having left blank
    // lines for skipped fixups.
    if (try r.readState("current-fixups")) |raw| {
        const text = state_file.oneliner(raw);
        try r.fixups.appendSlice(r.arena, text);
        if (text.len != 0) {
            r.fixup_count = 1;
            for (text, 0..) |c, i| {
                if (c == '\n' and i + 1 < text.len and text[i + 1] != '\n') r.fixup_count += 1;
            }
        }
    }
    return .{
        .head_name = if (std.mem.startsWith(u8, head_name, "refs/")) head_name else null,
        .orig_head = state_file.oidHex(r.repo.objectFormat(), state_file.oneliner(orig)) orelse return error.MalformedState,
    };
}

fn ontoOf(r: *Run) Error!Oid {
    const text = (try r.readState("onto")) orelse return error.MalformedState;
    return state_file.oidHex(r.repo.objectFormat(), state_file.oneliner(text)) orelse error.MalformedState;
}

/// `skip_unnecessary_picks`: leading picks whose parent is already where
/// `HEAD` will be need not be replayed; they are done, and the base moves to
/// them.
fn skipUnnecessaryPicks(r: *Run, base_in: Oid) Error!Oid {
    var base = base_in;
    var w: Walker = .{ .gpa = r.gpa, .arena = r.arena, .io = r.io, .repo = r.repo };
    var skipped: usize = 0;
    for (r.items.items) |item| {
        if (item.command == .noop or item.command == .drop or item.command == .comment) {
            skipped += 1;
            continue;
        }
        if (item.command != .pick) break;
        const node = try w.load(item.commit.?);
        if (node.parents.len != 1 or !node.parents[0].eql(base)) break;
        base = item.commit.?;
        skipped += 1;
    }
    // Only as far as the last pick actually taken.
    while (skipped > 0 and r.items.items[skipped - 1].command != .pick) skipped -= 1;
    if (skipped == 0) return base_in;
    const done = try todo.toBytes(r.arena, r.items.items[0..skipped], .{});
    try r.state("done", done);
    r.done_nr += countCommands(r.items.items[0..skipped]);
    const rest = try r.arena.dupe(todo.Item, r.items.items[skipped..]);
    r.items.clearRetainingCapacity();
    try r.items.appendSlice(r.arena, rest);
    if (r.items.items.len != 0 and r.items.items[0].command.isFixup()) {
        try recordInRewritten(r, base, r.items.items[0].command);
    }
    return base;
}

/// `checkout_onto`: detach `HEAD` at the base, with `ORIG_HEAD` recording
/// where it was.
fn checkoutOnto(r: *Run, base: Oid, orig_head: Oid, onto_name: []const u8) Error!void {
    var h = try r.head();
    defer h.deinit(r.gpa);
    var locked_index = try r.repo.lockIndex(r.io);
    defer locked_index.deinit(r.io);
    const index = &locked_index.index;
    const from_tree = if (h.oid) |oid| try r.repo.commitTree(r.io, oid) else try r.repo.objectDatabase().write(r.io, .tree, "");
    var outcome = try three_way.fastForward(r.gpa, r.io, r.repo, .{ .index = index, .old = from_tree, .new = try r.repo.commitTree(r.io, base) }, .{ .blocked = r.options.blocked });
    outcome.deinit();
    try locked_index.commit(r.io);
    try r.repo.refStore().root().write(r.repo.allocator(), r.io, .orig_head, orig_head);
    const log = try r.reflogMessage("start", try r.arena.print("checkout {s}", .{onto_name}));
    try head_mod.detach(r.io, r.repo, h.oid, base, .{ .who = r.options.who, .message = log });
    if (r.options.hooks) |runner| _ = try runner.postCheckout(r.io, h.oid orelse Oid.zero(r.repo.objectFormat()), base, .branch);
}

/// Switch to the branch being rebased when there is nothing else to do:
/// `checkout_up_to_date`.
fn checkoutTip(r: *Run, tip: Tip, name: []const u8) Error!void {
    var h = try r.head();
    defer h.deinit(r.gpa);
    if (h.branch != null and tip.head_name != null and std.mem.eql(u8, h.branch.?, tip.head_name.?)) return;
    var locked_index = try r.repo.lockIndex(r.io);
    defer locked_index.deinit(r.io);
    const index = &locked_index.index;
    const from_tree = try r.repo.commitTree(r.io, h.oid orelse return error.UnbornBranch);
    var outcome = try three_way.fastForward(r.gpa, r.io, r.repo, .{ .index = index, .old = from_tree, .new = try r.repo.commitTree(r.io, tip.orig_head) }, .{ .blocked = r.options.blocked });
    outcome.deinit();
    try locked_index.commit(r.io);
    const log = try r.arena.print("{s}: checkout {s}", .{ r.action(), name });
    if (tip.head_name) |branch| {
        try head_mod.attach(r.io, r.repo, branch, h.oid, .{ .who = r.options.who, .message = log });
    } else {
        try head_mod.detach(r.io, r.repo, h.oid, tip.orig_head, .{ .who = r.options.who, .message = log });
    }
}

fn removeState(r: *Run) Error!void {
    // The labels a rebase made go with it.
    if (try r.readState("refs-to-delete")) |text| {
        var labels: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |name| {
            // Only the labels a rebase writes, `refs/rewritten/<label>`,
            // and deleted as refs: a line is not a path to unlink, and a
            // reftable repository keeps them in its tables.
            if (!std.mem.startsWith(u8, name, "refs/rewritten/") or !ref_names.isSafe(name)) continue;
            try labels.append(r.arena, name);
        }
        try r.repo.refStore().deleteRefs(r.repo.allocator(), r.io, labels.items, null);
    }
    try r.repo.gitDirectory().deleteTree(r.io, r.backend.dir());
}

//=========================================================================
// The sheet, worked through
//=========================================================================

/// `save_todo` for a rebase: what is left after the current instruction
/// goes to `git-rebase-todo`, and the current one to `done`. With
/// `reschedule` the current one stays on the sheet.
fn saveTodo(r: *Run, current: usize) Error!void {
    const bytes = try todo.toBytes(r.arena, r.items.items[current..], .{});
    try r.state("git-rebase-todo", bytes);
}

fn advance(r: *Run) Error!void {
    const item = r.items.items[0];
    const rest = try todo.toBytes(r.arena, r.items.items[1..], .{});
    try r.state("git-rebase-todo", rest);
    const line = try todo.toBytes(r.arena, &.{item}, .{});
    try r.appendState("done", line);
}

fn peekCommand(r: *Run, offset: usize) todo.Command {
    var i = offset;
    while (i < r.items.items.len) : (i += 1) {
        const c = r.items.items[i].command;
        if (c != .comment) return c;
    }
    return .noop;
}

/// `pick_commits` for a rebase.
fn runLoop(r: *Run) Error!Outcome {
    try r.removeState("message");
    try r.removeState("stopped-sha");
    try r.removeState("amend");
    try r.removeState("patch");
    while (r.items.items.len != 0) {
        const item = r.items.items[0];
        try advance(r);
        if (item.command != .comment) {
            r.done_nr += 1;
            try r.state("msgnum", try r.arena.print("{d}\n", .{r.done_nr}));
        }
        try r.removeState("author-script");
        try r.repo.refStore().special().delete(r.io, .merge_head);
        try r.repo.refStore().root().delete(r.repo.allocator(), r.io, .auto_merge);
        try r.repo.refStore().root().delete(r.repo.allocator(), r.io, .rebase_head);
        r.msg.clearRetainingCapacity();
        r.have_message = false;

        switch (item.command) {
            .@"break" => {
                _ = r.items.orderedRemove(0);
                return finishOutcome(r, .stopped, .@"break", null);
            },
            .pick, .reword, .edit, .fixup, .squash => {
                const stopped = pickOne(r) catch |err| return reschedule(r, item, err);
                if (stopped) |outcome| return outcome;
            },
            .exec => {
                if (try doExec(r, item.arg)) |outcome| return outcome;
            },
            .label => doLabel(r, item.arg) catch |err| return reschedule(r, item, err),
            .reset => doReset(r, item.arg) catch |err| return reschedule(r, item, err),
            .merge => {
                const stopped = doMerge(r, item) catch |err| return reschedule(r, item, err);
                if (stopped) |outcome| return outcome;
            },
            .update_ref => doUpdateRef(r, item.arg) catch |err| return reschedule(r, item, err),
            .noop, .drop, .comment, .revert => {},
        }
        _ = r.items.orderedRemove(0);
    }
    return finish(r);
}

/// An instruction that failed without stopping -- a refusal, or a label
/// that does not resolve -- goes back on top of the sheet, as git
/// reschedules it, so that once the cause is dealt with a continue tries it
/// again instead of passing over it. Its line stays in `done` too, as in
/// git, and `REBASE_HEAD` names its commit.
fn reschedule(r: *Run, item: todo.Item, err: Error) Error {
    try saveTodo(r, 0);
    if (item.commit) |commit| try r.repo.refStore().root().write(r.repo.allocator(), r.io, .rebase_head, commit);
    return err;
}

/// The author a commit's buffer names, as `write_author_script` records it:
/// `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` and `GIT_AUTHOR_DATE='@secs tz'`,
/// each single-quoted with `'` written as `'\''`.
fn writeAuthorScript(r: *Run, author: object.Signature) Error!void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(r.arena, "GIT_AUTHOR_NAME='");
    try appendQuoted(r.arena, &out, author.name);
    try out.appendSlice(r.arena, "'\nGIT_AUTHOR_EMAIL='");
    try appendQuoted(r.arena, &out, author.email);
    try out.appendSlice(r.arena, "'\nGIT_AUTHOR_DATE='@");
    var sig_buf: std.Io.Writer.Allocating = .init(r.arena);
    const sign: u8 = if (author.offset_minutes < 0) '-' else '+';
    const abs: u32 = @intCast(@abs(author.offset_minutes));
    sig_buf.writer.print("{d} {c}{d:0>2}{d:0>2}", .{ author.when_secs, sign, abs / 60, abs % 60 }) catch return error.OutOfMemory;
    try out.appendSlice(r.arena, sig_buf.written());
    try out.appendSlice(r.arena, "'\n");
    try r.state("author-script", out.items);
}

fn appendQuoted(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
}

//=========================================================================
// One pick
//=========================================================================

const Picked = enum { ok, conflict, empty };

/// Whether the current instruction is the last of a fixup chain.
fn isFinalFixup(r: *Run) bool {
    if (!r.items.items[0].command.isFixup()) return false;
    for (r.items.items[1..]) |item| {
        if (item.command.isFixup()) return false;
        if (!item.command.isNoop()) break;
    }
    return true;
}

/// `pick_one_commit`: apply the instruction, and stop where git stops.
fn pickOne(r: *Run) Error!?Outcome {
    const item = r.items.items[0];
    const commit = item.commit.?;
    const final_fixup = isFinalFixup(r);
    const picked = try doPickCommit(r, item, final_fixup);
    if (item.command == .edit) {
        if (picked == .ok) {
            try errorWithPatch(r, commit, true);
            _ = r.items.orderedRemove(0);
            return finishOutcome(r, .stopped, .edit, commit);
        }
        try errorWithPatch(r, commit, false);
        _ = r.items.orderedRemove(0);
        return finishOutcome(r, .stopped, if (picked == .conflict) .conflict else .empty, commit);
    }
    if (picked == .ok) {
        try recordInRewritten(r, commit, peekCommand(r, 1));
        return null;
    }
    if (item.command.isFixup()) {
        if (picked == .empty) try intendToAmend(r);
        // `error_failed_squash`: the chain's message becomes the one to
        // resolve with.
        const squash_msg = (try r.readState("message-squash")) orelse "";
        try r.state("message", squash_msg);
        try state_file.write(r.io, r.repo.gitDirectory(), "MERGE_MSG", squash_msg);
    }
    try errorWithPatch(r, commit, false);
    _ = r.items.orderedRemove(0);
    return finishOutcome(r, .stopped, if (picked == .conflict) .conflict else .empty, commit);
}

/// `error_with_patch`: what a stop leaves for `--continue` -- the message,
/// `stopped-sha`, `REBASE_HEAD`, the commit's patch, and with `to_amend`
/// the commit `HEAD` names, to be amended.
fn errorWithPatch(r: *Run, commit: Oid, to_amend: bool) Error!void {
    if (r.have_message and !r.hasState("message")) try r.state("message", r.msg.items);
    try r.state("stopped-sha", try r.arena.print("{s}\n", .{try r.hex(commit)}));
    try r.repo.refStore().root().write(r.repo.allocator(), r.io, .rebase_head, commit);
    try writePatch(r, commit);
    if (!r.hasState("message")) {
        const parsed = (try readSource(r, commit)).commit;
        try r.state("message", try r.arena.print("{s}\n", .{message.fromSubject(parsed.message)}));
    }
    if (to_amend) try intendToAmend(r);
}

fn intendToAmend(r: *Run) Error!void {
    try r.state("amend", try r.arena.print("{s}\n", .{try r.hex(try r.headOid())}));
}

/// The commit's diff against its first parent, as `git diff-tree -p`
/// prints it, in `patch`.
fn writePatch(r: *Run, commit_oid: Oid) Error!void {
    const found = try r.repo.objectDatabase().read(r.io, commit_oid);
    defer r.repo.objectDatabase().allocator().free(found.bytes);
    var commit = try object.Commit.parse(r.gpa, r.repo.objectFormat(), found.bytes);
    defer commit.deinit();
    // `log_tree_commit` shows a merge commit no diff at all, so its patch
    // is empty.
    if (commit.parents.len > 1) return r.state("patch", "");
    const parent_tree: ?Oid = if (commit.parents.len != 0) try r.repo.commitTree(r.io, commit.parents[0]) else null;
    var changes = try diff.tree(r.gpa, r.io, r.repo.objectDatabase(), .{ .old = parent_tree, .new = commit.tree }, .{ .renames = .{} });
    defer changes.deinit();
    var out: std.Io.Writer.Allocating = .init(r.arena);
    diff.unified(r.gpa, r.io, .{ .db = r.repo.objectDatabase(), .changes = changes.items }, &out.writer, .{ .abbrev = r.abbrev_len }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    try r.state("patch", out.written());
}

/// Record that `old` became what `HEAD` is once its chain of fixups, if any,
/// is done: `rewritten-pending`, flushed into `rewritten-list` unless a
/// fixup follows.
fn recordInRewritten(r: *Run, old: Oid, next: todo.Command) Error!void {
    try r.appendState("rewritten-pending", try r.arena.print("{s}\n", .{try r.hex(old)}));
    if (!next.isFixup()) try flushRewritten(r);
}

fn flushRewritten(r: *Run) Error!void {
    const pending = (try r.readState("rewritten-pending")) orelse return;
    if (pending.len == 0) return;
    const new = try r.hex(try r.headOid());
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, pending, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(r.arena, line);
        try out.append(r.arena, ' ');
        try out.appendSlice(r.arena, new);
        try out.append(r.arena, '\n');
    }
    try r.appendState("rewritten-list", out.items);
    try r.removeState("rewritten-pending");
}

/// What a replayed commit is made of.
const Source = struct {
    oid: Oid,
    bytes: []const u8,
    commit: object.Commit,
};

/// A commit read into the arena, its message and people in
/// `i18n.commitEncoding`, as git's sequencer converts every commit it
/// takes a message or an author from (`logmsg_reencode`).
fn readSource(r: *Run, oid: Oid) Error!Source {
    return readIn(r, oid, try message.commitEncoding(r.repo.configuration()));
}

fn readIn(r: *Run, oid: Oid, output: []const u8) Error!Source {
    const found = try r.repo.objectDatabase().read(r.io, oid);
    defer r.repo.objectDatabase().allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const bytes = try r.arena.dupe(u8, found.bytes);
    const shown = try pretty.reencodeCommit(r.arena, bytes, output);
    return .{ .oid = oid, .bytes = bytes, .commit = try object.Commit.parse(r.arena, r.repo.objectFormat(), shown.bytes) };
}

/// `do_pick_commit` for the instructions that apply a commit.
fn doPickCommit(r: *Run, item: todo.Item, final_fixup: bool) Error!Picked {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    const arena = r.arena;
    const command = item.command;
    const is_fixup = command.isFixup();
    const reflog_action = try r.reflogMessage(command.name(), null);

    var head = try r.head();
    defer head.deinit(gpa);
    const head_oid = head.oid orelse return error.UnbornBranch;
    const head_tree = try repo.commitTree(io, head_oid);
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnmergedIndex;
    }

    const source = try readSource(r, item.commit.?);
    const commit = source.commit;
    if (commit.parents.len > 1) return error.MergeCommit;
    const parent: ?Oid = if (commit.parents.len == 1) commit.parents[0] else null;
    const subject = message.subjectLine(commit.message);
    const short_name = try r.short(source.oid);
    const label = try arena.print("{s} ({s})", .{ short_name, subject });
    const parent_label = try arena.print("parent of {s}", .{label});

    // The commit sits on `HEAD` already: reuse it.
    if (r.allow_ff and !is_fixup and parent != null and parent.?.eql(head_oid)) {
        try writeAuthorScript(r, commit.author);
        var outcome = try three_way.fastForward(gpa, io, repo, .{ .index = index, .old = head_tree, .new = commit.tree }, .{ .blocked = r.options.blocked });
        outcome.deinit();
        try locked_index.commit(io);
        try head_mod.advance(io, repo, head, source.oid, .{ .who = r.options.who, .message = "rebase: fast-forward" });
        if (command == .reword) try reword(r, reflog_action);
        return .ok;
    }

    try r.msg.appendSlice(arena, message.fromSubject(commit.message));
    r.have_message = true;
    var msg_source: MessageSource = .merge_msg;
    if (is_fixup) {
        try updateSquashMessages(r, item, commit.message);
        if (!final_fixup) {
            msg_source = .squash;
        } else if (r.hasState("message-fixup")) {
            msg_source = .fixup;
        } else {
            msg_source = .squash_edit;
        }
    }
    if (r.options.signoff and !is_fixup) try message.appendSignoff(arena, &r.msg, r.options.who, r.trailers);
    try writeAuthorScript(r, commit.author);

    const base_tree = if (parent) |p| try repo.commitTree(io, p) else null;
    const style = r.options.conflict_style orelse try merge.configuredStyle(repo.configuration());
    var outcome = try three_way.apply(gpa, io, repo, .{ .index = index, .base = base_tree, .ours = head_tree, .theirs = commit.tree }, .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .base = if (parent != null) parent_label else "(empty tree)", .theirs = label },
            .algorithm = .histogram,
        },
        .strategy_options = r.options.strategy_options,
        .filters = r.options.filters,
        .programs = r.options.programs,
        .blocked = r.options.blocked,
    });
    defer outcome.deinit();
    try locked_index.commit(io);
    try repo.refStore().root().write(repo.allocator(), io, .auto_merge, outcome.auto_merge);
    if (!outcome.isClean()) try noteConflicts(r, outcome.conflicts);
    try state_file.write(io, repo.gitDirectory(), "MERGE_MSG", r.msg.items);
    // A rebase takes care of the commit itself, so a conflict leaves no
    // `CHERRY_PICK_HEAD`, as git's leaves none. rerere runs on the stop.
    if (!outcome.isClean()) {
        _ = try rerere.afterStop(gpa, io, repo, .{ .arena = arena, .autoupdate = r.options.rerere_autoupdate });
        return .conflict;
    }
    if (command == .pick or command == .reword or command == .edit) {
        try repo.refStore().root().write(repo.allocator(), io, .cherry_pick_head, source.oid);
    }

    // Empty now, or empty from the start.
    var allow_empty = false;
    if (outcome.tree.?.eql(head_tree)) {
        const parent_tree = base_tree orelse try repo.objectDatabase().write(io, .tree, "");
        if (parent_tree.eql(commit.tree)) {
            allow_empty = true;
        } else switch (r.empty) {
            .keep => allow_empty = true,
            .drop => {
                try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
                try state_file.remove(io, repo.gitDirectory(), "MERGE_MSG");
                try repo.refStore().root().delete(repo.allocator(), io, .auto_merge);
                return .ok;
            },
            .stop => {},
        }
    }

    return commitPick(r, item, final_fixup, .{
        .head = head,
        .tree = outcome.tree.?,
        .author = commit.author,
        .source = msg_source,
        .allow_empty = allow_empty,
        .reflog_action = reflog_action,
    });
}

/// What `doPickCommit` applied, for `commitPick` to commit.
const Applied = struct {
    head: head_mod.Head,
    tree: Oid,
    author: object.Signature,
    source: MessageSource,
    allow_empty: bool,
    reflog_action: []const u8,
};

/// Where a pick's message comes from: `MERGE_MSG`, the squash message so
/// far, the fixup's, or the squash message edited at the chain's end.
const MessageSource = enum { merge_msg, squash, fixup, squash_edit };

/// The commit of a pick, or the amended one of a fixup chain, and what
/// follows it: hooks, state and the end of a chain.
fn commitPick(r: *Run, item: todo.Item, final_fixup: bool, applied: Applied) Error!Picked {
    const io = r.io;
    const repo = r.repo;
    const arena = r.arena;
    const command = item.command;
    const head = applied.head;
    // `doPickCommit` refused an unborn branch already.
    const head_oid = head.oid.?;
    const msg_source = applied.source;
    const reflog_action = applied.reflog_action;
    // The commit, or the amended one of a fixup chain.
    const amending = command.isFixup();
    const parents: []const Oid = if (amending) try parentsOf(r, head_oid) else &.{head_oid};
    const first_parent_tree = if (parents.len != 0) try repo.commitTree(io, parents[0]) else try repo.objectDatabase().write(io, .tree, "");
    if (!applied.allow_empty and applied.tree.eql(first_parent_tree)) return .empty;
    const author = if (amending) (try readSource(r, head_oid)).commit.author else applied.author;

    // `try_to_commit` cleans nothing but whitespace, and that only with a
    // sign-off, unless `commit.cleanup` says otherwise; an edited message
    // is cleaned of comments as an editor's is.
    const cleanup = message.uncut(try message.sequencerCleanup(repo.configuration()) orelse message.sequencerDefault(r.options.signoff));
    const commit_hooks = try commit_hooks_mod.Hooks.init(arena, io, repo, .{ .runner = r.options.hooks, .verify = r.options.verify });
    // An edited message is `git commit -n -e`'s: its hooks see the author
    // and the editor the person has.
    var edit_env = try commit_hooks.env(arena, author);
    edit_env.editor = true;
    const text: []const u8 = switch (msg_source) {
        .merge_msg => try message.cleanup(arena, r.msg.items, cleanup, r.comment),
        .squash => try message.cleanup(arena, (try r.readState("message-squash")).?, cleanup, r.comment),
        .fixup => try message.cleanup(arena, (try r.readState("message-fixup")).?, cleanup, r.comment),
        .squash_edit => blk: {
            const proposed = (try r.readState("message-squash")).?;
            try state_file.write(io, repo.gitDirectory(), "SQUASH_MSG", proposed);
            // git points `REBASE_HEAD` at the commit before it runs `git
            // commit` for the message.
            try repo.refStore().root().write(repo.allocator(), io, .rebase_head, item.commit.?);
            var shown = proposed;
            if (commit_hooks.runner) |runner| {
                try state_file.write(io, repo.gitDirectory(), "COMMIT_EDITMSG", proposed);
                _ = try runner.prepareCommitMsg(io, edit_env, try commit_hooks.path(arena, "COMMIT_EDITMSG"), .{ .source = .message, .commit = null });
                shown = (try state_file.read(arena, io, repo.gitDirectory(), "COMMIT_EDITMSG")) orelse "";
            }
            break :blk try edited(r, .squash, shown);
        },
    };
    // `try_to_commit`: `prepare-commit-msg` sees the message before it is
    // cleaned, in `COMMIT_EDITMSG`, when the hook is there at all.
    var final_text = text;
    if (msg_source != .squash_edit and commit_hooks.exists(io, "prepare-commit-msg")) {
        const raw: []const u8 = switch (msg_source) {
            .merge_msg => r.msg.items,
            .squash => (try r.readState("message-squash")).?,
            .fixup => (try r.readState("message-fixup")).?,
            .squash_edit => unreachable,
        };
        try state_file.write(io, repo.gitDirectory(), "COMMIT_EDITMSG", raw);
        const e = try commit_hooks.env(arena, null);
        const file = try commit_hooks.path(arena, "COMMIT_EDITMSG");
        _ = try commit_hooks.runner.?.prepareCommitMsg(io, e, file, .{ .source = .message, .commit = null });
        const back = (try state_file.read(arena, io, repo.gitDirectory(), "COMMIT_EDITMSG")) orelse "";
        final_text = try message.cleanup(arena, back, cleanup, r.comment);
    }
    const extra: []const object.ExtraHeader = if (amending) try extraHeadersOf(r, head_oid) else &.{};
    const made = try repo.writeCommit(io, .{
        .tree = applied.tree,
        .parents = parents,
        .author = author,
        .committer = r.options.who,
        .message = final_text,
        .extra = extra,
        .signing = r.options.signing,
    }, .{ .diagnostic = r.options.diagnostic });
    const log = try arena.print("{s}: {s}", .{ reflog_action, firstLine(final_text) });
    try head_mod.advance(io, repo, head, made, .{ .who = r.options.who, .message = log });
    if (msg_source == .squash_edit) {
        // `git commit` takes the message's files away before its last hooks.
        try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
        try state_file.remove(io, repo.gitDirectory(), "MERGE_MSG");
    }
    if (commit_hooks.runner) |runner| {
        if (msg_source == .squash_edit) {
            _ = try runner.postCommit(io, edit_env);
        } else try commit_hooks.postCommit(arena, io, null);
    }
    // An amend in place is `commit --amend`'s, with its author when it is
    // `git commit`'s.
    if (amending) try postRewriteAmend(r, commit_hooks.runner, .{ .old = head_oid, .new = made }, if (msg_source == .squash_edit) author else null);
    try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
    try state_file.remove(io, repo.gitDirectory(), "MERGE_MSG");
    if (msg_source == .squash_edit) {
        // An edited message is committed with `git commit`, which takes
        // `AUTO_MERGE` away as it finishes; git points `REBASE_HEAD` at the
        // commit first, and it stays there until the next instruction.
        try state_file.remove(io, repo.gitDirectory(), "SQUASH_MSG");
        try repo.refStore().root().delete(repo.allocator(), io, .auto_merge);
    }
    if (command == .reword) try reword(r, reflog_action);
    if (final_fixup) {
        try r.removeState("message-fixup");
        try r.removeState("message-squash");
        try r.removeState("current-fixups");
        r.fixups.clearRetainingCapacity();
        r.fixup_count = 0;
    }
    return .ok;
}

/// Leave a stopped pick's conflicts at the foot of its message, commented,
/// and in the run.
fn noteConflicts(r: *Run, conflicts: []const three_way.Conflict) Error!void {
    const arena = r.arena;
    const copied = try arena.dupe(three_way.Conflict, conflicts);
    const paths = try arena.alloc([]const u8, conflicts.len);
    for (copied, paths) |*c, *slot| {
        c.path = try arena.dupe(u8, c.path);
        slot.* = c.path;
    }
    // Under the scissors line when `commit.cleanup` is `scissors`.
    const mode = try message.sequencerCleanup(r.repo.configuration()) orelse .verbatim;
    try message.appendConflictsHint(arena, &r.msg, paths, r.comment, mode);
    r.conflicts = copied;
}

fn parentsOf(r: *Run, oid: Oid) Error![]const Oid {
    return (try readSource(r, oid)).commit.parents;
}

/// The headers an amend carries over: all but the signatures, which would
/// no longer verify.
fn extraHeadersOf(r: *Run, oid: Oid) Error![]const object.ExtraHeader {
    const source = try readSource(r, oid);
    var out: std.ArrayList(object.ExtraHeader) = .empty;
    for (source.commit.extra) |h| {
        if (std.mem.eql(u8, h.name, "gpgsig") or std.mem.eql(u8, h.name, "gpgsig-sha256")) continue;
        try out.append(r.arena, h);
    }
    return out.items;
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
}

/// A message a person would have edited: what the caller's `Messages` make
/// of it, or the proposal as an editor left untouched leaves it, cleaned as
/// `git commit` cleans after an editor (`editedCleanup`). git's proposal
/// also carries its status comments, which a `verbatim` or `whitespace`
/// cleanup keeps; relic's has none.
fn edited(r: *Run, kind: MessageKind, proposed: []const u8) Error![]const u8 {
    var text = proposed;
    if (r.options.messages) |m| {
        if (m.editFn(m.context, kind, proposed)) |given| text = given;
    }
    const cleaned = try message.cleanup(r.arena, text, try editedCleanup(r), r.comment);
    if (cleaned.len == 0) return error.EmptyMessage;
    return cleaned;
}

/// How `git commit -e`, which git's sequencer runs for a message a person
/// edits, cleans it: `commit.cleanup` read for an editor, `strip` by
/// default.
fn editedCleanup(r: *Run) Error!message.Cleanup {
    return message.cleanupMode(try message.cleanupSetting(r.repo.configuration()), true);
}

/// git's `commit_post_rewrite`, after the post-commit of every amend a
/// rebase makes: the amended commit's notes follow it as
/// `notes.rewrite.amend` says, then `post-rewrite amend` is told, with
/// `author` exported where `git commit` exports it.
fn postRewriteAmend(r: *Run, runner: ?*hooks_mod.Runner, rewrite: hooks_mod.Runner.Rewrite, author: ?object.Signature) Error!void {
    try notes.copyForRewrite(r.gpa, r.io, r.repo, &.{rewrite}, .{ .command = .amend, .who = r.options.who });
    if (runner) |h| _ = try h.postRewriteBy(r.io, .amend, &.{rewrite}, author);
}

/// `reword`: amend `HEAD` with the message a person makes of it.
fn reword(r: *Run, reflog_action: []const u8) Error!void {
    var head = try r.head();
    defer head.deinit(r.gpa);
    const current = try readSource(r, head.oid.?);
    // `git commit --amend` behind an editor: all four of its hooks, told
    // the commit it amends, with the author it keeps.
    const commit_hooks = try commit_hooks_mod.Hooks.init(r.arena, r.io, r.repo, .{ .runner = r.options.hooks, .verify = true });
    var e = try commit_hooks.env(r.arena, current.commit.author);
    e.editor = true;
    var proposed = message.fromSubject(current.commit.message);
    const file = try commit_hooks.path(r.arena, "COMMIT_EDITMSG");
    if (commit_hooks.runner) |runner| {
        _ = try runner.preCommit(r.io, e);
        try state_file.write(r.io, r.repo.gitDirectory(), "COMMIT_EDITMSG", proposed);
        _ = try runner.prepareCommitMsg(r.io, e, file, .{ .source = .commit, .commit = "HEAD" });
        proposed = (try state_file.read(r.arena, r.io, r.repo.gitDirectory(), "COMMIT_EDITMSG")) orelse "";
    }
    var text = try edited(r, .reword, proposed);
    if (commit_hooks.runner) |runner| {
        try state_file.write(r.io, r.repo.gitDirectory(), "COMMIT_EDITMSG", text);
        _ = try runner.commitMsg(r.io, e, file);
        const back = (try state_file.read(r.arena, r.io, r.repo.gitDirectory(), "COMMIT_EDITMSG")) orelse "";
        text = try message.cleanup(r.arena, back, try editedCleanup(r), r.comment);
    }
    const made = try r.repo.writeCommit(r.io, .{
        .tree = current.commit.tree,
        .parents = current.commit.parents,
        .author = current.commit.author,
        .committer = r.options.who,
        .message = text,
        .signing = r.options.signing,
    }, .{ .diagnostic = r.options.diagnostic });
    const log = try r.arena.print("{s}: {s}", .{ reflog_action, firstLine(text) });
    try head_mod.advance(r.io, r.repo, head, made, .{ .who = r.options.who, .message = log });
    // The amend is `git commit --amend`, which takes `AUTO_MERGE` away.
    try r.repo.refStore().root().delete(r.repo.allocator(), r.io, .auto_merge);
    if (commit_hooks.runner) |runner| _ = try runner.postCommit(r.io, e);
    try postRewriteAmend(r, commit_hooks.runner, .{ .old = head.oid.?, .new = made }, current.commit.author);
}

//=========================================================================
// Squash and fixup messages
//=========================================================================

const first_commit_msg = "This is the 1st commit message:";
const skip_first_commit_msg = "The 1st commit message will be skipped:";

fn isFixupFlag(item: todo.Item) bool {
    return item.command == .fixup and (item.replace_message or item.edit_message);
}

fn seenSquash(r: *Run) bool {
    return std.mem.startsWith(u8, r.fixups.items, "squash") or std.mem.find(u8, r.fixups.items, "\nsquash") != null;
}

/// `strbuf_add_commented_lines`, into a list.
fn addCommented(r: *Run, out: *std.ArrayList(u8), text: []const u8) Error!void {
    try message.appendCommented(r.arena, out, text, r.comment);
}

/// `add_commented_lines`: lines already commented are copied as they are,
/// and the rest commented.
fn addCommentedKeepingComments(r: *Run, out: *std.ArrayList(u8), text_in: []const u8) Error!void {
    var text = text_in;
    while (std.mem.startsWith(u8, text, r.comment)) {
        const next = if (std.mem.findScalar(u8, text, '\n')) |nl| nl + 1 else text.len;
        try out.appendSlice(r.arena, text[0..next]);
        text = text[next..];
    }
    try addCommented(r, out, text);
}

/// `commit_subject_length`: where the first blank line after the subject
/// paragraph starts.
fn subjectLength(body: []const u8) usize {
    var at: usize = 0;
    while (at < body.len) {
        const end = std.mem.findScalarPos(u8, body, at, '\n') orelse body.len;
        var blank = true;
        for (body[at..end]) |c| {
            if (c != ' ' and c != '\t' and c != '\r') blank = false;
        }
        if (blank) break;
        at = if (end < body.len) end + 1 else end;
    }
    return at;
}

/// `update_squash_messages`: the chain's message so far, in
/// `message-squash`, and `message-fixup` when only fixups have come.
fn updateSquashMessages(r: *Run, item: todo.Item, commit_message: []const u8) Error!void {
    const arena = r.arena;
    var buf: std.ArrayList(u8) = .empty;
    if (r.fixup_count > 0) {
        const old = (try r.readState("message-squash")) orelse return error.MalformedState;
        const eol = if (!std.mem.startsWith(u8, old, r.comment)) 0 else (std.mem.findScalar(u8, old, '\n') orelse old.len);
        try buf.appendSlice(arena, try arena.print("{s} This is a combination of {d} commits.", .{ r.comment, r.fixup_count + 2 }));
        try buf.appendSlice(arena, old[eol..]);
        if (isFixupFlag(item) and !seenSquash(r)) buf = try updateSquashMessageForFixup(r, buf.items);
    } else {
        const head_source = try readSource(r, try r.headOid());
        const body = message.fromSubject(head_source.commit.message);
        if (item.command == .fixup and !isFixupFlag(item)) try r.state("message-fixup", body);
        try buf.appendSlice(arena, try arena.print("{s} This is a combination of 2 commits.\n{s} {s}\n\n", .{
            r.comment, r.comment, if (isFixupFlag(item)) skip_first_commit_msg else first_commit_msg,
        }));
        if (isFixupFlag(item)) try addCommented(r, &buf, body) else try buf.appendSlice(arena, body);
    }

    const body = message.fromSubject(commit_message);
    if (item.command == .squash or isFixupFlag(item)) {
        try appendSquashMessage(r, &buf, body, item);
    } else {
        r.fixup_count += 1;
        try buf.appendSlice(arena, try arena.print("\n{s} The commit message #{d} will be skipped:\n\n", .{ r.comment, r.fixup_count + 1 }));
        try addCommented(r, &buf, body);
    }
    try r.state("message-squash", buf.items);
    if (r.fixups.items.len != 0) try r.fixups.append(arena, '\n');
    try r.fixups.appendSlice(arena, item.command.name());
    try r.fixups.append(arena, ' ');
    try r.fixups.appendSlice(arena, try r.hex(item.commit.?));
    try r.state("current-fixups", r.fixups.items);
}

/// `append_squash_message`.
fn appendSquashMessage(r: *Run, buf: *std.ArrayList(u8), body: []const u8, item: todo.Item) Error!void {
    const arena = r.arena;
    var commented_len: usize = 0;
    if (std.mem.startsWith(u8, body, "amend!") or
        ((item.command == .squash or seenSquash(r)) and
            (std.mem.startsWith(u8, body, "squash!") or std.mem.startsWith(u8, body, "fixup!"))))
    {
        commented_len = subjectLength(body);
    }
    r.fixup_count += 1;
    try buf.appendSlice(arena, try arena.print("\n{s} This is the commit message #{d}:\n\n", .{ r.comment, r.fixup_count + 1 }));
    if (commented_len != 0) try addCommented(r, buf, body[0..commented_len]) else if (buf.items.len != 0 and buf.items[buf.items.len - 1] != '\n') try buf.append(arena, '\n');
    const fixup_off = buf.items.len;
    try buf.appendSlice(arena, body[commented_len..]);
    if (isFixupFlag(item) and !seenSquash(r)) {
        if (r.options.signoff) try message.appendSignoff(arena, buf, r.options.who, r.trailers);
        if (item.replace_message and (r.hasState("message-fixup") or !r.hasState("message-squash"))) {
            var rest = buf.items[fixup_off..];
            while (rest.len != 0) {
                const nl = std.mem.findScalar(u8, rest, '\n') orelse break;
                if (std.mem.trim(u8, rest[0..nl], " \t\r").len != 0) break;
                rest = rest[nl + 1 ..];
            }
            try r.state("message-fixup", rest);
        } else try r.removeState("message-fixup");
    } else try r.removeState("message-fixup");
}

/// `update_squash_message_for_fixup`: after a `fixup -C`, the messages
/// before it are the ones to skip.
fn updateSquashMessageForFixup(r: *Run, orig: []const u8) Error!std.ArrayList(u8) {
    const arena = r.arena;
    var out: std.ArrayList(u8) = .empty;
    var buf1 = try arena.print("{s} {s}\n", .{ r.comment, first_commit_msg });
    var buf2 = try arena.print("{s} {s}\n", .{ r.comment, skip_first_commit_msg });
    var commented = false;
    var from: usize = 0;
    var s: ?usize = 0;
    var n: usize = 1;
    while (s) |at| {
        if (std.mem.startsWith(u8, orig[at..], buf1)) {
            var next = at + buf1.len;
            const off: usize = if (at > from + 1 and orig[at - 2] == '\n') 1 else 0;
            try copyLines(r, &out, orig[from .. at - off], commented);
            if (off != 0) try out.append(arena, '\n');
            try out.appendSlice(arena, buf2);
            if (next < orig.len and orig[next] == '\n') {
                try out.append(arena, '\n');
                next += 1;
            }
            from = next;
            s = next;
            commented = true;
            n += 1;
            buf1 = try arena.print("{s} This is the commit message #{d}:\n", .{ r.comment, n });
            buf2 = try arena.print("{s} The commit message #{d} will be skipped:\n", .{ r.comment, n });
        } else if (std.mem.startsWith(u8, orig[at..], buf2)) {
            const next = at + buf2.len;
            const off: usize = if (at > from + 1 and orig[at - 2] == '\n') 1 else 0;
            try copyLines(r, &out, orig[from .. at - off], commented);
            from = at - off;
            s = next;
            commented = false;
            n += 1;
            buf1 = try arena.print("{s} This is the commit message #{d}:\n", .{ r.comment, n });
            buf2 = try arena.print("{s} The commit message #{d} will be skipped:\n", .{ r.comment, n });
        } else {
            s = if (std.mem.findScalarPos(u8, orig, at, '\n')) |nl| nl + 1 else null;
            if (s != null and s.? >= orig.len) s = null;
        }
    }
    try copyLines(r, &out, orig[from..], commented);
    return out;
}

fn copyLines(r: *Run, out: *std.ArrayList(u8), text: []const u8, commented: bool) Error!void {
    if (commented) try addCommentedKeepingComments(r, out, text) else try out.appendSlice(r.arena, text);
}

//=========================================================================
// The other instructions
//=========================================================================

/// `exec`: run the command line through `sh`, from the caller's
/// environment; stop if it fails or leaves changes behind.
fn doExec(r: *Run, command_line: []const u8) Error!?Outcome {
    const programs = r.options.programs orelse return error.ExecNotPermitted;
    const wt = r.repo.workDirectory() orelse return error.BareRepository;
    var outcome = try program.run(r.gpa, r.io, programs, .{
        .argv = &.{command_line},
        .shell = true,
        .cwd = .{ .dir = wt },
        .unset = &.{"GIT_CHERRY_PICK_HELP"},
        .stderr = .inherit,
    }, .{});
    defer outcome.deinit(r.gpa);
    var status: u32 = switch (outcome.term) {
        .exited => |code| if (code == 127) 1 else code,
        else => 1,
    };
    const dirty = blk: {
        requireClean(r) catch |err| switch (err) {
            error.DirtyWorktree => break :blk true,
            else => |e| return e,
        };
        break :blk false;
    };
    if (status == 0 and dirty) status = 1;
    if (status == 0) return null;
    if (r.reschedule_failed_exec) {
        // Back on the sheet, to be run again on `--continue`.
        try saveTodo(r, 0);
    }
    _ = r.items.orderedRemove(0);
    const line = try r.arena.dupe(u8, command_line);
    var out = finishOutcome(r, .stopped, .exec_failed, null);
    out.exec = line;
    out.exec_status = status;
    return out;
}

/// `label`: `refs/rewritten/<label>` at `HEAD`, deleted when the rebase is.
fn doLabel(r: *Run, name: []const u8) Error!void {
    if (std.mem.eql(u8, name, "#")) return error.UnknownLabel;
    const ref = try r.arena.print("refs/rewritten/{s}", .{name});
    var tx = r.repo.beginRefs();
    defer tx.deinit(r.io);
    try tx.update(ref, .{ .direct = try r.headOid() }, .any);
    try tx.commit(r.io, .{ .who = r.options.who, .message = try r.arena.print("rebase (label) '{s}'", .{name}), .policy = r.repo.reflogPolicy() });
    try r.appendState("refs-to-delete", try r.arena.print("{s}\n", .{ref}));
}

/// `lookup_label`: `refs/rewritten/<label>`, or any name a commit goes by.
fn lookupLabel(r: *Run, name: []const u8) Error!Oid {
    const ref = try r.arena.print("refs/rewritten/{s}", .{name});
    if (try r.repo.refStore().resolve(r.gpa, r.io, ref)) |resolved| {
        r.gpa.free(resolved.name);
        return resolved.oid;
    }
    var context: sequencer.ResolverContext = .{ .repo = r.repo, .io = r.io };
    const found = context.resolver().resolveFn(&context, name) orelse return error.UnknownLabel;
    return found.oid;
}

/// `reset`: `HEAD`, the index and the working tree to a label.
fn doReset(r: *Run, arg: []const u8) Error!void {
    // git's `rebase -r --root` sheet starts from no commit at all, which
    // git reaches through a `squash-onto` commit it amends away; that
    // replay is not one this does, and the words are no label.
    if (std.mem.eql(u8, std.mem.trimEnd(u8, arg, " \t\r\n"), "[new root]")) return error.UnsupportedNewRoot;
    const end = std.mem.findAny(u8, arg, " \t\n\r") orelse arg.len;
    const name = arg[0..end];
    const target = try lookupLabel(r, name);
    var locked_index = try r.repo.lockIndex(r.io);
    defer locked_index.deinit(r.io);
    const index = &locked_index.index;
    try reset.toTree(r.gpa, r.io, r.repo, .{ .index = index, .tree = try r.repo.commitTree(r.io, target), .mode = .merge, .blocked = r.options.blocked });
    try locked_index.commit(r.io);
    var h = try r.head();
    defer h.deinit(r.gpa);
    const log = try r.reflogMessage("reset", try r.arena.print("'{s}'", .{name}));
    try head_mod.advance(r.io, r.repo, h, target, .{ .who = r.options.who, .message = log });
}

/// `update-ref`: remember where `HEAD` is for a ref to be moved when the
/// rebase finishes.
fn doUpdateRef(r: *Run, ref: []const u8) Error!void {
    const text = (try state_file.read(r.arena, r.io, r.repo.gitDirectory(), r.statePath("update-refs"))) orelse return;
    const records = try parseUpdateRefs(r, text);
    const new = try r.headOid();
    for (records.items) |*rec| {
        if (std.mem.eql(u8, rec.ref, ref)) rec.after = new;
    }
    try writeUpdateRefs(r, records.items);
}

const UpdateRef = struct { ref: []const u8, before: Oid, after: Oid };

fn parseUpdateRefs(r: *Run, text: []const u8) Error!std.ArrayList(UpdateRef) {
    return parseUpdateRefsText(r.arena, r.repo.objectFormat(), text);
}

/// The records of an `update-refs` file: a ref, where it was, and where
/// it goes, one line each.
fn parseUpdateRefsText(arena: Allocator, kind: hash.Kind, text: []const u8) error{ MalformedState, OutOfMemory }!std.ArrayList(UpdateRef) {
    var out: std.ArrayList(UpdateRef) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ref| {
        if (ref.len == 0) break;
        const before = lines.next() orelse return error.MalformedState;
        const after = lines.next() orelse return error.MalformedState;
        try out.append(arena, .{
            .ref = ref,
            .before = Oid.parse(kind, before) catch return error.MalformedState,
            .after = Oid.parse(kind, after) catch return error.MalformedState,
        });
    }
    return out;
}

fn writeUpdateRefs(r: *Run, records: []const UpdateRef) Error!void {
    if (records.len == 0) return r.removeState("update-refs");
    var out: std.ArrayList(u8) = .empty;
    for (records) |rec| {
        try out.appendSlice(r.arena, try r.arena.print("{s}\n{s}\n{s}\n", .{ rec.ref, try r.hex(rec.before), try r.hex(rec.after) }));
    }
    try r.state("update-refs", out.items);
}

fn lessThanRef(_: void, a: UpdateRef, b: UpdateRef) bool {
    return std.mem.order(u8, a.ref, b.ref) == .lt;
}

/// A record for `ref` that has not moved yet: where it is now, and
/// nothing after.
fn freshUpdateRef(r: *Run, ref: []const u8) Error!UpdateRef {
    const zero = Oid.zero(r.repo.objectFormat());
    const resolved = try r.repo.refStore().resolve(r.gpa, r.io, ref);
    const before = if (resolved) |found| blk: {
        r.gpa.free(found.name);
        break :blk found.oid;
    } else zero;
    return .{ .ref = try r.arena.dupe(u8, ref), .before = before, .after = zero };
}

/// `--update-refs`: after each instruction that names a commit, an
/// `update-ref` for every other local branch that points at it -- in the
/// order git's decorations list them, the last name first -- or a comment
/// in its place when another worktree has that branch checked out. With
/// `write`, the refs are recorded in `update-refs` as git records them.
fn addUpdateRefCommands(r: *Run, items: []todo.Item, write: bool) Error![]todo.Item {
    var listing = try r.repo.refStore().list(r.gpa, r.io, "refs/heads/");
    defer listing.deinit();
    var head = try r.head();
    defer head.deinit(r.gpa);
    var busy = try checkedOutBranches(r);

    var out: std.ArrayList(todo.Item) = .empty;
    var records: std.ArrayList(UpdateRef) = .empty;
    for (items) |item| {
        try out.append(r.arena, item);
        const commit = item.commit orelse continue;
        var i = listing.entries.len;
        while (i > 0) {
            i -= 1;
            const entry = listing.entries[i];
            const oid = switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => blk: {
                    const resolved = (try r.repo.refStore().resolve(r.gpa, r.io, entry.name)) orelse continue;
                    r.gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            if (!oid.eql(commit)) continue;
            if (head.branch) |branch| {
                if (std.mem.eql(u8, branch, entry.name)) continue;
            }
            if (busy.get(entry.name)) |where| {
                const line = try r.arena.print("{s} Ref {s} checked out at '{s}'", .{ r.comment, entry.name, where });
                try out.append(r.arena, .{ .command = .comment, .arg = line });
                continue;
            }
            const name = try r.arena.dupe(u8, entry.name);
            try out.append(r.arena, .{ .command = .update_ref, .arg = name });
            for (records.items) |rec| {
                if (std.mem.eql(u8, rec.ref, name)) break;
            } else try records.append(r.arena, try freshUpdateRef(r, name));
        }
    }
    if (write) {
        std.mem.sort(UpdateRef, records.items, {}, lessThanRef);
        try writeUpdateRefs(r, records.items);
    }
    return out.items;
}

/// `todo_list_filter_update_refs`: after the sheet is edited, forget the
/// refs whose `update-ref` line was taken out and have not moved, and
/// record the ones whose line was put in.
fn filterUpdateRefs(r: *Run) Error!void {
    const text = (try r.readState("update-refs")) orelse "";
    var records = try parseUpdateRefs(r, text);
    var updated = false;
    var i: usize = 0;
    while (i < records.items.len) {
        const rec = records.items[i];
        if (!rec.after.isZero() or hasUpdateRefLine(r, rec.ref)) {
            i += 1;
            continue;
        }
        _ = records.orderedRemove(i);
        updated = true;
    }
    for (r.items.items) |item| {
        if (item.command != .update_ref) continue;
        for (records.items) |rec| {
            if (std.mem.eql(u8, rec.ref, item.arg)) break;
        } else {
            try records.append(r.arena, try freshUpdateRef(r, item.arg));
            updated = true;
        }
    }
    if (!updated) return;
    std.mem.sort(UpdateRef, records.items, {}, lessThanRef);
    try writeUpdateRefs(r, records.items);
}

fn hasUpdateRefLine(r: *Run, ref: []const u8) bool {
    for (r.items.items) |item| {
        if (item.command == .update_ref and std.mem.eql(u8, item.arg, ref)) return true;
    }
    return false;
}

/// The branches some worktree holds, and where that worktree is, as git's
/// `branch_checked_out` finds them: each worktree's `HEAD`, the branch a
/// rebase there is rebasing, the branch a bisection started from, and the
/// refs a rebase there will move.
fn checkedOutBranches(r: *Run) Error!std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const repo = r.repo;
    const io = r.io;

    // The main worktree, unless the repository is bare.
    const bare = repo.configuration().getBool("core.bare", false) catch false;
    if (!bare) main: {
        var buf: [4096]u8 = undefined;
        const len = repo.commonDirectory().realPath(io, &buf) catch break :main;
        const common = buf[0..len];
        const main_path = if (std.mem.endsWith(u8, common, "/.git")) common[0 .. common.len - "/.git".len] else common;
        try addWorktreeBranches(r, &map, repo.commonDirectory(), "main-worktree/HEAD", try r.arena.dupe(u8, main_path));
    }
    var listing = try worktrees.list(r.gpa, io, repo.refStore());
    defer listing.deinit();
    for (listing.entries) |entry| {
        const sub = try r.arena.print("worktrees/{s}", .{entry.name});
        var admin = repo.commonDirectory().openDir(io, sub, .{}) catch continue;
        defer admin.close(io);
        try addWorktreeBranches(r, &map, admin, try r.arena.print("{s}/HEAD", .{sub}), try r.arena.dupe(u8, entry.path));
    }
    return map;
}

/// The branches the worktree whose `HEAD` is `head` holds: that `HEAD`,
/// read through the ref store, which a reftable repository keeps in its
/// tables, and what the operation in progress in `dir` is on.
fn addWorktreeBranches(r: *Run, map: *std.StringHashMapUnmanaged([]const u8), dir: Io.Dir, head: []const u8, where: []const u8) Error!void {
    const arena = r.arena;
    const head_value = r.repo.refStore().read(arena, r.io, head) catch |err| switch (err) {
        // git's `get_worktrees` reads a `HEAD` it cannot take as nothing.
        error.MalformedRef => null,
        else => |e| return e,
    };
    if (head_value) |value| switch (value) {
        .symbolic => |target| try map.put(arena, target, where),
        .direct => {},
    };
    for ([_][]const u8{ "rebase-apply/head-name", "rebase-merge/head-name" }) |sub| {
        const text = (try state_file.read(arena, r.io, dir, sub)) orelse continue;
        // `get_branch`: one newline off the end.
        const name = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
        if (std.mem.startsWith(u8, name, "refs/heads/")) try map.put(arena, name, where);
        break;
    }
    if (try state_file.read(arena, r.io, dir, "BISECT_START")) |text| {
        const name = std.mem.trim(u8, text, " \t\r\n");
        // A bisection started from a detached `HEAD` names a commit.
        if (name.len != 0) {
            if (Oid.parse(r.repo.objectFormat(), name)) |_| {} else |_| {
                try map.put(arena, try arena.print("refs/heads/{s}", .{name}), where);
            }
        }
    }
    if (try state_file.read(arena, r.io, dir, "rebase-merge/update-refs")) |text| {
        const records = try parseUpdateRefs(r, text);
        for (records.items) |rec| try map.put(arena, rec.ref, where);
    }
}

/// `merge`: a merge commit of `HEAD` and the label it names, with the
/// original merge's message when there was one, reused as it is when
/// nothing about it would change.
fn doMerge(r: *Run, item: todo.Item) Error!?Outcome {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    var h = try r.head();
    defer h.deinit(gpa);
    const head_oid = h.oid orelse return error.UnbornBranch;

    // The labels, then optionally `#` and the oneline.
    var arg = item.arg;
    var oneline: ?[]const u8 = null;
    if (std.mem.find(u8, arg, " #")) |at| {
        oneline = std.mem.trim(u8, arg[at + 2 ..], " \t");
        arg = arg[0..at];
    } else if (std.mem.startsWith(u8, arg, "#")) {
        oneline = std.mem.trim(u8, arg[1..], " \t");
        arg = "";
    }
    var names = std.mem.tokenizeAny(u8, arg, " \t");
    const name = names.next() orelse return error.UnknownLabel;
    var merge_heads: std.ArrayList(Oid) = .empty;
    try merge_heads.append(r.arena, try lookupLabel(r, name));
    while (names.next()) |more| try merge_heads.append(r.arena, try lookupLabel(r, more));
    const merge_head = merge_heads.items[0];

    if (item.commit) |original| {
        if (try reuseMerge(r, h, original, merge_heads.items)) return null;
    }

    var author = r.options.who;
    if (item.commit) |original| {
        const source = try readSource(r, original);
        author = source.commit.author;
        try r.msg.appendSlice(r.arena, message.fromSubject(source.commit.message));
    } else {
        try r.msg.appendSlice(r.arena, oneline orelse try mergeSubject(r.arena, arg, merge_heads.items.len));
    }
    r.have_message = true;
    try writeAuthorScript(r, author);
    try state_file.write(io, repo.gitDirectory(), "MERGE_MSG", r.msg.items);

    // An octopus is git's `git merge -s octopus --no-ff -F MERGE_MSG` of
    // the heads, named by their object names.
    if (merge_heads.items.len > 1) return mergeAsGitMerge(r, item, merge_heads.items, author);

    const bases = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = head_oid, .b = merge_head }, .{});
    defer gpa.free(bases);
    if (bases.len != 0 and bases[0].eql(merge_head)) return null;

    // With strategy options git hands the merge to `git merge -s ort -X...
    // --no-ff -F MERGE_MSG <commit>`, which names it by its object name and
    // does the rest its own way.
    if (r.options.strategy_options.len != 0) return mergeAsGitMerge(r, item, &.{merge_head}, author);

    try repo.refStore().special().write(repo.allocator(), io, .merge_head, try r.hex(merge_head));
    try state_file.write(io, repo.gitDirectory(), "MERGE_MODE", "no-ff");

    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    // The bases oldest first, as git hands them to its recursive merge.
    const reversed = try r.arena.alloc(Oid, bases.len);
    for (bases, 0..) |base, i| reversed[bases.len - 1 - i] = base;
    const style = r.options.conflict_style orelse try merge.configuredStyle(repo.configuration());
    const ref_name = try r.arena.print("refs/rewritten/{s}", .{name});
    var outcome = try three_way.applyCommits(gpa, io, repo, .{ .index = index, .ours = head_oid, .theirs = merge_head, .bases = reversed }, .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .theirs = if (lookupRewritten(r, name)) ref_name else name },
            .algorithm = .histogram,
        },
        .strategy_options = r.options.strategy_options,
        .filters = r.options.filters,
        .programs = r.options.programs,
        .blocked = r.options.blocked,
    });
    defer outcome.deinit();
    try locked_index.commit(io);
    try repo.refStore().root().write(repo.allocator(), io, .auto_merge, outcome.auto_merge);
    if (!outcome.isClean()) {
        const copied = try r.arena.dupe(three_way.Conflict, outcome.conflicts);
        for (copied) |*c| c.path = try r.arena.dupe(u8, c.path);
        r.conflicts = copied;
        _ = try rerere.afterStop(gpa, io, repo, .{ .arena = r.arena, .autoupdate = r.options.rerere_autoupdate });
        if (item.commit) |original| try errorWithPatch(r, original, false) else if (r.have_message and !r.hasState("message")) try r.state("message", r.msg.items);
        _ = r.items.orderedRemove(0);
        return finishOutcome(r, .stopped, .conflict, item.commit);
    }

    var text: []const u8 = try message.cleanup(r.arena, r.msg.items, message.uncut(try message.sequencerCleanup(repo.configuration()) orelse message.sequencerDefault(r.options.signoff)), r.comment);
    if (item.edit_message) text = try edited(r, .merge, text);
    const made = try repo.writeCommit(io, .{
        .tree = outcome.tree.?,
        .parents = &.{ head_oid, merge_head },
        .author = author,
        .committer = r.options.who,
        .message = text,
        .signing = r.options.signing,
    }, .{ .diagnostic = r.options.diagnostic });
    const log = try r.reflogMessage("merge", firstLine(text));
    try head_mod.advance(io, repo, h, made, .{ .who = r.options.who, .message = log });
    // git makes this commit with `git commit`, whose clean-up takes
    // `AUTO_MERGE` with the merge's other files and runs rerere.
    try rerere.afterCommit(gpa, io, repo);
    if (item.commit) |original| try recordInRewritten(r, original, peekCommand(r, 1));
    return null;
}

/// The original merge, reused as it is when its parents are exactly `HEAD`
/// and `merge_heads`: `HEAD` fast-forwards to it. Whether it was.
fn reuseMerge(r: *Run, h: head_mod.Head, original: Oid, merge_heads: []const Oid) Error!bool {
    const io = r.io;
    const repo = r.repo;
    // `doMerge` refused an unborn branch already.
    const head_oid = h.oid.?;
    const source = try readSource(r, original);
    const parents = source.commit.parents;
    if (!r.allow_ff or parents.len != 1 + merge_heads.len or !parents[0].eql(head_oid) or !sameOids(parents[1..], merge_heads)) return false;
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    const head_tree = try repo.commitTree(io, head_oid);
    var outcome = try three_way.fastForward(r.gpa, io, repo, .{ .index = index, .old = head_tree, .new = source.commit.tree }, .{ .blocked = r.options.blocked });
    outcome.deinit();
    try locked_index.commit(io);
    try head_mod.advance(io, repo, h, original, .{ .who = r.options.who, .message = "rebase: fast-forward" });
    try recordInRewritten(r, original, peekCommand(r, 1));
    return true;
}

/// The subject git gives a merge with no original and no oneline: of the
/// branch, or the branches, `labels` names.
fn mergeSubject(arena: Allocator, labels: []const u8, count: usize) Allocator.Error![]const u8 {
    assert(count != 0);
    const names = std.mem.trim(u8, labels, " \t");
    if (count > 1) return arena.print("Merge branches '{s}'", .{names});
    var first = std.mem.tokenizeAny(u8, names, " \t");
    // A count of one is one label, there to take.
    return arena.print("Merge branch '{s}'", .{first.next().?});
}

/// `do_merge` with a strategy: the merge `git merge` makes of it.
fn mergeAsGitMerge(r: *Run, item: todo.Item, merge_heads: []const Oid, author: object.Signature) Error!?Outcome {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
    const targets = try r.arena.alloc(merging.Target, merge_heads.len);
    for (merge_heads, targets) |oid, *target| target.* = .{ .oid = oid, .name = try r.hex(oid), .kind = .commit };
    var outcome = try merging.startHeads(gpa, io, repo, targets, .{
        .who = r.options.who,
        .author = author,
        .fast_forward = .never,
        .message = r.msg.items,
        .strategy_options = r.options.strategy_options,
        .conflict_style = r.options.conflict_style,
        .filters = r.options.filters,
        .programs = r.options.programs,
        .signing = r.options.signing,
        .diagnostic = r.options.diagnostic,
        .hooks = r.options.hooks,
        .blocked = r.options.blocked,
        .rerere_autoupdate = r.options.rerere_autoupdate,
    });
    defer outcome.deinit();
    if (outcome.result == .conflicted) {
        const copied = try r.arena.dupe(three_way.Conflict, outcome.conflicts);
        for (copied) |*c| c.path = try r.arena.dupe(u8, c.path);
        r.conflicts = copied;
    }
    if (item.commit) |original| try recordInRewritten(r, original, peekCommand(r, 1));
    if (outcome.result == .conflicted) {
        if (item.commit) |original| try errorWithPatch(r, original, false) else if (r.have_message and !r.hasState("message")) try r.state("message", r.msg.items);
        _ = r.items.orderedRemove(0);
        return finishOutcome(r, .stopped, .conflict, item.commit);
    }
    return null;
}

fn sameOids(a: []const Oid, b: []const Oid) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn lookupRewritten(r: *Run, name: []const u8) bool {
    const ref = r.arena.print("refs/rewritten/{s}", .{name}) catch return false;
    const found = r.repo.refStore().read(r.gpa, r.io, ref) catch return false;
    if (found) |f| switch (f) {
        .symbolic => |t| r.gpa.free(t),
        .direct => {},
    };
    return found != null;
}

//=========================================================================
// Finishing, continuing, skipping, aborting
//=========================================================================

/// `move_to_original_branch`: the branch moved to `head_oid`, `HEAD`
/// naming it again, with git's `(finish)` lines.
fn returnToBranch(r: *Run, tip: Tip, onto: Oid, head_oid: Oid) Error!void {
    const branch = tip.head_name orelse return;
    const branch_log = try r.reflogMessage("finish", try r.arena.print("{s} onto {s}", .{ branch, try r.hex(onto) }));
    try head_mod.moveBranch(r.io, r.repo, branch, .{ .expected = .{ .matches = tip.orig_head }, .new = head_oid }, .{ .who = r.options.who, .message = branch_log });
    const head_log = try r.reflogMessage("finish", try r.arena.print("returning to {s}", .{branch}));
    try head_mod.attach(r.io, r.repo, branch, head_oid, .{ .who = r.options.who, .message = head_log });
}

/// `<old> <new>` lines: a rewritten list.
fn parseRewritten(r: *Run, text: []const u8) Error!std.ArrayList(Rewritten) {
    var rewritten: std.ArrayList(Rewritten) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.findScalar(u8, line, ' ') orelse return error.MalformedState;
        try rewritten.append(r.arena, .{
            .old = Oid.parse(r.repo.objectFormat(), line[0..space]) catch return error.MalformedState,
            .new = Oid.parse(r.repo.objectFormat(), line[space + 1 ..]) catch return error.MalformedState,
        });
    }
    return rewritten;
}

/// The end of the sheet: the branch moves to where `HEAD` is, `HEAD` names
/// it again, the refs `update-ref` lines asked for move, and the state goes.
fn finish(r: *Run) Error!Outcome {
    const io = r.io;
    const repo = r.repo;
    const tip = try readBasicState(r);
    const onto = try ontoOf(r);
    try returnToBranch(r, tip, onto, try r.headOid());
    try flushRewritten(r);
    var rewritten: std.ArrayList(Rewritten) = .empty;
    if (try r.readState("rewritten-list")) |text| rewritten = try parseRewritten(r, text);
    // `git notes copy --for-rewrite=rebase` with `rewritten-list`, whose
    // failure git does not mind; then `post-rewrite`, told on its standard
    // input what that list says, once the branch has moved.
    if (rewritten.items.len != 0) {
        const pairs = try r.arena.alloc(hooks_mod.Runner.Rewrite, rewritten.items.len);
        for (pairs, rewritten.items) |*pair, one| pair.* = .{ .old = one.old, .new = one.new };
        notes.copyForRewrite(r.gpa, io, repo, pairs, .{ .command = .rebase, .who = r.options.who }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
    if (r.options.hooks) |runner| {
        if (try r.readState("rewritten-list")) |list| {
            if (list.len != 0) _ = try runner.run(io, "post-rewrite", .{ .args = &.{"rebase"}, .input = list });
        }
    }
    if (try r.readState("update-refs")) |text| {
        const records = try parseUpdateRefs(r, text);
        for (records.items) |rec| {
            if (rec.after.isZero()) continue;
            try head_mod.moveBranch(io, repo, rec.ref, .{ .expected = .{ .matches = rec.before }, .new = rec.after }, .{ .who = r.options.who, .message = "rewritten during rebase" });
        }
    }
    // The autostash comes back once `post-rewrite` has run, as git's does.
    r.restored = try restoreAutostash(r, true);
    try removeState(r);
    var out = finishOutcome(r, .done, null, null);
    out.rewritten = rewritten.items;
    return out;
}

//=========================================================================
// The apply backend
//=========================================================================

/// The backend a rebase starts with: git's choice among `--apply`,
/// `--merge`, the options only the merge backend has, and `rebase.backend`.
fn backendOf(r: *Run) Error!Backend {
    const o = r.options;
    const merge_only = o.interactive or o.todo != null or o.exec.len != 0 or o.autosquash == true or o.update_refs == true or
        o.empty != null or o.reapply_cherry_picks or o.strategy_options.len != 0 or !o.keep_empty or
        (o.rebase_merges != null and o.rebase_merges.? != .off);
    const backend: Backend = blk: {
        if (o.backend == .apply) {
            if (merge_only) return error.RequiresMergeBackend;
            if (o.rebase_merges == null and r.merges != .off) return error.ApplyWithRebaseMerges;
            if (o.update_refs == null and r.update_refs) return error.ApplyWithUpdateRefs;
            break :blk .apply;
        }
        if (merge_only or r.merges != .off) break :blk .merge;
        if (o.backend) |b| break :blk b;
        const configured = r.repo.configuration().get("rebase.backend") orelse break :blk .merge;
        if (std.mem.eql(u8, configured, "merge")) break :blk .merge;
        if (std.mem.eql(u8, configured, "apply")) break :blk .apply;
        return error.UnknownRebaseBackend;
    };
    // "--reschedule-failed-exec requires --exec or --interactive".
    if (backend == .apply and o.reschedule_failed_exec == true) return error.RequiresMergeBackend;
    return backend;
}

/// The apply backend after the checks every rebase makes: `HEAD` detached
/// at `onto`; a branch with no commits of its own fast-forwarded; else the
/// branch's commits written as git's `format-patch -k --full-index
/// --cherry-pick --right-only --no-renames --pretty=mboxrd --topo-order`
/// writes them and applied by `am --rebasing`, which stops where a commit
/// does not apply.
fn startApply(r: *Run, upstream: Oid, tip: Tip, onto: Oid, onto_name: []const u8) Error!Outcome {
    const gpa = r.gpa;
    const io = r.io;
    const repo = r.repo;
    if (!try prepare(r, upstream, tip, onto)) {
        try finishApplyState(r);
        return finishOutcome(r, .up_to_date, null, null);
    }
    try checkoutOnto(r, onto, tip.orig_head, r.options.onto_name orelse onto_name);
    const branch_base = blk: {
        const bases = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = onto, .b = tip.orig_head }, .{});
        defer gpa.free(bases);
        break :blk if (bases.len == 1) bases[0] else null;
    };
    if (branch_base != null and branch_base.?.eql(tip.orig_head)) return finishApply(r, tip, onto);

    var diff_options = try diff.configured(repo.configuration(), .{});
    diff_options.full_index = true;
    var series = try format_patch.format(gpa, io, repo, .{
        .upstream = upstream,
        .tip = tip.orig_head,
        .exclude = if (r.restrict) |fork| &.{fork} else &.{},
    }, .{
        .keep_subject = true,
        .mboxrd = true,
        .ignore_if_in_upstream = true,
        .renames = .off,
        .topo_order = true,
        .diff = diff_options,
    });
    defer series.deinit();
    var mbox: Io.Writer.Allocating = .init(r.arena);
    series.writeMbox(&mbox.writer) catch return error.OutOfMemory;
    var applied = try am.start(gpa, io, repo, &.{mbox.written()}, try amOptions(r));
    defer applied.deinit();
    if (applied.stopped) |stop| {
        try writeApplyState(r, tip, onto);
        return stoppedApply(r, stop);
    }
    return finishApply(r, tip, onto);
}

/// What `am` is run with for a rebase: git's `run_am`.
fn amOptions(r: *Run) Error!am.Options {
    return .{
        .committer = r.options.who,
        .rebasing = true,
        .mboxrd = true,
        .reflog_action = try r.arena.print("{s} (pick)", .{r.action()}),
        .hooks = r.options.hooks,
        .signing = r.options.signing,
        .signoff = r.options.signoff,
    };
}

/// `rebase_write_basic_state` into `rebase-apply`, once `am` has stopped.
fn writeApplyState(r: *Run, tip: Tip, onto: Oid) Error!void {
    try r.state("head-name", try r.arena.print("{s}\n", .{tip.head_name orelse "detached HEAD"}));
    try r.state("onto", try r.arena.print("{s}\n", .{try r.hex(onto)}));
    try r.state("orig-head", try r.arena.print("{s}\n", .{try r.hex(tip.orig_head)}));
    if (r.options.rerere_autoupdate) |on| try r.state("allow_rerere_autoupdate", if (on) "--rerere-autoupdate\n" else "--no-rerere-autoupdate\n");
    if (r.options.signing.sign == .always) try r.state("gpg_sign_opt", try r.arena.print("-S{s}\n", .{r.options.signing.key orelse ""}));
    if (r.options.signoff) try r.state("signoff", "--signoff\n");
}

fn stoppedApply(r: *Run, stop: am.Stop) Error!Outcome {
    _ = stop;
    const at = try r.repo.refStore().root().read(r.gpa, r.io, .rebase_head);
    return finishOutcome(r, .stopped, .conflict, at);
}

/// `move_to_original_branch` and `finish_rebase`: the branch moved to
/// `HEAD` and `HEAD` naming it again, then the state removed and the
/// autostash brought back.
fn finishApply(r: *Run, tip: Tip, onto: Oid) Error!Outcome {
    try returnToBranch(r, tip, onto, try r.headOid());
    var rewritten: std.ArrayList(Rewritten) = .empty;
    if (try r.readState("rewritten")) |text| rewritten = try parseRewritten(r, text);
    try finishApplyState(r);
    var out = finishOutcome(r, .done, null, null);
    out.rewritten = rewritten.items;
    return out;
}

fn finishApplyState(r: *Run) Error!void {
    try r.repo.refStore().root().delete(r.repo.allocator(), r.io, .rebase_head);
    try r.repo.refStore().root().delete(r.repo.allocator(), r.io, .auto_merge);
    r.restored = try restoreAutostash(r, true);
    try removeState(r);
}

/// `--continue` for the apply backend: nothing left unstaged, then `am`
/// commits what is staged and goes on.
fn proceedApply(r: *Run) Error!Outcome {
    if (try hasUnstagedChanges(r)) return error.UnstagedChanges;
    const tip = try readBasicState(r);
    const onto = try ontoOf(r);
    var applied = try am.proceed(r.gpa, r.io, r.repo, try amOptions(r));
    defer applied.deinit();
    if (applied.stopped) |stop| return stoppedApply(r, stop);
    return finishApply(r, tip, onto);
}

/// `--skip` for the apply backend: the index and the working tree back to
/// `HEAD`, and `am --skip`.
fn skipApply(r: *Run) Error!Outcome {
    const tip = try readBasicState(r);
    const onto = try ontoOf(r);
    var applied = try am.skip(r.gpa, r.io, r.repo, try amOptions(r));
    defer applied.deinit();
    if (applied.stopped) |stop| return stoppedApply(r, stop);
    return finishApply(r, tip, onto);
}

/// git's `has_unstaged_changes`, submodules aside: a path whose working
/// tree differs from the index, or that is still conflicted.
fn hasUnstagedChanges(r: *Run) Error!bool {
    var index = try r.repo.openIndex(r.io);
    defer index.deinit();
    const wt = r.repo.workDirectory() orelse return error.BareRepository;
    var rules = try r.repo.worktreeRules();
    var attrs = try r.repo.loadAttrs(r.io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    var status = try worktree.status(r.gpa, r.io, wt, .{ .index = &index, .db = r.repo.objectDatabase() }, .{
        .rules = rules,
        .head_tree = try r.repo.headTree(r.io),
        .untracked = .no,
    });
    defer status.deinit();
    for (status.entries) |entry| {
        if (entry.submodule != null) continue;
        if (entry.conflicted) return true;
        switch (entry.unstaged) {
            .unmodified, .untracked, .ignored => {},
            else => return true,
        }
    }
    return false;
}

/// Load a rebase in progress, whoever started it, its sheet and all.
fn loadRun(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Run {
    var r = try loadBareRun(gpa, io, repo, options);
    errdefer freeRun(&r);
    _ = try readBasicState(&r);
    const text = (try r.readState("git-rebase-todo")) orelse "";
    var context: sequencer.ResolverContext = .{ .repo = repo, .io = io };
    const list = try todo.parse(r.arena, text, context.resolver(), .{ .comment = r.comment, .rebase = true, .fixup_first_ok = true });
    try r.items.appendSlice(r.arena, list.items.items);
    // `read_populate_todo`: how many are done is what `done` lists, or
    // none where it does not parse; `msgnum` is only written.
    if (try r.readState("done")) |done| {
        if (todo.parse(r.arena, done, context.resolver(), .{ .comment = r.comment, .rebase = true, .fixup_first_ok = true })) |parsed| {
            r.done_nr = countCommands(parsed.items.items);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTodoLine, error.FixupWithoutCommit => r.done_nr = 0,
        }
    }
    // ... and writes the total again, as git's does each time.
    try r.state("end", try r.arena.print("{d}\n", .{r.done_nr + countCommands(r.items.items)}));
    return r;
}

/// A rebase in progress with nothing of its state read: what `--abort`
/// and `--quit` start from, as git's read only what they undo, so a sheet
/// it cannot read does not keep a rebase from being given up.
fn loadBareRun(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Run {
    const backend = backendInProgress(io, repo) orelse return error.NoRebaseInProgress;
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    arena_state.* = .init(gpa);
    errdefer {
        arena_state.deinit();
        gpa.destroy(arena_state);
    }
    var r = try newRun(gpa, io, arena_state, repo, options);
    r.allow_ff = !options.force;
    r.backend = backend;
    return r;
}

/// Continue the rebase that stopped, whoever stopped it: commit what is
/// staged, as git does, and carry on down the sheet.
pub fn proceed(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    diagnostic.reset(options.diagnostic);
    if (backendInProgress(io, repo) == .apply) {
        var r = try loadBareRun(gpa, io, repo, options);
        errdefer freeRun(&r);
        return proceedApply(&r);
    }
    try sequencer.initConfig(repo);
    var r = try loadRun(gpa, io, repo, options);
    errdefer freeRun(&r);
    // A sheet refused for the commits it leaves out is checked again
    // against the one written first.
    if (r.hasState("dropped")) {
        const backup = (try r.readState("git-rebase-todo.backup")) orelse "";
        var context: sequencer.ResolverContext = .{ .repo = repo, .io = io };
        const old = try todo.parse(r.arena, backup, context.resolver(), .{ .comment = r.comment, .rebase = true, .fixup_first_ok = true });
        if (try missingCommits(&r, old.items.items, r.items.items)) return finishOutcome(&r, .stopped, .missing_commits, null);
        try r.removeState("dropped");
    }
    try commitStagedChanges(&r);
    if (r.hasState("stopped-sha")) {
        const text = (try r.readState("stopped-sha")).?;
        // git records it only when it reads as a name, and goes on if not.
        if (state_file.oidHex(repo.objectFormat(), state_file.oneliner(text))) |oid| try recordInRewritten(&r, oid, peekCommand(&r, 0));
    }
    return runLoop(&r);
}

fn freeRun(r: *Run) void {
    const gpa = r.gpa;
    const arena_state = r.arena_state;
    arena_state.deinit();
    gpa.destroy(arena_state);
}

/// `commit_staged_changes`: what `--continue` does with the index before it
/// carries on.
fn commitStagedChanges(r: *Run) Error!void {
    const io = r.io;
    const repo = r.repo;
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (r.options.blocked) |b| b.set(entry.path);
            return error.UnresolvedConflicts;
        }
    }
    // Unstaged changes are refused; staged ones are what gets committed.
    const wt = repo.workDirectory() orelse return error.BareRepository;
    var rules = try repo.worktreeRules();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    var h = try r.head();
    defer h.deinit(r.gpa);
    const head_oid = h.oid orelse return error.UnbornBranch;
    const head_tree = try repo.commitTree(io, head_oid);
    var status = try worktree.status(r.gpa, io, wt, .{ .index = index, .db = repo.objectDatabase() }, .{ .rules = rules, .head_tree = head_tree, .untracked = .no });
    defer status.deinit();
    var staged = false;
    for (status.entries) |entry| {
        if (entry.unstaged != .unmodified) return error.DirtyWorktree;
        if (entry.staged != .unmodified) staged = true;
    }
    const merge_head_text = try repo.refStore().special().readAll(r.arena, io, .merge_head);
    const is_clean = !staged and merge_head_text == null;
    if (!is_clean and !r.hasState("message")) return error.StagedWithoutMessage;

    var amend = false;
    if (try r.readState("amend")) |text| {
        const to_amend = state_file.oidHex(repo.objectFormat(), state_file.oneliner(text)) orelse return error.MalformedState;
        if (!is_clean and !head_oid.eql(to_amend)) return error.DirtyWorktree;
        amend = true;
    }
    if (is_clean) {
        try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
        try state_file.remove(io, repo.gitDirectory(), "MERGE_MSG");
        return;
    }

    const tree = try worktree.writeTree(r.gpa, io, index, repo.objectDatabase());
    try locked_index.commit(io);
    var parents: std.ArrayList(Oid) = .empty;
    if (amend) {
        try parents.appendSlice(r.arena, try parentsOf(r, head_oid));
    } else try parents.append(r.arena, head_oid);
    if (merge_head_text) |text| {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| try parents.append(r.arena, Oid.parse(repo.objectFormat(), std.mem.trim(u8, line, " ")) catch return error.MalformedState);
    }
    // The author the stop recorded; an amend keeps the one it amends.
    var author = r.options.who;
    if (amend) {
        author = (try readSource(r, head_oid)).commit.author;
    } else if (try r.readState("author-script")) |script| {
        // `git commit` with the script's variables in its environment:
        // the date as `parse_date` reads it, whatever git wrote there.
        const recorded = try state_file.AuthorScript.parse(r.arena, script);
        const when = gitdate.parse(recorded.date, .{ .now = gitdate.timestamp(r.options.who.when_secs), .local_offset_minutes = r.options.who.offset_minutes }) orelse return error.InvalidDate;
        author = .{ .name = recorded.name, .email = recorded.email, .when_secs = when.secs, .offset_minutes = @intCast(when.offset_minutes) };
    } else return error.StagedWithoutMessage;
    const proposed = (try r.readState("message")).?;
    // `git commit -n -e -F message`: only the message hooks around it, an
    // editor's as the person's editor left it.
    const commit_hooks = try commit_hooks_mod.Hooks.init(r.arena, io, repo, .{ .runner = r.options.hooks, .verify = false });
    var hook_env: hooksEnv = null;
    var shown = proposed;
    if (commit_hooks.runner) |runner| {
        var e = try commit_hooks.env(r.arena, author);
        e.editor = true;
        hook_env = e;
        try state_file.write(io, repo.gitDirectory(), "COMMIT_EDITMSG", proposed);
        _ = try runner.prepareCommitMsg(io, e, try commit_hooks.path(r.arena, "COMMIT_EDITMSG"), .{ .source = .message, .commit = null });
        shown = (try state_file.read(r.arena, io, repo.gitDirectory(), "COMMIT_EDITMSG")) orelse "";
    }
    const text = try edited(r, .resolved, shown);
    const made = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = parents.items,
        .author = author,
        .committer = r.options.who,
        .message = text,
        .extra = if (amend) try extraHeadersOf(r, head_oid) else &.{},
        .signing = r.options.signing,
    }, .{ .diagnostic = r.options.diagnostic });
    const log = try r.reflogMessage("continue", firstLine(text));
    try head_mod.advance(io, repo, h, made, .{ .who = r.options.who, .message = log });
    try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
    try state_file.remove(io, repo.gitDirectory(), "MERGE_MSG");
    try r.removeState("amend");
    // The commit is `git commit`'s, which records resolutions as it ends.
    try rerere.afterCommit(r.gpa, io, repo);
    if (hook_env) |e| _ = try commit_hooks.runner.?.postCommit(io, e);
    // An amend is `git commit --amend`'s.
    if (amend) try postRewriteAmend(r, commit_hooks.runner, .{ .old = head_oid, .new = made }, author);
}

const hooksEnv = ?hooks_mod.Runner.CommitEnv;

/// Leave out the instruction that stopped, with whatever it changed, and
/// carry on: `--skip`.
pub fn skip(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    diagnostic.reset(options.diagnostic);
    if (backendInProgress(io, repo) == .apply) {
        var r = try loadBareRun(gpa, io, repo, options);
        errdefer freeRun(&r);
        // git's `--skip`: the working tree back to `HEAD`, the branch state
        // gone, then `am --skip`.
        try rerere.clear(gpa, io, repo);
        var locked_index = try repo.lockIndex(io);
        defer locked_index.deinit(io);
        try reset.toTree(gpa, io, repo, .{ .index = &locked_index.index, .tree = try repo.commitTree(io, try r.headOid()), .mode = .hard, .blocked = options.blocked });
        try locked_index.commit(io);
        try merging.removeMergeState(io, repo, options.who);
        return skipApply(&r);
    }
    try sequencer.initConfig(repo);
    {
        var r = try loadRun(gpa, io, repo, options);
        defer freeRun(&r);
        try rerere.clear(gpa, io, repo);
        const current = try r.headOid();
        var locked_index = try repo.lockIndex(io);
        defer locked_index.deinit(io);
        const index = &locked_index.index;
        try reset.toTree(gpa, io, repo, .{ .index = index, .tree = try repo.commitTree(io, current), .mode = .hard, .blocked = options.blocked });
        try locked_index.commit(io);
        try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
        try repo.refStore().root().delete(repo.allocator(), io, .revert_head);
        try merging.removeMergeState(io, repo, options.who);
    }
    return proceed(gpa, io, repo, options);
}

/// Stop the rebase and put the branch, `HEAD`, the index and the working
/// tree back where they were when it began: `--abort`. The autostash is
/// then brought back: what became of it, or `null` when there was none.
/// Of `options`, `who`, `hooks`, `filters` and `programs` are read.
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!?stash.Restored {
    const who = options.who;
    var r = try loadBareRun(gpa, io, repo, options);
    defer freeRun(&r);
    try rerere.clear(gpa, io, repo);
    const tip = try readBasicState(&r);
    var h = try r.head();
    defer h.deinit(gpa);
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    try reset.toTree(gpa, io, repo, .{ .index = index, .tree = try repo.commitTree(io, tip.orig_head), .mode = .hard, .blocked = null });
    try locked_index.commit(io);
    const target = tip.head_name orelse try r.hex(tip.orig_head);
    const log = try r.reflogMessage("abort", try r.arena.print("returning to {s}", .{target}));
    if (tip.head_name) |branch| {
        try head_mod.attach(io, repo, branch, h.oid, .{ .who = who, .message = log });
    } else {
        try head_mod.advance(io, repo, h, tip.orig_head, .{ .who = who, .message = log });
    }
    try repo.refStore().root().delete(repo.allocator(), io, .cherry_pick_head);
    try repo.refStore().root().delete(repo.allocator(), io, .revert_head);
    try merging.removeMergeState(io, repo, who);
    try repo.refStore().root().delete(repo.allocator(), io, .rebase_head);
    const restored = try restoreAutostash(&r, true);
    try removeState(&r);
    return restored;
}

/// Forget the rebase and leave `HEAD`, the index and the working tree as
/// they are: `--quit`. The autostash goes on the stash list unapplied:
/// `.stored`, or `null` when there was none. Of `options`, `who` and
/// `hooks` are read.
pub fn quit(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!?stash.Restored {
    var r = try loadBareRun(gpa, io, repo, options);
    defer freeRun(&r);
    const restored = try restoreAutostash(&r, false);
    try removeState(&r);
    return restored;
}

//=========================================================================
// Tests
//=========================================================================

test "fuzz: any bytes are an update-refs file or a named error" {
    try shakedown.check(std.testing.allocator, {}, fuzzUpdateRefs, .{});
}

fn fuzzUpdateRefs(_: void, case: *shakedown.Case) anyerror!void {
    var input: [256]u8 = undefined;
    const text = input[0..shakedown.gen.intRange(case.source, usize, 0, input.len)];
    case.source.bytes(text);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = parseUpdateRefsText(arena.allocator(), .sha1, text) catch |err| switch (err) {
        error.MalformedState => return,
        error.OutOfMemory => return err,
    };
}
