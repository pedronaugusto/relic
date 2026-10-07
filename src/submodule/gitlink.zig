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

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const fs = @import("../repo/fs.zig");
const refs_mod = @import("../refs.zig");
const repository_format = @import("../discover/format.zig");

const Oid = hash.Oid;

/// Errors from looking at a gitlink's directory: the filesystem's. A ref
/// that does not parse is a `HEAD` that names nothing, not an error.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    refs_mod.ReadError;

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

    /// A store over its refs, which borrows the two directories, in the
    /// format the repository's own configuration names: the hash its
    /// objects are named with, and loose files and `packed-refs` or a
    /// stack under `reftable/`. What is on the disk has no say.
    pub fn refStore(g: *const GitDir, gpa: Allocator, io: Io) repository_format.ReadError!refs_mod.Store {
        const format = try repository_format.read(gpa, io, g.common_dir, null);
        return refs_mod.Store.initWithOptions(gpa, format.kind, g.git_dir, g.common_dir, .{ .format = format.ref_storage });
    }
};

/// Open the repository whose working tree is `path` under `wt`, or `null`
/// when `<path>/.git` is neither a git directory nor a file naming one.
///
/// A `.git` file's `gitdir:` line is read relative to the directory the file
/// is in, which is how git writes it for a submodule, or as an absolute path,
/// which is how it writes it for a linked worktree.
pub fn open(gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8) Self.Error!?GitDir {
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
        break :blk (if (std.Io.Dir.path.isAbsolute(target))
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
        const common = (if (std.Io.Dir.path.isAbsolute(target))
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

/// Whether the directory `path` under `wt` holds a repository of its own:
/// `<path>/.git` is a git directory, or a `.git` file naming one. This is
/// git's `is_nonbare_repository_dir`, which is how its walk of a working
/// tree tells a repository inside it from a directory to descend into.
pub fn isRepository(gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8) Self.Error!bool {
    // Almost every directory has no `.git` at all, and one access says so
    // without opening anything.
    var buf: [4096]u8 = undefined;
    const dot_git = std.mem.print(&buf, "{s}/.git", .{path}) catch return false;
    wt.access(io, dot_git, .{}) catch return false;
    var found = (try open(gpa, io, wt, path)) orelse {
        // git's `is_nonbare_repository_dir`: a `.git` file that is there and
        // cannot be opened or read is taken for a repository all the same,
        // so `clean` and the walks leave what is beside it alone.
        const st = wt.statFile(io, dot_git, .{}) catch return false;
        if (st.kind != .file) return false;
        const file = wt.openFile(io, dot_git, .{}) catch return true;
        defer file.close(io);
        var probe: [1]u8 = undefined;
        _ = file.readPositional(io, &.{&probe}, 0) catch return true;
        return false;
    };
    found.close(io);
    return true;
}

/// The commit `HEAD` resolves to in the repository whose working tree is
/// `path`, or `null` when there is no repository there, its format is one
/// this release does not read, or its `HEAD` does not name a commit.
pub fn head(gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8) Self.Error!?Oid {
    var found = (try open(gpa, io, wt, path)) orelse return null;
    defer found.close(io);
    var store = found.refStore(gpa, io) catch |err| switch (err) {
        // A configuration that names no format this release reads, which
        // git's `resolve_gitlink_ref` cannot resolve either.
        error.UnsupportedRepositoryVersion,
        error.UnsupportedExtension,
        error.UnknownObjectFormat,
        error.UnsupportedRefStorage,
        error.NotABoolean,
        error.NotAnInteger,
        error.MalformedSectionHeader,
        error.InvalidVariableName,
        error.MalformedValue,
        error.IncludeTooDeep,
        error.RemoteUrlInConditionalInclude,
        error.InvalidKey,
        => return null,
        else => |e| return e,
    };
    defer store.deinit();
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

const testgit = @import("../testing/git.zig");

test "a gitlink's refs are read in the format its own configuration names, whatever else its directory holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for (try testgit.refFormats(gpa, io)) |format| {
        var r = try testgit.Repo.init(gpa, io, format.initArgs());
        defer r.deinit();
        try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
        // A stack a files repository never reads, which a reader probing
        // the disk would take for its refs.
        if (format == .files) try r.writeFile(io, ".git/reftable/tables.list", "");
        const text = try r.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(text);
        const ours = (try head(gpa, io, r.dir, "")) orelse return error.TestExpectedHead;
        try std.testing.expect(ours.eql(try Oid.parse(.sha1, text)));
    }
}

test "a gitlink's format refusals are no commit, and its filesystem refusals are errors" {
    const Probe = struct {
        var failure: Io.File.OpenError = error.AccessDenied;
        fn openFile(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
            return failure;
        }
        fn store(g: *const GitDir, io: Io) !void {
            var refs = try g.refStore(std.testing.allocator, io);
            defer refs.deinit();
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var vtable = Io.failing.vtable.*;
    vtable.dirOpenFile = Probe.openFile;
    const io: Io = .{ .userdata = null, .vtable = &vtable };
    const g: GitDir = .{ .git_dir = tmp.dir, .common_dir = tmp.dir, .common_is_separate = false, .via_file = false };
    for ([_]Io.File.OpenError{ error.AccessDenied, error.Canceled }) |err| {
        Probe.failure = err;
        try std.testing.expectError(err, Probe.store(&g, io));
    }
    // No configuration is a version 0 repository's.
    Probe.failure = error.FileNotFound;
    try Probe.store(&g, io);

    const real = std.testing.io;
    try tmp.dir.writeFile(real, .{ .sub_path = "config", .data = "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tunknown = yes\n" });
    try std.testing.expectError(error.UnsupportedExtension, Probe.store(&g, real));
}
