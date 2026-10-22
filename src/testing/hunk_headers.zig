//! The function lines on a patch's `@@` lines against git 2.55's `git
//! diff`: a driver's `xfuncname` and `funcname` from the configuration, a
//! negated line, a group or the whole match, git's built-in drivers (one
//! blind to case), the old side's driver before the new one's across a
//! rename, a symbolic link under `default`'s, the converted text a
//! `textconv` makes, and `diff.default.xfuncname` over the files without
//! a driver; then range-diff's patches, which carry the same.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const suite = @import("helpers.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const driver = @import("../diff/driver.zig");
const textconv = @import("../diff/textconv.zig");
const range_diff = @import("../patch/range_diff.zig");
const attributes = @import("../patterns.zig").attributes;
const hash = @import("../hash/hash.zig");

const filler = "        b = 2\n        c = 3\n        d = 4\n        e = 5\n        f = 6\n        g = 7\n";

/// `text` with `e = 5` changed, far enough from the top for a function
/// line to be looked for above the hunk.
fn edited(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const at = std.mem.find(u8, text, "e = 5").?;
        return text[0..at] ++ "e = 50" ++ text[at + "e = 5".len ..];
    }
}

const python = "class Alpha:\n    def one(self):\n        a = 1\n" ++ filler ++ "        return a\n";
const sections = "SECTION first one\n  a = 1\nSECTION skip me\n" ++ filler;
const chapters = "chapter opening\n  a = 1\nprologue\n" ++ filler;
const ada = "package Stack is\n   PROCEDURE Push (X : Integer) IS\n" ++ filler;
const c_code = "int main(void)\n{\n" ++ filler ++ "}\n";
const lower = "section lowered\n  a = 1\n" ++ filler;

fn setup(io: Io, repo: *testgit.Repo) anyerror!void {
    const command = try testgit.fixtureCommand(repo.gpa, suite.path(.process_fixture), "upper-file");
    defer repo.gpa.free(command);
    try repo.exec(io, &.{ "config", "diff.sections.xfuncname", "!^SECTION skip\n^SECTION (.*)" });
    try repo.exec(io, &.{ "config", "diff.chapters.funcname", "^chapter \\([a-z]*\\)" });
    try repo.exec(io, &.{ "config", "diff.upfn.textconv", command });
    try repo.exec(io, &.{ "config", "diff.upfn.xfuncname", "^SECTION (.*)" });
    try repo.writeFile(io, ".gitattributes", "*.py diff=python\n*.cfg diff=sections\n*.txt diff=chapters\n*.adb diff=ada\n*.up diff=upfn\n");
    try repo.writeFile(io, "code.py", python);
    try repo.writeFile(io, "conf.cfg", sections);
    try repo.writeFile(io, "book.txt", chapters);
    try repo.writeFile(io, "stack.adb", ada);
    try repo.writeFile(io, "main.c", c_code);
    try repo.writeFile(io, "conv.up", lower);
    try repo.writeFile(io, "moved.py", python);
    const link = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, python);
    defer repo.gpa.free(link);
    const info = try std.mem.concat(repo.gpa, u8, &.{ "120000,", std.mem.trimEnd(u8, link, "\n"), ",link.py" });
    defer repo.gpa.free(info);
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    try repo.writeFile(io, "code.py", comptime edited(python));
    try repo.writeFile(io, "conf.cfg", comptime edited(sections));
    try repo.writeFile(io, "book.txt", comptime edited(chapters));
    try repo.writeFile(io, "stack.adb", comptime edited(ada));
    try repo.writeFile(io, "main.c", comptime edited(c_code));
    try repo.writeFile(io, "conv.up", comptime edited(lower));
    // Renamed to a name another driver takes: the old side's decides.
    try repo.exec(io, &.{ "mv", "moved.py", "moved.cfg" });
    try repo.writeFile(io, "moved.cfg", comptime edited(python));
    try repo.writeFile(io, "fresh.py", "def fresh():\n    pass\n");
    const new_link = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, comptime edited(python));
    defer repo.gpa.free(new_link);
    const new_info = try std.mem.concat(repo.gpa, u8, &.{ "120000,", std.mem.trimEnd(u8, new_link, "\n"), ",link.py" });
    defer repo.gpa.free(new_info);
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", new_info });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
}

fn ours(gpa: Allocator, io: Io, git: *testgit.Repo, env: *const std.process.Environ.Map) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = git.dir, .config = repo.configuration() };
    const tc: textconv.Textconv = .{ .programs = .{ .environ = env } };
    const db = repo.objectDatabase();
    const old = try repo.commitTree(io, try oidOf(gpa, io, git, "HEAD~1"));
    const new = try repo.commitTree(io, try oidOf(gpa, io, git, "HEAD"));
    var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{ .renames = .{} });
    defer changes.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try diff.unified(gpa, io, &out.writer, .{ .db = db, .changes = changes.items, .drivers = drivers, .textconv = &tc }, .{});
    return out.toOwnedSlice();
}

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

test "a patch's function lines are the ones each file's diff driver finds, as git diff writes them" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    git.environ = &env;
    try setup(io, &git);
    for ([_]?[]const u8{ null, "^(class|int) (.*)" }) |default| {
        if (default) |pattern| try git.exec(io, &.{ "config", "diff.default.xfuncname", pattern });
        const theirs = try git.run(io, &.{ "diff", "--no-color", "-M", "HEAD~1", "HEAD" });
        defer gpa.free(theirs);
        const mine = try ours(gpa, io, &git, &env);
        defer gpa.free(mine);
        std.testing.expectEqualStrings(theirs, mine) catch |err| {
            std.debug.print("diff.default.xfuncname={s}\n", .{default orelse "(unset)"});
            return err;
        };
    }
}

test "range-diff's patches carry the function lines and the converted text git log -p gives them" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    git.environ = &env;
    try setup(io, &git);
    try git.exec(io, &.{ "branch", "old" });
    try git.exec(io, &.{ "checkout", "-q", "-b", "new", "HEAD~1" });
    try git.exec(io, &.{ "checkout", "-q", "old", "--", "." });
    try git.writeFile(io, "code.py", "class Alpha:\n    def one(self):\n        a = 1\n" ++ filler[0 .. filler.len - "        g = 7\n".len] ++ "        g = 70\n        return a\n");
    try git.writeFile(io, "conv.up", "section lowered\n  a = 1\n" ++ filler[0 .. filler.len - "        g = 7\n".len] ++ "        g = 70\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "two" });
    const theirs = try git.run(io, &.{ "range-diff", "--no-color", "old~1", "old", "new" });
    defer gpa.free(theirs);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const tc: textconv.Textconv = .{ .programs = .{ .environ = &env } };
    const base = try oidOf(gpa, io, &git, "old~1");
    const old: range_diff.Range = .{ .base = base, .tip = try oidOf(gpa, io, &git, "old") };
    const new: range_diff.Range = .{ .base = base, .tip = try oidOf(gpa, io, &git, "new") };
    var mine: Io.Writer.Allocating = .init(gpa);
    defer mine.deinit();
    try range_diff.write(gpa, io, &mine.writer, .{ .repo = &repo, .old = old, .new = new }, .{ .textconv = &tc });
    try std.testing.expectEqualStrings(theirs, mine.written());
}
