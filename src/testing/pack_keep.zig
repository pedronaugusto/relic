//! Received-pack retention through reference publication, against Git collection.
const std = @import("std");
const builtin = @import("builtin");
const seam = @import("airlock.testing");
const transport_mod = @import("../transport/transport.zig");
const testing = std.testing;
const Io = std.Io;
const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
/// Windows renames through the handle of the file.
const rename_call: seam.Call = if (builtin.target.os.tag == .windows) .win_rename_ex else .rename;
const no_space: seam.Code = if (builtin.target.os.tag == .windows) .DISK_FULL else .NOSPC;

test "received pack survives prune before references are published" {
    const gpa = testing.allocator;
    const io = testing.io;
    for (try testgit.refFormats(gpa, io)) |ref_format| {
        for ([_][]const u8{ "sha1", "sha256" }) |format| {
            const fmtarg = try gpa.print("--object-format={s}", .{format});
            defer gpa.free(fmtarg);
            var source = try testgit.Repo.init(gpa, io, &.{fmtarg});
            defer source.deinit();
            try source.writeFile(io, "a", "received\n");
            try source.exec(io, &.{ "add", "a" });
            try source.exec(io, &.{ "commit", "-qm", "received" });
            const head = try source.line(io, &.{ "rev-parse", "HEAD" });
            defer gpa.free(head);
            const bytes = try source.run(io, &.{ "pack-objects", "--all", "--stdout" });
            defer gpa.free(bytes);
            const args = try std.mem.concat(gpa, []const u8, &.{ &.{ "--bare", fmtarg }, ref_format.initArgs() });
            defer gpa.free(args);
            var target = try testgit.Repo.init(gpa, io, args);
            defer target.deinit();
            var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
            defer repo.deinit(io);
            var dir = try repo.objectDatabase().objectsDirectory().openDir(io, "pack", .{ .iterate = true });
            defer dir.close(io);
            var reader: Io.Reader = .fixed(bytes);
            var received = try repo.objectDatabase().receivePack(io, &reader, .{});
            var released = false;
            defer if (!released) received.deinit(io);
            var hex: [hash.max_hex_len]u8 = undefined;
            const marker = try gpa.print("pack-{s}.keep", .{received.name.?.hex(&hex)});
            defer gpa.free(marker);
            try dir.access(io, marker, .{});
            const oid = try Oid.parse(repo.objectFormat(), head);
            {
                var failed = repo.refStore().begin(gpa);
                defer failed.deinit(io);
                try failed.update("refs/heads/failed", .{ .direct = oid }, .{ .matches = oid });
                try testing.expectError(error.ExpectedValueMismatch, failed.commit(io, null));
                try dir.access(io, marker, .{});
            }
            var tx = repo.refStore().begin(gpa);
            defer tx.deinit(io);
            try tx.create("refs/heads/main", .{ .direct = oid });
            try tx.prepare(io);
            const Collector = struct {
                fn run(worker_io: Io, git: *testgit.Repo) !void {
                    for (0..3) |_| {
                        try git.exec(worker_io, &.{ "repack", "-ad" });
                        try git.exec(worker_io, &.{ "prune", "--expire=now" });
                    }
                }
            };
            var collector = try io.concurrent(Collector.run, .{ io, &target });
            // glint-ignore: Z026 -- the task is canceled to stop it; its outcome is checked through its state
            defer _ = collector.cancel(io) catch {};
            try collector.await(io);
            try target.exec(io, &.{ "cat-file", "-e", head });
            try tx.commit(io, null);
            received.deinit(io);
            released = true;
            try testing.expectError(error.FileNotFound, dir.access(io, marker, .{}));
            try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
        }
    }
}

