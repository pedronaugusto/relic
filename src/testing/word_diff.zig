//! Word diffs against git 2.55's `git diff --word-diff` and
//! `--color-words`: plain, porcelain and colour; words cut at spaces, by
//! `--word-diff-regex`, by a driver's `wordRegex` (configured or built in,
//! the old side's before the new one's) and by `diff.wordRegex`; lines only
//! removed, a last line without a newline, carriage returns, several hunks
//! and runs long enough for xdiff's common tail to be trimmed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const driver = @import("../diff/driver.zig");
const attributes = @import("../patterns.zig").attributes;
const hash = @import("../hash/hash.zig");
const repeat = @import("shakedown").corpus.repeat;

fn commitAll(io: Io, repo: *testgit.Repo, subject: []const u8) !void {
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", subject });
}

fn manyWords(comptime n: usize, comptime word: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        for (0..n) |i| out = out ++ word ++ std.fmt.comptimePrint("{d}", .{i}) ++ if (i % 8 == 7) "\n" else " ";
        return out;
    }
}

const long_tail = manyWords(400, "tail");

/// One line of the same word over and over: an inserted one slides to the
/// end in full, and only as far as the common tail xdiff trims away when
/// the words are diffed.
fn repeated(comptime n: usize) []const u8 {
    return "y" ++ repeat(" x", n) ++ "\n";
}

fn setup(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.exec(io, &.{ "config", "diff.letters.wordRegex", "[a-z]+" });
    try repo.writeFile(io, ".gitattributes", "*.py diff=python\n*.let diff=letters\n");
    try repo.writeFile(io, "prose.txt", "The quick brown fox\njumps over the lazy dog.\n\nA second paragraph here,\nwith words that stay.\nkeep one\nkeep two\nkeep three\nkeep four\nAnd a third one\n");
    try repo.writeFile(io, "code.py", "def f(x):\n    return x+1  # inc\n\nvalue = f(41)\n");
    try repo.writeFile(io, "only.let", "abc123def ghi\n");
    try repo.writeFile(io, "gone.txt", "these lines\nare removed\nentirely\n");
    try repo.writeFile(io, "noeol.txt", "last line without end");
    try repo.writeFile(io, "crlf.txt", "one two\r\nthree four\r\n");
    try repo.writeFile(io, "long.txt", "head words here\n" ++ long_tail);
    try repo.writeFile(io, "slide.txt", comptime repeated(600));
    try commitAll(io, repo, "one");
    try repo.writeFile(io, "prose.txt", "The quick red fox\njumps over the lazy cat!\n\nA second paragraph there,\nwith words that stay.\nkeep one\nkeep two\nkeep three\nkeep four\nAnd a 3rd one\nadded at the end\n");
    try repo.writeFile(io, "code.py", "def f(y):\n    return y+2  # inc\n\nvalue = f(41)\n");
    try repo.writeFile(io, "only.let", "abc456xyz ghi\n");
    try repo.writeFile(io, "gone.txt", "");
    try repo.writeFile(io, "noeol.txt", "last line still without end");
    try repo.writeFile(io, "crlf.txt", "one 2\r\nthree four\r\n");
    try repo.writeFile(io, "long.txt", "head WORDS here\n" ++ long_tail);
    try repo.writeFile(io, "slide.txt", comptime repeated(601));
    try commitAll(io, repo, "two");
}

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

const Variant = struct { args: []const []const u8, style: diff.WordDiff, regex: ?[]const u8 = null, color: bool = false };

fn expectSame(gpa: Allocator, io: Io, git: *testgit.Repo, v: Variant) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "diff", if (v.color) "--color=always" else "--no-color" });
    try argv.appendSlice(gpa, v.args);
    try argv.appendSlice(gpa, &.{ "HEAD~1", "HEAD" });
    const theirs = try git.run(io, argv.items);
    defer gpa.free(theirs);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = git.dir, .config = repo.configuration() };
    const colors = try diff.Colors.configured(repo.configuration(), .always);
    var options = try diff.configured(repo.configuration(), .{ .word_diff = v.style, .word_regex = v.regex });
    if (v.color) options.colors = &colors.?;
    const db = repo.objectDatabase();
    const old = try repo.commitTree(io, try oidOf(gpa, io, git, "HEAD~1"));
    const new = try repo.commitTree(io, try oidOf(gpa, io, git, "HEAD"));
    var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{});
    defer changes.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diff.unified(gpa, io, &out.writer, .{ .db = db, .changes = changes.items, .drivers = drivers }, options);
    std.testing.expectEqualStrings(theirs, out.written()) catch |err| {
        for (argv.items) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print(": differs\n", .{});
        return err;
    };
}

test "a word diff is git diff's, in each style, with words cut as each driver and setting says" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(io, &git);
    const variants = [_]Variant{
        .{ .args = &.{"--word-diff"}, .style = .plain },
        .{ .args = &.{"--word-diff=porcelain"}, .style = .porcelain },
        // `--word-diff=color` turns colour on; `--no-color` after it off.
        .{ .args = &.{ "--word-diff=color", "--no-color" }, .style = .color },
        .{ .args = &.{"--word-diff=color"}, .style = .color, .color = true },
        .{ .args = &.{"--color-words"}, .style = .color, .color = true },
        .{ .args = &.{"--word-diff=plain"}, .style = .plain, .color = true },
        .{ .args = &.{"--word-diff=porcelain"}, .style = .porcelain, .color = true },
        .{ .args = &.{ "--word-diff", "--word-diff-regex=[^[:space:]]" }, .style = .plain, .regex = "[^[:space:]]" },
        .{ .args = &.{"--color-words=[0-9]+|[a-z]+"}, .style = .color, .regex = "[0-9]+|[a-z]+", .color = true },
        .{ .args = &.{ "--word-diff=porcelain", "--word-diff-regex=." }, .style = .porcelain, .regex = "." },
    };
    for (variants) |v| try expectSame(gpa, io, &git, v);
    // `diff.wordRegex` under the drivers' own.
    try git.exec(io, &.{ "config", "diff.wordRegex", "[a-z]" });
    try expectSame(gpa, io, &git, .{ .args = &.{"--word-diff"}, .style = .plain });
    try expectSame(gpa, io, &git, .{ .args = &.{"--word-diff=porcelain"}, .style = .porcelain });
}
