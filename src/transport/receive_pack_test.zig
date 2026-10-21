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
const fetch_mod = @import("fetch.zig");

const zero = "0000000000000000000000000000000000000000";

/// Hooks that write what they were shown to `hook.log` in the git
/// directory, the quarantine and what it holds included, and say a word
/// back to the pusher -- `update` on standard output, standard error and
/// standard output again, which git relays in that order; `update` declines a branch named `declined…`, and
/// `pre-receive` declines everything while `decline-pre-receive` exists,
/// and takes three seconds while `slow` does.
/// `update` for `refs/heads/meddle` moves refs behind the push's back,
/// while `meddle` exists: `race` back one commit, `made` created, `gone`
/// deleted. `reference-transaction` logs every state and line.
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
            \\test -z "$GIT_PUSH_CERT" || { echo "pre-receive cert $GIT_PUSH_CERT_STATUS $GIT_PUSH_CERT_SIGNER $GIT_PUSH_CERT_KEY ${GIT_PUSH_CERT_NONCE:+nonce} $GIT_PUSH_CERT_NONCE_STATUS" >>hook.log; git cat-file blob "$GIT_PUSH_CERT" | sed -e '/^-----BEGIN/,$d' -e 's/^\(pusher [^ ]*\) .*/\1/' -e 's/^pushee .*/pushee/' -e 's/^nonce .*/nonce/' >>hook.log; }
            \\echo "hook says pre-receive"
            \\test ! -e slow || sleep 3
            \\test ! -e decline-pre-receive
            \\
    },
    .{
        "update",
        \\#!/bin/sh
        \\echo "update $1 $2 $3" >>hook.log
        \\echo "hook says update out"; echo "hook says update err" >&2; echo "hook says update out again"
        \\case "$1" in refs/heads/declined*) echo "hook says no to $1"; exit 1;; esac
        \\if test "$1" = refs/heads/meddle && test -e meddle; then
        \\  git update-ref refs/heads/race refs/heads/race~1
        \\  git update-ref refs/heads/made refs/heads/main
        \\  git update-ref -d refs/heads/gone
        \\fi
        \\exit 0
        \\
    },
    .{
        "post-receive",
        \\#!/bin/sh
        \\echo "post-receive options=$GIT_PUSH_OPTION_COUNT" >>hook.log
        \\while read old new ref; do echo "post-receive $old $new $ref" >>hook.log; done
        \\test -z "$GIT_QUARANTINE_PATH" || echo "post-receive quarantined" >>hook.log
        \\test -z "$GIT_PUSH_CERT" || { echo "post-receive cert $GIT_PUSH_CERT_STATUS $GIT_PUSH_CERT_SIGNER $GIT_PUSH_CERT_KEY ${GIT_PUSH_CERT_NONCE:+nonce} $GIT_PUSH_CERT_NONCE_STATUS" >>hook.log; git cat-file blob "$GIT_PUSH_CERT" | sed -e '/^-----BEGIN/,$d' -e 's/^\(pusher [^ ]*\) .*/\1/' -e 's/^pushee .*/pushee/' -e 's/^nonce .*/nonce/' >>hook.log; }
        \\
    },
    .{
        "reference-transaction",
        \\#!/bin/sh
        \\echo "reference-transaction $1" >>hook.log
        \\while read old new ref; do echo "  $old $new $ref" >>hook.log; done
        \\
    },
    .{
        "post-update",
        \\#!/bin/sh
        \\echo "post-update $*" >>hook.log
        \\
    },
};

