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
const sequencer = @import("sequencer.zig");
const patchid = @import("patchid.zig");
const revwalk = @import("revwalk.zig");
const diff = @import("diff.zig");
const program = @import("program.zig");
const config_mod = @import("config.zig");
const repo_mod = @import("repo.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const worktrees = @import("worktrees.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a rebase.
pub const Error = error{
    /// `.git/rebase-merge` or `.git/rebase-apply` is there already.
    RebaseInProgress,
    /// There is no rebase to continue, skip or abort.
    NoRebaseInProgress,
    /// The rebase git left in `.git/rebase-apply` is the apply backend's,
    /// which this release does not continue.
    ApplyBackendInProgress,
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
    /// `commit.gpgSign`, or a rebase started with `-S`, asks for signed
    /// commits.
    SigningRequested,
    /// A state file does not say what git writes there.
    MalformedState,
    /// A label or commit a `reset` or `merge` names does not resolve.
    UnknownLabel,
    /// A `merge` line names more than one commit to merge.
    OctopusMerge,
    /// The rebase names a merge strategy other than `ort` or `recursive`.
    UnsupportedStrategy,
    /// The branch given does not name a branch or a commit.
    NotACommit,
    /// The commit is a merge; only `merge` and `drop` take one.
    MergeCommit,
    /// The message left after cleanup is empty.
    EmptyMessage,
    /// A `merge` line's two sides have more than one merge base.
    ConflictingMergeBases,
} || sequencer.Error || program.Error || patchid.Error || revwalk.Error || worktrees.Error;

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
    /// The sheet to work through in place of the one git would write: an
    /// interactive rebase, with the sheet a person would have left in the
    /// editor. `plan` gives the sheet to start from.
    todo: ?[]const u8 = null,
    /// `--interactive` with no sheet of its own: the generated sheet as it
    /// is, with an interactive rebase's defaults.
    interactive: bool = false,
    /// Move `fixup!`, `squash!` and `amend!` commits after their targets.
    autosquash: bool = false,
    /// Add `update-ref` lines for the other branches that point at the
    /// replayed commits, so they move with them: `--update-refs`. git's
    /// `rebase.updateRefs` is the caller's to read.
    update_refs: bool = false,
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
    /// `-X ours` or `-X theirs`.
    favor: merge.Favor = .none,
    /// `null` asks `merge.conflictStyle`.
    conflict_style: ?merge.ConflictStyle = null,
    /// `--exec`: commands to run after each commit.
    exec: []const []const u8 = &.{},
    /// Put a failed `exec` back on the sheet: `--reschedule-failed-exec`.
    reschedule_failed_exec: bool = false,
    /// The permission to run `exec` lines.
    programs: ?program.Programs = null,
    /// Where messages a person would edit go.
    messages: ?Messages = null,
    /// Where a refusal writes the path that caused it.
    blocked: ?*threeway.Blocked = null,
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
};

/// One rewritten commit: what `post-rewrite` is told.
pub const Rewritten = struct { old: Oid, new: Oid };

/// What a rebase did.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    result: Result,
    /// Why it stopped, when it did.
    stopped: ?Stop = null,
    /// The commit it stopped at, when a commit was being applied.
    stopped_at: ?Oid = null,
    /// The `exec` line that failed, and how it exited.
    exec: ?[]const u8 = null,
    exec_status: u8 = 0,
    /// The paths left conflicted, sorted.
    conflicts: []const threeway.Conflict = &.{},
    /// When the rebase finished: every commit it rewrote and what it became.
    rewritten: []const Rewritten = &.{},

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

const state_dir = "rebase-merge";

fn path(comptime name: []const u8) []const u8 {
    return state_dir ++ "/" ++ name;
}

/// Whether a rebase is waiting: `.git/rebase-merge` is there.
pub fn inProgress(io: Io, repo: *Repository) bool {
    return head_mod.stateExists(io, repo.git_dir, state_dir);
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
    abbrev_len: usize,
    allow_ff: bool,
    empty: Empty,
    /// What is left to do, the current instruction first.
    items: std.ArrayList(todo.Item) = .empty,
    done_nr: usize = 0,
    /// `current-fixups`: the fixups and squashes in the chain so far.
    fixups: std.ArrayList(u8) = .empty,
    fixup_count: usize = 0,
    /// The message being built for the current pick.
    msg: std.ArrayList(u8) = .empty,
    have_message: bool = false,
    conflicts: []const threeway.Conflict = &.{},

    fn state(r: *Run, comptime name: []const u8, bytes: []const u8) Error!void {
        try head_mod.writeState(r.io, r.repo.git_dir, path(name), bytes);
    }

    fn readState(r: *Run, comptime name: []const u8) Error!?[]u8 {
        return head_mod.readState(r.arena, r.io, r.repo.git_dir, path(name));
    }

    fn removeState(r: *Run, comptime name: []const u8) Error!void {
        try head_mod.removeState(r.io, r.repo.git_dir, path(name));
    }

    fn hasState(r: *Run, comptime name: []const u8) bool {
        return head_mod.stateExists(r.io, r.repo.git_dir, path(name));
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
        return r.arena.dupe(u8, try abbrev.unique(r.io, &r.repo.odb, oid, r.abbrev_len, &buf));
    }

    fn head(r: *Run) Error!head_mod.Head {
        return head_mod.read(r.gpa, r.io, r.repo);
    }

    fn headOid(r: *Run) Error!Oid {
        var h = try r.head();
        defer h.deinit(r.gpa);
        return h.oid orelse error.UnbornBranch;
    }

    fn reflogMessage(r: *Run, sub: []const u8, tail: ?[]const u8) Error![]const u8 {
        if (tail) |t| return std.fmt.allocPrint(r.arena, "rebase ({s}): {s}", .{ sub, t });
        return std.fmt.allocPrint(r.arena, "rebase ({s})", .{sub});
    }
};

fn newRun(gpa: Allocator, arena_state: *std.heap.ArenaAllocator, io: Io, repo: *Repository, options: Options) Error!Run {
    if (repo.config.getBool("commit.gpgsign", false) catch false) return error.SigningRequested;
    const interactive = options.interactive or options.todo != null;
    return .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .arena_state = arena_state,
        .io = io,
        .repo = repo,
        .options = options,
        .comment = message.commentString(repo.config.get("core.commentchar"), ""),
        .abbrev_len = abbrev.defaultLength(&repo.config, &repo.odb),
        .allow_ff = !options.force and !options.signoff,
        .empty = options.empty orelse if (interactive) .stop else .drop,
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
        const found = try w.repo.odb.read(w.io, oid);
        defer w.repo.odb.gpa.free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(w.gpa, w.repo.kind, found.bytes);
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
    const parent_tree = if (node.parents.len != 0) (try w.load(node.parents[0])).tree else try w.repo.odb.write(w.io, .tree, "");
    return parent_tree.eql(node.tree);
}

