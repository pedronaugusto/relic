//! The pack layer's input seam: where the bytes of a pack, of its `.idx`
//! and of an object a pack writer takes in enter `pack.zig`, each read held
//! to a limit named here. They are read here and nowhere else in it; what
//! reads the bytes these hand back parses them as the untrusted input they
//! are, a pack or an index being a file anyone could have written.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A pack index read whole: at most `max_bytes` (`Index.OpenOptions`'s),
/// a longer one `error.StreamTooLong`, the bytes the caller's.
pub fn indexFile(io: Io, dir: Io.Dir, sub_path: []const u8, gpa: Allocator, max_bytes: usize) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, sub_path, gpa, aegis.units.Bytes(u64).fromRaw(max_bytes));
}

/// `file`'s bytes from `offset` into `dest`, at most `dest.len` of them:
/// how many were read, fewer only where the file ends first.
pub fn readAt(io: Io, file: Io.File, offset: u64, dest: []u8) Io.File.ReadPositionalError!usize {
    var done: usize = 0;
    while (done < dest.len) {
        // No file reaches past the last offset a u64 holds.
        const at = std.math.add(u64, offset, done) catch return done;
        const n = try file.readPositional(io, &.{dest[done..]}, at);
        if (n == 0) return done;
        done += n;
    }
    return done;
}

/// A reader over `file` from `at`, each of its reads at most `buffer.len`
/// bytes. It reads positionally, falling back to streaming where the file
/// cannot be read so, as std's reader does.
pub fn readerAt(io: Io, file: Io.File, buffer: []u8, at: u64) Io.File.Reader {
    var reader = file.reader(io, buffer);
    // A reader made now holds nothing yet, so its position is where its
    // first read lands.
    reader.pos = at;
    return reader;
}

/// `file`'s first `len` bytes mapped and read in, or `null` where the
/// platform or the file gives no map: a pack opened for `Access.map` is read
/// positionally then, as `Access` promises. A cancel is no refusal to map,
/// and is returned.
pub fn map(io: Io, file: Io.File, len: usize) Io.Cancelable!?Io.File.MemoryMap {
    var mapping = Io.File.MemoryMap.create(io, file, .{
        .len = len,
        .protection = .{ .read = true, .write = false },
        .populate = false,
    }) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => null,
    };
    mapping.read(io) catch |err| {
        mapping.destroy(io);
        return switch (err) {
            error.Canceled => error.Canceled,
            else => null,
        };
    };
    return mapping;
}

/// Exactly `dest.len` bytes of `in`.
pub fn exactly(in: *Io.Reader, dest: []u8) Io.Reader.Error!void {
    return in.readSliceAll(dest);
}

/// Whether `in` has nothing more to give.
pub fn ended(in: *Io.Reader) error{ReadFailed}!bool {
    _ = in.peekByte() catch |err| return switch (err) {
        error.EndOfStream => true,
        error.ReadFailed => error.ReadFailed,
    };
    return false;
}

/// At least one byte of `in` and at most `max`, taken from it: they stay
/// good until `in` is next read.
pub fn some(in: *Io.Reader, max: u64) Io.Reader.Error![]const u8 {
    const piece = try in.peekGreedy(1);
    const n = @min(piece.len, std.math.cast(usize, max) orelse piece.len);
    in.toss(n);
    return piece[0..n];
}

/// The unit a positional pack read is made in. Every read of a block starts
/// at a multiple of this many bytes into the file and covers one block, so
/// where a read lands depends on the bytes wanted and never on the reads
/// before it.
pub const read_block_bytes = 8 * 1024;

/// Room in front of each block for the few bytes a decoder had not taken
/// from the block before it, so that the two read as one run.
const block_prefix = 64;
/// One slot: the prefix, the block, and one byte past it, so that a reader
/// at the end of a whole block always asks for the next one rather than for
/// room in this one.
pub const block_stride = block_prefix + read_block_bytes + 1;
const no_block = std.math.maxInt(u64);

/// One slot of a pack's block cache: the block it holds and that block's
/// length, and its `block_stride` bytes, allocated when it is first filled.
pub const Slot = struct {
    id: u64 = no_block,
    len: u32 = 0,
    bytes: ?*[block_stride]u8 = null,
};

