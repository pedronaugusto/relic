//! Work and result checks, independent of the machine's clock.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const testgit = @import("git.zig");
const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const odb_state = @import("../odb/state.zig");
const pack_mod = @import("../odb/pack.zig");
const fs = @import("../fs/fs.zig");
const worktree = @import("../checkout/checkout.zig");
const repo_mod = @import("../repo/repo.zig");

/// How many files the generated tree holds.
///
/// Debug and optimized builds exercise their existing fixture sizes.
const file_count: usize = switch (builtin.optimize) {
    .Debug => 300,
    else => 3000,
};

/// How many directories the files are spread over, which is what the cache
/// tree's work is proportional to.
const directory_count: usize = 60;

test "staging and cache-tree reuse count only the work they need" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo_git = try testgit.Repo.init(gpa, io, &.{});
    defer repo_git.deinit();

    // Unique file bodies make every cold blob write count.
    var content: [96]u8 = undefined;
    for (0..file_count) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.mem.print(&path_buf, "d{d}/f{d}.txt", .{ i % directory_count, i });
        const text = try std.mem.print(&content, "file {d}\nsome contents that are not all the same\n", .{i});
        try repo_git.writeFile(io, path, text);
        try fs.setTimestamps(io, repo_git.dir, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 * std.time.ns_per_s } } });
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

    const cold = try worktree.addAll(gpa, io, repo.workDirectory().?, &index, repo.objectDatabase(), .{ .rules = wt_rules });
    const cold_stats = repo.objectDatabase().stats;

    const tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());

    try index.write(io, repo.gitDirectory(), "index", .{});
    index.deinit();
    index = try repo.openIndex(io);

    const warm = try worktree.addAll(gpa, io, repo.workDirectory().?, &index, repo.objectDatabase(), .{ .rules = wt_rules });

    const before_tree = repo.objectDatabase().stats;
    const same_tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());

    // A dirty tree: one file in ten changed, which is the shape a status
    // actually meets.
    for (0..file_count / 10) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.mem.print(&path_buf, "d{d}/f{d}.txt", .{ (i * 10) % directory_count, i * 10 });
        const text = try std.mem.print(&content, "file {d} changed\n", .{i * 10});
        try repo_git.writeFile(io, path, text);
    }
    var result = try worktree.status(gpa, io, repo.workDirectory().?, &index, repo.objectDatabase(), .{
        .rules = wt_rules,
        .head_tree = null,
    });
    defer result.deinit();

    // Every cold object is written exactly once. Every file is one object written, and
    // the fan-out directories are made once each rather than once per object:
    // two hundred and fifty-six is every directory that can exist, so this
    // bound holds whatever the tree looks like.
    try std.testing.expectEqual(@as(u64, file_count), cold_stats.loose_written);
    try std.testing.expect(cold_stats.fan_out_created <= 256);

    // The stat shortcut: a warm pass opens nothing.
    try std.testing.expectEqual(@as(u32, @intCast(file_count)), cold.hashed);
    try std.testing.expectEqual(@as(u32, 0), warm.hashed);
    try std.testing.expectEqual(@as(u32, @intCast(file_count)), warm.unchanged);

    // The cache tree: a warm write-tree writes no tree object at all
    // and returns the same name.
    try std.testing.expect(same_tree.eql(tree));
    try std.testing.expectEqualDeep(before_tree, repo.objectDatabase().stats);

    try std.testing.expect(result.entries.len >= file_count / 10);
}

const ReadWork = struct {
    threadlocal var calls: usize = 0;
    threadlocal var bytes: usize = 0;

    fn reset() void {
        calls = 0;
        bytes = 0;
    }
    fn read(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        calls += 1;
        const n = try std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
        bytes += n;
        return n;
    }
};

