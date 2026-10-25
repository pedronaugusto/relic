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
const walk_mod = @import("../walk/walk.zig");
const Walk = walk_mod.Walk;
const rev_parse = @import("../repo/rev_parse.zig");
const grep = @import("../grep.zig");

const commit_mod = @import("../commit/commit.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const repack = @import("../maintenance/repack.zig");
const gc = @import("../maintenance/gc.zig");
const prune = @import("../maintenance/prune.zig");
const date = @import("../text.zig").date;

const Op = enum {
    open,
    status,
    describe,
    log,
    rev_parse,
    merge_base,
    grep,
    add,
    commit,
    checkout,
    repack,
    repack_cruft,
    pack_refs,
    reflog_expire,
    prune,

    /// Whether the operation writes, and so runs on a copy of its own.
    fn writes(op: Op) bool {
        return switch (op) {
            .add, .commit, .checkout, .repack, .repack_cruft, .pack_refs, .reflog_expire, .prune => true,
            else => false,
        };
    }
};

const who: object.Signature = .{ .name = "Sweep", .email = "sweep@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

/// Every file of the copy at one time, the index after it, so its stat, the
/// racy checks and the configuration's freshness answer the same in every
/// run, whenever in the second it is made.
fn settle(io: Io, git: *testgit.Repo) !void {
    const at: Io.Timestamp = .{ .nanoseconds = @as(i96, testgit.fixture_date) * std.time.ns_per_s };
    var walker = try git.dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try fs.setTimestamps(io, git.dir, entry.path, .{ .modify_timestamp = .{ .new = at } });
    }
    try fs.setTimestamps(io, git.dir, ".git/index", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = at.nanoseconds + 10 * std.time.ns_per_s } } });
}

/// Two commits of three files, a tag on the first, a changed file and a new
/// one in the working tree, stored but named by nothing (what prune and a
/// cruft repack take).
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
    try git.exec(io, &.{ "hash-object", "-w", "new" });
    return git;
}

const Sweep = struct {
    git: *testgit.Repo,
    op: Op,
    /// A writing operation's own copy of the fixture, made for each run.
    copy: ?testgit.Repo = null,
    fio: ?*shakedown.FaultIo = null,
    /// Runs whose cancel landed and that ended without `error.Canceled`.
    lost: u32 = 0,

    pub fn setUp(s: *Sweep, fio: *shakedown.FaultIo) !void {
        s.fio = fio;
        if (!s.op.writes()) return;
        s.copy = try testgit.Repo.copyOf(testing.allocator, testing.io, s.git);
        try settle(testing.io, &s.copy.?);
    }
    pub fn tearDown(s: *Sweep) void {
        if (s.copy) |*c| c.deinit();
        s.copy = null;
    }

    pub fn run(s: *Sweep, io: Io) !void {
        const gpa = testing.allocator;
        // The probe measures the real disk's clock, which no two runs share.
        const dir = if (s.copy) |c| c.dir else s.git.dir;
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
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
            .rev_parse => _ = try rev_parse.resolve(gpa, io, repo.revisionSource(), "v1^{tree}:d/b"),
            .merge_base => {
                const one = try rev_parse.resolve(gpa, io, repo.revisionSource(), "v1^{commit}");
                const two = try rev_parse.resolve(gpa, io, repo.revisionSource(), "HEAD");
                gpa.free(try walk_mod.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = one, .b = two }, .{}));
            },
            .grep => {
                var out: Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                _ = try grep.grep(gpa, io, &out.writer, &repo, .{ .patterns = &.{"e"}, .threads = 1 });
            },
            .add, .commit => {
                var locked = try repo.lockIndex(io);
                defer locked.deinit(io);
                _ = try worktree.addAll(gpa, io, dir, .{ .index = &locked.index, .db = repo.objectDatabase() }, .{ .rules = try repo.worktreeRules() });
                try locked.commit(io);
                if (s.op == .commit) _ = try commit_mod.commit(io, &repo, .{ .author = who, .committer = who, .message = "swept\n" }, .{ .verify = false });
            },
            .checkout => {
                var locked = try repo.lockIndex(io);
                defer locked.deinit(io);
                const tree = try rev_parse.resolve(gpa, io, repo.revisionSource(), "v1^{tree}");
                _ = try worktree.checkout(gpa, io, dir, .{ .index = &locked.index, .db = repo.objectDatabase(), .tree = tree }, .{ .force = true, .rules = try repo.worktreeRules() });
                try locked.commit(io);
            },
            .repack => _ = try repack.repack(gpa, io, &repo, .{ .mode = .all, .delete = true, .update_server_info = false, .pack = .{ .threads = 1 } }),
            .repack_cruft => _ = try repack.repack(gpa, io, &repo, .{ .mode = .cruft, .delete = true, .update_server_info = false, .pack = .{ .threads = 1 } }),
            .pack_refs => try gc.packRefs(io, &repo, .{ .include = &.{"*"} }),
            .reflog_expire => try gc.expireReflogs(gpa, io, &repo, .{ .clock = .{ .now = date.timestamp(testgit.fixture_date) }, .expire = date.expire_all }),
            .prune => _ = try prune.prune(gpa, io, &repo, .{}),
        }
    }

    /// A lost cancel is counted and its call printed with the three before
    /// and after it, which name the fallback that took it in; the sweep goes
    /// on.
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
            for (records[i -| 3..@min(records.len, i + 4)]) |next| std.debug.print(" | {f}", .{next.event});
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
        if (report.failure) |f| std.debug.print("{t}: {t} at {any}, first difference at record {any}\n{s}\n", .{ op, f.err, f.injected, f.difference, f.trace });
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

test "every cancellation point of rev-parse returns error.Canceled (design §11)" {
    try sweep(.rev_parse);
}

test "every cancellation point of a merge base returns error.Canceled (design §11)" {
    try sweep(.merge_base);
}

test "every cancellation point of grep returns error.Canceled (design §11)" {
    try sweep(.grep);
}

test "every cancellation point of add returns error.Canceled (design §11)" {
    try sweep(.add);
}

test "every cancellation point of a commit returns error.Canceled (design §11)" {
    try sweep(.commit);
}

test "every cancellation point of a checkout returns error.Canceled (design §11)" {
    try sweep(.checkout);
}

test "every cancellation point of a repack -a -d returns error.Canceled (design §11)" {
    try sweep(.repack);
}

test "every cancellation point of a repack --cruft -d returns error.Canceled (design §11)" {
    try sweep(.repack_cruft);
}

test "every cancellation point of pack-refs returns error.Canceled (design §11)" {
    try sweep(.pack_refs);
}

test "every cancellation point of reflog expire returns error.Canceled (design §11)" {
    try sweep(.reflog_expire);
}

test "every cancellation point of prune returns error.Canceled (design §11)" {
    try sweep(.prune);
}
