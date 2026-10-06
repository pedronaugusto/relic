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
//! Every commit, tree and tag is checked the way git's `index-pack
//! --strict` checks one, with the levels `fsck.Rules` give, before it is
//! kept, and a malformed one is refused by name; the blobs trees name as
//! `.gitmodules` and `.gitattributes` are read back and checked once every
//! object is in hand. A stream that
//! is not a pack, or stops short, or carries a delta that reaches outside
//! itself, is a named error and leaves nothing behind.

const Self = @This();

const std = @import("std");
const crc32 = @import("../crc32.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;
const inflate_mod = @import("inflate.zig");
const config_mod = @import("../config.zig");

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const revindex = @import("revindex.zig");
const pack = @import("pack.zig");
const delta = @import("delta.zig");
const fs = @import("../repo/fs.zig");
const odb_mod = @import("../odb.zig");
const fsck = @import("../object/fsck.zig");
const warning = @import("../repo/warning.zig");
const progress_mod = @import("../transport/progress.zig");

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
    /// An object the pack carries has the name of one the database already
    /// holds, and other bytes: a hash collision, which git's index-pack
    /// reports as "SHA1 COLLISION FOUND". `Diagnostic.oid` names it.
    HashCollision,
    /// A commit git's `fsck` refuses. `Diagnostic` names the object and
    /// the problem.
    MalformedCommit,
    /// A tree git's `fsck` refuses.
    MalformedTree,
    /// A tag git's `fsck` refuses.
    MalformedTag,
    /// A blob a tree names as `.gitmodules` or `.gitattributes` that git's
    /// `fsck` refuses, or one that is not there or not a blob.
    MalformedBlob,
    /// The stream being read failed; its own reader says why.
    ReadFailed,
} || delta.Error || odb_mod.Error || Io.File.Reader.Error || Io.File.SetLengthError;

/// How a pack is received.
pub const Options = struct {
    /// Complete a thin pack from the object database. Off, a reference
    /// delta whose base is not in the pack is `error.DeltaBaseMissing`.
    fix_thin: bool = true,
    /// The rules every commit, tree and tag is checked with, and the
    /// blobs trees name as `.gitmodules` and `.gitattributes`; `null`
    /// checks nothing. `fsck.forTransfer` gives what a repository's
    /// configuration asks for.
    fsck: ?*const fsck.Rules = &fsck.baseline,
    /// The pack comes from a promisor remote, which promises a found
    /// `.gitmodules` or `.gitattributes` the pack and the database lack, as
    /// git takes a promisor object as there.
    promised: bool = false,
    /// Where what the rules make warnings goes, as git prints them.
    warnings: ?*warning.Warnings = null,
    /// How hard the pack and its index are pushed to the disk before they
    /// are renamed into place.
    sync: fs.Sync = .none,
    /// The most bytes the stream may carry, or `null` for no bound.
    max_pack_bytes: ?u64 = null,
    /// The largest object, or delta, held in memory.
    max_object_bytes: u64 = 1 << 31,
    /// How deep a delta chain may go.
    max_delta_depth: u32 = pack.default_max_depth,
    /// `core.deltaBaseCacheLimit`: how many bytes of the bases along a
    /// delta chain one resolving thread holds. Past it the oldest are let
    /// go and rebuilt from the pack if another delta needs them, as git's
    /// index-pack prunes them, so a chain of large objects costs time and
    /// not its whole length in memory. git's default, 96 MiB.
    delta_base_cache_limit: u64 = 96 << 20,
    progress: ?Progress = null,
    /// Where the object behind a refusal is named, when the caller wants it.
    diagnostic: ?*Diagnostic = null,
    /// Write `pack-<name>.rev` beside the index, as git does while
    /// `pack.writeReverseIndex` is on: `revindex.wanted`.
    reverse_index: bool = true,
    /// Where the names the pack's commits, trees and tags hold are
    /// collected, for a caller that checks the pack is connected without
    /// reading it again: `Links`.
    links: ?*Links = null,
    /// How many threads resolve the deltas: `pack.threads`
    /// (`configuredThreads`). Zero chooses as git's index-pack does from
    /// the processors: all of up to three, three of four or five, half of
    /// fewer than forty, and twenty at most. A fetch or clone that copies
    /// a repository on this machine writes its pack instead, on this many
    /// tasks (`odb.PackOptions.threads`, zero there for one per processor).
    threads: u32 = 0,
};

/// `pack.threads`, as index-pack reads it: zero, or unset, to choose from
/// the processors; a value that is not a number is zero.
pub fn configuredThreads(config: ?*const config_mod.Config) u32 {
    const c = config orelse return 0;
    const n = c.getInt("pack.threads", 0) catch return 0;
    return std.math.cast(u32, n) orelse 0;
}

/// The names a received pack's commits, trees and tags hold, collected as
/// it is indexed — each object is in hand then — so that whether the pack
/// is connected is asked of the pack's index and the database alone,
/// without reading an object again: git's index-pack
/// `--check-self-contained-and-connected`.
pub const Links = struct {
    gpa: Allocator,
    /// Trees, blobs and tag targets named, each once.
    named: Oid.Set = .empty,
    /// Each commit with each parent it names: a parent of a commit on a
    /// shallow boundary is not looked for.
    parents: std.ArrayList([2]Oid) = .empty,
    /// An object did not read as its type says, and no conclusion is drawn:
    /// the caller walks instead.
    unreadable: bool = false,

    /// Nothing collected.
    pub fn init(gpa: Allocator) Links {
        return .{ .gpa = gpa };
    }

    /// Release everything.
    pub fn deinit(l: *Links) void {
        l.named.deinit(l.gpa);
        l.parents.deinit(l.gpa);
        l.* = undefined;
    }

    fn take(l: *Links, kind: Kind, t: object.Type, oid: Oid, bytes: []const u8) Allocator.Error!void {
        switch (t) {
            .blob => {},
            .commit => {
                var commit = object.Commit.parse(l.gpa, kind, bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        l.unreadable = true;
                        return;
                    },
                };
                defer commit.deinit();
                try l.named.put(l.gpa, commit.tree, {});
                for (commit.parents) |parent| try l.parents.append(l.gpa, .{ oid, parent });
            },
            .tree => {
                var entries = object.Tree.parse(kind, bytes).iterate();
                while (entries.next() catch {
                    l.unreadable = true;
                    return;
                }) |entry| {
                    if (entry.mode == .gitlink) continue;
                    try l.named.put(l.gpa, entry.oid, {});
                }
            },
            .tag => {
                var tag = object.Tag.parse(l.gpa, kind, bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        l.unreadable = true;
                        return;
                    },
                };
                defer tag.deinit();
                try l.named.put(l.gpa, tag.target, {});
            },
        }
    }

    /// The first name the pack holds that is neither in the pack, whose
    /// index is `fresh`, nor in `db`; `null` when every one is there. A
    /// parent of a commit in `db`'s shallow boundary is not looked for.
    pub fn firstMissing(l: *const Links, io: Io, db: *odb_mod.Odb, fresh: *const pack.Index) (odb_mod.Error || pack.IndexError)!?Oid {
        var it = l.named.keyIterator();
        while (it.next()) |oid| {
            if ((try fresh.find(oid.*)) != null) continue;
            if (!try db.exists(io, oid.*)) return oid.*;
        }
        for (l.parents.items) |pair| {
            if (db.shallow.contains(pair[0])) continue;
            if ((try fresh.find(pair[1])) != null) continue;
            if (!try db.exists(io, pair[1])) return pair[1];
        }
        return null;
    }
};

