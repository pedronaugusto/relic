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
//! binary file contributes its two object names instead of its lines. A
//! merge commit has no patch id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const diff = @import("diff.zig");
const textdiff = @import("textdiff.zig");

const Oid = hash.Oid;

/// Errors from computing a patch id.
pub const Error = diff.Error || object.ParseError || error{NotACommit};

/// The patch id of `commit` against its parent, or against nothing for a
/// root commit. `null` for a merge, which has none.
pub fn ofCommit(gpa: Allocator, io: Io, db: *odb_mod.Odb, commit_oid: Oid) Error!?Oid {
    const found = try db.read(io, commit_oid);
    defer db.gpa.free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    var commit = try object.Commit.parse(gpa, db.kind, found.bytes);
    defer commit.deinit();
    if (commit.parents.len > 1) return null;
    var parent_tree: ?Oid = null;
    if (commit.parents.len == 1) {
        const parent = try db.read(io, commit.parents[0]);
        defer db.gpa.free(parent.bytes);
        if (parent.type != .commit) return error.NotACommit;
        var parsed = try object.Commit.parse(gpa, db.kind, parent.bytes);
        defer parsed.deinit();
        parent_tree = parsed.tree;
    }
    return try ofTrees(gpa, io, db, parent_tree, commit.tree);
}

/// The patch id of the change from `old` to `new`, either of which may be
/// the empty tree.
pub fn ofTrees(gpa: Allocator, io: Io, db: *odb_mod.Odb, old: ?Oid, new: ?Oid) Error!Oid {
    var changes = try diff.tree(gpa, io, db, old, new, .{});
    defer changes.deinit();
    var result: [hash.max_raw_len]u8 = @splat(0);
    const raw_len = db.kind.rawLen();
    for (changes.items) |change| {
        var h: hash.Hasher = .init(db.kind);
        try hashChange(gpa, io, db, &h, change);
        const part = h.final();
        // Summed byte by byte with a carry, from the first byte up.
        var carry: u16 = 0;
        for (0..raw_len) |i| {
            carry += @as(u16, result[i]) + part.bytes[i];
            result[i] = @truncate(carry);
            carry >>= 8;
        }
    }
    return Oid.fromRaw(db.kind, result[0..raw_len]) catch unreachable;
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
    h.update(std.fmt.bufPrint(&buf, "{o:0>6}", .{mode.raw()}) catch unreachable);
}

/// Read a side of a change: a blob's bytes, a symlink's target, or what git
/// prints for a submodule.
fn sideBytes(gpa: Allocator, io: Io, db: *odb_mod.Odb, entry: ?diff.Entry) Error![]u8 {
    const e = entry orelse return gpa.alloc(u8, 0);
    if (e.mode == .gitlink) {
        var hex: [hash.max_hex_len]u8 = undefined;
        return std.fmt.allocPrint(gpa, "Subproject commit {s}\n", .{e.oid.hex(&hex)});
    }
    const found = try db.read(io, e.oid);
    defer db.gpa.free(found.bytes);
    return gpa.dupe(u8, found.bytes);
}

fn hashChange(gpa: Allocator, io: Io, db: *odb_mod.Odb, h: *hash.Hasher, change: diff.Change) Error!void {
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
    if (textdiff.isBinary(old_bytes) or textdiff.isBinary(new_bytes)) {
        var hex: [hash.max_hex_len]u8 = undefined;
        const zero = Oid.zero(db.kind);
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

    const old_lines = try textdiff.splitLines(gpa, old_bytes);
    defer gpa.free(old_lines);
    const new_lines = try textdiff.splitLines(gpa, new_bytes);
    defer gpa.free(new_lines);
    // No indentation heuristic: the patch id is taken with xdiff's plain
    // settings.
    const options: textdiff.Options = .{ .indent_heuristic = false };
    const script = try textdiff.diffLines(gpa, old_lines, new_lines, options);
    defer gpa.free(script);
    const groups = try textdiff.hunks(gpa, script, old_lines.len, new_lines.len, options);
    defer gpa.free(groups);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    for (groups) |hunk| {
        var old_at = hunk.old_start;
        var new_at = hunk.new_start;
        for (hunk.changes) |c| {
            while (old_at < c.old_start) : ({
                old_at += 1;
                new_at += 1;
            }) try addLine(gpa, h, &scratch, "", old_lines[old_at]);
            for (0..c.old_count) |_| {
                try addLine(gpa, h, &scratch, "-", old_lines[old_at]);
                old_at += 1;
            }
            for (0..c.new_count) |_| {
                try addLine(gpa, h, &scratch, "+", new_lines[new_at]);
                new_at += 1;
            }
        }
        while (old_at < hunk.old_start + hunk.old_count) : ({
            old_at += 1;
            new_at += 1;
        }) try addLine(gpa, h, &scratch, "", old_lines[old_at]);
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

const testgit = @import("testgit.zig");

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
        const got = (try ofCommit(gpa, io, &db, try Oid.parse(.sha1, commit_text))).?;
        var hex: [hash.max_hex_len]u8 = undefined;
        try std.testing.expectEqualStrings(line[0..40], got.hex(&hex));
    }
}
