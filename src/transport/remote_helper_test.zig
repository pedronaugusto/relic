//! Remote helpers, against git: git and relic pointed at the same helper —
//! the suite's `git-remote-testgit` (git's own, for `import` and `export`),
//! its `git-remote-testfetch` (`fetch` and `push`), and git's `ext` (for
//! `connect`) — clone, fetch and push, and the refs on both sides, the
//! helper's private refs and its marks agree.

const std = @import("std");
const suite = @import("../testing/helpers.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");
const transport = @import("transport.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const program = @import("../process.zig").program;
const warning = @import("../report.zig").warning;

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
        for ([_][]const u8{ "git-remote-testgit", "git-remote-testfetch", "git-remote-testscript" }) |name| {
            const exe = if (builtin.target.os.tag == .windows) try gpa.print("{s}.exe", .{name}) else try gpa.dupe(u8, name);
            defer gpa.free(exe);
            try Io.Dir.cwd().copyFile(suite.path(.remote_helper), bin.dir, exe, io, .{});
            if (builtin.target.os.tag != .windows) {
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
        const sep = [_]u8{std.Io.Dir.path.delimiter};
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
    const path = try std.Io.Dir.path.join(gpa, &.{ dir, file });
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
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, p, '\\', '/');
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
    const theirs_url = try gpa.print("testgit::{s}", .{theirs_path});
    defer gpa.free(theirs_url);
    const mine_url = try gpa.print("testgit::{s}", .{mine_path});
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
        try gpa.print("testfetch::{s}", .{remote_path}),
        try gpa.print("ext::git %s {s}", .{remote_path}),
    };
    defer for (urls) |u| gpa.free(u);
    // `git-remote-ext` is a git builtin, on `PATH` only where git installs
    // its dashed names — not every Git for Windows does.
    const exec_path = try scratch.line(io, &.{"--exec-path"});
    defer gpa.free(exec_path);
    const ext_name = if (builtin.target.os.tag == .windows) "git-remote-ext.exe" else "git-remote-ext";
    const ext_path = try std.Io.Dir.path.join(gpa, &.{ exec_path, ext_name });
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
    try std.testing.expectError(error.HelperNotFound, transport.Session.open(gpa, io, "nosuchhelper::x", .{ .service = .upload_pack, .kind = null }, .{ .programs = helpers.programs() }));
    try std.testing.expectError(error.HelperNotFound, transport.Session.open(gpa, io, "nosuchscheme://host/x", .{ .service = .upload_pack, .kind = null }, .{ .programs = helpers.programs() }));
    try std.testing.expectError(error.TransportNotAllowed, transport.Session.open(gpa, io, "ext::git %s /x", .{ .service = .upload_pack, .kind = null }, .{ .programs = helpers.programs() }));
    try std.testing.expectError(error.ProgramsNotGranted, transport.Session.open(gpa, io, "testgit::/x", .{ .service = .upload_pack, .kind = null }, .{}));
}

/// A helper's answers given by a script, to git and to relic in the same
/// repository: `testscript::x`.
const Scripted = struct {
    gpa: Allocator,
    scratch: testgit.Repo,
    helpers: Helpers,
    script_path: []u8,

    fn init(gpa: Allocator, io: Io) !Scripted {
        var scratch = try testgit.Repo.init(gpa, io, &.{});
        errdefer scratch.deinit();
        try scratch.writeFile(io, "a.txt", "a\n");
        try scratch.exec(io, &.{ "add", "." });
        try scratch.exec(io, &.{ "commit", "-q", "-m", "one" });
        try scratch.exec(io, &.{ "branch", "side" });
        var helpers = try Helpers.init(gpa, io, &scratch);
        errdefer helpers.deinit();
        try helpers.give(&scratch);
        const dir = try pathOf(gpa, io, scratch.dir);
        defer gpa.free(dir);
        const script_path = try std.Io.Dir.path.join(gpa, &.{ dir, ".git", "helper-script" });
        errdefer gpa.free(script_path);
        try helpers.environ.put("RELIC_HELPER_SCRIPT", script_path);
        try scratch.isolated.?.put("RELIC_HELPER_SCRIPT", script_path);
        return .{ .gpa = gpa, .scratch = scratch, .helpers = helpers, .script_path = script_path };
    }

    fn deinit(s: *Scripted) void {
        s.gpa.free(s.script_path);
        s.helpers.deinit();
        s.scratch.deinit();
        s.* = undefined;
    }

    fn script(s: *Scripted, io: Io, text: []const u8) !void {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = s.script_path, .data = text });
    }

    /// What git printed after `warning: `, a line each.
    fn gitWarnings(arena: Allocator, stderr: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |l| if (std.mem.startsWith(u8, l, "warning: ")) try out.print(arena, "{s}\n", .{l["warning: ".len..]});
        return out.items;
    }

    fn relicWarnings(arena: Allocator, w: *const warning.Warnings) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (w.items.items) |item| try out.print(arena, "{s}\n", .{try item.message(arena)});
        return out.items;
    }
};

