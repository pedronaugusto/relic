//! The untracked cache, git's `UNTR` index extension (`dir.c`): for each
//! directory the last `git status` read, its stat, its `.gitignore`'s
//! object, and the untracked names it held, so that a directory whose stat
//! has not moved need not be read again.
//!
//! What this package does with it is what git's index code does: read it,
//! keep it true while entries come and go -- a path that joins or leaves
//! the index invalidates the directories it is in, as git's
//! `untracked_cache_add_to_index` and `untracked_cache_remove_from_index`
//! do -- and write it back. Filling it is a status walk's business.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const codec = @import("../codec.zig");
const ewah = codec.ewah;
const varint = codec.varint;

/// git's `DIR_SHOW_OTHER_DIRECTORIES`: an untracked directory is shown as
/// one name. Part of `dir_flags`, and what makes an invalidation reach back
/// to the root.
pub const show_other_directories: u32 = 1 << 1;
/// git's `DIR_HIDE_EMPTY_DIRECTORIES`.
pub const hide_empty_directories: u32 = 1 << 2;

/// Errors from the untracked cache: memory, and the writer it is written to.
pub const Error = Allocator.Error || Io.Writer.Error;

/// git's `struct stat_data` as the extension stores it: nine big-endian
/// words, kept as they were read.
pub const StatData = [36]u8;

/// A file's stat and object: git's `struct oid_stat`, for
/// `$GIT_DIR/info/exclude` and `core.excludesFile`.
pub const OidStat = struct {
    stat: StatData = @splat(0),
    /// Raw, the repository's hash length; all zeros for none.
    oid: [hash.max_raw_len]u8 = @splat(0),
};

/// One directory: git's `struct untracked_cache_dir`.
pub const Dir = struct {
    /// Its own name, no slash; the root's is empty.
    name: []const u8,
    /// The untracked names in it, a directory's with its slash.
    untracked: std.ArrayList([]const u8) = .empty,
    /// The directories under it, by name.
    dirs: std.ArrayList(*Dir) = .empty,
    stat: StatData = @splat(0),
    /// Whether `stat`, `untracked` and `check_only` are good.
    valid: bool = false,
    check_only: bool = false,
    /// Its `.gitignore`'s object, raw; `null` for none.
    exclude_oid: ?[hash.max_raw_len]u8 = null,

    /// git's `invalidate_one_directory`.
    fn invalidate(d: *Dir) void {
        d.valid = false;
        d.untracked.clearRetainingCapacity();
    }
};

