//! `git range-diff`: two ranges of commits, each commit's patch as git's
//! `range-diff.c` reads it out of `git log -p`, the patches of one range
//! paired with the other's where they correspond, and the pairs written as
//! git writes them, each with the diff between its two patches.
//!
//! The pairing is git's. Patches whose diffs are identical pair first; the
//! rest pair at the least total cost, a pair costing the size of the diff
//! between its patches and a patch left alone its own size times the
//! creation factor, found by git's Jonker-Volgenant solver step for step so
//! that ties come out as git's do.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const abbrev = @import("../odb/abbrev.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const parallax = @import("parallax");
const revwalk = @import("../walk/walk.zig");
const pretty = @import("../pretty/pretty.zig");
const notes_mod = @import("../commit/notes.zig");
const mailmap_mod = @import("../revwalk/mailmap.zig");
const attributes = @import("../patterns/attributes.zig");
const cquote = @import("../text/cquote.zig");
const unicodewidth = @import("../text/unicodewidth.zig");
const formatpatch = @import("format.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a range-diff.
pub const Error = error{
    /// The cost matrix would need `Options.max_memory` or more, which git
    /// dies on.
    RangeDiffTooLarge,
    /// `left_only` and `right_only` together, which git refuses.
    LeftAndRightOnly,
    /// A commit whose message is in an encoding other than UTF-8 or
    /// Latin-1.
    UnsupportedEncoding,
    NotACommit,
} || diff.Error || diff.TextError || diff.ConfigError || revwalk.Error || pretty.Error || notes_mod.Error ||
    mailmap_mod.LoadError || repo_mod.Error || attributes.Error || Io.Writer.Error;

/// `<base>..<tip>`: the commits `tip` reaches and `base` does not, merges
/// left out. git's other two forms are made of these: `<base> <old> <new>`
/// is `base..old` against `base..new`, and `<old>...<new>` is `new..old`
/// against `old..new`.
pub const Range = struct { base: Oid, tip: Oid };

/// How a range-diff is made and written.
pub const Options = struct {
    /// `--creation-factor`: how much, in percent of its size, leaving a
    /// patch without a partner costs.
    creation_factor: u32 = 60,
    /// `--left-only`: only the pairs with an old commit in them.
    left_only: bool = false,
    /// `--right-only`: only the pairs with a new commit in them.
    right_only: bool = false,
    /// Whether a commit's notes, from `core.notesRef` or
    /// `refs/notes/commits`, are part of its patch; `--no-notes` is
    /// `false`.
    notes: bool = true,
    /// `--max-memory`: the most the cost matrix may take, in bytes.
    max_memory: usize = 4 << 30,
    /// Whether a pair's line is followed by the diff between its patches;
    /// `--no-patch` is `false`.
    patch: bool = true,
    /// How a pair's patches are compared; `null` reads `diff.algorithm`
    /// and `diff.context` as git does.
    diff: ?diff.Options = null,
};

/// One commit's patch as range-diff compares it: ` ## Metadata ##` with
/// the author, ` ## Commit message ##`, the notes, and a section per file.
pub const Patch = struct {
    oid: Oid,
    text: []const u8,
    /// Where the files start in `text`; the whole of it for a commit that
    /// changes no file, as in git.
    diff_offset: usize,
    /// The lines of the files' sections, which is what leaving the patch
    /// alone costs.
    diff_size: u32,
    /// Its partner's place in the other range.
    matching: ?usize = null,

    fn diffText(p: *const Patch) []const u8 {
        return p.text[p.diff_offset..];
    }
};

/// Two ranges' patches, oldest first, paired.
pub const RangeDiff = struct {
    arena: std.heap.ArenaAllocator,
    old: []Patch,
    new: []Patch,

    pub fn deinit(r: *RangeDiff) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

/// Read both ranges' patches and pair them.
pub fn compute(gpa: Allocator, io: Io, repo: *Repository, old: Range, new: Range, options: Options) Self.Error!RangeDiff {
    if (options.left_only and options.right_only) return error.LeftAndRightOnly;
    var result: RangeDiff = .{ .arena = .init(gpa), .old = &.{}, .new = &.{} };
    errdefer result.deinit();
    var reader: Reader = try .init(gpa, result.arena.allocator(), io, repo, options);
    defer reader.deinit();
    result.old = try reader.readPatches(old);
    result.new = try reader.readPatches(new);
    try findExactMatches(gpa, result.old, result.new);
    try getCorrespondences(gpa, result.old, result.new, options);
    return result;
}

/// `git range-diff`, written to `w`: a line for each pair in the order of
/// the new range, an old commit with no partner once those before it have
/// been shown, and under a pair whose patches differ, the diff between
/// them. No colour.
pub fn write(gpa: Allocator, io: Io, repo: *Repository, old: Range, new: Range, options: Options, w: *Io.Writer) Self.Error!void {
    var result = try compute(gpa, io, repo, old, new, options);
    defer result.deinit();
    try output(gpa, io, repo, &result, options, w);
}

// ---------------------------------------------------------------------------
// Reading the patches: what `read_patches` makes of `git log -p --no-prefix
// --submodule=short --pretty=medium --show-notes-by-default --no-merges
// --date-order --reverse`.

const Reader = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    a: Allocator,
    mailmap: ?mailmap_mod.Mailmap = null,
    notes: ?notes_mod.Notes = null,
    attrs: ?attributes.Attrs = null,
    diff_options: diff.Options,
    renames: ?diff.RenameOptions,
    show_root: bool,
    quote_path: bool,

    fn init(gpa: Allocator, a: Allocator, io: Io, repo: *Repository, options: Options) Error!Reader {
        const config = repo.configuration();
        var r: Reader = .{
            .gpa = gpa,
            .io = io,
            .repo = repo,
            .a = a,
            .diff_options = try formatpatch.configuredDiff(config),
            .renames = formatpatch.configuredRenames(config),
            .show_root = config.getBool("log.showroot", true) catch true,
            .quote_path = config.getBool("core.quotepath", true) catch true,
        };
        errdefer r.deinit();
        if (config.getBool("log.mailmap", true) catch true) r.mailmap = try mailmap_mod.Mailmap.load(gpa, io, repo);
        if (options.notes) {
            const ref = try notes_mod.defaultRef(gpa, repo);
            defer gpa.free(ref);
            r.notes = try notes_mod.Notes.open(gpa, io, repo, ref, .concatenate);
        }
        if (repo.workDirectory() != null) r.attrs = try repo.loadAttrs(io);
        return r;
    }

    fn deinit(r: *Reader) void {
        if (r.mailmap) |*m| m.deinit();
        if (r.notes) |*n| n.deinit();
        if (r.attrs) |*x| x.deinit();
        r.* = undefined;
    }

    fn readPatches(r: *Reader, range: Range) Error![]Patch {
        var walk = revwalk.Walk.init(r.gpa, r.repo.objectDatabase());
        defer walk.deinit();
        walk.sort = .date_order;
        walk.reverse = true;
        try walk.push(range.tip);
        try walk.hide(range.base);
        var list: std.ArrayList(Patch) = .empty;
        while (try walk.next(r.io)) |c| {
            if (c.parents.len > 1) continue;
            try list.append(r.a, try r.readPatch(c.oid));
        }
        return list.items;
    }

    fn readPatch(r: *Reader, oid: Oid) Error!Patch {
        const a = r.a;
        const db = r.repo.objectDatabase();
        const found = try db.read(r.io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        const commit = try object.Commit.parse(a, db.objectFormat(), try a.dupe(u8, found.bytes));

        var text: std.ArrayList(u8) = .empty;
        var who: mailmap_mod.Identity = .{
            .name = try formatpatch.logText(a, &commit, commit.author.name),
            .email = try formatpatch.logText(a, &commit, commit.author.email),
        };
        if (r.mailmap) |*m| who = m.map(who.name, who.email);
        try text.print(a, " ## Metadata ##\nAuthor: {s} <{s}>\n\n ## Commit message ##\n", .{ who.name, who.email });
        try appendMessage(a, &text, try formatpatch.logMessage(a, &commit));
        if (r.notes) |*n| {
            var shown: Io.Writer.Allocating = .init(a);
            try notes_mod.formatNote(r.io, n, oid, &shown.writer, .{ .raw = false });
            var lines = std.mem.splitScalar(u8, shown.written(), '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "Notes") and std.mem.endsWith(u8, line, ":")) {
                    try text.print(a, "\n\n ## {s} ##\n", .{line[0 .. line.len - 1]});
                } else if (std.mem.startsWith(u8, line, "    ")) {
                    try text.appendSlice(a, std.mem.trimEnd(u8, line, &std.ascii.whitespace));
                    try text.append(a, '\n');
                }
            }
        }

        var patch: Patch = .{ .oid = oid, .text = "", .diff_offset = 0, .diff_size = 0 };
        if (commit.parents.len > 0 or r.show_root) {
            const parent_tree: ?Oid = if (commit.parents.len == 0) null else blk: {
                const p = try db.read(r.io, commit.parents[0]);
                defer db.allocator().free(p.bytes);
                var parent = try object.Commit.parse(r.gpa, db.objectFormat(), p.bytes);
                defer parent.deinit();
                break :blk parent.tree;
            };
            var changes = try diff.tree(r.gpa, r.io, db, parent_tree, commit.tree, .{ .renames = r.renames });
            defer changes.deinit();
            for (changes.items) |change| {
                const old = if (change.old) |e| try r.loadSide(e) else null;
                const new = if (change.new) |e| try r.loadSide(e) else null;
                if (old != null and new != null and typeChanged(old.?.mode, new.?.mode)) {
                    // git splits a change of type into a deletion and a creation
                    try r.appendFile(&text, &patch, change, old, null);
                    try r.appendFile(&text, &patch, change, null, new);
                } else try r.appendFile(&text, &patch, change, old, new);
            }
        }
        patch.text = text.items;
        return patch;
    }

    const Side = struct { path: []const u8, mode: object.Mode, oid: Oid, bytes: []const u8, binary: bool };

    fn loadSide(r: *Reader, e: diff.Entry) Error!Side {
        var bytes: []const u8 = undefined;
        if (e.mode == .gitlink) {
            var hex: [hash.max_hex_len]u8 = undefined;
            bytes = try r.a.print("Subproject commit {s}\n", .{e.oid.hex(&hex)});
        } else {
            const found = try r.repo.objectDatabase().read(r.io, e.oid);
            defer r.repo.objectDatabase().allocator().free(found.bytes);
            bytes = try r.a.dupe(u8, found.bytes);
        }
        return .{ .path = e.path, .mode = e.mode, .oid = e.oid, .bytes = bytes, .binary = try r.isBinary(e.path, bytes) };
    }

    fn isBinary(r: *Reader, path: []const u8, bytes: []const u8) Error!bool {
        const rule: diff.BinaryRule = .{ .attrs = if (r.attrs) |*attrs| attrs else null, .work_dir = r.repo.workDirectory(), .config = r.repo.configuration() };
        return rule.isBinary(r.a, r.io, path, bytes);
    }

    /// One file of the commit: ` ## <name> ##` for its `diff --git` header,
    /// then its hunks, an `@@` line carrying the file's name before the
    /// function's, and each line with its own sign.
    fn appendFile(r: *Reader, text: *std.ArrayList(u8), patch: *Patch, change: diff.Change, old: ?Side, new: ?Side) Error!void {
        const a = r.a;
        try text.append(a, '\n');
        if (patch.diff_offset == 0) patch.diff_offset = text.items.len;
        try text.appendSlice(a, " ## ");
        if (old == null) {
            try text.print(a, "{s} (new)", .{new.?.path});
        } else if (new == null) {
            try text.print(a, "{s} (deleted)", .{old.?.path});
        } else if (change.status == .renamed) {
            try text.print(a, "{s} => {s}", .{ old.?.path, new.?.path });
        } else try text.appendSlice(a, new.?.path);
        const file_name = if (new) |n| n.path else old.?.path;
        if (old != null and new != null and old.?.mode != new.?.mode) {
            try text.print(a, " (mode change {o:0>6} => {o:0>6})", .{ @backingInt(old.?.mode), @backingInt(new.?.mode) });
        }
        try text.appendSlice(a, " ##\n");
        patch.diff_size += 1;

        const zero = Oid.zero(r.repo.objectFormat());
        if ((if (old) |o| o.oid else zero).eql(if (new) |n| n.oid else zero)) return;
        const one: []const u8 = if (old) |o| o.bytes else "";
        const two: []const u8 = if (new) |n| n.bytes else "";
        if ((old != null and old.?.binary) or (new != null and new.?.binary)) {
            const lbl0 = if (old) |o| try cquote.alloc(a, o.path, r.quote_path) else "/dev/null";
            const lbl1 = if (new) |n| try cquote.alloc(a, n.path, r.quote_path) else "/dev/null";
            try text.print(a, " Binary files {s} and {s} differ\n", .{ lbl0, lbl1 });
            patch.diff_size += 1;
            return;
        }
        var body: Io.Writer.Allocating = .init(a);
        diff.unifiedBody(r.gpa, &body.writer, one, two, r.diff_options) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        var lines = std.mem.splitScalar(u8, body.written(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "@@ ")) {
                const rest = line[(std.mem.findPos(u8, line, 3, "@@") orelse line.len - 2) + 2 ..];
                try text.appendSlice(a, "@@");
                if (rest.len != 0) try text.print(a, " {s}:", .{file_name});
                try text.appendSlice(a, rest);
            } else if (line[0] == '+' or line[0] == '-') {
                try text.appendSlice(a, line);
            } else if (line[0] == ' ') {
                try text.appendSlice(a, line);
            } else {
                try text.append(a, ' ');
                try text.appendSlice(a, line);
            }
            try text.append(a, '\n');
            patch.diff_size += 1;
        }
    }
};

