//! Packfiles, and the `.idx` beside them.
//!
//! A pack is read and written. Reading, both delta kinds resolve, the chain
//! is bounded by a depth cap and a visited set so neither a cycle nor a
//! thousand-deep chain is a hang, and every entry can be rehashed against
//! the name the index gives it. Writing, `Writer` makes the pack a repack or
//! a push sends — to a file, or streamed to a writer — with deltas git's
//! way, and `writeIndexFile` makes the `.idx`, byte for byte git's, for it
//! and for a pack received by `indexpack.zig`.

const ErrorNamespace = @This();
const Self = @This();
const retention = @import("keep.zig");

const std = @import("std");
const entry_mod = @import("pack/entry.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const warp = @import("warp");

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const delta = @import("../codec.zig").delta;
const revindex = @import("revindex.zig");
const fs = @import("../fs/fs.zig");

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

/// The unit a positional pack read is made in. Every read of a block starts
/// at a multiple of this many bytes into the file and covers one block, so
/// where a read lands depends on the bytes wanted and never on the reads
/// before it.
pub const read_block_bytes = 8 * 1024;

/// How many bytes of a pack its positional reads keep by default: up to
/// 32 MiB, never more than the pack, each block allocated when it is first
/// read. A pack this size or smaller is read at most once whatever order
/// its objects are read in, as a memory map would read it, without the map.
/// Reading 24,000 blobs in name order from a 14.5 MB pack made a read call
/// for nearly every blob with 256 KiB, which cost a fifth of the time.
pub const default_read_cache_bytes = 32 * 1024 * 1024;

/// An entry whose stated size is at least this streams through a buffer of
/// its own rather than through the blocks.
const stream_entry_bytes = 64 * 1024;
/// How much a streamed entry reads at a time.
const stream_buffer_bytes = 64 * 1024;
/// Room in front of each block for the few bytes a decoder had not taken
/// from the block before it, so that the two read as one run.
const block_prefix = 64;
/// One slot: the prefix, the block, and one byte past it, so that a reader
/// at the end of a whole block always asks for the next one rather than for
/// room in this one.
const block_stride = block_prefix + read_block_bytes + 1;
const no_block = std.math.maxInt(u64);

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
    pub const Error = ErrorNamespace.Error;

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

    pub const OpenOptions = struct {
        kind: Kind,
        max_bytes: usize = 1 << 30,
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
        options: OpenOptions,
    ) Self.IndexError!Index {
        const kind = options.kind;
        const bytes = try dir.readFileAlloc(io, sub_path, gpa, .limited(options.max_bytes));
        // parse takes ownership on success and failure.
        return parse(gpa, kind, bytes);
    }

    /// Read an index from bytes this takes ownership of.
    pub fn parse(gpa: Allocator, kind: Kind, bytes: []u8) Self.IndexError!Index {
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
        // unreachable: the slice is cut to the format's raw length
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

        // unreachable: the slice is cut to the format's raw length
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
        // unreachable: rawNameAt cuts the name to the format's raw length
        return Oid.fromRaw(index.kind, index.rawNameAt(i)) catch unreachable;
    }

    /// The pack offset of the object at position `i`.
    pub fn offsetAt(index: Index, i: u32) Self.IndexError!u64 {
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
    pub fn find(index: Index, oid: Oid) Self.IndexError!?Located {
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
        // The smallest name that begins with the prefix: its digits, and
        // zeros after them.
        var least: [hash.max_raw_len]u8 = @splat(0);
        for (prefix, 0..) |c, i| {
            const digit = hexVal(c) catch return null;
            least[i / 2] |= if (i % 2 == 0) digit << 4 else digit;
        }
        const raw = least[0..index.kind.rawLen()];
        // A whole first byte narrows the search to its fanout bucket.
        var lo: u32 = 0;
        var hi: u32 = index.count;
        if (prefix.len >= 2) {
            lo = if (raw[0] == 0) 0 else std.mem.readInt(u32, index.bytes[8 + (@as(usize, raw[0]) - 1) * 4 ..][0..4], .big);
            hi = std.mem.readInt(u32, index.bytes[8 + @as(usize, raw[0]) * 4 ..][0..4], .big);
        }
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, index.rawNameAt(mid), raw) == .lt) lo = mid + 1 else hi = mid;
        }
        // Every name that begins with the prefix is in one run from here.
        if (lo >= index.count) return null;
        const found = index.nameAt(lo);
        if (!found.startsWithHex(prefix)) return null;
        if (lo + 1 < index.count and index.nameAt(lo + 1).startsWithHex(prefix)) return error.AmbiguousPrefix;
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
        pub fn next(it: *Iterator) Self.IndexError!?struct { oid: Oid, located: Located } {
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
    /// The pack's object count or its trailing checksum is not the one its
    /// index records: the two files are not a pair, and an offset the index
    /// gives would read another object. git's "packfile does not match
    /// index".
    PackIndexMismatch,
} || IndexError || delta.Error || Io.File.OpenError ||
    Io.File.ReadPositionalError || Io.File.Reader.Error || Io.File.Reader.SeekError || Io.File.StatError || Io.File.MemoryMap.CreateError;

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
    pub const Error = ErrorNamespace.Error;

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
    /// Scratch for one inflate at a time. A pack is read by one task at a
    /// time, and a delta chain is resolved one entry after another, so one
    /// Warp decoder serves both partial header and whole-entry reads.
    decoder: *warp.Decompressor,
    /// The blocks positional reads keep, direct-mapped: block `b` of the
    /// file can only be in slot `b % slots`, and there are never more slots
    /// than the file has blocks. A slot's `block_stride` bytes are allocated
    /// when it is first filled, so a pack holds what of it was read, up to
    /// `slots` blocks; the slot tables are allocated on the first
    /// positional read.
    slots: usize,
    slot_memory: []?[*]u8 = &.{},
    block_ids: []u64 = &.{},
    block_lens: []u32 = &.{},
    /// The reader an entry is inflated through: it walks the blocks.
    block_reader: Io.Reader = undefined,
    /// The Io and block of the read in progress through `block_reader`.
    reader_io: Io = undefined,
    reader_block: u64 = 0,
    /// Why the reader in progress failed, when it says `ReadFailed`.
    read_err: ?ErrorNamespace.Error = null,
    /// A large entry's own buffer and reader, made afresh for each one.
    stream_buffer: []u8 = &.{},
    stream_reader: Io.File.Reader = undefined,

    pub const OpenInputs = struct { base: []const u8, kind: Kind };
    pub const OpenOptions = struct {
        access: Access = .read,
        max_depth: u32 = default_max_depth,
        max_chain_bytes: u64 = default_max_chain_bytes,
        max_index_bytes: usize = 1 << 30,
        /// How many bytes of the pack positional reads keep, in aligned
        /// `read_block_bytes` blocks, at least one and never more than
        /// the pack has, each allocated when first read. A pass over objects
        /// an earlier pass read, with the delta-base cache holding at
        /// each step at least what it held then, reads no more blocks.
        read_cache_bytes: usize = default_read_cache_bytes,
    };

    /// Open `<base>.pack` and `<base>.idx` in `dir`.
    /// `base` is the name without an extension; inputs and options are borrowed.
    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        inputs: OpenInputs,
        options: OpenOptions,
    ) Self.Error!Pack {
        const base = inputs.base;
        const kind = inputs.kind;
        // The pack first: an index with no pack beside it is one being
        // written, or left behind, and is `FileNotFound` whatever it holds.
        var pack_buf: [512]u8 = undefined;
        const pack_name = std.mem.print(&pack_buf, "{s}.pack", .{base}) catch return error.NameTooLong;
        const file = try dir.openFile(io, pack_name, .{});
        errdefer file.close(io);

        var name_buf: [512]u8 = undefined;
        const idx_name = std.mem.print(&name_buf, "{s}.idx", .{base}) catch return error.NameTooLong;
        var index = try Index.open(gpa, io, dir, idx_name, .{ .kind = kind, .max_bytes = options.max_index_bytes });
        errdefer index.deinit();

        const stat = try file.stat(io);
        const raw_len = kind.rawLen();
        if (stat.size < 12 + raw_len) return error.TruncatedPack;

        var header: [12]u8 = undefined;
        _ = try file.readPositionalAll(io, &header, 0);
        if (!std.mem.eql(u8, header[0..4], "PACK")) return error.NotAPack;
        const version = std.mem.readInt(u32, header[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;
        const count = std.mem.readInt(u32, header[8..12], .big);
        // git's `open_packed_git_1`: the pack must be the one the index was
        // made from, by its count and by the checksum ending both.
        if (count != index.count) return error.PackIndexMismatch;
        var trailer: [hash.max_raw_len]u8 = undefined;
        if (try file.readPositionalAll(io, trailer[0..raw_len], stat.size - raw_len) != raw_len) return error.TruncatedPack;
        if (!std.mem.eql(u8, trailer[0..raw_len], index.pack_checksum.raw())) return error.PackIndexMismatch;

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

        const decoder = try gpa.create(warp.Decompressor);
        errdefer gpa.destroy(decoder);
        decoder.* = .{};

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
            .decoder = decoder,
            // unreachable: read_block_bytes is a nonzero constant
            .slots = @intCast(@max(1, @min(options.read_cache_bytes / read_block_bytes, std.math.divCeil(u64, stat.size, read_block_bytes) catch unreachable))),
        };
    }

    /// The slot block `id` is in, read from the file if it is not there.
    ///
    /// A read is exactly one block, so what it costs depends only on which
    /// block is wanted, and a slot only ever changes to the block wanted.
    /// That is what makes the cache monotone: a sequence of reads that is
    /// part of another, block for block, never costs more than it.
    fn loadBlock(p: *Pack, io: Io, id: u64) ErrorNamespace.Error!usize {
        if (p.slot_memory.len == 0) {
            const memory = try p.gpa.alloc(?[*]u8, p.slots);
            errdefer p.gpa.free(memory);
            const ids = try p.gpa.alloc(u64, p.slots);
            errdefer p.gpa.free(ids);
            const lens = try p.gpa.alloc(u32, p.slots);
            @memset(memory, null);
            @memset(ids, no_block);
            p.slot_memory = memory;
            p.block_ids = ids;
            p.block_lens = lens;
        }
        const slot: usize = @intCast(id % p.slots);
        if (p.block_ids[slot] == id) return slot;
        const start = id * read_block_bytes;
        if (start >= p.size) return error.TruncatedPack;
        const len: usize = @intCast(@min(read_block_bytes, p.size - start));
        if (p.slot_memory[slot] == null) p.slot_memory[slot] = (try p.gpa.alloc(u8, block_stride)).ptr;
        // Claimed only once read whole: a failure leaves the slot empty.
        p.block_ids[slot] = no_block;
        const dest = p.slotBytes(slot)[block_prefix..][0..len];
        var done: usize = 0;
        while (done < len) {
            const n = try p.file.readPositional(io, &.{dest[done..]}, start + done);
            if (n == 0) return error.TruncatedPack;
            done += n;
        }
        p.block_ids[slot] = id;
        p.block_lens[slot] = @intCast(len);
        return slot;
    }

    fn slotBytes(p: *Pack, slot: usize) []u8 {
        return p.slot_memory[slot].?[0..block_stride];
    }

    /// The pack's bytes from `offset` to the end of the block it is in.
    fn blockBytesAt(p: *Pack, io: Io, offset: u64) ErrorNamespace.Error![]const u8 {
        const id = offset / read_block_bytes;
        const slot = try p.loadBlock(io, id);
        const from: usize = @intCast(offset - id * read_block_bytes);
        return p.slotBytes(slot)[block_prefix..][from..p.block_lens[slot]];
    }

    const block_vtable: Io.Reader.VTable = .{
        .stream = blockStream,
        .readVec = blockReadVec,
        .rebase = blockRebase,
    };

    /// A reader over the pack from `at`, through the blocks.
    fn blockReaderAt(p: *Pack, io: Io, at: u64) ErrorNamespace.Error!*Io.Reader {
        const id = at / read_block_bytes;
        const slot = try p.loadBlock(io, id);
        p.reader_io = io;
        p.reader_block = id;
        p.read_err = null;
        p.block_reader = .{
            .vtable = &block_vtable,
            .buffer = p.slotBytes(slot),
            .seek = block_prefix + @as(usize, @intCast(at - id * read_block_bytes)),
            .end = block_prefix + p.block_lens[slot],
        };
        return &p.block_reader;
    }

    /// Move the reader on to the next block. What the reader had not taken
    /// from this one — never more than a decoder asks for at once — goes in
    /// front of the next block, in that slot's prefix, so the two read as
    /// one run; neither block's own bytes move.
    fn nextBlock(r: *Io.Reader) Io.Reader.Error!void {
        const p: *Pack = @alignCast(@fieldParentPtr("block_reader", r)); // safe: installed only on a Pack's block_reader
        const next = p.reader_block + 1;
        if (next * read_block_bytes >= p.size) return error.EndOfStream;
        const kept = r.end - r.seek;
        if (kept > block_prefix) {
            p.read_err = error.CorruptPackEntry;
            return error.ReadFailed;
        }
        var carry: [block_prefix]u8 = undefined;
        @memcpy(carry[0..kept], r.buffer[r.seek..r.end]);
        const slot = p.loadBlock(p.reader_io, next) catch |err| {
            p.read_err = err;
            return error.ReadFailed;
        };
        const bytes = p.slotBytes(slot);
        @memcpy(bytes[block_prefix - kept .. block_prefix], carry[0..kept]);
        r.buffer = bytes;
        r.seek = block_prefix - kept;
        r.end = block_prefix + p.block_lens[slot];
        p.reader_block = next;
    }

    fn blockReadVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        _ = data;
        try nextBlock(r);
        return 0;
    }

    fn blockStream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        try nextBlock(r);
        return 0;
    }

    fn blockRebase(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        if (r.buffer.len - r.seek >= capacity) return;
        try nextBlock(r);
    }

    /// A reader over the pack from `at` with a buffer of its own, made
    /// afresh: what it reads depends on the entry alone, and it leaves the
    /// blocks as they were.
    fn streamReaderAt(p: *Pack, io: Io, at: u64) ErrorNamespace.Error!*Io.Reader {
        if (p.stream_buffer.len == 0) p.stream_buffer = try p.gpa.alloc(u8, stream_buffer_bytes);
        p.stream_reader = p.file.reader(io, p.stream_buffer);
        p.stream_reader.seekTo(at) catch |err| return switch (err) {
            error.EndOfStream => error.TruncatedPack,
            error.ReadFailed => p.stream_reader.err orelse error.ReadFailed,
            else => |e| e,
        };
        return &p.stream_reader.interface;
    }

    /// Close the pack and release everything it holds.
    pub fn deinit(p: *Pack, io: Io) void {
        p.gpa.destroy(p.decoder);
        if (p.slot_memory.len != 0) {
            for (p.slot_memory) |memory| if (memory) |bytes| p.gpa.free(@as([]u8, bytes[0..block_stride]));
            p.gpa.free(p.slot_memory);
            p.gpa.free(p.block_ids);
            p.gpa.free(p.block_lens);
        }
        if (p.stream_buffer.len != 0) p.gpa.free(p.stream_buffer);
        if (p.mapping) |*m| m.destroy(io);
        p.file.close(io);
        p.index.deinit();
        p.* = undefined;
    }

    /// Where the entries end and the trailing checksum begins.
    pub fn bodyEnd(p: *const Pack) u64 {
        return p.size - p.kind.rawLen();
    }

    fn readAtExact(p: *Pack, io: Io, offset: u64, out: []u8) ErrorNamespace.Error!void {
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

    /// The `out.len` packed bytes from `offset`, as they are in the file,
    /// read positionally or from the mapping. Nothing of the pack that
    /// changes is touched, so tasks call it at once on one pack.
    pub fn readStored(p: *const Pack, io: Io, offset: u64, out: []u8) Self.Error!void {
        if (offset > p.size or out.len > p.size - offset) return error.TruncatedPack;
        if (p.memory) |mem| {
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

    /// The header of the entry at `offset`, without inflating anything.
    pub fn entryHeaderAt(p: *Pack, io: Io, offset: u64) Self.Error!EntryHeader {
        if (offset < 12 or offset >= p.bodyEnd()) return error.TruncatedPack;
        var buf: [32 + hash.max_raw_len]u8 = undefined;
        const available: usize = @intCast(@min(buf.len, p.bodyEnd() - offset));
        if (p.memory) |mem| {
            return (try p.parseEntryHeader(offset, mem[@intCast(offset)..][0..available])) orelse error.TruncatedPack;
        }
        // From the block the entry starts in, and from the next one only
        // when the header runs into it.
        var n: usize = 0;
        while (true) {
            const chunk = try p.blockBytesAt(io, offset + n);
            const take = @min(chunk.len, available - n);
            @memcpy(buf[n..][0..take], chunk[0..take]);
            n += take;
            if (try p.parseEntryHeader(offset, buf[0..n])) |header| return header;
            if (n == available) return error.TruncatedPack;
        }
    }

    /// The header at the start of `bytes`, which begin at `offset`, or
    /// `null` when it runs past their end.
    pub fn parseEntryHeader(p: *const Pack, offset: u64, bytes: []const u8) Self.Error!?EntryHeader {
        var i: usize = 0;
        if (i >= bytes.len) return null;
        var byte = bytes[i];
        i += 1;
        const type_bits: u3 = @truncate(byte >> 4);
        var size: u64 = byte & 0x0f;
        var shift: u6 = 4;
        while (byte & 0x80 != 0) {
            if (i >= bytes.len) return null;
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
                if (i >= bytes.len) return null;
                byte = bytes[i];
                i += 1;
                var back: u64 = byte & 0x7f;
                while (byte & 0x80 != 0) {
                    if (i >= bytes.len) return null;
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
                if (i + raw_len > bytes.len) return null;
                // unreachable: the slice is cut to the format's raw length
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
    fn inflateAt(p: *Pack, io: Io, at: u64, size: u64) ErrorNamespace.Error![]u8 {
        const result_len = try inflatedLen(size);
        const out = try p.gpa.alloc(u8, result_len +| decode_slack);
        errdefer p.gpa.free(out);
        try p.decodeAt(io, at, size, out);
        return p.gpa.realloc(out, result_len);
    }

    /// `inflateAt` into `out`, which is cleared, grows as needed and then
    /// holds exactly the entry.
    fn inflateInto(p: *Pack, io: Io, at: u64, size: u64, out: *std.ArrayList(u8)) ErrorNamespace.Error!void {
        const result_len = try inflatedLen(size);
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(p.gpa, result_len +| decode_slack);
        try p.decodeAt(io, at, size, out.allocatedSlice()[0 .. result_len + decode_slack]);
        out.items.len = result_len;
    }

    /// Leave one longest match and its word-copy slack after the result, so
    /// the fast decoder can also handle the last bytes of an entry.
    const decode_slack = warp.inflate_margin;

    fn inflatedLen(size: u64) ErrorNamespace.Error!usize {
        if (size > delta.max_result_bytes) return error.StreamTooLong;
        return std.math.cast(usize, size) orelse error.StreamTooLong;
    }

    /// Decode the `size`-byte entry at `at` into the front of `out`, which
    /// has `decode_slack` bytes of room past it.
    fn decodeAt(p: *Pack, io: Io, at: u64, size: u64, out: []u8) ErrorNamespace.Error!void {
        const result_len: usize = @intCast(size);
        var fixed_reader: Io.Reader = undefined;
        const streamed = p.memory == null and size >= stream_entry_bytes;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else if (streamed)
            try p.streamReaderAt(io, at)
        else
            try p.blockReaderAt(io, at);

        // The whole entry in one pass, with bounded scratch past the result:
        // Warp keeps only reusable decoding tables, with no copied history.
        const n = p.decoder.inflateReader(input, out, .{}) catch |err| switch (err) {
            error.ReadFailed => return if (streamed)
                p.stream_reader.err orelse error.ReadFailed
            else
                p.read_err orelse error.ReadFailed,
            error.Truncated, error.InvalidStream, error.ChecksumMismatch, error.DictionaryMismatch, error.OutputTooSmall => return error.CorruptPackEntry,
        };
        if (n.out_len != result_len) return error.CorruptPackEntry;
    }

    /// What one task inflates pack entries with, apart from the pack's own
    /// decoder and blocks, so that several tasks read one pack at once:
    /// `inflateWith`.
    pub const EntryReader = struct {
        decoder: warp.Decompressor = .{},
        buffer: [stream_buffer_bytes]u8 = undefined,
    };

    /// The room `inflateWith` needs in `out` past the entry's stated size.
    pub const inflate_slack = decode_slack;

    /// Inflate the whole object whose entry's data begins at `at` and
    /// states `size` bytes into the front of `out`, which holds `size +
    /// inflate_slack`, with `reader`'s decoder and buffer.
    ///
    /// It reads the pack file positionally, or the mapping, and nothing of
    /// the pack that changes — not the blocks and not the decoder the other
    /// reads use — so tasks call it at once on one pack, each with a reader
    /// of its own. A delta has no whole object to inflate here: its base is
    /// `readAt`'s, with the delta-base cache.
    pub const InflateInputs = struct { reader: *EntryReader, at: u64, size: u64 };

    pub fn inflateWith(p: *const Pack, io: Io, inputs: InflateInputs, out: []u8) Self.Error!void {
        const reader = inputs.reader;
        const at = inputs.at;
        const size = inputs.size;
        const result_len = try inflatedLen(size);
        if (out.len < result_len +| decode_slack) return error.StreamTooLong;
        var fixed_reader: Io.Reader = undefined;
        var file_reader: Io.File.Reader = undefined;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else blk: {
            // No more read ahead than the stream can take: a deflated entry
            // is at most an eighth longer than what it holds.
            const want = @min(reader.buffer.len, result_len +| result_len / 8 +| 64);
            file_reader = p.file.reader(io, reader.buffer[0..want]);
            file_reader.seekTo(at) catch |err| return switch (err) {
                error.EndOfStream => error.TruncatedPack,
                error.ReadFailed => file_reader.err orelse error.ReadFailed,
                else => |e| e,
            };
            break :blk &file_reader.interface;
        };
        const n = reader.decoder.inflateReader(input, out[0 .. result_len + decode_slack], .{}) catch |err| switch (err) {
            error.ReadFailed => return if (p.memory == null) file_reader.err orelse error.ReadFailed else error.ReadFailed,
            error.Truncated, error.InvalidStream, error.ChecksumMismatch, error.DictionaryMismatch, error.OutputTooSmall => return error.CorruptPackEntry,
        };
        if (n.out_len != result_len) return error.CorruptPackEntry;
    }

    /// The object at `offset`, with its delta chain resolved.
    ///
    /// `cache` may be `null`; when it is not, resolved bases are kept in it,
    /// which is what makes a walk over a pack proportional to its objects
    /// rather than to its chains.
    pub fn readAt(p: *Pack, io: Io, offset: u64, cache: ?*Cache, pack_id: u32) Self.Error!Object {
        return p.resolve(io, offset, cache, pack_id, null);
    }

    /// `readAt`, with the object put in `out` rather than in an allocation
    /// of its own: `out` is cleared, grows with this pack's allocator as
    /// needed, and then holds exactly the object. A whole object is
    /// inflated straight into it.
    pub const ReadOptions = struct { cache: ?*Cache = null, pack_id: u32 = 0 };

    pub fn readAtInto(p: *Pack, io: Io, offset: u64, out: *std.ArrayList(u8), options: ReadOptions) Self.Error!object.Type {
        return (try p.resolve(io, offset, options.cache, options.pack_id, out)).type;
    }

    /// The object at `offset`, in an allocation of its own or, given `into`,
    /// there, when the returned bytes are `into.items`.
    fn resolve(p: *Pack, io: Io, offset: u64, cache: ?*Cache, pack_id: u32, into: ?*std.ArrayList(u8)) ErrorNamespace.Error!Object {
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
                    if (chain.items.len == 0) if (into) |out| {
                        out.clearRetainingCapacity();
                        try out.appendSlice(p.gpa, hit.bytes);
                        return .{ .type = hit.type, .bytes = out.items };
                    };
                    base_bytes = try p.gpa.dupe(u8, hit.bytes);
                    base_type = hit.type;
                    break;
                }
            }
            const header = try p.entryHeaderAt(io, current);
            switch (header.kind) {
                .object => |t| {
                    if (chain.items.len == 0) if (into) |out| {
                        try p.inflateInto(io, header.data_at, header.size, out);
                        return .{ .type = t, .bytes = out.items };
                    };
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
            if (i == 0) if (into) |out| {
                out.clearRetainingCapacity();
                try delta.applyTo(p.gpa, out, base_bytes, delta_bytes);
                p.gpa.free(base_bytes);
                // ziglint-ignore: Z026 a base the cache cannot hold is only inflated again; the object is already whole
                if (cache) |c| c.put(pack_id, delta_offset, base_type, out.items) catch {};
                return .{ .type = base_type, .bytes = out.items };
            };
            const applied = try delta.apply(p.gpa, base_bytes, delta_bytes);
            p.gpa.free(base_bytes);
            base_bytes = applied;
            // ziglint-ignore: Z026 a base the cache cannot hold is only inflated again; the object is already whole
            if (cache) |c| c.put(pack_id, delta_offset, base_type, base_bytes) catch {};
        }

        return .{ .type = base_type, .bytes = base_bytes };
    }

    /// Every object's type and length, by its position in the index, as
    /// `headerAt` gives them: read in the order of the file, so that the
    /// reads run forward through it, and a delta's type taken from its base
    /// entry, which an offset delta always has before it, rather than by
    /// walking its chain again. The result is the caller's, freed with
    /// `gpa`.
    pub fn headers(p: *Pack, gpa: Allocator, io: Io) Self.Error![]object.Header {
        const n = p.index.count;
        const Entry = struct { offset: u64, position: u32 };
        const order = try gpa.alloc(Entry, n);
        defer gpa.free(order);
        for (order, 0..) |*e, i| e.* = .{ .offset = try p.index.offsetAt(@intCast(i)), .position = @intCast(i) };
        std.mem.sort(Entry, order, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.offset < b.offset;
            }
        }.less);
        const out = try gpa.alloc(object.Header, n);
        errdefer gpa.free(out);
        const known = try gpa.alloc(bool, n);
        defer gpa.free(known);
        @memset(known, false);
        for (order) |e| {
            const entry = try p.entryHeaderAt(io, e.offset);
            const base: ?u32 = switch (entry.kind) {
                .object => |t| {
                    out[e.position] = .{ .type = t, .size = entry.size };
                    known[e.position] = true;
                    continue;
                },
                .ofs_delta => |back| blk: {
                    if (back == 0 or back > e.offset) break :blk null;
                    const at = std.sort.lowerBound(Entry, order, e.offset - back, struct {
                        fn cmp(offset: u64, x: Entry) std.math.Order {
                            return std.math.order(offset, x.offset);
                        }
                    }.cmp);
                    if (at == order.len or order[at].offset != e.offset - back) break :blk null;
                    break :blk order[at].position;
                },
                .ref_delta => |oid| if (try p.index.find(oid)) |found| found.index else null,
            };
            if (base) |b| if (known[b]) {
                const head = try p.inflateHead(io, entry.data_at, entry.size);
                out[e.position] = .{ .type = out[b].type, .size = (try delta.header(&head)).target };
                known[e.position] = true;
                continue;
            };
            out[e.position] = try p.headerAt(io, e.offset);
            known[e.position] = true;
        }
        return out;
    }

    /// The type and length of the object at `offset`, with no body inflated.
    ///
    /// A delta's chain is walked for the type — which is the base's — but the
    /// size is the delta's own stated target, read out of its first few
    /// bytes, so nothing large is decompressed.
    pub fn headerAt(p: *Pack, io: Io, offset: u64) Self.Error!object.Header {
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
    fn inflateHead(p: *Pack, io: Io, at: u64, size: u64) ErrorNamespace.Error![20]u8 {
        var out: [20]u8 = @splat(0);
        const want: usize = @intCast(@min(size, out.len));
        var fixed_reader: Io.Reader = undefined;
        const input: *Io.Reader = if (p.memory) |mem| blk: {
            if (at > mem.len) return error.TruncatedPack;
            fixed_reader = .fixed(mem[@intCast(at)..]);
            break :blk &fixed_reader;
        } else try p.blockReaderAt(io, at);
        const result = p.decoder.inflateReader(input, out[0..want], .{ .partial = true }) catch |err| return switch (err) {
            error.ReadFailed => p.read_err orelse error.ReadFailed,
            else => error.CorruptPackEntry,
        };
        if (result.out_len != want) return error.CorruptPackEntry;
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
    pub fn verify(p: *Pack, io: Io, cache: ?*Cache, pack_id: u32) Self.Error!Report {
        try p.verifyChecksum(io);

        // The compressed span of an entry runs to the next entry's offset, so
        // a CRC needs the offsets in file order rather than in name order.
        const order = try p.gpa.alloc(u32, p.index.count);
        defer p.gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sort(u32, order, &p.index, struct {
            fn lessThan(index: *const Index, a: u32, b: u32) bool {
                const oa = index.offsetAt(a) catch 0;
                const ob = index.offsetAt(b) catch 0;
                return oa < ob;
            }
        }.lessThan);

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
            if (warp.Crc32.hash(span) != p.index.crcAt(position)) return error.ChecksumMismatch;

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
    pub fn verifyChecksum(p: *Pack, io: Io) Self.Error!void {
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
        // unreachable: the trailer is cut to the format's raw length
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
    pub const Error = ErrorNamespace.Error;

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

    /// Forget everything: what a database does when it closes packs, whose
    /// entries would otherwise stay until they aged out. The ids a database
    /// gives its packs are never reused, so a re-scan needs no clear.
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
    // ziglint-ignore: Z026 refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
    _ = index.find(Oid.zero(.sha1)) catch {};
    // ziglint-ignore: Z026 refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
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
        p.* = undefined;
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
        var compress = try Deflater.init(p.gpa);
        defer compress.deinit(p.gpa);
        // The compressor needs somewhere to put its output; an allocating
        // writer starts with no buffer at all and it asserts against that.
        var out: std.Io.Writer.Allocating = try .initCapacity(p.gpa, 4096);
        defer out.deinit();
        try compress.deflate(&out.writer, bytes, .fast);
        try p.body.appendSlice(p.gpa, out.written());
    }

    fn finishEntry(p: *TestPack, start: usize, name: Oid) !void {
        try p.names.append(p.gpa, name);
        try p.offsets.append(p.gpa, start);
        try p.crcs.append(p.gpa, warp.Crc32.hash(p.body.items[start..]));
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
            .sub_path = try std.mem.print(&pack_name, "{s}.pack", .{base}),
            .data = pack_bytes.items,
        });

        // The index's names must rise, so the entries are sorted here and
        // the offsets follow them.
        const order = try p.gpa.alloc(u32, p.names.items.len);
        defer p.gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sort(u32, order, @as([]const Oid, p.names.items), struct {
            fn lessThan(names: []const Oid, a: u32, b: u32) bool {
                return names[a].order(names[b]) == .lt;
            }
        }.lessThan);

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
            .sub_path = try std.mem.print(&idx_name, "{s}.idx", .{base}),
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

    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = "cycle", .kind = .sha1 }, .{});
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
        var p = try Pack.open(gpa, io, tmp.dir, .{ .base = "deep", .kind = .sha1 }, .{});
        defer p.deinit(io);
        const found = try p.readAt(io, last, null, 0);
        defer gpa.free(found.bytes);
        try std.testing.expectEqualStrings(content, found.bytes);
    }
    {
        // And a caller that sets a smaller cap gets the refusal rather than
        // the work.
        var p = try Pack.open(gpa, io, tmp.dir, .{ .base = "deep", .kind = .sha1 }, .{ .max_depth = 16 });
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

    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = "forward", .kind = .sha1 }, .{});
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
// `WrittenEntry` per object for the index. A writer is one task's; entries
// deflated ahead of it, on other tasks, arrive through `addDeflated`.
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
} || retention.Error || Allocator.Error || Io.File.OpenError || Io.Writer.Error ||
    fs.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError ||
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

    fn level(c: Compression) u4 {
        return switch (c) {
            .fast => 1,
            .default => 6,
            .best => 9,
        };
    }
};

