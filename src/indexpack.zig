//! Receiving a pack: what `git index-pack --stdin --fix-thin` does.
//!
//! A fetch ends with a pack arriving on a stream, written by the other side
//! and trusted by nobody. It is copied into `objects/pack` under a temporary
//! name while its trailing checksum is taken; then every entry is read in
//! order, each whole object named as it is inflated, each delta's extent
//! found; then the deltas are resolved against their bases — an offset delta
//! against the entry that many bytes before it, a reference delta against the
//! object with that name — one chain at a time, so what is held is the chain
//! and not the pack. A reference delta whose base the pack does not carry is
//! a thin pack, and the base is read from the object database and appended to
//! the pack as a whole object, with the header's count and the trailing
//! checksum rewritten to match, which is what makes the pack stand on its
//! own. The index is written last, byte for byte the one `git index-pack`
//! writes for the same pack, and the two files are renamed into place pack
//! first, as git renames them.
//!
//! Every commit, tree and tag is checked the way git's `fsck` checks one
//! before it is kept, and a malformed one is refused by name. A stream that
//! is not a pack, or stops short, or carries a delta that reaches outside
//! itself, is a named error and leaves nothing behind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

const hash = @import("hash.zig");
const object = @import("object.zig");
const pack = @import("pack.zig");
const delta = @import("delta.zig");
const fs = @import("fs.zig");
const odb_mod = @import("odb.zig");
const fsck = @import("fsck.zig");
const progress_mod = @import("progress.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;
const Progress = progress_mod.Progress;

/// Errors from receiving a pack.
pub const Error = error{
    /// The stream does not begin `PACK`.
    NotAPack,
    /// A pack version other than 2 or 3.
    UnsupportedPackVersion,
    /// The stream ended inside the header, an entry, or the trailer.
    TruncatedPack,
    /// Bytes after the last entry and before the trailer.
    PackTrailingGarbage,
    /// A type field of 0 or 5, which git reserves and never writes.
    InvalidPackEntryType,
    /// An offset delta that points before the pack's header or at no
    /// entry's beginning.
    BadDeltaOffset,
    /// A reference delta whose base is neither in the pack nor, for a thin
    /// pack, in the object database. `Diagnostic.oid` names the base.
    DeltaBaseMissing,
    /// A chain deeper than `Options.max_delta_depth`.
    DeltaChainTooDeep,
    /// An entry inflated to a length other than the one its header states.
    PackEntrySizeMismatch,
    /// An entry's zlib stream did not inflate.
    CorruptPackEntry,
    /// The trailing checksum is not the hash of what came before it.
    PackChecksumMismatch,
    /// One object twice. An index's names must rise, so a pack carrying a
    /// name twice cannot be indexed. `Diagnostic.oid` names it.
    DuplicateObject,
    /// An object past `Options.max_object_bytes`.
    ObjectTooLarge,
    /// A stream past `Options.max_pack_bytes`.
    PackTooLarge,
    /// A SHA-1 name taken over bytes carrying the signature of a collision
    /// attack, from a database that asks for the check.
    CollisionAttack,
    /// A commit git's `fsck` refuses. `Diagnostic` names the object and
    /// the problem.
    MalformedCommit,
    /// A tree git's `fsck` refuses.
    MalformedTree,
    /// A tag git's `fsck` refuses.
    MalformedTag,
    /// The stream being read failed; its own reader says why.
    ReadFailed,
} || delta.Error || odb_mod.Error || Io.File.Reader.Error || Io.File.SetLengthError;

/// How a pack is received.
pub const Options = struct {
    /// Complete a thin pack from the object database. Off, a reference
    /// delta whose base is not in the pack is `error.DeltaBaseMissing`.
    fix_thin: bool = true,
    /// Check every commit, tree and tag with `fsck.check`.
    check_objects: bool = true,
    /// How hard the pack and its index are pushed to the disk before they
    /// are renamed into place.
    sync: fs.Sync = .none,
    /// The most bytes the stream may carry, or `null` for no bound.
    max_pack_bytes: ?u64 = null,
    /// The largest object, or delta, held in memory.
    max_object_bytes: u64 = 1 << 31,
    /// How deep a delta chain may go.
    max_delta_depth: u32 = pack.default_max_depth,
    progress: ?Progress = null,
    /// Where the object behind a refusal is named, when the caller wants it.
    diagnostic: ?*Diagnostic = null,
};

/// What went wrong, and where, for a message.
pub const Diagnostic = struct {
    /// The object refused, or the base that was missing, when there is one.
    oid: ?Oid = null,
    /// What git's `fsck` calls the problem, for a malformed object.
    problem: ?fsck.Problem = null,
    /// Where in the pack the entry begins.
    offset: ?u64 = null,
};

/// What was received.
pub const Result = struct {
    /// The pack's checksum, which names both files: `pack-<name>.pack` and
    /// `pack-<name>.idx`. `null` when the pack held no objects, in which
    /// case nothing is kept.
    name: ?Oid,
    /// How many objects the kept pack holds, appended bases included.
    objects: u32,
    /// How many arrived as deltas.
    deltas: u32,
    /// How many bases a thin pack named and did not carry, appended from the
    /// object database.
    appended: u32,
};

const EntryKind = enum(u2) { whole, ofs_delta, ref_delta };

const Entry = struct {
    offset: u64,
    /// Where the zlib stream begins.
    data_at: u64,
    /// The inflated length: the object's, or the delta's.
    size: u64,
    /// The offset of the base, for an offset delta.
    base_offset: u64 = 0,
    oid: Oid,
    crc: u32 = 0,
    kind: EntryKind,
    /// The object's type; for a delta, its base's, once resolved.
    type: object.Type = .blob,
    resolved: bool = false,
};

/// A reference delta and the name of its base.
const RefBase = struct {
    child: u32,
    base: Oid,

    fn lessThan(_: void, a: RefBase, b: RefBase) bool {
        return a.base.order(b.base) == .lt;
    }
};

/// An offset delta and the entry its base is.
const OfsBase = struct {
    child: u32,
    base: u32,

    fn lessThan(_: void, a: OfsBase, b: OfsBase) bool {
        return a.base < b.base;
    }
};

/// Read a pack from `in` into `pack_dir`, which is `db`'s `objects/pack`,
/// and refresh `db` so it reads the new pack.
///
/// `db` is where a thin pack's missing bases are read from and where the
/// received objects' names are checked for a collision attack when it asks
/// for that. On any error nothing is left in `pack_dir`.
pub fn receive(
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    pack_dir: Io.Dir,
    in: *Io.Reader,
    options: Options,
) Error!Result {
    const kind = db.kind;
    const raw_len = kind.rawLen();

    var temp_buf: [64]u8 = undefined;
    const temp = fs.tempName(io, &temp_buf, "tmp_pack_");
    const file = try pack_dir.createFile(io, temp, .{ .exclusive = true, .read = true });
    var file_open = true;
    var kept = false;
    defer {
        if (file_open) file.close(io);
        if (!kept) pack_dir.deleteFile(io, temp) catch {};
    }

    const copied = try copyIn(io, file, in, kind, options);
    if (copied.size < 12 + raw_len) return error.TruncatedPack;
    var header: [12]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return error.TruncatedPack;
    if (!std.mem.eql(u8, header[0..4], "PACK")) return error.NotAPack;
    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version != 2 and version != 3) return error.UnsupportedPackVersion;
    const count = std.mem.readInt(u32, header[8..12], .big);
    const trailer = Oid.fromRaw(kind, copied.tail[0..raw_len]) catch unreachable;
    if (!trailer.eql(copied.checksum)) return error.PackChecksumMismatch;
    const body_end = copied.size - raw_len;

    if (count == 0) {
        if (body_end != 12) return error.PackTrailingGarbage;
        return .{ .name = null, .objects = 0, .deltas = 0, .appended = 0 };
    }

    var indexer: Indexer = try .init(gpa, io, db, file, options);
    defer indexer.deinit();
    try indexer.parse(count, body_end);
    try indexer.resolve();

    var name = trailer;
    var appended: u32 = 0;
    if (indexer.thin_bases.items.len != 0) {
        name = try indexer.appendBases(body_end, count);
        appended = @intCast(indexer.thin_bases.items.len);
    }

    // Every name once: the index cannot hold one twice.
    const index_entries = try gpa.alloc(pack.IndexEntry, indexer.entries.items.len);
    defer gpa.free(index_entries);
    for (indexer.entries.items, index_entries) |entry, *out| {
        out.* = .{ .oid = entry.oid, .offset = entry.offset, .crc = entry.crc };
    }
    std.mem.sort(pack.IndexEntry, index_entries, {}, struct {
        fn lessThan(_: void, a: pack.IndexEntry, b: pack.IndexEntry) bool {
            return a.oid.order(b.oid) == .lt;
        }
    }.lessThan);
    for (index_entries[1..], 0..) |entry, i| {
        if (entry.oid.eql(index_entries[i].oid)) {
            if (options.diagnostic) |d| d.* = .{ .oid = entry.oid };
            return error.DuplicateObject;
        }
    }

    switch (options.sync) {
        .none => {},
        .batch, .per_file => try file.sync(io),
    }
    file.close(io);
    file_open = false;

    var hex: [hash.max_hex_len]u8 = undefined;
    const text = name.hex(&hex);
    var pack_name_buf: [96]u8 = undefined;
    const pack_name = std.fmt.bufPrint(&pack_name_buf, "pack-{s}.pack", .{text}) catch unreachable;
    var idx_name_buf: [96]u8 = undefined;
    const idx_name = std.fmt.bufPrint(&idx_name_buf, "pack-{s}.idx", .{text}) catch unreachable;

    const result: Result = .{
        .name = name,
        .objects = @intCast(index_entries.len),
        .deltas = indexer.deltas,
        .appended = appended,
    };

    // The same pack received twice has the same name, and the one already
    // there is the one a reader may have open.
    if (pack_dir.access(io, idx_name, .{})) |_| {
        return result;
    } else |_| {}

    var idx_temp_buf: [64]u8 = undefined;
    const idx_temp = fs.tempName(io, &idx_temp_buf, "tmp_idx_");
    _ = try pack.writeIndexFile(gpa, io, pack_dir, idx_temp, kind, index_entries, name, options.sync);
    errdefer pack_dir.deleteFile(io, idx_temp) catch {};

    // Pack first, index second: a reader finds a pack by its index.
    try fs.renameWithRetry(io, pack_dir, temp, pack_name);
    kept = true;
    fs.renameWithRetry(io, pack_dir, idx_temp, idx_name) catch |err| {
        pack_dir.deleteFile(io, pack_name) catch {};
        return err;
    };
    if (options.sync == .batch) try fs.syncBarrier(io, pack_dir);
    try db.refresh(io);
    return result;
}