/// What two passes over every object of a deep delta chain read: the
/// objects and their bytes, the positional reads and the bytes those
/// returned, and the bases the delta cache holds after each pass.
pub const ChainScan = struct {
    cold_objects: usize = 0,
    warm_objects: usize = 0,
    cold_object_bytes: usize = 0,
    warm_object_bytes: usize = 0,
    cold_reads: usize = 0,
    warm_reads: usize = 0,
    cold_read_bytes: usize = 0,
    warm_read_bytes: usize = 0,
    cold_bases: usize = 0,
    warm_bases: usize = 0,

    pub fn format(s: ChainScan, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("objects cold {d} warm {d}; object bytes cold {d} warm {d}; ", .{ s.cold_objects, s.warm_objects, s.cold_object_bytes, s.warm_object_bytes });
        try w.print("reads cold {d} warm {d}; read bytes cold {d} warm {d}; ", .{ s.cold_reads, s.warm_reads, s.cold_read_bytes, s.warm_read_bytes });
        try w.print("cached bases cold {d} warm {d}", .{ s.cold_bases, s.warm_bases });
    }
};

/// Read every object in the database twice, in the order `listObjects`
/// gives, counting the positional reads of each pass.
fn scanColdWarm(gpa: std.mem.Allocator, git_dir: Io.Dir, options: odb_mod.Options) !ChainScan {
    const io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.fileReadPositional = ReadWork.read;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var db = try odb_mod.Odb.open(gpa, counted, git_dir, .sha1, options);
    defer db.deinit(io);

    var names = try db.listObjects(io);
    defer names.deinit(gpa);

    var scan: ChainScan = .{};
    ReadWork.reset();
    var it = names.keyIterator();
    while (it.next()) |oid| {
        const found = try db.read(counted, oid.*);
        defer gpa.free(found.bytes);
        scan.cold_object_bytes += found.bytes.len;
        scan.cold_objects += 1;
    }
    scan.cold_reads = ReadWork.calls;
    scan.cold_read_bytes = ReadWork.bytes;
    scan.cold_bases = odb_state.get(db._state).cache.entries.count();

    // A second pass over the same objects, with the delta base cache warm.
    ReadWork.reset();
    var warm_it = names.keyIterator();
    while (warm_it.next()) |oid| {
        const found = try db.read(counted, oid.*);
        defer gpa.free(found.bytes);
        scan.warm_object_bytes += found.bytes.len;
        scan.warm_objects += 1;
    }
    scan.warm_reads = ReadWork.calls;
    scan.warm_read_bytes = ReadWork.bytes;
    scan.warm_bases = odb_state.get(db._state).cache.entries.count();
    return scan;
}

/// The first bound two passes over a chain of `rounds` commits break, or
/// `null`. Both passes read every object to the same bytes; the warm one,
/// with the bases cached, reads no more than the cold one and caches nothing
/// new.
fn brokenChainBound(scan: ChainScan, rounds: usize) ?[]const u8 {
    const bounds = [_]struct { holds: bool, what: []const u8 }{
        .{ .holds = scan.cold_bases > 0, .what = "the cold pass cached a base" },
        .{ .holds = scan.cold_objects == scan.warm_objects, .what = "both passes read the same objects" },
        .{ .holds = scan.cold_object_bytes == scan.warm_object_bytes, .what = "both passes read the same object bytes" },
        .{ .holds = scan.cold_objects > rounds, .what = "every round's objects were read" },
        .{ .holds = scan.warm_reads <= scan.cold_reads, .what = "warm reads <= cold reads" },
        .{ .holds = scan.warm_read_bytes <= scan.cold_read_bytes, .what = "warm read bytes <= cold read bytes" },
        .{ .holds = scan.cold_bases == scan.warm_bases, .what = "the warm pass cached no new base" },
    };
    for (bounds) |bound| {
        if (!bound.holds) return bound.what;
    }
    return null;
}

