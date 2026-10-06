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

pub const reftablestack = @import("refs/reftablestack.zig");
// The modules relic's API puts under this one, as `relic.refs.<name>`.
pub const reflog = @import("refs/reflog.zig");
pub const reftable = @import("refs/reftable.zig");
pub const filter = @import("refs/filter.zig");
const stack_engine = @import("refs/reftablestack/transaction.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const fs = @import("repo/fs.zig");
const safepath = @import("worktree/safepath.zig");
const hooks = @import("repo/hooks.zig");
const testgit = @import("testing/git.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;
const state_mod = @import("refs/state.zig");
const packed_cache = @import("refs/packed.zig");
const value_mod = @import("refs/value.zig");

/// The header `packed-refs` carries, with the space before the newline that
/// is in git's source and in no document.
pub const packed_header = @import("refs/value.zig").packed_header;

/// How deep a chain of symbolic refs may go. git's own cap.
pub const max_symbolic_depth = @import("refs/value.zig").max_symbolic_depth;

/// Errors from reading refs.
pub const ReadError = @import("refs/value.zig").ReadError;

/// Errors from a transaction.
pub const TransactionError = @import("refs/value.zig").TransactionError;

/// Where a repository's refs are kept.
pub const Format = @import("refs/value.zig").Format;

/// Peels an object name for a ref about to be written, so that a reftable
/// can record what an annotated tag points at beside it, as git's does.
/// `Repository.beginRefs` supplies one.
pub const Peeler = @import("refs/value.zig").Peeler;

/// What a ref points at.
pub const Ref = @import("refs/value.zig").Ref;

/// A ref with its name, as `list` hands them back.
pub const Named = @import("refs/value.zig").Named;

/// A fully resolved ref: the name it ended at and the object it points to.
pub const Resolved = @import("refs/value.zig").Resolved;

/// What an edit requires the ref's current value to be.
pub const Expected = @import("refs/value.zig").Expected;

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
    _state: *state_mod.State,
    /// Open over an already-opened pair of directories, which the store borrows.
    /// The returned owner must be released with `deinit`.
    pub fn init(gpa: Allocator, kind: Kind, git_dir: Io.Dir, common_dir: Io.Dir) Allocator.Error!Store {
        return initWithOptions(gpa, kind, git_dir, common_dir, .{});
    }

    pub const Options = struct {
        format: Format = .files,
        reftable: stack_engine.Options = .{},
        /// What `core.sharedRepository` asks of the permissions of the
        /// refs, logs and directories written.
        shared: fs.Shared = .umask,
    };

    /// Choose the backend and its cache once, before the store is published.
    /// Changing the backend or object format requires opening another store.
    pub fn initWithOptions(gpa: Allocator, kind: Kind, git_dir: Io.Dir, common_dir: Io.Dir, options: Options) Allocator.Error!Store {
        const state = try state_mod.create(gpa, kind, options.format, options.reftable, git_dir, common_dir);
        state_mod.get(state).shared = options.shared;
        return .{ ._state = state };
    }

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
    pub fn configureReftable(store: *Store, options: stack_engine.Options) void {
        state_mod.get(store._state).options = options;
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

    /// Which directory a ref lives in.
    ///
    /// A name of capitals, dashes and underscores alone -- `HEAD`,
    /// `ORIG_HEAD`, `AUTO_MERGE`, `REBASE_HEAD` -- is a pseudo-ref, and
    /// every pseudo-ref belongs to one working tree, which is git's rule.
    pub fn dirFor(store: *const Store, name: []const u8) Io.Dir {
        if (isPseudoRef(name) or
            std.mem.startsWith(u8, name, "refs/bisect/") or
            std.mem.startsWith(u8, name, "refs/worktree/") or
            std.mem.startsWith(u8, name, "refs/rewritten/"))
        {
            return store.gitDir();
        }
        return store.commonDir();
    }

    /// Read one ref, loose first and then `packed-refs`, or `null`.
    ///
    /// A symbolic ref comes back as `.symbolic` without being followed; use
    /// `resolve` for the object. The returned name, when symbolic, is the
    /// caller's.
    pub fn read(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        if (!isReadableName(name)) return error.InvalidRefName;
        if (store.refFormat() == .reftable) {
            if (stack_engine.isSpecial(name)) return store.readLoose(gpa, io, name);
            return stack_engine.read(gpa, io, store, name);
        }
        if (try store.readLoose(gpa, io, name)) |found| return found;
        if (try store.readPackedOne(io, name)) |oid| return .{ .direct = oid };
        return null;
    }

    /// A ref's own value, symbolic or not, where a symbolic one can be:
    /// the loose file, or the reftable stack.
    fn readOwnValue(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        if (store.refFormat() == .reftable) return store.read(gpa, io, name);
        return store.readLoose(gpa, io, name);
    }

    fn readLoose(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        const dir = store.dirFor(name);
        const bytes = (try fs.readFileAlloc(gpa, io, dir, name, 4096)) orelse return null;
        defer gpa.free(bytes);
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "ref:")) {
            const target = std.mem.trim(u8, trimmed[4..], " \t");
            if (target.len == 0) return error.MalformedRef;
            return .{ .symbolic = try gpa.dupe(u8, target) };
        }
        const oid = Oid.parse(store.objectFormat(), trimmed) catch return error.MalformedRef;
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
            if (depth > max_symbolic_depth) {
                gpa.free(current);
                return error.SymbolicRefLoop;
            }
            const found = (try store.read(gpa, io, current)) orelse {
                gpa.free(current);
                return null;
            };
            switch (found) {
                .direct => |oid| return .{ .name = current, .oid = oid },
                .symbolic => |target| {
                    gpa.free(current);
                    current = target;
                },
            }
        }
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
    /// file harmless.
    pub fn list(store: *const Store, gpa: Allocator, io: Io, prefix: []const u8) ReadError!Listing {
        if (store.refFormat() == .reftable) return stack_engine.list(gpa, io, store, prefix);
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var entries: std.ArrayList(Named) = .empty;

        {
            const packed_listing = try store.acquirePacked(io);
            defer store.releasePacked(io);
            // Sorted, so the names under `prefix` are one run.
            const from = std.sort.lowerBound(PackedEntry, packed_listing.entries, prefix, orderPrefix);
            for (packed_listing.entries[from..]) |entry| {
                if (!std.mem.startsWith(u8, entry.name, prefix)) break;
                try entries.append(arena, .{
                    .name = try arena.dupe(u8, entry.name),
                    .target = .{ .direct = entry.oid },
                    .peeled = entry.peeled,
                    .loose = false,
                });
            }
        }

        try store.walkLoose(arena, io, &entries, prefix);

        std.mem.sort(Named, entries.items, {}, lessThanNamed);
        // A loose entry shadows the packed one beside it.
        var deduped: std.ArrayList(Named) = .empty;
        for (entries.items) |entry| {
            if (deduped.items.len != 0) {
                const last = &deduped.items[deduped.items.len - 1];
                if (std.mem.eql(u8, last.name, entry.name)) {
                    if (entry.loose) last.* = entry;
                    continue;
                }
            }
            try deduped.append(arena, entry);
        }

        return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .entries = deduped.items,
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

    fn walkLoose(
        store: *const Store,
        arena: Allocator,
        io: Io,
        out: *std.ArrayList(Named),
        prefix: []const u8,
    ) ReadError!void {
        // `refs/` in both directories: the per-worktree one carries only
        // `refs/bisect`, `refs/worktree` and `refs/rewritten`, and the
        // shared one carries the rest.
        const dirs = [_]Io.Dir{ store.commonDir(), store.gitDir() };
        var seen_same = false;
        for (dirs) |dir| {
            if (seen_same) break;
            if (dir.handle == store.commonDir().handle and store.gitDir().handle == store.commonDir().handle) {
                seen_same = true;
            }
            var refs_dir = dir.openDir(io, "refs", .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer refs_dir.close(io);
            try store.walkLooseDir(arena, io, refs_dir, "refs", out, prefix, 0);
        }
    }

    fn walkLooseDir(
        store: *const Store,
        arena: Allocator,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        out: *std.ArrayList(Named),
        prefix: []const u8,
        depth: u8,
    ) ReadError!void {
        if (depth > 32) return;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            // `<ref>.lock` is a lock file, not a ref. It is skipped rather
            // than read, and a caller that wants to know one is there asks
            // `fs.staleReport`.
            if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
            const child_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, entry.name });
            if (entry.kind == .directory) {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => continue,
                    else => |e| return e,
                };
                defer sub.close(io);
                try store.walkLooseDir(arena, io, sub, child_path, out, prefix, depth + 1);
                continue;
            }
            if (!std.mem.startsWith(u8, child_path, prefix) and !std.mem.startsWith(u8, prefix, child_path)) continue;
            if (!std.mem.startsWith(u8, child_path, prefix)) continue;
            if (!safepath.isValidRefName(child_path)) continue;
            const target = (store.readLoose(arena, io, child_path) catch |err| switch (err) {
                error.MalformedRef => continue,
                else => |e| return e,
            }) orelse continue;
            try out.append(arena, .{ .name = child_path, .target = target, .loose = true });
        }
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
        var lock = try fs.LockFile.open(state_mod.get(store._state).gpa, io, store.commonDir(), "packed-refs", &buffer, .{ .shared = store.sharedPermissions() });
        defer lock.deinit(io);
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
        return reflog.exists(gpa, io, store.dirFor(name), name);
    }

    /// Append one entry to a ref's log without moving the ref: a line of
    /// `logs/<ref>`, or in a reftable repository a table of its own, which
    /// is where git would look for it. The message is collapsed as a
    /// transaction's is.
    pub fn appendLog(
        store: *const Store,
        gpa: Allocator,
        io: Io,
        name: []const u8,
        old: Oid,
        new: Oid,
        who: object.Signature,
        message: []const u8,
    ) TransactionError!void {
        if (!safepath.isValidRefName(name)) return error.InvalidRefName;
        if (store.refFormat() == .reftable) return stack_engine.appendLog(gpa, io, store, name, old, new, who, message);
        // The message a transaction would write: collapsed as git collapses it.
        const text = try reflog.normalizeMessage(gpa, message);
        defer gpa.free(text);
        return reflog.appendShared(gpa, io, store.dirFor(name), name, old, new, who, text, store.sharedPermissions());
    }

    /// A ref's log, oldest first, from `logs/<ref>` or from the reftable
    /// stack as the format says. An absent log is an empty one.
    pub fn readLog(store: *const Store, gpa: Allocator, io: Io, name: []const u8) (ReadError || reflog.ReadError)!reflog.Log {
        if (store.refFormat() == .reftable) return stack_engine.readLog(gpa, io, store, name);
        return reflog.read(gpa, io, store.dirFor(name), name, store.objectFormat());
    }
};

