//! Loose refs and `packed-refs`, with transactions.
//!
//! A transaction takes every `<ref>.lock` in its prepare step and rolls back
//! completely if any one of them is held. Once `commit` starts, loose refs
//! are installed with separate renames and reflogs with separate appends, as
//! they are in git: an I/O error can leave a committed prefix and the caller
//! must reread the refs before deciding what happened.
//!
//! A repository whose refs are a reftable stack is read and written through
//! the same `Store` and `Transaction`; `format` says which, and
//! `reftablestack` is the other side. There a transaction is one table added
//! under one lock, so its commit is all or nothing.

const ErrorNamespace = @This();
// The modules relic's API puts under this one, as `relic.refs.<name>`.
const reftable = @import("reftable.zig");
/// What a ref may be named, and the names git treats apart.
const names = @import("../names.zig").ref;
const stack_engine = @import("reftablestack/transaction.zig");

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const hooks = @import("../hooks/hooks.zig");
const testgit = @import("../testing/git.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;
const state_mod = @import("state.zig");
const packed_cache = @import("packed.zig");
const value_mod = @import("value.zig");
// The files backend's logs, private to this namespace: every log is read
// and written through `Store`, which knows where the format keeps it.
const reflog = @import("reflog.zig");

/// The header `packed-refs` carries, with the space before the newline that
/// is in git's source and in no document.
pub const packed_header = @import("value.zig").packed_header;

/// How deep a chain of symbolic refs may go. git's own cap.
pub const max_symbolic_depth = @import("value.zig").max_symbolic_depth;

/// Errors from reading refs.
pub const ReadError = @import("value.zig").ReadError;

/// Errors from a transaction.
pub const TransactionError = @import("value.zig").TransactionError;

/// Where a repository's refs are kept.
pub const Format = @import("value.zig").Format;

/// Peels an object name for a ref about to be written, so that a reftable
/// can record what an annotated tag points at beside it, as git's does.
/// `Repository.beginRefs` supplies one.
pub const Peeler = @import("value.zig").Peeler;

/// What a ref points at.
pub const Ref = @import("value.zig").Ref;

/// A ref with its name, as `list` hands them back.
pub const Named = @import("value.zig").Named;

/// What a listing found that is not a ref git would read.
pub const Broken = @import("value.zig").Broken;

/// A fully resolved ref: the name it ended at and the object it points to.
pub const Resolved = @import("value.zig").Resolved;

/// What an edit requires the ref's current value to be.
pub const Expected = @import("value.zig").Expected;

/// A ref's log, oldest first, as `Store.readLog` returns it.
pub const Log = reflog.Log;

/// One entry of a log.
pub const LogEntry = reflog.Entry;

/// When a ref update writes a log entry: `core.logAllRefUpdates`.
pub const LogPolicy = reflog.Policy;

/// Errors from reading a log, beyond those of reading a ref.
pub const LogReadError = reflog.ReadError;

/// One folder `Store.watchScopes` names.
pub const WatchScope = struct {
    /// The per-worktree directory or the shared one, as the store was
    /// opened with them (`Store.gitDir`, `Store.commonDir`).
    dir: enum { git, common },
    /// The folder below it, `/`-separated; `""` the directory itself.
    sub_path: []const u8,
    /// Everything below the folder, at any depth; otherwise only the
    /// entries directly in it.
    recursive: bool = false,
    /// When not empty, the only entries directly in the folder whose
    /// change matters; otherwise every one.
    names: []const []const u8 = &.{},
};

/// The folders `Store.watchScopes` names, at most four.
pub const WatchScopes = struct {
    buffer: [4]WatchScope = undefined,
    len: usize = 0,

    pub fn slice(scopes: *const WatchScopes) []const WatchScope {
        return scopes.buffer[0..scopes.len];
    }

    fn add(scopes: *WatchScopes, scope: WatchScope) void {
        scopes.buffer[scopes.len] = scope;
        scopes.len += 1;
    }
};

/// Loose refs and `packed-refs` behind one reader.
///
/// `git_dir` is the per-worktree directory and `common_dir` the shared one;
/// they are the same in a repository with no linked worktrees. `HEAD`,
/// `refs/bisect`, `refs/worktree` and `refs/rewritten` are per-worktree and
/// everything else is shared, which is the fixed list git uses.
pub const Store = struct {
    pub const Error = ErrorNamespace.Error;

    _state: *state_mod.State,
    /// Open over an already-opened pair of directories, which the store borrows.
    /// The returned owner must be released with `deinit`.
    pub fn init(gpa: Allocator, kind: Kind, git_dir: Io.Dir, common_dir: Io.Dir, options: Options) Allocator.Error!Store {
        const state = try state_mod.create(gpa, kind, options.format, options.reftable, git_dir, common_dir);
        state_mod.get(state).shared = options.shared;
        state_mod.get(state).fsync = options.fsync;
        state_mod.get(state).options.fsync = options.fsync;
        state_mod.get(state).packed_lock = options.packed_lock;
        return .{ ._state = state };
    }

    pub const Options = struct {
        format: Format = .files,
        reftable: stack_engine.Options = .{},
        /// What `core.sharedRepository` asks of the permissions of the
        /// refs, logs and directories written.
        shared: fs.Shared = .umask,
        /// `core.fsync`: which writes are synced; refs, `packed-refs`, logs
        /// and reftable tables are its `reference`.
        fsync: fs.Fsync = .default,
        /// `core.packedRefsTimeout`: how long a writer waits for
        /// `packed-refs.lock`, with git's backoff. git waits a second.
        packed_lock: fs.OnContention = .{ .wait_ms = 1000 },
    };

    /// Choose the backend and its cache once, before the store is published.
    /// Changing the backend or object format requires opening another store.
    /// What `core.sharedRepository` asks of what this store writes.
    pub fn sharedPermissions(store: *const Store) fs.Shared {
        return state_mod.get(store._state).shared;
    }

    /// Borrowed directories; their handles stay owned by the caller of init.
    pub fn gitDir(store: *const Store) Io.Dir {
        return state_mod.get(store._state).git_dir;
    }
    pub fn commonDir(store: *const Store) Io.Dir {
        return state_mod.get(store._state).common_dir;
    }

    pub fn objectFormat(store: *const Store) Kind {
        return state_mod.get(store._state).kind;
    }

    pub fn refFormat(store: *const Store) Format {
        return state_mod.get(store._state).format;
    }

    /// The current write policy, returned by value.
    pub fn reftableOptions(store: *const Store) stack_engine.Options {
        return state_mod.get(store._state).options;
    }

    /// Replace write policy without changing the backend, hash or read cache.
    /// The `fsync` it carries is the store's, which `configureFsync` sets.
    pub fn configureReftable(store: *Store, options: stack_engine.Options) void {
        const data = state_mod.get(store._state);
        data.options = options;
        data.options.fsync = data.fsync;
    }

    /// How a reference this store writes is synced.
    pub fn referenceSync(store: *const Store) fs.Sync {
        return state_mod.get(store._state).fsync.sync(.reference);
    }

    /// Change which writes are synced, as a refreshed configuration says.
    pub fn configureFsync(store: *Store, fsync: fs.Fsync) void {
        const data = state_mod.get(store._state);
        data.fsync = fsync;
        data.options.fsync = fsync;
    }

    /// Release the backend and every cached stack together.
    pub fn deinit(store: *Store) void {
        state_mod.destroy(state_mod.get(store._state).gpa, store._state);
        store.* = undefined;
    }

    /// Where on the disk a change to `HEAD` or to a ref under `refs/`
    /// lands, for a caller that watches the folders rather than reading
    /// every ref again: the loose files and `packed-refs`, or each reftable
    /// stack. In a linked worktree that is both directories — its own
    /// `HEAD` and per-worktree refs, and the branches and `packed-refs` it
    /// shares. Pseudo-refs other than `HEAD`, such as `FETCH_HEAD`, are not
    /// covered. A folder in the list need not exist yet.
    pub fn watchScopes(store: *const Store) WatchScopes {
        const linked = store.gitDir().handle != store.commonDir().handle;
        var scopes: WatchScopes = .{};
        if (store.refFormat() == .reftable) {
            // every ref is in a stack, `HEAD` too: the shared stack, and a
            // linked worktree's own for its `HEAD` and per-worktree refs
            scopes.add(.{ .dir = .common, .sub_path = "reftable" });
            if (linked) scopes.add(.{ .dir = .git, .sub_path = "reftable" });
            return scopes;
        }
        if (linked) {
            scopes.add(.{ .dir = .git, .sub_path = "", .names = &.{"HEAD"} });
            scopes.add(.{ .dir = .git, .sub_path = "refs", .recursive = true });
            scopes.add(.{ .dir = .common, .sub_path = "", .names = &.{"packed-refs"} });
        } else {
            scopes.add(.{ .dir = .git, .sub_path = "", .names = &.{ "HEAD", "packed-refs" } });
        }
        scopes.add(.{ .dir = .common, .sub_path = "refs", .recursive = true });
        return scopes;
    }

    /// Which directory a ref lives in: the worktree's own for a name each
    /// worktree keeps for itself (`names.isCurrentWorktree`: `HEAD`, the
    /// root refs, `refs/bisect/`, `refs/worktree/`, `refs/rewritten/`), the
    /// shared one otherwise. Private to the store: a caller reads and
    /// writes refs and their logs through it, never the files.
    fn dirFor(store: *const Store, name: []const u8) Io.Dir {
        if (names.isCurrentWorktree(name)) return store.gitDir();
        return store.commonDir();
    }

    /// Read one ref, loose first and then `packed-refs`, or `null`.
    ///
    /// A symbolic ref comes back as `.symbolic` without being followed; use
    /// `resolve` for the object. The returned name, when symbolic, is the
    /// caller's.
    pub fn read(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        const found = (try store.readFrom(gpa, io, name)) orelse return null;
        return found.value;
    }

    /// A ref's value, and whether it came from `packed-refs`.
    const Found = struct { value: Ref, from_packed: bool };

    /// `read`, saying whether the value came from `packed-refs`.
    fn readFrom(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Found {
        if (!isRefName(name)) return error.InvalidRefName;
        return store.readUnchecked(gpa, io, name);
    }

    /// A ref's own value, symbolic or not, where a symbolic one can be:
    /// the loose file, or the reftable stack.
    fn readOwnValue(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        if (store.refFormat() == .reftable) {
            const found = (try store.readUnchecked(gpa, io, name)) orelse return null;
            return found.value;
        }
        return store.readLoose(gpa, io, name);
    }

    fn readLoose(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        return store.readLooseAt(gpa, io, store.dirFor(name), name);
    }

    /// The loose ref at `path` under `dir`, or `null`.
    fn readLooseAt(store: *const Store, gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) ReadError!?Ref {
        // A ref is an object name or `ref: <name>`, and git reads no more of
        // the file than that: `FETCH_HEAD` and a merge's `MERGE_HEAD` carry
        // further lines, of any length, after the first object name. One
        // byte past the limit says whether a symbolic ref was cut short.
        var buffer: [max_loose_ref + 1]u8 = undefined;
        const bytes = dir.readFile(io, path, &buffer) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => return null,
            else => |e| return e,
        };
        const value = try parseLoose(gpa, store.objectFormat(), bytes);
        return value;
    }

    /// git's `parse_loose_ref_contents`: `ref:` and a name, or an object
    /// name followed by whitespace or nothing.
    fn parseLoose(gpa: Allocator, kind: Kind, bytes: []const u8) ReadError!Ref {
        if (std.mem.startsWith(u8, bytes, "ref:")) {
            if (bytes.len > max_loose_ref) return error.MalformedRef;
            const target = std.mem.trim(u8, bytes[4..], " \t\r\n");
            if (target.len == 0) return error.MalformedRef;
            return .{ .symbolic = try gpa.dupe(u8, target) };
        }
        const hex_len = kind.hexLen();
        if (bytes.len < hex_len) return error.MalformedRef;
        if (bytes.len > hex_len and !std.ascii.isWhitespace(bytes[hex_len])) return error.MalformedRef;
        const oid = Oid.parse(kind, bytes[0..hex_len]) catch return error.MalformedRef;
        return .{ .direct = oid };
    }

    /// Follow a ref until it points at an object.
    ///
    /// Returns `null` when the chain ends at a name that does not exist,
    /// which is what an unborn branch looks like: `HEAD` is
    /// `ref: refs/heads/main` and `refs/heads/main` is not there.
    pub fn resolve(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Resolved {
        var current: []const u8 = try gpa.dupe(u8, name);
        errdefer gpa.free(current);
        var depth: u8 = 0;
        while (true) : (depth += 1) {
            // `current` is freed on the way out, as on any error.
            if (depth > max_symbolic_depth) return error.SymbolicRefLoop;
            const found = (try store.readFrom(gpa, io, current)) orelse {
                gpa.free(current);
                return null;
            };
            switch (found.value) {
                .direct => |oid| return .{ .name = current, .oid = oid, .from_packed = found.from_packed },
                .symbolic => |target| {
                    gpa.free(current);
                    current = target;
                },
            }
        }
    }

    /// The object `name` resolves to, or `null` when the chain ends at a
    /// name that is not there: git's `refs_read_ref`.
    pub fn readOid(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Oid {
        const resolved = (try store.resolve(gpa, io, name)) orelse return null;
        gpa.free(resolved.name);
        return resolved.oid;
    }

    /// What `HEAD` points at, resolved.
    pub fn head(store: *const Store, gpa: Allocator, io: Io) ReadError!?Resolved {
        return store.resolve(gpa, io, "HEAD");
    }

    /// The branch `HEAD` is on, without `refs/heads/`, or `null` when `HEAD`
    /// is detached. The result is the caller's.
    pub fn currentBranch(store: *const Store, gpa: Allocator, io: Io) ReadError!?[]u8 {
        const found = (if (store.refFormat() == .reftable)
            try store.read(gpa, io, "HEAD")
        else
            try store.readLoose(gpa, io, "HEAD")) orelse return null;
        switch (found) {
            .direct => return null,
            .symbolic => |target| {
                defer gpa.free(target);
                if (!std.mem.startsWith(u8, target, "refs/heads/")) return null;
                return try gpa.dupe(u8, target["refs/heads/".len..]);
            },
        }
    }

    /// A list of refs, loose entries shadowing packed ones.
    pub const Listing = value_mod.Listing;

    /// Every ref whose name begins with `prefix`, sorted by name.
    ///
    /// A loose ref shadows a packed one of the same name, which is what git
    /// does and what makes a `pack-refs` that has not yet removed the loose
    /// file harmless. What is found and is no ref git would read -- a name
    /// no ref may have, a file that holds no ref -- is in `broken`, as git's
    /// listing marks it `REF_ISBROKEN`, and shadows a packed ref of its
    /// name just the same.
    pub fn list(store: *const Store, gpa: Allocator, io: Io, prefix: []const u8) ReadError!Listing {
        if (store.refFormat() == .reftable) return stack_engine.list(gpa, io, store, prefix);
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var entries: std.ArrayList(Named) = .empty;
        var broken: std.ArrayList(Broken) = .empty;

        {
            const packed_listing = try store.acquirePacked(io);
            defer store.releasePacked(io);
            // Sorted, so the names under `prefix` are one run.
            const from = std.sort.lowerBound(PackedEntry, packed_listing.entries, prefix, orderPrefix);
            for (packed_listing.entries[from..]) |entry| {
                if (!std.mem.startsWith(u8, entry.name, prefix)) break;
                if (entry.broken) {
                    try broken.append(arena, .{ .name = try arena.dupe(u8, entry.name), .why = badName(entry.name) });
                    continue;
                }
                try entries.append(arena, .{
                    .name = try arena.dupe(u8, entry.name),
                    .target = .{ .direct = entry.oid },
                    .peeled = entry.peeled,
                    .loose = false,
                });
            }
        }

        try store.walkLoose(arena, io, &entries, &broken, prefix);

        std.mem.sort(Named, entries.items, {}, lessThanNamed);
        std.mem.sort(Broken, broken.items, {}, lessThanBroken);
        // A loose entry shadows the packed one beside it, and a broken one
        // shadows either.
        var deduped: std.ArrayList(Named) = .empty;
        var at_broken: usize = 0;
        for (entries.items) |entry| {
            while (at_broken < broken.items.len and std.mem.order(u8, broken.items[at_broken].name, entry.name) == .lt) at_broken += 1;
            if (at_broken < broken.items.len and std.mem.eql(u8, broken.items[at_broken].name, entry.name)) continue;
            if (deduped.items.len != 0) {
                const last = &deduped.items[deduped.items.len - 1];
                if (std.mem.eql(u8, last.name, entry.name)) {
                    if (entry.loose) last.* = entry;
                    continue;
                }
            }
            try deduped.append(arena, entry);
        }
        // A packed entry under a bad name and a loose file of that name are
        // one broken ref.
        var kept: usize = 0;
        for (broken.items) |item| {
            if (kept != 0 and std.mem.eql(u8, broken.items[kept - 1].name, item.name)) continue;
            broken.items[kept] = item;
            kept += 1;
        }

        return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .entries = deduped.items,
            .broken = broken.items[0..kept],
        };
    }

    fn orderPrefix(prefix: []const u8, entry: PackedEntry) std.math.Order {
        return std.mem.order(u8, prefix, entry.name);
    }

    fn lessThanNamed(_: void, a: Named, b: Named) bool {
        const by_name = std.mem.order(u8, a.name, b.name);
        if (by_name != .eq) return by_name == .lt;
        // A loose entry sorts after the packed one of the same name so the
        // deduplication above keeps the loose one.
        return !a.loose and b.loose;
    }

    /// The loose refs under `refs/`. In a linked worktree that is the
    /// shared directory's, less the per-worktree refs there, which are the
    /// main worktree's, and this worktree's own per-worktree refs from its
    /// directory: where git's files backend finds each.
    fn walkLoose(
        store: *const Store,
        arena: Allocator,
        io: Io,
        out: *std.ArrayList(Named),
        broken: *std.ArrayList(Broken),
        prefix: []const u8,
    ) ReadError!void {
        const linked = store.gitDir().handle != store.commonDir().handle;
        try store.walkLooseIn(arena, io, store.commonDir(), "refs", out, broken, prefix, linked);
        if (!linked) return;
        for (per_worktree_folders) |folder| {
            try store.walkLooseIn(arena, io, store.gitDir(), folder, out, broken, prefix, false);
        }
    }

    /// The folders under `refs/` each worktree keeps for itself.
    const per_worktree_folders = [_][]const u8{ "refs/bisect", "refs/worktree", "refs/rewritten" };

    fn walkLooseIn(
        store: *const Store,
        arena: Allocator,
        io: Io,
        dir: Io.Dir,
        folder: []const u8,
        out: *std.ArrayList(Named),
        broken: *std.ArrayList(Broken),
        prefix: []const u8,
        skip_per_worktree: bool,
    ) ReadError!void {
        if (!overlaps(folder, prefix)) return;
        var sub = dir.openDir(io, folder, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => |e| return e,
        };
        defer sub.close(io);
        try store.walkLooseDir(arena, io, sub, folder, out, broken, prefix, skip_per_worktree, 0);
    }

    /// Whether the refs under `folder` can begin with `prefix`: one of the
    /// two leads to the other.
    fn overlaps(folder: []const u8, prefix: []const u8) bool {
        if (std.mem.startsWith(u8, prefix, folder)) {
            return prefix.len == folder.len or prefix[folder.len] == '/';
        }
        return std.mem.startsWith(u8, folder, prefix);
    }

    fn walkLooseDir(
        store: *const Store,
        arena: Allocator,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        out: *std.ArrayList(Named),
        broken: *std.ArrayList(Broken),
        prefix: []const u8,
        skip_per_worktree: bool,
        depth: u8,
    ) ReadError!void {
        if (depth > 32) return;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            // `<ref>.lock` is a lock file, not a ref. It is skipped rather
            // than read, and a caller that wants to know one is there asks
            // `fs.staleReport`.
            if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
            const child_path = try arena.print("{s}/{s}", .{ path, entry.name });
            if (entry.kind == .directory) {
                if (skip_per_worktree and depth == 0 and isPerWorktreeFolder(child_path)) continue;
                if (!overlaps(child_path, prefix)) continue;
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => continue,
                    else => |e| return e,
                };
                defer sub.close(io);
                try store.walkLooseDir(arena, io, sub, child_path, out, broken, prefix, false, depth + 1);
                continue;
            }
            if (!std.mem.startsWith(u8, child_path, prefix)) continue;
            if (!isRefName(child_path)) {
                try broken.append(arena, .{ .name = child_path, .why = badName(child_path) });
                continue;
            }
            const target = (store.readLooseAt(arena, io, dir, entry.name) catch |err| switch (err) {
                error.MalformedRef => {
                    try broken.append(arena, .{ .name = child_path, .why = .bad_content });
                    continue;
                },
                else => |e| return e,
            }) orelse continue;
            // An object name of zeros is no object, which git takes for a
            // damaged ref.
            if (target == .direct and target.direct.isZero()) {
                try broken.append(arena, .{ .name = child_path, .why = .bad_content });
                continue;
            }
            try out.append(arena, .{ .name = child_path, .target = target, .loose = true });
        }
    }

    fn isPerWorktreeFolder(path: []const u8) bool {
        for (per_worktree_folders) |folder| {
            if (std.mem.eql(u8, path, folder)) return true;
        }
        return false;
    }

    /// One line of `packed-refs`.
    pub const PackedEntry = packed_cache.Entry;

    /// Everything `packed-refs` holds, sorted by name.
    pub const PackedListing = packed_cache.Listing;

    /// Read `packed-refs` now, into a listing the caller owns. An absent
    /// file is an empty listing. `read` and `list` go through the store's
    /// snapshot of the file instead, which they check with a stat.
    pub fn readPacked(store: *const Store, gpa: Allocator, io: Io) ReadError!PackedListing {
        return packed_cache.read(gpa, io, store.commonDir(), store.objectFormat());
    }

    /// Parse `packed-refs` bytes this takes ownership of, including on error.
    pub fn parsePacked(gpa: Allocator, kind: Kind, bytes: []u8) ReadError!PackedListing {
        return packed_cache.parse(gpa, kind, bytes);
    }

    /// The store's snapshot of `packed-refs`, brought up to date, with its
    /// mutex held: give it back with `releasePacked`.
    fn acquirePacked(store: *const Store, io: Io) ReadError!*const PackedListing {
        const c = state_mod.get(store._state).packed_refs.?;
        c.mutex.lock(io) catch return error.Canceled;
        errdefer c.mutex.unlock(io);
        return c.refresh(io, store.commonDir(), store.objectFormat());
    }

    fn releasePacked(store: *const Store, io: Io) void {
        state_mod.get(store._state).packed_refs.?.mutex.unlock(io);
    }

    /// The object `packed-refs` names for `name`, or `null`.
    fn readPackedOne(store: *const Store, io: Io, name: []const u8) ReadError!?Oid {
        const listing = try store.acquirePacked(io);
        defer store.releasePacked(io);
        const entry = listing.find(name) orelse return null;
        return entry.oid;
    }

    /// Write `packed-refs` from `entries`, which must be sorted by name.
    ///
    /// The header is exact, including the space before its newline, because
    /// git compares it when it decides whether every tag in the file is
    /// already peeled.
    pub fn writePacked(store: *const Store, io: Io, entries: []const PackedEntry) TransactionError!void {
        var buffer: [64 * 1024]u8 = undefined;
        var lock = try store.lockPacked(io, &buffer);
        defer lock.deinit(io);
        try store.writePackedLocked(io, &lock, entries);
    }

    /// Take `packed-refs.lock`, waiting as `core.packedRefsTimeout` says.
    fn lockPacked(store: *const Store, io: Io, buffer: []u8) TransactionError!fs.LockFile {
        const data = state_mod.get(store._state);
        return fs.LockFile.open(data.gpa, io, store.commonDir(), .{ .sub_path = "packed-refs", .buffer = buffer }, .{
            .shared = store.sharedPermissions(),
            .sync = store.referenceSync(),
            .on_contention = data.packed_lock,
        });
    }

    /// Write `entries` through a `packed-refs.lock` already held, and
    /// install it.
    fn writePackedLocked(store: *const Store, io: Io, lock: *fs.LockFile, entries: []const PackedEntry) TransactionError!void {
        const w = lock.writer();
        w.writeAll(packed_header) catch return error.WriteFailed;
        var hex: [hash.max_hex_len]u8 = undefined;
        for (entries) |entry| {
            w.print("{s} {s}\n", .{ entry.oid.hex(&hex), entry.name }) catch return error.WriteFailed;
            if (entry.peeled) |peeled| {
                w.print("^{s}\n", .{peeled.hex(&hex)}) catch return error.WriteFailed;
            }
        }
        try lock.commit(io);
        // The stat would tell the next lookup as much; this is cheaper.
        if (state_mod.get(store._state).packed_refs) |c| c.forget(io);
    }

    /// Begin a transaction over this store.
    pub fn begin(store: *Store, gpa: Allocator) Transaction {
        return .{ .store = store, .gpa = gpa, .edits = .empty };
    }

    /// Whether `name` has a log, in whichever format the refs are kept.
    pub fn logExists(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!bool {
        if (store.refFormat() == .reftable) return stack_engine.logExists(gpa, io, store, name);
        const where = names.parseWorktreeRef(name);
        if (where.owner == .other) {
            var admin = (try store.openWorktree(io, name, where)) orelse return false;
            defer admin.close(io);
            return reflog.exists(gpa, io, admin, where.bare);
        }
        return reflog.exists(gpa, io, store.logDir(name, where), where.bare);
    }

    /// The directory whose `logs/` holds the log of `name`, a ref of this
    /// worktree's, a shared one or the main worktree's.
    fn logDir(store: *const Store, name: []const u8, where: names.WorktreeRef) Io.Dir {
        return if (where.owner == .main) store.commonDir() else store.dirFor(name);
    }

    /// The administrative directory of the linked worktree `name` reaches,
    /// `worktrees/<id>`, opened, or `null` when there is no such worktree.
    fn openWorktree(store: *const Store, io: Io, name: []const u8, where: names.WorktreeRef) Io.Dir.OpenError!?Io.Dir {
        return store.commonDir().openDir(io, name[0 .. name.len - where.bare.len], .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => |e| e,
        };
    }

    pub const AppendInputs = value_mod.AppendInputs;

    /// Append one entry to a ref's log without moving the ref, where
    /// `log.policy` asks for one: a line of `logs/<ref>`, or in a reftable
    /// repository a table of its own, which is where git would look for
    /// it. The message is collapsed as a transaction's is.
    pub fn appendLog(store: *const Store, gpa: Allocator, io: Io, inputs: AppendInputs, log: LogMessage) TransactionError!void {
        const name = inputs.name;
        const old = inputs.old;
        const new = inputs.new;
        if (!isRefName(name)) return error.InvalidRefName;
        try ownWorktree(name);
        if (!reflog.shouldLog(log.policy, name, try store.logExists(gpa, io, name))) return;
        if (store.refFormat() == .reftable) return stack_engine.appendLog(gpa, io, store, .{ .name = name, .old = old, .new = new }, .{ .who = log.who, .message = log.message });
        // The message a transaction would write: collapsed as git collapses it.
        const text = try reflog.normalizeMessage(gpa, log.message);
        defer gpa.free(text);
        return reflog.append(gpa, io, store.dirFor(name), .{ .ref = name, .old = old, .new = new, .who = log.who, .message = text, .shared = store.sharedPermissions(), .sync = store.referenceSync() });
    }

    /// Errors from `readLog`.
    pub const ReadLogError = ReadError || LogReadError;

    /// A ref's log, oldest first, from `logs/<ref>` or from the reftable
    /// stack as the format says. An absent log is an empty one.
    pub fn readLog(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadLogError!Log {
        if (store.refFormat() == .reftable) return stack_engine.readLog(gpa, io, store, name);
        const where = names.parseWorktreeRef(name);
        if (where.owner == .other) {
            // A worktree that is not there has no log, which is an empty one.
            var admin = (try store.openWorktree(io, name, where)) orelse
                return .{ .gpa = gpa, .bytes = try gpa.alloc(u8, 0), .entries = try gpa.alloc(reflog.Entry, 0) };
            defer admin.close(io);
            return reflog.read(gpa, io, admin, where.bare, store.objectFormat());
        }
        return reflog.read(gpa, io, store.logDir(name, where), where.bare, store.objectFormat());
    }

    /// Start a log for `name` where it has none, so that its next update is
    /// logged under any policy, as git's `refs_create_reflog` does: an
    /// empty `logs/<ref>`, or in a reftable stack the entry git writes to
    /// say a log exists.
    pub fn createLog(store: *const Store, gpa: Allocator, io: Io, name: []const u8) TransactionError!void {
        if (!isRefName(name)) return error.InvalidRefName;
        try ownWorktree(name);
        if (store.refFormat() == .reftable) return stack_engine.createLog(gpa, io, store, name);
        return reflog.create(gpa, io, store.dirFor(name), name, store.sharedPermissions());
    }

    /// How `expireLog` treats the entries it keeps.
    pub const ExpireOptions = value_mod.ExpireOptions;

    /// Errors from `expireLog`.
    pub const ExpireLogError = TransactionError || LogReadError;

    /// Keep only the entries of `name`'s log that `keeper.keep(entry, nth)`
    /// says to, as git's `refs_reflog_expire` does for `git reflog expire`
    /// and `git reflog delete`; `nth` is how far back the entry is, `0` the
    /// newest, which is what `<ref>@{n}` counts. `keeper` is a pointer to
    /// anything with that method, which may keep what it learns. A ref
    /// without a log is left alone.
    ///
    /// The log and the ref move together: under the ref's lock in the files
    /// format, as one table in a reftable stack. Like git's, it runs no
    /// `reference-transaction` hook and writes no log entry of its own.
    pub fn expireLog(
        store: *const Store,
        gpa: Allocator,
        io: Io,
        keeper: anytype,
        options: ExpireOptions,
    ) ExpireLogError!void {
        const name = options.name;
        if (!isRefName(name)) return error.InvalidRefName;
        try ownWorktree(name);
        if (store.refFormat() == .reftable) return stack_engine.expireLog(gpa, io, store, keeper, options);
        const dir = store.dirFor(name);
        if (std.Io.Dir.path.dirnamePosix(name)) |parent| {
            fs.makeDirs(io, dir, parent, store.sharedPermissions()) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
        }
        // git's `files_reflog_expire` takes the ref's lock first, which every
        // transaction moving the ref or appending to its log also takes.
        var buffer: [max_loose_ref]u8 = undefined;
        var lock = try fs.LockFile.open(gpa, io, dir, .{ .sub_path = name, .buffer = &buffer }, .{ .shared = store.sharedPermissions(), .sync = store.referenceSync() });
        defer lock.deinit(io);
        const newest = try reflog.expire(gpa, io, dir, keeper, .{ .ref = name, .kind = store.objectFormat(), .shared = store.sharedPermissions(), .sync = store.referenceSync(), .rewrite = options.rewrite });
        if (!options.update_ref) return;
        const oid = newest orelse return;
        if (try store.readLoose(gpa, io, name)) |own| switch (own) {
            .direct => {},
            .symbolic => |target| {
                gpa.free(target);
                return;
            },
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        lock.writer().print("{s}\n", .{oid.hex(&hex)}) catch return error.WriteFailed;
        try lock.commit(io);
    }

    /// Remove `name`'s log and every entry in it, as git's
    /// `refs_delete_reflog` does, without touching the ref. A ref without a
    /// log is left alone.
    pub fn deleteLog(store: *const Store, gpa: Allocator, io: Io, name: []const u8) TransactionError!void {
        if (!isRefName(name)) return error.InvalidRefName;
        try ownWorktree(name);
        if (store.refFormat() == .reftable) return stack_engine.deleteLog(gpa, io, store, name);
        const dir = store.dirFor(name);
        try reflog.delete(gpa, io, dir, name);
        const path = try reflog.pathFor(gpa, name);
        defer gpa.free(path);
        removeEmptyParents(io, dir, path);
    }

    /// The root refs of the worktree this store was opened in:
    /// `ORIG_HEAD`, `CHERRY_PICK_HEAD` and the rest of `names.Root`.
    pub fn root(store: *Store) RootRefs {
        return .{ .store = store };
    }

    /// `FETCH_HEAD` and `MERGE_HEAD`: files in the worktree's git
    /// directory whatever the ref format.
    pub fn special(store: *Store) SpecialRefs {
        return .{ .store = store };
    }

    /// Delete every ref `refs` names in one transaction, as git's
    /// `refs_delete_refs` does: each name need only be one `names.isSafe`
    /// takes, which is how a ref listed with a bad name goes, and a name
    /// that is not refuses the whole transaction before anything moves.
    /// Each ref goes itself, not a ref it names. A ref that is not there
    /// is no error.
    pub fn deleteRefs(store: *Store, gpa: Allocator, io: Io, refs: []const []const u8, log: ?LogMessage) TransactionError!void {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        for (refs) |name| try tx.change(name, null, .any, .{ .no_deref = true });
        try tx.commit(io, log);
    }

    /// One of a new repository's first refs: a full name under `refs/`,
    /// the object, and what it peels to when it is an annotated tag.
    pub const Initial = struct {
        name: []const u8,
        oid: Oid,
        peeled: ?Oid = null,
    };

    /// Write `refs`, none of which the store has yet, in one step and with
    /// no logs: git's initial ref transaction, which a clone makes of the
    /// refs it fetched. The files format writes them into `packed-refs`
    /// under its lock, as git does, beside any packed ref already there;
    /// a reftable writes them as one table. A name the store already has,
    /// loose or packed or in a table, is `RefAlreadyExists`, and a name
    /// twice `DuplicateEdit`; either way nothing is written. Every name is
    /// one the worktrees share.
    pub fn writeInitial(store: *Store, gpa: Allocator, io: Io, refs: []const Initial) TransactionError!void {
        if (refs.len == 0) return;
        for (refs) |ref| {
            if (!names.checkFormat(ref.name, .{}) or names.parseWorktreeRef(ref.name).owner != .shared) return error.InvalidRefName;
        }
        const sorted = try gpa.dupe(Initial, refs);
        defer gpa.free(sorted);
        std.mem.sort(Initial, sorted, {}, lessThanInitial);
        for (1..sorted.len) |i| {
            if (std.mem.eql(u8, sorted[i - 1].name, sorted[i].name)) return error.DuplicateEdit;
        }
        if (store.refFormat() == .reftable) return stack_engine.writeInitial(gpa, io, store, sorted);

        var buffer: [64 * 1024]u8 = undefined;
        var lock = try store.lockPacked(io, &buffer);
        defer lock.deinit(io);
        var existing = try store.readPacked(gpa, io);
        defer existing.deinit();
        for (sorted) |ref| {
            if (existing.find(ref.name) != null) return error.RefAlreadyExists;
            const loose = (try store.readLoose(gpa, io, ref.name)) orelse continue;
            if (loose == .symbolic) gpa.free(loose.symbolic);
            return error.RefAlreadyExists;
        }
        // Both sorted: one merge.
        const merged = try gpa.alloc(PackedEntry, existing.entries.len + sorted.len);
        defer gpa.free(merged);
        var i: usize = 0;
        var j: usize = 0;
        for (merged) |*slot| {
            const take_new = j < sorted.len and (i == existing.entries.len or std.mem.order(u8, sorted[j].name, existing.entries[i].name) == .lt);
            if (take_new) {
                slot.* = .{ .name = sorted[j].name, .oid = sorted[j].oid, .peeled = sorted[j].peeled };
                j += 1;
            } else {
                slot.* = existing.entries[i];
                i += 1;
            }
        }
        try store.writePackedLocked(io, &lock, merged);
    }

    fn lessThanInitial(_: void, a: Initial, b: Initial) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    /// A ref's own value and whether it came from `packed-refs`, with no
    /// check of its name: what a transaction reads of a ref it deletes,
    /// whose name need only be safe.
    fn readUnchecked(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Found {
        const where = names.parseWorktreeRef(name);
        const own = switch (where.owner) {
            .current, .shared => if (store.refFormat() == .reftable)
                if (names.isSpecial(name))
                    try store.readLoose(gpa, io, name)
                else
                    try stack_engine.read(gpa, io, store, name)
            else
                try store.readLoose(gpa, io, name),
            // What another worktree keeps for itself, which the files
            // format never packs: its `HEAD` and root refs, its
            // per-worktree refs.
            .main, .other => if (where.bare.len == 0)
                null
            else if (store.refFormat() == .reftable)
                try stack_engine.readOtherWorktree(gpa, io, store, where)
            else
                // `worktrees/<id>/<name>` is that worktree's file under the
                // shared directory, path for path.
                try store.readLooseAt(gpa, io, store.commonDir(), if (where.owner == .main) where.bare else name),
        };
        if (own) |value| return .{ .value = value, .from_packed = false };
        if (store.refFormat() == .files and (where.owner == .current or where.owner == .shared)) {
            if (try store.readPackedOne(io, name)) |oid| return .{ .value = .{ .direct = oid }, .from_packed = true };
        }
        return null;
    }
};

/// The root refs of one worktree, as git's commands keep them: each
/// written, read and removed as itself, never through a symbolic ref it
/// might be (git's `REF_NO_DEREF`), and with no log. Through the store,
/// so a reftable repository keeps them in its tables.
pub const RootRefs = struct {
    store: *Store,
    /// The hooks to tell of each change, as a transaction's `hooks`, or
    /// `null` to tell none.
    hooks: ?*hooks.Runner = null,

    /// The object `ref` points at, or `null` when it is not there.
    pub fn read(r: RootRefs, gpa: Allocator, io: Io, ref: names.Root) ReadError!?Oid {
        return r.store.readOid(gpa, io, ref.name());
    }

    /// Whether `ref` is there, as git's `ref_exists` asks: one that
    /// cannot be read is not.
    pub fn exists(r: RootRefs, gpa: Allocator, io: Io, ref: names.Root) bool {
        return (r.read(gpa, io, ref) catch return false) != null;
    }

    /// Point `ref` at `oid`, whatever it was.
    pub fn write(r: RootRefs, gpa: Allocator, io: Io, ref: names.Root, oid: Oid) TransactionError!void {
        var tx = r.store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = r.hooks;
        try tx.change(ref.name(), .{ .direct = oid }, .any, .{ .no_deref = true });
        try tx.commit(io, null);
    }

    /// Remove `ref`, which need not be there.
    pub fn delete(r: RootRefs, gpa: Allocator, io: Io, ref: names.Root) TransactionError!void {
        var tx = r.store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = r.hooks;
        try tx.change(ref.name(), null, .any, .{ .no_deref = true });
        try tx.commit(io, null);
    }

    /// Every root ref of the worktree, `HEAD` among them, sorted by name:
    /// what git's `--include-root-refs` adds to a listing. The files
    /// format finds them as files in the git directory, and reftable in
    /// the worktree's stack. One that cannot be read is in `broken`.
    pub fn list(r: RootRefs, gpa: Allocator, io: Io) ReadError!Store.Listing {
        const store = r.store;
        if (store.refFormat() == .reftable) {
            var all = try stack_engine.list(gpa, io, store, "");
            errdefer all.deinit();
            var kept: usize = 0;
            for (all.entries) |entry| {
                if (!names.isRootRef(entry.name)) continue;
                all.entries[kept] = entry;
                kept += 1;
            }
            all.entries = all.entries[0..kept];
            // Every name a root ref has is one a ref may have.
            all.broken = all.broken[0..0];
            return all;
        }
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var entries: std.ArrayList(Named) = .empty;
        var broken: std.ArrayList(Broken) = .empty;
        var it = store.gitDir().iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !names.isRootRef(entry.name)) continue;
            const name = try arena.dupe(u8, entry.name);
            const target = (store.readLoose(arena, io, name) catch |err| switch (err) {
                error.MalformedRef => {
                    try broken.append(arena, .{ .name = name, .why = .bad_content });
                    continue;
                },
                else => |e| return e,
            }) orelse continue;
            try entries.append(arena, .{ .name = name, .target = target, .loose = true });
        }
        std.mem.sort(Named, entries.items, {}, Store.lessThanNamed);
        std.mem.sort(Broken, broken.items, {}, lessThanBroken);
        return .{ .gpa = gpa, .arena = arena_instance.state, .entries = entries.items, .broken = broken.items };
    }
};

/// The special refs of one worktree, `FETCH_HEAD` and `MERGE_HEAD`: files
/// in its git directory in either ref format, which hold a line for each
/// object they name and which no transaction writes (git's
/// `is_special_ref`).
pub const SpecialRefs = struct {
    store: *Store,

    /// The largest special ref read whole.
    pub const max_bytes = 1 << 26;

    /// The first object `ref` names, which is what reading it as a ref
    /// gives (git's `refs_read_special_head`), or `null`.
    pub fn read(s: SpecialRefs, gpa: Allocator, io: Io, ref: names.Special) ReadError!?Oid {
        return s.store.readOid(gpa, io, ref.name());
    }

    /// Everything `ref` holds, every line, or `null` when it is not
    /// there. The bytes are the caller's.
    pub fn readAll(s: SpecialRefs, gpa: Allocator, io: Io, ref: names.Special) Io.Dir.ReadFileAllocError!?[]u8 {
        return fs.readFileAlloc(gpa, io, s.store.gitDir(), ref.name(), max_bytes);
    }

    /// Whether `ref` is there, as git's `file_exists` asks.
    pub fn exists(s: SpecialRefs, io: Io, ref: names.Special) bool {
        s.store.gitDir().access(io, ref.name(), .{}) catch return false;
        return true;
    }

    /// Replace `ref` with `bytes` whole, through `<ref>.lock`, so a reader
    /// sees the old file or the new one; with the permissions
    /// `core.sharedRepository` asks for, and no sync, as git writes it.
    pub fn write(s: SpecialRefs, gpa: Allocator, io: Io, ref: names.Special, bytes: []const u8) TransactionError!void {
        var buffer: [4096]u8 = undefined;
        var lock = try s.takeLock(gpa, io, ref, &buffer);
        defer lock.deinit(io);
        lock.writer().writeAll(bytes) catch return error.WriteFailed;
        try lock.commit(io);
    }

    /// Add `bytes` after what `ref` holds, read under the same lock the
    /// whole is then replaced through, so two writers appending at once
    /// each keep the other's lines: `git fetch --append`.
    pub fn append(s: SpecialRefs, gpa: Allocator, io: Io, ref: names.Special, bytes: []const u8) TransactionError!void {
        var buffer: [4096]u8 = undefined;
        var lock = try s.takeLock(gpa, io, ref, &buffer);
        defer lock.deinit(io);
        if (try s.readAll(gpa, io, ref)) |existing| {
            defer gpa.free(existing);
            lock.writer().writeAll(existing) catch return error.WriteFailed;
        }
        lock.writer().writeAll(bytes) catch return error.WriteFailed;
        try lock.commit(io);
    }

    /// `<ref>.lock`, waiting as long as git waits on a ref's lock.
    fn takeLock(s: SpecialRefs, gpa: Allocator, io: Io, ref: names.Special, buffer: []u8) TransactionError!fs.LockFile {
        return fs.LockFile.open(gpa, io, s.store.gitDir(), .{ .sub_path = ref.name(), .buffer = buffer }, .{
            .on_contention = .{ .wait_ms = 100 },
            .sync = .none,
            .shared = s.store.sharedPermissions(),
        });
    }

    /// Remove `ref`, which need not be there.
    pub fn delete(s: SpecialRefs, io: Io, ref: names.Special) Io.Dir.DeleteFileError!void {
        s.store.gitDir().deleteFile(io, ref.name()) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        };
    }
};

fn lessThanBroken(_: void, a: Broken, b: Broken) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// The longest loose ref file read whole: a symbolic one, `ref: <name>`.
const max_loose_ref = 4096;

/// What `create` lays down.
pub const CreateOptions = struct {
    /// The directory is a linked worktree's, whose shared refs are the
    /// repository's: it gets no `refs/heads` or `refs/tags` of its own.
    worktree: bool = false,
    /// What `core.sharedRepository` asks of the permissions of what is
    /// made.
    shared: fs.Shared = .umask,
};

/// Errors from `create`.
pub const CreateError = @import("value.zig").CreateError;

/// Lay down what a ref store in `format` needs in a new git directory
/// before its first ref, as git's `ref_store_create_on_disk` does. The
/// files format makes `refs/`, and outside a linked worktree `refs/heads`
/// and `refs/tags`. A reftable makes its `reftable/` directory and, so
/// that a reader of the files format stops rather than misreads, a `HEAD`
/// naming a branch no one can create and a file `refs/heads` saying why.
/// The first ref, `HEAD`, is then a transaction's to write, through a
/// store opened over the directory.
pub fn create(io: Io, git_dir: Io.Dir, format: Format, options: CreateOptions) CreateError!void {
    switch (format) {
        .files => {
            try makeDir(io, git_dir, "refs", options.shared);
            if (options.worktree) return;
            try makeDir(io, git_dir, "refs/heads", options.shared);
            try makeDir(io, git_dir, "refs/tags", options.shared);
        },
        .reftable => {
            try makeDir(io, git_dir, "reftable", options.shared);
            try git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/.invalid\n" });
            fs.adjustShared(io, git_dir, "HEAD", options.shared);
            try makeDir(io, git_dir, "refs", options.shared);
            try git_dir.writeFile(io, .{ .sub_path = "refs/heads", .data = "this repository uses the reftable format\n" });
            fs.adjustShared(io, git_dir, "refs/heads", options.shared);
        },
    }
}

fn makeDir(io: Io, dir: Io.Dir, sub_path: []const u8, shared: fs.Shared) Io.Dir.CreateDirPathError!void {
    fs.makeDirs(io, dir, sub_path, shared) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

/// Whether a transaction may change `name`: git's
/// `transaction_refname_valid`. Never a special ref, which is a file no
/// transaction owns. A new value only under a name `names.checkFormat`
/// takes, and beyond git a name of one level only when it is spelled as a
/// root ref: git writes `index`, `config` or `shallow` as a ref when a
/// stream names it, over the files of those names. A deletion under any
/// name `names.isSafe` takes, which is how a ref listed with a bad name is
/// removed.
fn isChangeableName(name: []const u8, deleting: bool) bool {
    if (names.isSpecial(name)) return false;
    if (deleting) return names.isSafe(name);
    if (!names.checkFormat(name, .{ .allow_onelevel = true })) return false;
    return std.mem.findScalar(u8, name, '/') != null or names.isRootRefSyntax(name);
}

/// Why a name found on the disk is no ref's: one git's
/// `refname_is_safe` still takes, or one that reaches out of the ref
/// directories.
fn badName(name: []const u8) Broken.Why {
    return if (names.isSafe(name)) .bad_name else .unsafe_name;
}

/// A name a ref can be read or written under: git's
/// `check_refname_format` with `REFNAME_ALLOW_ONELEVEL`.
/// Refuse a name that reaches another worktree's own refs,
/// `main-worktree/<name>` or `worktrees/<id>/<name>`: read from any
/// worktree, and written, ref or log, by a store opened in that one.
fn ownWorktree(name: []const u8) error{OtherWorktreeRef}!void {
    switch (names.parseWorktreeRef(name).owner) {
        .current, .shared => {},
        .main, .other => return error.OtherWorktreeRef,
    }
}

fn isRefName(name: []const u8) bool {
    return names.checkFormat(name, .{ .allow_onelevel = true });
}

/// What a log entry a transaction writes says.
pub const LogMessage = @import("value.zig").LogMessage;
const config_mod = @import("../config/config.zig");

/// A set of ref updates applied together.
///
/// `prepare` takes every lock; if any is held the whole thing rolls back and
/// nothing on the disk has changed. `commit` then installs each new value and
/// appends each log line. Those renames and appends are separate filesystem
/// operations, so a commit-time error is indeterminate and may have installed
/// a prefix; reread the affected refs before retrying.
///
/// An update or a deletion goes through a symbolic ref to the ref at the end
/// of it, as git's does unless told `--no-deref`: moving `HEAD` while it
/// names `refs/heads/main` moves `refs/heads/main`, and both logs record it.
/// Moving the branch `HEAD` names, by its own name, records it in `HEAD`'s
/// log as well, because that is also what `HEAD` did. `EditOptions.no_deref`
/// changes the named ref itself, which is how `HEAD` is detached. A symbolic
/// new value always changes the named ref, as `git symbolic-ref` does.
///
/// With `hooks` set, `reference-transaction` is told about the transaction
/// the way git tells it about every one: `preparing` before any lock is
/// taken, `prepared` once every lock is held and checked, then `committed`
/// or `aborted`. A hook that fails in either of the first two refuses the
/// transaction, which then rolls back as it would for a held lock.
pub const Transaction = struct {
    pub const Error = ErrorNamespace.Error;

    store: *Store,
    gpa: Allocator,
    edits: std.ArrayList(Edit),
    prepared: bool = false,
    finished: bool = false,
    /// The hooks to run, or `null` to run none.
    hooks: ?*hooks.Runner = null,
    /// Whether `preparing` has been announced, which is what makes giving
    /// up announce `aborted`.
    announced: bool = false,
    /// Whether the deletions' `packed-refs` step has been announced as
    /// prepared and is owed its end.
    packed_announced: bool = false,
    /// Peels a new value that is an annotated tag, for a reftable to record
    /// beside it. `null` records the tag alone, which git reads as well.
    peeler: ?Peeler = null,
    /// What `prepare` took in a reftable repository.
    reftable: ?*stack_engine.Pending = null,
    /// `packed-refs.lock`, held from `prepare` to the end when a deletion
    /// removes a packed ref, as git holds it, and `packed-refs` as read
    /// under it: a concurrent `pack-refs` cannot slip a ref in between the
    /// read and the write.
    packed_lock: ?fs.LockFile = null,
    packed_lock_buffer: []u8 = &.{},
    packed_listing: ?Store.PackedListing = null,

    /// One ref's change.
    pub const Edit = value_mod.Edit;

    /// How one edit treats a symbolic ref.
    pub const EditOptions = struct {
        /// Change the named ref itself even when it is symbolic, rather than
        /// the ref it names: git's `--no-deref`.
        no_deref: bool = false,
        /// The text of this edit's log line, in place of the message
        /// `commit` is given, whose `who` and `policy` still apply: how one
        /// transaction logs each ref in its own words, as git's atomic
        /// fetch does. Collapsed as `commit`'s is.
        message: ?[]const u8 = null,
    };

    /// Release the transaction, rolling back anything `prepare` took.
    pub fn deinit(tx: *Transaction, io: Io) void {
        tx.abort(io);
        for (tx.edits.items) |edit| {
            tx.gpa.free(edit.name);
            if (edit.message) |m| tx.gpa.free(m);
            if (edit.new) |new| switch (new) {
                .symbolic => |target| tx.gpa.free(target),
                .direct => {},
            };
        }
        tx.edits.deinit(tx.gpa);
        tx.* = undefined;
    }

    /// Point `name` at `new`, whatever it is now.
    pub fn update(tx: *Transaction, name: []const u8, new: Ref, expected: Expected) TransactionError!void {
        try tx.change(name, new, expected, .{});
    }

    /// Create `name`, which must not exist.
    pub fn create(tx: *Transaction, name: []const u8, new: Ref) TransactionError!void {
        try tx.change(name, new, .must_not_exist, .{});
    }

    /// Remove `name`.
    pub fn delete(tx: *Transaction, name: []const u8, expected: Expected) TransactionError!void {
        try tx.change(name, null, expected, .{});
    }

    /// Point `name` at `new`, or remove it when `new` is `null`, with the
    /// choice of whether a symbolic `name` is gone through.
    pub fn change(tx: *Transaction, name: []const u8, new: ?Ref, expected: Expected, options: EditOptions) TransactionError!void {
        try tx.add(name, new, expected);
        const added = &tx.edits.items[tx.edits.items.len - 1];
        added.deref = !options.no_deref;
        if (options.message) |m| added.message = try tx.gpa.dupe(u8, m);
    }

    fn add(tx: *Transaction, name: []const u8, new: ?Ref, expected: Expected) TransactionError!void {
        if (!isChangeableName(name, new == null)) return error.InvalidRefName;
        try ownWorktree(name);
        for (tx.edits.items) |edit| {
            if (std.mem.eql(u8, edit.name, name)) return error.DuplicateEdit;
        }
        const owned = try tx.gpa.dupe(u8, name);
        errdefer tx.gpa.free(owned);
        if (new) |value| if (value == .symbolic) {
            // git's `check_refname_format` on the target, and its rule that
            // `HEAD` names a ref under `refs/`: a repository whose `HEAD`
            // does not is one git no longer recognises.
            const target = value.symbolic;
            if (!isRefName(target)) return error.InvalidRefName;
            if (std.mem.eql(u8, name, "HEAD") and !std.mem.startsWith(u8, target, "refs/")) return error.InvalidRefName;
        };
        var stored_new: ?Ref = null;
        if (new) |value| {
            stored_new = switch (value) {
                .direct => |oid| .{ .direct = oid },
                .symbolic => |target| .{ .symbolic = try tx.gpa.dupe(u8, target) },
            };
        }
        errdefer if (stored_new) |value| if (value == .symbolic) tx.gpa.free(value.symbolic);
        try tx.edits.append(tx.gpa, .{ .name = owned, .new = stored_new, .expected = expected });
    }

    /// Take every lock and check every expected value.
    ///
    /// On any failure every lock taken so far is given up and the
    /// repository is exactly as it was.
    pub fn prepare(tx: *Transaction, io: Io) TransactionError!void {
        std.debug.assert(!tx.prepared);
        errdefer tx.abort(io);

        if (tx.hooks != null) {
            tx.announced = true;
            try tx.announce(io, .preparing);
        }

        try tx.splitSymbolic(io);
        try tx.lockAndCheck(io);
    }

    /// `prepare` after the edits through symbolic refs are split: nested
    /// names refused, every lock taken and every expected value checked.
    fn lockAndCheck(tx: *Transaction, io: Io) TransactionError!void {
        errdefer tx.abort(io);
        // Two edits whose names nest — `refs/heads/a` and `refs/heads/a/b` —
        // cannot both exist, because one is a file and the other a directory
        // with the same path.
        for (tx.edits.items, 0..) |a, i| {
            if (a.via != null) continue;
            for (tx.edits.items[i + 1 ..]) |b| {
                if (b.via != null) continue;
                if (nests(a.name, b.name)) return error.RefNameConflict;
            }
        }

        if (tx.store.refFormat() == .reftable) {
            // One table under one lock: no `packed-refs` step to announce.
            try stack_engine.prepare(io, tx);
            try tx.checkSplitUnchanged(io);
            if (tx.hooks != null) try tx.announce(io, .prepared);
            tx.prepared = true;
            return;
        }

        for (tx.edits.items) |*edit| {
            const dir = tx.store.dirFor(edit.name);
            if (edit.via == null and edit.new != null) try tx.checkAvailable(io, edit.name);
            if (std.Io.Dir.path.dirnamePosix(edit.name)) |parent| {
                fs.makeDirs(io, dir, parent, tx.store.sharedPermissions()) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
            }
            const buffer = try tx.gpa.alloc(u8, 4096);
            edit.lock_buffer = buffer;
            edit.lock = fs.LockFile.open(tx.gpa, io, dir, .{ .sub_path = edit.name, .buffer = buffer }, .{ .shared = tx.store.sharedPermissions(), .sync = tx.store.referenceSync() }) catch |err| switch (err) {
                error.LockHeld => return error.LockHeld,
                else => |e| return e,
            };
            // A ref only logged through is held, not checked.
            if (edit.via != null) continue;

            // Read without a check of the name, which a deletion need only
            // have safe.
            const current = if (try tx.store.readUnchecked(tx.gpa, io, edit.name)) |found| found.value else null;
            var current_oid: ?Oid = null;
            if (current) |value| {
                switch (value) {
                    .direct => |oid| current_oid = oid,
                    .symbolic => |target| {
                        defer tx.gpa.free(target);
                        // A symbolic ref's own value is not an object name;
                        // an expected-value check on it is a check on what
                        // it resolves to.
                        if (try tx.store.resolve(tx.gpa, io, target)) |resolved| {
                            tx.gpa.free(resolved.name);
                            current_oid = resolved.oid;
                        }
                    },
                }
            }
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
        try tx.checkSplitUnchanged(io);
        try tx.lockPackedForDeletions(io);
        if (tx.hooks != null) {
            // git's files backend removes deleted refs from `packed-refs` in
            // a transaction of its own, which the hook hears about too: it
            // is prepared, and later committed, when a deleted ref is
            // packed, and given up at once when none is.
            if (tx.hasDeletions()) {
                const needed = for (tx.edits.items) |e| {
                    if (e.via == null and e.new == null and e.was_packed) break true;
                } else false;
                if (needed) {
                    try tx.announceAs(io, .preparing, true);
                    tx.packed_announced = true;
                    try tx.announceAs(io, .prepared, true);
                } else {
                    // glint-ignore: Z026 -- as git's run_transaction_hook for an aborted state: the hook's status changes nothing
                    tx.announceAs(io, .aborted, true) catch {};
                }
            }
            try tx.announce(io, .prepared);
        }
        tx.prepared = true;
    }

    /// The symbolic refs `splitSymbolic` went through, read again now that
    /// their locks are held: each still names the next ref of its chain,
    /// and the ref at the end is still not symbolic. git reads them under
    /// their locks; a `HEAD` a concurrent checkout retargeted in between
    /// would otherwise have the branch it left moved.
    fn checkSplitUnchanged(tx: *Transaction, io: Io) TransactionError!void {
        for (tx.edits.items) |e| {
            const own_new_symbolic = if (e.new) |n| n == .symbolic else false;
            if (e.via == null and (!e.deref or own_new_symbolic)) continue;
            const own = try tx.store.readOwnValue(tx.gpa, io, e.name);
            const target = if (own) |value| switch (value) {
                .symbolic => |t| t,
                .direct => null,
            } else null;
            defer if (target) |t| tx.gpa.free(t);
            const at = e.via orelse {
                if (target != null) return error.ExpectedValueMismatch;
                continue;
            };
            const next = target orelse return error.ExpectedValueMismatch;
            const in_chain = std.mem.eql(u8, next, tx.edits.items[at].name) or for (tx.edits.items) |other| {
                if (other.via == at and std.mem.eql(u8, other.name, next)) break true;
            } else false;
            if (!in_chain) return error.ExpectedValueMismatch;
        }
    }

    /// git's `files_transaction_prepare`: a deletion takes
    /// `packed-refs.lock` and reads the file under it, and whether each
    /// deleted ref is in it decides whether the file is rewritten -- a ref
    /// that is loose and packed at once is deleted from both, or the packed
    /// value comes back. When no deleted ref is packed the lock is given up.
    fn lockPackedForDeletions(tx: *Transaction, io: Io) TransactionError!void {
        if (!tx.hasDeletions()) return;
        tx.packed_lock_buffer = try tx.gpa.alloc(u8, 64 * 1024);
        tx.packed_lock = try tx.store.lockPacked(io, tx.packed_lock_buffer);
        tx.packed_listing = try tx.store.readPacked(tx.gpa, io);
        var needed = false;
        for (tx.edits.items) |*edit| {
            if (edit.via != null or edit.new != null) continue;
            edit.was_packed = tx.packed_listing.?.find(edit.name) != null;
            needed = needed or edit.was_packed;
        }
        if (!needed) tx.releasePackedLock(io);
    }

    fn releasePackedLock(tx: *Transaction, io: Io) void {
        if (tx.packed_lock) |*lock| {
            lock.deinit(io);
            tx.packed_lock = null;
        }
        if (tx.packed_listing) |*listing| {
            listing.deinit();
            tx.packed_listing = null;
        }
        if (tx.packed_lock_buffer.len != 0) {
            tx.gpa.free(tx.packed_lock_buffer);
            tx.packed_lock_buffer = &.{};
        }
    }

    /// git's `refs_verify_refname_available`: `name` cannot be written
    /// while a ref exists at one of its parents (`refs/heads/a` for
    /// `refs/heads/a/b`) or below it (`refs/heads/c/d` for
    /// `refs/heads/c`), loose or packed. A ref this transaction also names
    /// is no exception: `prepare` has refused the pair already, as git
    /// refuses to process both at once.
    fn checkAvailable(tx: *Transaction, io: Io, name: []const u8) TransactionError!void {
        const dir = tx.store.dirFor(name);
        var parent = std.Io.Dir.path.dirnamePosix(name);
        while (parent) |p| : (parent = std.Io.Dir.path.dirnamePosix(p)) {
            if (std.mem.findScalar(u8, p, '/') == null) break;
            if (try isLooseFile(io, dir, p)) return error.RefNameConflict;
            if (try tx.store.readPackedOne(io, p) != null) return error.RefNameConflict;
        }
        if (try hasLooseBelow(tx.gpa, io, dir, name)) return error.RefNameConflict;
        const listing = try tx.store.acquirePacked(io);
        defer tx.store.releasePacked(io);
        var folder_buf: [max_loose_ref + 1]u8 = undefined;
        if (name.len + 1 > folder_buf.len) return;
        @memcpy(folder_buf[0..name.len], name);
        folder_buf[name.len] = '/';
        const folder = folder_buf[0 .. name.len + 1];
        const from = std.sort.lowerBound(Store.PackedEntry, listing.entries, folder, Store.orderPrefix);
        if (from < listing.entries.len and std.mem.startsWith(u8, listing.entries[from].name, folder)) return error.RefNameConflict;
    }

    fn hasDeletions(tx: *const Transaction) bool {
        for (tx.edits.items) |e| {
            if (e.via == null and e.new == null) return true;
        }
        return false;
    }

    /// git's `split_symref_update` and `split_head_update`. An edit through
    /// a symbolic ref moves to the ref at the end of the chain, and every
    /// symbolic ref on the way keeps only its log line; a branch `HEAD`
    /// names, moved by its own name, gives `HEAD` a log line too.
    fn splitSymbolic(tx: *Transaction, io: Io) TransactionError!void {
        const given = tx.edits.items.len;
        for (0..given) |i| {
            const e = tx.edits.items[i];
            if (!e.deref) continue;
            if (e.new) |n| if (n == .symbolic) continue;

            var chain: std.ArrayList([]const u8) = .empty;
            defer {
                for (chain.items[1..]) |name| tx.gpa.free(name);
                chain.deinit(tx.gpa);
            }
            try chain.append(tx.gpa, e.name);
            while (true) {
                if (chain.items.len > max_symbolic_depth + 1) return error.SymbolicRefLoop;
                const at = chain.items[chain.items.len - 1];
                const found = (try tx.store.readOwnValue(tx.gpa, io, at)) orelse break;
                switch (found) {
                    .direct => break,
                    .symbolic => |target| {
                        errdefer tx.gpa.free(target);
                        if (!isRefName(target)) return error.InvalidRefName;
                        for (chain.items) |seen| {
                            if (std.mem.eql(u8, seen, target)) return error.SymbolicRefLoop;
                        }
                        try chain.append(tx.gpa, target);
                    },
                }
            }
            if (chain.items.len == 1) continue;

            const final = chain.items[chain.items.len - 1];
            for (tx.edits.items) |other| {
                if (std.mem.eql(u8, other.name, final)) return error.DuplicateEdit;
            }
            const target_at = tx.edits.items.len;
            try tx.edits.append(tx.gpa, .{
                .name = try tx.gpa.dupe(u8, final),
                .new = e.new,
                .expected = e.expected,
            });
            tx.edits.items[i].via = target_at;
            tx.edits.items[i].expected = .any;
            for (chain.items[1 .. chain.items.len - 1]) |middle| {
                for (tx.edits.items) |other| {
                    if (std.mem.eql(u8, other.name, middle)) return error.DuplicateEdit;
                }
                try tx.edits.append(tx.gpa, .{
                    .name = try tx.gpa.dupe(u8, middle),
                    .new = e.new,
                    .expected = .any,
                    .via = target_at,
                });
            }
        }

        // The branch `HEAD` names, moved by its own name.
        for (tx.edits.items) |e| {
            if (std.mem.eql(u8, e.name, "HEAD")) return;
        }
        const head = (try tx.store.readOwnValue(tx.gpa, io, "HEAD")) orelse return;
        const branch = switch (head) {
            .direct => return,
            .symbolic => |target| target,
        };
        defer tx.gpa.free(branch);
        for (tx.edits.items, 0..) |e, i| {
            if (e.via != null or !std.mem.eql(u8, e.name, branch)) continue;
            if (e.new) |n| if (n == .symbolic) return;
            try tx.edits.append(tx.gpa, .{
                .name = try tx.gpa.dupe(u8, "HEAD"),
                .new = e.new,
                .expected = .any,
                .via = i,
            });
            return;
        }
    }

    /// Tell `reference-transaction` where the transaction is. The old value
    /// on each line is the one the edit expected, or zero when it expected
    /// none or any, which is what git writes.
    fn announce(tx: *Transaction, io: Io, state: hooks.Runner.TransactionState) hooks.Error!void {
        return tx.announceAs(io, state, false);
    }

    /// With `packed`, the lines of the `packed-refs` step: one per deleted
    /// ref, with no old value and no new one.
    fn announceAs(tx: *Transaction, io: Io, state: hooks.Runner.TransactionState, packed_step: bool) hooks.Error!void {
        const runner = tx.hooks orelse return;
        var lines: std.ArrayList(hooks.Runner.RefUpdate) = .empty;
        defer lines.deinit(tx.gpa);
        for (tx.edits.items) |edit| {
            // A ref only logged through is not an update of its own, and git
            // leaves it off the hook's lines.
            if (edit.via != null) continue;
            if (packed_step) {
                if (edit.new == null) try lines.append(tx.gpa, .{ .old = null, .new = null, .name = edit.name });
                continue;
            }
            try lines.append(tx.gpa, .{
                .old = switch (edit.expected) {
                    .matches => |oid| .{ .oid = oid },
                    else => null,
                },
                .new = if (edit.new) |new| switch (new) {
                    .direct => |oid| .{ .oid = oid },
                    .symbolic => |target| .{ .symbolic = target },
                } else null,
                .name = edit.name,
            });
        }
        _ = try runner.referenceTransaction(io, tx.store.objectFormat(), state, lines.items);
    }

    /// Write every new value, and append a log line for each where the
    /// policy asks for one. An error after installation begins may leave a
    /// committed prefix; callers must reread every affected ref.
    ///
    /// A deletion also removes the ref from `packed-refs`, because a packed
    /// entry left behind is a ref that comes back, and removes the ref's
    /// log, as git's files backend does: a log with no ref is one a later
    /// ref of the same name would inherit. Directories left empty under
    /// `refs/<kind>/` and `logs/refs/<kind>/` go too.
    pub fn commit(tx: *Transaction, io: Io, log: ?LogMessage) TransactionError!void {
        if (!tx.prepared) try tx.prepare(io);
        std.debug.assert(!tx.finished);

        if (tx.store.refFormat() == .reftable) {
            try stack_engine.commit(io, tx, log);
            tx.finished = true;
            tx.releaseLocks(io);
            // glint-ignore: Z026 -- the refs have moved; as git, a hook failing on "committed" changes nothing
            if (tx.announced) tx.announce(io, .committed) catch {};
            return;
        }

        // git's `files_transaction_finish`: updates first, so what they
        // reference stays referenced; then each deleted ref's log, then its
        // packed entry, then its loose file, each while its lock is held,
        // so a writer waiting on a lock never has its ref removed after it.
        var hex: [hash.max_hex_len]u8 = undefined;
        for (tx.edits.items) |*edit| {
            // Its lock is given up with the rest, the file as it was.
            if (edit.via != null) continue;
            const new = edit.new orelse continue;
            const lock = &edit.lock.?;
            switch (new) {
                .direct => |oid| {
                    lock.writer().print("{s}\n", .{oid.hex(&hex)}) catch return error.WriteFailed;
                },
                .symbolic => |target| {
                    lock.writer().print("ref: {s}\n", .{target}) catch return error.WriteFailed;
                },
            }
            try lock.commit(io);
        }
        for (tx.edits.items) |edit| {
            if (edit.via != null or edit.new != null) continue;
            try reflog.delete(tx.gpa, io, tx.store.dirFor(edit.name), edit.name);
        }
        if (tx.packed_lock != null) try tx.removeFromPacked(io);
        if (tx.packed_announced) {
            tx.packed_announced = false;
            // glint-ignore: Z026 -- packed-refs is rewritten; as git, a hook failing on "committed" changes nothing
            tx.announceAs(io, .committed, true) catch {};
        }
        for (tx.edits.items) |edit| {
            if (edit.via != null or edit.new != null) continue;
            tx.store.dirFor(edit.name).deleteFile(io, edit.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }

        if (log) |message| {
            const shared = try reflog.normalizeMessage(tx.gpa, message.message);
            defer tx.gpa.free(shared);
            for (tx.edits.items) |edit| {
                // A deleted ref's log went with it.
                if (edit.via == null and edit.new == null) continue;
                // A ref logged through records what the ref at the end of it
                // did.
                const source = if (edit.via) |at| tx.edits.items[at] else edit;
                const old = source.old orelse Oid.zero(tx.store.objectFormat());
                const new = switch (source.new orelse Ref{ .direct = Oid.zero(tx.store.objectFormat()) }) {
                    .direct => |oid| oid,
                    // A symbolic ref's log records what it now resolves to.
                    .symbolic => blk: {
                        const resolved = try tx.store.resolve(tx.gpa, io, source.name);
                        if (resolved) |r| {
                            defer tx.gpa.free(r.name);
                            break :blk r.oid;
                        }
                        break :blk Oid.zero(tx.store.objectFormat());
                    },
                };
                const exists = try reflog.exists(tx.gpa, io, tx.store.dirFor(edit.name), edit.name);
                if (!reflog.shouldLog(message.policy, edit.name, exists)) continue;
                // An edit's own words, or the transaction's.
                const own = if (source.message) |m| try reflog.normalizeMessage(tx.gpa, m) else null;
                defer if (own) |t| tx.gpa.free(t);
                try reflog.append(tx.gpa, io, tx.store.dirFor(edit.name), .{ .ref = edit.name, .old = old, .new = new, .who = message.who, .message = own orelse shared, .shared = tx.store.sharedPermissions(), .sync = tx.store.referenceSync() });
            }
        }

        tx.finished = true;
        tx.releaseLocks(io);
        // With the locks gone, the directories the deletions emptied go,
        // as git's cleanup removes them.
        for (tx.edits.items) |edit| {
            if (edit.via != null or edit.new != null) continue;
            const dir = tx.store.dirFor(edit.name);
            removeEmptyParents(io, dir, edit.name);
            const log_path = try reflog.pathFor(tx.gpa, edit.name);
            defer tx.gpa.free(log_path);
            removeEmptyParents(io, dir, log_path);
        }
        // The refs have moved; a hook failing now changes nothing, and its
        // status is not an error of the transaction's.
        // glint-ignore: Z026 -- the refs have moved; as git, a hook failing on "committed" changes nothing
        if (tx.announced) tx.announce(io, .committed) catch {};
    }

    /// Rewrite `packed-refs` without the deleted refs, from the file as it
    /// was read under the lock `prepare` took, through that lock.
    fn removeFromPacked(tx: *Transaction, io: Io) TransactionError!void {
        const listing = &tx.packed_listing.?;
        var deleted: std.ArrayList([]const u8) = .empty;
        defer deleted.deinit(tx.gpa);
        for (tx.edits.items) |e| {
            if (e.via == null and e.new == null) try deleted.append(tx.gpa, e.name);
        }
        std.mem.sort([]const u8, deleted.items, {}, lessThanName);
        var kept: std.ArrayList(Store.PackedEntry) = .empty;
        defer kept.deinit(tx.gpa);
        try kept.ensureTotalCapacity(tx.gpa, listing.entries.len);
        for (listing.entries) |entry| {
            const at = std.sort.lowerBound([]const u8, deleted.items, entry.name, orderName);
            if (at < deleted.items.len and std.mem.eql(u8, deleted.items[at], entry.name)) continue;
            kept.appendAssumeCapacity(entry);
        }
        try tx.store.writePackedLocked(io, &tx.packed_lock.?, kept.items);
    }

    fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    fn orderName(name: []const u8, item: []const u8) std.math.Order {
        return std.mem.order(u8, name, item);
    }

    /// Give up, leaving the repository exactly as it was. A transaction
    /// that announced itself to `reference-transaction` announces this too.
    pub fn abort(tx: *Transaction, io: Io) void {
        if (!tx.finished) {
            tx.releaseLocks(io);
            tx.finished = true;
            if (tx.packed_announced) {
                tx.packed_announced = false;
                // glint-ignore: Z026 -- as git's run_transaction_hook for an aborted state: the hook's status changes nothing
                tx.announceAs(io, .aborted, true) catch {};
            }
            // glint-ignore: Z026 -- as git's run_transaction_hook for an aborted state: the hook's status changes nothing
            if (tx.announced) tx.announce(io, .aborted) catch {};
        }
    }

    fn releaseLocks(tx: *Transaction, io: Io) void {
        stack_engine.releasePending(io, tx);
        tx.releasePackedLock(io);
        for (tx.edits.items) |*edit| {
            if (edit.lock) |*lock| {
                lock.deinit(io);
                edit.lock = null;
            }
            if (edit.lock_buffer.len != 0) {
                tx.gpa.free(edit.lock_buffer);
                edit.lock_buffer = &.{};
            }
        }
    }
};

/// Whether `path` in `dir` is a file: a loose ref, which no ref below it
/// can share a path with.
fn isLooseFile(io: Io, dir: Io.Dir, path: []const u8) TransactionError!bool {
    const stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |e| return e,
    };
    return stat.kind != .directory;
}

/// Whether a file other than a lock is anywhere under the directory `name`
/// in `dir`: a loose ref that `name` cannot be written over.
fn hasLooseBelow(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) TransactionError!bool {
    var sub = dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |e| return e,
    };
    defer sub.close(io);
    var walker = try sub.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory or std.mem.endsWith(u8, entry.basename, ".lock")) continue;
        return true;
    }
    return false;
}

