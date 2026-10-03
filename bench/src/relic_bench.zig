//! relic's side of the head-to-head benchmark.
//!
//! One workload per invocation, chosen by the first argument. Every timed
//! region starts at "open the repository" and ends when the work is done,
//! which is the same boundary the rival programs use and the same one the
//! `git` subprocess pays for (minus its process start). The best of the
//! internal repetitions is printed, and `run.sh` takes the best of five
//! processes on top of that.
//!
//!   relic_bench status   <repo>
//!   relic_bench addall   <repo>            (repo is a fresh, 1 % dirty copy)
//!   relic_bench revlist  <repo>
//!   relic_bench catblobs <repo> <blobs.txt>
//!   relic_bench packwrite <repo>           (repo is a fresh loose-object copy)
//!   relic_bench indexrw  <repo> <scratch-dir>
//!   relic_bench <operation> <repo> [extra]  (the operation workloads, `ops.zig`)

const std = @import("std");
const Io = std.Io;
const relic = @import("relic");
const smoke = @import("bench_options").smoke;
const ops = @import("ops.zig");

const Oid = relic.hash.Oid;

fn ms(io: Io, from: Io.Timestamp) f64 {
    const now = benchmarkNow(io);
    const ns: f64 = @floatFromInt(from.durationTo(now).toNanoseconds());
    return ns / std.time.ns_per_ms;
}

var out_buf: [4096]u8 = undefined;

/// git's own delta base cache is 96 MiB (`core.deltaBaseCacheLimit`); relic's
/// default is 16 MiB. `RELIC_DELTA_CACHE_MB` overrides it, so the README can
/// price that difference rather than guess at it.
var delta_cache_mb: usize = 16;

fn emit(io: Io, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) void {
    const line = std.fmt.bufPrint(&out_buf, "relic\t{s}\t{s}\t{d:.3}\t{s}\n", .{
        workload, metric, value, unit,
    }) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

pub fn main(init: std.process.Init) !void {
    // `std.heap.smp_allocator` rather than the process default: relic's own
    // benchmark uses it for the same reason, and every rival here allocates
    // from its language's ordinary allocator rather than from a checking one.
    const gpa = std.heap.smp_allocator;
    _ = init.gpa;
    if (init.environ_map.get("RELIC_DELTA_CACHE_MB")) |mb_text| {
        delta_cache_mb = std.fmt.parseInt(usize, mb_text, 10) catch 16;
    }
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const command = args.next() orelse return error.MissingCommand;
    const repo_path = args.next() orelse return error.MissingRepoPath;
    const extra = args.next();

    var cwd: Io.Dir = .cwd();
    if (ops.isOp(command)) return ops.run(gpa, io, cwd, command, repo_path, extra);
    var dir = try cwd.openDir(io, repo_path, .{ .iterate = true });
    defer dir.close(io);

    if (std.mem.eql(u8, command, "status")) {
        try status(gpa, io, dir);
    } else if (std.mem.eql(u8, command, "addall")) {
        try addAll(gpa, io, dir);
    } else if (std.mem.eql(u8, command, "revlist")) {
        try revList(gpa, io, dir);
    } else if (std.mem.eql(u8, command, "catblobs")) {
        try catBlobs(gpa, io, cwd, dir, extra orelse return error.MissingBlobList);
    } else if (std.mem.eql(u8, command, "packwrite")) {
        try packWrite(gpa, io, dir);
    } else if (std.mem.eql(u8, command, "indexrw")) {
        try indexReadWrite(gpa, io, cwd, dir, extra orelse return error.MissingScratchDir);
    } else {
        return error.UnknownCommand;
    }
}

/// Workload 1: status of a clean worktree with a warm index.
fn status(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    const reps: usize = if (smoke) 1 else 5;
    var best: f64 = std.math.floatMax(f64);
    var entries: usize = 0;
    for (0..reps) |_| {
        const start = benchmarkNow(io);

        var repo = try relic.repo.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var ignore_rules = try repo.loadIgnore(io);
        defer ignore_rules.deinit();
        var attrs = try repo.loadAttrs(io);
        defer attrs.deinit();
        var rules = try worktreeRules(&repo);
        rules.ignore = &ignore_rules;
        rules.attrs = &attrs;
        const t_open = ms(io, start);
        var index = try repo.openIndex(io);
        defer index.deinit();
        const t_index = ms(io, start);
        const head_tree = try repo.headTree(io);
        var result = try relic.worktree.status(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
            .rules = rules,
            .head_tree = head_tree,
            .untracked = .all,
        });
        defer result.deinit();

        // Where the time went, to stderr: the harness reads stdout only.
        std.debug.print("  relic status: open+rules {d:.1} ms, index {d:.1} ms, walk {d:.1} ms\n", .{
            t_open, t_index - t_open, ms(io, start) - t_index,
        });
        best = @min(best, ms(io, start));
        entries = result.entries.len;
    }
    emit(io, "status", "time", best, "ms");
    emit(io, "status", "entries", @floatFromInt(entries), "count");
}