const Copied = struct {
    size: u64,
    /// The hash of everything but the last `rawLen` bytes.
    checksum: Oid,
    /// The last `rawLen` bytes, which should be that hash.
    tail: [hash.max_raw_len]u8,
};

/// Copy the stream into the temporary, hashing everything but its last
/// `rawLen` bytes as it goes — which bytes those are is only known at the
/// end, so a window of that many is held back from the hash.
fn copyIn(io: Io, file: Io.File, in: *Io.Reader, kind: Kind, options: Options) Error!Copied {
    const raw_len = kind.rawLen();
    var buffer: [64 * 1024]u8 = undefined;
    var hasher: hash.Hasher = .init(kind);
    var tail: [hash.max_raw_len]u8 = undefined;
    var tail_len: usize = 0;
    var total: u64 = 0;
    while (true) {
        const n = in.readSliceShort(&buffer) catch return error.ReadFailed;
        if (n == 0) break;
        const chunk = buffer[0..n];
        try file.writePositionalAll(io, chunk, total);
        total += n;
        if (options.max_pack_bytes) |most| {
            if (total > most) return error.PackTooLarge;
        }
        const held = tail_len + n;
        if (held <= raw_len) {
            @memcpy(tail[tail_len..][0..n], chunk);
            tail_len = held;
        } else {
            const release = held - raw_len;
            if (release <= tail_len) {
                hasher.update(tail[0..release]);
                std.mem.copyForwards(u8, tail[0 .. tail_len - release], tail[release..tail_len]);
                tail_len -= release;
                @memcpy(tail[tail_len..][0..n], chunk);
                tail_len += n;
            } else {
                hasher.update(tail[0..tail_len]);
                hasher.update(chunk[0 .. release - tail_len]);
                @memcpy(tail[0..raw_len], chunk[n - raw_len ..]);
                tail_len = raw_len;
            }
        }
        Progress.emit(options.progress, .{ .received = total });
        if (n < buffer.len) break;
    }
    return .{ .size = total, .checksum = hasher.final(), .tail = tail };
}

