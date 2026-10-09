//! Symlink traversal: a write, a read or a removal that a symbolic link
//! carries out of the working tree or out of a repository -- a link a patch
//! or a tree makes and then writes through, a link a filesystem's folding
//! makes of a directory, a link in a repository being cloned. Writes are
//! closed where they are made: `worktree.zig`'s leading-directory check
//! (the architecture's `checkout/`) for checkout and merge, `patch/apply.zig`
//! for patches, `submodule.zig` for submodule paths. A repository cloned
//! from this machine is read object by object and never copied as files
//! (`transport/local.zig`), so what a link in it points at reaches a clone
//! only as an object its refs name.

const local = @import("../../transport/local.zig");
const std = @import("std");
const filter_mod = @import("../../lfs/filter.zig");
const path_mod = @import("../../names/path.zig");
const suite = @import("../helpers.zig");
const builtin = @import("builtin");
const Io = std.Io;

const apply = @import("../../patch/apply.zig");
const repo_mod = @import("../../repo/repo.zig");
const worktree = @import("../../checkout/checkout.zig");
const index_mod = @import("../../index/index.zig");
const clone_mod = @import("../../transport/clone.zig");
const transport = @import("../../transport/transport.zig");
const submodule = @import("../../submodule/submodule.zig");
const object = @import("../../object/object.zig");
const hash = @import("../../hash/hash.zig");
const hostile = @import("hostile.zig");
const testgit = @import("../git.zig");

const Repository = repo_mod.Repository;
const who: object.Signature = .{ .name = "S", .email = "s@example.com", .when_secs = 1, .offset_minutes = 0 };
/// A link needs a privilege on Windows, where git writes one as a file.
const links = builtin.target.os.tag != .windows;

/// Apply `patch` to the working tree of `git`, and say whether relic
/// refused it.
fn refuses(gpa: std.mem.Allocator, io: Io, git: *testgit.Repo, patch: []const u8, options: apply.Options) !bool {
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var outcome = apply.apply(gpa, io, &repo, patch, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return true,
    };
    defer outcome.deinit();
    return !outcome.clean();
}

fn add(comptime path: []const u8) []const u8 {
    return "diff --git a/" ++ path ++ " b/" ++ path ++ "\nnew file mode 100644\n--- /dev/null\n+++ b/" ++ path ++ "\n@@ -0,0 +1 @@\n+evil\n";
}

fn symlink(comptime path: []const u8, comptime target: []const u8) []const u8 {
    return "diff --git a/" ++ path ++ " b/" ++ path ++ "\nnew file mode 120000\n--- /dev/null\n+++ b/" ++ path ++ "\n@@ -0,0 +1 @@\n+" ++ target ++ "\n\\ No newline at end of file\n";
}

test "git 2.3.3, t4139-apply-escape and t4122-apply-symlink-inside: apply writes, reads and deletes nothing outside the working tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var outer = try testgit.Repo.init(gpa, io, &.{});
    defer outer.deinit();
    try outer.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    // The repository one level down, as git's test puts it, so `../foo`
    // is a file the test owns.
    try outer.dir.createDirPath(io, "inside");
    var inside = outer;
    inside.dir = try outer.dir.openDir(io, "inside", .{ .iterate = true });
    defer inside.dir.close(io);
    try inside.exec(io, &.{ "init", "-q" });

    try std.testing.expect(try refuses(gpa, io, &inside, add("../foo"), .{}));
    try std.testing.expect(try refuses(gpa, io, &inside, add("../foo"), .{ .target = .index }));
    try std.testing.expectError(error.FileNotFound, outer.dir.access(io, "foo", .{}));
    try outer.writeFile(io, "foo", "evil\n");
    try std.testing.expect(try refuses(gpa, io, &inside, "diff --git a/../foo b/../foo\ndeleted file mode 100644\n--- a/../foo\n+++ /dev/null\n@@ -1 +0,0 @@\n-evil\n", .{}));
    try outer.dir.access(io, "foo", .{});
    try outer.dir.deleteFile(io, "foo");
    if (!links) return;
    const outer_path = try outer.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(outer_path);
    const absolute = try gpa.print("diff --git a/tmp b/tmp\nnew file mode 120000\n--- /dev/null\n+++ b/tmp\n@@ -0,0 +1 @@\n+{s}\n\\ No newline at end of file\n" ++ comptime add("tmp/foo"), .{outer_path});
    defer gpa.free(absolute);
    for ([_][]const u8{ comptime symlink("tmp", "..") ++ add("tmp/foo"), absolute }) |patch| {
        try std.testing.expect(try refuses(gpa, io, &inside, patch, .{}));
        try std.testing.expectError(error.FileNotFound, inside.dir.access(io, "tmp", .{}));
        try std.testing.expectError(error.FileNotFound, outer.dir.access(io, "foo", .{}));
    }
    // t4122: a change read from past a link in the working tree.
    try inside.writeFile(io, "elsewhere/file", "line\n");
    try inside.dir.symLink(io, "elsewhere", "dir", .{ .is_directory = true });
    try std.testing.expect(try refuses(gpa, io, &inside, "diff --git a/dir/file b/dir/file\n--- a/dir/file\n+++ b/dir/file\n@@ -1 +1 @@\n-line\n+changed\n", .{}));
    const kept = try inside.readFile(io, "elsewhere/file");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("line\n", kept);
}

