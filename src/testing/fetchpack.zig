//! Negotiation and received-pack integration against Git upload-pack.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const protocol = @import("../wire/protocol.zig");
const connection = @import("../wire/connection.zig");
const Connection = connection.Connection;
const fetchpack = @import("../wire/fetchpack.zig");
const objectwalk = @import("../walk/objectwalk.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("git.zig");
const testremote = @import("remote.zig");

/// A conversation with `git upload-pack` run on this machine, in `dir`.
fn uploadPack(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, v2: bool) !*Connection {
    return connection.Process.start(gpa, io, .{ .environ = env }, .{
        .argv = &.{ "git", "upload-pack", "." },
        .cwd = .{ .dir = dir },
        .set = if (v2) &.{.{ .name = "GIT_PROTOCOL", .value = "version=2" }} else &.{},
    });
}

test "a fetch from git upload-pack negotiates, in v2 and in v0, and brings only what is missing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();

    for ([_]bool{ true, false }) |v2| {
        var source = try testremote.historyRepo(gpa, io, 6);
        defer source.deinit();
        // A v0 server gives only what a ref names.
        try source.exec(io, &.{ "branch", "older", "HEAD~2" });
        const old = try source.line(io, &.{ "rev-parse", "older" });
        defer gpa.free(old);
        const head = try source.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(head);

        var target_git = try testgit.Repo.init(gpa, io, &.{"--bare"});
        defer target_git.deinit();
        var repo = try repo_mod.Repository.open(gpa, io, target_git.dir, .{});
        defer repo.deinit(io);
        var pack_dir = try target_git.dir.openDir(io, "objects/pack", .{ .iterate = true });
        defer pack_dir.close(io);

        // First everything up to `old`, from nothing.
        {
            const conn = try uploadPack(gpa, io, &env, source.dir, v2);
            defer conn.deinit(io);
            var adv = try protocol.readAdvertisement(gpa, conn, repo.objectFormat());
            defer adv.deinit();
            try testing.expectEqual(if (v2) protocol.Version.v2 else protocol.Version.v0, adv.version);
            const want = try Oid.parse(.sha1, old);
            var result = try fetchpack.fetch(gpa, io, conn, &adv, repo.objectDatabase(), .{ .wants = &.{want}, .tips = &.{} }, .{});
            defer result.deinit(io);
            try testing.expect(result.objects > 0);
            try objectwalk.checkConnected(gpa, io, repo.objectDatabase(), &.{want}, null, null);
            try target_git.exec(io, &.{ "update-ref", "refs/heads/main", old });
        }
        // Then the rest, offering what is here: only what is new comes.
        {
            const conn = try uploadPack(gpa, io, &env, source.dir, v2);
            defer conn.deinit(io);
            var adv = try protocol.readAdvertisement(gpa, conn, repo.objectFormat());
            defer adv.deinit();
            var list = try protocol.listRefs(gpa, conn, &adv, .{ .prefixes = &.{ "refs/heads/", "refs/tags/" } });
            defer list.deinit();
            try testing.expect(list.find("refs/heads/main").?.oid.eql(try Oid.parse(.sha1, head)));
            try testing.expect(list.find("refs/tags/v1").?.peeled != null);
            const want = try Oid.parse(.sha1, head);
            var result = try fetchpack.fetch(gpa, io, conn, &adv, repo.objectDatabase(), .{
                .wants = &.{want},
                .tips = &.{try Oid.parse(.sha1, old)},
            }, .{});
            defer result.deinit(io);
            // Two commits, each with a root tree, three subtrees... far
            // fewer than the whole history; and the tag pointing at the
            // head came with them.
            const whole = try source.line(io, &.{ "rev-list", "--objects", "--count", "--all" });
            defer gpa.free(whole);
            try testing.expect(result.objects < try std.fmt.parseInt(u32, whole, 10) / 2);
            const tag_hex = try source.line(io, &.{ "rev-parse", "v1" });
            defer gpa.free(tag_hex);
            try testing.expect(try repo.objectDatabase().exists(io, try Oid.parse(.sha1, tag_hex)));
            try objectwalk.checkConnected(gpa, io, repo.objectDatabase(), &.{want}, null, null);
        }
        try target_git.exec(io, &.{ "update-ref", "refs/heads/main", head });
        try target_git.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

test "the server's refusal comes back by name, with its words" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    var target_git = try testgit.Repo.init(gpa, io, &.{"--bare"});
    defer target_git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, target_git.dir, .{});
    defer repo.deinit(io);
    var pack_dir = try target_git.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const conn = try uploadPack(gpa, io, &env, source.dir, true);
    defer conn.deinit(io);
    var adv = try protocol.readAdvertisement(gpa, conn, repo.objectFormat());
    defer adv.deinit();
    // An object the server does not have.
    const nowhere = hash.Hasher.object(.sha1, "blob", "not on the server");
    try testing.expectError(error.RemoteError, fetchpack.fetch(gpa, io, conn, &adv, repo.objectDatabase(), .{ .wants = &.{nowhere}, .tips = &.{} }, .{}));
    try testing.expect(std.mem.find(u8, conn.message(), "not our ref") != null);
}
