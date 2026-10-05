//! Remote helpers, against git: git and relic pointed at the same helper —
//! the suite's `git-remote-testgit` (git's own, for `import` and `export`),
//! its `git-remote-testfetch` (`fetch` and `push`), and git's `ext` (for
//! `connect`) — clone, fetch and push, and the refs on both sides, the
//! helper's private refs and its marks agree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const repo_mod = @import("../repo.zig");
const config_mod = @import("../config.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");
const transport = @import("../transport.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const build_options = @import("build_options");
const program = @import("../repo/program.zig");

const Repository = repo_mod.Repository;

const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

/// The helpers on a `PATH` of their own, ahead of git's exec path (where
/// `git-remote-ext` lives) and the machine's.
const Helpers = struct {
    gpa: Allocator,
    bin: std.testing.TmpDir,
    path: []u8,
    environ: Environ.Map,

    fn init(gpa: Allocator, io: Io, git: *testgit.Repo) !Helpers {
        var bin = std.testing.tmpDir(.{});
        errdefer bin.cleanup();
        for ([_][]const u8{ "git-remote-testgit", "git-remote-testfetch" }) |name| {
            const exe = if (builtin.os.tag == .windows) try std.fmt.allocPrint(gpa, "{s}.exe", .{name}) else try gpa.dupe(u8, name);
            defer gpa.free(exe);
            try Io.Dir.cwd().copyFile(build_options.remote_helper_path, bin.dir, exe, io, .{});
            if (builtin.os.tag != .windows) {
                const file = try bin.dir.openFile(io, exe, .{});
                defer file.close(io);
                try file.setPermissions(io, .fromMode(0o755));
            }
        }
        const bin_path = try bin.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(bin_path);
        const exec_path = try git.line(io, &.{"--exec-path"});
        defer gpa.free(exec_path);
        var environ = try testremote.environ(gpa);
        errdefer environ.deinit();
        const sep = [_]u8{std.fs.path.delimiter};
        const path = try std.mem.concat(gpa, u8, &.{ bin_path, &sep, exec_path, &sep, environ.get("PATH").? });
        errdefer gpa.free(path);
        try environ.put("PATH", path);
        return .{ .gpa = gpa, .bin = bin, .path = path, .environ = environ };
    }

    fn deinit(h: *Helpers) void {
        h.environ.deinit();
        h.gpa.free(h.path);
        h.bin.cleanup();
        h.* = undefined;
    }

    /// Have `git`'s runs find the helpers too.
    fn give(h: *const Helpers, git: *testgit.Repo) !void {
        try git.isolated.?.put("PATH", h.path);
    }

    fn programs(h: *const Helpers) program.Programs {
        return .{ .environ = &h.environ };
    }
};

/// The remote: two branches, a lightweight tag — an annotated one is what
/// git's testgit cannot import — and a file in a directory.
fn remoteFixture(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    var env = try testgit.datedEnv(gpa, testgit.fixture_date);
    defer env.deinit();
    git.environ = &env;
    defer git.environ = null;
    try git.writeFile(io, "a.txt", "a\n");
    try git.writeFile(io, "dir/b.txt", "b\n");
    try git.exec(io, &.{ "add", "." });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "tag", "v1" });
    try git.exec(io, &.{ "branch", "side" });
    try git.writeFile(io, "a.txt", "a2\n");
    try git.exec(io, &.{ "commit", "-q", "-a", "-m", "two" });
}

/// A commit made the same in two clones, so both push the same object.
fn commitIn(gpa: Allocator, io: Io, scratch: *testgit.Repo, dir: []const u8, secs: i64, file: []const u8) !void {
    var env = try testgit.datedEnv(gpa, secs);
    defer env.deinit();
    try env.put("PATH", scratch.isolated.?.get("PATH").?);
    const saved = scratch.environ;
    scratch.environ = &env;
    defer scratch.environ = saved;
    const path = try std.fs.path.join(gpa, &.{ dir, file });
    defer gpa.free(path);
    try scratch.writeFile(io, path, file);
    try scratch.exec(io, &.{ "-C", dir, "add", file });
    try scratch.exec(io, &.{ "-C", dir, "commit", "-q", "-m", file });
}

fn refsOf(io: Io, scratch: *testgit.Repo, dir: []const u8) ![]u8 {
    return scratch.run(io, &.{ "-C", dir, "for-each-ref", "--format=%(refname) %(objectname) %(symref)" });
}

