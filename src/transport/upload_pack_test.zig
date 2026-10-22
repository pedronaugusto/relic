//! relic's upload-pack held to git's: real git clones and fetches from it —
//! handed it as `--upload-pack` — and what it ends with is compared with
//! what it ends with from its own upload-pack, full, shallow by depth, date
//! and ref, deepened and unshallowed, and filtered, in protocol v2 and v0;
//! and relic fetches from it in process for a `file://` remote.

const config_mod = @import("../config/config.zig");
const std = @import("std");
const suite = @import("../testing/helpers.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const warning = @import("../report.zig").warning;
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const local = @import("local.zig");
const upload_pack_mod = @import("upload_pack.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const program = @import("../process.zig").program;

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

const sparse_spec = "/file\n/dir/\n!/dir/deep/\n";

/// Eight commits a day apart on `main`, a branch, a lightweight and an
/// annotated tag, a file large enough for `blob:limit`, and filters
/// allowed: `<root>/repo.git`.
fn served(gpa: Allocator, io: Io, root: Io.Dir) ![]u8 {
    const root_path = try testremote.absolutePath(gpa, io, root);
    defer gpa.free(root_path);
    const bare = try gpa.print("{s}/repo.git", .{root_path});
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
        // Sparse patterns for `sparse:oid=`: a file, and a directory with
        // a part taken back out.
        if (mark == 1) try stream.print(gpa, "M 100644 inline spec\ndata {d}\n{s}\n", .{ sparse_spec.len, sparse_spec });
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
    const gpa = testing.allocator;
    const io = testing.io;
    const shell_helper = try gpa.dupe(u8, suite.path(.upload_pack_helper));
    defer gpa.free(shell_helper);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, shell_helper, '\\', '/');
    // git before 2.43 cannot walk what a combine: filter with object:type=
    // left.
    try testgit.requireGitVersion(gpa, io, 2, 43);
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try gpa.print("file://{s}", .{bare});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    const day = 86400;
    var since_buf: [64]u8 = undefined;
    const since = try std.mem.print(&since_buf, "--shallow-since={d}", .{1_600_000_000 + 5 * day + 1});
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
        &.{"--filter=sparse:oid=main:spec"},
        &.{"--filter=sparse:oid=main~3^{tree}:spec"},
        &.{"--filter=combine:blob:none+tree:2"},
        &.{"--filter=combine:blob:limit=1k+tree:3"},
        &.{"--filter=combine:tree:3+blob:limit=1k"},
        &.{"--filter=combine:sparse:oid=main%3Aspec+tree:2"},
        &.{"--filter=combine:object:type=tree+tree:2"},
        &.{"--filter=blob:limit=2"},
        &.{"--filter=tree:0"},
        &.{"--filter=tree:2"},
        &.{"--filter=object:type=tree"},
        &.{"--filter=object:type=commit"},
        &.{"--filter=combine:tree:2+sparse:oid=main%3Aspec"},
        &.{"--filter=object:type=blob"},
    };
    for ([_][]const u8{ "2", "0" }) |version| for (cases) |extra| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        for ([_]?[]const u8{ null, shell_helper }, [_][]const u8{ "by-git", "by-relic" }) |upload_pack, name| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            const version_setting = try gpa.print("protocol.version={s}", .{version});
            defer gpa.free(version_setting);
            try args.appendSlice(gpa, &.{ "-c", version_setting, "clone", "-q", "--no-checkout" });
            if (upload_pack) |p| try args.appendSlice(gpa, &.{ "--upload-pack", p });
            try args.appendSlice(gpa, extra);
            try args.appendSlice(gpa, &.{ url, name });
            const out = git(gpa, io, tmp.dir, &env, args.items) catch |err| {
                for (extra) |arg| std.debug.print("{s} ", .{arg});
                std.debug.print("in protocol v{s}, cloned by {s}\n", .{ version, name });
                return err;
            };
            gpa.free(out);
        }
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        var b = try tmp.dir.openDir(io, "by-relic", .{});
        defer b.close(io);
        expectSame(gpa, io, &env, a, b) catch |err| {
            for (extra) |arg| std.debug.print("{s} ", .{arg});
            std.debug.print("in protocol v{s}\n", .{version});
            return err;
        };
    };
}

