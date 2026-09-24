//! A merge of three trees carried into the index and the working tree.
//!
//! Every command that edits history does this one step: git's merge,
//! cherry-pick, revert and rebase all merge two trees against a third and
//! leave the result where a person works. A resolved path is staged and
//! written; a conflicted one is left at stages 1, 2 and 3 with the
//! conflict-marked text in the file. What the step must never do is lose
//! work, so everything it would overwrite is checked before anything is
//! written: something staged is refused, as is a change in the working tree
//! to a path the merge rewrites or removes, and an untracked file where the
//! merge puts one. A path the merge does not touch keeps whatever changes it
//! has, and an ignored file in the way is replaced, both as in git.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const merge = @import("merge.zig");
const worktree = @import("worktree.zig");
const attributes = @import("attributes.zig");
const ignore = @import("ignore.zig");
const fs = @import("fs.zig");
const repo_mod = @import("repo.zig");
const ort = @import("ort.zig");
const revwalk = @import("revwalk.zig");
const config_mod = @import("config.zig");
const strategy = @import("strategy.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Repository = repo_mod.Repository;

/// Errors from carrying a merge into the working tree.
pub const Error = error{
    /// The index already holds a conflict, which has to be resolved first.
    UnmergedIndex,
    /// The index does not describe the tree the merge starts from:
    /// something is staged.
    DirtyIndex,
    /// A path the merge rewrites or removes has changes in the working tree.
    LocalChangesWouldBeOverwritten,
    /// The repository has no working tree.
    BareRepository,
    /// `diff.algorithm` names no line diff git has.
    UnknownDiffAlgorithm,
    /// `merge.renormalize` asks for each side to be put through the
    /// line-ending conversion before it is merged, which this release does
    /// not do.
    RenormalizeRequested,
} || merge.Error || worktree.Error || repo_mod.Error || revwalk.Error || strategy.Error;

/// Where a refusal writes the path that caused it, so a caller can say which
/// file stood in the way without anything being allocated.
pub const Blocked = merge.Blocked;

/// How a merge is carried out.
pub const Options = struct {
    /// Labels, conflict style and favoured side for the content merges, and
    /// the line diff they start from: histogram, which is what git's merge
    /// machinery diffs with. `diff.algorithm` and then `strategy_options`
    /// have their say over the line diff and the favoured side.
    blob: merge.BlobOptions = .{ .algorithm = .histogram },
    /// The `-X` words, in the order given: `strategy.Settings.apply`.
    strategy_options: []const []const u8 = &.{},
    /// Where a refusal writes the path that caused it.
    blocked: ?*Blocked = null,
    /// Keep the inner merges' messages, as git does at
    /// `GIT_MERGE_VERBOSITY=5`: `ort.Options.inner_messages`. So does a
    /// `merge.verbosity` of 5 or more.
    inner_messages: bool = false,
};

/// One conflicted path.
pub const Conflict = struct {
    /// Owned by the outcome.
    path: []const u8,
    kind: merge.Conflict.Kind,
};

/// What a merge left behind.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// Sorted by path. Empty when the merge was clean.
    conflicts: []Conflict,
    /// The merged tree, when the merge was clean.
    tree: ?Oid,
    /// The tree of the working tree's merged state, markers and all: what
    /// git records as `AUTO_MERGE`. The merged tree when the merge was clean.
    auto_merge: Oid,
    /// Files written into the working tree.
    written: u32,
    /// Files removed from it.
    removed: u32,
    /// What git's merge says about the paths it merged, grouped by path.
    messages: []const ort.Message = &.{},

    /// Whether every path reconciled.
    pub fn isClean(o: *const Outcome) bool {
        return o.conflicts.len == 0;
    }

    /// Release the outcome.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

const TreeEntry = worktree.TreeEntry;

/// Merge `theirs` into `ours` against `base`, trees all, and leave the result
/// in `index` and the repository's working tree.
///
/// `index` must describe `ours` exactly, with nothing staged beyond it:
/// `ours` is `HEAD`'s tree for a command that commits the result, and the
/// index's own tree for one that only stages it. The caller writes the index
/// afterwards; nothing about `HEAD` or any ref moves here.
pub fn apply(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *Index,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
    options: Options,
) Error!Outcome {
    return run(gpa, io, repo, index, .{ .trees = .{ .base = base, .ours = ours, .theirs = theirs } }, options);
}

/// Merge the commit `theirs` into the commit `ours`, their merge bases
/// merged into one first as git's recursive merge does, and leave the
/// result in `index` and the working tree. `bases` is in the order git
/// merges them, the oldest first, or `null` to find them. The labels'
/// `base` is not used: git names the ancestor itself.
pub fn applyCommits(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *Index,
    ours: Oid,
    theirs: Oid,
    bases: ?[]const Oid,
    options: Options,
) Error!Outcome {
    return run(gpa, io, repo, index, .{ .commits = .{ .ours = ours, .theirs = theirs, .bases = bases } }, options);
}

const Sides = union(enum) {
    trees: struct { base: ?Oid, ours: Oid, theirs: Oid },
    commits: struct { ours: Oid, theirs: Oid, bases: ?[]const Oid },
};

fn run(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *Index,
    sides: Sides,
    options: Options,
) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = repo.work_dir orelse return error.BareRepository;
    const db = &repo.odb;

    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (options.blocked) |b| b.set(entry.path);
            return error.UnmergedIndex;
        }
    }

    const ours = switch (sides) {
        .trees => |t| t.ours,
        .commits => |c| try repo.commitTree(io, c.ours),
    };
    // The index must be exactly `ours`.
    var our_entries = try worktree.flatten(arena, io, db, ours);
    for (index.entries.items) |entry| {
        const want = our_entries.get(entry.path);
        if (want == null or want.?.mode != entry.mode or !want.?.oid.eql(entry.oid) or entry.intent_to_add) {
            if (options.blocked) |b| b.set(entry.path);
            return error.DirtyIndex;
        }
    }
    if (index.entries.items.len != our_entries.count()) {
        var it = our_entries.keyIterator();
        while (it.next()) |path| {
            if (index.find(path.*) == null) {
                if (options.blocked) |b| b.set(path.*);
                return error.DirtyIndex;
            }
        }
    }

    var rules = repo.worktreeRules();
    rules.required_filters = try repo.requiredFilters(arena);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;

    const settings = try configuredSettings(repo, options);
    if (settings.renormalize) return error.RenormalizeRequested;
    var submodules: SubmoduleOpener = .{ .gpa = gpa, .io = io, .wt = wt };
    defer submodules.deinit();
    var ort_options: ort.Options = .{
        .labels = options.blob.labels,
        .conflict_style = options.blob.conflict_style,
        .favor = settings.favor,
        .algorithm = settings.algorithm,
        .minimal = settings.minimal,
        .renames = settings.renames,
        .rename_score = settings.rename_score,
        .rename_limit = configuredRenameLimit(repo),
        .directory_renames = configuredDirectoryRenames(repo),
        .attributes = &attrs,
        .attributes_dir = wt,
        .configured_drivers = try configuredDrivers(arena, repo),
        .submodules = .{ .context = &submodules, .openFn = SubmoduleOpener.open },
        .abbrev_len = @import("abbrev.zig").defaultLength(&repo.config, db),
        .blocked = options.blocked,
        .inner_messages = options.inner_messages or (repo.config.getInt("merge.verbosity", 2) catch 2) >= 5,
    };
    var merged = switch (sides) {
        .trees => |t| try ort.mergeTrees(gpa, io, db, t.base, t.ours, t.theirs, ort_options),
        .commits => |c| blk: {
            ort_options.labels.base = "";
            break :blk try ort.mergeCommits(gpa, io, db, c.ours, c.theirs, c.bases, ort_options);
        },
    };
    defer merged.deinit();
    var result = try merge.fromOrt(gpa, io, db, &merged);
    defer result.deinit();

    // What each path the merge touches should hold in the working tree.
    var desired: std.StringArrayHashMapUnmanaged(?TreeEntry) = .empty;
    for (result.index.entries.items) |entry| {
        if (entry.stage != 0) continue;
        try desired.put(arena, try arena.dupe(u8, entry.path), .{ .mode = entry.mode, .oid = entry.oid });
    }
    for (result.conflicts) |conflict| {
        const side = conflict.result orelse continue;
        try desired.put(arena, try arena.dupe(u8, conflict.path), .{ .mode = side.mode, .oid = side.oid });
    }
    const messages = try ort.dupeMessages(arena, merged.messages);
    var our_it = our_entries.keyIterator();
    while (our_it.next()) |path| {
        if (!desired.contains(path.*)) try desired.put(arena, path.*, null);
    }

    var changes: std.ArrayList([]const u8) = .empty;
    var updates: std.StringArrayHashMapUnmanaged(?TreeEntry) = .empty;
    for (desired.keys(), desired.values()) |path, want| {
        const have = our_entries.get(path);
        if (sameEntry(have, want)) continue;
        try changes.append(arena, path);
        try updates.put(arena, path, want);
    }
    std.mem.sort([]const u8, changes.items, {}, lessThanPath);

    // Nothing is written until every change has been checked, by the same
    // rules a checkout keeps.
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var obstructions: worktree.Obstructions = .init(gpa);
    defer obstructions.deinit();
    worktree.verifyUpdates(gpa, io, wt, index, &updates, .{ .rules = rules, .ignore = &ignore_rules, .obstructions = &obstructions }) catch |err| {
        if (obstructions.first()) |path| {
            if (options.blocked) |b| b.set(path);
        }
        return err;
    };

    // Removals first, so that a directory the merge turns into a file is
    // gone before the file is written.
    var outcome_removed: u32 = 0;
    var outcome_written: u32 = 0;
    var i = changes.items.len;
    while (i > 0) {
        i -= 1;
        const path = changes.items[i];
        if (desired.get(path).? != null) continue;
        const entry = index.find(path).?;
        if (entry.skip_worktree) continue;
        if (entry.mode == .gitlink) {
            // Only an empty submodule directory goes, as with git.
            wt.deleteDir(io, path) catch {};
            outcome_removed += 1;
            continue;
        }
        try worktree.removeEntry(io, wt, path);
        outcome_removed += 1;
    }

    var stats: std.StringHashMapUnmanaged(fs.Stat) = .empty;
    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    for (result.conflicts) |conflict| try conflicted.put(arena, conflict.path, {});
    for (changes.items) |path| {
        const want = (desired.get(path).?) orelse continue;
        if (index.find(path)) |entry| {
            // A clean change to a path outside the sparse patterns stays out
            // of the working tree; a conflict is brought in, because someone
            // has to resolve it.
            if (entry.skip_worktree and !conflicted.contains(path)) continue;
        }
        if (try fs.statAt(io, wt, path)) |found| {
            if (found.kind == .directory) {
                // A submodule's checkout is left as it is, as git leaves it
                // without `--recurse-submodules`; the index records the
                // new commit.
                if (want.mode == .gitlink) {
                    if (index.find(path)) |old| {
                        if (old.mode == .gitlink) continue;
                    }
                }
                wt.deleteTree(io, path) catch {};
            }
        }
        const written = try worktree.writeEntry(gpa, io, wt, db, path, want.mode, want.oid, rules);
        try stats.put(arena, path, written.stat);
        outcome_written += 1;
    }

    // The new index: unchanged entries keep what the old index knew about
    // them, changed ones take the stat of what was just written, and a
    // conflict is its stages.
    var fresh: std.ArrayList(index_mod.Entry) = .empty;
    for (result.index.entries.items) |entry| {
        var copy = entry;
        copy.path = try arena.dupe(u8, entry.path);
        if (entry.stage == 0) {
            if (index.find(entry.path)) |old| {
                if (old.oid.eql(entry.oid) and old.mode == entry.mode) {
                    copy = old.*;
                    copy.path = try arena.dupe(u8, entry.path);
                } else {
                    copy.skip_worktree = old.skip_worktree;
                }
            }
            if (stats.get(entry.path)) |stat| copy.stat = stat;
        }
        try fresh.append(arena, copy);
    }
    index.clear();
    try index.addMany(fresh.items);
    const cache_tree = try index.cacheTree();
    cache_tree.invalidateAll();

    const conflicts = try arena.alloc(Conflict, result.conflicts.len);
    for (result.conflicts, conflicts) |conflict, *out| {
        out.* = .{ .path = try arena.dupe(u8, conflict.path), .kind = conflict.kind };
    }
    std.mem.sort(Conflict, conflicts, {}, lessThanConflict);

    var merged_tree: ?Oid = null;
    const auto_merge: Oid = merged.tree;
    if (result.isClean()) {
        merged_tree = merged.tree;
        cache_tree.root.entry_count = @intCast(index.entries.items.len);
        cache_tree.root.oid = merged.tree;
    }
    // The merge's index is `unpack_trees`' result in git, which remembers
    // no resolutions.
    index.dropResolveUndo();
    try db.syncBatch(io);

    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .conflicts = conflicts,
        .tree = merged_tree,
        .auto_merge = auto_merge,
        .written = outcome_written,
        .removed = outcome_removed,
        .messages = messages,
    };
}

