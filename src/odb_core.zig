//! The object database: loose objects, the packs, and `objects/info/alternates`.
//!
//! Reading takes an allocator and gives the caller the bytes. Writing goes
//! through a uniquely-named temporary and a rename, so two writers of the same
//! object never meet and a reader never sees half of one.

// The modules relic's API puts under this one, as `relic.odb.<name>`.
const pack = @import("pack.zig");
const delta = @import("delta.zig");
const inflate = @import("inflate.zig");

const midx = @import("midx.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

const hash = @import("hash.zig");
const object = @import("object_core.zig");
const fs = @import("fs.zig");
const opening = @import("odbinit.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// How the object database behaves. The only caches in this package are
/// named here.
pub const Options = @import("odb_types.zig").Options;

/// Errors from the object database.
pub const Error = @import("odb_types.zig").Error;

/// Paths named directly by one `objects/info/alternates` file. `paths` hold
/// decoded names, and `text` holds the original file; release both with
/// `deinit` when finished.
pub const Alternates = struct {
    gpa: Allocator,
    text: []u8,
    paths: [][]u8,

    pub fn deinit(a: *Alternates) void {
        for (a.paths) |path| a.gpa.free(path);
        a.gpa.free(a.paths);
        a.gpa.free(a.text);
        a.* = undefined;
    }
};

fn alternateLine(raw: []const u8) ?[]const u8 {
    const line = std.mem.trimEnd(u8, raw, "\r");
    if (line.len == 0 or line[0] == '#') return null;
    return line;
}

/// Git accepts C-style quoted lines for names that cannot be written raw.
/// Malformed quoted lines name no directory, as an inaccessible path does.
fn parseAlternate(gpa: Allocator, raw: []const u8) Allocator.Error!?[]u8 {
    const line = alternateLine(raw) orelse return null;
    if (line[0] != '"') return try gpa.dupe(u8, line);
    if (line.len < 2 or line[line.len - 1] != '"') return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 1;
    while (i < line.len - 1) : (i += 1) {
        var c = line[i];
        if (c == '\\') {
            i += 1;
            if (i >= line.len - 1) return null;
            c = switch (line[i]) {
                'a' => 7,
                'b' => 8,
                'f' => 12,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => 11,
                '\\' => '\\',
                '"' => '"',
                '0'...'3' => blk: {
                    if (i + 2 >= line.len - 1) return null;
                    const d1 = line[i + 1];
                    const d2 = line[i + 2];
                    if (d1 < '0' or d1 > '7' or d2 < '0' or d2 > '7') return null;
                    const value = (line[i] - '0') * 64 + (d1 - '0') * 8 + (d2 - '0');
                    i += 2;
                    break :blk value;
                },
                else => return null,
            };
        } else if (c == '"') return null;
        try out.append(gpa, c);
    }
    if (out.items.len == 0 or std.mem.indexOfScalar(u8, out.items, 0) != null) return null;
    return try out.toOwnedSlice(gpa);
}

fn appendAlternatePath(gpa: Allocator, out: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    var quoted = path[0] == '#';
    for (path) |c| if (c < ' ' or c == 127 or c == '\\' or c == '"') {
        quoted = true;
        break;
    };
    if (!quoted) return out.appendSlice(gpa, path);
    try out.append(gpa, '"');
    for (path) |c| {
        switch (c) {
            '\\', '"' => {
                try out.append(gpa, '\\');
                try out.append(gpa, c);
            },
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            1...8, 11...12, 14...31, 127 => {
                try out.append(gpa, '\\');
                try out.append(gpa, '0' + (c >> 6));
                try out.append(gpa, '0' + ((c >> 3) & 7));
                try out.append(gpa, '0' + (c & 7));
            },
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}

const storage = @import("odbstate.zig");
const Source = storage.Source;
const DeflateState = storage.DeflateState;

/// How many bytes of an object's compressed form are gathered before the
/// first write. Sixty-four kilobytes is one write for anything a working tree
/// holds by the thousand, and a bound rather than a promise for the rest.
const deflate_output_buffer_len = 64 * 1024;

/// Counters saying how lookups resolved and what writing cost. Nothing
/// depends on them; they are how a caller, or a test, sees that an
/// accelerator is being used and that a batch of writes stayed cheap.
pub const Stats = @import("odb_types.zig").Stats;

/// The object database.
pub const Odb = struct {
    /// Owned format and storage state; never reassigned piecemeal.
    _state: *storage.State,
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
    /// What asks a partial clone's promisor remote for an object this
    /// database does not have, when a read meets one. `null` — the default,
    /// and the case in every repository that is not a partial clone — and a
    /// miss is `error.ObjectNotFound`.
    lazy: ?Lazy = null,

    fn backendData(db: *const Odb) *storage.Data {
        return storage.get(db._state);
    }

    /// The hash format selected at construction.
    pub fn objectFormat(db: *const Odb) Kind {
        return db.backendData().kind;
    }

    /// A copy of the storage policy selected at construction.
    pub fn settings(db: *const Odb) Options {
        return db.backendData().options;
    }

    /// The allocator that owns returned object bytes.
    pub fn allocator(db: *const Odb) Allocator {
        return db.backendData().gpa;
    }

    /// A fetch of missing objects, installed by the caller: `partial.zig`
    /// makes one.
    pub const Lazy = struct {
        context: *anyopaque,
        /// Bring `oids` into the database. Called with `lazy` unset, so a
        /// read it makes cannot ask again.
        fetch: *const fn (context: *anyopaque, io: Io, oids: []const Oid) (Allocator.Error || Io.Cancelable || error{PromisorFetchFailed})!void,
    };

    /// Ask the promisor remote for `oids`, then look again.
    pub fn fetchMissing(odb: *Odb, io: Io, oids: []const Oid) Error!void {
        const lazy = odb.lazy orelse return error.ObjectNotFound;
        odb.lazy = null;
        defer odb.lazy = lazy;
        try lazy.fetch(lazy.context, io, oids);
        try odb.refresh(io);
    }

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
        var odb = try opening.empty(Odb, gpa, io, kind, options);
        errdefer odb.deinit(io);

        const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
        // addSource transfers the handle when it registers the source. A
        // failure before that point leaves this scope as its sole owner.
        errdefer if (odb.backendData().sources.items.len == 0) objects.close(io);
        try odb.addSource(io, objects, true, 0);
        if (options.probe_timestamp_resolution) {
            odb.timestamp_resolution = fs.probeTimestampResolution(io, objects);
        }
        return odb;
    }

    /// Open an object database at an `objects` directory directly, for a
    /// caller that has one without a repository around it. The supplied
    /// handle is borrowed on success and failure; close it in the caller.
    pub fn openAt(
        gpa: Allocator,
        io: Io,
        objects_dir: Io.Dir,
        kind: Kind,
        options: Options,
    ) Error!Odb {
        var odb = try opening.empty(Odb, gpa, io, kind, options);
        errdefer odb.deinit(io);
        const owned = try objects_dir.openDir(io, ".", .{ .iterate = true });
        errdefer if (odb.backendData().sources.items.len == 0) owned.close(io);
        try odb.addSource(io, owned, true, 0);
        if (options.probe_timestamp_resolution) {
            odb.timestamp_resolution = fs.probeTimestampResolution(io, owned);
        }
        return odb;
    }

    /// Read the paths named directly by this database's alternates file.
    /// Relative paths are relative to its `objects` directory, as in git.
    /// Comments and empty lines are omitted, quoted names are decoded, and
    /// the caller owns the result.
    pub fn listAlternates(odb: *Odb, gpa: Allocator, io: Io) Error!Alternates {
        const file = (try fs.readFileAlloc(gpa, io, odb.backendData().sources.items[0].dir, "info/alternates", 1 << 20)) orelse try gpa.alloc(u8, 0);
        errdefer gpa.free(file);
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| gpa.free(path);
            paths.deinit(gpa);
        }
        var lines = std.mem.splitScalar(u8, file, '\n');
        while (lines.next()) |raw| if (try parseAlternate(gpa, raw)) |path| {
            paths.append(gpa, path) catch {
                gpa.free(path);
                return error.OutOfMemory;
            };
        };
        return .{ .gpa = gpa, .text = file, .paths = try paths.toOwnedSlice(gpa) };
    }

    /// Append one object-directory path if it is not already named. The
    /// newly named objects are available through this open database at once.
    pub fn addAlternate(odb: *Odb, io: Io, path: []const u8) Error!void {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAlternatePath;
        var listed = try odb.listAlternates(odb.backendData().gpa, io);
        defer listed.deinit();
        for (listed.paths) |existing| if (std.mem.eql(u8, existing, path)) return;
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(odb.backendData().gpa);
        try content.appendSlice(odb.backendData().gpa, listed.text);
        if (content.items.len != 0 and content.items[content.items.len - 1] != '\n') try content.append(odb.backendData().gpa, '\n');
        try appendAlternatePath(odb.backendData().gpa, &content, path);
        try content.append(odb.backendData().gpa, '\n');
        try odb.writeAlternates(io, content.items);
    }

    /// Remove every direct line naming `path`, preserving other paths and
    /// comments. A path absent from the file changes nothing.
    pub fn removeAlternate(odb: *Odb, io: Io, path: []const u8) Error!void {
        var listed = try odb.listAlternates(odb.backendData().gpa, io);
        defer listed.deinit();
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(odb.backendData().gpa);
        var changed = false;
        var cursor: usize = 0;
        while (cursor < listed.text.len) {
            const end = std.mem.indexOfScalarPos(u8, listed.text, cursor, '\n') orelse listed.text.len;
            const raw = listed.text[cursor..end];
            if (try parseAlternate(odb.backendData().gpa, raw)) |existing| {
                defer odb.backendData().gpa.free(existing);
                if (std.mem.eql(u8, existing, path)) {
                    changed = true;
                    cursor = @min(end + 1, listed.text.len);
                    continue;
                }
            }
            const next = @min(end + 1, listed.text.len);
            try content.appendSlice(odb.backendData().gpa, listed.text[cursor..next]);
            cursor = next;
        }
        if (changed) try odb.writeAlternates(io, content.items);
    }

    fn writeAlternates(odb: *Odb, io: Io, content: []const u8) Error!void {
        if (content.len > 1 << 20) return error.AlternatesTooLarge;
        const dir = odb.backendData().sources.items[0].dir;
        try dir.createDirPath(io, "info");
        try fs.atomicWrite(io, dir, "info/alternates", content, "alternates-", odb.backendData().options.sync);
        // The own source remains open; rebuild the chain below it so reads
        // immediately see additions and stop seeing removed alternates.
        for (odb.backendData().sources.items[1..]) |*source| odb.closeSource(io, source);
        odb.backendData().sources.items.len = 1;
        odb.backendData().cache.clear();
        try odb.readAlternates(io, dir, 0);
        odb.backendData().generation += 1;
    }

    fn addSource(odb: *Odb, io: Io, dir: Io.Dir, writable: bool, depth: u8) Error!void {
        if (depth > odb.backendData().options.max_alternate_depth) return error.AlternatesTooDeep;
        try opening.register(odb, io, dir, writable);
        try odb.scanPacks(io, odb.backendData().sources.items.len - 1);
        try odb.readAlternates(io, dir, depth);
    }

    fn readAlternates(odb: *Odb, io: Io, dir: Io.Dir, depth: u8) Error!void {
        const text = (try fs.readFileAlloc(odb.backendData().gpa, io, dir, "info/alternates", 1 << 20)) orelse return;
        defer odb.backendData().gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = (try parseAlternate(odb.backendData().gpa, raw_line)) orelse continue;
            defer odb.backendData().gpa.free(line);
            const alt = (try opening.openDirectory(io, dir, line)) orelse continue;
            const before = odb.backendData().sources.items.len;
            odb.addSource(io, alt, false, depth + 1) catch |err| {
                if (odb.backendData().sources.items.len == before) {
                    // The source was never registered: this scope owns alt.
                    alt.close(io);
                } else {
                    // Registration transferred the handles to the database,
                    // including any deeper sources. Undo that whole suffix.
                    for (odb.backendData().sources.items[before..]) |*source| odb.closeSource(io, source);
                    odb.backendData().sources.items.len = before;
                }
                return err;
            };
        }
    }

    fn scanPacks(odb: *Odb, io: Io, source_index: usize) Error!void {
        const source = &odb.backendData().sources.items[source_index];
        const pack_dir = source.pack_dir orelse return;
        var it = pack_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            const base = entry.name[0 .. entry.name.len - 4];
            var already = false;
            for (source.packs.items) |named| {
                if (std.mem.eql(u8, named.name, base)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            var opened = pack.Pack.open(odb.backendData().gpa, io, pack_dir, base, odb.backendData().kind, .{
                .access = if (odb.backendData().options.map_packs) .map else .read,
                .max_depth = odb.backendData().options.max_delta_depth,
                .read_cache_bytes = odb.backendData().options.pack_read_cache_bytes,
            }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return err,
            };
            errdefer opened.deinit(io);
            const name = try odb.backendData().gpa.dupe(u8, base);
            errdefer odb.backendData().gpa.free(name);
            try source.packs.append(odb.backendData().gpa, .{ .pack = opened, .name = name });
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
        const source = &odb.backendData().sources.items[source_index];
        if (source.midx) |*old| old.deinit();
        source.midx = null;
        source.midx_packs.clearRetainingCapacity();

        const pack_dir = source.pack_dir orelse return;
        var index = (midx.Index.open(odb.backendData().gpa, io, pack_dir, odb.backendData().kind) catch |err| switch (err) {
            error.NotAMultiPackIndex, error.UnsupportedMidxVersion, error.ObjectFormatMismatch, error.CorruptMultiPackIndex, error.ChainUnsupported => return,
            else => |failure| return failure,
        }) orelse return;
        errdefer index.deinit();

        var position: u32 = 0;
        while (position < index.pack_count) : (position += 1) {
            const name = index.packName(position);
            var at: ?u32 = null;
            if (name) |text| {
                for (source.packs.items, 0..) |named, i| {
                    if (std.mem.eql(u8, named.name, text)) {
                        at = @intCast(i);
                        break;
                    }
                }
            }
            source.midx_packs.append(odb.backendData().gpa, at) catch return error.OutOfMemory;
        }
        source.midx = index;
    }

    /// Re-scan every pack directory, picking up packs written since the last
    /// scan. `read` does this once on a miss; a caller watching a repository
    /// a `gc` runs in may call it.
    pub fn refresh(odb: *Odb, io: Io) Error!void {
        for (0..odb.backendData().sources.items.len) |i| try odb.scanPacks(io, i);
        odb.backendData().generation += 1;
    }

    /// Close every pack and release everything held.
    pub fn deinit(odb: *Odb, io: Io) void {
        for (odb.backendData().sources.items) |*source| odb.closeSource(io, source);
        odb.backendData().sources.deinit(odb.backendData().gpa);
        if (odb.backendData().deflate_window.len != 0) odb.backendData().gpa.free(odb.backendData().deflate_window);
        if (odb.backendData().deflate_state) |state| {
            odb.backendData().gpa.destroy(state.compress);
            odb.backendData().gpa.free(state.buffer);
        }
        odb.backendData().cache.deinit();
        odb.shallow.deinit(odb.backendData().gpa);
        const owned = odb.backendData();
        owned.gpa.destroy(owned);
        odb.* = undefined;
    }

    fn closeSource(odb: *Odb, io: Io, source: *Source) void {
        for (source.packs.items) |*named| named.deinit(odb.backendData().gpa, io);
        source.packs.deinit(odb.backendData().gpa);
        if (source.midx) |*index| index.deinit();
        source.midx_packs.deinit(odb.backendData().gpa);
        if (source.pack_dir) |d| d.close(io);
        source.dir.close(io);
    }

    /// The hash every name in this database is written with.
    pub fn hashKind(odb: *const Odb) Kind {
        return odb.backendData().kind;
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
        if (odb.lazy != null) {
            try odb.fetchMissing(io, &.{oid});
            if (try odb.tryRead(io, oid)) |found| return found;
        }
        return error.ObjectNotFound;
    }

    /// An object read into a buffer the caller keeps: `bytes` is that
    /// buffer's `items`.
    pub const Borrowed = struct {
        type: object.Type,
        bytes: []const u8,
    };

    /// Read the object named `oid` into `buffer`, which keeps its capacity
    /// from one call to the next, so that reading many objects one after
    /// another reuses one allocation for their bytes.
    ///
    /// `buffer` is cleared, grows with `allocator()` when the object needs
    /// more room, and is the caller's to free with that allocator. The
    /// returned `bytes` are `buffer.items`, borrowed: valid until `buffer`
    /// is next read into, changed or freed. On an error `buffer`'s contents
    /// are unspecified, and it is still the caller's to reuse or free.
    /// Looking up, re-scanning and asking a promisor are as `read` does
    /// them. A packed whole object needs no other allocation once `buffer`
    /// is large enough; a loose object still allocates its read buffer, and
    /// a delta its chain.
    pub fn readInto(odb: *Odb, io: Io, oid: Oid, buffer: *std.ArrayList(u8)) Error!Borrowed {
        if (try odb.tryReadInto(io, oid, buffer)) |found| return found;
        try odb.refresh(io);
        if (try odb.tryReadInto(io, oid, buffer)) |found| return found;
        if (odb.lazy != null) {
            try odb.fetchMissing(io, &.{oid});
            if (try odb.tryReadInto(io, oid, buffer)) |found| return found;
        }
        return error.ObjectNotFound;
    }

    fn tryReadInto(odb: *Odb, io: Io, oid: Oid, buffer: *std.ArrayList(u8)) Error!?Borrowed {
        var base: u32 = 0;
        for (odb.backendData().sources.items) |*source| {
            defer base += @intCast(source.packs.items.len);
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            const p = &source.packs.items[located.at].pack;
            const t = try p.readAtInto(io, located.offset, &odb.backendData().cache, base + @as(u32, @intCast(located.at)), buffer);
            return .{ .type = t, .bytes = buffer.items };
        }
        const found = (try odb.readLooseFor(io, oid, .{ .list = buffer })) orelse return null;
        return .{ .type = found.header.type, .bytes = buffer.items };
    }

    /// The packs first, then the loose objects, as git looks: a name is its
    /// content, so where it is found does not change what is read, and in a
    /// packed repository a loose lookup first is a failed `open` for every
    /// object.
    fn tryRead(odb: *Odb, io: Io, oid: Oid) Error!?Read {
        var base: u32 = 0;
        for (odb.backendData().sources.items) |*source| {
            defer base += @intCast(source.packs.items.len);
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            const p = &source.packs.items[located.at].pack;
            const obj = try p.readAt(io, located.offset, &odb.backendData().cache, base + @as(u32, @intCast(located.at)));
            return .{ .type = obj.type, .bytes = obj.bytes };
        }
        return odb.readLoose(io, oid);
    }

    fn readLoose(odb: *Odb, io: Io, oid: Oid) Error!?Read {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.backendData().sources.items) |*source| {
            const file = source.dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer file.close(io);
            const bytes = try odb.inflateWhole(io, file);
            errdefer odb.backendData().gpa.free(bytes);
            const parsed = object.parseHeader(bytes) catch return error.CorruptLooseObject;
            const body = bytes[parsed.len..];
            if (body.len != parsed.header.size) return error.CorruptLooseObject;
            // The body moves to the front of the allocation it was inflated
            // into, rather than into a second one.
            std.mem.copyForwards(u8, bytes[0..body.len], body);
            const out = try odb.backendData().gpa.realloc(bytes, body.len);
            return .{ .type = parsed.header.type, .bytes = out };
        }
        return null;
    }

    fn inflateWhole(odb: *Odb, io: Io, file: Io.File) Error![]u8 {
        const input_buffer = try odb.backendData().gpa.alloc(u8, odb.backendData().options.read_buffer_size);
        defer odb.backendData().gpa.free(input_buffer);
        var file_reader = file.reader(io, input_buffer);
        var window: [flate.max_window_len]u8 = undefined;
        var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, &window);
        return decompress.reader.allocRemaining(odb.backendData().gpa, .limited(odb.backendData().options.max_object_bytes)) catch |err| switch (err) {
            error.OutOfMemory, error.StreamTooLong => |e| return e,
            error.ReadFailed => return looseInflateError(&decompress, &file_reader),
        };
    }

    // The inflater's ReadFailed can mean bad zlib or a failed file read.
    // Only the latter has a cause on the file reader.
    fn looseInflateError(decompress: *const flate.Decompress, reader: *const Io.File.Reader) Error {
        if (decompress.err) |cause| {
            if (cause == error.ReadFailed) return reader.err orelse error.ReadFailed;
        }
        return error.CorruptLooseObject;
    }

    /// The type and length of `oid`, with no body inflated where the object
    /// is packed and with only its header inflated where it is loose.
    pub fn readHeader(odb: *Odb, io: Io, oid: Oid) Error!object.Header {
        return (try odb.readHeaderForPack(io, oid, 0)).header;
    }

    /// The header of `oid` from the first pack that holds it, or `null`
    /// when none does; no loose copy is looked for.
    fn packedHeader(odb: *Odb, io: Io, oid: Oid) Error!?object.Header {
        for (odb.backendData().sources.items) |*source| {
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            return try source.packs.items[located.at].pack.headerAt(io, located.offset);
        }
        return null;
    }

    /// Where `oid`'s whole object is in the first pack that holds it, for
    /// `Pack.inflateWith`; `null` when no pack holds it or it is a delta
    /// there, which `read` resolves.
    fn locateWhole(odb: *Odb, io: Io, oid: Oid) Error!?PackedAt {
        for (odb.backendData().sources.items) |*source| {
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            const p = &source.packs.items[located.at].pack;
            const entry = try p.entryHeaderAt(io, located.offset);
            return switch (entry.kind) {
                .object => |t| .{ .pack = p, .type = t, .at = entry.data_at, .size = entry.size },
                .ofs_delta, .ref_delta => null,
            };
        }
        return null;
    }

    const PackHeader = struct {
        header: object.Header,
        /// A loose body retained while reading its header, when it fit the
        /// caller's remaining cache budget.
        bytes: ?[]u8 = null,
        /// Whether the header came from a loose object, which is where its
        /// body is then read from too.
        loose: bool = false,
    };

    /// The pack ordering pass has already opened a loose object. When its
    /// body fits `cache_available`, finish that inflate and hand the body to
    /// the write pass rather than opening and inflating it again.
    fn readHeaderForPack(odb: *Odb, io: Io, oid: Oid, cache_available: usize) Error!PackHeader {
        if (try odb.tryReadHeaderForPack(io, oid, cache_available)) |found| return found;
        try odb.refresh(io);
        if (try odb.tryReadHeaderForPack(io, oid, cache_available)) |found| return found;
        if (odb.lazy != null) {
            try odb.fetchMissing(io, &.{oid});
            if (try odb.tryReadHeaderForPack(io, oid, cache_available)) |found| return found;
        }
        return error.ObjectNotFound;
    }

    fn tryReadHeaderForPack(odb: *Odb, io: Io, oid: Oid, cache_available: usize) Error!?PackHeader {
        const want: LooseWant = if (cache_available == 0) .header else .{ .cache = cache_available };
        if (try odb.readLooseFor(io, oid, want)) |found| return .{ .header = found.header, .bytes = found.bytes, .loose = true };
        for (odb.backendData().sources.items) |*source| {
            const located = (try source.findPack(oid, &odb.stats)) orelse continue;
            return .{ .header = try source.packs.items[located.at].pack.headerAt(io, located.offset) };
        }
        return null;
    }

    /// What `readLooseFor` reads besides the header.
    const LooseWant = union(enum) {
        /// Nothing.
        header,
        /// The body, into this buffer, which is exactly its size. A body
        /// of any other size is `error.CorruptLooseObject`.
        into: []u8,
        /// The body, allocated, when it is at most this many bytes.
        cache: usize,
        /// The body, into this list, cleared and grown as needed.
        list: *std.ArrayList(u8),
    };

    const LooseFound = struct {
        header: object.Header,
        /// The allocated body, for `.cache`.
        bytes: ?[]u8 = null,
    };

    /// The loose object `oid`'s header, and its body as `want` says, or
    /// `null` when no source holds it loose.
    ///
    /// With `.header` and `.into` this allocates nothing and touches nothing
    /// of the database but its sources' directory handles, so pack-writing
    /// tasks call it concurrently; `.cache` and `.list` allocate, and are
    /// the calling task's.
    fn readLooseFor(odb: *const Odb, io: Io, oid: Oid, want: LooseWant) Error!?LooseFound {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.backendData().sources.items) |*source| {
            const file = source.dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer file.close(io);
            // Both buffers live on the stack: a pack write asks for tens of
            // thousands of headers in a row, and an allocation for each was
            // a measurable share of it.
            // Most loose blobs fit this read, including the zlib trailer.
            // A tiny input buffer made the body cache pay several syscalls
            // for the single inflate it was meant to save.
            var input_buffer: [16 * 1024]u8 = undefined;
            if (want == .header) {
                // The zlib header, the first block's and the object's own
                // fit a kilobyte whatever the object's size.
                var header_reader = file.reader(io, input_buffer[0..1024]);
                return .{ .header = try looseHeader(&header_reader) };
            }
            var file_reader = file.reader(io, &input_buffer);
            var window: [flate.max_window_len]u8 = undefined;
            var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, &window);
            var head: [64]u8 = @splat(0);
            var got: usize = 0;
            while (got < head.len) {
                const n = decompress.reader.readSliceShort(head[got..]) catch return looseInflateError(&decompress, &file_reader);
                if (n == 0) break;
                got += n;
                if (std.mem.indexOfScalar(u8, head[0..got], 0) != null) break;
            }
            const parsed = object.parseHeader(head[0..got]) catch return error.CorruptLooseObject;
            const body: []u8 = switch (want) {
                .header => unreachable,
                .cache => |available| blk: {
                    if (available == 0 or parsed.header.size > available) return .{ .header = parsed.header };
                    break :blk try odb.backendData().gpa.alloc(u8, @intCast(parsed.header.size));
                },
                .into => |buffer| blk: {
                    if (parsed.header.size != buffer.len) return error.CorruptLooseObject;
                    break :blk buffer;
                },
                .list => |list| blk: {
                    const len = std.math.cast(usize, parsed.header.size) orelse return error.StreamTooLong;
                    if (parsed.header.size > odb.backendData().options.max_object_bytes) return error.StreamTooLong;
                    list.clearRetainingCapacity();
                    try list.resize(odb.backendData().gpa, len);
                    break :blk list.items;
                },
            };
            errdefer if (want == .cache) odb.backendData().gpa.free(body);

            const initial = head[parsed.len..got];
            if (initial.len > body.len) return error.CorruptLooseObject;
            @memcpy(body[0..initial.len], initial);
            var body_got = initial.len;
            while (body_got < body.len) {
                const n = decompress.reader.readSliceShort(body[body_got..]) catch return looseInflateError(&decompress, &file_reader);
                if (n == 0) return error.CorruptLooseObject;
                body_got += n;
            }
            var extra: [1]u8 = undefined;
            if ((decompress.reader.readSliceShort(&extra) catch return looseInflateError(&decompress, &file_reader)) != 0) {
                return error.CorruptLooseObject;
            }
            return .{ .header = parsed.header, .bytes = if (want == .cache) body else null };
        }
        return null;
    }

    /// A loose object's header, with no more of it inflated than the
    /// header's own bytes and what decodes with them: the decoder writes
    /// straight into a buffer the size of the longest header, rather than
    /// filling its window.
    fn looseHeader(file_reader: *Io.File.Reader) Error!object.Header {
        var decompress: flate.Decompress = .init(&file_reader.interface, .zlib, &.{});
        var head: [64]u8 = undefined;
        var out: Io.Writer = .fixed(&head);
        while (std.mem.indexOfScalar(u8, out.buffered(), 0) == null and out.end < head.len) {
            const n = decompress.reader.stream(&out, .limited(head.len - out.end)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return looseInflateError(&decompress, file_reader),
                // The limit is the room left.
                error.WriteFailed => unreachable,
            };
            // A match longer than the room left: no header is that long.
            if (n == 0) break;
        }
        const parsed = object.parseHeader(out.buffered()) catch return error.CorruptLooseObject;
        return parsed.header;
    }

    /// Whether the database holds `oid`, without reading it.
    ///
    /// Does not refresh: a caller asking whether an object is present before
    /// writing it wants an answer, not a directory scan.
    pub fn exists(odb: *Odb, io: Io, oid: Oid) Error!bool {
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        for (odb.backendData().sources.items) |*source| {
            if (try opening.exists(io, source.dir, path)) return true;
        }
        for (odb.backendData().sources.items) |*source| {
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
        if (prefix.len < 2 or prefix.len > odb.backendData().kind.hexLen()) return error.ObjectNotFound;
        var found: ?Oid = null;
        for (odb.backendData().sources.items) |*source| {
            var dir_name: [3]u8 = .{ prefix[0], prefix[1], 0 };
            const sub = try opening.openDirectory(io, source.dir, dir_name[0..2]);
            if (sub) |d| {
                defer d.close(io);
                var it = d.iterate();
                while (try it.next(io)) |entry| {
                    if (entry.kind == .directory) continue;
                    if (entry.name.len != odb.backendData().kind.hexLen() - 2) continue;
                    var full: [hash.max_hex_len]u8 = undefined;
                    @memcpy(full[0..2], prefix[0..2]);
                    @memcpy(full[2..][0..entry.name.len], entry.name);
                    const oid = Oid.parse(odb.backendData().kind, full[0 .. 2 + entry.name.len]) catch continue;
                    if (!oid.startsWithHex(prefix)) continue;
                    if (found) |f| {
                        if (!f.eql(oid)) return error.AmbiguousPrefix;
                    } else found = oid;
                }
            }
            for (source.packs.items) |*named| {
                const p = &named.pack;
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
        const named = hash.Hasher.nameObject(odb.backendData().kind, odb.hashOptions(), t.name(), bytes);
        if (named.collision_attack) return error.CollisionAttack;
        const oid = named.oid;
        if (try odb.exists(io, oid)) {
            odb.stats.loose_present += 1;
            return oid;
        }
        try odb.writeLoose(io, t, bytes, oid);
        return oid;
    }

    /// Whether `oid` is in this database's own objects, loose or packed,
    /// and not only in an alternate.
    pub fn existsOwn(odb: *Odb, io: Io, oid: Oid) Error!bool {
        const source = odb.writableSource();
        var path_buf: [hash.max_hex_len + 2]u8 = undefined;
        const path = odb.loosePath(oid, &path_buf);
        if (try opening.exists(io, source.dir, path)) return true;
        return (try source.findPack(oid, &odb.stats)) != null;
    }

    /// Take `oid` into this database's own objects when only an alternate
    /// holds it, so that it stays readable here whatever becomes of the
    /// alternate: a repository that borrows another's objects owns what it
    /// cannot afford to lose. An object already here is left as it is.
    pub fn own(odb: *Odb, io: Io, oid: Oid) Error!void {
        if (try odb.existsOwn(io, oid)) return;
        const found = try odb.read(io, oid);
        defer odb.backendData().gpa.free(found.bytes);
        try odb.writeLoose(io, found.type, found.bytes, oid);
    }

    /// Writes `bytes`, named `oid`, as a loose object in this database's own
    /// objects, whatever an alternate holds.
    fn writeLoose(odb: *Odb, io: Io, t: object.Type, bytes: []const u8, oid: Oid) Error!void {
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
        compress.* = try flate.Compress.init(&file_writer.interface, odb.backendData().deflate_window, .zlib, .level_1);
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ t.name(), bytes.len }) catch unreachable;
        try compress.writer.writeAll(header);
        try compress.writer.writeAll(bytes);
        try compress.writer.flush();
        try compress.finish();
        try file_writer.interface.flush();
        switch (odb.backendData().options.sync) {
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
        if (odb.backendData().options.sync_directories) {
            const sub = try source.dir.openDir(io, text[0..2], .{});
            defer sub.close(io);
            try fs.syncDir(io, sub);
        }
        odb.stats.loose_written += 1;
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
        if (odb.backendData().deflate_state) |state| return state;
        const compress = try odb.backendData().gpa.create(flate.Compress);
        errdefer odb.backendData().gpa.destroy(compress);
        const buffer = try odb.backendData().gpa.alloc(u8, deflate_output_buffer_len);
        odb.backendData().deflate_state = .{ .compress = compress, .buffer = buffer };
        return odb.backendData().deflate_state.?;
    }

    /// The naming options every name this database takes is given.
    fn hashOptions(odb: *const Odb) hash.Hasher.Options {
        return .{ .detect_collisions = odb.backendData().options.detect_sha1_collisions };
    }

    fn writableSource(odb: *Odb) *Source {
        for (odb.backendData().sources.items) |*s| {
            if (s.writable) return s;
        }
        return &odb.backendData().sources.items[0];
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
            const s: *Stream = @alignCast(@fieldParentPtr("input_writer", w)); // safe: this function is installed only on a Stream's input_writer
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
            switch (s.odb.backendData().options.sync) {
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
            if (s.odb.backendData().options.sync_directories) try fs.syncDir(io, s.dir);
            return oid;
        }

        /// Give up, leaving the database as it was.
        pub fn abort(s: *Stream, io: Io) void {
            if (!s.finished) {
                if (s.file_open) s.file.close(io);
                s.dir.deleteFile(io, s.temp[0..s.temp_len]) catch {};
                s.finished = true;
            }
            s.odb.backendData().gpa.free(s.window);
            s.odb.backendData().gpa.free(s.out_buffer);
        }

        /// Release the stream's buffers after a successful `finish`.
        pub fn deinit(s: *Stream, io: Io) void {
            if (!s.finished) {
                s.abort(io);
                return;
            }
            s.odb.backendData().gpa.free(s.window);
            s.odb.backendData().gpa.free(s.out_buffer);
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
        const window = try odb.backendData().gpa.alloc(u8, flate.max_window_len);
        errdefer odb.backendData().gpa.free(window);
        const out_buffer = try odb.backendData().gpa.alloc(u8, 16 * 1024);
        errdefer odb.backendData().gpa.free(out_buffer);

        out.* = .{
            .odb = odb,
            .dir = source.dir,
            .temp = undefined,
            .temp_len = temp.len,
            .file = file,
            .file_writer = undefined,
            .compress = undefined,
            .input_writer = .{ .vtable = &.{ .drain = Stream.drain }, .buffer = &.{} },
            .hasher = .initOptions(odb.backendData().kind, odb.hashOptions()),
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
        for (odb.backendData().sources.items) |*source| {
            var top = source.dir.iterate();
            while (try top.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                if (entry.name.len != 2) continue;
                if (hexPair(entry.name) == null) continue;
                const sub = (try opening.openDirectory(io, source.dir, entry.name)) orelse continue;
                defer sub.close(io);
                var it = sub.iterate();
                while (try it.next(io)) |file_entry| {
                    if (file_entry.kind == .directory) continue;
                    if (file_entry.name.len != odb.backendData().kind.hexLen() - 2) continue;
                    var full: [hash.max_hex_len]u8 = undefined;
                    @memcpy(full[0..2], entry.name);
                    @memcpy(full[2..][0..file_entry.name.len], file_entry.name);
                    const oid = Oid.parse(odb.backendData().kind, full[0 .. 2 + file_entry.name.len]) catch continue;
                    const found = (try odb.readLoose(io, oid)) orelse continue;
                    defer odb.backendData().gpa.free(found.bytes);
                    const named = hash.Hasher.nameObject(odb.backendData().kind, odb.hashOptions(), found.type.name(), found.bytes);
                    if (named.collision_attack) return error.CollisionAttack;
                    if (!named.oid.eql(oid)) return error.ObjectNameMismatch;
                    report.loose += 1;
                    report.bytes += found.bytes.len;
                }
            }
        }
        var pack_id: u32 = 0;
        for (odb.backendData().sources.items) |*source| {
            for (source.packs.items) |*named| {
                const p = &named.pack;
                defer pack_id += 1;
                const pack_report = try p.verify(io, &odb.backendData().cache, pack_id);
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
        errdefer set.deinit(odb.backendData().gpa);
        for (odb.backendData().sources.items) |*source| {
            var top = source.dir.iterate();
            while (try top.next(io)) |entry| {
                if (entry.kind != .directory or entry.name.len != 2) continue;
                if (hexPair(entry.name) == null) continue;
                const sub = (try opening.openDirectory(io, source.dir, entry.name)) orelse continue;
                defer sub.close(io);
                var it = sub.iterate();
                while (try it.next(io)) |file_entry| {
                    if (file_entry.name.len != odb.backendData().kind.hexLen() - 2) continue;
                    var full: [hash.max_hex_len]u8 = undefined;
                    @memcpy(full[0..2], entry.name);
                    @memcpy(full[2..][0..file_entry.name.len], file_entry.name);
                    const oid = Oid.parse(odb.backendData().kind, full[0 .. 2 + file_entry.name.len]) catch continue;
                    try set.put(odb.backendData().gpa, oid, {});
                }
            }
            for (source.packs.items) |*named| {
                const p = &named.pack;
                var it = p.index.iterate();
                while (try it.next()) |found| try set.put(odb.backendData().gpa, found.oid, {});
            }
        }
        return set;
    }

    /// Own and make every object reachable from `roots` durable before the
    /// caller records an intent using their IDs. Commits include parents and
    /// tags include targets; gitlinks and LFS payloads are separate stores.
    /// Existing objects are synced too, independent of `Options.sync`.
    /// This reads the closure and opens/syncs each loose object or used pack
    /// and index, then their directories. The supplied store directory's own
    /// parent entry remains the caller's responsibility.
    pub fn makeDurable(odb: *Odb, io: Io, roots: []const Oid) Error!void {
        const barrier = @import("durability.zig");
        var seen: Oid.Set = .empty;
        defer seen.deinit(odb.backendData().gpa);
        var pending: std.ArrayList(Oid) = .empty;
        defer pending.deinit(odb.backendData().gpa);
        try pending.appendSlice(odb.backendData().gpa, roots);
        while (pending.pop()) |oid| {
            if (oid.kind != odb.backendData().kind) return error.ObjectFormatMismatch;
            const slot = try seen.getOrPut(odb.backendData().gpa, oid);
            if (slot.found_existing) continue;
            try odb.own(io, oid);
            const found = try odb.read(io, oid);
            defer odb.backendData().gpa.free(found.bytes);
            switch (found.type) {
                .blob => {},
                .tree => {
                    var tree = object.Tree.parse(odb.backendData().kind, found.bytes);
                    var entries = tree.iterate();
                    while (try entries.next()) |entry| {
                        if (entry.mode != .gitlink) try pending.append(odb.backendData().gpa, entry.oid);
                    }
                },
                .commit => {
                    var commit = try object.Commit.parse(odb.backendData().gpa, odb.backendData().kind, found.bytes);
                    defer commit.deinit();
                    try pending.append(odb.backendData().gpa, commit.tree);
                    try pending.appendSlice(odb.backendData().gpa, commit.parents);
                },
                .tag => {
                    var tag = try object.Tag.parse(odb.backendData().gpa, odb.backendData().kind, found.bytes);
                    defer tag.deinit();
                    try pending.append(odb.backendData().gpa, tag.target);
                },
            }
        }
        const source = odb.writableSource();
        var fanouts: [256]bool = @splat(false);
        var packs: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer packs.deinit(odb.backendData().gpa);
        var it = seen.keyIterator();
        while (it.next()) |oid| {
            if (try source.findPack(oid.*, &odb.stats)) |hit| {
                const slot = try packs.getOrPut(odb.backendData().gpa, hit.at);
                if (slot.found_existing) continue;
                const named = &source.packs.items[hit.at];
                var path_buf: [128]u8 = undefined;
                const pack_path = std.fmt.bufPrint(&path_buf, "{s}.pack", .{named.name}) catch unreachable;
                try barrier.syncPath(io, source.pack_dir.?, pack_path);
                const idx_path = std.fmt.bufPrint(&path_buf, "{s}.idx", .{named.name}) catch unreachable;
                try barrier.syncPath(io, source.pack_dir.?, idx_path);
            } else {
                var path_buf: [hash.max_hex_len + 2]u8 = undefined;
                const path = odb.loosePath(oid.*, &path_buf);
                try barrier.syncPath(io, source.dir, path);
                fanouts[oid.raw()[0]] = true;
            }
        }
        for (fanouts, 0..) |used, byte| if (used) {
            var path: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&path, "{x:0>2}", .{byte}) catch unreachable;
            try barrier.syncDirectory(io, source.dir, &path);
        };
        if (packs.count() != 0) try barrier.syncDirectory(io, source.dir, "pack");
        try barrier.syncDirectory(io, source.dir, ".");
    }

    /// Put one durability barrier at the end of a batch of object writes.
    ///
    /// Under `Options.sync = .batch` this is what makes every object written
    /// since the last barrier durable, for the cost of one sync rather than
    /// one per object. Under the other two policies it is a no-op that costs
    /// a file creation, so a caller may always call it.
    pub fn syncBatch(odb: *Odb, io: Io) Error!void {
        if (odb.backendData().options.sync != .batch) return;
        const source = odb.writableSource();
        try fs.syncBarrier(io, source.dir);
    }

    /// Write a pack holding exactly these objects, into `pack_dir`.
    ///
    /// The objects are ordered the way git's packer orders them -- type,
    /// then the tail of the path hint, then size descending -- and each is
    /// tried against a sliding window of the ones already written. What is
    /// held at once is the window, which `PackOptions.window_bytes` bounds,
    /// and, with `PackOptions.threads` one, the loose-body cache bounded by
    /// `PackOptions.loose_cache_bytes` and one object being written, or,
    /// with more, the batches `PackOptions.batch_bytes` bounds.
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
        const gpa = odb.backendData().gpa;
        // No more tasks than objects: a task with nothing to take still
        // costs the Io one, and its deflate state.
        const workers = @min(taskCount(options.threads), @max(entries.len, 1));

        // Every object's type and length, which is what the order is by. A
        // header is all this needs, and for a packed object that is no
        // inflation at all.
        var ordered = try gpa.alloc(Ordered, entries.len);
        var ordered_filled: usize = 0;
        defer {
            for (ordered[0..ordered_filled]) |item| if (item.cached) |bytes| gpa.free(bytes);
            gpa.free(ordered);
        }
        if (workers > 1) {
            for (ordered, entries) |*item, entry| item.* = .{
                .oid = entry.oid,
                .type = if (entry.header) |h| h.type else undefined,
                .size = if (entry.header) |h| h.size else undefined,
                .name_hash = nameHash(entry.hint),
                .cached = null,
                .known = entry.header != null,
                .loose = entry.header != null and !entry.in_pack,
            };
            ordered_filled = entries.len;
            try odb.readHeadersConcurrently(io, workers, ordered);
        } else {
            var cached_bytes: usize = 0;
            for (entries, 0..) |entry, i| {
                if (entry.header) |header| {
                    // Known already; the body is looked for loose first,
                    // unless the header came from a pack.
                    ordered[i] = .{
                        .oid = entry.oid,
                        .type = header.type,
                        .size = header.size,
                        .name_hash = nameHash(entry.hint),
                        .cached = null,
                        .loose = !entry.in_pack,
                    };
                    ordered_filled += 1;
                    continue;
                }
                const available = options.loose_cache_bytes -| cached_bytes;
                const found = try odb.readHeaderForPack(io, entry.oid, available);
                if (found.bytes) |bytes| cached_bytes += bytes.len;
                ordered[i] = .{
                    .oid = entry.oid,
                    .type = found.header.type,
                    .size = found.header.size,
                    .name_hash = nameHash(entry.hint),
                    .cached = found.bytes,
                    .loose = found.loose,
                };
                ordered_filled += 1;
            }
        }
        std.mem.sort(Ordered, ordered, {}, beforeInPackOrder);

        const write_options: pack.WriteOptions = .{
            .sync = options.sync,
            .compression = options.compression,
            .reverse_index = options.reverse_index,
        };
        var writer = switch (target) {
            .dir => |pack_dir| try pack.Writer.init(gpa, io, pack_dir, odb.backendData().kind, @intCast(entries.len), write_options),
            .stream => |out| try pack.Writer.initStream(gpa, odb.backendData().kind, out, @intCast(entries.len), write_options),
        };
        defer writer.deinit(io);

        var build: Build = .{
            .odb = odb,
            .gpa = gpa,
            .options = options,
            .ordered = ordered,
            .offsets = try gpa.alloc(u64, ordered.len),
            .writer = writer,
        };
        defer build.deinit();
        if (workers > 1) {
            try build.writeConcurrently(io, workers);
        } else {
            try build.writeSerially(io);
        }
        return try writer.finish(io);
    }

    /// The headers of `ordered`'s objects, on `workers` tasks: the loose
    /// ones read concurrently, the rest — packed, or fetched from a
    /// promisor, which may re-scan the pack directories — on this task once
    /// the others are done.
    fn readHeadersConcurrently(odb: *Odb, io: Io, workers: usize, ordered: []Ordered) Error!void {
        const gpa = odb.backendData().gpa;
        const failures = try gpa.alloc(?Error, ordered.len);
        defer gpa.free(failures);
        const found = try gpa.alloc(bool, ordered.len);
        defer gpa.free(found);
        @memset(found, false);
        const Context = struct {
            odb: *const Odb,
            ordered: []Ordered,
            found: []bool,
            fn work(c: @This(), task_io: Io, _: usize, i: usize) Error!void {
                const item = &c.ordered[i];
                if (item.known) {
                    c.found[i] = true;
                    return;
                }
                const loose = (try c.odb.readLooseFor(task_io, item.oid, .header)) orelse return;
                item.type = loose.header.type;
                item.size = loose.header.size;
                item.loose = true;
                c.found[i] = true;
            }
        };
        try runTasks(io, readTaskCount(workers), failures, Context{ .odb = odb, .ordered = ordered, .found = found }, Context.work);
        for (ordered, found) |*item, loose| {
            if (loose) continue;
            const header = try odb.readHeaderForPack(io, item.oid, 0);
            item.type = header.header.type;
            item.size = header.header.size;
            item.loose = header.loose;
        }
    }

    /// The body of an object to pack, from where its header was found: the
    /// loose file when it was loose, so that an object stored twice is
    /// always packed from the same copy, and `read` otherwise.
    fn readForPack(odb: *Odb, io: Io, item: *const Ordered) Error!Read {
        if (item.loose) {
            if (try odb.readLoose(io, item.oid)) |found| return found;
        }
        return odb.read(io, item.oid);
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
        /// How many tasks `collectLoose` and `collectAll` read the objects'
        /// headers and the loose trees with, through the caller's `std.Io`,
        /// as `PackOptions.threads` says. The tasks allocate nothing: the
        /// trees go into buffers sized from their headers, eight megabytes
        /// of them at a time.
        threads: u16 = 0,
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
        var collected: Collected = .{ .arena = .init(odb.backendData().gpa), .entries = &.{} };
        errdefer collected.arena.deinit();
        const arena = collected.arena.allocator();

        var skip: Oid.Set = .empty;
        defer skip.deinit(odb.backendData().gpa);
        for (options.exclude) |oid| try skip.put(odb.backendData().gpa, oid, {});
        for (options.exclude_packs) |base| {
            const p = odb.findPackByName(base) orelse continue;
            var it = p.index.iterate();
            while (try it.next()) |found| try skip.put(odb.backendData().gpa, found.oid, {});
        }

        var seen: Oid.Set = .empty;
        defer seen.deinit(odb.backendData().gpa);
        var entries: std.ArrayList(PackEntry) = .empty;
        defer entries.deinit(odb.backendData().gpa);

        // Commits and tags first, so that every tree is reached through the
        // commit that names it and a path is known by the time a blob is.
        var commits: std.ArrayList(Oid) = .empty;
        defer commits.deinit(odb.backendData().gpa);
        var trees: std.ArrayList(struct { oid: Oid, path: []const u8 }) = .empty;
        defer trees.deinit(odb.backendData().gpa);

        for (tips) |tip| try commits.append(odb.backendData().gpa, tip);
        var at: usize = 0;
        while (at < commits.items.len) : (at += 1) {
            const oid = commits.items[at];
            if (seen.contains(oid)) continue;
            const found = odb.read(io, oid) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => |e| return e,
            };
            defer odb.backendData().gpa.free(found.bytes);
            try seen.put(odb.backendData().gpa, oid, {});
            switch (found.type) {
                .commit => {
                    var commit = try object.Commit.parse(odb.backendData().gpa, odb.backendData().kind, found.bytes);
                    defer commit.deinit();
                    try trees.append(odb.backendData().gpa, .{ .oid = commit.tree, .path = "" });
                    for (commit.parents) |parent| try commits.append(odb.backendData().gpa, parent);
                    if (!skip.contains(oid)) try entries.append(odb.backendData().gpa, .{ .oid = oid });
                },
                .tag => {
                    var tag = try object.Tag.parse(odb.backendData().gpa, odb.backendData().kind, found.bytes);
                    defer tag.deinit();
                    try commits.append(odb.backendData().gpa, tag.target);
                    if (!skip.contains(oid)) try entries.append(odb.backendData().gpa, .{ .oid = oid });
                },
                .tree => try trees.append(odb.backendData().gpa, .{ .oid = oid, .path = "" }),
                .blob => if (!skip.contains(oid)) try entries.append(odb.backendData().gpa, .{ .oid = oid }),
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
            defer odb.backendData().gpa.free(found.bytes);
            if (found.type != .tree) continue;
            try seen.put(odb.backendData().gpa, node.oid, {});
            if (!skip.contains(node.oid)) {
                try entries.append(odb.backendData().gpa, .{ .oid = node.oid, .hint = node.path });
            }

            var it = object.Tree.parse(odb.backendData().kind, found.bytes).iterate();
            while (try it.next()) |entry| {
                const path = if (node.path.len == 0)
                    try arena.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ node.path, entry.name });
                switch (entry.mode) {
                    .tree => try trees.append(odb.backendData().gpa, .{ .oid = entry.oid, .path = path }),
                    // A gitlink names a commit in another repository, which
                    // this one does not hold and must not be asked for.
                    .gitlink => {},
                    else => {
                        if (seen.contains(entry.oid)) continue;
                        try seen.put(odb.backendData().gpa, entry.oid, {});
                        if (!skip.contains(entry.oid)) {
                            try entries.append(odb.backendData().gpa, .{ .oid = entry.oid, .hint = path });
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
        var collected: Collected = .{ .arena = .init(odb.backendData().gpa), .entries = &.{} };
        errdefer collected.arena.deinit();
        const arena = collected.arena.allocator();

        var skip: Oid.Set = .empty;
        defer skip.deinit(odb.backendData().gpa);
        for (options.exclude) |oid| try skip.put(odb.backendData().gpa, oid, {});
        for (options.exclude_packs) |base| {
            const p = odb.findPackByName(base) orelse continue;
            var it = p.index.iterate();
            while (try it.next()) |found| try skip.put(odb.backendData().gpa, found.oid, {});
        }

        var entries: std.ArrayList(PackEntry) = .empty;
        defer entries.deinit(odb.backendData().gpa);
        const source = odb.writableSource();
        var top = source.dir.iterate();
        while (try top.next(io)) |entry| {
            if (entry.kind != .directory or entry.name.len != 2) continue;
            if (hexPair(entry.name) == null) continue;
            const sub = (try opening.openDirectory(io, source.dir, entry.name)) orelse continue;
            defer sub.close(io);
            var it = sub.iterate();
            while (try it.next(io)) |file| {
                if (file.name.len != odb.backendData().kind.hexLen() - 2) continue;
                var full: [hash.max_hex_len]u8 = undefined;
                @memcpy(full[0..2], entry.name);
                @memcpy(full[2..][0..file.name.len], file.name);
                const oid = Oid.parse(odb.backendData().kind, full[0 .. 2 + file.name.len]) catch continue;
                if (skip.contains(oid)) continue;
                try entries.append(odb.backendData().gpa, .{ .oid = oid });
            }
        }
        if (packed_too) {
            var seen: Oid.Set = .empty;
            defer seen.deinit(odb.backendData().gpa);
            for (entries.items) |e| try seen.put(odb.backendData().gpa, e.oid, {});
            for (source.packs.items) |*named| {
                const p = &named.pack;
                var it = p.index.iterate();
                while (try it.next()) |found| {
                    if (skip.contains(found.oid) or seen.contains(found.oid)) continue;
                    try seen.put(odb.backendData().gpa, found.oid, {});
                    try entries.append(odb.backendData().gpa, .{ .oid = found.oid, .in_pack = true });
                }
            }
        }
        try odb.assignHints(io, arena, entries.items, options.threads);
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
    fn assignHints(odb: *Odb, io: Io, arena: Allocator, entries: []PackEntry, threads: u16) Error!void {
        const gpa = odb.backendData().gpa;
        // Every header, which also goes with the entry to `writePack`: the
        // loose ones on as many tasks as asked, the rest here after them. A
        // header that does not read leaves its entry without a hint, as
        // before; only a refusal to read stops the collection.
        const workers = taskCount(threads);
        if (workers > 1) {
            const failures = try gpa.alloc(?Error, entries.len);
            defer gpa.free(failures);
            const Context = struct {
                odb: *const Odb,
                entries: []PackEntry,
                fn work(c: @This(), task_io: Io, _: usize, i: usize) Error!void {
                    if (c.entries[i].in_pack) return;
                    const found = c.odb.readLooseFor(task_io, c.entries[i].oid, .header) catch |err| {
                        if (opening.readRefusal(err)) return err;
                        return;
                    } orelse return;
                    c.entries[i].header = found.header;
                }
            };
            try runTasks(io, readTaskCount(workers), failures, Context{ .odb = odb, .entries = entries }, Context.work);
        }
        for (entries) |*entry| {
            if (entry.header != null) continue;
            // Found in a pack, so read there, not looked for loose first.
            if (entry.in_pack) if (odb.packedHeader(io, entry.oid) catch |err| {
                if (opening.readRefusal(err)) return err;
                continue;
            }) |header| {
                entry.header = header;
                continue;
            };
            entry.header = odb.readHeader(io, entry.oid) catch |err| {
                if (opening.readRefusal(err)) return err;
                continue;
            };
            entry.in_pack = false;
        }

        // The trees, which name everything else. The loose ones are read by
        // the tasks, a batch at a time, into buffers sized here from their
        // headers, and the rest here; every one is parsed here, in order, so
        // the first tree to name an object gives it its hint whatever the
        // tasks' timing.
        var hints: std.AutoHashMapUnmanaged(Oid, []const u8) = .empty;
        defer hints.deinit(gpa);
        const TreeRead = struct {
            oid: Oid,
            bytes: ?[]u8 = null,
            filled: bool = false,
        };
        var trees: std.ArrayList(TreeRead) = .empty;
        defer trees.deinit(gpa);
        defer for (trees.items) |t| if (t.bytes) |bytes| gpa.free(bytes);
        var failures: std.ArrayList(?Error) = .empty;
        defer failures.deinit(gpa);
        var start: usize = 0;
        while (start < entries.len) {
            for (trees.items) |*t| if (t.bytes) |bytes| {
                gpa.free(bytes);
                t.bytes = null;
            };
            trees.clearRetainingCapacity();
            var held: usize = 0;
            var end = start;
            while (end < entries.len and held < hint_batch_bytes) : (end += 1) {
                const head = entries[end].header orelse continue;
                if (head.type != .tree) continue;
                try trees.append(gpa, .{ .oid = entries[end].oid });
                if (workers == 1 or entries[end].in_pack or head.size > odb.backendData().options.max_object_bytes) continue;
                const len = std.math.cast(usize, head.size) orelse continue;
                trees.items[trees.items.len - 1].bytes = try gpa.alloc(u8, len);
                held += len;
            }
            start = end;
            if (workers > 1) {
                try failures.resize(gpa, trees.items.len);
                const Trees = struct {
                    odb: *const Odb,
                    trees: []TreeRead,
                    fn work(c: @This(), task_io: Io, _: usize, i: usize) Error!void {
                        const t = &c.trees[i];
                        const into = t.bytes orelse return;
                        const found = c.odb.readLooseFor(task_io, t.oid, .{ .into = into }) catch |err| {
                            if (opening.readRefusal(err)) return err;
                            return;
                        } orelse return;
                        t.filled = found.header.type == .tree;
                    }
                };
                try runTasks(io, readTaskCount(workers), failures.items, Trees{ .odb = odb, .trees = trees.items }, Trees.work);
            }
            for (trees.items) |*t| {
                const tree_bytes = if (t.filled) t.bytes.? else blk: {
                    if (t.bytes) |unused| gpa.free(unused);
                    t.bytes = null;
                    const found = odb.read(io, t.oid) catch |err| {
                        if (opening.readRefusal(err)) return err;
                        continue;
                    };
                    if (found.type != .tree) {
                        gpa.free(found.bytes);
                        continue;
                    }
                    t.bytes = found.bytes;
                    break :blk found.bytes;
                };
                var it = object.Tree.parse(odb.backendData().kind, tree_bytes).iterate();
                while (it.next() catch null) |child| {
                    if (hints.contains(child.oid)) continue;
                    try hints.put(gpa, child.oid, try arena.dupe(u8, child.name));
                }
            }
        }
        for (entries) |*entry| {
            if (hints.get(entry.oid)) |name| entry.hint = name;
        }
    }

    fn findPackByName(odb: *Odb, base: []const u8) ?*pack.Pack {
        for (odb.backendData().sources.items) |*source| {
            for (source.packs.items) |*named| {
                if (std.mem.eql(u8, named.name, base)) return &named.pack;
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
        var collected = try odb.collectLoose(io, .{ .threads = options.pack.threads });
        defer collected.deinit();
        return odb.packCollected(io, collected.entries, options, false);
    }

    /// Put every object the writable directory holds, loose and packed, into
    /// one pack.
    ///
    /// The same order as `packLoose`, and the same rule: nothing is taken
    /// away until the new pack is written, durable and readable here.
    pub fn repack(odb: *Odb, io: Io, options: RepackOptions) Error!RepackReport {
        var collected = try odb.collectAll(io, .{ .threads = options.pack.threads });
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
            for (old_packs.items) |name| odb.backendData().gpa.free(name);
            old_packs.deinit(odb.backendData().gpa);
        }
        if (remove_packs) {
            for (source.packs.items) |named| {
                const name = try odb.backendData().gpa.dupe(u8, named.name);
                errdefer odb.backendData().gpa.free(name);
                try old_packs.append(odb.backendData().gpa, name);
            }
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
        const source = &odb.backendData().sources.items[source_index];
        for (source.packs.items) |*named| named.deinit(odb.backendData().gpa, io);
        source.packs.clearRetainingCapacity();
        if (source.midx) |*m| {
            m.deinit();
            source.midx = null;
        }
        source.midx_packs.clearRetainingCapacity();
        // The delta base cache is keyed on which pack an offset was in, and
        // the packs have just been renumbered.
        odb.backendData().cache.clear();
        odb.backendData().generation +%= 1;
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
        const writer = try pack.Writer.initCounting(odb.backendData().gpa, io, dir, odb.backendData().kind, .{
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
        const named = hash.Hasher.nameObject(odb.backendData().kind, odb.hashOptions(), t.name(), bytes);
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
        for (odb.backendData().sources.items) |*s| n += s.packs.items.len;
        return n;
    }

    /// How many of this database's object directories have a multi-pack
    /// index that parsed.
    pub fn multiPackIndexCount(odb: *const Odb) usize {
        var n: usize = 0;
        for (odb.backendData().sources.items) |*s| n += @intFromBool(s.midx != null);
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
    /// The object's type and size, when the caller has already read them,
    /// as `collectLoose` and `collectAll` have; `writePack` then does not
    /// read them again. The pack is written from the object itself, so a
    /// wrong header costs a second read and the order, never the pack.
    header: ?object.Header = null,
    /// Whether `header` was read from a pack, and no loose copy was found,
    /// as `collectAll` says of what it found only in packs: `writePack`
    /// then reads the object from the packs without looking for a loose
    /// copy first.
    in_pack: bool = false,
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
    /// How many tasks build the pack, through the caller's `std.Io`
    /// (`Io.Group.async`): zero for one per processor the machine has, one
    /// for none at all — the writer then runs on the calling task alone,
    /// with the loose-body cache below. Above one, the tasks read loose
    /// objects, inflate the whole objects of packs and deflate entries ahead
    /// of the writer, while the delta search, the deltas packs hold and the
    /// writing stay on the calling task in pack order. An Io that cannot run
    /// a task in parallel runs it inline. Every value writes the same bytes,
    /// and the tasks never allocate: the calling task sizes and allocates
    /// everything they fill, and, when objects come from packs, a decoder
    /// and a 64 KiB read buffer for each task. A `-fsingle-threaded` build
    /// always uses one.
    threads: u16 = 0,
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
    /// the write pass, when `threads` is one. A retained object is opened
    /// and inflated once instead of twice. Objects that do not fit the
    /// remaining budget take the old two-read path; there is no eviction.
    /// Zero disables the cache.
    loose_cache_bytes: usize = 64 << 20,
    /// How many bytes the tasks may hold ahead of the writer, when `threads`
    /// is not one. Objects go through in batches, three under way at once:
    /// the tasks read one and deflate another while the calling task
    /// searches the one between for deltas. Each object is charged its size
    /// for its body and `pack.Deflater.room(size)` for its deflated entry,
    /// and a batch takes objects while their charges fit a third of this,
    /// and always at least one. An object whose charge alone is larger is
    /// read and deflated straight into the pack, on the calling task, one
    /// such object at a time.
    batch_bytes: usize = 64 << 20,
    /// An object this large or larger is written whole and never enters the
    /// window. git's `core.bigFileThreshold`, and the same default.
    big_file_bytes: u64 = 512 << 20,
    /// How hard the two files are pushed towards the disk before they are
    /// renamed into place.
    sync: fs.Sync = .none,
    /// How hard the entries are compressed.
    compression: pack.Compression = .default,
    /// Write the pack's reverse index too: `pack.WriteOptions.reverse_index`.
    reverse_index: bool = false,
};

/// How many tasks `threads` asks for.
fn taskCount(threads: u16) usize {
    if (builtin.single_threaded) return 1;
    if (threads != 0) return threads;
    return std.Thread.getCpuCount() catch 1;
}

/// The most tasks that read loose objects at once. Each read opens and
/// closes a file, and beyond a few at a time those contend in the kernel on
/// the process's descriptor table. Measured on macOS: opening and reading
/// 35,512 warm loose objects took 203 ms on four tasks, 240 on six, 425 on
/// eight and 1,267 on sixteen, against 541 on one; the whole bench pack,
/// from a fresh copy, took 2.3 s with four reading, 2.0 with six or eight
/// and 3.3 with sixteen. Deflating has no such limit and uses every task.
const read_task_limit = 6;

/// How many bytes of trees `collectLoose` and `collectAll` read ahead of
/// parsing them, when tasks read them.
const hint_batch_bytes = 8 << 20;

fn readTaskCount(workers: usize) usize {
    return @min(workers, read_task_limit);
}

/// Items shared out among tasks of `io`, each calling `work(context, io,
/// worker, item)` for the items it takes. Tasks go through `Io.Group.async`,
/// so an Io that cannot run one in parallel runs it inline, and a cancel
/// reaches every task at its next item. A failed item stops the items after
/// it from starting; `finish` returns the failure of the first item in
/// order, whatever the order the tasks met them in.
///
/// The items from `limited_from` on open files, and only workers below
/// `limited_workers` take them, those first: opening files contends in the
/// kernel (`read_task_limit`). The others are anyone's.
fn TaskSet(comptime Context: type, comptime work: fn (Context, Io, usize, usize) Error!void) type {
    return struct {
        io: Io,
        failures: []?Error,
        context: Context,
        limited_from: usize,
        limited_workers: usize,
        next_open: std.atomic.Value(usize) = .init(0),
        next_limited: std.atomic.Value(usize) = .init(0),
        lowest_failed: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
        /// Whether a task met a cancelation. Meeting one consumes the
        /// request, and a task the Io ran inline may have met the calling
        /// task's, so the others are then canceled explicitly.
        canceled: std.atomic.Value(bool) = .init(false),
        group: Io.Group = .init,

        const Set = @This();

        fn take(set: *Set, worker: usize) ?usize {
            if (worker < set.limited_workers) {
                const i = set.limited_from + set.next_limited.fetchAdd(1, .monotonic);
                if (i < set.failures.len) return i;
            }
            const i = set.next_open.fetchAdd(1, .monotonic);
            if (i < set.limited_from) return i;
            return null;
        }

        fn run(set: *Set, worker: usize) void {
            while (set.take(worker)) |i| {
                if (i > set.lowest_failed.load(.monotonic)) continue;
                const outcome: Error!void = if (set.io.checkCancel()) |_|
                    work(set.context, set.io, worker, i)
                else |err|
                    err;
                outcome catch |err| {
                    if (err == error.Canceled) set.canceled.store(true, .monotonic);
                    set.failures[i] = err;
                    var lowest = set.lowest_failed.load(.monotonic);
                    while (i < lowest) {
                        lowest = set.lowest_failed.cmpxchgWeak(lowest, i, .monotonic, .monotonic) orelse break;
                    }
                };
            }
        }

        /// Start `tasks` tasks, workers `1` to `tasks`, and never more than
        /// there are items; the calling task is free until `finish`.
        fn start(set: *Set, tasks: usize) void {
            @memset(set.failures, null);
            for (0..@min(tasks, set.failures.len)) |t| set.group.async(set.io, run, .{ set, t + 1 });
        }

        /// Take what is left as worker `0`, then wait for the others.
        fn finish(set: *Set) Error!void {
            set.run(0);
            if (set.canceled.load(.monotonic)) {
                set.group.cancel(set.io);
                return error.Canceled;
            }
            try set.group.await(set.io);
            for (set.failures) |failure| if (failure) |err| return err;
        }

        /// Stop the tasks and wait for them: the caller failed meanwhile.
        fn abandon(set: *Set) void {
            set.group.cancel(set.io);
        }
    };
}

/// Share `failures.len` items out among `workers` tasks of `io`, the calling
/// task one of them, and never more tasks than items: a `TaskSet` whose
/// items are anyone's, run to its end.
fn runTasks(
    io: Io,
    workers: usize,
    failures: []?Error,
    context: anytype,
    comptime work: fn (@TypeOf(context), Io, usize, usize) Error!void,
) Error!void {
    var set: TaskSet(@TypeOf(context), work) = .{
        .io = io,
        .failures = failures,
        .context = context,
        .limited_from = failures.len,
        .limited_workers = 0,
    };
    // The calling task takes items too, so one item needs no other task.
    set.start(@min(workers, failures.len) -| 1);
    return set.finish();
}

/// One object held in the delta window.
const WindowSlot = struct {
    /// Where the object is in pack order, which says where it was written.
    pos: usize,
    type: object.Type,
    bytes: []u8,
    depth: u32,
    /// Built on the first candidate search that survives the cheap size and
    /// depth filters, then reused for the rest of this slot's window life.
    encoder: ?delta.Encoder,

    fn getEncoder(slot: *WindowSlot, gpa: Allocator) Allocator.Error!*delta.Encoder {
        if (slot.encoder == null) slot.encoder = try .init(gpa, slot.bytes);
        return &slot.encoder.?;
    }
};

/// A pack being built: the window, the delta choice for each object in pack
/// order, and where each object was written.
const Build = struct {
    odb: *Odb,
    gpa: Allocator,
    options: PackOptions,
    ordered: []Ordered,
    /// Where each object of `ordered` was written, once it was.
    offsets: []u64,
    writer: *pack.Writer,
    window: std.ArrayList(WindowSlot) = .empty,
    window_bytes: usize = 0,
    /// Bodies the window let go of while objects of the batch that may be
    /// written from them still wait; released once the batch is written.
    retired: std.ArrayList([]u8) = .empty,
    keep_retired: bool = false,

    fn deinit(b: *Build) void {
        for (b.window.items) |*slot| {
            if (slot.encoder) |*encoder| encoder.deinit(b.gpa);
            b.gpa.free(slot.bytes);
        }
        b.window.deinit(b.gpa);
        b.releaseRetired();
        b.retired.deinit(b.gpa);
        b.gpa.free(b.offsets);
    }

    fn releaseRetired(b: *Build) void {
        for (b.retired.items) |bytes| b.gpa.free(bytes);
        b.retired.clearRetainingCapacity();
    }

    /// How object `pos` is written, by git's rules against the window: the
    /// delta and its base, or whole.
    const Choice = struct {
        /// The base's position in pack order, for a delta.
        base: ?usize = null,
        /// The delta's bytes, the caller's.
        delta: ?[]u8 = null,
        /// Whether `bytes` went into the window, which now owns them.
        kept: bool = false,
    };

    /// Choose how object `pos`, whose bytes are `bytes`, is written, and
    /// put it in the window when it may be a base. On success the bytes are
    /// the window's when `kept`, and the caller's otherwise; the window
    /// keeps them readable until `releaseRetired` while `keep_retired`.
    fn choose(b: *Build, pos: usize, t: object.Type, bytes: []u8) Error!Choice {
        const options = b.options;
        const deltifiable = options.delta != .none and options.window != 0 and
            bytes.len < options.big_file_bytes;
        var choice: Choice = .{};
        var depth: u32 = 0;
        if (deltifiable) {
            // git's rule for what is worth writing: a delta must be at
            // most half the object it stands in for, and each one after
            // the first must beat the one before it.
            const raw_len = b.odb.backendData().kind.rawLen();
            var limit: usize = bytes.len / 2;
            if (limit > raw_len) limit -= raw_len else limit = 0;
            if (try findDelta(b.gpa, b.window.items, t, bytes, options, limit)) |chosen| {
                const slot = b.window.items[chosen.slot];
                depth = slot.depth + 1;
                choice = .{ .base = slot.pos, .delta = chosen.bytes };
            }
            errdefer if (choice.delta) |d| b.gpa.free(d);
            try b.window.ensureUnusedCapacity(b.gpa, 1);
            if (b.keep_retired) try b.retired.ensureUnusedCapacity(b.gpa, b.window.items.len + 1);
            b.window.appendAssumeCapacity(.{ .pos = pos, .type = t, .bytes = bytes, .depth = depth, .encoder = null });
            choice.kept = true;
            b.window_bytes += bytes.len;
            // The oldest go first, by count and then by weight, so the
            // window is a bound on memory and not only on work.
            while (b.window.items.len > options.window or
                (b.window.items.len > 1 and b.window_bytes > options.window_bytes))
            {
                var oldest = b.window.orderedRemove(0);
                b.window_bytes -= oldest.bytes.len;
                if (oldest.encoder) |*encoder| encoder.deinit(b.gpa);
                if (b.keep_retired) b.retired.appendAssumeCapacity(oldest.bytes) else b.gpa.free(oldest.bytes);
            }
        }
        return choice;
    }

    /// Write object `pos` the way `choice` says, deflating it here.
    fn writeDirect(b: *Build, pos: usize, t: object.Type, bytes: []const u8, choice: Choice) Error!void {
        const item = &b.ordered[pos];
        b.offsets[pos] = if (choice.base) |base| switch (b.options.delta) {
            .offset => try b.writer.addOfsDelta(item.oid, b.offsets[base], choice.delta.?),
            .reference => try b.writer.addRefDelta(item.oid, b.ordered[base].oid, choice.delta.?),
            .none => unreachable,
        } else try b.writer.add(item.oid, t, bytes);
    }

    /// Every object in pack order on this task alone: the serial writer.
    fn writeSerially(b: *Build, io: Io) Error!void {
        for (b.ordered, 0..) |*item, pos| {
            const found = if (item.cached) |bytes| blk: {
                item.cached = null;
                break :blk Odb.Read{ .type = item.type, .bytes = bytes };
            } else try b.odb.readForPack(io, item);
            var owned = true;
            defer if (owned) b.gpa.free(found.bytes);
            const choice = try b.choose(pos, found.type, found.bytes);
            owned = !choice.kept;
            defer if (choice.delta) |d| b.gpa.free(d);
            try b.writeDirect(pos, found.type, found.bytes, choice);
        }
    }

    /// One object of a batch.
    const Pending = struct {
        type: object.Type,
        /// The body, once read; allocated here for a loose object and a
        /// whole packed one, by `read` for the rest.
        bytes: ?[]u8 = null,
        filled: bool = false,
        /// Where a packed whole object is, for a task to inflate it.
        packed_at: ?PackedAt = null,
        choice: Choice = .{},
        /// Room for the deflated entry, and how much of it was used, or
        /// `null` when the entry overflowed or has no room and is deflated
        /// when written.
        room: []u8 = &.{},
        deflated: ?usize = null,

        fn payload(p: *const Pending) []const u8 {
            return p.choice.delta orelse p.bytes.?;
        }
    };

    /// Objects `start..end` of pack order, on their way through the tasks.
    const Batch = struct {
        start: usize = 0,
        end: usize = 0,
        /// One object too large for a batch's share of the budget: read and
        /// deflated on the calling task, straight into the pack.
        alone: bool = false,
        /// Whether the tasks open files for it, which caps how many read.
        opens: bool = false,
        pending: std.ArrayList(Pending) = .empty,
        /// Bodies the window let go of during this batch's search, which
        /// this batch or the one before it may still be written from.
        retired: std.ArrayList([]u8) = .empty,

        fn items(batch: *const Batch) usize {
            return batch.end - batch.start;
        }

        /// Free what the batch holds, keeping its lists' room.
        fn release(batch: *Batch, gpa: Allocator) void {
            for (batch.pending.items) |*p| {
                if (!p.choice.kept) if (p.bytes) |bytes| gpa.free(bytes);
                if (p.choice.delta) |d| gpa.free(d);
                if (p.room.len != 0) gpa.free(p.room);
            }
            batch.pending.clearRetainingCapacity();
            for (batch.retired.items) |bytes| gpa.free(bytes);
            batch.retired.clearRetainingCapacity();
        }

        fn deinit(batch: *Batch, gpa: Allocator) void {
            batch.release(gpa);
            batch.pending.deinit(gpa);
            batch.retired.deinit(gpa);
        }
    };

    /// Every object in pack order, with tasks reading bodies and deflating
    /// entries ahead of this one, batch by batch. While this task searches
    /// one batch for deltas, the tasks deflate the batch before it and read
    /// the batch after it, so three batches are under way at once, each
    /// within a third of `batch_bytes`.
    fn writeConcurrently(b: *Build, io: Io, workers: usize) Error!void {
        const gpa = b.gpa;
        const deflaters = try gpa.alloc(pack.Deflater, workers);
        var made: usize = 0;
        defer {
            for (deflaters[0..made]) |*d| d.deinit(gpa);
            gpa.free(deflaters);
        }
        while (made < workers) : (made += 1) deflaters[made] = try .init(gpa);
        // A decoder and a read buffer for each task, when some objects come
        // from packs.
        var readers: []pack.Pack.EntryReader = &.{};
        defer gpa.free(readers);
        for (b.ordered) |item| {
            if (item.loose) continue;
            readers = try gpa.alloc(pack.Pack.EntryReader, workers);
            for (readers) |*r| r.* = .{};
            break;
        }
        var failures: std.ArrayList(?Error) = .empty;
        defer failures.deinit(gpa);
        var slots: [3]Batch = @splat(.{});
        defer for (&slots) |*slot| slot.deinit(gpa);
        b.keep_retired = true;
        const stage: Stage = .{ .workers = workers, .deflaters = deflaters, .readers = readers, .failures = &failures };

        // The first batch read, then each searched while the one before is
        // deflated and the one after read, then the last deflated.
        var turn: usize = 0;
        var prev: ?*Batch = null;
        var cur: ?*Batch = &slots[0];
        b.plan(cur.?, 0);
        try b.prepareReads(io, cur.?);
        try b.overlap(io, stage, null, cur, null);
        try b.finishReads(io, cur.?);
        while (cur) |searching| {
            turn += 1;
            const next: ?*Batch = if (searching.end < b.ordered.len) &slots[turn % 3] else null;
            if (next) |n| {
                b.plan(n, searching.end);
                try b.prepareReads(io, n);
            }
            if (prev) |p| if (p.alone) {
                // Nothing for the tasks to deflate: written now, so that
                // one object too large for a batch is held at a time.
                try b.writeBatch(p);
                p.release(gpa);
                prev = null;
            };
            if (searching.alone) try b.readAlone(io, searching);
            if (prev) |p| try b.prepareDeflate(p);
            try b.overlap(io, stage, prev, next, searching);
            if (prev) |p| {
                try b.writeBatch(p);
                p.release(gpa);
            }
            if (next) |n| try b.finishReads(io, n);
            prev = searching;
            cur = next;
        }
        if (prev) |p| {
            try b.prepareDeflate(p);
            try b.overlap(io, stage, p, null, null);
            try b.writeBatch(p);
            p.release(gpa);
        }
    }

    /// What every stage of `writeConcurrently` shares.
    const Stage = struct {
        workers: usize,
        deflaters: []pack.Deflater,
        readers: []pack.Pack.EntryReader,
        failures: *std.ArrayList(?Error),
    };

    /// The batch from `start`: objects while their charges fit a third of
    /// the budget, and always one. Each is charged its body, the slack a
    /// packed one is inflated with, and its deflated entry's room.
    fn plan(b: *Build, batch: *Batch, start: usize) void {
        const share = b.options.batch_bytes / 3;
        var end = start;
        var charged: usize = 0;
        while (end < b.ordered.len) {
            const size = std.math.cast(usize, b.ordered[end].size) orelse std.math.maxInt(usize);
            const slack: usize = if (b.ordered[end].loose) 0 else pack.Pack.inflate_slack;
            const charge = size +| slack +| pack.Deflater.room(size);
            if (end > start and charged +| charge > share) break;
            charged +|= charge;
            end += 1;
        }
        batch.* = .{
            .start = start,
            .end = end,
            .alone = end == start + 1 and charged > share,
            .pending = batch.pending,
            .retired = batch.retired,
        };
    }

    /// Size the bodies the tasks read: the loose ones, and the whole
    /// packed ones, which are looked for here, since looking in the packs
    /// changes them.
    fn prepareReads(b: *Build, io: Io, batch: *Batch) Error!void {
        const gpa = b.gpa;
        const items = b.ordered[batch.start..batch.end];
        try batch.pending.ensureTotalCapacity(gpa, items.len);
        for (items) |item| batch.pending.appendAssumeCapacity(.{ .type = item.type });
        if (batch.alone) return;
        for (items, batch.pending.items) |item, *p| {
            if (item.loose) {
                p.bytes = try gpa.alloc(u8, @intCast(item.size));
                batch.opens = true;
                continue;
            }
            const at = (try b.odb.locateWhole(io, item.oid)) orelse continue;
            // A size other than the header's is read again, whole, after.
            if (at.size != item.size) continue;
            p.bytes = try gpa.alloc(u8, @as(usize, @intCast(item.size)) + pack.Pack.inflate_slack);
            p.packed_at = at;
        }
    }

    /// The bodies the tasks did not read, read here: deltas and what else
    /// is not loose, and a loose object that went away since its header was
    /// read. An object too large to batch is read just before it is
    /// searched, by `readAlone`.
    fn finishReads(b: *Build, io: Io, batch: *Batch) Error!void {
        const gpa = b.gpa;
        if (batch.alone) return;
        for (b.ordered[batch.start..batch.end], batch.pending.items) |*item, *p| {
            if (p.filled) {
                if (p.packed_at != null) p.bytes = try gpa.realloc(p.bytes.?, @intCast(item.size));
                continue;
            }
            if (p.bytes) |unused| gpa.free(unused);
            p.bytes = null;
            const found = try b.odb.readForPack(io, item);
            p.bytes = found.bytes;
            p.type = found.type;
        }
    }

    /// The body of an object too large to batch, read here while no task
    /// runs, since a read may re-scan the pack directories.
    fn readAlone(b: *Build, io: Io, batch: *Batch) Error!void {
        const p = &batch.pending.items[0];
        const found = try b.odb.readForPack(io, &b.ordered[batch.start]);
        p.bytes = found.bytes;
        p.type = found.type;
    }

    /// The delta search, in pack order, exactly as the serial writer makes
    /// it. The bodies the window lets go of meanwhile stay the batch's.
    fn search(b: *Build, batch: *Batch) Error!void {
        for (batch.pending.items, batch.start..) |*p, pos| p.choice = try b.choose(pos, p.type, p.bytes.?);
        std.mem.swap(std.ArrayList([]u8), &batch.retired, &b.retired);
    }

    /// Room for each entry the tasks deflate.
    fn prepareDeflate(b: *Build, batch: *Batch) Error!void {
        if (batch.alone) return;
        for (batch.pending.items) |*p| p.room = try b.gpa.alloc(u8, pack.Deflater.room(p.payload().len));
    }

    /// The tasks deflate `deflating` and read `reading`, either may be
    /// absent, while this task searches `searching`, then takes what is
    /// left of their work.
    fn overlap(b: *Build, io: Io, stage: Stage, deflating: ?*Batch, reading: ?*Batch, searching: ?*Batch) Error!void {
        const deflates: []Pending = if (deflating) |d| (if (d.alone) &.{} else d.pending.items) else &.{};
        const reads: []Pending = if (reading) |r| (if (r.alone) &.{} else r.pending.items) else &.{};
        try stage.failures.resize(b.gpa, deflates.len + reads.len);
        const Work = struct {
            odb: *const Odb,
            deflates: []Pending,
            reads: []Pending,
            read_items: []const Ordered,
            deflaters: []pack.Deflater,
            readers: []pack.Pack.EntryReader,
            compression: pack.Compression,

            fn work(c: @This(), task_io: Io, worker: usize, i: usize) Error!void {
                if (i < c.deflates.len) return c.deflate(worker, &c.deflates[i]);
                const at = i - c.deflates.len;
                return c.read(task_io, worker, c.read_items[at].oid, &c.reads[at]);
            }

            fn deflate(c: @This(), worker: usize, p: *Pending) Error!void {
                var out: Io.Writer = .fixed(p.room);
                c.deflaters[worker].deflate(&out, p.payload(), c.compression) catch |err| switch (err) {
                    // No room: deflated again when it is written.
                    error.WriteFailed => return,
                };
                p.deflated = out.end;
            }

            fn read(c: @This(), task_io: Io, worker: usize, oid: Oid, p: *Pending) Error!void {
                const into = p.bytes orelse return;
                if (p.packed_at) |at| {
                    at.pack.inflateWith(task_io, &c.readers[worker], at.at, at.size, into) catch |err| switch (err) {
                        // Read again on the calling task, which says why.
                        error.CorruptPackEntry => return,
                        else => |e| return e,
                    };
                    p.type = at.type;
                    p.filled = true;
                    return;
                }
                const found = c.odb.readLooseFor(task_io, oid, .{ .into = into }) catch |err| switch (err) {
                    // Not the size its header said: read it again, whole,
                    // on the calling task.
                    error.CorruptLooseObject => return,
                    else => |e| return e,
                } orelse return;
                p.type = found.header.type;
                p.filled = true;
            }
        };
        const opens = if (reading) |r| r.opens else false;
        var set: TaskSet(Work, Work.work) = .{
            .io = io,
            .failures = stage.failures.items,
            .context = .{
                .odb = b.odb,
                .deflates = deflates,
                .reads = reads,
                .read_items = if (reading) |r| b.ordered[r.start..r.end] else &.{},
                .deflaters = stage.deflaters,
                .readers = stage.readers,
                .compression = b.options.compression,
            },
            // The reads come after the deflating in item order; opening
            // files is for a few workers only.
            .limited_from = deflates.len,
            .limited_workers = if (opens) readTaskCount(stage.workers) else stage.workers,
        };
        // The workers with something to take, and of them every one but
        // this task, which searches meanwhile and joins them after, or
        // joins them at once with nothing to search.
        const busy = if (deflates.len != 0) stage.workers else @min(stage.workers, set.limited_workers);
        const items = deflates.len + reads.len;
        set.start(if (searching != null) @min(busy - 1, items) else @min(busy, items) -| 1);
        if (searching) |s| b.search(s) catch |err| {
            set.abandon();
            return err;
        };
        try set.finish();
    }

    /// A batch's entries, in pack order.
    fn writeBatch(b: *Build, batch: *Batch) Error!void {
        for (batch.pending.items, batch.start..) |*p, pos| {
            const deflated_len = p.deflated orelse {
                try b.writeDirect(pos, p.type, p.bytes.?, p.choice);
                continue;
            };
            const item = &b.ordered[pos];
            const payload: pack.Writer.Payload = if (p.choice.base) |base| switch (b.options.delta) {
                .offset => .{ .ofs_delta = b.offsets[base] },
                .reference => .{ .ref_delta = b.ordered[base].oid },
                .none => unreachable,
            } else .{ .object = p.type };
            b.offsets[pos] = try b.writer.addDeflated(item.oid, payload, p.payload().len, p.room[0..deflated_len]);
        }
    }
};

const ChosenDelta = struct { slot: usize, bytes: []u8 };

/// git's delta search for one object against the window, newest first.
fn findDelta(
    gpa: Allocator,
    window: []WindowSlot,
    object_type: object.Type,
    target: []const u8,
    options: PackOptions,
    initial_limit: usize,
) Error!?ChosenDelta {
    var chosen: ?ChosenDelta = null;
    errdefer if (chosen) |c| gpa.free(c.bytes);
    var at = window.len;
    while (at != 0) {
        at -= 1;
        const slot = &window[at];
        // Types are contiguous in pack order, so the first mismatch also
        // means every older window entry is the wrong type.
        if (slot.type != object_type) break;
        const limit = deltaCandidateLimit(initial_limit, options.depth, slot.depth, chosen, window);
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

/// A whole object's entry in a pack, which a task may inflate.
const PackedAt = struct {
    pack: *const pack.Pack,
    type: object.Type,
    /// Where the entry's zlib stream begins.
    at: u64,
    size: u64,
};

/// What a sort puts the objects in order by.
const Ordered = struct {
    oid: Oid,
    type: object.Type,
    size: u64,
    name_hash: u32,
    cached: ?[]u8,
    /// Whether the header came from a loose object, which is where the body
    /// is read from too, or was given and the body is looked for loose
    /// first.
    loose: bool = false,
    /// Whether the header was given with the entry.
    known: bool = false,
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
    defer objects.close(io);

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

test "an object an alternate holds is borrowed, and owned once asked for" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "theirs/pack");
    try tmp.dir.createDirPath(io, "ours/pack");
    try tmp.dir.createDirPath(io, "ours/info");
    try tmp.dir.writeFile(io, .{ .sub_path = "ours/info/alternates", .data = "../theirs\n" });

    const oid = blk: {
        const theirs_dir = try tmp.dir.openDir(io, "theirs", .{ .iterate = true });
        defer theirs_dir.close(io);
        var theirs = try Odb.openAt(gpa, io, theirs_dir, .sha1, .{});
        defer theirs.deinit(io);
        break :blk try theirs.write(io, .blob, "borrowed\n");
    };
    {
        const ours_dir = try tmp.dir.openDir(io, "ours", .{ .iterate = true });
        defer ours_dir.close(io);
        var ours = try Odb.openAt(gpa, io, ours_dir, .sha1, .{});
        defer ours.deinit(io);
        // read through the alternate, written nowhere here
        try std.testing.expect(try ours.exists(io, oid));
        try std.testing.expect(!try ours.existsOwn(io, oid));
        try std.testing.expect((try ours.write(io, .blob, "borrowed\n")).eql(oid));
        try std.testing.expect(!try ours.existsOwn(io, oid));
        // owned: here whatever becomes of the alternate
        try ours.own(io, oid);
        try std.testing.expect(try ours.existsOwn(io, oid));
        try ours.own(io, oid);
    }
    try tmp.dir.deleteTree(io, "theirs");
    try tmp.dir.createDirPath(io, "theirs/pack");
    const ours_dir = try tmp.dir.openDir(io, "ours", .{ .iterate = true });
    defer ours_dir.close(io);
    var ours = try Odb.openAt(gpa, io, ours_dir, .sha1, .{});
    defer ours.deinit(io);
    const found = try ours.read(io, oid);
    defer gpa.free(found.bytes);
    try std.testing.expectEqualStrings("borrowed\n", found.bytes);
}

test "alternates API reads a relative chain, preserves comments, and updates open lookups" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "a/pack", "b/pack", "c/pack", "a/info" }) |dir| try tmp.dir.createDirPath(io, dir);
    const oid = blk: {
        const c_dir = try tmp.dir.openDir(io, "c", .{ .iterate = true });
        defer c_dir.close(io);
        var c = try Odb.openAt(gpa, io, c_dir, .sha1, .{});
        defer c.deinit(io);
        break :blk try c.write(io, .blob, "through two alternates\n");
    };
    const b_dir = try tmp.dir.openDir(io, "b", .{ .iterate = true });
    defer b_dir.close(io);
    var b = try Odb.openAt(gpa, io, b_dir, .sha1, .{});
    defer b.deinit(io);
    try b.addAlternate(io, "../c");
    try tmp.dir.writeFile(io, .{ .sub_path = "b/info/alternates", .data = "\"../c\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/info/alternates", .data = "# keep this comment\n" });
    const a_dir = try tmp.dir.openDir(io, "a", .{ .iterate = true });
    defer a_dir.close(io);
    var a = try Odb.openAt(gpa, io, a_dir, .sha1, .{});
    defer a.deinit(io);
    try std.testing.expect(!try a.exists(io, oid));
    try a.addAlternate(io, "../b");
    try a.addAlternate(io, "../b");
    var listed = try a.listAlternates(gpa, io);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.paths.len);
    try std.testing.expectEqualStrings("../b", listed.paths[0]);
    try std.testing.expect(std.mem.startsWith(u8, listed.text, "# keep this comment\n"));
    const found = try a.read(io, oid);
    defer gpa.free(found.bytes);
    try std.testing.expectEqualStrings("through two alternates\n", found.bytes);
    try a.removeAlternate(io, "../b");
    try std.testing.expect(!try a.exists(io, oid));
    var after = try a.listAlternates(gpa, io);
    defer after.deinit();
    try std.testing.expectEqualStrings("# keep this comment\n", after.text);
    try std.testing.expectError(error.InvalidAlternatePath, a.addAlternate(io, "bad\x00path"));
}

test "alternate path quoting round trips comment prefixes and control bytes" {
    const gpa = std.testing.allocator;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    const path = "#quoted\\name\n\x01";
    try appendAlternatePath(gpa, &encoded, path);
    const decoded = (try parseAlternate(gpa, encoded.items)).?;
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings(path, decoded);
}

test "git reads an alternate relic wrote and relic reads one git wrote" {
    const testgit = @import("testgit.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    var borrower = try testgit.Repo.init(gpa, io, &.{});
    defer borrower.deinit();
    try source.writeFile(io, "blob", "shared by git and relic\n");
    const oid_text = try source.run(io, &.{ "hash-object", "-w", "blob" });
    defer gpa.free(oid_text);
    const oid = try Oid.parse(.sha1, std.mem.trim(u8, oid_text, "\r\n"));
    try source.exec(io, &.{ "add", "blob" });
    try source.exec(io, &.{ "commit", "-qm", "source" });
    const source_objects = try source.dir.realPathFileAlloc(io, ".git/objects", gpa);
    defer gpa.free(source_objects);
    const borrower_git_dir = try borrower.dir.openDir(io, ".git", .{});
    defer borrower_git_dir.close(io);
    var db = try Odb.open(gpa, io, borrower_git_dir, .sha1, .{});
    defer db.deinit(io);
    try db.addAlternate(io, source_objects);
    const from_git = try borrower.run(io, &.{ "cat-file", "-p", std.mem.trim(u8, oid_text, "\r\n") });
    defer gpa.free(from_git);
    try std.testing.expectEqualStrings("shared by git and relic\n", from_git);
    try db.removeAlternate(io, source_objects);
    try std.testing.expect(!try db.exists(io, oid));
    borrower.report_failures = false;
    try std.testing.expectError(error.GitFailed, borrower.run(io, &.{ "cat-file", "-e", std.mem.trim(u8, oid_text, "\r\n") }));
    if (@import("builtin").os.tag != .windows) {
        const quoted_line = try std.fmt.allocPrint(gpa, "\"{s}\"\n", .{source_objects});
        defer gpa.free(quoted_line);
        try borrower.dir.writeFile(io, .{ .sub_path = ".git/objects/info/alternates", .data = quoted_line });
        const quoted_from_git = try borrower.run(io, &.{ "cat-file", "-p", std.mem.trim(u8, oid_text, "\r\n") });
        defer gpa.free(quoted_from_git);
        try std.testing.expectEqualStrings("shared by git and relic\n", quoted_from_git);
        var quoted_db = try Odb.open(gpa, io, borrower_git_dir, .sha1, .{});
        defer quoted_db.deinit(io);
        try std.testing.expect(try quoted_db.exists(io, oid));
    }
    const source_root = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(source_root);
    const clone_root = try borrower.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(clone_root);
    const clone_path = try std.fs.path.join(gpa, &.{ clone_root, "shared" });
    defer gpa.free(clone_path);
    try source.exec(io, &.{ "clone", "-q", "--shared", source_root, clone_path });
    const clone_git_dir = try borrower.dir.openDir(io, "shared/.git", .{});
    defer clone_git_dir.close(io);
    var reopened = try Odb.open(gpa, io, clone_git_dir, .sha1, .{});
    defer reopened.deinit(io);
    const from_relic = try reopened.read(io, oid);
    defer gpa.free(from_relic.bytes);
    try std.testing.expectEqualStrings("shared by git and relic\n", from_relic.bytes);
}

test "an abbreviated name resolves, and an ambiguous one is named" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
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
    defer objects.close(io);
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
    defer objects.close(io);
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

    var it = odb.backendData().sources.items[0].dir.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "tmp_obj_"));
    }
}

test "loose inflate preserves allocation resource failures" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);
    const oid = try odb.write(io, .blob, "hello\n");
    var path_buf: [hash.max_hex_len + 2]u8 = undefined;
    const file = try objects.openFile(io, odb.loosePath(oid, &path_buf), .{});
    defer file.close(io);
    const Check = struct {
        fn run(allocator: Allocator, original: *const Odb, input: Io.File) !void {
            var data_copy = original.backendData().*;
            data_copy.gpa = allocator;
            var copy = original.*;
            copy._state = @ptrCast(&data_copy);
            const bytes = try copy.inflateWhole(std.testing.io, input);
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings("blob 6\x00hello\n", bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(gpa, Check.run, .{ &odb, file });
}

test "loose inflate distinguishes policy resource failures from corruption" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);
    const oid = try odb.write(io, .blob, "hello\n");
    odb.backendData().options.max_object_bytes = 1;
    try std.testing.expectError(error.StreamTooLong, odb.read(io, oid));
    odb.backendData().options.max_object_bytes = 100;
    var path_buf: [hash.max_hex_len + 2]u8 = undefined;
    try objects.writeFile(io, .{ .sub_path = odb.loosePath(oid, &path_buf), .data = "bad zlib" });
    try std.testing.expectError(error.CorruptLooseObject, odb.read(io, oid));
}

test "loose reads preserve I/O and cancellation resource failures" {
    const Fault = struct {
        threadlocal var failure: Io.File.ReadPositionalError = error.InputOutput;
        fn read(_: ?*anyopaque, _: Io.File, _: []const []u8, _: u64) Io.File.ReadPositionalError!usize {
            return failure;
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);
    const oid = try odb.write(io, .blob, "hello\n");
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Fault.read;
    const failing_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Io.File.ReadPositionalError{ error.InputOutput, error.Canceled }) |failure| {
        Fault.failure = failure;
        try std.testing.expectError(failure, odb.read(failing_io, oid));
        try std.testing.expectError(failure, odb.readHeader(failing_io, oid));
        try std.testing.expectError(failure, odb.readHeaderForPack(failing_io, oid, 100));
    }
}

test "a loose object's header is read without inflating its body" {
    // What the file reads return: a loose object is read positionally.
    const Counting = struct {
        threadlocal var bytes: usize = 0;
        fn positional(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            const n = try std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
            bytes += n;
            return n;
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);
    // Bytes that do not compress, so every byte inflated is a byte read.
    const body = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(body);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    prng.random().bytes(body);
    const oid = try odb.write(io, .blob, body);

    var vtable = io.vtable.*;
    vtable.fileReadPositional = Counting.positional;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    Counting.bytes = 0;
    const header = try odb.readHeader(counted, oid);
    try std.testing.expectEqual(object.Header{ .type = .blob, .size = body.len }, header);
    // The zlib header, the first block's and the object's own: well under
    // a kilobyte, against the whole inflate window a full read fills.
    if (Counting.bytes > 1024) {
        std.debug.print("a header read read {d} bytes of a {d}-byte object\n", .{ Counting.bytes, body.len });
        return error.TestUnexpectedResult;
    }
}

test "packed source registration owns its files and names when allocation stops" {
    const testgit = @import("testgit.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "file", "packed\n");
    try source.exec(io, &.{ "add", "." });
    try source.exec(io, &.{ "commit", "-qm", "base" });
    try source.exec(io, &.{ "repack", "-ad" });
    const dir = try source.gitDir(io);
    defer dir.close(io);
    const Case = struct {
        fn run(allocator: Allocator, git_dir: Io.Dir) !void {
            var db = try Odb.open(allocator, std.testing.io, git_dir, .sha1, .{ .probe_timestamp_resolution = false });
            defer db.deinit(std.testing.io);
            try std.testing.expectEqual(@as(usize, 1), db.packCount());
        }
    };
    try std.testing.checkAllAllocationFailures(gpa, Case.run, .{dir});
}

test "openAt borrows its directory on success and every allocation failure" {
    const Check = struct {
        var original: Io.Dir = undefined;
        var closed_original: bool = false;
        fn close(context: ?*anyopaque, dirs: []const Io.Dir) void {
            _ = context;
            for (dirs) |dir| {
                if (dir.handle == original.handle) closed_original = true else dir.close(std.testing.io);
            }
        }
        fn run(gpa: Allocator) !void {
            const base = std.testing.io;
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            try tmp.dir.createDirPath(base, "pack");
            original = tmp.dir;
            closed_original = false;
            var vtable = base.vtable.*;
            vtable.dirClose = close;
            const io: Io = .{ .userdata = base.userdata, .vtable = &vtable };
            var db = Odb.openAt(gpa, io, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false }) catch |err| {
                try std.testing.expect(!closed_original);
                return err;
            };
            db.deinit(io);
            try std.testing.expect(!closed_original);
            try tmp.dir.access(base, "pack", .{});
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "selected object durability names a foreign object format" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Odb.openAt(std.testing.allocator, io, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    try std.testing.expectError(error.ObjectFormatMismatch, db.makeDurable(io, &.{hash.Hasher.object(.sha256, "blob", "a")}));
}

test "object discovery refuses unreadable loose state instead of partial answers" {
    const Probe = struct {
        var failure: Io.Dir.OpenError = error.AccessDenied;
        fn openDir(_: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            if (path.len == 2) return failure;
            return dir.openDir(std.testing.io, path, options);
        }
        fn access(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
            return error.InputOutput;
        }
        fn next(_: ?*anyopaque, _: *Io.Dir.Reader, _: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
            return error.Canceled;
        }
    };
    const gpa = std.testing.allocator;
    const base = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Odb.openAt(gpa, base, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(base);
    const oid = try db.write(base, .blob, "a");
    var vtable = base.vtable.*;
    vtable.dirOpenDir = Probe.openDir;
    var io: Io = .{ .userdata = base.userdata, .vtable = &vtable };
    var hex: [hash.max_hex_len]u8 = undefined;
    for ([_]Io.Dir.OpenError{ error.AccessDenied, error.ProcessFdQuotaExceeded, error.Canceled }) |err| {
        Probe.failure = err;
        try std.testing.expectError(err, db.verify(io));
        try std.testing.expectError(err, db.listObjects(io));
        try std.testing.expectError(err, db.collectLoose(io, .{}));
        try std.testing.expectError(err, db.collectAll(io, .{}));
        try std.testing.expectError(err, db.findPrefix(io, oid.hex(&hex)[0..8]));
    }
    vtable = base.vtable.*;
    vtable.dirAccess = Probe.access;
    io.vtable = &vtable;
    try std.testing.expectError(error.InputOutput, db.exists(io, oid));
    try std.testing.expectError(error.InputOutput, db.existsOwn(io, oid));
    // Iteration itself must not turn a failed prefix search into a miss.
    vtable = base.vtable.*;
    vtable.dirRead = Probe.next;
    try std.testing.expectError(error.Canceled, db.findPrefix(io, oid.hex(&hex)[0..8]));
}

test "object source discovery keeps alternate and pack read refusals" {
    const Probe = struct {
        fn openDir(_: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            if (std.mem.eql(u8, path, "../other")) return error.ProcessFdQuotaExceeded;
            return dir.openDir(std.testing.io, path, options);
        }
    };
    const gpa = std.testing.allocator;
    const base = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(base, "objects/info");
    try tmp.dir.createDirPath(base, "objects/pack");
    try tmp.dir.writeFile(base, .{ .sub_path = "objects/info/alternates", .data = "../other\n" });
    var vtable = base.vtable.*;
    vtable.dirOpenDir = Probe.openDir;
    const io: Io = .{ .userdata = base.userdata, .vtable = &vtable };
    if (Odb.open(gpa, io, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false })) |value| {
        var unexpected = value;
        unexpected.deinit(base);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.ProcessFdQuotaExceeded, err);
    try tmp.dir.deleteFile(base, "objects/info/alternates");
    // A named pack with a truncated index cannot disappear from discovery.
    try tmp.dir.writeFile(base, .{ .sub_path = "objects/pack/pack-invalid.idx", .data = "x" });
    if (Odb.open(gpa, base, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false })) |value| {
        var unexpected = value;
        unexpected.deinit(base);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.TruncatedIndex, err);
}

test "object discovery preserves optional index and hint read resources" {
    const Probe = struct {
        fn openFile(_: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
            if (std.mem.eql(u8, path, "multi-pack-index") or (path.len > 2 and path[2] == '/')) return error.SystemResources;
            return dir.openFile(std.testing.io, path, options);
        }
        fn open(io: Io, dir: Io.Dir) !void {
            var db = try Odb.openAt(std.testing.allocator, io, dir, .sha1, .{ .probe_timestamp_resolution = false });
            defer db.deinit(std.testing.io);
        }
        fn collect(db: *Odb, io: Io) !void {
            var found = try db.collectLoose(io, .{});
            defer found.deinit();
        }
    };
    const base = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(base, "pack");
    var vtable = base.vtable.*;
    vtable.dirOpenFile = Probe.openFile;
    const io: Io = .{ .userdata = base.userdata, .vtable = &vtable };
    try std.testing.expectError(error.SystemResources, Probe.open(io, tmp.dir));
    var db = try Odb.openAt(std.testing.allocator, base, tmp.dir, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(base);
    _ = try db.write(base, .tree, "");
    try std.testing.expectError(error.SystemResources, Probe.collect(&db, io));
}

test "a cached loose body fits one buffered read and an end check" {
    const Counter = struct {
        threadlocal var reads: usize = 0;
        fn read(userdata: ?*anyopaque, file: Io.File, buffers: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            reads += 1;
            const io = std.testing.io;
            return io.vtable.fileReadPositional(userdata, file, buffers, offset);
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{});
    defer odb.deinit(io);
    var bytes: [12000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(1950);
    prng.random().bytes(&bytes);
    const oid = try odb.write(io, .blob, &bytes);
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Counter.read;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    Counter.reads = 0;
    const found = try odb.readHeaderForPack(counted, oid, bytes.len);
    defer gpa.free(found.bytes.?);
    try std.testing.expectEqual(object.Type.blob, found.header.type);
    try std.testing.expectEqualSlices(u8, &bytes, found.bytes.?);
    try std.testing.expect(Counter.reads <= 2);
}

test "an object read into a kept buffer is the object read, and borrows the buffer" {
    const io = std.testing.io;
    const Counting = struct {
        child: Allocator,
        allocations: usize = 0,
        fn allocator(c: *@This()) Allocator {
            return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.allocations += 1;
            return c.child.rawAlloc(len, alignment, ret);
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.child.rawFree(memory, alignment, ret);
        }
    };
    var counting: Counting = .{ .child = std.testing.allocator };
    const gpa = counting.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var odb = try Odb.openAt(gpa, io, objects, .sha1, .{ .probe_timestamp_resolution = false });
    defer odb.deinit(io);

    // Versions of one file, which pack as a whole object and deltas, and a
    // loose object the pack does not hold.
    var names: std.ArrayList(Oid) = .empty;
    defer names.deinit(std.testing.allocator);
    var entries: std.ArrayList(PackEntry) = .empty;
    defer entries.deinit(std.testing.allocator);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..12) |v| {
        for (0..200) |line| try body.print(std.testing.allocator, "version {d} line {d}\n", .{ v, line });
        const oid = try odb.write(io, .blob, body.items);
        try names.append(std.testing.allocator, oid);
        try entries.append(std.testing.allocator, .{ .oid = oid, .hint = "file" });
    }
    var pack_dir = try objects.openDir(io, "pack", .{ .iterate = true });
    defer pack_dir.close(io);
    const written = try odb.writePack(io, pack_dir, entries.items, .{ .threads = 1 });
    try std.testing.expect(written.deltas > 0);
    try odb.refresh(io);
    try names.append(std.testing.allocator, try odb.write(io, .blob, "loose only\n"));

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    for (names.items) |oid| {
        const expected = try odb.read(io, oid);
        defer gpa.free(expected.bytes);
        const got = try odb.readInto(io, oid, &buffer);
        try std.testing.expectEqual(expected.type, got.type);
        try std.testing.expectEqualSlices(u8, expected.bytes, got.bytes);
        // Borrowed: the bytes are the buffer's.
        try std.testing.expectEqual(buffer.items.ptr, got.bytes.ptr);
        try std.testing.expectEqual(buffer.items.len, got.bytes.len);
    }

    // The pack's whole object, read again into a buffer already large
    // enough, allocates nothing and lands where the last one did.
    const whole = names.items[names.items.len - 2];
    const before_ptr = buffer.items.ptr;
    _ = try odb.readInto(io, whole, &buffer);
    const allocations = counting.allocations;
    const again = try odb.readInto(io, whole, &buffer);
    try std.testing.expectEqual(allocations, counting.allocations);
    try std.testing.expectEqual(before_ptr, again.bytes.ptr);

    // A miss is the miss `read` gives, and leaves the buffer the caller's.
    try std.testing.expectError(error.ObjectNotFound, odb.readInto(io, try Oid.parse(.sha1, "1" ** 40), &buffer));
    _ = try odb.readInto(io, names.items[0], &buffer);
}
