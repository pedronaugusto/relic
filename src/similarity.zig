//! How much of one blob another is made of, scored exactly as git's rename
//! detection scores it.
//!
//! A merge that follows renames pairs a deleted path with an added one when
//! the added one is at least half made of the deleted one, and "half" is
//! git's measure, not any reasonable one: both blobs are cut into spans that
//! end at a newline or after sixty-four bytes, each span is hashed into one
//! of 107927 buckets with git's own rolling hash -- so two different spans
//! that land in one bucket count as the same, as they do in git -- and the
//! score is the material the two share over the larger size, out of 60000.
//! A carriage return before a newline is left out of a text blob's spans,
//! and a pair whose sizes differ too much for the minimum is scored zero
//! without being read. Only regular files are scored; git pairs anything
//! else only when it is identical.

const std = @import("std");
const Allocator = std.mem.Allocator;

const textdiff = @import("textdiff.zig");

/// A perfect score: the whole of the larger blob is shared.
pub const max_score: u32 = 60000;
/// The score git pairs a rename at unless told otherwise: half.
pub const default_minimum: u32 = 30000;

/// git's `HASHBASE`: the number of buckets a span hashes into.
const hash_base: u32 = 107927;

/// The score of `dst` as made from `src`, from 0 to `max_score`, as git's
/// `estimate_similarity` gives it. A pair whose sizes alone rule out
/// `minimum` scores 0.
pub fn score(gpa: Allocator, src: []const u8, dst: []const u8, minimum: u32) Allocator.Error!u32 {
    const max_size: u64 = @max(src.len, dst.len);
    const base_size: u64 = @min(src.len, dst.len);
    const delta_size = max_size - base_size;
    if (max_size * (max_score - minimum) < delta_size * max_score) return 0;
    if (dst.len == 0) return 0;

    var src_counts: Counts = .empty;
    defer src_counts.deinit(gpa);
    try countSpans(gpa, src, &src_counts);
    var dst_counts: Counts = .empty;
    defer dst_counts.deinit(gpa);
    try countSpans(gpa, dst, &dst_counts);

    var copied: u64 = 0;
    var it = src_counts.iterator();
    while (it.next()) |entry| {
        const in_dst = dst_counts.get(entry.key_ptr.*) orelse 0;
        copied += @min(entry.value_ptr.*, in_dst);
    }
    return @intCast(copied * max_score / max_size);
}

/// Bytes of span per bucket.
const Counts = std.AutoHashMapUnmanaged(u32, u64);

/// git's `hash_chars`: cut `bytes` into spans and count each span's length
/// against its bucket.
fn countSpans(gpa: Allocator, bytes: []const u8, counts: *Counts) Allocator.Error!void {
    const is_text = !textdiff.isBinary(bytes);
    var n: u64 = 0;
    var accum1: u32 = 0;
    var accum2: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c: u32 = bytes[i];
        const old_1 = accum1;
        // A carriage return before a newline is not counted in text.
        if (is_text and c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        accum1 = (accum1 << 7) ^ (accum2 >> 25);
        accum2 = (accum2 << 7) ^ (old_1 >> 25);
        accum1 +%= c;
        n += 1;
        if (n < 64 and c != '\n') continue;
        try add(gpa, counts, accum1, accum2, n);
        n = 0;
        accum1 = 0;
        accum2 = 0;
    }
    if (n > 0) try add(gpa, counts, accum1, accum2, n);
}

fn add(gpa: Allocator, counts: *Counts, accum1: u32, accum2: u32, n: u64) Allocator.Error!void {
    const bucket = (accum1 +% accum2 *% 0x61) % hash_base;
    const slot = try counts.getOrPut(gpa, bucket);
    if (!slot.found_existing) slot.value_ptr.* = 0;
    slot.value_ptr.* += n;
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("testgit.zig");

test "scores are the ones git's rename detection prints" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    var dst: std.ArrayList(u8) = .empty;
    defer dst.deinit(gpa);
    var paired: usize = 0;
    var apart: usize = 0;
    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta\r", "", "a very long line that runs well past sixty-four bytes before it ever reaches its end" };
    for (0..40) |round| {
        src.clearRetainingCapacity();
        dst.clearRetainingCapacity();
        const lines = 1 + random.uintLessThan(usize, 40);
        for (0..lines) |_| {
            const word = words[random.uintLessThan(usize, words.len)];
            try src.appendSlice(gpa, word);
            if (random.uintLessThan(u8, 8) != 0) try src.append(gpa, '\n');
        }
        // The destination keeps some of the source's lines and adds its own.
        var lines_iter = std.mem.splitScalar(u8, src.items, '\n');
        while (lines_iter.next()) |line| {
            if (random.uintLessThan(u8, 4) == 0) continue;
            try dst.appendSlice(gpa, line);
            try dst.append(gpa, '\n');
            if (random.uintLessThan(u8, 5) == 0) try dst.appendSlice(gpa, "inserted\n");
        }
        if (round % 7 == 0) try dst.append(gpa, 0);

        try repo.writeFile(io, "src", src.items);
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "src" });
        try repo.dir.deleteFile(io, "src");
        try repo.writeFile(io, "dst", dst.items);
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "dst" });
        // `-M1%` pairs at almost any score, so the pairing shows the score.
        const status = try repo.run(io, &.{ "diff", "-M1%", "--name-status", "HEAD~", "HEAD" });
        defer gpa.free(status);
        const got = try score(gpa, src.items, dst.items, max_score / 100);
        var expected: []const u8 = "none";
        var buf: [16]u8 = undefined;
        if (std.mem.startsWith(u8, status, "R")) {
            expected = status[1..std.mem.indexOfScalar(u8, status, '\t').?];
            paired += 1;
        } else apart += 1;
        const shown: []const u8 = if (got >= max_score / 100 and !std.mem.eql(u8, src.items, dst.items))
            try std.fmt.bufPrint(&buf, "{d:0>3}", .{got * 100 / max_score})
        else if (std.mem.eql(u8, src.items, dst.items)) "100" else "none";
        std.testing.expectEqualStrings(expected, shown) catch |err| {
            std.debug.print("round {d}: git says {s}\n", .{ round, status });
            return err;
        };
        try repo.exec(io, &.{ "rm", "-q", "dst" });
        try repo.exec(io, &.{ "commit", "-q", "-m", "clear" });
    }
    // Both outcomes were seen, so the comparison covered both.
    try std.testing.expect(paired >= 10 and apart >= 1);
}

test "sizes too far apart score zero unread, and an empty destination scores zero" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 0), try score(gpa, "a\n", "a\nb\nc\nd\n", default_minimum));
    try std.testing.expectEqual(@as(u32, 0), try score(gpa, "", "", default_minimum));
    try std.testing.expectEqual(max_score, try score(gpa, "same\n", "same\n", default_minimum));
    // A carriage return before a newline is not material in text.
    try std.testing.expect(try score(gpa, "one\r\ntwo\r\n", "one\ntwo\n", 0) > default_minimum);
}
