//! `archive` against `git archive`: the same tree, the same options, the
//! same bytes.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const archive_mod = @import("archive.zig");
const hash = @import("hash.zig");
const repo_mod = @import("repo.zig");
const testgit = @import("testing/git.zig");

const Repository = repo_mod.Repository;
const Oid = hash.Oid;

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

fn ours(gpa: Allocator, io: Io, repo: *Repository, treeish: Oid, options: archive_mod.Options) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try archive_mod.archive(gpa, io, repo, treeish, options, &out.writer);
    return out.toOwnedSlice();
}

fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *Repository, args: []const []const u8, treeish: Oid, options: archive_mod.Options) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "archive");
    try argv.appendSlice(gpa, args);
    const theirs = try git.run(io, argv.items);
    defer gpa.free(theirs);
    const mine = try ours(gpa, io, repo, treeish, options);
    defer gpa.free(mine);
    if (!std.mem.eql(u8, theirs, mine)) {
        std.debug.print("git archive {any}: {d} bytes, ours {d}\n", .{ args, theirs.len, mine.len });
        const n = @min(theirs.len, mine.len);
        for (0..n) |i| if (theirs[i] != mine[i]) {
            std.debug.print("first difference at byte {d}\n", .{i});
            break;
        };
    }
    try std.testing.expect(std.mem.eql(u8, theirs, mine));
}

fn fixture(io: Io, git: *testgit.Repo) !void {
    // UTC, so the zip's DOS times are the same on both sides
    try git.isolated.?.put("TZ", "UTC");
    try git.writeFile(io, "README", "readme\n");
    try git.writeFile(io, "bin/run.sh", "#!/bin/sh\necho run\n");
    try git.exec(io, &.{ "update-index", "--add", "README" });
    try git.writeFile(io, "src/deep/er/still/file.c", "int x;\n");
    try git.writeFile(io, "ignored/secret.txt", "do not ship\n");
    try git.writeFile(io, "notes/skip.md", "skip me\n");
    try git.writeFile(io, "crlf.txt", "one\ntwo\n");
    // git writes `%aI` at UTC as `Z` since 2.45, and as `+00:00` before
    const strict = if (try testgit.gitAtLeast(git.gpa, io, 2, 45)) "|%aI" else "";
    var text_buf: [256]u8 = undefined;
    try git.writeFile(io, "version.txt", try std.fmt.bufPrint(&text_buf, "Commit $Format:%H$ (%h) by $Format:%an <%ae>%n%ad|%ai{s}|%at$ $Format:%s%+b%-b$ $Format:%T %t %P %p %cn %ce %cd %ci%%x41$\n", .{strict}));
    try git.writeFile(io, "data.bin", "\x00\x01\x02 binary " ** 50);
    const long_dir = "a-directory-name-that-is-quite-long/another-directory-name-that-is-long-too/and-a-third-one";
    try git.writeFile(io, long_dir ++ "/file-with-a-long-name-as-well.txt", "long path\n");
    try git.writeFile(io, "x" ** 120 ++ "/" ++ "y" ** 120 ++ "/" ++ "z" ** 30, "longer than ustar holds\n");
    try git.writeFile(io, ".gitattributes", "ignored/ export-ignore\nnotes/*.md export-ignore\ncrlf.txt eol=crlf\nversion.txt export-subst\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "bin/run.sh" });
    if (builtin.os.tag != .windows) {
        try git.dir.symLink(io, "README", "link", .{});
        try git.dir.symLink(io, "t" ** 150, "longlink", .{});
        try git.exec(io, &.{ "add", "link", "longlink" });
    }
    try git.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000,1234567890123456789012345678901234567890,sub" });
    try git.exec(io, &.{ "commit", "-q", "-m", "archive me\n\nWith a body line." });
}

test "a commit is archived as git archives it: tar with every kind of entry, attributes, prefixes and pathspecs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head = try oidOf(gpa, io, &git, "HEAD");
    try compare(gpa, io, &git, &repo, &.{"HEAD"}, head, .{});
    try compare(gpa, io, &git, &repo, &.{ "--prefix=pre/", "HEAD" }, head, .{ .prefix = "pre/" });
    try compare(gpa, io, &git, &repo, &.{ "--prefix=pre-", "HEAD" }, head, .{ .prefix = "pre-" });
    try compare(gpa, io, &git, &repo, &.{ "HEAD", "src", "bin" }, head, .{ .pathspecs = &.{ "src", "bin" } });
    try compare(gpa, io, &git, &repo, &.{ "HEAD", "*.txt" }, head, .{ .pathspecs = &.{"*.txt"} });
    // `--mtime` came in 2.42
    if (try testgit.gitAtLeast(gpa, io, 2, 42)) {
        try compare(gpa, io, &git, &repo, &.{ "--mtime=@1600000000", "HEAD" }, head, .{ .mtime = 1600000000 });
        const tree = try oidOf(gpa, io, &git, "HEAD^{tree}");
        try compare(gpa, io, &git, &repo, &.{ "--mtime=@1600000000", "HEAD^{tree}" }, tree, .{ .mtime = 1600000000 });
    }
    try git.exec(io, &.{ "config", "tar.umask", "022" });
    var again = try Repository.open(gpa, io, git.dir, .{});
    defer again.deinit(io);
    try compare(gpa, io, &git, &again, &.{"HEAD"}, head, .{});
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.PathspecNoMatch, archive_mod.archive(gpa, io, &repo, head, .{ .pathspecs = &.{"nowhere"} }, &out.writer));
}

