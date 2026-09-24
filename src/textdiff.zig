//! The line diff: the edit script between two texts, and the hunks a unified
//! diff prints.
//!
//! Myers here has the shape git's xdiff gives it, because a diff that is
//! merely correct is not enough -- a patch has to land on the same lines the
//! reader's `git diff` shows. Four things in order: trim the common prefix
//! and suffix; run the greedy O(ND) search with the linear-space middle-snake
//! split; give up on proving the script minimal once the search has cost too
//! much, which git does deliberately and which changes its answer on large or
//! noisy input; then slide every run of changed lines to the place the
//! indentation heuristic likes best. A run of equal lines admits several
//! equally short scripts and the raw algorithm picks whichever its tie-breaks
//! reach first; the slide is what collapses that freedom to git's answer.
//!
//! The histogram algorithm is here too, with the shape git's xhistogram gives
//! it, because git's merge machinery diffs with it: where a conflict starts
//! and ends in a cherry-pick is decided by which run histogram anchors on.
//!
//! Patience is git's xpatience, line for line, because its answer is the
//! one `git diff --patience` prints: anchor on the lines that occur exactly
//! once on each side, keep the longest run of them that is in order on both,
//! recurse into the gaps, and hand a gap with no unique line in common to the
//! classic pipeline as if it were a pair of files of its own. That last step
//! is where the answers of a patience diff come from on repetitive input, so
//! it is the same trimming, pruning and Myers the plain algorithm runs.
//!
//! Nothing in this file opens a file or reads an object: it takes bytes and
//! gives back indices.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Which algorithm produces the edit script.
pub const Algorithm = enum { myers, histogram, patience };

/// One line of an input, as a slice of the original bytes including its
/// trailing newline when it had one.
pub const Line = []const u8;

/// Split `bytes` into lines. A final line with no newline is still a line.
/// The result is the caller's; the slices borrow `bytes`.
pub fn splitLines(gpa: Allocator, bytes: []const u8) Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);
    var at: usize = 0;
    while (at < bytes.len) {
        const end = if (std.mem.indexOfScalarPos(u8, bytes, at, '\n')) |nl| nl + 1 else bytes.len;
        try lines.append(gpa, bytes[at..end]);
        at = end;
    }
    return lines.toOwnedSlice(gpa);
}

/// One run of the edit script.
pub const Change = struct {
    /// Index of the first line taken from the old side.
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

/// How a diff is taken.
pub const Options = struct {
    algorithm: Algorithm = .myers,
    /// Lines of context a hunk carries on each side.
    context: usize = 3,
    /// Ignore a change that only adds or removes trailing whitespace.
    ignore_trailing_whitespace: bool = false,
    /// Ignore changes in the amount of whitespace inside a line.
    ignore_whitespace_change: bool = false,
    /// Ignore every whitespace difference.
    ignore_all_whitespace: bool = false,
    /// Score the places a run of changed lines could sit by the indentation
    /// around them and take the best. On by default because it is on by
    /// default in git, which is where the expected output comes from.
    indent_heuristic: bool = true,
    /// Prove the script minimal instead of giving up once the search has
    /// cost enough, which is what `git diff --minimal` asks for. Slower, and
    /// on large noisy input it disagrees with plain `git diff`.
    minimal: bool = false,
    /// Cap on the work the algorithm will do before falling back to a
    /// correct but coarser script. One unit is one forward-and-backward
    /// sweep of the Myers search, summed over every split the diff takes.
    /// Zero means no cap, which still leaves git's own give-up heuristics in
    /// force unless `minimal` is set.
    max_work: usize = 0,
    /// Lines on the old side that begin with one of these are kept as
    /// context wherever an ordering allows it, which is `git diff
    /// --anchored`. Only the patience algorithm reads them, as in git.
    anchors: []const []const u8 = &.{},
};

/// The edit script between two line lists: the runs that differ, in order,
/// with matching lines between them. The result is the caller's.
pub fn diffLines(
    gpa: Allocator,
    old: []const Line,
    new: []const Line,
    options: Options,
) Allocator.Error![]Change {
    const classified = try classify(gpa, old, new, options);
    defer gpa.free(classified.ids);
    const a = classified.ids[0..old.len];
    const b = classified.ids[old.len..];

    const changed_old = try Flags.init(gpa, old.len);
    defer changed_old.deinit(gpa);
    const changed_new = try Flags.init(gpa, new.len);
    defer changed_new.deinit(gpa);

    switch (options.algorithm) {
        .myers => try whole(gpa, a, b, classified.classes, changed_old, changed_new, options),
        .histogram => {
            var h: Histogram = .{
                .gpa = gpa,
                .a = a,
                .b = b,
                .classes = classified.classes,
                .changed_a = changed_old,
                .changed_b = changed_new,
                .options = options,
            };
            try h.diff(1, a.len, 1, b.len);
        },
        .patience => {
            var p: Patience = .{
                .gpa = gpa,
                .a = a,
                .b = b,
                .old = old,
                .classes = classified.classes,
                .changed_a = changed_old,
                .changed_b = changed_new,
                .options = options,
            };
            try p.run();
        },
    }

    const rediff_old: ?Rediff = if (options.algorithm == .histogram)
        .{ .gpa = gpa, .other_ids = b, .classes = classified.classes, .options = options }
    else
        null;
    const rediff_new: ?Rediff = if (options.algorithm == .histogram)
        .{ .gpa = gpa, .other_ids = a, .classes = classified.classes, .options = options }
    else
        null;
    try compact(changed_old, a, old, changed_new, options.indent_heuristic, rediff_old);
    try compact(changed_new, b, new, changed_old, options.indent_heuristic, rediff_new);

    return buildScript(gpa, changed_old, changed_new);
}

/// Mark the changed lines of two whole files with Myers, the way git's
/// `xdl_do_diff` does: the equal head and tail set aside, then the lines no
/// match can come from.
///
/// `a` and `b` are the identity numbers of the two files and the flags are
/// theirs, one per line. Patience and the histogram call this on a region
/// as if the region were a pair of files, which is what git's fallback
/// does.
fn whole(
    gpa: Allocator,
    a: []const u32,
    b: []const u32,
    classes: u32,
    changed_old: Flags,
    changed_new: Flags,
    options: Options,
) Allocator.Error!void {
    // The equal head and tail cannot be part of any change, and keeping them
    // out of the search is what git does before it starts counting edits.
    var start: usize = 0;
    while (start < a.len and start < b.len and a[start] == b[start]) start += 1;
    var end_old = a.len;
    var end_new = b.len;
    while (end_old > start and end_new > start and a[end_old - 1] == b[end_new - 1]) {
        end_old -= 1;
        end_new -= 1;
    }

    // Which lines the search actually sees. Myers gets git's pruned set. A
    // minimal script keeps the lines that are merely too common, because a
    // line dropped for being uninformative is a match that can never be
    // found again, but still loses the ones with no counterpart at all,
    // which no script could match; that is git's own rule, and which lines
    // the search sees decides its ties.
    const counts = try classCounts(gpa, a, b, classes);
    defer gpa.free(counts.in_old);
    defer gpa.free(counts.in_new);
    const index_old = try selectRecords(gpa, a, counts.in_new, start, end_old, changed_old, options.minimal);
    defer gpa.free(index_old);
    const index_new = try selectRecords(gpa, b, counts.in_old, start, end_new, changed_new, options.minimal);
    defer gpa.free(index_new);

    const packed_old = try gpa.alloc(u32, index_old.len);
    defer gpa.free(packed_old);
    for (index_old, packed_old) |at, *id| id.* = a[at];
    const packed_new = try gpa.alloc(u32, index_new.len);
    defer gpa.free(packed_new);
    for (index_new, packed_new) |at, *id| id.* = b[at];

    // One diagonal per possible value of x - y, plus a sentinel diagonal at
    // each end that the sweep writes its out-of-box marker into.
    const ndiags = packed_old.len + packed_new.len + 3;
    const kvd = try gpa.alloc(isize, 2 * ndiags);
    defer gpa.free(kvd);
    var search: Search = .{
        .a = packed_old,
        .b = packed_new,
        .index_a = index_old,
        .index_b = index_new,
        .changed_a = changed_old,
        .changed_b = changed_new,
        .forward = kvd[0..ndiags],
        .backward = kvd[ndiags..],
        .diag_bias = @as(isize, @intCast(packed_new.len)) + 1,
        .max_cost = @max(max_cost_min, bogosqrt(ndiags)),
        .work = 0,
        .max_work = options.max_work,
    };
    search.myers(0, packed_old.len, 0, packed_new.len, options.minimal);
}

/// One hunk of a unified diff.
pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    /// The changes this hunk covers, borrowed from the change list.
    changes: []const Change,
};

