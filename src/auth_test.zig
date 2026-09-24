//! Authentication as a person meets it: the helpers their installers and
//! tools configured, the ssh they already use, and what they are told when
//! it does not work.
//!
//! Each test builds a stand-in person — a home, a system configuration
//! file, and the environment their terminal would hand a program — and has
//! git and relic reach the same remote from it. What git asked each helper
//! and what relic asked it are compared byte for byte, and what relic
//! reports on a refusal is held to what git printed. A helper named after a
//! real one — `osxkeychain`, `manager` — is a stand-in found on a private
//! `GIT_EXEC_PATH`, checked to be the stand-in before anything is asked of
//! it; `store` and `cache` are git's own, pointed at files and sockets the
//! test owns. Nothing reaches the person's own keychain, agent or files.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const testing = std.testing;

const auth = @import("auth.zig");
const credential = @import("credential.zig");
const fetch_mod = @import("fetch.zig");
const program = @import("program.zig");
const repo_mod = @import("repo.zig");
const transport = @import("transport.zig");
const userconfig = @import("userconfig.zig");
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const test_who: @import("object.zig").Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// A person, as far as git can tell: a home with a `~/.gitconfig`, a system
/// file where their git was built to look, and their environment.
const Person = struct {
    gpa: Allocator,
    home: testing.TmpDir,
    tools: testing.TmpDir,
    home_path: []u8,
    tools_path: []u8,
    env: Environ.Map,

    fn init(gpa: Allocator, io: Io) !Person {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        try testgit.requireGit(gpa, io);
        var home = testing.tmpDir(.{ .iterate = true });
        errdefer home.cleanup();
        var tools = testing.tmpDir(.{ .iterate = true });
        errdefer tools.cleanup();
        const home_path = try testremote.absolutePath(gpa, io, home.dir);
        errdefer gpa.free(home_path);
        const tools_path = try testremote.absolutePath(gpa, io, tools.dir);
        errdefer gpa.free(tools_path);
        var env = try testremote.environ(gpa);
        errdefer env.deinit();
        try testgit.isolate(&env, home_path);
        // The person's git reads its system file and their `~/.gitconfig`,
        // which here are the test's.
        _ = env.swapRemove("GIT_CONFIG_NOSYSTEM");
        _ = env.swapRemove("GIT_CONFIG_GLOBAL");
        const system = try std.fs.path.join(gpa, &.{ home_path, "system-gitconfig" });
        defer gpa.free(system);
        try env.put("GIT_CONFIG_SYSTEM", system);
        try home.dir.writeFile(io, .{ .sub_path = "system-gitconfig", .data = "" });
        return .{ .gpa = gpa, .home = home, .tools = tools, .home_path = home_path, .tools_path = tools_path, .env = env };
    }

    fn deinit(p: *Person) void {
        p.env.deinit();
        p.gpa.free(p.home_path);
        p.gpa.free(p.tools_path);
        p.home.cleanup();
        p.tools.cleanup();
    }

    fn writeSystem(p: *Person, io: Io, text: []const u8) !void {
        try p.home.dir.writeFile(io, .{ .sub_path = "system-gitconfig", .data = text });
    }

    fn writeGlobal(p: *Person, io: Io, text: []const u8) !void {
        try p.home.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = text });
    }

    /// A helper at `<tools>/<name>` that writes what it is asked to
    /// `<name>.log` and answers `get` with `<name>.answer`. The path is
    /// the caller's.
    fn standIn(p: *Person, io: Io, name: []const u8, answer: []const u8) ![]u8 {
        const script = try std.fmt.allocPrint(p.gpa,
            \\#!/bin/sh
            \\for op; do :; done
            \\[ "$op" = relic-probe ] && {{ echo stand-in; exit 0; }}
            \\echo "== $op" >> "{s}/{s}.log"
            \\while IFS= read -r line; do echo "$line" >> "{s}/{s}.log"; done
            \\if [ "$op" = get ]; then cat "{s}/{s}.answer"; fi
            \\
        , .{ p.tools_path, name, p.tools_path, name, p.tools_path, name });
        defer p.gpa.free(script);
        try p.tools.dir.writeFile(io, .{ .sub_path = name, .data = script });
        var answer_name: [64]u8 = undefined;
        try p.tools.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&answer_name, "{s}.answer", .{name}), .data = answer });
        const file = try p.tools.dir.openFile(io, name, .{});
        defer file.close(io);
        if (builtin.os.tag != .windows) try file.setPermissions(io, .fromMode(0o755));
        return std.fs.path.join(p.gpa, &.{ p.tools_path, name });
    }

    /// A private `GIT_EXEC_PATH`: every program of the real one, with
    /// `git-credential-<name>` for each of `names` replaced by a stand-in.
    /// Each is checked to be the stand-in before any test asks it anything,
    /// so the person's real keychain is never reached.
    fn shadowHelpers(p: *Person, io: Io, names: []const []const u8, answers: []const []const u8) !void {
        var outcome = try program.run(.{ .environ = &p.env }, p.gpa, io, .{ .argv = &.{ "git", "--exec-path" } }, "", .{});
        defer outcome.deinit(p.gpa);
        if (!outcome.succeeded()) return error.SkipZigTest;
        const real = std.mem.trimEnd(u8, outcome.stdout, "\r\n");
        try p.tools.dir.createDirPath(io, "exec");
        var shadow = try p.tools.dir.openDir(io, "exec", .{});
        defer shadow.close(io);
        var real_dir = try Io.Dir.cwd().openDir(io, real, .{ .iterate = true });
        defer real_dir.close(io);
        var it = real_dir.iterate();
        while (try it.next(io)) |entry| {
            const target = try std.fs.path.join(p.gpa, &.{ real, entry.name });
            defer p.gpa.free(target);
            try shadow.symLink(io, target, entry.name, .{});
        }
        for (names, answers) |name, answer| {
            const path = try p.standIn(io, name, answer);
            defer p.gpa.free(path);
            var dashed_buf: [64]u8 = undefined;
            const dashed = try std.fmt.bufPrint(&dashed_buf, "git-credential-{s}", .{name});
            shadow.deleteFile(io, dashed) catch {};
            try shadow.symLink(io, path, dashed, .{});
        }
        const exec_path = try std.fs.path.join(p.gpa, &.{ p.tools_path, "exec" });
        defer p.gpa.free(exec_path);
        try p.env.put("GIT_EXEC_PATH", exec_path);
        for (names) |name| {
            var dashed_buf: [64]u8 = undefined;
            const dashed = try std.fmt.bufPrint(&dashed_buf, "credential-{s}", .{name});
            var probe = try program.run(.{ .environ = &p.env }, p.gpa, io, .{ .argv = &.{ "git", dashed, "relic-probe" } }, "", .{});
            defer probe.deinit(p.gpa);
            if (!std.mem.eql(u8, probe.stdout, "stand-in\n")) {
                std.debug.print("git {s} is not the stand-in; stopping before it is asked anything\n", .{dashed});
                return error.TestUnexpectedResult;
            }
        }
    }

    /// What `name` was asked since the last `clearLogs`.
    fn log(p: *Person, io: Io, name: []const u8) ![]u8 {
        var buf: [64]u8 = undefined;
        return p.tools.dir.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}.log", .{name}), p.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => p.gpa.dupe(u8, ""),
            else => err,
        };
    }

    fn clearLogs(p: *Person, io: Io, names: []const []const u8) void {
        for (names) |name| {
            var buf: [64]u8 = undefined;
            p.tools.dir.deleteFile(io, std.fmt.bufPrint(&buf, "{s}.log", .{name}) catch unreachable) catch {};
        }
    }

    /// Run git as this person, in `dir`: its outcome, with what it said on
    /// its standard error.
    fn git(p: *Person, io: Io, dir: Io.Dir, args: []const []const u8) !program.Outcome {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(p.gpa);
        try argv.append(p.gpa, "git");
        try argv.appendSlice(p.gpa, &testgit.default_settings);
        try argv.appendSlice(p.gpa, args);
        return program.run(.{ .environ = &p.env }, p.gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = dir } }, "", .{});
    }

    /// Open `dir` as this person's repository, with the configuration
    /// their git would read: what `userconfig.locate` finds.
    fn open(p: *Person, io: Io, dir: Io.Dir, locations: *userconfig.Locations) !repo_mod.Repository {
        locations.* = try userconfig.locate(p.gpa, io, &p.env, .{ .environ = &p.env });
        const sources = locations.sources();
        return repo_mod.Repository.open(p.gpa, io, dir, .{
            .system_config = sources.system,
            .xdg_config = sources.xdg,
            .global_config = sources.global,
            .home = locations.home,
            .config_pairs = locations.pairs,
        });
    }
};