/// The state of one receive after the copy: the entries, and the file they
/// are read back from.
const Indexer = struct {
    gpa: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    kind: Kind,
    file: Io.File,
    options: Options,
    read_buffer: []u8,
    window: []u8,
    reader: Io.File.Reader,
    entries: std.ArrayList(Entry) = .empty,
    ofs_bases: std.ArrayList(OfsBase) = .empty,
    ref_bases: std.ArrayList(RefBase) = .empty,
    /// Bases a thin pack named and the database supplied, in the order they
    /// are appended.
    thin_bases: std.ArrayList(Oid) = .empty,
    deltas: u32 = 0,
    resolved_count: u64 = 0,

    fn init(gpa: Allocator, io: Io, db: *odb_mod.Odb, file: Io.File, options: Options) Allocator.Error!Indexer {
        const read_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(read_buffer);
        const window = try gpa.alloc(u8, flate.max_window_len);
        return .{
            .gpa = gpa,
            .io = io,
            .db = db,
            .kind = db.kind,
            .file = file,
            .options = options,
            .read_buffer = read_buffer,
            .window = window,
            .reader = file.reader(io, read_buffer),
        };
    }

    fn deinit(x: *Indexer) void {
        x.entries.deinit(x.gpa);
        x.ofs_bases.deinit(x.gpa);
        x.ref_bases.deinit(x.gpa);
        x.thin_bases.deinit(x.gpa);
        x.gpa.free(x.read_buffer);
        x.gpa.free(x.window);
        x.* = undefined;
    }

    fn fail(x: *Indexer, err: Error, diagnostic: Diagnostic) Error {
        if (x.options.diagnostic) |d| d.* = diagnostic;
        return err;
    }

    fn seek(x: *Indexer, offset: u64) Error!void {
        x.reader.seekTo(offset) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedPack,
            error.ReadFailed => return x.reader.err orelse error.ReadFailed,
            else => return error.TruncatedPack,
        };
    }

    fn takeByte(x: *Indexer) Error!u8 {
        return x.reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => error.TruncatedPack,
            error.ReadFailed => x.reader.err orelse error.ReadFailed,
        };
    }

    /// Read every entry in order: its header, and its zlib stream to the
    /// end so the next one's offset is known. Whole objects are named here.
    fn parse(x: *Indexer, count: u32, body_end: u64) Error!void {
        const gpa = x.gpa;
        // An entry is at least a header byte and a two-byte zlib header, so
        // a count larger than the body can hold is not believed for the
        // allocation.
        const plausible: usize = @intCast(@min(@as(u64, count), (body_end - 12) / 3 + 1));
        try x.entries.ensureTotalCapacity(gpa, plausible);
        try x.seek(12);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const offset = x.reader.logicalPos();
            if (offset >= body_end) return error.TruncatedPack;
            var entry = try x.readHeader(offset);
            entry.data_at = x.reader.logicalPos();
            switch (entry.kind) {
                .whole => try x.inflateWhole(&entry),
                .ofs_delta, .ref_delta => {
                    x.deltas += 1;
                    if (entry.size > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = offset });
                    try x.inflate(entry.size, .discard, null);
                },
            }
            const end = x.reader.logicalPos();
            if (end > body_end) return error.TruncatedPack;
            entry.crc = try x.crcOf(offset, end);
            try x.entries.append(gpa, entry);
            Progress.emit(x.options.progress, .{ .indexed = .{ .done = i + 1, .total = count } });
        }
        if (x.reader.logicalPos() != body_end) return error.PackTrailingGarbage;

        // Where each delta's base is.
        for (x.entries.items, 0..) |entry, at| {
            switch (entry.kind) {
                .whole => {},
                .ofs_delta => {
                    const base = x.entryAt(entry.base_offset) orelse
                        return x.fail(error.BadDeltaOffset, .{ .offset = entry.offset });
                    try x.ofs_bases.append(gpa, .{ .child = @intCast(at), .base = base });
                },
                .ref_delta => {},
            }
        }
        std.mem.sort(OfsBase, x.ofs_bases.items, {}, OfsBase.lessThan);
        std.mem.sort(RefBase, x.ref_bases.items, {}, RefBase.lessThan);
    }

    /// The entry beginning exactly at `offset`, by bisection: the entries
    /// are in the order they were read, which is offset order.
    fn entryAt(x: *const Indexer, offset: u64) ?u32 {
        var lo: usize = 0;
        var hi: usize = x.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = x.entries.items[mid].offset;
            if (at == offset) return @intCast(mid);
            if (at < offset) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn readHeader(x: *Indexer, offset: u64) Error!Entry {
        var byte = try x.takeByte();
        const type_bits: u3 = @truncate(byte >> 4);
        var size: u64 = byte & 0x0f;
        var shift: u6 = 4;
        while (byte & 0x80 != 0) {
            byte = try x.takeByte();
            if (shift > 57) return x.fail(error.CorruptPackEntry, .{ .offset = offset });
            size |= @as(u64, byte & 0x7f) << shift;
            shift += 7;
        }
        var entry: Entry = .{
            .offset = offset,
            .data_at = 0,
            .size = size,
            .oid = .zero(x.kind),
            .kind = .whole,
        };
        switch (type_bits) {
            1 => entry.type = .commit,
            2 => entry.type = .tree,
            3 => entry.type = .blob,
            4 => entry.type = .tag,
            6 => {
                // The biased offset varint: a different encoding from the
                // size varint a few bytes earlier in the same entry.
                byte = try x.takeByte();
                var back: u64 = byte & 0x7f;
                while (byte & 0x80 != 0) {
                    byte = try x.takeByte();
                    back = std.math.add(u64, back, 1) catch return x.fail(error.BadDeltaOffset, .{ .offset = offset });
                    if (back >> 57 != 0) return x.fail(error.BadDeltaOffset, .{ .offset = offset });
                    back = (back << 7) | (byte & 0x7f);
                }
                if (back == 0 or back > offset or offset - back < 12) return x.fail(error.BadDeltaOffset, .{ .offset = offset });
                entry.kind = .ofs_delta;
                entry.base_offset = offset - back;
            },
            7 => {
                var raw: [hash.max_raw_len]u8 = undefined;
                for (raw[0..x.kind.rawLen()]) |*b| b.* = try x.takeByte();
                entry.kind = .ref_delta;
                try x.ref_bases.append(x.gpa, .{
                    .child = @intCast(x.entries.items.len),
                    .base = Oid.fromRaw(x.kind, raw[0..x.kind.rawLen()]) catch unreachable,
                });
            },
            else => return x.fail(error.InvalidPackEntryType, .{ .offset = offset }),
        }
        return entry;
    }

    const Sink = union(enum) {
        discard,
        hash: *hash.Hasher,
        buffer: []u8,
    };

    /// Inflate the stream at the reader's position, which must yield
    /// exactly `size` bytes and then end.
    fn inflate(x: *Indexer, size: u64, sink: Sink, hasher: ?*hash.Hasher) Error!void {
        var d: flate.Decompress = .init(&x.reader.interface, .zlib, x.window);
        var chunk: [16 * 1024]u8 = undefined;
        var done: u64 = 0;
        while (true) {
            const remaining = size - done;
            const want: usize = @intCast(@min(@as(u64, chunk.len), remaining + 1));
            const n = d.reader.readSliceShort(chunk[0..want]) catch {
                if (x.reader.err) |err| return err;
                return if (d.err) |err| switch (err) {
                    error.EndOfStream => error.TruncatedPack,
                    else => error.CorruptPackEntry,
                } else error.CorruptPackEntry;
            };
            if (n > remaining) return error.PackEntrySizeMismatch;
            const got = chunk[0..n];
            switch (sink) {
                .discard => {},
                .hash => |h| h.update(got),
                .buffer => |out| @memcpy(out[@intCast(done)..][0..n], got),
            }
            if (hasher) |h| h.update(got);
            done += n;
            if (n < want) break;
        }
        if (done != size) return error.PackEntrySizeMismatch;
    }

    /// Name a whole object as it is inflated. A blob streams through the
    /// hash; a commit, tree or tag is held long enough to be checked.
    fn inflateWhole(x: *Indexer, entry: *Entry) Error!void {
        var hasher: hash.Hasher = .initOptions(x.kind, x.hashOptions());
        hasher.updateHeader(entry.type.name(), entry.size);
        if (entry.type == .blob or !x.options.check_objects) {
            try x.inflate(entry.size, .{ .hash = &hasher }, null);
            entry.oid = hasher.final();
        } else {
            if (entry.size > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = entry.offset });
            const bytes = try x.gpa.alloc(u8, @intCast(entry.size));
            defer x.gpa.free(bytes);
            try x.inflate(entry.size, .{ .buffer = bytes }, &hasher);
            entry.oid = hasher.final();
            try x.checkObject(entry.oid, entry.type, bytes, entry.offset);
        }
        if (hasher.collisionAttack()) return x.fail(error.CollisionAttack, .{ .oid = entry.oid, .offset = entry.offset });
        entry.resolved = true;
    }

    fn hashOptions(x: *const Indexer) hash.Hasher.Options {
        return .{ .detect_collisions = x.db.options.detect_sha1_collisions };
    }

    fn checkObject(x: *Indexer, oid: Oid, t: object.Type, bytes: []const u8, offset: u64) Error!void {
        if (!x.options.check_objects) return;
        const problem = fsck.check(x.kind, t, bytes) orelse return;
        const err: Error = switch (t) {
            .commit => error.MalformedCommit,
            .tree => error.MalformedTree,
            .tag => error.MalformedTag,
            .blob => unreachable,
        };
        return x.fail(err, .{ .oid = oid, .problem = problem, .offset = offset });
    }

    fn crcOf(x: *Indexer, start: u64, end: u64) Error!u32 {
        var crc: std.hash.Crc32 = .init();
        var buf: [16 * 1024]u8 = undefined;
        var at = start;
        while (at < end) {
            const want: usize = @intCast(@min(@as(u64, buf.len), end - at));
            const n = try x.file.readPositionalAll(x.io, buf[0..want], at);
            if (n == 0) return error.TruncatedPack;
            crc.update(buf[0..n]);
            at += n;
        }
        return crc.final();
    }

    /// The bytes of the entry at `at`, inflated. For a delta, the delta.
    fn load(x: *Indexer, at: u32) Error![]u8 {
        const entry = x.entries.items[at];
        if (entry.size > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = entry.offset });
        const bytes = try x.gpa.alloc(u8, @intCast(entry.size));
        errdefer x.gpa.free(bytes);
        try x.seek(entry.data_at);
        try x.inflate(entry.size, .{ .buffer = bytes }, null);
        return bytes;
    }

    /// The range of `ofs_bases` whose base is `base`.
    fn ofsChildren(x: *const Indexer, base: u32) []const OfsBase {
        const items = x.ofs_bases.items;
        const lo = lowerBound(OfsBase, items, base, struct {
            fn before(item: OfsBase, key: u32) bool {
                return item.base < key;
            }
        }.before);
        var hi = lo;
        while (hi < items.len and items[hi].base == base) hi += 1;
        return items[lo..hi];
    }

    /// The range of `ref_bases` whose base is named `oid`.
    fn refChildren(x: *const Indexer, oid: Oid) []const RefBase {
        const items = x.ref_bases.items;
        const lo = lowerBound(RefBase, items, oid, struct {
            fn before(item: RefBase, key: Oid) bool {
                return item.base.order(key) == .lt;
            }
        }.before);
        var hi = lo;
        while (hi < items.len and items[hi].base.eql(oid)) hi += 1;
        return items[lo..hi];
    }

    /// One object on the chain being resolved: its bytes, and which of its
    /// children comes next.
    const Frame = struct {
        /// The entry, or `null` for a thin pack's base from the database.
        at: ?u32,
        oid: Oid,
        type: object.Type,
        bytes: []u8,
        depth: u32,
        next_ofs: usize = 0,
        next_ref: usize = 0,
    };

    /// Resolve every delta: from each whole object, and then from each
    /// base a thin pack left out, down every chain, depth first so that
    /// what is held is one chain's objects.
    fn resolve(x: *Indexer) Error!void {
        if (x.deltas == 0) return;
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |frame| x.gpa.free(frame.bytes);
            stack.deinit(x.gpa);
        }

        for (x.entries.items, 0..) |entry, at| {
            if (entry.kind != .whole) continue;
            const index: u32 = @intCast(at);
            if (x.ofsChildren(index).len == 0 and x.refChildren(entry.oid).len == 0) continue;
            const bytes = try x.load(index);
            try x.walk(&stack, .{ .at = index, .oid = entry.oid, .type = entry.type, .bytes = bytes, .depth = 0 });
        }

        // What is left is reference deltas whose base the pack does not
        // carry: a thin pack, completed from the database. A base may also
        // be a delta in the pack that hangs off such a base, so the groups
        // are gone over until a pass resolves nothing more.
        if (x.options.fix_thin) {
            var progressed = true;
            while (progressed) {
                progressed = false;
                var i: usize = 0;
                while (i < x.ref_bases.items.len) {
                    const base = x.ref_bases.items[i].base;
                    const group = x.refChildren(base);
                    i += group.len;
                    var pending = false;
                    for (group) |ref| {
                        if (!x.entries.items[ref.child].resolved) pending = true;
                    }
                    if (!pending) continue;
                    if (!try x.db.exists(x.io, base)) continue;
                    const found = try x.db.read(x.io, base);
                    // The database's bytes are its allocator's; the stack
                    // frees with this one.
                    const bytes = x.gpa.dupe(u8, found.bytes) catch |err| {
                        x.db.gpa.free(found.bytes);
                        return err;
                    };
                    x.db.gpa.free(found.bytes);
                    x.thin_bases.append(x.gpa, base) catch |err| {
                        x.gpa.free(bytes);
                        return err;
                    };
                    try x.walk(&stack, .{ .at = null, .oid = base, .type = found.type, .bytes = bytes, .depth = 0 });
                    progressed = true;
                }
            }
        }

        for (x.ref_bases.items) |ref| {
            const entry = x.entries.items[ref.child];
            if (!entry.resolved) return x.fail(error.DeltaBaseMissing, .{ .oid = ref.base, .offset = entry.offset });
        }
        for (x.entries.items) |entry| {
            // An offset delta whose chain never reached a whole object: one
            // that names a reference delta that was never resolved.
            if (!entry.resolved) return x.fail(error.DeltaBaseMissing, .{ .offset = entry.offset });
        }
    }

    /// Resolve everything below `root`, which the stack takes ownership of.
    fn walk(x: *Indexer, stack: *std.ArrayList(Frame), root: Frame) Error!void {
        stack.append(x.gpa, root) catch |err| {
            x.gpa.free(root.bytes);
            return err;
        };
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const ofs = if (top.at) |at| x.ofsChildren(at) else &.{};
            const refs = x.refChildren(top.oid);
            var child: ?u32 = null;
            while (child == null) {
                if (top.next_ofs < ofs.len) {
                    const candidate = ofs[top.next_ofs].child;
                    top.next_ofs += 1;
                    if (!x.entries.items[candidate].resolved) child = candidate;
                } else if (top.next_ref < refs.len) {
                    const candidate = refs[top.next_ref].child;
                    top.next_ref += 1;
                    if (!x.entries.items[candidate].resolved) child = candidate;
                } else break;
            }
            const at = child orelse {
                const done = stack.pop().?;
                x.gpa.free(done.bytes);
                continue;
            };
            const entry = &x.entries.items[at];
            if (top.depth + 1 > x.options.max_delta_depth) return x.fail(error.DeltaChainTooDeep, .{ .offset = entry.offset });

            const patch = try x.load(at);
            defer x.gpa.free(patch);
            const sizes = try delta.header(patch);
            if (sizes.target > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = entry.offset });
            const bytes = delta.apply(x.gpa, top.bytes, patch) catch |err| {
                if (x.options.diagnostic) |d| d.* = .{ .offset = entry.offset };
                return err;
            };
            var keep = false;
            defer if (!keep) x.gpa.free(bytes);

            const named = hash.Hasher.nameObject(x.kind, x.hashOptions(), top.type.name(), bytes);
            if (named.collision_attack) return x.fail(error.CollisionAttack, .{ .oid = named.oid, .offset = entry.offset });
            entry.oid = named.oid;
            entry.type = top.type;
            entry.resolved = true;
            try x.checkObject(named.oid, top.type, bytes, entry.offset);
            x.resolved_count += 1;
            Progress.emit(x.options.progress, .{ .resolved = .{ .done = x.resolved_count, .total = x.deltas } });

            if (x.ofsChildren(at).len != 0 or x.refChildren(named.oid).len != 0) {
                const depth = top.depth + 1;
                try stack.append(x.gpa, .{ .at = at, .oid = named.oid, .type = entry.type, .bytes = bytes, .depth = depth });
                keep = true;
            }
        }
    }

    /// Append the bases a thin pack left out, as whole objects, and make
    /// the header's count and the trailing checksum say so. Returns the new
    /// checksum.
    fn appendBases(x: *Indexer, body_end: u64, count: u32) Error!Oid {
        const io = x.io;
        try x.file.setLength(io, body_end);
        var end = body_end;
        var compressed: Io.Writer.Allocating = try .initCapacity(x.gpa, 4096);
        defer compressed.deinit();
        const compressor = try x.gpa.create(flate.Compress);
        defer x.gpa.destroy(compressor);
        for (x.thin_bases.items) |oid| {
            const found = try x.db.read(io, oid);
            defer x.db.gpa.free(found.bytes);

            var head: [16]u8 = undefined;
            const head_len = encodeTypeAndSize(&head, found.type, found.bytes.len);
            compressed.clearRetainingCapacity();
            compressor.* = try flate.Compress.init(&compressed.writer, x.window, .zlib, .level_6);
            try compressor.writer.writeAll(found.bytes);
            try compressor.writer.flush();
            try compressor.finish();

            var crc: std.hash.Crc32 = .init();
            crc.update(head[0..head_len]);
            crc.update(compressed.written());
            try x.file.writePositionalAll(io, head[0..head_len], end);
            try x.file.writePositionalAll(io, compressed.written(), end + head_len);
            try x.entries.append(x.gpa, .{
                .offset = end,
                .data_at = end + head_len,
                .size = found.bytes.len,
                .oid = oid,
                .crc = crc.final(),
                .kind = .whole,
                .type = found.type,
                .resolved = true,
            });
            end += head_len + compressed.written().len;
        }

        var count_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_bytes, count + @as(u32, @intCast(x.thin_bases.items.len)), .big);
        try x.file.writePositionalAll(io, &count_bytes, 8);

        var hasher: hash.Hasher = .init(x.kind);
        var at: u64 = 0;
        while (at < end) {
            const want: usize = @intCast(@min(@as(u64, x.read_buffer.len), end - at));
            const n = try x.file.readPositionalAll(io, x.read_buffer[0..want], at);
            if (n == 0) return error.TruncatedPack;
            hasher.update(x.read_buffer[0..n]);
            at += n;
        }
        const checksum = hasher.final();
        try x.file.writePositionalAll(io, checksum.raw(), end);
        return checksum;
    }
};

