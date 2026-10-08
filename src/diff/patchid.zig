//! Patch ids: a name for what a commit changes, whatever lines it moved and
//! whatever whitespace it touched, as git computes it to tell that a commit
//! is already upstream.
//!
//! A rebase leaves out a commit whose patch id matches one of upstream's,
//! so the id has to be git's to leave out the same ones. It is the stable
//! form: each file's part of the diff is hashed on its own and the hashes
//! are summed, so the order of files does not matter, and within a file what
//! is hashed is the diff with a context of three lines, every hunk header
//! and every whitespace character left out, with rename detection off. A
//! binary file -- by its `diff` attribute, as git's diff decides, or by its
//! bytes -- contributes its two object names instead of its lines. A merge
//! commit has no patch id.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const diff = @import("diff.zig");
const parallax = @import("parallax");
const attributes = @import("../patterns/attributes.zig");

const Oid = hash.Oid;

/// Errors from computing a patch id.
pub const Error = diff.Error || diff.TextError || object.ParseError || attributes.Error || error{NotACommit};

/// The patch id of `commit` against its parent, or against nothing for a
/// root commit. `null` for a merge, which has none. `binary` says which
/// files are binary: a rebase hands it the repository's attributes, as
/// git's patch ids read them.
pub fn ofCommit(gpa: Allocator, io: Io, db: *odb_mod.Odb, commit_oid: Oid, binary: diff.BinaryRule) Self.Error!?Oid {
    const found = try db.read(io, commit_oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    var commit = try object.Commit.parse(gpa, db.objectFormat(), found.bytes);
    defer commit.deinit();
    if (commit.parents.len > 1) return null;
    var parent_tree: ?Oid = null;
    if (commit.parents.len == 1) {
        const parent = try db.read(io, commit.parents[0]);
        defer db.allocator().free(parent.bytes);
        if (parent.type != .commit) return error.NotACommit;
        var parsed = try object.Commit.parse(gpa, db.objectFormat(), parent.bytes);
        defer parsed.deinit();
        parent_tree = parsed.tree;
    }
    const id = try ofTrees(gpa, io, db, parent_tree, commit.tree, binary);
    return id;
}

/// The patch id of the change from `old` to `new`, either of which may be
/// the empty tree.
pub fn ofTrees(gpa: Allocator, io: Io, db: *odb_mod.Odb, old: ?Oid, new: ?Oid, binary: diff.BinaryRule) Self.Error!Oid {
    var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{});
    defer changes.deinit();
    var result: [hash.max_raw_len]u8 = @splat(0);
    const raw_len = db.objectFormat().rawLen();
    for (changes.items) |change| {
        var h: hash.Hasher = .init(db.objectFormat());
        try hashChange(gpa, io, db, &h, change, binary);
        const part = h.final();
        // Summed byte by byte with a carry, from the first byte up.
        var carry: u16 = 0;
        for (0..raw_len) |i| {
            carry += @as(u16, result[i]) + part.bytes[i];
            result[i] = @truncate(carry);
            carry >>= 8;
        }
    }
    // unreachable: the slice is cut to the format's raw length
    return Oid.fromRaw(db.objectFormat(), result[0..raw_len]) catch unreachable;
}

