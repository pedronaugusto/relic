//! Differences: tree against tree, blob against blob, and the unified text
//! git prints.
//!
//! The line diff is parallax's; this is what turns it into the shapes a
//! caller wants — a name-status list, added and removed line counts, and a
//! patch with git's own headers.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.diff.<name>`.
const rename = @import("rename.zig");
const similarity = @import("similarity.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const parallax = @import("parallax");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const attributes = @import("../patterns.zig").attributes;
const user_diff = @import("user_diff.zig");
const textconv_mod = @import("textconv.zig");
const config_mod = @import("../config/config.zig");
const glob = @import("../text.zig").glob;
const pathspec = @import("../patterns.zig").pathspec;
const whitespace = @import("../text.zig").whitespace;
const c_quote = @import("../text.zig").c_quote;
const paint = @import("paint.zig");
const color_mod = @import("../config/color.zig");
const moved = @import("moved.zig");
const binarypatch = @import("binary.zig");
const abbrev = @import("../odb/abbrev.zig");

const Oid = hash.Oid;

/// The colours a patch is written in, as `color.diff.<slot>` sets them.
pub const Colors = paint.Colors;
/// Which lines a coloured patch marks whitespace errors on.
pub const WsErrorHighlight = paint.WsErrorHighlight;
/// How range-diff writes the diff of two patches.
pub const DiffOfPatches = paint.DiffOfPatches;
/// How moved lines are shown in a coloured patch.
pub const ColorMoved = moved.ColorMoved;
/// What whitespace moved lines may differ in.
pub const ColorMovedWs = moved.ColorMovedWs;

/// Which algorithm produces the edit script: parallax's.
pub const Algorithm = parallax.Algorithm;

/// Git's common algorithm grammar, shared by configuration and merge options.
pub const LineDiff = struct {
    algorithm: Algorithm,
    minimal: bool = false,

    pub fn parse(text: []const u8) ?LineDiff {
        if (std.ascii.eqlIgnoreCase(text, "myers") or std.ascii.eqlIgnoreCase(text, "default")) return .{ .algorithm = .myers };
        if (std.ascii.eqlIgnoreCase(text, "minimal")) return .{ .algorithm = .myers, .minimal = true };
        if (std.ascii.eqlIgnoreCase(text, "patience")) return .{ .algorithm = .patience };
        if (std.ascii.eqlIgnoreCase(text, "histogram")) return .{ .algorithm = .histogram };
        return null;
    }
};

/// Git's `MAX_XDIFF_SIZE`, checked before content scanning or line indexing.
pub const max_text_bytes: usize = 1023 * 1024 * 1024;

fn checkTextSize(old: []const u8, new: []const u8) TextError!void {
    if (old.len > max_text_bytes or new.len > max_text_bytes) return error.InputTooLarge;
}

/// Errors from diffing two texts.
pub const TextError = Allocator.Error || error{
    /// A side exceeds Git's 1023 MiB limit, or the two hold 2^32 lines or more
    /// between them: more than a line diff numbers.
    InputTooLarge,
};

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
    pub const Error = ErrorNamespace.Error;

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
    /// git's `single_follow`: only this path may be the destination of a
    /// rename or a copy, as `git log --follow` asks.
    single_follow: ?[]const u8 = null,
};

/// How a tree comparison behaves.
pub const TreeOptions = struct {
    /// Rename and copy detection, or `null` for none.
    renames: ?RenameOptions = null,
    /// Only paths under this directory, `/`-separated; a trailing `/`, as
    /// git's prefix has, is the same directory.
    prefix: []const u8 = "",
    /// An order file's patterns (`-O`, `diff.orderFile`: `Order`): the
    /// changes come out in the order of the first pattern each path
    /// matches, the rest after them, otherwise as they were.
    order: Order = .{},
    /// `-- <paths>`: only the paths these name, and the subtrees on the
    /// way to them.
    paths: ?*const pathspec.Pathspec = null,
    /// `--max-depth=<n>`: a subtree below this many levels -- from the top,
    /// or from the pathspec item it lies in -- is listed as one change, its
    /// mode a tree's, and not entered. `null` enters every subtree. Never
    /// with a wildcard in `paths`, which git refuses.
    max_depth: ?u32 = null,
    /// `-t`: a subtree entered is listed too, ahead of what changed in it.
    trees: bool = false,
};

/// An order file, as git's `diffcore_order` reads and applies it: one
/// pattern a line, blank lines and lines beginning `#` passed over, the
/// rest kept whole. A path takes the first pattern that matches it or one
/// of its leading directories, as `wildmatch` with no flags matches (`*`
/// crosses `/`); a path matching none comes after all of them.
pub const Order = struct {
    patterns: []const []const u8 = &.{},

    /// The patterns of an order file's `text`, borrowing it; the list is
    /// `arena`'s.
    pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Order {
        var patterns: std.ArrayList([]const u8) = .empty;
        var at: usize = 0;
        while (at < text.len) {
            const end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
            const line = text[at..end];
            if (line.len != 0 and line[0] != '#') try patterns.append(arena, line);
            at = end + 1;
        }
        return .{ .patterns = patterns.items };
    }

    /// Which pattern `path` takes: its index, or the count for none.
    pub fn rank(o: Order, gpa: Allocator, path: []const u8) Allocator.Error!usize {
        for (o.patterns, 0..) |pattern, i| {
            var subject = path;
            while (subject.len != 0) {
                if (try glob.matches(gpa, pattern, subject, .{ .pathname = false })) return i;
                subject = subject[0 .. std.mem.findScalarLast(u8, subject, '/') orelse break];
            }
        }
        return o.patterns.len;
    }

    /// `changes` in the order's order, stable, as git's sort keeps equal
    /// ranks in their order.
    fn apply(o: Order, arena: Allocator, changes: []Change) Allocator.Error!void {
        if (o.patterns.len == 0 or changes.len < 2) return;
        const Ranked = struct { rank: usize, change: Change };
        const ranked = try arena.alloc(Ranked, changes.len);
        for (changes, ranked) |c, *r| r.* = .{ .rank = try o.rank(arena, c.path()), .change = c };
        std.sort.block(Ranked, ranked, {}, struct {
            fn less(_: void, a: Ranked, b: Ranked) bool {
                return a.rank < b.rank;
            }
        }.less);
        for (changes, ranked) |*c, r| c.* = r.change;
    }

    /// Errors from `configured`.
    pub const ConfiguredError = config_mod.PathSettingError || error{
        /// The order file named cannot be read, which git dies on.
        OrderFileUnreadable,
    };

    /// The order file `diff.orderFile` names, a path setting found from
    /// `base` (`Config.getPath`), read whole; none when it is not set.
    /// Everything is `arena`'s.
    pub fn configured(arena: Allocator, io: Io, base: Io.Dir, config: *const config_mod.Config) ConfiguredError!Order {
        const path = (try config.getPath(arena, io, base, "diff.orderfile")) orelse return .{};
        const text = base.readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OrderFileUnreadable,
        };
        return parse(arena, text);
    }
};

