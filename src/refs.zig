//! Loose refs and `packed-refs`, with transactions.
//!
//! A transaction takes every `<ref>.lock` in its prepare step and rolls back
//! completely if any one of them is held. Once `commit` starts, loose refs
//! are installed with separate renames and reflogs with separate appends, as
//! they are in git: an I/O error can leave a committed prefix and the caller
//! must reread the refs before deciding what happened.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const fs = @import("fs.zig");
const safepath = @import("safepath.zig");
const reflog = @import("reflog.zig");
const hooks = @import("hooks.zig");
const testgit = @import("testgit.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// The header `packed-refs` carries, with the space before the newline that
/// is in git's source and in no document.
pub const packed_header = "# pack-refs with: peeled fully-peeled sorted \n";

/// How deep a chain of symbolic refs may go. git's own cap.
pub const max_symbolic_depth: u8 = 5;

/// Errors from reading refs.
pub const ReadError = error{
    /// A loose ref file that is neither an object name nor `ref: <name>`.
    MalformedRef,
    /// A `packed-refs` line that is neither a ref nor a peel nor a comment.
    MalformedPackedRefs,
    /// A symbolic ref chain longer than `max_symbolic_depth`, or one that
    /// came back to a name it had already been through.
    SymbolicRefLoop,
    /// A ref name git would not accept — including one ending in `.lock`,
    /// which is the name of the file that blocks every update to the ref
    /// without it.
    InvalidRefName,
} || Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error;

/// Errors from a transaction.
pub const TransactionError = error{
    /// The ref's current value is not the one the edit expected. Nothing has
    /// changed.
    ExpectedValueMismatch,
    /// The ref exists and the edit required that it did not.
    RefAlreadyExists,
    /// The ref does not exist and the edit required that it did.
    RefNotFound,
    /// Another writer holds `<ref>.lock`. Nothing has changed and the lock
    /// is exactly as it was found.
    LockHeld,
    /// The same ref was named twice in one transaction.
    DuplicateEdit,
    /// A ref name and a directory of refs cannot both exist:
    /// `refs/heads/a` and `refs/heads/a/b` are the same path.
    RefNameConflict,
} || ReadError || fs.CommitError || fs.LockError || reflog.AppendError ||
    Io.Dir.DeleteFileError || Io.Dir.CreateDirPathError || hooks.Error;

/// What a ref points at.
pub const Ref = union(enum) {
    /// An object name.
    direct: Oid,
    /// Another ref's name, which is what `HEAD` usually holds. Owned by
    /// whatever produced it.
    symbolic: []const u8,
};

/// A ref with its name, as `list` hands them back.
pub const Named = struct {
    /// Owned by the listing.
    name: []const u8,
    target: Ref,
    /// The object an annotated tag points at, when `packed-refs` carried a
    /// peel line for it.
    peeled: ?Oid = null,
    /// Whether the ref was found loose rather than in `packed-refs`.
    loose: bool,
};

/// A fully resolved ref: the name it ended at and the object it points to.
pub const Resolved = struct {
    /// The last name in the chain. Owned by the caller.
    name: []const u8,
    oid: Oid,
};

/// What an edit requires the ref's current value to be.
pub const Expected = union(enum) {
    /// Whatever it is.
    any,
    /// It must not exist.
    must_not_exist,
    /// It must exist, with any value.
    must_exist,
    /// It must be exactly this.
    matches: Oid,
};

/// Loose refs and `packed-refs` behind one reader.
///
/// `git_dir` is the per-worktree directory and `common_dir` the shared one;
/// they are the same in a repository with no linked worktrees. `HEAD`,
/// `refs/bisect`, `refs/worktree` and `refs/rewritten` are per-worktree and
/// everything else is shared, which is the fixed list git uses.
pub const Store = struct {
    gpa: Allocator,
    kind: Kind,
    git_dir: Io.Dir,
    common_dir: Io.Dir,

    /// Open over an already-opened pair of directories, which the store does
    /// not close.
    pub fn init(gpa: Allocator, kind: Kind, git_dir: Io.Dir, common_dir: Io.Dir) Store {
        return .{ .gpa = gpa, .kind = kind, .git_dir = git_dir, .common_dir = common_dir };
    }

    /// Which directory a ref lives in.
    pub fn dirFor(store: *const Store, name: []const u8) Io.Dir {
        if (std.mem.eql(u8, name, "HEAD") or
            std.mem.eql(u8, name, "ORIG_HEAD") or
            std.mem.eql(u8, name, "FETCH_HEAD") or
            std.mem.eql(u8, name, "MERGE_HEAD") or
            std.mem.eql(u8, name, "CHERRY_PICK_HEAD") or
            std.mem.eql(u8, name, "REVERT_HEAD") or
            std.mem.eql(u8, name, "BISECT_HEAD") or
            std.mem.startsWith(u8, name, "refs/bisect/") or
            std.mem.startsWith(u8, name, "refs/worktree/") or
            std.mem.startsWith(u8, name, "refs/rewritten/"))
        {
            return store.git_dir;
        }
        return store.common_dir;
    }

    /// Read one ref, loose first and then `packed-refs`, or `null`.
    ///
    /// A symbolic ref comes back as `.symbolic` without being followed; use
    /// `resolve` for the object. The returned name, when symbolic, is the
    /// caller's.
    pub fn read(store: *const Store, gpa: Allocator, io: Io, name: []const u8) ReadError!?Ref {
        if (!isReadableName(name)) return error.InvalidRefName;
        if (try store.readLoose(gpa, io, name)) |found| return found;
        var listing = try store.readPacked(gpa, io);
        defer listing.deinit();
        if (listing.find(name)) |entry| return .{ .direct = entry.oid };
        return null;
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
        const oid = Oid.parse(store.kind, trimmed) catch return error.MalformedRef;
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
        const found = (try store.readLoose(gpa, io, "HEAD")) orelse return null;
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
    pub const Listing = struct {
        gpa: Allocator,
        arena: std.heap.ArenaAllocator.State,
        entries: []Named,

        /// Release the listing and everything in it.
        pub fn deinit(listing: *Listing) void {
            var arena = listing.arena.promote(listing.gpa);
            arena.deinit();
            listing.* = undefined;
        }

        /// The entry named `name`, or `null`. A linear walk over a sorted
        /// list; the lists are small enough that a bisection would only make
        /// the code longer.
        pub fn find(listing: *const Listing, name: []const u8) ?Named {
            for (listing.entries) |entry| {
                if (std.mem.eql(u8, entry.name, name)) return entry;
            }
            return null;
        }
    };

    /// Every ref whose name begins with `prefix`, sorted by name.
    ///
    /// A loose ref shadows a packed one of the same name, which is what git
    /// does and what makes a `pack-refs` that has not yet removed the loose
    /// file harmless.
    pub fn list(store: *const Store, gpa: Allocator, io: Io, prefix: []const u8) ReadError!Listing {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var entries: std.ArrayList(Named) = .empty;

        var packed_listing = try store.readPacked(gpa, io);
        defer packed_listing.deinit();
        for (packed_listing.entries) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            try entries.append(arena, .{
                .name = try arena.dupe(u8, entry.name),
                .target = .{ .direct = entry.oid },
                .peeled = entry.peeled,
                .loose = false,
            });
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
        const dirs = [_]Io.Dir{ store.common_dir, store.git_dir };
        var seen_same = false;
        for (dirs) |dir| {
            if (seen_same) break;
            if (dir.handle == store.common_dir.handle and store.git_dir.handle == store.common_dir.handle) {
                seen_same = true;
            }
            var refs_dir = dir.openDir(io, "refs", .{ .iterate = true }) catch continue;
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
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                try store.walkLooseDir(arena, io, sub, child_path, out, prefix, depth + 1);
                continue;
            }
            if (!std.mem.startsWith(u8, child_path, prefix) and !std.mem.startsWith(u8, prefix, child_path)) continue;
            if (!std.mem.startsWith(u8, child_path, prefix)) continue;
            if (!safepath.isValidRefName(child_path)) continue;
            const target = (store.readLoose(arena, io, child_path) catch continue) orelse continue;
            try out.append(arena, .{ .name = child_path, .target = target, .loose = true });
        }
    }

    /// One line of `packed-refs`.
    pub const PackedEntry = struct {
        name: []const u8,
        oid: Oid,
        /// The object an annotated tag points at, from a `^` line.
        peeled: ?Oid,
    };

    /// Everything `packed-refs` holds.
    pub const PackedListing = struct {
        gpa: Allocator,
        bytes: []u8,
        entries: []PackedEntry,
        /// Whether the header claimed every tag is peeled.
        fully_peeled: bool,

        /// Release the listing.
        pub fn deinit(listing: *PackedListing) void {
            listing.gpa.free(listing.entries);
            listing.gpa.free(listing.bytes);
            listing.* = undefined;
        }

        /// The entry named `name`, or `null`.
        pub fn find(listing: *const PackedListing, name: []const u8) ?PackedEntry {
            for (listing.entries) |entry| {
                if (std.mem.eql(u8, entry.name, name)) return entry;
            }
            return null;
        }
    };

    /// Read `packed-refs`. An absent file is an empty listing.
    pub fn readPacked(store: *const Store, gpa: Allocator, io: Io) ReadError!PackedListing {
        const bytes = (try fs.readFileAlloc(gpa, io, store.common_dir, "packed-refs", 1 << 28)) orelse
            return .{ .gpa = gpa, .bytes = try gpa.alloc(u8, 0), .entries = try gpa.alloc(PackedEntry, 0), .fully_peeled = false };
        errdefer gpa.free(bytes);
        return parsePacked(gpa, store.kind, bytes);
    }

    /// Parse `packed-refs` bytes this takes ownership of.
    pub fn parsePacked(gpa: Allocator, kind: Kind, bytes: []u8) ReadError!PackedListing {
        errdefer gpa.free(bytes);
        var entries: std.ArrayList(PackedEntry) = .empty;
        errdefer entries.deinit(gpa);
        var fully_peeled = false;

        const hex_len = kind.hexLen();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var first = true;
        while (lines.next()) |raw| {
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) continue;
            if (line[0] == '#') {
                if (first and std.mem.indexOf(u8, line, "fully-peeled") != null) fully_peeled = true;
                first = false;
                continue;
            }
            first = false;
            if (line[0] == '^') {
                if (entries.items.len == 0) return error.MalformedPackedRefs;
                const oid = Oid.parse(kind, std.mem.trim(u8, line[1..], " \t")) catch return error.MalformedPackedRefs;
                entries.items[entries.items.len - 1].peeled = oid;
                continue;
            }
            if (line.len < hex_len + 2) return error.MalformedPackedRefs;
            const oid = Oid.parse(kind, line[0..hex_len]) catch return error.MalformedPackedRefs;
            if (line[hex_len] != ' ') return error.MalformedPackedRefs;
            const name = line[hex_len + 1 ..];
            if (!safepath.isValidRefName(name)) return error.InvalidRefName;
            try entries.append(gpa, .{ .name = name, .oid = oid, .peeled = null });
        }
        return .{
            .gpa = gpa,
            .bytes = bytes,
            .entries = try entries.toOwnedSlice(gpa),
            .fully_peeled = fully_peeled,
        };
    }

    /// Write `packed-refs` from `entries`, which must be sorted by name.
    ///
    /// The header is exact, including the space before its newline, because
    /// git compares it when it decides whether every tag in the file is
    /// already peeled.
    pub fn writePacked(store: *const Store, io: Io, entries: []const PackedEntry) TransactionError!void {
        var buffer: [64 * 1024]u8 = undefined;
        var lock = try fs.LockFile.open(store.gpa, io, store.common_dir, "packed-refs", &buffer, .{});
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
    }

    /// Begin a transaction over this store.
    pub fn begin(store: *Store, gpa: Allocator) Transaction {
        return .{ .store = store, .gpa = gpa, .edits = .empty };
    }
};

