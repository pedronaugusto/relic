//! The stash against git's, in both directions.
//!
//! Every test runs in twin repositories built the same way by git with a
//! fixed date, so a stash commit made here and one made by `git stash` in
//! the other can be compared by name: the same name is the same bytes. What
//! git reads back — `stash list`, `stash show -p`, `stash apply` — is asked
//! of git, and what is left behind — `status --porcelain`, `ls-files -s`,
//! the files themselves — is compared with what git left in the other twin.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const testgit = @import("testgit.zig");
const stash = @import("stash.zig");
const hooks = @import("hooks.zig");
const object = @import("object.zig");
const Repository = @import("repo.zig").Repository;

const who: object.Signature = .{
    .name = "Fixture",
    .email = "fixture@example.com",
    .when_secs = 1_700_000_000,
    .offset_minutes = 0,
};

const Twin = struct {
    git: testgit.Repo,
    relic: testgit.Repo,
    environ: std.process.Environ.Map,

    fn init(gpa: Allocator, io: Io) !*Twin {
        const t = try gpa.create(Twin);
        errdefer gpa.destroy(t);
        t.environ = try hooks.testEnviron(gpa);
        errdefer t.environ.deinit();
        _ = t.environ.orderedRemove("GIT_DIR");
        _ = t.environ.orderedRemove("GIT_INDEX_FILE");
        try t.environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
        try t.environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
        t.git = try testgit.Repo.init(gpa, io, &.{});
        errdefer t.git.deinit();
        t.relic = try testgit.Repo.init(gpa, io, &.{});
        t.git.environ = &t.environ;
        t.relic.environ = &t.environ;
        return t;
    }

    fn deinit(t: *Twin, gpa: Allocator) void {
        t.git.deinit();
        t.relic.deinit();
        t.environ.deinit();
        gpa.destroy(t);
    }

    fn both(t: *Twin, io: Io, args: []const []const u8) !void {
        try t.git.exec(io, args);
        try t.relic.exec(io, args);
    }

    fn write(t: *Twin, io: Io, path: []const u8, bytes: []const u8) !void {
        try t.git.writeFile(io, path, bytes);
        try t.relic.writeFile(io, path, bytes);
    }

    fn remove(t: *Twin, io: Io, path: []const u8) !void {
        try t.git.dir.deleteFile(io, path);
        try t.relic.dir.deleteFile(io, path);
    }

    fn expectSame(t: *Twin, io: Io, args: []const []const u8) !void {
        const a = try t.git.run(io, args);
        defer t.git.gpa.free(a);
        const b = try t.relic.run(io, args);
        defer t.relic.gpa.free(b);
        testing.expectEqualStrings(a, b) catch |err| {
            std.debug.print("git {s} differs\n", .{args[0]});
            return err;
        };
    }

    fn expectSameFile(t: *Twin, io: Io, path: []const u8) !void {
        const a = t.git.readFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {
                try testing.expectError(error.FileNotFound, t.relic.readFile(io, path));
                return;
            },
            else => |e| return e,
        };
        defer t.git.gpa.free(a);
        const b = try t.relic.readFile(io, path);
        defer t.relic.gpa.free(b);
        try testing.expectEqualStrings(a, b);
    }

    /// The state both working trees and indexes are compared in.
    fn expectSameState(t: *Twin, io: Io, paths: []const []const u8) !void {
        try t.expectSame(io, &.{ "status", "--porcelain", "--untracked-files=all" });
        try t.expectSame(io, &.{ "ls-files", "-s" });
        for (paths) |f| try t.expectSameFile(io, f);
    }

    fn open(t: *Twin, gpa: Allocator, io: Io) !Repository {
        return Repository.open(gpa, io, t.relic.dir, .{});
    }

    /// The history and the changes every test starts from: a commit of
    /// three files, then a staged change, an unstaged change, a deletion, a
    /// new staged file and an untracked one.
    fn setUp(t: *Twin, io: Io) !void {
        try t.write(io, "a.txt", ten);
        try t.write(io, "b.txt", "bee\n");
        try t.write(io, "dir/c.txt", "sea\n");
        try t.write(io, ".gitignore", "*.log\nout/\n");
        try t.both(io, &.{ "add", "." });
        try t.both(io, &.{ "commit", "-q", "-m", "base\n\nwith a body" });
        try t.write(io, "a.txt", "1\n2, staged\n3\n4\n5\n6\n7\n8\n9\n10\n");
        try t.both(io, &.{ "add", "a.txt" });
        try t.write(io, "b.txt", "bee, unstaged\n");
        try t.remove(io, "dir/c.txt");
        try t.write(io, "new.txt", "new\n");
        try t.both(io, &.{ "add", "new.txt" });
        try t.write(io, "loose.txt", "untracked\n");
        try t.write(io, "build.log", "ignored\n");
        try t.write(io, "fresh/deep/x.txt", "untracked, deeper\n");
        try t.write(io, "out/o.txt", "ignored, in a directory\n");
    }
};

