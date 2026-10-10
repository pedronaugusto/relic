//! The working tree against the real git: the same bytes in, the same tree
//! out, and a working tree git calls clean.

const std = @import("std");
const repo_mod = @import("../repo/repo.zig");
const path_mod = @import("../names.zig").path;
const shakedown = @import("shakedown");
const repeat = @import("shakedown").corpus.repeat;
const builtin = @import("builtin");
const Io = std.Io;

const testgit = @import("../testing/git.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const worktree = @import("checkout.zig");
const ignore = @import("../patterns.zig").ignore;
const attributes = @import("../patterns.zig").attributes;
const fs = @import("../fs/fs.zig");
const sparse = @import("../patterns.zig").sparse;
const pathspec = @import("../patterns.zig").pathspec;

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
            .rules = try ignore.Rules.init(gpa, .{ .case_fold = false }),
            .attrs = try attributes.Attrs.init(gpa, .{ .case_fold = false }),
        };
    }

    fn deinit(h: *Harness, io: Io) void {
        h.attrs.deinit();
        h.rules.deinit();
        h.index.deinit();
        h.db.deinit(io);
        h.git_dir.close(io);
        h.repo.deinit();
        h.* = undefined;
    }

    fn reload(h: *Harness, gpa: std.mem.Allocator, io: Io) !void {
        h.index.deinit();
        h.index = try index_mod.Index.read(gpa, io, h.git_dir, "index", .{ .git_dir = h.git_dir, .kind = .sha1 });
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
        try h.repo.dir.setFilePermissions(io, "run.sh", @fromBackingInt(@intCast(@as(std.posix.mode_t, 0o755))), .{});
    }
    var has_link = true;
    h.repo.dir.symLink(io, "a.c", "link.c", .{}) catch {
        has_link = false;
    };
    try h.repo.writeFile(io, ".gitignore", "*.log\n");
    try h.repo.writeFile(io, "skip.log", "ignored\n");

    const outcome = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{
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
    try std.testing.expect(std.mem.find(u8, listed, "skip.log") == null);
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

// POSIX read bits are not Windows ACLs: taking them away on Windows does
// not make a file unreadable. These fixtures skip there, and under root,
// whose permission to read survives chmod(000).
fn makeUnreadable(io: Io, dir: Io.Dir, path: []const u8) !struct { err: Io.File.OpenError } {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    try dir.setFilePermissions(io, path, @fromBackingInt(@intCast(@as(std.posix.mode_t, 0))), .{});
    if (dir.openFile(io, path, .{})) |file| {
        file.close(io);
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return .{ .err = err },
        else => return err,
    }
}

test "ignore-errors reports unreadable files, keeps their entries and stages the rest as git does" {
    // Windows needs ACL changes, not chmod, to deny reading a file.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for ([_]worktree.NewBlobs{ .loose, .pack }) |new_blobs| {
        var h = try Harness.init(gpa, io, &.{});
        defer h.deinit(io);
        try h.repo.writeFile(io, "a-unreadable", "old\n");
        _ = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{});
        const old = h.index.find("a-unreadable").?.*;
        try h.index.write(io, h.git_dir, "index", .{});

        try h.repo.writeFile(io, "a-unreadable", "changed and unreadable\n");
        try h.repo.writeFile(io, "b/new-unreadable", "also unreadable\n");
        try h.repo.writeFile(io, "0-good", "before\n");
        try h.repo.writeFile(io, "z-good", "after\n");
        const first_error = (try makeUnreadable(io, h.repo.dir, "a-unreadable")).err;
        // glint-ignore: Z026 -- restoring the mode only lets the temporary directory be removed; the test's result is already decided
        defer h.repo.dir.setFilePermissions(io, "a-unreadable", .default_file, .{}) catch {};
        const second_error = (try makeUnreadable(io, h.repo.dir, "b/new-unreadable")).err;
        // glint-ignore: Z026 -- restoring the mode only lets the temporary directory be removed; the test's result is already decided
        defer h.repo.dir.setFilePermissions(io, "b/new-unreadable", .default_file, .{}) catch {};

        var report: worktree.AddErrorReport = .init(gpa);
        defer report.deinit();
        const outcome = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{
            .rules = h.worktreeRules(),
            .new_blobs = new_blobs,
            .ignore_errors = true,
            .error_report = &report,
        });
        try std.testing.expectEqual(@as(u32, 2), outcome.skipped_errors);
        try std.testing.expectEqual(@as(u32, 2), outcome.added);
        try std.testing.expectEqual(@as(u32, 0), outcome.removed);
        try std.testing.expectEqual(@as(u32, 2), outcome.hashed);
        try std.testing.expectEqual(@as(usize, 2), report.failures.items.len);
        try std.testing.expectEqualStrings("a-unreadable", report.failures.items[0].path);
        try std.testing.expectEqual(first_error, report.failures.items[0].err);
        try std.testing.expectEqualStrings("b/new-unreadable", report.failures.items[1].path);
        try std.testing.expectEqual(second_error, report.failures.items[1].err);
        try std.testing.expect(old.oid.eql(h.index.find("a-unreadable").?.oid));
        try std.testing.expectEqualDeep(old.stat, h.index.find("a-unreadable").?.stat);
        try std.testing.expect(h.index.find("b/new-unreadable") == null);
        try std.testing.expect(h.index.find("0-good") != null);
        try std.testing.expect(h.index.find("z-good") != null);
        // The bytes really reached the database, including when the rest
        // were put into one pack around the failed files.
        const blob = try h.db.read(io, h.index.find("z-good").?.oid);
        defer gpa.free(blob.bytes);
        try std.testing.expectEqualStrings("after\n", blob.bytes);

        h.repo.report_failures = false;
        try std.testing.expectError(error.GitFailed, h.repo.exec(io, &.{ "add", "-A", "--ignore-errors" }));
        const theirs = try h.repo.line(io, &.{"write-tree"});
        defer gpa.free(theirs);
        const ours = try worktree.writeTree(gpa, io, &h.index, &h.db);
        var hex: [hash.max_hex_len]u8 = undefined;
        try std.testing.expectEqualStrings(theirs, ours.hex(&hex));
    }
}