/// The cache: git's `struct untracked_cache`. Everything it holds lives in
/// its arena; release it with `deinit`.
pub const UntrackedCache = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator,
    /// "Location <working tree>, system <kernel>" and a NUL: where the
    /// cache was made, which git checks before it trusts one.
    ident: []const u8,
    info_exclude: OidStat = .{},
    excludes_file: OidStat = .{},
    /// The `dir_struct` flags of the walk it serves.
    dir_flags: u32,
    /// The per-directory ignore file, `.gitignore`.
    exclude_per_dir: []const u8,
    /// `null` until a walk starts it.
    root: ?*Dir = null,

    /// A new, empty cache, as git's `new_untracked_cache` makes one: no
    /// directory yet. `ident` is copied and given its NUL.
    pub fn init(gpa: Allocator, ident: []const u8, dir_flags: u32) Allocator.Error!UntrackedCache {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        return .{
            .ident = try std.mem.concat(a, u8, &.{ ident, "\x00" }),
            .dir_flags = dir_flags,
            .exclude_per_dir = ".gitignore",
            .arena = arena,
        };
    }

    pub fn deinit(uc: *UntrackedCache) void {
        uc.arena.deinit();
        uc.* = undefined;
    }

    /// Whether the cache was made for `ident` (without its NUL): git's
    /// `ident_in_untracked`, which reads the first of what older gits kept
    /// as a list.
    pub fn madeFor(uc: *const UntrackedCache, ident: []const u8) bool {
        const first = std.mem.sliceTo(uc.ident, 0);
        return std.mem.eql(u8, first, ident);
    }

    /// Forget what is cached for the directories `path` lies in: git's
    /// `untracked_cache_invalidate_path`. The directory holding it always,
    /// and under `show_other_directories` each one above it, since a
    /// directory shown as one name may have become or stopped being one.
    /// A directory the cache does not hold is passed through, where git
    /// makes one it never writes.
    pub fn invalidatePath(uc: *UntrackedCache, path: []const u8) void {
        const root = uc.root orelse return;
        _ = uc.invalidateFrom(root, path);
    }

    fn invalidateFrom(uc: *const UntrackedCache, dir: ?*Dir, path: []const u8) bool {
        const slash = std.mem.findScalar(u8, path, '/') orelse {
            if (dir) |d| d.invalidate();
            return uc.dir_flags & show_other_directories != 0;
        };
        const child = if (dir) |d| find(d, path[0..slash]) else null;
        const reaches = uc.invalidateFrom(child, path[slash + 1 ..]);
        if (reaches) if (dir) |d| d.invalidate();
        return reaches;
    }

    /// The directory `name` under `dir`: git's `lookup_untracked`, which
    /// keeps them by name.
    fn find(dir: *const Dir, name: []const u8) ?*Dir {
        var first: usize = 0;
        var last: usize = dir.dirs.items.len;
        while (last > first) {
            const next = first + (last - first) / 2;
            const d = dir.dirs.items[next];
            switch (std.mem.order(u8, name, d.name)) {
                .eq => return d,
                .lt => last = next,
                .gt => first = next + 1,
            }
        }
        return null;
    }

    /// Forget every directory's contents, keeping the cache's own
    /// settings: what an index rebuilt whole leaves true.
    pub fn invalidateAll(uc: *UntrackedCache) void {
        if (uc.root) |root| invalidateTree(root);
    }

    fn invalidateTree(dir: *Dir) void {
        dir.invalidate();
        for (dir.dirs.items) |d| invalidateTree(d);
    }

    /// The extension's bytes, as git's `write_untracked_extension` writes
    /// them, into `out`.
    pub fn write(uc: *const UntrackedCache, gpa: Allocator, kind: hash.Kind, out: *Io.Writer) Self.Error!void {
        const raw_len = kind.rawLen();
        try writeVarint(out, uc.ident.len);
        try out.writeAll(uc.ident);
        try out.writeAll(&uc.info_exclude.stat);
        try out.writeAll(&uc.excludes_file.stat);
        try out.writeInt(u32, uc.dir_flags, .big);
        try out.writeAll(uc.info_exclude.oid[0..raw_len]);
        try out.writeAll(uc.excludes_file.oid[0..raw_len]);
        try out.writeAll(uc.exclude_per_dir);
        try out.writeByte(0);
        const root = uc.root orelse return writeVarint(out, 0);

        var walk: Walk = .{ .gpa = gpa, .raw_len = raw_len };
        defer walk.deinit();
        try walk.dir(root);
        try writeVarint(out, walk.count);
        try out.writeAll(walk.body.written());
        for ([_]*std.ArrayList(u32){ &walk.valid, &walk.check_only, &walk.oid_valid }) |bits| {
            const bitmap = try ewah.writePositions(gpa, bits.items);
            defer gpa.free(bitmap);
            try out.writeAll(bitmap);
        }
        try out.writeAll(walk.stats.written());
        try out.writeAll(walk.oids.written());
        try out.writeByte(0);
    }

    /// `write_one_dir`'s state across the tree.
    const Walk = struct {
        gpa: Allocator,
        raw_len: usize,
        count: u32 = 0,
        body: Io.Writer.Allocating = undefined,
        stats: Io.Writer.Allocating = undefined,
        oids: Io.Writer.Allocating = undefined,
        valid: std.ArrayList(u32) = .empty,
        check_only: std.ArrayList(u32) = .empty,
        oid_valid: std.ArrayList(u32) = .empty,
        started: bool = false,

        fn deinit(w: *Walk) void {
            if (w.started) {
                w.body.deinit();
                w.stats.deinit();
                w.oids.deinit();
            }
            w.valid.deinit(w.gpa);
            w.check_only.deinit(w.gpa);
            w.oid_valid.deinit(w.gpa);
        }

        fn dir(w: *Walk, d: *const Dir) (Allocator.Error || Io.Writer.Error)!void {
            if (!w.started) {
                w.body = .init(w.gpa);
                w.stats = .init(w.gpa);
                w.oids = .init(w.gpa);
                w.started = true;
            }
            const at = w.count;
            w.count += 1;
            // An invalid directory is written with nothing in it.
            const untracked: []const []const u8 = if (d.valid) d.untracked.items else &.{};
            if (d.valid and d.check_only) try w.check_only.append(w.gpa, at);
            if (d.valid) {
                try w.valid.append(w.gpa, at);
                try w.stats.writer.writeAll(&d.stat);
            }
            if (d.exclude_oid) |oid| {
                try w.oid_valid.append(w.gpa, at);
                try w.oids.writer.writeAll(oid[0..w.raw_len]);
            }
            const out = &w.body.writer;
            try writeVarint(out, untracked.len);
            try writeVarint(out, d.dirs.items.len);
            try out.writeAll(d.name);
            try out.writeByte(0);
            for (untracked) |name| {
                try out.writeAll(name);
                try out.writeByte(0);
            }
            for (d.dirs.items) |child| try w.dir(child);
        }
    };
};

