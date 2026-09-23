//! The sparse index: a directory the sparse cone leaves out, standing in
//! the index as one entry instead of one per file under it.
//!
//! A repository with a large tree and a narrow cone has most of its index
//! in directories nobody will check out, and every operation that walks the
//! index pays for them. git's answer is to collapse each such directory
//! into a single entry -- the path with a trailing `/`, mode `040000`, the
//! tree's object name, `skip-worktree` set -- and to mark the index with the
//! empty `sdir` extension so an older reader refuses it rather than
//! misreading it. Only cone mode allows it, because only a cone says of a
//! whole directory, without looking at the files in it, that it is out.
//!
//! The two moves here are git's own: `collapse` is `convert_to_sparse`, and
//! `expand` is `expand_index`, which with no patterns is
//! `ensure_full_index`. A collapse that cannot be done -- patterns that are
//! not a cone, an unmerged entry -- leaves the index full, which is always a
//! correct index. Both rebuild the cache tree afterwards, as git does, since
//! the entries it counts have changed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const sparse = @import("sparse.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Entry = index_mod.Entry;
const Odb = odb_mod.Odb;

/// Errors from expanding or collapsing.
pub const Error = error{
    /// A sparse directory names something that is not a tree.
    NotATree,
    /// Trees nested deeper than a walk will follow.
    TreeTooDeep,
} || Allocator.Error || odb_mod.Error || index_mod.ReadError ||
    object.TreeParseError || object.Tree.Builder.AddError;

/// How deep an expansion follows trees.
const max_depth: u32 = 256;

/// Whether the index holds any sparse directory entry.
pub fn hasSparseDirectories(index: *const Index) bool {
    for (index.entries.items) |entry| {
        if (entry.isSparseDirectory()) return true;
    }
    return false;
}

/// The sparse directory entry `path` lies under, or `null`. `path` is a
/// file's path; a sparse directory is found by its own name with the
/// trailing slash.
pub fn containing(index: *const Index, path: []const u8) ?*Entry {
    var end = path.len;
    while (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |slash| {
        end = slash;
        // A sparse directory's path is the directory with its slash.
        if (index.find(path[0 .. end + 1])) |entry| {
            if (entry.isSparseDirectory()) return entry;
        }
    }
    return null;
}

/// Replace sparse directory entries with the files under them.
///
/// With `patterns` `null`, or patterns that are not a cone, every one is
/// expanded and the index is full afterwards: git's `ensure_full_index`.
/// With a cone, only what the cone reaches into is expanded, and a
/// directory under it that the cone still leaves out stays one entry: git's
/// `expand_index`, which is what a change of patterns does first.
///
/// Every file that comes out of a sparse directory has `skip-worktree` set
/// and no stat, since none of them is in the working tree.
pub fn expand(gpa: Allocator, io: Io, index: *Index, db: *Odb, patterns: ?*const sparse.Patterns) Error!void {
    if (!index.sparse and !hasSparseDirectories(index)) return;
    const cone: ?*const sparse.Cone = if (patterns) |p| (if (p.cone) |*c| c else null) else null;
    return expandSelected(gpa, io, index, db, cone, null);
}

/// Expand the sparse directories that are on the disk after all, and no
/// others.
///
/// A directory the cone leaves out is not normally there. When it is --
/// someone made it, or a tool wrote into it -- what is in it is either a
/// file the index holds or a new one, and to tell which, and to stage a new
/// one, the index needs its entries rather than the one that stands for
/// them. The rest of the index stays as sparse as it was.
pub fn expandPresent(gpa: Allocator, io: Io, wt: Io.Dir, index: *Index, db: *Odb) (Error || fs.StatError)!void {
    var present: std.StringHashMapUnmanaged(void) = .empty;
    defer present.deinit(gpa);
    for (index.entries.items) |entry| {
        if (!entry.isSparseDirectory()) continue;
        const found = (try fs.statAt(io, wt, entry.path[0 .. entry.path.len - 1])) orelse continue;
        if (found.kind != .directory) continue;
        try present.put(gpa, entry.path, {});
    }
    if (present.count() == 0) return;
    return expandSelected(gpa, io, index, db, null, &present);
}

/// Expand the sparse directories named in `only`, or every one the cone
/// reaches into when `only` is `null`.
fn expandSelected(
    gpa: Allocator,
    io: Io,
    index: *Index,
    db: *Odb,
    cone: ?*const sparse.Cone,
    only: ?*const std.StringHashMapUnmanaged(void),
) Error!void {
    var out: std.ArrayList(Entry) = .empty;
    defer {
        for (out.items) |e| gpa.free(e.path);
        out.deinit(gpa);
    }
    try out.ensureTotalCapacity(gpa, index.entries.items.len);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);

    for (index.entries.items) |entry| {
        const keep = !entry.isSparseDirectory() or
            (cone != null and cone.?.match(entry.path[0 .. entry.path.len - 1], true) == .outside) or
            (only != null and !only.?.contains(entry.path));
        if (keep) {
            var copy = entry;
            copy.path = try gpa.dupe(u8, entry.path);
            out.append(gpa, copy) catch |err| {
                gpa.free(copy.path);
                return err;
            };
            continue;
        }
        path_buf.clearRetainingCapacity();
        try path_buf.appendSlice(gpa, entry.path);
        try expandTree(gpa, io, db, cone, entry.oid, &path_buf, &out, 0);
    }

    // The new entries take the old ones' place; the old paths go.
    for (index.entries.items) |e| gpa.free(e.path);
    index.entries.clearRetainingCapacity();
    try index.entries.appendSlice(gpa, out.items);
    out.clearRetainingCapacity();

    index.sparse = hasSparseDirectories(index);
    try rebuildCacheTree(io, index, db);
}

