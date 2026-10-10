//! Accelerator files are held to git's writer and git's verifier.
const std = @import("std");
const testgit = @import("../testing/git.zig");
const ops = @import("maintenance.zig");
const graph = @import("../odb/commitgraph.zig");
const odb = @import("../odb/odb.zig");
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const io = std.testing.io;
const gpa = std.testing.allocator;

fn commit(repo: *testgit.Repo, n: usize) !void {
    try repo.dir.createDirPath(io, "dir/sub");
    var content: [80]u8 = undefined;
    try repo.writeFile(io, "dir/sub/na\xc3\xafve.txt", try std.mem.print(&content, "change {d}\n", .{n}));
    try repo.exec(io, &.{ "add", "dir/sub/na\xc3\xafve.txt" });
    const date = try gpa.print("@{d} +0000", .{switch (n % 4) {
        0 => @as(i64, 4_200_000_000),
        1 => @as(i64, 1_000_000_000),
        else => 1_700_000_000 + @as(i64, @intCast(n)),
    }});
    defer gpa.free(date);
    try repo.isolated.?.put("GIT_AUTHOR_DATE", date);
    try repo.isolated.?.put("GIT_COMMITTER_DATE", date);
    try repo.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&content, "commit {d}", .{n}) });
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
            const config = try gpa.print("commitGraph.changedPathsVersion={d}", .{version});
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
            const path = try gpa.print(".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
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
            const path = try gpa.print(".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
            defer gpa.free(path);
            try expected_files.append(gpa, try repo.readFile(io, path));
        }
        try db.objectsDirectory().deleteFile(io, "info/commit-graphs/commit-graph-chain");
        try repo.writeFile(io, ".git/objects/info/commit-graphs/commit-graph-chain", before);
        before_hashes.reset();
        var before_i: usize = 0;
        while (before_hashes.next()) |name| : (before_i += 1) {
            const path = try gpa.print(".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
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
            const path = try gpa.print(".git/objects/info/commit-graphs/graph-{s}.graph", .{name});
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

const midx = @import("../odb/midx.zig");
const bitmaps = @import("../odb/bitmap.zig");
const bitmap_store = @import("../odb/bitmap/reachability.zig");
const objectwalk = @import("../walk/objectwalk.zig");
const pack_mod = @import("../odb/pack.zig");
const repo_mod = @import("../repo/repo.zig");

fn linearCommit(repo: *testgit.Repo, n: usize) !void {
    var text: [64]u8 = undefined;
    try repo.writeFile(io, "file", try std.mem.print(&text, "contents {d}\n", .{n}));
    try repo.exec(io, &.{ "add", "file" });
    try testgit.setDate(&repo.isolated.?, 1_700_000_000 + @as(i64, @intCast(n)));
    try repo.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&text, "commit {d}", .{n}) });
}

fn bitmapPath(repo: *testgit.Repo, prefix: []const u8) ![]u8 {
    const dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (std.mem.startsWith(u8, entry.name, prefix) and std.mem.endsWith(u8, entry.name, ".bitmap")) {
        return gpa.print(".git/objects/pack/{s}", .{entry.name});
    };
    return error.TestUnexpectedResult;
}