/// Group changes into hunks with `options.context` lines of context,
/// merging hunks that overlap. The result is the caller's.
pub fn hunks(
    gpa: Allocator,
    changes: []const Change,
    old_len: usize,
    new_len: usize,
    options: Options,
) Allocator.Error![]Hunk {
    var out: std.ArrayList(Hunk) = .empty;
    errdefer out.deinit(gpa);

    // Two changes belong to one hunk when the run of common lines between
    // them is no longer than the context both would print anyway.
    const max_common = 2 * options.context;
    var i: usize = 0;
    while (i < changes.len) {
        var j = i + 1;
        while (j < changes.len) : (j += 1) {
            const prev = changes[j - 1];
            const gap = changes[j].old_start - (prev.old_start + prev.old_count);
            if (gap > max_common) break;
        }
        const first = changes[i];
        const last = changes[j - 1];
        const s1 = first.old_start -| options.context;
        const s2 = first.new_start -| options.context;
        const e1 = @min(last.old_start + last.old_count + options.context, old_len);
        const e2 = @min(last.new_start + last.new_count + options.context, new_len);
        try out.append(gpa, .{
            .old_start = s1,
            .old_count = e1 - s1,
            .new_start = s2,
            .new_count = e2 - s2,
            .changes = changes[i..j],
        });
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

/// Added and removed line counts over a whole edit script.
pub const Stat = struct { plus: usize, minus: usize };

/// The plus and minus counts an edit script implies.
pub fn stat(changes: []const Change) Stat {
    var s: Stat = .{ .plus = 0, .minus = 0 };
    for (changes) |c| {
        s.plus += c.new_count;
        s.minus += c.old_count;
    }
    return s;
}

/// git's rule: a NUL byte in the first 8000 bytes makes a file binary.
pub fn isBinary(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 8000)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

//=========================================================================
// Line identity
//
// Every line becomes a small integer, equal integers meaning equal lines
// under the whitespace options in force. The algorithms compare only those
// integers, so a whitespace option costs nothing past this point and the
// change ranges still index the real lines.
//=========================================================================

/// Whether `c` is whitespace by git's reckoning, which includes the newline.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// Append the comparison form of `line` to `out`.
///
/// The trailing newline is held back and re-appended, so a final line that
/// lacks one never equals a line that has one -- the distinction `git diff`
/// prints as "\\ No newline at end of file". Under `ignore_all_whitespace`
/// the newline goes with the rest of the whitespace, as it does in git.
fn normalize(gpa: Allocator, out: *std.ArrayList(u8), line: Line, options: Options) Allocator.Error!void {
    const has_newline = line.len > 0 and line[line.len - 1] == '\n';
    const body = if (has_newline) line[0 .. line.len - 1] else line;

    if (options.ignore_all_whitespace) {
        for (body) |c| {
            if (!isSpace(c)) try out.append(gpa, c);
        }
        return;
    }

    var end = body.len;
    if (options.ignore_whitespace_change or options.ignore_trailing_whitespace) {
        while (end > 0 and isSpace(body[end - 1])) end -= 1;
    }
    const trimmed = body[0..end];

    if (options.ignore_whitespace_change) {
        var i: usize = 0;
        while (i < trimmed.len) {
            if (isSpace(trimmed[i])) {
                try out.append(gpa, ' ');
                while (i < trimmed.len and isSpace(trimmed[i])) i += 1;
            } else {
                try out.append(gpa, trimmed[i]);
                i += 1;
            }
        }
    } else {
        try out.appendSlice(gpa, trimmed);
    }

    if (has_newline) try out.append(gpa, '\n');
}

/// Identity numbers for `old` then `new`, in one slice of `old.len +
/// new.len` entries, and how many distinct lines they name. The slice is
/// the caller's.
const Classified = struct { ids: []u32, classes: u32 };

fn classify(gpa: Allocator, old: []const Line, new: []const Line, options: Options) Allocator.Error!Classified {
    const total = old.len + new.len;
    const ids = try gpa.alloc(u32, total);
    errdefer gpa.free(ids);
    if (total == 0) return .{ .ids = ids, .classes = 0 };

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const spans = try gpa.alloc([2]usize, total);
    defer gpa.free(spans);

    for (old, 0..) |line, i| {
        const at = text.items.len;
        try normalize(gpa, &text, line, options);
        spans[i] = .{ at, text.items.len };
    }
    for (new, 0..) |line, i| {
        const at = text.items.len;
        try normalize(gpa, &text, line, options);
        spans[old.len + i] = .{ at, text.items.len };
    }

    // `text` is complete before a single key is taken, so no append can move
    // the bytes a live key points at.
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(gpa);
    var next_id: u32 = 0;
    for (spans, 0..) |span, i| {
        const gop = try seen.getOrPut(gpa, text.items[span[0]..span[1]]);
        if (!gop.found_existing) {
            gop.value_ptr.* = next_id;
            next_id += 1;
        }
        ids[i] = gop.value_ptr.*;
    }
    return .{ .ids = ids, .classes = next_id };
}

//=========================================================================
// Which lines the search is given
//
// git does not hand Myers the whole file. A line with no counterpart on
// the other side cannot be part of any match, so it is marked changed up
// front and left out; a line so common that matching it means nothing is
// left out too, but only where it sits in a run of lines that are already
// going to be dropped. Both are load-bearing: they are why `git diff` on a
// noisy file keeps the few shared lines as context instead of collapsing
// the region into one block.
//=========================================================================

/// How often a line appears in one file and so is worth matching at all.
const max_eqlimit: usize = 1024;
/// How far the run scan either side of a common line reaches.
const simscan_window: isize = 100;
/// A run has to be this much more no-match than multi-match before a
/// multi-match line in it is dropped as well.
const kpdis_run: isize = 4;

/// How many times each line of each file occurs in that file. Both slices
/// are the caller's.
fn classCounts(gpa: Allocator, a: []const u32, b: []const u32, classes: u32) Allocator.Error!struct {
    in_old: []u32,
    in_new: []u32,
} {
    const in_old = try gpa.alloc(u32, classes);
    errdefer gpa.free(in_old);
    const in_new = try gpa.alloc(u32, classes);
    @memset(in_old, 0);
    @memset(in_new, 0);
    for (a) |id| in_old[id] += 1;
    for (b) |id| in_new[id] += 1;
    return .{ .in_old = in_old, .in_new = in_new };
}

/// The lines of `ids[start..end]` the search should see, as indices into
/// the whole file. Everything else is marked changed here and never
/// reconsidered. `need_min` keeps every line that has a counterpart, however
/// common. The result is the caller's.
fn selectRecords(
    gpa: Allocator,
    ids: []const u32,
    counts_other: []const u32,
    start: usize,
    end: usize,
    changed: Flags,
    need_min: bool,
) Allocator.Error![]u32 {
    if (start >= end) return gpa.alloc(u32, 0);

    // 0: no counterpart at all. 1: worth matching. 2: so common that a
    // match says little. Positions outside the region stay 0, which is what
    // stops the run scan at the boundary.
    const dis = try gpa.alloc(u8, ids.len);
    defer gpa.free(dis);
    @memset(dis, 0);
    const limit = @min(bogosqrt(ids.len), max_eqlimit);
    for (start..end) |i| {
        const nm = counts_other[ids[i]];
        dis[i] = if (nm == 0) 0 else if (nm >= limit and !need_min) 2 else 1;
    }

    var kept: std.ArrayList(u32) = .empty;
    errdefer kept.deinit(gpa);
    for (start..end) |i| {
        const keep = switch (dis[i]) {
            1 => true,
            2 => !inDiscardableRun(dis, @intCast(i), @intCast(start), @intCast(end - 1)),
            else => false,
        };
        if (keep) {
            try kept.append(gpa, @intCast(i));
        } else {
            changed.set(@intCast(i), true);
        }
    }
    return kept.toOwnedSlice(gpa);
}

/// Whether the too-common line at `i` sits between two runs that are mostly
/// lines with no counterpart, in which case matching it would only pin the
/// diff to a coincidence.
fn inDiscardableRun(dis: []const u8, i: isize, start: isize, end: isize) bool {
    var low = start;
    var high = end;
    if (i - low > simscan_window) low = i - simscan_window;
    if (high - i > simscan_window) high = i + simscan_window;

    var no_match_before: isize = 0;
    var common_before: isize = 1;
    var r: isize = 1;
    while (i - r >= low) : (r += 1) {
        switch (dis[@intCast(i - r)]) {
            0 => no_match_before += 1,
            2 => common_before += 1,
            else => break,
        }
    }
    if (no_match_before == 0) return false;

    var no_match_after: isize = 0;
    var common_after: isize = 1;
    r = 1;
    while (i + r <= high) : (r += 1) {
        switch (dis[@intCast(i + r)]) {
            0 => no_match_after += 1,
            2 => common_after += 1,
            else => break,
        }
    }
    if (no_match_after == 0) return false;

    const no_match = no_match_before + no_match_after;
    const common = common_before + common_after;
    return common * kpdis_run < common + no_match;
}

//=========================================================================
// Changed-line flags
//
// Both algorithms write their answer as one flag per line on each side,
// which is the form the slide needs: it moves a change by moving flags, and
// it has to be able to read one line past either end of the file without a
// bounds test, so the array carries a clear sentinel at each end and is
// addressed with a signed index.
//=========================================================================

/// One flag per line, with a clear sentinel at index -1 and at index len.
const Flags = struct {
    raw: []u8,
    len: isize,

    fn init(gpa: Allocator, n: usize) Allocator.Error!Flags {
        const raw = try gpa.alloc(u8, n + 2);
        @memset(raw, 0);
        return .{ .raw = raw, .len = @intCast(n) };
    }

    fn deinit(f: Flags, gpa: Allocator) void {
        gpa.free(f.raw);
    }

    fn get(f: Flags, i: isize) bool {
        return f.raw[@intCast(i + 1)] != 0;
    }

    fn set(f: Flags, i: isize, value: bool) void {
        f.raw[@intCast(i + 1)] = @intFromBool(value);
    }
};

//=========================================================================
// Myers
//
// The constants are xdiff's, and they are not decoration: the point at
// which git stops proving the script minimal is part of the output. A
// textbook minimal Myers disagrees with `git diff` on anything large or
// repetitive, so these numbers are what make the hunks match.
//=========================================================================

/// Below this edit cost the search never gives up, however small the input.
const max_cost_min: usize = 256;
/// Above this edit cost a long enough snake is allowed to end the search.
const heur_min_cost: usize = 256;
/// How many equal lines in a row count as a snake worth splitting on.
const snake_cnt: isize = 20;
/// How far a snake has to reach, relative to the edit cost, to be taken.
const k_heur: isize = 4;

/// xdiff's integer square root by shifts. It overshoots, which is fine: it
/// only sets a give-up threshold, and the answer has to be the one git's
/// arithmetic gives or the give-up point moves.
fn bogosqrt(n: usize) usize {
    var i: usize = 1;
    var v = n;
    while (v > 0) : (v >>= 2) i <<= 1;
    return i;
}

/// The state both algorithms share: the two identity arrays, the flags they
/// fill in, and the two diagonal vectors the Myers split needs.
const Search = struct {
    a: []const u32,
    b: []const u32,
    /// Where each entry of `a` and `b` sits in its whole file.
    index_a: []const u32,
    index_b: []const u32,
    changed_a: Flags,
    changed_b: Flags,
    forward: []isize,
    backward: []isize,
    /// Added to a diagonal number to index `forward` and `backward`.
    diag_bias: isize,
    /// Edit cost past which the search takes the best split it has.
    max_cost: usize,
    work: usize,
    max_work: usize,

    const out_of_box_low: isize = -1;
    const out_of_box_high: isize = std.math.maxInt(isize);

    fn getF(s: *const Search, d: isize) isize {
        return s.forward[@intCast(d + s.diag_bias)];
    }
    fn setF(s: *Search, d: isize, v: isize) void {
        s.forward[@intCast(d + s.diag_bias)] = v;
    }
    fn getB(s: *const Search, d: isize) isize {
        return s.backward[@intCast(d + s.diag_bias)];
    }
    fn setB(s: *Search, d: isize, v: isize) void {
        s.backward[@intCast(d + s.diag_bias)] = v;
    }

    fn markA(s: *Search, from: usize, to: usize) void {
        for (s.index_a[from..to]) |at| s.changed_a.set(@intCast(at), true);
    }

    fn markB(s: *Search, from: usize, to: usize) void {
        for (s.index_b[from..to]) |at| s.changed_b.set(@intCast(at), true);
    }

    /// Mark everything in both regions changed. Always a correct script,
    /// and the one the work cap falls back to.
    fn markAll(s: *Search, off1: usize, lim1: usize, off2: usize, lim2: usize) void {
        s.markA(off1, lim1);
        s.markB(off2, lim2);
    }

    /// Diff the box `[off1, lim1) x [off2, lim2)` by splitting it at a
    /// middle snake and recursing on the two halves. `need_min` asks this
    /// box for a minimal script; a heuristic split hands it down to one half
    /// and not the other, because only one half is known to be exact.
    fn myers(
        s: *Search,
        off1_in: usize,
        lim1_in: usize,
        off2_in: usize,
        lim2_in: usize,
        need_min: bool,
    ) void {
        var off1 = off1_in;
        var lim1 = lim1_in;
        var off2 = off2_in;
        var lim2 = lim2_in;

        while (off1 < lim1 and off2 < lim2 and s.a[off1] == s.b[off2]) {
            off1 += 1;
            off2 += 1;
        }
        while (off1 < lim1 and off2 < lim2 and s.a[lim1 - 1] == s.b[lim2 - 1]) {
            lim1 -= 1;
            lim2 -= 1;
        }

        if (off1 == lim1) {
            s.markB(off2, lim2);
            return;
        }
        if (off2 == lim2) {
            s.markA(off1, lim1);
            return;
        }

        const split = s.middleSnake(off1, lim1, off2, lim2, need_min) orelse {
            s.markAll(off1, lim1, off2, lim2);
            return;
        };
        // A split on a corner of the box leaves one half empty and the other
        // identical to the box, which would recurse for ever. The give-up
        // paths pick a point by a measure rather than by a crossing, so
        // refuse the degenerate answer rather than trust it.
        if ((split.i1 == off1 and split.i2 == off2) or (split.i1 == lim1 and split.i2 == lim2)) {
            s.markAll(off1, lim1, off2, lim2);
            return;
        }
        s.myers(off1, split.i1, off2, split.i2, split.min_lo);
        s.myers(split.i1, lim1, split.i2, lim2, split.min_hi);
    }

    const Split = struct { i1: usize, i2: usize, min_lo: bool, min_hi: bool };

    /// Where the edit script through this box crosses it: run the greedy
    /// search from both corners until the two frontiers touch, or until one
    /// of git's two give-up rules fires. Returns null when `max_work` ran
    /// out, which is the caller's signal to describe the box coarsely.
    fn middleSnake(
        s: *Search,
        off1: usize,
        lim1: usize,
        off2: usize,
        lim2: usize,
        need_min: bool,
    ) ?Split {
        const o1: isize = @intCast(off1);
        const l1: isize = @intCast(lim1);
        const o2: isize = @intCast(off2);
        const l2: isize = @intCast(lim2);

        const dmin = o1 - l2;
        const dmax = l1 - o2;
        const fmid = o1 - o2;
        const bmid = l1 - l2;
        // The frontiers can only touch on a diagonal of one parity, and
        // which one decides whether the forward or the backward sweep is the
        // one that notices.
        const odd = @mod(fmid - bmid, 2) != 0;

        var fmin = fmid;
        var fmax = fmid;
        var bmin = bmid;
        var bmax = bmid;
        s.setF(fmid, o1);
        s.setB(bmid, l1);

        var ec: usize = 1;
        while (true) : (ec += 1) {
            if (s.max_work != 0) {
                if (s.work >= s.max_work) return null;
                s.work += 1;
            }
            var got_snake = false;

            // The band of live diagonals widens by one on each side, or, if
            // it has already reached the edge of the box, narrows there
            // instead so that its width keeps its parity.
            if (fmin > dmin) {
                fmin -= 1;
                s.setF(fmin - 1, out_of_box_low);
            } else fmin += 1;
            if (fmax < dmax) {
                fmax += 1;
                s.setF(fmax + 1, out_of_box_low);
            } else fmax -= 1;

            var d = fmax;
            while (d >= fmin) : (d -= 2) {
                // A tie goes to the step that takes a line from the old
                // side; this is the tie-break git's output rests on.
                var x = if (s.getF(d - 1) >= s.getF(d + 1)) s.getF(d - 1) + 1 else s.getF(d + 1);
                const from = x;
                var y = x - d;
                while (x < l1 and y < l2 and s.a[@intCast(x)] == s.b[@intCast(y)]) {
                    x += 1;
                    y += 1;
                }
                if (x - from > snake_cnt) got_snake = true;
                s.setF(d, x);
                if (odd and bmin <= d and d <= bmax and s.getB(d) <= x) {
                    return .{ .i1 = @intCast(x), .i2 = @intCast(y), .min_lo = true, .min_hi = true };
                }
            }

            if (bmin > dmin) {
                bmin -= 1;
                s.setB(bmin - 1, out_of_box_high);
            } else bmin += 1;
            if (bmax < dmax) {
                bmax += 1;
                s.setB(bmax + 1, out_of_box_high);
            } else bmax -= 1;

            d = bmax;
            while (d >= bmin) : (d -= 2) {
                var x = if (s.getB(d - 1) < s.getB(d + 1)) s.getB(d - 1) else s.getB(d + 1) - 1;
                const from = x;
                var y = x - d;
                while (x > o1 and y > o2 and s.a[@intCast(x - 1)] == s.b[@intCast(y - 1)]) {
                    x -= 1;
                    y -= 1;
                }
                if (from - x > snake_cnt) got_snake = true;
                s.setB(d, x);
                if (!odd and fmin <= d and d <= fmax and x <= s.getF(d)) {
                    return .{ .i1 = @intCast(x), .i2 = @intCast(y), .min_lo = true, .min_hi = true };
                }
            }

            if (need_min) continue;

            // A frontier that has run a long way along one diagonal has
            // almost certainly found the real correspondence, so split there
            // and stop paying for a proof. The half behind the snake is
            // exact; the half in front of it is not, and is told so.
            if (got_snake and ec > heur_min_cost) {
                if (s.forwardSnakeSplit(ec, fmin, fmax, fmid, o1, l1, o2, l2)) |split| return split;
                if (s.backwardSnakeSplit(ec, bmin, bmax, bmid, o1, l1, o2, l2)) |split| return split;
            }

            // Enough. Take the furthest reaching path either frontier has.
            if (ec >= s.max_cost) {
                var fbest: isize = -1;
                var fbest1: isize = -1;
                d = fmax;
                while (d >= fmin) : (d -= 2) {
                    var x = @min(s.getF(d), l1);
                    var y = x - d;
                    if (l2 < y) {
                        x = l2 + d;
                        y = l2;
                    }
                    if (fbest < x + y) {
                        fbest = x + y;
                        fbest1 = x;
                    }
                }

                var bbest: isize = std.math.maxInt(isize);
                var bbest1: isize = std.math.maxInt(isize);
                d = bmax;
                while (d >= bmin) : (d -= 2) {
                    var x = @max(o1, s.getB(d));
                    var y = x - d;
                    if (y < o2) {
                        x = o2 + d;
                        y = o2;
                    }
                    if (x + y < bbest) {
                        bbest = x + y;
                        bbest1 = x;
                    }
                }

                if ((l1 + l2) - bbest < fbest - (o1 + o2)) {
                    return .{
                        .i1 = @intCast(fbest1),
                        .i2 = @intCast(fbest - fbest1),
                        .min_lo = true,
                        .min_hi = false,
                    };
                }
                return .{
                    .i1 = @intCast(bbest1),
                    .i2 = @intCast(bbest - bbest1),
                    .min_lo = false,
                    .min_hi = true,
                };
            }
        }
    }

    /// The forward diagonal that has reached furthest from its corner, if it
    /// ends in a long enough snake to be worth splitting on.
    fn forwardSnakeSplit(
        s: *Search,
        ec: usize,
        fmin: isize,
        fmax: isize,
        fmid: isize,
        o1: isize,
        l1: isize,
        o2: isize,
        l2: isize,
    ) ?Split {
        var best: isize = 0;
        var best_split: Split = undefined;
        var d = fmax;
        while (d >= fmin) : (d -= 2) {
            const off_mid = if (d > fmid) d - fmid else fmid - d;
            const x = s.getF(d);
            const y = x - d;
            const reach = (x - o1) + (y - o2) - off_mid;
            if (reach <= k_heur * @as(isize, @intCast(ec)) or reach <= best) continue;
            if (!(o1 + snake_cnt <= x and x < l1 and o2 + snake_cnt <= y and y < l2)) continue;
            var k: isize = 1;
            while (s.a[@intCast(x - k)] == s.b[@intCast(y - k)]) : (k += 1) {
                if (k == snake_cnt) {
                    best = reach;
                    best_split = .{
                        .i1 = @intCast(x),
                        .i2 = @intCast(y),
                        .min_lo = true,
                        .min_hi = false,
                    };
                    break;
                }
            }
        }
        return if (best > 0) best_split else null;
    }

    /// The same for the backward frontier, where the exact half is the one
    /// in front of the split rather than behind it.
    fn backwardSnakeSplit(
        s: *Search,
        ec: usize,
        bmin: isize,
        bmax: isize,
        bmid: isize,
        o1: isize,
        l1: isize,
        o2: isize,
        l2: isize,
    ) ?Split {
        var best: isize = 0;
        var best_split: Split = undefined;
        var d = bmax;
        while (d >= bmin) : (d -= 2) {
            const off_mid = if (d > bmid) d - bmid else bmid - d;
            const x = s.getB(d);
            const y = x - d;
            const reach = (l1 - x) + (l2 - y) - off_mid;
            if (reach <= k_heur * @as(isize, @intCast(ec)) or reach <= best) continue;
            if (!(o1 < x and x <= l1 - snake_cnt and o2 < y and y <= l2 - snake_cnt)) continue;
            var k: isize = 0;
            while (s.a[@intCast(x + k)] == s.b[@intCast(y + k)]) : (k += 1) {
                if (k == snake_cnt - 1) {
                    best = reach;
                    best_split = .{
                        .i1 = @intCast(x),
                        .i2 = @intCast(y),
                        .min_lo = false,
                        .min_hi = true,
                    };
                    break;
                }
            }
        }
        return if (best > 0) best_split else null;
    }
};

//=========================================================================
// Histogram
//
// xdiff's xhistogram, line for line in what it decides. A region is split
// at its longest common run anchored on the rarest line available; what is
// left either side is split the same way. The ties are the point: which
// run is longest, which occurrence of a repeated line is tried first, and
// when a line is too common to anchor anything all decide where a merge's
// conflict lands, and git's merge machinery diffs with this algorithm. It
// does not trim the equal ends first, and a region it cannot anchor goes to
// a Myers diff of just that region -- pruned against the region's own
// counts, as git's fallback prepares it afresh.
//=========================================================================

const Histogram = struct {
    gpa: Allocator,
    a: []const u32,
    b: []const u32,
    classes: u32,
    changed_a: Flags,
    changed_b: Flags,
    options: Options,

    /// Lines occurring more often than this in a region anchor nothing.
    const max_chain: u32 = 64;

    /// A common run, as one-based inclusive line numbers. All zeros is none.
    const Region = struct { begin1: usize = 0, end1: usize = 0, begin2: usize = 0, end2: usize = 0 };

    /// One value's occurrences in the old side of a region: the first line
    /// it is on and how many lines it is on.
    const Record = struct { ptr: usize, cnt: u32 };

    fn markA(h: *Histogram, line: usize, count: usize) void {
        for (line..line + count) |l| h.changed_a.set(@intCast(l - 1), true);
    }

    fn markB(h: *Histogram, line: usize, count: usize) void {
        for (line..line + count) |l| h.changed_b.set(@intCast(l - 1), true);
    }

    /// Diff lines `line1 .. line1 + count1` against `line2 .. line2 +
    /// count2`, one-based, as `histogram_diff` does.
    fn diff(h: *Histogram, line1_in: usize, count1_in: usize, line2_in: usize, count2_in: usize) Allocator.Error!void {
        var line1 = line1_in;
        var count1 = count1_in;
        var line2 = line2_in;
        var count2 = count2_in;
        while (true) {
            if (count1 == 0 and count2 == 0) return;
            if (count1 == 0) return h.markB(line2, count2);
            if (count2 == 0) return h.markA(line1, count1);

            var lcs: Region = .{};
            if (try h.findLcs(&lcs, line1, count1, line2, count2)) {
                return h.giveUp(line1, count1, line2, count2);
            }
            if (lcs.begin1 == 0 and lcs.begin2 == 0) {
                h.markA(line1, count1);
                h.markB(line2, count2);
                return;
            }
            try h.diff(line1, lcs.begin1 - line1, line2, lcs.begin2 - line2);
            const end1 = line1 + count1 - 1;
            const end2 = line2 + count2 - 1;
            count1 = end1 - lcs.end1;
            line1 = lcs.end1 + 1;
            count2 = end2 - lcs.end2;
            line2 = lcs.end2 + 1;
        }
    }

    /// Find the anchor run. True when the region has common lines but every
    /// one of them is too common, which is git's signal to hand it to Myers.
    fn findLcs(
        h: *Histogram,
        lcs: *Region,
        line1: usize,
        count1: usize,
        line2: usize,
        count2: usize,
    ) Allocator.Error!bool {
        const end1 = line1 + count1 - 1;
        const end2 = line2 + count2 - 1;

        // Every occurrence of a value chains to the next one down the file,
        // and the value's record starts at its first. Scanning from the end
        // is what leaves the chains in that order.
        const next = try h.gpa.alloc(usize, count1);
        defer h.gpa.free(next);
        var records: std.AutoHashMapUnmanaged(u32, Record) = .empty;
        defer records.deinit(h.gpa);
        try records.ensureTotalCapacity(h.gpa, @intCast(@min(count1, h.classes)));
        var ptr = end1;
        while (ptr >= line1) : (ptr -= 1) {
            const gop = records.getOrPutAssumeCapacity(h.a[ptr - 1]);
            if (gop.found_existing) {
                next[ptr - line1] = gop.value_ptr.ptr;
                gop.value_ptr.ptr = ptr;
                gop.value_ptr.cnt +|= 1;
            } else {
                next[ptr - line1] = 0;
                gop.value_ptr.* = .{ .ptr = ptr, .cnt = 1 };
            }
            if (ptr == line1) break;
        }

        var best_cnt: u32 = max_chain + 1;
        var has_common = false;
        var b_ptr = line2;
        while (b_ptr <= end2) {
            var b_next = b_ptr + 1;
            const rec = records.get(h.b[b_ptr - 1]) orelse {
                b_ptr = b_next;
                continue;
            };
            if (rec.cnt > best_cnt) {
                has_common = true;
                b_ptr = b_next;
                continue;
            }
            has_common = true;
            var as = rec.ptr;
            occurrences: while (true) {
                var np = next[as - line1];
                var bs = b_ptr;
                var ae = as;
                var be = bs;
                var rc = rec.cnt;
                while (line1 < as and line2 < bs and h.a[as - 2] == h.b[bs - 2]) {
                    as -= 1;
                    bs -= 1;
                    if (1 < rc) rc = @min(rc, records.get(h.a[as - 1]).?.cnt);
                }
                while (ae < end1 and be < end2 and h.a[ae] == h.b[be]) {
                    ae += 1;
                    be += 1;
                    if (1 < rc) rc = @min(rc, records.get(h.a[ae - 1]).?.cnt);
                }
                if (b_next <= be) b_next = be + 1;
                if (lcs.end1 - lcs.begin1 < ae - as or rc < best_cnt) {
                    lcs.* = .{ .begin1 = as, .begin2 = bs, .end1 = ae, .end2 = be };
                    best_cnt = rc;
                }
                if (np == 0) break;
                while (np <= ae) {
                    np = next[np - line1];
                    if (np == 0) break :occurrences;
                }
                as = np;
            }
            b_ptr = b_next;
        }
        return has_common and max_chain < best_cnt;
    }

    fn giveUp(h: *Histogram, line1: usize, count1: usize, line2: usize, count2: usize) Allocator.Error!void {
        return fallBack(h.gpa, h.a, h.changed_a, line1 - 1, count1, h.b, h.changed_b, line2 - 1, count2, h.classes, h.options);
    }
};

/// A Myers diff of one region of each side, prepared as if the two regions
/// were whole files -- git's `xdl_fall_back_diff` -- with every flag in both
/// regions overwritten by its answer.
fn fallBack(
    gpa: Allocator,
    a: []const u32,
    changed_a: Flags,
    start_a: usize,
    count_a: usize,
    b: []const u32,
    changed_b: Flags,
    start_b: usize,
    count_b: usize,
    classes: u32,
    options_in: Options,
) Allocator.Error!void {
    const flags_a = try Flags.init(gpa, count_a);
    defer flags_a.deinit(gpa);
    const flags_b = try Flags.init(gpa, count_b);
    defer flags_b.deinit(gpa);
    var options = options_in;
    options.algorithm = .myers;
    try whole(gpa, a[start_a..][0..count_a], b[start_b..][0..count_b], classes, flags_a, flags_b, options);
    for (0..count_a) |i| changed_a.set(@intCast(start_a + i), flags_a.get(@intCast(i)));
    for (0..count_b) |i| changed_b.set(@intCast(start_b + i), flags_b.get(@intCast(i)));
}

//=========================================================================
// Patience
//
// git's xpatience.c. A region is diffed by the lines that occur exactly once
// in it on each side: the longest run of those that is in the same order on
// both sides is taken as the backbone, each backbone line is grown outward
// over equal neighbours, and the gaps between are regions of their own,
// where a line that was repeated before may now be unique. A region with no
// unique line in common goes to the classic pipeline as a pair of files.
//
// git recurses; this keeps a list of regions still to do instead. The
// regions are disjoint and each one writes only its own flags, so the order
// they are done in cannot change the answer, and a deep file cannot run the
// stack out.
//=========================================================================

const Patience = struct {
    gpa: Allocator,
    a: []const u32,
    b: []const u32,
    /// The old side's real lines, which only the anchor test reads.
    old: []const Line,
    classes: u32,
    changed_a: Flags,
    changed_b: Flags,
    options: Options,

    /// A region still to be diffed: `count1` lines from `line1` of the old
    /// side against `count2` lines from `line2` of the new.
    const Region = struct { line1: usize, count1: usize, line2: usize, count2: usize };

    /// A line of the old side and what the new side holds of it. `line2` is
    /// `none` until the new side is seen and `repeated` once either side has
    /// it twice, which is what takes it out of the running.
    const Slot = struct {
        line1: usize,
        line2: usize = none,
        anchor: bool,
        /// The backbone entry before this one, as an index into the slots.
        previous: u32 = no_slot,

        const none = std.math.maxInt(usize);
        const repeated = std.math.maxInt(usize) - 1;
    };

    const no_slot = std.math.maxInt(u32);

    fn run(p: *Patience) Allocator.Error!void {
        var todo: std.ArrayList(Region) = .empty;
        defer todo.deinit(p.gpa);
        try todo.append(p.gpa, .{ .line1 = 0, .count1 = p.a.len, .line2 = 0, .count2 = p.b.len });
        while (todo.pop()) |next| try p.diffRegion(next, &todo);
    }

    fn markA(p: *Patience, from: usize, count: usize) void {
        for (from..from + count) |i| p.changed_a.set(@intCast(i), true);
    }

    fn markB(p: *Patience, from: usize, count: usize) void {
        for (from..from + count) |i| p.changed_b.set(@intCast(i), true);
    }

    fn isAnchor(p: *const Patience, line: Line) bool {
        for (p.options.anchors) |anchor| {
            if (std.mem.startsWith(u8, line, anchor)) return true;
        }
        return false;
    }

    fn diffRegion(p: *Patience, r: Region, todo: *std.ArrayList(Region)) Allocator.Error!void {
        if (r.count1 == 0) return p.markB(r.line2, r.count2);
        if (r.count2 == 0) return p.markA(r.line1, r.count1);

        // Every distinct line of the old side, in the order it first
        // appears there, which is the order the backbone is built in.
        var slots: std.ArrayList(Slot) = .empty;
        defer slots.deinit(p.gpa);
        var by_class: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer by_class.deinit(p.gpa);
        try by_class.ensureTotalCapacity(p.gpa, @intCast(@min(r.count1, p.classes)));

        for (r.line1..r.line1 + r.count1) |i| {
            const gop = by_class.getOrPutAssumeCapacity(p.a[i]);
            if (gop.found_existing) {
                slots.items[gop.value_ptr.*].line2 = Slot.repeated;
                continue;
            }
            gop.value_ptr.* = @intCast(slots.items.len);
            try slots.append(p.gpa, .{ .line1 = i, .anchor = p.isAnchor(p.old[i]) });
        }

        var has_matches = false;
        for (r.line2..r.line2 + r.count2) |j| {
            const at = by_class.get(p.b[j]) orelse continue;
            has_matches = true;
            const slot = &slots.items[at];
            slot.line2 = if (slot.line2 == Slot.none) j else Slot.repeated;
        }

        if (!has_matches) {
            p.markA(r.line1, r.count1);
            p.markB(r.line2, r.count2);
            return;
        }

        const backbone = try p.longestCommon(slots.items);
        defer p.gpa.free(backbone);
        if (backbone.len == 0) return p.fallBack(r);
        try p.walk(r, slots.items, backbone, todo);
    }

    /// The longest run of lines unique on both sides that is in order on
    /// both, as slot indices in order. Patience sorting: each line goes on
    /// the pile after the longest run ending lower on the new side, and an
    /// anchor, once placed, is never displaced. The result is the caller's.
    fn longestCommon(p: *Patience, slots: []Slot) Allocator.Error![]u32 {
        const piles = try p.gpa.alloc(u32, slots.len);
        defer p.gpa.free(piles);
        var longest: usize = 0;
        // No pile at or below this one may be replaced.
        var anchor_at: isize = -1;

        for (slots, 0..) |*slot, at| {
            if (slot.line2 == Slot.none or slot.line2 == Slot.repeated) continue;
            // The last pile whose top is lower on the new side, or -1.
            var left: isize = -1;
            var right: isize = @intCast(longest);
            while (left + 1 < right) {
                const middle = left + @divTrunc(right - left, 2);
                if (slots[piles[@intCast(middle)]].line2 > slot.line2) right = middle else left = middle;
            }
            slot.previous = if (left < 0) no_slot else piles[@intCast(left)];
            const i = left + 1;
            if (i <= anchor_at) continue;
            piles[@intCast(i)] = @intCast(at);
            if (slot.anchor) {
                anchor_at = i;
                longest = @intCast(anchor_at + 1);
            } else if (i == longest) {
                longest += 1;
            }
        }

        const out = try p.gpa.alloc(u32, longest);
        if (longest == 0) return out;
        var cursor = piles[longest - 1];
        var n = longest;
        while (true) {
            n -= 1;
            out[n] = cursor;
            cursor = slots[cursor].previous;
            if (cursor == no_slot) break;
        }
        // The chain from the top pile back is exactly one slot per pile.
        std.debug.assert(n == 0);
        return out;
    }

    /// Grow each backbone line over the equal lines around it, and queue
    /// the gaps between.
    fn walk(p: *Patience, r: Region, slots: []const Slot, backbone: []const u32, todo: *std.ArrayList(Region)) Allocator.Error!void {
        const end1 = r.line1 + r.count1;
        const end2 = r.line2 + r.count2;
        var line1 = r.line1;
        var line2 = r.line2;
        var k: usize = 0;
        while (true) {
            var next1: usize = end1;
            var next2: usize = end2;
            if (k < backbone.len) {
                next1 = slots[backbone[k]].line1;
                next2 = slots[backbone[k]].line2;
                while (next1 > line1 and next2 > line2 and p.a[next1 - 1] == p.b[next2 - 1]) {
                    next1 -= 1;
                    next2 -= 1;
                }
            }
            while (line1 < next1 and line2 < next2 and p.a[line1] == p.b[line2]) {
                line1 += 1;
                line2 += 1;
            }
            if (next1 > line1 or next2 > line2) {
                try todo.append(p.gpa, .{
                    .line1 = line1,
                    .count1 = next1 - line1,
                    .line2 = line2,
                    .count2 = next2 - line2,
                });
            }
            if (k == backbone.len) return;

            // A stretch of backbone lines that follow one another on both
            // sides is one match, and the next gap starts after all of it.
            while (k + 1 < backbone.len and
                slots[backbone[k + 1]].line1 == slots[backbone[k]].line1 + 1 and
                slots[backbone[k + 1]].line2 == slots[backbone[k]].line2 + 1) k += 1;
            line1 = slots[backbone[k]].line1 + 1;
            line2 = slots[backbone[k]].line2 + 1;
            k += 1;
        }
    }

    /// A region with no line unique on both sides is diffed the classic
    /// way, as a pair of files of its own, which is git's
    /// `xdl_fall_back_diff`: the trimming and the pruning are over this
    /// region alone, and its flags are copied into place.
    fn fallBack(p: *Patience, r: Region) Allocator.Error!void {
        const sub_a = try Flags.init(p.gpa, r.count1);
        defer sub_a.deinit(p.gpa);
        const sub_b = try Flags.init(p.gpa, r.count2);
        defer sub_b.deinit(p.gpa);
        try whole(
            p.gpa,
            p.a[r.line1..][0..r.count1],
            p.b[r.line2..][0..r.count2],
            p.classes,
            sub_a,
            sub_b,
            p.options,
        );
        for (0..r.count1) |i| p.changed_a.set(@intCast(r.line1 + i), sub_a.get(@intCast(i)));
        for (0..r.count2) |i| p.changed_b.set(@intCast(r.line2 + i), sub_b.get(@intCast(i)));
    }
};

//=========================================================================
// The slide
//
// xdiff's xdl_change_compact. Each run of changed lines is pushed as far up
// the file as equal boundary lines allow and then as far down, absorbing
// any run it meets on the way. Where it ends up depends on whether the
// other side has a change it can line up with; failing that, on the
// indentation heuristic, which has been git's default since 2.14 and which
// is why an added block lands on the brace a reader would expect.
//=========================================================================

/// A maximal run of changed lines. Empty when start equals end.
const Group = struct { start: isize, end: isize };

fn groupInit(f: Flags) Group {
    var g: Group = .{ .start = 0, .end = 0 };
    while (f.get(g.end)) g.end += 1;
    return g;
}

/// Move to the run after this one, stepping over exactly one unchanged
/// line. False when this run already ends the file.
fn groupNext(f: Flags, g: *Group) bool {
    if (g.end == f.len) return false;
    g.start = g.end + 1;
    g.end = g.start;
    while (f.get(g.end)) g.end += 1;
    return true;
}

/// Move to the run before this one. False when this run starts the file.
fn groupPrevious(f: Flags, g: *Group) bool {
    if (g.start == 0) return false;
    g.end = g.start - 1;
    g.start = g.end;
    while (f.get(g.start - 1)) g.start -= 1;
    return true;
}

/// Push the run one line down the file, which is legal when the line the
/// run gives up matches the line it takes on. Absorbs the next run if the
/// move makes them touch.
fn slideDown(f: Flags, ids: []const u32, g: *Group) bool {
    if (g.end >= f.len) return false;
    if (ids[@intCast(g.start)] != ids[@intCast(g.end)]) return false;
    f.set(g.start, false);
    g.start += 1;
    f.set(g.end, true);
    g.end += 1;
    while (f.get(g.end)) g.end += 1;
    return true;
}

/// Push the run one line up the file, absorbing the previous run if the
/// move makes them touch.
fn slideUp(f: Flags, ids: []const u32, g: *Group) bool {
    if (g.start <= 0) return false;
    if (ids[@intCast(g.start - 1)] != ids[@intCast(g.end - 1)]) return false;
    g.start -= 1;
    f.set(g.start, true);
    g.end -= 1;
    f.set(g.end, false);
    while (f.get(g.start - 1)) g.start -= 1;
    return true;
}

/// Slide every run of changed lines in `f` to where git puts it. `other` is
/// the opposite side's flags, walked in step so that a run can be told when
/// it lines up with a change over there. `lines` is this side's real bytes,
/// which only the indentation heuristic reads.
/// What the slide needs to diff a merged run again, which only a histogram
/// diff asks for.
const Rediff = struct {
    gpa: Allocator,
    other_ids: []const u32,
    classes: u32,
    options: Options,
};

fn compact(
    f: Flags,
    ids: []const u32,
    lines: []const Line,
    other: Flags,
    indent_heuristic: bool,
    rediff: ?Rediff,
) Allocator.Error!void {
    var g = groupInit(f);
    var go = groupInit(other);

    while (true) {
        if (g.end != g.start) {
            const g_orig = g;
            var earliest_end: isize = g.end;
            var end_matching_other: isize = -1;
            var groupsize: isize = g.end - g.start;

            // Sliding one way can merge in a neighbour, which gives the
            // enlarged run room to slide further; repeat until it settles.
            while (true) {
                groupsize = g.end - g.start;
                end_matching_other = -1;

                while (slideUp(f, ids, &g)) {
                    std.debug.assert(groupPrevious(other, &go));
                }
                earliest_end = g.end;
                if (go.end > go.start) end_matching_other = g.end;

                while (slideDown(f, ids, &g)) {
                    std.debug.assert(groupNext(other, &go));
                    if (go.end > go.start) end_matching_other = g.end;
                }

                if (groupsize == g.end - g.start) break;
            }

            // The run now sits as far down as it will go, so every remaining
            // choice is a move back up.
            if (g.end == earliest_end) {
                // Nowhere to go.
            } else if (end_matching_other != -1) {
                // Pull it back to meet a change on the other side, so that a
                // deletion and the insertion replacing it print as one hunk.
                while (go.end == go.start) {
                    std.debug.assert(slideUp(f, ids, &g));
                    std.debug.assert(groupPrevious(other, &go));
                }
            } else if (indent_heuristic) {
                var shift = earliest_end;
                if (g.end - groupsize - 1 > shift) shift = g.end - groupsize - 1;
                if (g.end - indent_max_sliding > shift) shift = g.end - indent_max_sliding;

                var best_shift: isize = -1;
                var best: SplitScore = .{};
                while (shift <= g.end) : (shift += 1) {
                    var score: SplitScore = .{};
                    scoreAddSplit(measureSplit(lines, shift), &score);
                    scoreAddSplit(measureSplit(lines, shift - groupsize), &score);
                    if (best_shift == -1 or scoreCmp(score, best) <= 0) {
                        best = score;
                        best_shift = shift;
                    }
                }

                while (g.end > best_shift) {
                    std.debug.assert(slideUp(f, ids, &g));
                    std.debug.assert(groupPrevious(other, &go));
                }
            }

            // A run that slid into a neighbour may now hold lines the other
            // side's run also holds, which histogram's anchoring allows and
            // Myers' does not. git diffs the merged pair again, this side
            // first, and so does this.
            if (rediff) |r| {
                if (go.end != go.start and (g.start != g_orig.start or g.end != g_orig.end)) {
                    try fallBack(
                        r.gpa,
                        ids,
                        f,
                        @intCast(g.start),
                        @intCast(g.end - g.start),
                        r.other_ids,
                        other,
                        @intCast(go.start),
                        @intCast(go.end - go.start),
                        r.classes,
                        r.options,
                    );
                }
            }
        }

        if (!groupNext(f, &g)) break;
        std.debug.assert(groupNext(other, &go));
    }

    std.debug.assert(!groupNext(other, &go));
}

//=========================================================================
// The indentation heuristic
//
// Weights from git's xdiff, which got them by fitting a corpus rather than
// by reasoning. Changing any of them changes which line a hunk starts on,
// so they are copied exactly and not tidied.
//=========================================================================

/// An indentation past this is not worth measuring precisely.
const max_indent: i32 = 200;
/// More consecutive blank lines than this all count the same.
const max_blanks: i32 = 20;
const start_of_file_penalty: i32 = 1;
const end_of_file_penalty: i32 = 21;
const total_blank_weight: i32 = -30;
const post_blank_weight: i32 = 6;
const relative_indent_penalty: i32 = -4;
const relative_indent_with_blank_penalty: i32 = 10;
const relative_outdent_penalty: i32 = 24;
const relative_outdent_with_blank_penalty: i32 = 17;
const relative_dedent_penalty: i32 = 23;
const relative_dedent_with_blank_penalty: i32 = 17;
/// How much a lower total indentation outweighs the penalties.
const indent_weight: i32 = 60;
/// A run that could slide further than this is not worth scoring.
const indent_max_sliding: isize = 100;

/// The indentation of `line` in columns, tabs counted to the next multiple
/// of eight. -1 for a line that is blank or all whitespace.
fn getIndent(line: Line) i32 {
    var indent: i32 = 0;
    for (line) |c| {
        if (!isSpace(c)) return indent;
        if (c == ' ') {
            indent += 1;
        } else if (c == '\t') {
            indent += 8 - @rem(indent, 8);
        }
        if (indent >= max_indent) return max_indent;
    }
    return -1;
}

/// What the lines around a candidate boundary look like. `split` is the
/// index of the first line below the boundary, and may be one past the end.
const SplitMeasure = struct {
    end_of_file: bool,
    indent: i32,
    pre_blank: i32,
    pre_indent: i32,
    post_blank: i32,
    post_indent: i32,
};

fn measureSplit(lines: []const Line, split: isize) SplitMeasure {
    const n: isize = @intCast(lines.len);
    var m: SplitMeasure = .{
        .end_of_file = split >= n,
        .indent = if (split >= n) -1 else getIndent(lines[@intCast(split)]),
        .pre_blank = 0,
        .pre_indent = -1,
        .post_blank = 0,
        .post_indent = -1,
    };

    var i = split - 1;
    while (i >= 0) : (i -= 1) {
        m.pre_indent = getIndent(lines[@intCast(i)]);
        if (m.pre_indent != -1) break;
        m.pre_blank += 1;
        if (m.pre_blank == max_blanks) {
            m.pre_indent = 0;
            break;
        }
    }

    i = split + 1;
    while (i < n) : (i += 1) {
        m.post_indent = getIndent(lines[@intCast(i)]);
        if (m.post_indent != -1) break;
        m.post_blank += 1;
        if (m.post_blank == max_blanks) {
            m.post_indent = 0;
            break;
        }
    }

    return m;
}

/// How bad a boundary is. Smaller is better on both counts.
const SplitScore = struct {
    effective_indent: i32 = 0,
    penalty: i32 = 0,
};

fn scoreAddSplit(m: SplitMeasure, s: *SplitScore) void {
    if (m.pre_indent == -1 and m.pre_blank == 0) s.penalty += start_of_file_penalty;
    if (m.end_of_file) s.penalty += end_of_file_penalty;

    const post_blank: i32 = if (m.indent == -1) 1 + m.post_blank else 0;
    const total_blank = m.pre_blank + post_blank;
    s.penalty += total_blank_weight * total_blank;
    s.penalty += post_blank_weight * post_blank;

    const indent = if (m.indent != -1) m.indent else m.post_indent;
    const any_blanks = total_blank != 0;
    s.effective_indent += indent;

    if (indent == -1 or m.pre_indent == -1 or indent == m.pre_indent) {
        // Nothing to say about a boundary that keeps the indentation, ends
        // the file, or starts it.
    } else if (indent > m.pre_indent) {
        s.penalty += if (any_blanks) relative_indent_with_blank_penalty else relative_indent_penalty;
    } else if (m.post_indent != -1 and m.post_indent > indent) {
        // Less indented than what came before but more than what follows:
        // this reads as the start of a block, not the end of one.
        s.penalty += if (any_blanks) relative_outdent_with_blank_penalty else relative_outdent_penalty;
    } else {
        s.penalty += if (any_blanks) relative_dedent_with_blank_penalty else relative_dedent_penalty;
    }
}

/// Negative when `x` is the better boundary. The indentations are compared
/// only by sign, so one column of indentation never outweighs another, but
/// any difference at all outweighs a small penalty.
fn scoreCmp(x: SplitScore, y: SplitScore) i32 {
    const above: i32 = @intFromBool(x.effective_indent > y.effective_indent);
    const below: i32 = @intFromBool(x.effective_indent < y.effective_indent);
    return indent_weight * (above - below) + (x.penalty - y.penalty);
}

/// Read the two flag arrays as one list of changes. The unchanged lines
/// match up one for one, so both sides advance together over them and each
/// change is the run where either side is flagged.
fn buildScript(gpa: Allocator, changed_old: Flags, changed_new: Flags) Allocator.Error![]Change {
    var out: std.ArrayList(Change) = .empty;
    errdefer out.deinit(gpa);

    const len_old: usize = @intCast(changed_old.len);
    const len_new: usize = @intCast(changed_new.len);
    var at_old: usize = 0;
    var at_new: usize = 0;
    while (at_old < len_old or at_new < len_new) {
        const flagged_old = at_old < len_old and changed_old.get(@intCast(at_old));
        const flagged_new = at_new < len_new and changed_new.get(@intCast(at_new));
        if (flagged_old or flagged_new) {
            const from_old = at_old;
            const from_new = at_new;
            while (at_old < len_old and changed_old.get(@intCast(at_old))) at_old += 1;
            while (at_new < len_new and changed_new.get(@intCast(at_new))) at_new += 1;
            try out.append(gpa, .{
                .old_start = from_old,
                .old_count = at_old - from_old,
                .new_start = from_new,
                .new_count = at_new - from_new,
            });
        } else {
            at_old += 1;
            at_new += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

//=========================================================================
// Tests
//=========================================================================

/// Apply `changes` to `old` and return the lines they imply, so a test can
/// say the script means what it claims. The result is the caller's.
fn applyScript(
    gpa: Allocator,
    old: []const Line,
    new: []const Line,
    changes: []const Change,
) Allocator.Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    for (changes) |c| {
        try out.appendSlice(gpa, old[at..c.old_start]);
        try out.appendSlice(gpa, new[c.new_start .. c.new_start + c.new_count]);
        at = c.old_start + c.old_count;
    }
    try out.appendSlice(gpa, old[at..]);
    return out.toOwnedSlice(gpa);
}

fn expectDiff(text_old: []const u8, text_new: []const u8, want: []const Change) !void {
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, text_old);
    defer gpa.free(old);
    const new = try splitLines(gpa, text_new);
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{});
    defer gpa.free(changes);
    try std.testing.expectEqualSlices(Change, want, changes);
}

test "splitLines keeps the newline and keeps a last line without one" {
    const gpa = std.testing.allocator;
    const lines = try splitLines(gpa, "a\nbb\nc");
    defer gpa.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a\n", lines[0]);
    try std.testing.expectEqualStrings("bb\n", lines[1]);
    try std.testing.expectEqualStrings("c", lines[2]);

    const none = try splitLines(gpa, "");
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "identical inputs give no changes" {
    try expectDiff("a\nb\nc\n", "a\nb\nc\n", &.{});
    try expectDiff("", "", &.{});
}

test "a pure insertion" {
    try expectDiff("a\nb\n", "a\nx\nb\n", &.{
        .{ .old_start = 1, .old_count = 0, .new_start = 1, .new_count = 1 },
    });
}

test "a pure deletion" {
    try expectDiff("a\nx\nb\n", "a\nb\n", &.{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0 },
    });
}

test "a replacement is one change, not a delete and an insert apart" {
    try expectDiff("a\nb\nc\n", "a\nB\nc\n", &.{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 },
    });
}

test "an empty side is one whole-file change" {
    try expectDiff("a\nb\n", "", &.{
        .{ .old_start = 0, .old_count = 2, .new_start = 0, .new_count = 0 },
    });
    try expectDiff("", "a\nb\n", &.{
        .{ .old_start = 0, .old_count = 0, .new_start = 0, .new_count = 2 },
    });
}

test "the slide puts a repeated insertion where git puts it" {
    // A naive Myers reports the added "1\n2\n" at the top, because the two
    // scripts are the same length. The slide moves the run past the equal
    // lines, so the pair that reads as added is the second one.
    try expectDiff("1\n2\n3\n", "1\n2\n1\n2\n3\n", &.{
        .{ .old_start = 2, .old_count = 0, .new_start = 2, .new_count = 2 },
    });

    // A deletion has the same freedom and resolves the same way.
    try expectDiff("a\na\na\nb\n", "a\na\nb\n", &.{
        .{ .old_start = 2, .old_count = 1, .new_start = 2, .new_count = 0 },
    });
}

test "the indentation heuristic picks the boundary git picks" {
    // The added block can sit at either of two places: the three lines
    // "a {", "  x", "}" starting at index 3, or the three lines "  x", "}",
    // "a {" starting at index 4. git's heuristic prefers the first, which
    // keeps the brace pair together.
    try expectDiff(
        "a {\n  b\n}\na {\n  c\n}\n",
        "a {\n  b\n}\na {\n  x\n}\na {\n  c\n}\n",
        &.{.{ .old_start = 3, .old_count = 0, .new_start = 3, .new_count = 3 }},
    );

    // With the heuristic off the run slides as far down as it will go,
    // which is what `git diff --no-indent-heuristic` shows.
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "a {\n  b\n}\na {\n  c\n}\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "a {\n  b\n}\na {\n  x\n}\na {\n  c\n}\n");
    defer gpa.free(new);
    const plain = try diffLines(gpa, old, new, .{ .indent_heuristic = false });
    defer gpa.free(plain);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .old_start = 4, .old_count = 0, .new_start = 4, .new_count = 3 },
    }, plain);
}

