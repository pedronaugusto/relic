//! The object database: loose objects, the packs, and `objects/info/alternates`.
//!
//! Reading takes an allocator and gives the caller the bytes. Writing goes
//! through a uniquely-named temporary and a rename, so two writers of the same
//! object never meet and a reader never sees half of one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

const hash = @import("hash.zig");
const object = @import("object.zig");
const pack = @import("pack.zig");
const delta_mod = @import("delta.zig");
const midx_mod = @import("midx.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// How the object database behaves. The only caches in this package are
/// named here.
pub const Options = struct {
    /// How many bytes of resolved delta bases to keep. Zero disables the
    /// cache, which makes a walk over a packed repository quadratic in its
    /// chain length and is almost never what you want.
    delta_cache_bytes: usize = 16 * 1024 * 1024,
    /// Whether packs are reached through a memory map where the platform has
    /// one. Off by default: a map is faster on a cold cache, and it turns an
    /// IO error into a signal nobody can catch and holds the file open
    /// against a `git gc` that wants to replace it. Both of those are the
    /// property this package exists to keep.
    map_packs: bool = false,
    /// How hard a loose object is pushed towards the disk. git's own default
    /// syncs neither loose objects nor the index; `batch` gives real
    /// durability for one barrier per batch rather than one per object, and
    /// `Odb.syncBatch` is that barrier.
    sync: fs.Sync = .none,
    /// Whether to make a directory entry durable after a rename. git does
    /// not; the guarantee it adds is one git does not make.
    sync_directories: bool = fs.sync_directories_default,
    /// The buffer size a streaming read uses.
    read_buffer_size: usize = 64 * 1024,
    /// How deep a delta chain may be before it is refused.
    max_delta_depth: u32 = pack.default_max_depth,
    /// How many levels of `objects/info/alternates` to follow.
    max_alternate_depth: u8 = 5,
    /// The largest loose object this will read into memory.
    max_object_bytes: usize = 1 << 31,
    /// Whether to measure, at open, how fine a modification time the
    /// filesystem under `objects` records.
    ///
    /// On, because the answer decides whether a stat shortcut may believe an
    /// entry's nanoseconds, and neither answer is safe to assume. It costs
    /// one file created, written to three times and removed. Off for a
    /// caller that will not have anything written into that directory.
    probe_timestamp_resolution: bool = true,
    /// Whether every SHA-1 name this database takes is additionally checked
    /// for the signature of a collision attack, which is
    /// `error.CollisionAttack`.
    ///
    /// Off. It costs about five times the hash, and what it guards is git's
    /// object format rather than a file on the disk: the published colliding
    /// documents are not colliding objects, because `"blob <size>\0"` goes
    /// in front of the content and moves every block of the message. A
    /// SHA-256 repository ignores it.
    detect_sha1_collisions: bool = false,
};

/// Errors from the object database.
pub const Error = error{
    /// No loose object and no pack holds it, after one pack refresh.
    ObjectNotFound,
    /// A loose object whose inflated bytes do not match its own header.
    CorruptLooseObject,
    /// A loose object whose content does not hash to its own name.
    ObjectNameMismatch,
    /// Bytes carrying the signature of a SHA-1 collision attack, from a
    /// database opened with `Options.detect_sha1_collisions`. The object is
    /// not written.
    CollisionAttack,
    /// An object read back as a type the caller did not ask for.
    UnexpectedObjectType,
    /// `objects/info/alternates` pointed at itself, or the chain was deeper
    /// than `Options.max_alternate_depth`.
    AlternatesTooDeep,
} || pack.Error || pack.WriteError || object.HeaderParseError ||
    object.ParseError || object.TreeParseError || Allocator.Error ||
    Io.Dir.OpenError || Io.File.OpenError || Io.Writer.Error ||
    Io.File.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError ||
    Io.Dir.CreateDirError || Io.Dir.ReadFileAllocError || Io.Dir.Iterator.Error;

/// One `objects` directory: the repository's own, or an alternate.
const Source = struct {
    dir: Io.Dir,
    pack_dir: ?Io.Dir,
    packs: std.ArrayList(pack.Pack),
    pack_names: std.ArrayList([]u8),
    /// Whether objects may be written here. Only the first source is.
    writable: bool,
    /// `pack/multi-pack-index`, when there is one.
    midx: ?midx_mod.Index,
    /// For each pack the multi-pack index names, its position in `packs`, or
    /// `null` when that pack is not open here. The index names packs by file
    /// name and this database holds them in directory order, so the two have
    /// to be matched up once rather than on every lookup.
    midx_packs: std.ArrayList(?u32),

    /// Which pack holds `oid`, asking the multi-pack index first.
    ///
    /// The index narrows the search to one pack; that pack's own index is
    /// still what gives the offset. Doing it the other way round would make
    /// a stale or wrong index a read at a wrong offset rather than a miss,
    /// and the answer is the same either way, which is the property the whole
    /// accelerator is allowed to have.
    fn findPack(source: *Source, oid: Oid, stats: *Stats) Error!?struct { at: usize, offset: u64 } {
        if (source.midx) |*index| {
            // A multi-pack index that misanswers is a miss and not an error:
            // it is an accelerator, and the scan below is the same answer.
            if (index.find(oid) catch null) |located| {
                if (located.pack < source.midx_packs.items.len) {
                    if (source.midx_packs.items[located.pack]) |position| {
                        const p = &source.packs.items[position];
                        if (try p.index.find(oid)) |found| {
                            stats.midx_hits += 1;
                            return .{ .at = position, .offset = found.offset };
                        }
                    }
                }
            }
        }
        stats.pack_scans += 1;
        for (source.packs.items, 0..) |*p, position| {
            if (try p.index.find(oid)) |found| return .{ .at = position, .offset = found.offset };
        }
        return null;
    }
};

/// How many bytes of an object's compressed form are gathered before the
/// first write. Sixty-four kilobytes is one write for anything a working tree
/// holds by the thousand, and a bound rather than a promise for the rest.
const deflate_output_buffer_len = 64 * 1024;

/// The deflate state a writing database keeps. `flate.Compress` is two
/// hundred and twenty-four kilobytes, which is why it is here and not on the
/// stack of every `write`.
const DeflateState = struct {
    compress: *flate.Compress,
    buffer: []u8,
};

/// Counters saying how lookups resolved and what writing cost. Nothing
/// depends on them; they are how a caller, or a test, sees that an
/// accelerator is being used and that a batch of writes stayed cheap.
pub const Stats = struct {
    /// Lookups a multi-pack index narrowed to one pack.
    midx_hits: u64 = 0,
    /// Lookups that asked every pack in turn, because there was no
    /// multi-pack index, or it did not name the object.
    pack_scans: u64 = 0,
    /// Objects written to the disk: a temporary created, deflated, closed
    /// and renamed.
    loose_written: u64 = 0,
    /// Writes that found the object already there and did nothing.
    loose_present: u64 = 0,
    /// Fan-out directories made. At most two hundred and fifty-six of them
    /// exist, so a batch of any size makes at most that many, however many
    /// objects it writes.
    fan_out_created: u64 = 0,
    /// Objects written into a pack rather than as loose files.
    packed_written: u64 = 0,
};

/// The object database.
pub const Odb = struct {
    gpa: Allocator,
    kind: Kind,
    options: Options,
    sources: std.ArrayList(Source),
    cache: pack.Cache,
    /// Bumped whenever the pack directories are re-scanned, so a caller can
    /// tell that a miss was already retried.
    generation: u32 = 0,
    /// One deflate window, allocated once. A window is sixty-four kilobytes
    /// and an `add -A` writes one object per changed file; allocating it per
    /// object is a measurable share of the cost of a cold pass.
    deflate_window: []u8 = &.{},
    /// The deflate state and the buffer an object's compressed bytes are
    /// gathered in, allocated on the first object written and reused by every
    /// one after it. `null` in a database nothing has written to.
    deflate_state: ?DeflateState = null,
    /// How lookups resolved. Read it; nothing in the package does.
    stats: Stats = .{},
    /// How fine a modification time this repository's filesystem records,
    /// measured at open unless `Options.probe_timestamp_resolution` said not
    /// to. `Repository.worktreeRules` hands it to the working tree, which is
    /// what makes a stat shortcut believe exactly as much as it should.
    timestamp_resolution: fs.Resolution = .nanosecond,
    /// The commits of a shallow repository's boundary, `.git/shallow`,
    /// which `Repository.open` fills: every history walk takes them as
    /// having no parents, because theirs are not here. Empty in a whole
    /// repository.
    shallow: Oid.Set = .empty,

    /// Open the object database under `git_dir`.
    ///
    /// `objects/pack` is scanned once here; a miss re-scans it before giving
    /// up, because a concurrent `git gc` may have packed an object away
    /// between the two.
    pub fn open(
        gpa: Allocator,
        io: Io,
        git_dir: Io.Dir,
        kind: Kind,
        options: Options,
    ) Error!Odb {
        var odb: Odb = .{
            .gpa = gpa,
            .kind = kind,
            .options = options,
            .sources = .empty,
            .cache = try .init(gpa, options.delta_cache_bytes),
        };
        errdefer odb.deinit(io);

        odb.deflate_window = try gpa.alloc(u8, flate.max_window_len);
        const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
        try odb.addSource(io, objects, true, 0);
        if (options.probe_timestamp_resolution) {
            odb.timestamp_resolution = fs.probeTimestampResolution(io, objects);
        }
        return odb;
    }

    /// Open an object database at an `objects` directory directly, for a
    /// caller that has one without a repository around it.
    pub fn openAt(
        gpa: Allocator,
        io: Io,
        objects_dir: Io.Dir,
        kind: Kind,
        options: Options,
    ) Error!Odb {
        var odb: Odb = .{
            .gpa = gpa,
            .kind = kind,
            .options = options,
            .sources = .empty,
            .cache = try .init(gpa, options.delta_cache_bytes),
        };
        errdefer odb.deinit(io);
        odb.deflate_window = try gpa.alloc(u8, flate.max_window_len);
        try odb.addSource(io, objects_dir, true, 0);
        if (options.probe_timestamp_resolution) {
            odb.timestamp_resolution = fs.probeTimestampResolution(io, objects_dir);
        }
        return odb;
    }

    fn addSource(odb: *Odb, io: Io, dir: Io.Dir, writable: bool, depth: u8) Error!void {
        if (depth > odb.options.max_alternate_depth) return error.AlternatesTooDeep;
        const pack_dir = dir.openDir(io, "pack", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => |e| return e,
        };
        try odb.sources.append(odb.gpa, .{
            .dir = dir,
            .pack_dir = pack_dir,
            .packs = .empty,
            .pack_names = .empty,
            .writable = writable,
            .midx = null,
            .midx_packs = .empty,
        });
        try odb.scanPacks(io, odb.sources.items.len - 1);
        try odb.readAlternates(io, dir, depth);
    }

    fn readAlternates(odb: *Odb, io: Io, dir: Io.Dir, depth: u8) Error!void {
        const text = (try fs.readFileAlloc(odb.gpa, io, dir, "info/alternates", 1 << 20)) orelse return;
        defer odb.gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0 or line[0] == '#') continue;
            const alt = dir.openDir(io, line, .{ .iterate = true }) catch continue;
            odb.addSource(io, alt, false, depth + 1) catch |err| switch (err) {
                error.AlternatesTooDeep => {
                    alt.close(io);
                    return err;
                },
                else => {
                    alt.close(io);
                    continue;
                },
            };
        }
    }

    fn scanPacks(odb: *Odb, io: Io, source_index: usize) Error!void {
        const source = &odb.sources.items[source_index];
        const pack_dir = source.pack_dir orelse return;
        var it = pack_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            const base = entry.name[0 .. entry.name.len - 4];
            var already = false;
            for (source.pack_names.items) |name| {
                if (std.mem.eql(u8, name, base)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            var opened = pack.Pack.open(odb.gpa, io, pack_dir, base, odb.kind, .{
                .access = if (odb.options.map_packs) .map else .read,
                .max_depth = odb.options.max_delta_depth,
            }) catch continue;
            const name_copy = odb.gpa.dupe(u8, base) catch {
                opened.deinit(io);
                return error.OutOfMemory;
            };
            source.packs.append(odb.gpa, opened) catch {
                odb.gpa.free(name_copy);
                opened.deinit(io);
                return error.OutOfMemory;
            };
            source.pack_names.append(odb.gpa, name_copy) catch return error.OutOfMemory;
        }
        try odb.loadMidx(io, source_index);
    }

    /// Read `pack/multi-pack-index` and match its pack names to the packs
    /// open here.
    ///
    /// Re-read on every scan, because a `gc` replaces it along with the packs
    /// it names. An index that does not parse is left out: it is an
    /// accelerator, and a repository reads the same without one.
    fn loadMidx(odb: *Odb, io: Io, source_index: usize) Error!void {
        const source = &odb.sources.items[source_index];
        if (source.midx) |*old| old.deinit();
        source.midx = null;
        source.midx_packs.clearRetainingCapacity();

        const pack_dir = source.pack_dir orelse return;
        var index = (midx_mod.Index.open(odb.gpa, io, pack_dir, odb.kind) catch return) orelse return;
        errdefer index.deinit();

        var position: u32 = 0;
        while (position < index.pack_count) : (position += 1) {
            const name = index.packName(position);
            var at: ?u32 = null;
            if (name) |text| {
                for (source.pack_names.items, 0..) |open_name, i| {
                    if (std.mem.eql(u8, open_name, text)) {
                        at = @intCast(i);
                        break;
                    }
                }
            }
            source.midx_packs.append(odb.gpa, at) catch return error.OutOfMemory;
        }
        source.midx = index;
    }

    /// Re-scan every pack directory, picking up packs written since the last
    /// scan. `read` does this once on a miss; a caller watching a repository
    /// a `gc` runs in may call it.
    pub fn refresh(odb: *Odb, io: Io) Error!void {
        for (0..odb.sources.items.len) |i| try odb.scanPacks(io, i);
        odb.generation += 1;
    }

    /// Close every pack and release everything held.
    pub fn deinit(odb: *Odb, io: Io) void {
        for (odb.sources.items) |*source| {
            for (source.packs.items) |*p| p.deinit(io);
            for (source.pack_names.items) |name| odb.gpa.free(name);
            source.packs.deinit(odb.gpa);
            source.pack_names.deinit(odb.gpa);
            if (source.midx) |*index| index.deinit();
            source.midx_packs.deinit(odb.gpa);
            if (source.pack_dir) |d| d.close(io);
            source.dir.close(io);
        }
        odb.sources.deinit(odb.gpa);
        if (odb.deflate_window.len != 0) odb.gpa.free(odb.deflate_window);
        if (odb.deflate_state) |state| {
            odb.gpa.destroy(state.compress);
            odb.gpa.free(state.buffer);
        }
        odb.cache.deinit();
        odb.shallow.deinit(odb.gpa);
        odb.* = undefined;
    }

    /// The hash every name in this database is written with.
    pub fn hashKind(odb: *const Odb) Kind {
        return odb.kind;
    }

    fn loosePath(odb: *const Odb, oid: Oid, buf: []u8) []const u8 {
        _ = odb;
        var hex: [hash.max_hex_len]u8 = undefined;
        const text = oid.hex(&hex);
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ text[0..2], text[2..] }) catch unreachable;
    }

    /// An object's type and bytes. The bytes are the caller's.
    pub const Read = struct {
        type: object.Type,
        bytes: []u8,
    };

    /// Read the object named `oid`.
    ///
    /// On a miss the pack directories are re-scanned once and the lookup is
    /// tried again, because a concurrent `git gc` may have just packed the
    /// object away; then it is `error.ObjectNotFound`.
    pub fn read(odb: *Odb, io: Io, oid: Oid) Error!Read {
        if (try odb.tryRead(io, oid)) |found| return found;
        try odb.refresh(io);
        if (try odb.tryRead(io, oid)) |found| return found;
        return error.ObjectNotFound;
    }

    fn tryRead(odb: *Odb, io: Io, oid: Oid) Error!?Read {
        if (try odb.readLoose(io, oid)) |found| return found;
        var base: u32 = 0;
        for (odb.sources.items) |*source| {
            defer base += @intCast(source.packs.items.len);
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            const p = &source.packs.items[located.at];
            const obj = try p.readAt(io, located.offset, &odb.cache, base + @as(u32, @intCast(located.at)));
            return .{ .type = obj.type, .bytes = obj.bytes };
        }
        return null;
    }

    fn readLoose(odb: *Odb, io: Io, oid: Oid) Error!?Read {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.sources.items) |*source| {
            const file = source.dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer file.close(io);
            const bytes = try odb.inflateWhole(io, file);
            errdefer odb.gpa.free(bytes);
            const parsed = object.parseHeader(bytes) catch return error.CorruptLooseObject;
            const body = bytes[parsed.len..];
            if (body.len != parsed.header.size) return error.CorruptLooseObject;
            // The body moves to the front of the allocation it was inflated
            // into, rather than into a second one.
            std.mem.copyForwards(u8, bytes[0..body.len], body);
            const out = try odb.gpa.realloc(bytes, body.len);
            return .{ .type = parsed.header.type, .bytes = out };
        }
        return null;
    }

    fn inflateWhole(odb: *Odb, io: Io, file: Io.File) Error![]u8 {
        const input_buffer = try odb.gpa.alloc(u8, odb.options.read_buffer_size);
        defer odb.gpa.free(input_buffer);
        var file_reader = file.reader(io, input_buffer);
        var window: [flate.max_window_len]u8 = undefined;
        var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, &window);
        return decompress.reader.allocRemaining(odb.gpa, .limited(odb.options.max_object_bytes)) catch
            return error.CorruptLooseObject;
    }

    /// The type and length of `oid`, with no body inflated where the object
    /// is packed and with only its header inflated where it is loose.
    pub fn readHeader(odb: *Odb, io: Io, oid: Oid) Error!object.Header {
        return (try odb.readHeaderForPack(io, oid, 0)).header;
    }

    const PackHeader = struct {
        header: object.Header,
        /// A loose body retained while reading its header, when it fit the
        /// caller's remaining cache budget.
        bytes: ?[]u8 = null,
    };

    /// The pack ordering pass has already opened a loose object. When its
    /// body fits `cache_available`, finish that inflate and hand the body to
    /// the write pass rather than opening and inflating it again.
    fn readHeaderForPack(odb: *Odb, io: Io, oid: Oid, cache_available: usize) Error!PackHeader {
        if (try odb.tryReadHeaderForPack(io, oid, cache_available)) |found| return found;
        try odb.refresh(io);
        if (try odb.tryReadHeaderForPack(io, oid, cache_available)) |found| return found;
        return error.ObjectNotFound;
    }

    fn tryReadHeaderForPack(odb: *Odb, io: Io, oid: Oid, cache_available: usize) Error!?PackHeader {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.sources.items) |*source| {
            const file = source.dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer file.close(io);
            // Both buffers live on the stack: a pack write asks for tens of
            // thousands of headers in a row, and an allocation for each was
            // a measurable share of it.
            var input_buffer: [1024]u8 = undefined;
            var file_reader = file.reader(io, &input_buffer);
            var window: [flate.max_window_len]u8 = undefined;
            var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, &window);
            var head: [64]u8 = @splat(0);
            var got: usize = 0;
            while (got < head.len) {
                const n = decompress.reader.readSliceShort(head[got..]) catch return error.CorruptLooseObject;
                if (n == 0) break;
                got += n;
                if (std.mem.indexOfScalar(u8, head[0..got], 0) != null) break;
            }
            const parsed = object.parseHeader(head[0..got]) catch return error.CorruptLooseObject;
            if (cache_available == 0 or parsed.header.size > cache_available) {
                return .{ .header = parsed.header };
            }

            const body_len: usize = @intCast(parsed.header.size);
            const initial = head[parsed.len..got];
            if (initial.len > body_len) return error.CorruptLooseObject;
            const body = try odb.gpa.alloc(u8, body_len);
            errdefer odb.gpa.free(body);
            @memcpy(body[0..initial.len], initial);
            var body_got = initial.len;
            while (body_got < body.len) {
                const n = decompress.reader.readSliceShort(body[body_got..]) catch
                    return error.CorruptLooseObject;
                if (n == 0) return error.CorruptLooseObject;
                body_got += n;
            }
            var extra: [1]u8 = undefined;
            if ((decompress.reader.readSliceShort(&extra) catch return error.CorruptLooseObject) != 0) {
                return error.CorruptLooseObject;
            }
            return .{ .header = parsed.header, .bytes = body };
        }
        for (odb.sources.items) |*source| {
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            return .{ .header = try source.packs.items[located.at].headerAt(io, located.offset) };
        }
        return null;
    }

    /// Whether the database holds `oid`, without reading it.
    ///
    /// Does not refresh: a caller asking whether an object is present before
    /// writing it wants an answer, not a directory scan.
    pub fn exists(odb: *Odb, io: Io, oid: Oid) Error!bool {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.sources.items) |*source| {
            source.dir.access(io, path, .{}) catch continue;
            return true;
        }
        for (odb.sources.items) |*source| {
            if ((try source.findPack(oid, &odb.stats)) != null) return true;
        }
        return false;
    }

    /// Errors from resolving an abbreviated name.
    pub const PrefixError = error{
        /// Two or more objects begin with those digits.
        AmbiguousPrefix,
        /// None do.
        ObjectNotFound,
    } || Error;

    /// The one object whose name begins with `prefix`.
    ///
    /// Loose objects and every pack are searched. This is what turns a short
    /// name a person typed into a name; nothing else in the package accepts
    /// an abbreviation.
    pub fn findPrefix(odb: *Odb, io: Io, prefix: []const u8) PrefixError!Oid {
        if (prefix.len < 2 or prefix.len > odb.kind.hexLen()) return error.ObjectNotFound;
        var found: ?Oid = null;
        for (odb.sources.items) |*source| {
            var dir_name: [3]u8 = .{ prefix[0], prefix[1], 0 };
            const sub = source.dir.openDir(io, dir_name[0..2], .{ .iterate = true }) catch null;
            if (sub) |d| {
                defer d.close(io);
                var it = d.iterate();
                while (it.next(io) catch null) |entry| {
                    if (entry.kind == .directory) continue;
                    if (entry.name.len != odb.kind.hexLen() - 2) continue;
                    var full: [hash.max_hex_len]u8 = undefined;
                    @memcpy(full[0..2], prefix[0..2]);
                    @memcpy(full[2..][0..entry.name.len], entry.name);
                    const oid = Oid.parse(odb.kind, full[0 .. 2 + entry.name.len]) catch continue;
                    if (!oid.startsWithHex(prefix)) continue;
                    if (found) |f| {
                        if (!f.eql(oid)) return error.AmbiguousPrefix;
                    } else found = oid;
                }
            }
            for (source.packs.items) |*p| {
                const hit = p.index.findPrefix(prefix) catch |err| switch (err) {
                    error.AmbiguousPrefix => return error.AmbiguousPrefix,
                    else => |e| return e,
                };
                if (hit) |oid| {
                    if (found) |f| {
                        if (!f.eql(oid)) return error.AmbiguousPrefix;
                    } else found = oid;
                }
            }
        }
        return found orelse error.ObjectNotFound;
    }

    /// Write a loose object and return its name.
    ///
    /// An object already in the database is not written again, which is what
    /// git does and what keeps `addAll` from rewriting a tree every frame.
    pub fn write(odb: *Odb, io: Io, t: object.Type, bytes: []const u8) Error!Oid {
        const named = hash.Hasher.nameObject(odb.kind, odb.hashOptions(), t.name(), bytes);
        if (named.collision_attack) return error.CollisionAttack;
        const oid = named.oid;
        if (try odb.exists(io, oid)) {
            odb.stats.loose_present += 1;
            return oid;
        }

        const source = odb.writableSource();
        var hex: [hash.max_hex_len]u8 = undefined;
        const text = oid.hex(&hex);

        // The temporary and the object it becomes are both named relative to
        // the `objects` directory, so the fan-out directory is never opened
        // and never closed. What the old shape paid per object -- a `mkdir`
        // that almost always answers that the directory is already there, an
        // `opendir` and a `close` -- a batch now pays once per fan-out
        // directory: the create that lands in one that is not there yet is
        // the signal to make it.
        var name_buf: [hash.max_hex_len + 32]u8 = undefined;
        const temp = tempObjectName(io, &name_buf, text[0..2]);
        var final_buf: [hash.max_hex_len + 2]u8 = undefined;
        const final = std.fmt.bufPrint(&final_buf, "{s}/{s}", .{ text[0..2], text[2..] }) catch unreachable;

        var file = source.dir.createFile(io, temp, .{ .exclusive = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                source.dir.createDir(io, text[0..2], .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => |other| return other,
                };
                odb.stats.fan_out_created += 1;
                break :blk try source.dir.createFile(io, temp, .{ .exclusive = true });
            },
            else => |e| return e,
        };
        var failed = true;
        defer if (failed) {
            file.close(io);
            source.dir.deleteFile(io, temp) catch {};
        };

        // The deflate state and the file's own buffer belong to the database
        // rather than to this frame. The state is two hundred and twenty-four
        // kilobytes and is built from scratch for every object; a stack that
        // large per call is not what a cold `addAll` should stand on.
        const state = try odb.deflateState();
        var file_writer = file.writer(io, state.buffer);
        // Level 1, which is what git's own `core.looseCompression` defaults
        // to. The library default is level 6: three times the processor time
        // for twenty per cent smaller objects, paid on every blob written.
        const compress = state.compress;
        compress.* = try flate.Compress.init(&file_writer.interface, odb.deflate_window, .zlib, .level_1);
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ t.name(), bytes.len }) catch unreachable;
        try compress.writer.writeAll(header);
        try compress.writer.writeAll(bytes);
        try compress.writer.flush();
        try compress.finish();
        try file_writer.interface.flush();
        switch (odb.options.sync) {
            .none => {},
            // Batch and per-file both flush the object's own descriptor; the
            // difference is the single barrier `syncBatch` puts at the end.
            .batch, .per_file => try file.sync(io),
        }
        file.close(io);
        failed = false;

        // An object's name is the hash of its content, so a rename over an
        // object that is already there replaces it with the same bytes.
        fs.renameWithRetry(io, source.dir, temp, final) catch |err| {
            source.dir.deleteFile(io, temp) catch {};
            return err;
        };
        if (odb.options.sync_directories) {
            const sub = try source.dir.openDir(io, text[0..2], .{});
            defer sub.close(io);
            try fs.syncDir(io, sub);
        }
        odb.stats.loose_written += 1;
        return oid;
    }

    /// `<xx>/tmp_obj_<random>`, written into `buf`.
    ///
    /// The temporary lies beside the object it becomes, so the rename that
    /// finishes it stays inside one directory and needs no handle on it.
    fn tempObjectName(io: Io, buf: []u8, fan_out: []const u8) []const u8 {
        var raw: [12]u8 = undefined;
        io.random(&raw);
        return std.fmt.bufPrint(buf, "{s}/tmp_obj_{x}", .{ fan_out, &raw }) catch unreachable;
    }

    /// The deflate state, allocated on the first object this database writes.
    ///
    /// A database that is only read never pays for it; one that writes pays
    /// once rather than once per object.
    fn deflateState(odb: *Odb) Allocator.Error!DeflateState {
        if (odb.deflate_state) |state| return state;
        const compress = try odb.gpa.create(flate.Compress);
        errdefer odb.gpa.destroy(compress);
        const buffer = try odb.gpa.alloc(u8, deflate_output_buffer_len);
        odb.deflate_state = .{ .compress = compress, .buffer = buffer };
        return odb.deflate_state.?;
    }

    /// The naming options every name this database takes is given.
    fn hashOptions(odb: *const Odb) hash.Hasher.Options {
        return .{ .detect_collisions = odb.options.detect_sha1_collisions };
    }

    fn writableSource(odb: *Odb) *Source {
        for (odb.sources.items) |*s| {
            if (s.writable) return s;
        }
        return &odb.sources.items[0];
    }

    /// A writer for an object too large to hold in memory.
    ///
    /// Bytes go through it, `finish` names the object and puts it in the
    /// database, and `abort` leaves the database as it was. The stated size
    /// must be right: it goes into the header the name is taken over.
    pub const Stream = struct {
        odb: *Odb,
        dir: Io.Dir,
        temp: [128]u8,
        temp_len: usize,
        file: Io.File,
        file_writer: Io.File.Writer,
        compress: flate.Compress,
        input_writer: Io.Writer,
        hasher: hash.Hasher,
        window: []u8,
        out_buffer: []u8,
        remaining: u64,
        file_open: bool = true,
        finished: bool = false,

        /// Where the object's bytes go.
        pub fn writer(s: *Stream) *Io.Writer {
            return &s.input_writer;
        }

        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const s: *Stream = @alignCast(@fieldParentPtr("input_writer", w));
            var total: usize = 0;
            for (data[0 .. data.len - 1]) |slice| {
                total = std.math.add(usize, total, slice.len) catch return error.WriteFailed;
            }
            const pattern = data[data.len - 1];
            const repeated = std.math.mul(usize, pattern.len, splat) catch return error.WriteFailed;
            total = std.math.add(usize, total, repeated) catch return error.WriteFailed;
            if (total > s.remaining) return error.WriteFailed;

            for (data[0 .. data.len - 1]) |slice| s.write(slice) catch return error.WriteFailed;
            for (0..splat) |_| s.write(pattern) catch return error.WriteFailed;
            return total;
        }

        /// Feed bytes, hashing as they go.
        pub fn write(s: *Stream, bytes: []const u8) Error!void {
            if (bytes.len > s.remaining) return error.CorruptLooseObject;
            s.hasher.update(bytes);
            s.remaining -= bytes.len;
            try s.compress.writer.writeAll(bytes);
        }

        /// Close the object and put it in the database. Returns its name.
        pub fn finish(s: *Stream, io: Io) Error!Oid {
            if (s.remaining != 0) return error.CorruptLooseObject;
            try s.compress.writer.flush();
            try s.compress.finish();
            try s.file_writer.interface.flush();
            switch (s.odb.options.sync) {
                .none => {},
                .batch, .per_file => try s.file.sync(io),
            }
            s.file.close(io);
            s.file_open = false;

            const oid = s.hasher.final();
            if (s.hasher.collisionAttack()) return error.CollisionAttack;
            var hex: [hash.max_hex_len]u8 = undefined;
            const text = oid.hex(&hex);
            s.dir.createDir(io, text[0..2], .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            var final_buf: [hash.max_hex_len + 2]u8 = undefined;
            const final_path = std.fmt.bufPrint(&final_buf, "{s}/{s}", .{ text[0..2], text[2..] }) catch unreachable;
            fs.renameWithRetry(io, s.dir, s.temp[0..s.temp_len], final_path) catch |err| {
                s.dir.deleteFile(io, s.temp[0..s.temp_len]) catch {};
                return err;
            };
            s.finished = true;
            if (s.odb.options.sync_directories) try fs.syncDir(io, s.dir);
            return oid;
        }

        /// Give up, leaving the database as it was.
        pub fn abort(s: *Stream, io: Io) void {
            if (!s.finished) {
                if (s.file_open) s.file.close(io);
                s.dir.deleteFile(io, s.temp[0..s.temp_len]) catch {};
                s.finished = true;
            }
            s.odb.gpa.free(s.window);
            s.odb.gpa.free(s.out_buffer);
        }

        /// Release the stream's buffers after a successful `finish`.
        pub fn deinit(s: *Stream, io: Io) void {
            if (!s.finished) {
                s.abort(io);
                return;
            }
            s.odb.gpa.free(s.window);
            s.odb.gpa.free(s.out_buffer);
            s.* = undefined;
        }
    };

    /// Begin writing an object of `size` bytes. The result must be `finish`ed
    /// or `abort`ed, and lives at a stable address until then.
    pub fn writeStream(odb: *Odb, io: Io, t: object.Type, size: u64, out: *Stream) Error!void {
        const source = odb.writableSource();
        var name_buf: [128]u8 = undefined;
        const temp = fs.tempName(io, &name_buf, "tmp_obj_");
        const file = try source.dir.createFile(io, temp, .{ .exclusive = true });
        errdefer {
            file.close(io);
            source.dir.deleteFile(io, temp) catch {};
        }
        const window = try odb.gpa.alloc(u8, flate.max_window_len);
        errdefer odb.gpa.free(window);
        const out_buffer = try odb.gpa.alloc(u8, 16 * 1024);
        errdefer odb.gpa.free(out_buffer);

        out.* = .{
            .odb = odb,
            .dir = source.dir,
            .temp = undefined,
            .temp_len = temp.len,
            .file = file,
            .file_writer = undefined,
            .compress = undefined,
            .input_writer = .{ .vtable = &.{ .drain = Stream.drain }, .buffer = &.{} },
            .hasher = .initOptions(odb.kind, odb.hashOptions()),
            .window = window,
            .out_buffer = out_buffer,
            .remaining = size,
        };
        @memcpy(out.temp[0..temp.len], temp);
        out.file_writer = file.writer(io, out_buffer);
        out.compress = try flate.Compress.init(&out.file_writer.interface, window, .zlib, .level_1);
        out.hasher.updateHeader(t.name(), size);
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ t.name(), size }) catch unreachable;
        try out.compress.writer.writeAll(header);
    }

    /// What `verify` found.
    pub const Report = struct {
        loose: u32 = 0,
        packed_objects: u32 = 0,
        packs: u32 = 0,
        bytes: u64 = 0,
    };

    /// Rehash every object the database holds against its own name.
    ///
    /// Loose objects are inflated and named; every pack is checked against
    /// its trailing checksum, every entry against the CRC its index carries,
    /// and every object against the name the index gives it.
    pub fn verify(odb: *Odb, io: Io) Error!Report {
        var report: Report = .{};
        for (odb.sources.items) |*source| {
            var top = source.dir.iterate();
            while (try top.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                if (entry.name.len != 2) continue;
                if (hexPair(entry.name) == null) continue;
                const sub = source.dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var it = sub.iterate();
                while (try it.next(io)) |file_entry| {
                    if (file_entry.kind == .directory) continue;
                    if (file_entry.name.len != odb.kind.hexLen() - 2) continue;
                    var full: [hash.max_hex_len]u8 = undefined;
                    @memcpy(full[0..2], entry.name);
                    @memcpy(full[2..][0..file_entry.name.len], file_entry.name);
                    const oid = Oid.parse(odb.kind, full[0 .. 2 + file_entry.name.len]) catch continue;
                    const found = (try odb.readLoose(io, oid)) orelse continue;
                    defer odb.gpa.free(found.bytes);
                    const named = hash.Hasher.nameObject(odb.kind, odb.hashOptions(), found.type.name(), found.bytes);
                    if (named.collision_attack) return error.CollisionAttack;
                    if (!named.oid.eql(oid)) return error.ObjectNameMismatch;
                    report.loose += 1;
                    report.bytes += found.bytes.len;
                }
            }
        }
        var pack_id: u32 = 0;
        for (odb.sources.items) |*source| {
            for (source.packs.items) |*p| {
                defer pack_id += 1;
                const pack_report = try p.verify(io, &odb.cache, pack_id);
                report.packs += 1;
                report.packed_objects += pack_report.objects;
                report.bytes += pack_report.bytes;
            }
        }
        return report;
    }

    /// Every object name the database holds, loose and packed, as a set the
    /// caller owns.
    ///
    /// This is what a fsck-shaped tool walks; nothing inside the package uses
    /// it, so a repository with a million objects pays for it only on demand.
    pub fn listObjects(odb: *Odb, io: Io) Error!Oid.Set {
        var set: Oid.Set = .empty;
        errdefer set.deinit(odb.gpa);
        for (odb.sources.items) |*source| {
            var top = source.dir.iterate();
            while (try top.next(io)) |entry| {
                if (entry.kind != .directory or entry.name.len != 2) continue;
                if (hexPair(entry.name) == null) continue;
                const sub = source.dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var it = sub.iterate();
                while (try it.next(io)) |file_entry| {
                    if (file_entry.name.len != odb.kind.hexLen() - 2) continue;
                    var full: [hash.max_hex_len]u8 = undefined;
                    @memcpy(full[0..2], entry.name);
                    @memcpy(full[2..][0..file_entry.name.len], file_entry.name);
                    const oid = Oid.parse(odb.kind, full[0 .. 2 + file_entry.name.len]) catch continue;
                    try set.put(odb.gpa, oid, {});
                }
            }
            for (source.packs.items) |*p| {
                var it = p.index.iterate();
                while (try it.next()) |found| try set.put(odb.gpa, found.oid, {});
            }
        }
        return set;
    }

    /// Put one durability barrier at the end of a batch of object writes.
    ///
    /// Under `Options.sync = .batch` this is what makes every object written
    /// since the last barrier durable, for the cost of one sync rather than
    /// one per object. Under the other two policies it is a no-op that costs
    /// a file creation, so a caller may always call it.
    pub fn syncBatch(odb: *Odb, io: Io) Error!void {
        if (odb.options.sync != .batch) return;
        const source = odb.writableSource();
        try fs.syncBarrier(io, source.dir);
    }

    /// Write a pack holding exactly these objects, into `pack_dir`.
    ///
    /// The objects are ordered the way git's packer orders them -- type,
    /// then the tail of the path hint, then size descending -- and each is
    /// tried against a sliding window of the ones already written. What is
    /// held at once is the window, which `PackOptions.window_bytes` bounds,
    /// the loose-body cache bounded by `PackOptions.loose_cache_bytes`, and
    /// one object being written. Delta candidate searches use the caller's
    /// concurrency executor only when `PackOptions.threads` is greater than
    /// one.
    ///
    /// `pack_dir` is where `pack-<name>.pack` and `pack-<name>.idx` land, and
    /// in a repository that is `objects/pack`. Nothing is visible under
    /// either name until both are written.
    ///
    /// This does not add the pack to this database; `refresh` does, and
    /// `repack` does both.
    pub fn writePack(
        odb: *Odb,
        io: Io,
        pack_dir: Io.Dir,
        entries: []const PackEntry,
        options: PackOptions,
    ) Error!pack.WriteReport {
        return odb.writePackInto(io, .{ .dir = pack_dir }, entries, options);
    }

    /// `writePack`, with the pack written to `out` as it is made rather
    /// than to a file: what a push sends. No index is written; `out` is not
    /// flushed.
    pub fn writePackTo(
        odb: *Odb,
        io: Io,
        out: *Io.Writer,
        entries: []const PackEntry,
        options: PackOptions,
    ) Error!pack.WriteReport {
        return odb.writePackInto(io, .{ .stream = out }, entries, options);
    }

    const PackTarget = union(enum) {
        dir: Io.Dir,
        stream: *Io.Writer,
    };

    fn writePackInto(
        odb: *Odb,
        io: Io,
        target: PackTarget,
        entries: []const PackEntry,
        options: PackOptions,
    ) Error!pack.WriteReport {
        const gpa = odb.gpa;

        // Every object's type and length, which is what the order is by. A
        // header is all this needs, and for a packed object that is no
        // inflation at all.
        var ordered = try gpa.alloc(Ordered, entries.len);
        var ordered_filled: usize = 0;
        defer {
            for (ordered[0..ordered_filled]) |item| if (item.cached) |bytes| gpa.free(bytes);
            gpa.free(ordered);
        }
        var cached_bytes: usize = 0;
        for (entries, 0..) |entry, i| {
            const available = options.loose_cache_bytes -| cached_bytes;
            const found = try odb.readHeaderForPack(io, entry.oid, available);
            if (found.bytes) |bytes| cached_bytes += bytes.len;
            ordered[i] = .{
                .oid = entry.oid,
                .type = found.header.type,
                .size = found.header.size,
                .name_hash = nameHash(entry.hint),
                .cached = found.bytes,
            };
            ordered_filled += 1;
        }
        std.mem.sort(Ordered, ordered, {}, beforeInPackOrder);

        const write_options: pack.WriteOptions = .{
            .sync = options.sync,
            .compression = options.compression,
        };
        var writer = switch (target) {
            .dir => |pack_dir| try pack.Writer.init(gpa, io, pack_dir, odb.kind, @intCast(entries.len), write_options),
            .stream => |out| try pack.Writer.initStream(gpa, odb.kind, out, @intCast(entries.len), write_options),
        };
        defer writer.deinit(io);

        var window: std.ArrayList(WindowSlot) = .empty;
        defer {
            for (window.items) |*slot| {
                if (slot.encoder) |*encoder| encoder.deinit(gpa);
                gpa.free(slot.bytes);
            }
            window.deinit(gpa);
        }
        var window_bytes: usize = 0;

        for (ordered) |*item| {
            const found = if (item.cached) |bytes| blk: {
                item.cached = null;
                break :blk Read{ .type = item.type, .bytes = bytes };
            } else try odb.read(io, item.oid);
            var bytes = found.bytes;
            var keep = false;
            defer if (!keep) gpa.free(bytes);

            const deltifiable = options.delta != .none and options.window != 0 and
                bytes.len < options.big_file_bytes;

            var chosen: ?ChosenDelta = null;
            defer if (chosen) |c| gpa.free(c.bytes);
            if (deltifiable) {
                // git's rule for what is worth writing: a delta must be at
                // most half the object it stands in for, and each one after
                // the first must beat the one before it.
                var limit: usize = bytes.len / 2;
                if (limit > odb.kind.rawLen()) limit -= odb.kind.rawLen() else limit = 0;
                chosen = try findDelta(gpa, io, window.items, found.type, bytes, options, limit);
            }

            var depth: u32 = 0;
            const offset = if (chosen) |c| blk: {
                const slot = window.items[c.slot];
                depth = slot.depth + 1;
                break :blk switch (options.delta) {
                    .offset => try writer.addOfsDelta(item.oid, slot.offset, c.bytes),
                    .reference => try writer.addRefDelta(item.oid, slot.oid, c.bytes),
                    .none => unreachable,
                };
            } else try writer.add(item.oid, found.type, bytes);

            if (deltifiable) {
                try window.append(gpa, .{
                    .oid = item.oid,
                    .type = found.type,
                    .bytes = bytes,
                    .offset = offset,
                    .depth = depth,
                    .encoder = null,
                });
                keep = true;
                window_bytes += bytes.len;
                // The oldest go first, by count and then by weight, so the
                // window is a bound on memory and not only on work.
                while (window.items.len > options.window or
                    (window.items.len > 1 and window_bytes > options.window_bytes))
                {
                    var oldest = window.orderedRemove(0);
                    window_bytes -= oldest.bytes.len;
                    if (oldest.encoder) |*encoder| encoder.deinit(gpa);
                    gpa.free(oldest.bytes);
                }
                bytes = &.{};
            }
        }

        return try writer.finish(io);
    }

    /// What `collectReachable` and `collectLoose` leave out.
    pub const CollectOptions = struct {
        /// Names to leave out whatever else says they belong.
        exclude: []const Oid = &.{},
        /// Packs, by the base name a directory listing gives -- `pack-<name>`
        /// -- whose objects are left out. This is what makes a pack
        /// incremental: it names the packs it is being added to, and holds
        /// only what they do not.
        exclude_packs: []const []const u8 = &.{},
    };

    /// A set of objects to pack, and the hints that came with them.
    ///
    /// Everything is owned by the arena, so releasing it is one call.
    pub const Collected = struct {
        arena: std.heap.ArenaAllocator,
        entries: []PackEntry,

        pub fn deinit(c: *Collected) void {
            c.arena.deinit();
            c.* = undefined;
        }
    };

    /// Every object reachable from `tips`: the commits behind them, the trees
    /// those name, and the blobs under the trees.
    ///
    /// Each object carries the path it was found at, which is the hint the
    /// delta search orders by. A commit or a tag carries none, because
    /// neither has a path.
    pub fn collectReachable(
        odb: *Odb,
        io: Io,
        tips: []const Oid,
        options: CollectOptions,
    ) Error!Collected {
        var collected: Collected = .{ .arena = .init(odb.gpa), .entries = &.{} };
        errdefer collected.arena.deinit();
        const arena = collected.arena.allocator();

        var skip: Oid.Set = .empty;
        defer skip.deinit(odb.gpa);
        for (options.exclude) |oid| try skip.put(odb.gpa, oid, {});
        for (options.exclude_packs) |base| {
            const p = odb.findPackByName(base) orelse continue;
            var it = p.index.iterate();
            while (try it.next()) |found| try skip.put(odb.gpa, found.oid, {});
        }

        var seen: Oid.Set = .empty;
        defer seen.deinit(odb.gpa);
        var entries: std.ArrayList(PackEntry) = .empty;
        defer entries.deinit(odb.gpa);

        // Commits and tags first, so that every tree is reached through the
        // commit that names it and a path is known by the time a blob is.
        var commits: std.ArrayList(Oid) = .empty;
        defer commits.deinit(odb.gpa);
        var trees: std.ArrayList(struct { oid: Oid, path: []const u8 }) = .empty;
        defer trees.deinit(odb.gpa);

        for (tips) |tip| try commits.append(odb.gpa, tip);
        var at: usize = 0;
        while (at < commits.items.len) : (at += 1) {
            const oid = commits.items[at];
            if (seen.contains(oid)) continue;
            const found = odb.read(io, oid) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => |e| return e,
            };
            defer odb.gpa.free(found.bytes);
            try seen.put(odb.gpa, oid, {});
            switch (found.type) {
                .commit => {
                    var commit = try object.Commit.parse(odb.gpa, odb.kind, found.bytes);
                    defer commit.deinit();
                    try trees.append(odb.gpa, .{ .oid = commit.tree, .path = "" });
                    for (commit.parents) |parent| try commits.append(odb.gpa, parent);
                    if (!skip.contains(oid)) try entries.append(odb.gpa, .{ .oid = oid });
                },
                .tag => {
                    var tag = try object.Tag.parse(odb.gpa, odb.kind, found.bytes);
                    defer tag.deinit();
                    try commits.append(odb.gpa, tag.target);
                    if (!skip.contains(oid)) try entries.append(odb.gpa, .{ .oid = oid });
                },
                .tree => try trees.append(odb.gpa, .{ .oid = oid, .path = "" }),
                .blob => if (!skip.contains(oid)) try entries.append(odb.gpa, .{ .oid = oid }),
            }
        }

        var tree_at: usize = 0;
        while (tree_at < trees.items.len) : (tree_at += 1) {
            const node = trees.items[tree_at];
            if (seen.contains(node.oid)) continue;
            const found = odb.read(io, node.oid) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => |e| return e,
            };
            defer odb.gpa.free(found.bytes);
            if (found.type != .tree) continue;
            try seen.put(odb.gpa, node.oid, {});
            if (!skip.contains(node.oid)) {
                try entries.append(odb.gpa, .{ .oid = node.oid, .hint = node.path });
            }

            var it = object.Tree.parse(odb.kind, found.bytes).iterate();
            while (try it.next()) |entry| {
                const path = if (node.path.len == 0)
                    try arena.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ node.path, entry.name });
                switch (entry.mode) {
                    .tree => try trees.append(odb.gpa, .{ .oid = entry.oid, .path = path }),
                    // A gitlink names a commit in another repository, which
                    // this one does not hold and must not be asked for.
                    .gitlink => {},
                    else => {
                        if (seen.contains(entry.oid)) continue;
                        try seen.put(odb.gpa, entry.oid, {});
                        if (!skip.contains(entry.oid)) {
                            try entries.append(odb.gpa, .{ .oid = entry.oid, .hint = path });
                        }
                    },
                }
            }
        }

        collected.entries = try arena.dupe(PackEntry, entries.items);
        return collected;
    }

    /// Every object that is loose in the writable object directory.
    ///
    /// No hints: a loose object on its own says nothing about where it came
    /// from. `collectReachable` is the one that knows.
    pub fn collectLoose(odb: *Odb, io: Io, options: CollectOptions) Error!Collected {
        return odb.collectWritable(io, options, false);
    }

    /// Every object the writable object directory holds, loose and packed.
    ///
    /// An alternate's objects are not here: they belong to the repository
    /// that holds them, and packing them into this one would make a second
    /// copy rather than move anything.
    pub fn collectAll(odb: *Odb, io: Io, options: CollectOptions) Error!Collected {
        return odb.collectWritable(io, options, true);
    }

    fn collectWritable(odb: *Odb, io: Io, options: CollectOptions, packed_too: bool) Error!Collected {
        var collected: Collected = .{ .arena = .init(odb.gpa), .entries = &.{} };
        errdefer collected.arena.deinit();
        const arena = collected.arena.allocator();

        var skip: Oid.Set = .empty;
        defer skip.deinit(odb.gpa);
        for (options.exclude) |oid| try skip.put(odb.gpa, oid, {});
        for (options.exclude_packs) |base| {
            const p = odb.findPackByName(base) orelse continue;
            var it = p.index.iterate();
            while (try it.next()) |found| try skip.put(odb.gpa, found.oid, {});
        }

        var entries: std.ArrayList(PackEntry) = .empty;
        defer entries.deinit(odb.gpa);
        const source = odb.writableSource();
        var top = source.dir.iterate();
        while (try top.next(io)) |entry| {
            if (entry.kind != .directory or entry.name.len != 2) continue;
            if (hexPair(entry.name) == null) continue;
            const sub = source.dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            var it = sub.iterate();
            while (try it.next(io)) |file| {
                if (file.name.len != odb.kind.hexLen() - 2) continue;
                var full: [hash.max_hex_len]u8 = undefined;
                @memcpy(full[0..2], entry.name);
                @memcpy(full[2..][0..file.name.len], file.name);
                const oid = Oid.parse(odb.kind, full[0 .. 2 + file.name.len]) catch continue;
                if (skip.contains(oid)) continue;
                try entries.append(odb.gpa, .{ .oid = oid });
            }
        }
        if (packed_too) {
            var seen: Oid.Set = .empty;
            defer seen.deinit(odb.gpa);
            for (entries.items) |e| try seen.put(odb.gpa, e.oid, {});
            for (source.packs.items) |*p| {
                var it = p.index.iterate();
                while (try it.next()) |found| {
                    if (skip.contains(found.oid) or seen.contains(found.oid)) continue;
                    try seen.put(odb.gpa, found.oid, {});
                    try entries.append(odb.gpa, .{ .oid = found.oid });
                }
            }
        }
        try odb.assignHints(io, arena, entries.items);
        collected.entries = try arena.dupe(PackEntry, entries.items);
        return collected;
    }

    /// Give every object a delta hint by reading the trees that name it.
    ///
    /// A loose object on its own says nothing about where it came from, and
    /// the delta search orders by exactly that: without a hint, two versions
    /// of one file sort next to two versions of a different file of the same
    /// length, and the window looks at the wrong base. One read per tree
    /// buys the whole ordering.
    fn assignHints(odb: *Odb, io: Io, arena: Allocator, entries: []PackEntry) Error!void {
        var hints: std.AutoHashMapUnmanaged(Oid, []const u8) = .empty;
        defer hints.deinit(odb.gpa);
        for (entries) |entry| {
            const head = odb.readHeader(io, entry.oid) catch continue;
            if (head.type != .tree) continue;
            const found = odb.read(io, entry.oid) catch continue;
            defer odb.gpa.free(found.bytes);
            var it = object.Tree.parse(odb.kind, found.bytes).iterate();
            while (it.next() catch null) |child| {
                if (hints.contains(child.oid)) continue;
                try hints.put(odb.gpa, child.oid, try arena.dupe(u8, child.name));
            }
        }
        for (entries) |*entry| {
            if (hints.get(entry.oid)) |name| entry.hint = name;
        }
    }

    fn findPackByName(odb: *Odb, base: []const u8) ?*pack.Pack {
        for (odb.sources.items) |*source| {
            for (source.pack_names.items, 0..) |name, i| {
                if (std.mem.eql(u8, name, base)) return &source.packs.items[i];
            }
        }
        return null;
    }

    /// How a repack behaves.
    pub const RepackOptions = struct {
        /// How the pack itself is built.
        pack: PackOptions = .{ .sync = .batch },
        /// Whether the loose objects the new pack now holds are removed.
        remove_loose: bool = true,
        /// Whether the packs the new one replaces are removed.
        ///
        /// Off, and not because it is hard: removing a pack a *second*
        /// process has open is safe on one platform and refused on another,
        /// and this package cannot tell whether one has. A caller that knows
        /// nothing else is reading the repository turns it on.
        remove_packs: bool = false,
    };

    /// What a repack did.
    pub const RepackReport = struct {
        /// The pack that was written, or `null` when there was nothing to
        /// write.
        written: ?pack.WriteReport = null,
        /// How many loose object files were removed.
        loose_removed: u32 = 0,
        /// How many packs the new one replaced and took away.
        packs_removed: u32 = 0,
    };

    /// Put every loose object into a pack and take the loose files away.
    ///
    /// The order is the one a running git has to survive: the pack is
    /// written and made durable, the index beside it likewise, this database
    /// re-scans so that it can read the new pack itself, and only then are
    /// the loose files removed -- and only the ones the new pack is confirmed
    /// to hold. At no point is an object in neither place.
    ///
    /// A reader that misses an object re-scans the pack directory once before
    /// it gives up, which is what closes the remaining window: a git that
    /// listed the packs before this ran and looked for a loose object after
    /// it finished finds the pack on its second look.
    pub fn packLoose(odb: *Odb, io: Io, options: RepackOptions) Error!RepackReport {
        var collected = try odb.collectLoose(io, .{});
        defer collected.deinit();
        return odb.packCollected(io, collected.entries, options, false);
    }

    /// Put every object the writable directory holds, loose and packed, into
    /// one pack.
    ///
    /// The same order as `packLoose`, and the same rule: nothing is taken
    /// away until the new pack is written, durable and readable here.
    pub fn repack(odb: *Odb, io: Io, options: RepackOptions) Error!RepackReport {
        var collected = try odb.collectAll(io, .{});
        defer collected.deinit();
        return odb.packCollected(io, collected.entries, options, options.remove_packs);
    }

    fn packCollected(
        odb: *Odb,
        io: Io,
        entries: []const PackEntry,
        options: RepackOptions,
        remove_packs: bool,
    ) Error!RepackReport {
        if (entries.len == 0) return .{};
        const collected: struct { entries: []const PackEntry } = .{ .entries = entries };

        const source = odb.writableSource();
        source.dir.createDir(io, "pack", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        var pack_dir = try source.dir.openDir(io, "pack", .{ .iterate = true });
        defer pack_dir.close(io);

        // Which packs were there before, so that the ones this replaces can
        // be named afterwards.
        var old_packs: std.ArrayList([]u8) = .empty;
        defer {
            for (old_packs.items) |name| odb.gpa.free(name);
            old_packs.deinit(odb.gpa);
        }
        if (remove_packs) {
            for (source.pack_names.items) |name| try old_packs.append(odb.gpa, try odb.gpa.dupe(u8, name));
        }

        const written = try odb.writePack(io, pack_dir, collected.entries, options.pack);
        if (options.pack.sync == .batch) try fs.syncBarrier(io, pack_dir);

        // The new pack has to be readable here before anything is taken
        // away, because it is this database that will be asked for those
        // objects next.
        try odb.refresh(io);

        var report: RepackReport = .{ .written = written };
        var hex: [hash.max_hex_len]u8 = undefined;
        var base_buf: [hash.max_hex_len + 8]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, "pack-{s}", .{written.name.hex(&hex)}) catch unreachable;
        const opened = odb.findPackByName(base) orelse return report;

        if (options.remove_loose) for (collected.entries) |entry| {
            // Never remove a loose object the pack does not hold. The pack
            // was written from this list, so this is a belt on top of a
            // brace -- and it is the one that makes a mistake here a wasted
            // syscall rather than a lost object.
            if ((try opened.index.find(entry.oid)) == null) continue;
            var path_buf: [hash.max_hex_len + 2]u8 = undefined;
            const path = odb.loosePath(entry.oid, &path_buf);
            source.dir.deleteFile(io, path) catch continue;
            report.loose_removed += 1;
        };

        if (remove_packs and old_packs.items.len != 0) {
            // The old packs are closed here first, because a file this
            // process still holds open is one Windows will not let it
            // remove.
            try odb.reopenPacks(io, 0);
            for (old_packs.items) |old_base| {
                // A repack of the same objects with the same settings writes
                // the same bytes, which gives the same checksum and so the
                // same name: the new pack *is* the old one, and removing it
                // would remove the repository.
                if (std.mem.eql(u8, old_base, base)) continue;
                var name_buf: [128]u8 = undefined;
                var removed = false;
                for ([_][]const u8{ ".idx", ".pack", ".rev", ".bitmap" }) |extension| {
                    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ old_base, extension }) catch continue;
                    if (pack_dir.deleteFile(io, name)) {
                        if (std.mem.eql(u8, extension, ".pack")) removed = true;
                    } else |_| {}
                }
                if (removed) report.packs_removed += 1;
            }
            try odb.reopenPacks(io, 0);
        }
        return report;
    }

    /// Close and re-open every pack of one source, so that a pack removed
    /// from the disk is gone from here too.
    fn reopenPacks(odb: *Odb, io: Io, source_index: usize) Error!void {
        const source = &odb.sources.items[source_index];
        for (source.packs.items) |*p| p.deinit(io);
        source.packs.clearRetainingCapacity();
        for (source.pack_names.items) |name| odb.gpa.free(name);
        source.pack_names.clearRetainingCapacity();
        if (source.midx) |*m| {
            m.deinit();
            source.midx = null;
        }
        source.midx_packs.clearRetainingCapacity();
        // The delta base cache is keyed on which pack an offset was in, and
        // the packs have just been renumbered.
        odb.cache.clear();
        odb.generation +%= 1;
        try odb.scanPacks(io, source_index);
    }

    /// A pack this database is filling, and the directory it lives in.
    pub const OpenPack = struct {
        writer: *pack.Writer,
        dir: Io.Dir,
    };

    /// Begin a pack in this database's own `objects/pack`, for a caller
    /// about to write many objects at once.
    ///
    /// The count is not stated, because the caller that wants this -- one
    /// staging a working tree -- does not know it until the walk is over.
    /// `finishPack` is what closes it; `abortPack` leaves nothing behind.
    pub fn beginPack(odb: *Odb, io: Io, options: PackOptions) Error!OpenPack {
        const source = odb.writableSource();
        source.dir.createDir(io, "pack", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        const dir = try source.dir.openDir(io, "pack", .{ .iterate = true });
        errdefer dir.close(io);
        const writer = try pack.Writer.initCounting(odb.gpa, io, dir, odb.kind, .{
            .sync = options.sync,
            .compression = options.compression,
        });
        return .{ .writer = writer, .dir = dir };
    }

    /// Write an object into an open pack rather than as a loose file.
    ///
    /// An object the database already holds, or that this pack already
    /// holds, is not written again -- which is the same rule `write`
    /// follows, and what keeps a tree staged twice from being two entries.
    pub fn writeInto(odb: *Odb, io: Io, filling: OpenPack, t: object.Type, bytes: []const u8) Error!Oid {
        const named = hash.Hasher.nameObject(odb.kind, odb.hashOptions(), t.name(), bytes);
        if (named.collision_attack) return error.CollisionAttack;
        const oid = named.oid;
        if (filling.writer.holds(oid) or try odb.exists(io, oid)) {
            odb.stats.loose_present += 1;
            return oid;
        }
        _ = try filling.writer.add(oid, t, bytes);
        odb.stats.packed_written += 1;
        return oid;
    }

    /// Close a pack begun with `beginPack` and make this database able to
    /// read it.
    ///
    /// A pack with nothing in it is not written at all: `null` comes back
    /// and the directory is as it was.
    pub fn finishPack(odb: *Odb, io: Io, filling: OpenPack) Error!?pack.WriteReport {
        defer {
            filling.writer.deinit(io);
            filling.dir.close(io);
        }
        if (filling.writer.count() == 0) {
            filling.writer.abort(io);
            return null;
        }
        const report = try filling.writer.finish(io);
        if (filling.writer.options.sync == .batch) try fs.syncBarrier(io, filling.dir);
        try odb.refresh(io);
        return report;
    }

    /// Give up on a pack begun with `beginPack`, leaving nothing behind.
    pub fn abortPack(odb: *Odb, io: Io, filling: OpenPack) void {
        _ = odb;
        filling.writer.abort(io);
        filling.writer.deinit(io);
        filling.dir.close(io);
    }

    /// How many packs are open. A caller measuring a repository asks here.
    pub fn packCount(odb: *const Odb) usize {
        var n: usize = 0;
        for (odb.sources.items) |*s| n += s.packs.items.len;
        return n;
    }

    /// How many of this database's object directories have a multi-pack
    /// index that parsed.
    pub fn multiPackIndexCount(odb: *const Odb) usize {
        var n: usize = 0;
        for (odb.sources.items) |*s| n += @intFromBool(s.midx != null);
        return n;
    }
};