/// How a pack is written.
pub const WriteOptions = struct {
    /// Retain publication until the returned report is released.
    keep: bool = false,
    /// How hard the two files are pushed towards the disk before they are
    /// renamed into place. A pack that a loose object is about to be deleted
    /// for wants `batch` at least.
    sync: fs.Sync = .none,
    /// How hard the entries are compressed.
    compression: Compression = .default,
    /// Write `pack-<name>.rev` too, as git's pack-objects does while
    /// `pack.writeReverseIndex` is on: `revindex.wanted`.
    reverse_index: bool = false,
    /// What `core.sharedRepository` asks of the files' permissions, which
    /// are otherwise git's read-only ones.
    shared: fs.Shared = .umask,
};

/// What a finished pack turned out to be.
pub const WriteReport = struct {
    keep: ?retention.Token = null,
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
pub const IndexEntry = entry_mod.IndexEntry;

const WrittenEntry = IndexEntry;

/// One deflate state, reused from entry to entry: what `Writer.add` deflates
/// through, and what a task deflating entries ahead of the writer owns one
/// of. The stream it makes depends only on the payload and the level, never
/// on what it deflated before or where the stream goes.
pub const Deflater = struct {
    pub const Error = ErrorNamespace.Error;

    workspace: []align(64) u8,
    compress: warp.Deflate,
    compression: Compression = .default,

    pub fn init(gpa: Allocator) Allocator.Error!Deflater {
        const workspace = try gpa.alignedAlloc(u8, .@"64", warp.Deflate.memory(.{}));
        return .{ .workspace = workspace, .compress = .initBuffer(workspace, .{}) };
    }

    pub fn deinit(d: *Deflater, gpa: Allocator) void {
        d.compress.deinit();
        gpa.free(d.workspace);
        d.* = undefined;
    }

    /// Write one independent zlib stream without flushing `out`.
    pub fn deflate(d: *Deflater, out: *Io.Writer, payload: []const u8, compression: Compression) Io.Writer.Error!void {
        if (d.compression == compression) {
            d.compress.reset(.nothing);
        } else {
            d.compress = .initBuffer(d.workspace, .{ .level = compression.level() });
            d.compression = compression;
        }
        var buffer: [4096]u8 = undefined;
        var writer: warp.Deflate.Writer = .init(&d.compress, out, &buffer);
        try writer.interface.writeAll(payload);
        try writer.finish();
    }

    /// The most bytes `deflate` is given room for ahead of the writer, for a
    /// payload of `len` bytes. A stream that needs more is deflated again
    /// straight into the pack.
    pub fn room(len: usize) usize {
        return len +| len / 8 +| 64;
    }
};

/// A writer for a packfile and its index.
///
/// `init` states how many objects will be added, because that number goes in
/// the header and the header is written first. Every `add` streams straight
/// to the file; `finish` writes the index and renames both into place under
/// the name the pack's checksum gives it.
pub const Writer = struct {
    pub const Error = ErrorNamespace.Error;

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
    deflater: Deflater,

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
        crc: warp.Crc32,
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
            const s: *Sink = @alignCast(@fieldParentPtr("writer", w)); // safe: this function is installed only on a Sink's writer
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

    /// The hash format and optional count; null counts entries while writing.
    pub const OpenInputs = struct { kind: Kind, object_count: ?u32 = null };
    /// A streamed pack must know its count before emitting its header.
    pub const StreamInputs = struct { kind: Kind, object_count: u32 };

    /// Begin a pack in `dir`. Nothing is published until finish.
    /// An unknown count is patched into the header at finish before checksumming.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, inputs: OpenInputs, options: WriteOptions) Self.WriteError!*Writer {
        return initMaybeCounted(gpa, io, dir, inputs.kind, inputs.object_count, options);
    }

    /// Begin a pack of a known count streamed to out, without a file or index.
    /// finish emits the checksum; flushing out belongs to the caller.
    pub fn openStream(gpa: Allocator, inputs: StreamInputs, out: *Io.Writer, options: WriteOptions) Self.WriteError!*Writer {
        const kind = inputs.kind;
        const object_count = inputs.object_count;
        const w = try gpa.create(Writer);
        errdefer gpa.destroy(w);
        var deflater: Deflater = try .init(gpa);
        errdefer deflater.deinit(gpa);
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
            .deflater = deflater,
            .entries = .empty,
            .seen = .empty,
            .streaming = true,
        };
        w.sink = .{
            .out = out,
            .hasher = .init(kind),
            .crc = .init,
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
        var deflater: Deflater = try .init(gpa);
        errdefer deflater.deinit(gpa);

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
            .deflater = deflater,
            .entries = .empty,
            .seen = .empty,
        };
        @memcpy(w.temp[0..temp.len], temp);
        w.file_writer = file.writer(io, file_buffer);
        w.sink = .{
            .out = &w.file_writer.interface,
            .hasher = .init(kind),
            .crc = .init,
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
        const gpa = w.gpa;
        defer gpa.destroy(w);
        if (!w.finished) w.abort(io);
        w.entries.deinit(w.gpa);
        w.seen.deinit(w.gpa);
        if (w.file_buffer.len != 0) w.gpa.free(w.file_buffer);
        w.deflater.deinit(w.gpa);
        w.* = undefined;
    }

    /// Give up, leaving the directory as it was.
    pub fn abort(w: *Writer, io: Io) void {
        if (w.finished) return;
        if (w.streaming) {
            w.finished = true;
            return;
        }
        w.file.close(io);
        // ziglint-ignore: Z026 abandoning cannot fail; a temporary pack left behind is what `git gc` prunes
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
    pub fn add(w: *Writer, oid: Oid, t: object.Type, bytes: []const u8) Self.WriteError!u64 {
        return w.addEntry(oid, typeBits(t), bytes.len, &.{}, bytes);
    }

    /// Add an object stored as a delta against one already in this pack.
    ///
    /// `base_offset` must be the offset an earlier `add` returned: the format
    /// only allows an offset delta to point backwards, and a reader that met
    /// one pointing forwards would be reading an object that is not there
    /// yet.
    pub fn addOfsDelta(w: *Writer, oid: Oid, base_offset: u64, delta_bytes: []const u8) Self.WriteError!u64 {
        const at = w.sink.count;
        if (base_offset >= at) return error.DeltaBaseNotWritten;
        var buf: [16]u8 = undefined;
        const encoded = encodeBackOffset(&buf, at - base_offset);
        w.deltas += 1;
        return w.addEntry(oid, 6, delta_bytes.len, encoded, delta_bytes);
    }

    /// Add an object stored as a delta against a name, which need not be in
    /// this pack. A reader resolves it through the database.
    pub fn addRefDelta(w: *Writer, oid: Oid, base: Oid, delta_bytes: []const u8) Self.WriteError!u64 {
        w.deltas += 1;
        return w.addEntry(oid, 7, delta_bytes.len, base.raw(), delta_bytes);
    }

    /// Add an entry whose zlib stream a `Deflater` already made, ahead of
    /// the writer: `deflated` is `Deflater.deflate`'s output for a payload of
    /// `payload_len` bytes at this writer's `WriteOptions.compression` — the
    /// stream `add`, `addOfsDelta` or `addRefDelta` would have written for
    /// those bytes, so the pack is the same pack. Anything else makes a
    /// corrupt pack, as wrong delta bytes given to `addOfsDelta` would.
    /// Returns the offset the entry begins at.
    pub fn addDeflated(w: *Writer, oid: Oid, payload: Payload, payload_len: u64, deflated: []const u8) Self.WriteError!u64 {
        var buf: [16]u8 = undefined;
        const at = w.sink.count;
        const type_bits: u3, const extra: []const u8 = switch (payload) {
            .object => |t| .{ typeBits(t), &.{} },
            .ofs_delta => |base_offset| blk: {
                if (base_offset >= at) return error.DeltaBaseNotWritten;
                break :blk .{ 6, encodeBackOffset(&buf, at - base_offset) };
            },
            .ref_delta => |*base| .{ 7, base.raw() },
        };
        try w.beginEntry(oid, type_bits, payload_len, extra);
        try w.sink.emit(deflated);
        if (payload != .object) w.deltas += 1;
        return w.endEntry(oid, at);
    }

    /// What an entry holds, for `addDeflated`.
    pub const Payload = union(enum) {
        /// A whole object of this type.
        object: object.Type,
        /// A delta against the entry an earlier add returned this offset
        /// for.
        ofs_delta: u64,
        /// A delta against the object with this name.
        ref_delta: Oid,
    };

    fn addEntry(
        w: *Writer,
        oid: Oid,
        type_bits: u3,
        payload_len: u64,
        extra: []const u8,
        payload: []const u8,
    ) WriteError!u64 {
        const at = w.sink.count;
        try w.beginEntry(oid, type_bits, payload_len, extra);
        try w.deflater.deflate(&w.sink.writer, payload, w.options.compression);
        try w.sink.writer.flush();
        return w.endEntry(oid, at);
    }

    fn beginEntry(w: *Writer, oid: Oid, type_bits: u3, payload_len: u64, extra: []const u8) WriteError!void {
        if (w.expected) |expected| {
            if (w.entries.items.len >= expected) return error.ObjectCountMismatch;
        }
        if (w.seen.contains(oid)) return error.DuplicateObject;
        w.sink.crc = .init;

        var head: [16]u8 = undefined;
        const head_len = encodeTypeAndSize(&head, type_bits, payload_len);
        try w.sink.emit(head[0..head_len]);
        if (extra.len != 0) try w.sink.emit(extra);
    }

    fn endEntry(w: *Writer, oid: Oid, at: u64) WriteError!u64 {
        try w.entries.append(w.gpa, .{ .oid = oid, .offset = at, .crc = w.sink.crc.final() });
        try w.seen.put(w.gpa, oid, {});
        return at;
    }

    /// Close the pack, write its index, and rename both into place.
    ///
    /// The name both files carry is the pack's own trailing checksum, which
    /// is what git names a pack after.
    pub fn finish(w: *Writer, io: Io) Self.WriteError!WriteReport {
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
        var token: ?retention.Token = if (w.options.keep) try retention.Token.open(w.gpa, io, w.dir, checksum) else null;
        errdefer if (token) |*t| t.deinit(io);
        const pack_bytes = w.sink.count + w.kind.rawLen();
        try w.file_writer.interface.flush();
        switch (w.options.sync) {
            .none => {},
            .batch, .per_file => try fs.syncFile(io, w.file, .{ .policy = w.options.sync }),
        }
        w.file.close(io);
        w.finished = true;

        var hex: [hash.max_hex_len]u8 = undefined;
        const text = checksum.hex(&hex);
        var pack_name_buf: [hash.max_hex_len + 16]u8 = undefined;
        // unreachable: a hex name is at most max_hex_len digits, the rest ten bytes
        const pack_name = std.mem.print(&pack_name_buf, "pack-{s}.pack", .{text}) catch unreachable;
        var idx_name_buf: [hash.max_hex_len + 16]u8 = undefined;
        // unreachable: a hex name is at most max_hex_len digits, the rest nine bytes
        const idx_name = std.mem.print(&idx_name_buf, "pack-{s}.idx", .{text}) catch unreachable;

        // The index goes to a temporary of its own, because the order the two
        // become visible in is not free to choose: a reader finds a pack by
        // its `.idx`, so an index that is there before its pack is a reader
        // opening a file that does not exist. Pack first, index second, which
        // is git's order too.
        var idx_temp_buf: [64]u8 = undefined;
        const idx_temp = fs.tempName(io, &idx_temp_buf, "tmp_idx_");
        const index_bytes = try w.writeIndex(io, checksum, idx_temp);
        errdefer w.dir.deleteFile(io, idx_temp) catch {};
        var rev_temp_buf: [64]u8 = undefined;
        const rev_temp: ?[]const u8 = if (w.options.reverse_index) fs.tempName(io, &rev_temp_buf, "tmp_rev_") else null;
        if (rev_temp) |t| try revindex.write(w.gpa, io, w.dir, t, .{ .kind = w.kind, .entries = w.entries.items, .pack_checksum = checksum, .sync = w.options.sync });
        errdefer if (rev_temp) |t| w.dir.deleteFile(io, t) catch {};

        // read-only, as git leaves a pack and its indexes
        fs.readOnlyObject(io, w.dir, w.temp[0..w.temp_len], w.options.shared);
        fs.readOnlyObject(io, w.dir, idx_temp, w.options.shared);
        if (rev_temp) |t| fs.readOnlyObject(io, w.dir, t, w.options.shared);
        fs.renameWithRetry(io, w.dir, w.temp[0..w.temp_len], pack_name) catch |err| {
            // ziglint-ignore: Z026 the rename's error is the one to report; temporary files left behind are what `git gc` prunes
            w.dir.deleteFile(io, w.temp[0..w.temp_len]) catch {};
            // ziglint-ignore: Z026 the rename's error is the one to report; temporary files left behind are what `git gc` prunes
            w.dir.deleteFile(io, idx_temp) catch {};
            return err;
        };
        // The reverse index before the index, as git renames them.
        if (rev_temp) |t| {
            var rev_name_buf: [hash.max_hex_len + 16]u8 = undefined;
            // unreachable: a hex name is at most max_hex_len digits, the rest nine bytes
            const rev_name = std.mem.print(&rev_name_buf, "pack-{s}.rev", .{text}) catch unreachable;
            try fs.renameWithRetry(io, w.dir, t, rev_name);
        }
        fs.renameWithRetry(io, w.dir, idx_temp, idx_name) catch |err| {
            // ziglint-ignore: Z026 the rename's error is the one to report; a pack without its index is unreachable, and `git gc` prunes it
            w.dir.deleteFile(io, idx_temp) catch {};
            return err;
        };

        return .{
            .keep = token,
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
        return writeIndexFile(w.gpa, io, w.dir, idx_name, .{ .kind = w.kind, .entries = w.entries.items, .pack_checksum = pack_checksum, .sync = w.options.sync });
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
pub const IndexWriteOptions = struct {
    kind: Kind,
    entries: []IndexEntry,
    pack_checksum: Oid,
    sync: fs.Sync = .none,
};

pub fn writeIndexFile(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    options: IndexWriteOptions,
) Self.WriteError!u64 {
    const kind = options.kind;
    const entries = options.entries;
    const pack_checksum = options.pack_checksum;
    const sync = options.sync;
    std.mem.sort(WrittenEntry, entries, {}, lessThanWritten);
    // The names rise, each once: what `Index.parse` checks before anything
    // is looked up.
    if (entries.len > 1) for (1..entries.len) |i| std.debug.assert(entries[i - 1].oid.order(entries[i].oid) == .lt);

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
    std.debug.assert(running == entries.len);
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
    // The layout `Index.parse` reads back: header, fanout, names, CRCs,
    // offsets, large offsets, two checksums.
    std.debug.assert(written == 8 + 1024 + entries.len * (raw_len + 8) + large.items.len * 8 + 2 * raw_len);
    try out.writeAll(own.raw()[0..raw_len]);
    try out.flush();
    switch (sync) {
        .none => {},
        .batch, .per_file => try fs.syncFile(io, file, .{ .policy = sync }),
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
    const tree_bytes = "100644 a\x00" ++ (&@as([20]u8, @splat(0x01)));
    const commit_bytes = "tree " ++ (&@as([40]u8, @splat('0'))) ++ "\nsome header lines\n\nmessage\n";

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

    var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 5 }, .{});
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
    const base = try std.mem.print(&base_buf, "pack-{s}", .{report.name.hex(&hex)});

    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = base, .kind = .sha1 }, .{});
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

    var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1 }, .{});
    defer w.deinit(io);
    // The body the newest entry holds: what an offset delta against that
    // entry is a delta from. Not the body generated before this one, which
    // may have gone unwritten -- a duplicate, or one refused below.
    var newest: ?usize = null;

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
        if (newest != null and smith.valueRangeAtMost(u8, 0, 1) == 0) {
            const base = bodies[newest.?];
            const encoded = (try delta.encode(gpa, base, bodies[i], .{})) orelse continue;
            defer gpa.free(encoded);
            const base_offset = w.entries.items[w.count() - 1].offset;
            if (kinds[i] != kinds[newest.?]) continue;
            _ = try w.addOfsDelta(names[i], base_offset, encoded);
            newest = i;
            continue;
        }
        _ = try w.add(names[i], kinds[i], bodies[i]);
        newest = i;
    }

    const report = try w.finish(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    var base_buf: [64]u8 = undefined;
    const base = try std.mem.print(&base_buf, "pack-{s}", .{report.name.hex(&hex)});
    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = base, .kind = .sha1 }, .{});
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

    var file_writer = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 2 }, .{});
    defer file_writer.deinit(io);
    const at = try file_writer.add(base_oid, .blob, base_bytes);
    _ = try file_writer.addOfsDelta(target_oid, at, patch);
    const written = try file_writer.finish(io);

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var stream_writer = try Writer.openStream(gpa, .{ .kind = .sha1, .object_count = 2 }, &stream.writer, .{});
    defer stream_writer.deinit(io);
    const stream_at = try stream_writer.add(base_oid, .blob, base_bytes);
    _ = try stream_writer.addOfsDelta(target_oid, stream_at, patch);
    const streamed = try stream_writer.finish(io);

    try std.testing.expect(written.name.eql(streamed.name));
    var hex: [hash.max_hex_len]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const pack_name = try std.mem.print(&name_buf, "pack-{s}.pack", .{written.name.hex(&hex)});
    const on_disk = try tmp.dir.readFileAlloc(io, pack_name, gpa, .unlimited);
    defer gpa.free(on_disk);
    try std.testing.expectEqualSlices(u8, on_disk, stream.written());
}