const Flat = std.array_hash_map.String(Entry);

/// Compare two trees, path by path.
///
/// Either side may be `null`, which compares against the empty tree — what
/// the first commit's diff is.
pub const TreeInputs = struct { old: ?Oid = null, new: ?Oid = null };
pub fn tree(gpa: Allocator, io: Io, db: *odb_mod.Odb, inputs: TreeInputs, options: TreeOptions) Self.Error!Changes {
    const old = inputs.old;
    const new = inputs.new;

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // git's `diff_setup_done` refuses the two together; its walk asserts it.
    if (options.max_depth != null) if (options.paths) |paths| std.debug.assert(!paths.hasWildcard());
    var changes: std.ArrayList(Change) = .empty;
    var walk: Walk = .{ .arena = arena, .io = io, .db = db, .prefix = options.prefix, .out = &changes, .paths = options.paths, .max_depth = options.max_depth, .list_trees = options.trees };
    try walk.trees(old, new, "", 0);

    // `--find-copies-harder` offers every file of the old tree as a source.
    var old_entries: Flat = .empty;
    const harder = if (options.renames) |r| r.detect_copies and r.find_copies_harder else false;
    if (harder) if (old) |oid| try flatten(arena, io, db, oid, "", &old_entries, 0);

    std.mem.sort(Change, changes.items, {}, lessThanChange);

    if (options.renames) |rename_options| {
        try detectRenames(arena, io, db, &changes, &old_entries, rename_options, null);
        std.mem.sort(Change, changes.items, {}, lessThanChange);
    }
    try options.order.apply(arena, changes.items);

    return .{ .gpa = gpa, .arena = arena_instance.state, .items = changes.items };
}

/// Two trees walked side by side, as git's tree diff walks them: a subtree
/// both sides hold under the same name is passed over without being read,
/// so the cost is the part of the trees that differs and not their size.
const Walk = struct {
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    prefix: []const u8,
    out: *std.ArrayList(Change),
    paths: ?*const pathspec.Pathspec = null,
    max_depth: ?u32 = null,
    list_trees: bool = false,

    fn trees(w: *Walk, old: ?Oid, new: ?Oid, base: []const u8, depth: u32) Error!void {
        if (depth > object.max_tree_depth) return error.TreeTooDeep;
        if (old != null and new != null and old.?.eql(new.?)) return;
        const old_bytes = if (old) |oid| try w.readTree(oid) else null;
        defer if (old_bytes) |b| w.db.allocator().free(b);
        const new_bytes = if (new) |oid| try w.readTree(oid) else null;
        defer if (new_bytes) |b| w.db.allocator().free(b);
        const kind = w.db.objectFormat();
        var old_it = object.Tree.parse(kind, old_bytes orelse "").iterate();
        var new_it = object.Tree.parse(kind, new_bytes orelse "").iterate();
        var a = try old_it.next();
        var b = try new_it.next();
        while (a != null or b != null) {
            const order: std.math.Order = if (a == null) .gt else if (b == null) .lt else treeOrder(a.?, b.?);
            switch (order) {
                .lt => {
                    try w.oneSide(a.?, base, .deleted, depth);
                    a = try old_it.next();
                },
                .gt => {
                    try w.oneSide(b.?, base, .added, depth);
                    b = try new_it.next();
                },
                .eq => {
                    try w.bothSides(a.?, b.?, base, depth);
                    a = try old_it.next();
                    b = try new_it.next();
                },
            }
        }
    }

    fn readTree(w: *Walk, oid: Oid) Error![]u8 {
        const found = try w.db.read(w.io, oid);
        if (found.type != .tree) {
            w.db.allocator().free(found.bytes);
            return error.NotATree;
        }
        return found.bytes;
    }

    /// An entry on one side only: a file added or deleted, or every file
    /// of a subtree.
    fn oneSide(w: *Walk, e: object.Tree.Entry, base: []const u8, status: Status, depth: u32) Error!void {
        const path = (try w.pathIfWanted(e, base)) orelse return;
        const entry: Entry = .{ .path = path, .mode = e.mode, .oid = e.oid };
        if (e.mode.isTree() and w.enters(path)) {
            if (w.list_trees) try w.out.append(w.arena, if (status == .deleted)
                .{ .status = .deleted, .old = entry, .new = null }
            else
                .{ .status = .added, .old = null, .new = entry });
            return if (status == .deleted) w.trees(e.oid, null, path, depth + 1) else w.trees(null, e.oid, path, depth + 1);
        }
        try w.out.append(w.arena, if (status == .deleted)
            .{ .status = .deleted, .old = entry, .new = null }
        else
            .{ .status = .added, .old = null, .new = entry });
    }

    /// One name on both sides, both subtrees or neither.
    fn bothSides(w: *Walk, a: object.Tree.Entry, b: object.Tree.Entry, base: []const u8, depth: u32) Error!void {
        if (a.oid.eql(b.oid) and a.mode == b.mode) return;
        const path = (try w.pathIfWanted(a, base)) orelse return;
        const entered = a.mode.isTree() and w.enters(path);
        if (entered and !w.list_trees) return w.trees(a.oid, b.oid, path, depth + 1);
        const status: Status = if (a.mode.isBlob() != b.mode.isBlob() or
            (a.mode == .symlink) != (b.mode == .symlink) or
            (a.mode == .gitlink) != (b.mode == .gitlink))
            .type_changed
        else
            .modified;
        try w.out.append(w.arena, .{
            .status = status,
            .old = .{ .path = path, .mode = a.mode, .oid = a.oid },
            .new = .{ .path = path, .mode = b.mode, .oid = b.oid },
        });
        if (entered) return w.trees(a.oid, b.oid, path, depth + 1);
    }

    /// git's `should_recurse`: whether the subtree at `path` is entered,
    /// or listed as one change.
    fn enters(w: *const Walk, path: []const u8) bool {
        const max = w.max_depth orelse return true;
        if (w.paths) |paths| return paths.entersAt(path, max);
        return pathspec.entersTop(path, max);
    }

    /// The entry's path, or `null` when the prefix or the pathspec leaves
    /// it out: a file outside them, or a subtree that neither lies inside
    /// them nor holds what they name.
    fn pathIfWanted(w: *Walk, e: object.Tree.Entry, base: []const u8) Allocator.Error!?[]const u8 {
        const path = if (base.len == 0) try w.arena.dupe(u8, e.name) else try w.arena.print("{s}/{s}", .{ base, e.name });
        const in_prefix = underPrefix(path, w.prefix) or
            (e.mode.isTree() and std.mem.startsWith(u8, w.prefix, path) and w.prefix[path.len] == '/');
        if (!in_prefix) return null;
        const paths = w.paths orelse return path;
        if (e.mode.isTree()) return if (paths.matchesDir(path) or paths.couldMatchUnder(path)) path else null;
        return if (paths.matches(path)) path else null;
    }
};

