//! Packfiles, and the `.idx` beside them.
//!
//! A pack is read and written. Reading, both delta kinds resolve, the chain
//! is bounded by a depth cap and a visited set so neither a cycle nor a
//! thousand-deep chain is a hang, and every entry can be rehashed against
//! the name the index gives it. Writing, `Writer` makes the pack a repack or
//! a push sends — to a file, or streamed to a writer — with deltas git's
//! way, and `writeIndexFile` makes the `.idx`, byte for byte git's, for it
//! and for a pack received by `indexpack.zig`.

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
    /// The trailing digest did not match the index bytes before it.
    ChecksumMismatch,
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

        var checksum_hasher: hash.Hasher = .init(kind);
        checksum_hasher.update(bytes[0 .. bytes.len - raw_len]);
        const computed_checksum = checksum_hasher.final();
        const stored_checksum = Oid.fromRaw(kind, bytes[bytes.len - raw_len ..][0..raw_len]) catch unreachable;
        if (!computed_checksum.eql(stored_checksum)) return error.ChecksumMismatch;

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
    file_reader: Io.File.Reader,

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

        var p: Pack = .{
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
            .file_reader = undefined,
        };
        p.file_reader = file.reader(io, input_buffer);
        return p;
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
    fn inflateAt(p: *Pack, at: u64, size: u64) Error![]u8 {
        if (size > delta.max_result_bytes) return error.PackEntrySizeMismatch;
        const out = try p.gpa.alloc(u8, @intCast(size));
        errdefer p.gpa.free(out);

        var fixed_reader: Io.Reader = undefined;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else blk: {
            p.file_reader.seekTo(at) catch return error.TruncatedPack;
            break :blk &p.file_reader.interface;
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
                    base_bytes = try p.inflateAt(header.data_at, header.size);
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
            const delta_bytes = try p.inflateAt(header.data_at, header.size);
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
                        const head = try p.inflateHead(header.data_at, header.size);
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
    fn inflateHead(p: *Pack, at: u64, size: u64) Error![20]u8 {
        var out: [20]u8 = @splat(0);
        const want: usize = @intCast(@min(size, out.len));
        var fixed_reader: Io.Reader = undefined;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else blk: {
            p.file_reader.seekTo(at) catch return error.TruncatedPack;
            break :blk &p.file_reader.interface;
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
/// over a pack is quadratic. Entries are keyed by pack and offset and kept in
/// least-recently-used order, so the byte limit rather than a fixed slot count
/// decides how many small bases survive. This is the only cache in the package
/// apart from the pack indexes themselves.
pub const Cache = struct {
    gpa: Allocator,
    limit_bytes: usize,
    bytes: usize = 0,
    entries: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    oldest: ?*Entry = null,
    newest: ?*Entry = null,

    const Key = struct {
        pack: u32,
        offset: u64,
    };

    const Entry = struct {
        key: Key,
        type: object.Type,
        bytes: []u8,
        older: ?*Entry = null,
        newer: ?*Entry = null,
    };

    /// What `get` hands back. Borrowed until the next `put`.
    pub const Hit = struct { type: object.Type, bytes: []const u8 };

    /// A cache holding at most `limit_bytes` of resolved objects.
    pub fn init(gpa: Allocator, limit_bytes: usize) Allocator.Error!Cache {
        return .{ .gpa = gpa, .limit_bytes = limit_bytes };
    }

    /// Release everything held.
    pub fn deinit(c: *Cache) void {
        var entry = c.oldest;
        while (entry) |current| {
            entry = current.newer;
            c.gpa.free(current.bytes);
            c.gpa.destroy(current);
        }
        c.entries.deinit(c.gpa);
        c.* = undefined;
    }

    /// The object cached for `offset` in pack `pack_id`, or `null`.
    pub fn get(c: *Cache, pack_id: u32, offset: u64) ?Hit {
        const entry = c.entries.get(.{ .pack = pack_id, .offset = offset }) orelse return null;
        c.touch(entry);
        return .{ .type = entry.type, .bytes = entry.bytes };
    }

    /// Keep a copy of `bytes`. An object larger than the whole cache is not
    /// kept, rather than emptying it.
    pub fn put(c: *Cache, pack_id: u32, offset: u64, t: object.Type, bytes: []const u8) Allocator.Error!void {
        if (c.limit_bytes == 0 or bytes.len > c.limit_bytes) return;
        const key: Key = .{ .pack = pack_id, .offset = offset };
        if (c.entries.get(key)) |entry| {
            c.touch(entry);
            return;
        }

        while (c.bytes + bytes.len > c.limit_bytes) c.evictOldest();

        const copy = try c.gpa.dupe(u8, bytes);
        errdefer c.gpa.free(copy);
        const entry = try c.gpa.create(Entry);
        errdefer c.gpa.destroy(entry);
        entry.* = .{
            .key = key,
            .type = t,
            .bytes = copy,
            .older = c.newest,
        };
        try c.entries.put(c.gpa, key, entry);
        if (c.newest) |newest| newest.newer = entry else c.oldest = entry;
        c.newest = entry;
        c.bytes += copy.len;
    }

    fn touch(c: *Cache, entry: *Entry) void {
        if (c.newest == entry) return;
        if (entry.older) |older| older.newer = entry.newer else c.oldest = entry.newer;
        if (entry.newer) |newer| newer.older = entry.older;
        entry.older = c.newest;
        entry.newer = null;
        if (c.newest) |newest| newest.newer = entry else c.oldest = entry;
        c.newest = entry;
    }

    fn evictOldest(c: *Cache) void {
        const entry = c.oldest orelse return;
        c.oldest = entry.newer;
        if (c.oldest) |oldest| oldest.older = null else c.newest = null;
        _ = c.entries.remove(entry.key);
        c.bytes -= entry.bytes.len;
        c.gpa.free(entry.bytes);
        c.gpa.destroy(entry);
    }

    /// Forget everything. Used when a pack directory is re-scanned, because
    /// pack ids move.
    pub fn clear(c: *Cache) void {
        var entry = c.oldest;
        while (entry) |current| {
            entry = current.newer;
            c.gpa.free(current.bytes);
            c.gpa.destroy(current);
        }
        c.entries.clearRetainingCapacity();
        c.oldest = null;
        c.newest = null;
        c.bytes = 0;
    }
};

test "the delta cache is byte-bounded and least recently used" {
    const gpa = std.testing.allocator;
    var cache = try Cache.init(gpa, 6);
    defer cache.deinit();

    try cache.put(0, 10, .blob, "aa");
    try cache.put(0, 20, .blob, "bb");
    try cache.put(0, 30, .blob, "cc");
    try std.testing.expectEqualStrings("aa", cache.get(0, 10).?.bytes);
    try cache.put(0, 40, .blob, "dd");

    try std.testing.expect(cache.get(0, 20) == null);
    try std.testing.expectEqualStrings("aa", cache.get(0, 10).?.bytes);
    try std.testing.expectEqualStrings("cc", cache.get(0, 30).?.bytes);
    try std.testing.expectEqualStrings("dd", cache.get(0, 40).?.bytes);
    try std.testing.expectEqual(@as(usize, 6), cache.bytes);
}

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

test "a pack index with a bad trailing checksum is refused" {
    const gpa = std.testing.allocator;
    const raw_len = Kind.sha1.rawLen();
    const bytes = try gpa.alloc(u8, 8 + 1024 + 2 * raw_len);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], idx_magic);
    std.mem.writeInt(u32, bytes[4..8], 2, .big);
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(bytes[0 .. bytes.len - raw_len]);
    const checksum = hasher.final();
    @memcpy(bytes[bytes.len - raw_len ..], checksum.raw());
    bytes[bytes.len - raw_len - 1] ^= 1;

    try std.testing.expectError(error.ChecksumMismatch, Index.parse(gpa, .sha1, bytes));
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

/// A pack written by hand, for the entries a real packer will not produce.
///
/// Test-only. A hostile pack is a file like any other, and the two shapes
/// that hang a careless reader — a reference-delta cycle and a chain a
/// thousand deep — cannot be made with `git repack`.
const TestPack = struct {
    gpa: Allocator,
    body: std.ArrayList(u8) = .empty,
    names: std.ArrayList(Oid) = .empty,
    offsets: std.ArrayList(u64) = .empty,
    crcs: std.ArrayList(u32) = .empty,

    fn deinit(p: *TestPack) void {
        p.body.deinit(p.gpa);
        p.names.deinit(p.gpa);
        p.offsets.deinit(p.gpa);
        p.crcs.deinit(p.gpa);
    }

    fn init(gpa: Allocator) !TestPack {
        var p: TestPack = .{ .gpa = gpa };
        try p.body.appendSlice(gpa, "PACK");
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], 2, .big);
        std.mem.writeInt(u32, header[4..8], 0, .big);
        try p.body.appendSlice(gpa, &header);
        return p;
    }

    fn writeTypeAndSize(p: *TestPack, type_bits: u3, size: u64) !void {
        var value = size;
        var first: u8 = (@as(u8, type_bits) << 4) | @as(u8, @truncate(value & 0x0f));
        value >>= 4;
        if (value != 0) first |= 0x80;
        try p.body.append(p.gpa, first);
        while (value != 0) {
            var byte: u8 = @truncate(value & 0x7f);
            value >>= 7;
            if (value != 0) byte |= 0x80;
            try p.body.append(p.gpa, byte);
        }
    }

    fn deflate(p: *TestPack, bytes: []const u8) !void {
        const window = try p.gpa.alloc(u8, flate.max_window_len);
        defer p.gpa.free(window);
        // The compressor needs somewhere to put its output; an allocating
        // writer starts with no buffer at all and it asserts against that.
        var out: std.Io.Writer.Allocating = try .initCapacity(p.gpa, 4096);
        defer out.deinit();
        var compress = try flate.Compress.init(&out.writer, window, .zlib, .level_1);
        try compress.writer.writeAll(bytes);
        try compress.writer.flush();
        try compress.finish();
        try p.body.appendSlice(p.gpa, out.written());
    }

    fn finishEntry(p: *TestPack, start: usize, name: Oid) !void {
        try p.names.append(p.gpa, name);
        try p.offsets.append(p.gpa, start);
        try p.crcs.append(p.gpa, std.hash.Crc32.hash(p.body.items[start..]));
    }

    /// A whole object, with the name the caller chooses rather than the one
    /// its content would give it: these packs are about the entry headers.
    fn addObject(p: *TestPack, name: Oid, bytes: []const u8) !u64 {
        const start = p.body.items.len;
        try p.writeTypeAndSize(3, bytes.len);
        try p.deflate(bytes);
        try p.finishEntry(start, name);
        return start;
    }

    /// A delta against an entry `back` bytes earlier, in the biased offset
    /// encoding.
    fn addOfsDelta(p: *TestPack, name: Oid, back: u64, delta_bytes: []const u8) !u64 {
        const start = p.body.items.len;
        try p.writeTypeAndSize(6, delta_bytes.len);
        var buf: [16]u8 = undefined;
        var pos: usize = buf.len - 1;
        var value = back;
        buf[pos] = @intCast(value & 0x7f);
        while (value >> 7 != 0) {
            value >>= 7;
            value -= 1;
            pos -= 1;
            buf[pos] = 0x80 | @as(u8, @intCast(value & 0x7f));
        }
        try p.body.appendSlice(p.gpa, buf[pos..]);
        try p.deflate(delta_bytes);
        try p.finishEntry(start, name);
        return start;
    }

    /// A delta against the object with `base`'s name.
    fn addRefDelta(p: *TestPack, name: Oid, base: Oid, delta_bytes: []const u8) !u64 {
        const start = p.body.items.len;
        try p.writeTypeAndSize(7, delta_bytes.len);
        try p.body.appendSlice(p.gpa, base.raw());
        try p.deflate(delta_bytes);
        try p.finishEntry(start, name);
        return start;
    }

    /// Write `<base>.pack` and `<base>.idx` into `dir`.
    fn write(p: *TestPack, io: Io, dir: Io.Dir, base: []const u8) !void {
        std.mem.writeInt(u32, p.body.items[8..12], @intCast(p.names.items.len), .big);
        var hasher: hash.Hasher = .init(.sha1);
        hasher.update(p.body.items);
        const checksum = hasher.final();

        var pack_name: [64]u8 = undefined;
        var pack_bytes: std.ArrayList(u8) = .empty;
        defer pack_bytes.deinit(p.gpa);
        try pack_bytes.appendSlice(p.gpa, p.body.items);
        try pack_bytes.appendSlice(p.gpa, checksum.raw());
        try dir.writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&pack_name, "{s}.pack", .{base}),
            .data = pack_bytes.items,
        });

        // The index's names must rise, so the entries are sorted here and
        // the offsets follow them.
        const order = try p.gpa.alloc(u32, p.names.items.len);
        defer p.gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        const Ctx = struct {
            names: []const Oid,
            fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                return ctx.names[a].order(ctx.names[b]) == .lt;
            }
        };
        std.mem.sort(u32, order, Ctx{ .names = p.names.items }, Ctx.lessThan);

        var idx: std.ArrayList(u8) = .empty;
        defer idx.deinit(p.gpa);
        try idx.appendSlice(p.gpa, idx_magic);
        var version: [4]u8 = undefined;
        std.mem.writeInt(u32, &version, 2, .big);
        try idx.appendSlice(p.gpa, &version);
        var bucket: usize = 0;
        while (bucket < 256) : (bucket += 1) {
            var count: u32 = 0;
            for (order) |position| {
                if (p.names.items[position].raw()[0] <= bucket) count += 1;
            }
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, count, .big);
            try idx.appendSlice(p.gpa, &value);
        }
        for (order) |position| try idx.appendSlice(p.gpa, p.names.items[position].raw());
        for (order) |position| {
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, p.crcs.items[position], .big);
            try idx.appendSlice(p.gpa, &value);
        }
        for (order) |position| {
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, @intCast(p.offsets.items[position]), .big);
            try idx.appendSlice(p.gpa, &value);
        }
        try idx.appendSlice(p.gpa, checksum.raw());
        var idx_hasher: hash.Hasher = .init(.sha1);
        idx_hasher.update(idx.items);
        try idx.appendSlice(p.gpa, idx_hasher.final().raw());

        var idx_name: [64]u8 = undefined;
        try dir.writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&idx_name, "{s}.idx", .{base}),
            .data = idx.items,
        });
    }
};

