//! Crafted objects, written by git as they are given and read by relic,
//! held to what git's own readers make of them: `git log` for idents,
//! `git ls-tree` for tree entries, `git cat-file -p` for a tag, and `git
//! fsck` for whether each is refused.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Oid = @import("../hash/hash.zig").Oid;
const object = @import("../object/object.zig");
const fsck = @import("../object/fsck.zig");
const odb_mod = @import("../odb/odb.zig");
const testgit = @import("git.zig");

/// An object another one names, written beside it.
const Dep = struct { type: []const u8, bytes: []const u8 };
const empty_tree: Dep = .{ .type = "tree", .bytes = "" };
const x_blob: Dep = .{ .type = "blob", .bytes = "x\n" };

const Corpus = struct {
    repo: testgit.Repo,
    git_dir: Io.Dir,
    db: odb_mod.Odb,

    fn init(gpa: Allocator, io: Io) !Corpus {
        var repo = try testgit.Repo.init(gpa, io, &.{});
        errdefer repo.deinit();
        const git_dir = try repo.gitDir(io);
        errdefer git_dir.close(io);
        const db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{ .probe_timestamp_resolution = false });
        return .{ .repo = repo, .git_dir = git_dir, .db = db };
    }

    fn deinit(c: *Corpus, io: Io) void {
        c.db.deinit(io);
        c.git_dir.close(io);
        c.repo.deinit();
    }

    /// `bytes` stored as an object of type `kind` exactly as given.
    fn literally(c: *Corpus, io: Io, kind: []const u8, bytes: []const u8) !Oid {
        const out = try c.repo.runInput(io, &.{ "hash-object", "-t", kind, "-w", "--literally", "--stdin" }, bytes);
        defer c.repo.gpa.free(out);
        return Oid.parse(.sha1, std.mem.trimEnd(u8, out, "\n"));
    }

    /// What git prints for `args` on `oid`; the caller's.
    fn git(c: *Corpus, io: Io, args: []const []const u8, oid: Oid) ![]u8 {
        var hex: [40]u8 = undefined;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(c.repo.gpa);
        try argv.appendSlice(c.repo.gpa, args);
        try argv.append(c.repo.gpa, oid.hex(&hex));
        return c.repo.run(io, argv.items);
    }

    /// Whether `git fsck --strict` finds an error in the object, in a
    /// repository holding it and only it beside `deps` (git's fsck checks
    /// every object there is), and whether relic's fsck does.
    fn fsckAgrees(c: *Corpus, io: Io, oid: Oid, t: object.Type, deps: []const Dep) !void {
        const gpa = c.repo.gpa;
        const found = try c.db.read(io, oid);
        defer gpa.free(found.bytes);
        var alone = try testgit.Repo.init(gpa, io, &.{});
        defer alone.deinit();
        for (deps) |dep| gpa.free(try alone.runInput(io, &.{ "hash-object", "-t", dep.type, "-w", "--literally", "--stdin" }, dep.bytes));
        gpa.free(try alone.runInput(io, &.{ "hash-object", "-t", t.name(), "-w", "--literally", "--stdin" }, found.bytes));
        alone.report_failures = false;
        const git_refuses = if (alone.run(io, &.{ "fsck", "--strict", "--no-dangling" })) |out| blk: {
            gpa.free(out);
            break :blk false;
        } else |err| switch (err) {
            error.GitFailed => true,
            else => |e| return e,
        };
        const rules: fsck.Rules = .{ .strict = true };
        const finding = try fsck.inspect(gpa, &rules, .{ .kind = .sha1, .oid = oid, .type = t, .bytes = found.bytes }, .{});
        testing.expectEqual(git_refuses, finding != null) catch |err| {
            std.debug.print("fsck differs on {s}: git {s}, relic {s}\n", .{ found.bytes, if (git_refuses) "refuses" else "accepts", if (finding != null) "refuses" else "accepts" });
            return err;
        };
    }
};