/// The sheet git writes for `upstream...orig_head`: `pick <name> # <subject>`
/// for each commit to replay, `# empty` after one that was empty to begin
/// with.
fn makeScript(r: *Run, upstream: Oid, orig_head: Oid) Error![]todo.Item {
    var w: Walker = .{ .gpa = r.gpa, .arena = r.arena, .io = r.io, .repo = r.repo };
    const sides = try symmetricDifference(&w, upstream, orig_head);

    // Commits upstream already has, by patch id.
    var same: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
    if (!r.options.reapply_cherry_picks and sides.left.len != 0 and sides.right.len != 0) {
        var ids: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, void) = .empty;
        for (sides.left) |oid| {
            if ((try w.load(oid)).parents.len > 1) continue;
            const id = (try patchid.ofCommit(r.gpa, r.io, &r.repo.odb, oid)) orelse continue;
            try ids.put(r.arena, id.bytes, {});
        }
        for (sides.right) |oid| {
            if ((try w.load(oid)).parents.len > 1) continue;
            const id = (try patchid.ofCommit(r.gpa, r.io, &r.repo.odb, oid)) orelse continue;
            if (ids.contains(id.bytes)) try same.put(r.arena, oid.bytes, {});
        }
    }

    const ordered = try graphOrderOldestFirst(&w, sides.right);
    var items: std.ArrayList(todo.Item) = .empty;
    for (ordered) |oid| {
        const node = try w.load(oid);
        if (node.parents.len > 1) continue;
        const empty = try originallyEmpty(&w, oid);
        if (!empty and same.contains(oid.bytes)) continue;
        if (empty and !r.options.keep_empty) continue;
        const found = try r.repo.odb.read(r.io, oid);
        defer r.repo.odb.gpa.free(found.bytes);
        var commit = try object.Commit.parse(r.gpa, r.repo.kind, found.bytes);
        defer commit.deinit();
        const subject = try message.onelineSubject(r.arena, commit.message);
        const arg = if (empty)
            try std.fmt.allocPrint(r.arena, "{s} {s} empty", .{ r.comment, subject })
        else
            try std.fmt.allocPrint(r.arena, "{s} {s}", .{ r.comment, subject });
        try items.append(r.arena, .{ .command = .pick, .commit = oid, .arg = arg });
    }
    return items.items;
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
        const found = try r.repo.odb.read(r.io, commit_oid);
        defer r.repo.odb.gpa.free(found.bytes);
        var commit = try object.Commit.parse(r.gpa, r.repo.kind, found.bytes);
        defer commit.deinit();
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
            } else if (std.mem.indexOfScalar(u8, p, ' ') == null) found_name: {
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
        const full = try std.fmt.allocPrint(r.arena, "refs/heads/{s}", .{name});
        if (try r.repo.refs.resolve(r.gpa, r.io, full)) |resolved| {
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
    var index = try r.repo.openIndex(r.io);
    defer index.deinit();
    const wt = r.repo.work_dir orelse return error.BareRepository;
    var rules = r.repo.worktreeRules();
    var attrs = try r.repo.loadAttrs(r.io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    const head_tree = try r.repo.headTree(r.io);
    var status = try worktree.status(r.gpa, r.io, wt, &index, &r.repo.odb, .{
        .rules = rules,
        .head_tree = head_tree,
        .untracked = .no,
    });
    defer status.deinit();
    if (!status.isClean()) {
        if (r.options.blocked) |b| b.set(status.entries[0].path);
        return error.DirtyWorktree;
    }
}

/// The sheet a rebase of the current branch onto `upstream` would work
/// through, as git gives it to a person to edit: short object names, the
/// subjects after them, and git's help below. Edit it and hand it back as
/// `Options.todo`. The result is the caller's.
pub fn plan(gpa: Allocator, io: Io, repo: *Repository, upstream: Oid, options: Options) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r = try newRun(gpa, &arena_state, io, repo, options);
    const tip = try resolveTip(&r);
    var items = try makeScript(&r, upstream, tip.orig_head);
    if (items.len == 0) {
        const noop = try r.arena.alloc(todo.Item, 1);
        noop[0] = .{ .command = .noop };
        items = noop;
    }
    if (options.update_refs) items = try addUpdateRefCommands(&r, items, false);
    if (options.autosquash) items = try rearrangeSquash(&r, items);
    items = try addExecCommands(&r, items, options.exec);
    const onto = options.onto orelse upstream;
    return try sheetText(&r, gpa, items, upstream, onto, tip.orig_head, true);
}

/// The sheet as git writes it for a person: the instructions and the
/// help. `short` shortens the object names.
fn sheetText(r: *Run, gpa: Allocator, items: []const todo.Item, upstream: Oid, onto: Oid, orig_head: Oid, short: bool) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const Shorten = struct {
        fn shorten(context: *anyopaque, oid: Oid, buf: *[hash.max_hex_len]u8) []const u8 {
            const run: *Run = @ptrCast(@alignCast(context));
            return abbrev.unique(run.io, &run.repo.odb, oid, run.abbrev_len, buf) catch oid.hex(buf);
        }
    };
    todo.format(&out.writer, items, .{
        .short = if (short) .{ .context = r, .shortenFn = Shorten.shorten } else null,
        .abbreviate_commands = r.repo.config.getBool("rebase.abbreviatecommands", false) catch false,
    }) catch return error.OutOfMemory;
    var count: usize = 0;
    for (items) |item| {
        if (item.command != .comment) count += 1;
    }
    const revisions = try std.fmt.allocPrint(r.arena, "{s}..{s}", .{ try r.short(upstream), try r.short(orig_head) });
    todo.writeHelp(&out.writer, count, revisions, try r.short(onto), r.comment) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Rebase the current branch, or `options.branch`, onto `upstream` (or
/// `options.onto`).
pub fn start(gpa: Allocator, io: Io, repo: *Repository, upstream: Oid, options: Options) Error!Outcome {
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    arena_state.* = .init(gpa);
    errdefer {
        arena_state.deinit();
        gpa.destroy(arena_state);
    }
    var r = try newRun(gpa, arena_state, io, repo, options);

    if (inProgress(io, repo)) return error.RebaseInProgress;
    if (head_mod.stateExists(io, repo.git_dir, "rebase-apply")) return error.ApplyBackendInProgress;
    if (merging.inProgress(io, repo) or sequencer.inProgress(io, repo) != null) return error.OperationInProgress;
    if (options.exec.len != 0 and options.programs == null) return error.ExecNotPermitted;

    const tip = try resolveTip(&r);
    const onto = options.onto orelse upstream;
    const onto_name = options.onto_name orelse try r.hex(onto);
    try requireClean(&r);

    // Already on top of `onto`, with a straight line from it: nothing to do.
    const branch_base = blk: {
        const bases = try revwalk.mergeBases(gpa, io, &repo.odb, onto, tip.orig_head);
        defer gpa.free(bases);
        break :blk if (bases.len == 1) bases[0] else null;
    };
    const preemptive = !options.interactive and options.todo == null and options.exec.len == 0 and
        !options.autosquash and !options.force;
    if (preemptive and branch_base != null and branch_base.?.eql(onto)) up_to_date: {
        const bases = try revwalk.mergeBases(gpa, io, &repo.odb, upstream, tip.orig_head);
        defer gpa.free(bases);
        if (bases.len != 1 or !bases[0].eql(onto)) break :up_to_date;
        if (!try isLinear(&r, onto, tip.orig_head)) break :up_to_date;
        if (options.branch) |name| {
            // Switch to the branch, as git does before it says so.
            try checkoutTip(&r, tip, name);
        }
        // `finish_rebase`, with nothing to finish.
        try head_mod.deleteRef(io, repo, "REBASE_HEAD");
        try head_mod.deleteRef(io, repo, "AUTO_MERGE");
        return finishOutcome(&r, .up_to_date, null, null);
    }

    // The sheet.
    var items: []todo.Item = try makeScript(&r, upstream, tip.orig_head);
    try repo.git_dir.createDirPath(io, state_dir);
    try r.state("interactive", "");
    try writeBasicState(&r, tip, onto);
    if (items.len == 0) {
        const noop = try r.arena.alloc(todo.Item, 1);
        noop[0] = .{ .command = .noop };
        items = noop;
    }
    if (options.update_refs) items = try addUpdateRefCommands(&r, items, true);
    if (options.autosquash) items = try rearrangeSquash(&r, items);
    items = try addExecCommands(&r, items, options.exec);
    if (countCommands(items) == 0) {
        try removeState(&r);
        return error.NothingToDo;
    }
    // What a person would be given, and a backup of it.
    const shown = try sheetText(&r, gpa, items, upstream, onto, tip.orig_head, true);
    defer gpa.free(shown);
    try r.state("git-rebase-todo", shown);
    const backup = try sheetText(&r, gpa, items, upstream, onto, tip.orig_head, false);
    defer gpa.free(backup);
    try r.state("git-rebase-todo.backup", backup);

    // What they left: the caller's sheet, or the one written.
    const sheet = try message.stripSpace(r.arena, options.todo orelse shown, r.comment);
    if (sheet.len == 0) {
        try removeState(&r);
        return error.NothingToDo;
    }
    var context: sequencer.ResolverContext = .{ .repo = repo, .io = io };
    const list = try todo.parse(r.arena, sheet, context.resolver(), .{ .comment = r.comment, .rebase = true });
    try r.items.appendSlice(r.arena, list.items.items);
    // The refs to move follow the sheet as it was left.
    try filterUpdateRefs(&r);
    // A sheet that runs a program is refused before anything moves, not
    // halfway through it.
    if (options.programs == null) {
        for (r.items.items) |item| {
            if (item.command == .exec) {
                try removeState(&r);
                return error.ExecNotPermitted;
            }
        }
    }

    // Full names from here on, and the picks that can stay as they are
    // taken off the front.
    var base = onto;
    if (r.allow_ff) base = try skipUnnecessaryPicks(&r, base);
    try saveTodo(&r, 0);
    try r.state("end", try std.fmt.allocPrint(r.arena, "{d}\n", .{r.done_nr + countCommands(r.items.items)}));

    // Detach at `onto`.
    try checkoutOnto(&r, base, tip.orig_head, onto_name);
    return runLoop(&r);
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
    try r.state("head-name", try std.fmt.allocPrint(r.arena, "{s}\n", .{tip.head_name orelse "detached HEAD"}));
    try r.state("onto", try std.fmt.allocPrint(r.arena, "{s}\n", .{try r.hex(onto)}));
    try r.state("orig-head", try std.fmt.allocPrint(r.arena, "{s}\n", .{try r.hex(tip.orig_head)}));
    if (r.options.favor == .ours or r.options.favor == .theirs) {
        try r.state("strategy_opts", try std.fmt.allocPrint(r.arena, " --{s}\n", .{@tagName(r.options.favor)}));
    }
    if (r.options.signoff) try r.state("signoff", "--signoff\n");
    switch (r.empty) {
        .drop => try r.state("drop_redundant_commits", ""),
        .keep => try r.state("keep_redundant_commits", ""),
        .stop => {},
    }
    if (r.options.reschedule_failed_exec) {
        try r.state("reschedule-failed-exec", "");
    } else try r.state("no-reschedule-failed-exec", "");
}

/// Read back what `writeBasicState` wrote, whoever wrote it.
fn readBasicState(r: *Run) Error!Tip {
    const head_name = (try r.readState("head-name")) orelse return error.MalformedState;
    const orig = (try r.readState("orig-head")) orelse return error.MalformedState;
    const name = std.mem.trimEnd(u8, head_name, "\n");
    if (r.hasState("signoff")) {
        r.options.signoff = true;
        r.allow_ff = false;
    }
    if (r.hasState("drop_redundant_commits")) r.empty = .drop else if (r.hasState("keep_redundant_commits")) r.empty = .keep else r.empty = .stop;
    r.options.reschedule_failed_exec = r.hasState("reschedule-failed-exec");
    if (try r.readState("strategy")) |text| {
        const s = std.mem.trim(u8, text, " \n");
        if (!std.mem.eql(u8, s, "ort") and !std.mem.eql(u8, s, "recursive")) return error.UnsupportedStrategy;
    }
    if (try r.readState("strategy_opts")) |text| {
        var it = std.mem.tokenizeAny(u8, text, " \n'");
        while (it.next()) |opt| {
            if (std.mem.eql(u8, opt, "--ours")) r.options.favor = .ours else if (std.mem.eql(u8, opt, "--theirs")) r.options.favor = .theirs else return error.UnsupportedStrategy;
        }
    }
    if (r.hasState("gpg_sign_opt")) return error.SigningRequested;
    if (try r.readState("current-fixups")) |text| {
        try r.fixups.appendSlice(r.arena, text);
        if (text.len != 0) r.fixup_count = std.mem.count(u8, text, "\n") + 1;
    }
    return .{
        .head_name = if (std.mem.startsWith(u8, name, "refs/")) name else null,
        .orig_head = Oid.parse(r.repo.kind, std.mem.trimEnd(u8, orig, "\n")) catch return error.MalformedState,
    };
}

fn ontoOf(r: *Run) Error!Oid {
    const text = (try r.readState("onto")) orelse return error.MalformedState;
    return Oid.parse(r.repo.kind, std.mem.trimEnd(u8, text, "\n")) catch error.MalformedState;
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
    var index = try r.repo.openIndex(r.io);
    defer index.deinit();
    const from_tree = if (h.oid) |oid| try r.repo.commitTree(r.io, oid) else try r.repo.odb.write(r.io, .tree, "");
    var outcome = try threeway.apply(r.gpa, r.io, r.repo, &index, from_tree, from_tree, try r.repo.commitTree(r.io, base), .{ .blocked = r.options.blocked });
    outcome.deinit();
    try index.write(r.io, r.repo.git_dir, "index", .{});
    try head_mod.writeRef(r.io, r.repo, "ORIG_HEAD", orig_head);
    const log = try r.reflogMessage("start", try std.fmt.allocPrint(r.arena, "checkout {s}", .{onto_name}));
    try head_mod.detach(r.io, r.repo, h.oid, base, .{ .who = r.options.who, .message = log });
}

/// Switch to the branch being rebased when there is nothing else to do:
/// `checkout_up_to_date`.
fn checkoutTip(r: *Run, tip: Tip, name: []const u8) Error!void {
    var h = try r.head();
    defer h.deinit(r.gpa);
    if (h.branch != null and tip.head_name != null and std.mem.eql(u8, h.branch.?, tip.head_name.?)) return;
    var index = try r.repo.openIndex(r.io);
    defer index.deinit();
    const from_tree = try r.repo.commitTree(r.io, h.oid orelse return error.UnbornBranch);
    var outcome = try threeway.apply(r.gpa, r.io, r.repo, &index, from_tree, from_tree, try r.repo.commitTree(r.io, tip.orig_head), .{ .blocked = r.options.blocked });
    outcome.deinit();
    try index.write(r.io, r.repo.git_dir, "index", .{});
    const log = try std.fmt.allocPrint(r.arena, "rebase: checkout {s}", .{name});
    if (tip.head_name) |branch| {
        try head_mod.attach(r.io, r.repo, branch, h.oid, .{ .who = r.options.who, .message = log });
    } else {
        try head_mod.detach(r.io, r.repo, h.oid, tip.orig_head, .{ .who = r.options.who, .message = log });
    }
}

fn removeState(r: *Run) Error!void {
    // The labels a rebase made go with it.
    if (try r.readState("refs-to-delete")) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |name| {
            r.repo.refs.dirFor(name).deleteFile(r.io, name) catch {};
        }
    }
    try r.repo.git_dir.deleteTree(r.io, state_dir);
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
            try r.state("msgnum", try std.fmt.allocPrint(r.arena, "{d}\n", .{r.done_nr}));
        }
        try r.removeState("author-script");
        try head_mod.removeState(r.io, r.repo.git_dir, "MERGE_HEAD");
        try head_mod.deleteRef(r.io, r.repo, "AUTO_MERGE");
        try head_mod.deleteRef(r.io, r.repo, "REBASE_HEAD");
        r.msg.clearRetainingCapacity();
        r.have_message = false;

        switch (item.command) {
            .@"break" => {
                _ = r.items.orderedRemove(0);
                return finishOutcome(r, .stopped, .@"break", null);
            },
            .pick, .reword, .edit, .fixup, .squash => {
                if (try pickOne(r)) |outcome| return outcome;
            },
            .exec => {
                if (try doExec(r, item.arg)) |outcome| return outcome;
            },
            .label => try doLabel(r, item.arg),
            .reset => try doReset(r, item.arg),
            .merge => {
                if (try doMerge(r, item)) |outcome| return outcome;
            },
            .update_ref => try doUpdateRef(r, item.arg),
            .noop, .drop, .comment, .revert => {},
        }
        _ = r.items.orderedRemove(0);
    }
    return finish(r);
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

