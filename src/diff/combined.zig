//! The combined diff of a merge: its result against every parent at once,
//! as git 2.55's `combine-diff.c` writes it for `git diff-tree -c` and
//! `--cc`, `git show` of a merge, and `git log` under `--diff-merges=c` or
//! `cc`.
//!
//! A path is in it when the result differs from every parent there
//! (`paths`): each parent's diff against the result is made apart, renames
//! and all where the caller asks for them, and only what every one of them
//! changed is kept, in the first parent's order. A path's patch has a
//! column for each parent: a line the result added against parent `n` has
//! `+` in column `n`, a line parent `n` had and the result lost has `-`
//! there, and lost lines that several parents had are written once, the
//! parents' lost runs merged by their longest common subsequence as git's
//! `coalesce_lines` merges them. Hunks take git's context; `--cc` (dense)
//! further drops a hunk where the result took one parent's version
//! whole, so what is left is where the merge did something of its own.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const parallax = @import("parallax");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const attributes = @import("../patterns.zig").attributes;
const ctype = @import("../text.zig").ctype;
const color = @import("../config/color.zig");
const diff = @import("diff.zig");
const driver_mod = @import("driver.zig");
const textconv_mod = @import("textconv.zig");
const labels = @import("labels.zig");
const paint = @import("paint.zig");

const Oid = hash.Oid;

/// Errors from a combined diff.
pub const Error = error{
    /// More parents than the line masks hold: git's masks are a machine
    /// word with two bits besides the parents', which a merge of 63
    /// parents or more overruns.
    TooManyParents,
    /// A side named something that is not a blob, which git dies on.
    NotABlob,
} || diff.Error || diff.TextError || textconv_mod.Error || driver_mod.Error || attributes.Error || Io.Writer.Error;

/// The most parents a combined diff takes.
pub const max_parents = 62;

/// One parent's side of a path.
pub const Parent = struct {
    /// How the parent's diff against the result has the path: `added`
    /// where the parent lacks it, `renamed` or `copied` where its file
    /// went there under another name.
    status: diff.Status,
    /// The parent's own path for it, the result's but for a rename or a
    /// copy.
    path: []const u8,
    /// `null` where the parent lacks the path.
    mode: ?object.Mode,
    /// The zero name where the parent lacks the path.
    oid: Oid,
};

/// A path the result changed against every parent.
pub const Path = struct {
    path: []const u8,
    /// `null` where the result deleted the path.
    mode: ?object.Mode,
    /// The zero name where the result deleted the path.
    oid: Oid,
    parents: []Parent,
};

/// A merge's combined paths, from `paths`.
pub const Paths = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    items: []Path,

    /// Release everything.
    pub fn deinit(p: *Paths) void {
        var arena = p.arena.promote(p.gpa);
        arena.deinit();
        p.* = undefined;
    }
};

/// The trees compared: the merge's and its parents', in order.
pub const Inputs = struct { result: Oid, parents: []const Oid };

/// The paths the result changed against every parent, as git's
/// `find_paths_generic` finds them: each parent's diff against the result
/// by `options` -- its renames, prefix and pathspec; every subtree is
/// entered and none listed -- intersected in the order of the first, the
/// order file applied last. With no renames this is what git's walk of all
/// the trees at once (`find_paths_multitree`) finds.
pub fn paths(gpa: Allocator, io: Io, db: *odb_mod.Odb, inputs: Inputs, options: diff.TreeOptions) Self.Error!Paths {
    const n_parents = inputs.parents.len;
    if (n_parents > max_parents) return error.TooManyParents;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var each = options;
    each.order = .{};
    each.trees = false;
    each.max_depth = null;
    var list: std.ArrayList(Path) = .empty;
    for (inputs.parents, 0..) |parent, n| {
        var changes = try diff.tree(gpa, io, db, .{ .old = parent, .new = inputs.result }, each);
        defer changes.deinit();
        if (n == 0) {
            for (changes.items) |change| {
                if (unmodified(change)) continue;
                const parents = try arena.alloc(Parent, n_parents);
                parents[0] = try parentOf(arena, db, change);
                try list.append(arena, .{
                    .path = try arena.dupe(u8, change.path()),
                    .mode = if (change.new) |e| e.mode else null,
                    .oid = if (change.new) |e| e.oid else Oid.zero(db.objectFormat()),
                    .parents = parents,
                });
            }
            continue;
        }
        // Both lists in tree order: keep what this diff has too.
        var kept: usize = 0;
        var i: usize = 0;
        for (list.items) |p| {
            while (true) {
                const order: std.math.Order = if (i >= changes.items.len) .lt else std.mem.order(u8, p.path, changes.items[i].path());
                switch (order) {
                    .lt => break,
                    .gt => i += 1,
                    .eq => {
                        p.parents[n] = try parentOf(arena, db, changes.items[i]);
                        list.items[kept] = p;
                        kept += 1;
                        i += 1;
                        break;
                    },
                }
            }
        }
        list.items.len = kept;
    }
    try applyOrder(arena, options.order, list.items);
    return .{ .gpa = gpa, .arena = arena_instance.state, .items = list.items };
}

