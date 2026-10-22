//! `diff.stat` against git 2.55's `git diff --stat --summary`: the names
//! scaled and renamed, the graph scaled, binary files, the count, colour,
//! and the widths `--stat-width` and `--stat-count` give and
//! `diff.statNameWidth` and `diff.statGraphWidth` set.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const stat = @import("../diff/stat.zig");
const hash = @import("../hash/hash.zig");

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

fn lines(gpa: Allocator, n: usize, word: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.print(gpa, "{s} {d}\n", .{ word, i });
    return out.toOwnedSlice(gpa);
}

fn setup(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    const long_path = "very/long/directory/name/that/goes/on/and/on/file-with-a-long-name.txt";
    const many = try lines(gpa, 40, "line");
    defer gpa.free(many);
    try git.writeFile(io, "short.txt", "one\ntwo\nthree\n");
    try git.writeFile(io, long_path, many);
    try git.writeFile(io, "bin.dat", "a\x00b");
    try git.writeFile(io, "same.dat", "\x00same");
    try git.writeFile(io, "dir/inner/moved.txt", many);
    try git.writeFile(io, "gone.txt", "gone\n");
    try git.writeFile(io, "mode.sh", "echo\n");
    try git.writeFile(io, "naïve-名前.txt", "x\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });

    const more = try lines(gpa, 240, "more");
    defer gpa.free(more);
    try git.writeFile(io, "short.txt", "one\n2\nthree\nfour\n");
    try git.writeFile(io, long_path, more);
    try git.writeFile(io, "bin.dat", "a\x00b, larger");
    try git.writeFile(io, "dir/other/moved.txt", many);
    try git.exec(io, &.{ "rm", "-q", "dir/inner/moved.txt" });
    try git.exec(io, &.{ "rm", "-q", "gone.txt" });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "mode.sh" });
    try git.writeFile(io, "naïve-名前.txt", "y\nz\n");
    try git.writeFile(io, "new.txt", "new\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "two" });
}

test "a diffstat is git diff --stat's at each width the options and diff.statNameWidth and diff.statGraphWidth give" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(gpa, io, &git);

    const Variant = struct {
        width: usize = 80,
        count: ?usize = null,
        name: ?[]const u8 = null,
        graph: ?[]const u8 = null,
        quote_path: bool = true,
        color: bool = false,
    };
    const variants = [_]Variant{
        .{},
        .{ .width = 40 },
        .{ .width = 200 },
        .{ .width = 10 },
        .{ .count = 3 },
        .{ .name = "12" },
        .{ .graph = "7" },
        .{ .name = "20", .graph = "15", .width = 120 },
        .{ .name = "0", .graph = "0" },
        .{ .quote_path = false },
        .{ .color = true },
    };
    for (variants, 0..) |v, i| {
        // The first variant runs with neither set; after it, 0 is git's
        // own default, no limit.
        if (v.name != null or v.graph != null or i > 0) {
            try git.exec(io, &.{ "config", "diff.statNameWidth", v.name orelse "0" });
            try git.exec(io, &.{ "config", "diff.statGraphWidth", v.graph orelse "0" });
        }
        try git.exec(io, &.{ "config", "core.quotePath", if (v.quote_path) "true" else "false" });

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        var width_arg: [32]u8 = undefined;
        var count_arg: [32]u8 = undefined;
        try args.appendSlice(gpa, &.{ "diff", "-M", "--stat", "--summary", try std.mem.print(&width_arg, "--stat-width={d}", .{v.width}) });
        if (v.count) |c| try args.append(gpa, try std.mem.print(&count_arg, "--stat-count={d}", .{c}));
        try args.append(gpa, if (v.color) "--color=always" else "--no-color");
        try args.appendSlice(gpa, &.{ "HEAD~1", "HEAD" });
        const theirs = try git.run(io, args.items);
        defer gpa.free(theirs);

        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        const db = repo.objectDatabase();
        const old = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD~1"));
        const new = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD"));
        var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{ .renames = .{} });
        defer changes.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = try stat.files(a, io, .{ .db = db, .changes = changes.items }, .{});
        const widths = try stat.Widths.configured(repo.configuration(), .{ .width = v.width, .count = v.count });
        const colors: diff.Colors = .{};
        var ours: std.ArrayList(u8) = .empty;
        try stat.write(a, &ours, list, .{ .widths = widths, .quote_path = v.quote_path, .colors = if (v.color) &colors else null });
        try stat.writeSummary(a, &ours, changes.items, v.quote_path);
        std.testing.expectEqualStrings(theirs, ours.items) catch |err| {
            std.debug.print("{any}\n", .{v});
            return err;
        };
    }
}
