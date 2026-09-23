//! reftable: git's binary format for refs and their logs, one table.
//!
//! A table is a sorted run of records cut into blocks. Refs come first,
//! then, when the table is large enough to want one, an index of the ref
//! blocks and an index from object names back to the ref blocks that name
//! them; then the logs, deflated a block at a time; then a footer that
//! repeats the header and says where each section starts, under a CRC-32.
//! Inside a block each key shares a prefix with the one before it and only
//! the rest is stored, and every so often a key is stored whole and its
//! offset recorded at the block's end, which is what makes a block
//! searchable by bisection.
//!
//! What is written here is what git's writer writes, byte for byte, for the
//! same records and settings, with one exception: a log block is deflated by
//! the standard library and not by zlib, so its compressed bytes differ while
//! what they inflate to does not. The reader takes arbitrary bytes -- a table
//! is a file anyone could have written -- and answers with a record or a
//! named error, never a read outside the file; the fuzz test at the bottom
//! holds it to that.
//!
//! A table is immutable once written. The stack of them that makes up a
//! repository's refs, and the transactions that add to it, are
//! `reftablestack`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

const hash = @import("hash.zig");
const varint = @import("varint.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// Every table begins with this.
pub const magic = "REFT";

/// The block types, each the first byte of its block.
pub const BlockType = enum(u8) {
    ref = 'r',
    log = 'g',
    obj = 'o',
    index = 'i',
};

/// The `hash_id` a version 2 table carries for SHA-1.
pub const format_id_sha1: u32 = 0x73686131;
/// The `hash_id` a version 2 table carries for SHA-256.
pub const format_id_sha256: u32 = 0x73323536;

/// A restart table holds at most this many offsets, since its count is
/// sixteen bits.
const max_restarts: usize = (1 << 16) - 1;

/// The header's length: version 1 has no hash identifier, version 2 does.
pub fn headerSize(version: u8) usize {
    return if (version == 1) 24 else 28;
}

/// The footer's length: the header again, five offsets and a CRC-32.
pub fn footerSize(version: u8) usize {
    return headerSize(version) + 44;
}

/// The version git writes for a hash: 1 for SHA-1, 2 for anything else.
pub fn versionFor(kind: Kind) u8 {
    return if (kind == .sha1) 1 else 2;
}

/// Errors from reading or writing a table.
pub const Error = error{
    /// The file does not begin `REFT`, or is too short to be a table.
    NotAReftable,
    /// A version other than 1 or 2.
    UnsupportedReftableVersion,
    /// The footer does not repeat the header, or does not end the file.
    CorruptFooter,
    /// The footer's CRC-32 does not match its bytes.
    FooterChecksumMismatch,
    /// The table names a hash other than the repository's.
    HashMismatch,
    /// A block's header, length, restart table or compressed body does not
    /// hold together.
    CorruptBlock,
    /// A record runs off its block, or holds a value its type cannot.
    CorruptRecord,
    /// Records handed to the writer, or found by `verify`, out of order.
    UnsortedRecords,
    /// A record's update index outside the table's range.
    UpdateIndexOutOfRange,
    /// One record that does not fit in a block of the configured size.
    RecordTooLarge,
} || Allocator.Error || Io.File.ReadPositionalError || Io.File.LengthError;

/// What a ref record holds.
pub const RefValue = union(enum) {
    /// A tombstone: the ref is deleted as of this table.
    deletion,
    /// An object name.
    direct: Oid,
    /// An annotated tag's name and the object it peels to.
    peeled: struct { value: Oid, target: Oid },
    /// Another ref's name.
    symbolic: []const u8,
};

/// One ref as a table records it. The strings borrow the table's bytes or
/// the iterator that produced them, until the next call.
pub const RefRecord = struct {
    name: []const u8,
    update_index: u64,
    value: RefValue,
};

/// One reflog entry's contents.
pub const LogUpdate = struct {
    old: Oid,
    new: Oid,
    name: []const u8,
    email: []const u8,
    /// Seconds since the epoch.
    time: u64,
    /// The zone as git stores it here: the `±hhmm` digits read as one
    /// decimal number, so `+0130` is 130 and `-0500` is -500.
    tz_offset: i16,
    /// With the trailing newline git's writer adds.
    message: []const u8,
};

/// What a log record holds.
pub const LogValue = union(enum) {
    /// A tombstone: the entry with this ref and update index is gone.
    deletion,
    update: LogUpdate,
};

/// One reflog entry as a table records it. Newest first within a ref,
/// which is why the update index is stored inverted in the key.
pub const LogRecord = struct {
    name: []const u8,
    update_index: u64,
    value: LogValue,
};

/// Where a table's bytes come from.
pub const Source = union(enum) {
    /// The whole table in memory, kept alive by the caller.
    bytes: []const u8,
    /// An open file, read a block at a time with positional reads, kept
    /// open by the caller. Nothing is read that a lookup does not reach.
    file: struct { file: Io.File, io: Io },
};

/// A parsed table: its header and footer, and where to read the rest.
pub const Table = struct {
    source: Source,
    kind: Kind,
    version: u8,
    block_size: u32,
    min_update_index: u64,
    max_update_index: u64,
    /// Where the footer begins; no block reaches past it.
    size: usize,
    ref_index_offset: u64,
    obj_offset: u64,
    obj_id_len: u8,
    obj_index_offset: u64,
    log_offset: u64,
    log_index_offset: u64,
    has_refs: bool,
    has_logs: bool,
    has_objs: bool,

    /// Read a table's header and footer from bytes in memory. Nothing past
    /// them is looked at until a record is asked for.
    pub fn parse(bytes: []const u8, kind: Kind) Error!Table {
        if (bytes.len < 5 or !std.mem.eql(u8, bytes[0..4], magic)) return error.NotAReftable;
        const version = bytes[4];
        if (version != 1 and version != 2) return error.UnsupportedReftableVersion;
        const footer_len = footerSize(version);
        if (bytes.len < headerSize(version) + footer_len) return error.NotAReftable;
        const head = bytes[0..@min(bytes.len, headerSize(2) + 1)];
        return fromParts(.{ .bytes = bytes }, head, bytes[bytes.len - footer_len ..], bytes.len, kind);
    }

    /// Read a table's header and footer from an open file, which the caller
    /// keeps open for as long as the table is used. Blocks are read as a
    /// lookup reaches them.
    pub fn open(io: Io, file: Io.File, kind: Kind) Error!Table {
        const total = try file.length(io);
        const len: usize = std.math.cast(usize, total) orelse return error.NotAReftable;
        var head_buf: [29]u8 = undefined;
        const head = head_buf[0..@min(len, head_buf.len)];
        if (try file.readPositionalAll(io, head, 0) != head.len) return error.NotAReftable;
        if (head.len < 5 or !std.mem.eql(u8, head[0..4], magic)) return error.NotAReftable;
        const version = head[4];
        if (version != 1 and version != 2) return error.UnsupportedReftableVersion;
        const footer_len = footerSize(version);
        if (len < headerSize(version) + footer_len) return error.NotAReftable;
        var footer_buf: [72]u8 = undefined;
        const footer = footer_buf[0..footer_len];
        if (try file.readPositionalAll(io, footer, len - footer_len) != footer_len) return error.NotAReftable;
        return fromParts(.{ .file = .{ .file = file, .io = io } }, head, footer, len, kind);
    }

    /// The table from its first bytes -- the header and the byte after it,
    /// where the file has one -- and its footer.
    fn fromParts(source: Source, bytes: []const u8, footer: []const u8, total: usize, kind: Kind) Error!Table {
        const version = bytes[4];
        const header_len = headerSize(version);
        const size = total - footer.len;
        if (bytes.len < header_len) return error.NotAReftable;
        if (!std.mem.eql(u8, footer[0..header_len], bytes[0..header_len])) return error.CorruptFooter;

        var at: usize = 5;
        const block_size = std.mem.readInt(u24, footer[at..][0..3], .big);
        at += 3;
        const min_index = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        const max_index = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        if (version == 2) {
            const id = std.mem.readInt(u32, footer[at..][0..4], .big);
            at += 4;
            const named: Kind = switch (id) {
                format_id_sha1 => .sha1,
                format_id_sha256 => .sha256,
                else => return error.CorruptFooter,
            };
            if (named != kind) return error.HashMismatch;
        } else if (kind != .sha1) {
            return error.HashMismatch;
        }
        const ref_index = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        const obj_field = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        const obj_index = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        const log_offset = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        const log_index = std.mem.readInt(u64, footer[at..][0..8], .big);
        at += 8;
        const stored_crc = std.mem.readInt(u32, footer[at..][0..4], .big);
        if (std.hash.Crc32.hash(footer[0..at]) != stored_crc) return error.FooterChecksumMismatch;

        // The type of the first block, which is what says whether there
        // are refs at all. An empty table's "first block" is its footer.
        const first_type: u8 = if (size > header_len and bytes.len > header_len) bytes[header_len] else 0;
        const obj_offset = obj_field >> 5;
        const obj_id_len: u8 = @intCast(obj_field & 0x1f);
        const has_objs = obj_offset > 0;
        if (has_objs and obj_id_len == 0) return error.CorruptFooter;
        return .{
            .source = source,
            .kind = kind,
            .version = version,
            .block_size = block_size,
            .min_update_index = min_index,
            .max_update_index = max_index,
            .size = size,
            .ref_index_offset = ref_index,
            .obj_offset = obj_offset,
            .obj_id_len = obj_id_len,
            .obj_index_offset = obj_index,
            .log_offset = log_offset,
            .log_index_offset = log_index,
            .has_refs = first_type == @intFromEnum(BlockType.ref),
            .has_logs = first_type == @intFromEnum(BlockType.log) or log_offset > 0,
            .has_objs = has_objs,
        };
    }

    fn sectionStart(t: *const Table, typ: BlockType) ?u64 {
        return switch (typ) {
            .ref => if (t.has_refs) 0 else null,
            .log => if (t.has_logs) t.log_offset else null,
            .obj => if (t.has_objs) t.obj_offset else null,
            .index => null,
        };
    }

    fn sectionIndex(t: *const Table, typ: BlockType) u64 {
        return switch (typ) {
            .ref => t.ref_index_offset,
            .log => t.log_index_offset,
            .obj => t.obj_index_offset,
            .index => 0,
        };
    }

    /// An iterator over every record of `typ`, from the first.
    pub fn iterate(t: *const Table, gpa: Allocator, typ: BlockType) Error!Iterator {
        var it: Iterator = .{ .gpa = gpa, .table = t, .typ = typ };
        errdefer it.deinit();
        const start = t.sectionStart(typ) orelse return it;
        try it.enter(start);
        return it;
    }

    /// An iterator over the records of `typ` from the first whose key is
    /// at least `key`, found through the section's index where the table
    /// has one and by the first key of each block where it does not.
    pub fn seek(t: *const Table, gpa: Allocator, typ: BlockType, key: []const u8) Error!Iterator {
        var it: Iterator = .{ .gpa = gpa, .table = t, .typ = typ };
        errdefer it.deinit();
        const start = t.sectionStart(typ) orelse return it;
        const index_at = t.sectionIndex(typ);
        if (index_at != 0) {
            var at = index_at;
            // Each index level narrows to one block of the level below; a
            // table is finite and every step moves to a lower offset or to
            // the section, so the depth is bounded by the table itself.
            var levels: usize = 0;
            while (true) : (levels += 1) {
                if (levels > 64) return error.CorruptBlock;
                var block = (try t.loadBlock(gpa, at)) orelse return it;
                defer block.deinit(gpa);
                if (block.typ != @intFromEnum(BlockType.index)) {
                    if (block.typ != @intFromEnum(typ)) return error.CorruptBlock;
                    break;
                }
                var cursor: Iterator = .{ .gpa = gpa, .table = t, .typ = .index };
                defer cursor.deinit();
                cursor.block = block;
                cursor.block_at = at;
                defer cursor.block = null;
                try cursor.seekInBlock(key);
                const record = (try cursor.nextInBlock()) orelse return it;
                at = record.index_offset;
            }
            try it.enter(at);
        } else {
            try it.enter(start);
            if (it.block == null) return it;
            // The last block whose first key is not past the key holds it.
            while (true) {
                const next_at = it.block_at + it.block.?.full_size;
                var next = (try t.loadBlock(gpa, next_at)) orelse break;
                if (next.typ != @intFromEnum(typ)) {
                    next.deinit(gpa);
                    break;
                }
                const first = try next.firstKey(gpa);
                defer gpa.free(first);
                if (std.mem.order(u8, first, key) == .gt) {
                    next.deinit(gpa);
                    break;
                }
                it.block.?.deinit(gpa);
                it.block = next;
                it.block_at = next_at;
                it.pos = next.header_off + 4;
                it.key.clearRetainingCapacity();
            }
        }
        try it.seekInBlock(key);
        return it;
    }

    /// `len` bytes from `off` of a file-backed table, or fewer where the
    /// blocks end first. The caller's.
    fn readAt(t: *const Table, gpa: Allocator, off: usize, len: usize) Error![]u8 {
        const f = t.source.file;
        const n = @min(len, t.size - off);
        const buf = try gpa.alloc(u8, n);
        errdefer gpa.free(buf);
        if (try f.file.readPositionalAll(f.io, buf, off) != n) return error.CorruptBlock;
        return buf;
    }

    /// The block at `at`, or `null` past the last one.
    fn loadBlock(t: *const Table, gpa: Allocator, at: u64) Error!?Block {
        if (at >= t.size) return null;
        const off: usize = @intCast(at);
        const header_off: usize = if (off == 0) headerSize(t.version) else 0;
        // From a file, the header first, then as much as the block says it
        // is -- a byte more, to tell padding from the next block -- or, for
        // a deflated log block, as much as its data could take to compress.
        var raw: ?[]u8 = null;
        defer if (raw) |r| gpa.free(r);
        var data: []const u8 = switch (t.source) {
            .bytes => |b| b[off..t.size],
            .file => blk: {
                raw = try t.readAt(gpa, off, @max(t.block_size, 64) + 1);
                break :blk raw.?;
            },
        };
        if (data.len < header_off + 4) return error.CorruptBlock;
        const typ = data[header_off];
        switch (typ) {
            'r', 'g', 'o', 'i' => {},
            else => return error.CorruptBlock,
        }
        const len = std.mem.readInt(u24, data[header_off + 1 ..][0..3], .big);
        const skip = header_off + 4;
        if (len < skip + 2) return error.CorruptBlock;
        if (t.source == .file) {
            const want = if (typ == @intFromEnum(BlockType.log)) len + len / 256 + 64 else len + 1;
            if (want > data.len and data.len < t.size - off) {
                gpa.free(raw.?);
                raw = null;
                raw = try t.readAt(gpa, off, want);
                data = raw.?;
            }
        }

        var block: Block = .{
            .typ = typ,
            .header_off = header_off,
            .data = undefined,
            .owned = null,
            .restart_off = 0,
            .restart_count = 0,
            .full_size = 0,
        };
        if (typ == @intFromEnum(BlockType.log)) {
            const out = try gpa.alloc(u8, len);
            errdefer gpa.free(out);
            @memcpy(out[0..skip], data[0..skip]);
            const window = try gpa.alloc(u8, flate.max_window_len);
            defer gpa.free(window);
            var input: Io.Reader = .fixed(data[skip..]);
            var inflate: flate.Decompress = .init(&input, .zlib, window);
            inflate.reader.readSliceAll(out[skip..]) catch return error.CorruptBlock;
            // The stream has to end exactly there: the footer and the
            // checksum read, and nothing more to inflate.
            var extra: [1]u8 = undefined;
            const more = inflate.reader.readSliceShort(&extra) catch return error.CorruptBlock;
            if (more != 0) return error.CorruptBlock;
            block.data = out;
            block.owned = out;
            block.full_size = skip + input.seek;
        } else {
            if (len > data.len) return error.CorruptBlock;
            block.data = data[0..len];
            // Padded to the block size, unless what follows the data is not
            // padding -- the footer, or an unaligned next block.
            block.full_size = if (t.block_size == 0)
                len
            else if (len < t.block_size and len < data.len and data[len] != 0)
                len
            else
                t.block_size;
            // A block read from a file keeps the buffer it was read into.
            if (raw) |r| {
                block.owned = r;
                raw = null;
            }
        }
        errdefer block.deinit(gpa);
        const count = std.mem.readInt(u16, block.data[len - 2 ..][0..2], .big);
        const table_len = 2 + 3 * @as(usize, count);
        if (len < skip + table_len) return error.CorruptBlock;
        block.restart_off = len - table_len;
        block.restart_count = count;
        for (0..count) |i| {
            const r = block.restart(i);
            if (r < skip or r >= block.restart_off) return error.CorruptBlock;
        }
        if (block.full_size == 0) return error.CorruptBlock;
        return block;
    }

    /// Walk every block of every section and decode every record, checking
    /// that keys rise and that each value is one its type allows. What a
    /// lookup would find is only the part of this a lookup reaches; this is
    /// the whole of it.
    pub fn verify(t: *const Table, gpa: Allocator) Error!void {
        for ([_]BlockType{ .ref, .obj, .log }) |typ| {
            var it = try t.iterate(gpa, typ);
            defer it.deinit();
            var last: std.ArrayList(u8) = .empty;
            defer last.deinit(gpa);
            var first = true;
            while (try it.nextRaw()) |raw| {
                if (!first and std.mem.order(u8, last.items, raw.key) != .lt) return error.UnsortedRecords;
                first = false;
                last.clearRetainingCapacity();
                try last.appendSlice(gpa, raw.key);
            }
        }
        for ([_]BlockType{ .ref, .obj, .log }) |typ| {
            const at = t.sectionIndex(typ);
            if (at == 0) continue;
            var block = (try t.loadBlock(gpa, at)) orelse return error.CorruptBlock;
            defer block.deinit(gpa);
            if (block.typ != @intFromEnum(BlockType.index)) return error.CorruptBlock;
            var it: Iterator = .{ .gpa = gpa, .table = t, .typ = .index };
            defer it.deinit();
            it.block = block;
            it.block_at = at;
            it.pos = block.header_off + 4;
            defer it.block = null;
            while (try it.nextInBlock()) |_| {}
        }
    }
};

/// One block, its bytes from its own start: the file's for a ref, object
/// or index block, inflated and owned for a log block.
const Block = struct {
    typ: u8,
    header_off: usize,
    data: []const u8,
    owned: ?[]u8,
    /// Where the records end and the restart table begins.
    restart_off: usize,
    restart_count: u16,
    /// How far the next block starts from this one.
    full_size: usize,

    fn deinit(b: *Block, gpa: Allocator) void {
        if (b.owned) |bytes| gpa.free(bytes);
        b.owned = null;
    }

    fn restart(b: *const Block, i: usize) usize {
        return std.mem.readInt(u24, b.data[b.restart_off + 3 * i ..][0..3], .big);
    }

    /// The first record's key, which is stored whole. The caller's.
    fn firstKey(b: *const Block, gpa: Allocator) Error![]u8 {
        var key: std.ArrayList(u8) = .empty;
        errdefer key.deinit(gpa);
        _ = try decodeKey(gpa, b.data[0..b.restart_off], b.header_off + 4, &key);
        return key.toOwnedSlice(gpa);
    }
};

/// A key's prefix and suffix read at `pos`, applied to `key`, which holds
/// the key before it. Returns the value type and where the value starts.
fn decodeKey(gpa: Allocator, data: []const u8, pos: usize, key: *std.ArrayList(u8)) Error!struct { extra: u3, at: usize } {
    if (pos >= data.len) return error.CorruptRecord;
    const prefix = varint.readOffset(data[pos..]) catch return error.CorruptRecord;
    var at = pos + prefix.len;
    const packed_suffix = varint.readOffset(data[at..]) catch return error.CorruptRecord;
    at += packed_suffix.len;
    const suffix_len = packed_suffix.value >> 3;
    if (prefix.value > key.items.len) return error.CorruptRecord;
    if (suffix_len > data.len - at) return error.CorruptRecord;
    const suffix: usize = @intCast(suffix_len);
    key.shrinkRetainingCapacity(@intCast(prefix.value));
    try key.appendSlice(gpa, data[at..][0..suffix]);
    return .{ .extra = @truncate(packed_suffix.value), .at = at + suffix };
}

/// A record's key and value type, with the value's bytes still to read.
pub const Raw = struct {
    key: []const u8,
    extra: u3,
};

/// A walk over one section of a table. What it hands back borrows the
/// iterator and is valid until the next call.
pub const Iterator = struct {
    gpa: Allocator,
    table: *const Table,
    typ: BlockType,
    block: ?Block = null,
    block_at: u64 = 0,
    pos: usize = 0,
    key: std.ArrayList(u8) = .empty,
    /// The last decoded value, for the accessor that wants it.
    value_at: usize = 0,

    /// Release the iterator.
    pub fn deinit(it: *Iterator) void {
        if (it.block) |*b| b.deinit(it.gpa);
        it.key.deinit(it.gpa);
        it.* = undefined;
    }

    fn enter(it: *Iterator, at: u64) Error!void {
        const block = (try it.table.loadBlock(it.gpa, at)) orelse return;
        if (block.typ != @intFromEnum(it.typ)) {
            var b = block;
            b.deinit(it.gpa);
            return;
        }
        if (it.block) |*old| old.deinit(it.gpa);
        it.block = block;
        it.block_at = at;
        it.pos = block.header_off + 4;
        it.key.clearRetainingCapacity();
    }

    /// Put the cursor on the first record of this block whose key is at
    /// least `want`, or at the block's end. Bisects the restart points,
    /// whose keys are stored whole, then walks.
    fn seekInBlock(it: *Iterator, want: []const u8) Error!void {
        const block = if (it.block) |*b| b else return;
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(it.gpa);
        var lo: usize = 0;
        var hi: usize = block.restart_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            scratch.clearRetainingCapacity();
            const start = block.restart(mid);
            // A restart's key shares nothing with the one before it.
            if (start >= block.restart_off or block.data[start] != 0) return error.CorruptBlock;
            _ = try decodeKey(it.gpa, block.data[0..block.restart_off], start, &scratch);
            if (std.mem.order(u8, scratch.items, want) == .gt) hi = mid else lo = mid + 1;
        }
        it.pos = if (lo == 0) block.header_off + 4 else block.restart(lo - 1);
        it.key.clearRetainingCapacity();
        var previous: std.ArrayList(u8) = .empty;
        defer previous.deinit(it.gpa);
        while (it.pos < block.restart_off) {
            previous.clearRetainingCapacity();
            try previous.appendSlice(it.gpa, it.key.items);
            const record_at = it.pos;
            const decoded = try decodeKey(it.gpa, block.data[0..block.restart_off], it.pos, &it.key);
            if (std.mem.order(u8, it.key.items, want) != .lt) {
                it.pos = record_at;
                it.key.clearRetainingCapacity();
                try it.key.appendSlice(it.gpa, previous.items);
                return;
            }
            it.pos = try skipValue(it.table, block.typ, block.data[0..block.restart_off], decoded.at, decoded.extra, it.key.items);
        }
    }

    const IndexRecord = struct { key: []const u8, index_offset: u64 };

    /// The next record of an index block, without moving to another block.
    fn nextInBlock(it: *Iterator) Error!?IndexRecord {
        const block = if (it.block) |*b| b else return null;
        if (it.pos >= block.restart_off) return null;
        const decoded = try decodeKey(it.gpa, block.data[0..block.restart_off], it.pos, &it.key);
        const value = varint.readOffset(block.data[decoded.at..block.restart_off]) catch return error.CorruptRecord;
        it.pos = decoded.at + value.len;
        return .{ .key = it.key.items, .index_offset = value.value };
    }

    /// The next record's key and value type, the value checked and passed
    /// over; `value` then reads it.
    pub fn nextRaw(it: *Iterator) Error!?Raw {
        while (true) {
            const block = if (it.block) |*b| b else return null;
            if (it.pos < block.restart_off) {
                const decoded = try decodeKey(it.gpa, block.data[0..block.restart_off], it.pos, &it.key);
                it.value_at = decoded.at;
                it.pos = try skipValue(it.table, block.typ, block.data[0..block.restart_off], decoded.at, decoded.extra, it.key.items);
                return .{ .key = it.key.items, .extra = decoded.extra };
            }
            const next_at = it.block_at + block.full_size;
            const had = it.block_at;
            var old = it.block.?;
            it.block = null;
            old.deinit(it.gpa);
            try it.enter(next_at);
            if (it.block == null or it.block_at == had) {
                it.block = null;
                return null;
            }
        }
    }

    /// The next ref. Only for an iterator over refs.
    pub fn nextRef(it: *Iterator) Error!?RefRecord {
        std.debug.assert(it.typ == .ref);
        const raw = (try it.nextRaw()) orelse return null;
        return try decodeRef(it.table, it.block.?.data[0..it.block.?.restart_off], it.value_at, raw);
    }

    /// The next log entry. Only for an iterator over logs.
    pub fn nextLog(it: *Iterator) Error!?LogRecord {
        std.debug.assert(it.typ == .log);
        const raw = (try it.nextRaw()) orelse return null;
        return try decodeLog(it.table, it.block.?.data[0..it.block.?.restart_off], it.value_at, raw);
    }
};

