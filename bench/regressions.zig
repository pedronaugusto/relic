//! Quiet-machine regression measurements: relic's own, against nothing else.
//!
//! Run only on a quiet machine. Ratios, speed limits and throughput are
//! measurements here; shared unit suites count work and compare results.
//! The production allocator keeps allocation checking out of these timings.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const smoke = @import("bench_options").smoke;

const relic = @import("relic");
const testgit = @import("scratchgit.zig");
const hash = relic.hash;
const odb_mod = relic.odb;
const worktree = relic.worktree;
const repo_mod = relic.repo;
const dirscan = relic.worktree.dirscan;

/// How many files the generated tree holds.
///
/// A Debug build runs the same code with every safety check on and is two
/// orders of magnitude slower at hashing, so it measures a smaller tree; the
/// ratios it checks are the same ones.
const file_count: usize = if (smoke) 30 else switch (builtin.optimize) {
    .Debug => 300,
    else => 3000,
};

/// How many directories the files are spread over, which is what the cache
/// tree's work is proportional to.
const directory_count: usize = if (smoke) 3 else 60;

fn elapsedMs(io: Io, from: Io.Timestamp) f64 {
    const now = benchmarkNow(io);
    const nanoseconds: f64 = @floatFromInt(from.durationTo(now).toNanoseconds());
    return nanoseconds / std.time.ns_per_ms;
}

/// The shortest of several passes, in milliseconds.
///
/// A single wall-clock pass measures the machine as much as the code. No pass
/// can take less time than the work itself, and every pass that was
/// interrupted took more, so the smallest of several is the rate the
/// processor gives and the ones above it are what else the runner was doing.
fn bestMs(io: Io, passes: usize, context: anytype, comptime pass: fn (@TypeOf(context)) void) f64 {
    var best: f64 = std.math.floatMax(f64);
    for (0..passes) |_| {
        const start = benchmarkNow(io);
        pass(context);
        best = @min(best, elapsedMs(io, start));
    }
    return best;
}

test "benchmark: add, write-tree and status stay inside the budget" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();

    // A shape like the one the numbers were measured on: a few thousand
    // small files over sixty directories.
    var content: [96]u8 = undefined;
    for (0..file_count) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.mem.print(&path_buf, "d{d}/f{d}.txt", .{ i % directory_count, i });
        const text = try std.mem.print(&content, "file {d}\nsome contents that are not all the same\n", .{i});
        try repo_git.writeFile(io, path, text);
    }

    var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    var rules = try repo.loadIgnore(io);
    defer rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var wt_rules = try repo.worktreeRules();
    wt_rules.ignore = &rules;
    wt_rules.attrs = &attrs;

    var index = try repo.openIndex(io);
    defer index.deinit();

    const cold_start = benchmarkNow(io);
    const cold = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = wt_rules });
    const cold_add_ms = elapsedMs(io, cold_start);
    const cold_stats = repo.odb.stats;

    const cold_tree_start = benchmarkNow(io);
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    const cold_tree_ms = elapsedMs(io, cold_tree_start);

    try index.write(io, repo.git_dir, "index", .{});
    index.deinit();
    index = try repo.openIndex(io);

    const warm_start = benchmarkNow(io);
    const warm = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = wt_rules });
    const warm_add_ms = elapsedMs(io, warm_start);

    const warm_tree_start = benchmarkNow(io);
    const same_tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    const warm_tree_ms = elapsedMs(io, warm_tree_start);

    // A dirty tree: one file in ten changed, which is the shape a status
    // actually meets.
    for (0..file_count / 10) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.mem.print(&path_buf, "d{d}/f{d}.txt", .{ (i * 10) % directory_count, i * 10 });
        const text = try std.mem.print(&content, "file {d} changed\n", .{i * 10});
        try repo_git.writeFile(io, path, text);
    }
    const status_start = benchmarkNow(io);
    var result = try worktree.status(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
        .rules = wt_rules,
        .head_tree = null,
    });
    defer result.deinit();
    const status_ms = elapsedMs(io, status_start);

    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} files over {d} directories)
        \\    walk {s}, timestamps to {d} ns
        \\    add -A       cold {d: >8.1} ms   warm {d: >8.1} ms
        \\    write-tree   cold {d: >8.1} ms   warm {d: >8.1} ms
        \\    status       dirty {d: >7.1} ms
        \\    hashed       cold {d: >8}      warm {d: >8}
        \\    objects written {d: >5}      fan-out directories made {d: >4}
        \\
    , .{
        @tagName(builtin.optimize),
        file_count,
        directory_count,
        dirscan.armFor(gpa, io, repo.work_dir.?),
        repo.odb.timestamp_resolution.ns,
        cold_add_ms,
        warm_add_ms,
        cold_tree_ms,
        warm_tree_ms,
        status_ms,
        cold.hashed,
        warm.hashed,
        cold_stats.loose_written,
        cold_stats.fan_out_created,
    });

    // What a cold pass costs the filesystem, which is the part of the number
    // above a busy runner cannot move. Every file is one object written, and
    // the fan-out directories are made once each rather than once per object:
    // two hundred and fifty-six is every directory that can exist, so this
    // bound holds whatever the tree looks like.
    try std.testing.expectEqual(@as(u64, file_count), cold_stats.loose_written);
    try std.testing.expect(cold_stats.fan_out_created <= 256);

    // The stat shortcut: a warm pass opens nothing.
    try std.testing.expectEqual(@as(u32, @intCast(file_count)), cold.hashed);
    try std.testing.expectEqual(@as(u32, 0), warm.hashed);
    try std.testing.expectEqual(@as(u32, @intCast(file_count)), warm.unchanged);

    // The cache tree: a warm write-tree writes no tree object at all, so it
    // is far faster than the cold one and gives the same name.
    try std.testing.expect(same_tree.eql(tree));
    if (!smoke) std.debug.print("speed condition warm_tree_ms <= cold_tree_ms + 1.0: {s}\n", .{if (warm_tree_ms <= cold_tree_ms + 1.0) "within" else "over"});

    // The ratio that breaks when the stat shortcut is lost. A machine under
    // load moves the absolute numbers; it does not make a pass that hashed
    // nothing as slow as one that hashed every file. A Debug build spends
    // most of its time in safety checks rather than in hashing, so the
    // margin there is smaller and the count above is what carries the
    // property.
    const ratio: f64 = switch (builtin.optimize) {
        .Debug => 1.2,
        else => 2.0,
    };
    if (!smoke) std.debug.print("speed condition warm_add_ms * ratio < cold_add_ms + 1.0: {s}\n", .{if (warm_add_ms * ratio < cold_add_ms + 1.0) "within" else "over"});

    // Loose ceilings, so a busy runner does not fail the build but a real
    // regression does.
    const budget_ms: f64 = switch (builtin.optimize) {
        .Debug => 60_000,
        else => 20_000,
    };
    if (!smoke) std.debug.print("speed condition cold_add_ms < budget_ms: {s}\n", .{if (cold_add_ms < budget_ms) "within" else "over"});
    if (!smoke) std.debug.print("speed condition warm_add_ms < budget_ms: {s}\n", .{if (warm_add_ms < budget_ms) "within" else "over"});
    if (!smoke) std.debug.print("speed condition status_ms < budget_ms: {s}\n", .{if (status_ms < budget_ms) "within" else "over"});
    try std.testing.expect(result.entries.len >= file_count / 10);
}

