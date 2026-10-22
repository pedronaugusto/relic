//! The working tree: staging it, writing a tree out of it, putting a tree
//! into it, and saying how the three views differ.
//!
//! Every path that comes out of a tree or an index is validated before it
//! becomes a filesystem path, because a tree entry's name is written by
//! whoever wrote the tree.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.worktree.<name>`.

const sparse = @import("../patterns.zig").sparse;

const ignore = @import("../patterns.zig").ignore;
const attributes = @import("../patterns.zig").attributes;

const convert = @import("convert.zig");
const fsmonitor = @import("fsmonitor.zig");
const filter = @import("filter.zig");
const dir_scan = @import("dir_scan.zig");
const safe_path = @import("../names.zig").path;

const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const fs = @import("../fs/fs.zig");
const sparse_index = @import("../index/sparse_index.zig");
const pack_mod = @import("../odb/pack.zig");
const gitlink = @import("../discover.zig").gitlink;
const native = @import("native.zig");
const program = @import("../process.zig").program;
const config_mod = @import("../config/config.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Odb = odb_mod.Odb;

/// Errors from working-tree operations.
pub const Error = error{
    /// A path in a tree or an index that must never become a filesystem
    /// path. `refusedPath` on the outcome says which and why.
    UnsafePath,
    /// The attributes name a setting this release cannot honour, so the
    /// blob it would write is not the blob git would write.
    UnsupportedAttribute,
    /// A tree entry named a type the working tree cannot hold here.
    UnsupportedEntry,
    /// Line-ending normalization would not round-trip and `core.safecrlf`
    /// requires staging to stop.
    IrreversibleConversion,
    /// The same path appeared twice with different case on a filesystem
    /// that folds case, so one would silently overwrite the other.
    CaseCollision,
    /// An untracked file stands where the update puts one, or a directory
    /// with untracked content where it puts a file: git's "untracked
    /// working tree files would be overwritten". `Obstructions` lists them.
    UntrackedWouldBeOverwritten,
    /// A `SubmoduleProbe` could not read a submodule's repository. The probe
    /// says which and why.
    SubmoduleUnreadable,
    /// A `SubmoduleMover` could not move a submodule, or found before
    /// anything was written that it could not: git's "Cannot update
    /// submodule", with every such path in `Obstructions`. The mover says
    /// why.
    SubmoduleNotUpdated,
    /// A repository inside the working tree has no commit checked out, so a
    /// gitlink for it would have nothing to record. git's `add` stops there
    /// too. `AddOptions.refusal` says which.
    NoCommitCheckedOut,
    /// A tracked file the update changes or removes has changes of its own
    /// in the working tree: git's "your local changes would be
    /// overwritten". `Obstructions` lists them.
    LocalChangesWouldBeOverwritten,
    /// The index has conflicts, which a checkout that keeps local changes
    /// cannot start from.
    UnmergedIndex,
} || Allocator.Error || odb_mod.Error || index_mod.ReadError || fsmonitor.Error ||
    index_mod.WriteError || fs.StatError || Io.Dir.Iterator.Error ||
    Io.Dir.OpenError || Io.Dir.DeleteFileError || Io.Dir.DeleteDirError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.SymLinkError ||
    Io.Dir.ReadLinkError || Io.Writer.Error || fs.SyncError ||
    Io.File.SetPermissionsError || object.Tree.Builder.AddError ||
    object.TreeParseError || convert.Error || sparse_index.Error || gitlink.Error;

/// What the caller supplies so that a blob is hashed the way git would hash
/// it, and so that ignore rules are the ones git would apply.
pub const Rules = struct {
    /// Ignore rules, already loaded for the root. The walk pushes and pops
    /// deeper levels itself.
    ignore: ?*ignore.Rules = null,
    /// Attributes, already loaded for the root.
    attrs: ?*attributes.Attrs = null,
    /// The `core` settings that take part in line-ending conversion.
    core: attributes.CoreSettings = .{},
    /// Filter names whose `filter.<name>.required` is true. Read only when
    /// `filters` is null, and then a path naming one is refused.
    required_filters: []const []const u8 = &.{},
    /// The filter drivers and relic's own LFS, from `Repository.loadFilters`.
    /// Null is what relic did before it ran filters: a required driver is
    /// refused through `required_filters` and every other is passed over.
    filters: ?*const filter.Drivers = null,
    /// Whether the filesystem folds case, from `core.ignoreCase`.
    ignore_case: bool = false,
    /// `core.precomposeUnicode`, which git acts on only on macOS: a name
    /// read from the working tree in its decomposed spelling is taken
    /// composed (`fs.readName`), as git's `readdir` gives it.
    precompose_unicode: bool = false,
    /// How much of a cached stat to believe, from `core.checkStat`.
    check_stat: fs.Stat.Check = .full,
    /// `core.protectNTFS` and `core.protectHFS`: the spellings of `.git`
    /// another file system opens as it, refused in what is written.
    protect: safe_path.Protect = .{},
    /// `core.trustCtime`.
    trust_ctime: bool = true,
    /// How fine a modification time the working tree's filesystem records.
    /// `Repository.worktreeRules` fills it in from what the object database
    /// measured at open; the default believes every nanosecond, which is
    /// what this package assumed before it measured.
    timestamp_resolution: fs.Resolution = .nanosecond,
    /// Whether the filesystem records an executable bit, from
    /// `core.fileMode`. When false the index's mode is preserved rather
    /// than taken from the disk.
    file_mode: bool = Io.File.Permissions.has_executable_bit,
    /// Whether symlinks can be created, from `core.symlinks`. When false a
    /// symlink is written as a file holding its target, which is what that
    /// setting means, and the outcome records it.
    symlinks: bool = builtin.target.os.tag != .windows,

    /// git for Windows' `core.hideDotFiles`: which files and directories a
    /// checkout makes are hidden. Nothing outside Windows.
    hide_dot_files: fs.HideDotFiles = .dot_git_only,
    /// `core.ignoreStat`: an entry an add or a write takes the stat of is
    /// marked `assume_valid`, which nothing compares against the disk.
    ignore_stat: bool = false,
    /// `--recurse-submodules` and `submodule.recurse`: what moves the
    /// submodules whose gitlinks are written or removed. Without one a
    /// gitlink is written as an empty directory.
    submodules: ?SubmoduleMover = null,

    /// Put the stat an add or a write found into `entry`: git's
    /// `fill_stat_cache_info`, which under `ignore_stat` marks the entry
    /// assume-valid.
    pub fn fillStat(r: Rules, entry: *index_mod.Entry, stat: fs.Stat) void {
        entry.stat = stat;
        if (r.ignore_stat) entry.assume_valid = true;
    }

    /// How a cached stat is compared with the disk under these rules.
    pub fn statCompare(r: Rules) fs.Stat.Compare {
        return .{ .check = r.check_stat, .trust_ctime = r.trust_ctime, .resolution = r.timestamp_resolution };
    }
};

/// What `addAll` changed.
pub const AddOutcome = struct {
    added: u32 = 0,
    modified: u32 = 0,
    removed: u32 = 0,
    /// Entries whose cached stat matched, so nothing was read or hashed.
    unchanged: u32 = 0,
    /// Files whose stat matched but which the racy rule made this read
    /// anyway. A number a benchmark watches.
    racy_checked: u32 = 0,
    /// How many times a file was opened and hashed.
    hashed: u32 = 0,
    /// The pack the new blobs went into, when `AddOptions.new_blobs` asked
    /// for one and there was anything to write.
    pack: ?pack_mod.WriteReport = null,
    /// The pack the files past `core.bigFileThreshold` that nothing
    /// converts went into, as git's add streams such a file into a pack
    /// (`index_fd`): one for the call, where new blobs go loose.
    streamed_pack: ?pack_mod.WriteReport = null,
    /// Repositories inside the working tree that the index had nothing for,
    /// staged as gitlinks to the commit each has checked out. Counted in
    /// `added` too. git stages them the same way and warns about each, since
    /// a clone of the superproject gets a gitlink and no url to fill it
    /// from; a caller says so from this.
    nested_repositories: u32 = 0,
    /// Gitlinks whose submodule has another commit checked out than the
    /// index records, and which now record that one. Counted in `modified`
    /// too.
    gitlinks_moved: u32 = 0,
    /// Paths the working tree holds that a tree must never carry — a name
    /// that reaches `.git` on some filesystem, a DOS device name, a
    /// component ending in a dot or a space. They are skipped rather than
    /// staged, and counted here so a caller can say so.
    unsafe_paths: u32 = 0,
    /// Files staged after `core.safecrlf=warn` found a line-ending conversion
    /// that would not round-trip.
    safecrlf_warnings: u32 = 0,
    /// Files skipped under `AddOptions.ignore_errors`. `error_report` names
    /// each path and the error that prevented staging it.
    skipped_errors: u32 = 0,
};

/// Where the blobs a staging pass writes are put.
pub const NewBlobs = enum {
    /// One loose object per blob, which is what git writes.
    loose,
    /// One pack for the whole call.
    ///
    /// A loose object costs two filesystem calls nothing can avoid -- the
    /// exclusive create of its temporary and the rename that finishes it --
    /// and on a staging pass over a few thousand new files those two are most
    /// of the time. A pack is one file, so it costs them once.
    ///
    /// What it gives up is what a pack gives up: the objects are not
    /// visible to a reader until the pass is over, and nothing is deltified,
    /// because a delta wants the object before it and a walk hands them over
    /// one at a time. `Odb.repack` is what deltifies.
    pack,
    /// Loose until the call has written `unpack_limit` new blobs, and the
    /// rest into one pack: a pass that brings a few new files leaves no
    /// pack behind it, and one that brings thousands pays for few of them.
    auto,

    /// git's `fetch.unpackLimit`: the number of objects at which a fetch
    /// keeps what it received as a pack rather than as loose objects.
    pub const unpack_limit = 100;
};

/// `add.ignoreErrors`, or its older spelling `add.ignore-errors`, the last
/// of either deciding, as git's `add_config` reads them: what
/// `AddOptions.ignore_errors` is for `git add` when the command line says
/// neither `--ignore-errors` nor `--no-ignore-errors`. Off when unset.
pub fn ignoreErrorsConfigured(config: *const config_mod.Config) config_mod.ValueError!bool {
    var on = false;
    var it = config.iterate(&.{ "add.ignoreerrors", "add.ignore-errors" });
    while (it.next()) |entry| on = if (entry.value) |value| try config_mod.parseBool(value) else true;
    return on;
}

/// How `addAll` behaves.
pub const AddOptions = struct {
    rules: Rules = .{},
    /// Where new blobs go.
    new_blobs: NewBlobs = .loose,
    /// How the pack is written, where `new_blobs` asks for one.
    pack: odb_mod.PackOptions = .{ .delta = .none },
    /// Whether to stage deletions for index entries whose file is gone.
    /// `git add -A` does; `git add .` without `-A` does not.
    stage_deletions: bool = true,
    /// Skip files that cannot be read or hashed and keep staging the rest,
    /// as `git add --ignore-errors` does. `error_report` records each path
    /// and error; `AddOutcome.skipped_errors` counts them. Without this,
    /// the first such error stops the walk. `ignoreErrorsConfigured` is
    /// what `git add` takes when its command line does not say.
    ignore_errors: bool = false,
    /// Where files skipped under `ignore_errors` are reported.
    error_report: ?*AddErrorReport = null,
    /// A path to limit the walk to, `/`-separated: a directory, whose
    /// files are walked, or one file. Empty walks the whole tree.
    prefix: []const u8 = "",
    /// The permission to run the filter programs `rules.filters` names.
    programs: ?program.Programs = null,
    /// Where filters passed over are reported.
    filter_report: ?*filter.Report = null,
    /// Where the path is written when a repository inside the working tree
    /// stops the walk with `error.NoCommitCheckedOut`.
    refusal: ?*Refusal = null,
};

/// Files a staging pass skipped under `AddOptions.ignore_errors`.
/// The caller owns this report and hands it in through `error_report`.
pub const AddErrorReport = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    /// Paths and errors in the order the walk met them. Paths are owned by
    /// this report and remain valid after `addAll` returns.
    failures: std.ArrayList(Failure) = .empty,

    pub const Failure = struct {
        path: []u8,
        err: ErrorNamespace.Error,
    };

    /// An empty report allocated from `gpa`.
    pub fn init(gpa: Allocator) AddErrorReport {
        return .{ .gpa = gpa };
    }

    /// Release the paths and the list.
    pub fn deinit(r: *AddErrorReport) void {
        for (r.failures.items) |failure| r.gpa.free(failure.path);
        r.failures.deinit(r.gpa);
        r.* = undefined;
    }

    fn record(r: *AddErrorReport, path: []const u8, err: ErrorNamespace.Error) Allocator.Error!void {
        const owned = try r.gpa.dupe(u8, path);
        errdefer r.gpa.free(owned);
        try r.failures.append(r.gpa, .{ .path = owned, .err = err });
    }
};

pub const Inputs = struct { index: *Index, db: *Odb };
pub const CheckoutInputs = struct { index: *Index, db: *Odb, tree: Oid };
pub const PathInputs = struct { index: *Index, db: *Odb, writes: []const PathWrite };
pub const VerifyInputs = struct { index: *const Index, updates: *const std.array_hash_map.String(?TreeEntry) };
pub const CompareInputs = struct { index: *const Index, entry: index_mod.Entry };
pub const SparseInputs = struct { index: *Index, db: *Odb, patterns: *const sparse.Patterns };

/// `git add -A`: walk the working tree, stage what changed, stage deletions,
/// and keep the cache tree true.
///
/// The stat shortcut is what makes a warm call cheap: an entry whose
/// recorded stat still matches the file is neither opened nor hashed. git's
/// racy rule is what keeps it correct: an entry whose modification time is
/// not older than the index's own is read anyway, because a file rewritten
/// inside one second without changing size is invisible to a stat.
///
/// A repository inside the working tree that the index has nothing for is
/// staged as git stages it, as a gitlink to the commit it has checked out,
/// and counted in `AddOutcome.nested_repositories`; one with no commit
/// checked out is `error.NoCommitCheckedOut`, where git's `add` stops too.
pub fn addAll(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: Inputs,
    options: AddOptions,
) Self.Error!AddOutcome {
    const index = inputs.index;
    const db = inputs.db;
    var outcome: AddOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    var scratch_instance: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_instance.deinit();

    var fresh: std.ArrayList(index_mod.Entry) = .empty;
    defer fresh.deinit(gpa);

    // A sparse directory the working tree has after all is expanded first,
    // so that what is in it is compared and staged against its own entries.
    if (index.sparse) try sparse_index.expandPresent(gpa, io, wt, index, db);

    // One pack for the whole call, where the caller asked for one. It is
    // opened before the walk so that an object written early in it is in
    // the same file as one written late, and finished after, so that a
    // reader sees all of them or none.
    var filling: ?Odb.OpenPack = null;
    errdefer if (filling) |open| db.abortPack(io, open);
    if (options.new_blobs == .pack) filling = try db.beginPack(io, options.pack);
    // `.auto` opens it on the way, once enough new blobs have gone loose.
    var streamed: ?Odb.OpenPack = null;
    errdefer if (streamed) |open| db.abortPack(io, open);

    var conv: convert.Session = .open(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .index = index,
        .db = db,
    });
    defer conv.deinit(io);

    var walker: Walker = .{
        .gpa = gpa,
        .conv = &conv,
        .arena = &arena_instance,
        .scratch = &scratch_instance,
        .io = io,
        .wt = wt,
        .index = index,
        .db = db,
        .options = options,
        .outcome = &outcome,
        .seen = &seen,
        .fresh = &fresh,
        .filling = &filling,
        .streamed = &streamed,
    };
    try walker.walkFrom(options.prefix);
    if (filling) |open| {
        // Out of the errdefer's reach before it is closed, because closing
        // it releases it whether it succeeded or not.
        filling = null;
        outcome.pack = try db.finishPack(io, open);
    }
    if (streamed) |open| {
        streamed = null;
        outcome.streamed_pack = try db.finishPack(io, open);
    }
    // New entries go in once, sorted once. A walk produces paths in tree
    // order and the index is in path order, so inserting them one at a time
    // would move the tail of the list on almost every file. One that
    // resolves a conflict replaces its stages, which the index remembers,
    // as git's `add_index_entry` does.
    try index.addMany(fresh.items);
    for (fresh.items) |entry| _ = try index.resolveStages(entry.path);

    if (options.stage_deletions) {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(gpa);
        for (index.entries.items) |entry| {
            const under_prefix = options.prefix.len == 0 or std.mem.eql(u8, entry.path, options.prefix) or
                (std.mem.startsWith(u8, entry.path, options.prefix) and
                    entry.path.len > options.prefix.len and
                    entry.path[options.prefix.len] == '/');
            if (!under_prefix or entry.skip_worktree or entry.isSparseDirectory() or seen.contains(entry.path)) continue;
            // The file is gone from the working tree: stage its removal,
            // remembering a conflict's stages as git does.
            const tree = try index.cacheTree();
            tree.invalidate(entry.path);
            try index.recordResolveUndo(entry);
            try gone.append(gpa, entry.path);
            outcome.removed += 1;
        }
        index.removeMany(gone.items);
    }
    try db.syncBatch(io);
    return outcome;
}

// Every filesystem walk uses the same distinction: a vanished directory
// can be absent, but a directory that could not be read cannot be empty.
fn openWalkDirectory(io: Io, wt: Io.Dir, path: []const u8) Error!?Io.Dir {
    if (path.len == 0) return wt;
    return wt.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
}

