//! Three-way merges of blob contents and trees.
//!
//! The blob merge is xdiff's, decision for decision, because the conflict
//! markers a merge leaves in a file are text a person reads and edits and a
//! tool compares: independent edits compose, overlapping edits get markers,
//! and a conflict is narrowed to the lines the two sides really disagree on
//! exactly where git narrows it. The tree merge is stage-only by default, or
//! follows the per-path rules of git's merge machinery when content merging
//! is asked for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const textdiff = @import("textdiff.zig");
const attributes = @import("attributes.zig");

const Oid = hash.Oid;

/// Errors from a merge.
pub const Error = error{
    /// A tree entry pointed at something that is not a tree.
    NotATree,
    /// The trees nest deeper than the walk will go.
    TreeTooDeep,
    /// A path's `merge` attribute names a driver `merge.<name>.driver`
    /// configures, which is a program this merge does not run.
    UnsupportedMergeDriver,
} || attributes.Error || Allocator.Error || odb_mod.Error || object.TreeParseError ||
    object.Tree.Builder.AddError || index_mod.ReadError;

/// A content merge refuses data git classifies as binary.
pub const BlobError = error{BinaryBlob} || Allocator.Error;

/// Which conflict body to write, which is what `merge.conflictStyle` names.
pub const ConflictStyle = enum {
    /// Ours and theirs, separated by `=======`.
    merge,
    /// Also show the common ancestor after `||||||| base`.
    diff3,
    /// `diff3`, with the lines both sides agree on at either end of a
    /// conflict moved out of it.
    zdiff3,

    /// The style a `merge.conflictStyle` value names, or `null` for one
    /// this release does not know.
    pub fn parse(text: []const u8) ?ConflictStyle {
        if (std.mem.eql(u8, text, "merge")) return .merge;
        if (std.mem.eql(u8, text, "diff3")) return .diff3;
        if (std.mem.eql(u8, text, "zdiff3")) return .zdiff3;
        return null;
    }
};

/// Which side a conflict resolves to without markers: `-X ours`, `-X
/// theirs`, or `merge=union`, which keeps both.
pub const Favor = enum { none, ours, theirs, union_ };

/// The words after the markers.
pub const Labels = struct {
    ours: []const u8 = "ours",
    base: []const u8 = "base",
    theirs: []const u8 = "theirs",
};

