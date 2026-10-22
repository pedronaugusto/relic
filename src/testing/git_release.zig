//! The git release relic is held to. Setup builds and installs it on every
//! hosted runner (ci/setup.zig), and every comparison with git in the tests
//! expects it (testing/git.zig): a run against another git stops at its
//! first git, naming both releases, instead of failing as the comparisons
//! whose behaviour moved. relic follows git's current release, so a new one
//! moves this, and the comparisons that change move with it.

const std = @import("std");

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