test "without ignore-errors the first unreadable file stops add" {
    // Windows needs ACL changes, not chmod, to deny reading a file.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.repo.writeFile(io, "a-unreadable", "cannot read\n");
    try h.repo.writeFile(io, "z-good", "would have been staged\n");
    const read_error = (try makeUnreadable(io, h.repo.dir, "a-unreadable")).err;
    // glint-ignore: Z026 -- restoring the mode only lets the temporary directory be removed; the test's result is already decided
    defer h.repo.dir.setFilePermissions(io, "a-unreadable", .default_file, .{}) catch {};
    var report: worktree.AddErrorReport = .init(gpa);
    defer report.deinit();
    try std.testing.expectError(read_error, worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{
        .error_report = &report,
    }));
    try std.testing.expectEqual(@as(usize, 0), report.failures.items.len);
    try std.testing.expect(h.index.find("a-unreadable") == null);
    try std.testing.expect(h.index.find("z-good") == null);
}

test "the stat shortcut means a warm addAll hashes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    for (0..60) |i| {
        var buf: [64]u8 = undefined;
        const path = try std.mem.print(&buf, "d{d}/f{d}.txt", .{ i % 6, i });
        try h.repo.writeFile(io, path, "contents\n");
        // This fixture is deliberately non-racy. The clock can give the
        // file and index writes the same tick, even with subsecond times.
        try fs.setTimestamps(io, h.repo.dir, path, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 * std.time.ns_per_s } },
        });
    }

    const cold = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
    try std.testing.expectEqual(@as(u32, 60), cold.added);
    try std.testing.expectEqual(@as(u32, 60), cold.hashed);

    // Write and read back, so the index has a real modification time,
    // strictly later than the fixture files on any clock resolution.
    try h.index.write(io, h.git_dir, "index", .{});
    try h.reload(gpa, io);

    const warm = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
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
    _ = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
    try h.index.write(io, h.git_dir, "index", .{});
    try h.reload(gpa, io);

    const before = h.index.find("racy.txt").?.oid;
    try h.repo.writeFile(io, "racy.txt", "BBBB\n");

    const outcome = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
    const after = h.index.find("racy.txt").?.oid;
    try std.testing.expect(!before.eql(after));
    try std.testing.expectEqual(@as(u32, 1), outcome.modified);

    const expected = hash.Hasher.object(.sha1, "blob", "BBBB\n");
    try std.testing.expect(after.eql(expected));
}

test "a racily clean entry is smudged on the way out only when its file changed, as git smudges" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "same.txt", "AAAA\n");
    try h.repo.writeFile(io, "other.txt", "CCCC\n");
    _ = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
    // Both entries racy: the index is dated to their own second.
    const same = h.index.find("same.txt").?.stat;
    h.index.racy_cutoff_sec = same.mtime_sec;
    h.index.racy_cutoff_nsec = same.mtime_nsec;
    try std.testing.expect(h.index.isRacy(h.index.find("same.txt").?.*));
    // other.txt rewritten with the same size and the same time: a stat
    // cannot tell, the content can.
    const other_stat = try statOf(io, h.repo.dir, "other.txt");
    try h.repo.writeFile(io, "other.txt", "DDDD\n");
    try fs.setTimestamps(io, h.repo.dir, "other.txt", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, other_stat.mtime_sec) * std.time.ns_per_s + other_stat.mtime_nsec } } });

    var check: worktree.RacyCheck = .{ .gpa = gpa, .io = io, .wt = h.repo.dir, .rules = h.worktreeRules() };
    try h.index.write(io, h.git_dir, "index", .{ .racy = check.racy() });
    var back = try index_mod.Index.read(gpa, io, h.git_dir, "index", .{ .git_dir = h.git_dir, .kind = .sha1 });
    defer back.deinit();
    try std.testing.expectEqual(@as(u64, 5), back.find("same.txt").?.stat.size);
    try std.testing.expectEqual(@as(u64, 0), back.find("other.txt").?.stat.size);
    // The index just written is the cutoff now, as git's write takes it.
    try std.testing.expectEqual(back.racy_cutoff_sec, h.index.racy_cutoff_sec);
    try std.testing.expectEqual(back.racy_cutoff_nsec, h.index.racy_cutoff_nsec);

    // Without the check every racy entry is smudged.
    h.index.racy_cutoff_sec = same.mtime_sec;
    h.index.racy_cutoff_nsec = same.mtime_nsec;
    try h.index.write(io, h.git_dir, "index", .{});
    var all = try index_mod.Index.read(gpa, io, h.git_dir, "index", .{ .git_dir = h.git_dir, .kind = .sha1 });
    defer all.deinit();
    try std.testing.expectEqual(@as(u64, 0), all.find("same.txt").?.stat.size);
}

