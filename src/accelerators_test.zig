//! Accelerator files are held to git's writer and git's verifier.
const std = @import("std");
const testgit = @import("testgit.zig");
const ops = @import("accelerators.zig");
const graph = @import("commitgraph.zig");
const odb = @import("odb_core.zig");
const hash = @import("hash.zig");
const Oid = hash.Oid;
const io = std.testing.io;
const gpa = std.testing.allocator;

fn commit(repo: *testgit.Repo, n: usize) !void {
    try repo.dir.createDirPath(io, "dir/sub");
    var content: [80]u8 = undefined;
    try repo.writeFile(io, "dir/sub/na\xc3\xafve.txt", try std.fmt.bufPrint(&content, "change {d}\n", .{n}));
    try repo.exec(io, &.{ "add", "dir/sub/na\xc3\xafve.txt" });
    const date = try std.fmt.allocPrint(gpa, "@{d} +0000", .{switch (n % 4) {
        0 => @as(i64, 4_200_000_000),
        1 => @as(i64, 1_000_000_000),
        else => 1_700_000_000 + @as(i64, @intCast(n)),
    }});
    defer gpa.free(date);
    try repo.isolated.?.put("GIT_AUTHOR_DATE", date);
    try repo.isolated.?.put("GIT_COMMITTER_DATE", date);
    try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&content, "commit {d}", .{n}) });
}

fn tip(repo: *testgit.Repo, kind: hash.Kind) !Oid {
    const text = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(text);
    return Oid.parse(kind, text);
}