const Walker = struct {
    gpa: Allocator,
    /// The conversions, and the filter processes, for the whole walk.
    conv: *convert.Session,
    /// Lives for the whole walk: the paths `seen` holds.
    arena: *std.heap.ArenaAllocator,
    /// Reset after every file, so one file's temporary bytes do not
    /// accumulate over three thousand of them.
    scratch: *std.heap.ArenaAllocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    options: AddOptions,
    outcome: *AddOutcome,
    seen: *std.StringHashMapUnmanaged(void),
    /// Entries for paths the index did not have, added in one sorted pass
    /// at the end. Their paths live in `arena`.
    fresh: *std.ArrayList(index_mod.Entry),
    /// The pack the blobs go into, where the caller asked for one.
    /// The pack new blobs go into, once there is one; `addAll` finishes it.
    filling: *?Odb.OpenPack,
    /// The pack git streams big files into, opened at the first one.
    streamed: *?Odb.OpenPack,
    /// New blobs this pass has written loose, for `NewBlobs.auto`.
    loose_new: u32 = 0,

    /// The walk from `prefix`: the directory's files, or the one file it
    /// names, under the rules of the directory that holds it.
    fn walkFrom(w: *Walker, prefix: []const u8) Error!void {
        if (prefix.len != 0) if (try fs.statAt(w.io, w.wt, prefix)) |found| switch (found.kind) {
            .sym_link, .file => {
                const parent = std.Io.Dir.path.dirnamePosix(prefix) orelse "";
                if (w.options.rules.ignore) |rules| try rules.addDirectory(w.io, w.wt, parent, 0);
                defer if (w.options.rules.ignore) |rules| rules.popTo(2);
                if (w.options.rules.attrs) |attrs| try attrs.addDirectory(w.io, w.wt, parent, 0);
                defer if (w.options.rules.attrs) |attrs| attrs.popTo(1);
                return w.stageFile(prefix, found);
            },
            else => {},
        };
        return w.walk(prefix, 0);
    }

    fn walk(w: *Walker, dir_path: []const u8, depth: u32) Error!void {
        if (depth > 64) return error.TreeTooDeep;
        const dir = (try openWalkDirectory(w.io, w.wt, dir_path)) orelse return;
        defer if (dir_path.len != 0) dir.close(w.io);

        if (w.options.rules.ignore) |rules| try rules.addDirectory(w.io, w.wt, dir_path, depth);
        defer if (w.options.rules.ignore) |rules| rules.popTo(depth + 2);
        if (w.options.rules.attrs) |attrs| try attrs.addDirectory(w.io, w.wt, dir_path, depth);
        defer if (w.options.rules.attrs) |attrs| attrs.popTo(depth + 1);

        // The entries are collected first so the directory handle is not held
        // open across the work each one causes, which matters on Windows. The
        // stat comes with the name where the platform has a call that gives
        // both, and from a stat of its own where it does not.
        var entries: std.ArrayList(Found) = .empty;
        defer {
            for (entries.items) |e| w.gpa.free(e.name);
            entries.deinit(w.gpa);
        }
        var scan = try dir_scan.Scan.init(w.gpa, w.io, dir, .{ .precompose = w.options.rules.precompose_unicode });
        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            const name = try w.gpa.dupe(u8, item.name);
            errdefer w.gpa.free(name);
            try entries.append(w.gpa, .{ .name = name, .entry = item.entry });
        }
        std.mem.sort(Found, entries.items, {}, lessThanFound);

        for (entries.items) |e| {
            const path = if (dir_path.len == 0)
                try w.gpa.dupe(u8, e.name)
            else
                try w.gpa.print("{s}/{s}", .{ dir_path, e.name });
            defer w.gpa.free(path);

            switch (e.entry.kind) {
                .directory => try w.enterDirectory(path, depth, e.entry),
                .sym_link, .file => try w.stageFile(path, e.entry),
                // A socket, a fifo or a device is not something a tree can
                // hold, and git skips it silently.
                else => {},
            }
        }
    }

    fn enterDirectory(w: *Walker, path: []const u8, depth: u32, found: fs.Entry) Error!void {
        // A gitlink's directory is a submodule's, whatever it holds: nothing
        // in it is walked, and what is staged for it is the commit its
        // repository has checked out, which is git's `add -A`. One nobody
        // populated, or whose `HEAD` names nothing, stays as recorded.
        if (w.index.find(path)) |entry| {
            if (entry.mode == .gitlink) {
                try w.markSeen(path);
                const checked_out = (try gitlink.head(w.gpa, w.io, w.wt, path)) orelse {
                    w.outcome.unchanged += 1;
                    return;
                };
                if (checked_out.eql(entry.oid)) {
                    w.outcome.unchanged += 1;
                    return;
                }
                const tree = try w.index.cacheTree();
                tree.invalidate(path);
                entry.oid = checked_out;
                w.options.rules.fillStat(entry, found.stat);
                w.outcome.modified += 1;
                w.outcome.gitlinks_moved += 1;
                return;
            }
        }
        // A directory the index has files under is walked like any other,
        // even when it holds a `.git` of its own: git descends into it too.
        if (!w.index.hasDirectory(path)) {
            if (w.options.rules.ignore) |rules| {
                // An excluded directory is not entered at all, so a negation
                // inside it cannot bring anything back — which is git's rule.
                if (rules.match(path, .dir).excluded) return;
            }
            if (try gitlink.isRepository(w.gpa, w.io, w.wt, path)) return w.stageRepository(path, found);
        }
        try w.walk(path, depth + 1);
    }

    /// A repository inside the working tree that the index has nothing for
    /// is staged as git's `add -A` stages it: a gitlink to the commit it has
    /// checked out, its directory never walked.
    fn stageRepository(w: *Walker, path: []const u8, found: fs.Entry) Error!void {
        if (!safe_path.isSafeStoredPath(path, w.options.rules.protect)) {
            w.outcome.unsafe_paths += 1;
            return;
        }
        const checked_out = (try gitlink.head(w.gpa, w.io, w.wt, path)) orelse {
            if (w.options.refusal) |r| r.set(null, path);
            return error.NoCommitCheckedOut;
        };
        try w.markSeen(path);
        const tree = try w.index.cacheTree();
        tree.invalidate(path);
        var added: index_mod.Entry = .{
            .path = try w.arena.allocator().dupe(u8, path),
            .oid = checked_out,
            .mode = .gitlink,
        };
        w.options.rules.fillStat(&added, found.stat);
        try w.fresh.append(w.gpa, added);
        w.outcome.added += 1;
        w.outcome.nested_repositories += 1;
    }

    /// Remember that a path is still in the working tree, so the deletion
    /// pass does not stage its removal. The copy lives in the walk's arena
    /// because the caller's buffer does not outlive the iteration.
    fn markSeen(w: *Walker, path: []const u8) Error!void {
        const owned = try w.arena.allocator().dupe(u8, path);
        try w.seen.put(w.gpa, owned, {});
    }

    fn stageFile(w: *Walker, path: []const u8, found: fs.Entry) Error!void {
        const tracked = w.index.find(path);
        // A conflicted path is in the index, at its stages, and is added
        // whatever the ignore rules say.
        const conflicted = tracked == null and (w.index.findStage(path, 1) != null or
            w.index.findStage(path, 2) != null or w.index.findStage(path, 3) != null);
        if (tracked == null) {
            if (!conflicted) if (w.options.rules.ignore) |rules| {
                if (rules.match(path, .file).excluded) return;
            };
        } else if (tracked.?.skip_worktree) {
            try w.markSeen(path);
            return;
        }
        if (!safe_path.isSafeStoredPath(path, w.options.rules.protect)) {
            w.outcome.unsafe_paths += 1;
            return;
        }
        try w.markSeen(path);

        const mode = modeOnDisk(found, if (tracked) |entry| entry.mode else null, w.options.rules);

        if (tracked) |entry| {
            const racy = w.index.isRacy(entry.*);
            if (!racy and !entry.intent_to_add and
                entry.mode == mode and
                entry.stat.matches(found.stat, w.options.rules.statCompare()))
            {
                w.outcome.unchanged += 1;
                return;
            }
            if (racy) w.outcome.racy_checked += 1;
        }

        const read = w.readForAdd(path, found) catch |err| {
            try w.skipFile(path, err);
            return;
        };
        const blob = w.store(read) catch |err| switch (err) {
            error.CollisionAttack => {
                try w.skipFile(path, err);
                return;
            },
            // A failed object write, especially halfway through a pack,
            // cannot be recovered by passing over a working-tree file.
            else => return err,
        };
        w.outcome.hashed += 1;

        if (tracked) |entry| {
            if (entry.oid.eql(blob) and entry.mode == mode) {
                // The content did not change after all; refresh the stat so
                // the next call takes the shortcut.
                w.options.rules.fillStat(entry, found.stat);
                entry.intent_to_add = false;
                w.outcome.unchanged += 1;
                return;
            }
        }

        const tree = try w.index.cacheTree();
        tree.invalidate(path);
        if (tracked) |entry| {
            entry.oid = blob;
            entry.mode = mode;
            w.options.rules.fillStat(entry, found.stat);
            entry.intent_to_add = false;
            w.outcome.modified += 1;
        } else {
            var added: index_mod.Entry = .{
                .path = try w.arena.allocator().dupe(u8, path),
                .oid = blob,
                .mode = mode,
            };
            w.options.rules.fillStat(&added, found.stat);
            try w.fresh.append(w.gpa, added);
            w.outcome.added += 1;
        }
    }

    fn skipFile(w: *Walker, path: []const u8, err: Error) Error!void {
        // Cancellation and allocation failure stop the operation even when
        // individual files may be passed over.
        if (!w.options.ignore_errors or err == error.Canceled or err == error.OutOfMemory) return err;
        if (w.options.error_report) |report| try report.record(path, err);
        w.outcome.skipped_errors += 1;
    }

    /// A file's blob as it is stored, and whether git streams it into a
    /// pack: a regular file past `core.bigFileThreshold` (the database's
    /// pack settings carry it) that nothing would convert.
    const Read = struct { bytes: []const u8, streamed: bool = false };

    fn readForAdd(w: *Walker, path: []const u8, found: fs.Entry) Error!Read {
        _ = w.scratch.reset(.retain_capacity);
        const a = w.scratch.allocator();

        if (found.kind == .sym_link) {
            var buf: [4096]u8 = undefined;
            const len = try w.wt.readLink(w.io, path, &buf);
            return .{ .bytes = try a.dupe(u8, buf[0..len]) };
        }

        const big = aegis.units.Bytes(u64).fromRaw(found.stat.size).compare(w.db.packOptions().big_file_bytes) == .gt;
        if (w.options.rules.attrs) |attrs| {
            const applied = try attrs.lookup(a, path, .file);
            if (big and !try w.conv.wouldConvertToGit(path, applied)) {
                return .{ .bytes = try fs.readFileSized(a, w.io, w.wt, path, .{ .size = found.stat.size, .max_bytes = 1 << 31 }), .streamed = true };
            }
            const converted = try w.conv.toGitFile(a, .{ .path = path, .size = found.stat.size, .applied = applied }, .{ .storing = .store });
            if (converted.irreversible) switch (w.options.rules.core.safecrlf) {
                .false => {},
                .true => return error.IrreversibleConversion,
                .warn => w.outcome.safecrlf_warnings += 1,
            };
            return .{ .bytes = converted.bytes };
        }
        return .{ .bytes = try fs.readFileSized(a, w.io, w.wt, path, .{ .size = found.stat.size, .max_bytes = 1 << 31 }), .streamed = big };
    }

    /// Put a blob where this pass puts them: a streamed one into the pack
    /// for those, unless every blob goes into one.
    fn store(w: *Walker, read: Read) Error!Oid {
        const bytes = read.bytes;
        if (w.filling.*) |open| return w.db.writeInto(w.io, open, .blob, bytes);
        if (read.streamed) {
            if (w.streamed.* == null) w.streamed.* = try w.db.beginPack(w.io, streamedPackOptions(w.db));
            return w.db.writeInto(w.io, w.streamed.*.?, .blob, bytes);
        }
        const written = w.db.stats.loose_written;
        const oid = try w.db.write(w.io, .blob, bytes);
        if (w.db.stats.loose_written != written) w.loose_new += 1;
        if (w.options.new_blobs == .auto and w.loose_new >= NewBlobs.unpack_limit) {
            w.filling.* = try w.db.beginPack(w.io, w.options.pack);
        }
        return oid;
    }
};

/// How git's add writes the pack it streams big files into
/// (`stream_blob_to_pack`): each object whole, deflated at the pack's
/// compression, with a version 2 index and no reverse index.
fn streamedPackOptions(db: *Odb) odb_mod.PackOptions {
    var options = db.packOptions();
    options.delta = .none;
    options.index_version = 2;
    options.reverse_index = false;
    return options;
}

/// The mode a file on the disk is staged with, as git's `ce_mode_from_stat`
/// gives it: without `core.symlinks` a file where the index has a link is
/// the link, written as a file; without `core.fileMode` the index's
/// executable bit is kept, there being none on the disk to read.
/// A working tree's files beside the index entries that record them: the
/// objects those name, how a file is converted, and the rules it is read
/// by.
pub const Tracked = struct {
    pub const Error = ErrorNamespace.Error;

    io: Io,
    wt: Io.Dir,
    index: *const Index,
    db: *Odb,
    conv: *convert.Session,
    rules: Rules,

    /// git's `ie_match_stat` with no options: whether the file `found` at
    /// `path` is what `entry` records -- of its kind and mode, its stat
    /// matching, and where the stat cannot vouch for it (the racy case) its
    /// content as it would be stored. An intent to add matches nothing.
    pub fn matches(t: Tracked, a: Allocator, entry: index_mod.Entry, path: []const u8, found: fs.Entry) Self.Error!bool {
        if (entry.intent_to_add) return false;
        if (entry.mode != modeOnDisk(found, entry.mode, t.rules)) return false;
        return t.sameContent(a, entry, path, found);
    }

    /// Whether a file of the entry's mode holds what the entry records: its
    /// stat, or where that cannot vouch for it, its content.
    pub fn sameContent(t: Tracked, a: Allocator, entry: index_mod.Entry, path: []const u8, found: fs.Entry) Self.Error!bool {
        if (!t.index.isRacy(entry) and entry.stat.matches(found.stat, t.rules.statCompare())) return true;
        // The stat says it may have changed; the content says whether it
        // did. This is the racy rule doing its work.
        const content = try t.storedBytes(a, path, found);
        return hash.Hasher.object(t.db.objectFormat(), "blob", content).eql(entry.oid);
    }

    /// What `path` would be stored as: a symlink's target, a file's bytes
    /// through its clean filter, encoding, line endings and `ident`, as
    /// git's `diff_populate_filespec` reads a working-tree file.
    pub fn storedBytes(t: Tracked, a: Allocator, path: []const u8, found: fs.Entry) Self.Error![]const u8 {
        if (found.kind == .sym_link) {
            var buf: [4096]u8 = undefined;
            const len = try t.wt.readLink(t.io, path, &buf);
            return a.dupe(u8, buf[0..len]);
        }
        if (t.rules.attrs) |attrs| {
            const applied = try attrs.lookup(a, path, .file);
            return (try t.conv.toGitFile(a, .{ .path = path, .size = found.stat.size, .applied = applied }, .{ .storing = .hash_only })).bytes;
        }
        return t.wt.readFileAlloc(t.io, path, a, .limited(1 << 31));
    }
};

fn modeOnDisk(found: fs.Entry, tracked: ?object.Mode, rules: Rules) object.Mode {
    if (found.kind == .sym_link) return .symlink;
    if (!rules.symlinks and tracked == .symlink) return .symlink;
    if (rules.file_mode) return if (found.executable) .exec else .file;
    return if (tracked == .exec) .exec else .file;
}

/// One entry of a directory, kept while the rest of it is read.
const Found = struct {
    name: []const u8,
    entry: fs.Entry,
};

fn lessThanFound(_: void, a: Found, b: Found) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Build the tree the index describes, through the cache tree, and return
/// its name.
///
/// A cache-tree node that is still valid is used as it stands: no directory
/// under it is rebuilt and no tree object is written for it. That is the
/// difference between a warm call and a cold one.
pub fn writeTree(gpa: Allocator, io: Io, index: *Index, db: *Odb) Self.Error!Oid {
    return writeTreeInto(gpa, io, index, db, null);
}

/// `writeTree`, with the tree objects it writes going into a pack the
/// database is filling, when one is given.
pub fn writeTreeInto(gpa: Allocator, io: Io, index: *Index, db: *Odb, filling: ?Odb.OpenPack) Self.Error!Oid {
    _ = gpa;
    const tree = try index.cacheTree();
    const oid = try tree.rebuildInto(io, index.entries.items, db, filling);
    try db.syncBatch(io);
    return oid;
}

/// One path's difference between two of the three views.
pub const Change = enum {
    unmodified,
    added,
    modified,
    deleted,
    /// A file became a symlink, or a symlink a file, or a gitlink appeared.
    type_changed,
    /// Present in the working tree and in no index entry.
    untracked,
    /// Present in the working tree and excluded by an ignore rule.
    ignored,
    /// Under this path from `StatusEntry.source`, which is gone from that
    /// side: what `worktree.renames.find` finds among the staged changes,
    /// or among the working tree's.
    renamed,
    /// Under this path as a copy of `StatusEntry.source`.
    copied,
};

/// One path's status.
pub const StatusEntry = struct {
    /// Owned by the `Status`. A directory reported whole ends in `/`, as
    /// git prints it: a repository inside the working tree, an untracked
    /// directory under `Untracked.normal`, an ignored one.
    path: []const u8,
    /// HEAD against the index.
    staged: Change,
    /// The index against the working tree.
    unstaged: Change,
    /// Set when the path has entries at stages 1 to 3.
    conflicted: bool = false,
    /// Where a `renamed` or `copied` path came from, and how alike the two
    /// are, in percent.
    source: ?[]const u8 = null,
    score: u8 = 0,
    /// Set when the path is a gitlink in `HEAD` or in the index: the path is
    /// a submodule, and this is what its working tree holds. It is the `S<c><m><u>` field of
    /// `git status --porcelain=v2`, where every other path has `N...`.
    submodule: ?SubmoduleState = null,
    /// For a file the index holds as an intent to add, when
    /// `StatusOptions.added_content` asks: what the working tree holds
    /// there.
    added: ?Added = null,

    /// A working-tree file as it would be stored: its mode, its bytes
    /// through the clean filter and line endings, and the blob they make.
    pub const Added = struct { mode: object.Mode, oid: Oid, bytes: []const u8 };
};

/// What a submodule's working tree holds, as its superproject's status sees
/// it.
///
/// Any of the three makes the gitlink modified in the working tree, which
/// is the ` M` that `git status --porcelain` prints for all three alike.
pub const SubmoduleState = struct {
    /// Its `HEAD` is another commit than the one the index records.
    new_commits: bool = false,
    /// It has tracked changes, staged or not, or a submodule of its own
    /// does.
    modified_content: bool = false,
    /// It has untracked files, or a submodule of its own does.
    untracked_content: bool = false,

    /// Whether none of the three holds.
    pub fn isClean(s: SubmoduleState) bool {
        return !s.new_commits and !s.modified_content and !s.untracked_content;
    }
};

