//! The front door against the real git: a repository this creates is one git
//! uses, and a commit this writes is one git shows.

const builtin = @import("builtin");
const config_mod = @import("config.zig");
const config_state = @import("config/state.zig");
const std = @import("std");
const Io = std.Io;

const testgit = @import("testing/git.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const worktrees = @import("worktree/worktrees.zig");
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
    try std.testing.expectEqual(hash.Kind.sha1, repo.objectFormat());
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

    var wt_rules = try repo.worktreeRules();
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
    try std.testing.expectEqual(hash.Kind.sha256, repo.objectFormat());

    var git: testgit.Repo = .{ .gpa = gpa, .tmp = tmp, .dir = tmp.dir };
    const format = git.line(io, &.{ "rev-parse", "--show-object-format" }) catch return error.SkipZigTest;
    defer gpa.free(format);
    try std.testing.expectEqualStrings("sha256", format);

    try git.writeFile(io, "a.txt", "hello\n");
    var index = try repo.openIndex(io);
    defer index.deinit();
    var rules = try repo.loadIgnore(io);
    defer rules.deinit();
    var wt_rules = try repo.worktreeRules();
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
    try std.testing.expectEqual(@import("refs.zig").Format.reftable, opened.refStore().refFormat());
    try opened.editConfig(&.{.{ .set = .{ .level = .local, .name = "fixture.edited", .value = "shared" } }}, null);
    try std.testing.expectEqualStrings("shared", opened.configuration().get("fixture.edited").?);
    try std.testing.expectEqual(@import("refs.zig").Format.reftable, opened.refStore().refFormat());
    try std.testing.expectError(error.RefStorageChanged, opened.editConfig(&.{.{ .set = .{ .level = .local, .name = "extensions.refstorage", .value = "files" } }}, null));
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
    try repo.editConfig(&.{.{ .set = .{ .name = "tag.gpgSign", .value = "true" } }}, null);
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
    try std.testing.expectError(error.MixedHashKinds, repo.writeTagWith(io, invalid, .{ .sign = .never }, &diagnostic));
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
    try std.testing.expectEqual(@as(i64, 0), try repo.configuration().getInt("core.repositoryformatversion", -1));
    try std.testing.expectError(error.UnsupportedRepositoryVersion, repo.refreshConfig(io, null));
    try repo.editConfig(&.{.{ .set = .{ .name = "tag.gpgSign", .value = "true" } }}, null);
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
        const cache = @import("refs/state.zig").get(repo.refStore()._state).cache;
        const replacement = if (format == .files)
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n[user]\nname = changed\n"
        else
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = files\n[user]\nname = changed\n";
        try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = replacement });
        try std.testing.expectError(error.RefStorageChanged, repo.refreshConfig(io, &diagnostic));
        try std.testing.expectEqualStrings("extensions.refStorage", diagnostic.unsupported_setting);
        try std.testing.expectEqual(format, repo.refStore().refFormat());
        try std.testing.expectEqual(cache, @import("refs/state.zig").get(repo.refStore()._state).cache);
        try std.testing.expect(repo.configuration().get("user.name") == null);
        // A refused refresh did not acknowledge the new file.
        try std.testing.expectError(error.RefStorageChanged, repo.refreshConfig(io, null));
        const restored = if (format == .files)
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = files\n[user]\nname = accepted\n"
        else
            "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n[user]\nname = accepted\n";
        try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = restored });
        try std.testing.expect(try repo.refreshConfig(io, &diagnostic));
        try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
        try std.testing.expectEqualStrings("accepted", repo.configuration().get("user.name").?);
        try std.testing.expectEqual(cache, @import("refs/state.zig").get(repo.refStore()._state).cache);
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
    try repo.editConfig(&.{.{ .set = .{ .name = "tag.forceSignAnnotated", .value = "true" } }}, null);
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
    const cache = @import("refs/state.zig").get(repo.refStore()._state).cache;
    const prefix = "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n[reftable]\n";
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = prefix ++
        "blockSize = 8192\nrestartInterval = 32\nindexObjects = false\ngeometricFactor = 4\nlockTimeout = 0\n" });
    try std.testing.expect(try repo.refreshConfig(io, null));
    const options = repo.refStore().reftableOptions();
    try std.testing.expectEqual(@as(u32, 8192), options.write.block_size);
    try std.testing.expectEqual(@as(u16, 32), options.write.restart_interval);
    try std.testing.expect(!options.write.index_objects);
    try std.testing.expectEqual(@as(u8, 4), options.geometric_factor);
    try std.testing.expectEqual(@import("repo/fs.zig").OnContention.fail, options.lock);
    try std.testing.expectEqual(cache, @import("refs/state.zig").get(repo.refStore()._state).cache);
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = prefix ++ "blockSize = invalid\n" });
    try std.testing.expectError(error.NotAnInteger, repo.refreshConfig(io, null));
    try std.testing.expectEqualDeep(options, repo.refStore().reftableOptions());
    try std.testing.expectEqualStrings("8192", repo.configuration().get("reftable.blocksize").?);
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = prefix ++ "lockTimeout = 200\n" });
    try std.testing.expect(try repo.refreshConfig(io, null));
    try std.testing.expectEqualDeep(@import("refs/reftablestack.zig").Options{ .lock = .{ .wait_ms = 200 } }, repo.refStore().reftableOptions());
    try std.testing.expectEqual(cache, @import("refs/state.zig").get(repo.refStore()._state).cache);
}