test "sparse checkout keeps a racily clean modified file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "outside.txt", "AAAA\n");
    _ = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
    try h.index.write(io, h.git_dir, "index", .{});
    try h.reload(gpa, io);

    try h.repo.writeFile(io, "outside.txt", "BBBB\n");
    const found = (try fs.statAt(io, h.repo.dir, "outside.txt")).?;
    // Model the ambiguous same-size, same-timestamp observation which the
    // racy-index rule requires callers to verify by content.
    h.index.find("outside.txt").?.stat = found.stat;
    h.index.racy_cutoff_sec = found.stat.mtime_sec;
    h.index.racy_cutoff_nsec = found.stat.mtime_nsec;

    var patterns = try sparse.Patterns.init(gpa, .{ .case_fold = false });
    defer patterns.deinit();
    const out = try worktree.applySparse(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .patterns = &patterns }, .{});

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
    _ = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
    _ = try worktree.writeTree(gpa, io, &h.index, &h.db);

    try h.repo.dir.deleteFile(io, "dir/gone.txt");
    const outcome = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });
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
    const outcome = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = first_tree }, .{
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
    const out = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = target }, .{});

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
        worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = target }, .{}),
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

    var result = try worktree.status(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{
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
    var rules = try ignore.Rules.init(gpa, .{ .case_fold = false });
    defer rules.deinit();
    var attrs = try attributes.Attrs.init(gpa, .{ .case_fold = false });
    defer attrs.deinit();

    _ = try worktree.addAll(gpa, io, repo.dir, .{ .index = &index, .db = &db }, .{
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
        worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = rules }),
    );
    try std.testing.expect(h.index.find("mixed.txt") == null);

    rules.core.safecrlf = .warn;
    const warned = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = rules });
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

    try std.testing.expectError(error.UnsafePath, worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = outer_tree }, .{ .rules = h.worktreeRules() }));
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
    _ = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = h.worktreeRules() });

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
    const Repository = repo_mod.Repository;
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
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    var index = try repo.openIndex(io);
    defer index.deinit();
    const tree = (try repo.headTree(io)).?;
    // The deleted files come back, as `git checkout -- .` brings them.
    _ = try worktree.checkout(gpa, io, here.dir, .{ .index = &index, .db = repo.objectDatabase(), .tree = tree }, .{ .rules = rules, .force = true });
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
    _ = try worktree.writePaths(gpa, io, here.dir, .{ .index = &index, .db = repo.objectDatabase(), .writes = &.{
        .{ .path = "sub/deeper/c.txt", .blob = .{ .mode = entry.mode, .oid = entry.oid } },
    } }, .{ .rules = rules });
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
    const at = std.mem.find(u8, text, heading) orelse return out.toOwnedSlice(gpa);
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
    var ignore_rules = try ignore.Rules.init(gpa, .{ .case_fold = false });
    defer ignore_rules.deinit();
    var obstructions: worktree.Obstructions = .init(gpa);
    defer obstructions.deinit();
    try std.testing.expectError(error.LocalChangesWouldBeOverwritten, worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = target }, .{
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
    _ = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = target }, .{ .force = false, .ignore = &ignore_rules });
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
    _ = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = target }, .{ .force = true });
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

test "a file whose stat went stale is compared as it would be added, under the attributes above it" {
    // Touched, or written in the same tick of a coarse clock as the index:
    // the stat stops matching and the content decides. git reads it the
    // way it would add it, so a CRLF checkout and an expanded `$Id$` under
    // a directory's `.gitattributes` are no change; a changed line is.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGit(gpa, io);
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);

    try h.repo.writeFile(io, "sub/.gitattributes", "*.txt text eol=crlf\nid.txt ident\n");
    try h.repo.writeFile(io, "sub/crlf.txt", "one\ntwo\n");
    try h.repo.writeFile(io, "sub/id.txt", "$Id$\nx\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    for ([_][]const u8{ "sub/crlf.txt", "sub/id.txt" }) |path| try h.repo.dir.deleteFile(io, path);
    try h.repo.exec(io, &.{ "checkout", "--", "." });
    const crlf = try h.repo.readFile(io, "sub/crlf.txt");
    defer gpa.free(crlf);
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", crlf);
    const id = try h.repo.readFile(io, "sub/id.txt");
    defer gpa.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "$Id: "));

    const long_ago: Io.File.SetTimestampsOptions = .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 * std.time.ns_per_s } } };
    for ([_][]const u8{ "sub/crlf.txt", "sub/id.txt" }) |path| try fs.setTimestamps(io, h.repo.dir, path, long_ago);
    try h.reload(gpa, io);
    for ([_][]const u8{ "sub/crlf.txt", "sub/id.txt" }) |path| {
        const entry = h.index.find(path).?;
        try std.testing.expect(!entry.stat.matches(try statOf(io, h.repo.dir, path), .full, .nanosecond));
        try std.testing.expect(!try worktree.differsFromIndex(gpa, io, h.repo.dir, .{ .index = &h.index, .entry = entry.* }, h.worktreeRules()));
    }
    // What it entered to read them, it gave back.
    try std.testing.expect(!h.attrs.entered_any);
    const status = try h.repo.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);

    try h.repo.writeFile(io, "sub/crlf.txt", "one\r\nTWO\r\n");
    const changed = h.index.find("sub/crlf.txt").?;
    try std.testing.expect(try worktree.differsFromIndex(gpa, io, h.repo.dir, .{ .index = &h.index, .entry = changed.* }, h.worktreeRules()));
}

fn statOf(io: Io, dir: Io.Dir, path: []const u8) !fs.Stat {
    return (try fs.statAt(io, dir, path)).?.stat;
}

test "a staging scan owns each name when allocation stops" {
    const io = std.testing.io;
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.writeFile(io, .{ .sub_path = "file", .data = "contents\n" });
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), stagingAllocationCase, .{folder.dir});
    }
}

