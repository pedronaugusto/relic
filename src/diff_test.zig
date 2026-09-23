//! Diffs against the real git: the same trees in, the same name-status, the
//! same counts, and the same patch text byte for byte.

const std = @import("std");
const Io = std.Io;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const diff = @import("diff.zig");
const textdiff = @import("textdiff.zig");

const Oid = hash.Oid;

const Pair = struct {
    repo: testgit.Repo,
    git_dir: Io.Dir,
    db: odb_mod.Odb,
    old: Oid,
    new: Oid,
    old_text: []u8,
    new_text: []u8,

    fn deinit(p: *Pair, io: Io, gpa: std.mem.Allocator) void {
        gpa.free(p.old_text);
        gpa.free(p.new_text);
        p.db.deinit(io);
        p.git_dir.close(io);
        p.repo.deinit();
    }
};

/// Build a repository with two commits and hand back both trees.
fn buildPair(gpa: std.mem.Allocator, io: Io, comptime setup: fn (*testgit.Repo, Io) anyerror!void) !Pair {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    try setup(&repo, io);
    const old_text = try repo.line(io, &.{ "rev-parse", "HEAD~1^{tree}" });
    errdefer gpa.free(old_text);
    const new_text = try repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    errdefer gpa.free(new_text);
    const git_dir = try repo.gitDir(io);
    const db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    return .{
        .repo = repo,
        .git_dir = git_dir,
        .db = db,
        .old = try Oid.parse(.sha1, old_text),
        .new = try Oid.parse(.sha1, new_text),
        .old_text = old_text,
        .new_text = new_text,
    };
}

fn setupMixed(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.writeFile(io, "unchanged.txt", "same\n");
    try repo.writeFile(io, "modified.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n");
    try repo.writeFile(io, "deleted.txt", "gone\n");
    try repo.writeFile(io, "dir/nested.txt", "nested\n");
    try repo.writeFile(io, "exec.sh", "#!/bin/sh\n");
    try repo.writeFile(io, "binary.bin", "before\x00binary\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    try repo.writeFile(io, "modified.txt", "one\ntwo\nTHREE\nfour\nfive\nsix\nSEVEN\neight\n");
    try repo.dir.deleteFile(io, "deleted.txt");
    try repo.writeFile(io, "added.txt", "brand new\n");
    try repo.writeFile(io, "binary.bin", "after\x00binary\n");
    try repo.exec(io, &.{ "add", "-A" });
    // The mode change is made in the index and not on the disk. What is
    // being compared here is two trees, so where the 100755 came from does
    // not matter, and a filesystem with no executable bit — Windows — has
    // no other way to put one in a tree. It is git's own way of doing it.
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "exec.sh" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
}

test "name-status agrees with git diff-tree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupMixed);
    defer pair.deinit(io, gpa);

    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();

    const expected = try pair.repo.run(io, &.{ "diff-tree", "--name-status", "-r", pair.old_text, pair.new_text });
    defer gpa.free(expected);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (changes.items) |change| {
        try out.writer.print("{c}\t{s}\n", .{ change.letter(), change.path() });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "numstat agrees with git, including the binary marker" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupMixed);
    defer pair.deinit(io, gpa);

    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();
    const counts = try diff.numstat(gpa, io, &pair.db, changes.items, .{});
    defer gpa.free(counts);

    const expected = try pair.repo.run(io, &.{ "diff-tree", "--numstat", "-r", pair.old_text, pair.new_text });
    defer gpa.free(expected);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (changes.items, counts) |change, count| {
        if (count.binary) {
            try out.writer.print("-\t-\t{s}\n", .{change.path()});
        } else {
            try out.writer.print("{d}\t{d}\t{s}\n", .{ count.plus, count.minus, change.path() });
        }
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "the unified patch is byte for byte what git prints" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupMixed);
    defer pair.deinit(io, gpa);

    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();

    for (changes.items) |change| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try diff.unified(gpa, io, &out.writer, &pair.db, change, .{});

        const expected = try pair.repo.run(io, &.{
            "diff",         "--no-color",  "-U3",
            "--no-renames", pair.old_text, pair.new_text,
            "--",           change.path(),
        });
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, out.written());
    }
}

fn setupGitlink(repo: *testgit.Repo, io: Io) anyerror!void {
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000," ++ "1" ** 40 ++ ",vendor/lib" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.exec(io, &.{ "update-index", "--cacheinfo", "160000," ++ "2" ** 40 ++ ",vendor/lib" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
}

