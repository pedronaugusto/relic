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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const index_mod = @import("../index/index.zig");
const merge = @import("merge.zig");
const worktree = @import("../checkout/checkout.zig");
const fs = @import("../fs/fs.zig");
const repo_mod = @import("../repo/repo.zig");
const ort = @import("ort.zig");
const octopus = @import("octopus.zig");
const revwalk = @import("../walk/walk.zig");
const config_mod = @import("../config/config.zig");
const strategy = @import("strategy.zig");
const convert = @import("../checkout/convert.zig");
const attributes = @import("../patterns/attributes.zig");
const filter = @import("../checkout/filter.zig");
const program = @import("../process/program.zig");
const diff = @import("../diff/diff.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const abbrev = @import("../odb/abbrev.zig");

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
} || merge.Error || worktree.Error || repo_mod.Error || revwalk.Error || strategy.Error || octopus.Error;

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
    /// The filter drivers and relic's own LFS the merged files are written
    /// through, and renormalized through, as `Repository.loadFilters` gives
    /// them. `null` passes every driver over and refuses a required one.
    filters: ?*const filter.Drivers = null,
    /// The permission to run the filters' programs.
    programs: ?program.Programs = null,
    /// Where a refusal writes the path that caused it.
    blocked: ?*Blocked = null,
    /// Keep the inner merges' messages, as git does at
    /// `GIT_MERGE_VERBOSITY=5`: `ort.Options.inner_messages`. So does a
    /// `merge.verbosity` of 5 or more.
    inner_messages: bool = false,
    /// Directory rename detection; `null` reads `merge.directoryRenames`.
    /// `git am`'s three-way fallback turns it off.
    directory_renames: ?ort.DirectoryRenames = null,
};

/// The index and tree identities for one working-tree merge.
pub const TreeInputs = struct {
    index: *Index,
    base: ?Oid = null,
    ours: Oid,
    theirs: Oid,
};

/// The index and commits for a recursive working-tree merge.
pub const CommitInputs = struct {
    index: *Index,
    ours: Oid,
    theirs: Oid,
    bases: ?[]const Oid = null,
};

/// The index and heads for an octopus working-tree merge.
pub const OctopusInputs = struct {
    index: *Index,
    head: Oid,
    heads: []const Oid,
};

/// One conflicted path.
pub const Conflict = struct {
    /// Owned by the outcome.
    path: []const u8,
    kind: merge.Conflict.Kind,
};

/// What a merge left behind.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

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
    /// Whether rename processing came out clean: `ort.Result.renames_clean`.
    renames_clean: bool = true,

    /// Whether the merge is clean: every path reconciled, and no rename
    /// conflict that leaves none conflicted.
    pub fn isClean(o: *const Outcome) bool {
        return o.renames_clean and o.conflicts.len == 0;
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
    inputs: TreeInputs,
    options: Options,
) Self.Error!Outcome {
    return run(gpa, io, repo, inputs.index, .{ .trees = .{ .base = inputs.base, .ours = inputs.ours, .theirs = inputs.theirs } }, options);
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
    inputs: CommitInputs,
    options: Options,
) Self.Error!Outcome {
    return run(gpa, io, repo, inputs.index, .{ .commits = .{ .ours = inputs.ours, .theirs = inputs.theirs, .bases = inputs.bases } }, options);
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
    const wt = repo.workDirectory() orelse return error.BareRepository;
    const db = repo.objectDatabase();

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
    // The index must be exactly `ours`. A cache tree whose root is valid
    // says what tree the index is, as git's `repo_index_has_changes` asks
    // it; without one, every entry is compared.
    try requireIndexIs(arena, io, db, index, ours, options.blocked);

    var rules = try repo.worktreeRules();
    rules.required_filters = try repo.requiredFilters(arena);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    rules.filters = options.filters;

    const settings = try configuredSettings(repo, options);
    // Renormalizing takes each side out and back in, and asks no index
    // whether a stored version kept its CRLF endings.
    var normalizer: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = rules.core,
        .required_filters = rules.required_filters,
        .drivers = rules.filters,
        .programs = options.programs,
    });
    defer normalizer.deinit();
    var submodules: SubmoduleOpener = .{ .gpa = gpa, .io = io, .wt = wt };
    defer submodules.deinit();
    var ort_options: ort.Options = .{
        .labels = options.blob.labels,
        .conflict_style = options.blob.conflict_style,
        .resolve = settings.resolve,
        .algorithm = settings.algorithm,
        .minimal = settings.minimal,
        .renames = settings.renames,
        .rename_score = settings.rename_score,
        .whitespace = settings.whitespace,
        .subtree_shift = settings.subtree_shift,
        .rename_limit = configuredRenameLimit(repo),
        .directory_renames = options.directory_renames orelse configuredDirectoryRenames(repo),
        .attributes = &attrs,
        .attributes_dir = wt,
        .configured_drivers = try configuredDrivers(arena, repo),
        .default_driver = repo.configuration().get("merge.default"),
        .submodules = .{ .context = &submodules, .openFn = SubmoduleOpener.open },
        .abbrev_len = abbrev.defaultLength(repo.configuration(), db),
        .blocked = options.blocked,
        .renormalize = if (settings.renormalize) &normalizer else null,
        .attributes_from_merge = if (wt.access(io, ".gitattributes", .{})) |_| false else |_| true,
        .inner_messages = options.inner_messages or (repo.configuration().getInt("merge.verbosity", 2) catch 2) >= 5,
    };
    var merged = switch (sides) {
        .trees => |t| try ort.trees(gpa, io, db, .{ .base = t.base, .ours = t.ours, .theirs = t.theirs }, ort_options),
        .commits => |c| blk: {
            ort_options.labels.base = "";
            break :blk try ort.commits(gpa, io, db, .{ .ours = c.ours, .theirs = c.theirs, .bases = c.bases }, ort_options);
        },
    };
    defer merged.deinit();
    return carry(gpa, io, repo, index, &arena_instance, ours, rules, .{
        .tree = merged.tree,
        .conflicted = merged.conflicted,
        .messages = merged.messages,
        .renormalize_read_attributes = merged.renormalize_read_attributes,
        .merged_attributes_blob = merged.merged_attributes_blob,
        .renames_clean = merged.renames_clean,
    }, options);
}