test "CVE-2023-23946, t4115-apply-symlink 'symlink escape when creating new files', '...modifying file' and '...deleting file': nothing goes through a link the patch itself renames" {
    if (!links) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.dir.symLink(io, ".git", "symlink", .{});
    try git.exec(io, &.{ "add", "symlink" });
    try git.exec(io, &.{ "commit", "-q", "-m", "add symlink" });
    try git.writeFile(io, ".git/modify-me", "");
    try git.writeFile(io, ".git/delete-me", "");
    const rename = "diff --git a/symlink b/renamed-symlink\nsimilarity index 100%\nrename from symlink\nrename to renamed-symlink\n--\n";
    for ([_][]const u8{
        rename ++ "diff --git /dev/null b/renamed-symlink/create-me\nnew file mode 100644\nindex 0000000..039727e\n--- /dev/null\n+++ b/renamed-symlink/create-me\n@@ -0,0 +1,1 @@\n+busted\n",
        rename ++ "diff --git a/renamed-symlink/modify-me b/renamed-symlink/modify-me\nindex 1111111..2222222 100644\n--- a/renamed-symlink/modify-me\n+++ b/renamed-symlink/modify-me\n@@ -0,0 +1,1 @@\n+busted\n",
        rename ++ "diff --git a/renamed-symlink/delete-me b/renamed-symlink/delete-me\ndeleted file mode 100644\nindex 1111111..0000000 100644\n",
    }) |patch| {
        try std.testing.expect(try refuses(gpa, io, &git, patch, .{}));
    }
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, ".git/create-me", .{}));
    const modified = try git.readFile(io, ".git/modify-me");
    defer gpa.free(modified);
    try std.testing.expectEqualStrings("", modified);
    try git.dir.access(io, ".git/delete-me", .{});
}

test "CVE-2023-25652, t4115-apply-symlink '--reject removes .rej symlink if it exists': a reject is written in the working tree, never through a link" {
    if (!links) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "file.t", "file\n");
    try git.exec(io, &.{ "add", "file.t" });
    try git.exec(io, &.{ "commit", "-q", "-m", "file" });
    try git.writeFile(io, "file.t", "modified\n");
    const patch = try git.run(io, &.{ "diff", "--", "file.t" });
    defer gpa.free(patch);
    try git.writeFile(io, "file.t", "modified-again\n");
    try git.dir.symLink(io, "foo", "file.t.rej", .{});

    try std.testing.expect(try refuses(gpa, io, &git, patch, .{ .reject = true }));
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, "foo", .{}));
    const rej = try git.dir.statFile(io, "file.t.rej", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.file, rej.kind);
}

