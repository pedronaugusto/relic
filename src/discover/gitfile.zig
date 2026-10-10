//! A `.git` file: the `gitdir: <path>` git writes in place of a `.git`
//! directory for a linked worktree and a submodule, read as git's
//! `read_gitfile_gently` reads it, and the one place that text is read or
//! written.

const ErrorNamespace = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../fs/fs.zig");

/// What a `.git` file starts with, the space included, as git writes and
/// requires it.
pub const prefix = "gitdir: ";

/// The largest `.git` file read: git's `max_file_size` for it, 1 MiB.
pub const max_bytes = 1 << 20;

/// The path a `.git` file's text names, or `null` when the text is not one.
/// The text must start with `gitdir: `; the carriage returns and line feeds
/// that end it are not the path's, and every other byte is, spaces
/// included, as git reads it. No path is not a `.git` file.
pub fn target(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const path = std.mem.trimEnd(u8, text[prefix.len..], "\r\n");
    if (path.len == 0) return null;
    return path;
}

/// Errors from reading a `.git` file.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError;

/// The path `<dir>/<sub_path>` names as a `.git` file, in `gpa`; `null` when
/// there is no such file or it is not a `.git` file. One larger than
/// `max_bytes` is not one either, as git refuses it.
pub fn read(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) ErrorNamespace.Error!?[]u8 {
    const text = fs.readFileAlloc(gpa, io, dir, sub_path, max_bytes) catch |err| switch (err) {
        error.StreamTooLong => return null,
        else => |e| return e,
    } orelse return null;
    defer gpa.free(text);
    const path = target(text) orelse return null;
    return try gpa.dupe(u8, path);
}

/// Write `<dir>/.git` naming `path`: `gitdir: <path>` and a line feed, as
/// git writes it.
pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) (Allocator.Error || Io.Dir.WriteFileError)!void {
    std.debug.assert(path.len != 0);
    const line = try std.mem.concat(gpa, u8, &.{ prefix, path, "\n" });
    defer gpa.free(line);
    try dir.writeFile(io, .{ .sub_path = ".git", .data = line });
}

/// The directory `path` names, opened: absolute, as git writes it for a
/// linked worktree, or relative to `dir`, the directory the `.git` file is
/// in, as it writes it for a submodule.
pub fn open(io: Io, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    return if (std.Io.Dir.path.isAbsolute(path)) Io.Dir.openDirAbsolute(io, path, options) else dir.openDir(io, path, options);
}

test "a .git file is read as git reads it" {
    const testing = std.testing;
    try testing.expectEqualStrings("../.git/modules/a", target("gitdir: ../.git/modules/a\n").?);
    try testing.expectEqualStrings("/w/.git/worktrees/x", target("gitdir: /w/.git/worktrees/x\r\n\n").?);
    // The path keeps every byte but the line ending, spaces included.
    try testing.expectEqualStrings(" spaced ", target("gitdir:  spaced \n").?);
    // git requires the space after the colon and nothing before the word.
    try testing.expectEqual(@as(?[]const u8, null), target("gitdir:../x\n"));
    try testing.expectEqual(@as(?[]const u8, null), target(" gitdir: ../x\n"));
    try testing.expectEqual(@as(?[]const u8, null), target("gitdir: \n"));
    try testing.expectEqual(@as(?[]const u8, null), target("ref: refs/heads/main\n"));

    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: inner\n" });
    const read_back = (try read(gpa, io, tmp.dir, ".git")).?;
    defer gpa.free(read_back);
    try testing.expectEqualStrings("inner", read_back);
    try testing.expectEqual(@as(?[]u8, null), try read(gpa, io, tmp.dir, "missing"));
    try tmp.dir.createDirPath(io, "inner");
    var opened = try open(io, tmp.dir, read_back, .{});
    opened.close(io);
    try write(gpa, io, tmp.dir, "elsewhere/.git");
    const written = (try read(gpa, io, tmp.dir, ".git")).?;
    defer gpa.free(written);
    try testing.expectEqualStrings("elsewhere/.git", written);
}
