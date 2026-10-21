//! git's `mv` (`builtin/mv.c`): files, directories and submodules renamed
//! in the working tree and the index together, a submodule's `.gitmodules`
//! path and `.git` file following it, after every source has been checked
//! the way git checks it.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const repo_mod = @import("../repo/repo.zig");
const index_mod = @import("../index/index.zig");
const sparse_index = @import("../index/sparse_index.zig");
const checkout = @import("../checkout/checkout.zig");
const fs = @import("../fs/fs.zig");
const patterns = @import("../patterns.zig");
const pathspec_mod = patterns.pathspec;
const sparse = patterns.sparse;
const sparse_checkout = @import("../worktree/sparse_checkout.zig");
const submodule = @import("../submodule/submodule.zig");
const Repository = repo_mod.Repository;
const Index = index_mod.Index;

/// What `move` is asked: `git mv`'s operands and options.
pub const Options = struct {
    /// What moves, as git reads each at the top of the working tree.
    sources: []const []const u8,
    /// Where: the new name of a single source, or a directory the sources
    /// move into.
    destination: []const u8,
    /// `-f`: a file in the way is overwritten.
    force: bool = false,
    /// `-k`: a source git would refuse is passed over, and the rest move.
    skip_errors: bool = false,
    /// `-n`: report what would move, and move nothing.
    dry_run: bool = false,
    /// `--sparse`: entries outside the sparse-checkout cone may move too.
    sparse: bool = false,
};

/// Why git refuses a source: each of `mv`'s "%s, source=%s,
/// destination=%s" messages, and the two it dies with on its own.
pub const Reason = enum {
    /// "bad source": neither on the disk nor in the index.
    bad_source,
    /// "can not move directory into itself".
    into_itself,
    /// "destination already exists" (a directory) or "destination exists".
    destination_exists,
    /// "Cannot overwrite": under `force`, something other than a file.
    cannot_overwrite,
    /// "source directory is empty": no entry under it.
    source_empty,
    /// "not under version control".
    not_tracked,
    /// "conflicted".
    conflicted,
    /// "multiple sources for the same target".
    multiple_sources,
    /// "destination directory does not exist".
    destination_directory_missing,
    /// "destination exists in the index", outside the cone under `sparse`.
    destination_in_index,
    /// "destination '%s' is not a directory": several sources and a
    /// destination that is not one. `source` is empty.
    not_a_directory,
    /// "cannot move both '%s' and its parent directory '%s'": `source` is
    /// the path, `destination` the directory.
    with_parent,
};

/// A source git refuses, and where it was to go.
pub const Refusal = struct { reason: Reason, source: []const u8, destination: []const u8 };

/// One rename: git's "Renaming %s to %s".
pub const Rename = struct { source: []const u8, destination: []const u8 };

/// What `move` did, or refused. Release it with `deinit`.
pub const Outcome = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator,
    /// What moved, or under `dry_run` would, in git's order: each source,
    /// then for a directory each entry under it.
    renamed: []const Rename = &.{},
    /// The refusal that stopped the move before anything changed.
    refusal: ?Refusal = null,
    /// Under `skip_errors`, the sources passed over.
    skipped: []const Refusal = &.{},
    /// Paths outside the sparse-checkout cone, which only `sparse` moves:
    /// git's advice to use `--sparse`. Without `skip_errors` nothing moved,
    /// and git exits 1.
    sparse_only: []const []const u8 = &.{},
    /// Files moved out of the cone with local changes, which stay on the
    /// disk: git's advice on moving a dirty path.
    dirty: []const []const u8 = &.{},
    stopped_on_sparse: bool = false,

    /// Whether git would fail: a refusal, or paths outside the cone
    /// without `skip_errors`.
    pub fn refused(o: *const Outcome) bool {
        return o.refusal != null or o.stopped_on_sparse;
    }

    pub fn deinit(o: *Outcome) void {
        o.arena.deinit();
        o.* = undefined;
    }
};

