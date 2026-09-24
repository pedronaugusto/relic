//! Differences: tree against tree, blob against blob, and the unified text
//! git prints.
//!
//! The algorithms are in `textdiff`; this is what turns them into the shapes
//! a caller wants — a name-status list, added and removed line counts, and a
//! patch with git's own headers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const textdiff = @import("textdiff.zig");
const rename = @import("rename.zig");
const similarity = @import("similarity.zig");
const attributes = @import("attributes.zig");
const config_mod = @import("config.zig");

const Oid = hash.Oid;

/// Which algorithm produces the edit script.
pub const Algorithm = textdiff.Algorithm;

/// Errors from a diff.
pub const Error = error{
    /// A tree entry pointed at something that is not a tree.
    NotATree,
    /// The trees nest deeper than the walk will go.
    TreeTooDeep,
} || rename.Error || Allocator.Error || odb_mod.Error || object.TreeParseError;

/// What happened to a path.
pub const Status = enum {
    added,
    modified,
    deleted,
    /// A file became a symlink, a symlink a gitlink, and so on.
    type_changed,
    renamed,
    copied,
};

/// One side of a change.
pub const Entry = struct {
    /// Owned by the `Changes` that produced it.
    path: []const u8,
    mode: object.Mode,
    oid: Oid,
};

/// One path's change.
pub const Change = struct {
    status: Status,
    /// Absent for an addition.
    old: ?Entry,
    /// Absent for a deletion.
    new: ?Entry,
    /// For a rename or a copy, how alike the two sides are, as a percentage.
    similarity: u8 = 0,

    /// The path a caller should show: the new one where there is one.
    pub fn path(c: Change) []const u8 {
        if (c.new) |e| return e.path;
        return c.old.?.path;
    }

    /// git's single letter for the status, for a caller that wants one.
    /// Presentation stays the caller's; this is only the letter.
    pub fn letter(c: Change) u8 {
        return switch (c.status) {
            .added => 'A',
            .modified => 'M',
            .deleted => 'D',
            .type_changed => 'T',
            .renamed => 'R',
            .copied => 'C',
        };
    }
};

/// The result of a tree comparison.
pub const Changes = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    items: []Change,

    /// Release everything.
    pub fn deinit(c: *Changes) void {
        var arena = c.arena.promote(c.gpa);
        arena.deinit();
        c.* = undefined;
    }

    /// The change for `path`, or `null`.
    pub fn find(c: *const Changes, path: []const u8) ?Change {
        for (c.items) |change| {
            if (std.mem.eql(u8, change.path(), path)) return change;
        }
        return null;
    }
};

/// How rename and copy detection behaves: git's `-M`, `-C` and
/// `--find-copies-harder`, by git's own pairing (`rename.zig`).
///
/// Off by default, which is what `git diff-tree --name-status -r` does
/// without `-M`. It is a heuristic with a threshold and a limit, and
/// turning it on changes what a diff means, so it is the caller's decision.
pub const RenameOptions = struct {
    /// How alike two files must be, as a percentage, before a deletion and
    /// an addition become a rename: `-M<n>%`. git's own default.
    threshold: u8 = 50,
    /// The most sources times destinations scored, squared: git's
    /// `diff.renameLimit`. Exact matches are found whatever this says;
    /// zero is no limit.
    limit: usize = 1000,
    /// `-C`: an addition that matches a file this diff modified becomes a
    /// copy of it.
    detect_copies: bool = false,
    /// `--find-copies-harder`: an unmodified file is a copy source too.
    find_copies_harder: bool = false,
};

/// How a tree comparison behaves.
pub const TreeOptions = struct {
    /// Rename and copy detection, or `null` for none.
    renames: ?RenameOptions = null,
    /// Only paths beginning with this prefix, `/`-separated.
    prefix: []const u8 = "",
};

const Flat = std.StringArrayHashMapUnmanaged(Entry);