test "benchmark: a packed object with a delta chain reads inside the budget" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();

    // A file that grows one line per commit gives the packer a deep chain.
    const rounds: usize = if (smoke) 3 else switch (builtin.optimize) {
        .Debug => 40,
        else => 120,
    };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..rounds) |i| {
        try body.print(gpa, "line {d} of a file that keeps growing\n", .{i});
        try repo_git.writeFile(io, "grow.txt", body.items);
        try repo_git.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try repo_git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "c{d}", .{i}) });
    }
    try repo_git.exec(io, &.{ "gc", "-q", "--aggressive" });

    const git_dir = try repo_git.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var names = try db.listObjects(io);
    defer names.deinit(gpa);

    const start = benchmarkNow(io);
    var read_count: usize = 0;
    var bytes: usize = 0;
    var it = names.keyIterator();
    while (it.next()) |oid| {
        const found = try db.read(io, oid.*);
        defer gpa.free(found.bytes);
        bytes += found.bytes.len;
        read_count += 1;
    }
    const ms = elapsedMs(io, start);

    // A second pass over the same objects, with the delta base cache warm.
    const warm_start = benchmarkNow(io);
    var warm_it = names.keyIterator();
    while (warm_it.next()) |oid| {
        const found = try db.read(io, oid.*);
        gpa.free(found.bytes);
    }
    const warm_ms = elapsedMs(io, warm_start);

    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} packed objects, {d} bytes)
        \\    read all     cold {d: >8.1} ms   warm {d: >8.1} ms
        \\
    , .{ @tagName(builtin.optimize), read_count, bytes, ms, warm_ms });

    try std.testing.expect(read_count > rounds);
    const budget_ms: f64 = switch (builtin.optimize) {
        .Debug => 60_000,
        else => 20_000,
    };
    if (!smoke) std.debug.print("speed condition ms < budget_ms: {s}\n", .{if (ms < budget_ms) "within" else "over"});
}

