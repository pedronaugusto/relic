//! Status's renames against `git status --porcelain`: the same renames,
//! copies and deletions, staged and in the working tree, under each
//! `status.renames`.
const std = @import("std");
const builtin = @import("builtin");
const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");
const checkout = @import("../checkout/checkout.zig");
const renames = @import("renames.zig");

fn code(change: checkout.Change) u8 {
    return switch (change) {
        .unmodified => ' ',
        .added => 'A',
        .modified => 'M',
        .deleted => 'D',
        .type_changed => 'T',
        .untracked => '?',
        .ignored => '!',
        .renamed => 'R',
        .copied => 'C',
    };
}

/// relic's status as `git status --porcelain` lines, sorted.
fn ours(gpa: std.mem.Allocator, io: std.Io, git: *testgit.Repo) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var locked = try repo.lockIndex(io);
    defer locked.deinit(io);
    const head_tree = try repo.headTree(io);
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    var result = try checkout.status(gpa, io, repo.workDirectory().?, .{ .index = &locked.index, .db = repo.objectDatabase() }, .{
        .rules = rules,
        .head_tree = head_tree,
        .added_content = true,
    });
    defer result.deinit();
    if (try renames.configured(repo.configuration())) |options| {
        try renames.find(io, &result, .{ .index = &locked.index, .db = repo.objectDatabase(), .head_tree = head_tree }, options);
    }
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (result.entries) |e| {
        // A path deleted from the index and back in the working tree is two
        // lines to git.
        if (e.unstaged == .untracked) {
            try lines.append(gpa, try gpa.print("?? {s}", .{e.path}));
            if (e.staged == .unmodified) continue;
        }
        const unstaged: checkout.Change = if (e.unstaged == .untracked) .unmodified else e.unstaged;
        const line = if (e.source) |from|
            try gpa.print("{c}{c} {s} -> {s}", .{ code(e.staged), code(unstaged), from, e.path })
        else
            try gpa.print("{c}{c} {s}", .{ code(e.staged), code(unstaged), e.path });
        try lines.append(gpa, line);
    }
    return sorted(gpa, lines.items);
}

fn sorted(gpa: std.mem.Allocator, lines: [][]const u8) ![]u8 {
    std.mem.sort([]const u8, lines, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |l| try out.print(gpa, "{s}\n", .{l});
    return out.toOwnedSlice(gpa);
}

fn theirs(gpa: std.mem.Allocator, io: std.Io, git: *testgit.Repo) ![]u8 {
    const text = try git.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(text);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len != 0) try lines.append(gpa, l);
    return sorted(gpa, lines.items);
}

test "status finds the staged renames and copies git status finds, under each status.renames" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const long = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n";
    try git.writeFile(io, "moved.txt", long);
    try git.writeFile(io, "edited-move.txt", "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n");
    try git.writeFile(io, "source.txt", "a\nb\nc\nd\ne\nf\ng\nh\n");
    try git.writeFile(io, "gone.txt", "nothing like the others\n");
    try git.writeFile(io, "back.txt", "this path comes back untracked\nwith more\nlines\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });

    try git.exec(io, &.{ "mv", "moved.txt", "z-moved.txt" });
    try git.exec(io, &.{ "mv", "edited-move.txt", "renamed.txt" });
    try git.writeFile(io, "renamed.txt", "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\n");
    try git.writeFile(io, "source.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\n");
    try git.writeFile(io, "copy.txt", "a\nb\nc\nd\ne\nf\ng\nh\n");
    try git.exec(io, &.{ "rm", "-q", "gone.txt" });
    try git.writeFile(io, "fresh.txt", "unrelated\n");
    try git.exec(io, &.{ "mv", "back.txt", "front.txt" });
    try git.writeFile(io, "back.txt", "this path comes back untracked\nwith more\nlines\n");
    try git.exec(io, &.{ "add", "renamed.txt", "source.txt", "copy.txt", "fresh.txt" });
    // Unstaged on top of a staged rename.
    try git.writeFile(io, "z-moved.txt", long ++ "eleven\n");

    for ([_]?[]const u8{ null, "true", "false", "copies", "copy" }) |setting| {
        if (setting) |value| try git.exec(io, &.{ "config", "status.renames", value });
        const want = try theirs(gpa, io, &git);
        defer gpa.free(want);
        const got = try ours(gpa, io, &git);
        defer gpa.free(got);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("status.renames = {s}\n", .{setting orelse "(unset)"});
            return err;
        };
    }
    // diff.renames is read under status.renames, and the limit.
    try git.exec(io, &.{ "config", "--unset", "status.renames" });
    for ([_][2][]const u8{ .{ "diff.renames", "false" }, .{ "diff.renames", "copies" }, .{ "status.renameLimit", "1" } }) |setting| {
        try git.exec(io, &.{ "config", setting[0], setting[1] });
        const want = try theirs(gpa, io, &git);
        defer gpa.free(want);
        const got = try ours(gpa, io, &git);
        defer gpa.free(got);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("{s} = {s}\n", .{ setting[0], setting[1] });
            return err;
        };
    }
}