/// Compare two trees, path by path.
///
/// Either side may be `null`, which compares against the empty tree — what
/// the first commit's diff is.
pub fn tree(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    old: ?Oid,
    new: ?Oid,
    options: TreeOptions,
) Error!Changes {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var old_entries: Flat = .empty;
    if (old) |oid| try flatten(arena, io, db, oid, "", &old_entries, 0);
    var new_entries: Flat = .empty;
    if (new) |oid| try flatten(arena, io, db, oid, "", &new_entries, 0);

    var changes: std.ArrayList(Change) = .empty;

    for (old_entries.keys(), old_entries.values()) |path, entry| {
        if (!underPrefix(path, options.prefix)) continue;
        if (new_entries.get(path)) |after| {
            if (after.oid.eql(entry.oid) and after.mode == entry.mode) continue;
            const status: Status = if (entry.mode.isBlob() != after.mode.isBlob() or
                (entry.mode == .symlink) != (after.mode == .symlink) or
                (entry.mode == .gitlink) != (after.mode == .gitlink))
                .type_changed
            else
                .modified;
            try changes.append(arena, .{ .status = status, .old = entry, .new = after });
            continue;
        }
        try changes.append(arena, .{ .status = .deleted, .old = entry, .new = null });
    }
    for (new_entries.keys(), new_entries.values()) |path, entry| {
        if (!underPrefix(path, options.prefix)) continue;
        if (old_entries.contains(path)) continue;
        try changes.append(arena, .{ .status = .added, .old = null, .new = entry });
    }

    std.mem.sort(Change, changes.items, {}, lessThanChange);

    if (options.renames) |rename_options| {
        try detectRenames(arena, io, db, gpa, &changes, &old_entries, rename_options);
        std.mem.sort(Change, changes.items, {}, lessThanChange);
    }

    return .{ .gpa = gpa, .arena = arena_instance.state, .items = changes.items };
}

fn underPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn lessThanChange(_: void, a: Change, b: Change) bool {
    return std.mem.order(u8, a.path(), b.path()) == .lt;
}

fn flatten(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    tree_oid: Oid,
    prefix: []const u8,
    out: *Flat,
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
        try out.put(arena, path, .{ .path = path, .mode = entry.mode, .oid = entry.oid });
    }
}

fn detectRenames(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    gpa: Allocator,
    changes: *std.ArrayList(Change),
    old_entries: *const Flat,
    options: RenameOptions,
) Error!void {
    _ = gpa;
    // git's queue: every change in path order, and with
    // `--find-copies-harder` every unchanged file as well.
    var queue: std.ArrayList(*rename.Pair) = .empty;
    var unchanged: std.ArrayList(Change) = .empty;
    if (options.detect_copies and options.find_copies_harder) {
        var changed: std.StringHashMapUnmanaged(void) = .empty;
        for (changes.items) |c| {
            if (c.old) |o| try changed.put(arena, o.path, {});
        }
        for (old_entries.values()) |entry| {
            if (changed.contains(entry.path)) continue;
            try unchanged.append(arena, .{ .status = .modified, .old = entry, .new = entry });
        }
    }
    var all: std.ArrayList(Change) = .empty;
    try all.appendSlice(arena, changes.items);
    try all.appendSlice(arena, unchanged.items);
    std.mem.sort(Change, all.items, {}, lessThanChange);
    for (all.items) |c| {
        const one = try arena.create(rename.Spec);
        const two = try arena.create(rename.Spec);
        one.* = specOf(c.old, if (c.new) |n| n.path else c.old.?.path, db.kind);
        two.* = specOf(c.new, if (c.old) |o| o.path else c.new.?.path, db.kind);
        const pair = try arena.create(rename.Pair);
        pair.* = .{ .one = one, .two = two };
        try queue.append(arena, pair);
    }
    const minimum: u32 = @as(u32, options.threshold) * similarity.max_score / 100;
    _ = try rename.detect(arena, io, db, &queue, .{
        .copies = options.detect_copies,
        .minimum_score = if (minimum == 0) 1 else minimum,
        .rename_limit = @intCast(options.limit),
        .rename_empty = true,
    });

    // `diff_resolve_rename_copy`: of the destinations sharing a source, all
    // but the last are copies, and all are when the source is still there.
    changes.clearRetainingCapacity();
    for (queue.items) |p| {
        const old: ?Entry = entryOf(p.one);
        const new: ?Entry = entryOf(p.two);
        if (p.renamed) {
            p.one.rename_used -= 1;
            const status: Status = if (p.one.rename_used > 0) .copied else .renamed;
            try changes.append(arena, .{
                .status = status,
                .old = old,
                .new = new,
                .similarity = @intCast(@as(u64, p.score) * 100 / similarity.max_score),
            });
            continue;
        }
        if (old != null and new != null and old.?.mode == new.?.mode and old.?.oid.eql(new.?.oid)) continue;
        const status: Status = if (old == null) .added else if (new == null) .deleted else if (typeChanged(old.?.mode, new.?.mode)) .type_changed else .modified;
        try changes.append(arena, .{ .status = status, .old = old, .new = new });
    }
}