test "a pack with no objects is still a pack, under either name format" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for ([_]Kind{ .sha1, .sha256 }) |kind| {
        var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = kind, .object_count = 0 }, .{});
        defer w.deinit(io);
        const report = try w.finish(io);
        try std.testing.expectEqual(@as(u32, 0), report.objects);
        try std.testing.expectEqual(@as(u64, 12 + kind.rawLen()), report.pack_bytes);

        var hex: [hash.max_hex_len]u8 = undefined;
        var base_buf: [hash.max_hex_len + 8]u8 = undefined;
        var p = try Pack.open(gpa, io, tmp.dir, .{ .base = try std.mem.print(&base_buf, "pack-{s}", .{report.name.hex(&hex)}), .kind = kind }, .{});
        defer p.deinit(io);
        try std.testing.expectEqual(@as(u32, 0), p.index.count);
    }
}

test "a writer that is given the wrong count refuses rather than lying in the header" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 1 }, .{});
    defer w.deinit(io);
    try std.testing.expectError(error.ObjectCountMismatch, w.finish(io));
    _ = try w.add(testName(1), .blob, "x");
    try std.testing.expectError(error.ObjectCountMismatch, w.add(testName(2), .blob, "y"));

    // An offset delta may only point backwards.
    var w2 = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 1 }, .{});
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
        var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 2 }, .{});
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
    std.debug.assert(base_len < 256);
    std.debug.assert(suffix.len < 128);
    std.debug.assert(suffix.len > 0);
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
fn typeBits(t: object.Type) u3 {
    return switch (t) {
        .commit => 1,
        .tree => 2,
        .blob => 3,
        .tag => 4,
    };
}

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

