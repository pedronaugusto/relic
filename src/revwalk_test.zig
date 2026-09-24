//! History walks held to git's: `git merge-base --is-ancestor` for every
//! pair of commits, and `git rev-list <tip> --not <hidden>` for every pair,
//! over a history with branches, merges, commits made in the same second
//! and a clock that ran backwards — with and without a commit-graph.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const revwalk = @import("revwalk.zig");
const commitgraph = @import("commitgraph.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const Oid = hash.Oid;

/// A history made by `git fast-import`, with marks `:1`… and the dates
/// given: two lines that fork and merge twice, a run of commits in one
/// second, and a commit dated before its parent.
fn skewedHistory(gpa: std.mem.Allocator, io: Io) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    const Commit = struct { branch: []const u8, time: i64, from: ?u32 = null, merge: ?u32 = null };
    const commits = [_]Commit{
        .{ .branch = "main", .time = 1000 }, // 1
        .{ .branch = "main", .time = 1100, .from = 1 }, // 2
        .{ .branch = "side", .time = 1100, .from = 1 }, // 3, the same second as 2
        .{ .branch = "side", .time = 1100, .from = 3 }, // 4
        .{ .branch = "main", .time = 1200, .from = 2, .merge = 4 }, // 5
        .{ .branch = "side", .time = 900, .from = 4 }, // 6, before its parent
        .{ .branch = "side", .time = 1300, .from = 6 }, // 7
        .{ .branch = "main", .time = 1250, .from = 5 }, // 8
        .{ .branch = "main", .time = 1400, .from = 8, .merge = 7 }, // 9
        .{ .branch = "topic", .time = 1150, .from = 2 }, // 10
        .{ .branch = "topic", .time = 1500, .from = 10 }, // 11
        .{ .branch = "main", .time = 1450, .from = 9 }, // 12
    };
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (commits, 1..) |c, mark| {
        try stream.print(gpa, "commit refs/heads/{s}\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 2\n{d}\n", .{ c.branch, mark, c.time, mark % 10 });
        if (c.from) |from| try stream.print(gpa, "from :{d}\n", .{from});
        if (c.merge) |merge| try stream.print(gpa, "merge :{d}\n", .{merge});
        try stream.print(gpa, "M 100644 inline f{d}\ndata 2\n{d}\n\n", .{ mark, mark % 10 });
    }
    try stream.appendSlice(gpa, "done\n");
    const out = try testremote.gitInput(gpa, io, repo.dir, &.{ "fast-import", "--quiet", "--done", "--export-marks=marks" }, stream.items);
    gpa.free(out);
    return repo;
}

fn marks(gpa: std.mem.Allocator, io: Io, repo: *testgit.Repo) ![]Oid {
    const text = try repo.readFile(io, "marks");
    defer gpa.free(text);
    var list: std.ArrayList(Oid) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const index = try std.fmt.parseUnsigned(usize, line[1..space], 10);
        if (list.items.len < index) try list.resize(gpa, index);
        list.items[index - 1] = try Oid.parse(.sha1, line[space + 1 ..]);
    }
    return list.toOwnedSlice(gpa);
}

test "ancestry answers what git merge-base --is-ancestor answers, for every pair, with and without a commit-graph" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try skewedHistory(gpa, io);
    defer repo.deinit();
    const oids = try marks(gpa, io, &repo);
    defer gpa.free(oids);
    try repo.exec(io, &.{ "commit-graph", "write", "--reachable" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var graph = (try commitgraph.Graph.open(gpa, io, objects, .sha1)) orelse return error.SkipZigTest;
    defer graph.deinit();

    repo.report_failures = false;
    var a_hex: [hash.max_hex_len]u8 = undefined;
    var d_hex: [hash.max_hex_len]u8 = undefined;
    for (oids) |a| for (oids) |d| {
        const theirs = if (repo.run(io, &.{ "merge-base", "--is-ancestor", a.hex(&a_hex), d.hex(&d_hex) })) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |_| false;
        try testing.expectEqual(theirs, try revwalk.isAncestor(gpa, io, &db, a, d));
        try testing.expectEqual(theirs, try revwalk.isAncestorWith(gpa, io, &db, a, d, .{ .graph = &graph }));
    };
}

test "a walk with hidden commits lists what git rev-list lists, for every pair" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try skewedHistory(gpa, io);
    defer repo.deinit();
    const oids = try marks(gpa, io, &repo);
    defer gpa.free(oids);
    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var tip_hex: [hash.max_hex_len]u8 = undefined;
    var hidden_hex: [hash.max_hex_len]u8 = undefined;
    for (oids) |tip| for (oids) |hidden| {
        const theirs = try repo.run(io, &.{ "rev-list", tip.hex(&tip_hex), "--not", hidden.hex(&hidden_hex) });
        defer gpa.free(theirs);
        var walk: revwalk.Walk = .init(gpa, &db);
        defer walk.deinit();
        try walk.push(tip);
        try walk.hide(hidden);
        // The same commits; the order of two made in one second is
        // git's queue's and not a promise.
        var listed: std.ArrayList([]const u8) = .empty;
        defer listed.deinit(gpa);
        var lines = std.mem.tokenizeScalar(u8, theirs, '\n');
        while (lines.next()) |line| try listed.append(gpa, line);
        var walked: std.ArrayList([hash.max_hex_len]u8) = .empty;
        defer walked.deinit(gpa);
        while (try walk.next(io)) |commit| {
            var hex: [hash.max_hex_len]u8 = undefined;
            _ = commit.oid.hex(&hex);
            try walked.append(gpa, hex);
        }
        try testing.expectEqual(listed.items.len, walked.items.len);
        for (walked.items) |*hex| {
            const text = hex[0..40];
            const found = for (listed.items) |line| {
                if (std.mem.eql(u8, line, text)) break true;
            } else false;
            try testing.expect(found);
        }
    };
}
