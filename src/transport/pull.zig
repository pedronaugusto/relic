//! `git pull`: a fetch, and what it brought merged into the current branch
//! or the branch rebased onto it.
//!
//! It is git's `cmd_pull`, step for step, since each step decides what the
//! next one sees. Before anything is fetched: the index must hold no
//! conflict and no merge may be waiting, and a rebase asks for a clean
//! working tree unless it puts the changes aside, and notes where the
//! branch forked from its upstream (`rev_walk.fork_point`) while the
//! upstream's log still says so. The fetch may move the branch checked
//! out, which brings the working tree along. Then the lines of
//! `FETCH_HEAD` marked for merging are the heads: none is refused with the
//! reason git gives; an unborn branch takes the one head as its first
//! commit ("initial pull"); otherwise `pull.ff`, `pull.rebase` and
//! `branch.<name>.rebase` decide between a fast-forward, a merge of
//! `FETCH_HEAD` (`merging.fetchHead`, so the message says `of <url>`) and
//! a rebase onto the head -- from the fork point, when the upstream was
//! rewritten under the branch. Divergent branches with nothing said about
//! how to reconcile them are refused, as git refuses them. Every reflog
//! line begins with the pull's own words, git's `GIT_REFLOG_ACTION`.
//!
//! `submodule.recurse` and `--recurse-submodules` are not acted on: the
//! fetch does not go into submodules, and the submodules are not updated
//! after.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const head_mod = @import("../repo/head.zig");
const config_mod = @import("../config/config.zig");
const remote_mod = @import("../wire.zig").remote;
const refspec_mod = @import("../wire.zig").refspec;
const warning = @import("../report.zig").warning;
const rev_walk = @import("../walk/walk.zig");
const fork_point = @import("../rev_walk/fork_point.zig");
const three_way = @import("../merge/three_way.zig");
const merging = @import("../commit/merging.zig");
const rebase = @import("../commit/rebase.zig");
const fetch_mod = @import("fetch.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a pull.
pub const Error = error{
    /// `pull.rebase` or `branch.<name>.rebase` names no way git knows, or
    /// the `preserve` it no longer has.
    InvalidRebaseSetting,
    /// `pull.ff` is neither a boolean nor `only`.
    InvalidFastForwardSetting,
    /// A rebase that keeps merges, `merges`: relic's rebase writes no
    /// sheet with merges yet.
    RebaseMergesNotSupported,
    /// The branch has no commit and the index has something added: git's
    /// "Updating an unborn branch with changes added to the index."
    UnbornWithStagedChanges,
    /// Refspecs were named and none brought anything to merge.
    NoMergeCandidates,
    /// A remote other than the branch's was named with no branch to merge.
    BranchNotGiven,
    /// `HEAD` is detached and nothing was named to merge.
    NotOnABranch,
    /// Several heads to merge into a branch with no commit yet.
    MultipleHeadsIntoUnborn,
    /// Several heads to rebase onto.
    MultipleHeadsToRebase,
    /// Several heads with `--ff-only`.
    MultipleHeadsToFastForward,
    /// The branches have diverged and nothing says whether to merge or to
    /// rebase: `pull.rebase`, `pull.ff` or the caller's choice.
    DivergentBranches,
} || fetch_mod.Error || merging.Error || rebase.Error || fork_point.Error || head_mod.Error;

/// How what was fetched is brought into the branch.
pub const Mode = enum {
    /// Merged: `--no-rebase`, `pull.rebase=false`.
    merge,
    /// The branch rebased onto it: `--rebase`, `pull.rebase=true`.
    rebase,
    /// Rebased with its merges kept: `--rebase=merges`.
    rebase_merges,
    /// Rebased through the sheet a person would be handed:
    /// `--rebase=interactive`, taken as it is written.
    rebase_interactive,
};

/// How a pull runs. The fetch, the merge and the rebase are made with the
/// caller's options for each, with what the pull decides set in them: the
/// fetch may update the branch checked out; the merge's `fast_forward` and
/// `autostash` and the rebase's `onto`, `autostash` and `interactive` are
/// the pull's; every `reflog_action` is `reflog_action`. The merge's
/// `who` writes the first commit of an unborn branch.
pub const Options = struct {
    /// `--rebase`, `--rebase=<how>`, `--no-rebase`; `null` asks
    /// `branch.<name>.rebase`, then `pull.rebase`.
    mode: ?Mode = null,
    /// `--ff`, `--no-ff`, `--ff-only`; `null` asks `pull.ff`.
    fast_forward: ?merging.FastForward = null,
    /// `--autostash`, `--no-autostash`; `null` asks `pull.autoStash`, and
    /// then a rebase asks `rebase.autoStash` and a merge `merge.autoStash`.
    autostash: ?bool = null,
    /// What every reflog line begins with: git's `GIT_REFLOG_ACTION`,
    /// which `git pull` sets to its command line. `null` writes `pull`,
    /// the remote and the refspecs.
    reflog_action: ?[]const u8 = null,
    /// The fetch's options; its refspecs are the pull's.
    fetch: fetch_mod.Options,
    /// The merge's options. `verify_signatures` checks the head an unborn
    /// branch takes too, when it is `true`; a rebase ignores it, with a
    /// warning.
    merge: merging.Options,
    /// The rebase's options.
    rebasing: rebase.Options,
};

/// What a pull did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    fetched: fetch_mod.Outcome,
    /// The commit the branch checked out was at when the fetch moved it,
    /// and the working tree was brought along from.
    moved_from: ?Oid = null,
    /// What was done with the heads; `null` when the fetch refused to
    /// update a ref, where git stops.
    result: ?Result = null,

    pub const Result = union(enum) {
        merged: merging.Outcome,
        rebased: rebase.Outcome,
        /// The unborn branch's first commit: the head it took.
        initial: Oid,
    };

    /// Release everything.
    pub fn deinit(o: *Outcome) void {
        o.fetched.deinit();
        if (o.result) |*result| switch (result.*) {
            .merged => |*m| m.deinit(),
            .rebased => |*r| r.deinit(),
            .initial => {},
        };
        o.* = undefined;
    }
};