fn testName(n: u32) Oid {
    var oid: Oid = .zero(.sha1);
    std.mem.writeInt(u32, oid.bytes[0..4], n *% 2_654_435_761, .big);
    std.mem.writeInt(u32, oid.bytes[16..20], n, .big);
    return oid;
}

/// A delta that copies its whole base, which is the smallest valid delta.
fn identityDelta(gpa: Allocator, size: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var value = size;
    while (true) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        try out.append(gpa, byte);
        if (value == 0) break;
    }
    const header_len = out.items.len;
    try out.appendSlice(gpa, out.items[0..header_len]);
    // Copy from offset 0 for `size` bytes, with one offset byte and one
    // size byte, which is enough for the sizes these tests use.
    try out.append(gpa, 0x80 | 0x01 | 0x10);
    try out.append(gpa, 0);
    try out.append(gpa, @intCast(size));
    return out.toOwnedSlice(gpa);
}

test "two reference deltas naming each other are a named error, not a hang" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const a = testName(1);
    const b = testName(2);
    const patch = try identityDelta(gpa, 8);
    defer gpa.free(patch);

    var builder = try TestPack.init(gpa);
    defer builder.deinit();
    const a_at = try builder.addRefDelta(a, b, patch);
    _ = try builder.addRefDelta(b, a, patch);
    try builder.write(io, tmp.dir, "cycle");

    var p = try Pack.open(gpa, io, tmp.dir, "cycle", .sha1, .{});
    defer p.deinit(io);
    try std.testing.expectError(error.DeltaCycle, p.readAt(io, a_at, null, 0));
}

