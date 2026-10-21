//! `grep` against `git grep`: the same repository, the same options, the
//! same bytes and the same exit status.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const grep_mod = @import("grep.zig");
const hash = @import("hash/hash.zig");
const repo_mod = @import("repo/repo.zig");
const testgit = @import("testing/git.zig");
const suite = @import("testing/helpers.zig");
const textconv = @import("diff/textconv.zig");
const attributes = @import("patterns.zig").attributes;

const Repository = repo_mod.Repository;

fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *Repository, args: []const []const u8, options: grep_mod.Options) !void {
    // This follows today's git: `-o` with `--column` numbers each match
    // from the start of the line since 2.55, where an older git counted
    // from the end of the match before it.
    if (options.only_matching and options.column == true and !try testgit.gitAtLeast(gpa, io, 2, 55)) return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "grep");
    try argv.appendSlice(gpa, args);
    var c = try git.capture(io, argv.items);
    defer c.deinit(gpa);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const outcome = try grep_mod.grep(gpa, io, repo, options, &out.writer);
    if (!std.mem.eql(u8, c.stdout, out.written()) or (c.code == 0) != outcome.matched) {
        std.debug.print("git grep {any}: exit {d}\n{s}\n", .{ args, c.code, c.stderr });
    }
    try std.testing.expectEqualStrings(c.stdout, out.written());
    try std.testing.expectEqual(c.code == 0, outcome.matched);
}

const source_c =
    \\#include <stdio.h>
    \\
    \\int main(void) {
    \\    int count = 0;
    \\    printf("hello, world\n");
    \\    count += 1;
    \\    /* a comment about counting */
    \\    return count;
    \\}
    \\
    \\static int helper(int x) {
    \\    return x * 2; // doubled
    \\}
    \\
;

fn fixture(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "src/main.c", source_c);
    try git.writeFile(io, "src/util/strings.c", "char *dup(const char *s);\nint count_words(const char *s);\nfoobar foo barfoo\n");
    try git.writeFile(io, "README.md", "# Title\n\nHello World.\nThe count is hidden here: COUNT.\nno newline at the end");
    try git.writeFile(io, "docs/notes.txt", "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\nalpha again\n");
    try git.writeFile(io, "data.bin", "binary\x00data with count inside\n");
    try git.writeFile(io, "odd name.txt", "a line with count\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
    // the working tree and the index move on, differently
    try git.writeFile(io, "docs/notes.txt", "alpha\nbeta changed\ngamma\ncount in notes\n");
    try git.exec(io, &.{ "add", "docs/notes.txt" });
    try git.writeFile(io, "docs/notes.txt", "alpha\nworktree only count\n");
}