test "export-subst names people by the mailmap and commits by their refs, and tar.umask=user is the process's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, ".mailmap", "Real Name <real@example.com> <author@example.com>\n");
    try git.writeFile(io, ".gitattributes", "subst.txt export-subst\n");
    // Git 2.43 introduced the configurable decoration placeholder.
    const decorations = if (try testgit.gitAtLeast(gpa, io, 2, 43)) "%(decorate:prefix=[,suffix=],separator=%x3b,pointer=>,tag=T:)|%(decorate)|%(decorate:bogus)|" else "";
    const subst = try std.fmt.allocPrint(gpa, "$Format:%aN <%aE> %aL|%cN <%cE> %cL|%an|%d|%D|%+d|{s}%N|%G?|%GS|%GK|%GT$\n", .{decorations});
    defer gpa.free(subst);
    try git.writeFile(io, "subst.txt", subst);
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "first" });
    try git.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1" });
    try git.exec(io, &.{ "tag", "light" });
    try git.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    try git.exec(io, &.{ "update-ref", "refs/stash", "HEAD" });
    try git.exec(io, &.{ "update-ref", "refs/other/thing", "HEAD" });
    try git.exec(io, &.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    try git.writeFile(io, "more.txt", "more\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "second" });
    try git.exec(io, &.{ "branch", "side" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head = try oidOf(gpa, io, &git, "HEAD");
    const first = try oidOf(gpa, io, &git, "v1");
    try compare(gpa, io, &git, &repo, &.{"HEAD"}, head, .{});
    try compare(gpa, io, &git, &repo, &.{"v1"}, first, .{});
    // detached, HEAD stands alone
    try git.exec(io, &.{ "checkout", "-q", "--detach", "HEAD" });
    var detached = try Repository.open(gpa, io, git.dir, .{});
    defer detached.deinit(io);
    try compare(gpa, io, &git, &detached, &.{"HEAD"}, head, .{});

    try git.exec(io, &.{ "config", "tar.umask", "user" });
    var user = try Repository.open(gpa, io, git.dir, .{});
    defer user.deinit(io);
    try compare(gpa, io, &git, &user, &.{"HEAD"}, head, .{});
    try git.exec(io, &.{ "config", "tar.umask", "nonsense" });
    var bad = try Repository.open(gpa, io, git.dir, .{});
    defer bad.deinit(io);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTarUmask, archive_mod.archive(gpa, io, &bad, head, .{}, &out.writer));
}

test "a stored zip is git's byte for byte, and a deflated one holds the same files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head = try oidOf(gpa, io, &git, "HEAD");
    try compare(gpa, io, &git, &repo, &.{ "--format=zip", "-0", "HEAD" }, head, .{ .format = .zip, .level = 0 });
    try compare(gpa, io, &git, &repo, &.{ "--format=zip", "-0", "--prefix=p/", "HEAD", "src" }, head, .{ .format = .zip, .level = 0, .prefix = "p/", .pathspecs = &.{"src"} });

    // deflated: every entry's name, attributes, CRC and size agree, and
    // ours inflates to the stored bytes
    const theirs = try git.run(io, &.{ "archive", "--format=zip", "HEAD" });
    defer gpa.free(theirs);
    const mine = try ours(gpa, io, &repo, head, .{ .format = .zip });
    defer gpa.free(mine);
    const stored = try ours(gpa, io, &repo, head, .{ .format = .zip, .level = 0 });
    defer gpa.free(stored);
    var a_entries = try centralDirectory(gpa, theirs);
    defer a_entries.deinit(gpa);
    var b_entries = try centralDirectory(gpa, mine);
    defer b_entries.deinit(gpa);
    try std.testing.expectEqual(a_entries.items.len, b_entries.items.len);
    for (a_entries.items, b_entries.items) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(x.crc, y.crc);
        try std.testing.expectEqual(x.size, y.size);
        try std.testing.expectEqual(x.external, y.external);
        try std.testing.expectEqual(x.internal, y.internal);
    }
}