/// The blocks a pack's positional reads keep, direct-mapped: block `b` of
/// the file can only be in slot `b % slots`, and there are never more slots
/// than the file has blocks. A slot's `block_stride` bytes are allocated
/// when it is first filled, so a pack holds what of it was read, up to
/// `slots` blocks; the table of slots is allocated on the first read. Each
/// read is one block, the most any read here takes.
pub const Blocks = struct {
    gpa: Allocator,
    /// The pack file, which the pack owns and closes.
    file: aegis.own.Unowned(Io.File),
    /// The pack's length.
    size: u64,
    slots: usize,
    table: []Slot = &.{},
    /// The reader an entry is inflated through: it walks the blocks.
    reader: Io.Reader = undefined,
    /// The Io and block of the read in progress through `reader`.
    reader_io: Io = undefined,
    reader_block: u64 = 0,
    /// Why the reader in progress failed, when it says `ReadFailed`.
    err: ?Error = null,

    /// Why a block was not read.
    pub const Error = error{
        /// The block is past the end of the pack, or ends early.
        TruncatedPack,
        /// A decoder held back more of a block than the next one has room
        /// in front of it for: no zlib stream asks that.
        CorruptPackEntry,
    } || Allocator.Error || Io.File.ReadPositionalError;

    /// Blocks of `file`, `size` bytes long, keeping up to `cache_bytes` of
    /// it, at least one block and never more blocks than it has.
    pub fn init(gpa: Allocator, file: Io.File, size: u64, cache_bytes: usize) Blocks {
        const file_blocks = size / read_block_bytes + @intFromBool(size % read_block_bytes != 0);
        const kept = @max(1, @min(cache_bytes / read_block_bytes, file_blocks));
        return .{
            .gpa = gpa,
            .file = .of(file),
            .size = size,
            // At most `cache_bytes / read_block_bytes`, which is a usize.
            .slots = std.math.cast(usize, kept) orelse aegis.assert.never("the slots are at most a usize's quotient"),
        };
    }

    /// Release the blocks held.
    pub fn deinit(b: *Blocks) void {
        for (b.table) |slot| if (slot.bytes) |bytes| b.gpa.destroy(bytes);
        if (b.table.len != 0) b.gpa.free(b.table);
        b.* = undefined;
    }

    /// The slot block `id` is in, read from the file if it is not there.
    ///
    /// A read is exactly one block, so what it costs depends only on which
    /// block is wanted, and a slot only ever changes to the block wanted.
    /// That is what makes the cache monotone: a sequence of reads that is
    /// part of another, block for block, never costs more than it.
    fn load(b: *Blocks, io: Io, id: u64) Error!*Slot {
        if (b.table.len == 0) {
            const table = try b.gpa.alloc(Slot, b.slots);
            @memset(table, .{});
            b.table = table;
        }
        const rem = std.math.rem(u64, id, b.table.len) catch return error.TruncatedPack;
        const at = std.math.cast(usize, rem) orelse return error.TruncatedPack;
        if (at >= b.table.len) return error.TruncatedPack;
        const slot = &b.table[at];
        if (slot.id == id) return slot;
        const start: u64 = std.math.mul(u64, id, read_block_bytes) catch return error.TruncatedPack;
        if (start >= b.size) return error.TruncatedPack;
        const len: u32 = @intCast(@min(read_block_bytes, b.size - start));
        if (slot.bytes == null) slot.bytes = try b.gpa.create([block_stride]u8);
        // Claimed only once read whole: a failure leaves the slot empty.
        slot.id = no_block;
        const dest = slot.bytes.?[block_prefix..][0..len];
        if (try readAt(io, b.file.get(), start, dest) != len) return error.TruncatedPack;
        slot.id = id;
        slot.len = len;
        return slot;
    }

    /// The pack's bytes from `offset` to the end of the block it is in.
    pub fn bytesAt(b: *Blocks, io: Io, offset: u64) Error![]const u8 {
        const slot = try b.load(io, offset / read_block_bytes);
        const block = slot.bytes.?[block_prefix..][0..slot.len];
        const from: usize = @intCast(offset % read_block_bytes);
        if (from > block.len) return error.TruncatedPack;
        return block[from..];
    }

    const vtable: Io.Reader.VTable = .{
        .stream = stream,
        .readVec = readVec,
        .rebase = rebase,
    };

    /// A reader over the pack from `at`, through the blocks.
    pub fn readerAt(b: *Blocks, io: Io, at: u64) Error!*Io.Reader {
        const id = at / read_block_bytes;
        const slot = try b.load(io, id);
        b.reader_io = io;
        b.reader_block = id;
        b.err = null;
        const within: usize = @intCast(at % read_block_bytes);
        b.reader = .{
            .vtable = &vtable,
            .buffer = slot.bytes.?,
            .seek = block_prefix + within,
            .end = block_prefix + slot.len,
        };
        return &b.reader;
    }

    /// Move the reader on to the next block. What the reader had not taken
    /// from this one — never more than a decoder asks for at once — goes in
    /// front of the next block, in that slot's prefix, so the two read as
    /// one run; neither block's own bytes move.
    fn next(r: *Io.Reader) Io.Reader.Error!void {
        const b: *Blocks = @alignCast(@fieldParentPtr("reader", r)); // installed only on a Blocks' reader
        const next_block = std.math.add(u64, b.reader_block, 1) catch return error.EndOfStream;
        const next_at = std.math.mul(u64, next_block, read_block_bytes) catch return error.EndOfStream;
        if (next_at >= b.size) return error.EndOfStream;
        const kept = r.buffered();
        if (kept.len > block_prefix) {
            b.err = error.CorruptPackEntry;
            return error.ReadFailed;
        }
        var carry: [block_prefix]u8 = undefined;
        @memcpy(carry[0..kept.len], kept);
        const slot = b.load(b.reader_io, next_block) catch |err| {
            b.err = err;
            return error.ReadFailed;
        };
        // The bytes not taken end where the block's own begin.
        const seek = block_prefix - kept.len;
        @memcpy(slot.bytes.?[seek..block_prefix], carry[0..kept.len]);
        r.buffer = slot.bytes.?;
        r.seek = seek;
        r.end = block_prefix + slot.len;
        b.reader_block = next_block;
    }

    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        _ = data;
        try next(r);
        return 0;
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        try next(r);
        return 0;
    }

    fn rebase(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        if (r.seek <= r.buffer.len and r.buffer.len - r.seek >= capacity) return;
        try next(r);
    }
};

test "a read past the end of a file gives what the file holds, and a reader starts where it is told" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pack", .data = "PACKbytes" });
    const file = try tmp.dir.openFile(io, "pack", .{});
    defer file.close(io);
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try readAt(io, file, 4, &out));
    try std.testing.expectEqualStrings("bytes", out[0..5]);
    try std.testing.expectEqual(@as(usize, 0), try readAt(io, file, 100, &out));
    var buffer: [4]u8 = undefined;
    var reader = readerAt(io, file, &buffer, 4);
    var got: [5]u8 = undefined;
    try exactly(&reader.interface, &got);
    try std.testing.expectEqualStrings("bytes", &got);
    try std.testing.expect(try ended(&reader.interface));
}