/// Failures of `move`.
pub const Error = repo_mod.Error || Repository.LockIndexError || Repository.WriteIndexError || checkout.Error || pathspec_mod.Error ||
    submodule.Error || sparse_index.Error || sparse.Error || sparse_checkout.Error || fs.StatError || Io.Dir.RenameError ||
    Io.Dir.CreateDirPathError || error{
    /// No source: git's usage message.
    NoSource,
    /// A submodule among the sources while `.gitmodules` has changes not
    /// staged: git's "please stage your changes to .gitmodules".
    GitmodulesNotStaged,
    /// A directory the index holds as an entry that is not a gitlink:
    /// git's "Directory %s is in index and no submodule?".
    DirectoryNotSubmodule,
};

/// What each source is moved as: git's `update_mode`.
const Mode = packed struct {
    working_directory: bool = false,
    index: bool = false,
    sparse: bool = false,
    skip_worktree_dir: bool = false,
    move_via_parent_dir: bool = false,
};

const Gitfile = union(enum) {
    /// The submodule's `.git` is a directory of its own.
    with_git_dir,
    /// The git directory its `.git` file names, absolute.
    path: []const u8,
};

const Item = struct { source: []const u8, destination: []const u8, mode: Mode = .{}, gitfile: ?Gitfile = null };

/// git's `mv`.
pub fn move(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    if (options.sources.len == 0) return error.NoSource;
    var outcome: Outcome = .{ .arena = .init(gpa) };
    errdefer outcome.deinit();
    const wt = repo.workDirectory() orelse return error.BareRepository;
    const ignore_case = repo.settings().ignore_case;

    var locked = try repo.lockIndex(io);
    defer locked.deinit(io);
    try sparse_index.expand(gpa, io, &locked.index, repo.objectDatabase(), null);

    const settings = try sparse_checkout.settings(io, repo);
    var cone_patterns: ?sparse.Patterns = if (settings.enabled)
        try sparse.Patterns.load(gpa, io, repo.gitDirectory(), .{ .case_fold = ignore_case, .cone = settings.cone })
    else
        null;
    defer if (cone_patterns) |*p| p.deinit();

    var mover: Mover = .{
        .gpa = gpa,
        .io = io,
        .repo = repo,
        .wt = wt,
        .index = &locked.index,
        .arena = outcome.arena.allocator(),
        .options = options,
        .cone = .{ .patterns = if (cone_patterns) |*p| p else null },
        .cone_mode = settings.enabled and settings.cone,
        .ignore_case = ignore_case,
        .outcome = &outcome,
    };
    if (try mover.place()) |refusal| {
        outcome.refusal = refusal;
        return outcome;
    }
    if (try mover.check()) |refusal| {
        outcome.refusal = refusal;
        return outcome;
    }
    if (mover.parentAndChild()) |refusal| {
        outcome.refusal = refusal;
        return outcome;
    }
    if (outcome.sparse_only.len != 0 and !options.skip_errors) {
        outcome.stopped_on_sparse = true;
        return outcome;
    }
    if (options.dry_run) {
        var renamed: std.ArrayList(Rename) = .empty;
        for (mover.items.items) |item| try renamed.append(mover.arena, .{ .source = item.source, .destination = item.destination });
        outcome.renamed = renamed.items;
        return outcome;
    }
    try mover.apply();
    try locked.commit(io);
    return outcome;
}

