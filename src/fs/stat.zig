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
//! This is the one place the package goes around `std.Io`, and it goes around
//! it only where `std.Io.File.Stat` cannot answer. Everything that can come
//! from `std.Io` does.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The fields `std.Io.File.Stat` leaves out.
pub const Extra = struct {
    dev: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
};

/// Whether this platform reports the three fields at all.
///
/// False on Windows, where git's own port writes zeros, and on WASI.
pub const supported = switch (builtin.target.os.tag) {
    .windows, .wasi => false,
    .linux => true,
    else => builtin.link_libc,
};

/// Everything one platform stat call reports about a path.
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
    /// The path is not there. Distinguished from `unavailable` because it is
    /// the common answer and needs no second call to confirm.
    absent,
    /// This platform does not report these fields, or the call failed for a
    /// reason the caller should see as an error. Ask `std.Io` instead.
    /// Never the answer on Windows, which says `failed` instead.
    unavailable,
    /// Windows only: the stat could not be taken, for this reason. There
    /// `std.Io` is no second way to ask: its stat describes the file
    /// otherwise (no attributes, the attribute-change time, a link's size as
    /// zero), so an answer from it would be another stat, not this one taken
    /// again, and a walk would see a different working tree when the first
    /// call failed.
    failed: Error,
};

/// One stat of `sub_path` relative to `dir`, without following a symlink.
///
/// `unavailable` is the answer on a platform that has no such call and on any
/// failure that is not a missing path, so the caller falls back to `std.Io`
/// and gets its named error rather than a guess.
pub fn full(io: Io, dir: Io.Dir, sub_path: []const u8) FullResult {
    if (builtin.target.os.tag == .windows) return fullWindows(io, dir, sub_path);
    if (!supported) return .unavailable;
    var path_buf: [4096]u8 = undefined;
    if (sub_path.len >= path_buf.len) return .unavailable;
    @memcpy(path_buf[0..sub_path.len], sub_path);
    path_buf[sub_path.len] = 0;
    const path: [*:0]const u8 = path_buf[0..sub_path.len :0].ptr;

    switch (builtin.target.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var statx: linux.Statx = std.mem.zeroes(linux.Statx);
            const mask: linux.STATX = .{
                .TYPE = true,
                .MODE = true,
                .INO = true,
                .SIZE = true,
                .UID = true,
                .GID = true,
                .MTIME = true,
                .CTIME = true,
            };
            const rc = linux.statx(
                dir.handle,
                path,
                linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT,
                mask,
                &statx,
            );
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .NOENT, .NOTDIR => return .absent,
                else => return .unavailable,
            }
            return .{ .found = .{
                .mtime_ns = @as(i128, statx.mtime.sec) * std.time.ns_per_s + statx.mtime.nsec,
                .ctime_ns = @as(i128, statx.ctime.sec) * std.time.ns_per_s + statx.ctime.nsec,
                .size = statx.size,
                .inode = statx.ino,
                .file_id = statx.ino,
                .mode = statx.mode,
                .permissions = modePermissions(statx.mode),
                .kind = kindFromMode(statx.mode),
                .extra = .{
                    .dev = @truncate(linuxDev(statx)),
                    .uid = @truncate(statx.uid),
                    .gid = @truncate(statx.gid),
                },
            } };
        },
        else => {
            if (!builtin.link_libc) return .unavailable;
            var st: std.c.Stat = std.mem.zeroes(std.c.Stat);
            const rc = std.c.fstatat(dir.handle, path, &st, std.c.AT.SYMLINK_NOFOLLOW);
            if (rc != 0) return switch (std.posix.errno(rc)) {
                .NOENT, .NOTDIR => .absent,
                else => .unavailable,
            };
            const mtime = st.mtime();
            const ctime = st.ctime();
            return .{ .found = .{
                .mtime_ns = @as(i128, mtime.sec) * std.time.ns_per_s + mtime.nsec,
                .ctime_ns = @as(i128, ctime.sec) * std.time.ns_per_s + ctime.nsec,
                .size = @intCast(@max(st.size, 0)),
                .inode = st.ino,
                .file_id = st.ino,
                .mode = st.mode,
                .permissions = modePermissions(st.mode),
                .kind = kindFromMode(st.mode),
                .extra = .{
                    .dev = deviceBits(st.dev),
                    .uid = @truncate(st.uid),
                    .gid = @truncate(st.gid),
                },
            } };
        },
    }
}