/// Where the value that starts at `at` ends, having checked it is one the
/// record type allows.
fn skipValue(t: *const Table, typ: u8, data: []const u8, at: usize, extra: u3, key: []const u8) Error!usize {
    const raw: Raw = .{ .key = key, .extra = extra };
    switch (typ) {
        'r' => return (try decodeRefValue(t, data, at, raw)).end,
        'g' => return (try decodeLogValue(t, data, at, raw)).end,
        'i' => {
            const value = varint.readOffset(data[@min(at, data.len)..]) catch return error.CorruptRecord;
            return at + value.len;
        },
        'o' => {
            var pos = at;
            var count: u64 = extra;
            if (count == 0) {
                const n = varint.readOffset(data[@min(pos, data.len)..]) catch return error.CorruptRecord;
                pos += n.len;
                count = n.value;
            }
            // Every offset takes a byte at least, which bounds the count by
            // what is left of the block before anything is believed.
            if (count > data.len - @min(pos, data.len)) return error.CorruptRecord;
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const n = varint.readOffset(data[@min(pos, data.len)..]) catch return error.CorruptRecord;
                pos += n.len;
            }
            return pos;
        },
        else => return error.CorruptBlock,
    }
}

fn readOid(t: *const Table, data: []const u8, at: usize) Error!Oid {
    const len = t.kind.rawLen();
    if (at > data.len or data.len - at < len) return error.CorruptRecord;
    return Oid.fromRaw(t.kind, data[at..][0..len]) catch unreachable;
}

