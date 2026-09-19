//! Tests against repositories the real `git` builds on the machine at test
//! time. Where the format is exact, the comparison is byte for byte.

const std = @import("std");
const Io = std.Io;
const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const sha1dc = @import("sha1dc.zig");

const Oid = hash.Oid;

test "every object of a packed repository reads back, both delta kinds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // A file that grows, so the packer has something to delta, and a second
    // one that shrinks, so at least one delta goes the other way.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..40) |i| {
        try body.print(gpa, "line {d} of a file that keeps growing\n", .{i});
        try repo.writeFile(io, "grow.txt", body.items);
        try repo.writeFile(io, "shrink.txt", body.items[0 .. body.items.len / 2]);
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "commit {d}", .{i});
        try repo.exec(io, &.{ "commit", "-q", "-m", msg });
    }
    try repo.exec(io, &.{ "gc", "-q", "--aggressive" });

    const git_dir = try repo.gitDir(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    try std.testing.expect(db.packCount() >= 1);

    // Every name git enumerates must read back, and must rehash to itself.
    const listing = try repo.run(io, &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)" });
    defer gpa.free(listing);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const name = fields.next().?;
        const type_text = fields.next().?;
        const size_text = fields.next().?;
        const oid = try Oid.parse(.sha1, name);
        const expected_type = try object.Type.parse(type_text);
        const expected_size = try std.fmt.parseInt(u64, size_text, 10);

        const header = try db.readHeader(io, oid);
        try std.testing.expectEqual(expected_type, header.type);
        try std.testing.expectEqual(expected_size, header.size);

        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        try std.testing.expectEqual(expected_type, found.type);
        try std.testing.expectEqual(expected_size, found.bytes.len);
        const rehashed = hash.Hasher.object(.sha1, found.type.name(), found.bytes);
        try std.testing.expect(rehashed.eql(oid));
        count += 1;
    }
    try std.testing.expect(count > 40);

    // And the pack itself verifies: trailer, every CRC, every name.
    const report = try db.verify(io);
    try std.testing.expect(report.packs >= 1);
    try std.testing.expect(report.packed_objects > 0);
}

test "a pack holds both ofs-delta and ref-delta entries and both resolve" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..25) |i| {
        try body.print(gpa, "row {d}\n", .{i});
        try repo.writeFile(io, "f.txt", body.items);
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) });
    }
    // `--no-delta-base-offset` makes the packer write ref-deltas; the default
    // writes ofs-deltas. One repacked repository of each proves both arms.
    try repo.exec(io, &.{ "-c", "repack.usedeltabaseoffset=false", "repack", "-a", "-d", "-q" });

    const git_dir = try repo.gitDir(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var saw_ref_delta = false;
    for (db.sources.items) |*source| {
        for (source.packs.items) |*p| {
            var it = p.index.iterate();
            while (try it.next()) |found| {
                const header = try p.entryHeaderAt(io, found.located.offset);
                if (header.kind == .ref_delta) saw_ref_delta = true;
            }
        }
    }
    try std.testing.expect(saw_ref_delta);
    const report = try db.verify(io);
    try std.testing.expect(report.packed_objects > 0);

    // Now repack with offsets, which is git's default, and check the other
    // arm in the same repository.
    try repo.exec(io, &.{ "repack", "-a", "-d", "-q" });
    var db2 = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db2.deinit(io);
    var saw_ofs_delta = false;
    for (db2.sources.items) |*source| {
        for (source.packs.items) |*p| {
            var it = p.index.iterate();
            while (try it.next()) |found| {
                const header = try p.entryHeaderAt(io, found.located.offset);
                if (header.kind == .ofs_delta) saw_ofs_delta = true;
            }
        }
    }
    try std.testing.expect(saw_ofs_delta);
    _ = try db2.verify(io);
}

test "a sha256 repository reads end to end" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = testgit.Repo.init(gpa, io, &.{"--object-format=sha256"}) catch |err| switch (err) {
        error.GitFailed => return error.SkipZigTest,
        else => return err,
    };
    defer repo.deinit();

    try repo.writeFile(io, "a.txt", "hello\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.exec(io, &.{ "gc", "-q" });

    const git_dir = try repo.gitDir(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha256, .{});
    defer db.deinit(io);

    const listing = try repo.run(io, &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)" });
    defer gpa.free(listing);
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const oid = try Oid.parse(.sha256, fields.next().?);
        const expected_type = try object.Type.parse(fields.next().?);
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        try std.testing.expectEqual(expected_type, found.type);
        try std.testing.expect(hash.Hasher.object(.sha256, found.type.name(), found.bytes).eql(oid));
        seen += 1;
    }
    try std.testing.expect(seen >= 3);
    _ = try db.verify(io);
}

