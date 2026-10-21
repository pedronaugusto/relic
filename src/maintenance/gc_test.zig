//! `pack-refs` and `reflog expire` held to git's: the same fixture built
//! twice, git's command run in one and relic's in the other, and what each
//! left compared.
const std = @import("std");
const date = @import("../text.zig").date;
const testgit = @import("../testing/git.zig");
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

/// Branches nested and not, a lightweight and an annotated tag and a tag
/// of a tag, a symbolic ref, refs packed already and one of them moved
/// since, so its loose file shadows the packed line.
fn refsFixture(format: testgit.RefFormat) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, format.initArgs());
    errdefer repo.deinit();
    const base: i64 = 1_700_000_000;
    try commitAt(&repo, base, "one");
    try repo.exec(io, &.{ "branch", "feature/a" });
    try repo.exec(io, &.{ "branch", "feature/b/c" });
    try repo.exec(io, &.{ "tag", "light" });
    try repo.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1" });
    try repo.exec(io, &.{ "tag", "-a", "-m", "nested", "v1-of-v1", "v1" });
    try repo.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    try repo.exec(io, &.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    try repo.exec(io, &.{ "pack-refs", "--include", "refs/heads/feature/*" });
    try commitAt(&repo, base + 10, "two");
    try repo.exec(io, &.{ "update-ref", "refs/heads/feature/a", "HEAD" });
    try repo.exec(io, &.{ "tag", "-a", "-m", "later", "v2" });
    try repo.exec(io, &.{ "update-ref", "refs/bisect/bad", "HEAD" });
    return repo;
}

/// Every file under `.git/refs`, and `packed-refs`, or `for-each-ref`'s
/// account of a reftable with its table count: what a pack leaves.
fn refsState(repo: *testgit.Repo, format: testgit.RefFormat) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const listed = try repo.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname) %(*objectname) %(symref)" });
    defer gpa.free(listed);
    try out.appendSlice(gpa, listed);
    switch (format) {
        .files => {
            const packed_refs = repo.readFile(io, ".git/packed-refs") catch |err| switch (err) {
                error.FileNotFound => try gpa.dupe(u8, "(none)\n"),
                else => |e| return e,
            };
            defer gpa.free(packed_refs);
            try out.appendSlice(gpa, packed_refs);
            var dir = try repo.dir.openDir(io, ".git/refs", .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            var paths: std.ArrayList([]u8) = .empty;
            defer {
                for (paths.items) |p| gpa.free(p);
                paths.deinit(gpa);
            }
            while (try walker.next(io)) |entry| try paths.append(gpa, try gpa.print("{t} {s}", .{ entry.kind, entry.path }));
            std.mem.sort([]u8, paths.items, {}, struct {
                fn less(_: void, a: []u8, b: []u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less);
            for (paths.items) |p| {
                try out.appendSlice(gpa, p);
                try out.append(gpa, '\n');
            }
        },
        .reftable => {
            const list = try repo.readFile(io, ".git/reftable/tables.list");
            defer gpa.free(list);
            try out.print(gpa, "tables: {d}\n", .{std.mem.count(u8, list, "\n")});
            var dir = try repo.dir.openDir(io, ".git/reftable", .{ .iterate = true });
            defer dir.close(io);
            var files: usize = 0;
            var it = dir.iterate();
            while (try it.next(io)) |_| files += 1;
            try out.print(gpa, "files: {d}\n", .{files});
        },
    }
    return out.toOwnedSlice(gpa);
}

const PackCase = struct { args: []const []const u8, options: gc.PackRefsOptions };

const pack_cases = [_]PackCase{
    .{ .args = &.{}, .options = .{} },
    .{ .args = &.{"--all"}, .options = .{ .include = &.{"*"} } },
    .{ .args = &.{ "--include", "refs/heads/feature/*", "--exclude", "refs/heads/feature/b/*" }, .options = .{ .include = &.{"refs/heads/feature/*"}, .exclude = &.{"refs/heads/feature/b/*"} } },
    .{ .args = &.{ "--all", "--no-prune" }, .options = .{ .include = &.{"*"}, .prune = false } },
};

fn packInFormat(format: testgit.RefFormat) !void {
    for (pack_cases, 0..) |case, n| {
        var theirs = try refsFixture(format);
        defer theirs.deinit();
        var ours = try refsFixture(format);
        defer ours.deinit();
        // A ref naming an object that is not there stays loose.
        if (format == .files) for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            try r.writeFile(io, ".git/refs/heads/dangling", "1111111111111111111111111111111111111111\n");
        };
        // A table no list names, older than the stack: what a compaction
        // that could not remove it leaves, and what a pack cleans away.
        if (format == .reftable) for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            const list = try r.readFile(io, ".git/reftable/tables.list");
            defer gpa.free(list);
            const first = list[0..std.mem.findScalar(u8, list, '\n').?];
            const from = try gpa.print(".git/reftable/{s}", .{first});
            defer gpa.free(from);
            try r.dir.copyFile(from, r.dir, ".git/reftable/0x000000000001-0x000000000001-0badc0de.ref", io, .{});
        };
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.append(gpa, "pack-refs");
        try args.appendSlice(gpa, case.args);
        // git reports the dangling ref and packs the rest.
        var said = try theirs.capture(io, args.items);
        said.deinit(gpa);
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        try gc.packRefs(io, &native, case.options);
        if (format == .files) for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            try r.dir.deleteFile(io, ".git/refs/heads/dangling");
        };
        const expected = try refsState(&theirs, format);
        defer gpa.free(expected);
        const actual = try refsState(&ours, format);
        defer gpa.free(actual);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("pack-refs case {d}\n", .{n});
            return err;
        };
        try ours.exec(io, &.{ "refs", "verify" });
    }
}