fn readString(data: []const u8, at: usize) Error!struct { text: []const u8, end: usize } {
    if (at > data.len) return error.CorruptRecord;
    const len = varint.readOffset(data[at..]) catch return error.CorruptRecord;
    const start = at + len.len;
    if (len.value > data.len - start) return error.CorruptRecord;
    const n: usize = @intCast(len.value);
    return .{ .text = data[start..][0..n], .end = start + n };
}

fn decodeRefValue(t: *const Table, data: []const u8, at: usize, raw: Raw) Error!struct { value: RefValue, update_index: u64, end: usize } {
    if (at > data.len) return error.CorruptRecord;
    const delta = varint.readOffset(data[at..]) catch return error.CorruptRecord;
    const update_index = std.math.add(u64, t.min_update_index, delta.value) catch return error.CorruptRecord;
    var pos = at + delta.len;
    const len = t.kind.rawLen();
    const value: RefValue = switch (raw.extra) {
        0 => .deletion,
        1 => blk: {
            const oid = try readOid(t, data, pos);
            pos += len;
            break :blk .{ .direct = oid };
        },
        2 => blk: {
            const value = try readOid(t, data, pos);
            const target = try readOid(t, data, pos + len);
            pos += 2 * len;
            break :blk .{ .peeled = .{ .value = value, .target = target } };
        },
        3 => blk: {
            const s = try readString(data, pos);
            pos = s.end;
            break :blk .{ .symbolic = s.text };
        },
        else => return error.CorruptRecord,
    };
    return .{ .value = value, .update_index = update_index, .end = pos };
}

