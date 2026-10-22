//! Replace refs as git 2.56 reads through them (`lookup_replace_object`):
//! a replaced blob's bytes, size and a replaced commit's parents read as
//! the replacement's; `GIT_NO_REPLACE_OBJECTS`, `core.useReplaceRefs` and
//! `GIT_REPLACE_REF_BASE`; a chain followed four deep and refused at five,
//! a name that is no object passed over, two refs for one object refused;
//! and what git runs with replace refs off reading the objects as stored:
//! the commit-graph left aside while they are in use, a repack and prune
//! that keep the history only the stored parents reach, and a clone served
//! from relic's upload-pack that holds it; and an ancestry that loops
//! through a replacement, on which `git tag --contains` dies and `git
//! branch --contains` answers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const suite = @import("helpers.zig");
const repo_mod = @import("../repo/repo.zig");
const rev_walk = @import("../walk/walk.zig");
const repack = @import("../maintenance/repack.zig");
const prune = @import("../maintenance/prune.zig");
const date = @import("../text.zig").date;
const ref_listing = @import("../pretty/refs.zig");
const hash = @import("../hash/hash.zig");

const Oid = hash.Oid;

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

fn blob(gpa: Allocator, io: Io, git: *testgit.Repo, bytes: []const u8) !Oid {
    const out = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, bytes);
    defer gpa.free(out);
    return Oid.parse(.sha1, std.mem.trimEnd(u8, out, "\n"));
}

fn setRef(io: Io, git: *testgit.Repo, name: []const u8, oid: Oid) !void {
    var hex: [hash.max_hex_len]u8 = undefined;
    try git.exec(io, &.{ "update-ref", name, oid.hex(&hex) });
}

fn replaceRef(gpa: Allocator, io: Io, git: *testgit.Repo, base: []const u8, original: Oid, replacement: Oid) !void {
    var hex: [hash.max_hex_len]u8 = undefined;
    const name = try std.mem.concat(gpa, u8, &.{ base, original.hex(&hex) });
    defer gpa.free(name);
    try setRef(io, git, name, replacement);
}

/// Three commits on `main`; the second's file replaced by another blob and
/// the second itself by a copy with no parents (`git replace --graft`).
const History = struct { second: Oid, two: Oid };

fn setup(gpa: Allocator, io: Io, git: *testgit.Repo) !History {
    try git.writeFile(io, "f.txt", "one\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.writeFile(io, "f.txt", "two\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    try git.writeFile(io, "f.txt", "three\n");
    try git.writeFile(io, "g.txt", "g\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "three" });
    const history: History = .{ .second = try oidOf(gpa, io, git, "HEAD~1"), .two = try oidOf(gpa, io, git, "HEAD~1:f.txt") };
    var hex: [hash.max_hex_len]u8 = undefined;
    const upper = try blob(gpa, io, git, "TWO\n");
    var upper_hex: [hash.max_hex_len]u8 = undefined;
    try git.exec(io, &.{ "replace", history.two.hex(&hex), upper.hex(&upper_hex) });
    try git.exec(io, &.{ "replace", "--graft", "HEAD~1" });
    return history;
}

/// What a reader sees: `rev-list --parents HEAD`, the file's blob, its
/// size and the second commit.
fn gitView(gpa: Allocator, io: Io, git: *testgit.Repo, env: *const std.process.Environ.Map, global: []const []const u8, h: History) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    var second_hex: [hash.max_hex_len]u8 = undefined;
    const asks = [_][]const []const u8{
        &.{ "rev-list", "--parents", "HEAD" },
        &.{ "cat-file", "-p", h.two.hex(&hex) },
        &.{ "cat-file", "-s", h.two.hex(&hex) },
        &.{ "cat-file", "commit", h.second.hex(&second_hex) },
    };
    for (asks) |ask| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, global);
        try argv.appendSlice(gpa, ask);
        const text = try testremote.gitInputEnv(gpa, io, git.dir, env, argv.items, "", true);
        defer gpa.free(text);
        try out.appendSlice(gpa, text);
    }
    return out.toOwnedSlice(gpa);
}

fn relicView(gpa: Allocator, io: Io, git: *testgit.Repo, options: repo_mod.Repository.OpenOptions, h: History) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, options);
    defer repo.deinit(io);
    const db = repo.objectDatabase();
    var walk: rev_walk.Walk = .init(gpa, db);
    defer walk.deinit();
    try walk.push(try oidOf(gpa, io, git, "HEAD"));
    while (try walk.next(io)) |commit| {
        try out.print(gpa, "{f}", .{commit.oid});
        for (commit.parents) |p| try out.print(gpa, " {f}", .{p});
        try out.append(gpa, '\n');
    }
    const file = try db.read(io, h.two);
    defer db.allocator().free(file.bytes);
    try out.appendSlice(gpa, file.bytes);
    try out.print(gpa, "{d}\n", .{(try db.readHeader(io, h.two)).size});
    const second = try db.read(io, h.second);
    defer db.allocator().free(second.bytes);
    try out.appendSlice(gpa, second.bytes);
    return out.toOwnedSlice(gpa);
}

