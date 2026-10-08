//! Object-walk integration against repositories produced by Git.
const std = @import("std");
const testing = std.testing;
const Oid = @import("../hash/hash.zig").Oid;
const objectwalk = @import("../walk/objectwalk.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("git.zig");

test "what is missing is what git rev-list --objects lists" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..6) |i| {
        var buf: [64]u8 = undefined;
        try repo.writeFile(io, "a.txt", try std.mem.print(&buf, "version {d}\n", .{i}));
        try repo.writeFile(io, "dir/same.txt", "never changes\n");
        var name_buf: [64]u8 = undefined;
        try repo.writeFile(io, try std.mem.print(&name_buf, "dir/n{d}.txt", .{i % 3}), try std.mem.print(&buf, "n {d}\n", .{i}));
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&buf, "c{d}", .{i}) });
        if (i == 1) try repo.exec(io, &.{ "branch", "side" });
    }
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.writeFile(io, "side.txt", "on the side\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "side" });
    try repo.exec(io, &.{ "tag", "-a", "t", "-m", "tag on side" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });

    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    const Case = struct { include: []const []const u8, exclude: []const []const u8 };
    const cases = [_]Case{
        .{ .include = &.{"main"}, .exclude = &.{} },
        .{ .include = &.{"main"}, .exclude = &.{"main~3"} },
        .{ .include = &.{ "main", "t" }, .exclude = &.{"side~1"} },
        .{ .include = &.{"t"}, .exclude = &.{"main"} },
        .{ .include = &.{"main"}, .exclude = &.{"main"} },
    };
    for (cases) |case| {
        var include: std.ArrayList(Oid) = .empty;
        defer include.deinit(gpa);
        var exclude: std.ArrayList(Oid) = .empty;
        defer exclude.deinit(gpa);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |o| gpa.free(o);
            owned.deinit(gpa);
        }
        try argv.appendSlice(gpa, &.{ "rev-list", "--objects" });
        for (case.include) |name| {
            const hex = try repo.line(io, &.{ "rev-parse", name });
            try owned.append(gpa, hex);
            try include.append(gpa, try Oid.parse(.sha1, hex));
            try argv.append(gpa, hex);
        }
        for (case.exclude) |name| {
            const hex = try repo.line(io, &.{ "rev-parse", name });
            try owned.append(gpa, hex);
            try exclude.append(gpa, try Oid.parse(.sha1, hex));
            const not = try gpa.print("^{s}", .{hex});
            try owned.append(gpa, not);
            try argv.append(gpa, not);
        }
        const listed = try repo.run(io, argv.items);
        defer gpa.free(listed);
        var theirs: Oid.Set = .empty;
        defer theirs.deinit(gpa);
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        while (lines.next()) |line| try theirs.put(gpa, try Oid.parse(.sha1, line[0..40]), {});

        var ours = try objectwalk.missing(gpa, io, opened.objectDatabase(), include.items, exclude.items);
        defer ours.deinit();
        try testing.expectEqual(theirs.count(), ours.entries.len);
        for (ours.entries) |entry| try testing.expect(theirs.contains(entry.oid));
    }
}

test "a tip with an object missing below it is refused, and names the object" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    const head_hex = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_hex);
    const blob_hex = try repo.line(io, &.{ "rev-parse", "HEAD:a.txt" });
    defer gpa.free(blob_hex);

    var opened = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer opened.deinit(io);
    const head = try Oid.parse(.sha1, head_hex);
    try objectwalk.checkConnected(gpa, io, opened.objectDatabase(), &.{head}, null, null);

    const path = try gpa.print(".git/objects/{s}/{s}", .{ blob_hex[0..2], blob_hex[2..] });
    defer gpa.free(path);
    try repo.dir.deleteFile(io, path);
    var gone: Oid = undefined;
    try testing.expectError(error.MissingObject, objectwalk.checkConnected(gpa, io, opened.objectDatabase(), &.{head}, null, &gone));
    try testing.expect(gone.eql(try Oid.parse(.sha1, blob_hex)));
}
