//! The combined diff of a merge against git 2.55's `git diff-tree -c` and
//! `--cc`: a merge of two parents that resolves conflicts its own way, takes
//! a file whole from one side, adds and deletes files, changes a mode and a
//! gitlink, has binary, CRLF and unterminated files, a function line above a
//! hunk, a textconv driver, a name quoted; an octopus of three whose
//! parents share a blob; with renames and every parent's path, the context
//! at 0 and 1, whitespace overlooked, an order file, and in colour.

const std = @import("std");
const fs = @import("../fs/fs.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const suite = @import("helpers.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const combined = @import("../diff/combined.zig");
const textconv = @import("../diff/textconv.zig");
const attributes = @import("../patterns.zig").attributes;
const hash = @import("../hash/hash.zig");

const ten = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n";
const body = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\n";
const code = "int main(void)\n{\n\tint a = 1;\n\tint b = 2;\n\tint c = 3;\n\tint d = 4;\n\tint e = 5;\n\tint f = 6;\n\treturn a;\n}\n";

fn replace(comptime text: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const at = std.mem.find(u8, text, from).?;
        return text[0..at] ++ to ++ text[at + from.len ..];
    }
}

fn addLink(io: Io, repo: *testgit.Repo, mode: []const u8, oid_text: []const u8, path: []const u8) !void {
    const info = try std.mem.concat(repo.gpa, u8, &.{ mode, ",", oid_text, ",", path });
    defer repo.gpa.free(info);
    try repo.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
}

