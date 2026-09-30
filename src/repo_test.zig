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
        }, null);
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
    }, null);

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
    }, null);
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

test "failed opens leave the full refused setting in caller-owned diagnostics" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
        repo.deinit(io);
    }
    var diagnostic = repo_mod.OpenDiagnostic.init(gpa);
    defer diagnostic.deinit();
    const long_name = "anextensionwhosenameislongerthantherepositorysoldsixtyfourbytebuffer";
    const cases = .{
        .{ "[core]\nrepositoryformatversion = 9\n", error.UnsupportedRepositoryVersion, "core.repositoryFormatVersion" },
        .{ "[core]\nrepositoryformatversion = 1\n[extensions]\nsomethingNew = true\n", error.UnsupportedExtension, "somethingnew" },
        .{ "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = lmdb\n", error.UnsupportedRefStorage, "extensions.refStorage" },
        .{ "[core]\nrepositoryformatversion = 1\n[extensions]\nobjectFormat = sha512\n", error.UnknownObjectFormat, "extensions.objectFormat" },
        .{ "[core]\nrepositoryformatversion = 1\n[extensions]\n" ++ long_name ++ " = true\n", error.UnsupportedExtension, long_name },
    };
    inline for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = case[0] });
        try std.testing.expectError(case[1], repo_mod.Repository.open(gpa, io, tmp.dir, .{ .diagnostic = &diagnostic }));
        try std.testing.expectEqualStrings(case[2], diagnostic.unsupported_setting);
    }
    try tmp.dir.createDir(io, "empty", .default_dir);
    var empty = try tmp.dir.openDir(io, "empty", .{});
    defer empty.close(io);
    try std.testing.expectError(error.NotARepository, repo_mod.Repository.open(gpa, io, empty, .{ .discover = false, .diagnostic = &diagnostic }));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\nrepositoryformatversion = 0\n" });
    var repo = try repo_mod.Repository.open(gpa, io, tmp.dir, .{ .diagnostic = &diagnostic });
    defer repo.deinit(io);
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
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

test "a config refresh keeps only its own refused setting" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\nrepositoryformatversion = 1\n[extensions]\nsomethingNew = true\n" });
    try std.testing.expectError(error.UnsupportedExtension, repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("somethingnew", diagnostic.unsupported_setting);
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\nrepositoryformatversion = 0\n" });
    try std.testing.expect(try repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
    try std.testing.expect(!try repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\nrepositoryformatversion = 1\n[extensions]\nobjectformat = sha256\n" });
    try std.testing.expectError(error.ObjectFormatChanged, repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("extensions.objectFormat", diagnostic.unsupported_setting);
}

test "opening uses the format validated before worktree settings are read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
        repo.deinit(io);
    }
    try tmp.dir.writeFile(io, .{
        .sub_path = ".git/config",
        .data = "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\nworktreeConfig = true\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".git/config.worktree",
        .data = "[core]\nrepositoryformatversion = 0\n[extensions]\nrefStorage = files\n",
    });
    var opened = try repo_mod.Repository.open(gpa, io, tmp.dir, .{});
    defer opened.deinit(io);
    try std.testing.expectEqual(@import("refs.zig").Format.reftable, opened.refs.format);
}

test "opening refuses a repository version that is not an integer" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
        repo.deinit(io);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\nrepositoryformatversion = invalid\n" });
    if (repo_mod.Repository.open(gpa, io, tmp.dir, .{})) |repository| {
        var opened = repository;
        opened.deinit(io);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.NotAnInteger, err);
    }
}

test "a refresh preserves a refused extension beyond sixty-four bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    const name = "anextensionwhosenameislongerthantherepositorysoldsixtyfourbytebufferandkeepsgoing";
    {
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
        defer repo.deinit(io);
        try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\nrepositoryformatversion = 1\n[extensions]\n" ++ name ++ " = true\n" });
        try std.testing.expectError(error.UnsupportedExtension, repo.refreshConfig(io, &diagnostic));
    }
    try std.testing.expectEqualStrings(name, diagnostic.unsupported_setting);
}

test "a signing write keeps only its own refused setting" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try repo.config.set("tag.gpgSign", "true");
    const fields: @import("object.zig").Tag.Fields = .{
        .target = @import("hash.zig").Hasher.object(.sha1, "tree", ""),
        .target_type = .tree,
        .name = "t",
        .message = "m",
    };
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, fields, &diagnostic));
    try std.testing.expectEqualStrings("tag.gpgSign", diagnostic.unsupported_setting);
    _ = try repo.writeTagWith(io, fields, .{ .sign = .never }, &diagnostic);
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, fields, &diagnostic));
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTagWith(io, fields, .{ .sign = .always }, &diagnostic));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, fields, &diagnostic));
    var invalid = fields;
    invalid.target = @import("hash.zig").Hasher.object(.sha256, "tree", "");
    try std.testing.expectError(error.UnexpectedObjectType, repo.writeTagWith(io, invalid, .{ .sign = .never }, &diagnostic));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
}