/// Read `author-script` back: the three variables, single-quoted, as git
/// and this write them. `null` when the file is not there.
pub fn parseAuthorScript(text: []const u8, buf: []u8) error{MalformedState}!object.Signature {
    var name: ?[]const u8 = null;
    var email: ?[]const u8 = null;
    var date: ?[]const u8 = null;
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedState;
        const key = line[0..eq];
        const value = try unquote(line[eq + 1 ..], buf[used..]);
        used += value.len;
        if (std.mem.eql(u8, key, "GIT_AUTHOR_NAME")) {
            name = value;
        } else if (std.mem.eql(u8, key, "GIT_AUTHOR_EMAIL")) {
            email = value;
        } else if (std.mem.eql(u8, key, "GIT_AUTHOR_DATE")) {
            date = value;
        } else return error.MalformedState;
    }
    const d = date orelse return error.MalformedState;
    if (d.len < 2 or d[0] != '@') return error.MalformedState;
    const space = std.mem.indexOfScalar(u8, d, ' ') orelse return error.MalformedState;
    const secs = std.fmt.parseInt(i64, d[1..space], 10) catch return error.MalformedState;
    const zone = d[space + 1 ..];
    if (zone.len != 5 or (zone[0] != '+' and zone[0] != '-')) return error.MalformedState;
    const hours = std.fmt.parseInt(i16, zone[1..3], 10) catch return error.MalformedState;
    const minutes = std.fmt.parseInt(i16, zone[3..5], 10) catch return error.MalformedState;
    const offset = (hours * 60 + minutes) * @as(i16, if (zone[0] == '-') -1 else 1);
    return .{ .name = name orelse return error.MalformedState, .email = email orelse return error.MalformedState, .when_secs = secs, .offset_minutes = offset };
}

