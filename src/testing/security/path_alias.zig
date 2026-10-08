//! Path aliases: a stored name that some filesystem opens as `.git`,
//! `.gitmodules`, a device or a path outside the working tree. git's fixes
//! for them, each mirrored from its own test. The rule's owner is
//! `worktree/safepath.zig` (the architecture's `names/path`); checkout,
//! the index and fsck all ask it.

const std = @import("std");
const builtin = @import("builtin");

const hostile = @import("hostile.zig");
const safepath = @import("../../names/path.zig");
const fsck = @import("../../object/fsck.zig");
const hash = @import("../../hash/hash.zig");

const windows = builtin.target.os.tag == .windows;

/// The rows of git's t1014-read-tree-confusing.sh, which git refuses with
/// both `core.protectHFS` and `core.protectNTFS` on.
const t1014_rows = [_][]const u8{
    ".",
    "..",
    ".git",
    ".GIT",
    "\u{200c}.Git",
    ".gI\u{200c}T",
    ".GiT\u{200c}",
    "git~1",
    ".git. ",
    ".\\.GIT\\foobar",
    ".git\\foobar",
    ".git...:alternate-stream",
};

/// The tree problem fsck names for `name` as a tree entry, or `null`.
fn fsckProblem(gpa: std.mem.Allocator, mode: []const u8, name: []const u8) !?fsck.Problem {
    const bytes = try hostile.treeBytes(gpa, &.{.{ .mode = mode, .name = name, .oid = try hash.Oid.fromRaw(.sha1, &(@as([20]u8, @splat(1)))) }});
    defer gpa.free(bytes);
    const finding = try fsck.checkObject(gpa, &fsck.baseline, .sha1, .zero(.sha1), .tree, bytes, null, null) orelse return null;
    return finding.problem;
}

test "CVE-2014-9390, t1014-read-tree-confusing: a path that is .git in another spelling is refused at its end and as a subtree, and fsck names it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const blob = try h.blob(io, "content\n");
    const base = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = "file", .oid = blob }});
    for (t1014_rows) |path| {
        const at_end = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = path, .oid = blob }});
        const as_subtree = try h.writeTree(gpa, io, &.{.{ .mode = "40000", .name = path, .oid = base }});
        for ([_]hash.Oid{ at_end, as_subtree }) |tree| {
            if (try h.checkout(gpa, io, tree) == null) {
                std.debug.print("checked out a tree naming {s}\n", .{path});
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expect(try fsckProblem(gpa, "40000", path) != null);
    }
    try h.repo.dir.access(io, ".git/config", .{});
    try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, ".git/file", .{}));
    try std.testing.expectError(error.FileNotFound, h.git_dir.access(io, "foobar", .{}));
}

test "CVE-2018-11233, t0060-path-utils 'match .gitmodules': the NTFS and HFS+ matchers agree with git's vectors and read nothing past a name" {
    const yes = [_][]const u8{
        ".gitmodules",       ".git\u{200c}modules", ".Gitmodules",    ".gitmoduleS",
        ".gitmodules ",      ".gitmodules.",        ".gitmodules  ",  ".gitmodules. ",
        ".gitmodules .",     ".gitmodules..",       ".gitmodules   ", ".gitmodules.  ",
        ".gitmodules . ",    ".gitmodules  .",      ".Gitmodules ",   ".Gitmodules.",
        ".Gitmodules  ",     ".Gitmodules. ",       ".Gitmodules .",  ".Gitmodules..",
        ".Gitmodules   ",    ".Gitmodules.  ",      ".Gitmodules . ", ".Gitmodules  .",
        "GITMOD~1",          "gitmod~1",            "GITMOD~2",       "gitmod~3",
        "GITMOD~4",          "GITMOD~1 ",           "gitmod~2.",      "GITMOD~3  ",
        "gitmod~4. ",        "GITMOD~1 .",          "gitmod~2   ",    "GITMOD~3.  ",
        "gitmod~4 . ",       "GI7EBA~1",            "gi7eba~9",       "GI7EB~10",
        "GI7EB~11",          "GI7EB~99",            "GI7EB~10",       "GI7E~100",
        "GI7E~101",          "GI7E~999",            "~1000000",       "~9999999",
        ".gitmodules:$DATA", "gitmod~4 . :$DATA",
    };
    const no = [_][]const u8{
        ".gitmodules x",  ".gitmodules .x", " .gitmodules", "..gitmodules", "gitmodules",         ".gitmodule",
        ".gitmodules x ", "GI7EBA~",        "GI7EBA~0",     "GI7EBA~~1",    "GI7EBA~X",           "Gx7EBA~1",
        "GI7EBX~1",       "GI7EB~1",        "GI7EB~01",     "GI7EB~1X",     ".gitmodules,:$DATA",
    };
    const matches = struct {
        fn f(name: []const u8) bool {
            return safepath.isHfsDot(name, "gitmodules") or safepath.isNtfsDotGitmodules(name);
        }
    }.f;
    for (yes) |name| try std.testing.expect(matches(name));
    for (no) |name| try std.testing.expect(!matches(name));
    // The same table for the other dotfiles git protects.
    const others = [_]struct { needle: []const u8, prefix: []const u8, names: []const []const u8 }{
        .{ .needle = "gitattributes", .prefix = "gi7d29", .names = &.{ ".gitattributes", ".git\u{200c}attributes", ".Gitattributes", ".gitattributeS", "GITATT~1", "GI7D29~1" } },
        .{ .needle = "gitignore", .prefix = "gi250a", .names = &.{ ".gitignore", ".git\u{200c}ignore", ".Gitignore", ".gitignorE", "GITIGN~1", "GI250A~1" } },
        .{ .needle = "mailmap", .prefix = "maba30", .names = &.{ ".mailmap", ".mail\u{200c}map", ".Mailmap", ".mailmaP", "MAILMA~1", "MABA30~1" } },
    };
    for (others) |other| for (other.names) |name| {
        try std.testing.expect(safepath.isHfsDot(name, other.needle) or safepath.isNtfsDot(name, other.needle, other.prefix));
    };
    // The out-of-bounds read was on names cut short: every prefix of every
    // vector is asked, and a safe build traps any read past its end.
    for (yes ++ no) |name| {
        for (0..name.len + 1) |len| {
            _ = matches(name[0..len]);
            _ = safepath.isNtfsDotGit(name[0..len]);
            _ = safepath.checkEntry(name[0..len], .worktree, true);
        }
    }
}

