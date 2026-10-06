//! Working trees recorded in a private object store.
//!
//! A snapshot is a tree, without parents or refs. Every tree and blob it
//! reaches belongs to this store before capture or adoption returns. The source's
//! index supplies tracked paths, including ignored ones; its files supply
//! the contents. No source index, ref or object is written. Gitlinks name
//! another repository's commit, and LFS pointers name separate LFS data;
//! neither is an edge in the Git object closure.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb = @import("../odb.zig");
const index = @import("../index.zig");
const repo = @import("../repo.zig");
const worktree = @import("../worktree.zig");
const diff_mod = @import("../diff.zig");
const filter = @import("filter.zig");
const program = @import("../repo/program.zig");
const fs = @import("../repo/fs.zig");
const opening = @import("../odb/open.zig");

pub const Error = worktree.Error || repo.Error || repo.Repository.LoadFiltersError ||
    diff_mod.Error || error{ BareRepository, ObjectFormatMismatch, TreeDepthExceeded };

/// A retained tree ID is all that is needed to reopen a snapshot. The
/// caller keeps its IDs and decides their order and when to prune objects.
pub const Snapshot = struct { tree: hash.Oid };

/// Borrowed for one capture. A folder reads its own `.gitignore` and
/// `.gitattributes`, with no repository configuration or tracked paths.
pub const Source = union(enum) {
    repository: *repo.Repository,
    folder: Io.Dir,
};

pub const OpenOptions = struct {
    /// Durable capture syncs the owned closure before returning its ID;
    /// restore syncs file bytes and directories before success. Off by
    /// default because each barrier waits on storage.
    durability: fs.Durability = .none,
    kind: hash.Kind = .sha1,
    odb: odb.Options = .{},
};

pub const CaptureOptions = struct {
    /// Permission to run the source's configured filter programs.
    programs: ?program.Programs = null,
    filter_report: ?*filter.Report = null,
    refusal: ?*worktree.Refusal = null,
};

pub const Captured = struct {
    snapshot: Snapshot,
    staged: worktree.AddOutcome,
};

pub const RestoreOptions = struct {
    /// The tree previously written to this destination. Its paths absent
    /// from the new snapshot are removed. With null, other paths remain.
    from: ?Snapshot = null,
    /// Checkout's overwrite policy, conversion rules and diagnostics.
    /// By default a file already in the way is refused.
    checkout: worktree.CheckoutOptions = .{},
};