/// git's order of tree entries: by name, a subtree's with `/` after it.
fn treeOrder(a: object.Tree.Entry, b: object.Tree.Entry) std.math.Order {
    const len = @min(a.name.len, b.name.len);
    switch (std.mem.order(u8, a.name[0..len], b.name[0..len])) {
        .eq => {},
        else => |o| return o,
    }
    const ca: u8 = if (a.name.len > len) a.name[len] else if (a.mode.isTree()) '/' else 0;
    const cb: u8 = if (b.name.len > len) b.name[len] else if (b.mode.isTree()) '/' else 0;
    return std.math.order(ca, cb);
}

fn underPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix[prefix.len - 1] == '/') return std.mem.startsWith(u8, path, prefix);
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// By path, in git's tree order: a subtree's path with `/` after it, so
/// it comes where its contents do.
fn lessThanChange(_: void, a: Change, b: Change) bool {
    const pa = a.path();
    const pb = b.path();
    const la = pa.len + @intFromBool(isTreeChange(a));
    const lb = pb.len + @intFromBool(isTreeChange(b));
    for (0..@min(la, lb)) |i| {
        const ca: u8 = if (i < pa.len) pa[i] else '/';
        const cb: u8 = if (i < pb.len) pb[i] else '/';
        if (ca != cb) return ca < cb;
    }
    return la < lb;
}

fn isTreeChange(c: Change) bool {
    const e = c.new orelse c.old.?;
    return e.mode.isTree();
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
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const parsed: object.Tree = .parse(db.objectFormat(), found.bytes);
    var it = parsed.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try arena.print("{s}/{s}", .{ prefix, entry.name });
        if (entry.mode == .tree) {
            try flatten(arena, io, db, entry.oid, path, out, depth + 1);
            continue;
        }
        try out.put(arena, path, .{ .path = path, .mode = entry.mode, .oid = entry.oid });
    }
}

/// Pair the deletions and additions among `changes` as `tree` pairs them,
/// git's `diffcore_rename`, writing the list back as git writes its queue:
/// a rename or copy where its destination stood, a deletion whose file
/// went somewhere gone. For changes made elsewhere than between two trees,
/// such as a status's, staged or in the working tree; their paths and
/// everything allocated are `arena`'s.
pub fn findRenames(arena: Allocator, io: Io, blobs: RenameBlobs, changes: *std.ArrayList(Change), options: RenameOptions) Self.Error!void {
    std.mem.sort(Change, changes.items, {}, lessThanChange);
    try detectRenames(arena, io, blobs.db, changes, &Flat.empty, options, blobs.contents);
    std.mem.sort(Change, changes.items, {}, lessThanChange);
}

fn detectRenames(
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    changes: *std.ArrayList(Change),
    old_entries: *const Flat,
    options: RenameOptions,
    contents: ?*const std.AutoHashMapUnmanaged(Oid, []const u8),
) Error!void {
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
        one.* = specOf(c.old, if (c.new) |n| n.path else c.old.?.path, db.objectFormat());
        two.* = specOf(c.new, if (c.old) |o| o.path else c.new.?.path, db.objectFormat());
        const pair = try arena.create(rename.Pair);
        pair.* = .{ .one = one, .two = two };
        try queue.append(arena, pair);
    }
    const minimum: u32 = @as(u32, options.threshold) * similarity.max_score / 100;
    _ = try rename.detect(arena, io, db, &queue, .{
        .copies = options.detect_copies,
        .single_follow = options.single_follow,
        .minimum_score = if (minimum == 0) 1 else minimum,
        .rename_limit = @intCast(options.limit),
        .rename_empty = true,
        .contents = contents,
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
    context: u32 = 3,
    /// Unchanged lines between two hunks that are shown, joining them,
    /// rather than cut: `--inter-hunk-context`. Two hunks whose contexts
    /// meet are always joined.
    inter_hunk_context: u32 = 0,
    /// Whether to slide an ambiguous change group to the position with the
    /// best indentation. On by default, as it is in git since 2.14.
    indent_heuristic: bool = true,
    /// `diff.suppressBlankEmpty`: a context line that is a line ending
    /// alone is written without its space.
    suppress_blank_empty: bool = false,
    /// Whether to spend the time proving the script is minimal. git does
    /// not by default, and its output is what a fixture holds.
    minimal: bool = false,
    ignore_all_whitespace: bool = false,
    ignore_whitespace_change: bool = false,
    ignore_trailing_whitespace: bool = false,
    /// How many hexadecimal characters the `index` line carries. git's own
    /// default is seven in a small repository and grows with the object
    /// count; a caller that wants git's exact line passes what
    /// `core.abbrev` resolves to. A name is lengthened past it until no
    /// other object shares the prefix, as git's are.
    abbrev: usize = 7,
    /// `--full-index`: the `index` line names its objects in full.
    full_index: bool = false,
    /// `--binary`: a binary file's change is written as a `GIT binary
    /// patch`, its objects named in full, rather than as `Binary files
    /// ... differ`.
    binary_patches: bool = false,
    /// `--relative`: the directory, with its trailing slash, the headers
    /// name paths from; a path outside it keeps its whole name. Which
    /// changes are shown is the caller's: git shows only those under it.
    relative_to: []const u8 = "",
    /// Whether the `@@` line carries the enclosing function's text, which
    /// git does by default.
    function_context_names: bool = true,
    /// What starts a function, in place of git's default rule: a diff
    /// driver's `funcname`, as a caller decides it.
    function_line: ?FunctionLine = null,
    /// A cap on the algorithm's work before it falls back to a coarser but
    /// correct script.
    max_work: u32 = 0,
    /// Old-side lines beginning with one of these stay as context where
    /// they can, which is `git diff --anchored`. Read by the patience
    /// algorithm only, as in git, where `--anchored` also selects it.
    anchors: []const []const u8 = &.{},
    /// The colours a patch is written in, `null` for none: what
    /// `Colors.configured` gives where git colours.
    colors: ?*const Colors = null,
    /// The whitespace errors a coloured patch marks: `core.whitespace`,
    /// with the path's `whitespace` attribute applied as
    /// `WhitespaceRule.of` applies it. git's default is
    /// `blank-at-eol,space-before-tab,blank-at-eof`, tabs eight wide.
    whitespace_rule: u32 = whitespace.default_rule,
    /// Which lines a coloured patch marks whitespace errors on.
    ws_error_highlight: WsErrorHighlight = .{},
    /// How a coloured patch shows the lines that moved, found over every
    /// file `unified` is given: `diff.colorMoved`.
    color_moved: ColorMoved = .no,
    /// What whitespace a moved line may differ in: `diff.colorMovedWS`.
    color_moved_ws: ColorMovedWs = .{},
    /// range-diff's diff of two patches (`DiffOfPatches`), for
    /// `unifiedBody`; `null` for any other diff.
    diff_of_patches: ?DiffOfPatches = null,
    /// `core.quotePath`: whether a name's bytes above 0x7f are quoted
    /// in the headers, as well as its control characters, quotes and
    /// backslashes.
    quote_path: bool = true,
};

/// A caller's rule for the text after a hunk's `@@`: given a line without
/// its newline, the part to show when the line starts a function, as a
/// driver's `funcname` pattern gives its first group, or `null`. git cuts
/// what it gives at eighty bytes and drops its trailing whitespace.
pub const FunctionLine = struct {
    context: ?*const anyopaque = null,
    find: *const fn (context: ?*const anyopaque, line: []const u8) ?[]const u8,
};

/// Errors from reading the diff settings out of a configuration.
pub const ConfigError = error{
    /// `diff.algorithm` names something other than `default`, `myers`,
    /// `minimal`, `patience` or `histogram`, or is a bare name, which git
    /// refuses too.
    UnknownDiffAlgorithm,
    /// A `diff.context` or `diff.interHunkContext` that is not an `int` of
    /// zero or more, a `diff.indentHeuristic` that is not a boolean, a
    /// rename setting that is neither a boolean nor `copies`, a rename
    /// limit that is not an `int`: values git dies on.
    InvalidDiffSetting,
    /// `core.whitespace` or a `whitespace` attribute names both
    /// `tab-in-indent` and `indent-with-non-tab`, which git refuses.
    ConflictingWhitespaceRules,
};

/// `options` with what the configuration says of the content diff `git
/// diff`, `git log -p`, `git show` and `format-patch` make when nothing is
/// asked: `diff.algorithm`, `diff.context`, `diff.interHunkContext`,
/// `diff.indentHeuristic` and `diff.suppressBlankEmpty`; and what a
/// coloured patch marks, `core.whitespace` and `diff.wsErrorHighlight`,
/// and how it shows moved lines, `diff.colorMoved` and `diff.colorMovedWS`;
/// and `core.quotePath`.
///
/// Every value is read in order, as git's callback reads it: one git dies
/// on is refused wherever it stands, and the last one decides. An
/// algorithm is named without regard to case; `minimal` is Myers made to
/// prove its script minimal, and `default` is Myers. A count is git's
/// `int`, unit suffixes included. A setting that is absent leaves `options`
/// as it was given.
pub fn configured(config: *const config_mod.Config, options: Options) ConfigError!Options {
    var out = options;
    var it = config.iterate(&.{ "diff.algorithm", "diff.context", "diff.interhunkcontext", "diff.indentheuristic", "diff.suppressblankempty", "diff.suppress-blank-empty", "diff.wserrorhighlight", "diff.colormoved", "diff.colormovedws", "core.whitespace", "core.quotepath" });
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "quotepath")) {
            out.quote_path = if (entry.value) |v| config_mod.parseBool(v) catch return error.InvalidDiffSetting else true;
        } else if (std.mem.eql(u8, entry.section, "core")) {
            out.whitespace_rule = whitespace.parse(entry.value orelse return error.InvalidDiffSetting) catch return error.ConflictingWhitespaceRules;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "colormoved")) {
            out.color_moved = ColorMoved.parse(entry.value) orelse return error.InvalidDiffSetting;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "colormovedws")) {
            out.color_moved_ws = ColorMovedWs.parse(entry.value orelse return error.InvalidDiffSetting) orelse return error.InvalidDiffSetting;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "wserrorhighlight")) {
            out.ws_error_highlight = WsErrorHighlight.parse(entry.value orelse return error.InvalidDiffSetting) orelse return error.InvalidDiffSetting;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "algorithm")) {
            const parsed = LineDiff.parse(entry.value orelse return error.UnknownDiffAlgorithm) orelse return error.UnknownDiffAlgorithm;
            out.algorithm = parsed.algorithm;
            out.minimal = parsed.minimal;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "context")) {
            out.context = try configCount(entry.value);
        } else if (std.ascii.eqlIgnoreCase(entry.name, "interhunkcontext")) {
            out.inter_hunk_context = try configCount(entry.value);
        } else if (std.ascii.eqlIgnoreCase(entry.name, "indentheuristic")) {
            out.indent_heuristic = if (entry.value) |v| config_mod.parseBool(v) catch return error.InvalidDiffSetting else true;
        } else {
            // `suppressBlankEmpty`, and its old name `suppress-blank-empty`.
            out.suppress_blank_empty = if (entry.value) |v| config_mod.parseBool(v) catch return error.InvalidDiffSetting else true;
        }
    }
    return out;
}

