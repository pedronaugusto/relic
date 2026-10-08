const std = @import("std");
const shakedown = @import("shakedown");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const snapshot = @import("snapshot.zig");
const repo = @import("../repo/repo.zig");
const odb = @import("../odb/odb.zig");
const object = @import("../object/object.zig");
const hash = @import("../hash/hash.zig");
const diff_mod = @import("../diff/diff.zig");
const fs = @import("../fs/fs.zig");
const lfs = @import("../lfs/lfs.zig");
const storage = @import("../odb/state.zig");
const testgit = @import("../testing/git.zig");

fn sourceObjects(dir: Io.Dir) ![:0]u8 {
    return dir.realPathFileAlloc(testing.io, ".git/objects", testing.allocator);
}

fn expectClosure(db: *odb.Odb, oid: hash.Oid) !void {
    try testing.expect(try db.existsOwn(testing.io, oid));
    const found = try db.read(testing.io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type == .tree) {
        var tree = object.Tree.parse(db.objectFormat(), found.bytes);
        var entries = tree.iterate();
        while (try entries.next()) |entry| {
            if (entry.mode != .gitlink) try expectClosure(db, entry.oid);
        }
    } else try testing.expectEqual(object.Type.blob, found.type);
}

fn expectFile(dir: Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

test "snapshot owns unchanged nested history before a rewrite and prune" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "unchanged/deep/file", "from history\n");
    try source.writeFile(io, "changed", "before\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "original" });
    try source.exec(io, &.{ "repack", "-ad" });
    const old_blob = try source.line(io, &.{ "rev-parse", "HEAD:unchanged/deep/file" });
    defer gpa.free(old_blob);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var first: snapshot.Snapshot = undefined;
    var second: snapshot.Snapshot = undefined;
    {
        var store = try snapshot.Store.open(gpa, io, private.dir, .{});
        defer store.deinit(io);
        first = (try store.capture(io, .{ .repository = &r }, .{})).snapshot;
        try source.writeFile(io, "changed", "after\n");
        try source.writeFile(io, "untracked", "new\n");
        second = (try store.capture(io, .{ .repository = &r }, .{})).snapshot;
    }
    // No rescue runs between the rewrite and collection. Prove the old
    // object has actually gone from the source rather than testing a grace period.
    try source.exec(io, &.{ "checkout", "--orphan", "rewritten" });
    try source.exec(io, &.{ "rm", "-rf", "." });
    try source.writeFile(io, "replacement", "new history\n");
    try source.exec(io, &.{ "add", "replacement" });
    try source.exec(io, &.{ "commit", "-qm", "replacement" });
    try source.exec(io, &.{ "reflog", "expire", "--expire=now", "--all" });
    try source.exec(io, &.{ "branch", "-D", "main" });
    try source.exec(io, &.{ "gc", "--prune=now" });
    source.report_failures = false;
    try testing.expectError(error.GitFailed, source.exec(io, &.{ "cat-file", "-e", old_blob }));
    source.report_failures = true;

    // Reopening discards every in-memory shortcut; only the private
    // source is registered, so restore and diff have no alternate reader.
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    try testing.expectEqual(@as(usize, 1), storage.get(store.db._state).sources.items.len);
    try expectClosure(&store.db, first.tree);
    try expectClosure(&store.db, second.tree);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, first, dest.dir, .{});
    try expectFile(dest.dir, "unchanged/deep/file", "from history\n");
    try expectFile(dest.dir, "changed", "before\n");
    _ = try store.restore(io, second, dest.dir, .{ .from = first });
    try expectFile(dest.dir, "changed", "after\n");
    try expectFile(dest.dir, "untracked", "new\n");
    var changes = try store.diff(io, first, second, .{});
    defer changes.deinit();
    try testing.expectEqual(@as(usize, 2), changes.items.len);
    try testing.expect(changes.find("unchanged/deep/file") == null);
    try testing.expect(changes.find("changed") != null);
    try testing.expect(changes.find("untracked") != null);
}

