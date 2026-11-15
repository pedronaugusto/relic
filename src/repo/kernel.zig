//! The kernel's name, as uname(3)'s `sysname` gives it: on FreeBSD, where
//! Zig's std has no utsname, the `kern.ostype` sysctl, the one call std's
//! checked layer does not give the repository.
//! Package plumbing, reached by no public name.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");

/// What holds a kernel's name: SYS_NMLN, the size uname gives it.
pub const Buffer = [256]u8;

/// The kernel's name, in `buffer` or in std's own record of it.
pub fn name(buffer: *Buffer) []const u8 {
    if (builtin.target.os.tag == .freebsd) {
        var len: usize = buffer.len;
        if (std.c.sysctlbyname("kern.ostype", buffer, &len, null, 0) != 0)
            aegis.assert.never("kern.ostype is a string the kernel always has, shorter than SYS_NMLN; git dies where uname does");
        return std.mem.sliceTo(buffer[0..len], 0);
    }
    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const len = @min(sysname.len, buffer.len);
    @memcpy(buffer[0..len], sysname[0..len]);
    return buffer[0..len];
}
