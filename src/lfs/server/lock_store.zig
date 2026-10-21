//! A repository's LFS locks as a server keeps them: in
//! `<git dir>/lfs/locks.json`, a JSON array as git-lfs writes its cache,
//! replaced under git's lock file. The HTTP locking API (`../server.zig`) and
//! git-lfs's pure-ssh protocol (`server/transfer.zig`) keep them here alike.
//! This is package plumbing, reached by no public name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../../fs/fs.zig");
const locks = @import("../locks.zig");

/// Errors from reading and replacing the locks.
pub const Error = error{
    /// The file is not a list of locks: one another writer left cut short
    /// is refused rather than read as none.
    LfsStoreFailed,
    UnwritableTime,
} || Allocator.Error || Io.Cancelable || fs.LockFile.OpenError || fs.CommitError ||
    Io.Dir.CreateDirPathError || Io.Dir.ReadFileAllocError || Io.File.Writer.Error;

const dir_name = "lfs";
const name = "lfs/locks.json";

/// The locks as they are now, in `arena`.
pub fn read(arena: Allocator, io: Io, git_dir: Io.Dir) Error![]const locks.Lock {
    const bytes = (try fs.readFileAlloc(arena, io, git_dir, name, 64 << 20)) orelse return &.{};
    const page = locks.parseListPage(arena, bytes) catch return error.LfsStoreFailed;
    return page.locks;
}

/// The locks, held under git's lock file until `save` or `deinit`.
pub const Table = struct {
    io: Io,
    file: fs.LockFile,
    buffer: [4096]u8,
    list: []const locks.Lock,

    /// Take the locks of the repository at `git_dir`, read into `arena`.
    /// The table is `arena`'s, and its file `gpa`'s until `deinit`.
    pub fn take(gpa: Allocator, arena: Allocator, io: Io, git_dir: Io.Dir) Error!*Table {
        const t = try arena.create(Table);
        try git_dir.createDirPath(io, dir_name);
        t.* = .{ .io = io, .file = undefined, .buffer = undefined, .list = &.{} };
        t.file = try fs.LockFile.open(gpa, io, git_dir, .{ .sub_path = name, .buffer = &t.buffer }, .{
            .on_contention = .{ .wait = .fromSeconds(10) },
            .sync = .per_file,
        });
        errdefer t.file.deinit(io);
        t.list = try read(arena, io, git_dir);
        return t;
    }

    /// Replace the locks with `list`.
    pub fn save(t: *Table, list: []const locks.Lock) Error!void {
        locks.writeLockList(t.file.writer(), list) catch |err| switch (err) {
            error.WriteFailed => return t.file.file_writer.err orelse error.WriteFailed,
            error.UnwritableTime => return error.UnwritableTime,
        };
        try t.file.commit(t.io);
    }

    pub fn deinit(t: *Table) void {
        t.file.deinit(t.io);
    }
};

/// The page of `list` that starts at the lock whose id is `cursor` (the
/// first lock without one), `limit` long, and the id the next starts at.
pub fn paged(list: []const locks.Lock, cursor: ?[]const u8, limit: usize) Page {
    var from: usize = 0;
    if (cursor) |id| {
        from = for (list, 0..) |l, i| {
            if (std.mem.eql(u8, l.id, id)) break i;
        } else list.len;
    }
    const end = from + @min(limit, list.len - from);
    return .{ .locks = list[from..end], .next = if (end < list.len) list[end].id else null };
}

pub const Page = struct { locks: []const locks.Lock, next: ?[]const u8 };
