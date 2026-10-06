//! `core.sharedRepository` against git's: the same operations in two
//! repositories with the same setting, and the permissions of what each
//! wrote compared kind by kind — loose objects and their directories,
//! packs and their indexes, the commit-graph, refs, logs and their
//! directories, `packed-refs`, the index and the configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const relic = @import("../relic.zig");
const testgit = @import("git.zig");
const platstat = @import("../repo/fs/stat.zig");

const Repository = relic.repo.Repository;
const Oid = relic.hash.Oid;

const who: relic.object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

/// What kind of thing a path under `.git` is, for comparing permissions.
fn kindOf(path: []const u8) ?[]const u8 {
    const kinds = [_]struct { []const u8, []const u8 }{
        .{ "objects/pack/", "pack file" },
        .{ "objects/info/commit-graph", "commit-graph" },
        .{ "refs/heads/", "ref" },
        .{ "logs/refs/heads/", "log" },
    };
    if (std.mem.eql(u8, path, "index")) return "index";
    if (std.mem.eql(u8, path, "config")) return "config";
    if (std.mem.eql(u8, path, "packed-refs")) return "packed-refs";
    if (std.mem.eql(u8, path, "logs/HEAD")) return "log";
    if (path.len == "objects/xx/".len + 38 and std.mem.startsWith(u8, path, "objects/") and path[10] == '/') return "loose object";
    for (kinds) |k| if (std.mem.startsWith(u8, path, k[0])) return k[1];
    return null;
}

fn dirKindOf(path: []const u8) ?[]const u8 {
    if (path.len == "objects/xx".len and std.mem.startsWith(u8, path, "objects/")) return "fan-out directory";
    if (std.mem.eql(u8, path, "objects/pack")) return "pack directory";
    if (std.mem.startsWith(u8, path, "refs/heads/")) return "ref directory";
    if (std.mem.startsWith(u8, path, "logs/refs")) return "log directory";
    return null;
}

/// Every kind found under `dir`, with the permission bits each has.
fn modes(gpa: Allocator, io: Io, dir: Io.Dir) !std.array_hash_map.String(std.ArrayList(u32)) {
    var out: std.array_hash_map.String(std.ArrayList(u32)) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const path = try gpa.dupe(u8, entry.path);
        defer gpa.free(path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const kind = if (entry.kind == .directory) dirKindOf(path) else kindOf(path);
        const k = kind orelse continue;
        const found = switch (platstat.full(dir, entry.path)) {
            .found => |f| f,
            else => continue,
        };
        const gop = try out.getOrPut(gpa, k);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const mode = found.mode & 0o7777;
        for (gop.value_ptr.items) |m| {
            if (m == mode) break;
        } else try gop.value_ptr.append(gpa, mode);
    }
    return out;
}

fn freeModes(gpa: Allocator, m: *std.array_hash_map.String(std.ArrayList(u32))) void {
    for (m.values()) |*list| list.deinit(gpa);
    m.deinit(gpa);
}