test "pack-refs packs, peels and prunes as git's, with --all, --include, --exclude and --no-prune, in both ref formats" {
    try testgit.eachRefFormat(packInFormat);
}

test "pack-refs --auto waits for as many loose refs as git's measure of packed-refs asks" {
    for ([_]usize{ 15, 16 }) |count| {
        var pair: [2]testgit.Repo = undefined;
        for (&pair, 0..) |*r, i| {
            r.* = try testgit.Repo.init(gpa, io, &.{});
            errdefer for (pair[0 .. i + 1]) |*made| made.deinit();
            try commitAt(r, 1_700_000_000, "one");
            for (0..count) |n| {
                var name: [32]u8 = undefined;
                try r.exec(io, &.{ "tag", try std.mem.print(&name, "t{d}", .{n}) });
            }
        }
        defer for (&pair) |*r| r.deinit();
        try pair[0].exec(io, &.{ "pack-refs", "--auto" });
        var native = try repo_mod.Repository.open(gpa, io, pair[1].dir, .{});
        defer native.deinit(io);
        try gc.packRefs(io, &native, .{ .auto = true });
        const expected = try refsState(&pair[0], .files);
        defer gpa.free(expected);
        const actual = try refsState(&pair[1], .files);
        defer gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "a deletion holds packed-refs.lock to its end even when the ref is only loose, as git's does" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try commitAt(&repo, 1_700_000_000, "one");
    try repo.exec(io, &.{ "branch", "gone" });
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    var tx = native.beginRefs();
    defer tx.deinit(io);
    try tx.delete("refs/heads/gone", .any);
    try tx.prepare(io);
    try repo.dir.access(io, ".git/packed-refs.lock", .{});
    try tx.commit(io, null);
    try std.testing.expectError(error.FileNotFound, repo.dir.access(io, ".git/packed-refs.lock", .{}));
    try std.testing.expectError(error.FileNotFound, repo.dir.access(io, ".git/packed-refs", .{}));
}

/// Logs with entries on both sides of the expiries: a branch moved back
/// past commits it no longer reaches, a second branch, a stash, and a
/// detached `HEAD` along the way.
fn logsFixture(format: testgit.RefFormat, now: i64) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, format.initArgs());
    errdefer repo.deinit();
    const ages = [_]i64{ 200, 150, 100, 70, 45, 35, 20 };
    for (ages, 0..) |age, i| {
        var message: [16]u8 = undefined;
        try commitAt(&repo, now - age * day, try std.mem.print(&message, "c{d}", .{i}));
    }
    try at(&repo, now - 12 * day);
    try repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~4" });
    try at(&repo, now - 11 * day);
    try repo.exec(io, &.{ "checkout", "-q", "-b", "topic" });
    try commitAt(&repo, now - 10 * day, "t1");
    try at(&repo, now - 9 * day);
    try repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try at(&repo, now - 8 * day);
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try at(&repo, now - 120 * day);
    try repo.writeFile(io, "file.txt", "stashed");
    try repo.exec(io, &.{ "stash", "-q" });
    try at(&repo, now - 3 * day);
    try repo.exec(io, &.{ "checkout", "-q", "--detach", "HEAD~1" });
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    return repo;
}

/// Every log's entries as `reflog show` gives them, and in the files
/// format the log files' bytes.
fn logsState(repo: *testgit.Repo, format: testgit.RefFormat) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const names = try repo.run(io, &.{ "reflog", "list" });
    defer gpa.free(names);
    try out.appendSlice(gpa, names);
    var lines = std.mem.tokenizeScalar(u8, names, '\n');
    while (lines.next()) |name| {
        const shown = try repo.run(io, &.{ "reflog", "show", "--format=%H %gs %ct", name });
        defer gpa.free(shown);
        try out.print(gpa, "{s}:\n{s}", .{ name, shown });
        if (format == .files) {
            const path = try gpa.print(".git/logs/{s}", .{name});
            defer gpa.free(path);
            const bytes = try repo.readFile(io, path);
            defer gpa.free(bytes);
            try out.appendSlice(gpa, bytes);
        }
    }
    const listed = try repo.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(listed);
    try out.appendSlice(gpa, listed);
    return out.toOwnedSlice(gpa);
}

const ExpireCase = struct {
    config: []const []const [2][]const u8,
    args: []const []const u8,
    options: gc.ReflogExpireOptions,
};