/// A `proc-receive` hook that logs what receive-pack sends it and answers
/// from files in the git directory: `proc-receive.version` its version
/// packets (`version=1` when there is none), `proc-receive.report` its
/// report (`ok` for each ref it was handed when there is none),
/// `proc-receive.exit` its exit status. It reads push options when its
/// version packets ask for them, and exits at once while
/// `proc-receive.gone` exists.
const proc_receive_hook =
    \\#!/bin/sh
    \\readpkt() {
    \\  len=$(dd bs=1 count=4 2>/dev/null)
    \\  test -n "$len" || exit 1
    \\  test "$len" = 0000 && return 1
    \\  line=$(dd bs=1 count=$((0x$len - 4)) 2>/dev/null | tr '\0' ' ')
    \\}
    \\pkt() { printf '%04x%s' $((${#1} + 4)) "$1"; }
    \\test -e proc-receive.gone && exit 1
    \\while readpkt; do echo "proc-receive version $line" >>hook.log; done
    \\if test -e proc-receive.version; then cat proc-receive.version; else pkt version=1; printf 0000; fi
    \\refs=
    \\while readpkt; do echo "proc-receive command $line" >>hook.log; refs="$refs ${line##* }"; done
    \\if grep -q push-options proc-receive.version 2>/dev/null; then
    \\  while readpkt; do echo "proc-receive option $line" >>hook.log; done
    \\fi
    \\echo "hook says proc-receive" >&2
    \\if test -e proc-receive.report; then cat proc-receive.report
    \\else for ref in $refs; do pkt "ok $ref"; done; printf 0000; fi
    \\exit $(cat proc-receive.exit 2>/dev/null || echo 0)
    \\
;

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
        return initFormat(gpa, io, bare, "files", settings);
    }

    fn initFormat(gpa: Allocator, io: Io, bare: bool, ref_format: []const u8, settings: []const [2][]const u8) !Pair {
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
            const format_arg = try gpa.print("--ref-format={s}", .{ref_format});
            defer gpa.free(format_arg);
            if (bare) {
                try p.git(p.root.dir, &.{ "init", "-q", "--bare", "-b", "main", format_arg, target });
            } else {
                try p.git(p.root.dir, &.{ "init", "-q", "-b", "main", format_arg, target });
            }
            var dir = try Io.Dir.cwd().openDir(io, target, .{});
            defer dir.close(io);
            // git's receive-pack starts its auto maintenance detached,
            // which would move objects while they are compared.
            try p.git(dir, &.{ "config", "receive.autogc", "false" });
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
            if (std.mem.startsWith(u8, line, "remote: hook says") or std.mem.startsWith(u8, line, "remote: error:")) try remote.print(p.gpa, "{s}\n", .{std.mem.trimEnd(u8, line, " \r")});
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
        // Stored alike: loose below the unpack limit, in packs above it.
        var stored: [2][]u8 = undefined;
        for (listed, 0..) |target, i| {
            var dir = try Io.Dir.cwd().openDir(p.io, target, .{});
            defer dir.close(p.io);
            const counted = try testremote.gitInputEnv(p.gpa, p.io, dir, &p.env, &.{ "count-objects", "-v" }, "", true);
            defer p.gpa.free(counted);
            var kept: std.ArrayList(u8) = .empty;
            var lines = std.mem.tokenizeScalar(u8, counted, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "count:") or std.mem.startsWith(u8, line, "in-pack:") or std.mem.startsWith(u8, line, "packs:")) try kept.print(p.gpa, "{s}\n", .{line});
            }
            stored[i] = try kept.toOwnedSlice(p.gpa);
        }
        defer for (stored) |text| p.gpa.free(text);
        try testing.expectEqualStrings(stored[0], stored[1]);
        var ours = try Io.Dir.cwd().openDir(p.io, p.ours, .{});
        defer ours.close(p.io);
        try p.git(ours, &.{ "fsck", "--strict", "--no-dangling" });
    }

    /// The same git command in both repositories.
    fn gitBoth(p: *Pair, args: []const []const u8) !void {
        for ([_][]const u8{ p.theirs, p.ours }) |target| {
            var dir = try Io.Dir.cwd().openDir(p.io, target, .{});
            defer dir.close(p.io);
            try p.git(dir, args);
        }
    }

    /// How many keepalives a push from the source to `target` hears,
    /// through relic's receive-pack when `ours`: the empty channel-one
    /// packets git's packet trace shows as `sideband< \1`.
    fn keepalives(p: *Pair, target: []const u8, ours: bool, args: []const []const u8) !usize {
        var env = try p.env.clone(p.gpa);
        defer env.deinit();
        try env.put("GIT_TRACE_PACKET", "1");
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(p.gpa);
        try argv.appendSlice(p.gpa, &.{ "git", "push", "-q" });
        if (ours) try argv.appendSlice(p.gpa, &.{ "--receive-pack", p.helper });
        const url = try p.gpa.print("file://{s}", .{target});
        defer p.gpa.free(url);
        try argv.append(p.gpa, url);
        try argv.appendSlice(p.gpa, args);
        var outcome = try program.run(p.gpa, p.io, .{ .environ = &env }, .{ .argv = argv.items, .cwd = .{ .dir = p.source.dir } }, .{});
        defer outcome.deinit(p.gpa);
        try testing.expect(outcome.succeeded());
        var count: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, outcome.stderr, '\n');
        while (lines.next()) |line| {
            if (std.mem.endsWith(u8, line, "sideband< \\1")) count += 1;
        }
        return count;
    }

    /// The same file in both git directories, or none with `null`.
    fn fileBoth(p: *Pair, name: []const u8, data: ?[]const u8, mode: u16) !void {
        for ([_][]const u8{ p.theirs, p.ours }) |target| {
            var dir = try Io.Dir.cwd().openDir(p.io, target, .{});
            defer dir.close(p.io);
            if (data) |bytes| {
                try dir.writeFile(p.io, .{ .sub_path = name, .data = bytes });
                // Windows has no mode bits to set.
                if (builtin.target.os.tag != .windows) {
                    const file = try dir.openFile(p.io, name, .{});
                    defer file.close(p.io);
                    try file.setPermissions(p.io, .fromMode(mode));
                }
            } else dir.deleteFile(p.io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    /// What `proc-receive` answers with in a bare pair: `lines` as packets,
    /// `{old}` and `{new}` in them the source's `main~1` and `main`, then a
    /// flush; `null` for the hook's own answer.
    fn procSays(p: *Pair, name: []const u8, lines: ?[]const []const u8) !void {
        const these = lines orelse return p.fileBoth(name, null, 0o644);
        const old = try p.source.line(p.io, &.{ "rev-parse", "main~1" });
        defer p.gpa.free(old);
        const new = try p.source.line(p.io, &.{ "rev-parse", "main" });
        defer p.gpa.free(new);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(p.gpa);
        for (these) |line| {
            const a = try std.mem.replaceOwned(u8, p.gpa, line, "{old}", old);
            defer p.gpa.free(a);
            const b = try std.mem.replaceOwned(u8, p.gpa, a, "{new}", new);
            defer p.gpa.free(b);
            try out.print(p.gpa, "{x:0>4}{s}", .{ b.len + 4, b });
        }
        try out.appendSlice(p.gpa, "0000");
        try p.fileBoth(name, out.items, 0o644);
    }

    /// An SSH key the source signs with, made beside the repositories, and
    /// the servers' allowed signers naming it when `known`. `false` when
    /// `ssh-keygen` is not installed.
    fn signWith(p: *Pair, name: []const u8, known: bool) !bool {
        const dir = Io.Dir.path.dirname(p.ours).?;
        const key = try p.gpa.print("{s}/{s}", .{ dir, name });
        defer p.gpa.free(key);
        var made = program.run(p.gpa, p.io, .{ .environ = &p.env }, .{ .argv = &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", key } }, .{}) catch return false;
        made.deinit(p.gpa);
        const public_path = try p.gpa.print("{s}.pub", .{key});
        defer p.gpa.free(public_path);
        const public = try Io.Dir.cwd().readFileAlloc(p.io, public_path, p.gpa, .limited(4096));
        defer p.gpa.free(public);
        const allowed = try p.gpa.print("{s}/allowed", .{dir});
        defer p.gpa.free(allowed);
        if (known) {
            const line = try p.gpa.print("{s}@example.com namespaces=\"git\" {s}", .{ name, public });
            defer p.gpa.free(line);
            try Io.Dir.cwd().writeFile(p.io, .{ .sub_path = allowed, .data = line });
        }
        try p.source.exec(p.io, &.{ "config", "gpg.format", "ssh" });
        try p.source.exec(p.io, &.{ "config", "user.signingKey", key });
        try p.gitBoth(&.{ "config", "gpg.ssh.allowedSignersFile", allowed });
        return true;
    }

    /// `git status` and `git ls-files -s` alike in git's working tree at
    /// `<theirs><suffix>` and relic's at `<ours><suffix>`.
    fn expectSameWorktrees(p: *Pair, suffix: []const u8) !void {
        var said: [2][2][]u8 = undefined;
        for ([_][]const u8{ p.theirs, p.ours }, 0..) |target, i| {
            const path = try p.gpa.print("{s}{s}", .{ target, suffix });
            defer p.gpa.free(path);
            var dir = try Io.Dir.cwd().openDir(p.io, path, .{});
            defer dir.close(p.io);
            said[i][0] = try testremote.gitInputEnv(p.gpa, p.io, dir, &p.env, &.{ "status", "--porcelain", "--untracked-files=all" }, "", true);
            said[i][1] = try testremote.gitInputEnv(p.gpa, p.io, dir, &p.env, &.{ "ls-files", "-s" }, "", true);
        }
        defer for (said) |pair| for (pair) |text| p.gpa.free(text);
        try testing.expectEqualStrings(said[0][0], said[1][0]);
        try testing.expectEqualStrings(said[0][1], said[1][1]);
    }

    /// The same git command in both working trees at `<target><suffix>`.
    fn gitBothAt(p: *Pair, suffix: []const u8, args: []const []const u8) !void {
        for ([_][]const u8{ p.theirs, p.ours }) |target| {
            const path = try p.gpa.print("{s}{s}", .{ target, suffix });
            defer p.gpa.free(path);
            var dir = try Io.Dir.cwd().openDir(p.io, path, .{});
            defer dir.close(p.io);
            try p.git(dir, args);
        }
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

test "a push's refs go in two transactions that refuse a ref alone, as git 2.55 batches them" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_][]const u8{ "files", "reftable" }) |format| {
        var p = try Pair.initFormat(gpa, io, true, format, &.{});
        defer p.deinit();
        try p.both(&.{ "main:refs/heads/main", "main~1:refs/heads/x", "main~1:refs/heads/race", "main:refs/heads/gone", "main:refs/heads/lp", "main:refs/heads/pp", "main:refs/heads/lc/d", "main:refs/heads/pc/d", "main:refs/heads/g1", "main:refs/heads/g2" });
        // Some in packed-refs, some loose, which the files backend checks
        // apart.
        try p.gitBoth(&.{ "pack-refs", "--include", "refs/heads/p*" });
        // Names in conflict with refs there, loose and packed, above and
        // below, and with each other, in both orders, beside refs that go
        // ahead; the deletion first, so a directory can take its place.
        try p.both(&.{ "main~1:refs/heads/main/sub", "main~2:refs/heads/ok", "main:refs/heads/n", "main:refs/heads/n/m", ":refs/heads/x", "main:refs/heads/x/y", "main:refs/heads/lp/x", "main:refs/heads/pp/x", "main:refs/heads/lc", "main:refs/heads/pc", "main:refs/heads/z/a", "main:refs/heads/z", "main:refs/heads/z/b" });
        // Refs moved behind the push's back by a hook: an old value gone,
        // a ref made that the push creates, and, in the deletions' own
        // transaction, one deleted that the push deletes.
        try p.markBoth("meddle", true, true);
        try p.both(&.{ "main:refs/heads/race", "main:refs/heads/made", "main~2:refs/heads/meddle", "main:refs/heads/after" });
        try p.gitBoth(&.{ "update-ref", "refs/heads/gone", "main" });
        try p.both(&.{ ":refs/heads/meddle", ":refs/heads/gone" });
        try p.markBoth("meddle", false, true);
    }
}

test "a proc-receive hook takes the refs it is given, and says what it made of them, as git 2.55 hears it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{
        .{ "receive.advertisePushOptions", "true" },
        .{ "receive.procReceiveRefs", "refs/for/" },
    });
    defer p.deinit();
    try p.fileBoth("hooks/proc-receive", proc_receive_hook, 0o755);
    try p.both(&.{ "main~1:refs/heads/main", "v1" });
    // The hook's own answer: ok for each, its refs untouched here.
    try p.both(&.{ "main:refs/for/main", "main:refs/heads/beside", "main:refs/for/main/topic" });
    // What it made of them: another ref, its old and new values, forced,
    // several for one; in report-status-v2 and the hooks after.
    try p.procSays("proc-receive.report", &.{ "ok refs/for/main", "option refname refs/heads/main", "option old-oid {old}", "option new-oid {new}", "ok refs/for/next", "option refname refs/heads/next", "option new-oid {new}", "option forced-update", "ok refs/for/next", "option refname refs/heads/next2" });
    try p.both(&.{ "main:refs/for/main", "main:refs/for/next", "main:refs/heads/plain" });
    // Refusals, with and without a reason, and a ref it does not answer for.
    try p.procSays("proc-receive.report", &.{ "ng refs/for/main not today", "ng refs/for/next" });
    try p.both(&.{ "main:refs/for/main", "main:refs/for/next", "main:refs/for/third" });
    // fall-through: receive-pack updates it after all.
    try p.procSays("proc-receive.report", &.{ "ok refs/for/main", "option fall-through", "ok refs/for/next" });
    try p.both(&.{ "main:refs/for/main", "main:refs/for/next" });
    // What breaks its protocol: an unknown ref, one it was not given, a bad
    // status, a line with no ref, an option with no ok before it.
    try p.procSays("proc-receive.report", &.{ "option refname refs/heads/x", "ok refs/heads/nowhere", "ok refs/heads/main", "option refname refs/heads/y", "bad refs/for/main", "ok", "ok refs/for/main" });
    try p.both(&.{ "main:refs/for/main", "main~1:refs/heads/main" });
    // Answering nothing; exiting with a failure after answering; a version
    // it cannot speak; gone before it is asked anything.
    try p.procSays("proc-receive.report", &.{});
    try p.both(&.{ "main:refs/for/main", "main:refs/heads/after-nothing" });
    try p.procSays("proc-receive.report", null);
    try p.fileBoth("proc-receive.exit", "1\n", 0o644);
    try p.both(&.{ "main:refs/for/main", "main:refs/heads/after-exit" });
    try p.both(&.{ "--atomic", "main:refs/for/main", "main:refs/heads/atomic-exit" });
    try p.fileBoth("proc-receive.exit", null, 0o644);
    try p.procSays("proc-receive.version", &.{"version=2"});
    try p.both(&.{ "main:refs/for/main", "main:refs/heads/after-v2" });
    try p.procSays("proc-receive.version", null);
    try p.fileBoth("proc-receive.gone", "", 0o644);
    try p.both(&.{ "main:refs/for/main", "main:refs/heads/after-gone" });
    try p.fileBoth("proc-receive.gone", null, 0o644);
    // Push options, which it asks for; atomic, which it is told of, where
    // its refusal refuses the rest.
    try p.procSays("proc-receive.version", &.{"version=1\x00push-options"});
    try p.both(&.{ "-o", "first", "-o", "second", "main:refs/for/main" });
    try p.both(&.{ "--atomic", "main:refs/for/main", "main:refs/heads/atomic-ok" });
    try p.procSays("proc-receive.report", &.{"ng refs/for/main no"});
    try p.both(&.{ "--atomic", "main:refs/for/main", "main:refs/heads/atomic-no" });
}