test "a reftable HEAD read failure does not become a detached branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]@import("hash.zig").Kind{ .sha1, .sha256 }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .object_format = kind, .ref_format = .reftable });
        defer repo.deinit(io);
        try std.testing.expectEqualStrings("main", repo.configuration().context.branch.?);
        const before = try repo.git_dir.readFileAlloc(io, "reftable/tables.list", gpa, .limited(4096));
        defer gpa.free(before);
        const cases = .{
            .{ "not a table\n", error.MalformedTablesList },
            .{ "missing.ref\n", error.ReftableMissing },
        };
        inline for (cases) |case| {
            try repo.git_dir.writeFile(io, .{ .sub_path = "reftable/tables.list", .data = case[0] });
            try std.testing.expectError(case[1], repo.refreshConfig(io, null));
            try std.testing.expectEqualStrings("main", repo.configuration().context.branch.?);
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
        try std.testing.expectEqualStrings("main", repo.configuration().context.branch.?);
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
        try repo.editConfig(&.{.{ .set = .{ .name = setting, .value = "maybe" } }}, null);
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
    try repo.editConfig(&.{.{ .set = .{ .name = "tag.gpgSign", .value = "true" } }}, null);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    config_state.get(repo._config).gpa = failing.allocator();
    defer config_state.get(repo._config).gpa = gpa;
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

test "a commondir that cannot be opened is not replaced by the worktree directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
        repo.deinit(io);
    }
    var git_dir = try tmp.dir.openDir(io, ".git", .{});
    defer git_dir.close(io);
    try git_dir.writeFile(io, .{ .sub_path = "not-a-directory", .data = "file\n" });
    try tmp.dir.createDir(io, "linked", .default_dir);
    var linked = try tmp.dir.openDir(io, "linked", .{});
    defer linked.close(io);
    try linked.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: ../.git\n" });
    const cases = .{
        .{ "missing-common-dir\n", error.FileNotFound },
        .{ "not-a-directory\n", error.NotDir },
    };
    inline for (cases) |case| {
        try git_dir.writeFile(io, .{ .sub_path = "commondir", .data = case[0] });
        for ([_]Io.Dir{ tmp.dir, git_dir, linked }) |dir| {
            if (repo_mod.Repository.open(gpa, io, dir, .{ .discover = false })) |opened| {
                var unexpected = opened;
                unexpected.deinit(io);
                return error.TestExpectedError;
            } else |err| {
                try std.testing.expectEqual(case[1], err);
            }
        }
    }
}

test "a signer configuration refusal names its setting in caller-owned output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    const request: @import("commit/signing.zig").Request = .{ .sign = .always, .programs = .{ .environ = &environ } };
    inline for (.{
        .{ "gpg.format", "new-format", error.UnknownSignatureFormat, "openpgp" },
        .{ "gpg.minTrustLevel", "new-level", error.UnknownTrustLevel, "undefined" },
    }) |case| {
        try repo.editConfig(&.{.{ .set = .{ .name = case[0], .value = case[1] } }}, null);
        try std.testing.expectError(case[2], repo.writeTagWith(io, .{
            .target = hash.Hasher.object(.sha1, "tree", ""),
            .target_type = .tree,
            .name = "t",
            .message = "m",
        }, request, &diagnostic));
        try std.testing.expectEqualStrings(case[0], diagnostic.unsupported_setting);
        try repo.editConfig(&.{.{ .set = .{ .name = case[0], .value = case[3] } }}, null);
    }
}