test "benchmark: SHA-1 runs at the rate the processor's instructions give it" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;

    // Enough bytes that the measurement is the compression function and not
    // the call around it, and few enough that a Debug build still finishes.
    const bytes: usize = if (smoke) 1024 else switch (builtin.optimize) {
        .Debug => 4 * 1024 * 1024,
        else => 64 * 1024 * 1024,
    };
    const buf = try gpa.alloc(u8, bytes);
    defer gpa.free(buf);
    var prng: std.Random.DefaultPrng = .init(0x5ec0_0d1e);
    prng.random().bytes(buf);

    const gib: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);

    // Each rate below is the best of several passes and not one pass. The
    // same code hashing the same bytes twelve times in a row on one loaded
    // machine gave rates between 0.21 and 2.30 GiB/s; the fastest of them is
    // the only one that is about the processor.
    const passes: usize = if (smoke) 1 else 5;

    const Pass = struct {
        buf: []const u8,
        mine: hash.Oid = undefined,
        reference: [20]u8 = undefined,
        checked: hash.Oid = undefined,
        checked_attack: bool = false,

        /// relic's SHA-1, on whichever arm this processor turned out to have.
        fn relicSha1(p: *@This()) void {
            var h: hash.Hasher = .init(.sha1);
            h.update(p.buf);
            p.mine = h.final();
        }

        /// The library's SHA-1, which is the same eighty rounds relic falls
        /// back to, measured in the same run on the same machine.
        fn librarySha1(p: *@This()) void {
            std.crypto.hash.Sha1.hash(p.buf, &p.reference, .{});
        }

        /// SHA-256, which the library already has a hardware arm for, as the
        /// scale the SHA-1 number is read against.
        fn relicSha256(p: *@This()) void {
            var h: hash.Hasher = .init(.sha256);
            h.update(p.buf);
            _ = h.final();
        }

        /// And SHA-1 with the collision check, which is what turning it on
        /// costs.
        fn checkedSha1(p: *@This()) void {
            var h: hash.Hasher = .initOptions(.sha1, .{ .detect_collisions = true });
            h.update(p.buf);
            p.checked = h.final();
            p.checked_attack = h.collisionAttack();
        }
    };

    var pass: Pass = .{ .buf = buf };
    const mine_ms = bestMs(io, passes, &pass, Pass.relicSha1);
    const ref_ms = bestMs(io, passes, &pass, Pass.librarySha1);
    const sha256_ms = bestMs(io, passes, &pass, Pass.relicSha256);
    const checked_ms = bestMs(io, passes, &pass, Pass.checkedSha1);
    const mine_oid = pass.mine;
    const checked_oid = pass.checked;
    const reference = pass.reference;

    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} MiB hashed, SHA-1 arm: {s})
        \\    SHA-1        relic {d: >6.2} GiB/s   library {d: >6.2} GiB/s
        \\    SHA-1 checked {d: >5.2} GiB/s
        \\    SHA-256      {d: >6.2} GiB/s
        \\
    , .{
        @tagName(builtin.optimize),
        bytes / (1024 * 1024),
        @tagName(hash.Hasher.sha1Backend()),
        gib / (mine_ms / 1000.0),
        gib / (ref_ms / 1000.0),
        gib / (checked_ms / 1000.0),
        gib / (sha256_ms / 1000.0),
    });

    // The check does not change the name, and finds nothing in noise.
    try std.testing.expect(checked_oid.eql(mine_oid));
    try std.testing.expect(!pass.checked_attack);

    // The name is the name whichever arm produced it.
    try std.testing.expectEqualSlices(u8, &reference, mine_oid.raw());

    // How far ahead of the software rounds the hardware arm is, is reported
    // and not asserted. It is a property of the processor rather than of
    // this code, and the two arms are nowhere near each other: an Apple M3
    // Max puts the crypto extension 2.6 times ahead of the library's eighty
    // rounds, and a CI runner's SHA extensions were 1.3 times ahead of the
    // same rounds compiled for x86-64, because that is a processor whose
    // software SHA-1 is already fast. A floor that both would clear has to
    // sit low enough that an arm which had quietly become the software
    // rounds would clear it too, which is a guard that guards nothing.
    //
    // What the arm must do is produce the right digest, and that is the
    // assertion above: no runner can move it, and an arm that stopped
    // working fails it.
}

