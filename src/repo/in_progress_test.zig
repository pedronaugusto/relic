const std = @import("std");
const testgit = @import("../testing/git.zig");
const in_progress = @import("in_progress.zig");
const Repository = @import("repo.zig").Repository;

/// A repository whose `main` and `side` both change `f`, so merging,
/// rebasing or picking one onto the other stops on a conflict.
fn conflicting(gpa: std.mem.Allocator, io: std.Io) !testgit.Repo {
    var r = try testgit.Repo.init(gpa, io, &.{});
    errdefer r.deinit();
    try r.writeFile(io, "f", "base\n");
    try r.exec(io, &.{ "add", "f" });
    try r.exec(io, &.{ "commit", "-q", "-m", "base" });
    try r.exec(io, &.{ "branch", "side" });
    try r.writeFile(io, "f", "ours\n");
    try r.exec(io, &.{ "commit", "-q", "-am", "ours" });
    try r.exec(io, &.{ "checkout", "-q", "side" });
    try r.writeFile(io, "f", "theirs\n");
    try r.exec(io, &.{ "commit", "-q", "-am", "theirs" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    return r;
}

/// What relic reads against the sentence `git status` prints for it.
fn agrees(gpa: std.mem.Allocator, io: std.Io, r: *testgit.Repo, read: in_progress.InProgress) !void {
    var status = try r.capture(io, &.{"status"});
    defer status.deinit(gpa);
    const said = status.stdout;
    const has = struct {
        fn f(text: []const u8, needle: []const u8) bool {
            return std.mem.find(u8, text, needle) != null;
        }
    }.f;
    try std.testing.expectEqual(has(said, "You have unmerged paths") and !read.rebase_merge and !read.rebase and !read.cherry_pick and !read.revert and !read.am, read.merge);
    try std.testing.expectEqual(has(said, "interactive rebase in progress"), read.rebase_merge and read.interactive);
    try std.testing.expectEqual(has(said, "You are currently cherry-picking"), read.cherry_pick);
    try std.testing.expectEqual(has(said, "You are currently reverting"), read.revert);
    try std.testing.expectEqual(has(said, "You are currently bisecting"), read.bisect);
    try std.testing.expectEqual(has(said, "You are in the middle of an am session"), read.am);
    try std.testing.expectEqual(has(said, "You are currently rebasing") and !has(said, "interactive"), read.rebase or (read.rebase_merge and !read.interactive));
}

fn readOf(gpa: std.mem.Allocator, io: std.Io, r: *testgit.Repo) !in_progress.InProgress {
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    return try in_progress.read(io, &repo);
}

test "what is in progress is what git status says: merge, rebase, interactive rebase, am, cherry-pick, revert, bisect" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Case = struct { args: []const []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "merge", "-q", "side" }, .want = "merge" },
        .{ .args = &.{ "rebase", "--merge", "side" }, .want = "rebase_merge" },
        .{ .args = &.{ "rebase", "--apply", "side" }, .want = "rebase" },
        .{ .args = &.{ "cherry-pick", "side" }, .want = "cherry_pick" },
        .{ .args = &.{ "revert", "--no-edit", "HEAD" }, .want = "revert" },
    };
    for (cases) |case| {
        var r = try conflicting(gpa, io);
        defer r.deinit();
        if (std.mem.eql(u8, case.want, "revert")) {
            // Reverting `ours` on top of a commit that changes `f` again.
            try r.writeFile(io, "f", "later\n");
            try r.exec(io, &.{ "commit", "-q", "-am", "later" });
            var stopped = try r.capture(io, &.{ "revert", "--no-edit", "HEAD~1" });
            stopped.deinit(gpa);
        } else {
            var stopped = try r.capture(io, case.args);
            stopped.deinit(gpa);
        }
        const read = try readOf(gpa, io, &r);
        inline for (@typeInfo(in_progress.InProgress).@"struct".field_names) |name| {
            if (!comptime std.mem.eql(u8, name, "interactive")) {
                try std.testing.expectEqual(std.mem.eql(u8, name, case.want), @field(read, name));
            }
        }
        try agrees(gpa, io, &r, read);
    }
    {
        var r = try conflicting(gpa, io);
        defer r.deinit();
        try r.exec(io, &.{ "bisect", "start" });
        const read = try readOf(gpa, io, &r);
        try std.testing.expect(read.bisect and !read.merge);
        try agrees(gpa, io, &r, read);
    }
    {
        var r = try conflicting(gpa, io);
        defer r.deinit();
        const patch = try r.run(io, &.{ "format-patch", "-1", "--stdout", "side" });
        defer gpa.free(patch);
        // `am` stops on the conflict and exits with an error.
        if (r.runInput(io, &.{ "am", "--quiet" }, patch)) |out| gpa.free(out) else |_| {}
        const read = try readOf(gpa, io, &r);
        try std.testing.expect(read.am and !read.rebase);
        try agrees(gpa, io, &r, read);
    }
    {
        var r = try conflicting(gpa, io);
        defer r.deinit();
        const read = try readOf(gpa, io, &r);
        try std.testing.expect(read.none());
    }
}
