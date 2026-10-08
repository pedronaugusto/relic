//! The delta encoding a packfile uses.
//!
//! A delta is two sizes and then a list of commands: copy a run from the base,
//! or insert bytes carried in the delta. Two rules catch reimplementers, and
//! both are here: an omitted offset or size byte does not renumber the bytes
//! after it, and a copy size of zero means 0x10000.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from reading or applying a delta.
pub const Error = error{
    /// A size or a command ran off the end of the delta.
    TruncatedDelta,
    /// The delta's stated source size is not the base's length.
    DeltaBaseSizeMismatch,
    /// A copy command reached past the end of the base.
    DeltaCopyOutOfRange,
    /// The commands produced more or fewer bytes than the stated target
    /// size.
    DeltaResultSizeMismatch,
    /// Command byte zero, which git reserves and never writes.
    InvalidDeltaCommand,
    /// A size varint wider than 64 bits.
    DeltaSizeOverflow,
    /// The stated result exceeds `max_result_bytes` or the address space.
    DeltaSizeLimitExceeded,
};

/// A little-endian 7-bits-per-byte varint, the one a delta uses for its two
/// sizes. Returns the value and how many bytes it took.
pub fn readSize(bytes: []const u8) Error!struct { value: u64, len: usize } {
    var value: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (true) {
        if (i >= bytes.len) return error.TruncatedDelta;
        const byte = bytes[i];
        i += 1;
        const part: u64 = byte & 0x7f;
        const shifted = std.math.shlExact(u64, part, shift) catch return error.DeltaSizeOverflow;
        value |= shifted;
        if (byte & 0x80 == 0) break;
        if (shift > 56) return error.DeltaSizeOverflow;
        shift += 7;
    }
    return .{ .value = value, .len = i };
}

/// The two sizes at the head of a delta: the base it applies to and the
/// object it produces.
pub const Sizes = struct {
    source: u64,
    target: u64,
    /// Where the commands begin.
    len: usize,
};

/// Read a delta's header without applying it.
pub fn header(delta: []const u8) Error!Sizes {
    const source = try readSize(delta);
    const target = try readSize(delta[source.len..]);
    return .{
        .source = source.value,
        .target = target.value,
        .len = source.len + target.len,
    };
}

/// Errors from `applyTo`.
pub const ApplyToError = Error || Allocator.Error;

/// Apply `delta` to `base`, appending the result to `out`.
///
/// `out` is expected to be empty or to be appended to deliberately; the
/// produced length is checked against the delta's stated target size, so a
/// delta that lies about its own output is a named error rather than a short
/// object. A result over `max_result_bytes` or the address space is
/// `DeltaSizeLimitExceeded`, checked before reserving any output.
pub fn applyTo(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    base: []const u8,
    delta: []const u8,
) ApplyToError!void {
    const sizes = try header(delta);
    if (sizes.source != base.len) return error.DeltaBaseSizeMismatch;
    if (sizes.target > max_result_bytes) return error.DeltaSizeLimitExceeded;
    const target = std.math.cast(usize, sizes.target) orelse return error.DeltaSizeLimitExceeded;
    const start = out.items.len;
    try out.ensureUnusedCapacity(gpa, target);

    var i: usize = sizes.len;
    while (i < delta.len) {
        const op = delta[i];
        i += 1;
        if (op == 0) return error.InvalidDeltaCommand;
        if (op & 0x80 != 0) {
            // Copy. Each set bit in the low nibble supplies one byte of the
            // offset and each of the next three one byte of the size, in
            // rising significance; a bit that is clear contributes a zero
            // byte and does not shift the ones that follow.
            var offset: u64 = 0;
            var size: u64 = 0;
            inline for (0..4) |shift| {
                if (op & (@as(u8, 1) << shift) != 0) {
                    if (i >= delta.len) return error.TruncatedDelta;
                    offset |= @as(u64, delta[i]) << (8 * shift);
                    i += 1;
                }
            }
            inline for (0..3) |shift| {
                if (op & (@as(u8, 0x10) << shift) != 0) {
                    if (i >= delta.len) return error.TruncatedDelta;
                    size |= @as(u64, delta[i]) << (8 * shift);
                    i += 1;
                }
            }
            if (size == 0) size = 0x10000;
            const end = std.math.add(u64, offset, size) catch return error.DeltaCopyOutOfRange;
            if (end > base.len) return error.DeltaCopyOutOfRange;
            if (out.items.len - start + size > sizes.target) return error.DeltaResultSizeMismatch;
            out.appendSliceAssumeCapacity(base[@intCast(offset)..@intCast(end)]);
        } else {
            // Insert: the command byte is the count, one to 127.
            const n = op;
            if (i + n > delta.len) return error.TruncatedDelta;
            if (out.items.len - start + n > sizes.target) return error.DeltaResultSizeMismatch;
            out.appendSliceAssumeCapacity(delta[i..][0..n]);
            i += n;
        }
    }
    if (out.items.len - start != sizes.target) return error.DeltaResultSizeMismatch;
}