/// What went wrong, and where, for a message.
pub const Diagnostic = struct {
    /// The object refused, or the base that was missing, when there is one.
    oid: ?Oid = null,
    /// What git's `fsck` calls the problem, for a malformed object;
    /// `null` with a malformed commit or tag that git's parser cannot read
    /// at all.
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
    /// A reference delta a thread has taken to resolve.
    claimed: bool = false,
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
) Self.Error!Result {
    const kind = db.objectFormat();

    var temp_buf: [64]u8 = undefined;
    const temp = fs.tempName(io, &temp_buf, "tmp_pack_");
    const file = try pack_dir.createFile(io, temp, .{ .exclusive = true, .read = true });
    var file_open = true;
    var kept = false;
    defer {
        if (file_open) file.close(io);
        if (!kept) pack_dir.deleteFile(io, temp) catch {};
    }

    // The stream is read once: each entry as it arrives, its bytes kept in
    // the file on the way, as git's index-pack reads its input, so that
    // naming the objects goes on while the rest is still coming.
    const tee_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(tee_buffer);
    var tee: Tee = .init(io, file, in, kind, tee_buffer, options);
    const count = try readPackHeader(&tee);

    var indexer: Indexer = try .init(gpa, io, db, file, options);
    defer indexer.deinit();
    const read = try readEntries(&tee, &indexer, count, kind);
    const trailer = read.trailer;
    const body_end = read.body_end;

    if (count == 0) return .{ .name = null, .objects = 0, .deltas = 0, .appended = 0 };
    try indexer.findBases();
    try indexer.resolve();
    try indexer.checkCollisions();

    var name = trailer;
    var appended: u32 = 0;
    if (indexer.thin_bases.items.len != 0) {
        name = try indexer.appendBases(body_end, count);
        appended = @intCast(indexer.thin_bases.items.len);
    }
    try indexer.checkFound();

    const index_entries = try indexEntries(gpa, &indexer, options);
    defer gpa.free(index_entries);

    switch (options.sync) {
        .none => {},
        .batch, .per_file => try file.sync(io),
    }
    file.close(io);
    file_open = false;

    var hex: [hash.max_hex_len]u8 = undefined;
    const text = name.hex(&hex);
    var pack_name_buf: [96]u8 = undefined;
    // unreachable: a hex name is at most max_hex_len digits, the rest ten bytes
    const pack_name = std.fmt.bufPrint(&pack_name_buf, "pack-{s}.pack", .{text}) catch unreachable;
    var idx_name_buf: [96]u8 = undefined;
    // unreachable: a hex name is at most max_hex_len digits, the rest nine bytes
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
    var rev_temp_buf: [64]u8 = undefined;
    const rev_temp: ?[]const u8 = if (options.reverse_index) fs.tempName(io, &rev_temp_buf, "tmp_rev_") else null;
    if (rev_temp) |t| try revindex.write(gpa, io, pack_dir, t, kind, index_entries, name, options.sync);
    errdefer if (rev_temp) |t| pack_dir.deleteFile(io, t) catch {};

    // read-only, as git leaves a pack and its indexes
    const shared = db.sharedPermissions();
    fs.readOnlyObject(io, pack_dir, temp, shared);
    fs.readOnlyObject(io, pack_dir, idx_temp, shared);
    if (rev_temp) |t| fs.readOnlyObject(io, pack_dir, t, shared);
    // Pack first, then the reverse index, index last, as git renames them:
    // a reader finds a pack by its index.
    try fs.renameWithRetry(io, pack_dir, temp, pack_name);
    kept = true;
    if (rev_temp) |t| {
        var rev_name_buf: [96]u8 = undefined;
        // unreachable: a hex name is at most max_hex_len digits, the rest nine bytes
        const rev_name = std.fmt.bufPrint(&rev_name_buf, "pack-{s}.rev", .{text}) catch unreachable;
        try renameBesidePack(io, pack_dir, t, rev_name, pack_name);
    }
    try renameBesidePack(io, pack_dir, idx_temp, idx_name, pack_name);
    if (options.sync == .batch) try fs.syncBarrier(io, pack_dir);
    try db.refresh(io);
    return result;
}

/// Read every entry of the stream through `tee` into `indexer`, then the
/// trailer: the stream's own checksum, which must end the entries exactly.
fn readEntries(tee: *Tee, indexer: *Indexer, count: u32, kind: Kind) Error!struct { trailer: Oid, body_end: u64 } {
    const raw_len = kind.rawLen();
    const parsed_end = indexer.parse(tee, count) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled, error.ReadFailed, error.PackTooLarge => return err,
        // A damaged stream is named by its checksum, as when it was read
        // whole before any entry was looked at.
        else => {
            tee.drain() catch return err;
            const whole = tee.finish();
            if (whole.size >= 12 + raw_len and !whole.trailerMatches(kind)) return error.PackChecksumMismatch;
            return err;
        },
    };
    try tee.drain();
    const copied = tee.finish();
    if (copied.size < 12 + raw_len) return error.TruncatedPack;
    if (!copied.trailerMatches(kind)) return error.PackChecksumMismatch;
    // unreachable: the tail is cut to the format's raw length
    const trailer = Oid.fromRaw(kind, copied.tail[0..raw_len]) catch unreachable;
    const body_end = copied.size - raw_len;
    if (parsed_end > body_end) return error.TruncatedPack;
    if (parsed_end != body_end) return error.PackTrailingGarbage;
    return .{ .trailer = trailer, .body_end = body_end };
}

/// The index's entries, sorted by name. Every name once: the index cannot
/// hold one twice. The caller frees them.
fn indexEntries(gpa: Allocator, indexer: *const Indexer, options: Options) Error![]pack.IndexEntry {
    const index_entries = try gpa.alloc(pack.IndexEntry, indexer.entries.items.len);
    errdefer gpa.free(index_entries);
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
    return index_entries;
}

/// Rename `from` to `to` beside the pack already at `pack_name`. When the
/// rename fails the pack goes too: a pack with no index is never read.
fn renameBesidePack(io: Io, pack_dir: Io.Dir, from: []const u8, to: []const u8, pack_name: []const u8) Io.Dir.RenameError!void {
    fs.renameWithRetry(io, pack_dir, from, to) catch |err| {
        // ziglint-ignore: Z026 the rename's error is the one to report; a pack with no index is unreachable, and `git gc` prunes it
        pack_dir.deleteFile(io, pack_name) catch {};
        return err;
    };
}

fn readPackHeader(tee: *Tee) Error!u32 {
    var header: [12]u8 = undefined;
    tee.interface.readSliceAll(&header) catch |err| return switch (err) {
        error.EndOfStream => error.TruncatedPack,
        error.ReadFailed => tee.err orelse error.ReadFailed,
    };
    if (!std.mem.eql(u8, header[0..4], "PACK")) return error.NotAPack;
    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version != 2 and version != 3) return error.UnsupportedPackVersion;
    return std.mem.readInt(u32, header[8..12], .big);
}

const Copied = struct {
    size: u64,
    /// The hash of everything but the last `rawLen` bytes.
    checksum: Oid,
    /// The last `rawLen` bytes, which should be that hash.
    tail: [hash.max_raw_len]u8,

    fn trailerMatches(c: *const Copied, kind: Kind) bool {
        // unreachable: the tail is cut to the format's raw length
        const trailer = Oid.fromRaw(kind, c.tail[0..kind.rawLen()]) catch unreachable;
        return trailer.eql(c.checksum);
    }
};