test "benchmark: a staging pass into a pack, and writing one" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;

    // The same tree staged twice: once as one loose object per blob, which
    // is what git writes, and once as one pack for the whole pass. The two
    // must produce the same tree, and the difference between them is the
    // two filesystem calls a loose object costs.
    var ms: [2]f64 = undefined;
    var trees: [2]hash.Oid = undefined;
    var packed_report: ?relic.odb.pack.WriteReport = null;

    for ([_]worktree.NewBlobs{ .loose, .pack }, 0..) |where, pass| {
        var repo_git = try testgit.Repo.init(gpa, io);
        defer repo_git.deinit();
        var content: [96]u8 = undefined;
        for (0..file_count) |i| {
            var path_buf: [64]u8 = undefined;
            const path = try std.mem.print(&path_buf, "d{d}/f{d}.txt", .{ i % directory_count, i });
            const text = try std.mem.print(&content, "file {d}\nsome contents that are not all the same\n", .{i});
            try repo_git.writeFile(io, path, text);
        }

        var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
        defer repo.deinit(io);
        var rules = try repo.loadIgnore(io);
        defer rules.deinit();
        var wt_rules = try repo.worktreeRules();
        wt_rules.ignore = &rules;
        var index = try repo.openIndex(io);
        defer index.deinit();

        const start = benchmarkNow(io);
        const outcome = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
            .rules = wt_rules,
            .new_blobs = where,
        });
        ms[pass] = elapsedMs(io, start);
        try std.testing.expectEqual(@as(u32, @intCast(file_count)), outcome.added);
        if (where == .pack) packed_report = outcome.pack;
        trees[pass] = try worktree.writeTree(gpa, io, &index, &repo.odb);
    }
    try std.testing.expect(trees[0].eql(trees[1]));
    try std.testing.expect(packed_report != null);

    // And writing a pack out of a repository that already has one commit's
    // worth of history, which is where the delta window earns its keep.
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();
    const rounds: usize = if (smoke) 3 else switch (builtin.optimize) {
        .Debug => 3,
        else => 6,
    };
    for (0..rounds) |round| {
        for (0..20) |i| {
            var path_buf: [64]u8 = undefined;
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(gpa);
            for (0..(round + 1) * 80) |line| try body.print(gpa, "file {d} line {d} of text\n", .{ i, line });
            try repo_git.writeFile(io, try std.mem.print(&path_buf, "src/f{d}.txt", .{i}), body.items);
        }
        try repo_git.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try repo_git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "c{d}", .{round}) });
    }

    const git_dir = try repo_git.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    // With the path hints the trees give, which is what puts two versions
    // of one file next to each other in the delta search.
    var collected = try db.collectLoose(io, .{});
    defer collected.deinit();
    var loose_bytes: u64 = 0;
    for (collected.entries) |entry| {
        const head = try db.readHeader(io, entry.oid);
        loose_bytes += head.size;
    }

    var pack_dir = try git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const whole_start = benchmarkNow(io);
    const whole = try db.writePack(io, pack_dir, collected.entries, .{ .delta = .none });
    const whole_ms = elapsedMs(io, whole_start);

    const delta_start = benchmarkNow(io);
    const deltified = try db.writePack(io, pack_dir, collected.entries, .{});
    const delta_ms = elapsedMs(io, delta_start);

    const seconds = @max(delta_ms, 0.001) / 1000.0;
    const megabytes = @as(f64, @floatFromInt(loose_bytes)) / (1024.0 * 1024.0);
    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} files staged, {d} objects packed)
        \\    add -A       loose {d: >8.1} ms   into a pack {d: >8.1} ms
        \\    write pack   whole {d: >8.1} ms   deltified {d: >8.1} ms
        \\                 {d: >8.0} objects/s  {d: >6.1} MiB/s in  {d: >5.1}% of the bytes
        \\    deltas       {d} of {d}, {d} bytes against {d} undeltified
        \\
    , .{
        @tagName(builtin.optimize),
        file_count,
        deltified.objects,
        ms[0],
        ms[1],
        whole_ms,
        delta_ms,
        @as(f64, @floatFromInt(deltified.objects)) / seconds,
        megabytes / seconds,
        100.0 * @as(f64, @floatFromInt(deltified.pack_bytes)) / @as(f64, @floatFromInt(whole.pack_bytes)),
        deltified.deltas,
        deltified.objects,
        deltified.pack_bytes,
        whole.pack_bytes,
    });

    // The window has to find something: these files are each other's
    // neighbours a few lines apart.
    try std.testing.expect(deltified.deltas > 0);
    // And what it finds has to be worth having.
    try std.testing.expect(deltified.pack_bytes < whole.pack_bytes);
    // A pack is one file where loose objects are one file each, so a staging
    // pass into a pack cannot be the slower of the two by any margin worth
    // the name. A ratio, because a busy runner moves both.
    if (!smoke) std.debug.print("speed condition ms[1] < ms[0] * 1.5 + 5.0: {s}\n", .{if (ms[1] < ms[0] * 1.5 + 5.0) "within" else "over"});

    const budget_ms: f64 = switch (builtin.optimize) {
        .Debug => 120_000,
        else => 40_000,
    };
    if (!smoke) std.debug.print("speed condition delta_ms < budget_ms: {s}\n", .{if (delta_ms < budget_ms) "within" else "over"});
    if (!smoke) std.debug.print("speed condition whole_ms < budget_ms: {s}\n", .{if (whole_ms < budget_ms) "within" else "over"});
}

/// Lines of the shape real ignore files hold: names, extensions, anchored
/// directories, globstars, brackets and negations.
const ignore_lines = [_][]const u8{
    "*.o",             "*.a",          "*.so",                "*.so.*",        "*.ko",
    "*.py[cod]",       "__pycache__/", "*.class",             "*.log",         "!keep.log",
    "/build/",         "/dist",        "out/",                "node_modules/", "**/vendor/*.tmp",
    "doc/**/*.html",   "*.sw[op]",     ".DS_Store",           "Thumbs.db",     "*~",
    "/coverage",       "*.gcda",       "*.gcno",              "tmp*/",         "[Bb]in/",
    "**/generated/**", "*.min.js",     "!vendor/keep.min.js", "cache-*",       "*.bak",
};

/// Lines of the shape real attribute files hold.
const attribute_lines = [_][]const u8{
    "* text=auto",                "*.c diff=cpp",         "*.h diff=cpp",                  "*.png binary",    "*.jpg binary",
    "*.sh eol=lf",                "*.bat eol=crlf",       "doc/** linguist-documentation", "vendor/** -diff", "*.min.js -diff",
    "[Mm]akefile whitespace=tab", "**/fixtures/** -text",
};

/// Paths of a tree several directories deep, of every kind the lines name.
fn rulePaths(gpa: std.mem.Allocator, count: usize) ![][]const u8 {
    const dirs = [_][]const u8{ "src", "src/net", "lib/core", "doc/api/v1", "vendor/pkg", "build", "test/fixtures/a", "tools" };
    const names = [_][]const u8{ "main.c", "util.h", "app.py", "x.pyc", "README.md", "logo.png", "keep.log", "run.log", "Makefile", "page.html", "lib.min.js", "a.o", "mod.ko", "data.json" };
    const paths = try gpa.alloc([]const u8, count);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(gpa, "{s}/d{d}/{s}", .{ dirs[i % dirs.len], i % 97, names[(i / dirs.len) % names.len] });
    return paths;
}

