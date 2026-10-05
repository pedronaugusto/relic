//! The `promisor-remote` capability against git's own upload-pack and
//! fetch, on repositories on this machine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const object = @import("../object.zig");
const repo_mod = @import("../repo.zig");
const local = @import("local.zig");
const uploadpack = @import("uploadpack.zig");
const pktline = @import("pktline.zig");
const fetch_mod = @import("fetch.zig");
const clone_mod = @import("clone.zig");
const warning = @import("../repo/warning.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");

const testing = std.testing;
const Repository = repo_mod.Repository;

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// The `promisor-remote=` line of a v2 advertisement, or `null`.
fn promisorLine(gpa: Allocator, advertisement: []const u8) !?[]u8 {
    var fixed: Io.Reader = .fixed(advertisement);
    var buffer: [pktline.max_line]u8 = undefined;
    var in = fixed.limited(.unlimited, &buffer);
    while (true) {
        const packet = pktline.read(&in.interface) catch return null;
        switch (packet) {
            .data => |raw| {
                const line = std.mem.trimEnd(u8, raw, "\n");
                if (std.mem.startsWith(u8, line, "promisor-remote=")) return try gpa.dupe(u8, line);
            },
            .flush => return null,
            else => {},
        }
    }
}

/// A repository that borrows from a promisor remote and says so.
fn advertisingServer(gpa: Allocator, io: Io) !testgit.Repo {
    var server = try testremote.historyRepo(gpa, io, 2);
    errdefer server.deinit();
    for ([_][]const []const u8{
        &.{ "config", "promisor.advertise", "true" },
        &.{ "config", "promisor.sendFields", "partialCloneFilter, token" },
        &.{ "config", "remote.lop.url", "https://example.com/large;objects" },
        &.{ "config", "remote.lop.promisor", "true" },
        &.{ "config", "remote.lop.partialCloneFilter", "blob:limit=8k" },
        &.{ "config", "remote.lop.token", "a b,c" },
    }) |args| try server.exec(io, args);
    return server;
}

test "a served repository advertises its promisor remotes as git's upload-pack does" {
    const gpa = testing.allocator;
    const io = testing.io;
    // The fields came with 2.52.
    try testgit.requireGitVersion(gpa, io, 2, 52);
    var server = try advertisingServer(gpa, io);
    defer server.deinit();
    const path = try testremote.absolutePath(gpa, io, server.dir);
    defer gpa.free(path);

    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_PROTOCOL", "version=2");
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "upload-pack", "--advertise-refs", path },
        .cwd = .{ .dir = server.dir },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const theirs = (try promisorLine(gpa, result.stdout)).?;
    defer gpa.free(theirs);

    var remote = try local.Remote.open(gpa, io, path);
    defer remote.deinit(io);
    var s: uploadpack.Server = .init(gpa, io, &remote, .v2, false, .{});
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try s.advertise(&out.writer);
    const ours = (try promisorLine(gpa, out.written())).?;
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);

    // A client that names one in its request is taken to have it.
    var request: Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    try pktline.write(&request.writer, "command=ls-refs\n");
    try pktline.write(&request.writer, "promisor-remote=lop\n");
    try pktline.delim(&request.writer);
    try pktline.flush(&request.writer);
    var fixed: Io.Reader = .fixed(request.written());
    var buffer: [pktline.max_line]u8 = undefined;
    var in = fixed.limited(.unlimited, &buffer);
    var answer: Io.Writer.Allocating = .init(gpa);
    defer answer.deinit();
    try s.serveRequest(&in.interface, &answer.writer);
    try testing.expect(s.promisor_taken);
}