test "snapshot follows repository membership and current ignore and attribute rules without writing it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, ".gitignore", "*.ignored\n");
    try source.writeFile(io, ".gitattributes", "*.txt text eol=lf\n");
    try source.writeFile(io, "tracked.ignored", "tracked\n");
    try source.writeFile(io, "text.txt", "staged\n");
    try source.exec(io, &.{ "add", "-f", ".", "tracked.ignored" });
    try source.exec(io, &.{ "commit", "-qm", "base" });
    try source.exec(io, &.{ "update-index", "--assume-unchanged", "text.txt" });
    try source.writeFile(io, "text.txt", "working\r\n");
    try source.writeFile(io, "omit.ignored", "ignored\n");
    try source.writeFile(io, "sub/.gitignore", "omit\n");
    try source.writeFile(io, "sub/omit", "ignored too\n");
    try source.writeFile(io, "sub/new", "included\n");
    const index_before = try source.readFile(io, ".git/index");
    defer gpa.free(index_before);
    const counts_before = try source.run(io, &.{ "count-objects", "-v" });
    defer gpa.free(counts_before);
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const captured = try store.capture(io, .{ .repository = &r }, .{});
    try expectClosure(&store.db, captured.snapshot.tree);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    try expectFile(dest.dir, "tracked.ignored", "tracked\n");
    try expectFile(dest.dir, "text.txt", "working\n");
    try expectFile(dest.dir, "sub/new", "included\n");
    try testing.expectError(error.FileNotFound, dest.dir.access(io, "omit.ignored", .{}));
    try testing.expectError(error.FileNotFound, dest.dir.access(io, "sub/omit", .{}));
    const index_after = try source.readFile(io, ".git/index");
    defer gpa.free(index_after);
    try testing.expectEqualSlices(u8, index_before, index_after);
    const counts_after = try source.run(io, &.{ "count-objects", "-v" });
    defer gpa.free(counts_after);
    try testing.expectEqualStrings(counts_before, counts_after);
    // A previous untracked snapshot path does not become repository-tracked.
    try source.writeFile(io, "sub/.gitignore", "omit\nnew\n");
    const next = try store.capture(io, .{ .repository = &r }, .{});
    var changes = try store.diff(io, captured.snapshot, next.snapshot, .{});
    defer changes.deinit();
    try testing.expectEqual(diff_mod.Status.deleted, changes.find("sub/new").?.status);
}

test "snapshot captures a plain folder incrementally and restores additions deletions and modes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var folder = testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.createDirPath(io, "nested");
    try folder.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored\n" });
    try folder.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.txt text eol=lf\n" });
    try folder.dir.writeFile(io, .{ .sub_path = "nested/a.txt", .data = "a\r\n" });
    try folder.dir.writeFile(io, .{ .sub_path = "removed", .data = "gone\n" });
    try folder.dir.writeFile(io, .{ .sub_path = "ignored", .data = "no\n" });
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const first = (try store.capture(io, .{ .folder = folder.dir }, .{})).snapshot;
    try expectClosure(&store.db, first.tree);
    const written = store.db.stats.loose_written;
    const again = (try store.capture(io, .{ .folder = folder.dir }, .{})).snapshot;
    try testing.expect(first.tree.eql(again.tree));
    try testing.expectEqual(written, store.db.stats.loose_written);
    try folder.dir.deleteFile(io, "removed");
    try folder.dir.writeFile(io, .{ .sub_path = "added", .data = "new\n" });
    const second = (try store.capture(io, .{ .folder = folder.dir }, .{})).snapshot;
    // One new blob and the root. The unchanged nested tree is neither
    // copied nor written again.
    try testing.expectEqual(written + 2, store.db.stats.loose_written);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, first, dest.dir, .{});
    try expectFile(dest.dir, "nested/a.txt", "a\n");
    _ = try store.restore(io, second, dest.dir, .{ .from = first });
    try expectFile(dest.dir, "added", "new\n");
    try testing.expectError(error.FileNotFound, dest.dir.access(io, "removed", .{}));
    try dest.dir.writeFile(io, .{ .sub_path = "added", .data = "local\n" });
    try testing.expectError(error.LocalChangesWouldBeOverwritten, store.restore(io, first, dest.dir, .{ .from = second }));
    _ = try store.restore(io, first, dest.dir, .{ .from = second, .checkout = .{ .force = true } });
    var changes = try store.diff(io, first, second, .{});
    defer changes.deinit();
    try testing.expectEqual(@as(usize, 2), changes.items.len);
}

