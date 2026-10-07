//! The programs the build makes for the suite, by absolute path. The build
//! names each relative to the directory `zig build` runs in, which is the
//! suite's own; a test hands them to programs it starts elsewhere, where
//! only an absolute path still names them.

const std = @import("std");
const build_options = @import("build_options");

pub const Program = enum {
    lock_helper,
    filter_helper,
    lfs_transfer_helper,
    upload_pack_helper,
    hook_fixture,
    fake_ssh_helper,
    lfs_test_tool,
    process_fixture,
    remote_helper,
    lfs_agent,
};

/// One program's path, resolved once.
const Resolved = struct {
    /// Unresolved, being resolved, resolved.
    state: std.atomic.Value(u8) = .init(0),
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,
};

var resolved: std.EnumArray(Program, Resolved) = .initFill(.{});

/// `program`'s absolute path, resolved against the suite's directory on
/// first use and kept for the rest of the run.
pub fn path(comptime program: Program) []const u8 {
    const entry = resolved.getPtr(program);
    if (entry.state.load(.acquire) != 2) {
        if (entry.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            entry.len = absolute(@field(build_options, @tagName(program) ++ "_path"), &entry.buffer);
            entry.state.store(2, .release);
        } else while (entry.state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return entry.buffer[0..entry.len];
}

fn absolute(relative: []const u8, buffer: []u8) usize {
    if (std.Io.Dir.path.isAbsolute(relative)) {
        @memcpy(buffer[0..relative.len], relative);
        return relative.len;
    }
    const cwd_len = std.process.currentPath(std.testing.io, buffer) catch |err|
        std.debug.panic("the suite's directory cannot be read: {t}", .{err});
    const joined = cwd_len + 1 + relative.len;
    if (joined > buffer.len) std.debug.panic("{s}: the absolute path is longer than a path can be", .{relative});
    buffer[cwd_len] = std.Io.Dir.path.sep;
    @memcpy(buffer[cwd_len + 1 ..][0..relative.len], relative);
    return joined;
}

test "each helper's path is absolute and names the program the build made for it" {
    inline for (@typeInfo(Program).@"enum".field_names) |name| {
        const program = @field(Program, name);
        const absolute_path = path(program);
        try std.testing.expect(std.Io.Dir.path.isAbsolute(absolute_path));
        try std.testing.expect(std.mem.endsWith(u8, absolute_path, @field(build_options, name ++ "_path")));
        try std.testing.expectEqual(absolute_path.ptr, path(program).ptr);
        try std.Io.Dir.cwd().access(std.testing.io, absolute_path, .{});
    }
}
