//! relic's side of the operation workloads: one public operation per
//! workload, on the repositories `mkops.py` builds.
//!
//!   relic_bench <workload> <repo> [extra]
//!
//! Read-only workloads take the best of three internal repetitions (one in
//! smoke); a workload that writes runs once, on a fresh copy the harness
//! makes. The clock starts at "open the repository", as everywhere in this
//! bench. Every workload prints what it found as `count` or `oid` rows, and
//! the harness requires every side that did the work to agree on them.

const std = @import("std");
const Io = std.Io;
const relic = @import("relic");
const smoke = @import("bench_options").smoke;

const Oid = relic.hash.Oid;
const Repository = relic.repo.Repository;
const Allocator = std.mem.Allocator;

/// The identity and the clock of every commit, tag and stash a side makes,
/// the same on every side so the objects are the same objects.
const who: relic.object.Signature = .{ .name = "Bench", .email = "bench\x40example.invalid", .when_secs = 1_700_000_000, .offset_minutes = 0 };
/// The path `mkops.py` changes in every tenth commit.
const hot_path = "d00/d00/f0000.txt";

const reps: usize = if (smoke) 1 else 3;

pub const names = [_][]const u8{
    "diff-tree",     "diff-renames", "diff-patch",       "diff-index",          "log",         "log-path",
    "revparse",      "merge-base",   "merge-tree-clean", "merge-tree-conflict", "merge-clean", "merge-conflict",
    "rebase",        "cherry-pick",  "revert",           "commit",              "switch",      "stash",
    "branch-create", "tag-create",   "ref-list",         "repack",              "verify",      "worktree-add",
    "lfs-add",       "lfs-checkout", "submodule-status", "submodule-update",    "snapshot",    "patch-id",
    "blame",
};

pub fn isOp(command: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, command)) return true;
    return false;
}

var out_buf: [512]u8 = undefined;

