//! Hidden refs against git's own upload-pack and receive-pack, on
//! repositories on this machine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const object = @import("../object.zig");
const repo_mod = @import("../repo.zig");
const transport = @import("../transport.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");

const testing = std.testing;
const Repository = repo_mod.Repository;

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// A repository with refs to hide, hiding them.
fn hidingSource(gpa: Allocator, io: Io) !testgit.Repo {
    var source = try testremote.historyRepo(gpa, io, 3);
    errdefer source.deinit();
    try source.exec(io, &.{ "update-ref", "refs/hidden/a", "HEAD~1" });
    try source.exec(io, &.{ "update-ref", "refs/hidden/shown/b", "HEAD~1" });
    try source.exec(io, &.{ "update-ref", "refs/pull/1/head", "HEAD~2" });
    try source.exec(io, &.{ "config", "--add", "transfer.hideRefs", "refs/hidden/" });
    try source.exec(io, &.{ "config", "--add", "uploadpack.hideRefs", "!refs/hidden/shown" });
    try source.exec(io, &.{ "config", "--add", "uploadpack.hideRefs", "^refs/pull" });
    try source.exec(io, &.{ "config", "--add", "receive.hideRefs", "refs/heads/locked" });
    return source;
}

/// `<oid> <name>` lines, in byte order.
fn sortLines(lines: *std.ArrayList([]u8)) void {
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

test "a repository on this machine lists what git ls-remote lists of it, hidden refs left out" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 30);
    var source = try hidingSource(gpa, io);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();

    for ([_]bool{ false, true }) |v2| {
        const version = if (v2) "protocol.version=2" else "protocol.version=0";
        const out = try here.run(io, &.{ "-c", version, "ls-remote", source_path });
        defer gpa.free(out);
        var theirs: std.ArrayList([]u8) = .empty;
        defer {
            for (theirs.items) |l| gpa.free(l);
            theirs.deinit(gpa);
        }
        var it = std.mem.tokenizeScalar(u8, out, '\n');
        while (it.next()) |line| {
            if (std.mem.endsWith(u8, line, "^{}")) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t').?;
            try theirs.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ line[0..tab], line[tab + 1 ..] }));
        }

        var session = try transport.Session.open(gpa, io, source_path, .upload_pack, null, .{ .protocol_v2 = v2 });
        defer session.close(io);
        var refs = try session.listRefs(gpa, io, &.{});
        defer refs.deinit();
        var ours: std.ArrayList([]u8) = .empty;
        defer {
            for (ours.items) |l| gpa.free(l);
            ours.deinit(gpa);
        }
        for (refs.refs) |ref| {
            if (ref.unborn or std.mem.endsWith(u8, ref.name, "^{}")) continue;
            try ours.append(gpa, try std.fmt.allocPrint(gpa, "{f} {s}", .{ ref.oid, ref.name }));
        }
        sortLines(&theirs);
        sortLines(&ours);
        try testing.expectEqual(theirs.items.len, ours.items.len);
        for (theirs.items, ours.items) |a, b| try testing.expectEqualStrings(a, b);
        var saw_shown = false;
        for (ours.items) |l| {
            try testing.expect(std.mem.indexOf(u8, l, "refs/hidden/a") == null);
            try testing.expect(std.mem.indexOf(u8, l, "refs/pull/") == null);
            if (std.mem.indexOf(u8, l, "refs/hidden/shown/b") != null) saw_shown = true;
        }
        try testing.expect(saw_shown);
    }
}

test "a hidden ref's tip is a v0 want only where git's upload-pack allows a tip" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 30);
    var source = try hidingSource(gpa, io);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const hidden_tip = try source.line(io, &.{ "rev-parse", "refs/pull/1/head" });
    defer gpa.free(hidden_tip);

    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| {
        try twin.exec(io, &.{ "remote", "add", "origin", source_path });
        try twin.exec(io, &.{ "config", "protocol.version", "0" });
    }
    const spec = try std.fmt.allocPrint(gpa, "{s}:refs/heads/got", .{hidden_tip});
    defer gpa.free(spec);

    for ([_]bool{ false, true }) |allow_tip| {
        if (allow_tip) try source.exec(io, &.{ "config", "uploadpack.allowTipSHA1InWant", "true" });
        by_git.report_failures = false;
        const git_ok = if (by_git.exec(io, &.{ "fetch", "-q", "origin", spec })) true else |_| false;
        var repo = try Repository.open(gpa, io, by_relic.dir, .{});
        defer repo.deinit(io);
        const relic_ok = if (fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{spec} })) |outcome| blk: {
            var o = outcome;
            o.deinit();
            break :blk true;
        } else |_| false;
        try testing.expectEqual(allow_tip, git_ok);
        try testing.expectEqual(git_ok, relic_ok);
    }
}

test "a push to a hidden ref is refused as git's receive-pack refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 30);
    var source = try hidingSource(gpa, io);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);

    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    try here.exec(io, &.{ "remote", "add", "origin", source_path });
    try here.exec(io, &.{ "fetch", "-q", "origin" });
    try here.exec(io, &.{ "checkout", "-q", "-b", "work", "origin/main" });

    var said = try here.capture(io, &.{ "push", "--porcelain", "origin", "work:refs/heads/locked" });
    defer said.deinit(gpa);
    try testing.expect(said.code != 0);
    try testing.expect(std.mem.indexOf(u8, said.stdout, "deny updating a hidden ref") != null);

    var repo = try Repository.open(gpa, io, here.dir, .{});
    defer repo.deinit(io);
    var outcome = try push_mod.push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{"work:refs/heads/locked"} });
    defer outcome.deinit();
    try testing.expectEqual(push_mod.RefResult.Status.rejected_by_remote, outcome.refs[0].status);
    try testing.expectEqualStrings("deny updating a hidden ref", outcome.refs[0].message.?);
    // An unhidden ref is pushed.
    var other = try push_mod.push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{"work:refs/heads/open"} });
    defer other.deinit();
    try testing.expectEqual(push_mod.RefResult.Status.ok, other.refs[0].status);
}
