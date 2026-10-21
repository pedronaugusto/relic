//! `gc` held to git 2.55's: the same repository collected by each, and
//! what each then holds compared -- the object directory as `repack`'s
//! tests read it, the refs' files, the commit graph, the worktrees and
//! `gc.pid` and `gc.log` -- and `--auto`'s thresholds, the `gc.pid` lock,
//! `gc.log` and the `pre-auto-gc` hook decided as git's.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const shared = @import("repack_test.zig");
const collect = @import("collect.zig");
const repo_mod = @import("../repo/repo.zig");
const fs = @import("../fs/fs.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;
const day = shared.day;

/// The harness's settings but `gc.auto=0` and its empty hooks directory,
/// so the repository's own configuration decides git's gc as it decides
/// relic's.
const gc_settings = blk: {
    var kept: [testgit.default_settings.len][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < testgit.default_settings.len) : (i += 2) {
        const setting = testgit.default_settings[i + 1];
        if (std.mem.eql(u8, setting, "gc.auto=0") or std.mem.startsWith(u8, setting, "core.hooksPath=")) continue;
        kept[n] = "-c";
        kept[n + 1] = setting;
        n += 2;
    }
    const out = kept[0..n].*;
    break :blk out;
};

/// git as the gc tests run it.
fn gitGc(repo: *testgit.Repo, args: []const []const u8) !void {
    repo.defaults = &gc_settings;
    defer repo.defaults = &testgit.default_settings;
    try repo.exec(io, args);
}

fn clock() collect.Options {
    return .{ .clock = .{ .now = Io.Clock.real.now(io) } };
}

/// What `gc` leaves besides objects: the loose refs' files and
/// `packed-refs`, or the number of reftables; whether there is a commit
/// graph; `worktrees/`; `gc.pid` and `gc.log`.
fn housekeeping(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var walker_dir = try repo.dir.openDir(io, ".git/refs", .{ .iterate = true });
    defer walker_dir.close(io);
    var walker = try walker_dir.walk(gpa);
    defer walker.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |r| gpa.free(r);
        refs.deinit(gpa);
    }
    while (try walker.next(io)) |entry| if (entry.kind == .file) try refs.append(gpa, try gpa.dupe(u8, entry.path));
    std.mem.sort([]const u8, refs.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (refs.items) |r| try out.print(gpa, "ref file {s}\n", .{r});
    for ([_][]const u8{ ".git/packed-refs", ".git/objects/info/commit-graph", ".git/gc.pid", ".git/gc.log" }) |path| {
        const bytes = repo.readFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {
                try out.print(gpa, "{s}: (none)\n", .{path});
                continue;
            },
            else => |e| return e,
        };
        defer gpa.free(bytes);
        // The commit graph's bytes are relic's own; that it is there is
        // what git's gc decides.
        if (std.mem.endsWith(u8, path, "commit-graph")) {
            try out.print(gpa, "{s}: present\n", .{path});
        } else try out.print(gpa, "{s}:\n{s}", .{ path, bytes });
    }
    var tables: usize = 0;
    if (repo.dir.openDir(io, ".git/reftable", .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| tables += @intFromBool(std.mem.endsWith(u8, entry.name, ".ref"));
    } else |_| {}
    try out.print(gpa, "reftables: {d}\n", .{tables});
    return out.toOwnedSlice(gpa);
}

const Case = struct {
    args: []const []const u8,
    options: collect.Options,
    /// Settings both repositories take first.
    config: []const [2][]const u8 = &.{},
};

fn compare(format: testgit.RefFormat, cases: []const Case, configure: ?*const fn (*testgit.Repo, i64) anyerror!void) !void {
    const now = Io.Clock.real.now(io).toSeconds();
    for (cases, 0..) |case, n| {
        var theirs = try shared.fixture(format, now);
        defer theirs.deinit();
        var ours = try shared.fixture(format, now);
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            // Both sides' dates the same second, however long apart they run.
            var expire: [32]u8 = undefined;
            try r.exec(io, &.{ "config", "gc.pruneExpire", try std.mem.print(&expire, "@{d}", .{now - 14 * day}) });
            for (case.config) |kv| try r.exec(io, &.{ "config", kv[0], kv[1] });
            if (configure) |c| try c(r, now);
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "gc", "-q" });
        try args.appendSlice(gpa, case.args);
        try gitGc(&theirs, args.items);
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var options = case.options;
        options.programs = .{ .environ = &ours.isolated.? };
        options.pack.threads = 1;
        _ = try collect.collect(gpa, io, &native, options);
        inline for (.{ shared.state, housekeeping }) |describe| {
            const expected = try describe(&theirs);
            defer gpa.free(expected);
            const actual = try describe(&ours);
            defer gpa.free(actual);
            std.testing.expectEqualStrings(expected, actual) catch |err| {
                std.debug.print("gc case {d}\n", .{n});
                return err;
            };
        }
        try ours.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
    }
}