/// A bare repository at `<root>/<name>` for the server, with one commit.
fn served(gpa: Allocator, io: Io, root: *testing.TmpDir, name: []const u8) !void {
    var source = try testremote.historyRepo(gpa, io, 1);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const bare = try std.fs.path.join(gpa, &.{ root_path, name });
    defer gpa.free(bare);
    try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
}

/// The lines of git's standard error that the server sent, `remote: `
/// taken off, as one text.
fn remoteLines(gpa: Allocator, stderr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const prefix = "remote: ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (out.items.len != 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, std.mem.trimEnd(u8, line[prefix.len..], " \r"));
    }
    return out.toOwnedSlice(gpa);
}

test "with only the person's environment, relic asks the helpers git asks: gh's reset for its host, the system keychain elsewhere" {
    const gpa = testing.allocator;
    const io = testing.io;
    var person = try Person.init(gpa, io);
    defer person.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, &root, "mine.git");
    try served(gpa, io, &root, "other.git");
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" } });
    defer server.stop();

    // Homebrew's system file names the keychain; `gh auth setup-git`
    // writes a reset and itself for its host, here one repository.
    try person.shadowHelpers(io, &.{"osxkeychain"}, &.{""});
    const gh = try person.standIn(io, "gh", "username=ada\npassword=secret\n");
    defer gpa.free(gh);
    try person.writeSystem(io, "[credential]\n\thelper = osxkeychain\n");
    const global = try std.fmt.allocPrint(gpa,
        \\[credential "http://127.0.0.1:{d}/mine.git"]
        \\    helper =
        \\    helper = !{s} auth git-credential
        \\
    , .{ server.port, gh });
    defer gpa.free(global);
    try person.writeGlobal(io, global);
    const names = [_][]const u8{ "gh", "osxkeychain" };

    for ([_][]const u8{ "mine.git", "other.git" }) |name| {
        const url = try server.url(gpa, name);
        defer gpa.free(url);
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| try r.exec(io, &.{ "remote", "add", "origin", url });

        person.clearLogs(io, &names);
        var theirs_outcome = try person.git(io, by_git.dir, &.{ "fetch", "-q", "origin" });
        defer theirs_outcome.deinit(gpa);
        var theirs: [names.len][]u8 = undefined;
        for (names, 0..) |n, i| theirs[i] = try person.log(io, n);
        defer for (theirs) |t| gpa.free(t);

        person.clearLogs(io, &names);
        var locations: userconfig.Locations = undefined;
        var repo = try person.open(io, by_relic.dir, &locations);
        defer repo.deinit(io);
        defer locations.deinit();
        var failure: auth.Failure = .{};
        defer failure.deinit();
        const result = fetch_mod.fetch(gpa, io, &repo, "origin", .{
            .who = test_who,
            .programs = .{ .environ = &person.env },
            .auth_failure = &failure,
        });
        for (names, 0..) |n, i| {
            const ours = try person.log(io, n);
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs[i], ours);
        }

        if (std.mem.eql(u8, name, "mine.git")) {
            // gh answered; the keychain was never asked.
            try testing.expect(theirs_outcome.succeeded());
            var outcome = try result;
            outcome.deinit();
            try testing.expectEqualStrings("", theirs[1]);
            try testing.expect(std.mem.startsWith(u8, theirs[0], "== get\n"));
        } else {
            // Out of gh's scope: the keychain was asked, knew nothing, and
            // with no prompt there is nothing more — git stops at its
            // disabled terminal prompt, relic says why.
            try testing.expect(!theirs_outcome.succeeded());
            try testing.expectError(error.CredentialsUnavailable, result);
            try testing.expectEqual(auth.Failure.Reason.no_credential, failure.reason);
            try testing.expectEqual(@as(usize, 1), failure.helpers.len);
            try testing.expectEqualStrings("osxkeychain", failure.helpers[0].command);
            try testing.expectEqual(auth.Failure.Answer.nothing, failure.helpers[0].answer);
            try testing.expect(!failure.prompt_available);
            try testing.expectEqual(@as(?u16, 401), failure.status);
            try testing.expectEqualStrings(url, failure.url);
            try testing.expectEqualStrings("Basic realm=\"relic\"", failure.challenges[0]);
        }
    }
}

