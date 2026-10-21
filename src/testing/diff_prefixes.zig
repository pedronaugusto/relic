//! The prefixes on a patch's headers against git 2.55: `diff.noPrefix`,
//! `diff.srcPrefix` and `diff.dstPrefix`, and `diff.mnemonicPrefix`'s
//! letters for what is compared, for `git diff` of two commits and
//! `--cached`; format-patch's are in `patch/format_test.zig`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const hash = @import("../hash/hash.zig");

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

fn setup(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "file.txt", "one\n");
    try git.writeFile(io, "with space.txt", "two\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.writeFile(io, "file.txt", "one, changed\n");
    try git.exec(io, &.{ "mv", "with space.txt", "moved.txt" });
    try git.writeFile(io, "added.txt", "added\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "two" });
}

test "a patch's headers take the prefixes git's settings give for what is compared" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Setting = struct { key: []const u8, value: []const u8 };
    const variants = [_][]const Setting{
        &.{},
        &.{.{ .key = "diff.noPrefix", .value = "true" }},
        &.{ .{ .key = "diff.srcPrefix", .value = "from/" }, .{ .key = "diff.dstPrefix", .value = "to/" } },
        &.{.{ .key = "diff.mnemonicPrefix", .value = "true" }},
        &.{ .{ .key = "diff.mnemonicPrefix", .value = "true" }, .{ .key = "diff.srcPrefix", .value = "from/" } },
        &.{ .{ .key = "diff.mnemonicPrefix", .value = "true" }, .{ .key = "diff.noPrefix", .value = "true" } },
    };
    for (variants) |settings| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try setup(io, &git);
        for (settings) |s| try git.exec(io, &.{ "config", s.key, s.value });
        var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        const db = repo.objectDatabase();
        const old = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD~1"));
        const new = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD"));
        var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{ .renames = .{} });
        defer changes.deinit();
        const Kind = struct { args: []const []const u8, compared: diff.Prefixes.Compared };
        // The index holds `HEAD`, so `--cached HEAD~1` is the same change.
        const kinds = [_]Kind{
            .{ .args = &.{ "diff", "-M", "HEAD~1", "HEAD" }, .compared = .commits },
            .{ .args = &.{ "diff", "-M", "--cached", "HEAD~1" }, .compared = .commit_index },
        };
        for (kinds) |kind| {
            const theirs = try git.run(io, kind.args);
            defer gpa.free(theirs);
            var mine: Io.Writer.Allocating = .init(gpa);
            defer mine.deinit();
            const prefixes = try diff.Prefixes.configured(repo.configuration(), kind.compared);
            try diff.unified(gpa, io, .{ .db = db, .changes = changes.items }, &mine.writer, try diff.configured(repo.configuration(), .{ .prefixes = prefixes }));
            std.testing.expectEqualStrings(theirs, mine.written()) catch |err| {
                for (settings) |s| std.debug.print("{s}={s} ", .{ s.key, s.value });
                std.debug.print("{s}\n", .{@tagName(kind.compared)});
                return err;
            };
        }
    }
}