test "a chain deeper than the cap is refused, and one inside it resolves" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const content = "abcdefgh";
    const patch = try identityDelta(gpa, content.len);
    defer gpa.free(patch);

    var builder = try TestPack.init(gpa);
    defer builder.deinit();
    var base_at = try builder.addObject(testName(0), content);
    var i: u32 = 1;
    // A thousand deep: far past anything a packer writes, and the shape
    // that turns a recursive reader into a stack overflow.
    while (i < 1000) : (i += 1) {
        const back = builder.body.items.len - base_at;
        base_at = try builder.addOfsDelta(testName(i), back, patch);
    }
    const last = base_at;
    try builder.write(io, tmp.dir, "deep");

    {
        // Inside the format's own limit, so it resolves — iteratively, with
        // no recursion to overflow.
        var p = try Pack.open(gpa, io, tmp.dir, "deep", .sha1, .{});
        defer p.deinit(io);
        const found = try p.readAt(io, last, null, 0);
        defer gpa.free(found.bytes);
        try std.testing.expectEqualStrings(content, found.bytes);
    }
    {
        // And a caller that sets a smaller cap gets the refusal rather than
        // the work.
        var p = try Pack.open(gpa, io, tmp.dir, "deep", .sha1, .{ .max_depth = 16 });
        defer p.deinit(io);
        try std.testing.expectError(error.DeltaChainTooDeep, p.readAt(io, last, null, 0));
    }
}

test "an offset delta pointing forwards is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const patch = try identityDelta(gpa, 4);
    defer gpa.free(patch);
    var builder = try TestPack.init(gpa);
    defer builder.deinit();
    // A back-reference larger than the entry's own offset points before the
    // header, which no pack may do.
    const at = try builder.addOfsDelta(testName(7), 1 << 20, patch);
    try builder.write(io, tmp.dir, "forward");

    var p = try Pack.open(gpa, io, tmp.dir, "forward", .sha1, .{});
    defer p.deinit(io);
    try std.testing.expectError(error.BadDeltaOffset, p.readAt(io, at, null, 0));
}

//=====================================================================
// Writing a pack
//
// A pack is a header, its entries in the order the writer chose, and a
// trailing checksum over everything before it; the `.idx` beside it is the
// names sorted, a fanout over the first byte, a CRC per entry and the
// offsets. Nothing here decides *which* objects go in or *what order* they
// go in -- that is a policy, and it lives with the object database.
//
// The pack is written straight to a temporary file as the entries arrive, so
// what is held in memory is one object's bytes, the deflate state, and one
// `WrittenEntry` per object for the index. Nothing is threaded.
//=====================================================================

/// Errors from writing a pack.
pub const WriteError = error{
    /// More objects were added than `init` was told to expect, or fewer.
    /// The count goes in the header, which is written first.
    ObjectCountMismatch,
    /// More objects than the format's count field can hold.
    TooManyObjects,
    /// An offset delta whose base is not already in this pack. An offset
    /// delta may only point backwards.
    DeltaBaseNotWritten,
    /// A name this pack already holds. An index's names must rise, so a
    /// pack cannot hold one twice; `Writer.holds` says whether it does.
    DuplicateObject,
} || Allocator.Error || Io.File.OpenError || Io.Writer.Error ||
    Io.File.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError ||
    Io.Dir.CreateDirError || Io.File.WritePositionalError ||
    Io.File.ReadPositionalError;