/// Append the files of the tree `oid` under `base`, which ends in `/`, in
/// index order -- which is tree order, since both put a directory where its
/// name with a slash would sort.
fn expandTree(
    gpa: Allocator,
    io: Io,
    db: *Odb,
    cone: ?*const sparse.Cone,
    oid: Oid,
    base: *std.ArrayList(u8),
    out: *std.ArrayList(Entry),
    depth: u32,
) Error!void {
    if (depth > max_depth) return error.TreeTooDeep;
    const found = try db.read(io, oid);
    defer db.gpa.free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const tree: object.Tree = .parse(db.kind, found.bytes);
    var it = tree.iterate();
    const base_len = base.items.len;
    while (try it.next()) |item| {
        base.shrinkRetainingCapacity(base_len);
        try base.appendSlice(gpa, item.name);
        if (item.mode == .tree) {
            // A directory the cone still leaves out stays collapsed.
            if (cone) |c| {
                if (c.match(base.items, true) == .outside) {
                    try base.append(gpa, '/');
                    try appendEntry(gpa, out, base.items, .tree, item.oid);
                    continue;
                }
            }
            try base.append(gpa, '/');
            try expandTree(gpa, io, db, cone, item.oid, base, out, depth + 1);
            continue;
        }
        try appendEntry(gpa, out, base.items, item.mode, item.oid);
    }
    base.shrinkRetainingCapacity(base_len);
}

fn appendEntry(gpa: Allocator, out: *std.ArrayList(Entry), path: []const u8, mode: object.Mode, oid: Oid) Allocator.Error!void {
    const owned = try gpa.dupe(u8, path);
    out.append(gpa, .{
        .path = owned,
        .oid = oid,
        .mode = mode,
        .skip_worktree = true,
    }) catch |err| {
        gpa.free(owned);
        return err;
    };
}