test "a trailing insertion stays at the end" {
    try expectDiff("a\nb\n", "a\nb\nc\n", &.{
        .{ .old_start = 2, .old_count = 0, .new_start = 2, .new_count = 1 },
    });
}

test "a leading insertion stays at the start" {
    try expectDiff("b\nc\n", "a\nb\nc\n", &.{
        .{ .old_start = 0, .old_count = 0, .new_start = 0, .new_count = 1 },
    });
}

test "hunks merge when their context touches and split when it does not" {
    const gpa = std.testing.allocator;
    var text_old: std.Io.Writer.Allocating = .init(gpa);
    defer text_old.deinit();
    var text_new: std.Io.Writer.Allocating = .init(gpa);
    defer text_new.deinit();
    for (0..30) |i| {
        try text_old.writer.print("{d}\n", .{i});
        // Lines 2 and 8 change: five unchanged lines between them, which
        // three lines of context on each side covers, so they are one hunk.
        // Line 25 is far away and is a hunk of its own.
        if (i == 2 or i == 8 or i == 25) {
            try text_new.writer.print("x{d}\n", .{i});
        } else {
            try text_new.writer.print("{d}\n", .{i});
        }
    }
    const old = try splitLines(gpa, text_old.written());
    defer gpa.free(old);
    const new = try splitLines(gpa, text_new.written());
    defer gpa.free(new);

    const changes = try diffLines(gpa, old, new, .{});
    defer gpa.free(changes);
    try std.testing.expectEqual(@as(usize, 3), changes.len);

    const merged = try hunks(gpa, changes, old.len, new.len, .{ .context = 3 });
    defer gpa.free(merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(@as(usize, 2), merged[0].changes.len);
    try std.testing.expectEqual(@as(usize, 0), merged[0].old_start);
    try std.testing.expectEqual(@as(usize, 12), merged[0].old_count);
    try std.testing.expectEqual(@as(usize, 1), merged[1].changes.len);
    try std.testing.expectEqual(@as(usize, 22), merged[1].old_start);
    try std.testing.expectEqual(@as(usize, 7), merged[1].old_count);

    // One line of context leaves the first two changes too far apart.
    const narrow = try hunks(gpa, changes, old.len, new.len, .{ .context = 1 });
    defer gpa.free(narrow);
    try std.testing.expectEqual(@as(usize, 3), narrow.len);
}

test "hunks clamp their context at both ends of the file" {
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "a\nb\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "A\nb\n");
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{});
    defer gpa.free(changes);
    const h = try hunks(gpa, changes, old.len, new.len, .{ .context = 3 });
    defer gpa.free(h);
    try std.testing.expectEqual(@as(usize, 1), h.len);
    try std.testing.expectEqual(@as(usize, 0), h[0].old_start);
    try std.testing.expectEqual(@as(usize, 2), h[0].old_count);
    try std.testing.expectEqual(@as(usize, 0), h[0].new_start);
    try std.testing.expectEqual(@as(usize, 2), h[0].new_count);
}

