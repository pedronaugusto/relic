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
//! keeps them, and a transaction naming either is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const fs = @import("fs.zig");
const reftable = @import("reftable.zig");
const refs = @import("refs.zig");
const reflog = @import("reflog.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// How the stack writes and compacts. The defaults are git's, and
/// `Repository` fills them in from `reftable.*` in the configuration.
pub const Options = struct {
    /// Block size, restart interval and object index.
    write: reftable.WriteOptions = .{},
    /// Compact after every addition, by the geometric rule. git turns this
    /// off only for its own tests; it is here for a caller that compacts
    /// on its own schedule.
    auto_compact: bool = true,
    /// `reftable.geometricFactor`: how much larger each older table must be
    /// than everything after it.
    geometric_factor: u8 = 2,
};

/// Errors from reading a stack.
pub const Error = error{
    /// `tables.list` names a table that is not there, and still does after
    /// reading it again; or it could not be looked at at all.
    ReftableMissing,
    /// A line of `tables.list` that is not a table's name.
    MalformedTablesList,
} || reftable.Error || Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Cancelable;

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
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.eql(u8, name, ".ref") or name[0] == '.') return false;
    return true;
}

/// A table's file name, as git forms it.
fn tableName(buf: []u8, io: Io, min: u64, max: u64) []const u8 {
    var random: [4]u8 = undefined;
    io.random(&random);
    return std.fmt.bufPrint(buf, "0x{x:0>12}-0x{x:0>12}-{x:0>8}.ref", .{
        min,
        max,
        std.mem.readInt(u32, &random, .little),
    }) catch unreachable;
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
    fn refresh(c: *Cache, store: *const refs.Store, io: Io) Error!*const Stacks {
        const main_now = try Validity.of(io, store.common_dir);
        const worktree_now: ?Validity = if (isLinked(store)) try Validity.of(io, store.git_dir) else null;
        if (c.stacks) |*st| {
            if (Validity.same(c.main_seen, main_now) and
                (!isLinked(store) or Validity.same(c.worktree_seen, worktree_now)))
            {
                return st;
            }
            // The stat moved; the list may not have. Reload only what did.
            c.reloads += 1;
            if (!Validity.same(c.main_seen, main_now)) {
                const fresh = try reloadIn(c.gpa, io, store.common_dir, store.kind, &st.main);
                st.main.arena.deinit();
                st.main = fresh;
            }
            if (isLinked(store) and !Validity.same(c.worktree_seen, worktree_now)) {
                const fresh = try reloadIn(c.gpa, io, store.git_dir, store.kind, &st.worktree.?);
                st.worktree.?.arena.deinit();
                st.worktree = fresh;
            }
        } else {
            c.stacks = try Stacks.open(store, c.gpa, io);
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
const View = struct {
    cache: ?*Cache,
    owned: ?Stacks,
    stacks: *const Stacks,

    fn acquire(store: *const refs.Store, gpa: Allocator, io: Io, owned: *?Stacks) Error!View {
        if (store.reftable_cache) |c| {
            c.mutex.lock(io) catch return error.Canceled;
            errdefer c.mutex.unlock(io);
            const st = try c.refresh(store, io);
            return .{ .cache = c, .owned = null, .stacks = st };
        }
        owned.* = try Stacks.open(store, gpa, io);
        return .{ .cache = null, .owned = null, .stacks = &owned.*.? };
    }

    fn release(v: *View, io: Io, owned: *?Stacks) void {
        if (v.cache) |c| c.mutex.unlock(io);
        if (owned.*) |*st| st.deinit();
        owned.* = null;
    }
};

/// The per-worktree stack and the shared one, for a store. In the main
/// worktree they are one stack.
const Stacks = struct {
    main: Stack,
    worktree: ?Stack,

    fn open(store: *const refs.Store, gpa: Allocator, io: Io) Error!Stacks {
        var main = try loadIn(gpa, io, store.common_dir, store.kind);
        errdefer main.deinit();
        const worktree: ?Stack = if (isLinked(store)) try loadIn(gpa, io, store.git_dir, store.kind) else null;
        return .{ .main = main, .worktree = worktree };
    }

    fn deinit(s: *Stacks) void {
        s.main.deinit();
        if (s.worktree) |*w| w.deinit();
    }

    fn forName(s: *const Stacks, store: *const refs.Store, name: []const u8) *const Stack {
        if (s.worktree) |*w| {
            if (isPerWorktree(store, name)) return w;
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

fn isLinked(store: *const refs.Store) bool {
    return store.git_dir.handle != store.common_dir.handle;
}

fn isPerWorktree(store: *const refs.Store, name: []const u8) bool {
    return store.dirFor(name).handle == store.git_dir.handle;
}

/// Whether `name` is one git keeps as a file whatever the ref format.
pub fn isSpecial(name: []const u8) bool {
    return std.mem.eql(u8, name, "FETCH_HEAD") or std.mem.eql(u8, name, "MERGE_HEAD");
}

/// `Store.read` over reftable. The returned target of a symbolic ref is
/// the caller's.
pub fn read(store: *const refs.Store, gpa: Allocator, io: Io, name: []const u8) refs.ReadError!?refs.Ref {
    var owned: ?Stacks = null;
    var view = try View.acquire(store, gpa, io, &owned);
    defer view.release(io, &owned);
    return readIn(view.stacks, store, gpa, name);
}

fn readIn(stacks: *const Stacks, store: *const refs.Store, gpa: Allocator, name: []const u8) refs.ReadError!?refs.Ref {
    const record = (try stacks.forName(store, name).lookup(gpa, gpa, name)) orelse return null;
    return switch (record.value) {
        .deletion => null,
        .direct => |oid| .{ .direct = oid },
        .peeled => |p| .{ .direct = p.value },
        .symbolic => |target| .{ .symbolic = target },
    };
}

/// Follow symbolic refs through the stacks until an object name, with the
/// transaction's own new values taking precedence. `null` for a name that
/// is not there, which is an unborn branch's shape.
fn resolveIn(stacks: *const Stacks, store: *const refs.Store, gpa: Allocator, name: []const u8, pending: ?*const refs.Transaction) refs.ReadError!?Oid {
    var buf: [1024]u8 = undefined;
    var current: []const u8 = name;
    var depth: u8 = 0;
    while (depth <= refs.max_symbolic_depth) : (depth += 1) {
        var value: ?refs.Ref = null;
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        var overridden = false;
        if (pending) |tx| {
            for (tx.edits.items) |edit| {
                if (!std.mem.eql(u8, edit.name, current)) continue;
                overridden = true;
                value = edit.new;
            }
        }
        if (!overridden) {
            value = try readIn(stacks, store, gpa, current);
            if (value) |v| switch (v) {
                .symbolic => |t| owned = @constCast(t),
                .direct => {},
            };
        }
        const found = value orelse return null;
        switch (found) {
            .direct => |oid| return oid,
            .symbolic => |target| {
                if (target.len > buf.len) return error.MalformedRef;
                @memcpy(buf[0..target.len], target);
                current = buf[0..target.len];
            },
        }
    }
    return error.SymbolicRefLoop;
}

/// `Store.list` over reftable.
pub fn list(store: *const refs.Store, gpa: Allocator, io: Io, prefix: []const u8) refs.ReadError!refs.Store.Listing {
    var owned: ?Stacks = null;
    var view = try View.acquire(store, gpa, io, &owned);
    defer view.release(io, &owned);
    const stacks = view.stacks;

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var entries: std.ArrayList(refs.Named) = .empty;

    const sources = [_]?*const Stack{ &stacks.main, if (stacks.worktree) |*w| w else null };
    for (sources, 0..) |maybe, which| {
        const stack = maybe orelse continue;
        const records = try stack.refsWithPrefix(gpa, arena, prefix, false);
        for (records) |record| {
            // In a linked worktree the shared stack's per-worktree refs are
            // the main worktree's, and the worktree's own stack holds only
            // per-worktree refs.
            if (stacks.worktree != null and isPerWorktree(store, record.name) != (which == 1)) continue;
            try entries.append(arena, .{
                .name = record.name,
                .target = switch (record.value) {
                    .direct => |oid| .{ .direct = oid },
                    .peeled => |p| .{ .direct = p.value },
                    .symbolic => |t| .{ .symbolic = try arena.dupe(u8, t) },
                    .deletion => unreachable,
                },
                .peeled = if (record.value == .peeled) record.value.peeled.target else null,
                .loose = false,
            });
        }
    }
    std.mem.sort(refs.Named, entries.items, {}, lessThanNamed);
    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = entries.items };
}

fn lessThanNamed(_: void, a: refs.Named, b: refs.Named) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// `Store.readLog` over reftable: the entries oldest first, as the files
/// backend's log is. An entry whose old and new names are both zero is the
/// marker git writes to say a log exists, and is not an entry.
pub fn readLog(store: *const refs.Store, gpa: Allocator, io: Io, name: []const u8) (refs.ReadError || reflog.ReadError)!reflog.Log {
    var owned: ?Stacks = null;
    var view = try View.acquire(store, gpa, io, &owned);
    defer view.release(io, &owned);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const records = try view.stacks.forName(store, name).logsFor(gpa, arena_instance.allocator(), name);

    var total: usize = 0;
    var count: usize = 0;
    for (records) |r| {
        const u = r.value.update;
        if (u.old.isZero() and u.new.isZero()) continue;
        total += u.name.len + u.email.len + u.message.len;
        count += 1;
    }
    const bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(bytes);
    const entries = try gpa.alloc(reflog.Entry, count);
    errdefer gpa.free(entries);

    var at: usize = 0;
    var n: usize = 0;
    var i = records.len;
    while (i > 0) {
        i -= 1;
        const u = records[i].value.update;
        if (u.old.isZero() and u.new.isZero()) continue;
        const name_text = put(bytes, &at, u.name);
        const email_text = put(bytes, &at, u.email);
        var message = put(bytes, &at, u.message);
        if (message.len > 0 and message[message.len - 1] == '\n') message = message[0 .. message.len - 1];
        entries[n] = .{
            .old = u.old,
            .new = u.new,
            .who = .{
                .name = name_text,
                .email = email_text,
                .when_secs = std.math.cast(i64, u.time) orelse std.math.maxInt(i64),
                .offset_minutes = minutesFromZone(u.tz_offset),
            },
            .message = message,
        };
        n += 1;
    }
    return .{ .gpa = gpa, .bytes = bytes, .entries = entries };
}

fn put(bytes: []u8, at: *usize, text: []const u8) []const u8 {
    @memcpy(bytes[at.*..][0..text.len], text);
    const out = bytes[at.*..][0..text.len];
    at.* += text.len;
    return out;
}

/// Whether a log for `name` exists: any entry at all, the existence marker
/// included.
pub fn logExists(store: *const refs.Store, gpa: Allocator, io: Io, name: []const u8) refs.ReadError!bool {
    var owned: ?Stacks = null;
    var view = try View.acquire(store, gpa, io, &owned);
    defer view.release(io, &owned);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const records = try view.stacks.forName(store, name).logsFor(gpa, arena_instance.allocator(), name);
    return records.len != 0;
}

/// git's zone number -- `+0130` read as 130 -- as minutes east of UTC.
pub fn minutesFromZone(zone: i16) i16 {
    const magnitude: i32 = @intCast(@abs(@as(i32, zone)));
    const minutes: i32 = @divTrunc(magnitude, 100) * 60 + @mod(magnitude, 100);
    const signed = if (zone < 0) -minutes else minutes;
    return std.math.cast(i16, signed) orelse 0;
}

/// Minutes east of UTC as git's zone number.
pub fn zoneFromMinutes(minutes: i16) i16 {
    const magnitude: i32 = @intCast(@abs(@as(i32, minutes)));
    const zone: i32 = @divTrunc(magnitude, 60) * 100 + @mod(magnitude, 60);
    return std.math.cast(i16, if (minutes < 0) -zone else zone) orelse 0;
}

//=========================================================================
// Transactions
//=========================================================================

/// What a prepared transaction holds: the lock on each stack it writes, and
/// the stacks as they were read under it.
pub const Pending = struct {
    main: Locked,
    worktree: ?Locked = null,
    /// Both stacks, read under the locks, for lookups.
    stacks: Stacks,

    const Locked = struct {
        dir: Io.Dir,
        lock: fs.LockFile,
        buffer: []u8,
        written: bool = false,
    };

    fn release(p: *Pending, gpa: Allocator, io: Io) void {
        for ([_]?*Locked{ &p.main, if (p.worktree) |*w| w else null }) |maybe| {
            const l = maybe orelse continue;
            if (!l.written) l.lock.deinit(io);
            gpa.free(l.buffer);
            l.dir.close(io);
        }
        p.stacks.deinit();
    }
};

fn lockStack(gpa: Allocator, io: Io, parent: Io.Dir) refs.TransactionError!Pending.Locked {
    parent.createDirPath(io, "reftable") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    var dir = try parent.openDir(io, "reftable", .{});
    errdefer dir.close(io);
    const buffer = try gpa.alloc(u8, 4096);
    errdefer gpa.free(buffer);
    const lock = try fs.LockFile.open(gpa, io, dir, "tables.list", buffer, .{});
    return .{ .dir = dir, .lock = lock, .buffer = buffer };
}

/// `Transaction.prepare` over reftable: take `tables.list.lock` on every
/// stack the edits touch, read the stacks under it, and check every
/// expected value and every name against the refs already there.
pub fn prepare(tx: *refs.Transaction, io: Io) refs.TransactionError!void {
    const store = tx.store;
    const gpa = tx.gpa;
    var needs_worktree = false;
    for (tx.edits.items) |edit| {
        if (isSpecial(edit.name)) return error.InvalidRefName;
        if (isLinked(store) and isPerWorktree(store, edit.name)) needs_worktree = true;
    }

    var main = try lockStack(gpa, io, store.common_dir);
    errdefer {
        main.lock.deinit(io);
        gpa.free(main.buffer);
        main.dir.close(io);
    }
    var worktree: ?Pending.Locked = if (needs_worktree) try lockStack(gpa, io, store.git_dir) else null;
    errdefer if (worktree) |*w| {
        w.lock.deinit(io);
        gpa.free(w.buffer);
        w.dir.close(io);
    };
    var stacks = try Stacks.open(store, gpa, io);
    errdefer stacks.deinit();

    for (tx.edits.items) |*edit| {
        // A ref only logged through is neither read nor checked.
        if (edit.via != null) continue;
        const current = try readIn(&stacks, store, gpa, edit.name);
        var current_oid: ?Oid = null;
        if (current) |value| switch (value) {
            .direct => |oid| current_oid = oid,
            .symbolic => |target| {
                gpa.free(target);
                current_oid = try resolveIn(&stacks, store, gpa, edit.name, null);
            },
        };
        edit.old = current_oid;
        switch (edit.expected) {
            .any => {},
            .must_not_exist => if (current != null) return error.RefAlreadyExists,
            .must_exist => if (current == null) return error.RefNotFound,
            .matches => |want| {
                const have = current_oid orelse return error.ExpectedValueMismatch;
                if (!have.eql(want)) return error.ExpectedValueMismatch;
            },
        }
    }
    try checkNames(tx, &stacks);

    const pending = try gpa.create(Pending);
    pending.* = .{ .main = main, .worktree = worktree, .stacks = stacks };
    tx.reftable = pending;
}

/// A name and a directory of names cannot both exist: `refs/heads/a` and
/// `refs/heads/a/b`. git checks that against the refs already there, and
/// so does this, leaving out the ones the transaction deletes.
fn checkNames(tx: *refs.Transaction, stacks: *const Stacks) refs.TransactionError!void {
    const gpa = tx.gpa;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    for (tx.edits.items) |edit| {
        if (edit.new == null or edit.via != null) continue;
        const stack = stacks.forName(tx.store, edit.name);
        // A ref where a directory of this one would be.
        var end = edit.name.len;
        while (std.mem.lastIndexOfScalar(u8, edit.name[0..end], '/')) |slash| {
            end = slash;
            const ancestor = edit.name[0..end];
            if (deletedHere(tx, ancestor)) continue;
            const record = (try stack.lookup(gpa, arena, ancestor)) orelse continue;
            if (record.value != .deletion) return error.RefNameConflict;
        }
        // Refs where this one's directory would be.
        const below = try std.fmt.allocPrint(arena, "{s}/", .{edit.name});
        for (try stack.refsWithPrefix(gpa, arena, below, false)) |record| {
            if (!deletedHere(tx, record.name)) return error.RefNameConflict;
        }
    }
}

fn deletedHere(tx: *const refs.Transaction, name: []const u8) bool {
    for (tx.edits.items) |edit| {
        if (edit.via == null and edit.new == null and std.mem.eql(u8, edit.name, name)) return true;
    }
    return false;
}

/// `Transaction.commit` over reftable: one table per stack the edits touch,
/// installed by rewriting `tables.list` under the lock `prepare` took, then
/// the stack compacted if the geometric rule asks for it.
pub fn commit(tx: *refs.Transaction, io: Io, log: ?refs.LogMessage) refs.TransactionError!void {
    const pending = tx.reftable.?;
    const store = tx.store;
    try addTable(tx, io, pending, &pending.main, &pending.stacks.main, false, log);
    if (pending.worktree) |*w| try addTable(tx, io, pending, w, &pending.stacks.worktree.?, true, log);

    const options = store.reftable_options;
    const compact_worktree = pending.worktree != null;
    releasePending(tx, io);
    if (!options.auto_compact) return;
    compactIn(tx.gpa, io, store.common_dir, store.kind, options, .auto) catch |err| switch (err) {
        // Compaction is housekeeping: someone else holding a lock, or
        // compacting already, is not a failure of this transaction.
        error.LockHeld => {},
        else => |e| return e,
    };
    if (compact_worktree) {
        compactIn(tx.gpa, io, store.git_dir, store.kind, options, .auto) catch |err| switch (err) {
            error.LockHeld => {},
            else => |e| return e,
        };
    }
}

/// Give up whatever `prepare` took.
pub fn releasePending(tx: *refs.Transaction, io: Io) void {
    const pending = tx.reftable orelse return;
    pending.release(tx.gpa, io);
    tx.gpa.destroy(pending);
    tx.reftable = null;
}

fn addTable(
    tx: *refs.Transaction,
    io: Io,
    pending: *Pending,
    locked: *Pending.Locked,
    stack: *const Stack,
    worktree_stack: bool,
    log: ?refs.LogMessage,
) refs.TransactionError!void {
    const store = tx.store;
    const gpa = tx.gpa;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const update_index = stack.maxUpdateIndex() + 1;

    var records: std.ArrayList(reftable.RefRecord) = .empty;
    var logs: std.ArrayList(reftable.LogRecord) = .empty;
    const text: ?[]const u8 = if (log) |message| blk: {
        const normal = try reflog.normalizeMessage(arena, message.message);
        break :blk try logMessage(arena, normal, store.reftable_options.write.block_size);
    } else null;
    for (tx.edits.items) |edit| {
        if (isLinked(store) and isPerWorktree(store, edit.name) != worktree_stack) continue;
        // A ref an update went through, or `HEAD` when the branch it names
        // moved, keeps its value and gains the log line: git's
        // `REF_LOG_ONLY`.
        const source = if (edit.via) |at| tx.edits.items[at] else edit;
        if (edit.via == null) {
            const value: reftable.RefValue = if (edit.new) |new| switch (new) {
                .direct => |oid| if (tx.peeler) |p| (if (p.peel(p.context, io, oid)) |target|
                    .{ .peeled = .{ .value = oid, .target = target } }
                else
                    .{ .direct = oid }) else .{ .direct = oid },
                .symbolic => |target| .{ .symbolic = target },
            } else .deletion;
            try records.append(arena, .{ .name = edit.name, .update_index = update_index, .value = value });
        }

        const message = log orelse continue;
        if (edit.via == null and edit.new == null) {
            // A deleted ref's log goes with it, as it does in git: one
            // tombstone for each entry it had.
            for (try stack.logsFor(gpa, arena, edit.name)) |entry| {
                try logs.append(arena, .{ .name = edit.name, .update_index = entry.update_index, .value = .deletion });
            }
            continue;
        }
        const exists = (try stack.logsFor(gpa, arena, edit.name)).len != 0;
        if (!reflog.shouldLog(message.policy, edit.name, exists)) continue;
        const new_oid = if (source.new) |new| switch (new) {
            .direct => |oid| oid,
            // git writes no entry for a symbolic ref whose target does not
            // resolve yet.
            .symbolic => (try resolveIn(&pending.stacks, store, gpa, source.name, tx)) orelse continue,
        } else Oid.zero(store.kind);
        if (std.mem.indexOfAny(u8, message.who.name, "<>\n") != null or
            std.mem.indexOfAny(u8, message.who.email, "<>\n") != null) return error.InvalidSignature;
        try logs.append(arena, .{
            .name = edit.name,
            .update_index = update_index,
            .value = .{ .update = .{
                .old = source.old orelse Oid.zero(store.kind),
                .new = new_oid,
                .name = message.who.name,
                .email = message.who.email,
                .time = std.math.cast(u64, message.who.when_secs) orelse 0,
                .tz_offset = zoneFromMinutes(message.who.offset_minutes),
                .message = text.?,
            } },
        });
    }
    if (records.items.len == 0 and logs.items.len == 0) return;
    std.mem.sort(reftable.RefRecord, records.items, {}, lessThanRef);
    std.mem.sort(reftable.LogRecord, logs.items, {}, logOrder);

    const bytes = try reftable.write(gpa, store.kind, store.reftable_options.write, update_index, update_index, records.items, logs.items);
    defer gpa.free(bytes);
    var name_buf: [64]u8 = undefined;
    const name = tableName(&name_buf, io, update_index, update_index);
    try writeTable(gpa, io, locked.dir, name, bytes);

    const w = locked.lock.writer();
    w.writeAll(stack.list) catch return error.WriteFailed;
    if (stack.list.len != 0 and stack.list[stack.list.len - 1] != '\n') w.writeByte('\n') catch return error.WriteFailed;
    w.print("{s}\n", .{name}) catch return error.WriteFailed;
    try locked.lock.commit(io);
    locked.lock.deinit(io);
    locked.written = true;
}

/// A reflog message as git's reftable writer keeps it: on one line, no
/// longer than half a block, ending with a newline.
fn logMessage(arena: Allocator, text: []const u8, block_size: u32) Allocator.Error![]const u8 {
    const limit = block_size / 2;
    const kept = text[0..@min(text.len, limit)];
    const out = try arena.alloc(u8, kept.len + 1);
    for (kept, 0..) |c, i| out[i] = if (c == '\n' or c == '\r') ' ' else c;
    var end = kept.len;
    while (end > 0 and out[end - 1] == ' ' and (kept[end - 1] == '\n' or kept[end - 1] == '\r')) end -= 1;
    out[end] = '\n';
    return out[0 .. end + 1];
}

/// Write a new table under its final name, through `<name>.lock`, so no
/// reader sees half of it.
fn writeTable(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) refs.TransactionError!void {
    var buffer: [16 * 1024]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, dir, name, &buffer, .{});
    defer lock.deinit(io);
    lock.writer().writeAll(bytes) catch return error.WriteFailed;
    try lock.commit(io);
}

//=========================================================================
// Compaction
//=========================================================================

/// Which tables a compaction merges.
pub const Compaction = enum {
    /// Whatever git's geometric rule says, which may be nothing.
    auto,
    /// Every table into one, which is what `git pack-refs` does.
    all,
};

/// Compact the stack in `parent`'s `reftable` directory.
///
/// The stack's lock is held throughout, and each table being merged is
/// locked as git locks it, by `<table>.lock`; a table another process has
/// locked -- a git compacting it already -- ends the run there, and only
/// the newer tables past it are merged, as git's best-effort rule does.
pub fn compactIn(gpa: Allocator, io: Io, parent: Io.Dir, kind: Kind, options: Options, which: Compaction) refs.TransactionError!void {
    var dir = parent.openDir(io, "reftable", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    var buffer: [4096]u8 = undefined;
    var list_lock = try fs.LockFile.open(gpa, io, dir, "tables.list", &buffer, .{});
    defer list_lock.deinit(io);
    var stack = try Stack.load(gpa, io, dir, kind);
    defer stack.deinit();
    if (stack.tables.len < 2) return;

    var first: usize = 0;
    var last: usize = stack.tables.len - 1;
    if (which == .auto) {
        const segment = (try suggestSegment(&stack, options.geometric_factor)) orelse return;
        first = segment.start;
        last = segment.end - 1;
    }

    // Lock from the newest back, and stop at the first one held.
    var locked: usize = 0;
    var held: std.ArrayList([]u8) = .empty;
    defer {
        for (held.items) |lock_name| {
            dir.deleteFile(io, lock_name) catch {};
            gpa.free(lock_name);
        }
        held.deinit(gpa);
    }
    var i = last + 1;
    while (i > first) : (i -= 1) {
        const lock_name = try std.fmt.allocPrint(gpa, "{s}.lock", .{stack.names[i - 1]});
        if (dir.createFile(io, lock_name, .{ .exclusive = true })) |file| {
            file.close(io);
            held.append(gpa, lock_name) catch |err| {
                dir.deleteFile(io, lock_name) catch {};
                gpa.free(lock_name);
                return err;
            };
            locked += 1;
        } else |err| {
            gpa.free(lock_name);
            switch (err) {
                error.PathAlreadyExists => {
                    if (locked >= 2) {
                        first = i;
                        break;
                    }
                    return error.LockHeld;
                },
                else => |e| return e,
            }
        }
    }
    // One table merged with nothing is the same table.
    if (last == first) return;

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const tables = stack.tables[first .. last + 1];
    const drop_deletions = first == 0;

    const merged_refs = try mergedRefs(gpa, arena, tables, "", !drop_deletions);
    const merged_logs = try allLogs(gpa, arena, tables, drop_deletions);

    var new_name: ?[]const u8 = null;
    var name_buf: [64]u8 = undefined;
    if (merged_refs.len != 0 or merged_logs.len != 0) {
        const min = tables[0].min_update_index;
        const max = tables[tables.len - 1].max_update_index;
        const bytes = try reftable.write(gpa, kind, options.write, min, max, merged_refs, merged_logs);
        defer gpa.free(bytes);
        const name = tableName(&name_buf, io, min, max);
        try writeTable(gpa, io, dir, name, bytes);
        new_name = name;
    }

    const w = list_lock.writer();
    for (stack.names[0..first]) |name| w.print("{s}\n", .{name}) catch return error.WriteFailed;
    if (new_name) |name| w.print("{s}\n", .{name}) catch return error.WriteFailed;
    for (stack.names[last + 1 ..]) |name| w.print("{s}\n", .{name}) catch return error.WriteFailed;
    try list_lock.commit(io);

    // The old tables are out of the list; a reader that read the list
    // before the rename may still be opening one, and goes back to the list
    // when it finds it gone. A platform that will not remove a file another
    // process has open leaves it for the next compaction to find.
    stack.closeUnclaimed(&.{});
    for (stack.names[first .. last + 1]) |name| dir.deleteFile(io, name) catch {};
}

const Segment = struct { start: usize, end: usize };

/// The sizes git's rule compares: each table without its footer and
/// without all but one byte of its header.
fn suggestSegment(stack: *const Stack, factor: u8) Allocator.Error!?Segment {
    const version = reftable.versionFor(stack.kind);
    const overhead = reftable.headerSize(version) - 1;
    const sizes = try stack.gpa.alloc(u64, stack.tables.len);
    defer stack.gpa.free(sizes);
    for (stack.tables, sizes) |t, *size| size.* = @as(u64, t.size) -| overhead;
    return suggest(sizes, factor);
}

/// git's `suggest_compaction_segment`: the run of tables, oldest first, to
/// merge so that each is at least `factor` times the size of everything
/// newer, or `null` when they already are.
///
/// Walking back from the newest, the segment ends at the first table that
/// is larger than a `factor`th of the one before it; walking on, it starts
/// at the oldest table that is not `factor` times what has been gathered
/// since the end, which catches a violation further back as well.
fn suggest(sizes: []const u64, factor_in: u8) ?Segment {
    const n = sizes.len;
    if (n <= 1) return null;
    const factor: u64 = if (factor_in == 0) 2 else factor_in;
    var end: usize = 0;
    var bytes: u64 = 0;
    var i = n - 1;
    while (i > 0) : (i -= 1) {
        if (sizes[i - 1] < sizes[i] *| factor) {
            end = i + 1;
            bytes = sizes[i];
            break;
        }
    }
    if (end == 0) return null;
    var start: ?usize = null;
    while (i > 0) : (i -= 1) {
        const current = bytes;
        bytes +|= sizes[i - 1];
        if (sizes[i - 1] < current *| factor) start = i - 1;
    }
    const first = start orelse return null;
    return .{ .start = first, .end = end };
}

//=========================================================================
// A new repository
//=========================================================================

/// Lay down what `git init --ref-format=reftable` lays down in `git_dir`:
/// a stack whose one table holds `HEAD` -- a symbolic ref to the unborn
/// branch in a new repository, or whatever a new linked worktree starts
/// on -- a `HEAD` file naming a branch no one can create, so that a reader
/// of the files format stops rather than misreads, and `refs/heads` as a
/// file saying why. `orig_head`, when given, is written beside `HEAD`.
pub fn initialize(gpa: Allocator, io: Io, git_dir: Io.Dir, kind: Kind, head: refs.Ref, orig_head: ?Oid, options: Options) refs.TransactionError!void {
    git_dir.createDirPath(io, "reftable") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    var dir = try git_dir.openDir(io, "reftable", .{});
    defer dir.close(io);
    var records: [2]reftable.RefRecord = undefined;
    records[0] = .{ .name = "HEAD", .update_index = 1, .value = switch (head) {
        .direct => |oid| .{ .direct = oid },
        .symbolic => |target| .{ .symbolic = target },
    } };
    var n: usize = 1;
    if (orig_head) |oid| {
        records[1] = .{ .name = "ORIG_HEAD", .update_index = 1, .value = .{ .direct = oid } };
        n = 2;
    }
    const bytes = try reftable.write(gpa, kind, options.write, 1, 1, records[0..n], &.{});
    defer gpa.free(bytes);
    var name_buf: [64]u8 = undefined;
    const name = tableName(&name_buf, io, 1, 1);
    try writeTable(gpa, io, dir, name, bytes);
    var list_buf: [96]u8 = undefined;
    const list_text = std.fmt.bufPrint(&list_buf, "{s}\n", .{name}) catch unreachable;
    try dir.writeFile(io, .{ .sub_path = "tables.list", .data = list_text });

    try git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/.invalid\n" });
    git_dir.createDirPath(io, "refs") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    try git_dir.writeFile(io, .{ .sub_path = "refs/heads", .data = "this repository uses the reftable format\n" });
}

/// What `HEAD` holds in the stack under `git_dir`, or `null` when there is
/// no stack there -- the files format -- or no `HEAD` in it. A symbolic
/// target is in `arena`.
pub fn headIn(gpa: Allocator, arena: Allocator, io: Io, git_dir: Io.Dir, kind: Kind) Error!?refs.Ref {
    var dir = git_dir.openDir(io, "reftable", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    defer dir.close(io);
    var stack = try Stack.load(gpa, io, dir, kind);
    defer stack.deinit();
    const record = (try stack.lookup(gpa, arena, "HEAD")) orelse return null;
    return switch (record.value) {
        .deletion => null,
        .direct => |oid| .{ .direct = oid },
        .peeled => |p| .{ .direct = p.value },
        .symbolic => |target| .{ .symbolic = target },
    };
}

/// Whether the repository whose shared directory is `common_dir` keeps its
/// refs in a reftable stack.
pub fn isReftableRepository(io: Io, common_dir: Io.Dir) bool {
    common_dir.access(io, "reftable/tables.list", .{}) catch return false;
    return true;
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("testgit.zig");
const repo_mod = @import("repo.zig");

test "the geometric rule merges what git's merges" {
    // git's own examples from its source.
    try std.testing.expect(suggest(&.{ 64, 32, 16, 8, 4, 2, 1 }, 2) == null);
    // The segment ends before the newest table, and gathering back from
    // there each older table is smaller than twice what came after it, so
    // it reaches the oldest.
    const tail = suggest(&.{ 64, 32, 16, 8, 4, 3, 1 }, 2).?;
    try std.testing.expectEqual(@as(usize, 0), tail.start);
    try std.testing.expectEqual(@as(usize, 6), tail.end);
    const deep = suggest(&.{ 128, 32, 16, 8, 4, 3, 1 }, 2).?;
    try std.testing.expectEqual(@as(usize, 1), deep.start);
    try std.testing.expectEqual(@as(usize, 6), deep.end);
    try std.testing.expect(suggest(&.{5}, 2) == null);
    const pair = suggest(&.{ 10, 10 }, 2).?;
    try std.testing.expectEqual(@as(usize, 0), pair.start);
    try std.testing.expectEqual(@as(usize, 2), pair.end);
}

test "a zone is git's hhmm number both ways" {
    try std.testing.expectEqual(@as(i16, 130), zoneFromMinutes(90));
    try std.testing.expectEqual(@as(i16, -500), zoneFromMinutes(-300));
    try std.testing.expectEqual(@as(i16, 90), minutesFromZone(130));
    try std.testing.expectEqual(@as(i16, -300), minutesFromZone(-500));
    try std.testing.expectEqual(@as(i16, 0), minutesFromZone(0));
}

fn requireReftableGit(gpa: Allocator, io: Io) !void {
    // `--ref-format=reftable` arrived in 2.45.
    try testgit.requireGitVersion(gpa, io, 2, 45);
}

fn who(when: i64) object.Signature {
    return .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = when, .offset_minutes = 90 };
}

/// `git for-each-ref` as text, from a listing.
fn forEachRef(gpa: Allocator, listing: *const refs.Store.Listing) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    for (listing.entries) |entry| {
        switch (entry.target) {
            .direct => |oid| try out.print(gpa, "{s} {s}\n", .{ entry.name, oid.hex(&hex) }),
            .symbolic => |target| try out.print(gpa, "{s} -> {s}\n", .{ entry.name, target }),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn gitForEachRef(repo: *testgit.Repo, io: Io) ![]u8 {
    return repo.run(io, &.{ "for-each-ref", "--format=%(refname)%(if)%(symref)%(then) -> %(symref)%(else) %(objectname)%(end)" });
}

/// `git log -g` as text, from a log: newest first, the new name and the
/// message.
fn reflogText(gpa: Allocator, log: *const reflog.Log) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    var i = log.entries.len;
    while (i > 0) {
        i -= 1;
        const e = log.entries[i];
        try out.print(gpa, "{s}\t{s}\n", .{ e.new.hex(&hex), e.message });
    }
    return out.toOwnedSlice(gpa);
}

fn gitReflog(repo: *testgit.Repo, io: Io, name: []const u8) ![]u8 {
    return repo.run(io, &.{ "log", "-g", "--format=%H%x09%gs", name, "--" });
}

test "a reftable repository git made is read through the refs API" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "branch", "topic" });
    try git.writeFile(io, "a.txt", "b\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    try git.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1" });
    try git.exec(io, &.{ "tag", "light" });
    try git.exec(io, &.{ "branch", "gone" });
    try git.exec(io, &.{ "branch", "-D", "gone" });
    try git.exec(io, &.{ "symbolic-ref", "refs/heads/alias", "refs/heads/main" });
    try git.exec(io, &.{ "checkout", "-q", "topic" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectEqual(refs.Format.reftable, repo.refs.format);

    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    try std.testing.expectEqualStrings("refs/heads/topic", head.name);
    const branch = (try repo.refs.currentBranch(gpa, io)).?;
    defer gpa.free(branch);
    try std.testing.expectEqualStrings("topic", branch);
    try std.testing.expect(try repo.refs.read(gpa, io, "refs/heads/gone") == null);

    var listing = try repo.refs.list(gpa, io, "refs/");
    defer listing.deinit();
    const ours = try forEachRef(gpa, &listing);
    defer gpa.free(ours);
    const theirs = try gitForEachRef(&git, io);
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours);
    // git records the annotated tag's target beside it.
    try std.testing.expect(listing.find("refs/tags/v1").?.peeled != null);

    for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/topic" }) |name| {
        var log = try repo.readLog(io, name);
        defer log.deinit();
        const text = try reflogText(gpa, &log);
        defer gpa.free(text);
        const expected = try gitReflog(&git, io, name);
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, text);
        try std.testing.expect(log.entries.len > 0);
    }
}

test "what this writes into a reftable repository git reads, logs and all" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .default_branch = "main", .ref_format = .reftable });
    defer repo.deinit(io);

    const tree = try repo.odb.write(io, .tree, "");
    var commits: [12]Oid = undefined;
    var parent: ?Oid = null;
    for (&commits, 0..) |*c, i| {
        c.* = try repo.writeCommit(io, .{
            .tree = tree,
            .parents = if (parent) |p| &.{p} else &.{},
            .author = who(1_700_000_000 + @as(i64, @intCast(i))),
            .committer = who(1_700_000_000 + @as(i64, @intCast(i))),
            .message = "a commit\n",
        });
        parent = c.*;
    }
    const tag = try repo.writeTag(io, .{
        .target = commits[3],
        .target_type = .commit,
        .name = "v1",
        .tagger = who(1_700_000_100),
        .message = "a tag\n",
    });

    // One transaction per commit, each moving main and HEAD's log with it,
    // and the geometric rule compacting as they pile up.
    for (commits, 0..) |c, i| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.update("refs/heads/main", .{ .direct = c }, if (i == 0) .must_not_exist else .{ .matches = commits[i - 1] });
        try tx.update("HEAD", .{ .symbolic = "refs/heads/main" }, .any);
        try tx.commit(io, .{ .who = who(1_700_000_000 + @as(i64, @intCast(i))), .message = "commit: a commit" });
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/tags/v1", .{ .direct = tag });
        try tx.create("refs/heads/topic", .{ .direct = commits[5] });
        try tx.create("refs/heads/doomed", .{ .direct = commits[6] });
        try tx.create("refs/heads/link", .{ .symbolic = "refs/heads/topic" });
        try tx.commit(io, .{ .who = who(1_700_000_200), .message = "branch: made" });
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.delete("refs/heads/doomed", .must_exist);
        try tx.commit(io, .{ .who = who(1_700_000_300), .message = "branch: deleted" });
    }

    // Compaction kept the stack short.
    {
        var dir = try repo.git_dir.openDir(io, "reftable", .{});
        defer dir.close(io);
        var stack = try Stack.load(gpa, io, dir, .sha1);
        defer stack.deinit();
        try std.testing.expect(stack.tables.len < 6);
        for (stack.tables) |*t| try t.verify(gpa);
    }

    var git: testgit.Repo = .{ .gpa = gpa, .tmp = undefined, .dir = tmp.dir };
    try git.exec(io, &.{ "fsck", "--no-progress" });
    try refsVerify(&git, io, &.{});
    const shown = try git.run(io, &.{ "show-ref", "--head", "-d" });
    defer gpa.free(shown);
    var hex: [hash.max_hex_len]u8 = undefined;
    var tag_hex: [hash.max_hex_len]u8 = undefined;
    var peel_hex: [hash.max_hex_len]u8 = undefined;
    var topic_hex: [hash.max_hex_len]u8 = undefined;
    const want = try std.fmt.allocPrint(gpa, "{s} HEAD\n{s} refs/heads/link\n{s} refs/heads/main\n{s} refs/heads/topic\n{s} refs/tags/v1\n{s} refs/tags/v1^{{}}\n", .{
        commits[11].hex(&hex),
        commits[5].hex(&topic_hex),
        commits[11].hex(&hex),
        commits[5].hex(&topic_hex),
        tag.hex(&tag_hex),
        commits[3].hex(&peel_hex),
    });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, shown);

    var log = try repo.readLog(io, "refs/heads/main");
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 12), log.entries.len);
    const ours = try reflogText(gpa, &log);
    defer gpa.free(ours);
    const theirs = try gitReflog(&git, io, "refs/heads/main");
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours);
    const head_log = try gitReflog(&git, io, "HEAD");
    defer gpa.free(head_log);
    try std.testing.expectEqual(@as(usize, 12), std.mem.count(u8, head_log, "\n"));
    // The deleted branch's log went with it.
    var doomed = try repo.readLog(io, "refs/heads/doomed");
    defer doomed.deinit();
    try std.testing.expectEqual(@as(usize, 0), doomed.entries.len);

    // And git's own next write lands on the stack this left.
    try git.exec(io, &.{ "branch", "after", "main" });
    try git.exec(io, &.{"pack-refs"});
    const after = (try repo.refs.read(gpa, io, "refs/heads/after")).?;
    try std.testing.expect(after.direct.eql(commits[11]));
}