test "named helpers run as git runs them: Git Credential Manager, and git's own store and cache" {
    const gpa = testing.allocator;
    const io = testing.io;
    var person = try Person.init(gpa, io);
    defer person.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, &root, "repo.git");
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .basic_auth = .{ .user = "ada", .password = "secret" } });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    // `manager`, as git for Windows configures it: a stand-in, asked the
    // same things by both.
    try person.shadowHelpers(io, &.{"manager"}, &.{"username=ada\npassword=secret\n"});
    try person.writeSystem(io, "[credential]\n\thelper = manager\n");
    {
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| try r.exec(io, &.{ "remote", "add", "origin", url });
        person.clearLogs(io, &.{"manager"});
        var theirs_outcome = try person.git(io, by_git.dir, &.{ "fetch", "-q", "origin" });
        defer theirs_outcome.deinit(gpa);
        try testing.expect(theirs_outcome.succeeded());
        const theirs = try person.log(io, "manager");
        defer gpa.free(theirs);
        person.clearLogs(io, &.{"manager"});
        var locations: userconfig.Locations = undefined;
        var repo = try person.open(io, by_relic.dir, &locations);
        defer repo.deinit(io);
        defer locations.deinit();
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &person.env } });
        outcome.deinit();
        const ours = try person.log(io, "manager");
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }

    // `store`: git's own helper and file. What relic leaves in the file is
    // what git leaves, when the credential works and when it is refused.
    for ([_][]const u8{ "secret", "wrong" }) |password| {
        const line = try std.fmt.allocPrint(gpa, "http://ada:{s}@127.0.0.1:{d}\n", .{ password, server.port });
        defer gpa.free(line);
        var files: [2][]u8 = undefined;
        for (0..2) |who| {
            try person.tools.dir.writeFile(io, .{ .sub_path = "credentials", .data = line });
            const store = try std.fmt.allocPrint(gpa, "[credential]\n\thelper = store --file={s}/credentials\n", .{person.tools_path});
            defer gpa.free(store);
            try person.writeSystem(io, store);
            var r = try testgit.Repo.init(gpa, io, &.{});
            defer r.deinit();
            try r.exec(io, &.{ "remote", "add", "origin", url });
            if (who == 0) {
                var o = try person.git(io, r.dir, &.{ "fetch", "-q", "origin" });
                defer o.deinit(gpa);
                try testing.expectEqual(std.mem.eql(u8, password, "secret"), o.succeeded());
            } else {
                var locations: userconfig.Locations = undefined;
                var repo = try person.open(io, r.dir, &locations);
                defer repo.deinit(io);
                defer locations.deinit();
                if (fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &person.env } })) |fetched| {
                    var outcome = fetched;
                    outcome.deinit();
                    try testing.expectEqualStrings("secret", password);
                } else |err| {
                    try testing.expectEqual(error.AuthenticationFailed, err);
                    try testing.expectEqualStrings("wrong", password);
                }
            }
            files[who] = try person.tools.dir.readFileAlloc(io, "credentials", gpa, .unlimited);
        }
        defer for (files) |f| gpa.free(f);
        try testing.expectEqualStrings(files[0], files[1]);
    }

    // `cache`: git's daemon, on a socket of the test's. relic hands it the
    // credential the caller's prompt gave; git's own `credential fill`
    // then reads it back, and relic's next fetch needs no prompt.
    {
        // git's cache refuses a socket directory others can read.
        try person.tools.dir.createDirPath(io, "cache");
        {
            var cache_dir = try person.tools.dir.openDir(io, "cache", .{});
            defer cache_dir.close(io);
            if (builtin.os.tag != .windows) try cache_dir.setPermissions(io, .fromMode(0o700));
        }
        const socket = try std.fs.path.join(gpa, &.{ person.tools_path, "cache", "sock" });
        defer gpa.free(socket);
        const cache = try std.fmt.allocPrint(gpa, "[credential]\n\thelper = cache --socket={s}\n", .{socket});
        defer gpa.free(cache);
        try person.writeSystem(io, cache);
        const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket});
        defer gpa.free(socket_arg);
        defer {
            var o = person.git(io, person.tools.dir, &.{ "credential-cache", "exit", socket_arg }) catch null;
            if (o) |*outcome| outcome.deinit(gpa);
        }
        var r = try testgit.Repo.init(gpa, io, &.{});
        defer r.deinit();
        try r.exec(io, &.{ "remote", "add", "origin", url });
        var locations: userconfig.Locations = undefined;
        var repo = try person.open(io, r.dir, &locations);
        defer repo.deinit(io);
        defer locations.deinit();
        const Asker = struct {
            fn ask(_: ?*anyopaque, allocator: Allocator, field: credential.Field, _: []const u8) Allocator.Error!?[]u8 {
                return try allocator.dupe(u8, if (field == .username) "ada" else "secret");
            }
        };
        var first = try fetch_mod.fetch(gpa, io, &repo, "origin", .{
            .who = test_who,
            .programs = .{ .environ = &person.env },
            .prompt = .{ .ask = Asker.ask },
        });
        first.deinit();
        const question = try std.fmt.allocPrint(gpa, "url={s}\n\n", .{url});
        defer gpa.free(question);
        const filled = try testremote.gitInputEnv(gpa, io, r.dir, &person.env, &.{ "credential", "fill" }, question, true);
        defer gpa.free(filled);
        try testing.expect(std.mem.indexOf(u8, filled, "password=secret\n") != null);
        var second = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &person.env } });
        second.deinit();
    }
}

