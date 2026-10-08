//! `clean` against `git clean`: two copies of one working tree, git cleans
//! one and this the other, and the lines printed and the files left agree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const clean_mod = @import("clean.zig");
const repo_mod = @import("repo/repo.zig");
const testgit = @import("testing/git.zig");

const Repository = repo_mod.Repository;

fn fixture(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, ".gitignore", "*.o\nbuild/\nignored-dir/\n!keep.o\n");
    try git.writeFile(io, "README", "readme\n");
    try git.writeFile(io, "src/main.c", "int main;\n");
    try git.writeFile(io, "build/keep", "tracked under an ignored directory\n");
    try git.exec(io, &.{ "add", "-f", ".gitignore", "README", "src/main.c", "build/keep" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });

    try git.writeFile(io, "new.txt", "untracked\n");
    try git.writeFile(io, "sp ace.txt", "untracked\n");
    try git.writeFile(io, "h\xc3\xa9llo.txt", "quoted when core.quotePath is on\n");
    try git.writeFile(io, "src/new.c", "untracked\n");
    try git.writeFile(io, "src/obj.o", "ignored\n");
    try git.writeFile(io, "keep.o", "negated, so untracked\n");
    try git.writeFile(io, "untracked-dir/a.txt", "a\n");
    try git.writeFile(io, "untracked-dir/deep/b.txt", "b\n");
    try git.writeFile(io, "mixed-dir/a.txt", "untracked beside an ignored file\n");
    try git.writeFile(io, "mixed-dir/x.o", "ignored\n");
    try git.writeFile(io, "only-ignored/x.o", "ignored\n");
    try git.writeFile(io, "only-ignored/sub/y.o", "ignored\n");
    try git.writeFile(io, "ignored-dir/stuff.txt", "in an ignored directory\n");
    try git.writeFile(io, "build/out.bin", "under an ignored directory with a tracked file\n");
    try git.writeFile(io, "logs/.gitignore", "*.log\n");
    try git.writeFile(io, "logs/a.log", "ignored by its own directory's file\n");
    try git.writeFile(io, "logs/b.txt", "untracked\n");
    try git.dir.createDirPath(io, "empty-dir/inner");
    try git.writeFile(io, "nest/f", "in a repository of its own\n");
    try git.exec(io, &.{ "init", "-q", "nest" });
    try git.writeFile(io, "holder/loose.txt", "beside a repository\n");
    try git.writeFile(io, "holder/inner/f", "in a repository inside an untracked directory\n");
    try git.exec(io, &.{ "init", "-q", "holder/inner" });
    if (builtin.target.os.tag != .windows) try git.dir.symLink(io, "README", "link", .{});
}

/// Every path under `dir`, directories with a trailing `/`, sorted. A
/// repository's `.git` is listed and not entered.
fn listTree(gpa: Allocator, io: Io, dir: Io.Dir) ![]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, ".git")) {
            if (!std.mem.eql(u8, entry.path, ".git")) try out.append(gpa, try gpa.print("{s}/", .{entry.path}));
            continue;
        }
        if (entry.kind == .directory) {
            try out.append(gpa, try gpa.print("{s}/", .{entry.path}));
            try walker.enter(io, entry);
        } else try out.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    for (out.items) |p| {
        try joined.appendSlice(gpa, p);
        try joined.append(gpa, '\n');
    }
    return joined.toOwnedSlice(gpa);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The lines of `text`, sorted: git prints a directory's entries in the
/// filesystem's order and this in name order.
fn sortedLines(gpa: Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len > 0) try lines.append(gpa, l);
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    for (lines.items) |l| {
        try joined.appendSlice(gpa, l);
        try joined.append(gpa, '\n');
    }
    return joined.toOwnedSlice(gpa);
}

/// Clean one copy with git and the other with `options`, and compare.
fn compare(gpa: Allocator, io: Io, args: []const []const u8, options: clean_mod.Options) !void {
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    try fixture(io, &theirs);
    var mine = try testgit.Repo.init(gpa, io, &.{});
    defer mine.deinit();
    try fixture(io, &mine);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "clean");
    try argv.appendSlice(gpa, args);
    const git_out = try theirs.run(io, argv.items);
    defer gpa.free(git_out);

    var repo = try Repository.open(gpa, io, mine.dir, .{});
    defer repo.deinit(io);
    var printed: Io.Writer.Allocating = .init(gpa);
    defer printed.deinit();
    const quiet = for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q")) break true;
    } else false;
    var opts = options;
    if (!quiet) opts.out = &printed.writer;
    var outcome = try clean_mod.clean(gpa, io, &repo, opts);
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 0), outcome.failures.len);
    if (!quiet) try std.testing.expectEqual(std.mem.count(u8, printed.written(), "\n"), outcome.reports.len);

    const a = try sortedLines(gpa, git_out);
    defer gpa.free(a);
    const b = try sortedLines(gpa, printed.written());
    defer gpa.free(b);
    std.testing.expectEqualStrings(a, b) catch |err| {
        std.debug.print("git clean {any}\n", .{args});
        return err;
    };
    const left_a = try listTree(gpa, io, theirs.dir);
    defer gpa.free(left_a);
    const left_b = try listTree(gpa, io, mine.dir);
    defer gpa.free(left_b);
    try std.testing.expectEqualStrings(left_a, left_b);
}