fn sameFile(repo: *testgit.Repo, path: []const u8, expected: []const u8) !void {
    const actual = try repo.readFile(io, path);
    defer gpa.free(actual);
    if (!std.mem.eql(u8, expected, actual)) {
        const count = @min(expected.len, actual.len);
        for (expected[0..count], actual[0..count], 0..) |a, b, i| if (a != b) {
            std.debug.print("{s}: first difference at {d}: git {x}, relic {x}; sizes {d}/{d}\n", .{ path, i, a, b, expected.len, actual.len });
            break;
        };
    }
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "commit graph writing agrees byte for byte with git, including overflow and Bloom versions" {
    // Generation v2 and Bloom v2 appeared after the oldest supported Git.
    try testgit.requireGitVersion(gpa, io, 2, 43);
    for ([_]hash.Kind{ .sha1, .sha256 }) |kind| {
        var repo = try testgit.Repo.init(gpa, io, if (kind == .sha1) &.{} else &.{"--object-format=sha256"});
        defer repo.deinit();
        for (0..9) |n| try commit(&repo, n);
        const git_dir = try repo.gitDir(io);
        defer git_dir.close(io);
        var db = try odb.Odb.open(gpa, io, git_dir, kind, .{});
        defer db.deinit(io);
        const head = try tip(&repo, kind);
        for ([_]u32{ 0, 1, 2 }) |version| {
            const config = try std.fmt.allocPrint(gpa, "commitGraph.changedPathsVersion={d}", .{version});
            defer gpa.free(config);
            try repo.exec(io, if (version == 0) &.{ "commit-graph", "write", "--reachable" } else &.{ "-c", config, "commit-graph", "write", "--reachable", "--changed-paths" });
            const expected = try repo.readFile(io, ".git/objects/info/commit-graph");
            defer gpa.free(expected);
            try db.objectsDirectory().deleteFile(io, "info/commit-graph");
            _ = try ops.writeCommitGraph(gpa, io, &db, &.{head}, .{ .changed_paths = if (version == 0) null else .{ .version = version } });
            try sameFile(&repo, ".git/objects/info/commit-graph", expected);
            try repo.exec(io, &.{ "commit-graph", "verify" });
            var parsed = (try graph.Graph.open(gpa, io, db.objectsDirectory(), kind)).?;
            defer parsed.deinit();
            try parsed.verify();
            try std.testing.expectEqual(@as(u32, 9), parsed.count);
            try db.objectsDirectory().deleteFile(io, "info/commit-graph");
        }
    }
}

test "split commit graph chains and merge thresholds agree byte for byte with git" {
    // This fixture compares generation-v2 split layers.
    try testgit.requireGitVersion(gpa, io, 2, 31);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..8) |n| try commit(&repo, n);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable", "--split=no-merge", "--changed-paths" });
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    for ([_]ops.Split{ .no_merge, .merge, .merge, .replace }, 0..) |mode, cycle| {
        const before = try repo.readFile(io, ".git/objects/info/commit-graphs/commit-graph-chain");
        defer gpa.free(before);
        var before_hashes = std.mem.tokenizeScalar(u8, before, '\n');
        var before_files: std.ArrayList([]const u8) = .empty;
        defer {
            for (before_files.items) |bytes| gpa.free(bytes);
            before_files.deinit(gpa);
        }
        while (before_hashes.next()) |name| {
            const path = try std.fmt.allocPrint(gpa, ".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
            defer gpa.free(path);
            try before_files.append(gpa, try repo.readFile(io, path));
        }
        try commit(&repo, 9 + cycle);
        const head = try tip(&repo, .sha1);
        const split_arg: []const u8 = switch (mode) {
            .no_merge => "--split=no-merge",
            .merge => "--split",
            .replace => "--split=replace",
            else => unreachable,
        };
        try repo.exec(io, &.{ "commit-graph", "write", "--reachable", split_arg, "--size-multiple=2", "--max-commits=2", "--changed-paths" });
        const expected_chain = try repo.readFile(io, ".git/objects/info/commit-graphs/commit-graph-chain");
        defer gpa.free(expected_chain);
        var hashes = std.mem.tokenizeScalar(u8, expected_chain, '\n');
        var expected_files: std.ArrayList([]const u8) = .empty;
        defer {
            for (expected_files.items) |bytes| gpa.free(bytes);
            expected_files.deinit(gpa);
        }
        while (hashes.next()) |name| {
            const path = try std.fmt.allocPrint(gpa, ".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
            defer gpa.free(path);
            try expected_files.append(gpa, try repo.readFile(io, path));
        }
        try db.objectsDirectory().deleteFile(io, "info/commit-graphs/commit-graph-chain");
        try repo.writeFile(io, ".git/objects/info/commit-graphs/commit-graph-chain", before);
        before_hashes.reset();
        var before_i: usize = 0;
        while (before_hashes.next()) |name| : (before_i += 1) {
            const path = try std.fmt.allocPrint(gpa, ".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
            defer gpa.free(path);
            repo.dir.deleteFile(io, path) catch |err| if (err != error.FileNotFound) {
                return err;
            };
            try repo.writeFile(io, path, before_files.items[before_i]);
        }
        _ = ops.writeCommitGraph(gpa, io, &db, &.{head}, .{ .split = mode, .max_commits = 2, .changed_paths = .{} }) catch |err| {
            std.debug.print("write {s}: {s}\n", .{ @tagName(mode), @errorName(err) });
            return err;
        };
        try sameFile(&repo, ".git/objects/info/commit-graphs/commit-graph-chain", expected_chain);
        hashes.reset();
        var i: usize = 0;
        while (hashes.next()) |name| : (i += 1) {
            const path = try std.fmt.allocPrint(gpa, ".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
            defer gpa.free(path);
            try sameFile(&repo, path, expected_files.items[i]);
        }
        try repo.exec(io, &.{ "commit-graph", "verify" });
        var parsed = (try graph.Graph.open(gpa, io, db.objectsDirectory(), .sha1)).?;
        defer parsed.deinit();
        parsed.verify() catch |err| {
            std.debug.print("verify {s}: {s}\n", .{ @tagName(mode), @errorName(err) });
            return err;
        };
        try std.testing.expect(parsed.find(head) != null);
    }
}

const midx = @import("midx.zig");
const bitmaps = @import("bitmap.zig");
const bitmap_store = @import("bitmap_store.zig");
const objectwalk = @import("objectwalk.zig");

fn linearCommit(repo: *testgit.Repo, n: usize) !void {
    var text: [64]u8 = undefined;
    try repo.writeFile(io, "file", try std.fmt.bufPrint(&text, "contents {d}\n", .{n}));
    try repo.exec(io, &.{ "add", "file" });
    try testgit.setDate(&repo.isolated.?, 1_700_000_000 + @as(i64, @intCast(n)));
    try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&text, "commit {d}", .{n}) });
}

fn bitmapPath(repo: *testgit.Repo, prefix: []const u8) ![]u8 {
    const dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (std.mem.startsWith(u8, entry.name, prefix) and std.mem.endsWith(u8, entry.name, ".bitmap")) {
        return std.fmt.allocPrint(gpa, ".git/objects/pack/{s}", .{entry.name});
    };
    return error.TestUnexpectedResult;
}

test "MIDX object selection, RIDX, BTMP and its bitmap agree byte for byte with git" {
    // MIDX bitmaps and bitmap lookup tables appeared after Git 2.30.
    try testgit.requireGitVersion(gpa, io, 2, 43);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..18) |n| {
        try linearCommit(&repo, n);
        if (n % 6 == 5) try repo.exec(io, &.{ "repack", "-q", "-d" });
    }
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const head = try tip(&repo, .sha1);
    try repo.exec(io, &.{ "multi-pack-index", "write" });
    const plain = try repo.readFile(io, ".git/objects/pack/multi-pack-index");
    defer gpa.free(plain);
    try db.objectsDirectory().deleteFile(io, "pack/multi-pack-index");
    _ = try ops.writeMidx(gpa, io, &db, .{});
    try sameFile(&repo, ".git/objects/pack/multi-pack-index", plain);
    try repo.exec(io, &.{ "multi-pack-index", "verify" });
    try db.objectsDirectory().deleteFile(io, "pack/multi-pack-index");
    for ([_]bool{ false, true }) |lookup| {
        const config: []const u8 = if (lookup) "pack.writeBitmapLookupTable=true" else "pack.writeBitmapLookupTable=false";
        try repo.exec(io, &.{ "-c", config, "multi-pack-index", "write", "--bitmap" });
        const expected = try repo.readFile(io, ".git/objects/pack/multi-pack-index");
        defer gpa.free(expected);
        const path = try bitmapPath(&repo, "multi-pack-index-");
        defer gpa.free(path);
        const expected_bitmap = try repo.readFile(io, path);
        defer gpa.free(expected_bitmap);
        try db.objectsDirectory().deleteFile(io, "pack/multi-pack-index");
        _ = try ops.writeMidxBitmap(gpa, io, &db, &.{head}, .{}, .{ .lookup_table = lookup });
        try sameFile(&repo, ".git/objects/pack/multi-pack-index", expected);
        try sameFile(&repo, path, expected_bitmap);
        try repo.exec(io, &.{ "multi-pack-index", "verify" });
        try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
        const count = try objectwalk.countObjects(gpa, io, &db, &.{head}, &.{});
        try std.testing.expectEqual(@as(u64, 18), count.commits);
        try std.testing.expectEqual(@as(u64, 54), count.total());
        try std.testing.expect(db.stats.bitmap_hits > 0);
        try db.objectsDirectory().deleteFile(io, "pack/multi-pack-index");
        try repo.dir.deleteFile(io, path);
    }
}