/// git's `diff_unmodified_pair` for a pair of a tree diff.
fn unmodified(change: diff.Change) bool {
    const old = change.old orelse return false;
    const new = change.new orelse return false;
    return old.mode == new.mode and std.mem.eql(u8, old.path, new.path) and old.oid.eql(new.oid);
}

fn parentOf(arena: Allocator, db: *odb_mod.Odb, change: diff.Change) Allocator.Error!Parent {
    const old = change.old orelse return .{ .status = change.status, .path = try arena.dupe(u8, change.path()), .mode = null, .oid = Oid.zero(db.objectFormat()) };
    return .{ .status = change.status, .path = try arena.dupe(u8, old.path), .mode = old.mode, .oid = old.oid };
}

/// The order file's order, stable, as git's `order_objects` sorts.
fn applyOrder(arena: Allocator, order: diff.Order, items: []Path) Allocator.Error!void {
    if (order.patterns.len == 0 or items.len < 2) return;
    const Ranked = struct { rank: usize, path: Path };
    const ranked = try arena.alloc(Ranked, items.len);
    for (items, ranked) |p, *r| r.* = .{ .rank = try order.rank(arena, p.path), .path = p };
    std.sort.block(Ranked, ranked, {}, struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            return a.rank < b.rank;
        }
    }.less);
    for (items, ranked) |*p, r| p.* = r.path;
}

/// Where a combined diff's sides are read, and how they are converted.
pub const WriteInputs = struct {
    db: *odb_mod.Odb,
    paths: []const Path,
    /// The driver a path names by its `diff` attribute, which says whether
    /// it is binary and what converts it; git asks it of the result's
    /// path for every side.
    drivers: driver_mod.Drivers = .{},
    /// `--textconv`, as `UnifiedInputs.textconv`: every side of a path
    /// whose driver has a `textconv` is the program's text, and the path
    /// is never binary.
    textconv: ?*const textconv_mod.Textconv = null,
};

/// How a combined diff is written.
pub const Options = struct {
    /// The content diff each parent's lines are found by -- its algorithm,
    /// what whitespace it overlooks, the indent heuristic -- the context
    /// around a hunk, the `index` line's names, the prefixes of the `---`
    /// and `+++` lines, the quoting of paths and the colours.
    diff: diff.Options = .{},
    /// `--cc` rather than `-c`: a hunk where the result is one parent's
    /// version, or where all parents but one agree and the result takes
    /// theirs, is left out, and a path left with no hunk and no change of
    /// mode is not written at all.
    dense: bool = true,
    /// `--combined-all-paths`: a `---` line for each parent, under its own
    /// path where it renamed the file.
    all_paths: bool = false,
};

/// Append the combined diff of `inputs.paths` to `w`, a path after
/// another, as git's `show_patch_diff` writes each.
pub fn write(gpa: Allocator, io: Io, w: *Io.Writer, inputs: WriteInputs, options: Options) Self.Error!void {
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    for (inputs.paths) |p| {
        if (p.parents.len > max_parents) return error.TooManyParents;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var file: File = .{ .a = arena.allocator(), .io = io, .inputs = inputs, .options = options, .differ = &differ, .path = p };
        try file.write(w);
    }
}