test "gitlink counts and patch text agree with git" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupGitlink);
    defer pair.deinit(io, gpa);
    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);

    const counts = try diff.numstat(gpa, io, &pair.db, changes.items, .{});
    defer gpa.free(counts);
    try std.testing.expectEqual(@as(u32, 1), counts[0].plus);
    try std.testing.expectEqual(@as(u32, 1), counts[0].minus);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diff.unified(gpa, io, &out.writer, &pair.db, changes.items[0], .{});
    const expected = try pair.repo.run(io, &.{ "diff", "--no-color", "-U3", pair.old_text, pair.new_text, "--", "vendor/lib" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}

fn setupSource(repo: *testgit.Repo, io: Io) anyerror!void {
    const before =
        "const std = @import(\"std\");\n" ++
        "\n" ++
        "pub fn first(a: u32) u32 {\n" ++
        "    var total: u32 = 0;\n" ++
        "    total += a;\n" ++
        "    total += 1;\n" ++
        "    total += 2;\n" ++
        "    return total;\n" ++
        "}\n" ++
        "\n" ++
        "pub fn second(b: u32) u32 {\n" ++
        "    var total: u32 = 0;\n" ++
        "    total += b;\n" ++
        "    total += 3;\n" ++
        "    total += 4;\n" ++
        "    return total;\n" ++
        "}\n";
    try repo.writeFile(io, "src/main.zig", before);
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    const after =
        "const std = @import(\"std\");\n" ++
        "\n" ++
        "pub fn first(a: u32) u32 {\n" ++
        "    var total: u32 = 0;\n" ++
        "    total += a;\n" ++
        "    total += 11;\n" ++
        "    total += 2;\n" ++
        "    return total;\n" ++
        "}\n" ++
        "\n" ++
        "pub fn second(b: u32) u32 {\n" ++
        "    var total: u32 = 100;\n" ++
        "    total += b;\n" ++
        "    total += 3;\n" ++
        "    total += 44;\n" ++
        "    return total;\n" ++
        "}\n";
    try repo.writeFile(io, "src/main.zig", after);
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
}

test "the hunk header carries the enclosing line git puts there" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupSource);
    defer pair.deinit(io, gpa);

    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);

    for ([_]usize{ 0, 1, 3, 5 }) |context| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try diff.unified(gpa, io, &out.writer, &pair.db, changes.items[0], .{ .context = context });

        var arg_buf: [8]u8 = undefined;
        const context_arg = try std.fmt.bufPrint(&arg_buf, "-U{d}", .{context});
        const expected = try pair.repo.run(io, &.{
            "diff",         "--no-color",  context_arg,
            "--no-renames", pair.old_text, pair.new_text,
        });
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, out.written());
    }
}

fn setupRename(repo: *testgit.Repo, io: Io) anyerror!void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(repo.gpa);
    for (0..60) |i| try body.print(repo.gpa, "line {d} of a file with real content\n", .{i});
    try repo.writeFile(io, "before.txt", body.items);
    try repo.writeFile(io, "exact.txt", "moved without a change\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    try repo.dir.deleteFile(io, "before.txt");
    try body.appendSlice(repo.gpa, "one more line\n");
    try repo.writeFile(io, "after.txt", body.items);
    try repo.dir.deleteFile(io, "exact.txt");
    try repo.writeFile(io, "elsewhere.txt", "moved without a change\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
}

test "rename detection finds what git -M finds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupRename);
    defer pair.deinit(io, gpa);

    // Without detection, the same thing git shows without -M.
    var plain = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer plain.deinit();
    const plain_expected = try pair.repo.run(io, &.{
        "diff-tree", "--name-status", "-r", "--no-renames", pair.old_text, pair.new_text,
    });
    defer gpa.free(plain_expected);
    var plain_out: std.Io.Writer.Allocating = .init(gpa);
    defer plain_out.deinit();
    for (plain.items) |change| {
        try plain_out.writer.print("{c}\t{s}\n", .{ change.letter(), change.path() });
    }
    try std.testing.expectEqualStrings(plain_expected, plain_out.written());

    // With detection, both moves are renames and git agrees which is which.
    var renamed = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{ .renames = .{} });
    defer renamed.deinit();
    try std.testing.expectEqual(@as(usize, 2), renamed.items.len);
    for (renamed.items) |change| {
        try std.testing.expectEqual(diff.Status.renamed, change.status);
        try std.testing.expect(change.similarity >= 50);
    }
    const exact = renamed.find("elsewhere.txt").?;
    try std.testing.expectEqual(@as(u8, 100), exact.similarity);
    try std.testing.expectEqualStrings("exact.txt", exact.old.?.path);
    const inexact = renamed.find("after.txt").?;
    try std.testing.expectEqualStrings("before.txt", inexact.old.?.path);

    const expected = try pair.repo.run(io, &.{
        "diff-tree", "--name-status", "-r", "-M", pair.old_text, pair.new_text,
    });
    defer gpa.free(expected);
    // git prints `R<score>`; the score is the similarity this computed.
    try std.testing.expect(std.mem.indexOf(u8, expected, "before.txt\tafter.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, expected, "exact.txt\telsewhere.txt") != null);
}

test "a diff against the empty tree is every file added" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupMixed);
    defer pair.deinit(io, gpa);

    var changes = try diff.tree(gpa, io, &pair.db, null, pair.new, .{});
    defer changes.deinit();
    for (changes.items) |change| {
        try std.testing.expectEqual(diff.Status.added, change.status);
    }
    const expected = try pair.repo.run(io, &.{ "ls-tree", "-r", "--name-only", pair.new_text });
    defer gpa.free(expected);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(changes.find(line) != null);
        count += 1;
    }
    try std.testing.expectEqual(count, changes.items.len);
}

