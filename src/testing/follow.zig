//! `follow` against git 2.55's `git log --follow --name-status`: the same
//! commits, newest first, each with the change git shows, the file
//! followed through renames, a rename into a directory, a copy when copies
//! are found, a rename on a branch merged later, and a root that created
//! it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const history = @import("history.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const follow = @import("../rev_walk/follow.zig");
const hash = @import("../hash/hash.zig");

const Pair = history.Pair;

fn commitAll(io: Io, repo: *testgit.Repo, subject: []const u8) !void {
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", subject });
}

const body = "one line\ntwo line\nthree line\nfour line\nfive line\nsix line\nseven line\n";

fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, "first.txt", body);
    try repo.writeFile(io, "other", "other\n");
    try commitAll(io, repo, "root");
    try repo.writeFile(io, "first.txt", body ++ "eight line\n");
    try commitAll(io, repo, "grow");
    try repo.exec(io, &.{ "mv", "first.txt", "second.txt" });
    // A twin of the file under a name that sorts first, which would take
    // the rename were the followed path not the only destination.
    try repo.writeFile(io, "a-twin.txt", body ++ "eight line\n");
    try commitAll(io, repo, "rename");
    try repo.writeFile(io, "second.txt", "zero line\n" ++ body ++ "eight line\n");
    try repo.writeFile(io, "other", "other changed\n");
    try commitAll(io, repo, "edit and rename-free");
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try repo.dir.createDirPath(io, "dir");
    try repo.exec(io, &.{ "mv", "second.txt", "dir/third.txt" });
    try commitAll(io, repo, "into a directory");
    try repo.writeFile(io, "dir/third.txt", "zero line\n" ++ body ++ "eight line\nnine line\n");
    try commitAll(io, repo, "side edit");
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "unrelated", "u\n");
    try commitAll(io, repo, "main moves");
    try repo.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });
    // A copy of the file under a new name, and the original changed.
    const now = try repo.readFile(io, "dir/third.txt");
    defer repo.gpa.free(now);
    try repo.writeFile(io, "copy.txt", now);
    try repo.writeFile(io, "dir/third.txt", "changed entirely\nnothing alike\n");
    try commitAll(io, repo, "copy");
}

fn expected(gpa: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == 0) {
            try out.print(gpa, "{s}\n", .{line[1..]});
        } else try out.print(gpa, "{s}\n", .{line});
    }
    return out.toOwnedSlice(gpa);
}

fn actual(gpa: Allocator, result: follow.Result) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    for (result.entries) |e| {
        try out.print(gpa, "{s}\n", .{e.commit.hex(&hex)});
        for (e.changes) |ch| {
            switch (ch.status) {
                .renamed, .copied => try out.print(gpa, "{c}{d:0>3}\t{s}\t{s}\n", .{ ch.letter(), ch.similarity, ch.old.?.path, ch.new.?.path }),
                else => try out.print(gpa, "{c}\t{s}\n", .{ ch.letter(), ch.path() }),
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

test "follow shows the commits git log --follow shows, through renames, a directory, a branch and copies" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    for ([_]?[]const u8{ null, "copies", "false" }) |setting| {
        if (setting) |value| try pair.git.exec(io, &.{ "config", "diff.renames", value });
        for ([_][]const u8{ "copy.txt", "dir/third.txt", "other", "first.txt", "a-twin.txt" }) |path| {
            const raw = try pair.git.run(io, &.{ "log", "--follow", "--format=%x00%H", "--name-status", "--", path });
            defer gpa.free(raw);
            const want = try expected(gpa, raw);
            defer gpa.free(want);
            var repo = try repo_mod.Repository.open(gpa, io, pair.git.dir, .{});
            defer repo.deinit(io);
            const head = try history.oidOf(gpa, io, &pair.git, "HEAD");
            const renames = try diff.RenameSettings.read(repo.configuration());
            var result = try follow.follow(gpa, io, &repo, .{ .include = &.{head}, .path = path }, .{ .renames = renames });
            defer result.deinit();
            const got = try actual(gpa, result);
            defer gpa.free(got);
            std.testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("--follow {s} with diff.renames={s}\n", .{ path, setting orelse "(unset)" });
                return err;
            };
        }
    }
}