/// One move a checkout asks of a submodule: git's `submodule_move_head`,
/// its working tree and index taken from the commit `from` to the commit
/// `to`, its `HEAD` detached at `to`.
pub const SubmoduleMove = struct {
    /// Relative to the superproject's working tree.
    path: []const u8,
    from: From,
    /// `null` takes the submodule away: its `.git` file and, once empty,
    /// its directory go.
    to: ?Oid,
    /// `SUBMODULE_MOVE_HEAD_FORCE`: the submodule's own changes are
    /// overwritten, as `read-tree --reset` overwrites them, and its index
    /// is not asked to be clean.
    force: bool,
    /// `SUBMODULE_MOVE_HEAD_DRY_RUN`: only whether the move would go
    /// through, as `read-tree -n` answers it. Nothing is written.
    dry_run: bool = false,

    pub const From = union(enum) {
        /// Nothing: the submodule's working tree is made, from its
        /// repository in the superproject's `modules`.
        none,
        /// Its `HEAD`.
        head,
        /// This commit, as the superproject's index records it.
        commit: Oid,
    };
};

/// How a checkout moves the submodules it changes, as git does under
/// `--recurse-submodules`. Without one a gitlink is an empty directory to
/// the working tree, and a submodule's own checkout is left where it is.
///
/// The working-tree layer cannot open another repository, so the moves go
/// through here; `submodule.Mover` makes them the way git does, a
/// submodule's own submodules with them. A move that cannot be made is
/// `error.SubmoduleNotUpdated`, and the mover says which and why.
pub const SubmoduleMover = struct {
    context: *anyopaque,
    moveFn: *const fn (io: Io, context: *anyopaque, move: SubmoduleMove) Error!void,

    /// Make `move`, or with `move.dry_run` say whether it would go through.
    pub fn move(m: SubmoduleMover, io: Io, request: SubmoduleMove) Self.Error!void {
        return m.moveFn(io, m.context, request);
    }
};

/// What `status` asks of a populated submodule.
///
/// The working-tree layer cannot open another repository — that is the
/// layer above it — so the question goes through here.
/// `submodule.StatusProbe` answers it the way git does: it opens the
/// submodule, honours `submodule.<name>.ignore` and `diff.ignoreSubmodules`,
/// and runs a status inside, recursively.
pub const SubmoduleProbe = struct {
    context: *anyopaque,
    inspectFn: *const fn (io: Io, context: *anyopaque, path: []const u8, recorded: Oid) Error!SubmoduleState,
    /// Whether a gitlink whose index entry differs from `HEAD`'s is left out
    /// too. `--ignore-submodules=all` asks for that and no configured
    /// setting can: git always shows a staged submodule, so that one added
    /// by hand is not committed unseen.
    ignore_staged: bool = false,

    /// What the submodule at `path` holds, against the commit the index
    /// records for it, already filtered by what the settings ignore.
    pub fn inspect(p: SubmoduleProbe, io: Io, path: []const u8, recorded: Oid) Self.Error!SubmoduleState {
        return p.inspectFn(io, p.context, path, recorded);
    }
};

/// What `status` found, sorted by path.
pub const Status = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    entries: []StatusEntry,

    /// Release the result.
    pub fn deinit(s: *Status) void {
        var arena = s.arena.promote(s.gpa);
        arena.deinit();
        s.* = undefined;
    }

    /// Whether nothing differs anywhere, ignoring untracked and ignored
    /// paths.
    pub fn isClean(s: *const Status) bool {
        for (s.entries) |entry| {
            if (entry.conflicted) return false;
            if (entry.staged != .unmodified) return false;
            switch (entry.unstaged) {
                .unmodified, .untracked, .ignored => {},
                else => return false,
            }
        }
        return true;
    }

    /// The entry for `path`, or `null`.
    pub fn find(s: *const Status, path: []const u8) ?StatusEntry {
        for (s.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

/// How `status` behaves.
pub const StatusOptions = struct {
    rules: Rules = .{},
    /// The tree `HEAD` points at, or `null` on an unborn branch.
    head_tree: ?Oid = null,
    /// Whether to list untracked files. `all` is what
    /// `--untracked-files=all` asks for; `normal` reports a directory
    /// holding only untracked files once, by its name. Under either, a
    /// repository inside the working tree is one entry, `sub/`, and is
    /// never looked into.
    untracked: Untracked = .all,
    /// Whether to list ignored paths too, as `--ignored` does: under
    /// `normal` an ignored directory is one entry and so is an untracked
    /// one holding nothing but ignored files; under `all` every ignored
    /// file is its own. Nothing is listed under `Untracked.no`, which is
    /// git's rule.
    include_ignored: bool = false,
    /// How a populated submodule is looked into. Without one, a gitlink's
    /// working-tree state is its `HEAD` against the recorded commit and
    /// nothing else: no content is inspected and no ignore setting is read.
    submodules: ?SubmoduleProbe = null,
    /// The permission to run the clean filters `rules.filters` names, which
    /// is how a filtered file whose stat changed is compared.
    programs: ?program.Programs = null,
    /// Where filters passed over are reported.
    filter_report: ?*filter.Report = null,
    /// The file monitor to ask what changed: `fsmonitor.configured` for
    /// git's hook, or the caller's own. A file it vouches for is taken as
    /// the index has it and not looked at, and a file found unchanged is
    /// vouched for from then on, in `index`, which the caller writes to
    /// keep it -- git writes it when `Index.fsmonitor_changed` says. With `untracked = .no` only the files it does not vouch for
    /// are looked at, and no directory is read.
    fsmonitor: ?fsmonitor.Source = null,
    /// Whether to keep `StatusEntry.added` for each file the index holds as
    /// an intent to add: the bytes `worktree.renames.find` pairs the working
    /// tree's deletions with, read as git's rename detection reads such a
    /// file (`diff_populate_filespec`, `hash_filespec`).
    added_content: bool = false,

    /// How much of an untracked directory `status` reports: nothing, the
    /// directory itself, or every file under it. These are what `git status`
    /// takes in `--untracked-files`.
    pub const Untracked = enum {
        no,
        normal,
        all,

        /// git's `parse_untracked_setting_name`, for `--untracked-files`
        /// and `status.showUntrackedFiles`: `no`, `normal` or `all`, or a
        /// boolean, `false` for `no` and `true` (or no value) for `normal`.
        /// `null` for anything else.
        pub fn parse(text: ?[]const u8) ?Untracked {
            const value = text orelse return .normal;
            if (config_mod.parseBool(value)) |on| return if (on) .normal else .no else |_| {}
            return std.meta.stringToEnum(Untracked, value);
        }

        /// `status.showUntrackedFiles`, `normal` when it says nothing, as
        /// `git status` reads it. A mode git does not know is
        /// `error.InvalidUntrackedMode`, which git stops on.
        pub fn configured(config: *const config_mod.Config) error{InvalidUntrackedMode}!Untracked {
            const entry = config.find("status.showuntrackedfiles") orelse return .normal;
            return parse(entry.value) orelse error.InvalidUntrackedMode;
        }
    };
};

/// HEAD against the index against the working tree, as values.
///
/// Never as text: `XY path` is presentation, and a caller that wants it can
/// write two characters from these two enums.
pub fn status(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: Inputs,
    options: StatusOptions,
) Self.Error!Status {
    const index = inputs.index;
    const db = inputs.db;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var entries: std.array_hash_map.String(StatusEntry) = .empty;
    const head = try headSide(arena, io, index, db, options.head_tree);
    try recordStaged(arena, index, &head, options, &entries);
    try recordUnstaged(gpa, arena, io, wt, index, db, options, &entries);
    const out = try keepChanged(arena, index, &head.paths, &entries);
    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = out };
}

/// HEAD as `status` compares the index with it: its files, the directories
/// nothing under which is staged, and the files of each sparse directory
/// whose tree is not HEAD's.
const HeadSide = struct {
    /// HEAD's files, except under the directories in `unchanged` and the
    /// sparse directories HEAD has the same tree for.
    paths: std.StringHashMapUnmanaged(TreeEntry) = .empty,
    /// Directories the cache tree holds as HEAD's own tree; "" is the root.
    unchanged: std.StringHashMapUnmanaged(void) = .empty,
    /// The files of the index's sparse directories that differ from HEAD's.
    expanded: std.StringHashMapUnmanaged(TreeEntry) = .empty,
};

/// HEAD against the index. A sparse directory is a tree: where HEAD has the
/// same tree there, nothing under it differs and neither side is flattened;
/// where it does not, its files are flattened out of the index's tree and
/// compared one by one, as a full index would be.
fn headSide(arena: Allocator, io: Io, index: *const Index, db: *Odb, head_tree: ?Oid) Error!HeadSide {
    var head: HeadSide = .{};
    var sparse_dirs: std.StringHashMapUnmanaged(Oid) = .empty;
    for (index.entries.items) |entry| {
        if (entry.isSparseDirectory()) try sparse_dirs.put(arena, entry.path[0 .. entry.path.len - 1], entry.oid);
    }
    // The cache tree says which directories the index holds exactly as a
    // tree object it names; where HEAD has that same tree, nothing under it
    // is staged and HEAD's side is never read. With nothing staged at all
    // that is the root, and HEAD is not read at all — git's shortcut.
    var cached: std.StringHashMapUnmanaged(Oid) = .empty;
    if (index.cache_tree) |*tree| try validTrees(arena, &tree.root, "", &cached);
    if (head_tree) |tree_oid| {
        if (cached.get("")) |root| {
            if (root.eql(tree_oid)) try head.unchanged.put(arena, "", {});
        }
        if (!head.unchanged.contains("")) {
            try flattenStaged(arena, io, db, tree_oid, "", &head.paths, 0, &sparse_dirs, &cached, &head.unchanged);
        }
    }
    for (index.entries.items) |entry| {
        if (!entry.isSparseDirectory()) continue;
        const dir = entry.path[0 .. entry.path.len - 1];
        if (head_tree) |tree_oid| {
            if (try treeAt(io, db, tree_oid, dir)) |at| {
                if (at.eql(entry.oid)) continue;
            }
        }
        try flattenTree(arena, io, db, entry.oid, dir, &head.expanded, 1, null);
    }
    return head;
}

/// Record what is staged: each index path against HEAD's, a conflict as
/// conflicted, and a HEAD path the index does not have as deleted.
fn recordStaged(
    arena: Allocator,
    index: *const Index,
    head: *const HeadSide,
    options: StatusOptions,
    entries: *std.array_hash_map.String(StatusEntry),
) Allocator.Error!void {
    var expanded_it = head.expanded.iterator();
    while (expanded_it.next()) |pair| {
        const staged = compareToHead(&head.paths, pair.key_ptr.*, pair.value_ptr.mode, pair.value_ptr.oid);
        if (staged == .unmodified) continue;
        const slot = try entries.getOrPut(arena, pair.key_ptr.*);
        slot.value_ptr.* = .{ .path = slot.key_ptr.*, .staged = staged, .unstaged = .unmodified };
    }

    for (index.entries.items) |entry| {
        if (entry.isSparseDirectory()) continue;
        if (entry.stage != 0) {
            const slot = try entries.getOrPut(arena, try arena.dupe(u8, entry.path));
            if (!slot.found_existing) {
                slot.value_ptr.* = .{
                    .path = slot.key_ptr.*,
                    .staged = .unmodified,
                    .unstaged = .unmodified,
                };
            }
            slot.value_ptr.conflicted = true;
            continue;
        }
        // An intent to add is not staged: HEAD's side does not see it, as
        // git's `ita_invisible_in_index` has it, and the working tree's
        // side reports the file added.
        if (entry.intent_to_add) continue;
        if (options.submodules) |probe| {
            if (probe.ignore_staged) {
                const was_gitlink = if (head.paths.get(entry.path)) |e| e.mode == .gitlink else false;
                if (entry.mode == .gitlink or was_gitlink) continue;
            }
        }
        const staged = if (options.head_tree == null or !underAny(&head.unchanged, entry.path))
            compareToHead(&head.paths, entry.path, entry.mode, entry.oid)
        else
            .unmodified;
        if (staged == .unmodified) continue;
        const slot = try entries.getOrPut(arena, try arena.dupe(u8, entry.path));
        slot.value_ptr.* = .{
            .path = slot.key_ptr.*,
            .staged = staged,
            .unstaged = .unmodified,
        };
    }

    var head_it = head.paths.iterator();
    while (head_it.next()) |pair| {
        if (index.find(pair.key_ptr.*)) |e| {
            if (!e.intent_to_add) continue;
        }
        if (head.expanded.contains(pair.key_ptr.*)) continue;
        if (options.submodules) |probe| {
            if (probe.ignore_staged and pair.value_ptr.mode == .gitlink) continue;
        }
        const slot = try entries.getOrPut(arena, pair.key_ptr.*);
        slot.value_ptr.* = .{
            .path = slot.key_ptr.*,
            .staged = .deleted,
            .unstaged = .unmodified,
        };
    }
}

/// The index against the working tree. A file whose stat changed is
/// compared through what it would be stored as, clean filter and all, and
/// an index path the scan never met is deleted.
fn recordUnstaged(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    options: StatusOptions,
    entries: *std.array_hash_map.String(StatusEntry),
) Error!void {
    var conv: convert.Session = .open(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .index = index,
        .db = db,
    });
    defer conv.deinit(io);
    if (options.fsmonitor) |source| try fsmonitor.refresh(gpa, io, wt, index, source);
    var scan: StatusScan = .{
        .gpa = gpa,
        .conv = &conv,
        .arena = arena,
        .io = io,
        .wt = wt,
        .index = index,
        .db = db,
        .options = options,
        .entries = entries,
        .monitored = index.fsmonitor_token != null and index.fsmonitor_refreshed,
    };
    defer scan.seen.deinit(gpa);
    if (scan.monitored and options.untracked == .no) try scan.checkEntries() else try scan.walk("", 0);

    for (index.entries.items) |entry| {
        if (entry.stage != 0 or entry.skip_worktree or entry.isSparseDirectory()) continue;
        if (scan.seen.contains(entry.path)) continue;
        const slot = try entries.getOrPut(arena, try arena.dupe(u8, entry.path));
        if (!slot.found_existing) {
            slot.value_ptr.* = .{ .path = slot.key_ptr.*, .staged = .unmodified, .unstaged = .unmodified };
        }
        slot.value_ptr.unstaged = .deleted;
    }
}

/// Only paths that differ somewhere are reported; an unchanged path is
/// absent, which is what makes the result the same shape as git's. The
/// paths come out sorted, a gitlink on either side marked a submodule.
fn keepChanged(
    arena: Allocator,
    index: *const Index,
    head_paths: *const std.StringHashMapUnmanaged(TreeEntry),
    entries: *const std.array_hash_map.String(StatusEntry),
) Allocator.Error![]StatusEntry {
    var kept: usize = 0;
    for (entries.values()) |value| {
        if (value.conflicted or value.staged != .unmodified or value.unstaged != .unmodified) kept += 1;
    }
    var out = try arena.alloc(StatusEntry, kept);
    var i: usize = 0;
    for (entries.values()) |value| {
        if (!(value.conflicted or value.staged != .unmodified or value.unstaged != .unmodified)) continue;
        out[i] = value;
        if (out[i].submodule == null) {
            const in_head = if (head_paths.get(value.path)) |e| e.mode == .gitlink else false;
            const in_index = if (index.find(value.path)) |e| e.mode == .gitlink else false;
            if (in_head or in_index) out[i].submodule = .{};
        }
        i += 1;
    }
    assert(i == kept);
    std.mem.sort(StatusEntry, out, {}, lessThanStatus);
    return out;
}

/// HEAD's side of one index path: what `status` calls a staged change.
/// Every directory the cache tree holds valid, by path, with its tree.
fn validTrees(arena: Allocator, node: *const index_mod.CacheTreeNode, path: []const u8, out: *std.StringHashMapUnmanaged(Oid)) Allocator.Error!void {
    if (node.isValid()) try out.put(arena, path, node.oid.?);
    for (node.children.items) |*child| {
        const sub = if (path.len == 0) child.name else try arena.print("{s}/{s}", .{ path, child.name });
        try validTrees(arena, child, sub, out);
    }
}

/// HEAD's tree flattened, as `flattenTree`, but a directory whose tree the
/// index's cache tree names as its own is not descended into: it is
/// recorded in `unchanged`, nothing under it being staged.
fn flattenStaged(
    arena: Allocator,
    io: Io,
    db: *Odb,
    tree_oid: Oid,
    prefix: []const u8,
    out: *std.StringHashMapUnmanaged(TreeEntry),
    depth: u32,
    same: *const std.StringHashMapUnmanaged(Oid),
    cached: *const std.StringHashMapUnmanaged(Oid),
    unchanged: *std.StringHashMapUnmanaged(void),
) Error!void {
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.UnsupportedEntry;
    const tree: object.Tree = .parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try arena.print("{s}/{s}", .{ prefix, entry.name });
        if (entry.mode == .tree) {
            if (same.get(path)) |oid| {
                if (oid.eql(entry.oid)) continue;
            }
            if (cached.get(path)) |oid| {
                if (oid.eql(entry.oid)) {
                    try unchanged.put(arena, path, {});
                    continue;
                }
            }
            try flattenStaged(arena, io, db, entry.oid, path, out, depth + 1, same, cached, unchanged);
            continue;
        }
        try out.put(arena, path, .{ .mode = entry.mode, .oid = entry.oid });
    }
}

/// Whether `path` lies under a directory in `dirs` ("" is the root).
fn underAny(dirs: *const std.StringHashMapUnmanaged(void), path: []const u8) bool {
    if (dirs.count() == 0) return false;
    if (dirs.contains("")) return true;
    var end: usize = 0;
    while (std.mem.findScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
        if (dirs.contains(path[0..slash])) return true;
    }
    return false;
}

fn compareToHead(head_paths: *const std.StringHashMapUnmanaged(TreeEntry), path: []const u8, mode: object.Mode, oid: Oid) Change {
    const in_head = head_paths.get(path) orelse return .added;
    if (!in_head.oid.eql(oid)) return .modified;
    if (in_head.mode != mode) return if (in_head.mode.isBlob() == mode.isBlob()) .modified else .type_changed;
    return .unmodified;
}

/// The tree at the directory `dir` of `root`, or `null` where there is
/// none.
fn treeAt(io: Io, db: *Odb, root: Oid, dir: []const u8) Error!?Oid {
    var current = root;
    var parts = std.mem.splitScalar(u8, dir, '/');
    while (parts.next()) |name| {
        const found = try db.read(io, current);
        defer db.allocator().free(found.bytes);
        if (found.type != .tree) return null;
        const tree: object.Tree = .parse(db.objectFormat(), found.bytes);
        const entry = (try tree.find(name)) orelse return null;
        if (entry.mode != .tree) return null;
        current = entry.oid;
    }
    return current;
}

