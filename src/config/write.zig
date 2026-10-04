const std = @import("std");
const fs = @import("../repo/fs.zig");
pub fn writeFile(file: anytype, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !void {
    const bytes = try file.render();
    defer file.gpa.free(bytes);
    var buffer: [16 * 1024]u8 = undefined;
    var lock = try fs.LockFile.open(file.gpa, io, dir, sub_path, &buffer, .{});
    defer lock.deinit(io);
    lock.writer().writeAll(bytes) catch return error.WriteFailed;
    try lock.commit(io);
}
