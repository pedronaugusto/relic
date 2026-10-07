//! Path search: a bare program name -- `sh`, `ssh`, `git`, a helper --
//! found outside `PATH`, in the working tree a program runs in or the
//! directory relic was started from, where a repository can put one. The
//! owner is `repo/program.zig` (the architecture's `process/`), the one
//! place a program is started: on Windows it looks a bare name up in
//! `PATH` alone, as git for Windows does, before conduit could search
//! Windows' own places first.

const std = @import("std");
const suite = @import("../helpers.zig");
const builtin = @import("builtin");
const Io = std.Io;

const program = @import("../../repo/program.zig");
const testgit = @import("../git.zig");

const exe = if (builtin.target.os.tag == .windows) ".exe" else "";

/// Put a copy of the process fixture at `name` in `dir`, executable.
fn plant(io: Io, dir: Io.Dir, name: []const u8) !void {
    try Io.Dir.cwd().copyFile(suite.path(.process_fixture), dir, name, io, .{});
    if (builtin.target.os.tag != .windows) {
        const file = try dir.openFile(io, name, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
}

/// Run the bare `name` in `cwd`, asked to make the file `ran` there.
fn runBare(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8, cwd: Io.Dir) !void {
    var outcome = program.run(.{ .environ = env }, gpa, io, .{ .argv = &.{ name, "touch", "ran" }, .cwd = .{ .dir = cwd } }, "", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer outcome.deinit(gpa);
    std.debug.print("{s} ran from outside PATH\n", .{name});
    return error.TestUnexpectedResult;
}

test "CVE-2018-19486, t0061-run-command 'run_command is restricted to PATH': a program in the working tree a command runs in is not run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try plant(io, repo.dir, "should-not-run" ++ exe);
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    try runBare(gpa, io, &env, "should-not-run", repo.dir);
    try std.testing.expectError(error.FileNotFound, repo.dir.access(io, "ran", .{}));
}

test "CVE-2018-19486, t0061-run-command 'run_command is restricted to PATH': a program beside relic's own executable is not run either" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Windows looks in the directory of the running executable before
    // `PATH`; git for Windows does not, and neither does relic.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own = buf[0..try std.process.executableDirPath(io, &buf)];
    var own_dir = try Io.Dir.cwd().openDir(io, own, .{});
    defer own_dir.close(io);
    const name = "relic-cve-2018-19486-path-search";
    try plant(io, own_dir, name ++ exe);
    defer own_dir.deleteFile(io, name ++ exe) catch |err| std.debug.print("the planted program stays: {s}\n", .{@errorName(err)});
    var work = std.testing.tmpDir(.{});
    defer work.cleanup();
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    try runBare(gpa, io, &env, name, work.dir);
    try std.testing.expectError(error.FileNotFound, work.dir.access(io, "ran", .{}));
}

test "CVE-2018-19486, git for Windows' path_lookup: a bare name is found in PATH, in order, and nowhere else" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    try plant(io, second.dir, "tool" ++ exe);
    try first.dir.createDir(io, "tool" ++ exe, .default_dir);
    const first_path = try first.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(first_path);
    const second_path = try second.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(second_path);
    const sep = std.Io.Dir.path.delimiter;
    const path = try gpa.print("{c}{s}{c}{s}", .{ sep, first_path, sep, second_path });
    defer gpa.free(path);
    // An empty entry, then a directory named like the program, then it.
    const found = (try program.lookupOnPath(gpa, io, path, "tool")).?;
    defer gpa.free(found);
    const expected = try gpa.print("{s}{c}tool{s}", .{ second_path, std.Io.Dir.path.sep, exe });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, found);
    try std.testing.expectEqual(null, try program.lookupOnPath(gpa, io, path, "absent"));
    try std.testing.expectEqual(null, try program.lookupOnPath(gpa, io, null, "tool"));
}