/// One object to put in a pack.
pub const PackEntry = struct {
    oid: Oid,
    /// The path the object was found at, or empty where there is none.
    ///
    /// It is a hint for the delta search and nothing else: objects whose
    /// paths end the same way are usually versions of one file and so delta
    /// well against each other, which is the whole of git's ordering
    /// heuristic. A wrong hint costs compression and nothing else.
    hint: []const u8 = &.{},
};

/// Which delta encoding a pack is written with.
pub const DeltaEncoding = enum {
    /// A delta against an entry earlier in the same pack, named by how far
    /// back it is. Smaller, and what git writes by default.
    offset,
    /// A delta against a name. Larger by the width of a hash, and readable
    /// by a reader that cannot seek within the pack.
    reference,
    /// No deltas. Every object is written whole.
    none,
};

/// How a pack is built out of a set of objects.
pub const PackOptions = struct {
    /// The most delta candidates searched concurrently through the caller's
    /// `std.Io` executor. One starts no concurrent task and is exactly the
    /// serial writer. Larger values do not change object order, delta choice,
    /// or output bytes.
    threads: u16 = 1,
    /// How many objects already written each new one is tried against.
    /// git's default is ten. Zero writes no deltas.
    window: u32 = 10,
    /// How long a delta chain may get. git's default is fifty.
    depth: u32 = 50,
    /// Which delta encoding to write.
    delta: DeltaEncoding = .offset,
    /// How many bytes of window objects to hold at once. The window is
    /// emptied from the oldest end until it fits, so this is the bound on
    /// what building a pack costs in memory whatever the objects are.
    window_bytes: usize = 32 << 20,
    /// How many bytes of loose-object bodies the ordering pass may retain for
    /// the write pass. A retained object is opened and inflated once instead
    /// of twice. Objects that do not fit the remaining budget take the old
    /// two-read path; there is no eviction. Zero disables the cache.
    loose_cache_bytes: usize = 64 << 20,
    /// An object this large or larger is written whole and never enters the
    /// window. git's `core.bigFileThreshold`, and the same default.
    big_file_bytes: u64 = 512 << 20,
    /// How hard the two files are pushed towards the disk before they are
    /// renamed into place.
    sync: fs.Sync = .none,
    /// How hard the entries are compressed.
    compression: pack.Compression = .default,
};

