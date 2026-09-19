//! The working tree against the real git: the same bytes in, the same tree
//! out, and a working tree git calls clean.

const std = @import("std");
const Io = std.Io;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const worktree = @import("worktree.zig");
const ignore = @import("ignore.zig");
const attributes = @import("attributes.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;

const Harness = struct {
    repo: testgit.Repo,
    git_dir: Io.Dir,
    db: odb_mod.Odb,
    index: index_mod.Index,
    rules: ignore.Rules,
    attrs: attributes.Attrs,

    fn init(gpa: std.mem.Allocator, io: Io, extra: []const []const u8) !Harness {
        var repo = try testgit.Repo.init(gpa, io, extra);
        errdefer repo.deinit();
        const git_dir = try repo.gitDir(io);
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
        errdefer db.deinit(io);
        const index = index_mod.Index.initEmpty(gpa, .sha1);
        return .{
            .repo = repo,
            .git_dir = git_dir,
            .db = db,
            .index = index,
            .rules = try ignore.Rules.init(gpa, false),
            .attrs = try attributes.Attrs.init(gpa, false),
        };
    }

    fn deinit(h: *Harness, io: Io) void {
        h.attrs.deinit();
        h.rules.deinit();
        h.index.deinit();
        h.db.deinit(io);
        h.git_dir.close(io);
        h.repo.deinit();
    }

    fn reload(h: *Harness, gpa: std.mem.Allocator, io: Io) !void {
        h.index.deinit();
        h.index = try index_mod.Index.read(gpa, io, h.git_dir, "index", h.git_dir, .sha1);
    }

    fn worktreeRules(h: *Harness) worktree.Rules {
        return .{ .ignore = &h.rules, .attrs = &h.attrs };
    }
};

test "addAll then writeTree equals git add -A and git write-tree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    // A shape with nesting, an executable, a symlink and names that test
    // git's tree sort rule.
    try h.repo.writeFile(io, "a.c", "int main(void) { return 0; }\n");
    try h.repo.writeFile(io, "a/b.c", "nested\n");
    try h.repo.writeFile(io, "a0", "after the tree\n");
    try h.repo.writeFile(io, "deep/one/two/three.txt", "deep\n");
    try h.repo.writeFile(io, "run.sh", "#!/bin/sh\necho hi\n");
    try h.repo.dir.setFilePermissions(io, "run.sh", @enumFromInt(@as(std.posix.mode_t, 0o755)), .{});
    try h.repo.dir.symLink(io, "a.c", "link.c", .{});
    try h.repo.writeFile(io, ".gitignore", "*.log\n");
    try h.repo.writeFile(io, "skip.log", "ignored\n");

    const outcome = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{
        .rules = h.worktreeRules(),
    });
    try std.testing.expect(outcome.added >= 6);

    const tree = try worktree.writeTree(gpa, io, &h.index, &h.db);
    var hex: [hash.max_hex_len]u8 = undefined;
    const ours = try gpa.dupe(u8, tree.hex(&hex));
    defer gpa.free(ours);

    try h.repo.exec(io, &.{ "add", "-A" });
    const theirs = try h.repo.line(io, &.{"write-tree"});
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours);

    // The ignored file is in neither.
    const listed = try h.repo.run(io, &.{"ls-files"});
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "skip.log") == null);
    try std.testing.expect(h.index.find("skip.log") == null);
    try std.testing.expect(h.index.find("link.c").?.mode == .symlink);
    try std.testing.expect(h.index.find("run.sh").?.mode == .exec);

    // And git reads the index this wrote back to the same entries.
    try h.index.write(io, h.git_dir, "index", .{});
    const after = try h.repo.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(after);
    const before = try h.repo.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(before);
    try std.testing.expectEqualStrings(before, after);
    try h.repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}