test "CVE-2021-21300, t0021-conversion 'delayed checkout with case-collision don't write to the wrong place': a delayed file is not written through a link that took its directory's name" {
    if (!links) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    const filter = try testgit.fixtureCommand(gpa, suite.path(.filter_helper), "--delay");
    defer gpa.free(filter);
    const Mode = struct { dir: []const u8, link: []const u8 };
    for ([_]Mode{ .{ .dir = "A", .link = "a" }, .{ .dir = "a\u{308}", .link = "\u{e4}" } }) |mode| {
        for ([_][]const u8{ "true", "false" }) |ignore_case| {
            var git = try testgit.Repo.init(gpa, io, &.{});
            defer git.deinit();
            try git.exec(io, &.{ "config", "filter.delay.process", filter });
            try git.exec(io, &.{ "config", "filter.delay.required", "true" });
            // The names go into the index as they are spelled here.
            try git.exec(io, &.{ "config", "core.precomposeunicode", "false" });
            try git.dir.createDirPath(io, "target-dir");
            const target = try git.dir.realPathFileAlloc(io, "target-dir", gpa);
            defer gpa.free(target);
            const empty = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "");
            defer gpa.free(empty);
            const pointer = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, target);
            defer gpa.free(pointer);
            const attr_text = try gpa.print("{s}/z filter=delay\n", .{mode.dir});
            defer gpa.free(attr_text);
            const attr = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, attr_text);
            defer gpa.free(attr);
            const e = std.mem.trimEnd(u8, empty, "\n");
            const objs = try gpa.print("100644 blob {s}\t{s}/x\n100644 blob {s}\t{s}/y\n100644 blob {s}\t{s}/z\n120000 blob {s}\t{s}\n100644 blob {s}\t.gitattributes\n", .{
                e, mode.dir, e, mode.dir, e, mode.dir, std.mem.trimEnd(u8, pointer, "\n"), mode.link, std.mem.trimEnd(u8, attr, "\n"),
            });
            defer gpa.free(objs);
            const none = try git.runInput(io, &.{ "update-index", "--index-info" }, objs);
            gpa.free(none);
            const tree_text = try git.line(io, &.{"write-tree"});
            defer gpa.free(tree_text);
            try git.exec(io, &.{ "config", "core.ignorecase", ignore_case });
            try git.dir.deleteFile(io, ".git/index");

            var repo = try Repository.open(gpa, io, git.dir, .{});
            defer repo.deinit(io);
            var attrs = try repo.loadAttrs(io);
            defer attrs.deinit();
            var drivers = try filter_mod.load(gpa, io, &repo, .{});
            defer drivers.deinit(io);
            var rules = try repo.worktreeRules();
            rules.attrs = &attrs;
            rules.filters = &drivers;
            var index = index_mod.Index.initEmpty(gpa, .sha1);
            defer index.deinit();
            // Refused, or written with the delayed file kept inside: what
            // must never be is a file in `target-dir`.
            if (worktree.checkout(gpa, io, git.dir, .{ .index = &index, .db = repo.objectDatabase(), .tree = try hash.Oid.parse(.sha1, tree_text) }, .{
                .rules = rules,
                .programs = .{ .environ = &env },
            })) |_| {} else |_| {}
            try std.testing.expectError(error.FileNotFound, git.dir.access(io, "target-dir/z", .{}));
        }
    }
}

/// Every file under `dir`, as one string of paths, failing on a link and
/// on a file holding `needle`.
fn expectNoLink(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, needle: []const u8) !void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .sym_link => {
                std.debug.print("a link at {s}\n", .{entry.path});
                return error.TestUnexpectedResult;
            },
            .file => {
                const bytes = try dir.readFileAlloc(io, entry.path, gpa, .limited(64 << 20));
                defer gpa.free(bytes);
                if (needle.len != 0 and std.mem.find(u8, bytes, needle) != null) {
                    std.debug.print("{s} holds what a link pointed at\n", .{entry.path});
                    return error.TestUnexpectedResult;
                }
            },
            else => {},
        }
    }
}

/// Clone the repository at `path` with relic into a new directory of
/// `into`, `c`.
fn relicClone(gpa: std.mem.Allocator, io: Io, path: []const u8, into: *testgit.Repo) !?Repository {
    try into.dir.createDirPath(io, "c");
    var target = try into.dir.openDir(io, "c", .{ .iterate = true });
    defer target.close(io);
    return clone_mod.clone(gpa, io, path, target, .{ .who = who }) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => null,
    };
}