/// One object held in the delta window.
const WindowSlot = struct {
    oid: Oid,
    type: object.Type,
    bytes: []u8,
    offset: u64,
    depth: u32,
    /// Built on the first candidate search that survives the cheap size and
    /// depth filters, then reused for the rest of this slot's window life.
    encoder: ?delta_mod.Encoder,

    fn getEncoder(slot: *WindowSlot, gpa: Allocator) Allocator.Error!*delta_mod.Encoder {
        if (slot.encoder == null) slot.encoder = try .init(gpa, slot.bytes);
        return &slot.encoder.?;
    }
};

const DeltaJob = struct {
    gpa: Allocator,
    encoder: *const delta_mod.Encoder,
    target: []const u8,
    limit: usize,
    slot: usize,
    result: Result = .pending,

    const Result = union(enum) {
        pending,
        failed: Allocator.Error,
        none,
        bytes: []u8,
    };

    fn run(job: *DeltaJob) Io.Cancelable!void {
        const encoded = job.encoder.encode(job.gpa, job.target, .{ .max_bytes = job.limit }) catch |err| {
            job.result = .{ .failed = err };
            return;
        };
        job.result = if (encoded) |bytes| .{ .bytes = bytes } else .none;
    }
};

const ChosenDelta = struct { slot: usize, bytes: []u8 };