/// Merge the commits `heads` into the commit `head` as git's octopus
/// strategy does, `octopus.mergeCommits`, and leave the result in `index`
/// and the working tree. Only the last head may leave conflicts; a conflict
/// before it fails the whole merge with nothing written.
pub fn applyOctopus(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    inputs: OctopusInputs,
    options: Options,
) Self.Error!Outcome {
    const index = inputs.index;
    const head = inputs.head;
    const heads = inputs.heads;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const db = repo.objectDatabase();
    if (repo.workDirectory() == null) return error.BareRepository;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            if (options.blocked) |b| b.set(entry.path);
            return error.UnmergedIndex;
        }
    }
    const ours = try repo.commitTree(io, head);
    try requireIndexIs(arena, io, db, index, ours, options.blocked);
    var rules = try repo.worktreeRules();
    rules.required_filters = try repo.requiredFilters(arena);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    rules.filters = options.filters;
    var merged = try octopus.commits(gpa, io, db, .{ .head = head, .heads = heads }, .{ .conflict_style = options.blob.conflict_style });
    defer merged.deinit();
    return carry(gpa, io, repo, index, &arena_instance, ours, rules, .{
        .tree = merged.worktree_tree,
        .conflicted = merged.conflicted,
    }, options);
}

/// What a merge computed, for `carry` to put in place.
const Merged = struct {
    /// The working tree's merged state, markers and all.
    tree: Oid,
    conflicted: []const ort.Conflicted,
    messages: []const ort.Message = &.{},
    renormalize_read_attributes: bool = false,
    merged_attributes_blob: ?Oid = null,
    renames_clean: bool = true,
};

/// Remove the directory at `path` if it is empty, as git's `rmdir` for a
/// submodule's checkout: one with files in it, or already gone, stays as
/// it is.
fn removeIfEmpty(io: Io, wt: Io.Dir, path: []const u8) Io.Dir.DeleteDirError!void {
    wt.deleteDir(io, path) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound, error.NotDir => {},
        else => return err,
    };
}

