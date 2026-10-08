//! `rangediff` against `git range-diff`: the same ranges, the same options,
//! the same bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const rangediff = @import("rangediff.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;
const Oid = hash.Oid;

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

fn range(gpa: Allocator, io: Io, git: *testgit.Repo, base: []const u8, tip: []const u8) !rangediff.Range {
    return .{ .base = try oidOf(gpa, io, git, base), .tip = try oidOf(gpa, io, git, tip) };
}

/// `git range-diff <args>` and `write` with `options`, byte for byte.
fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, args: []const []const u8, old: rangediff.Range, new: rangediff.Range, options: rangediff.Options) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "range-diff", "--no-color" });
    try argv.appendSlice(gpa, args);
    const theirs = try git.run(io, argv.items);
    defer gpa.free(theirs);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var ours: Io.Writer.Allocating = .init(gpa);
    defer ours.deinit();
    try rangediff.write(gpa, io, &repo, old, new, options, &ours.writer);
    std.testing.expectEqualStrings(theirs, ours.written()) catch |err| {
        for (args) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print(": range-diff differs\n", .{});
        return err;
    };
}

fn commitAll(io: Io, git: *testgit.Repo, message: []const u8) !void {
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", message });
}

/// A base and two series grown from it: a commit kept as it was, one
/// changed, one dropped and one added, a rename, a mode change, a deletion,
/// a binary file, a message with tabs and trailing whitespace, a second
/// author the mailmap renames, and an empty commit.
fn buildSeries(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a.c", "int main(void)\n{\n\treturn 0;\n}\n\nstatic int helper(int x)\n{\n\treturn x + 1;\n}\n");
    try git.writeFile(io, "old name.txt", "this file is renamed later\nwith enough lines\nto be found\nas a rename\n");
    try git.writeFile(io, "run.sh", "#!/bin/sh\necho run\n");
    try git.writeFile(io, "gone.txt", "to be deleted\n");
    try git.writeFile(io, ".mailmap", "Proper Name <proper@example.com> <other@example.com>\n");
    try commitAll(io, git, "base");
    try git.exec(io, &.{ "tag", "base" });

    try git.exec(io, &.{ "checkout", "-q", "-b", "old" });
    try git.writeFile(io, "a.c", "int main(void)\n{\n\treturn 1;\n}\n\nstatic int helper(int x)\n{\n\treturn x + 1;\n}\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "--cleanup=verbatim", "-m", "\n\nReturn one\n\nBecause\tzero was\twrong.   \n\n\n" });
    try git.writeFile(io, "b.txt", "x\ty\n");
    try commitAll(io, git, "Add b");
    try git.exec(io, &.{ "mv", "old name.txt", "new name.txt" });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "run.sh" });
    try git.dir.deleteFile(io, "gone.txt");
    try commitAll(io, git, "Rename, chmod and delete");
    try git.writeFile(io, "blob.bin", "\x00\x01\x02binary\n");
    try commitAll(io, git, "Add a binary file");
    try git.exec(io, &.{ "-c", "user.name=Other", "-c", "user.email=other@example.com", "commit", "-q", "--allow-empty", "-m", "Empty, from someone the mailmap renames" });
    try git.writeFile(io, "a.c", "int main(void)\n{\n\treturn 1;\n}\n\nstatic int helper(int x)\n{\n\treturn x + 2;\n}\n");
    try commitAll(io, git, "Dropped later");

    try git.exec(io, &.{ "checkout", "-q", "-b", "new", "base" });
    try git.writeFile(io, "a.c", "int main(void)\n{\n\treturn 1;\n}\n\nstatic int helper(int x)\n{\n\treturn x + 1;\n}\n");
    try commitAll(io, git, "Return one\n\nBecause\tzero was\twrong.\n\tAn indented line, caf\xc3\xa9\tand a tab after it.\n");
    try git.writeFile(io, "b.txt", "x\tz\nsecond line\n");
    try commitAll(io, git, "Add b, with a second line");
    try git.exec(io, &.{ "mv", "old name.txt", "new name.txt" });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "run.sh" });
    try git.dir.deleteFile(io, "gone.txt");
    try commitAll(io, git, "Rename, chmod and delete");
    try git.writeFile(io, "blob.bin", "\x00\x01\x02binary, changed\n");
    try commitAll(io, git, "Add a binary file");
    try git.exec(io, &.{ "-c", "user.name=Other", "-c", "user.email=other@example.com", "commit", "-q", "--allow-empty", "-m", "Empty, from someone the mailmap renames" });
    try git.writeFile(io, "c.txt", "a new commit\n");
    try commitAll(io, git, "Added later");
}

