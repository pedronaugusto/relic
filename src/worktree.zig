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
    /// The same path appeared twice with different case on a filesystem
    /// that folds case, so one would silently overwrite the other.
    CaseCollision,
} || Allocator.Error || odb_mod.Error || index_mod.ReadError ||
    index_mod.WriteError || fs.StatError || Io.Dir.Iterator.Error ||
    Io.Dir.OpenError || Io.Dir.DeleteFileError || Io.Dir.DeleteDirError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.SymLinkError ||
    Io.Dir.ReadLinkError || Io.Writer.Error || Io.File.SyncError ||
    Io.File.SetPermissionsError || object.Tree.Builder.AddError ||
    object.TreeParseError;

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
    /// Filter names whose `filter.<name>.required` is true.
    required_filters: []const []const u8 = &.{},
    /// Whether the filesystem folds case, from `core.ignoreCase`.
    ignore_case: bool = false,
    /// How much of a cached stat to believe, from `core.checkStat`.
    check_stat: fs.Stat.Check = .full,
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
    /// Directories holding their own `.git`, which are neither descended
    /// into nor staged unless the index already has a gitlink for them.
    nested_repositories: u32 = 0,
    /// Paths the working tree holds that a tree must never carry — a name
    /// that reaches `.git` on some filesystem, a DOS device name, a
    /// component ending in a dot or a space. They are skipped rather than
    /// staged, and counted here so a caller can say so.
    unsafe_paths: u32 = 0,
};

/// How `addAll` behaves.
pub const AddOptions = struct {
    rules: Rules = .{},
    /// Whether to stage deletions for index entries whose file is gone.
    /// `git add -A` does; `git add .` without `-A` does not.
    stage_deletions: bool = true,
    /// Whether to stop at the first unreadable file or to skip it, which is
    /// what `--ignore-errors` asks for.
    ignore_errors: bool = false,
    /// A path prefix to limit the walk to, `/`-separated. Empty walks the
    /// whole tree.
    prefix: []const u8 = "",
};

/// `git add -A`: walk the working tree, stage what changed, stage deletions,
/// and keep the cache tree true.
///
/// The stat shortcut is what makes a warm call cheap: an entry whose
/// recorded stat still matches the file is neither opened nor hashed. git's
/// racy rule is what keeps it correct: an entry whose modification time is
/// not older than the index's own is read anyway, because a file rewritten
/// inside one second without changing size is invisible to a stat.
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

    var walker: Walker = .{
        .gpa = gpa,
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
    };
    try walker.walk(options.prefix, 0);
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
            if (!under_prefix or entry.skip_worktree or seen.contains(entry.path)) continue;
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

        // The names are collected first so the directory handle is not held
        // open across the work each entry causes, which matters on Windows.
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| w.gpa.free(name);
            names.deinit(w.gpa);
        }
        var it = dir.iterate();
        while (try it.next(w.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            try names.append(w.gpa, try w.gpa.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThanName);

        for (names.items) |name| {
            const path = if (dir_path.len == 0)
                try w.gpa.dupe(u8, name)
            else
                try std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ dir_path, name });
            defer w.gpa.free(path);

            const found = (try fs.statAt(w.io, w.wt, path)) orelse continue;
            switch (found.kind) {
                .directory => try w.enterDirectory(path, depth, found),
                .sym_link, .file => try w.stageFile(path, found),
                // A socket, a fifo or a device is not something a tree can
                // hold, and git skips it silently.
                else => {},
            }
        }
    }

    fn enterDirectory(w: *Walker, path: []const u8, depth: u32, found: fs.Entry) Error!void {
        _ = found;
        // A directory holding its own `.git` is another repository. git
        // stages it as a gitlink only if the index already has one, and
        // never walks into it.
        var dot_git_buf: [4096]u8 = undefined;
        const dot_git = std.fmt.bufPrint(&dot_git_buf, "{s}/.git", .{path}) catch return;
        var nested = false;
        if (w.wt.statFile(w.io, dot_git, .{})) |_| {
            nested = true;
        } else |_| {}

        if (nested) {
            w.outcome.nested_repositories += 1;
            if (w.index.find(path)) |entry| {
                if (entry.mode == .gitlink) {
                    try w.markSeen(path);
                    w.outcome.unchanged += 1;
                }
            }
            return;
        }

        if (w.options.rules.ignore) |rules| {
            const decided = rules.match(path, true);
            // An excluded directory is not entered at all, so a negation
            // inside it cannot bring anything back — which is git's rule.
            if (decided.excluded and !w.index.hasDirectory(path)) return;
        }
        try w.walk(path, depth + 1);
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
                entry.stat.matches(found.stat, w.options.rules.check_stat))
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
            return w.db.write(w.io, .blob, buf[0..len]);
        }

        const bytes = try w.wt.readFileAlloc(w.io, path, a, .limited(1 << 31));
        if (w.options.rules.attrs) |attrs| {
            const applied = try attrs.lookup(a, path, false);
            if (attributes.unsupported(applied, w.options.rules.required_filters)) |_| {
                return error.UnsupportedAttribute;
            }
            const converted = try attributes.toGit(a, bytes, applied, w.options.rules.core);
            return w.db.write(w.io, .blob, converted.bytes);
        }
        return w.db.write(w.io, .blob, bytes);
    }
};

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
    /// Owned by the `Status`.
    path: []const u8,
    /// HEAD against the index.
    staged: Change,
    /// The index against the working tree.
    unstaged: Change,
    /// Set when the path has entries at stages 1 to 3.
    conflicted: bool = false,
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
    /// holding only untracked files once, by its name.
    untracked: Untracked = .all,
    /// Whether to list ignored files too.
    include_ignored: bool = false,

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

    // HEAD against the index.
    var head_paths: std.StringHashMapUnmanaged(TreeEntry) = .empty;
    if (options.head_tree) |tree_oid| {
        try flattenTree(arena, io, db, tree_oid, "", &head_paths, 0);
    }

    for (index.entries.items) |entry| {
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
        const staged: Change = blk: {
            const in_head = head_paths.get(entry.path) orelse break :blk .added;
            if (!in_head.oid.eql(entry.oid)) break :blk .modified;
            if (in_head.mode != entry.mode) break :blk if (in_head.mode.isBlob() == entry.mode.isBlob())
                .modified
            else
                .type_changed;
            break :blk .unmodified;
        };
        const slot = try entries.getOrPut(arena, try arena.dupe(u8, entry.path));
        slot.value_ptr.* = .{
            .path = slot.key_ptr.*,
            .staged = staged,
            .unstaged = .unmodified,
        };
    }

    var head_it = head_paths.iterator();
    while (head_it.next()) |pair| {
        if (index.find(pair.key_ptr.*) != null) continue;
        const slot = try entries.getOrPut(arena, pair.key_ptr.*);
        slot.value_ptr.* = .{
            .path = slot.key_ptr.*,
            .staged = .deleted,
            .unstaged = .unmodified,
        };
    }

    // The index against the working tree.
    var scan: StatusScan = .{
        .gpa = gpa,
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
        if (entry.stage != 0 or entry.skip_worktree) continue;
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
        i += 1;
    }
    std.mem.sort(StatusEntry, out, {}, lessThanStatus);

    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = out };
}

