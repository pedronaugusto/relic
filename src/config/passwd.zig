//! The password database, asked for a user's home directory: the one call
//! std's checked layer does not give the configuration (`getpwnam_r`).
//! Package plumbing, reached by no public name.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Errors from `home`.
pub const Error = error{
    /// No home can be asked of this platform, or the database has no such
    /// user, or its record names no home.
    UnexpandablePath,
} || Allocator.Error;

/// The home directory of `user`, from the password database, where the
/// platform has one this can ask. The result is the caller's.
pub fn home(gpa: Allocator, user: []const u8) Error![]u8 {
    if (comptime !builtin.link_libc or builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.UnexpandablePath;
    const name = try gpa.dupeSentinel(u8, user, 0);
    defer gpa.free(name);
    // The reentrant call: a library's caller may have threads.
    var entry: std.c.passwd = undefined;
    var found: ?*std.c.passwd = null;
    const buffer = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(buffer);
    if (std.c.getpwnam_r(name, &entry, buffer.ptr, buffer.len, &found) != 0) return error.UnexpandablePath;
    const record = found orelse return error.UnexpandablePath;
    const dir = record.dir orelse return error.UnexpandablePath;
    return gpa.dupe(u8, std.mem.span(dir));
}