test "benchmark: ignore and attribute rules decide paths" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    const path_count: usize = if (smoke) 50 else switch (builtin.optimize) {
        .Debug => 5_000,
        else => 100_000,
    };
    const paths = try rulePaths(gpa, path_count);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
    var ignore_text: std.ArrayList(u8) = .empty;
    defer ignore_text.deinit(gpa);
    for (ignore_lines) |line| try ignore_text.print(gpa, "{s}\n", .{line});
    var attribute_text: std.ArrayList(u8) = .empty;
    defer attribute_text.deinit(gpa);
    for (attribute_lines) |line| try attribute_text.print(gpa, "{s}\n", .{line});
    // The root's file and one in every directory a walk enters, as a tree
    // with a `.gitignore` per package holds them.
    const levels = [_][]const u8{ "", "src", "lib/core", "vendor/pkg" };

    const Load = struct {
        text: []const u8,
        fn ignoreRules(l: @This()) void {
            var rules = worktree.ignore.Rules.init(std.heap.smp_allocator, false) catch unreachable;
            defer rules.deinit();
            for (levels, 0..) |base, depth| rules.addText(l.text, base, ".gitignore", @intCast(depth + 2)) catch unreachable;
        }
    };
    const load_ms = bestMs(io, 20, Load{ .text = ignore_text.items }, Load.ignoreRules);

    var rules = try worktree.ignore.Rules.init(gpa, false);
    defer rules.deinit();
    for (levels, 0..) |base, depth| try rules.addText(ignore_text.items, base, ".gitignore", @intCast(depth + 2));
    const Ask = struct {
        rules: *const worktree.ignore.Rules,
        paths: []const []const u8,
        fn all(a: @This()) void {
            var excluded: usize = 0;
            for (a.paths) |p| {
                if (a.rules.matchPath(p, false).excluded) excluded += 1;
            }
            std.mem.doNotOptimizeAway(excluded);
        }
    };
    const match_ms = bestMs(io, 5, Ask{ .rules = &rules, .paths = paths }, Ask.all);

    var attrs = try worktree.attributes.Attrs.init(gpa, false);
    defer attrs.deinit();
    try attrs.addText(attribute_text.items, "", ".gitattributes", 1);
    const Lookup = struct {
        attrs: *const worktree.attributes.Attrs,
        paths: []const []const u8,
        fn all(l: @This()) void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena.deinit();
            var found: usize = 0;
            for (l.paths) |p| {
                found += (l.attrs.lookup(arena.allocator(), p, false) catch unreachable).items.len;
                _ = arena.reset(.retain_capacity);
            }
            std.mem.doNotOptimizeAway(found);
        }
    };
    const lookup_ms = bestMs(io, 5, Lookup{ .attrs = &attrs, .paths = paths }, Lookup.all);

    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} ignore lines over {d} levels, {d} attribute lines, {d} paths)
        \\    ignore load  {d: >8.3} ms
        \\    ignore match {d: >8.1} ms   {d: >6.0} ns/path
        \\    attr lookup  {d: >8.1} ms   {d: >6.0} ns/path
        \\
    , .{
        @tagName(builtin.optimize), ignore_lines.len, levels.len,                                                          attribute_lines.len, path_count,
        load_ms,                    match_ms,         match_ms * std.time.ns_per_ms / @as(f64, @floatFromInt(path_count)), lookup_ms,           lookup_ms * std.time.ns_per_ms / @as(f64, @floatFromInt(path_count)),
    });
    try std.testing.expect(rules.matchPath("src/d1/a.o", false).excluded);
    try std.testing.expect(!rules.matchPath("src/d1/keep.log", false).excluded);
}

test "benchmark: status walks a tree with an ignore file in every directory" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();

    // A package tree: a root ignore file of the usual size, and one of a few
    // lines in every directory, over files tracked, untracked and ignored.
    const dirs: usize = if (smoke) 3 else 120;
    const files_per_dir: usize = if (smoke) 4 else 25;
    var root: std.ArrayList(u8) = .empty;
    defer root.deinit(gpa);
    for (ignore_lines) |line| try root.print(gpa, "{s}\n", .{line});
    try repo_git.writeFile(io, ".gitignore", root.items);
    const exts = [_][]const u8{ "c", "h", "o", "log", "py", "pyc", "tmp", "md" };
    for (0..dirs) |d| {
        var path_buf: [64]u8 = undefined;
        try repo_git.writeFile(io, try std.mem.print(&path_buf, "pkg{d}/.gitignore", .{d}), "*.tmp\n/local-*\n!keep.tmp\nscratch/\n[Gg]en*.c\n");
        for (0..files_per_dir) |f| {
            const path = try std.mem.print(&path_buf, "pkg{d}/sub{d}/f{d}.{s}", .{ d, f % 3, f, exts[f % exts.len] });
            try repo_git.writeFile(io, path, "x\n");
        }
    }
    try repo_git.exec(io, &.{ "add", "-A" });
    // Untracked files beside the tracked ones.
    for (0..dirs) |d| {
        var path_buf: [64]u8 = undefined;
        try repo_git.writeFile(io, try std.mem.print(&path_buf, "pkg{d}/new{d}.c", .{ d, d }), "y\n");
    }

    var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();

    const Pass = struct {
        repo: *repo_mod.Repository,
        index: *relic.index.Index,
        fn status(p: @This()) void {
            var rules = p.repo.loadIgnore(std.testing.io) catch unreachable;
            defer rules.deinit();
            var attrs = p.repo.loadAttrs(std.testing.io) catch unreachable;
            defer attrs.deinit();
            var wt_rules = p.repo.worktreeRules() catch unreachable;
            wt_rules.ignore = &rules;
            wt_rules.attrs = &attrs;
            var result = worktree.status(std.heap.smp_allocator, std.testing.io, p.repo.work_dir.?, p.index, &p.repo.odb, .{
                .rules = wt_rules,
                .head_tree = null,
            }) catch unreachable;
            defer result.deinit();
            std.mem.doNotOptimizeAway(result.entries.len);
        }
    };
    const status_ms = bestMs(io, if (smoke) 1 else 10, Pass{ .repo = &repo, .index = &index }, Pass.status);
    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, status over {d} directories with an ignore file each, {d} files)
        \\    status       {d: >8.2} ms
        \\
    , .{ @tagName(builtin.optimize), dirs, dirs * files_per_dir, status_ms });
}

