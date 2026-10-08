//! Custom transfer adapters against git-lfs: the suite's agent handed to
//! git-lfs and to relic as a standalone agent, the lines each sent it
//! compared, and the objects where they should be; how many processes start,
//! and an agent that refuses to start.

const std = @import("std");
const suite = @import("../testing/helpers.zig");
const testbytes = @import("../testing/bytes.zig");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const repo_mod = @import("../repo/repo.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("api.zig");
const lfstransfer = @import("transfer.zig");
const objectwalk = @import("../walk/objectwalk.zig");
const testlfs = @import("../testing/lfs.zig");
const testremote = @import("../testing/remote.zig");

const Fixture = struct {
    gpa: Allocator,
    io: Io,
    tmp: testing.TmpDir,
    root: []u8,
    env: std.process.Environ.Map,

    fn init(gpa: Allocator, io: Io) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try testremote.absolutePath(gpa, io, tmp.dir);
        errdefer gpa.free(root);
        for ([_][]const u8{ "home", "objects with space" }) |name| try tmp.dir.createDirPath(io, name);
        const home = try gpa.print("{s}/home", .{root});
        defer gpa.free(home);
        var env = try testlfs.environ(gpa, home);
        errdefer env.deinit();
        try testlfs.requireGitLfs(gpa, io, &env);
        return .{ .gpa = gpa, .io = io, .tmp = tmp, .root = root, .env = env };
    }

    fn deinit(fx: *Fixture) void {
        fx.env.deinit();
        fx.gpa.free(fx.root);
        fx.tmp.cleanup();
        fx.* = undefined;
    }

    fn git(fx: *Fixture, d: Io.Dir, args: []const []const u8) !void {
        fx.gpa.free(try testlfs.git(fx.gpa, fx.io, d, &fx.env, args, true));
    }

    fn path(fx: *Fixture, name: []const u8) ![]u8 {
        return fx.gpa.print("{s}/{s}", .{ fx.root, name });
    }

    /// A repository with two LFS files committed, `origin` a bare
    /// repository beside it — which no git-lfs reaches but through the
    /// agent — and the agent configured, logging to `logs`.
    fn repo(fx: *Fixture, name: []const u8, logs: []const u8, extra: []const [2][]const u8) !Io.Dir {
        try fx.tmp.dir.createDirPath(fx.io, name);
        try fx.tmp.dir.createDirPath(fx.io, logs);
        const d = try fx.tmp.dir.openDir(fx.io, name, .{ .iterate = true });
        try fx.git(d, &.{ "init", "-q", "-b", "main" });
        for ([_][2][]const u8{
            .{ "filter.lfs.clean", "git-lfs clean -- %f" },
            .{ "filter.lfs.smudge", "git-lfs smudge -- %f" },
            .{ "filter.lfs.process", "git-lfs filter-process" },
            .{ "filter.lfs.required", "true" },
            .{ "lfs.locksverify", "false" },
            .{ "lfs.concurrenttransfers", "1" },
            .{ "lfs.standalonetransferagent", "agent" },
        }) |kv| try fx.git(d, &.{ "config", kv[0], kv[1] });
        const agent = suite.path(.lfs_agent);
        try fx.git(d, &.{ "config", "lfs.customtransfer.agent.path", agent });
        const objects = try fx.path("objects with space");
        defer fx.gpa.free(objects);
        const log_dir = try fx.path(logs);
        defer fx.gpa.free(log_dir);
        const args = try fx.gpa.print("'{s}' '{s}'", .{ objects, log_dir });
        defer fx.gpa.free(args);
        try fx.git(d, &.{ "config", "lfs.customtransfer.agent.args", args });
        for (extra) |kv| try fx.git(d, &.{ "config", kv[0], kv[1] });
        const bare = try fx.gpa.print("{s}.git", .{name});
        defer fx.gpa.free(bare);
        try fx.git(fx.tmp.dir, &.{ "init", "-q", "--bare", bare });
        const bare_path = try fx.path(bare);
        defer fx.gpa.free(bare_path);
        try fx.git(d, &.{ "remote", "add", "origin", bare_path });
        try d.writeFile(fx.io, .{ .sub_path = ".gitattributes", .data = "*.bin filter=lfs diff=lfs merge=lfs -text\n" });
        try d.writeFile(fx.io, .{ .sub_path = "a.bin", .data = testbytes.repeat("the first object\n", 64) });
        try d.writeFile(fx.io, .{ .sub_path = "b.bin", .data = "the second object\n" });
        try fx.git(d, &.{ "add", "-A" });
        try fx.git(d, &.{ "commit", "-q", "-m", "files" });
        return d;
    }

    /// What every agent process was sent, a line to a line, sorted, the
    /// repository's path written `<repo>`.
    fn sent(fx: *Fixture, logs: []const u8, repo_dir: Io.Dir) ![]u8 {
        const repo_path = try repo_dir.realPathFileAlloc(fx.io, ".", fx.gpa);
        defer fx.gpa.free(repo_path);
        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, repo_path, '\\', '/');
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |l| fx.gpa.free(l);
            lines.deinit(fx.gpa);
        }
        var dir = try fx.tmp.dir.openDir(fx.io, logs, .{ .iterate = true });
        defer dir.close(fx.io);
        var it = dir.iterate();
        while (try it.next(fx.io)) |entry| {
            const text = try dir.readFileAlloc(fx.io, entry.name, fx.gpa, .unlimited);
            defer fx.gpa.free(text);
            var split = std.mem.splitScalar(u8, text, '\n');
            while (split.next()) |l| {
                if (l.len == 0) continue;
                var parsed = try std.json.parseFromSlice(std.json.Value, fx.gpa, l, .{});
                defer parsed.deinit();
                // Normalize the decoded filesystem path, leaving URLs and
                // other protocol fields intact. JSON escapes Windows slashes.
                var normalized: ?[]u8 = null;
                defer if (normalized) |p| fx.gpa.free(p);
                if (parsed.value.object.getPtr("path")) |value| {
                    if (value.* == .string) {
                        const path_text = try fx.gpa.dupe(u8, value.string);
                        defer fx.gpa.free(path_text);
                        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, path_text, '\\', '/');
                        normalized = try std.mem.replaceOwned(u8, fx.gpa, path_text, repo_path, "<repo>");
                        value.* = .{ .string = normalized.? };
                    }
                }
                try lines.append(fx.gpa, try std.json.Stringify.valueAlloc(fx.gpa, parsed.value, .{}));
            }
        }
        std.mem.sort([]u8, lines.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return std.mem.join(fx.gpa, "\n", lines.items);
    }

    fn processes(fx: *Fixture, logs: []const u8) !usize {
        var dir = try fx.tmp.dir.openDir(fx.io, logs, .{ .iterate = true });
        defer dir.close(fx.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (try it.next(fx.io)) |_| n += 1;
        return n;
    }
};