fn lowerBound(comptime T: type, items: []const T, key: anytype, before: fn (T, @TypeOf(key)) bool) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (before(items[mid], key)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn encodeTypeAndSize(buf: *[16]u8, t: object.Type, size: u64) usize {
    const type_bits: u8 = switch (t) {
        .commit => 1,
        .tree => 2,
        .blob => 3,
        .tag => 4,
    };
    var value = size;
    var first: u8 = (type_bits << 4) | @as(u8, @truncate(value & 0x0f));
    value >>= 4;
    if (value != 0) first |= 0x80;
    buf[0] = first;
    var i: usize = 1;
    while (value != 0) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        buf[i] = byte;
        i += 1;
    }
    return i;
}

const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");
const repo_mod = @import("repo.zig");

/// One entry of a pack built by hand, for the shapes a real packer does not
/// write.
const TestEntry = union(enum) {
    whole: struct { t: object.Type, bytes: []const u8 },
    ref_delta: struct { base: Oid, patch: []const u8 },
    /// A delta against the entry `back` places before this one.
    ofs_delta: struct { back: usize, patch: []const u8 },
};

/// A pack's bytes, header to trailer, from `entries`.
fn buildPack(gpa: Allocator, kind: Kind, entries: []const TestEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var header: [12]u8 = undefined;
    @memcpy(header[0..4], "PACK");
    std.mem.writeInt(u32, header[4..8], 2, .big);
    std.mem.writeInt(u32, header[8..12], @intCast(entries.len), .big);
    try out.appendSlice(gpa, &header);
    const offsets = try gpa.alloc(usize, entries.len);
    defer gpa.free(offsets);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    for (entries, 0..) |entry, i| {
        offsets[i] = out.items.len;
        var head: [16]u8 = undefined;
        const payload = switch (entry) {
            .whole => |w| blk: {
                const n = encodeTypeAndSize(&head, w.t, w.bytes.len);
                try out.appendSlice(gpa, head[0..n]);
                break :blk w.bytes;
            },
            .ref_delta => |r| blk: {
                const n = encodeTypeAndSize(&head, .blob, r.patch.len);
                head[0] = (head[0] & 0x8f) | (7 << 4);
                try out.appendSlice(gpa, head[0..n]);
                try out.appendSlice(gpa, r.base.raw());
                break :blk r.patch;
            },
            .ofs_delta => |o| blk: {
                const n = encodeTypeAndSize(&head, .blob, o.patch.len);
                head[0] = (head[0] & 0x8f) | (6 << 4);
                try out.appendSlice(gpa, head[0..n]);
                const back = offsets[i] - offsets[i - o.back];
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
                try out.appendSlice(gpa, buf[pos..]);
                break :blk o.patch;
            },
        };
        var compressed: Io.Writer.Allocating = try .initCapacity(gpa, 256);
        defer compressed.deinit();
        var compress = try flate.Compress.init(&compressed.writer, window, .zlib, .level_1);
        try compress.writer.writeAll(payload);
        try compress.writer.flush();
        try compress.finish();
        try out.appendSlice(gpa, compressed.written());
    }
    var hasher: hash.Hasher = .init(kind);
    hasher.update(out.items);
    try out.appendSlice(gpa, hasher.final().raw());
    return out.toOwnedSlice(gpa);
}