fn typeChanged(a: object.Mode, b: object.Mode) bool {
    return (@backingInt(a) & 0o170000) != (@backingInt(b) & 0o170000);
}

/// The message as `--pretty=medium` shows it, less its indent's trailing
/// whitespace: blank lines at the start dropped, each line's trailing
/// whitespace too, tabs expanded to eight columns, four spaces before each
/// line that is not blank, and no blank line at the end.
fn appendMessage(a: Allocator, text: *std.ArrayList(u8), message: []const u8) Allocator.Error!void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, message, '\n');
    while (it.next()) |raw| {
        if (it.index == null and raw.len == 0) break;
        const line = std.mem.trimEnd(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 and lines.items.len == 0) continue;
        try lines.append(a, line);
    }
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) lines.items.len -= 1;
    for (lines.items) |line| {
        if (line.len != 0) {
            try text.appendSlice(a, "    ");
            try appendTabExpanded(a, text, line);
        }
        try text.append(a, '\n');
    }
}

/// git's `strbuf_add_tabexpand` at eight columns: each tab up to the next
/// stop, counted in display columns, until a stretch is not UTF-8.
fn appendTabExpanded(a: Allocator, text: *std.ArrayList(u8), line_in: []const u8) Allocator.Error!void {
    var line = line_in;
    while (std.mem.findScalar(u8, line, '\t')) |tab| {
        const columns = utf8Width(line[0..tab]) orelse break;
        try text.appendSlice(a, line[0..tab]);
        try text.appendNTimes(a, ' ', 8 - columns % 8);
        line = line[tab + 1 ..];
    }
    try text.appendSlice(a, line);
}

