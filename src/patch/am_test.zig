//! `am` against `git am`: the same mailbox on the same repository makes
//! the same commits, stops at the same mail leaving the same state, and a
//! session either tool stopped is finished by the other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const am = @import("am.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;

const committer: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

const Pair = struct {
    gpa: Allocator,
    git: testgit.Repo,
    ours: testgit.Repo,

    fn init(gpa: Allocator, io: Io, format: testgit.RefFormat) !Pair {
        var git = try testgit.Repo.init(gpa, io, format.initArgs());
        errdefer git.deinit();
        return .{ .gpa = gpa, .git = git, .ours = try testgit.Repo.init(gpa, io, format.initArgs()) };
    }

    fn deinit(p: *Pair) void {
        p.git.deinit();
        p.ours.deinit();
        p.* = undefined;
    }

    fn both(p: *Pair, io: Io, args: []const []const u8) !void {
        try p.git.exec(io, args);
        try p.ours.exec(io, args);
    }

    fn write(p: *Pair, io: Io, path: []const u8, bytes: []const u8) !void {
        try p.git.writeFile(io, path, bytes);
        try p.ours.writeFile(io, path, bytes);
    }
};

/// A mailbox `git format-patch` makes of the commits `build` adds on top
/// of `base.txt` and `other.txt`, in a repository of its own.
fn makeMailbox(gpa: Allocator, io: Io, args: []const []const u8, build: *const fn (Io, *testgit.Repo) anyerror!void) ![]u8 {
    var src = try testgit.Repo.init(gpa, io, &.{});
    defer src.deinit();
    try baseFiles(io, &src);
    try src.exec(io, &.{ "add", "-A" });
    try src.exec(io, &.{ "commit", "-q", "-m", "base" });
    try src.exec(io, &.{ "tag", "base" });
    try build(io, &src);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "format-patch", "--stdout", "--no-signature" });
    try argv.appendSlice(gpa, args);
    try argv.append(gpa, "base..HEAD");
    return src.run(io, argv.items);
}

fn baseFiles(io: Io, r: *testgit.Repo) !void {
    try r.writeFile(io, "base.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n");
    try r.writeFile(io, "other.txt", "alpha\nbeta\ngamma\n");
}

fn setupPair(p: *Pair, io: Io) !void {
    try baseFiles(io, &p.git);
    try baseFiles(io, &p.ours);
    try p.both(io, &.{ "add", "-A" });
    try p.both(io, &.{ "commit", "-q", "-m", "base" });
}

fn threeCommits(io: Io, r: *testgit.Repo) !void {
    try r.writeFile(io, "base.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\n");
    try r.exec(io, &.{ "commit", "-q", "-a", "-m", "First change\n\nWith a body." });
    try r.writeFile(io, "new.txt", "brand new\n");
    try r.exec(io, &.{ "add", "new.txt" });
    try r.exec(io, &.{ "-c", "user.name=Other Author", "-c", "user.email=other@example.com", "commit", "-q", "-m", "[topic] Second: add a file" });
    try r.writeFile(io, "base.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\nEIGHT\n");
    try r.writeFile(io, "other.txt", "alpha\nbeta\nGAMMA\n");
    try r.exec(io, &.{ "commit", "-q", "-a", "-m", "Third change" });
}