test "CVE-2022-39253, t5604-clone-reference 'clone repo with symlinked or unknown files at objects/': a link among a source's objects carries nothing it points at into a clone" {
    if (!links) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "f", "public\n");
    try source.exec(io, &.{ "add", "f" });
    try source.exec(io, &.{ "commit", "-q", "-m", "one" });
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "id_rsa", .data = "PRIVATE KEY MATERIAL\n" });
    const secret = try outside.dir.realPathFileAlloc(io, "id_rsa", gpa);
    defer gpa.free(secret);
    // A loose object's name that is a link to a file the cloner can read.
    try source.dir.createDirPath(io, ".git/objects/ab");
    try source.dir.symLink(io, secret, ".git/objects/ab/" ++ @as([38]u8, @splat('c')), .{});
    const path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);

    var into = try testgit.Repo.init(gpa, io, &.{});
    defer into.deinit();
    if (try relicClone(gpa, io, path, &into)) |opened| {
        var repo = opened;
        repo.deinit(io);
    }
    var clone_dir = try into.dir.openDir(io, "c", .{ .iterate = true });
    defer clone_dir.close(io);
    try expectNoLink(gpa, io, clone_dir, "PRIVATE KEY MATERIAL");
}

test "CVE-2023-22490, t5604-clone-reference 'clone repo with symlinked objects directory' and t5619-clone-local-ambiguous-transport: a linked objects directory leaks nothing, and a URL is never taken for a path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // A URL is a URL, whatever a directory beside it is called: relic
    // reaches `http://` only over HTTP.
    var only_file = try testgit.programEnviron(gpa);
    defer only_file.deinit();
    try only_file.put("GIT_ALLOW_PROTOCOL", "file");
    try std.testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "http://127.0.0.1:1/dumb/sub.git", .{ .service = .upload_pack, .kind = .sha1 }, .{
        .programs = .{ .environ = &only_file },
    }));
    try std.testing.expectError(error.NotARepository, local.Remote.open(gpa, io, "http://127.0.0.1:1/dumb/sub.git", .{}));
    if (!links) return;

    var sensitive = std.testing.tmpDir(.{});
    defer sensitive.cleanup();
    try sensitive.dir.writeFile(io, .{ .sub_path = "file", .data = "secret\n" });
    const sensitive_path = try sensitive.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(sensitive_path);
    var malicious = try testgit.Repo.init(gpa, io, &.{});
    defer malicious.deinit();
    try malicious.dir.deleteTree(io, ".git/objects");
    try malicious.dir.symLink(io, sensitive_path, ".git/objects", .{ .is_directory = true });
    const path = try malicious.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var into = try testgit.Repo.init(gpa, io, &.{});
    defer into.deinit();
    if (try relicClone(gpa, io, path, &into)) |opened| {
        var repo = opened;
        repo.deinit(io);
    }
    var clone_dir = try into.dir.openDir(io, "c", .{ .iterate = true });
    defer clone_dir.close(io);
    try expectNoLink(gpa, io, clone_dir, "secret");
}

test "CVE-2024-32021, t5604-clone-reference 'setup repo with manually symlinked or unknown files at objects/': a clone holds the source's objects and none of its links or strays" {
    if (!links) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var t = try testgit.Repo.init(gpa, io, &.{});
    defer t.deinit();
    try t.exec(io, &.{ "config", "gc.auto", "0" });
    try t.writeFile(io, "A.t", "A\n");
    try t.exec(io, &.{ "add", "A.t" });
    try t.exec(io, &.{ "commit", "-q", "-m", "A" });
    try t.exec(io, &.{ "gc", "-q" });
    try t.writeFile(io, "B.t", "B\n");
    try t.exec(io, &.{ "add", "B.t" });
    try t.exec(io, &.{ "commit", "-q", "-m", "B" });
    var objects = try t.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    // `pack` a link to `packs`; one loose directory a link; one loose
    // object a link to a file beside the directories; an unknown file.
    try objects.rename("pack", objects, "packs", io);
    try objects.symLink(io, "packs", "pack", .{ .is_directory = true });
    var loose: std.ArrayList([]const u8) = .empty;
    defer {
        for (loose.items) |name| gpa.free(name);
        loose.deinit(gpa);
    }
    var it = objects.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and entry.name.len == 2) try loose.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, loose.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    try std.testing.expect(loose.items.len >= 2);
    const last = loose.items[loose.items.len - 1];
    try objects.rename(last, objects, "a-loose-dir", io);
    try objects.symLink(io, "a-loose-dir", last, .{ .is_directory = true });
    var first = try objects.openDir(io, loose.items[0], .{ .iterate = true });
    defer first.close(io);
    var first_it = first.iterate();
    const obj = (try first_it.next(io)).?;
    const obj_name = try gpa.dupe(u8, obj.name);
    defer gpa.free(obj_name);
    try first.rename(obj_name, objects, "an-object", io);
    try first.symLink(io, "../an-object", obj_name, .{});
    try objects.writeFile(io, .{ .sub_path = "unknown_file", .data = "unknown_content\n" });
    const expected = try t.run(io, &.{ "rev-list", "--all", "--objects" });
    defer gpa.free(expected);

    const path = try t.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var into = try testgit.Repo.init(gpa, io, &.{});
    defer into.deinit();
    var repo = (try relicClone(gpa, io, path, &into)) orelse return error.TestUnexpectedResult;
    repo.deinit(io);
    var cloned = into;
    cloned.dir = try into.dir.openDir(io, "c", .{ .iterate = true });
    defer cloned.dir.close(io);
    try cloned.exec(io, &.{ "fsck", "--no-dangling" });
    const got = try cloned.run(io, &.{ "rev-list", "--all", "--objects" });
    defer gpa.free(got);
    try std.testing.expectEqualStrings(expected, got);
    try expectNoLink(gpa, io, cloned.dir, "unknown_content");
}