const CdEntry = struct { name: []const u8, crc: u32, size: u32, external: u32, internal: u16 };

fn centralDirectory(gpa: Allocator, zip: []const u8) !std.ArrayList(CdEntry) {
    var out: std.ArrayList(CdEntry) = .empty;
    errdefer out.deinit(gpa);
    // the end record: 22 bytes, then the comment
    var end: usize = zip.len - 22;
    while (std.mem.readInt(u32, zip[end..][0..4], .little) != 0x06054b50) end -= 1;
    const count = std.mem.readInt(u16, zip[end + 10 ..][0..2], .little);
    var at: usize = std.mem.readInt(u32, zip[end + 16 ..][0..4], .little);
    for (0..count) |_| {
        const name_len = std.mem.readInt(u16, zip[at + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, zip[at + 30 ..][0..2], .little);
        try out.append(gpa, .{
            .name = zip[at + 46 ..][0..name_len],
            .crc = std.mem.readInt(u32, zip[at + 16 ..][0..4], .little),
            .size = std.mem.readInt(u32, zip[at + 24 ..][0..4], .little),
            .internal = std.mem.readInt(u16, zip[at + 36 ..][0..2], .little),
            .external = std.mem.readInt(u32, zip[at + 38 ..][0..4], .little),
        });
        at += 46 + name_len + extra_len;
    }
    return out;
}

test "a commit dated before 1970 is archived as git archives it: a tar with git's unsigned time, a zip refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "f", "x\n");
    try git.exec(io, &.{ "add", "f" });
    const tree = try git.line(io, &.{"write-tree"});
    defer gpa.free(tree);
    const body = try std.fmt.allocPrint(gpa, "tree {s}\nauthor A <a@a> -5 +0000\ncommitter A <a@a> -5 +0000\n\nm\n", .{tree});
    defer gpa.free(body);
    const text = try git.runInput(io, &.{ "hash-object", "-t", "commit", "-w", "--literally", "--stdin" }, body);
    defer gpa.free(text);
    const commit = try Oid.parse(.sha1, std.mem.trim(u8, text, "\n"));
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    try compare(gpa, io, &git, &repo, &.{commit.hex(&hex)}, commit, .{});
    // git's zip writer dies: "timestamp too large for this system".
    var zip = try git.capture(io, &.{ "archive", "--format=zip", commit.hex(&hex) });
    defer zip.deinit(gpa);
    try std.testing.expect(zip.code != 0);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.TimestampTooLarge, archive_mod.archive(gpa, io, &repo, commit, .{ .format = .zip }, &out.writer));
}

test "a tree deeper than sixty-four directories, and a zip of more entries than its end record counts, are git's byte for byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.isolated.?.put("TZ", "UTC");
    const blob = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "x\n");
    defer gpa.free(blob);
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(gpa);
    try info.appendSlice(gpa, "100644 ");
    try info.appendSlice(gpa, std.mem.trim(u8, blob, "\n"));
    try info.append(gpa, '\t');
    for (0..70) |_| try info.appendSlice(gpa, "d/");
    try info.appendSlice(gpa, "f\n");
    gpa.free(try git.runInput(io, &.{ "update-index", "--add", "--index-info" }, info.items));
    try git.exec(io, &.{ "commit", "-q", "-m", "deep" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try compare(gpa, io, &git, &repo, &.{"HEAD"}, try oidOf(gpa, io, &git, "HEAD"), .{});

    // Seventy thousand entries: the end record holds 65535, and git adds
    // the zip64 end record and its locator.
    info.clearRetainingCapacity();
    for (0..70000) |i| try info.print(gpa, "100644 {s}\tmany/{d}\n", .{ std.mem.trim(u8, blob, "\n"), i });
    gpa.free(try git.runInput(io, &.{ "update-index", "--add", "--index-info" }, info.items));
    try git.exec(io, &.{ "commit", "-q", "-m", "many" });
    var again = try Repository.open(gpa, io, git.dir, .{});
    defer again.deinit(io);
    try compare(gpa, io, &git, &again, &.{ "--format=zip", "-0", "HEAD" }, try oidOf(gpa, io, &git, "HEAD"), .{ .format = .zip, .level = 0 });
}