/// The submodules a merge meets, opened from the working tree where they
/// are checked out, as git finds them.
const SubmoduleOpener = struct {
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    opened: std.ArrayList(*Opened) = .empty,

    const Opened = struct { repo: Repository, tips: []Oid };

    fn deinit(s: *SubmoduleOpener) void {
        for (s.opened.items) |o| {
            s.gpa.free(o.tips);
            o.repo.deinit(s.io);
            s.gpa.destroy(o);
        }
        s.opened.deinit(s.gpa);
    }

    fn open(context: *anyopaque, path: []const u8) ?ort.SubmoduleHistory {
        const s: *SubmoduleOpener = @ptrCast(@alignCast(context));
        return s.openInner(path) catch null;
    }

    fn openInner(s: *SubmoduleOpener, path: []const u8) !?ort.SubmoduleHistory {
        var dir = s.wt.openDir(s.io, path, .{}) catch return null;
        defer dir.close(s.io);
        // Only a checkout of its own: a directory with a `.git` in it.
        dir.access(s.io, ".git", .{}) catch return null;
        const opened = try s.gpa.create(Opened);
        errdefer s.gpa.destroy(opened);
        opened.repo = try Repository.open(s.gpa, s.io, dir, .{});
        errdefer opened.repo.deinit(s.io);
        var tips: std.ArrayList(Oid) = .empty;
        errdefer tips.deinit(s.gpa);
        if (try opened.repo.refs.resolve(s.gpa, s.io, "HEAD")) |r| {
            s.gpa.free(r.name);
            try tips.append(s.gpa, r.oid);
        }
        var listing = try opened.repo.refs.list(s.gpa, s.io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            const resolved = (try opened.repo.refs.resolve(s.gpa, s.io, entry.name)) orelse continue;
            s.gpa.free(resolved.name);
            const peeled = opened.repo.peel(s.io, resolved.oid) catch continue;
            try tips.append(s.gpa, peeled);
        }
        opened.tips = try tips.toOwnedSlice(s.gpa);
        try s.opened.append(s.gpa, opened);
        return .{ .db = &opened.repo.odb, .tips = opened.tips };
    }
};

