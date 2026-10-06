//! Locate a child program in a test helper's inherited environment.
//!
//! Git for Windows can hand a native hook `Path` instead of `PATH`. Zig's
//! process launcher looks up the latter, so resolve the executable before
//! starting another native child.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub fn path(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return name;
    if (std.mem.findAny(u8, name, "/\\:") != null) return name;
    const executable = if (std.mem.endsWith(u8, name, ".exe")) name else try std.fmt.allocPrint(arena, "{s}.exe", .{name});
    var path_value: ?[]const u8 = null;
    for (env.keys()) |key| {
        if (std.ascii.eqlIgnoreCase(key, "PATH")) path_value = env.get(key);
    }
    if (path_value) |value| {
        var dirs = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
        while (dirs.next()) |raw| {
            const dir = std.mem.trim(u8, raw, "\"");
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(arena, &.{ dir, executable });
            if (Io.Dir.cwd().openFile(io, candidate, .{})) |file| {
                file.close(io);
                return candidate;
            } else |_| {}
        }
    }
    if (std.mem.eql(u8, name, "git")) {
        if (env.get("GIT_EXEC_PATH")) |dir| {
            const candidate = try std.fs.path.join(arena, &.{ dir, executable });
            if (Io.Dir.cwd().openFile(io, candidate, .{})) |file| {
                file.close(io);
                return candidate;
            } else |_| {}
        }
    }
    return name;
}