/// One owner for the private database and its completed-subtree cache.
/// The caller serializes operations and keeps the directory's objects
/// until every retained snapshot that needs them has been released. Close
/// the store before pruning its objects, and reopen it afterwards.
pub const Store = struct {
    gpa: Allocator,
    dir: Io.Dir,
    db: odb.Odb,
    durability: fs.Durability,
    /// Only inserted after the entire subtree has been taken into db.
    /// It is a shortcut, not persistent state: reopening walks once again.
    complete: std.AutoHashMapUnmanaged(hash.Oid, void) = .empty,

    /// Open or create a private store in `dir`. Its own handle is retained;
    /// the caller may close the supplied handle. No Git repository is needed.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: OpenOptions) Self.Error!Store {
        const owned = try dir.openDir(io, ".", .{ .iterate = true });
        errdefer owned.close(io);
        try owned.createDirPath(io, "objects/pack");
        try owned.createDirPath(io, "objects/info");
        var db = try opening.openOwn(odb.Odb, gpa, io, owned, options.kind, options.odb);
        errdefer db.deinit(io);
        return .{ .gpa = gpa, .dir = owned, .db = db, .durability = options.durability };
    }

    pub fn deinit(store: *Store, io: Io) void {
        store.complete.deinit(store.gpa);
        store.db.deinit(io);
        store.dir.close(io);
        store.* = undefined;
    }

    /// Record tracked and untracked-not-ignored files under the source's
    /// ignore, attribute and filter rules. Its index supplies membership,
    /// never cached file contents: every file is checked afresh, including
    /// assume-unchanged and skip-worktree entries present on disk.
    /// A failed capture returns no snapshot; objects already copied are
    /// harmless and reusable by the next capture.
    pub fn capture(store: *Store, io: Io, source: Source, options: CaptureOptions) Self.Error!Captured {
        const source_repo: ?*repo.Repository = switch (source) {
            .repository => |r| r,
            .folder => null,
        };
        if (source_repo) |r| {
            if (r.objectFormat() != store.db.objectFormat()) return error.ObjectFormatMismatch;
        }
        const wt = switch (source) {
            .repository => |r| r.work_dir orelse return error.BareRepository,
            .folder => |dir| dir,
        };
        var ignored = if (source_repo) |r| try r.loadIgnore(io) else try worktree.ignore.Rules.init(store.gpa, false);
        defer ignored.deinit();
        var attrs = if (source_repo) |r| try r.loadAttrs(io) else try worktree.attributes.Attrs.init(store.gpa, false);
        defer attrs.deinit();
        var drivers: ?filter.Drivers = null;
        defer if (drivers) |*d| d.deinit();
        if (source_repo) |r| {
            const lfsconfig = try r.lfsconfigText(io);
            defer if (lfsconfig) |text| r.gpa.free(text);
            // Native LFS writes to the private store, never to the source.
            drivers = try filter.Drivers.load(store.gpa, io, r.configuration(), store.dir, wt, .{ .lfsconfig = lfsconfig });
            // lfs.storage belongs to the source's storage policy. Its rules
            // still apply, but even an absolute storage path cannot redirect
            // a snapshot write out of the private store.
            if (drivers.?.lfs) |*lfs| lfs.store = .{ .base = store.dir, .root = "lfs" };
        }
        var rules = if (source_repo) |r| try r.worktreeRules() else worktree.Rules{};
        rules.ignore = &ignored;
        rules.attrs = &attrs;
        rules.filters = if (drivers) |*d| d else null;
        var staged = if (source_repo) |r|
            try index.Index.readWithResolution(store.gpa, io, r.git_dir, "index", r.common_dir, r.objectFormat(), r.odb.timestamp_resolution)
        else
            index.Index.initEmpty(store.gpa, store.db.objectFormat());
        defer staged.deinit();
        // The source index is a membership list, not a cache for this store.
        // Sparse directories keep their indexed contents from the source.
        const source_db: ?*odb.Odb = if (source_repo) |r| &r.odb else null;
        try @import("../index/sparseindex.zig").expand(store.gpa, io, &staged, source_db orelse &store.db, null);
        for (staged.entries.items) |*entry| {
            entry.stat = .none;
            entry.assume_valid = false;
            // A sparse path absent by policy still has its indexed content.
            // A present one must be read, even when Git marked it skipped.
            if (entry.skip_worktree and try fs.statAt(io, wt, entry.path) != null) entry.skip_worktree = false;
        }
        // The first capture of a large tree writes every blob in it, and
        // as loose objects that is a create and a rename each: past git's
        // unpack limit the rest go into one pack, and the trees after them.
        const outcome = try worktree.addAll(store.gpa, io, wt, &staged, &store.db, .{
            .rules = rules,
            .new_blobs = .auto,
            .programs = options.programs,
            .filter_report = options.filter_report,
            .refusal = options.refusal,
        });
        const tree = if (outcome.pack != null) try store.writeEveryTree(io, &staged) else try worktree.writeTree(store.gpa, io, &staged, &store.db);
        const recorded = try store.recordTree(io, tree, source_db);
        return .{ .snapshot = recorded, .staged = outcome };
    }

    /// Write every tree the index describes into one pack, rather than only
    /// the ones its cache tree says changed: the rest would otherwise be
    /// borrowed from the source and copied in one loose object at a time.
    fn writeEveryTree(store: *Store, io: Io, staged: *index.Index) Error!hash.Oid {
        (try staged.cacheTree()).invalidateAll();
        const filling = try store.db.beginPack(io, .{ .delta = .none });
        errdefer store.db.abortPack(io, filling);
        const tree = try worktree.writeTreeInto(store.gpa, io, staged, &store.db, filling);
        _ = try store.db.finishPack(io, filling);
        return tree;
    }

    /// Take an existing tree and every reachable tree and blob into this
    /// store without reading a working tree. Objects may already be split
    /// between the store and source; the source is borrowed for this call.
    /// Migrate retained IDs while their old objects still exist. Gitlinks
    /// and LFS payloads keep their separate owners, as with capture.
    pub fn adoptTree(store: *Store, io: Io, source: *odb.Odb, tree: hash.Oid) Self.Error!Snapshot {
        if (source.objectFormat() != store.db.objectFormat() or tree.kind != store.db.objectFormat()) return error.ObjectFormatMismatch;
        return store.recordTree(io, tree, source);
    }

    fn recordTree(store: *Store, io: Io, tree: hash.Oid, source: ?*odb.Odb) Error!Snapshot {
        try store.ownTree(io, tree, source, 0);
        try store.db.syncBatch(io);
        if (store.durability == .durable) {
            try store.db.makeDurable(io, &.{tree});
            try @import("../repo/fs/durability.zig").syncDirectory(io, store.dir, ".");
        }
        return .{ .tree = tree };
    }

    // A tree being present is not a certificate for its descendants: writeTree
    // can have just written it while its unchanged children remain borrowed.
    // Only a completed walk may put a tree in the shortcut cache.
    fn ownTree(store: *Store, io: Io, oid: hash.Oid, source_db: ?*odb.Odb, depth: u32) Error!void {
        if (store.complete.contains(oid)) return;
        if (depth > 128) return error.TreeDepthExceeded;
        try store.ownObject(io, oid, source_db, .tree);
        const found = try store.db.read(io, oid);
        defer store.gpa.free(found.bytes);
        if (found.type != .tree) return error.UnexpectedObjectType;
        var tree = object.Tree.parse(store.db.objectFormat(), found.bytes);
        var entries = tree.iterate();
        while (try entries.next()) |entry| switch (entry.mode) {
            .tree => try store.ownTree(io, entry.oid, source_db, depth + 1),
            .gitlink => {},
            .file, .exec, .symlink => try store.ownObject(io, entry.oid, source_db, .blob),
        };
        // A cache must not turn the caller's retained history into an
        // unbounded amount of live memory. Missing entries only cost a walk.
        if (store.complete.count() < 4096) try store.complete.put(store.gpa, oid, {});
    }

    // The source is a reader for this capture alone. Attaching it to db
    // would let a live restore prefer a source pack over our own loose copy.
    fn ownObject(store: *Store, io: Io, oid: hash.Oid, source_db: ?*odb.Odb, expected: object.Type) Error!void {
        if (try store.db.existsOwn(io, oid)) {
            if ((try store.db.readHeader(io, oid)).type != expected) return error.UnexpectedObjectType;
            return;
        }
        const source = source_db orelse return error.ObjectNotFound;
        const found = try source.read(io, oid);
        defer source.allocator().free(found.bytes);
        if (found.type != expected) return error.UnexpectedObjectType;
        const written = try store.db.write(io, found.type, found.bytes);
        if (!written.eql(oid)) return error.ObjectNameMismatch;
    }

    /// Materialize a snapshot using checkout's path checks and overwrite
    /// policy. Tree attributes apply even in an empty destination; callers
    /// may supply core settings and filter drivers through `checkout.rules`.
    pub fn restore(store: *Store, io: Io, snapshot: Snapshot, wt: Io.Dir, options: RestoreOptions) Self.Error!worktree.CheckoutOutcome {
        if (snapshot.tree.kind != store.db.objectFormat()) return error.ObjectFormatMismatch;
        if (options.from) |before| if (before.tree.kind != store.db.objectFormat()) return error.ObjectFormatMismatch;
        var staged: index.Index = .initEmpty(store.gpa, store.db.objectFormat());
        defer staged.deinit();
        if (options.from) |before| _ = try worktree.resetIndex(store.gpa, io, &staged, &store.db, before.tree);
        var attrs = try worktree.attributes.Attrs.init(store.gpa, options.checkout.rules.ignore_case);
        defer attrs.deinit();
        var checkout = options.checkout;
        if (store.durability == .durable) checkout.durability = .durable;
        if (checkout.rules.attrs == null) checkout.rules.attrs = &attrs;
        return worktree.checkout(store.gpa, io, wt, &staged, &store.db, snapshot.tree, checkout);
    }

    /// Compare snapshot trees; null names an empty tree. The returned
    /// changes belong to the caller and use the ordinary diff API.
    pub fn diff(store: *Store, io: Io, before: ?Snapshot, after: ?Snapshot, options: diff_mod.TreeOptions) Self.Error!diff_mod.Changes {
        if (before) |s| if (s.tree.kind != store.db.objectFormat()) return error.ObjectFormatMismatch;
        if (after) |s| if (s.tree.kind != store.db.objectFormat()) return error.ObjectFormatMismatch;
        return diff_mod.tree(store.gpa, io, &store.db, if (before) |s| s.tree else null, if (after) |s| s.tree else null, options);
    }
};
