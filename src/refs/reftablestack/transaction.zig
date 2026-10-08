const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../../hash/hash.zig");
const Oid = hash.Oid;
const Kind = hash.Kind;
const object = @import("../../object/object.zig");
const fs = @import("../../fs/fs.zig");
const reftable = @import("../reftable.zig");
const reflog = @import("../reflog.zig");
const refs = @import("../value.zig");
const cache = @import("cache.zig");
pub const Options = @import("policy.zig").Options;
pub const Error = @import("policy.zig").Error;
const state_mod = @import("../state.zig");
const ref_names = @import("../../names/ref.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Stack = cache.Stack;
const Cache = cache.Cache;
const max_reload_attempts = cache.internal.max_reload_attempts;
const mergedRefs = cache.internal.mergedRefs;
const allLogs = cache.internal.allLogs;
const copyLog = cache.internal.copyLog;
const lessThanRef = cache.internal.lessThanRef;
const newerFirst = cache.internal.newerFirst;
const logOrder = cache.internal.logOrder;
const isTableName = cache.internal.isTableName;
const tableName = cache.internal.tableName;
const Validity = cache.internal.Validity;
const Stacks = cache.internal.Stacks;
const loadIn = cache.internal.loadIn;
const reloadIn = cache.internal.reloadIn;
const isLinked = cache.internal.isLinked;
const View = struct {
    cache: ?*Cache,
    owned: ?Stacks,
    stacks: *const Stacks,

    fn acquire(gpa: Allocator, io: Io, store: anytype, owned: *?Stacks) Error!View {
        if (state_mod.get(store._state).cache) |c| {
            c.mutex.lock(io) catch return error.Canceled;
            errdefer c.mutex.unlock(io);
            const st = try cache.internal.refresh(c, io, store);
            return .{ .cache = c, .owned = null, .stacks = st };
        }
        owned.* = try cache.internal.open(gpa, io, store);
        return .{ .cache = null, .owned = null, .stacks = &owned.*.? };
    }

    fn release(v: *View, io: Io, owned: *?Stacks) void {
        if (v.cache) |c| c.mutex.unlock(io);
        if (owned.*) |*st| cache.internal.deinit(st);
        owned.* = null;
    }
};
/// `Store.read` over reftable. The returned target of a symbolic ref is
/// the caller's.
pub fn read(gpa: Allocator, io: Io, store: anytype, name: []const u8) refs.ReadError!?refs.Ref {
    var owned: ?Stacks = null;
    var view = try View.acquire(gpa, io, store, &owned);
    defer view.release(io, &owned);
    return readIn(gpa, view.stacks, name);
}

fn readIn(gpa: Allocator, stacks: *const Stacks, name: []const u8) refs.ReadError!?refs.Ref {
    return refFrom(gpa, cache.internal.forName(stacks, name), name);
}

/// `name`'s value in one stack, or `null`.
fn refFrom(gpa: Allocator, stack: *const Stack, name: []const u8) refs.ReadError!?refs.Ref {
    const record = (try stack.lookup(gpa, name, .{ .out = gpa })) orelse return null;
    return switch (record.value) {
        .deletion => null,
        .direct => |oid| .{ .direct = oid },
        .peeled => |p| .{ .direct = p.value },
        .symbolic => |target| .{ .symbolic = target },
    };
}

/// A ref another worktree keeps for itself, reached as
/// `main-worktree/<name>` or `worktrees/<id>/<name>`: the main worktree's
/// in the shared stack, a linked worktree's in its own, which is read for
/// this call. The returned target of a symbolic ref is the caller's.
pub fn readOtherWorktree(gpa: Allocator, io: Io, store: anytype, where: ref_names.WorktreeRef) refs.ReadError!?refs.Ref {
    switch (where.owner) {
        .main => {
            var owned: ?Stacks = null;
            var view = try View.acquire(gpa, io, store, &owned);
            defer view.release(io, &owned);
            return refFrom(gpa, &view.stacks.main, where.bare);
        },
        .other => {
            var stack = (try loadWorktree(gpa, io, store, where.id)) orelse return null;
            defer stack.deinit();
            return refFrom(gpa, &stack, where.bare);
        },
        // unreachable: the store reads the names of its own worktree, and the shared ones, itself
        .current, .shared => unreachable,
    }
}

/// The stack of the linked worktree `id`, read now, or `null` when there
/// is no such worktree.
fn loadWorktree(gpa: Allocator, io: Io, store: anytype, id: []const u8) refs.ReadError!?Stack {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.mem.print(&path_buffer, "worktrees/{s}", .{id}) catch return null;
    var admin = store.commonDir().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.NameTooLong => return null,
        else => |e| return e,
    };
    defer admin.close(io);
    const stack = try loadIn(gpa, io, admin, store.objectFormat());
    return stack;
}

