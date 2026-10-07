//! A repository's refs as a stack of reftables: `reftable/tables.list`
//! names the tables oldest first, and a ref's value is the one the newest
//! table that mentions it gives -- a tombstone there meaning it is gone.
//!
//! A transaction adds one table. It takes `tables.list.lock` the way git
//! takes it, reads the stack under the lock, checks every expected value,
//! writes the new table beside the others under a name that says which
//! update indexes it covers, and replaces `tables.list` with one more line.
//! Readers never lock: they read `tables.list` and then the tables it
//! names, and a table a concurrent compaction has already removed sends
//! them back to read the list again, which by then names its replacement.
//!
//! After each addition the stack is compacted by git's geometric rule:
//! walking back from the newest table, any run where an older table is not
//! at least twice the size of what follows it is merged into one, so the
//! stack stays logarithmic in the number of transactions. A compaction that
//! reaches the oldest table drops the tombstones, since nothing older is
//! left for them to hide. The sizes the rule compares are this writer's;
//! a log block deflated here is not byte for byte zlib's, so on a stack
//! with logs the point at which a compaction happens can differ from git's
//! by a table, while what every ref and log says does not.
//!
//! `FETCH_HEAD` and `MERGE_HEAD` stay files in a reftable repository, as git
//! keeps them: a transaction writes them under their own `.lock` beside
//! the stack, and no log. Every other pseudoref -- `ORIG_HEAD`,
//! `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `AUTO_MERGE` -- is a ref in the stack,
//! which is where git since 2.45 keeps them.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../../hash.zig");
const object = @import("../../object.zig");
const fs = @import("../../repo/fs.zig");
const reftable = @import("../reftable.zig");
const reflog = @import("../reflog.zig");
const ref_names = @import("../../names/ref.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// How the stack writes and compacts. The defaults are git's, and
/// `Repository` fills them in from `reftable.*` in the configuration.
pub const Options = @import("policy.zig").Options;

/// Errors from reading a stack.
pub const Error = @import("policy.zig").Error;

/// How many times a reader goes back to `tables.list` when a table it names
/// has gone, which only a compaction finishing in between can cause.
const max_reload_attempts = 8;

/// One stack, read: the list, and every table it names open.
///
/// A table is its footer and an open file; its blocks are read with
/// positional reads as a lookup reaches them, through the table's index
/// where it has one, so a lookup costs a few blocks and not the stack.
pub const Stack = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    /// Oldest first, as `tables.list` has them.
    names: []const []const u8,
    tables: []reftable.Table,
    files: []Io.File,
    /// `tables.list` as it was read.
    list: []const u8,

    fn empty(gpa: Allocator, io: Io, kind: Kind) Stack {
        return .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .kind = kind,
            .names = &.{},
            .tables = &.{},
            .files = &.{},
            .list = "",
        };
    }

    /// Read the stack in `dir`, the `reftable` directory. A directory with
    /// no `tables.list` is an empty stack.
    pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, kind: Kind) Error!Stack {
        return loadReusing(gpa, io, dir, kind, null);
    }

    /// Read the stack again, keeping open every table the new list still
    /// names -- a table never changes once written -- and closing the rest.
    /// This is git's reload: after a transaction one table is new, and after
    /// a compaction a few are replaced by one.
    fn loadReusing(gpa: Allocator, io: Io, dir: Io.Dir, kind: Kind, old: ?*Stack) Error!Stack {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            if (tryLoad(gpa, io, dir, kind, old)) |stack| {
                return stack;
            } else |err| switch (err) {
                error.FileNotFound => if (attempt + 1 >= max_reload_attempts) return error.ReftableMissing,
                else => |e| return e,
            }
        }
    }

    fn tryLoad(gpa: Allocator, io: Io, dir: Io.Dir, kind: Kind, old: ?*Stack) (Error || error{FileNotFound})!Stack {
        var stack: Stack = .empty(gpa, io, kind);
        errdefer stack.arena.deinit();
        const arena = stack.arena.allocator();
        const text = (try fs.readFileAlloc(arena, io, dir, "tables.list", 1 << 24)) orelse {
            if (old) |o| o.closeUnclaimed(&.{});
            return stack;
        };
        stack.list = text;

        var names: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (!isTableName(line)) return error.MalformedTablesList;
            try names.append(arena, line);
        }
        const tables = try arena.alloc(reftable.Table, names.items.len);
        const files = try arena.alloc(Io.File, names.items.len);
        // Which tables this load opened itself, and so closes on failure.
        const opened = try arena.alloc(bool, names.items.len);
        @memset(opened, false);
        errdefer for (files, opened) |f, mine| {
            if (mine) f.close(io);
        };
        for (names.items, tables, files, opened) |name, *table, *file, *mine| {
            if (old) |o| {
                if (o.indexOf(name)) |at| {
                    table.* = o.tables[at];
                    file.* = o.files[at];
                    continue;
                }
            }
            file.* = dir.openFile(io, name, .{}) catch |err| switch (err) {
                error.FileNotFound => return error.FileNotFound,
                else => |e| return e,
            };
            mine.* = true;
            table.* = try reftable.Table.open(io, file.*, kind);
        }
        stack.names = names.items;
        stack.tables = tables;
        stack.files = files;
        if (old) |o| o.closeUnclaimed(stack.names);
        return stack;
    }

    fn indexOf(s: *const Stack, name: []const u8) ?usize {
        for (s.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }

    /// Close the tables `keep` does not name, whose files a reload has not
    /// taken over.
    fn closeUnclaimed(s: *Stack, keep: []const []const u8) void {
        for (s.names, s.files) |name, file| {
            var kept = false;
            for (keep) |k| {
                if (std.mem.eql(u8, k, name)) kept = true;
            }
            if (!kept) file.close(s.io);
        }
        s.files = &.{};
    }

    /// Release the stack and close its tables.
    pub fn deinit(s: *Stack) void {
        for (s.files) |f| f.close(s.io);
        s.arena.deinit();
        s.* = undefined;
    }

    /// The highest update index any table covers, or zero for an empty
    /// stack. The next addition takes the one after it.
    pub fn maxUpdateIndex(s: *const Stack) u64 {
        var max: u64 = 0;
        for (s.tables) |t| max = @max(max, t.max_update_index);
        return max;
    }

    /// The newest record for `name`, tombstone included, or `null` when no
    /// table mentions it. The name is `name`; a symbolic target is copied
    /// with `out`.
    pub fn lookup(s: *const Stack, gpa: Allocator, out: Allocator, name: []const u8) Error!?reftable.RefRecord {
        var i = s.tables.len;
        while (i > 0) {
            i -= 1;
            var it = try s.tables[i].seek(gpa, .ref, name);
            defer it.deinit();
            const found = (try it.nextRef()) orelse continue;
            if (!std.mem.eql(u8, found.name, name)) continue;
            var record = found;
            record.name = name;
            if (found.value == .symbolic) record.value = .{ .symbolic = try out.dupe(u8, found.value.symbolic) };
            return record;
        }
        return null;
    }

    /// Every live ref beginning with `prefix`, newest record for each name,
    /// sorted by name. The records and their names live in `arena`.
    pub fn refsWithPrefix(s: *const Stack, gpa: Allocator, arena: Allocator, prefix: []const u8, include_deletions: bool) Error![]reftable.RefRecord {
        return mergedRefs(gpa, arena, s.tables, prefix, include_deletions);
    }

    /// The log entries for `name`, newest first, the newest record for each
    /// update index winning and tombstones taken out. The strings live in
    /// `arena`.
    pub fn logsFor(s: *const Stack, gpa: Allocator, arena: Allocator, name: []const u8) Error![]reftable.LogRecord {
        const start = try reftable.logKey(gpa, name, std.math.maxInt(u64));
        defer gpa.free(start);
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(gpa);
        var out: std.ArrayList(reftable.LogRecord) = .empty;
        var i = s.tables.len;
        while (i > 0) {
            i -= 1;
            var it = try s.tables[i].seek(gpa, .log, start);
            defer it.deinit();
            while (try it.nextLog()) |record| {
                if (!std.mem.eql(u8, record.name, name)) break;
                const gop = try seen.getOrPut(gpa, record.update_index);
                if (gop.found_existing) continue;
                if (record.value == .deletion) continue;
                try out.append(arena, try copyLog(arena, record));
            }
        }
        std.mem.sort(reftable.LogRecord, out.items, {}, newerFirst);
        return out.items;
    }
};