test "receive.procReceiveRefs takes creations, deletions or other updates, and refs outside a prefix, as git matches them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{.{ "receive.procReceiveRefs", "a:refs/review" }});
    defer p.deinit();
    try p.gitBoth(&.{ "config", "--add", "receive.procReceiveRefs", "dm!:refs/heads/" });
    try p.gitBoth(&.{ "config", "--add", "receive.procReceiveRefs", "!:refs/never" });
    try p.fileBoth("hooks/proc-receive", proc_receive_hook, 0o755);
    try p.both(&.{ "main~1:refs/heads/main", "v1", "main:refs/reviewed/x" });
    try p.gitBoth(&.{ "update-ref", "refs/review/x", "main~1" });
    // A creation under refs/review, an update there, an update under
    // refs/heads and one outside it, and a tag's deletion.
    try p.both(&.{ "main:refs/review/new", "main:refs/review/x", "main:refs/heads/main", "+main~1:refs/reviewed/x", ":refs/tags/v1" });
}

test "a signed push's certificate is checked and handed to the receive hooks, as git 2.55 hands it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{
        .{ "receive.certNonceSeed", "a seed" },
        .{ "receive.advertisePushOptions", "true" },
    });
    defer p.deinit();
    if (!try p.signWith("signer", true)) return error.SkipZigTest;
    try p.both(&.{ "--signed", "main~1:refs/heads/main", "v1" });
    // Push options, which the certificate carries too; a deletion; a push
    // signed only because the server asks.
    try p.both(&.{ "--signed", "-o", "first", "-o", "second", "main:refs/heads/main", ":refs/tags/v1" });
    try p.both(&.{ "--signed=if-asked", "main:refs/heads/asked" });
    // A key the allowed signers do not name.
    if (!try p.signWith("stranger", false)) return error.SkipZigTest;
    try p.both(&.{ "--signed", "main~1:refs/heads/stranger" });
}