/// The permissions a POSIX mode names, as `std.Io`'s type holds them.
pub fn modePermissions(mode: u32) Io.File.Permissions {
    return if (Io.File.Permissions.has_executable_bit) .fromMode(@intCast(mode & 0o7777)) else .default_file;
}

/// git for Windows' `mingw_lstat`, through one handle opened to read
/// attributes and nothing else, on the link itself rather than its target.
fn fullWindows(io: Io, dir: Io.Dir, sub_path: []const u8) FullResult {
    const windows = std.os.windows;
    var path_w = Io.Threaded.sliceToPrefixedFileW(dir.handle, sub_path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => |e| .{ .failed = e },
    };
    // The directory itself is the empty name relative to it; Windows has no
    // `.`.
    if (std.mem.eql(u8, sub_path, ".")) path_w.len = 0;
    const span = path_w.span();
    var object_name = windows.UNICODE_STRING.init(span);
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
        },
        &.{
            .RootDirectory = if (Io.Dir.path.isAbsoluteWindowsWtf16(span)) null else dir.handle,
            .ObjectName = &object_name,
        },
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
        null,
        0,
    )) {
        .SUCCESS => {},
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND, .NOT_A_DIRECTORY => return .absent,
        // git's `mingw_lstat` names these EACCES; a file being deleted is one
        // of them there too.
        .ACCESS_DENIED, .SHARING_VIOLATION, .DELETE_PENDING => return .{ .failed = error.AccessDenied },
        .OBJECT_NAME_INVALID => return .{ .failed = error.BadPathName },
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return .{ .failed = error.NetworkNotFound },
        .VIRUS_INFECTED, .VIRUS_DELETED => return .{ .failed = error.AntivirusInterference },
        .INSUFFICIENT_RESOURCES => return .{ .failed = error.SystemResources },
        else => return .{ .failed = error.Unexpected },
    }
    defer windows.CloseHandle(handle);

    var info: windows.FILE.ALL_INFORMATION = undefined;
    switch (windows.ntdll.NtQueryInformationFile(handle, &iosb, &info, @sizeOf(windows.FILE.ALL_INFORMATION), .All)) {
        // More than the buffer holds is the name, which this does not use.
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return .{ .failed = error.AccessDenied },
        else => return .{ .failed = error.Unexpected },
    }
    const attributes = info.BasicInformation.FileAttributes;
    // git's `file_attr_to_st_mode` makes a link of a symbolic link's tag
    // alone, and every other reparse point (a cloud placeholder, a
    // deduplicated file, WSL's own links) the file or directory its
    // attributes say. A junction is a link here too, as `std.Io`'s directory
    // listing reads it, so a walk never goes through one.
    const kind: Io.File.Kind = if (attributes.REPARSE_POINT) kind: {
        var tag: windows.FILE.ATTRIBUTE_TAG_INFO = undefined;
        switch (windows.ntdll.NtQueryInformationFile(handle, &iosb, &tag, @sizeOf(windows.FILE.ATTRIBUTE_TAG_INFO), .AttributeTag)) {
            .SUCCESS => {},
            .ACCESS_DENIED => return .{ .failed = error.AccessDenied },
            else => return .{ .failed = error.Unexpected },
        }
        const link = @as(u32, @bitCast(tag.ReparseTag)) == @as(u32, @bitCast(windows.IO_REPARSE_TAG.SYMLINK)) or
            @as(u32, @bitCast(tag.ReparseTag)) == @as(u32, @bitCast(windows.IO_REPARSE_TAG.MOUNT_POINT));
        break :kind if (link) .sym_link else if (attributes.DIRECTORY) .directory else .file;
    } else if (attributes.DIRECTORY) .directory else .file;

    // git's `file_attr_to_st_mode`: read for the owner always, write unless
    // read-only, and no execute bit anywhere.
    const type_bits: u32 = switch (kind) {
        .sym_link => 0o120000,
        .directory => 0o040000,
        else => 0o100000,
    };
    const mode: u32 = type_bits | 0o400 | @as(u32, if (attributes.READONLY) 0 else 0o200);
    // A link's size is its target's length, as `lstat` gives it and the
    // index records it. A link that cannot be read fails the stat, as it
    // fails git's.
    const size: u64 = if (kind == .sym_link) size: {
        var target: [Io.Dir.max_path_bytes]u8 = undefined;
        break :size dir.readLink(io, sub_path, &target) catch |err| return switch (err) {
            // Gone, or no longer a link, since the handle above was closed.
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
    } else @bitCast(info.StandardInformation.EndOfFile);
    return .{ .found = .{
        .mtime_ns = windows.fromSysTime(info.BasicInformation.LastWriteTime).nanoseconds,
        .ctime_ns = windows.fromSysTime(info.BasicInformation.CreationTime).nanoseconds,
        .size = size,
        .inode = 0,
        .file_id = @bitCast(info.InternalInformation.IndexNumber),
        .mode = mode,
        .permissions = @fromBackingInt(@as(u32, @bitCast(attributes))),
        .kind = kind,
        .extra = .{},
    } };
}

