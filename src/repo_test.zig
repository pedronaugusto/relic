//! The front door against the real git: a repository this creates is one git
//! uses, and a commit this writes is one git shows.

const std = @import("std");
const Io = std.Io;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const worktrees = @import("worktrees.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const index_mod = @import("index.zig");

const Oid = hash.Oid;

const fixture_who: object.Signature = .{
    .name = "Fixture",
    .email = "fixture@example.com",
    .when_secs = 1_700_000_000,
    .offset_minutes = 0,
};

test "peeling refuses an annotated tag chain beyond the limit" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);

    var target = try repo.odb.write(io, .blob, "target\n");
    var target_type: object.Type = .blob;
    for (0..17) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "tag-{d}", .{i});
        target = try repo.writeTag(io, .{
            .target = target,
            .target_type = target_type,
            .name = name,
            .message = "nested\n",
        });
        target_type = .tag;
    }

    try std.testing.expectError(error.TagDepthExceeded, repo.peel(io, target));
}

test "a repository this creates is one git uses" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGit(gpa, io);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectEqual(hash.Kind.sha1, repo.kind);
    try std.testing.expect(!repo.isBare());

    var git: testgit.Repo = .{ .gpa = gpa, .tmp = tmp, .dir = tmp.dir };
    // The directory is this test's; `deinit` on the harness must not remove
    // it twice, so the harness is used only to run commands.
    const branch = try git.line(io, &.{ "symbolic-ref", "--short", "HEAD" });
    defer gpa.free(branch);
    try std.testing.expectEqualStrings("main", branch);
    try git.exec(io, &.{ "fsck", "--no-progress" });

    const status = try git.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);
}

test "a whole commit cycle, and git agrees with every part of it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGit(gpa, io);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);

    var git: testgit.Repo = .{ .gpa = gpa, .tmp = tmp, .dir = tmp.dir };
    try git.writeFile(io, "a.txt", "hello\n");
    try git.writeFile(io, "dir/b.txt", "nested\n");

    var index = try repo.openIndex(io);
    defer index.deinit();
    var rules = try repo.loadIgnore(io);
    defer rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();

    var wt_rules = repo.worktreeRules();
    wt_rules.ignore = &rules;
    wt_rules.attrs = &attrs;

    _ = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = wt_rules });
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});

    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .author = fixture_who,
        .committer = fixture_who,
        .message = "first commit\n",
    });

    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("refs/heads/main", .{ .direct = commit }, .must_not_exist);
    try tx.commit(io, .{
        .who = fixture_who,
        .message = "commit (initial): first commit",
        .policy = repo.reflogPolicy(),
    });

    var hex: [hash.max_hex_len]u8 = undefined;
    const commit_text = try gpa.dupe(u8, commit.hex(&hex));
    defer gpa.free(commit_text);

    const shown = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(commit_text, shown);

    const status = try git.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);

    const listed = try git.run(io, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer gpa.free(listed);
    try std.testing.expectEqualStrings("a.txt\ndir/b.txt\n", listed);

    // The reflog is there, for HEAD as well as for the branch.
    const head_log = try git.run(io, &.{ "reflog", "show", "HEAD" });
    defer gpa.free(head_log);
    try std.testing.expect(std.mem.indexOf(u8, head_log, "commit (initial): first commit") != null);
    const branch_log = try git.run(io, &.{ "reflog", "show", "main" });
    defer gpa.free(branch_log);
    try std.testing.expect(std.mem.indexOf(u8, branch_log, "commit (initial): first commit") != null);

    try git.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });

    // And reading back through the front door gives what was written.
    const resolved = (try repo.head(io)).?;
    defer gpa.free(resolved.name);
    try std.testing.expectEqualStrings("refs/heads/main", resolved.name);
    try std.testing.expect(resolved.oid.eql(commit));
    try std.testing.expect((try repo.headTree(io)).?.eql(tree));
}

test "a sha256 repository this creates is one git uses" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGit(gpa, io);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var repo = repo_mod.Repository.init(gpa, io, tmp.dir, .{ .object_format = .sha256 }) catch |err| switch (err) {
        else => return err,
    };
    defer repo.deinit(io);
    try std.testing.expectEqual(hash.Kind.sha256, repo.kind);

    var git: testgit.Repo = .{ .gpa = gpa, .tmp = tmp, .dir = tmp.dir };
    const format = git.line(io, &.{ "rev-parse", "--show-object-format" }) catch return error.SkipZigTest;
    defer gpa.free(format);
    try std.testing.expectEqualStrings("sha256", format);

    try git.writeFile(io, "a.txt", "hello\n");
    var index = try repo.openIndex(io);
    defer index.deinit();
    var rules = try repo.loadIgnore(io);
    defer rules.deinit();
    var wt_rules = repo.worktreeRules();
    wt_rules.ignore = &rules;
    _ = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = wt_rules });
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});

    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .author = fixture_who,
        .committer = fixture_who,
        .message = "sha256\n",
    });
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("refs/heads/main", .{ .direct = commit }, .any);
    try tx.commit(io, null);

    var hex: [hash.max_hex_len]u8 = undefined;
    const commit_text = try gpa.dupe(u8, commit.hex(&hex));
    defer gpa.free(commit_text);
    const shown = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(commit_text, shown);
    try git.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}