/// The newest record for each ref beginning with `prefix` across `tables`,
/// oldest first, sorted by name; tombstones kept only when asked for.
fn mergedRefs(gpa: Allocator, arena: Allocator, tables: []const reftable.Table, prefix: []const u8, include_deletions: bool) Error![]reftable.RefRecord {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var out: std.ArrayList(reftable.RefRecord) = .empty;
    var i = tables.len;
    while (i > 0) {
        i -= 1;
        var it = try tables[i].seek(gpa, .ref, prefix);
        defer it.deinit();
        while (try it.nextRef()) |record| {
            if (!std.mem.startsWith(u8, record.name, prefix)) break;
            if (seen.contains(record.name)) continue;
            const name = try arena.dupe(u8, record.name);
            try seen.put(gpa, name, {});
            if (record.value == .deletion and !include_deletions) continue;
            var copy = record;
            copy.name = name;
            if (record.value == .symbolic) copy.value = .{ .symbolic = try arena.dupe(u8, record.value.symbolic) };
            try out.append(arena, copy);
        }
    }
    std.mem.sort(reftable.RefRecord, out.items, {}, lessThanRef);
    return out.items;
}

/// Every log record of every ref across `tables`, newest record for each
/// key, sorted by key; tombstones kept unless `drop_deletions`. For
/// compaction.
fn allLogs(gpa: Allocator, arena: Allocator, tables: []const reftable.Table, drop_deletions: bool) Error![]reftable.LogRecord {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var out: std.ArrayList(reftable.LogRecord) = .empty;
    var i = tables.len;
    while (i > 0) {
        i -= 1;
        var it = try tables[i].iterate(gpa, .log);
        defer it.deinit();
        while (try it.nextLog()) |record| {
            const key = try reftable.logKey(arena, record.name, record.update_index);
            const gop = try seen.getOrPut(gpa, key);
            if (gop.found_existing) continue;
            if (record.value == .deletion and drop_deletions) continue;
            try out.append(arena, try copyLog(arena, record));
        }
    }
    std.mem.sort(reftable.LogRecord, out.items, {}, logOrder);
    return out.items;
}

