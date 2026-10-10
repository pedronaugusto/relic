//! Pack and multi-pack reachability bitmap files, and git's EWAH/XOR encoding.

const ErrorNamespace = @This();
const Self = @This();
const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const ewah = @import("../codec.zig").ewah;
const format = @import("accelerators/chunks.zig");
const Oid = hash.Oid;

/// Malformed, incompatible or unsupported optional accelerator data.
pub const Error = ewah.Error || Allocator.Error || error{ NotABitmap, UnsupportedBitmapVersion, UnsupportedBitmapOptions, CorruptReachabilityBitmap, BitmapChecksumMismatch };

/// One stored commit's compressed delta. The base precedes it by xor_offset rows.
pub const Entry = struct { position: u32, xor_offset: u8, flags: u8, start: usize, len: usize };

/// A checked bitmap, borrowing its pack's name order and reverse order from the caller.
pub const Index = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    kind: hash.Kind,
    bytes: []const u8,
    object_count: u32,
    checksum: Oid,
    options: u16,
    types: [4][]u64,
    entries: []Entry,
    hash_cache: ?[]const u8,

    /// Take ownership of a bitmap and check its digest against the named pack or MIDX.
    /// Pseudo-merge extensions are refused by name; ordinary reachability remains usable without them.
    pub fn parse(gpa: Allocator, kind: hash.Kind, bytes: []const u8, checksum: Oid, object_count: u32) Self.Error!Index {
        errdefer gpa.free(bytes);
        const header_len = 12 + kind.rawLen();
        if (bytes.len < header_len + kind.rawLen() or !std.mem.eql(u8, bytes[0..4], "BITM")) return error.NotABitmap;
        if (std.mem.readInt(u16, bytes[4..6], .big) != 1) return error.UnsupportedBitmapVersion;
        const options = std.mem.readInt(u16, bytes[6..8], .big);
        if (options & 1 == 0 or options & ~@as(u16, 1 | 4 | 16) != 0) return error.UnsupportedBitmapOptions;
        if (checksum.kind != kind or !std.mem.eql(u8, checksum.raw(), bytes[12..header_len])) return error.BitmapChecksumMismatch;
        const data_end = bytes.len - kind.rawLen();
        var hasher = hash.Hasher.init(kind);
        hasher.update(bytes[0..data_end]);
        const digest = hasher.final();
        if (!std.mem.eql(u8, digest.raw(), bytes[data_end..])) return error.BitmapChecksumMismatch;
        const entry_count = std.mem.readInt(u32, bytes[8..12], .big);
        if (entry_count > object_count or @as(u64, entry_count) * 26 > data_end - header_len) return error.CorruptReachabilityBitmap;
        var end = data_end;
        var cache: ?[]const u8 = null;
        if (options & 4 != 0) {
            const size = @as(usize, object_count) * 4;
            if (size > end - header_len) return error.CorruptReachabilityBitmap;
            cache = bytes[end - size .. end];
            end -= size;
        }
        var lookup: ?[]const u8 = null;
        if (options & 16 != 0) {
            const size = @as(usize, entry_count) * 16;
            if (size > end - header_len) return error.CorruptReachabilityBitmap;
            lookup = bytes[end - size .. end];
            end -= size;
        }
        var types: [4][]u64 = undefined;
        var loaded: usize = 0;
        errdefer for (types[0..loaded]) |words| gpa.free(words);
        var at = header_len;
        for (&types) |*words| {
            const decoded = try ewah.readWords(gpa, bytes[at..end], object_count);
            words.* = decoded.words;
            loaded += 1;
            at += decoded.len;
        }
        // Every indexed object has one and only one real type.
        for (0..(@as(usize, object_count) + 63) / 64) |i| {
            var union_word: u64 = 0;
            for (types) |words| {
                const word = if (i < words.len) words[i] else 0;
                if (union_word & word != 0) return error.CorruptReachabilityBitmap;
                union_word |= word;
            }
            const expected = if (i == object_count / 64 and object_count % 64 != 0) (@as(u64, 1) << @as(u6, @intCast(object_count % 64))) - 1 else std.math.maxInt(u64);
            if (union_word != expected) return error.CorruptReachabilityBitmap;
        }
        const entries = try gpa.alloc(Entry, entry_count);
        errdefer gpa.free(entries);
        for (entries, 0..) |*entry, i| {
            if (at > end or end - at < 6) return error.CorruptReachabilityBitmap;
            entry.* = .{ .position = std.mem.readInt(u32, bytes[at..][0..4], .big), .xor_offset = bytes[at + 4], .flags = bytes[at + 5], .start = at + 6, .len = 0 };
            if (entry.position >= object_count or entry.xor_offset > i or entry.xor_offset > 160) return error.CorruptReachabilityBitmap;
            entry.len = try ewah.encodedLength(bytes[at + 6 .. end], @as(u64, object_count) + 63);
            at += 6 + entry.len;
        }
        if (at != end) return error.CorruptReachabilityBitmap;
        if (lookup) |table| {
            var previous: ?u32 = null;
            for (0..entry_count) |i| {
                const row = table[i * 16 ..][0..16];
                const pos = std.mem.readInt(u32, row[0..4], .big);
                const offset = std.mem.readInt(u64, row[4..12], .big);
                const xor_row = std.mem.readInt(u32, row[12..16], .big);
                if (previous) |p| if (p >= pos) return error.CorruptReachabilityBitmap;
                previous = pos;
                if (xor_row != 0xffff_ffff and xor_row >= entry_count) return error.CorruptReachabilityBitmap;
                // The entries are in file order, so the row's offset finds
                // its entry by bisection rather than by a scan per row.
                const j = std.sort.binarySearch(Entry, entries, offset, orderEntryOffset) orelse return error.CorruptReachabilityBitmap;
                if (entries[j].position != pos) return error.CorruptReachabilityBitmap;
                if (entries[j].xor_offset == 0) {
                    if (xor_row != 0xffff_ffff) return error.CorruptReachabilityBitmap;
                } else {
                    if (xor_row == 0xffff_ffff) return error.CorruptReachabilityBitmap;
                    if (std.mem.readInt(u32, table[@as(usize, xor_row) * 16 ..][0..4], .big) != entries[j - entries[j].xor_offset].position) return error.CorruptReachabilityBitmap;
                }
            }
        }
        return .{ .gpa = gpa, .kind = kind, .bytes = bytes, .object_count = object_count, .checksum = checksum, .options = options, .types = types, .entries = entries, .hash_cache = cache };
    }

    fn orderEntryOffset(offset: u64, entry: Entry) std.math.Order {
        return std.math.order(offset, entry.start - 6);
    }

    pub fn deinit(index: *Index) void {
        for (index.types) |words| index.gpa.free(words);
        index.gpa.free(index.entries);
        index.gpa.free(index.bytes);
        index.* = undefined;
    }

    /// Decode a selected commit's reachability in pack order, or null when unselected.
    /// The caller owns the words. XOR bases always precede the entry, so this cannot cycle.
    pub fn reach(index: *const Index, gpa: Allocator, position: u32) Self.Error!?[]u64 {
        var chosen: ?usize = null;
        for (index.entries, 0..) |entry, i| if (entry.position == position) {
            chosen = i;
            break;
        };
        var i = chosen orelse return null;
        const out = try gpa.alloc(u64, (@as(usize, index.object_count) + 63) / 64);
        errdefer gpa.free(out);
        @memset(out, 0);
        while (true) {
            const entry = index.entries[i];
            const decoded = try ewah.readWords(gpa, index.bytes[entry.start..][0..entry.len], @as(u64, index.object_count) + 63);
            defer gpa.free(decoded.words);
            if (decoded.words.len > out.len) return error.CorruptReachabilityBitmap;
            for (decoded.words, 0..) |word, j| out[j] ^= word;
            if (entry.xor_offset == 0) break;
            i -= entry.xor_offset;
        }
        if (out.len > 0 and index.object_count % 64 != 0) out[out.len - 1] &= (@as(u64, 1) << @as(u6, @intCast(index.object_count % 64))) - 1;
        return out;
    }

    /// The name hash of an object in name order, when the optional cache is present.
    pub fn nameHashAt(index: *const Index, position: u32) ?u32 {
        if (position >= index.object_count) return null;
        const cache = index.hash_cache orelse return null;
        return std.mem.readInt(u32, cache[@as(usize, position) * 4 ..][0..4], .big);
    }
};

