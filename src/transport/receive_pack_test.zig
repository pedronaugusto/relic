//! relic's receive-pack held to git's: real git pushes to it — handed it as
//! `--receive-pack` — and to its own, and what each push reported, what
//! the hooks were shown and what the refs ended as are compared, push by
//! push: creations, fast-forwards and refusals by `receive.*`, deletions,
//! hooks that decline, atomic pushes, push options, hidden refs, a
//! checked-out branch, in protocol v0, v1 and v2.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const suite = @import("../testing/helpers.zig");
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const program = @import("../process.zig").program;
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const push_mod = @import("push.zig");

const zero = "0000000000000000000000000000000000000000";

/// Hooks that write what they were shown to `hook.log` in the git
/// directory, the quarantine and what it holds included, and say a word
/// back to the pusher; `update` declines a branch named `declined…`, and
/// `pre-receive` declines everything while `decline-pre-receive` exists.
const hook_scripts = [_][2][]const u8{
    .{
        "pre-receive",
        \\#!/bin/sh
        \\echo "pre-receive options=$GIT_PUSH_OPTION_COUNT $GIT_PUSH_OPTION_0 $GIT_PUSH_OPTION_1" >>hook.log
        \\while read old new ref; do
        \\  echo "pre-receive $old $new $ref" >>hook.log
        \\  if test "$new" != "
        ++ zero ++
            \\"; then git cat-file -e "$new" && echo "pre-receive reads $ref" >>hook.log; fi
            \\done
            \\test -n "$GIT_QUARANTINE_PATH" && test -d "$GIT_QUARANTINE_PATH" && echo "pre-receive quarantined" >>hook.log
            \\echo "hook says pre-receive"
            \\test ! -e decline-pre-receive
            \\
    },
    .{
        "update",
        \\#!/bin/sh
        \\echo "update $1 $2 $3" >>hook.log
        \\case "$1" in refs/heads/declined*) echo "hook says no to $1"; exit 1;; esac
        \\exit 0
        \\
    },
    .{
        "post-receive",
        \\#!/bin/sh
        \\echo "post-receive options=$GIT_PUSH_OPTION_COUNT" >>hook.log
        \\while read old new ref; do echo "post-receive $old $new $ref" >>hook.log; done
        \\test -z "$GIT_QUARANTINE_PATH" || echo "post-receive quarantined" >>hook.log
        \\
    },
    .{
        "post-update",
        \\#!/bin/sh
        \\echo "post-update $*" >>hook.log
        \\
    },
};