fn specOf(entry: ?Entry, path: []const u8, kind: hash.Kind) rename.Spec {
    const e = entry orelse return .{ .path = path, .oid = Oid.zero(kind) };
    return .{ .path = e.path, .mode = e.mode.raw(), .oid = e.oid };
}

fn entryOf(spec: *const rename.Spec) ?Entry {
    if (!spec.valid()) return null;
    return .{ .path = spec.path, .mode = object.Mode.fromRaw(spec.mode) catch .file, .oid = spec.oid };
}

fn typeChanged(a: object.Mode, b: object.Mode) bool {
    return a.isBlob() != b.isBlob() or (a == .symlink) != (b == .symlink) or (a == .gitlink) != (b == .gitlink);
}

/// Added and removed line counts for one change.
pub const NumStat = struct {
    plus: usize,
    minus: usize,
    /// git prints `-` for both counts when either side is binary; a caller
    /// that wants that text writes it from here.
    binary: bool,
};

/// How a content diff behaves.
pub const Options = struct {
    algorithm: Algorithm = .myers,
    /// Lines of context on each side of a hunk.
    context: usize = 3,
    /// Whether to slide an ambiguous change group to the position with the
    /// best indentation. On by default, as it is in git since 2.14.
    indent_heuristic: bool = true,
    /// Whether to spend the time proving the script is minimal. git does
    /// not by default, and its output is what a fixture holds.
    minimal: bool = false,
    ignore_all_whitespace: bool = false,
    ignore_whitespace_change: bool = false,
    ignore_trailing_whitespace: bool = false,
    /// How many hexadecimal characters the `index` line carries. git's own
    /// default is seven in a small repository and grows with the object
    /// count; a caller that wants git's exact line passes what
    /// `core.abbrev` resolves to.
    abbrev: usize = 7,
    /// Whether the `@@` line carries the enclosing function's text, which
    /// git does by default.
    function_context_names: bool = true,
    /// A cap on the algorithm's work before it falls back to a coarser but
    /// correct script.
    max_work: usize = 0,
    /// Old-side lines beginning with one of these stay as context where
    /// they can, which is `git diff --anchored`. Read by the patience
    /// algorithm only, as in git, where `--anchored` also selects it.
    anchors: []const []const u8 = &.{},
};

/// Errors from reading the diff settings out of a configuration.
pub const ConfigError = error{
    /// `diff.algorithm` names something other than `default`, `myers`,
    /// `minimal`, `patience` or `histogram`, which git refuses too.
    UnknownDiffAlgorithm,
};

/// `options` with the algorithm `diff.algorithm` names, which is the one
/// `git diff`, `git log -p` and `git show` use when none is asked for.
///
/// The value is read without regard to case, as git reads it. `minimal` is
/// Myers made to prove its script minimal, and `default` is Myers. With the
/// setting absent `options` comes back as it was given.
pub fn configured(config: *const config_mod.Config, options: Options) ConfigError!Options {
    const text = config.get("diff.algorithm") orelse return options;
    var out = options;
    if (std.ascii.eqlIgnoreCase(text, "myers") or std.ascii.eqlIgnoreCase(text, "default")) {
        out.algorithm = .myers;
    } else if (std.ascii.eqlIgnoreCase(text, "minimal")) {
        out.algorithm = .myers;
        out.minimal = true;
    } else if (std.ascii.eqlIgnoreCase(text, "patience")) {
        out.algorithm = .patience;
    } else if (std.ascii.eqlIgnoreCase(text, "histogram")) {
        out.algorithm = .histogram;
    } else {
        return error.UnknownDiffAlgorithm;
    }
    return out;
}