/// Everything in `rebase-apply`, sorted, `patch-merge-index` left out: an
/// index file whose stat fields neither side fills.
fn stateFiles(gpa: Allocator, io: Io, r: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var git_dir = try r.gitDir(io);
    defer git_dir.close(io);
    var dir = git_dir.openDir(io, "rebase-apply", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(gpa),
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "patch-merge-index")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try out.print(gpa, "== {s}\n", .{name});
        try out.appendSlice(gpa, bytes);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// The history, the index, the files and the session's state.
fn snapshot(gpa: Allocator, io: Io, r: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const log = r.run(io, &.{ "log", "--format=%H %an <%ae> %ad %cn <%ce> %cd%n%B", "--date=raw" }) catch try gpa.dupe(u8, "(no commits)\n");
    defer gpa.free(log);
    try out.appendSlice(gpa, log);
    const reflog = r.run(io, &.{ "reflog", "--format=%H %gs" }) catch try gpa.dupe(u8, "(no reflog)\n");
    defer gpa.free(reflog);
    try out.appendSlice(gpa, reflog);
    // The root refs a session leaves, as git reads them in either format.
    for ([_][]const u8{ "ORIG_HEAD", "REBASE_HEAD" }) |name| {
        r.report_failures = false;
        defer r.report_failures = true;
        const value = r.run(io, &.{ "rev-parse", "--verify", "-q", name }) catch try gpa.dupe(u8, "(none)\n");
        defer gpa.free(value);
        try out.print(gpa, "{s} {s}", .{ name, value });
    }
    const staged = try r.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(staged);
    try out.appendSlice(gpa, staged);
    const status = try r.run(io, &.{ "status", "--porcelain", "--untracked-files=all" });
    defer gpa.free(status);
    try out.appendSlice(gpa, status);
    const listed = try r.run(io, &.{ "ls-files", "-z" });
    defer gpa.free(listed);
    var files = std.mem.splitScalar(u8, listed, 0);
    while (files.next()) |name| {
        if (name.len == 0) continue;
        const bytes = r.dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(bytes);
        try out.print(gpa, "-- {s}\n{s}", .{ name, bytes });
    }
    const state = try stateFiles(gpa, io, r);
    defer gpa.free(state);
    try out.appendSlice(gpa, state);
    return out.toOwnedSlice(gpa);
}

fn expectSame(gpa: Allocator, io: Io, p: *Pair) !void {
    const theirs = try snapshot(gpa, io, &p.git);
    defer gpa.free(theirs);
    const ours = try snapshot(gpa, io, &p.ours);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
}

/// `git am <args>` over `mbox` on the git side; its exit code.
fn gitAm(gpa: Allocator, io: Io, p: *Pair, args: []const []const u8, mbox: []const u8) !u8 {
    var git_dir = try p.git.gitDir(io);
    defer git_dir.close(io);
    try git_dir.writeFile(io, .{ .sub_path = "relic-test.mbox", .data = mbox });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "am");
    try argv.appendSlice(gpa, args);
    try argv.append(gpa, ".git/relic-test.mbox");
    var c = try p.git.capture(io, argv.items);
    defer c.deinit(gpa);
    try git_dir.deleteFile(io, "relic-test.mbox");
    return c.code;
}

fn oursAm(gpa: Allocator, io: Io, p: *Pair, mbox: []const u8, options: am.Options) !?am.Stop {
    var repo = try Repository.open(gpa, io, p.ours.dir, .{});
    defer repo.deinit(io);
    var outcome = try am.start(gpa, io, &repo, &.{mbox}, options);
    defer outcome.deinit();
    if (outcome.stopped) |s| return .{ .number = s.number, .reason = s.reason, .subject = "" };
    return null;
}

test "a mailbox git format-patch wrote becomes the commits git am makes" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const mbox = try makeMailbox(gpa, io, &.{}, threeCommits);
            defer gpa.free(mbox);
            var p = try Pair.init(gpa, io, format);
            defer p.deinit();
            try setupPair(&p, io);
            try std.testing.expectEqual(@as(u8, 0), try gitAm(gpa, io, &p, &.{}, mbox));
            try std.testing.expect((try oursAm(gpa, io, &p, mbox, .{ .committer = committer })) == null);
            try expectSame(gpa, io, &p);
        }
    }.inFormat);
}