test "the stat shortcut means a warm addAll hashes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    for (0..60) |i| {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "d{d}/f{d}.txt", .{ i % 6, i });
        try h.repo.writeFile(io, path, "contents\n");
    }

    const cold = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    try std.testing.expectEqual(@as(u32, 60), cold.added);
    try std.testing.expectEqual(@as(u32, 60), cold.hashed);

    // Write and read back, so the index has a real modification time and
    // the racy window has closed for files written before it.
    try h.index.write(io, h.git_dir, "index", .{});
    try h.reload(gpa, io);

    const warm = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    try std.testing.expectEqual(@as(u32, 0), warm.added);
    try std.testing.expectEqual(@as(u32, 0), warm.modified);
    try std.testing.expectEqual(@as(u32, 60), warm.unchanged);
    try std.testing.expectEqual(@as(u32, 0), warm.hashed);
}

test "the racy rule notices a file rewritten inside one second" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    // Same length, different content, written without waiting: the stat
    // alone cannot tell them apart.
    try h.repo.writeFile(io, "racy.txt", "AAAA\n");
    _ = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    try h.index.write(io, h.git_dir, "index", .{});
    try h.reload(gpa, io);

    const before = h.index.find("racy.txt").?.oid;
    try h.repo.writeFile(io, "racy.txt", "BBBB\n");

    const outcome = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    const after = h.index.find("racy.txt").?.oid;
    try std.testing.expect(!before.eql(after));
    try std.testing.expectEqual(@as(u32, 1), outcome.modified);

    const expected = hash.Hasher.object(.sha1, "blob", "BBBB\n");
    try std.testing.expect(after.eql(expected));
}

test "a deletion is staged and the cache tree stays true" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "keep.txt", "keep\n");
    try h.repo.writeFile(io, "dir/gone.txt", "gone\n");
    try h.repo.writeFile(io, "dir/stay.txt", "stay\n");
    _ = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    _ = try worktree.writeTree(gpa, io, &h.index, &h.db);

    try h.repo.dir.deleteFile(io, "dir/gone.txt");
    const outcome = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    try std.testing.expectEqual(@as(u32, 1), outcome.removed);
    try std.testing.expect(h.index.find("dir/gone.txt") == null);

    const ours = try worktree.writeTree(gpa, io, &h.index, &h.db);
    var hex: [hash.max_hex_len]u8 = undefined;
    const ours_text = try gpa.dupe(u8, ours.hex(&hex));
    defer gpa.free(ours_text);

    try h.repo.exec(io, &.{ "add", "-A" });
    const theirs = try h.repo.line(io, &.{"write-tree"});
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours_text);
}

test "checkout sets the tree and leaves untracked and ignored files alone" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "a.txt", "first\n");
    try h.repo.writeFile(io, "dir/b.txt", "second\n");
    try h.repo.writeFile(io, "gone.txt", "will go\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const first_tree_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(first_tree_text);
    const first_tree = try Oid.parse(.sha1, first_tree_text);

    try h.repo.writeFile(io, "a.txt", "second version\n");
    try h.repo.dir.deleteFile(io, "gone.txt");
    try h.repo.writeFile(io, "dir/c.txt", "new file\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "two" });

    // Things checkout must not touch.
    try h.repo.writeFile(io, "untracked.txt", "mine\n");
    try h.repo.writeFile(io, ".gitignore", "*.log\n");
    try h.repo.writeFile(io, "build.log", "noise\n");

    try h.reload(gpa, io);
    const outcome = try worktree.checkout(gpa, io, h.repo.dir, &h.index, &h.db, first_tree, .{
        .rules = h.worktreeRules(),
    });
    try std.testing.expect(outcome.written >= 2);
    try std.testing.expect(outcome.removed >= 1);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("first\n", try h.repo.dir.readFile(io, "a.txt", &buf));
    try std.testing.expectEqualStrings("will go\n", try h.repo.dir.readFile(io, "gone.txt", &buf));
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "dir/c.txt", .{}));
    try std.testing.expectEqualStrings("mine\n", try h.repo.dir.readFile(io, "untracked.txt", &buf));
    try std.testing.expectEqualStrings("noise\n", try h.repo.dir.readFile(io, "build.log", &buf));

    // The index this wrote describes exactly that tree, and git agrees.
    try h.index.write(io, h.git_dir, "index", .{});
    const written = try h.repo.line(io, &.{"write-tree"});
    defer gpa.free(written);
    try std.testing.expectEqualStrings(first_tree_text, written);

    // And git calls the working tree clean against that tree.
    try h.repo.exec(io, &.{ "reset", "-q", "--soft", "HEAD~1" });
    const porcelain = try h.repo.run(io, &.{ "status", "--porcelain", "--untracked-files=no" });
    defer gpa.free(porcelain);
    try std.testing.expectEqualStrings("", porcelain);
}