/// The largest object a delta is allowed to produce, so a crafted delta
/// cannot ask for the address space. Four gigabytes; git's own packs do not
/// approach it.
pub const max_result_bytes: u64 = 4 << 30;

/// Errors from `apply`.
pub const ApplyError = Error || Allocator.Error;

/// Apply `delta` to `base`. The result is the caller's.
pub fn apply(gpa: Allocator, base: []const u8, delta: []const u8) ApplyError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try applyTo(gpa, &out, base, delta);
    return out.toOwnedSlice(gpa);
}

//=====================================================================
// Writing a delta
//
// A delta is worth writing when it is shorter than the object it replaces,
// and finding one is a matter of finding long runs of the target that are
// already somewhere in the base. The base is indexed by its sixteen-byte
// blocks; the target is walked, each position looked up, and the longest
// match taken.
//
// Nothing about correctness depends on the index: a worse one finds shorter
// matches and writes a longer delta. What it does have to be is exact about
// the two encodings, which is what the suite checks by decoding every delta
// it writes.
//=====================================================================

/// How many bytes of the target must match for a copy to be worth a command.
///
/// git's own value, and the width of the block the base is indexed by.
pub const match_len = 16;

/// The most bytes one copy command can carry: three size bytes.
const max_copy = 0xff_ffff;

/// The most literal bytes one insert command can carry: the command byte is
/// the count and the high bit says it is a copy.
const max_insert = 0x7f;

/// How many candidate positions one lookup walks before it settles for what
/// it has. A cap, so a base full of one repeated block cannot make the search
/// quadratic.
const max_candidates = 64;

/// How a delta is looked for.
pub const EncodeOptions = struct {
    /// Give up and return `null` once the delta has grown past this many
    /// bytes. Zero means no limit.
    ///
    /// A delta longer than the object it stands in for is not worth writing,
    /// and stopping at the limit rather than at the end saves the rest of the
    /// search.
    max_bytes: usize = 0,
};

/// A delta that turns `base` into `target`, or `null` if it grew past
/// `options.max_bytes` before it was finished.
///
/// The result is the caller's.
pub fn encode(
    gpa: Allocator,
    base: []const u8,
    target: []const u8,
    options: EncodeOptions,
) Allocator.Error!?[]u8 {
    var encoder = try Encoder.init(gpa, base);
    defer encoder.deinit(gpa);
    return encoder.encode(gpa, target, options);
}