fn writeVarint(out: *Io.Writer, value: usize) Io.Writer.Error!void {
    var buf: [16]u8 = undefined;
    try out.writeAll(varint.writeOffset(&buf, value));
}

/// Read the extension as git's `read_untracked_extension` does: `null` for
/// bytes it would not take, which git drops without a word.
pub fn parse(gpa: Allocator, kind: hash.Kind, data: []const u8) Allocator.Error!?UntrackedCache {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const cache = (try parseInto(arena.allocator(), kind, data)) orelse {
        arena.deinit();
        return null;
    };
    var uc = cache;
    uc.arena = arena;
    return uc;
}

const Reader = struct {
    data: []const u8,
    at: usize = 0,

    fn number(r: *Reader) ?u64 {
        const read = varint.readOffset(r.data[r.at..]) catch return null;
        r.at += read.len;
        return read.value;
    }

    fn string(r: *Reader) ?[]const u8 {
        const end = std.mem.findScalarPos(u8, r.data, r.at, 0) orelse return null;
        const s = r.data[r.at..end];
        r.at = end + 1;
        return s;
    }

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.data.len - r.at < n) return null;
        const s = r.data[r.at..][0..n];
        r.at += n;
        return s;
    }
};

fn parseInto(a: Allocator, kind: hash.Kind, whole: []const u8) Allocator.Error!?UntrackedCache {
    const raw_len = kind.rawLen();
    if (whole.len <= 1 or whole[whole.len - 1] != 0) return null;
    var r: Reader = .{ .data = whole[0 .. whole.len - 1] };
    const ident_len = r.number() orelse return null;
    const ident = r.take(std.math.cast(usize, ident_len) orelse return null) orelse return null;
    const info_stat = r.take(36) orelse return null;
    const excludes_stat = r.take(36) orelse return null;
    const flags = r.take(4) orelse return null;
    const info_oid = r.take(raw_len) orelse return null;
    const excludes_oid = r.take(raw_len) orelse return null;
    const per_dir = r.string() orelse return null;
    var uc: UntrackedCache = .{
        .arena = undefined,
        .ident = try a.dupe(u8, ident),
        .dir_flags = std.mem.readInt(u32, flags[0..4], .big),
        .exclude_per_dir = try a.dupe(u8, per_dir),
    };
    @memcpy(&uc.info_exclude.stat, info_stat);
    @memcpy(uc.info_exclude.oid[0..raw_len], info_oid);
    @memcpy(&uc.excludes_file.stat, excludes_stat);
    @memcpy(uc.excludes_file.oid[0..raw_len], excludes_oid);
    if (r.at >= r.data.len) return uc;

    const count = r.number() orelse return null;
    if (count == 0) return if (r.at == r.data.len) uc else null;
    var dirs: std.ArrayList(*Dir) = .empty;
    uc.root = (try readDir(a, &r, &dirs)) orelse return null;
    if (dirs.items.len != count) return null;
    var bitmaps: [3]ewah.Bits = undefined;
    for (&bitmaps) |*bits| {
        const read = ewah.read(a, r.data[r.at..]) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return null,
        };
        r.at += read.len;
        bits.* = read.bits;
    }
    for (bitmaps[1].positions) |p| {
        if (p >= dirs.items.len) return null;
        dirs.items[p].check_only = true;
    }
    for (bitmaps[0].positions) |p| {
        if (p >= dirs.items.len) return null;
        const stat = r.take(36) orelse return null;
        @memcpy(&dirs.items[p].stat, stat);
        dirs.items[p].valid = true;
    }
    for (bitmaps[2].positions) |p| {
        if (p >= dirs.items.len) return null;
        const oid = r.take(raw_len) orelse return null;
        var raw: [hash.max_raw_len]u8 = @splat(0);
        @memcpy(raw[0..raw_len], oid);
        dirs.items[p].exclude_oid = raw;
    }
    if (r.at != r.data.len) return null;
    return uc;
}

/// git's `read_one_dir`: a directory and, after it, each one under it.
fn readDir(a: Allocator, r: *Reader, all: *std.ArrayList(*Dir)) Allocator.Error!?*Dir {
    const untracked_count = r.number() orelse return null;
    const dir_count = r.number() orelse return null;
    const name = r.string() orelse return null;
    const d = try a.create(Dir);
    d.* = .{ .name = try a.dupe(u8, name) };
    for (0..std.math.cast(usize, untracked_count) orelse return null) |_| {
        const entry = r.string() orelse return null;
        try d.untracked.append(a, try a.dupe(u8, entry));
    }
    try all.append(a, d);
    for (0..std.math.cast(usize, dir_count) orelse return null) |_| {
        const child = (try readDir(a, r, all)) orelse return null;
        try d.dirs.append(a, child);
    }
    return d;
}
