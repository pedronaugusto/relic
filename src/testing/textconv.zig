//! `diff.<driver>.textconv` against git 2.55's `git diff`: the patches of a
//! history whose files a driver converts -- a change only the bytes see,
//! a binary file read as text, a rename, a creation and a deletion, a
//! symbolic link left as it is -- and with `cachetextconv` the same
//! `refs/notes/textconv/<driver>` written, and read back.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const history = @import("history.zig");
const suite = @import("helpers.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const driver = @import("../diff/driver.zig");
const textconv = @import("../diff/textconv.zig");
const notes = @import("../commit/notes.zig");
const attributes = @import("../patterns.zig").attributes;
const hash = @import("../hash/hash.zig");

const Pair = history.Pair;

fn commitAll(io: Io, repo: *testgit.Repo, subject: []const u8) !void {
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", subject });
}

fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    const command = try testgit.fixtureCommand(repo.gpa, suite.path(.process_fixture), "upper-file");
    defer repo.gpa.free(command);
    try repo.exec(io, &.{ "config", "diff.up.textconv", command });
    try repo.writeFile(io, ".gitattributes", "*.txt diff=up\n*.bin diff=up\n");
    try repo.writeFile(io, "case.txt", "hello\nworld\n");
    try repo.writeFile(io, "data.bin", "a\x00b\n");
    try repo.writeFile(io, "plain.dat", "kept as it is\n");
    try repo.writeFile(io, "gone.txt", "bye\n");
    try commitAll(io, repo, "root");
    // A change only the bytes see, beside a binary file read as text.
    try repo.writeFile(io, "case.txt", "HELLO\nworld\n");
    try repo.writeFile(io, "data.bin", "a\x00c\n");
    try repo.writeFile(io, "plain.dat", "changed as it is\n");
    try commitAll(io, repo, "case");
    try repo.exec(io, &.{ "mv", "case.txt", "renamed.txt" });
    try repo.exec(io, &.{ "rm", "-q", "gone.txt" });
    try repo.writeFile(io, "new.txt", "made\n");
    try commitAll(io, repo, "rename");
    // A symbolic link whose name the driver's pattern takes, which git
    // does not convert, and a change of mode alone.
    const link = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "renamed.txt");
    defer repo.gpa.free(link);
    const info = try std.mem.concat(repo.gpa, u8, &.{ "120000,", std.mem.trimEnd(u8, link, "\n"), ",link.txt" });
    defer repo.gpa.free(info);
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "new.txt" });
    try repo.writeFile(io, "renamed.txt", "HELLO\nthere\n");
    try repo.exec(io, &.{ "add", "renamed.txt" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "link" });
}

const revisions = [_][]const u8{ "HEAD~3", "HEAD~2", "HEAD~1", "HEAD" };

/// Every commit's patch from its parent, the root's from the empty tree,
/// as `git diff -M` prints them.
fn gitPatches(gpa: Allocator, io: Io, git: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const empty = try git.line(io, &.{ "hash-object", "-t", "tree", "/dev/null" });
    defer gpa.free(empty);
    var previous: []const u8 = empty;
    for (revisions) |rev| {
        const text = try git.run(io, &.{ "diff", "--no-color", "-M", previous, rev });
        defer gpa.free(text);
        try out.appendSlice(gpa, text);
        previous = rev;
    }
    return out.toOwnedSlice(gpa);
}

/// What `ourPatches` diffs with.
const Setup = struct { drivers: driver.Drivers, textconv: ?*const textconv.Textconv };

fn ourPatches(gpa: Allocator, io: Io, pair: *Pair, repo: *repo_mod.Repository, setup: Setup) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var previous: ?hash.Oid = null;
    for (revisions) |rev| {
        const tree = try repo.commitTree(io, try history.oidOf(gpa, io, &pair.ours, rev));
        var changes = try diff.tree(gpa, io, repo.objectDatabase(), .{ .old = previous, .new = tree }, .{ .renames = .{} });
        defer changes.deinit();
        try diff.unified(gpa, io, .{ .db = repo.objectDatabase(), .changes = changes.items, .drivers = setup.drivers, .textconv = setup.textconv }, &out.writer, .{});
        previous = tree;
    }
    return out.toOwnedSlice();
}

fn expectSamePatches(gpa: Allocator, io: Io, pair: *Pair, repo: *repo_mod.Repository, setup: Setup) !void {
    const theirs = try gitPatches(gpa, io, &pair.git);
    defer gpa.free(theirs);
    const ours = try ourPatches(gpa, io, pair, repo, setup);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
}

