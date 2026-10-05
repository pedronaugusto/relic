const std = @import("std");
const fs = @import("../repo/fs.zig");
pub fn writeFile(file: anytype, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, shared: fs.Shared) !void {
    const bytes = try file.render();
    defer file.gpa.free(bytes);
    var buffer: [16 * 1024]u8 = undefined;
    var lock = try fs.LockFile.open(file.gpa, io, dir, sub_path, &buffer, .{ .shared = shared });
    defer lock.deinit(io);
    // git gives the new file the mode the old one had
    if (std.Io.File.Permissions.has_executable_bit) {
        if (dir.statFile(io, sub_path, .{})) |st| {
            dir.setFilePermissions(io, lock.lock_name, st.permissions, .{}) catch {};
        } else |_| {}
    }
    lock.writer().writeAll(bytes) catch return error.WriteFailed;
    try lock.commit(io);
}