test "snapshot allocation failures leave no published result or lost owner" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "nested/file", "borrowed\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "base" });
    try source.exec(io, &.{ "repack", "-ad" });
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try testing.checkAllAllocationFailures(no_resize.allocator(), allocationCase, .{source.dir});
    }
}

fn allocationCase(gpa: std.mem.Allocator, source: Io.Dir) !void {
    const io = testing.io;
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    var r = try repo.Repository.open(gpa, io, source, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const captured = try store.capture(io, .{ .repository = &r }, .{});
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    var changes = try store.diff(io, null, captured.snapshot, .{});
    defer changes.deinit();
}

test "snapshot keeps native LFS writes inside the private store" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    const source_path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(source_path);
    const external = try std.Io.Dir.path.join(gpa, &.{ source_path, "external-lfs" });
    defer gpa.free(external);
    try source.exec(io, &.{ "config", "lfs.storage", external });
    try source.writeFile(io, ".gitattributes", "*.bin filter=lfs\n");
    try source.writeFile(io, "large.bin", "the LFS content\n");
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const captured = try store.capture(io, .{ .repository = &r }, .{ .native_provider = @import("../lfs/filter.zig").provider(&.{}) });
    try testing.expectError(error.FileNotFound, source.dir.access(io, "external-lfs", .{}));
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    const pointer_text = try dest.dir.readFileAlloc(io, "large.bin", gpa, .limited(1024));
    defer gpa.free(pointer_text);
    const pointer = try lfs.Pointer.decode(pointer_text);
    const payloads: lfs.Store = .{ .base = store.dir, .root = "lfs" };
    try testing.expect(try payloads.contains(io, &pointer));
}

test "snapshot plain folders keep executable modes symlinks and SHA256 names" {
    const gpa = testing.allocator;
    const io = testing.io;
    var folder = testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.writeFile(io, .{ .sub_path = "run", .data = "executable\n" });
    if (Io.File.Permissions.has_executable_bit) {
        const file = try folder.dir.openFile(io, "run", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    const symlink = if (builtin.target.os.tag != .windows) blk: {
        try folder.dir.symLink(io, "run", "link", .{});
        break :blk true;
    } else false;
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{ .kind = .sha256 });
    defer store.deinit(io);
    const captured = try store.capture(io, .{ .folder = folder.dir }, .{});
    try testing.expectEqual(hash.Kind.sha256, captured.snapshot.tree.kind);
    try expectClosure(&store.db, captured.snapshot.tree);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    try expectFile(dest.dir, "run", "executable\n");
    const executable = try dest.dir.openFile(io, "run", .{});
    defer executable.close(io);
    if (Io.File.Permissions.has_executable_bit) try testing.expect(fs.isExecutable((try executable.stat(io)).permissions));
    if (symlink) {
        var buf: [100]u8 = undefined;
        const len = try dest.dir.readLink(io, "link", &buf);
        try testing.expectEqualStrings("run", buf[0..len]);
    }
}

test "snapshot retains sparse tracked files absent from disk and captures present edits" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "included/file", "before\n");
    try source.writeFile(io, "excluded/deep/file", "sparse history\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "base" });
    try source.exec(io, &.{ "sparse-checkout", "init", "--cone", "--sparse-index" });
    try source.exec(io, &.{ "sparse-checkout", "set", "included" });
    try testing.expectError(error.FileNotFound, source.dir.access(io, "excluded/deep/file", .{}));
    try source.writeFile(io, "included/file", "after\n");
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const captured = try store.capture(io, .{ .repository = &r }, .{});
    try expectClosure(&store.db, captured.snapshot.tree);
    try testing.expectEqual(@as(usize, 1), storage.get(store.db._state).sources.items.len);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    try expectFile(dest.dir, "included/file", "after\n");
    try expectFile(dest.dir, "excluded/deep/file", "sparse history\n");
}