fn decodeRef(t: *const Table, data: []const u8, at: usize, raw: Raw) Error!RefRecord {
    const decoded = try decodeRefValue(t, data, at, raw);
    return .{ .name = raw.key, .update_index = decoded.update_index, .value = decoded.value };
}

fn decodeLogValue(t: *const Table, data: []const u8, at: usize, raw: Raw) Error!struct { value: LogValue, end: usize } {
    // The key is the ref's name, a NUL, and the inverted update index.
    if (raw.key.len <= 9 or raw.key[raw.key.len - 9] != 0) return error.CorruptRecord;
    switch (raw.extra) {
        0 => return .{ .value = .deletion, .end = at },
        1 => {},
        else => return error.CorruptRecord,
    }
    const len = t.kind.rawLen();
    const old = try readOid(t, data, at);
    const new = try readOid(t, data, at + len);
    const name = try readString(data, at + 2 * len);
    const email = try readString(data, name.end);
    if (email.end > data.len) return error.CorruptRecord;
    const time = varint.readOffset(data[email.end..]) catch return error.CorruptRecord;
    const tz_at = email.end + time.len;
    if (tz_at > data.len or data.len - tz_at < 2) return error.CorruptRecord;
    const tz: i16 = @bitCast(std.mem.readInt(u16, data[tz_at..][0..2], .big));
    const message = try readString(data, tz_at + 2);
    return .{
        .value = .{ .update = .{
            .old = old,
            .new = new,
            .name = name.text,
            .email = email.text,
            .time = time.value,
            .tz_offset = tz,
            .message = message.text,
        } },
        .end = message.end,
    };
}

fn decodeLog(t: *const Table, data: []const u8, at: usize, raw: Raw) Error!LogRecord {
    const decoded = try decodeLogValue(t, data, at, raw);
    const inverted = std.mem.readInt(u64, raw.key[raw.key.len - 8 ..][0..8], .big);
    return .{
        .name = raw.key[0 .. raw.key.len - 9],
        .update_index = ~inverted,
        .value = decoded.value,
    };
}

/// A log record's key: the ref's name, a NUL, and the update index
/// inverted, so a ref's newest entry sorts first. The caller's.
pub fn logKey(gpa: Allocator, name: []const u8, update_index: u64) Allocator.Error![]u8 {
    const key = try gpa.alloc(u8, name.len + 9);
    @memcpy(key[0..name.len], name);
    key[name.len] = 0;
    std.mem.writeInt(u64, key[name.len + 1 ..][0..8], ~update_index, .big);
    return key;
}

//=========================================================================
// Writing
//
// git's writer, step for step, because the layout is part of the bytes: a
// block is filled until the next record would not fit with its restart
// table, then padded to the block size -- except that the padding of the
// block before the logs and of the last block before the footer is never
// written. A section of more than three blocks gets an index, and an index
// of more than three blocks gets an index of its own. The object index is
// written only when the refs needed an index, which is git's rule for when
// a table is big enough for it to pay.
//=========================================================================

/// How a table is written. The defaults are git's.
pub const WriteOptions = struct {
    /// `reftable.blockSize`.
    block_size: u32 = 4096,
    /// `reftable.restartInterval`: a key is stored whole at least this
    /// often.
    restart_interval: u16 = 16,
    /// `reftable.indexObjects`: whether to write the object index.
    index_objects: bool = true,
};

/// Write one table holding `refs`, sorted by name, and `logs`, sorted by
/// name and then newest first. Every ref's update index must lie in
/// `[min_update_index, max_update_index]` and no log's above the latter.
/// The result is the caller's.
///
/// A log update's message is written as given; git's writer ends each with
/// one newline, and the stack does that before it gets here.
pub fn write(
    gpa: Allocator,
    kind: Kind,
    options: WriteOptions,
    min_update_index: u64,
    max_update_index: u64,
    refs: []const RefRecord,
    logs: []const LogRecord,
) Error![]u8 {
    if (options.block_size < 64 or options.block_size >= (1 << 24)) return error.RecordTooLarge;
    var w: Writer = try .init(gpa, kind, options, min_update_index, max_update_index);
    defer w.deinit();

    for (refs, 0..) |ref, i| {
        if (i > 0 and std.mem.order(u8, refs[i - 1].name, ref.name) != .lt) return error.UnsortedRecords;
        if (ref.name.len == 0) return error.UnsortedRecords;
        if (ref.update_index < min_update_index or ref.update_index > max_update_index) return error.UpdateIndexOutOfRange;
        try w.addRef(ref);
    }
    for (logs, 0..) |log, i| {
        if (log.name.len == 0) return error.UnsortedRecords;
        if (i > 0) {
            const by_name = std.mem.order(u8, logs[i - 1].name, log.name);
            if (by_name == .gt or (by_name == .eq and logs[i - 1].update_index <= log.update_index)) return error.UnsortedRecords;
        }
        if (log.update_index > max_update_index) return error.UpdateIndexOutOfRange;
        try w.addLog(log);
    }
    return w.close();
}

const IndexEntry = struct { key: []u8, offset: u64 };

const SectionStats = struct {
    offset: u64 = 0,
    blocks: u64 = 0,
    index_offset: u64 = 0,
    index_blocks: u64 = 0,
};