const ten = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";

const files = [_][]const u8{ "a.txt", "b.txt", "dir/c.txt", "new.txt", "loose.txt", "build.log", "fresh/deep/x.txt", "out/o.txt" };

test "a stash pushed here is the stash git pushes, and git lists, shows and applies it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;

    const Case = struct { args: []const []const u8, options: stash.PushOptions };
    const cases = [_]Case{
        .{ .args = &.{ "stash", "push", "-q" }, .options = .{ .who = who } },
        .{ .args = &.{ "stash", "push", "-q", "-u" }, .options = .{ .who = who, .untracked = .include } },
        .{ .args = &.{ "stash", "push", "-q", "-a" }, .options = .{ .who = who, .untracked = .all } },
        .{ .args = &.{ "stash", "push", "-q", "--keep-index", "-m", "kept" }, .options = .{ .who = who, .keep_index = true, .message = "kept" } },
        .{ .args = &.{ "stash", "push", "-q", "--", "b.txt", "dir" }, .options = .{ .who = who, .paths = &.{ "b.txt", "dir" } } },
        .{ .args = &.{ "stash", "push", "-q", "-u", "--", "a.txt", "loose.txt" }, .options = .{ .who = who, .untracked = .include, .paths = &.{ "a.txt", "loose.txt" } } },
        .{ .args = &.{ "stash", "push", "-q", "--keep-index", "--", "a.txt", "b.txt", "new.txt" }, .options = .{ .who = who, .keep_index = true, .paths = &.{ "a.txt", "b.txt", "new.txt" } } },
    };
    for (cases) |case| {
        var twin = try Twin.init(gpa, io);
        defer twin.deinit(gpa);
        try twin.setUp(io);

        try twin.git.exec(io, case.args);
        {
            var repo = try twin.open(gpa, io);
            defer repo.deinit(io);
            const made = try stash.push(&repo, io, case.options);
            try testing.expect(made != null);
        }

        // The same commits, so the same bytes, and the same list.
        try twin.expectSame(io, &.{ "rev-parse", "stash", "stash^1", "stash^2" });
        try twin.expectSame(io, &.{ "log", "-g", "--format=%H %gs", "refs/stash" });
        try twin.expectSame(io, &.{ "stash", "list" });
        try twin.expectSame(io, &.{ "stash", "show", "-p", "--include-untracked" });
        try twin.expectSameFile(io, ".git/logs/refs/stash");
        // And the working tree and index left behind.
        try twin.expectSameState(io, &files);

        // git brings back what was stashed here.
        try twin.both(io, &.{ "reset", "-q", "--hard" });
        try twin.both(io, &.{ "clean", "-q", "-fdx" });
        try twin.both(io, &.{ "stash", "pop", "-q", "--index" });
        try twin.expectSameState(io, &files);
    }
}

test "nothing to stash is no stash" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    try fixture.writeFile(io, "a.txt", "a\n");
    try fixture.exec(io, &.{ "add", "." });
    try fixture.exec(io, &.{ "commit", "-q", "-m", "a" });
    try fixture.writeFile(io, "loose.txt", "untracked\n");
    var repo = try Repository.open(gpa, io, fixture.dir, .{});
    defer repo.deinit(io);
    try testing.expect((try stash.push(&repo, io, .{ .who = who })) == null);
    var refusal: stash.Refusal = .{};
    try testing.expectError(error.PathspecMatchesNothing, stash.push(&repo, io, .{ .who = who, .paths = &.{"missing"}, .refusal = &refusal }));
    try testing.expectEqualStrings("missing", refusal.path());
}