/// How hard a pack's entries are compressed.
///
/// git's `pack.compression` falls back to `core.compression`, which is
/// zlib's default. A pack is written once and read many times, which is why
/// the default here is that one rather than the level a loose object gets.
pub const Compression = enum {
    /// zlib's level 1, which is what a loose object gets here.
    fast,
    /// zlib's level 6, which is git's own default for a pack.
    default,
    /// zlib's level 9.
    best,

    fn options(c: Compression) flate.Compress.Options {
        return switch (c) {
            .fast => .level_1,
            .default => .level_6,
            .best => .level_9,
        };
    }
};

/// How a pack is written.
pub const WriteOptions = struct {
    /// How hard the two files are pushed towards the disk before they are
    /// renamed into place. A pack that a loose object is about to be deleted
    /// for wants `batch` at least.
    sync: fs.Sync = .none,
    /// How hard the entries are compressed.
    compression: Compression = .default,
};

/// What a finished pack turned out to be.
pub const WriteReport = struct {
    /// The pack's own trailing checksum, which is the name both files carry:
    /// `pack-<name>.pack` and `pack-<name>.idx`. It is what git names a pack
    /// after too.
    name: Oid,
    /// How many objects the pack holds.
    objects: u32,
    /// The size of the `.pack`, its trailer included.
    pack_bytes: u64,
    /// The size of the `.idx`.
    index_bytes: u64,
    /// How many of the entries are deltas.
    deltas: u32,
};

/// One entry, as the index will need it: its name, where it begins in the
/// pack, and the CRC32 of its bytes there.
pub const IndexEntry = struct {
    oid: Oid,
    offset: u64,
    crc: u32,
};

const WrittenEntry = IndexEntry;