/// The stream as the entries are read from it: every byte taken is written
/// to the file at its offset and hashed — all but the last `rawLen`, which
/// are only known to be the trailer at the end, so a window of that many is
/// held back from the hash.
const Tee = struct {
    interface: Io.Reader,
    io: Io,
    file: Io.File,
    in: *Io.Reader,
    kind: Kind,
    options: Options,
    /// Bytes taken from `in` and written, which is where the next go.
    written: u64 = 0,
    hasher: hash.Hasher,
    tail: [hash.max_raw_len]u8 = undefined,
    tail_len: usize = 0,
    err: ?Error = null,

    fn init(io: Io, file: Io.File, in: *Io.Reader, kind: Kind, buffer: []u8, options: Options) Tee {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .io = io,
            .file = file,
            .in = in,
            .kind = kind,
            .options = options,
            .hasher = .init(kind),
        };
    }

    /// Where in the pack the next byte read is.
    fn position(t: *const Tee) u64 {
        return t.written - t.interface.bufferedLen();
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Tee = @alignCast(@fieldParentPtr("interface", r)); // safe: this function is installed only on a Tee's interface
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = t.pull(dest) catch |err| {
            t.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    /// Take from `in` into `dest` — read straight into it, as a reader
    /// with no buffer of its own, like the side-band's, needs — until it is
    /// full or the stream ends; zero at the end.
    fn pull(t: *Tee, dest: []u8) Error!usize {
        const n = t.in.readSliceShort(dest) catch return error.ReadFailed;
        try t.keep(dest[0..n]);
        return n;
    }

    fn keep(t: *Tee, chunk: []const u8) Error!void {
        const raw_len = t.kind.rawLen();
        try t.file.writePositionalAll(t.io, chunk, t.written);
        t.written += chunk.len;
        if (t.options.max_pack_bytes) |most| {
            if (t.written > most) return error.PackTooLarge;
        }
        const n = chunk.len;
        const held = t.tail_len + n;
        if (held <= raw_len) {
            @memcpy(t.tail[t.tail_len..][0..n], chunk);
            t.tail_len = held;
        } else {
            const release = held - raw_len;
            if (release <= t.tail_len) {
                t.hasher.update(t.tail[0..release]);
                @memmove(t.tail[0 .. t.tail_len - release], t.tail[release..t.tail_len]);
                t.tail_len -= release;
                @memcpy(t.tail[t.tail_len..][0..n], chunk);
                t.tail_len += n;
            } else {
                t.hasher.update(t.tail[0..t.tail_len]);
                t.hasher.update(chunk[0 .. release - t.tail_len]);
                @memcpy(t.tail[0..raw_len], chunk[n - raw_len ..]);
                t.tail_len = raw_len;
            }
        }
        Progress.emit(t.options.progress, .{ .received = t.written });
    }

    /// Read the rest of the stream into the file: the trailer, and
    /// anything after it.
    fn drain(t: *Tee) Error!void {
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try t.pull(&chunk);
            if (n == 0) return;
        }
    }

    /// Everything read, and its hash.
    fn finish(t: *Tee) Copied {
        return .{ .size = t.written, .checksum = t.hasher.final(), .tail = t.tail };
    }
};

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
    /// How the stream's entries are decoded while it is parsed.
    inflater: Inflater,
    reader: Io.File.Reader,
    entries: std.ArrayList(Entry) = .empty,
    ofs_bases: std.ArrayList(OfsBase) = .empty,
    ref_bases: std.ArrayList(RefBase) = .empty,
    /// Bases a thin pack named and the database supplied, in the order they
    /// are appended.
    thin_bases: std.ArrayList(Oid) = .empty,
    deltas: u32 = 0,
    resolved_count: std.atomic.Value(u64) = .init(0),
    /// Held by the threads resolving deltas for what they share: `Links`,
    /// the progress, the diagnostic, reference deltas claimed.
    lock: Io.Mutex = .init,
    /// The whole objects deltas hang from, and the next one a thread takes.
    roots: []u32 = &.{},
    next_root: std.atomic.Value(usize) = .init(0),
    /// The first failure among the threads, which stops the others.
    failure: ?Error = null,
    failed: std.atomic.Value(bool) = .init(false),
    /// The stream, while `parse` reads from it.
    tee: ?*Tee = null,
    /// The blobs trees name as `.gitmodules` and `.gitattributes`, under
    /// `lock`.
    found: fsck.Found = .{},

    fn init(gpa: Allocator, io: Io, db: *odb_mod.Odb, file: Io.File, options: Options) Allocator.Error!Indexer {
        const read_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(read_buffer);
        const window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(window);
        const inflater: Inflater = try .init(gpa);
        return .{
            .gpa = gpa,
            .io = io,
            .db = db,
            .kind = db.objectFormat(),
            .file = file,
            .options = options,
            .read_buffer = read_buffer,
            .window = window,
            .inflater = inflater,
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
        x.inflater.deinit();
        x.gpa.free(x.roots);
        x.found.deinit(x.gpa);
        x.* = undefined;
    }

    /// Fail with `err`, saying where for the caller that asked. With
    /// several threads the first failure is the one returned and said.
    fn fail(x: *Indexer, err: Error, diagnostic: Diagnostic) Error {
        x.lock.lockUncancelable(x.io);
        defer x.lock.unlock(x.io);
        if (x.failure != null) return err;
        x.failure = err;
        x.failed.store(true, .release);
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
        return x.input().takeByte() catch |err| switch (err) {
            error.EndOfStream => error.TruncatedPack,
            error.ReadFailed => x.inputError() orelse error.ReadFailed,
        };
    }

    /// What entries are read from: the stream while it is parsed, the file
    /// after.
    fn input(x: *Indexer) *Io.Reader {
        return if (x.tee) |t| &t.interface else &x.reader.interface;
    }

    fn inputError(x: *const Indexer) ?Error {
        if (x.tee) |t| return t.err;
        return x.reader.err;
    }

    /// Read every entry in order from the stream, as it arrives: its
    /// header, and its zlib stream to the end so the next one's offset is
    /// known. Whole objects are named here. Returns where the last entry
    /// ends, which the caller checks against the trailer once the stream
    /// is all in.
    fn parse(x: *Indexer, tee: *Tee, count: u32) Error!u64 {
        const gpa = x.gpa;
        // A count is not believed for the allocation beyond this; the list
        // grows as the entries come.
        try x.entries.ensureTotalCapacity(gpa, @min(count, 1 << 16));
        x.tee = tee;
        defer x.tee = null;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const offset = tee.position();
            var entry = try x.readHeader(offset);
            entry.data_at = tee.position();
            switch (entry.kind) {
                .whole => try x.inflateWhole(&entry),
                .ofs_delta, .ref_delta => {
                    x.deltas += 1;
                    if (entry.size > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = offset });
                    try x.inflate(entry.size, .discard, null);
                },
            }
            const end = tee.position();
            entry.crc = try x.crcOf(offset, end);
            try x.entries.append(gpa, entry);
            Progress.emit(x.options.progress, .{ .indexed = .{ .done = i + 1, .total = count } });
        }
        return tee.position();
    }

    /// Where each delta's base is.
    fn findBases(x: *Indexer) Error!void {
        const gpa = x.gpa;
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
                    // unreachable: the slice is cut to the format's raw length
                    .base = Oid.fromRaw(x.kind, raw[0..x.kind.rawLen()]) catch unreachable,
                });
            },
            else => return x.fail(error.InvalidPackEntryType, .{ .offset = offset }),
        }
        return entry;
    }

    /// Inflate the entry at the stream's position, which must yield
    /// exactly `size` bytes and then end.
    fn inflate(x: *Indexer, size: u64, sink: Sink, hasher: ?*hash.Hasher) Error!void {
        const source: Source = if (x.tee) |t| .{ .tee = t } else .{ .file = &x.reader };
        return x.inflater.run(source, size, sink, hasher);
    }

    /// Name a whole object as it is inflated. A blob streams through the
    /// hash; a commit, tree or tag is held long enough to be checked.
    fn inflateWhole(x: *Indexer, entry: *Entry) Error!void {
        var hasher: hash.Hasher = .initOptions(x.kind, x.hashOptions());
        hasher.updateHeader(entry.type.name(), entry.size);
        if (entry.type == .blob or (x.options.fsck == null and x.options.links == null)) {
            try x.inflate(entry.size, .{ .hash = &hasher }, null);
            entry.oid = hasher.final();
        } else {
            if (entry.size > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = entry.offset });
            const bytes = try x.gpa.alloc(u8, @intCast(entry.size));
            defer x.gpa.free(bytes);
            try x.inflate(entry.size, .{ .buffer = bytes }, &hasher);
            entry.oid = hasher.final();
            try x.checkObject(entry.oid, entry.type, bytes, entry.offset);
            if (x.options.links) |l| try l.take(x.kind, entry.type, entry.oid, bytes);
        }
        if (hasher.collisionAttack()) return x.fail(error.CollisionAttack, .{ .oid = entry.oid, .offset = entry.offset });
        entry.resolved = true;
    }

    fn hashOptions(x: *const Indexer) hash.Hasher.Options {
        return .{ .detect_collisions = x.db.settings().detect_sha1_collisions };
    }

    fn checkObject(x: *Indexer, oid: Oid, t: object.Type, bytes: []const u8, offset: u64) Error!void {
        const rules = x.options.fsck orelse return;
        // The found blobs are shared by the threads; a tree's own are
        // gathered apart and added under the lock.
        var found: fsck.Found = .{};
        defer found.deinit(x.gpa);
        const finding = try fsck.inspect(x.gpa, rules, x.kind, oid, t, bytes, if (t == .tree) &found else null, x.fsckSink());
        if (t == .tree and (found.modules.count() != 0 or found.attributes.count() != 0)) {
            x.lock.lockUncancelable(x.io);
            defer x.lock.unlock(x.io);
            var it = found.modules.keyIterator();
            while (it.next()) |k| try x.found.modules.put(x.gpa, k.*, {});
            it = found.attributes.keyIterator();
            while (it.next()) |k| try x.found.attributes.put(x.gpa, k.*, {});
        }
        const f = finding orelse return;
        const err: Error = switch (t) {
            .commit => error.MalformedCommit,
            .tree => error.MalformedTree,
            .tag => error.MalformedTag,
            .blob => error.MalformedBlob,
        };
        return x.fail(err, .{ .oid = oid, .problem = f.problem, .offset = offset });
    }

    fn fsckSink(x: *Indexer) ?fsck.Sink {
        if (x.options.warnings == null) return null;
        return .{ .context = x, .warning = noteFinding, .unknown = noteUnknown };
    }

    fn noteFinding(context: *anyopaque, finding: fsck.Finding) Allocator.Error!void {
        const x: *Indexer = @ptrCast(@alignCast(context)); // safe: the context is the Indexer the sink was made from
        x.lock.lockUncancelable(x.io);
        defer x.lock.unlock(x.io);
        try fsck.note(x.options.warnings, finding);
    }

    fn noteUnknown(_: *anyopaque, _: []const u8) Allocator.Error!void {}

    /// Read back and check every blob a tree named as `.gitmodules` or
    /// `.gitattributes`, from the pack or else the database, as git's
    /// `fsck_finish` does once the pack is in.
    fn checkFound(x: *Indexer) Error!void {
        const rules = x.options.fsck orelse return;
        if (x.found.modules.count() == 0 and x.found.attributes.count() == 0) return;
        var by_name: Oid.Map(u32) = .empty;
        defer by_name.deinit(x.gpa);
        try by_name.ensureTotalCapacity(x.gpa, @intCast(x.entries.items.len));
        for (x.entries.items, 0..) |entry, at| by_name.putAssumeCapacity(entry.oid, @intCast(at));
        var w: Worker = try .init(x);
        defer w.deinit();
        for ([_]fsck.Special{ .modules, .attributes }) |as| {
            const set = switch (as) {
                .modules => &x.found.modules,
                .attributes => &x.found.attributes,
            };
            var it = set.keyIterator();
            while (it.next()) |oid_ptr| {
                const oid = oid_ptr.*;
                const finding = if (by_name.get(oid)) |at| blk: {
                    const entry = x.entries.items[at];
                    if (entry.type != .blob) break :blk try fsck.checkFoundObject(rules, oid, as, false, x.fsckSink());
                    if (entry.size > x.options.max_object_bytes) break :blk try fsck.checkBlob(x.gpa, rules, oid, as, null, x.fsckSink());
                    const bytes = try x.readBack(&w, at, by_name);
                    defer x.gpa.free(bytes);
                    break :blk try fsck.checkBlob(x.gpa, rules, oid, as, bytes, x.fsckSink());
                } else if (try x.db.exists(x.io, oid)) blk: {
                    const found = try x.db.read(x.io, oid);
                    defer x.db.allocator().free(found.bytes);
                    if (found.type != .blob) break :blk try fsck.checkFoundObject(rules, oid, as, false, x.fsckSink());
                    break :blk try fsck.checkBlob(x.gpa, rules, oid, as, found.bytes, x.fsckSink());
                } else if (x.options.promised) null else try fsck.checkFoundObject(rules, oid, as, true, x.fsckSink());
                if (finding) |f| return x.fail(error.MalformedBlob, .{ .oid = oid, .problem = f.problem });
            }
        }
    }

    /// git's `sha1_object` check: every object the pack carries that the
    /// database already holds must have the bytes the database holds, or
    /// the pack is refused, whatever the hash and however the detector
    /// above is set. Only names already present cost a read.
    fn checkCollisions(x: *Indexer) Error!void {
        var by_name: Oid.Map(u32) = .empty;
        defer by_name.deinit(x.gpa);
        var w: ?Worker = null;
        defer if (w) |*worker| worker.deinit();
        for (x.entries.items, 0..) |entry, at| {
            if (!try x.db.exists(x.io, entry.oid)) continue;
            const header = try x.db.readHeader(x.io, entry.oid);
            const sized = entry.kind != .whole or header.size == entry.size;
            if (header.type != entry.type or !sized) return x.fail(error.HashCollision, .{ .oid = entry.oid, .offset = entry.offset });
            if (header.size > x.options.max_object_bytes) continue;
            if (w == null) {
                w = try .init(x);
                try by_name.ensureTotalCapacity(x.gpa, @intCast(x.entries.items.len));
                for (x.entries.items, 0..) |e, i| by_name.putAssumeCapacity(e.oid, @intCast(i));
            }
            const ours = try x.readBack(&w.?, @intCast(at), by_name);
            defer x.gpa.free(ours);
            const theirs = try x.db.read(x.io, entry.oid);
            defer x.db.allocator().free(theirs.bytes);
            if (!std.mem.eql(u8, ours, theirs.bytes)) return x.fail(error.HashCollision, .{ .oid = entry.oid, .offset = entry.offset });
        }
    }

    /// The whole object entry `at` holds, read back from the pack: a
    /// delta's base first, as far down as its chain goes.
    fn readBack(x: *Indexer, w: *Worker, at: u32, by_name: Oid.Map(u32)) Error![]u8 {
        const entry = x.entries.items[at];
        const base_at: u32 = switch (entry.kind) {
            .whole => return w.load(at),
            .ofs_delta => x.entryAt(entry.base_offset) orelse return error.BadDeltaOffset,
            .ref_delta => blk: {
                for (x.ref_bases.items) |ref| {
                    if (ref.child != at) continue;
                    if (by_name.get(ref.base)) |base_at| break :blk base_at;
                    // A thin pack's base, which the database holds.
                    const found = try x.db.read(x.io, ref.base);
                    defer x.db.allocator().free(found.bytes);
                    const patch = try w.load(at);
                    defer x.gpa.free(patch);
                    return delta.apply(x.gpa, found.bytes, patch);
                }
                return error.DeltaBaseMissing;
            },
        };
        const base = try x.readBack(w, base_at, by_name);
        defer x.gpa.free(base);
        const patch = try w.load(at);
        defer x.gpa.free(patch);
        return delta.apply(x.gpa, base, patch);
    }

    fn crcOf(x: *Indexer, start: u64, end: u64) Error!u32 {
        var crc: crc32.Crc32 = .init();
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
        /// The object, or nothing while `dropped`.
        bytes: []u8,
        depth: u32,
        next_ofs: usize = 0,
        next_ref: usize = 0,
        /// Whether the bytes were let go to keep within
        /// `Options.delta_base_cache_limit`, and are rebuilt when wanted.
        dropped: bool = false,
    };

    /// How many threads resolve deltas.
    fn threadCount(x: *const Indexer) usize {
        if (x.options.threads != 0) return x.options.threads;
        const cpus = std.Thread.getCpuCount() catch 1;
        return if (cpus < 4) cpus else if (cpus < 6) 3 else if (cpus < 40) cpus / 2 else 20;
    }

    /// Resolve every delta: from each whole object, down every chain, depth
    /// first so that what a thread holds is one chain's objects — the whole
    /// objects shared among as many threads as `threadCount` says, as git's
    /// index-pack shares them — and then from each base a thin pack left
    /// out.
    fn resolve(x: *Indexer) Error!void {
        if (x.deltas == 0) return;
        var roots: std.ArrayList(u32) = .empty;
        defer roots.deinit(x.gpa);
        for (x.entries.items, 0..) |entry, at| {
            if (entry.kind != .whole) continue;
            const index: u32 = @intCast(at);
            if (x.ofsChildren(index).len == 0 and x.refChildren(entry.oid).len == 0) continue;
            try roots.append(x.gpa, index);
        }
        x.roots = try roots.toOwnedSlice(x.gpa);

        const threads = @max(1, @min(x.threadCount(), x.roots.len));
        const workers = try x.gpa.alloc(Worker, threads);
        defer x.gpa.free(workers);
        var made: usize = 0;
        defer for (workers[0..made]) |*w| w.deinit();
        while (made < threads) : (made += 1) workers[made] = try .init(x);

        var group: Io.Group = .init;
        var spawned: usize = 1;
        while (spawned < threads) : (spawned += 1) {
            group.concurrent(x.io, Worker.run, .{&workers[spawned]}) catch break;
        }
        // This thread is a worker too; with no others it is the only one.
        workers[0].run();
        // A failure stops the others at their next object, but one may be
        // waiting in a read. When the failure is this task's cancelation,
        // meeting it used the request up, and nothing else would end that
        // wait; so once anything failed, the others are canceled.
        if (x.failed.load(.acquire)) {
            group.cancel(x.io);
            return x.failure.?;
        }
        group.await(x.io) catch |err| {
            group.cancel(x.io);
            return err;
        };
        if (x.failure) |err| return err;

        // What is left is reference deltas whose base the pack does not
        // carry: a thin pack, completed from the database. A base may also
        // be a delta in the pack that hangs off such a base, so the groups
        // are gone over until a pass resolves nothing more.
        if (x.options.fix_thin) {
            const w = &workers[0];
            var progressed = true;
            while (progressed) {
                progressed = false;
                var i: usize = 0;
                while (i < x.ref_bases.items.len) {
                    const base = x.ref_bases.items[i].base;
                    const group_items = x.refChildren(base);
                    i += group_items.len;
                    var pending = false;
                    for (group_items) |ref| {
                        if (!x.entries.items[ref.child].resolved) pending = true;
                    }
                    if (!pending) continue;
                    if (!try x.db.exists(x.io, base)) continue;
                    const found = try x.db.read(x.io, base);
                    // The database's bytes are its allocator's; the stack
                    // frees with this one.
                    const bytes = x.gpa.dupe(u8, found.bytes) catch |err| {
                        x.db.allocator().free(found.bytes);
                        return err;
                    };
                    x.db.allocator().free(found.bytes);
                    x.thin_bases.append(x.gpa, base) catch |err| {
                        x.gpa.free(bytes);
                        return err;
                    };
                    try w.walk(.{ .at = null, .oid = base, .type = found.type, .bytes = bytes, .depth = 0 });
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

    /// Take a reference delta to resolve: whether no other thread has. A
    /// reference delta hangs from a name, which a damaged pack may carry
    /// twice.
    fn claimRef(x: *Indexer, at: u32) bool {
        x.lock.lockUncancelable(x.io);
        defer x.lock.unlock(x.io);
        const entry = &x.entries.items[at];
        if (entry.resolved or entry.claimed) return false;
        entry.claimed = true;
        return true;
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
            defer x.db.allocator().free(found.bytes);

            var head: [16]u8 = undefined;
            const head_len = encodeTypeAndSize(&head, found.type, found.bytes.len);
            compressed.clearRetainingCapacity();
            compressor.* = try flate.Compress.init(&compressed.writer, x.window, .zlib, .level_6);
            try compressor.writer.writeAll(found.bytes);
            try compressor.writer.flush();
            try compressor.finish();

            var crc: crc32.Crc32 = .init();
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

/// Where a decoded entry goes.
const Sink = union(enum) {
    discard,
    hash: *hash.Hasher,
    buffer: []u8,
};

/// What entries are read from: the stream while it is parsed, a file
/// reader of its own for each thread after.
const Source = union(enum) {
    tee: *Tee,
    file: *Io.File.Reader,

    fn reader(s: Source) *Io.Reader {
        return switch (s) {
            .tee => |t| &t.interface,
            .file => |f| &f.interface,
        };
    }

    fn err(s: Source) ?Error {
        return switch (s) {
            .tee => |t| t.err,
            .file => |f| f.err,
        };
    }
};

/// A decoder and what it decodes into, one to a thread.
const Inflater = struct {
    gpa: Allocator,
    /// relic's own decoder, for every entry that fits in memory whole.
    decoder: *inflate_mod.Decoder,
    /// Where an entry whose bytes are not kept is decoded: a blob being
    /// named, a delta being measured.
    scratch: std.ArrayList(u8) = .empty,
    /// The standard library's window, for an entry too large to hold,
    /// made when one comes.
    window: ?[]u8 = null,

    /// The most bytes an entry whose bytes are not kept is decoded whole
    /// for; a larger one streams through the standard library's decoder.
    const scratch_limit = 16 << 20;

    fn init(gpa: Allocator) Allocator.Error!Inflater {
        const decoder = try gpa.create(inflate_mod.Decoder);
        decoder.* = .{};
        return .{ .gpa = gpa, .decoder = decoder };
    }

    fn deinit(f: *Inflater) void {
        f.gpa.destroy(f.decoder);
        f.scratch.deinit(f.gpa);
        if (f.window) |w| f.gpa.free(w);
        f.* = undefined;
    }

    /// Inflate the entry at `source`'s position, which must yield exactly
    /// `size` bytes and then end.
    fn run(f: *Inflater, source: Source, size: u64, sink: Sink, hasher: ?*hash.Hasher) Error!void {
        const out: ?[]u8 = switch (sink) {
            .buffer => |b| b,
            .discard, .hash => if (size <= scratch_limit) blk: {
                try f.scratch.resize(f.gpa, @intCast(size));
                break :blk f.scratch.items;
            } else null,
        };
        const whole = out orelse return f.streaming(source, size, sink, hasher);
        const n = f.decoder.zlib(source.reader(), whole) catch |err| return switch (err) {
            error.CorruptStream => error.CorruptPackEntry,
            error.OutputTooLong => error.PackEntrySizeMismatch,
            error.EndOfStream => source.err() orelse error.TruncatedPack,
            error.ReadFailed => source.err() orelse error.ReadFailed,
        };
        if (n != size) return error.PackEntrySizeMismatch;
        switch (sink) {
            .hash => |h| h.update(whole),
            .discard, .buffer => {},
        }
        if (hasher) |h| h.update(whole);
    }

    /// `run` for an entry too large to hold whole.
    fn streaming(f: *Inflater, source: Source, size: u64, sink: Sink, hasher: ?*hash.Hasher) Error!void {
        const window = f.window orelse blk: {
            const w = try f.gpa.alloc(u8, flate.max_window_len);
            f.window = w;
            break :blk w;
        };
        var d: flate.Decompress = .init(source.reader(), .zlib, window);
        var chunk: [16 * 1024]u8 = undefined;
        var done: u64 = 0;
        while (true) {
            const remaining = size - done;
            const want: usize = @intCast(@min(@as(u64, chunk.len), remaining + 1));
            const n = d.reader.readSliceShort(chunk[0..want]) catch {
                if (source.err()) |err| return err;
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
                .buffer => |b| @memcpy(b[@intCast(done)..][0..n], got),
            }
            if (hasher) |h| h.update(got);
            done += n;
            if (n < want) break;
        }
        if (done != size) return error.PackEntrySizeMismatch;
    }
};

/// One thread resolving deltas: its own reader of the pack, its own
/// decoder, and the chain it holds.
const Worker = struct {
    x: *Indexer,
    read_buffer: []u8,
    reader: Io.File.Reader,
    inflater: Inflater,
    stack: std.ArrayList(Indexer.Frame) = .empty,
    /// The bytes the frames on `stack` hold.
    held: u64 = 0,

    fn init(x: *Indexer) Allocator.Error!Worker {
        const read_buffer = try x.gpa.alloc(u8, 64 * 1024);
        errdefer x.gpa.free(read_buffer);
        return .{
            .x = x,
            .read_buffer = read_buffer,
            .reader = x.file.reader(x.io, read_buffer),
            .inflater = try .init(x.gpa),
        };
    }

    fn deinit(w: *Worker) void {
        for (w.stack.items) |frame| w.x.gpa.free(frame.bytes);
        w.stack.deinit(w.x.gpa);
        w.inflater.deinit();
        w.x.gpa.free(w.read_buffer);
        w.* = undefined;
    }

    /// Take whole objects and resolve what hangs from each until none is
    /// left, or a thread has failed.
    fn run(w: *Worker) void {
        const x = w.x;
        while (!x.failed.load(.acquire)) {
            const next = x.next_root.fetchAdd(1, .monotonic);
            if (next >= x.roots.len) return;
            const index = x.roots[next];
            const entry = x.entries.items[index];
            w.walkFrom(index, entry) catch |err| {
                x.lock.lockUncancelable(x.io);
                defer x.lock.unlock(x.io);
                if (x.failure == null) x.failure = err;
                x.failed.store(true, .release);
                return;
            };
        }
    }

    fn walkFrom(w: *Worker, index: u32, entry: Entry) Error!void {
        const bytes = try w.load(index);
        try w.walk(.{ .at = index, .oid = entry.oid, .type = entry.type, .bytes = bytes, .depth = 0 });
    }

    /// The bytes of the entry at `at`, inflated. For a delta, the delta.
    fn load(w: *Worker, at: u32) Error![]u8 {
        const x = w.x;
        const entry = x.entries.items[at];
        if (entry.size > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = entry.offset });
        const bytes = try x.gpa.alloc(u8, @intCast(entry.size));
        errdefer x.gpa.free(bytes);
        w.reader.seekTo(entry.data_at) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedPack,
            error.ReadFailed => return w.reader.err orelse error.ReadFailed,
            else => return error.TruncatedPack,
        };
        try w.inflater.run(.{ .file = &w.reader }, entry.size, .{ .buffer = bytes }, null);
        return bytes;
    }

    /// Resolve everything below `root`, which the stack takes ownership of.
    fn walk(w: *Worker, root: Indexer.Frame) Error!void {
        const x = w.x;
        const stack = &w.stack;
        stack.append(x.gpa, root) catch |err| {
            x.gpa.free(root.bytes);
            return err;
        };
        w.held += root.bytes.len;
        while (stack.items.len != 0) {
            if (x.failed.load(.monotonic)) return;
            const top = &stack.items[stack.items.len - 1];
            const ofs = if (top.at) |at| x.ofsChildren(at) else &.{};
            const refs = x.refChildren(top.oid);
            var child: ?u32 = null;
            while (child == null) {
                if (top.next_ofs < ofs.len) {
                    // An offset delta hangs from one entry, whose thread
                    // alone comes to it.
                    const candidate = ofs[top.next_ofs].child;
                    top.next_ofs += 1;
                    if (!x.entries.items[candidate].resolved) child = candidate;
                } else if (top.next_ref < refs.len) {
                    const candidate = refs[top.next_ref].child;
                    top.next_ref += 1;
                    if (x.claimRef(candidate)) child = candidate;
                } else break;
            }
            const at = child orelse {
                const done = stack.pop().?;
                w.held -= done.bytes.len;
                x.gpa.free(done.bytes);
                continue;
            };
            const entry = &x.entries.items[at];
            if (top.depth + 1 > x.options.max_delta_depth) return x.fail(error.DeltaChainTooDeep, .{ .offset = entry.offset });
            try w.rebuild(stack.items.len - 1);

            const patch = try w.load(at);
            defer x.gpa.free(patch);
            const sizes = try delta.header(patch);
            if (sizes.target > x.options.max_object_bytes) return x.fail(error.ObjectTooLarge, .{ .offset = entry.offset });
            const bytes = delta.apply(x.gpa, top.bytes, patch) catch |err| return x.fail(err, .{ .offset = entry.offset });
            var keep = false;
            defer if (!keep) x.gpa.free(bytes);

            const named = hash.Hasher.nameObject(x.kind, x.hashOptions(), top.type.name(), bytes);
            if (named.collision_attack) return x.fail(error.CollisionAttack, .{ .oid = named.oid, .offset = entry.offset });
            entry.oid = named.oid;
            entry.type = top.type;
            entry.resolved = true;
            try x.checkObject(named.oid, top.type, bytes, entry.offset);
            {
                x.lock.lockUncancelable(x.io);
                defer x.lock.unlock(x.io);
                if (x.options.links) |l| try l.take(x.kind, top.type, named.oid, bytes);
                const done = x.resolved_count.fetchAdd(1, .monotonic) + 1;
                Progress.emit(x.options.progress, .{ .resolved = .{ .done = done, .total = x.deltas } });
            }

            if (x.ofsChildren(at).len != 0 or x.refChildren(named.oid).len != 0) {
                const depth = top.depth + 1;
                try stack.append(x.gpa, .{ .at = at, .oid = named.oid, .type = entry.type, .bytes = bytes, .depth = depth });
                keep = true;
                w.held += bytes.len;
                w.prune(stack.items.len - 1);
            }
        }
    }

    /// Let go of the oldest bases on the stack until what it holds is
    /// within `Options.delta_base_cache_limit`, keeping the frame at
    /// `keep` and every one a thin pack took from the database, which is
    /// not rebuilt.
    fn prune(w: *Worker, keep: usize) void {
        const x = w.x;
        for (w.stack.items, 0..) |*frame, i| {
            if (w.held <= x.options.delta_base_cache_limit) return;
            if (i == keep or frame.dropped or frame.at == null) continue;
            w.held -= frame.bytes.len;
            x.gpa.free(frame.bytes);
            frame.bytes = &.{};
            frame.dropped = true;
        }
    }

    /// Give the frame at `index` its bytes again if they were let go: from
    /// the nearest frame below it that still has its own, a delta applied
    /// at each step, or from the pack for a whole object at the bottom.
    /// Each step's base is let go behind it while over the limit.
    fn rebuild(w: *Worker, index: usize) Error!void {
        const x = w.x;
        const frames = w.stack.items;
        if (!frames[index].dropped) return;
        var from = index;
        while (from > 0 and frames[from].dropped) from -= 1;
        if (frames[from].dropped) {
            // A whole object, read from the pack again.
            frames[from].bytes = try w.load(frames[from].at.?);
            frames[from].dropped = false;
            w.held += frames[from].bytes.len;
        }
        var k = from;
        while (k < index) : (k += 1) {
            const patch = try w.load(frames[k + 1].at.?);
            defer x.gpa.free(patch);
            const bytes = delta.apply(x.gpa, frames[k].bytes, patch) catch |err| return x.fail(err, .{ .offset = x.entries.items[frames[k + 1].at.?].offset });
            frames[k + 1].bytes = bytes;
            frames[k + 1].dropped = false;
            w.held += bytes.len;
            w.prune(k + 1);
        }
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
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const repo_mod = @import("../repo.zig");

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
        // One copy from offset zero, its size in as many of the three size
        // bytes as it needs.
        std.debug.assert(base_len < 1 << 24);
        var op: u8 = 0x80 | 0x01;
        var size_bytes: [3]u8 = undefined;
        var n: usize = 0;
        for (0..3) |i| {
            const byte: u8 = @truncate(base_len >> @intCast(8 * i));
            if (byte == 0) continue;
            op |= @as(u8, 0x10) << @intCast(i);
            size_bytes[n] = byte;
            n += 1;
        }
        try out.append(gpa, op);
        try out.append(gpa, 0);
        try out.appendSlice(gpa, size_bytes[0..n]);
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

test "a pack git wrote is received, and its index is byte for byte the one git wrote, with one thread resolving its deltas or several" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_][]const u8{ "true", "false", "true", "false" }, [_]u32{ 1, 1, 4, 4 }) |offsets, threads| {
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
        const result = try receive(gpa, io, &repo.odb, pack_dir, &in, .{ .threads = threads });
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

    // git chooses the shape of the fixture above. Four independent bases
    // with one delta each give this test control over the task count.
    const Tasks = @import("../testing/io.zig");
    var single: Io.Threaded = .init_single_threaded;
    const bases = [_][]const u8{ "base 0", "base 1", "base 2", "base 3" };
    const patch = try appendDelta(gpa, bases[0].len, "more\n");
    defer gpa.free(patch);
    for ([_]bool{ false, true }) |references| {
        var entries: [8]TestEntry = undefined;
        for (bases, 0..) |base_bytes, i| {
            entries[2 * i] = .{ .whole = .{ .t = .blob, .bytes = base_bytes } };
            entries[2 * i + 1] = if (references)
                .{ .ref_delta = .{ .base = hash.Hasher.object(.sha1, "blob", base_bytes), .patch = patch } }
            else
                .{ .ofs_delta = .{ .back = 1, .patch = patch } };
        }
        const bytes = try buildPack(gpa, .sha1, &entries);
        defer gpa.free(bytes);
        var serial_index: ?[]u8 = null;
        defer if (serial_index) |index| gpa.free(index);
        var serial_result: Result = undefined;
        for ([_]Io{ io, single.io() }, 0..) |each_io, executor| {
            for ([_]u32{ 1, 2, 4, 8 }) |threads| {
                var tmp = testing.tmpDir(.{ .iterate = true });
                defer tmp.cleanup();
                var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
                defer repo.deinit(io);
                var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
                defer pack_dir.close(io);
                var in: Io.Reader = .fixed(bytes);
                const counted = if (executor == 0) Tasks.wrap(each_io) else Tasks.wrapInline(each_io);
                const result = try receive(gpa, counted, &repo.odb, pack_dir, &in, .{ .threads = threads });
                // The caller resolves too, and there are only four roots.
                try Tasks.expect(0, @min(threads, 4) - 1);
                try testing.expectEqual(@as(u32, 8), result.objects);
                try testing.expectEqual(@as(u32, 4), result.deltas);
                try testing.expectEqual(@as(u32, 0), result.appended);
                const base = try onlyPack(gpa, io, pack_dir);
                defer gpa.free(base);
                const idx_name = try std.fmt.allocPrint(gpa, "{s}.idx", .{base});
                defer gpa.free(idx_name);
                const index = try pack_dir.readFileAlloc(io, idx_name, gpa, .unlimited);
                if (serial_index) |want| {
                    defer gpa.free(index);
                    try testing.expectEqualDeep(serial_result, result);
                    try testing.expectEqualSlices(u8, want, index);
                } else {
                    serial_index = index;
                    serial_result = result;
                }
            }
        }
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
    try target.exec(io, &.{ "index-pack", "--rev-index", "-o", "check.idx", pack_path });
    const ours = try target.readFile(io, idx_path);
    defer gpa.free(ours);
    const theirs = try target.readFile(io, "check.idx");
    defer gpa.free(theirs);
    try testing.expectEqualSlices(u8, theirs, ours);
    // And the reverse index beside it, as git's index-pack writes it.
    const rev_path = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.rev", .{result.name.?.hex(&hex)});
    defer gpa.free(rev_path);
    const our_rev = try target.readFile(io, rev_path);
    defer gpa.free(our_rev);
    const their_rev = try target.readFile(io, "check.rev");
    defer gpa.free(their_rev);
    try testing.expectEqualSlices(u8, their_rev, our_rev);
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
    const kept = try receive(gpa, io, &repo.odb, pack_dir, &unchecked, .{ .fsck = null });
    try testing.expectEqual(@as(u32, 2), kept.objects);
}

test "a pack is refused where git's index-pack --fsck-objects refuses it, at the levels it is given" {
    const gpa = testing.allocator;
    const io = testing.io;
    // `.gitattributes` is checked from 2.40 on.
    try testgit.requireGitVersion(gpa, io, 2, 40);
    var git = try testgit.Repo.init(gpa, io, &.{"--bare"});
    defer git.deinit();

    const zero_hex = "0" ** 40;
    const ident = "A <a@example.com> 1700000000 +0000";
    const blob_oid = hash.Hasher.object(.sha1, "blob", "x\n");
    const modules_base = "[submodule \"a\"]\n\tpath = a\n";
    const modules_text = modules_base ++ "\turl = -u/x\n";
    const modules_oid = hash.Hasher.object(.sha1, "blob", modules_text);
    const modules_delta = try appendDelta(gpa, modules_base.len, "\turl = -u/x\n");
    defer gpa.free(modules_delta);
    const attributes_text = "a" ** 2100 ++ " text\n";
    const attributes_oid = hash.Hasher.object(.sha1, "blob", attributes_text);

    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(gpa);
    try padded.appendSlice(gpa, "0100644 a\x00");
    try padded.appendSlice(gpa, blob_oid.raw());
    var with_modules: std.ArrayList(u8) = .empty;
    defer with_modules.deinit(gpa);
    try with_modules.appendSlice(gpa, "100644 .gitmodules\x00");
    try with_modules.appendSlice(gpa, modules_oid.raw());
    var with_attributes: std.ArrayList(u8) = .empty;
    defer with_attributes.deinit(gpa);
    try with_attributes.appendSlice(gpa, "100644 .gitattributes\x00");
    try with_attributes.appendSlice(gpa, attributes_oid.raw());

    const Case = struct { entries: []const TestEntry, levels: []const u8, problem: ?fsck.Problem };
    const bad_tz: TestEntry = .{ .whole = .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ ident ++ "\ncommitter A <a@example.com> 1 +00\n\nm\n" } };
    const unparsable: TestEntry = .{ .whole = .{ .t = .commit, .bytes = "tree 123\nauthor " ++ ident ++ "\ncommitter " ++ ident ++ "\n\nm\n" } };
    const no_tagger: TestEntry = .{ .whole = .{ .t = .tag, .bytes = "object " ++ zero_hex ++ "\ntype commit\ntag v1\n\nold\n" } };
    const blob: TestEntry = .{ .whole = .{ .t = .blob, .bytes = "x\n" } };
    const modules_entries = [_]TestEntry{
        .{ .whole = .{ .t = .blob, .bytes = modules_base } },
        .{ .ofs_delta = .{ .back = 1, .patch = modules_delta } },
        .{ .whole = .{ .t = .tree, .bytes = with_modules.items } },
    };
    const attributes_entries = [_]TestEntry{
        .{ .whole = .{ .t = .tree, .bytes = with_attributes.items } },
        .{ .whole = .{ .t = .blob, .bytes = attributes_text } },
    };
    const padded_entries = [_]TestEntry{ blob, .{ .whole = .{ .t = .tree, .bytes = padded.items } } };
    const cases = [_]Case{
        .{ .entries = &padded_entries, .levels = "", .problem = .zero_padded_filemode },
        .{ .entries = &padded_entries, .levels = "zeroPaddedFilemode=ignore", .problem = null },
        .{ .entries = &.{bad_tz}, .levels = "", .problem = .bad_timezone },
        .{ .entries = &.{bad_tz}, .levels = "badTimezone=warn", .problem = null },
        // git's parser refuses it before any level is looked at.
        .{ .entries = &.{unparsable}, .levels = "badTreeSha1=ignore", .problem = null },
        .{ .entries = &.{no_tagger}, .levels = "", .problem = null },
        .{ .entries = &.{no_tagger}, .levels = "missingTaggerEntry=error", .problem = .missing_tagger_entry },
        .{ .entries = &modules_entries, .levels = "", .problem = .gitmodules_url },
        .{ .entries = &modules_entries, .levels = "gitmodulesUrl=warn", .problem = null },
        .{ .entries = &attributes_entries, .levels = "", .problem = .gitattributes_line_length },
    };
    for (cases, 0..) |case, n| {
        const bytes = try buildPack(gpa, .sha1, case.entries);
        defer gpa.free(bytes);

        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "case{d}.pack", .{n});
        try git.writeFile(io, name, bytes);
        var arg_buf: [128]u8 = undefined;
        const arg = if (case.levels.len == 0) "--fsck-objects" else try std.fmt.bufPrint(&arg_buf, "--fsck-objects={s}", .{case.levels});
        var said = try git.capture(io, &.{ "index-pack", arg, name });
        defer said.deinit(gpa);
        const git_refused = said.code != 0;

        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
        defer repo.deinit(io);
        var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
        defer pack_dir.close(io);
        var rules: fsck.Rules = .{ .strict = true };
        defer rules.deinit(gpa);
        var levels = std.mem.tokenizeScalar(u8, case.levels, ',');
        while (levels.next()) |pair| {
            const eq = std.mem.findScalar(u8, pair, '=').?;
            const lowered = try std.ascii.allocLowerString(gpa, pair[0..eq]);
            defer gpa.free(lowered);
            try rules.set(lowered, pair[eq + 1 ..]);
        }
        var diagnostic: Diagnostic = .{};
        var in: Io.Reader = .fixed(bytes);
        const refused = if (receive(gpa, io, &repo.odb, pack_dir, &in, .{ .fsck = &rules, .diagnostic = &diagnostic })) |_| false else |err| switch (err) {
            error.MalformedCommit, error.MalformedTree, error.MalformedTag, error.MalformedBlob => true,
            else => return err,
        };
        if (refused != git_refused) {
            std.debug.print("case {d}: relic refused {}, git refused {} ({s})\n", .{ n, refused, git_refused, said.stderr });
            return error.TestUnexpectedResult;
        }
        if (case.problem) |problem| {
            try testing.expectEqual(problem, diagnostic.problem.?);
            try testing.expect(std.mem.find(u8, said.stderr, problem.id()) != null);
        }
        if (refused) try testing.expectEqual(@as(usize, 0), try countEntries(io, pack_dir));
    }
}

test "a .gitmodules a tree names and nobody has is refused unless promised" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    var tree: std.ArrayList(u8) = .empty;
    defer tree.deinit(gpa);
    try tree.appendSlice(gpa, "100644 .gitmodules\x00");
    try tree.appendSlice(gpa, hash.Hasher.object(.sha1, "blob", "absent\n").raw());
    const bytes = try buildPack(gpa, .sha1, &.{.{ .whole = .{ .t = .tree, .bytes = tree.items } }});
    defer gpa.free(bytes);
    const strict: fsck.Rules = .{ .strict = true };
    var diagnostic: Diagnostic = .{};
    var in: Io.Reader = .fixed(bytes);
    try testing.expectError(error.MalformedBlob, receive(gpa, io, &repo.odb, pack_dir, &in, .{ .fsck = &strict, .diagnostic = &diagnostic }));
    try testing.expectEqual(fsck.Problem.gitmodules_missing, diagnostic.problem.?);
    var promised: Io.Reader = .fixed(bytes);
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    _ = try receive(gpa, io, &repo.odb, pack_dir, &promised, .{ .fsck = &strict, .promised = true, .warnings = &warnings });
    try testing.expectEqual(@as(usize, 0), warnings.items.items.len);
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

/// An allocator that remembers the most it ever held at once.
const Peak = struct {
    child: Allocator,
    held: usize = 0,
    most: usize = 0,

    fn allocator(p: *Peak) Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn note(p: *Peak, grown: usize, shrunk: usize) void {
        p.held = p.held + grown - shrunk;
        p.most = @max(p.most, p.held);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx)); // safe: only `allocator` hands this pointer out
        const out = p.child.rawAlloc(len, alignment, ret) orelse return null;
        p.note(len, 0);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const p: *Peak = @ptrCast(@alignCast(ctx)); // safe: only `allocator` hands this pointer out
        if (!p.child.rawResize(memory, alignment, len, ret)) return false;
        p.note(len, memory.len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx)); // safe: only `allocator` hands this pointer out
        const out = p.child.rawRemap(memory, alignment, len, ret) orelse return null;
        p.note(len, memory.len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const p: *Peak = @ptrCast(@alignCast(ctx)); // safe: only `allocator` hands this pointer out
        p.child.rawFree(memory, alignment, ret);
        p.note(0, memory.len);
    }
};