test "snapshot reopening does not depend on the source alternate metadata" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "file", "owned\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "base" });
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    try private.dir.createDirPath(io, "objects/info");
    // A legacy private store may still name the source as an alternate.
    // Opening a snapshot store must leave this unused metadata alone.
    const alternate = try sourceObjects(source.dir);
    defer gpa.free(alternate);
    try private.dir.writeFile(io, .{ .sub_path = "objects/info/alternates", .data = alternate });
    const saved = blk: {
        var store = try snapshot.Store.open(gpa, io, private.dir, .{});
        defer store.deinit(io);
        break :blk (try store.capture(io, .{ .repository = &r }, .{})).snapshot;
    };
    // The source's alternates now contain a cycle. Its metadata must not
    // gate opening the private objects of a completed snapshot.
    try source.writeFile(io, ".git/objects/info/alternates", ".\n");
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    try expectClosure(&store.db, saved.tree);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, saved, dest.dir, .{});
    try expectFile(dest.dir, "file", "owned\n");
}

test "a live snapshot store reads its own objects after source packs are damaged" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "file", "owned\n");
    // Larger than the pack reader's buffer: a restore cannot happen to
    // succeed because capture left the source's entire pack in memory.
    const uncached = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(uncached);
    var random = std.Random.DefaultPrng.init(0);
    random.random().bytes(uncached);
    try source.writeFile(io, "uncached", uncached);
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "base" });
    try source.exec(io, &.{ "repack", "-ad" });
    // Git makes its packs read-only. Replace the fixture pack with an
    // identical writable file before opening it, on every platform.
    {
        const packs = try source.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
        defer packs.close(io);
        var names = packs.iterate();
        var replaced = false;
        while (try names.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
            const bytes = try packs.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
            defer gpa.free(bytes);
            try packs.deleteFile(io, entry.name);
            try packs.writeFile(io, .{ .sub_path = entry.name, .data = bytes });
            replaced = true;
            break;
        }
        try testing.expect(replaced);
    }
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    try private.dir.createDirPath(io, "objects/info");
    const alternate = try sourceObjects(source.dir);
    defer gpa.free(alternate);
    try private.dir.writeFile(io, .{ .sub_path = "objects/info/alternates", .data = alternate });
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const saved = (try store.capture(io, .{ .repository = &r }, .{})).snapshot;
    const pack_name = storage.get(r.objectDatabase()._state).sources.items[0].packs.items[0].name;
    const path = try gpa.print(".git/objects/pack/{s}.pack", .{pack_name});
    defer gpa.free(path);
    try source.writeFile(io, path, "damaged\n");
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, saved, dest.dir, .{});
    try expectFile(dest.dir, "file", "owned\n");
    try expectFile(dest.dir, "uncached", uncached);
    var changes = try store.diff(io, null, saved, .{});
    defer changes.deinit();
    try testing.expectEqual(@as(usize, 2), changes.items.len);
}

const airlock_testing = @import("airlock.testing");

fn expectSyncOrder(h: *airlock_testing.Seam) !void {
    var trace_calls: [256]airlock_testing.Call = undefined;
    const calls = h.calls(&trace_calls);
    try testing.expect(calls.len < trace_calls.len);
    var directories_started = false;
    for (calls) |call| switch (call) {
        .sync_dir => directories_started = true,
        .sync_full, .sync_barrier, .sync_data, .sync_plain, .sync_writeout => try testing.expect(!directories_started),
        else => {},
    };
}