fn lessThanStatus(_: void, a: StatusEntry, b: StatusEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const StatusScan = struct {
    gpa: Allocator,
    conv: *convert.Session,
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    options: StatusOptions,
    entries: *std.array_hash_map.String(StatusEntry),
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Whether the file monitor was asked, so `Entry.fsmonitor_valid` holds.
    monitored: bool = false,
    /// The files of the sparse directories the walk has met on the disk,
    /// which a full index would hold with `skip-worktree` set. In `arena`.
    sparse_files: std.StringHashMapUnmanaged(TreeEntry) = .empty,
    /// The sparse directories whose files are in `sparse_files`.
    sparse_loaded: std.StringHashMapUnmanaged(void) = .empty,

    /// Whether `path`, which no index entry names, is a file of a sparse
    /// directory, and so tracked and out of the working tree.
    fn inSparseDirectory(s: *StatusScan, path: []const u8) Error!bool {
        const dir_entry = sparse_index.containing(s.index, path) orelse return false;
        if (!s.sparse_loaded.contains(dir_entry.path)) {
            try s.sparse_loaded.put(s.arena, dir_entry.path, {});
            try flattenTree(s.arena, s.io, s.db, dir_entry.oid, dir_entry.path[0 .. dir_entry.path.len - 1], &s.sparse_files, 1, null);
        }
        return s.sparse_files.contains(path);
    }

    fn walk(s: *StatusScan, dir_path: []const u8, depth: u32) Error!void {
        if (depth > 64) return error.TreeTooDeep;
        const dir = (try openWalkDirectory(s.io, s.wt, dir_path)) orelse return;
        defer if (dir_path.len != 0) dir.close(s.io);

        if (s.options.rules.ignore) |rules| try rules.addDirectory(s.io, s.wt, dir_path, depth);
        defer if (s.options.rules.ignore) |rules| rules.popTo(depth + 2);
        if (s.options.rules.attrs) |attrs| try attrs.addDirectory(s.io, s.wt, dir_path, depth);
        defer if (s.options.rules.attrs) |attrs| attrs.popTo(depth + 1);

        var scan = try dir_scan.Scan.init(s.gpa, s.io, dir, .{ .precompose = s.options.rules.precompose_unicode });

        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            const path = if (dir_path.len == 0)
                try s.arena.dupe(u8, item.name)
            else
                try s.arena.print("{s}/{s}", .{ dir_path, item.name });

            const found = item.entry;
            if (found.kind == .directory) {
                if (s.index.find(path)) |entry| {
                    if (entry.mode == .gitlink) {
                        try s.seen.put(s.gpa, entry.path, {});
                        try s.inspectGitlink(entry, path);
                        continue;
                    }
                }
                // A directory the index has files under is walked, whatever
                // it holds; git descends into it too.
                if (s.index.hasDirectory(path)) {
                    try s.walk(path, depth + 1);
                    continue;
                }
                if (s.options.untracked == .no) continue;
                const as_directory = try s.arena.print("{s}/", .{path});
                if (s.excluded(path, true)) {
                    if (s.options.include_ignored) try s.ignoredDirectory(path, as_directory, depth);
                    continue;
                }
                if (try gitlink.isRepository(s.gpa, s.io, s.wt, path)) {
                    try s.record(as_directory, .untracked);
                    continue;
                }
                if (s.options.untracked == .normal) {
                    try s.untrackedDirectory(path, as_directory, depth);
                    continue;
                }
                try s.walk(path, depth + 1);
                continue;
            }

            const tracked = s.index.find(path);
            if (tracked == null) {
                // Tracked, in a sparse directory, and out of the working
                // tree whatever the disk says: what a full index says of a
                // `skip-worktree` entry.
                if (try s.inSparseDirectory(path)) continue;
                if (s.options.untracked == .no) continue;
                if (s.excluded(path, false)) {
                    if (s.options.include_ignored) try s.record(path, .ignored);
                    continue;
                }
                try s.record(path, .untracked);
                continue;
            }
            const entry_ptr = tracked.?;
            try s.seen.put(s.gpa, entry_ptr.path, {});
            if (entry_ptr.skip_worktree or entry_ptr.assume_valid) continue;
            if (s.monitored and entry_ptr.fsmonitor_valid) continue;

            const change = try s.compare(entry_ptr, path, found);
            if (change != .unmodified) try s.recordFound(entry_ptr, path, found, change) else s.vouch(entry_ptr);
        }
    }

    /// A file found as the index has it is vouched for from now on, as git's
    /// refresh marks it.
    fn vouch(s: *StatusScan, entry: *index_mod.Entry) void {
        if (!s.monitored or entry.mode == .gitlink or entry.fsmonitor_valid) return;
        entry.fsmonitor_valid = true;
        s.index.fsmonitor_changed = true;
    }

    /// The tracked files the monitor does not vouch for, one by one, with
    /// no directory read: what `git status -uno` does with a monitor.
    fn checkEntries(s: *StatusScan) Error!void {
        var not_directories: std.StringHashMapUnmanaged(void) = .empty;
        for (s.index.entries.items) |*entry| {
            if (entry.stage != 0 or entry.skip_worktree or entry.isSparseDirectory()) continue;
            if (entry.assume_valid or entry.fsmonitor_valid) {
                try s.seen.put(s.gpa, entry.path, {});
                continue;
            }
            // Behind a symlink or a file is not in the working tree at all,
            // as the walk finds it.
            if (try s.behindNonDirectory(entry.path, &not_directories)) continue;
            const found = (try fs.statAt(s.io, s.wt, entry.path)) orelse continue;
            if (found.kind == .directory) {
                if (entry.mode != .gitlink) continue;
                try s.seen.put(s.gpa, entry.path, {});
                try s.inspectGitlink(entry, entry.path);
                continue;
            }
            try s.seen.put(s.gpa, entry.path, {});
            if (s.options.rules.attrs) |attrs| try attrs.enter(s.io, s.wt, entry.path);
            const change = try s.compare(entry, entry.path, found);
            if (change != .unmodified) try s.recordFound(entry, entry.path, found, change) else s.vouch(entry);
        }
    }

    /// Whether a directory above `path` is a symlink, a file or missing.
    fn behindNonDirectory(s: *StatusScan, path: []const u8, known: *std.StringHashMapUnmanaged(void)) Error!bool {
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
            const dir = path[0..slash];
            if (known.contains(dir)) return true;
            const found = try fs.statAt(s.io, s.wt, dir);
            if (found == null or found.?.kind != .directory) {
                try known.put(s.arena, dir, {});
                return true;
            }
        }
        return false;
    }

    fn excluded(s: *const StatusScan, path: []const u8, is_dir: bool) bool {
        const rules = s.options.rules.ignore orelse return false;
        return rules.match(path, if (is_dir) .dir else .file).excluded;
    }

    /// An ignored directory the index has nothing under. Under `normal` it
    /// is one entry, when it holds anything at all; under `all` each file
    /// in it is, though a repository in it is still one.
    fn ignoredDirectory(s: *StatusScan, path: []const u8, as_directory: []const u8, depth: u32) Error!void {
        if (try gitlink.isRepository(s.gpa, s.io, s.wt, path)) return s.record(as_directory, .ignored);
        if (s.options.untracked == .normal) {
            if (try s.holdsAnything(path, depth + 1)) try s.record(as_directory, .ignored);
            return;
        }
        var names = try s.readNames(path);
        defer names.deinit(s.gpa);
        for (names.items) |item| {
            const child = try s.arena.print("{s}/{s}", .{ path, item.name });
            if (item.kind == .directory) {
                try s.ignoredDirectory(child, try s.arena.print("{s}/", .{child}), depth + 1);
            } else if (item.kind == .file or item.kind == .sym_link) {
                try s.record(child, .ignored);
            }
        }
    }

    /// An untracked directory under `normal`: one entry, `dir/`, when
    /// anything in it is untracked, with the ignored paths inside listed
    /// beside it when they are asked for; one ignored entry when all it
    /// holds is ignored; nothing when it holds nothing.
    fn untrackedDirectory(s: *StatusScan, path: []const u8, as_directory: []const u8, depth: u32) Error!void {
        var ignored: std.ArrayList([]const u8) = .empty;
        defer ignored.deinit(s.gpa);
        if (try s.classify(path, depth + 1, &ignored)) {
            try s.record(as_directory, .untracked);
            if (s.options.include_ignored) {
                for (ignored.items) |p| try s.record(p, .ignored);
            }
        } else if (ignored.items.len != 0 and s.options.include_ignored) {
            try s.record(as_directory, .ignored);
        }
    }

    /// Whether anything in the untracked directory `path` is untracked,
    /// gathering into `ignored` the ignored paths in it the way git's
    /// `normal` listing names them: a file, or a directory that holds
    /// nothing but ignored paths, by its name. A repository inside counts
    /// as untracked content, whatever it holds, and is not looked into.
    fn classify(s: *StatusScan, path: []const u8, depth: u32, ignored: *std.ArrayList([]const u8)) Error!bool {
        if (depth > 64) return error.TreeTooDeep;
        if (s.options.rules.ignore) |rules| try rules.addDirectory(s.io, s.wt, path, depth);
        defer if (s.options.rules.ignore) |rules| rules.popTo(depth + 2);

        var names = try s.readNames(path);
        defer names.deinit(s.gpa);
        var untracked = false;
        for (names.items) |item| {
            const child = try s.arena.print("{s}/{s}", .{ path, item.name });
            if (item.kind == .directory) {
                const as_directory = try s.arena.print("{s}/", .{child});
                if (s.excluded(child, true)) {
                    if (!s.options.include_ignored) continue;
                    if (try gitlink.isRepository(s.gpa, s.io, s.wt, child) or try s.holdsAnything(child, depth + 1)) {
                        try ignored.append(s.gpa, as_directory);
                    }
                    continue;
                }
                if (try gitlink.isRepository(s.gpa, s.io, s.wt, child)) {
                    untracked = true;
                } else {
                    const mark = ignored.items.len;
                    if (try s.classify(child, depth + 1, ignored)) {
                        untracked = true;
                    } else if (ignored.items.len != mark) {
                        ignored.shrinkRetainingCapacity(mark);
                        try ignored.append(s.gpa, as_directory);
                    }
                }
            } else if (item.kind == .file or item.kind == .sym_link) {
                if (s.excluded(child, false)) {
                    if (s.options.include_ignored) try ignored.append(s.gpa, child);
                } else {
                    untracked = true;
                }
            }
            // Nothing more can change the answer when the ignored paths
            // are not wanted.
            if (untracked and !s.options.include_ignored) return true;
        }
        return untracked;
    }

    /// Whether `path` holds a file, or a repository, anywhere below it: an
    /// ignored directory that holds nothing is not listed.
    fn holdsAnything(s: *StatusScan, path: []const u8, depth: u32) Error!bool {
        if (depth > 64) return error.TreeTooDeep;
        var names = try s.readNames(path);
        defer names.deinit(s.gpa);
        for (names.items) |item| {
            if (item.kind == .file or item.kind == .sym_link) return true;
            if (item.kind != .directory) continue;
            const child = try s.arena.print("{s}/{s}", .{ path, item.name });
            if (try gitlink.isRepository(s.gpa, s.io, s.wt, child)) return true;
            if (try s.holdsAnything(child, depth + 1)) return true;
        }
        return false;
    }

    const Name = struct { name: []const u8, kind: Io.File.Kind };

    /// The entries of `path` other than `.git`, their names in the arena.
    /// Read whole before any is looked at, so no directory handle is held
    /// open across the recursion.
    fn readNames(s: *StatusScan, path: []const u8) Error!std.ArrayList(Name) {
        var out: std.ArrayList(Name) = .empty;
        errdefer out.deinit(s.gpa);
        const dir = (try openWalkDirectory(s.io, s.wt, path)) orelse return out;
        defer if (path.len != 0) dir.close(s.io);
        var scan = try dir_scan.Scan.init(s.gpa, s.io, dir, .{ .precompose = s.options.rules.precompose_unicode });

        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            try out.append(s.gpa, .{ .name = try s.arena.dupe(u8, item.name), .kind = item.entry.kind });
        }
        return out;
    }

    fn compare(s: *StatusScan, entry: *index_mod.Entry, path: []const u8, found: fs.Entry) Error!Change {
        // An intent to add is the file added, whatever it holds: git's
        // `run_diff_files` under `ita_invisible_in_index`.
        if (entry.intent_to_add) return .added;
        const mode = modeOnDisk(found, entry.mode, s.options.rules);

        if (entry.mode.isBlob() != mode.isBlob() or
            (entry.mode == .symlink) != (mode == .symlink))
        {
            return .type_changed;
        }
        if (entry.mode != mode) return .modified;
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        return if (try s.trackedFiles().sameContent(scratch.allocator(), entry.*, path, found)) .unmodified else .modified;
    }

    fn trackedFiles(s: *StatusScan) Tracked {
        return .{ .io = s.io, .wt = s.wt, .index = s.index, .db = s.db, .conv = s.conv, .rules = s.options.rules };
    }

    /// Record a tracked file's change, and for a file added under an intent
    /// to add, when `StatusOptions.added_content` asks, what it holds.
    fn recordFound(s: *StatusScan, entry: *const index_mod.Entry, path: []const u8, found: fs.Entry, change: Change) Error!void {
        try s.record(path, change);
        if (change != .added or !s.options.added_content) return;
        const bytes = try s.trackedFiles().storedBytes(s.arena, path, found);
        s.entries.getPtr(path).?.added = .{
            .mode = modeOnDisk(found, entry.mode, s.options.rules),
            .oid = hash.Hasher.object(s.db.objectFormat(), "blob", bytes),
            .bytes = bytes,
        };
    }

    /// A gitlink's directory is never walked. Its state is the probe's
    /// answer, or without one its `HEAD` against the recorded commit.
    fn inspectGitlink(s: *StatusScan, entry: *index_mod.Entry, path: []const u8) Error!void {
        if (entry.skip_worktree) return;
        const state: SubmoduleState = if (s.options.submodules) |probe|
            try probe.inspect(s.io, path, entry.oid)
        else blk: {
            const checked_out = try gitlink.head(s.gpa, s.io, s.wt, path);
            break :blk .{ .new_commits = checked_out != null and !checked_out.?.eql(entry.oid) };
        };
        if (state.isClean()) return;
        try s.record(path, .modified);
        s.entries.getPtr(path).?.submodule = state;
    }

    fn record(s: *StatusScan, path: []const u8, change: Change) Error!void {
        const slot = try s.entries.getOrPut(s.arena, path);
        if (!slot.found_existing) {
            slot.value_ptr.* = .{ .path = slot.key_ptr.*, .staged = .unmodified, .unstaged = .unmodified };
        }
        slot.value_ptr.unstaged = change;
    }
};

/// One flattened tree entry.
/// One flattened tree entry: a path's mode and object.
pub const TreeEntry = struct { mode: object.Mode, oid: Oid };

fn flattenTree(
    arena: Allocator,
    io: Io,
    db: *Odb,
    tree_oid: Oid,
    prefix: []const u8,
    out: *std.StringHashMapUnmanaged(TreeEntry),
    depth: u32,
    same: ?*const std.StringHashMapUnmanaged(Oid),
) Error!void {
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.UnsupportedEntry;
    const tree: object.Tree = .parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try arena.print("{s}/{s}", .{ prefix, entry.name });
        if (entry.mode == .tree) {
            // A subtree a sparse directory already names, unchanged, has
            // nothing in it to compare.
            if (same) |dirs| {
                if (dirs.get(path)) |oid| {
                    if (oid.eql(entry.oid)) continue;
                }
            }
            try flattenTree(arena, io, db, entry.oid, path, out, depth + 1, same);
            continue;
        }
        try out.put(arena, path, .{ .mode = entry.mode, .oid = entry.oid });
    }
}

/// Every path a tree holds, flattened, as the caller's map from path to
/// mode and object name.
///
/// The map and its keys come from `arena`, so a caller frees them by
/// resetting it.
pub fn flatten(
    arena: Allocator,
    io: Io,
    db: *Odb,
    tree_oid: Oid,
) Self.Error!std.StringHashMapUnmanaged(TreeEntry) {
    var out: std.StringHashMapUnmanaged(TreeEntry) = .empty;
    try flattenTree(arena, io, db, tree_oid, "", &out, 0, null);
    return out;
}

/// What `resetIndex` changed.
pub const ResetOutcome = struct {
    /// Entries whose object name or mode came from the tree.
    updated: u32 = 0,
    /// Entries the tree does not have, which left the index.
    removed: u32 = 0,
    /// Entries that were already what the tree says.
    unchanged: u32 = 0,
};

/// Make the index describe `tree`, and leave the working tree alone.
///
/// This is `git reset` with no paths and no `--hard`: what is staged goes
/// back to what the commit says, and the files on the disk are not touched.
/// An entry that keeps its object name and mode keeps its cached stat too,
/// so the next `addAll` still takes the stat shortcut over it.
pub fn resetIndex(
    gpa: Allocator,
    io: Io,
    index: *Index,
    db: *Odb,
    tree_oid: Oid,
) Self.Error!ResetOutcome {
    var outcome: ResetOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // The tree is compared path by path, so a sparse index is made full
    // first; a caller that wants it sparse again collapses it.
    try sparse_index.expand(gpa, io, index, db, null);
    var wanted = try flatten(arena, io, db, tree_oid);

    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(gpa);
    for (index.entries.items) |entry| {
        if (entry.stage != 0) {
            // A conflict's stages are not part of any tree; a reset drops
            // them, which is what makes the result clean.
            try gone.append(gpa, entry.path);
            continue;
        }
        if (!wanted.contains(entry.path)) try gone.append(gpa, entry.path);
    }
    outcome.removed = @intCast(gone.items.len);
    index.removeMany(gone.items);

    var fresh: std.ArrayList(index_mod.Entry) = .empty;
    defer fresh.deinit(gpa);
    var it = wanted.iterator();
    while (it.next()) |pair| {
        const path = pair.key_ptr.*;
        const want = pair.value_ptr.*;
        if (index.find(path)) |entry| {
            if (entry.oid.eql(want.oid) and entry.mode == want.mode) {
                outcome.unchanged += 1;
                continue;
            }
            entry.oid = want.oid;
            entry.mode = want.mode;
            // The file on the disk is untouched and no longer matches, so
            // neither the cached stat nor the monitor's word for it may be
            // trusted against it.
            entry.stat = .none;
            entry.fsmonitor_valid = false;
            entry.intent_to_add = false;
            outcome.updated += 1;
            continue;
        }
        try fresh.append(gpa, .{
            .path = try arena.dupe(u8, path),
            .oid = want.oid,
            .mode = want.mode,
            .stat = .none,
        });
        outcome.updated += 1;
    }
    try index.addMany(fresh.items);

    try describeTree(index, tree_oid);
    return outcome;
}

