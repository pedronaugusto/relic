//! The working tree: staging it, writing a tree out of it, putting a tree
//! into it, and saying how the three views differ.
//!
//! Every path that comes out of a tree or an index is validated before it
//! becomes a filesystem path, because a tree entry's name is written by
//! whoever wrote the tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const fs = @import("fs.zig");
const safepath = @import("safepath.zig");
const ignore = @import("ignore.zig");
const attributes = @import("attributes.zig");
const sparse = @import("sparse.zig");
const sparseindex = @import("sparseindex.zig");
const dirscan = @import("dirscan.zig");
const pack_mod = @import("pack.zig");
const gitlink = @import("gitlink.zig");
const convert = @import("convert.zig");
const filter = @import("filter.zig");
const lfs = @import("lfs.zig");
const program = @import("program.zig");

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
    /// A tree wants a file where the working tree has a directory containing
    /// untracked content, which checkout must not discard.
    UntrackedWouldBeOverwritten,
    /// A `SubmoduleProbe` could not read a submodule's repository. The probe
    /// says which and why.
    SubmoduleUnreadable,
    /// A repository inside the working tree has no commit checked out, so a
    /// gitlink for it would have nothing to record. git's `add` stops there
    /// too. `AddOptions.refusal` says which.
    NoCommitCheckedOut,
} || Allocator.Error || odb_mod.Error || index_mod.ReadError ||
    index_mod.WriteError || fs.StatError || Io.Dir.Iterator.Error ||
    Io.Dir.OpenError || Io.Dir.DeleteFileError || Io.Dir.DeleteDirError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.SymLinkError ||
    Io.Dir.ReadLinkError || Io.Writer.Error || Io.File.SyncError ||
    Io.File.SetPermissionsError || object.Tree.Builder.AddError ||
    object.TreeParseError || convert.Error || sparseindex.Error || gitlink.Error;

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
    /// How much of a cached stat to believe, from `core.checkStat`.
    check_stat: fs.Stat.Check = .full,
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
    symlinks: bool = @import("builtin").os.tag != .windows,
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
};

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
    /// Whether to stop at the first unreadable file or to skip it, which is
    /// what `--ignore-errors` asks for.
    ignore_errors: bool = false,
    /// A path prefix to limit the walk to, `/`-separated. Empty walks the
    /// whole tree.
    prefix: []const u8 = "",
    /// The permission to run the filter programs `rules.filters` names.
    programs: ?program.Programs = null,
    /// Where filters passed over are reported.
    filter_report: ?*filter.Report = null,
    /// Where the path is written when a repository inside the working tree
    /// stops the walk with `error.NoCommitCheckedOut`.
    refusal: ?*Refusal = null,
};

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
    index: *Index,
    db: *Odb,
    options: AddOptions,
) Error!AddOutcome {
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
    if (index.sparse) try sparseindex.expandPresent(gpa, io, wt, index, db);

    // One pack for the whole call, where the caller asked for one. It is
    // opened before the walk so that an object written early in it is in
    // the same file as one written late, and finished after, so that a
    // reader sees all of them or none.
    var filling: ?Odb.OpenPack = null;
    errdefer if (filling) |open| db.abortPack(io, open);
    if (options.new_blobs == .pack) filling = try db.beginPack(io, options.pack);

    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.kind,
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .index = index,
        .db = db,
    });
    defer conv.deinit();

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
        .filling = filling,
    };
    try walker.walk(options.prefix, 0);
    if (filling) |open| {
        // Out of the errdefer's reach before it is closed, because closing
        // it releases it whether it succeeded or not.
        filling = null;
        outcome.pack = try db.finishPack(io, open);
    }
    // New entries go in once, sorted once. A walk produces paths in tree
    // order and the index is in path order, so inserting them one at a time
    // would move the tail of the list on almost every file.
    try index.addMany(fresh.items);

    if (options.stage_deletions) {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(gpa);
        for (index.entries.items) |entry| {
            const under_prefix = options.prefix.len == 0 or
                (std.mem.startsWith(u8, entry.path, options.prefix) and
                    entry.path.len > options.prefix.len and
                    entry.path[options.prefix.len] == '/');
            if (!under_prefix or entry.skip_worktree or entry.isSparseDirectory() or seen.contains(entry.path)) continue;
            // The file is gone from the working tree: stage its removal.
            const tree = try index.cacheTree();
            tree.invalidate(entry.path);
            try gone.append(gpa, entry.path);
            outcome.removed += 1;
        }
        index.removeMany(gone.items);
    }
    try db.syncBatch(io);
    return outcome;
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
    filling: ?Odb.OpenPack = null,

    fn walk(w: *Walker, dir_path: []const u8, depth: u32) Error!void {
        if (depth > 64) return;
        const dir = if (dir_path.len == 0)
            w.wt
        else
            w.wt.openDir(w.io, dir_path, .{ .iterate = true }) catch return;
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
        var scan = try dirscan.Scan.init(w.gpa, w.io, dir);
        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            try entries.append(w.gpa, .{
                .name = try w.gpa.dupe(u8, item.name),
                .entry = item.entry,
            });
        }
        std.mem.sort(Found, entries.items, {}, lessThanFound);

        for (entries.items) |e| {
            const path = if (dir_path.len == 0)
                try w.gpa.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ dir_path, e.name });
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
                const checked_out = (try gitlink.head(w.gpa, w.io, w.wt, path, w.db.kind)) orelse {
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
                entry.stat = found.stat;
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
                if (rules.match(path, true).excluded) return;
            }
            if (try gitlink.isRepository(w.gpa, w.io, w.wt, path)) return w.stageRepository(path, found);
        }
        try w.walk(path, depth + 1);
    }

    /// A repository inside the working tree that the index has nothing for
    /// is staged as git's `add -A` stages it: a gitlink to the commit it has
    /// checked out, its directory never walked.
    fn stageRepository(w: *Walker, path: []const u8, found: fs.Entry) Error!void {
        if (!safepath.isSafeStoredPath(path)) {
            w.outcome.unsafe_paths += 1;
            return;
        }
        const checked_out = (try gitlink.head(w.gpa, w.io, w.wt, path, w.db.kind)) orelse {
            if (w.options.refusal) |r| r.set(null, path);
            return error.NoCommitCheckedOut;
        };
        try w.markSeen(path);
        const tree = try w.index.cacheTree();
        tree.invalidate(path);
        try w.fresh.append(w.gpa, .{
            .path = try w.arena.allocator().dupe(u8, path),
            .oid = checked_out,
            .mode = .gitlink,
            .stat = found.stat,
        });
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
        if (tracked == null) {
            if (w.options.rules.ignore) |rules| {
                if (rules.match(path, false).excluded) return;
            }
        } else if (tracked.?.skip_worktree) {
            try w.markSeen(path);
            return;
        }
        if (!safepath.isSafeStoredPath(path)) {
            w.outcome.unsafe_paths += 1;
            return;
        }
        try w.markSeen(path);

        const mode: object.Mode = if (found.kind == .sym_link)
            .symlink
        else if (w.options.rules.file_mode)
            (if (found.executable) .exec else .file)
        else if (tracked) |entry|
            // Without an executable bit on the filesystem, the index's mode
            // is preserved rather than invented.
            (if (entry.mode == .exec) .exec else .file)
        else
            .file;

        if (tracked) |entry| {
            const racy = w.index.isRacy(entry.*);
            if (!racy and !entry.intent_to_add and
                entry.mode == mode and
                entry.stat.matches(found.stat, w.options.rules.check_stat, w.options.rules.timestamp_resolution))
            {
                w.outcome.unchanged += 1;
                return;
            }
            if (racy) w.outcome.racy_checked += 1;
        }

        const blob = try w.hashAndStore(path, found);
        w.outcome.hashed += 1;

        if (tracked) |entry| {
            if (entry.oid.eql(blob) and entry.mode == mode) {
                // The content did not change after all; refresh the stat so
                // the next call takes the shortcut.
                entry.stat = found.stat;
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
            entry.stat = found.stat;
            entry.intent_to_add = false;
            w.outcome.modified += 1;
        } else {
            try w.fresh.append(w.gpa, .{
                .path = try w.arena.allocator().dupe(u8, path),
                .oid = blob,
                .mode = mode,
                .stat = found.stat,
            });
            w.outcome.added += 1;
        }
    }

    fn hashAndStore(w: *Walker, path: []const u8, found: fs.Entry) Error!Oid {
        _ = w.scratch.reset(.retain_capacity);
        const a = w.scratch.allocator();

        if (found.kind == .sym_link) {
            var buf: [4096]u8 = undefined;
            const len = try w.wt.readLink(w.io, path, &buf);
            return w.store(buf[0..len]);
        }

        if (w.options.rules.attrs) |attrs| {
            const applied = try attrs.lookup(a, path, false);
            const converted = try w.conv.toGitFile(a, path, found.stat.size, applied, .store);
            if (converted.irreversible) switch (w.options.rules.core.safecrlf) {
                .false => {},
                .true => return error.IrreversibleConversion,
                .warn => w.outcome.safecrlf_warnings += 1,
            };
            return w.store(converted.bytes);
        }
        const bytes = try fs.readFileSized(a, w.io, w.wt, path, found.stat.size, 1 << 31);
        return w.store(bytes);
    }

    /// Put a blob where this pass puts them.
    fn store(w: *Walker, bytes: []const u8) Error!Oid {
        if (w.filling) |open| return w.db.writeInto(w.io, open, .blob, bytes);
        return w.db.write(w.io, .blob, bytes);
    }
};

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
pub fn writeTree(gpa: Allocator, io: Io, index: *Index, db: *Odb) Error!Oid {
    _ = gpa;
    const tree = try index.cacheTree();
    const oid = try tree.rebuild(io, index.entries.items, db);
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
    /// Set when the path is a gitlink in `HEAD` or in the index: the path is
    /// a submodule, and this is what its working tree holds. It is the `S<c><m><u>` field of
    /// `git status --porcelain=v2`, where every other path has `N...`.
    submodule: ?SubmoduleState = null,
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

/// What `status` asks of a populated submodule.
///
/// The working-tree layer cannot open another repository — that is the
/// layer above it — so the question goes through here.
/// `submodule.StatusProbe` answers it the way git does: it opens the
/// submodule, honours `submodule.<name>.ignore` and `diff.ignoreSubmodules`,
/// and runs a status inside, recursively.
pub const SubmoduleProbe = struct {
    context: *anyopaque,
    inspectFn: *const fn (context: *anyopaque, io: Io, path: []const u8, recorded: Oid) Error!SubmoduleState,
    /// Whether a gitlink whose index entry differs from `HEAD`'s is left out
    /// too. `--ignore-submodules=all` asks for that and no configured
    /// setting can: git always shows a staged submodule, so that one added
    /// by hand is not committed unseen.
    ignore_staged: bool = false,

    /// What the submodule at `path` holds, against the commit the index
    /// records for it, already filtered by what the settings ignore.
    pub fn inspect(p: SubmoduleProbe, io: Io, path: []const u8, recorded: Oid) Error!SubmoduleState {
        return p.inspectFn(p.context, io, path, recorded);
    }
};

/// What `status` found, sorted by path.
pub const Status = struct {
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

    /// How much of an untracked directory `status` reports: nothing, the
    /// directory itself, or every file under it. These are what `git status`
    /// takes in `--untracked-files`.
    pub const Untracked = enum { no, normal, all };
};

/// HEAD against the index against the working tree, as values.
///
/// Never as text: `XY path` is presentation, and a caller that wants it can
/// write two characters from these two enums.
pub fn status(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    options: StatusOptions,
) Error!Status {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var entries: std.StringArrayHashMapUnmanaged(StatusEntry) = .empty;

    // HEAD against the index. A sparse directory is a tree: where HEAD has
    // the same tree there, nothing under it differs and neither side is
    // flattened; where it does not, its files are flattened out of the
    // index's tree and compared one by one, as a full index would be.
    var sparse_dirs: std.StringHashMapUnmanaged(Oid) = .empty;
    for (index.entries.items) |entry| {
        if (entry.isSparseDirectory()) try sparse_dirs.put(arena, entry.path[0 .. entry.path.len - 1], entry.oid);
    }
    var head_paths: std.StringHashMapUnmanaged(TreeEntry) = .empty;
    if (options.head_tree) |tree_oid| {
        try flattenTree(arena, io, db, tree_oid, "", &head_paths, 0, &sparse_dirs);
    }
    var expanded: std.StringHashMapUnmanaged(TreeEntry) = .empty;
    for (index.entries.items) |entry| {
        if (!entry.isSparseDirectory()) continue;
        const dir = entry.path[0 .. entry.path.len - 1];
        if (options.head_tree) |head| {
            if (try treeAt(io, db, head, dir)) |at| {
                if (at.eql(entry.oid)) continue;
            }
        }
        try flattenTree(arena, io, db, entry.oid, dir, &expanded, 1, null);
    }
    var expanded_it = expanded.iterator();
    while (expanded_it.next()) |pair| {
        const staged = compareToHead(&head_paths, pair.key_ptr.*, pair.value_ptr.mode, pair.value_ptr.oid);
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
        if (options.submodules) |probe| {
            if (probe.ignore_staged) {
                const was_gitlink = if (head_paths.get(entry.path)) |e| e.mode == .gitlink else false;
                if (entry.mode == .gitlink or was_gitlink) continue;
            }
        }
        const staged = compareToHead(&head_paths, entry.path, entry.mode, entry.oid);
        if (staged == .unmodified) continue;
        const slot = try entries.getOrPut(arena, try arena.dupe(u8, entry.path));
        slot.value_ptr.* = .{
            .path = slot.key_ptr.*,
            .staged = staged,
            .unstaged = .unmodified,
        };
    }

    var head_it = head_paths.iterator();
    while (head_it.next()) |pair| {
        if (index.find(pair.key_ptr.*) != null or expanded.contains(pair.key_ptr.*)) continue;
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

    // The index against the working tree. A file whose stat changed is
    // compared through what it would be stored as, clean filter and all.
    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.kind,
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .index = index,
        .db = db,
    });
    defer conv.deinit();
    var scan: StatusScan = .{
        .gpa = gpa,
        .conv = &conv,
        .arena = arena,
        .io = io,
        .wt = wt,
        .index = index,
        .db = db,
        .options = options,
        .entries = &entries,
    };
    try scan.walk("", 0);

    for (index.entries.items) |entry| {
        if (entry.stage != 0 or entry.skip_worktree or entry.isSparseDirectory()) continue;
        if (scan.seen.contains(entry.path)) continue;
        const slot = try entries.getOrPut(arena, try arena.dupe(u8, entry.path));
        if (!slot.found_existing) {
            slot.value_ptr.* = .{ .path = slot.key_ptr.*, .staged = .unmodified, .unstaged = .unmodified };
        }
        slot.value_ptr.unstaged = .deleted;
    }
    scan.seen.deinit(gpa);

    // Only paths that differ somewhere are reported; an unchanged path is
    // absent, which is what makes the result the same shape as git's.
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
    std.mem.sort(StatusEntry, out, {}, lessThanStatus);

    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = out };
}

