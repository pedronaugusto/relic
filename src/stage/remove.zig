//! git's `rm` (`builtin/rm.c`): the index entries a pathspec names
//! removed, and unless `cached` their files, a submodule's working tree
//! and its `.gitmodules` section with them, after `check_local_mod` has
//! found no change the removal would lose.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const repo_mod = @import("../repo/repo.zig");
const checkout = @import("../checkout/checkout.zig");
const sparse_index = @import("../index/sparse_index.zig");
const pathspec_mod = @import("../patterns.zig").pathspec;
const submodule = @import("../submodule/submodule.zig");
const Repository = repo_mod.Repository;

/// What `remove` is asked: `git rm`'s options.
pub const Options = struct {
    /// The pathspecs, as git reads them at the top of the working tree.
    pathspecs: []const []const u8,
    /// `--cached`: the index entries alone; the files stay.
    cached: bool = false,
    /// `-f`: no check for changes the removal would lose.
    force: bool = false,
    /// `-r`: a pathspec that names a directory takes what is under it.
    recursive: bool = false,
    /// `--ignore-unmatch`: a pathspec that names nothing is no failure.
    ignore_unmatch: bool = false,
    /// `-n`: report what would go, and remove nothing.
    dry_run: bool = false,
    /// `--sparse`: entries outside the sparse-checkout cone may go too.
    sparse: bool = false,
    /// What runs a submodule's status, and opens it.
    submodules: submodule.StatusProbe.ProbeOptions = .{},
};

/// What `remove` did, or refused. Release it with `deinit`.
pub const Outcome = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator,
    /// The paths taken out of the index, in index order: git's `rm '<path>'`
    /// lines.
    removed: []const []const u8 = &.{},
    /// Pathspecs that named only entries outside the sparse-checkout cone:
    /// git's advice to use `--sparse`, and its exit status 1.
    sparse_only: []const []const u8 = &.{},
    /// When `check_local_mod` refused: the files whose staged content is
    /// neither the file's nor `HEAD`'s, those with changes staged, and
    /// those with local changes. Nothing was removed.
    staged_and_local: []const []const u8 = &.{},
    staged: []const []const u8 = &.{},
    local: []const []const u8 = &.{},

    pub fn refused(o: *const Outcome) bool {
        return o.staged_and_local.len + o.staged.len + o.local.len != 0;
    }

    pub fn deinit(o: *Outcome) void {
        o.arena.deinit();
        o.* = undefined;
    }
};

/// Failures of `remove`.
pub const Error = repo_mod.Error || Repository.LockIndexError || Repository.WriteIndexError || checkout.Error || pathspec_mod.Error ||
    submodule.Error || sparse_index.Error || Io.Dir.DeleteTreeError || Io.Dir.DeleteFileError || error{
    /// No pathspec: git's "No pathspec was given".
    NoPathspec,
    /// A pathspec that names no entry, without `ignore_unmatch`: git's
    /// "pathspec did not match any files".
    PathspecUnmatched,
    /// A pathspec that names a directory, without `recursive`: git's "not
    /// removing recursively without -r".
    NotRecursive,
    /// A submodule among the paths while `.gitmodules` has changes not
    /// staged: git's "please stage your changes to .gitmodules".
    GitmodulesNotStaged,
    /// The first file could not be removed: git stops before anything is
    /// written.
    RemoveFailed,
};

const Picked = struct { path: []const u8, gitlink: bool };