test "a refusal says what git says: the server's words, the helpers asked, the prompt there was not" {
    const gpa = testing.allocator;
    const io = testing.io;
    var person = try Person.init(gpa, io);
    defer person.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, &root, "repo.git");
    const words = "Invalid username or token.\nPassword authentication is not supported for Git operations.\n";
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{
        .basic_auth = .{ .user = "ada", .password = "secret" },
        .refusal_text = words,
    });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);

    const Case = struct { answer: []const u8, err: anyerror, reason: auth.Failure.Reason, helper: auth.Failure.Answer };
    for ([_]Case{
        .{ .answer = "username=ada\npassword=wrong\n", .err = error.AuthenticationFailed, .reason = .refused, .helper = .credential },
        .{ .answer = "quit=1\n", .err = error.CredentialHelperQuit, .reason = .helper_quit, .helper = .quit },
    }) |case| {
        const helper = try person.standIn(io, "helper", case.answer);
        defer gpa.free(helper);
        const global = try std.fmt.allocPrint(gpa, "[credential]\n\thelper = {s}\n", .{helper});
        defer gpa.free(global);
        try person.writeGlobal(io, global);
        var r = try testgit.Repo.init(gpa, io, &.{});
        defer r.deinit();
        try r.exec(io, &.{ "remote", "add", "origin", url });

        var theirs = try person.git(io, r.dir, &.{ "fetch", "-q", "origin" });
        defer theirs.deinit(gpa);
        try testing.expect(!theirs.succeeded());

        var locations: userconfig.Locations = undefined;
        var repo = try person.open(io, r.dir, &locations);
        defer repo.deinit(io);
        defer locations.deinit();
        var failure: auth.Failure = .{};
        defer failure.deinit();
        try testing.expectError(case.err, fetch_mod.fetch(gpa, io, &repo, "origin", .{
            .who = test_who,
            .programs = .{ .environ = &person.env },
            .auth_failure = &failure,
        }));
        try testing.expectEqual(case.reason, failure.reason);
        try testing.expectEqual(@import("url.zig").Scheme.http, failure.scheme);
        try testing.expectEqualStrings(url, failure.url);
        try testing.expectEqual(@as(usize, 1), failure.helpers.len);
        try testing.expectEqualStrings(helper, failure.helpers[0].command);
        try testing.expectEqual(case.helper, failure.helpers[0].answer);
        try testing.expect(!failure.prompt_available);
        try testing.expectEqual(@as(?u16, 401), failure.status);
        if (case.reason == .refused) {
            // The username refused, never the password; and the server's
            // own words, which git shows as `remote:` lines.
            try testing.expectEqualStrings("ada", failure.username.?);
            try testing.expectEqual(auth.Failure.Source.helper, failure.source);
            const shown = try remoteLines(gpa, theirs.stderr);
            defer gpa.free(shown);
            try testing.expectEqualStrings(shown, failure.server_message);
            try testing.expectEqualStrings(std.mem.trimEnd(u8, words, "\n"), failure.server_message);
        }
    }

    // A helper configured and no leave to run it: said by name, before
    // anything is sent.
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.exec(io, &.{ "remote", "add", "origin", url });
    var locations: userconfig.Locations = undefined;
    var repo = try person.open(io, r.dir, &locations);
    defer repo.deinit(io);
    defer locations.deinit();
    var failure: auth.Failure = .{};
    defer failure.deinit();
    try testing.expectError(error.ProgramsNotGranted, fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .auth_failure = &failure }));
    try testing.expectEqual(auth.Failure.Reason.programs_not_granted, failure.reason);
    try testing.expectEqual(auth.Failure.Answer.failed, failure.helpers[0].answer);
}