/// The log records of `name`, newest first, wherever its worktree keeps
/// them: this worktree's stack, the shared one, or another worktree's.
fn logRecords(gpa: Allocator, arena: Allocator, io: Io, store: anytype, name: []const u8) refs.ReadError![]reftable.LogRecord {
    const where = ref_names.parseWorktreeRef(name);
    if (where.owner == .other) {
        if (where.bare.len == 0) return &.{};
        var stack = (try loadWorktree(gpa, io, store, where.id)) orelse return &.{};
        defer stack.deinit();
        return stack.logsFor(gpa, where.bare, .{ .arena = arena });
    }
    var owned: ?Stacks = null;
    var view = try View.acquire(gpa, io, store, &owned);
    defer view.release(io, &owned);
    if (where.owner == .main) return view.stacks.main.logsFor(gpa, where.bare, .{ .arena = arena });
    return cache.internal.forName(view.stacks, name).logsFor(gpa, name, .{ .arena = arena });
}

/// Follow symbolic refs through the stacks until an object name, with the
/// transaction's own new values taking precedence. `null` for a name that
/// is not there, which is an unborn branch's shape.
fn resolveIn(gpa: Allocator, stacks: *const Stacks, name: []const u8, pending: anytype) refs.ReadError!?Oid {
    var buf: [1024]u8 = undefined;
    var current: []const u8 = name;
    var depth: u8 = 0;
    while (depth <= refs.max_symbolic_depth) : (depth += 1) {
        var value: ?refs.Ref = null;
        var owned: ?[]const u8 = null;
        defer if (owned) |o| gpa.free(o);
        var overridden = false;
        const Maybe = if (@TypeOf(pending) == @TypeOf(null)) ?*const struct { edits: struct { items: []const refs.Edit } } else if (@typeInfo(@TypeOf(pending)) == .optional) @TypeOf(pending) else ?@TypeOf(pending);
        const maybe: Maybe = pending;
        if (maybe) |tx| {
            for (tx.edits.items) |edit| {
                if (!std.mem.eql(u8, edit.name, current)) continue;
                overridden = true;
                value = edit.new;
            }
        }
        if (!overridden) {
            value = try readIn(gpa, stacks, current);
            if (value) |v| switch (v) {
                .symbolic => |t| owned = t,
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
pub fn list(gpa: Allocator, io: Io, store: anytype, prefix: []const u8) refs.ReadError!refs.Listing {
    var owned: ?Stacks = null;
    var view = try View.acquire(gpa, io, store, &owned);
    defer view.release(io, &owned);
    const stacks = view.stacks;

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var entries: std.ArrayList(refs.Named) = .empty;
    var broken: std.ArrayList(refs.Broken) = .empty;

    const sources = [_]?*const Stack{ &stacks.main, if (stacks.worktree) |*w| w else null };
    for (sources, 0..) |maybe, which| {
        const stack = maybe orelse continue;
        const records = try stack.refsWithPrefix(gpa, prefix, .{ .arena = arena, .include_deletions = false });
        for (records) |record| {
            // In a linked worktree the shared stack's per-worktree refs are
            // the main worktree's, and the worktree's own stack holds only
            // per-worktree refs.
            if (stacks.worktree != null and ref_names.isCurrentWorktree(record.name) != (which == 1)) continue;
            // A name no ref may have is listed apart, as git's reftable
            // backend marks it broken.
            if (!ref_names.checkFormat(record.name, .{ .allow_onelevel = true })) {
                try broken.append(arena, .{ .name = record.name, .why = if (ref_names.isSafe(record.name)) .bad_name else .unsafe_name });
                continue;
            }
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
    std.mem.sort(refs.Broken, broken.items, {}, lessThanBroken);
    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = entries.items, .broken = broken.items };
}

fn lessThanNamed(_: void, a: refs.Named, b: refs.Named) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn lessThanBroken(_: void, a: refs.Broken, b: refs.Broken) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Errors from `readLog`.
pub const ReadLogError = refs.ReadError || reflog.ReadError;

/// `Store.readLog` over reftable: the entries oldest first, as the files
/// backend's log is. An entry whose old and new names are both zero is the
/// marker git writes to say a log exists, and is not an entry.
pub fn readLog(gpa: Allocator, io: Io, store: anytype, name: []const u8) ReadLogError!reflog.Log {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const records = try logRecords(gpa, arena_instance.allocator(), io, store, name);

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
pub fn logExists(gpa: Allocator, io: Io, store: anytype, name: []const u8) refs.ReadError!bool {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    return (try logRecords(gpa, arena_instance.allocator(), io, store, name)).len != 0;
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
        shared: fs.Shared = .umask,
    };

    fn release(p: *Pending, gpa: Allocator, io: Io) void {
        for ([_]?*Locked{ &p.main, if (p.worktree) |*w| w else null }) |maybe| {
            const l = maybe orelse continue;
            if (!l.written) l.lock.deinit(io);
            gpa.free(l.buffer);
            l.dir.close(io);
        }
        cache.internal.deinit(&p.stacks);
    }
};

fn lockStack(gpa: Allocator, io: Io, parent: Io.Dir, options: Options) refs.TransactionError!Pending.Locked {
    fs.makeDirs(io, parent, "reftable", options.shared) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    var dir = try parent.openDir(io, "reftable", .{});
    errdefer dir.close(io);
    const buffer = try gpa.alloc(u8, 4096);
    errdefer gpa.free(buffer);
    const lock = try fs.LockFile.open(gpa, io, dir, "tables.list", buffer, .{ .on_contention = options.lock, .shared = options.shared });
    return .{ .dir = dir, .lock = lock, .buffer = buffer, .shared = options.shared };
}

/// `Transaction.prepare` over reftable: take `tables.list.lock` on every
/// stack the edits touch, read the stacks under it, and check every
/// expected value and every name against the refs already there.
pub fn prepare(io: Io, tx: anytype) refs.TransactionError!void {
    const store = tx.store;
    const gpa = tx.gpa;
    var needs_worktree = false;
    for (tx.edits.items) |edit| {
        if (isLinked(store) and ref_names.isCurrentWorktree(edit.name)) needs_worktree = true;
    }

    var main = try lockStack(gpa, io, store.commonDir(), store.reftableOptions());
    errdefer {
        main.lock.deinit(io);
        gpa.free(main.buffer);
        main.dir.close(io);
    }
    var worktree: ?Pending.Locked = if (needs_worktree) try lockStack(gpa, io, store.gitDir(), store.reftableOptions()) else null;
    errdefer if (worktree) |*w| {
        w.lock.deinit(io);
        gpa.free(w.buffer);
        w.dir.close(io);
    };
    var stacks = try cache.internal.open(gpa, io, store);
    errdefer cache.internal.deinit(&stacks);

    for (tx.edits.items) |*edit| {
        // A ref only logged through is neither read nor checked.
        if (edit.via != null) continue;
        const current = try readIn(gpa, &stacks, edit.name);
        var current_oid: ?Oid = null;
        if (current) |value| switch (value) {
            .direct => |oid| current_oid = oid,
            .symbolic => |target| {
                gpa.free(target);
                current_oid = try resolveIn(gpa, &stacks, edit.name, null);
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
fn checkNames(tx: anytype, stacks: *const Stacks) refs.TransactionError!void {
    const gpa = tx.gpa;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    for (tx.edits.items) |edit| {
        if (edit.new == null or edit.via != null) continue;
        const stack = cache.internal.forName(stacks, edit.name);
        // A ref where a directory of this one would be.
        var end = edit.name.len;
        while (std.mem.findScalarLast(u8, edit.name[0..end], '/')) |slash| {
            end = slash;
            const ancestor = edit.name[0..end];
            if (deletedHere(tx, ancestor)) continue;
            const record = (try stack.lookup(gpa, ancestor, .{ .out = arena })) orelse continue;
            if (record.value != .deletion) return error.RefNameConflict;
        }
        // Refs where this one's directory would be.
        const below = try arena.print("{s}/", .{edit.name});
        for (try stack.refsWithPrefix(gpa, below, .{ .arena = arena, .include_deletions = false })) |record| {
            if (!deletedHere(tx, record.name)) return error.RefNameConflict;
        }
    }
}

fn deletedHere(tx: anytype, name: []const u8) bool {
    for (tx.edits.items) |edit| {
        if (edit.via == null and edit.new == null and std.mem.eql(u8, edit.name, name)) return true;
    }
    return false;
}

/// `Transaction.commit` over reftable: one table per stack the edits touch,
/// installed by rewriting `tables.list` under the lock `prepare` took, then
/// the stack compacted if the geometric rule asks for it.
pub fn commit(io: Io, tx: anytype, log: ?refs.LogMessage) refs.TransactionError!void {
    const pending = tx.reftable.?;
    const store = tx.store;
    try addTable(io, tx, pending, &pending.main, &pending.stacks.main, false, log);
    if (pending.worktree) |*w| try addTable(io, tx, pending, w, &pending.stacks.worktree.?, true, log);

    const options = store.reftableOptions();
    const compact_worktree = pending.worktree != null;
    releasePending(io, tx);
    if (!options.auto_compact) return;
    compactIn(tx.gpa, io, store.commonDir(), store.objectFormat(), options, .auto) catch |err| switch (err) {
        // Compaction is housekeeping: someone else holding a lock, or
        // compacting already, is not a failure of this transaction.
        error.LockHeld => {},
        else => |e| return e,
    };
    if (compact_worktree) {
        compactIn(tx.gpa, io, store.gitDir(), store.objectFormat(), options, .auto) catch |err| switch (err) {
            error.LockHeld => {},
            else => |e| return e,
        };
    }
}

/// `Store.appendLog` over reftable: one entry, written as a table of its
/// own under the stack's lock, which is how git writes a log that moves no
/// ref. The message is kept as a transaction's is.
pub fn appendLog(
    gpa: Allocator,
    io: Io,
    store: anytype,
    name: []const u8,
    old: Oid,
    new: Oid,
    who: object.Signature,
    message: []const u8,
) refs.TransactionError!void {
    if (std.mem.findAny(u8, who.name, "<>\n") != null or
        std.mem.findAny(u8, who.email, "<>\n") != null) return error.InvalidSignature;
    const parent = if (isLinked(store) and ref_names.isCurrentWorktree(name)) store.gitDir() else store.commonDir();
    var locked = try lockStack(gpa, io, parent, store.reftableOptions());
    defer releaseLocked(gpa, io, &locked);
    var stack = try Stack.load(gpa, io, locked.dir, store.objectFormat());
    defer stack.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const update_index = stack.maxUpdateIndex() + 1;
    const record: reftable.LogRecord = .{ .name = name, .update_index = update_index, .value = .{ .update = .{
        .old = old,
        .new = new,
        .name = who.name,
        .email = who.email,
        .time = std.math.cast(u64, who.when_secs) orelse 0,
        .tz_offset = zoneFromMinutes(who.offset_minutes),
        .message = try logMessage(arena_instance.allocator(), try reflog.normalizeMessage(arena_instance.allocator(), message), store.reftableOptions().write.block_size),
    } } };
    const bytes = try reftable.write(gpa, store.objectFormat(), store.reftableOptions().write, update_index, update_index, &.{}, &.{record});
    defer gpa.free(bytes);
    try install(gpa, io, &locked, &stack, bytes, update_index);
    try compactAfter(gpa, io, parent, store);
}

/// `Store.expireLog` over reftable, as git's `reftable_be_reflog_expire`:
/// under the stack's lock, one table that tombstones each entry `keeper`
/// lets go and writes each kept one again, its old value rewritten when
/// asked; a log left with no entry keeps the marker that says it exists,
/// and the ref moves to the newest kept entry when asked.
pub fn expireLog(
    gpa: Allocator,
    io: Io,
    store: anytype,
    name: []const u8,
    options: anytype,
    keeper: anytype,
) refs.TransactionError!void {
    const parent = if (isLinked(store) and ref_names.isCurrentWorktree(name)) store.gitDir() else store.commonDir();
    var locked = try lockStack(gpa, io, parent, store.reftableOptions());
    defer releaseLocked(gpa, io, &locked);
    var stack = try Stack.load(gpa, io, locked.dir, store.objectFormat());
    defer stack.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // Newest first, as git's iterator hands them over.
    const records = try stack.logsFor(gpa, name, .{ .arena = arena });
    if (records.len == 0) return;

    var live: usize = 0;
    for (records) |r| {
        if (!isMarker(r)) live += 1;
    }
    const rewritten = try arena.dupe(reftable.LogRecord, records);
    var last_kept: ?usize = null;
    var newer = live;
    var i = rewritten.len;
    while (i > 0) {
        i -= 1;
        const dest = &rewritten[i];
        // The marker goes; it comes back below when no entry is left.
        if (isMarker(dest.*)) {
            dest.value = .deletion;
            continue;
        }
        newer -= 1;
        const entry = entryOf(dest.value.update);
        if (options.rewrite) if (last_kept) |at| {
            dest.value.update.old = rewritten[at].value.update.new;
        };
        if (keeper.keep(entry, newer)) last_kept = i else dest.value = .deletion;
    }

    const update_index = stack.maxUpdateIndex() + 1;
    var logs: std.ArrayList(reftable.LogRecord) = .empty;
    try logs.appendSlice(arena, rewritten);
    if (last_kept == null) try logs.append(arena, marker(store.objectFormat(), name, update_index));
    std.mem.sort(reftable.LogRecord, logs.items, {}, logOrder);

    var ref_records: [1]reftable.RefRecord = undefined;
    var ref_count: usize = 0;
    if (options.update_ref) if (last_kept) |at| {
        // A symbolic ref is left as it is, as git leaves it.
        const current = try stack.lookup(gpa, name, .{ .out = arena });
        const direct = if (current) |r| r.value == .direct or r.value == .peeled else false;
        if (direct) {
            ref_records[0] = .{ .name = name, .update_index = update_index, .value = .{ .direct = rewritten[at].value.update.new } };
            ref_count = 1;
        }
    };

    const bytes = try reftable.write(gpa, store.objectFormat(), store.reftableOptions().write, update_index, update_index, ref_records[0..ref_count], logs.items);
    defer gpa.free(bytes);
    try install(gpa, io, &locked, &stack, bytes, update_index);
    try compactAfter(gpa, io, parent, store);
}

/// `Store.createLog` over reftable: the marker git writes to say a log
/// exists, in a table of its own, unless the log has an entry already.
pub fn createLog(gpa: Allocator, io: Io, store: anytype, name: []const u8) refs.TransactionError!void {
    const parent = if (isLinked(store) and ref_names.isCurrentWorktree(name)) store.gitDir() else store.commonDir();
    var locked = try lockStack(gpa, io, parent, store.reftableOptions());
    defer releaseLocked(gpa, io, &locked);
    var stack = try Stack.load(gpa, io, locked.dir, store.objectFormat());
    defer stack.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    if ((try stack.logsFor(gpa, name, .{ .arena = arena_instance.allocator() })).len != 0) return;
    const update_index = stack.maxUpdateIndex() + 1;
    const logs = [_]reftable.LogRecord{marker(store.objectFormat(), name, update_index)};
    const bytes = try reftable.write(gpa, store.objectFormat(), store.reftableOptions().write, update_index, update_index, &.{}, &logs);
    defer gpa.free(bytes);
    try install(gpa, io, &locked, &stack, bytes, update_index);
    try compactAfter(gpa, io, parent, store);
}

/// `Store.deleteLog` over reftable, as git's `reftable_be_delete_reflog`:
/// a tombstone for every entry of the log, the marker among them, in one
/// table. A log with no entry adds none.
pub fn deleteLog(gpa: Allocator, io: Io, store: anytype, name: []const u8) refs.TransactionError!void {
    const parent = if (isLinked(store) and ref_names.isCurrentWorktree(name)) store.gitDir() else store.commonDir();
    var locked = try lockStack(gpa, io, parent, store.reftableOptions());
    defer releaseLocked(gpa, io, &locked);
    var stack = try Stack.load(gpa, io, locked.dir, store.objectFormat());
    defer stack.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const records = try stack.logsFor(gpa, name, .{ .arena = arena });
    if (records.len == 0) return;
    const update_index = stack.maxUpdateIndex() + 1;
    const logs = try arena.alloc(reftable.LogRecord, records.len);
    for (records, logs) |r, *out| out.* = .{ .name = name, .update_index = r.update_index, .value = .deletion };
    std.mem.sort(reftable.LogRecord, logs, {}, logOrder);
    const bytes = try reftable.write(gpa, store.objectFormat(), store.reftableOptions().write, update_index, update_index, &.{}, logs);
    defer gpa.free(bytes);
    try install(gpa, io, &locked, &stack, bytes, update_index);
    try compactAfter(gpa, io, parent, store);
}

/// The entry git writes to say a log exists with nothing in it: both
/// names null, and nothing else.
fn marker(kind: Kind, name: []const u8, update_index: u64) reftable.LogRecord {
    return .{ .name = name, .update_index = update_index, .value = .{ .update = .{
        .old = Oid.zero(kind),
        .new = Oid.zero(kind),
        .name = "",
        .email = "",
        .time = 0,
        .tz_offset = 0,
        .message = "",
    } } };
}

fn isMarker(record: reftable.LogRecord) bool {
    return switch (record.value) {
        .deletion => false,
        .update => |u| u.old.isZero() and u.new.isZero(),
    };
}

/// A table's log record as `Store.readLog` hands an entry out, borrowing
/// the record's text.
fn entryOf(u: reftable.LogUpdate) reflog.Entry {
    var message = u.message;
    if (message.len > 0 and message[message.len - 1] == '\n') message = message[0 .. message.len - 1];
    return .{
        .old = u.old,
        .new = u.new,
        .who = .{
            .name = u.name,
            .email = u.email,
            .when_secs = std.math.cast(i64, u.time) orelse std.math.maxInt(i64),
            .offset_minutes = minutesFromZone(u.tz_offset),
        },
        .message = message,
    };
}

fn releaseLocked(gpa: Allocator, io: Io, locked: *Pending.Locked) void {
    if (!locked.written) locked.lock.deinit(io);
    gpa.free(locked.buffer);
    locked.dir.close(io);
}

/// The compaction git's geometric rule asks for after a table is added;
/// another process compacting already is not a failure of the addition.
fn compactAfter(gpa: Allocator, io: Io, parent: Io.Dir, store: anytype) refs.TransactionError!void {
    const options = store.reftableOptions();
    if (!options.auto_compact) return;
    compactIn(gpa, io, parent, store.objectFormat(), options, .auto) catch |err| switch (err) {
        error.LockHeld => {},
        else => |e| return e,
    };
}

/// Put a new table beside the others and name it last in `tables.list`,
/// through the lock the caller holds.
fn install(gpa: Allocator, io: Io, locked: *Pending.Locked, stack: *const Stack, bytes: []const u8, update_index: u64) refs.TransactionError!void {
    var name_buf: [64]u8 = undefined;
    const name = tableName(io, &name_buf, update_index, update_index);
    try writeTable(gpa, io, locked.dir, name, bytes, locked.shared);
    const w = locked.lock.writer();
    w.writeAll(stack.list) catch return error.WriteFailed;
    if (stack.list.len != 0 and stack.list[stack.list.len - 1] != '\n') w.writeByte('\n') catch return error.WriteFailed;
    w.print("{s}\n", .{name}) catch return error.WriteFailed;
    try locked.lock.commit(io);
    locked.lock.deinit(io);
    locked.written = true;
}

/// Give up whatever `prepare` took.
pub fn releasePending(io: Io, tx: anytype) void {
    const pending = tx.reftable orelse return;
    pending.release(tx.gpa, io);
    tx.gpa.destroy(pending);
    tx.reftable = null;
}

fn addTable(
    io: Io,
    tx: anytype,
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
        break :blk try logMessage(arena, normal, store.reftableOptions().write.block_size);
    } else null;
    for (tx.edits.items) |edit| {
        if (isLinked(store) and ref_names.isCurrentWorktree(edit.name) != worktree_stack) continue;
        // A ref an update went through, or `HEAD` when the branch it names
        // moved, keeps its value and gains the log line: git's
        // `REF_LOG_ONLY`.
        const source = if (edit.via) |at| tx.edits.items[at] else edit;
        if (edit.via == null) {
            const value: reftable.RefValue = if (edit.new) |new| switch (new) {
                .direct => |oid| if (tx.peeler) |p| (if (p.peel(io, p.context, oid)) |target|
                    .{ .peeled = .{ .value = oid, .target = target } }
                else
                    .{ .direct = oid }) else .{ .direct = oid },
                .symbolic => |target| .{ .symbolic = target },
            } else .deletion;
            try records.append(arena, .{ .name = edit.name, .update_index = update_index, .value = value });
        }

        if (edit.via == null and edit.new == null) {
            // A deleted ref's log goes with it, as it does in git, whether
            // or not the transaction logs anything: one tombstone for each
            // entry it had.
            for (try stack.logsFor(gpa, edit.name, .{ .arena = arena })) |entry| {
                try logs.append(arena, .{ .name = edit.name, .update_index = entry.update_index, .value = .deletion });
            }
            continue;
        }
        const message = log orelse continue;
        const exists = (try stack.logsFor(gpa, edit.name, .{ .arena = arena })).len != 0;
        if (!reflog.shouldLog(message.policy, edit.name, exists)) continue;
        const new_oid = if (source.new) |new| switch (new) {
            .direct => |oid| oid,
            // git writes no entry for a symbolic ref whose target does not
            // resolve yet.
            .symbolic => (try resolveIn(gpa, &pending.stacks, source.name, tx)) orelse continue,
        } else Oid.zero(store.objectFormat());
        if (std.mem.findAny(u8, message.who.name, "<>\n") != null or
            std.mem.findAny(u8, message.who.email, "<>\n") != null) return error.InvalidSignature;
        try logs.append(arena, .{
            .name = edit.name,
            .update_index = update_index,
            .value = .{
                .update = .{
                    .old = source.old orelse Oid.zero(store.objectFormat()),
                    .new = new_oid,
                    .name = message.who.name,
                    .email = message.who.email,
                    .time = std.math.cast(u64, message.who.when_secs) orelse 0,
                    .tz_offset = zoneFromMinutes(message.who.offset_minutes),
                    // An edit's own words, or the transaction's.
                    .message = if (source.message) |m|
                        try logMessage(arena, try reflog.normalizeMessage(arena, m), store.reftableOptions().write.block_size)
                    else
                        text.?,
                },
            },
        });
    }
    if (records.items.len == 0 and logs.items.len == 0) return;
    std.mem.sort(reftable.RefRecord, records.items, {}, lessThanRef);
    std.mem.sort(reftable.LogRecord, logs.items, {}, logOrder);

    const bytes = try reftable.write(gpa, store.objectFormat(), store.reftableOptions().write, update_index, update_index, records.items, logs.items);
    defer gpa.free(bytes);
    try install(gpa, io, locked, stack, bytes, update_index);
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
fn writeTable(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8, shared: fs.Shared) refs.TransactionError!void {
    var buffer: [16 * 1024]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, dir, name, &buffer, .{ .shared = shared });
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
/// As git's `stack_compact_range`: each table being merged is locked, by
/// `<table>.lock`, under the stack's lock; a table another process has
/// locked -- a git compacting it already -- ends the run there, and only
/// the newer tables past it are merged, as git's best-effort rule does.
/// The stack's lock is then let go for the merge, so a writer is not kept
/// waiting past its `reftable.lockTimeout` for it, and taken again to put
/// the merged table in the place of the ones it replaces, wherever the
/// stack has them by then.
pub fn compactIn(gpa: Allocator, io: Io, parent: Io.Dir, kind: Kind, options: Options, which: Compaction) refs.TransactionError!void {
    var dir = parent.openDir(io, "reftable", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    var buffer: [4096]u8 = undefined;
    var list_lock: ?fs.LockFile = try fs.LockFile.open(gpa, io, dir, "tables.list", &buffer, .{ .on_contention = options.lock, .shared = options.shared });
    defer if (list_lock) |*lock| lock.deinit(io);
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
        const lock_name = try gpa.print("{s}.lock", .{stack.names[i - 1]});
        if (dir.createFile(io, lock_name, .{ .exclusive = true })) |file| {
            file.close(io);
            held.append(gpa, lock_name) catch |err| {
                // ziglint-ignore: Z026 the allocation's error is the one to report; a lock left behind is one git reports by name
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
    // The tables are locked; the list need not be while they are merged.
    list_lock.?.deinit(io);
    list_lock = null;

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
        const name = tableName(io, &name_buf, min, max);
        try writeTable(gpa, io, dir, name, bytes, options.shared);
        new_name = name;
    }
    var installed = false;
    // ziglint-ignore: Z026 a merged table no list names is only left for the next compaction to find
    defer if (!installed) if (new_name) |name| dir.deleteFile(io, name) catch {};

    // The list again, as it is now: writers may have added tables, and the
    // merged ones are wherever it has them, in the order they were merged.
    list_lock = try fs.LockFile.open(gpa, io, dir, "tables.list", &buffer, .{ .on_contention = options.lock, .shared = options.shared });
    const listed = (try fs.readFileAlloc(gpa, io, dir, "tables.list", 1 << 20)) orelse try gpa.alloc(u8, 0);
    defer gpa.free(listed);
    var current: std.ArrayList([]const u8) = .empty;
    defer current.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |line| try current.append(gpa, line);
    const merged = stack.names[first .. last + 1];
    // The tables are locked, so another compaction cannot have taken them;
    // a list without them is one this does not understand, and is left be.
    const offset = findRun(current.items, merged) orelse return error.LockHeld;

    const w = list_lock.?.writer();
    for (current.items[0..offset]) |name| w.print("{s}\n", .{name}) catch return error.WriteFailed;
    if (new_name) |name| w.print("{s}\n", .{name}) catch return error.WriteFailed;
    for (current.items[offset + merged.len ..]) |name| w.print("{s}\n", .{name}) catch return error.WriteFailed;
    try list_lock.?.commit(io);
    installed = true;

    // The old tables are out of the list; a reader that read the list
    // before the rename may still be opening one, and goes back to the list
    // when it finds it gone. A platform that will not remove a file another
    // process has open leaves it for the next compaction to find.
    cache.internal.closeUnclaimed(&stack, &.{});
    // ziglint-ignore: Z026 the list no longer names these tables; one a platform will not remove is left for the next compaction
    for (stack.names[first .. last + 1]) |name| dir.deleteFile(io, name) catch {};
}

/// Where `run` stands in `names`, whole and in order, or `null`.
fn findRun(names: []const []const u8, run: []const []const u8) ?usize {
    if (run.len > names.len) return null;
    for (0..names.len - run.len + 1) |offset| {
        const same = for (run, names[offset..][0..run.len]) |a, b| {
            if (!std.mem.eql(u8, a, b)) break false;
        } else true;
        if (same) return offset;
    }
    return null;
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

/// `Store.writeInitial` over reftable: `refs`, sorted, none of them in the
/// shared stack yet, written as one table under its lock, with no logs.
pub fn writeInitial(gpa: Allocator, io: Io, store: anytype, refs_in: anytype) refs.TransactionError!void {
    var locked = try lockStack(gpa, io, store.commonDir(), store.reftableOptions());
    defer {
        if (!locked.written) locked.lock.deinit(io);
        gpa.free(locked.buffer);
        locked.dir.close(io);
    }
    var stack = try Stack.load(gpa, io, locked.dir, store.objectFormat());
    defer stack.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const update_index = stack.maxUpdateIndex() + 1;
    const records = try arena.alloc(reftable.RefRecord, refs_in.len);
    for (refs_in, records) |ref, *record| {
        if (try stack.lookup(gpa, ref.name, .{ .out = arena })) |found| if (found.value != .deletion) return error.RefAlreadyExists;
        record.* = .{ .name = ref.name, .update_index = update_index, .value = if (ref.peeled) |target|
            .{ .peeled = .{ .value = ref.oid, .target = target } }
        else
            .{ .direct = ref.oid } };
    }
    if (records.len == 0) return;
    const bytes = try reftable.write(gpa, store.objectFormat(), store.reftableOptions().write, update_index, update_index, records, &.{});
    defer gpa.free(bytes);
    try install(gpa, io, &locked, &stack, bytes, update_index);
    if (!store.reftableOptions().auto_compact) return;
    compactIn(gpa, io, store.commonDir(), store.objectFormat(), store.reftableOptions(), .auto) catch |err| switch (err) {
        error.LockHeld => {},
        else => |e| return e,
    };
}

//=========================================================================
// Tests
//=========================================================================

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
