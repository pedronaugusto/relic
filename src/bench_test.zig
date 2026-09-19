//! The benchmark is a test with a budget.
//!
//! A regression in the cache tree or in the stat shortcut is a red build
//! rather than a slow day. The absolute ceilings are loose, because a CI
//! runner is not a quiet machine; the ratios are not, because they are what
//! actually break when one of those two is lost.
//!
//! The numbers are printed under `--summary all`, so a run says what it
//! measured and not only that it passed.
//!
//! These two tests allocate from `std.heap.smp_allocator` rather than from
//! `std.testing.allocator`. Every other test in the suite uses the testing
//! allocator and so checks for leaks; this one is measuring, and the testing
//! allocator's bookkeeping is several times the cost of the work being
//! measured, which would make the numbers say nothing about a real caller.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const worktree = @import("worktree.zig");
const repo_mod = @import("repo.zig");
const ignore = @import("ignore.zig");
const attributes = @import("attributes.zig");

/// How many files the generated tree holds.
///
/// A Debug build runs the same code with every safety check on and is two
/// orders of magnitude slower at hashing, so it measures a smaller tree; the
/// ratios it checks are the same ones.
const file_count: usize = switch (builtin.mode) {
    .Debug => 300,
    else => 3000,
};

/// How many directories the files are spread over, which is what the cache
/// tree's work is proportional to.
const directory_count: usize = 60;

fn elapsedMs(io: Io, from: Io.Timestamp) f64 {
    const now = Io.Clock.awake.now(io);
    const nanoseconds: f64 = @floatFromInt(from.durationTo(now).toNanoseconds());
    return nanoseconds / std.time.ns_per_ms;
}

test "benchmark: add, write-tree and status stay inside the budget" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io, &.{});
    defer repo_git.deinit();

    // A shape like the one the numbers were measured on: a few thousand
    // small files over sixty directories.
    var content: [96]u8 = undefined;
    for (0..file_count) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "d{d}/f{d}.txt", .{ i % directory_count, i });
        const text = try std.fmt.bufPrint(&content, "file {d}\nsome contents that are not all the same\n", .{i});
        try repo_git.writeFile(io, path, text);
    }

    var repo = try repo_mod.Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    var rules = try repo.loadIgnore(io);
    defer rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var wt_rules = repo.worktreeRules();
    wt_rules.ignore = &rules;
    wt_rules.attrs = &attrs;

    var index = try repo.openIndex(io);
    defer index.deinit();

    const cold_start = Io.Clock.awake.now(io);
    const cold = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = wt_rules });
    const cold_add_ms = elapsedMs(io, cold_start);

    const cold_tree_start = Io.Clock.awake.now(io);
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    const cold_tree_ms = elapsedMs(io, cold_tree_start);

    try index.write(io, repo.git_dir, "index", .{});
    index.deinit();
    index = try repo.openIndex(io);

    const warm_start = Io.Clock.awake.now(io);
    const warm = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = wt_rules });
    const warm_add_ms = elapsedMs(io, warm_start);

    const warm_tree_start = Io.Clock.awake.now(io);
    const same_tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    const warm_tree_ms = elapsedMs(io, warm_tree_start);

    // A dirty tree: one file in ten changed, which is the shape a status
    // actually meets.
    for (0..file_count / 10) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "d{d}/f{d}.txt", .{ (i * 10) % directory_count, i * 10 });
        const text = try std.fmt.bufPrint(&content, "file {d} changed\n", .{i * 10});
        try repo_git.writeFile(io, path, text);
    }
    const status_start = Io.Clock.awake.now(io);
    var result = try worktree.status(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
        .rules = wt_rules,
        .head_tree = null,
    });
    defer result.deinit();
    const status_ms = elapsedMs(io, status_start);

    std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} files over {d} directories)
        \\    add -A       cold {d: >8.1} ms   warm {d: >8.1} ms
        \\    write-tree   cold {d: >8.1} ms   warm {d: >8.1} ms
        \\    status       dirty {d: >7.1} ms
        \\    hashed       cold {d: >8}      warm {d: >8}
        \\
    , .{
        @tagName(builtin.mode),
        file_count,
        directory_count,
        cold_add_ms,
        warm_add_ms,
        cold_tree_ms,
        warm_tree_ms,
        status_ms,
        cold.hashed,
        warm.hashed,
    });

    // The stat shortcut: a warm pass opens nothing.
    try std.testing.expectEqual(@as(u32, @intCast(file_count)), cold.hashed);
    try std.testing.expectEqual(@as(u32, 0), warm.hashed);
    try std.testing.expectEqual(@as(u32, @intCast(file_count)), warm.unchanged);

    // The cache tree: a warm write-tree writes no tree object at all, so it
    // is far faster than the cold one and gives the same name.
    try std.testing.expect(same_tree.eql(tree));
    try std.testing.expect(warm_tree_ms <= cold_tree_ms + 1.0);

    // The ratio that breaks when the stat shortcut is lost. A machine under
    // load moves the absolute numbers; it does not make a pass that hashed
    // nothing as slow as one that hashed every file. A Debug build spends
    // most of its time in safety checks rather than in hashing, so the
    // margin there is smaller and the count above is what carries the
    // property.
    const ratio: f64 = switch (builtin.mode) {
        .Debug => 1.2,
        else => 2.0,
    };
    try std.testing.expect(warm_add_ms * ratio < cold_add_ms + 1.0);

    // Loose ceilings, so a busy runner does not fail the build but a real
    // regression does.
    const budget_ms: f64 = switch (builtin.mode) {
        .Debug => 60_000,
        else => 20_000,
    };
    try std.testing.expect(cold_add_ms < budget_ms);
    try std.testing.expect(warm_add_ms < budget_ms);
    try std.testing.expect(status_ms < budget_ms);
    try std.testing.expect(result.entries.len >= file_count / 10);
}

test "benchmark: a packed object with a delta chain reads inside the budget" {
    const io = std.testing.io;
    const gpa = std.heap.smp_allocator;
    var repo_git = try testgit.Repo.init(gpa, io, &.{});
    defer repo_git.deinit();

    // A file that grows one line per commit gives the packer a deep chain.
    const rounds: usize = switch (builtin.mode) {
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
        try repo_git.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg, "c{d}", .{i}) });
    }
    try repo_git.exec(io, &.{ "gc", "-q", "--aggressive" });

    const git_dir = try repo_git.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var names = try db.listObjects(io);
    defer names.deinit(gpa);

    const start = Io.Clock.awake.now(io);
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
    const warm_start = Io.Clock.awake.now(io);
    var warm_it = names.keyIterator();
    while (warm_it.next()) |oid| {
        const found = try db.read(io, oid.*);
        gpa.free(found.bytes);
    }
    const warm_ms = elapsedMs(io, warm_start);

    std.debug.print(
        \\
        \\  relic benchmark ({s}, {d} packed objects, {d} bytes)
        \\    read all     cold {d: >8.1} ms   warm {d: >8.1} ms
        \\
    , .{ @tagName(builtin.mode), read_count, bytes, ms, warm_ms });

    try std.testing.expect(read_count > rounds);
    const budget_ms: f64 = switch (builtin.mode) {
        .Debug => 60_000,
        else => 20_000,
    };
    try std.testing.expect(ms < budget_ms);
}