test "a malformed worktree configuration policy is refused instead of disabling the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try repo.git_dir.writeFile(io, .{ .sub_path = "config.worktree", .data = "[user]\nname = worktree\n" });
    const shared = "[core]\nrepositoryformatversion = 1\n[extensions]\nworktreeConfig = ";
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = shared ++ "maybe\n" });
    try std.testing.expectError(error.NotABoolean, repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("extensions.worktreeConfig", diagnostic.unsupported_setting);
    try std.testing.expect(repo.configuration().get("user.name") == null);
    if (repo_mod.Repository.open(gpa, io, tmp.dir, .{ .diagnostic = &diagnostic })) |opened| {
        var unexpected = opened;
        unexpected.deinit(io);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.NotABoolean, err);
        try std.testing.expectEqualStrings("extensions.worktreeConfig", diagnostic.unsupported_setting);
    }
    try repo.git_dir.writeFile(io, .{ .sub_path = "config", .data = shared ++ "true\n" });
    try std.testing.expect(try repo.refreshConfig(io, &diagnostic));
    try std.testing.expectEqualStrings("worktree", repo.configuration().get("user.name").?);
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
}

test "repository writes preserve signature and hash refusals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    const tree = hash.Hasher.object(.sha1, "tree", "");
    var invalid = fixture_who;
    invalid.name = "broken\nname";
    try std.testing.expectError(error.InvalidSignature, repo.writeCommit(io, .{
        .tree = tree,
        .author = invalid,
        .committer = fixture_who,
        .message = "m",
    }, null));
    try std.testing.expectError(error.MixedHashKinds, repo.writeCommit(io, .{
        .tree = hash.Hasher.object(.sha256, "tree", ""),
        .author = fixture_who,
        .committer = fixture_who,
        .message = "m",
    }, null));
    try std.testing.expectError(error.InvalidSignature, repo.writeTag(io, .{
        .target = tree,
        .target_type = .tree,
        .name = "t",
        .tagger = invalid,
        .message = "m",
    }, null));
    try std.testing.expectError(error.MixedHashKinds, repo.writeTag(io, .{
        .target = hash.Hasher.object(.sha256, "tree", ""),
        .target_type = .tree,
        .name = "t",
        .message = "m",
    }, null));
}