test "git deepens, unshallows and fetches again from relic's upload-pack as from its own" {
    const gpa = testing.allocator;
    const io = testing.io;
    const shell_helper = try gpa.dupe(u8, suite.path(.upload_pack_helper));
    defer gpa.free(shell_helper);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, shell_helper, '\\', '/');
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try gpa.print("file://{s}", .{bare});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    for ([_][]const u8{ "2", "0" }) |version| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const version_setting = try gpa.print("protocol.version={s}", .{version});
        defer gpa.free(version_setting);
        for ([_]?[]const u8{ null, shell_helper }, [_][]const u8{ "by-git", "by-relic" }) |upload_pack, name| {
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
                const setting = try gpa.print("remote.origin.uploadpack={s}", .{shell_helper});
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
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try gpa.print("file://{s}", .{bare});
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
    const ours_server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .upload_pack = suite.path(.upload_pack_helper) });
    defer ours_server.stop();
    const theirs_url = try theirs_server.url(gpa, "repo.git");
    defer gpa.free(theirs_url);
    const ours_url = try ours_server.url(gpa, "repo.git");
    defer gpa.free(ours_url);

    for ([_][]const u8{ "2", "0" }) |version| for ([_][]const []const u8{ &.{}, &.{"--depth=2"}, &.{"--filter=blob:none"} }) |extra| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const version_setting = try gpa.print("protocol.version={s}", .{version});
        defer gpa.free(version_setting);
        for ([_][]const u8{ theirs_url, ours_url }, [_][]const u8{ "by-git", "from-relic" }) |url, name| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.appendSlice(gpa, &.{ "-c", version_setting, "clone", "-q", "--no-checkout" });
            try args.appendSlice(gpa, extra);
            try args.appendSlice(gpa, &.{ url, name });
            const out = git(gpa, io, tmp.dir, &env, args.items) catch |err| {
                for (extra) |arg| std.debug.print("{s} ", .{arg});
                std.debug.print("in protocol v{s}, cloned by {s}\n", .{ version, name });
                return err;
            };
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
        var config = try config_mod.Config.parseText(gpa, if (std.mem.eql(u8, version, "0")) "[protocol]\nversion = 0\n" else "", .command);
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

test "relic's upload-pack answers bundle-uri as git's under uploadpack.advertiseBundleURIs: every bundle.* setting, its section and variable in lower case" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_PROTOCOL", "version=2");
    const config_path = try std.Io.Dir.path.join(gpa, &.{ bare, "config" });
    defer gpa.free(config_path);
    const config = try Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .unlimited);
    defer gpa.free(config);
    const more = "[uploadpack]\n\tadvertiseBundleURIs = yes\n[Bundle]\n\tVersion = 1\n\tmode = all\n[bundle \"One.B\"]\n\tURI = https://example.com/one.bundle\n\tcreationToken = 3\n[core]\n\tbundled = no\n";
    const joined = try std.mem.concat(gpa, u8, &.{ config, more });
    defer gpa.free(joined);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = joined });

    const request = "0017command=bundle-uri\n00010000";
    const theirs = try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "upload-pack", "--stateless-rpc", bare }, request, true);
    defer gpa.free(theirs);
    var remote = try local.Remote.open(gpa, io, bare, .{});
    defer remote.deinit(io);
    var server: upload_pack_mod.Server = .init(gpa, io, &remote, .v2, .{ .stateless = true });
    var fixed: Io.Reader = .fixed(request);
    var buffer: [pkt_line.max_line]u8 = undefined;
    var in = fixed.limited(.unlimited, &buffer);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try server.serveRequest(&out.writer, &in.interface);
    try testing.expectEqualStrings(theirs, out.written());
    try testing.expect(std.mem.find(u8, theirs, "bundle.One.B.uri=https://example.com/one.bundle") != null);

    // The advertisement names it where git's does: after object-format.
    var advertised: Io.Writer.Allocating = .init(gpa);
    defer advertised.deinit();
    try server.advertise(&advertised.writer);
    try testing.expect(std.mem.find(u8, advertised.written(), "object-format=sha1\n000fbundle-uri\n") != null);
}