/// HEAD's side of one index path: what `status` calls a staged change.
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
        defer db.gpa.free(found.bytes);
        if (found.type != .tree) return null;
        const tree: object.Tree = .parse(db.kind, found.bytes);
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
    entries: *std.StringArrayHashMapUnmanaged(StatusEntry),
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// The files of the sparse directories the walk has met on the disk,
    /// which a full index would hold with `skip-worktree` set. In `arena`.
    sparse_files: std.StringHashMapUnmanaged(TreeEntry) = .empty,
    /// The sparse directories whose files are in `sparse_files`.
    sparse_loaded: std.StringHashMapUnmanaged(void) = .empty,

    /// Whether `path`, which no index entry names, is a file of a sparse
    /// directory, and so tracked and out of the working tree.
    fn inSparseDirectory(s: *StatusScan, path: []const u8) Error!bool {
        const dir_entry = sparseindex.containing(s.index, path) orelse return false;
        if (!s.sparse_loaded.contains(dir_entry.path)) {
            try s.sparse_loaded.put(s.arena, dir_entry.path, {});
            try flattenTree(s.arena, s.io, s.db, dir_entry.oid, dir_entry.path[0 .. dir_entry.path.len - 1], &s.sparse_files, 1, null);
        }
        return s.sparse_files.contains(path);
    }

    fn walk(s: *StatusScan, dir_path: []const u8, depth: u32) Error!void {
        if (depth > 64) return;
        const dir = if (dir_path.len == 0)
            s.wt
        else
            s.wt.openDir(s.io, dir_path, .{ .iterate = true }) catch return;
        defer if (dir_path.len != 0) dir.close(s.io);

        if (s.options.rules.ignore) |rules| try rules.addDirectory(s.io, s.wt, dir_path, depth);
        defer if (s.options.rules.ignore) |rules| rules.popTo(depth + 2);
        if (s.options.rules.attrs) |attrs| try attrs.addDirectory(s.io, s.wt, dir_path, depth);
        defer if (s.options.rules.attrs) |attrs| attrs.popTo(depth + 1);

        var scan = try dirscan.Scan.init(s.gpa, s.io, dir);
        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            const path = if (dir_path.len == 0)
                try s.arena.dupe(u8, item.name)
            else
                try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ dir_path, item.name });

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
                const as_directory = try std.fmt.allocPrint(s.arena, "{s}/", .{path});
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

            const change = try s.compare(entry_ptr, path, found);
            if (change != .unmodified) try s.record(path, change);
        }
    }

    fn excluded(s: *const StatusScan, path: []const u8, is_dir: bool) bool {
        const rules = s.options.rules.ignore orelse return false;
        return rules.match(path, is_dir).excluded;
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
            const child = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ path, item.name });
            if (item.kind == .directory) {
                try s.ignoredDirectory(child, try std.fmt.allocPrint(s.arena, "{s}/", .{child}), depth + 1);
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
        if (depth > 64) return false;
        if (s.options.rules.ignore) |rules| try rules.addDirectory(s.io, s.wt, path, depth);
        defer if (s.options.rules.ignore) |rules| rules.popTo(depth + 2);

        var names = try s.readNames(path);
        defer names.deinit(s.gpa);
        var untracked = false;
        for (names.items) |item| {
            const child = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ path, item.name });
            if (item.kind == .directory) {
                const as_directory = try std.fmt.allocPrint(s.arena, "{s}/", .{child});
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
        if (depth > 64) return false;
        var names = try s.readNames(path);
        defer names.deinit(s.gpa);
        for (names.items) |item| {
            if (item.kind == .file or item.kind == .sym_link) return true;
            if (item.kind != .directory) continue;
            const child = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ path, item.name });
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
        var dir = s.wt.openDir(s.io, path, .{ .iterate = true }) catch return out;
        defer dir.close(s.io);
        var scan = try dirscan.Scan.init(s.gpa, s.io, dir);
        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            try out.append(s.gpa, .{ .name = try s.arena.dupe(u8, item.name), .kind = item.entry.kind });
        }
        return out;
    }

    fn compare(s: *StatusScan, entry: *index_mod.Entry, path: []const u8, found: fs.Entry) Error!Change {
        const mode: object.Mode = if (found.kind == .sym_link)
            .symlink
        else if (s.options.rules.file_mode)
            (if (found.executable) .exec else .file)
        else if (entry.mode == .exec) .exec else .file;

        if (entry.mode.isBlob() != mode.isBlob() or
            (entry.mode == .symlink) != (mode == .symlink))
        {
            return .type_changed;
        }
        if (entry.mode != mode) return .modified;
        if (!s.index.isRacy(entry.*) and entry.stat.matches(found.stat, s.options.rules.check_stat, s.options.rules.timestamp_resolution)) {
            return .unmodified;
        }
        // The stat says it may have changed; the content says whether it
        // did. This is the racy rule doing its work.
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const content = if (found.kind == .sym_link) blk: {
            var buf: [4096]u8 = undefined;
            const len = try s.wt.readLink(s.io, path, &buf);
            break :blk try a.dupe(u8, buf[0..len]);
        } else if (s.options.rules.attrs) |attrs| blk: {
            const applied = try attrs.lookup(a, path, false);
            break :blk (try s.conv.toGitFile(a, path, found.stat.size, applied, .hash_only)).bytes;
        } else try s.wt.readFileAlloc(s.io, path, a, .limited(1 << 31));
        const oid = hash.Hasher.object(s.db.kind, "blob", content);
        if (oid.eql(entry.oid)) return .unmodified;
        return .modified;
    }

    /// A gitlink's directory is never walked. Its state is the probe's
    /// answer, or without one its `HEAD` against the recorded commit.
    fn inspectGitlink(s: *StatusScan, entry: *index_mod.Entry, path: []const u8) Error!void {
        if (entry.skip_worktree) return;
        const state: SubmoduleState = if (s.options.submodules) |probe|
            try probe.inspect(s.io, path, entry.oid)
        else blk: {
            const checked_out = try gitlink.head(s.gpa, s.io, s.wt, path, s.db.kind);
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
    if (depth > 64) return error.UnsupportedEntry;
    const found = try db.read(io, tree_oid);
    defer db.gpa.free(found.bytes);
    if (found.type != .tree) return error.UnsupportedEntry;
    const tree: object.Tree = .parse(db.kind, found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
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
) Error!std.StringHashMapUnmanaged(TreeEntry) {
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
) Error!ResetOutcome {
    var outcome: ResetOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // The tree is compared path by path, so a sparse index is made full
    // first; a caller that wants it sparse again collapses it.
    try sparseindex.expand(gpa, io, index, db, null);
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
            // the cached stat must not be trusted against it.
            entry.stat = .none;
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

    // The index now describes exactly this tree.
    const cache_tree = try index.cacheTree();
    cache_tree.invalidateAll();
    cache_tree.root.entry_count = @intCast(index.entries.items.len);
    cache_tree.root.oid = tree_oid;
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
    /// LFS files written as their pointer, because the object was not in
    /// the store. `CheckoutOptions.filter_report` names them.
    lfs_pointers: u32 = 0,
};

/// Where a refusal is written, so `error.UnsafePath` can say which path and
/// which rule without allocating.
pub const Refusal = struct {
    reason: ?safepath.Reason = null,
    buffer: [512]u8 = undefined,
    len: usize = 0,

    /// The path that was refused. Empty when nothing was.
    pub fn path(r: *const Refusal) []const u8 {
        return r.buffer[0..r.len];
    }

    fn set(r: *Refusal, reason: ?safepath.Reason, text: []const u8) void {
        r.reason = reason;
        r.len = @min(text.len, r.buffer.len);
        @memcpy(r.buffer[0..r.len], text[0..r.len]);
    }
};

/// How `checkout` behaves.
pub const CheckoutOptions = struct {
    rules: Rules = .{},
    /// Whether to remove a directory once the last file in it is removed.
    remove_empty_directories: bool = true,
    /// Where to write the path and the rule when a tree entry is refused.
    refusal: ?*Refusal = null,
    /// The permission to run the smudge filters `rules.filters` names.
    programs: ?program.Programs = null,
    /// Where filters passed over, and LFS files left as pointers, are
    /// reported.
    filter_report: ?*filter.Report = null,
    /// What fetches LFS objects the store does not have. It is called once,
    /// with all of them, after every other file is written.
    lfs_fetch: ?lfs.Fetcher = null,
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
    index: *Index,
    db: *Odb,
    tree_oid: Oid,
    options: CheckoutOptions,
) Error!CheckoutOutcome {
    var outcome: CheckoutOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // Every path of the tree is written, so a sparse index is made full
    // first, which is what this leaves behind anyway.
    try sparseindex.expand(gpa, io, index, db, null);
    var wanted = try flatten(arena, io, db, tree_oid);

    const attrs_before = if (options.rules.attrs) |attrs| attrs.levels.items.len else 0;
    const macros_before = if (options.rules.attrs) |attrs| attrs.macros.items.len else 0;
    defer if (options.rules.attrs) |attrs| {
        attrs.levels.shrinkRetainingCapacity(attrs_before);
        attrs.macros.shrinkRetainingCapacity(macros_before);
    };
    if (options.rules.attrs) |attrs| try addTreeAttributes(arena, io, db, attrs, &wanted);

    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.kind,
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .fetch = options.lfs_fetch,
    });
    defer conv.deinit();

    // Every path out of the tree is checked before it becomes a filesystem
    // path. A tree is a file format and anyone may write one.
    var check_it = wanted.keyIterator();
    while (check_it.next()) |path| {
        if (safepath.check(path.*, .worktree)) |refused| {
            if (options.refusal) |out| out.set(refused.reason, path.*);
            return error.UnsafePath;
        }
    }
    if (options.rules.ignore_case) {
        try refuseCaseCollisions(arena, &wanted);
    }

    // A directory-to-file transition is safe only when everything below the
    // directory is tracked and is about to leave the index. Prove that before
    // deleting any old entry, so an untracked file cannot turn a checkout
    // failure into a partially deleted working tree.
    var conflict_it = wanted.iterator();
    while (conflict_it.next()) |item| {
        if (item.value_ptr.mode == .gitlink) continue;
        if (try fs.statAt(io, wt, item.key_ptr.*)) |found| {
            if (found.kind == .directory and
                !try directoryIsReplaceable(arena, io, wt, item.key_ptr.*, index, &wanted))
            {
                return error.UntrackedWouldBeOverwritten;
            }
        }
    }

    // Remove what the index has and the tree does not.
    var removed_dirs: std.StringHashMapUnmanaged(void) = .empty;
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
        if (entry.mode == .gitlink) {
            // A submodule nobody populated leaves with its empty directory;
            // a populated one's directory stays where it is, as git leaves
            // it with a warning.
            wt.deleteDir(io, entry.path) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.DirNotEmpty => {},
                else => |e| return e,
            };
        } else fs.deleteFile(io, wt, entry.path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => {},
            else => |e| return e,
        };
        if (std.fs.path.dirnamePosix(entry.path)) |parent| {
            try removed_dirs.put(arena, try arena.dupe(u8, parent), {});
        }
        const tree = try index.cacheTree();
        tree.invalidate(entry.path);
        gpa.free(entry.path);
        _ = index.entries.orderedRemove(i);
        outcome.removed += 1;
    }

    // Write what the tree has.
    var paths = try arena.alloc([]const u8, wanted.count());
    var n: usize = 0;
    var key_it = wanted.keyIterator();
    while (key_it.next()) |key| {
        paths[n] = key.*;
        n += 1;
    }
    std.mem.sort([]const u8, paths, {}, lessThanName);

    // Tracked children have now gone. Remove the empty directories they
    // occupied before attempting the atomic file replacements.
    for (paths) |path| {
        const want = wanted.get(path).?;
        if (want.mode == .gitlink) continue;
        if (try fs.statAt(io, wt, path)) |found| {
            if (found.kind == .directory) try wt.deleteDir(io, path);
        }
    }

    for (paths) |path| {
        const want = wanted.get(path).?;
        const existing = index.find(path);
        const on_disk = try fs.statAt(io, wt, path);

        if (existing) |entry| {
            if (entry.oid.eql(want.oid) and entry.mode == want.mode and on_disk != null and
                !index.isRacy(entry.*) and entry.stat.matches(on_disk.?.stat, options.rules.check_stat, options.rules.timestamp_resolution))
            {
                outcome.unchanged += 1;
                continue;
            }
        }

        if (std.fs.path.dirnamePosix(path)) |parent| {
            wt.createDirPath(io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
        }

        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        switch (want.mode) {
            .gitlink => {
                wt.createDirPath(io, path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
                outcome.gitlinks += 1;
            },
            .symlink => {
                const found = try db.read(io, want.oid);
                defer gpa.free(found.bytes);
                fs.deleteFile(io, wt, path) catch {};
                if (options.rules.symlinks) {
                    wt.symLink(io, found.bytes, path, .{}) catch {
                        try writeFile(io, wt, path, .{ .bytes = found.bytes }, false);
                        outcome.symlinks_as_files += 1;
                    };
                } else {
                    try writeFile(io, wt, path, .{ .bytes = found.bytes }, false);
                    outcome.symlinks_as_files += 1;
                }
                outcome.written += 1;
            },
            .file, .exec => {
                const found = try db.read(io, want.oid);
                defer gpa.free(found.bytes);
                const executable = want.mode == .exec and options.rules.file_mode;
                if (options.rules.attrs) |attrs| {
                    const applied = try attrs.lookup(a, path, false);
                    const smudged = try conv.toWorktree(a, path, found.bytes, applied, .{
                        .blob = want.oid,
                        .treeish = tree_oid,
                        .can_delay = true,
                    });
                    // Its index entry is added when it arrives.
                    if (smudged == .delayed) continue;
                    try writeSmudged(io, wt, path, smudged, executable);
                } else {
                    try writeFile(io, wt, path, .{ .bytes = found.bytes }, executable);
                }
                outcome.written += 1;
            },
            .tree => return error.UnsupportedEntry,
        }
        try recordWritten(io, wt, index, path, want);
    }

    var late: std.heap.ArenaAllocator = .init(gpa);
    defer late.deinit();
    while (try conv.nextReady(late.allocator())) |ready| {
        defer _ = late.reset(.retain_capacity);
        const want = wanted.get(ready.path).?;
        try writeSmudged(io, wt, ready.path, ready.content, want.mode == .exec and options.rules.file_mode);
        outcome.written += 1;
        try recordWritten(io, wt, index, ready.path, want);
    }
    outcome.lfs_pointers = conv.lfs_pointers;

    if (options.remove_empty_directories) {
        var dir_it = removed_dirs.keyIterator();
        while (dir_it.next()) |dir_path| {
            removeEmptyDirectories(io, wt, dir_path.*);
        }
    }

    // The tree the index now describes is exactly the tree asked for, so
    // the cache tree may be told so rather than rebuilt.
    const tree = try index.cacheTree();
    tree.invalidateAll();
    tree.root.entry_count = @intCast(index.entries.items.len);
    tree.root.oid = tree_oid;

    return outcome;
}

/// Stat what was just written and put it in the index.
fn recordWritten(io: Io, wt: Io.Dir, index: *Index, path: []const u8, want: TreeEntry) Error!void {
    const after = try fs.statAt(io, wt, path);
    const tree = try index.cacheTree();
    tree.invalidate(path);
    try index.add(.{
        .path = path,
        .oid = want.oid,
        .mode = want.mode,
        .stat = if (after) |s| s.stat else .none,
    });
}

/// Put the tree's own `.gitattributes` files into `attrs`, each at the depth
/// its directory is at. The text lives in `arena`; the caller takes the
/// levels out again before the arena goes.
fn addTreeAttributes(
    arena: Allocator,
    io: Io,
    db: *Odb,
    attrs: *attributes.Attrs,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
) Error!void {
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
        defer db.gpa.free(found.bytes);
        const depth: u32 = if (base.len == 0) 0 else @intCast(std.mem.count(u8, base, "/") + 1);
        try attrs.addText(try arena.dupe(u8, found.bytes), base, path, depth + 1);
    }
}