test "whitespace options change what counts as equal" {
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "a\nb  \nc\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "a\nb\nc\n");
    defer gpa.free(new);

    const plain = try diffLines(gpa, old, new, .{});
    defer gpa.free(plain);
    try std.testing.expectEqual(@as(usize, 1), plain.len);

    const relaxed = try diffLines(gpa, old, new, .{ .ignore_trailing_whitespace = true });
    defer gpa.free(relaxed);
    try std.testing.expectEqual(@as(usize, 0), relaxed.len);

    const inner_old = try splitLines(gpa, "a\nx    y\n");
    defer gpa.free(inner_old);
    const inner_new = try splitLines(gpa, "a\nx y\n");
    defer gpa.free(inner_new);
    const inner = try diffLines(gpa, inner_old, inner_new, .{ .ignore_whitespace_change = true });
    defer gpa.free(inner);
    try std.testing.expectEqual(@as(usize, 0), inner.len);

    const all_old = try splitLines(gpa, "\ta b\n");
    defer gpa.free(all_old);
    const all_new = try splitLines(gpa, "ab\n");
    defer gpa.free(all_new);
    const all = try diffLines(gpa, all_old, all_new, .{ .ignore_all_whitespace = true });
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 0), all.len);
}

test "a changed range still indexes the real lines under a whitespace option" {
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "a  \nb\nc\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "a\nB\nc\n");
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{ .ignore_trailing_whitespace = true });
    defer gpa.free(changes);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 },
    }, changes);
    try std.testing.expectEqualStrings("b\n", old[changes[0].old_start]);
}

