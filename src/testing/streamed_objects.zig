//! Objects past `core.bigFileThreshold` written and received without being
//! held (designs/relic.md §10), against git 2.55: a pack written with them
//! copies the entries its packs store in blocks and deflates the rest as it
//! reads them, and index-pack names such an entry as it inflates it, both
//! under an object cap and an allocator peak below the objects' size.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const suite = @import("helpers.zig");
const builtin = @import("builtin");
const Counting = @import("shakedown").alloc.Counting;
const repo_mod = @import("../repo/repo.zig");
const repack_mod = @import("../maintenance/repack.zig");
const index_pack = @import("../odb/index_pack.zig");
const pack = @import("../odb/pack.zig");
const hash = @import("../hash/hash.zig");

/// How large each big object is: past the threshold and the cap below,
/// and past what the allocator may hold at once.
const big_len = 1 << 20;
/// The object cap the repository is opened with: anything read whole past
/// it fails.
const cap: u64 = 16 << 10;

/// `len` bytes of lines no two alike, from `seed`; `changed` alters one
/// line in the middle, so two versions delta well.
fn bigText(gpa: Allocator, seed: u64, changed: bool, len: usize) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const text = try gpa.alloc(u8, len);
    var at: usize = 0;
    var line: usize = 0;
    while (at < text.len) : (line += 1) {
        var buf: [40]u8 = undefined;
        const drawn = prng.random().int(u64);
        const value = if (changed and line == 700) 0 else drawn;
        const written = std.mem.print(&buf, "{d:0>6} {x:0>16}\n", .{ line, value }) catch unreachable;
        const n = @min(written.len, text.len - at);
        @memcpy(text[at..][0..n], written[0..n]);
        at += n;
    }
    return text;
}

/// Two versions of a big file packed with git's own threshold, so one is a
/// delta of the other; a third big file and a small one loose after; and
/// `core.bigFileThreshold` set to a kilobyte.
fn bigHistory(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    for ([_]bool{ false, true }) |changed| {
        const text = try bigText(gpa, 1, changed, big_len);
        defer gpa.free(text);
        try git.writeFile(io, "big.txt", text);
        try git.exec(io, &.{ "add", "big.txt" });
        try git.exec(io, &.{ "commit", "-q", "-m", "big" });
    }
    try git.exec(io, &.{ "repack", "-q", "-a", "-d", "-f" });
    const loose = try bigText(gpa, 2, false, big_len);
    defer gpa.free(loose);
    try git.writeFile(io, "other.txt", loose);
    try git.writeFile(io, "small.txt", "small\n");
    try git.exec(io, &.{ "add", "other.txt", "small.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "loose" });
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "1k" });
}

/// How many objects `git verify-pack -v` lists as deltas, over every pack.
fn deltaCount(gpa: Allocator, io: Io, git: *testgit.Repo) !usize {
    var pack_dir = try git.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var count: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const path = try std.mem.concat(gpa, u8, &.{ ".git/objects/pack/", entry.name });
        defer gpa.free(path);
        const listed = try git.run(io, &.{ "verify-pack", "-v", path });
        defer gpa.free(listed);
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        // A delta's line has seven fields: its depth and base last.
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            var n: usize = 0;
            while (fields.next()) |_| n += 1;
            if (n == 7) count += 1;
        }
    }
    return count;
}

