//! `upload-archive` and `git archive --remote` against git's: relic's
//! server under git's client gives what git's server gives, and relic's
//! client takes from git's server what git's client takes.

const std = @import("std");
const warp = @import("warp");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const remote = @import("remote.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const suite = @import("../testing/helpers.zig");

fn fixture(io: Io, git: *testgit.Repo) !void {
    // UTC, so a zip's DOS times are the same on both sides
    try git.isolated.?.put("TZ", "UTC");
    try git.writeFile(io, "README", "readme\n");
    try git.writeFile(io, "src/main.c", "int main(void) { return 0; }\n");
    try git.writeFile(io, "src/util/strings.c", "char *s;\n");
    try git.writeFile(io, "docs/guide.md", "# guide\n");
    try git.writeFile(io, "skip/me.txt", "not shipped\n");
    try git.writeFile(io, ".gitattributes", "skip/ export-ignore\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "first" });
    try git.exec(io, &.{ "tag", "v1" });
    try git.writeFile(io, "README", "readme, again\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "second" });
}

/// Whether two archives are the same: byte for byte, or for gzip -- whose
/// deflated bytes are Warp's here and zlib's in git -- the same header and
/// the same tar inside.
fn same(gpa: Allocator, theirs: []const u8, ours: []const u8) !bool {
    if (!std.mem.startsWith(u8, theirs, "\x1f\x8b")) return std.mem.eql(u8, theirs, ours);
    if (ours.len < 10 or !std.mem.eql(u8, theirs[0..10], ours[0..10])) return false;
    const a = try gunzip(gpa, theirs);
    defer gpa.free(a);
    const b = try gunzip(gpa, ours);
    defer gpa.free(b);
    return std.mem.eql(u8, a, b);
}

/// Whether two outputs hold the same lines, in any order.
fn sameLines(gpa: Allocator, a: []const u8, b: []const u8) !bool {
    const x = try sortedLines(gpa, a);
    defer gpa.free(x);
    const y = try sortedLines(gpa, b);
    defer gpa.free(y);
    if (x.len != y.len) return false;
    for (x, y) |l, r| if (!std.mem.eql(u8, l, r)) return false;
    return true;
}

fn sortedLines(gpa: Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);
    return lines.toOwnedSlice(gpa);
}

fn gunzip(gpa: Allocator, bytes: []const u8) ![]u8 {
    var in: Io.Reader = .fixed(bytes);
    var window: [(1 << 15) + 4096]u8 = undefined;
    var inflate: warp.Inflate.Reader = .init(&in, &window, .{ .accept = .gzip });
    return inflate.interface.allocRemaining(gpa, .limited(1 << 30));
}

/// `git archive --remote=<path> [--exec=<relic's server>] <args>`.
fn gitArchive(gpa: Allocator, io: Io, git: *testgit.Repo, path: []const u8, exec: ?[]const u8, args: []const []const u8) !testgit.Captured {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var remote_buf: [Io.Dir.max_path_bytes + 16]u8 = undefined;
    var exec_buf: [Io.Dir.max_path_bytes + 16]u8 = undefined;
    try argv.append(gpa, "archive");
    try argv.append(gpa, try std.mem.print(&remote_buf, "--remote={s}", .{path}));
    if (exec) |e| try argv.append(gpa, try std.mem.print(&exec_buf, "--exec={s}", .{e}));
    try argv.appendSlice(gpa, args);
    return git.capture(io, argv.items);
}

test "relic's upload-archive gives git's client what git's gives: archives, lists and refusals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    // filters of its own: two a client may ask for, one it may not
    try git.exec(io, &.{ "config", "tar.cat.command", "cat" });
    try git.exec(io, &.{ "config", "tar.cat.remote", "true" });
    try git.exec(io, &.{ "config", "tar.rev.command", "cat; echo level" });
    try git.exec(io, &.{ "config", "tar.rev.remote", "true" });
    try git.exec(io, &.{ "config", "tar.secret.command", "cat" });
    try git.exec(io, &.{ "config", "tar.fail.command", "cat >/dev/null; exit 3" });
    try git.exec(io, &.{ "config", "tar.fail.remote", "true" });
    const path = try testremote.absolutePath(gpa, io, git.dir);
    defer gpa.free(path);
    const helper = suite.path(.upload_archive_helper);
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const cases = [_][]const []const u8{
        &.{"HEAD"},
        &.{ "--format=zip", "-0", "HEAD" },
        &.{ "--format=tgz", "HEAD" },
        &.{ "--format=tar.gz", "-9", "HEAD" },
        &.{ "--format=tgz", "-1", "HEAD" },
        &.{ "--format=tgz", "-0", "HEAD" },
        &.{ "--format=cat", "HEAD" },
        &.{ "--format=rev", "-3", "HEAD" },
        &.{ "--prefix=project/", "v1", "src" },
        &.{ "--format", "tar", "HEAD", "--", "docs" },
        &.{"--list"},
        // what the archiver refuses
        &.{ "--format=secret", "HEAD" },
        &.{"HEAD:README"},
        &.{ "--list", "HEAD" },
        &.{"nowhere"},
        &.{head},
        &.{ "HEAD", "nothing-here" },
        &.{ "--format=rar", "HEAD" },
        &.{ "-9", "HEAD" },
    };
    // git's usage text, which each version words its own way: the first
    // line and the end are the same. And a filter that fails, whose words
    // git's server loses -- it stops reading its archiver's errors once the
    // archive's end is read -- and relic's sends.
    const usage_cases = [_][]const []const u8{ &.{ "--bogus", "HEAD" }, &.{}, &.{ "--format=fail", "HEAD" }, &.{ "--format=fail", "-4", "HEAD" } };
    // A tree has no time of its own, and takes the time now unless
    // `--mtime` (2.42) gives one.
    const timed = [_][]const []const u8{&.{ "--mtime=@1600000000", "HEAD:src", "util" }};
    const with_mtime = try testgit.gitAtLeast(gpa, io, 2, 42);
    for (cases ++ timed, 0..) |args, i| {
        if (i >= cases.len and !with_mtime) break;
        var theirs = try gitArchive(gpa, io, &git, path, null, args);
        defer theirs.deinit(gpa);
        var ours = try gitArchive(gpa, io, &git, path, helper, args);
        defer ours.deinit(gpa);
        std.testing.expectEqual(theirs.code, ours.code) catch |err| {
            std.debug.print("{any}: git {d} {s}\nrelic {d} {s}\n", .{ args, theirs.code, theirs.stderr, ours.code, ours.stderr });
            return err;
        };
        // The server's own last words and the client's race each other.
        std.testing.expect(try sameLines(gpa, theirs.stderr, ours.stderr)) catch |err| {
            std.debug.print("{any}\ngit:\n{s}\nrelic:\n{s}\n", .{ args, theirs.stderr, ours.stderr });
            return err;
        };
        std.testing.expect(try same(gpa, theirs.stdout, ours.stdout)) catch |err| {
            std.debug.print("{any}: git {d} bytes, relic {d}\n", .{ args, theirs.stdout.len, ours.stdout.len });
            return err;
        };
    }

    for (usage_cases) |args| {
        var theirs = try gitArchive(gpa, io, &git, path, null, args);
        defer theirs.deinit(gpa);
        var ours = try gitArchive(gpa, io, &git, path, helper, args);
        defer ours.deinit(gpa);
        try std.testing.expectEqual(theirs.code, ours.code);
        if (std.mem.startsWith(u8, theirs.stderr, "remote: ")) {
            const first = theirs.stderr[0 .. std.mem.findScalar(u8, theirs.stderr, '\n') orelse theirs.stderr.len];
            std.testing.expect(std.mem.find(u8, ours.stderr, first) != null) catch |err| {
                std.debug.print("{any}\ngit:\n{s}\nrelic:\n{s}\n", .{ args, theirs.stderr, ours.stderr });
                return err;
            };
        }
        try std.testing.expect(std.mem.find(u8, ours.stderr, "remote: git upload-archive: archiver died with error\n") != null);
        try std.testing.expect(std.mem.find(u8, ours.stderr, "fatal: sent error to the client: git upload-archive: archiver died with error\n") != null);
    }

    // A commit no ref names, when the repository allows it.
    try git.exec(io, &.{ "config", "uploadarchive.allowUnreachable", "true" });
    var theirs = try gitArchive(gpa, io, &git, path, null, &.{head});
    defer theirs.deinit(gpa);
    var ours = try gitArchive(gpa, io, &git, path, helper, &.{head});
    defer ours.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), ours.code);
    try std.testing.expect(std.mem.eql(u8, theirs.stdout, ours.stdout));
}