/// One `mv`, between its phases: where each source goes, the checks, and
/// the moves.
const Mover = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    wt: Io.Dir,
    index: *Index,
    /// The outcome's: every path here lives as long as it.
    arena: Allocator,
    options: Options,
    cone: Cone,
    /// `core.sparseCheckout` with `core.sparseCheckoutCone`.
    cone_mode: bool,
    ignore_case: bool,
    outcome: *Outcome,
    items: std.ArrayList(Item) = .empty,
    /// What the destination is moved as: git's `dst_mode`.
    dst_mode: Mode = .{},
    trimmed: []const []const u8 = &.{},
    sparse_only: std.ArrayList([]const u8) = .empty,
    skipped: std.ArrayList(Refusal) = .empty,
    src_for_dst: std.StringHashMapUnmanaged(void) = .empty,
    moved_dirs: std.ArrayList([]const u8) = .empty,
    dirty: std.ArrayList([]const u8) = .empty,

    /// The operands as git's `internal_prefix_pathspec` leaves them, and
    /// where each source goes. Each source loses its trailing slashes; the
    /// destination keeps its own, so that `mv file no-such-dir/` fails,
    /// unless one directory moves to a name that is not one.
    fn place(m: *Mover) Self.Error!?Refusal {
        const arena = m.arena;
        const trimmed = try arena.alloc([]const u8, m.options.sources.len);
        for (m.options.sources, trimmed) |source, *t| {
            t.* = std.mem.trimEnd(u8, source, "/");
            try m.items.append(arena, .{ .source = try pathspec_mod.normalize(arena, t.*), .destination = "" });
        }
        m.trimmed = trimmed;
        const one_dir = m.options.sources.len == 1 and isDirectory(m.io, m.wt, m.items.items[0].source) and
            !isDirectory(m.io, m.wt, try pathspec_mod.normalize(arena, m.options.destination));
        const destination = try pathspec_mod.normalize(arena, if (one_dir) std.mem.trimEnd(u8, m.options.destination, "/") else m.options.destination);
        const dst_w_slash = try addSlash(arena, destination);

        if (destination.len == 0) {
            for (m.items.items, trimmed) |*item, t| item.destination = try pathspec_mod.normalize(arena, std.Io.Dir.path.basenamePosix(t));
        } else if (if (try lstat(m.io, m.wt, std.mem.trimEnd(u8, destination, "/"))) |found| found.kind == .directory else false) {
            try m.into(dst_w_slash);
        } else if (!m.cone.includes(dst_w_slash, false) and emptyDirHasSparseContents(m.index, dst_w_slash)) {
            try m.into(dst_w_slash);
            m.dst_mode.skip_worktree_dir = true;
        } else if (m.items.items.len != 1) {
            return .{ .reason = .not_a_directory, .source = "", .destination = destination };
        } else {
            m.items.items[0].destination = destination;
            // A file outside the cone, in cone mode only.
            if (!m.cone.includes(destination, true)) m.dst_mode.sparse = true;
        }
        return null;
    }

    fn into(m: *Mover, dir_slash: []const u8) Allocator.Error!void {
        for (m.items.items, m.trimmed) |*item, t| item.destination = try std.mem.concat(m.arena, u8, &.{ dir_slash, std.Io.Dir.path.basenamePosix(t) });
    }

    /// The checks, as git makes them: a refusal stops everything unless
    /// `skip_errors`, which drops the source instead. A directory's entries
    /// join the list as it is checked.
    fn check(m: *Mover) Self.Error!?Refusal {
        var i: usize = 0;
        while (i < m.items.items.len) {
            switch (try m.checkOne(i)) {
                .keep => {
                    i += 1;
                    continue;
                },
                .drop => {},
                .bad => |reason| {
                    const item = m.items.items[i];
                    const refusal: Refusal = .{ .reason = reason, .source = item.source, .destination = item.destination };
                    if (!m.options.skip_errors) return refusal;
                    try m.skipped.append(m.arena, refusal);
                },
            }
            _ = m.items.orderedRemove(i);
        }
        m.outcome.skipped = m.skipped.items;
        m.outcome.sparse_only = m.sparse_only.items;
        return null;
    }

    fn checkOne(m: *Mover, i: usize) Self.Error!Verdict {
        const options = m.options;
        const index = m.index;
        const item = &m.items.items[i];
        const src = item.source;
        const dst = item.destination;
        var is_dir = false;
        if (try lstat(m.io, m.wt, src)) |found| {
            if (std.mem.startsWith(u8, dst, src) and (dst.len == src.len or dst[src.len] == '/')) return .{ .bad = .into_itself };
            if (found.kind == .directory and try lstat(m.io, m.wt, dst) != null) return .{ .bad = .destination_exists };
            is_dir = found.kind == .directory;
        } else if (index.find(src)) |entry| {
            if (!entry.skip_worktree) return .{ .bad = .bad_source };
            if (!options.sparse) {
                try m.sparse_only.append(m.arena, src);
                return .keep;
            }
            if (index.find(dst) != null and !options.force) return .{ .bad = .destination_exists };
            item.mode.sparse = true;
            return .keep;
        } else if (!m.cone.includes(try addSlash(m.arena, src), false) and emptyDirHasSparseContents(index, src)) {
            item.mode.skip_worktree_dir = true;
            is_dir = true;
        } else return if (item.mode.sparse) .keep else .{ .bad = .bad_source };

        if (is_dir) return m.checkDirectory(i);

        const entry = anyStage(index, src) orelse return .{ .bad = .not_tracked };
        if (entry.stage != 0) return .{ .bad = .conflicted };
        if (try lstat(m.io, m.wt, dst)) |found| if (!m.ignore_case or !std.ascii.eqlIgnoreCase(src, dst)) {
            if (!options.force) return .{ .bad = .destination_exists };
            // Only files can overwrite each other.
            return if (found.kind == .file or found.kind == .sym_link) .keep else .{ .bad = .cannot_overwrite };
        };
        if (m.src_for_dst.contains(dst)) return .{ .bad = .multiple_sources };
        if (dst[dst.len - 1] == '/') return .{ .bad = .destination_directory_missing };
        if (options.sparse and (m.dst_mode.skip_worktree_dir or m.dst_mode.sparse) and index.find(dst) != null and !options.force)
            return .{ .bad = .destination_in_index };
        // The cone last, so that the advice to use `--sparse` is what a
        // move only it would allow gets.
        var skip_sparse = false;
        if (!options.sparse and !m.cone.includes(src, false)) {
            try m.sparse_only.append(m.arena, src);
            skip_sparse = true;
        }
        if (!options.sparse and !m.cone.includes(dst, false)) {
            try m.sparse_only.append(m.arena, dst);
            skip_sparse = true;
        }
        if (skip_sparse) return .drop;
        try m.src_for_dst.put(m.arena, dst, {});
        return .keep;
    }

    /// A directory: a submodule, or the entries under it, each of which
    /// joins the list to move with it.
    fn checkDirectory(m: *Mover, i: usize) Self.Error!Verdict {
        const src = m.items.items[i].source;
        const dst = m.items.items[i].destination;
        if (m.index.find(src)) |entry| {
            if (entry.mode != .gitlink) return error.DirectoryNotSubmodule;
            if (!try submodule.gitmodulesStaged(m.gpa, m.io, m.repo, m.index)) return error.GitmodulesNotStaged;
            m.items.items[i].gitfile = if (try submodule.gitDirOf(m.arena, m.io, m.repo, src)) |path| .{ .path = path } else .with_git_dir;
            return .keep;
        }
        const range = underDirectory(m.index, try addSlash(m.arena, src));
        if (range.len == 0) return .{ .bad = .source_empty };
        try m.moved_dirs.append(m.arena, src);
        m.items.items[i].mode.working_directory = true;
        const dst_slash = try addSlash(m.arena, dst);
        for (range) |entry| try m.items.append(m.arena, .{
            .source = try m.arena.dupe(u8, entry.path),
            .destination = try std.mem.concat(m.arena, u8, &.{ dst_slash, entry.path[src.len + 1 ..] }),
            .mode = .{ .move_via_parent_dir = true, .sparse = entry.skip_worktree, .index = !entry.skip_worktree },
        });
        return .keep;
    }

    /// A path and a directory above it, both named: git dies, `-k` or not.
    fn parentAndChild(m: *const Mover) ?Refusal {
        for (m.items.items) |item| {
            if (item.mode.move_via_parent_dir) continue;
            var above = item.source;
            while (std.mem.findScalarLast(u8, above, '/')) |slash| {
                if (slash == 0) break;
                above = above[0..slash];
                for (m.moved_dirs.items) |dir| if (samePath(dir, above, m.ignore_case)) {
                    return .{ .reason = .with_parent, .source = item.source, .destination = above };
                };
            }
        }
        return null;
    }

    /// The moves: the working tree, `.gitmodules` and a submodule's `.git`
    /// file, the index, and across the cone under `sparse`.
    fn apply(m: *Mover) Self.Error!void {
        const io = m.io;
        const wt = m.wt;
        const rules = try m.repo.worktreeRules();
        var renamed: std.ArrayList(Rename) = .empty;
        var gitmodules_modified = false;
        for (m.items.items) |item| {
            const mode = item.mode;
            if (!(mode.index or mode.sparse or mode.skip_worktree_dir) and !(m.dst_mode.skip_worktree_dir or m.dst_mode.sparse)) {
                wt.rename(item.source, wt, item.destination, io) catch |err| {
                    if (m.options.skip_errors) continue;
                    return err;
                };
            }
            try renamed.append(m.arena, .{ .source = item.source, .destination = item.destination });
            if (item.gitfile) |gitfile| {
                if (try submodule.moveInGitmodules(m.gpa, io, m.repo, m.index, item.source, item.destination)) gitmodules_modified = true;
                switch (gitfile) {
                    .with_git_dir => {},
                    .path => |git_dir| try submodule.connectGitDir(m.gpa, io, m.repo, item.destination, git_dir),
                }
            }
            if (mode.working_directory or mode.skip_worktree_dir) continue;
            try m.moveEntry(item, rules);
        }
        m.outcome.renamed = renamed.items;

        // `remove_empty_src_dirs`: a directory everything moved out of goes,
        // whatever is left in it.
        for (m.moved_dirs.items) |dir| {
            if (underDirectory(m.index, try addSlash(m.arena, dir)).len != 0) continue;
            wt.deleteTree(io, dir) catch |err| std.log.warn("unable to remove '{s}': {t}", .{ dir, err });
        }
        // `stage_updated_gitmodules`.
        if (gitmodules_modified) _ = try checkout.addAll(m.gpa, io, wt, .{ .index = m.index, .db = m.repo.objectDatabase() }, .{ .rules = rules, .prefix = ".gitmodules", .stage_deletions = false });
    }

    /// One index entry renamed, and under `sparse` in cone mode moved
    /// across the cone.
    fn moveEntry(m: *Mover, item: Item, rules: checkout.Rules) Self.Error!void {
        const io = m.io;
        const wt = m.wt;
        const index = m.index;
        const src = item.source;
        const dst = item.destination;
        const before = (index.find(src) orelse unreachable).*;
        const sparse_and_dirty = !item.mode.sparse and try lstat(io, wt, src) != null and
            try checkout.differsFromIndex(m.gpa, io, wt, .{ .index = index, .entry = before }, rules);
        _ = try index.rename(src, dst);
        // git's `refresh_cache_entry`: the stat the rename gave the file,
        // when its content is still what the entry says.
        if (try lstat(io, wt, dst)) |found| {
            const entry = index.find(dst) orelse unreachable;
            if (!try checkout.differsFromIndex(m.gpa, io, wt, .{ .index = index, .entry = entry.* }, rules)) entry.stat = found.stat;
        }
        if (!m.options.sparse or !m.cone_mode) return;
        if (item.mode.sparse and m.cone.includes(dst, false)) {
            // From outside the cone into it.
            const entry = index.find(dst) orelse unreachable;
            entry.skip_worktree = false;
            _ = try checkout.writePaths(m.gpa, io, wt, .{ .index = index, .db = m.repo.objectDatabase(), .writes = &.{.{
                .path = dst,
                .blob = .{ .mode = entry.mode, .oid = entry.oid },
            }} }, .{ .rules = rules, .force = true });
        } else if ((m.dst_mode.skip_worktree_dir or m.dst_mode.sparse) and !item.mode.sparse and !m.cone.includes(dst, false)) {
            // From inside the cone out of it: a clean file goes, a dirty
            // one moves and stays.
            if (!sparse_and_dirty) {
                (index.find(dst) orelse unreachable).skip_worktree = true;
                fs.deleteFile(io, wt, src) catch |err| std.log.warn("unable to unlink '{s}': {t}", .{ src, err });
            } else {
                try m.dirty.append(m.arena, dst);
                m.outcome.dirty = m.dirty.items;
                if (std.Io.Dir.path.dirnamePosix(dst)) |parent| try fs.makeDirs(io, wt, parent, m.repo.sharedPermissions());
                try wt.rename(src, wt, dst, io);
            }
        }
    }
};