test "a server that asks for no certificate takes an unsigned push, and git refuses to send a signed one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{});
    defer p.deinit();
    if (!try p.signWith("signer", true)) return error.SkipZigTest;
    try p.both(&.{ "--signed=if-asked", "main:refs/heads/main" });
    try p.both(&.{ "--signed", "main:refs/heads/signed" });
}

test "denyCurrentBranch=updateInstead brings the working tree along with its branch, or refuses as git does, push-to-checkout deciding when there is one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, false, &.{.{ "receive.denyCurrentBranch", "updateInstead" }});
    defer p.deinit();
    // The branch unborn: its files appear.
    try p.both(&.{"main~2:refs/heads/main"});
    try p.expectSameWorktrees("");
    // A change not staged, then a staged one, then an untracked file where
    // the push puts one: each refused, the working tree left.
    try p.fileBoth("src/a.txt", "changed\n", 0o644);
    try p.both(&.{"main~1:refs/heads/main"});
    try p.expectSameWorktrees("");
    try p.gitBothAt("", &.{ "add", "src/a.txt" });
    try p.both(&.{"main~1:refs/heads/main"});
    try p.expectSameWorktrees("");
    try p.gitBothAt("", &.{ "reset", "-q", "--hard" });
    try p.fileBoth("files/1.txt", "in the way\n", 0o644);
    try p.both(&.{"main~1:refs/heads/main"});
    try p.expectSameWorktrees("");
    try p.fileBoth("files/1.txt", null, 0o644);
    // Clean: the branch and the working tree move together.
    try p.both(&.{"main~1:refs/heads/main"});
    try p.expectSameWorktrees("");
    // A push-to-checkout hook decides in place of all that.
    try p.fileBoth(".git/hooks/push-to-checkout",
        \\#!/bin/sh
        \\echo "push-to-checkout $1 ${GIT_DIR:+git-dir} ${GIT_WORK_TREE:+work-tree}" >>hook.log
        \\test ! -e decline-checkout || exit 1
        \\exec git read-tree -u -m HEAD "$1"
        \\
    , 0o755);
    try p.markBoth("decline-checkout", true, false);
    try p.both(&.{"main:refs/heads/main"});
    try p.markBoth("decline-checkout", false, false);
    try p.both(&.{"main:refs/heads/main"});
    try p.expectSameWorktrees("");
    try p.fileBoth(".git/hooks/push-to-checkout", null, 0o644);
    // A linked working tree with the branch: it is the one brought along;
    // and deleting a checked-out branch is still refused.
    for ([_][]const u8{ p.theirs, p.ours }) |target| {
        var dir = try Io.Dir.cwd().openDir(io, target, .{});
        defer dir.close(io);
        const linked = try gpa.print("{s}-linked", .{target});
        defer gpa.free(linked);
        try p.git(dir, &.{ "worktree", "add", "-q", "-b", "side", linked, "HEAD~2" });
    }
    try p.both(&.{"main:refs/heads/side"});
    try p.expectSameWorktrees("-linked");
    try p.both(&.{":refs/heads/side"});
}