fn findDelta(
    gpa: Allocator,
    io: Io,
    window: []WindowSlot,
    object_type: object.Type,
    target: []const u8,
    options: PackOptions,
    initial_limit: usize,
) Error!?ChosenDelta {
    var chosen: ?ChosenDelta = null;
    errdefer if (chosen) |c| gpa.free(c.bytes);
    var limit = initial_limit;

    if (options.threads <= 1) {
        var at = window.len;
        while (at != 0) {
            at -= 1;
            const slot = &window[at];
            // Types are contiguous in pack order, so the first mismatch also
            // means every older window entry is the wrong type.
            if (slot.type != object_type) break;
            limit = deltaCandidateLimit(initial_limit, options.depth, slot.depth, chosen, window);
            if (!worthTryingDelta(slot, target.len, options.depth, limit)) continue;
            const encoder = try slot.getEncoder(gpa);
            const candidate = try encoder.encode(gpa, target, .{ .max_bytes = limit }) orelse continue;
            if (chosen) |c| {
                const chosen_depth = window[c.slot].depth + 1;
                if (candidate.len == c.bytes.len and slot.depth + 1 >= chosen_depth) {
                    gpa.free(candidate);
                    continue;
                }
                gpa.free(c.bytes);
            }
            chosen = .{ .slot = at, .bytes = candidate };
        }
        return chosen;
    }

    const jobs = try gpa.alloc(DeltaJob, @min(@as(usize, options.threads), window.len));
    defer gpa.free(jobs);
    var at = window.len;
    while (at != 0) {
        var count: usize = 0;
        while (at != 0 and count < jobs.len) {
            at -= 1;
            const slot = &window[at];
            if (slot.type != object_type) {
                at = 0;
                break;
            }
            if (slot.depth >= options.depth or target.len < slot.bytes.len / 32) continue;
            const encoder = try slot.getEncoder(gpa);
            jobs[count] = .{
                .gpa = gpa,
                .encoder = encoder,
                .target = target,
                // Candidate bounds depend on earlier results in this batch.
                // Search speculatively, then apply those bounds in window
                // order below so every thread count makes the same choice.
                .limit = 0,
                .slot = at,
            };
            count += 1;
        }
        if (count == 0) break;

        var group: Io.Group = .init;
        for (jobs[0..count]) |*job| {
            group.concurrent(io, DeltaJob.run, .{job}) catch try job.run();
        }
        group.await(io) catch |err| {
            group.cancel(io);
            for (jobs[0..count]) |completed| switch (completed.result) {
                .bytes => |bytes| gpa.free(bytes),
                else => {},
            };
            return err;
        };

        for (jobs[0..count]) |job| {
            if (job.result == .failed) {
                for (jobs[0..count]) |completed| switch (completed.result) {
                    .bytes => |bytes| gpa.free(bytes),
                    else => {},
                };
                return job.result.failed;
            }
        }
        for (jobs[0..count]) |job| switch (job.result) {
            .bytes => |candidate| {
                const slot = &window[job.slot];
                limit = deltaCandidateLimit(initial_limit, options.depth, slot.depth, chosen, window);
                if (!worthTryingDelta(slot, target.len, options.depth, limit) or candidate.len > limit) {
                    gpa.free(candidate);
                    continue;
                }
                if (chosen) |c| {
                    const chosen_depth = window[c.slot].depth + 1;
                    if (candidate.len == c.bytes.len and slot.depth + 1 >= chosen_depth) {
                        gpa.free(candidate);
                        continue;
                    }
                    gpa.free(c.bytes);
                }
                chosen = .{ .slot = job.slot, .bytes = candidate };
            },
            else => {},
        };
    }
    return chosen;
}