test "uploadpack.allowRefInWant and uploadpackfilter.* are held to as git's upload-pack holds to them" {
    const gpa = testing.allocator;
    const io = testing.io;
    const shell_helper = try gpa.dupe(u8, suite.path(.upload_pack_helper));
    defer gpa.free(shell_helper);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, shell_helper, '\\', '/');
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try gpa.print("file://{s}", .{bare});
    defer gpa.free(url);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var served_dir = try Io.Dir.cwd().openDir(io, bare, .{});
    defer served_dir.close(io);
    const settings = [_][2][]const u8{
        .{ "uploadpack.allowRefInWant", "true" },
        .{ "uploadpack.allowFilter", "true" },
        .{ "uploadpackfilter.allow", "false" },
        .{ "uploadpackfilter.blob:none.allow", "true" },
        .{ "uploadpackfilter.tree.maxDepth", "1" },
    };
    for (settings) |kv| gpa.free(try git(gpa, io, served_dir, &env, &.{ "config", kv[0], kv[1] }));
    // A clone by ref name, with filters the settings allow and refuse.
    const cases = [_][]const []const u8{
        &.{},
        &.{"--filter=blob:none"},
        &.{"--filter=tree:1"},
        &.{"--filter=tree:2"},
        &.{"--filter=blob:limit=1k"},
        &.{"--filter=combine:blob:none+tree:1"},
    };
    for (cases) |extra| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var outcomes: [2]?[]u8 = undefined;
        for ([_]?[]const u8{ null, shell_helper }, [_][]const u8{ "by-git", "by-relic" }, 0..) |upload_pack, name, i| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.appendSlice(gpa, &.{ "-c", "protocol.version=2", "clone", "-q", "--no-checkout" });
            if (upload_pack) |p| try args.appendSlice(gpa, &.{ "--upload-pack", p });
            try args.appendSlice(gpa, extra);
            try args.appendSlice(gpa, &.{ url, name });
            outcomes[i] = testremote.gitInputEnv(gpa, io, tmp.dir, &env, args.items, "", false) catch null;
        }
        defer for (outcomes) |o| if (o) |text| gpa.free(text);
        try testing.expectEqual(outcomes[0] == null, outcomes[1] == null);
        if (outcomes[0] == null) continue;
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        var b = try tmp.dir.openDir(io, "by-relic", .{});
        defer b.close(io);
        try expectSame(gpa, io, &env, a, b);
        // A fetch of one more ref by name.
        for ([_]Io.Dir{ a, b }) |d| gpa.free(try git(gpa, io, d, &env, &.{ "-c", "protocol.version=2", "fetch", "-q", "origin", "refs/heads/main:refs/heads/fetched" }));
        try expectSame(gpa, io, &env, a, b);
    }
}