/// Options for a blob merge.
pub const BlobOptions = struct {
    conflict_style: ConflictStyle = .merge,
    labels: Labels = .{},
    /// How many characters each marker is: git's `conflict-marker-size`
    /// attribute.
    marker_size: u8 = 7,
    favor: Favor = .none,
    /// The line diff the two sides are taken with. `git merge-file`
    /// uses Myers; the merge machinery behind `merge`, `cherry-pick`,
    /// `revert` and `rebase` uses histogram.
    algorithm: textdiff.Algorithm = .myers,
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
/// This is xdiff's merge at the level git uses, decision for decision: the
/// two sides are diffed against the ancestor, changes that touch or overlap
/// become one conflict, and a conflict whose two sides share lines is diffed
/// again and split around them, with conflicts fewer than four lines apart
/// joined back together. `diff3` shows the ancestor and so refines nothing;
/// `zdiff3` moves only the shared lines at either end out. Binary data is
/// refused when the three inputs need an actual merge; an unchanged side
/// still takes the other side byte for byte.
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
    // The merge machinery diffs with no indentation heuristic: the slide it
    // wants is the plain one.
    const diff_options: textdiff.Options = .{ .algorithm = options.algorithm, .indent_heuristic = false };
    const our_changes = try textdiff.diffLines(gpa, base_lines, our_lines, diff_options);
    defer gpa.free(our_changes);
    const their_changes = try textdiff.diffLines(gpa, base_lines, their_lines, diff_options);
    defer gpa.free(their_changes);

    if (our_changes.len == 0) return ownedBlob(gpa, theirs, .clean);
    if (their_changes.len == 0) return ownedBlob(gpa, ours, .clean);

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(gpa);
    const lines: Sides = .{ .base = base_lines, .ours = our_lines, .theirs = their_lines };
    try collectHunks(gpa, &hunks, lines, our_changes, their_changes);

    switch (options.conflict_style) {
        .zdiff3 => trimConflicts(hunks.items, our_lines, their_lines),
        .merge => {
            try refineConflicts(gpa, &hunks, our_lines, their_lines, diff_options);
            joinCloseConflicts(&hunks);
        },
        .diff3 => {},
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var conflicts: usize = 0;
    var at: isize = 0;
    for (hunks.items) |*h| {
        if (options.favor != .none and h.mode == .conflict) h.mode = switch (options.favor) {
            .ours => .ours,
            .theirs => .theirs,
            .union_ => .both,
            .none => unreachable,
        };
        switch (h.mode) {
            .conflict => {
                conflicts += 1;
                try writeConflict(gpa, &out, lines, at, h.*, options);
            },
            .ours, .theirs, .both => {
                try copyLines(gpa, &out, span(our_lines, at, h.at1 - at), false, false);
                if (h.mode != .theirs) {
                    try copyLines(gpa, &out, span(our_lines, h.at1, h.len1), crNeeded(lines, h.*), h.mode == .both);
                }
                if (h.mode != .ours) {
                    try copyLines(gpa, &out, span(their_lines, h.at2, h.len2), false, false);
                }
            },
            .identical => continue,
        }
        at = h.at1 + h.len1;
    }
    try copyLines(gpa, &out, our_lines[@intCast(at)..], false, false);
    return .{
        .gpa = gpa,
        .bytes = try out.toOwnedSlice(gpa),
        .status = if (conflicts == 0) .clean else .conflicted,
    };
}

/// One region of the merge: where each of the three texts has it, and which
/// of them it is taken from. `0` is the ancestor, `1` ours and `2` theirs,
/// and each pair is a first line and a count of lines.
///
/// Signed, as xdiff's are: a region appended only to be joined into the one
/// before it can start before the first line.
const Hunk = struct {
    mode: Mode,
    at0: isize,
    len0: isize,
    at1: isize,
    len1: isize,
    at2: isize,
    len2: isize,

    fn make(mode: Mode, at0: isize, len0: isize, at1: isize, len1: isize, at2: isize, len2: isize) Hunk {
        return .{ .mode = mode, .at0 = at0, .len0 = len0, .at1 = at1, .len1 = len1, .at2 = at2, .len2 = len2 };
    }

    const Mode = enum {
        conflict,
        /// Only our side changed it.
        ours,
        /// Only their side changed it.
        theirs,
        /// Both, kept one after the other: what a union merge asks for.
        both,
        /// Both sides made the same change, found when refining.
        identical,
    };
};

const Sides = struct {
    base: []const textdiff.Line,
    ours: []const textdiff.Line,
    theirs: []const textdiff.Line,
};

/// `xdl_append_merge`: a region that touches the previous one joins it, and
/// the joined region is a conflict unless both came from the same side.
fn appendHunk(gpa: Allocator, hunks: *std.ArrayList(Hunk), h: Hunk) Allocator.Error!void {
    if (hunks.items.len != 0) {
        const m = &hunks.items[hunks.items.len - 1];
        if (h.at1 <= m.at1 + m.len1 or h.at2 <= m.at2 + m.len2) {
            if (h.mode != m.mode) m.mode = .conflict;
            m.len0 = h.at0 + h.len0 - m.at0;
            m.len1 = h.at1 + h.len1 - m.at1;
            m.len2 = h.at2 + h.len2 - m.at2;
            return;
        }
    }
    try hunks.append(gpa, h);
}

/// Walk the two edit scripts together, as `xdl_do_merge` does. Changes
/// that touch or overlap become one conflict; the same change made on both
/// sides is no change at all.
fn collectHunks(
    gpa: Allocator,
    hunks: *std.ArrayList(Hunk),
    lines: Sides,
    ours: []const textdiff.Change,
    theirs: []const textdiff.Change,
) Allocator.Error!void {
    const base_len: isize = @intCast(lines.base.len);
    const our_len: isize = @intCast(lines.ours.len);
    const their_len: isize = @intCast(lines.theirs.len);
    var oi: usize = 0;
    var ti: usize = 0;
    while (oi < ours.len and ti < theirs.len) {
        const x1 = Script.of(ours[oi]);
        const x2 = Script.of(theirs[ti]);
        if (x1.old_at + x1.old_len < x2.old_at) {
            try appendHunk(gpa, hunks, .make(.ours, x1.old_at, x1.old_len, x1.new_at, x1.new_len, x2.new_at - x2.old_at + x1.old_at, x1.old_len));
            oi += 1;
            continue;
        }
        if (x2.old_at + x2.old_len < x1.old_at) {
            try appendHunk(gpa, hunks, .make(.theirs, x2.old_at, x2.old_len, x1.new_at - x1.old_at + x2.old_at, x2.old_len, x2.new_at, x2.new_len));
            ti += 1;
            continue;
        }
        const identical = x1.old_at == x2.old_at and x1.old_len == x2.old_len and x1.new_len == x2.new_len and
            sameLines(span(lines.ours, x1.new_at, x1.new_len), span(lines.theirs, x2.new_at, x2.new_len));
        if (!identical) {
            const off = x1.old_at - x2.old_at;
            const ffo = off + x1.old_len - x2.old_len;
            var at0 = x1.old_at;
            var at1 = x1.new_at;
            var at2 = x2.new_at;
            if (off > 0) {
                at0 -= off;
                at1 -= off;
            } else at2 += off;
            var len0 = x1.old_at + x1.old_len - at0;
            var len1 = x1.new_at + x1.new_len - at1;
            var len2 = x2.new_at + x2.new_len - at2;
            if (ffo < 0) {
                len0 -= ffo;
                len1 -= ffo;
            } else len2 += ffo;
            try appendHunk(gpa, hunks, .make(.conflict, at0, len0, at1, len1, at2, len2));
        }
        const end1 = x1.old_at + x1.old_len;
        const end2 = x2.old_at + x2.old_len;
        if (end1 >= end2) ti += 1;
        if (end2 >= end1) oi += 1;
    }
    while (oi < ours.len) : (oi += 1) {
        const x1 = Script.of(ours[oi]);
        try appendHunk(gpa, hunks, .make(.ours, x1.old_at, x1.old_len, x1.new_at, x1.new_len, x1.old_at + their_len - base_len, x1.old_len));
    }
    while (ti < theirs.len) : (ti += 1) {
        const x2 = Script.of(theirs[ti]);
        try appendHunk(gpa, hunks, .make(.theirs, x2.old_at, x2.old_len, x2.old_at + our_len - base_len, x2.old_len, x2.new_at, x2.new_len));
    }
}

/// One change of an edit script in xdiff's terms, signed, because the
/// offsets the walk computes pass through negative values on the way.
const Script = struct {
    old_at: isize,
    old_len: isize,
    new_at: isize,
    new_len: isize,

    fn of(c: textdiff.Change) Script {
        return .{
            .old_at = @intCast(c.old_start),
            .old_len = @intCast(c.old_count),
            .new_at = @intCast(c.new_start),
            .new_len = @intCast(c.new_count),
        };
    }
};

/// Lines `at .. at + len` of `lines`.
fn span(lines: []const textdiff.Line, at: isize, len: isize) []const textdiff.Line {
    return lines[@intCast(at)..][0..@intCast(len)];
}

fn sameLines(a: []const textdiff.Line, b: []const textdiff.Line) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// `xdl_refine_conflicts`: diff the two sides of each conflict against each
/// other and keep only the runs where they differ as conflicts. Nothing is
/// refined when one side is empty.
fn refineConflicts(
    gpa: Allocator,
    hunks: *std.ArrayList(Hunk),
    our_lines: []const textdiff.Line,
    their_lines: []const textdiff.Line,
    diff_options: textdiff.Options,
) Allocator.Error!void {
    var at: usize = 0;
    while (at < hunks.items.len) : (at += 1) {
        const m = hunks.items[at];
        if (m.mode != .conflict or m.len1 == 0 or m.len2 == 0) continue;
        const changes = try textdiff.diffLines(
            gpa,
            span(our_lines, m.at1, m.len1),
            span(their_lines, m.at2, m.len2),
            diff_options,
        );
        defer gpa.free(changes);
        if (changes.len == 0) {
            hunks.items[at].mode = .identical;
            continue;
        }
        for (changes, 0..) |c, n| {
            const piece: Hunk = .{
                .mode = .conflict,
                .at0 = m.at0,
                .len0 = m.len0,
                .at1 = m.at1 + @as(isize, @intCast(c.old_start)),
                .len1 = @intCast(c.old_count),
                .at2 = m.at2 + @as(isize, @intCast(c.new_start)),
                .len2 = @intCast(c.new_count),
            };
            if (n == 0) {
                hunks.items[at] = piece;
            } else {
                at += 1;
                try hunks.insert(gpa, at, piece);
            }
        }
    }
}

/// `xdl_simplify_non_conflicts`: two conflicts with three lines or fewer
/// between them read more easily as one.
fn joinCloseConflicts(hunks: *std.ArrayList(Hunk)) void {
    var at: usize = 0;
    while (at + 1 < hunks.items.len) {
        const m = &hunks.items[at];
        const next = hunks.items[at + 1];
        const begin = m.at1 + m.len1;
        if (m.mode != .conflict or next.mode != .conflict or next.at1 - begin > 3) {
            at += 1;
            continue;
        }
        m.len1 = next.at1 + next.len1 - m.at1;
        m.len2 = next.at2 + next.len2 - m.at2;
        _ = hunks.orderedRemove(at + 1);
    }
}

/// `xdl_refine_zdiff3_conflicts`: move the lines both sides agree on at the
/// start and the end of each conflict out of it.
fn trimConflicts(hunks: []Hunk, our_lines: []const textdiff.Line, their_lines: []const textdiff.Line) void {
    for (hunks) |*m| {
        if (m.mode != .conflict) continue;
        while (m.len1 != 0 and m.len2 != 0 and
            std.mem.eql(u8, our_lines[@intCast(m.at1)], their_lines[@intCast(m.at2)]))
        {
            m.len1 -= 1;
            m.len2 -= 1;
            m.at1 += 1;
            m.at2 += 1;
        }
        while (m.len1 != 0 and m.len2 != 0 and
            std.mem.eql(u8, our_lines[@intCast(m.at1 + m.len1 - 1)], their_lines[@intCast(m.at2 + m.len2 - 1)]))
        {
            m.len1 -= 1;
            m.len2 -= 1;
        }
    }
}

/// Append lines; with `add_newline`, end the last one with a newline if it
/// has none, as a carriage return and a newline under `crlf`.
fn copyLines(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    lines: []const textdiff.Line,
    crlf: bool,
    add_newline: bool,
) Allocator.Error!void {
    if (lines.len == 0) return;
    for (lines) |line| try out.appendSlice(gpa, line);
    if (add_newline) {
        const last = lines[lines.len - 1];
        if (last.len == 0 or last[last.len - 1] != '\n') {
            if (crlf) try out.append(gpa, '\r');
            try out.append(gpa, '\n');
        }
    }
}

/// `is_eol_crlf`: whether line `i` ends in a carriage return and a newline,
/// looking at the line before when the last has no newline at all. `null`
/// when there is nothing to tell by.
fn endsCrlf(lines: []const textdiff.Line, i: isize) ?bool {
    const n: isize = @intCast(lines.len);
    if (i < n - 1) return crlfLine(lines[@intCast(i)]);
    if (n == 0) return null;
    const line = lines[@intCast(i)];
    if (line.len != 0 and line[line.len - 1] == '\n') return crlfLine(line);
    if (i == 0) return null;
    return crlfLine(lines[@intCast(i - 1)]);
}

fn crlfLine(line: []const u8) bool {
    return line.len > 1 and line[line.len - 2] == '\r';
}

/// `is_cr_needed`: markers end in a carriage return when both sides' lines
/// before the conflict, and the ancestor's first line, do.
fn crNeeded(lines: Sides, h: Hunk) bool {
    var needs = endsCrlf(lines.ours, if (h.at1 > 0) h.at1 - 1 else 0);
    if (needs != false) needs = endsCrlf(lines.theirs, if (h.at2 > 0) h.at2 - 1 else 0);
    if (needs != false) needs = endsCrlf(lines.base, 0);
    return needs orelse false;
}

fn writeMarker(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    c: u8,
    size: u8,
    label: []const u8,
    crlf: bool,
) Allocator.Error!void {
    try out.appendNTimes(gpa, c, size);
    if (label.len != 0) {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, label);
    }
    if (crlf) try out.append(gpa, '\r');
    try out.append(gpa, '\n');
}

