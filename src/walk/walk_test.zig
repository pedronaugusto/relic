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
const rev_walk = @import("walk.zig");
const commit_graph = @import("../odb/commit_graph.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const cancel = @import("../testing/cancel.zig");
const object_walk = @import("object/walk.zig");

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
    var graph = (try commit_graph.Graph.open(gpa, io, objects, .sha1)) orelse return error.SkipZigTest;
    defer graph.deinit();

    repo.report_failures = false;
    var a_hex: [hash.max_hex_len]u8 = undefined;
    var d_hex: [hash.max_hex_len]u8 = undefined;
    for (oids) |a| for (oids) |d| {
        const theirs = if (repo.run(io, &.{ "merge-base", "--is-ancestor", a.hex(&a_hex), d.hex(&d_hex) })) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |_| false;
        try testing.expectEqual(theirs, try rev_walk.isAncestor(gpa, io, &db, .{ .ancestor = a, .descendant = d }, .{}));
        try testing.expectEqual(theirs, try rev_walk.isAncestor(gpa, io, &db, .{ .ancestor = a, .descendant = d }, .{ .graph = &graph }));
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
        var walk: rev_walk.Walk = .init(gpa, &db);
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

    var walk: rev_walk.Walk = .init(gpa, &db);
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

test "an ancestry-path walk lists what git rev-list --ancestry-path lists, for every pair" {
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
    var path_hex: [hash.max_hex_len]u8 = undefined;
    // `--ancestry-path` alone, the hidden commit the bottom; then
    // `--ancestry-path=<commit>` under the root hidden.
    for ([_]bool{ false, true }) |explicit| for (oids, 1..) |tip, tip_mark| for (oids, 1..) |other, other_mark| {
        const hidden = if (explicit) oids[0] else other;
        const flag = if (explicit) try gpa.print("--ancestry-path={s}", .{other.hex(&path_hex)}) else try gpa.dupe(u8, "--ancestry-path");
        defer gpa.free(flag);
        const theirs = try repo.run(io, &.{ "rev-list", "--topo-order", flag, tip.hex(&tip_hex), "--not", hidden.hex(&hidden_hex) });
        defer gpa.free(theirs);
        var walk: rev_walk.Walk = .init(gpa, &db);
        defer walk.deinit();
        walk.sort = .topological;
        walk.ancestry_path = &.{other};
        try walk.push(tip);
        try walk.hide(hidden);
        var walked: std.ArrayList(u8) = .empty;
        defer walked.deinit(gpa);
        while (try walk.next(io)) |commit| {
            var hex: [hash.max_hex_len]u8 = undefined;
            try walked.print(gpa, "{s}\n", .{commit.oid.hex(&hex)});
        }
        testing.expectEqualStrings(theirs, walked.items) catch |err| {
            std.debug.print("explicit {} tip :{d} other :{d}\n", .{ explicit, tip_mark, other_mark });
            return err;
        };
    };
}

/// Two lines of `length` commits each from one root, `main` and `side`,
/// made by `git fast-import`: marks `:1` the root, then main's, then
/// side's; then `late` on main's tip, dated before the root, as a
/// skewed clock leaves one.
fn twoLines(gpa: std.mem.Allocator, io: Io, length: u32) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, "commit refs/heads/main\nmark :1\ncommitter C <c@example.com> 1000 +0000\ndata 1\n1\n\n");
    for ([_][]const u8{ "main", "side" }, 0..) |branch, line| {
        for (0..length) |i| {
            const mark = 2 + line * length + i;
            const from = if (i == 0) 1 else mark - 1;
            try stream.print(gpa, "commit refs/heads/{s}\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 1\n{d}\nfrom :{d}\nM 100644 inline {s}\ndata 5\n{d:0>4}\n\n", .{ branch, mark, 1000 + mark, mark % 10, from, branch, mark });
        }
    }
    try stream.print(gpa, "commit refs/heads/late\nmark :{d}\ncommitter C <c@example.com> 500 +0000\ndata 4\nlate\nfrom :{d}\n\n", .{ 2 + 2 * length, 1 + length });
    try stream.appendSlice(gpa, "done\n");
    const out = try testremote.gitInput(gpa, io, repo.dir, &.{ "fast-import", "--quiet", "--done", "--export-marks=marks" }, stream.items);
    gpa.free(out);
    return repo;
}