/// Remove the directories above `path` that are left empty, down to but not
/// including `refs/<kind>/` — or `logs/refs/<kind>/` — which git keeps.
fn removeEmptyParents(io: Io, dir: Io.Dir, path: []const u8) void {
    const keep: usize = if (std.mem.startsWith(u8, path, "logs/")) 3 else 2;
    var current = path;
    while (std.Io.Dir.path.dirnamePosix(current)) |parent| {
        if (std.mem.count(u8, parent, "/") < keep) return;
        dir.deleteDir(io, parent) catch return;
        current = parent;
    }
}

fn nests(a: []const u8, b: []const u8) bool {
    if (a.len == b.len) return false;
    const shorter = if (a.len < b.len) a else b;
    const longer = if (a.len < b.len) b else a;
    return std.mem.startsWith(u8, longer, shorter) and longer[shorter.len] == '/';
}

test "a loose ref is written, read and resolved" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    const oid = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));

    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.create("refs/heads/main", .{ .direct = oid });
    try tx.update("HEAD", .{ .symbolic = "refs/heads/main" }, .any);
    try tx.commit(io, .{
        .who = .{ .name = "Ada", .email = "a@b", .when_secs = 1, .offset_minutes = 0 },
        .message = "commit: first",
    });

    const found = (try store.read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(found.direct.eql(oid));

    const resolved = (try store.head(gpa, io)).?;
    defer gpa.free(resolved.name);
    try std.testing.expectEqualStrings("refs/heads/main", resolved.name);
    try std.testing.expect(resolved.oid.eql(oid));

    const branch = (try store.currentBranch(gpa, io)).?;
    defer gpa.free(branch);
    try std.testing.expectEqualStrings("main", branch);

    // Both refs got a log: git writes HEAD's as well as the branch's.
    var log = try reflog.read(gpa, io, tmp.dir, "refs/heads/main", .sha1);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 1), log.entries.len);
    var head_log = try reflog.read(gpa, io, tmp.dir, "HEAD", .sha1);
    defer head_log.deinit();
    try std.testing.expectEqual(@as(usize, 1), head_log.entries.len);
}