fn stagingAllocationCase(gpa: std.mem.Allocator, wt: Io.Dir) !void {
    const io = std.testing.io;
    var private = std.testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    try private.dir.createDirPath(io, "objects");
    var db = try odb_mod.Odb.open(gpa, io, private.dir, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    var staged = index_mod.Index.initEmpty(gpa, .sha1);
    defer staged.deinit();
    _ = try worktree.addAll(gpa, io, wt, .{ .index = &staged, .db = &db }, .{});
}

test "a directory that staging cannot open is not reported as deleted" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.createDirPath(io, "blocked");
    try folder.dir.writeFile(io, .{ .sub_path = "blocked/file", .data = "still present\n" });
    var private = std.testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    try private.dir.createDirPath(io, "objects");
    var db = try odb_mod.Odb.open(gpa, io, private.dir, .sha1, .{});
    defer db.deinit(io);
    var staged = index_mod.Index.initEmpty(gpa, .sha1);
    defer staged.deinit();
    _ = try worktree.addAll(gpa, io, folder.dir, .{ .index = &staged, .db = &db }, .{});
    const Refused = struct {
        fn openDir(context: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            if (std.mem.eql(u8, path, "blocked")) return error.AccessDenied;
            return std.testing.io.vtable.dirOpenDir(context, dir, path, options);
        }
    };
    var vtable = io.vtable.*;
    vtable.dirOpenDir = Refused.openDir;
    const refused: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.AccessDenied, worktree.addAll(gpa, refused, folder.dir, .{ .index = &staged, .db = &db }, .{}));
    try std.testing.expect(staged.find("blocked/file") != null);
}

test "a filesystem walk that reaches its depth limit refuses a partial result" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    const path = repeat("d/", 66) ++ "file";
    try folder.dir.createDirPath(io, std.Io.Dir.path.dirnamePosix(path).?);
    try folder.dir.writeFile(io, .{ .sub_path = path, .data = "deep\n" });
    var private = std.testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    try private.dir.createDirPath(io, "objects");
    var db = try odb_mod.Odb.open(gpa, io, private.dir, .sha1, .{});
    defer db.deinit(io);
    var staged = index_mod.Index.initEmpty(gpa, .sha1);
    defer staged.deinit();
    try std.testing.expectError(error.TreeTooDeep, worktree.addAll(gpa, io, folder.dir, .{ .index = &staged, .db = &db }, .{}));
    try std.testing.expectError(error.TreeTooDeep, worktree.status(gpa, io, folder.dir, .{ .index = &staged, .db = &db }, .{}));
    try std.testing.expectError(error.TreeTooDeep, worktree.list(gpa, io, folder.dir, &staged, .{}));
}

test "status and listing refuse a directory they could not read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.createDirPath(io, "blocked");
    try folder.dir.writeFile(io, .{ .sub_path = "blocked/file", .data = "untracked\n" });
    var private = std.testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    try private.dir.createDirPath(io, "objects");
    var db = try odb_mod.Odb.open(gpa, io, private.dir, .sha1, .{});
    defer db.deinit(io);
    var staged = index_mod.Index.initEmpty(gpa, .sha1);
    defer staged.deinit();
    const Refused = struct {
        fn openDir(context: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            if (std.mem.eql(u8, path, "blocked")) return error.AccessDenied;
            return std.testing.io.vtable.dirOpenDir(context, dir, path, options);
        }
    };
    var vtable = io.vtable.*;
    vtable.dirOpenDir = Refused.openDir;
    const refused: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.AccessDenied, worktree.status(gpa, refused, folder.dir, .{ .index = &staged, .db = &db }, .{}));
    try std.testing.expectError(error.AccessDenied, worktree.list(gpa, refused, folder.dir, &staged, .{}));
}

test "checkout writes files with git's modes, trimmed by the umask as git's are" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.repo.writeFile(io, "plain.txt", "one\n");
    try h.repo.writeFile(io, "run.sh", "#!/bin/sh\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "update-index", "--chmod=+x", "run.sh" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tree_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree_text);
    try h.repo.dir.deleteFile(io, "plain.txt");
    try h.repo.dir.deleteFile(io, "run.sh");
    try h.repo.exec(io, &.{ "rm", "-q", "--cached", "plain.txt", "run.sh" });
    try h.reload(gpa, io);

    const mask: std.posix.mode_t = std.c.umask(0o027);
    defer _ = std.c.umask(mask);
    _ = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = try Oid.parse(.sha1, tree_text) }, .{ .rules = h.worktreeRules() });
    const plain = try h.repo.dir.statFile(io, "plain.txt", .{});
    const run = try h.repo.dir.statFile(io, "run.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o640), @as(std.posix.mode_t, @intCast(@backingInt(plain.permissions))) & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o750), @as(std.posix.mode_t, @intCast(@backingInt(run.permissions))) & 0o777);
}

