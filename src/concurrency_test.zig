//! What happens when something else is writing the same repository.
//!
//! Two of these spawn a second process, because a lock is a thing between
//! processes and a single-process test of one proves nothing.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const fs = @import("fs.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const worktree = @import("worktree.zig");
const repo_mod = @import("repo.zig");
const reflog = @import("reflog.zig");

const Oid = hash.Oid;

/// The helper's path, compiled in by `build.zig`.
const lock_helper_path: []const u8 = if (@hasDecl(@import("root"), "dummy"))
    ""
else
    @import("build_options").lock_helper_path;

/// Run the helper, which takes a lock and holds it until its standard input
/// closes.
const Holder = struct {
    child: std.process.Child,
    released: bool = false,

    fn start(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, lock_path: []const u8) !Holder {
        _ = gpa;
        var child = try std.process.spawn(io, .{
            .argv = &.{ lock_helper_path, lock_path },
            .cwd = .{ .dir = dir },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        // Wait for the `held` line, so the lock is certainly on the disk
        // before the test tries to take it.
        var buf: [16]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buf);
        _ = reader.interface.takeDelimiterExclusive('\n') catch {
            child.kill(io);
            return error.HelperFailed;
        };
        return .{ .child = child };
    }

    /// Let the helper go and wait for it. Idempotent, so a test may release
    /// it early and still `defer` the call.
    fn release(h: *Holder, io: Io) void {
        if (h.released) return;
        h.released = true;
        if (h.child.stdin) |stdin| {
            stdin.close(io);
            h.child.stdin = null;
        }
        _ = h.child.wait(io) catch {};
    }
};

test "a lock a second process holds is refused, and left exactly as it was" {
    if (lock_helper_path.len == 0) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "a.txt", "hello\n");
    try repo.exec(io, &.{ "add", "-A" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();

    var holder = Holder.start(gpa, io, git_dir, "index.lock") catch return error.SkipZigTest;
    defer holder.release(io);

    // git itself refuses the same lock, which is the point: this behaves the
    // way the other writer expects. The refusal is expected, so it is not
    // reported.
    repo.report_failures = false;
    try std.testing.expectError(
        error.GitFailed,
        repo.exec(io, &.{ "add", "-A" }),
    );
    repo.report_failures = true;
    try std.testing.expectError(
        error.LockHeld,
        index.write(io, git_dir, "index", .{}),
    );

    const report = fs.staleReport(io, git_dir, "index");
    try std.testing.expect(report.held);
    if (report.pid) |pid| try std.testing.expect(pid != 0);

    // The lock is still there and still the other process's: nothing broke
    // it, and nothing wrote through it.
    try git_dir.access(io, "index.lock", .{});
    var buf: [16]u8 = undefined;
    const contents = try git_dir.readFile(io, "index.lock", &buf);
    try std.testing.expectEqual(@as(usize, 0), contents.len);

    holder.release(io);
    // With the holder gone, the write goes through.
    try index.write(io, git_dir, "index", .{});
    const listed = try repo.run(io, &.{"ls-files"});
    defer gpa.free(listed);
    try std.testing.expectEqualStrings("a.txt\n", listed);
}

test "a stale lock is reported and never broken" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A lock left behind by a process that is gone, with a pid nothing is
    // using. It stays exactly where it is.
    try tmp.dir.writeFile(io, .{ .sub_path = "thing", .data = "old\n" });
    const lock = try tmp.dir.createFile(io, "thing.lock", .{ .exclusive = true });
    lock.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "thing~pid.lock", .data = "pid 4294967294\n" });

    const report = fs.staleReport(io, tmp.dir, "thing");
    try std.testing.expect(report.held);
    try std.testing.expectEqual(@as(?u32, 4294967294), report.pid);
    if (report.holder_alive) |alive| try std.testing.expect(!alive);

    var buffer: [64]u8 = undefined;
    try std.testing.expectError(
        error.LockHeld,
        fs.LockFile.open(gpa, io, tmp.dir, "thing", &buffer, .{}),
    );
    try tmp.dir.access(io, "thing.lock", .{});
    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("old\n", try tmp.dir.readFile(io, "thing", &read_buf));
}