/// git's side: a commit, a branch, refs packed and one loose again, a
/// repack, a loose object, a configuration edit and a commit-graph.
fn byGit(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a.txt", "a\n");
    try git.writeFile(io, "dir/b.txt", "b\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "first" });
    try git.exec(io, &.{ "update-ref", "-m", "branch", "refs/heads/topic/one", "HEAD" });
    try git.exec(io, &.{ "pack-refs", "--all" });
    try git.exec(io, &.{ "update-ref", "-m", "loose", "refs/heads/loose", "HEAD" });
    try git.exec(io, &.{ "repack", "-a", "-d", "-q" });
    try git.exec(io, &.{ "hash-object", "-w", "--stdin" });
    try git.exec(io, &.{ "config", "fixture.value", "set" });
    try git.exec(io, &.{ "commit-graph", "write", "--reachable" });
}

/// The same through relic.
fn byRelic(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a.txt", "a\n");
    try git.writeFile(io, "dir/b.txt", "b\n");
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    _ = try relic.worktree.addAll(gpa, io, git.dir, &index, &repo.odb, .{ .rules = try repo.worktreeRules() });
    const tree = try relic.worktree.writeTree(gpa, io, &index, &repo.odb);
    try repo.writeIndex(io, &index);
    const commit = try repo.writeCommit(io, .{ .tree = tree, .author = who, .committer = who, .message = "first\n" }, null);
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.update("refs/heads/main", .{ .direct = commit }, .any);
        try tx.commit(io, .{ .who = who, .message = "commit (initial): first" });
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.update("refs/heads/topic/one", .{ .direct = commit }, .must_not_exist);
        try tx.commit(io, .{ .who = who, .message = "branch" });
    }
    const store = repo.refStore();
    try store.writePacked(io, &.{
        .{ .name = "refs/heads/main", .oid = commit, .peeled = null },
        .{ .name = "refs/heads/topic/one", .oid = commit, .peeled = null },
    });
    try repo.git_dir.deleteFile(io, "refs/heads/main");
    try repo.git_dir.deleteFile(io, "refs/heads/topic/one");
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.update("refs/heads/loose", .{ .direct = commit }, .must_not_exist);
        try tx.commit(io, .{ .who = who, .message = "loose" });
    }
    _ = try repo.odb.repack(io, .{ .remove_packs = true });
    _ = try repo.odb.write(io, .blob, "");
    {
        var config = try relic.config.Config.openFile(gpa, io, .{ .dir = repo.git_dir, .sub_path = "config" }, .local, .{});
        defer config.deinit();
        try config.set("fixture.value", "set");
        try config.write(io, repo.git_dir, "config");
    }
    _ = try relic.odb.accelerators.writeCommitGraph(gpa, io, &repo.odb, &.{commit}, .{});
}

test "core.sharedRepository gives what is written git's permissions" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]?[]const u8{ null, "umask", "group", "true", "all", "0640", "0660", "0600", "0644" }) |setting| {
        var a = try testgit.Repo.init(gpa, io, &.{});
        defer a.deinit();
        var b = try testgit.Repo.init(gpa, io, &.{});
        defer b.deinit();
        if (setting) |value| {
            try a.exec(io, &.{ "config", "core.sharedRepository", value });
            try b.exec(io, &.{ "config", "core.sharedRepository", value });
        }
        try byGit(io, &a);
        try byRelic(gpa, io, &b);
        var a_git = try a.gitDir(io);
        defer a_git.close(io);
        var b_git = try b.gitDir(io);
        defer b_git.close(io);
        var theirs = try modes(gpa, io, a_git);
        defer freeModes(gpa, &theirs);
        var ours = try modes(gpa, io, b_git);
        defer freeModes(gpa, &ours);
        for (theirs.keys(), theirs.values()) |kind, git_modes| {
            const relic_modes = ours.get(kind) orelse {
                std.debug.print("{?s}: relic wrote no {s}\n", .{ setting, kind });
                return error.TestUnexpectedResult;
            };
            std.mem.sort(u32, git_modes.items, {}, std.sort.asc(u32));
            std.mem.sort(u32, relic_modes.items, {}, std.sort.asc(u32));
            std.testing.expectEqualSlices(u32, git_modes.items, relic_modes.items) catch |err| {
                std.debug.print("{?s}: {s}: git {any} relic {any}\n", .{ setting, kind, git_modes.items, relic_modes.items });
                return err;
            };
        }
    }
}

test "a core.sharedRepository mode the owner cannot read and write refuses the repository" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "core.sharedRepository", "0440" });
    try std.testing.expectError(error.InvalidSharedMode, Repository.open(gpa, io, git.dir, .{}));
    try std.testing.expectEqual(relic.repo.fs.Shared{ .mode = 0o640 }, try relic.repo.fs.Shared.parse("0640"));
    try std.testing.expectEqual(relic.repo.fs.Shared.group, try relic.repo.fs.Shared.parse("1"));
    try std.testing.expectEqual(relic.repo.fs.Shared.everybody, try relic.repo.fs.Shared.parse("2"));
    try std.testing.expectEqual(relic.repo.fs.Shared.umask, try relic.repo.fs.Shared.parse("false"));
    try std.testing.expectEqual(relic.repo.fs.Shared{ .mode = 0o666 }, try relic.repo.fs.Shared.parse("0666"));
}