fn runsInFormat(format: testgit.RefFormat) !void {
    const c = clock().clock;
    try compare(format, &.{
        .{ .args = &.{}, .options = .{ .clock = c } },
        .{ .args = &.{"--prune=now"}, .options = .{ .clock = c, .prune = .now } },
        .{ .args = &.{"--no-prune"}, .options = .{ .clock = c, .prune = .never } },
        .{ .args = &.{"--no-cruft"}, .options = .{ .clock = c, .cruft = false } },
        .{ .args = &.{"--aggressive"}, .options = .{ .clock = c, .aggressive = true } },
        .{ .args = &.{"--keep-largest-pack"}, .options = .{ .clock = c, .keep_largest_pack = true } },
        .{ .args = &.{}, .options = .{ .clock = c }, .config = &.{ .{ "gc.bigPackThreshold", "1" }, .{ "gc.pruneExpire", "now" } } },
        .{ .args = &.{}, .options = .{ .clock = c }, .config = &.{ .{ "gc.packRefs", "false" }, .{ "gc.reflogExpire", "never" }, .{ "gc.reflogExpireUnreachable", "never" } } },
        .{ .args = &.{}, .options = .{ .clock = c }, .config = &.{.{ "gc.writeCommitGraph", "false" }} },
    }, null);
}

test "gc packs the refs, expires the logs, repacks and prunes what git's does, in both ref formats" {
    try testgit.eachRefFormat(runsInFormat);
}

/// Blobs whose names begin `17`, loose, a day old: what `gc --auto`
/// samples.
fn seventeen(repo: *testgit.Repo, now: i64) !void {
    var found: usize = 0;
    var n: usize = 0;
    while (found < 2) : (n += 1) {
        var content: [64]u8 = undefined;
        const bytes = try std.mem.print(&content, "in objects/17, try {d}\n", .{n});
        var header: [32]u8 = undefined;
        var sha: std.crypto.hash.Sha1 = .init(.{});
        sha.update(try std.mem.print(&header, "blob {d}\x00", .{bytes.len}));
        sha.update(bytes);
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        if (digest[0] != 0x17) continue;
        const name = try shared.blob(repo, bytes);
        defer gpa.free(name);
        try shared.touchObject(repo, name, (if (now == 0) Io.Clock.real.now(io).toSeconds() else now) - day);
        found += 1;
    }
}

fn autoInFormat(format: testgit.RefFormat) !void {
    const c = clock().clock;
    const no_detach: [2][]const u8 = .{ "gc.autoDetach", "false" };
    // Too many packs: the fixture has two that are not kept.
    try compare(format, &.{
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ no_detach, .{ "gc.autoPackLimit", "1" } } },
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ no_detach, .{ "gc.autoPackLimit", "1" }, .{ "gc.bigPackThreshold", "1" } } },
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ no_detach, .{ "gc.autoPackLimit", "5" } } },
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ no_detach, .{ "gc.auto", "0" }, .{ "gc.autoPackLimit", "1" } } },
    }, null);
    // Too many loose objects: two in `objects/17` are 512, above 256.
    try compare(format, &.{
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ no_detach, .{ "gc.auto", "1" } } },
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ no_detach, .{ "gc.auto", "512" } } },
    }, seventeen);
}

test "gc --auto runs when git's thresholds say, and as git's runs it" {
    try testgit.eachRefFormat(autoInFormat);
}

