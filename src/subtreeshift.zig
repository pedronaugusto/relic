//! Lining one tree up with another that holds it one or more directories
//! down, or that it holds: git's match-trees, which the merge strategy
//! options `subtree` and `subtree=<path>` run before a merge.
//!
//! A project merged in as a subdirectory of another has its files at `lib/`
//! on one side and at the top on the other. Before the merge, the other
//! side and the base are shifted to match our tree: given a path, by
//! exactly that much, whichever way fits; given none, by the directory that
//! scores best, found by comparing the two trees entry by entry and every
//! directory of each, to a depth of three, against the other. Shifting down
//! puts the tree at that path inside a copy of ours, so everything else of
//! ours is unchanged by the merge; shifting up takes the subtree at that
//! path. The scores, the walk order that settles a tie and the refusal to
//! shift when nothing scores better are git's, so the merge lines the same
//! files up as git's does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");

const Oid = hash.Oid;

/// Errors from shifting a tree.
pub const Error = error{
    /// An object the shift reads as a tree is something else.
    NotATree,
} || odb_mod.Error || object.TreeParseError || Allocator.Error;

/// `two` shifted to line up with `one`: git's `shift_tree_object`. `prefix`
/// empty works the shift out from the trees; otherwise it is the path to
/// shift by, as `-X subtree=<path>` gives it. `two` itself when no shift
/// fits. A tree the shift makes is written to `db`.
pub fn shift(gpa: Allocator, io: Io, db: *odb_mod.Odb, one: Oid, two: Oid, prefix: []const u8) Error!Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const s: Shifter = .{ .arena = arena_state.allocator(), .io = io, .db = db };
    if (prefix.len == 0) return s.shiftTree(one, two);
    return s.shiftTreeBy(one, two, prefix);
}

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;

fn isDir(mode: u32) bool {
    return mode & S_IFMT == S_IFDIR;
}

fn isLink(mode: u32) bool {
    return mode & S_IFMT == S_IFLNK;
}

/// A path one tree has and the other lacks.
fn scoreMissing(mode: u32) i32 {
    if (isDir(mode)) return -1000;
    if (isLink(mode)) return -500;
    return -50;
}

/// A path both trees have, with different contents.
fn scoreDiffers(mode1: u32, mode2: u32) i32 {
    if (isDir(mode1) != isDir(mode2)) return -100;
    if (isLink(mode1) != isLink(mode2)) return -50;
    return -5;
}

/// A path both trees have with the same object.
fn scoreMatches(mode1: u32, mode2: u32) i32 {
    if (isDir(mode1) != isDir(mode2)) return -100;
    if (isLink(mode1) != isLink(mode2)) return -50;
    if (isDir(mode1)) return 1000;
    if (isLink(mode1)) return 500;
    return 250;
}

const Entry = struct { name: []const u8, mode: u32, oid: Oid };

/// `base_name_compare`: a directory's name sorts as though it ended in
/// `/`.
fn baseNameOrder(a: Entry, b: Entry) std.math.Order {
    const len = @min(a.name.len, b.name.len);
    switch (std.mem.order(u8, a.name[0..len], b.name[0..len])) {
        .eq => {},
        else => |o| return o,
    }
    const c1: u8 = if (a.name.len > len) a.name[len] else if (isDir(a.mode)) '/' else 0;
    const c2: u8 = if (b.name.len > len) b.name[len] else if (isDir(b.mode)) '/' else 0;
    return std.math.order(c1, c2);
}

