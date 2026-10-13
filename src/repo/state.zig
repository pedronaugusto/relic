//! The state files an operation keeps in the git directory while it is
//! under way (`MERGE_MSG`, `rebase-merge/`, `sequencer/`, `BISECT_LOG`, …):
//! one owner for writing, reading and removing them.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../fs/fs.zig");

/// All errors reported by this namespace.
pub const Error = fs.AtomicWriteError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError;

/// Replace the state file `sub_path` under `dir` with `bytes`, making the
/// directories above it. State files are written unsynced, as git writes
/// them.
pub fn write(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8) Self.Error!void {
    if (std.Io.Dir.path.dirnamePosix(sub_path)) |parent| {
        dir.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    try fs.atomicWrite(io, dir, sub_path, bytes, .{ .prefix = ".relic-", .sync = .none });
}

/// The state file `sub_path` under `dir`, or `null`. The bytes are the
/// caller's.
pub fn read(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.ReadFileAllocError!?[]u8 {
    return fs.readFileAlloc(gpa, io, dir, sub_path, 64 << 20);
}

/// Remove the state file `sub_path` under `dir`, which need not exist.
pub fn remove(io: Io, dir: Io.Dir, sub_path: []const u8) Self.Error!void {
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |e| return e,
    };
}

/// Whether the state file or directory `sub_path` under `dir` is there.
pub fn exists(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}
