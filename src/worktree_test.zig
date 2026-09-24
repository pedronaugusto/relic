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
const sparse = @import("sparse.zig");

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
    // Neither an executable bit nor a symlink is a thing a Windows working
    // tree has: there is no POSIX mode, and a link needs a privilege the
    // runner does not hand out. git turns `core.fileMode` and
    // `core.symlinks` off there for the same reason. The two entries are
    // left out of the shape rather than asserted, and everything else in
    // the tree is compared as it is everywhere else.
    const has_exec_bit = Io.File.Permissions.has_executable_bit;
    if (has_exec_bit) {
        try h.repo.dir.setFilePermissions(io, "run.sh", @enumFromInt(@as(std.posix.mode_t, 0o755)), .{});
    }
    var has_link = true;
    h.repo.dir.symLink(io, "a.c", "link.c", .{}) catch {
        has_link = false;
    };
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
    if (has_link) try std.testing.expect(h.index.find("link.c").?.mode == .symlink);
    if (has_exec_bit) try std.testing.expect(h.index.find("run.sh").?.mode == .exec);

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

test "sparse checkout keeps a racily clean modified file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "outside.txt", "AAAA\n");
    _ = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = h.worktreeRules() });
    try h.index.write(io, h.git_dir, "index", .{});
    try h.reload(gpa, io);

    try h.repo.writeFile(io, "outside.txt", "BBBB\n");
    const found = (try fs.statAt(io, h.repo.dir, "outside.txt")).?;
    // Model the ambiguous same-size, same-timestamp observation which the
    // racy-index rule requires callers to verify by content.
    h.index.find("outside.txt").?.stat = found.stat;
    h.index.racy_cutoff_sec = found.stat.mtime_sec;
    h.index.racy_cutoff_nsec = found.stat.mtime_nsec;

    var patterns = try sparse.Patterns.init(gpa, false);
    defer patterns.deinit();
    const out = try worktree.applySparse(gpa, io, h.repo.dir, &h.index, &h.db, &patterns, .{});

    try std.testing.expectEqual(@as(u32, 1), out.kept_dirty);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("BBBB\n", try h.repo.dir.readFile(io, "outside.txt", &buf));
    try std.testing.expect(!h.index.find("outside.txt").?.skip_worktree);
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

test "checkout replaces a tracked directory with a file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "a/child.txt", "old\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "directory" });

    try h.repo.dir.deleteFile(io, "a/child.txt");
    try h.repo.dir.deleteDir(io, "a");
    try h.repo.writeFile(io, "a", "new file\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "file" });
    const target_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(target_text);
    const target = try Oid.parse(.sha1, target_text);

    try h.repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try h.reload(gpa, io);
    const out = try worktree.checkout(gpa, io, h.repo.dir, &h.index, &h.db, target, .{});

    try std.testing.expectEqual(@as(u32, 1), out.written);
    try std.testing.expectEqual(@as(u32, 1), out.removed);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("new file\n", try h.repo.dir.readFile(io, "a", &buf));
    try std.testing.expect(h.index.find("a/child.txt") == null);
    try std.testing.expect(h.index.find("a") != null);
}

test "checkout refuses a directory-to-file conflict before deleting tracked files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "a/child.txt", "tracked\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "directory" });
    try h.repo.dir.deleteFile(io, "a/child.txt");
    try h.repo.dir.deleteDir(io, "a");
    try h.repo.writeFile(io, "a", "replacement\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "file" });
    const target_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(target_text);
    const target = try Oid.parse(.sha1, target_text);

    try h.repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try h.repo.writeFile(io, "a/mine.txt", "untracked\n");
    try h.reload(gpa, io);
    try std.testing.expectError(
        error.UntrackedWouldBeOverwritten,
        worktree.checkout(gpa, io, h.repo.dir, &h.index, &h.db, target, .{}),
    );

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("tracked\n", try h.repo.dir.readFile(io, "a/child.txt", &buf));
    try std.testing.expectEqualStrings("untracked\n", try h.repo.dir.readFile(io, "a/mine.txt", &buf));
    try std.testing.expect(h.index.find("a/child.txt") != null);
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

test "core.safecrlf refuses irreversible staging and reports warnings" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.attrs.addText("*.txt text\n", "", "info/attributes", attributes.info_precedence);
    try h.repo.writeFile(io, "mixed.txt", "one\r\ntwo\n");

    var rules = h.worktreeRules();
    rules.core.safecrlf = .true;
    try std.testing.expectError(
        error.IrreversibleConversion,
        worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = rules }),
    );
    try std.testing.expect(h.index.find("mixed.txt") == null);

    rules.core.safecrlf = .warn;
    const warned = try worktree.addAll(gpa, io, h.repo.dir, &h.index, &h.db, .{ .rules = rules });
    try std.testing.expectEqual(@as(u32, 1), warned.safecrlf_warnings);
    try std.testing.expect(h.index.find("mixed.txt") != null);
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

