//! `fastimport` against `git fast-import`: one stream into two empty
//! repositories, git's and this, and the refs, the objects they name, the
//! marks and what was printed agree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fastimport = @import("fastimport.zig");
const object = @import("object/object.zig");
const repo_mod = @import("repo/repo.zig");
const testgit = @import("testing/git.zig");

const Repository = repo_mod.Repository;

const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

/// Every ref and what it names, as git lists them.
fn refs(io: Io, git: *testgit.Repo) ![]u8 {
    return git.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
}

const Pair = struct {
    theirs: testgit.Repo,
    mine: testgit.Repo,

    fn init(gpa: Allocator, io: Io) !Pair {
        var theirs = try testgit.Repo.init(gpa, io, &.{});
        errdefer theirs.deinit();
        return .{ .theirs = theirs, .mine = try testgit.Repo.init(gpa, io, &.{}) };
    }

    fn deinit(p: *Pair) void {
        p.theirs.deinit();
        p.mine.deinit();
        p.* = undefined;
    }

    /// Import `stream` into both, git with `args`; what each printed must
    /// match, and the refs after.
    fn import(p: *Pair, gpa: Allocator, io: Io, stream: []const u8, args: []const []const u8, options: fastimport.Options) !fastimport.Report {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "fast-import", "--quiet" });
        try argv.appendSlice(gpa, args);
        const git_out = try p.theirs.runInput(io, argv.items, stream);
        defer gpa.free(git_out);

        var repo = try Repository.open(gpa, io, p.mine.dir, .{});
        defer repo.deinit(io);
        var printed: Io.Writer.Allocating = .init(gpa);
        defer printed.deinit();
        var opts = options;
        opts.output = &printed.writer;
        opts.cwd = p.mine.dir;
        var input: Io.Reader = .fixed(stream);
        const report = fastimport.import(gpa, io, &repo, &input, opts) catch |err| {
            std.debug.print("fastimport: {t}\n", .{err});
            return err;
        };
        errdefer {
            var r = report;
            r.deinit();
        }
        try std.testing.expectEqualStrings(git_out, printed.written());

        const a = try refs(io, &p.theirs);
        defer gpa.free(a);
        const b = try refs(io, &p.mine);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
        const fsck = try p.mine.run(io, &.{ "fsck", "--strict", "--no-dangling" });
        gpa.free(fsck);
        return report;
    }
};

const stream_one =
    \\feature date-format=raw
    \\feature notes
    \\option git quiet
    \\# a comment
    \\blob
    \\mark :1
    \\data 6
    \\hello
    \\
    \\blob
    \\mark :2
    \\original-oid 1234
    \\data <<EOF
    \\second file
    \\EOF
    \\
    \\commit refs/heads/main
    \\mark :3
    \\author A U Thor <author@example.com> 1700000000 +0100
    \\committer C O Mitter <committer@example.com> 1700000100 -0500
    \\data 12
    \\first commit
    \\M 100644 :1 hello.txt
    \\M 644 :2 dir/second.txt
    \\M 755 inline bin/run.sh
    \\data 10
    \\#!/bin/sh
    \\
    \\M 120000 inline link
    \\data 9
    \\hello.txt
    \\M 100644 inline "quoted name.txt"
    \\data 3
    \\q!
    \\M 100644 :1 spaced name.txt
    \\
    \\commit refs/heads/main
    \\mark :4
    \\committer C O Mitter <committer@example.com> 1700000200 +0000
    \\data <<MSG
    \\second
    \\MSG
    \\from :3
    \\R hello.txt greeting.txt
    \\C dir/second.txt "copy of second.txt"
    \\D bin/run.sh
    \\M 160000 0123456789012345678901234567890123456789 sub
    \\M 040000 4b825dc642cb6eb9a060e54bf8d69288fbee4904 dir
    \\ls "greeting.txt"
    \\ls "nothing here"
    \\cat-blob :1
    \\
    \\reset refs/heads/side
    \\from :3
    \\
    \\commit refs/heads/side
    \\mark :5
    \\author <nobody@example.com> 1700000300 +0000
    \\committer Name <c@example.com> 1700000300 +0000
    \\encoding ISO-8859-1
    \\data 5
    \\side
    \\M 100644 inline dir/second.txt
    \\data 7
    \\changed
    \\R dir sub/dir
    \\
    \\commit refs/heads/main
    \\mark :6
    \\committer C O Mitter <committer@example.com> 1700000400 +0000
    \\data 6
    \\merge
    \\merge :5
    \\deleteall
    \\M 100644 :1 only.txt
    \\C only.txt deep/er/copy.txt
    \\
    \\commit refs/heads/from-branch
    \\committer C O Mitter <committer@example.com> 1700000450 +0000
    \\data 12
    \\from branch
    \\from refs/heads/side
    \\M 100644 :2 dir/second.txt
    \\
    \\tag v1
    \\from :4
    \\tagger T Agger <t@example.com> 1700000500 +0000
    \\data 8
    \\release
    \\
    \\tag v2
    \\from refs/heads/side
    \\data 9
    \\untagged
    \\
    \\reset refs/tags/light
    \\from :5
    \\
    \\alias
    \\mark :7
    \\to :4
    \\
    \\get-mark :7
    \\ls :3 dir
    \\ls :6 ""
    \\progress done importing
    \\checkpoint
    \\
    \\commit refs/notes/commits
    \\committer N <n@example.com> 1700000600 +0000
    \\data 6
    \\notes
    \\N inline :3
    \\data 5
    \\note
    \\N :1 :4
    \\
    \\reset refs/heads/gone
    \\from :3
    \\
    \\reset refs/heads/gone
    \\from 0000000000000000000000000000000000000000
    \\
    \\done
    \\
