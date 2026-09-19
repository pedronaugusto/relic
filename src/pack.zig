//! Packfiles, and the `.idx` beside them.
//!
//! A pack is read, never written. Both delta kinds resolve, the chain is
//! bounded by a depth cap and a visited set so neither a cycle nor a
//! thousand-deep chain is a hang, and every entry can be rehashed against the
//! name the index gives it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

const hash = @import("hash.zig");
const object = @import("object.zig");
const delta = @import("delta.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// The magic a version 2 index begins with. Version 1 has no magic at all,
/// which is how the two are told apart.
pub const idx_magic = "\xfftOc";

/// How deep a delta chain may be before it is refused.
///
/// git's own packer defaults to 50 and a real pack measured here had exactly
/// one object at that depth, with a median of 3. But `pack.depth` is a
/// setting and the format's own field allows 4 095, so the cap is the
/// format's limit and the byte budget below is what actually bounds the work.
pub const default_max_depth: u32 = 4095;

/// How many bytes one delta chain may produce in total before it is refused.
///
/// The depth cap alone does not bound memory: a hundred-deep chain of
/// hundred-megabyte objects is within every other limit. One gigabyte is far
/// above anything a real pack asks for.
pub const default_max_chain_bytes: u64 = 1 << 30;

/// Errors from opening or reading a pack index.
pub const IndexError = error{
    /// The file was shorter than its own headers say.
    TruncatedIndex,
    /// A version 1 index. git still reads them; this does not, by name.
    UnsupportedIndexVersion,
    /// The magic was there but the version was neither 1 nor 2.
    UnknownIndexVersion,
    /// The fanout does not rise, or its last entry is not the object count.
    CorruptIndexFanout,
    /// The object names are not in ascending order.
    UnsortedIndex,
    /// A 4-byte offset had its high bit set but the 8-byte table has no such
    /// row.
    BadLargeOffset,
} || Allocator.Error || Io.Dir.ReadFileAllocError;

/// A packfile's `.idx`, version 2.
///
/// The whole file is held in memory: it is about twenty-six bytes per object
/// and every lookup is a bisection inside it, so there is nothing to gain by
/// leaving it on the disk.
pub const Index = struct {
    gpa: Allocator,
    kind: Kind,
    bytes: []const u8,
    /// How many objects the pack holds.
    count: u32,
    names_at: usize,
    crcs_at: usize,
    offsets_at: usize,
    large_at: usize,
    large_count: u32,
    /// The name of the pack this index belongs to, from its trailer.
    pack_checksum: Oid,

    /// Where an object lives in the pack.
    pub const Located = struct {
        /// The object's position in the index, which is its position in the
        /// sorted name list.
        index: u32,
        /// The byte offset of its entry in the pack.
        offset: u64,
        /// The CRC32 of its compressed entry, which the index carries so a
        /// corrupt pack is caught without inflating it.
        crc: u32,
    };

    /// Read `sub_path` in `dir` as a version 2 index.
    ///
    /// `max_bytes` bounds the read; an index larger than that is
    /// `error.StreamTooLong` rather than an allocation nobody asked for.
    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        kind: Kind,
        max_bytes: usize,
    ) IndexError!Index {
        const bytes = try dir.readFileAlloc(io, sub_path, gpa, .limited(max_bytes));
        errdefer gpa.free(bytes);
        return parse(gpa, kind, bytes);
    }

    /// Read an index from bytes this takes ownership of.
    pub fn parse(gpa: Allocator, kind: Kind, bytes: []u8) IndexError!Index {
        errdefer gpa.free(bytes);
        const raw_len = kind.rawLen();
        if (bytes.len < 8) return error.TruncatedIndex;
        // Version 1 has no magic at all: it begins with its fanout. That is
        // how the two are told apart, and why the magic is checked before
        // the length.
        if (!std.mem.eql(u8, bytes[0..4], idx_magic)) return error.UnsupportedIndexVersion;
        const version = std.mem.readInt(u32, bytes[4..8], .big);
        if (version != 2) return error.UnknownIndexVersion;
        if (bytes.len < 8 + 1024 + 2 * raw_len) return error.TruncatedIndex;

        const fanout_at: usize = 8;
        var previous: u32 = 0;
        for (0..256) |i| {
            const value = std.mem.readInt(u32, bytes[fanout_at + i * 4 ..][0..4], .big);
            if (value < previous) return error.CorruptIndexFanout;
            previous = value;
        }
        const count = previous;

        const names_at = fanout_at + 1024;
        const crcs_at = names_at + @as(usize, count) * raw_len;
        const offsets_at = crcs_at + @as(usize, count) * 4;
        const large_at = offsets_at + @as(usize, count) * 4;
        if (bytes.len < large_at + 2 * raw_len) return error.TruncatedIndex;
        const remaining = bytes.len - large_at - 2 * raw_len;
        if (remaining % 8 != 0) return error.TruncatedIndex;
        const large_count: u32 = @intCast(remaining / 8);

        const pack_checksum = Oid.fromRaw(kind, bytes[bytes.len - 2 * raw_len ..][0..raw_len]) catch unreachable;

        const index: Index = .{
            .gpa = gpa,
            .kind = kind,
            .bytes = bytes,
            .count = count,
            .names_at = names_at,
            .crcs_at = crcs_at,
            .offsets_at = offsets_at,
            .large_at = large_at,
            .large_count = large_count,
            .pack_checksum = pack_checksum,
        };

        // The fanout must agree with the names it indexes, and the names must
        // rise. Both are cheap and both are how a truncated or shuffled index
        // is caught before a lookup silently misses.
        var i: u32 = 1;
        while (i < count) : (i += 1) {
            const a = index.rawNameAt(i - 1);
            const b = index.rawNameAt(i);
            if (std.mem.order(u8, a, b) != .lt) return error.UnsortedIndex;
        }
        for (0..256) |bucket| {
            const end = std.mem.readInt(u32, bytes[fanout_at + bucket * 4 ..][0..4], .big);
            if (end > count) return error.CorruptIndexFanout;
            if (end > 0 and index.rawNameAt(end - 1)[0] > bucket) return error.CorruptIndexFanout;
            if (end < count and index.rawNameAt(end)[0] < bucket) return error.CorruptIndexFanout;
        }

        return index;
    }

    /// Release the index.
    pub fn deinit(index: *Index) void {
        index.gpa.free(index.bytes);
        index.* = undefined;
    }

    fn rawNameAt(index: Index, i: u32) []const u8 {
        const raw_len = index.kind.rawLen();
        return index.bytes[index.names_at + @as(usize, i) * raw_len ..][0..raw_len];
    }

    /// The name of the object at position `i`.
    pub fn nameAt(index: Index, i: u32) Oid {
        return Oid.fromRaw(index.kind, index.rawNameAt(i)) catch unreachable;
    }

    /// The pack offset of the object at position `i`.
    pub fn offsetAt(index: Index, i: u32) IndexError!u64 {
        const small = std.mem.readInt(u32, index.bytes[index.offsets_at + @as(usize, i) * 4 ..][0..4], .big);
        if (small & 0x8000_0000 == 0) return small;
        const row = small & 0x7fff_ffff;
        if (row >= index.large_count) return error.BadLargeOffset;
        return std.mem.readInt(u64, index.bytes[index.large_at + @as(usize, row) * 8 ..][0..8], .big);
    }

    /// The CRC32 of the compressed entry at position `i`.
    pub fn crcAt(index: Index, i: u32) u32 {
        return std.mem.readInt(u32, index.bytes[index.crcs_at + @as(usize, i) * 4 ..][0..4], .big);
    }

    /// Where `oid` lives, or `null` if this pack does not hold it.
    pub fn find(index: Index, oid: Oid) IndexError!?Located {
        if (oid.kind != index.kind) return null;
        const raw = oid.raw();
        var lo: u32 = if (raw[0] == 0) 0 else std.mem.readInt(u32, index.bytes[8 + (@as(usize, raw[0]) - 1) * 4 ..][0..4], .big);
        var hi: u32 = std.mem.readInt(u32, index.bytes[8 + @as(usize, raw[0]) * 4 ..][0..4], .big);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, index.rawNameAt(mid), raw)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{
                    .index = mid,
                    .offset = try index.offsetAt(mid),
                    .crc = index.crcAt(mid),
                },
            }
        }
        return null;
    }

    /// Errors from resolving an abbreviated name.
    pub const PrefixError = error{
        /// More than one object in this pack begins with those digits.
        AmbiguousPrefix,
    } || IndexError;

    /// The one object whose name begins with `prefix`, or `null`.
    ///
    /// `prefix` is hexadecimal and may be odd-length. Two matches are
    /// `error.AmbiguousPrefix`, which is what a caller resolving a short name
    /// typed by a person needs to hear.
    pub fn findPrefix(index: Index, prefix: []const u8) PrefixError!?Oid {
        if (prefix.len == 0 or prefix.len > index.kind.hexLen()) return null;
        var found: ?Oid = null;
        var i: u32 = 0;
        // The first byte narrows to one fanout bucket; a prefix shorter than
        // two digits does not, so the walk starts at the front.
        if (prefix.len >= 2) {
            const first = (hexVal(prefix[0]) catch return null) * 16 + (hexVal(prefix[1]) catch return null);
            i = if (first == 0) 0 else std.mem.readInt(u32, index.bytes[8 + (@as(usize, first) - 1) * 4 ..][0..4], .big);
        }
        while (i < index.count) : (i += 1) {
            const oid = index.nameAt(i);
            if (!oid.startsWithHex(prefix)) {
                if (prefix.len >= 2 and found == null and i > 0) {
                    // Past the bucket: nothing further can match.
                    var buf: [hash.max_hex_len]u8 = undefined;
                    const text = oid.hex(&buf);
                    if (std.mem.order(u8, text[0..2], prefix[0..2]) == .gt) break;
                }
                continue;
            }
            if (found != null) return error.AmbiguousPrefix;
            found = oid;
        }
        return found;
    }

    /// A walk over every object in the index, in name order.
    pub fn iterate(index: *const Index) Iterator {
        return .{ .index = index, .i = 0 };
    }

    /// A walk over an index.
    pub const Iterator = struct {
        index: *const Index,
        i: u32,

        /// The next object, or `null` at the end.
        pub fn next(it: *Iterator) IndexError!?struct { oid: Oid, located: Located } {
            if (it.i >= it.index.count) return null;
            const i = it.i;
            it.i += 1;
            return .{
                .oid = it.index.nameAt(i),
                .located = .{ .index = i, .offset = try it.index.offsetAt(i), .crc = it.index.crcAt(i) },
            };
        }
    };
};

fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidCharacter,
    };
}

/// Errors from reading a packfile.
pub const Error = error{
    /// The file does not begin `PACK`.
    NotAPack,
    /// A pack version other than 2 or 3.
    UnsupportedPackVersion,
    /// An entry, or the trailer, ran off the end.
    TruncatedPack,
    /// A type field of 0 or 5, which git reserves and never writes.
    InvalidPackEntryType,
    /// An `ofs-delta` whose base offset points forwards, or before the
    /// header.
    BadDeltaOffset,
    /// A `ref-delta` whose base this pack does not hold.
    DeltaBaseMissing,
    /// The chain reached `max_depth` without finding a base.
    DeltaChainTooDeep,
    /// The chain came back to an offset it had already been through.
    DeltaCycle,
    /// An entry's inflated length is not the length its header states.
    PackEntrySizeMismatch,
    /// The compressed stream did not inflate.
    CorruptPackEntry,
    /// The object did not hash to the name the index gives it.
    ObjectNameMismatch,
    /// The compressed entry did not match the CRC the index carries.
    ChecksumMismatch,
} || IndexError || delta.Error || Io.File.OpenError ||
    Io.File.ReadPositionalError || Io.File.StatError || Io.File.MemoryMap.CreateError;

/// The kinds a pack entry header can name.
pub const EntryKind = union(enum) {
    /// A whole object of this type.
    object: object.Type,
    /// A delta against an entry `n` bytes earlier in this pack.
    ofs_delta: u64,
    /// A delta against the object with this name.
    ref_delta: Oid,
};

