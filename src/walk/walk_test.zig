//! History walks held to git's: `git merge-base --is-ancestor` for every
//! pair of commits, and `git rev-list <tip> --not <hidden>` for every pair,
//! over a history with branches, merges, commits made in the same second
//! and a clock that ran backwards — with and without a commit-graph.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const object = @import("../object/object.zig");
const revwalk = @import("walk.zig");
const commitgraph = @import("../odb/commitgraph.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");

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
        const space = std.mem.findScalar(u8, line, ' ').?;
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
        try testing.expectEqual(theirs, try revwalk.isAncestor(gpa, io, &db, .{ .ancestor = a, .descendant = d }, .{}));
        try testing.expectEqual(theirs, try revwalk.isAncestor(gpa, io, &db, .{ .ancestor = a, .descendant = d }, .{ .graph = &graph }));
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

test "a commit's tree and parents are read where git reads them, whatever headers follow" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "f", "one\n");
    try repo.exec(io, &.{ "add", "f" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const parent = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(parent);
    const tree = try repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree);
    try repo.writeFile(io, "empty", "");
    const empty_tree = try repo.line(io, &.{ "hash-object", "-t", "tree", "-w", "empty" });
    defer gpa.free(empty_tree);
    // A second tree and a parent after the identities, which git's fsck
    // lets through and git's parser does not read.
    const text = try gpa.print("tree {s}\nauthor A <a@b> 1 +0000\ncommitter A <a@b> 1 +0000\ntree {s}\nparent {s}\n\nodd\n", .{ tree, empty_tree, parent });
    defer gpa.free(text);
    try repo.writeFile(io, "odd", text);
    const odd = try repo.line(io, &.{ "hash-object", "-t", "commit", "-w", "--literally", "odd" });
    defer gpa.free(odd);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const tree_of = try gpa.print("{s}^{{tree}}", .{odd});
    defer gpa.free(tree_of);
    const theirs_tree = try repo.line(io, &.{ "rev-parse", "--verify", tree_of });
    defer gpa.free(theirs_tree);
    const found = try db.read(io, try Oid.parse(.sha1, odd));
    defer gpa.free(found.bytes);
    var parsed = try object.Commit.parse(gpa, .sha1, found.bytes);
    defer parsed.deinit();
    var tree_hex: [hash.max_hex_len]u8 = undefined;
    try testing.expectEqualStrings(theirs_tree, parsed.tree.hex(&tree_hex));
    const theirs_list = try repo.run(io, &.{ "rev-list", odd });
    defer gpa.free(theirs_list);

    var walk: revwalk.Walk = .init(gpa, &db);
    defer walk.deinit();
    try walk.push(try Oid.parse(.sha1, odd));
    var listed: std.ArrayList(u8) = .empty;
    defer listed.deinit(gpa);
    while (try walk.next(io)) |commit| {
        var hex: [hash.max_hex_len]u8 = undefined;
        try listed.print(gpa, "{s}\n", .{commit.oid.hex(&hex)});
    }
    try testing.expectEqualStrings(theirs_list, listed.items);
}
