//! A tree against the index (`diff.index`) as git 2.56's `git diff-index
//! --cached` and `git diff --cached` compare them: files added, deleted,
//! modified, re-moded and turned into links or gitlinks, renames and
//! copies, an intent to add seen by the plumbing and not the porcelain,
//! conflict stages as one unmerged path with or without the tree's side,
//! `--relative` leaving out what lies outside it (unmerged paths too), a
//! pathspec, and a sparse directory as the files of its tree; in raw form,
//! as a patch, a stat and counts.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const stat = @import("../diff/stat.zig");
const pathspec = @import("../patterns.zig").pathspec;
const hash = @import("../hash/hash.zig");

const body = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n";
const other_body = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n";

/// The blob `bytes` make, written; the name is the caller's, ending in a
/// newline.
fn blob(io: Io, git: *testgit.Repo, bytes: []const u8) ![]u8 {
    return git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, bytes);
}

fn trimmed(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\n");
}

/// `lines` into the index as `git update-index --index-info` reads them.
fn indexInfo(io: Io, git: *testgit.Repo, lines: []const u8) !void {
    const out = try git.runInput(io, &.{ "update-index", "--index-info" }, lines);
    git.gpa.free(out);
}

/// Conflict stages at `path`, its merged entry taken out first.
fn conflict(gpa: Allocator, io: Io, git: *testgit.Repo, path: []const u8) !void {
    const zero = "0000000000000000000000000000000000000000";
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    try lines.print(gpa, "0 {s}\t{s}\n", .{ zero, path });
    for ([_][]const u8{ "base\n", "ours\n", "theirs\n" }, 1..) |bytes, stage| {
        const oid = try blob(io, git, bytes);
        defer gpa.free(oid);
        try lines.print(gpa, "100644 {s} {d}\t{s}\n", .{ trimmed(oid), stage, path });
    }
    try indexInfo(io, git, lines.items);
}

fn cacheinfo(gpa: Allocator, io: Io, git: *testgit.Repo, mode: []const u8, oid: []const u8, path: []const u8) !void {
    const info = try std.mem.concat(gpa, u8, &.{ mode, ",", oid, ",", path });
    defer gpa.free(info);
    try git.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
}

fn setup(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a.txt", "a\n");
    try git.writeFile(io, "gone.txt", "gone\n");
    try git.writeFile(io, "mode.sh", "#!/bin/sh\n");
    try git.writeFile(io, "kind", "a file, then a link\n");
    try git.writeFile(io, "moved.txt", body);
    try git.writeFile(io, "source.txt", other_body);
    try git.writeFile(io, "conflict.txt", "before the conflict\n");
    try git.writeFile(io, "dir/c.txt", "c\n");
    try git.writeFile(io, "dir/d.txt", "d\n");
    try git.writeFile(io, "dir/held.txt", "held\n");
    try git.writeFile(io, "dir/sub/e.txt", "e\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });

    try git.writeFile(io, "a.txt", "a, staged\n");
    try git.exec(io, &.{ "rm", "-q", "--cached", "gone.txt" });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "mode.sh" });
    const link = try blob(io, git, "a.txt");
    defer gpa.free(link);
    try git.exec(io, &.{ "rm", "-q", "--cached", "kind" });
    try cacheinfo(gpa, io, git, "120000", trimmed(link), "kind");
    try git.exec(io, &.{ "mv", "moved.txt", "renamed.txt" });
    try git.writeFile(io, "renamed.txt", body ++ "nine\n");
    try git.writeFile(io, "copy.txt", other_body);
    try git.writeFile(io, "new.txt", "new\n");
    // What the conflicted path holds in the tree: `-C` copies it, and
    // `-M` takes no rename from it.
    try git.writeFile(io, "same.txt", "before the conflict\n");
    try git.writeFile(io, "dir/d.txt", "d, staged\n");
    try git.writeFile(io, "dir/f.txt", "f\n");
    try git.exec(io, &.{ "add", "a.txt", "renamed.txt", "copy.txt", "new.txt", "same.txt", "dir/d.txt", "dir/f.txt" });
    try git.writeFile(io, "ita.txt", "intent\n");
    try git.writeFile(io, "dir/ita.txt", "intent\n");
    try git.exec(io, &.{ "add", "-N", "ita.txt", "dir/ita.txt" });
    // A gitlink the index alone holds.
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try cacheinfo(gpa, io, git, "160000", head, "dir/module");
    // Conflicts: on a path the tree has, on one it does not, and on one
    // under `dir/`.
    try conflict(gpa, io, git, "conflict.txt");
    try conflict(gpa, io, git, "fresh.txt");
    try conflict(gpa, io, git, "dir/held.txt");
}