/// `sq_dequote`: a shell single-quoted word, `'\''` meaning a quote.
fn unquote(text: []const u8, out: []u8) error{MalformedState}![]const u8 {
    if (text.len < 2 or text[0] != '\'') return error.MalformedState;
    var n: usize = 0;
    var i: usize = 1;
    while (true) {
        if (i >= text.len) return error.MalformedState;
        const c = text[i];
        if (c != '\'') {
            if (n >= out.len) return error.MalformedState;
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        // A closing quote: the end, or `'\''`.
        if (i + 1 == text.len) return out[0..n];
        if (std.mem.startsWith(u8, text[i + 1 ..], "\\''")) {
            if (n >= out.len) return error.MalformedState;
            out[n] = '\'';
            n += 1;
            i += 4;
            continue;
        }
        return error.MalformedState;
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
        try head_mod.writeState(r.io, r.repo.git_dir, "MERGE_MSG", squash_msg);
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
    try r.state("stopped-sha", try std.fmt.allocPrint(r.arena, "{s}\n", .{try r.hex(commit)}));
    try head_mod.writeRef(r.io, r.repo, "REBASE_HEAD", commit);
    try writePatch(r, commit);
    if (!r.hasState("message")) {
        const found = try r.repo.odb.read(r.io, commit);
        defer r.repo.odb.gpa.free(found.bytes);
        var parsed = try object.Commit.parse(r.gpa, r.repo.kind, found.bytes);
        defer parsed.deinit();
        try r.state("message", try std.fmt.allocPrint(r.arena, "{s}\n", .{message.fromSubject(parsed.message)}));
    }
    if (to_amend) try intendToAmend(r);
}

fn intendToAmend(r: *Run) Error!void {
    try r.state("amend", try std.fmt.allocPrint(r.arena, "{s}\n", .{try r.hex(try r.headOid())}));
}

/// The commit's diff against its first parent, as `git diff-tree -p`
/// prints it, in `patch`.
fn writePatch(r: *Run, commit_oid: Oid) Error!void {
    const found = try r.repo.odb.read(r.io, commit_oid);
    defer r.repo.odb.gpa.free(found.bytes);
    var commit = try object.Commit.parse(r.gpa, r.repo.kind, found.bytes);
    defer commit.deinit();
    const parent_tree: ?Oid = if (commit.parents.len != 0) try r.repo.commitTree(r.io, commit.parents[0]) else null;
    var changes = try diff.tree(r.gpa, r.io, &r.repo.odb, parent_tree, commit.tree, .{ .renames = .{} });
    defer changes.deinit();
    var out: std.Io.Writer.Allocating = .init(r.arena);
    for (changes.items) |change| {
        diff.unified(r.gpa, r.io, &out.writer, &r.repo.odb, change, .{ .abbrev = r.abbrev_len }) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
    }
    try r.state("patch", out.written());
}

/// Record that `old` became what `HEAD` is once its chain of fixups, if any,
/// is done: `rewritten-pending`, flushed into `rewritten-list` unless a
/// fixup follows.
fn recordInRewritten(r: *Run, old: Oid, next: todo.Command) Error!void {
    try r.appendState("rewritten-pending", try std.fmt.allocPrint(r.arena, "{s}\n", .{try r.hex(old)}));
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

fn readSource(r: *Run, oid: Oid) Error!Source {
    const found = try r.repo.odb.read(r.io, oid);
    defer r.repo.odb.gpa.free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const bytes = try r.arena.dupe(u8, found.bytes);
    return .{ .oid = oid, .bytes = bytes, .commit = try object.Commit.parse(r.arena, r.repo.kind, bytes) };
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
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnmergedIndex;
    }

    const source = try readSource(r, item.commit.?);
    const commit = source.commit;
    if (commit.parents.len > 1) return error.MergeCommit;
    const parent: ?Oid = if (commit.parents.len == 1) commit.parents[0] else null;
    const subject = message.subjectLine(commit.message);
    const short_name = try r.short(source.oid);
    const label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ short_name, subject });
    const parent_label = try std.fmt.allocPrint(arena, "parent of {s}", .{label});

    // The commit sits on `HEAD` already: reuse it.
    if (r.allow_ff and !is_fixup and parent != null and parent.?.eql(head_oid)) {
        try writeAuthorScript(r, commit.author);
        var outcome = try threeway.apply(gpa, io, repo, &index, head_tree, head_tree, commit.tree, .{ .blocked = r.options.blocked });
        outcome.deinit();
        try index.write(io, repo.git_dir, "index", .{});
        try head_mod.advance(io, repo, head, source.oid, .{ .who = r.options.who, .message = "rebase: fast-forward" });
        if (command == .reword) try reword(r, reflog_action);
        return .ok;
    }

    try r.msg.appendSlice(arena, message.fromSubject(commit.message));
    r.have_message = true;
    var msg_source: enum { merge_msg, squash, fixup, squash_edit } = .merge_msg;
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
    if (r.options.signoff and !is_fixup) try message.appendSignoff(arena, &r.msg, r.options.who, r.comment);
    try writeAuthorScript(r, commit.author);

    const base_tree = if (parent) |p| try repo.commitTree(io, p) else null;
    const style = r.options.conflict_style orelse merging.configuredStyle(repo);
    var outcome = try threeway.apply(gpa, io, repo, &index, base_tree, head_tree, commit.tree, .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .base = if (parent != null) parent_label else "(empty tree)", .theirs = label },
            .favor = r.options.favor,
            .algorithm = .histogram,
        },
        .blocked = r.options.blocked,
    });
    defer outcome.deinit();
    try index.write(io, repo.git_dir, "index", .{});
    try head_mod.writeRef(io, repo, "AUTO_MERGE", outcome.auto_merge);
    if (!outcome.isClean()) {
        try r.msg.append(arena, '\n');
        try r.msg.appendSlice(arena, r.comment);
        try r.msg.appendSlice(arena, " Conflicts:\n");
        for (outcome.conflicts) |conflict| {
            try r.msg.appendSlice(arena, r.comment);
            try r.msg.append(arena, '\t');
            try r.msg.appendSlice(arena, conflict.path);
            try r.msg.append(arena, '\n');
        }
        const copied = try arena.dupe(threeway.Conflict, outcome.conflicts);
        for (copied) |*c| c.path = try arena.dupe(u8, c.path);
        r.conflicts = copied;
    }
    try head_mod.writeState(io, repo.git_dir, "MERGE_MSG", r.msg.items);
    // A rebase takes care of the commit itself, so a conflict leaves no
    // `CHERRY_PICK_HEAD`, as git's leaves none.
    if (!outcome.isClean()) return .conflict;
    if (command == .pick or command == .reword or command == .edit) {
        try head_mod.writeRef(io, repo, "CHERRY_PICK_HEAD", source.oid);
    }

    // Empty now, or empty from the start.
    var allow_empty = false;
    if (outcome.tree.?.eql(head_tree)) {
        const parent_tree = base_tree orelse try repo.odb.write(io, .tree, "");
        if (parent_tree.eql(commit.tree)) {
            allow_empty = true;
        } else switch (r.empty) {
            .keep => allow_empty = true,
            .drop => {
                try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
                try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
                try head_mod.deleteRef(io, repo, "AUTO_MERGE");
                return .ok;
            },
            .stop => {},
        }
    }

    // The commit, or the amended one of a fixup chain.
    const amending = is_fixup;
    const parents: []const Oid = if (amending) try parentsOf(r, head_oid) else &.{head_oid};
    const first_parent_tree = if (parents.len != 0) try repo.commitTree(io, parents[0]) else try repo.odb.write(io, .tree, "");
    if (!allow_empty and outcome.tree.?.eql(first_parent_tree)) return .empty;
    const author = if (amending) (try readSource(r, head_oid)).commit.author else commit.author;

    // `try_to_commit` cleans nothing but whitespace, and that only with a
    // sign-off, unless `commit.cleanup` says otherwise; an edited message
    // is cleaned of comments as an editor's is.
    const cleanup: message.Cleanup = if (r.options.signoff) .whitespace else configuredCleanup(repo);
    const text: []const u8 = switch (msg_source) {
        .merge_msg => try message.cleanup(arena, r.msg.items, cleanup, r.comment),
        .squash => try message.cleanup(arena, (try r.readState("message-squash")).?, cleanup, r.comment),
        .fixup => try message.cleanup(arena, (try r.readState("message-fixup")).?, cleanup, r.comment),
        .squash_edit => blk: {
            const proposed = (try r.readState("message-squash")).?;
            try head_mod.writeState(io, repo.git_dir, "SQUASH_MSG", proposed);
            try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
            break :blk try edited(r, .squash, proposed);
        },
    };
    const extra: []const object.ExtraHeader = if (amending) try extraHeadersOf(r, head_oid) else &.{};
    const made = try repo.writeCommit(io, .{
        .tree = outcome.tree.?,
        .parents = parents,
        .author = author,
        .committer = r.options.who,
        .message = text,
        .extra = extra,
    });
    const log = try std.fmt.allocPrint(arena, "{s}: {s}", .{ reflog_action, firstLine(text) });
    try head_mod.advance(io, repo, head, made, .{ .who = r.options.who, .message = log });
    try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
    try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
    if (msg_source == .squash_edit) {
        // An edited message is committed with `git commit`, which takes
        // `AUTO_MERGE` away as it finishes; git points `REBASE_HEAD` at the
        // commit first, and it stays there until the next instruction.
        try head_mod.removeState(io, repo.git_dir, "SQUASH_MSG");
        try head_mod.deleteRef(io, repo, "AUTO_MERGE");
        try head_mod.writeRef(io, repo, "REBASE_HEAD", item.commit.?);
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
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

fn configuredCleanup(repo: *Repository) message.Cleanup {
    const text = repo.config.get("commit.cleanup") orelse return .verbatim;
    return message.Cleanup.parse(text) orelse .verbatim;
}

/// A message a person would have edited: what the caller's `Messages` make
/// of it, or the proposal as an editor left untouched leaves it, cleaned of
/// comments either way.
fn edited(r: *Run, kind: MessageKind, proposed: []const u8) Error![]const u8 {
    var text = proposed;
    if (r.options.messages) |m| {
        if (m.editFn(m.context, kind, proposed)) |given| text = given;
    }
    const cleaned = try message.cleanup(r.arena, text, .strip, r.comment);
    if (cleaned.len == 0) return error.EmptyMessage;
    return cleaned;
}

/// `reword`: amend `HEAD` with the message a person makes of it.
fn reword(r: *Run, reflog_action: []const u8) Error!void {
    var head = try r.head();
    defer head.deinit(r.gpa);
    const current = try readSource(r, head.oid.?);
    const text = try edited(r, .reword, message.fromSubject(current.commit.message));
    const made = try r.repo.writeCommit(r.io, .{
        .tree = current.commit.tree,
        .parents = current.commit.parents,
        .author = current.commit.author,
        .committer = r.options.who,
        .message = text,
    });
    const log = try std.fmt.allocPrint(r.arena, "{s}: {s}", .{ reflog_action, firstLine(text) });
    try head_mod.advance(r.io, r.repo, head, made, .{ .who = r.options.who, .message = log });
    // The amend is `git commit --amend`, which takes `AUTO_MERGE` away.
    try head_mod.deleteRef(r.io, r.repo, "AUTO_MERGE");
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
    return std.mem.startsWith(u8, r.fixups.items, "squash") or std.mem.indexOf(u8, r.fixups.items, "\nsquash") != null;
}

/// `strbuf_add_commented_lines`, into a list.
fn addCommented(r: *Run, out: *std.ArrayList(u8), text: []const u8) Error!void {
    var at: usize = 0;
    while (at < text.len) {
        const next = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        try out.appendSlice(r.arena, r.comment);
        if (text[at] != '\n' and text[at] != '\t') try out.append(r.arena, ' ');
        try out.appendSlice(r.arena, text[at..next]);
        at = next;
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(r.arena, '\n');
}

/// `add_commented_lines`: lines already commented are copied as they are,
/// and the rest commented.
fn addCommentedKeepingComments(r: *Run, out: *std.ArrayList(u8), text_in: []const u8) Error!void {
    var text = text_in;
    while (std.mem.startsWith(u8, text, r.comment)) {
        const next = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| nl + 1 else text.len;
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
        const end = std.mem.indexOfScalarPos(u8, body, at, '\n') orelse body.len;
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
        const eol = if (!std.mem.startsWith(u8, old, r.comment)) 0 else (std.mem.indexOfScalar(u8, old, '\n') orelse old.len);
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} This is a combination of {d} commits.", .{ r.comment, r.fixup_count + 2 }));
        try buf.appendSlice(arena, old[eol..]);
        if (isFixupFlag(item) and !seenSquash(r)) buf = try updateSquashMessageForFixup(r, buf.items);
    } else {
        const head_source = try readSource(r, try r.headOid());
        const body = message.fromSubject(head_source.commit.message);
        if (item.command == .fixup and !isFixupFlag(item)) try r.state("message-fixup", body);
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} This is a combination of 2 commits.\n{s} {s}\n\n", .{
            r.comment, r.comment, if (isFixupFlag(item)) skip_first_commit_msg else first_commit_msg,
        }));
        if (isFixupFlag(item)) try addCommented(r, &buf, body) else try buf.appendSlice(arena, body);
    }

    const body = message.fromSubject(commit_message);
    if (item.command == .squash or isFixupFlag(item)) {
        try appendSquashMessage(r, &buf, body, item);
    } else {
        r.fixup_count += 1;
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\n{s} The commit message #{d} will be skipped:\n\n", .{ r.comment, r.fixup_count + 1 }));
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
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\n{s} This is the commit message #{d}:\n\n", .{ r.comment, r.fixup_count + 1 }));
    if (commented_len != 0) try addCommented(r, buf, body[0..commented_len]) else if (buf.items.len != 0 and buf.items[buf.items.len - 1] != '\n') try buf.append(arena, '\n');
    const fixup_off = buf.items.len;
    try buf.appendSlice(arena, body[commented_len..]);
    if (isFixupFlag(item) and !seenSquash(r)) {
        if (r.options.signoff) try message.appendSignoff(arena, buf, r.options.who, r.comment);
        if (item.replace_message and (r.hasState("message-fixup") or !r.hasState("message-squash"))) {
            var rest = buf.items[fixup_off..];
            while (rest.len != 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
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
    var buf1 = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ r.comment, first_commit_msg });
    var buf2 = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ r.comment, skip_first_commit_msg });
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
            buf1 = try std.fmt.allocPrint(arena, "{s} This is the commit message #{d}:\n", .{ r.comment, n });
            buf2 = try std.fmt.allocPrint(arena, "{s} The commit message #{d} will be skipped:\n", .{ r.comment, n });
        } else if (std.mem.startsWith(u8, orig[at..], buf2)) {
            const next = at + buf2.len;
            const off: usize = if (at > from + 1 and orig[at - 2] == '\n') 1 else 0;
            try copyLines(r, &out, orig[from .. at - off], commented);
            from = at - off;
            s = next;
            commented = false;
            n += 1;
            buf1 = try std.fmt.allocPrint(arena, "{s} This is the commit message #{d}:\n", .{ r.comment, n });
            buf2 = try std.fmt.allocPrint(arena, "{s} The commit message #{d} will be skipped:\n", .{ r.comment, n });
        } else {
            s = if (std.mem.indexOfScalarPos(u8, orig, at, '\n')) |nl| nl + 1 else null;
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
    const wt = r.repo.work_dir orelse return error.BareRepository;
    var outcome = try program.run(programs, r.gpa, r.io, .{
        .argv = &.{command_line},
        .shell = true,
        .cwd = .{ .dir = wt },
        .unset = &.{"GIT_CHERRY_PICK_HELP"},
        .stderr = .inherit,
    }, "", .{});
    defer outcome.deinit(r.gpa);
    var status: u8 = switch (outcome.term) {
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
    if (r.options.reschedule_failed_exec) {
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
    const ref = try std.fmt.allocPrint(r.arena, "refs/rewritten/{s}", .{name});
    var tx = r.repo.beginRefs();
    defer tx.deinit(r.io);
    try tx.update(ref, .{ .direct = try r.headOid() }, .any);
    try tx.commit(r.io, .{ .who = r.options.who, .message = try std.fmt.allocPrint(r.arena, "rebase (label) '{s}'", .{name}), .policy = r.repo.reflogPolicy() });
    try r.appendState("refs-to-delete", try std.fmt.allocPrint(r.arena, "{s}\n", .{ref}));
}

/// `lookup_label`: `refs/rewritten/<label>`, or any name a commit goes by.
fn lookupLabel(r: *Run, name: []const u8) Error!Oid {
    const ref = try std.fmt.allocPrint(r.arena, "refs/rewritten/{s}", .{name});
    if (try r.repo.refs.resolve(r.gpa, r.io, ref)) |resolved| {
        r.gpa.free(resolved.name);
        return resolved.oid;
    }
    var context: sequencer.ResolverContext = .{ .repo = r.repo, .io = r.io };
    const found = context.resolver().resolveFn(&context, name) orelse return error.UnknownLabel;
    return found.oid;
}

/// `reset`: `HEAD`, the index and the working tree to a label.
fn doReset(r: *Run, arg: []const u8) Error!void {
    const end = std.mem.indexOfAny(u8, arg, " \t\n\r") orelse arg.len;
    const name = arg[0..end];
    const target = try lookupLabel(r, name);
    var index = try r.repo.openIndex(r.io);
    defer index.deinit();
    try reset.toTree(r.gpa, r.io, r.repo, &index, try r.repo.commitTree(r.io, target), .merge, r.options.blocked);
    try index.write(r.io, r.repo.git_dir, "index", .{});
    var h = try r.head();
    defer h.deinit(r.gpa);
    const log = try std.fmt.allocPrint(r.arena, "rebase (reset): '{s}'", .{name});
    try head_mod.advance(r.io, r.repo, h, target, .{ .who = r.options.who, .message = log });
}

/// `update-ref`: remember where `HEAD` is for a ref to be moved when the
/// rebase finishes.
fn doUpdateRef(r: *Run, ref: []const u8) Error!void {
    const text = (try head_mod.readState(r.arena, r.io, r.repo.git_dir, path("update-refs"))) orelse return;
    const records = try parseUpdateRefs(r, text);
    const new = try r.headOid();
    for (records.items) |*rec| {
        if (std.mem.eql(u8, rec.ref, ref)) rec.after = new;
    }
    try writeUpdateRefs(r, records.items);
}

const UpdateRef = struct { ref: []const u8, before: Oid, after: Oid };

fn parseUpdateRefs(r: *Run, text: []const u8) Error!std.ArrayList(UpdateRef) {
    var out: std.ArrayList(UpdateRef) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ref| {
        if (ref.len == 0) break;
        const before = lines.next() orelse return error.MalformedState;
        const after = lines.next() orelse return error.MalformedState;
        try out.append(r.arena, .{
            .ref = ref,
            .before = Oid.parse(r.repo.kind, before) catch return error.MalformedState,
            .after = Oid.parse(r.repo.kind, after) catch return error.MalformedState,
        });
    }
    return out;
}

fn writeUpdateRefs(r: *Run, records: []const UpdateRef) Error!void {
    if (records.len == 0) return r.removeState("update-refs");
    var out: std.ArrayList(u8) = .empty;
    for (records) |rec| {
        try out.appendSlice(r.arena, try std.fmt.allocPrint(r.arena, "{s}\n{s}\n{s}\n", .{ rec.ref, try r.hex(rec.before), try r.hex(rec.after) }));
    }
    try r.state("update-refs", out.items);
}

fn lessThanRef(_: void, a: UpdateRef, b: UpdateRef) bool {
    return std.mem.order(u8, a.ref, b.ref) == .lt;
}

/// A record for `ref` that has not moved yet: where it is now, and
/// nothing after.
fn freshUpdateRef(r: *Run, ref: []const u8) Error!UpdateRef {
    const zero = Oid.zero(r.repo.kind);
    const resolved = try r.repo.refs.resolve(r.gpa, r.io, ref);
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
    var listing = try r.repo.refs.list(r.gpa, r.io, "refs/heads/");
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
                    const resolved = (try r.repo.refs.resolve(r.gpa, r.io, entry.name)) orelse continue;
                    r.gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            if (!oid.eql(commit)) continue;
            if (head.branch) |branch| {
                if (std.mem.eql(u8, branch, entry.name)) continue;
            }
            if (busy.get(entry.name)) |where| {
                const line = try std.fmt.allocPrint(r.arena, "{s} Ref {s} checked out at '{s}'", .{ r.comment, entry.name, where });
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
    const bare = repo.config.getBool("core.bare", false) catch false;
    if (!bare) main: {
        var buf: [4096]u8 = undefined;
        const len = repo.common_dir.realPath(io, &buf) catch break :main;
        const common = buf[0..len];
        const main_path = if (std.mem.endsWith(u8, common, "/.git")) common[0 .. common.len - "/.git".len] else common;
        try addWorktreeBranches(r, &map, repo.common_dir, try r.arena.dupe(u8, main_path));
    }
    var listing = try worktrees.list(r.gpa, io, repo.common_dir, repo.kind);
    defer listing.deinit();
    for (listing.entries) |entry| {
        const sub = try std.fmt.allocPrint(r.arena, "worktrees/{s}", .{entry.name});
        var admin = repo.common_dir.openDir(io, sub, .{}) catch continue;
        defer admin.close(io);
        try addWorktreeBranches(r, &map, admin, try r.arena.dupe(u8, entry.path));
    }
    return map;
}

fn addWorktreeBranches(r: *Run, map: *std.StringHashMapUnmanaged([]const u8), dir: Io.Dir, where: []const u8) Error!void {
    const arena = r.arena;
    if (try head_mod.readState(arena, r.io, dir, "HEAD")) |text| {
        const line = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.startsWith(u8, line, "ref:")) {
            try map.put(arena, std.mem.trim(u8, line[4..], " \t"), where);
        }
    }
    for ([_][]const u8{ "rebase-apply/head-name", "rebase-merge/head-name" }) |sub| {
        const text = (try head_mod.readState(arena, r.io, dir, sub)) orelse continue;
        const name = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.startsWith(u8, name, "refs/heads/")) try map.put(arena, name, where);
        break;
    }
    if (try head_mod.readState(arena, r.io, dir, "BISECT_START")) |text| {
        const name = std.mem.trim(u8, text, " \t\r\n");
        // A bisection started from a detached `HEAD` names a commit.
        if (name.len != 0) {
            if (Oid.parse(r.repo.kind, name)) |_| {} else |_| {
                try map.put(arena, try std.fmt.allocPrint(arena, "refs/heads/{s}", .{name}), where);
            }
        }
    }
    if (try head_mod.readState(arena, r.io, dir, "rebase-merge/update-refs")) |text| {
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
    if (std.mem.indexOf(u8, arg, " #")) |at| {
        oneline = std.mem.trim(u8, arg[at + 2 ..], " \t");
        arg = arg[0..at];
    } else if (std.mem.startsWith(u8, arg, "#")) {
        oneline = std.mem.trim(u8, arg[1..], " \t");
        arg = "";
    }
    var names = std.mem.tokenizeAny(u8, arg, " \t");
    const name = names.next() orelse return error.UnknownLabel;
    if (names.next() != null) return error.OctopusMerge;
    const merge_head = try lookupLabel(r, name);

    // The original merge's parents are exactly these: reuse it.
    if (item.commit) |original| {
        const source = try readSource(r, original);
        if (r.allow_ff and source.commit.parents.len == 2 and source.commit.parents[0].eql(head_oid) and source.commit.parents[1].eql(merge_head)) {
            var index = try repo.openIndex(io);
            defer index.deinit();
            const head_tree = try repo.commitTree(io, head_oid);
            var outcome = try threeway.apply(gpa, io, repo, &index, head_tree, head_tree, source.commit.tree, .{ .blocked = r.options.blocked });
            outcome.deinit();
            try index.write(io, repo.git_dir, "index", .{});
            try head_mod.advance(io, repo, h, original, .{ .who = r.options.who, .message = "rebase: fast-forward" });
            try recordInRewritten(r, original, peekCommand(r, 1));
            return null;
        }
    }

    var author = r.options.who;
    if (item.commit) |original| {
        const source = try readSource(r, original);
        author = source.commit.author;
        try r.msg.appendSlice(r.arena, message.fromSubject(source.commit.message));
    } else if (oneline) |text| {
        try r.msg.appendSlice(r.arena, text);
    } else {
        try r.msg.appendSlice(r.arena, try std.fmt.allocPrint(r.arena, "Merge branch '{s}'", .{name}));
    }
    r.have_message = true;
    try writeAuthorScript(r, author);
    try head_mod.writeState(io, repo.git_dir, "MERGE_MSG", r.msg.items);

    const bases = try revwalk.mergeBases(gpa, io, &repo.odb, head_oid, merge_head);
    defer gpa.free(bases);
    if (bases.len != 0 and bases[0].eql(merge_head)) return null;
    try head_mod.writeState(io, repo.git_dir, "MERGE_HEAD", try r.hex(merge_head));
    try head_mod.writeState(io, repo.git_dir, "MERGE_MODE", "no-ff");

    var index = try repo.openIndex(io);
    defer index.deinit();
    const base_tree: ?Oid = if (bases.len == 1) try repo.commitTree(io, bases[0]) else if (bases.len == 0) null else return error.ConflictingMergeBases;
    const style = r.options.conflict_style orelse merging.configuredStyle(repo);
    var buf: [hash.max_hex_len]u8 = undefined;
    const base_label = if (bases.len == 1) try r.arena.dupe(u8, try abbrev.unique(io, &repo.odb, bases[0], r.abbrev_len, &buf)) else "empty tree";
    const ref_name = try std.fmt.allocPrint(r.arena, "refs/rewritten/{s}", .{name});
    var outcome = try threeway.apply(gpa, io, repo, &index, base_tree, try repo.commitTree(io, head_oid), try repo.commitTree(io, merge_head), .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .base = base_label, .theirs = if (lookupRewritten(r, name)) ref_name else name },
            .algorithm = .histogram,
        },
        .blocked = r.options.blocked,
    });
    defer outcome.deinit();
    try index.write(io, repo.git_dir, "index", .{});
    try head_mod.writeRef(io, repo, "AUTO_MERGE", outcome.auto_merge);
    if (!outcome.isClean()) {
        const copied = try r.arena.dupe(threeway.Conflict, outcome.conflicts);
        for (copied) |*c| c.path = try r.arena.dupe(u8, c.path);
        r.conflicts = copied;
        if (item.commit) |original| try errorWithPatch(r, original, false) else if (r.have_message and !r.hasState("message")) try r.state("message", r.msg.items);
        _ = r.items.orderedRemove(0);
        return finishOutcome(r, .stopped, .conflict, item.commit);
    }

    var text: []const u8 = try message.cleanup(r.arena, r.msg.items, if (r.options.signoff) .whitespace else configuredCleanup(repo), r.comment);
    if (item.edit_message) text = try edited(r, .merge, text);
    const made = try repo.writeCommit(io, .{
        .tree = outcome.tree.?,
        .parents = &.{ head_oid, merge_head },
        .author = author,
        .committer = r.options.who,
        .message = text,
    });
    const log = try std.fmt.allocPrint(r.arena, "rebase (merge): {s}", .{firstLine(text)});
    try head_mod.advance(io, repo, h, made, .{ .who = r.options.who, .message = log });
    // git makes this commit with `git commit`, whose clean-up takes
    // `AUTO_MERGE` with the merge's other files.
    try merging.removeMergeState(io, repo);
    if (item.commit) |original| try recordInRewritten(r, original, peekCommand(r, 1));
    return null;
}

