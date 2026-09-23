//! A gitlink's directory in the working tree: whether a repository is there,
//! and which commit it has checked out.
//!
//! A gitlink names a commit in another repository, and the superproject's
//! walk never descends into its directory. What the walk asks instead is
//! git's `resolve_gitlink_ref`: whether `<path>/.git` is a git directory —
//! the directory itself, or a `.git` file naming one — and what that
//! repository's `HEAD` resolves to. A directory holding no repository is a
//! submodule nobody populated, and git calls that unchanged; so is one whose
//! `HEAD` does not resolve, because git cannot compare a commit it cannot
//! name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const fs = @import("fs.zig");
const refs_mod = @import("refs.zig");

const Oid = hash.Oid;

/// Errors from looking at a gitlink's directory: the filesystem's. A ref
/// that does not parse is a `HEAD` that names nothing, not an error.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error;

/// A submodule's repository, found from its working tree.
pub const GitDir = struct {
    /// Its `.git` directory, wherever that is.
    git_dir: Io.Dir,
    /// Where its shared state lives: `git_dir` itself, unless a `commondir`
    /// file names another.
    common_dir: Io.Dir,
    common_is_separate: bool,
    /// Whether `<path>/.git` was a file naming the directory rather than the
    /// directory itself, which is what an absorbed submodule has.
    via_file: bool,

    /// Close both directories.
    pub fn close(g: *GitDir, io: Io) void {
        if (g.common_is_separate) g.common_dir.close(io);
        g.git_dir.close(io);
        g.* = undefined;
    }

    /// A ref store over the two directories, which it borrows.
    pub fn refStore(g: *const GitDir, gpa: Allocator, kind: hash.Kind) refs_mod.Store {
        return .init(gpa, kind, g.git_dir, g.common_dir);
    }
};

/// Open the repository whose working tree is `path` under `wt`, or `null`
/// when `<path>/.git` is neither a git directory nor a file naming one.
///
/// A `.git` file's `gitdir:` line is read relative to the directory the file
/// is in, which is how git writes it for a submodule, or as an absolute path,
/// which is how it writes it for a linked worktree.
pub fn open(gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8) Error!?GitDir {
    var work = (if (path.len == 0) wt.openDir(io, ".", .{}) else wt.openDir(io, path, .{})) catch return null;
    defer work.close(io);

    var via_file = false;
    const git_dir = if (work.openDir(io, ".git", .{ .iterate = true })) |dir| dir else |_| blk: {
        const text = (fs.readFileAlloc(gpa, io, work, ".git", 4096) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        }) orelse return null;
        defer gpa.free(text);
        const target = gitFileTarget(text) orelse return null;
        via_file = true;
        break :blk (if (std.fs.path.isAbsolute(target))
            Io.Dir.openDirAbsolute(io, target, .{ .iterate = true })
        else
            work.openDir(io, target, .{ .iterate = true })) catch return null;
    };
    if (!isGitDirectory(io, git_dir)) {
        git_dir.close(io);
        return null;
    }

    var result: GitDir = .{
        .git_dir = git_dir,
        .common_dir = git_dir,
        .common_is_separate = false,
        .via_file = via_file,
    };
    const common_text = fs.readFileAlloc(gpa, io, git_dir, "commondir", 4096) catch |err| switch (err) {
        error.OutOfMemory => {
            git_dir.close(io);
            return error.OutOfMemory;
        },
        else => null,
    };
    if (common_text) |text| {
        defer gpa.free(text);
        const target = std.mem.trim(u8, text, " \t\r\n");
        const common = (if (std.fs.path.isAbsolute(target))
            Io.Dir.openDirAbsolute(io, target, .{ .iterate = true })
        else
            git_dir.openDir(io, target, .{ .iterate = true })) catch null;
        if (common) |dir| {
            result.common_dir = dir;
            result.common_is_separate = true;
        }
    }
    return result;
}

/// The commit `HEAD` resolves to in the repository whose working tree is
/// `path`, or `null` when there is no repository there or its `HEAD` does not
/// name a commit.
pub fn head(gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8, kind: hash.Kind) Error!?Oid {
    var found = (try open(gpa, io, wt, path)) orelse return null;
    defer found.close(io);
    const store = found.refStore(gpa, kind);
    const resolved = (store.head(gpa, io) catch |err| switch (err) {
        error.MalformedRef, error.MalformedPackedRefs, error.SymbolicRefLoop, error.InvalidRefName => return null,
        else => |e| return e,
    }) orelse return null;
    gpa.free(resolved.name);
    return resolved.oid;
}

/// The path after `gitdir:` in a `.git` file's text, or `null` when the text
/// is not one.
pub fn gitFileTarget(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
    const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    if (target.len == 0) return null;
    return target;
}

/// Whether `dir` holds what a git directory must: `HEAD`, `objects` and
/// `refs`. What git's `is_git_directory` asks before it trusts one.
pub fn isGitDirectory(io: Io, dir: Io.Dir) bool {
    dir.access(io, "HEAD", .{}) catch return false;
    dir.access(io, "objects", .{}) catch return false;
    dir.access(io, "refs", .{}) catch return false;
    return true;
}