const frob_before =
    "#include <stdio.h>\n" ++
    "\n" ++
    "// Frobs foo heartily\n" ++
    "int frobnitz(int foo)\n" ++
    "{\n" ++
    "    int i;\n" ++
    "    for(i = 0; i < 10; i++)\n" ++
    "    {\n" ++
    "        printf(\"Your answer is: \");\n" ++
    "        printf(\"%d\\n\", foo);\n" ++
    "    }\n" ++
    "}\n" ++
    "\n" ++
    "int fact(int n)\n" ++
    "{\n" ++
    "    if(n > 1)\n" ++
    "    {\n" ++
    "        return fact(n-1) * n;\n" ++
    "    }\n" ++
    "    return 1;\n" ++
    "}\n" ++
    "\n" ++
    "int main(int argc, char **argv)\n" ++
    "{\n" ++
    "    frobnitz(fact(10));\n" ++
    "}\n";

const frob_after =
    "#include <stdio.h>\n" ++
    "\n" ++
    "int fib(int n)\n" ++
    "{\n" ++
    "    if(n > 2)\n" ++
    "    {\n" ++
    "        return fib(n-1) + fib(n-2);\n" ++
    "    }\n" ++
    "    return 1;\n" ++
    "}\n" ++
    "\n" ++
    "// Frobs foo heartily\n" ++
    "int frobnitz(int foo)\n" ++
    "{\n" ++
    "    int i;\n" ++
    "    for(i = 0; i < 10; i++)\n" ++
    "    {\n" ++
    "        printf(\"%d\\n\", foo);\n" ++
    "    }\n" ++
    "}\n" ++
    "\n" ++
    "int main(int argc, char **argv)\n" ++
    "{\n" ++
    "    frobnitz(fib(10));\n" ++
    "}\n";

/// A small deterministic generator, so a fixture is the same on every run
/// and a failure can be reproduced from its file name.
const Lcg = struct {
    state: u64,

    fn next(l: *Lcg, bound: u64) u64 {
        l.state = l.state *% 6364136223846793005 +% 1442695040888963407;
        return (l.state >> 33) % bound;
    }
};

/// One line of generated text. Most lines come from a handful, so the files
/// repeat themselves the way source does and the unique lines are few; the
/// rest are unique, which is what patience anchors on.
fn generatedLine(l: *Lcg, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const common = [_][]const u8{ "{\n", "}\n", "\n", "    return x;\n", "    x += 1;\n", "else\n" };
    if (l.next(3) != 0) {
        try out.appendSlice(gpa, common[@intCast(l.next(common.len))]);
    } else {
        try out.print(gpa, "unique line {d}\n", .{l.next(1_000_000)});
    }
}

