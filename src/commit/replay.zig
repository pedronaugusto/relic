//! `git replay`: commits made again on a new base without a working tree,
//! an index or any state between steps, and the refs that pointed at them
//! moved to the new ones in one transaction.
//!
//! It is git 2.55's `replay_revisions` and `cmd_replay`. The commits are
//! those `include` reaches and `exclude` does not, oldest first in graph
//! order (newest first to revert), each merged in memory onto where its
//! parent went: `--onto` puts them on a commit and moves the branches among
//! the revisions given (with `contained`, every branch on a commit
//! replayed); `--advance` puts them on a branch and moves that branch;
//! `--revert` reverts them, newest first, on a branch and moves it. A merge
//! commit is refused, as git refuses it. A conflict, or with `empty` set
//! to `abort` a commit left empty, stops it with no ref moved.

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
const sequencer = @import("sequencer.zig");
const ref_names = @import("../names.zig").ref;
const rev_walk = @import("../walk/walk.zig");
const rev_parse = @import("../rev_walk/rev_parse.zig");
const repo_mod = @import("../repo/repo.zig");
const refs_mod = @import("../refs/refs.zig");
const config_mod = @import("../config/config.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from replaying commits.
pub const Error = error{
    /// No revision to replay: "need some commits to replay".
    NoCommitsToReplay,
    /// `--advance` or `--revert` naming no one ref: "argument to
    /// --advance must be a reference".
    NotAReference,
    /// `--advance` or `--revert` with more than one revision to replay:
    /// "cannot be used with multiple revision ranges because the ordering
    /// would be ill-defined".
    MultipleRanges,
    /// `--ref` where the revisions name more than one ref: "'--ref' cannot
    /// be used with multiple revision ranges".
    RefWithMultipleRanges,
    /// `--ref` and `--contained` together.
    RefWithContained,
    /// `--ref` naming no ref under `refs/`: "is not a valid refname".
    InvalidRefName,
    /// `replay.refAction` neither `update` nor `print`.
    InvalidRefAction,
    /// "replaying merge commits is not supported yet!"
    MergeCommit,
    NotACommit,
} || three_way.Error || rev_walk.Error || rev_parse.Error || pretty.Decorations.LoadError || repo_mod.WriteError ||
    refs_mod.TransactionError || refs_mod.ReadError || error{ InvalidEncodingSetting, UnsupportedEncoding };

/// Where the commits go, and which refs move with them.
pub const Target = union(enum) {
    /// `--onto <revision>`.
    onto: Onto,
    /// `--advance <branch>`: onto the branch, which moves to the last
    /// commit made.
    advance: []const u8,
    /// `--revert <branch>`: each commit reverted, newest first, onto the
    /// branch, which moves to the last revert.
    revert: []const u8,

    pub const Onto = struct {
        revision: []const u8,
        /// `--contained`: every branch on a commit replayed moves, not
        /// only the ones the revisions name.
        contained: bool = false,
    };
};

/// What is replayed, and where.
pub const Inputs = struct {
    /// The revisions whose history is replayed: `B` of `A..B`.
    include: []const []const u8,
    /// The revisions whose history is not: `^A`, the `A` of `A..B`.
    exclude: []const []const u8 = &.{},
    /// `--ancestry-path=<commit>`: only what descends from these.
    ancestry_path: []const []const u8 = &.{},
    target: Target,
};

/// What happens to a commit the replay leaves with no change of its own.
pub const Empty = enum { drop, keep, abort };

/// What is done with the refs: `--ref-action`.
pub const RefAction = enum {
    /// Moved in one transaction.
    update,
    /// Left for the caller, git's `update <ref> <new> <old>` lines.
    print,
};

/// How commits are replayed.
pub const Options = struct {
    /// Who commits, and when; also who reverts, and who the reflog lines
    /// are by.
    who: object.Signature,
    /// `--ref <ref>`: the one ref that moves, to the last commit made,
    /// whatever the target would move.
    ref: ?[]const u8 = null,
    /// `null` reads `replay.refAction`, `update` when unset.
    ref_action: ?RefAction = null,
    /// A commit that had a change and is left with none.
    empty: Empty = .drop,
    /// The `reference-transaction` hook, or `null` for none.
    hooks: ?*hooks_mod.Runner = null,
    diagnostic: ?*repo_mod.Diagnostic = null,
};

/// One ref moved.
pub const Update = struct {
    ref: []const u8,
    old: Oid,
    new: Oid,
};

/// Where a replay stopped.
pub const Stop = struct {
    /// The commit that would not replay.
    commit: Oid,
    why: Why,

    pub const Why = enum {
        /// Its merge onto the new base conflicted.
        conflicted,
        /// It was left empty and `empty` is `abort`: "commit %s became
        /// empty after replay".
        became_empty,
    };
};

/// What a replay did.
pub const Outcome = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator.State,
    gpa: Allocator,
    /// The refs to move, in git's order; none when it stopped.
    updates: []const Update,
    /// Whether `updates` were made.
    updated: bool = false,
    stopped: ?Stop = null,

    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// `git replay`: the commits made and, as `ref_action` says, the refs
/// moved, logged as git logs them.
pub fn replay(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!Outcome {
    const action = options.ref_action orelse try configuredAction(repo.configuration());
    var outcome = try plan(gpa, io, repo, inputs, options);
    errdefer outcome.deinit();
    if (action == .print or outcome.stopped != null) return outcome;
    const log = switch (inputs.target) {
        .revert => |name| try gpa.print("replay --revert {s}", .{name}),
        .advance => |name| try gpa.print("replay --advance {s}", .{name}),
        .onto => |onto| blk: {
            // The name as given, not peeled: git's `repo_get_oid_committish`.
            const oid = try rev_parse.resolve(gpa, io, repo, onto.revision);
            var hex: [hash.max_hex_len]u8 = undefined;
            break :blk try gpa.print("replay --onto {s}", .{oid.hex(&hex)});
        },
    };
    defer gpa.free(log);
    try updateRefs(io, repo, outcome.updates, .{ .who = options.who, .message = log, .hooks = options.hooks });
    outcome.updated = true;
    return outcome;
}

/// How refs are moved.
pub const UpdateOptions = struct {
    who: object.Signature,
    message: []const u8,
    hooks: ?*hooks_mod.Runner = null,
};

/// The refs moved in one transaction, each from the value it had when
/// replayed: a ref moved since is refused, and nothing moves.
pub fn updateRefs(io: Io, repo: *Repository, updates: []const Update, options: UpdateOptions) Self.Error!void {
    if (updates.len == 0) return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    tx.hooks = options.hooks;
    for (updates) |u| {
        try tx.update(u.ref, .{ .direct = u.new }, if (u.old.isZero()) .must_not_exist else .{ .matches = u.old });
    }
    try tx.commit(io, .{ .who = options.who, .message = options.message });
}

/// git's `replay_revisions`: the commits made and the refs that would
/// move, no ref touched.
pub fn plan(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    if (options.ref != null and inputs.target == .onto and inputs.target.onto.contained) return error.RefWithContained;

    var r: Run = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options, .mode = if (inputs.target == .revert) .revert else .pick };
    defer r.replayed.deinit(gpa);
    const setup = try r.setUp(inputs);
    var updates: std.ArrayList(Update) = .empty;
    const stopped = try r.replayAll(inputs, setup, &updates);
    if (stopped == null) if (setup.ref) |ref| {
        try updates.append(a, .{ .ref = ref, .old = setup.ref_old, .new = r.last });
    };
    return .{
        .arena = arena_state.state,
        .gpa = gpa,
        .updates = if (stopped == null) updates.items else &.{},
        .stopped = stopped,
    };
}

/// `replay.refAction`.
fn configuredAction(config: *const config_mod.Config) Error!RefAction {
    const entry = config.find("replay.refaction") orelse return .update;
    const text = entry.value orelse return error.InvalidRefAction;
    if (std.mem.eql(u8, text, "update")) return .update;
    if (std.mem.eql(u8, text, "print")) return .print;
    return error.InvalidRefAction;
}

const Mode = enum { pick, revert };

/// What `set_up_replay_mode` and `--ref` decide.
const Setup = struct {
    onto: Oid,
    /// The refs `--onto` may move: those the revisions name, each by one
    /// ref.
    update_refs: std.StringHashMapUnmanaged(void) = .empty,
    contained: bool = false,
    /// The one ref that moves at the end, when one does: `--ref`, or the
    /// branch `--advance` or `--revert` names.
    ref: ?[]const u8 = null,
    ref_old: Oid,
    detached_head: bool,
};

const Run = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,
    mode: Mode,
    replayed: Oid.Map(Oid) = .empty,
    last: Oid = undefined,
    /// Where the last pick stopped.
    stop: ?Stop = null,

    fn setUp(r: *Run, inputs: Inputs) Error!Setup {
        const head = try r.repo.refStore().read(r.a, r.io, "HEAD");
        const detached = if (head) |h| h != .symbolic else true;
        if (inputs.include.len == 0) return error.NoCommitsToReplay;
        var positive: std.StringHashMapUnmanaged(void) = .empty;
        for (inputs.include) |name| {
            const found = (try rev_parse.dwimRef(r.a, r.io, r.repo, name)) orelse continue;
            if (found.count == 1) try positive.put(r.a, found.ref, {});
        }
        var setup: Setup = .{ .onto = undefined, .ref_old = undefined, .detached_head = detached };
        switch (inputs.target) {
            .onto => |onto| {
                setup.onto = try r.commitOf(onto.revision);
                setup.update_refs = positive;
                setup.contained = onto.contained;
            },
            .advance, .revert => |name| {
                const found = (try rev_parse.dwimRef(r.a, r.io, r.repo, name)) orelse return error.NotAReference;
                if (found.count != 1) return error.NotAReference;
                setup.onto = try r.commitOf(found.ref);
                if (inputs.include.len > 1) return error.MultipleRanges;
                setup.ref = found.ref;
            },
        }
        if (r.options.ref) |ref| {
            if (inputs.target == .onto and setup.update_refs.count() > 1) return error.RefWithMultipleRanges;
            if (!std.mem.startsWith(u8, ref, "refs/") or !ref_names.checkFormat(ref, .{})) return error.InvalidRefName;
            setup.ref = ref;
            setup.ref_old = if (try r.repo.refStore().resolve(r.a, r.io, ref)) |found| found.oid else Oid.zero(r.repo.objectFormat());
        } else setup.ref_old = setup.onto;
        return setup;
    }

    /// Every commit in turn; where it stopped, or `null`.
    fn replayAll(r: *Run, inputs: Inputs, setup: Setup, updates: *std.ArrayList(Update)) Error!?Stop {
        var walk: rev_walk.Walk = .init(r.gpa, r.repo.objectDatabase());
        defer walk.deinit();
        walk.sort = .topological;
        walk.reverse = r.mode == .pick;
        for (inputs.include) |name| try walk.push(try r.commitOf(name));
        for (inputs.exclude) |name| try walk.hide(try r.commitOf(name));
        var bottoms: std.ArrayList(Oid) = .empty;
        for (inputs.ancestry_path) |name| try bottoms.append(r.a, try r.commitOf(name));
        walk.ancestry_path = bottoms.items;
        var decorations: ?pretty.Decorations = null;
        defer if (decorations) |*d| d.deinit();
        r.last = setup.onto;
        while (try walk.next(r.io)) |walked| {
            if (walked.parents.len > 1) return error.MergeCommit;
            const made = (try r.pick(walked.oid, walked.parents, setup.onto)) orelse return r.stop;
            r.last = made;
            try r.replayed.put(r.gpa, walked.oid, made);
            if (setup.ref != null) continue;
            if (decorations == null) decorations = try pretty.Decorations.load(r.gpa, r.io, r.repo, null);
            var node = decorations.?.of(walked.oid);
            while (node) |d| : (node = d.next) {
                if (d.kind != .local and d.kind != .head) continue;
                // HEAD on a branch moves with it.
                if (d.kind == .head and !setup.detached_head) continue;
                if (!setup.contained and !setup.update_refs.contains(d.name)) continue;
                try updates.append(r.a, .{ .ref = try r.a.dupe(u8, d.name), .old = walked.oid, .new = made });
            }
        }
        return null;
    }

    /// git's `pick_regular_commit`: the commit made, the base it would
    /// have been where it was left empty and is dropped, or `null` where
    /// it stopped.
    fn pick(r: *Run, oid: Oid, parents: []const Oid, onto: Oid) Error!?Oid {
        const repo = r.repo;
        const base: ?Oid = if (parents.len != 0) parents[0] else null;
        const base_tree = if (base) |b| try repo.commitTree(r.io, b) else repo.objectFormat().emptyTree();
        const fallback = if (r.mode == .revert) r.last else onto;
        const replayed_base = if (base) |b| r.replayed.get(b) orelse fallback else fallback;
        const replayed_base_tree = try repo.commitTree(r.io, replayed_base);
        const tree = try repo.commitTree(r.io, oid);
        var merged = try three_way.inCore(r.gpa, r.io, repo, switch (r.mode) {
            .pick => .{ .base = base_tree, .ours = replayed_base_tree, .theirs = tree },
            // The diff reversed: the commit is the base, its parent theirs.
            .revert => .{ .base = tree, .ours = replayed_base_tree, .theirs = base_tree },
        }, .{ .basic = true });
        defer merged.deinit();
        if (!merged.isClean()) {
            r.stop = .{ .commit = oid, .why = .conflicted };
            return null;
        }
        if (merged.tree.eql(replayed_base_tree) and !tree.eql(base_tree)) switch (r.options.empty) {
            .drop => return replayed_base,
            .keep => {},
            .abort => {
                r.stop = .{ .commit = oid, .why = .became_empty };
                return null;
            },
        };
        return try r.commit(oid, merged.tree, replayed_base);
    }

    /// git's `create_commit`: `tree` on `parent`, with the message, author
    /// and extra headers of `based_on` in a pick, a revert's message and
    /// the committer as author in a revert; never signed.
    fn commit(r: *Run, based_on: Oid, tree: Oid, parent: Oid) Error!Oid {
        const db = r.repo.objectDatabase();
        const found = try db.read(r.io, based_on);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        const shown = try pretty.reencodeCommit(r.a, found.bytes, try message.commitEncoding(r.repo.configuration()));
        const source = try object.Commit.parse(r.a, r.repo.objectFormat(), shown.bytes);
        var extra: std.ArrayList(object.ExtraHeader) = .empty;
        for (source.extra) |header| {
            if (std.mem.eql(u8, header.name, "gpgsig") or std.mem.eql(u8, header.name, "gpgsig-sha256")) continue;
            try extra.append(r.a, header);
        }
        var text: std.ArrayList(u8) = .empty;
        const author = switch (r.mode) {
            .pick => blk: {
                try text.appendSlice(r.a, source.message);
                break :blk source.author;
            },
            .revert => blk: {
                const end = std.mem.findScalar(u8, source.message, '\n') orelse source.message.len;
                try sequencer.revertMessage(r.a, &text, source.message[0..end], based_on, null);
                break :blk r.options.who;
            },
        };
        return r.repo.writeCommit(r.io, .{
            .tree = tree,
            .parents = &.{parent},
            .author = author,
            .committer = r.options.who,
            .message = text.items,
            .extra = extra.items,
            .signing = .{ .sign = .never },
        }, .{ .diagnostic = r.options.diagnostic });
    }

    /// The commit `name` peels to.
    fn commitOf(r: *Run, name: []const u8) Error!Oid {
        return rev_parse.resolve(r.gpa, r.io, r.repo, try r.a.print("{s}^{{commit}}", .{name}));
    }
};