/// A delta that copies the whole of a base of `base_len` bytes and then
/// inserts `suffix`.
fn appendDelta(gpa: Allocator, base_len: usize, suffix: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_]usize{ base_len, base_len + suffix.len }) |size| {
        var value = size;
        while (true) {
            var byte: u8 = @truncate(value & 0x7f);
            value >>= 7;
            if (value != 0) byte |= 0x80;
            try out.append(gpa, byte);
            if (value == 0) break;
        }
    }
    if (base_len != 0) {
        try out.append(gpa, 0x80 | 0x01 | 0x10);
        try out.append(gpa, 0);
        try out.append(gpa, @intCast(base_len));
    }
    try out.append(gpa, @intCast(suffix.len));
    try out.appendSlice(gpa, suffix);
    return out.toOwnedSlice(gpa);
}

/// A repository with some history: files that change a little each
/// commit, so the packer finds deltas, a directory, and an annotated tag.
fn historyRepo(gpa: Allocator, io: Io, commits: usize) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..40) |line| try text.print(gpa, "line {d} of a file that is long enough to delta well\n", .{line});
    for (0..commits) |i| {
        try text.print(gpa, "change {d}\n", .{i});
        try repo.writeFile(io, "src/a.txt", text.items);
        try repo.writeFile(io, "docs/b.md", text.items[0 .. text.items.len / 2]);
        var name_buf: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&name_buf, "files/{d}.txt", .{i}), "new\n");
        try repo.exec(io, &.{ "add", "-A" });
        var msg_buf: [32]u8 = undefined;
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) });
    }
    try repo.exec(io, &.{ "tag", "-a", "v1", "-m", "version one" });
    return repo;
}

