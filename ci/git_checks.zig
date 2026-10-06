//! The Linux image and the hosted installer build one pinned Git release.
const std = @import("std");
pub const git_version = "2.55.0";
pub const git_sha256 = "457fdb04dc8728e007d4688695e6912e6f680727920f2a40bf11eacc17505357";
pub const lfs_version = "3.8.0";
pub const make_flags = [_][]const u8{ "NO_TCLTK=1", "NO_GETTEXT=1", "NO_RUST=1" };

pub fn recent(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "git version ")) return false;
    var parts = std.mem.splitScalar(u8, text[12..], '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return major > 2 or (major == 2 and minor >= 47);
}

fn check(a: std.mem.Allocator, text: []const u8) !void {
    for ([_][]const u8{
        try std.fmt.allocPrint(a, "ARG GIT_VERSION={s}\n", .{git_version}),
        try std.fmt.allocPrint(a, "ARG GIT_SHA256={s}\n", .{git_sha256}),
    }) |expected| if (std.mem.indexOf(u8, text, expected) == null) return error.ImageGitPinDiffers;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var builds: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "make -C ") == null or std.mem.indexOf(u8, line, "prefix=/opt/git") == null) continue;
        for (make_flags) |flag| if (std.mem.indexOf(u8, line, flag) == null) return error.ImageGitFlagDiffers;
        builds += 1;
    }
    if (builds != 2) return error.ImageGitBuildMissing;
}

fn report(comptime format: []const u8, io: std.Io, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, "ci/linux.Dockerfile", a, .limited(1024 * 1024));
    try check(a, text);
    try report("Git {s}: image and Zig installer share release, digest and make flags\n", init.io, .{git_version});
}

test "Git fixtures require 2.47 including Windows version suffixes" {
    try std.testing.expect(!recent("git version 2.46.3"));
    try std.testing.expect(recent("git version 2.47.0.windows.1"));
    try std.testing.expect(recent("git version 3.0.0"));
    try std.testing.expect(!recent("unexpected version"));
}

test "an image missing a release pin or make flag fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.ImageGitPinDiffers, check(a, "ARG GIT_VERSION=2.39.0\n"));
    const pins = try std.fmt.allocPrint(a, "ARG GIT_VERSION={s}\nARG GIT_SHA256={s}\nmake -C /tmp/git NO_TCLTK=1 NO_GETTEXT=1 prefix=/opt/git all\n", .{ git_version, git_sha256 });
    try std.testing.expectError(error.ImageGitFlagDiffers, check(a, pins));
}