fn utf8Width(s: []const u8) ?usize {
    var columns: usize = 0;
    var at: usize = 0;
    while (at < s.len) {
        const decoded = unicodewidth.decode(s[at..]) orelse return null;
        const w = unicodewidth.width(decoded.char);
        if (w > 0) columns += @intCast(w);
        at += decoded.len;
    }
    return columns;
}

// ---------------------------------------------------------------------------
// Pairing.

/// `find_exact_matches`: each new patch takes an old one with the same
/// diff. The old ones are found as git's hash map finds them: of several
/// alike, the last one added, the order of a bucket turning over each time
/// the table is resized.
fn findExactMatches(gpa: Allocator, old: []Patch, new: []Patch) Allocator.Error!void {
    var chains: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    defer {
        var values = chains.valueIterator();
        while (values.next()) |v| v.deinit(gpa);
        chains.deinit(gpa);
    }
    var table: Table = .{};
    for (old, 0..) |*p, i| {
        const entry = try chains.getOrPut(gpa, p.diffText());
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        // the chain's head is its last element
        try entry.value_ptr.append(gpa, i);
        if (table.add()) turnChains(&chains);
    }
    for (new, 0..) |*p, j| {
        const chain = chains.getPtr(p.diffText()) orelse continue;
        const i = chain.pop() orelse continue;
        old[i].matching = j;
        p.matching = i;
        if (table.remove()) turnChains(&chains);
    }
}