/// The one pack in a repository's `objects/pack`, as `pack-<name>` without
/// an extension. The result is the caller's.
fn onlyPack(gpa: Allocator, io: Io, pack_dir: Io.Dir) ![]u8 {
    var found: ?[]u8 = null;
    errdefer if (found) |f| gpa.free(f);
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
        if (found != null) return error.TestUnexpectedResult;
        found = try gpa.dupe(u8, entry.name[0 .. entry.name.len - 5]);
    }
    return found orelse error.TestUnexpectedResult;
}

fn countEntries(io: Io, dir: Io.Dir) !usize {
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "a pack git wrote is received, and its index is byte for byte the one git wrote" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_][]const u8{ "true", "false" }) |offsets| {
        var source = try historyRepo(gpa, io, 8);
        defer source.deinit();
        // Offset deltas, then reference deltas.
        var setting_buf: [64]u8 = undefined;
        const setting = try std.fmt.bufPrint(&setting_buf, "repack.useDeltaBaseOffset={s}", .{offsets});
        try source.exec(io, &.{ "-c", setting, "repack", "-a", "-d", "-f", "-q" });
        var source_git = try source.gitDir(io);
        defer source_git.close(io);
        var source_packs = try source_git.openDir(io, "objects/pack", .{ .iterate = true });
        defer source_packs.close(io);
        const base = try onlyPack(gpa, io, source_packs);
        defer gpa.free(base);
        const pack_name = try std.fmt.allocPrint(gpa, "{s}.pack", .{base});
        defer gpa.free(pack_name);
        const idx_name = try std.fmt.allocPrint(gpa, "{s}.idx", .{base});
        defer gpa.free(idx_name);
        const pack_bytes = try source_packs.readFileAlloc(io, pack_name, gpa, .unlimited);
        defer gpa.free(pack_bytes);
        const idx_bytes = try source_packs.readFileAlloc(io, idx_name, gpa, .unlimited);
        defer gpa.free(idx_bytes);

        var target = try testgit.Repo.init(gpa, io, &.{"--bare"});
        defer target.deinit();
        var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
        defer repo.deinit(io);
        var pack_dir = try target.dir.openDir(io, "objects/pack", .{ .iterate = true });
        defer pack_dir.close(io);

        var in: Io.Reader = .fixed(pack_bytes);
        const result = try receive(gpa, io, &repo.odb, pack_dir, &in, .{});
        try testing.expect(result.deltas > 0);
        try testing.expectEqual(@as(u32, 0), result.appended);

        const received = try pack_dir.readFileAlloc(io, idx_name, gpa, .unlimited);
        defer gpa.free(received);
        try testing.expectEqualSlices(u8, idx_bytes, received);

        // git reads it: the pack verifies, and with the history's refs in
        // place a strict fsck finds everything connected and well formed.
        const verify_path = try std.fmt.allocPrint(gpa, "objects/pack/{s}", .{idx_name});
        defer gpa.free(verify_path);
        try target.exec(io, &.{ "verify-pack", verify_path });
        const head = try source.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(head);
        try target.exec(io, &.{ "update-ref", "refs/heads/main", head });
        try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
        // The database reads the new pack at once.
        const found = try repo.odb.read(io, try Oid.parse(.sha1, head));
        gpa.free(found.bytes);
    }
}