test "keep, keep-non-patch, sign-off and message ids shape the commits as git's do" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const mbox = try makeMailbox(gpa, io, &.{"--thread"}, threeCommits);
            defer gpa.free(mbox);
            const variants = [_]struct { args: []const []const u8, options: am.Options }{
                .{ .args = &.{"-k"}, .options = .{ .committer = committer, .keep = .subject } },
                .{ .args = &.{"--keep-non-patch"}, .options = .{ .committer = committer, .keep = .non_patch } },
                .{ .args = &.{ "-s", "--message-id" }, .options = .{ .committer = committer, .signoff = true, .message_id = true } },
                .{ .args = &.{"--committer-date-is-author-date"}, .options = .{ .committer = committer, .committer_date_is_author_date = true } },
            };
            for (variants) |v| {
                // git spells the header it adds `Message-ID` since 2.41
                if (v.options.message_id == true and !try testgit.gitAtLeast(gpa, io, 2, 41)) continue;
                var p = try Pair.init(gpa, io, format);
                defer p.deinit();
                try setupPair(&p, io);
                try std.testing.expectEqual(@as(u8, 0), try gitAm(gpa, io, &p, v.args, mbox));
                try std.testing.expect((try oursAm(gpa, io, &p, mbox, v.options)) == null);
                expectSame(gpa, io, &p) catch |err| {
                    std.debug.print("git am {any}\n", .{v.args});
                    return err;
                };
            }
        }
    }.inFormat);
}

test "a patch that does not apply stops both at the same mail with the same state, and either finishes the other's session" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const mbox = try makeMailbox(gpa, io, &.{}, threeCommits);
            defer gpa.free(mbox);
            for ([_]bool{ false, true }) |cross| {
                var p = try Pair.init(gpa, io, format);
                defer p.deinit();
                try setupPair(&p, io);
                // the target moved on where the third patch changes it
                try p.write(io, "other.txt", "alpha\nbeta\nGamma-ours\n");
                try p.both(io, &.{ "commit", "-q", "-a", "-m", "ours" });
                try std.testing.expect(try gitAm(gpa, io, &p, &.{}, mbox) != 0);
                const stop = (try oursAm(gpa, io, &p, mbox, .{ .committer = committer })).?;
                try std.testing.expectEqual(@as(usize, 3), stop.number);
                try std.testing.expectEqual(am.StopReason.does_not_apply, stop.reason);
                try expectSame(gpa, io, &p);

                // resolve by hand, the same way on both sides
                try p.write(io, "other.txt", "alpha\nbeta\nGAMMA\n");
                try p.write(io, "base.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\nEIGHT\n");
                try p.both(io, &.{ "add", "-A" });
                if (cross) {
                    // each tool continues the session the other stopped
                    var git_side = try Repository.open(gpa, io, p.git.dir, .{});
                    defer git_side.deinit(io);
                    var done = try am.proceed(gpa, io, &git_side, .{ .committer = committer });
                    defer done.deinit();
                    try std.testing.expect(done.stopped == null);
                    try p.ours.exec(io, &.{ "am", "--continue" });
                } else {
                    try p.git.exec(io, &.{ "am", "--continue" });
                    var ours = try Repository.open(gpa, io, p.ours.dir, .{});
                    defer ours.deinit(io);
                    var done = try am.proceed(gpa, io, &ours, .{ .committer = committer });
                    defer done.deinit();
                    try std.testing.expect(done.stopped == null);
                }
                try expectSame(gpa, io, &p);
            }
        }
    }.inFormat);
}

