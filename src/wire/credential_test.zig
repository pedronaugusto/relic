//! A credential, filled as git's `credential.c` fills it, held to git.
//!
//! Each case is a URL, a `~/.gitconfig` of `credential.*` settings and the
//! answers two stand-in helpers give. git fills it with `git credential
//! fill` (the URL, both capabilities and the server's challenges on its
//! input, as git's HTTP transport fills one) and relic with a `Session`;
//! the helpers are the lfs test tool's `credential-person`, which logs
//! every question it is asked word for word, and the prompt is an askpass
//! stand-in that logs the prompt it was shown. What each helper was asked,
//! what the person was asked, what `git credential fill` printed and
//! whether git died must all be relic's too. Nothing is dialled and no
//! real helper or keychain is reached: the helpers are named by absolute
//! path and the home is the test's.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const suite = @import("../testing/helpers.zig");
const credential = @import("credential.zig");
const url_mod = @import("url.zig");
const config_mod = @import("../config/config.zig");
const program = @import("../process.zig").program;
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");
const testlfs = @import("../testing/lfs.zig");

const urls = [_][]const u8{
    "https://example.com/org/repo.git",
    "https://ada@example.com/org/repo.git",
    "https://ada:pw@example.com/r",
    "https://@example.com/r",
    "https://:pw@example.com/r",
    "http://example.com:8080//a//b//",
    "https://EXAMPLE.com:443/r?x=1#f",
    "https://a%40b@example.com/%41%2fx",
    "https://[::1]:8443/r",
    "https://example.com",
    "https://ex%41mple.com/r",
    "https://example.com/r%00x",
    "https://u%3Ax@example.com/p%20q/",
    "https://git.example.com/team/repo",
    "https://example.com%0d/",
    "https://u%0d@example.com/",
};

/// `credential.<pattern>`: patterns git normalizes, and partial ones it
/// does not, against the URLs above.
const patterns = [_][]const u8{
    "https://example.com",           "https://*.com",             "https://example.com/org", "http://example.com:8080",
    "example.com",                   "example.com/org/repo.git",  "ada@example.com",         "https://ada@example.com",
    "https://",                      "https://example.com:443/r", "[::1]:8443",              "git.example.com",
    "https://git.example.com/team/", "EXAMPLE.com",               "example.com:8080",        "https://example.com/org/repo.git/",
    "/r",                            "u@",                        "https://*.example.com",   "https://[::1]:8443",
    "example.com/r",                 "https://ada@",              "http://",                 "a@b@example.com",
};

/// What a setting may be set to.
const settings = [_]struct { name: []const u8, values: []const ?[]const u8 }{
    .{ .name = "username", .values = &.{ "bob", "" } },
    .{ .name = "useHttpPath", .values = &.{ "true", "false", "maybe", null } },
    .{ .name = "sanitizePrompt", .values = &.{ "false", "true" } },
    .{ .name = "protectProtocol", .values = &.{ "false", "true" } },
    .{ .name = "interactive", .values = &.{ "never", "false", "true", "auto" } },
};

/// Lines a helper may answer with.
const answers = [_][]const u8{
    "username=ada",                   "username=",               "password=secret",       "password=",
    "quit=1",                         "quit=0",                  "quit=maybe",            "password_expiry_utc=1000",
    "password_expiry_utc=4102444800", "password_expiry_utc=0",   "password_expiry_utc=x", "password_expiry_utc=-1",
    "capability[]=authtype",          "capability[]=state",      "authtype=Bearer",       "credential=tok",
    "state[]=s1",                     "continue=1",              "ephemeral=1",           "ephemeral=nope",
    "protocol=http",                  "host=other.example",      "path=elsewhere",        "url=https://u:p@other.example/x",
    "url=nope",                       "wwwauth[]=Basic realm=x", "oauth_refresh_token=r", "broken line",
    "",                               "password=p\r",            "username=a\rb",         "url=https://other.example",
};

