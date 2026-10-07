//! The file monitor against git's: the same hook answers both, and what
//! status reports, what the index vouches for and the token it keeps are
//! compared.

const std = @import("std");
const suite = @import("../testing/helpers.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo.zig");
const worktree = @import("../worktree.zig");
const index_mod = @import("../index.zig");
const fsmonitor = @import("fsmonitor.zig");
const fs = @import("../repo/fs.zig");

/// testgit's settings without its `core.fsmonitor=`, so the repository's
/// own decides.
const settings = blk: {
    var out: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < testgit.default_settings.len) : (i += 2) {
        if (std.mem.startsWith(u8, testgit.default_settings[i + 1], "core.fsmonitor=")) continue;
        out = out ++ testgit.default_settings[i..][0..2];
    }
    break :blk out;
};

/// Two copies of one repository, `git` for git and `ours` for this
/// package, each with the fixture as its `core.fsmonitor` hook.
const Pair = struct {
    gpa: Allocator,
    env: std.process.Environ.Map,
    git: testgit.Repo,
    ours: testgit.Repo,
    /// The modification time the next file written gets, long ago: no entry
    /// is ever as new as the index, so git rewrites the index for the
    /// monitor's sake alone and never for a racy timestamp.
    written: i96 = 1_000_000_000,

    fn init(gpa: Allocator, io: Io, pair: *Pair, version: ?[]const u8) !void {
        pair.gpa = gpa;
        pair.env = try testgit.programEnviron(gpa);
        errdefer pair.env.deinit();
        pair.git = try testgit.Repo.init(gpa, io, &.{});
        errdefer pair.git.deinit();
        pair.ours = try testgit.Repo.init(gpa, io, &.{});
        errdefer pair.ours.deinit();
        const hook = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "fsmonitor");
        defer gpa.free(hook);
        pair.written = 1_000_000_000;
        try pair.writeBoth(io, "a", "a\n");
        try pair.writeBoth(io, "b", "b\n");
        try pair.writeBoth(io, "d/c", "c\n");
        try pair.writeBoth(io, "d/e/f", "f\n");
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            r.defaults = settings;
            try r.exec(io, &.{ "add", "-A" });
            try r.exec(io, &.{ "commit", "-q", "-m", "base" });
            try r.exec(io, &.{ "config", "core.fsmonitor", hook });
            if (version) |v| try r.exec(io, &.{ "config", "core.fsmonitorHookVersion", v });
        }
    }

    fn deinit(pair: *Pair) void {
        pair.ours.deinit();
        pair.git.deinit();
        pair.env.deinit();
        pair.* = undefined;
    }

    /// Both hooks' answer to a question of `version`.
    fn answer(pair: *Pair, io: Io, version: []const u8, bytes: []const u8) !void {
        var buf: [32]u8 = undefined;
        const path = try std.mem.print(&buf, ".git/fsmonitor-v{s}", .{version});
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.writeFile(io, path, bytes);
    }

    fn writeBoth(pair: *Pair, io: Io, path: []const u8, bytes: []const u8) !void {
        pair.written += 1;
        const when: Io.File.SetTimestampsOptions = .{ .modify_timestamp = .{ .new = .{ .nanoseconds = pair.written * std.time.ns_per_s } } };
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.writeFile(io, path, bytes);
            try fs.setTimestamps(io, r.dir, path, when);
        }
    }

    /// `git status --porcelain` in git's copy and this package's status in
    /// ours, the index written after each, and the two compared: the
    /// report, what each index vouches for (`ls-files -f`), the token, and
    /// the versions the hook was asked with.
    fn status(pair: *Pair, io: Io, untracked: worktree.StatusOptions.Untracked) !void {
        const gpa = pair.gpa;
        const flag = if (untracked == .no) "--untracked-files=no" else "--untracked-files=all";
        const want = try pair.git.run(io, &.{ "status", "--porcelain", flag });
        defer gpa.free(want);
        const got = try pair.ourStatus(io, untracked);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
        try pair.expectSameIndex(io);
    }

    fn ourStatus(pair: *Pair, io: Io, untracked: worktree.StatusOptions.Untracked) ![]u8 {
        return pair.statusIn(io, &pair.ours, untracked);
    }

    /// This package's status in `r`, with the hook, the index written after.
    fn statusIn(pair: *Pair, io: Io, r: *testgit.Repo, untracked: worktree.StatusOptions.Untracked) ![]u8 {
        const gpa = pair.gpa;
        var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        var index = try repo.openIndex(io);
        defer index.deinit();
        const source = (try fsmonitor.configured(repo.configuration(), .{ .environ = &pair.env })).?;
        var result = try worktree.status(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
            .rules = try repo.worktreeRules(),
            .head_tree = try repo.headTree(io),
            .untracked = untracked,
            .fsmonitor = source,
        });
        defer result.deinit();
        // As git's status: written when the monitor's state changed.
        if (index.fsmonitor_changed) try repo.writeIndex(io, &index);
        return porcelain(gpa, result.entries);
    }

    fn expectSameIndex(pair: *Pair, io: Io) !void {
        const gpa = pair.gpa;
        const want = try pair.git.run(io, &.{ "ls-files", "-f" });
        defer gpa.free(want);
        const got = try pair.ours.run(io, &.{ "ls-files", "-f" });
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
        const want_log = try versionsAsked(gpa, io, &pair.git);
        defer gpa.free(want_log);
        const got_log = try versionsAsked(gpa, io, &pair.ours);
        defer gpa.free(got_log);
        try std.testing.expectEqualStrings(want_log, got_log);
    }
};