/// A pack entry's header: what it is, how long the result is, and where its
/// compressed body starts.
pub const EntryHeader = struct {
    kind: EntryKind,
    /// The length of the inflated result — the object, or the delta.
    size: u64,
    /// The offset of the zlib stream.
    data_at: u64,
};

/// An object read out of a pack. The bytes are the caller's.
pub const Object = struct {
    type: object.Type,
    bytes: []u8,
};

/// How a pack's bytes are reached.
pub const Access = enum {
    /// Positional reads. The default, and the one that keeps two promises a
    /// memory map cannot: an IO error arrives as an error value rather than
    /// as a signal, and nothing holds the file open against a concurrent
    /// `git gc` that wants to replace it. On macOS a mapped pack replaced
    /// underneath gives `SIGBUS`, which no library can catch on the caller's
    /// behalf; on Windows a live mapping stops the repack outright.
    read,
    /// A memory map where the platform has one, and positional reads where
    /// it does not. Faster on a cold cache, and the trade above is the price.
    map,
};

/// A packfile, open for reading.
pub const Pack = struct {
    gpa: Allocator,
    kind: Kind,
    file: Io.File,
    mapping: ?Io.File.MemoryMap,
    /// The whole pack, when it is mapped.
    memory: ?[]const u8,
    size: u64,
    /// How many objects the pack header claims.
    count: u32,
    index: Index,
    max_depth: u32,
    max_chain_bytes: u64,
    /// Scratch for one inflate at a time. The package starts no threads, and
    /// a delta chain is resolved one entry after another, so one window does.
    window: []u8,
    input_buffer: []u8,

    /// Open `<base>.pack` and `<base>.idx` in `dir`.
    ///
    /// `base` is the pack's name without an extension, which is what the
    /// directory listing gives.
    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        base: []const u8,
        kind: Kind,
        options: struct {
            access: Access = .read,
            max_depth: u32 = default_max_depth,
            max_chain_bytes: u64 = default_max_chain_bytes,
            max_index_bytes: usize = 1 << 30,
        },
    ) Error!Pack {
        var name_buf: [512]u8 = undefined;
        const idx_name = std.fmt.bufPrint(&name_buf, "{s}.idx", .{base}) catch return error.NameTooLong;
        var index = try Index.open(gpa, io, dir, idx_name, kind, options.max_index_bytes);
        errdefer index.deinit();

        var pack_buf: [512]u8 = undefined;
        const pack_name = std.fmt.bufPrint(&pack_buf, "{s}.pack", .{base}) catch return error.NameTooLong;
        const file = try dir.openFile(io, pack_name, .{});
        errdefer file.close(io);

        const stat = try file.stat(io);
        const raw_len = kind.rawLen();
        if (stat.size < 12 + raw_len) return error.TruncatedPack;

        var header: [12]u8 = undefined;
        _ = try file.readPositionalAll(io, &header, 0);
        if (!std.mem.eql(u8, header[0..4], "PACK")) return error.NotAPack;
        const version = std.mem.readInt(u32, header[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;
        const count = std.mem.readInt(u32, header[8..12], .big);

        var mapping: ?Io.File.MemoryMap = null;
        var memory: ?[]const u8 = null;
        if (options.access == .map and stat.size <= std.math.maxInt(usize)) {
            if (Io.File.MemoryMap.create(io, file, .{
                .len = @intCast(stat.size),
                .protection = .{ .read = true, .write = false },
                .populate = false,
            })) |created| {
                var m = created;
                if (m.read(io)) {
                    mapping = m;
                    memory = m.memory;
                } else |_| {
                    m.destroy(io);
                }
            } else |_| {}
        }
        errdefer if (mapping) |*m| m.destroy(io);

        const window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(window);
        // 64 KiB rather than the usual 8: a pack scan reads entry headers one
        // after another and the larger buffer is several times faster.
        const input_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(input_buffer);

        return .{
            .gpa = gpa,
            .kind = kind,
            .file = file,
            .mapping = mapping,
            .memory = memory,
            .size = stat.size,
            .count = count,
            .index = index,
            .max_depth = options.max_depth,
            .max_chain_bytes = options.max_chain_bytes,
            .window = window,
            .input_buffer = input_buffer,
        };
    }

    /// Close the pack and release everything it holds.
    pub fn deinit(p: *Pack, io: Io) void {
        p.gpa.free(p.window);
        p.gpa.free(p.input_buffer);
        if (p.mapping) |*m| m.destroy(io);
        p.file.close(io);
        p.index.deinit();
        p.* = undefined;
    }

    /// Where the entries end and the trailing checksum begins.
    pub fn bodyEnd(p: *const Pack) u64 {
        return p.size - p.kind.rawLen();
    }

    fn readAtExact(p: *Pack, io: Io, offset: u64, out: []u8) Error!void {
        if (p.memory) |mem| {
            if (offset + out.len > mem.len) return error.TruncatedPack;
            @memcpy(out, mem[@intCast(offset)..][0..out.len]);
            return;
        }
        var done: usize = 0;
        while (done < out.len) {
            const n = try p.file.readPositional(io, &.{out[done..]}, offset + done);
            if (n == 0) return error.TruncatedPack;
            done += n;
        }
    }

    fn readAtUpTo(p: *Pack, io: Io, offset: u64, out: []u8) Error!usize {
        if (p.memory) |mem| {
            if (offset >= mem.len) return 0;
            const n = @min(out.len, mem.len - @as(usize, @intCast(offset)));
            @memcpy(out[0..n], mem[@intCast(offset)..][0..n]);
            return n;
        }
        return p.file.readPositional(io, &.{out}, offset);
    }

    /// The header of the entry at `offset`, without inflating anything.
    pub fn entryHeaderAt(p: *Pack, io: Io, offset: u64) Error!EntryHeader {
        if (offset < 12 or offset >= p.bodyEnd()) return error.TruncatedPack;
        var buf: [32 + hash.max_raw_len]u8 = undefined;
        const available = @min(buf.len, p.bodyEnd() - offset);
        const n = try p.readAtUpTo(io, offset, buf[0..@intCast(available)]);
        if (n == 0) return error.TruncatedPack;
        const bytes = buf[0..n];

        var i: usize = 0;
        if (i >= bytes.len) return error.TruncatedPack;
        var byte = bytes[i];
        i += 1;
        const type_bits: u3 = @truncate(byte >> 4);
        var size: u64 = byte & 0x0f;
        var shift: u6 = 4;
        while (byte & 0x80 != 0) {
            if (i >= bytes.len) return error.TruncatedPack;
            byte = bytes[i];
            i += 1;
            if (shift > 57) return error.TruncatedPack;
            size |= @as(u64, byte & 0x7f) << shift;
            shift += 7;
        }

        const kind: EntryKind = switch (type_bits) {
            1 => .{ .object = .commit },
            2 => .{ .object = .tree },
            3 => .{ .object = .blob },
            4 => .{ .object = .tag },
            6 => blk: {
                // The biased offset varint: a different encoding from the
                // size varint a few bytes earlier in the same entry.
                if (i >= bytes.len) return error.TruncatedPack;
                byte = bytes[i];
                i += 1;
                var back: u64 = byte & 0x7f;
                while (byte & 0x80 != 0) {
                    if (i >= bytes.len) return error.TruncatedPack;
                    byte = bytes[i];
                    i += 1;
                    back = std.math.add(u64, back, 1) catch return error.BadDeltaOffset;
                    back = std.math.shl(u64, back, @as(u6, 7));
                    if (back >> 7 == 0 and byte & 0x7f != 0) return error.BadDeltaOffset;
                    back |= byte & 0x7f;
                }
                break :blk .{ .ofs_delta = back };
            },
            7 => blk: {
                const raw_len = p.kind.rawLen();
                if (i + raw_len > bytes.len) return error.TruncatedPack;
                const oid = Oid.fromRaw(p.kind, bytes[i..][0..raw_len]) catch unreachable;
                i += raw_len;
                break :blk .{ .ref_delta = oid };
            },
            else => return error.InvalidPackEntryType,
        };

        return .{ .kind = kind, .size = size, .data_at = offset + i };
    }

    /// Inflate `size` bytes of the zlib stream at `at`. The result is the
    /// caller's.
    fn inflateAt(p: *Pack, io: Io, at: u64, size: u64) Error![]u8 {
        if (size > delta.max_result_bytes) return error.PackEntrySizeMismatch;
        const out = try p.gpa.alloc(u8, @intCast(size));
        errdefer p.gpa.free(out);

        var fixed_reader: Io.Reader = undefined;
        var file_reader: Io.File.Reader = undefined;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else blk: {
            file_reader = p.file.reader(io, p.input_buffer);
            file_reader.seekTo(at) catch return error.TruncatedPack;
            break :blk &file_reader.interface;
        };

        var decompress: flate.Decompress = .init(input, .zlib, p.window);
        decompress.reader.readSliceAll(out) catch return error.CorruptPackEntry;
        return out;
    }

    /// The object at `offset`, with its delta chain resolved.
    ///
    /// `cache` may be `null`; when it is not, resolved bases are kept in it,
    /// which is what makes a walk over a pack proportional to its objects
    /// rather than to its chains.
    pub fn readAt(p: *Pack, io: Io, offset: u64, cache: ?*Cache, pack_id: u32) Error!Object {
        var chain: std.ArrayList(u64) = .empty;
        defer chain.deinit(p.gpa);
        var visited: std.ArrayList(u64) = .empty;
        defer visited.deinit(p.gpa);

        var current = offset;
        var chain_bytes: u64 = 0;
        var base_bytes: []u8 = undefined;
        var base_type: object.Type = undefined;

        while (true) {
            if (cache) |c| {
                if (c.get(pack_id, current)) |hit| {
                    base_bytes = try p.gpa.dupe(u8, hit.bytes);
                    base_type = hit.type;
                    break;
                }
            }
            const header = try p.entryHeaderAt(io, current);
            switch (header.kind) {
                .object => |t| {
                    base_bytes = try p.inflateAt(io, header.data_at, header.size);
                    base_type = t;
                    break;
                },
                .ofs_delta => |back| {
                    if (back == 0 or back > current) return error.BadDeltaOffset;
                    const base_offset = current - back;
                    if (base_offset < 12) return error.BadDeltaOffset;
                    try chain.append(p.gpa, current);
                    current = base_offset;
                },
                .ref_delta => |oid| {
                    const located = (try p.index.find(oid)) orelse return error.DeltaBaseMissing;
                    try chain.append(p.gpa, current);
                    current = located.offset;
                },
            }
            if (chain.items.len > p.max_depth) return error.DeltaChainTooDeep;
            chain_bytes += header.size;
            if (chain_bytes > p.max_chain_bytes) return error.DeltaChainTooDeep;
            for (visited.items) |seen| {
                if (seen == current) return error.DeltaCycle;
            }
            try visited.append(p.gpa, current);
        }
        errdefer p.gpa.free(base_bytes);

        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const delta_offset = chain.items[i];
            const header = try p.entryHeaderAt(io, delta_offset);
            const delta_bytes = try p.inflateAt(io, header.data_at, header.size);
            defer p.gpa.free(delta_bytes);
            const applied = try delta.apply(p.gpa, base_bytes, delta_bytes);
            p.gpa.free(base_bytes);
            base_bytes = applied;
            if (cache) |c| c.put(pack_id, delta_offset, base_type, base_bytes) catch {};
        }

        return .{ .type = base_type, .bytes = base_bytes };
    }

    /// The type and length of the object at `offset`, with no body inflated.
    ///
    /// A delta's chain is walked for the type — which is the base's — but the
    /// size is the delta's own stated target, read out of its first few
    /// bytes, so nothing large is decompressed.
    pub fn headerAt(p: *Pack, io: Io, offset: u64) Error!object.Header {
        var current = offset;
        var depth: u32 = 0;
        var size: ?u64 = null;
        while (true) : (depth += 1) {
            if (depth > p.max_depth) return error.DeltaChainTooDeep;
            const header = try p.entryHeaderAt(io, current);
            switch (header.kind) {
                .object => |t| return .{ .type = t, .size = size orelse header.size },
                .ofs_delta, .ref_delta => {
                    if (size == null) {
                        const head = try p.inflateHead(io, header.data_at, header.size);
                        const sizes = try delta.header(&head);
                        size = sizes.target;
                    }
                    switch (header.kind) {
                        .ofs_delta => |back| {
                            if (back == 0 or back > current) return error.BadDeltaOffset;
                            current -= back;
                        },
                        .ref_delta => |oid| {
                            const located = (try p.index.find(oid)) orelse return error.DeltaBaseMissing;
                            current = located.offset;
                        },
                        .object => unreachable,
                    }
                },
            }
        }
    }

    /// Inflate at most the first twenty bytes of a stream.
    ///
    /// That is enough for a delta's two size varints — ten bytes each at the
    /// widest — so the type and the true expanded size of a deltified object
    /// come back with nothing materialised.
    fn inflateHead(p: *Pack, io: Io, at: u64, size: u64) Error![20]u8 {
        var out: [20]u8 = @splat(0);
        const want: usize = @intCast(@min(size, out.len));
        var fixed_reader: Io.Reader = undefined;
        var file_reader: Io.File.Reader = undefined;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else blk: {
            file_reader = p.file.reader(io, p.input_buffer);
            file_reader.seekTo(at) catch return error.TruncatedPack;
            break :blk &file_reader.interface;
        };
        var decompress: flate.Decompress = .init(input, .zlib, p.window);
        decompress.reader.readSliceAll(out[0..want]) catch return error.CorruptPackEntry;
        return out;
    }

    /// What `verify` found.
    pub const Report = struct {
        objects: u32 = 0,
        bytes: u64 = 0,
    };

    /// Rehash every object in the pack against the name the index gives it,
    /// and check every entry against the CRC the index carries.
    ///
    /// The pack's own trailing checksum is checked first, so a truncated file
    /// is one error and not thousands.
    pub fn verify(p: *Pack, io: Io, cache: ?*Cache, pack_id: u32) Error!Report {
        try p.verifyChecksum(io);

        // The compressed span of an entry runs to the next entry's offset, so
        // a CRC needs the offsets in file order rather than in name order.
        const order = try p.gpa.alloc(u32, p.index.count);
        defer p.gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        const Ctx = struct {
            index: *const Index,
            fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                const oa = ctx.index.offsetAt(a) catch 0;
                const ob = ctx.index.offsetAt(b) catch 0;
                return oa < ob;
            }
        };
        std.mem.sort(u32, order, Ctx{ .index = &p.index }, Ctx.lessThan);

        var report: Report = .{};
        for (order, 0..) |position, rank| {
            const offset = try p.index.offsetAt(position);
            const end = if (rank + 1 < order.len)
                try p.index.offsetAt(order[rank + 1])
            else
                p.bodyEnd();
            if (end < offset or end > p.bodyEnd()) return error.TruncatedPack;

            const span = try p.gpa.alloc(u8, @intCast(end - offset));
            defer p.gpa.free(span);
            try p.readAtExact(io, offset, span);
            if (std.hash.Crc32.hash(span) != p.index.crcAt(position)) return error.ChecksumMismatch;

            const obj = try p.readAt(io, offset, cache, pack_id);
            defer p.gpa.free(obj.bytes);
            const name = hash.Hasher.object(p.kind, obj.type.name(), obj.bytes);
            if (!name.eql(p.index.nameAt(position))) return error.ObjectNameMismatch;
            report.objects += 1;
            report.bytes += obj.bytes.len;
        }
        return report;
    }

    /// Check the pack's trailing checksum, which names the pack and which the
    /// index repeats.
    pub fn verifyChecksum(p: *Pack, io: Io) Error!void {
        var hasher: hash.Hasher = .init(p.kind);
        var buf: [64 * 1024]u8 = undefined;
        var at: u64 = 0;
        while (at < p.bodyEnd()) {
            const want: usize = @intCast(@min(buf.len, p.bodyEnd() - at));
            try p.readAtExact(io, at, buf[0..want]);
            hasher.update(buf[0..want]);
            at += want;
        }
        const computed = hasher.final();
        var trailer: [hash.max_raw_len]u8 = undefined;
        const raw_len = p.kind.rawLen();
        try p.readAtExact(io, p.bodyEnd(), trailer[0..raw_len]);
        const stored = Oid.fromRaw(p.kind, trailer[0..raw_len]) catch unreachable;
        if (!computed.eql(stored)) return error.ChecksumMismatch;
        if (!stored.eql(p.index.pack_checksum)) return error.ChecksumMismatch;
    }
};