/// Carry a merge from `ours` to `merged` into the index and the working
/// tree, everything it would overwrite checked first. The outcome takes
/// over `arena_instance`.
fn carry(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *Index,
    arena_instance: *std.heap.ArenaAllocator,
    ours: Oid,
    rules: worktree.Rules,
    merged: Merged,
    options: Options,
) Error!Outcome {
    const arena = arena_instance.allocator();
    const wt = repo.workDirectory() orelse return error.BareRepository;
    const db = repo.objectDatabase();
    // What the merge changes: the merged tree against ours, a walk past
    // every subtree the two share, so a pick costs what it changes.
    var tree_changes = try diff.tree(gpa, io, db, .{ .old = ours, .new = merged.tree }, .{});
    defer tree_changes.deinit();
    var desired: Desired = .empty;
    for (tree_changes.items) |change| {
        const path = try arena.dupe(u8, change.path());
        try desired.put(arena, path, if (change.new) |e| .{ .mode = e.mode, .oid = e.oid } else null);
    }
    const messages = try ort.dupeMessages(arena, merged.messages);
    // A conflict's stages, by path.
    var conflicted: std.array_hash_map.String(ort.Conflicted) = .empty;
    for (merged.conflicted) |c| try conflicted.put(arena, try arena.dupe(u8, c.path), c);

    var changes: std.ArrayList([]const u8) = .empty;
    var updates: std.array_hash_map.String(?TreeEntry) = .empty;
    for (desired.keys(), desired.values()) |path, want| {
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
    worktree.verifyUpdates(gpa, io, wt, .{ .index = index, .updates = &updates }, .{ .rules = rules, .ignore = &ignore_rules, .obstructions = &obstructions }) catch |err| {
        if (obstructions.first()) |path| {
            if (options.blocked) |b| b.set(path);
        }
        return err;
    };

    const outcome_removed = try removeGone(io, wt, index, changes.items, &desired);
    var write_attrs = try repo.loadAttrs(io);
    defer write_attrs.deinit();
    try mergedAttributes(arena, io, db, &write_attrs, merged, changes.items);
    var write_rules = rules;
    write_rules.attrs = &write_attrs;

    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = rules.core,
        .required_filters = rules.required_filters,
        .drivers = rules.filters,
        .programs = options.programs,
    });
    defer conv.deinit();
    var stats: std.StringHashMapUnmanaged(fs.Stat) = .empty;
    const outcome_written = try writeChanged(.{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .wt = wt,
        .db = db,
        .index = index,
        .conv = &conv,
        .attrs = &write_attrs,
        .rules = write_rules,
    }, changes.items, &desired, &conflicted, &stats);

    const cache_tree = try index.cacheTree();
    try updateIndex(arena, index, changes.items, &desired, &conflicted, &stats);

    const conflicts = try arena.alloc(Conflict, conflicted.count());
    for (conflicted.keys(), conflicted.values(), conflicts) |path, c, *out| {
        out.* = .{ .path = path, .kind = merge.Conflict.Kind.of(c.stages[0] != null, c.stages[1] != null, c.stages[2] != null) };
    }
    std.mem.sort(Conflict, conflicts, {}, lessThanConflict);

    var merged_tree: ?Oid = null;
    const auto_merge: Oid = merged.tree;
    if (conflicts.len == 0) {
        if (merged.renames_clean) merged_tree = merged.tree;
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
        .renames_clean = merged.renames_clean,
    };
}

/// Each path the merge changes, with what the merged tree has there:
/// `null` where it has nothing.
const Desired = std.array_hash_map.String(?TreeEntry);

/// Remove what the merge takes away, last path first, so that a directory
/// the merge turns into a file is gone before the file is written. How
/// many went.
fn removeGone(io: Io, wt: Io.Dir, index: *const Index, changes: []const []const u8, desired: *const Desired) Error!u32 {
    var removed: u32 = 0;
    var i = changes.len;
    while (i > 0) {
        i -= 1;
        const path = changes[i];
        if (desired.get(path).? != null) continue;
        // A path the merge removes is one ours, and so the index, has.
        const entry = index.find(path).?;
        if (entry.skip_worktree) continue;
        if (entry.mode == .gitlink) {
            // Only an empty submodule directory goes, as with git.
            if (try worktree.realLeadingPath(io, wt, path)) try removeIfEmpty(io, wt, path);
            removed += 1;
            continue;
        }
        try worktree.removeEntry(io, wt, path);
        removed += 1;
    }
    return removed;
}