/// One path of a combined diff while it is written.
const File = struct {
    a: Allocator,
    io: Io,
    inputs: WriteInputs,
    options: Options,
    differ: *parallax.Differ,
    path: Path,

    fn write(f: *File, w: *Io.Writer) Self.Error!void {
        const p = f.path;
        const config = f.inputs.drivers.config;
        const driver = (try f.inputs.drivers.ofPath(f.a, f.io, p.path)) orelse driver_mod.Driver{ .named = "default" };
        const conversion: ?driver_mod.Conversion = if (f.inputs.textconv != null) try driver.conversion(config) else null;
        const result = try f.side(p.oid, p.mode, conversion);
        var mode_differs = false;
        for (p.parents) |parent| {
            if (modeBits(parent.mode) != modeBits(p.mode)) mode_differs = true;
        }
        if (try f.binary(driver, conversion, result)) {
            try f.writeHeader(w, mode_differs, false);
            return w.writeAll("Binary files differ\n");
        }
        var lines = try Lines.init(f.a, result, p.parents.len);
        for (p.parents, 0..) |parent, n| {
            const earlier = for (p.parents[0..n], 0..) |other, j| {
                if (other.oid.eql(parent.oid)) break j;
            } else null;
            if (earlier) |j| {
                lines.reuse(n, j);
            } else {
                const text = try f.side(parent.oid, parent.mode, conversion);
                try lines.combine(f.a, f.differ, text, n, f.options.diff);
            }
        }
        const context = f.options.diff.context;
        const show_hunks = lines.makeHunks(context, f.options.dense);
        if (!show_hunks and !mode_differs) return;
        try f.writeHeader(w, mode_differs, true);
        try lines.dump(w, context, f.options.diff.colors);
    }

    /// A side's text, as git's `grab_blob` reads it: a gitlink as its
    /// `Subproject commit` line, a side that is not there empty, otherwise
    /// the blob or, with a conversion, its program's text.
    fn side(f: *File, oid: Oid, mode: ?object.Mode, conversion: ?driver_mod.Conversion) Self.Error![]const u8 {
        if (mode == .gitlink) {
            var buf: [labels.gitlink_text_max]u8 = undefined;
            return f.a.dupe(u8, labels.gitlinkText(&buf, oid));
        }
        if (oid.isZero()) return "";
        const db = f.inputs.db;
        const found = try db.read(f.io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .blob) return error.NotABlob;
        const bytes = try f.a.dupe(u8, found.bytes);
        const c = conversion orelse return bytes;
        return f.inputs.textconv.?.convert(f.a, f.io, .{ .conversion = c, .path = f.path.path, .blob = oid, .bytes = bytes });
    }

    /// Whether the path is binary: never with a conversion; as its driver
    /// says, where it says; else where the result or any parent has a NUL
    /// near its start.
    fn binary(f: *File, driver: driver_mod.Driver, conversion: ?driver_mod.Conversion, result: []const u8) Self.Error!bool {
        if (conversion != null) return false;
        if (try driver.says(f.inputs.drivers.config)) |says| return says;
        if (diff.isBinary(result)) return true;
        for (f.path.parents) |parent| {
            if (diff.isBinary(try f.side(parent.oid, parent.mode, null))) return true;
        }
        return false;
    }

    /// git's `show_combined_header`: `diff --cc` or `diff --combined`, the
    /// `index` line naming every parent's object, the modes where any
    /// differs, and with `files` the `---` and `+++` lines.
    fn writeHeader(f: *File, w: *Io.Writer, mode_differs: bool, files: bool) Self.Error!void {
        const p = f.path;
        const o = f.options.diff;
        const colors = o.colors;
        const name = try labels.quoteTwo(f.a, "", p.path, o.quote_path);
        try paint.writeMeta(w, colors, "{s}{s}", .{ if (f.options.dense) "diff --cc " else "diff --combined ", name });
        const meta = if (colors) |c| c.meta.bytes() else "";
        const reset = if (colors != null) color.reset else "";
        try w.print("{s}index ", .{meta});
        var hex: [hash.max_hex_len]u8 = undefined;
        for (p.parents, 0..) |parent, i| {
            try w.print("{s}{s}", .{ if (i != 0) "," else "", try labels.abbreviated(f.io, f.inputs.db, parent.oid, o.abbrev, o.full_index, &hex) });
        }
        try w.print("..{s}{s}\n", .{ try labels.abbreviated(f.io, f.inputs.db, p.oid, o.abbrev, o.full_index, &hex), reset });

        const deleted = p.mode == null;
        // It was added if no parent had it.
        var added = false;
        if (mode_differs) {
            added = !deleted;
            for (p.parents) |parent| {
                if (parent.status != .added) added = false;
            }
            if (added) {
                try w.print("{s}new file mode {o:0>6}", .{ meta, modeBits(p.mode) });
            } else {
                // git paints the line only when it starts with `deleted file`.
                if (deleted) try w.print("{s}deleted file ", .{meta});
                try w.writeAll("mode ");
                for (p.parents, 0..) |parent, i| try w.print("{s}{o:0>6}", .{ if (i != 0) "," else "", modeBits(parent.mode) });
                if (p.mode) |m| try w.print("..{o:0>6}", .{@backingInt(m)});
            }
            try w.print("{s}\n", .{reset});
        }
        if (!files) return;
        if (f.options.all_paths) {
            for (p.parents) |parent| {
                if (parent.status == .added) {
                    try paint.writeMeta(w, colors, "--- /dev/null", .{});
                } else try f.writeName(w, "--- ", o.prefixes.src, parent.path);
            }
        } else if (added) {
            try paint.writeMeta(w, colors, "--- /dev/null", .{});
        } else try f.writeName(w, "--- ", o.prefixes.src, p.path);
        if (deleted) {
            try paint.writeMeta(w, colors, "+++ /dev/null", .{});
        } else try f.writeName(w, "+++ ", o.prefixes.dst, p.path);
    }

    fn writeName(f: *File, w: *Io.Writer, head: []const u8, prefix: []const u8, path: []const u8) Self.Error!void {
        const name = try labels.quoteTwo(f.a, prefix, path, f.options.diff.quote_path);
        try paint.writeMeta(w, f.options.diff.colors, "{s}{s}", .{ head, name });
    }
};