test "benchmark: for-each-ref chooses among many refs by pattern" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();
    try repo_git.writeFile(io, "a", "a\n");
    try repo_git.exec(io, &.{ "add", "a" });
    try repo_git.exec(io, &.{ "commit", "-q", "-m", "a" });
    var hex_buf: [hash.max_hex_len]u8 = undefined;
    const head = blk: {
        var first = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
        defer first.deinit(io);
        const h = (try first.head(io)).?;
        gpa.free(h.name);
        break :blk h.oid.hex(&hex_buf);
    };

    // Branches and tags as a large project keeps them, packed.
    const ref_count: usize = if (smoke) 20 else 20_000;
    var packed_refs: std.ArrayList(u8) = .empty;
    defer packed_refs.deinit(gpa);
    try packed_refs.appendSlice(gpa, "# pack-refs with: peeled fully-peeled sorted \n");
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    const kinds = [_][]const u8{ "refs/heads/feature/", "refs/heads/fix/", "refs/remotes/origin/", "refs/tags/v" };
    for (0..ref_count) |i| try names.append(gpa, try std.fmt.allocPrint(gpa, "{s}{d}.{d}", .{ kinds[i % kinds.len], i / 100, i % 100 }));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f);
    for (names.items) |name| try packed_refs.print(gpa, "{s} {s}\n", .{ head, name });
    const git_dir = try repo_git.gitDir(io);
    defer git_dir.close(io);
    try git_dir.writeFile(io, .{ .sub_path = "packed-refs", .data = packed_refs.items });

    var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    const List = struct {
        repo: *repo_mod.Repository,
        fn pass(l: @This()) void {
            var sink: std.Io.Writer.Discarding = .init(&.{});
            relic.refs.filter.listRefs(std.heap.smp_allocator, std.testing.io, l.repo, .{
                .filter = .{ .patterns = &.{ "refs/heads/f*/1[0-9].*", "refs/tags/v*" }, .exclude = &.{"refs/tags/v1?.*"} },
                .format = "%(refname)",
            }, &sink.writer) catch unreachable;
            std.mem.doNotOptimizeAway(sink.count);
        }
    };
    const list_ms = bestMs(io, if (smoke) 1 else 10, List{ .repo = &repo }, List.pass);
    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, for-each-ref over {d} packed refs, two patterns and an exclusion)
        \\    list         {d: >8.2} ms
        \\
    , .{ @tagName(builtin.optimize), ref_count, list_ms });
}

/// A source file of `lines` lines, with every `stride`-th line changed by
/// `round`: the shape of a file a history edits a little at a time.
fn editedText(gpa: std.mem.Allocator, lines: usize, stride: usize, round: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..lines) |i| {
        if (i % 40 == 0) try out.print(gpa, "fn section_{d}() void {{\n", .{i / 40});
        if (stride != 0 and (i + round) % stride == 0) {
            try out.print(gpa, "    value_{d} = compute({d}, {d});\n", .{ i, i, round });
        } else {
            try out.print(gpa, "    value_{d} = compute({d});\n", .{ i, i });
        }
        if (i % 40 == 39) try out.appendSlice(gpa, "}\n");
    }
    return out.toOwnedSlice(gpa);
}