fn expectView(gpa: Allocator, io: Io, git: *testgit.Repo, env: *const std.process.Environ.Map, global: []const []const u8, options: repo_mod.Repository.OpenOptions, h: History) !void {
    const theirs = try gitView(gpa, io, git, env, global, h);
    defer gpa.free(theirs);
    const ours = try relicView(gpa, io, git, options, h);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
}

test "objects are read through the replace refs as git reads them, unless the caller, the setting or the base says otherwise" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const h = try setup(gpa, io, &git);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    try expectView(gpa, io, &git, &env, &.{}, .{}, h);
    // The replacement is what is read: no parents, the other bytes.
    const plain = try relicView(gpa, io, &git, .{}, h);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "TWO\n") != null);
    try expectView(gpa, io, &git, &env, &.{"--no-replace-objects"}, .{ .replace_objects = false }, h);

    try git.exec(io, &.{ "config", "core.useReplaceRefs", "false" });
    try expectView(gpa, io, &git, &env, &.{}, .{}, h);
    try git.exec(io, &.{ "config", "--unset", "core.useReplaceRefs" });

    // The refs moved under another base, which git takes from the
    // environment and relic from the caller.
    const listed = try git.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/replace/" });
    defer gpa.free(listed);
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        const space = std.mem.findScalar(u8, line, ' ').?;
        const name = try std.mem.concat(gpa, u8, &.{ "refs/alt/", line["refs/replace/".len..space] });
        defer gpa.free(name);
        try git.exec(io, &.{ "update-ref", name, line[space + 1 ..] });
        try git.exec(io, &.{ "update-ref", "-d", line[0..space] });
    }
    try expectView(gpa, io, &git, &env, &.{}, .{}, h);
    try env.put("GIT_REPLACE_REF_BASE", "refs/alt/");
    try expectView(gpa, io, &git, &env, &.{}, .{ .replace_ref_base = "refs/alt/" }, h);
}

fn readBlob(gpa: Allocator, io: Io, git: *testgit.Repo, oid: Oid) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const found = try repo.objectDatabase().read(io, oid);
    defer repo.objectDatabase().allocator().free(found.bytes);
    return gpa.dupe(u8, found.bytes);
}

test "a chain of replacements is followed four deep and refused at five, and a ref that names no object or names one twice is git's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var blobs: [6]Oid = undefined;
    for (&blobs, 0..) |*b, i| {
        const text = try gpa.print("blob {d}\n", .{i});
        defer gpa.free(text);
        b.* = try blob(gpa, io, &git, text);
    }
    for (0..4) |i| try replaceRef(gpa, io, &git, "refs/replace/", blobs[i], blobs[i + 1]);
    // A name that is no object: git warns and reads on.
    try setRef(io, &git, "refs/replace/not-an-object", blobs[5]);
    var hex: [hash.max_hex_len]u8 = undefined;
    const theirs = try git.run(io, &.{ "cat-file", "-p", blobs[0].hex(&hex) });
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings("blob 4\n", theirs);
    const ours = try readBlob(gpa, io, &git, blobs[0]);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);

    try replaceRef(gpa, io, &git, "refs/replace/", blobs[4], blobs[5]);
    git.report_failures = false;
    try std.testing.expectError(error.GitFailed, git.run(io, &.{ "cat-file", "-p", blobs[0].hex(&hex) }));
    try std.testing.expectError(error.ReplaceDepthTooHigh, readBlob(gpa, io, &git, blobs[0]));
    // One link short of git's limit reads again.
    const four = try readBlob(gpa, io, &git, blobs[1]);
    defer gpa.free(four);
    try std.testing.expectEqualStrings("blob 5\n", four);

    // Two refs for one object: git dies at the first read, as relic stops.
    try replaceRef(gpa, io, &git, "refs/replace/twice/", blobs[1], blobs[3]);
    try std.testing.expectError(error.GitFailed, git.run(io, &.{ "cat-file", "-p", blobs[5].hex(&hex) }));
    try std.testing.expectError(error.DuplicateReplaceRef, readBlob(gpa, io, &git, blobs[5]));
}