test "preparing an existing symbolic ref releases every parsed target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = @as([40]u8, @splat('1')) ++ "\n" });

    var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe_allocator.allocator();
    {
        var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
        defer store.deinit();
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        try tx.update("HEAD", .{ .symbolic = "refs/heads/next" }, .any);
        try tx.prepare(io);
    }
    try std.testing.expectEqual(0, safe_allocator.deinit());
}

test "an expected value that does not hold changes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const two = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    const three = try Oid.parse(.sha1, &@as([40]u8, @splat('3')));

    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        try tx.create("refs/heads/main", .{ .direct = one });
        try tx.commit(io, null);
    }
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        try tx.update("refs/heads/main", .{ .direct = three }, .{ .matches = two });
        try std.testing.expectError(error.ExpectedValueMismatch, tx.commit(io, null));
    }
    const found = (try store.read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(found.direct.eql(one));
    try std.testing.expect(!fs.lockHeld(io, tmp.dir, "refs/heads/main"));

    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        try tx.create("refs/heads/main", .{ .direct = three });
        try std.testing.expectError(error.RefAlreadyExists, tx.commit(io, null));
    }
}

test "a whole transaction rolls back when one lock is held" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));

    try tmp.dir.createDirPath(io, "refs/heads");
    // A lock exactly where a running git would leave one.
    const blocker = try tmp.dir.createFile(io, "refs/heads/b.lock", .{ .exclusive = true });
    blocker.close(io);

    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.create("refs/heads/a", .{ .direct = one });
    try tx.create("refs/heads/b", .{ .direct = one });
    try std.testing.expectError(error.LockHeld, tx.commit(io, null));

    // Neither ref moved, and the lock this did not take is untouched.
    try std.testing.expect((try store.read(gpa, io, "refs/heads/a")) == null);
    try std.testing.expect((try store.read(gpa, io, "refs/heads/b")) == null);
    try tmp.dir.access(io, "refs/heads/b.lock", .{});
    try std.testing.expect(!fs.lockHeld(io, tmp.dir, "refs/heads/a"));
}