const sub_a = "1111111111111111111111111111111111111111";
const sub_b = "2222222222222222222222222222222222222222";
const sub_c = "3333333333333333333333333333333333333333";

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
    const command = try testgit.fixtureCommand(repo.gpa, suite.path(.process_fixture), "upper-file");
    defer repo.gpa.free(command);
    try repo.exec(io, &.{ "config", "diff.up.textconv", command });
    try repo.writeFile(io, ".gitattributes", "*.up diff=up\n*.raw -diff\n");
    try repo.writeFile(io, "both.txt", ten);
    try repo.writeFile(io, "ours.txt", "a\nb\nc\n");
    try repo.writeFile(io, "theirs.txt", "x\ny\nz\n");
    try repo.writeFile(io, "gone.txt", "gone\n");
    try repo.writeFile(io, "mode.sh", "#!/bin/sh\n");
    try repo.writeFile(io, "bin.dat", "\x00bin\n");
    try repo.writeFile(io, "code.c", code);
    try repo.writeFile(io, "crlf.txt", "a\r\nb\r\nc\r\n");
    try repo.writeFile(io, "noeol.txt", "one\ntwo");
    try repo.writeFile(io, "moved.txt", body);
    try repo.writeFile(io, "conv.up", "lower\ncase\n");
    try repo.writeFile(io, "plain.raw", "plain\n");
    try repo.writeFile(io, "caf\xc3\xa9.txt", "accent\n");
    try repo.writeFile(io, "spaces.txt", "a b\nc  d\ne\n");
    try addLink(io, repo, "160000", sub_a, "sub");
    try commitAll(io, repo, "base");
    try repo.exec(io, &.{ "branch", "side" });
    try repo.exec(io, &.{ "branch", "third" });

    try repo.writeFile(io, "both.txt", comptime replace(replace(ten, "two\n", "two main\n"), "five\n", "five main\n"));
    try repo.writeFile(io, "ours.txt", "a\nB\nc\n");
    try repo.writeFile(io, "gone.txt", "gone main\n");
    try repo.writeFile(io, "bin.dat", "\x00bin main\n");
    try repo.writeFile(io, "code.c", comptime replace(code, "\tint e = 5;\n", "\tint e = 50;\n"));
    try repo.writeFile(io, "crlf.txt", "a\r\nB\r\nc\r\n");
    try repo.writeFile(io, "noeol.txt", "one\nTWO");
    try repo.writeFile(io, "moved.txt", comptime replace(body, "alpha\n", "ALPHA\n"));
    try repo.writeFile(io, "conv.up", "lower\ncase main\n");
    try repo.writeFile(io, "plain.raw", "plain main\n");
    try repo.writeFile(io, "caf\xc3\xa9.txt", "accent main\n");
    try repo.writeFile(io, "spaces.txt", "a  b\nc d\ne main\n");
    try addLink(io, repo, "160000", sub_b, "sub");
    try commitAll(io, repo, "main");

    try repo.exec(io, &.{ "checkout", "-q", "side" });
    try repo.writeFile(io, "both.txt", comptime replace(replace(ten, "two\n", "two side\n"), "nine\n", "nine side\n"));
    try repo.writeFile(io, "theirs.txt", "x\nY\nz\n");
    try repo.writeFile(io, "gone.txt", "gone side\n");
    try repo.writeFile(io, "bin.dat", "\x00bin side\n");
    try repo.writeFile(io, "code.c", comptime replace(code, "\tint e = 5;\n", "\tint e = 500;\n"));
    try repo.writeFile(io, "crlf.txt", "a\r\nb\r\nC\r\n");
    try repo.writeFile(io, "noeol.txt", "ONE\ntwo");
    try repo.exec(io, &.{ "mv", "moved.txt", "renamed.txt" });
    try repo.writeFile(io, "renamed.txt", comptime replace(body, "kappa\n", "KAPPA\n"));
    try repo.writeFile(io, "conv.up", "LOWER\ncase\n");
    try repo.writeFile(io, "plain.raw", "plain side\n");
    try repo.writeFile(io, "caf\xc3\xa9.txt", "accent side\n");
    try repo.writeFile(io, "spaces.txt", "a\tb\nc d \ne side\n");
    try addLink(io, repo, "160000", sub_c, "sub");
    try commitAll(io, repo, "side");

    try repo.exec(io, &.{ "checkout", "-q", "third" });
    try repo.writeFile(io, "both.txt", comptime replace(ten, "seven\n", "seven third\n"));
    try repo.writeFile(io, "gone.txt", "gone side\n");
    try repo.writeFile(io, "theirs.txt", "x\nY\nz\n");
    try commitAll(io, repo, "third");

    // The merge of main and side, resolved by hand.
    try repo.exec(io, &.{ "checkout", "-q", "main" });
    try repo.writeFile(io, "both.txt", comptime replace(replace(replace(ten, "two\n", "two merged\n"), "five\n", "five main\n"), "nine\n", "nine side\nextra\n"));
    try repo.writeFile(io, "theirs.txt", "x\nY\nz\n");
    try repo.exec(io, &.{ "rm", "-q", "gone.txt" });
    try repo.writeFile(io, "mode.sh", "#!/bin/sh\necho merged\n");
    try repo.exec(io, &.{ "update-index", "--add", "mode.sh" });
    try repo.writeFile(io, "bin.dat", "\x00bin merged\n");
    try repo.writeFile(io, "new.txt", "brand new\n");
    try repo.writeFile(io, "code.c", comptime replace(code, "\tint e = 5;\n", "\tint e = 5000;\n\tint g = 7;\n"));
    try repo.writeFile(io, "crlf.txt", "a\r\nB\r\nC\r\nd\r\n");
    try repo.writeFile(io, "noeol.txt", "ONE\nTwo");
    try repo.exec(io, &.{ "rm", "-q", "moved.txt" });
    try repo.writeFile(io, "renamed.txt", comptime replace(replace(body, "alpha\n", "ALPHA\n"), "kappa\n", "KAPPA\n"));
    try repo.writeFile(io, "conv.up", "LOWER\ncase main\n");
    try repo.writeFile(io, "plain.raw", "plain merged\n");
    try repo.writeFile(io, "caf\xc3\xa9.txt", "accent merged\n");
    try repo.writeFile(io, "spaces.txt", "a   b\nc d\ne merged\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "update-index", "--chmod=+x", "mode.sh" });
    try addLink(io, repo, "160000", "4444444444444444444444444444444444444444", "sub");
    try mergeCommit(io, repo, "refs/heads/merged", &.{ "main", "side" });

    // An octopus over main, side and third; side and third share some
    // blobs, which the diff against one is reused for the other.
    try repo.exec(io, &.{ "reset", "-q", "--hard", "main" });
    try repo.writeFile(io, "both.txt", comptime replace(replace(replace(ten, "two\n", "two octopus\n"), "five\n", "five main\n"), "seven\n", "seven third\n"));
    try repo.writeFile(io, "theirs.txt", "x\nY\nz\nw\n");
    try repo.writeFile(io, "gone.txt", "gone octopus\n");
    try repo.writeFile(io, "ours.txt", "a\nB\nc\n");
    try repo.exec(io, &.{ "add", "-A" });
    try mergeCommit(io, repo, "refs/heads/octopus", &.{ "main", "side", "third" });
    try repo.exec(io, &.{ "reset", "-q", "--hard", "main" });
}

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