test "relic's client takes git's archive, here and from git's upload-archive over ssh" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try fixture(io, &git);
    const path = try testremote.absolutePath(gpa, io, git.dir);
    defer gpa.free(path);

    var tools = std.testing.tmpDir(.{});
    defer tools.cleanup();
    const fake = try testremote.fakeSsh(gpa, io, tools.dir);
    defer gpa.free(fake);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("TZ", "UTC");

    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    try here.exec(io, &.{ "config", "core.sshCommand", fake });
    var repo = try repo_mod.Repository.open(gpa, io, here.dir, .{});
    defer repo.deinit(io);

    const ssh_url = try gpa.print("example.invalid:{s}", .{path});
    defer gpa.free(ssh_url);
    const cases = [_][]const []const u8{
        &.{"HEAD"},
        &.{ "--format=zip", "-0", "HEAD" },
        &.{ "--format=tgz", "HEAD" },
        &.{ "--prefix=project/", "v1", "src" },
        &.{"--list"},
    };
    for ([_][]const u8{ path, ssh_url }) |url| {
        for (cases) |args| {
            var theirs = try gitArchive(gpa, io, &git, path, null, args);
            defer theirs.deinit(gpa);
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try remote.fetch(gpa, io, url, args, &out.writer, .{
                .programs = .{ .environ = &env },
                .config = repo.configuration(),
                .now = Io.Clock.real.now(io),
            });
            std.testing.expect(try same(gpa, theirs.stdout, out.written())) catch |err| {
                std.debug.print("{s} {any}: git {d} bytes, relic {d}\n", .{ url, args, theirs.stdout.len, out.written().len });
                return err;
            };
        }
        var said: remote.Said = .{};
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try std.testing.expectError(error.ArchiveFailed, remote.fetch(gpa, io, url, &.{"nowhere"}, &out.writer, .{
            .programs = .{ .environ = &env },
            .config = repo.configuration(),
            .said = &said,
        }));
        try std.testing.expectEqualStrings(remote.died, said.text());
    }
}