test "a helper's bearer token is sent as git sends it, and handed back with its state" {
    const gpa = testing.allocator;
    const io = testing.io;
    var person = try Person.init(gpa, io);
    defer person.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try served(gpa, io, &root, "repo.git");
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{
        .basic_auth = .{ .user = "nobody", .password = "unused" },
        .bearer = "TOKEN",
    });
    defer server.stop();
    const url = try server.url(gpa, "repo.git");
    defer gpa.free(url);
    const helper = try person.standIn(io, "helper",
        \\capability[]=authtype
        \\capability[]=state
        \\authtype=Bearer
        \\credential=TOKEN
        \\state[]=helper:one
        \\oauth_refresh_token=REFRESH
        \\password_expiry_utc=9999999999
        \\
    );
    defer gpa.free(helper);
    const global = try std.fmt.allocPrint(gpa, "[credential]\n\thelper = {s}\n", .{helper});
    defer gpa.free(global);
    try person.writeGlobal(io, global);

    var by_git = try testgit.Repo.init(gpa, io, &.{});
    defer by_git.deinit();
    var by_relic = try testgit.Repo.init(gpa, io, &.{});
    defer by_relic.deinit();
    for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| try r.exec(io, &.{ "remote", "add", "origin", url });
    person.clearLogs(io, &.{"helper"});
    var theirs_outcome = try person.git(io, by_git.dir, &.{ "fetch", "-q", "origin" });
    defer theirs_outcome.deinit(gpa);
    try testing.expect(theirs_outcome.succeeded());
    const theirs = try person.log(io, "helper");
    defer gpa.free(theirs);
    person.clearLogs(io, &.{"helper"});
    var locations: userconfig.Locations = undefined;
    var repo = try person.open(io, by_relic.dir, &locations);
    defer repo.deinit(io);
    defer locations.deinit();
    var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &person.env } });
    outcome.deinit();
    const ours = try person.log(io, "helper");
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
    try testing.expect(std.mem.indexOf(u8, ours, "state[]=helper:one") != null);
}