fn copyLog(arena: Allocator, record: reftable.LogRecord) Allocator.Error!reftable.LogRecord {
    var copy = record;
    copy.name = try arena.dupe(u8, record.name);
    switch (record.value) {
        .deletion => {},
        .update => |u| {
            copy.value.update.name = try arena.dupe(u8, u.name);
            copy.value.update.email = try arena.dupe(u8, u.email);
            copy.value.update.message = try arena.dupe(u8, u.message);
        },
    }
    return copy;
}

fn lessThanRef(_: void, a: reftable.RefRecord, b: reftable.RefRecord) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn newerFirst(_: void, a: reftable.LogRecord, b: reftable.LogRecord) bool {
    return a.update_index > b.update_index;
}

/// A log's key order: by name, then newest first.
fn logOrder(_: void, a: reftable.LogRecord, b: reftable.LogRecord) bool {
    const by_name = std.mem.order(u8, a.name, b.name);
    if (by_name != .eq) return by_name == .lt;
    return a.update_index > b.update_index;
}

/// Whether `name` has the shape of a table's name:
/// `0x<12 hex>-0x<12 hex>-<8 hex>.ref`, which is what git writes, or
/// anything else ending `.ref` without a slash, which it also reads.
fn isTableName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".ref")) return false;
    if (std.mem.findAny(u8, name, "/\\") != null) return false;
    if (std.mem.eql(u8, name, ".ref") or name[0] == '.') return false;
    return true;
}

/// A table's file name, as git forms it.
fn tableName(io: Io, buf: *[64]u8, min: u64, max: u64) []const u8 {
    var random: [4]u8 = undefined;
    io.random(&random);
    return std.mem.print(buf, "0x{x:0>12}-0x{x:0>12}-{x:0>8}.ref", .{
        min,
        max,
        std.mem.readInt(u32, &random, .little),
    }) catch unreachable; // unreachable: two u64 of at most sixteen hex digits, a u32 of eight and fourteen bytes fit 64
}

//=========================================================================
// The ref store's side
//=========================================================================

/// The stacks a store has read, kept from one call to the next.
///
/// A daemon that holds a repository for days and reads its refs all the
/// time should not read `tables.list` and open every table for each read.
/// This keeps them, and on each read looks at `tables.list`'s stat: the same
/// file, size and time means nothing changed; otherwise the list is read,
/// and only when its text differs is the stack reloaded, keeping the tables
/// it still names open. That is how git's stack decides to reload. The
/// cache is behind a mutex, since a daemon reads from many tasks; a
/// transaction reads its own stacks under its lock and does not touch it.
pub const Cache = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    stacks: ?Stacks = null,
    main_seen: ?Validity = null,
    worktree_seen: ?Validity = null,
    /// How many times a read found the stack changed and reloaded it, for
    /// a caller or a test that wants to see the cache working.
    reloads: u64 = 0,

    /// An empty cache; nothing is read until the first lookup.
    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    /// Close every table and release the cache.
    pub fn deinit(c: *Cache) void {
        if (c.stacks) |*st| st.deinit();
        c.* = undefined;
    }

    /// Bring the stacks up to date with the disk.
    fn refresh(c: *Cache, io: Io, store: anytype) Error!*const Stacks {
        const main_now = try Validity.of(io, store.commonDir());
        const worktree_now: ?Validity = if (isLinked(store)) try Validity.of(io, store.gitDir()) else null;
        if (c.stacks) |*st| {
            if (Validity.same(c.main_seen, main_now) and
                (!isLinked(store) or Validity.same(c.worktree_seen, worktree_now)))
            {
                return st;
            }
            // The stat moved; the list may not have. Reload only what did.
            c.reloads += 1;
            if (!Validity.same(c.main_seen, main_now)) {
                const fresh = try reloadIn(c.gpa, io, store.commonDir(), store.objectFormat(), &st.main);
                st.main.arena.deinit();
                st.main = fresh;
            }
            if (isLinked(store) and !Validity.same(c.worktree_seen, worktree_now)) {
                const fresh = try reloadIn(c.gpa, io, store.gitDir(), store.objectFormat(), &st.worktree.?);
                st.worktree.?.arena.deinit();
                st.worktree = fresh;
            }
        } else {
            c.stacks = try Stacks.open(c.gpa, io, store);
        }
        c.main_seen = main_now;
        c.worktree_seen = worktree_now;
        return &c.stacks.?;
    }
};