test "a driver's textconv makes the patches git diff prints: case changes gone, a binary file as text, a link left alone" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    var repo = try pair.open(io);
    defer repo.deinit(io);
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = pair.ours.dir, .config = repo.configuration() };
    const tc: textconv.Textconv = .{ .programs = .{ .environ = &pair.env } };
    try expectSamePatches(gpa, io, &pair, &repo, .{ .drivers = drivers, .textconv = &tc });
    // `--no-textconv` is the bytes.
    const plain = try ourPatches(gpa, io, &pair, &repo, .{ .drivers = drivers, .textconv = null });
    defer gpa.free(plain);
    const theirs = try pair.git.run(io, &.{ "diff", "--no-color", "--no-textconv", "-M", "HEAD~3", "HEAD~2" });
    defer gpa.free(theirs);
    try std.testing.expect(std.mem.find(u8, plain, theirs) != null);
}

test "cachetextconv writes git's refs/notes/textconv/<driver>, and a text kept there is the one diffed" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    try testgit.eachRefFormat(struct {
        fn run(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var pair: Pair = undefined;
            try Pair.init(gpa, io, &pair, format, script);
            defer pair.deinit();
            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "diff.up.cachetextconv", "true" });
            var repo = try pair.open(io);
            defer repo.deinit(io);
            var attrs = try attributes.Attrs.init(gpa, .{});
            defer attrs.deinit();
            const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = pair.ours.dir, .config = repo.configuration() };
            var caches: notes.TextconvCaches = .init(gpa, &repo, history.who);
            defer caches.deinit();
            const tc: textconv.Textconv = .{ .programs = .{ .environ = &pair.env }, .cache = caches.cache() };
            try expectSamePatches(gpa, io, &pair, &repo, .{ .drivers = drivers, .textconv = &tc });
            const log_args: []const []const u8 = &.{ "reflog", "--format=%H %gs", "refs/notes/textconv/up" };
            const theirs = try pair.git.run(io, log_args);
            defer gpa.free(theirs);
            const ours = try pair.ours.run(io, log_args);
            defer gpa.free(ours);
            try std.testing.expectEqualStrings(theirs, ours);

            // A text kept for the root's case.txt, under the command it
            // was made by, is what both diff from then on.
            for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try keepText(gpa, io, r);
            var fresh: notes.TextconvCaches = .init(gpa, &repo, history.who);
            defer fresh.deinit();
            var kept = tc;
            kept.cache = fresh.cache();
            try expectSamePatches(gpa, io, &pair, &repo, .{ .drivers = drivers, .textconv = &kept });
            const patch = try pair.git.run(io, &.{ "diff", "--no-color", "HEAD~3", "HEAD~2" });
            defer gpa.free(patch);
            try std.testing.expect(std.mem.find(u8, patch, "-KEPT IN THE CACHE") != null);
        }
    }.run);
}

/// A note for the root's `case.txt` in the driver's cache, its commit
/// named for the command, as git's `notes_cache_write` names it.
fn keepText(gpa: Allocator, io: Io, r: *testgit.Repo) !void {
    const blob = try r.line(io, &.{ "rev-parse", "HEAD~3:case.txt" });
    defer gpa.free(blob);
    try r.exec(io, &.{ "notes", "--ref", "textconv/up", "add", "-f", "-m", "KEPT IN THE CACHE", blob });
    const command = try r.line(io, &.{ "config", "diff.up.textconv" });
    defer gpa.free(command);
    const commit = try r.line(io, &.{ "commit-tree", "refs/notes/textconv/up^{tree}", "-m", command });
    defer gpa.free(commit);
    try r.exec(io, &.{ "update-ref", "refs/notes/textconv/up", commit });
}

test "a textconv that fails is error.TextconvFailed, where git diff dies" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: Pair = undefined;
    try Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "diff.up.textconv", "false" });
    pair.git.report_failures = false;
    try std.testing.expectError(error.GitFailed, pair.git.run(io, &.{ "diff", "HEAD~3", "HEAD~2" }));
    var repo = try pair.open(io);
    defer repo.deinit(io);
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = pair.ours.dir, .config = repo.configuration() };
    const tc: textconv.Textconv = .{ .programs = .{ .environ = &pair.env } };
    try std.testing.expectError(error.TextconvFailed, ourPatches(gpa, io, &pair, &repo, .{ .drivers = drivers, .textconv = &tc }));
}
