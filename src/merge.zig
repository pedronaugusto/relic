//! Three-way merges of blob contents and trees.
//!
//! The blob merge is `blobmerge.zig`'s, xdiff's decision for decision. The
//! tree merge here is stage-only by default: every path both sides changed
//! differently is left at stages 1, 2 and 3, which is not what any git
//! command does, and is for a caller that wants to decide every path
//! itself. With `content_merge` it is git's merge, `ort.zig`'s: renames
//! followed, files merged, conflicts recorded as git records them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const textdiff = @import("textdiff.zig");
const attributes = @import("attributes.zig");
const blobmerge = @import("blobmerge.zig");
const ort = @import("ort.zig");

const Oid = hash.Oid;

/// Errors from a merge.
pub const Error = error{
    /// A tree entry pointed at something that is not a tree.
    NotATree,
    /// The trees nest deeper than the walk will go.
    TreeTooDeep,
} || ort.Error || attributes.Error || Allocator.Error || odb_mod.Error || object.TreeParseError ||
    object.Tree.Builder.AddError || index_mod.ReadError;

/// A content merge refuses data git classifies as binary.
pub const BlobError = blobmerge.BlobError;
/// Which conflict body to write: `merge.conflictStyle`.
pub const ConflictStyle = blobmerge.ConflictStyle;
/// Which side a conflict resolves to without markers.
pub const Favor = blobmerge.Favor;
/// The words after the markers.
pub const Labels = blobmerge.Labels;
/// Options for a blob merge.
pub const BlobOptions = blobmerge.BlobOptions;
/// The owned bytes produced by a blob merge.
pub const BlobResult = blobmerge.BlobResult;
/// Merge `ours` and `theirs` against `ancestor`: `blobmerge.blobs`.
pub const blobs = blobmerge.blobs;
/// Where a refusal writes the path that caused it.
pub const Blocked = blobmerge.Blocked;

/// One side's view of a path.
pub const Side = struct {
    mode: object.Mode,
    oid: Oid,
};

/// A path both sides changed differently.
pub const Conflict = struct {
    /// Owned by the result.
    path: []const u8,
    /// Absent when the path was added on both sides.
    base: ?Side,
    /// Absent when our side deleted it.
    ours: ?Side,
    /// Absent when their side deleted it.
    theirs: ?Side,
    kind: Kind,
    /// What git leaves in the working tree for the path, and records in
    /// `AUTO_MERGE`, when content merging was requested: the conflict-marked
    /// blob, the surviving side of a modify/delete, our side where nothing
    /// could be merged. `null` where the merged tree has nothing there.
    result: ?Side = null,

    /// Which stages the index holds for the path -- the shapes `git status`
    /// names, from `UU` to `DD`.
    pub const Kind = enum {
        /// Stages 1, 2 and 3: both sides changed it. `UU`.
        both_modified,
        /// Stage 1 and one of 2 and 3: one side changed it and the other
        /// deleted it. `UD` and `DU`.
        modify_delete,
        /// Stages 2 and 3: both sides added it. `AA`.
        both_added,
        /// Stage 1 alone: both sides took it away, one of them by a rename
        /// the other does not share. `DD`.
        deleted_by_both,
        /// Stage 2 alone: ours put it there, and where it goes is the
        /// conflict. `AU`.
        added_by_ours,
        /// Stage 3 alone: theirs put it there. `UA`.
        added_by_theirs,

        /// The shape of these stages.
        pub fn of(base: bool, ours: bool, theirs: bool) Kind {
            if (base and ours and theirs) return .both_modified;
            if (ours and theirs) return .both_added;
            if (base and (ours or theirs)) return .modify_delete;
            if (base) return .deleted_by_both;
            if (ours) return .added_by_ours;
            return .added_by_theirs;
        }
    };
};

