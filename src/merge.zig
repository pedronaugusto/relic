//! Three-way merges of blob contents and trees.
//!
//! Blob merging uses the same line-oriented shape as git's default xdiff
//! merge: independent edits compose and overlapping edits receive conflict
//! markers. Tree merging is stage-only by default, or may be asked to use the
//! blob merge to resolve regular-file conflicts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const textdiff = @import("textdiff.zig");

const Oid = hash.Oid;

/// Errors from a merge.
pub const Error = error{
    /// A tree entry pointed at something that is not a tree.
    NotATree,
    /// The trees nest deeper than the walk will go.
    TreeTooDeep,
} || Allocator.Error || odb_mod.Error || object.TreeParseError ||
    object.Tree.Builder.AddError || index_mod.ReadError;

/// A content merge refuses data git classifies as binary.
pub const BlobError = error{BinaryBlob} || Allocator.Error;

/// Which conflict body to write.
pub const ConflictStyle = enum {
    /// Ours and theirs, separated by `=======`.
    merge,
    /// Also show the common ancestor after `||||||| base`.
    diff3,
};

/// Options for a blob merge.
pub const BlobOptions = struct {
    conflict_style: ConflictStyle = .merge,
};

/// The owned bytes produced by a blob merge.
pub const BlobResult = struct {
    gpa: Allocator,
    bytes: []u8,
    status: Status,

    pub const Status = enum { clean, conflicted };

    pub fn isClean(result: *const BlobResult) bool {
        return result.status == .clean;
    }

    pub fn deinit(result: *BlobResult) void {
        result.gpa.free(result.bytes);
        result.* = undefined;
    }
};

