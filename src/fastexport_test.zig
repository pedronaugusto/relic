//! `fastexport` against `git fast-export`: one history, the stream each
//! writes for the same refs and options, byte for byte; and that stream read
//! back by `fastimport` makes the objects git's fast-import makes of it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fastexport = @import("fastexport.zig");
const fastimport = @import("fastimport.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const testgit = @import("testing/git.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

fn commitAt(io: Io, git: *testgit.Repo, secs: i64, message: []const u8) !void {
    var env = try testgit.datedEnv(git.gpa, secs);
    defer env.deinit();
    const saved = git.environ;
    git.environ = &env;
    defer git.environ = saved;
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", message });
}

/// A history with what a stream has to say: files, an executable, a
/// symlink, quoted names, a rename, a deletion, a file become a directory,
/// a gitlink, a merge, a commit in another encoding, a signed commit,
/// annotated, lightweight and nested tags, a tag of a blob, one with no
/// tagger, and notes.
fn fixture(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    try git.exec(io, &.{ "config", "core.ignorecase", "false" });
    try git.writeFile(io, "README", "readme\n");
    try git.writeFile(io, "src/main.c", "int main(void) { return 0; }\n");
    try git.writeFile(io, "src/util.c", "/* a long enough file to be found again after a rename */\nint util(void) { return 1; }\nint other(void) { return 2; }\n");
    try git.writeFile(io, "run.sh", "#!/bin/sh\necho run\n");
    try git.writeFile(io, "with space.txt", "spaced\n");
    // Windows cannot create control characters in filenames.
    if (builtin.os.tag != .windows) try git.writeFile(io, "tab\there.txt", "tabbed\n");
    try git.writeFile(io, "h\xc3\xa9llo.txt", "accented\n");
    try git.exec(io, &.{ "add", "." });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "run.sh" });
    const blob = try git.line(io, &.{ "hash-object", "-w", "README" });
    defer gpa.free(blob);
    const link_spec = try std.fmt.allocPrint(gpa, "120000,{s},link", .{blob});
    defer gpa.free(link_spec);
    try git.exec(io, &.{ "update-index", "--add", "--cacheinfo", link_spec });
    try git.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000,0123456789012345678901234567890123456789,sub" });
    try commitAt(io, git, 1_700_000_000, "first");

    try git.exec(io, &.{ "mv", "src/util.c", "src/helpers.c" });
    try git.exec(io, &.{ "rm", "-q", "README" });
    try git.writeFile(io, "src/main.c", "int main(void) { return 1; }\n");
    try git.exec(io, &.{ "add", "src" });
    try commitAt(io, git, 1_700_000_100, "rename and delete");

    try git.exec(io, &.{ "checkout", "-q", "-b", "side", "HEAD~1" });
    try git.exec(io, &.{ "rm", "-q", "-f", "run.sh" });
    try git.writeFile(io, "run.sh/inner", "now a directory\n");
    try git.exec(io, &.{ "add", "run.sh" });
    try commitAt(io, git, 1_700_000_050, "file to directory");
    try git.exec(io, &.{ "-c", "i18n.commitEncoding=ISO-8859-1", "commit", "-q", "--allow-empty", "-m", "caf\xe9" });

    try git.exec(io, &.{ "checkout", "-q", "main" });
    {
        var env = try testgit.datedEnv(gpa, 1_700_000_200);
        defer env.deinit();
        const saved = git.environ;
        git.environ = &env;
        defer git.environ = saved;
        try git.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });
    }

    // Git 2.50 introduced embedded signatures in the stream. Older
    // oracles still compare the same history with an unsigned commit.
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const tree = try git.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree);
    const signed = try std.fmt.allocPrint(gpa,
        \\tree {s}
        \\parent {s}
        \\author A U Thor <author@example.com> 1700000300 +0000
        \\committer C O Mitter <committer@example.com> 1700000300 +0000
        \\{s}
        \\signed
        \\
    , .{ tree, head, if (try testgit.gitAtLeast(gpa, io, 2, 50)) "gpgsig -----BEGIN PGP SIGNATURE-----\n\n c2lnbmF0dXJl\n -----END PGP SIGNATURE-----\n" else "" });
    defer gpa.free(signed);
    const signed_oid = try git.runInput(io, &.{ "hash-object", "-t", "commit", "-w", "--stdin" }, signed);
    defer gpa.free(signed_oid);
    try git.exec(io, &.{ "update-ref", "refs/heads/main", std.mem.trimEnd(u8, signed_oid, "\n") });

    try git.exec(io, &.{ "tag", "light", "HEAD~1" });
    {
        var env = try testgit.datedEnv(gpa, 1_700_000_400);
        defer env.deinit();
        const saved = git.environ;
        git.environ = &env;
        defer git.environ = saved;
        try git.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1", "HEAD" });
        try git.exec(io, &.{ "tag", "-a", "-m", "of a tag", "v1-again", "v1" });
        try git.exec(io, &.{ "tag", "-a", "-m", "of a blob", "blob-tag", blob });
        try git.exec(io, &.{ "notes", "add", "-m", "a note", "HEAD~1" });
    }
    const target = try git.line(io, &.{ "rev-parse", "side" });
    defer gpa.free(target);
    const bare_tag = try std.fmt.allocPrint(gpa, "object {s}\ntype commit\ntag untagged\n\nno tagger here\n", .{target});
    defer gpa.free(bare_tag);
    const bare_oid = try git.runInput(io, &.{ "hash-object", "-t", "tag", "-w", "--literally", "--stdin" }, bare_tag);
    defer gpa.free(bare_oid);
    try git.exec(io, &.{ "update-ref", "refs/tags/untagged", std.mem.trimEnd(u8, bare_oid, "\n") });
}