/// A base indexed once for several delta searches.
///
/// A pack window tries several targets against the same base. Keeping this
/// value beside that base avoids rebuilding its sixteen-byte-block index for
/// every comparison. `base` must outlive the encoder.
pub const Encoder = struct {
    pub const Error = ErrorNamespace.Error;

    base: []const u8,
    index: Index,

    /// Index `base` for later searches.
    pub fn init(gpa: Allocator, base: []const u8) Allocator.Error!Encoder {
        return .{ .base = base, .index = try .build(gpa, base) };
    }

    /// Release the base index. The base itself remains the caller's.
    pub fn deinit(encoder: *Encoder, gpa: Allocator) void {
        encoder.index.deinit(gpa);
        encoder.* = undefined;
    }

    /// Encode `target` against the indexed base, or return `null` at the
    /// configured size limit. The result is the caller's.
    pub fn encode(
        encoder: *const Encoder,
        gpa: Allocator,
        target: []const u8,
        options: EncodeOptions,
    ) Allocator.Error!?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (!try encoder.encodeInto(gpa, target, options, &out)) {
            out.deinit(gpa);
            return null;
        }
        const value = try out.toOwnedSlice(gpa);
        return value;
    }

    /// `encode` into `out`, which is cleared first and keeps its capacity,
    /// so that one buffer serves many searches: whether the delta fit
    /// `options.max_bytes`. When it did, the delta is `out.items`.
    pub fn encodeInto(
        encoder: *const Encoder,
        gpa: Allocator,
        target: []const u8,
        options: EncodeOptions,
        out: *std.ArrayList(u8),
    ) Allocator.Error!bool {
        out.clearRetainingCapacity();
        try writeSizeTo(gpa, out, encoder.base.len);
        try writeSizeTo(gpa, out, target.len);

        var pending_at: usize = 0;
        var at: usize = 0;
        var window_hash: ?u64 = null;
        while (at < target.len) {
            if (target.len - at < match_len) break;
            const current_hash = window_hash orelse Index.hashWindow(target[at..][0..match_len]);
            const found = encoder.index.longestAt(encoder.base, target, at, current_hash);
            if (found.len < match_len) {
                at += 1;
                window_hash = if (target.len - at >= match_len)
                    Index.rollWindow(current_hash, target[at - 1], target[at + match_len - 1])
                else
                    null;
                continue;
            }
            try flushInsert(gpa, out, target[pending_at..at]);
            var left = found.len;
            var from = found.at;
            while (left != 0) {
                const chunk = @min(left, max_copy);
                try emitCopy(gpa, out, @intCast(from), @intCast(chunk));
                from += chunk;
                left -= chunk;
            }
            at += found.len;
            pending_at = at;
            window_hash = null;
            if (options.max_bytes != 0 and out.items.len > options.max_bytes) return false;
        }
        try flushInsert(gpa, out, target[pending_at..]);
        return options.max_bytes == 0 or out.items.len <= options.max_bytes;
    }
};

fn writeSizeTo(gpa: Allocator, out: *std.ArrayList(u8), size: usize) Allocator.Error!void {
    var value = size;
    while (true) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        try out.append(gpa, byte);
        if (value == 0) break;
    }
}

fn flushInsert(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    var rest = bytes;
    while (rest.len != 0) {
        const chunk = @min(rest.len, max_insert);
        try out.append(gpa, @intCast(chunk));
        try out.appendSlice(gpa, rest[0..chunk]);
        rest = rest[chunk..];
    }
}

/// One copy command: the low nibble says which bytes of the offset follow and
/// the next three bits which bytes of the size. A byte that is zero is left
/// out and does not renumber the ones after it, which is the rule that
/// catches reimplementers of the decoder and the encoder alike.
fn emitCopy(gpa: Allocator, out: *std.ArrayList(u8), offset: u32, size: u32) Allocator.Error!void {
    std.debug.assert(size != 0);
    std.debug.assert(size <= max_copy);
    var buf: [8]u8 = undefined;
    var n: usize = 1;
    var cmd: u8 = 0x80;
    inline for (0..4) |shift| {
        const byte: u8 = @truncate(offset >> (8 * shift));
        if (byte != 0) {
            cmd |= @as(u8, 1) << shift;
            buf[n] = byte;
            n += 1;
        }
    }
    inline for (0..3) |shift| {
        const byte: u8 = @truncate(size >> (8 * shift));
        if (byte != 0) {
            cmd |= @as(u8, 0x10) << shift;
            buf[n] = byte;
            n += 1;
        }
    }
    buf[0] = cmd;
    try out.appendSlice(gpa, buf[0..n]);
}