test "pack bitmap bytes, XORs, hashes, lookup table and accelerated counts agree with git" {
    // This fixture compares bitmap lookup tables introduced after Git 2.30.
    try testgit.requireGitVersion(gpa, io, 2, 34);
    for ([_]bool{ false, true }) |lookup| {
        var repo = try testgit.Repo.init(gpa, io, &.{});
        defer repo.deinit();
        for (0..24) |n| try linearCommit(&repo, n);
        const config: []const u8 = if (lookup) "pack.writeBitmapLookupTable=true" else "pack.writeBitmapLookupTable=false";
        try repo.exec(io, &.{ "-c", config, "repack", "-q", "-a", "-d", "-b" });
        const path = try bitmapPath(&repo, "pack-");
        defer gpa.free(path);
        const expected = try repo.readFile(io, path);
        defer gpa.free(expected);
        const git_dir = try repo.gitDir(io);
        defer git_dir.close(io);
        var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        const head = try tip(&repo, .sha1);
        const pack_name = std.fs.path.basename(path);
        try repo.dir.deleteFile(io, path);
        try ops.writePackBitmap(gpa, io, &db, pack_name[0 .. pack_name.len - 7], &.{head}, .{ .lookup_table = lookup });
        try sameFile(&repo, path, expected);
        try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
        var store = (try bitmap_store.Store.open(gpa, io, db.objectsDirectory(), .sha1)).?;
        defer store.deinit();
        const head_words = (try store.reach(gpa, head)).?;
        defer gpa.free(head_words);
        try std.testing.expectEqual(@as(u64, 72), bitmaps.count(head_words, null));
        const old_text = try repo.line(io, &.{ "rev-parse", "HEAD~7" });
        defer gpa.free(old_text);
        const old = try Oid.parse(.sha1, old_text);
        try std.testing.expectEqual(@as(u64, 7), try objectwalk.countCommits(gpa, io, &db, &.{head}, &.{old}));
        const counts = try objectwalk.countObjects(gpa, io, &db, &.{head}, &.{old});
        try std.testing.expectEqual(@as(u64, 21), counts.total());
        var missing = try objectwalk.missing(gpa, io, &db, &.{head}, &.{old});
        defer missing.deinit();
        try std.testing.expectEqual(@as(usize, 21), missing.entries.len);
        const expected_objects = try repo.run(io, &.{ "rev-list", "--objects", "HEAD", "^HEAD~7" });
        defer gpa.free(expected_objects);
        var set: Oid.Set = .empty;
        defer set.deinit(gpa);
        var lines = std.mem.tokenizeScalar(u8, expected_objects, '\n');
        while (lines.next()) |line| try set.put(gpa, try Oid.parse(.sha1, line[0..40]), {});
        for (missing.entries) |entry| try std.testing.expect(set.contains(entry.oid));
        try std.testing.expect(db.stats.bitmap_hits >= 3);
        // A new commit outside the bitmap takes the ordinary walk.
        try linearCommit(&repo, 24);
        const next = try tip(&repo, .sha1);
        const hits = db.stats.bitmap_hits;
        try std.testing.expectEqual(@as(u64, 25), try objectwalk.countCommits(gpa, io, &db, &.{next}, &.{}));
        try std.testing.expectEqual(hits, db.stats.bitmap_hits);
    }
}