test "an ident reads as git log reads it: name, email and date, a malformed tail a person with no date" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    var c = try Corpus.init(gpa, io);
    defer c.deinit(io);
    const tree = try c.literally(io, "tree", "");
    var tree_hex: [40]u8 = undefined;
    for ([_][]const u8{
        "Ada  <a@b> 100 +0130", "A <a@b> 1 +0x00", "A <a@b>",           "A <a@b> x +0000",
        "A <a@b> 1",            "A <a@b> 1 0000",  "A <a@b>c> 7 +0000", "A\t<a@b>\t9\t-0230",
        "A a@b 1 +0000",        "<a@b> 3 +0000",   "A <> 4 +0000",
    }) |ident| {
        const text = try std.fmt.allocPrint(gpa, "tree {s}\nauthor {s}\ncommitter C <c@d> 5 +0000\n\nm\n", .{ tree.hex(&tree_hex), ident });
        defer gpa.free(text);
        const oid = try c.literally(io, "commit", text);
        const out = try c.git(io, &.{ "log", "-1", "--format=%an|%ae|%at" }, oid);
        defer gpa.free(out);
        const shown = std.mem.trimEnd(u8, out, "\n");

        const found = try c.db.read(io, oid);
        defer gpa.free(found.bytes);
        var commit = try object.Commit.parse(gpa, .sha1, found.bytes);
        defer commit.deinit();
        const a = commit.author;
        var ours_buf: [256]u8 = undefined;
        // git shows no date where it read none, which relic reads as zero.
        const ours = if (std.mem.endsWith(u8, shown, "|") and a.when_secs == 0)
            try std.mem.print(&ours_buf, "{s}|{s}|", .{ a.name, a.email })
        else
            try std.mem.print(&ours_buf, "{s}|{s}|{d}", .{ a.name, a.email, a.when_secs });
        testing.expectEqualStrings(shown, ours) catch |err| {
            std.debug.print("ident: {s}\n", .{ident});
            return err;
        };
        try c.fsckAgrees(io, oid, .commit, &.{empty_tree});
    }
}

test "a tree's entries read as git ls-tree lists them: modes folded as canon_mode folds them, a slash in a name kept" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    var c = try Corpus.init(gpa, io);
    defer c.deinit(io);
    const blob = try c.literally(io, "blob", "x\n");
    for ([_][]const u8{ "100644", "100755", "100700", "100655", "120644", "040755", "0", "1", "777777", "40000100644", "100664" }) |mode| {
        for ([_][]const u8{ "n", "a/b" }) |name| {
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(gpa);
            try bytes.print(gpa, "{s} {s}\x00", .{ mode, name });
            try bytes.appendSlice(gpa, blob.raw());
            const oid = try c.literally(io, "tree", bytes.items);
            const out = try c.git(io, &.{"ls-tree"}, oid);
            defer gpa.free(out);
            const listed = std.mem.trimEnd(u8, out, "\n");

            const found = try c.db.read(io, oid);
            defer gpa.free(found.bytes);
            const tree: object.Tree = .{ .kind = .sha1, .bytes = found.bytes };
            var it = tree.iterate();
            const entry = (try it.next()).?;
            try testing.expect((try it.next()) == null);
            var mode_buf: [6]u8 = undefined;
            var hex: [40]u8 = undefined;
            const kind_name = if (entry.mode.objectType()) |t| t.name() else "commit";
            var ours_buf: [128]u8 = undefined;
            // ls-tree pads the mode to six digits.
            const ours = try std.mem.print(&ours_buf, "{s:0>6} {s} {s}\t{s}", .{ entry.mode.text(&mode_buf), kind_name, entry.oid.hex(&hex), entry.name });
            testing.expectEqualStrings(listed, ours) catch |err| {
                std.debug.print("mode {s}, name {s}\n", .{ mode, name });
                return err;
            };
            try c.fsckAgrees(io, oid, .tree, &.{x_blob});
        }
    }
}

test "a tag reads as git cat-file reads it: a header line with no space kept, an unreadable tagger none" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    var c = try Corpus.init(gpa, io);
    defer c.deinit(io);
    const blob = try c.literally(io, "blob", "x\n");
    var hex: [40]u8 = undefined;
    for ([_][]const u8{ "tagger T <t@u> 1 +0000\n", "tagger T t@u 1 +0000\n", "", "tagger T <t@u> 1 +0000\nlonely\n" }) |rest| {
        const text = try std.fmt.allocPrint(gpa, "object {s}\ntype blob\ntag v1\n{s}\nmessage\n", .{ blob.hex(&hex), rest });
        defer gpa.free(text);
        const oid = try c.literally(io, "tag", text);
        const shown = try c.git(io, &.{ "cat-file", "-p" }, oid);
        defer gpa.free(shown);
        try testing.expectEqualStrings(text, shown);

        const found = try c.db.read(io, oid);
        defer gpa.free(found.bytes);
        var tag = try object.Tag.parse(gpa, .sha1, found.bytes);
        defer tag.deinit();
        try testing.expectEqualStrings("v1", tag.name);
        try testing.expectEqual(std.mem.startsWith(u8, rest, "tagger T <"), tag.tagger != null);
        try c.fsckAgrees(io, oid, .tag, &.{x_blob});
    }
}