/// Capitals, dashes and underscores and nothing else: git's syntax for a
/// pseudo-ref.
fn isPseudoRef(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isUpper(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn isReadableName(name: []const u8) bool {
    // A pseudo-ref such as `HEAD` or `ORIG_HEAD` is upper case with no
    // slash, which `checkRefName` would otherwise allow through anyway; the
    // check that matters is the `.lock` suffix and the traversal rules.
    return safepath.isValidRefName(name);
}

/// What a log entry a transaction writes says.
pub const LogMessage = @import("refs/value.zig").LogMessage;
const config_mod = @import("config.zig");

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
        if (!safepath.isValidRefName(name)) return error.InvalidRefName;
        for (tx.edits.items) |edit| {
            if (std.mem.eql(u8, edit.name, name)) return error.DuplicateEdit;
        }
        const owned = try tx.gpa.dupe(u8, name);
        errdefer tx.gpa.free(owned);
        var stored_new: ?Ref = null;
        if (new) |value| {
            stored_new = switch (value) {
                .direct => |oid| .{ .direct = oid },
                .symbolic => |target| .{ .symbolic = try tx.gpa.dupe(u8, target) },
            };
        }
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
            if (tx.hooks != null) try tx.announce(io, .prepared);
            tx.prepared = true;
            return;
        }

        for (tx.edits.items) |*edit| {
            const dir = tx.store.dirFor(edit.name);
            if (std.fs.path.dirnamePosix(edit.name)) |parent| {
                fs.makeDirs(io, dir, parent, tx.store.sharedPermissions()) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
            }
            const buffer = try tx.gpa.alloc(u8, 4096);
            edit.lock_buffer = buffer;
            edit.lock = fs.LockFile.open(tx.gpa, io, dir, edit.name, buffer, .{ .shared = tx.store.sharedPermissions() }) catch |err| switch (err) {
                error.LockHeld => return error.LockHeld,
                else => |e| return e,
            };
            // A ref only logged through is held, not checked.
            if (edit.via != null) continue;

            const current = try tx.store.read(tx.gpa, io, edit.name);
            var current_oid: ?Oid = null;
            if (current) |value| {
                switch (value) {
                    .direct => |oid| current_oid = oid,
                    .symbolic => |target| {
                        tx.gpa.free(target);
                        // A symbolic ref's own value is not an object name;
                        // an expected-value check on it is a check on what
                        // it resolves to.
                        if (try tx.store.resolve(tx.gpa, io, edit.name)) |resolved| {
                            tx.gpa.free(resolved.name);
                            current_oid = resolved.oid;
                        }
                    },
                }
                const loose = try tx.store.readLoose(tx.gpa, io, edit.name);
                edit.was_packed = loose == null;
                if (loose) |loose_value| switch (loose_value) {
                    .symbolic => |target| tx.gpa.free(target),
                    .direct => {},
                };
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
                    // ziglint-ignore: Z026 as git's run_transaction_hook for an aborted state: the hook's status changes nothing
                    tx.announceAs(io, .aborted, true) catch {};
                }
            }
            try tx.announce(io, .prepared);
        }
        tx.prepared = true;
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
                        if (!safepath.isValidRefName(target)) return error.InvalidRefName;
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
            // ziglint-ignore: Z026 the refs have moved; as git, a hook failing on "committed" changes nothing
            if (tx.announced) tx.announce(io, .committed) catch {};
            return;
        }

        var rewrite_packed = false;
        for (tx.edits.items) |edit| {
            if (edit.via == null and edit.new == null and edit.was_packed) rewrite_packed = true;
        }
        if (rewrite_packed) try tx.removeFromPacked(io);
        if (tx.packed_announced) {
            tx.packed_announced = false;
            // ziglint-ignore: Z026 packed-refs is rewritten; as git, a hook failing on "committed" changes nothing
            tx.announceAs(io, .committed, true) catch {};
        }

        var hex: [hash.max_hex_len]u8 = undefined;
        for (tx.edits.items) |*edit| {
            // Its lock is given up with the rest, the file as it was.
            if (edit.via != null) continue;
            const lock = &edit.lock.?;
            if (edit.new) |new| {
                switch (new) {
                    .direct => |oid| {
                        lock.writer().print("{s}\n", .{oid.hex(&hex)}) catch return error.WriteFailed;
                    },
                    .symbolic => |target| {
                        lock.writer().print("ref: {s}\n", .{target}) catch return error.WriteFailed;
                    },
                }
                try lock.commit(io);
            } else {
                // A deletion gives the lock up and removes the loose file.
                lock.deinit(io);
                edit.lock = null;
                const dir = tx.store.dirFor(edit.name);
                dir.deleteFile(io, edit.name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
                removeEmptyParents(io, dir, edit.name);
                const log_path = try reflog.pathFor(tx.gpa, edit.name);
                defer tx.gpa.free(log_path);
                dir.deleteFile(io, log_path) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => {},
                    else => |e| return e,
                };
                removeEmptyParents(io, dir, log_path);
            }
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
                try reflog.appendShared(
                    tx.gpa,
                    io,
                    tx.store.dirFor(edit.name),
                    edit.name,
                    old,
                    new,
                    message.who,
                    own orelse shared,
                    tx.store.sharedPermissions(),
                );
            }
        }

        tx.finished = true;
        tx.releaseLocks(io);
        // The refs have moved; a hook failing now changes nothing, and its
        // status is not an error of the transaction's.
        // ziglint-ignore: Z026 the refs have moved; as git, a hook failing on "committed" changes nothing
        if (tx.announced) tx.announce(io, .committed) catch {};
    }

    fn removeFromPacked(tx: *Transaction, io: Io) TransactionError!void {
        var listing = try tx.store.readPacked(tx.gpa, io);
        defer listing.deinit();
        var kept: std.ArrayList(Store.PackedEntry) = .empty;
        defer kept.deinit(tx.gpa);
        for (listing.entries) |entry| {
            var removed = false;
            for (tx.edits.items) |edit| {
                if (edit.via == null and edit.new == null and std.mem.eql(u8, edit.name, entry.name)) removed = true;
            }
            if (!removed) try kept.append(tx.gpa, entry);
        }
        try tx.store.writePacked(io, kept.items);
    }

    /// Give up, leaving the repository exactly as it was. A transaction
    /// that announced itself to `reference-transaction` announces this too.
    pub fn abort(tx: *Transaction, io: Io) void {
        if (!tx.finished) {
            tx.releaseLocks(io);
            tx.finished = true;
            if (tx.packed_announced) {
                tx.packed_announced = false;
                // ziglint-ignore: Z026 as git's run_transaction_hook for an aborted state: the hook's status changes nothing
                tx.announceAs(io, .aborted, true) catch {};
            }
            // ziglint-ignore: Z026 as git's run_transaction_hook for an aborted state: the hook's status changes nothing
            if (tx.announced) tx.announce(io, .aborted) catch {};
        }
    }

    fn releaseLocks(tx: *Transaction, io: Io) void {
        stack_engine.releasePending(io, tx);
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

/// Remove the directories above `path` that are left empty, down to but not
/// including `refs/<kind>/` — or `logs/refs/<kind>/` — which git keeps.
fn removeEmptyParents(io: Io, dir: Io.Dir, path: []const u8) void {
    const keep: usize = if (std.mem.startsWith(u8, path, "logs/")) 3 else 2;
    var current = path;
    while (std.fs.path.dirnamePosix(current)) |parent| {
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

    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    const oid = try Oid.parse(.sha1, "1" ** 40);

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
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = "1" ** 40 ++ "\n" });

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    {
        var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
        defer store.deinit();
        var tx = store.begin(gpa);
        defer tx.deinit(io);
        try tx.update("HEAD", .{ .symbolic = "refs/heads/next" }, .any);
        try tx.prepare(io);
    }
    try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}