/// Two repositories alike, one pushed to through git's receive-pack and
/// one through relic's, and a source to push from.
const Pair = struct {
    gpa: Allocator,
    io: Io,
    root: testing.TmpDir,
    env: std.process.Environ.Map,
    source: testgit.Repo,
    theirs: []u8,
    ours: []u8,
    helper: []u8,
    /// `-c` settings for the pushing git, which reach either server too.
    settings: []const []const u8 = &.{},

    fn init(gpa: Allocator, io: Io, bare: bool, settings: []const [2][]const u8) !Pair {
        if (builtin.target.os.tag == .windows) return error.SkipZigTest; // the hooks are shell scripts
        var p: Pair = .{ .gpa = gpa, .io = io, .root = testing.tmpDir(.{ .iterate = true }), .env = undefined, .source = undefined, .theirs = &.{}, .ours = &.{}, .helper = &.{} };
        errdefer p.root.cleanup();
        p.env = try testremote.environ(gpa);
        errdefer p.env.deinit();
        p.source = try testgit.Repo.init(gpa, io, &.{});
        errdefer p.source.deinit();
        try testremote.addCommits(gpa, io, &p.source, 0, 3);
        try p.source.exec(io, &.{ "tag", "-a", "v1", "-m", "one" });
        const root_path = try testremote.absolutePath(gpa, io, p.root.dir);
        defer gpa.free(root_path);
        p.theirs = try gpa.print("{s}/theirs", .{root_path});
        p.ours = try gpa.print("{s}/ours", .{root_path});
        p.helper = try gpa.dupe(u8, suite.path(.receive_pack_helper));
        for ([_][]const u8{ p.theirs, p.ours }) |target| {
            if (bare) {
                try p.git(p.root.dir, &.{ "init", "-q", "--bare", "-b", "main", target });
            } else {
                try p.git(p.root.dir, &.{ "init", "-q", "-b", "main", target });
            }
            var dir = try Io.Dir.cwd().openDir(io, target, .{});
            defer dir.close(io);
            for (settings) |kv| try p.git(dir, &.{ "config", kv[0], kv[1] });
            const git_dir = if (bare) "." else ".git";
            for (hook_scripts) |hook| {
                const name = try gpa.print("{s}/hooks/{s}", .{ git_dir, hook[0] });
                defer gpa.free(name);
                try dir.writeFile(io, .{ .sub_path = name, .data = hook[1] });
                const file = try dir.openFile(io, name, .{});
                defer file.close(io);
                try file.setPermissions(io, .fromMode(0o755));
            }
        }
        return p;
    }

    fn deinit(p: *Pair) void {
        p.gpa.free(p.theirs);
        p.gpa.free(p.ours);
        p.gpa.free(p.helper);
        p.source.deinit();
        p.env.deinit();
        p.root.cleanup();
    }

    fn git(p: *Pair, dir: Io.Dir, args: []const []const u8) !void {
        const out = try testremote.gitInputEnv(p.gpa, p.io, dir, &p.env, args, "", true);
        p.gpa.free(out);
    }

    const Pushed = struct { ok: bool, report: []u8, remote_lines: []u8 };

    /// `git push --porcelain` from the source to `target`, through
    /// relic's receive-pack when `ours`: whether it succeeded, the status
    /// lines, and what the server said on `remote:` lines from the hooks.
    fn push(p: *Pair, target: []const u8, ours: bool, args: []const []const u8) !Pushed {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(p.gpa);
        try argv.append(p.gpa, "git");
        try argv.appendSlice(p.gpa, p.settings);
        try argv.appendSlice(p.gpa, &.{ "push", "--porcelain" });
        if (ours) try argv.appendSlice(p.gpa, &.{ "--receive-pack", p.helper });
        const url = try p.gpa.print("file://{s}", .{target});
        defer p.gpa.free(url);
        try argv.append(p.gpa, url);
        try argv.appendSlice(p.gpa, args);
        var outcome = try program.run(p.gpa, p.io, .{ .environ = &p.env }, .{ .argv = argv.items, .cwd = .{ .dir = p.source.dir } }, .{});
        defer outcome.deinit(p.gpa);
        var report: std.ArrayList(u8) = .empty;
        errdefer report.deinit(p.gpa);
        var lines = std.mem.tokenizeScalar(u8, outcome.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "To ")) continue;
            try report.print(p.gpa, "{s}\n", .{line});
        }
        var remote: std.ArrayList(u8) = .empty;
        errdefer remote.deinit(p.gpa);
        var err_lines = std.mem.tokenizeScalar(u8, outcome.stderr, '\n');
        while (err_lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "remote: hook says")) try remote.print(p.gpa, "{s}\n", .{std.mem.trimEnd(u8, line, " \r")});
        }
        return .{ .ok = outcome.succeeded(), .report = try report.toOwnedSlice(p.gpa), .remote_lines = try remote.toOwnedSlice(p.gpa) };
    }

    /// The same push to both, held to the same outcome.
    fn both(p: *Pair, args: []const []const u8) !void {
        const theirs = try p.push(p.theirs, false, args);
        defer p.gpa.free(theirs.report);
        defer p.gpa.free(theirs.remote_lines);
        const ours = try p.push(p.ours, true, args);
        defer p.gpa.free(ours.report);
        defer p.gpa.free(ours.remote_lines);
        testing.expectEqualStrings(theirs.report, ours.report) catch |err| {
            std.debug.print("push {s}\n", .{args[args.len - 1]});
            return err;
        };
        try testing.expectEqual(theirs.ok, ours.ok);
        try testing.expectEqualStrings(theirs.remote_lines, ours.remote_lines);
        try p.expectSame();
    }

    /// Both ended with the same refs, the same hook log and no quarantine
    /// left; relic's passes git's own check.
    fn expectSame(p: *Pair) !void {
        const listed = [2][]const u8{ p.theirs, p.ours };
        var refs: [2][]u8 = undefined;
        var logs: [2][]u8 = undefined;
        for (listed, 0..) |target, i| {
            var dir = try Io.Dir.cwd().openDir(p.io, target, .{});
            defer dir.close(p.io);
            refs[i] = try testremote.gitInputEnv(p.gpa, p.io, dir, &p.env, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, "", true);
            const git_dir = try testremote.gitInputEnv(p.gpa, p.io, dir, &p.env, &.{ "rev-parse", "--git-dir" }, "", true);
            defer p.gpa.free(git_dir);
            const log_path = try p.gpa.print("{s}/hook.log", .{std.mem.trimEnd(u8, git_dir, "\n")});
            defer p.gpa.free(log_path);
            logs[i] = dir.readFileAlloc(p.io, log_path, p.gpa, .unlimited) catch try p.gpa.dupe(u8, "");
            const objects = try p.gpa.print("{s}/objects", .{std.mem.trimEnd(u8, git_dir, "\n")});
            defer p.gpa.free(objects);
            var objects_dir = try dir.openDir(p.io, objects, .{ .iterate = true });
            defer objects_dir.close(p.io);
            var it = objects_dir.iterate();
            while (try it.next(p.io)) |entry| try testing.expect(!std.mem.startsWith(u8, entry.name, "tmp_objdir-") and !std.mem.startsWith(u8, entry.name, "incoming-"));
        }
        defer for (refs) |r| p.gpa.free(r);
        defer for (logs) |l| p.gpa.free(l);
        try testing.expectEqualStrings(refs[0], refs[1]);
        try testing.expectEqualStrings(logs[0], logs[1]);
        var ours = try Io.Dir.cwd().openDir(p.io, p.ours, .{});
        defer ours.close(p.io);
        try p.git(ours, &.{ "fsck", "--strict", "--no-dangling" });
    }

    fn markBoth(p: *Pair, name: []const u8, present: bool, bare: bool) !void {
        for ([_][]const u8{ p.theirs, p.ours }) |target| {
            var dir = try Io.Dir.cwd().openDir(p.io, target, .{});
            defer dir.close(p.io);
            const path = try p.gpa.print("{s}{s}", .{ if (bare) "" else ".git/", name });
            defer p.gpa.free(path);
            if (present) try dir.writeFile(p.io, .{ .sub_path = path, .data = "" }) else try dir.deleteFile(p.io, path);
        }
    }
};