test "a thin pack is completed from the database, and git indexes the result identically" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try historyRepo(gpa, io, 6);
    defer source.deinit();
    const old = try source.line(io, &.{ "rev-parse", "HEAD~3" });
    defer gpa.free(old);
    const new = try source.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(new);

    var target = try testgit.Repo.init(gpa, io, &.{"--bare"});
    defer target.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
    defer repo.deinit(io);
    var pack_dir = try target.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    // First what the target already has: everything up to `old`.
    const first_input = try std.fmt.allocPrint(gpa, "{s}\n", .{old});
    defer gpa.free(first_input);
    const first = try testremote.gitInput(gpa, io, source.dir, &.{ "pack-objects", "--revs", "--stdout", "-q" }, first_input);
    defer gpa.free(first);
    var first_in: Io.Reader = .fixed(first);
    _ = try receive(gpa, io, &repo.odb, pack_dir, &first_in, .{});
    const packs_before = try countEntries(io, pack_dir);

    // Then a thin pack of what is new, its deltas against what is not in it.
    const thin_input = try std.fmt.allocPrint(gpa, "{s}\n^{s}\n", .{ new, old });
    defer gpa.free(thin_input);
    const thin = try testremote.gitInput(gpa, io, source.dir, &.{ "pack-objects", "--revs", "--thin", "--stdout", "-q" }, thin_input);
    defer gpa.free(thin);

    // Refused whole when completing it is not allowed, and nothing is left.
    var diagnostic: Diagnostic = .{};
    var refused_in: Io.Reader = .fixed(thin);
    try testing.expectError(error.DeltaBaseMissing, receive(gpa, io, &repo.odb, pack_dir, &refused_in, .{
        .fix_thin = false,
        .diagnostic = &diagnostic,
    }));
    try testing.expect(diagnostic.oid != null);
    try testing.expectEqual(packs_before, try countEntries(io, pack_dir));

    var thin_in: Io.Reader = .fixed(thin);
    const result = try receive(gpa, io, &repo.odb, pack_dir, &thin_in, .{});
    try testing.expect(result.appended > 0);

    var hex: [hash.max_hex_len]u8 = undefined;
    const pack_path = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.pack", .{result.name.?.hex(&hex)});
    defer gpa.free(pack_path);
    const idx_path = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.idx", .{result.name.?.hex(&hex)});
    defer gpa.free(idx_path);
    try target.exec(io, &.{ "index-pack", "-o", "check.idx", pack_path });
    const ours = try target.readFile(io, idx_path);
    defer gpa.free(ours);
    const theirs = try target.readFile(io, "check.idx");
    defer gpa.free(theirs);
    try testing.expectEqualSlices(u8, theirs, ours);
    try target.exec(io, &.{ "verify-pack", idx_path });
    try target.exec(io, &.{ "update-ref", "refs/heads/main", new });
    try target.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
}

