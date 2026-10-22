//! External diffs against git 2.55's `git diff --ext-diff`: `diff.external`
//! for every pair and a driver's `command` over it, each handed the path,
//! both sides (a temporary `git-blob-XXXXXX/<name>` holding the blob as a
//! checkout writes it, or the working tree's own file where the index
//! vouches for it, or `/dev/null . .`; an unmerged path's name alone), the
//! new path and metadata of a rename, and which pair of how many; and the exit status each may give,
//! trusted or not.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const history = @import("history.zig");
const suite = @import("helpers.zig");
const diff = @import("../diff/diff.zig");
const driver = @import("../diff/driver.zig");
const external = @import("../diff/external.zig");
const convert = @import("../checkout/convert.zig");

const body = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n";

fn script(io: Io, repo: *testgit.Repo) anyerror!void {
    try repo.writeFile(io, ".gitattributes", "*.crlf text eol=crlf\n*.tool diff=tool\n");
    try repo.writeFile(io, "kept.txt", "kept\n");
    try repo.writeFile(io, "dirty.txt", "dirty before\n");
    try repo.writeFile(io, "lines.crlf", "a\nb\n");
    try repo.writeFile(io, "moved.txt", body);
    try repo.writeFile(io, "gone.txt", "gone\n");
    try repo.writeFile(io, "by.tool", "tool before\n");
    try repo.writeFile(io, "mode.sh", "#!/bin/sh\n");
    try repo.writeFile(io, "kind", "a file, then a link\n");
    try repo.exec(io, &.{ "add", "-A" });
    try addLink(io, repo, "link", "kept.txt");
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.writeFile(io, "kept.txt", "kept, changed\n");
    try repo.writeFile(io, "dirty.txt", "dirty after\n");
    try repo.writeFile(io, "lines.crlf", "a\nb\nc\n");
    try repo.exec(io, &.{ "mv", "moved.txt", "renamed.txt" });
    try repo.writeFile(io, "renamed.txt", body ++ "nine\n");
    try repo.exec(io, &.{ "rm", "-q", "gone.txt" });
    try repo.writeFile(io, "new file.txt", "new\n");
    try repo.writeFile(io, "by.tool", "tool after\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "mode.sh" });
    // Links in the index alone, so a working tree without them serves.
    try addLink(io, repo, "link", "renamed.txt");
    try addLink(io, repo, "kind", "kept.txt");
    try repo.exec(io, &.{ "commit", "-q", "-m", "two" });
    // A change the working tree has and the index does not: that side is
    // written out, not lent.
    try repo.writeFile(io, "dirty.txt", "dirty in the working tree\n");
    // Conflict stages, which `--cached` gives the program by name alone.
    const stage = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "a side\n");
    defer repo.gpa.free(stage);
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(repo.gpa);
    for (1..4) |n| try lines.print(repo.gpa, "100644 {s} {d}\tconflicted.txt\n", .{ std.mem.trimEnd(u8, stage, "\n"), n });
    const out = try repo.runInput(io, &.{ "update-index", "--index-info" }, lines.items);
    repo.gpa.free(out);
}

fn addLink(io: Io, repo: *testgit.Repo, path: []const u8, target: []const u8) !void {
    const link = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, target);
    defer repo.gpa.free(link);
    const info = try std.mem.concat(repo.gpa, u8, &.{ "120000,", std.mem.trimEnd(u8, link, "\n"), ",", path });
    defer repo.gpa.free(info);
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
}

fn commandOf(gpa: Allocator, status: []const u8) ![]u8 {
    const verb = try std.mem.concat(gpa, u8, &.{ "ext-diff ", status });
    defer gpa.free(verb);
    return testgit.fixtureCommand(gpa, suite.path(.process_fixture), verb);
}

