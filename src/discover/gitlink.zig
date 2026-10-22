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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const shakedown = @import("shakedown");

const hash = @import("../hash/hash.zig");
const refs_mod = @import("../refs/refs.zig");
const repository_format = @import("format.zig");
const gitfile = @import("gitfile.zig");
const directory = @import("directory.zig");

const Oid = hash.Oid;

/// Errors from looking at a gitlink's directory: the filesystem's. A ref
/// that does not parse is a `HEAD` that names nothing, not an error.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    refs_mod.ReadError;

/// A submodule's repository, found from its working tree.
pub const GitDir = struct {
    pub const Error = ErrorNamespace.Error;

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
    pub fn deinit(g: *GitDir, io: Io) void {
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
        return refs_mod.Store.init(gpa, format.kind, g.git_dir, g.common_dir, .{ .format = format.ref_storage });
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
        const target = (gitfile.read(gpa, io, work, ".git") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        }) orelse return null;
        defer gpa.free(target);
        via_file = true;
        break :blk gitfile.open(io, work, target, .{ .iterate = true }) catch return null;
    };
    if (!directory.isGitDirectory(io, git_dir)) {
        git_dir.close(io);
        return null;
    }

    var result: GitDir = .{
        .git_dir = git_dir,
        .common_dir = git_dir,
        .common_is_separate = false,
        .via_file = via_file,
    };
    // `isGitDirectory` opened it already: one that does not open is not a
    // git directory, and was refused there.
    if (directory.openCommon(io, git_dir) catch null) |dir| {
        result.common_dir = dir;
        result.common_is_separate = true;
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
    found.deinit(io);
    return true;
}

/// The commit `HEAD` resolves to in the repository whose working tree is
/// `path`, or `null` when there is no repository there, its format is one
/// this release does not read, or its `HEAD` does not name a commit.
pub fn head(gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8) Self.Error!?Oid {
    var found = (try open(gpa, io, wt, path)) orelse return null;
    defer found.deinit(io);
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
        error.UnexpandablePath,
        error.RelativeIncludeOutsideFile,
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
        fn store(g: *const GitDir, io: Io) !void {
            var refs = try g.refStore(std.testing.allocator, io);
            defer refs.deinit();
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Every open refused, and every other call failing.
    const faults = try shakedown.FaultIo.init(std.testing.allocator, Io.failing, .{});
    defer faults.deinit();
    const io = faults.io();
    const g: GitDir = .{ .git_dir = tmp.dir, .common_dir = tmp.dir, .common_is_separate = false, .via_file = false };
    for ([_]Io.File.OpenError{ error.AccessDenied, error.Canceled, error.FileNotFound }) |err| {
        const plan = [_]shakedown.IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .{ .fail = err }, .times = 0 }};
        try faults.setPlan(&plan);
        // No configuration is a version 0 repository's.
        if (err == error.FileNotFound) try Probe.store(&g, io) else try std.testing.expectError(err, Probe.store(&g, io));
    }

    const real = std.testing.io;
    try tmp.dir.writeFile(real, .{ .sub_path = "config", .data = "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tunknown = yes\n" });
    try std.testing.expectError(error.UnsupportedExtension, Probe.store(&g, real));
}