/// Whether a pack-order position is set in decoded words.
pub fn isSet(words: []const u64, position: u32) bool {
    const i = position / 64;
    return i < words.len and words[i] & (@as(u64, 1) << @as(u6, @intCast(position % 64))) != 0;
}
/// Count the set positions, optionally intersecting a type map.
pub fn count(words: []const u64, types: ?[]const u64) u64 {
    var total: u64 = 0;
    for (words, 0..) |word, i| total += @popCount(word & (if (types) |map| (if (i < map.len) map[i] else 0) else std.math.maxInt(u64)));
    return total;
}

/// Git's version-one path hint hash, stored in name order.
pub fn nameHash(path: []const u8) u32 {
    var value: u32 = 0;
    for (path) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 11 or c == 12) continue;
        const signed: u32 = @bitCast(@as(i32, @as(i8, @bitCast(c))));
        value = (value >> 2) +% (signed << 24);
    }
    return value;
}

/// One selected commit in increasing commit-date order, as git writes it.
pub const WriteCommit = struct { position: u32, words: []const u64, flags: u8 = 0 };
pub const WriteOptions = struct { hash_cache: ?[]const u32 = null, lookup_table: bool = true };

/// Errors from `encode`.
pub const EncodeError = Allocator.Error || error{InvalidBitmapInput};