/// relic's `git diff --ext-diff -M HEAD~1 HEAD` in `pair.ours`, or with
/// `cached` its `--cached HEAD~1`, which reads the index and lends the
/// files it vouches for.
fn ours(gpa: Allocator, io: Io, pair: *history.Pair, cached: bool, out: *Io.Writer) !void {
    var repo = try pair.open(io);
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var index = try repo.openIndex(io);
    defer index.deinit();
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    const db = repo.objectDatabase();
    const wt = repo.workDirectory().?;
    var conv: convert.Session = .open(gpa, io, .{ .wt = wt, .kind = db.objectFormat(), .core = rules.core, .index = &index, .db = db });
    defer conv.deinit(io);
    const ext: external.External = .{
        .programs = .{ .environ = &pair.env },
        .command = try external.configured(repo.configuration()),
        .worktree = .{
            .dir = wt,
            .conv = &conv,
            .lends = if (cached) .{ .io = io, .wt = wt, .index = &index, .db = db, .conv = &conv, .rules = rules } else null,
        },
    };
    const options = try diff.configured(repo.configuration(), .{});
    const old = try repo.commitTree(io, try history.oidOf(gpa, io, &pair.ours, "HEAD~1"));
    const new = try repo.commitTree(io, try history.oidOf(gpa, io, &pair.ours, "HEAD"));
    var changes = if (cached)
        try diff.index(gpa, io, db, .{ .tree = old, .index = &index }, .{ .renames = .{}, .hide_intent_to_add = true })
    else
        try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{ .renames = .{} });
    defer changes.deinit();
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = wt, .config = repo.configuration() };
    try diff.unified(gpa, io, out, .{ .db = db, .changes = changes.items, .drivers = drivers, .external = &ext }, options);
}

fn expectSame(gpa: Allocator, io: Io, pair: *history.Pair) !void {
    for ([_]bool{ false, true }) |cached| {
        const args: []const []const u8 = if (cached)
            &.{ "diff", "--ext-diff", "-M", "--cached", "HEAD~1" }
        else
            &.{ "diff", "--ext-diff", "-M", "HEAD~1", "HEAD" };
        const theirs = try pair.git.run(io, args);
        defer gpa.free(theirs);
        var mine: Io.Writer.Allocating = .init(gpa);
        defer mine.deinit();
        try ours(gpa, io, pair, cached, &mine.writer);
        std.testing.expectEqualStrings(theirs, mine.written()) catch |err| {
            std.debug.print("cached: {}\n", .{cached});
            return err;
        };
    }
}

fn setBoth(io: Io, pair: *history.Pair, key: []const u8, value: []const u8) !void {
    for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", key, value });
}

test "diff.external and a driver's command are run as git diff runs them, each side lent or written out" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: history.Pair = undefined;
    try history.Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    const plain = try commandOf(gpa, "0");
    defer gpa.free(plain);
    // A driver's command alone: every other pair is a patch.
    const tool = try commandOf(gpa, "1");
    defer gpa.free(tool);
    try setBoth(io, &pair, "diff.tool.command", tool);
    try setBoth(io, &pair, "diff.tool.trustExitCode", "true");
    try expectSame(gpa, io, &pair);
    try setBoth(io, &pair, "diff.external", plain);
    try expectSame(gpa, io, &pair);
}

test "an external diff's exit status: 0 alone untrusted, 0 or 1 trusted, anything else a failure where git dies" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pair: history.Pair = undefined;
    try history.Pair.init(gpa, io, &pair, .files, script);
    defer pair.deinit();
    const one = try commandOf(gpa, "1");
    defer gpa.free(one);
    try setBoth(io, &pair, "diff.external", one);
    pair.git.report_failures = false;
    try std.testing.expectError(error.GitFailed, pair.git.run(io, &.{ "diff", "--ext-diff", "HEAD~1", "HEAD" }));
    var sink: Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try std.testing.expectError(error.ExternalDiffFailed, ours(gpa, io, &pair, false, &sink.writer));
    pair.git.report_failures = true;

    try setBoth(io, &pair, "diff.trustExitCode", "true");
    try expectSame(gpa, io, &pair);

    const two = try commandOf(gpa, "2");
    defer gpa.free(two);
    try setBoth(io, &pair, "diff.external", two);
    pair.git.report_failures = false;
    try std.testing.expectError(error.GitFailed, pair.git.run(io, &.{ "diff", "--ext-diff", "HEAD~1", "HEAD" }));
    sink.clearRetainingCapacity();
    try std.testing.expectError(error.ExternalDiffFailed, ours(gpa, io, &pair, false, &sink.writer));
}