/// What `checkout` did.
pub const CheckoutOutcome = struct {
    written: u32 = 0,
    removed: u32 = 0,
    unchanged: u32 = 0,
    /// Symlinks written as ordinary files holding their target, because the
    /// platform or `core.symlinks` refuses a real one.
    symlinks_as_files: u32 = 0,
    /// Gitlinks: a directory is made and nothing is put in it, because the
    /// submodule's own repository is the caller's business.
    gitlinks: u32 = 0,
    /// Native content written using its provider fallback.
    /// `CheckoutOptions.filter_report` names the unavailable objects.
    native_fallbacks: u32 = 0,
};

/// Where a refusal is written, so `error.UnsafePath` can say which path and
/// which rule without allocating.
pub const Refusal = struct {
    reason: ?safe_path.Reason = null,
    buffer: [512]u8 = undefined,
    len: usize = 0,

    /// The path that was refused. Empty when nothing was.
    pub fn path(r: *const Refusal) []const u8 {
        return r.buffer[0..r.len];
    }

    fn set(r: *Refusal, reason: ?safe_path.Reason, text: []const u8) void {
        r.reason = reason;
        r.len = @min(text.len, r.buffer.len);
        @memcpy(r.buffer[0..r.len], text[0..r.len]);
    }
};

/// How `checkout` behaves.
pub const CheckoutOptions = struct {
    /// Durable mode syncs selected file bytes, then all affected directories,
    /// before success. Off by default; this costs opens and storage barriers.
    durability: fs.Durability = .none,
    rules: Rules = .{},
    /// `true` is `read-tree --reset -u`: rewrite files with changes of
    /// their own and replace untracked files where the tree puts one. The
    /// default is `read-tree -m -u`, as `git checkout` is: a checkout that
    /// would lose either is refused before anything is touched, with every
    /// such path in `obstructions`, and a file the tree does not change
    /// keeps its local changes. A caller that means to discard work says so.
    force: bool = false,
    /// Where a refusal lists the paths that caused it.
    obstructions: ?*Obstructions = null,
    /// Ignore rules for the root, for telling an ignored file in the way,
    /// which is replaced as git replaces it, from an untracked one, which
    /// is not. The `.gitignore` files further down are read into it as
    /// needed. Without it every file in the way counts as untracked.
    ignore: ?*ignore.Rules = null,
    /// Whether to remove a directory once the last file in it is removed.
    remove_empty_directories: bool = true,
    /// Where to write the path and the rule when a tree entry is refused.
    refusal: ?*Refusal = null,
    /// The permission to run the smudge filters `rules.filters` names.
    programs: ?program.Programs = null,
    /// Where filters passed over, and LFS files left as pointers, are
    /// reported.
    filter_report: ?*filter.Report = null,
    /// How many tasks of the caller's `Io` write the files, as git's
    /// `checkout.workers`; zero is four, or the processors there are when
    /// fewer. The files written, the index and the error returned are the
    /// same whatever the count.
    workers: usize = 0,
};

/// `read-tree --reset -u`: make the working tree and the index match `tree`.
///
/// Files the index has and the tree does not are removed; files whose
/// content or mode differ are rewritten; untracked and ignored files are
/// left exactly as they are. Nothing about `HEAD` moves: a caller that wants
/// a branch moved does that with a ref transaction, which is a separate
/// decision from what is on the disk.
///
/// The `.gitattributes` files the tree carries are the ones the files are
/// written by, for as long as the call lasts, as they are in git: a
/// checkout into an empty directory has no other copy of them. A file a
/// filter hands over late, or whose LFS object has to be fetched, is
/// written after all the others.
pub fn checkout(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: CheckoutInputs,
    options: CheckoutOptions,
) Self.Error!CheckoutOutcome {
    const index = inputs.index;
    const db = inputs.db;
    const tree_oid = inputs.tree;
    var outcome: CheckoutOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // Every path of the tree is written, so a sparse index is made full
    // first, which is what this leaves behind anyway.
    try sparse_index.expand(gpa, io, index, db, null);
    var wanted = try flatten(arena, io, db, tree_oid);

    const attrs_before = if (options.rules.attrs) |attrs| attrs.checkpoint() else null;
    defer if (options.rules.attrs) |attrs| attrs.restore(attrs_before.?);
    if (options.rules.attrs) |attrs| try addTreeAttributes(arena, io, db, attrs, &wanted);

    var conv: convert.Session = .open(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
    });
    defer conv.deinit(io);

    try refuseUnsafeTree(arena, &wanted, options);
    if (!options.force) {
        try verifyCheckout(gpa, arena, io, wt, index, &wanted, options);
    } else if (options.rules.submodules) |mover| {
        const updates = try checkoutUpdates(arena, index, &wanted);
        try verifySubmoduleMoves(gpa, io, wt, .{ .index = index, .updates = &updates }, .{
            .mover = mover,
            .force = true,
            .obstructions = options.obstructions,
        });
    }
    try refuseDirectoriesInTheWay(arena, io, wt, index, &wanted, options.force, options.rules.precompose_unicode);
    var removed_dirs = try removeUnwanted(arena, io, wt, index, &wanted, options.rules, &outcome);

    // Write what the tree has, in path order.
    var paths = try arena.alloc([]const u8, wanted.count());
    var n: usize = 0;
    var key_it = wanted.keyIterator();
    while (key_it.next()) |key| {
        paths[n] = key.*;
        n += 1;
    }
    assert(n == paths.len);
    std.mem.sort([]const u8, paths, {}, lessThanName);
    if (options.rules.submodules != null) gitmodulesFirst(paths);
    try removeEmptiedDirectories(io, wt, index, paths, &wanted, options.force);

    var writing: CheckoutWrite = .{
        .gpa = gpa,
        .io = io,
        .wt = wt,
        .index = index,
        .db = db,
        .conv = &conv,
        .tree_oid = tree_oid,
        .wanted = &wanted,
        .options = options,
        .outcome = &outcome,
    };
    try writing.all(paths);
    try writing.late();
    outcome.native_fallbacks = conv.fallbackCount();

    if (options.remove_empty_directories) {
        var dir_it = removed_dirs.keyIterator();
        while (dir_it.next()) |dir_path| {
            removeEmptyDirectories(io, wt, dir_path.*);
        }
    }

    if (options.durability == .durable) try syncCheckout(arena, io, wt, &wanted, &removed_dirs);

    try describeTree(index, tree_oid);
    return outcome;
}

/// The tree the index now describes is exactly `tree_oid`, so the cache
/// tree is told so rather than rebuilt; and, as git's `unpack_trees` leaves
/// it, the index remembers no resolutions.
fn describeTree(index: *Index, tree_oid: Oid) Allocator.Error!void {
    const tree = try index.cacheTree();
    tree.invalidateAll();
    tree.root.entry_count = @intCast(index.entries.items.len);
    tree.root.oid = tree_oid;
    index.dropResolveUndo();
}

/// Every path out of the tree is checked before it becomes a filesystem
/// path. A tree is a file format and anyone may write one.
fn refuseUnsafeTree(arena: Allocator, wanted: *std.StringHashMapUnmanaged(TreeEntry), options: CheckoutOptions) Error!void {
    var check_it = wanted.iterator();
    while (check_it.next()) |entry| {
        const path = entry.key_ptr.*;
        if (safe_path.checkEntry(path, .worktree, entry.value_ptr.mode == .symlink, options.rules.protect)) |refused| {
            if (options.refusal) |out| out.set(refused.reason, path);
            return error.UnsafePath;
        }
    }
    if (options.rules.ignore_case) {
        try refuseCaseCollisions(arena, wanted);
    }
    try refuseCollidingPaths(arena, wanted, options.rules.ignore_case, options.refusal);
}

/// An entry standing where another entry of the tree has its directory --
/// the same name twice in one tree, or a name the filesystem folds to the
/// other's -- is refused before anything is written: written in order, a
/// link of that name would carry the files under it out of the working
/// tree. git writes no such tree; relic does not try to.
fn refuseCollidingPaths(
    arena: Allocator,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    ignore_case: bool,
    refusal: ?*Refusal,
) Error!void {
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    var it = wanted.keyIterator();
    while (it.next()) |key| {
        const path = if (ignore_case) try std.ascii.allocLowerString(arena, key.*) else key.*;
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
            try dirs.put(arena, path[0..slash], {});
        }
    }
    it = wanted.keyIterator();
    while (it.next()) |key| {
        const path = if (ignore_case) try std.ascii.allocLowerString(arena, key.*) else key.*;
        if (dirs.contains(path)) {
            if (refusal) |out| out.set(.path_collision, key.*);
            return error.UnsafePath;
        }
    }
}

/// Each path a checkout of `wanted` changes in `index`, to what the tree
/// has there, `null` where it has nothing.
fn checkoutUpdates(
    arena: Allocator,
    index: *const Index,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
) Allocator.Error!std.array_hash_map.String(?TreeEntry) {
    var updates: std.array_hash_map.String(?TreeEntry) = .empty;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) continue;
        const want = wanted.get(entry.path);
        if (want != null and want.?.mode == entry.mode and want.?.oid.eql(entry.oid)) continue;
        try updates.put(arena, entry.path, want);
    }
    var want_it = wanted.iterator();
    while (want_it.next()) |item| {
        if (index.find(item.key_ptr.*) != null) continue;
        try updates.put(arena, item.key_ptr.*, item.value_ptr.*);
    }
    return updates;
}

/// Without `force`, refuse a checkout that would lose work: every path the
/// tree changes, against what is on the disk.
fn verifyCheckout(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    options: CheckoutOptions,
) Error!void {
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnmergedIndex;
    }
    const updates = try checkoutUpdates(arena, index, wanted);
    try verifyUpdates(gpa, io, wt, .{ .index = index, .updates = &updates }, .{
        .rules = options.rules,
        .ignore = options.ignore,
        .obstructions = options.obstructions,
    });
}

/// A directory-to-file transition is safe only when everything below the
/// directory is tracked and is about to leave the index. Prove that before
/// deleting any old entry, so an untracked file cannot turn a checkout
/// failure into a partially deleted working tree.
fn refuseDirectoriesInTheWay(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *const Index,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    force: bool,
    precompose: bool,
) Error!void {
    var conflict_it = wanted.iterator();
    while (conflict_it.next()) |item| {
        if (item.value_ptr.mode == .gitlink) continue;
        if (keeps(index, item.key_ptr.*, item.value_ptr.*, force)) continue;
        if (try fs.statAt(io, wt, item.key_ptr.*)) |found| {
            if (found.kind == .directory and
                !try directoryIsReplaceable(arena, io, wt, item.key_ptr.*, index, wanted, precompose))
            {
                return error.UntrackedWouldBeOverwritten;
            }
        }
    }
}

/// Remove what the index has and the tree does not, from both. The
/// directories they were in are returned, for removing once empty.
fn removeUnwanted(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    rules: Rules,
    outcome: *CheckoutOutcome,
) Error!std.StringHashMapUnmanaged(void) {
    var removed_dirs: std.StringHashMapUnmanaged(void) = .empty;
    var leading: LeadingDirs = .{};
    var i: usize = 0;
    while (i < index.entries.items.len) {
        const entry = index.entries.items[i];
        if (entry.stage != 0) {
            i += 1;
            continue;
        }
        if (wanted.contains(entry.path)) {
            i += 1;
            continue;
        }
        if (!try leading.real(io, wt, std.Io.Dir.path.dirnamePosix(entry.path) orelse "")) {
            // Past a symbolic link: nothing of the working tree's to remove.
        } else if (entry.mode == .gitlink) {
            try removeGitlink(io, wt, entry.path, rules);
        } else fs.deleteFile(io, wt, entry.path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => {},
            else => |e| return e,
        };
        if (std.Io.Dir.path.dirnamePosix(entry.path)) |parent| {
            try removed_dirs.put(arena, try arena.dupe(u8, parent), {});
        }
        const tree = try index.cacheTree();
        tree.invalidate(entry.path);
        _ = index.remove(entry.path);
        outcome.removed += 1;
    }
    return removed_dirs;
}

/// Tracked children have now gone. Remove the empty directories they
/// occupied before attempting the atomic file replacements. A path the
/// checkout keeps as it is needs no look at the disk.
fn removeEmptiedDirectories(
    io: Io,
    wt: Io.Dir,
    index: *const Index,
    paths: []const []const u8,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    force: bool,
) Error!void {
    var leading: LeadingDirs = .{};
    for (paths) |path| {
        const want = wanted.get(path).?;
        if (want.mode == .gitlink) continue;
        if (keeps(index, path, want, force)) continue;
        if (!try leading.real(io, wt, std.Io.Dir.path.dirnamePosix(path) orelse "")) continue;
        if (try fs.statAt(io, wt, path)) |found| {
            if (found.kind == .directory) try wt.deleteDir(io, path);
        }
    }
}

const gitmodules_path = ".gitmodules";

/// Put `.gitmodules` first in the sorted `paths`, when it is there: git
/// checks it out before anything else when it moves submodules
/// (`load_gitmodules_file`), so every move reads the names the new one
/// gives.
pub fn gitmodulesFirst(paths: [][]const u8) void {
    for (paths, 0..) |path, i| {
        if (!std.mem.eql(u8, path, gitmodules_path)) continue;
        std.mem.rotate([]const u8, paths[0 .. i + 1], i);
        return;
    }
}

/// What `checkout` writes the tree's paths with.
const CheckoutWrite = struct {
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    conv: *convert.Session,
    tree_oid: Oid,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    options: CheckoutOptions,
    outcome: *CheckoutOutcome,

    /// Write `paths`, sorted. Regular files are written on tasks, a batch
    /// at a time; everything else, and everything a batch needs first,
    /// here and in order.
    fn all(c: *const CheckoutWrite, paths: []const []const u8) Error!void {
        var batch: WriteBatch = .{ .gpa = c.gpa, .workers = checkoutWorkers(c.options.workers) };
        defer batch.deinit();
        // A path that fails here leaves every path before it written, as a
        // checkout one file at a time leaves them.
        // glint-ignore: Z026 -- the path's own error is the one returned; flushing only keeps the paths before it written
        errdefer batch.flush(c.io, c.wt, c.index, c.outcome, c.options.rules) catch {};
        var leading: LeadingDirs = .{ .hide = c.options.rules.hide_dot_files };
        for (paths) |path| {
            const want = c.wanted.get(path).?;
            if (try c.unchanged(path, want)) {
                c.outcome.unchanged += 1;
                continue;
            }
            if (std.Io.Dir.path.dirnamePosix(path)) |parent| {
                try leading.make(c.io, c.wt, parent, c.options.force, c.options.refusal);
            }
            try c.one(&batch, &leading, path, want);
            if (c.options.rules.submodules != null and std.mem.eql(u8, path, gitmodules_path)) try batch.flush(c.io, c.wt, c.index, c.outcome, c.options.rules);
        }
        try batch.flush(c.io, c.wt, c.index, c.outcome, c.options.rules);
    }

    /// Whether `path` is left as it is: kept with its local changes, or,
    /// with `force`, a file whose stat says it is the one the index has.
    fn unchanged(c: *const CheckoutWrite, path: []const u8, want: TreeEntry) Error!bool {
        if (keeps(c.index, path, want, c.options.force)) return true;
        // A forced checkout moves every submodule to its commit, as git's
        // `oneway_merge` updates every gitlink under `--recurse-submodules`.
        if (want.mode == .gitlink and c.options.rules.submodules != null) return false;
        const entry = c.index.find(path) orelse return false;
        if (!entry.oid.eql(want.oid) or entry.mode != want.mode or c.index.isRacy(entry.*)) return false;
        const on_disk = try fs.statAt(c.io, c.wt, path) orelse return false;
        return entry.stat.matches(on_disk.stat, c.options.rules.statCompare());
    }

    /// Write one path, or hand a regular file to `batch`, or leave one a
    /// filter delays for `late`.
    fn one(c: *const CheckoutWrite, batch: *WriteBatch, leading: *LeadingDirs, path: []const u8, want: TreeEntry) Error!void {
        switch (want.mode) {
            .gitlink => {
                try writeGitlink(c.gpa, c.io, c.wt, leading, .{ .path = path, .oid = want.oid, .rules = c.options.rules, .force = c.options.force, .refusal = c.options.refusal });
                c.outcome.gitlinks += 1;
            },
            .symlink => {
                const found = try c.db.read(c.io, want.oid);
                defer c.gpa.free(found.bytes);
                if (try writeLink(c.io, c.wt, path, found.bytes, c.options.rules.symlinks)) c.outcome.symlinks_as_files += 1;
                // A link where a proved directory's name folds to it is
                // looked at again before anything is written under it.
                leading.forget();
                c.outcome.written += 1;
            },
            .file, .exec => {
                var scratch: std.heap.ArenaAllocator = .init(c.gpa);
                defer scratch.deinit();
                const a = scratch.allocator();
                const found = try c.db.read(c.io, want.oid);
                defer c.gpa.free(found.bytes);
                const executable = want.mode == .exec and c.options.rules.file_mode;
                const smudged: native.Content = if (c.options.rules.attrs) |attrs| try c.conv.toWorktree(a, .{ .path = path, .blob = found.bytes, .applied = try attrs.lookup(a, path, .file) }, .{
                    .blob = want.oid,
                    .treeish = c.tree_oid,
                    .can_delay = true,
                }) else .{ .bytes = found.bytes };
                switch (smudged) {
                    // Its index entry is added when it arrives.
                    .delayed => return,
                    .bytes => |bytes| {
                        if (try batch.add(path, want, bytes, executable)) {
                            try batch.flush(c.io, c.wt, c.index, c.outcome, c.options.rules);
                        }
                        return;
                    },
                    .file => try writeSmudged(c.io, c.wt, path, smudged, executable),
                }
                c.outcome.written += 1;
            },
            .tree => return error.UnsupportedEntry,
        }
        try recordWritten(c.io, c.wt, c.index, path, want, c.options.rules);
    }

    /// Write the files a filter delayed, as it hands them over.
    fn late(c: *const CheckoutWrite) Error!void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        while (try c.conv.nextReady(arena.allocator())) |ready| {
            defer _ = arena.reset(.retain_capacity);
            const want = c.wanted.get(ready.path).?;
            try writeSmudged(c.io, c.wt, ready.path, ready.content, want.mode == .exec and c.options.rules.file_mode);
            c.outcome.written += 1;
            try recordWritten(c.io, c.wt, c.index, ready.path, want, c.options.rules);
        }
    }
};