/// What the configuration and the caller decided, before anything moves.
const Plan = struct {
    mode: Mode,
    /// Neither the caller nor the configuration chose `mode`.
    mode_unspecified: bool,
    fast_forward: ?merging.FastForward,
    autostash: ?bool,
    reflog_action: []const u8,
    branch: ?remote_mod.Branch,
};

/// Fetch from `remote` -- a configured remote or a URL, or `null` for the
/// current branch's -- and bring what was fetched into the current branch.
pub fn pull(gpa: Allocator, io: Io, repo: *Repository, remote: ?[]const u8, options: Options) Self.Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var plan = try decide(gpa, arena, io, repo, remote, options);
    defer if (plan.branch) |*b| b.deinit();

    try requireMerged(io, repo, options.merge.blocked);
    if (merging.inProgress(io, repo)) return error.MergeInProgress;
    var orig = try head_mod.read(gpa, io, repo);
    defer orig.deinit(gpa);
    var forked: ?Oid = null;
    if (plan.mode != .merge) {
        if (plan.mode == .rebase_merges) return error.RebaseMergesNotSupported;
        plan.autostash = plan.autostash orelse try repo.configuration().getBool("rebase.autostash", false);
        if (orig.oid == null and !try indexEmpty(io, repo)) return error.UnbornWithStagedChanges;
        if (!plan.autostash.?) try rebase.requireCleanWorkTree(gpa, io, repo, options.rebasing.blocked);
        forked = try forkPointFor(gpa, arena, io, repo, plan, remote, options.fetch.refspecs);
    }

    var fetch_options = options.fetch;
    fetch_options.update_head_ok = true;
    fetch_options.reflog_action = fetch_options.reflog_action orelse plan.reflog_action;
    const remote_name = remote orelse if (plan.branch) |*b| b.fetchRemote(repo.configuration()) else remote_mod.fallback(repo.configuration());
    var outcome: Outcome = .{ .fetched = try fetch_mod.fetch(gpa, io, repo, remote_name, fetch_options) };
    errdefer outcome.deinit();
    if (outcome.fetched.anyRejected()) return outcome;

    var current = try head_mod.read(gpa, io, repo);
    defer current.deinit(gpa);
    if (orig.oid != null and current.oid != null and !orig.oid.?.eql(current.oid.?)) {
        var hex: [hash.max_hex_len]u8 = undefined;
        try warning.note(options.fetch.warnings, .{ .pull_moved_head = orig.oid.?.hex(&hex) });
        try moveWorkTree(io, repo, try repo.commitTree(io, orig.oid.?), try repo.commitTree(io, current.oid.?), options.merge);
        outcome.moved_from = orig.oid;
    }

    const heads = try merging.fetchHead(io, repo, .{ .arena = arena });
    if (heads.len == 0) return noCandidates(plan, remote, options.fetch.refspecs);
    outcome.result = try reconcile(gpa, io, repo, .{ .plan = plan, .heads = heads, .current = current, .forked = forked }, options);
    return outcome;
}