test "two series are paired and their differences written as git range-diff writes them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildSeries(io, &git);
    const old = try range(gpa, io, &git, "base", "old");
    const new = try range(gpa, io, &git, "base", "new");

    try compare(gpa, io, &git, &.{ "base", "old", "new" }, old, new, .{});
    try compare(gpa, io, &git, &.{ "base..old", "base..new" }, old, new, .{});
    try compare(gpa, io, &git, &.{"old...new"}, try range(gpa, io, &git, "new", "old"), try range(gpa, io, &git, "old", "new"), .{});
    try compare(gpa, io, &git, &.{ "--creation-factor=200", "base", "old", "new" }, old, new, .{ .creation_factor = 200 });
    try compare(gpa, io, &git, &.{ "--creation-factor=0", "base", "old", "new" }, old, new, .{ .creation_factor = 0 });
    try compare(gpa, io, &git, &.{ "--left-only", "base", "old", "new" }, old, new, .{ .left_only = true });
    try compare(gpa, io, &git, &.{ "--right-only", "base", "old", "new" }, old, new, .{ .right_only = true });
    try compare(gpa, io, &git, &.{ "-s", "base", "old", "new" }, old, new, .{ .patch = false });
    try compare(gpa, io, &git, &.{ "-U1", "base", "old", "new" }, old, new, .{ .diff = .{ .context = 1 } });
    try compare(gpa, io, &git, &.{ "base", "new", "old" }, new, old, .{});
    try compare(gpa, io, &git, &.{ "base", "old", "old" }, old, old, .{});

    // notes are part of a patch unless asked otherwise
    try git.exec(io, &.{ "notes", "add", "-m", "A note on the old one.\n\nWith a second paragraph.", "old~5" });
    try git.exec(io, &.{ "notes", "add", "-m", "A note on the new one.", "new~5" });
    try compare(gpa, io, &git, &.{ "base", "old", "new" }, old, new, .{});
    try compare(gpa, io, &git, &.{ "--no-notes", "base", "old", "new" }, old, new, .{ .notes = false });

    // diff.context reaches both the patches and their diff
    try git.exec(io, &.{ "config", "diff.context", "1" });
    try compare(gpa, io, &git, &.{ "base", "old", "new" }, old, new, .{});
}

test "patches alike are paired as git's hash map pairs them, and a large series as its solver does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "f.txt", "one\n");
    try commitAll(io, &git, "base");
    try git.exec(io, &.{ "tag", "base" });
    // the same diff three times on each side, with different messages
    for ([_][]const u8{ "old", "new" }) |side| {
        try git.exec(io, &.{ "checkout", "-q", "-b", side, "base" });
        for (0..3) |k| {
            try git.writeFile(io, "f.txt", "one\ntwo\n");
            const add = try gpa.print("{s}: add {d}", .{ side, k });
            defer gpa.free(add);
            try commitAll(io, &git, add);
            try git.writeFile(io, "f.txt", "one\n");
            const remove = try gpa.print("{s}: remove {d}", .{ side, k });
            defer gpa.free(remove);
            try commitAll(io, &git, remove);
        }
    }
    try compare(gpa, io, &git, &.{ "base", "old", "new" }, try range(gpa, io, &git, "base", "old"), try range(gpa, io, &git, "base", "new"), .{});

    // past the hash map's first size, and through its resizes back down
    try git.exec(io, &.{ "checkout", "-q", "-b", "long", "base" });
    for (0..60) |k| {
        try git.writeFile(io, "f.txt", if (k % 2 == 0) "one\ntwo\n" else "one\n");
        const message = try gpa.print("long {d}", .{k});
        defer gpa.free(message);
        try commitAll(io, &git, message);
    }
    try git.exec(io, &.{ "checkout", "-q", "-b", "long2", "base" });
    for (0..58) |k| {
        try git.writeFile(io, "f.txt", if (k % 2 == 0) "one\ntwo\n" else "one\n");
        const message = try gpa.print("long2 {d}", .{k});
        defer gpa.free(message);
        try commitAll(io, &git, message);
    }
    try compare(gpa, io, &git, &.{ "-s", "base", "long", "long2" }, try range(gpa, io, &git, "base", "long"), try range(gpa, io, &git, "base", "long2"), .{ .patch = false });
}

