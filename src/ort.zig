//! git's merge of two trees against a third, decision for decision: the
//! machinery behind `git merge`, `cherry-pick`, `revert`, `rebase` and
//! `merge-tree`, called ort.
//!
//! A merge that follows renames only where they change the answer finds
//! different renames from one that looks everywhere, and which pairing wins
//! a tie depends on the order things were seen in. So this is not a merge
//! written to git's documentation but a port of `merge-ort.c` and the parts
//! of `diffcore-rename.c` it drives: the three trees are walked in git's
//! order, directories one side left alone are resolved without being read
//! when no rename can reach into them, a deleted path is paired with an
//! added one only when the pairing matters, exactly, by basename, then by
//! git's similarity score, and the directories whose files moved together
//! carry the other side's additions along with them. What comes out is what
//! git's merge writes: the tree, markers and moved-aside files included, the
//! stages of every conflicted path, and the messages, with git's words.
//!
//! Where git iterates one of its own hash maps and the order decides an
//! answer -- the destination a directory most often moved to, when two tie,
//! and the order the directories left for later are read in -- the map is
//! git's too, `GitMap`, down to the hash and the growth rule.
//!
//! Several merge bases are merged into one first, recursively, with the
//! labels git gives the inner merges and the markers they leave nested in
//! the base. The inner merges' messages are dropped, as git drops them
//! below its highest verbosity, unless `Options.inner_messages` asks for
//! them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const merge = @import("blobmerge.zig");
const rename = @import("rename.zig");
const attributes = @import("attributes.zig");
const revwalk = @import("revwalk.zig");
const abbrev = @import("abbrev.zig");
const convert = @import("convert.zig");

const Oid = hash.Oid;

/// Errors from a merge.
pub const Error = error{
    /// A tree entry named something that is not a tree.
    NotATree,
    /// A tree entry named something that is not a blob where one belongs.
    NotABlob,
    /// A commit named something that is not a commit.
    NotACommit,
    /// The trees nest deeper than the walk will go.
    TreeTooDeep,
    /// A path's `merge` attribute names a driver `merge.<name>.driver`
    /// configures, which is a program this merge does not run.
    UnsupportedMergeDriver,
    /// A file of ours that the other side's directory rename carried onto
    /// a path where a directory also stands lost its own stage: git's
    /// merge-ort splits the file from the directory there and clears stage
    /// 1 whichever side the file is on. Where the merge later needs that
    /// stage -- a content merge of the file against the other side's
    /// rename of the same source, or a rename whose type the empty stage
    /// seems to change, leaving a moved-aside file inconsistent -- git
    /// stops on an assertion, in `handle_content_merge` or in
    /// `process_entry`, and has no answer to give. This stops at the same
    /// two checks.
    DirectoryRenameLostStage,
} || Allocator.Error || odb_mod.Error || object.TreeParseError || object.ParseError ||
    attributes.Error || revwalk.Error || convert.Error;

/// When a file one side added lands in a directory the other side renamed:
/// `merge.directoryRenames`.
pub const DirectoryRenames = enum {
    /// Leave it where it was added.
    off,
    /// Move it with the directory, and call the move a conflict for a
    /// person to confirm. git's default.
    conflict,
    /// Move it with the directory.
    on,
};

/// A submodule's history, for merging two commits of it.
pub const SubmoduleHistory = struct {
    /// The submodule's object database.
    db: *odb_mod.Odb,
    /// Every commit its `HEAD` and refs point at: what git's `--all` walks
    /// from when it looks for a merge that already joins the two sides.
    tips: []const Oid,
};

/// How a merge reaches the submodules it meets: the caller opens the one at
/// `path`, or returns `null` when it is not checked out, which git reports
/// as a conflict of its own.
pub const Submodules = struct {
    context: *anyopaque,
    openFn: *const fn (context: *anyopaque, path: []const u8) ?SubmoduleHistory,
};

/// How a merge is made.
pub const Options = struct {
    /// The names on the markers and in the messages, and the suffix a
    /// moved-aside file takes: `ours` is git's `branch1`, `theirs` its
    /// `branch2`, `base` the ancestor's label. For a merge of commits the
    /// ancestor's label is worked out as git does and `base` is not used.
    labels: merge.Labels = .{ .ours = "HEAD", .base = "base", .theirs = "theirs" },
    conflict_style: merge.ConflictStyle = .merge,
    /// `-X ours` or `-X theirs`.
    favor: merge.Favor = .none,
    /// The line diff; git's merge machinery uses histogram unless
    /// `diff.algorithm` says otherwise.
    algorithm: @import("textdiff.zig").Algorithm = .histogram,
    /// Prove the Myers diffs minimal: `diff-algorithm=minimal`.
    minimal: bool = false,
    /// Whether renames are followed: `merge.renames`, `-X no-renames`.
    renames: bool = true,
    /// How much of a file must survive for a delete and an add to be a
    /// rename, out of `similarity.max_score`; zero is git's default of
    /// half. `-X find-renames=<n>`.
    rename_score: u32 = 0,
    /// The most sources times destinations the inexact rename search
    /// takes on, squared: `merge.renameLimit`. Zero or less is git's 7000.
    rename_limit: i64 = 0,
    directory_renames: DirectoryRenames = .conflict,
    /// The attributes that decide how a path is merged: `merge` and
    /// `conflict-marker-size`, read along the way from `attributes_dir`.
    attributes: ?*attributes.Attrs = null,
    attributes_dir: ?Io.Dir = null,
    /// The names of the merge drivers `merge.<name>.driver` configures;
    /// a path whose `merge` attribute names one is refused.
    configured_drivers: []const []const u8 = &.{},
    /// The driver for a path whose `merge` attribute says nothing:
    /// `merge.default`. Text when `null`.
    default_driver: ?[]const u8 = null,
    submodules: ?Submodules = null,
    /// How long the ancestor's short name is in a merge of commits:
    /// `core.abbrev`.
    abbrev_len: usize = abbrev.fallback,
    /// Where a refusal writes the path that caused it.
    blocked: ?*merge.Blocked = null,
    /// Keep the messages of the inner merges a merge of several bases
    /// makes, each after `  From inner merge:` and two spaces a level, and
    /// ahead of the outer merge's own for the same path. git keeps them at
    /// verbosity 5 and above, `GIT_MERGE_VERBOSITY=5`, and drops them
    /// otherwise.
    inner_messages: bool = false,
    /// Renormalize, as `merge.renormalize` and `-X renormalize` ask: each
    /// side of a content merge is taken out to the working tree and back in
    /// through this session, with the path's attributes, before it is
    /// merged, and a modify/delete whose modification that undoes is no
    /// conflict. `null` merges the blobs as they are.
    renormalize: ?*convert.Session = null,
    /// The working tree has no top-level `.gitattributes`: a renormalizing
    /// merge then reads the merge's own there, as git's does.
    attributes_from_merge: bool = false,
};

/// What a message is about: git's conflict types, whose short names
/// `description` gives as git prints them for `merge-tree -z`.
pub const MessageKind = enum {
    auto_merging,
    contents,
    binary,
    file_directory,
    distinct_modes,
    modify_delete,
    rename_rename,
    rename_collides,
    rename_delete,
    dir_rename_suggested,
    dir_rename_applied,
    dir_rename_skipped,
    dir_rename_file_in_way,
    dir_rename_collision,
    dir_rename_split,
    submodule_fast_forwarding,
    submodule_failed,
    submodule_possible_resolution,
    submodule_not_initialized,
    submodule_history_not_available,
    submodule_may_have_rewinds,
    submodule_null_merge_base,

    /// The short description git prints for the kind.
    pub fn description(k: MessageKind) []const u8 {
        return switch (k) {
            .auto_merging => "Auto-merging",
            .contents => "CONFLICT (contents)",
            .binary => "CONFLICT (binary)",
            .file_directory => "CONFLICT (file/directory)",
            .distinct_modes => "CONFLICT (distinct modes)",
            .modify_delete => "CONFLICT (modify/delete)",
            .rename_rename => "CONFLICT (rename/rename)",
            .rename_collides => "CONFLICT (rename involved in collision)",
            .rename_delete => "CONFLICT (rename/delete)",
            .dir_rename_suggested => "CONFLICT (directory rename suggested)",
            .dir_rename_applied => "Path updated due to directory rename",
            .dir_rename_skipped => "Directory rename skipped since directory was renamed on both sides",
            .dir_rename_file_in_way => "CONFLICT (file in way of directory rename)",
            .dir_rename_collision => "CONFLICT(directory rename collision)",
            .dir_rename_split => "CONFLICT(directory rename unclear split)",
            .submodule_fast_forwarding => "Fast forwarding submodule",
            .submodule_failed => "CONFLICT (submodule)",
            .submodule_possible_resolution => "CONFLICT (submodule with possible resolution)",
            .submodule_not_initialized => "CONFLICT (submodule not initialized)",
            .submodule_history_not_available => "CONFLICT (submodule history not available)",
            .submodule_may_have_rewinds => "CONFLICT (submodule may have rewinds)",
            .submodule_null_merge_base => "CONFLICT (submodule lacks merge base)",
        };
    }
};

/// One message: what git's merge prints, with the paths it is about, the
/// first of which it is filed under.
pub const Message = struct {
    kind: MessageKind,
    paths: []const []const u8,
    text: []const u8,
};

/// One stage of a conflicted path.
pub const Stage = struct {
    /// The mode as git records it. Zero in one corner git reaches -- a
    /// file moved aside from a directory whose own side it no longer has
    /// -- where git's index takes a regular file with no content.
    mode: u32,
    oid: Oid,
};

/// A path the merge could not settle, with what the index records for it.
pub const Conflicted = struct {
    path: []const u8,
    /// Stages 1, 2 and 3: the base's version, ours and theirs, each absent
    /// where the index has no entry at that stage.
    stages: [3]?Stage,
};