test "random credentials are filled as git fills them: what the helpers and the person are asked, what fill prints, where it dies" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Capabilities and state are git 2.46's.
    try testgit.requireGitVersion(gpa, io, 2, 46);
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();
    var prng: std.Random.DefaultPrng = .init(0xc4ed_0300);
    const random = prng.random();
    for (0..testgit.corpusCases(300)) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const url = urls[random.uintLessThan(usize, urls.len)];
        var config: std.ArrayList(u8) = .empty;
        if (random.uintLessThan(u8, 10) < 7) try config.print(arena, "[credential]\n\thelper = \"{s}\"\n", .{fx.helpers[0]});
        for (0..random.uintLessThan(usize, 5)) |_| {
            if (random.boolean()) {
                try config.appendSlice(arena, "[credential]\n");
            } else try config.print(arena, "[credential \"{s}\"]\n", .{patterns[random.uintLessThan(usize, patterns.len)]});
            if (random.uintLessThan(u8, 3) == 0) {
                const which = random.uintLessThan(usize, 3);
                if (which == 2) try config.appendSlice(arena, "\thelper =\n") else try config.print(arena, "\thelper = \"{s}\"\n", .{fx.helpers[which]});
            } else {
                const setting = settings[random.uintLessThan(usize, settings.len)];
                const value = setting.values[random.uintLessThan(usize, setting.values.len)];
                if (value) |v| try config.print(arena, "\t{s} = {s}\n", .{ setting.name, v }) else try config.print(arena, "\t{s}\n", .{setting.name});
            }
        }
        var replies: [2][]const u8 = undefined;
        for (&replies) |*reply| {
            var text: std.ArrayList(u8) = .empty;
            for (0..random.uintLessThan(usize, 5)) |_| try text.print(arena, "{s}\n", .{answers[random.uintLessThan(usize, answers.len)]});
            reply.* = text.items;
        }
        const challenges: []const []const u8 = if (random.boolean()) &.{} else &.{ "Basic realm=\"x\"", "Bearer" };
        try fx.expectAsGit(arena, io, .{ .url = url, .config = config.items, .replies = replies, .challenges = challenges });
    }
}

test "listed credentials are filled as git fills them" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 46);
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = fx.helpers[0];
    const b = fx.helpers[1];
    const Listed = struct { url: []const u8, config: []const u8, replies: [2][]const u8 = .{ "", "" } };
    for ([_]Listed{
        // The first helper with a whole credential ends the search.
        .{ .url = "https://example.com/r", .config = try arena.print("[credential]\n\thelper = {s}\n\thelper = {s}\n", .{ a, b }), .replies = .{ "username=ada\npassword=one\n", "username=bob\npassword=two\n" } },
        // A username from one helper and a password from the next.
        .{ .url = "https://example.com/r", .config = try arena.print("[credential]\n\thelper = {s}\n\thelper = {s}\n", .{ a, b }), .replies = .{ "username=ada\n", "password=two\n" } },
        // Partial patterns, and the path kept for the helpers.
        .{ .url = "https://ada@example.com/org/r.git/", .config = try arena.print("[credential \"example.com/org/r.git\"]\n\thelper = {s}\n\tuseHttpPath = true\n[credential \"bob@example.com\"]\n\thelper = {s}\n", .{ a, b }), .replies = .{ "password=x\n", "" } },
        // A helper's url= starts over, with no helper left.
        .{ .url = "https://example.com/r", .config = try arena.print("[credential]\n\thelper = {s}\n\thelper = {s}\n", .{ a, b }), .replies = .{ "url=https://zed@other.example/p/\n", "password=two\n" } },
        // An expired password, then a fresh one; a token with its state.
        .{ .url = "https://example.com/r", .config = try arena.print("[credential]\n\thelper = {s}\n\thelper = {s}\n", .{ a, b }), .replies = .{ "username=ada\npassword=old\npassword_expiry_utc=1000\n", "capability[]=authtype\ncapability[]=state\nauthtype=Bearer\ncredential=tok\nstate[]=k=v\ncontinue=1\nephemeral=1\n" } },
        // credential.username for a URL without one, and the prompt for
        // the password, sanitized and not.
        .{ .url = "https://example.com/a%20b", .config = "[credential]\n\tusername = b o/b\n" },
        .{ .url = "https://example.com/a%20b", .config = "[credential]\n\tusername = b o/b\n\tsanitizePrompt = false\n\tuseHttpPath = 1\n" },
        // Prompts turned off.
        .{ .url = "https://example.com/r", .config = "[credential]\n\tinteractive = never\n" },
        .{ .url = "https://example.com/r", .config = "[credential \"https://example.com\"]\n\tinteractive = false\n" },
    }) |case| try fx.expectAsGit(arena, io, .{ .url = case.url, .config = case.config, .replies = case.replies, .challenges = &.{} });
}