/// A mode as git's `unsigned int` holds it, 0 for none.
fn modeBits(mode: ?object.Mode) u32 {
    return if (mode) |m| @backingInt(m) else 0;
}

/// A line some parents had and the result lost: git's `lline`.
const Lost = struct {
    line: []const u8,
    /// The parents that had it, a bit each.
    parents: u64,
};

/// A line of the result, and the lost lines that hang before it: git's
/// `sline`. One more than the result's lines, for what was lost at its
/// end.
const Line = struct {
    /// The line without its ending; `null` for the one past the end.
    text: ?[]const u8 = null,
    /// Where the line starts in the result, for a hunk's comment.
    start: usize = 0,
    /// Lost lines, the parents' runs merged.
    lost: std.ArrayList(Lost) = .empty,
    /// What the parent being compared lost here, before it is merged in.
    pending: std.ArrayList(Lost) = .empty,
    /// Bit `n` for each parent `n` the result added this line against;
    /// then git's two marks, for a line shown and for one whose lost lines
    /// are not.
    flag: u64 = 0,
    /// Each parent's line number at this line, from one.
    p_lno: []usize = &.{},
};

/// The result's lines with what every parent lost and gained, as git's
/// `show_patch_diff` builds them.
const Lines = struct {
    result: []const u8,
    lines: []Line,
    /// The result's line count; `lines` has one more.
    cnt: usize,
    num_parent: usize,

    fn init(a: Allocator, result: []const u8, num_parent: usize) Allocator.Error!Lines {
        var cnt: usize = std.mem.count(u8, result, "\n");
        if (result.len != 0 and result[result.len - 1] != '\n') cnt += 1;
        const lines = try a.alloc(Line, cnt + 2);
        for (lines) |*l| l.* = .{};
        const numbers = try a.alloc(usize, (cnt + 2) * num_parent);
        @memset(numbers, 0);
        for (lines, 0..) |*l, i| l.p_lno = numbers[i * num_parent ..][0..num_parent];
        var at: usize = 0;
        for (lines[0..cnt]) |*l| {
            const end = std.mem.findScalarPos(u8, result, at, '\n') orelse result.len;
            l.text = result[at..end];
            l.start = at;
            at = end + 1;
        }
        lines[cnt].start = result.len;
        return .{ .result = result, .lines = lines, .cnt = cnt, .num_parent = num_parent };
    }

    /// git's `combine_diff` for parent `n`: what it lost hung before the
    /// result's line where each change starts, what the result added
    /// marked, the lost lines merged, and the parent's line numbers.
    fn combine(l: *Lines, a: Allocator, differ: *parallax.Differ, parent: []const u8, n: usize, options: diff.Options) Self.Error!void {
        const nmask = @as(u64, 1) << @intCast(n);
        if (parent.len > diff.max_text_bytes or l.result.len > diff.max_text_bytes) return error.InputTooLarge;
        const d = try differ.lines(parent, l.result, options.lines());
        for (d.changes) |c| {
            // The lost lines hang before the line the change starts at.
            const bucket = &l.lines[c.new_start];
            for (0..c.old_len) |k| {
                const line = d.old.get(c.old_start + @as(u32, @intCast(k)));
                const bare = if (std.mem.endsWith(u8, line, "\n")) line[0 .. line.len - 1] else line;
                try bucket.pending.append(a, .{ .line = bare, .parents = nmask });
            }
            for (l.lines[c.new_start..][0..c.new_len]) |*added| added.flag |= nmask;
        }
        var p_lno: usize = 1;
        for (l.lines[0 .. l.cnt + 1], 0..) |*line, lno| {
            line.p_lno[n] = p_lno;
            if (line.pending.items.len != 0) {
                try coalesce(a, &line.lost, line.pending.items, nmask, options);
                line.pending = .empty;
            }
            for (line.lost.items) |ll| {
                if (ll.parents & nmask != 0) p_lno += 1;
            }
            if (lno < l.cnt and line.flag & nmask == 0) p_lno += 1;
        }
        l.lines[l.cnt + 1].p_lno[n] = p_lno;
    }

    /// git's `reuse_combine_diff`: parent `i` is parent `j`'s blob, so its
    /// marks and numbers are `j`'s.
    fn reuse(l: *Lines, i: usize, j: usize) void {
        const imask = @as(u64, 1) << @intCast(i);
        const jmask = @as(u64, 1) << @intCast(j);
        for (l.lines[0 .. l.cnt + 1]) |*line| {
            line.p_lno[i] = line.p_lno[j];
            for (line.lost.items) |*ll| {
                if (ll.parents & jmask != 0) ll.parents |= imask;
            }
            if (line.flag & jmask != 0) line.flag |= imask;
        }
        l.lines[l.cnt + 1].p_lno[i] = l.lines[l.cnt + 1].p_lno[j];
    }

    fn allMask(l: *const Lines) u64 {
        return (@as(u64, 1) << @intCast(l.num_parent)) - 1;
    }

    fn markBit(l: *const Lines) u64 {
        return @as(u64, 1) << @intCast(l.num_parent);
    }

    fn noPreDelete(l: *const Lines) u64 {
        return @as(u64, 2) << @intCast(l.num_parent);
    }

    /// git's `interesting`: some parent lost lines here, or the result
    /// added this one against some parent.
    fn interesting(l: *const Lines, line: *const Line) bool {
        return line.flag & l.allMask() != 0 or line.lost.items.len != 0;
    }

    /// git's `adjust_hunk_tail`: `i` is the first line not marked; a last
    /// line marked only for the deletion before it gives no context of
    /// its own.
    fn adjustHunkTail(l: *const Lines, hunk_begin: usize, i: usize) usize {
        if (hunk_begin + 1 <= i and l.lines[i - 1].flag & l.allMask() == 0) return i - 1;
        return i;
    }

    /// git's `find_next`: from `i`, the next line marked, or with
    /// `unmarked` the next one not.
    fn findNext(l: *const Lines, mark: u64, from: usize, unmarked: bool) usize {
        var i = from;
        while (i <= l.cnt) : (i += 1) {
            const marked = l.lines[i].flag & mark != 0;
            if (marked != unmarked) return i;
        }
        return i;
    }

    /// git's `give_context`: the marked lines with `context` lines around
    /// them, gaps shorter than that joined.
    fn giveContext(l: *Lines, context: usize) bool {
        const mark = l.markBit();
        const no_pre_delete = l.noPreDelete();
        var i = l.findNext(mark, 0, false);
        if (l.cnt < i) return false;
        while (i <= l.cnt) {
            var j = if (context < i) i - context else 0;
            // A few lines before the first marked one.
            while (j < i) : (j += 1) {
                if (l.lines[j].flag & mark == 0) l.lines[j].flag |= no_pre_delete;
                l.lines[j].flag |= mark;
            }
            while (true) {
                // Up to i is in; where does the next unmarked run start?
                j = l.findNext(mark, i, true);
                if (l.cnt < j) return true;
                var k = l.findNext(mark, j, false);
                j = l.adjustHunkTail(i, j);
                if (k < j + context) {
                    // A short gap: mark it and go on from k.
                    while (j < k) : (j += 1) l.lines[j].flag |= mark;
                    i = k;
                    continue;
                }
                // The trailing context.
                i = k;
                k = @min(j + context, l.cnt + 1);
                while (j < k) : (j += 1) l.lines[j].flag |= mark;
                break;
            }
        }
        return true;
    }

    /// git's `make_hunks`: mark what is shown, and with `dense` unmark a
    /// hunk with no more than two versions in it that the result took one
    /// of.
    fn makeHunks(l: *Lines, context: usize, dense: bool) bool {
        const all_mask = l.allMask();
        const mark = l.markBit();
        for (l.lines[0 .. l.cnt + 1]) |*line| {
            if (l.interesting(line)) line.flag |= mark else line.flag &= ~mark;
        }
        if (!dense) return l.giveContext(context);
        var i: usize = 0;
        while (i <= l.cnt) {
            while (i <= l.cnt and l.lines[i].flag & mark == 0) i += 1;
            if (l.cnt < i) break;
            const hunk_begin = i;
            var j = i + 1;
            while (j <= l.cnt) : (j += 1) {
                if (l.lines[j].flag & mark != 0) continue;
                // Is there a marked line within the context past this?
                var la = l.adjustHunkTail(hunk_begin, j);
                la = @min(la + context, l.cnt + 1);
                var contin = false;
                while (la != 0) {
                    la -= 1;
                    if (j > la) break;
                    if (l.lines[la].flag & mark != 0) {
                        contin = true;
                        break;
                    }
                }
                if (!contin) break;
                j = la;
            }
            const hunk_end = j;
            // Only two versions, and the result one of them, is no news.
            var same_diff: u64 = 0;
            var has_interesting = false;
            j = i;
            scan: while (j < hunk_end) : (j += 1) {
                const this_diff = l.lines[j].flag & all_mask;
                if (this_diff != 0) {
                    if (same_diff == 0) {
                        same_diff = this_diff;
                    } else if (same_diff != this_diff) {
                        has_interesting = true;
                        break :scan;
                    }
                }
                for (l.lines[j].lost.items) |ll| {
                    if (same_diff == 0) {
                        same_diff = ll.parents;
                    } else if (same_diff != ll.parents) {
                        has_interesting = true;
                        break :scan;
                    }
                }
            }
            if (!has_interesting and same_diff != all_mask) {
                for (l.lines[hunk_begin..hunk_end]) |*line| line.flag &= ~mark;
            }
            i = hunk_end;
        }
        return l.giveContext(context);
    }

    /// git's `dump_sline`: each run of marked lines as a hunk, `@@@` with a
    /// range for each parent and the result, the lost lines before the
    /// line they hang on.
    fn dump(l: *Lines, w: *Io.Writer, context: usize, colors: ?*const diff.Colors) Io.Writer.Error!void {
        const mark = l.markBit();
        const no_pre_delete = l.noPreDelete();
        const c_frag = if (colors) |c| c.frag.bytes() else "";
        const c_func = if (colors) |c| c.func.bytes() else "";
        const c_new = if (colors) |c| c.new.bytes() else "";
        const c_old = if (colors) |c| c.old.bytes() else "";
        const c_context = if (colors) |c| c.context.bytes() else "";
        const c_reset = if (colors != null) color.reset else "";
        var lno: usize = 0;
        while (true) {
            var comment: ?usize = null;
            while (lno <= l.cnt and l.lines[lno].flag & mark == 0) : (lno += 1) {
                if (l.commentLine(lno)) comment = l.lines[lno].start;
            }
            if (l.cnt < lno) break;
            var hunk_end = lno + 1;
            while (hunk_end <= l.cnt and l.lines[hunk_end].flag & mark != 0) hunk_end += 1;
            var rlines = hunk_end - lno;
            // Pointing at the deletion past the end.
            if (l.cnt < hunk_end) rlines -%= 1;
            var null_context: usize = 0;
            if (context == 0) {
                // Every line is walked to show what was lost before it,
                // but a line shown only for that is not counted.
                for (l.lines[lno..hunk_end]) |line| {
                    if (line.flag & (mark - 1) == 0) null_context += 1;
                }
                // Wrapping as git's `unsigned long` wraps: a file the result
                // deleted counts its line past the end twice, and git writes
                // the wrapped count.
                rlines -%= null_context;
            }
            try w.writeAll(c_frag);
            try w.splatByteAll('@', l.num_parent + 1);
            for (0..l.num_parent) |n| {
                const l0 = l.lines[lno].p_lno[n];
                const l1 = l.lines[hunk_end].p_lno[n];
                try w.print(" -{d},{d}", .{ l0, l1 -% l0 -% null_context });
            }
            try w.print(" +{d},{d} ", .{ lno + 1, rlines });
            try w.splatByteAll('@', l.num_parent + 1);
            if (comment) |start| try l.writeComment(w, start, .{ .reset = c_reset, .context = c_context, .func = c_func });
            try w.print("{s}\n", .{c_reset});
            while (lno < hunk_end) {
                const line = &l.lines[lno];
                lno += 1;
                if (line.flag & no_pre_delete == 0) for (line.lost.items) |ll| {
                    try w.writeAll(c_old);
                    for (0..l.num_parent) |n| try w.writeByte(if (ll.parents & (@as(u64, 1) << @intCast(n)) != 0) '-' else ' ');
                    // The line as a C string: up to a NUL in it.
                    try writeToEol(w, ll.line[0 .. std.mem.findScalar(u8, ll.line, 0) orelse ll.line.len], c_reset);
                };
                if (l.cnt < lno) break;
                if (line.flag & (mark - 1) == 0) {
                    // Here only to hang the lost lines on.
                    if (context == 0) continue;
                    try w.writeAll(c_context);
                } else try w.writeAll(c_new);
                for (0..l.num_parent) |n| try w.writeByte(if (line.flag & (@as(u64, 1) << @intCast(n)) != 0) '+' else ' ');
                try writeToEol(w, line.text.?, c_reset);
            }
        }
    }

    /// git's `hunk_comment_line`: a line starting with a letter, `_` or `$`.
    fn commentLine(l: *const Lines, lno: usize) bool {
        const text = l.lines[lno].text orelse return false;
        if (text.len == 0) return false;
        const ch = text[0];
        return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$';
    }

    const CommentColors = struct { reset: []const u8, context: []const u8, func: []const u8 };

    /// The text after a hunk's `@@@`: the last comment line before it, at
    /// most forty bytes up to its end, as git writes it -- up to, and not
    /// including, the last byte that is no space.
    fn writeComment(l: *const Lines, w: *Io.Writer, start: usize, colors: CommentColors) Io.Writer.Error!void {
        var comment_end: usize = 0;
        for (0..40) |i| {
            const ch: u8 = if (start + i < l.result.len) l.result[start + i] else 0;
            if (ch == 0 or ch == '\n') break;
            if (!ctype.isSpace(ch)) comment_end = i;
        }
        if (comment_end == 0) return;
        try w.print("{s}{s} {s}{s}", .{ colors.reset, colors.context, colors.reset, colors.func });
        try w.writeAll(l.result[start..][0..comment_end]);
    }
};