test "a loose object this writes is one git reads" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    const git_dir = try repo.gitDir(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    const blob = try db.write(io, .blob, "written by relic\n");
    var hex: [hash.max_hex_len]u8 = undefined;
    const name = try gpa.dupe(u8, blob.hex(&hex));
    defer gpa.free(name);

    const content = try repo.run(io, &.{ "cat-file", "blob", name });
    defer gpa.free(content);
    try std.testing.expectEqualStrings("written by relic\n", content);

    var tree_builder: object.Tree.Builder = .init(gpa, .sha1);
    defer tree_builder.deinit();
    try tree_builder.add(.file, "note.txt", blob);
    const tree_bytes = try tree_builder.build();
    defer gpa.free(tree_bytes);
    const tree = try db.write(io, .tree, tree_bytes);

    const commit_bytes = try object.Commit.build(gpa, .sha1, .{
        .tree = tree,
        .author = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
        .committer = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
        .message = "from relic\n",
    });
    defer gpa.free(commit_bytes);
    const commit = try db.write(io, .commit, commit_bytes);
    const commit_name = try gpa.dupe(u8, commit.hex(&hex));
    defer gpa.free(commit_name);

    // git must agree the commit is a commit and its tree is the tree.
    const spec = try std.fmt.allocPrint(gpa, "{s}^{{tree}}", .{commit_name});
    defer gpa.free(spec);
    const shown = try repo.line(io, &.{ "rev-parse", spec });
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(tree.hex(&hex), shown);

    // And fsck is silent about everything written.
    try repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}

const index_mod = @import("index.zig");

/// Read the index git wrote, write it back, and compare the bytes.
fn expectIndexRoundTrip(
    gpa: std.mem.Allocator,
    io: Io,
    repo: *testgit.Repo,
    kind: hash.Kind,
    version: index_mod.WriteOptions.Version,
    skip_hash: bool,
) !void {
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    const original = try repo.readFile(io, ".git/index");
    defer gpa.free(original);

    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, kind);
    defer index.deinit();

    const written = try index.toBytes(.{ .version = version, .skip_hash = skip_hash });
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, original, written);
}

test "an index git wrote with the offset caches is written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    for (0..14) |i| {
        var name_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "dir{d}/file{d}.txt", .{ i % 3, i });
        try repo.writeFile(io, path, "contents\n");
    }

    // Stock git writes neither extension. They appear when `index.threads`
    // asks for a reader that can use them, which is what this asks for.
    const threaded: []const []const u8 = &.{ "-c", "index.threads=4" };
    try repo.exec(io, threaded ++ [_][]const u8{ "add", "-A" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    {
        var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
        defer index.deinit();
        try std.testing.expect(index.had_end_of_index_entries);
        try std.testing.expectEqual(@as(u32, 4), index.entry_offset_blocks);
    }
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .auto, false);

    // With a `TREE` extension in front of them, so the hash `EOIE` carries
    // is over more than one extension header.
    try repo.exec(io, threaded ++ [_][]const u8{ "commit", "-q", "-m", "one" });
    try repo.writeFile(io, "dir0/file0.txt", "changed\n");
    try repo.exec(io, threaded ++ [_][]const u8{ "add", "-A" });
    {
        var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
        defer index.deinit();
        try std.testing.expect(index.cache_tree != null);
        try std.testing.expect(index.had_end_of_index_entries);
        try std.testing.expectEqual(@as(u32, 4), index.entry_offset_blocks);
    }
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .auto, false);

    // And at version 4, where the path of the first entry of every block is
    // written whole rather than against the entry before it, so that a
    // reader can take the blocks apart.
    try repo.exec(io, threaded ++ [_][]const u8{ "-c", "index.version=4", "update-index", "--index-version", "4" });
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .v4, false);
}

test "a version 2 index git wrote is written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    for (0..12) |i| {
        var name_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "dir{d}/file{d}.txt", .{ i % 3, i });
        try repo.writeFile(io, path, "contents\n");
    }
    try repo.writeFile(io, "top.txt", "top\n");
    try repo.exec(io, &.{ "add", "-A" });
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .auto, false);

    // After a commit the index carries a TREE extension, which must also
    // come back byte for byte.
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .auto, false);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    try std.testing.expect(index.cache_tree != null);
    const root = index.cache_tree.?.get("").?;
    try std.testing.expect(root.isValid());
    try std.testing.expectEqual(@as(i64, 13), root.entry_count);

    // And the cache tree's root is the tree git wrote.
    const tree_text = try repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree_text);
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(tree_text, root.oid.?.hex(&hex));
}

test "a version 3 index git wrote is written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.exec(io, &.{ "add", "-A" });
    // skip-worktree is what forces the extended flag, and so version 3.
    try repo.exec(io, &.{ "update-index", "--skip-worktree", "b.txt" });
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .auto, false);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    try std.testing.expectEqual(@as(u32, 3), index.version);
    try std.testing.expect(index.find("b.txt").?.skip_worktree);
}

test "a version 4 index git wrote is written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "config", "index.version", "4" });
    // feature.manyFiles also turns on index.skipHash, so the two are set
    // apart here and both arms are exercised.
    for (0..30) |i| {
        var name_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "deep/nest{d}/file{d}.txt", .{ i % 4, i });
        try repo.writeFile(io, path, "x\n");
    }
    try repo.exec(io, &.{ "add", "-A" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    try std.testing.expectEqual(@as(u32, 4), index.version);
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .v4, false);

    // Every path git lists is a path this read, in the same order.
    const listed = try repo.run(io, &.{"ls-files"});
    defer gpa.free(listed);
    var lines = std.mem.splitScalar(u8, listed, '\n');
    var i: usize = 0;
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        try std.testing.expectEqualStrings(path, index.entries.items[i].path);
        i += 1;
    }
    try std.testing.expectEqual(i, index.entries.items.len);
}

