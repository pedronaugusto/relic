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
fn linearCommit(repo: *testgit.Repo, n: usize) !void {
    var text: [64]u8 = undefined;
    try repo.writeFile(io, "file", try std.fmt.bufPrint(&text, "contents {d}\n", .{n}));
    try repo.exec(io, &.{ "add", "file" });
    try testgit.setDate(&repo.isolated.?, 1_700_000_000 + @as(i64, @intCast(n)));
    try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&text, "commit {d}", .{n}) });
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