fn linuxDev(statx: std.os.linux.Statx) u64 {
    // git stores the whole `st_dev`, which on Linux packs the major and minor
    // the way `makedev` does.
    return (@as(u64, statx.dev_major) << 8) | (statx.dev_minor & 0xff) |
        ((@as(u64, statx.dev_minor) & ~@as(u64, 0xff)) << 12);
}

/// The file type the mode bits name.
fn kindFromMode(mode: u32) Io.File.Kind {
    return switch (mode & 0o170000) {
        0o100000 => .file,
        0o040000 => .directory,
        0o120000 => .sym_link,
        0o060000 => .block_device,
        0o020000 => .character_device,
        0o010000 => .named_pipe,
        0o140000 => .unix_domain_socket,
        else => .unknown,
    };
}

/// The three fields for `sub_path` relative to `dir`, without following a
/// symlink.
///
/// Returns zeros rather than an error where the platform does not report
/// them, so a caller never has to branch: zeros are what git's Windows port
/// writes and what `core.checkStat = minimal` ignores.
pub fn statAt(dir: Io.Dir, sub_path: []const u8) Extra {
    if (!supported) return .{};
    var path_buf: [4096]u8 = undefined;
    if (sub_path.len >= path_buf.len) return .{};
    @memcpy(path_buf[0..sub_path.len], sub_path);
    path_buf[sub_path.len] = 0;
    const path: [*:0]const u8 = path_buf[0..sub_path.len :0].ptr;

    switch (builtin.target.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var statx: linux.Statx = std.mem.zeroes(linux.Statx);
            const mask: linux.STATX = .{ .UID = true, .GID = true };
            const rc = linux.statx(
                dir.handle,
                path,
                linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT,
                mask,
                &statx,
            );
            if (linux.errno(rc) != .SUCCESS) return .{};
            return .{
                .dev = @truncate(linuxDev(statx)),
                .uid = @truncate(statx.uid),
                .gid = @truncate(statx.gid),
            };
        },
        else => {
            if (!builtin.link_libc) return .{};
            var st: std.c.Stat = std.mem.zeroes(std.c.Stat);
            const rc = std.c.fstatat(dir.handle, path, &st, std.c.AT.SYMLINK_NOFOLLOW);
            if (rc != 0) return .{};
            return .{
                .dev = deviceBits(st.dev),
                .uid = @truncate(st.uid),
                .gid = @truncate(st.gid),
            };
        },
    }
}

test "the three fields are reported where the platform has them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "x" });
    const extra = statAt(tmp.dir, "a");
    if (supported) {
        // A real file on a real filesystem has a device; uid and gid may
        // legitimately be zero when the test runs as root.
        try std.testing.expect(extra.dev != 0);
    } else {
        try std.testing.expectEqual(@as(u32, 0), extra.dev);
    }
}

test "a missing path is zeros, not an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const extra = statAt(tmp.dir, "not-there");
    try std.testing.expectEqual(@as(u32, 0), extra.dev);
}

/// All errors reported by this namespace: why a Windows stat could not be
/// taken, each a name `std.Io`'s own stat gives the same failure.
pub const Error = error{
    AccessDenied,
    BadPathName,
    NameTooLong,
    NetworkNotFound,
    AntivirusInterference,
    SystemResources,
    Canceled,
    Unexpected,
};

/// `st_dev` as the 32 bits git keeps of it, whether the platform's type is
/// signed (macOS) or unsigned (Linux, FreeBSD).
fn deviceBits(dev: anytype) u32 {
    const T = @TypeOf(dev);
    const bits = @typeInfo(T).int.bits;
    return @truncate(@as(@Int(.unsigned, bits), @bitCast(dev)));
}
