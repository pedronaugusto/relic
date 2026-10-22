//! git's `repack` (`builtin/repack.c`, `repack.c`, `repack-cruft.c`,
//! `repack-promisor.c`, and the paths of `pack-objects` it asks for): the
//! reachable objects into a new pack, the unreachable ones kept in it, turned
//! loose or put into a cruft pack with each one's time, the packs this
//! replaces taken away, and the files a dumb HTTP client reads written.
//!
//! The order is the one a running git survives, as git's: every new pack is
//! written and readable, and every object turned loose is written, before
//! any pack goes; a loose object goes only once a pack holds it.

const Self = @This();
const std = @import("std");
const date = @import("../text.zig").date;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const odb_mod = @import("../odb/odb.zig");
const pack_mod = @import("../odb/pack.zig");
const rev_index = @import("../odb/rev_index.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const object_walk = @import("../walk/object.zig").walk;
const program = @import("../process/program.zig");
const reach = @import("reach.zig");
const ops = @import("maintenance.zig");
const server_info = @import("server_info.zig");
const islands_mod = @import("islands.zig");
const islands_odb = @import("../odb/islands.zig");
const promisors = @import("../wire.zig").promisors;
const in_progress = @import("../repo/in_progress.zig");
const Repository = repo_mod.Repository;
const Odb = odb_mod.Odb;

/// What goes into the new pack, and what becomes of the rest.
pub const Mode = enum {
    /// git's default (`--unpacked --incremental`): the reachable objects
    /// no pack holds, into a new pack beside the others.
    loose,
    /// `-a`: every reachable object into one pack.
    all,
    /// `-A`: as `-a`, and with `delete` the unreachable objects of the
    /// packs it takes away written loose first.
    all_loosen,
    /// `--cruft`: as `-a`, and the unreachable objects into a cruft pack,
    /// each with its time in the pack's `.mtimes`.
    cruft,
};

/// git's `repack` options. Those left `null` are read from the
/// repository's configuration as git reads them.
pub const Options = struct {
    mode: Mode = .loose,
    /// `-d`: the packs the new ones replace go, then `prune-packed`.
    delete: bool = false,
    /// `-k`, with `-a` and `-d`: the unreachable objects go into the new
    /// pack too.
    keep_unreachable: bool = false,
    /// `--unpack-unreachable=<date>`, with `-A`: an unreachable object
    /// whose pack is no newer than this, and which no recent object
    /// reaches, is not turned loose but dropped. `null` turns every one
    /// loose.
    unpack_unreachable: ?date.Expiry = null,
    /// `--cruft-expiration`: with `--cruft`, the unreachable objects no
    /// newer than this, and that no newer one reaches, go into no cruft
    /// pack, and so go. `null` keeps every one.
    cruft_expiration: ?date.Expiry = null,
    /// `--expire-to`, with `--cruft` and `-d`: what the cruft pack leaves
    /// to go -- every object of the packs taken away and every loose one
    /// that no new pack holds -- written first into a cruft pack of its
    /// own in `dir`, named `<prefix>-<name>.pack`, as git's `--expire-to=<dir>/<prefix>`.
    expire_to: ?struct { dir: Io.Dir, prefix: []const u8 = "pack" } = null,
    /// `--max-cruft-size`: the largest cruft pack written; `null` takes
    /// `max_pack_bytes`.
    max_cruft_bytes: ?u64 = null,
    /// `--combine-cruft-below-size`: without an expiration, only the cruft
    /// packs smaller than this are written again; the others stay. 0 writes
    /// every one again.
    combine_cruft_below: u64 = 0,
    /// `--max-pack-size`; `null` takes `pack.packSizeLimit`. Less than a
    /// megabyte is a megabyte, as git raises it.
    max_pack_bytes: ?u64 = null,
    /// `-l`: what an alternate's packs hold is not packed here.
    local: bool = false,
    /// `--keep-pack`: packs, by file name (`pack-<name>.pack`), left as
    /// they are, as a `.keep` leaves one.
    keep_packs: []const []const u8 = &.{},
    /// `--pack-kept-objects`; `null` takes `repack.packKeptObjects`, else
    /// whether bitmaps are written.
    pack_kept_objects: ?bool = null,
    /// `-b`; `null` takes `repack.writeBitmaps` or `pack.writeBitmaps`,
    /// else writes them for `-a` in a bare repository when it can.
    write_bitmaps: ?bool = null,
    /// `--geometric=<factor>`, with `.loose`: in place of the reachable
    /// objects, the packs, smallest first, that break a progression in
    /// which each pack holds at least `factor` times the objects of all
    /// before it, rolled up with the loose objects into one pack (and the
    /// promisor packs so into one of their own). 0 is none, as git's.
    geometric: u32 = 0,
    /// `-m`, `--write-midx`: a multi-pack index over the packs that stay,
    /// which carries the bitmap `write_bitmaps` asks for in place of a
    /// pack's.
    write_midx: bool = false,
    /// `-i`, `--delta-islands`; `null` takes `repack.useDeltaIslands`: no
    /// object of the new pack a delta of one in fewer of the islands
    /// `pack.island` describes (`maintenance/islands.zig`).
    delta_islands: ?bool = null,
    /// `--filter=<spec>`, as `wire.filter_spec.toWalk` gives it: what the
    /// filter leaves out of the reachable objects' pack, and of what the
    /// packs taken away held, goes into a pack of its own
    /// (`write_filtered_pack`); the objects the index names stay.
    filter: object_walk.Filter = .none,
    /// `--filter-to`: that pack in `dir`, named `<prefix>-<name>.pack`, in
    /// place of beside the others.
    filter_to: ?struct { dir: Io.Dir, prefix: []const u8 = "pack" } = null,
    /// `--drop-filtered`, git 2.56's, with `-a` or `-A` and a `blob_limit`
    /// `filter`: the promisor blobs that filter leaves out
    /// (`dropCandidates`, refused as it refuses) are dropped where they
    /// would be packed apart, and the packs they were in go (`delete` is
    /// implied), for the promisor remote to send again. What the filter
    /// leaves out that is no promisor object is still packed apart, where
    /// git 2.56's loses it. Not with `filter_to` or `write_bitmaps`;
    /// bitmaps the configuration asks for are not written.
    drop_filtered: bool = false,
    /// `-n` is `false`; `null` takes `repack.updateServerInfo`, true.
    update_server_info: ?bool = null,
    /// How each pack is built. `repack.cruftWindow`, `cruftDepth` and
    /// `cruftThreads` change it for a cruft pack.
    /// `null` takes the repository's settings, `Odb.packOptions`.
    pack: ?odb_mod.PackOptions = null,
    /// What runs `gc.recentObjectsHook`, for a cruft expiration and
    /// `--unpack-unreachable`.
    programs: ?program.Programs = null,
};

/// What a repack did.
pub const Report = struct {
    /// New packs of reachable objects, a promisor pack's included.
    packs_written: u32 = 0,
    cruft_written: u32 = 0,
    /// Packs of what `filter` left out.
    filtered_written: u32 = 0,
    /// Cruft packs `expire_to` wrote.
    expired_written: u32 = 0,
    /// Packs taken away.
    packs_removed: u32 = 0,
    /// Unreachable objects written loose, for `-A`.
    loosened: u32 = 0,
    /// Loose objects a pack holds, taken away by `prune-packed`.
    loose_removed: u32 = 0,
    /// Promisor blobs `drop_filtered` dropped.
    dropped: u32 = 0,
    /// Commits taken out of `.git/shallow` that are gone.
    shallow_removed: u32 = 0,
    /// The multi-pack index written, by its checksum.
    midx: ?Oid = null,
};

/// Failures of `repack`.
pub const Error = reach.Error || ops.BitmapError || ops.MidxError || islands_mod.Error || Repository.WriteShallowError || server_info.Error || error{
    /// `-d` in a repository with `extensions.preciousObjects`: git refuses.
    PreciousObjects,
    /// Two of `-A` (or `--unpack-unreachable`), `-k` and `--cruft`, or
    /// `--geometric` with `-a`, `-A` or `--cruft`: git refuses them
    /// together.
    IncompatibleOptions,
    /// Bitmaps asked for without `-a`: git's "Incremental repacks are
    /// incompatible with bitmap indexes".
    IncrementalBitmaps,
    /// `--drop-filtered` without a filter, or with one other than
    /// `blob:limit=<n>`: "--drop-filtered requires --filter", "only
    /// supports --filter=blob:limit=<n> for now".
    DropNeedsBlobLimit,
    /// `--drop-filtered` without `-a` or `-A`, or with `--filter-to` or
    /// `-b`: git refuses them.
    DropIncompatible,
    /// `--drop-filtered` with no promisor remote to fetch what it drops
    /// again: "--drop-filtered requires a promisor remote".
    NoPromisorRemote,
    /// `--drop-filtered` in a worktree a merge, rebase, `am`, cherry-pick,
    /// revert or bisect is in the middle of (`commit.in_progress`).
    OperationInProgress,
    /// `--drop-filtered` would drop a blob the index names: "cannot drop
    /// '<path>' (<oid>): it is referenced by the current index".
    DroppedBlobInIndex,
};

/// git 2.56's `enumerate_promisor_blobs` and the checks `--drop-filtered`
/// makes first: the blobs of the promisor packs of at least `filter`'s
/// `blob_limit` bytes, sorted, which `--drop-filtered --dry-run` lists.
/// Refused without a promisor remote, and in a worktree that is in the
/// middle of an operation or whose index names one of them; a bare
/// repository has neither. The result is the caller's.
pub fn dropCandidates(gpa: Allocator, io: Io, repo: *Repository, filter: object_walk.Filter) Self.Error![]Oid {
    const limit = switch (filter) {
        .blob_limit => |n| n.raw(),
        else => return error.DropNeedsBlobLimit,
    };
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    if ((try promisors.remotes(arena_instance.allocator(), repo.configuration())).len == 0) return error.NoPromisorRemote;
    if (!repo.isBare() and !in_progress.read(io, repo).none()) return error.OperationInProgress;
    const db = repo.objectDatabase();
    var found: Oid.Set = .empty;
    defer found.deinit(gpa);
    const listed = try db.listPacks(gpa, io, .all);
    defer gpa.free(listed);
    for (listed) |listing| {
        if (!listing.promisor) continue;
        const p = db.packNamed(listing.name) orelse continue;
        for (0..p.index.count) |i| {
            const oid = p.index.nameAt(@intCast(i));
            if (found.contains(oid)) continue;
            const header = db.readHeader(io, oid) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => |e| return e,
            };
            if (header.type == .blob and header.size >= limit) try found.put(gpa, oid, {});
        }
    }
    if (!repo.isBare() and found.count() != 0) {
        var index = try repo.openIndex(io);
        defer index.deinit();
        for (index.entries.items) |entry| if (found.contains(entry.oid)) return error.DroppedBlobInIndex;
    }
    const out = try gpa.alloc(Oid, found.count());
    var it = found.keyIterator();
    var at: usize = 0;
    while (it.next()) |oid| : (at += 1) out[at] = oid.*;
    std.mem.sort(Oid, out, {}, oidBefore);
    return out;
}