test "git's stash is applied and popped here as git applies and pops it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;

    for ([_]bool{ false, true }) |with_index| {
        var twin = try Twin.init(gpa, io);
        defer twin.deinit(gpa);
        try twin.setUp(io);
        try twin.both(io, &.{ "stash", "push", "-q", "-u" });
        // Something moves on meanwhile: a new commit touching another line,
        // and an unrelated file with changes of its own.
        try twin.write(io, "a.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10, committed\n");
        try twin.both(io, &.{ "commit", "-q", "-am", "moved on" });
        try twin.write(io, ".gitignore", "*.log\nout/\n# edited\n");

        if (with_index)
            try twin.git.exec(io, &.{ "stash", "apply", "-q", "--index" })
        else
            try twin.git.exec(io, &.{ "stash", "apply", "-q" });
        {
            var repo = try twin.open(gpa, io);
            defer repo.deinit(io);
            var applied = try stash.apply(&repo, io, 0, .{ .index = with_index });
            defer applied.deinit();
            try testing.expect(applied.isClean());
            try testing.expectEqual(with_index, applied.index_restored);
        }
        try twin.expectSameState(io, &(files ++ [_][]const u8{".gitignore"}));
        try twin.expectSame(io, &.{"diff"});
        try twin.expectSame(io, &.{ "diff", "--cached" });
        try twin.expectSame(io, &.{ "stash", "list" });

        // Pop drops it, on a clean tree.
        try twin.both(io, &.{ "reset", "-q", "--hard" });
        try twin.both(io, &.{ "clean", "-q", "-fdx" });
        try twin.git.exec(io, &.{ "stash", "pop", "-q" });
        {
            var repo = try twin.open(gpa, io);
            defer repo.deinit(io);
            var popped = try stash.pop(&repo, io, 0, .{});
            defer popped.deinit();
            try testing.expect(popped.dropped);
        }
        try twin.expectSameState(io, &files);
        try twin.expectSame(io, &.{ "stash", "list" });
        try testing.expectError(error.FileNotFound, twin.relic.readFile(io, ".git/refs/stash"));
    }
}

test "an index git cannot restore as a patch is not restored here either" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit(gpa);
    try twin.setUp(io);
    try twin.both(io, &.{ "stash", "push", "-q" });
    // Line five is context for the staged change to line two: the tree
    // merge would take both, the patch git applies cannot.
    try twin.write(io, "a.txt", "1\n2\n3\n4\n5, committed\n6\n7\n8\n9\n10\n");
    try twin.both(io, &.{ "commit", "-q", "-am", "near" });

    twin.git.report_failures = false;
    try testing.expectError(error.GitFailed, twin.git.exec(io, &.{ "stash", "apply", "-q", "--index" }));
    var repo = try twin.open(gpa, io);
    defer repo.deinit(io);
    try testing.expectError(error.IndexConflict, stash.apply(&repo, io, 0, .{ .index = true }));
    try twin.expectSameState(io, &files);

    // Without the index, both merge it.
    try twin.git.exec(io, &.{ "stash", "apply", "-q" });
    var applied = try stash.apply(&repo, io, 0, .{});
    defer applied.deinit();
    try twin.expectSameState(io, &files);
}