const Verdict = union(enum) {
    /// The source stays in the list.
    keep,
    /// It leaves the list without a refusal: the cone's advice covers it.
    drop,
    bad: Reason,
};

/// The sparse-checkout patterns, asked as git's `path_in_sparse_checkout`
/// asks them: everything is in when there are none.
const Cone = struct {
    patterns: ?*const sparse.Patterns,

    /// Whether `path` is in. `cone_only` is git's
    /// `path_in_cone_mode_sparse_checkout`: patterns that are not a cone
    /// leave everything in.
    fn includes(c: Cone, path: []const u8, cone_only: bool) bool {
        const p = c.patterns orelse return true;
        if (path.len == 0 or (cone_only and p.cone == null)) return true;
        // A path ending in a slash is asked about as git asks it: as a
        // file in that directory.
        if (path[path.len - 1] == '/') {
            var buf: [4096]u8 = undefined;
            if (path.len + 1 > buf.len) return true;
            @memcpy(buf[0..path.len], path);
            buf[path.len] = '-';
            return p.includes(buf[0 .. path.len + 1], .file);
        }
        return p.includes(path, .file);
    }
};

/// `path/` unless `path` is empty or already ends in one: git's
/// `add_slash`.
fn addSlash(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (path.len == 0 or path[path.len - 1] == '/') return path;
    return std.mem.concat(arena, u8, &.{ path, "/" });
}