/// git's `rm`.
pub fn remove(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    if (options.pathspecs.len == 0) return error.NoPathspec;
    var outcome: Outcome = .{ .arena = .init(gpa) };
    errdefer outcome.deinit();
    const arena = outcome.arena.allocator();
    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();

    var locked = try repo.lockIndex(io);
    defer locked.deinit(io);
    const index = &locked.index;
    try sparse_index.expand(gpa, io, index, repo.objectDatabase(), null);
    const wt: ?Io.Dir = if (repo.workDirectory()) |work| work.get() else null;

    // Every entry the pathspec names, once a path.
    const seen = try arena.alloc(pathspec_mod.How, spec.items.len);
    @memset(seen, .none);
    var picked: std.ArrayList(Picked) = .empty;
    var sparse_seen: std.ArrayList(bool) = .empty;
    try sparse_seen.appendNTimes(arena, false, spec.items.len);
    for (index.items(), 0..) |entry, i| {
        if (i > 0 and std.mem.eql(u8, index.items()[i - 1].path, entry.path)) continue;
        if (!options.sparse and entry.skip_worktree) {
            // `matches_skip_worktree`: which pathspecs only an entry out of
            // the cone answers.
            const scratch = try arena.alloc(pathspec_mod.How, spec.items.len);
            @memset(scratch, .none);
            if (spec.howSeen(entry.path, .{}, scratch) != .none) for (scratch, sparse_seen.items) |h, *s| {
                if (h != .none) s.* = true;
            };
            continue;
        }
        if (spec.howSeen(entry.path, .{}, seen) == .none) continue;
        try picked.append(arena, .{ .path = entry.path, .gitlink = entry.mode == .gitlink });
    }
    var sparse_only: std.ArrayList([]const u8) = .empty;
    var seen_any = false;
    for (options.pathspecs, seen, sparse_seen.items) |original, how, sparse| {
        if (how != .none) {
            seen_any = true;
        } else if (options.ignore_unmatch) {
            continue;
        } else if (sparse) {
            try sparse_only.append(arena, original);
        } else return error.PathspecUnmatched;
        if (!options.recursive and how == .recursively) return error.NotRecursive;
    }
    outcome.sparse_only = try sparse_only.toOwnedSlice(arena);
    if (!seen_any) return outcome;

    const head_tree = try repo.headTree(io);
    var status: ?checkout.Status = null;
    defer if (status) |*s| s.deinit();
    if (!options.force) if (wt) |work| {
        var probe = try submodule.StatusProbe.init(gpa, io, repo, index, options.submodules);
        defer probe.deinit();
        status = try checkout.status(gpa, io, work, .{ .index = index, .db = repo.objectDatabase() }, .{
            .rules = try repo.worktreeRules(),
            .head_tree = head_tree,
            .untracked = .no,
            .submodules = probe.probe(),
        });
    };
    for (picked.items) |p| if (p.gitlink) {
        if (!try submodule.gitmodulesStaged(gpa, io, repo, index)) return error.GitmodulesNotStaged;
        break;
    };

    if (!options.cached) if (wt) |work| try absorbIfNeeded(gpa, io, repo, work, picked.items);
    if (!options.force) if (try localChanges(arena, io, repo, picked.items, if (status) |*s| s else null, head_tree, index, options.cached, &outcome)) return outcome;

    var removed: std.ArrayList([]const u8) = .empty;
    for (picked.items) |p| {
        try removed.append(arena, try arena.dupe(u8, p.path));
        if (index.cache_tree) |*tree| tree.invalidate(p.path);
        _ = index.remove(p.path);
    }
    outcome.removed = try removed.toOwnedSlice(arena);
    if (options.dry_run) return outcome;

    if (!options.cached) if (wt) |work| {
        var any_removed = false;
        var gitmodules_changed = false;
        for (outcome.removed, picked.items) |path, p| {
            if (p.gitlink) {
                work.deleteTree(io, path) catch |err| return err;
                any_removed = true;
                if (try submodule.removeFromGitmodules(gpa, io, repo, index, path)) gitmodules_changed = true;
                continue;
            }
            if (removePath(io, work, path)) {
                any_removed = true;
            } else if (!any_removed) return error.RemoveFailed;
        }
        // `stage_updated_gitmodules`.
        if (gitmodules_changed) _ = try checkout.addAll(gpa, io, work, .{ .index = index, .db = repo.objectDatabase() }, .{ .rules = try repo.worktreeRules(), .prefix = ".gitmodules", .stage_deletions = false });
    };
    try locked.commit(io);
    return outcome;
}

/// `submodules_absorb_gitdir_if_needed`: a submodule about to go whose
/// `.git` is a directory has it moved into the superproject first.
fn absorbIfNeeded(gpa: Allocator, io: Io, repo: *Repository, work: Io.Dir, picked: []const Picked) Self.Error!void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    for (picked) |p| {
        if (!p.gitlink) continue;
        var dir = work.openDir(io, p.path, .{}) catch continue;
        defer dir.close(io);
        const stat = dir.statFile(io, ".git", .{}) catch continue;
        if (stat.kind == .directory) try paths.append(gpa, p.path);
    }
    if (paths.items.len == 0) return;
    _ = try submodule.absorbGitDirs(gpa, io, repo, .{ .paths = paths.items });
}

/// `check_local_mod`: each path's local change (the file is not what the
/// index holds, or a submodule's working tree has changes) and staged
/// change (the index is not `HEAD`), sorted into git's three refusals.
/// Whether any was found.
fn localChanges(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    picked: []const Picked,
    status: ?*const checkout.Status,
    head_tree: ?Oid,
    index: *const @import("../index/index.zig").Index,
    cached: bool,
    outcome: *Outcome,
) Self.Error!bool {
    _ = io;
    _ = repo;
    var both: std.ArrayList([]const u8) = .empty;
    var staged_only: std.ArrayList([]const u8) = .empty;
    var local_only: std.ArrayList([]const u8) = .empty;
    for (picked) |p| {
        const entry = index.find(p.path) orelse continue;
        const state = if (status) |s| s.find(p.path) else null;
        // A file already gone from the working tree, or one that is now a
        // directory, is nothing to lose.
        const unstaged = if (state) |s| s.unstaged else .unmodified;
        if (unstaged == .deleted) continue;
        var local = unstaged != .unmodified;
        if (p.gitlink) if (state) |s| if (s.submodule) |sub| {
            if (sub.modified_content or sub.untracked_content) local = true;
        };
        const staged = head_tree == null or (if (state) |s| s.staged != .unmodified else false);
        if (local and staged) {
            if (!cached or !entry.intent_to_add) try both.append(arena, p.path);
        } else if (!cached) {
            if (staged) try staged_only.append(arena, p.path);
            if (local) try local_only.append(arena, p.path);
        }
    }
    outcome.staged_and_local = try both.toOwnedSlice(arena);
    outcome.staged = try staged_only.toOwnedSlice(arena);
    outcome.local = try local_only.toOwnedSlice(arena);
    return outcome.refused();
}

/// `remove_path`: the file, then each directory above it left empty.
/// Whether the file went.
fn removePath(io: Io, work: Io.Dir, path: []const u8) bool {
    work.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return false,
    };
    var dir = std.Io.Dir.path.dirname(path);
    while (dir) |d| : (dir = std.Io.Dir.path.dirname(d)) {
        work.deleteDir(io, d) catch break;
    }
    return true;
}