fn expectSameRefs(gpa: Allocator, io: Io, scratch: *testgit.Repo, a: []const u8, b: []const u8) !void {
    const left = try refsOf(io, scratch, a);
    defer gpa.free(left);
    const right = try refsOf(io, scratch, b);
    defer gpa.free(right);
    try std.testing.expectEqualStrings(left, right);
    const head_a = try scratch.line(io, &.{ "-C", a, "symbolic-ref", "HEAD" });
    defer gpa.free(head_a);
    const head_b = try scratch.line(io, &.{ "-C", b, "symbolic-ref", "HEAD" });
    defer gpa.free(head_b);
    try std.testing.expectEqualStrings(head_a, head_b);
}

fn pathOf(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    const real = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(real);
    const p = try gpa.dupe(u8, real);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, p, '\\', '/');
    return p;
}

test "clone, fetch and push through a helper's import and export as git does, its private refs and marks alike" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var theirs_remote = try testgit.Repo.init(gpa, io, &.{});
    defer theirs_remote.deinit();
    try remoteFixture(gpa, io, &theirs_remote);
    var mine_remote = try testgit.Repo.init(gpa, io, &.{});
    defer mine_remote.deinit();
    try remoteFixture(gpa, io, &mine_remote);
    var scratch = try testgit.Repo.init(gpa, io, &.{});
    defer scratch.deinit();
    var helpers = try Helpers.init(gpa, io, &scratch);
    defer helpers.deinit();
    try helpers.give(&scratch);

    const theirs_path = try pathOf(gpa, io, theirs_remote.dir);
    defer gpa.free(theirs_path);
    const mine_path = try pathOf(gpa, io, mine_remote.dir);
    defer gpa.free(mine_path);
    const theirs_url = try std.fmt.allocPrint(gpa, "testgit::{s}", .{theirs_path});
    defer gpa.free(theirs_url);
    const mine_url = try std.fmt.allocPrint(gpa, "testgit::{s}", .{mine_path});
    defer gpa.free(mine_url);

    try scratch.exec(io, &.{ "clone", "-q", theirs_url, "theirs" });
    try scratch.dir.createDirPath(io, "mine");
    const mine_dir = try scratch.dir.openDir(io, "mine", .{ .iterate = true });
    defer mine_dir.close(io);
    var repo = try clone_mod.clone(gpa, io, mine_url, mine_dir, .{ .who = who, .programs = helpers.programs() });
    defer repo.deinit(io);
    try expectSameRefs(gpa, io, &scratch, "theirs", "mine");
    const marks_a = try scratch.readFile(io, "theirs/.git/testgit/origin/git.marks");
    defer gpa.free(marks_a);
    const marks_b = try scratch.readFile(io, "mine/.git/testgit/origin/git.marks");
    defer gpa.free(marks_b);
    try std.testing.expectEqualStrings(marks_a, marks_b);

    // The remotes move on, and a fetch follows.
    for ([_]*testgit.Repo{ &theirs_remote, &mine_remote }) |r| {
        var env = try testgit.datedEnv(gpa, testgit.fixture_date + 100);
        defer env.deinit();
        r.environ = &env;
        defer r.environ = null;
        try r.writeFile(io, "c.txt", "c\n");
        try r.exec(io, &.{ "add", "c.txt" });
        try r.exec(io, &.{ "commit", "-q", "-m", "three" });
    }
    try scratch.exec(io, &.{ "-C", "theirs", "fetch", "-q", "origin" });
    var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = who, .programs = helpers.programs() });
    fetched.deinit();
    try expectSameRefs(gpa, io, &scratch, "theirs", "mine");

    // A commit here goes there by export.
    for ([_][]const u8{ "theirs", "mine" }) |side| {
        try scratch.exec(io, &.{ "-C", side, "reset", "-q", "--hard", "origin/main" });
        try commitIn(gpa, io, &scratch, side, testgit.fixture_date + 200, "pushed.txt");
    }
    try scratch.exec(io, &.{ "-C", "theirs", "push", "-q", "origin", "main" });
    var pushed = try push_mod.push(gpa, io, &repo, "origin", .{ .who = who, .programs = helpers.programs(), .refspecs = &.{"refs/heads/main:refs/heads/main"} });
    defer pushed.deinit();
    try std.testing.expect(!pushed.anyRejected());
    const remote_a = try theirs_remote.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(remote_a);
    const remote_b = try mine_remote.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(remote_b);
    try std.testing.expectEqualStrings(remote_a, remote_b);
    try expectSameRefs(gpa, io, &scratch, "theirs", "mine");
}