/// The base's sixteen-byte blocks, by hash.
const Index = struct {
    /// For each hash bucket, the last block that landed in it, or
    /// `sentinel`.
    head: []u32,
    /// For each block, the previous block in its bucket.
    chain: []u32,
    mask: u32,

    const sentinel: u32 = std.math.maxInt(u32);
    const hash_base: u64 = 0x9e37_79b1_85eb_ca87;
    const outgoing_factor: u64 = blk: {
        var factor: u64 = 1;
        for (1..match_len) |_| factor *%= hash_base;
        break :blk factor;
    };

    fn build(gpa: Allocator, base: []const u8) Allocator.Error!Index {
        const blocks = base.len / match_len;
        // Small bases need enough buckets that unrelated targets seldom
        // reach a candidate chain. Sixteen KiB avoids that hot-loop work.
        var size: u32 = 4096;
        while (size < blocks and size < (1 << 20)) size <<= 1;
        const head = try gpa.alloc(u32, size);
        errdefer gpa.free(head);
        @memset(head, sentinel);
        const chain = try gpa.alloc(u32, blocks);
        errdefer gpa.free(chain);
        @memset(chain, sentinel);

        var index: Index = .{ .head = head, .chain = chain, .mask = size - 1 };
        var block: u32 = 0;
        while (block < blocks) : (block += 1) {
            const at = @as(usize, block) * match_len;
            const bucket = index.bucketOfHash(hashWindow(base[at..][0..match_len]));
            index.chain[block] = index.head[bucket];
            index.head[bucket] = block;
        }
        return index;
    }

    fn deinit(index: *Index, gpa: Allocator) void {
        gpa.free(index.head);
        gpa.free(index.chain);
        index.* = undefined;
    }

    fn hashWindow(bytes: *const [match_len]u8) u64 {
        var value: u64 = 0;
        for (bytes) |byte| value = value *% hash_base +% byte;
        return value;
    }

    fn rollWindow(value: u64, outgoing: u8, incoming: u8) u64 {
        return (value -% (@as(u64, outgoing) *% outgoing_factor)) *% hash_base +% incoming;
    }

    fn bucketOfHash(index: *const Index, value: u64) u32 {
        const mixed = value ^ (value >> 32) ^ (value >> 17);
        return @intCast(mixed & index.mask);
    }

    const Match = struct {
        /// Where in the base the run starts.
        at: usize,
        /// How long it is. Below `match_len` means there was no match worth
        /// a command.
        len: usize,
    };

    /// The longest run of `target` from `at` that the base also holds.
    fn longestAt(index: *const Index, base: []const u8, target: []const u8, at: usize, window_hash: u64) Match {
        const bucket = index.bucketOfHash(window_hash);
        var best: Match = .{ .at = 0, .len = 0 };
        var block = index.head[bucket];
        var looked: u32 = 0;
        while (block != sentinel and looked < max_candidates) : (looked += 1) {
            const candidate = @as(usize, block) * match_len;
            block = index.chain[block];
            var len: usize = 0;
            const room = @min(base.len - candidate, target.len - at);
            if (base[candidate] != target[at]) continue;
            // Compare whole words where both slices have room. The first
            // differing byte still ends the match, so delta choice and its
            // encoded bytes are unchanged, including at unaligned targets.
            while (room - len >= 8) : (len += 8) {
                const different = std.mem.readInt(u64, base[candidate + len ..][0..8], .little) ^
                    std.mem.readInt(u64, target[at + len ..][0..8], .little);
                if (different != 0) {
                    len += @ctz(different) / 8;
                    break;
                }
            }
            while (len < room and base[candidate + len] == target[at + len]) len += 1;
            if (len > best.len) best = .{ .at = candidate, .len = len };
            if (best.len == target.len - at) break;
        }
        return best;
    }
};

test "a delta this writes is a delta this applies" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x0de1_7a00);
    const random = prng.random();

    const base = try gpa.alloc(u8, 40_000);
    defer gpa.free(base);
    for (base, 0..) |*b, i| b.* = @truncate(i / 37 + (i % 7) * 11);

    const cases: []const struct { name: []const u8, build: u8 } = &.{
        .{ .name = "identical", .build = 0 },
        .{ .name = "a suffix added", .build = 1 },
        .{ .name = "a prefix added", .build = 2 },
        .{ .name = "a hole in the middle", .build = 3 },
        .{ .name = "shuffled halves", .build = 4 },
        .{ .name = "nothing in common", .build = 5 },
        .{ .name = "empty", .build = 6 },
    };
    for (cases) |c| {
        var target: std.ArrayList(u8) = .empty;
        defer target.deinit(gpa);
        switch (c.build) {
            0 => try target.appendSlice(gpa, base),
            1 => {
                try target.appendSlice(gpa, base);
                for (0..5000) |_| try target.append(gpa, random.int(u8));
            },
            2 => {
                for (0..5000) |_| try target.append(gpa, random.int(u8));
                try target.appendSlice(gpa, base);
            },
            3 => {
                try target.appendSlice(gpa, base[0 .. base.len / 3]);
                try target.appendSlice(gpa, base[2 * base.len / 3 ..]);
            },
            4 => {
                try target.appendSlice(gpa, base[base.len / 2 ..]);
                try target.appendSlice(gpa, base[0 .. base.len / 2]);
            },
            5 => for (0..20_000) |_| try target.append(gpa, random.int(u8)),
            else => {},
        }
        const written = (try encode(gpa, base, target.items, .{})).?;
        defer gpa.free(written);
        const back = try apply(gpa, base, written);
        defer gpa.free(back);
        try std.testing.expectEqualSlices(u8, target.items, back);

        // The cases that share anything must actually be shorter than the
        // object they stand in for, or there would be no reason to write one.
        if (c.build <= 4) {
            try std.testing.expect(written.len < target.items.len);
        }
    }
}

