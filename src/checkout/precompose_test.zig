//! `core.precomposeUnicode` against git: names spelled decomposed on the
//! disk are read under the names git reads, in the working tree and the
//! loose refs. git composes on macOS alone, and so does this; elsewhere both
//! read the names as the disk spells them, which the same comparisons check.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const checkout = @import("checkout.zig");
const clean_mod = @import("../clean.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;

/// Decomposed spellings: composed whole, composed pairwise and no further,
/// and one iconv refuses for a character outside the Basic Multilingual
/// Plane, which git keeps as it is.
const names = [_][]const u8{
    "cafe\u{301}.txt",
    "o\u{308}d/u\u{308}.txt",
    "a\u{302}\u{323}.txt",
    "e\u{301}\u{1f600}.txt",
    "\u{212b}.txt",
};

fn fixture(io: Io, git: *testgit.Repo) !void {
    try git.exec(io, &.{ "config", "core.precomposeunicode", "true" });
    try git.exec(io, &.{ "config", "core.quotepath", "false" });
    try git.writeFile(io, "README", "readme\n");
    try git.exec(io, &.{ "add", "README" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
    for (names) |name| try git.writeFile(io, name, "x\n");
}

/// The lines of `text`, sorted.
fn sortedLines(gpa: Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len > 0) try lines.append(gpa, l);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    for (lines.items) |l| {
        try joined.appendSlice(gpa, l);
        try joined.append(gpa, '\n');
    }
    return joined.toOwnedSlice(gpa);
}

test "untracked names, the names added and clean's names are git's under core.precomposeUnicode" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);

    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);

    // status: the untracked files
    {
        const theirs = try git.run(io, &.{ "ls-files", "-o", "--exclude-standard" });
        defer gpa.free(theirs);
        var locked = try repo.lockIndex(io);
        defer locked.deinit(io);
        var result = try checkout.status(gpa, io, repo.workDirectory().?.get(), .{ .index = &locked.index, .db = repo.objectDatabase() }, .{
            .rules = try repo.worktreeRules(),
            .untracked = .all,
        });
        defer result.deinit();
        var mine: std.ArrayList(u8) = .empty;
        defer mine.deinit(gpa);
        for (result.entries) |e| if (e.unstaged == .untracked) {
            try mine.appendSlice(gpa, e.path);
            try mine.append(gpa, '\n');
        };
        const a = try sortedLines(gpa, theirs);
        defer gpa.free(a);
        const b = try sortedLines(gpa, mine.items);
        defer gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }

    // clean: what it would remove, by name
    {
        const theirs = try git.run(io, &.{ "clean", "-n", "-d" });
        defer gpa.free(theirs);
        var printed: Io.Writer.Allocating = .init(gpa);
        defer printed.deinit();
        var outcome = try clean_mod.clean(gpa, io, &repo, .{ .dry_run = true, .directories = true, .out = &printed.writer });
        defer outcome.deinit();
        const a = try sortedLines(gpa, theirs);
        defer gpa.free(a);
        const b = try sortedLines(gpa, printed.written());
        defer gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }

    // add: the index's names, after git's add in a copy of the same tree
    {
        var other = try testgit.Repo.init(gpa, io, &.{});
        defer other.deinit();
        try fixture(io, &other);
        try other.exec(io, &.{ "add", "-A" });
        const theirs = try other.run(io, &.{"ls-files"});
        defer gpa.free(theirs);

        var index = try repo.openIndex(io);
        defer index.deinit();
        _ = try checkout.addAll(gpa, io, repo.workDirectory().?.get(), .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = try repo.worktreeRules() });
        var mine: std.ArrayList(u8) = .empty;
        defer mine.deinit(gpa);
        for (index.items()) |e| {
            try mine.appendSlice(gpa, e.path);
            try mine.append(gpa, '\n');
        }
        const a = try sortedLines(gpa, theirs);
        defer gpa.free(a);
        const b = try sortedLines(gpa, mine.items);
        defer gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }
}

test "a loose ref spelled decomposed is listed and verified under git's name for it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const contents = try std.mem.concat(gpa, u8, &.{ head, "\n" });
    defer gpa.free(contents);
    try git.writeFile(io, ".git/refs/heads/cafe\u{301}", contents);
    try git.writeFile(io, ".git/refs/heads/o\u{308}/u\u{308}", contents);

    const theirs = try git.run(io, &.{ "for-each-ref", "--format=%(refname)" });
    defer gpa.free(theirs);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var listing = try repo.refStore().list(gpa, io, "refs/");
    defer listing.deinit();
    var mine: std.ArrayList(u8) = .empty;
    defer mine.deinit(gpa);
    for (listing.entries) |e| {
        try mine.appendSlice(gpa, e.name);
        try mine.append(gpa, '\n');
    }
    const a = try sortedLines(gpa, theirs);
    defer gpa.free(a);
    const b = try sortedLines(gpa, mine.items);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}