fn lessThanStatus(_: void, a: StatusEntry, b: StatusEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const StatusScan = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    db: *Odb,
    options: StatusOptions,
    entries: *std.StringArrayHashMapUnmanaged(StatusEntry),
    seen: std.StringHashMapUnmanaged(void) = .empty,

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

        var it = dir.iterate();
        while (try it.next(s.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            const path = if (dir_path.len == 0)
                try s.arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ dir_path, entry.name });

            const found = (try fs.statAt(s.io, s.wt, path)) orelse continue;
            if (found.kind == .directory) {
                const tracked_below = s.index.hasDirectory(path);
                if (s.options.rules.ignore) |rules| {
                    const decided = rules.match(path, true);
                    if (decided.excluded and !tracked_below) {
                        if (s.options.include_ignored) try s.record(path, .ignored);
                        continue;
                    }
                }
                var nested_git: bool = false;
                if (s.wt.statFile(s.io, try std.fmt.allocPrint(s.arena, "{s}/.git", .{path}), .{})) |_| {
                    nested_git = true;
                } else |_| {}
                if (nested_git) {
                    if (s.index.find(path) == null and s.options.untracked != .no) {
                        try s.record(path, .untracked);
                    }
                    continue;
                }
                try s.walk(path, depth + 1);
                continue;
            }

            const tracked = s.index.find(path);
            if (tracked == null) {
                if (s.options.rules.ignore) |rules| {
                    if (rules.match(path, false).excluded) {
                        if (s.options.include_ignored) try s.record(path, .ignored);
                        continue;
                    }
                }
                if (s.options.untracked != .no) try s.record(path, .untracked);
                continue;
            }
            const entry_ptr = tracked.?;
            try s.seen.put(s.gpa, entry_ptr.path, {});
            if (entry_ptr.skip_worktree or entry_ptr.assume_valid) continue;

            const change = try s.compare(entry_ptr, path, found);
            if (change != .unmodified) try s.record(path, change);
        }
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
        if (!s.index.isRacy(entry.*) and entry.stat.matches(found.stat, s.options.rules.check_stat)) {
            return .unmodified;
        }
        // The stat says it may have changed; the content says whether it
        // did. This is the racy rule doing its work.
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const bytes = if (found.kind == .sym_link) blk: {
            var buf: [4096]u8 = undefined;
            const len = try s.wt.readLink(s.io, path, &buf);
            break :blk try a.dupe(u8, buf[0..len]);
        } else try s.wt.readFileAlloc(s.io, path, a, .limited(1 << 31));

        var content: []const u8 = bytes;
        if (s.options.rules.attrs) |attrs| {
            if (found.kind != .sym_link) {
                const applied = try attrs.lookup(a, path, false);
                const converted = try attributes.toGit(a, bytes, applied, s.options.rules.core);
                content = converted.bytes;
            }
        }
        const oid = hash.Hasher.object(s.db.kind, "blob", content);
        if (oid.eql(entry.oid)) return .unmodified;
        return .modified;
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
const TreeEntry = struct { mode: object.Mode, oid: Oid };