const Shifter = struct {
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,

    /// A tree's entries in its own order; the empty tree needs no object.
    fn entries(s: Shifter, oid: Oid) Error![]Entry {
        if (oid.eql(hash.Hasher.object(s.db.kind, "tree", ""))) return &.{};
        const bytes = try s.treeBytes(oid);
        var out: std.ArrayList(Entry) = .empty;
        var it = object.Tree.parse(s.db.kind, bytes).iterate();
        while (try it.next()) |e| try out.append(s.arena, .{ .name = e.name, .mode = e.mode.raw(), .oid = e.oid });
        return out.items;
    }

    fn treeBytes(s: Shifter, oid: Oid) Error![]const u8 {
        if (oid.eql(hash.Hasher.object(s.db.kind, "tree", ""))) return "";
        const found = try s.db.read(s.io, oid);
        defer s.db.gpa.free(found.bytes);
        if (found.type != .tree) return error.NotATree;
        return s.arena.dupe(u8, found.bytes);
    }

    /// `score_trees`: the two trees' top levels walked together, each
    /// name scored by whether both have it and with what.
    fn scoreTrees(s: Shifter, oid1: Oid, oid2: Oid) Error!i32 {
        const one = try s.entries(oid1);
        const two = try s.entries(oid2);
        var i: usize = 0;
        var j: usize = 0;
        var score: i32 = 0;
        while (i < one.len or j < two.len) {
            const order: std.math.Order = if (i < one.len and j < two.len)
                baseNameOrder(one[i], two[j])
            else if (i < one.len) .lt else .gt;
            switch (order) {
                .lt => {
                    score += scoreMissing(one[i].mode);
                    i += 1;
                },
                .gt => {
                    score += scoreMissing(two[j].mode);
                    j += 1;
                },
                .eq => {
                    score += if (one[i].oid.eql(two[j].oid)) scoreMatches(one[i].mode, two[j].mode) else scoreDiffers(one[i].mode, two[j].mode);
                    i += 1;
                    j += 1;
                },
            }
        }
        return score;
    }

    /// `match_trees`: every directory of `oid1`, `limit` levels further
    /// down too, scored against `oid2`; a strictly better score takes
    /// `best`, so the first found keeps a tie.
    fn matchTrees(s: Shifter, oid1: Oid, oid2: Oid, best_score: *i32, best: *[]const u8, base: []const u8, limit: u32) Error!void {
        for (try s.entries(oid1)) |e| {
            if (!isDir(e.mode)) continue;
            const score = try s.scoreTrees(e.oid, oid2);
            if (best_score.* < score) {
                best.* = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ base, e.name });
                best_score.* = score;
            }
            if (limit != 0) {
                const deeper = try std.fmt.allocPrint(s.arena, "{s}{s}/", .{ base, e.name });
                try s.matchTrees(e.oid, oid2, best_score, best, deeper, limit - 1);
            }
        }
    }

    /// `splice_tree`: `oid1` with the directory at `prefix` replaced by
    /// `oid2`, each tree on the way written anew.
    fn spliceTree(s: Shifter, oid1: Oid, prefix: []const u8, oid2: Oid) Error!Oid {
        const slash = std.mem.indexOfScalar(u8, prefix, '/');
        const top = prefix[0 .. slash orelse prefix.len];
        const rest = if (slash) |at| prefix[at + 1 ..] else "";
        const bytes = try s.arena.dupe(u8, try s.treeBytes(oid1));
        const raw_len = s.db.kind.rawLen();
        var it = object.Tree.parse(s.db.kind, bytes).iterate();
        while (try it.next()) |e| {
            if (!std.mem.eql(u8, e.name, top)) continue;
            // git refuses here; the paths it is given are all directories.
            if (!e.mode.isTree()) return error.NotATree;
            const with = if (rest.len != 0) try s.spliceTree(e.oid, rest, oid2) else oid2;
            @memcpy(bytes[it.offset - raw_len .. it.offset], with.raw());
            return s.db.write(s.io, .tree, bytes);
        }
        return error.NotATree;
    }

    /// `get_tree_entry`: the object at `path` in `tree` and its mode, or
    /// `null`. An empty path is the tree itself.
    fn treeEntry(s: Shifter, tree: Oid, path: []const u8) Error!?Entry {
        if (path.len == 0) return .{ .name = "", .mode = S_IFDIR, .oid = tree };
        for (try s.entries(tree)) |e| {
            if (e.name.len > path.len) continue;
            switch (std.mem.order(u8, path[0..e.name.len], e.name)) {
                .gt => continue,
                .lt => return null,
                .eq => {},
            }
            if (e.name.len == path.len) return e;
            if (path[e.name.len] != '/') continue;
            if (!isDir(e.mode)) return null;
            if (e.name.len + 1 == path.len) return e;
            return s.treeEntry(e.oid, path[e.name.len + 1 ..]);
        }
        return null;
    }

    /// `shift_tree`: `two` put under the directory of `one` it best
    /// matches, or cut down to its directory that best matches `one`,
    /// whichever scores higher, or left alone.
    fn shiftTree(s: Shifter, one: Oid, two: Oid) Error!Oid {
        // git's depth limit.
        const depth_limit = 2;
        var add_score = try s.scoreTrees(one, two);
        var del_score = add_score;
        var add_prefix: []const u8 = "";
        var del_prefix: []const u8 = "";
        try s.matchTrees(one, two, &add_score, &add_prefix, "", depth_limit);
        try s.matchTrees(two, one, &del_score, &del_prefix, "", depth_limit);
        if (add_score < del_score) {
            if (del_prefix.len == 0) return two;
            const found = (try s.treeEntry(two, del_prefix)) orelse return error.NotATree;
            return found.oid;
        }
        if (add_prefix.len == 0) return two;
        return s.spliceTree(one, add_prefix, two);
    }

    /// `shift_tree_by`: `two` shifted by exactly `prefix`, down if `one`
    /// has a directory there, up if `two` has, by the better score if
    /// both, and not at all if neither or if neither scores above the
    /// trees as they are.
    fn shiftTreeBy(s: Shifter, one: Oid, two: Oid, prefix: []const u8) Error!Oid {
        const sub1 = try s.treeEntry(one, prefix);
        const sub2 = try s.treeEntry(two, prefix);
        const down = if (sub1) |e| isDir(e.mode) else false;
        const up = if (sub2) |e| isDir(e.mode) else false;
        var candidate: enum { none, down, up } = if (down and up) .none else if (down) .down else if (up) .up else .none;
        if (down and up) {
            var best = try s.scoreTrees(one, two);
            const score1 = try s.scoreTrees(sub1.?.oid, two);
            if (score1 > best) {
                candidate = .down;
                best = score1;
            }
            if (try s.scoreTrees(sub2.?.oid, one) > best) candidate = .up;
        }
        return switch (candidate) {
            .none => two,
            .down => s.spliceTree(one, prefix, two),
            .up => sub2.?.oid,
        };
    }
};