/// Collapse every directory the cone leaves out, whose entries are all
/// merged, all `skip-worktree` and none a gitlink, into one sparse
/// directory entry. Returns whether the index is sparse afterwards.
///
/// Patterns that are not a cone, or an index with an unmerged entry, leave
/// the index as it is and return false, which is git's rule: a full index
/// is never wrong, so a collapse that cannot be proven safe is not made.
/// The directories of the cone itself, and the root, are never collapsed.
pub fn collapse(gpa: Allocator, io: Io, index: *Index, db: *Odb, patterns: *const sparse.Patterns) Error!bool {
    const cone = if (patterns.cone) |*c| c else return false;
    if (index.entries.items.len == 0) return false;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return false;
    }

    // The walk is over the cache tree, so it has to describe these entries.
    // git verifies it and rebuilds it when it does not; rebuilding it is
    // the same answer without the second pass.
    try rebuildCacheTree(io, index, db);
    const tree = &index.cache_tree.?;

    var out: std.ArrayList(Entry) = .empty;
    defer {
        for (out.items) |e| gpa.free(e.path);
        out.deinit(gpa);
    }
    try out.ensureTotalCapacity(gpa, index.entries.items.len);
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(gpa);
    if (!try collapseNode(gpa, cone, &tree.root, index.entries.items, &prefix, &out)) return false;

    for (index.entries.items) |e| gpa.free(e.path);
    index.entries.clearRetainingCapacity();
    try index.entries.appendSlice(gpa, out.items);
    out.clearRetainingCapacity();

    index.sparse = true;
    try rebuildCacheTree(io, index, db);
    return true;
}