const Writer = struct {
    gpa: Allocator,
    kind: Kind,
    options: WriteOptions,
    version: u8,
    min_update_index: u64,
    max_update_index: u64,
    out: std.ArrayList(u8) = .empty,
    /// The offset the next block starts at, counting padding not yet
    /// written.
    next: u64 = 0,
    pending_padding: usize = 0,
    block: []u8,
    /// The block being filled, or `null` between blocks.
    open: ?OpenBlock = null,
    /// The section's last key, for the order check; cleared at each block.
    last_key: std.ArrayList(u8) = .empty,
    index: std.ArrayList(IndexEntry) = .empty,
    refs: SectionStats = .{},
    objs: SectionStats = .{},
    logs: SectionStats = .{},
    indexes: SectionStats = .{},
    object_id_len: u8 = 0,
    /// Object names to the ref blocks naming them, for the object index.
    objects: std.AutoArrayHashMapUnmanaged([hash.max_raw_len]u8, std.ArrayList(u64)) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    const OpenBlock = struct {
        typ: BlockType,
        header_off: usize,
        next: usize,
        entries: usize = 0,
        restarts: std.ArrayList(u32) = .empty,
        last_key: std.ArrayList(u8) = .empty,
    };

    fn init(gpa: Allocator, kind: Kind, options: WriteOptions, min: u64, max: u64) Allocator.Error!Writer {
        const block = try gpa.alloc(u8, options.block_size);
        @memset(block, 0);
        return .{
            .gpa = gpa,
            .kind = kind,
            .options = options,
            .version = versionFor(kind),
            .min_update_index = min,
            .max_update_index = max,
            .block = block,
        };
    }

    fn deinit(w: *Writer) void {
        w.out.deinit(w.gpa);
        w.gpa.free(w.block);
        w.dropOpen();
        w.last_key.deinit(w.gpa);
        w.clearIndex();
        w.index.deinit(w.gpa);
        for (w.objects.values()) |*offsets| offsets.deinit(w.gpa);
        w.objects.deinit(w.gpa);
        w.scratch.deinit(w.gpa);
    }

    fn clearIndex(w: *Writer) void {
        for (w.index.items) |e| w.gpa.free(e.key);
        w.index.clearRetainingCapacity();
    }

    fn stats(w: *Writer, typ: BlockType) *SectionStats {
        return switch (typ) {
            .ref => &w.refs,
            .obj => &w.objs,
            .log => &w.logs,
            .index => &w.indexes,
        };
    }

    fn writeHeader(w: *const Writer, buf: []u8) usize {
        @memcpy(buf[0..4], magic);
        buf[4] = w.version;
        std.mem.writeInt(u24, buf[5..8], @intCast(w.options.block_size), .big);
        std.mem.writeInt(u64, buf[8..16], w.min_update_index, .big);
        std.mem.writeInt(u64, buf[16..24], w.max_update_index, .big);
        if (w.version == 2) {
            std.mem.writeInt(u32, buf[24..28], if (w.kind == .sha1) format_id_sha1 else format_id_sha256, .big);
        }
        return headerSize(w.version);
    }

    fn reinit(w: *Writer, typ: BlockType) Allocator.Error!void {
        const header_off: usize = if (w.next == 0) headerSize(w.version) else 0;
        w.last_key.clearRetainingCapacity();
        w.dropOpen();
        @memset(w.block, 0);
        w.block[header_off] = @intFromEnum(typ);
        w.open = .{ .typ = typ, .header_off = header_off, .next = header_off + 4 };
    }

    /// Append one record to the open block. False when it does not fit,
    /// which is the signal to start another.
    fn blockAdd(w: *Writer, key: []const u8, extra: u8, value: []const u8) Allocator.Error!bool {
        const o = &w.open.?;
        const last: []const u8 = if (o.entries % w.options.restart_interval == 0) "" else o.last_key.items;
        const prefix = commonPrefix(last, key);
        var restart = prefix == 0;

        w.scratch.clearRetainingCapacity();
        var buf: [16]u8 = undefined;
        try w.scratch.appendSlice(w.gpa, varint.writeOffset(&buf, prefix));
        try w.scratch.appendSlice(w.gpa, varint.writeOffset(&buf, (@as(u64, key.len - prefix) << 3) | extra));
        try w.scratch.appendSlice(w.gpa, key[prefix..]);
        try w.scratch.appendSlice(w.gpa, value);
        const n = w.scratch.items.len;

        var restarts = o.restarts.items.len;
        if (restarts >= max_restarts) restart = false;
        if (restart) restarts += 1;
        if (2 + 3 * restarts + n > w.options.block_size - o.next) return false;
        if (restart) try o.restarts.append(w.gpa, @intCast(o.next));
        @memcpy(w.block[o.next..][0..n], w.scratch.items);
        o.next += n;
        o.last_key.clearRetainingCapacity();
        try o.last_key.appendSlice(w.gpa, key);
        o.entries += 1;
        return true;
    }

    /// Close the open block: the restart table, the length, and for a log
    /// block the deflate. Returns the block's length on the disk.
    fn blockFinish(w: *Writer) Error!usize {
        const o = &w.open.?;
        for (o.restarts.items) |r| {
            std.mem.writeInt(u24, w.block[o.next..][0..3], @intCast(r), .big);
            o.next += 3;
        }
        std.mem.writeInt(u16, w.block[o.next..][0..2], @intCast(o.restarts.items.len), .big);
        o.next += 2;
        std.mem.writeInt(u24, w.block[o.header_off + 1 ..][0..3], @intCast(o.next), .big);
        if (o.typ != .log) return o.next;

        const skip = o.header_off + 4;
        var compressed: Io.Writer.Allocating = try .initCapacity(w.gpa, 64 + o.next);
        defer compressed.deinit();
        const window = try w.gpa.alloc(u8, flate.max_window_len);
        defer w.gpa.free(window);
        const state = try w.gpa.create(flate.Compress);
        defer w.gpa.destroy(state);
        state.* = flate.Compress.init(&compressed.writer, window, .zlib, .level_9) catch return error.OutOfMemory;
        state.writer.writeAll(w.block[skip..o.next]) catch return error.OutOfMemory;
        state.finish() catch return error.OutOfMemory;
        const bytes = compressed.written();
        // A log block is not bounded by the block size once deflated, and
        // is never padded; it is written from its own buffer.
        w.scratch.clearRetainingCapacity();
        try w.scratch.appendSlice(w.gpa, w.block[0..skip]);
        try w.scratch.appendSlice(w.gpa, bytes);
        return w.scratch.items.len;
    }

    fn paddedWrite(w: *Writer, data: []const u8, padding: usize) Allocator.Error!void {
        if (w.pending_padding > 0) try w.out.appendNTimes(w.gpa, 0, w.pending_padding);
        w.pending_padding = padding;
        try w.out.appendSlice(w.gpa, data);
    }

    fn flushBlock(w: *Writer) Error!void {
        const o = w.open orelse return;
        if (o.entries == 0) return;
        const typ = o.typ;
        const raw = try w.blockFinish();
        const padding: usize = if (typ == .log) 0 else w.options.block_size - raw;
        const s = w.stats(typ);
        if (s.blocks == 0 and w.next > 0) s.offset = w.next;
        s.blocks += 1;

        if (w.next == 0) _ = w.writeHeader(w.block);
        const data = if (typ == .log) w.scratch.items else w.block[0..raw];
        if (typ == .log and w.next == 0) _ = w.writeHeader(w.scratch.items);
        try w.paddedWrite(data, padding);

        const key = try w.gpa.dupe(u8, w.open.?.last_key.items);
        errdefer w.gpa.free(key);
        try w.index.append(w.gpa, .{ .key = key, .offset = w.next });
        w.next += padding + raw;
        w.dropOpen();
    }

    /// Add a record through the order check, starting a new block when the
    /// open one is full.
    fn addRecord(w: *Writer, typ: BlockType, key: []const u8, extra: u8, value: []const u8) Error!void {
        if (w.last_key.items.len != 0 and std.mem.order(u8, w.last_key.items, key) != .lt) return error.UnsortedRecords;
        w.last_key.clearRetainingCapacity();
        try w.last_key.appendSlice(w.gpa, key);
        if (w.open == null) try w.reinit(typ);
        if (try w.blockAdd(key, extra, value)) return;
        try w.flushBlock();
        try w.reinit(typ);
        // The order check's key was cleared with the new block.
        try w.last_key.appendSlice(w.gpa, key);
        if (!try w.blockAdd(key, extra, value)) return error.RecordTooLarge;
    }

    /// Flush the section's last block and write its index, as many levels
    /// of it as it takes to get down to three blocks.
    fn finishSection(w: *Writer) Error!void {
        const typ = (w.open orelse return).typ;
        const before = w.indexes.blocks;
        var index_start: u64 = 0;
        try w.flushBlock();
        while (w.index.items.len > 3) {
            index_start = w.next;
            try w.reinit(.index);
            const level = try w.index.toOwnedSlice(w.gpa);
            defer {
                for (level) |e| w.gpa.free(e.key);
                w.gpa.free(level);
            }
            for (level) |entry| {
                var buf: [16]u8 = undefined;
                try w.addRecord(.index, entry.key, 0, varint.writeOffset(&buf, entry.offset));
            }
            try w.flushBlock();
        }
        w.clearIndex();
        const s = w.stats(typ);
        s.index_blocks = w.indexes.blocks - before;
        s.index_offset = index_start;
        w.last_key.clearRetainingCapacity();
    }

    fn finishPublicSection(w: *Writer) Error!void {
        const typ = (w.open orelse return).typ;
        try w.finishSection();
        if (typ == .ref and w.options.index_objects and w.refs.index_blocks > 0) try w.writeObjectIndex();
        for (w.objects.values()) |*offsets| offsets.deinit(w.gpa);
        w.objects.clearRetainingCapacity();
        w.dropOpen();
    }

    /// Forget a block that was started and never given a record.
    fn dropOpen(w: *Writer) void {
        if (w.open) |*o| {
            o.restarts.deinit(w.gpa);
            o.last_key.deinit(w.gpa);
        }
        w.open = null;
    }

    fn noteObject(w: *Writer, oid: Oid) Allocator.Error!void {
        var raw: [hash.max_raw_len]u8 = @splat(0);
        @memcpy(raw[0..oid.raw().len], oid.raw());
        const gop = try w.objects.getOrPut(w.gpa, raw);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const offsets = gop.value_ptr;
        if (offsets.items.len > 0 and offsets.items[offsets.items.len - 1] == w.next) return;
        try offsets.append(w.gpa, w.next);
    }

    fn addRef(w: *Writer, ref: RefRecord) Error!void {
        w.scratch.clearRetainingCapacity();
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(w.gpa);
        var buf: [16]u8 = undefined;
        try value.appendSlice(w.gpa, varint.writeOffset(&buf, ref.update_index - w.min_update_index));
        const extra: u8 = switch (ref.value) {
            .deletion => 0,
            .direct => |oid| blk: {
                try value.appendSlice(w.gpa, oid.raw());
                break :blk 1;
            },
            .peeled => |p| blk: {
                try value.appendSlice(w.gpa, p.value.raw());
                try value.appendSlice(w.gpa, p.target.raw());
                break :blk 2;
            },
            .symbolic => |target| blk: {
                try value.appendSlice(w.gpa, varint.writeOffset(&buf, target.len));
                try value.appendSlice(w.gpa, target);
                break :blk 3;
            },
        };
        try w.addRecord(.ref, ref.name, extra, value.items);
        if (!w.options.index_objects) return;
        switch (ref.value) {
            .direct => |oid| try w.noteObject(oid),
            .peeled => |p| {
                try w.noteObject(p.value);
                try w.noteObject(p.target);
            },
            else => {},
        }
    }

    fn addLog(w: *Writer, log: LogRecord) Error!void {
        if (w.open) |o| {
            if (o.typ == .ref) try w.finishPublicSection();
        }
        // The padding of the last block before the logs is never written.
        w.next -= w.pending_padding;
        w.pending_padding = 0;

        const key = try logKey(w.gpa, log.name, log.update_index);
        defer w.gpa.free(key);
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(w.gpa);
        var buf: [16]u8 = undefined;
        const extra: u8 = switch (log.value) {
            .deletion => 0,
            .update => |u| blk: {
                try value.appendSlice(w.gpa, u.old.raw());
                try value.appendSlice(w.gpa, u.new.raw());
                for ([_][]const u8{ u.name, u.email }) |text| {
                    try value.appendSlice(w.gpa, varint.writeOffset(&buf, text.len));
                    try value.appendSlice(w.gpa, text);
                }
                try value.appendSlice(w.gpa, varint.writeOffset(&buf, u.time));
                var tz: [2]u8 = undefined;
                std.mem.writeInt(u16, &tz, @bitCast(u.tz_offset), .big);
                try value.appendSlice(w.gpa, &tz);
                try value.appendSlice(w.gpa, varint.writeOffset(&buf, u.message.len));
                try value.appendSlice(w.gpa, u.message);
                break :blk 1;
            },
        };
        try w.addRecord(.log, key, extra, value.items);
    }

    /// The object index: each object name the refs mention, cut to the
    /// shortest prefix that tells them apart, with the ref blocks that name
    /// it.
    fn writeObjectIndex(w: *Writer) Error!void {
        const SortCtx = struct {
            keys: [][hash.max_raw_len]u8,
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, &c.keys[a], &c.keys[b]) == .lt;
            }
        };
        w.objects.sort(SortCtx{ .keys = w.objects.keys() });
        const keys = w.objects.keys();
        const raw_len = w.kind.rawLen();
        // Two bytes at the least, and one more than any two neighbours share.
        var longest: usize = 1;
        if (keys.len > 1) {
            for (keys[1..], keys[0 .. keys.len - 1]) |b, a| {
                longest = @max(longest, commonPrefix(a[0..raw_len], b[0..raw_len]));
            }
        }
        w.object_id_len = @intCast(longest + 1);

        try w.reinit(.obj);
        for (keys, w.objects.values()) |*key, offsets| {
            const prefix = key[0..w.object_id_len];
            var value: std.ArrayList(u8) = .empty;
            defer value.deinit(w.gpa);
            var count = offsets.items.len;
            var extra: u8 = try encodeOffsets(w.gpa, &value, offsets.items, count);
            if (try w.blockAdd(prefix, extra, value.items)) continue;
            try w.flushBlock();
            try w.reinit(.obj);
            if (try w.blockAdd(prefix, extra, value.items)) continue;
            // Too many blocks name it for one record: git keeps the name and
            // drops the list.
            count = 0;
            value.clearRetainingCapacity();
            extra = try encodeOffsets(w.gpa, &value, offsets.items, count);
            if (!try w.blockAdd(prefix, extra, value.items)) return error.RecordTooLarge;
        }
        try w.finishSection();
    }

    fn close(w: *Writer) Error![]u8 {
        try w.finishPublicSection();
        w.pending_padding = 0;
        if (w.next == 0) {
            var header: [28]u8 = undefined;
            const n = w.writeHeader(&header);
            try w.paddedWrite(header[0..n], 0);
        }
        var footer: [72]u8 = undefined;
        var at = w.writeHeader(&footer);
        for ([_]u64{
            w.refs.index_offset,
            (w.objs.offset << 5) | w.object_id_len,
            w.objs.index_offset,
            w.logs.offset,
            w.logs.index_offset,
        }) |field| {
            std.mem.writeInt(u64, footer[at..][0..8], field, .big);
            at += 8;
        }
        std.mem.writeInt(u32, footer[at..][0..4], std.hash.Crc32.hash(footer[0..at]), .big);
        at += 4;
        try w.paddedWrite(footer[0..at], 0);
        return w.out.toOwnedSlice(w.gpa);
    }
};