/// git's raw lines (`--raw --no-abbrev`) for `changes`, paths from
/// `relative`.
fn writeRaw(gpa: Allocator, out: *std.ArrayList(u8), kind: hash.Kind, changes: []const diff.Change, relative: []const u8) !void {
    var zero_hex: [hash.max_hex_len]u8 = undefined;
    const zero = hash.Oid.zero(kind).hex(&zero_hex);
    for (changes) |c| {
        var old_hex: [hash.max_hex_len]u8 = undefined;
        var new_hex: [hash.max_hex_len]u8 = undefined;
        try out.print(gpa, ":{o:0>6} {o:0>6} {s} {s} {c}", .{
            if (c.old) |e| e.mode.raw() else 0,
            if (c.new) |e| e.mode.raw() else 0,
            if (c.old) |e| e.oid.hex(&old_hex) else zero,
            if (c.new) |e| e.oid.hex(&new_hex) else zero,
            c.letter(),
        });
        if (c.status == .renamed or c.status == .copied) {
            try out.print(gpa, "{d:0>3}\t{s}\t{s}\n", .{ c.similarity, c.old.?.path[relative.len..], c.new.?.path[relative.len..] });
        } else try out.print(gpa, "\t{s}\n", .{c.path()[relative.len..]});
    }
}

const Variant = struct {
    /// git's arguments after `--no-abbrev`.
    args: []const []const u8,
    options: diff.IndexOptions,
    relative: []const u8 = "",
};

fn expectRaw(gpa: Allocator, io: Io, git: *testgit.Repo, v: Variant) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, v.args[0..1]);
    try argv.appendSlice(gpa, &.{ "--raw", "--no-abbrev" });
    try argv.appendSlice(gpa, v.args[1..]);
    const theirs = try git.run(io, argv.items);
    defer gpa.free(theirs);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const db = repo.objectDatabase();
    var changes = try diff.index(gpa, io, db, .{ .tree = try repo.headTree(io), .index = &index }, v.options);
    defer changes.deinit();
    var mine: std.ArrayList(u8) = .empty;
    defer mine.deinit(gpa);
    try writeRaw(gpa, &mine, db.objectFormat(), changes.items, v.relative);
    std.testing.expectEqualStrings(theirs, mine.items) catch |err| {
        for (argv.items) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print(": differs\n", .{});
        return err;
    };
}

test "a tree against the index is git diff-index --cached's and git diff --cached's, change by change" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(gpa, io, &git);
    var dir_spec = try pathspec.parse(gpa, &.{"dir"});
    defer dir_spec.deinit();
    const variants = [_]Variant{
        // The plumbing sees an intent to add as the empty file it records.
        .{ .args = &.{ "diff-index", "--cached", "HEAD" }, .options = .{} },
        .{ .args = &.{ "diff-index", "--cached", "-M", "HEAD" }, .options = .{ .renames = .{} } },
        .{ .args = &.{ "diff-index", "--cached", "-C", "--find-copies-harder", "HEAD" }, .options = .{ .renames = .{ .detect_copies = true, .find_copies_harder = true } } },
        // The porcelain does not.
        .{ .args = &.{ "diff", "--cached", "--no-renames" }, .options = .{ .hide_intent_to_add = true } },
        .{ .args = &.{ "diff", "--cached", "-M" }, .options = .{ .renames = .{}, .hide_intent_to_add = true } },
        .{ .args = &.{ "diff", "--cached", "-C" }, .options = .{ .renames = .{ .detect_copies = true }, .hide_intent_to_add = true } },
        // `--relative`: what lies outside is left out, unmerged paths too,
        // which git 2.56 no longer stumbles on.
        .{ .args = &.{ "diff", "--cached", "-M", "--relative=dir/" }, .options = .{ .renames = .{}, .prefix = "dir/", .hide_intent_to_add = true }, .relative = "dir/" },
        .{ .args = &.{ "diff-index", "--cached", "--relative=dir/", "HEAD" }, .options = .{ .prefix = "dir/" }, .relative = "dir/" },
        .{ .args = &.{ "diff", "--cached", "--no-renames", "--", "dir" }, .options = .{ .paths = &dir_spec, .hide_intent_to_add = true } },
    };
    for (variants) |v| try expectRaw(gpa, io, &git, v);
}