/// git's `show_line_to_eol`: the line, the reset, then a carriage return
/// it ended with, and the newline.
fn writeToEol(w: *Io.Writer, line: []const u8, reset: []const u8) Io.Writer.Error!void {
    const cr = line.len != 0 and line[line.len - 1] == '\r';
    try w.writeAll(line[0 .. line.len - @intFromBool(cr)]);
    try w.writeAll(reset);
    if (cr) try w.writeByte('\r');
    try w.writeByte('\n');
}

/// git's `coalesce_lines`: the lines a parent lost here merged into those
/// earlier parents lost, by their longest common subsequence, a line that
/// matches one already there taking the parent's bit and the rest put in
/// among them in order.
fn coalesce(a: Allocator, base: *std.ArrayList(Lost), new: []const Lost, nmask: u64, options: diff.Options) Allocator.Error!void {
    if (new.len == 0) return;
    if (base.items.len == 0) {
        try base.appendSlice(a, new);
        return;
    }
    const Direction = enum(u2) { match, base, new };
    const rows = base.items.len + 1;
    const cols = new.len + 1;
    const lcs = try a.alloc(u32, rows * cols);
    defer a.free(lcs);
    const directions = try a.alloc(Direction, rows * cols);
    defer a.free(directions);
    @memset(lcs, 0);
    for (0..rows) |i| directions[i * cols] = .base;
    for (1..cols) |j| directions[j] = .new;
    for (1..rows) |i| {
        for (1..cols) |j| {
            const at = i * cols + j;
            if (matchSpaces(base.items[i - 1].line, new[j - 1].line, options)) {
                lcs[at] = lcs[at - cols - 1] + 1;
                directions[at] = .match;
            } else if (lcs[at - 1] >= lcs[at - cols]) {
                lcs[at] = lcs[at - 1];
                directions[at] = .new;
            } else {
                lcs[at] = lcs[at - cols];
                directions[at] = .base;
            }
        }
    }
    var i = rows - 1;
    var j = cols - 1;
    while (i != 0 or j != 0) {
        switch (directions[i * cols + j]) {
            .match => {
                base.items[i - 1].parents |= nmask;
                i -= 1;
                j -= 1;
            },
            .new => {
                try base.insert(a, i, new[j - 1]);
                j -= 1;
            },
            .base => i -= 1,
        }
    }
}