test "a pack written with objects past core.bigFileThreshold holds none whole: a stored entry copied, a loose object deflated as read, and git reads the pack" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const io = std.testing.io;
    for ([_]u16{ 1, 4 }) |threads| {
        // The peak is counted on one thread; with four, the cap alone
        // proves nothing is read whole.
        var counting: Counting = .init(std.testing.allocator);
        const gpa = if (threads == 1) counting.allocator() else std.testing.allocator;
        var git = try testgit.Repo.init(std.testing.allocator, io, &.{});
        defer git.deinit();
        try bigHistory(std.testing.allocator, io, &git);
        try std.testing.expect(try deltaCount(std.testing.allocator, io, &git) != 0);

        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{ .odb = .{ .max_object_bytes = .fromRaw(cap) } });
        defer repo.deinit(io);
        var pack_options = repo.objectDatabase().packOptions();
        pack_options.threads = threads;
        counting.resetPeak();
        const before = counting.live_bytes;
        _ = try repack_mod.repack(gpa, io, &repo, .{ .mode = .all, .delete = true, .pack = pack_options });
        if (threads == 1) try std.testing.expect(counting.peak_bytes - before < big_len);

        const checked = try git.run(io, &.{ "fsck", "--full", "--strict", "--no-dangling" });
        std.testing.allocator.free(checked);
        // The delta the pack held was copied as it was stored.
        try std.testing.expect(try deltaCount(std.testing.allocator, io, &git) != 0);
        const listed = try git.run(io, &.{ "count-objects", "-v" });
        defer std.testing.allocator.free(listed);
        try std.testing.expect(std.mem.find(u8, listed, "in-pack: 10\n") != null);
    }
}

test "index-pack names an entry past its object cap as it inflates it, keeping nothing, and git reads what it wrote" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const io = std.testing.io;
    var theirs = try testgit.Repo.init(std.testing.allocator, io, &.{});
    defer theirs.deinit();
    try bigHistory(std.testing.allocator, io, &theirs);
    // Every object, the big ones whole: a delta's result is held to be
    // named, within the cap, as git's index-pack holds it.
    const stream = try theirs.run(io, &.{ "pack-objects", "-q", "--stdout", "--all", "--no-reuse-delta" });
    defer std.testing.allocator.free(stream);

    var ours = try testgit.Repo.init(std.testing.allocator, io, &.{});
    defer ours.deinit();
    try ours.exec(io, &.{ "config", "core.bigFileThreshold", "1k" });
    var counting: Counting = .init(std.testing.allocator);
    const gpa = counting.allocator();
    var repo = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer repo.deinit(io);
    var pack_dir = try ours.dir.openDir(io, ".git/objects/pack", .{});
    defer pack_dir.close(io);
    var in: Io.Reader = .fixed(stream);
    counting.resetPeak();
    const before = counting.live_bytes;
    var result = try index_pack.receive(gpa, io, repo.objectDatabase(), .{ .pack_dir = pack_dir, .in = &in }, .{ .max_object_bytes = .fromRaw(cap), .threads = 1 });
    defer result.deinit(io);
    try std.testing.expect(counting.peak_bytes - before < big_len);
    try std.testing.expectEqual(@as(u32, 10), result.objects);

    const checked = try ours.run(io, &.{ "fsck", "--full", "--strict", "--no-dangling" });
    std.testing.allocator.free(checked);
}

test "a pack received again compares each object past the threshold as it reads both, and unpacking it writes each loose without holding it" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const io = std.testing.io;
    var theirs = try testgit.Repo.init(std.testing.allocator, io, &.{});
    defer theirs.deinit();
    try bigHistory(std.testing.allocator, io, &theirs);
    const stream = try theirs.run(io, &.{ "pack-objects", "-q", "--stdout", "--all", "--no-reuse-delta" });
    defer std.testing.allocator.free(stream);

    var ours = try testgit.Repo.init(std.testing.allocator, io, &.{});
    defer ours.deinit();
    try ours.exec(io, &.{ "config", "core.bigFileThreshold", "1k" });
    var counting: Counting = .init(std.testing.allocator);
    const gpa = counting.allocator();
    var repo = try repo_mod.Repository.open(gpa, io, ours.dir, .{ .odb = .{ .max_object_bytes = .fromRaw(cap) } });
    defer repo.deinit(io);
    const db = repo.objectDatabase();
    var pack_dir = try ours.dir.openDir(io, ".git/objects/pack", .{});
    defer pack_dir.close(io);
    var first_in: Io.Reader = .fixed(stream);
    var first = try index_pack.receive(gpa, io, db, .{ .pack_dir = pack_dir, .in = &first_in }, .{ .max_object_bytes = .fromRaw(cap), .threads = 1 });
    defer first.deinit(io);

    // Every name is held now: each object is compared with the one held,
    // the big ones as both are read.
    var again_in: Io.Reader = .fixed(stream);
    counting.resetPeak();
    var before = counting.live_bytes;
    var again = try index_pack.receive(gpa, io, db, .{ .pack_dir = pack_dir, .in = &again_in }, .{ .max_object_bytes = .fromRaw(cap), .threads = 1 });
    defer again.deinit(io);
    try std.testing.expect(counting.peak_bytes - before < big_len);

    var hex: [40]u8 = undefined;
    var base_buf: [64]u8 = undefined;
    const base = try std.mem.print(&base_buf, "pack-{s}", .{first.name.?.hex(&hex)});
    counting.resetPeak();
    before = counting.live_bytes;
    try db.unpackPack(io, base);
    try std.testing.expect(counting.peak_bytes - before < big_len);

    const checked = try ours.run(io, &.{ "fsck", "--full", "--strict", "--no-dangling" });
    std.testing.allocator.free(checked);
    const listed = try ours.run(io, &.{ "count-objects", "-v" });
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.startsWith(u8, listed, "count: 10\n"));
}