/// The local packs as `existing_packs_collect` sorts them.
const Existing = struct {
    kept: std.ArrayList([]const u8) = .empty,
    cruft: std.ArrayList([]const u8) = .empty,
    non_kept: std.ArrayList([]const u8) = .empty,
    promisor: std.ArrayList([]const u8) = .empty,
    /// Each pack's time and size, by base name.
    times: std.StringHashMapUnmanaged(i64) = .empty,
    sizes: std.StringHashMapUnmanaged(u64) = .empty,
};

/// git's `repack`, as `options` asks.
pub fn repack(gpa: Allocator, io: Io, repo: *Repository, asked: Options) Self.Error!Report {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const config = repo.configuration();
    const db = repo.objectDatabase();

    var options = asked;
    var mode = options.mode;
    const loosen = mode == .all_loosen or options.unpack_unreachable != null;
    if (@as(u2, @intFromBool(loosen)) + @intFromBool(options.keep_unreachable) + @intFromBool(mode == .cruft) > 1) return error.IncompatibleOptions;
    if (loosen and mode != .loose) mode = .all_loosen;
    if (options.geometric != 0 and mode != .loose) return error.IncompatibleOptions;
    // `--drop-filtered`: refused as git refuses it, before any pack is
    // written, and `-d` with it.
    var drop: Oid.Set = .empty;
    defer drop.deinit(gpa);
    if (options.drop_filtered) {
        if (options.filter_to != null) return error.DropIncompatible;
        if (options.filter == .none) return error.DropNeedsBlobLimit;
        if (mode != .all and mode != .all_loosen) return error.DropIncompatible;
        if (options.filter != .blob_limit) return error.DropNeedsBlobLimit;
        if (options.write_bitmaps == true) return error.DropIncompatible;
        const candidates = try dropCandidates(gpa, io, repo, options.filter);
        defer gpa.free(candidates);
        for (candidates) |oid| try drop.put(gpa, oid, {});
        options.delete = true;
        options.write_bitmaps = false;
    }
    if (options.delete and try config.getBool("extensions.preciousobjects", false)) return error.PreciousObjects;

    var bitmaps: ?bool = options.write_bitmaps orelse try lastBool(config, &.{ "repack.writebitmaps", "pack.writebitmaps" });
    if (bitmaps == null and !options.write_midx and !(mode != .loose and repo.isBare())) bitmaps = false;
    if (bitmaps == true and mode == .loose and !options.write_midx) return error.IncrementalBitmaps;
    if (bitmaps != false and options.local and db.hasAlternates()) bitmaps = false;
    var pack_options = options.pack orelse db.packOptions();
    // `pack.writeReverseIndex`, as pack-objects reads it.
    pack_options.reverse_index = pack_options.reverse_index or rev_index.wanted(config);

    var islands: ?islands_odb.Islands = if (options.delta_islands orelse try config.getBool("repack.usedeltaislands", false)) try islands_mod.load(gpa, io, repo) else null;
    defer if (islands) |*i| i.deinit();
    try db.refresh(io);
    const pack_dir = try db.openPackDirectory(io);
    defer pack_dir.close(io);
    var run: Run = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .repo = repo,
        .db = db,
        .options = options,
        .mode = mode,
        .pack_options = pack_options,
        .main_options = pack_options,
        .pack_kept = options.pack_kept_objects orelse try lastBool(config, &.{"repack.packkeptobjects"}) orelse (bitmaps == true and !options.write_midx),
        .max_pack = if (options.max_pack_bytes orelse try sizeSetting(config, "pack.packsizelimit")) |limit| @max(limit, 1 << 20) else null,
        .pack_dir = pack_dir,
        .existing = try collectExisting(gpa, arena, io, db, options.keep_packs),
        .drop = &drop,
    };
    defer run.deinit();
    run.report.dropped = drop.count();
    // `--delta-islands` goes to the pack of what is reachable alone.
    if (islands) |*i| run.main_options.islands = i;
    for (run.existing.promisor.items) |name| try addPackObjects(gpa, db, name, &run.promised);
    for (run.existing.kept.items) |name| try addPackObjects(gpa, db, name, &run.kept_objects);

    if (mode != .loose) try run.writePromisorPack();
    var geometry: ?Geometry = if (options.geometric != 0) try run.geometry() else null;
    const main_written = if (geometry) |*g| try run.writeGeometric(g) else try run.writeReachable();
    try db.refresh(io);

    var main_objects: Oid.Set = .empty;
    defer main_objects.deinit(gpa);
    for (run.fresh.items) |name| try addPackObjects(gpa, db, name, &main_objects);
    const has_old = run.existing.non_kept.items.len + run.existing.cruft.items.len != 0;
    // `-A`: `loosen_unused_packed_objects`.
    if (mode == .all_loosen and options.delete and has_old) {
        run.report.loosened = try loosenUnreachable(gpa, arena, io, repo, &run.existing, &main_objects, &run.kept_objects, options);
    }
    // `--cruft`: `write_cruft_pack`.
    if (mode == .cruft) {
        var cruft_options = pack_options;
        if (config.has("repack.cruftwindow")) cruft_options.window = std.math.cast(u32, @max(try config.getInt("repack.cruftwindow", 0), 0)) orelse std.math.maxInt(u32);
        if (config.has("repack.cruftdepth")) cruft_options.depth = std.math.cast(u32, @max(try config.getInt("repack.cruftdepth", 0), 0)) orelse std.math.maxInt(u32);
        if (config.has("repack.cruftthreads")) cruft_options.threads = std.math.cast(u16, @max(try config.getInt("repack.cruftthreads", 0), 0)) orelse std.math.maxInt(u16);
        const limit: ?u64 = if (options.max_cruft_bytes) |l| @max(l, 1 << 20) else run.max_pack;
        run.report.cruft_written = try writeCruft(gpa, arena, io, repo, &run.existing, run.fresh.items, &run.retained, options, cruft_options, limit, pack_dir);
        try db.refresh(io);
        // `--expire-to`: the same cruft pack again, the one just written
        // among the packs it leaves out, with no expiration and nothing
        // combined, so it holds what is about to go.
        if (options.delete) if (options.expire_to) |to| {
            var fresh: std.ArrayList([]const u8) = .empty;
            try fresh.appendSlice(arena, run.fresh.items);
            try fresh.appendSlice(arena, run.retained.items);
            var expired_options = options;
            expired_options.cruft_expiration = null;
            expired_options.combine_cruft_below = 0;
            var to_options = cruft_options;
            to_options.prefix = to.prefix;
            var elsewhere: std.ArrayList([]const u8) = .empty;
            run.report.expired_written = try writeCruft(gpa, arena, io, repo, &run.existing, fresh.items, &elsewhere, expired_options, to_options, limit, to.dir);
        };
    }
    if (options.filter != .none) try run.writeFiltered();
    if (main_written) |written| if (bitmaps != false and !run.kept_skipped and !options.write_midx) try run.writeBitmap(written);
    if (options.write_midx) run.report.midx = try run.writeMidx(if (geometry) |*g| g else null, bitmaps == true);
    if (options.delete) try run.removeRedundant(if (geometry) |*g| g else null);
    if (options.update_server_info orelse try config.getBool("repack.updateserverinfo", true)) try server_info.updateServerInfo(gpa, io, repo);
    return run.report;
}

