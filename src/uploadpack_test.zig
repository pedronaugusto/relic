//! relic's upload-pack held to git's: real git clones and fetches from it —
//! handed it as `--upload-pack` — and what it ends with is compared with
//! what it ends with from its own upload-pack, full, shallow by depth, date
//! and ref, deepened and unshallowed, and filtered, in protocol v2 and v0;
//! and relic fetches from it in process for a `file://` remote.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const warning = @import("warning.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const helper = @import("build_options").upload_pack_helper_path;
const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// Eight commits a day apart on `main`, a branch, a lightweight and an
/// annotated tag, a file large enough for `blob:limit`, and filters
/// allowed: `<root>/repo.git`.
fn served(gpa: Allocator, io: Io, root: Io.Dir) ![]u8 {
    const root_path = try testremote.absolutePath(gpa, io, root);
    defer gpa.free(root_path);
    const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
    errdefer gpa.free(bare);
    var maker = try testgit.Repo.init(gpa, io, &.{});
    defer maker.deinit();
    try maker.exec(io, &.{ "init", "-q", "--bare", "-b", "main", bare });
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const day = 86400;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..300) |i| try big.print(gpa, "a line of a file larger than a kilobyte, {d}\n", .{i});
    for (1..9) |mark| {
        try stream.print(gpa, "commit refs/heads/main\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 2\n{d}\n", .{ mark, 1_600_000_000 + mark * day, mark });
        if (mark > 1) try stream.print(gpa, "from :{d}\n", .{mark - 1});
        try stream.print(gpa, "M 100644 inline file\ndata 2\n{d}\n", .{mark});
        try stream.print(gpa, "M 100644 inline dir/deep/note\ndata 2\n{d}\n", .{mark});
        if (mark == 3) try stream.print(gpa, "M 100644 inline big\ndata {d}\n{s}\n", .{ big.items.len, big.items });
        try stream.appendSlice(gpa, "\n");
    }
    try stream.print(gpa, "commit refs/heads/side\nmark :20\ncommitter C <c@example.com> {d} +0000\ndata 5\nside\nfrom :4\nM 100644 inline side\ndata 5\nside\n\n", .{1_600_000_000 + 20 * day});
    try stream.appendSlice(gpa, "reset refs/tags/light\nfrom :2\n\n");
    try stream.print(gpa, "tag v6\nfrom :6\ntagger T <t@example.com> {d} +0000\ndata 3\nv6\n\n", .{1_600_000_000 + 30 * day});
    try stream.appendSlice(gpa, "done\n");
    var dir = try Io.Dir.cwd().openDir(io, bare, .{});
    defer dir.close(io);
    const out = try testremote.gitInput(gpa, io, dir, &.{ "fast-import", "--quiet", "--done" }, stream.items);
    gpa.free(out);
    try maker.exec(io, &.{ "--git-dir", bare, "config", "uploadpack.allowFilter", "true" });
    return bare;
}

fn git(gpa: Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map, args: []const []const u8) ![]u8 {
    return testremote.gitInputEnv(gpa, io, dir, env, args, "", true);
}