test "a helper's ref list is read as git reads it: values, symrefs, `?`, `unchanged`, the object format, line endings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Scripted.init(gpa, io);
    defer s.deinit();
    const main_oid = try s.scratch.line(io, &.{ "rev-parse", "refs/heads/main" });
    defer gpa.free(main_oid);
    var upper_buf: [40]u8 = undefined;
    const upper = std.ascii.upperString(&upper_buf, main_oid);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An import helper without a refspec, and an answer to `option` that
    // is none git knows, are warned of.
    const caps = [_][]const u8{
        "== capabilities\nfetch\noption\nobject-format\n\n== option\nok\n",
        "== capabilities\n*import\noption\nunknown\n\n== option\nmaybe\n== option progress\nerror no\n",
        "== capabilities\nfetch\r\noption\r\n\r\n== option\nunsupported\r\n",
    };
    const lists = [_][]const u8{
        try arena.print("{s} refs/heads/main\n@refs/heads/main HEAD\n\n", .{main_oid}),
        "? refs/heads/main\n@refs/heads/gone HEAD\n\n",
        try arena.print("{s} refs/heads/up\n{s}zz refs/heads/long\nabc refs/heads/short\n refs/heads/empty\n\n", .{ upper, main_oid }),
        try arena.print("{s} refs/heads/crlf\r\n\r\n", .{main_oid}),
        try arena.print(":object-format sha1\n:anything else\n{s} refs/heads/fmt\n\n", .{main_oid}),
        ":object-format md5\n\n",
        "nospace\n\n",
        try arena.print("{s} refs/heads/side x unchanged y\n\n", .{main_oid}),
        try arena.print("{s} refs/heads/nothere unchanged\n\n", .{main_oid}),
        try arena.print("{s} refs/heads/a extra words\n{s} refs/heads/n\x00ul\n\n", .{ main_oid, main_oid }),
        // The last block: a list cut off with no blank line.
        try arena.print("{s} refs/heads/cut", .{main_oid}),
    };
    var repo = try Repository.open(gpa, io, s.scratch.dir, .{});
    defer repo.deinit(io);
    for (lists, 0..) |list, i| {
        try s.script(io, try arena.print("{s}== list\n{s}", .{ caps[i % caps.len], list }));
        var theirs = try s.scratch.capture(io, &.{ "ls-remote", "testscript::x" });
        defer theirs.deinit(gpa);
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        const ours: ?[]const u8 = blk: {
            var session = transport.Session.open(gpa, io, "testscript::x", .{ .service = .upload_pack, .kind = .sha1 }, .{
                .programs = s.helpers.programs(),
                .repository = &repo,
                .warnings = &warnings,
            }) catch break :blk null;
            defer session.deinit(io);
            var refs = session.listRefs(gpa, io, &.{}) catch break :blk null;
            defer refs.arena.deinit();
            var out: std.ArrayList(u8) = .empty;
            for (refs.refs) |r| try out.print(arena, "{f}\t{s}\n", .{ r.oid, r.name });
            break :blk out.items;
        };
        errdefer std.debug.print("list:\n{s}\ngit ({d}):\n{s}{s}\nrelic:\n{?s}\n", .{ list, theirs.code, theirs.stdout, theirs.stderr, ours });
        try std.testing.expectEqual(theirs.code == 0, ours != null);
        if (ours) |text| try std.testing.expectEqualStrings(theirs.stdout, text);
        try std.testing.expectEqualStrings(try Scripted.gitWarnings(arena, theirs.stderr), try Scripted.relicWarnings(arena, &warnings));
    }
}