test "object-info answers each object's size as git's upload-pack does, and both name a session under transfer.advertiseSID" {
    const gpa = testing.allocator;
    const io = testing.io;
    const helper = try gpa.dupe(u8, suite.path(.upload_pack_helper));
    defer gpa.free(helper);
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_PROTOCOL", "version=2");
    var served_dir = try Io.Dir.cwd().openDir(io, bare, .{});
    defer served_dir.close(io);
    gpa.free(try git(gpa, io, served_dir, &env, &.{ "config", "transfer.advertiseObjectInfo", "true" }));
    gpa.free(try git(gpa, io, served_dir, &env, &.{ "config", "transfer.advertiseSID", "true" }));
    const main_oid = try git(gpa, io, served_dir, &env, &.{ "rev-parse", "main", "main^{tree}" });
    defer gpa.free(main_oid);
    var oids = std.mem.tokenizeScalar(u8, main_oid, '\n');
    const commit = oids.next().?;
    const tree = oids.next().?;

    // One request, every kind of line: sizes asked, a commit and a tree,
    // an object neither has, a name that is none, a line not asked for.
    var request: Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    const w = &request.writer;
    try pkt_line.write(w, "command=object-info");
    try pkt_line.write(w, "object-format=sha1");
    try pkt_line.delim(w);
    try pkt_line.write(w, "size");
    try pkt_line.print(w, "oid {s}", .{commit});
    try pkt_line.print(w, "oid {s}", .{tree});
    try pkt_line.write(w, "oid 0123456789012345678901234567890123456789");
    try pkt_line.write(w, "oid nothing");
    try pkt_line.write(w, "bogus");
    try pkt_line.flush(w);
    var answers: [2][]u8 = undefined;
    for ([_][]const u8{ "git", helper }, 0..) |program_name, i| {
        const argv: []const []const u8 = if (i == 0) &.{ program_name, "upload-pack", "--stateless-rpc", bare } else &.{ program_name, "--stateless-rpc", bare };
        const outcome = try program.run(gpa, io, .{ .environ = &env }, .{ .argv = argv }, .{ .input = request.written() });
        defer gpa.free(outcome.stderr);
        answers[i] = outcome.stdout;
    }
    defer for (answers) |a| gpa.free(a);
    try testing.expectEqualStrings(answers[0], answers[1]);

    // Each advertises a session and the command.
    for ([_][]const u8{ "git", helper }, 0..) |program_name, i| {
        const argv: []const []const u8 = if (i == 0) &.{ program_name, "upload-pack", "--advertise-refs", bare } else &.{ program_name, "--advertise-refs", bare };
        var outcome = try program.run(gpa, io, .{ .environ = &env }, .{ .argv = argv }, .{});
        defer outcome.deinit(gpa);
        try testing.expect(std.mem.find(u8, outcome.stdout, "session-id=") != null);
        try testing.expect(std.mem.find(u8, outcome.stdout, "object-info\n") != null);
    }
}