/// What a merge produced.
pub const Result = struct {
    gpa: Allocator,
    /// The merged index: stage 0 for everything that reconciled, and stages
    /// 1, 2 and 3 for everything that did not. The caller owns it.
    index: index_mod.Index,
    arena: std.heap.ArenaAllocator.State,
    conflicts: []Conflict,
    /// The merged tree, conflict markers and moved-aside files included,
    /// when content merging was asked for: what git's merge leaves in the
    /// working tree.
    tree: ?Oid = null,
    /// What git's merge says about the paths it merged, when content
    /// merging was asked for.
    messages: []const ort.Message = &.{},

    /// Whether every path reconciled.
    pub fn isClean(r: *const Result) bool {
        return r.conflicts.len == 0;
    }

    /// Release everything.
    pub fn deinit(r: *Result) void {
        r.index.deinit();
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

const Entries = std.StringHashMapUnmanaged(Side);

/// Options for a tree merge.
pub const TreeOptions = struct {
    /// Resolve what can be resolved the way git's merge machinery does:
    /// regular files are content-merged, a file added on both sides is
    /// merged against an empty ancestor, the executable bit is merged on its
    /// own, and a file that meets a directory the merge empties takes its
    /// place. Without it every path both sides changed differently is left
    /// at stages 1, 2 and 3.
    content_merge: bool = false,
    /// The labels, conflict style, favoured side and line diff of the
    /// content merges.
    blob: BlobOptions = .{ .algorithm = .histogram },
    /// The attributes that decide how a path is content-merged: `merge`
    /// (`-merge` and `merge=binary` keep our side as a conflict,
    /// `merge=union` keeps both, `merge=text` and an unknown name merge as
    /// text) and `conflict-marker-size`. git reads them from the working
    /// tree, and so does a caller that wants its answer.
    attributes: ?*attributes.Attrs = null,
    /// Where the `.gitattributes` files along a merged path are read from,
    /// into `attributes`, the first time a path under them is merged. Without
    /// it `attributes` is used as the caller loaded it.
    attributes_dir: ?Io.Dir = null,
    /// The names of the merge drivers `merge.<name>.driver` configures.
    /// Such a driver is a program; a path whose `merge` attribute names one
    /// is `error.UnsupportedMergeDriver`.
    configured_drivers: []const []const u8 = &.{},
    /// Everything else git's merge takes: renames, directory renames,
    /// submodules. Its labels and content options come from `blob` and
    /// the fields above.
    ort: ort.Options = .{},
};

/// Merge `ours` and `theirs` against their common ancestor `base`.
///
/// `base` may be `null`, which is what an unrelated-histories merge looks
/// like: every path that is in both sides and differs is a conflict.
pub fn trees(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
) Error!Result {
    return treesWithOptions(gpa, io, db, base, ours, theirs, .{});
}

/// `trees` with optional content resolution of regular-file conflicts.
pub fn treesWithOptions(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
    options: TreeOptions,
) Error!Result {
    if (options.content_merge) return contentMerge(gpa, io, db, base, ours, theirs, options);

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var base_entries: Entries = .empty;
    if (base) |oid| try flatten(arena, io, db, oid, "", &base_entries, 0);
    var our_entries: Entries = .empty;
    try flatten(arena, io, db, ours, "", &our_entries, 0);
    var their_entries: Entries = .empty;
    try flatten(arena, io, db, theirs, "", &their_entries, 0);

    var paths: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    inline for (.{ &base_entries, &our_entries, &their_entries }) |set| {
        var it = set.keyIterator();
        while (it.next()) |key| {
            const slot = try seen.getOrPut(arena, key.*);
            if (!slot.found_existing) try paths.append(arena, key.*);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var index: index_mod.Index = .initEmpty(gpa, db.kind);
    errdefer index.deinit();
    var conflicts: std.ArrayList(Conflict) = .empty;

    for (paths.items) |path| {
        const b = base_entries.get(path);
        const o = our_entries.get(path);
        const t = their_entries.get(path);

        // A directory on one side and a file on the other is a conflict
        // whatever the contents are, because one path cannot be both.
        if (isDirectoryOf(&our_entries, path) and t != null) {
            try conflicts.append(arena, .{
                .path = path,
                .base = b,
                .ours = o,
                .theirs = t,
                .kind = Conflict.Kind.of(b != null, o != null, t != null),
            });
            try stageAll(&index, path, b, o, t);
            continue;
        }
        if (isDirectoryOf(&their_entries, path) and o != null) {
            try conflicts.append(arena, .{
                .path = path,
                .base = b,
                .ours = o,
                .theirs = t,
                .kind = Conflict.Kind.of(b != null, o != null, t != null),
            });
            try stageAll(&index, path, b, o, t);
            continue;
        }

        if (sameSide(o, t)) {
            if (o) |side| try stage(&index, path, side, 0);
            continue;
        }
        if (sameSide(o, b)) {
            // Only their side moved.
            if (t) |side| try stage(&index, path, side, 0);
            continue;
        }
        if (sameSide(t, b)) {
            // Only our side moved.
            if (o) |side| try stage(&index, path, side, 0);
            continue;
        }

        const kind: Conflict.Kind = if (b == null)
            .both_added
        else if (o == null or t == null)
            .modify_delete
        else
            .both_modified;
        try conflicts.append(arena, .{
            .path = path,
            .base = b,
            .ours = o,
            .theirs = t,
            .kind = kind,
        });
        try stageAll(&index, path, b, o, t);
    }

    return .{
        .gpa = gpa,
        .index = index,
        .arena = arena_instance.state,
        .conflicts = conflicts.items,
    };
}

//=========================================================================
// The merge git's commands make
//=========================================================================

/// `ort.mergeTrees`, its answer put in this file's shape: the merged tree's
/// files at stage 0 and each conflicted path at the stages git gives it.
fn contentMerge(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
    options: TreeOptions,
) Error!Result {
    var ort_options = options.ort;
    ort_options.labels = options.blob.labels;
    ort_options.conflict_style = options.blob.conflict_style;
    ort_options.favor = options.blob.favor;
    ort_options.algorithm = options.blob.algorithm;
    ort_options.attributes = options.attributes;
    ort_options.attributes_dir = options.attributes_dir;
    ort_options.configured_drivers = options.configured_drivers;
    var merged = try ort.mergeTrees(gpa, io, db, base, ours, theirs, ort_options);
    defer merged.deinit();
    return fromOrt(gpa, io, db, &merged);
}

/// The index and conflicts of an `ort.Result`.
pub fn fromOrt(gpa: Allocator, io: Io, db: *odb_mod.Odb, merged: *const ort.Result) Error!Result {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var files: Entries = .empty;
    try flatten(arena, io, db, merged.tree, "", &files, 0);
    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    var index: index_mod.Index = .initEmpty(gpa, db.kind);
    errdefer index.deinit();
    for (merged.conflicted) |c| {
        const path = try arena.dupe(u8, c.path);
        try conflicted.put(arena, path, {});
        var sides: [3]?Side = .{ null, null, null };
        for (c.stages, 0..) |stage_entry, i| {
            const st = stage_entry orelse continue;
            // git's index takes a mode of nothing as a regular file.
            const mode = object.Mode.fromRaw(st.mode) catch .file;
            sides[i] = .{ .mode = mode, .oid = st.oid };
            try stage(&index, path, sides[i].?, @intCast(i + 1));
        }
        try conflicts.append(arena, .{
            .path = path,
            .base = sides[0],
            .ours = sides[1],
            .theirs = sides[2],
            .kind = Conflict.Kind.of(c.stages[0] != null, c.stages[1] != null, c.stages[2] != null),
            .result = files.get(path),
        });
    }
    var it = files.iterator();
    while (it.next()) |entry| {
        if (conflicted.contains(entry.key_ptr.*)) continue;
        try stage(&index, entry.key_ptr.*, entry.value_ptr.*, 0);
    }
    const messages = try ort.dupeMessages(arena, merged.messages);
    return .{
        .gpa = gpa,
        .index = index,
        .arena = arena_instance.state,
        .conflicts = conflicts.items,
        .tree = merged.tree,
        .messages = messages,
    };
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn sameSide(a: ?Side, b: ?Side) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.mode == b.?.mode and a.?.oid.eql(b.?.oid);
}

fn isDirectoryOf(entries: *const Entries, path: []const u8) bool {
    // A path is a directory on this side when some entry lives under it.
    var it = entries.keyIterator();
    while (it.next()) |key| {
        if (key.len > path.len and std.mem.startsWith(u8, key.*, path) and key.*[path.len] == '/') {
            return true;
        }
    }
    return false;
}

fn stage(index: *index_mod.Index, path: []const u8, side: Side, at: u2) Allocator.Error!void {
    try index.add(.{
        .path = path,
        .oid = side.oid,
        .mode = side.mode,
        .stage = at,
    });
}

fn stageAll(index: *index_mod.Index, path: []const u8, b: ?Side, o: ?Side, t: ?Side) Allocator.Error!void {
    if (b) |side| try stage(index, path, side, 1);
    if (o) |side| try stage(index, path, side, 2);
    if (t) |side| try stage(index, path, side, 3);
}

fn flatten(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    tree_oid: Oid,
    prefix: []const u8,
    out: *Entries,
    depth: u32,
) Error!void {
    if (depth > 64) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.gpa.free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const parsed: object.Tree = .parse(db.kind, found.bytes);
    var it = parsed.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        if (entry.mode == .tree) {
            try flatten(arena, io, db, entry.oid, path, out, depth + 1);
            continue;
        }
        try out.put(arena, path, .{ .mode = entry.mode, .oid = entry.oid });
    }
}

/// The tree a clean merge produces, written to the object database.
///
/// `error.MergeConflict` when the merge is not clean; the caller inspects
/// the `Result` for the conflicts instead.
pub fn tree(
    io: Io,
    db: *odb_mod.Odb,
    result: *Result,
) (Error || error{MergeConflict})!Oid {
    if (!result.isClean()) return error.MergeConflict;
    const cache_tree = try result.index.cacheTree();
    cache_tree.invalidateAll();
    return cache_tree.rebuild(io, result.index.entries.items, db);
}

/// The tree of what a merge leaves behind, conflicts and all: for a
/// content merge the tree it wrote, which is the one git records as
/// `AUTO_MERGE` and `git merge-tree --write-tree` prints; for a stage-only
/// one, every resolved path and our side of every conflicted one.
pub fn conflictedTree(gpa: Allocator, io: Io, db: *odb_mod.Odb, result: *const Result) Error!Oid {
    if (result.tree) |merged| return merged;
    var index: index_mod.Index = .initEmpty(gpa, db.kind);
    defer index.deinit();
    var entries: std.ArrayList(index_mod.Entry) = .empty;
    defer entries.deinit(gpa);
    for (result.index.entries.items) |entry| {
        if (entry.stage == 0) try entries.append(gpa, .{ .path = entry.path, .oid = entry.oid, .mode = entry.mode });
    }
    for (result.conflicts) |conflict| {
        const side = conflict.result orelse continue;
        try entries.append(gpa, .{ .path = conflict.path, .oid = side.oid, .mode = side.mode });
    }
    try index.addMany(entries.items);
    const cache_tree = try index.cacheTree();
    return cache_tree.rebuild(io, index.entries.items, db);
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("testgit.zig");

fn gitMergeFileFixture(
    gpa: Allocator,
    io: Io,
    ancestor: []const u8,
    ours: []const u8,
    theirs: []const u8,
    style: ConflictStyle,
) ![]u8 {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "ancestor", ancestor);
    try repo.writeFile(io, "ours", ours);
    try repo.writeFile(io, "theirs", theirs);
    repo.report_failures = false;
    const args: []const []const u8 = if (style == .diff3)
        &.{ "merge-file", "--diff3", "-L", "ours", "-L", "base", "-L", "theirs", "ours", "ancestor", "theirs" }
    else
        &.{ "merge-file", "-L", "ours", "-L", "base", "-L", "theirs", "ours", "ancestor", "theirs" };
    repo.exec(io, args) catch |err| switch (err) {
        error.GitFailed => {},
        else => |other| return other,
    };
    return repo.readFile(io, "ours");
}

/// What `git merge-file` makes of three texts under `options`, in a
/// repository the caller already has, so that a corpus pays for one `git
/// init` and not one per case.
fn gitMergeFile(
    gpa: Allocator,
    io: Io,
    repo: *testgit.Repo,
    ancestor: []const u8,
    ours: []const u8,
    theirs: []const u8,
    options: BlobOptions,
) ![]u8 {
    try repo.writeFile(io, "ancestor", ancestor);
    try repo.writeFile(io, "ours", ours);
    try repo.writeFile(io, "theirs", theirs);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "merge-file", "-p" });
    switch (options.conflict_style) {
        .merge => {},
        .diff3 => try argv.append(gpa, "--diff3"),
        .zdiff3 => try argv.append(gpa, "--zdiff3"),
    }
    if (options.algorithm == .histogram) try argv.append(gpa, "--diff-algorithm=histogram");
    switch (options.favor) {
        .none => {},
        .ours => try argv.append(gpa, "--ours"),
        .theirs => try argv.append(gpa, "--theirs"),
        .union_ => try argv.append(gpa, "--union"),
    }
    var size_buf: [32]u8 = undefined;
    if (options.marker_size != 7) {
        try argv.append(gpa, try std.fmt.bufPrint(&size_buf, "--marker-size={d}", .{options.marker_size}));
    }
    try argv.appendSlice(gpa, &.{
        "-L",   options.labels.ours, "-L",     options.labels.base, "-L", options.labels.theirs,
        "ours", "ancestor",          "theirs",
    });
    // A conflict is a non-zero exit, and the merged text is still printed.
    return repo.runInput(io, argv.items, "");
}

test "blob conflicts match git merge-file in merge and diff3 styles" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ancestor = "one\nbase\nend\n";
    const ours = "one\nours\nend\n";
    const theirs = "one\ntheirs\nend\n";

    for ([_]ConflictStyle{ .merge, .diff3 }) |style| {
        const expected = try gitMergeFileFixture(gpa, io, ancestor, ours, theirs, style);
        defer gpa.free(expected);
        var got = try blobs(gpa, ancestor, ours, theirs, .{ .conflict_style = style });
        defer got.deinit();
        try std.testing.expectEqual(BlobResult.Status.conflicted, got.status);
        try std.testing.expectEqualSlices(u8, expected, got.bytes);
    }
}