/// git's `convert_to_sparse_rec` over one cache-tree node, whose entries
/// are `entries` and whose path is `prefix` (empty at the root, ending in
/// `/` below it). False when the cache tree does not describe the entries,
/// which leaves the index to stay full.
fn collapseNode(
    gpa: Allocator,
    cone: *const sparse.Cone,
    node: *const index_mod.CacheTree.Node,
    entries: []const Entry,
    prefix: *std.ArrayList(u8),
    out: *std.ArrayList(Entry),
) Error!bool {
    if (prefix.items.len != 0 and cone.match(prefix.items[0 .. prefix.items.len - 1], true) == .outside) {
        var convertible = node.oid != null;
        for (entries) |entry| {
            if (entry.stage != 0 or entry.mode == .gitlink or !entry.skip_worktree) {
                convertible = false;
                break;
            }
        }
        if (convertible) {
            try appendEntry(gpa, out, prefix.items, .tree, node.oid.?);
            return true;
        }
    }

    const base_len = prefix.items.len;
    var i: usize = 0;
    while (i < entries.len) {
        const entry = entries[i];
        const rest = entry.path[base_len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        // A file of this directory. A sparse directory below it has a
        // slash and is taken with the node it names; one that is this
        // directory itself, which only a cone that has since widened can
        // leave, has none and is kept as it is.
        if (slash == rest.len) {
            var copy = entry;
            copy.path = try gpa.dupe(u8, entry.path);
            out.append(gpa, copy) catch |err| {
                gpa.free(copy.path);
                return err;
            };
            i += 1;
            continue;
        }
        const name = rest[0..slash];
        const child = findChild(node, name) orelse return false;
        const span = std.math.cast(usize, child.entry_count) orelse return false;
        if (span == 0 or i + span > entries.len) return false;
        try prefix.appendSlice(gpa, entry.path[base_len..][0 .. slash + 1]);
        const ok = try collapseNode(gpa, cone, child, entries[i..][0..span], prefix, out);
        prefix.shrinkRetainingCapacity(base_len);
        if (!ok) return false;
        i += span;
    }
    return true;
}

fn findChild(node: *const index_mod.CacheTree.Node, name: []const u8) ?*const index_mod.CacheTree.Node {
    for (node.children.items) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Throw the cache tree away and compute it again over the entries, which
/// is what git does after either move. An index with an unmerged entry has
/// no tree to compute, and is left with an invalid one.
fn rebuildCacheTree(io: Io, index: *Index, db: *Odb) Error!void {
    const tree = try index.cacheTree();
    tree.invalidateAll();
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return;
    }
    _ = try tree.rebuild(io, index.entries.items, db);
}

//=========================================================================
// Tests
//
// git writes a sparse index when a cone-mode sparse checkout has
// `index.sparse` set, and a full one when it has not; the two are the
// fixtures here. What is compared is every entry's path, mode, object
// name, stage and flags, and the `TREE` extension byte for byte. A stat
// is not compared where git may have refreshed it and this has not.
//=========================================================================

const testgit = @import("testgit.zig");

fn requireSparseIndexGit(gpa: Allocator, io: Io) !void {
    // `--sparse-index` arrived in 2.32; the collapse and expansion rules
    // compared here are the current release's.
    try testgit.requireGitVersion(gpa, io, 2, 45);
}

fn setupTree(repo: *testgit.Repo, io: Io) anyerror!void {
    for ([_][]const u8{
        "top.txt",   "A/a.txt",   "A/B/b.txt",   "A/B/C/c.txt", "A/X/x.txt",
        "D/d.txt",   "D/E/e.txt", "D/E/F/f.txt", "bb/y.txt",    "c/z.txt",
        "a.b/w.txt",
    }) |path| try repo.writeFile(io, path, path);
    try repo.exec(io, &.{ "add", "-A" });
    // A gitlink in a directory the cone leaves out, which keeps that one
    // directory from collapsing.
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000," ++ "1" ** 40 ++ ",G/sub" });
    try repo.writeFile(io, "G/g.txt", "g\n");
    try repo.exec(io, &.{ "add", "G/g.txt" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
}

fn readIndexBytes(repo: *testgit.Repo, io: Io) ![]u8 {
    return repo.readFile(io, ".git/index");
}

fn expectSameEntries(want: *const Index, got: *const Index) !void {
    try std.testing.expectEqual(want.entries.items.len, got.entries.items.len);
    for (want.entries.items, got.entries.items) |a, b| {
        errdefer std.debug.print("at {s}\n", .{a.path});
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expect(a.oid.eql(b.oid));
        try std.testing.expectEqual(a.mode, b.mode);
        try std.testing.expectEqual(a.stage, b.stage);
        try std.testing.expectEqual(a.skip_worktree, b.skip_worktree);
        try std.testing.expectEqual(a.intent_to_add, b.intent_to_add);
        if (a.skip_worktree) try std.testing.expectEqual(a.stat, b.stat);
    }
    try std.testing.expectEqual(want.sparse, got.sparse);
}

/// The two cache trees node for node: name, count, object name, and the
/// children in the order the extension holds them, which is what makes the
/// extension's bytes the same.
fn expectSameNode(want: *const index_mod.CacheTree.Node, got: *const index_mod.CacheTree.Node) !void {
    try std.testing.expectEqualStrings(want.name, got.name);
    try std.testing.expectEqual(want.entry_count, got.entry_count);
    try std.testing.expectEqual(want.oid == null, got.oid == null);
    if (want.oid) |oid| try std.testing.expect(oid.eql(got.oid.?));
    try std.testing.expectEqual(want.children.items.len, got.children.items.len);
    for (want.children.items, got.children.items) |*a, *b| try expectSameNode(a, b);
}

fn expectSameTree(gpa: Allocator, want: *Index, got: *Index) !void {
    _ = gpa;
    try expectSameNode(&want.cache_tree.?.root, &got.cache_tree.?.root);
}

test "an index git wrote sparse is read and written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try setupTree(&repo, io);
    try repo.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });

    const bytes = try readIndexBytes(&repo, io);
    defer gpa.free(bytes);
    var index = try Index.parse(gpa, .sha1, bytes);
    defer index.deinit();
    try std.testing.expect(index.sparse);
    try std.testing.expect(index.find("D/").?.isSparseDirectory());
    try std.testing.expect(index.find("A/X/").?.isSparseDirectory());
    try std.testing.expect(index.find("A/B/b.txt") != null);
    // The gitlink keeps its directory expanded.
    try std.testing.expect(index.find("G/sub") != null);
    try std.testing.expect(containing(&index, "D/E/e.txt") != null);
    try std.testing.expect(containing(&index, "A/B/b.txt") == null);

    const again = try index.toBytes(.{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
}

test "expanding is what git's ensure_full_index writes, and collapsing is what it collapses" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try setupTree(&repo, io);
    try repo.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });
    const sparse_bytes = try readIndexBytes(&repo, io);
    defer gpa.free(sparse_bytes);
    try repo.exec(io, &.{ "sparse-checkout", "reapply", "--no-sparse-index" });
    const full_bytes = try readIndexBytes(&repo, io);
    defer gpa.free(full_bytes);

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var patterns = (try sparse.Patterns.loadMode(gpa, io, git_dir, .{ .cone = true })).?;
    defer patterns.deinit();

    var git_sparse = try Index.parse(gpa, .sha1, sparse_bytes);
    defer git_sparse.deinit();
    var git_full = try Index.parse(gpa, .sha1, full_bytes);
    defer git_full.deinit();
    try std.testing.expect(!git_full.sparse);

    // Expanded here, from git's sparse index: git's full one.
    var expanded = try Index.parse(gpa, .sha1, sparse_bytes);
    defer expanded.deinit();
    try expand(gpa, io, &expanded, &db, null);
    try expectSameEntries(&git_full, &expanded);
    try expectSameTree(gpa, &git_full, &expanded);

    // Collapsed here, from git's full index: git's sparse one.
    var collapsed = try Index.parse(gpa, .sha1, full_bytes);
    defer collapsed.deinit();
    try std.testing.expect(try collapse(gpa, io, &collapsed, &db, &patterns));
    try expectSameEntries(&git_sparse, &collapsed);
    try expectSameTree(gpa, &git_sparse, &collapsed);

    // Expanding only as far as the cone reaches changes nothing that the
    // cone still leaves out.
    var partial = try Index.parse(gpa, .sha1, sparse_bytes);
    defer partial.deinit();
    try expand(gpa, io, &partial, &db, &patterns);
    try expectSameEntries(&git_sparse, &partial);
}