test "the three-way fallback leaves git's conflict, and skip and abort put things back as git's do" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const mbox = try makeMailbox(gpa, io, &.{}, threeCommits);
            defer gpa.free(mbox);
            for ([_][]const u8{ "skip", "abort" }) |how| {
                var p = try Pair.init(gpa, io, format);
                defer p.deinit();
                try setupPair(&p, io);
                try p.write(io, "other.txt", "alpha\nbeta\nGamma-ours\n");
                try p.both(io, &.{ "commit", "-q", "-a", "-m", "ours" });
                try std.testing.expect(try gitAm(gpa, io, &p, &.{"--3way"}, mbox) != 0);
                const stop = (try oursAm(gpa, io, &p, mbox, .{ .committer = committer, .three_way = true })).?;
                try std.testing.expectEqual(am.StopReason.conflicts, stop.reason);
                try expectSame(gpa, io, &p);
                var ours = try Repository.open(gpa, io, p.ours.dir, .{});
                defer ours.deinit(io);
                if (std.mem.eql(u8, how, "skip")) {
                    try p.git.exec(io, &.{ "am", "--skip" });
                    var done = try am.skip(gpa, io, &ours, .{ .committer = committer });
                    done.deinit();
                } else {
                    try p.git.exec(io, &.{ "am", "--abort" });
                    try am.abort(gpa, io, &ours, committer);
                }
                try expectSame(gpa, io, &p);
            }
        }
    }.inFormat);
}

test "the three-way fallback reads the patch under --directory as the apply did, and a stray rebase-apply goes on abort and quit, as git's do" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const mbox = try makeMailbox(gpa, io, &.{}, threeCommits);
            defer gpa.free(mbox);
            var p = try Pair.init(gpa, io, format);
            defer p.deinit();
            try p.write(io, "sub/base.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n");
            try p.write(io, "sub/other.txt", "alpha\nbeta\ngamma\n");
            try p.both(io, &.{ "add", "-A" });
            try p.both(io, &.{ "commit", "-q", "-m", "base, under sub" });
            try p.write(io, "sub/other.txt", "alpha\nbeta\nGamma-ours\n");
            try p.both(io, &.{ "commit", "-q", "-a", "-m", "ours" });
            try std.testing.expect(try gitAm(gpa, io, &p, &.{ "--3way", "--directory=sub" }, mbox) != 0);
            const stop = (try oursAm(gpa, io, &p, mbox, .{ .committer = committer, .three_way = true, .apply = .{ .directory = "sub" } })).?;
            try std.testing.expectEqual(am.StopReason.conflicts, stop.reason);
            try expectSame(gpa, io, &p);
            try p.git.exec(io, &.{ "am", "--abort" });
            {
                var ours = try Repository.open(gpa, io, p.ours.dir, .{});
                defer ours.deinit(io);
                try am.abort(gpa, io, &ours, committer);
            }
            try expectSame(gpa, io, &p);

            for ([_][]const u8{ "--abort", "--quit" }) |how| {
                try p.write(io, ".git/rebase-apply/stray", "left behind\n");
                try p.git.exec(io, &.{ "am", how });
                var ours = try Repository.open(gpa, io, p.ours.dir, .{});
                defer ours.deinit(io);
                if (std.mem.eql(u8, how, "--abort")) try am.abort(gpa, io, &ours, committer) else try am.quit(io, &ours);
                try std.testing.expectError(error.FileNotFound, p.ours.dir.statFile(io, ".git/rebase-apply", .{}));
                try std.testing.expectError(error.NoAmInProgress, am.quit(io, &ours));
            }
        }
    }.inFormat);
}

fn mailWith(comptime headers: []const u8, comptime body: []const u8) []const u8 {
    return "From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001\n" ++ headers ++ "\n" ++ body;
}

const plain_patch =
    \\---
    \\ base.txt | 2 +-
    \\ 1 file changed, 1 insertion(+), 1 deletion(-)
    \\
    \\diff --git a/base.txt b/base.txt
    \\--- a/base.txt
    \\+++ b/base.txt
    \\@@ -1,3 +1,3 @@
    \\ one
    \\-two
    \\+TWO
    \\ three
    \\
;