/// What a merge produced. Everything in it is the result's.
pub const Result = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// The merged tree, conflict markers and moved-aside files included:
    /// what git's merge leaves in the working tree and `merge-tree` prints.
    tree: Oid,
    /// The paths left conflicted, sorted.
    conflicted: []const Conflicted,
    /// Every message, grouped by the path each is filed under, the paths
    /// sorted.
    messages: []const Message,
    /// When the inexact rename search was skipped for want of a higher
    /// `merge.renameLimit`, the limit that would have run it; otherwise 0.
    rename_limit_needed: u64,

    /// Whether the merge is clean.
    pub fn isClean(r: *const Result) bool {
        return r.conflicted.len == 0;
    }

    /// Release everything.
    pub fn deinit(r: *Result) void {
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

/// Merge the trees `ours` and `theirs` against `base`, which is `null` for
/// two histories with nothing in common: `merge_incore_nonrecursive`, as a
/// cherry-pick, a revert and `merge-tree --merge-base` use it.
pub fn mergeTrees(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
    options: Options,
) Error!Result {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    var m: Merge = .{ .arena = arena_instance.allocator(), .io = io, .db = db, .options = options };
    m.branch1 = options.labels.ours;
    m.branch2 = options.labels.theirs;
    m.ancestor = options.labels.base;
    const outcome = try m.nonrecursive(base orelse emptyTree(db.kind), ours, theirs);
    return m.finish(gpa, &arena_instance, outcome);
}

/// Merge the commits `ours` and `theirs`, their merge bases merged into one
/// first: `merge_incore_recursive`, as `git merge` and a rebase's `merge`
/// use it. `bases` is in the order git passes them, the oldest first, or
/// `null` to find them.
pub fn mergeCommits(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    ours: Oid,
    theirs: Oid,
    bases: ?[]const Oid,
    options: Options,
) Error!Result {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    var m: Merge = .{ .arena = arena_instance.allocator(), .io = io, .db = db, .options = options };
    m.branch1 = options.labels.ours;
    m.branch2 = options.labels.theirs;
    const outcome = try m.recursive(bases, .{ .real = ours }, .{ .real = theirs });
    return m.finish(gpa, &arena_instance, outcome);
}

/// A copy of `messages`, every string in it, in `arena`.
pub fn dupeMessages(arena: Allocator, messages: []const Message) Allocator.Error![]const Message {
    const out = try arena.alloc(Message, messages.len);
    for (messages, out) |msg, *copy| {
        const paths = try arena.alloc([]const u8, msg.paths.len);
        for (msg.paths, paths) |p, *q| q.* = try arena.dupe(u8, p);
        copy.* = .{ .kind = msg.kind, .paths = paths, .text = try arena.dupe(u8, msg.text) };
    }
    return out;
}

/// The empty tree's name.
pub fn emptyTree(kind: hash.Kind) Oid {
    return hash.Hasher.object(kind, "tree", "");
}

const GitMap = rename.GitMap;

//=========================================================================
// The merge
//=========================================================================

/// A mode as git keeps it, 0 for none.
const Mode = u32;
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;
const S_IFGITLINK: u32 = 0o160000;

fn isReg(mode: Mode) bool {
    return mode & S_IFMT == S_IFREG;
}

fn isDir(mode: Mode) bool {
    return mode & S_IFMT == S_IFDIR;
}

const Version = struct {
    mode: Mode = 0,
    oid: Oid,

    fn isNull(v: Version) bool {
        return v.oid.isZero();
    }
};

/// `merged_info` and `conflict_info` in one: the second half is read only
/// while `clean` is false, as in git.
const Info = struct {
    result: Version,
    is_null: bool = false,
    clean: bool,
    basename_offset: usize,
    directory_name: []const u8,

    stages: [3]Version,
    pathnames: [3][]const u8,
    df_conflict: bool = false,
    path_conflict: bool = false,
    filemask: u3 = 0,
    dirmask: u3 = 0,
    match_mask: u3 = 0,
};

const Spec = rename.Spec;
const Pair = rename.Pair;

const Relevance = struct {
    const not_relevant = rename.DirRelevance.not_relevant;
    const for_ancestor = rename.DirRelevance.for_ancestor;
    const for_self = rename.DirRelevance.for_self;
    const no_more = rename.SourceRelevance.no_more;
    const content = rename.SourceRelevance.content;
    const location = rename.SourceRelevance.location;
};

const Deferred = struct {
    possible_trivial_merges: GitMap(u3) = .{},
    trivial_merges_okay: bool = true,
    target_dirs: std.StringHashMapUnmanaged(void) = .empty,
};

const CollisionInfo = struct {
    source_files: std.ArrayList([]const u8) = .empty,
    reported_already: bool = false,
};

/// A commit a recursive merge made up: the merged tree of two bases, with
/// the two as its parents.
const CommitRef = union(enum) {
    real: Oid,
    virtual: usize,
};

const Outcome = struct {
    tree: Oid,
};

const Merge = struct {
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    options: Options,
    branch1: []const u8 = "",
    branch2: []const u8 = "",
    ancestor: []const u8 = "",
    call_depth: u32 = 0,

    // Per merge, cleared between the merges a recursive one makes.
    paths: std.StringHashMapUnmanaged(*Info) = .empty,
    conflicted: std.StringHashMapUnmanaged(*Info) = .empty,
    conflicts: std.StringHashMapUnmanaged(std.ArrayList(Message)) = .empty,
    current_dir_name: []const u8 = "",
    dir_rename_mask: u3 = 0,
    pairs: [3]std.ArrayList(*Pair) = .{ .empty, .empty, .empty },
    dirs_removed: [3]std.StringHashMapUnmanaged(i64) = .{ .empty, .empty, .empty },
    relevant_sources: [3]std.StringHashMapUnmanaged(i64) = .{ .empty, .empty, .empty },
    dir_rename_count: [3]GitMap(*GitMap(i64)) = .{ .{}, .{}, .{} },
    dir_renames: [3]std.StringHashMapUnmanaged([]const u8) = .{ .empty, .empty, .empty },
    deferred: [3]Deferred = .{ .{}, .{}, .{} },
    needed_limit: u64 = 0,
    /// Renames found by a first pass and kept for the second, which git
    /// makes when reading the directories it put off turned out to be most
    /// of the work: `cached_pairs` maps a source to its destination, or to
    /// nothing for a deletion.
    cached_pairs: [3]GitMap(?[]const u8) = .{ .{}, .{}, .{} },
    cached_target_names: [3]std.StringHashMapUnmanaged(void) = .{ .empty, .empty, .empty },
    cached_irrelevant: [3]std.StringHashMapUnmanaged(void) = .{ .empty, .empty, .empty },
    redo_after_renames: u2 = 0,
    loaded_attr_dirs: std.StringHashMapUnmanaged(void) = .empty,

    // For recursion.
    virtuals: std.ArrayList(Virtual) = .empty,

    const Virtual = struct { tree: Oid, parents: []const CommitRef, fake: Oid };

    /// `clear_or_reinit_internal_opts` between one merge and the next, as
    /// a merge of several bases makes them: the messages stay, as git's
    /// `output` map does, and so does the largest rename limit asked for.
    fn reset(m: *Merge) void {
        m.reinit();
        m.cached_pairs = .{ .{}, .{}, .{} };
        m.cached_target_names = .{ .empty, .empty, .empty };
        m.cached_irrelevant = .{ .empty, .empty, .empty };
        m.redo_after_renames = 0;
        m.dir_rename_count = .{ .{}, .{}, .{} };
    }

    /// `clear_or_reinit_internal_opts` between the two passes: everything
    /// but the renames found, the directories' rename counts and the
    /// messages.
    fn reinit(m: *Merge) void {
        m.paths = .empty;
        m.conflicted = .empty;
        m.current_dir_name = "";
        m.dir_rename_mask = 0;
        m.pairs = .{ .empty, .empty, .empty };
        m.dirs_removed = .{ .empty, .empty, .empty };
        m.relevant_sources = .{ .empty, .empty, .empty };
        m.dir_renames = .{ .empty, .empty, .empty };
        m.deferred = .{ .{}, .{}, .{} };
    }

    fn zero(m: *const Merge) Oid {
        return Oid.zero(m.db.kind);
    }

    //---------------------------------------------------------------------
    // Messages
    //---------------------------------------------------------------------

    /// `path_msg`: a message filed under `primary`. Those of an inner merge
    /// are dropped, as git drops them below its highest verbosity, unless
    /// `Options.inner_messages` keeps them.
    fn pathMsg(
        m: *Merge,
        kind: MessageKind,
        primary: []const u8,
        other1: ?[]const u8,
        other2: ?[]const u8,
        others: []const []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        if (m.call_depth > 0 and !m.options.inner_messages) return;
        var paths: std.ArrayList([]const u8) = .empty;
        try paths.append(m.arena, primary);
        if (other1) |p| try paths.append(m.arena, p);
        if (other2) |p| try paths.append(m.arena, p);
        try paths.appendSlice(m.arena, others);
        var text: []const u8 = try std.fmt.allocPrint(m.arena, fmt, args);
        if (m.call_depth > 0) {
            const indent = try m.arena.alloc(u8, 2 * m.call_depth);
            @memset(indent, ' ');
            text = try std.mem.concat(m.arena, u8, &.{ "  From inner merge:", indent, text });
        }
        const slot = try m.conflicts.getOrPut(m.arena, primary);
        if (!slot.found_existing) {
            slot.key_ptr.* = try m.arena.dupe(u8, primary);
            slot.value_ptr.* = .empty;
        }
        try slot.value_ptr.append(m.arena, .{ .kind = kind, .paths = paths.items, .text = text });
    }

    /// `unique_path`: `<path>~<branch>`, with `/` in the branch turned to
    /// `_`, and `_<n>` after it until the name is free.
    fn uniquePath(m: *Merge, path: []const u8, branch: []const u8) Allocator.Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(m.arena, path);
        try buf.append(m.arena, '~');
        for (branch) |c| try buf.append(m.arena, if (c == '/') '_' else c);
        const base_len = buf.items.len;
        var suffix: u32 = 0;
        while (m.paths.contains(buf.items)) {
            buf.shrinkRetainingCapacity(base_len);
            try buf.print(m.arena, "_{d}", .{suffix});
            suffix += 1;
        }
        return buf.items;
    }

    //---------------------------------------------------------------------
    // Reading trees
    //---------------------------------------------------------------------

    const TreeItem = struct { name: []const u8, mode: Mode, oid: Oid };

    fn readTree(m: *Merge, oid: ?Oid) Error![]TreeItem {
        const tree_oid = oid orelse return &.{};
        if (tree_oid.eql(emptyTree(m.db.kind))) return &.{};
        const found = try m.db.read(m.io, tree_oid);
        defer m.db.gpa.free(found.bytes);
        if (found.type != .tree) return error.NotATree;
        var out: std.ArrayList(TreeItem) = .empty;
        var it = object.Tree.parse(m.db.kind, found.bytes).iterate();
        while (try it.next()) |entry| {
            try out.append(m.arena, .{ .name = try m.arena.dupe(u8, entry.name), .mode = entry.mode.raw(), .oid = entry.oid });
        }
        return out.items;
    }

    const Names = [3]struct { mode: Mode, oid: Oid, name: []const u8 };

    /// `traverse_trees` over three trees: every name any of them holds,
    /// in byte order, a file and a directory of one name met together.
    fn traverse(m: *Merge, trees: [3]?Oid, dir: []const u8, depth: u32) Error!void {
        if (depth > 4096) return error.TreeTooDeep;
        var lists: [3][]TreeItem = undefined;
        for (0..3) |i| lists[i] = try m.readTree(trees[i]);
        var names: std.StringArrayHashMapUnmanaged(Names) = .empty;
        for (lists, 0..) |list, i| {
            for (list) |item| {
                const slot = try names.getOrPut(m.arena, item.name);
                if (!slot.found_existing) {
                    for (slot.value_ptr) |*n| n.* = .{ .mode = 0, .oid = m.zero(), .name = item.name };
                }
                slot.value_ptr[i] = .{ .mode = item.mode, .oid = item.oid, .name = item.name };
            }
        }
        const Sorter = struct {
            keys: []const []const u8,
            pub fn lessThan(s: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, s.keys[a], s.keys[b]) == .lt;
            }
        };
        names.sort(Sorter{ .keys = names.keys() });

        // `traverse_trees_wrapper`: a directory one side removed is read
        // whole first, and a file the other side added anywhere in it means
        // every rename under it matters.
        if (m.dir_rename_mask == 2 or m.dir_rename_mask == 4) {
            for (names.values()) |n| {
                var mask: u3 = 0;
                var dirmask: u3 = 0;
                for (n, 0..) |e, i| {
                    if (e.mode == 0) continue;
                    mask |= @as(u3, 1) << @intCast(i);
                    if (isDir(e.mode)) dirmask |= @as(u3, 1) << @intCast(i);
                }
                const filemask = mask & ~dirmask;
                if (filemask != 0 and filemask == m.dir_rename_mask) m.dir_rename_mask = 7;
            }
        }
        for (names.keys(), names.values()) |name, n| {
            var mask: u3 = 0;
            var dirmask: u3 = 0;
            for (n, 0..) |e, i| {
                if (e.mode == 0) continue;
                mask |= @as(u3, 1) << @intCast(i);
                if (isDir(e.mode)) dirmask |= @as(u3, 1) << @intCast(i);
            }
            try m.collectCallback(n, mask, dirmask, dir, name, depth);
        }
    }

    fn fullPath(m: *Merge, dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
        if (dir.len == 0) return m.arena.dupe(u8, name);
        return std.fmt.allocPrint(m.arena, "{s}/{s}", .{ dir, name });
    }

    fn baseOffset(dir: []const u8) usize {
        return if (dir.len == 0) 0 else dir.len + 1;
    }

    /// `setup_path_info`.
    fn setupPathInfo(
        m: *Merge,
        dir: []const u8,
        fullpath: []const u8,
        names: Names,
        merged_version: ?Version,
        is_null: bool,
        df_conflict: bool,
        filemask: u3,
        dirmask: u3,
    ) Allocator.Error!*Info {
        const info = try m.arena.create(Info);
        info.* = .{
            .result = merged_version orelse .{ .oid = m.zero() },
            .is_null = if (merged_version != null) is_null else false,
            .clean = merged_version != null,
            .basename_offset = baseOffset(dir),
            .directory_name = dir,
            .stages = undefined,
            .pathnames = .{ fullpath, fullpath, fullpath },
        };
        for (0..3) |i| info.stages[i] = .{ .mode = names[i].mode, .oid = names[i].oid };
        if (merged_version == null) {
            info.filemask = filemask;
            info.dirmask = dirmask;
            info.df_conflict = df_conflict;
            if (dirmask != 0) info.is_null = true;
        }
        try m.paths.put(m.arena, fullpath, info);
        return info;
    }

    /// `collect_merge_info_callback`.
    fn collectCallback(m: *Merge, names: Names, mask: u3, dirmask_in: u3, dir: []const u8, name: []const u8, depth: u32) Error!void {
        const prev_dir_rename_mask = m.dir_rename_mask;
        const filemask: u3 = mask & ~dirmask_in;
        const mbase_null = mask & 1 == 0;
        const side1_null = mask & 2 == 0;
        const side2_null = mask & 4 == 0;
        const side1_matches_mbase = !side1_null and !mbase_null and names[0].mode == names[1].mode and names[0].oid.eql(names[1].oid);
        const side2_matches_mbase = !side2_null and !mbase_null and names[0].mode == names[2].mode and names[0].oid.eql(names[2].oid);
        const sides_match = !side1_null and !side2_null and names[1].mode == names[2].mode and names[1].oid.eql(names[2].oid);
        const df_conflict = filemask != 0 and dirmask_in != 0;

        var match_mask: u3 = 0;
        if (side1_matches_mbase) {
            match_mask = if (side2_matches_mbase) 7 else 3;
        } else if (side2_matches_mbase) {
            match_mask = 5;
        } else if (sides_match) {
            match_mask = 6;
        }

        const fullpath = try m.fullPath(dir, name);

        if (side1_matches_mbase and side2_matches_mbase) {
            _ = try m.setupPathInfo(dir, fullpath, names, .{ .mode = names[0].mode, .oid = names[0].oid }, mbase_null, false, filemask, dirmask_in);
            return;
        }
        if (sides_match and filemask == 7) {
            _ = try m.setupPathInfo(dir, fullpath, names, .{ .mode = names[1].mode, .oid = names[1].oid }, side1_null, false, filemask, dirmask_in);
            return;
        }
        if (side1_matches_mbase and filemask == 7) {
            _ = try m.setupPathInfo(dir, fullpath, names, .{ .mode = names[2].mode, .oid = names[2].oid }, side2_null, false, filemask, dirmask_in);
            return;
        }
        if (side2_matches_mbase and filemask == 7) {
            _ = try m.setupPathInfo(dir, fullpath, names, .{ .mode = names[1].mode, .oid = names[1].oid }, side1_null, false, filemask, dirmask_in);
            return;
        }

        try m.collectRenameInfo(names, dir, fullpath, filemask, dirmask_in, match_mask);

        const ci = try m.setupPathInfo(dir, fullpath, names, null, false, df_conflict, filemask, dirmask_in);
        ci.match_mask = match_mask;

        if (dirmask_in != 0) {
            var side: u2 = if (side1_matches_mbase) 2 else if (side2_matches_mbase) 1 else 0;
            if (filemask == 0 and (dirmask_in == 2 or dirmask_in == 4)) {
                ci.match_mask = 7 - dirmask_in;
                side = @intCast(dirmask_in / 2);
            }
            if (m.dir_rename_mask != 7 and side != 0 and m.deferred[side].trivial_merges_okay and
                !m.deferred[side].target_dirs.contains(fullpath))
            {
                try m.deferred[side].possible_trivial_merges.put(m.arena, fullpath, m.dir_rename_mask);
                m.dir_rename_mask = prev_dir_rename_mask;
                return;
            }

            ci.match_mask &= filemask;
            var trees: [3]?Oid = undefined;
            for (0..3) |i| trees[i] = if (isDir(names[i].mode)) names[i].oid else null;
            const original_dir_name = m.current_dir_name;
            m.current_dir_name = fullpath;
            try m.traverse(trees, fullpath, depth + 1);
            m.current_dir_name = original_dir_name;
            m.dir_rename_mask = prev_dir_rename_mask;
        }
    }

    /// `collect_rename_info`.
    fn collectRenameInfo(m: *Merge, names: Names, dirname: []const u8, fullname: []const u8, filemask: u3, dirmask: u3, match_mask: u3) Allocator.Error!void {
        if (m.dir_rename_mask != 7 and (dirmask == 3 or dirmask == 5)) {
            m.dir_rename_mask = dirmask & ~@as(u3, 1);
        }
        if (dirmask == 1 or dirmask == 3 or dirmask == 5) {
            const sides: u3 = (7 - dirmask) / 2;
            const relevance = if (m.dir_rename_mask == 7) Relevance.for_ancestor else Relevance.not_relevant;
            if (sides & 1 != 0) try m.dirs_removed[1].put(m.arena, fullname, relevance);
            if (sides & 2 != 0) try m.dirs_removed[2].put(m.arena, fullname, relevance);
        }
        if (m.dir_rename_mask == 7 and (filemask == 2 or filemask == 4)) {
            const side: usize = 3 - @as(usize, filemask >> 1);
            try m.dirs_removed[side].put(m.arena, dirname, Relevance.for_self);
        }
        if (filemask == 0 or filemask == 7) return;
        for (1..3) |side| {
            const side_mask = @as(u3, 1) << @intCast(side);
            if (filemask & 1 != 0 and filemask & side_mask == 0) {
                try m.addPair(names, fullname, side, false, match_mask & filemask);
            }
            if (filemask & 1 == 0 and filemask & side_mask != 0) {
                try m.addPair(names, fullname, side, true, match_mask & filemask);
            }
        }
    }

    /// `add_pair`.
    fn addPair(m: *Merge, names: Names, pathname: []const u8, side: usize, is_add: bool, match_mask: u3) Allocator.Error!void {
        const names_idx = if (is_add) side else 0;
        if (is_add) {
            if (m.cached_target_names[side].contains(pathname)) return;
        } else {
            const content_relevant = match_mask == 0;
            const location_relevant = m.dir_rename_mask == 7;
            if (content_relevant) {
                _ = m.cached_irrelevant[side].remove(pathname);
            }
            if (content_relevant or location_relevant) {
                try m.relevant_sources[side].put(m.arena, pathname, if (content_relevant) Relevance.content else Relevance.location);
            }
            if (m.cached_pairs[side].contains(pathname) or m.cached_irrelevant[side].contains(pathname)) return;
        }
        const one = try m.arena.create(Spec);
        const two = try m.arena.create(Spec);
        one.* = .{ .path = pathname, .oid = m.zero() };
        two.* = .{ .path = pathname, .oid = m.zero() };
        const filled = if (is_add) two else one;
        filled.mode = names[names_idx].mode;
        filled.oid = names[names_idx].oid;
        const pair = try m.arena.create(Pair);
        pair.* = .{ .one = one, .two = two };
        try m.pairs[side].append(m.arena, pair);
    }

    /// `resolve_trivial_directory_merge`.
    fn resolveTrivialDirectoryMerge(ci: *Info, side: usize) void {
        ci.result = ci.stages[side];
        ci.is_null = ci.stages[side].isNull();
        ci.dirmask &= ~ci.match_mask;
        ci.filemask &= ~ci.match_mask;
        ci.match_mask = 0;
        ci.clean = !ci.df_conflict or ci.dirmask != 0;
        ci.df_conflict = false;
    }

    /// `handle_deferred_entries`: a directory put off is resolved without
    /// being read when no rename source still to be found can have gone
    /// into it, and read otherwise.
    fn handleDeferredEntries(m: *Merge) Error!void {
        const path_count_before = m.paths.count();
        var path_count_after: usize = 0;
        for (1..3) |side| {
            var optimization_okay = true;
            var rit = m.relevant_sources[side].keyIterator();
            while (rit.next()) |key| {
                if (m.cached_irrelevant[side].contains(key.*)) continue;
                if (!m.cached_pairs[side].contains(key.*)) {
                    optimization_okay = false;
                    break;
                }
                const target = m.cached_pairs[side].get(key.*).? orelse continue;
                if (m.paths.contains(target)) continue;
                var end = target.len;
                while (std.mem.lastIndexOfScalar(u8, target[0..end], '/')) |slash| {
                    end = slash;
                    if (m.deferred[side].target_dirs.contains(target[0..end])) break;
                    try m.deferred[side].target_dirs.put(m.arena, target[0..end], {});
                }
            }
            m.deferred[side].trivial_merges_okay = optimization_okay;
            const copy = m.deferred[side].possible_trivial_merges;
            m.deferred[side].possible_trivial_merges = .{};
            var it = copy.iterator();
            while (it.next()) |node| {
                const path = node.key;
                const ci = m.paths.get(path).?;
                if (optimization_okay and !m.deferred[side].target_dirs.contains(path)) {
                    resolveTrivialDirectoryMerge(ci, side);
                    continue;
                }
                var trees: [3]?Oid = undefined;
                const dirmask = ci.dirmask;
                for (0..3) |i| trees[i] = if (dirmask & (@as(u3, 1) << @intCast(i)) != 0) ci.stages[i].oid else null;
                ci.match_mask &= ci.filemask;
                m.current_dir_name = path;
                m.dir_rename_mask = node.value;
                const interned = m.paths.getKey(path).?;
                try m.traverse(trees, interned, 1);
            }
            var rest = m.deferred[side].possible_trivial_merges.iterator();
            while (rest.next()) |node| {
                const ci = m.paths.get(node.key).?;
                resolveTrivialDirectoryMerge(ci, side);
            }
            if (!optimization_okay or path_count_after != 0) path_count_after = m.paths.count();
        }
        if (path_count_after != 0) {
            // Reading the directories put off was most of the work: find
            // the renames, and start again knowing them, so that more of
            // the directories can be left unread.
            if (m.redo_after_renames == 0 and path_count_after / path_count_before >= 3) m.redo_after_renames = 1;
        } else if (m.redo_after_renames == 2) {
            m.redo_after_renames = 0;
        }
    }

    fn collectMergeInfo(m: *Merge, base: Oid, side1: Oid, side2: Oid) Error!void {
        m.current_dir_name = "";
        try m.traverse(.{ base, side1, side2 }, "", 0);
        try m.handleDeferredEntries();
    }

    //---------------------------------------------------------------------
    // Content merges
    //---------------------------------------------------------------------

    fn readBlob(m: *Merge, oid: Oid) Error![]const u8 {
        if (oid.isZero()) return "";
        const found = try m.db.read(m.io, oid);
        defer m.db.gpa.free(found.bytes);
        if (found.type != .blob) return error.NotABlob;
        return m.arena.dupe(u8, found.bytes);
    }

    const Driver = enum { text, binary, union_ };

    /// What `path`'s attributes say about merging it: the driver and the
    /// marker size.
    /// The attributes `path` has, the `.gitattributes` on its way down read
    /// as they are needed. `null` without attributes to read.
    fn attributesOf(m: *Merge, path: []const u8) Error!?attributes.Attributes {
        const attrs = m.options.attributes orelse return null;
        if (m.options.attributes_dir) |dir| {
            var depth: u32 = 0;
            var at: usize = 0;
            while (true) : (depth += 1) {
                const base = path[0..at];
                if (!m.loaded_attr_dirs.contains(base)) {
                    try m.loaded_attr_dirs.put(m.arena, try m.arena.dupe(u8, base), {});
                    if (base.len == 0 and m.options.renormalize != null and m.options.attributes_from_merge) {
                        try m.addMergedAttributes(attrs);
                    } else try attrs.addDirectory(m.io, dir, base, depth);
                }
                const slash = std.mem.indexOfScalarPos(u8, path, if (at == 0) 0 else at + 1, '/') orelse break;
                at = slash;
            }
        }
        return try attrs.lookup(m.arena, path, false);
    }

    /// `initialize_attr_index`: the top-level `.gitattributes` a
    /// renormalizing merge reads when the working tree has none. Resolved,
    /// it is the merge's own. Still open -- as it is whenever a side added
    /// or changed it, since the paths are processed in reverse and it sorts
    /// early -- git puts each side it has in an index at a stage numbered
    /// from zero, and reading that index takes stage 0, which is the base,
    /// or else stage 2, which is theirs; our side is never read.
    fn addMergedAttributes(m: *Merge, attrs: *attributes.Attrs) Error!void {
        const ci = m.paths.get(".gitattributes") orelse return;
        const version: Version = if (ci.clean)
            (if (ci.is_null) return else ci.result)
        else if (ci.filemask & 1 != 0)
            ci.stages[0]
        else if (ci.filemask & 4 != 0)
            ci.stages[2]
        else
            return;
        if (!isReg(version.mode)) return;
        const text = try attrs.arena.allocator().dupe(u8, try m.readBlob(version.oid));
        try attrs.addText(text, "", ".gitattributes", 1);
    }

    /// `renormalize_buffer`, when the merge renormalizes; `bytes` as they
    /// are otherwise.
    fn renormalized(m: *Merge, path: []const u8, bytes: []const u8) Error![]const u8 {
        const session = m.options.renormalize orelse return bytes;
        const applied = (try m.attributesOf(path)) orelse attributes.Attributes{ .items = &.{} };
        return session.renormalize(m.arena, path, bytes, applied);
    }

    /// `blob_unchanged`: whether `side` is `base` once both are
    /// renormalized. Different modes are a change.
    fn blobUnchanged(m: *Merge, base: Version, side: Version, path: []const u8) Error!bool {
        if (base.mode != side.mode) return false;
        if (base.oid.eql(side.oid)) return true;
        const one = try m.renormalized(path, try m.readBlob(base.oid));
        const two = try m.renormalized(path, try m.readBlob(side.oid));
        return std.mem.eql(u8, one, two);
    }

    fn driverFor(m: *Merge, path: []const u8) Error!struct { driver: Driver, marker_size: u32 } {
        var driver: Driver = .text;
        var marker_size: u32 = 7;
        const applied = (try m.attributesOf(path)) orelse
            return .{ .driver = try m.namedDriver(path, m.options.default_driver), .marker_size = marker_size };
        if (applied.value("conflict-marker-size")) |text| {
            if (std.fmt.parseInt(i32, text, 10)) |size| {
                if (size > 0) marker_size = @intCast(size);
            } else |_| {}
        }
        // `find_ll_merge_driver`: set is text, unset binary, a name the
        // driver of that name, and nothing said `merge.default`.
        driver = if (applied.get("merge")) |state| switch (state) {
            .unset => .binary,
            .set => .text,
            .unspecified => try m.namedDriver(path, m.options.default_driver),
            .value => |name| try m.namedDriver(path, name),
        } else try m.namedDriver(path, m.options.default_driver);
        return .{ .driver = driver, .marker_size = marker_size };
    }

    /// The driver `name` names: a configured one is a program, refused; a
    /// built-in one is itself; anything else, or none, is text.
    fn namedDriver(m: *Merge, path: []const u8, name_in: ?[]const u8) Error!Driver {
        const name = name_in orelse return .text;
        for (m.options.configured_drivers) |configured| {
            if (std.mem.eql(u8, configured, name)) {
                if (m.options.blocked) |where| where.set(path);
                return error.UnsupportedMergeDriver;
            }
        }
        if (std.mem.eql(u8, name, "binary")) return .binary;
        if (std.mem.eql(u8, name, "union")) return .union_;
        return .text;
    }

    const LlStatus = enum { ok, conflict, binary_conflict };

    /// `merge_3way` and `ll_merge`: the blob merge, with git's labels.
    fn merge3Way(
        m: *Merge,
        path: []const u8,
        o: Oid,
        a: Oid,
        b: Oid,
        pathnames: [3][]const u8,
        extra_marker_size: u32,
    ) Error!struct { bytes: []const u8, status: LlStatus } {
        const same = std.mem.eql(u8, pathnames[0], pathnames[1]) and std.mem.eql(u8, pathnames[1], pathnames[2]);
        const base_label = if (same) m.ancestor else try std.fmt.allocPrint(m.arena, "{s}:{s}", .{ m.ancestor, pathnames[0] });
        const name1 = if (same) m.branch1 else try std.fmt.allocPrint(m.arena, "{s}:{s}", .{ m.branch1, pathnames[1] });
        const name2 = if (same) m.branch2 else try std.fmt.allocPrint(m.arena, "{s}:{s}", .{ m.branch2, pathnames[2] });

        // `ll_merge` renormalizes all three first, when asked to.
        const orig = try m.renormalized(path, try m.readBlob(o));
        const src1 = try m.renormalized(path, try m.readBlob(a));
        const src2 = try m.renormalized(path, try m.readBlob(b));

        const found = try m.driverFor(path);
        const marker_size = found.marker_size + extra_marker_size;
        const virtual_ancestor = m.call_depth > 0;
        var favor: merge.Favor = if (virtual_ancestor) .none else m.options.favor;

        var status: LlStatus = .ok;
        var bytes: []const u8 = undefined;
        const binary = found.driver == .binary or
            @import("textdiff.zig").isBinary(orig) or
            @import("textdiff.zig").isBinary(src1) or
            @import("textdiff.zig").isBinary(src2);
        if (binary) {
            // `ll_binary_merge`.
            if (virtual_ancestor) {
                bytes = orig;
            } else switch (favor) {
                .ours => bytes = src1,
                .theirs => bytes = src2,
                else => {
                    bytes = src1;
                    status = .binary_conflict;
                },
            }
        } else {
            if (found.driver == .union_) favor = .union_;
            var result = merge.blobs(m.arena, orig, src1, src2, .{
                .conflict_style = m.options.conflict_style,
                .labels = .{ .ours = name1, .base = base_label, .theirs = name2 },
                .marker_size = @intCast(@min(marker_size, 255)),
                .favor = favor,
                .algorithm = m.options.algorithm,
                .minimal = m.options.minimal,
            }) catch |err| switch (err) {
                error.BinaryBlob => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            };
            bytes = result.bytes;
            if (!result.isClean()) status = .conflict;
        }
        if (status == .binary_conflict) {
            try m.pathMsg(.binary, path, null, null, &.{}, "warning: Cannot merge binary files: {s} ({s} vs. {s})", .{ path, name1, name2 });
        }
        return .{ .bytes = bytes, .status = status };
    }

    /// `handle_content_merge`: whether the merge of the three is clean,
    /// with what it made in `result`.
    fn handleContentMerge(
        m: *Merge,
        path: []const u8,
        o: Version,
        a: Version,
        b: Version,
        pathnames: [3][]const u8,
        extra_marker_size: u32,
        result: *Version,
    ) Error!bool {
        if ((a.mode & S_IFMT) != (b.mode & S_IFMT)) return error.DirectoryRenameLostStage;
        var clean = true;
        if (a.mode == b.mode or a.mode == o.mode) {
            result.mode = b.mode;
        } else {
            result.mode = a.mode;
            clean = b.mode == o.mode;
        }

        if (a.oid.eql(b.oid) or a.oid.eql(o.oid)) {
            result.oid = b.oid;
        } else if (b.oid.eql(o.oid)) {
            result.oid = a.oid;
        } else if (isReg(a.mode)) {
            const two_way = (o.mode & S_IFMT) != (a.mode & S_IFMT);
            const merged = try m.merge3Way(path, if (two_way) m.zero() else o.oid, a.oid, b.oid, pathnames, extra_marker_size);
            result.oid = try m.db.write(m.io, .blob, merged.bytes);
            if (merged.status != .ok) clean = false;
            try m.pathMsg(.auto_merging, path, null, null, &.{}, "Auto-merging {s}", .{path});
        } else if (a.mode & S_IFMT == S_IFGITLINK) {
            const two_way = (o.mode & S_IFMT) != (a.mode & S_IFMT);
            clean = try m.mergeSubmodule(pathnames[0], if (two_way) m.zero() else o.oid, a.oid, b.oid, &result.oid);
            if (m.call_depth > 0 and two_way and !clean) {
                result.mode = o.mode;
                result.oid = o.oid;
            }
        } else if (a.mode & S_IFMT == S_IFLNK) {
            if (m.call_depth > 0) {
                clean = false;
                result.mode = o.mode;
                result.oid = o.oid;
            } else switch (m.options.favor) {
                .ours => result.oid = a.oid,
                .theirs => result.oid = b.oid,
                else => {
                    clean = false;
                    result.oid = a.oid;
                },
            }
        } else unreachable;
        return clean;
    }

    //---------------------------------------------------------------------
    // Submodules
    //---------------------------------------------------------------------

    /// `merge_submodule`: two commits of a submodule merge when one
    /// contains the other.
    fn mergeSubmodule(m: *Merge, path: []const u8, o: Oid, a: Oid, b: Oid, result: *Oid) Error!bool {
        result.* = if (m.call_depth > 0) o else a;
        const search = m.call_depth == 0;
        const sub = if (m.options.submodules) |s| s.openFn(s.context, path) else null;
        const history = sub orelse {
            try m.pathMsg(.submodule_not_initialized, path, null, null, &.{}, "Failed to merge submodule {s} (not checked out)", .{path});
            return false;
        };
        if (o.isZero()) {
            try m.pathMsg(.submodule_null_merge_base, path, null, null, &.{}, "Failed to merge submodule {s} (no merge base)", .{path});
            return false;
        }
        const sdb = history.db;
        for ([_]Oid{ o, a, b }) |oid| {
            const found = sdb.read(m.io, oid) catch |err| switch (err) {
                error.ObjectNotFound => {
                    try m.pathMsg(.submodule_history_not_available, path, null, null, &.{}, "Failed to merge submodule {s} (commits not present)", .{path});
                    return false;
                },
                else => |e| return e,
            };
            defer sdb.gpa.free(found.bytes);
            if (found.type != .commit) {
                try m.pathMsg(.submodule_history_not_available, path, null, null, &.{}, "Failed to merge submodule {s} (commits not present)", .{path});
                return false;
            }
        }
        const gpa = m.db.gpa;
        if (!try revwalk.isAncestor(gpa, m.io, sdb, o, a) or !try revwalk.isAncestor(gpa, m.io, sdb, o, b)) {
            try m.pathMsg(.submodule_may_have_rewinds, path, null, null, &.{}, "Failed to merge submodule {s} (commits don't follow merge-base)", .{path});
            return false;
        }
        var hex: [hash.max_hex_len]u8 = undefined;
        if (try revwalk.isAncestor(gpa, m.io, sdb, a, b)) {
            result.* = b;
            try m.pathMsg(.submodule_fast_forwarding, path, null, null, &.{}, "Note: Fast-forwarding submodule {s} to {s}", .{ path, b.hex(&hex) });
            return true;
        }
        if (try revwalk.isAncestor(gpa, m.io, sdb, b, a)) {
            result.* = a;
            try m.pathMsg(.submodule_fast_forwarding, path, null, null, &.{}, "Note: Fast-forwarding submodule {s} to {s}", .{ path, a.hex(&hex) });
            return true;
        }
        if (!search) return false;

        const merges = try m.findFirstMerges(sdb, history.tips, a, b);
        if (merges.len == 0) {
            try m.pathMsg(.submodule_failed, path, null, null, &.{}, "Failed to merge submodule {s}", .{path});
            return false;
        }
        var listing: std.ArrayList(u8) = .empty;
        for (merges) |commit| {
            var buf: [hash.max_hex_len]u8 = undefined;
            const short = try abbrev.unique(m.io, sdb, commit, abbrev.automaticLength(sdb), &buf);
            const found = try sdb.read(m.io, commit);
            defer sdb.gpa.free(found.bytes);
            var parsed = try object.Commit.parse(m.arena, sdb.kind, found.bytes);
            defer parsed.deinit();
            const subject = try @import("message.zig").onelineSubject(m.arena, parsed.message);
            try listing.print(m.arena, "    {s} {s}\n", .{ short, subject });
        }
        if (merges.len == 1) {
            try m.pathMsg(.submodule_possible_resolution, path, null, null, &.{}, "Failed to merge submodule {s}, but a possible merge resolution exists: {s}", .{ path, listing.items });
        } else {
            try m.pathMsg(.submodule_possible_resolution, path, null, null, &.{}, "Failed to merge submodule {s}, but multiple possible merges exist:\n{s}", .{ path, listing.items });
        }
        return false;
    }

    /// `find_first_merges`: the merges on the way from `a` to any tip that
    /// contain `b`, less those that contain another of them.
    fn findFirstMerges(m: *Merge, sdb: *odb_mod.Odb, tips: []const Oid, a: Oid, b: Oid) Error![]const Oid {
        const gpa = m.db.gpa;
        var walk = revwalk.Walk.init(gpa, sdb);
        defer walk.deinit();
        for (tips) |tip| try walk.push(tip);
        try walk.hide(a);
        try walk.prepare(m.io);
        var candidates: std.ArrayList(Oid) = .empty;
        while (try walk.next(m.io)) |commit| {
            if (commit.parents.len < 2) continue;
            // `--ancestry-path`: descendants of `a` only.
            if (!try revwalk.isAncestor(gpa, m.io, sdb, a, commit.oid)) continue;
            if (try revwalk.isAncestor(gpa, m.io, sdb, b, commit.oid)) try candidates.append(m.arena, commit.oid);
        }
        var out: std.ArrayList(Oid) = .empty;
        for (candidates.items, 0..) |m1, i| {
            var contains_another = false;
            for (candidates.items, 0..) |m2, j| {
                if (i == j) continue;
                if (try revwalk.isAncestor(gpa, m.io, sdb, m2, m1)) {
                    contains_another = true;
                    break;
                }
            }
            if (!contains_another) try out.append(m.arena, m1);
        }
        return out.items;
    }

    //---------------------------------------------------------------------
    // Directory renames
    //---------------------------------------------------------------------

    /// `apply_dir_rename`.
    fn applyDirRename(m: *Merge, old_dir: []const u8, new_dir: []const u8, old_path: []const u8) Allocator.Error![]const u8 {
        var oldlen = old_dir.len;
        if (new_dir.len == 0) oldlen += 1;
        return std.mem.concat(m.arena, u8, &.{ new_dir, old_path[oldlen..] });
    }

    fn pathInWay(m: *Merge, path: []const u8, side_mask: u3, p: *Pair) bool {
        const mi = m.paths.get(path) orelse return false;
        if (mi.clean) return true;
        return (side_mask & (mi.filemask | mi.dirmask)) != 0 or
            (mi.filemask & 1 != 0 and !std.mem.eql(u8, p.one.path, path));
    }

    /// `handle_path_level_conflicts`.
    fn handlePathLevelConflicts(
        m: *Merge,
        path: []const u8,
        side_index: usize,
        p: *Pair,
        old_dir: []const u8,
        new_dir: []const u8,
        collisions: *std.StringHashMapUnmanaged(*CollisionInfo),
    ) Allocator.Error!?[]const u8 {
        const new_path = try m.applyDirRename(old_dir, new_dir, path);
        const c_info = collisions.get(new_path).?;
        var clean = true;
        if (c_info.reported_already) {
            clean = false;
        } else if (m.pathInWay(new_path, @as(u3, 1) << @intCast(side_index), p)) {
            c_info.reported_already = true;
            const joined = try std.mem.join(m.arena, ", ", c_info.source_files.items);
            try m.pathMsg(.dir_rename_file_in_way, new_path, null, null, c_info.source_files.items, "CONFLICT (implicit dir rename): Existing file/dir at {s} in the way of implicit directory rename(s) putting the following path(s) there: {s}.", .{ new_path, joined });
            clean = false;
        } else if (c_info.source_files.items.len > 1) {
            c_info.reported_already = true;
            const joined = try std.mem.join(m.arena, ", ", c_info.source_files.items);
            try m.pathMsg(.dir_rename_collision, new_path, null, null, c_info.source_files.items, "CONFLICT (implicit dir rename): Cannot map more than one path to {s}; implicit directory renames tried to put these paths there: {s}", .{ new_path, joined });
            clean = false;
        }
        if (!clean) return null;
        return new_path;
    }

    /// `get_provisional_directory_renames`.
    fn getProvisionalDirectoryRenames(m: *Merge, side: usize, clean: *bool) Allocator.Error!void {
        var it = m.dir_rename_count[side].iterator();
        while (it.next()) |entry| {
            const source_dir = entry.key;
            var max: i64 = 0;
            var bad_max: i64 = 0;
            var best: ?[]const u8 = null;
            var count_it = entry.value.iterator();
            while (count_it.next()) |count_entry| {
                const count = count_entry.value;
                if (count == max) {
                    bad_max = max;
                } else if (count > max) {
                    max = count;
                    best = count_entry.key;
                }
            }
            if (max == 0) continue;
            if (bad_max == max) {
                try m.pathMsg(.dir_rename_split, source_dir, null, null, &.{}, "CONFLICT (directory rename split): Unclear where to rename {s} to; it was renamed to multiple other directories, with no destination getting a majority of the files.", .{source_dir});
                clean.* = false;
            } else {
                try m.dir_renames[side].put(m.arena, source_dir, best.?);
            }
        }
    }

    /// `handle_directory_level_conflicts`: a directory both sides renamed
    /// is renamed by neither's additions.
    fn handleDirectoryLevelConflicts(m: *Merge) void {
        var duplicated: std.ArrayList([]const u8) = .empty;
        var it = m.dir_renames[1].keyIterator();
        while (it.next()) |key| {
            if (m.dir_renames[2].contains(key.*)) duplicated.append(m.arena, key.*) catch {};
        }
        for (duplicated.items) |key| {
            _ = m.dir_renames[1].remove(key);
            _ = m.dir_renames[2].remove(key);
        }
    }

    /// `check_dir_renamed`: the deepest renamed directory above `path`.
    fn checkDirRenamed(path: []const u8, dir_renames: *const std.StringHashMapUnmanaged([]const u8)) ?struct { old: []const u8, new: []const u8 } {
        var end = path.len;
        while (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |slash| {
            end = slash;
            if (dir_renames.getEntry(path[0..end])) |e| return .{ .old = e.key_ptr.*, .new = e.value_ptr.* };
        }
        return null;
    }

    /// `compute_collisions`.
    fn computeCollisions(m: *Merge, collisions: *std.StringHashMapUnmanaged(*CollisionInfo), dir_renames: *const std.StringHashMapUnmanaged([]const u8), pairs: []const *Pair) Allocator.Error!void {
        if (dir_renames.count() == 0) return;
        for (pairs) |pair| {
            if (pair.status != 'A' and pair.status != 'R') continue;
            const found = checkDirRenamed(pair.two.path, dir_renames) orelse continue;
            const new_path = try m.applyDirRename(found.old, found.new, pair.two.path);
            const slot = try collisions.getOrPut(m.arena, new_path);
            if (!slot.found_existing) {
                slot.value_ptr.* = try m.arena.create(CollisionInfo);
                slot.value_ptr.*.* = .{};
            }
            // `string_list_insert`: sorted, no duplicates.
            const list = &slot.value_ptr.*.source_files;
            var at: usize = 0;
            var present = false;
            while (at < list.items.len) : (at += 1) {
                switch (std.mem.order(u8, list.items[at], pair.two.path)) {
                    .lt => continue,
                    .eq => present = true,
                    .gt => {},
                }
                break;
            }
            if (!present) try list.insert(m.arena, at, pair.two.path);
        }
    }

    /// `check_for_directory_rename`.
    fn checkForDirectoryRename(
        m: *Merge,
        path: []const u8,
        side_index: usize,
        p: *Pair,
        dir_renames: *const std.StringHashMapUnmanaged([]const u8),
        exclusions: *const std.StringHashMapUnmanaged([]const u8),
        collisions: *[3]std.StringHashMapUnmanaged(*CollisionInfo),
        clean: *bool,
    ) Allocator.Error!?[]const u8 {
        if (dir_renames.count() == 0) return null;
        const other_side = 3 - side_index;
        if (collisions[other_side].contains(path)) return null;
        const found = checkDirRenamed(path, dir_renames) orelse return null;
        if (exclusions.contains(found.new)) {
            try m.pathMsg(.dir_rename_skipped, found.old, path, found.new, &.{}, "WARNING: Avoiding applying {s} -> {s} rename to {s}, because {s} itself was renamed.", .{ found.old, found.new, path, found.new });
            return null;
        }
        const new_path = try m.handlePathLevelConflicts(path, side_index, p, found.old, found.new, &collisions[side_index]);
        if (new_path == null) clean.* = false;
        return new_path;
    }

    /// `apply_directory_rename_modifications`.
    fn applyDirectoryRenameModifications(m: *Merge, pair: *Pair, new_path_in: []const u8) Allocator.Error!void {
        const old_entry = m.paths.getEntry(pair.two.path).?;
        const old_path = old_entry.key_ptr.*;
        var ci = old_entry.value_ptr.*;

        var dirs_to_insert: std.ArrayList([]const u8) = .empty;
        var cur_path = new_path_in;
        var parent_name: []const u8 = "";
        while (true) {
            const slash = std.mem.lastIndexOfScalar(u8, cur_path, '/') orelse {
                parent_name = "";
                break;
            };
            const candidate = cur_path[0..slash];
            if (m.paths.getKey(candidate)) |known| {
                parent_name = known;
                break;
            }
            try dirs_to_insert.append(m.arena, try m.arena.dupe(u8, candidate));
            cur_path = candidate;
        }
        var i = dirs_to_insert.items.len;
        while (i > 0) {
            i -= 1;
            const cur_dir = dirs_to_insert.items[i];
            const dir_ci = try m.arena.create(Info);
            dir_ci.* = .{
                .result = .{ .oid = m.zero() },
                .clean = false,
                .basename_offset = baseOffset(parent_name),
                .directory_name = parent_name,
                .stages = .{ .{ .oid = m.zero() }, .{ .oid = m.zero() }, .{ .oid = m.zero() } },
                .pathnames = .{ "", "", "" },
                .dirmask = ci.filemask,
            };
            try m.paths.put(m.arena, cur_dir, dir_ci);
            parent_name = cur_dir;
        }

        if (ci.dirmask == 0) {
            _ = m.paths.remove(old_path);
        } else {
            const new_ci = try m.arena.create(Info);
            new_ci.* = ci.*;
            new_ci.dirmask = 0;
            new_ci.stages[1] = .{ .oid = m.zero() };
            ci.filemask = 0;
            ci.clean = true;
            for (0..3) |s| {
                if (ci.dirmask & (@as(u3, 1) << @intCast(s)) != 0) continue;
                ci.stages[s] = .{ .oid = m.zero() };
            }
            ci = new_ci;
        }

        const branch_with_new_path = if (ci.filemask == 2) m.branch1 else m.branch2;
        const branch_with_dir_rename = if (ci.filemask == 2) m.branch2 else m.branch1;

        ci.directory_name = parent_name;
        ci.basename_offset = baseOffset(parent_name);
        const new_path = try m.arena.dupe(u8, new_path_in);
        if (m.paths.get(new_path)) |existing| {
            existing.filemask |= ci.filemask;
            if (existing.dirmask != 0) existing.df_conflict = true;
            const index: usize = ci.filemask >> 1;
            existing.pathnames[index] = ci.pathnames[index];
            existing.stages[index] = ci.stages[index];
            ci = existing;
        } else {
            try m.paths.put(m.arena, new_path, ci);
        }
        const interned = m.paths.getKey(new_path).?;

        if (m.options.directory_renames == .on) {
            if (pair.status == 'A') {
                try m.pathMsg(.dir_rename_applied, interned, old_path, null, &.{}, "Path updated: {s} added in {s} inside a directory that was renamed in {s}; moving it to {s}.", .{ old_path, branch_with_new_path, branch_with_dir_rename, interned });
            } else {
                try m.pathMsg(.dir_rename_applied, interned, old_path, null, &.{}, "Path updated: {s} renamed to {s} in {s}, inside a directory that was renamed in {s}; moving it to {s}.", .{ pair.one.path, old_path, branch_with_new_path, branch_with_dir_rename, interned });
            }
        } else {
            ci.path_conflict = true;
            if (pair.status == 'A') {
                try m.pathMsg(.dir_rename_suggested, interned, old_path, null, &.{}, "CONFLICT (file location): {s} added in {s} inside a directory that was renamed in {s}, suggesting it should perhaps be moved to {s}.", .{ old_path, branch_with_new_path, branch_with_dir_rename, interned });
            } else {
                try m.pathMsg(.dir_rename_suggested, interned, old_path, null, &.{}, "CONFLICT (file location): {s} renamed to {s} in {s}, inside a directory that was renamed in {s}, suggesting it should perhaps be moved to {s}.", .{ pair.one.path, old_path, branch_with_new_path, branch_with_dir_rename, interned });
            }
        }
        pair.two.path = interned;
    }

    //---------------------------------------------------------------------
    // Rename detection: diffcore-rename
    //---------------------------------------------------------------------

    fn resolveStatuses(queue: []const *Pair) void {
        for (queue) |p| {
            p.status = 0;
            if (!p.one.valid()) {
                p.status = 'A';
            } else if (!p.two.valid()) {
                p.status = 'D';
            } else if (p.renamed) {
                p.status = 'R';
            }
        }
    }

    /// `detect_regular_renames`: whether the search ran.
    fn detectRegularRenames(m: *Merge, side: usize) Error!bool {
        // `prune_cached_from_relevant`.
        var cit = m.cached_pairs[side].iterator();
        while (cit.next()) |node| _ = m.relevant_sources[side].remove(node.key);
        var iit = m.cached_irrelevant[side].keyIterator();
        while (iit.next()) |key| _ = m.relevant_sources[side].remove(key.*);
        if (m.pairs[side].items.len == 0 or m.relevant_sources[side].count() == 0) {
            resolveStatuses(m.pairs[side].items);
            return false;
        }
        m.dir_rename_count[side] = .{};
        const outcome = try rename.detect(m.arena, m.io, m.db, &m.pairs[side], .{
            .minimum_score = m.options.rename_score,
            .rename_limit = if (m.options.rename_limit <= 0) 7000 else m.options.rename_limit,
            .rename_empty = false,
            .relevant_sources = &m.relevant_sources[side],
            .dirs_removed = &m.dirs_removed[side],
            .dir_rename_count = &m.dir_rename_count[side],
            .cached_pairs = &m.cached_pairs[side],
        });
        resolveStatuses(m.pairs[side].items);
        if (outcome.needed_limit > 0) m.redo_after_renames = 0;
        if (outcome.needed_limit > m.needed_limit) m.needed_limit = outcome.needed_limit;
        return true;
    }

    /// `possibly_cache_new_pair`, for the pairs a first pass found.
    fn possiblyCacheNewPair(m: *Merge, p: *Pair, side: usize) Allocator.Error!void {
        const val = m.relevant_sources[side].get(p.one.path) orelse -1;
        if (val == Relevance.no_more) try m.cached_irrelevant[side].put(m.arena, p.one.path, {});
        if (val <= 0) return;
        if (p.status == 'D') {
            try m.cached_pairs[side].put(m.arena, p.one.path, null);
        } else if (p.status == 'R') {
            try m.cached_pairs[side].put(m.arena, p.one.path, p.two.path);
            try m.cached_target_names[side].put(m.arena, p.two.path, {});
        }
    }

    /// `use_cached_pairs`: the renames and deletions a first pass found,
    /// put back among the pairs.
    fn useCachedPairs(m: *Merge, side: usize) Allocator.Error!void {
        var it = m.cached_pairs[side].iterator();
        while (it.next()) |node| {
            const old_name = node.key;
            var new_name = old_name;
            if (node.value) |target| {
                const mi = m.paths.get(target) orelse continue;
                if (mi.clean) continue;
                new_name = target;
            }
            const one = try m.arena.create(Spec);
            const two = try m.arena.create(Spec);
            one.* = .{ .path = try m.arena.dupe(u8, old_name), .oid = m.zero() };
            two.* = .{ .path = try m.arena.dupe(u8, new_name), .oid = m.zero() };
            const pair = try m.arena.create(Pair);
            pair.* = .{ .one = one, .two = two, .status = if (node.value != null) 'R' else 'D' };
            try m.pairs[side].append(m.arena, pair);
        }
    }

    /// `collect_renames`.
    fn collectRenames(
        m: *Merge,
        result: *std.ArrayList(*Pair),
        side_index: usize,
        collisions: *[3]std.StringHashMapUnmanaged(*CollisionInfo),
        dir_renames_for_side: *const std.StringHashMapUnmanaged([]const u8),
        rename_exclusions: *const std.StringHashMapUnmanaged([]const u8),
    ) Allocator.Error!bool {
        var clean = true;
        for (m.pairs[side_index].items) |p| {
            if (p.status != 'A' and p.status != 'R') continue;
            if (!(m.options.directory_renames == .off and p.status == 'R')) {
                const new_path = try m.checkForDirectoryRename(p.two.path, side_index, p, dir_renames_for_side, rename_exclusions, collisions, &clean);
                if (p.status != 'R' and new_path == null) continue;
                if (new_path) |np| try m.applyDirectoryRenameModifications(p, np);
            }
            p.score = @intCast(side_index);
            try result.append(m.arena, p);
        }
        return clean;
    }

    fn lessThanPairs(_: void, a: *Pair, b: *Pair) bool {
        return std.mem.order(u8, a.one.path, b.one.path) == .lt;
    }

    /// `detect_and_process_renames`.
    fn detectAndProcessRenames(m: *Merge) Error!bool {
        var clean = true;
        const possible = (m.pairs[1].items.len > 0 and m.relevant_sources[1].count() > 0) or
            (m.pairs[2].items.len > 0 and m.relevant_sources[2].count() > 0) or
            m.cached_pairs[1].size != 0 or m.cached_pairs[2].size != 0;
        if (!possible) return clean;
        if (!m.options.renames) {
            m.redo_after_renames = 0;
            return clean;
        }

        var detection_run = try m.detectRegularRenames(1);
        if (try m.detectRegularRenames(2)) detection_run = true;
        if (m.needed_limit != 0) m.redo_after_renames = 0;
        if (m.redo_after_renames != 0 and detection_run) {
            for (1..3) |side| {
                for (m.pairs[side].items) |p| try m.possiblyCacheNewPair(p, side);
            }
            m.redo_after_renames = 2;
            return clean;
        }
        try m.useCachedPairs(1);
        try m.useCachedPairs(2);

        const need_dir_renames = m.call_depth == 0 and m.options.directory_renames != .off;
        if (need_dir_renames) {
            try m.getProvisionalDirectoryRenames(1, &clean);
            try m.getProvisionalDirectoryRenames(2, &clean);
            m.handleDirectoryLevelConflicts();
        }

        var collisions: [3]std.StringHashMapUnmanaged(*CollisionInfo) = .{ .empty, .empty, .empty };
        for (1..3) |i| {
            const other = 3 - i;
            try m.computeCollisions(&collisions[i], &m.dir_renames[other], m.pairs[i].items);
        }
        var combined: std.ArrayList(*Pair) = .empty;
        if (!try m.collectRenames(&combined, 1, &collisions, &m.dir_renames[2], &m.dir_renames[1])) clean = false;
        if (!try m.collectRenames(&combined, 2, &collisions, &m.dir_renames[1], &m.dir_renames[2])) clean = false;
        std.mem.sort(*Pair, combined.items, {}, lessThanPairs);
        if (!try m.processRenames(combined.items)) clean = false;
        return clean;
    }

    /// `process_renames`.
    fn processRenames(m: *Merge, renames: []const *Pair) Error!bool {
        var clean_merge = true;
        var i: usize = 0;
        while (i < renames.len) : (i += 1) {
            const pair = renames[i];
            const old_entry = m.paths.getEntry(pair.one.path);
            const new_entry = m.paths.getEntry(pair.two.path);
            const oldpath: ?[]const u8 = if (old_entry) |e| e.key_ptr.* else null;
            const oldinfo: ?*Info = if (old_entry) |e| e.value_ptr.* else null;
            var newpath = pair.two.path;
            var newinfo: ?*Info = null;
            if (new_entry) |e| {
                newpath = e.key_ptr.*;
                newinfo = e.value_ptr.*;
            }
            if (oldpath != null and std.mem.eql(u8, oldpath.?, newpath)) continue;
            if (oldinfo == null or oldinfo.?.clean) continue;
            const old = oldinfo.?;
            const old_path = oldpath.?;

            if (i + 1 < renames.len and std.mem.eql(u8, old_path, renames[i + 1].one.path)) {
                const pathnames: [3][]const u8 = .{ old_path, newpath, renames[i + 1].two.path };
                const base = m.paths.get(pathnames[0]).?;
                const side1 = m.paths.get(pathnames[1]).?;
                const side2 = m.paths.get(pathnames[2]).?;
                if (std.mem.eql(u8, pathnames[1], pathnames[2])) {
                    side1.stages[0] = base.stages[0];
                    side1.filemask |= 1;
                    base.is_null = true;
                    base.clean = true;
                    i += 1;
                    continue;
                }
                var merged: Version = .{ .oid = m.zero() };
                const clean = try m.handleContentMerge(pair.one.path, base.stages[0], side1.stages[1], side2.stages[2], pathnames, 1 + 2 * m.call_depth, &merged);
                if (!clean) clean_merge = false;
                const was_binary_blob = !clean and merged.mode == side1.stages[1].mode and merged.oid.eql(side1.stages[1].oid);
                side1.stages[1] = merged;
                if (was_binary_blob) {
                    merged.oid = side2.stages[2].oid;
                    merged.mode = side2.stages[2].mode;
                }
                side2.stages[2] = merged;
                side1.path_conflict = true;
                side2.path_conflict = true;
                base.path_conflict = true;
                try m.pathMsg(.rename_rename, pathnames[0], pathnames[1], pathnames[2], &.{}, "CONFLICT (rename/rename): {s} renamed to {s} in {s} and to {s} in {s}.", .{ pathnames[0], pathnames[1], m.branch1, pathnames[2], m.branch2 });
                i += 1;
                continue;
            }

            const new = newinfo.?;
            const target_index: usize = pair.score;
            const other_source_index = 3 - target_index;
            const old_sidemask = @as(u3, 1) << @intCast(other_source_index);
            const source_deleted = old.filemask == 1;
            var collision = (new.filemask & old_sidemask) != 0;
            const type_changed = !source_deleted and (isReg(old.stages[other_source_index].mode) != isReg(new.stages[target_index].mode));
            if (type_changed and collision) collision = false;
            var rename_branch: []const u8 = "";
            var delete_branch: []const u8 = "";
            if (source_deleted) {
                if (target_index == 1) {
                    rename_branch = m.branch1;
                    delete_branch = m.branch2;
                } else {
                    rename_branch = m.branch2;
                    delete_branch = m.branch1;
                }
            }

            if (collision and !source_deleted) {
                var pathnames: [3][]const u8 = undefined;
                pathnames[0] = old_path;
                pathnames[other_source_index] = old_path;
                pathnames[target_index] = newpath;
                const base = m.paths.get(pathnames[0]).?;
                const side1 = m.paths.get(pathnames[1]).?;
                const side2 = m.paths.get(pathnames[2]).?;
                var merged: Version = .{ .oid = m.zero() };
                const clean = try m.handleContentMerge(pair.one.path, base.stages[0], side1.stages[1], side2.stages[2], pathnames, 1 + 2 * m.call_depth, &merged);
                new.stages[target_index] = merged;
                if (!clean) {
                    try m.pathMsg(.rename_collides, newpath, old_path, null, &.{}, "CONFLICT (rename involved in collision): rename of {s} -> {s} has content conflicts AND collides with another path; this may result in nested conflict markers.", .{ old_path, newpath });
                }
            } else if (collision and source_deleted) {
                new.path_conflict = true;
                try m.pathMsg(.rename_delete, newpath, old_path, null, &.{}, "CONFLICT (rename/delete): {s} renamed to {s} in {s}, but deleted in {s}.", .{ old_path, newpath, rename_branch, delete_branch });
            } else {
                new.stages[0] = old.stages[0];
                new.filemask |= 1;
                new.pathnames[0] = old_path;
                if (type_changed) {
                    old.stages[0] = .{ .oid = m.zero() };
                    old.filemask &= 6;
                } else if (source_deleted) {
                    new.path_conflict = true;
                    try m.pathMsg(.rename_delete, newpath, old_path, null, &.{}, "CONFLICT (rename/delete): {s} renamed to {s} in {s}, but deleted in {s}.", .{ old_path, newpath, rename_branch, delete_branch });
                } else {
                    new.stages[other_source_index] = old.stages[other_source_index];
                    new.filemask |= old_sidemask;
                    new.pathnames[other_source_index] = old_path;
                }
            }
            if (!type_changed) {
                old.is_null = true;
                old.clean = true;
            }
        }
        return clean_merge;
    }

    //---------------------------------------------------------------------
    // Processing every path, and writing trees
    //---------------------------------------------------------------------

    const VersionItem = struct { name: []const u8, version: *Version };
    const OffsetItem = struct { dir: []const u8, offset: usize };

    const DirMetadata = struct {
        versions: std.ArrayList(VersionItem) = .empty,
        offsets: std.ArrayList(OffsetItem) = .empty,
        last_directory: ?[]const u8 = null,
    };

    fn recordEntryForTree(m: *Merge, meta: *DirMetadata, path: []const u8, mi: *Info) Allocator.Error!void {
        if (mi.is_null) return;
        try meta.versions.append(m.arena, .{ .name = path[mi.basename_offset..], .version = &mi.result });
    }

    fn treeEntryLess(_: void, a: VersionItem, b: VersionItem) bool {
        // `base_name_compare`: a tree's name compares as though it ended
        // in `/`.
        const len = @min(a.name.len, b.name.len);
        switch (std.mem.order(u8, a.name[0..len], b.name[0..len])) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        const c1: u8 = if (a.name.len > len) a.name[len] else if (isDir(a.version.mode)) '/' else 0;
        const c2: u8 = if (b.name.len > len) b.name[len] else if (isDir(b.version.mode)) '/' else 0;
        return c1 < c2;
    }

    /// `write_tree`.
    fn writeTree(m: *Merge, versions: []VersionItem) Error!Oid {
        std.mem.sort(VersionItem, versions, {}, treeEntryLess);
        var buf: std.ArrayList(u8) = .empty;
        for (versions) |item| {
            try buf.print(m.arena, "{o} {s}", .{ item.version.mode, item.name });
            try buf.append(m.arena, 0);
            try buf.appendSlice(m.arena, item.version.oid.raw());
        }
        return m.db.write(m.io, .tree, buf.items);
    }

    /// `write_completed_directory`.
    fn writeCompletedDirectory(m: *Merge, new_directory_name: []const u8, info: *DirMetadata) Error!void {
        if (info.last_directory) |last| {
            if (std.mem.eql(u8, new_directory_name, last)) return;
        }
        if (info.last_directory == null or std.mem.startsWith(u8, new_directory_name, info.last_directory.?)) {
            try info.offsets.append(m.arena, .{ .dir = new_directory_name, .offset = info.versions.items.len });
            info.last_directory = new_directory_name;
            return;
        }
        const last = info.last_directory.?;
        const dir_info = m.paths.get(last).?;
        const offset = info.offsets.items[info.offsets.items.len - 1].offset;
        if (offset == info.versions.items.len) {
            dir_info.is_null = true;
        } else {
            dir_info.is_null = false;
            dir_info.result.mode = S_IFDIR;
            dir_info.result.oid = try m.writeTree(info.versions.items[offset..]);
        }
        info.offsets.items.len -= 1;
        info.versions.items.len = offset;
        const prev_dir: ?[]const u8 = if (info.offsets.items.len == 0) null else info.offsets.items[info.offsets.items.len - 1].dir;
        if (prev_dir == null or !std.mem.eql(u8, new_directory_name, prev_dir.?)) {
            try info.offsets.append(m.arena, .{ .dir = new_directory_name, .offset = info.versions.items.len });
        }
        info.last_directory = new_directory_name;
    }

    /// `process_entry`.
    fn processEntry(m: *Merge, path_in: []const u8, ci_in: *Info, meta: *DirMetadata) Error!void {
        var path = path_in;
        var ci = ci_in;
        var df_file_index: usize = 0;

        if (ci.dirmask != 0) {
            try m.recordEntryForTree(meta, path, ci);
            if (ci.filemask == 0) return;
        }

        if (ci.df_conflict and ci.result.mode == 0) {
            ci.df_conflict = false;
            ci.clean = false;
            ci.is_null = false;
            ci.match_mask = ci.match_mask & ~ci.dirmask;
            ci.dirmask = 0;
            for (0..3) |i| {
                if (ci.filemask & (@as(u3, 1) << @intCast(i)) != 0) continue;
                ci.stages[i] = .{ .oid = m.zero() };
            }
        } else if (ci.df_conflict and ci.result.mode != 0) {
            if (ci.filemask == 1) {
                ci.filemask = 0;
                return;
            }
            const new_ci = try m.arena.create(Info);
            new_ci.* = ci.*;
            new_ci.match_mask = new_ci.match_mask & ~new_ci.dirmask;
            new_ci.dirmask = 0;
            for (0..3) |i| {
                if (new_ci.filemask & (@as(u3, 1) << @intCast(i)) != 0) continue;
                new_ci.stages[i] = .{ .oid = m.zero() };
            }
            df_file_index = if (ci.dirmask & 2 != 0) 2 else 1;
            const branch = if (df_file_index == 1) m.branch1 else m.branch2;
            const old_path = path;
            path = try m.uniquePath(path, branch);
            try m.paths.put(m.arena, path, new_ci);
            try m.pathMsg(.file_directory, path, old_path, null, &.{}, "CONFLICT (file/directory): directory in the way of {s} from {s}; moving it to {s} instead.", .{ old_path, branch, path });
            ci.filemask = 0;
            ci = new_ci;
        }

        if (ci.match_mask != 0) {
            ci.clean = !ci.df_conflict and !ci.path_conflict;
            if (ci.match_mask == 6) {
                ci.result = ci.stages[1];
            } else {
                const othermask: u3 = 7 & ~ci.match_mask;
                const side: usize = if (othermask == 4) 2 else 1;
                ci.result = ci.stages[side];
                ci.is_null = ci.result.mode == 0;
                if (ci.is_null) ci.clean = true;
                if (ci.is_null != (ci.filemask == ci.match_mask)) return error.DirectoryRenameLostStage;
            }
        } else if (ci.filemask >= 6 and (ci.stages[1].mode & S_IFMT) != (ci.stages[2].mode & S_IFMT)) {
            if (m.call_depth > 0) {
                ci.clean = false;
                ci.result = ci.stages[0];
                ci.is_null = ci.result.mode == 0;
            } else {
                const o_mode = ci.stages[0].mode;
                const a_mode = ci.stages[1].mode;
                const b_mode = ci.stages[2].mode;
                var rename_a = false;
                var rename_b = false;
                if (isReg(a_mode)) {
                    rename_a = true;
                } else if (isReg(b_mode)) {
                    rename_b = true;
                } else {
                    rename_a = true;
                    rename_b = true;
                }
                var a_path: ?[]const u8 = null;
                var b_path: ?[]const u8 = null;
                if (rename_a) a_path = try m.uniquePath(path, m.branch1);
                if (rename_b) b_path = try m.uniquePath(path, m.branch2);
                if (rename_a and rename_b) {
                    try m.pathMsg(.distinct_modes, path, a_path, b_path, &.{}, "CONFLICT (distinct types): {s} had different types on each side; renamed both of them so each can be recorded somewhere.", .{path});
                } else {
                    try m.pathMsg(.distinct_modes, path, if (rename_a) a_path else b_path, null, &.{}, "CONFLICT (distinct types): {s} had different types on each side; renamed one of them so each can be recorded somewhere.", .{path});
                }
                ci.clean = false;
                const new_ci = try m.arena.create(Info);
                new_ci.* = ci.*;
                new_ci.result = ci.stages[2];
                new_ci.stages[1] = .{ .oid = m.zero() };
                new_ci.filemask = 5;
                if ((b_mode & S_IFMT) != (o_mode & S_IFMT)) {
                    new_ci.stages[0] = .{ .oid = m.zero() };
                    new_ci.filemask = 4;
                }
                ci.result = ci.stages[1];
                ci.stages[2] = .{ .oid = m.zero() };
                ci.filemask = 3;
                if ((a_mode & S_IFMT) != (o_mode & S_IFMT)) {
                    ci.stages[0] = .{ .oid = m.zero() };
                    ci.filemask = 2;
                }
                if (rename_a) try m.paths.put(m.arena, a_path.?, ci);
                if (!rename_b) b_path = path;
                try m.paths.put(m.arena, b_path.?, new_ci);
                if (rename_a and rename_b) _ = m.paths.remove(path);
                try m.conflicted.put(m.arena, b_path.?, new_ci);
                try m.recordEntryForTree(meta, b_path.?, new_ci);
                if (a_path) |p| path = p;
            }
        } else if (ci.filemask >= 6) {
            var merged_file: Version = .{ .oid = m.zero() };
            const clean_merge = try m.handleContentMerge(path, ci.stages[0], ci.stages[1], ci.stages[2], ci.pathnames, m.call_depth * 2, &merged_file);
            ci.clean = clean_merge and !ci.df_conflict and !ci.path_conflict;
            ci.result = merged_file;
            ci.is_null = merged_file.mode == 0;
            if (clean_merge and ci.df_conflict) {
                ci.filemask = @as(u3, 1) << @intCast(df_file_index);
                ci.stages[df_file_index] = merged_file;
            }
            if (!clean_merge) {
                var reason: []const u8 = "content";
                if (ci.filemask == 6) reason = "add/add";
                if (merged_file.mode & S_IFMT == S_IFGITLINK) reason = "submodule";
                try m.pathMsg(.contents, path, null, null, &.{}, "CONFLICT ({s}): Merge conflict in {s}", .{ reason, path });
            }
        } else if (ci.filemask == 3 or ci.filemask == 5) {
            const side: usize = if (ci.filemask == 5) 2 else 1;
            const index: usize = if (m.call_depth > 0) 0 else side;
            ci.result = ci.stages[index];
            ci.clean = false;
            const modify_branch = if (side == 1) m.branch1 else m.branch2;
            const delete_branch = if (side == 1) m.branch2 else m.branch1;
            if (m.options.renormalize != null and try m.blobUnchanged(ci.stages[0], ci.stages[side], path)) {
                if (!ci.path_conflict) {
                    // Unchanged once renormalized: no modify/delete after
                    // all, and the file goes, taking any directory/file
                    // conflict with it.
                    ci.is_null = true;
                    ci.clean = true;
                    ci.df_conflict = false;
                }
                // A rename/delete stays a conflict, and has said so.
            } else if (ci.path_conflict and ci.stages[0].oid.eql(ci.stages[side].oid)) {
                // From a rename/delete, which has said so already.
            } else {
                try m.pathMsg(.modify_delete, path, null, null, &.{}, "CONFLICT (modify/delete): {s} deleted in {s} and modified in {s}.  Version {s} of {s} left in tree.", .{ path, delete_branch, modify_branch, modify_branch, path });
            }
        } else if (ci.filemask == 2 or ci.filemask == 4) {
            const side: usize = if (ci.filemask == 4) 2 else 1;
            ci.result = ci.stages[side];
            ci.clean = !ci.df_conflict and !ci.path_conflict;
        } else if (ci.filemask == 1) {
            ci.is_null = true;
            ci.result = .{ .oid = m.zero() };
            ci.clean = !ci.path_conflict;
        }

        if (!ci.clean) try m.conflicted.put(m.arena, path, ci);
        try m.recordEntryForTree(meta, path, ci);
    }

    /// `sort_dirs_next_to_their_children`: a path sorts as though it ended
    /// in `/`.
    fn dirsNextToChildren(_: void, one: []const u8, two: []const u8) bool {
        var i: usize = 0;
        while (i < one.len and i < two.len and one[i] == two[i]) i += 1;
        const c1: u8 = if (i < one.len) one[i] else '/';
        const c2: u8 = if (i < two.len) two[i] else '/';
        if (c1 == c2) return i >= one.len;
        return c1 < c2;
    }

    /// `process_entries`.
    fn processEntries(m: *Merge) Error!Oid {
        if (m.paths.count() == 0) return emptyTree(m.db.kind);
        var plist: std.ArrayList([]const u8) = .empty;
        var it = m.paths.keyIterator();
        while (it.next()) |key| try plist.append(m.arena, key.*);
        std.mem.sort([]const u8, plist.items, {}, dirsNextToChildren);
        var meta: DirMetadata = .{};
        var i = plist.items.len;
        while (i > 0) {
            i -= 1;
            const path = plist.items[i];
            const mi = m.paths.get(path).?;
            try m.writeCompletedDirectory(mi.directory_name, &meta);
            if (mi.clean) {
                try m.recordEntryForTree(&meta, path, mi);
            } else {
                try m.processEntry(path, mi, &meta);
            }
        }
        return m.writeTree(meta.versions.items);
    }

    //---------------------------------------------------------------------
    // The drivers
    //---------------------------------------------------------------------

    /// `merge_ort_nonrecursive_internal`.
    fn nonrecursive(m: *Merge, base: Oid, side1: Oid, side2: Oid) Error!Outcome {
        m.reset();
        var passes: u32 = 0;
        while (true) : (passes += 1) {
            try m.collectMergeInfo(base, side1, side2);
            _ = try m.detectAndProcessRenames();
            if (m.redo_after_renames != 2 or passes > 0) break;
            m.reinit();
        }
        const tree = try m.processEntries();
        return .{ .tree = tree };
    }

    fn fakeOid(m: *Merge, n: usize) Oid {
        var bytes: [hash.max_raw_len]u8 = @splat(0xff);
        std.mem.writeInt(u64, bytes[0..8], n, .big);
        return Oid.fromRaw(m.db.kind, bytes[0..m.db.kind.rawLen()]) catch unreachable;
    }

    fn treeOf(m: *Merge, ref: CommitRef) Error!Oid {
        switch (ref) {
            .virtual => |i| return m.virtuals.items[i].tree,
            .real => |oid| {
                const found = try m.db.read(m.io, oid);
                defer m.db.gpa.free(found.bytes);
                if (found.type != .commit) return error.NotACommit;
                var commit = try object.Commit.parse(m.arena, m.db.kind, found.bytes);
                defer commit.deinit();
                return commit.tree;
            },
        }
    }

    fn oidOf(m: *Merge, ref: CommitRef) Oid {
        return switch (ref) {
            .real => |oid| oid,
            .virtual => |i| m.virtuals.items[i].fake,
        };
    }

    fn refOf(m: *Merge, oid: Oid) CommitRef {
        for (m.virtuals.items, 0..) |v, i| {
            if (v.fake.eql(oid)) return .{ .virtual = i };
        }
        return .{ .real = oid };
    }

    fn mergeBasesOf(m: *Merge, a: CommitRef, b: CommitRef) Error![]const Oid {
        var virtuals: std.ArrayList(revwalk.Virtual) = .empty;
        for (m.virtuals.items) |v| {
            const parents = try m.arena.alloc(Oid, v.parents.len);
            for (v.parents, parents) |ref, *out| out.* = m.oidOf(ref);
            try virtuals.append(m.arena, .{ .oid = v.fake, .parents = parents });
        }
        const gpa = m.db.gpa;
        const found = try revwalk.mergeBasesWith(gpa, m.io, m.db, m.oidOf(a), m.oidOf(b), .{ .virtuals = virtuals.items });
        defer gpa.free(found);
        return m.arena.dupe(Oid, found);
    }

    /// `merge_ort_internal`.
    fn recursive(m: *Merge, given_bases: ?[]const Oid, h1: CommitRef, h2: CommitRef) Error!Outcome {
        var bases: std.ArrayList(CommitRef) = .empty;
        if (given_bases) |list| {
            for (list) |oid| try bases.append(m.arena, m.refOf(oid));
        } else {
            const found = try m.mergeBasesOf(h1, h2);
            var i = found.len;
            while (i > 0) {
                i -= 1;
                try bases.append(m.arena, m.refOf(found[i]));
            }
        }
        var ancestor_name: []const u8 = undefined;
        var merged_merge_bases: CommitRef = undefined;
        if (bases.items.len == 0) {
            try m.virtuals.append(m.arena, .{ .tree = emptyTree(m.db.kind), .parents = &.{}, .fake = m.fakeOid(m.virtuals.items.len) });
            merged_merge_bases = .{ .virtual = m.virtuals.items.len - 1 };
            ancestor_name = "empty tree";
        } else {
            merged_merge_bases = bases.items[0];
            if (bases.items.len > 1) {
                ancestor_name = "merged common ancestors";
            } else {
                var buf: [hash.max_hex_len]u8 = undefined;
                ancestor_name = try m.arena.dupe(u8, try abbrev.unique(m.io, m.db, m.oidOf(merged_merge_bases), m.options.abbrev_len, &buf));
            }
        }
        for (bases.items[@min(bases.items.len, 1)..]) |next| {
            const prev = merged_merge_bases;
            m.call_depth += 1;
            const saved_b1 = m.branch1;
            const saved_b2 = m.branch2;
            m.branch1 = "Temporary merge branch 1";
            m.branch2 = "Temporary merge branch 2";
            const inner = try m.recursive(null, prev, next);
            m.branch1 = saved_b1;
            m.branch2 = saved_b2;
            m.call_depth -= 1;
            const parents = try m.arena.dupe(CommitRef, &.{ prev, next });
            try m.virtuals.append(m.arena, .{ .tree = inner.tree, .parents = parents, .fake = m.fakeOid(m.virtuals.items.len) });
            merged_merge_bases = .{ .virtual = m.virtuals.items.len - 1 };
        }
        const saved_ancestor = m.ancestor;
        m.ancestor = ancestor_name;
        const outcome = try m.nonrecursive(try m.treeOf(merged_merge_bases), try m.treeOf(h1), try m.treeOf(h2));
        m.ancestor = saved_ancestor;
        return outcome;
    }

    fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    fn finish(m: *Merge, gpa: Allocator, arena_instance: *std.heap.ArenaAllocator, outcome: Outcome) Error!Result {
        var conflicted: std.ArrayList(Conflicted) = .empty;
        var cit = m.conflicted.iterator();
        while (cit.next()) |entry| {
            const ci = entry.value_ptr.*;
            var stages: [3]?Stage = .{ null, null, null };
            for (0..3) |i| {
                if (ci.filemask & (@as(u3, 1) << @intCast(i)) == 0) continue;
                stages[i] = .{ .mode = ci.stages[i].mode, .oid = ci.stages[i].oid };
            }
            try conflicted.append(m.arena, .{ .path = entry.key_ptr.*, .stages = stages });
        }
        std.mem.sort(Conflicted, conflicted.items, {}, struct {
            fn less(_: void, a: Conflicted, b: Conflicted) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);

        var keys: std.ArrayList([]const u8) = .empty;
        var kit = m.conflicts.keyIterator();
        while (kit.next()) |key| try keys.append(m.arena, key.*);
        std.mem.sort([]const u8, keys.items, {}, lessThanPath);
        var messages: std.ArrayList(Message) = .empty;
        for (keys.items) |key| try messages.appendSlice(m.arena, m.conflicts.get(key).?.items);

        return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .tree = outcome.tree,
            .conflicted = conflicted.items,
            .messages = messages.items,
            .rename_limit_needed = m.needed_limit,
        };
    }
};