test "a table written for a transaction is the table git writes for it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var twins: [2]testgit.Repo = undefined;
    var made: usize = 0;
    defer for (twins[0..made]) |*t| t.deinit();
    var blob_text: []u8 = &.{};
    defer gpa.free(blob_text);
    var tag_text: []u8 = &.{};
    defer gpa.free(tag_text);
    for (&twins) |*t| {
        t.* = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
        made += 1;
        // Objects written the same way in both, so both have the same names:
        // a blob, and an annotated tag of it with a fixed date.
        try t.writeFile(io, "blob.txt", "the same blob\n");
        gpa.free(blob_text);
        blob_text = try t.line(io, &.{ "hash-object", "-w", "blob.txt" });
        const tag_body = try std.fmt.allocPrint(gpa, "object {s}\ntype blob\ntag v1\ntagger Fixture <fixture@example.com> 1700000000 +0000\n\nannotated\n", .{blob_text});
        defer gpa.free(tag_body);
        try t.writeFile(io, "tag.txt", tag_body);
        gpa.free(tag_text);
        tag_text = try t.line(io, &.{ "hash-object", "-t", "tag", "-w", "tag.txt" });

        // A large base, written and compacted by git in both, so that the
        // table under test is small beside it and nothing compacts it away.
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(gpa);
        for (0..1500) |i| try base.print(gpa, "create refs/base/b{d:0>4} {s}\n", .{ i, blob_text });
        try runWithInput(t, io, &.{ "update-ref", "--stdin" }, base.items);
    }

    // git: tags in one transaction, some of them the annotated one, and a
    // symbolic ref. Tags get no log under the default policy.
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    for (0..120) |i| try script.print(gpa, "create refs/tags/t{d:0>3} {s}\n", .{ i, if (i % 7 == 0) tag_text else blob_text });
    try script.print(gpa, "symref-create refs/tags/zz-link refs/heads/main\n", .{});
    try runWithInput(&twins[0], io, &.{ "update-ref", "--stdin" }, script.items);

    var repo = try repo_mod.Repository.open(gpa, io, twins[1].dir, .{});
    defer repo.deinit(io);
    {
        const blob_oid = try Oid.parse(.sha1, blob_text);
        const tag_oid = try Oid.parse(.sha1, tag_text);
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        var names: [120][16]u8 = undefined;
        for (0..120) |i| {
            const name = try std.fmt.bufPrint(&names[i], "refs/tags/t{d:0>3}", .{i});
            try tx.create(name, .{ .direct = if (i % 7 == 0) tag_oid else blob_oid });
        }
        try tx.create("refs/tags/zz-link", .{ .symbolic = "refs/heads/main" });
        try tx.commit(io, .{ .who = who(1_700_000_000), .message = "bulk" });
    }

    var lists: [2][]u8 = undefined;
    var newest: [2][]u8 = undefined;
    for (&twins, 0..) |*t, i| {
        lists[i] = try t.readFile(io, ".git/reftable/tables.list");
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, lists[i], "\n"), '\n');
        var last: []const u8 = "";
        while (lines.next()) |line| last = line;
        var path_buf: [128]u8 = undefined;
        newest[i] = try t.readFile(io, try std.fmt.bufPrint(&path_buf, ".git/reftable/{s}", .{last}));
    }
    defer for (lists) |bytes| gpa.free(bytes);
    defer for (newest) |bytes| gpa.free(bytes);
    // The same stack shape on both sides: nothing compacted the new table.
    try std.testing.expectEqual(std.mem.count(u8, lists[0], "\n"), std.mem.count(u8, lists[1], "\n"));
    try std.testing.expect(std.mem.count(u8, lists[1], "\n") >= 2);
    try std.testing.expectEqualSlices(u8, newest[0], newest[1]);

    const a = try gitForEachRef(&twins[0], io);
    defer gpa.free(a);
    const b = try gitForEachRef(&twins[1], io);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "a held tables.list.lock refuses the transaction and changes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
    defer repo.deinit(io);
    const before = try tmp.dir.readFileAlloc(io, ".git/reftable/tables.list", gpa, .limited(4096));
    defer gpa.free(before);

    const blocker = try tmp.dir.createFile(io, ".git/reftable/tables.list.lock", .{ .exclusive = true });
    blocker.close(io);
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/main", .{ .direct = Oid.zero(.sha1) });
        try std.testing.expectError(error.LockHeld, tx.commit(io, null));
    }
    try tmp.dir.access(io, ".git/reftable/tables.list.lock", .{});
    const after = try tmp.dir.readFileAlloc(io, ".git/reftable/tables.list", gpa, .limited(4096));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(try repo.refs.read(gpa, io, "refs/heads/main") == null);
}