/// A stand-in `ssh` at `<tools>/ssh` that notes its arguments and the
/// agent and home it was started with, then either says `refusal` on its
/// standard error and exits 255, as ssh does, or runs the command here.
fn sshStandIn(person: *Person, io: Io, refusal: ?[]const u8) ![]u8 {
    const body = if (refusal) |text|
        try std.fmt.allocPrint(person.gpa, "echo '{s}' >&2; exit 255\n", .{text})
    else
        try person.gpa.dupe(u8,
            \\while [ $# -gt 0 ]; do
            \\  case "$1" in
            \\    -G) exit 0 ;;
            \\    -o|-p|-P|-i|-J|-F) shift 2 ;;
            \\    -*) shift ;;
            \\    *) break ;;
            \\  esac
            \\done
            \\shift
            \\PATH="$(git --exec-path):$PATH" exec sh -c "$*"
            \\
        );
    defer person.gpa.free(body);
    const script = try std.fmt.allocPrint(person.gpa,
        \\#!/bin/sh
        \\for a in "$@"; do printf '[%s]' "$a" >> "$0.log"; done
        \\echo " agent=$SSH_AUTH_SOCK home=$HOME" >> "$0.log"
        \\{s}
    , .{body});
    defer person.gpa.free(script);
    try person.tools.dir.writeFile(io, .{ .sub_path = "ssh", .data = script });
    const file = try person.tools.dir.openFile(io, "ssh", .{});
    defer file.close(io);
    if (builtin.os.tag != .windows) try file.setPermissions(io, .fromMode(0o755));
    return std.fs.path.join(person.gpa, &.{ person.tools_path, "ssh" });
}