/// Every ref, as `--all` gives them to git: in name order.
fn allTips(gpa: Allocator, io: Io, git: *testgit.Repo, arena: Allocator) ![]fastexport.Tip {
    const listed = try git.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(listed);
    var tips: std.ArrayList(fastexport.Tip) = .empty;
    var lines = std.mem.splitScalar(u8, listed, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, l, ' ').?;
        try tips.append(arena, .{ .name = try arena.dupe(u8, l[0..space]), .oid = try Oid.parse(.sha1, l[space + 1 ..]) });
    }
    return tips.items;
}

fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, args: []const []const u8, options: fastexport.Options) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "fast-export");
    try argv.appendSlice(gpa, args);
    const theirs = try git.run(io, argv.items);
    defer gpa.free(theirs);

    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var mine: Io.Writer.Allocating = .init(gpa);
    errdefer mine.deinit();
    var opts = options;
    opts.cwd = git.dir;
    try fastexport.write(gpa, io, &repo, &mine.writer, opts);
    std.testing.expectEqualStrings(theirs, mine.written()) catch |err| {
        std.debug.print("git fast-export {any}\n", .{args});
        return err;
    };
    return mine.toOwnedSlice();
}

test "every ref exports as git exports it, and imports back to the same objects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(gpa, io, &git);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const tips = try allTips(gpa, io, &git, arena_state.allocator());

    const plain = try compare(gpa, io, &git, &.{ "--reencode=no", "--signed-tags=verbatim", "--tag-of-filtered-object=drop", "--all" }, .{
        .tips = tips,
        .reencode = .no,
        .signed_tags = .verbatim,
        .tag_of_filtered = .drop,
    });
    gpa.free(plain);
    const signatures = try testgit.gitAtLeast(gpa, io, 2, 50);
    const stream_args: []const []const u8 = if (signatures)
        &.{ "--reencode=no", "--signed-commits=verbatim", "--mark-tags", "--fake-missing-tagger", "--all" }
    else
        &.{ "--reencode=no", "--mark-tags", "--fake-missing-tagger", "--all" };
    const stream = try compare(gpa, io, &git, stream_args, .{
        .tips = tips,
        .reencode = .no,
        .signed_commits = .verbatim,
        .mark_tags = true,
        .fake_missing_tagger = true,
    });
    defer gpa.free(stream);

    // Read back by this and by git, the stream makes the same refs. Not
    // always the refs it came from: git writes a file become a directory
    // as the directory's files and then the file's deletion, which takes
    // the directory with it, and its fast-import reads it so.
    var back = try testgit.Repo.init(gpa, io, &.{});
    defer back.deinit();
    var back_git = try testgit.Repo.init(gpa, io, &.{});
    defer back_git.deinit();
    gpa.free(try back_git.runInput(io, &.{ "fast-import", "--quiet" }, stream));
    var repo = try Repository.open(gpa, io, back.dir, .{});
    defer repo.deinit(io);
    var input: Io.Reader = .fixed(stream);
    var report = try fastimport.import(gpa, io, &repo, &input, .{ .who = who });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.rejected.len);
    const a = try back_git.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(a);
    const b = try back.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "options shape the stream as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(gpa, io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const main = try git.line(io, &.{ "rev-parse", "main" });
    defer gpa.free(main);
    const side = try git.line(io, &.{ "rev-parse", "side" });
    defer gpa.free(side);
    const side_parent = try git.line(io, &.{ "rev-parse", "side~1" });
    defer gpa.free(side_parent);
    const v1 = try git.line(io, &.{ "rev-parse", "v1" });
    defer gpa.free(v1);
    const main_oid = try Oid.parse(.sha1, main);
    const side_oid = try Oid.parse(.sha1, side);
    const tips = [_]fastexport.Tip{
        .{ .name = "refs/heads/main", .oid = main_oid },
        .{ .name = "refs/heads/side", .oid = side_oid },
    };

    const cases = [_]struct { args: []const []const u8, options: fastexport.Options }{
        .{ .args = &.{ "--reencode=no", "-M", "main", "side" }, .options = .{ .tips = &tips, .reencode = .no, .renames = .{} } },
        .{ .args = &.{ "--reencode=no", "-C", "main", "side" }, .options = .{ .tips = &tips, .reencode = .no, .renames = .{ .detect_copies = true } } },
        .{ .args = &.{ "--reencode=no", "--no-data", "main", "side" }, .options = .{ .tips = &tips, .reencode = .no, .no_data = true } },
        .{ .args = &.{ "--reencode=no", "--full-tree", "--use-done-feature", "--progress=2", "--show-original-ids", "main", "side" }, .options = .{
            .tips = &tips,
            .reencode = .no,
            .full_tree = true,
            .use_done_feature = true,
            .progress = 2,
            .show_original_ids = true,
        } },
        .{ .args = &.{ "--reencode=no", "--signed-commits=verbatim", "main", "^side~1" }, .options = .{
            .tips = tips[0..1],
            .exclude = &.{try Oid.parse(.sha1, side_parent)},
            .reencode = .no,
            .signed_commits = .verbatim,
        } },
        .{ .args = &.{ "--reencode=no", "--reference-excluded-parents", "main", "side", "^side~1" }, .options = .{
            .tips = &tips,
            .exclude = &.{try Oid.parse(.sha1, side_parent)},
            .reencode = .no,
            .reference_excluded_parents = true,
        } },
        .{ .args = &.{ "--reencode=no", "--refspec=refs/heads/*:refs/heads/other/*", "--refspec=:refs/heads/deleted", "main", "side" }, .options = .{
            .tips = &tips,
            .reencode = .no,
            .refspecs = &.{ "refs/heads/*:refs/heads/other/*", ":refs/heads/deleted" },
        } },
        .{ .args = &.{ "--tag-of-filtered-object=drop", "v1", "^main" }, .options = .{
            .tips = &.{.{ .name = "refs/tags/v1", .oid = try Oid.parse(.sha1, v1) }},
            .exclude = &.{main_oid},
            .tag_of_filtered = .drop,
        } },
        .{ .args = &.{ "--tag-of-filtered-object=rewrite", "v1", "^main" }, .options = .{
            .tips = &.{.{ .name = "refs/tags/v1", .oid = try Oid.parse(.sha1, v1) }},
            .exclude = &.{main_oid},
            .tag_of_filtered = .rewrite,
        } },
    };
    const signatures = try testgit.gitAtLeast(gpa, io, 2, 50);
    for (cases) |case| {
        if (!signatures and case.options.signed_commits == .verbatim) continue;
        const out = try compare(gpa, io, &git, case.args, case.options);
        gpa.free(out);
    }

    // What git refuses by default is refused by name.
    var sink: Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.EncodedCommit, fastexport.write(gpa, io, &repo, &sink.writer, .{ .tips = &tips }));
    if (signatures) try std.testing.expectError(error.SignedObject, fastexport.write(gpa, io, &repo, &sink.writer, .{ .tips = &tips, .reencode = .no, .signed_commits = .abort }));
}

