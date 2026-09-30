const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const snapshot = @import("snapshot.zig");
const repo = @import("repo.zig");
const odb = @import("odb.zig");
const object = @import("object.zig");
const hash = @import("hash.zig");
const testgit = @import("testgit.zig");

fn sourceObjects(dir: Io.Dir) ![:0]u8 {
    return dir.realPathFileAlloc(testing.io, ".git/objects", testing.allocator);
}

fn expectClosure(db: *odb.Odb, oid: hash.Oid) !void {
    try testing.expect(try db.existsOwn(testing.io, oid));
    const found = try db.read(testing.io, oid);
    defer db.gpa.free(found.bytes);
    if (found.type == .tree) {
        var tree = object.Tree.parse(db.kind, found.bytes);
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
    const alternate = try sourceObjects(source.dir);
    defer gpa.free(alternate);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var first: snapshot.Snapshot = undefined;
    var second: snapshot.Snapshot = undefined;
    {
        var store = try snapshot.Store.open(gpa, io, private.dir, .{ .alternate = alternate });
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

    // Reopening discards every in-memory shortcut; removing the alternate
    // proves restore and diff use the private store alone.
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    try store.db.removeAlternate(io, alternate);
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
    const alternate = try sourceObjects(source.dir);
    defer gpa.free(alternate);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{ .alternate = alternate });
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
    try testing.expectEqual(@import("diff.zig").Status.deleted, changes.find("sub/new").?.status);
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
    const alternate = try sourceObjects(source.dir);
    defer gpa.free(alternate);
    try testing.checkAllAllocationFailures(gpa, allocationCase, .{ source.dir, alternate });
}

fn allocationCase(gpa: std.mem.Allocator, source: Io.Dir, alternate: []const u8) !void {
    const io = testing.io;
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    var r = try repo.Repository.open(gpa, io, source, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var store = try snapshot.Store.open(gpa, io, private.dir, .{ .alternate = alternate });
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
    const external = try std.fs.path.join(gpa, &.{ source_path, "external-lfs" });
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
    const captured = try store.capture(io, .{ .repository = &r }, .{});
    try testing.expectError(error.FileNotFound, source.dir.access(io, "external-lfs", .{}));
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    const pointer_text = try dest.dir.readFileAlloc(io, "large.bin", gpa, .limited(1024));
    defer gpa.free(pointer_text);
    const lfs = @import("lfs.zig");
    const pointer = try lfs.Pointer.decode(pointer_text);
    const payloads = lfs.Store{ .base = store.dir, .root = "lfs" };
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
    const symlink = if (@import("builtin").os.tag != .windows) blk: {
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
    if (Io.File.Permissions.has_executable_bit) try testing.expect(@import("fs.zig").isExecutable((try executable.stat(io)).permissions));
    if (symlink) {
        var buf: [100]u8 = undefined;
        const len = try dest.dir.readLink(io, "link", &buf);
        try testing.expectEqualStrings("run", buf[0..len]);
    }
}