test "a chain of large bases resolves within the base budget, rebuilding the ones let go" {
    // Four times the chain, and no more held at once: the bases past the
    // budget are let go, where every one was held to the end of its chain.
    const short = try receiveChain(10, 0);
    const long = try receiveChain(40, 1);
    try testing.expect(long < short + 2 * 64 * 1024);
}

/// Receive a 64 KiB base and a chain of `chain` deltas each a byte longer,
/// with a second child hanging from the first delta, under a budget of
/// 100 KiB; check what it holds, and say the most the receive held at once.
/// Walking back to the second child needs a base the budget let go.
fn receiveChain(chain: usize, seed: u8) !usize {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const base_len = 64 * 1024;
    const base = try gpa.alloc(u8, base_len);
    defer gpa.free(base);
    for (base, 0..) |*b, i| b.* = @truncate(i *% 7 +% seed);
    var entries: std.ArrayList(TestEntry) = .empty;
    defer entries.deinit(gpa);
    var patches: std.ArrayList([]u8) = .empty;
    defer {
        for (patches.items) |p| gpa.free(p);
        patches.deinit(gpa);
    }
    try entries.append(gpa, .{ .whole = .{ .t = .blob, .bytes = base } });
    for (0..chain) |i| {
        const patch = try appendDelta(gpa, base_len + i, "x");
        try patches.append(gpa, patch);
        try entries.append(gpa, .{ .ofs_delta = .{ .back = 1, .patch = patch } });
    }
    const side = try appendDelta(gpa, base_len + 1, "side");
    try patches.append(gpa, side);
    try entries.append(gpa, .{ .ofs_delta = .{ .back = chain, .patch = side } });
    const bytes = try buildPack(gpa, .sha1, entries.items);
    defer gpa.free(bytes);

    var in: Io.Reader = .fixed(bytes);
    var peak: Peak = .{ .child = gpa };
    const result = try receive(peak.allocator(), io, &repo.odb, pack_dir, &in, .{ .delta_base_cache_limit = 100 * 1024, .threads = 1 });
    try testing.expectEqual(@as(u32, @intCast(chain + 2)), result.objects);
    const expected = try gpa.alloc(u8, base_len + chain + "side".len);
    defer gpa.free(expected);
    @memcpy(expected[0..base_len], base);
    @memset(expected[base_len..][0..chain], 'x');
    const last = try repo.odb.read(io, hash.Hasher.object(.sha1, "blob", expected[0 .. base_len + chain]));
    defer gpa.free(last.bytes);
    try testing.expectEqualSlices(u8, expected[0 .. base_len + chain], last.bytes);
    @memcpy(expected[base_len + 1 ..][0.."side".len], "side");
    const branched = expected[0 .. base_len + 1 + "side".len];
    const found = try repo.odb.read(io, hash.Hasher.object(.sha1, "blob", branched));
    defer gpa.free(found.bytes);
    try testing.expectEqualSlices(u8, branched, found.bytes);
    return peak.most;
}