fn lookupRewritten(r: *Run, name: []const u8) bool {
    const ref = std.fmt.allocPrint(r.arena, "refs/rewritten/{s}", .{name}) catch return false;
    const found = r.repo.refs.read(r.gpa, r.io, ref) catch return false;
    if (found) |f| switch (f) {
        .symbolic => |t| r.gpa.free(t),
        .direct => {},
    };
    return found != null;
}

//=========================================================================
// Finishing, continuing, skipping, aborting
//=========================================================================

/// The end of the sheet: the branch moves to where `HEAD` is, `HEAD` names
/// it again, the refs `update-ref` lines asked for move, and the state goes.
fn finish(r: *Run) Error!Outcome {
    const io = r.io;
    const repo = r.repo;
    const tip = try readBasicState(r);
    const onto = try ontoOf(r);
    const head_oid = try r.headOid();
    if (tip.head_name) |branch| {
        const branch_log = try std.fmt.allocPrint(r.arena, "rebase (finish): {s} onto {s}", .{ branch, try r.hex(onto) });
        try head_mod.moveBranch(io, repo, branch, .{ .matches = tip.orig_head }, head_oid, .{ .who = r.options.who, .message = branch_log });
        const head_log = try std.fmt.allocPrint(r.arena, "rebase (finish): returning to {s}", .{branch});
        try head_mod.attach(io, repo, branch, head_oid, .{ .who = r.options.who, .message = head_log });
    }
    try flushRewritten(r);
    var rewritten: std.ArrayList(Rewritten) = .empty;
    if (try r.readState("rewritten-list")) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedState;
            try rewritten.append(r.arena, .{
                .old = Oid.parse(repo.kind, line[0..space]) catch return error.MalformedState,
                .new = Oid.parse(repo.kind, line[space + 1 ..]) catch return error.MalformedState,
            });
        }
    }
    if (try r.readState("update-refs")) |text| {
        const records = try parseUpdateRefs(r, text);
        for (records.items) |rec| {
            if (rec.after.isZero()) continue;
            try head_mod.moveBranch(io, repo, rec.ref, .{ .matches = rec.before }, rec.after, .{ .who = r.options.who, .message = "rewritten during rebase" });
        }
    }
    try removeState(r);
    var out = finishOutcome(r, .done, null, null);
    out.rewritten = rewritten.items;
    return out;
}