test "worktree configuration adapters refuse malformed settings and allocation failures" {
    const Adapter = struct {
        fn core(r: *const repo_mod.Repository) !worktree.attributes.CoreSettings {
            return try r.coreSettings();
        }
        fn rules(r: *const repo_mod.Repository) !worktree.Rules {
            return try r.worktreeRules();
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    inline for (.{ "core.autocrlf", "core.safecrlf", "core.ignorecase", "core.filemode", "core.symlinks" }) |setting| {
        try repo.editConfig(&.{.{ .set = .{ .name = setting, .value = "maybe" } }}, null);
        try std.testing.expectError(error.NotABoolean, Adapter.rules(&repo));
        try repo.editConfig(&.{.{ .set = .{ .name = setting, .value = "false" } }}, null);
    }
    inline for (.{ "core.eol", "core.checkstat" }) |setting| {
        try repo.editConfig(&.{.{ .set = .{ .name = setting, .value = "unknown" } }}, null);
        try std.testing.expectError(error.MalformedValue, Adapter.rules(&repo));
        try repo.editConfig(&.{.{ .set = .{ .name = setting, .value = if (comptime std.mem.eql(u8, setting, "core.eol")) "native" else "default" } }}, null);
    }
    config_state.get(repo._config).deinit();
    config_state.get(repo._config).* = try config_mod.Config.parseText(gpa, "[core]\n autocrlf = \"input\"\n", .local);
    try std.testing.expectEqual(worktree.attributes.CoreSettings.AutoCrlf.input, (try Adapter.core(&repo)).autocrlf);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    config_state.get(repo._config).gpa = failing.allocator();
    defer config_state.get(repo._config).gpa = gpa;
    try std.testing.expectError(error.OutOfMemory, Adapter.core(&repo));
}

test "repository format and ref cache state have no writable public fields" {
    try std.testing.expect(!@hasField(repo_mod.Repository, "kind"));
    try std.testing.expect(!@hasField(repo_mod.Repository, "refs"));
    const Store = @import("refs.zig").Store;
    inline for (.{ "kind", "format", "reftable_options", "reftable_cache", "git_dir", "common_dir", "gpa" }) |field| {
        try std.testing.expect(!@hasField(Store, field));
    }
}

test "rule loaders preserve malformed case policy and allocation failures" {
    const Load = struct {
        fn ignoreRules(r: *repo_mod.Repository, io: Io) !void {
            var rules = try r.loadIgnore(io);
            defer rules.deinit();
        }
        fn attributesRules(r: *repo_mod.Repository, io: Io) !void {
            var rules = try r.loadAttrs(io);
            defer rules.deinit();
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer r.deinit(io);
    try r.editConfig(&.{.{ .set = .{ .name = "core.ignorecase", .value = "maybe" } }}, null);
    try std.testing.expectError(error.NotABoolean, Load.ignoreRules(&r, io));
    try std.testing.expectError(error.NotABoolean, Load.attributesRules(&r, io));
    try r.editConfig(&.{.{ .set = .{ .name = "core.ignorecase", .value = "true" } }}, null);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    config_state.get(r._config).gpa = failing.allocator();
    defer config_state.get(r._config).gpa = gpa;
    try std.testing.expectError(error.OutOfMemory, Load.ignoreRules(&r, io));
    failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Load.attributesRules(&r, io));
}

test "required filter discovery keeps full names and resource failures" {
    const Read = struct {
        fn count(r: *repo_mod.Repository) !usize {
            const names = try r.requiredFilters(r.gpa);
            defer r.gpa.free(names);
            return names.len;
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer r.deinit(io);
    const long_name = "x" ** 300;
    try r.editConfig(&.{.{ .set = .{ .name = "filter." ++ long_name ++ ".required", .value = "true" } }}, null);
    const names = try r.requiredFilters(gpa);
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings(long_name, names[0]);
    // The query's allocation and the value decoder's allocation have owners.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    config_state.get(r._config).gpa = failing.allocator();
    defer config_state.get(r._config).gpa = gpa;
    try std.testing.expectError(error.OutOfMemory, Read.count(&r));
}

test "required filter discovery refuses malformed required policy" {
    const Read = struct {
        fn run(r: *repo_mod.Repository) !void {
            const names = try r.requiredFilters(r.gpa);
            defer r.gpa.free(names);
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer r.deinit(io);
    try r.editConfig(&.{.{ .set = .{ .name = "filter.needed.required", .value = "maybe" } }}, null);
    try std.testing.expectError(error.NotABoolean, Read.run(&r));
}

test "object backend and repository configuration have opaque owners" {
    inline for (.{ "kind", "options", "sources", "cache", "generation", "deflate_window", "deflate_state", "gpa" }) |field| {
        try std.testing.expect(!@hasField(@import("odb.zig").Odb, field));
    }
    try std.testing.expect(!@hasField(repo_mod.Repository, "config"));
}

test "repository configuration edits publish policy only after validating the whole change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try repo_mod.Repository.init(gpa, io, tmp.dir, .{});
    defer r.deinit(io);
    var diagnostic = repo_mod.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    try std.testing.expectError(error.ObjectFormatChanged, r.editConfig(&.{
        .{ .set = .{ .name = "fixture.value", .value = "discard" } },
        .{ .set = .{ .name = "core.repositoryformatversion", .value = "1" } },
        .{ .set = .{ .name = "extensions.objectformat", .value = "sha256" } },
    }, &diagnostic));
    try std.testing.expect(r.configuration().get("fixture.value") == null);
    try std.testing.expectEqualStrings("extensions.objectFormat", diagnostic.unsupported_setting);
    try std.testing.expectEqual(hash.Kind.sha1, r.odb.objectFormat());
    try std.testing.expectError(error.RefStorageChanged, r.editConfig(&.{
        .{ .set = .{ .name = "core.repositoryformatversion", .value = "1" } },
        .{ .set = .{ .name = "extensions.refstorage", .value = "reftable" } },
    }, &diagnostic));
    try std.testing.expectEqual(@import("refs.zig").Format.files, r.refStore().refFormat());
    try std.testing.expectError(error.WorktreeConfigChanged, r.editConfig(&.{.{ .set = .{ .name = "extensions.worktreeconfig", .value = "true" } }}, &diagnostic));
    try std.testing.expectEqualStrings("extensions.worktreeConfig", diagnostic.unsupported_setting);
    try std.testing.expect(r.configuration().sources.worktree == null);
    try r.editConfig(&.{.{ .set = .{ .name = "fixture.value", .value = "published" } }}, &diagnostic);
    try std.testing.expectEqualStrings("published", r.configuration().get("fixture.value").?);
    try std.testing.expectEqualStrings("", diagnostic.unsupported_setting);
}

test "repository configuration edit copies keep their owners when allocation stops" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var r = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable, .odb = .{ .probe_timestamp_resolution = false } });
            defer r.deinit(io);
            try r.editConfig(&.{.{ .set = .{ .name = "fixture.kept", .value = "before" } }}, null);
            r.editConfig(&.{
                .{ .set = .{ .name = "fixture.kept", .value = "yes", .level = .local } },
                .{ .set = .{ .name = "reftable.blocksize", .value = "8192" } },
                .{ .set = .{ .name = "fixture.removed", .value = "no" } },
                .{ .unset = .{ .name = "fixture.removed" } },
            }, null) catch |err| {
                try std.testing.expectEqualStrings("before", r.configuration().get("fixture.kept").?);
                try std.testing.expectEqual(@as(u32, 4096), r.refStore().reftableOptions().write.block_size);
                return err;
            };
            try std.testing.expectEqualStrings("yes", r.configuration().get("fixture.kept").?);
            try std.testing.expect(r.configuration().get("fixture.removed") == null);
            try std.testing.expectEqual(@as(usize, 8192), r.refStore().reftableOptions().write.block_size);
            try config_state.get(r._config).write(io, r.common_dir, "config");
            _ = try r.refreshConfig(io, null);
            try std.testing.expectEqualStrings("yes", r.configuration().get("fixture.kept").?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

/// `path`, as `git -C <where> rev-parse --git-path` prints it (relative
/// to `where` unless absolute), with its folder's symbolic links resolved:
/// two spellings of one file compare equal even when it is not there.
fn resolvedPath(gpa: std.mem.Allocator, io: Io, base: Io.Dir, where: []const u8, path: []const u8) ![]u8 {
    var at = try base.openDir(io, where, .{});
    defer at.close(io);
    const dir = try at.realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, std.fs.path.basename(path) });
}

test "the ignore sources and the index are named where git reads them, in a linked worktree too" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    try git.exec(io, &.{ "worktree", "add", "-q", "-b", "side", "linked" });
    const excludes = try git.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(excludes);
    const excludes_file = try std.fs.path.join(gpa, &.{ excludes, "excludes" });
    defer gpa.free(excludes_file);
    try git.exec(io, &.{ "config", "core.excludesFile", excludes_file });

    for ([_][]const u8{ ".", "linked" }) |where| {
        var dir = try git.dir.openDir(io, where, .{ .iterate = true });
        defer dir.close(io);
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{ .discover = false });
        defer repo.deinit(io);

        const index = try repo.indexPath(gpa, io);
        defer gpa.free(index);
        const git_index = try git.line(io, &.{ "-C", where, "rev-parse", "--git-path", "index" });
        defer gpa.free(git_index);
        const want_index = try resolvedPath(gpa, io, git.dir, where, git_index);
        defer gpa.free(want_index);
        try std.testing.expectEqualStrings(want_index, index);

        var sources = try repo.ignoreSources(gpa, io);
        defer sources.deinit(gpa);
        const git_exclude = try git.line(io, &.{ "-C", where, "rev-parse", "--git-path", "info/exclude" });
        defer gpa.free(git_exclude);
        const want_exclude = try resolvedPath(gpa, io, git.dir, where, git_exclude);
        defer gpa.free(want_exclude);
        try std.testing.expectEqualStrings(want_exclude, sources.info_exclude);
        try std.testing.expectEqualStrings(excludes_file, sources.excludes_file.?);
    }
    try git.exec(io, &.{ "config", "--unset", "core.excludesFile" });
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    var sources = try repo.ignoreSources(gpa, io);
    defer sources.deinit(gpa);
    try std.testing.expect(sources.excludes_file == null);
}

test "the git directory of a working tree is found without opening the repository, through a .git file too" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    try git.exec(io, &.{ "worktree", "add", "-q", "-b", "side", "linked" });
    try git.dir.createDirPath(io, "plain");
    for ([_][]const u8{ ".", "linked" }) |where| {
        var dir = try git.dir.openDir(io, where, .{});
        defer dir.close(io);
        var found = try repo_mod.Repository.gitDirOf(gpa, io, dir);
        defer found.close(io);
        const got = try found.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(got);
        const said = try git.line(io, &.{ "-C", where, "rev-parse", "--absolute-git-dir" });
        defer gpa.free(said);
        const want = try Io.Dir.cwd().realPathFileAlloc(io, said, gpa);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
    var plain = try git.dir.openDir(io, "plain", .{});
    defer plain.close(io);
    try std.testing.expectError(error.NotARepository, repo_mod.Repository.gitDirOf(gpa, io, plain));
}

/// What `git init` decided about the file system, read from what it wrote,
/// for an `init` to record the same.
fn probedOptions(gpa: std.mem.Allocator, io: Io, config_text: []const u8) repo_mod.InitOptions {
    _ = gpa;
    _ = io;
    var options: repo_mod.InitOptions = .{};
    options.file_mode = std.mem.indexOf(u8, config_text, "filemode = true") != null;
    options.ignore_case = std.mem.indexOf(u8, config_text, "ignorecase = true") != null;
    options.symlinks = std.mem.indexOf(u8, config_text, "symlinks = false") == null;
    if (std.mem.indexOf(u8, config_text, "precomposeunicode = true") != null) options.precompose_unicode = true;
    if (std.mem.indexOf(u8, config_text, "precomposeunicode = false") != null) options.precompose_unicode = false;
    return options;
}

/// Every path under a `.git` with its contents, a directory's empty.
fn treeOf(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !std.array_hash_map.String([]u8) {
    var out: std.array_hash_map.String([]u8) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const path = try gpa.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const bytes: []u8 = switch (entry.kind) {
            .file => try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)),
            .sym_link => blk: {
                var buf: [Io.Dir.max_path_bytes]u8 = undefined;
                const n = try dir.readLink(io, entry.path, &buf);
                break :blk try std.fmt.allocPrint(gpa, "-> {s}", .{buf[0..n]});
            },
            else => try gpa.dupe(u8, ""),
        };
        try out.put(gpa, path, bytes);
    }
    return out;
}