test "adjacent blob edits form the same conflict region as git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ancestor = "a\nb\nc\n";
    const ours = "A\nb\nc\n";
    const theirs = "a\nB\nc\n";
    const expected = try gitMergeFileFixture(gpa, io, ancestor, ours, theirs, .merge);
    defer gpa.free(expected);
    var got = try blobs(gpa, ancestor, ours, theirs, .{});
    defer got.deinit();
    try std.testing.expectEqual(BlobResult.Status.conflicted, got.status);
    try std.testing.expectEqualSlices(u8, expected, got.bytes);
}

test "conflict markers terminate lines that had no newline" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const expected = try gitMergeFileFixture(gpa, io, "base", "ours", "theirs", .merge);
    defer gpa.free(expected);
    var got = try blobs(gpa, "base", "ours", "theirs", .{});
    defer got.deinit();
    try std.testing.expectEqualSlices(u8, expected, got.bytes);
}

test "merge style moves a shared conflict tail outside the markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ancestor = "a\nb\nc\n";
    const ours = "A\nX\nc\n";
    const theirs = "B\nX\nc\n";
    const expected = try gitMergeFileFixture(gpa, io, ancestor, ours, theirs, .merge);
    defer gpa.free(expected);
    var got = try blobs(gpa, ancestor, ours, theirs, .{});
    defer got.deinit();
    try std.testing.expectEqualSlices(u8, expected, got.bytes);
}

