//! `rev_parse` against `git rev-parse`: the same expressions, the same
//! objects or the same refusal.

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const gitdate = @import("../text.zig").date;
const rev_parse = @import("rev_parse.zig");
const Repository = @import("repo.zig").Repository;

const Oid = hash.Oid;
const testing = std.testing;
const testgit = @import("../testing/git.zig");

test "every expression reads as git rev-parse reads it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    // Each commit a minute after the last, so the date order has no ties.
    var clock: u64 = 1_700_000_000;
    for (0..4) |i| {
        clock += 60;
        var date: [32]u8 = undefined;
        try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&date, "{d} +0000", .{clock}));
        var name: [16]u8 = undefined;
        const file = try std.mem.print(&name, "f{d}", .{i});
        try r.writeFile(io, file, file);
        try r.writeFile(io, "dir/deep", file);
        try r.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try r.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "change number {d}", .{i}) });
    }
    try r.exec(io, &.{ "tag", "light", "HEAD~2" });
    try r.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1", "HEAD~1" });
    clock += 60;
    var side_date: [32]u8 = undefined;
    try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&side_date, "{d} +0000", .{clock}));
    try r.exec(io, &.{ "checkout", "-q", "-b", "side", "HEAD~2" });
    try r.writeFile(io, "side", "side");
    try r.exec(io, &.{ "add", "side" });
    try r.exec(io, &.{ "commit", "-q", "-m", "side work" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    clock += 60;
    var merge_date: [32]u8 = undefined;
    try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&merge_date, "{d} +0000", .{clock}));
    try r.exec(io, &.{ "merge", "-q", "--no-edit", "side" });
    try r.exec(io, &.{ "checkout", "-q", "side" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    try r.exec(io, &.{ "remote", "add", "origin", "https://example.invalid/r.git" });
    try r.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD~1" });
    try r.exec(io, &.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    try r.exec(io, &.{ "config", "branch.main.remote", "origin" });
    try r.exec(io, &.{ "config", "branch.main.merge", "refs/heads/main" });
    const short = try r.line(io, &.{ "rev-parse", "--short=7", "HEAD~2" });
    defer gpa.free(short);
    const described = try r.line(io, &.{ "describe", "--tags", "--long", "HEAD" });
    defer gpa.free(described);

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        "HEAD",                "@",             "main",            "side",            "refs/heads/side",
        "light",               "v1",            "v1^{}",           "v1^{commit}",     "v1^{tree}",
        "v1^{tag}",            "HEAD^",         "HEAD^1",          "HEAD^2",          "HEAD^0",
        "HEAD~",               "HEAD~3",        "HEAD^2~1",        "HEAD^{tree}",     "HEAD:f0",
        "HEAD:dir",            "HEAD:dir/deep", "HEAD~1:dir/deep", "v1:f1",           ":f0",
        ":0:dir/deep",         "HEAD@{0}",      "HEAD@{1}",        "main@{1}",        "@{1}",
        "@{-1}",               "@{-2}",         "@{u}",            "main@{upstream}", "@{push}",
        "origin/main",         "origin",        ":/number 2",      ":/^side",         ":/!-number",
        "HEAD^{/number [01]}", short,           described,         "HEAD:",           "light~1",
    };
    for (cases) |expr| {
        const theirs = r.line(io, &.{ "rev-parse", "--verify", "--quiet", expr }) catch |err| {
            std.debug.print("git refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        defer gpa.free(theirs);
        const ours = rev_parse.resolve(gpa, io, repo.revisionSource(), expr) catch |err| {
            std.debug.print("relic refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        testing.expectEqualStrings(theirs, ours.hex(&hex)) catch |err| {
            std.debug.print("for {s}\n", .{expr});
            return err;
        };
    }
    // What git refuses is refused.
    for ([_][]const u8{ "nowhere", "HEAD~99", "HEAD^3", "HEAD:missing", "v1^{blob}", ":/no such message" }) |expr| {
        _ = try arena.alloc(u8, 1);
        const refused = if (rev_parse.resolve(gpa, io, repo.revisionSource(), expr)) |_| false else |_| true;
        try testing.expect(refused);
    }
}

test "git 2.56, @{push} is what git rev-parse makes of it: push.default, push refspecs, a mirror, and a push remote given as a URL" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 56);
    const a = "https://example.invalid/a.git";
    const b = "https://example.invalid/b.git";
    const Case = struct { config: []const []const u8 };
    const cases = [_]Case{
        .{ .config = &.{} },
        .{ .config = &.{"remote.pushDefault=other"} },
        .{ .config = &.{ "remote.pushDefault=other", "push.default=current" } },
        .{ .config = &.{ "remote.pushDefault=other", "push.default=upstream" } },
        .{ .config = &.{"push.default=nothing"} },
        .{ .config = &.{"push.default=matching"} },
        .{ .config = &.{"push.default=sideways"} },
        .{ .config = &.{ "remote.pushDefault=other", "remote.other.push=refs/heads/main:refs/heads/feature" } },
        .{ .config = &.{ "remote.pushDefault=other", "remote.other.push=refs/heads/side:refs/heads/feature" } },
        .{ .config = &.{ "remote.pushDefault=other", "remote.other.mirror=true" } },
        // A URL: the one remote pushing there tracks it (git 2.56).
        .{ .config = &.{ "branch.main.pushRemote=" ++ b, "push.default=current" } },
        .{ .config = &.{ "branch.main.pushRemote=" ++ a, "push.default=current" } },
        // Two remotes push there: none does.
        .{ .config = &.{ "branch.main.pushRemote=" ++ a, "push.default=current", "remote.other.pushurl=" ++ a } },
        // The remote's push URL is what is matched.
        .{ .config = &.{ "branch.main.pushRemote=https://example.invalid/c.git", "push.default=current", "remote.other.pushurl=https://example.invalid/c.git" } },
    };
    for (cases) |case| {
        var r = try testgit.Repo.init(gpa, io, &.{});
        defer r.deinit();
        for ([_][]const u8{ "one", "two", "three" }) |message| try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", message });
        try r.exec(io, &.{ "remote", "add", "origin", a });
        try r.exec(io, &.{ "remote", "add", "other", b });
        try r.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD~1" });
        try r.exec(io, &.{ "update-ref", "refs/remotes/other/main", "HEAD~2" });
        try r.exec(io, &.{ "update-ref", "refs/remotes/other/feature", "HEAD" });
        try r.exec(io, &.{ "config", "branch.main.remote", "origin" });
        try r.exec(io, &.{ "config", "branch.main.merge", "refs/heads/main" });
        for (case.config) |setting| {
            const eq = std.mem.findScalar(u8, setting, '=').?;
            try r.exec(io, &.{ "config", setting[0..eq], setting[eq + 1 ..] });
        }
        errdefer std.debug.print("case: {s}\n", .{if (case.config.len == 0) "simple" else case.config[case.config.len - 1]});
        r.report_failures = false;
        const theirs: ?[]u8 = r.line(io, &.{ "rev-parse", "--verify", "--quiet", "@{push}" }) catch null;
        defer if (theirs) |t| gpa.free(t);
        var repo = try Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        const ours: ?Oid = rev_parse.resolve(gpa, io, repo.revisionSource(), "@{push}") catch |err| switch (err) {
            error.BadRevision => null,
            else => return err,
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        try testing.expectEqualStrings(theirs orelse "(refused)", if (ours) |oid| oid.hex(&hex) else "(refused)");
    }
}

test "@{-N} reads the branch a checkout left as a name or an object name, never as an expression" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    try r.exec(io, &.{ "branch", "other" });
    // Left detached, then left a branch: git names an object, then a ref.
    try r.exec(io, &.{ "checkout", "-q", "--detach" });
    try r.exec(io, &.{ "checkout", "-q", "other" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    // The count as `strtol` reads it: spaces and a sign before it, zeros.
    for ([_][]const u8{ "@{-1}", "@{-2}", "@{-3}", "@{-01}", "@{- 2}", "@{-+3}" }) |expr| {
        const theirs = try r.line(io, &.{ "rev-parse", expr });
        defer gpa.free(theirs);
        var hex: [hash.max_hex_len]u8 = undefined;
        try testing.expectEqualStrings(theirs, (try rev_parse.resolve(gpa, io, repo.revisionSource(), expr)).hex(&hex));
    }

    // A log line naming `@{-1}` as where it came from is no name at all.
    const head_text = try r.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const line = try gpa.print("{s} {s} A <a@b> 1 +0000\tcheckout: moving from @{{-1}} to main\n", .{ head_text, head_text });
    defer gpa.free(line);
    const log = try r.readFile(io, ".git/logs/HEAD");
    defer gpa.free(log);
    const looped = try std.mem.concat(gpa, u8, &.{ log, line });
    defer gpa.free(looped);
    try r.writeFile(io, ".git/logs/HEAD", looped);
    r.report_failures = false;
    try testing.expectError(error.GitFailed, r.run(io, &.{ "rev-parse", "--verify", "-q", "@{-1}" }));
    try testing.expectError(error.BadRevision, rev_parse.resolve(gpa, io, repo.revisionSource(), "@{-1}"));
}

test "a reflog entry chosen by a date is the one git rev-parse chooses" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    // Two days of history an hour apart, read on the third day at 12:00.
    const start: i64 = 1_700_000_000;
    const now = start + 2 * 24 * 60 * 60;
    var now_text: [32]u8 = undefined;
    try r.isolated.?.put("GIT_TEST_DATE_NOW", try std.mem.print(&now_text, "{d}", .{now}));
    try r.isolated.?.put("TZ", "UTC");
    for (0..6) |i| {
        var date: [32]u8 = undefined;
        try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&date, "{d} +0000", .{start + @as(i64, @intCast(i)) * 3 * 60 * 60})); // safe: below 6
        var name: [16]u8 = undefined;
        const file = try std.mem.print(&name, "f{d}", .{i});
        try r.writeFile(io, file, file);
        try r.exec(io, &.{ "add", "-A" });
        try r.exec(io, &.{ "commit", "-q", "-m", file });
        if (i == 2) try r.exec(io, &.{ "branch", "side" });
    }

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var exact: [48]u8 = undefined;
    var stamp: [48]u8 = undefined;
    var iso: [48]u8 = undefined;
    const cases = [_][]const u8{
        "main@{now}",
        "main@{yesterday}",
        "@{2.days.ago}",
        "HEAD@{1.day.ago}",
        "main@{40 hours ago}",
        "main@{1.year.ago}",
        "side@{1.week.ago}",
        "side@{now}",
        try std.mem.print(&exact, "main@{{{d}}}", .{start + 3 * 60 * 60}),
        try std.mem.print(&stamp, "main@{{{d}}}", .{start + 4 * 60 * 60}),
        try std.mem.print(&iso, "main@{{2023-11-14 23:30:00 +0000}}", .{}),
        "main@{last tuesday}",
    };
    for (cases) |expr| {
        const theirs = r.line(io, &.{ "rev-parse", "--verify", "--quiet", expr }) catch |err| {
            std.debug.print("git refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        defer gpa.free(theirs);
        const ours = rev_parse.resolveAt(gpa, io, repo.revisionSource(), expr, .{ .now = gitdate.timestamp(now) }) catch |err| {
            std.debug.print("relic refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        testing.expectEqualStrings(theirs, ours.hex(&hex)) catch |err| {
            std.debug.print("for {s}\n", .{expr});
            return err;
        };
    }
    // Words that mean nothing are no date, for git and here.
    r.report_failures = false;
    try testing.expectError(error.GitFailed, r.run(io, &.{ "rev-parse", "--verify", "--quiet", "main@{whenever}" }));
    try testing.expectError(error.BadRevision, rev_parse.resolveAt(gpa, io, repo.revisionSource(), "main@{whenever}", .{ .now = gitdate.timestamp(now) }));
    // Without a clock the `Io`'s is read.
    _ = try rev_parse.resolve(gpa, io, repo.revisionSource(), "main@{yesterday}");
}

test "revision parsing preserves allocation resource failures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer repo.deinit(io);
    const commit = try repo.objectDatabase().write(io, .commit, "tree " ++ @as([40]u8, @splat('0')) ++ "\nparent " ++ @as([40]u8, @splat('1')) ++ "\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\n\nsubject\n");
    var hex: [hash.max_hex_len]u8 = undefined;
    const text = commit.hex(&hex);
    try repo.gitDirectory().get().writeFile(io, .{ .sub_path = "refs/heads/main", .data = text });
    const Check = struct {
        fn run(allocator: Allocator, repository: *Repository, expr: []const u8, expected: Oid) !void {
            const got = try rev_parse.resolve(allocator, std.testing.io, repository.revisionSource(), expr);
            try std.testing.expect(got.eql(expected));
        }
    };
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{ &repo, "HEAD", commit });
    }
    const parent_expr = try gpa.print("{s}^", .{text});
    defer gpa.free(parent_expr);
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{ &repo, parent_expr, try Oid.parse(.sha1, &@as([40]u8, @splat('1'))) });
    }
}