/// A pack of one small object, one whose compressed body runs across
/// several read blocks, and one large enough to stream, for the failure
/// tests below.
const FailurePack = struct {
    tmp: std.testing.TmpDir,
    name_buf: [64]u8 = undefined,
    name_buf2: [80]u8 = undefined,
    name_len: usize = 0,
    small: u64 = 0,
    spanning: u64 = 0,
    large: u64 = 0,

    fn init(gpa: Allocator, io: Io) !FailurePack {
        var f: FailurePack = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }) };
        errdefer f.tmp.cleanup();
        const noise = try gpa.alloc(u8, 200_000);
        defer gpa.free(noise);
        var prng: std.Random.DefaultPrng = .init(0xfa11);
        prng.random().bytes(noise);
        var w = try Writer.open(gpa, io, f.tmp.dir, .{ .kind = .sha1, .object_count = 3 }, .{});
        defer w.deinit(io);
        f.small = try w.add(try Oid.parse(.sha1, &@as([40]u8, @splat('1'))), .blob, "small");
        f.spanning = try w.add(try Oid.parse(.sha1, &@as([40]u8, @splat('2'))), .blob, noise[0 .. 3 * read_block_bytes]);
        f.large = try w.add(try Oid.parse(.sha1, &@as([40]u8, @splat('3'))), .blob, noise);
        const report = try w.finish(io);
        var hex: [hash.max_hex_len]u8 = undefined;
        f.name_len = (try std.mem.print(&f.name_buf, "pack-{s}", .{report.name.hex(&hex)})).len;
        return f;
    }

    fn name(f: *const FailurePack) []const u8 {
        return f.name_buf[0..f.name_len];
    }
};

