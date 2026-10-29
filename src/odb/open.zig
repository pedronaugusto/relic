//! Object database construction. Registration transfers a source's handles;
//! an own-only open never follows the alternates file.
//! This is package plumbing, reached by no public name.

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const odb = @import("policy.zig");
const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const storage = @import("state.zig");

pub fn empty(comptime Odb: type, gpa: Allocator, io: Io, kind: hash.Kind, options: odb.Options) odb.Error!Odb {
    _ = io;
    return .{ .state = try storage.create(gpa, kind, options) };
}

/// `dir` made a source of `db`, taken whatever comes of it: held by the
/// source, or closed with the error. Its pack directory is opened here and
/// held with it.
pub fn register(io: Io, db: anytype, dir: *fs.OwnedDir, writable: bool) odb.Error!void {
    errdefer dir.deinit(io);
    const data = storage.get(db.state);
    const gpa = data.gpa;
    const real_path = try realPath(gpa, io, dir.lend().get());
    errdefer gpa.free(real_path);
    var pack_dir = try openDirectory(io, dir.lend().get(), "pack");
    errdefer if (pack_dir) |*d| d.deinit(io);
    const source = try gpa.create(storage.Source);
    errdefer gpa.destroy(source);
    try data.sources.ensureUnusedCapacity(gpa, 1);
    source.* = .{
        .dir = dir.move(),
        .real_path = real_path,
        .pack_dir = if (pack_dir) |*d| d.move() else null,
        .packs = .empty,
        .writable = writable,
        .midx = null,
        .midx_packs = .empty,
    };
    data.sources.appendAssumeCapacity(source);
}

/// Where `dir` is, with every link resolved, as git compares alternates;
/// empty, and so equal to no other, where the platform cannot say. A
/// cancel is returned, never taken for a platform that cannot say.
pub fn realPath(gpa: Allocator, io: Io, dir: Io.Dir) (Allocator.Error || Io.Cancelable)![]u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = dir.realPathFile(io, ".", &buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return &.{},
    };
    return gpa.dupe(u8, buffer[0..len]);
}

pub fn openOwn(comptime Odb: type, gpa: Allocator, io: Io, git_dir: Io.Dir, kind: hash.Kind, options: odb.Options) odb.Error!Odb {
    var db = try empty(Odb, gpa, io, kind, options);
    errdefer db.deinit(io);
    var objects = fs.OwnedDir.init(try git_dir.openDir(io, "objects", .{ .iterate = true }));
    try register(io, &db, &objects, true);
    try db.refresh(io);
    if (options.probe_timestamp_resolution) db.timestamp_resolution = try fs.probeTimestampResolution(io, storage.get(db.state).sources.items[0].directory().get());
    return db;
}

/// Missing directories may disappear under a concurrent collector; a
/// directory refused by the filesystem cannot count as an empty source.
pub fn openDirectory(io: Io, dir: Io.Dir, path: []const u8) Io.Dir.OpenError!?fs.OwnedDir {
    return fs.OwnedDir.init(dir.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    });
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
    const ReadError = Allocator.Error || Io.Dir.OpenError || aegis.own.ReadFileError ||
        Io.Dir.Iterator.Error || Io.File.OpenError || Io.File.Reader.Error || Io.Reader.Error;
    inline for (@typeInfo(ReadError).error_set.error_names.?) |name| {
        if (err == @field(ReadError, name)) return true;
    }
    return false;
}

/// All errors reported by this namespace.
pub const Error = odb.Error || Allocator.Error || Io.Dir.OpenError || Io.Dir.AccessError;