/// A worktree gone four months, one gone a day, and garbage in the pack
/// directory: an index with no pack, its `.keep` with it, and a pack
/// with no index.
fn leftovers(repo: *testgit.Repo, now: i64) !void {
    for ([_][]const u8{ "gone-long", "gone-lately" }) |name| {
        var path: [64]u8 = undefined;
        const tree = try std.mem.print(&path, "trees/{s}", .{name});
        try repo.exec(io, &.{ "worktree", "add", "-q", "--detach", tree });
        try repo.dir.deleteTree(io, tree);
    }
    try repo.dir.setTimestamps(io, ".git/worktrees/gone-long/index", .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, now - 120 * day) * std.time.ns_per_s) } });
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".idx")) {
        try pack_dir.copyFile(entry.name, pack_dir, "pack-0000000000000000000000000000000000000000.idx", io, .{});
        break;
    };
    try pack_dir.writeFile(io, .{ .sub_path = "pack-0000000000000000000000000000000000000000.keep", .data = "" });
    try pack_dir.writeFile(io, .{ .sub_path = "pack-1111111111111111111111111111111111111111.pack", .data = "PACK" });
}

/// The worktrees and the garbage `leftovers` made, as each side leaves them.
fn leftoversState(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_][]const u8{
        ".git/worktrees/gone-long",
        ".git/worktrees/gone-lately",
        ".git/objects/pack/pack-0000000000000000000000000000000000000000.idx",
        ".git/objects/pack/pack-0000000000000000000000000000000000000000.keep",
        ".git/objects/pack/pack-1111111111111111111111111111111111111111.pack",
    }) |path| {
        const there = if (repo.dir.access(io, path, .{})) |_| true else |_| false;
        try out.print(gpa, "{s}: {}\n", .{ path, there });
    }
    return out.toOwnedSlice(gpa);
}

test "gc prunes the worktrees gone longer than gc.worktreePruneExpire and the pack directory's garbage, as git's" {
    const now = Io.Clock.real.now(io).toSeconds();
    var theirs = try shared.fixture(.files, now);
    defer theirs.deinit();
    var ours = try shared.fixture(.files, now);
    defer ours.deinit();
    try leftovers(&theirs, now);
    try leftovers(&ours, now);
    try gitGc(&theirs, &.{ "gc", "-q" });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    var options = clock();
    options.pack.threads = 1;
    const report = try collect.collect(gpa, io, &native, options);
    const expected = try leftoversState(&theirs);
    defer gpa.free(expected);
    const actual = try leftoversState(&ours);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(u32, 1), report.worktrees_pruned);
    try std.testing.expectEqual(@as(u32, 2), report.pack_garbage);
}

fn writePid(repo: *testgit.Repo, pid: u64, host: []const u8, age: i64) !void {
    var text: [fs.max_host_name + 32]u8 = undefined;
    try repo.writeFile(io, ".git/gc.pid", try std.mem.print(&text, "{d} {s}", .{ pid, host }));
    const when = Io.Clock.real.now(io).toSeconds() - age;
    try repo.dir.setTimestamps(io, ".git/gc.pid", .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, when) * std.time.ns_per_s) } });
}

test "gc.pid stops a gc while its holder runs, as git's: here or on another host, within twelve hours, --force aside" {
    var host_buf: [fs.max_host_name]u8 = undefined;
    const host = try fs.hostName(&host_buf);
    const pid: u64 = fs.currentPid();
    const Lock = struct { pid: u64, host: []const u8, age: i64, held: bool };
    const locks = [_]Lock{
        .{ .pid = pid, .host = host, .age = 60, .held = true },
        .{ .pid = 1, .host = "another-host.example", .age = 60, .held = true },
        .{ .pid = pid, .host = host, .age = 13 * std.time.s_per_hour, .held = false },
    };
    for (locks) |lock| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try shared.commitAt(&git, testgit.fixture_date, "one");
        try git.exec(io, &.{ "config", "gc.autoPackLimit", "0" });
        try git.exec(io, &.{ "config", "gc.auto", "1" });
        try writePid(&git, lock.pid, lock.host, lock.age);
        // git refuses as relic does.
        git.defaults = &gc_settings;
        var captured = try git.capture(io, &.{ "gc", "-q" });
        git.defaults = &testgit.default_settings;
        defer captured.deinit(gpa);
        try std.testing.expectEqual(lock.held, captured.code != 0);
        try writePid(&git, lock.pid, lock.host, lock.age);

        var native = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer native.deinit(io);
        if (lock.held) {
            try std.testing.expectError(error.GcRunning, collect.collect(gpa, io, &native, clock()));
            var auto = clock();
            auto.auto = true;
            auto.detach = false;
            auto.prune = .never;
            // Nothing asks for an automatic gc here, so it stops first.
            try std.testing.expectEqual(collect.Outcome.not_needed, (try collect.collect(gpa, io, &native, auto)).outcome);
            var forced = clock();
            forced.force = true;
            try std.testing.expectEqual(collect.Outcome.ran, (try collect.collect(gpa, io, &native, forced)).outcome);
        } else {
            try std.testing.expectEqual(collect.Outcome.ran, (try collect.collect(gpa, io, &native, clock())).outcome);
        }
        // The pid file goes with the gc that wrote it.
        try std.testing.expectError(error.FileNotFound, git.dir.access(io, ".git/gc.pid", .{}));
    }
}

