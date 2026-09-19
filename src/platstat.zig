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
pub const supported = switch (builtin.os.tag) {
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
    inode: u64,
    /// The permission and type bits, as the platform reports them.
    mode: u32,
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
    unavailable,
};

/// One stat of `sub_path` relative to `dir`, without following a symlink.
///
/// `unavailable` is the answer on a platform that has no such call and on any
/// failure that is not a missing path, so the caller falls back to `std.Io`
/// and gets its named error rather than a guess.
pub fn full(dir: Io.Dir, sub_path: []const u8) FullResult {
    if (!supported) return .unavailable;
    var path_buf: [4096]u8 = undefined;
    if (sub_path.len >= path_buf.len) return .unavailable;
    @memcpy(path_buf[0..sub_path.len], sub_path);
    path_buf[sub_path.len] = 0;
    const path: [*:0]const u8 = @ptrCast(&path_buf);

    switch (builtin.os.tag) {
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
                .mode = statx.mode,
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
                .mode = st.mode,
                .kind = kindFromMode(st.mode),
                .extra = .{
                    .dev = @truncate(@as(u64, @bitCast(@as(i64, st.dev)))),
                    .uid = @truncate(st.uid),
                    .gid = @truncate(st.gid),
                },
            } };
        },
    }
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
    const path: [*:0]const u8 = @ptrCast(&path_buf);

    switch (builtin.os.tag) {
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
                .dev = @truncate(@as(u64, @bitCast(@as(i64, st.dev)))),
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
