//! The three-way merge of one file's contents, xdiff's decision for
//! decision.
//!
//! The conflict markers a merge leaves in a file are text a person reads
//! and edits and a tool compares: independent edits compose, overlapping
//! edits get markers, and a conflict is narrowed to the lines the two sides
//! really disagree on exactly where git narrows it -- at the level git uses,
//! refined, with conflicts close together joined and `zdiff3`'s shared ends
//! moved out. This is the merge `git merge-file` makes, and the one git's
//! tree merge makes of each file both sides changed.

const std = @import("std");
const Allocator = std.mem.Allocator;

const textdiff = @import("textdiff.zig");

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

/// Where a refusal writes the path that caused it, so a caller can say which
/// file stood in the way without anything being allocated.
pub const Blocked = struct {
    buffer: [4096]u8 = undefined,
    len: usize = 0,

    /// The path. Empty when nothing was refused.
    pub fn path(b: *const Blocked) []const u8 {
        return b.buffer[0..b.len];
    }

    /// Record `text` as the path that caused a refusal.
    pub fn set(b: *Blocked, text: []const u8) void {
        b.len = @min(text.len, b.buffer.len);
        @memcpy(b.buffer[0..b.len], text[0..b.len]);
    }
};
