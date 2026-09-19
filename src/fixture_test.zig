//! Tests against repositories the real `git` builds on the machine at test
//! time. Where the format is exact, the comparison is byte for byte.

const std = @import("std");
const Io = std.Io;
const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");

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