test "received pack retention and rollback survive a ref commit fault" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "a", "received\n");
    try source.exec(io, &.{ "add", "a" });
    try source.exec(io, &.{ "commit", "-qm", "received" });
    const head = try source.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const bytes = try source.run(io, &.{ "pack-objects", "--all", "--stdout" });
    defer gpa.free(bytes);
    for (try testgit.refFormats(gpa, io)) |format| {
        const args = try std.mem.concat(gpa, []const u8, &.{ &.{"--bare"}, format.initArgs() });
        defer gpa.free(args);
        var target = try testgit.Repo.init(gpa, io, args);
        defer target.deinit();
        const fault = try seam.Seam.create(gpa, io, .{});
        defer fault.destroy();
        const fault_io = fault.io();
        // Reftable read caches retain their Io until the repository closes.
        var repo = try repo_mod.Repository.open(gpa, fault_io, target.dir, .{});
        defer repo.deinit(fault_io);
        var reader: Io.Reader = .fixed(bytes);
        var received = try repo.objectDatabase().receivePack(fault_io, &reader, .{});
        var released = false;
        defer if (!released) received.deinit(fault_io);
        var hex: [hash.max_hex_len]u8 = undefined;
        const marker = try gpa.print("objects/pack/pack-{s}.keep", .{received.name.?.hex(&hex)});
        defer gpa.free(marker);
        {
            var tx = repo.refStore().begin(gpa);
            defer tx.deinit(fault_io);
            try tx.create("refs/heads/faulted", .{ .direct = try Oid.parse(.sha1, head) });
            try tx.prepare(fault_io);
            // A fault Windows' replace-retry does not absorb.
            fault.setPlan(&.{seam.fail(rename_call, 1, no_space)});
            try testing.expectError(error.NoSpaceLeft, tx.commit(fault_io, null));
            try testing.expectEqual(@as(usize, 1), fault.plan.firedCount());
            try target.dir.access(io, marker, .{});
        }
        try testing.expect((try repo.refStore().readOid(gpa, io, "refs/heads/faulted")) == null);
        received.deinit(fault_io);
        released = true;
        try testing.expectError(error.FileNotFound, target.dir.access(io, marker, .{}));
        try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

const WaitingPublication = struct {
    ready: Io.Event = .unset,
    release: Io.Event = .unset,
    pack_hex: [hash.max_hex_len]u8 = undefined,
    pack_hex_len: usize = 0,

    fn receiveAndPrepare(state: *WaitingPublication, io: Io, dir: Io.Dir, bytes: []const u8, head: []const u8) !void {
        var repo = try repo_mod.Repository.open(testing.allocator, io, dir, .{});
        defer repo.deinit(io);
        var reader: Io.Reader = .fixed(bytes);
        var received = try repo.objectDatabase().receivePack(io, &reader, .{});
        defer received.deinit(io);
        const name = received.name.?.hex(&state.pack_hex);
        state.pack_hex_len = name.len;
        var tx = repo.refStore().begin(testing.allocator);
        defer tx.deinit(io);
        try tx.create("refs/heads/canceled", .{ .direct = try Oid.parse(.sha1, head) });
        try tx.prepare(io);
        state.ready.set(io);
        try state.release.wait(io);
        return error.TestUnexpectedResult;
    }
};

test "canceled publication releases ref locks before its received pack keep" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "a", "received\n");
    try source.exec(io, &.{ "add", "a" });
    try source.exec(io, &.{ "commit", "-qm", "received" });
    const head = try source.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const bytes = try source.run(io, &.{ "pack-objects", "--all", "--stdout" });
    defer gpa.free(bytes);
    for (try testgit.refFormats(gpa, io)) |format| {
        const args = try std.mem.concat(gpa, []const u8, &.{ &.{"--bare"}, format.initArgs() });
        defer gpa.free(args);
        var target = try testgit.Repo.init(gpa, io, args);
        defer target.deinit();
        var state: WaitingPublication = .{};
        var publication = try io.concurrent(WaitingPublication.receiveAndPrepare, .{ &state, io, target.dir, bytes, head });
        // glint-ignore: Z026 -- the task is canceled to stop it; its outcome is checked through its state
        defer _ = publication.cancel(io) catch {};
        try state.ready.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(20) } });
        const marker = try gpa.print("objects/pack/pack-{s}.keep", .{state.pack_hex[0..state.pack_hex_len]});
        defer gpa.free(marker);
        try target.dir.access(io, marker, .{});
        try target.exec(io, &.{ "repack", "-ad" });
        try target.exec(io, &.{ "prune", "--expire=now" });
        try target.exec(io, &.{ "cat-file", "-e", head });
        try testing.expectError(error.Canceled, publication.cancel(io));
        try testing.expectError(error.FileNotFound, target.dir.access(io, marker, .{}));
        var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
        defer repo.deinit(io);
        try testing.expect((try repo.refStore().readOid(gpa, io, "refs/heads/canceled")) == null);
        var retry = repo.refStore().begin(gpa);
        defer retry.deinit(io);
        try retry.create("refs/heads/recovered", .{ .direct = try Oid.parse(.sha1, head) });
        try retry.commit(io, null);
        try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

