//! git's own file monitor daemon against git: a stand-in daemon listens
//! where git's does and answers git and this package alike, and what each
//! asked, what status reports, what the index vouches for and the token it
//! keeps are compared; then git's real daemon, where git has one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("checkout.zig");
const index_mod = @import("../index/index.zig");
const fsmonitor = @import("fsmonitor.zig");
const fs = @import("../fs/fs.zig");
const pkt_line = @import("../codec.zig").pkt_line;

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

/// A daemon that answers every question with `reply`, raw bytes, and
/// keeps each question it was asked. It listens on the repository's
/// `.git/fsmonitor--daemon.ipc`, where git looks for its own.
const FakeDaemon = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    path: []u8,
    task: Io.Future(void),
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    /// The bytes written back, pkt-lines and all; borrowed.
    reply: []const u8 = "",
    /// Each question, one per line.
    asked: std.ArrayList(u8) = .empty,

    fn start(gpa: Allocator, io: Io, r: *testgit.Repo) !*FakeDaemon {
        if (builtin.os.tag == .windows or !Io.net.has_unix_sockets) return error.SkipZigTest;
        const top = try r.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(top);
        const absolute = try std.fs.path.join(gpa, &.{ top, ".git", "fsmonitor--daemon.ipc" });
        defer gpa.free(absolute);
        // As git names it, from the working directory, where the absolute
        // name is past what a socket address holds.
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        const path = try std.fs.path.relativeAllocPosix(gpa, cwd, cwd, absolute);
        errdefer gpa.free(path);
        if (path.len >= @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len) return error.SkipZigTest;
        const address: Io.net.UnixAddress = .{ .path = path };
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);
        const d = try gpa.create(FakeDaemon);
        errdefer gpa.destroy(d);
        d.* = .{ .gpa = gpa, .io = io, .listener = listener, .path = path, .task = undefined };
        d.task = io.concurrent(serve, .{d}) catch return error.SkipZigTest;
        return d;
    }

    fn stop(d: *FakeDaemon) void {
        const io = d.io;
        d.stopping.store(true, .release);
        const address: Io.net.UnixAddress = .{ .path = d.path };
        if (address.connect(io)) |stream| stream.close(io) else |_| {}
        d.task.await(io);
        d.listener.deinit(io);
        d.asked.deinit(d.gpa);
        d.gpa.free(d.path);
        d.gpa.destroy(d);
    }

    fn answer(d: *FakeDaemon, reply: []const u8) void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        d.reply = reply;
    }

    /// The questions so far, the caller's.
    fn questions(d: *FakeDaemon, gpa: Allocator) ![]u8 {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        return gpa.dupe(u8, d.asked.items);
    }

    fn serve(d: *FakeDaemon) void {
        while (!d.stopping.load(.acquire)) {
            const stream = d.listener.accept(d.io) catch return;
            defer stream.close(d.io);
            if (d.stopping.load(.acquire)) return;
            // glint-ignore: Z026 -- a question that breaks off is its client's to report; the daemon takes the next
            d.handle(stream) catch {};
        }
    }

    fn handle(d: *FakeDaemon, stream: Io.net.Stream) !void {
        const io = d.io;
        const read_buffer = try d.gpa.alloc(u8, pkt_line.max_line);
        defer d.gpa.free(read_buffer);
        var reader = stream.reader(io, read_buffer);
        var question: std.ArrayList(u8) = .empty;
        defer question.deinit(d.gpa);
        while (true) switch (try pkt_line.read(&reader.interface)) {
            .data => |data| try question.appendSlice(d.gpa, data),
            else => break,
        };
        d.mutex.lockUncancelable(io);
        defer d.mutex.unlock(io);
        // A time is the first question's, git's and this package's alike.
        const timed = question.items.len != 0 and for (question.items) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true;
        try d.asked.print(d.gpa, "{s}\n", .{if (timed) "<time>" else question.items});
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(d.reply);
        try writer.interface.flush();
    }
};

