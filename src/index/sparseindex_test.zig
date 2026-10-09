const std = @import("std");
const sparseindex_mod = @import("sparseindex.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("index.zig");
const sparse = @import("../patterns.zig").sparse;
const testgit = @import("../testing/git.zig");

fn requireSparseIndexGit(gpa: Allocator, io: Io) !void {
    // `--sparse-index` arrived in 2.32; the collapse and expansion rules
    // compared here are the current release's.
    try testgit.requireGitVersion(gpa, io, 2, 45);
}

fn setupTree(io: Io, repo: *testgit.Repo) anyerror!void {
    for ([_][]const u8{
        "top.txt",   "A/a.txt",   "A/B/b.txt",   "A/B/C/c.txt", "A/X/x.txt",
        "D/d.txt",   "D/E/e.txt", "D/E/F/f.txt", "bb/y.txt",    "c/z.txt",
        "a.b/w.txt",
    }) |path| try repo.writeFile(io, path, path);
    try repo.exec(io, &.{ "add", "-A" });
    // A gitlink in a directory the cone leaves out, which keeps that one
    // directory from collapsing.
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000," ++ @as([40]u8, @splat('1')) ++ ",G/sub" });
    try repo.writeFile(io, "G/g.txt", "g\n");
    try repo.exec(io, &.{ "add", "G/g.txt" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
}

fn readIndexBytes(io: Io, repo: *testgit.Repo) ![]u8 {
    return repo.readFile(io, ".git/index");
}

fn expectSameEntries(want: *const index_mod.Index, got: *const index_mod.Index) !void {
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
fn expectSameNode(want: *const index_mod.CacheTreeNode, got: *const index_mod.CacheTreeNode) !void {
    try std.testing.expectEqualStrings(want.name, got.name);
    try std.testing.expectEqual(want.entry_count, got.entry_count);
    try std.testing.expectEqual(want.oid == null, got.oid == null);
    if (want.oid) |oid| try std.testing.expect(oid.eql(got.oid.?));
    try std.testing.expectEqual(want.children.items.len, got.children.items.len);
    for (want.children.items, got.children.items) |*a, *b| try expectSameNode(a, b);
}

fn expectSameTree(gpa: Allocator, want: *index_mod.Index, got: *index_mod.Index) !void {
    _ = gpa;
    try expectSameNode(&want.cache_tree.?.root, &got.cache_tree.?.root);
}

test "an index git wrote sparse is read and written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try setupTree(io, &repo);
    try repo.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });

    const bytes = try readIndexBytes(io, &repo);
    defer gpa.free(bytes);
    var index = try index_mod.Index.parse(gpa, .sha1, bytes);
    defer index.deinit();
    try std.testing.expect(index.sparse);
    try std.testing.expect(index.find("D/").?.isSparseDirectory());
    try std.testing.expect(index.find("A/X/").?.isSparseDirectory());
    try std.testing.expect(index.find("A/B/b.txt") != null);
    // The gitlink keeps its directory expanded.
    try std.testing.expect(index.find("G/sub") != null);
    try std.testing.expect(sparseindex_mod.containing(&index, "D/E/e.txt") != null);
    try std.testing.expect(sparseindex_mod.containing(&index, "A/B/b.txt") == null);

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
    try setupTree(io, &repo);
    try repo.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });
    const sparse_bytes = try readIndexBytes(io, &repo);
    defer gpa.free(sparse_bytes);
    try repo.exec(io, &.{ "sparse-checkout", "reapply", "--no-sparse-index" });
    const full_bytes = try readIndexBytes(io, &repo);
    defer gpa.free(full_bytes);

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var patterns = (try sparse.Patterns.load(gpa, io, git_dir, .{ .cone = true })).?;
    defer patterns.deinit();

    var git_sparse = try index_mod.Index.parse(gpa, .sha1, sparse_bytes);
    defer git_sparse.deinit();
    var git_full = try index_mod.Index.parse(gpa, .sha1, full_bytes);
    defer git_full.deinit();
    try std.testing.expect(!git_full.sparse);

    // Expanded here, from git's sparse index: git's full one.
    var expanded = try index_mod.Index.parse(gpa, .sha1, sparse_bytes);
    defer expanded.deinit();
    try sparseindex_mod.expand(gpa, io, &expanded, &db, null);
    try expectSameEntries(&git_full, &expanded);
    try expectSameTree(gpa, &git_full, &expanded);

    // Collapsed here, from git's full index: git's sparse one.
    var collapsed = try index_mod.Index.parse(gpa, .sha1, full_bytes);
    defer collapsed.deinit();
    try std.testing.expect(try sparseindex_mod.collapse(gpa, io, &collapsed, &db, &patterns));
    try expectSameEntries(&git_sparse, &collapsed);
    try expectSameTree(gpa, &git_sparse, &collapsed);

    // Expanding only as far as the cone reaches changes nothing that the
    // cone still leaves out.
    var partial = try index_mod.Index.parse(gpa, .sha1, sparse_bytes);
    defer partial.deinit();
    try sparseindex_mod.expand(gpa, io, &partial, &db, &patterns);
    try expectSameEntries(&git_sparse, &partial);
}