/// What `reconcile` works with.
const Reconciling = struct {
    plan: Plan,
    heads: []const merging.Target,
    current: head_mod.Head,
    forked: ?Oid,
};

/// The second half of `cmd_pull`, once the heads are known: the first
/// commit of an unborn branch, a fast-forward, a merge or a rebase.
fn reconcile(gpa: Allocator, io: Io, repo: *Repository, r: Reconciling, options: Options) Self.Error!Outcome.Result {
    var plan = r.plan;
    const ours = r.current.oid orelse {
        if (r.heads.len > 1) return error.MultipleHeadsIntoUnborn;
        return .{ .initial = try intoUnborn(gpa, io, repo, r.current, r.heads[0], options.merge) };
    };
    if (r.heads.len > 1) {
        if (plan.mode != .merge) return error.MultipleHeadsToRebase;
        if (plan.fast_forward == .only) return error.MultipleHeadsToFastForward;
    }
    const db = repo.objectDatabase();
    const can_ff = r.heads.len == 1 and try rev_walk.isAncestor(gpa, io, db, .{ .ancestor = ours, .descendant = r.heads[0].oid }, .{});
    const divergent = !can_ff and !try upToDate(gpa, io, repo, ours, r.heads);
    if (plan.fast_forward == .only) {
        if (divergent) return error.NotFastForward;
        plan.mode = .merge;
    }
    if (plan.fast_forward == null and plan.mode_unspecified and divergent) return error.DivergentBranches;

    var merge_options = options.merge;
    merge_options.fast_forward = plan.fast_forward;
    merge_options.autostash = plan.autostash;
    merge_options.reflog_action = plan.reflog_action;
    if (plan.mode == .merge) return .{ .merged = try merging.startHeads(gpa, io, repo, r.heads, merge_options) };

    if (can_ff) {
        merge_options.fast_forward = .only;
        return .{ .merged = try merging.startHeads(gpa, io, repo, r.heads, merge_options) };
    }
    if (options.merge.verify_signatures == true) try warning.note(options.fetch.warnings, .verify_signatures_ignored_for_rebase);
    // git asks whether the fork point is the octopus merge base of `HEAD`,
    // the head and itself. It is one of `HEAD`'s ancestors, so that is the
    // same as asking whether the head has it: then nothing was rewritten
    // under the branch, and the head is the upstream.
    const head = r.heads[0].oid;
    var upstream = head;
    if (r.forked) |fork| {
        if (!try rev_walk.isAncestor(gpa, io, db, .{ .ancestor = fork, .descendant = head }, .{})) upstream = fork;
    }
    var rebase_options = options.rebasing;
    rebase_options.onto = head;
    rebase_options.onto_name = null;
    rebase_options.upstream_name = null;
    rebase_options.autostash = plan.autostash;
    rebase_options.interactive = plan.mode == .rebase_interactive;
    rebase_options.reflog_action = plan.reflog_action;
    return .{ .rebased = try rebase.start(gpa, io, repo, upstream, rebase_options) };
}

/// git's `already_up_to_date`: `HEAD` has every head.
fn upToDate(gpa: Allocator, io: Io, repo: *Repository, ours: Oid, heads: []const merging.Target) Self.Error!bool {
    for (heads) |head| {
        if (!try rev_walk.isAncestor(gpa, io, repo.objectDatabase(), .{ .ancestor = head.oid, .descendant = ours }, .{})) return false;
    }
    return true;
}