test "status agrees with git on every path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "unchanged.txt", "same\n");
    try h.repo.writeFile(io, "modified.txt", "before\n");
    try h.repo.writeFile(io, "deleted.txt", "gone\n");
    try h.repo.writeFile(io, "staged.txt", "staged\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "base" });

    try h.repo.writeFile(io, "modified.txt", "after\n");
    try h.repo.dir.deleteFile(io, "deleted.txt");
    try h.repo.writeFile(io, "staged.txt", "changed and staged\n");
    try h.repo.exec(io, &.{ "add", "staged.txt" });
    try h.repo.writeFile(io, "untracked.txt", "new\n");
    try h.repo.writeFile(io, ".gitignore", "*.log\n");
    try h.repo.writeFile(io, "noise.log", "ignored\n");
    try h.repo.exec(io, &.{ "add", ".gitignore" });

    try h.reload(gpa, io);
    try h.rules.addDirectory(io, h.repo.dir, "", 0);
    const head_tree_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(head_tree_text);

    var result = try worktree.status(gpa, io, h.repo.dir, &h.index, &h.db, .{
        .rules = h.worktreeRules(),
        .head_tree = try Oid.parse(.sha1, head_tree_text),
    });
    defer result.deinit();

    try std.testing.expectEqual(worktree.Change.unmodified, result.find("modified.txt").?.staged);
    try std.testing.expectEqual(worktree.Change.modified, result.find("modified.txt").?.unstaged);
    try std.testing.expectEqual(worktree.Change.deleted, result.find("deleted.txt").?.unstaged);
    try std.testing.expectEqual(worktree.Change.modified, result.find("staged.txt").?.staged);
    try std.testing.expectEqual(worktree.Change.unmodified, result.find("staged.txt").?.unstaged);
    try std.testing.expectEqual(worktree.Change.untracked, result.find("untracked.txt").?.unstaged);
    try std.testing.expectEqual(worktree.Change.added, result.find(".gitignore").?.staged);
    try std.testing.expect(result.find("unchanged.txt") == null);
    try std.testing.expect(result.find("noise.log") == null);
    try std.testing.expect(!result.isClean());

    // Every path git reports is a path this reports, and the other way
    // round.
    const porcelain = try h.repo.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(porcelain);
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    var counted: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = line[3..];
        try std.testing.expect(result.find(path) != null);
        counted += 1;
    }
    try std.testing.expectEqual(counted, result.entries.len);
}

test "list is the index's paths plus the untracked ones" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "tracked.txt", "a\n");
    try h.repo.writeFile(io, "dir/tracked.txt", "b\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.writeFile(io, "untracked.txt", "c\n");
    try h.repo.writeFile(io, ".gitignore", "*.log\n");
    try h.repo.writeFile(io, "x.log", "d\n");

    try h.reload(gpa, io);
    try h.rules.addDirectory(io, h.repo.dir, "", 0);

    var listing = try worktree.list(gpa, io, h.repo.dir, &h.index, h.worktreeRules());
    defer listing.deinit();

    const expected = try h.repo.run(io, &.{ "ls-files", "--cached", "--others", "--exclude-standard" });
    defer gpa.free(expected);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        var found = false;
        for (listing.paths) |ours| {
            if (std.mem.eql(u8, ours, path)) found = true;
        }
        if (!found) {
            std.debug.print("missing from list: {s}\n", .{path});
            return error.TestUnexpectedResult;
        }
        count += 1;
    }
    try std.testing.expectEqual(count, listing.paths.len);
}