;

test "a stream of every command imports to the objects and refs git makes, and answers as git answers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = try .init(gpa, io);
    defer pair.deinit();
    try pair.mine.exec(io, &.{ "config", "core.ignorecase", "false" });
    try pair.theirs.exec(io, &.{ "config", "core.ignorecase", "false" });
    var report = try pair.import(gpa, io, stream_one, &.{"--export-marks=marks"}, .{ .who = who, .export_marks = "marks" });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.rejected.len);
    const a = try pair.theirs.readFile(io, "marks");
    defer gpa.free(a);
    const b = try pair.mine.readFile(io, "marks");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(usize, 7), report.marks.map.count());
}

test "quoted tab filenames import as git imports them where NTFS protection permits them" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = try .init(gpa, io);
    defer pair.deinit();
    const stream = try std.mem.replaceOwned(u8, gpa, stream_one, "quoted name.txt", "quoted\\tname.txt");
    defer gpa.free(stream);
    var report = try pair.import(gpa, io, stream, &.{}, .{ .who = who });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.rejected.len);
}

test "an incremental import reads the marks, continues a branch from itself, and leaves a branch that would lose commits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = try .init(gpa, io);
    defer pair.deinit();
    var first = try pair.import(gpa, io, stream_one, &.{"--export-marks=marks"}, .{ .who = who, .export_marks = "marks" });
    first.deinit();
    const stream_two =
        \\commit refs/heads/main
        \\committer C O Mitter <committer@example.com> 1700001000 +0000
        \\data 5
        \\more
        \\from refs/heads/main^0
        \\M 100644 :2 again.txt
        \\
        \\commit refs/heads/side
        \\committer C O Mitter <committer@example.com> 1700001100 +0000
        \\data 4
        \\nff
        \\from :3
        \\
        \\commit refs/heads/new
        \\committer C O Mitter <committer@example.com> 1700001200 +0000
        \\data 4
        \\new
        \\merge :4
        \\merge :5
        \\M 100644 :1 merged.txt
        \\
    ;
    var second = try pair.import(gpa, io, stream_two, &.{"--import-marks=marks"}, .{ .who = who, .import_marks = "marks" });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.rejected.len);
    try std.testing.expectEqualStrings("refs/heads/side", second.rejected[0].name);
    try std.testing.expectEqual(fastimport.Rejected.Reason.not_fast_forward, second.rejected[0].reason);

    // With force, as git's --force, the branch moves.
    var forced = try pair.import(gpa, io, stream_two, &.{ "--import-marks=marks", "--force" }, .{ .who = who, .import_marks = "marks", .force = true });
    defer forced.deinit();
    try std.testing.expectEqual(@as(usize, 0), forced.rejected.len);
}