test "histogram agrees with myers on a plain replacement" {
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "a\nb\nc\nd\ne\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "a\nb\nX\nd\ne\n");
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{ .algorithm = .histogram });
    defer gpa.free(changes);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .old_start = 2, .old_count = 1, .new_start = 2, .new_count = 1 },
    }, changes);
}

test "histogram falls back to myers where no line is rare enough" {
    const gpa = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..200) |_| try text.writer.writeAll("x\n");
    const old = try splitLines(gpa, text.written());
    defer gpa.free(old);
    const new = try splitLines(gpa, text.written()[0 .. text.written().len - 2]);
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{ .algorithm = .histogram });
    defer gpa.free(changes);
    const s = stat(changes);
    try std.testing.expectEqual(@as(usize, 1), s.minus);
    try std.testing.expectEqual(@as(usize, 0), s.plus);
}

test "minimal and the give-up heuristics can part company" {
    const gpa = std.testing.allocator;
    var text_old: std.Io.Writer.Allocating = .init(gpa);
    defer text_old.deinit();
    var text_new: std.Io.Writer.Allocating = .init(gpa);
    defer text_new.deinit();
    // Long enough, and noisy enough, that the search passes the cost at
    // which git stops proving the script minimal.
    var seed: u64 = 1;
    for (0..1500) |i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        try text_old.writer.print("line {d} {d}\n", .{ i, seed >> 60 });
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        try text_new.writer.print("line {d} {d}\n", .{ i, seed >> 60 });
    }
    const old = try splitLines(gpa, text_old.written());
    defer gpa.free(old);
    const new = try splitLines(gpa, text_new.written());
    defer gpa.free(new);

    const heuristic = try diffLines(gpa, old, new, .{});
    defer gpa.free(heuristic);
    const exact = try diffLines(gpa, old, new, .{ .minimal = true });
    defer gpa.free(exact);

    // Both describe the same new file.
    for ([2][]const Change{ heuristic, exact }) |changes| {
        const applied = try applyScript(gpa, old, new, changes);
        defer gpa.free(applied);
        try std.testing.expectEqual(new.len, applied.len);
        for (new, applied) |want, got| try std.testing.expectEqualStrings(want, got);
    }
    // The minimal one removes and adds no more than the heuristic one.
    try std.testing.expect(stat(exact).plus <= stat(heuristic).plus);
}

