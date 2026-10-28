//! Git's changed-path Bloom hashes. Version one keeps git's `char` bug:
//! each path byte is widened as the platform's C `char`, so a byte with the
//! high bit set hashes differently where `char` is signed (x86, every Apple
//! and Windows target) than where it is unsigned (Linux on ARM, RISC-V,
//! PowerPC), just as git's own filters do.
const std = @import("std");
const ctype = @import("../../text.zig").ctype;
const Allocator = std.mem.Allocator;

/// Settings stored at the start of the commit-graph's BDAT chunk.
pub const Settings = struct {
    version: u32 = 1,
    hashes: u32 = 7,
    bits_per_entry: u32 = 10,
    max_changed_paths: usize = 512,
};

fn byte(c: u8, version: u32) u32 {
    if (version == 1) return @bitCast(@as(i32, ctype.asChar(c)));
    return c;
}

/// The seeded Murmur3 hash git uses for a path, version one widening bytes
/// as the platform's `char`.
pub fn murmur(seed_value: u32, path: []const u8, version: u32) u32 {
    var seed = seed_value;
    var at: usize = 0;
    while (at + 4 <= path.len) : (at += 4) {
        var k = byte(path[at], version) | (byte(path[at + 1], version) << 8) | (byte(path[at + 2], version) << 16) | (byte(path[at + 3], version) << 24);
        k *%= 0xcc9e2d51;
        k = std.math.rotl(u32, k, 15);
        k *%= 0x1b873593;
        seed ^= k;
        seed = std.math.rotl(u32, seed, 13) *% 5 +% 0xe6546b64;
    }
    var tail: u32 = 0;
    for (path[at..], 0..) |c, i| tail ^= byte(c, version) << @as(u5, @intCast(i * 8));
    if (at != path.len) {
        tail *%= 0xcc9e2d51;
        tail = std.math.rotl(u32, tail, 15);
        tail *%= 0x1b873593;
        seed ^= tail;
    }
    seed ^= @truncate(path.len);
    seed ^= seed >> 16;
    seed *%= 0x85ebca6b;
    seed ^= seed >> 13;
    seed *%= 0xc2b2ae35;
    seed ^= seed >> 16;
    return seed;
}

/// Errors from `build`.
pub const BuildError = Allocator.Error || error{ UnsupportedBloomVersion, InvalidBloomSettings };

/// Build a filter from distinct changed paths, including directory prefixes.
/// Empty and oversized diffs have git's one-byte all-zero and all-one filters.
pub fn build(gpa: Allocator, paths: []const []const u8, settings: Settings) BuildError![]u8 {
    if (settings.version != 1 and settings.version != 2) return error.UnsupportedBloomVersion;
    if (settings.hashes == 0 or settings.bits_per_entry == 0 or settings.bits_per_entry > 64 or settings.hashes > 64) return error.InvalidBloomSettings;
    if (paths.len > settings.max_changed_paths) return gpa.dupe(u8, &.{255});
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    defer unique.deinit(gpa);
    for (paths) |path| {
        var end = path.len;
        while (end != 0) {
            try unique.put(gpa, path[0..end], {});
            if (unique.count() > settings.max_changed_paths) return gpa.dupe(u8, &.{255});
            end = std.mem.findScalarLast(u8, path[0..end], '/') orelse 0;
        }
    }
    if (unique.count() == 0) return gpa.dupe(u8, &.{0});
    if (paths.len > settings.max_changed_paths or unique.count() > settings.max_changed_paths) return gpa.dupe(u8, &.{255});
    const bits = std.math.mul(usize, unique.count(), settings.bits_per_entry) catch return error.OutOfMemory;
    const out = try gpa.alloc(u8, (bits >> 3) + @intFromBool(bits & 7 != 0));
    @memset(out, 0);
    var it = unique.keyIterator();
    while (it.next()) |path| {
        const a = murmur(0x293ae76f, path.*, settings.version);
        const b = murmur(0x7e646e2c, path.*, settings.version);
        for (0..settings.hashes) |i| {
            const bit = (a +% @as(u32, @intCast(i)) *% b) % (out.len * 8);
            out[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        }
    }
    return out;
}

/// Whether a path may have changed. False is conclusive; true is only a hint.
pub fn mayContain(filter: []const u8, path: []const u8, settings: Settings) bool {
    if (settings.hashes == 0 or settings.hashes > 64 or filter.len == 0 or (settings.version != 1 and settings.version != 2)) return true;
    const a = murmur(0x293ae76f, path, settings.version);
    const b = murmur(0x7e646e2c, path, settings.version);
    for (0..settings.hashes) |i| {
        const bit = (a +% @as(u32, @intCast(i)) *% b) % (filter.len * 8);
        if (filter[bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8))) == 0) return false;
    }
    return true;
}

/// All errors reported by this namespace.
pub const Error = BuildError;