/// relic's `git diff --cached -M` in the form `args` asks: a patch, a stat
/// or counts.
fn porcelain(gpa: Allocator, io: Io, git: *testgit.Repo, form: []const u8, relative: []const u8, out: *std.ArrayList(u8)) !void {
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const db = repo.objectDatabase();
    var changes = try diff.index(gpa, io, db, .{ .tree = try repo.headTree(io), .index = &index }, .{ .renames = .{}, .prefix = relative, .hide_intent_to_add = true });
    defer changes.deinit();
    const options = try diff.configured(repo.configuration(), .{ .relative_to = relative });
    if (std.mem.eql(u8, form, "--patch")) {
        var w: Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try diff.unified(gpa, io, &w.writer, .{ .db = db, .changes = changes.items }, options);
        return out.appendSlice(gpa, w.written());
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try stat.files(a, io, .{ .db = db, .changes = changes.items }, options);
    // git's `run_diffstat` names an unmerged path in full.
    for (files) |*f| if (f.kind != .unmerged) {
        f.name = f.name[relative.len..];
        if (f.from) |from| f.from = from[relative.len..];
    };
    if (std.mem.eql(u8, form, "--stat")) {
        // `write` allocates as it goes, from an arena.
        var text: std.ArrayList(u8) = .empty;
        try stat.write(a, &text, files, .{});
        return out.appendSlice(gpa, text.items);
    }
    for (files) |f| {
        if (f.kind == .binary) try out.appendSlice(gpa, "-\t-\t") else try out.print(gpa, "{d}\t{d}\t", .{ f.added, f.deleted });
        try out.print(gpa, "{s}\n", .{try stat.printName(a, f.from, f.name, true)});
    }
}

test "a staged change's patch, stat and counts are git diff --cached's, an unmerged path as git names it" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(gpa, io, &git);
    for ([_][]const u8{ "", "dir/" }) |relative| {
        for ([_][]const u8{ "--patch", "--stat", "--numstat" }) |form| {
            const relative_arg = try std.mem.concat(gpa, u8, &.{ "--relative=", relative });
            defer gpa.free(relative_arg);
            const args: []const []const u8 = if (relative.len == 0)
                &.{ "diff", "--cached", "-M", form }
            else
                &.{ "diff", "--cached", "-M", form, relative_arg };
            const theirs = try git.run(io, args);
            defer gpa.free(theirs);
            var mine: std.ArrayList(u8) = .empty;
            defer mine.deinit(gpa);
            try porcelain(gpa, io, &git, form, relative, &mine);
            std.testing.expectEqualStrings(theirs, mine.items) catch |err| {
                std.debug.print("{s} --relative={s}: differs\n", .{ form, relative });
                return err;
            };
        }
    }
}

test "a sparse directory of the index is compared as the files of its tree" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "top.txt", "top\n");
    try git.writeFile(io, "out/x.txt", "x\n");
    try git.writeFile(io, "out/deep/y.txt", "y\n");
    try git.writeFile(io, "in/z.txt", "z\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.writeFile(io, "out/x.txt", "x, changed\n");
    try git.writeFile(io, "out/deep/w.txt", "w\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "two" });
    try git.exec(io, &.{ "sparse-checkout", "set", "--cone", "--sparse-index", "in" });
    const ls = try git.run(io, &.{ "ls-files", "--sparse", "-s" });
    defer gpa.free(ls);
    try std.testing.expect(std.mem.find(u8, ls, "\tout/\n") != null);

    // `-r`, as `git diff --cached` has it: without it git's diff-index
    // names a sparse directory's changed subtree as one tree, where the
    // same index in full lists its files.
    const theirs = try git.run(io, &.{ "diff-index", "-r", "--cached", "--raw", "--no-abbrev", "HEAD~1" });
    defer gpa.free(theirs);
    const porcelain_theirs = try git.run(io, &.{ "diff", "--cached", "--no-renames", "--raw", "--no-abbrev", "HEAD~1" });
    defer gpa.free(porcelain_theirs);
    try std.testing.expectEqualStrings(theirs, porcelain_theirs);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const db = repo.objectDatabase();
    const head = try git.line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(head);
    const old = try repo.commitTree(io, try hash.Oid.parse(.sha1, head));
    var changes = try diff.index(gpa, io, db, .{ .tree = old, .index = &index }, .{});
    defer changes.deinit();
    var mine: std.ArrayList(u8) = .empty;
    defer mine.deinit(gpa);
    try writeRaw(gpa, &mine, db.objectFormat(), changes.items, "");
    try std.testing.expectEqualStrings(theirs, mine.items);
}