/// What two clones are compared on: every ref, the boundary, every object
/// git can find and every one it is promised, and git's own check.
fn expectSame(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, a: Io.Dir, b: Io.Dir) !void {
    for ([_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname) %(symref)" },
        &.{ "rev-list", "--objects", "--missing=print", "--all" },
        &.{ "rev-parse", "--is-shallow-repository" },
    }) |args| {
        const theirs = try git(gpa, io, a, env, args);
        defer gpa.free(theirs);
        const ours = try git(gpa, io, b, env, args);
        defer gpa.free(ours);
        const sorted_theirs = try sortLines(gpa, theirs);
        defer gpa.free(sorted_theirs);
        const sorted_ours = try sortLines(gpa, ours);
        defer gpa.free(sorted_ours);
        try testing.expectEqualStrings(sorted_theirs, sorted_ours);
    }
    for ([_][]const u8{ ".git/shallow", "shallow" }) |name| {
        const theirs = a.readFileAlloc(io, name, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer gpa.free(theirs);
        const ours = try b.readFileAlloc(io, name, gpa, .unlimited);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    const checked = try git(gpa, io, b, env, &.{ "fsck", "--no-dangling" });
    gpa.free(checked);
}

fn sortLines(gpa: Allocator, text: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(gpa, line);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return std.mem.join(gpa, "\n", lines.items);
}

test "git clones from relic's upload-pack what it clones from its own, in v2 and v0, whole, shallow and filtered" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    const day = 86400;
    var since_buf: [64]u8 = undefined;
    const since = try std.fmt.bufPrint(&since_buf, "--shallow-since={d}", .{1_600_000_000 + 5 * day + 1});
    const cases = [_][]const []const u8{
        &.{},
        &.{"--depth=1"},
        &.{"--depth=3"},
        &.{ "--depth=2", "--no-single-branch" },
        &.{since},
        &.{"--shallow-exclude=light"},
        &.{"--filter=blob:none"},
        &.{"--filter=blob:limit=1k"},
        &.{"--filter=tree:1"},
        &.{ "--filter=blob:none", "--depth=2" },
    };
    for ([_][]const u8{ "2", "0" }) |version| for (cases) |extra| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        for ([_]?[]const u8{ null, helper }, [_][]const u8{ "by-git", "by-relic" }) |upload_pack, name| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            const version_setting = try std.fmt.allocPrint(gpa, "protocol.version={s}", .{version});
            defer gpa.free(version_setting);
            try args.appendSlice(gpa, &.{ "-c", version_setting, "clone", "-q", "--no-checkout" });
            if (upload_pack) |p| try args.appendSlice(gpa, &.{ "--upload-pack", p });
            try args.appendSlice(gpa, extra);
            try args.appendSlice(gpa, &.{ url, name });
            const out = try git(gpa, io, tmp.dir, &env, args.items);
            gpa.free(out);
        }
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        var b = try tmp.dir.openDir(io, "by-relic", .{});
        defer b.close(io);
        try expectSame(gpa, io, &env, a, b);
    };
}

test "git deepens, unshallows and fetches again from relic's upload-pack as from its own" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    for ([_][]const u8{ "2", "0" }) |version| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const version_setting = try std.fmt.allocPrint(gpa, "protocol.version={s}", .{version});
        defer gpa.free(version_setting);
        for ([_]?[]const u8{ null, helper }, [_][]const u8{ "by-git", "by-relic" }) |upload_pack, name| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.appendSlice(gpa, &.{ "-c", version_setting, "clone", "-q", "--depth=1" });
            if (upload_pack) |p| try args.appendSlice(gpa, &.{ "--upload-pack", p });
            try args.appendSlice(gpa, &.{ url, name });
            const out = try git(gpa, io, tmp.dir, &env, args.items);
            gpa.free(out);
        }
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        var b = try tmp.dir.openDir(io, "by-relic", .{});
        defer b.close(io);
        for ([_][]const []const u8{ &.{"--deepen=2"}, &.{"--depth=4"}, &.{"--unshallow"}, &.{} }) |step| {
            for ([_]Io.Dir{ a, b }, [_]bool{ false, true }) |dir, relic_server| {
                var args: std.ArrayList([]const u8) = .empty;
                defer args.deinit(gpa);
                try args.appendSlice(gpa, &.{ "-c", version_setting });
                const setting = try std.fmt.allocPrint(gpa, "remote.origin.uploadpack={s}", .{helper});
                defer gpa.free(setting);
                if (relic_server) try args.appendSlice(gpa, &.{ "-c", setting });
                try args.appendSlice(gpa, &.{ "fetch", "-q" });
                try args.appendSlice(gpa, step);
                try args.append(gpa, "origin");
                const out = try git(gpa, io, dir, &env, args.items);
                gpa.free(out);
            }
            try expectSame(gpa, io, &env, a, b);
        }
    }
}