fn isReadableName(name: []const u8) bool {
    // A pseudo-ref such as `HEAD` or `ORIG_HEAD` is upper case with no
    // slash, which `checkRefName` would otherwise allow through anyway; the
    // check that matters is the `.lock` suffix and the traversal rules.
    return safepath.isValidRefName(name);
}

/// What a log entry a transaction writes says.
pub const LogMessage = struct {
    who: object.Signature,
    /// The text after the tab, which the transaction collapses as git
    /// does: every run of whitespace one space, none at either end. Empty
    /// writes no tab.
    message: []const u8 = "",
    policy: reflog.Policy = .standard,
};

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

    /// One ref's change.
    pub const Edit = struct {
        /// Owned by the transaction.
        name: []const u8,
        /// `null` deletes the ref.
        new: ?Ref,
        expected: Expected,
        /// Filled in by `prepare`.
        old: ?Oid = null,
        lock: ?fs.LockFile = null,
        lock_buffer: []u8 = &.{},
        /// Whether the old value came from `packed-refs` rather than a loose
        /// file, which decides whether the packed file has to be rewritten.
        was_packed: bool = false,
        /// Whether to go through the ref to the one it names, when it is
        /// symbolic.
        deref: bool = true,
        /// Set by `prepare` on a symbolic ref an update went through, and on
        /// `HEAD` when the branch it names moves: the ref is locked and its
        /// log gains the line, and its own value is left alone. The line's
        /// values are those of the edit at `via`.
        via: ?usize = null,
    };

    /// How one edit treats a symbolic ref.
    pub const EditOptions = struct {
        /// Change the named ref itself even when it is symbolic, rather than
        /// the ref it names: git's `--no-deref`.
        no_deref: bool = false,
    };

    /// Release the transaction, rolling back anything `prepare` took.
    pub fn deinit(tx: *Transaction, io: Io) void {
        tx.abort(io);
        for (tx.edits.items) |edit| {
            tx.gpa.free(edit.name);
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
        tx.edits.items[tx.edits.items.len - 1].deref = !options.no_deref;
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

        for (tx.edits.items) |*edit| {
            const dir = tx.store.dirFor(edit.name);
            if (std.fs.path.dirnamePosix(edit.name)) |parent| {
                dir.createDirPath(io, parent) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
            }
            const buffer = try tx.gpa.alloc(u8, 4096);
            edit.lock_buffer = buffer;
            edit.lock = fs.LockFile.open(tx.gpa, io, dir, edit.name, buffer, .{}) catch |err| switch (err) {
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
                const found = (try tx.store.readLoose(tx.gpa, io, at)) orelse break;
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
        const head = (try tx.store.readLoose(tx.gpa, io, "HEAD")) orelse return;
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
        _ = try runner.referenceTransaction(io, tx.store.kind, state, lines.items);
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

        var rewrite_packed = false;
        for (tx.edits.items) |edit| {
            if (edit.via == null and edit.new == null and edit.was_packed) rewrite_packed = true;
        }
        if (rewrite_packed) try tx.removeFromPacked(io);
        if (tx.packed_announced) {
            tx.packed_announced = false;
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
            const text = try reflog.normalizeMessage(tx.gpa, message.message);
            defer tx.gpa.free(text);
            for (tx.edits.items) |edit| {
                // A deleted ref's log went with it.
                if (edit.via == null and edit.new == null) continue;
                // A ref logged through records what the ref at the end of it
                // did.
                const source = if (edit.via) |at| tx.edits.items[at] else edit;
                const old = source.old orelse Oid.zero(tx.store.kind);
                const new = switch (source.new orelse Ref{ .direct = Oid.zero(tx.store.kind) }) {
                    .direct => |oid| oid,
                    // A symbolic ref's log records what it now resolves to.
                    .symbolic => blk: {
                        const resolved = try tx.store.resolve(tx.gpa, io, source.name);
                        if (resolved) |r| {
                            defer tx.gpa.free(r.name);
                            break :blk r.oid;
                        }
                        break :blk Oid.zero(tx.store.kind);
                    },
                };
                const exists = try reflog.exists(io, tx.store.dirFor(edit.name), tx.gpa, edit.name);
                if (!reflog.shouldLog(message.policy, edit.name, exists)) continue;
                try reflog.append(
                    tx.gpa,
                    io,
                    tx.store.dirFor(edit.name),
                    edit.name,
                    old,
                    new,
                    message.who,
                    text,
                );
            }
        }

        tx.finished = true;
        tx.releaseLocks(io);
        // The refs have moved; a hook failing now changes nothing, and its
        // status is not an error of the transaction's.
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
                tx.announceAs(io, .aborted, true) catch {};
            }
            if (tx.announced) tx.announce(io, .aborted) catch {};
        }
    }

    fn releaseLocks(tx: *Transaction, io: Io) void {
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

    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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
        var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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

    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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

    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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
    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);

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
    try std.testing.expect(std.mem.indexOf(u8, text, "^3333") != null);

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

test "deleting a packed ref removes it from the packed file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);

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
    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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
    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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

    fn init(gpa: Allocator, io: Io, hook_body: []const u8) !HookTwin {
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
            try r.writeFile(io, ".git/hooks/reference-transaction", hook_body);
            const file = try r.dir.openFile(io, ".git/hooks/reference-transaction", .{});
            defer file.close(io);
            try file.setPermissions(io, .fromMode(0o755));
        }
        return t;
    }

    fn deinit(t: *HookTwin) void {
        t.environ.deinit();
        t.git.deinit();
        t.relic.deinit();
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

const logging_hook = "#!/bin/sh\n{ echo \"$1\"; cat; } >> .git/rt.log\n";

test "reference-transaction hears from a transaction what git's hears" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var twin = try HookTwin.init(gpa, io, logging_hook);
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
    var config = try @import("config.zig").Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = twin.relic.dir,
    }, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    var store: Store = .init(gpa, .sha1, git_dir, git_dir);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var twin = try HookTwin.init(gpa, io, logging_hook);
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
    var config = try @import("config.zig").Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = twin.relic.dir,
    }, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    var store: Store = .init(gpa, .sha1, git_dir, git_dir);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var twin = try HookTwin.init(gpa, io, "#!/bin/sh\n");
    defer twin.deinit();
    const head_text = try twin.relic.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const message = "  commit:\tsubject  line\n\n  body \r\n";
    try twin.gitWithHooks(io, &.{ "update-ref", "-m", message, "refs/heads/topic", head_text });

    var git_dir = try twin.relic.gitDir(io);
    defer git_dir.close(io);
    var store: Store = .init(gpa, .sha1, git_dir, git_dir);
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
    var store: Store = .init(gpa, .sha1, tmp.dir, tmp.dir);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "preparing", "prepared" }) |state| {
        var body_buf: [160]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "#!/bin/sh\n{{ echo \"$1\"; cat; }} >> .git/rt.log\n[ \"$1\" = {s} ] && exit 1\nexit 0\n", .{state});
        var twin = try HookTwin.init(gpa, io, body);
        defer twin.deinit();
        const head_text = try twin.git.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(head_text);
        const head = try Oid.parse(.sha1, head_text);

        twin.git.report_failures = false;
        try std.testing.expectError(error.GitFailed, twin.gitWithHooks(io, &.{ "update-ref", "refs/heads/topic", head_text }));

        var git_dir = try twin.relic.gitDir(io);
        defer git_dir.close(io);
        var config = try @import("config.zig").Config.parseText(gpa, "", .local);
        defer config.deinit();
        var runner = try hooks.Runner.init(gpa, io, .{
            .config = &config,
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = twin.relic.dir,
        }, .{ .environ = &twin.environ }, .{ .output = .ignore });
        defer runner.deinit();
        var store: Store = .init(gpa, .sha1, git_dir, git_dir);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var twin = try HookTwin.init(gpa, io, logging_hook);
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
    var config = try @import("config.zig").Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = twin.relic.dir,
    }, .{ .environ = &twin.environ }, .{ .output = .ignore });
    defer runner.deinit();
    var store: Store = .init(gpa, .sha1, git_dir, git_dir);
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
    inline for (.{ &git, &here }) |r| {
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
    var store: Store = .init(gpa, .sha1, git_dir, git_dir);
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
    try std.testing.expect(std.mem.indexOf(u8, listing_b, "heads/a") == null);
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