/// An object record's value: the count when it does not fit in the value
/// type, then the first block offset and the distance to each next one.
/// Returns the value type.
fn encodeOffsets(gpa: Allocator, out: *std.ArrayList(u8), offsets: []const u64, count: usize) Allocator.Error!u8 {
    var buf: [16]u8 = undefined;
    if (count == 0 or count >= 8) try out.appendSlice(gpa, varint.writeOffset(&buf, count));
    if (count == 0) return 0;
    try out.appendSlice(gpa, varint.writeOffset(&buf, offsets[0]));
    var last = offsets[0];
    for (offsets[1..count]) |off| {
        try out.appendSlice(gpa, varint.writeOffset(&buf, off - last));
        last = off;
    }
    return if (count < 8) @intCast(count) else 0;
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("testgit.zig");

fn oidOf(byte: u8) Oid {
    var raw: [20]u8 = @splat(byte);
    raw[19] = byte +% 1;
    return Oid.fromRaw(.sha1, &raw) catch unreachable;
}

test "a table written is a table read, record for record" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var refs: std.ArrayList(RefRecord) = .empty;
    defer refs.deinit(gpa);
    // Enough refs for several blocks, an index and an object index.
    for (0..800) |i| {
        const name = try std.fmt.allocPrint(gpa, "refs/heads/branch-{d:0>4}", .{i});
        try names.append(gpa, name);
        try refs.append(gpa, .{
            .name = name,
            .update_index = 3 + i % 5,
            .value = switch (i % 4) {
                0 => .{ .direct = oidOf(@truncate(i)) },
                1 => .{ .peeled = .{ .value = oidOf(@truncate(i)), .target = oidOf(@truncate(i + 7)) } },
                2 => .{ .symbolic = "refs/heads/main" },
                else => .deletion,
            },
        });
    }
    const logs = [_]LogRecord{
        .{ .name = "HEAD", .update_index = 7, .value = .{ .update = .{
            .old = oidOf(1),
            .new = oidOf(2),
            .name = "A U Thor",
            .email = "author@example.com",
            .time = 1_700_000_000,
            .tz_offset = -130,
            .message = "commit: second\n",
        } } },
        .{ .name = "HEAD", .update_index = 3, .value = .deletion },
        .{ .name = "refs/heads/main", .update_index = 5, .value = .{ .update = .{
            .old = oidOf(0),
            .new = oidOf(1),
            .name = "A U Thor",
            .email = "author@example.com",
            .time = 1_600_000_000,
            .tz_offset = 200,
            .message = "branch: Created from HEAD\n",
        } } },
    };
    const bytes = try write(gpa, .sha1, .{}, 3, 7, refs.items, &logs);
    defer gpa.free(bytes);

    const table = try Table.parse(bytes, .sha1);
    try std.testing.expect(table.has_refs and table.has_logs and table.has_objs);
    try std.testing.expect(table.ref_index_offset != 0);
    try table.verify(gpa);

    var it = try table.iterate(gpa, .ref);
    defer it.deinit();
    var n: usize = 0;
    while (try it.nextRef()) |got| : (n += 1) {
        const want = refs.items[n];
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.update_index, got.update_index);
        try std.testing.expectEqual(std.meta.activeTag(want.value), std.meta.activeTag(got.value));
    }
    try std.testing.expectEqual(refs.items.len, n);

    // Every ref is found by a seek through the index.
    for (refs.items) |want| {
        var found = try table.seek(gpa, .ref, want.name);
        defer found.deinit();
        const got = (try found.nextRef()).?;
        try std.testing.expectEqualStrings(want.name, got.name);
    }
    var past = try table.seek(gpa, .ref, "refs/heads/zzz");
    defer past.deinit();
    try std.testing.expect(try past.nextRef() == null);

    var logs_it = try table.seek(gpa, .log, "HEAD");
    defer logs_it.deinit();
    const newest = (try logs_it.nextLog()).?;
    try std.testing.expectEqualStrings("HEAD", newest.name);
    try std.testing.expectEqual(@as(u64, 7), newest.update_index);
    try std.testing.expectEqual(@as(i16, -130), newest.value.update.tz_offset);
    try std.testing.expectEqualStrings("commit: second\n", newest.value.update.message);
    try std.testing.expect((try logs_it.nextLog()).?.value == .deletion);
    try std.testing.expectEqualStrings("refs/heads/main", (try logs_it.nextLog()).?.name);
    try std.testing.expect(try logs_it.nextLog() == null);
}