fn relicUpload(fx: *Fixture, d: Io.Dir) !lfstransfer.Outcome {
    var repo = try repo_mod.Repository.open(fx.gpa, fx.io, d, .{});
    defer repo.deinit(fx.io);
    const head = (try repo.head(fx.io)).?;
    defer fx.gpa.free(head.name);
    var collected = try objectwalk.missing(fx.gpa, fx.io, repo.objectDatabase(), &.{head.oid}, &.{});
    defer collected.deinit();
    const server = try lfsapi.Server.open(fx.gpa, fx.io, &repo, "origin", .{ .programs = .{ .environ = &fx.env } });
    defer server.deinit();
    return lfstransfer.pushObjects(server, repo.objectDatabase(), collected.entries, .{});
}

fn relicFetch(fx: *Fixture, d: Io.Dir) !lfstransfer.Outcome {
    var repo = try repo_mod.Repository.open(fx.gpa, fx.io, d, .{});
    defer repo.deinit(fx.io);
    const server = try lfsapi.Server.open(fx.gpa, fx.io, &repo, "origin", .{ .programs = .{ .environ = &fx.env } });
    defer server.deinit();
    return lfstransfer.fetch(server, &repo, .{});
}

test "a standalone agent is sent what git-lfs sends it, an upload and a download, and the objects arrive" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    var theirs = try fx.repo("theirs", "logs-theirs-up", &.{});
    defer theirs.close(io);
    try fx.git(theirs, &.{ "lfs", "push", "origin", "main" });
    var ours = try fx.repo("ours", "logs-ours-up", &.{});
    defer ours.close(io);
    {
        var outcome = try relicUpload(&fx, ours);
        defer outcome.deinit();
        try testing.expectEqual(@as(usize, 0), outcome.failures());
        try testing.expectEqual(@as(usize, 2), outcome.results.len);
    }
    {
        const a = try fx.sent("logs-theirs-up", theirs);
        defer gpa.free(a);
        const b = try fx.sent("logs-ours-up", ours);
        defer gpa.free(b);
        try testing.expectEqualStrings(a, b);
        try testing.expect(std.mem.find(u8, b, "\"event\":\"upload\"") != null);
    }

    // Both stores emptied, each fetches its objects back through the agent.
    for ([_]Io.Dir{ theirs, ours }) |d| try d.deleteTree(io, ".git/lfs/objects");
    try fx.tmp.dir.createDirPath(io, "logs-theirs-down");
    try fx.tmp.dir.createDirPath(io, "logs-ours-down");
    for ([_][2][]const u8{ .{ "theirs", "logs-theirs-down" }, .{ "ours", "logs-ours-down" } }) |pair| {
        const d = try fx.tmp.dir.openDir(io, pair[0], .{});
        defer d.close(io);
        const objects = try fx.path("objects with space");
        defer gpa.free(objects);
        const log_dir = try fx.path(pair[1]);
        defer gpa.free(log_dir);
        const args = try gpa.print("'{s}' '{s}'", .{ objects, log_dir });
        defer gpa.free(args);
        try fx.git(d, &.{ "config", "lfs.customtransfer.agent.args", args });
    }
    try fx.git(theirs, &.{ "lfs", "fetch", "origin", "main" });
    {
        var outcome = try relicFetch(&fx, ours);
        defer outcome.deinit();
        try testing.expectEqual(@as(usize, 0), outcome.failures());
    }
    const a = try fx.sent("logs-theirs-down", theirs);
    defer gpa.free(a);
    const b = try fx.sent("logs-ours-down", ours);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
    var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
    defer repo.deinit(io);
    var store = try lfs.Lfs.load(gpa, io, repo.configuration(), repo.commonDirectory(), null, .{});
    defer store.deinit();
    const content = testbytes.repeat("the first object\n", 64);
    const pointer: lfs.Pointer = .{ .oid = testlfs.sha256Hex(content), .size = content.len };
    try testing.expect(try store.store.contains(io, &pointer));
}