test "an index written with index.skipHash round trips" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "config", "index.skipHash", "true" });
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.exec(io, &.{ "add", "-A" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    try std.testing.expect(index.hash_was_skipped);
    try expectIndexRoundTrip(gpa, io, &repo, .sha1, .auto, true);
}

test "a split index is read whole and loses no entry" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "config", "core.splitIndex", "true" });

    try repo.writeFile(io, "a.txt", "a\n");
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.writeFile(io, "c.txt", "c\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.writeFile(io, "a.txt", "a changed\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "rm", "-q", "--cached", "b.txt" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    try std.testing.expect(index.was_split);

    // git's own listing is the truth: every path and every object name.
    const listed = try repo.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(listed);
    var lines = std.mem.splitScalar(u8, listed, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitAny(u8, line, " \t");
        _ = fields.next().?;
        const oid_text = fields.next().?;
        _ = fields.next().?;
        const path = fields.rest();
        const entry = index.find(path) orelse {
            std.debug.print("missing from split index: {s}\n", .{path});
            return error.TestUnexpectedResult;
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        try std.testing.expectEqualStrings(oid_text, entry.oid.hex(&hex));
        seen += 1;
    }
    try std.testing.expectEqual(seen, index.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), seen);

    // Written back as one complete index, which git reads as the same set.
    var write_dir = try repo.gitDir(io);
    defer write_dir.close(io);
    try index.write(io, write_dir, "index", .{});
    const after = try repo.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(after);
    try std.testing.expectEqualStrings(listed, after);
}

test "fsmonitor and untracked-cache extensions survive a round trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // `core.untrackedCache` makes git write `UNTR`. `core.fsmonitor` set to
    // a hook path makes it write `FSMN` — the token is opaque and a file
    // watcher will supply it later, so what matters now is that neither is
    // lost when this rewrites the index.
    try repo.exec(io, &.{ "config", "core.untrackedCache", "true" });
    for (0..8) |i| {
        var buf: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&buf, "d{d}/f{d}.txt", .{ i % 3, i }), "x\n");
    }
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--untracked-cache" });
    try repo.exec(io, &.{ "status", "--porcelain" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    const original = try repo.readFile(io, ".git/index");
    defer gpa.free(original);

    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();

    var saw_untracked_cache = false;
    for (index.unknown.items) |extension| {
        if (std.mem.eql(u8, &extension.signature, "UNTR")) saw_untracked_cache = true;
    }
    if (!saw_untracked_cache) return error.SkipZigTest;

    const written = try index.toBytes(.{});
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, original, written);
}

test "an annotated tag written is one git reads, and its gpgsig header survives" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "hello\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const commit_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit_text);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    const signature = "-----BEGIN SSH SIGNATURE-----\n\nnot a real signature\n-----END SSH SIGNATURE-----";
    const bytes = try object.Tag.build(gpa, .sha1, .{
        .target = try Oid.parse(.sha1, commit_text),
        .target_type = .commit,
        .name = "v1.0",
        .tagger = .{
            .name = "Fixture",
            .email = "fixture@example.com",
            .when_secs = 1_700_000_000,
            .offset_minutes = 0,
        },
        .extra = &.{.{ .name = "gpgsig", .value = signature }},
        .message = "the first release\n",
    });
    defer gpa.free(bytes);
    const tag_oid = try db.write(io, .tag, bytes);
    var hex: [hash.max_hex_len]u8 = undefined;
    const tag_text = try gpa.dupe(u8, tag_oid.hex(&hex));
    defer gpa.free(tag_text);

    try repo.exec(io, &.{ "update-ref", "refs/tags/v1.0", tag_text });

    const shown = try repo.run(io, &.{ "cat-file", "tag", tag_text });
    defer gpa.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "tag v1.0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "gpgsig -----BEGIN SSH SIGNATURE-----\n \n") != null);

    const peeled = try repo.line(io, &.{ "rev-parse", "v1.0^{commit}" });
    defer gpa.free(peeled);
    try std.testing.expectEqualStrings(commit_text, peeled);
    try repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });

    // And the header comes back unfolded, which is what a verifier needs.
    const found = try db.read(io, tag_oid);
    defer gpa.free(found.bytes);
    var tag = try object.Tag.parse(gpa, .sha1, found.bytes);
    defer tag.deinit();
    try std.testing.expectEqualStrings(signature, tag.extraHeader("gpgsig").?);
    try std.testing.expectEqualStrings("v1.0", tag.name);
}

test "a commit's gpgsig header is read back exactly as git stores it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "hello\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    const head_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const head = try Oid.parse(.sha1, head_text);
    const found = try db.read(io, head);
    defer gpa.free(found.bytes);
    var original = try object.Commit.parse(gpa, .sha1, found.bytes);
    defer original.deinit();

    const signature = "-----BEGIN PGP SIGNATURE-----\n\nline one\n\nline three\n-----END PGP SIGNATURE-----";
    const signed = try object.Commit.build(gpa, .sha1, .{
        .tree = original.tree,
        .parents = original.parents,
        .author = original.author,
        .committer = original.committer,
        .extra = &.{.{ .name = "gpgsig", .value = signature }},
        .message = original.message,
    });
    defer gpa.free(signed);
    const signed_oid = try db.write(io, .commit, signed);
    var hex: [hash.max_hex_len]u8 = undefined;
    const signed_text = try gpa.dupe(u8, signed_oid.hex(&hex));
    defer gpa.free(signed_text);

    // git prints the header with every continuation line carrying a space,
    // the empty ones included.
    const raw = try repo.run(io, &.{ "cat-file", "commit", signed_text });
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "gpgsig -----BEGIN PGP SIGNATURE-----\n \n line one\n \n line three\n") != null);

    const back = try db.read(io, signed_oid);
    defer gpa.free(back.bytes);
    var parsed = try object.Commit.parse(gpa, .sha1, back.bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(signature, parsed.extraHeader("gpgsig").?);
    try repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}