/// Merge `ours` and `theirs` against `ancestor`.
///
/// The labels and seven-byte markers deliberately match `git merge-file`.
/// Binary data is refused when the three inputs need an actual merge; an
/// unchanged side still takes the other side byte for byte.
pub fn blobs(
    gpa: Allocator,
    ancestor: []const u8,
    ours: []const u8,
    theirs: []const u8,
    options: BlobOptions,
) BlobError!BlobResult {
    if (std.mem.eql(u8, ours, theirs)) return ownedBlob(gpa, ours, .clean);
    if (std.mem.eql(u8, ours, ancestor)) return ownedBlob(gpa, theirs, .clean);
    if (std.mem.eql(u8, theirs, ancestor)) return ownedBlob(gpa, ours, .clean);
    if (textdiff.isBinary(ancestor) or textdiff.isBinary(ours) or textdiff.isBinary(theirs)) {
        return error.BinaryBlob;
    }

    const base_lines = try textdiff.splitLines(gpa, ancestor);
    defer gpa.free(base_lines);
    const our_lines = try textdiff.splitLines(gpa, ours);
    defer gpa.free(our_lines);
    const their_lines = try textdiff.splitLines(gpa, theirs);
    defer gpa.free(their_lines);
    const our_changes = try textdiff.diffLines(gpa, base_lines, our_lines, .{});
    defer gpa.free(our_changes);
    const their_changes = try textdiff.diffLines(gpa, base_lines, their_lines, .{});
    defer gpa.free(their_changes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var status: BlobResult.Status = .clean;
    var base_at: usize = 0;
    var oi: usize = 0;
    var ti: usize = 0;

    while (oi < our_changes.len or ti < their_changes.len) {
        if (oi == our_changes.len) {
            try appendSingle(gpa, &out, base_lines, their_lines, their_changes[ti], &base_at);
            ti += 1;
            continue;
        }
        if (ti == their_changes.len) {
            try appendSingle(gpa, &out, base_lines, our_lines, our_changes[oi], &base_at);
            oi += 1;
            continue;
        }

        const oc = our_changes[oi];
        const tc = their_changes[ti];
        if (!changesOverlap(oc, tc)) {
            if (changeBefore(oc, tc)) {
                try appendSingle(gpa, &out, base_lines, our_lines, oc, &base_at);
                oi += 1;
            } else {
                try appendSingle(gpa, &out, base_lines, their_lines, tc, &base_at);
                ti += 1;
            }
            continue;
        }

        var oe = oi + 1;
        var te = ti + 1;
        var grew = true;
        while (grew) {
            grew = false;
            while (oe < our_changes.len and overlapsAny(our_changes[oe], their_changes[ti..te])) {
                oe += 1;
                grew = true;
            }
            while (te < their_changes.len and overlapsAny(their_changes[te], our_changes[oi..oe])) {
                te += 1;
                grew = true;
            }
        }

        const start = @min(our_changes[oi].old_start, their_changes[ti].old_start);
        var end = start;
        for (our_changes[oi..oe]) |c| end = @max(end, c.old_start + c.old_count);
        for (their_changes[ti..te]) |c| end = @max(end, c.old_start + c.old_count);
        try appendLines(gpa, &out, base_lines[base_at..start]);

        const our_region = try renderRegion(gpa, base_lines, our_lines, our_changes[oi..oe], start, end);
        defer gpa.free(our_region);
        const their_region = try renderRegion(gpa, base_lines, their_lines, their_changes[ti..te], start, end);
        defer gpa.free(their_region);

        if (std.mem.eql(u8, our_region, their_region)) {
            try out.appendSlice(gpa, our_region);
        } else {
            status = .conflicted;
            const refined = if (options.conflict_style == .merge)
                try refineConflict(gpa, our_region, their_region)
            else
                Refined{};
            try out.appendSlice(gpa, our_region[0..refined.prefix]);
            try endMarkerLine(gpa, &out);
            try out.appendSlice(gpa, "<<<<<<< ours\n");
            try out.appendSlice(gpa, our_region[refined.prefix .. our_region.len - refined.our_suffix]);
            try endMarkerLine(gpa, &out);
            if (options.conflict_style == .diff3) {
                try out.appendSlice(gpa, "||||||| base\n");
                try appendLines(gpa, &out, base_lines[start..end]);
                try endMarkerLine(gpa, &out);
            }
            try out.appendSlice(gpa, "=======\n");
            try out.appendSlice(gpa, their_region[refined.prefix .. their_region.len - refined.their_suffix]);
            try endMarkerLine(gpa, &out);
            try out.appendSlice(gpa, ">>>>>>> theirs\n");
            try out.appendSlice(gpa, our_region[our_region.len - refined.our_suffix ..]);
        }
        base_at = end;
        oi = oe;
        ti = te;
    }
    try appendLines(gpa, &out, base_lines[base_at..]);
    return .{ .gpa = gpa, .bytes = try out.toOwnedSlice(gpa), .status = status };
}

const Refined = struct {
    prefix: usize = 0,
    our_suffix: usize = 0,
    their_suffix: usize = 0,
};

fn refineConflict(gpa: Allocator, ours: []const u8, theirs: []const u8) Allocator.Error!Refined {
    const our_lines = try textdiff.splitLines(gpa, ours);
    defer gpa.free(our_lines);
    const their_lines = try textdiff.splitLines(gpa, theirs);
    defer gpa.free(their_lines);

    var first: usize = 0;
    var prefix: usize = 0;
    while (first < our_lines.len and first < their_lines.len and
        std.mem.eql(u8, our_lines[first], their_lines[first])) : (first += 1)
    {
        prefix += our_lines[first].len;
    }

    var our_last = our_lines.len;
    var their_last = their_lines.len;
    var our_suffix: usize = 0;
    var their_suffix: usize = 0;
    while (our_last > first and their_last > first and
        std.mem.eql(u8, our_lines[our_last - 1], their_lines[their_last - 1]))
    {
        our_last -= 1;
        their_last -= 1;
        our_suffix += our_lines[our_last].len;
        their_suffix += their_lines[their_last].len;
    }
    return .{ .prefix = prefix, .our_suffix = our_suffix, .their_suffix = their_suffix };
}

fn endMarkerLine(gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
}

fn ownedBlob(gpa: Allocator, bytes: []const u8, status: BlobResult.Status) Allocator.Error!BlobResult {
    return .{ .gpa = gpa, .bytes = try gpa.dupe(u8, bytes), .status = status };
}

fn changeBefore(a: textdiff.Change, b: textdiff.Change) bool {
    const ae = a.old_start + a.old_count;
    const be = b.old_start + b.old_count;
    if (ae < b.old_start) return true;
    if (be < a.old_start) return false;
    return a.old_start < b.old_start;
}

fn changesOverlap(a: textdiff.Change, b: textdiff.Change) bool {
    return a.old_start <= b.old_start + b.old_count and b.old_start <= a.old_start + a.old_count;
}

fn overlapsAny(change: textdiff.Change, others: []const textdiff.Change) bool {
    for (others) |other| if (changesOverlap(change, other)) return true;
    return false;
}

fn appendLines(gpa: Allocator, out: *std.ArrayList(u8), lines: []const textdiff.Line) Allocator.Error!void {
    for (lines) |line| try out.appendSlice(gpa, line);
}

fn appendSingle(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    base: []const textdiff.Line,
    side: []const textdiff.Line,
    change: textdiff.Change,
    base_at: *usize,
) Allocator.Error!void {
    try appendLines(gpa, out, base[base_at.*..change.old_start]);
    try appendLines(gpa, out, side[change.new_start .. change.new_start + change.new_count]);
    base_at.* = change.old_start + change.old_count;
}

fn renderRegion(
    gpa: Allocator,
    base: []const textdiff.Line,
    side: []const textdiff.Line,
    changes: []const textdiff.Change,
    start: usize,
    end: usize,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at = start;
    for (changes) |change| {
        try appendLines(gpa, &out, base[at..change.old_start]);
        try appendLines(gpa, &out, side[change.new_start .. change.new_start + change.new_count]);
        at = change.old_start + change.old_count;
    }
    try appendLines(gpa, &out, base[at..end]);
    return out.toOwnedSlice(gpa);
}

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
    /// Conflict-marked content for a text conflict, or the surviving content
    /// of a modify/delete conflict, when content merging was requested.
    /// Owned by the result.
    merged: ?[]const u8 = null,

    /// Why the two sides could not be reconciled.
    pub const Kind = enum {
        /// Both sides changed the content, or the mode, differently.
        both_modified,
        /// One side changed it and the other deleted it.
        modify_delete,
        /// Both sides added it, with different content.
        both_added,
        /// One side has a file where the other has a directory.
        directory_file,
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
    /// Try the blob merge for regular files that would otherwise occupy
    /// index stages 1, 2 and 3.
    content_merge: bool = false,
    blob: BlobOptions = .{},
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
                .kind = .directory_file,
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
                .kind = .directory_file,
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
        var merged: ?[]const u8 = null;
        if (options.content_merge and kind == .both_modified) content: {
            const merged_mode = mergeMode(b.?, o.?, t.?) orelse break :content;
            const base_blob = try db.read(io, b.?.oid);
            defer db.gpa.free(base_blob.bytes);
            const our_blob = try db.read(io, o.?.oid);
            defer db.gpa.free(our_blob.bytes);
            const their_blob = try db.read(io, t.?.oid);
            defer db.gpa.free(their_blob.bytes);
            if (base_blob.type != .blob or our_blob.type != .blob or their_blob.type != .blob) break :content;

            var content_result = blobs(gpa, base_blob.bytes, our_blob.bytes, their_blob.bytes, options.blob) catch |err| switch (err) {
                error.BinaryBlob => break :content,
                else => |other| return other,
            };
            defer content_result.deinit();
            if (content_result.isClean()) {
                const oid = try db.write(io, .blob, content_result.bytes);
                try stage(&index, path, .{ .mode = merged_mode, .oid = oid }, 0);
                continue;
            }
            merged = try arena.dupe(u8, content_result.bytes);
        } else if (options.content_merge and kind == .modify_delete) {
            const survivor = o orelse t.?;
            if (survivor.mode == .file or survivor.mode == .exec) {
                const found = try db.read(io, survivor.oid);
                defer db.gpa.free(found.bytes);
                if (found.type == .blob) merged = try arena.dupe(u8, found.bytes);
            }
        }
        try conflicts.append(arena, .{
            .path = path,
            .base = b,
            .ours = o,
            .theirs = t,
            .kind = kind,
            .merged = merged,
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

fn mergeMode(base: Side, ours: Side, theirs: Side) ?object.Mode {
    if ((base.mode != .file and base.mode != .exec) or
        (ours.mode != .file and ours.mode != .exec) or
        (theirs.mode != .file and theirs.mode != .exec)) return null;
    if (ours.mode == theirs.mode) return ours.mode;
    if (ours.mode == base.mode) return theirs.mode;
    if (theirs.mode == base.mode) return ours.mode;
    return null;
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