fn expireInFormat(format: testgit.RefFormat) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const clock: @import("../text.zig").date.Context = .{ .now = .fromNanoseconds(@as(i96, now) * std.time.ns_per_s) };
    const both = [_][2][]const u8{ .{ "gc.reflogExpire", "90.days.ago" }, .{ "gc.reflogExpireUnreachable", "30.days.ago" } };
    const cases = [_]ExpireCase{
        .{ .config = &.{}, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{&.{.{ "gc.reflogExpire", "90.days.ago" }}}, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{&.{.{ "gc.reflogExpireUnreachable", "never" }}}, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{&both}, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{ &both, &.{ .{ "gc.refs/heads/topic.reflogExpire", "never" }, .{ "gc.refs/heads/*.reflogExpireUnreachable", "5.days.ago" } } }, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{&.{ .{ "gc.reflogExpire", "160.days.ago" }, .{ "gc.reflogExpireUnreachable", "never" } }}, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{&.{ .{ "gc.reflogExpire", "1.day.ago" }, .{ "gc.refs/stash.reflogExpire", "never" } }}, .args = &.{"--all"}, .options = .{ .clock = clock } },
        .{ .config = &.{&both}, .args = &.{ "--expire-unreachable=now", "--rewrite", "--updateref", "refs/heads/main", "HEAD" }, .options = .{ .clock = clock, .refs = &.{ "refs/heads/main", "HEAD" }, .expire_unreachable = date.expire_all, .rewrite = true, .update_ref = true } },
        .{ .config = &.{&both}, .args = &.{ "--expire=40.days.ago", "--all" }, .options = .{ .clock = clock, .expire = now - 40 * day } },
    };
    for (cases, 0..) |case, n| {
        var theirs = try logsFixture(format, now);
        defer theirs.deinit();
        var ours = try logsFixture(format, now);
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            for (case.config) |group| for (group) |pair| try r.exec(io, &.{ "config", pair[0], pair[1] });
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "reflog", "expire" });
        try args.appendSlice(gpa, case.args);
        try theirs.exec(io, args.items);
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        try gc.expireReflogs(gpa, io, &native, case.options);
        const expected = try logsState(&theirs, format);
        defer gpa.free(expected);
        const actual = try logsState(&ours, format);
        defer gpa.free(actual);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("reflog expire case {d}\n", .{n});
            return err;
        };
    }
}

test "reflog expire keeps and drops what git's does: git 2.55's defaults, gc.reflogExpire*, patterns, refs/stash, HEAD, --rewrite and --updateref, in both ref formats" {
    try testgit.eachRefFormat(expireInFormat);
}

test "an expiry git dies on is refused" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try commitAt(&repo, 1_700_000_000, "one");
    try repo.exec(io, &.{ "config", "gc.reflogExpire", "not a date at all" });
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.exec(io, &.{ "reflog", "expire", "--all" }));
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectError(error.InvalidExpiryDate, gc.expireReflogs(gpa, io, &native, .{ .clock = .{ .now = .fromNanoseconds(1_700_000_000 * std.time.ns_per_s) } }));
}

fn worktreeLogsInFormat(format: testgit.RefFormat) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const clock: @import("../text.zig").date.Context = .{ .now = .fromNanoseconds(@as(i96, now) * std.time.ns_per_s) };
    var states: [2][]u8 = undefined;
    for (0..2) |side| {
        var repo = try testgit.Repo.init(gpa, io, format.initArgs());
        defer repo.deinit();
        for ([_]i64{ 100, 60, 50 }, 0..) |age, i| {
            var message: [16]u8 = undefined;
            try commitAt(&repo, now - age * day, try std.mem.print(&message, "c{d}", .{i}));
        }
        try at(&repo, now - 45 * day);
        try repo.exec(io, &.{ "worktree", "add", "-q", "--detach", "linked", "HEAD~2" });
        try at(&repo, now - 44 * day);
        try repo.exec(io, &.{ "-C", "linked", "checkout", "-q", "--detach", "HEAD~0" });
        try at(&repo, now - 5 * day);
        try repo.exec(io, &.{ "-C", "linked", "checkout", "-q", "--detach", "main" });
        if (side == 0) {
            try repo.exec(io, &.{ "reflog", "expire", "--all", "--expire=40.days.ago" });
        } else {
            var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
            defer native.deinit(io);
            try gc.expireReflogs(gpa, io, &native, .{ .clock = clock, .expire = now - 40 * day });
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const main_state = try logsState(&repo, format);
        defer gpa.free(main_state);
        try out.appendSlice(gpa, main_state);
        const linked = try repo.run(io, &.{ "-C", "linked", "reflog", "show", "--format=%H %gs %ct", "HEAD" });
        defer gpa.free(linked);
        try out.appendSlice(gpa, linked);
        states[side] = try out.toOwnedSlice(gpa);
    }
    defer for (states) |s| gpa.free(s);
    try std.testing.expectEqualStrings(states[0], states[1]);
}

test "reflog expire --all reaches every worktree's own logs, in both ref formats" {
    try testgit.eachRefFormat(worktreeLogsInFormat);
}
