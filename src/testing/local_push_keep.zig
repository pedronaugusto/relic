//! Local push owns its received pack until all receiver ref transactions end.
const std = @import("std");
const builtin = @import("builtin");
const seam = @import("airlock.testing");
const Io = std.Io;
const testing = std.testing;
const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const local = @import("../transport/local.zig");
const odb_mod = @import("../odb/odb.zig");
const sendpack = @import("../wire.zig").sendpack;
const hash = @import("../hash/hash.zig");

const no_space: seam.Code = if (builtin.target.os.tag == .windows) .DISK_FULL else .NOSPC;

/// A push run on its own task, to stand still where its receiving repository
/// takes the lock of the refs.
const Push = struct {
    accepted: bool = false,

    fn run(push: *Push, io: Io, path: []const u8, from: *odb_mod.Odb, commands: []const sendpack.Command, entries: []const odb_mod.PackEntry, atomic: bool) !void {
        var remote = try local.Remote.open(testing.allocator, io, path, .{});
        defer remote.deinit(io);
        var report = try remote.receivePush(testing.allocator, io, .{ .from = from, .commands = commands, .objects = entries }, .{
            .who = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
            .atomic = atomic,
        });
        defer report.deinit();
        push.accepted = report.refs.len == 1 and report.refs[0].ok;
    }
};

fn keeps(io: Io, dir: Io.Dir) !usize {
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".keep.lock"));
        if (std.mem.endsWith(u8, entry.name, ".keep")) count += 1;
    }
    return count;
}

test "local push retains its pack through collection failure and cancellation" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(4) });
    defer threaded.deinit();
    const io = threaded.io();
    for (try testgit.refFormats(gpa, io)) |ref_format| {
        for ([_][]const u8{ "sha1", "sha256" }) |format| {
            const fmtarg = try gpa.print("--object-format={s}", .{format});
            defer gpa.free(fmtarg);
            var source = try testgit.Repo.init(gpa, io, &.{fmtarg});
            defer source.deinit();
            try source.writeFile(io, "a", "pushed pack\n");
            try source.exec(io, &.{ "add", "a" });
            try source.exec(io, &.{ "commit", "-qm", "push" });
            const head = try source.line(io, &.{ "rev-parse", "HEAD" });
            defer gpa.free(head);
            var from = try repo_mod.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
            defer from.deinit(io);
            const oid = try hash.Oid.parse(from.objectFormat(), head);
            var objects = try from.objectDatabase().collectReachable(io, &.{oid}, .{});
            defer objects.deinit();
            const commands = [_]sendpack.Command{.{ .name = "refs/heads/arrived", .old = hash.Oid.zero(oid.kind), .new = oid }};
            for ([_]bool{ false, true }) |atomic| {
                for ([_]enum { success, failure, cancellation }{ .success, .failure, .cancellation }) |outcome| {
                    const args = try std.mem.concat(gpa, []const u8, &.{ &.{ "--bare", fmtarg }, ref_format.initArgs() });
                    defer gpa.free(args);
                    var target = try testgit.Repo.init(gpa, io, args);
                    defer target.deinit();
                    const path = try target.dir.realPathFileAlloc(io, ".", gpa);
                    defer gpa.free(path);
                    var ready: Io.Event = .unset;
                    var release: Io.Event = .unset;
                    const lock_name = if (ref_format == .files) "arrived.lock" else "tables.list.lock";
                    const fault = try seam.Seam.create(gpa, io, .{ .gate = .{ .call = .create_temp, .suffix = lock_name, .reached = &ready, .release = &release } });
                    defer fault.destroy();
                    var push: Push = .{};
                    var publication = try io.concurrent(Push.run, .{ &push, fault.io(), path, from.objectDatabase(), &commands, objects.entries, atomic });
                    defer _ = publication.cancel(io) catch {};
                    try ready.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(20) } });
                    var pack_dir = try target.dir.openDir(io, "objects/pack", .{ .iterate = true });
                    defer pack_dir.close(io);
                    try testing.expectEqual(@as(usize, 1), try keeps(io, pack_dir));
                    const Collector = struct {
                        fn run(worker_io: Io, git: *testgit.Repo) !void {
                            for (0..3) |_| {
                                try git.exec(worker_io, &.{ "repack", "-ad" });
                                try git.exec(worker_io, &.{ "prune", "--expire=now" });
                            }
                        }
                    };
                    var collector = try io.concurrent(Collector.run, .{ io, &target });
                    defer _ = collector.cancel(io) catch {};
                    try collector.await(io);
                    try target.exec(io, &.{ "cat-file", "-e", head });
                    if (outcome == .cancellation) {
                        try testing.expectError(error.Canceled, publication.cancel(io));
                    } else {
                        if (outcome == .failure) fault.setPlan(&.{.{ .at = .{ .nth = .{ .call = .create_temp, .n = 1, .path = .{ .suffix = lock_name } } }, .fault = .{ .code = no_space } }});
                        release.set(io);
                        try publication.await(io);
                        try testing.expectEqual(outcome == .success, push.accepted);
                        if (outcome == .failure) try testing.expectEqual(@as(usize, 1), fault.plan.firedCount());
                    }
                    try testing.expectEqual(@as(usize, 0), try keeps(io, pack_dir));
                    var reopened = try repo_mod.Repository.open(gpa, io, target.dir, .{});
                    defer reopened.deinit(io);
                    const received = try reopened.refStore().readOid(gpa, io, "refs/heads/arrived");
                    if (outcome == .success) {
                        try testing.expect(received != null and received.?.eql(oid));
                        try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
                    } else {
                        try testing.expect(received == null);
                        var retry = reopened.beginRefs();
                        defer retry.deinit(io);
                        try retry.create("refs/heads/retry", .{ .direct = oid });
                        try retry.commit(io, null);
                    }
                }
            }
        }
    }
}