test "concurrent agents start as many as git-lfs starts, one when not concurrent, and one refusing init stops the transfer" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();
    const concurrent = [_][2][]const u8{.{ "lfs.concurrenttransfers", "3" }};
    var theirs = try fx.repo("theirs", "logs-theirs", &concurrent);
    defer theirs.close(io);
    try fx.git(theirs, &.{ "lfs", "push", "origin", "main" });
    var ours = try fx.repo("ours", "logs-ours", &concurrent);
    defer ours.close(io);
    {
        var outcome = try relicUpload(&fx, ours);
        defer outcome.deinit();
        try testing.expectEqual(@as(usize, 0), outcome.failures());
    }
    try testing.expectEqual(try fx.processes("logs-theirs"), try fx.processes("logs-ours"));
    try testing.expectEqual(@as(usize, 3), try fx.processes("logs-ours"));
    {
        const a = try fx.sent("logs-theirs", theirs);
        defer gpa.free(a);
        const b = try fx.sent("logs-ours", ours);
        defer gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }

    var single = try fx.repo("single", "logs-single", &(concurrent ++ [_][2][]const u8{.{ "lfs.customtransfer.agent.concurrent", "false" }}));
    defer single.close(io);
    {
        var outcome = try relicUpload(&fx, single);
        defer outcome.deinit();
    }
    try testing.expectEqual(@as(usize, 1), try fx.processes("logs-single"));
    const sent = try fx.sent("logs-single", single);
    defer gpa.free(sent);
    try testing.expect(std.mem.find(u8, sent, "{\"event\":\"init\",\"operation\":\"upload\",\"remote\":\"origin\",\"concurrent\":false,\"concurrenttransfers\":3}") != null);

    var refusing = try fx.repo("refusing", "logs-refusing", &.{});
    defer refusing.close(io);
    const objects = try fx.path("objects with space");
    defer gpa.free(objects);
    const log_dir = try fx.path("logs-refusing");
    defer gpa.free(log_dir);
    const args = try gpa.print("'{s}' '{s}' refuse-init", .{ objects, log_dir });
    defer gpa.free(args);
    try fx.git(refusing, &.{ "config", "lfs.customtransfer.agent.args", args });
    try testing.expectError(error.LfsAdapterInitFailed, relicUpload(&fx, refusing));
}
