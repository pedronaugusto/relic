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