/// git's `git_config_int` refusing a negative, as `diff.context` and
/// `diff.interHunkContext` are read.
fn configCount(value: ?[]const u8) ConfigError!u32 {
    const n = config_mod.parseInteger(value orelse return error.InvalidDiffSetting) catch return error.InvalidDiffSetting;
    const int = std.math.cast(i32, n) orelse return error.InvalidDiffSetting;
    return std.math.cast(u32, int) orelse error.InvalidDiffSetting;
}

/// `diff.relative`, every value as git's callback reads it: whether a
/// diff made in a subdirectory shows only that directory, its paths
/// relative to it. Off when it is not there.
pub fn configuredRelative(config: *const config_mod.Config) ConfigError!bool {
    var out = false;
    var it = config.iterate(&.{"diff.relative"});
    while (it.next()) |entry| out = if (entry.value) |v| config_mod.parseBool(v) catch return error.InvalidDiffSetting else true;
    return out;
}

/// Where `findRenames` reads the blobs it scores: the database, and the
/// blobs that are not in it, the working tree's files as they would be
/// stored, under the names their bytes hash to (`rename.Options.contents`).
pub const RenameBlobs = struct {
    db: *odb_mod.Odb,
    contents: ?*const std.AutoHashMapUnmanaged(Oid, []const u8) = null,
};

/// Errors from `checkBasic`.
pub const BasicConfigError = error{InvalidDiffSetting} || color_mod.Error;

/// What git's `git_diff_basic_config` dies on, every value looked at
/// wherever it stands: `diff.renameLimit`; a driver's `diff.<driver>.*`
/// (`userdiff_config`: `funcname`, `xfuncname`, `command`, `textconv`,
/// `wordRegex` or `algorithm` with no value, a `binary` neither `auto` nor
/// a boolean, a `trustExitCode` or `cacheTextConv` not a boolean); a
/// `diff.color.<slot>` or `color.diff.<slot>` colour; `diff.wsErrorHighlight`;
/// `diff.suppressBlankEmpty`; `diff.dirstat` with no value (its parts
/// only warn); `diff.indentHeuristic`. A command that reads it refuses
/// these before anything else, whether or not it writes a diff: git's
/// sequencer does (`sequencer.initConfig`).
pub fn checkBasic(config: *const config_mod.Config) BasicConfigError!void {
    _ = RenameSettings.readLimit(config) catch return error.InvalidDiffSetting;
    const needs_value = [_][]const u8{ "funcname", "xfuncname", "command", "textconv", "wordregex", "algorithm" };
    for (config.entries.items) |entry| {
        if (!std.mem.eql(u8, entry.section, "diff") or !entry.has_subsection) continue;
        for (needs_value) |name| {
            if (std.mem.eql(u8, entry.name, name) and entry.value == null) return error.InvalidDiffSetting;
        }
        const value = entry.value orelse continue;
        if (std.mem.eql(u8, entry.name, "binary") and std.ascii.eqlIgnoreCase(value, "auto")) continue;
        if (std.mem.eql(u8, entry.name, "binary") or std.mem.eql(u8, entry.name, "trustexitcode") or std.mem.eql(u8, entry.name, "cachetextconv")) {
            _ = config_mod.parseBool(value) catch return error.InvalidDiffSetting;
        }
    }
    _ = try Colors.read(config);
    var it = config.iterate(&.{ "diff.wserrorhighlight", "diff.suppressblankempty", "diff.suppress-blank-empty", "diff.dirstat", "diff.indentheuristic" });
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "wserrorhighlight")) {
            _ = WsErrorHighlight.parse(entry.value orelse return error.InvalidDiffSetting) orelse return error.InvalidDiffSetting;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "dirstat")) {
            if (entry.value == null) return error.InvalidDiffSetting;
        } else if (entry.value) |v| {
            _ = config_mod.parseBool(v) catch return error.InvalidDiffSetting;
        }
    }
}