test "git grep's output for patterns, options and sources comes out byte for byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head_oid = blk: {
        const text = try git.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(text);
        break :blk try hash.Oid.parse(.sha1, text);
    };

    try compare(gpa, io, &git, &repo, &.{"count"}, .{ .patterns = &.{"count"} });
    try compare(gpa, io, &git, &repo, &.{ "-n", "count" }, .{ .patterns = &.{"count"}, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-i", "-n", "COUNT" }, .{ .patterns = &.{"COUNT"}, .ignore_case = true, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-w", "foo" }, .{ .patterns = &.{"foo"}, .word = true });
    try compare(gpa, io, &git, &repo, &.{ "-v", "-c", "a" }, .{ .patterns = &.{"a"}, .invert = true, .show = .count });
    try compare(gpa, io, &git, &repo, &.{ "-l", "count" }, .{ .patterns = &.{"count"}, .show = .files_with_matches });
    try compare(gpa, io, &git, &repo, &.{ "-L", "count" }, .{ .patterns = &.{"count"}, .show = .files_without_match });
    try compare(gpa, io, &git, &repo, &.{ "-c", "count" }, .{ .patterns = &.{"count"}, .show = .count });
    try compare(gpa, io, &git, &repo, &.{ "-o", "-n", "--column", "count" }, .{ .patterns = &.{"count"}, .only_matching = true, .line_number = true, .column = true });
    try compare(gpa, io, &git, &repo, &.{ "-h", "count" }, .{ .patterns = &.{"count"}, .with_filename = false });
    try compare(gpa, io, &git, &repo, &.{ "-z", "-n", "count" }, .{ .patterns = &.{"count"}, .null_separator = true, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-n", "-C1", "count" }, .{ .patterns = &.{"count"}, .line_number = true, .before = 1, .after = 1 });
    try compare(gpa, io, &git, &repo, &.{ "-A2", "int" }, .{ .patterns = &.{"int"}, .after = 2 });
    try compare(gpa, io, &git, &repo, &.{ "-B3", "-n", "return" }, .{ .patterns = &.{"return"}, .before = 3, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-m1", "count" }, .{ .patterns = &.{"count"}, .max_count = 1 });
    try compare(gpa, io, &git, &repo, &.{ "-a", "count" }, .{ .patterns = &.{"count"}, .binary = .text });
    try compare(gpa, io, &git, &repo, &.{ "-I", "count" }, .{ .patterns = &.{"count"}, .binary = .skip });
    try compare(gpa, io, &git, &repo, &.{ "-e", "alpha", "-e", "hello" }, .{ .patterns = &.{ "alpha", "hello" } });
    try compare(gpa, io, &git, &repo, &.{ "-e", "" }, .{ .patterns = &.{""} });
    try compare(gpa, io, &git, &repo, &.{"nothing-matches-this"}, .{ .patterns = &.{"nothing-matches-this"} });
    // basic, extended and fixed expressions
    try compare(gpa, io, &git, &repo, &.{ "-n", "^int" }, .{ .patterns = &.{"^int"}, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-o", "co*unt\\|re[a-z]*" }, .{ .patterns = &.{"co*unt\\|re[a-z]*"}, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{ "-E", "-o", "(count|return)[^;]+;" }, .{ .patterns = &.{"(count|return)[^;]+;"}, .syntax = .extended, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{ "-E", "x{1,2}|[[:upper:]]{3,}" }, .{ .patterns = &.{"x{1,2}|[[:upper:]]{3,}"}, .syntax = .extended });
    try compare(gpa, io, &git, &repo, &.{ "-F", "x * 2" }, .{ .patterns = &.{"x * 2"}, .syntax = .fixed });
    try compare(gpa, io, &git, &repo, &.{ "-w", "-o", "\\(foo\\|bar\\)" }, .{ .patterns = &.{"\\(foo\\|bar\\)"}, .word = true, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{"\\<count\\>"}, .{ .patterns = &.{"\\<count\\>"} });
    // pathspecs
    try compare(gpa, io, &git, &repo, &.{ "count", "--", "src" }, .{ .patterns = &.{"count"}, .pathspecs = &.{"src"} });
    try compare(gpa, io, &git, &repo, &.{ "count", "--", "*.c", ":!src/util" }, .{ .patterns = &.{"count"}, .pathspecs = &.{ "*.c", ":!src/util" } });
    // the index and a commit
    try compare(gpa, io, &git, &repo, &.{ "--cached", "-n", "count" }, .{ .patterns = &.{"count"}, .line_number = true, .source = .index });
    try compare(gpa, io, &git, &repo, &.{ "-n", "count", "HEAD" }, .{ .patterns = &.{"count"}, .line_number = true, .source = .{ .tree = .{ .oid = head_oid, .name = "HEAD" } } });
    try compare(gpa, io, &git, &repo, &.{ "-l", "count", "HEAD", "--", "docs" }, .{ .patterns = &.{"count"}, .show = .files_with_matches, .pathspecs = &.{"docs"}, .source = .{ .tree = .{ .oid = head_oid, .name = "HEAD" } } });
    // one task and many give the same output
    try compare(gpa, io, &git, &repo, &.{ "-n", "-C2", "a" }, .{ .patterns = &.{"a"}, .line_number = true, .before = 2, .after = 2, .threads = 1 });
    try compare(gpa, io, &git, &repo, &.{ "-n", "-C2", "a" }, .{ .patterns = &.{"a"}, .line_number = true, .before = 2, .after = 2, .threads = 4 });
}

test "back-references match where git grep's matcher matches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "words.txt", "foo foo bar\nabab\nxyzzy\nAbAB\nthe the end\nnone here\nabcabc abc\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "words" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try compare(gpa, io, &git, &repo, &.{ "-n", "-o", "\\(ab\\)\\1" }, .{ .patterns = &.{"\\(ab\\)\\1"}, .line_number = true, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{ "-w", "-o", "\\([a-z]*\\) \\1" }, .{ .patterns = &.{"\\([a-z]*\\) \\1"}, .word = true, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{ "-c", "\\(.\\)\\1" }, .{ .patterns = &.{"\\(.\\)\\1"}, .show = .count });
    try compare(gpa, io, &git, &repo, &.{ "-v", "\\(...\\)\\1" }, .{ .patterns = &.{"\\(...\\)\\1"}, .invert = true });
    // macOS's regcomp, which git uses there, takes no back-reference in an
    // extended expression and compares one with case; glibc's does both
    if (builtin.target.os.tag == .macos) return;
    try compare(gpa, io, &git, &repo, &.{ "-E", "-o", "(z)\\1" }, .{ .patterns = &.{"(z)\\1"}, .syntax = .extended, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{ "-i", "-n", "\\(ab\\)\\1" }, .{ .patterns = &.{"\\(ab\\)\\1"}, .ignore_case = true, .line_number = true });
}

test "--and, --or, --not, parentheses and --all-match select lines and files as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try compare(gpa, io, &git, &repo, &.{ "-n", "-e", "count", "--and", "-e", "int" }, .{ .expression = &.{ .{ .pattern = "count" }, .@"and", .{ .pattern = "int" } }, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-e", "int", "--and", "--not", "-e", "main" }, .{ .expression = &.{ .{ .pattern = "int" }, .@"and", .not, .{ .pattern = "main" } } });
    try compare(gpa, io, &git, &repo, &.{ "-e", "alpha", "--or", "-e", "zeta" }, .{ .expression = &.{ .{ .pattern = "alpha" }, .@"or", .{ .pattern = "zeta" } } });
    try compare(gpa, io, &git, &repo, &.{ "(", "-e", "alpha", "-e", "count", ")", "--and", "--not", "-e", "notes" }, .{ .expression = &.{ .open, .{ .pattern = "alpha" }, .{ .pattern = "count" }, .close, .@"and", .not, .{ .pattern = "notes" } } });
    try compare(gpa, io, &git, &repo, &.{ "-e", "a", "--and", "(", "-e", "b", "-e", "c", ")" }, .{ .expression = &.{ .{ .pattern = "a" }, .@"and", .open, .{ .pattern = "b" }, .{ .pattern = "c" }, .close } });
    try compare(gpa, io, &git, &repo, &.{ "--not", "--not", "-e", "count" }, .{ .expression = &.{ .not, .not, .{ .pattern = "count" } } });
    // columns: an earlier match under a `--not` counts for `-v`
    try compare(gpa, io, &git, &repo, &.{ "-n", "--column", "-e", "count", "--and", "--not", "-e", "int" }, .{ .expression = &.{ .{ .pattern = "count" }, .@"and", .not, .{ .pattern = "int" } }, .line_number = true, .column = true });
    try compare(gpa, io, &git, &repo, &.{ "-v", "-n", "--column", "--not", "-e", "count" }, .{ .expression = &.{ .not, .{ .pattern = "count" } }, .invert = true, .line_number = true, .column = true });
    try compare(gpa, io, &git, &repo, &.{ "-n", "--column", "-C1", "--not", "-e", "a" }, .{ .expression = &.{ .not, .{ .pattern = "a" } }, .line_number = true, .column = true, .before = 1, .after = 1 });
    // files where every term of the either-or hit
    try compare(gpa, io, &git, &repo, &.{ "--all-match", "-e", "count", "-e", "return" }, .{ .patterns = &.{ "count", "return" }, .all_match = true });
    try compare(gpa, io, &git, &repo, &.{ "--all-match", "-l", "-e", "count", "-e", "alpha" }, .{ .patterns = &.{ "count", "alpha" }, .all_match = true, .show = .files_with_matches });
    try compare(gpa, io, &git, &repo, &.{ "--all-match", "-e", "count", "--and", "-e", "int", "-e", "doubled" }, .{ .expression = &.{ .{ .pattern = "count" }, .@"and", .{ .pattern = "int" }, .{ .pattern = "doubled" } }, .all_match = true });
    try compare(gpa, io, &git, &repo, &.{ "--all-match", "-e", "count" }, .{ .patterns = &.{"count"}, .all_match = true });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.InvalidExpression, grep_mod.grep(gpa, io, &repo, .{ .expression = &.{ .@"and", .{ .pattern = "a" } } }, &out.writer));
    try std.testing.expectError(error.InvalidExpression, grep_mod.grep(gpa, io, &repo, .{ .expression = &.{ .open, .{ .pattern = "a" } } }, &out.writer));
    try std.testing.expectError(error.InvalidExpression, grep_mod.grep(gpa, io, &repo, .{ .expression = &.{ .{ .pattern = "a" }, .close } }, &out.writer));
    try std.testing.expectError(error.InvalidExpression, grep_mod.grep(gpa, io, &repo, .{ .expression = &.{ .{ .pattern = "a" }, .not } }, &out.writer));
}

const functions_c =
    \\#include <stdio.h>
    \\
    \\/* adds them up */
    \\static int sum(int a, int b)
    \\{
    \\    int total = a + b;
    \\    return total;
    \\}
    \\
    \\
    \\label:
    \\int main(void)
    \\{
    \\    int total = sum(1, 2);
    \\    printf("%d\n", total);
    \\
    \\    return 0;
    \\}
    \\
;

const functions_py =
    \\import os
    \\
    \\class Thing:
    \\    def count(self):
    \\        total = 0
    \\        return total
    \\
    \\    def name(self):
    \\        return "thing"
    \\
    \\def helper():
    \\    return Thing().count()
    \\
;

const functions_custom =
    \\SECTION one
    \\  value 1
    \\  other 2
    \\SECTION two
    \\  value 3
    \\  skip this SECTION
    \\  last 4
;

test "-p and -W show the function lines git's diff drivers find" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, ".gitattributes", "*.py diff=python\n*.cfg diff=sections\n*.txt diff=nosuchdriver\n");
    try git.exec(io, &.{ "config", "diff.sections.xfuncname", "!skip\n^SECTION .*" });
    try git.writeFile(io, "a.c", functions_c);
    try git.writeFile(io, "b.py", functions_py);
    try git.writeFile(io, "c.cfg", functions_custom);
    try git.writeFile(io, "d.txt", "head\n  value 9\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "functions" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);

    try compare(gpa, io, &git, &repo, &.{ "-p", "total" }, .{ .patterns = &.{"total"}, .show_function = true });
    try compare(gpa, io, &git, &repo, &.{ "-p", "-n", "return" }, .{ .patterns = &.{"return"}, .show_function = true, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-p", "-C1", "value" }, .{ .patterns = &.{"value"}, .show_function = true, .before = 1, .after = 1 });
    try compare(gpa, io, &git, &repo, &.{ "-W", "printf" }, .{ .patterns = &.{"printf"}, .function_context = true });
    try compare(gpa, io, &git, &repo, &.{ "-W", "-n", "a + b" }, .{ .patterns = &.{"a + b"}, .function_context = true, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-W", "static int sum" }, .{ .patterns = &.{"static int sum"}, .function_context = true });
    try compare(gpa, io, &git, &repo, &.{ "-W", "-n", "total = 0" }, .{ .patterns = &.{"total = 0"}, .function_context = true, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "-W", "value 3" }, .{ .patterns = &.{"value 3"}, .function_context = true });
    try compare(gpa, io, &git, &repo, &.{ "-W", "-p", "-A1", "thing" }, .{ .patterns = &.{"thing"}, .function_context = true, .show_function = true, .after = 1 });
    try compare(gpa, io, &git, &repo, &.{ "-W", "value" }, .{ .patterns = &.{"value"}, .function_context = true });
    try compare(gpa, io, &git, &repo, &.{ "-W", "-c", "total" }, .{ .patterns = &.{"total"}, .function_context = true, .show = .count });
    try compare(gpa, io, &git, &repo, &.{ "--threads=1", "-W", "-n", "total" }, .{ .patterns = &.{"total"}, .function_context = true, .line_number = true, .threads = 1 });
}

test "--textconv searches the text a driver's program writes, in the working tree, the index and a tree, as git grep's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const command = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "upper-file");
    defer gpa.free(command);
    try git.exec(io, &.{ "config", "diff.up.textconv", command });
    try git.writeFile(io, ".gitattributes", "*.txt diff=up\n*.bin diff=up\n");
    try git.writeFile(io, "words.txt", "hello there\nnothing\n");
    try git.writeFile(io, "data.bin", "raw\x00hello inside\n");
    try git.writeFile(io, "plain.dat", "hello as it is\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
    try git.writeFile(io, "words.txt", "hello in the working tree\n");
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head_oid = blk: {
        const text = try git.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(text);
        break :blk try hash.Oid.parse(.sha1, text);
    };
    var env = try testgit.datedEnv(gpa, 0);
    defer env.deinit();
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const tc: textconv.Textconv = .{ .programs = .{ .environ = &env } };

    try compare(gpa, io, &git, &repo, &.{ "--textconv", "-n", "HELLO" }, .{ .patterns = &.{"HELLO"}, .line_number = true, .textconv = &tc });
    try compare(gpa, io, &git, &repo, &.{ "--textconv", "hello" }, .{ .patterns = &.{"hello"}, .textconv = &tc });
    try compare(gpa, io, &git, &repo, &.{ "--textconv", "--cached", "HELLO" }, .{ .patterns = &.{"HELLO"}, .source = .index, .textconv = &tc });
    try compare(gpa, io, &git, &repo, &.{ "--textconv", "-c", "HELLO", "HEAD" }, .{ .patterns = &.{"HELLO"}, .show = .count, .source = .{ .tree = .{ .oid = head_oid, .name = "HEAD" } }, .textconv = &tc });
    try compare(gpa, io, &git, &repo, &.{"HELLO"}, .{ .patterns = &.{"HELLO"} });
}

/// A `-P` stand-in that finds its patterns as fixed text.
const FixedMatcher = struct {
    patterns: []const []const u8,

    fn find(context: *anyopaque, index: usize, line: []const u8, not_bol: bool) error{MatchFailed}!?grep_mod.Match {
        _ = not_bol;
        const m: *FixedMatcher = @ptrCast(@alignCast(context)); // safe: the context is always a FixedMatcher
        const at = std.mem.find(u8, line, m.patterns[index]) orelse return null;
        return .{ .start = at, .end = at + m.patterns[index].len };
    }
};

test "-P matches through the caller's matcher, and without one is refused by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var matcher: FixedMatcher = .{ .patterns = &.{ "count", "x *" } };
    const perl: grep_mod.Matcher = .{ .context = &matcher, .find = FixedMatcher.find };
    try compare(gpa, io, &git, &repo, &.{ "-F", "-n", "-o", "-e", "count", "-e", "x *" }, .{ .patterns = matcher.patterns, .syntax = .perl, .perl = perl, .line_number = true, .only_matching = true });
    try compare(gpa, io, &git, &repo, &.{ "-F", "-w", "-c", "-e", "count", "--and", "--not", "-e", "x *" }, .{ .expression = &.{ .{ .pattern = "count" }, .@"and", .not, .{ .pattern = "x *" } }, .syntax = .perl, .perl = perl, .word = true, .show = .count });
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.UnsupportedPerlRegex, grep_mod.grep(gpa, io, &repo, .{ .patterns = &.{"a"}, .syntax = .perl }, &out.writer));
}

fn randomAtom(a: Allocator, random: std.Random, out: *std.ArrayList(u8), depth: u32, extended: bool) !void {
    const roll = random.uintLessThan(u8, if (depth > 1) 6 else 8);
    switch (roll) {
        0, 1, 2 => try out.append(a, "abcx"[random.uintLessThan(usize, 4)]),
        3 => try out.append(a, '.'),
        4 => try out.appendSlice(a, ([_][]const u8{ "[ab]", "[^a]", "[a-c]", "[[:alpha:]]", "[x-z]" })[random.uintLessThan(usize, 5)]),
        5 => try out.appendSlice(a, ([_][]const u8{ "ab", "ca", "bb" })[random.uintLessThan(usize, 3)]),
        else => {
            try out.appendSlice(a, if (extended) "(" else "\\(");
            try randomBranches(a, random, out, depth + 1, extended);
            try out.appendSlice(a, if (extended) ")" else "\\)");
        },
    }
    switch (random.uintLessThan(u8, 8)) {
        0 => try out.append(a, '*'),
        1 => try out.appendSlice(a, if (extended) "+" else "\\+"),
        2 => try out.appendSlice(a, if (extended) "?" else "\\?"),
        3 => try out.appendSlice(a, if (extended) "{1,2}" else "\\{1,2\\}"),
        else => {},
    }
}

fn randomBranches(a: Allocator, random: std.Random, out: *std.ArrayList(u8), depth: u32, extended: bool) anyerror!void {
    const branches = 1 + random.uintLessThan(u8, 2);
    for (0..branches) |b| {
        if (b > 0) try out.appendSlice(a, if (extended) "|" else "\\|");
        const atoms = 1 + random.uintLessThan(u8, 3);
        for (0..atoms) |_| try randomAtom(a, random, out, depth, extended);
    }
}

test "random basic and extended expressions match where git grep's matcher matches, at the same columns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var prng: std.Random.DefaultPrng = .init(0x9e37);
    const random = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..60) |_| {
        const len = random.uintLessThan(usize, 24);
        for (0..len) |_| try text.append(gpa, "abcxyz _-"[random.uintLessThan(usize, 9)]);
        try text.append(gpa, '\n');
    }
    try git.writeFile(io, "lines.txt", text.items);
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "lines" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..testgit.corpusCases(80)) |i| {
        const extended = i % 2 == 0;
        var pattern: std.ArrayList(u8) = .empty;
        if (random.uintLessThan(u8, 4) == 0) try pattern.append(a, '^');
        try randomBranches(a, random, &pattern, 0, extended);
        if (random.uintLessThan(u8, 4) == 0) try pattern.append(a, '$');
        const syntax: grep_mod.Syntax = if (extended) .extended else .basic;
        const flag: []const u8 = if (extended) "-E" else "-G";
        try compare(gpa, io, &git, &repo, &.{ flag, "-o", "-n", "--column", "-e", pattern.items }, .{ .patterns = &.{pattern.items}, .syntax = syntax, .only_matching = true, .line_number = true, .column = true });
        try compare(gpa, io, &git, &repo, &.{ flag, "-c", "-w", "-i", "-e", pattern.items }, .{ .patterns = &.{pattern.items}, .syntax = syntax, .show = .count, .word = true, .ignore_case = true });
    }
}

/// Pieces of patterns git's regex reads in more than one way: braces,
/// brackets, anchors and repetitions where they may or may not stand.
const soup = [_][]const u8{
    "a",         "b",         "x",     "-",     "{",       "}",        ",",   "1",   "0",   "[",
    "]",         "[^",        "^",     "$",     "(",       ")",        "|",   "*",   "+",   "?",
    ".",         "\\",        "\\(",   "\\)",   "\\{",     "\\}",      "\\|", "\\+", "\\?", "\\1",
    "[:alpha:]", "[:digit:]", "[=a=]", "[.a.]", "[.-.]",   "[:",       ":]",  "\\w", "\\b", "\\<",
    "\\>",       "{1}",       "{,2}",  "{1,}",  "\\{1\\}", "\\{,2\\}", "\\,", "_",   " ",   "[.ab.]",
};

test "patterns made of braces, brackets, anchors and repetitions compile and match where git's own regex does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "lines.txt", "abc\na{,2}\nfoo_bar\na)b\n{x\n+y\n*z\n?q\nxx\naab-ab\na{1}b\nzz a-z\n:]\n[ab]\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "lines" });
    // relic reads patterns as git's compat/regex does, which glibc shares and
    // git for Windows builds; a git on another platform's regex (macOS's,
    // which refuses `a**`) has nothing to say here.
    {
        var probe = try git.capture(io, &.{ "grep", "-E", "-e", "a**" });
        defer probe.deinit(gpa);
        if (probe.code > 1) return error.SkipZigTest;
    }
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var prng: std.Random.DefaultPrng = .init(0x50a9);
    const random = prng.random();
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(gpa);
    for (0..testgit.corpusCases(400)) |i| {
        const extended = i % 2 == 0;
        pattern.clearRetainingCapacity();
        for (0..1 + random.uintLessThan(usize, 7)) |_| try pattern.appendSlice(gpa, soup[random.uintLessThan(usize, soup.len)]);
        const flag: []const u8 = if (extended) "-E" else "-G";
        var c = try git.capture(io, &.{ "grep", flag, "-o", "-n", "--column", "-e", pattern.items });
        defer c.deinit(gpa);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const options: grep_mod.Options = .{ .patterns = &.{pattern.items}, .syntax = if (extended) .extended else .basic, .only_matching = true, .line_number = true, .column = true };
        if (grep_mod.grep(gpa, io, &repo, options, &out.writer)) |outcome| {
            if (c.code > 1) std.debug.print("git refused {s} {s}: {s}\n", .{ flag, pattern.items, c.stderr });
            try std.testing.expect(c.code <= 1);
            try std.testing.expectEqualStrings(c.stdout, out.written());
            try std.testing.expectEqual(c.code == 0, outcome.matched);
        } else |err| {
            if (c.code != 128) std.debug.print("relic refused {s} {s} ({t}); git: exit {d}\n", .{ flag, pattern.items, err, c.code });
            try std.testing.expectEqual(error.InvalidPattern, err);
            try std.testing.expectEqual(@as(u8, 128), c.code);
        }
    }
}