test "packed refs read, shadow and write" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();

    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const two = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    const peeled = try Oid.parse(.sha1, &@as([40]u8, @splat('3')));
    try store.writePacked(io, &.{
        .{ .name = "refs/heads/main", .oid = one, .peeled = null },
        .{ .name = "refs/tags/v1", .oid = two, .peeled = peeled },
    });

    var raw: [512]u8 = undefined;
    const text = try tmp.dir.readFile(io, "packed-refs", &raw);
    try std.testing.expect(std.mem.startsWith(u8, text, packed_header));
    try std.testing.expect(std.mem.find(u8, text, "^3333") != null);

    const found = (try store.read(gpa, io, "refs/tags/v1")).?;
    try std.testing.expect(found.direct.eql(two));

    // A loose ref of the same name wins.
    const three = try Oid.parse(.sha1, &@as([40]u8, @splat('4')));
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        try tx.update("refs/heads/main", .{ .direct = three }, .any);
        try tx.commit(io, null);
    }
    var listing = try store.list(gpa, io, "refs/");
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 2), listing.entries.len);
    const main = listing.find("refs/heads/main").?;
    try std.testing.expect(main.loose);
    try std.testing.expect(main.target.direct.eql(three));
    const tag = listing.find("refs/tags/v1").?;
    try std.testing.expect(!tag.loose);
    try std.testing.expect(tag.peeled.?.eql(peeled));
}