/// One repack's state as it goes.
const Run = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    repo: *Repository,
    db: *Odb,
    options: Options,
    mode: Mode,
    pack_options: odb_mod.PackOptions,
    /// The reachable objects' pack's: `pack_options` with the islands.
    main_options: odb_mod.PackOptions,
    pack_kept: bool,
    max_pack: ?u64,
    pack_dir: Io.Dir,
    existing: Existing,
    report: Report = .{},
    /// The packs written of what is not cruft, by base name.
    fresh: std.ArrayList([]const u8) = .empty,
    /// The cruft packs that stay: those written, and those too large to
    /// combine.
    retained: std.ArrayList([]const u8) = .empty,
    /// What a promisor pack holds, and what a kept pack holds.
    promised: Oid.Set = .empty,
    kept_objects: Oid.Set = .empty,
    /// What `drop_filtered` drops: in no pack this writes.
    drop: *const Oid.Set,
    /// Whether a reachable object was left to a kept pack, so the new pack
    /// cannot carry a bitmap.
    kept_skipped: bool = false,

    fn deinit(run: *Run) void {
        run.promised.deinit(run.gpa);
        run.kept_objects.deinit(run.gpa);
    }

    /// git's `repack_promisor_objects`: what the promisor packs hold, but
    /// for a kept pack's, into one promisor pack of its own, so a partial
    /// clone still knows what its promisor remote can send again.
    fn writePromisorPack(run: *Run) Self.Error!void {
        var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
        for (run.existing.promisor.items) |name| {
            if (isListed(run.existing.kept.items, name)) continue;
            const p = run.db.packNamed(name) orelse continue;
            for (0..p.index.count) |i| {
                const oid = p.index.nameAt(@intCast(i));
                if (run.kept_objects.contains(oid) or run.drop.contains(oid)) continue;
                try entries.append(run.arena, .{ .oid = oid, .in_pack = true });
            }
        }
        if (entries.items.len == 0) return;
        const written = try run.db.writePack(run.io, run.pack_dir, entries.items, run.pack_options);
        try run.db.writePromisor(run.io, written.name, "", .replace);
        try run.fresh.append(run.arena, try baseName(run.arena, written.name));
        run.report.packs_written += 1;
    }

    /// `pack-objects --all --reflog --indexed-objects` and what `mode` adds
    /// to it, into new packs, none of them larger than `max_pack`; the one
    /// written, when it is one.
    fn writeReachable(run: *Run) Self.Error!?pack_mod.WriteReport {
        const gpa = run.gpa;
        const db = run.db;
        var collected = try reach.reachableToPack(gpa, run.io, run.repo, run.options.filter);
        defer collected.deinit();
        var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
        var taken: Oid.Set = .empty;
        defer taken.deinit(gpa);
        // `--keep-pack`'s packs, which `--pack-kept-objects` does not reach.
        var keep_pack_objects: Oid.Set = .empty;
        defer keep_pack_objects.deinit(gpa);
        for (run.existing.kept.items) |name| if (!(try hasKeepFile(run.io, run.pack_dir, name))) try addPackObjects(gpa, db, name, &keep_pack_objects);
        for (collected.entries) |entry| {
            if (run.promised.contains(entry.oid)) continue;
            if (keep_pack_objects.contains(entry.oid) or (!run.pack_kept and run.kept_objects.contains(entry.oid))) {
                run.kept_skipped = true;
                continue;
            }
            if (run.mode == .loose and try db.isPacked(entry.oid)) continue;
            if (run.options.local and !try db.existsOwn(run.io, entry.oid)) continue;
            try taken.put(gpa, entry.oid, {});
            try entries.append(run.arena, entry);
        }
        // `--keep-unreachable` with `--pack-loose-unreachable`.
        if (run.mode == .all and run.options.keep_unreachable and run.options.delete and run.existing.non_kept.items.len + run.existing.cruft.items.len != 0) {
            const timed = try db.timedObjects(gpa, run.io, .{ .exclude_packs = run.existing.kept.items });
            defer gpa.free(timed);
            for (timed) |object| {
                if (run.promised.contains(object.oid)) continue;
                if ((try taken.fetchPut(gpa, object.oid, {})) != null) continue;
                try entries.append(run.arena, .{ .oid = object.oid, .in_pack = object.pack != null });
            }
        }
        if (entries.items.len == 0) return null;
        const reports = try writeLimited(db, run.io, run.pack_dir, entries.items, run.main_options, run.max_pack);
        defer db.allocator().free(reports);
        for (reports) |written| try run.fresh.append(run.arena, try baseName(run.arena, written.name));
        run.report.packs_written += @intCast(reports.len);
        return if (reports.len == 1) reports[0] else null;
    }

    /// `write_filtered_pack`: `pack-objects --stdin-packs` over the packs
    /// not kept and the cruft ones (and the kept ones with kept objects
    /// packed), the new packs `^`-marked, into `filter_to` or beside them.
    fn writeFiltered(run: *Run) Self.Error!void {
        const gpa = run.gpa;
        const db = run.db;
        var skip: Oid.Set = .empty;
        defer skip.deinit(gpa);
        for (run.fresh.items) |name| try addPackObjects(gpa, db, name, &skip);
        for (run.retained.items) |name| try addPackObjects(gpa, db, name, &skip);
        if (!run.pack_kept) for (run.existing.kept.items) |name| try addPackObjects(gpa, db, name, &skip);
        var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
        var sources: std.ArrayList([]const u8) = .empty;
        try sources.appendSlice(run.arena, run.existing.non_kept.items);
        try sources.appendSlice(run.arena, run.existing.cruft.items);
        if (run.pack_kept) try sources.appendSlice(run.arena, run.existing.kept.items);
        for (sources.items) |name| {
            const p = db.packNamed(name) orelse continue;
            for (0..p.index.count) |i| {
                const oid = p.index.nameAt(@intCast(i));
                if (run.drop.contains(oid)) continue;
                if ((try skip.fetchPut(gpa, oid, {})) != null) continue;
                try entries.append(run.arena, .{ .oid = oid, .in_pack = true });
            }
        }
        if (entries.items.len == 0) return;
        var options = run.pack_options;
        const dir = if (run.options.filter_to) |to| blk: {
            options.prefix = to.prefix;
            break :blk to.dir;
        } else run.pack_dir;
        const reports = try writeLimited(db, run.io, dir, entries.items, options, run.max_pack);
        defer db.allocator().free(reports);
        // Beside the others, they are packs this repack keeps.
        if (run.options.filter_to == null) for (reports) |written| try run.fresh.append(run.arena, try baseName(run.arena, written.name));
        run.report.filtered_written = @intCast(reports.len);
        try db.refresh(run.io);
    }

    /// The new pack's reachability bitmap, as `--write-bitmap-index`.
    fn writeBitmap(run: *Run, written: pack_mod.WriteReport) Self.Error!void {
        const config = run.repo.configuration();
        const tips = try ops.repositoryTips(run.gpa, run.io, run.repo);
        defer run.gpa.free(tips);
        const name = try baseName(run.arena, written.name);
        ops.writePackBitmap(run.gpa, run.io, run.db, .{ .pack_name = name, .tips = tips }, .{
            .hash_cache = try config.getBool("pack.writebitmaphashcache", true),
            .lookup_table = try config.getBool("pack.writebitmaplookuptable", false),
        }) catch |err| switch (err) {
            // git's `--write-bitmap-index-quiet`, and the warning of the
            // asked-for one: the pack does not hold every object its
            // commits reach, and no bitmap is written.
            error.BitmapNotClosed => {},
            else => |e| return e,
        };
    }

    fn geometry(run: *Run) Self.Error!Geometry {
        return planGeometry(run.arena, run.io, run.db, .{ .factor = run.options.geometric, .local = run.options.local, .pack_kept_objects = run.pack_kept, .keep_packs = run.options.keep_packs });
    }

    /// `pack-objects --stdin-packs --unpacked`, the packs before the split
    /// given and those after it `^`-marked, the promisor packs that roll up
    /// written first into a promisor pack of their own
    /// (`pack_geometry_repack_promisors`); the one written, when it is one.
    fn writeGeometric(run: *Run, g: *const Geometry) Self.Error!?pack_mod.WriteReport {
        if (g.promisor_split != 0) {
            const entries = try run.rollUp(g.promisor, g.promisor_split, false);
            if (entries.len != 0) {
                const reports = try writeLimited(run.db, run.io, run.pack_dir, entries, run.pack_options, run.max_pack);
                defer run.db.allocator().free(reports);
                for (reports) |written| {
                    try run.db.writePromisor(run.io, written.name, "", .replace);
                    try run.fresh.append(run.arena, try baseName(run.arena, written.name));
                }
                run.report.packs_written += @intCast(reports.len);
            }
        }
        const entries = try run.rollUp(g.packs, g.split, true);
        if (entries.len == 0) return null;
        const reports = try writeLimited(run.db, run.io, run.pack_dir, entries, run.main_options, run.max_pack);
        defer run.db.allocator().free(reports);
        for (reports) |written| try run.fresh.append(run.arena, try baseName(run.arena, written.name));
        run.report.packs_written += @intCast(reports.len);
        return if (reports.len == 1) reports[0] else null;
    }

    /// `--stdin-packs`: each object of `packs` before `split`, and with
    /// `main` each loose one, that no pack after the split holds, nor a
    /// kept pack (`--honor-pack-keep`, and for `main` `--keep-pack`) or,
    /// for `main`, a promisor pack.
    fn rollUp(run: *Run, packs: []const Odb.PackListing, split: usize, main: bool) Self.Error![]odb_mod.PackEntry {
        const gpa = run.gpa;
        const db = run.db;
        var skip: Oid.Set = .empty;
        defer skip.deinit(gpa);
        for (packs[split..]) |p| try addPackObjects(gpa, db, p.name, &skip);
        for (run.existing.kept.items) |name| {
            const keep_file = try hasKeepFile(run.io, run.pack_dir, name);
            if ((keep_file and !run.pack_kept) or (!keep_file and main)) try addPackObjects(gpa, db, name, &skip);
        }
        var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
        for (packs[0..split]) |p| {
            const found = db.packNamed(p.name) orelse continue;
            for (0..found.index.count) |i| {
                const oid = found.index.nameAt(@intCast(i));
                if (main and run.promised.contains(oid)) continue;
                if ((try skip.fetchPut(gpa, oid, {})) != null) continue;
                try entries.append(run.arena, .{ .oid = oid, .in_pack = true });
            }
        }
        if (main) {
            var loose = try db.collectLoose(run.io, .{});
            defer loose.deinit();
            for (loose.entries) |entry| {
                if (run.promised.contains(entry.oid)) continue;
                if ((try skip.fetchPut(gpa, entry.oid, {})) != null) continue;
                // The listing's paths go with it: the entry keeps a copy.
                var kept = entry;
                kept.hint = try run.arena.dupe(u8, entry.hint);
                try entries.append(run.arena, kept);
            }
        }
        return entries.items;
    }

    /// Whether `-d` takes the pack `name` away: with `-a`, `-A` or
    /// `--cruft` each pack that is not kept and that no new pack and no
    /// retained cruft pack is.
    fn doomed(run: *const Run, name: []const u8) bool {
        if (run.mode == .loose or !run.options.delete) return false;
        return !isListed(run.fresh.items, name) and !isListed(run.retained.items, name);
    }

    /// `repack_write_midx`'s `write_midx_included_packs`: a multi-pack
    /// index over the kept packs, the new ones, those that stay (with
    /// `--geometric` the local ones after the split) and the cruft packs;
    /// the largest that stays preferred, else the first new one that is
    /// not cruft. With `bitmap` it carries one, and the packs it covers
    /// lose theirs.
    fn writeMidx(run: *Run, g: ?*const Geometry, bitmap: bool) Self.Error!?Oid {
        const arena = run.arena;
        var include: std.ArrayList([]const u8) = .empty;
        var stays: std.ArrayList([]const u8) = .empty;
        if (g) |geo| {
            for (geo.packs[geo.split..]) |p| if (p.local) try stays.append(arena, p.name);
        } else for (run.existing.non_kept.items) |name| {
            if (!run.doomed(name)) try stays.append(arena, name);
        }
        for (run.existing.cruft.items) |name| if (!run.doomed(name)) try stays.append(arena, name);
        for ([_][]const []const u8{ run.existing.kept.items, run.fresh.items, run.retained.items, stays.items }) |names| for (names) |name| {
            if (!isListed(include.items, name)) try include.append(arena, name);
        };
        if (include.items.len == 0) return null;

        var preferred: ?[]const u8 = null;
        if (g) |geo| {
            var i = geo.packs.len;
            while (i > geo.split) : (i -= 1) if (geo.packs[i - 1].local) {
                preferred = geo.packs[i - 1].name;
                break;
            };
        }
        if (preferred == null) for (run.fresh.items) |name| {
            if (preferred == null or std.mem.order(u8, name, preferred.?) == .lt) preferred = name;
        };

        const options: ops.MidxOptions = .{ .packs = include.items, .preferred_pack = preferred };
        if (!bitmap) return ops.writeMidx(run.gpa, run.io, run.db, options);
        const config = run.repo.configuration();
        const tips = try ops.repositoryTips(run.gpa, run.io, run.repo);
        defer run.gpa.free(tips);
        const written = try ops.writeMidxBitmap(run.gpa, run.io, run.db, .{ .tips = tips, .midx_options = options }, .{
            .hash_cache = try config.getBool("pack.writebitmaphashcache", true),
            .lookup_table = try config.getBool("pack.writebitmaplookuptable", false),
        });
        // `remove_redundant_bitmaps`.
        for (include.items) |name| {
            var name_buf: [Io.Dir.max_name_bytes]u8 = undefined;
            const file = std.mem.print(&name_buf, "{s}.bitmap", .{name}) catch continue;
            run.pack_dir.deleteFile(run.io, file) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }
        try run.db.refresh(run.io);
        return written;
    }

    /// `-d`: with `-a`, `-A` or `--cruft` the old packs the new ones
    /// replace go, with `--geometric` the local ones that rolled up; then
    /// `prune-packed`, and `prune_shallow(PRUNE_QUICK)`, the boundary
    /// commits that are gone.
    fn removeRedundant(run: *Run, g: ?*const Geometry) Self.Error!void {
        const db = run.db;
        var doomed_packs: std.ArrayList([]const u8) = .empty;
        for ([_][]const []const u8{ run.existing.non_kept.items, run.existing.cruft.items }) |names| for (names) |name| {
            if (run.doomed(name)) try doomed_packs.append(run.arena, name);
        };
        // `pack_geometry_remove_redundant`.
        if (g) |geo| for ([_][]const Odb.PackListing{ geo.packs[0..geo.split], geo.promisor[0..geo.promisor_split] }) |packs| for (packs) |p| {
            if (!p.local or p.kept or isListed(run.existing.kept.items, p.name) or isListed(run.fresh.items, p.name)) continue;
            try doomed_packs.append(run.arena, p.name);
        };
        if (doomed_packs.items.len != 0) run.report.packs_removed = try db.removePacks(run.io, doomed_packs.items);
        run.report.loose_removed = try db.prunePacked(run.io, false);
        if (run.options.keep_unreachable or (run.mode == .all_loosen and run.options.unpack_unreachable == null) or db.shallow.count() == 0) return;
        var gone: std.ArrayList(Oid) = .empty;
        var it = db.shallow.keyIterator();
        while (it.next()) |oid| if (!try db.exists(run.io, oid.*)) try gone.append(run.arena, oid.*);
        if (gone.items.len == 0) return;
        for (gone.items) |oid| _ = db.shallow.remove(oid);
        try run.repo.writeShallow(run.io);
        run.report.shallow_removed = @intCast(gone.items.len);
    }
};