/// A writer for a packfile and its index.
///
/// `init` states how many objects will be added, because that number goes in
/// the header and the header is written first. Every `add` streams straight
/// to the file; `finish` writes the index and renames both into place under
/// the name the pack's checksum gives it.
pub const Writer = struct {
    gpa: Allocator,
    kind: Kind,
    dir: Io.Dir,
    options: WriteOptions,
    /// How many objects the header was written with, or `null` when the
    /// count was not known and the header will be patched at the end.
    expected: ?u32,
    /// The names already written, so that a caller feeding objects it has
    /// not de-duplicated cannot put one in twice -- which an index, whose
    /// names must rise, cannot hold.
    seen: Oid.Set,

    temp: [64]u8,
    temp_len: usize,
    file: Io.File,
    file_writer: Io.File.Writer,
    file_buffer: []u8,

    sink: Sink,
    window: []u8,
    compress: *flate.Compress,

    entries: std.ArrayList(WrittenEntry),
    deltas: u32 = 0,
    finished: bool = false,
    /// Whether the pack goes to a caller's writer rather than to a file:
    /// no index, no rename, and nothing on the disk to take away.
    streaming: bool = false,

    /// How many bytes of the file are buffered before a write.
    const file_buffer_len = 64 * 1024;
    /// The buffer the compressor drains through on its way to the sink.
    const sink_buffer_len = 16 * 1024;

    /// Everything written to the pack goes through here, so the pack's own
    /// checksum, the CRC of the entry being written and the offset of the
    /// next one are all kept without a second pass over the bytes.
    const Sink = struct {
        out: *Io.Writer,
        hasher: hash.Hasher,
        crc: std.hash.Crc32,
        count: u64,
        writer: Io.Writer,
        buffer: [sink_buffer_len]u8,

        fn emit(s: *Sink, bytes: []const u8) Io.Writer.Error!void {
            if (bytes.len == 0) return;
            s.hasher.update(bytes);
            s.crc.update(bytes);
            s.count += bytes.len;
            try s.out.writeAll(bytes);
        }

        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const s: *Sink = @alignCast(@fieldParentPtr("writer", w));
            if (w.end != 0) {
                try s.emit(w.buffer[0..w.end]);
                w.end = 0;
            }
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |slice| {
                try s.emit(slice);
                consumed += slice.len;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| try s.emit(pattern);
            return consumed + pattern.len * splat;
        }
    };

    /// Begin a pack in `dir` holding exactly `object_count` objects.
    ///
    /// `dir` is where `pack-<name>.pack` and `pack-<name>.idx` will land,
    /// which in a repository is `objects/pack`. Nothing is visible under
    /// either name until `finish`.
    pub fn init(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        kind: Kind,
        object_count: u32,
        options: WriteOptions,
    ) WriteError!*Writer {
        return initMaybeCounted(gpa, io, dir, kind, object_count, options);
    }

    /// Begin a pack whose object count is not known yet.
    ///
    /// The count goes in the header and the header goes first, so a pack
    /// written this way has its header patched when it is finished and its
    /// checksum taken over a second pass across the file. That pass is
    /// sequential and one read per buffer, and it is what a caller pays for
    /// not knowing how many objects it is about to write. `init` is the one
    /// to use when it does.
    pub fn initCounting(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        kind: Kind,
        options: WriteOptions,
    ) WriteError!*Writer {
        return initMaybeCounted(gpa, io, dir, kind, null, options);
    }

    /// Begin a pack of exactly `object_count` objects written to `out` as
    /// it goes — a push's pack, on its way to the other side — with no
    /// index and no file. `finish` writes the trailing checksum to `out`;
    /// flushing `out` is the caller's.
    pub fn initStream(
        gpa: Allocator,
        kind: Kind,
        out: *Io.Writer,
        object_count: u32,
        options: WriteOptions,
    ) WriteError!*Writer {
        const w = try gpa.create(Writer);
        errdefer gpa.destroy(w);
        const window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(window);
        const compress = try gpa.create(flate.Compress);
        errdefer gpa.destroy(compress);
        w.* = .{
            .gpa = gpa,
            .kind = kind,
            .dir = undefined,
            .options = options,
            .expected = object_count,
            .temp = undefined,
            .temp_len = 0,
            .file = undefined,
            .file_writer = undefined,
            .file_buffer = &.{},
            .sink = undefined,
            .window = window,
            .compress = compress,
            .entries = .empty,
            .seen = .empty,
            .streaming = true,
        };
        w.sink = .{
            .out = out,
            .hasher = .init(kind),
            .crc = .init(),
            .count = 0,
            .writer = .{ .buffer = &w.sink.buffer, .vtable = &.{ .drain = Sink.drain } },
            .buffer = undefined,
        };
        w.sink.writer.buffer = &w.sink.buffer;
        var header: [12]u8 = undefined;
        @memcpy(header[0..4], "PACK");
        std.mem.writeInt(u32, header[4..8], 2, .big);
        std.mem.writeInt(u32, header[8..12], object_count, .big);
        try w.sink.emit(&header);
        return w;
    }

    fn initMaybeCounted(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        kind: Kind,
        object_count: ?u32,
        options: WriteOptions,
    ) WriteError!*Writer {
        const w = try gpa.create(Writer);
        errdefer gpa.destroy(w);

        var name_buf: [64]u8 = undefined;
        const temp = fs.tempName(io, &name_buf, "tmp_pack_");
        // Readable as well as writable, because a pack whose object count
        // was not known when it began has its header patched and its
        // checksum taken again over the file it has just written.
        const file = try dir.createFile(io, temp, .{ .exclusive = true, .read = true });
        errdefer {
            file.close(io);
            dir.deleteFile(io, temp) catch {};
        }

        const file_buffer = try gpa.alloc(u8, file_buffer_len);
        errdefer gpa.free(file_buffer);
        const window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(window);
        const compress = try gpa.create(flate.Compress);
        errdefer gpa.destroy(compress);

        w.* = .{
            .gpa = gpa,
            .kind = kind,
            .dir = dir,
            .options = options,
            .expected = object_count,
            .temp = undefined,
            .temp_len = temp.len,
            .file = file,
            .file_writer = undefined,
            .file_buffer = file_buffer,
            .sink = undefined,
            .window = window,
            .compress = compress,
            .entries = .empty,
            .seen = .empty,
        };
        @memcpy(w.temp[0..temp.len], temp);
        w.file_writer = file.writer(io, file_buffer);
        w.sink = .{
            .out = &w.file_writer.interface,
            .hasher = .init(kind),
            .crc = .init(),
            .count = 0,
            .writer = .{ .buffer = &w.sink.buffer, .vtable = &.{ .drain = Sink.drain } },
            .buffer = undefined,
        };
        // The buffer field has to point at the struct's own storage, which
        // only exists once the struct does.
        w.sink.writer.buffer = &w.sink.buffer;

        var header: [12]u8 = undefined;
        @memcpy(header[0..4], "PACK");
        std.mem.writeInt(u32, header[4..8], 2, .big);
        std.mem.writeInt(u32, header[8..12], object_count orelse 0, .big);
        try w.sink.emit(&header);
        return w;
    }

    /// Release everything. Safe after `finish` and after `abort`.
    pub fn deinit(w: *Writer, io: Io) void {
        if (!w.finished) w.abort(io);
        w.entries.deinit(w.gpa);
        w.seen.deinit(w.gpa);
        if (w.file_buffer.len != 0) w.gpa.free(w.file_buffer);
        w.gpa.free(w.window);
        w.gpa.destroy(w.compress);
        const gpa = w.gpa;
        gpa.destroy(w);
    }

    /// Give up, leaving the directory as it was.
    pub fn abort(w: *Writer, io: Io) void {
        if (w.finished) return;
        if (w.streaming) {
            w.finished = true;
            return;
        }
        w.file.close(io);
        w.dir.deleteFile(io, w.temp[0..w.temp_len]) catch {};
        w.finished = true;
    }

    /// How many objects have been added.
    pub fn count(w: *const Writer) u32 {
        return @intCast(w.entries.items.len);
    }

    /// Where the next entry will begin.
    pub fn offset(w: *const Writer) u64 {
        return w.sink.count;
    }

    /// Whether this pack already holds an object by that name.
    ///
    /// An index's names must rise, so a pack cannot hold one twice. A caller
    /// feeding objects it has not de-duplicated asks here first.
    pub fn holds(w: *const Writer, oid: Oid) bool {
        return w.seen.contains(oid);
    }

    /// Add a whole object. Returns the offset the entry begins at, which is
    /// what an offset delta against it needs.
    pub fn add(w: *Writer, oid: Oid, t: object.Type, bytes: []const u8) WriteError!u64 {
        const bits: u3 = switch (t) {
            .commit => 1,
            .tree => 2,
            .blob => 3,
            .tag => 4,
        };
        return w.addEntry(oid, bits, bytes.len, &.{}, bytes);
    }

    /// Add an object stored as a delta against one already in this pack.
    ///
    /// `base_offset` must be the offset an earlier `add` returned: the format
    /// only allows an offset delta to point backwards, and a reader that met
    /// one pointing forwards would be reading an object that is not there
    /// yet.
    pub fn addOfsDelta(w: *Writer, oid: Oid, base_offset: u64, delta_bytes: []const u8) WriteError!u64 {
        const at = w.sink.count;
        if (base_offset >= at) return error.DeltaBaseNotWritten;
        var buf: [16]u8 = undefined;
        const encoded = encodeBackOffset(&buf, at - base_offset);
        w.deltas += 1;
        return w.addEntry(oid, 6, delta_bytes.len, encoded, delta_bytes);
    }

    /// Add an object stored as a delta against a name, which need not be in
    /// this pack. A reader resolves it through the database.
    pub fn addRefDelta(w: *Writer, oid: Oid, base: Oid, delta_bytes: []const u8) WriteError!u64 {
        w.deltas += 1;
        return w.addEntry(oid, 7, delta_bytes.len, base.raw(), delta_bytes);
    }

    fn addEntry(
        w: *Writer,
        oid: Oid,
        type_bits: u3,
        payload_len: u64,
        extra: []const u8,
        payload: []const u8,
    ) WriteError!u64 {
        if (w.expected) |expected| {
            if (w.entries.items.len >= expected) return error.ObjectCountMismatch;
        }
        if (w.seen.contains(oid)) return error.DuplicateObject;
        const at = w.sink.count;
        w.sink.crc = .init();

        var head: [16]u8 = undefined;
        const head_len = encodeTypeAndSize(&head, type_bits, payload_len);
        try w.sink.emit(head[0..head_len]);
        if (extra.len != 0) try w.sink.emit(extra);

        w.compress.* = try flate.Compress.init(
            &w.sink.writer,
            w.window,
            .zlib,
            w.options.compression.options(),
        );
        try w.compress.writer.writeAll(payload);
        try w.compress.writer.flush();
        try w.compress.finish();
        try w.sink.writer.flush();

        try w.entries.append(w.gpa, .{ .oid = oid, .offset = at, .crc = w.sink.crc.final() });
        try w.seen.put(w.gpa, oid, {});
        return at;
    }

    /// Close the pack, write its index, and rename both into place.
    ///
    /// The name both files carry is the pack's own trailing checksum, which
    /// is what git names a pack after.
    pub fn finish(w: *Writer, io: Io) WriteError!WriteReport {
        if (w.expected) |expected| {
            if (w.entries.items.len != expected) return error.ObjectCountMismatch;
        }
        if (w.entries.items.len > std.math.maxInt(u32)) return error.TooManyObjects;

        if (w.streaming) {
            const checksum = w.sink.hasher.final();
            try w.sink.out.writeAll(checksum.raw());
            w.finished = true;
            return .{
                .name = checksum,
                .objects = @intCast(w.entries.items.len),
                .pack_bytes = w.sink.count + w.kind.rawLen(),
                .index_bytes = 0,
                .deltas = w.deltas,
            };
        }
        const checksum = if (w.expected != null)
            w.sink.hasher.final()
        else
            try w.patchCountAndRehash(io);
        try w.sink.out.writeAll(checksum.raw());
        const pack_bytes = w.sink.count + w.kind.rawLen();
        try w.file_writer.interface.flush();
        switch (w.options.sync) {
            .none => {},
            .batch, .per_file => try w.file.sync(io),
        }
        w.file.close(io);
        w.finished = true;

        var hex: [hash.max_hex_len]u8 = undefined;
        const text = checksum.hex(&hex);
        var pack_name_buf: [64]u8 = undefined;
        const pack_name = std.fmt.bufPrint(&pack_name_buf, "pack-{s}.pack", .{text}) catch unreachable;
        var idx_name_buf: [64]u8 = undefined;
        const idx_name = std.fmt.bufPrint(&idx_name_buf, "pack-{s}.idx", .{text}) catch unreachable;

        // The index goes to a temporary of its own, because the order the two
        // become visible in is not free to choose: a reader finds a pack by
        // its `.idx`, so an index that is there before its pack is a reader
        // opening a file that does not exist. Pack first, index second, which
        // is git's order too.
        var idx_temp_buf: [64]u8 = undefined;
        const idx_temp = fs.tempName(io, &idx_temp_buf, "tmp_idx_");
        const index_bytes = try w.writeIndex(io, checksum, idx_temp);
        errdefer w.dir.deleteFile(io, idx_temp) catch {};

        fs.renameWithRetry(io, w.dir, w.temp[0..w.temp_len], pack_name) catch |err| {
            w.dir.deleteFile(io, w.temp[0..w.temp_len]) catch {};
            w.dir.deleteFile(io, idx_temp) catch {};
            return err;
        };
        fs.renameWithRetry(io, w.dir, idx_temp, idx_name) catch |err| {
            w.dir.deleteFile(io, idx_temp) catch {};
            return err;
        };

        return .{
            .name = checksum,
            .objects = @intCast(w.entries.items.len),
            .pack_bytes = pack_bytes,
            .index_bytes = index_bytes,
            .deltas = w.deltas,
        };
    }

    /// Put the real object count in the header and take the checksum again.
    ///
    /// The trailing checksum is over every byte before it, the header
    /// included, so a header that changes changes it. One sequential pass
    /// over the file is what that costs, and it is only paid by a caller who
    /// did not know the count when it began.
    fn patchCountAndRehash(w: *Writer, io: Io) WriteError!Oid {
        try w.file_writer.interface.flush();
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(w.entries.items.len), .big);
        _ = try w.file.writePositionalAll(io, &header, 8);

        var hasher: hash.Hasher = .init(w.kind);
        var at: u64 = 0;
        const buffer = w.file_buffer;
        while (at < w.sink.count) {
            const want: usize = @intCast(@min(buffer.len, w.sink.count - at));
            const n = try w.file.readPositionalAll(io, buffer[0..want], at);
            if (n == 0) break;
            hasher.update(buffer[0..n]);
            at += n;
        }
        return hasher.final();
    }

    fn writeIndex(w: *Writer, io: Io, pack_checksum: Oid, idx_name: []const u8) WriteError!u64 {
        return writeIndexFile(w.gpa, io, w.dir, idx_name, w.kind, w.entries.items, pack_checksum, w.options.sync);
    }
};

