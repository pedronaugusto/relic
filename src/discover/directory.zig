//! What a git directory is, as git's setup asks before it trusts one: its
//! `HEAD` names a ref under `refs/` or an object, and its `objects` and
//! `refs` are there, in the common directory a linked worktree's
//! `commondir` names. One reader of `commondir` for every caller.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Io = std.Io;

/// All errors reported by this namespace.
pub const Error = error{
    /// `commondir` names a directory that cannot be opened.
    BrokenCommonDir,
} || Io.Dir.OpenError;

/// git's `validate_headref`: `HEAD` is a link to a name under `refs/`, a
/// file `ref: refs/...` (spaces allowed after the colon), or a file that
/// starts with an object name of either hash.
pub fn validHead(io: Io, dir: Io.Dir) bool {
    var buf: [256]u8 = undefined;
    if (dir.readLink(io, "HEAD", &buf)) |len| {
        return std.mem.startsWith(u8, buf[0..len], "refs/");
    } else |_| {}
    const text = dir.readFile(io, "HEAD", &buf) catch return false;
    if (std.mem.startsWith(u8, text, "ref:")) {
        const rest = std.mem.trimStart(u8, text["ref:".len..], " \t\n\r\x0b\x0c");
        if (std.mem.startsWith(u8, rest, "refs/")) return true;
    }
    return startsWithHex(text, 40) or startsWithHex(text, 64);
}

/// Whether `text` starts with `n` hex digits, the end or anything but a
/// hex digit after them: git's `get_oid_hex_any`.
fn startsWithHex(text: []const u8, n: usize) bool {
    if (text.len < n) return false;
    for (text[0..n]) |c| if (!std.ascii.isHex(c)) return false;
    return text.len == n or !std.ascii.isHex(text[n]);
}

/// The directory `git_dir`'s `commondir` names, opened, or `null` when it
/// has none: a linked worktree's shared directory. A relative name is taken
/// from `git_dir`, as git's `get_common_dir_noenv` takes it.
pub fn openCommon(io: Io, git_dir: Io.Dir) Self.Error!?Io.Dir {
    var buf: [4096]u8 = undefined;
    const text = git_dir.readFile(io, "commondir", &buf) catch return null;
    const target = std.mem.trimEnd(u8, text, "\r\n");
    if (target.len == 0) return error.BrokenCommonDir;
    const opened = if (std.Io.Dir.path.isAbsolute(target))
        Io.Dir.openDirAbsolute(io, target, .{ .iterate = true })
    else
        git_dir.openDir(io, target, .{ .iterate = true });
    return opened catch |err| switch (err) {
        error.FileNotFound, error.NotDir => error.BrokenCommonDir,
        else => |e| e,
    };
}

/// git's `is_git_directory`: a valid `HEAD`, and `objects` and `refs` in
/// the common directory (`git_dir` itself unless `commondir` names
/// another). A `commondir` that names nothing is not a git directory.
pub fn isGitDirectory(io: Io, dir: Io.Dir) bool {
    if (!validHead(io, dir)) return false;
    const common = openCommon(io, dir) catch return false;
    defer if (common) |c| c.close(io);
    const where = common orelse dir;
    where.access(io, "objects", .{}) catch return false;
    where.access(io, "refs", .{}) catch return false;
    return true;
}