/// One repository for git and one for this package, each with
/// `core.fsmonitor=true` and a stand-in daemon.
const Pair = struct {
    gpa: Allocator,
    git: testgit.Repo,
    ours: testgit.Repo,
    git_daemon: *FakeDaemon,
    our_daemon: *FakeDaemon,
    written: i96 = 1_000_000_000,

    fn init(gpa: Allocator, io: Io, pair: *Pair, value: ?[]const u8) !void {
        pair.gpa = gpa;
        pair.written = 1_000_000_000;
        pair.git = try testgit.Repo.init(gpa, io, &.{});
        errdefer pair.git.deinit();
        pair.ours = try testgit.Repo.init(gpa, io, &.{});
        errdefer pair.ours.deinit();
        try pair.writeBoth(io, "a", "a\n");
        try pair.writeBoth(io, "b", "b\n");
        try pair.writeBoth(io, "d/c", "c\n");
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            r.defaults = settings;
            try r.exec(io, &.{ "add", "-A" });
            try r.exec(io, &.{ "commit", "-q", "-m", "base" });
            if (value) |v| {
                try r.exec(io, &.{ "config", "core.fsmonitor", v });
            } else {
                // A bare name: no `=`.
                const config = try r.readFile(io, ".git/config");
                defer gpa.free(config);
                const bare = try std.mem.concat(gpa, u8, &.{ config, "[core]\n\tfsmonitor\n" });
                defer gpa.free(bare);
                try r.writeFile(io, ".git/config", bare);
            }
        }
        pair.git_daemon = try FakeDaemon.start(gpa, io, &pair.git);
        errdefer pair.git_daemon.stop();
        pair.our_daemon = try FakeDaemon.start(gpa, io, &pair.ours);
    }

    fn deinit(pair: *Pair) void {
        pair.our_daemon.stop();
        pair.git_daemon.stop();
        pair.ours.deinit();
        pair.git.deinit();
        pair.* = undefined;
    }

    fn answer(pair: *Pair, reply: []const u8) void {
        pair.git_daemon.answer(reply);
        pair.our_daemon.answer(reply);
    }

    fn writeBoth(pair: *Pair, io: Io, path: []const u8, bytes: []const u8) !void {
        pair.written += 1;
        const when: Io.File.SetTimestampsOptions = .{ .modify_timestamp = .{ .new = .{ .nanoseconds = pair.written * std.time.ns_per_s } } };
        for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| {
            try r.writeFile(io, path, bytes);
            try fs.setTimestamps(io, r.dir, path, when);
        }
    }

    /// git's status in its repository and this package's in ours, each
    /// writing its index, then the report, what each index vouches for,
    /// its token and the daemons' questions compared.
    fn status(pair: *Pair, io: Io) !void {
        const gpa = pair.gpa;
        const want = try pair.git.run(io, &.{ "status", "--porcelain", "--untracked-files=no" });
        defer gpa.free(want);
        const got = try ourStatus(gpa, io, &pair.ours);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
        const want_valid = try pair.git.run(io, &.{ "ls-files", "-f" });
        defer gpa.free(want_valid);
        const got_valid = try pair.ours.run(io, &.{ "ls-files", "-f" });
        defer gpa.free(got_valid);
        try std.testing.expectEqualStrings(want_valid, got_valid);
        const want_token = try tokenOf(gpa, io, &pair.git);
        defer if (want_token) |t| gpa.free(t);
        const got_token = try tokenOf(gpa, io, &pair.ours);
        defer if (got_token) |t| gpa.free(t);
        try std.testing.expectEqualStrings(want_token orelse "(none)", got_token orelse "(none)");
        const want_asked = try pair.git_daemon.questions(gpa);
        defer gpa.free(want_asked);
        const got_asked = try pair.our_daemon.questions(gpa);
        defer gpa.free(got_asked);
        try std.testing.expectEqualStrings(want_asked, got_asked);
    }
};

/// This package's status in `r`, with the monitor the repository
/// configures, the index written when the monitor's state changed, as
/// git's status writes it.
fn ourStatus(gpa: Allocator, io: Io, r: *testgit.Repo) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const source = try fsmonitor.configured(arena.allocator(), repo.configuration(), repo.gitDirectory(), .{ .environ = &env });
    var result = try worktree.status(gpa, io, repo.workDirectory().?, .{ .index = index, .db = repo.objectDatabase() }, .{
        .rules = try repo.worktreeRules(),
        .head_tree = try repo.headTree(io),
        .untracked = .no,
        .fsmonitor = source,
    });
    defer result.deinit();
    if (index.fsmonitor_changed) try locked_index.commit(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (result.entries) |e| try out.print(gpa, "{c}{c} {s}\n", .{ code(e.staged), code(e.unstaged), e.path });
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

fn tokenOf(gpa: Allocator, io: Io, r: *testgit.Repo) !?[]u8 {
    const git_dir = try r.gitDir(io);
    defer git_dir.close(io);
    var index = try index_mod.Index.read(gpa, io, git_dir, "index", .{ .git_dir = git_dir, .kind = .sha1 });
    defer index.deinit();
    const t = index.fsmonitor_token orelse return null;
    // A first token is a time, git's and this package's alike.
    for (t) |c| {
        if (!std.ascii.isDigit(c)) break;
    } else if (t.len != 0) return try gpa.dupe(u8, "<time>");
    return try gpa.dupe(u8, t);
}

/// `reply` as the daemon writes it: one data line and a flush.
fn line(comptime data: []const u8) []const u8 {
    return std.fmt.comptimePrint("{x:0>4}", .{data.len + 4}) ++ data ++ "0000";
}

test "git's daemon answers as git takes its answers: tokens, paths, directories, the trivial answer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, "true");
    defer pair.deinit();

    // The first question is asked with a time, and the answer vouches for
    // everything status then looks at.
    pair.answer(line("t1\x00"));
    try pair.status(io);

    // Two files change and the daemon names one: the other is not seen.
    try pair.writeBoth(io, "a", "a changed\n");
    try pair.writeBoth(io, "d/c", "c changed\n");
    pair.answer(line("t2\x00a\x00"));
    try pair.status(io);

    // A directory, and a last path with no NUL after it.
    pair.answer(line("t3\x00d/\x00b"));
    try pair.status(io);

    // A lone `/`: everything is looked at.
    try pair.writeBoth(io, "b", "b changed\n");
    pair.answer(line("t4\x00/\x00"));
    try pair.status(io);

    // The answer spread over lines, and ended by a delim.
    pair.answer("0007t5\x00" ++ "0006a\x00" ++ "0001");
    try pair.status(io);

    // An empty line ends the answer before the rest.
    try pair.writeBoth(io, "a", "a again\n");
    pair.answer("0007t6\x00" ++ "0004" ++ "0006a\x000000");
    try pair.status(io);
}