test "independent and identical blob changes match git merge-file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ancestor = "a\nb\nc\nd\n";
    for ([_]struct { ours: []const u8, theirs: []const u8 }{
        .{ .ours = "A\nb\nc\nd\n", .theirs = "a\nb\nc\nD\n" },
        .{ .ours = "a\nB\nc\nd\n", .theirs = "a\nB\nc\nd\n" },
    }) |fixture| {
        const expected = try gitMergeFileFixture(gpa, io, ancestor, fixture.ours, fixture.theirs, .merge);
        defer gpa.free(expected);
        var got = try blobs(gpa, ancestor, fixture.ours, fixture.theirs, .{});
        defer got.deinit();
        try std.testing.expect(got.isClean());
        try std.testing.expectEqualSlices(u8, expected, got.bytes);
    }
}

test "a delete modify blob conflict matches git merge-file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ancestor = "base\n";
    const ours = "";
    const theirs = "changed\n";
    const expected = try gitMergeFileFixture(gpa, io, ancestor, ours, theirs, .merge);
    defer gpa.free(expected);
    var got = try blobs(gpa, ancestor, ours, theirs, .{});
    defer got.deinit();
    try std.testing.expectEqual(BlobResult.Status.conflicted, got.status);
    try std.testing.expectEqualSlices(u8, expected, got.bytes);
}