test "benchmark: unified bodies, line counts and content merges of many files" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    const files: usize = if (smoke) 4 else switch (builtin.optimize) {
        .Debug => 40,
        else => 400,
    };
    const Pair = struct { old: []u8, new: []u8, theirs: []u8 };
    const pairs = try gpa.alloc(Pair, files);
    defer {
        for (pairs) |p| {
            gpa.free(p.old);
            gpa.free(p.new);
            gpa.free(p.theirs);
        }
        gpa.free(pairs);
    }
    for (pairs, 0..) |*p, i| p.* = .{
        .old = try editedText(gpa, 300 + i % 200, 0, 0),
        .new = try editedText(gpa, 300 + i % 200, 17 + i % 5, 1),
        .theirs = try editedText(gpa, 300 + i % 200, 23 + i % 7, 2),
    };

    const Work = struct {
        pairs: []const Pair,
        fn bodies(w: @This()) void {
            var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
            defer out.deinit();
            for (w.pairs) |p| {
                relic.diff.unifiedBody(std.heap.smp_allocator, &out.writer, p.old, p.new, .{}) catch unreachable;
                out.clearRetainingCapacity();
            }
        }
        fn counts(w: @This()) void {
            var lines: usize = 0;
            for (w.pairs) |p| {
                const n = relic.diff.blobNumStat(std.heap.smp_allocator, p.old, p.new, .{}) catch unreachable;
                lines += n.plus + n.minus;
            }
            std.mem.doNotOptimizeAway(lines);
        }
        fn merges(w: @This()) void {
            var conflicts: usize = 0;
            for (w.pairs) |p| {
                var r = relic.merge.blobs(std.heap.smp_allocator, p.old, p.new, p.theirs, .{ .algorithm = .histogram }) catch unreachable;
                if (!r.isClean()) conflicts += 1;
                r.deinit();
            }
            std.mem.doNotOptimizeAway(conflicts);
        }
    };
    const work: Work = .{ .pairs = pairs };
    const passes: usize = if (smoke) 1 else 7;
    const bodies_ms = bestMs(io, passes, work, Work.bodies);
    const counts_ms = bestMs(io, passes, work, Work.counts);
    const merges_ms = bestMs(io, passes, work, Work.merges);
    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} files of 300 to 500 lines, a few lines changed on each side)
        \\    unified      {d: >8.2} ms
        \\    numstat      {d: >8.2} ms
        \\    merge        {d: >8.2} ms
        \\
    , .{ @tagName(builtin.optimize), files, bodies_ms, counts_ms, merges_ms });
}

test "benchmark: blame follows a file through a long history" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();
    const rounds: usize = if (smoke) 3 else switch (builtin.optimize) {
        .Debug => 40,
        else => 200,
    };
    for (0..rounds) |round| {
        const text = try editedText(gpa, 2000, 97, round);
        defer gpa.free(text);
        try repo_git.writeFile(io, "file.zig", text);
        try repo_git.exec(io, &.{ "add", "file.zig" });
        var msg: [32]u8 = undefined;
        try repo_git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "r{d}", .{round}) });
    }
    var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    const Pass = struct {
        repo: *repo_mod.Repository,
        commit: hash.Oid,
        fn blame(p: @This()) void {
            var b = relic.diff.blame.file(std.heap.smp_allocator, std.testing.io, &p.repo.odb, p.commit, "file.zig", .{}) catch unreachable;
            std.mem.doNotOptimizeAway(b.hunks.len);
            b.deinit();
        }
    };
    const blame_ms = bestMs(io, if (smoke) 1 else 5, Pass{ .repo = &repo, .commit = head.oid }, Pass.blame);
    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, blame of a 2,000-line file through {d} commits)
        \\    blame        {d: >8.2} ms
        \\
    , .{ @tagName(builtin.optimize), rounds, blame_ms });
}