/// What a rename setting asks for: git's `DIFF_DETECT_*`.
pub const RenameDetection = enum { off, renames, copies };

/// A rename setting's value as git's `git_config_rename` reads it, for
/// `diff.renames`, `merge.renames` and `status.renames`: a bare name is
/// renames, `copies` or `copy` in any case is copies, anything else one of
/// git's boolean spellings (`error.InvalidDiffSetting` where git dies).
pub fn parseRenameSetting(value: ?[]const u8) ConfigError!RenameDetection {
    const text = value orelse return .renames;
    if (std.ascii.eqlIgnoreCase(text, "copies") or std.ascii.eqlIgnoreCase(text, "copy")) return .copies;
    const on = config_mod.parseBool(text) catch return error.InvalidDiffSetting;
    return if (on) .renames else .off;
}

/// A rename limit as git's `git_config_int` reads it: an `int`, unit
/// suffixes included, and a bare name refused.
pub fn parseRenameLimit(value: ?[]const u8) ConfigError!i32 {
    const n = config_mod.parseInteger(value orelse return error.InvalidDiffSetting) catch return error.InvalidDiffSetting;
    return std.math.cast(i32, n) orelse error.InvalidDiffSetting;
}

/// What `diff.renames` and `diff.renameLimit` say, read as git's diff
/// callbacks read them: every value in order, one git dies on refused
/// wherever it stands, the last deciding. `null` where a setting is not
/// there.
pub const RenameSettings = struct {
    detection: ?RenameDetection = null,
    limit: ?i32 = null,

    pub fn read(config: *const config_mod.Config) ConfigError!RenameSettings {
        var out: RenameSettings = .{};
        var it = config.iterate(&.{ "diff.renames", "diff.renamelimit" });
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "renames")) {
                out.detection = try parseRenameSetting(entry.value);
            } else out.limit = try parseRenameLimit(entry.value);
        }
        return out;
    }

    /// `diff.renameLimit` alone, every value in order as git's
    /// `git_diff_basic_config` reads it, a bad one refused wherever it
    /// stands, the last deciding: what a cherry-pick, a revert and a
    /// rebase read when they begin, where `diff.renames` is only the
    /// merge's own last value. `null` when it is not there.
    pub fn readLimit(config: *const config_mod.Config) ConfigError!?i32 {
        var out: ?i32 = null;
        var it = config.iterate(&.{"diff.renamelimit"});
        while (it.next()) |entry| out = try parseRenameLimit(entry.value);
        return out;
    }

    /// The renames a diff, `git log -p` or `format-patch` finds with
    /// nothing asked: on unless `diff.renames` says otherwise, copies too
    /// for `copies`, scored up to `diff.renameLimit` (1000, and none when
    /// it is zero or less); `null` for none.
    pub fn options(s: RenameSettings) ?RenameOptions {
        const detection = s.detection orelse .renames;
        if (detection == .off) return null;
        const limit = s.limit orelse 1000;
        return .{ .detect_copies = detection == .copies, .limit = @intCast(@max(0, limit)) };
    }
};

