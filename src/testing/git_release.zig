//! The git release relic is held to, and the git the tests find. Setup
//! builds and installs the release on every hosted runner (ci/setup.zig),
//! and every comparison with git in the tests expects it (testing/git.zig):
//! the build asks the git the tests would find for its release once, before
//! they run (testing/held_git.zig), and a run against another git stops
//! there, naming both releases, instead of failing as the comparisons whose
//! behaviour moved. relic follows git's current release, so a new one moves
//! this, and the comparisons that change move with it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// A release as `git --version` names it.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn eql(a: Version, b: Version) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
    }

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    }
};

/// The release.
pub const held: Version = .{ .major = 2, .minor = 56, .patch = 0 };

/// The published SHA-256 of `git-<held>.tar.xz`, which setup checks before
/// it builds the release.
pub const sha256 = "26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3";

/// The release `git --version` prints, as every build prints it: `git
/// version 2.56.0`, and with a build's own suffix, `2.39.5 (Apple Git-154)`
/// or `2.56.0.windows.1`; `null` for a line that names none.
pub fn parse(line: []const u8) ?Version {
    const prefix = "git version ";
    const at = std.mem.find(u8, line, prefix) orelse return null;
    const rest = line[at + prefix.len ..];
    const end = std.mem.findNone(u8, rest, "0123456789.") orelse rest.len;
    var numbers = std.mem.splitScalar(u8, rest[0..end], '.');
    var parts: [3]u32 = undefined;
    for (&parts) |*part| part.* = std.fmt.parseUnsigned(u32, numbers.next() orelse return null, 10) catch return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

//=====================================================================
// The tools on a hosted runner. preflight's setup (`zig build ci-setup`)
// installs the git and git-lfs the suite compares against under
// `$RUNNER_TEMP/preflight-tools`; on Windows the native git is Git for
// Windows' own `mingw64`, whose `bin` launcher would start another process.
// The suite finds them here, while it runs: a variable the build set on the
// test run would be baked into Zig's cached configuration, carried to a
// later run whose tools, shard or seed differ.
//=====================================================================

/// Which git a hosted job compares against, from `RELIC_GIT`: the oldest
/// supported one the job installed itself, git's development branch, or
/// the release setup builds.
pub const Hosted = enum { old, master, release };

/// Which git the hosted job `environ` is runs; `null` off a hosted runner.
pub fn hosted(gpa: Allocator, environ: Environ) ?Hosted {
    if (!(environ.contains(gpa, "RUNNER_TEMP") catch false)) return null;
    const value = environ.getAlloc(gpa, "RELIC_GIT") catch return .release;
    defer gpa.free(value);
    return std.meta.stringToEnum(Hosted, value) orelse .release;
}

/// The directories, most preferred first, that hold the tools a hosted job
/// installed for `git`; none off a hosted runner, or for the oldest git,
/// which is the machine's own.
pub fn hostedDirs(a: Allocator, environ: Environ, git: ?Hosted) ![]const []const u8 {
    const which = git orelse return &.{};
    if (which == .old) return &.{};
    const temp = try environ.getAlloc(a, "RUNNER_TEMP");
    const lfs = try std.Io.Dir.path.join(a, &.{ temp, "preflight-tools", "lfs", "bin" });
    if (builtin.target.os.tag == .windows) {
        const programs = environ.getAlloc(a, "ProgramFiles") catch "C:\\Program Files";
        const dirs = try a.alloc([]const u8, 3);
        dirs[0] = try std.Io.Dir.path.join(a, &.{ programs, "Git", "mingw64", "bin" });
        dirs[1] = lfs;
        dirs[2] = try std.Io.Dir.path.join(a, &.{ programs, "Git", "usr", "bin" });
        return dirs;
    }
    const dirs = try a.alloc([]const u8, 2);
    dirs[0] = try std.Io.Dir.path.join(a, &.{ temp, "preflight-tools", if (which == .master) "master" else "git", "bin" });
    dirs[1] = lfs;
    return dirs;
}

/// The git the tests start: on a hosted runner the installed one, by its
/// path, since Zig looks a bare name up in the starting process's own
/// `PATH`; elsewhere, or where none is installed, `git`. In `a`.
pub fn program(a: Allocator, io: std.Io, environ: Environ) []const u8 {
    const dirs = hostedDirs(a, environ, hosted(a, environ)) catch return "git";
    const name = if (builtin.target.os.tag == .windows) "git.exe" else "git";
    for (dirs) |dir| {
        const candidate = std.Io.Dir.path.join(a, &.{ dir, name }) catch return "git";
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return "git";
}

test "a release is read from what every build of git prints" {
    const cases = [_]struct { []const u8, ?Version }{
        .{ "git version 2.56.0\n", .{ .major = 2, .minor = 56, .patch = 0 } },
        .{ "git version 2.39.5 (Apple Git-154)\n", .{ .major = 2, .minor = 39, .patch = 5 } },
        .{ "git version 2.56.0.windows.1\r\n", .{ .major = 2, .minor = 56, .patch = 0 } },
        .{ "git version 2.57.0.rc0.12.gabcdef\n", .{ .major = 2, .minor = 57, .patch = 0 } },
        .{ "git version 2.56\n", null },
        .{ "not git\n", null },
    };
    for (cases) |case| {
        const found = parse(case[0]);
        try std.testing.expectEqual(case[1] == null, found == null);
        if (case[1]) |expected| try std.testing.expect(expected.eql(found.?));
    }
}
