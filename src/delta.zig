//! The delta encoding a packfile uses.
//!
//! A delta is two sizes and then a list of commands: copy a run from the base,
//! or insert bytes carried in the delta. Two rules catch reimplementers, and
//! both are here: an omitted offset or size byte does not renumber the bytes
//! after it, and a copy size of zero means 0x10000.

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

/// Apply `delta` to `base`, appending the result to `out`.
///
/// `out` is expected to be empty or to be appended to deliberately; the
/// produced length is checked against the delta's stated target size, so a
/// delta that lies about its own output is a named error rather than a short
/// object.
pub fn applyTo(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    base: []const u8,
    delta: []const u8,
) (Error || Allocator.Error)!void {
    const sizes = try header(delta);
    if (sizes.source != base.len) return error.DeltaBaseSizeMismatch;
    if (sizes.target > max_result_bytes) return error.DeltaSizeOverflow;
    const start = out.items.len;
    try out.ensureUnusedCapacity(gpa, @intCast(sizes.target));

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

/// Apply `delta` to `base`. The result is the caller's.
pub fn apply(gpa: Allocator, base: []const u8, delta: []const u8) (Error || Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try applyTo(gpa, &out, base, delta);
    return out.toOwnedSlice(gpa);
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