fn expectDirectorySyncs(h: *airlock_testing.Seam, expected: usize) !void {
    // Airlock retries Linux O_PATH descriptors after EBADF: the failed fsync
    // is recorded too, and each getfl identifies that recovery attempt.
    const recovered = if (builtin.os.tag == .linux) h.count(.getfl) else 0;
    try testing.expect(recovered <= expected);
    try testing.expectEqual(expected + recovered, h.count(.sync_dir));
}

fn resetSyncs(h: *airlock_testing.Seam) void {
    h.setPlan(&.{});
    h.reset();
}

test "durable snapshots sync their closure and restored files before directories and success" {
    const gpa = testing.allocator;
    const h = try airlock_testing.Seam.create(gpa, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var folder = testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.createDirPath(io, "nested/deep");
    try folder.dir.writeFile(io, .{ .sub_path = "nested/deep/file", .data = "kept" });
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var options: snapshot.OpenOptions = .{ .odb = .{ .probe_timestamp_resolution = false } };
    options.durability = .durable;
    var store = try snapshot.Store.open(gpa, io, private.dir, options);
    defer store.deinit(io);
    resetSyncs(h);
    const captured = try store.capture(io, .{ .folder = folder.dir }, .{});
    // Three trees and the blob; already present objects must be covered too.
    try testing.expectEqual(@as(usize, 4), h.syncs() - h.count(.sync_dir));
    try testing.expect(h.count(.sync_dir) >= 2);
    try expectSyncOrder(h);
    resetSyncs(h);
    _ = try store.capture(io, .{ .folder = folder.dir }, .{});
    try testing.expectEqual(@as(usize, 4), h.syncs() - h.count(.sync_dir));
    try expectSyncOrder(h);
    resetSyncs(h);
    _ = try store.adoptTree(io, &store.db, captured.snapshot.tree);
    try testing.expectEqual(@as(usize, 4), h.syncs() - h.count(.sync_dir));
    try expectSyncOrder(h);
    resetSyncs(h);
    h.setPlan(&.{airlock_testing.fail(airlock_testing.data_sync, 1, airlock_testing.io_error)});
    try testing.expectError(error.InputOutput, store.adoptTree(io, &store.db, captured.snapshot.tree));
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    resetSyncs(h);
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    try testing.expectEqual(@as(usize, 1), h.syncs() - h.count(.sync_dir));
    try expectDirectorySyncs(h, 3);
    try expectSyncOrder(h);
    try expectFile(dest.dir, "nested/deep/file", "kept");
    // The same barrier covers a stat-shortcut checkout's existing bytes.
    resetSyncs(h);
    _ = try store.restore(io, captured.snapshot, dest.dir, .{ .from = captured.snapshot });
    try testing.expectEqual(@as(usize, 1), h.syncs() - h.count(.sync_dir));
    try expectSyncOrder(h);
    resetSyncs(h);
    h.setPlan(&.{airlock_testing.fail(airlock_testing.data_sync, 1, airlock_testing.io_error)});
    try testing.expectError(error.InputOutput, store.restore(io, captured.snapshot, dest.dir, .{ .from = captured.snapshot }));
    resetSyncs(h);
    h.setPlan(&.{airlock_testing.fail(.sync_dir, 1, airlock_testing.io_error)});
    try testing.expectError(error.InputOutput, store.restore(io, captured.snapshot, dest.dir, .{ .from = captured.snapshot }));
    resetSyncs(h);
    h.setPlan(&.{airlock_testing.fail(airlock_testing.data_sync, 1, airlock_testing.io_error)});
    try testing.expectError(error.InputOutput, store.capture(io, .{ .folder = folder.dir }, .{}));
    resetSyncs(h);
}

test "selected object durability syncs a used pack and index once" {
    const gpa = testing.allocator;
    const base = testing.io;
    var folder = testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.writeFile(base, .{ .sub_path = "a", .data = "a" });
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, base, private.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer store.deinit(base);
    const saved = try store.capture(base, .{ .folder = folder.dir }, .{});
    // This unrelated object is packed too; durable roots need no refs.
    _ = try store.db.write(base, .blob, "unrelated");
    _ = try store.db.repack(base, .{});
    const h = try airlock_testing.Seam.create(gpa, base, .{});
    defer h.destroy();
    const io = h.io();
    resetSyncs(h);
    try store.db.makeDurable(io, &.{ saved.snapshot.tree, saved.snapshot.tree });
    try testing.expectEqual(@as(usize, 2), h.syncs() - h.count(.sync_dir));
    try expectDirectorySyncs(h, 2);
    try expectSyncOrder(h);
}

test "durable checkout covers unchanged files and surviving parents of deletions" {
    const gpa = testing.allocator;
    const base = testing.io;
    var folder = testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    try folder.dir.createDirPath(base, "old/deep");
    try folder.dir.writeFile(base, .{ .sub_path = "old/deep/remove", .data = "removed" });
    try folder.dir.writeFile(base, .{ .sub_path = "kept", .data = "kept" });
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, base, private.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer store.deinit(base);
    const before = try store.capture(base, .{ .folder = folder.dir }, .{});
    try folder.dir.deleteTree(base, "old");
    const after = try store.capture(base, .{ .folder = folder.dir }, .{});
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(base, before.snapshot, dest.dir, .{});
    const h = try airlock_testing.Seam.create(gpa, base, .{});
    defer h.destroy();
    const io = h.io();
    resetSyncs(h);
    const result = try store.restore(io, after.snapshot, dest.dir, .{ .from = before.snapshot, .checkout = .{ .durability = .durable } });
    try testing.expectEqual(@as(u32, 1), result.removed);
    try testing.expectEqual(@as(usize, 1), h.syncs() - h.count(.sync_dir));
    try testing.expectEqual(@as(usize, 1), h.count(.sync_dir));
    try expectSyncOrder(h);
    try testing.expectError(error.FileNotFound, dest.dir.access(base, "old", .{}));
}

test "snapshot adoption keeps a mixed tree after the source has moved on" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "nested/old", "retained history\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "old" });
    const text = try source.line(io, &.{ "rev-parse", "HEAD:nested" });
    defer gpa.free(text);
    const old_tree = try hash.Oid.parse(.sha1, text);
    // Advance both history and disk before migration; no capture can recover old.
    try source.writeFile(io, "nested/old", "current history\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "new" });
    try source.exec(io, &.{ "repack", "-ad" });
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var frame: snapshot.Snapshot = undefined;
    {
        var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
        defer r.deinit(io);
        var store = try snapshot.Store.open(gpa, io, private.dir, .{});
        defer store.deinit(io);
        const local = try store.db.write(io, .blob, "private edit\n");
        var root = object.Tree.Builder.init(gpa, .sha1);
        defer root.deinit();
        try root.add(.file, "private", local);
        try root.add(.tree, "nested", old_tree);
        const bytes = try root.build();
        defer gpa.free(bytes);
        const tree = try store.db.write(io, .tree, bytes);
        frame = try store.adoptTree(io, r.objectDatabase(), tree);
        try testing.expect(frame.tree.eql(tree));
        try expectClosure(&store.db, tree);
        const writes = store.db.stats.loose_written;
        _ = try store.adoptTree(io, r.objectDatabase(), tree);
        try testing.expectEqual(writes, store.db.stats.loose_written);
    }
    // Every old object may now disappear, and reopening must still restore it.
    try source.dir.deleteTree(io, ".git/objects");
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, frame, dest.dir, .{});
    try expectFile(dest.dir, "nested/old", "retained history\n");
    try expectFile(dest.dir, "private", "private edit\n");
}