test "an object the database holds under the same name with other bytes is refused, as git's index-pack refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    // The name of `base`, holding other bytes of the same type and size:
    // what a collision would look like from here, made the way git's own
    // test makes it.
    const oid = hash.Hasher.object(.sha1, "blob", "base");
    var hex: [hash.max_hex_len]u8 = undefined;
    const text = oid.hex(&hex);
    const loose_path = try std.fmt.allocPrint(gpa, "objects/{s}/{s}", .{ text[0..2], text[2..] });
    defer gpa.free(loose_path);
    try tmp.dir.createDirPath(io, loose_path[0.."objects/xx".len]);
    {
        var compressed: Io.Writer.Allocating = try .initCapacity(gpa, 256);
        defer compressed.deinit();
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var compress = try flate.Compress.init(&compressed.writer, window, .zlib, .level_1);
        try compress.writer.writeAll("blob 4\x00evil");
        try compress.writer.flush();
        try compress.finish();
        try tmp.dir.writeFile(io, .{ .sub_path = loose_path, .data = compressed.written() });
    }

    const patch = try appendDelta(gpa, 4, "more\n");
    defer gpa.free(patch);
    for ([_][]const TestEntry{
        &.{.{ .whole = .{ .t = .blob, .bytes = "base" } }},
        // The same object reached through a delta.
        &.{ .{ .whole = .{ .t = .blob, .bytes = "ba" } }, .{ .ofs_delta = .{ .back = 1, .patch = "\x02\x04\x90\x02\x02se" } } },
    }) |shape| {
        const bytes = try buildPack(gpa, .sha1, shape);
        defer gpa.free(bytes);
        var diagnostic: Diagnostic = .{};
        var in: Io.Reader = .fixed(bytes);
        try testing.expectError(error.HashCollision, receive(gpa, io, &repo.odb, pack_dir, &in, .{ .diagnostic = &diagnostic }));
        try testing.expect(diagnostic.oid.?.eql(oid));
        try testing.expectEqual(@as(usize, 0), try countEntries(io, pack_dir));
    }

    // The same bytes under the same name are no collision.
    const same = try buildPack(gpa, .sha1, &.{.{ .whole = .{ .t = .blob, .bytes = "evil" } }});
    defer gpa.free(same);
    var in: Io.Reader = .fixed(same);
    const evil = hash.Hasher.object(.sha1, "blob", "evil");
    _ = try repo.odb.write(io, .blob, "evil");
    _ = try receive(gpa, io, &repo.odb, pack_dir, &in, .{});
    try testing.expect(try repo.odb.exists(io, evil));
}