test "discovery finds the repository from a subdirectory" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGit(gpa, io);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
        repo.deinit(io);
    }
    try tmp.dir.createDirPath(io, "a/b/c");
    var deep = try tmp.dir.openDir(io, "a/b/c", .{ .iterate = true });
    defer deep.close(io);

    var repo = try repo_mod.Repository.open(gpa, io, deep, .{});
    defer repo.deinit(io);
    try std.testing.expect(!repo.isBare());

    var shallow = try tmp.dir.openDir(io, "a", .{ .iterate = true });
    defer shallow.close(io);
    try std.testing.expectError(
        error.NotARepository,
        repo_mod.Repository.open(gpa, io, shallow, .{ .discover = false }),
    );
}

test "an unknown ref storage and an unknown extension are refused by name" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGit(gpa, io);

    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        {
            var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
            repo.deinit(io);
        }
        try tmp.dir.writeFile(io, .{
            .sub_path = ".git/config",
            .data = "[core]\n\trepositoryformatversion = 1\n[extensions]\n\trefStorage = lmdb\n",
        });
        try std.testing.expectError(
            error.UnsupportedRefStorage,
            repo_mod.Repository.open(gpa, io, tmp.dir, .{}),
        );
    }
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        {
            var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
            repo.deinit(io);
        }
        try tmp.dir.writeFile(io, .{
            .sub_path = ".git/config",
            .data = "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tsomethingNew = 1\n",
        });
        try std.testing.expectError(
            error.UnsupportedExtension,
            repo_mod.Repository.open(gpa, io, tmp.dir, .{}),
        );
    }
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        {
            var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
            repo.deinit(io);
        }
        try tmp.dir.writeFile(io, .{
            .sub_path = ".git/config",
            .data = "[core]\n\trepositoryformatversion = 9\n",
        });
        try std.testing.expectError(
            error.UnsupportedRepositoryVersion,
            repo_mod.Repository.open(gpa, io, tmp.dir, .{}),
        );
    }
}

test "a linked worktree is created, listed, opened, removed and pruned" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();

    try git.writeFile(io, "a.txt", "hello\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const commit_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit_text);
    const commit = try Oid.parse(.sha1, commit_text);
    const tree_text = try git.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree_text);
    const tree = try Oid.parse(.sha1, tree_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);

    try git.dir.createDirPath(io, "trees/one");
    var dest = try git.dir.openDir(io, "trees/one", .{ .iterate = true });
    const input_name = try gpa.dupe(u8, "one");
    defer gpa.free(input_name);

    var added = try worktrees.add(gpa, io, repo.common_dir, input_name, dest, "trees/one", .{
        .detach_at = commit,
    });
    defer added.admin_dir.close(io);
    defer gpa.free(added.name);
    defer added.work_dir.close(io);
    dest.close(io);
    @memset(input_name, 'x');
    try std.testing.expectEqualStrings("one", added.name);
    try added.work_dir.access(io, ".git", .{});

    // git sees it, and says it is detached at the right commit.
    const listed = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "trees/one") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, commit_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "detached") != null);

    // And this sees it too.
    var ours = try repo.listWorktrees(io);
    defer ours.deinit();
    try std.testing.expectEqual(@as(usize, 1), ours.entries.len);
    try std.testing.expectEqualStrings("one", ours.entries[0].name);
    try std.testing.expect(ours.entries[0].head.?.eql(commit));
    try std.testing.expect(!ours.entries[0].prunable);
    try std.testing.expect(!ours.entries[0].locked);

    // Opening the destination follows its `.git` file.
    {
        var linked = try repo_mod.Repository.open(gpa, io, added.work_dir, .{ .discover = false });
        defer linked.deinit(io);
        try std.testing.expect(linked.common_is_separate);
        var linked_index = try linked.openIndex(io);
        defer linked_index.deinit();
        _ = try worktree.checkout(gpa, io, added.work_dir, &linked_index, &linked.odb, tree, .{});
        try linked_index.write(io, linked.git_dir, "index", .{});
    }
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello\n", try added.work_dir.readFile(io, "a.txt", &buf));

    // git calls the linked worktree clean.
    const linked_status = try git.run(io, &.{ "-C", "trees/one", "status", "--porcelain" });
    defer gpa.free(linked_status);
    try std.testing.expectEqualStrings("", linked_status);

    // A lock stops a prune.
    try worktrees.lock(io, repo.common_dir, "one", "busy\n");
    try git.dir.deleteTree(io, "trees/one");
    {
        var locked = try repo.listWorktrees(io);
        defer locked.deinit();
        try std.testing.expect(locked.entries[0].locked);
        try std.testing.expect(locked.entries[0].prunable);
    }
    const skipped = try repo.pruneWorktrees(io);
    try std.testing.expectEqual(@as(u32, 0), skipped.removed);
    try std.testing.expectEqual(@as(u32, 1), skipped.skipped_locked);

    try worktrees.unlock(io, repo.common_dir, "one");
    const pruned = try repo.pruneWorktrees(io);
    try std.testing.expectEqual(@as(u32, 1), pruned.removed);

    var after = try repo.listWorktrees(io);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.entries.len);
    const after_git = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(after_git);
    try std.testing.expect(std.mem.indexOf(u8, after_git, "trees/one") == null);
}

test "worktree remove takes the tree and the admin directory with it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();

    try git.writeFile(io, "a.txt", "hello\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const commit_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);

    try git.dir.createDirPath(io, "trees/two");
    var dest = try git.dir.openDir(io, "trees/two", .{ .iterate = true });
    var added = try worktrees.add(gpa, io, repo.common_dir, "two", dest, "trees/two", .{
        .detach_at = try Oid.parse(.sha1, commit_text),
    });
    added.admin_dir.close(io);
    gpa.free(added.name);
    added.work_dir.close(io);
    dest.close(io);

    try worktrees.remove(gpa, io, repo.common_dir, "two", .{});
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, "trees/two", .{}));
    const listed = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "trees/two") == null);
}