test "MIDX repack and expire retain kept packs and match git's two-step semantics" {
    for ([_]bool{ false, true }) |kept| {
        var repo = try testgit.Repo.init(gpa, io, &.{});
        defer repo.deinit();
        for (0..12) |n| {
            try linearCommit(&repo, n);
            if (n % 4 == 3) try repo.exec(io, &.{ "repack", "-q", "-d" });
        }
        try repo.exec(io, &.{ "multi-pack-index", "write" });
        const git_dir = try repo.gitDir(io);
        defer git_dir.close(io);
        var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        const dir = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
        defer dir.close(io);
        var before = (try midx.Index.open(gpa, io, dir, .sha1)).?;
        defer before.deinit();
        try std.testing.expectEqual(@as(u32, 3), before.pack_count);
        if (kept) {
            const path = try std.fmt.allocPrint(gpa, ".git/objects/pack/{s}.keep", .{before.packName(0).?});
            defer gpa.free(path);
            try repo.writeFile(io, path, "");
        }
        try std.testing.expectEqual(@as(?@import("pack.zig").WriteReport, null), try ops.repackMidx(gpa, io, &db, .{ .batch_size = 1 }));
        const report = (try ops.repackMidx(gpa, io, &db, .{ .pack = .{ .threads = 1 } })).?;
        try std.testing.expect(report.objects > 0);
        try repo.exec(io, &.{ "multi-pack-index", "verify" });
        _ = try ops.expireMidx(gpa, io, &db, .none);
        try repo.exec(io, &.{ "multi-pack-index", "verify" });
        var after = (try midx.Index.open(gpa, io, dir, .sha1)).?;
        defer after.deinit();
        try std.testing.expectEqual(@as(u32, if (kept) 2 else 1), after.pack_count);
        const ids = try repo.run(io, &.{ "rev-list", "--objects", "--all" });
        defer gpa.free(ids);
        var lines = std.mem.tokenizeScalar(u8, ids, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            try std.testing.expect((try after.find(try Oid.parse(.sha1, line[0..40]))) != null);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, after.count), count);
        // Git sees nothing left to expire; the native expire's file set is final.
        const listing_before = try repo.run(io, &.{ "count-objects", "-v" });
        defer gpa.free(listing_before);
        try repo.exec(io, &.{ "multi-pack-index", "expire" });
        const listing_after = try repo.run(io, &.{ "count-objects", "-v" });
        defer gpa.free(listing_after);
        try std.testing.expectEqualStrings(listing_before, listing_after);
    }
}