fn setupAlgorithms(repo: *testgit.Repo, io: Io) anyerror!void {
    const gpa = repo.gpa;
    try repo.writeFile(io, "frob.c", frob_before);
    var before: [24]std.ArrayList(u8) = @splat(.empty);
    defer for (&before) |*b| b.deinit(gpa);
    for (&before, 0..) |*text, i| {
        var l: Lcg = .{ .state = i + 1 };
        const lines = 10 + l.next(70);
        for (0..lines) |_| try generatedLine(&l, text, gpa);
        var name: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&name, "gen{d:0>2}.txt", .{i}), text.items);
    }
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });

    try repo.writeFile(io, "frob.c", frob_after);
    for (&before, 0..) |*text, i| {
        var l: Lcg = .{ .state = 1000 + i };
        var after: std.ArrayList(u8) = .empty;
        defer after.deinit(gpa);
        var lines = std.mem.splitScalar(u8, text.items, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null and line.len == 0) break;
            switch (l.next(10)) {
                // Dropped.
                0 => {},
                // Replaced.
                1 => try generatedLine(&l, &after, gpa),
                // Something inserted before it.
                2 => {
                    try generatedLine(&l, &after, gpa);
                    try after.print(gpa, "{s}\n", .{line});
                },
                else => try after.print(gpa, "{s}\n", .{line}),
            }
        }
        var name: [32]u8 = undefined;
        try repo.writeFile(io, try std.fmt.bufPrint(&name, "gen{d:0>2}.txt", .{i}), after.items);
    }
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
}

/// Every change's patch under `options`, against what git prints with
/// `flags` for the same two trees.
fn expectPatches(pair: *Pair, io: Io, options: diff.Options, flags: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();
    try std.testing.expect(changes.items.len > 20);

    for (changes.items) |change| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try diff.unified(gpa, io, &out.writer, &pair.db, change, options);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "diff", "--no-color", "-U3", "--no-renames" });
        try argv.appendSlice(gpa, flags);
        try argv.appendSlice(gpa, &.{ pair.old_text, pair.new_text, "--", change.path() });
        const expected = try pair.repo.run(io, argv.items);
        defer gpa.free(expected);
        std.testing.expectEqualStrings(expected, out.written()) catch |err| {
            std.debug.print("differs at {s}\n", .{change.path()});
            return err;
        };
    }
}

/// The hunks of `git diff -U0` as the changes they stand for.
fn parseZeroContextHunks(gpa: std.mem.Allocator, text: []const u8) ![]textdiff.Change {
    var out: std.ArrayList(textdiff.Change) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "@@ -")) continue;
        const close = std.mem.indexOfPos(u8, line, 4, " @@") orelse return error.BadHunk;
        const ranges = line[4..close];
        const plus = std.mem.indexOf(u8, ranges, " +") orelse return error.BadHunk;
        const old = try parseRange(ranges[0..plus]);
        const new = try parseRange(ranges[plus + 2 ..]);
        try out.append(gpa, .{
            .old_start = if (old.count == 0) old.start else old.start - 1,
            .old_count = old.count,
            .new_start = if (new.count == 0) new.start else new.start - 1,
            .new_count = new.count,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn parseRange(text: []const u8) !struct { start: usize, count: usize } {
    if (std.mem.indexOfScalar(u8, text, ',')) |comma| {
        return .{
            .start = try std.fmt.parseInt(usize, text[0..comma], 10),
            .count = try std.fmt.parseInt(usize, text[comma + 1 ..], 10),
        };
    }
    return .{ .start = try std.fmt.parseInt(usize, text, 10), .count = 1 };
}

test "the histogram diff lands on the lines git's does, over a random corpus" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    // Few distinct lines, so that every choice histogram makes -- which
    // run anchors, which occurrence comes first, when a region goes to
    // Myers and when a slid run is diffed again -- is exercised.
    var prng = std.Random.DefaultPrng.init(0x68697374);
    const rng = prng.random();
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(gpa);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(gpa);
    for (0..40) |case| {
        const alphabet: u8 = 2 + rng.uintLessThan(u8, 6);
        old.clearRetainingCapacity();
        for (0..rng.uintLessThan(usize, 40)) |_| {
            try old.append(gpa, 'a' + rng.uintLessThan(u8, alphabet));
            if (rng.uintLessThan(u8, 5) == 0) try old.append(gpa, ' ');
            try old.append(gpa, '\n');
        }
        new.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, old.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            switch (rng.uintLessThan(u8, 10)) {
                0 => {},
                1 => try new.appendSlice(gpa, &.{ 'a' + rng.uintLessThan(u8, alphabet), '\n' }),
                else => {},
            }
            if (rng.uintLessThan(u8, 10) != 0) {
                try new.appendSlice(gpa, line);
                try new.append(gpa, '\n');
            }
        }
        try repo.writeFile(io, "old", old.items);
        try repo.writeFile(io, "new", new.items);
        // `diff --no-index` exits 1 when the files differ; the output is
        // what is compared.
        const output = try repo.runInput(io, &.{ "diff", "--no-index", "--diff-algorithm=histogram", "-U0", "old", "new" }, "");
        defer gpa.free(output);
        const expected = try parseZeroContextHunks(gpa, output);
        defer gpa.free(expected);

        const old_lines = try textdiff.splitLines(gpa, old.items);
        defer gpa.free(old_lines);
        const new_lines = try textdiff.splitLines(gpa, new.items);
        defer gpa.free(new_lines);
        const got = try textdiff.diffLines(gpa, old_lines, new_lines, .{ .algorithm = .histogram });
        defer gpa.free(got);
        std.testing.expectEqualSlices(textdiff.Change, expected, got) catch |err| {
            std.debug.print("case {d}\n", .{case});
            return err;
        };
    }
}