test "a pack added in front of an alternate's never reads that pack's cached delta bases" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "theirs");
    try tmp.dir.createDirPath(io, "ours");
    var theirs_dir = try tmp.dir.openDir(io, "theirs", .{ .iterate = true });
    defer theirs_dir.close(io);
    var ours_dir = try tmp.dir.openDir(io, "ours", .{ .iterate = true });
    defer ours_dir.close(io);
    var theirs = try repo_mod.Repository.init(gpa, io, theirs_dir, .{ .bare = true });
    defer theirs.deinit(io);
    var ours = try repo_mod.Repository.init(gpa, io, ours_dir, .{ .bare = true });
    defer ours.deinit(io);

    // Two packs of one shape: a base at offset 12 and a delta on it, so
    // their bases are cached under the same offset.
    const patch = try appendDelta(gpa, 4, "1");
    defer gpa.free(patch);
    var packs: [2][]u8 = undefined;
    for (&packs, [_][]const u8{ "AAAA", "BBBB" }) |*p, base| p.* = try buildPack(gpa, .sha1, &.{
        .{ .whole = .{ .t = .blob, .bytes = base } },
        .{ .ofs_delta = .{ .back = 1, .patch = patch } },
    });
    defer for (packs) |p| gpa.free(p);
    {
        var pack_dir = try theirs_dir.openDir(io, "objects/pack", .{ .iterate = true });
        defer pack_dir.close(io);
        var in: Io.Reader = .fixed(packs[0]);
        _ = try receive(gpa, io, &theirs.odb, pack_dir, &in, .{});
    }
    const their_objects = try theirs_dir.realPathFileAlloc(io, "objects", gpa);
    defer gpa.free(their_objects);
    try ours.odb.addAlternate(io, their_objects);

    const a = try ours.odb.read(io, hash.Hasher.object(.sha1, "blob", "AAAA1"));
    defer gpa.free(a.bytes);
    try testing.expectEqualStrings("AAAA1", a.bytes);

    // Our own pack now comes before the alternate's.
    var pack_dir = try ours_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var in: Io.Reader = .fixed(packs[1]);
    _ = try receive(gpa, io, &ours.odb, pack_dir, &in, .{});
    const b = try ours.odb.read(io, hash.Hasher.object(.sha1, "blob", "BBBB1"));
    defer gpa.free(b.bytes);
    try testing.expectEqualStrings("BBBB1", b.bytes);
}