/// Workload 2: add -A then write-tree over a worktree with 1 % of its files
/// modified. The repository is a fresh copy, so this runs once.
fn addAll(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    const start = benchmarkNow(io);

    var repo = try relic.repo.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = try worktreeRules(&repo);
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    var index = try repo.openIndex(io);
    defer index.deinit();

    const outcome = try relic.worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
        .rules = rules,
    });
    const tree = try relic.worktree.writeTree(gpa, io, &index, &repo.odb);
    // `sync = .none` is what git, libgit2, gix and go-git all do; relic's
    // own default fsyncs the index before the rename. The like-for-like
    // number is the one compared, and `indexrw` prices the difference.
    try index.write(io, repo.git_dir, "index", .{ .lock = .{ .sync = .none } });

    const took = ms(io, start);
    std.mem.doNotOptimizeAway(&tree);
    emit(io, "addall", "time", took, "ms");
    emit(io, "addall", "hashed", @floatFromInt(outcome.hashed), "count");
}

/// Workload 3: walk every commit and count the trees and blobs reached.
///
/// The same set `git rev-list --objects HEAD` prints, and the same shape of
/// work every rival here does: the history walk hands over commits, each
/// commit's tree is recursed, and a subtree already seen is not descended
/// into again. `Odb.collectReachable` would do all of this in one call, but
/// it also builds the path of every object for the delta search, which no
/// rival is asked for here.
fn revList(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    const reps: usize = if (smoke) 1 else 3;
    var best: f64 = std.math.floatMax(f64);
    var objects: usize = 0;
    for (0..reps) |_| {
        const start = benchmarkNow(io);

        var repo = try relic.repo.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        const head = (try repo.head(io)) orelse return error.UnbornHead;
        defer gpa.free(head.name);

        var walk: relic.revwalk.Walk = .init(gpa, &repo.odb);
        defer walk.deinit();
        try walk.push(head.oid);

        var seen: Oid.Set = .empty;
        defer seen.deinit(gpa);
        var pending: std.ArrayList(Oid) = .empty;
        defer pending.deinit(gpa);
        var count: usize = 0;

        while (try walk.next(io)) |commit| {
            count += 1; // the commit itself, as `rev-list --objects` prints it
            const tree = try repo.commitTree(io, commit.oid);
            if (seen.contains(tree)) continue;
            try seen.put(gpa, tree, {});
            try pending.append(gpa, tree);
        }

        while (pending.pop()) |tree_oid| {
            count += 1;
            const found = try repo.odb.read(io, tree_oid);
            defer gpa.free(found.bytes);
            var it = relic.object.Tree.parse(objectFormat(&repo), found.bytes).iterate();
            while (try it.next()) |entry| switch (entry.mode) {
                .tree => {
                    if (seen.contains(entry.oid)) continue;
                    try seen.put(gpa, entry.oid, {});
                    try pending.append(gpa, entry.oid);
                },
                // A gitlink names a commit in another repository.
                .gitlink => {},
                else => {
                    if (seen.contains(entry.oid)) continue;
                    try seen.put(gpa, entry.oid, {});
                    count += 1;
                },
            };
        }

        best = @min(best, ms(io, start));
        objects = count;
    }
    // And the same answer through the one call relic has for it, which also
    // builds each object's path for a later delta search.
    var best_collect: f64 = std.math.floatMax(f64);
    for (0..reps) |_| {
        const start = benchmarkNow(io);
        var repo = try relic.repo.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        const head = (try repo.head(io)) orelse return error.UnbornHead;
        defer gpa.free(head.name);
        var collected = try repo.odb.collectReachable(io, &.{head.oid}, .{});
        defer collected.deinit();
        best_collect = @min(best_collect, ms(io, start));
        std.debug.assert(collected.entries.len == objects);
    }

    emit(io, "revlist", "time", best, "ms");
    emit(io, "revlist", "time_collect", best_collect, "ms");
    emit(io, "revlist", "objects", @floatFromInt(objects), "count");
}

