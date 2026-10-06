//! Which commit each line of a file comes from, as `git blame` says.
//!
//! The answer is git's because the walk is git's (`blame.c`): every line
//! starts suspected of the commit blamed, and a commit passes each of its
//! suspects to a parent whose copy of the file has that line unchanged, by
//! the same line diff git takes (Myers with the indent heuristic, no
//! context). Parents are asked in order: first for the file at the same
//! path, then, for a parent that has none, for the file it was renamed
//! from, by git's rename detection with only this path as the destination.
//! A parent whose copy is the same blob takes every suspect at once, and of
//! two parents with the same blob only the first is asked. What no parent
//! takes is the commit's own. Copies and moves between files, `-M` and
//! `-C`, are off, as they are in git unless asked for.
//!
//! Commits are taken newest first by committer date, as git takes them; a
//! commit that receives suspects after it was taken is taken again, so the
//! answer does not depend on the order.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");
const diff = @import("../diff.zig");
const rename = @import("rename.zig");
const textdiff = @import("textdiff.zig");

const Oid = hash.Oid;

/// Errors from a blame.
pub const Error = diff.Error || object.ParseError || error{
    /// A commit named is not a commit.
    NotACommit,
    /// The path is not a file in the commit blamed.
    PathNotFound,
};

/// How a blame is taken.
pub const Options = struct {
    /// Follow the file to the path it had before a whole-file rename, as
    /// git does unless told `--no-follow`.
    follow_renames: bool = true,
};

/// A run of lines that come from one commit, at consecutive lines there.
pub const Hunk = struct {
    /// Where the run starts in the file blamed, counting from one, and how
    /// many lines it has.
    final_start: u32,
    count: u32,
    /// The commit the lines come from.
    commit: Oid,
    /// The file's path in that commit. Owned by the `Blame`.
    path: []const u8,
    /// Where the run starts in that commit's copy of the file, from one.
    orig_start: u32,
};

/// Every line of a file, by where it comes from.
pub const Blame = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// In the order of the file's lines, covering each once.
    hunks: []Hunk,

    pub fn deinit(b: *Blame) void {
        var arena = b.arena.promote(b.gpa);
        arena.deinit();
        b.* = undefined;
    }
};

/// Blame `path` as `commit` has it.
pub fn file(gpa: Allocator, io: Io, db: *odb_mod.Odb, commit: Oid, path: []const u8, options: Options) Self.Error!Blame {
    var out_arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer out_arena.deinit();
    var work: std.heap.ArenaAllocator = .init(gpa);
    defer work.deinit();

    var s: Scoreboard = .{ .gpa = gpa, .arena = work.allocator(), .io = io, .db = db, .options = options };
    const start = try s.node(commit);
    const found = (try s.entryAt(start.tree, path)) orelse return error.PathNotFound;
    if (!found.mode.isBlob()) return error.PathNotFound;
    const origin = try s.origin(start, path, found.oid);
    const lines = try s.linesOf(found.oid);
    try origin.suspects.ensureTotalCapacity(s.arena, lines.len);
    for (0..lines.len) |i| origin.suspects.appendAssumeCapacity(.{ .final = @intCast(i), .at = @intCast(i) });
    try s.enqueue(start);

    while (s.queue.pop()) |n| {
        n.queued = false;
        // Origins the walk adds to this commit while it works go on the
        // list behind these and are taken in turn.
        var i: usize = 0;
        while (i < n.origins.items.len) : (i += 1) {
            const o = n.origins.items[i];
            if (o.suspects.items.len == 0) continue;
            try s.pass(n, o);
        }
    }

    // One hunk per run of lines with one source, in the file's order.
    std.mem.sort(Guilty, s.guilty.items, {}, Guilty.lessThan);
    const arena = out_arena.allocator();
    var hunks: std.ArrayList(Hunk) = .empty;
    for (s.guilty.items) |g| {
        if (hunks.items.len != 0) {
            const last = &hunks.items[hunks.items.len - 1];
            if (last.commit.eql(g.origin.commit) and std.mem.eql(u8, last.path, g.origin.path) and
                last.final_start + last.count == g.final + 1 and last.orig_start + last.count == g.at + 1)
            {
                last.count += 1;
                continue;
            }
        }
        const owned = if (hunks.items.len != 0 and std.mem.eql(u8, hunks.items[hunks.items.len - 1].path, g.origin.path))
            hunks.items[hunks.items.len - 1].path
        else
            try arena.dupe(u8, g.origin.path);
        try hunks.append(arena, .{ .final_start = g.final + 1, .count = 1, .commit = g.origin.commit, .path = owned, .orig_start = g.at + 1 });
    }
    // What `Blame` promises: every line blamed once, the hunks running from
    // the first line to the last without a gap or an overlap.
    assert(s.guilty.items.len == lines.len);
    var next_line: usize = 1;
    for (hunks.items) |h| {
        assert(h.final_start == next_line);
        next_line += h.count;
    }
    assert(next_line == lines.len + 1);
    return .{ .gpa = gpa, .arena = out_arena.state, .hunks = hunks.items };
}