/// Two random series from one base: each commit of the old one writes a
/// file of its own, and the new one keeps it, changes a line of it or of
/// its message, drops it, or moves it, with commits of its own between.
fn randomSeries(gpa: Allocator, io: Io, git: *testgit.Repo, random: std.Random) !void {
    try git.writeFile(io, "base.txt", "base\n");
    try commitAll(io, git, "base");
    try git.exec(io, &.{ "tag", "base" });
    const count = 3 + random.uintLessThan(usize, 10);
    const Plan = struct { file: usize, lines: [12]u8, edit: u8, keep: bool };
    var plans: std.ArrayList(Plan) = .empty;
    defer plans.deinit(gpa);
    for (0..count) |k| {
        var p: Plan = .{ .file = k, .lines = undefined, .edit = random.uintLessThan(u8, 6), .keep = random.uintLessThan(u8, 5) != 0 };
        for (&p.lines) |*l| l.* = 'a' + random.uintLessThan(u8, 26);
        try plans.append(gpa, p);
    }
    try git.exec(io, &.{ "checkout", "-q", "-b", "old", "base" });
    for (plans.items) |p| try writePlanned(gpa, io, git, p.file, &p.lines, null, "change");
    try git.exec(io, &.{ "checkout", "-q", "-b", "new", "base" });
    random.shuffle(Plan, plans.items[0 .. plans.items.len / 2]);
    for (plans.items, 0..) |p, k| {
        if (random.uintLessThan(u8, 4) == 0) {
            var lines: [12]u8 = undefined;
            for (&lines) |*l| l.* = 'a' + random.uintLessThan(u8, 26);
            try writePlanned(gpa, io, git, 100 + k, &lines, null, "inserted");
        }
        if (!p.keep) continue;
        switch (p.edit) {
            0 => try writePlanned(gpa, io, git, p.file, &p.lines, random.uintLessThan(usize, 12), "change"),
            1 => try writePlanned(gpa, io, git, p.file, &p.lines, null, "reworded"),
            else => try writePlanned(gpa, io, git, p.file, &p.lines, null, "change"),
        }
    }
}

fn writePlanned(gpa: Allocator, io: Io, git: *testgit.Repo, file: usize, lines: []const u8, changed: ?usize, word: []const u8) !void {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    for (lines, 0..) |l, k| {
        try content.appendNTimes(gpa, l, 3);
        if (changed == k) try content.appendSlice(gpa, " changed");
        try content.append(gpa, '\n');
    }
    const name = try gpa.print("f{d}.txt", .{file});
    defer gpa.free(name);
    try git.writeFile(io, name, content.items);
    const message = try gpa.print("{s} {d}", .{ word, file });
    defer gpa.free(message);
    try commitAll(io, git, message);
}

const random_seeds = testgit.corpusCases(12);

test "random series are paired as git pairs them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for (0..random_seeds) |seed| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        var prng: std.Random.DefaultPrng = .init(seed);
        try randomSeries(gpa, io, &git, prng.random());
        const old = try range(gpa, io, &git, "base", "old");
        const new = try range(gpa, io, &git, "base", "new");
        try compare(gpa, io, &git, &.{ "base", "old", "new" }, old, new, .{});
        try compare(gpa, io, &git, &.{ "--creation-factor=100", "-s", "base", "old", "new" }, old, new, .{ .creation_factor = 100, .patch = false });
    }
}

test "a cost matrix past the limit is refused, as git refuses it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildSeries(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const old = try range(gpa, io, &git, "base", "old");
    const new = try range(gpa, io, &git, "base", "new");
    try std.testing.expectError(error.RangeDiffTooLarge, rangediff.write(gpa, io, &repo, old, new, .{ .max_memory = 100 }, &out.writer));
    try std.testing.expectError(error.LeftAndRightOnly, rangediff.write(gpa, io, &repo, old, new, .{ .left_only = true, .right_only = true }, &out.writer));
}