test "a side kept at the top shifts down under the directory ours holds it in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    var db = try odb_mod.Odb.open(gpa, io, tmp.dir, .sha1, .{});
    defer db.deinit(io);

    const a = try db.write(io, .blob, "a\n");
    const b = try db.write(io, .blob, "b\n");
    const readme = try db.write(io, .blob, "readme\n");
    const lib = try writeTree(io, &db, &.{ .{ "a", "100644", a }, .{ "b", "100644", b } });
    const ours = try writeTree(io, &db, &.{ .{ "README", "100644", readme }, .{ "lib", "40000", lib } });
    const edited = try db.write(io, .blob, "b, edited\n");
    const theirs = try writeTree(io, &db, &.{ .{ "a", "100644", a }, .{ "b", "100644", edited } });

    const expected_lib = try writeTree(io, &db, &.{ .{ "a", "100644", a }, .{ "b", "100644", edited } });
    const expected = try writeTree(io, &db, &.{ .{ "README", "100644", readme }, .{ "lib", "40000", expected_lib } });
    try std.testing.expect(expected.eql(try shift(gpa, io, &db, ours, theirs, "")));
    try std.testing.expect(expected.eql(try shift(gpa, io, &db, ours, theirs, "lib")));
    // The other way round, the whole project is cut down to `lib`.
    try std.testing.expect(lib.eql(try shift(gpa, io, &db, theirs, ours, "")));
    try std.testing.expect(lib.eql(try shift(gpa, io, &db, theirs, ours, "lib/")));
    // A path neither tree has shifts nothing.
    try std.testing.expect(theirs.eql(try shift(gpa, io, &db, ours, theirs, "elsewhere")));
}

fn writeTree(io: Io, db: *odb_mod.Odb, items: []const struct { []const u8, []const u8, Oid }) !Oid {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (items) |item| {
        try w.print("{s} {s}\x00", .{ item[1], item[0] });
        try w.writeAll(item[2].raw());
    }
    return db.write(io, .tree, w.buffered());
}