/// What `stat` says, following a symbolic link: git's `is_directory`.
fn isDirectory(io: Io, wt: Io.Dir, path: []const u8) bool {
    if (path.len == 0) return true;
    const stat = wt.statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// What `lstat` says of `path`, or `null` when there is nothing there.
fn lstat(io: Io, wt: Io.Dir, path: []const u8) fs.StatError!?fs.Entry {
    if (path.len == 0) return null;
    return fs.statAt(io, wt, path) catch |err| switch (err) {
        error.NotDir => null,
        else => |e| return e,
    };
}

/// The entries under `dir_slash`, a directory with its slash.
fn underDirectory(index: *const Index, dir_slash: []const u8) []const index_mod.Entry {
    const entries = index.items();
    var first: usize = 0;
    while (first < entries.len and std.mem.order(u8, entries[first].path, dir_slash) == .lt) first += 1;
    var last = first;
    while (last < entries.len and std.mem.startsWith(u8, entries[last].path, dir_slash)) last += 1;
    return entries[first..last];
}

/// git's `empty_dir_has_sparse_contents`: whether the first entry under
/// the directory is outside the working tree.
fn emptyDirHasSparseContents(index: *const Index, dir: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (dir.len + 1 > buf.len) return false;
    @memcpy(buf[0..dir.len], dir);
    const with_slash = if (dir.len != 0 and dir[dir.len - 1] == '/') dir else blk: {
        buf[dir.len] = '/';
        break :blk buf[0 .. dir.len + 1];
    };
    if (index.find(with_slash) != null) return false;
    const under = underDirectory(index, with_slash);
    return under.len != 0 and under[0].skip_worktree;
}

/// The entry for `path` at its lowest stage: git's `index_file_exists`.
fn anyStage(index: *const Index, path: []const u8) ?*const index_mod.Entry {
    var stage: u3 = 0;
    while (stage < 4) : (stage += 1) if (index.findStage(path, @intCast(stage))) |entry| return entry;
    return null;
}

fn samePath(a: []const u8, b: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}