test "a refusal preserves the diagnostic allocator's resource failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var diagnostic = repo_mod.Diagnostic.init(failing.allocator());
    defer diagnostic.deinit();
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\nrepositoryformatversion = 9\n" });
    try std.testing.expectError(error.OutOfMemory, repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
    try std.testing.expectEqual(@as(i64, 0), try repo.config.getInt("core.repositoryformatversion", -1));
    try std.testing.expectError(error.UnsupportedRepositoryVersion, repo.refreshConfig(io, null));
    try repo.config.set("tag.gpgSign", "true");
    const fields: @import("object.zig").Tag.Fields = .{
        .target = @import("hash.zig").Hasher.object(.sha1, "tree", ""),
        .target_type = .tree,
        .name = "t",
        .message = "m",
    };
    try std.testing.expectError(error.OutOfMemory, repo.writeTag(io, fields, &diagnostic));
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, fields, null));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
}

test "a refresh changing the ref backend requires reopening and keeps the old state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]@import("refs.zig").Format{ .files, .reftable }) |format| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = format });
        defer repo.deinit(io);
        var diagnostic = repo_mod.Diagnostic.init(gpa);
        defer diagnostic.deinit();
        const cache = repo.refs.reftable_cache;
        const replacement = if (format == .files)
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n[user]\nname = changed\n"
        else
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = files\n[user]\nname = changed\n";
        try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = replacement });
        try std.testing.expectError(error.RefStorageChanged, repo.refreshConfig(io, &diagnostic));
        try std.testing.expectEqualStrings("extensions.refStorage", diagnostic.unsupported_setting);
        try std.testing.expectEqual(format, repo.refs.format);
        try std.testing.expectEqual(cache, repo.refs.reftable_cache);
        try std.testing.expect(repo.config.get("user.name") == null);
        // A refused refresh did not acknowledge the new file.
        try std.testing.expectError(error.RefStorageChanged, repo.refreshConfig(io, null));
        const restored = if (format == .files)
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = files\n[user]\nname = accepted\n"
        else
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n[user]\nname = accepted\n";
        try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = restored });
        try std.testing.expect(try repo.refreshConfig(io, &diagnostic));
        try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
        try std.testing.expectEqualStrings("accepted", repo.config.get("user.name").?);
        try std.testing.expectEqual(cache, repo.refs.reftable_cache);
    }
}

test "a signing refusal names the tag setting that required it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try repo.config.set("tag.forceSignAnnotated", "true");
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, .{
        .target = @import("hash.zig").Hasher.object(.sha1, "tree", ""),
        .target_type = .tree,
        .name = "t",
        .message = "m",
    }, &diagnostic));
    try std.testing.expectEqualStrings("tag.forceSignAnnotated", diagnostic.unsupported_setting);
}

test "a refresh updates reftable write settings together with the configuration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
    defer repo.deinit(io);
    const cache = repo.refs.reftable_cache;
    const prefix = "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n[reftable]\n";
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = prefix ++
        "blockSize = 8192\nrestartInterval = 32\nindexObjects = false\ngeometricFactor = 4\nlockTimeout = 0\n" });
    try std.testing.expect(try repo.refreshConfig(io, null));
    const options = repo.refs.reftable_options;
    try std.testing.expectEqual(@as(u32, 8192), options.write.block_size);
    try std.testing.expectEqual(@as(u16, 32), options.write.restart_interval);
    try std.testing.expect(!options.write.index_objects);
    try std.testing.expectEqual(@as(u8, 4), options.geometric_factor);
    try std.testing.expectEqual(@import("fs.zig").OnContention.fail, options.lock);
    try std.testing.expectEqual(cache, repo.refs.reftable_cache);
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = prefix ++ "blockSize = invalid\n" });
    try std.testing.expectError(error.NotAnInteger, repo.refreshConfig(io, null));
    try std.testing.expectEqualDeep(options, repo.refs.reftable_options);
    try std.testing.expectEqualStrings("8192", repo.config.get("reftable.blocksize").?);
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = prefix ++ "lockTimeout = 200\n" });
    try std.testing.expect(try repo.refreshConfig(io, null));
    try std.testing.expectEqualDeep(@import("reftablestack.zig").Options{ .lock = .{ .wait_ms = 200 } }, repo.refs.reftable_options);
    try std.testing.expectEqual(cache, repo.refs.reftable_cache);
}