/// git's `isspace`: no vertical tab and no form feed.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The bytes of `text` that are not whitespace, in `buf`.
fn withoutSpace(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (isSpace(c)) continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn addPath(h: *hash.Hasher, path: []const u8) void {
    for (path) |c| {
        if (isSpace(c)) continue;
        h.update(&.{c});
    }
}

fn addMode(h: *hash.Hasher, mode: object.Mode) void {
    var buf: [16]u8 = undefined;
    // unreachable: a u32 is at most 11 octal digits
    h.update(std.mem.print(&buf, "{o:0>6}", .{mode.raw()}) catch unreachable);
}

/// Read a side of a change: a blob's bytes, a symlink's target, or what git
/// prints for a submodule.
fn sideBytes(gpa: Allocator, io: Io, db: *odb_mod.Odb, entry: ?diff.Entry) Error![]u8 {
    const e = entry orelse return gpa.alloc(u8, 0);
    if (e.mode == .gitlink) {
        var hex: [hash.max_hex_len]u8 = undefined;
        return gpa.print("Subproject commit {s}\n", .{e.oid.hex(&hex)});
    }
    const found = try db.read(io, e.oid);
    defer db.allocator().free(found.bytes);
    return gpa.dupe(u8, found.bytes);
}

fn hashChange(gpa: Allocator, io: Io, db: *odb_mod.Odb, h: *hash.Hasher, change: diff.Change, binary: diff.BinaryRule) Error!void {
    const path = change.path();
    h.update("diff--git");
    h.update("a/");
    addPath(h, path);
    h.update("b/");
    addPath(h, path);
    const old = change.old;
    const new = change.new;
    if (old == null) {
        h.update("newfilemode");
        addMode(h, new.?.mode);
    } else if (new == null) {
        h.update("deletedfilemode");
        addMode(h, old.?.mode);
    } else if (old.?.mode != new.?.mode) {
        h.update("oldmode");
        addMode(h, old.?.mode);
        h.update("newmode");
        addMode(h, new.?.mode);
    }

    const old_bytes = try sideBytes(gpa, io, db, old);
    defer gpa.free(old_bytes);
    const new_bytes = try sideBytes(gpa, io, db, new);
    defer gpa.free(new_bytes);
    var lookup: std.heap.ArenaAllocator = .init(gpa);
    defer lookup.deinit();
    const old_binary = old != null and try binary.isBinary(lookup.allocator(), io, old.?.path, old_bytes);
    const new_binary = new != null and try binary.isBinary(lookup.allocator(), io, new.?.path, new_bytes);
    if (old_binary or new_binary) {
        var hex: [hash.max_hex_len]u8 = undefined;
        const zero = Oid.zero(db.objectFormat());
        h.update((if (old) |e| e.oid else zero).hex(&hex));
        h.update((if (new) |e| e.oid else zero).hex(&hex));
        return;
    }
    if (old == null) {
        h.update("---/dev/null");
        h.update("+++b/");
        addPath(h, path);
    } else if (new == null) {
        h.update("---a/");
        addPath(h, path);
        h.update("+++/dev/null");
    } else {
        h.update("---a/");
        addPath(h, path);
        h.update("+++b/");
        addPath(h, path);
    }

    // No indentation heuristic: the patch id is taken with xdiff's plain
    // settings.
    var script = try parallax.diffLines(gpa, old_bytes, new_bytes, .{ .indent_heuristic = false });
    defer script.deinit();
    const d = script.diff;

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var hunks = d.hunks(.{});
    while (hunks.next()) |hunk| {
        var old_at = hunk.old_start;
        var new_at = hunk.new_start;
        for (hunk.changes) |c| {
            while (old_at < c.old_start) : ({
                old_at += 1;
                new_at += 1;
            }) try addLine(gpa, h, &scratch, "", d.new.get(new_at));
            for (c.old_start..c.old_start + c.old_len) |i| try addLine(gpa, h, &scratch, "-", d.old.get(@intCast(i)));
            for (c.new_start..c.new_start + c.new_len) |i| try addLine(gpa, h, &scratch, "+", d.new.get(@intCast(i)));
            old_at = c.old_start + c.old_len;
            new_at = c.new_start + c.new_len;
        }
        while (new_at < hunk.new_start + hunk.new_len) : (new_at += 1) {
            try addLine(gpa, h, &scratch, "", d.new.get(new_at));
        }
    }
}

/// One diff line, its marker kept and every whitespace byte dropped -- the
/// space that marks a context line with them.
fn addLine(gpa: Allocator, h: *hash.Hasher, scratch: *std.ArrayList(u8), marker: []const u8, line: []const u8) Allocator.Error!void {
    try scratch.resize(gpa, line.len);
    h.update(marker);
    h.update(withoutSpace(line, scratch.items));
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("../testing/git.zig");

test "patch ids are the ones git patch-id --stable reads from the same diff" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "text", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n");
    try repo.writeFile(io, "gone", "bye\n");
    try repo.writeFile(io, "tail", "no newline");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "root" });
    // What git patch-id reads is a patch's text, which says nothing about a
    // binary file or a change of mode alone; the id a rebase takes of those
    // is checked by the rebase tests, against git's own rebase.
    try repo.writeFile(io, "text", "one\nTWO\nthree\nfour\nfive\nsix\nseven\n  eight  spaced\nnine\nten\neleven\n");
    try repo.dir.deleteFile(io, "gone");
    try repo.writeFile(io, "new file", "hello\n");
    try repo.writeFile(io, "tail", "no newline, still");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "text" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "change" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    for ([_][]const u8{ "HEAD", "HEAD~1" }) |rev| {
        const patch = try repo.run(io, &.{ "show", "--no-renames", "--no-indent-heuristic", "--format=commit %H", rev });
        defer gpa.free(patch);
        const line = try repo.runInput(io, &.{ "patch-id", "--stable" }, patch);
        defer gpa.free(line);
        const commit_text = try repo.line(io, &.{ "rev-parse", rev });
        defer gpa.free(commit_text);
        const got = (try ofCommit(gpa, io, &db, try Oid.parse(.sha1, commit_text), .{})).?;
        var hex: [hash.max_hex_len]u8 = undefined;
        try std.testing.expectEqualStrings(line[0..40], got.hex(&hex));
    }
}