test "a noisy file keeps its shared lines as context" {
    const gpa = std.testing.allocator;
    var text_old: std.Io.Writer.Allocating = .init(gpa);
    defer text_old.deinit();
    var text_new: std.Io.Writer.Allocating = .init(gpa);
    defer text_new.deinit();
    // Every third line is blank and shared; the rest match nothing on the
    // other side. git reports twenty small changes rather than one block,
    // and it only does so because the blank lines survive the pruning that
    // sets aside lines with no counterpart.
    for (0..60) |i| {
        if (i % 3 == 0) {
            try text_old.writer.writeAll("\n");
            try text_new.writer.writeAll("\n");
        } else {
            try text_old.writer.print("{s}\n", .{if (i % 2 == 1) "a" else "b"});
            try text_new.writer.print("{s}\n", .{if (i % 2 == 1) "x" else "y"});
        }
    }
    const old = try splitLines(gpa, text_old.written());
    defer gpa.free(old);
    const new = try splitLines(gpa, text_new.written());
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{});
    defer gpa.free(changes);
    try std.testing.expectEqual(@as(usize, 20), changes.len);
    for (changes) |c| {
        try std.testing.expectEqual(@as(usize, 2), c.old_count);
        try std.testing.expectEqual(@as(usize, 2), c.new_count);
    }
}