/// git's `pack_geometry`: the packs a geometric repack weighs, each list
/// by its objects, fewest first; those before its split roll up.
pub const Geometry = struct {
    packs: []const Odb.PackListing,
    split: usize,
    promisor: []const Odb.PackListing,
    promisor_split: usize,
};

/// What `planGeometry` weighs.
pub const GeometryOptions = struct {
    factor: u32,
    /// `-l`: an alternate's packs are not weighed.
    local: bool = false,
    /// A kept pack is weighed too.
    pack_kept_objects: bool = false,
    /// `--keep-pack`'s packs, by file name.
    keep_packs: []const []const u8 = &.{},
};

/// `pack_geometry_init` and `pack_geometry_split`: the packs a geometric
/// repack by `options.factor` weighs, an alternate's but for `-l`, and
/// where each list splits; the names in `arena`.
pub fn planGeometry(arena: Allocator, io: Io, db: *Odb, options: GeometryOptions) Self.Error!Geometry {
    const listed = try db.listPacks(arena, io, .all);
    var packs: std.ArrayList(Odb.PackListing) = .empty;
    var promisor: std.ArrayList(Odb.PackListing) = .empty;
    for (listed) |p| {
        if (options.local and !p.local) continue;
        const keep_pack = p.local and for (options.keep_packs) |k| {
            if (std.mem.endsWith(u8, k, ".pack") and std.mem.eql(u8, k[0 .. k.len - 5], p.name)) break true;
        } else false;
        if (!options.pack_kept_objects and (p.kept or keep_pack)) continue;
        if (p.cruft) continue;
        var copy = p;
        copy.name = try arena.dupe(u8, p.name);
        try (if (p.promisor) &promisor else &packs).append(arena, copy);
    }
    const by_objects = struct {
        fn less(_: void, a: Odb.PackListing, b: Odb.PackListing) bool {
            return a.objects < b.objects;
        }
    }.less;
    std.mem.sort(Odb.PackListing, packs.items, {}, by_objects);
    std.mem.sort(Odb.PackListing, promisor.items, {}, by_objects);
    return .{
        .packs = packs.items,
        .split = geometrySplit(packs.items, options.factor),
        .promisor = promisor.items,
        .promisor_split = geometrySplit(promisor.items, options.factor),
    };
}