fn toTextOptions(options: Options) textdiff.Options {
    return .{
        .algorithm = options.algorithm,
        .context = options.context,
        .indent_heuristic = options.indent_heuristic,
        .minimal = options.minimal,
        .ignore_all_whitespace = options.ignore_all_whitespace,
        .ignore_whitespace_change = options.ignore_whitespace_change,
        .ignore_trailing_whitespace = options.ignore_trailing_whitespace,
        .max_work = options.max_work,
        .anchors = options.anchors,
    };
}

/// git's diff binary rule: a NUL in the first 8000 bytes.
///
/// This is not the rule that decides whether a file is normalised on
/// check-in; that one is `attributes.isBinaryForCheckIn`, and using this one
/// there writes a different blob.
pub fn isBinary(bytes: []const u8) bool {
    return attributes.isBinaryForDiff(bytes);
}

fn gitlinkText(buf: []u8, oid: Oid) []const u8 {
    var hex: [hash.max_hex_len]u8 = undefined;
    return std.fmt.bufPrint(buf, "Subproject commit {s}\n", .{oid.hex(&hex)}) catch unreachable;
}

/// The added and removed line counts between two blobs.
pub fn blobNumStat(gpa: Allocator, old: []const u8, new: []const u8, options: Options) Allocator.Error!NumStat {
    if (isBinary(old) or isBinary(new)) return .{ .plus = 0, .minus = 0, .binary = true };
    const old_lines = try textdiff.splitLines(gpa, old);
    defer gpa.free(old_lines);
    const new_lines = try textdiff.splitLines(gpa, new);
    defer gpa.free(new_lines);
    const script = try textdiff.diffLines(gpa, old_lines, new_lines, toTextOptions(options));
    defer gpa.free(script);
    const counts = textdiff.stat(script);
    return .{ .plus = counts.plus, .minus = counts.minus, .binary = false };
}

/// The counts for every change in a tree comparison, in the same order.
///
/// The result is the caller's.
pub fn numstat(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    changes: []const Change,
    options: Options,
) Error![]NumStat {
    var out = try gpa.alloc(NumStat, changes.len);
    errdefer gpa.free(out);
    for (changes, 0..) |change, i| {
        // A gitlink has no content in this repository; git counts it as one
        // line changed either way, which is what a commit name is.
        var old_gitlink: [96]u8 = undefined;
        const old_bytes: []const u8 = if (change.old) |entry| blk: {
            if (entry.mode == .gitlink) break :blk gitlinkText(&old_gitlink, entry.oid);
            const found = try db.read(io, entry.oid);
            break :blk found.bytes;
        } else "";
        defer if (change.old) |entry| {
            if (entry.mode != .gitlink) gpa.free(@constCast(old_bytes));
        };
        var new_gitlink: [96]u8 = undefined;
        const new_bytes: []const u8 = if (change.new) |entry| blk: {
            if (entry.mode == .gitlink) break :blk gitlinkText(&new_gitlink, entry.oid);
            const found = try db.read(io, entry.oid);
            break :blk found.bytes;
        } else "";
        defer if (change.new) |entry| {
            if (entry.mode != .gitlink) gpa.free(@constCast(new_bytes));
        };
        out[i] = try blobNumStat(gpa, old_bytes, new_bytes, options);
    }
    return out;
}