/// Read what the caller and the configuration say, as `cmd_pull` reads it
/// before anything else: `pull.ff`, where an explicit rebase overrides an
/// `only` from the configuration, then the rebase setting, and
/// `pull.autoStash`.
fn decide(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, remote: ?[]const u8, options: Options) Self.Error!Plan {
    const config = repo.configuration();
    // `git_pull_config` reads both with `git_config_bool`, which dies on
    // anything else.
    _ = try config.getBool("rebase.autostash", false);
    const configured_autostash: ?bool = if (config.has("pull.autostash")) try config.getBool("pull.autostash", false) else null;
    var plan: Plan = .{
        .mode = .merge,
        .mode_unspecified = false,
        .fast_forward = options.fast_forward,
        .autostash = options.autostash orelse configured_autostash,
        .reflog_action = options.reflog_action orelse try defaultAction(arena, remote, options.fetch.refspecs),
        .branch = null,
    };
    if (try repo.refStore().currentBranch(gpa, io)) |name| {
        defer gpa.free(name);
        plan.branch = try remote_mod.Branch.get(gpa, config, name);
    }
    errdefer if (plan.branch) |*b| b.deinit();
    if (plan.fast_forward == null) {
        plan.fast_forward = try configuredFastForward(config);
        if (options.mode != null and plan.fast_forward == .only) plan.fast_forward = .allow;
    }
    if (options.mode) |mode| {
        plan.mode = mode;
        return plan;
    }
    if (plan.branch) |*b| {
        if (config.find(try arena.print("branch.{s}.rebase", .{b.name}))) |entry| {
            plan.mode = try parseMode(entry.value);
            return plan;
        }
    }
    if (config.find("pull.rebase")) |entry| {
        plan.mode = try parseMode(entry.value);
        return plan;
    }
    plan.mode_unspecified = true;
    return plan;
}

/// `pull` and the words after it, as `set_reflog_message` would have
/// them from a command line naming only these.
fn defaultAction(arena: Allocator, remote: ?[]const u8, refspecs: []const []const u8) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "pull");
    if (remote) |name| try text.print(arena, " {s}", .{name});
    for (refspecs) |spec| try text.print(arena, " {s}", .{spec});
    return text.items;
}

/// git's `config_get_ff`: `pull.ff` a boolean, or `only`.
fn configuredFastForward(config: *const config_mod.Config) Self.Error!?merging.FastForward {
    const entry = config.find("pull.ff") orelse return null;
    const value = entry.value orelse return .allow;
    if (config_mod.parseBool(value)) |on| return if (on) .allow else .never else |_| {}
    if (std.mem.eql(u8, value, "only")) return .only;
    return error.InvalidFastForwardSetting;
}

/// git's `rebase_parse_value`; a bare name is true.
fn parseMode(raw: ?[]const u8) Self.Error!Mode {
    const value = raw orelse return .rebase;
    if (config_mod.parseBool(value)) |on| return if (on) .rebase else .merge else |_| {}
    if (std.mem.eql(u8, value, "merges") or std.mem.eql(u8, value, "m")) return .rebase_merges;
    if (std.mem.eql(u8, value, "interactive") or std.mem.eql(u8, value, "i")) return .rebase_interactive;
    return error.InvalidRebaseSetting;
}

/// `error.UnmergedIndex` when the index holds a conflict, git's
/// `die_resolve_conflict`, its path in `blocked`.
fn requireMerged(io: Io, repo: *Repository, blocked: ?*three_way.Blocked) Self.Error!void {
    var index = try repo.openIndex(io);
    defer index.deinit();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (blocked) |b| b.set(entry.path);
            return error.UnmergedIndex;
        }
    }
}

/// Whether the index has nothing in it: git's `is_index_unborn`.
fn indexEmpty(io: Io, repo: *Repository) Self.Error!bool {
    var index = try repo.openIndex(io);
    defer index.deinit();
    return index.entries.items.len == 0;
}

/// git's `get_rebase_fork_point`: where the branch forked from the
/// remote-tracking ref of the first refspec, or of its upstream when none
/// was named and the remote is the branch's.
fn forkPointFor(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, plan: Plan, remote: ?[]const u8, refspecs: []const []const u8) Self.Error!?Oid {
    const branch = if (plan.branch) |*b| b else return null;
    const tracking = if (refspecs.len != 0)
        try trackingRef(arena, remote.?, refspecs[0], repo.objectFormat())
    else
        try upstreamRef(gpa, arena, repo, branch, remote);
    const ref = tracking orelse return null;
    const tip = (try repo.refStore().resolve(gpa, io, try arena.print("refs/heads/{s}", .{branch.name}))) orelse return null;
    gpa.free(tip.name);
    return fork_point.forkPoint(gpa, io, repo, .{ .ref = ref, .commit = tip.oid });
}