test "a table read from its file a block at a time reads what its bytes read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var refs: [300]RefRecord = undefined;
    var names: [300][32]u8 = undefined;
    for (&refs, 0..) |*r, i| {
        r.* = .{
            .name = try std.fmt.bufPrint(&names[i], "refs/tags/t{d:0>4}", .{i}),
            .update_index = 1,
            .value = if (i % 5 == 0) .{ .symbolic = "refs/heads/main" } else .{ .direct = oidOf(@truncate(i)) },
        };
    }
    const logs = [_]LogRecord{.{ .name = "HEAD", .update_index = 1, .value = .{ .update = .{
        .old = oidOf(1),
        .new = oidOf(2),
        .name = "A",
        .email = "a@example.com",
        .time = 1,
        .tz_offset = 0,
        .message = "m\n",
    } } }};
    const bytes = try write(gpa, .sha1, .{ .block_size = 512 }, 1, 1, &refs, &logs);
    defer gpa.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.ref", .data = bytes });
    const file = try tmp.dir.openFile(io, "t.ref", .{});
    defer file.close(io);

    const in_memory = try Table.parse(bytes, .sha1);
    const on_disk = try Table.open(io, file, .sha1);
    try on_disk.verify(gpa);
    try std.testing.expect(on_disk.ref_index_offset != 0);
    for (refs) |want| {
        var a = try in_memory.seek(gpa, .ref, want.name);
        defer a.deinit();
        var b = try on_disk.seek(gpa, .ref, want.name);
        defer b.deinit();
        const x = (try a.nextRef()).?;
        const y = (try b.nextRef()).?;
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(std.meta.activeTag(x.value), std.meta.activeTag(y.value));
    }
    var log_it = try on_disk.iterate(gpa, .log);
    defer log_it.deinit();
    try std.testing.expectEqualStrings("m\n", (try log_it.nextLog()).?.value.update.message);
}

test "an empty table is a header and a footer" {
    const gpa = std.testing.allocator;
    const bytes = try write(gpa, .sha1, .{}, 1, 1, &.{}, &.{});
    defer gpa.free(bytes);
    try std.testing.expectEqual(headerSize(1) + footerSize(1), bytes.len);
    const table = try Table.parse(bytes, .sha1);
    try std.testing.expect(!table.has_refs and !table.has_logs);
    var it = try table.iterate(gpa, .ref);
    defer it.deinit();
    try std.testing.expect(try it.nextRef() == null);

    const wide = try write(gpa, .sha256, .{}, 1, 1, &.{}, &.{});
    defer gpa.free(wide);
    try std.testing.expectEqual(headerSize(2) + footerSize(2), wide.len);
    _ = try Table.parse(wide, .sha256);
    try std.testing.expectError(error.HashMismatch, Table.parse(wide, .sha1));
}

test "records out of order are refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnsortedRecords, write(gpa, .sha1, .{}, 1, 1, &.{
        .{ .name = "refs/heads/b", .update_index = 1, .value = .deletion },
        .{ .name = "refs/heads/a", .update_index = 1, .value = .deletion },
    }, &.{}));
    try std.testing.expectError(error.UpdateIndexOutOfRange, write(gpa, .sha1, .{}, 2, 2, &.{
        .{ .name = "refs/heads/a", .update_index = 1, .value = .deletion },
    }, &.{}));
}

test "a damaged footer is a named error" {
    const gpa = std.testing.allocator;
    const bytes = try write(gpa, .sha1, .{}, 1, 1, &.{
        .{ .name = "HEAD", .update_index = 1, .value = .{ .symbolic = "refs/heads/main" } },
    }, &.{});
    defer gpa.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.FooterChecksumMismatch, Table.parse(bytes, .sha1));
    bytes[bytes.len - 1] ^= 1;
    bytes[0] = 'X';
    try std.testing.expectError(error.NotAReftable, Table.parse(bytes, .sha1));
}

test "fuzz: any bytes are a table or a named error, and every record reads or is refused" {
    try std.testing.fuzz({}, fuzzTable, .{});
}

/// A valid table with every section -- several small ref blocks, their
/// index, the object index, and logs -- for the fuzzer to damage. Made once
/// and kept for the process, from an allocator the leak check does not
/// watch.
var fuzz_base: ?[]u8 = null;

fn fuzzBase() ![]const u8 {
    if (fuzz_base) |bytes| return bytes;
    const gpa = std.heap.page_allocator;
    var refs: [60]RefRecord = undefined;
    var names: [60][32]u8 = undefined;
    for (&refs, 0..) |*r, i| {
        r.* = .{
            .name = try std.fmt.bufPrint(&names[i], "refs/heads/b{d:0>3}", .{i}),
            .update_index = 1 + i % 3,
            .value = switch (i % 4) {
                0 => .{ .direct = oidOf(@intCast(i)) },
                1 => .{ .peeled = .{ .value = oidOf(@intCast(i)), .target = oidOf(@intCast(i + 1)) } },
                2 => .{ .symbolic = "refs/heads/main" },
                else => .deletion,
            },
        };
    }
    const logs = [_]LogRecord{
        .{ .name = "HEAD", .update_index = 3, .value = .{ .update = .{
            .old = oidOf(1),
            .new = oidOf(2),
            .name = "A",
            .email = "a@example.com",
            .time = 1,
            .tz_offset = 100,
            .message = "m\n",
        } } },
        .{ .name = "HEAD", .update_index = 2, .value = .deletion },
    };
    fuzz_base = try write(gpa, .sha1, .{ .block_size = 256, .restart_interval = 4 }, 1, 3, &refs, &logs);
    return fuzz_base.?;
}

