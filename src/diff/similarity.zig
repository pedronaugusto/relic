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

const attributes = @import("../patterns/attributes.zig");

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
    if (sizesRuleOut(src.len, dst.len, minimum)) return 0;
    var src_spans = try spans(gpa, src);
    defer src_spans.deinit(gpa);
    var dst_spans = try spans(gpa, dst);
    defer dst_spans.deinit(gpa);
    return scoreSpans(&src_spans, &dst_spans, minimum);
}

/// Whether blobs of these sizes cannot reach `minimum`, or the destination
/// is empty: the pair scores 0 without either being read.
pub fn sizesRuleOut(src_len: usize, dst_len: usize, minimum: u32) bool {
    const max_size: u64 = @max(src_len, dst_len);
    const base_size: u64 = @min(src_len, dst_len);
    const delta_size = max_size - base_size;
    if (max_size * (max_score - minimum) < delta_size * max_score) return true;
    return dst_len == 0;
}

/// One bucket of a blob's spans, and how many bytes of span landed in it.
pub const Span = struct {
    bucket: u32,
    bytes: u64,
};

/// A blob cut into spans and counted, once: what git keeps on a file as
/// its `cnt_data`, so that a blob scored against a hundred others is cut
/// up once and not a hundred times. Sorted by bucket, so two are compared
/// in one pass over both.
pub const Spans = struct {
    /// The blob's size.
    size: usize,
    entries: []Span,

    pub fn deinit(s: *Spans, gpa: Allocator) void {
        gpa.free(s.entries);
        s.* = undefined;
    }
};

/// The score `score` gives, from the two blobs' spans.
pub fn scoreSpans(src: *const Spans, dst: *const Spans, minimum: u32) u32 {
    if (sizesRuleOut(src.size, dst.size, minimum)) return 0;
    const max_size: u64 = @max(src.size, dst.size);
    var copied: u64 = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.entries.len and j < dst.entries.len) {
        const a = src.entries[i];
        const b = dst.entries[j];
        if (a.bucket < b.bucket) {
            i += 1;
        } else if (a.bucket > b.bucket) {
            j += 1;
        } else {
            copied += @min(a.bytes, b.bytes);
            i += 1;
            j += 1;
        }
    }
    return @intCast(copied * max_score / max_size);
}

/// git's `hash_chars`: cut `bytes` into spans and count each span's length
/// against its bucket. The result is the caller's.
pub fn spans(gpa: Allocator, bytes: []const u8) Allocator.Error!Spans {
    var list: std.ArrayList(Span) = .empty;
    defer list.deinit(gpa);
    const is_text = !attributes.isBinaryForDiff(bytes);
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
        try list.append(gpa, .{ .bucket = bucketOf(accum1, accum2), .bytes = n });
        n = 0;
        accum1 = 0;
        accum2 = 0;
    }
    if (n > 0) try list.append(gpa, .{ .bucket = bucketOf(accum1, accum2), .bytes = n });

    // One entry per bucket, in bucket order.
    std.mem.sort(Span, list.items, {}, lessBucket);
    var kept: usize = 0;
    for (list.items) |span| {
        if (kept != 0 and list.items[kept - 1].bucket == span.bucket) {
            list.items[kept - 1].bytes += span.bytes;
        } else {
            list.items[kept] = span;
            kept += 1;
        }
    }
    list.shrinkRetainingCapacity(kept);
    return .{ .size = bytes.len, .entries = try list.toOwnedSlice(gpa) };
}

fn bucketOf(accum1: u32, accum2: u32) u32 {
    return (accum1 +% accum2 *% 0x61) % hash_base;
}

fn lessBucket(_: void, a: Span, b: Span) bool {
    return a.bucket < b.bucket;
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("../testing/git.zig");

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
            expected = status[1..std.mem.findScalar(u8, status, '\t').?];
            paired += 1;
        } else apart += 1;
        const shown: []const u8 = if (got >= max_score / 100 and !std.mem.eql(u8, src.items, dst.items))
            try std.mem.print(&buf, "{d:0>3}", .{got * 100 / max_score})
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