test "max_work falls back to one delete and one insert" {
    const gpa = std.testing.allocator;
    var text_old: std.Io.Writer.Allocating = .init(gpa);
    defer text_old.deinit();
    var text_new: std.Io.Writer.Allocating = .init(gpa);
    defer text_new.deinit();
    // Every line appears on both sides, so none of them can be set aside
    // before the search; rotating the file is then real work for Myers.
    for (0..200) |i| try text_old.writer.print("line {d}\n", .{i});
    for (0..200) |i| try text_new.writer.print("line {d}\n", .{(i + 100) % 200});
    const old = try splitLines(gpa, text_old.written());
    defer gpa.free(old);
    const new = try splitLines(gpa, text_new.written());
    defer gpa.free(new);

    const capped = try diffLines(gpa, old, new, .{ .max_work = 1 });
    defer gpa.free(capped);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .old_start = 0, .old_count = 200, .new_start = 0, .new_count = 200 },
    }, capped);

    // Uncapped the same inputs take more than one run to describe.
    const full = try diffLines(gpa, old, new, .{});
    defer gpa.free(full);
    try std.testing.expect(full.len > 1);
    try std.testing.expect(stat(full).plus < 200);

    // A cap the search never reaches leaves the script untouched.
    const generous = try diffLines(gpa, old, new, .{ .max_work = 1_000_000 });
    defer gpa.free(generous);
    try std.testing.expectEqualSlices(Change, full, generous);
}