test "ssh gets the person's host alias, agent and command line untouched, as git hands them over" {
    const gpa = testing.allocator;
    const io = testing.io;
    var person = try Person.init(gpa, io);
    defer person.deinit();
    // The person's agent, which their ssh uses and relic must pass along.
    try person.env.put("SSH_AUTH_SOCK", "/tmp/agent.person");
    const ssh = try sshStandIn(&person, io, null);
    defer gpa.free(ssh);
    var source = try testremote.historyRepo(gpa, io, 1);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);

    // A `Host work-github` alias with its `IdentityFile` and `ProxyJump`
    // lives in ~/.ssh/config, which only ssh reads: the host goes to ssh
    // as written. `GIT_SSH_COMMAND` and `core.sshCommand` are command
    // lines, their options kept.
    const scp = try std.fmt.allocPrint(gpa, "work-github:{s}", .{source_path});
    defer gpa.free(scp);
    const with_user = try std.fmt.allocPrint(gpa, "ssh://git@work-github{s}", .{source_path});
    defer gpa.free(with_user);
    const Case = struct { url: []const u8, env_command: ?[]const u8 = null, config_command: ?[]const u8 = null };
    const env_line = try std.fmt.allocPrint(gpa, "{s} -i ~/.ssh/work_ed25519 -o ProxyJump=bastion", .{ssh});
    defer gpa.free(env_line);
    const config_line = try std.fmt.allocPrint(gpa, "{s} -F ~/.ssh/config.work", .{ssh});
    defer gpa.free(config_line);
    for ([_]Case{
        .{ .url = scp, .config_command = config_line },
        .{ .url = with_user, .config_command = config_line },
        .{ .url = scp, .env_command = env_line },
    }) |case| {
        if (case.env_command) |line| try person.env.put("GIT_SSH_COMMAND", line) else _ = person.env.swapRemove("GIT_SSH_COMMAND");
        const global = if (case.config_command) |line|
            try std.fmt.allocPrint(gpa, "[core]\n\tsshCommand = {s}\n", .{line})
        else
            try gpa.dupe(u8, "");
        defer gpa.free(global);
        try person.writeGlobal(io, global);
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        defer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        defer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |r| try r.exec(io, &.{ "remote", "add", "origin", case.url });

        person.tools.dir.deleteFile(io, "ssh.log") catch {};
        var theirs_outcome = try person.git(io, by_git.dir, &.{ "fetch", "-q", "origin" });
        defer theirs_outcome.deinit(gpa);
        try testing.expect(theirs_outcome.succeeded());
        const theirs = try person.tools.dir.readFileAlloc(io, "ssh.log", gpa, .unlimited);
        defer gpa.free(theirs);
        person.tools.dir.deleteFile(io, "ssh.log") catch {};

        var locations: userconfig.Locations = undefined;
        var repo = try person.open(io, by_relic.dir, &locations);
        defer repo.deinit(io);
        defer locations.deinit();
        var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &person.env } });
        outcome.deinit();
        const ours = try person.tools.dir.readFileAlloc(io, "ssh.log", gpa, .unlimited);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        try testing.expect(std.mem.indexOf(u8, ours, "work-github]") != null);
        try testing.expect(std.mem.indexOf(u8, ours, "agent=/tmp/agent.person") != null);
    }
}