/// The line diff `options` asks for.
fn lineOptions(options: Options) parallax.Options {
    return .{
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .indent_heuristic = options.indent_heuristic,
        .compare = .{ .whitespace = .{
            .all = options.ignore_all_whitespace,
            .change = options.ignore_whitespace_change,
            .at_eol = options.ignore_trailing_whitespace,
        } },
        .max_work = .fromRaw(options.max_work),
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

/// Whether a path's contents diff as binary, as git's
/// `diff_filespec_is_binary` decides it: the driver the `diff` attribute
/// gives (`user_diff.Driver`: set is text, unset is binary, a driver says
/// by `diff.<driver>.binary`, and no driver is `default`'s), and `isBinary`
/// of the bytes where the driver does not say. The zero value has no
/// attributes or configuration and decides by the bytes alone.
pub const BinaryRule = struct {
    attrs: ?*attributes.Attrs = null,
    /// The working tree whose `.gitattributes` are read on the way down to
    /// a path; `null` reads only what `attrs` holds.
    work_dir: ?Io.Dir = null,
    /// Where `diff.<driver>.binary` is read.
    config: ?*const config_mod.Config = null,

    /// Whether `path`, holding `bytes`, is binary. `a` holds the lookup.
    pub fn isBinary(rule: BinaryRule, a: Allocator, io: Io, path: []const u8, bytes: []const u8) (attributes.Error || error{InvalidDriverBinary})!bool {
        var state: ?attributes.State = null;
        if (rule.attrs) |attrs| {
            if (rule.work_dir) |wt| try attrs.enter(io, wt, path);
            state = (try attrs.lookup(a, path, .file)).get("diff");
        }
        return try user_diff.Driver.of(rule.config, state).isBinary(rule.config, bytes);
    }
};

/// The whitespace rule a path's patch is marked by, as git's
/// `whitespace_rule` decides it: the path's `whitespace` attribute over
/// `configured`, which is `core.whitespace` as `configured` reads it into
/// `Options.whitespace_rule`.
pub const WhitespaceRule = struct {
    attrs: ?*attributes.Attrs = null,
    /// The working tree whose `.gitattributes` are read on the way down to
    /// a path; `null` reads only what `attrs` holds.
    work_dir: ?Io.Dir = null,
    configured: u32 = whitespace.default_rule,

    /// The rule for `path`. `a` holds the lookup.
    pub fn of(rule: WhitespaceRule, a: Allocator, io: Io, path: []const u8) (attributes.Error || error{ConflictingWhitespaceRules})!u32 {
        const attrs = rule.attrs orelse return rule.configured;
        if (rule.work_dir) |wt| try attrs.enter(io, wt, path);
        const attribute: whitespace.Attribute = if ((try attrs.lookup(a, path, .file)).get("whitespace")) |state| switch (state) {
            .set => .set,
            .unset => .unset,
            .unspecified => .unspecified,
            .value => |v| .{ .value = v },
        } else .unspecified;
        return whitespace.forAttribute(attribute, rule.configured);
    }
};

/// The longest line `gitlinkText` writes: the words, the widest name, the newline.
const gitlink_text_max = "Subproject commit \n".len + hash.max_hex_len;

fn gitlinkText(buf: *[gitlink_text_max]u8, oid: Oid) []const u8 {
    var hex: [hash.max_hex_len]u8 = undefined;
    // unreachable: the buffer holds the words and the widest name
    return std.mem.print(buf, "Subproject commit {s}\n", .{oid.hex(&hex)}) catch unreachable;
}

/// The added and removed line counts between two blobs.
pub fn blobNumStat(gpa: Allocator, old: []const u8, new: []const u8, options: Options) Self.TextError!NumStat {
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    return countLines(&differ, old, new, options);
}

/// `blobNumStat` in a workspace a caller keeps for many blobs.
fn countLines(differ: *parallax.Differ, old: []const u8, new: []const u8, options: Options) Self.TextError!NumStat {
    try checkTextSize(old, new);
    if (isBinary(old) or isBinary(new)) return .{ .plus = 0, .minus = 0, .binary = true };
    const counts = (try differ.lines(old, new, lineOptions(options))).stat();
    return .{ .plus = counts.added, .minus = counts.removed, .binary = false };
}

/// Errors from `numstat`.
pub const NumstatError = Self.Error || Self.TextError;

/// The counts for every change in a tree comparison, in the same order.
///
/// The result is the caller's.
pub fn numstat(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    changes: []const Change,
    options: Options,
) NumstatError![]NumStat {
    var out = try gpa.alloc(NumStat, changes.len);
    errdefer gpa.free(out);
    // One workspace for every pair: after the first, a diff allocates
    // nothing it does not need more room for.
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    for (changes, 0..) |change, i| {
        // A gitlink has no content in this repository; git counts it as one
        // line changed either way, which is what a commit name is.
        var old_gitlink: [gitlink_text_max]u8 = undefined;
        var old_read: ?[]u8 = null;
        defer if (old_read) |bytes| db.allocator().free(bytes);
        const old_bytes: []const u8 = if (change.old) |entry| blk: {
            if (entry.mode == .gitlink) break :blk gitlinkText(&old_gitlink, entry.oid);
            old_read = (try db.read(io, entry.oid)).bytes;
            break :blk old_read.?;
        } else "";
        var new_gitlink: [gitlink_text_max]u8 = undefined;
        var new_read: ?[]u8 = null;
        defer if (new_read) |bytes| db.allocator().free(bytes);
        const new_bytes: []const u8 = if (change.new) |entry| blk: {
            if (entry.mode == .gitlink) break :blk gitlinkText(&new_gitlink, entry.oid);
            new_read = (try db.read(io, entry.oid)).bytes;
            break :blk new_read.?;
        } else "";
        out[i] = try countLines(&differ, old_bytes, new_bytes, options);
    }
    return out;
}

/// Errors from `unified`.
pub const UnifiedError = Self.Error || Self.TextError || Io.Writer.Error || attributes.Error || textconv_mod.Error || error{InvalidDriverBinary};

/// The borrowed object store, the changes whose patch is written, and what
/// decides which of their files are binary.
pub const UnifiedInputs = struct {
    db: *odb_mod.Odb,
    /// In the order they are written: one diff, as git's
    /// `diff_flush_patch_all_file_pairs` writes its queue.
    changes: []const Change,
    /// Which files are binary, as git's `diff_filespec_is_binary` says;
    /// the zero value decides by the bytes alone.
    binary: BinaryRule = .{},
    /// `--textconv`, which `git diff` and `git log -p` have by default: a
    /// side whose driver has a `textconv` is diffed as the program's text,
    /// and is never binary. `null` diffs the bytes.
    textconv: ?*const textconv_mod.Textconv = null,
};

/// Append the unified diff of `inputs.changes` to `w`, each with git's
/// headers, as `git diff`, `git log -p` and `git format-patch` write a
/// diff (git's `builtin_diff` for each file). A change between a file and
/// a symbolic link or a gitlink is written as a deletion and a creation,
/// as git's `run_diff` splits it. In colour, with `Options.color_moved`,
/// the lines that moved are found over every file of the diff.
pub fn unified(
    gpa: Allocator,
    io: Io,
    inputs: UnifiedInputs,
    w: *Io.Writer,
    options: Options,
) UnifiedError!void {
    var recorder: ?paint.Recorder = if (movedWanted(options)) .init(gpa, options.color_moved, options.color_moved_ws) else null;
    defer if (recorder) |*r| r.deinit();
    const r: ?*paint.Recorder = if (recorder) |*r| r else null;
    const out = if (r) |rec| &rec.painted.writer else w;
    for (inputs.changes) |change| {
        writeChange(gpa, io, inputs, change, out, options, r) catch |err| return recorded(r, err);
    }
    if (r) |rec| try rec.finish(w);
}

/// Whether a patch is recorded for its moved lines: git looks for them
/// only in colour.
fn movedWanted(options: Options) bool {
    return options.color_moved != .no and options.colors != null;
}

/// An error from writing into a recorder, whose writer fails only when its
/// allocator does.
fn recorded(r: ?*paint.Recorder, err: anytype) @TypeOf(err) {
    if (r != null and err == error.WriteFailed) return error.OutOfMemory;
    return err;
}

fn writeChange(gpa: Allocator, io: Io, inputs: UnifiedInputs, change: Change, w: *Io.Writer, options: Options, r: ?*paint.Recorder) UnifiedError!void {
    const file: FileInputs = .{ .db = inputs.db, .binary = inputs.binary, .textconv = inputs.textconv, .change = change, .recorder = r };
    if (change.old != null and change.new != null and typeChanged(change.old.?.mode, change.new.?.mode)) {
        try writeFilePatch(gpa, io, file, w, options, change.old, null);
        return writeFilePatch(gpa, io, file, w, options, null, change.new);
    }
    return writeFilePatch(gpa, io, file, w, options, change.old, change.new);
}

/// One change's patch: what `writeFilePatch` reads it from, and where its
/// moved lines are recorded.
const FileInputs = struct {
    db: *odb_mod.Odb,
    binary: BinaryRule,
    textconv: ?*const textconv_mod.Textconv,
    change: Change,
    recorder: ?*paint.Recorder,
};

/// A side's bytes, as the patch compares them: a gitlink's commit as git's
/// `Subproject commit` line, an object's bytes read from `db`.
const SideBytes = struct {
    bytes: []const u8 = "",
    read: ?[]u8 = null,
    gitlink: [gitlink_text_max]u8 = undefined,

    fn load(side: *SideBytes, io: Io, db: *odb_mod.Odb, entry: ?Entry) Self.Error!void {
        const e = entry orelse return;
        if (e.mode == .gitlink) {
            side.bytes = gitlinkText(&side.gitlink, e.oid);
            return;
        }
        side.read = (try db.read(io, e.oid)).bytes;
        side.bytes = side.read.?;
    }

    /// An object's bytes are the object database's allocator's, whoever
    /// asked for them.
    fn deinit(side: *SideBytes, db: *odb_mod.Odb) void {
        if (side.read) |bytes| db.allocator().free(bytes);
    }
};

/// One side's text as its driver's `textconv` writes it, `null` when it
/// is not converted: git's `get_textconv` converts only a regular file,
/// never a symbolic link or a gitlink.
fn convertSide(tc: *const textconv_mod.Textconv, a: Allocator, io: Io, entry: ?Entry, bytes: []const u8) textconv_mod.Error!?[]const u8 {
    const e = entry orelse return null;
    if (e.mode != .file and e.mode != .exec) return null;
    return tc.convert(a, io, .{ .path = e.path, .blob = e.oid, .bytes = bytes });
}

/// One file pair's patch, either side absent for a creation or a deletion.
fn writeFilePatch(gpa: Allocator, io: Io, inputs: FileInputs, w: *Io.Writer, options: Options, old: ?Entry, new: ?Entry) UnifiedError!void {
    const db = inputs.db;
    const change = inputs.change;
    const colors = options.colors;
    const fully = options.quote_path;
    const old_path = shownPath(options, (old orelse new.?).path);
    const new_path = shownPath(options, (new orelse old.?).path);
    const old_name = try quoteTwo(gpa, "a/", old_path, fully);
    defer gpa.free(old_name);
    const new_name = try quoteTwo(gpa, "b/", new_path, fully);
    defer gpa.free(new_name);

    const old_oid = if (old) |e| e.oid else Oid.zero(db.objectFormat());
    const new_oid = if (new) |e| e.oid else Oid.zero(db.objectFormat());
    const header: Header = .{ .old_name = old_name, .new_name = new_name, .old_path = old_path, .new_path = new_path, .old = old, .new = new, .change = change, .quote_fully = fully };
    if (old_oid.eql(new_oid)) {
        // Only the mode moved: git prints no index line and no hunks.
        return writeHeader(gpa, w, colors, header);
    }

    var old_side: SideBytes = .{};
    defer old_side.deinit(db);
    try old_side.load(io, db, old);
    var new_side: SideBytes = .{};
    defer new_side.deinit(db);
    try new_side.load(io, db, new);
    try checkTextSize(old_side.bytes, new_side.bytes);

    var lookup: std.heap.ArenaAllocator = .init(gpa);
    defer lookup.deinit();
    // `fill_textconv`: each side the driver converts is diffed as its text.
    var old_text = old_side.bytes;
    var new_text = new_side.bytes;
    var old_converted = false;
    var new_converted = false;
    if (inputs.textconv) |tc| {
        if (try convertSide(tc, lookup.allocator(), io, old, old_side.bytes)) |t| {
            old_text = t;
            old_converted = true;
        }
        if (try convertSide(tc, lookup.allocator(), io, new, new_side.bytes)) |t| {
            new_text = t;
            new_converted = true;
        }
    }
    const binary = (if (old) |e| !old_converted and try inputs.binary.isBinary(lookup.allocator(), io, e.path, old_side.bytes) else false) or
        (if (new) |e| !new_converted and try inputs.binary.isBinary(lookup.allocator(), io, e.path, new_side.bytes) else false);
    // A change git need not announce -- no file made or removed, no mode
    // moved, no rename -- is written only with a hunk, which a text that
    // converts the same has none of.
    if (!binary and (old_converted or new_converted) and std.mem.eql(u8, old_text, new_text) and
        old != null and new != null and old.?.mode == new.?.mode and change.status != .renamed and change.status != .copied) return;
    try writeHeader(gpa, w, colors, header);

    // The mode is on the index line only when it did not change and the
    // file was neither created nor removed; otherwise it is on its own line
    // above. A binary patch names its objects in full, which `git apply`
    // checks.
    const full = options.full_index or (options.binary_patches and binary);
    var new_mode_buf: [6]u8 = undefined;
    var old_hex: [hash.max_hex_len]u8 = undefined;
    var new_hex: [hash.max_hex_len]u8 = undefined;
    const same_mode = old != null and new != null and old.?.mode == new.?.mode;
    try paint.writeMeta(w, colors, "index {s}..{s}{s}{s}", .{
        try abbreviated(io, db, old_oid, options.abbrev, full, &old_hex),
        try abbreviated(io, db, new_oid, options.abbrev, full, &new_hex),
        if (same_mode) " " else "",
        if (same_mode) new.?.mode.text(&new_mode_buf) else "",
    });

    const old_label = if (old == null) "/dev/null" else old_name;
    const new_label = if (new == null) "/dev/null" else new_name;
    if (binary) {
        if (options.binary_patches) {
            try binarypatch.write(gpa, w, old_side.bytes, new_side.bytes);
        } else try w.print("Binary files {s} and {s} differ\n", .{ old_label, new_label });
        return;
    }

    var body_options = options;
    // A symbolic link is a line without its ending, which is no news.
    if (new) |entry| if (entry.mode == .symlink) {
        body_options.whitespace_rule &= ~whitespace.incomplete_line;
    };
    try writeBody(gpa, w, old_text, new_text, body_options, .{ .old = old_label, .new = new_label }, inputs.recorder);
}

/// The lines a file's patch starts with, before its `index` line.
const Header = struct {
    old_name: []const u8,
    new_name: []const u8,
    old_path: []const u8,
    new_path: []const u8,
    old: ?Entry,
    new: ?Entry,
    change: Change,
    quote_fully: bool,
};

fn writeHeader(gpa: Allocator, w: *Io.Writer, colors: ?*const Colors, h: Header) UnifiedError!void {
    const old_name = h.old_name;
    const new_name = h.new_name;
    const old_path = h.old_path;
    const new_path = h.new_path;
    const old = h.old;
    const new = h.new;
    const change = h.change;
    const fully = h.quote_fully;
    try paint.writeMeta(w, colors, "diff --git {s} {s}", .{ old_name, new_name });

    var old_mode_buf: [6]u8 = undefined;
    var new_mode_buf: [6]u8 = undefined;
    if (old == null) {
        try paint.writeMeta(w, colors, "new file mode {s}", .{new.?.mode.text(&new_mode_buf)});
    } else if (new == null) {
        try paint.writeMeta(w, colors, "deleted file mode {s}", .{old.?.mode.text(&old_mode_buf)});
    } else {
        if (old.?.mode != new.?.mode) {
            try paint.writeMeta(w, colors, "old mode {s}", .{old.?.mode.text(&old_mode_buf)});
            try paint.writeMeta(w, colors, "new mode {s}", .{new.?.mode.text(&new_mode_buf)});
        }
        if (change.status == .renamed or change.status == .copied) {
            const word = if (change.status == .renamed) "rename" else "copy";
            try paint.writeMeta(w, colors, "similarity index {d}%", .{change.similarity});
            const from = try quoteTwo(gpa, "", old_path, fully);
            defer gpa.free(from);
            const to = try quoteTwo(gpa, "", new_path, fully);
            defer gpa.free(to);
            try paint.writeMeta(w, colors, "{s} from {s}", .{ word, from });
            try paint.writeMeta(w, colors, "{s} to {s}", .{ word, to });
        }
    }
}

/// A path as a patch's headers name it: under `Options.relative_to`, from
/// that directory, as git's `strip_prefix` names it.
fn shownPath(options: Options, path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, options.relative_to)) path[options.relative_to.len..] else path;
}