/// git's `get_tracking_branch`: the ref a refspec's branch is kept in,
/// assuming the default mapping, `refs/remotes/<remote>/<branch>` -- or
/// `refs/heads/<branch>` from `.`. `null` for a source that is not a
/// branch.
fn trackingRef(arena: Allocator, remote: []const u8, text: []const u8, format: hash.Kind) Self.Error!?[]const u8 {
    const spec = refspec_mod.Refspec.parse(text, .fetch, format) catch return error.InvalidRefspec;
    var source = spec.src;
    if (source.len == 0 or std.mem.eql(u8, source, "HEAD")) {
        source = "HEAD";
    } else if (std.mem.startsWith(u8, source, "heads/")) {
        source = source["heads/".len..];
    } else if (std.mem.startsWith(u8, source, "refs/heads/")) {
        source = source["refs/heads/".len..];
    } else if (std.mem.startsWith(u8, source, "refs/") or std.mem.startsWith(u8, source, "tags/") or std.mem.startsWith(u8, source, "remotes/")) {
        return null;
    }
    if (std.mem.eql(u8, remote, ".")) return try arena.print("refs/heads/{s}", .{source});
    return try arena.print("refs/remotes/{s}/{s}", .{ remote, source });
}

/// git's `get_upstream_branch`: the remote-tracking ref of the branch's
/// first `branch.<name>.merge`, when the remote pulled from is the
/// branch's; the ref itself from `.`.
fn upstreamRef(gpa: Allocator, arena: Allocator, repo: *Repository, branch: *const remote_mod.Branch, remote: ?[]const u8) Self.Error!?[]const u8 {
    const config = repo.configuration();
    if (remote) |name| {
        if (!std.mem.eql(u8, name, branch.fetchRemote(config))) return null;
    }
    const configured = branch.remote orelse return null;
    if (branch.merge.len == 0) return null;
    if (std.mem.eql(u8, configured, ".")) return branch.merge[0];
    var found = try remote_mod.Remote.get(gpa, config, repo.objectFormat(), configured);
    defer found.deinit();
    for (found.fetch) |spec| {
        if (try spec.mapSource(arena, branch.merge[0])) |mapped| return mapped;
    }
    return null;
}

/// `die_no_merge_candidates`'s reasons, as errors.
fn noCandidates(plan: Plan, remote: ?[]const u8, refspecs: []const []const u8) Self.Error {
    if (refspecs.len != 0) return error.NoMergeCandidates;
    const branch = plan.branch orelse return error.NotOnABranch;
    if (remote) |name| {
        const configured = branch.remote orelse return error.BranchNotGiven;
        if (!std.mem.eql(u8, name, configured)) return error.BranchNotGiven;
    }
    if (branch.remote == null or branch.merge.len == 0) return error.NoDefaultUpstream;
    return error.UpstreamNotFetched;
}

/// git's `checkout_fast_forward` from `old` to `new`, under the index's
/// lock: the working tree brought along with a branch the fetch moved, or
/// to an unborn branch's first commit.
fn moveWorkTree(io: Io, repo: *Repository, old: ?Oid, new: Oid, options: merging.Options) Self.Error!void {
    var locked = try repo.lockIndex(io);
    defer locked.deinit(io);
    var moved = try three_way.fastForward(repo.allocator(), io, repo, .{ .index = &locked.index, .old = old, .new = new }, .{
        .blocked = options.blocked,
        .filters = options.filters,
        .programs = options.programs,
    });
    defer moved.deinit();
    try locked.commit(io);
}

/// git's `pull_into_void`: the head checked out over an empty tree, what
/// the index has kept, and the unborn branch made at it.
fn intoUnborn(gpa: Allocator, io: Io, repo: *Repository, current: head_mod.Head, head: merging.Target, options: merging.Options) Self.Error!Oid {
    try merging.verify(gpa, io, repo, &.{head}, options);
    try moveWorkTree(io, repo, null, try repo.commitTree(io, head.oid), options);
    try head_mod.advance(io, repo, current, head.oid, .{ .who = options.who, .message = "initial pull" });
    return head.oid;
}
