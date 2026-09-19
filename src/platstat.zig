//! The three stat fields `std.Io` does not report.
//!
//! git's index carries `dev`, `uid` and `gid`, and stock `git status`
//! compares all three unless `core.checkStat` is set to `minimal`. A library
//! that writes zeros there makes the next `git status` treat every entry as
//! needing a refresh and re-hash the whole working tree — `core.checkStat`'s
//! own documentation names a library that did this and offers `minimal` as the
//! workaround. relic does not want that workaround, so it takes these three
//! fields from the platform.
//!
//! This is the one place the package goes around `std.Io`, and it goes around
//! it only for fields `std.Io.File.Stat` does not carry. Everything that can
//! come from `std.Io` does.

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
            // git stores the whole `st_dev`, which on Linux packs the major
            // and minor the way `makedev` does.
            const dev = (@as(u64, statx.dev_major) << 8) | (statx.dev_minor & 0xff) |
                ((@as(u64, statx.dev_minor) & ~@as(u64, 0xff)) << 12);
            return .{
                .dev = @truncate(dev),
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