test "a pack writer adds an object from a reader, named as it is deflated, takes the last one back, and git reads the pack" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var pack_dir = try git.dir.openDir(io, ".git/objects/pack", .{});
    defer pack_dir.close(io);
    const first = try bigText(gpa, 3, false, big_len);
    defer gpa.free(first);
    const second = try bigText(gpa, 4, false, big_len);
    defer gpa.free(second);

    const w = try pack.Writer.open(gpa, io, pack_dir, .{ .kind = .sha1 }, .{});
    defer w.deinit(io);
    var in: Io.Reader = .fixed(first);
    const dropped = try w.addFrom(io, &in, .{ .type = .blob, .size = first.len });
    try std.testing.expect(dropped.oid.eql(hash.Hasher.object(.sha1, "blob", first)));
    try w.dropLast(io);
    in = .fixed(second);
    const kept = try w.addFrom(io, &in, .{ .type = .blob, .size = second.len, .expect = hash.Hasher.object(.sha1, "blob", second) });
    try std.testing.expectEqual(dropped.offset, kept.offset);
    // The same object again is refused and taken back.
    in = .fixed(second);
    try std.testing.expectError(error.DuplicateObject, w.addFrom(io, &in, .{ .type = .blob, .size = second.len }));
    var short: Io.Reader = .fixed(second[0..100]);
    const report = try w.finish(io);
    try std.testing.expectEqual(@as(u32, 1), report.objects);

    var hex: [40]u8 = undefined;
    var path_buf: [80]u8 = undefined;
    const idx = try std.mem.print(&path_buf, ".git/objects/pack/pack-{s}.idx", .{report.name.hex(&hex)});
    const listed = try git.run(io, &.{ "verify-pack", "-v", idx });
    defer gpa.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, kept.oid.hex(&hex)) != null);

    // A reader that ends early leaves the pack to be aborted.
    const aborted = try pack.Writer.open(gpa, io, pack_dir, .{ .kind = .sha1 }, .{});
    defer aborted.deinit(io);
    try std.testing.expectError(error.ShortRead, aborted.addFrom(io, &short, .{ .type = .blob, .size = second.len }));
}