/// Encode type maps, Git's ten-row XOR search, lookup table and name hash cache.
/// `types` and commit reachability use pack order; positions and hashes use name order.
pub const WriteInputs = struct { checksum: Oid, types: [4][]const u64, commits: []const WriteCommit };

pub fn encode(gpa: Allocator, kind: hash.Kind, inputs: WriteInputs, options: WriteOptions) EncodeError![]u8 {
    const checksum = inputs.checksum;
    const types = inputs.types;
    const commits = inputs.commits;
    if (checksum.kind != kind or commits.len > std.math.maxInt(u32)) return error.InvalidBitmapInput;
    var out: format.Buffer = .{ .gpa = gpa };
    defer out.deinit();
    try out.add("BITM");
    try out.int(u16, 1);
    try out.int(u16, 1 | (if (options.hash_cache != null) @as(u16, 4) else 0) | (if (options.lookup_table) @as(u16, 16) else 0));
    try out.int(u32, @intCast(commits.len));
    try out.add(checksum.raw());
    for (types) |words| {
        var n = words.len;
        while (n > 0 and words[n - 1] == 0) n -= 1;
        const bits: u32 = if (n == 0) 0 else @intCast((n - 1) * 64 + 64 - @clz(words[n - 1]));
        const encoded = try ewah.write(gpa, words[0..n], bits);
        defer gpa.free(encoded);
        try out.add(encoded);
    }
    const offsets = try gpa.alloc(u64, commits.len);
    defer gpa.free(offsets);
    const xors = try gpa.alloc(u8, commits.len);
    defer gpa.free(xors);
    for (commits, 0..) |commit_value, i| {
        var n = commit_value.words.len;
        while (n > 0 and commit_value.words[n - 1] == 0) n -= 1;
        // Git's bitmap_to_ewah emits one zero word for an empty bitmap.
        const word_count = @max(n, 1);
        const words = try gpa.alloc(u64, word_count);
        defer gpa.free(words);
        @memset(words, 0);
        @memcpy(words[0..n], commit_value.words[0..n]);
        var best = try ewah.write(gpa, words, @intCast(word_count * 64));
        defer gpa.free(best);
        var best_offset: u8 = 0;
        for (1..@min(i, 10) + 1) |distance| {
            const base = commits[i - distance].words;
            var base_count = base.len;
            while (base_count > 0 and base[base_count - 1] == 0) base_count -= 1;
            const xor_words = try gpa.alloc(u64, @max(word_count, @max(base_count, 1)));
            defer gpa.free(xor_words);
            for (xor_words, 0..) |*word, j| word.* = (if (j < n) commit_value.words[j] else 0) ^ (if (j < base_count) base[j] else 0);
            const candidate = try ewah.write(gpa, xor_words, @intCast(xor_words.len * 64));
            if (candidate.len < best.len) {
                gpa.free(best);
                best = candidate;
                best_offset = @intCast(distance);
            } else gpa.free(candidate);
        }
        offsets[i] = out.bytes.items.len;
        xors[i] = best_offset;
        try out.int(u32, commit_value.position);
        try out.int(u8, best_offset);
        try out.int(u8, commit_value.flags);
        try out.add(best);
    }
    if (options.lookup_table) {
        const order = try gpa.alloc(u32, commits.len);
        defer gpa.free(order);
        const inverse = try gpa.alloc(u32, commits.len);
        defer gpa.free(inverse);
        for (order, 0..) |*p, i| p.* = @intCast(i);
        const Order = struct {
            fn less(context: []const WriteCommit, a: u32, b: u32) bool {
                return context[a].position < context[b].position;
            }
        };
        std.mem.sort(u32, order, commits, Order.less);
        for (order, 0..) |pos, i| inverse[pos] = @intCast(i);
        for (order) |pos| {
            try out.int(u32, commits[pos].position);
            try out.int(u64, offsets[pos]);
            try out.int(u32, if (xors[pos] == 0) 0xffff_ffff else inverse[pos - xors[pos]]);
        }
    }
    if (options.hash_cache) |cache| for (cache) |value| try out.int(u32, value);
    var hasher = hash.Hasher.init(kind);
    hasher.update(out.bytes.items);
    const digest = hasher.final();
    try out.add(digest.raw());
    return out.finish();
}

test "fuzz: any bytes are a reachability bitmap or a named error" {
    try shakedown.check(std.testing.allocator, {}, fuzzOne, .{});
}
fn fuzzOne(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const drawn = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(drawn);
    const bytes = try std.testing.allocator.dupe(u8, drawn);
    var parsed = Index.parse(std.testing.allocator, .sha1, bytes, Oid.zero(.sha1), 1024) catch return;
    parsed.deinit();
}
