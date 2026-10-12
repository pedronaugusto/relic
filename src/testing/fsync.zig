//! `core.fsync` and `core.fsyncMethod`, read from the repository's own
//! configuration and kept by every writer they name: what a received pack,
//! its index, a repack and a ref update sync, counted where airlock syncs.
const std = @import("std");
const seam = @import("airlock.testing");
const testing = std.testing;
const Io = std.Io;
const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const Oid = hash.Oid;

/// A configuration, and how many files a received pack (the pack, its index
/// and its reverse index) syncs, whether it syncs the directory its names
/// land in, and how many syncs a ref update then makes.
const Case = struct { fsync: ?[]const u8 = null, method: ?[]const u8 = null, object_files: bool = false, pack: u32, pack_dir: u32, ref: u32 };

test "a received pack, its indexes and a ref update are synced as core.fsync says, and not otherwise" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "a", "synced\n");
    try source.exec(io, &.{ "add", "a" });
    try source.exec(io, &.{ "commit", "-qm", "synced" });
    const head = try source.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const bytes = try source.run(io, &.{ "pack-objects", "--all", "--stdout" });
    defer gpa.free(bytes);

    for ([_]Case{
        // Unset: git's default, and the references besides.
        .{ .pack = 3, .pack_dir = 1, .ref = 1 },
        // Set: read over git's default alone, which leaves references out.
        .{ .fsync = "pack", .pack = 3, .pack_dir = 1, .ref = 0 },
        .{ .fsync = "reference", .pack = 3, .pack_dir = 1, .ref = 1 },
        .{ .fsync = "-pack", .pack = 0, .pack_dir = 0, .ref = 0 },
        .{ .fsync = "-pack-metadata,reference", .pack = 1, .pack_dir = 1, .ref = 1 },
        .{ .fsync = "none", .pack = 0, .pack_dir = 0, .ref = 0 },
        .{ .fsync = "committed", .pack = 3, .pack_dir = 1, .ref = 1 },
        .{ .fsync = "all", .method = "writeout-only", .pack = 3, .pack_dir = 1, .ref = 1 },
        // Only loose objects are batched; the rest are synced one by one.
        .{ .fsync = "all", .method = "batch", .pack = 3, .pack_dir = 1, .ref = 1 },
        // Loose objects only, which a received pack has none of.
        .{ .fsync = "none", .object_files = true, .pack = 0, .pack_dir = 0, .ref = 0 },
    }) |case| {
        var target = try testgit.Repo.init(gpa, io, &.{"--bare"});
        defer target.deinit();
        if (case.fsync) |value| try target.exec(io, &.{ "config", "core.fsync", value });
        if (case.method) |value| try target.exec(io, &.{ "config", "core.fsyncMethod", value });
        if (case.object_files) try target.exec(io, &.{ "config", "core.fsyncObjectFiles", "true" });

        const h = try seam.Seam.create(gpa, io, .{});
        defer h.destroy();
        const fault_io = h.io();
        var repo = try repo_mod.Repository.open(gpa, fault_io, target.dir, .{});
        defer repo.deinit(fault_io);

        const before_pack = h.syncs();
        const before_dir = h.count(.sync_dir);
        var reader: Io.Reader = .fixed(bytes);
        var received = try repo.objectDatabase().receivePack(fault_io, &reader, .{});
        defer received.deinit(fault_io);
        const dir_syncs = h.count(.sync_dir) - before_dir;
        expectSyncs(case.pack, h.syncs() - before_pack - dir_syncs, case) catch |err| return err;
        expectSyncs(case.pack_dir, dir_syncs, case) catch |err| return err;

        const before_ref = h.syncs();
        var tx = repo.refStore().begin(gpa);
        defer tx.deinit(fault_io);
        try tx.create("refs/heads/synced", .{ .direct = try Oid.parse(.sha1, head) });
        try tx.prepare(fault_io);
        try tx.commit(fault_io, null);
        expectSyncs(case.ref, h.syncs() - before_ref, case) catch |err| return err;
    }
}