test "a name and a directory of names conflict with what is already there" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
    defer repo.deinit(io);
    const one = try Oid.parse(.sha1, "1" ** 40);
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/a", .{ .direct = one });
        try tx.commit(io, null);
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/a/b", .{ .direct = one });
        try std.testing.expectError(error.RefNameConflict, tx.commit(io, null));
    }
    {
        // Deleting the one in the way in the same transaction is allowed.
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.delete("refs/heads/a", .must_exist);
        try tx.create("refs/heads/a-b", .{ .direct = one });
        try tx.commit(io, null);
    }
    try std.testing.expect(try repo.refs.read(gpa, io, "refs/heads/a") == null);
    try std.testing.expectError(error.InvalidRefName, blk: {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("FETCH_HEAD", .{ .direct = one });
        break :blk tx.commit(io, null);
    });
}

test "git waits on the lock a prepared transaction holds, and reads the result" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tip_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(tip_text);
    const tip = try Oid.parse(.sha1, tip_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.create("refs/heads/ours", .{ .direct = tip });
    try tx.prepare(io);

    // git gives up on `tables.list.lock` after its timeout rather than
    // break it, and writes nothing.
    git.report_failures = false;
    try std.testing.expectError(error.GitFailed, git.exec(io, &.{ "-c", "reftable.lockTimeout=0", "branch", "theirs" }));
    git.report_failures = true;

    try tx.commit(io, .{ .who = who(1_700_000_000), .message = "branch: Created" });
    try git.exec(io, &.{ "branch", "theirs" });
    const ours = try git.line(io, &.{ "rev-parse", "refs/heads/ours" });
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(tip_text, ours);
    try std.testing.expect(try repo.refs.read(gpa, io, "refs/heads/theirs") != null);
}