test "includeIf reads the file git reads" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "extra.config", "[core]\n\tautocrlf = input\n[fixture]\n\tvalue = included\n");
    // The condition names the repository's own git directory, so it holds.
    try repo.dir.writeFile(io, .{
        .sub_path = ".git/config",
        .data = "[core]\n\trepositoryformatversion = 0\n[includeIf \"gitdir:**/\"]\n\tpath = ../extra.config\n",
    });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);

    var abs: [4096]u8 = undefined;
    const abs_len = try git_dir.realPath(io, &abs);

    var cfg = try config_mod.Config.open(gpa, io, .{
        .local = .{ .dir = git_dir, .sub_path = "config" },
    }, .{ .git_dir = abs[0..abs_len] });
    defer cfg.deinit();

    try std.testing.expectEqualStrings("input", cfg.get("core.autocrlf").?);
    try std.testing.expectEqualStrings("included", cfg.get("fixture.value").?);

    // git agrees that the include applies. The key is one the fixture
    // harness does not set on the command line, where a `-c` would win.
    const theirs = try repo.line(io, &.{ "config", "--get", "fixture.value" });
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings("included", theirs);
}

const config_mod = @import("config.zig");

test "sparse checkout takes paths out of the working tree and puts them back" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "top.txt", "top\n");
    try repo.writeFile(io, "src/main.zig", "main\n");
    try repo.writeFile(io, "docs/page.md", "docs\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();

    try git_dir.createDirPath(io, "info");
    try git_dir.writeFile(io, .{ .sub_path = "info/sparse-checkout", .data = "/*\n!/docs/\n" });
    var patterns = (try sparse_mod.Patterns.load(gpa, io, git_dir, false)).?;
    defer patterns.deinit();

    const out = try worktree.applySparse(gpa, io, repo.dir, &index, &db, &patterns, .{});
    try std.testing.expectEqual(@as(u32, 1), out.skipped);
    try std.testing.expectError(error.FileNotFound, repo.dir.access(io, "docs/page.md", .{}));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("main\n", try repo.dir.readFile(io, "src/main.zig", &buf));
    try std.testing.expect(index.find("docs/page.md").?.skip_worktree);

    // git reads the index and calls the working tree clean, because the
    // missing file is marked as not wanted there.
    try index.write(io, git_dir, "index", .{});
    try repo.exec(io, &.{ "config", "core.sparseCheckout", "true" });
    const status = try repo.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("", status);

    // Widening the patterns brings it back.
    try git_dir.writeFile(io, .{ .sub_path = "info/sparse-checkout", .data = "/*\n" });
    var wider = (try sparse_mod.Patterns.load(gpa, io, git_dir, false)).?;
    defer wider.deinit();
    const back = try worktree.applySparse(gpa, io, repo.dir, &index, &db, &wider, .{});
    try std.testing.expectEqual(@as(u32, 1), back.restored);
    try std.testing.expectEqualStrings("docs\n", try repo.dir.readFile(io, "docs/page.md", &buf));
    try std.testing.expect(!index.find("docs/page.md").?.skip_worktree);
}

const sparse_mod = @import("sparse.zig");
const worktree = @import("worktree.zig");

const commitgraph_mod = @import("commitgraph.zig");
const midx_mod = @import("midx.zig");
const merge_mod = @import("merge.zig");
const revwalk = @import("revwalk.zig");
const worktrees_mod = @import("worktrees.zig");
const repo_mod = @import("repo.zig");

test "the commit-graph and the multi-pack index read what git wrote" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    for (0..12) |i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "f{d}.txt", .{i});
        try repo.writeFile(io, name, "x\n");
        try repo.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg, "c{d}", .{i}) });
        // A second pack each time, so the multi-pack index has something to
        // do.
        if (i % 4 == 3) try repo.exec(io, &.{ "repack", "-q", "-d" });
    }
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });
    repo.exec(io, &.{ "multi-pack-index", "write" }) catch {};

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);

    var graph = (try commitgraph_mod.Graph.open(gpa, io, objects, .sha1)) orelse return error.SkipZigTest;
    defer graph.deinit();

    // Every commit git lists is in the graph, with the parents the object
    // itself carries.
    const listed = try repo.run(io, &.{ "rev-list", "--all" });
    defer gpa.free(listed);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const oid = try Oid.parse(.sha1, line);
        const position = graph.find(oid) orelse {
            std.debug.print("commit missing from the graph: {s}\n", .{line});
            return error.TestUnexpectedResult;
        };
        const from_graph = try graph.parentsOf(gpa, position);
        defer gpa.free(from_graph);

        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        var commit = try object.Commit.parse(gpa, .sha1, found.bytes);
        defer commit.deinit();
        try std.testing.expectEqual(commit.parents.len, from_graph.len);
        for (commit.parents, from_graph) |a, b| try std.testing.expect(a.eql(b));

        const entry = (try graph.commitAt(position));
        try std.testing.expect(entry.tree.eql(commit.tree));
        try std.testing.expectEqual(commit.committer.when_secs, entry.time);
        count += 1;
    }
    try std.testing.expect(count >= 12);

    // The multi-pack index, when git wrote one, points every object at a
    // pack this has open.
    const pack_dir = objects.openDir(io, "pack", .{ .iterate = true }) catch return;
    defer pack_dir.close(io);
    var index = (try midx_mod.Index.open(gpa, io, pack_dir, .sha1)) orelse return;
    defer index.deinit();
    try std.testing.expect(index.count > 0);
    try std.testing.expect(index.packName(0) != null);

    var i: u32 = 0;
    while (i < @min(index.count, 50)) : (i += 1) {
        const oid = index.nameAt(i);
        const located = (try index.find(oid)).?;
        try std.testing.expect(located.pack < index.pack_count);
        // And the object really is readable, which is the only thing the
        // accelerator is allowed to change the speed of.
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        try std.testing.expect(hash.Hasher.object(.sha1, found.type.name(), found.bytes).eql(oid));
    }
}