test "a delta longer than the limit is given up on" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x0de1_7a01);
    const base = try gpa.alloc(u8, 4096);
    defer gpa.free(base);
    prng.random().bytes(base);
    const target = try gpa.alloc(u8, 4096);
    defer gpa.free(target);
    prng.random().bytes(target);

    // Two blocks of noise share nothing, so the delta is the whole target
    // plus its commands, which is past any limit worth taking.
    try std.testing.expect((try encode(gpa, base, target, .{ .max_bytes = 512 })) == null);
    const unlimited = (try encode(gpa, base, target, .{})).?;
    defer gpa.free(unlimited);
    const exact = (try encode(gpa, base, target, .{ .max_bytes = unlimited.len })).?;
    defer gpa.free(exact);
    try std.testing.expectEqualSlices(u8, unlimited, exact);
    try std.testing.expect((try encode(gpa, base, target, .{ .max_bytes = unlimited.len - 1 })) == null);
    const back = try apply(gpa, base, unlimited);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, target, back);
}

test "the delta index hash rolls one byte at a time" {
    const bytes = "the quick brown fox jumps over the lazy dog";
    var rolled = Index.hashWindow(bytes[0..match_len]);
    for (1..bytes.len - match_len + 1) |at| {
        rolled = Index.rollWindow(rolled, bytes[at - 1], bytes[at + match_len - 1]);
        try std.testing.expectEqual(Index.hashWindow(bytes[at..][0..match_len]), rolled);
    }
}

test "a copy longer than one command is split into several" {
    const gpa = std.testing.allocator;
    // Longer than one copy command can carry, so the encoder has to emit
    // more than one and the decoder has to put them back together.
    const len = max_copy + 4096;
    const base = try gpa.alloc(u8, len);
    defer gpa.free(base);
    for (base, 0..) |*b, i| b.* = @truncate(i * 31 + i / 251);

    const written = (try encode(gpa, base, base, .{})).?;
    defer gpa.free(written);
    const back = try apply(gpa, base, written);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, base, back);
}

test "fuzz: a delta this writes decodes back to what it was written from" {
    try std.testing.fuzz({}, fuzzEncode, .{});
}

fn fuzzEncode(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var base_buf: [512]u8 = undefined;
    var target_buf: [512]u8 = undefined;
    const base = base_buf[0..smith.slice(&base_buf)];
    const target = target_buf[0..smith.slice(&target_buf)];

    const written = (try encode(gpa, base, target, .{})) orelse return;
    defer gpa.free(written);
    const back = try apply(gpa, base, written);
    defer gpa.free(back);
    if (!std.mem.eql(u8, target, back)) return error.DeltaDidNotRoundTrip;
}

test "a copy with an omitted byte does not renumber the ones after it" {
    const gpa = std.testing.allocator;
    const base = "0123456789";
    // source 10, target 5, copy with offset byte 1 set (offset=5) and size
    // byte 1 set (size=5).
    const delta = [_]u8{ 10, 5, 0x80 | 0x01 | 0x10, 5, 5 };
    const out = try apply(gpa, base, &delta);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("56789", out);
}