test "ssh's refusal of a key or a host is named, with what ssh said" {
    const gpa = testing.allocator;
    const io = testing.io;
    var person = try Person.init(gpa, io);
    defer person.deinit();
    const Case = struct { said: []const u8, err: anyerror, reason: auth.Failure.Reason };
    for ([_]Case{
        .{ .said = "git@work-github: Permission denied (publickey).", .err = error.AuthenticationFailed, .reason = .refused },
        .{ .said = "Host key verification failed.", .err = error.HostKeyVerificationFailed, .reason = .host_key },
    }) |case| {
        const ssh = try sshStandIn(&person, io, case.said);
        defer gpa.free(ssh);
        try person.env.put("GIT_SSH_COMMAND", ssh);
        var r = try testgit.Repo.init(gpa, io, &.{});
        defer r.deinit();
        try r.exec(io, &.{ "remote", "add", "origin", "git@work-github:org/repo.git" });

        var theirs = try person.git(io, r.dir, &.{ "fetch", "-q", "origin" });
        defer theirs.deinit(gpa);
        try testing.expect(!theirs.succeeded());
        // git passes ssh's words through to the person.
        try testing.expect(std.mem.indexOf(u8, theirs.stderr, case.said) != null);

        var locations: userconfig.Locations = undefined;
        var repo = try person.open(io, r.dir, &locations);
        defer repo.deinit(io);
        defer locations.deinit();
        var failure: auth.Failure = .{};
        defer failure.deinit();
        try testing.expectError(case.err, fetch_mod.fetch(gpa, io, &repo, "origin", .{
            .who = test_who,
            .programs = .{ .environ = &person.env },
            .auth_failure = &failure,
        }));
        try testing.expectEqual(case.reason, failure.reason);
        try testing.expectEqual(@import("url.zig").Scheme.ssh, failure.scheme);
        try testing.expectEqualStrings("work-github:org/repo.git", failure.url);
        try testing.expectEqualStrings(case.said, failure.server_message);
        try testing.expectEqualStrings("git", failure.username.?);
    }
}