test "mails in quoted-printable, base64, Latin-1, flowed and multipart text, with in-body headers and scissors, are read as git reads them" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            const mails = [_]struct { mbox: []const u8, args: []const []const u8, options: am.Options }{
                .{ .mbox = mailWith("From: =?ISO-8859-1?Q?Ren=E9_Lat?= <rene@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0100\nSubject: [PATCH] Quoted =?UTF-8?B?w6l0w6k=?=\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: quoted-printable\n", "Caf=C3=A9 is =\nfolded.\n" ++ plain_patch), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: A Latin <latin@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 -0500\nSubject: Latin body\nContent-Type: text/plain; charset=ISO-8859-1\nContent-Transfer-Encoding: 8bit\n", "Caf\xe9 in Latin-1.\n" ++ plain_patch), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: B64 <b64@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Base64\nContent-Transfer-Encoding: base64\n", "QSBiYXNlNjQgYm9keS4KLS0tCiBiYXNlLnR4dCB8IDIgKy0KCmRpZmYgLS1naXQgYS9iYXNl\nLnR4dCBiL2Jhc2UudHh0Ci0tLSBhL2Jhc2UudHh0CisrKyBiL2Jhc2UudHh0CkBAIC0xLDMgKzEs\nMyBAQAogb25lCi10d28KK1RXTwogdGhyZWUK\n"), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: Sender <sender@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: [PATCH] Sent for someone\n", "From: Real Author <real@example.com>\nSubject: The real subject\n\nThe body.\n" ++ plain_patch), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: Cut <cut@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Discussion\n", "Chatter to drop.\n\n-- >8 --\nSubject: After the scissors\n\nKept.\n" ++ plain_patch), .args = &.{"--scissors"}, .options = .{ .committer = committer, .scissors = true } },
                .{ .mbox = mailWith("From: Flow <flow@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Flowed\nContent-Type: text/plain; charset=UTF-8; format=flowed\n", "A line that is \nflowed together.\n" ++ plain_patch), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: Multi <multi@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Multipart\nMIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"XYZ\"\n", "This is a multi-part message in MIME format.\n--XYZ\nContent-Type: text/plain; charset=UTF-8\n\nThe text part.\n\n--XYZ\nContent-Type: text/x-patch; name=\"p.patch\"\nContent-Transfer-Encoding: 8bit\n\n" ++ plain_patch ++ "\n--XYZ--\n"), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: Empty <empty@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Nothing\n", "No patch here.\n"), .args = &.{"--empty=keep"}, .options = .{ .committer = committer, .empty = .keep } },
                .{ .mbox = mailWith("From: Empty <empty@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Nothing\n", "No patch here.\n"), .args = &.{"--empty=drop"}, .options = .{ .committer = committer, .empty = .drop } },
                .{ .mbox = mailWith("From: Empty <empty@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Nothing\n", "No patch here.\n"), .args = &.{}, .options = .{ .committer = committer } },
                .{ .mbox = mailWith("From: Spaces <spaces@example.com>\nDate: Wed, 15 Nov 2023 10:00:00 +0000\nSubject: Fix whitespace\n", "Body.\n---\ndiff --git a/base.txt b/base.txt\n--- a/base.txt\n+++ b/base.txt\n@@ -1,3 +1,4 @@\n one\n+trailing  \n two\n three\n"), .args = &.{"--whitespace=fix"}, .options = .{ .committer = committer, .apply = .{ .whitespace = .fix } } },
            };
            for (mails, 0..) |m, i| {
                var p = try Pair.init(gpa, io, format);
                defer p.deinit();
                try setupPair(&p, io);
                const code = try gitAm(gpa, io, &p, m.args, m.mbox);
                const stop = oursAm(gpa, io, &p, m.mbox, m.options) catch |err| {
                    std.debug.print("mail {d}: {s} (git am exit {d})\n", .{ i, @errorName(err), code });
                    return err;
                };
                std.testing.expectEqual(code == 0, stop == null) catch |err| {
                    std.debug.print("mail {d}: git am exit {d}\n", .{ i, code });
                    return err;
                };
                expectSame(gpa, io, &p) catch |err| {
                    std.debug.print("mail {d}\n", .{i});
                    return err;
                };
            }
        }
    }.inFormat);
}
