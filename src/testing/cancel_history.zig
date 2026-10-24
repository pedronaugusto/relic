//! The history tools with walks of their own, canceled as tasks (design
//! §11): describe's search and its depth count, `--contains`'s naming,
//! last-modified, the path walk and bisect's distances and weights, each
//! returning `error.Canceled` from the commit it stops at.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const cancel = @import("cancel.zig");
const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const describe = @import("../rev_walk/describe.zig");
const last_modified = @import("../rev_walk/last_modified.zig");
const path_walk = @import("../rev_walk/path_walk.zig");
const bisect = @import("../rev_walk/bisect.zig");

const Oid = hash.Oid;

const length = 300;
const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

/// One line of `length` commits on `main` past a root, which alone writes
/// `still` and `length` files under `files/`; each writes `moving`. A line
/// of `length` on `side` from the root, merged at the tip of `main`. An
/// annotated tag `v0` on the root, `v1` on the merge, `vs` on `side`'s
/// tip, and `HEAD` checked out at the merge.
fn line(gpa: std.mem.Allocator, io: Io) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, "commit refs/heads/main\nmark :1\ncommitter C <c@example.com> 1000 +0000\ndata 1\n1\nM 100644 inline still\ndata 6\nstill\n");
    for (0..length) |i| try stream.print(gpa, "M 100644 inline files/{d:0>4}/f\ndata 5\n{d:0>4}\n", .{ i, i });
    try stream.appendSlice(gpa, "\n");
    // `main` is marks 2 to length + 1, `side` the next `length`.
    for ([_][]const u8{ "main", "side" }, [_][]const u8{ "moving", "aside" }, 0..) |branch, path, line_index| {
        for (0..length) |i| {
            const mark = 2 + line_index * length + i;
            const from = if (i == 0) 1 else mark - 1;
            try stream.print(gpa, "commit refs/heads/{s}\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 1\n{d}\nfrom :{d}\nM 100644 inline {s}\ndata 5\n{d:0>4}\n\n", .{ branch, mark, 1000 + mark, mark % 10, from, path, mark });
        }
    }
    const merge = 2 + 2 * length;
    try stream.print(gpa, "commit refs/heads/main\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 1\nm\nfrom :{d}\nmerge :{d}\n\n", .{ merge, 1000 + merge, length + 1, merge - 1 });
    for ([_][]const u8{ "v0", "v1", "vs" }, [_]usize{ 1, merge, merge - 1 }) |name, mark| {
        try stream.print(gpa, "tag {s}\nfrom :{d}\ntagger C <c@example.com> {d} +0000\ndata 2\n{s}\n", .{ name, mark, 1000 + mark, name });
    }
    try stream.appendSlice(gpa, "done\n");
    const out = try testremote.gitInput(gpa, io, repo.dir, &.{ "fast-import", "--quiet", "--done" }, stream.items);
    gpa.free(out);
    try repo.exec(io, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    try repo.exec(io, &.{ "reset", "-q", "--hard" });
    return repo;
}