/// A smart HTTP server on loopback that answers from memory: the same
/// advertisement to every `GET`, the same answer to every `POST`, on a
/// kept connection. What is timed is the client.
const CannedServer = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    answer: []const u8,
    mode: enum { smart, lfs },
    oid: [64]u8 = undefined,
    task: Io.Future(void) = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    const advertisement = "001e# service=git-upload-pack\n0000" ++ "0000";

    fn start(io: Io, answer: []const u8, mode: @FieldType(CannedServer, "mode")) !*CannedServer {
        const s = try std.heap.smp_allocator.create(CannedServer);
        errdefer std.heap.smp_allocator.destroy(s);
        var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        s.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort(), .answer = answer, .mode = mode };
        if (mode == .lfs) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(answer, &digest, .{});
            s.oid = std.fmt.bytesToHex(digest, .lower);
        }
        s.task = try io.concurrent(serve, .{s});
        return s;
    }

    fn stop(s: *CannedServer) void {
        // The accept is woken by a connection of the server's own.
        s.stopping.store(true, .release);
        const address = Io.net.IpAddress.parse("127.0.0.1", s.port) catch unreachable; // unreachable: a literal address
        if (address.connect(s.io, .{ .mode = .stream })) |stream| stream.close(s.io) else |_| {}
        s.task.await(s.io);
        s.listener.deinit(s.io);
        std.heap.smp_allocator.destroy(s);
    }

    /// One client at a time, as the bench has.
    fn serve(s: *CannedServer) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            defer stream.close(s.io);
            if (s.stopping.load(.acquire)) return;
            s.handle(stream) catch {};
        }
    }

    fn handle(s: *CannedServer, stream: Io.net.Stream) !void {
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(s.io, &read_buffer);
        var writer = stream.writer(s.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        while (true) {
            var request = try server.receiveHead();
            if (s.mode == .lfs) {
                if (request.head.method == .GET) {
                    try request.respond(s.answer, .{ .keep_alive = false });
                } else {
                    var body_buffer: [4096]u8 = undefined;
                    _ = try (try request.readerExpectContinue(&body_buffer)).discardRemaining();
                    const batch = try std.heap.smp_allocator.print(
                        "{{\"objects\":[{{\"oid\":\"{s}\",\"size\":{d},\"actions\":{{\"download\":{{\"href\":\"http://127.0.0.1:{d}/object\"}}}}}}]}}",
                        .{ &s.oid, s.answer.len, s.port },
                    );
                    defer std.heap.smp_allocator.free(batch);
                    try request.respond(batch, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/vnd.git-lfs+json" }} });
                }
                return;
            }
            if (request.head.method == .GET) {
                try request.respond(advertisement, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/x-git-upload-pack-advertisement" }} });
                continue;
            }
            var body_buffer: [4096]u8 = undefined;
            _ = try (try request.readerExpectContinue(&body_buffer)).discardRemaining();
            try request.respond(s.answer, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/x-git-upload-pack-result" }} });
        }
    }
};

/// An upload-pack answer carrying `size` bytes of pack on side-band 1, in
/// git's largest packets.
fn sidebandAnswer(gpa: std.mem.Allocator, size: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "0008NAK\n");
    const chunk = 65515;
    var left = size;
    while (left > 0) {
        const n = @min(left, chunk);
        try out.print(gpa, "{x:0>4}\x01", .{n + 5});
        try out.appendNTimes(gpa, 'P', n);
        left -= n;
    }
    try out.appendSlice(gpa, "0000");
    return out.toOwnedSlice(gpa);
}

/// Send a request on `conn` and read its answer's pkt-lines to the flush:
/// the bytes they carried.
fn exchange(conn: *relic.transport.connection.Connection) !usize {
    const w = try conn.request();
    try w.writeAll("0032want 0000000000000000000000000000000000000000\n00000009done\n");
    const r = try conn.response();
    var carried: usize = 0;
    while (true) switch (try conn.readPacket(r)) {
        .data => |d| carried += d.len,
        .flush => return carried,
        .delim, .response_end => {},
    };
}

test "benchmark: smart HTTP carries a large answer, and many small ones, over one connection" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    const size: usize = if (smoke) 1 << 20 else 256 << 20;
    const big = try sidebandAnswer(gpa, size);
    defer gpa.free(big);
    var timings: [2]f64 = undefined;
    for ([_][]const u8{ big, "0008NAK\n0000" }, 0..) |answer, row| {
        const server = try CannedServer.start(io, answer, .smart);
        defer server.stop();
        var url_buf: [64]u8 = undefined;
        const url = try relic.transport.url.Url.parse(try std.mem.print(&url_buf, "http://127.0.0.1:{d}/repo.git", .{server.port}));
        const conn = try relic.transport.smarthttp.connect(gpa, io, url, .upload_pack, .{ .protocol_v2 = false });
        defer conn.close(io);
        const Pass = struct {
            conn: *relic.transport.connection.Connection,
            rounds: usize,
            fn run(p: @This()) void {
                for (0..p.rounds) |_| std.mem.doNotOptimizeAway(exchange(p.conn) catch unreachable);
            }
        };
        const rounds: usize = if (row == 0) 1 else if (smoke) 10 else 20_000;
        timings[row] = bestMs(io, if (smoke) 1 else 5, Pass{ .conn = conn, .rounds = rounds }, Pass.run);
    }
    if (!smoke) std.debug.print(
        \\
        \\  relic benchmark ({s}, smart HTTP on loopback, one kept connection)
        \\    {d} MiB answer   {d: >8.1} MB/s
        \\    small exchanges  {d: >8.0} per second
        \\
    , .{ @tagName(builtin.optimize), size >> 20, @as(f64, @floatFromInt(size)) / 1e6 / (timings[0] / 1000), 20_000 / (timings[1] / 1000) });
}

test "benchmark: LFS downloads hash and store a large object" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    const size: usize = if (smoke) 1 << 20 else 256 << 20;
    const content = try gpa.alloc(u8, size);
    defer gpa.free(content);
    @memset(content, 'L');
    const server = try CannedServer.start(io, content, .lfs);
    defer server.stop();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const objects = [_]relic.lfs.lfstransfer.Object{.{ .oid = std.fmt.bytesToHex(digest, .lower), .size = size }};
    var repo_git = try testgit.Repo.init(gpa, io);
    defer repo_git.deinit();
    const url = try gpa.print("http://127.0.0.1:{d}/repo.git", .{server.port});
    defer gpa.free(url);
    try repo_git.exec(io, &.{ "remote", "add", "origin", url });
    var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    const lfs_server = try relic.lfs.lfsapi.Server.open(gpa, io, &repo, "origin", .{});
    defer lfs_server.close();
    const Pass = struct {
        server: *relic.lfs.lfsapi.Server,
        dir: Io.Dir,
        io: Io,
        objects: []const relic.lfs.lfstransfer.Object,
        fn run(p: @This()) void {
            p.dir.deleteTree(p.io, ".git/lfs/objects") catch unreachable;
            var outcome = relic.lfs.lfstransfer.download(p.server, p.objects, .{ .concurrency = 1 }) catch unreachable;
            defer outcome.deinit();
            std.debug.assert(outcome.failures() == 0);
            std.debug.assert(outcome.results[0].status == .transferred);
        }
    };
    const ms = bestMs(io, if (smoke) 1 else 5, Pass{ .server = lfs_server, .dir = repo_git.dir, .io = io, .objects = &objects }, Pass.run);
    if (!smoke) std.debug.print("\n  relic benchmark ({s}, LFS download, SHA-256 and store)\n    {d} MiB object {d:.1} MB/s\n", .{ @tagName(builtin.optimize), size >> 20, @as(f64, @floatFromInt(size)) / 1e6 / (ms / 1000) });
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