/// The maximum delta worth asking the encoder for against one base. Besides
/// tightening to the best delta so far, the bound prices in how much chain
/// depth that base consumes: a shallower base may replace a same-sized deep
/// delta, while a nearly exhausted chain must save more.
fn deltaCandidateLimit(
    initial_limit: usize,
    max_depth: u32,
    base_depth: u32,
    chosen: ?ChosenDelta,
    window: []const WindowSlot,
) usize {
    if (base_depth >= max_depth) return 0;
    const best_size = if (chosen) |c| c.bytes.len else initial_limit;
    const reference_depth = if (chosen) |c| window[c.slot].depth + 1 else 1;
    if (reference_depth > max_depth) return 0;
    const numerator = @as(u128, best_size) * (max_depth - base_depth);
    const denominator = max_depth - reference_depth + 1;
    const depth_limit: usize = @intCast(numerator / denominator);
    return @min(best_size, depth_limit);
}

/// Filters whose answer needs only the sizes and chain depth, before a base
/// is indexed or either byte slice is searched.
fn worthTryingDelta(slot: *const WindowSlot, target_len: usize, max_depth: u32, limit: usize) bool {
    if (slot.depth >= max_depth or limit == 0) return false;
    const size_difference = if (slot.bytes.len < target_len) target_len - slot.bytes.len else 0;
    if (size_difference >= limit) return false;
    if (target_len < slot.bytes.len / 32) return false;
    return true;
}

