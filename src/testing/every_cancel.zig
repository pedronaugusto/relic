//! A cancel at every cancellation point of an operation (design §11), by
//! shakedown's `everyFault`: a run whose cancel landed returns
//! `error.Canceled`. Zig hands a cancel to the next point only, so a point
//! whose error a fallback takes in (`catch null`, `else => continue`) loses
//! it, and the operation runs on to its end as if never canceled.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown");

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("../checkout/checkout.zig");
const describe = @import("../rev_walk/describe.zig");
const Walk = @import("../walk/walk.zig").Walk;

const Op = enum { open, status, describe, log };

/// Two commits of three files, a tag on the first, a changed file and a new
/// one in the working tree.
fn fixture(gpa: std.mem.Allocator, io: Io) !testgit.Repo {
    var git = try testgit.Repo.init(gpa, io, &.{});
    errdefer git.deinit();
    try git.writeFile(io, "a", "one\n");
    try git.writeFile(io, "d/b", "bee\n");
    try git.writeFile(io, "d/c", "sea\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "tag", "-a", "-m", "v1", "v1" });
    try git.writeFile(io, "a", "two\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    try git.writeFile(io, "d/b", "bees\n");
    try git.writeFile(io, "new", "new\n");
    return git;
}

const Sweep = struct {
    git: *testgit.Repo,
    op: Op,
    fio: ?*shakedown.FaultIo = null,
    /// Runs whose cancel landed and that ended without `error.Canceled`.
    lost: u32 = 0,

    pub fn setUp(s: *Sweep, fio: *shakedown.FaultIo) !void {
        s.fio = fio;
    }
    pub fn tearDown(_: *Sweep) void {}

    pub fn run(s: *Sweep, io: Io) !void {
        const gpa = testing.allocator;
        // The probe measures the real disk's clock, which no two runs share.
        var repo = try repo_mod.Repository.open(gpa, io, s.git.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
        defer repo.deinit(io);
        switch (s.op) {
            .open => {},
            .status => {
                var index = try repo.openIndex(io);
                defer index.deinit();
                var status = try worktree.status(gpa, io, s.git.dir, .{ .index = &index, .db = repo.objectDatabase() }, .{
                    .rules = try repo.worktreeRules(),
                    .head_tree = try repo.headTree(io),
                });
                status.deinit();
            },
            .describe => gpa.free(try describe.describe(gpa, io, &repo, "HEAD", .{})),
            .log => {
                var walk: Walk = .init(gpa, repo.objectDatabase());
                defer walk.deinit();
                const head = (try repo.head(io)).?;
                defer gpa.free(head.name);
                try walk.push(head.oid);
                while (try walk.next(io)) |_| {}
            },
        }
    }

    /// A lost cancel is counted and its call printed with the three after
    /// it, which name the fallback that took it in; the sweep goes on.
    pub fn check(s: *Sweep, _: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        const fault = injected orelse return result;
        if (fault.fault != .cancel) return;
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return;
            return err;
        }
        s.lost += 1;
        const records = s.fio.?.trace().records();
        for (records, 0..) |r, i| if (r.step == fault.step) {
            std.debug.print("{t}: cancel lost at step {d}:", .{ s.op, r.step });
            for (records[i..@min(records.len, i + 4)]) |next| std.debug.print(" | {f}", .{next.event});
            std.debug.print("\n", .{});
            break;
        };
    }
};

fn sweep(op: Op) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try fixture(gpa, io);
    defer git.deinit();
    var s: Sweep = .{ .git = &git, .op = op };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const done = shakedown.everyFault(gpa, io, &s, .{
        .errors = &.{},
        .short = false,
        .alloc = false,
        .cancel = true,
        .trace = .all,
        .diagnostics = &report,
    }) catch |err| {
        if (report.failure) |f| std.debug.print("{t}: {t} at {any}\n{s}\n", .{ op, f.err, f.injected, f.trace });
        return err;
    };
    std.debug.print("{t}: {d} steps, {d} runs, {d} cancels lost\n", .{ op, done.steps, done.runs, s.lost });
    try testing.expectEqual(0, s.lost);
}

test "every cancellation point of opening a repository returns error.Canceled (design §11)" {
    try sweep(.open);
}

test "every cancellation point of status returns error.Canceled (design §11)" {
    try sweep(.status);
}

test "every cancellation point of describe returns error.Canceled (design §11)" {
    try sweep(.describe);
}

test "every cancellation point of a revision walk returns error.Canceled (design §11)" {
    try sweep(.log);
}
