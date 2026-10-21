//! `git log --follow -- <path>`: the commits that changed a file, the file
//! followed back through its renames.
//!
//! It is git 2.55's walk with `follow_renames` (`try_to_follow_renames` in
//! `tree-diff.c`): every commit, newest committer date first, no history
//! simplified; a merge shows no diff and is passed by, a root commit is
//! diffed against the empty tree. Each commit's diff from its parent is
//! limited to the path followed; where that diff creates a file, the whole
//! diff is searched for the path's source -- renames and copies from any
//! file, whatever `diff.renames` says -- with the path as the only
//! destination, and when one is found the commit shows
//! that rename or copy and older commits follow the source's path. Found
//! or not, the commit shows one change: that one, or the first the limited
//! diff had. A commit whose diff is empty is not shown. The path followed
//! changes when a commit is met, whichever line of history it is on, as
//! git's does.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const diff = @import("../diff/diff.zig");
const pathspec = @import("../patterns.zig").pathspec;
const walk_mod = @import("../walk/walk.zig");
const config_mod = @import("../config/config.zig");
const repo_mod = @import("../repo/repo.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from following a file.
pub const Error = walk_mod.Error || diff.Error || pathspec.Error || repo_mod.Error;

/// Where the walk starts and stops, and the file.
pub const Inputs = struct {
    /// The commits walked from.
    include: []const Oid,
    /// `^<commit>`: commits whose history is left out.
    exclude: []const Oid = &.{},
    /// The one path followed, as the newest commits name it.
    path: []const u8,
};

/// How the renames are found.
pub const Options = struct {
    /// `diff.renames` and `diff.renameLimit`, as `diff.RenameSettings.read`
    /// reads them: the renames a commit's own diff finds, and the limit
    /// the search for a created file's source keeps to. That search finds
    /// renames and copies from any file whatever `diff.renames` says, as
    /// git's `--find-copies-harder` turns copies on.
    renames: diff.RenameSettings = .{},
};

/// A commit shown, and its diff.
pub const Entry = struct {
    commit: Oid,
    /// The path followed before this commit is met.
    path: []const u8,
    changes: []const diff.Change,
};

/// The commits shown, newest first.
pub const Result = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator.State,
    gpa: Allocator,
    entries: []const Entry,

    pub fn deinit(r: *Result) void {
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

/// `log.follow`: whether `git log` follows a single path given with no
/// `--follow`.
pub fn configured(config: *const config_mod.Config) config_mod.ValueError!bool {
    return config.getBool("log.follow", false);
}

pub fn follow(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    const db = repo.objectDatabase();
    var w = walk_mod.Walk.init(gpa, db);
    defer w.deinit();
    for (inputs.include) |oid| try w.push(oid);
    for (inputs.exclude) |oid| try w.hide(oid);

    var current = try a.dupe(u8, inputs.path);
    var entries: std.ArrayList(Entry) = .empty;
    while (try w.next(io)) |c| {
        if (c.parents.len > 1) continue;
        const old: ?Oid = if (c.parents.len == 0) null else try repo.commitTree(io, c.parents[0]);
        const literal = try a.print(":(literal){s}", .{current});
        var paths = try pathspec.parse(gpa, &.{literal});
        defer paths.deinit();
        var limited = try diff.tree(gpa, io, db, .{ .old = old, .new = c.tree }, .{ .paths = &paths });
        defer limited.deinit();
        if (limited.items.len == 0) continue;
        const followed_path = current;
        const created = for (limited.items) |ch| {
            if (ch.status == .added) break true;
        } else false;
        var shown: []const diff.Change = undefined;
        if (created) {
            // `try_to_follow_renames`.
            shown = try own(a, limited.items[0..1]);
            const limit = options.renames.limit orelse 1000;
            var full = try diff.tree(gpa, io, db, .{ .old = old, .new = c.tree }, .{ .renames = .{
                .detect_copies = true,
                .find_copies_harder = true,
                .single_follow = current,
                .limit = @intCast(@max(0, limit)),
            } });
            defer full.deinit();
            for (full.items) |ch| {
                if ((ch.status == .renamed or ch.status == .copied) and std.mem.eql(u8, ch.new.?.path, current)) {
                    shown = try own(a, &.{ch});
                    current = try a.dupe(u8, ch.old.?.path);
                    break;
                }
            }
        } else {
            var renamed = try diff.tree(gpa, io, db, .{ .old = old, .new = c.tree }, .{ .paths = &paths, .renames = options.renames.options() });
            defer renamed.deinit();
            shown = try own(a, renamed.items);
        }
        try entries.append(a, .{ .commit = c.oid, .path = followed_path, .changes = shown });
    }
    return .{ .arena = arena_state.state, .gpa = gpa, .entries = entries.items };
}

/// `changes` copied into `a`, paths and all.
fn own(a: Allocator, changes: []const diff.Change) Allocator.Error![]const diff.Change {
    const out = try a.dupe(diff.Change, changes);
    for (out) |*ch| {
        if (ch.old) |*e| e.path = try a.dupe(u8, e.path);
        if (ch.new) |*e| e.path = try a.dupe(u8, e.path);
    }
    return out;
}