fn emit(io: Io, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) void {
    const line = std.fmt.bufPrint(&out_buf, "relic\t{s}\t{s}\t{d:.3}\t{s}\n", .{ workload, metric, value, unit }) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

fn emitCount(io: Io, workload: []const u8, metric: []const u8, value: usize) void {
    emit(io, workload, metric, @floatFromInt(value), "count");
}

fn emitOid(io: Io, workload: []const u8, metric: []const u8, oid: Oid) void {
    var hex: [relic.hash.max_hex_len]u8 = undefined;
    const line = std.fmt.bufPrint(&out_buf, "relic\t{s}\t{s}\t{s}\t{s}\n", .{ workload, metric, oid.hex(&hex), "oid" }) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

/// An operation this revision of relic does not have: the harness reports
/// the side as unavailable, with the reason.
fn unavailable(io: Io, workload: []const u8, reason: []const u8) void {
    const line = std.fmt.bufPrint(&out_buf, "relic\t{s}\ttime\tunavailable\tms\nrelic\t{s}\treason\t{s}\ttext\n", .{ workload, workload, reason }) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

fn ms(io: Io, from: Io.Timestamp) f64 {
    const ns: f64 = @floatFromInt(from.durationTo(benchmarkNow(io)).toNanoseconds());
    return ns / std.time.ns_per_ms;
}

pub fn run(gpa: Allocator, io: Io, cwd: Io.Dir, command: []const u8, repo_path: []const u8, extra: ?[]const u8) !void {
    var dir = try cwd.openDir(io, repo_path, .{ .iterate = true });
    defer dir.close(io);
    const c = Ctx{ .gpa = gpa, .io = io, .cwd = cwd, .dir = dir, .name = command, .extra = extra };
    const eql = std.mem.eql;
    if (eql(u8, command, "diff-tree")) return c.diffTree("refs/tags/fork", "refs/heads/main", false);
    if (eql(u8, command, "diff-renames")) return c.diffTree("refs/heads/main", "refs/heads/renamed", true);
    if (eql(u8, command, "diff-patch")) return c.diffPatch();
    if (eql(u8, command, "diff-index")) return c.diffIndex();
    if (eql(u8, command, "log")) return c.log();
    if (eql(u8, command, "log-path")) return c.logPath();
    if (eql(u8, command, "revparse")) return c.revparse();
    if (eql(u8, command, "merge-base")) return c.mergeBase();
    if (eql(u8, command, "merge-tree-clean")) return c.mergeTree("side");
    if (eql(u8, command, "merge-tree-conflict")) return c.mergeTree("conflict");
    if (eql(u8, command, "merge-clean")) return c.merge("side");
    if (eql(u8, command, "merge-conflict")) return c.merge("conflict");
    if (eql(u8, command, "rebase")) return c.rebase();
    if (eql(u8, command, "cherry-pick")) return c.sequence(.pick);
    if (eql(u8, command, "revert")) return c.sequence(.revert);
    if (eql(u8, command, "commit")) return c.commit();
    if (eql(u8, command, "switch")) return c.switchBranch();
    if (eql(u8, command, "stash")) return c.stash();
    if (eql(u8, command, "branch-create")) return c.branchCreate();
    if (eql(u8, command, "tag-create")) return c.tagCreate();
    if (eql(u8, command, "ref-list")) return c.refList();
    if (eql(u8, command, "repack")) return c.repack();
    if (eql(u8, command, "verify")) return c.verify();
    if (eql(u8, command, "worktree-add")) return c.worktreeAdd();
    if (eql(u8, command, "lfs-add")) return c.lfsAdd();
    if (eql(u8, command, "lfs-checkout")) return c.lfsCheckout();
    if (eql(u8, command, "submodule-status")) return c.submoduleStatus();
    if (eql(u8, command, "submodule-update")) return c.submoduleUpdate();
    if (eql(u8, command, "snapshot")) return c.snapshot();
    if (eql(u8, command, "patch-id")) return c.patchId();
    if (eql(u8, command, "blame")) return c.blame();
    return error.UnknownCommand;
}

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    cwd: Io.Dir,
    dir: Io.Dir,
    name: []const u8,
    extra: ?[]const u8,

    fn open(c: Ctx) !Repository {
        return Repository.open(c.gpa, c.io, c.dir, .{});
    }

    fn resolve(c: Ctx, repo: *Repository, expr: []const u8) !Oid {
        return relic.revwalk.revparse.resolve(c.gpa, c.io, repo, expr);
    }

    /// The working-tree rules a caller builds: the repository's ignore and
    /// attribute files, with the filters when `filters` is given.
    const Rules = struct {
        ignore: relic.worktree.ignore.Rules,
        attrs: relic.worktree.attributes.Attrs,
        rules: relic.worktree.Rules,

        fn deinit(r: *Rules) void {
            r.ignore.deinit();
            r.attrs.deinit();
        }
    };

    fn rules(c: Ctx, repo: *Repository, out: *Rules) !void {
        out.ignore = try repo.loadIgnore(c.io);
        out.attrs = try repo.loadAttrs(c.io);
        out.rules = try worktreeRules(repo);
        out.rules.ignore = &out.ignore;
        out.rules.attrs = &out.attrs;
    }

    // ---------------------------------------------------------------- diff

    fn diffTree(c: Ctx, old_ref: []const u8, new_ref: []const u8, renames: bool) !void {
        var best: f64 = std.math.floatMax(f64);
        var counts: [5]usize = undefined;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            const old = try repo.commitTree(c.io, try c.resolve(&repo, old_ref));
            const new = try repo.commitTree(c.io, try c.resolve(&repo, new_ref));
            var changes = try relic.diff.tree(c.gpa, c.io, &repo.odb, old, new, .{ .renames = if (renames) .{} else null });
            defer changes.deinit();
            best = @min(best, ms(c.io, start));
            counts = @splat(0);
            for (changes.items) |change| {
                counts[0] += 1;
                switch (change.status) {
                    .added => counts[1] += 1,
                    .deleted => counts[2] += 1,
                    .modified => counts[3] += 1,
                    .renamed => counts[4] += 1,
                    else => {},
                }
            }
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "changes", counts[0]);
        emitCount(c.io, c.name, "added", counts[1]);
        emitCount(c.io, c.name, "deleted", counts[2]);
        emitCount(c.io, c.name, "modified", counts[3]);
        emitCount(c.io, c.name, "renamed", counts[4]);
    }

    /// `git diff fork main`: the unified patch of every change, in memory.
    fn diffPatch(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var plus: usize = 0;
        var minus: usize = 0;
        var bytes: usize = 0;
        for (0..reps) |_| {
            var patch: Io.Writer.Allocating = .init(c.gpa);
            defer patch.deinit();
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            const old = try repo.commitTree(c.io, try c.resolve(&repo, "refs/tags/fork"));
            const new = try repo.commitTree(c.io, try c.resolve(&repo, "refs/heads/main"));
            var changes = try relic.diff.tree(c.gpa, c.io, &repo.odb, old, new, .{});
            defer changes.deinit();
            for (changes.items) |change| try relic.diff.unified(c.gpa, c.io, &patch.writer, &repo.odb, change, .{});
            best = @min(best, ms(c.io, start));
            const text = patch.written();
            bytes = text.len;
            plus = 0;
            minus = 0;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "--- ")) continue;
                if (std.mem.startsWith(u8, line, "+")) plus += 1;
                if (std.mem.startsWith(u8, line, "-")) minus += 1;
            }
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "insertions", plus);
        emitCount(c.io, c.name, "deletions", minus);
        emit(c.io, c.name, "patch_bytes", @floatFromInt(bytes), "bytes");
    }

    /// `git diff --numstat`: the index against the working tree, with the
    /// lines each modified file adds and removes.
    fn diffIndex(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var files: usize = 0;
        var plus: usize = 0;
        var minus: usize = 0;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var r: Rules = undefined;
            try c.rules(&repo, &r);
            defer r.deinit();
            var index = try repo.openIndex(c.io);
            defer index.deinit();
            var result = try relic.worktree.status(c.gpa, c.io, repo.work_dir.?, &index, &repo.odb, .{
                .rules = r.rules,
                .untracked = .no,
            });
            defer result.deinit();
            files = 0;
            plus = 0;
            minus = 0;
            for (result.entries) |entry| {
                if (entry.unstaged != .modified) continue;
                const recorded = index.find(entry.path) orelse continue;
                const old = try repo.odb.read(c.io, recorded.oid);
                defer c.gpa.free(old.bytes);
                const new = try repo.work_dir.?.readFileAlloc(c.io, entry.path, c.gpa, .unlimited);
                defer c.gpa.free(new);
                const counts = try relic.diff.blobNumStat(c.gpa, old.bytes, new, .{});
                files += 1;
                plus += counts.plus;
                minus += counts.minus;
            }
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "files", files);
        emitCount(c.io, c.name, "insertions", plus);
        emitCount(c.io, c.name, "deletions", minus);
    }

    // ------------------------------------------------------------- history

    /// `git log main`: every commit, read and parsed for its author and
    /// message, in date order.
    fn log(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var count: usize = 0;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var walk: relic.revwalk.Walk = .init(c.gpa, &repo.odb);
            defer walk.deinit();
            try walk.push(try c.resolve(&repo, "refs/heads/main"));
            count = 0;
            while (try walk.next(c.io)) |walked| {
                const found = try repo.odb.read(c.io, walked.oid);
                defer c.gpa.free(found.bytes);
                var parsed = try relic.object.Commit.parse(c.gpa, objectFormat(&repo), found.bytes);
                defer parsed.deinit();
                std.mem.doNotOptimizeAway(parsed.author.name.len + parsed.message.len);
                count += 1;
            }
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "commits", count);
    }

    /// `git log main -- <path>`: the commits whose change from their first
    /// parent touches one path, found by looking the path up in both trees.
    fn logPath(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var count: usize = 0;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var walk: relic.revwalk.Walk = .init(c.gpa, &repo.odb);
            defer walk.deinit();
            try walk.push(try c.resolve(&repo, "refs/heads/main"));
            count = 0;
            while (try walk.next(c.io)) |walked| {
                const here = try c.entryAt(&repo, try repo.commitTree(c.io, walked.oid), hot_path);
                const before: ?Oid = if (walked.parents.len == 0) null else try c.entryAt(&repo, try repo.commitTree(c.io, walked.parents[0]), hot_path);
                const same = if (here) |a| (if (before) |b| a.eql(b) else false) else before == null;
                if (!same) count += 1;
            }
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "commits", count);
    }

    /// The object at `path` under `tree`, one tree read per component.
    fn entryAt(c: Ctx, repo: *Repository, tree: Oid, path: []const u8) !?Oid {
        var at = tree;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            const found = try repo.odb.read(c.io, at);
            defer c.gpa.free(found.bytes);
            var it = relic.object.Tree.parse(objectFormat(repo), found.bytes).iterate();
            const next = while (try it.next()) |entry| {
                if (std.mem.eql(u8, entry.name, part)) break entry.oid;
            } else return null;
            at = next;
        }
        return at;
    }

    fn revparse(c: Ctx) !void {
        const text = try c.cwd.readFileAlloc(c.io, c.extra orelse return error.MissingExpressions, c.gpa, .limited(1 << 20));
        defer c.gpa.free(text);
        var best: f64 = std.math.floatMax(f64);
        var count: usize = 0;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            count = 0;
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const oid = try c.resolve(&repo, line);
                std.mem.doNotOptimizeAway(&oid);
                count += 1;
            }
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "resolved", count);
    }

    fn mergeBase(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var base: ?Oid = null;
        var ancestor = false;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            const main = try c.resolve(&repo, "refs/heads/main");
            base = try relic.revwalk.mergeBase(c.gpa, c.io, &repo.odb, main, try c.resolve(&repo, "refs/heads/side"));
            ancestor = try relic.revwalk.isAncestor(c.gpa, c.io, &repo.odb, try c.resolve(&repo, "refs/tags/fork"), main);
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitOid(c.io, c.name, "base", base orelse return error.NoMergeBase);
        emitCount(c.io, c.name, "ancestor", @intFromBool(ancestor));
    }

    fn patchId(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var count: usize = 0;
        var tip: ?Oid = null;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var walk: relic.revwalk.Walk = .init(c.gpa, &repo.odb);
            defer walk.deinit();
            try walk.push(try c.resolve(&repo, "refs/heads/main"));
            try walk.hide(try c.resolve(&repo, "refs/tags/fork"));
            count = 0;
            tip = null;
            while (try walk.next(c.io)) |walked| {
                const id = try relic.diff.patchid.ofCommit(c.gpa, c.io, &repo.odb, walked.oid);
                if (tip == null) tip = id;
                count += 1;
            }
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "commits", count);
        emitOid(c.io, c.name, "tip", tip orelse return error.NoCommits);
    }

    /// `git blame main -- <path>`: every line of the hot file, by the
    /// commit it comes from.
    fn blame(c: Ctx) !void {
        if (!@hasDecl(relic.diff, "blame")) return unavailable(c.io, c.name, "this revision has no diff.blame");
        var best: f64 = std.math.floatMax(f64);
        var lines: usize = 0;
        var commits: usize = 0;
        var last: ?Oid = null;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var found = try relic.diff.blame.file(c.gpa, c.io, &repo.odb, try c.resolve(&repo, "refs/heads/main"), hot_path, .{});
            defer found.deinit();
            best = @min(best, ms(c.io, start));
            var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
            defer seen.deinit(c.gpa);
            lines = 0;
            for (found.hunks) |h| {
                lines += h.count;
                try seen.put(c.gpa, h.commit, {});
                last = h.commit;
            }
            commits = seen.count();
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "lines", lines);
        emitCount(c.io, c.name, "commits", commits);
        emitOid(c.io, c.name, "last", last orelse return error.EmptyBlame);
    }

    // --------------------------------------------------------------- merge

    /// `git merge-tree --write-tree main <theirs>`, in a bare copy.
    fn mergeTree(c: Ctx, theirs: []const u8) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        var full_buf: [64]u8 = undefined;
        const full = try std.fmt.bufPrint(&full_buf, "refs/heads/{s}", .{theirs});
        var result = try relic.merge.ort.mergeCommits(c.gpa, c.io, &repo.odb, try c.resolve(&repo, "refs/heads/main"), try c.resolve(&repo, full), null, .{
            .labels = .{ .ours = "main", .base = "base", .theirs = theirs },
        });
        defer result.deinit();
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "conflicts", result.conflicted.len);
        if (result.isClean()) emitOid(c.io, c.name, "tree", result.tree);
    }

    /// `git merge <theirs>` on the checked-out main.
    fn merge(c: Ctx, theirs: []const u8) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const target = try relic.commit.merging.resolve(c.gpa, c.io, &repo, theirs);
        var outcome = try relic.commit.merging.start(c.gpa, c.io, &repo, target, .{ .who = who });
        defer outcome.deinit();
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "conflicts", outcome.conflicts.len);
        if (outcome.conflicts.len == 0) emitOid(c.io, c.name, "tree", (try repo.headTree(c.io)).?);
    }

    /// `git rebase main` with side checked out.
    fn rebase(c: Ctx) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        var outcome = try relic.commit.rebase.start(c.gpa, c.io, &repo, try c.resolve(&repo, "refs/heads/main"), .{ .who = who });
        defer outcome.deinit();
        const took = ms(c.io, start);
        if (outcome.stopped != null) return error.RebaseStopped;
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "commits", outcome.rewritten.len);
        emitOid(c.io, c.name, "tree", (try repo.headTree(c.io)).?);
    }

    const Replay = enum { pick, revert };

    /// `git cherry-pick side` or `git revert main` on the checked-out main.
    fn sequence(c: Ctx, replay: Replay) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const sequencer = relic.commit.sequencer;
        var outcome = switch (replay) {
            .pick => try sequencer.pick(c.gpa, c.io, &repo, &.{try c.resolve(&repo, "refs/heads/side")}, .{ .who = who }),
            .revert => try sequencer.revert(c.gpa, c.io, &repo, &.{try c.resolve(&repo, "refs/heads/main")}, .{ .who = who }),
        };
        defer outcome.deinit();
        const took = ms(c.io, start);
        if (outcome.stopped != null) return error.ReplayStopped;
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "commits", outcome.made.len);
        emitOid(c.io, c.name, "tree", (try repo.headTree(c.io)).?);
    }

    // -------------------------------------------------------------- commit

    /// `git commit -m 'bench commit'` with 1 % of the files staged.
    fn commit(c: Ctx) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const made = try relic.commit.commit(&repo, c.io, .{ .author = who, .committer = who, .message = "bench commit" }, .{});
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitOid(c.io, c.name, "tree", made.tree);
        emitOid(c.io, c.name, "commit", made.commit);
    }

    /// `git switch oldb`: check the branch's tree out over main's, write the
    /// index, and point `HEAD` at the branch.
    fn switchBranch(c: Ctx) !void {
        return c.switchTo("oldb", false);
    }

    fn switchTo(c: Ctx, branch: []const u8, filters: bool) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        var r: Rules = undefined;
        try c.rules(&repo, &r);
        defer r.deinit();
        var drivers: ?relic.worktree.filter.Drivers = if (filters) try repo.loadFilters(c.io, .{}) else null;
        defer if (drivers) |*d| d.deinit();
        if (drivers) |*d| r.rules.filters = d;
        var index = try repo.openIndex(c.io);
        defer index.deinit();
        const old = (try repo.head(c.io)).?;
        defer c.gpa.free(old.name);
        var ref_buf: [64]u8 = undefined;
        const ref = try std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{branch});
        var message_buf: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buf, "checkout: moving from main to {s}", .{branch});
        const tree = try repo.commitTree(c.io, try c.resolve(&repo, ref));
        const outcome = try relic.worktree.checkout(c.gpa, c.io, repo.work_dir.?, &index, &repo.odb, tree, .{ .rules = r.rules, .ignore = &r.ignore });
        try repo.writeIndex(c.io, &index);
        try relic.commit.head.attach(c.io, &repo, ref, old.oid, .{ .who = who, .message = message });
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitOid(c.io, c.name, "tree", tree);
        if (filters) emitCount(c.io, c.name, "written", outcome.written);
    }

    /// `git stash push`, then `git stash pop`, over 1 % of the files changed.
    fn stash(c: Ctx) !void {
        const stash_mod = relic.commit.stash;
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const made = try stash_mod.push(&repo, c.io, .{ .who = who });
        if (made == null) return error.NothingStashed;
        const pushed = ms(c.io, start);
        var applied = try stash_mod.pop(&repo, c.io, 0, .{});
        defer applied.deinit();
        const took = ms(c.io, start);
        if (!applied.isClean()) return error.StashConflicted;
        emit(c.io, c.name, "time", took, "ms");
        emit(c.io, c.name, "time_push", pushed, "ms");
        emit(c.io, c.name, "time_pop", took - pushed, "ms");
    }

    // ---------------------------------------------------------------- refs

    /// 1,000 branches at main, in one transaction.
    fn branchCreate(c: Ctx) !void {
        const count: usize = if (smoke) 10 else 1000;
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const main = try c.resolve(&repo, "refs/heads/main");
        var tx = repo.beginRefs();
        defer tx.deinit(c.io);
        var names_buf: [32]u8 = undefined;
        for (0..count) |i| {
            const name = try std.fmt.bufPrint(&names_buf, "refs/heads/bench/b{d:0>4}", .{i});
            try tx.create(name, .{ .direct = main });
        }
        try tx.commit(c.io, .{ .who = who, .message = "branch: Created from main", .policy = repo.reflogPolicy() });
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "refs", count);
    }

    /// 100 annotated tags on main, each its object and its ref.
    fn tagCreate(c: Ctx) !void {
        const count: usize = if (smoke) 5 else 100;
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const main = try c.resolve(&repo, "refs/heads/main");
        var first: ?Oid = null;
        var name_buf: [32]u8 = undefined;
        var ref_buf: [48]u8 = undefined;
        for (0..count) |i| {
            const name = try std.fmt.bufPrint(&name_buf, "bench/t{d:0>3}", .{i});
            const tag = try writeTag(&repo, c.io, .{ .target = main, .target_type = .commit, .name = name, .tagger = who, .message = "bench tag\n" });
            if (first == null) first = tag;
            var tx = repo.beginRefs();
            defer tx.deinit(c.io);
            try tx.create(try std.fmt.bufPrint(&ref_buf, "refs/tags/{s}", .{name}), .{ .direct = tag });
            try tx.commit(c.io, .{ .who = who, .policy = repo.reflogPolicy() });
        }
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "tags", count);
        emitOid(c.io, c.name, "first", first.?);
    }

    /// `git for-each-ref`: every ref and the object it names.
    fn refList(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var count: usize = 0;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var listing = try refStore(&repo).list(c.gpa, c.io, "refs/");
            defer listing.deinit();
            count = 0;
            for (listing.entries) |entry| {
                switch (entry.target) {
                    .direct => |oid| std.mem.doNotOptimizeAway(&oid),
                    .symbolic => |target| {
                        const resolved = (try refStore(&repo).resolve(c.gpa, c.io, target)) orelse continue;
                        c.gpa.free(resolved.name);
                    },
                }
                count += 1;
            }
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "refs", count);
    }

    // ------------------------------------------------------------ database

    /// `git repack -a -d`: the pack and the loose objects into one pack,
    /// the old ones removed, with the reverse index git writes beside it.
    fn repack(c: Ctx) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const report = try repo.odb.repack(c.io, .{
            .pack = .{ .sync = .batch, .reverse_index = true },
            .remove_loose = true,
            .remove_packs = true,
        });
        const took = ms(c.io, start);
        const written = report.written orelse return error.NothingPacked;
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "objects", written.objects);
        emit(c.io, c.name, "pack_bytes", @floatFromInt(written.pack_bytes), "bytes");
    }

    /// `git verify-pack`: every object rehashed, every entry's CRC checked.
    fn verify(c: Ctx) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        const report = try repo.odb.verify(c.io);
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "objects", report.packed_objects + report.loose);
    }

    // ------------------------------------------------------------ worktree

    /// `git worktree add <dir> oldb` from a bare repository.
    fn worktreeAdd(c: Ctx) !void {
        const dest_path = c.extra orelse return error.MissingDestination;
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        try c.cwd.createDirPath(c.io, dest_path);
        var dest = try c.cwd.openDir(c.io, dest_path, .{ .iterate = true });
        defer dest.close(c.io);
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = real_buf[0..try c.cwd.realPathFile(c.io, dest_path, &real_buf)];
        var added = try relic.worktree.worktrees.add(c.gpa, c.io, repo.common_dir, "wt", dest, real, .{ .branch = "oldb" });
        defer {
            added.admin_dir.close(c.io);
            added.work_dir.close(c.io);
            c.gpa.free(added.name);
        }
        var linked = try Repository.open(c.gpa, c.io, dest, .{});
        defer linked.deinit(c.io);
        var r: Rules = undefined;
        try c.rules(&linked, &r);
        defer r.deinit();
        var index = try linked.openIndex(c.io);
        defer index.deinit();
        const tree = (try linked.headTree(c.io)).?;
        _ = try relic.worktree.checkout(c.gpa, c.io, dest, &index, &linked.odb, tree, .{ .rules = r.rules, .ignore = &r.ignore });
        try linked.writeIndex(c.io, &index);
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitOid(c.io, c.name, "tree", tree);
    }

    /// `git add -A` over files `.gitattributes` gives to LFS, through
    /// relic's own LFS: pointers in the index, contents in the store.
    fn lfsAdd(c: Ctx) !void {
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        var r: Rules = undefined;
        try c.rules(&repo, &r);
        defer r.deinit();
        var drivers = try repo.loadFilters(c.io, .{});
        defer drivers.deinit();
        r.rules.filters = &drivers;
        var index = try repo.openIndex(c.io);
        defer index.deinit();
        const outcome = try relic.worktree.addAll(c.gpa, c.io, repo.work_dir.?, &index, &repo.odb, .{ .rules = r.rules });
        try repo.writeIndex(c.io, &index);
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "added", outcome.added);
    }

    /// `git switch data`: the branch's LFS files smudged from the store.
    fn lfsCheckout(c: Ctx) !void {
        return c.switchTo("data", true);
    }

    fn submoduleStatus(c: Ctx) !void {
        var best: f64 = std.math.floatMax(f64);
        var count: usize = 0;
        for (0..reps) |_| {
            const start = benchmarkNow(c.io);
            var repo = try c.open();
            defer repo.deinit(c.io);
            var statuses = try relic.submodule.status(c.gpa, c.io, &repo, .{});
            defer statuses.deinit();
            count = statuses.entries.len;
            best = @min(best, ms(c.io, start));
        }
        emit(c.io, c.name, "time", best, "ms");
        emitCount(c.io, c.name, "submodules", count);
    }

    /// `git submodule update --init`: every submodule cloned from its local
    /// source and checked out at the recorded commit.
    fn submoduleUpdate(c: Ctx) !void {
        const environ = c.extra; // unused: programs come from the process
        _ = environ;
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        var transport: relic.submodule.submoduletransport.Transport = .init(.{ .who = who });
        defer transport.deinit();
        const outcome = try relic.submodule.update(c.gpa, c.io, &repo, .{ .init = true, .who = who, .transport = transport.transport() });
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitCount(c.io, c.name, "submodules", outcome.cloned);
    }

    /// A snapshot of the dirty working tree into a private store: like
    /// `git stash create`, an object name and the working tree untouched.
    fn snapshot(c: Ctx) !void {
        if (!@hasDecl(relic.worktree, "snapshot")) return unavailable(c.io, c.name, "this revision has no worktree.snapshot");
        const store_path = c.extra orelse return error.MissingStore;
        const start = benchmarkNow(c.io);
        var repo = try c.open();
        defer repo.deinit(c.io);
        try c.cwd.createDirPath(c.io, store_path);
        var store_dir = try c.cwd.openDir(c.io, store_path, .{});
        defer store_dir.close(c.io);
        var store = try relic.worktree.snapshot.Store.open(c.gpa, c.io, store_dir, .{ .kind = objectFormat(&repo) });
        defer store.deinit(c.io);
        const captured = try store.capture(c.io, .{ .repository = &repo }, .{});
        const took = ms(c.io, start);
        emit(c.io, c.name, "time", took, "ms");
        emitOid(c.io, c.name, "tree", captured.snapshot.tree);
    }
};

// The final API validates refreshed repository configuration.
fn worktreeRules(repo: *Repository) !relic.worktree.Rules {
    const result = repo.worktreeRules();
    return if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
}

// The final API takes a diagnostic output; the earlier one does not.
fn writeTag(repo: *Repository, io: Io, fields: relic.object.Tag.Fields) !Oid {
    if (@typeInfo(@TypeOf(Repository.writeTag)).@"fn".params.len == 4) return repo.writeTag(io, fields, null);
    return repo.writeTag(io, fields);
}

// The final API reaches the ref store through an accessor.
fn refStore(repo: *Repository) *relic.refs.Store {
    return if (@hasDecl(Repository, "refStore")) repo.refStore() else &repo.refs;
}

fn objectFormat(repo: *const Repository) relic.hash.Kind {
    return if (@hasDecl(Repository, "objectFormat")) repo.objectFormat() else repo.kind;
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