/// Write the `.idx`, version 2, for a pack whose entries are `entries`, in
/// `dir` as `sub_path`: the magic, the fanout over the first byte of each
/// name, the names sorted, a CRC per entry, the offsets with the 64-bit
/// table for anything past two gigabytes, the pack's checksum and the
/// index's own. `entries` is sorted in place. Returns the index's size.
///
/// What goes in is exactly what `git index-pack` writes for the same pack,
/// byte for byte, which is why a received pack's index and a written one's
/// come from here.
pub fn writeIndexFile(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    kind: Kind,
    entries: []IndexEntry,
    pack_checksum: Oid,
    sync: fs.Sync,
) WriteError!u64 {
    std.mem.sort(WrittenEntry, entries, {}, lessThanWritten);

    const raw_len = kind.rawLen();

    const buffer = try gpa.alloc(u8, Writer.file_buffer_len);
    defer gpa.free(buffer);
    const file = try dir.createFile(io, sub_path, .{ .exclusive = false, .truncate = true });
    var failed = true;
    defer if (failed) {
        file.close(io);
        dir.deleteFile(io, sub_path) catch {};
    };
    var fw = file.writer(io, buffer);
    var hasher: hash.Hasher = .init(kind);
    var written: u64 = 0;

    const Emit = struct {
        fn go(out: *Io.Writer, h: *hash.Hasher, total: *u64, bytes: []const u8) Io.Writer.Error!void {
            h.update(bytes);
            total.* += bytes.len;
            try out.writeAll(bytes);
        }
    };
    const out = &fw.interface;

    var head: [8]u8 = undefined;
    @memcpy(head[0..4], idx_magic);
    std.mem.writeInt(u32, head[4..8], 2, .big);
    try Emit.go(out, &hasher, &written, &head);

    // The fanout: for each first byte, how many names are at or below it.
    var fanout: [256]u32 = @splat(0);
    for (entries) |e| fanout[e.oid.raw()[0]] += 1;
    var running: u32 = 0;
    for (&fanout) |*slot| {
        running += slot.*;
        slot.* = running;
    }
    for (fanout) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try Emit.go(out, &hasher, &written, &bytes);
    }

    for (entries) |e| try Emit.go(out, &hasher, &written, e.oid.raw()[0..raw_len]);
    for (entries) |e| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, e.crc, .big);
        try Emit.go(out, &hasher, &written, &bytes);
    }

    // Anything past two gigabytes goes in the 64-bit table, and its row
    // in the 32-bit table is that row's position with the high bit set.
    var large: std.ArrayList(u64) = .empty;
    defer large.deinit(gpa);
    for (entries) |e| {
        var bytes: [4]u8 = undefined;
        if (e.offset <= std.math.maxInt(u31)) {
            std.mem.writeInt(u32, &bytes, @intCast(e.offset), .big);
        } else {
            std.mem.writeInt(u32, &bytes, 0x8000_0000 | @as(u32, @intCast(large.items.len)), .big);
            try large.append(gpa, e.offset);
        }
        try Emit.go(out, &hasher, &written, &bytes);
    }
    for (large.items) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .big);
        try Emit.go(out, &hasher, &written, &bytes);
    }

    try Emit.go(out, &hasher, &written, pack_checksum.raw()[0..raw_len]);
    const own = hasher.final();
    written += raw_len;
    try out.writeAll(own.raw()[0..raw_len]);
    try out.flush();
    switch (sync) {
        .none => {},
        .batch, .per_file => try file.sync(io),
    }
    file.close(io);
    failed = false;
    return written;
}