fn freeTree(gpa: std.mem.Allocator, tree: *std.array_hash_map.String([]u8)) void {
    for (tree.keys(), tree.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    tree.deinit(gpa);
}

/// `git init --template=<template>` in one directory and `init` with the
/// same template in another, compared path by path and byte by byte.
fn compareInit(gpa: std.mem.Allocator, io: Io, scratch: *testgit.Repo, template: []const u8, git_args: []const []const u8, shared: ?repo_mod.fs.Shared) !void {
    const by_git = try std.fmt.allocPrint(gpa, "by-git-{s}", .{template});
    defer gpa.free(by_git);
    const by_relic = try std.fmt.allocPrint(gpa, "by-relic-{s}", .{template});
    defer gpa.free(by_relic);
    const template_path = try scratch.dir.realPathFileAlloc(io, template, gpa);
    defer gpa.free(template_path);
    const template_arg = try std.fmt.allocPrint(gpa, "--template={s}", .{template_path});
    defer gpa.free(template_arg);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "init", "-q", "-b", "main", template_arg });
    try argv.appendSlice(gpa, git_args);
    try argv.append(gpa, by_git);
    try scratch.exec(io, argv.items);
    var git_dir = try scratch.dir.openDir(io, by_git, .{ .iterate = true });
    defer git_dir.close(io);
    const git_config = try git_dir.readFileAlloc(io, ".git/config", gpa, .limited(1 << 20));
    defer gpa.free(git_config);
    var options = probedOptions(gpa, io, git_config);
    options.shared = shared;
    var template_dir = try scratch.dir.openDir(io, template, .{ .iterate = true });
    defer template_dir.close(io);
    options.template = template_dir;
    try scratch.dir.createDir(io, by_relic, .default_dir);
    var relic_dir = try scratch.dir.openDir(io, by_relic, .{ .iterate = true });
    defer relic_dir.close(io);
    var repo = try repo_mod.Repository.init(gpa, io, relic_dir, options);
    repo.deinit(io);

    var theirs_dir = try git_dir.openDir(io, ".git", .{ .iterate = true });
    defer theirs_dir.close(io);
    var ours_dir = try relic_dir.openDir(io, ".git", .{ .iterate = true });
    defer ours_dir.close(io);
    var theirs = try treeOf(gpa, io, theirs_dir);
    defer freeTree(gpa, &theirs);
    var ours = try treeOf(gpa, io, ours_dir);
    defer freeTree(gpa, &ours);
    for (theirs.keys(), theirs.values()) |path, bytes| {
        const mine = ours.get(path) orelse {
            std.debug.print("{s}: relic did not write {s}\n", .{ template, path });
            return error.TestUnexpectedResult;
        };
        std.testing.expectEqualStrings(bytes, mine) catch |err| {
            std.debug.print("{s}: {s} differs\n", .{ template, path });
            return err;
        };
        if (!Io.File.Permissions.has_executable_bit) continue;
        const a = (try theirs_dir.statFile(io, path, .{ .follow_symlinks = false })).permissions;
        const b = (try ours_dir.statFile(io, path, .{ .follow_symlinks = false })).permissions;
        std.testing.expectEqual(a, b) catch |err| {
            std.debug.print("{s}: {s} has other permissions\n", .{ template, path });
            return err;
        };
    }
    // relic makes `info/` whether a template does or not
    for (ours.keys()) |path| {
        if (theirs.get(path) == null and !std.mem.eql(u8, path, "info")) {
            std.debug.print("{s}: relic wrote {s} and git did not\n", .{ template, path });
            return error.TestUnexpectedResult;
        }
    }
}

