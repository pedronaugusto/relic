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
};

/// Errors from the object database.
pub const Error = error{
    /// No loose object and no pack holds it, after one pack refresh.
    ObjectNotFound,
    /// A loose object whose inflated bytes do not match its own header.
    CorruptLooseObject,
    /// A loose object whose content does not hash to its own name.
    ObjectNameMismatch,
    /// An object read back as a type the caller did not ask for.
    UnexpectedObjectType,
    /// `objects/info/alternates` pointed at itself, or the chain was deeper
    /// than `Options.max_alternate_depth`.
    AlternatesTooDeep,
} || pack.Error || object.HeaderParseError || Allocator.Error ||
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
            if (source.pack_dir) |d| d.close(io);
            source.dir.close(io);
        }
        odb.sources.deinit(odb.gpa);
        if (odb.deflate_window.len != 0) odb.gpa.free(odb.deflate_window);
        odb.cache.deinit();
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
        var pack_id: u32 = 0;
        for (odb.sources.items) |*source| {
            for (source.packs.items) |*p| {
                defer pack_id += 1;
                const located = (try p.index.find(oid)) orelse continue;
                const obj = try p.readAt(io, located.offset, &odb.cache, pack_id);
                return .{ .type = obj.type, .bytes = obj.bytes };
            }
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
            const out = try odb.gpa.dupe(u8, body);
            odb.gpa.free(bytes);
            return .{ .type = parsed.header.type, .bytes = out };
        }
        return null;
    }

    fn inflateWhole(odb: *Odb, io: Io, file: Io.File) Error![]u8 {
        const input_buffer = try odb.gpa.alloc(u8, odb.options.read_buffer_size);
        defer odb.gpa.free(input_buffer);
        var file_reader = file.reader(io, input_buffer);
        const window = try odb.gpa.alloc(u8, flate.max_window_len);
        defer odb.gpa.free(window);
        var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, window);
        return decompress.reader.allocRemaining(odb.gpa, .limited(odb.options.max_object_bytes)) catch
            return error.CorruptLooseObject;
    }

    /// The type and length of `oid`, with no body inflated where the object
    /// is packed and with only its header inflated where it is loose.
    pub fn readHeader(odb: *Odb, io: Io, oid: Oid) Error!object.Header {
        if (try odb.tryReadHeader(io, oid)) |found| return found;
        try odb.refresh(io);
        if (try odb.tryReadHeader(io, oid)) |found| return found;
        return error.ObjectNotFound;
    }

    fn tryReadHeader(odb: *Odb, io: Io, oid: Oid) Error!?object.Header {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.sources.items) |*source| {
            const file = source.dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer file.close(io);
            var input_buffer: [1024]u8 = undefined;
            var file_reader = file.reader(io, &input_buffer);
            const window = try odb.gpa.alloc(u8, flate.max_window_len);
            defer odb.gpa.free(window);
            var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, window);
            var head: [64]u8 = @splat(0);
            var got: usize = 0;
            while (got < head.len) {
                const n = decompress.reader.readSliceShort(head[got..]) catch return error.CorruptLooseObject;
                if (n == 0) break;
                got += n;
                if (std.mem.indexOfScalar(u8, head[0..got], 0) != null) break;
            }
            const parsed = object.parseHeader(head[0..got]) catch return error.CorruptLooseObject;
            return parsed.header;
        }
        var pack_id: u32 = 0;
        for (odb.sources.items) |*source| {
            for (source.packs.items) |*p| {
                defer pack_id += 1;
                const located = (try p.index.find(oid)) orelse continue;
                return try p.headerAt(io, located.offset);
            }
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
            for (source.packs.items) |*p| {
                if ((try p.index.find(oid)) != null) return true;
            }
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
        const oid = hash.Hasher.object(odb.kind, t.name(), bytes);
        if (try odb.exists(io, oid)) return oid;

        const source = odb.writableSource();
        var hex: [hash.max_hex_len]u8 = undefined;
        const text = oid.hex(&hex);
        source.dir.createDir(io, text[0..2], .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        var sub = try source.dir.openDir(io, text[0..2], .{});
        defer sub.close(io);

        var name_buf: [128]u8 = undefined;
        const temp = fs.tempName(io, &name_buf, "tmp_obj_");
        var file = try sub.createFile(io, temp, .{ .exclusive = true });
        var failed = true;
        defer if (failed) {
            file.close(io);
            sub.deleteFile(io, temp) catch {};
        };

        var out_buf: [16 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &out_buf);
        // Level 1, which is what git's own `core.looseCompression` defaults
        // to. The library default is level 6: three times the processor time
        // for twenty per cent smaller objects, paid on every blob written.
        var compress = try flate.Compress.init(&file_writer.interface, odb.deflate_window, .zlib, .level_1);
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
        fs.renameWithRetry(io, sub, temp, text[2..]) catch |err| {
            sub.deleteFile(io, temp) catch {};
            return err;
        };
        if (odb.options.sync_directories) try fs.syncDir(io, sub);
        return oid;
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
        hasher: hash.Hasher,
        window: []u8,
        out_buffer: []u8,
        remaining: u64,
        finished: bool = false,

        /// Where the object's bytes go.
        pub fn writer(s: *Stream) *Io.Writer {
            return &s.compress.writer;
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
            s.finished = true;

            const oid = s.hasher.final();
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
            if (s.odb.options.sync_directories) try fs.syncDir(io, s.dir);
            return oid;
        }

        /// Give up, leaving the database as it was.
        pub fn abort(s: *Stream, io: Io) void {
            if (!s.finished) {
                s.file.close(io);
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
            .hasher = .init(odb.kind),
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
                    const name = hash.Hasher.object(odb.kind, found.type.name(), found.bytes);
                    if (!name.eql(oid)) return error.ObjectNameMismatch;
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

    /// How many packs are open. A caller measuring a repository asks here.
    pub fn packCount(odb: *const Odb) usize {
        var n: usize = 0;
        for (odb.sources.items) |*s| n += s.packs.items.len;
        return n;
    }
};

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
    try stream.write("hel");
    try stream.write("lo\n");
    const oid = try stream.finish(io);
    stream.deinit(io);

    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", oid.hex(&hex));
    const found = try odb.read(io, oid);
    defer gpa.free(found.bytes);
    try std.testing.expectEqualStrings("hello\n", found.bytes);
}