test "a copy size of zero means 0x10000" {
    const gpa = std.testing.allocator;
    const base = try gpa.alloc(u8, 0x10000);
    defer gpa.free(base);
    @memset(base, 'x');
    // source 0x10000 (varint 0x80,0x80,0x04), target the same, copy with no
    // size bytes at all.
    const delta = [_]u8{ 0x80, 0x80, 0x04, 0x80, 0x80, 0x04, 0x80 };
    const out = try apply(gpa, base, &delta);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0x10000), out.len);
    try std.testing.expect(std.mem.allEqual(u8, out, 'x'));
}

test "insert and copy together" {
    const gpa = std.testing.allocator;
    const base = "hello world";
    // target: "HELLO world" -> insert 5, copy 6 from offset 5
    const delta = [_]u8{ 11, 11, 5, 'H', 'E', 'L', 'L', 'O', 0x80 | 0x01 | 0x10, 5, 6 };
    const out = try apply(gpa, base, &delta);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("HELLO world", out);
}

test "a lying delta is a named error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DeltaBaseSizeMismatch, apply(gpa, "abc", &[_]u8{ 9, 1, 1, 'x' }));
    try std.testing.expectError(error.InvalidDeltaCommand, apply(gpa, "abc", &[_]u8{ 3, 1, 0 }));
    try std.testing.expectError(error.TruncatedDelta, apply(gpa, "abc", &[_]u8{ 3, 4, 4, 'x' }));
    try std.testing.expectError(
        error.DeltaCopyOutOfRange,
        apply(gpa, "abc", &[_]u8{ 3, 9, 0x80 | 0x01 | 0x10, 2, 9 }),
    );
    try std.testing.expectError(error.DeltaResultSizeMismatch, apply(gpa, "abc", &[_]u8{ 3, 9, 1, 'x' }));
}

test "fuzz: any bytes are a value or a named error" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [512]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var base_buf: [64]u8 = undefined;
    @memset(&base_buf, 'a');
    for (0..64) |n| {
        const out = apply(gpa, base_buf[0..n], input) catch continue;
        gpa.free(out);
    }
}

test "a valid delta over the result limit is not a size overflow" {
    const gpa = std.testing.allocator;
    const base: [0x10000]u8 = @splat('a');
    // 65 536 copies of 65 536 bytes, then one inserted byte: 4 GiB + 1.
    const delta = [_]u8{ 0x80, 0x80, 0x04, 0x81, 0x80, 0x80, 0x80, 0x10 } ++
        (@as([0x10000]u8, @splat(0x80))) ++ [_]u8{ 1, 'x' };
    const sizes = try header(&delta);
    try std.testing.expectEqual(max_result_bytes + 1, sizes.target);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "prefix");
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.DeltaSizeLimitExceeded, applyTo(failing.allocator(), &out, &base, &delta));
    try std.testing.expectEqualStrings("prefix", out.items);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectError(error.DeltaSizeLimitExceeded, apply(gpa, &base, &delta));
    // At the policy limit, a failure to reserve the result is a resource failure.
    const at_limit = [_]u8{ 0x80, 0x80, 0x04, 0x80, 0x80, 0x80, 0x80, 0x10 } ++
        (@as([0x10000]u8, @splat(0x80)));
    var empty: std.ArrayList(u8) = .empty;
    try std.testing.expectError(if (@sizeOf(usize) > 4) error.OutOfMemory else error.DeltaSizeLimitExceeded, applyTo(failing.allocator(), &empty, &base, &at_limit));
    // A size that does not fit the wire's u64 is still malformed input.
    try std.testing.expectError(error.DeltaSizeOverflow, readSize(&(@as([9]u8, @splat(0xff)) ++ [_]u8{2})));
}

test "delta matches stop at each byte of an unaligned word and at the tail" {
    const gpa = std.testing.allocator;
    var base: [160]u8 = undefined;
    for (&base, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    var index = try Index.build(gpa, &base);
    defer index.deinit(gpa);
    var target: [170]u8 = undefined;
    for ([_]usize{ 0, 1, 7 }) |start| {
        for (16..base.len + 1) |end| {
            @memcpy(target[start..][0..base.len], &base);
            if (end < base.len) target[start + end] ^= 1;
            const found = index.longestAt(&base, target[0 .. start + base.len], start, Index.hashWindow(target[start..][0..match_len]));
            try std.testing.expectEqual(@as(usize, 0), found.at);
            try std.testing.expectEqual(end, found.len);
        }
    }
}