test "snapshot adoption preserves refusals and allocation ownership" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const io = testing.io;
            var source = testing.tmpDir(.{ .iterate = true });
            defer source.cleanup();
            var from = try snapshot.Store.open(testing.allocator, io, source.dir, .{});
            defer from.deinit(io);
            const blob = try from.db.write(io, .blob, "content");
            var root = object.Tree.Builder.init(testing.allocator, .sha1);
            defer root.deinit();
            try root.add(.file, "a", blob);
            const bytes = try root.build();
            defer testing.allocator.free(bytes);
            const tree = try from.db.write(io, .tree, bytes);
            var private = testing.tmpDir(.{ .iterate = true });
            defer private.cleanup();
            var store = try snapshot.Store.open(gpa, io, private.dir, .{});
            defer store.deinit(io);
            try testing.expectError(error.ObjectFormatMismatch, store.adoptTree(io, &from.db, hash.Hasher.object(.sha256, "tree", "")));
            if (store.adoptTree(io, &from.db, blob)) |_| return error.TestUnexpectedResult else |err| {
                if (err == error.OutOfMemory) return err;
                try testing.expectEqual(error.UnexpectedObjectType, err);
            }
            const missing = hash.Hasher.object(.sha1, "tree", "missing");
            if (store.adoptTree(io, &from.db, missing)) |_| return error.TestUnexpectedResult else |err| {
                if (err == error.OutOfMemory) return err;
                try testing.expectEqual(error.ObjectNotFound, err);
            }
            const saved = try store.adoptTree(io, &from.db, tree);
            try testing.expect(saved.tree.eql(tree));
            try expectClosure(&store.db, tree);
        }
    };
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{});
    }
}