fn writeSmudged(io: Io, wt: Io.Dir, path: []const u8, smudged: convert.Smudged, executable: bool) Error!void {
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
    index: *Index,
    db: *Odb,
    writes: []const PathWrite,
    options: CheckoutOptions,
) Error!CheckoutOutcome {
    var outcome: CheckoutOutcome = .{};
    defer if (options.rules.attrs) |attrs| attrs.leave();
    for (writes) |w| {
        if (safepath.check(w.path, .worktree)) |refused| {
            if (options.refusal) |out| out.set(refused.reason, w.path);
            return error.UnsafePath;
        }
    }

    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.kind,
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .fetch = options.lfs_fetch,
    });
    defer conv.deinit();

    for (writes) |w| {
        if (w.blob != null) continue;
        fs.deleteFile(io, wt, w.path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        };
        if (w.index) {
            const tree = try index.cacheTree();
            tree.invalidate(w.path);
            _ = index.remove(w.path);
        }
        outcome.removed += 1;
        if (options.remove_empty_directories) {
            if (std.fs.path.dirnamePosix(w.path)) |parent| removeEmptyDirectories(io, wt, parent);
        }
    }

    var waiting: std.StringHashMapUnmanaged(PathWrite) = .empty;
    defer waiting.deinit(gpa);
    for (writes) |w| {
        const want = w.blob orelse continue;
        if (try fs.statAt(io, wt, w.path)) |found| {
            // An empty directory gives way; one with anything in it is
            // someone's work.
            if (found.kind == .directory) wt.deleteDir(io, w.path) catch return error.UntrackedWouldBeOverwritten;
        }
        if (std.fs.path.dirnamePosix(w.path)) |parent| {
            wt.createDirPath(io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
        }
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        switch (want.mode) {
            .gitlink => {
                wt.createDirPath(io, w.path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
                outcome.gitlinks += 1;
            },
            .symlink => {
                const found = try db.read(io, want.oid);
                defer gpa.free(found.bytes);
                fs.deleteFile(io, wt, w.path) catch {};
                if (options.rules.symlinks) {
                    wt.symLink(io, found.bytes, w.path, .{}) catch {
                        try writeFile(io, wt, w.path, .{ .bytes = found.bytes }, false);
                        outcome.symlinks_as_files += 1;
                    };
                } else {
                    try writeFile(io, wt, w.path, .{ .bytes = found.bytes }, false);
                    outcome.symlinks_as_files += 1;
                }
                outcome.written += 1;
            },
            .file, .exec => {
                const found = try db.read(io, want.oid);
                defer gpa.free(found.bytes);
                const executable = want.mode == .exec and options.rules.file_mode;
                if (options.rules.attrs) |attrs| {
                    try attrs.enter(io, wt, w.path);
                    const applied = try attrs.lookup(a, w.path, false);
                    const smudged = try conv.toWorktree(a, w.path, found.bytes, applied, .{
                        .blob = want.oid,
                        .can_delay = true,
                    });
                    if (smudged == .delayed) {
                        try waiting.put(gpa, w.path, w);
                        continue;
                    }
                    try writeSmudged(io, wt, w.path, smudged, executable);
                } else {
                    try writeFile(io, wt, w.path, .{ .bytes = found.bytes }, executable);
                }
                if (options.rules.attrs) |attrs| attrs.written(w.path);
                outcome.written += 1;
            },
            .tree => return error.UnsupportedEntry,
        }
        if (w.index) try recordWritten(io, wt, index, w.path, .{ .mode = want.mode, .oid = want.oid });
    }

    var late: std.heap.ArenaAllocator = .init(gpa);
    defer late.deinit();
    while (try conv.nextReady(late.allocator())) |ready| {
        defer _ = late.reset(.retain_capacity);
        const w = waiting.get(ready.path).?;
        const want = w.blob.?;
        try writeSmudged(io, wt, w.path, ready.content, want.mode == .exec and options.rules.file_mode);
        outcome.written += 1;
        if (w.index) try recordWritten(io, wt, index, w.path, .{ .mode = want.mode, .oid = want.oid });
    }
    outcome.lfs_pointers = conv.lfs_pointers;
    return outcome;
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
/// line endings converted as the attributes say, the executable bit set
/// where the filesystem keeps one, a symlink made or written as a file
/// holding its target, a gitlink made as an empty directory. Whatever is at
/// `path` is replaced; the directories above it are made.
pub fn writeEntry(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    db: *Odb,
    path: []const u8,
    mode: object.Mode,
    oid: Oid,
    rules: Rules,
) Error!Written {
    if (safepath.check(path, .worktree) != null) return error.UnsafePath;
    if (std.fs.path.dirnamePosix(path)) |parent| {
        wt.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    var written: Written = .{ .stat = .none };
    switch (mode) {
        .gitlink => {
            wt.createDirPath(io, path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
        },
        .symlink => {
            const found = try db.read(io, oid);
            defer gpa.free(found.bytes);
            wt.deleteFile(io, path) catch {};
            if (rules.symlinks) {
                wt.symLink(io, found.bytes, path, .{}) catch {
                    try writeFile(io, wt, path, .{ .bytes = found.bytes }, false);
                    written.symlink_as_file = true;
                };
            } else {
                try writeFile(io, wt, path, .{ .bytes = found.bytes }, false);
                written.symlink_as_file = true;
            }
        },
        .file, .exec => {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            const found = try db.read(io, oid);
            defer gpa.free(found.bytes);
            var bytes: []const u8 = found.bytes;
            if (rules.attrs) |attrs| {
                const applied = try attrs.lookup(a, path, false);
                if (attributes.unsupported(applied, rules.required_filters)) |_| {
                    return error.UnsupportedAttribute;
                }
                const converted = try attributes.toWorktree(a, found.bytes, applied, rules.core);
                bytes = converted.bytes;
            }
            try writeFile(io, wt, path, .{ .bytes = bytes }, mode == .exec and rules.file_mode);
        },
        .tree => return error.UnsupportedEntry,
    }
    if (try fs.statAt(io, wt, path)) |after| written.stat = after.stat;
    return written;
}

/// Remove one file from the working tree, and every directory above it that
/// it leaves empty. A file that is already gone is not an error.
pub fn removeEntry(io: Io, wt: Io.Dir, path: []const u8) Error!void {
    if (safepath.check(path, .worktree) != null) return error.UnsafePath;
    wt.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        error.IsDir => wt.deleteDir(io, path) catch {},
        else => |e| return e,
    };
    if (std.fs.path.dirnamePosix(path)) |parent| removeEmptyDirectories(io, wt, parent);
}

fn directoryIsReplaceable(
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    dir_path: []const u8,
    index: *const Index,
    wanted: *const std.StringHashMapUnmanaged(TreeEntry),
) Error!bool {
    var dir = try wt.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, item.name });
        if (item.kind == .directory) {
            if (!try directoryIsReplaceable(arena, io, wt, path, index, wanted)) return false;
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
    const dir_path = std.fs.path.dirnamePosix(path);
    var temp_path_buf: [4096]u8 = undefined;
    const temp_path = if (dir_path) |parent|
        std.fmt.bufPrint(&temp_path_buf, "{s}/{s}", .{ parent, temp_name }) catch return error.UnsafePath
    else
        temp_name;

    const file = try wt.createFile(io, temp_path, .{
        .exclusive = true,
        .permissions = fs.permissionsFor(executable),
    });
    var failed = true;
    defer if (failed) {
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
        if (Io.File.Permissions.has_executable_bit) {
            file.setPermissions(io, fs.permissionsFor(executable)) catch {};
        }
    }
    try fs.renameWithRetry(io, wt, temp_path, path);
    failed = false;
}

fn removeEmptyDirectories(io: Io, wt: Io.Dir, path: []const u8) void {
    var current = path;
    while (current.len != 0) {
        wt.deleteDir(io, current) catch return;
        current = std.fs.path.dirnamePosix(current) orelse return;
    }
}

/// What `applySparse` changed.
pub const SparseOutcome = struct {
    /// Entries that left the working tree.
    skipped: u32 = 0,
    /// Entries that came back into it.
    restored: u32 = 0,
    /// Entries left alone because the file on the disk does not match the
    /// index, so removing it would lose work.
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
/// that returns loses the flag and its file is written. A file whose
/// content differs from the index is left where it is and counted, because
/// removing it would throw away work nobody asked to throw away; and a
/// returning path where something is already on the disk is not written
/// over, for the same reason, which is git's rule for both.
pub fn applySparse(
    gpa: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    patterns: *const sparse.Patterns,
    options: CheckoutOptions,
) Error!SparseOutcome {
    var outcome: SparseOutcome = .{};
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var conv: convert.Session = .init(gpa, io, .{
        .wt = wt,
        .kind = db.kind,
        .core = options.rules.core,
        .required_filters = options.rules.required_filters,
        .drivers = options.rules.filters,
        .programs = options.programs,
        .report = options.filter_report,
        .index = index,
        .db = db,
    });
    defer conv.deinit();
    defer if (options.rules.attrs) |attrs| attrs.leave();

    // A sparse index is expanded as far as the new patterns reach into it,
    // which for a cone is the directories it now includes and for anything
    // else is everything. What stays collapsed stays out.
    if (index.sparse) try sparseindex.expand(gpa, io, index, db, patterns);

    for (index.entries.items) |*entry| {
        if (entry.stage != 0 or entry.isSparseDirectory()) continue;
        const included = patterns.includes(entry.path, false);
        if (!included and !entry.skip_worktree) {
            if (try fs.statAt(io, wt, entry.path)) |found| {
                const must_check_content = index.isRacy(entry.*) or
                    !entry.stat.matches(found.stat, options.rules.check_stat, options.rules.timestamp_resolution);
                if (must_check_content) {
                    _ = scratch.reset(.retain_capacity);
                    const a = scratch.allocator();
                    const raw = if (found.kind == .sym_link) blk: {
                        var buf: [4096]u8 = undefined;
                        const len = try wt.readLink(io, entry.path, &buf);
                        break :blk try a.dupe(u8, buf[0..len]);
                    } else try fs.readFileSized(a, io, wt, entry.path, found.stat.size, 1 << 31);
                    var content: []const u8 = raw;
                    if (options.rules.attrs) |attrs| {
                        if (found.kind != .sym_link) {
                            try attrs.enter(io, wt, entry.path);
                            const applied = try attrs.lookup(a, entry.path, false);
                            content = (try conv.toGit(a, entry.path, raw, applied, .hash_only)).bytes;
                        }
                    }
                    if (!hash.Hasher.object(db.kind, "blob", content).eql(entry.oid)) {
                        outcome.kept_dirty += 1;
                        continue;
                    }
                }
                fs.deleteFile(io, wt, entry.path) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.IsDir => {},
                    else => |e| return e,
                };
                if (options.remove_empty_directories) {
                    if (std.fs.path.dirnamePosix(entry.path)) |parent| {
                        removeEmptyDirectories(io, wt, parent);
                    }
                }
            }
            entry.skip_worktree = true;
            outcome.skipped += 1;
            continue;
        }
        if (included and entry.skip_worktree) {
            if (safepath.check(entry.path, .worktree) != null) {
                if (options.refusal) |out| out.set(.git_directory, entry.path);
                return error.UnsafePath;
            }
            if (try fs.statAt(io, wt, entry.path)) |_| {
                entry.skip_worktree = false;
                outcome.already_present += 1;
                continue;
            }
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            if (std.fs.path.dirnamePosix(entry.path)) |parent| {
                wt.createDirPath(io, parent) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
            }
            const found = try db.read(io, entry.oid);
            defer gpa.free(found.bytes);
            const executable = entry.mode == .exec and options.rules.file_mode;
            if (options.rules.attrs) |attrs| {
                try attrs.enter(io, wt, entry.path);
                const applied = try attrs.lookup(a, entry.path, false);
                const smudged = try conv.toWorktree(a, entry.path, found.bytes, applied, .{ .blob = entry.oid });
                try writeSmudged(io, wt, entry.path, smudged, executable);
            } else {
                try writeFile(io, wt, entry.path, .{ .bytes = found.bytes }, executable);
            }
            if (try fs.statAt(io, wt, entry.path)) |after| entry.stat = after.stat;
            entry.skip_worktree = false;
            outcome.restored += 1;
        }
    }
    return outcome;
}

/// What `list` found.
pub const Listing = struct {
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
) Error!Listing {
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
        if (depth > 64) return;
        const dir = if (dir_path.len == 0)
            s.wt
        else
            s.wt.openDir(s.io, dir_path, .{ .iterate = true }) catch return;
        defer if (dir_path.len != 0) dir.close(s.io);

        if (s.rules.ignore) |rules| try rules.addDirectory(s.io, s.wt, dir_path, depth);
        defer if (s.rules.ignore) |rules| rules.popTo(depth + 2);

        var scan = try dirscan.Scan.init(s.gpa, s.io, dir);
        defer scan.deinit();
        while (try scan.next()) |item| {
            if (std.mem.eql(u8, item.name, ".git")) continue;
            const path = if (dir_path.len == 0)
                try s.arena.dupe(u8, item.name)
            else
                try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ dir_path, item.name });
            const found = item.entry;
            if (found.kind == .directory) {
                // A submodule's directory is its own repository's to list.
                if (s.index.find(path)) |entry| {
                    if (entry.mode == .gitlink) continue;
                }
                if (!s.index.hasDirectory(path)) {
                    if (s.rules.ignore) |rules| {
                        if (rules.match(path, true).excluded) continue;
                    }
                    // A repository inside the working tree is its own to
                    // list: git names it once, as `sub/`.
                    if (try gitlink.isRepository(s.gpa, s.io, s.wt, path)) {
                        try s.out.append(s.arena, try std.fmt.allocPrint(s.arena, "{s}/", .{path}));
                        continue;
                    }
                }
                if (s.index.sparse) {
                    const as_dir = try std.fmt.allocPrint(s.arena, "{s}/", .{path});
                    if (s.index.find(as_dir)) |entry| {
                        if (entry.isSparseDirectory()) continue;
                    }
                }
                try s.walk(path, depth + 1);
                continue;
            }
            if (s.index.find(path) != null) continue;
            if (s.rules.ignore) |rules| {
                if (rules.match(path, false).excluded) continue;
            }
            try s.out.append(s.arena, path);
        }
    }
};