test "relic clones and fetches over file:// through its own upload-pack, and ignores a depth for a path as git does" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    const Case = struct { git_args: []const []const u8, options: clone_mod.Options };
    for ([_]Case{
        .{ .git_args = &.{"--depth=2"}, .options = .{ .who = test_who, .depth = 2 } },
        .{ .git_args = &.{"--filter=blob:none"}, .options = .{ .who = test_who, .filter = "blob:none" } },
        .{ .git_args = &.{}, .options = .{ .who = test_who } },
    }) |case| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "clone", "-q" });
        try args.appendSlice(gpa, case.git_args);
        try args.appendSlice(gpa, &.{ url, "by-git" });
        const out = try git(gpa, io, tmp.dir, &env, args.items);
        gpa.free(out);
        try tmp.dir.createDirPath(io, "by-relic");
        var b = try tmp.dir.openDir(io, "by-relic", .{ .iterate = true });
        defer b.close(io);
        var options = case.options;
        options.programs = .{ .environ = &env };
        var repo = try clone_mod.clone(gpa, io, url, b, options);
        repo.deinit(io);
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        try expectSame(gpa, io, &env, a, b);
        // A deepening fetch goes the same way.
        if (case.options.depth != null) {
            const fetched = try git(gpa, io, a, &env, &.{ "fetch", "-q", "--deepen=3", "origin" });
            gpa.free(fetched);
            var again = try repo_mod.Repository.open(gpa, io, b, .{});
            defer again.deinit(io);
            var outcome = try fetch_mod.fetch(gpa, io, &again, "origin", .{ .who = test_who, .deepen = 3, .programs = .{ .environ = &env } });
            outcome.deinit();
            try expectSame(gpa, io, &env, a, b);
        }
    }

    // A path is a local clone: the depth is ignored, and said to be, as git
    // says it.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    var repo = try clone_mod.clone(gpa, io, bare, tmp.dir, .{ .who = test_who, .depth = 1, .warnings = &warnings });
    repo.deinit(io);
    try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
    const text = try warnings.items.items[0].message(warnings.arena.allocator());
    try testing.expectEqualStrings("--depth is ignored in local clones; use file:// instead.", text);
    const shallow = try git(gpa, io, tmp.dir, &env, &.{ "rev-parse", "--is-shallow-repository" });
    defer gpa.free(shallow);
    try testing.expectEqualStrings("false\n", shallow);
}

test "git and relic clone over HTTP from relic's upload-pack, one request at a time, what they clone from git's" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const theirs_server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer theirs_server.stop();
    const ours_server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .upload_pack = helper });
    defer ours_server.stop();
    const theirs_url = try theirs_server.url(gpa, "repo.git");
    defer gpa.free(theirs_url);
    const ours_url = try ours_server.url(gpa, "repo.git");
    defer gpa.free(ours_url);

    for ([_][]const u8{ "2", "0" }) |version| for ([_][]const []const u8{ &.{}, &.{"--depth=2"}, &.{"--filter=blob:none"} }) |extra| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const version_setting = try std.fmt.allocPrint(gpa, "protocol.version={s}", .{version});
        defer gpa.free(version_setting);
        for ([_][]const u8{ theirs_url, ours_url }, [_][]const u8{ "by-git", "from-relic" }) |url, name| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.appendSlice(gpa, &.{ "-c", version_setting, "clone", "-q", "--no-checkout" });
            try args.appendSlice(gpa, extra);
            try args.appendSlice(gpa, &.{ url, name });
            const out = try git(gpa, io, tmp.dir, &env, args.items);
            gpa.free(out);
        }
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        var b = try tmp.dir.openDir(io, "from-relic", .{});
        defer b.close(io);
        try expectSame(gpa, io, &env, a, b);

        // relic's own client, from relic's server.
        try tmp.dir.createDirPath(io, "relic-both");
        var c = try tmp.dir.openDir(io, "relic-both", .{ .iterate = true });
        defer c.close(io);
        var config = try @import("config.zig").Config.parseText(gpa, if (std.mem.eql(u8, version, "0")) "[protocol]\nversion = 0\n" else "", .command);
        defer config.deinit();
        var options: clone_mod.Options = .{ .who = test_who, .checkout = false, .programs = .{ .environ = &env }, .config = &config };
        for (extra) |arg| {
            if (std.mem.eql(u8, arg, "--depth=2")) options.depth = 2;
            if (std.mem.eql(u8, arg, "--filter=blob:none")) options.filter = "blob:none";
        }
        var repo = try clone_mod.clone(gpa, io, ours_url, c, options);
        repo.deinit(io);
        try expectSame(gpa, io, &env, a, c);
    };
}
