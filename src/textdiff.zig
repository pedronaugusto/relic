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
//! The histogram algorithm is here too. It is not asked to agree with Myers,
//! only to be correct and to give the same answer every time.
//!
//! Nothing in this file opens a file or reads an object: it takes bytes and
//! gives back indices.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Which algorithm produces the edit script.
pub const Algorithm = enum { myers, histogram };

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
};

/// The edit script between two line lists: the runs that differ, in order,
/// with matching lines between them. The result is the caller's.
pub fn diffLines(
    gpa: Allocator,
    old: []const Line,
    new: []const Line,
    options: Options,
) Allocator.Error![]Change {
    const ids = try classify(gpa, old, new, options);
    defer gpa.free(ids);
    const a = ids[0..old.len];
    const b = ids[old.len..];

    const changed_old = try Flags.init(gpa, old.len);
    defer changed_old.deinit(gpa);
    const changed_new = try Flags.init(gpa, new.len);
    defer changed_new.deinit(gpa);

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

    // One diagonal per possible value of x - y, plus a sentinel diagonal at
    // each end that the sweep writes its out-of-box marker into.
    const ndiags = a.len + b.len + 3;
    const kvd = try gpa.alloc(isize, 2 * ndiags);
    defer gpa.free(kvd);
    var search: Search = .{
        .a = a,
        .b = b,
        .changed_a = changed_old,
        .changed_b = changed_new,
        .forward = kvd[0..ndiags],
        .backward = kvd[ndiags..],
        .diag_bias = @as(isize, @intCast(b.len)) + 1,
        .max_cost = @max(max_cost_min, bogosqrt(ndiags)),
        .work = 0,
        .max_work = options.max_work,
    };

    switch (options.algorithm) {
        .myers => search.myers(start, end_old, start, end_new, options.minimal),
        .histogram => try search.histogram(gpa, start, end_old, start, end_new, options.minimal),
    }

    compact(changed_old, a, old, changed_new, options.indent_heuristic);
    compact(changed_new, b, new, changed_old, options.indent_heuristic);

    return buildScript(gpa, changed_old, changed_new);
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

/// The similarity of two blobs as a percentage, 0 to 100, using git's own
/// counting: the shared material over the larger size. Used by rename
/// detection and nothing else.
///
/// The count is over chunks, not lines: a chunk ends at a newline or after
/// sixty-four bytes, whichever comes first, so a file that is one enormous
/// line still splits into pieces and the comparison stays linear.
pub fn similarity(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error!u8 {
    const biggest = @max(a.len, b.len);
    if (biggest == 0) return 100;

    var table: std.AutoHashMapUnmanaged(u64, [2]usize) = .empty;
    defer table.deinit(gpa);

    for ([2][]const u8{ a, b }, 0..) |bytes, side| {
        var at: usize = 0;
        while (at < bytes.len) {
            const chunk = bytes[at..chunkEnd(bytes, at)];
            at += chunk.len;
            const gop = try table.getOrPut(gpa, std.hash.Wyhash.hash(0, chunk));
            if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0 };
            gop.value_ptr.*[side] += chunk.len;
        }
    }

    var shared: usize = 0;
    var it = table.valueIterator();
    while (it.next()) |v| shared += @min(v[0], v[1]);
    return @intCast(@min(100, shared * 100 / biggest));
}

/// Where the chunk starting at `at` ends: after a newline, or after
/// sixty-four bytes, or at the end of the blob.
fn chunkEnd(bytes: []const u8, at: usize) usize {
    const limit = @min(bytes.len, at + 64);
    var i = at;
    while (i < limit) : (i += 1) {
        if (bytes[i] == '\n') return i + 1;
    }
    return limit;
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
/// new.len` entries. The result is the caller's.
fn classify(gpa: Allocator, old: []const Line, new: []const Line, options: Options) Allocator.Error![]u32 {
    const total = old.len + new.len;
    const ids = try gpa.alloc(u32, total);
    errdefer gpa.free(ids);
    if (total == 0) return ids;

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
    return ids;
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

    fn setRange(f: Flags, from: usize, to: usize) void {
        @memset(f.raw[from + 1 .. to + 1], 1);
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

    /// Mark everything in both regions changed. Always a correct script,
    /// and the one the work cap falls back to.
    fn markAll(s: *Search, off1: usize, lim1: usize, off2: usize, lim2: usize) void {
        s.changed_a.setRange(off1, lim1);
        s.changed_b.setRange(off2, lim2);
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
            s.changed_b.setRange(off2, lim2);
            return;
        }
        if (off2 == lim2) {
            s.changed_a.setRange(off1, lim1);
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

    //=====================================================================
    // Histogram
    //=====================================================================

    /// The longest common run in a box, anchored on the rarest line
    /// available, recursing on what is left either side of it. A region
    /// whose only common lines are too common to anchor anything goes to
    /// Myers instead.
    fn histogram(
        s: *Search,
        gpa: Allocator,
        off1: usize,
        lim1: usize,
        off2: usize,
        lim2: usize,
        need_min: bool,
    ) Allocator.Error!void {
        if (off1 == lim1) {
            s.changed_b.setRange(off2, lim2);
            return;
        }
        if (off2 == lim2) {
            s.changed_a.setRange(off1, lim1);
            return;
        }

        // A line repeated more than this in one region anchors nothing: the
        // scan that would follow every occurrence costs more than the better
        // script is worth, which is where git hands the region to Myers.
        const max_chain = 64;

        const n1 = lim1 - off1;
        const next = try gpa.alloc(u32, n1);
        defer gpa.free(next);
        var first: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer first.deinit(gpa);
        var last: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer last.deinit(gpa);
        var count: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer count.deinit(gpa);

        const no_next = std.math.maxInt(u32);
        for (off1..lim1) |i| {
            const id = s.a[i];
            next[i - off1] = no_next;
            const gop = try count.getOrPut(gpa, id);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
                next[last.get(id).? - off1] = @intCast(i);
            } else {
                gop.value_ptr.* = 1;
                try first.put(gpa, id, @intCast(i));
            }
            try last.put(gpa, id, @intCast(i));
        }

        var best: ?struct { as: usize, ae: usize, bs: usize, be: usize } = null;
        var best_len: usize = 0;
        var best_count: u32 = std.math.maxInt(u32);
        var has_common = false;
        var too_common = false;

        var b = off2;
        scan: while (b < lim2) {
            var b_next = b + 1;
            var cursor = first.get(s.b[b]);
            while (cursor) |a_at| {
                const a: usize = a_at;
                cursor = if (next[a - off1] == no_next) null else next[a - off1];
                has_common = true;
                const occurrences = count.get(s.b[b]).?;
                if (occurrences > max_chain) {
                    too_common = true;
                    break :scan;
                }

                var as = a;
                var bs = b;
                while (as > off1 and bs > off2 and s.a[as - 1] == s.b[bs - 1]) {
                    as -= 1;
                    bs -= 1;
                }
                var ae = a;
                var be = b;
                while (ae + 1 < lim1 and be + 1 < lim2 and s.a[ae + 1] == s.b[be + 1]) {
                    ae += 1;
                    be += 1;
                }
                var rarest = occurrences;
                for (as..ae + 1) |x| rarest = @min(rarest, count.get(s.a[x]).?);

                if (be + 1 > b_next) b_next = be + 1;
                const len = ae - as + 1;
                if (len > best_len or rarest < best_count) {
                    best = .{ .as = as, .ae = ae, .bs = bs, .be = be };
                    best_len = len;
                    best_count = rarest;
                }
            }
            b = b_next;
        }

        if (!has_common) {
            s.markAll(off1, lim1, off2, lim2);
            return;
        }
        if (too_common or best == null) {
            s.myers(off1, lim1, off2, lim2, need_min);
            return;
        }
        const lcs = best.?;
        try s.histogram(gpa, off1, lcs.as, off2, lcs.bs, need_min);
        try s.histogram(gpa, lcs.ae + 1, lim1, lcs.be + 1, lim2, need_min);
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
fn compact(f: Flags, ids: []const u32, lines: []const Line, other: Flags, indent_heuristic: bool) void {
    var g = groupInit(f);
    var go = groupInit(other);

    while (true) {
        if (g.end != g.start) {
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
    // Both placements of the added line are the same length; git's
    // heuristic keeps the added call inside the block it belongs to rather
    // than letting it slide past the closing brace.
    try expectDiff(
        "fn a() {\n    one();\n}\n\nfn b() {\n    one();\n}\n",
        "fn a() {\n    one();\n    two();\n}\n\nfn b() {\n    one();\n}\n",
        &.{.{ .old_start = 2, .old_count = 0, .new_start = 2, .new_count = 1 }},
    );

    // With the heuristic off the same run slides all the way down, which is
    // what `git diff --no-indent-heuristic` shows.
    const gpa = std.testing.allocator;
    const old = try splitLines(gpa, "fn a() {\n    one();\n}\n\nfn b() {\n    one();\n}\n");
    defer gpa.free(old);
    const new = try splitLines(gpa, "fn a() {\n    one();\n    two();\n}\n\nfn b() {\n    one();\n}\n");
    defer gpa.free(new);
    const plain = try diffLines(gpa, old, new, .{ .indent_heuristic = false });
    defer gpa.free(plain);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .old_start = 5, .old_count = 0, .new_start = 5, .new_count = 1 },
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
    try std.testing.expectEqual(@as(usize, 6), merged[1].old_count);

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

test "max_work falls back to one delete and one insert" {
    const gpa = std.testing.allocator;
    var text_old: std.Io.Writer.Allocating = .init(gpa);
    defer text_old.deinit();
    var text_new: std.Io.Writer.Allocating = .init(gpa);
    defer text_new.deinit();
    for (0..200) |i| {
        try text_old.writer.print("old line {d}\n", .{i});
        try text_new.writer.print("new line {d}\n", .{i * 7});
    }
    const old = try splitLines(gpa, text_old.written());
    defer gpa.free(old);
    const new = try splitLines(gpa, text_new.written());
    defer gpa.free(new);

    const capped = try diffLines(gpa, old, new, .{ .max_work = 1 });
    defer gpa.free(capped);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .old_start = 0, .old_count = 200, .new_start = 0, .new_count = 200 },
    }, capped);

    // Uncapped the same inputs take many more runs to describe.
    const full = try diffLines(gpa, old, new, .{});
    defer gpa.free(full);
    try std.testing.expect(full.len > 1);

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

test "similarity of identical, disjoint and half shared blobs" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(u8, 100), try similarity(gpa, "", ""));
    try std.testing.expectEqual(@as(u8, 100), try similarity(gpa, "a\nb\nc\n", "a\nb\nc\n"));
    try std.testing.expectEqual(@as(u8, 0), try similarity(gpa, "aaaa\n", "bbbb\n"));
    try std.testing.expectEqual(@as(u8, 0), try similarity(gpa, "a\nb\n", ""));
    try std.testing.expectEqual(@as(u8, 50), try similarity(gpa, "1\n2\n3\n4\n", "1\n2\nX\nY\n"));

    // Longer on one side: the shared half is measured against the larger.
    try std.testing.expectEqual(@as(u8, 50), try similarity(gpa, "1\n2\n", "1\n2\nX\nY\n"));
}

test "similarity is not quadratic in one long line" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big);
    @memset(big, 'z');
    try std.testing.expectEqual(@as(u8, 100), try similarity(gpa, big, big));
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
    for ([_]Algorithm{ .myers, .histogram }) |algorithm| {
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