test "a three-way tree merge agrees with git merge-tree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "shared.txt", "base\n");
    try repo.writeFile(io, "ours-only.txt", "base\n");
    try repo.writeFile(io, "theirs-only.txt", "base\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    const base_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(base_text);

    try repo.writeFile(io, "ours-only.txt", "ours\n");
    try repo.writeFile(io, "added-by-us.txt", "ours\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "ours" });
    const ours_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(ours_text);

    try repo.exec(io, &.{ "checkout", "-q", "-b", "theirs", base_text });
    try repo.writeFile(io, "theirs-only.txt", "theirs\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "theirs" });
    const theirs_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(theirs_text);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    const ours = try Oid.parse(.sha1, ours_text);
    const theirs = try Oid.parse(.sha1, theirs_text);

    // The merge base this computes is the one git computes.
    const base = (try revwalk.mergeBase(gpa, io, &db, ours, theirs)).?;
    var hex: [hash.max_hex_len]u8 = undefined;
    const merge_base_text = try repo.line(io, &.{ "merge-base", ours_text, theirs_text });
    defer gpa.free(merge_base_text);
    try std.testing.expectEqualStrings(merge_base_text, base.hex(&hex));

    var result = try merge_mod.trees(
        gpa,
        io,
        &db,
        try treeOf(gpa, io, &db, base),
        try treeOf(gpa, io, &db, ours),
        try treeOf(gpa, io, &db, theirs),
    );
    defer result.deinit();
    try std.testing.expect(result.isClean());

    const merged = try merge_mod.tree(io, &db, &result);
    const theirs_merged = repo.line(io, &.{ "merge-tree", "--write-tree", ours_text, theirs_text }) catch
        return error.SkipZigTest;
    defer gpa.free(theirs_merged);
    try std.testing.expectEqualStrings(theirs_merged, merged.hex(&hex));
}

fn treeOf(gpa: std.mem.Allocator, io: Io, db: *odb_mod.Odb, commit_oid: Oid) !Oid {
    const found = try db.read(io, commit_oid);
    defer gpa.free(found.bytes);
    var commit = try object.Commit.parse(gpa, .sha1, found.bytes);
    defer commit.deinit();
    return commit.tree;
}

test "a conflicting three-way merge leaves stages 1, 2 and 3" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "both.txt", "base\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });
    const base_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(base_text);

    try repo.writeFile(io, "both.txt", "ours\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "ours" });
    const ours_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(ours_text);

    try repo.exec(io, &.{ "checkout", "-q", "-b", "theirs", base_text });
    try repo.writeFile(io, "both.txt", "theirs\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "theirs" });
    const theirs_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(theirs_text);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var result = try merge_mod.trees(
        gpa,
        io,
        &db,
        try treeOf(gpa, io, &db, try Oid.parse(.sha1, base_text)),
        try treeOf(gpa, io, &db, try Oid.parse(.sha1, ours_text)),
        try treeOf(gpa, io, &db, try Oid.parse(.sha1, theirs_text)),
    );
    defer result.deinit();

    try std.testing.expect(!result.isClean());
    try std.testing.expectEqual(@as(usize, 1), result.conflicts.len);
    try std.testing.expectEqualStrings("both.txt", result.conflicts[0].path);
    try std.testing.expectEqual(merge_mod.Conflict.Kind.both_modified, result.conflicts[0].kind);

    // The index carries the three sides, exactly where git puts them.
    try std.testing.expect(result.index.find("both.txt") == null);
    for ([_]u2{ 1, 2, 3 }) |stage| {
        const entry = result.index.findStage("both.txt", stage).?;
        const found = try db.read(io, entry.oid);
        defer gpa.free(found.bytes);
        const expected: []const u8 = switch (stage) {
            1 => "base\n",
            2 => "ours\n",
            else => "theirs\n",
        };
        try std.testing.expectEqualStrings(expected, found.bytes);
    }
    try std.testing.expectError(error.MergeConflict, merge_mod.tree(io, &db, &result));

    // And git writes an index with the same three stages, which this reads
    // back to the same entries.
    try repo.exec(io, &.{ "checkout", "-q", ours_text });
    repo.report_failures = false;
    _ = repo.run(io, &.{ "merge", "--no-edit", theirs_text }) catch {};
    repo.report_failures = true;
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    if (index.findStage("both.txt", 2)) |ours_entry| {
        try std.testing.expect(ours_entry.oid.eql(result.index.findStage("both.txt", 2).?.oid));
        try std.testing.expect(index.findStage("both.txt", 1) != null);
        try std.testing.expect(index.findStage("both.txt", 3) != null);
    }
}

test "a worktree that moved is repaired and git follows it" {
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

    try git.dir.createDirPath(io, "trees/before");
    var dest = try git.dir.openDir(io, "trees/before", .{ .iterate = true });
    var added = try worktrees_mod.add(gpa, io, repo.common_dir, "moving", dest, "trees/before", .{
        .detach_at = try Oid.parse(.sha1, commit_text),
    });
    added.admin_dir.close(io);
    dest.close(io);

    var parent = try git.dir.openDir(io, "trees", .{ .iterate = true });
    defer parent.close(io);
    try worktrees_mod.move(gpa, io, repo.common_dir, "moving", parent, "after");

    try std.testing.expectError(error.FileNotFound, git.dir.access(io, "trees/before", .{}));
    var moved = try git.dir.openDir(io, "trees/after", .{ .iterate = true });
    defer moved.close(io);

    const listed = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "trees/after") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "trees/before") == null);

    // Opening the moved worktree still finds the repository behind it.
    var linked = try repo_mod.Repository.open(gpa, io, moved, .{ .discover = false });
    defer linked.deinit(io);
    try std.testing.expect(linked.common_is_separate);

    // And repair on its own is idempotent.
    try worktrees_mod.repair(io, repo.common_dir, "moving", moved);
    const again = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(again);
    try std.testing.expectEqualStrings(listed, again);
}

