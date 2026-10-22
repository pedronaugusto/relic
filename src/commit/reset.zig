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
const path_mod = @import("../names.zig").path;
const git_mod = @import("../testing/git.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const index_mod = @import("../index/index.zig");
const worktree = @import("../checkout/checkout.zig");
const convert = @import("../checkout/convert.zig");
const fs = @import("../fs/fs.zig");
const repo_mod = @import("../repo/repo.zig");
const three_way = @import("../merge/three_way.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Repository = repo_mod.Repository;

/// Errors from a reset.
pub const Error = three_way.Error;

/// How much of the working tree a reset may overwrite.
pub const Mode = enum {
    /// `--merge`: refuse to lose a change that is not the command's own.
    merge,
    /// `--hard`: overwrite everything.
    hard,
};

/// Target state and overwrite policy for a reset.
pub const Options = struct {
    index: *Index,
    tree: Oid,
    mode: Mode = .merge,
    blocked: ?*three_way.Blocked = null,
    /// `--recurse-submodules`: what moves the submodules, as
    /// `worktree.Rules.submodules`. `hard` moves every one to the commit
    /// the tree records, forced, as git's `read-tree --reset`; `merge`
    /// moves those whose gitlink changes, refused where a submodule would
    /// lose work. Without one a submodule's checkout is left where it is.
    submodules: ?worktree.SubmoduleMover = null,
    /// Where a refused submodule is listed.
    obstructions: ?*worktree.Obstructions = null,
};

/// Make `index` and the working tree hold `tree`, as `mode` allows.
/// `blocked`, when given, is where a refusal writes the path that caused it.
/// The caller writes the index.
pub fn toTree(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,
) Error!void {
    const index = options.index;
    const tree = options.tree;
    const mode = options.mode;
    const blocked = options.blocked;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = repo.workDirectory() orelse return error.BareRepository;
    const db = repo.objectDatabase();

    var rules = try repo.worktreeRules();
    rules.submodules = options.submodules;
    rules.required_filters = try repo.requiredFilters(arena);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;

    var wanted = try worktree.flatten(arena, io, db, tree);

    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    var current: std.array_hash_map.String(?index_mod.Entry) = .empty;
    try readCurrent(arena, index, &current, &conflicted);

    // Paths to rewrite, remove, or leave as the index has them.
    var rewrite: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    for (current.keys(), current.values()) |path, entry| {
        const want = wanted.get(path);
        const is_conflicted = conflicted.contains(path);
        if (!is_conflicted) {
            const e = entry.?;
            if (want != null and want.?.mode == e.mode and want.?.oid.eql(e.oid)) {
                // `read-tree --reset` brings every submodule to its commit,
                // and a file back where it is gone (`oneway_merge`'s failed
                // `lstat`).
                const moved = e.mode == .gitlink and rules.submodules != null;
                if (mode == .hard and !e.skip_worktree and (moved or try gone(io, wt, e) or try differs(gpa, io, wt, index, e, rules))) {
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
    if (rules.submodules) |mover| {
        try worktree.verifySubmoduleMoves(gpa, io, wt, .{ .index = index, .updates = &try changedPaths(arena, &wanted, &current, remove.items, rewrite.items) }, .{
            .mover = mover,
            .force = mode == .hard,
            .obstructions = options.obstructions,
        });
        worktree.gitmodulesFirst(rewrite.items);
    }

    // Git's checkout reads attributes from the index it is installing.
    // Keep the old rules for the local-change checks above, then use the
    // target tree's files for every path written below.
    var write_attrs = try repo.loadAttrs(io);
    defer write_attrs.deinit();
    try worktree.addTreeAttributes(arena, io, db, &write_attrs, &wanted);
    rules.attrs = &write_attrs;

    try removeAll(io, wt, remove.items, &current, rules);
    var conv: convert.Session = .open(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = rules.core,
        .required_filters = rules.required_filters,
        .drivers = rules.filters,
    });
    defer conv.deinit(io);
    var stats: std.StringHashMapUnmanaged(fs.Stat) = .empty;
    for (rewrite.items) |path| {
        const want = wanted.get(path).?;
        const old = current.get(path) orelse null;
        const was_gitlink = old != null and old.?.mode == .gitlink;
        if (try fs.statAt(io, wt, path)) |found| {
            // A submodule's checkout stays, for the mover to move or, with
            // none, as git leaves it.
            if (found.kind == .directory and !(want.mode == .gitlink and was_gitlink)) try wt.deleteTree(io, path);
        }
        // Validate before `enter` consults a directory in the working tree.
        if (path_mod.checkEntry(path, .worktree, want.mode == .symlink, rules.protect) != null) return error.UnsafePath;
        try write_attrs.enter(io, wt, path);
        const written = try worktree.writeEntry(gpa, io, wt, .{ .db = db, .conv = &conv, .path = path, .mode = want.mode, .oid = want.oid, .rules = rules });
        try stats.put(arena, path, written.stat);
    }

    try install(arena, index, tree, &wanted, &current, &stats);
}

/// Every path the index has, at any stage, into `current`, `null` for a
/// conflicted one, which `conflicted` also names.
fn readCurrent(
    arena: Allocator,
    index: *const Index,
    current: *std.array_hash_map.String(?index_mod.Entry),
    conflicted: *std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
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
}

/// Make the index `tree`, keeping what it knew of paths it already had
/// right and the stat of every file just written.
fn install(
    arena: Allocator,
    index: *Index,
    tree: Oid,
    wanted: *const std.StringHashMapUnmanaged(worktree.TreeEntry),
    current: *const std.array_hash_map.String(?index_mod.Entry),
    stats: *const std.StringHashMapUnmanaged(fs.Stat),
) Error!void {
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
    // One entry for each path of the tree, at stage 0.
    assert(index.entries.items.len == wanted.count());
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
/// Remove `paths`, sorted, last first: a submodule as `rules.submodules`
/// takes it away, anything else as a file.
fn removeAll(io: Io, wt: Io.Dir, paths: []const []const u8, current: *const std.array_hash_map.String(?index_mod.Entry), rules: worktree.Rules) Error!void {
    var i = paths.len;
    while (i > 0) {
        i -= 1;
        const old = current.get(paths[i]).?;
        if (old != null and old.?.mode == .gitlink) {
            try worktree.removeGitlink(io, wt, paths[i], rules);
        } else {
            try worktree.removeEntry(io, wt, paths[i], rules.protect);
        }
    }
}

/// The paths whose index entry the reset changes, each to what `wanted`
/// has there, `null` for the ones it removes: what git checks a
/// submodule's move over. A path rewritten only because its file changed
/// is not one.
fn changedPaths(
    arena: Allocator,
    wanted: *const std.StringHashMapUnmanaged(worktree.TreeEntry),
    current: *const std.array_hash_map.String(?index_mod.Entry),
    remove: []const []const u8,
    rewrite: []const []const u8,
) Allocator.Error!std.array_hash_map.String(?worktree.TreeEntry) {
    var updates: std.array_hash_map.String(?worktree.TreeEntry) = .empty;
    for (remove) |path| try updates.put(arena, path, null);
    for (rewrite) |path| {
        const want = wanted.get(path).?;
        if (current.get(path)) |maybe| {
            if (maybe) |old| {
                if (old.mode == want.mode and old.oid.eql(want.oid)) continue;
            }
        }
        try updates.put(arena, path, want);
    }
    return updates;
}

/// Whether `entry`'s file is missing from the working tree. A gitlink's
/// directory is the submodule's to have or not.
fn gone(io: Io, wt: Io.Dir, entry: index_mod.Entry) Error!bool {
    if (entry.mode == .gitlink) return false;
    return try fs.statAt(io, wt, entry.path) == null;
}

fn differs(gpa: Allocator, io: Io, wt: Io.Dir, index: *const Index, entry: index_mod.Entry, rules: worktree.Rules) Error!bool {
    return worktree.differsFromIndex(gpa, io, wt, .{ .index = index, .entry = entry }, rules);
}

test "reset writes through the target tree's attributes as git reset hard does" {
    const testgit = git_mod;
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
    try toTree(gpa, io, &repo, .{ .index = &idx, .tree = tree, .mode = .hard, .blocked = null });
    const actual = try fixture.dir.readFileAlloc(io, "file", gpa, .limited(100));
    defer gpa.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}