test "a notes ref changes its fanout as git's does, both ways" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = try .init(gpa, io);
    defer pair.deinit();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const count = 300;
    for (0..count) |i| {
        try stream.print(gpa, "commit refs/heads/many\nmark :{d}\ncommitter C <c@example.com> {d} +0000\ndata 0\n", .{ i + 1, 1700000000 + i });
        try stream.print(gpa, "M 100644 inline f\ndata <<E\n{d}\nE\n\n", .{i});
    }
    try stream.appendSlice(gpa, "commit refs/notes/commits\ncommitter N <n@example.com> 1700009000 +0000\ndata 3\nup\n");
    for (0..count) |i| try stream.print(gpa, "N inline :{d}\ndata <<E\nnote {d}\nE\n", .{ i + 1, i });
    try stream.appendSlice(gpa, "\ncommit refs/notes/commits\ncommitter N <n@example.com> 1700009100 +0000\ndata 5\ndown\n");
    for (0..count - 10) |i| try stream.print(gpa, "N 0000000000000000000000000000000000000000 :{d}\n", .{i + 1});
    try stream.appendSlice(gpa, "\n");
    var report = try pair.import(gpa, io, stream.items, &.{}, .{ .who = who });
    defer report.deinit();
    const notes = try pair.mine.run(io, &.{ "ls-tree", "-r", "--name-only", "refs/notes/commits~1" });
    defer gpa.free(notes);
    try std.testing.expect(std.mem.findScalar(u8, notes, '/') != null);
}

test "rfc2822 dates, signatures kept or dropped, and signed tags as the mode says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // `gpgsig <algo> <format>` is git 2.52's.
    if (!try testgit.gitAtLeast(gpa, io, 2, 52)) return error.SkipZigTest;
    const stream =
        \\feature date-format=rfc2822
        \\commit refs/heads/main
        \\mark :1
        \\committer C O Mitter <c@example.com> Tue, 14 Nov 2023 22:13:20 +0100
        \\gpgsig sha1 openpgp
        \\data 62
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\abc
        \\-----END PGP SIGNATURE-----
        \\data 7
        \\signed
        \\M 100644 inline a
        \\data 2
        \\a
        \\
        \\tag t
        \\from :1
        \\tagger T <t@example.com> Wed, 15 Nov 2023 10:00:00 -0500
        \\data 71
        \\message
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\sig
        \\-----END PGP SIGNATURE-----
        \\
    ;
    {
        var pair: Pair = try .init(gpa, io);
        defer pair.deinit();
        var r = try pair.import(gpa, io, stream, &.{}, .{ .who = who });
        r.deinit();
    }
    {
        var pair: Pair = try .init(gpa, io);
        defer pair.deinit();
        var r = try pair.import(gpa, io, stream, &.{ "--signed-commits=strip", "--signed-tags=strip" }, .{
            .who = who,
            .signed_commits = .strip,
            .signed_tags = .strip,
        });
        r.deinit();
    }
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var input: Io.Reader = .fixed(stream);
    try std.testing.expectError(error.SignedObject, fastimport.import(gpa, io, &repo, &input, .{ .who = who, .signed_commits = .abort }));
}