/// `compute_pack_geometry_split`: how many of `packs`, fewest objects
/// first, roll up so that each pack left holds at least `factor` times the
/// objects of all before it, the new pack among them.
fn geometrySplit(packs: []const Odb.PackListing, factor: u32) usize {
    if (packs.len == 0) return 0;
    // The packs from the heaviest down that already make a progression.
    var i = packs.len - 1;
    while (i > 0) : (i -= 1) {
        if (@as(u64, packs[i].objects) < @as(u64, factor) * packs[i - 1].objects) break;
    }
    var split = if (i == 0) 0 else i + 1;
    // The new pack may be heavy enough to break it again above the split.
    var total: u64 = 0;
    for (packs[0..split]) |p| total += p.objects;
    while (split < packs.len and packs[split].objects < @as(u64, factor) * total) : (split += 1) total += packs[split].objects;
    return split;
}

/// The last of `names` set, as a boolean, or `null`: git's config
/// callback, which reads each and keeps the last.
fn lastBool(config: *const config_mod.Config, names: []const []const u8) config_mod.ValueError!?bool {
    var found: ?bool = null;
    var it = config.iterate(names);
    while (it.next()) |entry| found = if (entry.value) |v| try config_mod.parseBool(v) else true;
    return found;
}

/// A size setting with git's `k`, `m` and `g`, or `null` when unset or 0.
fn sizeSetting(config: *const config_mod.Config, name: []const u8) config_mod.ValueError!?u64 {
    const value = try config.getInt(name, 0);
    return if (value <= 0) null else @intCast(value);
}