/// The versions the hook was asked with, in order, and each token that was
/// not a time.
fn versionsAsked(gpa: Allocator, io: Io, r: *testgit.Repo) ![]u8 {
    const log = r.readFile(io, ".git/fsmonitor-log") catch return gpa.dupe(u8, "");
    defer gpa.free(log);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const space = std.mem.findScalar(u8, line, ' ') orelse line.len;
        const token = if (space < line.len) line[space + 1 ..] else "";
        const timed = token.len != 0 and for (token) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true;
        try out.print(gpa, "{s} {s}\n", .{ line[0..space], if (timed) "<time>" else token });
    }
    return out.toOwnedSlice(gpa);
}

fn tokenOf(gpa: Allocator, io: Io, r: *testgit.Repo) !?[]u8 {
    const git_dir = try r.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    const t = index.fsmonitor_token orelse return null;
    const token = try gpa.dupe(u8, t);
    return token;
}

fn porcelain(gpa: Allocator, entries: []const worktree.StatusEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (entries) |e| {
        if (e.unstaged == .untracked) {
            try out.print(gpa, "?? {s}\n", .{e.path});
            continue;
        }
        try out.print(gpa, "{c}{c} {s}\n", .{ code(e.staged), code(e.unstaged), e.path });
    }
    return out.toOwnedSlice(gpa);
}

fn code(change: worktree.Change) u8 {
    return switch (change) {
        .unmodified => ' ',
        .added => 'A',
        .modified => 'M',
        .deleted => 'D',
        .type_changed => 'T',
        .untracked => '?',
        .ignored => '!',
    };
}

test "a version 2 hook decides what status looks at, as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, null);
    defer pair.deinit();

    // The first question: everything is looked at, and vouched for after.
    try pair.answer(io, "2", "t1\x00");
    try pair.status(io, .all);
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
        const t = (try tokenOf(gpa, io, r)).?;
        defer gpa.free(t);
        try std.testing.expectEqualStrings("t1", t);
    }

    // Two files change and the monitor names one: the other is not seen.
    try pair.writeBoth(io, "a", "a changed\n");
    try pair.writeBoth(io, "d/c", "c changed\n");
    try pair.answer(io, "2", "t2\x00a\x00");
    try pair.status(io, .all);
    try pair.status(io, .no);

    // A directory named takes everything under it out.
    try pair.answer(io, "2", "t3\x00d/\x00");
    try pair.status(io, .no);

    // A lone `/` is no answer: everything is looked at.
    try pair.writeBoth(io, "b", "b changed\n");
    try pair.answer(io, "2", "t4\x00/");
    try pair.status(io, .all);
}

test "git believes what this package's index vouches for, and the other way round" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, "2");
    defer pair.deinit();

    try pair.answer(io, "2", "t1\x00");
    try pair.status(io, .all);
    // A change the monitor does not name: git, reading this package's
    // index, does not see it, and this package does not see it in git's.
    try pair.writeBoth(io, "d/e/f", "f changed\n");
    try pair.answer(io, "2", "t2\x00");
    const git_in_ours = try pair.ours.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(git_in_ours);
    try std.testing.expectEqualStrings("", git_in_ours);
    const ours_in_git = try pair.statusIn(io, &pair.git, .all);
    defer gpa.free(ours_in_git);
    try std.testing.expectEqualStrings("", ours_in_git);
}