fn fuzzTable(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];

    // The input taken as a table, which is mostly refused at the door.
    try readEverything(input);

    // And a valid table with the input's bytes laid over it as damage --
    // pairs of a position and a value -- which reaches every block and
    // every record the door would otherwise keep the fuzzer from.
    const base = try fuzzBase();
    var damaged: [8192]u8 = undefined;
    if (base.len > damaged.len) return;
    const bytes = damaged[0..base.len];
    @memcpy(bytes, base);
    var i: usize = 0;
    while (i + 2 < input.len) : (i += 3) {
        const at = std.mem.readInt(u16, input[i..][0..2], .little) % bytes.len;
        bytes[at] ^= input[i + 2];
    }
    try readEverything(bytes);
}

fn readEverything(bytes: []const u8) !void {
    const gpa = std.testing.allocator;
    for ([_]Kind{ .sha1, .sha256 }) |kind| {
        const table = Table.parse(bytes, kind) catch continue;
        table.verify(gpa) catch {};
        inline for (.{ BlockType.ref, BlockType.log }) |typ| {
            if (table.iterate(gpa, typ)) |it_value| {
                var it = it_value;
                defer it.deinit();
                var steps: usize = 0;
                while (steps < 10_000) : (steps += 1) {
                    const next = (if (typ == .ref) (it.nextRef() catch break) else (it.nextLog() catch break));
                    if (next == null) break;
                }
            } else |_| {}
            for ([_][]const u8{ "", "HEAD", "refs/heads/b030", "zzz" }) |key| {
                if (table.seek(gpa, typ, key)) |it_value| {
                    var it = it_value;
                    defer it.deinit();
                    _ = (if (typ == .ref) (it.nextRef() catch null) else (it.nextLog() catch null));
                } else |_| {}
            }
        }
    }
}

test "the fuzzer's base table reads back whole" {
    const base = try fuzzBase();
    const table = try Table.parse(base, .sha1);
    try table.verify(std.testing.allocator);
    try std.testing.expect(table.ref_index_offset != 0 and table.has_objs and table.has_logs);
}

test "a table git wrote is read record for record, and written back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try testgit.requireGitVersion(gpa, io, 2, 45);
    var repo = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.writeFile(io, "a.txt", "b\n");
    try repo.exec(io, &.{ "commit", "-q", "-am", "two" });
    const head = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const parent = try repo.line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(parent);
    for (0..10) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "annotated-{d}", .{i});
        try repo.exec(io, &.{ "tag", "-a", "-m", "a tag", name, if (i % 2 == 0) head else parent });
    }
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    for (0..700) |i| {
        try script.print(gpa, "create refs/heads/topic/{d:0>4} {s}\n", .{ i, if (i % 3 == 0) parent else head });
    }
    for (0..40) |i| try script.print(gpa, "create refs/tags/light-{d:0>3} {s}\n", .{ i, head });
    try repo.writeFile(io, "script", script.items);
    const script_text = try repo.readFile(io, "script");
    defer gpa.free(script_text);
    try repo.exec(io, &.{ "symbolic-ref", "refs/heads/alias", "refs/heads/main" });
    try runWithInput(&repo, io, &.{ "update-ref", "--stdin", "-m", "bulk" }, script_text);
    try repo.exec(io, &.{ "update-ref", "-d", "refs/heads/topic/0005" });
    try repo.exec(io, &.{"pack-refs"});

    const list = try repo.readFile(io, ".git/reftable/tables.list");
    defer gpa.free(list);
    const table_name = std.mem.trimEnd(u8, list, "\n");
    try std.testing.expect(std.mem.indexOfScalar(u8, table_name, '\n') == null);
    var path_buf: [128]u8 = undefined;
    const bytes = try repo.readFile(io, try std.fmt.bufPrint(&path_buf, ".git/reftable/{s}", .{table_name}));
    defer gpa.free(bytes);

    const table = try Table.parse(bytes, .sha1);
    try table.verify(gpa);
    try std.testing.expect(table.ref_index_offset != 0);
    try std.testing.expect(table.has_objs);

    // Every ref git lists, in git's order, with git's values.
    const shown = try repo.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname) %(symref)" });
    defer gpa.free(shown);
    var refs: std.ArrayList(RefRecord) = .empty;
    defer refs.deinit(gpa);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    {
        var it = try table.iterate(gpa, .ref);
        defer it.deinit();
        while (try it.nextRef()) |ref| {
            const name = try gpa.dupe(u8, ref.name);
            try names.append(gpa, name);
            var copy = ref;
            copy.name = name;
            if (ref.value == .symbolic) {
                const target = try gpa.dupe(u8, ref.value.symbolic);
                try names.append(gpa, target);
                copy.value = .{ .symbolic = target };
            }
            try refs.append(gpa, copy);
        }
    }
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, shown, "\n"), '\n');
    var listed: usize = 0;
    for (refs.items) |ref| {
        if (ref.value == .deletion) continue;
        if (!std.mem.startsWith(u8, ref.name, "refs/")) continue;
        const line = lines.next().?;
        var parts = std.mem.splitScalar(u8, line, ' ');
        try std.testing.expectEqualStrings(parts.next().?, ref.name);
        const oid_text = parts.next().?;
        var hex: [hash.max_hex_len]u8 = undefined;
        switch (ref.value) {
            .direct => |oid| try std.testing.expectEqualStrings(oid_text, oid.hex(&hex)),
            .peeled => |p| try std.testing.expectEqualStrings(oid_text, p.value.hex(&hex)),
            .symbolic => |target| try std.testing.expectEqualStrings(parts.next().?, target),
            .deletion => unreachable,
        }
        listed += 1;
    }
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(listed > 700);

    var logs: std.ArrayList(LogRecord) = .empty;
    defer logs.deinit(gpa);
    var log_bytes: std.ArrayList(u8) = .empty;
    defer log_bytes.deinit(gpa);
    {
        var it = try table.iterate(gpa, .log);
        defer it.deinit();
        while (try it.nextLog()) |log| {
            const name = try gpa.dupe(u8, log.name);
            try names.append(gpa, name);
            var copy = log;
            copy.name = name;
            if (log.value == .update) {
                const u = log.value.update;
                const strings = try std.mem.concat(gpa, u8, &.{ u.name, u.email, u.message });
                try names.append(gpa, strings);
                copy.value.update.name = strings[0..u.name.len];
                copy.value.update.email = strings[u.name.len..][0..u.email.len];
                copy.value.update.message = strings[u.name.len + u.email.len ..];
            }
            try logs.append(gpa, copy);
        }
    }
    try std.testing.expect(logs.items.len > 700);

    // Written again from the same records, the table is git's table up to
    // the logs, and the logs inflate to git's.
    const ours = try write(gpa, .sha1, .{}, table.min_update_index, table.max_update_index, refs.items, logs.items);
    defer gpa.free(ours);
    const mine = try Table.parse(ours, .sha1);
    try std.testing.expectEqual(table.log_offset, mine.log_offset);
    try std.testing.expectEqualSlices(u8, bytes[0..@intCast(table.log_offset)], ours[0..@intCast(mine.log_offset)]);
    try expectSameLogBlocks(gpa, &table, &mine);
    const footer_head = footerSize(1) - 12;
    try std.testing.expectEqualSlices(u8, bytes[table.size..][0 .. footer_head - 8], ours[mine.size..][0 .. footer_head - 8]);
}

/// The log blocks of two tables, block for block, inflated.
fn expectSameLogBlocks(gpa: Allocator, a: *const Table, b: *const Table) !void {
    var at_a = a.log_offset;
    var at_b = b.log_offset;
    var blocks: usize = 0;
    while (true) : (blocks += 1) {
        var block_a = (try a.loadBlock(gpa, at_a)) orelse break;
        defer block_a.deinit(gpa);
        var block_b = (try b.loadBlock(gpa, at_b)) orelse return error.TestUnexpectedResult;
        defer block_b.deinit(gpa);
        if (block_a.typ != 'g') {
            try std.testing.expect(block_b.typ != 'g');
            break;
        }
        try std.testing.expectEqualSlices(u8, block_a.data, block_b.data);
        at_a += block_a.full_size;
        at_b += block_b.full_size;
    }
    try std.testing.expect(blocks > 1);
}

/// Run git with `input` on its standard input.
fn runWithInput(repo: *testgit.Repo, io: Io, args: []const []const u8, input: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(repo.gpa);
    try argv.append(repo.gpa, "git");
    try argv.appendSlice(repo.gpa, repo.defaults);
    try argv.appendSlice(repo.gpa, args);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = repo.dir },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    {
        var buf: [4096]u8 = undefined;
        var w = child.stdin.?.writer(io, &buf);
        try w.interface.writeAll(input);
        try w.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}