test "init copies a template and starts from its configuration, as git init does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try testgit.Repo.init(gpa, io, &.{});
    defer scratch.deinit();
    // a template with a configuration of its own, hooks, a dotfile and a
    // symbolic link
    try scratch.writeFile(io, "full/description", "a repository\n");
    try scratch.writeFile(io, "full/config", "[core]\n\tlogallrefupdates = false\n[user]\n\tname = Template\n");
    try scratch.writeFile(io, "full/hooks/pre-commit", "#!/bin/sh\nexit 0\n");
    if (Io.File.Permissions.has_executable_bit) try scratch.dir.setFilePermissions(io, "full/hooks/pre-commit", .fromMode(0o755), .{});
    try scratch.writeFile(io, "full/info/exclude", "*.tmp\n");
    try scratch.writeFile(io, "full/.hidden", "not copied\n");
    try scratch.dir.createDirPath(io, "full/empty");
    if (builtin.os.tag != .windows) try scratch.dir.symLink(io, "description", "full/link", .{});
    try compareInit(gpa, io, &scratch, "full", &.{}, null);
    // a template without a configuration
    try scratch.writeFile(io, "plain/description", "plain\n");
    try scratch.writeFile(io, "plain/info/exclude", "x\n");
    try compareInit(gpa, io, &scratch, "plain", &.{}, null);
    // a template of a format git does not take is not copied at all
    try scratch.writeFile(io, "future/config", "[core]\n\trepositoryformatversion = 9\n");
    try scratch.writeFile(io, "future/info/exclude", "x\n");
    try compareInit(gpa, io, &scratch, "future", &.{}, null);
    // shared, by the argument and by the template's own setting
    try scratch.writeFile(io, "empty/.keep", "");
    if (try testgit.gitAtLeast(gpa, io, 2, 31)) {
        try compareInit(gpa, io, &scratch, "empty", &.{"--shared=group"}, .group);
        try scratch.writeFile(io, "mode/info/exclude", "x\n");
        try compareInit(gpa, io, &scratch, "mode", &.{"--shared=0640"}, .{ .mode = 0o640 });
        try scratch.writeFile(io, "all/config", "[core]\n\tsharedrepository = all\n");
        try scratch.writeFile(io, "all/info/exclude", "x\n");
        try compareInit(gpa, io, &scratch, "all", &.{}, null);
    }
}

test "init.templateDir names the template git init copies" {
    const gpa = std.testing.allocator;
    var config = try config_mod.Config.parseText(gpa, "[init]\n\ttemplateDir = ~/templates\n", .global);
    defer config.deinit();
    config.context.home = "/home/someone";
    const path = (try repo_mod.templateDir(gpa, &config)).?;
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/home/someone/templates", path);
}