test "uploadpack.packObjectsHook makes the pack as git's upload-pack has it made, read only where the repository cannot write it, and uploadpack.keepAlive speaks while it works" {
    const gpa = testing.allocator;
    const io = testing.io;
    const shell_helper = try gpa.dupe(u8, suite.path(.upload_pack_helper));
    defer gpa.free(shell_helper);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, shell_helper, '\\', '/');
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const bare = try served(gpa, io, root.dir);
    defer gpa.free(bare);
    const url = try gpa.print("file://{s}", .{bare});
    defer gpa.free(url);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, root_path, '\\', '/');

    // The hook notes what it is handed, then makes the pack as asked.
    const script =
        \\#!/bin/sh
        \\d=$(dirname "$0")
        \\printf '%s\n' "$*" >>"$d/args"
        \\if test -n "$SLOW_HOOK"; then sleep 3; fi
        \\tee -a "$d/stdin" | "$@"
        \\
    ;
    try root.dir.writeFile(io, .{ .sub_path = "hook", .data = script });
    try root.dir.writeFile(io, .{ .sub_path = "evil", .data = "#!/bin/sh\ntouch \"$(dirname \"$0\")/evil-ran\"\nexec \"$@\"\n" });
    if (builtin.target.os.tag != .windows) for ([_][]const u8{ "hook", "evil" }) |name| {
        const file = try root.dir.openFile(io, name, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    };
    const global = try gpa.print("[uploadpack]\n\tpackObjectsHook = {s}/hook\n\tkeepAlive = 1\n", .{root_path});
    defer gpa.free(global);
    try root.dir.writeFile(io, .{ .sub_path = "global.gitconfig", .data = global });
    const global_path = try gpa.print("{s}/global.gitconfig", .{root_path});
    defer gpa.free(global_path);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_CONFIG_GLOBAL", global_path);
    // The repository's own word is not taken.
    const evil = try gpa.print("{s}/evil", .{root_path});
    defer gpa.free(evil);
    const set_evil = try git(gpa, io, root.dir, &env, &.{ "--git-dir", bare, "config", "uploadpack.packObjectsHook", evil });
    gpa.free(set_evil);

    const cases = [_][]const []const u8{
        &.{},
        &.{"--depth=2"},
        &.{"--filter=blob:limit=1k"},
        &.{ "--filter=combine:blob:none+tree:3", "--depth=3" },
    };
    for ([_][]const u8{ "2", "0" }) |version| for (cases) |extra| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var said: [2][2][]u8 = undefined;
        for ([_]?[]const u8{ null, shell_helper }, [_][]const u8{ "by-git", "by-relic" }, 0..) |upload_pack, name, i| {
            for ([_][]const u8{ "args", "stdin" }) |log| root.dir.deleteFile(io, log) catch |err| if (err != error.FileNotFound) return err;
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            const version_setting = try gpa.print("protocol.version={s}", .{version});
            defer gpa.free(version_setting);
            try args.appendSlice(gpa, &.{ "-c", version_setting, "clone", "-q", "--no-checkout" });
            if (upload_pack) |p| try args.appendSlice(gpa, &.{ "--upload-pack", p });
            try args.appendSlice(gpa, extra);
            try args.appendSlice(gpa, &.{ url, name });
            const out = try git(gpa, io, tmp.dir, &env, args.items);
            gpa.free(out);
            // A shallow clone deepened: haves, and the boundary moved.
            if (extra.len != 0 and std.mem.startsWith(u8, extra[extra.len - 1], "--depth")) {
                var d = try tmp.dir.openDir(io, name, .{});
                defer d.close(io);
                const fetched = try git(gpa, io, d, &env, &.{ "-c", version_setting, "fetch", "-q", "--deepen=1" });
                gpa.free(fetched);
            }
            said[i][0] = try root.dir.readFileAlloc(io, "args", gpa, .unlimited);
            said[i][1] = try root.dir.readFileAlloc(io, "stdin", gpa, .unlimited);
        }
        defer for (said) |pair| for (pair) |text| gpa.free(text);
        for (0..2) |k| testing.expectEqualStrings(said[0][k], said[1][k]) catch |err| {
            for (extra) |arg| std.debug.print("{s} ", .{arg});
            std.debug.print("in protocol v{s}\n", .{version});
            return err;
        };
        var a = try tmp.dir.openDir(io, "by-git", .{});
        defer a.close(io);
        var b = try tmp.dir.openDir(io, "by-relic", .{});
        defer b.close(io);
        try expectSame(gpa, io, &env, a, b);
    };
    try testing.expectError(error.FileNotFound, root.dir.access(io, "evil-ran", .{}));

    // A hook slow to start: the client hears keepalives meanwhile.
    try env.put("SLOW_HOOK", "1");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_path = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(tmp_path);
    for ([_]?[]const u8{ null, shell_helper }, [_][]const u8{ "by-git", "by-relic" }) |upload_pack, name| {
        const trace = try gpa.print("{s}/{s}.trace", .{ tmp_path, name });
        defer gpa.free(trace);
        try env.put("GIT_TRACE_PACKET", trace);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "clone", "-q", "--no-checkout" });
        if (upload_pack) |p| try args.appendSlice(gpa, &.{ "--upload-pack", p });
        try args.appendSlice(gpa, &.{ url, name });
        const out = try git(gpa, io, tmp.dir, &env, args.items);
        gpa.free(out);
        const traced = try Io.Dir.cwd().readFileAlloc(io, trace, gpa, .unlimited);
        defer gpa.free(traced);
        testing.expect(std.mem.count(u8, traced, "sideband< \\1\n") >= 1) catch |err| {
            std.debug.print("{s}: no keepalive in\n{s}\n", .{ name, traced });
            return err;
        };
    }
}