/// Load a rebase in progress, whoever started it.
fn loadRun(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Run {
    if (head_mod.stateExists(io, repo.git_dir, "rebase-apply")) return error.ApplyBackendInProgress;
    if (!inProgress(io, repo)) return error.NoRebaseInProgress;
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    arena_state.* = .init(gpa);
    errdefer {
        arena_state.deinit();
        gpa.destroy(arena_state);
    }
    var r = try newRun(gpa, arena_state, io, repo, options);
    r.allow_ff = !options.force;
    _ = try readBasicState(&r);
    const text = (try r.readState("git-rebase-todo")) orelse "";
    var context: sequencer.ResolverContext = .{ .repo = repo, .io = io };
    const list = try todo.parse(r.arena, text, context.resolver(), .{ .comment = r.comment, .rebase = true, .fixup_first_ok = true });
    try r.items.appendSlice(r.arena, list.items.items);
    if (try r.readState("msgnum")) |n| {
        r.done_nr = std.fmt.parseInt(usize, std.mem.trim(u8, n, " \n"), 10) catch return error.MalformedState;
    }
    return r;
}

/// Continue the rebase that stopped, whoever stopped it: commit what is
/// staged, as git does, and carry on down the sheet.
pub fn proceed(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Outcome {
    var r = try loadRun(gpa, io, repo, options);
    errdefer freeRun(&r);
    try commitStagedChanges(&r);
    if (r.hasState("stopped-sha")) {
        const text = (try r.readState("stopped-sha")).?;
        const oid = Oid.parse(repo.kind, std.mem.trim(u8, text, " \n")) catch return error.MalformedState;
        try recordInRewritten(&r, oid, peekCommand(&r, 0));
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
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (r.options.blocked) |b| b.set(entry.path);
            return error.UnresolvedConflicts;
        }
    }
    // Unstaged changes are refused; staged ones are what gets committed.
    const wt = repo.work_dir orelse return error.BareRepository;
    var rules = repo.worktreeRules();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    var h = try r.head();
    defer h.deinit(r.gpa);
    const head_oid = h.oid orelse return error.UnbornBranch;
    const head_tree = try repo.commitTree(io, head_oid);
    var status = try worktree.status(r.gpa, io, wt, &index, &repo.odb, .{ .rules = rules, .head_tree = head_tree, .untracked = .no });
    defer status.deinit();
    var staged = false;
    for (status.entries) |entry| {
        if (entry.unstaged != .unmodified) return error.DirtyWorktree;
        if (entry.staged != .unmodified) staged = true;
    }
    const merge_head_text = try head_mod.readState(r.arena, io, repo.git_dir, "MERGE_HEAD");
    const is_clean = !staged and merge_head_text == null;
    if (!is_clean and !r.hasState("message")) return error.StagedWithoutMessage;

    var amend = false;
    if (try r.readState("amend")) |text| {
        const to_amend = Oid.parse(repo.kind, std.mem.trim(u8, text, " \n")) catch return error.MalformedState;
        if (!is_clean and !head_oid.eql(to_amend)) return error.DirtyWorktree;
        amend = true;
    }
    if (is_clean) {
        try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
        try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
        return;
    }

    const tree = try worktree.writeTree(r.gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});
    var parents: std.ArrayList(Oid) = .empty;
    if (amend) {
        try parents.appendSlice(r.arena, try parentsOf(r, head_oid));
    } else try parents.append(r.arena, head_oid);
    if (merge_head_text) |text| {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| try parents.append(r.arena, Oid.parse(repo.kind, std.mem.trim(u8, line, " ")) catch return error.MalformedState);
    }
    // The author the stop recorded; an amend keeps the one it amends.
    var author = r.options.who;
    var name_buf: [4096]u8 = undefined;
    if (amend) {
        author = (try readSource(r, head_oid)).commit.author;
    } else if (try r.readState("author-script")) |script| {
        author = parseAuthorScript(script, &name_buf) catch return error.MalformedState;
    } else return error.StagedWithoutMessage;
    const proposed = (try r.readState("message")).?;
    const text = try edited(r, .resolved, proposed);
    const made = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = parents.items,
        .author = author,
        .committer = r.options.who,
        .message = text,
        .extra = if (amend) try extraHeadersOf(r, head_oid) else &.{},
    });
    const log = try std.fmt.allocPrint(r.arena, "rebase (continue): {s}", .{firstLine(text)});
    try head_mod.advance(io, repo, h, made, .{ .who = r.options.who, .message = log });
    try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
    try head_mod.removeState(io, repo.git_dir, "MERGE_MSG");
    try r.removeState("amend");
    try merging.removeMergeState(io, repo);
}