test "a store parses packed-refs once, and again when the file is replaced" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    // Another writer: a store of its own over the same directory.
    var other: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer other.deinit();
    const loads = &state_mod.get(store._state).packed_refs.?.loads;

    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const two = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    try std.testing.expect((try store.read(gpa, io, "refs/tags/v1")) == null);
    try other.writePacked(io, &.{
        .{ .name = "refs/heads/main", .oid = one, .peeled = null },
        .{ .name = "refs/tags/v1", .oid = one, .peeled = null },
    });
    for (0..1000) |_| {
        try std.testing.expect((try store.read(gpa, io, "refs/tags/v1")).?.direct.eql(one));
        try std.testing.expect((try store.read(gpa, io, "refs/tags/v2")) == null);
    }
    var listing = try store.list(gpa, io, "refs/tags/");
    listing.deinit();
    try std.testing.expectEqual(@as(u64, 2), loads.*);

    // The same size, other contents: the new file is another file.
    try other.writePacked(io, &.{
        .{ .name = "refs/heads/main", .oid = one, .peeled = null },
        .{ .name = "refs/tags/v1", .oid = two, .peeled = null },
    });
    try std.testing.expect((try store.read(gpa, io, "refs/tags/v1")).?.direct.eql(two));
    try std.testing.expectEqual(@as(u64, 3), loads.*);

    // Gone is empty.
    try tmp.dir.deleteFile(io, "packed-refs");
    try std.testing.expect((try store.read(gpa, io, "refs/tags/v1")) == null);
    var none = try store.list(gpa, io, "refs/");
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.entries.len);
}

