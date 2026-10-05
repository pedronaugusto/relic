//! Putting the index and the working tree back to a commit's tree: `git
//! reset --merge` and `git reset --hard`, which is how every history-editing
//! command is aborted.
//!
//! `merge` is the careful one, and it is what `git merge --abort` and `git
//! cherry-pick --abort` run: a path whose index entry already matches the
//! tree keeps whatever the working tree has, so changes a person made before
//! the command started survive it; a conflicted path is put back whatever it
//! holds, because its markers were written by the command being undone; and
//! any other path is put back only if the file still matches the index,
//! since otherwise the only copy of something would be lost. `hard` puts
//! everything back and asks nothing, which is what `git rebase --abort` does.
//! Neither moves `HEAD`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const index_mod = @import("../index.zig");
const worktree = @import("../worktree.zig");
const convert = @import("../worktree/convert.zig");
const fs = @import("../repo/fs.zig");
const repo_mod = @import("../repo.zig");
const threeway = @import("../merge/threeway.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Repository = repo_mod.Repository;

/// Errors from a reset.
pub const Error = threeway.Error;

/// How much of the working tree a reset may overwrite.
pub const Mode = enum {
    /// `--merge`: refuse to lose a change that is not the command's own.
    merge,
    /// `--hard`: overwrite everything.
    hard,
};

/// Make `index` and the working tree hold `tree`, as `mode` allows.
/// `blocked`, when given, is where a refusal writes the path that caused it.
/// The caller writes the index.
pub fn toTree(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *Index,
    tree: Oid,
    mode: Mode,
    blocked: ?*threeway.Blocked,
) Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = repo.work_dir orelse return error.BareRepository;
    const db = &repo.odb;

    var rules = try repo.worktreeRules();
    rules.required_filters = try repo.requiredFilters(arena);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;

    var wanted = try worktree.flatten(arena, io, db, tree);

    // Every path the index has, at any stage, and whether it is conflicted.
    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    var current: std.array_hash_map.String(?index_mod.Entry) = .empty;
    for (index.entries.items) |entry| {
        const path = try arena.dupe(u8, entry.path);
        if (entry.stage != 0) {
            try conflicted.put(arena, path, {});
            if (!current.contains(path)) try current.put(arena, path, null);
            continue;
        }
        var copy = entry;
        copy.path = path;
        try current.put(arena, path, copy);
    }

    // Paths to rewrite, remove, or leave as the index has them.
    var rewrite: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    for (current.keys(), current.values()) |path, entry| {
        const want = wanted.get(path);
        const is_conflicted = conflicted.contains(path);
        if (!is_conflicted) {
            const e = entry.?;
            if (want != null and want.?.mode == e.mode and want.?.oid.eql(e.oid)) {
                if (mode == .hard and !e.skip_worktree and try differs(gpa, io, wt, index, e, rules)) {
                    try rewrite.append(arena, path);
                }
                continue;
            }
            if (mode == .merge and !e.skip_worktree and try differs(gpa, io, wt, index, e, rules)) {
                if (blocked) |b| b.set(path);
                return error.LocalChangesWouldBeOverwritten;
            }
        }
        if (want == null) try remove.append(arena, path) else try rewrite.append(arena, path);
    }
    var wanted_it = wanted.keyIterator();
    while (wanted_it.next()) |path| {
        if (current.contains(path.*)) continue;
        if (mode == .merge) {
            if (try fs.statAt(io, wt, path.*)) |found| {
                if (found.kind != .directory) {
                    if (blocked) |b| b.set(path.*);
                    return error.UntrackedWouldBeOverwritten;
                }
            }
        }
        try rewrite.append(arena, path.*);
    }
    std.mem.sort([]const u8, rewrite.items, {}, lessThanPath);
    std.mem.sort([]const u8, remove.items, {}, lessThanPath);

    // Git's checkout reads attributes from the index it is installing.
    // Keep the old rules for the local-change checks above, then use the
    // target tree's files for every path written below.
    var write_attrs = try repo.loadAttrs(io);
    defer write_attrs.deinit();
    try worktree.addTreeAttributes(arena, io, db, &write_attrs, &wanted);
    rules.attrs = &write_attrs;

    var i = remove.items.len;
    while (i > 0) {
        i -= 1;
        try worktree.removeEntry(io, wt, remove.items[i]);
    }
    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = rules.core,
        .required_filters = rules.required_filters,
        .drivers = rules.filters,
    });
    defer conv.deinit();
    var stats: std.StringHashMapUnmanaged(fs.Stat) = .empty;
    for (rewrite.items) |path| {
        const want = wanted.get(path).?;
        if (try fs.statAt(io, wt, path)) |found| {
            if (found.kind == .directory) try wt.deleteTree(io, path);
        }
        // Validate before `enter` consults a directory in the working tree.
        if (worktree.safepath.check(path, .worktree) != null) return error.UnsafePath;
        try write_attrs.enter(io, wt, path);
        const written = try worktree.writeEntry(gpa, io, wt, db, &conv, path, want.mode, want.oid, rules);
        try stats.put(arena, path, written.stat);
    }

    // The index is the tree, keeping what it knew of paths it already had
    // right.
    var fresh: std.ArrayList(index_mod.Entry) = .empty;
    var it = wanted.iterator();
    while (it.next()) |pair| {
        const path = pair.key_ptr.*;
        const want = pair.value_ptr.*;
        var entry: index_mod.Entry = .{ .path = path, .oid = want.oid, .mode = want.mode };
        if (current.get(path)) |maybe| {
            if (maybe) |old| {
                if (old.oid.eql(want.oid) and old.mode == want.mode) entry = old;
                entry.skip_worktree = old.skip_worktree;
            }
        }
        if (stats.get(path)) |stat| entry.stat = stat;
        entry.path = path;
        try fresh.append(arena, entry);
    }
    index.clear();
    try index.addMany(fresh.items);
    const cache_tree = try index.cacheTree();
    cache_tree.invalidateAll();
    cache_tree.root.entry_count = @intCast(index.entries.items.len);
    cache_tree.root.oid = tree;
    // As git's `unpack_trees` leaves it: no resolutions remembered.
    index.dropResolveUndo();
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Whether the file for `entry` is something other than the index says. A
/// missing file loses nothing.
fn differs(gpa: Allocator, io: Io, wt: Io.Dir, index: *const Index, entry: index_mod.Entry, rules: worktree.Rules) Error!bool {
    return threeway.differsOnDisk(gpa, io, wt, index, entry, rules);
}