test "configured maintenance writes full and split commit graphs and repack bitmaps" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..5) |n| try linearCommit(&repo, n);
    var native = try @import("repo_core.zig").Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectEqual(@as(?Oid, null), try ops.writeConfiguredCommitGraph(gpa, io, &native, .fetch));
    _ = try ops.writeConfiguredCommitGraph(gpa, io, &native, .gc);
    try repo.exec(io, &.{ "commit-graph", "verify" });
    try repo.exec(io, &.{ "config", "fetch.writeCommitGraph", "true" });
    _ = try native.refreshConfig(io, null);
    try linearCommit(&repo, 6);
    _ = try ops.writeConfiguredCommitGraph(gpa, io, &native, .fetch);
    try repo.exec(io, &.{ "commit-graph", "verify" });
    _ = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 2, .sync = .none }, .remove_packs = true });
    try repo.exec(io, &.{ "commit-graph", "verify" });
    try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
}

test "bitmap commit selection past the dense region agrees byte for byte with git" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..140) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "repack", "-q", "-a", "-d", "-b" });
    const path = try bitmapPath(&repo, "pack-");
    defer gpa.free(path);
    const expected = try repo.readFile(io, path);
    defer gpa.free(expected);
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const head = try tip(&repo, .sha1);
    const base = std.fs.path.basename(path);
    try repo.dir.deleteFile(io, path);
    try ops.writePackBitmap(gpa, io, &db, base[0 .. base.len - 7], &.{head}, .{});
    try sameFile(&repo, path, expected);
    try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
}

test "preferred pack duplicate selection agrees byte for byte with git" {
    // Preferred-pack selection appeared with MIDX bitmap writing.
    try testgit.requireGitVersion(gpa, io, 2, 34);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..12) |n| {
        try linearCommit(&repo, n);
        if (n % 4 == 3) try repo.exec(io, &.{ "repack", "-q", "-d" });
    }
    try repo.exec(io, &.{ "repack", "-q", "-a" });
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const packs = try db.objectsDirectory().openDir(io, "pack", .{ .iterate = true });
    defer packs.close(io);
    var iterator = packs.iterate();
    var preferred: ?[]u8 = null;
    defer if (preferred) |p| gpa.free(p);
    while (try iterator.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".idx")) {
        preferred = try gpa.dupe(u8, entry.name);
        break;
    };
    const arg = try std.fmt.allocPrint(gpa, "--preferred-pack={s}", .{preferred.?});
    defer gpa.free(arg);
    try repo.exec(io, &.{ "multi-pack-index", "write", arg });
    const expected = try repo.readFile(io, ".git/objects/pack/multi-pack-index");
    defer gpa.free(expected);
    try packs.deleteFile(io, "multi-pack-index");
    _ = try ops.writeMidx(gpa, io, &db, .{ .preferred_pack = preferred.? });
    try sameFile(&repo, ".git/objects/pack/multi-pack-index", expected);
    try repo.exec(io, &.{ "multi-pack-index", "verify" });
}

