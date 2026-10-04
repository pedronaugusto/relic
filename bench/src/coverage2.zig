//! Storage and network operations omitted from the original operation pass.
//! One operation per process; setup and validation belong to coverage2_pass.py.
const std = @import("std");
const relic = @import("relic");
const Io = std.Io;
const Repository = relic.repo.Repository;
const who: relic.object.Signature = .{ .name = "Bench", .email = "bench\x40example.invalid", .when_secs = 1_700_000_000, .offset_minutes = 0 };
var ticks = std.atomic.Value(i64).init(0);
fn now(io: Io) Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = ticks.fetchAdd(1, .monotonic) };
    return Io.Clock.awake.now(io);
}
fn row(io: Io, w: []const u8, metric: []const u8, value: []const u8, unit: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&buffer, "relic\t{s}\t{s}\t{s}\t{s}\n", .{ w, metric, value, unit }));
}
fn store(repo: *Repository) *relic.refs.Store {
    return if (@hasDecl(Repository, "refStore")) repo.refStore() else &repo.refs;
}
fn kind(repo: *const Repository) relic.hash.Kind {
    return if (@hasDecl(Repository, "objectFormat")) repo.objectFormat() else repo.kind;
}
fn refsDigest(gpa: std.mem.Allocator, io: Io, repo: *Repository) ![20]u8 {
    var listing = try store(repo).list(gpa, io, "refs/");
    defer listing.deinit();
    var hash = std.crypto.hash.Sha1.init(.{});
    for (listing.entries) |entry| {
        const resolved = (try store(repo).resolve(gpa, io, entry.name)) orelse return error.RefMissing;
        defer gpa.free(resolved.name);
        var hex: [relic.hash.max_hex_len]u8 = undefined;
        hash.update(entry.name);
        hash.update(" ");
        hash.update(resolved.oid.hex(&hex));
        hash.update("\n");
    }
    return hash.finalResult();
}
fn lockDigest(locks: []const relic.lfs.lfslocks.Lock) [20]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    for (locks) |lock| {
        for ([_][]const u8{ lock.id, lock.path, lock.owner orelse "", lock.locked_at orelse "" }) |field| {
            hash.update(field);
            hash.update("\x00");
        }
        hash.update("\n");
    }
    return hash.finalResult();
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const gpa = init.gpa;
    const io = init.io;
    const cwd = Io.Dir.cwd();
    const w = args[1];
    const path = args[2];
    const extra = if (args.len > 3) args[3] else "";
    const eql = std.mem.eql;
    var digest: ?[20]u8 = null;
    var count: ?usize = null;
    const start = now(io);
    if (std.mem.startsWith(u8, w, "clone-")) {
        try cwd.createDirPath(io, extra);
        var dir = try cwd.openDir(io, extra, .{ .iterate = true });
        defer dir.close(io);
        var repo = try relic.transport.clone.clone(gpa, io, path, dir, .{
            .who = who,
            .bare = true,
            .checkout = false,
            .tags = false,
            .single_branch = true,
            .branch = "main",
            .depth = if (eql(u8, w, "clone-depth")) 3 else null,
            .filter = if (eql(u8, w, "clone-blob-none")) "blob:none" else if (eql(u8, w, "clone-tree-zero")) "tree:0" else null,
            .check_objects = false,
            .odb = .{ .detect_sha1_collisions = true },
            .programs = .{ .environ = init.environ_map },
        });
        defer repo.deinit(io);
    } else {
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var repo = try Repository.open(gpa, io, dir, .{ .odb = .{ .detect_sha1_collisions = true } });
        defer repo.deinit(io);
        if (eql(u8, w, "reftable-read")) {
            digest = try refsDigest(gpa, io, &repo);
        } else if (eql(u8, w, "reftable-write")) {
            const tip = (try store(&repo).resolve(gpa, io, "refs/heads/main")).?;
            defer gpa.free(tip.name);
            var tx = repo.beginRefs();
            defer tx.deinit(io);
            count = if (@import("bench_options").smoke) 10 else 1000;
            for (0..count.?) |i| {
                var name: [80]u8 = undefined;
                try tx.create(try std.fmt.bufPrint(&name, "refs/heads/bench/b{d:0>4}", .{i}), .{ .direct = tip.oid });
            }
            try tx.commit(io, null);
        } else if (eql(u8, w, "reftable-compact")) {
            try relic.refs.reftablestack.compactIn(gpa, io, repo.common_dir, kind(&repo), .{}, .all);
        } else if (eql(u8, w, "midx-read")) {
            const text = try cwd.readFileAlloc(io, extra, gpa, .unlimited);
            defer gpa.free(text);
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            var hash = std.crypto.hash.Sha1.init(.{});
            count = 0;
            while (lines.next()) |line| {
                const oid = try relic.hash.Oid.parse(kind(&repo), line);
                const obj = try repo.odb.read(io, oid);
                defer gpa.free(obj.bytes);
                hash.update(obj.bytes);
                count.? += 1;
            }
            digest = hash.finalResult();
        } else if (std.mem.startsWith(u8, w, "rerere-")) {
            var index = try repo.openIndex(io);
            defer index.deinit();
            var outcome = try relic.merge.rerere.run(gpa, io, &repo, &index, .{ .autoupdate = false });
            defer outcome.deinit();
            count = if (eql(u8, w, "rerere-record")) outcome.recorded_resolution.len else outcome.resolved.len;
        } else if (std.mem.startsWith(u8, w, "sparse-")) {
            const cone = std.mem.indexOf(u8, w, "noncone") == null;
            const options: relic.worktree.sparsecheckout.Options = .{ .cone = cone, .sparse_index = false };
            if (std.mem.endsWith(u8, w, "set")) {
                _ = try relic.worktree.sparsecheckout.set(&repo, io, if (cone) &.{"d00"} else &.{ "/d00/", "/side/", "!/side/s00.txt" }, options);
            } else _ = try relic.worktree.sparsecheckout.reapply(&repo, io, options);
        } else if (eql(u8, w, "lazy-fetch")) {
            const oid = try relic.hash.Oid.parse(kind(&repo), extra);
            var lazy = relic.transport.partial.Lazy.init(gpa, &repo, .{ .programs = .{ .environ = init.environ_map }, .check_objects = false });
            defer lazy.deinit();
            lazy.install();
            const obj = try repo.odb.read(io, oid);
            defer gpa.free(obj.bytes);
            var hash = std.crypto.hash.Sha1.init(.{});
            hash.update(obj.bytes);
            digest = hash.finalResult();
        } else if (std.mem.startsWith(u8, w, "lfs-")) {
            const server = try relic.lfs.lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = .{ .environ = init.environ_map } });
            defer server.close();
            if (eql(u8, w, "lfs-download")) {
                var outcome = try relic.lfs.lfstransfer.fetch(server, &repo, .{ .refs = &.{"refs/heads/data"}, .recent = false });
                defer outcome.deinit();
                if (outcome.failures() != 0) return error.LfsTransferFailed;
            } else if (eql(u8, w, "lfs-upload")) {
                const text = try cwd.readFileAlloc(io, extra, gpa, .unlimited);
                defer gpa.free(text);
                var objects: std.ArrayList(relic.lfs.lfstransfer.Object) = .empty;
                defer objects.deinit(gpa);
                var lines = std.mem.tokenizeScalar(u8, text, '\n');
                while (lines.next()) |line| {
                    var fields = std.mem.tokenizeScalar(u8, line, ' ');
                    const oid = fields.next().?;
                    try objects.append(gpa, .{ .oid = oid[0..64].*, .size = try std.fmt.parseInt(u64, fields.next().?, 10) });
                }
                var outcome = try relic.lfs.lfstransfer.upload(server, objects.items, .{});
                defer outcome.deinit();
                if (outcome.failures() != 0) return error.LfsTransferFailed;
                count = objects.items.len;
            } else if (eql(u8, w, "lfs-lock")) {
                const acquired = try relic.lfs.lfslocks.lock(server, &repo, "data/f00.bin", init.arena.allocator(), .{});
                if (acquired != .locked) return error.LockNotAcquired;
                digest = lockDigest(&.{acquired.locked});
            } else if (eql(u8, w, "lfs-unlock")) {
                const released = try relic.lfs.lfslocks.unlockPath(server, &repo, "data/f00.bin", false, init.arena.allocator(), .{});
                digest = lockDigest(&.{released});
            } else if (eql(u8, w, "lfs-lock-list")) {
                var listing = try relic.lfs.lfslocks.list(server, &repo, .{}, .{});
                defer listing.deinit();
                count = listing.locks.len;
                digest = lockDigest(listing.locks);
            } else if (eql(u8, w, "lfs-lock-verify")) {
                var verified = try relic.lfs.lfslocks.verify(server, &repo, .{});
                defer verified.deinit();
                count = verified.ours.len + verified.theirs.len;
                if (verified.theirs.len != 0) return error.UnexpectedLockOwner;
                digest = lockDigest(verified.ours);
            } else return error.UnknownLfsWorkload;
        } else return error.UnknownWorkload;
    }
    const elapsed = start.durationTo(now(io));
    var value: [80]u8 = undefined;
    try row(io, w, "time", try std.fmt.bufPrint(&value, "{d:.3}", .{@as(f64, @floatFromInt(elapsed.nanoseconds)) / 1e6}), "ms");
    if (count) |n| try row(io, w, "items", try std.fmt.bufPrint(&value, "{d}", .{n}), "count");
    if (digest) |d| try row(io, w, "digest", &std.fmt.bytesToHex(d, .lower), "oid");
}