/// What a stat of `tables.list` says: enough to tell that it was replaced.
/// A list is only ever replaced by a rename, so the file's identity changes
/// with every write; its size and time are checked as well, as git's are.
const Validity = struct {
    present: bool,
    inode: Io.File.INode = 0,
    size: u64 = 0,
    mtime: i96 = 0,

    fn of(io: Io, parent: Io.Dir) Error!Validity {
        const st = parent.statFile(io, "reftable/tables.list", .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .{ .present = false },
            else => return error.ReftableMissing,
        };
        return .{ .present = true, .inode = st.inode, .size = st.size, .mtime = st.mtime.nanoseconds };
    }

    fn same(seen: ?Validity, now: ?Validity) bool {
        const a = seen orelse return false;
        const b = now orelse return false;
        return a.present == b.present and a.inode == b.inode and a.size == b.size and a.mtime == b.mtime;
    }
};

/// The stacks one read works on: the cache's, under its mutex, or a set
/// read for this call when the store has no cache.
/// The per-worktree stack and the shared one, for a store. In the main
/// worktree they are one stack.
const Stacks = struct {
    main: Stack,
    worktree: ?Stack,

    fn open(gpa: Allocator, io: Io, store: anytype) Error!Stacks {
        var main = try loadIn(gpa, io, store.commonDir(), store.objectFormat());
        errdefer main.deinit();
        const worktree: ?Stack = if (isLinked(store)) try loadIn(gpa, io, store.gitDir(), store.objectFormat()) else null;
        return .{ .main = main, .worktree = worktree };
    }

    fn deinit(s: *Stacks) void {
        s.main.deinit();
        if (s.worktree) |*w| w.deinit();
        s.* = undefined;
    }

    fn forName(s: *const Stacks, name: []const u8) *const Stack {
        if (s.worktree) |*w| {
            if (ref_names.isCurrentWorktree(name)) return w;
        }
        return &s.main;
    }
};

fn loadIn(gpa: Allocator, io: Io, parent: Io.Dir, kind: Kind) Error!Stack {
    return reloadIn(gpa, io, parent, kind, null);
}

fn reloadIn(gpa: Allocator, io: Io, parent: Io.Dir, kind: Kind, old: ?*Stack) Error!Stack {
    var dir = parent.openDir(io, "reftable", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (old) |o| o.closeUnclaimed(&.{});
            return .empty(gpa, io, kind);
        },
        else => |e| return e,
    };
    defer dir.close(io);
    return Stack.loadReusing(gpa, io, dir, kind, old);
}

fn isLinked(store: anytype) bool {
    return store.gitDir().handle != store.commonDir().handle;
}

pub const internal = struct {
    pub const hash = Self.hash;
    pub const object = Self.object;
    pub const fs = Self.fs;
    pub const reftable = Self.reftable;
    pub const reflog = Self.reflog;
    pub const max_reload_attempts = Self.max_reload_attempts;
    pub const mergedRefs = Self.mergedRefs;
    pub const allLogs = Self.allLogs;
    pub const copyLog = Self.copyLog;
    pub const lessThanRef = Self.lessThanRef;
    pub const newerFirst = Self.newerFirst;
    pub const logOrder = Self.logOrder;
    pub const isTableName = Self.isTableName;
    pub const tableName = Self.tableName;
    pub const Validity = Self.Validity;
    pub const Stacks = Self.Stacks;
    pub const loadIn = Self.loadIn;
    pub const reloadIn = Self.reloadIn;
    pub const isLinked = Self.isLinked;
    pub const refresh = Cache.refresh;
    pub const open = Self.Stacks.open;
    pub const deinit = Self.Stacks.deinit;
    pub const forName = Self.Stacks.forName;
    pub const empty = Stack.empty;
    pub const closeUnclaimed = Stack.closeUnclaimed;
};