test "git grep --color=always comes out byte for byte, under color.grep.<slot> and color.grep.match" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    const config_mod = @import("config/config.zig");
    const color = @import("config/color.zig");
    const settings = [_][]const []const u8{
        &.{},
        &.{ "color.grep.filename=blue ul", "color.grep.lineNumber=#ffaa00", "color.grep.column=dim", "color.grep.separator=normal", "color.grep.selected=yellow", "color.grep.context=italic", "color.grep.function=reverse" },
        &.{ "color.grep.match=green", "color.grep.matchContext=red" },
        &.{ "color.grep.matchSelected=magenta", "color.grep.match=cyan" },
    };
    for (settings) |set| {
        for (set) |s| {
            const eq = std.mem.findScalar(u8, s, '=').?;
            try git.exec(io, &.{ "config", s[0..eq], s[eq + 1 ..] });
        }
        var repo = try Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        const colors = (try grep_mod.Colors.configured(repo.configuration(), color.Output.always)).?;
        const cases = .{
            .{ &.{ "-n", "--column", "count" }, grep_mod.Options{ .patterns = &.{"count"}, .line_number = true, .column = true } },
            .{ &.{ "-n", "-C1", "count" }, grep_mod.Options{ .patterns = &.{"count"}, .line_number = true, .before = 1, .after = 1 } },
            .{ &.{ "-o", "-n", "--column", "co*unt\\|re[a-z]*" }, grep_mod.Options{ .patterns = &.{"co*unt\\|re[a-z]*"}, .only_matching = true, .line_number = true, .column = true } },
            .{ &.{ "-v", "-n", "a" }, grep_mod.Options{ .patterns = &.{"a"}, .invert = true, .line_number = true } },
            .{ &.{ "-l", "count" }, grep_mod.Options{ .patterns = &.{"count"}, .show = .files_with_matches } },
            .{ &.{ "-c", "count" }, grep_mod.Options{ .patterns = &.{"count"}, .show = .count } },
            .{ &.{ "-z", "-n", "count" }, grep_mod.Options{ .patterns = &.{"count"}, .null_separator = true, .line_number = true } },
            .{ &.{ "-p", "-n", "return" }, grep_mod.Options{ .patterns = &.{"return"}, .show_function = true, .line_number = true } },
            .{ &.{ "-W", "doubled" }, grep_mod.Options{ .patterns = &.{"doubled"}, .function_context = true } },
            .{ &.{ "-e", "alpha", "-e", "ta" }, grep_mod.Options{ .patterns = &.{ "alpha", "ta" } } },
            .{ &.{ "-h", "-i", "COUNT" }, grep_mod.Options{ .patterns = &.{"COUNT"}, .with_filename = false, .ignore_case = true } },
        };
        inline for (cases) |case| {
            var options = case[1];
            options.colors = &colors;
            try compare(gpa, io, &git, &repo, &(.{"--color=always"} ++ case[0].*), options);
        }
        for (set) |s| try git.exec(io, &.{ "config", "--unset", s[0..std.mem.findScalar(u8, s, '=').?] });
    }
    // a slot grep does not have is refused, as git dies on it
    var config = try config_mod.Config.parseText(gpa, "[color \"grep\"]\n\tbogus = red\n", .local);
    defer config.deinit();
    try std.testing.expectError(error.UnknownColorSlot, grep_mod.Colors.configured(&config, color.Output.always));
}