test "MIDX object selection, RIDX, BTMP and its bitmap agree byte for byte with git" {
    // The MIDX bitmap and its lookup table as git writes them from 2.43 on.
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
        _ = try ops.writeMidxBitmap(gpa, io, &db, .{ .tips = &.{head}, .midx_options = .{} }, .{ .lookup_table = lookup });
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
        const pack_name = std.Io.Dir.path.basename(path);
        try repo.dir.deleteFile(io, path);
        try ops.writePackBitmap(gpa, io, &db, .{ .pack_name = pack_name[0 .. pack_name.len - 7], .tips = &.{head} }, .{ .lookup_table = lookup });
        // git writes these bytes from 2.55 on; every git reads them.
        if (try testgit.gitAtLeast(gpa, io, 2, 55)) try sameFile(&repo, path, expected);
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
        var missing = try objectwalk.missing(gpa, io, &db, &.{head}, .{ .exclude = &.{old} });
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
            const path = try gpa.print(".git/objects/pack/{s}.keep", .{before.packName(0).?});
            defer gpa.free(path);
            try repo.writeFile(io, path, "");
        }
        try std.testing.expectEqual(@as(?pack_mod.WriteReport, null), try ops.repackMidx(gpa, io, &db, .{ .batch_size = 1 }));
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
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectEqual(@as(?Oid, null), try ops.writeConfiguredCommitGraph(gpa, io, &native, .fetch));
    _ = try ops.writeConfiguredCommitGraph(gpa, io, &native, .gc);
    try repo.exec(io, &.{ "commit-graph", "verify" });
    try repo.exec(io, &.{ "config", "fetch.writeCommitGraph", "true" });
    _ = try native.refreshConfig(io, null);
    try linearCommit(&repo, 6);
    _ = try ops.writeConfiguredCommitGraph(gpa, io, &native, .fetch);
    try repo.exec(io, &.{ "commit-graph", "verify" });
    _ = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 2 }, .remove_packs = true });
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
    const base = std.Io.Dir.path.basename(path);
    try repo.dir.deleteFile(io, path);
    try ops.writePackBitmap(gpa, io, &db, .{ .pack_name = base[0 .. base.len - 7], .tips = &.{head} }, .{});
    // git writes these bytes from 2.55 on; every git reads them.
    if (try testgit.gitAtLeast(gpa, io, 2, 55)) try sameFile(&repo, path, expected);
    try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
}

test "preferred pack duplicate selection agrees byte for byte with git" {
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
    const arg = try gpa.print("--preferred-pack={s}", .{preferred.?});
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
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    const first = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 1 }, .remove_packs = true });
    const graph_bytes = try repo.readFile(io, ".git/objects/info/commit-graph");
    defer gpa.free(graph_bytes);
    const path = try bitmapPath(&repo, "pack-");
    defer gpa.free(path);
    const bitmap_bytes = try repo.readFile(io, path);
    defer gpa.free(bitmap_bytes);
    const second = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 4 }, .remove_packs = true });
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
        var db = try odb.Odb.open(gpa, io, dir, kind, .{ .use_bitmaps = false });
        defer db.deinit(io);
        const head = try tip(&repo, kind);
        _ = try ops.writeMidxBitmap(gpa, io, &db, .{ .tips = &.{head}, .midx_options = .{} }, .{});
        try sameFile(&repo, path, expected);
        try repo.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
    }
}

test "merged split layers are marked at the write time before an older expiry cutoff" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..3) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable", "--split" });
    const chain = try repo.readFile(io, ".git/objects/info/commit-graphs/commit-graph-chain");
    defer gpa.free(chain);
    const path = try gpa.print(".git/objects/info/commit-graphs/graph-{s}.graph", .{std.mem.trim(u8, chain, "\n")});
    defer gpa.free(path);
    const fs = @import("../fs/fs.zig");
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
    // the chain is read-only, as git leaves it
    try repo.dir.deleteFile(io, ".git/objects/info/commit-graphs/commit-graph-chain");
    try repo.writeFile(io, ".git/objects/info/commit-graphs/commit-graph-chain", chain);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable", "--split=replace", "--expire-time=@1" });
    try repo.dir.access(io, path, .{});
    try std.testing.expect((try repo.dir.statFile(io, path, .{})).mtime.toSeconds() > 1);
}

test "an unchanged MIDX bitmap is retained even when bitmap configuration changes" {
    try testgit.requireGitVersion(gpa, io, 2, 43);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..5) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "repack", "-q", "-a", "-d" });
    try repo.exec(io, &.{ "-c", "pack.writeBitmapLookupTable=false", "multi-pack-index", "write", "--bitmap" });
    const path = try bitmapPath(&repo, "multi-pack-index-");
    defer gpa.free(path);
    const expected = try repo.readFile(io, path);
    defer gpa.free(expected);
    try repo.exec(io, &.{ "-c", "pack.writeBitmapLookupTable=true", "multi-pack-index", "write", "--bitmap" });
    try sameFile(&repo, path, expected);
    const dir = try repo.gitDir(io);
    defer dir.close(io);
    var db = try odb.Odb.open(gpa, io, dir, .sha1, .{ .use_bitmaps = false });
    defer db.deinit(io);
    const head = try tip(&repo, .sha1);
    _ = try ops.writeMidxBitmap(gpa, io, &db, .{ .tips = &.{head}, .midx_options = .{} }, .{ .lookup_table = true });
    try sameFile(&repo, path, expected);
}