test "status finds the working tree's renames and copies git status finds: deletions paired with intents to add" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const long = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n";
    const greek = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n";
    const lines = "a\nb\nc\nd\ne\nf\ng\nh\n";
    const crlf_lines = "first line\nsecond line\nthird line\nfourth line\n";
    try git.writeFile(io, ".gitattributes", "*.crlf text\n");
    try git.writeFile(io, "moved.txt", long);
    try git.writeFile(io, "edited-move.txt", greek);
    try git.writeFile(io, "source.txt", lines);
    try git.writeFile(io, "gone.txt", "nothing like the others\n");
    try git.writeFile(io, "keep.txt", "kept\nwith its staged edit\nand more\n");
    try git.writeFile(io, "lines.crlf", crlf_lines);
    try git.writeFile(io, "head.txt", "in HEAD, then an intent to add\nagain\n");
    try git.writeFile(io, "staged.txt", "staged move, then deleted\nand added\n");
    const symlinks = builtin.target.os.tag != .windows;
    if (symlinks) try git.dir.symLink(io, "moved.txt", "old-link", .{});
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });

    // Renamed in the working tree, one exact, one edited.
    try git.dir.rename("moved.txt", git.dir, "z-moved.txt", io);
    try git.writeFile(io, "renamed.txt", greek ++ "iota\n");
    try git.dir.deleteFile(io, "edited-move.txt");
    // A copy of a file modified in the working tree.
    try git.writeFile(io, "source.txt", lines ++ "i\n");
    try git.writeFile(io, "copy.txt", lines);
    // A deletion and an unrelated file.
    try git.dir.deleteFile(io, "gone.txt");
    try git.writeFile(io, "fresh.txt", "unrelated\n");
    // A staged edit under a working tree's rename.
    try git.writeFile(io, "keep.txt", "kept\nwith its staged edit\nand more\nmore\n");
    try git.exec(io, &.{ "add", "keep.txt" });
    try git.dir.rename("keep.txt", git.dir, "kept.txt", io);
    // CRLF in the working tree, LF stored: the same blob once converted.
    try git.dir.deleteFile(io, "lines.crlf");
    try git.writeFile(io, "moved.crlf", "first line\r\nsecond line\r\nthird line\r\nfourth line\r\n");
    // Gone from the index and back as an intent to add.
    try git.exec(io, &.{ "rm", "-q", "--cached", "head.txt" });
    // A staged rename whose destination then moves in the working tree.
    try git.exec(io, &.{ "mv", "staged.txt", "staged-moved.txt" });
    try git.dir.rename("staged-moved.txt", git.dir, "staged-again.txt", io);
    // An intent to add whose file is gone, and an empty one.
    try git.writeFile(io, "vanished.txt", "");
    try git.writeFile(io, "empty.txt", "");
    if (symlinks) {
        try git.dir.deleteFile(io, "old-link");
        try git.dir.symLink(io, "moved.txt", "new-link", .{});
    }
    try git.exec(io, &.{ "add", "-N", "z-moved.txt", "renamed.txt", "copy.txt", "fresh.txt", "kept.txt", "moved.crlf", "head.txt", "staged-again.txt", "vanished.txt", "empty.txt" });
    if (symlinks) try git.exec(io, &.{ "add", "-N", "new-link" });
    try git.dir.deleteFile(io, "vanished.txt");

    for ([_]?[]const u8{ null, "true", "false", "copies" }) |setting| {
        if (setting) |value| try git.exec(io, &.{ "config", "status.renames", value });
        const want = try theirs(gpa, io, &git);
        defer gpa.free(want);
        const got = try ours(gpa, io, &git);
        defer gpa.free(got);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("status.renames = {s}\n", .{setting orelse "(unset)"});
            return err;
        };
    }
    try git.exec(io, &.{ "config", "status.renames", "true" });
    try git.exec(io, &.{ "config", "status.renameLimit", "1" });
    const want = try theirs(gpa, io, &git);
    defer gpa.free(want);
    const got = try ours(gpa, io, &git);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}