test "pack inflates preserve I/O and cancellation resource failures" {
    const Fault = struct {
        threadlocal var failure: Io.File.ReadPositionalError = error.InputOutput;
        fn read(_: ?*anyopaque, _: Io.File, _: []const []u8, _: u64) Io.File.ReadPositionalError!usize {
            return failure;
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try FailurePack.init(gpa, io);
    defer fixture.tmp.cleanup();
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Fault.read;
    const failing_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Io.File.ReadPositionalError{ error.InputOutput, error.Canceled }) |failure| {
        Fault.failure = failure;
        var p = try Pack.open(gpa, io, fixture.tmp.dir, .{ .base = fixture.name(), .kind = .sha1 }, .{});
        defer p.deinit(io);
        // The header's block is read; the rest of the body, through the
        // blocks or streamed, fails.
        const spanning = try p.entryHeaderAt(io, fixture.spanning);
        try std.testing.expectError(failure, p.inflateAt(failing_io, spanning.data_at, spanning.size));
        const large = try p.entryHeaderAt(io, fixture.large);
        try std.testing.expectError(failure, p.inflateAt(failing_io, large.data_at, large.size));
        // And with nothing read yet, the first block fails.
        var fresh = try Pack.open(gpa, io, fixture.tmp.dir, .{ .base = fixture.name(), .kind = .sha1 }, .{});
        defer fresh.deinit(io);
        try std.testing.expectError(failure, fresh.inflateAt(failing_io, spanning.data_at, spanning.size));
        try std.testing.expectError(failure, fresh.inflateHead(failing_io, spanning.data_at, spanning.size));
        // The failed blocks were not kept: the same reads succeed after.
        const got = try fresh.readAt(io, fixture.spanning, null, 0);
        gpa.free(got.bytes);
    }
}

test "the block reader serves every std reader call across block boundaries" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try FailurePack.init(gpa, io);
    defer fixture.tmp.cleanup();
    var p = try Pack.open(gpa, io, fixture.tmp.dir, .{ .base = fixture.name(), .kind = .sha1 }, .{ .read_cache_bytes = 2 * read_block_bytes });
    defer p.deinit(io);
    const file = try fixture.tmp.dir.readFileAlloc(io, try std.mem.print(&fixture.name_buf2, "{s}.pack", .{fixture.name()}), gpa, .limited(1 << 20));
    defer gpa.free(file);

    // Starting a few bytes before each of the first boundaries, every kind
    // of call a decoder makes returns the file's own bytes, with two slots
    // so that the reader moves between them and back into the first.
    for (1..5) |boundary| {
        const at = boundary * read_block_bytes - 3;
        const r = try p.blockReaderAt(io, at);
        try std.testing.expectEqual(std.mem.readInt(u32, file[at..][0..4], .big), try r.takeInt(u32, .big));
        try std.testing.expectEqualSlices(u8, file[at + 4 ..][0..16], try r.peek(16));
        r.toss(5);
        // Giving bytes back, as the decoder does with the bits it loaded.
        r.seek -= 2;
        var run: [3 * read_block_bytes]u8 = undefined;
        try r.readSliceAll(&run);
        try std.testing.expectEqualSlices(u8, file[at + 7 ..][0..run.len], &run);
        try r.discardAll(100);
        try std.testing.expectEqual(file[at + 7 + run.len + 100], try r.takeByte());
    }
    // And through the end of the file to the end of the stream.
    const tail = file.len - 10;
    const r = try p.blockReaderAt(io, tail);
    var rest: [10]u8 = undefined;
    try r.readSliceAll(&rest);
    try std.testing.expectEqualSlices(u8, file[tail..], &rest);
    try std.testing.expectError(error.EndOfStream, r.takeByte());
}