test "accelerator files are deterministic across pack worker counts" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..16) |n| try linearCommit(&repo, n);
    var native = try @import("repo_core.zig").Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    const first = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 1, .sync = .none }, .remove_packs = true });
    const graph_bytes = try repo.readFile(io, ".git/objects/info/commit-graph");
    defer gpa.free(graph_bytes);
    const path = try bitmapPath(&repo, "pack-");
    defer gpa.free(path);
    const bitmap_bytes = try repo.readFile(io, path);
    defer gpa.free(bitmap_bytes);
    const second = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 4, .sync = .none }, .remove_packs = true });
    try std.testing.expect(first.written.?.name.eql(second.written.?.name));
    try sameFile(&repo, ".git/objects/info/commit-graph", graph_bytes);
    try sameFile(&repo, path, bitmap_bytes);
    try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
}

test "a MIDX bitmap carries the existing pack bitmap's name hash cache" {
    for ([_]hash.Kind{ .sha1, .sha256 }) |kind| {
        try testgit.requireGitVersion(gpa, io, 2, 43);
        var repo = try testgit.Repo.init(gpa, io, if (kind == .sha1) &.{} else &.{"--object-format=sha256"});
        defer repo.deinit();
        for (0..12) |n| try linearCommit(&repo, n);
        try repo.exec(io, &.{ "repack", "-q", "-a", "-d", "-b" });
        try repo.exec(io, &.{ "multi-pack-index", "write", "--bitmap" });
        const path = try bitmapPath(&repo, "multi-pack-index-");
        defer gpa.free(path);
        const expected = try repo.readFile(io, path);
        defer gpa.free(expected);
        try repo.dir.deleteFile(io, path);
        try repo.dir.deleteFile(io, ".git/objects/pack/multi-pack-index");
        const dir = try repo.gitDir(io);
        defer dir.close(io);
        var db = try odb.Odb.open(gpa, io, dir, kind, .{});
        defer db.deinit(io);
        const head = try tip(&repo, kind);
        _ = try ops.writeMidxBitmap(gpa, io, &db, &.{head}, .{}, .{});
        try sameFile(&repo, path, expected);
        try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
    }
}

test "merged split layers are marked at the write time before an older expiry cutoff" {
    try testgit.requireGitVersion(gpa, io, 2, 31);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..3) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable", "--split" });
    const chain = try repo.readFile(io, ".git/objects/info/commit-graphs/commit-graph-chain");
    defer gpa.free(chain);
    const path = try std.fmt.allocPrint(gpa, ".git/objects/info/commit-graphs/graph-{s}.graph", .{std.mem.trim(u8, chain, "\n")});
    defer gpa.free(path);
    const fs = @import("fs.zig");
    try fs.setTimestamps(io, repo.dir, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
    try linearCommit(&repo, 3);
    const dir = try repo.gitDir(io);
    defer dir.close(io);
    var db = try odb.Odb.open(gpa, io, dir, .sha1, .{});
    defer db.deinit(io);
    const head = try tip(&repo, .sha1);
    _ = try ops.writeCommitGraph(gpa, io, &db, &.{head}, .{ .split = .replace, .expire_time = 1 });
    try repo.dir.access(io, path, .{});
    const native_time = (try repo.dir.statFile(io, path, .{})).mtime.toSeconds();
    try std.testing.expect(native_time > 1);
    // Git marks the layer too, so an older cutoff preserves it.
    try fs.setTimestamps(io, repo.dir, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
    try repo.writeFile(io, ".git/objects/info/commit-graphs/commit-graph-chain", chain);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable", "--split=replace", "--expire-time=@1" });
    try repo.dir.access(io, path, .{});
    try std.testing.expect((try repo.dir.statFile(io, path, .{})).mtime.toSeconds() > 1);
}