/// The attributes git's checkout of the merge reads, into `write_attrs`:
/// the merged tree's own `.gitattributes` first, as git reads them from
/// the index it is writing, and a working tree file only for a directory
/// the tree has none in. A `.gitattributes` the merge brings therefore
/// applies to the files written with it, itself included -- except at the
/// top when renormalizing read attributes: git's checkout keeps the top
/// level its renormalizing read, the merge's own file or else the working
/// tree's as it was before anything is written, which `enter` reads first.
fn mergedAttributes(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    write_attrs: *attributes.Attrs,
    merged: Merged,
    changes: []const []const u8,
) Error!void {
    // Only the `.gitattributes` above a path being written can say how it
    // is written.
    var merged_entries = try attributesAbove(arena, io, db, merged.tree, changes);
    if (merged.renormalize_read_attributes) {
        _ = merged_entries.remove(".gitattributes");
        if (merged.merged_attributes_blob) |oid| {
            const found = try db.read(io, oid);
            defer db.allocator().free(found.bytes);
            try write_attrs.addText(try arena.dupe(u8, found.bytes), "", ".gitattributes", 1);
        }
    }
    try worktree.addTreeAttributes(arena, io, db, write_attrs, &merged_entries);
}

/// What `writeChanged` writes with.
const Writer = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    db: *odb_mod.Odb,
    index: *const Index,
    conv: *convert.Session,
    attrs: *attributes.Attrs,
    rules: worktree.Rules,
};

/// Write every file the merge changes, recording each one's stat in
/// `stats`. How many were written.
fn writeChanged(
    w: Writer,
    changes: []const []const u8,
    desired: *const Desired,
    conflicted: *const std.array_hash_map.String(ort.Conflicted),
    stats: *std.StringHashMapUnmanaged(fs.Stat),
) Error!u32 {
    var written_count: u32 = 0;
    for (changes) |path| {
        const want = (desired.get(path).?) orelse continue;
        if (w.index.find(path)) |entry| {
            // A clean change to a path outside the sparse patterns stays out
            // of the working tree; a conflict is brought in, because someone
            // has to resolve it.
            if (entry.skip_worktree and !conflicted.contains(path)) continue;
        }
        // Past a symbolic link nothing is removed; `writeEntry` refuses
        // the write.
        const in_tree = try worktree.realLeadingPath(w.io, w.wt, path);
        if (if (in_tree) try fs.statAt(w.io, w.wt, path) else null) |found| {
            if (found.kind == .directory) {
                // A submodule's checkout is left as it is, as git leaves it
                // without `--recurse-submodules`; the index records the
                // new commit.
                if (want.mode == .gitlink) {
                    if (w.index.find(path)) |old| {
                        if (old.mode == .gitlink) continue;
                    }
                }
                try w.wt.deleteTree(w.io, path);
            }
        }
        try w.attrs.enter(w.io, w.wt, path);
        const written = try worktree.writeEntry(w.gpa, w.io, w.wt, .{ .db = w.db, .conv = w.conv, .path = path, .mode = want.mode, .oid = want.oid, .rules = w.rules });
        try stats.put(w.arena, path, written.stat);
        written_count += 1;
    }
    return written_count;
}

/// The index, changed where the merge changed it and nowhere else: every
/// other entry keeps what the index knew about it, a changed one takes the
/// stat of what was just written, and a conflict is its stages.
fn updateIndex(
    arena: Allocator,
    index: *Index,
    changes: []const []const u8,
    desired: *const Desired,
    conflicted: *const std.array_hash_map.String(ort.Conflicted),
    stats: *const std.StringHashMapUnmanaged(fs.Stat),
) Error!void {
    var leaving: std.ArrayList([]const u8) = .empty;
    var coming: std.ArrayList(index_mod.Entry) = .empty;
    const cache_tree = try index.cacheTree();
    for (changes) |path| {
        cache_tree.invalidate(path);
        const old = index.find(path);
        if (old != null) try leaving.append(arena, path);
        if (conflicted.contains(path)) continue;
        const want = desired.get(path).? orelse continue;
        var entry: index_mod.Entry = .{ .path = path, .oid = want.oid, .mode = want.mode };
        if (old) |o| entry.skip_worktree = o.skip_worktree;
        if (stats.get(path)) |stat| entry.stat = stat;
        try coming.append(arena, entry);
    }
    for (conflicted.keys(), conflicted.values()) |path, c| {
        cache_tree.invalidate(path);
        if (!desired.contains(path) and index.find(path) != null) try leaving.append(arena, path);
        for (c.stages, 0..) |stage_entry, at| {
            const st = stage_entry orelse continue;
            // git's index takes a mode of nothing as a regular file.
            const mode = object.Mode.fromRaw(st.mode) catch .file;
            try coming.append(arena, .{ .path = path, .oid = st.oid, .mode = mode, .stage = @intCast(at + 1) });
        }
    }
    std.mem.sort([]const u8, leaving.items, {}, lessThanPath);
    index.removeMany(leaving.items);
    try index.addMany(coming.items);
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
        s.* = undefined;
    }

    fn open(context: *anyopaque, path: []const u8) ?ort.SubmoduleHistory {
        const s: *SubmoduleOpener = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a SubmoduleOpener
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
        if (try opened.repo.refStore().resolve(s.gpa, s.io, "HEAD")) |r| {
            s.gpa.free(r.name);
            try tips.append(s.gpa, r.oid);
        }
        var listing = try opened.repo.refStore().list(s.gpa, s.io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            const resolved = (try opened.repo.refStore().resolve(s.gpa, s.io, entry.name)) orelse continue;
            s.gpa.free(resolved.name);
            const peeled = opened.repo.peel(s.io, resolved.oid) catch continue;
            try tips.append(s.gpa, peeled);
        }
        opened.tips = try tips.toOwnedSlice(s.gpa);
        try s.opened.append(s.gpa, opened);
        return .{ .db = opened.repo.objectDatabase(), .tips = opened.tips };
    }
};

