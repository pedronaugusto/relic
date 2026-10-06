//! Barriers for bytes and names. Ordinary writes choose their own policy;
//! durable checkout and selected object closures use this stricter one.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Policy = enum {
    /// Return after writes and renames; the OS decides when they reach disk.
    none,
    /// Sync every selected file, then its directories, before returning.
    /// This costs opens and storage barriers, including a drive-cache flush
    /// on macOS. A filesystem refusing a barrier makes the operation fail.
    durable,
};

pub const Error = Io.File.OpenError || Io.Dir.OpenError || Io.File.SyncError;

pub fn syncFile(io: Io, file: Io.File) Io.File.SyncError!void {
    try file.sync(io);
    if (builtin.os.tag == .macos) {
        // fsync only writes out to the device on macOS. F_FULLFSYNC also
        // asks the device to flush its cache; a refused request is a failure.
        if (std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)) == -1) return error.InputOutput;
    }
}

pub fn syncPath(io: Io, dir: Io.Dir, path: []const u8) Self.Error!void {
    const file = try dir.openFile(io, path, .{ .mode = if (builtin.os.tag == .windows) .read_write else .read_only });
    defer file.close(io);
    try syncFile(io, file);
}

pub fn syncDirectory(io: Io, dir: Io.Dir, path: []const u8) Self.Error!void {
    if (builtin.os.tag == .windows) {
        const file = try openDirectoryWindows(dir, path);
        defer file.close(io);
        try syncFile(io, file);
        return;
    }
    // iterate requests a syncable read descriptor rather than Linux O_PATH.
    const opened = try dir.openDir(io, path, .{ .iterate = true });
    defer opened.close(io);
    try syncFile(io, .{ .handle = opened.handle, .flags = .{ .nonblocking = false } });
}

fn openDirectoryWindows(dir: Io.Dir, path: []const u8) Error!Io.File {
    const windows = std.os.windows;
    const path_w = try Io.Threaded.sliceToPrefixedFileW(dir.handle, path, .{});
    const span = path_w.span();
    var name = windows.UNICODE_STRING.init(span);
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateFile(
        &handle,
        // NtCreateFile requires directory-specific rights rather than
        // generic file rights. ADD_FILE provides the write access to flush.
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE_DIRECTORY = .{
                .ADD_FILE = true,
                .READ_ATTRIBUTES = true,
            } },
        },
        &.{ .RootDirectory = if (Io.Dir.path.isAbsoluteWindowsWtf16(span)) null else dir.handle, .ObjectName = &name },
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .DIRECTORY_FILE = true, .WRITE_THROUGH = true, .IO = .SYNCHRONOUS_NONALERT },
        null,
        0,
    )) {
        .SUCCESS => return .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .ACCESS_DENIED, .SHARING_VIOLATION => return error.AccessDenied,
        else => |status| return windows.unexpectedStatus(status),
    }
}