fn turnChains(chains: *std.StringHashMapUnmanaged(std.ArrayList(usize))) void {
    var values = chains.valueIterator();
    while (values.next()) |v| std.mem.reverse(usize, v.items);
}

/// The size of git's `hashmap`, which decides when it is rehashed.
const Table = struct {
    size: usize = 64,
    count: usize = 0,

    const initial = 64;

    fn growAt(t: Table) usize {
        return t.size * 80 / 100;
    }

    fn shrinkAt(t: Table) usize {
        return if (t.size > initial) t.growAt() / 5 else 0;
    }

    /// Whether adding one rehashed the table.
    fn add(t: *Table) bool {
        t.count += 1;
        if (t.count <= t.growAt()) return false;
        t.size <<= 2;
        return true;
    }

    /// Whether removing one rehashed the table.
    fn remove(t: *Table) bool {
        t.count -= 1;
        if (t.count >= t.shrinkAt()) return false;
        t.size >>= 2;
        return true;
    }
};

const cost_max: i32 = 1 << 16;

/// `get_correspondences`.
fn getCorrespondences(gpa: Allocator, old: []Patch, new: []Patch, options: Options) Error!void {
    const n = old.len + new.len;
    const cells = std.math.mul(usize, n, n) catch return error.RangeDiffTooLarge;
    const bytes = std.math.mul(usize, cells, @sizeOf(i32)) catch return error.RangeDiffTooLarge;
    if (bytes >= options.max_memory) return error.RangeDiffTooLarge;
    const cost = try gpa.alloc(i32, cells);
    defer gpa.free(cost);
    const a2b = try gpa.alloc(i32, n);
    defer gpa.free(a2b);
    const b2a = try gpa.alloc(i32, n);
    defer gpa.free(b2a);
    const factor: u64 = options.creation_factor;
    // Every pair is diffed in one workspace, which stops allocating once it
    // has room for the largest.
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();

    for (old, 0..) |*a, i| {
        for (new, 0..) |*b, j| {
            const c: i32 = if (a.matching == j)
                0
            else if (a.matching == null and b.matching == null)
                try diffSize(&differ, a.diffText(), b.diffText())
            else
                cost_max;
            cost[i + n * j] = c;
        }
        const c: i32 = if (a.matching == null) @intCast(@min(@as(u64, a.diff_size) * factor / 100, std.math.maxInt(i32))) else cost_max;
        for (new.len..n) |j| cost[i + n * j] = c;
    }
    for (new, 0..) |*b, j| {
        const c: i32 = if (b.matching == null) @intCast(@min(@as(u64, b.diff_size) * factor / 100, std.math.maxInt(i32))) else cost_max;
        for (old.len..n) |i| cost[i + n * j] = c;
    }
    for (old.len..n) |i| {
        for (new.len..n) |j| cost[i + n * j] = 0;
    }

    try computeAssignment(gpa, n, n, cost, a2b, b2a);

    for (old, 0..) |*a, i| {
        if (a2b[i] >= 0 and a2b[i] < new.len) {
            const j: usize = @intCast(a2b[i]);
            a.matching = j;
            new[j].matching = i;
        }
    }
}