test "clone and push through a helper's fetch and push, and a connect helper's conversation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var remote = try testgit.Repo.init(gpa, io, &.{});
    defer remote.deinit();
    try remoteFixture(gpa, io, &remote);
    try remote.exec(io, &.{ "config", "receive.denyCurrentBranch", "ignore" });
    var scratch = try testgit.Repo.init(gpa, io, &.{});
    defer scratch.deinit();
    var helpers = try Helpers.init(gpa, io, &scratch);
    defer helpers.deinit();
    try helpers.give(&scratch);
    const remote_path = try pathOf(gpa, io, remote.dir);
    defer gpa.free(remote_path);

    var config = try config_mod.Config.parseText(gpa, "[protocol \"ext\"]\n\tallow = always\n", .command);
    defer config.deinit();
    const urls = [_][]const u8{
        try std.fmt.allocPrint(gpa, "testfetch::{s}", .{remote_path}),
        try std.fmt.allocPrint(gpa, "ext::git %s {s}", .{remote_path}),
    };
    defer for (urls) |u| gpa.free(u);
    // `git-remote-ext` is a git builtin, on `PATH` only where git installs
    // its dashed names — not every Git for Windows does.
    const exec_path = try scratch.line(io, &.{"--exec-path"});
    defer gpa.free(exec_path);
    const ext_name = if (builtin.os.tag == .windows) "git-remote-ext.exe" else "git-remote-ext";
    const ext_path = try std.fs.path.join(gpa, &.{ exec_path, ext_name });
    defer gpa.free(ext_path);
    const have_ext = if (Io.Dir.cwd().access(io, ext_path, .{})) |_| true else |_| false;
    for (urls, 0..) |url, i| {
        if (i == 1 and !have_ext) continue;
        const theirs = if (i == 0) "theirs-fetch" else "theirs-ext";
        const mine = if (i == 0) "mine-fetch" else "mine-ext";
        try scratch.exec(io, &.{ "-c", "protocol.ext.allow=always", "clone", "-q", url, theirs });
        try scratch.dir.createDirPath(io, mine);
        const mine_dir = try scratch.dir.openDir(io, mine, .{ .iterate = true });
        defer mine_dir.close(io);
        var repo = try clone_mod.clone(gpa, io, url, mine_dir, .{ .who = who, .programs = helpers.programs(), .config = &config });
        defer repo.deinit(io);
        try expectSameRefs(gpa, io, &scratch, theirs, mine);
    }

    // A push through `push`: the remote takes the commit, and the
    // remote-tracking ref follows it.
    try commitIn(gpa, io, &scratch, "mine-fetch", testgit.fixture_date + 300, "by-push.txt");
    const mine_dir = try scratch.dir.openDir(io, "mine-fetch", .{ .iterate = true });
    defer mine_dir.close(io);
    var repo = try Repository.open(gpa, io, mine_dir, .{});
    defer repo.deinit(io);
    var pushed = try push_mod.push(gpa, io, &repo, "origin", .{ .who = who, .programs = helpers.programs(), .refspecs = &.{"refs/heads/main:refs/heads/pushed"} });
    defer pushed.deinit();
    try std.testing.expect(!pushed.anyRejected());
    const there = try remote.line(io, &.{ "rev-parse", "refs/heads/pushed" });
    defer gpa.free(there);
    const here = try scratch.line(io, &.{ "-C", "mine-fetch", "rev-parse", "HEAD" });
    defer gpa.free(here);
    try std.testing.expectEqualStrings(here, there);
}

test "a helper that is not there, or not allowed, is refused by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try testgit.Repo.init(gpa, io, &.{});
    defer scratch.deinit();
    var helpers = try Helpers.init(gpa, io, &scratch);
    defer helpers.deinit();
    try std.testing.expectError(error.HelperNotFound, transport.Session.open(gpa, io, "nosuchhelper::x", .upload_pack, null, .{ .programs = helpers.programs() }));
    try std.testing.expectError(error.HelperNotFound, transport.Session.open(gpa, io, "nosuchscheme://host/x", .upload_pack, null, .{ .programs = helpers.programs() }));
    try std.testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "ext::git %s /x", .upload_pack, null, .{ .programs = helpers.programs() }));
    try std.testing.expectError(error.ProgramsNotGranted, transport.Session.open(gpa, io, "testgit::/x", .upload_pack, null, .{}));
}