test "what git's fast-import refuses is refused by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const cases = [_]struct { stream: []const u8, err: anyerror, options: fastimport.Options = .{ .who = who } }{
        .{ .stream = "frobnicate\n", .err = error.UnsupportedCommand },
        .{ .stream = "commit refs/heads/x\ndata 0\n", .err = error.MissingCommitter },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 0\nM 100644 :9 f\n", .err = error.UnknownMark },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +2500\ndata 0\n", .err = error.InvalidDate },
        .{ .stream = "commit refs/heads/x\ncommitter A a> 1 +0000\ndata 0\n", .err = error.InvalidIdent },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 0\nM 100600 inline f\ndata 0\n", .err = error.InvalidMode },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 0\nM 100644 inline .git/config\ndata 0\n", .err = error.InvalidPath },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 0\nR nope there\n", .err = error.PathNotInBranch },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 10\nshort", .err = error.TruncatedData },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 0\nfrom refs/heads/x\n", .err = error.BranchFromItself },
        .{ .stream = "commit refs/heads/x\ncommitter A <a> 1 +0000\ndata 0\nfrom no-such-thing\n", .err = error.BadRevision },
        .{ .stream = "feature export-marks=m\n", .err = error.UnsafeFeature },
        .{ .stream = "feature no-such-feature\n", .err = error.UnsupportedFeature },
        .{ .stream = "blob\ndata 0\nfeature done\n", .err = error.LateFeature },
        .{ .stream = "feature done\nblob\ndata 0\n", .err = error.StreamEndsEarly },
        .{ .stream = "commit bad..name\ncommitter A <a> 1 +0000\ndata 0\n", .err = error.InvalidRefName },
        // git's "refusing to update pseudoref"; and, beyond git, a name of
        // one level that would write over the index.
        .{ .stream = "commit FETCH_HEAD\ncommitter A <a> 1 +0000\ndata 0\n", .err = error.InvalidRefName },
        .{ .stream = "commit index\ncommitter A <a> 1 +0000\ndata 0\n", .err = error.InvalidRefName },
    };
    for (cases) |case| {
        var input: Io.Reader = .fixed(case.stream);
        const result = fastimport.import(gpa, io, &repo, &input, case.options);
        if (result) |r| {
            var report = r;
            report.deinit();
            std.debug.print("accepted: {s}\n", .{case.stream});
            return error.TestExpectedError;
        } else |err| std.testing.expectEqual(case.err, err) catch |e| {
            std.debug.print("stream: {s}\n", .{case.stream});
            return e;
        };
    }
}

/// A commit stream writing one file `levels` directories down, `a/` each.
fn deepStream(gpa: Allocator, levels: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "commit refs/heads/main\ncommitter A <a@a> 1 +0000\ndata 0\nM 100644 inline ");
    for (0..levels) |_| try out.appendSlice(gpa, "a/");
    try out.appendSlice(gpa, "f\ndata 2\nx\n");
    return out.toOwnedSlice(gpa);
}

test "a path as deep as git's tree limit imports as git's does, and a deeper one, or a copy that stacks past it, is refused rather than overflowing the stack" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    {
        var pair = try Pair.init(gpa, io);
        defer pair.deinit();
        const at_limit = try deepStream(gpa, object.max_tree_depth - 1);
        defer gpa.free(at_limit);
        var report = try pair.import(gpa, io, at_limit, &.{}, .{ .who = who });
        report.deinit();
    }
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    // The reviewer's stream: ten thousand directories, which git's
    // fast-import takes and its other walks refuse.
    const deep = try deepStream(gpa, 10000);
    defer gpa.free(deep);
    var input: Io.Reader = .fixed(deep);
    try std.testing.expectError(error.TreeTooDeep, fastimport.import(gpa, io, &repo, &input, .{ .who = who }));

    // Each path within the limit, and `b` twenty levels deep: copying it
    // to the bottom of a path two thousand deep makes a tree past it.
    var both: std.ArrayList(u8) = .empty;
    defer both.deinit(gpa);
    try both.appendSlice(gpa, "commit refs/heads/other\ncommitter A <a@a> 1 +0000\ndata 0\nM 100644 inline b/");
    for (0..20) |_| try both.appendSlice(gpa, "c/");
    try both.appendSlice(gpa, "g\ndata 2\ny\nC b ");
    for (0..object.max_tree_depth - 10) |_| try both.appendSlice(gpa, "a/");
    try both.appendSlice(gpa, "b\n");
    var copy_input: Io.Reader = .fixed(both.items);
    try std.testing.expectError(error.TreeTooDeep, fastimport.import(gpa, io, &repo, &copy_input, .{ .who = who }));
}