test "grep --recurse-submodules searches submodules as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try @import("submodule/move_test.zig").fixture(true);
    defer git.deinit();
    try git.writeFile(io, "sub/t", "t1 changed\n");
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const two_text = try git.line(io, &.{ "rev-parse", "two" });
    defer gpa.free(two_text);
    const two = try hash.Oid.parse(.sha1, two_text);

    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "-e", "1" }, .{ .patterns = &.{"1"}, .recurse_submodules = true });
    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "--cached", "-n", "1" }, .{ .patterns = &.{"1"}, .recurse_submodules = true, .source = .index, .line_number = true });
    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "-e", "2", "two" }, .{ .patterns = &.{"2"}, .recurse_submodules = true, .source = .{ .tree = .{ .oid = two, .name = "two" } } });
    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "-e", "1", "--", "sub/inner" }, .{ .patterns = &.{"1"}, .recurse_submodules = true, .pathspecs = &.{"sub/inner"} });
    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "-l", "2", "two", "--", "sub/s", "top" }, .{ .patterns = &.{"2"}, .recurse_submodules = true, .show = .files_with_matches, .pathspecs = &.{ "sub/s", "top" }, .source = .{ .tree = .{ .oid = two, .name = "two" } } });
    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "-l", "2", "two", "--", "sub", "top" }, .{ .patterns = &.{"2"}, .recurse_submodules = true, .show = .files_with_matches, .pathspecs = &.{ "sub", "top" }, .source = .{ .tree = .{ .oid = two, .name = "two" } } });
    try compare(gpa, io, &git, &repo, &.{ "--recurse-submodules", "-l", "1", "--", "sub/s", "top" }, .{ .patterns = &.{"1"}, .recurse_submodules = true, .show = .files_with_matches, .pathspecs = &.{ "sub/s", "top" } });
    try compare(gpa, io, &git, &repo, &.{ "-e", "1" }, .{ .patterns = &.{"1"} });

    try git.exec(io, &.{ "config", "submodule.recurse", "true" });
    _ = try repo.refreshConfig(io, .{});
    try compare(gpa, io, &git, &repo, &.{ "-c", "1" }, .{ .patterns = &.{"1"}, .show = .count });
    try git.exec(io, &.{ "config", "submodule.inner.active", "false" });
    try git.exec(io, &.{ "-C", "sub", "config", "submodule.inner.active", "false" });
    _ = try repo.refreshConfig(io, .{});
    try compare(gpa, io, &git, &repo, &.{"1"}, .{ .patterns = &.{"1"} });
    try git.exec(io, &.{ "config", "submodule.sub.active", "false" });
    _ = try repo.refreshConfig(io, .{});
    try compare(gpa, io, &git, &repo, &.{"1"}, .{ .patterns = &.{"1"} });
}