test "a helper's push answers are read as git reads them: the states its reasons name, quoted reasons, options, refs it was not asked about" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Scripted.init(gpa, io);
    defer s.deinit();
    var env = try testgit.datedEnv(gpa, testgit.fixture_date + 60);
    defer env.deinit();
    try env.put("PATH", s.scratch.isolated.?.get("PATH").?);
    try env.put("RELIC_HELPER_SCRIPT", s.script_path);
    const was = s.scratch.environ;
    s.scratch.environ = &env;
    try s.scratch.writeFile(io, "a.txt", "a2\n");
    try s.scratch.exec(io, &.{ "commit", "-q", "-a", "-m", "two" });
    s.scratch.environ = was;
    const before = try s.scratch.line(io, &.{ "rev-parse", "refs/heads/main~1" });
    defer gpa.free(before);
    const after = try s.scratch.line(io, &.{ "rev-parse", "refs/heads/main" });
    defer gpa.free(after);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = try arena.print(
        \\== capabilities
        \\push
        \\option
        \\refspec refs/heads/*:refs/testscript/heads/*
        \\
        \\== option
        \\ok
        \\== list
        \\{s} refs/heads/main
        \\
        \\== push
        \\
    , .{before});
    const answers = [_][]const u8{
        "ok refs/heads/main\nok refs/heads/new\n\n",
        "error refs/heads/main non-fast forward\nerror refs/heads/new \"spaced\\tquoted\" after\n\n",
        "ok refs/heads/main forced update\nok refs/heads/new up to date\n\n",
        "error refs/heads/main forced update\nerror refs/heads/new no match\n\n",
        "\n",
        "ok refs/heads/other\nok refs/heads/main\n\n",
        try arena.print("ok refs/heads/main\noption refname refs/heads/moved\noption new-oid {s}\noption forced-update\nok refs/heads/main\noption refname refs/heads/twice\nok refs/heads/new\n\n", .{before}),
        "error refs/heads/main x\noption refname a\n\n",
        "bogus\n\n",
        "ok refs/heads/main\r\nerror refs/heads/new fetch first\r\n\r\n",
        "error refs/heads/main already exists\nerror refs/heads/new needs force\n\n",
        "error refs/heads/main stale info\nerror refs/heads/new remote ref updated since checkout\n\n",
        "error refs/heads/main expecting report\nok refs/heads/main\nerror refs/heads/main no match\nok refs/heads/new some words\n\n",
    };
    const refspecs: []const []const u8 = &.{ "refs/heads/main:refs/heads/main", "refs/heads/main:refs/heads/new" };
    for (answers) |answer| {
        try s.script(io, try arena.print("{s}{s}", .{ head, answer }));
        // The private refs each side's push moves, from none.
        for ([_][]const u8{ "main", "new", "moved", "twice" }) |name| {
            var gone = try s.scratch.capture(io, &.{ "update-ref", "-d", try arena.print("refs/testscript/heads/{s}", .{name}) });
            gone.deinit(gpa);
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "push", "--porcelain", "testscript::x" });
        try argv.appendSlice(arena, refspecs);
        var theirs = try s.scratch.capture(io, argv.items);
        defer theirs.deinit(gpa);
        const their_private = try s.scratch.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/testscript/" });
        defer gpa.free(their_private);
        for ([_][]const u8{ "main", "new", "moved", "twice" }) |name| {
            var gone = try s.scratch.capture(io, &.{ "update-ref", "-d", try arena.print("refs/testscript/heads/{s}", .{name}) });
            gone.deinit(gpa);
        }

        var repo = try Repository.open(gpa, io, s.scratch.dir, .{});
        defer repo.deinit(io);
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        const ours: ?[]const u8 = blk: {
            var outcome = push_mod.push(gpa, io, &repo, "testscript::x", .{ .who = who, .programs = s.helpers.programs(), .refspecs = refspecs, .warnings = &warnings }) catch break :blk null;
            defer outcome.deinit();
            var out: std.ArrayList(u8) = .empty;
            // git prints nothing for a ref the helper had no match for.
            for (outcome.refs) |r| {
                if (r.status == .no_match) continue;
                // Each update an `ok` stood for is a line of git's own.
                if (r.status == .ok) for (r.updates) |u| {
                    try out.print(arena, "{s} {s}\n", .{ u.refname orelse r.remote_ref, if (u.forced) "forced" else "ok" });
                };
                if (r.status != .ok or r.updates.len == 0) try out.print(arena, "{s} {s}\n", .{ r.remote_ref, try said(arena, r) });
            }
            break :blk out.items;
        };
        const our_private = try s.scratch.run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/testscript/" });
        defer gpa.free(our_private);
        const their_lines = try porcelain(arena, theirs.stdout);
        errdefer std.debug.print("answer:\n{s}\ngit ({d}):\n{s}{s}\nrelic:\n{?s}\n", .{ answer, theirs.code, theirs.stdout, theirs.stderr, ours });
        // git dies on an answer it cannot read, after `To <url>` at most.
        try std.testing.expectEqual(theirs.code == 128, ours == null);
        // git prints the refs in its remote list's order; the states are
        // compared by ref.
        if (ours) |text| try std.testing.expectEqualStrings(try sortedLines(arena, their_lines), try sortedLines(arena, text));
        try std.testing.expectEqualStrings(their_private, our_private);
        try std.testing.expectEqualStrings(try Scripted.gitWarnings(arena, theirs.stderr), try Scripted.relicWarnings(arena, &warnings));
    }
}

/// `git push --porcelain`'s lines as `<ref> <state>`: `ok`, `forced`, `up
/// to date`, or the bracketed summary and its reason.
fn porcelain(arena: Allocator, stdout: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |l| {
        if (l.len < 2 or l[1] != '\t') continue;
        var parts = std.mem.splitScalar(u8, l[2..], '\t');
        const refs = parts.next().?;
        const summary = parts.rest();
        const to = refs[std.mem.findScalarLast(u8, refs, ':').? + 1 ..];
        const state: []const u8 = switch (l[0]) {
            ' ', '*', '-' => "ok",
            '+' => "forced",
            '=' => "up to date",
            else => summary,
        };
        try out.print(arena, "{s} {s}\n", .{ to, state });
    }
    return out.items;
}

/// A push result as `porcelain` reads git's.
fn said(arena: Allocator, r: push_mod.RefResult) ![]const u8 {
    return switch (r.status) {
        .ok => if (r.forced) "forced" else "ok",
        .up_to_date => "up to date",
        .no_match => unreachable,
        .rejected_by_remote => if (r.message) |m| arena.print("[remote rejected] ({s})", .{m}) else "[remote rejected]",
        .rejected_non_fast_forward => "[rejected] (non-fast-forward)",
        .rejected_already_exists => "[rejected] (already exists)",
        .rejected_fetch_first => "[rejected] (fetch first)",
        .rejected_needs_force => "[rejected] (needs force)",
        .rejected_stale => "[rejected] (stale info)",
        .rejected_remote_updated => "[rejected] (remote ref updated since checkout)",
        .unreported => "[remote failure] (remote failed to report status)",
        .atomic_failed => "[rejected] (atomic push failed)",
        .not_sent => "not sent",
    };
}

fn sortedLines(arena: Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len != 0) try lines.append(arena, l);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return std.mem.join(arena, "\n", lines.items);
}