test "a listing takes the packed refs under its prefix and no others" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    // Out of order, as a hand-written file may be: the snapshot sorts it.
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = "2222222222222222222222222222222222222222 refs/tags/b\n" ++
        "1111111111111111111111111111111111111111 refs/heads/a\n" ++
        "3333333333333333333333333333333333333333 refs/tags/a\n" ++
        "4444444444444444444444444444444444444444 refs/tagsx\n" });
    var tags = try store.list(gpa, io, "refs/tags/");
    defer tags.deinit();
    try std.testing.expectEqual(@as(usize, 2), tags.entries.len);
    try std.testing.expectEqualStrings("refs/tags/a", tags.entries[0].name);
    try std.testing.expectEqualStrings("refs/tags/b", tags.entries[1].name);
    var all = try store.list(gpa, io, "");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 4), all.entries.len);
    try std.testing.expect((try store.read(gpa, io, "refs/tagsx")).?.direct.eql(try Oid.parse(.sha1, &@as([40]u8, @splat('4')))));
}

test "deleting a packed ref removes it from the packed file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();

    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const two = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    try store.writePacked(io, &.{
        .{ .name = "refs/heads/keep", .oid = one, .peeled = null },
        .{ .name = "refs/heads/gone", .oid = two, .peeled = null },
    });

    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.delete("refs/heads/gone", .must_exist);
    try tx.commit(io, null);

    try std.testing.expect((try store.read(gpa, io, "refs/heads/gone")) == null);
    try std.testing.expect((try store.read(gpa, io, "refs/heads/keep")) != null);
}

test "deleting a ref that is loose and packed at once removes both, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    try repo.exec(io, &.{ "branch", "x" });
    try repo.exec(io, &.{ "pack-refs", "--all" });
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
    try repo.exec(io, &.{ "branch", "-f", "x", "HEAD" });

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.delete("refs/heads/x", .must_exist);
    try tx.commit(io, null);

    try std.testing.expect((try store.read(gpa, io, "refs/heads/x")) == null);
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.run(io, &.{ "rev-parse", "--verify", "-q", "refs/heads/x" }));
}

