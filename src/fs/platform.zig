//! The platform calls the file layer needs and `std.Io` does not give it:
//! the process umask, the effective user, the process id, Windows' hard
//! link, a file's owner against the user's token, and a handle opened for
//! a file's attributes alone. Each is the raw call and what it reports,
//! nothing more; what git makes of it is `fs.zig`'s.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

/// The process's umask, as git reads it for `tar.umask=user`: set to zero
/// and put back at once, the only way POSIX gives to read it, so a file
/// another thread creates in that moment is made without it. Windows has
/// no umask, and git there reads zero.
pub fn processUmask() u32 {
    switch (builtin.target.os.tag) {
        .windows => return 0,
        .linux => if (!builtin.link_libc) {
            const linux = std.os.linux;
            const old = linux.syscall1(.umask, 0);
            _ = linux.syscall1(.umask, old);
            return @intCast(old & 0o7777);
        },
        else => {},
    }
    const old = std.c.umask(0);
    _ = std.c.umask(old);
    return @intCast(old & 0o7777);
}

/// The process's effective user id, or `null` where the platform cannot
/// say: a POSIX build without libc beyond Linux.
pub fn effectiveUid() ?u32 {
    return switch (builtin.target.os.tag) {
        .linux => std.os.linux.geteuid(),
        else => if (builtin.link_libc) std.c.geteuid() else null,
    };
}

/// This process's id.
pub fn currentPid() u32 {
    return switch (builtin.target.os.tag) {
        .windows => windows.GetCurrentProcessId(),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
}

test "currentPid uses the host process API" {
    const expected: u32 = switch (builtin.target.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
    try std.testing.expectEqual(expected, currentPid());
}

/// Win32's `CreateHardLinkW`: `new_path` made a name of `old_path`'s file,
/// both absolute and prefixed. Whether it was.
pub fn createHardLink(new_path: [:0]const u16, old_path: [:0]const u16) bool {
    return CreateHardLinkW(new_path.ptr, old_path.ptr, null).toBool();
}

extern "kernel32" fn CreateHardLinkW(new_path: [*:0]const u16, old_path: [*:0]const u16, security_attributes: ?*anyopaque) callconv(.winapi) windows.BOOL;

const se_file_object: c_int = 1;
const owner_security_information: u32 = 0x1;
const dacl_security_information: u32 = 0x4;
const token_query: u32 = 0x8;
const token_user: c_int = 1;
const token_linked_token: c_int = 19;
const win_builtin_administrators_sid: c_int = 26;

extern "advapi32" fn GetNamedSecurityInfoW(object_name: [*:0]const u16, object_type: c_int, info: u32, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: ?*?*anyopaque, sacl: ?*?*anyopaque, descriptor: ?*?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn OpenProcessToken(process: windows.HANDLE, access: u32, token: *windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "advapi32" fn GetTokenInformation(token: windows.HANDLE, class: c_int, info: ?*anyopaque, length: u32, returned: *u32) callconv(.winapi) windows.BOOL;
extern "advapi32" fn IsValidSid(sid: *anyopaque) callconv(.winapi) windows.BOOL;
extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) windows.BOOL;
extern "advapi32" fn IsWellKnownSid(sid: *anyopaque, kind: c_int) callconv(.winapi) windows.BOOL;
extern "advapi32" fn CheckTokenMembership(token: ?windows.HANDLE, sid: *anyopaque, member: *windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

/// `TOKEN_USER`: the user's SID and its attributes, and room after them
/// for the SID itself, which the call writes into the same buffer.
const TokenUser = extern struct {
    sid: ?*anyopaque,
    attributes: u32,
    room: [240]u8,
};

/// TOKEN_LINKED_TOKEN: the handle of the token linked to an elevated or
/// filtered one, which `GetTokenInformation` writes in place.
const LinkedToken = extern struct { token: windows.HANDLE };

/// Whether the file at `path`, absolute, is the current user's, as git's
/// `is_path_owned_by_current_user` asks Windows: its owner is the user's
/// SID, or the Administrators group when the user is one (or its token's
/// linked, elevated token is). A file that cannot be asked about is not.
pub fn ownedByCurrentUser(path: [:0]const u16) bool {
    var owner: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    if (GetNamedSecurityInfoW(path.ptr, se_file_object, owner_security_information | dacl_security_information, &owner, null, null, null, &descriptor) != 0) return false;
    // LocalFree's answer is the memory it could not free, and the
    // descriptor is never used again either way.
    defer _ = LocalFree(descriptor);
    const sid = owner orelse return false;
    if (!IsValidSid(sid).toBool()) return false;
    var token: windows.HANDLE = undefined;
    if (!OpenProcessToken(windows.GetCurrentProcess(), token_query, &token).toBool()) return false;
    defer windows.CloseHandle(token);
    var user: TokenUser = undefined;
    var size: u32 = 0;
    if (GetTokenInformation(token, token_user, &user, @sizeOf(TokenUser), &size).toBool()) {
        if (user.sid) |user_sid| if (IsValidSid(user_sid).toBool() and EqualSid(sid, user_sid).toBool()) return true;
    }
    if (IsWellKnownSid(sid, win_builtin_administrators_sid).toBool()) {
        var member: windows.BOOL = .FALSE;
        if (CheckTokenMembership(null, sid, &member).toBool() and member.toBool()) return true;
        var linked: LinkedToken = undefined;
        if (GetTokenInformation(token, token_linked_token, &linked, @sizeOf(LinkedToken), &size).toBool()) {
            defer windows.CloseHandle(linked.token);
            if (CheckTokenMembership(linked.token, sid, &member).toBool() and member.toBool()) return true;
        }
    }
    return false;
}

/// Errors from `openAttributes`.
pub const OpenAttributesError = Io.Dir.PathNameError || Io.Cancelable || error{ FileNotFound, AccessDenied, Unexpected };

/// A handle to `sub_path`, a file or a directory, that may read and write
/// its attributes and times and do nothing else, which Windows grants on a
/// read-only file too. The caller closes it.
pub fn openAttributes(dir: Io.Dir, sub_path: []const u8) OpenAttributesError!Io.File {
    const path_w = try Io.Threaded.sliceToPrefixedFileW(dir.handle, sub_path, .{});
    const span = path_w.span();
    var object_name = windows.UNICODE_STRING.init(span);
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
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
        .{ .IO = .SYNCHRONOUS_NONALERT },
        null,
        0,
    )) {
        .SUCCESS => return .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .ACCESS_DENIED, .SHARING_VIOLATION => return error.AccessDenied,
        else => |status| return windows.unexpectedStatus(status),
    }
}