/// A byte-capped store of resolved delta bases.
///
/// Without it, every object in a chain re-resolves its whole chain and a walk
/// over a pack is quadratic. The table is direct-mapped on the low bits of
/// the pack offset — no hashing, no search, and a collision simply
/// overwrites — with a byte budget swept oldest-first. It is the cheapest
/// shape in the field and it is also the fastest one. This is the only cache
/// in the package apart from the pack indexes themselves.
pub const Cache = struct {
    gpa: Allocator,
    limit_bytes: usize,
    bytes: usize = 0,
    slots: []Slot,
    /// Insertion order, for the byte sweep.
    order: std.ArrayList(u32) = .empty,
    clock: u32 = 0,

    /// How many slots the table has. A power of two so the index is a mask.
    pub const slot_count = 1024;

    const Slot = struct {
        used: bool = false,
        pack: u32 = 0,
        offset: u64 = 0,
        seq: u32 = 0,
        type: object.Type = .blob,
        bytes: []u8 = &.{},
    };

    /// What `get` hands back. Borrowed until the next `put`.
    pub const Hit = struct { type: object.Type, bytes: []const u8 };

    /// A cache holding at most `limit_bytes` of resolved objects.
    pub fn init(gpa: Allocator, limit_bytes: usize) Allocator.Error!Cache {
        const slots = try gpa.alloc(Slot, slot_count);
        @memset(slots, .{});
        return .{ .gpa = gpa, .limit_bytes = limit_bytes, .slots = slots };
    }

    /// Release everything held.
    pub fn deinit(c: *Cache) void {
        for (c.slots) |slot| {
            if (slot.used) c.gpa.free(slot.bytes);
        }
        c.gpa.free(c.slots);
        c.order.deinit(c.gpa);
        c.* = undefined;
    }

    fn slotFor(pack_id: u32, offset: u64) u32 {
        // The low bits of a pack offset are as good a spread as a hash and
        // cost nothing; the pack id joins them so two packs do not collide
        // systematically.
        return @intCast((offset ^ (@as(u64, pack_id) << 24)) & (slot_count - 1));
    }

    /// The object cached for `offset` in pack `pack_id`, or `null`.
    pub fn get(c: *Cache, pack_id: u32, offset: u64) ?Hit {
        const slot = &c.slots[slotFor(pack_id, offset)];
        if (!slot.used or slot.pack != pack_id or slot.offset != offset) return null;
        return .{ .type = slot.type, .bytes = slot.bytes };
    }

    /// Keep a copy of `bytes`. An object larger than the whole cache is not
    /// kept, rather than emptying it.
    pub fn put(c: *Cache, pack_id: u32, offset: u64, t: object.Type, bytes: []const u8) Allocator.Error!void {
        if (c.limit_bytes == 0 or bytes.len > c.limit_bytes) return;
        const index = slotFor(pack_id, offset);
        const slot = &c.slots[index];
        if (slot.used and slot.pack == pack_id and slot.offset == offset) return;

        while (c.bytes + bytes.len > c.limit_bytes and c.order.items.len > 0) {
            const oldest = c.order.orderedRemove(0);
            const victim = &c.slots[oldest];
            if (victim.used) {
                c.bytes -= victim.bytes.len;
                c.gpa.free(victim.bytes);
                victim.* = .{};
            }
        }

        const copy = try c.gpa.dupe(u8, bytes);
        errdefer c.gpa.free(copy);
        if (slot.used) {
            c.bytes -= slot.bytes.len;
            c.gpa.free(slot.bytes);
            c.removeFromOrder(index);
        }
        try c.order.append(c.gpa, index);
        c.clock += 1;
        slot.* = .{
            .used = true,
            .pack = pack_id,
            .offset = offset,
            .seq = c.clock,
            .type = t,
            .bytes = copy,
        };
        c.bytes += copy.len;
    }

    fn removeFromOrder(c: *Cache, index: u32) void {
        for (c.order.items, 0..) |value, at| {
            if (value == index) {
                _ = c.order.orderedRemove(at);
                return;
            }
        }
    }

    /// Forget everything. Used when a pack directory is re-scanned, because
    /// pack ids move.
    pub fn clear(c: *Cache) void {
        for (c.slots) |*slot| {
            if (slot.used) {
                c.gpa.free(slot.bytes);
                slot.* = .{};
            }
        }
        c.order.clearRetainingCapacity();
        c.bytes = 0;
    }
};

test "a version 1 index is refused by name" {
    const gpa = std.testing.allocator;
    var bytes = try gpa.alloc(u8, 1024 + 40);
    @memset(bytes, 0);
    try std.testing.expectError(error.UnsupportedIndexVersion, Index.parse(gpa, .sha1, bytes));
    bytes = try gpa.alloc(u8, 8 + 1024 + 40);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], idx_magic);
    std.mem.writeInt(u32, bytes[4..8], 7, .big);
    try std.testing.expectError(error.UnknownIndexVersion, Index.parse(gpa, .sha1, bytes));
}

test "fuzz: any bytes are an index or a named error" {
    try std.testing.fuzz({}, fuzzIndex, .{});
}

fn fuzzIndex(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [4096]u8 = undefined;
    const n = smith.slice(&scratch);
    const bytes = try gpa.dupe(u8, scratch[0..n]);
    var index = Index.parse(gpa, .sha1, bytes) catch return;
    defer index.deinit();
    var it = index.iterate();
    while (it.next() catch null) |_| {}
    _ = index.find(Oid.zero(.sha1)) catch {};
    _ = index.findPrefix("ab") catch {};
}