test "binary blob content is refused like git merge-file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ancestor = "a\x00base\n";
    const ours = "a\x00ours\n";
    const theirs = "a\x00theirs\n";
    const git_bytes = try gitMergeFileFixture(gpa, io, ancestor, ours, theirs, .merge);
    defer gpa.free(git_bytes);
    try std.testing.expectEqualSlices(u8, ours, git_bytes);
    try std.testing.expectError(error.BinaryBlob, blobs(gpa, ancestor, ours, theirs, .{}));
}

test "a random corpus of three-way merges matches git merge-file in every style and both algorithms" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // `--diff-algorithm` reached merge-file in 2.44; zdiff3 is older.
    try testgit.requireGitVersion(gpa, io, 2, 44);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    var prng = std.Random.DefaultPrng.init(0x6d65726765);
    const rng = prng.random();
    var texts: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    defer for (&texts) |*t| t.deinit(gpa);

    for (0..24) |case| {
        const alphabet: u8 = 2 + rng.uintLessThan(u8, 5);
        texts[0].clearRetainingCapacity();
        for (0..rng.uintLessThan(usize, 18)) |_| {
            try texts[0].append(gpa, 'a' + rng.uintLessThan(u8, alphabet));
            try texts[0].append(gpa, '\n');
        }
        for (texts[1..]) |*side| {
            side.clearRetainingCapacity();
            var lines = std.mem.splitScalar(u8, texts[0].items, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                switch (rng.uintLessThan(u8, 8)) {
                    0 => {},
                    1 => try side.appendSlice(gpa, &.{ 'a' + rng.uintLessThan(u8, alphabet), '\n', line[0], '\n' }),
                    2 => try side.appendSlice(gpa, &.{ line[0], '\n', 'a' + rng.uintLessThan(u8, alphabet), '\n' }),
                    3 => try side.appendSlice(gpa, &.{ 'a' + rng.uintLessThan(u8, alphabet), '\n' }),
                    else => try side.appendSlice(gpa, &.{ line[0], '\n' }),
                }
            }
            if (case % 5 == 0 and side.items.len != 0) _ = side.pop();
        }
        for ([_]ConflictStyle{ .merge, .diff3, .zdiff3 }) |style| {
            for ([_]textdiff.Algorithm{ .myers, .histogram }) |algorithm| {
                const options: BlobOptions = .{ .conflict_style = style, .algorithm = algorithm };
                const expected = try gitMergeFile(gpa, io, &repo, texts[0].items, texts[1].items, texts[2].items, options);
                defer gpa.free(expected);
                var got = try blobs(gpa, texts[0].items, texts[1].items, texts[2].items, options);
                defer got.deinit();
                std.testing.expectEqualStrings(expected, got.bytes) catch |err| {
                    std.debug.print("case {d}, {s}, {s}\n", .{ case, @tagName(style), @tagName(algorithm) });
                    return err;
                };
            }
        }
    }
}