test "a repository's stack is kept between reads and read again only when it changes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const cache = repo.refs.reftable_cache.?;
    for (0..50) |_| {
        const head = (try repo.head(io)).?;
        gpa.free(head.name);
    }
    try std.testing.expectEqual(@as(u64, 0), cache.reloads);

    // git adds a table, then compacts the stack away under the reader: the
    // next read sees both.
    try git.exec(io, &.{ "branch", "later" });
    try std.testing.expect(try repo.refs.read(gpa, io, "refs/heads/later") != null);
    try std.testing.expectEqual(@as(u64, 1), cache.reloads);
    try git.exec(io, &.{ "branch", "-D", "later" });
    try git.exec(io, &.{"pack-refs"});
    try std.testing.expect(try repo.refs.read(gpa, io, "refs/heads/later") == null);
    const main = (try repo.refs.read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(main == .direct);
    try std.testing.expect(cache.reloads >= 2);
    const settled = cache.reloads;
    var listing = try repo.refs.list(gpa, io, "refs/");
    defer listing.deinit();
    try std.testing.expectEqual(settled, cache.reloads);
}

/// `git refs verify`, where the git has it: 2.47 and later.
fn refsVerify(repo: *testgit.Repo, io: Io, prefix: []const []const u8) !void {
    testgit.requireGitVersion(repo.gpa, io, 2, 47) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => |e| return e,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(repo.gpa);
    try argv.appendSlice(repo.gpa, prefix);
    try argv.appendSlice(repo.gpa, &.{ "refs", "verify" });
    try repo.exec(io, argv.items);
}