/// Append a unified diff for one change to `w`, with git's headers.
pub fn unified(
    gpa: Allocator,
    io: Io,
    w: *Io.Writer,
    db: *odb_mod.Odb,
    change: Change,
    options: Options,
) (Error || Io.Writer.Error)!void {
    const old_path = if (change.old) |e| e.path else change.new.?.path;
    const new_path = if (change.new) |e| e.path else change.old.?.path;

    try w.print("diff --git a/{s} b/{s}\n", .{ old_path, new_path });

    var old_mode_buf: [6]u8 = undefined;
    var new_mode_buf: [6]u8 = undefined;
    switch (change.status) {
        .added => try w.print("new file mode {s}\n", .{change.new.?.mode.text(&new_mode_buf)}),
        .deleted => try w.print("deleted file mode {s}\n", .{change.old.?.mode.text(&old_mode_buf)}),
        .renamed, .copied => {
            try w.print("similarity index {d}%\n", .{change.similarity});
            if (change.status == .renamed) {
                try w.print("rename from {s}\nrename to {s}\n", .{ old_path, new_path });
            } else {
                try w.print("copy from {s}\ncopy to {s}\n", .{ old_path, new_path });
            }
            if (change.old.?.mode != change.new.?.mode) {
                try w.print("old mode {s}\nnew mode {s}\n", .{
                    change.old.?.mode.text(&old_mode_buf),
                    change.new.?.mode.text(&new_mode_buf),
                });
            }
        },
        .modified, .type_changed => {
            if (change.old.?.mode != change.new.?.mode) {
                try w.print("old mode {s}\nnew mode {s}\n", .{
                    change.old.?.mode.text(&old_mode_buf),
                    change.new.?.mode.text(&new_mode_buf),
                });
            }
        },
    }

    const old_oid = if (change.old) |e| e.oid else Oid.zero(db.kind);
    const new_oid = if (change.new) |e| e.oid else Oid.zero(db.kind);
    if (old_oid.eql(new_oid)) {
        // Only the mode moved: git prints no index line and no hunks.
        return;
    }

    var old_hex: [hash.max_hex_len]u8 = undefined;
    var new_hex: [hash.max_hex_len]u8 = undefined;
    try w.print("index {s}..{s}", .{
        old_oid.abbrev(&old_hex, options.abbrev),
        new_oid.abbrev(&new_hex, options.abbrev),
    });
    // The mode is on the index line only when it did not change and the
    // file was neither created nor removed; otherwise it is on its own line
    // above.
    if (change.old != null and change.new != null and change.old.?.mode == change.new.?.mode) {
        try w.print(" {s}\n", .{change.new.?.mode.text(&new_mode_buf)});
    } else {
        try w.writeByte('\n');
    }

    var old_gitlink: [96]u8 = undefined;
    const old_bytes: []const u8 = if (change.old) |entry| blk: {
        if (entry.mode == .gitlink) break :blk gitlinkText(&old_gitlink, entry.oid);
        const found = try db.read(io, entry.oid);
        break :blk found.bytes;
    } else "";
    defer if (change.old) |entry| {
        if (entry.mode != .gitlink) gpa.free(@constCast(old_bytes));
    };
    var new_gitlink: [96]u8 = undefined;
    const new_bytes: []const u8 = if (change.new) |entry| blk: {
        if (entry.mode == .gitlink) break :blk gitlinkText(&new_gitlink, entry.oid);
        const found = try db.read(io, entry.oid);
        break :blk found.bytes;
    } else "";
    defer if (change.new) |entry| {
        if (entry.mode != .gitlink) gpa.free(@constCast(new_bytes));
    };

    if (isBinary(old_bytes) or isBinary(new_bytes)) {
        try w.print("Binary files a/{s} and b/{s} differ\n", .{ old_path, new_path });
        return;
    }

    if (change.status == .added) {
        try w.writeAll("--- /dev/null\n");
    } else {
        try w.print("--- a/{s}\n", .{old_path});
    }
    if (change.status == .deleted) {
        try w.writeAll("+++ /dev/null\n");
    } else {
        try w.print("+++ b/{s}\n", .{new_path});
    }
    try unifiedBody(gpa, w, old_bytes, new_bytes, options);
}