/// A home, two helpers and an askpass, each a copy of the lfs test tool.
const Fixture = struct {
    gpa: Allocator,
    tmp: testing.TmpDir,
    home: []u8,
    env: std.process.Environ.Map,
    helpers: [2][]u8,
    askpass: []u8,

    fn init(gpa: Allocator, io: Io) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const home = try testremote.absolutePath(gpa, io, tmp.dir);
        errdefer gpa.free(home);
        var env = try testgit.isolatedEnviron(gpa, home);
        errdefer env.deinit();
        var helpers: [2][]u8 = undefined;
        for (&helpers, [_][]const u8{ "first", "second" }) |*path, name| path.* = try standIn(gpa, io, tmp.dir, name, "credential-person");
        const askpass = try standIn(gpa, io, tmp.dir, "askpass", "askpass");
        try env.put("GIT_ASKPASS", askpass);
        // A directory with no repository above it.
        try env.put("GIT_CEILING_DIRECTORIES", home);
        return .{ .gpa = gpa, .tmp = tmp, .home = home, .env = env, .helpers = helpers, .askpass = askpass };
    }

    fn deinit(fx: *Fixture) void {
        for (fx.helpers) |h| fx.gpa.free(h);
        fx.gpa.free(fx.askpass);
        fx.env.deinit();
        fx.gpa.free(fx.home);
        fx.tmp.cleanup();
        fx.* = undefined;
    }

    /// The tool at `<tmp>/<name>`, logging to `<name>.log`.
    fn standIn(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, kind: []const u8) ![]u8 {
        const path = try testlfs.installProgram(gpa, io, dir, name, suite.path(.lfs_test_tool));
        errdefer gpa.free(path);
        const stem = if (builtin.target.os.tag == .windows) path[0 .. path.len - 4] else path;
        const sidecar = try gpa.print("{s}.fixture", .{path});
        defer gpa.free(sidecar);
        const description = try gpa.print("{s}\n{s}\n", .{ kind, stem });
        defer gpa.free(description);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = sidecar, .data = description });
        return path;
    }

    const Case = struct {
        url: []const u8,
        config: []const u8,
        replies: [2][]const u8,
        challenges: []const []const u8,
    };

    const log_names = [_][]const u8{ "first.log", "second.log", "askpass.log" };

    /// Every log, by `log_names`, and removed.
    fn takeLogs(fx: *Fixture, arena: Allocator, io: Io) ![log_names.len][]const u8 {
        var logs: [log_names.len][]const u8 = undefined;
        for (log_names, &logs) |name, *log| {
            log.* = fx.tmp.dir.readFileAlloc(io, name, arena, .limited(1 << 20)) catch |err| switch (err) {
                error.FileNotFound => "",
                else => return err,
            };
            if (log.len != 0) try fx.tmp.dir.deleteFile(io, name);
        }
        return logs;
    }

    fn expectAsGit(fx: *Fixture, arena: Allocator, io: Io, case: Case) !void {
        try fx.tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = case.config });
        for ([_][]const u8{ "first.answer", "second.answer" }, case.replies) |name, reply| {
            try fx.tmp.dir.writeFile(io, .{ .sub_path = name, .data = reply });
        }

        var input: std.ArrayList(u8) = .empty;
        try input.print(arena, "url={s}\ncapability[]=authtype\ncapability[]=state\n", .{case.url});
        for (case.challenges) |c| try input.print(arena, "wwwauth[]={s}\n", .{c});
        var git = try program.run(fx.gpa, io, .{ .environ = &fx.env }, .{
            .argv = &.{ testgit.program(), "credential", "fill" },
            .cwd = .{ .dir = fx.tmp.dir },
        }, .{ .input = input.items });
        defer git.deinit(fx.gpa);
        const git_logs = try fx.takeLogs(arena, io);

        var config = try config_mod.Config.parseText(fx.gpa, case.config, .global);
        defer config.deinit();
        var session: credential.Session = .{ .gpa = fx.gpa, .url = try url_mod.Url.parse(case.url) };
        defer session.deinit();
        try session.setChallenges(case.challenges);
        const filled = session.fill(io, .{
            .config = &config,
            .programs = .{ .environ = &fx.env },
            .prompt = .{ .askpass = true },
            .now = Io.Clock.real.now(io),
        });
        const relic_logs = try fx.takeLogs(arena, io);

        errdefer std.debug.print(
            "url: {s}\nconfig:\n{s}replies:\n{s}--\n{s}--\ngit said:\n{s}{s}\nrelic: {any}\ngit's helpers:\n{s}\n{s}\n{s}\nrelic's helpers:\n{s}\n{s}\n{s}\n",
            .{ case.url, case.config, case.replies[0], case.replies[1], git.stdout, git.stderr, filled, git_logs[0], git_logs[1], git_logs[2], relic_logs[0], relic_logs[1], relic_logs[2] },
        );
        for (git_logs, relic_logs) |theirs, ours| {
            // git writes to a helper a line at a time and dies at the
            // line it refuses, so the helper may have heard the start of
            // a question relic refuses whole before it writes any of it.
            if (filled == error.CredentialValueUnsafe and std.mem.startsWith(u8, theirs, ours)) {
                const partial = theirs[ours.len..];
                if (partial.len == 0 or (std.mem.startsWith(u8, partial, "== ") and std.mem.count(u8, partial, "== ") == 1)) continue;
            }
            try testing.expectEqualStrings(theirs, ours);
        }
        if (filled) |ok| {
            try testing.expect(ok);
            // `git credential fill` hands the state on before it prints.
            for (session.state_to_send.items) |v| fx.gpa.free(v);
            session.state_to_send.clearRetainingCapacity();
            std.mem.swap(std.ArrayList([]u8), &session.state, &session.state_to_send);
            var printed: std.ArrayList(u8) = .empty;
            defer printed.deinit(fx.gpa);
            session.write(fx.gpa, &printed, .response) catch |err| switch (err) {
                // git dies printing it.
                error.CredentialValueUnsafe => {
                    try testing.expect(!git.succeeded());
                    try testing.expect(std.mem.find(u8, git.stderr, "credential value for") != null);
                    return;
                },
                else => |e| return e,
            };
            try testing.expect(git.succeeded());
            try testing.expectEqualStrings(git.stdout, printed.items);
        } else |err| {
            try testing.expect(!git.succeeded());
            // A helper whose `url=` took the helper list away and then said
            // `quit=1`: git names the quitting helper from the list it
            // freed, and crashes; relic ends as for any other quit.
            if (err == error.CredentialHelperQuit and git.term != .exited) return;
            const said: []const u8 = switch (err) {
                error.CredentialHelperQuit => "told us to quit",
                error.CredentialsUnavailable => "unable to get password from user",
                error.CredentialValueUnsafe => "credential value for",
                error.InvalidCredentialSetting => "'credential.",
                error.InvalidCredentialAnswer => switch (std.mem.find(u8, git.stderr, "credential url cannot be parsed") != null) {
                    true => "credential url cannot be parsed",
                    false => "bad boolean config value",
                },
                else => return err,
            };
            try testing.expect(std.mem.find(u8, git.stderr, said) != null);
        }
    }
};