/// `diffsize`: the hunks and their lines in a diff of two patches with
/// three lines of context and none of the heuristics.
fn diffSize(differ: *parallax.Differ, a: []const u8, b: []const u8) diff.TextError!i32 {
    const d = try differ.lines(a, b, .{ .indent_heuristic = false });
    var count: usize = 0;
    var hunks = d.hunks(.{ .context = 3 });
    while (hunks.next()) |hunk| {
        var added: usize = 0;
        for (hunk.changes) |change| added += change.new_len;
        count += 1 + hunk.old_len + added;
    }
    return @intCast(@min(count, std.math.maxInt(i32)));
}

/// `cost[column + n * row]`, as `computeAssignment` reads it.
const Costs = struct {
    cost: []const i32,
    n: usize,
    fn at(s: Costs, column: i32, row: i32) i32 {
        return s.cost[@as(usize, @intCast(column)) + s.n * @as(usize, @intCast(row))];
    }
};

/// git's `compute_assignment`, after Jonker and Volgenant (1987): the
/// assignment of columns to rows of least total cost, `cost[column +
/// column_count * row]`. Ported line for line, ties included; each phase
/// of git's function is a step of `Assignment`.
fn computeAssignment(gpa: Allocator, column_count: usize, row_count: usize, cost: []const i32, column2row: []i32, row2column: []i32) Allocator.Error!void {
    assert(cost.len == column_count * row_count);
    assert(column2row.len == column_count);
    assert(row2column.len == row_count);
    if (column_count < 2) {
        @memset(column2row, 0);
        @memset(row2column, 0);
        return;
    }

    @memset(column2row, -1);
    @memset(row2column, -1);
    const v = try gpa.alloc(i32, column_count);
    defer gpa.free(v);
    const free_row = try gpa.alloc(i32, row_count);
    defer gpa.free(free_row);
    var lap: Assignment = .{
        .m = .{ .cost = cost, .n = column_count },
        .cc = @intCast(column_count),
        .rc = @intCast(row_count),
        .column2row = column2row,
        .row2column = row2column,
        .v = v,
        .free_row = free_row,
    };
    lap.columnReduction();
    lap.reductionTransfer();
    if (lap.free_count == (if (column_count < row_count) lap.rc - lap.cc else 0)) return;
    lap.augmentingRowReduction();
    try lap.augmentation(gpa);
}