test "a malformed tree is refused by name, and nothing is kept" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const blob_oid = hash.Hasher.object(.sha1, "blob", "x\n");
    var tree: std.ArrayList(u8) = .empty;
    defer tree.deinit(gpa);
    for ([_][]const u8{ "b", "a" }) |name| {
        try tree.print(gpa, "100644 {s}\x00", .{name});
        try tree.appendSlice(gpa, blob_oid.raw());
    }
    const bytes = try buildPack(gpa, .sha1, &.{
        .{ .whole = .{ .t = .blob, .bytes = "x\n" } },
        .{ .whole = .{ .t = .tree, .bytes = tree.items } },
    });
    defer gpa.free(bytes);
    var diagnostic: Diagnostic = .{};
    var in: Io.Reader = .fixed(bytes);
    try testing.expectError(error.MalformedTree, receive(gpa, io, &repo.odb, pack_dir, &in, .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(fsck.Problem.tree_not_sorted, diagnostic.problem.?);
    try testing.expect(diagnostic.oid.?.eql(hash.Hasher.object(.sha1, "tree", tree.items)));
    try testing.expectEqual(@as(usize, 0), try countEntries(io, pack_dir));

    // Asked not to check, the same pack is kept.
    var unchecked: Io.Reader = .fixed(bytes);
    const kept = try receive(gpa, io, &repo.odb, pack_dir, &unchecked, .{ .check_objects = false });
    try testing.expectEqual(@as(u32, 2), kept.objects);
}

test "a damaged stream is a named error and leaves nothing behind" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const patch = try appendDelta(gpa, 4, "more\n");
    defer gpa.free(patch);
    const good = try buildPack(gpa, .sha1, &.{
        .{ .whole = .{ .t = .blob, .bytes = "base" } },
        .{ .ofs_delta = .{ .back = 1, .patch = patch } },
    });
    defer gpa.free(good);

    const Case = struct { bytes: []const u8, err: Error };
    const flipped = try gpa.dupe(u8, good);
    defer gpa.free(flipped);
    flipped[20] ^= 0x40;
    const not_pack = try gpa.dupe(u8, good);
    defer gpa.free(not_pack);
    not_pack[0] = 'Q';
    const missing_base = try buildPack(gpa, .sha1, &.{
        .{ .ref_delta = .{ .base = hash.Hasher.object(.sha1, "blob", "nowhere"), .patch = patch } },
    });
    defer gpa.free(missing_base);
    const cases = [_]Case{
        .{ .bytes = good[0 .. good.len - 7], .err = error.PackChecksumMismatch },
        .{ .bytes = good[0..10], .err = error.TruncatedPack },
        .{ .bytes = flipped, .err = error.PackChecksumMismatch },
        .{ .bytes = not_pack, .err = error.NotAPack },
        .{ .bytes = missing_base, .err = error.DeltaBaseMissing },
    };
    for (cases) |case| {
        var in: Io.Reader = .fixed(case.bytes);
        try testing.expectError(case.err, receive(gpa, io, &repo.odb, pack_dir, &in, .{}));
        try testing.expectEqual(@as(usize, 0), try countEntries(io, pack_dir));
    }

    var in: Io.Reader = .fixed(good);
    const result = try receive(gpa, io, &repo.odb, pack_dir, &in, .{});
    try testing.expectEqual(@as(u32, 2), result.objects);
    const found = try repo.odb.read(io, hash.Hasher.object(.sha1, "blob", "basemore\n"));
    defer gpa.free(found.bytes);
    try testing.expectEqualStrings("basemore\n", found.bytes);
}

test "fuzz: any stream is a pack or a named error, and a kept pack verifies" {
    try testing.fuzz({}, fuzzReceive, .{});
}

fn fuzzReceive(_: void, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var db = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    var stream: []u8 = &.{};
    defer gpa.free(stream);
    if (smith.valueRangeAtMost(u8, 0, 3) == 0) {
        var scratch: [512]u8 = undefined;
        stream = try gpa.dupe(u8, scratch[0..smith.slice(&scratch)]);
    } else {
        // A pack that is well formed up to the damage done to it, so the
        // fuzzer spends its time inside the entries and not in the header.
        var entries: [4]TestEntry = undefined;
        var bodies: [4][64]u8 = undefined;
        var patches: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };
        defer for (patches) |p| gpa.free(p);
        const count = smith.valueRangeAtMost(u8, 1, 4);
        for (0..count) |i| {
            const body = bodies[i][0..smith.slice(&bodies[i])];
            const choice = smith.valueRangeAtMost(u8, 0, 5);
            if (i != 0 and choice >= 4) {
                patches[i] = try appendDelta(gpa, if (entries[i - 1] == .whole) entries[i - 1].whole.bytes.len else 0, body[0..@min(body.len, 100)]);
                entries[i] = if (choice == 4)
                    .{ .ofs_delta = .{ .back = 1, .patch = patches[i] } }
                else
                    .{ .ref_delta = .{ .base = hash.Hasher.object(.sha1, "blob", if (entries[i - 1] == .whole) entries[i - 1].whole.bytes else ""), .patch = patches[i] } };
            } else {
                entries[i] = .{ .whole = .{ .t = switch (choice) {
                    0 => .commit,
                    1 => .tree,
                    2 => .tag,
                    else => .blob,
                }, .bytes = body } };
            }
        }
        stream = try buildPack(gpa, .sha1, entries[0..count]);
        const flips = smith.valueRangeAtMost(u8, 0, 3);
        for (0..flips) |_| {
            const at = smith.valueRangeAtMost(u32, 0, @intCast(stream.len - 1));
            stream[at] ^= smith.value(u8);
        }
    }

    var in: Io.Reader = .fixed(stream);
    const result = receive(gpa, io, &db, pack_dir, &in, .{}) catch {
        // Whatever the refusal, nothing is left behind.
        if (try countEntries(io, pack_dir) != 0) return error.TemporaryLeftBehind;
        return;
    };
    const name = result.name orelse return;
    var hex: [hash.max_hex_len]u8 = undefined;
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "pack-{s}", .{name.hex(&hex)});
    var p = try pack.Pack.open(gpa, io, pack_dir, base, .sha1, .{});
    defer p.deinit(io);
    const checked = try p.verify(io, null, 0);
    if (checked.objects != result.objects) return error.PackDidNotVerify;
}