test "a repack syncs the directory its pack lands in before the loose objects go, as core.fsync says" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]Case{
        .{ .pack = 3, .pack_dir = 1, .ref = 0 },
        .{ .fsync = "-pack", .pack = 0, .pack_dir = 0, .ref = 0 },
    }) |case| {
        var target = try testgit.Repo.init(gpa, io, &.{});
        defer target.deinit();
        try target.writeFile(io, "a", "loose\n");
        try target.exec(io, &.{ "add", "a" });
        try target.exec(io, &.{ "commit", "-qm", "loose" });
        if (case.fsync) |value| try target.exec(io, &.{ "config", "core.fsync", value });

        const h = try seam.Seam.create(gpa, io, .{});
        defer h.destroy();
        const fault_io = h.io();
        var repo = try repo_mod.Repository.open(gpa, fault_io, target.dir, .{});
        defer repo.deinit(fault_io);

        const before_dir = h.count(.sync_dir);
        const report = try repo.objectDatabase().repack(fault_io, .{});
        try testing.expectEqual(@as(u32, 3), report.loose_removed);
        expectSyncs(case.pack_dir, h.count(.sync_dir) - before_dir, case) catch |err| return err;
    }
}

fn expectSyncs(want: u32, got: u32, case: Case) !void {
    if (want == got) return;
    std.debug.print("core.fsync={?s} core.fsyncMethod={?s}: {d} syncs, wanted {d}\n", .{ case.fsync, case.method, got, want });
    return error.TestUnexpectedResult;
}

test "a refreshed configuration changes what is synced" {
    const gpa = testing.allocator;
    const io = testing.io;
    var target = try testgit.Repo.init(gpa, io, &.{});
    defer target.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
    defer repo.deinit(io);
    try testing.expectEqual(fs.Sync.per_file, repo.indexLock().sync);
    try testing.expectEqual(fs.Sync.per_file, repo.refStore().referenceSync());
    try target.exec(io, &.{ "config", "core.fsync", "loose-object" });
    try target.exec(io, &.{ "config", "core.fsyncMethod", "batch" });
    _ = try repo.refreshConfig(io, null);
    try testing.expectEqual(fs.Sync.none, repo.indexLock().sync);
    try testing.expectEqual(fs.Sync.none, repo.refStore().referenceSync());
    try testing.expectEqual(fs.Sync.batch, repo.objectDatabase().settings().fsync.sync(.loose_object));
    try testing.expectEqual(fs.Sync.per_file, repo.objectDatabase().settings().fsync.sync(.pack));
}

test "core.fsyncObjectFiles syncs loose objects by the method, batched only where core.fsync names them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var target = try testgit.Repo.init(gpa, io, &.{});
    defer target.deinit();
    try target.exec(io, &.{ "config", "core.fsyncObjectFiles", "true" });
    var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
    defer repo.deinit(io);
    for ([_]struct { []const u8, ?[]const u8, fs.Sync }{
        .{ "fsync", null, .per_file },
        .{ "writeout-only", null, .ordered },
        // git's fsync_or_die flushes the hardware under batch.
        .{ "batch", null, .per_file },
        .{ "batch", "loose-object", .batch },
    }) |case| {
        const method, const components, const want = case;
        try target.exec(io, &.{ "config", "core.fsyncMethod", method });
        if (components) |value| try target.exec(io, &.{ "config", "core.fsync", value });
        _ = try repo.refreshConfig(io, null);
        try testing.expectEqual(want, repo.objectDatabase().settings().fsync.sync(.loose_object));
    }
}

test "a refreshed core.sharedRepository reaches every writer" {
    const gpa = testing.allocator;
    const io = testing.io;
    var target = try testgit.Repo.init(gpa, io, &.{});
    defer target.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
    defer repo.deinit(io);
    try testing.expectEqual(fs.Shared.umask, repo.sharedPermissions());
    try target.exec(io, &.{ "config", "core.sharedRepository", "group" });
    _ = try repo.refreshConfig(io, null);
    try testing.expectEqual(fs.Shared.group, repo.sharedPermissions());
    try testing.expectEqual(fs.Shared.group, repo.refStore().sharedPermissions());
    try testing.expectEqual(fs.Shared.group, repo.objectDatabase().sharedPermissions());
    try testing.expectEqual(fs.Shared.group, repo.indexLock().shared);
}
