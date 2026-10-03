//! `grep` against `git grep`: the same repository, the same options, the
//! same bytes and the same exit status.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const grep_mod = @import("grep.zig");
const hash = @import("hash.zig");
const repo_mod = @import("repo_core.zig");
const testgit = @import("testgit.zig");

const Repository = repo_mod.Repository;

fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *Repository, args: []const []const u8, options: grep_mod.Options) !void {
    // This follows today's git: `-m` came in 2.38, and `-o` with
    // `--column` numbers each match from the start of the line since 2.55,
    // where an older git counted from the end of the match before it.
    if (options.max_count != null and !try testgit.gitAtLeast(gpa, io, 2, 38)) return;
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

test "perl expressions and back-references are refused by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.UnsupportedPerlRegex, grep_mod.grep(gpa, io, &repo, .{ .patterns = &.{"a"}, .syntax = .perl }, &out.writer));
    try std.testing.expectError(error.UnsupportedBackreference, grep_mod.grep(gpa, io, &repo, .{ .patterns = &.{"\\(a\\)\\1"} }, &out.writer));
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
