//! The git release relic is held to, and the git the tests find. preflight's
//! held git (ci/workflow.json `git`) is that release on every hosted job,
//! first on the path, its program in `PREFLIGHT_GIT`; and every comparison
//! with git in the tests expects it (testing/git.zig):
//! the build asks the git the tests would find for its release once, before
//! they run (testing/held_git.zig), and a run against another git stops
//! there, naming both releases, instead of failing as the comparisons whose
//! behaviour moved. relic follows git's current release, so a new one moves
//! this, and the comparisons that change move with it.

const std = @import("std");
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
// The tools on a hosted runner. preflight puts its held git first on the
// path of every step after it and names its program in `PREFLIGHT_GIT`;
// relic's setup (`zig build ci-setup`) adds its git-lfs to the path after
// it. The suite's compatibility jobs (.github/workflows/git.yml) put the
// git they build there instead. The suite reads these while it runs: a
// variable the build set on the test run would be baked into Zig's cached
// configuration, carried to a later run whose tools, shard or seed differ.
//=====================================================================

/// Which git a hosted job compares against, from `RELIC_GIT`: the oldest
/// supported one or git's development branch, which a compatibility job
/// builds itself, or the held release.
pub const Hosted = enum { old, master, release };

/// Which git the hosted job `environ` is runs; `null` off a hosted runner.
pub fn hosted(gpa: Allocator, environ: Environ) ?Hosted {
    if (!hostedJob(gpa, environ)) return null;
    const value = environ.getAlloc(gpa, "RELIC_GIT") catch return .release;
    defer gpa.free(value);
    return hostedGit(value);
}

/// The git a hosted job runs, by `RELIC_GIT`'s value: the held release
/// unless it names another.
fn hostedGit(relic_git: []const u8) Hosted {
    return std.meta.stringToEnum(Hosted, relic_git) orelse .release;
}

/// Whether `environ` is a hosted job's (GitHub Actions sets
/// `GITHUB_ACTIONS=true`), where a missing git or git-lfs fails the run by
/// name rather than skipping what needs it: a comparison cannot pass there
/// by never running.
pub fn hostedJob(gpa: Allocator, environ: Environ) bool {
    const value = environ.getAlloc(gpa, "GITHUB_ACTIONS") catch return false;
    defer gpa.free(value);
    return std.mem.eql(u8, value, "true");
}

/// The git the tests start: preflight's held git by the path
/// `PREFLIGHT_GIT` names, since Zig looks a bare name up in the starting
/// process's own `PATH`; elsewhere `git`, which that `PATH` finds. In `a`.
pub fn program(a: Allocator, environ: Environ) []const u8 {
    return programNamed(environ.getAlloc(a, "PREFLIGHT_GIT") catch null);
}

/// `PREFLIGHT_GIT`'s path, or `git` where it is unset or empty.
fn programNamed(preflight_git: ?[]const u8) []const u8 {
    const named = preflight_git orelse return "git";
    return if (named.len == 0) "git" else named;
}

test "the held git is PREFLIGHT_GIT's path, else git, and a hosted job runs it unless RELIC_GIT names another" {
    try std.testing.expectEqualStrings("git", programNamed(null));
    try std.testing.expectEqualStrings("git", programNamed(""));
    try std.testing.expectEqualStrings("/tools/git/bin/git", programNamed("/tools/git/bin/git"));
    try std.testing.expectEqual(Hosted.release, hostedGit(""));
    try std.testing.expectEqual(Hosted.release, hostedGit("anything"));
    try std.testing.expectEqual(Hosted.old, hostedGit("old"));
    try std.testing.expectEqual(Hosted.master, hostedGit("master"));
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