test "a written pack and its index read back, entry kind for entry kind" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob_bytes = "a blob with some length to it, so the delta has something to copy\n";
    const tree_bytes = "100644 a\x00" ++ ("\x01" ** 20);
    const commit_bytes = "tree " ++ ("0" ** 40) ++ "\nsome header lines\n\nmessage\n";

    const blob_oid = hash.Hasher.nameObject(.sha1, .{}, "blob", blob_bytes).oid;
    const tree_oid = hash.Hasher.nameObject(.sha1, .{}, "tree", tree_bytes).oid;
    const commit_oid = hash.Hasher.nameObject(.sha1, .{}, "commit", commit_bytes).oid;
    // Two objects that really are the blob with something on the end, so
    // that the names in the index are the names their content gives them and
    // `verify` has something to check.
    const ofs_target = blob_bytes ++ "one\n";
    const ref_target = blob_bytes ++ "two\n";
    const ofs_oid = hash.Hasher.nameObject(.sha1, .{}, "blob", ofs_target).oid;
    const ref_oid = hash.Hasher.nameObject(.sha1, .{}, "blob", ref_target).oid;

    const ofs_delta_bytes = try copyThenInsert(gpa, blob_bytes.len, "one\n");
    defer gpa.free(ofs_delta_bytes);
    const ref_delta_bytes = try copyThenInsert(gpa, blob_bytes.len, "two\n");
    defer gpa.free(ref_delta_bytes);

    var w = try Writer.init(gpa, io, tmp.dir, .sha1, 5, .{});
    defer w.deinit(io);
    const blob_at = try w.add(blob_oid, .blob, blob_bytes);
    _ = try w.add(tree_oid, .tree, tree_bytes);
    _ = try w.add(commit_oid, .commit, commit_bytes);
    _ = try w.addOfsDelta(ofs_oid, blob_at, ofs_delta_bytes);
    _ = try w.addRefDelta(ref_oid, blob_oid, ref_delta_bytes);
    const report = try w.finish(io);

    try std.testing.expectEqual(@as(u32, 5), report.objects);
    try std.testing.expectEqual(@as(u32, 2), report.deltas);

    var hex: [hash.max_hex_len]u8 = undefined;
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "pack-{s}", .{report.name.hex(&hex)});

    var p = try Pack.open(gpa, io, tmp.dir, base, .sha1, .{});
    defer p.deinit(io);
    try std.testing.expectEqual(@as(u32, 5), p.index.count);
    try std.testing.expectEqual(@as(u32, 5), p.count);
    try std.testing.expect(p.index.pack_checksum.eql(report.name));

    // Every name the index carries resolves, and every object comes back as
    // what went in.
    const wanted: []const struct { oid: Oid, t: object.Type, bytes: []const u8 } = &.{
        .{ .oid = blob_oid, .t = .blob, .bytes = blob_bytes },
        .{ .oid = tree_oid, .t = .tree, .bytes = tree_bytes },
        .{ .oid = commit_oid, .t = .commit, .bytes = commit_bytes },
        .{ .oid = ofs_oid, .t = .blob, .bytes = ofs_target },
        .{ .oid = ref_oid, .t = .blob, .bytes = ref_target },
    };
    for (wanted) |want| {
        const found = (try p.index.find(want.oid)).?;
        const got = try p.readAt(io, found.offset, null, 0);
        defer gpa.free(got.bytes);
        try std.testing.expectEqual(want.t, got.type);
        try std.testing.expectEqualSlices(u8, want.bytes, got.bytes);
    }

    // And the pack checks out against its own trailer and every CRC.
    try p.verifyChecksum(io);
    const checked = try p.verify(io, null, 0);
    try std.testing.expectEqual(@as(u32, 5), checked.objects);
}

test "fuzz: a pack this writes is a pack this reads" {
    try std.testing.fuzz({}, fuzzWriter, .{});
}

fn fuzzWriter(_: void, smith: *std.testing.Smith) anyerror!void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const count = smith.valueRangeAtMost(u8, 1, 7);
    var bodies: [7][]u8 = undefined;
    var names: [7]Oid = undefined;
    var kinds: [7]object.Type = undefined;
    var written: usize = 0;
    defer for (bodies[0..written]) |b| gpa.free(b);

    var w = try Writer.initCounting(gpa, io, tmp.dir, .sha1, .{});
    defer w.deinit(io);

    for (0..count) |i| {
        var scratch: [256]u8 = undefined;
        const body = scratch[0..smith.slice(&scratch)];
        kinds[i] = switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0 => .blob,
            1 => .tree,
            2 => .commit,
            else => .tag,
        };
        bodies[i] = try gpa.dupe(u8, body);
        written += 1;
        names[i] = hash.Hasher.nameObject(.sha1, .{}, kinds[i].name(), bodies[i]).oid;
        if (w.holds(names[i])) continue;

        // Sometimes a delta against the entry before it, which is the other
        // way an object can be in a pack.
        if (i != 0 and w.count() != 0 and smith.valueRangeAtMost(u8, 0, 1) == 0) {
            const base = bodies[i - 1];
            const encoded = (try delta.encode(gpa, base, bodies[i], .{})) orelse continue;
            defer gpa.free(encoded);
            const base_offset = w.entries.items[w.count() - 1].offset;
            if (kinds[i] != kinds[i - 1]) continue;
            _ = try w.addOfsDelta(names[i], base_offset, encoded);
            continue;
        }
        _ = try w.add(names[i], kinds[i], bodies[i]);
    }

    const report = try w.finish(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "pack-{s}", .{report.name.hex(&hex)});
    var p = try Pack.open(gpa, io, tmp.dir, base, .sha1, .{});
    defer p.deinit(io);
    // Rehashes every object against the name the index gives it, deltas
    // resolved, and checks every CRC and the trailer.
    const checked = try p.verify(io, null, 0);
    if (checked.objects != report.objects) return error.PackDidNotRoundTrip;
}