test "an expected value that does not hold changes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    const one = try Oid.parse(.sha1, "1" ** 40);
    const two = try Oid.parse(.sha1, "2" ** 40);
    const three = try Oid.parse(.sha1, "3" ** 40);

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

    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    const one = try Oid.parse(.sha1, "1" ** 40);

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
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();

    const one = try Oid.parse(.sha1, "1" ** 40);
    const two = try Oid.parse(.sha1, "2" ** 40);
    const peeled = try Oid.parse(.sha1, "3" ** 40);
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
    const three = try Oid.parse(.sha1, "4" ** 40);
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
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    // Another writer: a store of its own over the same directory.
    var other: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer other.deinit();
    const loads = &state_mod.get(store._state).packed_refs.?.loads;

    const one = try Oid.parse(.sha1, "1" ** 40);
    const two = try Oid.parse(.sha1, "2" ** 40);
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
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
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
    try std.testing.expect((try store.read(gpa, io, "refs/tagsx")).?.direct.eql(try Oid.parse(.sha1, "4" ** 40)));
}

test "deleting a packed ref removes it from the packed file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();

    const one = try Oid.parse(.sha1, "1" ** 40);
    const two = try Oid.parse(.sha1, "2" ** 40);
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

test "a ref name ending in .lock is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
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
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    const one = try Oid.parse(.sha1, "1" ** 40);
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
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir);
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
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir);
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
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir);
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
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = "1" ** 40 ++ "\n" });
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .direct = try Oid.parse(.sha1, "2" ** 40) }, .any);
    try tx.update("refs/heads/main", .{ .direct = try Oid.parse(.sha1, "3" ** 40) }, .any);
    try std.testing.expectError(error.DuplicateEdit, tx.commit(io, null));
    const main = (try store.read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(main.direct.eql(try Oid.parse(.sha1, "1" ** 40)));
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
        const body = try std.fmt.bufPrint(&body_buf, ".git/rt.log\n{s}", .{state});
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
        var store: Store = try .init(gpa, .sha1, git_dir, git_dir);
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
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir);
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
    // git removes the directories a deleted ref leaves empty from 2.31 on.
    try testgit.requireGitVersion(gpa, io, 2, 31);
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
    var store: Store = try .init(gpa, .sha1, git_dir, git_dir);
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
            try paths.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.path }));
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
    var store: Store = try .init(gpa, .sha1, tmp.dir, tmp.dir);
    defer store.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = packed_header ++ "1" ** 40 ++ " refs/heads/main\n" });
    try std.testing.checkAllAllocationFailures(gpa, readPackedForAllocation, .{ io, tmp.dir });
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = "not a ref\n" });
    try std.testing.expectError(error.MalformedPackedRefs, store.readPacked(gpa, io));
}

fn readPackedForAllocation(gpa: Allocator, io: Io, dir: Io.Dir) !void {
    var store: Store = try .init(gpa, .sha1, dir, dir);
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
    try tmp.dir.writeFile(io, .{ .sub_path = "packed-refs", .data = packed_header ++ "1" ** 40 ++ " refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = "ref: refs/heads/" ++ "a" ** 2000 ++ "\n" });
    try std.testing.checkAllAllocationFailures(gpa, listLooseRefsForAllocation, .{ io, tmp.dir });
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
    var store: Store = try .init(gpa, .sha1, dir, dir);
    defer store.deinit();
    var listed = try store.list(gpa, io, "refs/heads/");
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.entries.len);
    try std.testing.expect(listed.entries[0].loose);
    try std.testing.expectEqualStrings("refs/heads/" ++ "a" ** 2000, listed.entries[0].target.symbolic);
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
        var main_store: Store = try .initWithOptions(gpa, .sha1, common, common, .{ .format = format });
        defer main_store.deinit();
        var linked_store: Store = try .initWithOptions(gpa, .sha1, admin, common, .{ .format = format });
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