test "pack inflate distinguishes policy resource failures from malformed lengths" {
    var p: Pack = undefined;
    try std.testing.expectError(error.StreamTooLong, p.inflateAt(std.testing.io, 0, delta.max_result_bytes + 1));
}

test "pack header reads preserve I/O and cancellation resource failures" {
    const Fault = struct {
        threadlocal var failure: Io.File.ReadPositionalError = error.InputOutput;
        fn read(_: ?*anyopaque, _: Io.File, _: []const []u8, _: u64) Io.File.ReadPositionalError!usize {
            return failure;
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try FailurePack.init(gpa, io);
    defer fixture.tmp.cleanup();
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Fault.read;
    const failing_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Io.File.ReadPositionalError{ error.AccessDenied, error.InputOutput, error.Canceled }) |failure| {
        Fault.failure = failure;
        var p = try Pack.open(gpa, io, fixture.tmp.dir, .{ .base = fixture.name(), .kind = .sha1 }, .{});
        defer p.deinit(io);
        try std.testing.expectError(failure, p.entryHeaderAt(failing_io, fixture.small));
        try std.testing.expectError(failure, p.headerAt(failing_io, fixture.small));
        try std.testing.expectError(failure, p.readAt(failing_io, fixture.large, null, 0));
    }
}

test "a refused on-disk pack index releases its bytes once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.idx", .data = "x" });
    try std.testing.expectError(error.TruncatedIndex, Index.open(gpa, io, tmp.dir, "bad.idx", .{ .kind = .sha1, .max_bytes = 1024 }));
}