test "a pack below receive.unpackLimit is stored loose and one at it kept, as git's unpack-objects and index-pack store them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{.{ "receive.unpackLimit", "10" }});
    defer p.deinit();
    // Two commits' objects, more than ten: kept as a pack.
    try p.both(&.{"main~1:refs/heads/main"});
    // One commit's eight: loose.
    try p.both(&.{"main:refs/heads/main"});
    // transfer.unpackLimit when receive.unpackLimit is unset.
    try p.gitBoth(&.{ "config", "--unset", "receive.unpackLimit" });
    try p.gitBoth(&.{ "config", "transfer.unpackLimit", "1" });
    try testremote.addCommits(gpa, io, &p.source, 3, 1);
    try p.both(&.{"main:refs/heads/main"});
}

test "a push kept waiting hears a keepalive every receive.keepAlive seconds, as git's receive-pack sends them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{.{ "receive.keepAlive", "1" }});
    defer p.deinit();
    try p.markBoth("slow", true, true);
    // A push with a pack, and one that only deletes: a pre-receive of three
    // seconds is two keepalives at least, from either server.
    for ([_][]const []const u8{ &.{"main:refs/heads/other"}, &.{":refs/heads/other"} }) |args| {
        try testing.expect(try p.keepalives(p.theirs, false, args) >= 2);
        try testing.expect(try p.keepalives(p.ours, true, args) >= 2);
    }
    // None at all when it is zero.
    try p.gitBoth(&.{ "config", "receive.keepAlive", "0" });
    try testing.expectEqual(@as(usize, 0), try p.keepalives(p.theirs, false, &.{"main:refs/heads/again"}));
    try testing.expectEqual(@as(usize, 0), try p.keepalives(p.ours, true, &.{"main:refs/heads/again2"}));
}