/// A pack read that, once armed, parks until the task it runs on is
/// canceled: first on a task resolving beside the calling one, then on the
/// calling task itself, so the cancel reaches the caller while another task
/// waits in a read.
const Park = struct {
    var base: Io = undefined;
    var caller: std.Thread.Id = undefined;
    var armed: std.atomic.Value(bool) = .init(false);
    var beside: std.atomic.Value(bool) = .init(false);
    var on_caller: std.atomic.Value(bool) = .init(false);
    var beside_canceled: std.atomic.Value(bool) = .init(false);

    fn read(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        if (armed.load(.acquire)) {
            if (std.Thread.getCurrentId() != caller) {
                // Only the resolving tasks read on another thread.
                if (beside.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                    wait() catch |err| {
                        beside_canceled.store(true, .release);
                        return err;
                    };
                    return error.Unexpected;
                }
            } else if (beside.load(.acquire) and on_caller.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                try wait();
                return error.Unexpected;
            }
        }
        return base.vtable.fileReadPositional(userdata, file, data, offset);
    }

    /// Until canceled, a short sleep at a time, since a sleep may also end
    /// early; twenty seconds is a hang, not a pass.
    fn wait() Io.Cancelable!void {
        for (0..2000) |_| try base.sleep(.fromMilliseconds(10), .awake);
    }

    fn receiveOn(gpa: Allocator, io: Io, db: *odb_mod.Odb, pack_dir: Io.Dir, bytes: []const u8) Error!Result {
        caller = std.Thread.getCurrentId();
        armed.store(true, .release);
        defer armed.store(false, .release);
        var in: Io.Reader = .fixed(bytes);
        return receive(gpa, io, db, pack_dir, &in, .{ .threads = 3 });
    }
};

