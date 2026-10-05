//! Which repositories git agrees to use: `safe.directory` and
//! `safe.bareRepository`, as git's `setup.c` decides them for a repository
//! it discovers.
//!
//! A discovered repository whose `.git` file, working tree or git directory
//! belongs to another user is used only when `safe.directory` names it — or
//! `*` names every one, `<path>/*` every one under a path, `.` the current
//! directory — and a bare repository is not discovered at all under
//! `safe.bareRepository=explicit` unless it is a `.git` directory, or the
//! git directory of a linked worktree or a submodule. Both are read from the
//! configuration a repository cannot write itself: the system, global and
//! command-line settings, never the repository's own file.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("../config.zig");

/// What is checked of who owns a repository that is discovered.
pub const Ownership = enum {
    /// git's check: the `.git` file, the working tree and the git directory
    /// are each the current user's, or `safe.directory` names the
    /// repository.
    check,
    /// Every path is someone else's, as git takes them under
    /// `GIT_TEST_ASSUME_DIFFERENT_OWNER`: only `safe.directory` lets a
    /// repository open.
    assume_different,
    /// Nothing is checked, as for a repository git is told the git
    /// directory of.
    trust,
};

/// A path as git compares them: `/` between components on every platform.
pub fn normalize(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const copy = try gpa.dupe(u8, path);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

/// `path` with every symbolic link resolved and its last component allowed
/// not to exist, as git's `real_pathdup` resolves it; `null` when it cannot
/// be.
fn realPath(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?[]u8 {
    if (Io.Dir.cwd().realPathFileAlloc(io, path, gpa)) |real| {
        defer gpa.free(real);
        const value = try normalize(gpa, real);
        return value;
    } else |_| {}
    const parent = std.fs.path.dirname(path) orelse return null;
    const base = std.fs.path.basename(path);
    const real_parent = Io.Dir.cwd().realPathFileAlloc(io, parent, gpa) catch return null;
    defer gpa.free(real_parent);
    const joined = try std.fs.path.join(gpa, &.{ real_parent, base });
    defer gpa.free(joined);
    const value = try normalize(gpa, joined);
    return value;
}

/// Whether `safe.directory` in `protected` names the repository at `path`,
/// a real path with `/` separators: git's `safe_directory_cb` over every
/// value in order, an empty one forgetting those before it. `home` expands
/// a leading `~/`.
pub fn directoryIsSafe(gpa: Allocator, io: Io, protected: *const config_mod.Config, path: []const u8, home: ?[]const u8) Allocator.Error!bool {
    var safe = false;
    for (protected.entries.items) |entry| {
        if (!entry.matches("safe", null, "directory")) continue;
        const raw = entry.value orelse {
            safe = false;
            continue;
        };
        const value = config_mod.unquote(gpa, raw) catch continue;
        defer gpa.free(value);
        if (value.len == 0) {
            safe = false;
            continue;
        }
        if (std.mem.eql(u8, value, "*")) {
            safe = true;
            continue;
        }
        var allowed: []const u8 = value;
        var expanded: ?[]u8 = null;
        defer if (expanded) |e| gpa.free(e);
        if (std.mem.startsWith(u8, value, "~/")) {
            const h = home orelse continue;
            expanded = try std.fs.path.join(gpa, &.{ h, value[2..] });
            allowed = expanded.?;
        }
        if (!std.fs.path.isAbsolute(allowed) and !std.mem.eql(u8, allowed, ".")) continue;
        const normalized = (try realPath(gpa, io, allowed)) orelse continue;
        defer gpa.free(normalized);
        if (std.mem.endsWith(u8, normalized, "/*")) {
            const prefix = normalized[0 .. normalized.len - 1];
            if (std.mem.startsWith(u8, path, prefix)) safe = true;
        } else if (std.mem.eql(u8, path, normalized)) safe = true;
    }
    return safe;
}

/// What `safe.bareRepository` allows.
pub const BareRepositories = enum {
    /// Every bare repository, discovered or named: git's default.
    all,
    /// Only one named as the git directory, besides a `.git` directory and
    /// the git directory of a linked worktree or a submodule.
    explicit,
};

/// `safe.bareRepository` in `protected`, the last value git knows.
pub fn bareRepositories(protected: *const config_mod.Config) BareRepositories {
    var result: BareRepositories = .all;
    for (protected.entries.items) |entry| {
        if (!entry.matches("safe", null, "barerepository")) continue;
        const value = entry.value orelse continue;
        if (std.mem.eql(u8, value, "explicit")) result = .explicit;
        if (std.mem.eql(u8, value, "all")) result = .all;
    }
    return result;
}

/// git's `is_implicit_bare_repo`: a bare repository found at `path`, with
/// `/` separators, that is a `.git` directory or the git directory of a
/// linked worktree or a submodule.
pub fn isImplicitBare(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (std.mem.eql(u8, trimmed, ".git") or std.mem.endsWith(u8, trimmed, "/.git")) return true;
    if (std.mem.indexOf(u8, path, "/.git/worktrees/") != null) return true;
    if (std.mem.indexOf(u8, path, "/.git/modules/") != null) return true;
    return false;
}

test "a bare repository is implicit inside a .git directory, a worktree's or a submodule's" {
    try std.testing.expect(isImplicitBare("/a/b/.git"));
    try std.testing.expect(isImplicitBare("/a/b/.git/worktrees/x"));
    try std.testing.expect(isImplicitBare("/a/b/.git/modules/sub"));
    try std.testing.expect(!isImplicitBare("/a/b/repo.git"));
    try std.testing.expect(!isImplicitBare("/a/b"));
}
