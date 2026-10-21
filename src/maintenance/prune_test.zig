//! `prune` held to git 2.55's: the same repository pruned by each, the
//! object directory and `.git/shallow` compared.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const prune_mod = @import("prune.zig");
const gc = @import("gc.zig");
const repo_mod = @import("../repo/repo.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

const day = std.time.s_per_day;

fn at(repo: *testgit.Repo, secs: i64) !void {
    var buffer: [32]u8 = undefined;
    const value = try std.mem.print(&buffer, "@{d} +0000", .{secs});
    try repo.isolated.?.put("GIT_AUTHOR_DATE", value);
    try repo.isolated.?.put("GIT_COMMITTER_DATE", value);
}

fn commitAt(repo: *testgit.Repo, secs: i64, message: []const u8) !void {
    try at(repo, secs);
    try repo.writeFile(io, "file.txt", message);
    try repo.exec(io, &.{ "add", "file.txt" });
    try repo.exec(io, &.{ "commit", "-q", "-m", message });
}

/// A commit nothing names, on `tree` with `parent`, as `commit-tree`
/// makes it.
fn dangling(repo: *testgit.Repo, tree: []const u8, parent: ?[]const u8, message: []const u8) ![]u8 {
    if (parent) |p| return repo.line(io, &.{ "commit-tree", tree, "-p", p, "-m", message });
    return repo.line(io, &.{ "commit-tree", tree, "-m", message });
}

/// Every loose file's time set to `secs`.
fn ageLoose(repo: *testgit.Repo, secs: i64) !void {
    var objects = try repo.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var it = objects.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name.len != 2) continue;
        var sub = try objects.openDir(io, entry.name, .{ .iterate = true });
        defer sub.close(io);
        var files = sub.iterate();
        while (try files.next(io)) |file| try setTime(sub, file.name, secs);
    }
}

fn setTime(dir: Io.Dir, name: []const u8, secs: i64) !void {
    try dir.setTimestamps(io, name, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, secs) * std.time.ns_per_s) } });
}

fn touchObject(repo: *testgit.Repo, hex: []const u8, secs: i64) !void {
    var buffer: [128]u8 = undefined;
    const path = try std.mem.print(&buffer, ".git/objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    try setTime(repo.dir, path, secs);
}

/// A repository with every kind of thing `prune` keeps and removes: refs,
/// a reflog-only commit, an index-only blob, a linked worktree whose
/// `HEAD` and own reflog name commits nothing else does, unreachable
/// objects old and recent (one recent commit reaching old ones), loose
/// copies of packed objects, stale temporary files and a shallow
/// boundary with a commit nothing reaches.
fn fixture(format: testgit.RefFormat, now: i64) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, format.initArgs());
    errdefer repo.deinit();
    try commitAt(&repo, now - 100 * day, "one");
    try commitAt(&repo, now - 90 * day, "two");
    // Loose copies stay beside the pack.
    try repo.exec(io, &.{ "repack", "-q" });
    try commitAt(&repo, now - 80 * day, "three");
    try repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try repo.writeFile(io, "staged.txt", "only in the index\n");
    try repo.exec(io, &.{ "add", "staged.txt" });

    const tree = try repo.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree);
    const head = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try at(&repo, now - 70 * day);
    const old = try dangling(&repo, tree, head, "old and unreachable");
    defer gpa.free(old);
    // Below a recent commit: an old one on a tree and blob of its own.
    const own_blob = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "under the recent one\n");
    defer gpa.free(own_blob);
    var listing: [256]u8 = undefined;
    const own_tree = try repo.runInput(io, &.{"mktree"}, try std.mem.print(&listing, "100644 blob {s}\tbelow.txt\n", .{std.mem.trim(u8, own_blob, "\n")}));
    defer gpa.free(own_tree);
    const base = try dangling(&repo, std.mem.trim(u8, own_tree, "\n"), null, "old, below a recent one");
    defer gpa.free(base);
    const recent = try dangling(&repo, tree, base, "recent and unreachable");
    defer gpa.free(recent);
    const shallow_gone = try dangling(&repo, tree, null, "a shallow boundary nothing reaches");
    defer gpa.free(shallow_gone);
    const worktree_head = try dangling(&repo, tree, head, "the linked worktree's");
    defer gpa.free(worktree_head);
    const worktree_logged = try dangling(&repo, tree, head, "the linked worktree's reflog's");
    defer gpa.free(worktree_logged);
    gpa.free(try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "an old blob\n"));
    const fresh_blob = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "a recent blob\n");
    defer gpa.free(fresh_blob);

    try repo.exec(io, &.{ "worktree", "add", "-q", "--detach", "linked", worktree_logged });
    try repo.exec(io, &.{ "-C", "linked", "checkout", "-q", "--detach", worktree_head });

    const root = try repo.line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(root);
    var shallow: [256]u8 = undefined;
    try repo.writeFile(io, ".git/shallow", try std.mem.print(&shallow, "{s}\n{s}\n", .{ root, shallow_gone }));

    try ageLoose(&repo, now - 30 * day);
    try touchObject(&repo, recent, now);
    try touchObject(&repo, std.mem.trim(u8, fresh_blob, "\n"), now);
    // Stale and fresh temporary files.
    try repo.writeFile(io, ".git/objects/ab/tmp_obj_stale", "x");
    try setTime(repo.dir, ".git/objects/ab/tmp_obj_stale", now - 30 * day);
    try repo.writeFile(io, ".git/objects/pack/tmp_pack_stale", "x");
    try setTime(repo.dir, ".git/objects/pack/tmp_pack_stale", now - 30 * day);
    try repo.writeFile(io, ".git/objects/tmp_fresh", "x");
    return repo;
}