test "checkout writes the same files, index and error whatever the number of tasks" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    // A folder that refuses writes refuses everyone but root.
    if (std.c.getuid() == 0) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    // More files than one batch holds, and a folder that refuses writes.
    var name: [64]u8 = undefined;
    var text: [64]u8 = undefined;
    for (0..1500) |i| {
        const folder = if (i % 50 == 0) "locked" else "open";
        try h.repo.writeFile(io, try std.mem.print(&name, "{s}/d{d}/f{d}", .{ folder, i % 7, i }), try std.mem.print(&text, "{d} first\n", .{i}));
    }
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const first_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(first_text);
    const first = try Oid.parse(.sha1, first_text);
    for (0..1500) |i| {
        const folder = if (i % 50 == 0) "locked" else "open";
        try h.repo.writeFile(io, try std.mem.print(&name, "{s}/d{d}/f{d}", .{ folder, i % 7, i }), try std.mem.print(&text, "{d} second\n", .{i}));
    }
    try h.repo.exec(io, &.{ "commit", "-q", "-am", "two" });

    var seen: ?[]u8 = null;
    defer if (seen) |s| gpa.free(s);
    for ([_]usize{ 1, 2, 7 }) |workers| {
        try h.repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD" });
        try h.reload(gpa, io);
        for (0..7) |d| {
            try h.repo.dir.setFilePermissions(io, try std.mem.print(&name, "locked/d{d}", .{d}), @fromBackingInt(@intCast(@as(std.posix.mode_t, 0o555))), .{});
        }
        const result = worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = first }, .{ .rules = h.worktreeRules(), .workers = workers });
        for (0..7) |d| {
            try h.repo.dir.setFilePermissions(io, try std.mem.print(&name, "locked/d{d}", .{d}), @fromBackingInt(@intCast(@as(std.posix.mode_t, 0o755))), .{});
        }
        // What came back, what the index holds and what the files say.
        var record: std.Io.Writer.Allocating = .init(gpa);
        defer record.deinit();
        if (result) |_| try record.writer.writeAll("ok\n") else |err| try record.writer.print("{s}\n", .{@errorName(err)});
        var hex: [hash.max_hex_len]u8 = undefined;
        for (h.index.entries.items) |entry| try record.writer.print("{s} {s}\n", .{ entry.path, entry.oid.hex(&hex) });
        for (0..1500) |i| {
            const folder = if (i % 50 == 0) "locked" else "open";
            var buf: [64]u8 = undefined;
            try record.writer.writeAll(try h.repo.dir.readFile(io, try std.mem.print(&name, "{s}/d{d}/f{d}", .{ folder, i % 7, i }), &buf));
        }
        if (seen) |s| {
            try std.testing.expectEqualStrings(s, record.written());
        } else {
            try std.testing.expect(std.mem.startsWith(u8, record.written(), "AccessDenied\n") or std.mem.startsWith(u8, record.written(), "PermissionDenied\n"));
            seen = try gpa.dupe(u8, record.written());
        }
    }
}

/// A tree object's bytes from raw entries, in the order given: a hostile
/// tree may hold a name twice, which `Tree.Builder` refuses to write.
fn rawTree(gpa: std.mem.Allocator, io: Io, db: *odb_mod.Odb, entries: []const struct { mode: []const u8, name: []const u8, oid: Oid }) !Oid {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (entries) |e| {
        try bytes.print(gpa, "{s} {s}\x00", .{ e.mode, e.name });
        try bytes.appendSlice(gpa, e.oid.raw());
    }
    return db.write(io, .tree, bytes.items);
}

/// `a/hooks/post-checkout`, an executable, under a tree named `a`.
fn hookTree(gpa: std.mem.Allocator, io: Io, db: *odb_mod.Odb) !Oid {
    const script = try db.write(io, .blob, "#!/bin/sh\necho owned\n");
    const hooks = try rawTree(gpa, io, db, &.{.{ .mode = "100755", .name = "post-checkout", .oid = script }});
    return rawTree(gpa, io, db, &.{.{ .mode = "40000", .name = "hooks", .oid = hooks }});
}

fn expectNoHook(io: Io, h: *Harness) !void {
    try std.testing.expectError(error.FileNotFound, h.git_dir.access(io, "hooks/post-checkout", .{}));
}

test "a tree holding a link and a directory of one name is refused before anything is written, and git writes no hook either" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    const link = try h.db.write(io, .blob, ".git");
    const a = try hookTree(gpa, io, &h.db);
    // `120000 a -> .git` and then `40000 a`: written in order, the hook
    // would land in `.git/hooks`.
    const tree = try rawTree(gpa, io, &h.db, &.{
        .{ .mode = "120000", .name = "a", .oid = link },
        .{ .mode = "40000", .name = "a", .oid = a },
    });
    var refusal: worktree.Refusal = .{};
    try std.testing.expectError(error.UnsafePath, worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = tree }, .{
        .rules = h.worktreeRules(),
        .refusal = &refusal,
    }));
    try std.testing.expectEqual(path_mod.Reason.path_collision, refusal.reason.?);
    try std.testing.expectEqualStrings("a", refusal.path());
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "a", .{}));
    try expectNoHook(io, &h);

    var hex: [hash.max_hex_len]u8 = undefined;
    var git = try h.repo.capture(io, &.{ "read-tree", "-u", "--reset", tree.hex(&hex) });
    git.deinit(gpa);
    try expectNoHook(io, &h);
}

test "a link and a directory whose names a folding filesystem makes one are refused, and nothing reaches .git on any filesystem" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |ignore_case| {
        var h = try Harness.init(gpa, io, &.{});
        defer h.deinit(io);
        const link = try h.db.write(io, .blob, ".git");
        const a = try hookTree(gpa, io, &h.db);
        const tree = try rawTree(gpa, io, &h.db, &.{
            .{ .mode = "120000", .name = "A", .oid = link },
            .{ .mode = "40000", .name = "a", .oid = a },
        });
        var rules = h.worktreeRules();
        rules.ignore_case = ignore_case;
        var refusal: worktree.Refusal = .{};
        const result = worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = tree }, .{ .rules = rules, .refusal = &refusal });
        if (ignore_case) {
            try std.testing.expectError(error.UnsafePath, result);
            try std.testing.expectEqual(path_mod.Reason.path_collision, refusal.reason.?);
        } else if (result) |_| {} else |err| switch (err) {
            // A filesystem that folds case anyway: the link is found on the
            // way down and the write past it refused, or, where a link
            // could not be made, the file written in its place stands in
            // the way.
            error.UnsafePath => try std.testing.expectEqual(path_mod.Reason.beyond_symlink, refusal.reason.?),
            error.NotDir => {},
            else => return err,
        }
        try expectNoHook(io, &h);
    }
}