test "a pack written to a stream is byte for byte the pack written to a file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const base_bytes = "a base with enough in it for a delta to copy from\n";
    const target = base_bytes ++ "and a line more\n";
    const base_oid = hash.Hasher.object(.sha1, "blob", base_bytes);
    const target_oid = hash.Hasher.object(.sha1, "blob", target);
    const patch = try copyThenInsert(gpa, base_bytes.len, "and a line more\n");
    defer gpa.free(patch);

    var file_writer = try Writer.init(gpa, io, tmp.dir, .sha1, 2, .{});
    defer file_writer.deinit(io);
    const at = try file_writer.add(base_oid, .blob, base_bytes);
    _ = try file_writer.addOfsDelta(target_oid, at, patch);
    const written = try file_writer.finish(io);

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var stream_writer = try Writer.initStream(gpa, .sha1, &stream.writer, 2, .{});
    defer stream_writer.deinit(io);
    const stream_at = try stream_writer.add(base_oid, .blob, base_bytes);
    _ = try stream_writer.addOfsDelta(target_oid, stream_at, patch);
    const streamed = try stream_writer.finish(io);

    try std.testing.expect(written.name.eql(streamed.name));
    var hex: [hash.max_hex_len]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const pack_name = try std.fmt.bufPrint(&name_buf, "pack-{s}.pack", .{written.name.hex(&hex)});
    const on_disk = try tmp.dir.readFileAlloc(io, pack_name, gpa, .unlimited);
    defer gpa.free(on_disk);
    try std.testing.expectEqualSlices(u8, on_disk, stream.written());
}

test "a pack with no objects is still a pack" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var w = try Writer.init(gpa, io, tmp.dir, .sha1, 0, .{});
    defer w.deinit(io);
    const report = try w.finish(io);
    try std.testing.expectEqual(@as(u32, 0), report.objects);
    try std.testing.expectEqual(@as(u64, 12 + 20), report.pack_bytes);

    var hex: [hash.max_hex_len]u8 = undefined;
    var base_buf: [64]u8 = undefined;
    var p = try Pack.open(gpa, io, tmp.dir, try std.fmt.bufPrint(&base_buf, "pack-{s}", .{report.name.hex(&hex)}), .sha1, .{});
    defer p.deinit(io);
    try std.testing.expectEqual(@as(u32, 0), p.index.count);
}

test "a writer that is given the wrong count refuses rather than lying in the header" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var w = try Writer.init(gpa, io, tmp.dir, .sha1, 1, .{});
    defer w.deinit(io);
    try std.testing.expectError(error.ObjectCountMismatch, w.finish(io));
    _ = try w.add(testName(1), .blob, "x");
    try std.testing.expectError(error.ObjectCountMismatch, w.add(testName(2), .blob, "y"));

    // An offset delta may only point backwards.
    var w2 = try Writer.init(gpa, io, tmp.dir, .sha1, 1, .{});
    defer w2.deinit(io);
    const identity = try identityDelta(gpa, 1);
    defer gpa.free(identity);
    try std.testing.expectError(error.DeltaBaseNotWritten, w2.addOfsDelta(testName(3), 1 << 20, identity));
}

test "an aborted pack leaves the directory as it was" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var w = try Writer.init(gpa, io, tmp.dir, .sha1, 2, .{});
        defer w.deinit(io);
        _ = try w.add(testName(7), .blob, "abandoned");
    }
    var it = tmp.dir.iterate();
    try std.testing.expect((try it.next(io)) == null);
}

/// A delta that copies the whole base and then inserts `suffix`, by hand:
/// the two sizes, one copy command with a one-byte offset and a one-byte
/// size, and one insert command. Good for a base under 256 bytes and a
/// suffix under 128, which is what these tests use.
fn copyThenInsert(gpa: Allocator, base_len: usize, suffix: []const u8) ![]u8 {
    std.debug.assert(base_len < 256 and suffix.len < 128 and suffix.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intCast(base_len));
    const target_len = base_len + suffix.len;
    var value = target_len;
    while (true) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        try out.append(gpa, byte);
        if (value == 0) break;
    }
    // Copy: the command byte says which offset and size bytes follow.
    try out.append(gpa, 0x80 | 0x01 | 0x10);
    try out.append(gpa, 0);
    try out.append(gpa, @intCast(base_len));
    // Insert: the command byte is the length.
    try out.append(gpa, @intCast(suffix.len));
    try out.appendSlice(gpa, suffix);
    return out.toOwnedSlice(gpa);
}

fn lessThanWritten(_: void, a: WrittenEntry, b: WrittenEntry) bool {
    return std.mem.order(u8, a.oid.raw(), b.oid.raw()) == .lt;
}

/// The type-and-size byte string a pack entry begins with: three type bits
/// and four size bits in the first byte, then seven size bits per byte after
/// it. Returns how many bytes it took.
fn encodeTypeAndSize(buf: []u8, type_bits: u3, size: u64) usize {
    var value = size;
    var i: usize = 0;
    var first: u8 = (@as(u8, type_bits) << 4) | @as(u8, @truncate(value & 0x0f));
    value >>= 4;
    if (value != 0) first |= 0x80;
    buf[i] = first;
    i += 1;
    while (value != 0) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        buf[i] = byte;
        i += 1;
    }
    return i;
}

/// The biased offset varint an offset delta carries, which is a different
/// encoding from the size varint a few bytes earlier in the same entry.
fn encodeBackOffset(buf: []u8, back: u64) []const u8 {
    var pos: usize = buf.len - 1;
    var value = back;
    buf[pos] = @intCast(value & 0x7f);
    while (value >> 7 != 0) {
        value >>= 7;
        value -= 1;
        pos -= 1;
        buf[pos] = 0x80 | @as(u8, @intCast(value & 0x7f));
    }
    return buf[pos..];
}
