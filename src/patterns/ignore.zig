//! `.gitignore`, in git's precedence order, on sweep's ignore stacks
//! (`sweep.ignore`, git's `dir.c`): the levels, their ranking and the
//! matching are sweep's; what a repository adds is where its files are.
//!
//! Levels rank lowest first: `core.excludesFile` and then
//! `$GIT_COMMON_DIR/info/exclude` (group `file`), one level per directory's
//! `.gitignore` from the working tree's root down (group `directory`, a
//! deeper one winning), and a command line's patterns (`clean -e`, group
//! `command_line`). Within a level the last matching line wins.

const std = @import("std");
const sweep = @import("sweep");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A working tree's ignore rules: `sweep.ignore.Stack`.
pub const Stack = sweep.ignore.Stack;
/// Paths asked one at a time outside a walk: `sweep.ignore.Checker`.
pub const Checker = sweep.ignore.Checker;
/// Whether a path is excluded, and the line that decided.
pub const Match = sweep.ignore.Match;
/// Where a stack stands, for a walk to pop back to on its way out.
pub const Mark = sweep.ignore.Mark;
/// Reading or adding a level failed.
pub const FileError = sweep.ignore.FileError;
/// Everything this namespace's calls fail with.
pub const Error = FileError;
/// What a path is, for a pattern ending in `/`.
pub const Kind = sweep.Kind;

/// How a working tree's rules compare names.
pub const Options = struct {
    /// `core.ignoreCase`: ASCII letters match either case.
    case_fold: bool = false,
};

/// Empty rules for a working tree, which exclude nothing. A file that is
/// there but cannot be read counts as absent, as git warns and goes on;
/// `Stack.skipped` lists it.
pub fn init(gpa: Allocator, options: Options) Stack {
    return .init(gpa, .{ .case = if (options.case_fold) .ascii_git else .sensitive, .unreadable = .skip });
}

/// The two levels before any `.gitignore`: the file `core.excludesFile`
/// names (`excludes_file` in `excludes_dir`), then `info/exclude` in the
/// common directory. Either being absent adds nothing; most repositories
/// have neither. Both are read through a link, as git reads them.
pub fn loadGlobal(stack: *Stack, io: Io, common_dir: Io.Dir, excludes_file: ?[]const u8, excludes_dir: ?Io.Dir) FileError!void {
    if (excludes_file) |path| if (excludes_dir) |dir| {
        try stack.addFile(io, dir, path, .{ .group = .file, .source = path }, .follow);
    };
    try stack.addFile(io, common_dir, "info/exclude", .{ .group = .file, .source = "info/exclude" }, .follow);
}

/// `<base>/.gitignore` in the working tree `wt`, when it is there, as a
/// level relative to `base`. Neither the directory nor the file is reached
/// through a link, as git's `PATTERN_NOFOLLOW` reads it: a `base` that is
/// not a directory of the tree adds nothing. A walk holding the directory's
/// handle gives it to `Stack.addDirectory` instead.
pub fn addDirectory(stack: *Stack, io: Io, wt: Io.Dir, base: []const u8) FileError!void {
    if (base.len == 0) return stack.addDirectory(io, wt, "");
    var dir = wt.openDir(io, base, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        // Absent, not a directory, a link, or closed to us: no level, as a
        // walk would not enter it.
        else => return,
    };
    defer dir.close(io);
    try stack.addDirectory(io, dir, base);
}

test "the global levels rank below every directory's, info/exclude above core.excludesFile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "common/info");
    try tmp.dir.writeFile(io, .{ .sub_path = "excludes", .data = "*.log\n*.tmp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "common/info/exclude", .data = "!keep.log\n" });
    try tmp.dir.createDirPath(io, "wt/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/sub/.gitignore", .data = "!x.tmp\n" });
    var common = try tmp.dir.openDir(io, "common", .{});
    defer common.close(io);
    var wt = try tmp.dir.openDir(io, "wt", .{});
    defer wt.close(io);

    var rules = init(gpa, .{});
    defer rules.deinit();
    try loadGlobal(&rules, io, common, "excludes", tmp.dir);
    try std.testing.expect(rules.matchPath("a.log", .file).excluded);
    try std.testing.expect(!rules.matchPath("keep.log", .file).excluded);
    try std.testing.expectEqualStrings("info/exclude", rules.matchPath("keep.log", .file).by.?.source);
    const before = rules.mark();
    try addDirectory(&rules, io, wt, "sub");
    try std.testing.expect(!rules.matchPath("sub/x.tmp", .file).excluded);
    try std.testing.expectEqualStrings("sub/.gitignore", rules.matchPath("sub/x.tmp", .file).by.?.source);
    rules.popTo(before);
    try std.testing.expect(rules.matchPath("sub/x.tmp", .file).excluded);
    // A base the tree does not hold, or that is a file, adds nothing.
    try addDirectory(&rules, io, wt, "absent");
    try addDirectory(&rules, io, wt, "sub/.gitignore");
    try std.testing.expectEqual(before, rules.mark());
}

test "core.ignoreCase folds ASCII letters, and an unreadable file counts as absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A directory where the file goes: there, and not readable as a file.
    try tmp.dir.createDirPath(io, "sub/.gitignore");
    var folding = init(gpa, .{ .case_fold = true });
    defer folding.deinit();
    try folding.addText("*.LOG\n", .{ .group = .directory, .source = ".gitignore" });
    try std.testing.expect(folding.match("a.log", .file).excluded);
    try addDirectory(&folding, io, tmp.dir, "sub");
    try std.testing.expectEqual(1, folding.skipped().len);
    var exact = init(gpa, .{});
    defer exact.deinit();
    try exact.addText("*.LOG\n", .{ .group = .directory, .source = ".gitignore" });
    try std.testing.expect(!exact.match("a.log", .file).excluded);
}

test "an in-tree .gitignore that is a link is not read, as git does not follow one" {
    const testgit = @import("../testing/git.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "elsewhere", "*.log\n");
    repo.dir.symLink(io, "elsewhere", ".gitignore", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => |e| return e,
    };
    try repo.writeFile(io, "a.log", "x\n");
    repo.report_failures = false;
    // git: not ignored, since its .gitignore is a link it does not read.
    const listed = try repo.run(io, &.{ "ls-files", "--others", "--exclude-standard", "--", "a.log" });
    defer gpa.free(listed);
    try std.testing.expectEqualStrings("a.log\n", listed);
    var rules = init(gpa, .{});
    defer rules.deinit();
    try addDirectory(&rules, io, repo.dir, "");
    try std.testing.expect(!rules.match("a.log", .file).excluded);
}