test "CVE-2024-32002, t7423-submodule-symlinks 'git submodule update must not create submodule behind symlink' and t7406-submodule-update 'submodule paths must not follow symlinks'" {
    if (!links) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var upstream = try testgit.Repo.init(gpa, io, &.{});
    defer upstream.deinit();
    try upstream.writeFile(io, "submodule_file", "upstream\n");
    try upstream.exec(io, &.{ "add", "-A" });
    try upstream.exec(io, &.{ "commit", "-q", "-m", "upstream" });
    const upstream_path = try upstream.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(upstream_path);
    var super = try testgit.Repo.init(gpa, io, &.{});
    defer super.deinit();
    try super.exec(io, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream_path, "a/sm" });
    try super.exec(io, &.{ "commit", "-q", "-m", "submodule" });
    try super.exec(io, &.{ "submodule", "deinit", "-q", "-f", "a/sm" });
    try super.dir.deleteTree(io, ".git/modules");
    try super.dir.deleteTree(io, "a");
    try super.dir.createDirPath(io, "b");
    try super.dir.symLink(io, "b", "a", .{ .is_directory = true });

    var repo = try Repository.open(gpa, io, super.dir, .{});
    defer repo.deinit(io);
    var t: hostile.GitClone = .{ .git = &super };
    var refusal: submodule.Refusal = .{};
    try std.testing.expectError(error.SymlinkInPath, submodule.update(gpa, io, &repo, .{ .init = true, .transport = t.seam(), .refusal = &refusal }));
    try std.testing.expectError(error.FileNotFound, super.dir.access(io, "b/sm", .{}));

    // t7406: a link `a` to `.git` beside a submodule at `A/modules/x`,
    // which a folding filesystem makes one directory: the checkout is
    // refused before a hook can land in `.git/modules`.
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const dot_git = try h.blob(io, ".git");
    const commit = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const x = try h.writeTree(gpa, io, &.{.{ .mode = "160000", .name = "x", .oid = commit }});
    const modules = try h.writeTree(gpa, io, &.{.{ .mode = "40000", .name = "modules", .oid = x }});
    const tree = try h.writeTree(gpa, io, &.{
        .{ .mode = "40000", .name = "A", .oid = modules },
        .{ .mode = "120000", .name = "a", .oid = dot_git },
    });
    var rules = h.worktreeRules();
    rules.ignore_case = true;
    var why: worktree.Refusal = .{};
    try std.testing.expectError(error.UnsafePath, worktree.checkout(gpa, io, h.repo.dir, .{ .index = &h.index, .db = &h.db, .tree = tree }, .{ .rules = rules, .refusal = &why }));
    try std.testing.expectEqual(path_mod.Reason.path_collision, why.reason.?);
    try std.testing.expectError(error.FileNotFound, h.git_dir.access(io, "modules/x", .{}));
}