test "a receive canceled while it resolves stops every resolving task, even one waiting in a read" {
    const gpa = testing.allocator;
    // Its own Io, as the pack writer's cancel test has, with two tasks
    // besides the calling one.
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    Park.base = io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .bare = true });
    defer repo.deinit(io);
    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    // Many whole objects, each with a delta and then an object larger than
    // a resolving task's read buffer, so every whole object is a read of
    // its own, and the calling task is still reading when another parks.
    const pairs = 128;
    const filler_len = 80 * 1024;
    const patch = try appendDelta(gpa, 12, "more\n");
    defer gpa.free(patch);
    const fillers = try gpa.alloc(u8, pairs * filler_len);
    defer gpa.free(fillers);
    var prng: std.Random.DefaultPrng = .init(7);
    prng.random().bytes(fillers);
    var names: [pairs][12]u8 = undefined;
    var entries: [3 * pairs]TestEntry = undefined;
    for (0..pairs) |i| {
        _ = std.fmt.bufPrint(&names[i], "base {d:0>6}\n", .{i}) catch unreachable;
        entries[3 * i] = .{ .whole = .{ .t = .blob, .bytes = &names[i] } };
        entries[3 * i + 1] = .{ .ofs_delta = .{ .back = 1, .patch = patch } };
        entries[3 * i + 2] = .{ .whole = .{ .t = .blob, .bytes = fillers[i * filler_len ..][0..filler_len] } };
    }
    const bytes = try buildPack(gpa, .sha1, &entries);
    defer gpa.free(bytes);

    var vtable = io.vtable.*;
    vtable.fileReadPositional = Park.read;
    const parked: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    Park.beside.store(false, .release);
    Park.on_caller.store(false, .release);
    Park.beside_canceled.store(false, .release);
    var future = try io.concurrent(Park.receiveOn, .{ gpa, parked, &repo.odb, pack_dir, bytes });
    for (0..20_000) |_| {
        if (Park.on_caller.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else {
        // ziglint-ignore: Z026 the test fails next; a task that will not cancel is reported by the leak check
        _ = future.cancel(io) catch {};
        std.debug.print("the calling task never read after another task parked (beside: {})\n", .{Park.beside.load(.acquire)});
        return error.TestUnexpectedResult;
    }
    const started = Io.Clock.awake.now(io);
    try testing.expectError(error.Canceled, future.cancel(io));
    // The task that waited was canceled too, rather than left to its wait.
    if (!Park.beside_canceled.load(.acquire)) {
        const waited = started.durationTo(Io.Clock.awake.now(io));
        std.debug.print("the task waiting in a read was left to its wait: the cancel took {d} ms\n", .{waited.toMilliseconds()});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 0), try countEntries(io, pack_dir));

    // Unarmed, the same stream is received whole.
    var in: Io.Reader = .fixed(bytes);
    const result = try receive(gpa, io, &repo.odb, pack_dir, &in, .{ .threads = 3 });
    try testing.expectEqual(@as(u32, 3 * pairs), result.objects);
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
    defer objects.close(io);
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

test "the names a pack holds are collected as it is indexed, and one that is nowhere is found without reading the pack again" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try historyRepo(gpa, io, 2);
    defer source.deinit();
    // A commit and its tree, and none of the tree's blobs.
    const commit = try source.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit);
    const tree = try source.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree);
    const listing = try std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ commit, tree });
    defer gpa.free(listing);
    const bytes = try testremote.gitInput(gpa, io, source.dir, &.{ "pack-objects", "--stdout", "-q" }, listing);
    defer gpa.free(bytes);

    var target = try testgit.Repo.init(gpa, io, &.{"--bare"});
    defer target.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, target.dir, .{});
    defer repo.deinit(io);
    var pack_dir = try target.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var links: Links = .init(gpa);
    defer links.deinit();
    var in: Io.Reader = .fixed(bytes);
    const result = try receive(gpa, io, &repo.odb, pack_dir, &in, .{ .fsck = null, .links = &links });
    var hex: [hash.max_hex_len]u8 = undefined;
    var idx_buf: [96]u8 = undefined;
    const idx_name = try std.fmt.bufPrint(&idx_buf, "pack-{s}.idx", .{result.name.?.hex(&hex)});
    var index = try pack.Index.open(gpa, io, pack_dir, idx_name, repo.objectFormat(), 1 << 30);
    defer index.deinit();
    try testing.expect(!links.unreadable);
    // The commit's parent is not there either; what the tree names is
    // looked for first.
    const missing = (try links.firstMissing(io, &repo.odb, &index)).?;
    const ls = try source.run(io, &.{ "ls-tree", "-r", "-t", "HEAD" });
    defer gpa.free(ls);
    try testing.expect(std.mem.find(u8, ls, missing.hex(&hex)) != null);
}