/// The state `compute_assignment` keeps from one phase to the next.
const Assignment = struct {
    m: Costs,
    cc: i32,
    rc: i32,
    column2row: []i32,
    row2column: []i32,
    v: []i32,
    free_row: []i32,
    free_count: i32 = 0,

    /// Column reduction: each column's cheapest row, taken where it is
    /// still free.
    fn columnReduction(l: *Assignment) void {
        const m = l.m;
        var j: i32 = l.cc - 1;
        while (j >= 0) : (j -= 1) {
            var i_1: i32 = 0;
            var i: i32 = 1;
            while (i < l.rc) : (i += 1) {
                if (m.at(j, i_1) > m.at(j, i)) i_1 = i;
            }
            l.v[@intCast(j)] = m.at(j, i_1);
            if (l.row2column[@intCast(i_1)] == -1) {
                // row i_1 unassigned
                l.row2column[@intCast(i_1)] = j;
                l.column2row[@intCast(j)] = i_1;
            } else {
                if (l.row2column[@intCast(i_1)] >= 0) l.row2column[@intCast(i_1)] = -2 - l.row2column[@intCast(i_1)];
                l.column2row[@intCast(j)] = -1;
            }
        }
    }

    /// Reduction transfer: the free rows listed, and each assigned
    /// column's price lowered by its row's second best.
    fn reductionTransfer(l: *Assignment) void {
        const m = l.m;
        const v = l.v;
        l.free_count = 0;
        var i: i32 = 0;
        while (i < l.rc) : (i += 1) {
            const j_1 = l.row2column[@intCast(i)];
            if (j_1 == -1) {
                l.free_row[@intCast(l.free_count)] = i;
                l.free_count += 1;
            } else if (j_1 < -1) {
                l.row2column[@intCast(i)] = -2 - j_1;
            } else {
                const not_j1: i32 = @intFromBool(j_1 == 0);
                var min = m.at(not_j1, i) - v[@intCast(not_j1)];
                var j: i32 = 1;
                while (j < l.cc) : (j += 1) {
                    if (j != j_1 and min > m.at(j, i) - v[@intCast(j)]) min = m.at(j, i) - v[@intCast(j)];
                }
                v[@intCast(j_1)] -= min;
            }
        }
    }

    /// Augmenting row reduction, twice: each free row takes its cheapest
    /// column, the row it displaces freed in its turn.
    fn augmentingRowReduction(l: *Assignment) void {
        const m = l.m;
        const v = l.v;
        var phase: u32 = 0;
        while (phase < 2) : (phase += 1) {
            var k: i32 = 0;
            const saved_free_count = l.free_count;
            l.free_count = 0;
            while (k < saved_free_count) {
                var j_1: i32 = 0;
                const i = l.free_row[@intCast(k)];
                k += 1;
                var u_1 = m.at(j_1, i) - v[@intCast(j_1)];
                var j_2: i32 = -1;
                var u_2: i32 = std.math.maxInt(i32);
                var j: i32 = 1;
                while (j < l.cc) : (j += 1) {
                    const c = m.at(j, i) - v[@intCast(j)];
                    if (u_2 > c) {
                        if (u_1 < c) {
                            u_2 = c;
                            j_2 = j;
                        } else {
                            u_2 = u_1;
                            u_1 = c;
                            j_2 = j_1;
                            j_1 = j;
                        }
                    }
                }
                if (j_2 < 0) {
                    j_2 = j_1;
                    u_2 = u_1;
                }

                var i_0 = l.column2row[@intCast(j_1)];
                if (u_1 < u_2) {
                    v[@intCast(j_1)] -= u_2 - u_1;
                } else if (i_0 >= 0) {
                    j_1 = j_2;
                    i_0 = l.column2row[@intCast(j_1)];
                }

                if (i_0 >= 0) {
                    if (u_1 < u_2) {
                        k -= 1;
                        l.free_row[@intCast(k)] = i_0;
                    } else {
                        l.free_row[@intCast(l.free_count)] = i_0;
                        l.free_count += 1;
                    }
                }
                l.row2column[@intCast(i)] = j_1;
                l.column2row[@intCast(j_1)] = i;
            }
        }
    }

    /// Augmentation: a shortest path from each row still free to a free
    /// column, the prices updated and the path's assignments flipped.
    fn augmentation(l: *Assignment, gpa: Allocator) Allocator.Error!void {
        const column_count: usize = @intCast(l.cc);
        const d = try gpa.alloc(i32, column_count);
        defer gpa.free(d);
        const pred = try gpa.alloc(i32, column_count);
        defer gpa.free(pred);
        const col = try gpa.alloc(i32, column_count);
        defer gpa.free(col);
        const saved_free_count = l.free_count;
        l.free_count = 0;
        while (l.free_count < saved_free_count) : (l.free_count += 1) {
            const i_1 = l.free_row[@intCast(l.free_count)];
            const found = l.shortestPath(i_1, d, pred, col);
            var j = found.column;

            // updating of the column pieces
            var k: i32 = 0;
            while (k < found.last) : (k += 1) {
                const j_1 = col[@intCast(k)];
                l.v[@intCast(j_1)] += d[@intCast(j_1)] - found.min;
            }

            // augmentation
            while (true) {
                assert(j >= 0);
                const i = pred[@intCast(j)];
                l.column2row[@intCast(j)] = i;
                std.mem.swap(i32, &j, &l.row2column[@intCast(i)]);
                if (i_1 == i) break;
            }
        }
    }

    /// The search of `augmentation` from free row `i_1`: the free column it
    /// reached, the reduced cost of the path there, and how many columns
    /// were scanned before it.
    fn shortestPath(l: *Assignment, i_1: i32, d: []i32, pred: []i32, col: []i32) struct { column: i32, min: i32, last: i32 } {
        const m = l.m;
        const v = l.v;
        var low: i32 = 0;
        var up: i32 = 0;
        var last: i32 = undefined;
        var min: i32 = undefined;

        var j: i32 = 0;
        while (j < l.cc) : (j += 1) {
            d[@intCast(j)] = m.at(j, i_1) - v[@intCast(j)];
            pred[@intCast(j)] = i_1;
            col[@intCast(j)] = j;
        }

        j = -1;
        search: while (true) {
            last = low;
            min = d[@intCast(col[@intCast(up)])];
            up += 1;
            var k: i32 = up;
            while (k < l.cc) : (k += 1) {
                j = col[@intCast(k)];
                const c = d[@intCast(j)];
                if (c <= min) {
                    if (c < min) {
                        up = low;
                        min = c;
                    }
                    col[@intCast(k)] = col[@intCast(up)];
                    col[@intCast(up)] = j;
                    up += 1;
                }
            }
            // git leaves `j` as the scan left it when a column here is free
            k = low;
            while (k < up) : (k += 1) {
                if (l.column2row[@intCast(col[@intCast(k)])] == -1) break :search;
            }

            // scan a row
            while (true) {
                const j_1 = col[@intCast(low)];
                low += 1;
                const i = l.column2row[@intCast(j_1)];
                const u_1 = m.at(j_1, i) - v[@intCast(j_1)] - min;
                k = up;
                while (k < l.cc) : (k += 1) {
                    j = col[@intCast(k)];
                    const c = m.at(j, i) - v[@intCast(j)] - u_1;
                    if (c < d[@intCast(j)]) {
                        d[@intCast(j)] = c;
                        pred[@intCast(j)] = i;
                        if (c == min) {
                            if (l.column2row[@intCast(j)] == -1) break :search;
                            col[@intCast(k)] = col[@intCast(up)];
                            col[@intCast(up)] = j;
                            up += 1;
                        }
                    }
                }
                if (low == up) break;
            }
            if (low != up) break;
        }
        return .{ .column = j, .min = min, .last = last };
    }
};