test "a daemon that breaks off its answer is no answer: everything looked at, builtin:fake kept" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, "true");
    defer pair.deinit();
    pair.answer(line("t1\x00"));
    try pair.status(io);
    const broken = [_][]const u8{
        // The end of the stream before a flush.
        "0007t2\x00",
        // A length that is not hexadecimal, and `0003`.
        "00x7t2\x000000",
        "0003",
        // Nothing at all.
        "",
    };
    for (broken, 0..) |reply, i| {
        var content: [16]u8 = undefined;
        try pair.writeBoth(io, "b", try std.mem.print(&content, "b {d}\n", .{i}));
        pair.answer(reply);
        try pair.status(io);
        pair.answer(line("again\x00"));
        try pair.status(io);
    }
}

test "core.fsmonitor turns the daemon on and off as git reads it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const values = [_]?[]const u8{ "true", "TRUE", "yes", "on", "1", "2", "-1", "1k", null, "false", "no", "off", "0", "" };
    for (values) |value| {
        var pair: Pair = undefined;
        try Pair.init(gpa, io, &pair, value);
        defer pair.deinit();
        pair.answer(line("t1\x00"));
        try pair.status(io);
        try pair.writeBoth(io, "a", "a changed\n");
        pair.answer(line("t2\x00a\x00"));
        try pair.status(io);
    }
}

test "with no daemon listening every file is looked at and builtin:fake is kept" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    r.defaults = settings;
    try r.writeFile(io, "a", "a\n");
    try r.exec(io, &.{ "add", "-A" });
    try r.exec(io, &.{ "commit", "-q", "-m", "base" });
    try r.exec(io, &.{ "config", "core.fsmonitor", "true" });
    try r.writeFile(io, "a", "a changed\n");
    const report = try ourStatus(gpa, io, &r);
    defer gpa.free(report);
    try std.testing.expectEqualStrings(" M a\n", report);
    const token = (try tokenOf(gpa, io, &r)).?;
    defer gpa.free(token);
    try std.testing.expectEqualStrings("builtin:fake", token);
}

test "git's own daemon, where git has one, answers this package as it answers git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    r.defaults = settings;
    try r.writeFile(io, "a", "a\n");
    try r.writeFile(io, "d/b", "b\n");
    try r.exec(io, &.{ "add", "-A" });
    try r.exec(io, &.{ "commit", "-q", "-m", "base" });
    try r.exec(io, &.{ "config", "core.fsmonitor", "true" });
    r.report_failures = false;
    // A git built without the daemon says so, and the test has nothing to
    // hold this package to.
    var started = try r.capture(io, &.{ "fsmonitor--daemon", "start" });
    const running = started.code == 0;
    started.deinit(gpa);
    if (!running) return error.SkipZigTest;
    defer if (r.capture(io, &.{ "fsmonitor--daemon", "stop" })) |stopped| {
        var s = stopped;
        s.deinit(gpa);
    } else |_| {};
    r.report_failures = true;

    const first = try ourStatus(gpa, io, &r);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("", first);
    const token = (try tokenOf(gpa, io, &r)).?;
    defer gpa.free(token);
    try std.testing.expect(std.mem.startsWith(u8, token, "builtin:") and !std.mem.eql(u8, token, "builtin:fake"));

    // A change the daemon sees, by this package and then by git reading
    // this package's index.
    try r.writeFile(io, "d/b", "b changed\n");
    var report: []u8 = &.{};
    defer gpa.free(report);
    // The daemon hears of a change a moment after it is made.
    for (0..100) |_| {
        gpa.free(report);
        report = try ourStatus(gpa, io, &r);
        if (report.len != 0) break;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    try std.testing.expectEqualStrings(" M d/b\n", report);
    const git_report = try r.run(io, &.{ "status", "--porcelain", "--untracked-files=no" });
    defer gpa.free(git_report);
    try std.testing.expectEqualStrings(report, git_report);
}