/// What a sort puts the objects in order by.
const Ordered = struct {
    oid: Oid,
    type: object.Type,
    size: u64,
    name_hash: u32,
    cached: ?[]u8,
};

/// git's own name hash: the last sixteen non-blank characters of a path,
/// weighted so that the last ones count most, which makes paths that end the
/// same way sort together.
fn nameHash(name: []const u8) u32 {
    var value: u32 = 0;
    for (name) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        value = (value >> 2) +% (@as(u32, c) << 24);
    }
    return value;
}

/// git's delta-search order: type descending, then the name hash
/// descending, then size descending. Objects of one type end up together,
/// files with the same ending next to each other, and the largest first, so
/// that what follows is a delta against something at least as big.
fn beforeInPackOrder(_: void, a: Ordered, b: Ordered) bool {
    const at = @intFromEnum(a.type);
    const bt = @intFromEnum(b.type);
    if (at != bt) return at > bt;
    if (a.name_hash != b.name_hash) return a.name_hash > b.name_hash;
    if (a.size != b.size) return a.size > b.size;
    return std.mem.order(u8, a.oid.raw(), b.oid.raw()) == .lt;
}

test "delta candidate bounds account for chain depth" {
    const no_window: []const WindowSlot = &.{};
    try std.testing.expectEqual(@as(usize, 100), deltaCandidateLimit(100, 50, 0, null, no_window));
    try std.testing.expectEqual(@as(usize, 50), deltaCandidateLimit(100, 50, 25, null, no_window));
    try std.testing.expectEqual(@as(usize, 0), deltaCandidateLimit(100, 50, 50, null, no_window));
}