/// Workload 4: read every blob in the packed repository, through the pack.
fn catBlobs(gpa: std.mem.Allocator, io: Io, cwd: Io.Dir, dir: Io.Dir, list_path: []const u8) !void {
    const text = try cwd.readFileAlloc(io, list_path, gpa, .limited(1 << 28));
    defer gpa.free(text);

    var oids: std.ArrayList(Oid) = .empty;
    defer oids.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try oids.append(gpa, try Oid.parse(.sha1, trimmed));
    }

    const start = benchmarkNow(io);
    var repo = try relic.repo.Repository.open(gpa, io, dir, .{
        .odb = .{ .delta_cache_bytes = delta_cache_mb << 20 },
    });
    defer repo.deinit(io);
    var total: u64 = 0;
    for (oids.items) |oid| {
        const found = try repo.odb.read(io, oid);
        total += found.bytes.len;
        gpa.free(found.bytes);
    }
    const took = ms(io, start);

    const mb: f64 = @as(f64, @floatFromInt(total)) / (1000.0 * 1000.0);
    emit(io, "catblobs", "throughput", mb / (took / 1000.0), "MB/s");
    emit(io, "catblobs", "time", took, "ms");
    emit(io, "catblobs", "bytes", @floatFromInt(total), "bytes");
}

/// Workload 5: pack every loose object, with deltas.
fn packWrite(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    const start = benchmarkNow(io);
    var repo = try relic.repo.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    // relic's own defaults: window 10, depth 50, offset deltas — git's
    // defaults too — and one sync barrier at the end of the batch, which is
    // what git's default `core.fsync=committed,-loose-object` also does for
    // a pack it writes. The loose objects are left in place because the
    // harness throws the copy away anyway.
    const report = try repo.odb.packLoose(io, .{ .remove_loose = false });
    const took = ms(io, start);

    const written = report.written orelse return error.NothingPacked;
    emit(io, "packwrite", "time", took, "ms");
    emit(io, "packwrite", "pack_bytes", @floatFromInt(written.pack_bytes), "bytes");
    emit(io, "packwrite", "objects", @floatFromInt(written.objects), "count");
    emit(io, "packwrite", "deltas", @floatFromInt(written.deltas), "count");
}

/// Workload 6: read the index and write it back out.
fn indexReadWrite(gpa: std.mem.Allocator, io: Io, cwd: Io.Dir, dir: Io.Dir, scratch: []const u8) !void {
    var scratch_dir = try cwd.openDir(io, scratch, .{});
    defer scratch_dir.close(io);

    const reps: usize = if (smoke) 1 else 10;
    var best: f64 = std.math.floatMax(f64);
    var best_durable: f64 = std.math.floatMax(f64);
    var entries: usize = 0;
    // The git directory is opened outside the timed region here: what is
    // measured is the index, not the discovery that finds it.
    var git_dir = try dir.openDir(io, ".git", .{ .iterate = true });
    defer git_dir.close(io);

    for (0..reps) |_| {
        // Like for like: no rival fsyncs the index it writes.
        const start = benchmarkNow(io);
        var index = try relic.index.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
        defer index.deinit();
        try index.write(io, scratch_dir, "index.relic", .{ .lock = .{ .sync = .none } });
        best = @min(best, ms(io, start));
        entries = index.items().len;

        // And relic's own default, which fsyncs before the rename.
        const durable_start = benchmarkNow(io);
        var durable = try relic.index.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
        defer durable.deinit();
        try durable.write(io, scratch_dir, "index.relic.durable", .{});
        best_durable = @min(best_durable, ms(io, durable_start));
    }
    emit(io, "indexrw", "time", best, "ms");
    emit(io, "indexrw", "time_durable", best_durable, "ms");
    emit(io, "indexrw", "entries", @floatFromInt(entries), "count");
}

// The final API validates refreshed repository configuration.
fn worktreeRules(repo: *relic.repo.Repository) !relic.worktree.Rules {
    const result = repo.worktreeRules();
    return if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
}

fn objectFormat(repo: *const relic.repo.Repository) relic.hash.Kind {
    return if (@hasDecl(relic.repo.Repository, "objectFormat")) repo.objectFormat() else repo.kind;
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