test "what git runs with replace refs off reads the stored objects: the commit-graph aside, repack and prune keeping the stored history, upload-pack serving it" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    _ = try setup(gpa, io, &git);
    // No reflog keeps the first commit: only the second's stored parent.
    try git.exec(io, &.{ "reflog", "expire", "--expire=all", "--all" });
    // Written with replace refs off: the stored parents.
    try git.exec(io, &.{ "commit-graph", "write", "--reachable" });
    const stored_args = [_][]const u8{ "--no-replace-objects", "rev-list", "--objects", "--all" };
    const stored = try git.run(io, &stored_args);
    defer gpa.free(stored);

    {
        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        const db = repo.objectDatabase();
        // The graph records the stored parents, so it is left aside.
        try std.testing.expect(try db.replacing(io));
        try std.testing.expect(try db.commitGraph(io) == null);
        // A prune while the first commit's objects are loose, then a repack
        // that takes away the pack holding them.
        _ = try prune.prune(gpa, io, &repo, .{ .expire = date.expire_all });
        try git.exec(io, &.{ "repack", "-a", "-d", "-q" });
        try repo.objectDatabase().refresh(io);
        _ = try repack.repack(gpa, io, &repo, .{ .mode = .all, .delete = true });
    }
    {
        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{ .replace_objects = false });
        defer repo.deinit(io);
        var graph = (try repo.objectDatabase().commitGraph(io)).?;
        graph.deinit();
    }
    const after = try git.run(io, &stored_args);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(stored, after);
    const checked = try git.run(io, &.{ "--no-replace-objects", "fsck", "--full", "--no-dangling" });
    gpa.free(checked);

    // A clone from relic's upload-pack holds what the stored parents
    // reach, and no replace refs.
    const helper = try gpa.dupe(u8, suite.path(.upload_pack_helper));
    defer gpa.free(helper);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, helper, '\\', '/');
    const source = try testremote.absolutePath(gpa, io, git.dir);
    defer gpa.free(source);
    const url = try std.mem.concat(gpa, u8, &.{ "file://", source });
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cloned = try testremote.gitInputEnv(gpa, io, tmp.dir, &env, &.{ "clone", "-q", "--no-checkout", "--upload-pack", helper, url, "clone" }, "", true);
    gpa.free(cloned);
    var clone = try tmp.dir.openDir(io, "clone", .{});
    defer clone.close(io);
    const count = try testremote.gitInputEnv(gpa, io, clone, &env, &.{ "rev-list", "--count", "HEAD" }, "", true);
    defer gpa.free(count);
    try std.testing.expectEqualStrings("3\n", count);
    const clone_checked = try testremote.gitInputEnv(gpa, io, clone, &env, &.{ "fsck", "--full", "--no-dangling" }, "", true);
    gpa.free(clone_checked);
}

/// relic's tag or branch listing of what contains `wanted`.
fn listContaining(gpa: Allocator, io: Io, git: *testgit.Repo, tags: bool, wanted: Oid) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (tags)
        try ref_listing.listTags(gpa, io, &out.writer, &repo, .{ .contains = &.{wanted} })
    else
        try ref_listing.listBranches(gpa, io, &out.writer, &repo, .{ .contains = &.{wanted} });
    return gpa.dupe(u8, out.written());
}

test "an ancestry a replacement makes loop: git tag --contains dies on it as git 2.56 does, git branch --contains answers" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    for ([_][]const u8{ "one", "two", "three" }) |subject| {
        try git.writeFile(io, "f.txt", subject);
        try git.exec(io, &.{ "add", "-A" });
        try git.exec(io, &.{ "commit", "-q", "-m", subject });
    }
    try git.exec(io, &.{ "tag", "middle", "HEAD~1" });
    try git.exec(io, &.{ "branch", "side", "HEAD~2" });
    try git.exec(io, &.{ "switch", "-q", "side" });
    try git.writeFile(io, "side.txt", "side\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "side" });
    const elsewhere = try oidOf(gpa, io, &git, "HEAD");
    try git.exec(io, &.{ "switch", "-q", "main" });
    // The first commit now has the last for its parent.
    try git.exec(io, &.{ "replace", "--graft", "main~2", "main" });
    var hex: [hash.max_hex_len]u8 = undefined;

    git.report_failures = false;
    try std.testing.expectError(error.GitFailed, git.run(io, &.{ "tag", "--contains", elsewhere.hex(&hex) }));
    try std.testing.expectError(error.CommitAncestryCycle, listContaining(gpa, io, &git, true, elsewhere));
    git.report_failures = true;

    const theirs = try git.run(io, &.{ "branch", "--contains", elsewhere.hex(&hex) });
    defer gpa.free(theirs);
    const ours = try listContaining(gpa, io, &git, false, elsewhere);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
}