test "nothing is written or removed past a symbolic link in the working tree, and a forced checkout replaces the link as git's does" {
    // A link needs a privilege on Windows.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.repo.writeFile(io, "d/f", "tracked\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tree_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree_text);
    const tree = try Oid.parse(.sha1, tree_text);

    // `d` is now an untracked link to a directory beside it.
    try h.repo.exec(io, &.{ "rm", "-q", "--cached", "d/f" });
    try h.repo.dir.deleteTree(io, "d");
    try h.repo.writeFile(io, "elsewhere/keep", "mine\n");
    try h.repo.dir.symLink(io, "elsewhere", "d", .{ .is_directory = true });
    try h.reload(gpa, io);

    var refusal: worktree.Refusal = .{};
    const options: worktree.CheckoutOptions = .{ .rules = h.worktreeRules(), .refusal = &refusal, .force = true };
    var unforced = options;
    unforced.force = false;
    try std.testing.expectError(error.UnsafePath, worktree.writePaths(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .writes = &.{
        .{ .path = "d/f", .blob = .{ .mode = .file, .oid = (try h.db.write(io, .blob, "tracked\n")) } },
    } }, unforced));
    try std.testing.expectEqual(path_mod.Reason.beyond_symlink, refusal.reason.?);
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "elsewhere/f", .{}));

    // Removing `d/keep` removes nothing: it is not the working tree's.
    try worktree.removeEntry(io, h.repo.dir, "d/keep");
    try h.repo.dir.access(io, "elsewhere/keep", .{});

    _ = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = tree }, options);
    const d = (try fs.statAt(io, h.repo.dir, "d")).?;
    try std.testing.expectEqual(Io.File.Kind.directory, d.kind);
    try h.repo.dir.access(io, "d/f", .{});
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "elsewhere/f", .{}));
    try h.repo.dir.access(io, "elsewhere/keep", .{});
}

test "a wider sparse pattern brings a link back as a link and a submodule back as its empty directory, as git does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    // A link needs a privilege on Windows, where git writes it as a file.
    const links = builtin.target.os.tag != .windows;
    try h.repo.writeFile(io, "top", "top\n");
    try h.repo.writeFile(io, "dir/file", "file\n");
    if (links) try h.repo.dir.symLink(io, "file", "dir/link", .{});
    try h.repo.exec(io, &.{ "add", "-A" });
    // A submodule's commit, which this repository's objects do not hold.
    try h.repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000,1111111111111111111111111111111111111111,dir/sub" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try h.reload(gpa, io);

    try h.git_dir.createDirPath(io, "info");
    try h.git_dir.writeFile(io, .{ .sub_path = "info/sparse-checkout", .data = "/*\n!/dir/\n" });
    var narrow = (try sparse.Patterns.load(gpa, io, h.git_dir, .{ .case_fold = false })).?;
    defer narrow.deinit();
    _ = try worktree.applySparse(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .patterns = &narrow }, .{});
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "dir/file", .{}));
    try h.repo.dir.deleteTree(io, "dir");

    try h.git_dir.writeFile(io, .{ .sub_path = "info/sparse-checkout", .data = "/*\n" });
    var wide = (try sparse.Patterns.load(gpa, io, h.git_dir, .{ .case_fold = false })).?;
    defer wide.deinit();
    const back = try worktree.applySparse(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .patterns = &wide }, .{ .rules = h.worktreeRules() });
    try std.testing.expectEqual(@as(u32, if (links) 3 else 2), back.restored);
    try std.testing.expectEqual(Io.File.Kind.directory, (try fs.statAt(io, h.repo.dir, "dir/sub")).?.kind);
    if (links) {
        try std.testing.expectEqual(Io.File.Kind.sym_link, (try fs.statAt(io, h.repo.dir, "dir/link")).?.kind);
        var buf: [16]u8 = undefined;
        try std.testing.expectEqualStrings("file", buf[0..try h.repo.dir.readLink(io, "dir/link", &buf)]);
    }

    // git calls the result clean.
    try h.index.write(io, h.git_dir, "index", .{});
    try h.repo.exec(io, &.{ "config", "core.sparseCheckout", "true" });
    const status = try h.repo.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);
}

test "a tree with names only Windows refuses checks out elsewhere as git checks it out" {
    // git itself refuses these names on Windows.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    const names = [_][]const u8{ "drivers/i2c/aux.c", "a\tb", "t.", "v1 ", "con", "x:y" };
    for (names) |path| try h.repo.writeFile(io, path, "kernel\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    try h.repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tree_text = try h.repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree_text);
    for (names) |path| try h.repo.dir.deleteFile(io, path);
    try h.repo.exec(io, &.{ "rm", "-q", "--cached", "-r", "." });
    try h.reload(gpa, io);

    const out = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = try Oid.parse(.sha1, tree_text) }, .{ .rules = h.worktreeRules() });
    try std.testing.expectEqual(@as(u32, names.len), out.written);
    try h.index.write(io, h.git_dir, "index", .{});
    const status = try h.repo.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);
}