test "a pass whose delta-base cache holds more reads no more of the pack" {
    const Counter = struct {
        threadlocal var calls: usize = 0;
        threadlocal var bytes: usize = 0;
        fn read(userdata: ?*anyopaque, file: Io.File, buffers: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            calls += 1;
            const n = try std.testing.io.vtable.fileReadPositional(userdata, file, buffers, offset);
            bytes += n;
            return n;
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Counter.read;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    var prng: std.Random.DefaultPrng = .init(0x7ac4e);
    const random = prng.random();
    for (0..200) |round| {
        // Whole objects of every size, the largest past the read blocks,
        // and offset deltas onto earlier entries, some of them deltas.
        var builder = try TestPack.init(gpa);
        defer builder.deinit();
        var contents: std.ArrayList([]u8) = .empty;
        defer {
            for (contents.items) |bytes| gpa.free(bytes);
            contents.deinit(gpa);
        }
        var offsets: std.ArrayList(u64) = .empty;
        defer offsets.deinit(gpa);
        const count = 8 + random.uintLessThan(usize, 40);
        for (0..count) |i| {
            const name = testName(@intCast(round * 1000 + i));
            if (i == 0 or random.uintLessThan(u8, 3) != 0) {
                const size = switch (random.uintLessThan(u8, 40)) {
                    0 => random.intRangeAtMost(usize, 64 * 1024, 160 * 1024),
                    1, 2 => random.intRangeAtMost(usize, 8 * 1024, 40 * 1024),
                    else => random.intRangeAtMost(usize, 1, 1500),
                };
                const bytes = try gpa.alloc(u8, size);
                errdefer gpa.free(bytes);
                for (bytes) |*b| b.* = 'a' + random.uintLessThan(u8, 6);
                try offsets.append(gpa, try builder.addObject(name, bytes));
                try contents.append(gpa, bytes);
            } else {
                const base = random.uintLessThan(usize, contents.items.len);
                const source = contents.items[base];
                var target: std.ArrayList(u8) = .empty;
                defer target.deinit(gpa);
                const cut = random.uintAtMost(usize, source.len);
                try target.appendSlice(gpa, source[0..cut]);
                for (0..random.uintLessThan(usize, 200)) |_| try target.append(gpa, 'a' + random.uintLessThan(u8, 26));
                try target.appendSlice(gpa, source[cut..]);
                const patch = (try delta.encode(gpa, source, target.items, .{})).?;
                defer gpa.free(patch);
                const back = builder.body.items.len - offsets.items[base];
                try offsets.append(gpa, try builder.addOfsDelta(name, back, patch));
                try contents.append(gpa, try target.toOwnedSlice(gpa));
            }
        }
        var base_buf: [32]u8 = undefined;
        const base_name = try std.mem.print(&base_buf, "random{d}", .{round});
        try builder.write(io, tmp.dir, base_name);

        // Any cache size, down to the single block.
        const cache_bytes: usize = switch (random.uintLessThan(u8, 5)) {
            0 => 0,
            1 => read_block_bytes,
            2 => 3 * read_block_bytes,
            3 => default_read_cache_bytes,
            else => 1 << 20,
        };
        var p = try Pack.open(gpa, counted, tmp.dir, .{ .base = base_name, .kind = .sha1 }, .{ .read_cache_bytes = cache_bytes });
        defer p.deinit(io);
        const order = try gpa.alloc(usize, offsets.items.len);
        defer gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = i;
        random.shuffle(usize, order);

        // Two passes in one order through a cache that never evicts: the
        // second holds every base the first held at each step, and more.
        var cache = try Cache.init(gpa, 1 << 30);
        defer cache.deinit();
        var passes: [2]struct { calls: usize, bytes: usize } = undefined;
        for (&passes) |*pass| {
            Counter.calls = 0;
            Counter.bytes = 0;
            for (order) |k| {
                const got = try p.readAt(counted, offsets.items[k], &cache, 0);
                defer gpa.free(got.bytes);
                try std.testing.expectEqualSlices(u8, contents.items[k], got.bytes);
            }
            pass.* = .{ .calls = Counter.calls, .bytes = Counter.bytes };
        }
        if (passes[1].calls > passes[0].calls or passes[1].bytes > passes[0].bytes) {
            std.debug.print("pack {d}, {d}-byte cache: cold {d} reads, {d} bytes; warm {d} reads, {d} bytes\n", .{ round, cache_bytes, passes[0].calls, passes[0].bytes, passes[1].calls, passes[1].bytes });
            return error.TestUnexpectedResult;
        }
    }
}

/// The bytes a test's allocations hold at once.
const LiveAllocator = struct {
    child: Allocator,
    live: usize = 0,
    fn allocator(l: *LiveAllocator) Allocator {
        return .{ .ptr = l, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const l: *LiveAllocator = @ptrCast(@alignCast(ctx)); // safe: ctx is the pointer `allocator` handed out
        const p = l.child.rawAlloc(len, alignment, ret) orelse return null;
        l.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const l: *LiveAllocator = @ptrCast(@alignCast(ctx)); // safe: ctx is the pointer `allocator` handed out
        if (!l.child.rawResize(memory, alignment, new_len, ret)) return false;
        l.live = l.live - memory.len + new_len;
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const l: *LiveAllocator = @ptrCast(@alignCast(ctx)); // safe: ctx is the pointer `allocator` handed out
        const p = l.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        l.live = l.live - memory.len + new_len;
        return p;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const l: *LiveAllocator = @ptrCast(@alignCast(ctx)); // safe: ctx is the pointer `allocator` handed out
        l.child.rawFree(memory, alignment, ret);
        l.live -= memory.len;
    }
};

test "a pack the default block cache holds is read once in any order, and holds only the blocks read" {
    const Counter = struct {
        threadlocal var calls: usize = 0;
        fn read(userdata: ?*anyopaque, file: Io.File, buffers: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            calls += 1;
            return std.testing.io.vtable.fileReadPositional(userdata, file, buffers, offset);
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Four hundred blobs that do not compress: a pack of about 600 KiB,
    // which the 256 KiB this cache used to hold could not.
    const count = 400;
    var prng: std.Random.DefaultPrng = .init(0xb10c);
    const random = prng.random();
    var contents: [count][1500]u8 = undefined;
    var offsets: [count]u64 = undefined;
    var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = count }, .{});
    defer w.deinit(io);
    for (&contents, &offsets, 0..) |*bytes, *at, i| {
        random.bytes(bytes);
        var name: [20]u8 = @splat(0);
        std.mem.writeInt(u32, name[0..4], @intCast(i), .big);
        at.* = try w.add(try Oid.fromRaw(.sha1, &name), .blob, bytes);
    }
    const report = try w.finish(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const base = try std.mem.print(&name_buf, "pack-{s}", .{report.name.hex(&hex)});

    var vtable = io.vtable.*;
    vtable.fileReadPositional = Counter.read;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var live: LiveAllocator = .{ .child = gpa };
    var p = try Pack.open(live.allocator(), counted, tmp.dir, .{ .base = base, .kind = .sha1 }, .{});
    defer p.deinit(io);
    const blocks = std.math.divCeil(u64, p.size, read_block_bytes) catch unreachable;
    try std.testing.expect(blocks * read_block_bytes > 2 * 256 * 1024);

    // One object read: the blocks it spans, and the slot tables.
    const opened = live.live;
    Counter.calls = 0;
    {
        const got = try p.readAt(counted, offsets[0], null, 0);
        defer live.allocator().free(got.bytes);
        try std.testing.expectEqualSlices(u8, &contents[0], got.bytes);
    }
    const held = live.live - opened;
    const tables = blocks * (@sizeOf(?[*]u8) + @sizeOf(u64) + @sizeOf(u32));
    if (held > Counter.calls * block_stride + tables) {
        std.debug.print("one object read in {d} reads holds {d} bytes\n", .{ Counter.calls, held });
        return error.TestUnexpectedResult;
    }

    // Every object, in a random order, twice: each block is read once.
    var order: [count]usize = undefined;
    for (&order, 0..) |*k, i| k.* = i;
    random.shuffle(usize, &order);
    for (0..2) |_| {
        for (order) |k| {
            const got = try p.readAt(counted, offsets[k], null, 0);
            defer live.allocator().free(got.bytes);
            try std.testing.expectEqualSlices(u8, &contents[k], got.bytes);
        }
    }
    if (Counter.calls > blocks) {
        std.debug.print("{d} blocks read in {d} calls\n", .{ blocks, Counter.calls });
        return error.TestUnexpectedResult;
    }
}

test "a reused deflater makes the stream a fresh one makes, wherever it goes" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xdef1);
    const random = prng.random();
    // Payloads that compress, that do not, and of every size around the
    // compressor's block and window lengths.
    var payloads: [12][]u8 = undefined;
    for (&payloads, 0..) |*payload, i| {
        const len = switch (i % 6) {
            0 => 0,
            1 => random.uintLessThan(usize, 300),
            2 => random.intRangeAtMost(usize, 30_000, 70_000),
            3 => 1 << 15,
            else => random.uintLessThan(usize, 100_000),
        };
        payload.* = try gpa.alloc(u8, len);
        if (i % 2 == 0) {
            random.bytes(payload.*);
        } else {
            for (payload.*) |*b| b.* = 'a' + random.uintLessThan(u8, 4);
        }
    }
    defer for (payloads) |payload| gpa.free(payload);

    var reused: Deflater = try .init(gpa);
    defer reused.deinit(gpa);
    for (0..2) |_| {
        random.shuffle([]u8, &payloads);
        for (payloads) |payload| {
            for ([_]Compression{ .fast, .default, .best }) |level| {
                var fresh: Deflater = try .init(gpa);
                defer fresh.deinit(gpa);
                var expected: Io.Writer.Allocating = try .initCapacity(gpa, 4096);
                defer expected.deinit();
                try fresh.deflate(&expected.writer, payload, level);

                // Into room of its own, as a task deflates ahead of the
                // writer, after whatever this deflater did before.
                const room = try gpa.alloc(u8, Deflater.room(payload.len));
                defer gpa.free(room);
                var out: Io.Writer = .fixed(room);
                try reused.deflate(&out, payload, level);
                try std.testing.expectEqualSlices(u8, expected.written(), out.buffered());
            }
        }
    }
}

test "small random packed reads keep large sequential reads buffered" {
    const Counter = struct {
        threadlocal var largest: usize = 0;
        fn read(userdata: ?*anyopaque, file: Io.File, buffers: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            var wanted: usize = 0;
            for (buffers) |buf| wanted += buf.len;
            largest = @max(largest, wanted);
            const io = std.testing.io;
            return io.vtable.fileReadPositional(userdata, file, buffers, offset);
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const large = try gpa.alloc(u8, 200000);
    defer gpa.free(large);
    var prng: std.Random.DefaultPrng = .init(1951);
    prng.random().bytes(large);
    var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 3 }, .{});
    defer w.deinit(io);
    const first = try w.add(try Oid.parse(.sha1, &@as([40]u8, @splat('1'))), .blob, "first");
    const middle = try w.add(try Oid.parse(.sha1, &@as([40]u8, @splat('2'))), .blob, large);
    const last = try w.add(try Oid.parse(.sha1, &@as([40]u8, @splat('3'))), .blob, "last");
    const report = try w.finish(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "pack-{s}", .{report.name.hex(&hex)});
    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = name, .kind = .sha1 }, .{});
    defer p.deinit(io);
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Counter.read;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    Counter.largest = 0;
    for ([_]struct { at: u64, bytes: []const u8 }{
        .{ .at = last, .bytes = "last" },
        .{ .at = first, .bytes = "first" },
    }) |want| {
        const got = try p.readAt(counted, want.at, null, 0);
        defer gpa.free(got.bytes);
        try std.testing.expectEqualSlices(u8, want.bytes, got.bytes);
    }
    try std.testing.expect(Counter.largest <= 8 * 1024);
    Counter.largest = 0;
    const got = try p.readAt(counted, middle, null, 0);
    defer gpa.free(got.bytes);
    try std.testing.expectEqualSlices(u8, large, got.bytes);
    try std.testing.expectEqual(@as(usize, 64 * 1024), Counter.largest);
}

