//! A commit's diff by git 2.55's `--diff-merges` formats: `git diff-tree
//! -p --diff-merges=<format>` for a root commit, a commit with one parent,
//! a merge that met conflicts (content, modify/delete, a rename), a clean
//! one and an octopus -- first parent, separate, combined, dense combined
//! and remerge, with renames, under a pathspec and in diff3 style -- and
//! what `-m` shows under `log.diffMerges`, as `git log -m -p` writes it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const commit_diff = @import("../patch/commit_diff.zig");
const pathspec = @import("../patterns.zig").pathspec;
const hash = @import("../hash/hash.zig");

const body = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\n";

fn commitAll(io: Io, repo: *testgit.Repo, message: []const u8) !void {
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", message });
}

/// A merge commit of the index's tree over `parents`, at `ref`.
fn mergeCommit(io: Io, repo: *testgit.Repo, ref: []const u8, parents: []const []const u8) !void {
    const gpa = repo.gpa;
    const tree = try repo.line(io, &.{"write-tree"});
    defer gpa.free(tree);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "commit-tree", tree, "-m", "merge" });
    for (parents) |p| try args.appendSlice(gpa, &.{ "-p", p });
    const commit = try repo.line(io, args.items);
    defer gpa.free(commit);
    try repo.exec(io, &.{ "update-ref", ref, commit });
}

fn setup(io: Io, repo: *testgit.Repo) !void {
    try repo.writeFile(io, "f", "1\n2\n3\n4\n5\n6\n7\n8\n9\n");
    try repo.writeFile(io, "g", "g\n");
    try repo.writeFile(io, "d", "delete me\n");
    try repo.writeFile(io, "moved", body);
    try repo.writeFile(io, "same", "same\n");
    try commitAll(io, repo, "base");
    try repo.exec(io, &.{ "branch", "side" });
    try repo.exec(io, &.{ "branch", "third" });
    try repo.exec(io, &.{ "branch", "clean" });

    try repo.writeFile(io, "f", "1\n2 main\n3\n4\n5\n6\n7\n8\n9\n");
    try repo.writeFile(io, "d", "delete me, main\n");
    try repo.writeFile(io, "moved", "ALPHA\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\n");
    try commitAll(io, repo, "main\n\nwith a body");

    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.writeFile(io, "f", "1\n2 side\n3\n4\n5\n6\n7\n8\n9 side\n");
    try repo.exec(io, &.{ "rm", "-q", "d" });
    try repo.exec(io, &.{ "mv", "moved", "renamed" });
    try repo.writeFile(io, "g", "g side\n");
    try commitAll(io, repo, "side");

    try repo.exec(io, &.{ "checkout", "-q", "third" });
    try repo.writeFile(io, "same", "same third\n");
    try commitAll(io, repo, "third");

    try repo.exec(io, &.{ "checkout", "-q", "clean" });
    try repo.writeFile(io, "f", "1\n2\n3\n4\n5\n6\n7\n8\n9 clean\n");
    try commitAll(io, repo, "clean");

    // main and side, resolved by hand and with a change of the merge's own.
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "f", "1\n2 merged\n3\n4\n5\n6\n7\n8\n9 side\n");
    try repo.exec(io, &.{ "mv", "moved", "renamed" });
    try repo.writeFile(io, "g", "g side, and the merge's\n");
    try repo.exec(io, &.{ "add", "-A" });
    try mergeCommit(io, repo, "refs/heads/merged", &.{ "main", "side" });

    // main and clean, merged as git merges them.
    try repo.exec(io, &.{ "reset", "-q", "--hard", "main" });
    try repo.exec(io, &.{ "merge", "-q", "--no-edit", "clean" });
    try repo.exec(io, &.{ "branch", "cleanly", "HEAD" });

    try repo.exec(io, &.{ "reset", "-q", "--hard", "main" });
    try repo.writeFile(io, "same", "same third\n");
    try repo.exec(io, &.{ "add", "-A" });
    try mergeCommit(io, repo, "refs/heads/octopus", &.{ "main", "side", "third" });
    try repo.exec(io, &.{ "reset", "-q", "--hard", "main" });
}

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

fn parentsOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) ![]hash.Oid {
    const spec = try std.mem.concat(gpa, u8, &.{ rev, "^@" });
    defer gpa.free(spec);
    const listed = try git.run(io, &.{ "rev-parse", spec });
    defer gpa.free(listed);
    var out: std.ArrayList(hash.Oid) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, listed, '\n');
    while (it.next()) |p| try out.append(gpa, try hash.Oid.parse(.sha1, p));
    return out.toOwnedSlice(gpa);
}

const Case = struct {
    rev: []const u8,
    merges: commit_diff.Merges,
    root: bool = false,
    renames: bool = false,
    path: ?[]const u8 = null,
};

fn mergesName(m: commit_diff.Merges) []const u8 {
    return switch (m) {
        .off => "off",
        .first_parent => "first-parent",
        .separate => "separate",
        .combined => "combined",
        .dense_combined => "dense-combined",
        .remerge => "remerge",
    };
}