test "patterns that are not a cone, or an unmerged entry, leave the index full" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireSparseIndexGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try setupTree(io, &repo);
    try repo.exec(io, &.{ "sparse-checkout", "set", "--no-cone", "/A/" });

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", .{ .git_dir = git_dir, .kind = .sha1 });
    defer index.deinit();

    var plain = try sparse.Patterns.fromText(gpa, "/A/\n", .{});
    defer plain.deinit();
    try std.testing.expect(!try sparseindex_mod.collapse(gpa, io, &index, &db, &plain));
    try std.testing.expect(!index.sparse);

    var cone = try sparse.Patterns.fromText(gpa, "/*\n!/*/\n/A/\n", .{ .cone = true });
    defer cone.deinit();
    const conflicted = index.entries.items[0];
    try index.add(.{ .path = conflicted.path, .oid = conflicted.oid, .mode = conflicted.mode, .stage = 2 });
    try std.testing.expect(!try sparseindex_mod.collapse(gpa, io, &index, &db, &cone));
    try std.testing.expect(!sparseindex_mod.hasSparseDirectories(&index));
}

const worktree = @import("../checkout.zig");
const repo_mod = @import("../repo/repo.zig");

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

fn relicStatus(gpa: Allocator, io: Io, repo: *repo_mod.Repository, index: *index_mod.Index) ![]u8 {
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    var status = try worktree.status(gpa, io, repo.workDirectory().?, .{ .index = index, .db = repo.objectDatabase() }, .{
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
    try setupTree(io, &git);
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
    const bytes = try readIndexBytes(io, &git);
    defer gpa.free(bytes);
    var index = try index_mod.Index.parse(gpa, .sha1, bytes);
    defer index.deinit();
    try std.testing.expect(index.sparse);
    var full = try index_mod.Index.parse(gpa, .sha1, bytes);
    defer full.deinit();
    try sparseindex_mod.expand(gpa, io, &full, repo.objectDatabase(), null);

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
    const tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(git_tree, tree.hex(&hex));
    try std.testing.expect((try worktree.writeTree(gpa, io, &full, repo.objectDatabase())).eql(tree));

    // Staging everything expands only the directory that is on the disk,
    // and stages what a full index would.
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    _ = try worktree.addAll(gpa, io, git.dir, .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
    _ = try worktree.addAll(gpa, io, git.dir, .{ .index = &full, .db = repo.objectDatabase() }, .{ .rules = rules });
    try std.testing.expect(index.sparse);
    try std.testing.expect(index.find("D/E/stray.txt") != null);
    try std.testing.expect(index.find("A/X/") != null);
    const staged_bytes = try index.toBytes(.{});
    defer gpa.free(staged_bytes);
    var widened = try index_mod.Index.parse(gpa, .sha1, staged_bytes);
    defer widened.deinit();
    try sparseindex_mod.expand(gpa, io, &widened, repo.objectDatabase(), null);
    try expectSameEntries(&full, &widened);

    try repo.writeIndex(io, &index);
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
    try setupTree(io, &git);
    try git.exec(io, &.{ "sparse-checkout", "set", "--sparse-index", "A/B" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head = (try repo.headTree(io)).?;

    var sparse_index = try repo.openIndex(io);
    defer sparse_index.deinit();
    var full = try repo.openIndex(io);
    defer full.deinit();
    try sparseindex_mod.expand(gpa, io, &full, repo.objectDatabase(), null);

    _ = try worktree.resetIndex(gpa, io, &sparse_index, repo.objectDatabase(), head);
    _ = try worktree.resetIndex(gpa, io, &full, repo.objectDatabase(), head);
    try std.testing.expect(!sparse_index.sparse);
    try expectSameEntries(&full, &sparse_index);

    // A checkout writes every path, so it leaves a full index and every
    // file on the disk, which git calls clean.
    var checked_out = try repo.openIndex(io);
    defer checked_out.deinit();
    // Every path written, as `read-tree --reset -u` writes them.
    _ = try worktree.checkout(gpa, io, git.dir, .{ .index = &checked_out, .db = repo.objectDatabase(), .tree = head }, .{ .force = true });
    try std.testing.expect(!checked_out.sparse and !sparseindex_mod.hasSparseDirectories(&checked_out));
    try git.dir.access(io, "D/E/F/f.txt", .{});
    try checked_out.write(io, repo.gitDirectory(), "index", .{});
    try git.exec(io, &.{ "sparse-checkout", "disable" });
    const status = try git.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);
}