test "checkout and writePaths apply every .gitattributes on the way down, as git does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const Repository = @import("repo.zig").Repository;
    const files = [_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = ".gitattributes", .bytes = "*.txt text\n" },
        .{ .path = "sub/.gitattributes", .bytes = "*.txt eol=crlf\n" },
        .{ .path = "sub/deeper/.gitattributes", .bytes = "b.txt eol=lf\n" },
        .{ .path = "top.txt", .bytes = "a\nb\n" },
        .{ .path = "sub/x.txt", .bytes = "a\nb\n" },
        .{ .path = "sub/deeper/b.txt", .bytes = "a\nb\n" },
        .{ .path = "sub/deeper/c.txt", .bytes = "a\nb\n" },
    };

    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    inline for (.{ &git, &here }) |r| {
        for (files) |f| try r.writeFile(io, f.path, f.bytes);
        try r.exec(io, &.{ "add", "." });
        try r.exec(io, &.{ "commit", "-q", "-m", "attributes" });
        for (files) |f| try r.dir.deleteFile(io, f.path);
    }
    try git.exec(io, &.{ "checkout", "--", "." });

    var repo = try Repository.open(gpa, io, here.dir, .{});
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = repo.worktreeRules();
    rules.attrs = &attrs;
    var index = try repo.openIndex(io);
    defer index.deinit();
    const tree = (try repo.headTree(io)).?;
    _ = try worktree.checkout(gpa, io, here.dir, &index, &repo.odb, tree, .{ .rules = rules });
    // What `enter` loaded is given back.
    try std.testing.expectEqual(@as(usize, 0), attrs.levels.items.len);

    for (files) |f| {
        const a = try git.readFile(io, f.path);
        defer gpa.free(a);
        const b = try here.readFile(io, f.path);
        defer gpa.free(b);
        std.testing.expectEqualStrings(a, b) catch |err| {
            std.debug.print("{s} differs\n", .{f.path});
            return err;
        };
    }
    const crlf = try here.readFile(io, "sub/deeper/c.txt");
    defer gpa.free(crlf);
    try std.testing.expectEqualStrings("a\r\nb\r\n", crlf);

    // One path on its own, with the files that decide it already there.
    try git.dir.deleteFile(io, "sub/deeper/c.txt");
    try git.exec(io, &.{ "checkout", "--", "sub/deeper/c.txt" });
    try here.dir.deleteFile(io, "sub/deeper/c.txt");
    const entry = index.find("sub/deeper/c.txt").?;
    _ = try worktree.writePaths(gpa, io, here.dir, &index, &repo.odb, &.{
        .{ .path = "sub/deeper/c.txt", .blob = .{ .mode = entry.mode, .oid = entry.oid } },
    }, .{ .rules = rules });
    const a = try git.readFile(io, "sub/deeper/c.txt");
    defer gpa.free(a);
    const b = try here.readFile(io, "sub/deeper/c.txt");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