test "snapshot adoption refuses file entries that name trees" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_dir = testing.tmpDir(.{ .iterate = true });
    defer source_dir.cleanup();
    var source = try snapshot.Store.open(gpa, io, source_dir.dir, .{});
    defer source.deinit(io);
    const child = try source.db.write(io, .tree, "");
    var root = object.Tree.Builder.init(gpa, .sha1);
    defer root.deinit();
    try root.add(.file, "wrong", child);
    const bytes = try root.build();
    defer gpa.free(bytes);
    const tree = try source.db.write(io, .tree, bytes);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    try testing.expectError(error.UnexpectedObjectType, store.adoptTree(io, &source.db, tree));
    // Preexisting private children must be checked too, without a source read.
    _ = try store.db.write(io, .tree, "");
    try testing.expectError(error.UnexpectedObjectType, store.adoptTree(io, &source.db, tree));
    try testing.expect(!store.complete.contains(tree));
}

test "a large first capture goes into packs, and a small one after it stays loose" {
    const gpa = testing.allocator;
    const io = testing.io;
    var folder = testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    for (0..300) |i| {
        var path: [32]u8 = undefined;
        var text: [32]u8 = undefined;
        try folder.dir.createDirPath(io, try std.mem.print(&path, "d{d}", .{i % 7}));
        try folder.dir.writeFile(io, .{
            .sub_path = try std.mem.print(&path, "d{d}/f{d}", .{ i % 7, i }),
            .data = try std.mem.print(&text, "file {d}\n", .{i}),
        });
    }
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const first = (try store.capture(io, .{ .folder = folder.dir }, .{})).snapshot;
    try expectClosure(&store.db, first.tree);
    // A hundred loose blobs at most; the rest of the blobs and every tree
    // in packs.
    try testing.expect(store.db.stats.loose_written <= 100);
    try testing.expect(store.db.stats.packed_written >= 200 + 8);
    try testing.expectEqual(@as(usize, 2), store.db.packCount());

    try folder.dir.writeFile(io, .{ .sub_path = "d0/f0", .data = "changed\n" });
    const loose = store.db.stats.loose_written;
    const second = (try store.capture(io, .{ .folder = folder.dir }, .{})).snapshot;
    try expectClosure(&store.db, second.tree);
    // The changed blob, its tree and the root, loose; no pack more.
    try testing.expectEqual(loose + 3, store.db.stats.loose_written);
    try testing.expectEqual(@as(usize, 2), store.db.packCount());

    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, first, dest.dir, .{});
    try expectFile(dest.dir, "d0/f0", "file 0\n");
    try expectFile(dest.dir, "d5/f299", "file 299\n");
}