test "a capped script still reproduces the new side" {
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "a\nb\nc\nd\ne\nf\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "a\nq\nc\nr\ne\ns\n");
    defer gpa.free(new);
    const changes = try diffLines(gpa, old, new, .{ .max_work = 1 });
    defer gpa.free(changes);
    const applied = try applyScript(gpa, old, new, changes);
    defer gpa.free(applied);
    try std.testing.expectEqual(new.len, applied.len);
    for (new, applied) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "stat counts both sides of every run" {
    try std.testing.expectEqual(Stat{ .plus = 0, .minus = 0 }, stat(&.{}));
    try std.testing.expectEqual(Stat{ .plus = 5, .minus = 3 }, stat(&.{
        .{ .old_start = 0, .old_count = 3, .new_start = 0, .new_count = 2 },
        .{ .old_start = 9, .old_count = 0, .new_start = 8, .new_count = 3 },
    }));
}

test "isBinary looks only at the first eight thousand bytes" {
    try std.testing.expect(!isBinary(""));
    try std.testing.expect(!isBinary("plain text\n"));
    try std.testing.expect(isBinary("a\x00b"));

    var buf: [9000]u8 = undefined;
    @memset(&buf, 'a');
    buf[7999] = 0;
    try std.testing.expect(isBinary(&buf));
    @memset(&buf, 'a');
    buf[8000] = 0;
    try std.testing.expect(!isBinary(&buf));
}

test "fuzz: any two inputs diff without a crash or a hang" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const a = a_buf[0..smith.slice(&a_buf)];
    const b = b_buf[0..smith.slice(&b_buf)];
    const old = try splitLines(gpa, a);
    defer gpa.free(old);
    const new = try splitLines(gpa, b);
    defer gpa.free(new);
    for ([_]Algorithm{ .myers, .histogram, .patience }) |algorithm| {
        const changes = try diffLines(gpa, old, new, .{ .algorithm = algorithm });
        defer gpa.free(changes);

        // Applying the script to `old` must reproduce `new`.
        const applied = try applyScript(gpa, old, new, changes);
        defer gpa.free(applied);
        try std.testing.expectEqual(new.len, applied.len);
        for (new, applied) |want, got| try std.testing.expectEqualStrings(want, got);

        // The runs rise, never touch, and stay inside both files.
        var previous_old: usize = 0;
        var previous_new: usize = 0;
        for (changes, 0..) |c, i| {
            try std.testing.expect(c.old_count != 0 or c.new_count != 0);
            try std.testing.expect(c.old_start + c.old_count <= old.len);
            try std.testing.expect(c.new_start + c.new_count <= new.len);
            if (i > 0) {
                try std.testing.expect(c.old_start > previous_old);
                try std.testing.expect(c.new_start > previous_new);
            }
            previous_old = c.old_start + c.old_count;
            previous_new = c.new_start + c.new_count;
        }

        const h = try hunks(gpa, changes, old.len, new.len, .{ .algorithm = algorithm });
        defer gpa.free(h);
        var covered: usize = 0;
        for (h) |one| {
            try std.testing.expect(one.old_start + one.old_count <= old.len);
            try std.testing.expect(one.new_start + one.new_count <= new.len);
            covered += one.changes.len;
        }
        try std.testing.expectEqual(changes.len, covered);
    }

    // The other three ways of taking the same diff must also round trip.
    for ([_]Options{
        .{ .minimal = true },
        .{ .indent_heuristic = false },
        .{ .ignore_all_whitespace = true },
    }) |options| {
        const changes = try diffLines(gpa, old, new, options);
        defer gpa.free(changes);
        const applied = try applyScript(gpa, old, new, changes);
        defer gpa.free(applied);
        try std.testing.expectEqual(new.len, applied.len);
    }
}