test "git pushes to relic's receive-pack as to its own: refs, refusals, hooks and their quarantine" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{
        .{ "receive.denyNonFastForwards", "true" },
        .{ "receive.advertisePushOptions", "true" },
        .{ "receive.hideRefs", "refs/hidden" },
        .{ "receive.fsckObjects", "true" },
        .{ "receive.procReceiveRefs", "refs/for" },
    });
    defer p.deinit();
    // Creations, a tag with them.
    try p.both(&.{ "main:refs/heads/main", "v1", "main~1:refs/heads/side" });
    try testremote.addCommits(gpa, io, &p.source, 3, 1);
    // A fast-forward, and a non-fast-forward denyNonFastForwards refuses.
    try p.both(&.{ "main:refs/heads/main", "+main~3:refs/heads/side" });
    // A deletion, and a deletion of nothing.
    try p.both(&.{ ":refs/heads/side", ":refs/heads/never" });
    // The update hook declining one ref of several.
    try p.both(&.{ "main:refs/heads/declined", "main:refs/heads/accepted" });
    // Atomic: the one refusal refuses both.
    try p.both(&.{ "--atomic", "main:refs/heads/declined-too", "main:refs/heads/atomic" });
    try p.both(&.{ "--atomic", "main:refs/heads/atomic-a", "main~1:refs/heads/atomic-b" });
    // Push options for the hooks.
    try p.both(&.{ "-o", "first", "-o", "second", "main:refs/heads/optioned" });
    // A ref for a proc-receive hook, which neither repository has.
    try p.both(&.{ "main:refs/for/main", "main:refs/heads/beside-for" });
    // A hidden ref.
    try p.both(&.{"main:refs/hidden/x"});
    // In protocol v1 and v2 (which receive-pack answers in v0).
    p.settings = &.{ "-c", "protocol.version=1" };
    try p.both(&.{"main:refs/heads/v1"});
    p.settings = &.{ "-c", "protocol.version=2" };
    try p.both(&.{"main:refs/heads/v2"});
    p.settings = &.{};
    // A commit fsck refuses: the pack is not taken.
    const tree = try p.source.line(io, &.{ "rev-parse", "main^{tree}" });
    defer gpa.free(tree);
    const bad_text = try gpa.print("tree {s}\nauthor A <a@example.com> 1 +0000\ncommitter no email 1 +0000\n\nbad\n", .{tree});
    defer gpa.free(bad_text);
    const bad = try testremote.gitInput(gpa, io, p.source.dir, &.{ "hash-object", "-t", "commit", "--literally", "-w", "--stdin" }, bad_text);
    defer gpa.free(bad);
    try p.source.exec(io, &.{ "update-ref", "refs/heads/bad", std.mem.trimEnd(u8, bad, "\n") });
    try p.both(&.{ "bad:refs/heads/bad", "main:refs/heads/beside-bad" });
    // pre-receive declining the whole push: nothing of it stays.
    try p.markBoth("decline-pre-receive", true, true);
    try testremote.addCommits(gpa, io, &p.source, 4, 1);
    try p.both(&.{ "main:refs/heads/main", "main:refs/heads/new" });
    try p.markBoth("decline-pre-receive", false, true);
}