/// relic's parts of `rev`'s diff, one after another, each after `header`.
fn ours(gpa: Allocator, io: Io, git: *testgit.Repo, case: Case, options: commit_diff.Options, header: []const u8) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const commit = try oidOf(gpa, io, git, case.rev);
    const parents = try parentsOf(gpa, io, git, case.rev);
    defer gpa.free(parents);
    const parts = try commit_diff.parts(arena.allocator(), parents, case.merges, case.root);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (parts) |part| {
        try out.writer.writeAll(header);
        // diff-tree writes the commit's line before the warning even under
        // `--no-commit-id`: its header, which is the caller's to write.
        if (part == .octopus_skipped and header.len == 0) {
            var hex: [hash.max_hex_len]u8 = undefined;
            try out.writer.print("{s}\n", .{commit.hex(&hex)});
        }
        try commit_diff.write(gpa, io, &out.writer, .{ .repo = &repo, .commit = commit, .part = part }, options);
    }
    return out.toOwnedSlice();
}

fn expectDiffTree(gpa: Allocator, io: Io, git: *testgit.Repo, case: Case) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    const format = try std.mem.concat(gpa, u8, &.{ "--diff-merges=", mergesName(case.merges) });
    defer gpa.free(format);
    try args.appendSlice(gpa, &.{ "diff-tree", "--no-commit-id", "-p", format });
    if (case.root) try args.append(gpa, "--root");
    if (case.renames) try args.append(gpa, "-M");
    try args.append(gpa, case.rev);
    if (case.path) |p| try args.appendSlice(gpa, &.{ "--", p });
    const theirs = try git.run(io, args.items);
    defer gpa.free(theirs);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var spec: ?pathspec.Pathspec = if (case.path) |p| try pathspec.parse(arena.allocator(), &.{p}) else null;
    const mine = try ours(gpa, io, git, case, .{ .tree = .{
        .renames = if (case.renames) .{} else null,
        .paths = if (spec) |*s| s else null,
    } }, "");
    defer gpa.free(mine);
    std.testing.expectEqualStrings(theirs, mine) catch |err| {
        std.debug.print("case: {s} {s} root={} renames={} path={?s}\n", .{ case.rev, mergesName(case.merges), case.root, case.renames, case.path });
        return err;
    };
}

test "a commit's diff by every --diff-merges format is git diff-tree's, remerge diffs and their conflicts included" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    git.environ = &env;
    try setup(io, &git);
    const formats = [_]commit_diff.Merges{ .off, .first_parent, .separate, .combined, .dense_combined, .remerge };
    for ([_][]const u8{ "merged", "cleanly", "octopus", "main", "main~1" }) |rev| {
        for (formats) |merges| {
            try expectDiffTree(gpa, io, &git, .{ .rev = rev, .merges = merges, .root = std.mem.eql(u8, rev, "main~1") });
            try expectDiffTree(gpa, io, &git, .{ .rev = rev, .merges = merges, .renames = true });
        }
    }
    for ([_][]const u8{ "f", "g", "d" }) |path| {
        try expectDiffTree(gpa, io, &git, .{ .rev = "merged", .merges = .remerge, .path = path });
    }
    try git.exec(io, &.{ "config", "merge.conflictStyle", "diff3" });
    try expectDiffTree(gpa, io, &git, .{ .rev = "merged", .merges = .remerge });
    try expectDiffTree(gpa, io, &git, .{ .rev = "merged", .merges = .remerge, .renames = true });
}

test "-m shows what log.diffMerges names, as git log -m -p writes it" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    git.environ = &env;
    try setup(io, &git);
    const settings = [_][]const []const u8{ &.{}, &.{"first-parent"}, &.{"1"}, &.{"separate"}, &.{"c"}, &.{"dense-combined"}, &.{"r"}, &.{"none"}, &.{ "cc", "on" }, &.{ "remerge", "m", "combined" } };
    for (settings) |values| {
        git.report_failures = false;
        _ = git.run(io, &.{ "config", "--unset-all", "log.diffMerges" }) catch {}; // glint-ignore: Z026 -- nothing to unset the first time round
        git.report_failures = true;
        for (values) |v| try git.exec(io, &.{ "config", "--add", "log.diffMerges", v });
        const theirs = try git.run(io, &.{ "log", "-1", "-m", "-p", "--no-color", "--format=tformat:X", "merged" });
        defer gpa.free(theirs);

        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        const config = repo.configuration();
        const options: commit_diff.Options = .{
            .diff = try diff.configured(config, .{}),
            .tree = .{ .renames = (try diff.RenameSettings.read(config)).options() },
        };
        const merges = try commit_diff.configured(config);
        const body_text = try ours(gpa, io, &git, .{ .rev = "merged", .merges = merges }, options, "X\n\n");
        defer gpa.free(body_text);
        const mine = if (body_text.len == 0) try gpa.dupe(u8, "X\n") else try gpa.dupe(u8, body_text);
        defer gpa.free(mine);
        std.testing.expectEqualStrings(theirs, mine) catch |err| {
            std.debug.print("log.diffMerges: {any}\n", .{values});
            return err;
        };
    }
    try git.exec(io, &.{ "config", "--replace-all", "log.diffMerges", "bogus" });
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectError(error.InvalidDiffMergesSetting, commit_diff.configured(repo.configuration()));
    try std.testing.expectEqual(null, commit_diff.Merges.parse("Separate", .separate));
}