/// `fill_conflict_hunk`: the lines before the conflict, then the markers
/// around each side.
fn writeConflict(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    lines: Sides,
    at: isize,
    h: Hunk,
    options: BlobOptions,
) Allocator.Error!void {
    const crlf = crNeeded(lines, h);
    const size = if (options.marker_size == 0) 7 else options.marker_size;
    try copyLines(gpa, out, span(lines.ours, at, h.at1 - at), false, false);
    try writeMarker(gpa, out, '<', size, options.labels.ours, crlf);
    try copyLines(gpa, out, span(lines.ours, h.at1, h.len1), crlf, true);
    if (options.conflict_style != .merge) {
        try writeMarker(gpa, out, '|', size, options.labels.base, crlf);
        try copyLines(gpa, out, span(lines.base, h.at0, h.len0), crlf, true);
    }
    try writeMarker(gpa, out, '=', size, "", crlf);
    try copyLines(gpa, out, span(lines.theirs, h.at2, h.len2), crlf, true);
    try writeMarker(gpa, out, '>', size, options.labels.theirs, crlf);
}

fn ownedBlob(gpa: Allocator, bytes: []const u8, status: BlobResult.Status) Allocator.Error!BlobResult {
    return .{ .gpa = gpa, .bytes = try gpa.dupe(u8, bytes), .status = status };
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
    /// What git leaves in the working tree for the path, and records in
    /// `AUTO_MERGE`, when content merging was requested: the conflict-marked
    /// blob, which is written to the object database; the surviving side of
    /// a modify/delete; our side where nothing could be merged.
    result: ?Side = null,

    /// Why the two sides could not be reconciled.
    pub const Kind = enum {
        /// Both sides changed the content, or the mode, differently.
        both_modified,
        /// One side changed it and the other deleted it.
        modify_delete,
        /// Both sides added it, with different content.
        both_added,
        /// One side has a file where the other has a directory, and neither
        /// went away.
        directory_file,
        /// The two sides hold different kinds of thing at the path: a file
        /// and a symlink, or either and a submodule.
        distinct_types,
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
    /// Resolve what can be resolved the way git's merge machinery does:
    /// regular files are content-merged, a file added on both sides is
    /// merged against an empty ancestor, the executable bit is merged on its
    /// own, and a file that meets a directory the merge empties takes its
    /// place. Without it every path both sides changed differently is left
    /// at stages 1, 2 and 3.
    content_merge: bool = false,
    blob: BlobOptions = .{},
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
    if (options.content_merge) return ortMerge(gpa, io, db, base, ours, theirs, options);

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
//
// merge-ort's per-path rules, which are what `git merge`, `cherry-pick`,
// `revert` and `rebase` leave behind. A side that did not change a path
// takes the other side's version; the same change on both sides is taken
// once; two different changes to a regular file are content-merged, with an
// empty ancestor when the file is new on both sides or was something else
// before; the executable bit is merged on its own, so one side's mode change
// and the other's content change compose. A file meeting a directory is
// resolved when either of them goes away in the merge, and is otherwise a
// conflict of its own kind.
//=========================================================================

/// What the per-path rules decided for one path.
const Resolution = struct {
    result: ?Side,
    kind: ?Conflict.Kind = null,
    merged: ?[]const u8 = null,
};

fn ortMerge(
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
    var directories: std.StringHashMapUnmanaged(void) = .empty;
    inline for (.{ &base_entries, &our_entries, &their_entries }) |set| {
        var it = set.keyIterator();
        while (it.next()) |key| {
            const slot = try seen.getOrPut(arena, key.*);
            if (!slot.found_existing) try paths.append(arena, key.*);
            var at = key.len;
            while (std.mem.lastIndexOfScalar(u8, key.*[0..at], '/')) |slash| {
                const dir_slot = try directories.getOrPut(arena, key.*[0..slash]);
                if (dir_slot.found_existing) break;
                at = slash;
            }
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    const resolutions = try arena.alloc(Resolution, paths.items.len);
    var loaded_dirs: LoadedDirs = .empty;
    for (paths.items, resolutions) |path, *resolution| {
        resolution.* = try resolvePath(
            arena,
            io,
            db,
            path,
            base_entries.get(path),
            our_entries.get(path),
            their_entries.get(path),
            options,
            &loaded_dirs,
        );
    }

    // Which directories still hold something once every file is decided.
    var surviving: std.StringHashMapUnmanaged(void) = .empty;
    for (paths.items, resolutions) |path, resolution| {
        if (resolution.result == null) continue;
        var at = path.len;
        while (std.mem.lastIndexOfScalar(u8, path[0..at], '/')) |slash| {
            const slot = try surviving.getOrPut(arena, path[0..slash]);
            if (slot.found_existing) break;
            at = slash;
        }
    }

    var index: index_mod.Index = .initEmpty(gpa, db.kind);
    errdefer index.deinit();
    var conflicts: std.ArrayList(Conflict) = .empty;

    for (paths.items, resolutions) |path, *resolution| {
        const b = base_entries.get(path);
        const o = our_entries.get(path);
        const t = their_entries.get(path);
        // A file where some side has a directory keeps the path only if
        // the directory is empty once the merge is done; a file the merge
        // removes gives the path up to it.
        if (resolution.result != null and directories.contains(path) and surviving.contains(path)) {
            resolution.* = .{ .result = resolution.result, .kind = .directory_file };
            try conflicts.append(arena, .{
                .path = path,
                .base = b,
                .ours = o,
                .theirs = t,
                .kind = .directory_file,
                .result = resolution.result,
            });
            continue;
        }
        if (resolution.kind) |kind| {
            try conflicts.append(arena, .{
                .path = path,
                .base = b,
                .ours = o,
                .theirs = t,
                .kind = kind,
                .merged = resolution.merged,
                .result = resolution.result,
            });
            try stageAll(&index, path, b, o, t);
            continue;
        }
        if (resolution.result) |side| try stage(&index, path, side, 0);
    }

    return .{
        .gpa = gpa,
        .index = index,
        .arena = arena_instance.state,
        .conflicts = conflicts.items,
    };
}

/// Whether two modes are the same kind of thing: a regular file whatever its
/// executable bit, a symlink, or a submodule.
fn sameType(a: object.Mode, b: object.Mode) bool {
    const regular_a = a == .file or a == .exec;
    const regular_b = b == .file or b == .exec;
    if (regular_a or regular_b) return regular_a and regular_b;
    return a == b;
}

/// The directories whose `.gitattributes` a merge has read, so that each is
/// read once.
const LoadedDirs = std.StringHashMapUnmanaged(void);

fn resolvePath(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    path: []const u8,
    o: ?Side,
    a: ?Side,
    b: ?Side,
    options: TreeOptions,
    loaded_dirs: *LoadedDirs,
) Error!Resolution {
    if (sameSide(a, b)) return .{ .result = a };
    if (sameSide(o, a)) return .{ .result = b };
    if (sameSide(o, b)) return .{ .result = a };

    const ours = a orelse return .{ .result = b, .kind = .modify_delete, .merged = try survivor(arena, io, db, b.?) };
    const theirs = b orelse return .{ .result = a, .kind = .modify_delete, .merged = try survivor(arena, io, db, a.?) };
    if (!sameType(ours.mode, theirs.mode)) return .{ .result = ours, .kind = .distinct_types };

    const kind: Conflict.Kind = if (o == null) .both_added else .both_modified;
    var clean = true;

    // The executable bit merges on its own.
    var mode = theirs.mode;
    if (!(ours.mode == theirs.mode or (o != null and ours.mode == o.?.mode))) {
        mode = ours.mode;
        clean = o != null and theirs.mode == o.?.mode;
    }

    if (ours.oid.eql(theirs.oid) or (o != null and ours.oid.eql(o.?.oid))) {
        return .{ .result = .{ .mode = mode, .oid = theirs.oid }, .kind = if (clean) null else kind };
    }
    if (o != null and theirs.oid.eql(o.?.oid)) {
        return .{ .result = .{ .mode = mode, .oid = ours.oid }, .kind = if (clean) null else kind };
    }
    if (ours.mode == .symlink or ours.mode == .gitlink) {
        // Two different symlinks cannot be merged, and a submodule's
        // commits are merged in the submodule's own repository; either way
        // our side is what stays.
        return .{ .result = .{ .mode = mode, .oid = ours.oid }, .kind = kind };
    }

    var blob_options = options.blob;
    var binary = false;
    if (options.attributes) |attrs| {
        if (options.attributes_dir) |dir| {
            var depth: u32 = 0;
            var at: usize = 0;
            while (true) : (depth += 1) {
                const base = path[0..at];
                if (!loaded_dirs.contains(base)) {
                    try loaded_dirs.put(arena, try arena.dupe(u8, base), {});
                    try attrs.addDirectory(io, dir, base, depth);
                }
                const slash = std.mem.indexOfScalarPos(u8, path, if (at == 0) 0 else at + 1, '/') orelse break;
                at = slash;
            }
        }
        const applied = try attrs.lookup(arena, path, false);
        if (applied.value("conflict-marker-size")) |text| {
            if (std.fmt.parseInt(u8, text, 10)) |size| {
                if (size > 0) blob_options.marker_size = size;
            } else |_| {}
        }
        if (applied.get("merge")) |state| switch (state) {
            .unset => binary = true,
            .set, .unspecified => {},
            .value => |name| {
                for (options.configured_drivers) |configured| {
                    if (std.mem.eql(u8, configured, name)) return error.UnsupportedMergeDriver;
                }
                if (std.mem.eql(u8, name, "binary")) binary = true;
                if (std.mem.eql(u8, name, "union")) blob_options.favor = .union_;
            },
        };
    }

    // An ancestor of another kind is no ancestor: the merge is two-way.
    const ancestor: ?Side = if (o != null and sameType(o.?.mode, ours.mode)) o else null;
    const base_found: ?odb_mod.Odb.Read = if (ancestor) |side| try db.read(io, side.oid) else null;
    defer if (base_found) |found| db.gpa.free(found.bytes);
    const our_found = try db.read(io, ours.oid);
    defer db.gpa.free(our_found.bytes);
    const their_found = try db.read(io, theirs.oid);
    defer db.gpa.free(their_found.bytes);
    const base_bytes: []const u8 = if (base_found) |found| found.bytes else "";

    var merged_bytes: []const u8 = undefined;
    var content_clean = false;
    var owned: ?BlobResult = null;
    defer if (owned) |*r| r.deinit();
    if (binary) {
        merged_bytes = switch (blob_options.favor) {
            .theirs => their_found.bytes,
            else => our_found.bytes,
        };
        content_clean = blob_options.favor == .ours or blob_options.favor == .theirs;
    } else if (blobs(arena, base_bytes, our_found.bytes, their_found.bytes, blob_options)) |result| {
        owned = result;
        merged_bytes = result.bytes;
        content_clean = result.isClean();
    } else |err| switch (err) {
        error.BinaryBlob => {
            merged_bytes = switch (blob_options.favor) {
                .theirs => their_found.bytes,
                else => our_found.bytes,
            };
            content_clean = blob_options.favor == .ours or blob_options.favor == .theirs;
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
    const oid = try db.write(io, .blob, merged_bytes);
    clean = clean and content_clean;
    return .{
        .result = .{ .mode = mode, .oid = oid },
        .kind = if (clean) null else kind,
        .merged = if (clean) null else try arena.dupe(u8, merged_bytes),
    };
}

/// The bytes of the side a modify/delete conflict keeps, when it is a
/// regular file.
fn survivor(arena: Allocator, io: Io, db: *odb_mod.Odb, side: Side) Error!?[]const u8 {
    if (side.mode != .file and side.mode != .exec) return null;
    const found = try db.read(io, side.oid);
    defer db.gpa.free(found.bytes);
    if (found.type != .blob) return null;
    return try arena.dupe(u8, found.bytes);
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

/// The tree of what a content-merging merge leaves behind, conflicts and
/// all: every resolved path as it was resolved and every conflicted one as
/// the working tree gets it, markers included. This is the tree git records
/// as `AUTO_MERGE` and the one `git merge-tree --write-tree` prints; a
/// conflict with nothing to put there -- a file that met a directory -- is
/// left out.
pub fn conflictedTree(gpa: Allocator, io: Io, db: *odb_mod.Odb, result: *const Result) Error!Oid {
    var index: index_mod.Index = .initEmpty(gpa, db.kind);
    defer index.deinit();
    var entries: std.ArrayList(index_mod.Entry) = .empty;
    defer entries.deinit(gpa);
    for (result.index.entries.items) |entry| {
        if (entry.stage == 0) try entries.append(gpa, .{ .path = entry.path, .oid = entry.oid, .mode = entry.mode });
    }
    for (result.conflicts) |conflict| {
        if (conflict.kind == .directory_file) continue;
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
    var git_argv: std.ArrayList([]const u8) = .empty;
    defer git_argv.deinit(gpa);
    try git_argv.append(gpa, "git");
    try git_argv.appendSlice(gpa, repo.defaults);
    try git_argv.appendSlice(gpa, argv.items);
    const result = try std.process.run(gpa, io, .{ .argv = git_argv.items, .cwd = .{ .dir = repo.dir } });
    gpa.free(result.stderr);
    return result.stdout;
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

    repo.report_failures = false;
    const git_out = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "merge-tree", "--write-tree", "main", "theirs" },
        .cwd = .{ .dir = repo.dir },
    });
    defer gpa.free(git_out.stdout);
    defer gpa.free(git_out.stderr);

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
    var lines = std.mem.splitScalar(u8, git_out.stdout, '\n');
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