test "a reftable HEAD read failure does not become a detached branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]@import("hash.zig").Kind{ .sha1, .sha256 }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .object_format = kind, .ref_format = .reftable });
        defer repo.deinit(io);
        try std.testing.expectEqualStrings("main", repo.config.context.branch.?);
        const before = try repo.git_dir.readFileAlloc(io, "reftable/tables.list", gpa, .limited(4096));
        defer gpa.free(before);
        const cases = .{
            .{ "not a table\n", error.MalformedTablesList },
            .{ "missing.ref\n", error.ReftableMissing },
        };
        inline for (cases) |case| {
            try repo.git_dir.writeFile(io, .{ .sub_path = "reftable/tables.list", .data = case[0] });
            try std.testing.expectError(case[1], repo.refreshConfig(io, null));
            try std.testing.expectEqualStrings("main", repo.config.context.branch.?);
            if (repo_mod.Repository.open(gpa, io, tmp.dir, .{})) |opened| {
                var unexpected = opened;
                unexpected.deinit(io);
                return error.TestExpectedError;
            } else |err| {
                try std.testing.expectEqual(case[1], err);
            }
        }
        try repo.git_dir.writeFile(io, .{ .sub_path = "reftable/tables.list", .data = before });
        try std.testing.expect(!try repo.refreshConfig(io, null));
        try std.testing.expectEqualStrings("main", repo.config.context.branch.?);
    }
}

test "a malformed signing policy is refused before an unsigned object is written" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ "commit.gpgSign", "tag.gpgSign", "tag.forceSignAnnotated" }) |setting| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
        defer repo.deinit(io);
        var diagnostic = repo_mod.Diagnostic.init(gpa);
        defer diagnostic.deinit();
        try repo.config.set(setting, "maybe");
        const tree = hash.Hasher.object(.sha1, "tree", "");
        if (comptime std.mem.startsWith(u8, setting, "commit.")) {
            try std.testing.expectError(error.NotABoolean, repo.writeCommit(io, .{
                .tree = tree,
                .author = fixture_who,
                .committer = fixture_who,
                .message = "m",
            }, &diagnostic));
        } else {
            try std.testing.expectError(error.NotABoolean, repo.writeTag(io, .{
                .target = tree,
                .target_type = .tree,
                .name = "t",
                .message = "m",
            }, &diagnostic));
        }
        try std.testing.expectEqualStrings(setting, diagnostic.unsupported_setting);
        var objects = try repo.git_dir.openDir(io, "objects", .{ .iterate = true });
        defer objects.close(io);
        var entries = objects.iterate();
        while (try entries.next(io)) |entry| {
            // init creates these two empty directories, and no object fanout.
            try std.testing.expect(std.mem.eql(u8, entry.name, "info") or std.mem.eql(u8, entry.name, "pack"));
        }
    }
}

test "reading a signing policy preserves allocation resource failures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    try repo.config.set("tag.gpgSign", "true");
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    repo.config.gpa = failing.allocator();
    defer repo.config.gpa = gpa;
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try std.testing.expectError(error.OutOfMemory, repo.writeTag(io, .{
        .target = hash.Hasher.object(.sha1, "tree", ""),
        .target_type = .tree,
        .name = "t",
        .message = "m",
    }, &diagnostic));
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
}

test "discovery closes its git directory when the worktree handle cannot be opened" {
    const Recorder = struct {
        opened: ?Io.Dir = null,
        closed: usize = 0,

        fn openDir(context: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            const r: *@This() = @ptrCast(@alignCast(context.?));
            if (r.opened != null) return error.ProcessFdQuotaExceeded;
            const opened = try dir.openDir(std.testing.io, path, options);
            r.opened = opened;
            return opened;
        }

        fn close(context: ?*anyopaque, dirs: []const Io.Dir) void {
            const r: *@This() = @ptrCast(@alignCast(context.?));
            for (dirs) |dir| {
                std.debug.assert(dir.handle == r.opened.?.handle);
                dir.close(std.testing.io);
                r.opened = null;
                r.closed += 1;
            }
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, ".git", .default_dir);
    var recorder: Recorder = .{};
    // Clean up even while this test is proving an unfixed leak.
    defer if (recorder.opened) |dir| dir.close(io);
    var vtable = Io.failing.vtable.*;
    vtable.dirOpenDir = Recorder.openDir;
    vtable.dirClose = Recorder.close;
    const tracked: Io = .{ .userdata = &recorder, .vtable = &vtable };
    try std.testing.expectError(error.ProcessFdQuotaExceeded, repo_mod.Repository.open(std.testing.allocator, tracked, tmp.dir, .{ .discover = false }));
    try std.testing.expectEqual(@as(usize, 1), recorder.closed);
}
