//! The stat `std.Io` does not report, taken in one call.
//!
//! git's index carries `dev`, `uid` and `gid`, and stock `git status`
//! compares all three unless `core.checkStat` is set to `minimal`. A library
//! that writes zeros there makes the next `git status` treat every entry as
//! needing a refresh and re-hash the whole working tree — `core.checkStat`'s
//! own documentation names a library that did this and offers `minimal` as the
//! workaround. relic does not want that workaround, so it takes those fields
//! from the platform.
//!
//! The call that fetches them already carries everything `std.Io.File.Stat`
//! carries, so `full` returns the whole thing and a walk over a working tree
//! pays one `fstatat` per entry rather than two. `extra` remains for a caller
//! that has the `std.Io` stat already.
//!
//! On Windows the stat is git for Windows' own (`mingw_lstat`): the change
//! time git keeps is the file's creation time, the inode is zero, a link's
//! size is its target's length, and the mode's write bit is the read-only
//! attribute. `std.Io`'s stat there reports the attribute-change time, the
//! file id and no attributes at all, so an index relic wrote would look
//! changed to git in every entry, and the other way round.
//!
//! The platform's stat is airlock's (`airlock.stat`), one call that carries
//! all of it, a test's seam and a simulation's file system included; what
//! is git's here is how its fields are taken.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const airlock = @import("airlock");

/// The fields `std.Io.File.Stat` leaves out.
pub const Extra = struct {
    dev: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
};

/// Everything one platform stat call reports about a path, as git takes it.
///
/// The times are nanoseconds since the epoch, which is the shape
/// `std.Io.File.Stat` uses and the shape the index's split into seconds and
/// nanoseconds is taken from.
pub const Full = struct {
    mtime_ns: i128,
    ctime_ns: i128,
    size: u64,
    /// The inode git's index keeps: zero on Windows, where git's own stat
    /// reports none.
    inode: u64,
    /// The file's identity on its volume, for telling two paths apart: the
    /// inode, or on Windows the file id.
    file_id: u64,
    /// The volume's identity, with `file_id`: the whole device, or on
    /// Windows the volume's serial number.
    device: u64,
    /// The permission and type bits, as the platform reports them, and on
    /// Windows as git for Windows makes them from the attributes.
    mode: u32,
    /// The permissions as `std.Io` sets them: the mode, or on Windows the
    /// file's attributes.
    permissions: Io.File.Permissions,
    kind: Io.File.Kind,
    extra: Extra,
};

/// What a full stat came back as.
pub const FullResult = union(enum) {
    /// The platform answered.
    found: Full,
    /// The path is not there, or a name on the way is not a directory:
    /// git's ENOENT and ENOTDIR, which a walk takes alike.
    absent,
    /// The stat could not be taken, for this reason.
    failed: Error,
};

/// All errors reported by this namespace: why a stat could not be taken.
pub const Error = airlock.StatError;

/// One stat of `sub_path` relative to `dir`, without following a symlink.
pub fn full(io: Io, dir: Io.Dir, sub_path: []const u8) FullResult {
    const s = airlock.stat(io, dir, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .absent,
        // git's `mingw_lstat` names a file in use, or being deleted, EACCES
        error.FileBusy => return .{ .failed = error.AccessDenied },
        else => |e| return .{ .failed = e },
    };
    if (builtin.target.os.tag == .windows) return fullWindows(io, dir, sub_path, s);
    return .{
        .found = .{
            .mtime_ns = s.mtime.nanoseconds,
            .ctime_ns = s.ctime.nanoseconds,
            .size = s.size,
            .inode = s.inode,
            .file_id = s.inode,
            .device = s.device,
            .mode = s.mode,
            .permissions = s.permissions,
            .kind = s.kind,
            // git keeps 32 bits of each
            .extra = .{ .dev = @truncate(s.device), .uid = s.uid, .gid = s.gid },
        },
    };
}

/// The permissions a POSIX mode names, as `std.Io`'s type holds them.
pub fn modePermissions(mode: u32) Io.File.Permissions {
    return if (Io.File.Permissions.has_executable_bit) .fromMode(@intCast(mode & 0o7777)) else .default_file;
}

/// git for Windows' `mingw_lstat` over the platform's stat: the change time
/// is the creation time, the inode zero, the mode made from the attributes,
/// and a link's size its target's length.
fn fullWindows(io: Io, dir: Io.Dir, sub_path: []const u8, s: airlock.Stat) FullResult {
    // airlock's kind is git's `file_attr_to_st_mode`'s but for a junction,
    // which is a link here too, as `std.Io`'s directory listing reads it,
    // so a walk never goes through one.
    const kind = s.kind;
    // git's `file_attr_to_st_mode`: read for the owner always, write unless
    // read-only, and no execute bit anywhere.
    const type_bits: u32 = switch (kind) {
        .sym_link => 0o120000,
        .directory => 0o040000,
        else => 0o100000,
    };
    const read_only = s.attributes & 0x1 != 0; // FILE_ATTRIBUTE_READONLY
    const mode: u32 = type_bits | 0o400 | @as(u32, if (read_only) 0 else 0o200);
    // A link's size is its target's length, as `lstat` gives it and the
    // index records it. A link that cannot be read fails the stat, as it
    // fails git's.
    const size: u64 = if (kind == .sym_link) size: {
        var target: [Io.Dir.max_path_bytes]u8 = undefined;
        break :size dir.readLink(io, sub_path, &target) catch |err| return switch (err) {
            // Gone, or no longer a link, since it was stat'ed.
            error.FileNotFound, error.NotDir => .absent,
            error.AccessDenied, error.PermissionDenied => .{ .failed = error.AccessDenied },
            error.NameTooLong => .{ .failed = error.NameTooLong },
            error.BadPathName => .{ .failed = error.BadPathName },
            error.NetworkNotFound => .{ .failed = error.NetworkNotFound },
            error.AntivirusInterference => .{ .failed = error.AntivirusInterference },
            error.SystemResources => .{ .failed = error.SystemResources },
            error.Canceled => .{ .failed = error.Canceled },
            else => .{ .failed = error.Unexpected },
        };
    } else s.size;
    return .{ .found = .{
        .mtime_ns = s.mtime.nanoseconds,
        .ctime_ns = (s.birth orelse s.ctime).nanoseconds,
        .size = size,
        .inode = 0,
        .file_id = s.inode,
        .device = s.device,
        .mode = mode,
        .permissions = s.permissions,
        .kind = kind,
        .extra = .{},
    } };
}

test "the three fields are reported where the platform has them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "x" });
    const found = full(io, tmp.dir, "a").found;
    if (builtin.target.os.tag == .windows) {
        try std.testing.expectEqual(@as(u32, 0), found.extra.dev);
    } else {
        // A real file on a real filesystem has a device; uid and gid may
        // legitimately be zero when the test runs as root.
        try std.testing.expect(found.extra.dev != 0);
    }
}

test "a missing path, and a path through a file, are absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "x" });
    try std.testing.expect(full(io, tmp.dir, "not-there") == .absent);
    try std.testing.expect(full(io, tmp.dir, "a/below") == .absent);
}