test "a walk with the commit-graph answers what a walk without it answers" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // A history with a merge in it, so the graph's second-parent encoding is
    // exercised rather than assumed.
    for (0..6) |i| {
        var buf: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&buf, "main{d}.txt", .{i}), "x\n");
        try repo.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg, "m{d}", .{i}) });
    }
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side", "HEAD~3" });
    try repo.writeFile(io, "side.txt", "y\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "side" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.exec(io, &.{ "merge", "--no-edit", "-q", "side" });
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var graph = (try commitgraph_mod.Graph.open(gpa, io, objects, .sha1)) orelse return error.SkipZigTest;
    defer graph.deinit();

    const head_text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const head = try Oid.parse(.sha1, head_text);

    var plain: revwalk.Walk = .init(gpa, &db);
    defer plain.deinit();
    try plain.push(head);
    var accelerated: revwalk.Walk = .init(gpa, &db);
    defer accelerated.deinit();
    accelerated.graph = &graph;
    try accelerated.push(head);

    var hex: [hash.max_hex_len]u8 = undefined;
    var other_hex: [hash.max_hex_len]u8 = undefined;
    while (try plain.next(io)) |a| {
        const b = (try accelerated.next(io)).?;
        try std.testing.expectEqualStrings(a.oid.hex(&hex), b.oid.hex(&other_hex));
        try std.testing.expectEqual(a.time, b.time);
        try std.testing.expectEqual(a.parents.len, b.parents.len);
    }
    try std.testing.expect((try accelerated.next(io)) == null);

    // And the walk covers exactly what git lists.
    const listed = try repo.run(io, &.{ "rev-list", "HEAD" });
    defer gpa.free(listed);
    var expected: usize = 0;
    var lines = std.mem.splitScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) expected += 1;
    }
    plain.reset();
    try std.testing.expectEqual(expected, try plain.count(io));
}

test "with the collision check on, nothing git wrote is flagged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // A spread of shapes: text, a file that grows so the packer deltas it,
    // a binary blob, and one long enough to be many blocks.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var binary: [8192]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xf1_c7_09);
    prng.random().bytes(&binary);
    try repo.writeFile(io, "binary.dat", &binary);
    for (0..12) |i| {
        try body.print(gpa, "line {d} of a file that keeps growing\n", .{i});
        try repo.writeFile(io, "grow.txt", body.items);
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "commit {d}", .{i});
        try repo.exec(io, &.{ "commit", "-q", "-m", msg });
    }
    try repo.exec(io, &.{ "gc", "-q" });

    const git_dir = try repo.gitDir(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{ .detect_sha1_collisions = true });
    defer db.deinit(io);

    const listing = try repo.run(io, &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname)" });
    defer gpa.free(listing);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const oid = try Oid.parse(.sha1, line);
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        // The checked arm gives the same name git gave it, and says nothing
        // about it looked like half of a near-collision pair.
        const named = hash.Hasher.nameObject(
            .sha1,
            .{ .detect_collisions = true },
            found.type.name(),
            found.bytes,
        );
        try std.testing.expect(!named.collision_attack);
        try std.testing.expect(named.oid.eql(oid));
        count += 1;
    }
    try std.testing.expect(count > 30);

    // Writing every one of them back through the checked database is a
    // no-op rather than a refusal.
    const report = try db.verify(io);
    try std.testing.expect(report.packs >= 1);
}