/// One way of writing a merge's combined diff, as relic is asked and as
/// git is.
const Case = struct {
    merge: []const u8,
    dense: bool = true,
    renames: bool = false,
    all_paths: bool = false,
    context: u32 = 3,
    ignore_change: bool = false,
    color: bool = false,
    order: ?[]const u8 = null,
    textconv: bool = false,
};

fn gitArgs(gpa: Allocator, case: Case) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "diff-tree", "--no-commit-id", "-p", if (case.dense) "--cc" else "-c" });
    if (case.renames) try args.append(gpa, "-M");
    if (case.all_paths) try args.append(gpa, "--combined-all-paths");
    if (case.ignore_change) try args.append(gpa, "-b");
    if (case.textconv) try args.append(gpa, "--textconv");
    try args.append(gpa, if (case.color) "--color=always" else "--no-color");
    try args.append(gpa, switch (case.context) {
        0 => "-U0",
        1 => "-U1",
        else => "-U3",
    });
    if (case.order) |o| try args.append(gpa, o);
    try args.append(gpa, case.merge);
    return args.toOwnedSlice(gpa);
}

fn ours(gpa: Allocator, io: Io, git: *testgit.Repo, env: *const std.process.Environ.Map, case: Case) ![]u8 {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const db = repo.objectDatabase();
    const tree_rev = try std.mem.concat(gpa, u8, &.{ case.merge, "^{tree}" });
    defer gpa.free(tree_rev);
    const result = try oidOf(gpa, io, git, tree_rev);
    const parents_rev = try std.mem.concat(gpa, u8, &.{ case.merge, "^@" });
    defer gpa.free(parents_rev);
    const listed = try git.run(io, &.{ "rev-parse", parents_rev });
    defer gpa.free(listed);
    var parents: std.ArrayList(hash.Oid) = .empty;
    defer parents.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, listed, '\n');
    while (it.next()) |p| try parents.append(gpa, try repo.commitTree(io, try hash.Oid.parse(.sha1, p)));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const order: diff.Order = if (case.order) |o| try diff.Order.parse(arena.allocator(), try fs.readWhole(git.dir, io, o["-O".len..], arena.allocator(), .unlimited)) else .{};
    var found = try combined.paths(gpa, io, db, .{ .result = result, .parents = parents.items }, .{ .renames = if (case.renames) .{} else null, .order = order });
    defer found.deinit();
    const colors: diff.Colors = .{};
    const tc: textconv.Textconv = .{ .programs = .{ .environ = env } };
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try combined.write(gpa, io, &out.writer, .{
        .db = db,
        .paths = found.items,
        .drivers = .{ .attrs = &attrs, .work_dir = git.dir, .config = repo.configuration() },
        .textconv = if (case.textconv) &tc else null,
    }, .{
        .diff = .{ .context = case.context, .ignore_whitespace_change = case.ignore_change, .colors = if (case.color) &colors else null },
        .dense = case.dense,
        .all_paths = case.all_paths,
    });
    return out.toOwnedSlice();
}

fn expectCase(gpa: Allocator, io: Io, git: *testgit.Repo, env: *const std.process.Environ.Map, case: Case) !void {
    const args = try gitArgs(gpa, case);
    defer gpa.free(args);
    const theirs = try git.run(io, args);
    defer gpa.free(theirs);
    const mine = try ours(gpa, io, git, env, case);
    defer gpa.free(mine);
    std.testing.expectEqualStrings(theirs, mine) catch |err| {
        std.debug.print("case: {any}\n", .{case});
        return err;
    };
}

test "a merge's combined diff is git diff-tree's, -c and --cc, over two parents and three" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    git.environ = &env;
    try setup(io, &git);
    for ([_][]const u8{ "merged", "octopus" }) |merge| {
        for ([_]bool{ true, false }) |dense| {
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .context = 0 });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .context = 1 });
        }
    }
}

test "renames, every parent's path, overlooked whitespace, an order file and colour in a combined diff are git's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    git.environ = &env;
    try setup(io, &git);
    try git.writeFile(io, "order", "*.txt\nsub\n");
    for ([_][]const u8{ "merged", "octopus" }) |merge| {
        for ([_]bool{ true, false }) |dense| {
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .renames = true });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .renames = true, .all_paths = true });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .ignore_change = true });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .order = "-Oorder" });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .color = true });
            try expectCase(gpa, io, &git, &env, .{ .merge = merge, .dense = dense, .textconv = true });
        }
    }
}