/// The directories above what a write puts into the working tree, as
/// git's `create_directories` and `has_symlink_leading_path` see them: each
/// is a directory on the disk, never followed through a symbolic link, so a
/// tree that writes a link and then a path under the link's name writes
/// into the working tree and nowhere else. The last directory proved is
/// remembered, as git's lstat cache remembers it, so sorted paths cost one
/// look per new directory.
const LeadingDirs = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    /// `core.hideDotFiles`, for each directory this makes.
    hide: fs.HideDotFiles = .none,

    /// Make `dir` and the directories above it. A symbolic link or a file
    /// standing as one is replaced when `force`, as git's forced checkout
    /// replaces it; otherwise a link is refused as `.beyond_symlink`, and a
    /// file is `error.NotDir`.
    fn make(l: *LeadingDirs, io: Io, wt: Io.Dir, dir: []const u8, force: bool, refusal: ?*Refusal) Error!void {
        var start = l.provenUpTo(dir);
        while (start < dir.len) {
            const end = std.mem.findScalarPos(u8, dir, start, '/') orelse dir.len;
            const sub = dir[0..end];
            if (try fs.statAt(io, wt, sub)) |found| {
                if (found.kind != .directory) {
                    if (!force) {
                        if (found.kind != .sym_link) return error.NotDir;
                        if (refusal) |out| out.set(.beyond_symlink, sub);
                        return error.UnsafePath;
                    }
                    try fs.deleteFile(io, wt, sub);
                    try wt.createDir(io, sub, .default_dir);
                    fs.hideIfAsked(io, wt, sub, l.hide);
                }
            } else if (wt.createDir(io, sub, .default_dir)) |_| {
                fs.hideIfAsked(io, wt, sub, l.hide);
            } else |err| switch (err) {
                // Made since the look by someone else: a directory is as
                // good, anything else is looked at again next time.
                error.PathAlreadyExists => {
                    const now = try fs.statAt(io, wt, sub) orelse return err;
                    if (now.kind != .directory) return error.NotDir;
                },
                else => |e| return e,
            }
            start = end + 1;
        }
        l.remember(dir);
    }

    /// Whether `dir` and every directory above it is a directory on the
    /// disk: `false` for a symbolic link or a missing one, under which
    /// nothing of the working tree's is to be removed.
    fn real(l: *LeadingDirs, io: Io, wt: Io.Dir, dir: []const u8) Error!bool {
        var start = l.provenUpTo(dir);
        while (start < dir.len) {
            const end = std.mem.findScalarPos(u8, dir, start, '/') orelse dir.len;
            const found = try fs.statAt(io, wt, dir[0..end]) orelse return false;
            if (found.kind != .directory) return false;
            start = end + 1;
        }
        l.remember(dir);
        return true;
    }

    /// Where in `dir` the components not yet proved start.
    fn provenUpTo(l: *const LeadingDirs, dir: []const u8) usize {
        const proven = l.buf[0..l.len];
        if (proven.len == 0 or !std.mem.startsWith(u8, dir, proven)) return 0;
        if (dir.len == proven.len) return dir.len;
        return if (dir[proven.len] == '/') proven.len + 1 else 0;
    }

    fn remember(l: *LeadingDirs, dir: []const u8) void {
        l.len = if (dir.len <= l.buf.len) dir.len else 0;
        @memcpy(l.buf[0..l.len], dir[0..l.len]);
    }

    /// Forget what was proved, after the disk may have changed under it.
    fn forget(l: *LeadingDirs) void {
        l.len = 0;
    }
};

/// Whether every directory above `path` is a directory on the disk, none a
/// symbolic link and none missing: git's `has_symlink_or_noent_leading_path`
/// turned around. A caller about to remove or replace `path` itself, as
/// relic's merge and patch do, removes nothing when this is `false`.
pub fn realLeadingPath(io: Io, wt: Io.Dir, path: []const u8) Self.Error!bool {
    const parent = std.Io.Dir.path.dirnamePosix(path) orelse return true;
    var leading: LeadingDirs = .{};
    return leading.real(io, wt, parent);
}

/// Make the directories above `path` for a write that replaces whatever is
/// at it, refusing a symbolic link among them.
fn makeLeadingDirs(io: Io, wt: Io.Dir, path: []const u8, hide: fs.HideDotFiles) Error!void {
    const parent = std.Io.Dir.path.dirnamePosix(path) orelse return;
    var leading: LeadingDirs = .{ .hide = hide };
    try leading.make(io, wt, parent, false, null);
}

/// Write a symlink to `target` at `path`, replacing whatever is there; or,
/// where `symlinks` is off or the platform refuses one, an ordinary file
/// holding the target. `true` when it was written as a file.
fn writeLink(io: Io, wt: Io.Dir, path: []const u8, target: []const u8, symlinks: bool) Error!bool {
    // glint-ignore: Z026 -- whatever is at the path is replaced next; a file that would not go is the error the link or the write reports
    fs.deleteFile(io, wt, path) catch {};
    if (symlinks) {
        if (wt.symLink(io, target, path, .{})) |_| return false else |_| {}
    }
    try writeFile(io, wt, path, .{ .bytes = target }, false);
    return true;
}

// Sync existing paths too: a skipped write is not evidence of durability.
// Symlink bytes live in their directory; gitlinks belong to another store.
fn syncCheckout(arena: Allocator, io: Io, wt: Io.Dir, wanted: *const std.StringHashMapUnmanaged(TreeEntry), removed: *const std.StringHashMapUnmanaged(void)) Error!void {
    var dirs: std.StringHashMap(bool) = .init(arena);
    try dirs.put(".", true);
    var files: std.ArrayList(fs.Named) = .empty;
    var paths = wanted.iterator();
    while (paths.next()) |entry| {
        const path = entry.key_ptr.*;
        if (entry.value_ptr.mode != .gitlink) {
            const st = (try fs.statAt(io, wt, path)) orelse return error.FileNotFound;
            if (st.kind == .file) try files.append(arena, .{ .dir = wt, .sub_path = path });
        }
        try addSyncParents(&dirs, path, true);
    }
    // Parents of removed files may now be absent; syncing their first
    // surviving ancestor makes the deletion durable.
    var deleted = removed.keyIterator();
    while (deleted.next()) |path| {
        const slot = try dirs.getOrPut(path.*);
        if (!slot.found_existing) slot.value_ptr.* = false;
        try addSyncParents(&dirs, path.*, false);
    }
    var directories: std.ArrayList(fs.Named) = .empty;
    var names = dirs.iterator();
    while (names.next()) |entry| {
        // A directory the checkout removed is not there to sync; one it
        // wanted is, and its absence is the error.
        if (!entry.value_ptr.*) wt.access(io, entry.key_ptr.*, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        try directories.append(arena, .{ .dir = wt, .sub_path = entry.key_ptr.* });
    }
    try fs.syncAll(arena, io, files.items, directories.items);
}

fn addSyncParents(dirs: *std.StringHashMap(bool), path: []const u8, required: bool) Allocator.Error!void {
    var parent = std.Io.Dir.path.dirnamePosix(path);
    while (parent) |p| {
        const slot = try dirs.getOrPut(p);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* or required else required;
        parent = std.Io.Dir.path.dirnamePosix(p);
    }
}

/// Whether a checkout leaves `path` exactly as it is without looking at
/// it: without `force`, a file the index already has as the tree has it
/// keeps whatever local changes it has, as git's checkout keeps them.
fn keeps(index: *const Index, path: []const u8, want: TreeEntry, force: bool) bool {
    if (force) return false;
    const entry = index.find(path) orelse return false;
    return entry.oid.eql(want.oid) and entry.mode == want.mode;
}

/// How many tasks write a checkout's files: zero is four, or fewer where
/// the machine has fewer processors. Past four, files created at once in
/// one tree cost more than they save on APFS.
fn checkoutWorkers(asked: usize) usize {
    if (asked != 0) return asked;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(cpus, 4));
}

/// Regular files to write, gathered on the calling task and written on
/// tasks of its `Io`. A batch ends by its bytes and its count alone, so
/// which files are attempted together never depends on how many tasks
/// write them; every file in a batch is attempted, each one that was
/// written goes into the index, and the error a batch returns is its
/// first file's in path order.
const WriteBatch = struct {
    gpa: Allocator,
    workers: usize,
    arena: std.heap.ArenaAllocator.State = .{},
    jobs: std.ArrayList(Job) = .empty,
    bytes: usize = 0,

    const max_bytes = 16 << 20;
    const max_files = 1024;
    /// git's `checkout.thresholdForParallelism`.
    const parallel_threshold = 100;

    comptime {
        // A full batch is one worth spreading over tasks.
        assert(parallel_threshold < max_files);
    }

    const Job = struct {
        path: []const u8,
        want: TreeEntry,
        bytes: []const u8,
        executable: bool,
        result: Error!?fs.Stat = error.Canceled,
    };

    fn deinit(b: *WriteBatch) void {
        b.jobs.deinit(b.gpa);
        var arena = b.arena.promote(b.gpa);
        arena.deinit();
        b.* = undefined;
    }

    /// Take a copy of a file to write; `true` when the batch is full.
    fn add(b: *WriteBatch, path: []const u8, want: TreeEntry, bytes: []const u8, executable: bool) Allocator.Error!bool {
        var arena = b.arena.promote(b.gpa);
        defer b.arena = arena.state;
        const owned = try arena.allocator().dupe(u8, bytes);
        // A full batch is flushed before another file is added.
        assert(b.jobs.items.len < max_files);
        try b.jobs.append(b.gpa, .{ .path = path, .want = want, .bytes = owned, .executable = executable });
        b.bytes += bytes.len;
        return b.bytes >= max_bytes or b.jobs.items.len >= max_files;
    }

    fn flush(b: *WriteBatch, io: Io, wt: Io.Dir, index: *Index, outcome: *CheckoutOutcome, rules: Rules) Error!void {
        if (b.jobs.items.len == 0) return;
        defer {
            b.jobs.clearRetainingCapacity();
            b.bytes = 0;
            var arena = b.arena.promote(b.gpa);
            _ = arena.reset(.retain_capacity);
            b.arena = arena.state;
        }
        var next: std.atomic.Value(usize) = .init(0);
        // A batch of a few files is written here, as git writes fewer than
        // its `checkout.thresholdForParallelism` of them.
        const tasks = if (b.jobs.items.len < parallel_threshold) 1 else @min(b.workers, b.jobs.items.len);
        var group: Io.Group = .init;
        var spawned: usize = 1;
        while (spawned < tasks) : (spawned += 1) {
            group.concurrent(io, run, .{ io, wt, b.jobs.items, &next }) catch break;
        }
        // This task writes too; with no others it writes them all.
        run(io, wt, b.jobs.items, &next);
        // It stops only once every job is claimed, so none is read below
        // with the result it started with.
        assert(next.load(.monotonic) >= b.jobs.items.len);
        group.await(io) catch group.cancel(io);
        var first: ?Error = null;
        for (b.jobs.items) |*job| {
            const stat = job.result catch |err| {
                if (first == null) first = err;
                continue;
            };
            fs.hideIfAsked(io, wt, job.path, rules.hide_dot_files);
            try recordStat(index, job.path, job.want, stat, rules);
            outcome.written += 1;
        }
        if (first) |err| return err;
    }

    fn run(io: Io, wt: Io.Dir, jobs: []Job, next: *std.atomic.Value(usize)) void {
        while (true) {
            const at = next.fetchAdd(1, .monotonic);
            if (at >= jobs.len) return;
            const job = &jobs[at];
            job.result = write(io, wt, job);
        }
    }

    fn write(io: Io, wt: Io.Dir, job: *const Job) Error!?fs.Stat {
        try writeFile(io, wt, job.path, .{ .bytes = job.bytes }, job.executable);
        const after = try fs.statAt(io, wt, job.path);
        return if (after) |found| found.stat else null;
    }
};

/// Put a path just written into the index with the stat it was found with.
fn recordStat(index: *Index, path: []const u8, want: TreeEntry, stat: ?fs.Stat, rules: Rules) Error!void {
    const tree = try index.cacheTree();
    tree.invalidate(path);
    var entry: index_mod.Entry = .{ .path = path, .oid = want.oid, .mode = want.mode };
    if (stat) |found| rules.fillStat(&entry, found);
    try index.add(entry);
}

/// Stat what was just written and put it in the index.
fn recordWritten(io: Io, wt: Io.Dir, index: *Index, path: []const u8, want: TreeEntry, rules: Rules) Error!void {
    fs.hideIfAsked(io, wt, path, rules.hide_dot_files);
    const after = try fs.statAt(io, wt, path);
    const tree = try index.cacheTree();
    tree.invalidate(path);
    var entry: index_mod.Entry = .{ .path = path, .oid = want.oid, .mode = want.mode };
    if (after) |found| rules.fillStat(&entry, found.stat);
    try index.add(entry);
}

/// Put the tree's own `.gitattributes` files into `attrs`, each at the depth
/// its directory is at. The text lives in `arena`; the caller takes the
/// levels out again before the arena goes. A later `Attrs.enter` reads the
/// working tree's file only for a directory the tree has none in, which is
/// how git reads attributes while it checks a tree out: from the index it
/// is writing first.
pub fn addTreeAttributes(
    arena: Allocator,
    io: Io,
    db: *Odb,
    attrs: *attributes.Attrs,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
) Self.Error!void {
    if (attrs.from_tree) return;
    var it = wanted.iterator();
    while (it.next()) |item| {
        const path = item.key_ptr.*;
        const base = if (std.mem.eql(u8, path, ".gitattributes"))
            ""
        else if (std.mem.endsWith(u8, path, "/.gitattributes"))
            path[0 .. path.len - "/.gitattributes".len]
        else
            continue;
        if (!item.value_ptr.mode.isBlob() or item.value_ptr.mode == .symlink) continue;
        const found = try db.read(io, item.value_ptr.oid);
        defer db.allocator().free(found.bytes);
        const depth: u32 = if (base.len == 0) 0 else @intCast(std.mem.count(u8, base, "/") + 1);
        try attrs.addText(try arena.dupe(u8, found.bytes), .{ .base = base, .source = path, .precedence = depth + 1, .form = .blob });
    }
}

fn writeSmudged(io: Io, wt: Io.Dir, path: []const u8, smudged: native.Content, executable: bool) Error!void {
    switch (smudged) {
        .bytes => |bytes| try writeFile(io, wt, path, .{ .bytes = bytes }, executable),
        .file => |file| {
            defer file.close(io);
            try writeFile(io, wt, path, .{ .file = file }, executable);
        },
        .delayed => unreachable,
    }
}

/// One path `writePaths` puts into the working tree.
pub const PathWrite = struct {
    path: []const u8,
    /// The mode and blob to write, or `null` to remove the file.
    blob: ?Blob,
    /// Whether the index follows: the path's entry becomes `blob` at stage
    /// zero, every other stage of it going, or leaves with the file. `false`
    /// leaves the index to the caller, which is how a conflict's stages sit
    /// beside the marked-up file.
    index: bool = true,

    /// A mode and a blob's name.
    pub const Blob = struct { mode: object.Mode, oid: Oid };
};

/// `checkout-index -f` for the named paths only: write each blob into the
/// working tree, or remove the file, and bring the index along. Nothing
/// else in either is touched, so a caller that has decided which paths may
/// change — a merge that has checked none of them holds local changes —
/// changes exactly those. Removals happen before writes, so a file may give
/// way to a directory of the same name. A file is written as a checkout
/// writes it, through the same line-ending conversion, smudge filters and
/// LFS, and one a filter hands over late is written after the others.
pub fn writePaths(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: PathInputs,
    options: CheckoutOptions,
) Self.Error!CheckoutOutcome {
    const index = inputs.index;
    const db = inputs.db;
    const writes = inputs.writes;
    var outcome: CheckoutOutcome = .{};
    defer if (options.rules.attrs) |attrs| attrs.leave();
    for (writes) |w| {
        const symlink = if (w.blob) |b| b.mode == .symlink else false;
        if (safe_path.checkEntry(w.path, .worktree, symlink, options.rules.protect)) |refused| {
            if (options.refusal) |out| out.set(refused.reason, w.path);
            return error.UnsafePath;
        }
    }

    var conv: convert.Session = .open(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
    });
    defer conv.deinit(io);

    try removePaths(io, wt, index, writes, options.remove_empty_directories, &outcome);

    var waiting: std.StringHashMapUnmanaged(PathWrite) = .empty;
    defer waiting.deinit(gpa);
    var leading: LeadingDirs = .{ .hide = options.rules.hide_dot_files };
    for (writes) |w| {
        const want = w.blob orelse continue;
        if (std.Io.Dir.path.dirnamePosix(w.path)) |parent| try leading.make(io, wt, parent, options.force, options.refusal);
        if (try fs.statAt(io, wt, w.path)) |found| {
            // An empty directory gives way; one with anything in it is
            // someone's work, or a submodule's checkout.
            if (found.kind == .directory and want.mode != .gitlink) wt.deleteDir(io, w.path) catch return error.UntrackedWouldBeOverwritten;
        }
        switch (want.mode) {
            .gitlink => {
                try writeGitlink(gpa, io, wt, &leading, .{ .path = w.path, .oid = want.oid, .rules = options.rules, .force = options.force, .refusal = options.refusal });
                outcome.gitlinks += 1;
            },
            .symlink => {
                const found = try db.read(io, want.oid);
                defer gpa.free(found.bytes);
                if (try writeLink(io, wt, w.path, found.bytes, options.rules.symlinks)) outcome.symlinks_as_files += 1;
                leading.forget();
                outcome.written += 1;
            },
            .file, .exec => {
                if (!try writePathFile(gpa, io, wt, db, &conv, w.path, want, options.rules)) {
                    try waiting.put(gpa, w.path, w);
                    continue;
                }
                outcome.written += 1;
            },
            .tree => return error.UnsupportedEntry,
        }
        if (w.index) try recordWritten(io, wt, index, w.path, .{ .mode = want.mode, .oid = want.oid }, options.rules);
    }

    var late: std.heap.ArenaAllocator = .init(gpa);
    defer late.deinit();
    while (try conv.nextReady(late.allocator())) |ready| {
        defer _ = late.reset(.retain_capacity);
        const w = waiting.get(ready.path).?;
        const want = w.blob.?;
        try writeSmudged(io, wt, w.path, ready.content, want.mode == .exec and options.rules.file_mode);
        outcome.written += 1;
        if (w.index) try recordWritten(io, wt, index, w.path, .{ .mode = want.mode, .oid = want.oid }, options.rules);
    }
    outcome.native_fallbacks = conv.fallbackCount();
    return outcome;
}