test "an update goes through HEAD, a deletion takes its log, and the hook hears what git's does, in a reftable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    const hooks = @import("hooks.zig");
    var environ = try testgit.programEnviron(gpa);
    defer environ.deinit();
    try environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
    try environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
    var twins: [2]testgit.Repo = undefined;
    var made: usize = 0;
    defer for (twins[0..made]) |*t| t.deinit();
    const hook = "#!/bin/sh\n{ echo \"$1\"; cat; } >> .git/rt.log\n";
    for (&twins) |*r| {
        r.* = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
        made += 1;
        r.environ = &environ;
        defer r.environ = null;
        try r.writeFile(io, "a.txt", "a\n");
        try r.exec(io, &.{ "add", "a.txt" });
        try r.exec(io, &.{ "commit", "-q", "-m", "one" });
        try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
        try r.writeFile(io, ".git/hooks/reference-transaction", hook);
        const file = try r.dir.openFile(io, ".git/hooks/reference-transaction", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    const first_text = try twins[0].line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(first_text);
    const second_text = try twins[0].line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(second_text);
    const first = try Oid.parse(.sha1, first_text);
    const second = try Oid.parse(.sha1, second_text);

    const git_steps = [_][]const []const u8{
        &.{ "update-ref", "-m", "through HEAD", "HEAD", first_text, second_text },
        &.{ "update-ref", "-m", "the branch by name", "refs/heads/main", second_text },
        &.{ "update-ref", "--no-deref", "-m", "detached", "HEAD", first_text },
        &.{ "update-ref", "--no-deref", "-m", "attached", "HEAD", second_text },
        &.{ "symbolic-ref", "HEAD", "refs/heads/main" },
        &.{ "update-ref", "-m", "a topic", "refs/heads/topic", first_text },
        &.{ "update-ref", "-d", "-m", "gone", "refs/heads/topic" },
    };
    twins[0].environ = &environ;
    for (git_steps) |args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "-c", "core.hooksPath=.git/hooks" });
        try argv.appendSlice(gpa, args);
        try twins[0].exec(io, argv.items);
    }
    twins[0].environ = null;

    var repo = try repo_mod.Repository.open(gpa, io, twins[1].dir, .{});
    defer repo.deinit(io);
    var config = try @import("config.zig").Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = repo.git_dir,
        .common_dir = repo.common_dir,
        .work_dir = twins[1].dir,
    }, .{ .environ = &environ }, .{ .output = .ignore });
    defer runner.deinit();
    const Step = struct { name: []const u8, new: ?refs.Ref, expected: refs.Expected, no_deref: bool = false, message: ?[]const u8 };
    const steps = [_]Step{
        .{ .name = "HEAD", .new = .{ .direct = first }, .expected = .{ .matches = second }, .message = "through HEAD" },
        .{ .name = "refs/heads/main", .new = .{ .direct = second }, .expected = .any, .message = "the branch by name" },
        .{ .name = "HEAD", .new = .{ .direct = first }, .expected = .any, .no_deref = true, .message = "detached" },
        .{ .name = "HEAD", .new = .{ .direct = second }, .expected = .any, .no_deref = true, .message = "  attached \n" },
        .{ .name = "HEAD", .new = .{ .symbolic = "refs/heads/main" }, .expected = .any, .message = "" },
        .{ .name = "refs/heads/topic", .new = .{ .direct = first }, .expected = .any, .message = "a topic" },
        .{ .name = "refs/heads/topic", .new = null, .expected = .any, .message = "gone" },
    };
    const fixed: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
    for (steps) |step| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.change(step.name, step.new, step.expected, .{ .no_deref = step.no_deref });
        try tx.commit(io, if (step.message) |m| .{ .who = fixed, .message = m } else null);
    }

    const a = try twins[0].readFile(io, ".git/rt.log");
    defer gpa.free(a);
    const b = try twins[1].readFile(io, ".git/rt.log");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
    for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/topic" }) |name| {
        twins[0].report_failures = false;
        twins[1].report_failures = false;
        const x = gitReflog(&twins[0], io, name) catch "";
        defer if (x.len != 0) gpa.free(x);
        const y = gitReflog(&twins[1], io, name) catch "";
        defer if (y.len != 0) gpa.free(y);
        try std.testing.expectEqualStrings(x, y);
    }
    const x = try gitForEachRef(&twins[0], io);
    defer gpa.free(x);
    const y = try gitForEachRef(&twins[1], io);
    defer gpa.free(y);
    try std.testing.expectEqualStrings(x, y);
    const head_a = try twins[0].line(io, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(head_a);
    const head_b = try twins[1].line(io, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(head_b);
    try std.testing.expectEqualStrings(head_a, head_b);
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

test "a linked worktree keeps its own HEAD in its own stack, both ways" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    const worktrees = @import("worktrees.zig");
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "worktree", "add", "-q", "-b", "theirs", "trees/theirs" });
    const commit_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit_text);
    const tip = try Oid.parse(.sha1, commit_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/ours", .{ .direct = tip });
        try tx.commit(io, .{ .who = who(1_700_000_000), .message = "branch: Created from main" });
    }
    try git.dir.createDirPath(io, "trees/ours");
    var dest = try git.dir.openDir(io, "trees/ours", .{ .iterate = true });
    defer dest.close(io);
    var added = try worktrees.add(gpa, io, repo.common_dir, "ours", dest, "trees/ours", .{ .branch = "ours" });
    defer added.admin_dir.close(io);
    defer gpa.free(added.name);
    defer added.work_dir.close(io);

    // git reads the worktree this made, and this reads the one git made.
    const listed = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "branch refs/heads/ours") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "branch refs/heads/theirs") != null);
    var ours = try repo.listWorktrees(io);
    defer ours.deinit();
    try std.testing.expectEqualStrings("ours", ours.find("ours").?.branch.?);
    try std.testing.expectEqualStrings("theirs", ours.find("theirs").?.branch.?);

    // Inside it, HEAD comes from its stack and the branch from the shared
    // one; a per-worktree ref written there stays there.
    var linked = try repo_mod.Repository.open(gpa, io, added.work_dir, .{ .discover = false });
    defer linked.deinit(io);
    const head = (try linked.head(io)).?;
    defer gpa.free(head.name);
    try std.testing.expectEqualStrings("refs/heads/ours", head.name);
    try std.testing.expect(head.oid.eql(tip));
    {
        var tx = linked.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/bisect/good", .{ .direct = tip });
        try tx.change("HEAD", .{ .direct = tip }, .any, .{ .no_deref = true });
        try tx.commit(io, .{ .who = who(1_700_000_100), .message = "checkout: moving to detached" });
    }
    const detached = try git.line(io, &.{ "-C", "trees/ours", "rev-parse", "--symbolic-full-name", "HEAD" });
    defer gpa.free(detached);
    try std.testing.expectEqualStrings("HEAD", detached);
    const bisect = try git.line(io, &.{ "-C", "trees/ours", "rev-parse", "refs/bisect/good" });
    defer gpa.free(bisect);
    try std.testing.expectEqualStrings(commit_text, bisect);
    // The main worktree's HEAD did not move, and does not see the other's
    // per-worktree ref.
    const main_head = try git.line(io, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(main_head);
    try std.testing.expectEqualStrings("refs/heads/main", main_head);
    var shared = try repo.refs.list(gpa, io, "refs/");
    defer shared.deinit();
    try std.testing.expect(shared.find("refs/bisect/good") == null);
    var own = try linked.refs.list(gpa, io, "refs/");
    defer own.deinit();
    try std.testing.expect(own.find("refs/bisect/good") != null);
    try std.testing.expect(own.find("refs/heads/ours") != null);
    try refsVerify(&git, io, &.{ "-C", "trees/ours" });
}
