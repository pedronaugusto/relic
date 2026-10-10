//! `core.fsync` and `core.fsyncMethod`, read from the repository's own
//! configuration and kept by every writer they name: what a received pack,
//! its index and a ref update sync, counted where airlock syncs.
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
/// and its reverse index) and a ref update then sync.
const Case = struct { fsync: ?[]const u8 = null, method: ?[]const u8 = null, object_files: bool = false, pack: u32, ref: u32 };

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
        .{ .pack = 3, .ref = 1 },
        // Set: read over git's default alone, which leaves references out.
        .{ .fsync = "pack", .pack = 3, .ref = 0 },
        .{ .fsync = "reference", .pack = 3, .ref = 1 },
        .{ .fsync = "-pack", .pack = 0, .ref = 0 },
        .{ .fsync = "-pack-metadata,reference", .pack = 1, .ref = 1 },
        .{ .fsync = "none", .pack = 0, .ref = 0 },
        .{ .fsync = "committed", .pack = 3, .ref = 1 },
        .{ .fsync = "all", .method = "writeout-only", .pack = 3, .ref = 1 },
        // Only loose objects are batched; the rest are synced one by one.
        .{ .fsync = "all", .method = "batch", .pack = 3, .ref = 1 },
        // Loose objects only, which a received pack has none of.
        .{ .fsync = "none", .object_files = true, .pack = 0, .ref = 0 },
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
        var reader: Io.Reader = .fixed(bytes);
        var received = try repo.objectDatabase().receivePack(fault_io, &reader, .{});
        defer received.deinit(fault_io);
        expectSyncs(case.pack, h.syncs() - before_pack, case) catch |err| return err;

        const before_ref = h.syncs();
        var tx = repo.refStore().begin(gpa);
        defer tx.deinit(fault_io);
        try tx.create("refs/heads/synced", .{ .direct = try Oid.parse(.sha1, head) });
        try tx.prepare(fault_io);
        try tx.commit(fault_io, null);
        expectSyncs(case.ref, h.syncs() - before_ref, case) catch |err| return err;
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