// ---------------------------------------------------------------------------
// Writing.

const Writer = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    w: *Io.Writer,
    width: usize,
    abbrev_len: usize,
    dashes: ?usize = null,
    a: Allocator,

    fn pairHeader(s: *Writer, old: ?*const Patch, old_index: usize, new: ?*const Patch, new_index: usize) Error!void {
        const db = s.repo.objectDatabase();
        const oid = if (old) |p| p.oid else new.?.oid;
        if (s.dashes == null) {
            var buf: [hash.max_hex_len]u8 = undefined;
            s.dashes = (try abbrev.unique(s.io, db, oid, s.abbrev_len, &buf)).len;
        }
        const status: u8 = if (new == null) '<' else if (old == null) '>' else if (std.mem.eql(u8, old.?.text, new.?.text)) '=' else '!';
        try s.side(old, old_index);
        try s.w.print(" {c} ", .{status});
        try s.side(new, new_index);
        var subject: std.ArrayList(u8) = .empty;
        try pretty.formatCommit(s.a, s.io, db, oid, "%s", .{}, &subject);
        const found = try db.read(s.io, oid);
        defer db.allocator().free(found.bytes);
        const commit = try object.Commit.parse(s.a, db.objectFormat(), try s.a.dupe(u8, found.bytes));
        try s.w.print(" {s}\n", .{try formatpatch.logText(s.a, &commit, subject.items)});
    }

    fn side(s: *Writer, patch: ?*const Patch, index: usize) Error!void {
        const p = patch orelse {
            try s.w.splatByteAll(' ', s.width - 1);
            try s.w.writeAll("-:  ");
            try s.w.splatByteAll('-', s.dashes.?);
            return;
        };
        var number: [20]u8 = undefined;
        // unreachable: a usize is at most 20 digits
        const text = std.mem.print(&number, "{d}", .{index + 1}) catch unreachable;
        if (text.len < s.width) try s.w.splatByteAll(' ', s.width - text.len);
        var buf: [hash.max_hex_len]u8 = undefined;
        try s.w.print("{s}:  {s}", .{ text, try abbrev.unique(s.io, s.repo.objectDatabase(), p.oid, s.abbrev_len, &buf) });
    }

    /// `patch_diff`: the diff of two patches, every line indented four
    /// spaces, its `@@` lines without their numbers, and the section a
    /// hunk is in after them.
    fn patchDiff(s: *Writer, old: *const Patch, new: *const Patch, options: diff.Options) Error!void {
        var body: Io.Writer.Allocating = .init(s.gpa);
        defer body.deinit();
        diff.unifiedBody(s.gpa, &body.writer, old.text, new.text, options) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        var lines = std.mem.splitScalar(u8, body.written(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try s.w.writeAll("    ");
            if (std.mem.startsWith(u8, line, "@@ ")) {
                const end = std.mem.findPos(u8, line, 3, "@@") orelse line.len - 2;
                try s.w.writeAll("@@");
                try s.w.writeAll(line[end + 2 ..]);
            } else try s.w.writeAll(line);
            try s.w.writeByte('\n');
        }
    }
};