test "CVE-2019-1351, t0060-path-utils (MINGW): a drive named by any character subst allows is absolute where Windows opens it" {
    try std.testing.expectEqual(@as(usize, 2), safepath.dosDrivePrefixLen("C:\\git"));
    try std.testing.expectEqual(@as(usize, 2), safepath.dosDrivePrefixLen("1:/escape"));
    try std.testing.expectEqual(@as(usize, 3), safepath.dosDrivePrefixLen("\u{e4}:x"));
    try std.testing.expectEqual(@as(usize, 3), safepath.dosDrivePrefixLen("\u{58d}:x"));
    try std.testing.expectEqual(@as(usize, 0), safepath.dosDrivePrefixLen("ab:c"));
    try std.testing.expectEqual(@as(usize, 0), safepath.dosDrivePrefixLen("1"));
    for ([_][]const u8{ "1:/escape", "\u{e4}:x", "C:x" }) |path| {
        for ([_]safepath.Use{ .stored, .worktree }) |use| {
            if (windows) {
                try std.testing.expectEqual(safepath.Reason.absolute, safepath.check(path, use).?.reason);
            } else if (use == .stored) try std.testing.expectEqual(null, safepath.check(path, use));
        }
    }
}

test "CVE-2019-1352, t1014-read-tree-confusing (protectNTFS): .git with an alternate data stream is .git on every platform" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const blob = try h.blob(io, "[core]\n\thooksPath = /tmp\n");
    const config = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = "config", .oid = blob }});
    for ([_][]const u8{ ".git::$INDEX_ALLOCATION", ".git:$DATA", "git~1::$INDEX_ALLOCATION", ".GIT...:x" }) |name| {
        const tree = try h.writeTree(gpa, io, &.{.{ .mode = "40000", .name = name, .oid = config }});
        try std.testing.expectEqual(safepath.Reason.git_directory, (try h.checkout(gpa, io, tree)).?);
        try std.testing.expectEqual(fsck.Problem.has_dotgit, (try fsckProblem(gpa, "40000", name)).?);
    }
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.mem.find(u8, try h.git_dir.readFile(io, "config", &buf), "hooksPath") == null);
}

test "CVE-2019-1353, t1014-read-tree-confusing and t0060-path-utils (MINGW): the NTFS .git rules hold on every platform and the Windows-only names only on Windows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const blob = try h.blob(io, "x\n");
    // What NTFS opens as `.git`, which a Linux system writing to an NTFS
    // volume opens as `.git` too: refused everywhere.
    for ([_][]const u8{ "git~1", ".git. ", ".git\\foobar", ".\\.GIT\\foobar", "a\\git~1", ".git...:alternate-stream" }) |name| {
        const tree = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = name, .oid = blob }});
        try std.testing.expect(try h.checkout(gpa, io, tree) != null);
    }
    // What only Windows cannot create: git writes it everywhere else.
    if (!windows) {
        const tree = try h.writeTree(gpa, io, &.{
            .{ .mode = "100644", .name = "AUX.c", .oid = blob },
            .{ .mode = "100644", .name = "com9.c", .oid = blob },
            .{ .mode = "100644", .name = "conout$", .oid = blob },
            .{ .mode = "100644", .name = "t.", .oid = blob },
        });
        try std.testing.expectEqual(null, try h.checkout(gpa, io, tree));
    }
    // git's `is_valid_win32_path` vectors, asked of the rule on every
    // platform so that it is proved where it is not applied too.
    for ([_][]const u8{ "win32", "win32 x", "../hello.txt", "C:\\git", "comm", "conout.c", "com0.c", "lptN" }) |path| {
        try std.testing.expectEqual(null, safepath.win32PathReason(path));
    }
    for ([_][]const u8{
        "win32 ",                 "win32 /x ", "win32.", "win32 . .", ".../hello.txt", "colon:test", "AUX.c",
        "abc/conOut$  .xyz/test", "lpt8",      "com9.c", "lpt*",      "Nul",           "PRN./abc",
    }) |path| {
        try std.testing.expect(safepath.win32PathReason(path) != null);
    }
}

test "CVE-2019-1354, verify_path under protectNTFS: a name holding a backslash is a path where Windows checks it out, and a file name elsewhere" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const blob = try h.blob(io, "x\n");
    const tree = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = "a\\b", .oid = blob }});
    if (windows) {
        try std.testing.expectEqual(safepath.Reason.separator_inside_component, (try h.checkout(gpa, io, tree)).?);
        try std.testing.expectError(error.FileNotFound, h.repo.dir.access(io, "a/b", .{}));
    } else {
        try std.testing.expectEqual(null, try h.checkout(gpa, io, tree));
        try h.repo.dir.access(io, "a\\b", .{});
    }
}