test "a fetch takes and stores what a server advertises as git fetch does" {
    const gpa = testing.allocator;
    const io = testing.io;
    // `promisor.storeFields` came with 2.55.
    try testgit.requireGitVersion(gpa, io, 2, 55);
    var server = try advertisingServer(gpa, io);
    defer server.deinit();
    const path = try testremote.absolutePath(gpa, io, server.dir);
    defer gpa.free(path);

    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| {
        for ([_][]const []const u8{
            &.{ "remote", "add", "origin", path },
            &.{ "config", "protocol.version", "2" },
            &.{ "config", "promisor.acceptFromServer", "KnownUrl" },
            &.{ "config", "promisor.storeFields", "partialCloneFilter,token" },
            &.{ "config", "remote.lop.url", "https://example.com/large;objects" },
            &.{ "config", "remote.lop.promisor", "true" },
            &.{ "config", "remote.lop.partialCloneFilter", "blob:none" },
        }) |args| try twin.exec(io, args);
    }
    try by_git.exec(io, &.{ "fetch", "-q", "origin" });
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    {
        var repo = try Repository.open(gpa, io, by_relic.dir, .{});
        defer repo.deinit(io);
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .warnings = &warnings });
        outcome.deinit();
    }
    for ([_][]const u8{ "remote.lop.partialclonefilter", "remote.lop.token" }) |key| {
        const theirs = try by_git.line(io, &.{ "config", key });
        defer gpa.free(theirs);
        const ours = try by_relic.line(io, &.{ "config", key });
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    var stored: usize = 0;
    for (warnings.items.items) |w| {
        if (w == .promisor_stored) stored += 1;
    }
    try testing.expectEqual(@as(usize, 2), stored);
}

test "a clone with the filter auto takes it from the promisor remotes taken, as git clone does" {
    const gpa = testing.allocator;
    const io = testing.io;
    // The filter `auto` came with 2.54.
    try testgit.requireGitVersion(gpa, io, 2, 54);
    var server = try testremote.historyRepo(gpa, io, 3);
    defer server.deinit();
    const path = try testremote.absolutePath(gpa, io, server.dir);
    defer gpa.free(path);
    const url = try std.fmt.allocPrint(gpa, "file://{s}", .{path});
    defer gpa.free(url);
    // The promisor remote is the served repository itself, so that what
    // the checkout lacks is fetched from it and not from the network. An
    // advertised `blob:none` makes git 2.55 stop on a BUG; a limit does not.
    for ([_][]const []const u8{
        &.{ "config", "uploadpack.allowFilter", "true" },
        &.{ "config", "promisor.advertise", "true" },
        &.{ "config", "promisor.sendFields", "partialCloneFilter" },
        &.{ "config", "remote.lop.url", url },
        &.{ "config", "remote.lop.promisor", "true" },
        &.{ "config", "remote.lop.partialCloneFilter", "blob:limit=1" },
    }) |args| try server.exec(io, args);

    var ws = try testgit.Repo.init(gpa, io, &.{});
    defer ws.deinit();
    const lop_url = try std.fmt.allocPrint(gpa, "remote.lop.url={s}", .{url});
    defer gpa.free(lop_url);
    try ws.exec(io, &.{ "-c", "protocol.version=2", "-c", "promisor.acceptFromServer=All", "-c", lop_url, "-c", "remote.lop.promisor=true", "clone", "-q", "--filter=auto", url, "by-git" });

    try ws.dir.createDirPath(io, "by-relic");
    var b = try ws.dir.openDir(io, "by-relic", .{});
    defer b.close(io);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var repo = try clone_mod.clone(gpa, io, url, b, .{ .who = test_who, .filter = "auto", .user_config = .{ .command = &.{ "protocol.version=2", "promisor.acceptFromServer=All", lop_url, "remote.lop.promisor=true" } }, .programs = .{ .environ = &env } });
    repo.deinit(io);

    for ([_][]const []const u8{
        &.{ "config", "remote.origin.promisor" },
        &.{ "config", "remote.origin.partialclonefilter" },
        &.{ "config", "remote.lop.partialclonefilter" },
        &.{ "rev-list", "--objects", "--all", "--missing=print" },
    }) |args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "-C", "by-git" });
        try argv.appendSlice(gpa, args);
        const theirs = try ws.run(io, argv.items);
        defer gpa.free(theirs);
        argv.items[1] = "by-relic";
        const ours = try ws.run(io, argv.items);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
}