const CancelFixture = struct {
    repo: *testgit.Repo,
    root: Oid,
    main: Oid,
    side: Oid,
    /// Dated before the root, on `main`'s tip.
    late: Oid,
    length: u32,

    /// Every commit `tip` reaches past `hidden`, in `sort`'s order: how many.
    fn walkAll(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, tip: Oid, hidden: ?Oid, sort: rev_walk.Sort) rev_walk.Walk.Error!usize {
        var walk: rev_walk.Walk = .init(gpa, db);
        defer walk.deinit();
        walk.sort = sort;
        try walk.push(tip);
        if (hidden) |h| try walk.hide(h);
        var n: usize = 0;
        while (try walk.next(io)) |_| n += 1;
        return n;
    }

    /// `rev-list --ancestry-path <bottom>..<tip>`: how many.
    fn ancestry(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, tip: Oid, bottom: Oid) rev_walk.Walk.Error!usize {
        var walk: rev_walk.Walk = .init(gpa, db);
        defer walk.deinit();
        walk.ancestry_path = &.{bottom};
        try walk.push(tip);
        try walk.hide(bottom);
        var n: usize = 0;
        while (try walk.next(io)) |_| n += 1;
        return n;
    }

    fn bases(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, a: Oid, b: Oid) rev_walk.Error!usize {
        const found = try rev_walk.mergeBasesMany(gpa, io, db, .{ .one = a, .others = &.{b} }, .{});
        defer gpa.free(found);
        return found.len;
    }

    fn reach(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, from: Oid, to: Oid) rev_walk.Error!bool {
        const out = try rev_walk.reachableSubset(gpa, io, db, .{ .from = &.{from}, .to = &.{to} }, .{});
        defer gpa.free(out);
        return out[0];
    }

    /// Every object `tip` reaches, walked, as `filter` leaves them: how many.
    fn objects(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, tip: Oid, filter: object_walk.Filter) object_walk.Error!usize {
        var collected = try object_walk.missing(gpa, io, db, &.{tip}, .{ .use_bitmaps = false, .filter = filter });
        defer collected.deinit();
        return collected.entries.len;
    }

    /// What `tip` reaches that `had` does not, walked: how many.
    fn objectsPast(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, tip: Oid, had: Oid) object_walk.Error!usize {
        var collected = try object_walk.missing(gpa, io, db, &.{tip}, .{ .use_bitmaps = false, .exclude = &.{had} });
        defer collected.deinit();
        return collected.entries.len;
    }

    fn connected(io: Io, gpa: std.mem.Allocator, db: *odb_mod.Odb, tip: Oid) object_walk.Error!void {
        return object_walk.checkConnected(gpa, io, db, &.{tip}, .{});
    }

    fn run(f: *const CancelFixture, io: Io) !void {
        const gpa = testing.allocator;
        const git_dir = try f.repo.gitDir(io);
        defer git_dir.close(io);
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        const all = 1 + 2 * f.length;
        var counter: cancel.Counter = undefined;

        // Uncanceled, the answers are the same with the points counted,
        // and there is a point for each commit popped, each handed out by
        // `next`, and each the topological sorts take.
        for ([_]rev_walk.Sort{ .date, .topological, .date_order }) |sort| {
            try testing.expectEqual(@as(usize, f.length + 1), try walkAll(io, gpa, &db, f.main, null, sort));
            counter = cancel.counted(io);
            try testing.expectEqual(@as(usize, f.length + 1), try walkAll(counter.io(), gpa, &db, f.main, null, sort));
            try testing.expect(cancel.points(&counter) >= @as(u64, if (sort == .date) 2 else 3) * (f.length + 1));
        }
        counter = cancel.counted(io);
        try testing.expectEqual(@as(usize, f.length), try walkAll(counter.io(), gpa, &db, f.main, f.side, .date));
        try testing.expect(cancel.points(&counter) >= f.length);
        // Limited to the ancestry path: two passes over the list as well.
        counter = cancel.counted(io);
        try testing.expectEqual(@as(usize, f.length), try ancestry(counter.io(), gpa, &db, f.main, f.root));
        try testing.expect(cancel.points(&counter) >= 4 * f.length);
        counter = cancel.counted(io);
        try testing.expectEqual(@as(usize, 1), try bases(counter.io(), gpa, &db, f.main, f.side));
        try testing.expect(cancel.points(&counter) >= all);
        counter = cancel.counted(io);
        try testing.expect(!try reach(counter.io(), gpa, &db, f.main, f.side));
        try testing.expect(cancel.points(&counter) >= f.length + 1);
        // The object walk: a point for each commit taken and each tree
        // listed, filtered or not, and for each object checked present.
        const commits = f.length + 1;
        counter = cancel.counted(io);
        try testing.expectEqual(try objects(io, gpa, &db, f.main, .none), try objects(counter.io(), gpa, &db, f.main, .none));
        try testing.expect(cancel.points(&counter) >= 2 * commits);
        counter = cancel.counted(io);
        try testing.expectEqual(try objects(io, gpa, &db, f.main, .blob_none), try objects(counter.io(), gpa, &db, f.main, .blob_none));
        try testing.expect(cancel.points(&counter) >= 2 * commits);
        // `late`, taken last for its date, reaches every commit taken as
        // wanted: a point for each marked had after all, and for each of
        // their trees.
        try testing.expectEqual(@as(usize, 0), try objectsPast(io, gpa, &db, f.main, f.late));
        counter = cancel.counted(io);
        try testing.expectEqual(@as(usize, 0), try objectsPast(counter.io(), gpa, &db, f.main, f.late));
        try testing.expect(cancel.points(&counter) >= 3 * commits);
        counter = cancel.counted(io);
        try connected(counter.io(), gpa, &db, f.main);
        try testing.expect(cancel.points(&counter) >= 3 * f.length);

        // Canceled in the middle, each hands `error.Canceled` back from
        // the point it stopped at and asks no other on its way out.
        const middle = f.length / 2;
        for ([_]rev_walk.Sort{ .date, .topological, .date_order }) |sort| {
            try cancel.expectCanceled(io, middle, 0, walkAll, .{ gpa, &db, f.main, null, sort });
            // Past the popping, in the sorting and in `next`.
            try cancel.expectCanceled(io, f.length + middle, 0, walkAll, .{ gpa, &db, f.main, null, sort });
        }
        try cancel.expectCanceled(io, middle, 0, walkAll, .{ gpa, &db, f.main, f.side, .date });
        try cancel.expectCanceled(io, 2 * f.length, 0, ancestry, .{ gpa, &db, f.main, f.root });
        try cancel.expectCanceled(io, f.length, 0, bases, .{ gpa, &db, f.main, f.side });
        try cancel.expectCanceled(io, middle, 0, reach, .{ gpa, &db, f.main, f.side });
        // Taking commits, then listing trees, plain and filtered.
        for ([_]object_walk.Filter{ .none, .blob_none }) |filter| {
            try cancel.expectCanceled(io, middle, 0, objects, .{ gpa, &db, f.main, filter });
            try cancel.expectCanceled(io, commits + middle, 0, objects, .{ gpa, &db, f.main, filter });
        }
        // Taking commits, marking them had, then their trees.
        for ([_]u64{ middle, commits + middle, 2 * commits + middle }) |at| {
            try cancel.expectCanceled(io, at, 0, objectsPast, .{ gpa, &db, f.main, f.late });
        }
        try cancel.expectCanceled(io, commits, 0, connected, .{ gpa, &db, f.main });
    }
};

test "a walk, a merge-base paint, a reachability walk and an object walk canceled as tasks return error.Canceled from the step they stop at, on each backend (design §11)" {
    const gpa = testing.allocator;
    const io = testing.io;
    const length = 300;
    var repo = try twoLines(gpa, io, length);
    defer repo.deinit();
    const oids = try marks(gpa, io, &repo);
    defer gpa.free(oids);
    const fixture: CancelFixture = .{ .repo = &repo, .root = oids[0], .main = oids[length], .side = oids[2 * length], .late = oids[2 * length + 1], .length = length };
    try cancel.eachBackend(&fixture, CancelFixture.run);
}