test "the patience patch is byte for byte what git diff --patience prints" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupAlgorithms);
    defer pair.deinit(io, gpa);
    try expectPatches(&pair, io, .{ .algorithm = .patience }, &.{"--patience"});

    // The fixtures are ones where the choice shows: on some of them the
    // patience patch is not the Myers patch.
    var changes = try diff.tree(gpa, io, &pair.db, pair.old, pair.new, .{});
    defer changes.deinit();
    var differing: usize = 0;
    for (changes.items) |change| {
        var mine: std.Io.Writer.Allocating = .init(gpa);
        defer mine.deinit();
        try diff.unified(gpa, io, &mine.writer, &pair.db, change, .{ .algorithm = .patience });
        var plain: std.Io.Writer.Allocating = .init(gpa);
        defer plain.deinit();
        try diff.unified(gpa, io, &plain.writer, &pair.db, change, .{});
        if (!std.mem.eql(u8, mine.written(), plain.written())) differing += 1;
    }
    try std.testing.expect(differing >= 5);
}

test "plain myers is unchanged beside patience, on the same fixtures" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupAlgorithms);
    defer pair.deinit(io, gpa);
    try expectPatches(&pair, io, .{}, &.{"--diff-algorithm=myers"});
}

test "a minimal patch is what git diff --minimal prints" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupAlgorithms);
    defer pair.deinit(io, gpa);
    try expectPatches(&pair, io, .{ .minimal = true }, &.{"--minimal"});
}

test "an anchored patience patch is what git diff --anchored prints" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupAlgorithms);
    defer pair.deinit(io, gpa);
    try expectPatches(
        &pair,
        io,
        .{ .algorithm = .patience, .anchors = &.{ "    return", "int main" } },
        &.{ "--anchored=    return", "--anchored=int main" },
    );
}

test "diff.algorithm picks the algorithm git picks when none is asked for" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pair = try buildPair(gpa, io, setupAlgorithms);
    defer pair.deinit(io, gpa);

    const config_mod = @import("config.zig");
    for ([_][]const u8{ "patience", "Minimal", "Myers", "default" }) |value| {
        try pair.repo.exec(io, &.{ "config", "diff.algorithm", value });
        var git_dir = try pair.repo.gitDir(io);
        defer git_dir.close(io);
        var config = try config_mod.Config.openFile(gpa, io, .{ .dir = git_dir, .sub_path = "config" }, .local, .{});
        defer config.deinit();
        const options = try diff.configured(&config, .{});
        expectPatches(&pair, io, options, &.{}) catch |err| {
            std.debug.print("with diff.algorithm={s}\n", .{value});
            return err;
        };
    }

    var bogus = try config_mod.Config.parseText(gpa, "[diff]\n\talgorithm = sideways\n", .local);
    defer bogus.deinit();
    try std.testing.expectError(error.UnknownDiffAlgorithm, diff.configured(&bogus, .{}));
    var histogram = try config_mod.Config.parseText(gpa, "[diff]\n\talgorithm = HISTOGRAM\n", .local);
    defer histogram.deinit();
    try std.testing.expectEqual(diff.Algorithm.histogram, (try diff.configured(&histogram, .{})).algorithm);
    var absent = config_mod.Config.initEmpty(gpa);
    defer absent.deinit();
    try std.testing.expectEqual(diff.Algorithm.histogram, (try diff.configured(&absent, .{ .algorithm = .histogram })).algorithm);
}