test "clean removes what git clean removes, and prints what it prints, for files, directories and ignored paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try compare(gpa, io, &.{"-n"}, .{ .dry_run = true });
    try compare(gpa, io, &.{"-f"}, .{ .force = .yes });
    try compare(gpa, io, &.{ "-n", "-d" }, .{ .dry_run = true, .directories = true });
    try compare(gpa, io, &.{ "-f", "-d" }, .{ .force = .yes, .directories = true });
    try compare(gpa, io, &.{ "-f", "-x" }, .{ .force = .yes, .ignored = .too });
    try compare(gpa, io, &.{ "-f", "-d", "-x" }, .{ .force = .yes, .directories = true, .ignored = .too });
    try compare(gpa, io, &.{ "-f", "-X" }, .{ .force = .yes, .ignored = .only });
    try compare(gpa, io, &.{ "-f", "-d", "-X" }, .{ .force = .yes, .directories = true, .ignored = .only });
    try compare(gpa, io, &.{ "-q", "-f", "-d" }, .{ .force = .yes, .directories = true });
}

test "clean leaves a repository inside the working tree unless forced twice, and takes -e patterns above every ignore file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try compare(gpa, io, &.{ "-ff", "-d" }, .{ .force = .nested_repositories, .directories = true });
    try compare(gpa, io, &.{ "-n", "-ff", "-d", "-x" }, .{ .dry_run = true, .force = .nested_repositories, .directories = true, .ignored = .too });
    try compare(gpa, io, &.{ "-f", "-d", "-e", "*.txt" }, .{ .force = .yes, .directories = true, .excludes = &.{"*.txt"} });
    try compare(gpa, io, &.{ "-f", "-d", "-e", "!*.o" }, .{ .force = .yes, .directories = true, .excludes = &.{"!*.o"} });
    try compare(gpa, io, &.{ "-f", "-x", "-e", "new.txt" }, .{ .force = .yes, .ignored = .too, .excludes = &.{"new.txt"} });
    try compare(gpa, io, &.{ "-f", "-X", "-e", "*.txt" }, .{ .force = .yes, .ignored = .only, .excludes = &.{"*.txt"} });
}

test "clean with pathspecs takes only what they name, directories included" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try compare(gpa, io, &.{ "-f", "--", "src" }, .{ .force = .yes, .pathspecs = &.{"src"} });
    try compare(gpa, io, &.{ "-f", "--", "untracked-dir/deep" }, .{ .force = .yes, .pathspecs = &.{"untracked-dir/deep"} });
    try compare(gpa, io, &.{ "-f", "-x", "--", "*.o" }, .{ .force = .yes, .ignored = .too, .pathspecs = &.{"*.o"} });
    try compare(gpa, io, &.{ "-n", "--", "holder/inner" }, .{ .dry_run = true, .pathspecs = &.{"holder/inner"} });
    try compare(gpa, io, &.{ "-n", "--", ":!src", "." }, .{ .dry_run = true, .pathspecs = &.{ ":!src", "." } });
    try compare(gpa, io, &.{ "-n", "-x", "--", "build/" }, .{ .dry_run = true, .ignored = .too, .pathspecs = &.{"build/"} });
}

test "clean refuses without force as git does, and names a bare repository" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var refused = try git.capture(io, &.{"clean"});
    defer refused.deinit(gpa);
    try std.testing.expect(refused.code != 0);
    try std.testing.expect(std.mem.find(u8, refused.stderr, "refusing to clean") != null);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectError(error.ForceRequired, clean_mod.clean(gpa, io, &repo, .{}));

    try git.exec(io, &.{ "config", "clean.requireForce", "false" });
    var again = try Repository.open(gpa, io, git.dir, .{});
    defer again.deinit(io);
    var outcome = try clean_mod.clean(gpa, io, &again, .{});
    defer outcome.deinit();
    try std.testing.expect(outcome.reports.len > 0);
}

test "clean leaves a directory whose .git file cannot be read, as git takes it for a repository" {
    // A mode that refuses reading is POSIX's, and refuses no one as root.
    if (builtin.target.os.tag == .windows or std.c.getuid() == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var outs: [2][]const u8 = undefined;
    var trees: [2][]const u8 = undefined;
    for (0..2) |side| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try git.writeFile(io, "tracked", "t\n");
        try git.exec(io, &.{ "add", "tracked" });
        try git.exec(io, &.{ "commit", "-q", "-m", "one" });
        try git.writeFile(io, "nested/work.txt", "someone's work\n");
        try git.writeFile(io, "nested/.git", "gitdir: ../.git/modules/nested\n");
        try git.dir.setFilePermissions(io, "nested/.git", @fromBackingInt(@intCast(@as(std.posix.mode_t, 0))), .{});
        defer git.dir.setFilePermissions(io, "nested/.git", @fromBackingInt(@intCast(@as(std.posix.mode_t, 0o644))), .{}) catch {};
        if (side == 0) {
            outs[side] = try git.run(io, &.{ "clean", "-f", "-d" });
        } else {
            var repo = try Repository.open(gpa, io, git.dir, .{});
            defer repo.deinit(io);
            var printed: Io.Writer.Allocating = .init(gpa);
            defer printed.deinit();
            var outcome = try clean_mod.clean(gpa, io, &repo, .{ .force = .yes, .directories = true, .out = &printed.writer });
            outcome.deinit();
            outs[side] = try gpa.dupe(u8, printed.written());
        }
        trees[side] = try listTree(gpa, io, git.dir);
    }
    defer for (outs ++ trees) |text| gpa.free(text);
    try std.testing.expectEqualStrings(outs[0], outs[1]);
    try std.testing.expectEqualStrings(trees[0], trees[1]);
    try std.testing.expect(std.mem.find(u8, trees[1], "nested/work.txt") != null);
}