test "a packed entry header survives a short positional read" {
    const Short = struct {
        threadlocal var first: bool = true;
        fn read(userdata: ?*anyopaque, file: Io.File, buffers: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            const io = std.testing.io;
            if (first) {
                first = false;
                return io.vtable.fileReadPositional(userdata, file, &.{buffers[0][0..1]}, offset);
            }
            return io.vtable.fileReadPositional(userdata, file, buffers, offset);
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const bytes = &@as([1000]u8, @splat('b'));
    const oid = hash.Hasher.nameObject(.sha1, .{}, "blob", bytes).oid;
    var w = try Writer.open(gpa, io, tmp.dir, .{ .kind = .sha1, .object_count = 1 }, .{});
    defer w.deinit(io);
    const at = try w.add(oid, .blob, bytes);
    const report = try w.finish(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "pack-{s}", .{report.name.hex(&hex)});
    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = name, .kind = .sha1 }, .{});
    defer p.deinit(io);
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Short.read;
    const short: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    Short.first = true;
    const got = try p.readAt(short, at, null, 0);
    defer gpa.free(got.bytes);
    try std.testing.expectEqualSlices(u8, bytes, got.bytes);
}

test "pack decode scratch does not relax the stated object size" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var builder = try TestPack.init(gpa);
    defer builder.deinit();
    const at = try builder.addObject(testName(0), "abcdef");
    // Only the claimed size changes. The stream and its checksum are valid.
    builder.body.items[@intCast(at)] = 0x35;
    try builder.write(io, tmp.dir, "short");
    var p = try Pack.open(gpa, io, tmp.dir, .{ .base = "short", .kind = .sha1 }, .{});
    defer p.deinit(io);
    try std.testing.expectError(error.CorruptPackEntry, p.readAt(io, at, null, 0));
}