test "labels, marker size and a favoured side are written as git merge-file writes them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const ancestor = "one\nbase\nend\nkeep\nbase two\n";
    const ours = "one\nours\nend\nkeep\nours two\n";
    const theirs = "one\ntheirs\nend\nkeep\ntheirs two\n";
    const labels: Labels = .{ .ours = "HEAD", .base = "parent of 1234567 (a subject)", .theirs = "1234567 (a subject)" };
    for ([_]BlobOptions{
        .{ .labels = labels, .conflict_style = .diff3 },
        .{ .labels = labels, .marker_size = 10 },
        .{ .labels = labels, .favor = .ours },
        .{ .labels = labels, .favor = .theirs },
        .{ .labels = labels, .favor = .union_ },
    }) |options| {
        const expected = try gitMergeFile(gpa, io, &repo, ancestor, ours, theirs, options);
        defer gpa.free(expected);
        var got = try blobs(gpa, ancestor, ours, theirs, options);
        defer got.deinit();
        try std.testing.expectEqualStrings(expected, got.bytes);
        try std.testing.expectEqual(options.favor == .none, !got.isClean());
    }
}

test "markers take a carriage return where both sides end their lines with one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const ancestor = "a\r\nb\r\nc\r\n";
    const ours = "a\r\nB\r\nc\r\n";
    const theirs = "a\r\nX\r\nc\r\n";
    for ([_]ConflictStyle{ .merge, .diff3, .zdiff3 }) |style| {
        const expected = try gitMergeFile(gpa, io, &repo, ancestor, ours, theirs, .{ .conflict_style = style });
        defer gpa.free(expected);
        var got = try blobs(gpa, ancestor, ours, theirs, .{ .conflict_style = style });
        defer got.deinit();
        try std.testing.expectEqualStrings(expected, got.bytes);
        try std.testing.expect(std.mem.indexOf(u8, got.bytes, "=======\r\n") != null);
    }
}