test "verify checks each object past the threshold as it reads it, loose and packed, and finds one cut short" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const io = std.testing.io;
    var git = try testgit.Repo.init(std.testing.allocator, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "1k" });
    // Larger than the readers verify gives each task, however many.
    const verified_len = 16 << 20;
    const packed_text = try bigText(std.testing.allocator, 5, false, verified_len);
    defer std.testing.allocator.free(packed_text);
    try git.writeFile(io, "packed.txt", packed_text);
    try git.exec(io, &.{ "add", "packed.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "packed" });
    try git.exec(io, &.{ "repack", "-q", "-a", "-d" });
    const loose_text = try bigText(std.testing.allocator, 6, false, verified_len);
    defer std.testing.allocator.free(loose_text);
    try git.writeFile(io, "loose.txt", loose_text);
    // Loose: past its threshold git would write it into a pack of its own.
    const loose_hex = try git.line(io, &.{ "-c", "core.bigFileThreshold=1g", "hash-object", "-w", "loose.txt" });
    defer std.testing.allocator.free(loose_hex);

    // On one task, so the peak is counted.
    var single: Io.Threaded = .init_single_threaded;
    const one = single.io();
    var counting: Counting = .init(std.testing.allocator);
    const gpa = counting.allocator();
    var repo = try repo_mod.Repository.open(gpa, one, git.dir, .{ .odb = .{ .max_object_bytes = .fromRaw(cap) } });
    defer repo.deinit(one);
    counting.resetPeak();
    const before = counting.live_bytes;
    const report = try repo.objectDatabase().verify(one);
    try std.testing.expect(counting.peak_bytes - before < verified_len);
    try std.testing.expectEqual(@as(u32, 1), report.loose);

    // The loose object cut short is found.
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.print(&path_buf, ".git/objects/{s}/{s}", .{ loose_hex[0..2], loose_hex[2..] });
    // Loose objects are read-only: written again, cut in half.
    const whole = try git.dir.readFileAlloc(one, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(whole);
    try git.dir.deleteFile(one, path);
    try git.dir.writeFile(one, .{ .sub_path = path, .data = whole[0 .. whole.len / 2] });
    try std.testing.expectError(error.CorruptLooseObject, repo.objectDatabase().verify(one));
}

test "git pushes objects past the threshold to relic's receive-pack and clones them from its upload-pack, each held by neither" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try bigHistory(gpa, io, &source);
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const target = try gpa.print("{s}/target.git", .{root_path});
    defer gpa.free(target);
    gpa.free(try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "init", "-q", "--bare", "-b", "main", target }, "", true));
    var target_dir = try Io.Dir.cwd().openDir(io, target, .{});
    defer target_dir.close(io);
    gpa.free(try testremote.gitInputEnv(gpa, io, target_dir, &env, &.{ "config", "core.bigFileThreshold", "1k" }, "", true));
    gpa.free(try testremote.gitInputEnv(gpa, io, target_dir, &env, &.{ "config", "receive.autogc", "false" }, "", true));

    var helpers: [2][]u8 = .{ try gpa.dupe(u8, suite.path(.receive_pack_helper)), try gpa.dupe(u8, suite.path(.upload_pack_helper)) };
    defer for (helpers) |h| gpa.free(h);
    if (builtin.target.os.tag == .windows) for (&helpers) |h| std.mem.replaceScalar(u8, h, '\\', '/');

    // Ten objects, under receive.unpackLimit: received and unpacked loose,
    // the big ones from the pack as they are read.
    const pushed = try gpa.print("--receive-pack={s}", .{helpers[0]});
    defer gpa.free(pushed);
    gpa.free(try testremote.gitInputEnv(gpa, io, source.dir, &env, &.{ "push", "-q", pushed, target, "main" }, "", true));
    gpa.free(try testremote.gitInputEnv(gpa, io, target_dir, &env, &.{ "fsck", "--full", "--strict", "--no-dangling" }, "", true));
    const counted = try testremote.gitInputEnv(gpa, io, target_dir, &env, &.{ "count-objects", "-v" }, "", true);
    defer gpa.free(counted);
    try std.testing.expect(std.mem.startsWith(u8, counted, "count: 10\n"));

    // Cloned from relic's upload-pack: the big objects go into the pack it
    // writes from the loose files, deflated as they are read.
    const url = try gpa.print("file://{s}", .{target});
    defer gpa.free(url);
    const uploaded = try gpa.print("--upload-pack={s}", .{helpers[1]});
    defer gpa.free(uploaded);
    gpa.free(try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "clone", "-q", "--no-checkout", uploaded, url, "clone" }, "", true));
    var clone = try root.dir.openDir(io, "clone", .{});
    defer clone.close(io);
    gpa.free(try testremote.gitInputEnv(gpa, io, clone, &env, &.{ "fsck", "--full", "--strict", "--no-dangling" }, "", true));
    const theirs = try testremote.gitInputEnv(gpa, io, source.dir, &env, &.{ "rev-list", "--objects", "--all" }, "", true);
    defer gpa.free(theirs);
    const ours = try testremote.gitInputEnv(gpa, io, clone, &env, &.{ "rev-list", "--objects", "--all" }, "", true);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
}