/// Leave out the instruction that stopped, with whatever it changed, and
/// carry on: `--skip`.
pub fn skip(gpa: Allocator, io: Io, repo: *Repository, options: Options) Error!Outcome {
    {
        var r = try loadRun(gpa, io, repo, options);
        defer freeRun(&r);
        const current = try r.headOid();
        var index = try repo.openIndex(io);
        defer index.deinit();
        try reset.toTree(gpa, io, repo, &index, try repo.commitTree(io, current), .hard, options.blocked);
        try index.write(io, repo.git_dir, "index", .{});
        try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
        try head_mod.deleteRef(io, repo, "REVERT_HEAD");
        try merging.removeMergeState(io, repo);
    }
    return proceed(gpa, io, repo, options);
}

/// Stop the rebase and put the branch, `HEAD`, the index and the working
/// tree back where they were when it began: `--abort`.
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, who: object.Signature) Error!void {
    var r = try loadRun(gpa, io, repo, .{ .who = who });
    defer freeRun(&r);
    const tip = try readBasicState(&r);
    var h = try r.head();
    defer h.deinit(gpa);
    var index = try repo.openIndex(io);
    defer index.deinit();
    try reset.toTree(gpa, io, repo, &index, try repo.commitTree(io, tip.orig_head), .hard, null);
    try index.write(io, repo.git_dir, "index", .{});
    const target = tip.head_name orelse try r.hex(tip.orig_head);
    const log = try std.fmt.allocPrint(r.arena, "rebase (abort): returning to {s}", .{target});
    if (tip.head_name) |branch| {
        try head_mod.attach(io, repo, branch, h.oid, .{ .who = who, .message = log });
    } else {
        try head_mod.advance(io, repo, h, tip.orig_head, .{ .who = who, .message = log });
    }
    try head_mod.deleteRef(io, repo, "CHERRY_PICK_HEAD");
    try head_mod.deleteRef(io, repo, "REVERT_HEAD");
    try merging.removeMergeState(io, repo);
    try head_mod.deleteRef(io, repo, "REBASE_HEAD");
    try removeState(&r);
}