/// An object's name on the `index` line, as git's `diff_abbrev_oid` writes
/// it: in full, or the shortest prefix of at least `len` the object
/// database holds no other object under; the null name cut at `len`.
fn abbreviated(io: Io, db: *odb_mod.Odb, oid: Oid, len: usize, full: bool, buf: *[hash.max_hex_len]u8) odb_mod.Error![]const u8 {
    if (full) return oid.hex(buf);
    if (oid.isZero()) return oid.abbrev(buf, len);
    return abbrev.unique(io, db, oid, len, buf);
}

/// `prefix` and `path` as a patch's headers write them: C-quoted
/// together as git's `quote_two_c_style` quotes them, where either needs
/// it. The text is `gpa`'s.
fn quoteTwo(gpa: Allocator, prefix: []const u8, path: []const u8, fully: bool) Allocator.Error![]u8 {
    if (!c_quote.needsQuote(prefix, fully) and !c_quote.needsQuote(path, fully)) return std.mem.concat(gpa, u8, &.{ prefix, path });
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    c_quote.writeBody(&out.writer, prefix, fully) catch return error.OutOfMemory;
    c_quote.writeBody(&out.writer, path, fully) catch return error.OutOfMemory;
    out.writer.writeByte('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The `---` and `+++` names a patch body is written under, quoted.
const FileNames = struct { old: []const u8, new: []const u8 };

/// Errors from `unifiedBody`.
pub const UnifiedBodyError = Self.TextError || Io.Writer.Error;

/// Append the `@@` hunks for two blobs, with no `diff --git` header.
///
/// This is what a caller that wants only the body asks for, and what
/// `unified` uses. Context lines are the new side's, as git prints them,
/// which shows where a whitespace option lets the two differ. Moved lines
/// are found within the body, a diff of one file.
pub fn unifiedBody(
    gpa: Allocator,
    w: *Io.Writer,
    old: []const u8,
    new: []const u8,
    options: Options,
) UnifiedBodyError!void {
    var recorder: ?paint.Recorder = if (movedWanted(options)) .init(gpa, options.color_moved, options.color_moved_ws) else null;
    defer if (recorder) |*r| r.deinit();
    const r: ?*paint.Recorder = if (recorder) |*r| r else null;
    writeBody(gpa, if (r) |rec| &rec.painted.writer else w, old, new, options, null, r) catch |err| return recorded(r, err);
    if (r) |rec| try rec.finish(w);
}

/// The hunks, under `---` and `+++` lines naming `files` where there are
/// any, painted where `options` has colours; the removed and added lines
/// recorded in `recorder` where there is one.
fn writeBody(gpa: Allocator, w: *Io.Writer, old: []const u8, new: []const u8, options: Options, files: ?FileNames, recorder: ?*paint.Recorder) UnifiedBodyError!void {
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    try checkTextSize(old, new);
    const diff = try differ.lines(old, new, lineOptions(options));
    // The rule lives in `options` for as long as the writer reads it.
    const heading: ?parallax.Heading = if (!options.function_context_names)
        null
    else if (options.function_line) |*rule|
        .{ .context = rule, .find = findByRule }
    else
        .c_function;
    var own_painter: ?paint.Painter = if (options.colors != null or options.diff_of_patches != null)
        .init(options.colors, options.whitespace_rule, options.ws_error_highlight, options.diff_of_patches, old, new)
    else
        null;
    // A recorded painter lives in the recorder, which replays its lines.
    const painter: ?*paint.Painter = if (own_painter) |*p|
        (if (recorder) |r| try r.addPainter(p.*) else p)
    else
        null;
    // The names as the `---` and `+++` lines write them; plain, a name with
    // a space gets a tab after it, for GNU patch, which a painter writes
    // itself outside the colour.
    var names: [2][]const u8 = .{ "", "" };
    defer for (names) |n| gpa.free(n);
    if (files) |f| for ([_][]const u8{ f.old, f.new }, &names) |name, *out| {
        const tab = painter == null and std.mem.findScalar(u8, name, ' ') != null;
        out.* = try std.mem.concat(gpa, u8, &.{ name, if (tab) "\t" else "" });
    };
    try parallax.writeUnified(w, diff, .{
        .hunks = .{ .context = options.context, .inter_hunk_context = options.inter_hunk_context },
        .heading = heading,
        .files = if (files != null) .{ .old = names[0], .new = names[1] } else null,
        .suppress_blank_empty = options.suppress_blank_empty,
        .paint = if (painter) |p| p.paint() else null,
    });
}

/// A caller's `FunctionLine` asked of a line, as git's `ff_regexp` asks a
/// driver's pattern: without the line's ending, carriage return included.
fn findByRule(context: ?*const anyopaque, line: []const u8) ?[]const u8 {
    const rule: *const FunctionLine = @ptrCast(@alignCast(context.?)); // safe: unifiedBody hands its own *const FunctionLine as the context
    const bare = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
    return rule.find(rule.context, bare);
}

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

test "the enclosing line on a hunk header is cut at eighty bytes, as xdiff's buffer cuts it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const long = "function_with_a_very_long_name_that_goes_on(int first_argument, int second_argument, int third)";
    try unifiedBody(gpa, &out.writer, long ++ "\n1\n2\n3\n4\n5\n6\nx\n", long ++ "\n1\n2\n3\n4\n5\n6\ny\n", .{});
    // `git diff --no-index` prints the same header for these two files
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "@@ -5,4 +5,4 @@ " ++ long[0..80] ++ "\n"));
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
    try std.testing.expect(std.mem.find(u8, out.written(), "\\ No newline at end of file") != null);
}

test "the binary rule is the diff one" {
    try std.testing.expect(isBinary("a\x00b"));
    try std.testing.expect(!isBinary("a\rb"));
}

test "diff refuses over Git's byte limit before binary scanning" {
    // A NUL makes the pre-fix binary scanner return without reading past
    // this buffer. The input limit is a length contract, before content access.
    const prefix: [8000]u8 = @splat(0);
    const pointer: [*]const u8 = &prefix;
    const too_large = pointer[0 .. 1023 * 1024 * 1024 + 1];
    try std.testing.expectError(error.InputTooLarge, blobNumStat(std.testing.allocator, too_large, "", .{}));
    try std.testing.expectError(error.InputTooLarge, blobNumStat(std.testing.allocator, "", too_large, .{}));
}