/// A line under suspicion: where it is in the file blamed, and where it is
/// in the suspect's copy, both from zero.
const Suspect = struct { final: u32, at: u32 };

/// A file in one commit, and the lines it is suspected of.
const Origin = struct {
    commit: Oid,
    path: []const u8,
    blob: Oid,
    suspects: std.ArrayList(Suspect) = .empty,
};

/// A commit as the walk knows it.
const Node = struct {
    oid: Oid,
    tree: Oid,
    parents: []const Oid,
    time: i64,
    origins: std.ArrayList(*Origin) = .empty,
    queued: bool = false,
};

/// A line settled on its origin.
const Guilty = struct {
    final: u32,
    at: u32,
    origin: *const Origin,

    fn lessThan(_: void, a: Guilty, b: Guilty) bool {
        return a.final < b.final;
    }
};

fn newerFirst(_: void, a: *Node, b: *Node) std.math.Order {
    return std.math.order(b.time, a.time);
}

const Scoreboard = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    options: Options,
    nodes: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, *Node) = .empty,
    lines: std.AutoHashMapUnmanaged([hash.max_raw_len]u8, []const textdiff.Line) = .empty,
    queue: std.PriorityQueue(*Node, void, newerFirst) = .empty,
    guilty: std.ArrayList(Guilty) = .empty,

    fn node(s: *Scoreboard, oid: Oid) Error!*Node {
        if (s.nodes.get(oid.bytes)) |n| return n;
        const found = try s.db.read(s.io, oid);
        defer s.db.allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var parsed = try object.Commit.parse(s.gpa, s.db.objectFormat(), found.bytes);
        defer parsed.deinit();
        const n = try s.arena.create(Node);
        n.* = .{
            .oid = oid,
            .tree = parsed.tree,
            .parents = try s.arena.dupe(Oid, parsed.parents),
            .time = parsed.committer.when_secs,
        };
        try s.nodes.put(s.arena, oid.bytes, n);
        return n;
    }

    fn enqueue(s: *Scoreboard, n: *Node) Error!void {
        if (n.queued) return;
        n.queued = true;
        try s.queue.push(s.arena, n);
    }

    /// The origin for `path` in `n`, made the first time it is asked for.
    fn origin(s: *Scoreboard, n: *Node, path: []const u8, blob: Oid) Error!*Origin {
        for (n.origins.items) |o| {
            if (std.mem.eql(u8, o.path, path)) return o;
        }
        const o = try s.arena.create(Origin);
        o.* = .{ .commit = n.oid, .path = try s.arena.dupe(u8, path), .blob = blob };
        try n.origins.append(s.arena, o);
        return o;
    }

    /// A blob's lines, read once.
    fn linesOf(s: *Scoreboard, blob: Oid) Error![]const textdiff.Line {
        if (s.lines.get(blob.bytes)) |l| return l;
        const found = try s.db.read(s.io, blob);
        defer s.db.allocator().free(found.bytes);
        const bytes = try s.arena.dupe(u8, found.bytes);
        const l = try textdiff.splitLines(s.arena, bytes);
        try s.lines.put(s.arena, blob.bytes, l);
        return l;
    }

    /// The entry at `path` under `tree`, or `null`.
    fn entryAt(s: *Scoreboard, tree: Oid, path: []const u8) Error!?object.Tree.Entry {
        var at = tree;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            const found = try s.db.read(s.io, at);
            defer s.db.allocator().free(found.bytes);
            if (found.type != .tree) return null;
            const entry = (try object.Tree.parse(s.db.objectFormat(), found.bytes).find(part)) orelse return null;
            if (parts.peek() == null) return entry;
            if (!entry.mode.isTree()) return null;
            at = entry.oid;
        }
        return null;
    }

    /// git's `pass_blame` for one origin.
    fn pass(s: *Scoreboard, n: *Node, o: *Origin) Error!void {
        const scapegoats = try s.arena.alloc(?*Origin, n.parents.len);
        @memset(scapegoats, null);
        const passes: usize = if (s.options.follow_renames) 2 else 1;
        for (0..passes) |round| {
            for (n.parents, 0..) |parent_oid, i| {
                if (scapegoats[i] != null) continue;
                const parent = try s.node(parent_oid);
                const found = if (round == 0) try s.samePath(parent, o) else try s.renamedFrom(n, parent, o);
                const p_origin = found orelse continue;
                if (p_origin.blob.eql(o.blob)) {
                    // The parent has this very file: everything is its.
                    try p_origin.suspects.appendSlice(s.arena, o.suspects.items);
                    o.suspects.clearRetainingCapacity();
                    try s.enqueue(parent);
                    return;
                }
                const repeated = for (scapegoats[0..i]) |other| {
                    if (other) |earlier| if (earlier.blob.eql(p_origin.blob)) break true;
                } else false;
                if (!repeated) scapegoats[i] = p_origin;
            }
        }
        for (n.parents, scapegoats) |parent_oid, maybe| {
            const p_origin = maybe orelse continue;
            try s.passToParent(o, p_origin);
            if (p_origin.suspects.items.len != 0) try s.enqueue(try s.node(parent_oid));
            if (o.suspects.items.len == 0) return;
        }
        // What no parent took is this commit's.
        for (o.suspects.items) |l| try s.guilty.append(s.arena, .{ .final = l.final, .at = l.at, .origin = o });
        o.suspects.clearRetainingCapacity();
    }

    /// git's `find_origin`: the file at the same path in the parent, when
    /// it is a file of the same kind there.
    fn samePath(s: *Scoreboard, parent: *Node, o: *const Origin) Error!?*Origin {
        const entry = (try s.entryAt(parent.tree, o.path)) orelse return null;
        if (!sameKind(entry.mode, try s.modeAt(o))) return null;
        const found = try s.origin(parent, o.path, entry.oid);
        return found;
    }

    fn modeAt(s: *Scoreboard, o: *const Origin) Error!object.Mode {
        const n = s.nodes.get(o.commit.bytes).?;
        return (try s.entryAt(n.tree, o.path)).?.mode;
    }

    /// git's `find_rename`: the file this one was renamed from, among the
    /// files the parent has and the commit does not, by git's rename
    /// detection with this path as the only destination.
    fn renamedFrom(s: *Scoreboard, n: *Node, parent: *Node, o: *const Origin) Error!?*Origin {
        // A path the parent has as a file is no destination: that is a
        // change of kind, not an addition.
        if (try s.entryAt(parent.tree, o.path)) |entry| {
            if (!entry.mode.isTree()) return null;
        }
        var changes = try diff.tree(s.gpa, s.io, s.db, parent.tree, n.tree, .{});
        defer changes.deinit();
        var queue: std.ArrayList(*rename.Pair) = .empty;
        var target: ?*rename.Pair = null;
        for (changes.items) |c| {
            const is_source = c.status == .deleted;
            const is_target = c.status == .added and std.mem.eql(u8, c.new.?.path, o.path);
            if (!is_source and !is_target) continue;
            const one = try s.arena.create(rename.Spec);
            const two = try s.arena.create(rename.Spec);
            if (is_source) {
                one.* = .{ .path = try s.arena.dupe(u8, c.old.?.path), .mode = c.old.?.mode.raw(), .oid = c.old.?.oid };
                two.* = .{ .path = one.path, .oid = Oid.zero(s.db.objectFormat()) };
            } else {
                two.* = .{ .path = o.path, .mode = c.new.?.mode.raw(), .oid = c.new.?.oid };
                one.* = .{ .path = o.path, .oid = Oid.zero(s.db.objectFormat()) };
            }
            const p = try s.arena.create(rename.Pair);
            p.* = .{ .one = one, .two = two };
            try queue.append(s.arena, p);
            if (is_target) target = p;
        }
        const wanted = target orelse return null;
        _ = try rename.detect(s.arena, s.io, s.db, &queue, .{});
        if (!wanted.renamed) return null;
        const found = try s.origin(parent, wanted.one.path, wanted.one.oid);
        return found;
    }

    /// git's `pass_blame_to_parent`: every suspect on a line the diff from
    /// the parent's copy leaves alone goes to the parent, at its line there.
    fn passToParent(s: *Scoreboard, target: *Origin, parent: *Origin) Error!void {
        const old = try s.linesOf(parent.blob);
        const new = try s.linesOf(target.blob);
        const changes = try textdiff.diffLines(s.gpa, old, new, .{});
        defer s.gpa.free(changes);
        std.mem.sort(Suspect, target.suspects.items, {}, byAt);
        var kept: usize = 0;
        var c: usize = 0;
        var offset: i64 = 0;
        for (target.suspects.items) |l| {
            while (c < changes.len and changes[c].new_start + changes[c].new_count <= l.at) : (c += 1) {
                offset = @as(i64, @intCast(changes[c].old_start + changes[c].old_count)) - @as(i64, @intCast(changes[c].new_start + changes[c].new_count));
            }
            if (c < changes.len and changes[c].new_start <= l.at) {
                // Inside a change: the target's own line.
                target.suspects.items[kept] = l;
                kept += 1;
                continue;
            }
            try parent.suspects.append(s.arena, .{ .final = l.final, .at = @intCast(@as(i64, l.at) + offset) });
        }
        target.suspects.shrinkRetainingCapacity(kept);
    }
};

fn byAt(_: void, a: Suspect, b: Suspect) bool {
    return a.at < b.at;
}

/// Whether two modes are files of one kind: both regular files, both
/// symlinks or both gitlinks, which is when git's diff says `M` and not `T`.
fn sameKind(a: object.Mode, b: object.Mode) bool {
    const regular_a = a == .file or a == .exec;
    const regular_b = b == .file or b == .exec;
    if (regular_a or regular_b) return regular_a and regular_b;
    return a == b;
}