/// What the merge does with content and renames: `options.blob`'s start,
/// then configuration -- `diff.algorithm`, `merge.renames`,
/// `merge.renormalize` -- then each strategy option in turn, as git's merge
/// configuration and `parse_merge_opt` have it.
fn configuredSettings(repo: *Repository, options: Options) Error!strategy.Settings {
    var settings: strategy.Settings = .{
        .resolve = options.blob.resolve,
        .algorithm = options.blob.algorithm,
        .minimal = options.blob.minimal,
        .whitespace = options.blob.whitespace,
        .renames = configuredRenames(repo),
        .renormalize = repo.configuration().getBool("merge.renormalize", false) catch false,
    };
    if (repo.configuration().get("diff.algorithm")) |text| {
        settings.configureAlgorithm(text) orelse return error.UnknownDiffAlgorithm;
    }
    for (options.strategy_options) |word| try settings.apply(word);
    return settings;
}

/// `merge.renameLimit`, then `diff.renameLimit`; zero for git's default.
fn configuredRenameLimit(repo: *Repository) i64 {
    for ([_][]const u8{ "merge.renamelimit", "diff.renamelimit" }) |key| {
        const text = repo.configuration().get(key) orelse continue;
        return config_mod.parseInt(text) catch 0;
    }
    return 0;
}

/// `merge.directoryRenames`: `true`, `false` or `conflict`, which is the
/// default.
fn configuredDirectoryRenames(repo: *Repository) ort.DirectoryRenames {
    const text = repo.configuration().get("merge.directoryrenames") orelse return .conflict;
    if (config_mod.parseBool(text)) |on| return if (on) .on else .off else |_| {}
    return .conflict;
}

/// `error.DirtyIndex` unless `index` is exactly the tree `ours`, nothing
/// staged beyond it.
fn requireIndexIs(arena: Allocator, io: Io, db: *odb_mod.Odb, index: *Index, ours: Oid, blocked: ?*Blocked) Error!void {
    var plain = true;
    for (index.entries.items) |entry| {
        if (entry.intent_to_add) plain = false;
    }
    if (plain) {
        const cache_tree = try index.cacheTree();
        if (cache_tree.root.isValid() and cache_tree.root.oid != null and cache_tree.root.oid.?.eql(ours) and
            cache_tree.root.entry_count == @as(i64, @intCast(index.entries.items.len))) return;
    }
    var our_entries = try worktree.flatten(arena, io, db, ours);
    for (index.entries.items) |entry| {
        const want = our_entries.get(entry.path);
        if (want == null or want.?.mode != entry.mode or !want.?.oid.eql(entry.oid) or entry.intent_to_add) {
            if (blocked) |b| b.set(entry.path);
            return error.DirtyIndex;
        }
    }
    if (index.entries.items.len != our_entries.count()) {
        var it = our_entries.keyIterator();
        while (it.next()) |path| {
            if (index.find(path.*) == null) {
                if (blocked) |b| b.set(path.*);
                return error.DirtyIndex;
            }
        }
    }
}