test "core.autocrlf with text=auto stores the blob git stores" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    // The repository's own config decides, so the fixed settings must not
    // override it.
    repo.defaults = &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false" };
    try repo.exec(io, &.{ "config", "core.autocrlf", "true" });
    try repo.exec(io, &.{ "config", "core.safecrlf", "false" });

    try repo.writeFile(io, ".gitattributes", "* text=auto\n");
    try repo.writeFile(io, "crlf.txt", "one\r\ntwo\r\nthree\r\n");
    try repo.writeFile(io, "lf.txt", "one\ntwo\n");
    // A lone carriage return makes git's check-in rule call it binary.
    try repo.writeFile(io, "lone.bin", "one\rtwo\r\n");
    try repo.writeFile(io, "zero.bin", "a\x00b\r\n");

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var index = index_mod.Index.initEmpty(gpa, .sha1);
    defer index.deinit();
    var rules = try ignore.Rules.init(gpa, false);
    defer rules.deinit();
    var attrs = try attributes.Attrs.init(gpa, false);
    defer attrs.deinit();

    _ = try worktree.addAll(gpa, io, repo.dir, &index, &db, .{
        .rules = .{
            .ignore = &rules,
            .attrs = &attrs,
            .core = .{ .autocrlf = .true },
        },
    });
    const ours = try worktree.writeTree(gpa, io, &index, &db);
    var hex: [hash.max_hex_len]u8 = undefined;
    const ours_text = try gpa.dupe(u8, ours.hex(&hex));
    defer gpa.free(ours_text);

    try repo.exec(io, &.{ "add", "-A" });
    const theirs = try repo.line(io, &.{"write-tree"});
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours_text);

    // And the blob for the CRLF file really is the LF-normalised one.
    const normalised = hash.Hasher.object(.sha1, "blob", "one\ntwo\nthree\n");
    try std.testing.expect(index.find("crlf.txt").?.oid.eql(normalised));
    const kept = hash.Hasher.object(.sha1, "blob", "one\rtwo\r\n");
    try std.testing.expect(index.find("lone.bin").?.oid.eql(kept));
}

test "a tree naming .git is refused rather than written" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    const blob = try h.db.write(io, .blob, "payload\n");
    var inner: object.Tree.Builder = .init(gpa, .sha1);
    defer inner.deinit();
    try inner.add(.file, "config", blob);
    const inner_bytes = try inner.build();
    defer gpa.free(inner_bytes);
    const inner_tree = try h.db.write(io, .tree, inner_bytes);

    // `git~1` is the NTFS short name for `.git`, and it reaches the same
    // directory. A tree may carry it; a working tree must never receive it.
    var outer: object.Tree.Builder = .init(gpa, .sha1);
    defer outer.deinit();
    try outer.add(.tree, "git~1", inner_tree);
    const outer_bytes = try outer.build();
    defer gpa.free(outer_bytes);
    const outer_tree = try h.db.write(io, .tree, outer_bytes);

    try std.testing.expectError(error.UnsafePath, worktree.checkout(
        gpa,
        io,
        h.repo.dir,
        &h.index,
        &h.db,
        outer_tree,
        .{ .rules = h.worktreeRules() },
    ));
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "git~1/config", .{}));
}

test "resetIndex puts the index back and leaves the files alone" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "kept.txt", "one\n");
    try h.repo.writeFile(io, "changed.txt", "one\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const head_tree_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(head_tree_text);

    // Stage a change and a new file, then put the index back.
    try h.repo.writeFile(io, "changed.txt", "two\n");
    try h.repo.writeFile(io, "added.txt", "new\n");
    try h.reload(gpa, io);
    _ = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });

    const outcome = try worktree.resetIndex(gpa, io, &h.index, &h.db, try Oid.parse(.sha1, head_tree_text));
    try std.testing.expectEqual(@as(u32, 1), outcome.removed);
    try std.testing.expectEqual(@as(u32, 1), outcome.updated);
    try h.index.write(io, h.git_dir, "index", .{});

    // The files are exactly where they were.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("two\n", try h.repo.dir.readFile(io, "changed.txt", &buf));
    try std.testing.expectEqualStrings("new\n", try h.repo.dir.readFile(io, "added.txt", &buf));

    // And git says the same thing it says after `git reset`.
    const ours = try h.repo.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(ours);
    try h.repo.exec(io, &.{ "reset", "-q" });
    const theirs = try h.repo.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours);

    // The cache tree is the tree that was reset to, so write-tree is free.
    const written = try worktree.writeTree(gpa, io, &h.index, &h.db);
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(head_tree_text, written.hex(&hex));
}