test "gc --auto under a held gc.pid says who holds it" {
    var host_buf: [fs.max_host_name]u8 = undefined;
    const host = try fs.hostName(&host_buf);
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try shared.commitAt(&git, testgit.fixture_date, "one");
    try git.exec(io, &.{ "repack", "-q" });
    try shared.commitAt(&git, testgit.fixture_date + 1, "two");
    try git.exec(io, &.{ "repack", "-q" });
    try git.exec(io, &.{ "config", "gc.autoPackLimit", "1" });
    try writePid(&git, fs.currentPid(), host, 60);
    var native = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer native.deinit(io);
    var auto = clock();
    auto.auto = true;
    auto.detach = false;
    const report = try collect.collect(gpa, io, &native, auto);
    try std.testing.expectEqual(collect.Outcome.running, report.outcome);
    try std.testing.expectEqual(@as(u64, fs.currentPid()), report.holder.?.pid);
    try std.testing.expectEqualStrings(host, report.holder.?.host());
}

test "a detached gc stops at a recent gc.log and records its warning there, and one in the foreground removes the log" {
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try shared.commitAt(&git, testgit.fixture_date, "one");
    try seventeen(&git, 0);
    try git.exec(io, &.{ "config", "gc.auto", "1" });
    try git.writeFile(io, ".git/gc.log", "error: an earlier run failed\n");
    var native = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer native.deinit(io);
    var detached = clock();
    detached.auto = true;
    detached.detach = true;
    try std.testing.expectEqual(collect.Outcome.last_failed, (try collect.collect(gpa, io, &native, detached)).outcome);

    // A log older than `gc.logExpiry` is let be, and this run's warning
    // replaces it: the unreachable loose objects in `objects/17` are new.
    const old = Io.Clock.real.now(io).toSeconds() - 2 * day;
    try git.dir.setTimestamps(io, ".git/gc.log", .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, old) * std.time.ns_per_s) } });
    const report = try collect.collect(gpa, io, &native, detached);
    try std.testing.expectEqual(collect.Outcome.ran, report.outcome);
    try std.testing.expect(report.too_many_loose);
    const log = try git.readFile(io, ".git/gc.log");
    defer gpa.free(log);
    try std.testing.expect(std.mem.startsWith(u8, log, "warning: There are too many unreachable loose objects"));

    // A detached run stops at that log; one in the foreground removes it.
    try std.testing.expectEqual(collect.Outcome.last_failed, (try collect.collect(gpa, io, &native, detached)).outcome);
    var foreground = detached;
    foreground.detach = false;
    try std.testing.expectEqual(collect.Outcome.ran, (try collect.collect(gpa, io, &native, foreground)).outcome);
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, ".git/gc.log", .{}));
}

test "a failing pre-auto-gc hook stops gc --auto, as git's" {
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    var ours = try testgit.Repo.init(gpa, io, &.{});
    defer ours.deinit();
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
        try shared.commitAt(r, testgit.fixture_date, "one");
        try seventeen(r, 0);
        try r.exec(io, &.{ "config", "gc.auto", "1" });
        try r.exec(io, &.{ "config", "gc.autoDetach", "false" });
        try testgit.fixtureHook(gpa, io, r.dir, ".git/hooks/pre-auto-gc", "status", "1");
        // Both sides' objects the same age, however far apart they were made.
        try shared.ageAll(r, testgit.fixture_date);
    }
    try gitGc(&theirs, &.{ "gc", "--auto", "-q" });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    var runner = try native.hookRunner(io, .{ .environ = &ours.isolated.? }, .{ .output = .ignore });
    defer runner.deinit();
    var auto = clock();
    auto.auto = true;
    auto.hooks = &runner;
    try std.testing.expectEqual(collect.Outcome.hook_declined, (try collect.collect(gpa, io, &native, auto)).outcome);
    const expected = try shared.state(&theirs);
    defer gpa.free(expected);
    const actual = try shared.state(&ours);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