test "cold and warm delta-chain reads scan the same objects and bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // The harness fixes git's dates, so every commit has the same name on
    // every run, and the scans below meet the objects in the same order.
    var repo_git = try testgit.Repo.init(gpa, io, &.{});
    defer repo_git.deinit();

    // A file that grows one line per commit gives the packer a deep chain,
    // and a pack that spans many of the blocks positional reads keep.
    const rounds: usize = 120;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..rounds) |i| {
        try body.print(gpa, "line {d} of a file that keeps growing\n", .{i});
        try repo_git.writeFile(io, "grow.txt", body.items);
        try repo_git.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try repo_git.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "c{d}", .{i}) });
    }
    // One thread, so the deltas git picks do not depend on the machine's
    // core count.
    try repo_git.exec(io, &.{ "-c", "pack.threads=1", "gc", "-q", "--aggressive" });

    const git_dir = try repo_git.gitDir(io);
    defer git_dir.close(io);
    const scan = try scanColdWarm(gpa, git_dir, .{});
    // A failure names the bound and every count.
    if (brokenChainBound(scan, rounds)) |what| {
        std.debug.print("{d} rounds: not {s}: {f}\n", .{ rounds, what, scan });
        return error.TestUnexpectedResult;
    }
}

test "a warm pass over a small pack reads no more than a cold one, at every pinned date" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // Forty commits make a pack of a few kilobytes. Where in it each object
    // sits, and the order the scans meet the objects in, follow from the
    // object names, so every date below is a different layout and order.
    // Whether a warm pass reads more must not depend on either.
    const rounds: usize = 40;
    const dates: usize = 32;
    var failed: usize = 0;
    for (0..dates) |day| {
        var repo_git = try testgit.Repo.init(gpa, io, &.{});
        defer repo_git.deinit();
        const when = testgit.fixture_date + @as(i64, @intCast(day)) * std.time.s_per_day;

        // One fast-import of the whole history rather than a git process
        // per commit.
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(gpa);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        for (0..rounds) |i| {
            try body.print(gpa, "line {d} of a file that keeps growing\n", .{i});
            var msg_buf: [16]u8 = undefined;
            const msg = try std.mem.print(&msg_buf, "c{d}", .{i});
            try stream.print(gpa, "commit refs/heads/main\ncommitter Fixture <fixture@example.com> {d} +0000\ndata {d}\n{s}\n", .{ when, msg.len, msg });
            try stream.print(gpa, "M 100644 inline grow.txt\ndata {d}\n{s}\n", .{ body.items.len, body.items });
        }
        try stream.appendSlice(gpa, "done\n");
        gpa.free(try repo_git.runInput(io, &.{ "fast-import", "--quiet", "--done" }, stream.items));
        try repo_git.exec(io, &.{ "-c", "pack.threads=1", "gc", "-q", "--aggressive" });

        const git_dir = try repo_git.gitDir(io);
        defer git_dir.close(io);
        // With every block of the pack kept, and with one block for all of
        // them.
        for ([_]usize{ odb_mod.Options.default_pack_read_cache_bytes, 0 }) |cache_bytes| {
            const scan = try scanColdWarm(gpa, git_dir, .{ .pack_read_cache_bytes = cache_bytes });
            if (brokenChainBound(scan, rounds)) |what| {
                std.debug.print("date {d}, {d}-byte read cache: not {s}: {f}\n", .{ when, cache_bytes, what, scan });
                failed += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "hardware and checked hashes process the same bytes as software" {
    const gpa = std.testing.allocator;

    // A fixed seeded corpus exercises many compression blocks.
    const bytes: usize = switch (builtin.optimize) {
        .Debug => 4 * 1024 * 1024,
        else => 64 * 1024 * 1024,
    };
    const buf = try gpa.alloc(u8, bytes);
    defer gpa.free(buf);
    var prng: std.Random.DefaultPrng = .init(0x5ec0_0d1e);
    prng.random().bytes(buf);

    const Pass = struct {
        const Self = @This();

        buf: []const u8,
        mine: hash.Oid = undefined,
        reference: [20]u8 = undefined,
        checked: hash.Oid = undefined,
        sha256: hash.Oid = undefined,
        checked_attack: bool = false,

        /// relic's SHA-1, on whichever arm this processor turned out to have.
        fn relicSha1(p: *Self) void {
            var h: hash.Hasher = .init(.sha1);
            h.update(p.buf);
            p.mine = h.final();
        }

        /// The library's SHA-1, which is the same eighty rounds relic falls
        /// back to, over the same input.
        fn librarySha1(p: *Self) void {
            std.crypto.hash.Sha1.hash(p.buf, &p.reference, .{});
        }

        /// SHA-256 over the same input.
        fn relicSha256(p: *Self) void {
            var h: hash.Hasher = .init(.sha256);
            h.update(p.buf);
            p.sha256 = h.final();
        }

        /// SHA-1 with the collision check over the same input.
        fn checkedSha1(p: *Self) void {
            var h: hash.Hasher = .initOptions(.sha1, .{ .detect_collisions = true });
            h.update(p.buf);
            p.checked = h.final();
            p.checked_attack = h.collisionAttack();
        }
    };

    var pass: Pass = .{ .buf = buf };
    Pass.relicSha1(&pass);
    Pass.librarySha1(&pass);
    Pass.relicSha256(&pass);
    Pass.checkedSha1(&pass);
    const mine_oid = pass.mine;
    const checked_oid = pass.checked;
    const reference = pass.reference;

    // The check does not change the name, and finds nothing in noise.
    try std.testing.expect(checked_oid.eql(mine_oid));
    try std.testing.expect(!pass.checked_attack);

    // The name is the name whichever arm produced it.
    try std.testing.expectEqualSlices(u8, &reference, mine_oid.raw());
    var reference256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buf, &reference256, .{});
    try std.testing.expectEqualSlices(u8, &reference256, pass.sha256.raw());
}

test "loose and packed staging count object writes and deltas reduce pack bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // The same tree staged twice: once as one loose object per blob, which
    // is what git writes, and once as one pack for the whole pass. The two
    // must produce the same tree, and the difference between them is the
    // two filesystem calls a loose object costs.
    var trees: [2]hash.Oid = undefined;
    var packed_report: ?pack_mod.WriteReport = null;

    for ([_]worktree.NewBlobs{ .loose, .pack }, 0..) |where, pass| {
        var repo_git = try testgit.Repo.init(gpa, io, &.{});
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

        const outcome = try worktree.addAll(gpa, io, repo.workDirectory().?, &index, repo.objectDatabase(), .{
            .rules = wt_rules,
            .new_blobs = where,
        });
        try std.testing.expectEqual(@as(u32, @intCast(file_count)), outcome.added);
        if (where == .pack) {
            packed_report = outcome.pack;
            try std.testing.expectEqual(@as(u64, file_count), repo.objectDatabase().stats.packed_written);
            try std.testing.expectEqual(@as(u64, 0), repo.objectDatabase().stats.loose_written);
        } else try std.testing.expectEqual(@as(u64, file_count), repo.objectDatabase().stats.loose_written);
        trees[pass] = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());
    }
    try std.testing.expect(trees[0].eql(trees[1]));
    try std.testing.expect(packed_report != null);

    // And writing a pack out of a repository that already has one commit's
    // worth of history, which is where the delta window earns its keep.
    var repo_git = try testgit.Repo.init(gpa, io, &.{});
    defer repo_git.deinit();
    const rounds: usize = switch (builtin.optimize) {
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

    const whole = try db.writePack(io, pack_dir, collected.entries, .{ .delta = .none });

    const deltified = try db.writePack(io, pack_dir, collected.entries, .{});

    // The window has to find something: these files are each other's
    // neighbours a few lines apart.
    try std.testing.expect(deltified.deltas > 0);
    // And what it finds has to be worth having.
    try std.testing.expect(deltified.pack_bytes < whole.pack_bytes);
}