test "patterns that are not a cone, or an unmerged entry, leave the index full" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try setupTree(&repo, io);
    try repo.exec(io, &.{ "sparse-checkout", "set", "--no-cone", "/A/" });

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var index = try Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();

    var plain = try sparse.Patterns.fromText(gpa, "/A/\n", .{});
    defer plain.deinit();
    try std.testing.expect(!try collapse(gpa, io, &index, &db, &plain));
    try std.testing.expect(!index.sparse);

    var cone = try sparse.Patterns.fromText(gpa, "/*\n!/*/\n/A/\n", .{ .cone = true });
    defer cone.deinit();
    const conflicted = index.entries.items[0];
    try index.add(.{ .path = conflicted.path, .oid = conflicted.oid, .mode = conflicted.mode, .stage = 2 });
    try std.testing.expect(!try collapse(gpa, io, &index, &db, &cone));
    try std.testing.expect(!hasSparseDirectories(&index));
}

const worktree = @import("worktree.zig");
const repo_mod = @import("repo.zig");

/// `git status --porcelain` as text, from a status: changes first, then
/// untracked paths, each sorted, which is git's order.
fn porcelain(gpa: Allocator, status: *const worktree.Status) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_]bool{ false, true }) |untracked_pass| {
        for (status.entries) |entry| {
            const untracked = entry.unstaged == .untracked;
            if (untracked != untracked_pass) continue;
            if (untracked) {
                try out.print(gpa, "?? {s}\n", .{entry.path});
                continue;
            }
            try out.print(gpa, "{c}{c} {s}\n", .{ code(entry.staged), code(entry.unstaged), entry.path });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn code(change: worktree.Change) u8 {
    return switch (change) {
        .unmodified => ' ',
        .added => 'A',
        .modified => 'M',
        .deleted => 'D',
        .type_changed => 'T',
        .untracked => '?',
        .ignored => '!',
    };
}

fn relicStatus(gpa: Allocator, io: Io, repo: *repo_mod.Repository, index: *Index) ![]u8 {
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = repo.worktreeRules();
    rules.ignore = &ignore_rules;
    var status = try worktree.status(gpa, io, repo.work_dir.?, index, &repo.odb, .{
        .rules = rules,
        .head_tree = try repo.headTree(io),
    });
    defer status.deinit();
    return porcelain(gpa, &status);
}

test "status, write-tree and add on a sparse index say what they say on the full one, and git agrees" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setupTree(&git, io);
    // A second commit changes a file the cone will leave out, and the
    // branch is then moved back without touching the index: HEAD and the
    // index differ inside a sparse directory.
    try git.writeFile(io, "D/E/e.txt", "changed outside the cone\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    try git.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });
    try git.exec(io, &.{ "reset", "-q", "--soft", "HEAD~1" });
    try git.writeFile(io, "A/B/b.txt", "changed in the cone\n");
    try git.writeFile(io, "A/B/new.txt", "untracked in the cone\n");
    // A sparse directory that is on the disk after all.
    try git.writeFile(io, "D/d.txt", "D/d.txt");
    try git.writeFile(io, "D/E/stray.txt", "untracked where the cone does not reach\n");

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    // Both indexes come from the same bytes: git's status is free to
    // rewrite the file, and does, when it finds files on the disk that the
    // index says are not there.
    const bytes = try readIndexBytes(&git, io);
    defer gpa.free(bytes);
    var index = try Index.parse(gpa, .sha1, bytes);
    defer index.deinit();
    try std.testing.expect(index.sparse);
    var full = try Index.parse(gpa, .sha1, bytes);
    defer full.deinit();
    try expand(gpa, io, &full, &repo.odb, null);

    const expected = try git.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(expected);
    const on_sparse = try relicStatus(gpa, io, &repo, &index);
    defer gpa.free(on_sparse);
    try std.testing.expectEqualStrings(expected, on_sparse);

    const on_full = try relicStatus(gpa, io, &repo, &full);
    defer gpa.free(on_full);
    try std.testing.expectEqualStrings(expected, on_full);

    // The tree the sparse index describes is the one git writes.
    const git_tree = try git.line(io, &.{"write-tree"});
    defer gpa.free(git_tree);
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(git_tree, tree.hex(&hex));
    try std.testing.expect((try worktree.writeTree(gpa, io, &full, &repo.odb)).eql(tree));

    // Staging everything expands only the directory that is on the disk,
    // and stages what a full index would.
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = repo.worktreeRules();
    rules.ignore = &ignore_rules;
    _ = try worktree.addAll(gpa, io, git.dir, &index, &repo.odb, .{ .rules = rules });
    _ = try worktree.addAll(gpa, io, git.dir, &full, &repo.odb, .{ .rules = rules });
    try std.testing.expect(index.sparse);
    try std.testing.expect(index.find("D/E/stray.txt") != null);
    try std.testing.expect(index.find("A/X/") != null);
    const staged_bytes = try index.toBytes(.{});
    defer gpa.free(staged_bytes);
    var widened = try Index.parse(gpa, .sha1, staged_bytes);
    defer widened.deinit();
    try expand(gpa, io, &widened, &repo.odb, null);
    try expectSameEntries(&full, &widened);

    try index.write(io, repo.git_dir, "index", .{});
    try git.exec(io, &.{ "fsck", "--no-progress" });
    const after = try git.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(after);
    const ours = try relicStatus(gpa, io, &repo, &index);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(after, ours);
}

test "checkout and reset on a sparse index leave what they leave on the full one" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setupTree(&git, io);
    try git.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head = (try repo.headTree(io)).?;

    var sparse_index = try repo.openIndex(io);
    defer sparse_index.deinit();
    var full = try repo.openIndex(io);
    defer full.deinit();
    try expand(gpa, io, &full, &repo.odb, null);

    _ = try worktree.resetIndex(gpa, io, &sparse_index, &repo.odb, head);
    _ = try worktree.resetIndex(gpa, io, &full, &repo.odb, head);
    try std.testing.expect(!sparse_index.sparse);
    try expectSameEntries(&full, &sparse_index);

    // A checkout writes every path, so it leaves a full index and every
    // file on the disk, which git calls clean.
    var checked_out = try repo.openIndex(io);
    defer checked_out.deinit();
    _ = try worktree.checkout(gpa, io, git.dir, &checked_out, &repo.odb, head, .{});
    try std.testing.expect(!checked_out.sparse and !hasSparseDirectories(&checked_out));
    try git.dir.access(io, "D/E/F/f.txt", .{});
    try checked_out.write(io, repo.git_dir, "index", .{});
    try git.exec(io, &.{ "sparse-checkout", "disable" });
    const status = try git.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);
}