test "a file the attributes call binary is hashed by its names, so git cherry and the patch id agree on what is upstream" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |binary_attribute| {
        var repo = try testgit.Repo.init(gpa, io, &.{});
        defer repo.deinit();
        var lines: [20][]const u8 = undefined;
        for (&lines, 0..) |*l, i| l.* = try gpa.print("line {d}\n", .{i});
        defer for (lines) |l| gpa.free(l);
        const base_text = try std.mem.concat(gpa, u8, &lines);
        defer gpa.free(base_text);
        try repo.writeFile(io, "f", base_text);
        if (binary_attribute) try repo.writeFile(io, ".gitattributes", "f binary\n");
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
        try repo.exec(io, &.{ "branch", "topic" });
        // Upstream changes line 1 and then line 15; the topic changes line
        // 15 the same way.
        const first = try std.mem.replaceOwned(u8, gpa, base_text, "line 1\n", "LINE 1\n");
        defer gpa.free(first);
        try repo.writeFile(io, "f", first);
        try repo.exec(io, &.{ "commit", "-q", "-am", "u1" });
        const both = try std.mem.replaceOwned(u8, gpa, first, "line 15\n", "LINE 15\n");
        defer gpa.free(both);
        try repo.writeFile(io, "f", both);
        try repo.exec(io, &.{ "commit", "-q", "-am", "u2" });
        try repo.exec(io, &.{ "checkout", "-q", "topic" });
        const topic = try std.mem.replaceOwned(u8, gpa, base_text, "line 15\n", "LINE 15\n");
        defer gpa.free(topic);
        try repo.writeFile(io, "f", topic);
        try repo.exec(io, &.{ "commit", "-q", "-am", "t1" });

        const cherry = try repo.run(io, &.{ "cherry", "main", "topic" });
        defer gpa.free(cherry);
        const git_equal = cherry[0] == '-';
        try std.testing.expectEqual(!binary_attribute, git_equal);

        const git_dir = try repo.gitDir(io);
        defer git_dir.close(io);
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        var attrs: attributes.Attrs = try .init(gpa, false);
        defer attrs.deinit();
        defer attrs.leave();
        const rule: diff.BinaryRule = .{ .attrs = &attrs, .work_dir = repo.dir };
        const upstream_text = try repo.line(io, &.{ "rev-parse", "main" });
        defer gpa.free(upstream_text);
        const topic_text = try repo.line(io, &.{ "rev-parse", "topic" });
        defer gpa.free(topic_text);
        const upstream_id = (try ofCommit(gpa, io, &db, try Oid.parse(.sha1, upstream_text), rule)).?;
        const topic_id = (try ofCommit(gpa, io, &db, try Oid.parse(.sha1, topic_text), rule)).?;
        try std.testing.expectEqual(git_equal, upstream_id.eql(topic_id));
    }
}