/// The paths git lists under the heading that starts with `heading`, one
/// per tab-indented line.
fn listedUnder(gpa: std.mem.Allocator, text: []const u8, heading: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const at = std.mem.indexOf(u8, text, heading) orelse return out.toOwnedSlice(gpa);
    var lines = std.mem.splitScalar(u8, text[at..], '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '\t') break;
        try out.appendSlice(gpa, line[1..]);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn joined(gpa: std.mem.Allocator, paths: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths) |p| {
        try out.appendSlice(gpa, p);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "checkout refuses to lose local changes or untracked files, lists them as git does, and touches nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, ".gitignore", "*.log\n");
    try h.repo.writeFile(io, "keep", "keep\n");
    try h.repo.writeFile(io, "change", "one\n");
    try h.repo.writeFile(io, "gone", "gone\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "a" });
    try h.repo.writeFile(io, "change", "two\n");
    try h.repo.dir.deleteFile(io, "gone");
    try h.repo.writeFile(io, "new.txt", "new\n");
    try h.repo.writeFile(io, "dir/f", "f\n");
    try h.repo.writeFile(io, "build.log", "tracked log\n");
    try h.repo.exec(io, &.{ "add", "-A", "-f" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "b" });
    try h.repo.exec(io, &.{ "tag", "b" });
    const target_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(target_text);
    const target = try Oid.parse(.sha1, target_text);
    try h.repo.exec(io, &.{ "checkout", "-q", "HEAD~1" });

    // Local changes where the target changes the file, and where it does
    // not; untracked files where it puts one, ignored and not.
    try h.repo.writeFile(io, "change", "mine\n");
    try h.repo.writeFile(io, "keep", "mine too\n");
    try h.repo.writeFile(io, "new.txt", "mine\n");
    try h.repo.writeFile(io, "dir", "a file where a directory goes\n");
    try h.repo.writeFile(io, "build.log", "an ignored log\n");

    var git = try h.repo.capture(io, &.{ "checkout", "-q", "b" });
    defer git.deinit(gpa);
    try std.testing.expect(git.code != 0);
    const git_changed = try listedUnder(gpa, git.stderr, "error: Your local changes to the following files would be overwritten");
    defer gpa.free(git_changed);
    const git_untracked = try listedUnder(gpa, git.stderr, "error: The following untracked working tree files would be overwritten");
    defer gpa.free(git_untracked);

    try h.reload(gpa, io);
    var ignore_rules = try ignore.Rules.init(gpa, false);
    defer ignore_rules.deinit();
    var obstructions: worktree.Obstructions = .init(gpa);
    defer obstructions.deinit();
    try std.testing.expectError(error.LocalChangesWouldBeOverwritten, worktree.checkout(gpa, io, h.repo.dir, &h.index, &h.db, target, .{
        .force = false,
        .ignore = &ignore_rules,
        .obstructions = &obstructions,
    }));
    const ours_changed = try joined(gpa, obstructions.changed.items);
    defer gpa.free(ours_changed);
    const ours_untracked = try joined(gpa, obstructions.untracked.items);
    defer gpa.free(ours_untracked);
    try std.testing.expectEqualStrings(git_changed, ours_changed);
    try std.testing.expectEqualStrings(git_untracked, ours_untracked);

    // Nothing was touched.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("mine\n", try h.repo.dir.readFile(io, "change", &buf));
    try std.testing.expectEqualStrings("mine\n", try h.repo.dir.readFile(io, "new.txt", &buf));

    // With the obstructions gone the checkout goes through, keeping the
    // change the target does not touch and replacing the ignored file, as
    // git's does.
    try h.repo.writeFile(io, "change", "one\n");
    try h.repo.dir.deleteFile(io, "new.txt");
    try h.repo.dir.deleteFile(io, "dir");
    _ = try worktree.checkout(gpa, io, h.repo.dir, &h.index, &h.db, target, .{ .force = false, .ignore = &ignore_rules });
    try std.testing.expectEqualStrings("mine too\n", try h.repo.dir.readFile(io, "keep", &buf));
    try std.testing.expectEqualStrings("tracked log\n", try h.repo.dir.readFile(io, "build.log", &buf));
    try std.testing.expectEqualStrings("two\n", try h.repo.dir.readFile(io, "change", &buf));
}

test "a forced checkout overwrites local changes and untracked files, as read-tree --reset -u does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "change", "one\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "a" });
    try h.repo.writeFile(io, "change", "two\n");
    try h.repo.writeFile(io, "new.txt", "new\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "b" });
    const target_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(target_text);
    const target = try Oid.parse(.sha1, target_text);
    try h.repo.exec(io, &.{ "checkout", "-q", "HEAD~1" });
    try h.repo.writeFile(io, "change", "mine\n");
    try h.repo.writeFile(io, "new.txt", "mine\n");

    try h.reload(gpa, io);
    _ = try worktree.checkout(gpa, io, h.repo.dir, &h.index, &h.db, target, .{ .force = true });
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("two\n", try h.repo.dir.readFile(io, "change", &buf));
    try std.testing.expectEqualStrings("new\n", try h.repo.dir.readFile(io, "new.txt", &buf));
    try h.index.write(io, h.git_dir, "index", .{});
    // The index is the target and the working tree matches it; only
    // `HEAD`, which a checkout does not move, is behind.
    const status = try h.repo.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("M  change\nA  new.txt\n", status);
}