/// What the merge does with content and renames: `options.blob`'s start,
/// then configuration -- `diff.algorithm`, `merge.renames`,
/// `merge.renormalize` -- then each strategy option in turn, as git's merge
/// configuration and `parse_merge_opt` have it.
fn configuredSettings(repo: *Repository, options: Options) Error!strategy.Settings {
    var settings: strategy.Settings = .{
        .favor = options.blob.favor,
        .algorithm = options.blob.algorithm,
        .minimal = options.blob.minimal,
        .renames = configuredRenames(repo),
        .renormalize = repo.config.getBool("merge.renormalize", false) catch false,
    };
    if (repo.config.get("diff.algorithm")) |text| {
        settings.configureAlgorithm(text) orelse return error.UnknownDiffAlgorithm;
    }
    for (options.strategy_options) |word| try settings.apply(word);
    return settings;
}

/// `merge.renameLimit`, then `diff.renameLimit`; zero for git's default.
fn configuredRenameLimit(repo: *Repository) i64 {
    for ([_][]const u8{ "merge.renamelimit", "diff.renamelimit" }) |key| {
        const text = repo.config.get(key) orelse continue;
        return config_mod.parseInt(text) catch 0;
    }
    return 0;
}

/// `merge.directoryRenames`: `true`, `false` or `conflict`, which is the
/// default.
fn configuredDirectoryRenames(repo: *Repository) ort.DirectoryRenames {
    const text = repo.config.get("merge.directoryrenames") orelse return .conflict;
    if (config_mod.parseBool(text)) |on| return if (on) .on else .off else |_| {}
    return .conflict;
}