test "marks carry an export on from where the last one stopped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(gpa, io, &git);
    const side = try git.line(io, &.{ "rev-parse", "side" });
    defer gpa.free(side);
    const tips = [_]fastexport.Tip{.{ .name = "refs/heads/side", .oid = try Oid.parse(.sha1, side) }};
    const first = try compare(gpa, io, &git, &.{ "--reencode=no", "--export-marks=git-marks", "side" }, .{ .tips = &tips, .reencode = .no, .export_marks = "relic-marks" });
    gpa.free(first);
    const a = try git.readFile(io, "git-marks");
    defer gpa.free(a);
    const b = try git.readFile(io, "relic-marks");
    defer gpa.free(b);
    const sorted_a = try sortedLines(gpa, a);
    defer gpa.free(sorted_a);
    const sorted_b = try sortedLines(gpa, b);
    defer gpa.free(sorted_b);
    try std.testing.expectEqualStrings(sorted_a, sorted_b);

    try commitAt(io, &git, 1_700_001_000, "later");
    const main = try git.line(io, &.{ "rev-parse", "main" });
    defer gpa.free(main);
    const more = [_]fastexport.Tip{.{ .name = "refs/heads/main", .oid = try Oid.parse(.sha1, main) }};
    const second = try compare(gpa, io, &git, &.{ "--reencode=no", "--import-marks=git-marks", "main" }, .{ .tips = &more, .reencode = .no, .import_marks = "relic-marks" });
    gpa.free(second);
}

fn sortedLines(gpa: Allocator, text: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len > 0) try lines.append(gpa, l);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return std.mem.join(gpa, "\n", lines.items);
}
