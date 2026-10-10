//! Object database construction. Registration transfers a source's handles;
//! an own-only open never follows the alternates file.
//! This is package plumbing, reached by no public name.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const odb = @import("policy.zig");
const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const storage = @import("state.zig");

pub fn empty(comptime Odb: type, gpa: Allocator, io: Io, kind: hash.Kind, options: odb.Options) odb.Error!Odb {
    _ = io;
    return .{ ._state = try storage.create(gpa, kind, options) };
}

/// The caller owns `dir` until append succeeds; the database owns it after.
/// The pack directory is acquired here and follows the same transfer.
pub fn register(io: Io, db: anytype, dir: Io.Dir, writable: bool) odb.Error!void {
    const gpa = storage.get(db._state).gpa;
    const real_path = try realPath(gpa, io, dir);
    errdefer gpa.free(real_path);
    const pack_dir = try openDirectory(io, dir, "pack");
    errdefer if (pack_dir) |d| d.close(io);
    try storage.get(db._state).sources.append(gpa, .{
        .dir = dir,
        .real_path = real_path,
        .pack_dir = pack_dir,
        .packs = .empty,
        .writable = writable,
        .midx = null,
        .midx_packs = .empty,
    });
}

/// Where `dir` is, with every link resolved, as git compares alternates;
/// empty, and so equal to no other, where the platform cannot say.
pub fn realPath(gpa: Allocator, io: Io, dir: Io.Dir) Allocator.Error![]u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = dir.realPathFile(io, ".", &buffer) catch return &.{};
    return gpa.dupe(u8, buffer[0..len]);
}

pub fn openOwn(comptime Odb: type, gpa: Allocator, io: Io, git_dir: Io.Dir, kind: hash.Kind, options: odb.Options) odb.Error!Odb {
    var db = try empty(Odb, gpa, io, kind, options);
    errdefer db.deinit(io);
    const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    errdefer if (storage.get(db._state).sources.items.len == 0) objects.close(io);
    try register(io, &db, objects, true);
    try db.refresh(io);
    if (options.probe_timestamp_resolution) db.timestamp_resolution = fs.probeTimestampResolution(io, objects);
    return db;
}

/// Missing directories may disappear under a concurrent collector; a
/// directory refused by the filesystem cannot count as an empty source.
pub fn openDirectory(io: Io, dir: Io.Dir, path: []const u8) Io.Dir.OpenError!?Io.Dir {
    return dir.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
}

pub fn exists(io: Io, dir: Io.Dir, path: []const u8) Io.Dir.AccessError!bool {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Optional accelerators and hints may ignore malformed data, but not a
/// refusal to obtain its bytes. These errors keep their original names.
pub fn readRefusal(err: anyerror) bool {
    const ReadError = Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileAllocError ||
        Io.Dir.Iterator.Error || Io.File.OpenError || Io.File.Reader.Error || Io.Reader.Error;
    inline for (@typeInfo(ReadError).error_set.error_names.?) |name| {
        if (err == @field(ReadError, name)) return true;
    }
    return false;
}

/// All errors reported by this namespace.
pub const Error = odb.Error || Allocator.Error || Io.Dir.OpenError || Io.Dir.AccessError;