test "a bitmap whose pack has disappeared is refused instead of answering phantom objects" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..3) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "repack", "-q", "-a", "-d", "-b" });
    const bitmap_path = try bitmapPath(&repo, "pack-");
    defer gpa.free(bitmap_path);
    const pack_path = try gpa.print("{s}.pack", .{bitmap_path[0 .. bitmap_path.len - 7]});
    defer gpa.free(pack_path);
    try repo.dir.deleteFile(io, pack_path);
    const objects = try repo.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    try std.testing.expectError(error.CorruptReachabilityBitmap, bitmap_store.Store.open(gpa, io, objects, .sha1));
}

test "MIDX bitmap discovery preserves filesystem refusals for its packs" {
    try testgit.requireGitVersion(gpa, io, 2, 43);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..3) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "repack", "-q", "-a", "-d" });
    try repo.exec(io, &.{ "multi-pack-index", "write", "--bitmap" });
    const objects = try repo.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    const Probe = struct {
        var refusal: std.Io.Dir.AccessError = error.AccessDenied;
        fn access(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
            return refusal;
        }
    };
    var vtable = io.vtable.*;
    vtable.dirAccess = Probe.access;
    const refused_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]std.Io.Dir.AccessError{ error.AccessDenied, error.InputOutput, error.Canceled }) |err| {
        Probe.refusal = err;
        try std.testing.expectError(err, bitmap_store.Store.open(gpa, refused_io, objects, .sha1));
    }
}

const describe_mod = @import("../revwalk/describe.zig");

/// A multi-pack index's bytes with its trailing checksum taken again.
fn resealMidx(bytes: []u8) void {
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(bytes[0 .. bytes.len - 20]);
    @memcpy(bytes[bytes.len - 20 ..], hasher.final().raw());
}

/// The PNAM chunk of a multi-pack index: where its names begin.
fn packNamesAt(bytes: []const u8) usize {
    var i: usize = 0;
    while (true) : (i += 1) {
        const row = bytes[12 + i * 12 ..][0..12];
        if (std.mem.eql(u8, row[0..4], "PNAM")) return @intCast(std.mem.readInt(u64, row[4..12], .big));
    }
}

test "a MIDX naming a path outside its pack directory is no index, and expire removes nothing by it" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    // Two packs and a third holding everything: the first two are left
    // with nothing assigned, which is what expire removes.
    for (0..8) |n| {
        try linearCommit(&repo, n);
        if (n % 4 == 3) try repo.exec(io, &.{ "repack", "-q", "-d" });
    }
    try repo.exec(io, &.{ "repack", "-q", "-a" });
    try repo.exec(io, &.{ "multi-pack-index", "write" });
    const midx_path = ".git/objects/pack/multi-pack-index";
    const bytes = try repo.readFile(io, midx_path);
    defer gpa.free(bytes);
    var index = try midx.Index.parse(gpa, .sha1, try gpa.dupe(u8, bytes));
    defer index.deinit();
    const counts = try gpa.alloc(u32, index.pack_count);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (0..index.count) |i| counts[(try index.locate(@intCast(i))).pack] += 1;
    const empty = std.mem.findScalar(u32, counts, 0).?;

    // That pack's name, of the same length, made a path two levels up.
    var at = packNamesAt(bytes);
    for (0..empty) |_| at = std.mem.findScalarPos(u8, bytes, at, 0).? + 1;
    const len = std.mem.findScalarPos(u8, bytes, at, 0).? - at;
    const name = "../../" ++ @as([39]u8, @splat('v')) ++ ".idx";
    try std.testing.expectEqual(name.len, len);
    @memcpy(bytes[at..][0..len], name);
    resealMidx(bytes);
    try repo.dir.deleteFile(io, midx_path);
    try repo.writeFile(io, midx_path, bytes);
    for ([_][]const u8{ ".pack", ".idx", ".rev", ".bitmap" }) |extension| {
        const victim = try gpa.print(".git/{s}{s}", .{ &@as([39]u8, @splat('v')), extension });
        defer gpa.free(victim);
        try repo.writeFile(io, victim, "keep me");
    }

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), db.multiPackIndexCount());
    try std.testing.expectEqual(@as(u32, 0), try ops.expireMidx(gpa, io, &db, .none));
    for ([_][]const u8{ ".pack", ".idx", ".rev", ".bitmap" }) |extension| {
        const victim = try gpa.print(".git/{s}{s}", .{ &@as([39]u8, @splat('v')), extension });
        defer gpa.free(victim);
        const kept = try repo.readFile(io, victim);
        defer gpa.free(kept);
        try std.testing.expectEqualStrings("keep me", kept);
    }
}

