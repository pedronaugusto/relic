//! Diffs against the real git: the same trees in, the same name-status, the
//! same counts, and the same patch text byte for byte.

const std = @import("std");
const Io = std.Io;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const diff = @import("diff.zig");

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