/// Append the `@@` hunks for two blobs, with no `diff --git` header.
///
/// This is what a caller that wants only the body asks for, and what
/// `unified` uses.
pub fn unifiedBody(
    gpa: Allocator,
    w: *Io.Writer,
    old: []const u8,
    new: []const u8,
    options: Options,
) (Allocator.Error || Io.Writer.Error)!void {
    const old_lines = try textdiff.splitLines(gpa, old);
    defer gpa.free(old_lines);
    const new_lines = try textdiff.splitLines(gpa, new);
    defer gpa.free(new_lines);
    const text_options = toTextOptions(options);
    const script = try textdiff.diffLines(gpa, old_lines, new_lines, text_options);
    defer gpa.free(script);
    const groups = try textdiff.hunks(gpa, script, old_lines.len, new_lines.len, text_options);
    defer gpa.free(groups);

    // git looks backwards from each hunk for the enclosing line, stopping
    // where the previous hunk's search began. When it finds none it keeps
    // the one it found last, which is why a second hunk inside the same
    // function still carries that function's name.
    var previous_start: isize = -1;
    var last_found: ?[]const u8 = null;
    for (groups) |hunk| {
        try w.writeAll("@@ -");
        try writeRange(w, hunk.old_start, hunk.old_count);
        try w.writeAll(" +");
        try writeRange(w, hunk.new_start, hunk.new_count);
        try w.writeAll(" @@");
        if (options.function_context_names) {
            const from: isize = @as(isize, @intCast(hunk.old_start)) - 1;
            if (functionLine(old_lines, from, previous_start)) |text| last_found = text;
            previous_start = from;
            if (last_found) |text| {
                if (text.len != 0) {
                    try w.writeByte(' ');
                    try w.writeAll(text);
                }
            }
        }
        try w.writeByte('\n');

        var old_at = hunk.old_start;
        var new_at = hunk.new_start;
        for (hunk.changes) |change| {
            while (old_at < change.old_start) {
                try writeLine(w, ' ', old_lines[old_at]);
                old_at += 1;
                new_at += 1;
            }
            var i: usize = 0;
            while (i < change.old_count) : (i += 1) {
                try writeLine(w, '-', old_lines[old_at]);
                old_at += 1;
            }
            i = 0;
            while (i < change.new_count) : (i += 1) {
                try writeLine(w, '+', new_lines[new_at]);
                new_at += 1;
            }
        }
        while (old_at < hunk.old_start + hunk.old_count) {
            try writeLine(w, ' ', old_lines[old_at]);
            old_at += 1;
            new_at += 1;
        }
    }
}

fn writeRange(w: *Io.Writer, start: usize, count: usize) Io.Writer.Error!void {
    // An empty range is printed at the line before it, and with no count
    // when the count is one, which is what every unified diff does.
    if (count == 0) {
        try w.print("{d},0", .{start});
        return;
    }
    if (count == 1) {
        try w.print("{d}", .{start + 1});
        return;
    }
    try w.print("{d},{d}", .{ start + 1, count });
}

fn writeLine(w: *Io.Writer, prefix: u8, line: []const u8) Io.Writer.Error!void {
    try w.writeByte(prefix);
    if (line.len != 0 and line[line.len - 1] == '\n') {
        try w.writeAll(line);
        return;
    }
    try w.writeAll(line);
    try w.writeAll("\n\\ No newline at end of file\n");
}

/// The text git puts after the second `@@`.
///
/// It is the nearest line at or before `from` that begins with a letter, an
/// underscore or a dollar sign, with its trailing whitespace removed and
/// capped at forty characters — git's own default, which has no language in
/// it at all.
fn functionLine(lines: []const textdiff.Line, from: isize, limit: isize) ?[]const u8 {
    var at = from;
    while (at > limit and at >= 0 and at < @as(isize, @intCast(lines.len))) : (at -= 1) {
        var line = lines[@intCast(at)];
        if (line.len == 0) continue;
        const first = line[0];
        if (!std.ascii.isAlphabetic(first) and first != '_' and first != '$') continue;
        if (line.len > function_context_max) line = line[0..function_context_max];
        var end = line.len;
        while (end > 0 and std.ascii.isWhitespace(line[end - 1])) end -= 1;
        return line[0..end];
    }
    return null;
}

/// How much of the enclosing line git puts on the `@@` line.
pub const function_context_max: usize = 40;

test "a unified body matches the shape git prints" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try unifiedBody(
        gpa,
        &out.writer,
        "one\ntwo\nthree\nfour\nfive\n",
        "one\ntwo\nTHREE\nfour\nfive\n",
        .{},
    );
    try std.testing.expectEqualStrings(
        "@@ -1,5 +1,5 @@\n one\n two\n-three\n+THREE\n four\n five\n",
        out.written(),
    );
}

test "an empty range is printed the way a unified diff prints it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try unifiedBody(gpa, &out.writer, "", "added\n", .{});
    try std.testing.expectEqualStrings("@@ -0,0 +1 @@\n+added\n", out.written());

    out.clearRetainingCapacity();
    try unifiedBody(gpa, &out.writer, "gone\n", "", .{});
    try std.testing.expectEqualStrings("@@ -1 +0,0 @@\n-gone\n", out.written());
}

test "a missing final newline is marked" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try unifiedBody(gpa, &out.writer, "one\n", "one", .{});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\\ No newline at end of file") != null);
}

test "the binary rule is the diff one" {
    try std.testing.expect(isBinary("a\x00b"));
    try std.testing.expect(!isBinary("a\rb"));
}