test "local receive owns a keep token with default receive options" {
    const gpa = testing.allocator;
    const io = testing.io;
    for (try testgit.refFormats(gpa, io)) |ref_format| {
        for ([_][]const u8{ "sha1", "sha256" }) |format| {
            const fmtarg = try gpa.print("--object-format={s}", .{format});
            defer gpa.free(fmtarg);
            var source = try testgit.Repo.init(gpa, io, &.{fmtarg});
            defer source.deinit();
            try source.writeFile(io, "a", "local receipt\n");
            try source.exec(io, &.{ "add", "a" });
            try source.exec(io, &.{ "commit", "-qm", "received" });
            const head = try source.line(io, &.{ "rev-parse", "HEAD" });
            defer gpa.free(head);
            const args = try std.mem.concat(gpa, []const u8, &.{ &.{ "--bare", fmtarg }, ref_format.initArgs() });
            defer gpa.free(args);
            var target = try testgit.Repo.init(gpa, io, args);
            defer target.deinit();
            var repository = try repo_mod.Repository.open(gpa, io, target.dir, .{});
            defer repository.deinit(io);
            const path = try source.dir.realPathFileAlloc(io, ".", gpa);
            defer gpa.free(path);
            var session = try transport_mod.Session.open(gpa, io, path, .{ .service = .upload_pack, .kind = repository.objectFormat() }, .{ .local_copy = true });
            defer session.deinit(io);
            var pack_dir = try repository.objectDatabase().objectsDirectory().openDir(io, "pack", .{ .iterate = true });
            defer pack_dir.close(io);
            const oid = try Oid.parse(repository.objectFormat(), head);
            var fetched = try session.fetch(gpa, io, .{ .db = repository.objectDatabase(), .pack_dir = pack_dir, .request = .{ .wants = &.{oid}, .tips = &.{} } }, .{});
            var released = false;
            defer if (!released) fetched.deinit(io);
            try testing.expect(fetched.keep != null);
            var hex: [hash.max_hex_len]u8 = undefined;
            const marker = try gpa.print("pack-{s}.keep", .{fetched.pack.?.hex(&hex)});
            defer gpa.free(marker);
            try pack_dir.access(io, marker, .{});
            var tx = repository.refStore().begin(gpa);
            defer tx.deinit(io);
            try tx.create("refs/heads/main", .{ .direct = oid });
            try tx.prepare(io);
            try target.exec(io, &.{ "repack", "-ad" });
            try target.exec(io, &.{ "prune", "--expire=now" });
            try target.exec(io, &.{ "cat-file", "-e", head });
            try tx.commit(io, null);
            fetched.deinit(io);
            released = true;
            try testing.expectError(error.FileNotFound, pack_dir.access(io, marker, .{}));
            try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
        }
    }
}

test {
    _ = @import("local_push_keep.zig");
}

/// Each pack in `.git/objects/pack`, as `<marker> <object count>`, sorted:
/// `keep`, `promisor` or `plain`, and how many objects `git verify-pack`
/// says it holds.
fn packSet(gpa: std.mem.Allocator, io: std.Io, r: *testgit.Repo) ![]u8 {
    var dir = try r.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer dir.close(io);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
        const base = entry.name[0 .. entry.name.len - ".pack".len];
        var buf: [128]u8 = undefined;
        const marker: []const u8 = if (dir.access(io, try std.mem.print(&buf, "{s}.keep", .{base}), .{})) |_| "keep" else |_| if (dir.access(io, try std.mem.print(&buf, "{s}.promisor", .{base}), .{})) |_| "promisor" else |_| "plain";
        const count = try r.run(io, &.{ "verify-pack", "-v", try std.mem.print(&buf, ".git/objects/pack/{s}.idx", .{base}) });
        defer gpa.free(count);
        var n: usize = 0;
        var objects = std.mem.splitScalar(u8, count, '\n');
        while (objects.next()) |line| {
            if (line.len > 40 and std.mem.findScalar(u8, line[0..40], ' ') == null) n += 1;
        }
        try lines.append(gpa, try gpa.print("{s} {d}", .{ marker, n }));
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return std.mem.join(gpa, "\n", lines.items);
}

/// A repository with a kept pack, a promisor pack and loose objects.
fn threeKinds(gpa: std.mem.Allocator, io: std.Io) !testgit.Repo {
    var r = try testgit.Repo.init(gpa, io, &.{});
    errdefer r.deinit();
    for ([_][]const u8{ "k", "p", "l" }, 0..) |name, i| {
        try r.writeFile(io, name, name);
        try r.exec(io, &.{ "add", name });
        var msg_buf: [8]u8 = undefined;
        try r.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg_buf, "c{d}", .{i}) });
        if (i == 2) break;
        const tip = try r.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(tip);
        const input = try gpa.print("{s}\n", .{tip});
        defer gpa.free(input);
        const listed = try r.runInput(io, &.{ "rev-list", "--objects", "--no-object-names", "--stdin" }, input);
        defer gpa.free(listed);
        const made = try r.runInput(io, &.{ "pack-objects", ".git/objects/pack/pack" }, listed);
        defer gpa.free(made);
        const base = try gpa.print(".git/objects/pack/pack-{s}.{s}", .{ std.mem.trim(u8, made, "\n"), if (i == 0) "keep" else "promisor" });
        defer gpa.free(base);
        try r.writeFile(io, base, "");
        try r.exec(io, &.{ "prune-packed" });
    }
    return r;
}

test "repack leaves a kept pack as it is and keeps promisor objects in a promisor pack, as git's repack -a -d" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var theirs = try threeKinds(gpa, io);
    defer theirs.deinit();
    var ours = try threeKinds(gpa, io);
    defer ours.deinit();
    try theirs.exec(io, &.{ "repack", "-a", "-d", "-q" });
    var repo = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer repo.deinit(io);
    _ = try repo.objectDatabase().repack(io, .{ .remove_packs = true });
    const want = try packSet(gpa, io, &theirs);
    defer gpa.free(want);
    const got = try packSet(gpa, io, &ours);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
    try ours.exec(io, &.{ "fsck", "--no-progress" });
}
