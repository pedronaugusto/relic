//! Object database construction. Registration transfers a source's handles;
//! an own-only open never follows the alternates file.
//! This is package plumbing, reached by no public name.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const odb = @import("odb.zig");
const hash = @import("hash.zig");
const fs = @import("fs.zig");

pub fn empty(gpa: Allocator, io: Io, kind: hash.Kind, options: odb.Options) odb.Error!odb.Odb {
    _ = io;
    return .{ ._state = try @import("odbstate.zig").create(gpa, kind, options) };
}

/// The caller owns `dir` until append succeeds; the database owns it after.
/// The pack directory is acquired here and follows the same transfer.
pub fn register(db: *odb.Odb, io: Io, dir: Io.Dir, writable: bool) odb.Error!void {
    const pack_dir = dir.openDir(io, "pack", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
    errdefer if (pack_dir) |d| d.close(io);
    try @import("odbstate.zig").get(db._state).sources.append(@import("odbstate.zig").get(db._state).gpa, .{
        .dir = dir,
        .pack_dir = pack_dir,
        .packs = .empty,
        .writable = writable,
        .midx = null,
        .midx_packs = .empty,
    });
}

pub fn openOwn(gpa: Allocator, io: Io, git_dir: Io.Dir, kind: hash.Kind, options: odb.Options) odb.Error!odb.Odb {
    var db = try empty(gpa, io, kind, options);
    errdefer db.deinit(io);
    const objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    errdefer if (@import("odbstate.zig").get(db._state).sources.items.len == 0) objects.close(io);
    try register(&db, io, objects, true);
    try db.refresh(io);
    if (options.probe_timestamp_resolution) db.timestamp_resolution = fs.probeTimestampResolution(io, objects);
    return db;
}