/// Forget the rebase and leave `HEAD`, the index and the working tree as
/// they are: `--quit`.
pub fn quit(gpa: Allocator, io: Io, repo: *Repository) Error!void {
    var r = try loadRun(gpa, io, repo, .{ .who = .{ .name = "", .email = "", .when_secs = 0, .offset_minutes = 0 } });
    defer freeRun(&r);
    try removeState(&r);
}

//=========================================================================
// Tests
//=========================================================================

test "an author script reads back what git writes, quotes and all" {
    var buf: [256]u8 = undefined;
    const sig = try parseAuthorScript(
        "GIT_AUTHOR_NAME='O'\\''Brien'\nGIT_AUTHOR_EMAIL='o@example.com'\nGIT_AUTHOR_DATE='@1700000000 -0130'\n",
        &buf,
    );
    try std.testing.expectEqualStrings("O'Brien", sig.name);
    try std.testing.expectEqualStrings("o@example.com", sig.email);
    try std.testing.expectEqual(@as(i64, 1700000000), sig.when_secs);
    try std.testing.expectEqual(@as(i16, -90), sig.offset_minutes);
    try std.testing.expectError(error.MalformedState, parseAuthorScript("GIT_AUTHOR_NAME=unquoted\n", &buf));
}

test "fuzz: any bytes are an author script or a named error" {
    try std.testing.fuzz({}, fuzzAuthorScript, .{});
}

fn fuzzAuthorScript(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [256]u8 = undefined;
    const text = input[0..smith.slice(&input)];
    var buf: [512]u8 = undefined;
    _ = parseAuthorScript(text, &buf) catch |err| switch (err) {
        error.MalformedState => return,
    };
}