/// The removals of `writePaths`, made before any write so a file may give
/// way to a directory of the same name.
fn removePaths(
    io: Io,
    wt: Io.Dir,
    index: *Index,
    writes: []const PathWrite,
    remove_empty_directories: bool,
    outcome: *CheckoutOutcome,
) Error!void {
    var leading: LeadingDirs = .{};
    for (writes) |w| {
        if (w.blob != null) continue;
        // A file past a symbolic link is not the working tree's to remove.
        if (try leading.real(io, wt, std.Io.Dir.path.dirnamePosix(w.path) orelse "")) fs.deleteFile(io, wt, w.path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        };
        if (w.index) {
            const tree = try index.cacheTree();
            tree.invalidate(w.path);
            _ = index.remove(w.path);
        }
        outcome.removed += 1;
        if (remove_empty_directories) {
            if (std.Io.Dir.path.dirnamePosix(w.path)) |parent| removeEmptyDirectories(io, wt, parent);
        }
    }
}

/// Write one regular file of `writePaths` as a checkout writes it. `false`
/// when a filter delays it, to be handed over later.
fn writePathFile(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    db: *Odb,
    conv: *convert.Session,
    path: []const u8,
    want: PathWrite.Blob,
    rules: Rules,
) Error!bool {
    assert(want.mode == .file or want.mode == .exec);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const found = try db.read(io, want.oid);
    defer gpa.free(found.bytes);
    const executable = want.mode == .exec and rules.file_mode;
    const attrs = rules.attrs orelse {
        try writeFile(io, wt, path, .{ .bytes = found.bytes }, executable);
        return true;
    };
    try attrs.enter(io, wt, path);
    const applied = try attrs.lookup(a, path, .file);
    const smudged = try conv.toWorktree(a, .{ .path = path, .blob = found.bytes, .applied = applied }, .{
        .blob = want.oid,
        .can_delay = true,
    });
    if (smudged == .delayed) return false;
    try writeSmudged(io, wt, path, smudged, executable);
    attrs.written(path);
    return true;
}

/// What `writeEntry` left on the disk.
pub const Written = struct {
    /// The file's stat after writing, for the index.
    stat: fs.Stat,
    /// A symlink written as an ordinary file holding its target, because the
    /// platform or `core.symlinks` refuses a real one.
    symlink_as_file: bool = false,
};

/// Write one tree entry into the working tree the way `checkout` writes it:
/// a file through `conv` -- `ident`, line endings and the smudge filter or
/// relic's own LFS, as the attributes say -- with the executable bit set
/// where the filesystem keeps one, a symlink made or written as a file
/// holding its target, a gitlink's submodule moved by `rules.submodules` or
/// else made as an empty directory. Whatever is at
/// `path` is replaced; the directories above it are made. `conv` must not
/// be one that may hand a file over late.
pub const WriteEntryOptions = struct { db: *Odb, conv: *convert.Session, path: []const u8, mode: object.Mode, oid: Oid, rules: Rules };
pub fn writeEntry(gpa: Allocator, io: Io, wt: Io.Dir, options: WriteEntryOptions) Self.Error!Written {
    const db = options.db;
    const conv = options.conv;
    const path = options.path;
    const mode = options.mode;
    const oid = options.oid;
    const rules = options.rules;
    if (safe_path.checkEntry(path, .worktree, mode == .symlink, options.rules.protect) != null) return error.UnsafePath;
    try makeLeadingDirs(io, wt, path, rules.hide_dot_files);
    defer fs.hideIfAsked(io, wt, path, rules.hide_dot_files);
    var written: Written = .{ .stat = .none };
    switch (mode) {
        .gitlink => {
            var leading: LeadingDirs = .{ .hide = rules.hide_dot_files };
            try writeGitlink(gpa, io, wt, &leading, .{ .path = path, .oid = oid, .rules = rules });
        },
        .symlink => {
            const found = try db.read(io, oid);
            defer gpa.free(found.bytes);
            written.symlink_as_file = try writeLink(io, wt, path, found.bytes, rules.symlinks);
        },
        .file, .exec => {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            const found = try db.read(io, oid);
            defer db.allocator().free(found.bytes);
            const applied: attributes.Attributes = if (rules.attrs) |attrs| try attrs.lookup(a, path, .file) else .{ .items = &.{} };
            const smudged = try conv.toWorktree(a, .{ .path = path, .blob = found.bytes, .applied = applied }, .{ .blob = oid });
            try writeSmudged(io, wt, path, smudged, mode == .exec and rules.file_mode);
        },
        .tree => return error.UnsupportedEntry,
    }
    if (try fs.statAt(io, wt, path)) |after| written.stat = after.stat;
    return written;
}

/// Write `bytes`, a blob's contents already in memory, at `path` the way
/// `writeEntry` writes a blob of `mode`: through `conv` for a file, as a
/// link for a symlink, as an empty directory for a gitlink. For a caller
/// that made the contents itself and stores no object for them, which is
/// what `git apply` without `--index` does.
pub const WriteBytesOptions = struct { conv: *convert.Session, path: []const u8, mode: object.Mode, bytes: []const u8, rules: Rules };
pub fn writeBytes(gpa: Allocator, io: Io, wt: Io.Dir, options: WriteBytesOptions) Self.Error!Written {
    const conv = options.conv;
    const path = options.path;
    const mode = options.mode;
    const bytes = options.bytes;
    const rules = options.rules;
    if (safe_path.checkEntry(path, .worktree, mode == .symlink, options.rules.protect) != null) return error.UnsafePath;
    try makeLeadingDirs(io, wt, path, rules.hide_dot_files);
    defer fs.hideIfAsked(io, wt, path, rules.hide_dot_files);
    if (try fs.statAt(io, wt, path)) |found| {
        if (found.kind == .directory and mode != .gitlink) wt.deleteDir(io, path) catch return error.UntrackedWouldBeOverwritten;
    }
    var written: Written = .{ .stat = .none };
    switch (mode) {
        .gitlink => {
            var leading: LeadingDirs = .{ .hide = rules.hide_dot_files };
            try leading.make(io, wt, path, false, null);
        },
        .symlink => {
            written.symlink_as_file = try writeLink(io, wt, path, bytes, rules.symlinks);
        },
        .file, .exec => {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            const applied: attributes.Attributes = if (rules.attrs) |attrs| blk: {
                try attrs.enter(io, wt, path);
                break :blk try attrs.lookup(a, path, .file);
            } else .{ .items = &.{} };
            const smudged = try conv.toWorktree(a, .{ .path = path, .blob = bytes, .applied = applied }, .{});
            try writeSmudged(io, wt, path, smudged, mode == .exec and rules.file_mode);
            if (rules.attrs) |attrs| attrs.written(path);
        },
        .tree => return error.UnsupportedEntry,
    }
    if (try fs.statAt(io, wt, path)) |after| written.stat = after.stat;
    return written;
}

/// Write the gitlink at `path`: git's `checkout_entry` on one. Without a
/// mover it is an empty directory. With one, a populated submodule there
/// is moved from its `HEAD` to `oid`, forced, as git's `check_updates`
/// forces every entry it writes: what would lose work was refused before
/// anything was written, and a change the move does not touch goes with
/// the rest. Anything else there gives way to the submodule's directory,
/// and the submodule is made in it from its repository, unforced where
/// something was there, as git makes it.
fn writeGitlink(gpa: Allocator, io: Io, wt: Io.Dir, leading: *LeadingDirs, link: GitlinkWrite) Error!void {
    const mover = link.rules.submodules orelse return leading.make(io, wt, link.path, link.force, link.refusal);
    var force = true;
    if (try fs.statAt(io, wt, link.path)) |found| {
        if (found.kind == .directory and try gitlink.isRepository(gpa, io, wt, link.path)) {
            return mover.move(io, .{ .path = link.path, .from = .head, .to = link.oid, .force = true });
        }
        if (found.kind != .directory) try fs.deleteFile(io, wt, link.path);
        force = false;
    }
    try leading.make(io, wt, link.path, link.force, link.refusal);
    try mover.move(io, .{ .path = link.path, .from = .none, .to = link.oid, .force = force });
}

/// `force` is the checkout's, for the directories made on the way.
const GitlinkWrite = struct { path: []const u8, oid: Oid, rules: Rules, force: bool = false, refusal: ?*Refusal = null };

/// Take the submodule at `path` away, as git's `unlink_entry` does: with
/// `rules.submodules`, the mover takes its working tree away, forced, and
/// what it could not is left; then its directory goes once empty. A
/// populated submodule without a mover keeps its directory, as git keeps
/// it with a warning.
pub fn removeGitlink(io: Io, wt: Io.Dir, path: []const u8, rules: Rules) Self.Error!void {
    if (safe_path.check(path, .worktree, rules.protect) != null) return error.UnsafePath;
    if (!try realLeadingPath(io, wt, path)) return;
    if (rules.submodules) |mover| {
        if (try fs.statAt(io, wt, path) != null) {
            mover.move(io, .{ .path = path, .from = .head, .to = null, .force = true }) catch |err| switch (err) {
                // git's `unlink_entry` goes on whatever the move says.
                error.SubmoduleNotUpdated => {},
                else => |e| return e,
            };
        }
    }
    wt.deleteDir(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.DirNotEmpty => {},
        else => |e| return e,
    };
}

/// Remove one file from the working tree, and every directory above it that
/// it leaves empty. A file that is already gone is not an error.
pub fn removeEntry(io: Io, wt: Io.Dir, path: []const u8, protect: safe_path.Protect) Self.Error!void {
    if (safe_path.check(path, .worktree, protect) != null) return error.UnsafePath;
    // A file past a symbolic link is not the working tree's: git's
    // `unlink_entry` leaves it.
    if (!try realLeadingPath(io, wt, path)) return;
    wt.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        // glint-ignore: Z026 -- as git's remove_path: a directory with something in it stays, and only an empty one goes
        error.IsDir => wt.deleteDir(io, path) catch {},
        else => |e| return e,
    };
    if (std.Io.Dir.path.dirnamePosix(path)) |parent| removeEmptyDirectories(io, wt, parent);
}

/// The paths an update would lose work at, as git lists them.
pub const Obstructions = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    /// Tracked paths with changes of their own that the update would
    /// overwrite or remove, sorted.
    changed: std.ArrayList([]u8) = .empty,
    /// Untracked paths the update would overwrite, sorted.
    untracked: std.ArrayList([]u8) = .empty,
    /// Submodules the `Rules.submodules` mover could not move, sorted.
    submodules: std.ArrayList([]u8) = .empty,

    /// An empty list, allocating from `gpa`.
    pub fn init(gpa: Allocator) Obstructions {
        return .{ .gpa = gpa };
    }

    /// Release the lists.
    pub fn deinit(o: *Obstructions) void {
        for (o.changed.items) |p| o.gpa.free(p);
        for (o.untracked.items) |p| o.gpa.free(p);
        for (o.submodules.items) |p| o.gpa.free(p);
        o.changed.deinit(o.gpa);
        o.untracked.deinit(o.gpa);
        o.submodules.deinit(o.gpa);
        o.* = undefined;
    }

    /// The first path listed, changed ones first, then untracked ones, or
    /// `null`.
    pub fn first(o: *const Obstructions) ?[]const u8 {
        if (o.changed.items.len != 0) return o.changed.items[0];
        if (o.untracked.items.len != 0) return o.untracked.items[0];
        if (o.submodules.items.len != 0) return o.submodules.items[0];
        return null;
    }
};

/// What `verifyUpdates` is told.
pub const VerifyOptions = struct {
    rules: Rules = .{},
    /// Ignore rules for the root; the `.gitignore` files below are read
    /// into it as needed. An ignored file in the way is not an obstruction,
    /// as git's checkout and merge overwrite it. Without rules, none is
    /// ignored.
    ignore: ?*ignore.Rules = null,
    obstructions: ?*Obstructions = null,
    /// Whether what stands in the way of a new path is looked for. An
    /// update that writes nothing, `read-tree` without `-u`, does not look:
    /// git's `verify_absent` asks only of one that updates the working tree.
    untracked: bool = true,
};

/// `verify_uptodate` and `verify_absent` from git's `unpack-trees`, over
/// every path an update changes: `updates` maps each path whose index
/// entry the update rewrites, adds or removes to what it will hold, `null`
/// for removal.
///
/// A tracked path there whose file has changes of its own is
/// `error.LocalChangesWouldBeOverwritten`. A new path where an untracked,
/// unignored file stands -- or stands where a directory above it goes, or
/// where a directory holding anything but files the update removes stands
/// in the way -- is `error.UntrackedWouldBeOverwritten`. Every such path is
/// listed in `options.obstructions` before the error comes back, changed
/// ones taking precedence; nothing on the disk is touched either way.
pub fn verifyUpdates(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: VerifyInputs,
    options: VerifyOptions,
) Self.Error!void {
    const index = inputs.index;
    const updates = inputs.updates;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var changed: std.ArrayList([]const u8) = .empty;
    var untracked: std.ArrayList([]const u8) = .empty;
    // the caller's rules, with every `.gitignore` read along the way, go
    // back to the caller; one that cannot be read counts as absent
    var ignores: ?ignore.Checker = if (options.ignore) |rules| .init(rules.*, wt, .{ .unreadable = .skip }) else null;
    defer if (ignores) |*checker| {
        options.ignore.?.* = checker.toRules();
    };

    const paths = try arena.dupe([]const u8, updates.keys());
    std.mem.sort([]const u8, paths, {}, lessThanName);
    for (paths) |path| {
        const want = updates.get(path).?;
        if (index.find(path)) |entry| {
            if (entry.skip_worktree) continue;
            if (try differsFromIndex(gpa, io, wt, .{ .index = index, .entry = entry.* }, options.rules)) try changed.append(arena, path);
            continue;
        }
        if (want == null or !options.untracked) continue;
        var at: usize = 0;
        while (true) {
            const slash = std.mem.findScalarPos(u8, path, at, '/');
            const prefix = if (slash) |s| path[0..s] else path;
            const is_last = slash == null;
            if (try fs.statAt(io, wt, prefix)) |found| {
                const blocks = if (found.kind == .directory)
                    is_last and !try directoryGoes(arena, io, wt, prefix, index, updates, options.rules.precompose_unicode)
                else if (index.find(prefix) != null)
                    false
                else
                    !(if (ignores) |*checker| try checker.excluded(io, prefix, .file) else false);
                if (blocks) {
                    try untracked.append(arena, prefix);
                    break;
                }
            }
            at = (slash orelse break) + 1;
        }
    }
    var submodules: std.ArrayList([]const u8) = .empty;
    if (options.rules.submodules) |mover| try refusedMoves(arena, io, wt, inputs, .{ .mover = mover }, paths, &submodules);
    if (changed.items.len == 0 and untracked.items.len == 0 and submodules.items.len == 0) return;
    if (options.obstructions) |out| {
        for (changed.items) |p| try out.changed.append(out.gpa, try out.gpa.dupe(u8, p));
        for (untracked.items) |p| try out.untracked.append(out.gpa, try out.gpa.dupe(u8, p));
        for (submodules.items) |p| try out.submodules.append(out.gpa, try out.gpa.dupe(u8, p));
    }
    if (changed.items.len != 0) return error.LocalChangesWouldBeOverwritten;
    if (untracked.items.len != 0) return error.UntrackedWouldBeOverwritten;
    return error.SubmoduleNotUpdated;
}

/// What `verifySubmoduleMoves` is told.
pub const SubmoduleCheck = struct {
    mover: SubmoduleMover,
    /// `read-tree --reset`: each move asked as a forced one, and a
    /// submodule's `HEAD` not asked to be where its gitlink was.
    force: bool = false,
    obstructions: ?*Obstructions = null,
};

/// git's `check_submodule_move_head` over the gitlinks an update changes:
/// every move the mover would make, asked of it as a dry run before
/// anything is written. `verifyUpdates` does this itself when its rules
/// carry a mover; a forced update, which checks nothing else, asks here.
/// A refused move is `error.SubmoduleNotUpdated`, with every such path in
/// `options.obstructions`.
pub fn verifySubmoduleMoves(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: VerifyInputs,
    options: SubmoduleCheck,
) Self.Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const paths = try arena.dupe([]const u8, inputs.updates.keys());
    std.mem.sort([]const u8, paths, {}, lessThanName);
    var refused: std.ArrayList([]const u8) = .empty;
    try refusedMoves(arena, io, wt, inputs, options, paths, &refused);
    if (refused.items.len == 0) return;
    if (options.obstructions) |out| {
        for (refused.items) |p| try out.submodules.append(out.gpa, try out.gpa.dupe(u8, p));
    }
    return error.SubmoduleNotUpdated;
}