test "a deletion holds packed-refs.lock from prepare, so git cannot pack a ref in between" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    try repo.exec(io, &.{ "branch", "a" });
    try repo.exec(io, &.{ "pack-refs", "--all" });
    try repo.exec(io, &.{ "branch", "b" });

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{ .packed_lock = .fail });
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.delete("refs/heads/a", .must_exist);
    try tx.prepare(io);
    // git's pack-refs waits for the lock this transaction holds, and gives
    // up rather than write a file the deletion would then overwrite.
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.run(io, &.{ "-c", "core.packedRefsTimeout=0", "pack-refs", "--all" }));
    repo.report_failures = true;
    try tx.commit(io, null);
    try repo.exec(io, &.{ "pack-refs", "--all" });
    const listed = try repo.run(io, &.{ "for-each-ref", "--format=%(refname)" });
    defer gpa.free(listed);
    try std.testing.expectEqualStrings("refs/heads/b\nrefs/heads/main\n", listed);

    // A lock another writer holds is waited for as long as the store says,
    // then refused with nothing changed.
    try git_dir.writeFile(io, .{ .sub_path = "packed-refs.lock", .data = "" });
    var held = store.begin(gpa);
    defer held.deinit(io);
    try held.delete("refs/heads/b", .must_exist);
    try std.testing.expectError(error.LockHeld, held.commit(io, null));
    try std.testing.expect((try store.read(gpa, io, "refs/heads/b")) != null);
}

test "a name that shares a path with an existing ref is refused, loose or packed, as git refuses it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    try repo.exec(io, &.{ "branch", "a" });
    try repo.exec(io, &.{ "branch", "c/d" });
    try repo.exec(io, &.{ "pack-refs", "--all" });
    try repo.exec(io, &.{ "branch", "e/f" });
    const head_text = try repo.run(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const head = try Oid.parse(.sha1, std.mem.trim(u8, head_text, "\r\n"));

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    repo.report_failures = false;
    for ([_][]const u8{ "refs/heads/a/b", "refs/heads/c", "refs/heads/e" }) |name| {
        try std.testing.expectError(error.GitFailed, repo.run(io, &.{ "update-ref", name, "HEAD" }));
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        // The first edit is not installed when the second is refused.
        try tx.create("refs/heads/first", .{ .direct = head });
        try tx.create(name, .{ .direct = head });
        try std.testing.expectError(error.RefNameConflict, tx.commit(io, null));
        try std.testing.expect((try store.read(gpa, io, "refs/heads/first")) == null);
    }
    // A ref beside them, sharing only a prefix of its name, is no conflict.
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.create("refs/heads/ab", .{ .direct = head });
    try tx.create("refs/heads/c-d", .{ .direct = head });
    try tx.commit(io, null);
}

test "FETCH_HEAD and a merge's MERGE_HEAD read as their first object name, as git reads them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    try source.exec(io, &.{ "branch", "other" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(source_path);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "fetch", "-q", source_path, "main", "other" });
    try repo.writeFile(io, ".git/MERGE_HEAD", @as([40]u8, @splat('1')) ++ "\n" ++ @as([40]u8, @splat('2')) ++ "\n");

    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    inline for (comptime std.enums.values(names.Special)) |special| {
        const theirs = try repo.run(io, &.{ "rev-parse", special.name() });
        defer gpa.free(theirs);
        var hex: [hash.max_hex_len]u8 = undefined;
        // as a ref, and as the special ref it is
        const ours = (try store.read(gpa, io, special.name())).?;
        try std.testing.expectEqualStrings(std.mem.trim(u8, theirs, "\r\n"), ours.direct.hex(&hex));
        const first = (try store.special().read(gpa, io, special)).?;
        try std.testing.expectEqualStrings(std.mem.trim(u8, theirs, "\r\n"), first.hex(&hex));
    }
    // An object name run into more text is not one.
    try repo.writeFile(io, ".git/ORIG_HEAD", @as([41]u8, @splat('1')) ++ "\n");
    try std.testing.expectError(error.MalformedRef, store.read(gpa, io, names.Root.orig_head.name()));
}

test "a symbolic ref's target is checked as git checks it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try std.testing.expectError(error.InvalidRefName, tx.update("HEAD", .{ .symbolic = "../x\nfoo" }, .any));
    try std.testing.expectError(error.InvalidRefName, tx.update("refs/heads/s", .{ .symbolic = "refs/heads/a..b" }, .any));
    try std.testing.expectError(error.InvalidRefName, tx.update("HEAD", .{ .symbolic = names.Root.orig_head.name() }, .any));
    try tx.update("refs/heads/s", .{ .symbolic = names.Root.orig_head.name() }, .any);
    try tx.update("HEAD", .{ .symbolic = "refs/heads/main" }, .any);
}

test "an update through HEAD is refused when HEAD moves between the split and the locks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = @as([40]u8, @splat('1')) ++ "\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/other", .data = @as([40]u8, @splat('1')) ++ "\n" });
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .direct = try Oid.parse(.sha1, &@as([40]u8, @splat('2'))) }, .any);
    try tx.splitSymbolic(io);
    // A checkout elsewhere moves HEAD to another branch.
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/other\n" });
    try std.testing.expectError(error.ExpectedValueMismatch, tx.lockAndCheck(io));
    const main = (try store.read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(main.direct.eql(try Oid.parse(.sha1, &@as([40]u8, @splat('1')))));
}

test "a ref name ending in .lock is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try std.testing.expectError(
        error.InvalidRefName,
        tx.create("refs/heads/main.lock", .{ .direct = Oid.zero(.sha1) }),
    );
}

test "nesting names in one transaction is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    try tx.create("refs/heads/a", .{ .direct = one });
    try tx.create("refs/heads/a/b", .{ .direct = one });
    try std.testing.expectError(error.RefNameConflict, tx.commit(io, null));
}

/// Two repositories holding the same commit, made by git with a fixed date,
/// each with a `reference-transaction` hook that appends its state and its
/// input to `.git/rt.log`.
const HookTwin = struct {
    git: testgit.Repo,
    relic: testgit.Repo,
    environ: std.process.Environ.Map,

    fn init(gpa: Allocator, io: Io, hook_action: []const u8, hook_data: []const u8) !HookTwin {
        var t: HookTwin = .{
            .git = try testgit.Repo.init(gpa, io, &.{}),
            .relic = undefined,
            .environ = undefined,
        };
        errdefer t.git.deinit();
        t.relic = try testgit.Repo.init(gpa, io, &.{});
        errdefer t.relic.deinit();
        t.environ = try testgit.programEnviron(gpa);
        errdefer t.environ.deinit();
        try t.environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
        try t.environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
        inline for (.{ &t.git, &t.relic }) |r| {
            // The same dates, so both twins hold the same commits.
            r.environ = &t.environ;
            defer r.environ = null;
            try r.writeFile(io, "a.txt", "a\n");
            try r.exec(io, &.{ "add", "a.txt" });
            try r.exec(io, &.{ "commit", "-q", "-m", "one" });
            try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
            try testgit.fixtureHook(gpa, io, r.dir, ".git/hooks/reference-transaction", hook_action, hook_data);
        }
        return t;
    }

    fn deinit(t: *HookTwin) void {
        t.environ.deinit();
        t.git.deinit();
        t.relic.deinit();
        t.* = undefined;
    }

    fn gitWithHooks(t: *HookTwin, io: Io, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(t.git.gpa);
        try argv.appendSlice(t.git.gpa, &.{ "-c", "core.hooksPath=.git/hooks" });
        try argv.appendSlice(t.git.gpa, args);
        t.git.environ = &t.environ;
        defer t.git.environ = null;
        try t.git.exec(io, argv.items);
    }

    fn expectSameLog(t: *HookTwin, io: Io) !void {
        const a = try t.git.readFile(io, ".git/rt.log");
        defer t.git.gpa.free(a);
        const b = try t.relic.readFile(io, ".git/rt.log");
        defer t.relic.gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
};

const logging_hook = ".git/rt.log\n";

test "reference-transaction hears from a transaction what git's hears" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // What the reference-transaction hook hears is git 2.54's: a
    // "preparing" state, and a symbolic ref's updates among the others.
    try testgit.requireGitVersion(gpa, io, 2, 54);
    var twin = try HookTwin.init(gpa, io, "record_stdin", logging_hook);
    defer twin.deinit();

    const first_text = try twin.git.line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(first_text);
    const second_text = try twin.git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(second_text);
    const first = try Oid.parse(.sha1, first_text);
    const second = try Oid.parse(.sha1, second_text);

    try twin.gitWithHooks(io, &.{ "update-ref", "refs/heads/topic", first_text });
    try twin.gitWithHooks(io, &.{ "update-ref", "refs/heads/topic", second_text, first_text });
    try twin.gitWithHooks(io, &.{ "symbolic-ref", "HEAD", "refs/heads/topic" });

    var git_dir = try twin.relic.gitDir(io);
    defer git_dir.close(io);
    var config = try config_mod.Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = twin.relic.dir,
    }, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.update("refs/heads/topic", .{ .direct = first }, .any);
        try tx.commit(io, null);
    }
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.update("refs/heads/topic", .{ .direct = second }, .{ .matches = first });
        try tx.commit(io, null);
    }
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.update("HEAD", .{ .symbolic = "refs/heads/topic" }, .any);
        try tx.commit(io, null);
    }
    try twin.expectSameLog(io);
}

test "an update goes through HEAD to its branch, and both logs record it, as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // What the reference-transaction hook hears is git 2.54's: a
    // "preparing" state, and a symbolic ref's updates among the others.
    try testgit.requireGitVersion(gpa, io, 2, 54);
    var twin = try HookTwin.init(gpa, io, "record_stdin", logging_hook);
    defer twin.deinit();
    const first_text = try twin.git.line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(first_text);
    const second_text = try twin.git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(second_text);
    const first = try Oid.parse(.sha1, first_text);
    const second = try Oid.parse(.sha1, second_text);

    try twin.gitWithHooks(io, &.{ "update-ref", "-m", "through HEAD", "HEAD", first_text, second_text });
    try twin.gitWithHooks(io, &.{ "update-ref", "-m", "the branch by name", "refs/heads/main", second_text });
    try twin.gitWithHooks(io, &.{ "update-ref", "--no-deref", "-m", "detached", "HEAD", first_text });
    try twin.gitWithHooks(io, &.{ "update-ref", "--no-deref", "-m", "attached", "HEAD", second_text });
    try twin.gitWithHooks(io, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    try twin.gitWithHooks(io, &.{ "update-ref", "-d", "-m", "deleted through HEAD", "HEAD" });

    var git_dir = try twin.relic.gitDir(io);
    defer git_dir.close(io);
    var config = try config_mod.Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = twin.relic.dir,
    }, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
    const Step = struct { name: []const u8, new: ?Ref, expected: Expected, no_deref: bool = false, message: ?[]const u8 };
    const steps = [_]Step{
        .{ .name = "HEAD", .new = .{ .direct = first }, .expected = .{ .matches = second }, .message = "through HEAD" },
        .{ .name = "refs/heads/main", .new = .{ .direct = second }, .expected = .any, .message = "the branch by name" },
        .{ .name = "HEAD", .new = .{ .direct = first }, .expected = .any, .no_deref = true, .message = "detached" },
        .{ .name = "HEAD", .new = .{ .direct = second }, .expected = .any, .no_deref = true, .message = "attached" },
        .{ .name = "HEAD", .new = .{ .symbolic = "refs/heads/main" }, .expected = .any, .message = "" },
        .{ .name = "HEAD", .new = null, .expected = .any, .message = "deleted through HEAD" },
    };
    for (steps) |step| {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.change(step.name, step.new, step.expected, .{ .no_deref = step.no_deref });
        try tx.commit(io, if (step.message) |m| .{ .who = who, .message = m } else null);
    }

    try twin.expectSameLog(io);
    for ([_][]const u8{ ".git/HEAD", ".git/logs/HEAD" }) |path| {
        const a = try twin.git.readFile(io, path);
        defer gpa.free(a);
        const b = try twin.relic.readFile(io, path);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
    const listing_a = try listTree(gpa, io, twin.git.dir);
    defer gpa.free(listing_a);
    const listing_b = try listTree(gpa, io, twin.relic.dir);
    defer gpa.free(listing_b);
    try std.testing.expectEqualStrings(listing_a, listing_b);
}

test "a log message is collapsed in the transaction as git collapses it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var twin = try HookTwin.init(gpa, io, "status", "0\n");
    defer twin.deinit();
    const head_text = try twin.relic.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const message = "  commit:\tsubject  line\n\n  body \r\n";
    try twin.gitWithHooks(io, &.{ "update-ref", "-m", message, "refs/heads/topic", head_text });

    var git_dir = try twin.relic.gitDir(io);
    defer git_dir.close(io);
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.update("refs/heads/topic", .{ .direct = try Oid.parse(.sha1, head_text) }, .any);
    try tx.commit(io, .{
        .who = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
        .message = message,
    });
    const a = try twin.git.readFile(io, ".git/logs/refs/heads/topic");
    defer gpa.free(a);
    const b = try twin.relic.readFile(io, ".git/logs/refs/heads/topic");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.endsWith(u8, b, "\tcommit: subject line body\n"));
}

test "an edit named twice, once through HEAD, is refused before anything moves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = @as([40]u8, @splat('1')) ++ "\n" });
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .direct = try Oid.parse(.sha1, &@as([40]u8, @splat('2'))) }, .any);
    try tx.update("refs/heads/main", .{ .direct = try Oid.parse(.sha1, &@as([40]u8, @splat('3'))) }, .any);
    try std.testing.expectError(error.DuplicateEdit, tx.commit(io, null));
    const main = (try store.read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(main.direct.eql(try Oid.parse(.sha1, &@as([40]u8, @splat('1')))));
    try std.testing.expect(!fs.lockHeld(io, tmp.dir, "HEAD"));
}