fn hexPair(name: []const u8) ?u8 {
    if (name.len != 2) return null;
    var value: u8 = 0;
    for (name) |c| {
        const digit: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        value = value * 16 + digit;
    }
    return value;
}

test "a loose object written is a loose object read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });

    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);

    const oid = try odb.write(io, .blob, "hello\n");
    var hex: [hash.max_hex_len]u8 = undefined;
    // git hash-object of "hello\n"
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", oid.hex(&hex));
    try std.testing.expect(try odb.exists(io, oid));

    const found = try odb.read(io, oid);
    defer gpa.free(found.bytes);
    try std.testing.expectEqual(object.Type.blob, found.type);
    try std.testing.expectEqualStrings("hello\n", found.bytes);

    const header = try odb.readHeader(io, oid);
    try std.testing.expectEqual(object.Type.blob, header.type);
    try std.testing.expectEqual(@as(u64, 6), header.size);

    const cached = try odb.readHeaderForPack(io, oid, 6);
    defer gpa.free(cached.bytes.?);
    try std.testing.expectEqualStrings("hello\n", cached.bytes.?);
    const too_large = try odb.readHeaderForPack(io, oid, 5);
    try std.testing.expect(too_large.bytes == null);

    // Writing the same bytes again is the same name and no second file.
    const again = try odb.write(io, .blob, "hello\n");
    try std.testing.expect(again.eql(oid));

    const report = try odb.verify(io);
    try std.testing.expectEqual(@as(u32, 1), report.loose);

    try std.testing.expectError(
        error.ObjectNotFound,
        odb.read(io, try Oid.parse(.sha1, "1" ** 40)),
    );
}