/// The paths of `paths`, sorted, whose submodule would not move: git asks
/// a gitlink the update changes or removes to be at the commit the index
/// records (`verify_uptodate`), unless forced; one it removes, or one it
/// writes where the index had nothing, to give way, from that commit to
/// nothing (`verify_absent`); and one it writes to take the move from the
/// old one (`merged_entry`). A path with nothing on the disk has no
/// submodule to ask.
fn refusedMoves(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: VerifyInputs,
    check: SubmoduleCheck,
    paths: []const []const u8,
    refused: *std.ArrayList([]const u8),
) Error!void {
    for (paths) |path| {
        const want = inputs.updates.get(path).?;
        const old = inputs.index.find(path);
        if (old != null and old.?.skip_worktree) continue;
        const old_link: ?Oid = if (old != null and old.?.mode == .gitlink) old.?.oid else null;
        const new_link: ?Oid = if (want != null and want.?.mode == .gitlink) want.?.oid else null;
        if (old_link == null and new_link == null) continue;
        if (try fs.statAt(io, wt, path) == null) continue;
        var moves: [3]?SubmoduleMove = .{ null, null, null };
        if (old_link) |recorded| {
            if (!check.force) moves[0] = .{ .path = path, .from = .head, .to = recorded, .force = false, .dry_run = true };
            if (want == null) moves[1] = .{ .path = path, .from = .{ .commit = recorded }, .to = null, .force = check.force, .dry_run = true };
        } else if (old == null and new_link != null) {
            moves[1] = .{ .path = path, .from = .{ .commit = new_link.? }, .to = null, .force = check.force, .dry_run = true };
        }
        if (new_link) |to| {
            // A file the index has there is no submodule to move from.
            if (old == null or old_link != null) moves[2] = .{
                .path = path,
                .from = if (old_link) |from| .{ .commit = from } else .none,
                .to = to,
                .force = check.force,
                .dry_run = true,
            };
        }
        for (moves) |maybe| {
            const move = maybe orelse continue;
            check.mover.move(io, move) catch |err| switch (err) {
                error.SubmoduleNotUpdated => {
                    try refused.append(arena, path);
                    break;
                },
                else => |e| return e,
            };
        }
    }
}

/// Whether everything under the directory at `dir_path` is a file the
/// update removes, so the directory may go.
fn directoryGoes(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    dir_path: []const u8,
    index: *const Index,
    updates: *const std.array_hash_map.String(?TreeEntry),
    precompose: bool,
) Error!bool {
    var dir = try wt.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it: fs.Names = .init(dir, precompose);
    while (try it.next(io)) |item| {
        const path = try arena.print("{s}/{s}", .{ dir_path, item.name });
        if (item.kind == .directory) {
            if (!try directoryGoes(arena, io, wt, path, index, updates, precompose)) return false;
            continue;
        }
        if (index.find(path) == null) return false;
        const want = updates.get(path) orelse return false;
        if (want != null) return false;
    }
    return true;
}

/// The check `index.WriteOptions.racy` asks for, over the working tree at
/// `wt` read by `rules`: a racily clean entry is smudged only when its file
/// holds something else. A file that cannot be read counts as changed.
pub const RacyCheck = struct {
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    rules: Rules,

    pub fn racy(c: *RacyCheck) index_mod.WriteOptions.Racy {
        return .{ .context = c, .changed = changed };
    }

    fn changed(context: *anyopaque, index: *const Index, entry: index_mod.Entry) bool {
        const c: *RacyCheck = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a RacyCheck
        return differsFromIndex(c.gpa, c.io, c.wt, .{ .index = index, .entry = entry }, c.rules) catch true;
    }
};

/// Whether the file at `entry.path` holds something other than the index
/// says. A file that is not there has nothing to lose, which is how git
/// treats one deleted by hand; a submodule's checkout is its own.
pub fn differsFromIndex(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: CompareInputs,
    rules: Rules,
) Self.Error!bool {
    const index = inputs.index;
    const entry = inputs.entry;
    if (entry.mode == .gitlink) return false;
    const found = (try fs.statAt(io, wt, entry.path)) orelse return false;
    if (found.kind == .directory) return true;
    if (modeOnDisk(found, entry.mode, rules) != entry.mode) return true;
    if (!index.isRacy(entry) and entry.stat.matches(found.stat, rules.statCompare())) {
        return false;
    }
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const bytes = if (found.kind == .sym_link) blk: {
        var buf: [4096]u8 = undefined;
        const len = try wt.readLink(io, entry.path, &buf);
        break :blk try a.dupe(u8, buf[0..len]);
    } else wt.readFileAlloc(io, entry.path, a, .limited(1 << 31)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    var content: []const u8 = bytes;
    if (rules.attrs) |attrs| {
        if (found.kind != .sym_link) {
            // The whole way in, as the file would be added: the filter,
            // line endings and `ident`, under the attributes the working
            // tree gives it. Anything less takes a checked-out `$Id: ... $`
            // or CRLF for a change whenever the stat stops matching, which a
            // touch does, and which a filesystem whose clock is coarser than
            // the time between writing a file and the index does to them all.
            var conv: convert.Session = .open(gpa, io, .{
                .wt = wt,
                .kind = index.kind,
                .core = rules.core,
                .required_filters = rules.required_filters,
                .drivers = rules.filters,
                .index = index,
            });
            defer conv.deinit(io);
            // The `.gitattributes` on the way down to the file, which a
            // lookup alone does not read. What this enters, it leaves; a
            // caller already going path by path keeps what it entered.
            const entered = attrs.entered_any;
            try attrs.enter(io, wt, entry.path);
            defer if (!entered) attrs.leave();
            const applied = try attrs.lookup(a, entry.path, .file);
            content = (try conv.toGit(a, .{ .path = entry.path, .bytes = bytes, .applied = applied }, .{ .storing = .hash_only })).bytes;
        }
    }
    return !hash.Hasher.object(index.kind, "blob", content).eql(entry.oid);
}

fn directoryIsReplaceable(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    dir_path: []const u8,
    index: *const Index,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
    precompose: bool,
) Error!bool {
    var dir = try wt.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iterator: fs.Names = .init(dir, precompose);
    while (try iterator.next(io)) |item| {
        const path = try arena.print("{s}/{s}", .{ dir_path, item.name });
        if (item.kind == .directory) {
            if (!try directoryIsReplaceable(arena, io, wt, path, index, wanted, precompose)) return false;
            continue;
        }
        const tracked = index.find(path) != null;
        if (!tracked or wanted.contains(path)) return false;
    }
    return true;
}

fn refuseCaseCollisions(arena: Allocator, wanted: *std.StringHashMapUnmanaged(TreeEntry)) Error!void {
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    var it = wanted.keyIterator();
    while (it.next()) |key| {
        const lowered = try arena.dupe(u8, key.*);
        for (lowered) |*c| c.* = std.ascii.toLower(c.*);
        const slot = try folded.getOrPut(arena, lowered);
        // Two tree entries differing only in case become one file on a
        // filesystem that folds case, and the second silently wins. Saying
        // so is the minimum honest behaviour.
        if (slot.found_existing) return error.CaseCollision;
    }
}

/// What a file is written from: bytes in memory, or an open file copied in
/// pieces.
const Source = union(enum) {
    bytes: []const u8,
    file: Io.File,
};

fn writeFile(io: Io, wt: Io.Dir, path: []const u8, source: Source, executable: bool) Error!void {
    // A file that is there is replaced rather than opened for writing, so a
    // reader sees the old bytes or the new ones.
    var name_buf: [256]u8 = undefined;
    const temp_name = fs.tempName(io, &name_buf, ".relic-");
    const dir_path = std.Io.Dir.path.dirnamePosix(path);
    var temp_path_buf: [4096]u8 = undefined;
    const temp_path = if (dir_path) |parent|
        std.mem.print(&temp_path_buf, "{s}/{s}", .{ parent, temp_name }) catch return error.UnsafePath
    else
        temp_name;

    // Created with git's mode, 0666 or 0777, which the umask then trims
    // as it trims git's: no change of mode after.
    const file = try wt.createFile(io, temp_path, .{
        .exclusive = true,
        .permissions = fs.permissionsFor(executable),
    });
    var failed = true;
    defer if (failed) {
        // glint-ignore: Z026 -- the write's error is the one to report; a temporary left behind is what git's own checkout leaves too
        wt.deleteFile(io, temp_path) catch {};
    };
    {
        defer file.close(io);
        var buf: [16 * 1024]u8 = undefined;
        var fw = file.writer(io, &buf);
        switch (source) {
            .bytes => |bytes| try fw.interface.writeAll(bytes),
            .file => |from| {
                var in_buf: [64 * 1024]u8 = undefined;
                var reader = from.reader(io, &in_buf);
                _ = reader.interface.streamRemaining(&fw.interface) catch |err| switch (err) {
                    error.ReadFailed => return reader.err.?,
                    error.WriteFailed => return fw.err.?,
                };
            },
        }
        try fw.interface.flush();
    }
    try fs.rename(io, wt, temp_path, path);
    failed = false;
}

fn removeEmptyDirectories(io: Io, wt: Io.Dir, path: []const u8) void {
    // Only directories of the working tree's own go: none reached through
    // a symbolic link.
    var leading: LeadingDirs = .{};
    const real = leading.real(io, wt, path) catch false;
    if (!real) return;
    var current = path;
    while (current.len != 0) {
        wt.deleteDir(io, current) catch return;
        current = std.Io.Dir.path.dirnamePosix(current) orelse return;
    }
}

/// What `applySparse` changed.
pub const SparseOutcome = struct {
    /// Entries that left the working tree.
    skipped: u32 = 0,
    /// Entries that came back into it.
    restored: u32 = 0,
    /// Entries left alone because the file on the disk does not match the
    /// index's stat, or its content where that stat is racy, so removing it
    /// might lose work.
    kept_dirty: u32 = 0,
    /// Entries that came back where something was already on the disk at
    /// their path. What is there is not overwritten; the entry comes back
    /// with it, and a status says whether the two differ, as in git.
    already_present: u32 = 0,
};

/// Make the working tree hold exactly the paths the sparse patterns
/// include.
///
/// A path that leaves gets `skip-worktree` and its file is removed; a path
/// that returns loses the flag and its file is written. A file that does
/// not match the index -- by its stat, or by its content where the stat
/// matches but is racy -- is left where it is and counted, because
/// removing it would throw away work nobody asked to throw away; and a
/// returning path where something is already on the disk is not written
/// over, for the same reason, which is git's rule for both.
pub fn applySparse(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    inputs: SparseInputs,
    options: CheckoutOptions,
) Self.Error!SparseOutcome {
    const index = inputs.index;
    const db = inputs.db;
    const patterns = inputs.patterns;
    var outcome: SparseOutcome = .{};
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var conv: convert.Session = .open(gpa, io, .{
        .wt = wt,
        .kind = db.objectFormat(),
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .index = index,
        .db = db,
    });
    defer conv.deinit(io);
    defer if (options.rules.attrs) |attrs| attrs.leave();

    // A sparse index is expanded as far as the new patterns reach into it,
    // which for a cone is the directories it now includes and for anything
    // else is everything. What stays collapsed stays out.
    if (index.sparse) try sparse_index.expand(gpa, io, index, db, patterns);

    for (index.entries.items) |*entry| {
        if (entry.stage != 0 or entry.isSparseDirectory()) continue;
        const included = patterns.includes(entry.path, .file);
        if (!included and !entry.skip_worktree) {
            if (try fs.statAt(io, wt, entry.path)) |found| {
                // git's `verify_uptodate`: a stat that does not match is a
                // change, without reading the file, and only a racy entry
                // whose stat does match has its content compared.
                if (!entry.stat.matches(found.stat, options.rules.statCompare())) {
                    outcome.kept_dirty += 1;
                    continue;
                }
                if (index.isRacy(entry.*)) {
                    _ = scratch.reset(.retain_capacity);
                    const a = scratch.allocator();
                    const raw = if (found.kind == .sym_link) blk: {
                        var buf: [4096]u8 = undefined;
                        const len = try wt.readLink(io, entry.path, &buf);
                        break :blk try a.dupe(u8, buf[0..len]);
                    } else try fs.readFileSized(a, io, wt, entry.path, .{ .size = found.stat.size, .max_bytes = 1 << 31 });
                    var content: []const u8 = raw;
                    if (options.rules.attrs) |attrs| {
                        if (found.kind != .sym_link) {
                            try attrs.enter(io, wt, entry.path);
                            const applied = try attrs.lookup(a, entry.path, .file);
                            content = (try conv.toGit(a, .{ .path = entry.path, .bytes = raw, .applied = applied }, .{ .storing = .hash_only })).bytes;
                        }
                    }
                    if (!hash.Hasher.object(db.objectFormat(), "blob", content).eql(entry.oid)) {
                        outcome.kept_dirty += 1;
                        continue;
                    }
                }
                if (try realLeadingPath(io, wt, entry.path)) fs.deleteFile(io, wt, entry.path) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.IsDir => {},
                    else => |e| return e,
                };
                if (options.remove_empty_directories) {
                    if (std.Io.Dir.path.dirnamePosix(entry.path)) |parent| {
                        removeEmptyDirectories(io, wt, parent);
                    }
                }
            }
            entry.skip_worktree = true;
            outcome.skipped += 1;
            continue;
        }
        if (included and entry.skip_worktree) {
            if (safe_path.checkEntry(entry.path, .worktree, entry.mode == .symlink, options.rules.protect)) |refused| {
                if (options.refusal) |out| out.set(refused.reason, entry.path);
                return error.UnsafePath;
            }
            if (try fs.statAt(io, wt, entry.path)) |_| {
                entry.skip_worktree = false;
                outcome.already_present += 1;
                continue;
            }
            _ = scratch.reset(.retain_capacity);
            try restoreSparse(scratch.allocator(), io, wt, db, &conv, entry, options);
            if (try fs.statAt(io, wt, entry.path)) |after| options.rules.fillStat(entry, after.stat);
            entry.skip_worktree = false;
            outcome.restored += 1;
        }
    }
    return outcome;
}

/// Write back an entry a wider sparse pattern brings in, as a checkout
/// writes its mode: a link as a link, a gitlink as the empty directory a
/// submodule's checkout goes in, a file through the attributes.
fn restoreSparse(
    a: Allocator,
    io: Io,
    wt: Io.Dir,
    db: *Odb,
    conv: *convert.Session,
    entry: *const index_mod.Entry,
    options: CheckoutOptions,
) Error!void {
    var leading: LeadingDirs = .{ .hide = options.rules.hide_dot_files };
    if (std.Io.Dir.path.dirnamePosix(entry.path)) |parent| try leading.make(io, wt, parent, false, options.refusal);
    defer fs.hideIfAsked(io, wt, entry.path, options.rules.hide_dot_files);
    switch (entry.mode) {
        // The submodule's commit is in its own repository, not this one.
        .gitlink => return leading.make(io, wt, entry.path, false, options.refusal),
        .symlink => {
            const found = try db.read(io, entry.oid);
            defer db.allocator().free(found.bytes);
            _ = try writeLink(io, wt, entry.path, found.bytes, options.rules.symlinks);
        },
        .file, .exec => {
            const found = try db.read(io, entry.oid);
            defer db.allocator().free(found.bytes);
            const executable = entry.mode == .exec and options.rules.file_mode;
            if (options.rules.attrs) |attrs| {
                try attrs.enter(io, wt, entry.path);
                const applied = try attrs.lookup(a, entry.path, .file);
                const smudged = try conv.toWorktree(a, .{ .path = entry.path, .blob = found.bytes, .applied = applied }, .{ .blob = entry.oid });
                try writeSmudged(io, wt, entry.path, smudged, executable);
            } else {
                try writeFile(io, wt, entry.path, .{ .bytes = found.bytes }, executable);
            }
        },
        .tree => return error.UnsupportedEntry,
    }
}

/// What `list` found.
pub const Listing = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// Paths in the index, then untracked ones, each group sorted.
    paths: []const []const u8,
    /// How many of `paths` are tracked; the rest are untracked.
    tracked_count: usize,

    /// Release the listing.
    pub fn deinit(l: *Listing) void {
        var arena = l.arena.promote(l.gpa);
        arena.deinit();
        l.* = undefined;
    }

    /// The tracked paths.
    pub fn tracked(l: *const Listing) []const []const u8 {
        return l.paths[0..l.tracked_count];
    }

    /// The untracked paths.
    pub fn untracked(l: *const Listing) []const []const u8 {
        return l.paths[l.tracked_count..];
    }
};

/// The index's paths plus the untracked ones, with the ignore rules applied:
/// what `git ls-files --cached --others --exclude-standard` lists. A
/// repository inside the working tree that the index has nothing for is one
/// untracked path ending in `/`.
///
/// A sparse directory is listed as itself, with its trailing slash, which
/// is what `git ls-files --sparse` prints, and the walk for untracked paths
/// does not go into one: what is there is outside the sparse checkout.
pub fn list(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    rules: Rules,
) Self.Error!Listing {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    const tracked_count = paths.items.len;

    var scan: ListScan = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .wt = wt,
        .index = index,
        .rules = rules,
        .out = &paths,
    };
    try scan.walk("", 0);

    std.mem.sort([]const u8, paths.items[0..tracked_count], {}, lessThanName);
    std.mem.sort([]const u8, paths.items[tracked_count..], {}, lessThanName);

    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .paths = paths.items,
        .tracked_count = tracked_count,
    };
}

const ListScan = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    rules: Rules,
    out: *std.ArrayList([]const u8),

    fn walk(s: *ListScan, dir_path: []const u8, depth: u32) Error!void {
        if (depth > 64) return error.TreeTooDeep;
        const dir = (try openWalkDirectory(s.io, s.wt, dir_path)) orelse return;
        defer if (dir_path.len != 0) dir.close(s.io);

        if (s.rules.ignore) |rules| try rules.addDirectory(s.io, s.wt, dir_path, depth);
        defer if (s.rules.ignore) |rules| rules.popTo(depth + 2);

        var scan = try dir_scan.Scan.init(s.gpa, s.io, dir, .{ .precompose = s.rules.precompose_unicode });

        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            const path = if (dir_path.len == 0)
                try s.arena.dupe(u8, item.name)
            else
                try s.arena.print("{s}/{s}", .{ dir_path, item.name });
            const found = item.entry;
            if (found.kind == .directory) {
                // A submodule's directory is its own repository's to list.
                if (s.index.find(path)) |entry| {
                    if (entry.mode == .gitlink) continue;
                }
                if (!s.index.hasDirectory(path)) {
                    if (s.rules.ignore) |rules| {
                        if (rules.match(path, .dir).excluded) continue;
                    }
                    // A repository inside the working tree is its own to
                    // list: git names it once, as `sub/`.
                    if (try gitlink.isRepository(s.gpa, s.io, s.wt, path)) {
                        try s.out.append(s.arena, try s.arena.print("{s}/", .{path}));
                        continue;
                    }
                }
                if (s.index.sparse) {
                    const as_dir = try s.arena.print("{s}/", .{path});
                    if (s.index.find(as_dir)) |entry| {
                        if (entry.isSparseDirectory()) continue;
                    }
                }
                try s.walk(path, depth + 1);
                continue;
            }
            if (s.index.find(path) != null) continue;
            if (s.rules.ignore) |rules| {
                if (rules.match(path, .file).excluded) continue;
            }
            try s.out.append(s.arena, path);
        }
    }
};