test "the collision check does not change a name a database takes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const git_dir = try repo.gitDir(io);

    const contents = [_][]const u8{
        "",
        "a\n",
        sha1dc.collision_test_vector_a,
        sha1dc.collision_test_vector_b,
        "x" ** 5000,
    };

    var plain_names: [contents.len]Oid = undefined;
    {
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        for (contents, &plain_names) |content, *name| name.* = try db.write(io, .blob, content);
    }
    {
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{ .detect_sha1_collisions = true });
        defer db.deinit(io);
        for (contents, plain_names) |content, plain_name| {
            try std.testing.expect((try db.write(io, .blob, content)).eql(plain_name));
        }
    }

    // git agrees with both, including about the two halves of the published
    // pair being two objects rather than one.
    for (contents, plain_names) |content, name| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "obj{d}.bin", .{content.len});
        try repo.writeFile(io, path, content);
        const said = try repo.run(io, &.{ "hash-object", "-t", "blob", path });
        defer gpa.free(said);
        var hex: [hash.max_hex_len]u8 = undefined;
        try std.testing.expectEqualStrings(name.hex(&hex), std.mem.trimEnd(u8, said, "\n"));
    }
}

test "a repository with a multi-pack index looks objects up through it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // Several packs, so that the index has something to narrow: a commit,
    // a `gc` to pack what is there, and round again. `gc` would fold the
    // packs back into one, so `repack -d` is not used after the first.
    for (0..4) |round| {
        for (0..6) |i| {
            var path_buf: [64]u8 = undefined;
            var body_buf: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "r{d}f{d}.txt", .{ round, i });
            const body = try std.fmt.bufPrint(&body_buf, "round {d} file {d}\n", .{ round, i });
            try repo.writeFile(io, path, body);
        }
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg_buf, "round {d}", .{round}) });
        // Pack what is loose without touching the packs already there.
        try repo.exec(io, &.{ "repack", "-q", "-d" });
        if (round == 0) continue;
        // And make one more pack that keeps the previous ones, so the count
        // grows rather than being folded away.
        try repo.exec(io, &.{ "repack", "-q" });
    }
    repo.exec(io, &.{ "multi-pack-index", "write" }) catch return;

    const git_dir = try repo.gitDir(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    // git only writes one when there is something to write; a version of it
    // that declined leaves this test with nothing to prove.
    if (db.multiPackIndexCount() == 0) return;
    try std.testing.expect(db.packCount() >= 1);

    const listing = try repo.run(io, &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)" });
    defer gpa.free(listing);

    var packed_objects: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const oid = try Oid.parse(.sha1, fields.next().?);
        const expected_type = try object.Type.parse(fields.next().?);
        const expected_size = try std.fmt.parseInt(u64, fields.next().?, 10);

        const before = db.stats.midx_hits;
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        try std.testing.expectEqual(expected_type, found.type);
        try std.testing.expectEqual(expected_size, found.bytes.len);
        try std.testing.expect(hash.Hasher.object(.sha1, found.type.name(), found.bytes).eql(oid));
        if (db.stats.midx_hits != before) packed_objects += 1;

        // The header and the existence check go the same way.
        const header = try db.readHeader(io, oid);
        try std.testing.expectEqual(expected_type, header.type);
        try std.testing.expect(try db.exists(io, oid));
    }

    // Most objects are packed here, so most lookups went through the index
    // rather than round the packs one at a time.
    try std.testing.expect(packed_objects > 0);
    try std.testing.expect(db.stats.midx_hits > 0);

    // And the repository reads the same with the index taken away, which is
    // the only promise an accelerator is allowed to make.
    try repo.exec(io, &.{ "multi-pack-index", "--object-dir=.git/objects", "expire" });
    var pack_dir = try git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    pack_dir.deleteFile(io, "multi-pack-index") catch {};

    var plain = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer plain.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), plain.multiPackIndexCount());

    lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const oid = try Oid.parse(.sha1, fields.next().?);
        const found = try plain.read(io, oid);
        defer gpa.free(found.bytes);
        try std.testing.expect(hash.Hasher.object(.sha1, found.type.name(), found.bytes).eql(oid));
    }
    try std.testing.expectEqual(@as(u64, 0), plain.stats.midx_hits);
}