/// The `.gitattributes` files of `tree` in the folders above `paths`, by
/// path, as `worktree.addTreeAttributes` takes them.
fn attributesAbove(arena: Allocator, io: Io, db: *odb_mod.Odb, tree: Oid, paths: []const []const u8) Error!std.StringHashMapUnmanaged(TreeEntry) {
    var out: std.StringHashMapUnmanaged(TreeEntry) = .empty;
    var looked: std.StringHashMapUnmanaged(void) = .empty;
    for (paths) |path| {
        var end: usize = 0;
        while (true) {
            const folder = path[0..end];
            if (!looked.contains(folder)) {
                try looked.put(arena, folder, {});
                const file = if (folder.len == 0) ".gitattributes" else try arena.print("{s}/.gitattributes", .{folder});
                if (try entryAt(io, db, tree, file)) |found| try out.put(arena, file, found);
            }
            const slash = std.mem.findScalarPos(u8, path, if (end == 0) 0 else end + 1, '/') orelse break;
            end = slash;
        }
    }
    return out;
}

/// The entry at `path` under `tree`, or `null`.
fn entryAt(io: Io, db: *odb_mod.Odb, tree: Oid, path: []const u8) Error!?TreeEntry {
    var at = tree;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        const found = try db.read(io, at);
        defer db.allocator().free(found.bytes);
        if (found.type != .tree) return null;
        const entry = (try object.Tree.parse(db.objectFormat(), found.bytes).find(part)) orelse return null;
        if (parts.peek() == null) return .{ .mode = entry.mode, .oid = entry.oid };
        if (!entry.mode.isTree()) return null;
        at = entry.oid;
    }
    return null;
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
        const text = repo.configuration().get(key) orelse continue;
        if (std.ascii.eqlIgnoreCase(text, "copies") or std.ascii.eqlIgnoreCase(text, "copy")) return true;
        return config_mod.parseBool(text) catch true;
    }
    return true;
}

/// The names `merge.<name>.driver` configures.
fn configuredDrivers(arena: Allocator, repo: *Repository) Allocator.Error![]const []const u8 {
    const names = try repo.configuration().subsections(arena, "merge");
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const key = try arena.print("merge.{s}.driver", .{name});
        if (repo.configuration().get(key) != null) try out.append(arena, name);
    }
    return out.items;
}

test "a merge reads the trees it changes, not the whole tree" {
    const testgit = @import("../testing/git.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    var name: [32]u8 = undefined;
    var text: [32]u8 = undefined;
    for (0..300) |i| try r.writeFile(io, try std.mem.print(&name, "d{d:0>3}/f", .{i}), try std.mem.print(&text, "{d}\n", .{i}));
    try r.exec(io, &.{ "add", "-A" });
    try r.exec(io, &.{ "commit", "-q", "-m", "base" });
    try r.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try r.writeFile(io, "d005/f", "theirs\n");
    try r.exec(io, &.{ "commit", "-q", "-am", "theirs" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    try r.writeFile(io, "d250/f", "ours\n");
    try r.exec(io, &.{ "commit", "-q", "-am", "ours" });
    try r.exec(io, &.{ "repack", "-adq" });

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const ours = (try repo.head(io)).?;
    defer gpa.free(ours.name);
    const theirs = (try repo.refStore().resolve(gpa, io, "refs/heads/side")).?;
    defer gpa.free(theirs.name);

    // Every object is in the one pack, and every read of one asks it.
    const before = repo.objectDatabase().stats.pack_scans;
    var outcome = try applyCommits(gpa, io, &repo, .{ .index = &index, .ours = ours.oid, .theirs = theirs.oid }, .{});
    defer outcome.deinit();
    const reads = repo.objectDatabase().stats.pack_scans - before;
    try std.testing.expect(outcome.isClean());
    try std.testing.expectEqual(@as(u32, 1), outcome.written);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("theirs\n", try r.dir.readFile(io, "d005/f", &buf));
    try std.testing.expectEqualStrings("ours\n", try r.dir.readFile(io, "d250/f", &buf));
    // The index is the merged tree, and git says so.
    try index.write(io, repo.gitDirectory(), "index", .{ .lock = .{ .shared = repo.sharedPermissions() } });
    var hex: [hash.max_hex_len]u8 = undefined;
    const written = try r.line(io, &.{"write-tree"});
    defer gpa.free(written);
    try std.testing.expectEqualStrings(outcome.tree.?.hex(&hex), written);
    // Three hundred folders, of which two changed: a whole-tree walk reads
    // every one of them, more than once.
    try std.testing.expect(reads < 50);
}