test "an index git wrote with FSMN is written back byte for byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, "2");
    defer pair.deinit();
    try pair.answer(io, "2", "token\x00");
    try pair.git.exec(io, &.{ "status", "--porcelain" });
    try pair.writeBoth(io, "b", "b changed\n");
    try pair.answer(io, "2", "next\x00b\x00");
    try pair.git.exec(io, &.{ "status", "--porcelain" });

    const original = try pair.git.readFile(io, ".git/index");
    defer gpa.free(original);
    const git_dir = try pair.git.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", git_dir, .sha1);
    defer index.deinit();
    // The second answer changed nothing git writes the index for.
    try std.testing.expectEqualStrings("token", index.fsmonitor_token.?);
    for (index.entries.items) |entry| try std.testing.expect(entry.fsmonitor_valid);
    const written = try index.toBytes(.{});
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, original, written);
}

test "a version 1 hook, and a version 2 question falling back to version 1, as git asks them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]?[]const u8{ "1", null }) |version| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, version);
        defer pair.deinit();
        try pair.answer(io, "1", "");
        try pair.status(io, .all);
        try pair.writeBoth(io, "a", "a changed\n");
        try pair.writeBoth(io, "b", "b changed\n");
        try pair.answer(io, "1", "b\x00");
        try pair.status(io, .no);
        try pair.status(io, .all);
    }
}

const Feed = struct {
    paths: ?[]const []const u8,
    answers: bool = true,
    asked_with: [16]u8 = undefined,
    asked_len: usize = 0,

    fn source(f: *Feed) fsmonitor.Source {
        return .{ .changes = .{ .context = f, .queryFn = query } };
    }

    fn query(arena: Allocator, context: *anyopaque, since: []const u8) Allocator.Error!?fsmonitor.Changes {
        _ = arena;
        const f: *Feed = @ptrCast(@alignCast(context));
        f.asked_len = @min(since.len, f.asked_with.len);
        @memcpy(f.asked_with[0..f.asked_len], since[0..f.asked_len]);
        if (!f.answers) return null;
        return .{ .token = "fed", .paths = f.paths };
    }
};

test "a program's own change source decides what status looks at" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.writeFile(io, "a", "a\n");
    try r.writeFile(io, "b", "b\n");
    try r.exec(io, &.{ "add", "-A" });
    try r.exec(io, &.{ "commit", "-q", "-m", "base" });

    const Run = struct {
        fn status(io_: Io, repo_dir: *testgit.Repo, feed: *Feed, untracked: worktree.StatusOptions.Untracked) ![]u8 {
            const g = std.testing.allocator;
            var repo = try repo_mod.Repository.open(g, io_, repo_dir.dir, .{});
            defer repo.deinit(io_);
            var index = try repo.openIndex(io_);
            defer index.deinit();
            var result = try worktree.status(g, io_, repo.work_dir.?, &index, &repo.odb, .{
                .rules = try repo.worktreeRules(),
                .head_tree = try repo.headTree(io_),
                .untracked = untracked,
                .fsmonitor = feed.source(),
            });
            defer result.deinit();
            try repo.writeIndex(io_, &index);
            return porcelain(g, result.entries);
        }
    };
    var feed: Feed = .{ .paths = &.{} };
    const first = try Run.status(io, &r, &feed, .all);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("", first);

    try r.writeFile(io, "a", "a changed\n");
    try r.writeFile(io, "b", "b changed\n");
    feed = .{ .paths = &.{"a"} };
    const named = try Run.status(io, &r, &feed, .no);
    defer gpa.free(named);
    try std.testing.expectEqualStrings(" M a\n", named);
    try std.testing.expectEqualStrings("fed", feed.asked_with[0..feed.asked_len]);

    // No answer: everything is looked at.
    feed = .{ .paths = &.{}, .answers = false };
    const all = try Run.status(io, &r, &feed, .all);
    defer gpa.free(all);
    try std.testing.expectEqualStrings(" M a\n M b\n", all);
}

test "git's own daemon is refused by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.exec(io, &.{ "config", "core.fsmonitor", "true" });
    var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    try std.testing.expectError(error.FsmonitorDaemonUnsupported, fsmonitor.configured(repo.configuration(), .{ .environ = &env }));
}
