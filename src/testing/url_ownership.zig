const std = @import("std");
const testing = std.testing;
const testgit = @import("git.zig");
const local = @import("../transport/local.zig");
test "encoded file URL paths reach the same repository as Git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    try fixture.exec(io, &.{ "init", "-q", "--bare", "a b%20" });
    const path = try fixture.dir.realPathFileAlloc(io, "a b%20", gpa);
    defer gpa.free(path);
    const escaped_percent = try std.mem.replaceOwned(u8, gpa, path, "%", "%25");
    defer gpa.free(escaped_percent);
    const escaped = try std.mem.replaceOwned(u8, gpa, escaped_percent, " ", "%20");
    defer gpa.free(escaped);
    const text = try gpa.print("file://{s}", .{escaped});
    defer gpa.free(text);
    try fixture.exec(io, &.{ "ls-remote", text });
    var remote = try local.Remote.open(gpa, io, text, .{});
    defer remote.deinit(io);
    try testing.expect(remote.repo.isBare());
}