test "a push to a checked-out branch is refused as git refuses it, and taken when told to ignore it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, false, &.{});
    defer p.deinit();
    try p.both(&.{"main:refs/heads/main"});
    try p.both(&.{"main:refs/heads/other"});
    try p.both(&.{":refs/heads/main"});
    for ([_][]const u8{ p.theirs, p.ours }) |target| {
        var dir = try Io.Dir.cwd().openDir(io, target, .{});
        defer dir.close(io);
        try p.git(dir, &.{ "config", "receive.denyCurrentBranch", "ignore" });
        try p.git(dir, &.{ "config", "receive.denyDeleteCurrent", "warn" });
    }
    try p.both(&.{"main:refs/heads/main"});
    try p.both(&.{":refs/heads/main"});
}

test "relic pushes to a repository on this machine through its receive-pack, hooks run with the caller's permission" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{});
    defer p.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, p.source.dir, .{});
    defer repo.deinit(io);
    const who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
    // Without permission to run programs, a repository with hooks refuses.
    try testing.expectError(error.RemoteHooksNotRun, push_mod.push(gpa, io, &repo, p.ours, .{ .who = who, .refspecs = &.{"main:refs/heads/main"} }));
    const theirs = try p.push(p.theirs, false, &.{ "main:refs/heads/main", "main:refs/heads/declined" });
    defer gpa.free(theirs.report);
    defer gpa.free(theirs.remote_lines);
    var outcome = try push_mod.push(gpa, io, &repo, p.ours, .{ .who = who, .refspecs = &.{ "main:refs/heads/main", "main:refs/heads/declined" }, .programs = .{ .environ = &p.env } });
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 2), outcome.refs.len);
    try testing.expectEqual(push_mod.RefResult.Status.ok, outcome.refs[0].status);
    try testing.expectEqual(push_mod.RefResult.Status.rejected_by_remote, outcome.refs[1].status);
    try testing.expectEqualStrings("hook declined", outcome.refs[1].message.?);
    try p.expectSame();
}