/// The `section_headers` driver git gives the diff of two patches: ` ## <section> ##`
/// and `@@ <hunk>`, with at most one character before the `@@`.
fn sectionHeader(_: ?*const anyopaque, line: []const u8) ?[]const u8 {
    if (line.len >= 7 and std.mem.startsWith(u8, line, " ## ") and std.mem.endsWith(u8, line, " ##")) return line[4 .. line.len - 3];
    if (std.mem.startsWith(u8, line, "@@ ")) return line[3..];
    if (line.len >= 4 and std.mem.startsWith(u8, line[1..], "@@ ")) return line[4..];
    return null;
}

/// `output`: in the order of the new range, an old commit with no partner
/// shown once every old commit before it has been.
fn output(gpa: Allocator, io: Io, repo: *Repository, result: *RangeDiff, options: Options, w: *Io.Writer) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const config = repo.configuration();
    var diff_options = options.diff orelse try formatpatch.configuredDiff(config);
    diff_options.function_line = .{ .find = sectionHeader };
    const old = result.old;
    const new = result.new;
    var s: Writer = .{
        .gpa = gpa,
        .io = io,
        .repo = repo,
        .w = w,
        .a = arena.allocator(),
        .width = decimalWidth(1 + @max(old.len, new.len)),
        .abbrev_len = abbrev.defaultLength(config, repo.objectDatabase()),
    };
    const shown = try gpa.alloc(bool, old.len);
    defer gpa.free(shown);
    @memset(shown, false);

    var i: usize = 0;
    var j: usize = 0;
    while (i < old.len or j < new.len) {
        // skip the old commits already shown
        while (i < old.len and shown[i]) i += 1;

        // an old commit with no partner, once those before it are shown
        if (i < old.len and old[i].matching == null) {
            if (!options.right_only) try s.pairHeader(&old[i], i, null, 0);
            i += 1;
            continue;
        }

        // new commits with no partner
        while (j < new.len and new[j].matching == null) {
            if (!options.left_only) try s.pairHeader(null, 0, &new[j], j);
            j += 1;
        }

        // a pair
        if (j < new.len) {
            const k = new[j].matching.?;
            try s.pairHeader(&old[k], k, &new[j], j);
            if (options.patch) try s.patchDiff(&old[k], &new[j], diff_options);
            shown[k] = true;
            j += 1;
        }
    }
}

fn decimalWidth(n: usize) usize {
    var width: usize = 1;
    var rest = n;
    while (rest >= 10) : (rest /= 10) width += 1;
    return width;
}

test "the assignment of least cost is found, and a single column takes the first row" {
    const gpa = std.testing.allocator;
    // cost[column + 3 * row]
    const cost = [_]i32{
        4, 1, 3,
        2, 0, 5,
        3, 2, 2,
    };
    var column2row: [3]i32 = undefined;
    var row2column: [3]i32 = undefined;
    try computeAssignment(gpa, 3, 3, &cost, &column2row, &row2column);
    try std.testing.expectEqualSlices(i32, &.{ 1, 0, 2 }, &column2row);
    try std.testing.expectEqualSlices(i32, &.{ 1, 0, 2 }, &row2column);

    var one: [1]i32 = undefined;
    var other: [1]i32 = undefined;
    try computeAssignment(gpa, 1, 1, &.{7}, &one, &other);
    try std.testing.expectEqual(0, one[0]);
}