/// git's `match_string_spaces`: two lost lines alike, by the whitespace
/// the diff overlooks.
fn matchSpaces(line1: []const u8, line2: []const u8, options: diff.Options) bool {
    const all = options.ignore_all_whitespace;
    const change = options.ignore_whitespace_change;
    var len1 = line1.len;
    var len2 = line2.len;
    if (all or change or options.ignore_trailing_whitespace) {
        while (len1 > 0 and ctype.isSpace(line1[len1 - 1])) len1 -= 1;
        while (len2 > 0 and ctype.isSpace(line2[len2 - 1])) len2 -= 1;
    }
    if (!all and !change) return std.mem.eql(u8, line1[0..len1], line2[0..len2]);
    while (len1 > 0 and len2 > 0) {
        len1 -= 1;
        len2 -= 1;
        if (ctype.isSpace(line1[len1]) or ctype.isSpace(line2[len2])) {
            if (change and (!ctype.isSpace(line1[len1]) or !ctype.isSpace(line2[len2]))) return false;
            while (len1 > 0 and ctype.isSpace(line1[len1])) len1 -= 1;
            while (len2 > 0 and ctype.isSpace(line2[len2])) len2 -= 1;
        }
        if (line1[len1] != line2[len2]) return false;
    }
    if (all) {
        while (len1 > 0 and ctype.isSpace(line1[len1 - 1])) len1 -= 1;
        while (len2 > 0 and ctype.isSpace(line2[len2 - 1])) len2 -= 1;
    }
    return len1 == 0 and len2 == 0;
}