fn baseName(arena: Allocator, name: Oid) Allocator.Error![]const u8 {
    var hex: [hash.max_hex_len]u8 = undefined;
    return arena.print("pack-{s}", .{name.hex(&hex)});
}

fn isListed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn hasKeepFile(io: Io, pack_dir: Io.Dir, base: []const u8) Io.Dir.AccessError!bool {
    var name_buf: [Io.Dir.max_name_bytes]u8 = undefined;
    const name = std.mem.print(&name_buf, "{s}.keep", .{base}) catch return false;
    pack_dir.access(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

/// Every object of the pack `name` into `set`.
fn addPackObjects(gpa: Allocator, db: *Odb, name: []const u8, set: *Oid.Set) Allocator.Error!void {
    const p = db.packNamed(name) orelse return;
    try set.ensureUnusedCapacity(gpa, p.index.count);
    for (0..p.index.count) |i| set.putAssumeCapacity(p.index.nameAt(@intCast(i)), {});
}

/// `existing_packs_collect`: the local packs by kind, a pack `keep_packs`
/// names or with a `.keep` kept, the names copied into `arena`.
fn collectExisting(gpa: Allocator, arena: Allocator, io: Io, db: *Odb, keep_packs: []const []const u8) Self.Error!Existing {
    const listed = try db.listPacks(gpa, io, .own);
    defer gpa.free(listed);
    var existing: Existing = .{};
    for (listed) |p| {
        const name = try arena.dupe(u8, p.name);
        const kept = p.kept or for (keep_packs) |k| {
            if (std.mem.endsWith(u8, k, ".pack") and std.mem.eql(u8, k[0 .. k.len - 5], name)) break true;
        } else false;
        if (kept) {
            try existing.kept.append(arena, name);
        } else if (p.cruft) {
            try existing.cruft.append(arena, name);
        } else {
            try existing.non_kept.append(arena, name);
        }
        if (p.promisor) try existing.promisor.append(arena, name);
        try existing.times.put(arena, name, p.time);
        try existing.sizes.put(arena, name, p.size);
    }
    return existing;
}

/// The objects that are recent as git's `add_unseen_recent_objects_to_traversal`
/// finds them, of `timed`: each newer than `after` or named by a
/// `gc.recentObjectsHook` command (run once, at the first that is not
/// newer), into `out` with its time, the newest of its copies.
fn recentOf(gpa: Allocator, io: Io, repo: *Repository, timed: []const Odb.Timed, after: date.Expiry, programs: ?program.Programs, out: *Oid.Map(i64)) Self.Error!void {
    var hooked: ?Oid.Set = null;
    defer if (hooked) |*set| set.deinit(gpa);
    for (timed) |object| {
        if (date.Expiry.fromRaw(object.time).compare(after) != .gt) {
            if (hooked == null) hooked = try reach.hookedObjects(gpa, io, repo, programs);
            if (!hooked.?.contains(object.oid)) continue;
        }
        const slot = try out.getOrPut(gpa, object.oid);
        if (!slot.found_existing or slot.value_ptr.* < object.time) slot.value_ptr.* = object.time;
    }
}

/// What the recent objects in `recent` reach, as far as it is there and
/// short of what the repository reaches: `traverse_commit_list` from them
/// with `ignore_missing_links`, the commits the refs name excluded.
fn walkRecent(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, recent: *const Oid.Map(i64)) Self.Error!odb_mod.Odb.Collected {
    const starts = try reach.collectStarts(gpa, arena, io, repo, .{ .rebase_state = false });
    var tips: std.ArrayList(Oid) = .empty;
    var it = recent.keyIterator();
    while (it.next()) |oid| try tips.append(arena, oid.*);
    return object_walk.missing(gpa, io, repo.objectDatabase(), tips.items, .{ .exclude = starts.roots, .ignore_missing_links = true });
}

/// `loosen_unused_packed_objects`: each object of a pack about to go that
/// the new packs, a kept pack and an alternate do not hold, written loose
/// with its pack's time, unless `--unpack-unreachable` drops it: its pack
/// no newer than the date and no recent object reaching it.
fn loosenUnreachable(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, existing: *const Existing, fresh: *const Oid.Set, kept: *const Oid.Set, options: Options) Self.Error!u32 {
    const db = repo.objectDatabase();
    var recent: Oid.Map(i64) = .empty;
    defer recent.deinit(gpa);
    var recent_reached: Oid.Set = .empty;
    defer recent_reached.deinit(gpa);
    if (options.unpack_unreachable) |after| {
        const timed = try db.timedObjects(gpa, io, .{});
        defer gpa.free(timed);
        try recentOf(gpa, io, repo, timed, after, options.programs, &recent);
        var walked = try walkRecent(gpa, arena, io, repo, &recent);
        defer walked.deinit();
        for (walked.entries) |entry| try recent_reached.put(gpa, entry.oid, {});
    }
    var count: u32 = 0;
    for ([_][]const []const u8{ existing.non_kept.items, existing.cruft.items }) |names| for (names) |name| {
        const p = db.packNamed(name) orelse continue;
        const time = existing.times.get(name) orelse 0;
        for (0..p.index.count) |i| {
            const oid = p.index.nameAt(@intCast(i));
            if (fresh.contains(oid) or kept.contains(oid)) continue;
            if (!try db.existsOwn(io, oid)) continue;
            if (options.unpack_unreachable) |after| {
                if (date.Expiry.fromRaw(time).compare(after) != .gt and !recent.contains(oid) and !recent_reached.contains(oid)) continue;
            }
            if (try db.loosen(io, oid, time)) count += 1;
        }
    };
    return count;
}

/// `write_cruft_pack` and `pack-objects --cruft`: the objects of the packs
/// about to go and the loose ones that the fresh packs do not hold, into
/// cruft packs, each with the newest time of its copies; with an
/// expiration only the recent ones and what they reach, the reached ones
/// no older than the expiration. A cruft pack at least
/// `combine_cruft_below` large stays (`retained`), and an object it holds
/// is written again only when newer than its copy there. How many packs
/// were written; their names join the retained ones in `retained`, which
/// no removal takes.
fn writeCruft(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    repo: *Repository,
    existing: *const Existing,
    fresh_names: []const []const u8,
    retained: *std.ArrayList([]const u8),
    options: Options,
    pack_options: odb_mod.PackOptions,
    limit: ?u64,
    pack_dir: Io.Dir,
) Self.Error!u32 {
    const db = repo.objectDatabase();
    // The packs whose objects are not cruft: the new ones and the kept
    // ones, which `null` marks; a retained cruft pack's objects by time.
    var fresh: Oid.Map(?i64) = .empty;
    defer fresh.deinit(gpa);
    var discard: std.ArrayList([]const u8) = .empty;
    for (fresh_names) |name| try addFresh(gpa, db, name, &fresh, null);
    for (existing.kept.items) |name| try addFresh(gpa, db, name, &fresh, null);
    try discard.appendSlice(arena, existing.non_kept.items);
    for (existing.cruft.items) |name| {
        if (options.combine_cruft_below != 0 and options.cruft_expiration == null and (existing.sizes.get(name) orelse 0) >= options.combine_cruft_below) {
            try retained.append(arena, name);
            continue;
        }
        try discard.append(arena, name);
    }
    var retained_times: std.ArrayList(Odb.Timed) = .empty;
    {
        // A retained cruft pack's objects with their own times.
        var skip: std.ArrayList([]const u8) = .empty;
        for (existing.non_kept.items) |n| try skip.append(arena, n);
        for (existing.kept.items) |n| try skip.append(arena, n);
        for (existing.cruft.items) |n| if (!isListed(retained.items, n)) try skip.append(arena, n);
        for (fresh_names) |n| try skip.append(arena, n);
        if (retained.items.len != 0) {
            const timed = try db.timedObjects(gpa, io, .{ .exclude_packs = skip.items });
            defer gpa.free(timed);
            for (timed) |object| if (object.pack != null) try retained_times.append(arena, object);
        }
    }
    for (retained_times.items) |object| {
        const slot = try fresh.getOrPut(gpa, object.oid);
        if (!slot.found_existing) {
            slot.value_ptr.* = object.time;
        } else if (slot.value_ptr.*) |t| slot.value_ptr.* = @max(t, object.time);
    }

    // Every loose object and every object of a discarded pack, with its
    // time: what is enumerated.
    var excluded: std.ArrayList([]const u8) = .empty;
    for (existing.kept.items) |n| try excluded.append(arena, n);
    for (retained.items) |n| try excluded.append(arena, n);
    for (fresh_names) |n| try excluded.append(arena, n);
    const timed = try db.timedObjects(gpa, io, .{ .exclude_packs = excluded.items });
    defer gpa.free(timed);

    var times: Oid.Map(i64) = .empty;
    defer times.deinit(gpa);
    if (options.cruft_expiration) |after| {
        try recentOf(gpa, io, repo, timed, after, options.programs, &times);
        var walked = try walkRecent(gpa, arena, io, repo, &times);
        defer walked.deinit();
        for (walked.entries) |entry| {
            const slot = try times.getOrPut(gpa, entry.oid);
            if (!slot.found_existing) slot.value_ptr.* = after.raw() else slot.value_ptr.* = @max(slot.value_ptr.*, after.raw());
        }
    } else {
        for (timed) |object| {
            const slot = try times.getOrPut(gpa, object.oid);
            if (!slot.found_existing or slot.value_ptr.* < object.time) slot.value_ptr.* = object.time;
        }
    }

    var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
    var mtimes: Oid.Map(u32) = .empty;
    defer mtimes.deinit(gpa);
    var it = times.iterator();
    while (it.next()) |kv| {
        const oid = kv.key_ptr.*;
        const time = kv.value_ptr.*;
        // `want_object_in_pack_mtime`: an object the fresh packs hold
        // stays there, unless only a retained cruft pack holds it, and
        // with an older time.
        if (fresh.get(oid)) |held| {
            const t = held orelse continue;
            if (time <= t) continue;
        }
        if (options.local and !try db.existsOwn(io, oid)) continue;
        if (!try db.exists(io, oid)) continue;
        try entries.append(arena, .{ .oid = oid, .in_pack = try db.isPacked(oid) });
        // `oe_set_cruft_mtime`: a 32-bit time.
        try mtimes.put(gpa, oid, @truncate(@as(u64, @bitCast(time))));
    }
    if (entries.items.len == 0) return 0;
    // In name order, so the same objects make the same packs.
    std.mem.sort(odb_mod.PackEntry, entries.items, {}, struct {
        fn less(_: void, a: odb_mod.PackEntry, b: odb_mod.PackEntry) bool {
            return a.oid.order(b.oid) == .lt;
        }
    }.less);
    var cruft_options = pack_options;
    cruft_options.mtimes = &mtimes;
    const reports = try writeLimited(db, io, pack_dir, entries.items, cruft_options, limit);
    defer db.allocator().free(reports);
    for (reports) |written| try retained.append(arena, try baseName(arena, written.name));
    return @intCast(reports.len);
}

/// The entries into one pack, or under `limit` into as many as it takes;
/// the reports in the database's allocator.
fn writeLimited(db: *Odb, io: Io, pack_dir: Io.Dir, entries: []const odb_mod.PackEntry, options: odb_mod.PackOptions, limit: ?u64) Self.Error![]pack_mod.WriteReport {
    if (limit) |l| return db.writePacks(io, pack_dir, entries, .{ .pack = options, .max_bytes = l });
    const reports = try db.allocator().alloc(pack_mod.WriteReport, 1);
    errdefer db.allocator().free(reports);
    reports[0] = try db.writePack(io, pack_dir, entries, options);
    return reports;
}

fn addFresh(gpa: Allocator, db: *Odb, name: []const u8, fresh: *Oid.Map(?i64), time: ?i64) Allocator.Error!void {
    const p = db.packNamed(name) orelse return;
    for (0..p.index.count) |i| try fresh.put(gpa, p.index.nameAt(@intCast(i)), time);
}

fn oidBefore(_: void, l: Oid, r: Oid) bool {
    return l.order(r) == .lt;
}