test "the content-merging tree merge writes the tree and the stages git merge-tree does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // `merge-tree --write-tree` is 2.38's.
    try testgit.requireGitVersion(gpa, io, 2, 38);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "conflict", "a\nb\nc\n");
    try repo.writeFile(io, "clean", "1\n2\n3\n4\n5\n");
    try repo.writeFile(io, "mode", "m\n");
    try repo.writeFile(io, "gone-mine", "x\n");
    try repo.writeFile(io, "both-gone", "y\n");
    try repo.writeFile(io, "binary", "a\x00b\n");
    try repo.writeFile(io, "was-file", "f\n");
    try repo.writeFile(io, "was-dir/inside", "i\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    try repo.exec(io, &.{ "branch", "theirs" });

    try repo.writeFile(io, "conflict", "a\nOURS\nc\n");
    try repo.writeFile(io, "clean", "one\n2\n3\n4\n5\n");
    try repo.writeFile(io, "added", "ours\nshared\n");
    try repo.writeFile(io, "added-same", "same\n");
    try repo.writeFile(io, "gone-mine", "x changed\n");
    try repo.writeFile(io, "binary", "a\x00ours\n");
    try repo.dir.deleteFile(io, "both-gone");
    try repo.dir.deleteFile(io, "was-file");
    try repo.writeFile(io, "was-file/now-dir", "d\n");
    try repo.dir.deleteTree(io, "was-dir");
    try repo.writeFile(io, "was-dir", "now a file\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "mode" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "ours" });

    // The executable bit went into the index and not onto the disk, which is
    // the one way to put it in a tree on every platform; checkout is told to
    // mind that no more than the commit did.
    try repo.exec(io, &.{ "checkout", "-q", "-f", "theirs" });
    try repo.writeFile(io, "conflict", "a\nTHEIRS\nc\n");
    try repo.writeFile(io, "clean", "1\n2\n3\n4\nfive\n");
    try repo.writeFile(io, "mode", "m\nmore\n");
    try repo.writeFile(io, "added", "theirs\nshared\n");
    try repo.writeFile(io, "added-same", "same\n");
    try repo.dir.deleteFile(io, "gone-mine");
    try repo.dir.deleteFile(io, "both-gone");
    try repo.writeFile(io, "binary", "a\x00theirs\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "theirs" });

    // `merge-tree` exits 1 on a conflicted merge; its output is what is
    // compared.
    const git_stdout = try repo.runInput(io, &.{ "merge-tree", "--write-tree", "main", "theirs" }, "");
    defer gpa.free(git_stdout);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const tree_of = struct {
        fn get(r: *testgit.Repo, g: Allocator, i: Io, rev: []const u8) !Oid {
            const text = try r.line(i, &.{ "rev-parse", rev });
            defer g.free(text);
            return Oid.parse(.sha1, text);
        }
    }.get;
    var result = try treesWithOptions(
        gpa,
        io,
        &db,
        try tree_of(&repo, gpa, io, "main~1^{tree}"),
        try tree_of(&repo, gpa, io, "main^{tree}"),
        try tree_of(&repo, gpa, io, "theirs^{tree}"),
        .{ .content_merge = true, .blob = .{ .labels = .{ .ours = "main", .theirs = "theirs" }, .algorithm = .histogram } },
    );
    defer result.deinit();

    // The first line is the tree, then one line per conflicted stage.
    var lines = std.mem.splitScalar(u8, git_stdout, '\n');
    const tree_line = lines.next().?;
    const merged_tree = try conflictedTree(gpa, io, &db, &result);
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(tree_line, merged_tree.hex(&hex));

    var expected_stages: std.ArrayList(u8) = .empty;
    defer expected_stages.deinit(gpa);
    while (lines.next()) |line| {
        if (line.len == 0) break;
        try expected_stages.appendSlice(gpa, line);
        try expected_stages.append(gpa, '\n');
    }
    var got_stages: std.ArrayList(u8) = .empty;
    defer got_stages.deinit(gpa);
    for (result.index.entries.items) |entry| {
        if (entry.stage == 0) continue;
        var mode_buf: [6]u8 = undefined;
        const line = try std.fmt.allocPrint(gpa, "{s} {s} {d}\t{s}\n", .{
            entry.mode.text(&mode_buf), entry.oid.hex(&hex), entry.stage, entry.path,
        });
        defer gpa.free(line);
        try got_stages.appendSlice(gpa, line);
    }
    try std.testing.expectEqualStrings(expected_stages.items, got_stages.items);
    try std.testing.expectEqual(@as(usize, 4), result.conflicts.len);
}

test "fuzz: three-way blob merges never crash and an unchanged theirs preserves ours" {
    try std.testing.fuzz({}, fuzzBlobs, .{});
}

fn fuzzBlobs(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var ancestor_buf: [192]u8 = undefined;
    var ours_buf: [192]u8 = undefined;
    var theirs_buf: [192]u8 = undefined;
    const ancestor = ancestor_buf[0..smith.slice(&ancestor_buf)];
    const ours = ours_buf[0..smith.slice(&ours_buf)];
    const theirs = theirs_buf[0..smith.slice(&theirs_buf)];

    if (blobs(gpa, ancestor, ours, theirs, .{})) |result_value| {
        var result = result_value;
        result.deinit();
    } else |err| switch (err) {
        error.BinaryBlob => {},
        else => |other| return other,
    }

    var unchanged = try blobs(gpa, ancestor, ours, ancestor, .{});
    defer unchanged.deinit();
    try std.testing.expect(unchanged.isClean());
    try std.testing.expectEqualSlices(u8, ours, unchanged.bytes);
}