const Run = struct {
    repo: *testgit.Repo,
    root: []const u8,
    tip: Oid,

    fn open(io: Io, r: *const Run) !repo_mod.Repository {
        return repo_mod.Repository.open(testing.allocator, io, r.repo.dir, .{});
    }

    /// `git describe <rev>`, with `options`: its length.
    fn described(io: Io, r: *const Run, rev: []const u8, options: describe.Options) !usize {
        var repo = try open(io, r);
        defer repo.deinit(io);
        const text = try describe.describe(testing.allocator, io, &repo, rev, options);
        defer testing.allocator.free(text);
        return text.len;
    }

    /// `git last-modified`: how many paths.
    fn lastModified(io: Io, r: *const Run) !usize {
        var repo = try open(io, r);
        defer repo.deinit(io);
        var result = try last_modified.lastModified(testing.allocator, io, &repo, .{}, .{});
        defer result.deinit();
        return result.entries.len;
    }

    /// The path walk from `main`: how many objects it hands back.
    fn pathWalk(io: Io, r: *const Run, tip: Oid) !usize {
        var repo = try open(io, r);
        defer repo.deinit(io);
        var pw = try path_walk.PathWalk.init(testing.allocator, io, &repo, .{ .include = &.{tip} }, .{});
        defer pw.deinit();
        var n: usize = 0;
        while (try pw.next(io)) |batch| n += batch.oids.len;
        return n;
    }

    /// bisect's next step between `v0` and `main`, which checks it out.
    fn bisected(io: Io, r: *const Run) !void {
        var repo = try open(io, r);
        defer repo.deinit(io);
        var report = try bisect.nextStep(testing.allocator, io, &repo, .{ .who = who });
        report.deinit();
    }

    fn run(r: *const Run, io: Io) !void {
        // describe walks back to `v0`, then on to count the depth; with one
        // candidate it stops at `vs` and counts the rest of both lines;
        // `--contains` names every commit down from `v1`; last-modified
        // goes back to the root for `still`; the path walk takes every
        // commit; bisect counts each candidate's distance and weight.
        // The least each must ask: a point per commit it takes, and the
        // path walk one per path as well.
        const past_vs: describe.Options = .{ .candidates = 1, .exclude = &.{"v1"} };
        const Case = struct { points: u64, least: u64, at: u64 };
        const cases = [_]Case{
            .{ .points = try pointsOf(io, described, .{ r, "main~1", describe.Options{} }), .least = length, .at = length / 2 },
            .{ .points = try pointsOf(io, described, .{ r, r.root, describe.Options{ .contains = true } }), .least = 2 * length, .at = length / 2 },
            .{ .points = try pointsOf(io, lastModified, .{r}), .least = length, .at = length / 2 },
            .{ .points = try pointsOf(io, pathWalk, .{ r, r.tip }), .least = 5 * length, .at = length / 2 },
            .{ .points = try pointsOf(io, described, .{ r, "main", past_vs }), .least = 2 * length, .at = length },
        };
        for (cases) |case| try testing.expect(case.points >= case.least);
        try cancel.expectCanceled(io, cases[0].at, 0, described, .{ r, "main~1", describe.Options{} });
        try cancel.expectCanceled(io, cases[1].at, 0, described, .{ r, r.root, describe.Options{ .contains = true } });
        try cancel.expectCanceled(io, cases[2].at, 0, lastModified, .{r});
        try cancel.expectCanceled(io, cases[3].at, 0, pathWalk, .{ r, r.tip });
        // Past the commits, in the paths.
        try cancel.expectCanceled(io, cases[3].points - length / 2, 0, pathWalk, .{ r, r.tip });
        // Counting the depth.
        try cancel.expectCanceled(io, cases[4].at, 0, described, .{ r, "main", past_vs });

        try r.repo.exec(testing.io, &.{ "bisect", "start", "main", "v0" });
        defer r.repo.exec(testing.io, &.{ "bisect", "reset" }) catch {}; // glint-ignore: Z026 -- the next backend starts its own; a reset that fails leaves a scratch repository's state
        const bisect_points = try pointsOf(io, bisected, .{r});
        // The walk listing the candidates, a point for each commit popped
        // and each handed out; the merge's distance, one for each commit it
        // reaches; then the weights, one for each commit looked at until a
        // line's last, halfway, has its own.
        const candidates = 2 * length + 1;
        try testing.expect(bisect_points >= 3 * candidates + length);
        try r.repo.exec(testing.io, &.{ "checkout", "-q", "main" });
        // In the walk, in the distance, then in the weights.
        for ([_]u64{ bisect_points / 4, bisect_points - length - length / 2, bisect_points - length / 2 }) |at| {
            try cancel.expectCanceled(io, at, 0, bisected, .{r});
        }
    }

    /// The points `function` asks, uncanceled.
    fn pointsOf(io: Io, function: anytype, args: anytype) !u64 {
        var counter = cancel.counted(io);
        _ = try @call(.auto, function, .{counter.io()} ++ args);
        return cancel.points(&counter);
    }
};

test "describe, --contains, last-modified, the path walk and bisect canceled as tasks return error.Canceled from the commit they stop at, on each backend (design §11)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try line(gpa, io);
    defer repo.deinit();
    const root = try repo.line(io, &.{ "rev-parse", "v0^{commit}" });
    defer gpa.free(root);
    const tip_hex = try repo.line(io, &.{ "rev-parse", "main" });
    defer gpa.free(tip_hex);
    const r: Run = .{ .repo = &repo, .root = root, .tip = try Oid.parse(.sha1, tip_hex) };
    try cancel.eachBackend(&r, Run.run);
}