/// The object directory's files and `.git/shallow`, as text.
fn state(repo: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var objects = try repo.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var walker = try objects.walk(gpa);
    defer walker.deinit();
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    while (try walker.next(io)) |entry| try paths.append(gpa, try std.mem.concat(gpa, u8, &.{ entry.path, if (entry.kind == .directory) "/" else "" }));
    std.mem.sort([]u8, paths.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (paths.items) |p| try out.print(gpa, "{s}\n", .{p});
    const shallow = repo.readFile(io, ".git/shallow") catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, "(no shallow file)\n"),
        else => |e| return e,
    };
    defer gpa.free(shallow);
    try out.appendSlice(gpa, shallow);
    return out.toOwnedSlice(gpa);
}

const Case = struct { args: []const []const u8, options: prune_mod.PruneOptions };

fn pruneInFormat(format: testgit.RefFormat) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const cases = [_]Case{
        .{ .args = &.{}, .options = .{} },
        .{ .args = &.{"--expire=2.weeks.ago"}, .options = .{ .expire = now - 14 * day } },
        .{ .args = &.{"--expire=never"}, .options = .{ .expire = 0 } },
        .{ .args = &.{"--expire=200.days.ago"}, .options = .{ .expire = now - 200 * day } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try fixture(format, now);
        defer theirs.deinit();
        var ours = try fixture(format, now);
        defer ours.deinit();
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.append(gpa, "prune");
        try args.appendSlice(gpa, case.args);
        try theirs.exec(io, args.items);
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        _ = try prune_mod.prune(gpa, io, &native, case.options);
        const expected = try state(&theirs);
        defer gpa.free(expected);
        const actual = try state(&ours);
        defer gpa.free(actual);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("prune case {d}\n", .{n});
            return err;
        };
    }
}

test "prune removes what git's does: refs, reflogs, every worktree's HEAD, index and reflogs, recent objects and what they reach, prune-packed, temporary files, the shallow boundary, in both ref formats" {
    try testgit.eachRefFormat(pruneInFormat);
}

test "a dry run removes nothing" {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var repo = try fixture(.files, now);
    defer repo.deinit();
    const before = try state(&repo);
    defer gpa.free(before);
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    const report = try prune_mod.prune(gpa, io, &native, .{ .dry_run = true });
    try std.testing.expect(report.objects.pruned != 0 and report.objects.packed_removed != 0 and report.shallow_removed == 1);
    const after = try state(&repo);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "precious objects are never pruned" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try commitAt(&repo, testgit.fixture_date, "one");
    try repo.exec(io, &.{ "config", "extensions.preciousObjects", "true" });
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.exec(io, &.{"prune"}));
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectError(error.PreciousObjects, prune_mod.prune(gpa, io, &native, .{}));
}

test "gc.pruneExpire as git's gc reads it" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const clock: @import("../text.zig").date.Context = .{ .now = .fromNanoseconds(1_700_000_000 * std.time.ns_per_s) };
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectEqual(@as(?gc.Expiry, 1_700_000_000 - 14 * day), try prune_mod.pruneExpiry(&native, clock));
    try native.editConfig(io, &.{.{ .name = "gc.pruneExpire", .value = "never" }}, .{});
    try std.testing.expectEqual(@as(?gc.Expiry, null), try prune_mod.pruneExpiry(&native, clock));
    try native.editConfig(io, &.{.{ .name = "gc.pruneExpire", .value = "now" }}, .{});
    try std.testing.expectEqual(@as(?gc.Expiry, gc.expire_all), try prune_mod.pruneExpiry(&native, clock));
}
