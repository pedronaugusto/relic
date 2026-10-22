//! Objects past `core.bigFileThreshold` received without being held
//! (designs/relic.md §10), against git 2.55: index-pack names such an entry
//! as it inflates it, under an object cap and an allocator peak below the
//! objects' size.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const Counting = @import("shakedown").alloc.Counting;
const repo_mod = @import("../repo/repo.zig");
const index_pack = @import("../odb/index_pack.zig");

/// How large each big object is: past the threshold and the cap below,
/// and past what the allocator may hold at once.
const big_len = 1 << 20;
/// The object cap the repository is opened with: anything read whole past
/// it fails.
const cap: u64 = 16 << 10;

/// `big_len` bytes of lines no two alike, from `seed`; `changed` alters
/// one line in the middle, so two versions delta well.
fn bigText(gpa: Allocator, seed: u64, changed: bool) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const text = try gpa.alloc(u8, big_len);
    var at: usize = 0;
    var line: usize = 0;
    while (at < text.len) : (line += 1) {
        var buf: [40]u8 = undefined;
        const value = if (changed and line == 700) 0 else prng.random().int(u64);
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
        const text = try bigText(gpa, 1, changed);
        defer gpa.free(text);
        try git.writeFile(io, "big.txt", text);
        try git.exec(io, &.{ "add", "big.txt" });
        try git.exec(io, &.{ "commit", "-q", "-m", "big" });
    }
    try git.exec(io, &.{ "repack", "-q", "-a", "-d", "-f" });
    const loose = try bigText(gpa, 2, false);
    defer gpa.free(loose);
    try git.writeFile(io, "other.txt", loose);
    try git.writeFile(io, "small.txt", "small\n");
    try git.exec(io, &.{ "add", "other.txt", "small.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "loose" });
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "1k" });
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