test "reset writes through the target tree's attributes as git reset hard does" {
    const testgit = @import("../testing/git.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    try fixture.writeFile(io, ".gitattributes", "file text eol=lf\n");
    try fixture.writeFile(io, "file", "old\n");
    try fixture.exec(io, &.{ "add", "-A" });
    try fixture.exec(io, &.{ "commit", "-qm", "old" });
    try fixture.exec(io, &.{ "tag", "old" });
    try fixture.writeFile(io, ".gitattributes", "file text eol=crlf\n");
    try fixture.writeFile(io, "file", "new\n");
    try fixture.exec(io, &.{ "add", "-A" });
    try fixture.exec(io, &.{ "commit", "-qm", "new" });
    try fixture.exec(io, &.{ "tag", "new" });
    const tree_text = try fixture.run(io, &.{ "rev-parse", "new^{tree}" });
    defer gpa.free(tree_text);
    const tree = try Oid.parse(.sha1, std.mem.trim(u8, tree_text, "\r\n"));

    try fixture.exec(io, &.{ "reset", "-q", "--hard", "old" });
    try fixture.exec(io, &.{ "reset", "-q", "--hard", "new" });
    const expected = try fixture.dir.readFileAlloc(io, "file", gpa, .limited(100));
    defer gpa.free(expected);
    try std.testing.expectEqualStrings("new\r\n", expected);
    try fixture.exec(io, &.{ "reset", "-q", "--hard", "old" });
    var repo = try Repository.open(gpa, io, fixture.dir, .{});
    defer repo.deinit(io);
    var idx = try repo.openIndex(io);
    defer idx.deinit();
    try toTree(gpa, io, &repo, &idx, tree, .hard, null);
    const actual = try fixture.dir.readFileAlloc(io, "file", gpa, .limited(100));
    defer gpa.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}