test "a reference-transaction hook refusing a transaction leaves every ref as it was" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // What the reference-transaction hook hears is git 2.54's: a
    // "preparing" state, and a symbolic ref's updates among the others.
    try testgit.requireGitVersion(gpa, io, 2, 54);
    for ([_][]const u8{ "preparing", "prepared" }) |state| {
        var body_buf: [160]u8 = undefined;
        const body = try std.mem.print(&body_buf, ".git/rt.log\n{s}", .{state});
        var twin = try HookTwin.init(gpa, io, "record_stdin", body);
        defer twin.deinit();
        const head_text = try twin.git.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(head_text);
        const head = try Oid.parse(.sha1, head_text);

        twin.git.report_failures = false;
        try std.testing.expectError(error.GitFailed, twin.gitWithHooks(io, &.{ "update-ref", "refs/heads/topic", head_text }));

        var git_dir = try twin.relic.gitDir(io);
        defer git_dir.close(io);
        var config = try config_mod.Config.parseText(gpa, "", .local);
        defer config.deinit();
        var runner = try hooks.Runner.init(gpa, io, .{
            .config = &config,
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = twin.relic.dir,
        }, .{ .environ = &twin.environ }, .{ .output = .ignore });
        defer runner.deinit();
        var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
        defer store.deinit();
        {
            var tx = store.begin(gpa);
            defer tx.deinit(io);
            tx.hooks = &runner;
            try tx.update("refs/heads/topic", .{ .direct = head }, .any);
            try std.testing.expectError(error.HookRejected, tx.commit(io, null));
        }
        try std.testing.expectEqualStrings("reference-transaction", runner.failure.event());
        try std.testing.expect((try store.read(gpa, io, "refs/heads/topic")) == null);
        try std.testing.expect(!fs.lockHeld(io, git_dir, "refs/heads/topic"));
        try twin.expectSameLog(io);
    }
}

test "a deletion is announced as git announces it, packed or loose" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // What the reference-transaction hook hears is git 2.54's: a
    // "preparing" state, and a symbolic ref's updates among the others.
    try testgit.requireGitVersion(gpa, io, 2, 54);
    var twin = try HookTwin.init(gpa, io, "record_stdin", logging_hook);
    defer twin.deinit();
    const head_text = try twin.relic.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const head = try Oid.parse(.sha1, head_text);
    inline for (.{ &twin.git, &twin.relic }) |r| {
        try r.exec(io, &.{ "-c", "core.hooksPath=none", "branch", "packed" });
        try r.exec(io, &.{ "-c", "core.hooksPath=none", "pack-refs", "--all" });
        try r.exec(io, &.{ "-c", "core.hooksPath=none", "branch", "loose" });
    }
    // One loose ref, then a packed and a loose one together.
    try twin.gitWithHooks(io, &.{ "update-ref", "-d", "refs/heads/loose", head_text });
    try twin.gitWithHooks(io, &.{ "branch", "loose" });
    try twin.gitWithHooks(io, &.{ "branch", "-D", "-q", "packed", "loose" });

    var git_dir = try twin.relic.gitDir(io);
    defer git_dir.close(io);
    var config = try config_mod.Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = twin.relic.dir,
    }, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.delete("refs/heads/loose", .{ .matches = head });
        try tx.commit(io, null);
    }
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.create("refs/heads/loose", .{ .direct = head });
        try tx.commit(io, null);
    }
    {
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        tx.hooks = &runner;
        // `git branch -D` expects no value.
        try tx.delete("refs/heads/packed", .any);
        try tx.delete("refs/heads/loose", .any);
        try tx.commit(io, null);
    }
    try twin.expectSameLog(io);
}

test "deleting a ref takes its log and its empty directories with it, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    // One date for both, so both commits have one name however long the
    // two setups take between them.
    var environ = try testgit.programEnviron(gpa);
    defer environ.deinit();
    try environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
    try environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
    inline for (.{ &git, &here }) |r| {
        r.environ = &environ;
        defer r.environ = null;
        try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
        try r.exec(io, &.{ "branch", "a/b/c" });
        try r.exec(io, &.{ "branch", "d" });
        try r.exec(io, &.{ "branch", "e" });
        try r.exec(io, &.{ "pack-refs", "--all" });
        try r.exec(io, &.{ "branch", "-f", "e", "HEAD" });
    }
    try git.exec(io, &.{ "branch", "-q", "-D", "a/b/c", "d", "e" });

    var git_dir = try here.gitDir(io);
    defer git_dir.close(io);
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir, .{});
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.delete("refs/heads/a/b/c", .must_exist);
    try tx.delete("refs/heads/d", .must_exist);
    try tx.delete("refs/heads/e", .must_exist);
    try tx.commit(io, null);

    const refs_a = try git.run(io, &.{"for-each-ref"});
    defer gpa.free(refs_a);
    const refs_b = try here.run(io, &.{"for-each-ref"});
    defer gpa.free(refs_b);
    try std.testing.expectEqualStrings(refs_a, refs_b);
    const packed_a = try git.readFile(io, ".git/packed-refs");
    defer gpa.free(packed_a);
    const packed_b = try here.readFile(io, ".git/packed-refs");
    defer gpa.free(packed_b);
    try std.testing.expectEqualStrings(packed_a, packed_b);
    const listing_a = try listTree(gpa, io, git.dir);
    defer gpa.free(listing_a);
    const listing_b = try listTree(gpa, io, here.dir);
    defer gpa.free(listing_b);
    try std.testing.expectEqualStrings(listing_a, listing_b);
    try std.testing.expect(std.mem.find(u8, listing_b, "heads/a") == null);
}

/// Every path under `.git/refs` and `.git/logs`, sorted, one per line.
fn listTree(gpa: Allocator, io: Io, top: Io.Dir) ![]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    for ([_][]const u8{ ".git/refs", ".git/logs" }) |root| {
        var dir = top.openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            try paths.append(gpa, try gpa.print("{s}/{s}", .{ root, entry.path }));
        }
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths.items) |p| {
        try out.appendSlice(gpa, p);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "fuzz: any packed-refs bytes are a listing or a named error" {
    try std.testing.fuzz({}, fuzzPacked, .{});
}

fn fuzzPacked(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [2048]u8 = undefined;
    const n = smith.slice(&scratch);
    const bytes = try gpa.dupe(u8, scratch[0..n]);
    var listing = Store.parsePacked(gpa, .sha1, bytes) catch return;
    defer listing.deinit();
    _ = listing.find("refs/heads/main");
}

test "reading packed refs has one owner when parsing stops" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
    defer store.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = packed_header ++ @as([40]u8, @splat('1')) ++ " refs/heads/main\n" });
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), readPackedForAllocation, .{ io, tmp.dir });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = "not a ref\n" });
    try std.testing.expectError(error.MalformedPackedRefs, store.readPacked(gpa, io));
}

fn readPackedForAllocation(gpa: Allocator, io: Io, dir: Io.Dir) !void {
    var store: Store = try .init(gpa, .sha1, dir, dir, .{});
    defer store.deinit();
    var listed = try store.readPacked(gpa, io);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.entries.len);
    try std.testing.expectEqualStrings("refs/heads/main", listed.entries[0].name);
}

test "listing loose refs preserves allocation resource failures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "refs/heads");
    // A packed ref stays present when an unreadable loose shadow is skipped.
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = packed_header ++ @as([40]u8, @splat('1')) ++ " refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = "ref: refs/heads/" ++ @as([2000]u8, @splat('a')) ++ "\n" });
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), listLooseRefsForAllocation, .{ io, tmp.dir });
    }
    var counting = std.testing.FailingAllocator.init(gpa, .{});
    try listLooseRefsForAllocation(counting.allocator(), io, tmp.dir);
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var vtable = failing.allocator().vtable.*;
        vtable.alloc = struct {
            fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                const f: *std.testing.FailingAllocator = @ptrCast(@alignCast(context));
                const result = f.allocator().rawAlloc(len, alignment, ra);
                // Fail once, so a swallowed error cannot hide behind a later one.
                if (result == null and f.has_induced_failure) f.fail_index = std.math.maxInt(usize);
                return result;
            }
        }.alloc;
        const recovering: Allocator = .{ .ptr = &failing, .vtable = &vtable };
        try std.testing.expectError(error.OutOfMemory, listLooseRefsForAllocation(recovering, io, tmp.dir));
    }
}

fn listLooseRefsForAllocation(gpa: Allocator, io: Io, dir: Io.Dir) !void {
    var store: Store = try .init(gpa, .sha1, dir, dir, .{});
    defer store.deinit();
    var listed = try store.list(gpa, io, "refs/heads/");
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.entries.len);
    try std.testing.expect(listed.entries[0].loose);
    try std.testing.expectEqualStrings("refs/heads/" ++ @as([2000]u8, @splat('a')), listed.entries[0].target.symbolic);
}

/// Every file below `dir` but objects and logs, by its `/`-separated path,
/// with its bytes: a before and after of what an operation wrote.
fn refFilesSnapshot(gpa: Allocator, io: Io, dir: Io.Dir) !std.array_hash_map.String([]u8) {
    var out: std.array_hash_map.String([]u8) = .empty;
    errdefer freeRefFilesSnapshot(gpa, &out);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.depth() == 1 and (std.mem.eql(u8, entry.basename, "objects") or std.mem.eql(u8, entry.basename, "logs"))) walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        const path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .unlimited);
        errdefer gpa.free(bytes);
        try out.put(gpa, path, bytes);
    }
    return out;
}

fn freeRefFilesSnapshot(gpa: Allocator, snapshot: *std.array_hash_map.String([]u8)) void {
    var it = snapshot.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    snapshot.deinit(gpa);
}

/// Whether one of `scopes` covers `path`, below the common directory;
/// `git_prefix` is the per-worktree directory's place there.
fn scopesCover(scopes: []const WatchScope, git_prefix: []const u8, path: []const u8) bool {
    for (scopes) |scope| {
        const base = if (scope.dir == .git) git_prefix else "";
        const in_base = below(path, base) orelse continue;
        const rest = below(in_base, scope.sub_path) orelse continue;
        if (!scope.recursive and std.mem.findScalar(u8, rest, '/') != null) continue;
        if (scope.names.len == 0) return true;
        for (scope.names) |name| if (std.mem.eql(u8, name, rest)) return true;
    }
    return false;
}

/// What of `path` lies below `folder`, the whole of it when `folder` is
/// empty, or null when it lies elsewhere.
fn below(path: []const u8, folder: []const u8) ?[]const u8 {
    if (folder.len == 0) return path;
    if (path.len <= folder.len or path[folder.len] != '/' or !std.mem.startsWith(u8, path, folder)) return null;
    return path[folder.len + 1 ..];
}

test "the watch scopes cover every ref and HEAD move, in a linked worktree too" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Format{ .files, .reftable }) |format| {
        // `--ref-format=reftable` arrived in 2.45.
        if (format == .reftable and !try testgit.gitAtLeast(gpa, io, 2, 45)) continue;
        var git = try testgit.Repo.init(gpa, io, if (format == .reftable) &.{"--ref-format=reftable"} else &.{});
        defer git.deinit();
        try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
        try git.exec(io, &.{ "branch", "gone" });
        try git.exec(io, &.{ "pack-refs", "--all" });
        try git.exec(io, &.{ "worktree", "add", "-q", "-b", "side", "linked" });
        var common = try git.dir.openDir(io, ".git", .{ .iterate = true });
        defer common.close(io);
        var admin = try common.openDir(io, "worktrees/linked", .{});
        defer admin.close(io);
        var main_store: Store = try .init(gpa, .sha1, common, common, .{ .format = format });
        defer main_store.deinit();
        var linked_store: Store = try .init(gpa, .sha1, admin, common, .{ .format = format });
        defer linked_store.deinit();
        const main_scopes = main_store.watchScopes();
        const linked_scopes = linked_store.watchScopes();

        const Step = struct { args: []const []const u8, linked: bool, shared: bool };
        for ([_]Step{
            .{ .args = &.{ "commit", "-q", "--allow-empty", "-m", "main moves" }, .linked = false, .shared = true },
            .{ .args = &.{ "checkout", "-q", "-b", "topic" }, .linked = false, .shared = false },
            .{ .args = &.{ "-C", "linked", "commit", "-q", "--allow-empty", "-m", "side moves" }, .linked = true, .shared = true },
            .{ .args = &.{ "-C", "linked", "checkout", "-q", "-b", "other" }, .linked = true, .shared = false },
            // a branch only `packed-refs` holds: the file in the shared
            // directory is all that changes
            .{ .args = &.{ "-C", "linked", "branch", "-q", "-D", "gone" }, .linked = true, .shared = true },
            .{ .args = &.{ "-C", "linked", "checkout", "-q", "--detach" }, .linked = true, .shared = false },
        }) |step| {
            var before = try refFilesSnapshot(gpa, io, common);
            defer freeRefFilesSnapshot(gpa, &before);
            try git.exec(io, step.args);
            var after = try refFilesSnapshot(gpa, io, common);
            defer freeRefFilesSnapshot(gpa, &after);
            var own = false;
            var other = false;
            for ([_]*const std.array_hash_map.String([]u8){ &before, &after }, [_]*const std.array_hash_map.String([]u8){ &after, &before }) |one, two| {
                var it = one.iterator();
                while (it.next()) |entry| {
                    const same = if (two.get(entry.key_ptr.*)) |bytes| std.mem.eql(u8, bytes, entry.value_ptr.*) else false;
                    if (same) continue;
                    const path = entry.key_ptr.*;
                    if (scopesCover((if (step.linked) linked_scopes else main_scopes).slice(), if (step.linked) "worktrees/linked" else "", path)) own = true;
                    if (scopesCover((if (step.linked) main_scopes else linked_scopes).slice(), if (step.linked) "" else "worktrees/linked", path)) other = true;
                }
            }
            std.testing.expect(own and (!step.shared or other)) catch |err| {
                std.debug.print("{t}: {s} not seen (own {}, other {})\n", .{ format, step.args[step.args.len - 1], own, other });
                return err;
            };
        }
    }
}

/// All errors reported by this namespace.
pub const Error = ReadError || TransactionError || LogReadError || Store.ReadLogError || Store.ExpireLogError || CreateError || Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.DeleteFileError;