test "an abbreviated name resolves, and an ambiguous one is named" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);

    const oid = try odb.write(io, .blob, "hello\n");
    var hex: [hash.max_hex_len]u8 = undefined;
    const text = oid.hex(&hex);
    const resolved = try odb.findPrefix(io, text[0..8]);
    try std.testing.expect(resolved.eql(oid));
    try std.testing.expectError(error.ObjectNotFound, odb.findPrefix(io, "ffffffff"));
}

test "a streamed object is the same object" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);

    var stream: Odb.Stream = undefined;
    try odb.writeStream(io, .blob, 6, &stream);
    try stream.writer().writeAll("hel");
    try stream.writer().writeAll("lo\n");
    const oid = try stream.finish(io);
    stream.deinit(io);

    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", oid.hex(&hex));
    const found = try odb.read(io, oid);
    defer gpa.free(found.bytes);
    try std.testing.expectEqualStrings("hello\n", found.bytes);
}

test "a stream whose installation fails remains abortable" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);

    // A directory where the object `hello\n` (ce0136...) has to land. The
    // rename that installs it then fails for every user on every platform:
    // a read-only objects directory would not stop root, and CI runs the
    // oldest git in a container as root. (A file in the fan-out directory's
    // place is not an option: the Windows rename reports that as a
    // programmer bug rather than an error.)
    try tmp.dir.createDirPath(io, "objects/ce/013625030ba8dba906f756967f9e9ca394464a");

    var stream: Odb.Stream = undefined;
    try odb.writeStream(io, .blob, 6, &stream);
    // Released on every path: a stream that was installed after all must
    // not leak its buffers on the way to the failure report.
    defer stream.deinit(io);
    try stream.write("hello\n");
    if (stream.finish(io)) |_| return error.TestExpectedError else |err| switch (err) {
        error.IsDir, error.PathAlreadyExists, error.AccessDenied, error.PermissionDenied => {},
        else => return err,
    }

    var it = odb.sources.items[0].dir.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "tmp_obj_"));
    }
}