test "receive.updateServerInfo writes the dumb HTTP files after a push, as git's receive-pack does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{ .{ "receive.updateServerInfo", "true" }, .{ "receive.unpackLimit", "1" } });
    defer p.deinit();
    try p.both(&.{ "main~1:refs/heads/main", "v1" });
    try p.both(&.{ "main:refs/heads/main", "main:refs/heads/side" });
    var files: [2][2][]u8 = undefined;
    for ([_][]const u8{ p.theirs, p.ours }, 0..) |target, i| {
        var dir = try Io.Dir.cwd().openDir(io, target, .{});
        defer dir.close(io);
        files[i][0] = try dir.readFileAlloc(io, "info/refs", gpa, .unlimited);
        files[i][1] = try dir.readFileAlloc(io, "objects/info/packs", gpa, .unlimited);
    }
    defer for (files) |pair| for (pair) |text| gpa.free(text);
    try testing.expectEqualStrings(files[0][0], files[1][0]);
    // The same packs, by number: their names are each repository's own.
    try testing.expectEqual(std.mem.count(u8, files[0][1], "P pack-"), std.mem.count(u8, files[1][1], "P pack-"));
    try testing.expect(std.mem.count(u8, files[1][1], "P pack-") >= 1);
}

test "a push updating a symbolic ref and its target is taken once, or refused when the two disagree, as git's check_aliased_updates decides" {
    const gpa = testing.allocator;
    const io = testing.io;
    var p = try Pair.init(gpa, io, true, &.{});
    defer p.deinit();
    try p.both(&.{ "main~2:refs/heads/main", "main~2:refs/heads/side" });
    try p.gitBoth(&.{ "symbolic-ref", "refs/heads/alias", "refs/heads/main" });
    // The same update through both names: once.
    try p.both(&.{ "main~1:refs/heads/main", "main~1:refs/heads/alias" });
    // Two updates that disagree: both refused, the rest taken.
    try p.both(&.{ "main:refs/heads/main", "main~2:refs/heads/alias", "main:refs/heads/side" });
    // The symbolic ref alone moves its target.
    try p.both(&.{"main:refs/heads/alias"});
    // A symbolic ref that leads round in a circle, which fsck would
    // refuse: the two pushes alone are compared, and it goes after.
    try p.gitBoth(&.{ "symbolic-ref", "refs/heads/loop-a", "refs/heads/loop-b" });
    try p.gitBoth(&.{ "symbolic-ref", "refs/heads/loop-b", "refs/heads/loop-a" });
    const args = [_][]const u8{ "main:refs/heads/loop-a", "main~1:refs/heads/side" };
    const theirs = try p.push(p.theirs, false, &args);
    defer gpa.free(theirs.report);
    defer gpa.free(theirs.remote_lines);
    const ours = try p.push(p.ours, true, &args);
    defer gpa.free(ours.report);
    defer gpa.free(ours.remote_lines);
    try testing.expectEqualStrings(theirs.report, ours.report);
    try testing.expectEqualStrings(theirs.remote_lines, ours.remote_lines);
    try p.gitBoth(&.{ "update-ref", "--no-deref", "-d", "refs/heads/loop-a" });
    try p.gitBoth(&.{ "update-ref", "--no-deref", "-d", "refs/heads/loop-b" });
    try p.expectSame();
}