fn sameEntry(a: anytype, b: ?TreeEntry) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.mode == b.?.mode and a.?.oid.eql(b.?.oid);
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanConflict(_: void, a: Conflict, b: Conflict) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Whether git's merge would follow renames: `merge.renames`, then
/// `diff.renames`, and on when neither says otherwise. `copies` is on.
fn configuredRenames(repo: *Repository) bool {
    for ([_][]const u8{ "merge.renames", "diff.renames" }) |key| {
        const text = repo.config.get(key) orelse continue;
        if (std.ascii.eqlIgnoreCase(text, "copies") or std.ascii.eqlIgnoreCase(text, "copy")) return true;
        return config_mod.parseBool(text) catch true;
    }
    return true;
}

/// The names `merge.<name>.driver` configures.
fn configuredDrivers(arena: Allocator, repo: *Repository) Allocator.Error![]const []const u8 {
    const names = try repo.config.subsections(arena, "merge");
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const key = try std.fmt.allocPrint(arena, "merge.{s}.driver", .{name});
        if (repo.config.get(key) != null) try out.append(arena, name);
    }
    return out.items;
}

/// Whether the file at `entry.path` holds something other than what the
/// index says: `worktree.differsFromIndex`.
pub const differsOnDisk = worktree.differsFromIndex;