test "a version 1 MIDX with its pack names out of order is refused as git refuses it, and a version 2 one is read" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..8) |n| {
        try linearCommit(&repo, n);
        if (n % 4 == 3) try repo.exec(io, &.{ "repack", "-q", "-d" });
    }
    const midx_path = ".git/objects/pack/multi-pack-index";
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    if (try testgit.gitAtLeast(gpa, io, 2, 54)) {
        try repo.exec(io, &.{ "-c", "midx.version=2", "multi-pack-index", "write" });
        const written = try repo.readFile(io, midx_path);
        defer gpa.free(written);
        try std.testing.expectEqual(@as(u8, 2), written[4]);
        var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        try std.testing.expectEqual(@as(usize, 1), db.multiPackIndexCount());
        try repo.dir.deleteFile(io, midx_path);
    }

    try repo.exec(io, &.{ "multi-pack-index", "write" });
    const bytes = try repo.readFile(io, midx_path);
    defer gpa.free(bytes);
    // The first two names, which are of one length, swapped.
    const first = packNamesAt(bytes);
    const len = std.mem.findScalarPos(u8, bytes, first, 0).? - first;
    var swap: [64]u8 = undefined;
    @memcpy(swap[0..len], bytes[first..][0..len]);
    @memcpy(bytes[first..][0..len], bytes[first + len + 1 ..][0..len]);
    @memcpy(bytes[first + len + 1 ..][0..len], swap[0..len]);
    resealMidx(bytes);
    try repo.dir.deleteFile(io, midx_path);
    try repo.writeFile(io, midx_path, bytes);
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.run(io, &.{ "multi-pack-index", "verify" }));
    var db = try odb.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), db.multiPackIndexCount());
}

test "a repository with replace refs is repacked with a commit graph of the parents its commits carry, as git writes one" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..3) |n| try linearCommit(&repo, n);
    try repo.exec(io, &.{ "replace", "HEAD~1", "HEAD~2" });
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    _ = try ops.repackRepository(gpa, io, &native, .{ .pack = .{ .threads = 1 }, .remove_packs = true });
    try repo.exec(io, &.{ "commit-graph", "verify" });
    // git writes these generation bytes from 2.43 on.
    if (!try testgit.gitAtLeast(gpa, io, 2, 43)) return;
    const ours = try repo.readFile(io, ".git/objects/info/commit-graph");
    defer gpa.free(ours);
    try repo.dir.deleteFile(io, ".git/objects/info/commit-graph");
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });
    try sameFile(&repo, ".git/objects/info/commit-graph", ours);
}

test "a commit graph or MIDX that does not read is replaced by the writers, and describe --contains reads past it" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..6) |n| {
        try linearCommit(&repo, n);
        if (n % 3 == 2) try repo.exec(io, &.{ "repack", "-q", "-d" });
    }
    try repo.exec(io, &.{ "tag", "v1", "HEAD~3" });
    // git dies on the damaged files below, so its answer is taken first.
    const expected = try repo.run(io, &.{ "describe", "--contains", "HEAD~4" });
    defer gpa.free(expected);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });
    try repo.exec(io, &.{ "multi-pack-index", "write" });
    for ([_][]const u8{ ".git/objects/info/commit-graph", ".git/objects/pack/multi-pack-index" }) |path| {
        const bytes = try repo.readFile(io, path);
        defer gpa.free(bytes);
        // The version byte, which no release reads.
        bytes[4] = 0x7f;
        try repo.dir.deleteFile(io, path);
        try repo.writeFile(io, path, bytes);
    }

    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    const named = try describe_mod.describe(gpa, io, &native, "HEAD~4", .{ .contains = true });
    defer gpa.free(named);
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, expected, "\n"), named);
    _ = try ops.writeConfiguredCommitGraph(gpa, io, &native, .gc);
    _ = try ops.writeMidx(gpa, io, native.objectDatabase(), .{});
    try repo.exec(io, &.{ "commit-graph", "verify" });
    try repo.exec(io, &.{ "multi-pack-index", "verify" });
}