test "revision parsing preserves I/O and cancellation resource failures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer repo.deinit(io);
    const faults = try shakedown.FaultIo.init(gpa, io, .{});
    defer faults.deinit();
    const failing_io = faults.io();
    for ([_]Io.File.ReadPositionalError{ error.InputOutput, error.Canceled }) |failure| {
        const plan = [_]shakedown.IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .fail = failure }, .times = 0 }};
        try faults.setPlan(&plan);
        try std.testing.expectError(failure, rev_parse.resolve(gpa, failing_io, repo.revisionSource(), "HEAD"));
        try std.testing.expectError(failure, rev_parse.resolve(gpa, failing_io, repo.revisionSource(), "@{0}"));
    }
}

test "a walk back from a commit reads each commit once per repository handle" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    for (0..30) |i| {
        var name: [16]u8 = undefined;
        try r.writeFile(io, "f", try std.mem.print(&name, "{d}\n", .{i}));
        try r.exec(io, &.{ "commit", "-q", "-am", "c", "--allow-empty" });
        if (i == 0) try r.exec(io, &.{ "add", "f" });
    }
    try r.exec(io, &.{ "repack", "-adq" });
    const expected = try r.line(io, &.{ "rev-parse", "main~25" });
    defer gpa.free(expected);
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    try testing.expectEqualStrings(expected, (try rev_parse.resolve(gpa, io, repo.revisionSource(), "main~25")).hex(&hex));
    // Every object here is in the one pack, and every read of one asks it.
    const before = repo.objectDatabase().stats.pack_scans;
    try testing.expectEqualStrings(expected, (try rev_parse.resolve(gpa, io, repo.revisionSource(), "main~25")).hex(&hex));
    try testing.expectEqualStrings(expected, (try rev_parse.resolve(gpa, io, repo.revisionSource(), "main~24^")).hex(&hex));
    // Each expression asks the object it starts from, and `^` the one it
    // starts from, for its type; no commit is read again.
    try testing.expect(repo.objectDatabase().stats.pack_scans - before <= 3);
}