test "writing the index while git reads the same repository" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    for (0..25) |i| {
        var buf: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&buf, "f{d}.txt", .{i}), "contents\n");
    }
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "base" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();

    // A reader never blocks and never sees half a file: every one of these
    // is a complete index, old or new.
    for (0..10) |round| {
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "round{d}.txt", .{round});
        try repo.writeFile(io, path, "added\n");
        const blob = hash.Hasher.object(.sha1, "blob", "added\n");
        var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
        defer db.deinit(io);
        _ = try db.write(io, .blob, "added\n");
        try index.add(.{ .path = path, .oid = blob, .mode = .file });
        try index.write(io, git_dir, "index", .{});

        const listed = try repo.run(io, &.{"ls-files"});
        defer gpa.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, path) != null);
    }
    try repo.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}

test "a gc while the object database is being walked finds every object" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    var names: std.ArrayList(Oid) = .empty;
    defer names.deinit(gpa);
    for (0..40) |i| {
        var buf: [32]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf, "object number {d}\n", .{i});
        try repo.writeFile(io, try std.fmt.bufPrint(&buf, "f{d}.txt", .{i}), content);
    }
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);

    var all = try db.listObjects(io);
    defer all.deinit(gpa);
    var it = all.keyIterator();
    while (it.next()) |oid| try names.append(gpa, oid.*);
    try std.testing.expect(names.items.len > 40);

    // Everything loose goes into a pack under the reader's feet. The one
    // retry past a pack refresh is what makes the next read succeed.
    try repo.exec(io, &.{ "gc", "-q", "--prune=now" });

    for (names.items) |oid| {
        const found = try db.read(io, oid);
        defer gpa.free(found.bytes);
        try std.testing.expect(hash.Hasher.object(.sha1, found.type.name(), found.bytes).eql(oid));
    }
}

test "two writers of the same loose object both succeed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });

    // A loose object is named by its own content, so two writers racing on
    // one are writing the same bytes; each goes through its own uniquely
    // named temporary and the rename is idempotent.
    var a = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{});
    defer a.deinit(io);
    const objects_b = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var b = try odb_mod.Odb.openAt(gpa, io, objects_b, .sha1, .{});
    defer b.deinit(io);

    const one = try a.write(io, .blob, "same bytes\n");
    const two = try b.write(io, .blob, "same bytes\n");
    try std.testing.expect(one.eql(two));

    const found = try a.read(io, one);
    defer gpa.free(found.bytes);
    try std.testing.expectEqualStrings("same bytes\n", found.bytes);
}

test "concurrent reflog appends preserve every complete line" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "logs/refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/refs/heads/main", .data = "" });

    const ThreadContext = struct {
        io: Io,
        dir: Io.Dir,
        start: *Io.Event,
        failed: *std.atomic.Value(bool),
        old: Oid,
        new: Oid,

        fn run(ctx: *@This()) void {
            ctx.start.wait(ctx.io) catch {
                ctx.failed.store(true, .release);
                return;
            };
            for (0..100) |_| {
                reflog.append(
                    std.heap.page_allocator,
                    ctx.io,
                    ctx.dir,
                    "refs/heads/main",
                    ctx.old,
                    ctx.new,
                    .{ .name = "Writer", .email = "writer@example.com", .when_secs = 1, .offset_minutes = 0 },
                    "update",
                ) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    const old = try Oid.parse(.sha1, "1" ** 40);
    const new = try Oid.parse(.sha1, "2" ** 40);
    var start: Io.Event = .unset;
    var failed: std.atomic.Value(bool) = .init(false);
    var context: ThreadContext = .{ .io = io, .dir = tmp.dir, .start = &start, .failed = &failed, .old = old, .new = new };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    start.set(io);
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(false, failed.load(.acquire));

    var log = try reflog.read(gpa, io, tmp.dir, "refs/heads/main", .sha1);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 800), log.entries.len);
}