/// What `git check-attr -a` says of `path`, and what relic's lookup says,
/// each as sorted `name: value` lines.
fn expectCheckAttr(gpa: std.mem.Allocator, io: Io, h: *Harness, path: []const u8) !void {
    const said = try h.repo.run(io, &.{ "check-attr", "-a", "--", path });
    defer gpa.free(said);
    var theirs: std.ArrayList([]const u8) = .empty;
    defer theirs.deinit(gpa);
    var lines = std.mem.splitScalar(u8, said, '\n');
    while (lines.next()) |line| if (line.len != 0) try theirs.append(gpa, line[path.len + 2 ..]);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try h.attrs.enter(io, h.repo.dir, path);
    const found = try h.attrs.lookup(a, path, false);
    var ours: std.ArrayList([]const u8) = .empty;
    for (found.items) |item| {
        const value = switch (item.state) {
            .set => "set",
            .unset => "unset",
            .value => |v| v,
            .unspecified => continue,
        };
        try ours.append(a, try a.print("{s}: {s}", .{ item.name, value }));
    }
    const less = struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f;
    std.mem.sort([]const u8, theirs.items, {}, less);
    std.mem.sort([]const u8, ours.items, {}, less);
    std.testing.expectEqual(theirs.items.len, ours.items.len) catch |err| {
        std.debug.print("{s}: git {any}, relic {any}\n", .{ path, theirs.items, ours.items });
        return err;
    };
    for (theirs.items, ours.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "attributes resolve as git check-attr resolves them: the last assignment of a line, macros once and only when set, and only from the top" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.repo.writeFile(io, ".gitattributes",
        \\[attr]m x y=1
        \\[attr]n p
        \\* a -a m -x
        \\sub/* !m
        \\val/* m=foo
        \\top/* n
        \\
    );
    // A macro further down is git's "not allowed", and ignored.
    try h.repo.writeFile(io, "sub/.gitattributes", "[attr]inner z\n* inner\n");
    // info/attributes outranks the root's file, its macro too.
    try h.git_dir.createDirPath(io, "info");
    try h.git_dir.writeFile(io, .{ .sub_path = "info/attributes", .data = "[attr]n q\n" });
    try h.attrs.loadGlobal(io, h.git_dir, null, null);
    // A .gitattributes that is a link is not followed.
    if (builtin.target.os.tag != .windows) {
        try h.repo.writeFile(io, "elsewhere.attrs", "* evil\n");
        try h.repo.dir.createDirPath(io, "link");
        try h.repo.dir.symLink(io, "../elsewhere.attrs", "link/.gitattributes", .{});
        try expectCheckAttr(gpa, io, &h, "link/f");
    }
    for ([_][]const u8{ "f", "sub/f", "val/f", "top/f" }) |path| try expectCheckAttr(gpa, io, &h, path);
}

/// The ignore lines the glob differentials below share: git's line grammar
/// at its edges, the probes the glob design names, and a pattern far longer
/// than one match takes on the stack.
const glob_lines = "tabbed\t\nspaced   \nkept\\ \n\\#hash\n\\!bang\n*.log\n!keep.log\nbuild/\n/root-only\n" ++
    "doc/*.txt\nsr**/wild.zig\na/**/z\n[[:upper:]]*.c\nx[abc\n" ++ "long/" ++ repeat("*", 1100) ++ "z\n";

/// The paths the `sr**/wild.zig` probe is decided on where git before 2.52
/// matched it: its `match_pathname` cut the literal `sr` off and read what
/// was left, `**/wild.zig`, as the start of a path, where `**/` matches any
/// directories or none. 2.52 gives the match one byte of that prefix, and
/// relic decides them as 2.52 does, so an older git is not asked about them.
const probe_paths = [_][]const u8{ "src/worktree/wild.zig", "srwild.zig" };

/// Whether `path` is one of `probe_paths`.
fn isProbePath(path: []const u8) bool {
    for (probe_paths) |probe| if (std.mem.eql(u8, path, probe)) return true;
    return false;
}

/// Whether the git found decides `probe_paths` as relic does.
fn probeAgrees(gpa: std.mem.Allocator, io: std.Io) !bool {
    return testgit.gitAtLeast(gpa, io, 2, 52);
}

test "ignore rules decide every path as git check-ignore decides it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.repo.writeFile(io, ".gitignore", glob_lines);
    try h.repo.dir.createDirPath(io, "build");
    // git init sets core.ignoreCase where the filesystem folds case, and
    // git folds the patterns then.
    const fold = try h.repo.line(io, &.{ "config", "--bool", "--default", "false", "core.ignorecase" });
    defer gpa.free(fold);
    var rules: ignore.Rules = try .init(gpa, .{ .case_fold = std.mem.eql(u8, fold, "true") });
    defer rules.deinit();
    try rules.addText(glob_lines, "", ".gitignore", 2);

    const all_paths = [_]struct { []const u8, bool }{
        .{ "tabbed", false },     .{ "spaced", false },          .{ "kept ", false },
        .{ "#hash", false },      .{ "!bang", false },           .{ "a.log", false },
        .{ "keep.log", false },   .{ "sub/keep.log", false },    .{ "build", true },
        .{ "build/x.o", false },  .{ "root-only", false },       .{ "sub/root-only", false },
        .{ "doc/a.txt", false },  .{ "other/doc/a.txt", false }, .{ "src/worktree/wild.zig", false },
        .{ "srwild.zig", false }, .{ "src/wild.zig", false },    .{ "a/b/c/z", false },
        .{ "a/z", false },        .{ "Upper.c", false },         .{ "lower.c", false },
        .{ "x[abc", false },      .{ "long/xyz", false },        .{ "long/x/z", false },
        .{ "long/xy", false },
    };
    const probe = try probeAgrees(gpa, io);
    var kept: [all_paths.len]struct { []const u8, bool } = undefined;
    var kept_len: usize = 0;
    for (all_paths) |p| {
        if (!probe and isProbePath(p[0])) continue;
        kept[kept_len] = p;
        kept_len += 1;
    }
    const paths = kept[0..kept_len];
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    for (paths) |p| try input.print(gpa, "{s}\x00", .{p[0]});
    // `-z`: source, line, pattern and path, each ended by a NUL, the first
    // three empty when nothing matched; nothing is quoted.
    const said = try h.repo.runInput(io, &.{ "check-ignore", "--no-index", "--stdin", "-z", "-v", "-n" }, input.items);
    defer gpa.free(said);
    var fields = std.mem.splitScalar(u8, said, 0);
    for (paths) |p| {
        _ = fields.next() orelse "";
        const line_text = fields.next() orelse "";
        const pattern = fields.next() orelse "";
        const path = fields.next() orelse "";
        std.testing.expectEqualStrings(p[0], path) catch |err| {
            std.debug.print("git check-ignore said:\n{s}\n", .{said});
            return err;
        };
        const decided: ?u32 = if (line_text.len == 0) null else try std.fmt.parseUnsigned(u32, line_text, 10);
        // A `!` pattern re-included the path.
        const theirs = decided != null and pattern[0] != '!';
        const ours = rules.matchPath(p[0], p[1]);
        std.testing.expectEqual(theirs, ours.excluded) catch |err| {
            std.debug.print("{s}: git line {s}, {s}\n", .{ p[0], line_text, pattern });
            return err;
        };
        try std.testing.expectEqual(decided, if (ours.by) |by| by.line else null);
    }
}

test "attributes match globs as git check-attr matches them" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    // Sixty-five brackets: more than one match holds on the stack.
    // git folds the patterns where git init found a folding filesystem.
    const fold = try h.repo.line(io, &.{ "config", "--bool", "--default", "false", "core.ignorecase" });
    defer gpa.free(fold);
    const folded: attributes.Attrs = try .init(gpa, .{ .case_fold = std.mem.eql(u8, fold, "true") });
    h.attrs.deinit();
    h.attrs = folded;
    const many = repeat("[ab]", 65);
    try h.repo.writeFile(io, ".gitattributes", "*.txt t1\nsr**/wild.zig probe\n[[:upper:]]*.c upper\n" ++
        many ++ " many\nx[abc broken\na/**/z deep\n*.C\tfolded\n");
    const probe = try probeAgrees(gpa, io);
    for ([_][]const u8{
        "f.txt",   "src/worktree/wild.zig", "srwild.zig",           "src/wild.zig", "Upper.c",
        "lower.c", repeat("a", 65),         repeat("a", 64) ++ "c", "x[abc",        "a/b/c/z",
        "a/z",     "UPPER.C",
    }) |path| {
        if (!probe and isProbePath(path)) continue;
        try expectCheckAttr(gpa, io, &h, path);
    }
}

test "pathspecs choose the files git ls-files lists" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    const files = [_][]const u8{ "src/worktree/wild.zig", "src/a.zig", "srcx/b.zig", "docs/README.md", "Upper.c", "top.zig" };
    for (files) |path| try h.repo.writeFile(io, path, "x\n");
    try h.repo.exec(io, &.{ "add", "-A" });
    const long = "src/" ++ repeat("*", 1100) ++ ".zig";
    for ([_][]const u8{
        // git_fnmatch matches what follows the literal prefix as a pattern
        // of its own: `**` after `sr` spans components.
        ":(glob)sr**/wild.zig", ":(glob)src**/wild.zig", ":(glob)src/*.zig",
        "*.zig",                "src/*.zig",             ":(icase)SRC/*",
        ":(exclude)*.md",       long,                    ":(glob)" ++ long,
        "[[:upper:]]*",
    }) |spec| {
        const said = try h.repo.run(io, &.{ "ls-files", "--", spec });
        defer gpa.free(said);
        var p = try pathspec.parse(gpa, &.{spec});
        defer p.deinit();
        var ours: std.ArrayList(u8) = .empty;
        defer ours.deinit(gpa);
        var sorted = files;
        std.mem.sort([]const u8, &sorted, {}, struct {
            fn f(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.f);
        for (sorted) |path| if (p.matches(path)) try ours.print(gpa, "{s}\n", .{path});
        std.testing.expectEqualStrings(said, ours.items) catch |err| {
            std.debug.print("pathspec {s}\n", .{spec});
            return err;
        };
    }
}

test "without core.symlinks a link written as a file stays a link to status and add, as git keeps it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa, io, &.{});
    defer h.deinit(io);
    try h.repo.writeFile(io, "target", "t\n");
    const link = try h.db.write(io, .blob, "target");
    const file = try h.db.write(io, .blob, "t\n");
    var builder: object.Tree.Builder = .init(gpa, .sha1);
    defer builder.deinit();
    try builder.add(.symlink, "link", link);
    try builder.add(.file, "target", file);
    const bytes = try builder.build();
    defer gpa.free(bytes);
    const tree = try h.db.write(io, .tree, bytes);

    var rules = h.worktreeRules();
    rules.symlinks = false;
    const out = try worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = tree }, .{ .rules = rules, .force = true });
    try std.testing.expectEqual(@as(u32, 1), out.symlinks_as_files);
    // Every stat stale, so the content is what decides.
    for (h.index.entries.items) |*entry| entry.stat = .none;

    var st = try worktree.status(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = rules, .head_tree = tree });
    defer st.deinit();
    try std.testing.expect(st.isClean());
    const added = try worktree.addAll(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db }, .{ .rules = rules });
    try std.testing.expectEqual(@as(u32, 0), added.modified);
    try std.testing.expectEqual(object.Mode.symlink, h.index.find("link").?.mode);

    // git, told the same, calls it clean.
    try h.index.write(io, h.git_dir, "index", .{});
    try h.repo.exec(io, &.{ "config", "core.symlinks", "false" });
    var hex: [hash.max_hex_len]u8 = undefined;
    const commit = try h.repo.line(io, &.{ "commit-tree", tree.hex(&hex), "-m", "links" });
    defer gpa.free(commit);
    try h.repo.exec(io, &.{ "update-ref", "HEAD", commit });
    const said = try h.repo.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(said);
    try std.testing.expectEqualStrings("", said);
}