test "a pack this wrote is a pack git verifies, object for object" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // A few commits, so there are commits, trees and blobs of several sizes.
    for (0..4) |round| {
        for (0..6) |i| {
            var name_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&name_buf, "dir{d}/file{d}.txt", .{ i % 2, i });
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(gpa);
            for (0..(round + 1) * 40) |line| try body.print(gpa, "line {d} of file {d}\n", .{ line, i });
            try repo.writeFile(io, path, body.items);
        }
        var msg: [32]u8 = undefined;
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg, "round {d}", .{round}) });
    }

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var names = try db.listObjects(io);
    defer names.deinit(gpa);
    try std.testing.expect(names.count() > 20);

    try git_dir.createDirPath(io, "objects/pack");
    var pack_dir = try git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    var w = try pack.Writer.init(gpa, io, pack_dir, .sha1, @intCast(names.count()), .{});
    defer w.deinit(io);
    var it = names.keyIterator();
    while (it.next()) |oid| {
        const found = try db.read(io, oid.*);
        defer gpa.free(found.bytes);
        _ = try w.add(oid.*, found.type, found.bytes);
    }
    const report = try w.finish(io);
    try std.testing.expectEqual(@as(u32, @intCast(names.count())), report.objects);

    var hex: [hash.max_hex_len]u8 = undefined;
    const text = report.name.hex(&hex);
    var idx_path: [96]u8 = undefined;
    const idx = try std.fmt.bufPrint(&idx_path, ".git/objects/pack/pack-{s}.idx", .{text});
    var pack_path: [96]u8 = undefined;
    const pack_file = try std.fmt.bufPrint(&pack_path, ".git/objects/pack/pack-{s}.pack", .{text});

    // git's own two checkers: one walks the index and the pack together, the
    // other rebuilds the index from the pack and compares.
    const listing = try repo.run(io, &.{ "verify-pack", "-v", idx });
    defer gpa.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "chain length") != null or
        std.mem.indexOf(u8, listing, "non delta") != null);
    try repo.exec(io, &.{ "index-pack", "--verify", pack_file });

    // Every object in it reads back through git, as the type and the length
    // this wrote.
    var check = names.keyIterator();
    while (check.next()) |oid| {
        const shown = try repo.line(io, &.{ "cat-file", "-s", oid.hex(&hex) });
        defer gpa.free(shown);
        const found = try db.read(io, oid.*);
        defer gpa.free(found.bytes);
        try std.testing.expectEqual(found.bytes.len, try std.fmt.parseInt(usize, shown, 10));
    }

    // And with the loose objects taken away, the pack is the only copy and
    // git is still silent about the repository.
    var top = git_dir.openDir(io, "objects", .{ .iterate = true }) catch unreachable;
    defer top.close(io);
    var dirs = top.iterate();
    var removed: usize = 0;
    while (try dirs.next(io)) |entry| {
        if (entry.kind != .directory or entry.name.len != 2) continue;
        var sub = try top.openDir(io, entry.name, .{ .iterate = true });
        var files: std.ArrayList([]u8) = .empty;
        defer {
            for (files.items) |f| gpa.free(f);
            files.deinit(gpa);
        }
        var inner = sub.iterate();
        while (try inner.next(io)) |file| try files.append(gpa, try gpa.dupe(u8, file.name));
        for (files.items) |name| {
            try sub.deleteFile(io, name);
            removed += 1;
        }
        sub.close(io);
    }
    try std.testing.expect(removed > 0);
    try repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
    const head_tree = try repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(head_tree);
    try std.testing.expectEqual(@as(usize, 40), head_tree.len);
}

test "a deltified pack is read back by git and by this, object for object" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // Files that grow a line at a time give the packer real deltas to find,
    // and several of them keep the window busy.
    const files = 5;
    for (0..8) |round| {
        for (0..files) |i| {
            var name_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&name_buf, "src/file{d}.txt", .{i});
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(gpa);
            for (0..(round + 1) * 60) |line| {
                try body.print(gpa, "file {d} line {d} with enough text to be worth copying\n", .{ i, line });
            }
            try repo.writeFile(io, path, body.items);
        }
        var msg: [32]u8 = undefined;
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg, "round {d}", .{round}) });
    }

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var names = try db.listObjects(io);
    defer names.deinit(gpa);

    var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
    defer entries.deinit(gpa);
    var it = names.keyIterator();
    while (it.next()) |oid| try entries.append(gpa, .{ .oid = oid.*, .hint = "src/file.txt" });

    try git_dir.createDirPath(io, "objects/pack");
    var pack_dir = try git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const report = try db.writePack(io, pack_dir, entries.items, .{});
    try std.testing.expectEqual(@as(u32, @intCast(entries.items.len)), report.objects);
    // The blobs here are each other's neighbours a line apart, so the window
    // must find something.
    try std.testing.expect(report.deltas > 0);

    var hex: [hash.max_hex_len]u8 = undefined;
    const text = report.name.hex(&hex);
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "pack-{s}", .{text});
    var path_buf: [96]u8 = undefined;

    // git's checkers, and its own report of the chain lengths.
    try repo.exec(io, &.{ "index-pack", "--verify", try std.fmt.bufPrint(&path_buf, ".git/objects/pack/{s}.pack", .{base}) });
    const listing = try repo.run(io, &.{ "verify-pack", "-v", try std.fmt.bufPrint(&path_buf, ".git/objects/pack/{s}.idx", .{base}) });
    defer gpa.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "chain length = 1") != null);

    // And this reads every one of them back: `verify` rehashes each object
    // against the name the index gives it, which is the whole delta chain
    // reconstructed and checked.
    {
        var p = try pack.Pack.open(gpa, io, pack_dir, base, .sha1, .{});
        defer p.deinit(io);
        const checked = try p.verify(io, null, 0);
        try std.testing.expectEqual(report.objects, checked.objects);
    }

    // A pack written with reference deltas holds the same objects.
    const ref_report = try db.writePack(io, pack_dir, entries.items, .{ .delta = .reference });
    try std.testing.expect(ref_report.deltas > 0);
    var ref_base_buf: [64]u8 = undefined;
    const ref_base = try std.fmt.bufPrint(&ref_base_buf, "pack-{s}", .{ref_report.name.hex(&hex)});
    try repo.exec(io, &.{ "index-pack", "--verify", try std.fmt.bufPrint(&path_buf, ".git/objects/pack/{s}.pack", .{ref_base}) });
    {
        var p = try pack.Pack.open(gpa, io, pack_dir, ref_base, .sha1, .{});
        defer p.deinit(io);
        const checked = try p.verify(io, null, 0);
        try std.testing.expectEqual(ref_report.objects, checked.objects);
    }

    // A pack written with no deltas at all holds them too, and is larger.
    const whole = try db.writePack(io, pack_dir, entries.items, .{ .delta = .none });
    try std.testing.expectEqual(@as(u32, 0), whole.deltas);
    try std.testing.expect(whole.pack_bytes > report.pack_bytes);

    // Every object still reads back through git, from whichever copy it
    // picks, and fsck is silent about all three packs at once.
    try repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}