test "a conflicting stash leaves git's stages and markers, and pop keeps it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit(gpa);
    try twin.setUp(io);
    try twin.both(io, &.{ "stash", "push", "-q" });
    try twin.write(io, "a.txt", "1\n2, committed\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try twin.write(io, "b.txt", "bee, committed\n");
    try twin.both(io, &.{ "commit", "-q", "-am", "the same lines" });

    twin.git.report_failures = false;
    try testing.expectError(error.GitFailed, twin.git.exec(io, &.{ "stash", "pop", "-q" }));
    {
        var repo = try twin.open(gpa, io);
        defer repo.deinit(io);
        var popped = try stash.pop(&repo, io, 0, .{});
        defer popped.deinit();
        try testing.expect(!popped.dropped);
        try testing.expectEqual(@as(usize, 2), popped.conflicts.len);
        try testing.expectEqualStrings("a.txt", popped.conflicts[0]);
    }
    try twin.expectSameState(io, &files);
    try twin.expectSame(io, &.{ "stash", "list" });
}

test "a stash that would overwrite local changes or untracked files is refused and nothing moves" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit(gpa);
    try twin.setUp(io);
    // Without the untracked files: git puts those back even when its merge
    // refuses, and here a refusal touches nothing.
    try twin.both(io, &.{ "stash", "push", "-q" });

    twin.git.report_failures = false;
    try twin.write(io, "b.txt", "bee, local\n");
    try testing.expectError(error.GitFailed, twin.git.exec(io, &.{ "stash", "apply", "-q" }));
    var repo = try twin.open(gpa, io);
    defer repo.deinit(io);
    var refusal: stash.Refusal = .{};
    try testing.expectError(error.LocalChangesWouldBeOverwritten, stash.apply(&repo, io, 0, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("b.txt", refusal.path());
    try twin.expectSameState(io, &files);

    try twin.both(io, &.{ "checkout", "b.txt" });
    try twin.write(io, "new.txt", "in the way\n");
    try testing.expectError(error.UntrackedWouldBeOverwritten, stash.apply(&repo, io, 0, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("new.txt", refusal.path());
    const kept = try twin.relic.readFile(io, "new.txt");
    defer gpa.free(kept);
    try testing.expectEqualStrings("in the way\n", kept);
}

test "dropping and clearing leave git's list" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io);
    defer twin.deinit(gpa);
    try twin.setUp(io);
    try twin.both(io, &.{ "stash", "push", "-q", "-m", "first" });
    try twin.write(io, "b.txt", "second\n");
    try twin.both(io, &.{ "stash", "push", "-q", "-m", "second" });
    try twin.write(io, "b.txt", "third\n");
    try twin.both(io, &.{ "stash", "push", "-q", "-m", "third" });

    var repo = try twin.open(gpa, io);
    defer repo.deinit(io);
    {
        var l = try stash.list(&repo, io);
        defer l.deinit();
        try testing.expectEqual(@as(usize, 3), l.entries.len);
        try testing.expectEqualStrings("On main: third", l.entries[0].message);
    }

    {
        var changes = try stash.show(&repo, io, 1, .{});
        defer changes.deinit();
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(gpa);
        for (changes.items) |c| {
            try names.append(gpa, c.letter());
            try names.append(gpa, '\t');
            try names.appendSlice(gpa, c.path());
            try names.append(gpa, '\n');
        }
        const shown = try twin.git.run(io, &.{ "stash", "show", "--name-status", "stash@{1}" });
        defer gpa.free(shown);
        try testing.expectEqualStrings(shown, names.items);
    }

    try twin.git.exec(io, &.{ "stash", "drop", "-q", "stash@{1}" });
    _ = try stash.drop(&repo, io, 1, .{});
    try twin.expectSameFile(io, ".git/logs/refs/stash");
    try twin.expectSame(io, &.{ "stash", "list" });
    try twin.expectSame(io, &.{ "rev-parse", "stash" });

    try twin.git.exec(io, &.{ "stash", "drop", "-q" });
    _ = try stash.drop(&repo, io, 0, .{});
    try twin.expectSameFile(io, ".git/logs/refs/stash");
    try twin.expectSame(io, &.{ "rev-parse", "stash" });

    try twin.git.exec(io, &.{ "stash", "clear" });
    try stash.clear(&repo, io, .{});
    try twin.expectSame(io, &.{ "stash", "list" });
    try testing.expectError(error.FileNotFound, twin.relic.readFile(io, ".git/logs/refs/stash"));
    try testing.expectError(error.NoSuchStash, stash.drop(&repo, io, 0, .{}));
}