test "a push to a repository on this machine and a fetch back cross as they are written, and whole where no second task runs" {
    const gpa = testing.allocator;
    // A file far larger than the pipes between the two sides, which does
    // not compress.
    const noise = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(noise);
    var state: u64 = 0x2545f4914f6cdd1d;
    for (noise) |*b| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        b.* = @truncate(state);
    }
    for ([_]bool{ true, false }) |beside| {
        var threaded: Io.Threaded = .init(gpa, .{ .concurrent_limit = if (beside) .unlimited else .nothing });
        defer threaded.deinit();
        const io = threaded.io();
        var source = try testgit.Repo.init(gpa, io, &.{});
        defer source.deinit();
        try source.writeFile(io, "noise.bin", noise);
        try source.exec(io, &.{ "add", "noise.bin" });
        try source.exec(io, &.{ "commit", "-qm", "noise" });
        // No hooks: where no second task runs, none could.
        var target = try testgit.Repo.init(gpa, io, &.{"--bare"});
        defer target.deinit();
        const target_path = try target.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(target_path);
        var repo = try repo_mod.Repository.open(gpa, io, source.dir, .{});
        defer repo.deinit(io);
        const who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
        var pushed = try push_mod.push(gpa, io, &repo, target_path, .{ .who = who, .refspecs = &.{"HEAD:refs/heads/main"} });
        defer pushed.deinit();
        try testing.expectEqual(push_mod.RefResult.Status.ok, pushed.refs[0].status);
        try target.exec(io, &.{ "fsck", "--strict" });
        // And back, into a repository that has none of it.
        var empty = try testgit.Repo.init(gpa, io, &.{});
        defer empty.deinit();
        var back = try repo_mod.Repository.open(gpa, io, empty.dir, .{});
        defer back.deinit(io);
        var fetched = try fetch_mod.fetch(gpa, io, &back, target_path, .{ .refspecs = &.{"refs/heads/main:refs/heads/fetched"}, .who = who });
        defer fetched.deinit();
        const sent = try source.line(io, &.{ "rev-parse", "HEAD:noise.bin" });
        defer gpa.free(sent);
        const got = try empty.line(io, &.{ "rev-parse", "fetched:noise.bin" });
        defer gpa.free(got);
        try testing.expectEqualStrings(sent, got);
    }
}