fn flattenTree(
    arena: Allocator,
    io: Io,
    db: *Odb,
    tree_oid: Oid,
    prefix: []const u8,
    out: *std.StringHashMapUnmanaged(TreeEntry),
    depth: u32,
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
            try flattenTree(arena, io, db, entry.oid, path, out, depth + 1);
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
    try flattenTree(arena, io, db, tree_oid, "", &out, 0);
    return out;
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

    fn set(r: *Refusal, reason: safepath.Reason, text: []const u8) void {
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
};

/// `read-tree --reset -u`: make the working tree and the index match `tree`.
///
/// Files the index has and the tree does not are removed; files whose
/// content or mode differ are rewritten; untracked and ignored files are
/// left exactly as they are. Nothing about `HEAD` moves: a caller that wants
/// a branch moved does that with a ref transaction, which is a separate
/// decision from what is on the disk.
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

    var wanted = try flatten(arena, io, db, tree_oid);

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
        wt.deleteFile(io, entry.path) catch |err| switch (err) {
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

    for (paths) |path| {
        const want = wanted.get(path).?;
        const existing = index.find(path);
        const on_disk = try fs.statAt(io, wt, path);

        if (existing) |entry| {
            if (entry.oid.eql(want.oid) and entry.mode == want.mode and on_disk != null and
                !index.isRacy(entry.*) and entry.stat.matches(on_disk.?.stat, options.rules.check_stat))
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
                wt.deleteFile(io, path) catch {};
                if (options.rules.symlinks) {
                    wt.symLink(io, found.bytes, path, .{}) catch {
                        try writeFile(io, wt, path, found.bytes, false);
                        outcome.symlinks_as_files += 1;
                    };
                } else {
                    try writeFile(io, wt, path, found.bytes, false);
                    outcome.symlinks_as_files += 1;
                }
                outcome.written += 1;
            },
            .file, .exec => {
                const found = try db.read(io, want.oid);
                defer gpa.free(found.bytes);
                var bytes: []const u8 = found.bytes;
                if (options.rules.attrs) |attrs| {
                    const applied = try attrs.lookup(a, path, false);
                    if (attributes.unsupported(applied, options.rules.required_filters)) |_| {
                        return error.UnsupportedAttribute;
                    }
                    const converted = try attributes.toWorktree(a, found.bytes, applied, options.rules.core);
                    bytes = converted.bytes;
                }
                try writeFile(io, wt, path, bytes, want.mode == .exec and options.rules.file_mode);
                outcome.written += 1;
            },
            .tree => return error.UnsupportedEntry,
        }

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

fn writeFile(io: Io, wt: Io.Dir, path: []const u8, bytes: []const u8, executable: bool) Error!void {
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
        try fw.interface.writeAll(bytes);
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
};

/// Make the working tree hold exactly the paths the sparse patterns
/// include.
///
/// A path that leaves gets `skip-worktree` and its file is removed; a path
/// that returns loses the flag and its file is written. A file whose
/// content differs from the index is left where it is and counted, because
/// removing it would throw away work nobody asked to throw away.
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

    for (index.entries.items) |*entry| {
        if (entry.stage != 0) continue;
        const included = patterns.includes(entry.path, false);
        if (!included and !entry.skip_worktree) {
            if (try fs.statAt(io, wt, entry.path)) |found| {
                if (!entry.stat.matches(found.stat, options.rules.check_stat)) {
                    outcome.kept_dirty += 1;
                    continue;
                }
                wt.deleteFile(io, entry.path) catch |err| switch (err) {
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
            var bytes: []const u8 = found.bytes;
            if (options.rules.attrs) |attrs| {
                const applied = try attrs.lookup(a, entry.path, false);
                const converted = try attributes.toWorktree(a, found.bytes, applied, options.rules.core);
                bytes = converted.bytes;
            }
            try writeFile(io, wt, entry.path, bytes, entry.mode == .exec and options.rules.file_mode);
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

/// The index's paths plus the untracked ones, with the ignore rules applied.
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

        var it = dir.iterate();
        while (try it.next(s.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            const path = if (dir_path.len == 0)
                try s.arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ dir_path, entry.name });
            const found = (try fs.statAt(s.io, s.wt, path)) orelse continue;
            if (found.kind == .directory) {
                if (s.rules.ignore) |rules| {
                    if (rules.match(path, true).excluded and !s.index.hasDirectory(path)) continue;
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
