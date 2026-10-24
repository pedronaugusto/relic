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
const fs = @import("../fs/fs.zig");
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
            log.* = fs.readWhole(fx.tmp.dir, io, name, arena, .limited(1 << 20)) catch |err| switch (err) {
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
            var printed: std.Io.Writer.Allocating = .init(fx.gpa);
            defer printed.deinit();
            session.write(&printed.writer, .response) catch |err| switch (err) {
                // git dies printing it.
                error.CredentialValueUnsafe => {
                    try testing.expect(!git.succeeded());
                    try testing.expect(std.mem.find(u8, git.stderr, "credential value for") != null);
                    return;
                },
                else => |e| return e,
            };
            try testing.expect(git.succeeded());
            try testing.expectEqualStrings(git.stdout, printed.written());
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

const store_mod = @import("credential/store.zig");

test "credential-store run in process keeps the file git's keeps and answers as it does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(root);
    const theirs = try gpa.print("{s}/by-git", .{root});
    defer gpa.free(theirs);
    const ours = try gpa.print("{s}/by-relic", .{root});
    defer gpa.free(ours);
    // What neither touches: a line that is no URL, one with no password,
    // one ended by a carriage return.
    const seed = "not a url\nhttps://only@example.com\nhttps://u:p@kept.example.com\r\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "by-git", .data = seed });
    try tmp.dir.writeFile(io, .{ .sub_path = "by-relic", .data = seed });

    const Step = struct { op: []const u8, c: store_mod.Credential };
    const steps = [_]Step{
        .{ .op = "store", .c = .{ .protocol = "https", .host = "example.com", .username = "ada", .password = "p@ss w/rd" } },
        .{ .op = "store", .c = .{ .protocol = "https", .host = "example.com", .path = "org/repo.git", .username = "bob", .password = "x" } },
        .{ .op = "store", .c = .{ .protocol = "http", .host = "other.example:8080", .username = "c%d", .password = "q:r" } },
        .{ .op = "store", .c = .{ .protocol = "https", .host = "example.com", .username = "ada", .password = "new" } },
        .{ .op = "store", .c = .{ .protocol = "https", .host = "example.com", .username = "nopassword" } },
        .{ .op = "get", .c = .{ .protocol = "https", .host = "example.com" } },
        .{ .op = "get", .c = .{ .protocol = "https", .host = "example.com", .path = "org/repo.git", .username = "bob" } },
        .{ .op = "get", .c = .{ .protocol = "https", .host = "nowhere.example" } },
        .{ .op = "erase", .c = .{ .protocol = "https", .host = "example.com", .username = "ada", .password = "old" } },
        .{ .op = "erase", .c = .{ .protocol = "https", .host = "example.com", .username = "ada" } },
        .{ .op = "erase", .c = .{} },
        .{ .op = "get", .c = .{ .protocol = "https", .host = "example.com" } },
    };
    for (steps) |step| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(gpa);
        inline for (.{ "protocol", "host", "path", "username", "password" }) |name| {
            if (@field(step.c, name)) |v| try input.print(gpa, "{s}={s}\n", .{ name, v });
        }
        try input.append(gpa, '\n');
        const answer = try testremote.gitInput(gpa, io, tmp.dir, &.{ "credential-store", "--file", theirs, step.op }, input.items);
        defer gpa.free(answer);

        const files: store_mod.Files = .{ .paths = &.{ours} };
        var ours_answer: std.ArrayList(u8) = .empty;
        defer ours_answer.deinit(gpa);
        if (std.mem.eql(u8, step.op, "get")) {
            if (try store_mod.get(gpa, io, files, step.c)) |found| {
                defer gpa.free(found.username);
                defer gpa.free(found.password);
                try ours_answer.print(gpa, "username={s}\npassword={s}\n", .{ found.username, found.password });
            }
        } else if (std.mem.eql(u8, step.op, "store")) {
            try store_mod.store(gpa, io, files, step.c);
        } else {
            try store_mod.erase(gpa, io, files, step.c);
        }
        try testing.expectEqualStrings(answer, ours_answer.items);
        const file_theirs = try fs.readWhole(tmp.dir, io, "by-git", gpa, .unlimited);
        defer gpa.free(file_theirs);
        const file_ours = try fs.readWhole(tmp.dir, io, "by-relic", gpa, .unlimited);
        defer gpa.free(file_ours);
        try testing.expectEqualStrings(file_theirs, file_ours);
    }
    if (builtin.target.os.tag != .windows) {
        const st = try tmp.dir.statFile(io, "by-relic", .{});
        try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

test "credential-store's default files are git's: ~/.git-credentials first, else the XDG one when only it is there" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]bool{ false, true }) |xdg_there| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try testremote.absolutePath(gpa, io, tmp.dir);
        defer gpa.free(root);
        for ([_][]const u8{ "git-home", "relic-home" }) |home| {
            try tmp.dir.createDirPath(io, home);
            if (xdg_there) {
                const dir = try gpa.print("{s}/.config/git", .{home});
                defer gpa.free(dir);
                try tmp.dir.createDirPath(io, dir);
                const file = try gpa.print("{s}/credentials", .{dir});
                defer gpa.free(file);
                try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "" });
            }
        }
        var env = try testremote.environ(gpa);
        defer env.deinit();
        const git_home = try gpa.print("{s}/git-home", .{root});
        defer gpa.free(git_home);
        try env.put("HOME", git_home);
        _ = env.swapRemove("XDG_CONFIG_HOME");
        const out = try testremote.gitInputEnv(gpa, io, tmp.dir, &env, &.{ "credential-store", "store" }, "protocol=https\nhost=h.example\nusername=u\npassword=p\n\n", true);
        gpa.free(out);

        var relic_env: std.process.Environ.Map = .init(gpa);
        defer relic_env.deinit();
        const relic_home = try gpa.print("{s}/relic-home", .{root});
        defer gpa.free(relic_home);
        try relic_env.put("HOME", relic_home);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const paths = try store_mod.defaultFiles(arena_state.allocator(), &relic_env);
        try store_mod.store(gpa, io, .{ .paths = paths }, .{ .protocol = "https", .host = "h.example", .username = "u", .password = "p" });
        for ([_][]const u8{ ".git-credentials", ".config/git/credentials" }) |name| {
            var contents: [2][]u8 = undefined;
            for ([_][]const u8{ "git-home", "relic-home" }, &contents) |home, *c| {
                const path = try gpa.print("{s}/{s}", .{ home, name });
                defer gpa.free(path);
                c.* = fs.readWhole(tmp.dir, io, path, gpa, .unlimited) catch try gpa.dupe(u8, "(none)");
            }
            defer for (contents) |c| gpa.free(c);
            try testing.expectEqualStrings(contents[0], contents[1]);
        }
    }
}

test "a store helper with words a shell hands over as written runs in process: quoted --file, ~/, and git's own file left for git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(home);
    // A path goes into configuration text, where a backslash escapes.
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, home, '\\', '/');
    try tmp.dir.writeFile(io, .{ .sub_path = "my creds", .data = "https://ada:one@example.com\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git-credentials", .data = "https://bob:two@example.com\n" });
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    const Case = struct { helper: []const u8, username: []const u8 };
    const cases = [_]Case{
        .{ .helper = "store --file '~/my creds'", .username = "" },
        .{ .helper = "store --file ~/'my creds'", .username = "ada" },
        // `\"` in the configuration, so the shell sees the quotes.
        .{ .helper = "store --file=\\\"MY\\\"", .username = "ada" },
        .{ .helper = "store", .username = "bob" },
    };
    const mine = try gpa.print("{s}/my creds", .{home});
    defer gpa.free(mine);
    for (cases) |case| {
        const helper = try std.mem.replaceOwned(u8, gpa, case.helper, "MY", mine);
        defer gpa.free(helper);
        const text = try gpa.print("[credential]\n\thelper = {s}\n", .{helper});
        defer gpa.free(text);
        var config = try config_mod.Config.parseText(gpa, text, .global);
        defer config.deinit();
        var session: credential.Session = .{ .gpa = gpa, .url = try url_mod.Url.parse("https://example.com/r") };
        defer session.deinit();
        // A quoted `~` is no home: that file is not there, and nothing is
        // left but a prompt there is none of.
        const filled = session.fill(io, .{ .config = &config, .programs = .{ .environ = &env } });
        if (case.username.len == 0) {
            try testing.expectError(error.CredentialsUnavailable, filled);
            continue;
        }
        try testing.expect(try filled);
        try testing.expectEqualStrings(case.username, session.username.?);
    }
}

const cache = credential.cache;
const cache_daemon = @import("credential/cache/daemon.zig");
const shakedown = @import("shakedown");

/// `git credential-cache --socket <socket> <args>` with `input`, as git
/// runs the helper: its output.
fn gitCache(gpa: Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map, socket: []const u8, args: []const []const u8, input: []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "credential-cache", "--socket", socket });
    try argv.appendSlice(gpa, args);
    return testremote.gitInputEnv(gpa, io, dir, env, argv.items, input, true);
}

test "credential-cache's daemon run in process answers git's client as git's daemon does: matching, order, capabilities, refusals and erasure" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(root);
    // A socket path goes into configuration text, where a backslash escapes.
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, root, '\\', '/');
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("HOME", root);
    const theirs = try gpa.print("{s}/git/socket", .{root});
    defer gpa.free(theirs);
    const ours = try gpa.print("{s}/relic/socket", .{root});
    defer gpa.free(ours);

    var daemons: cache_daemon.InProcess = .init(gpa, io);
    defer daemons.deinit();
    const starter = daemons.starter();
    try starter.start(starter.context, io, ours);
    // git's starts with the first store; it ends with `exit` either way.
    defer gpa.free(gitCache(gpa, io, tmp.dir, &env, theirs, &.{"exit"}, "") catch &.{});

    const Step = struct { args: []const []const u8, input: []const u8 };
    const steps = [_]Step{
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=example.com\nusername=ada\npassword=one\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=example.com\n\n" },
        // A token, kept with what goes with it; its authtype and credential
        // only to a client that says it takes them.
        .{ .args = &.{"store"}, .input = "capability[]=authtype\nprotocol=https\nhost=tok.example\nauthtype=Bearer\ncredential=xyz\npassword_expiry_utc=4102444800\noauth_refresh_token=r\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=tok.example\n\n" },
        .{ .args = &.{"get"}, .input = "capability[]=authtype\nprotocol=https\nhost=tok.example\n\n" },
        // Refused: a partial credential, an ephemeral one, a negative
        // timeout; a request with a line that is no line is passed over.
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=partial.example\nusername=u\n\n" },
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=eph.example\nusername=u\npassword=p\nephemeral=1\n\n" },
        .{ .args = &.{ "--timeout=-1", "store" }, .input = "protocol=https\nhost=neg.example\nusername=u\npassword=p\n\n" },
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=bad.example\nno line\nusername=u\npassword=p\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=partial.example\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=eph.example\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=neg.example\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=bad.example\n\n" },
        // A URL starts the credential over.
        .{ .args = &.{"store"}, .input = "protocol=http\nhost=gone.example\nurl=https://u:p@url.example/a/b\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=url.example\npath=a/b\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=http\nhost=gone.example\n\n" },
        // Three for one host; erasing the first moves the last into its
        // place, so a lookup finds that one next.
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=many.example\nusername=a\npassword=1\n\n" },
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=many.example\nusername=b\npassword=2\n\n" },
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=many.example\nusername=c\npassword=3\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=many.example\n\n" },
        .{ .args = &.{"erase"}, .input = "protocol=https\nhost=many.example\nusername=a\npassword=wrong\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=many.example\n\n" },
        .{ .args = &.{"erase"}, .input = "protocol=https\nhost=many.example\nusername=a\npassword=1\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=many.example\n\n" },
        // A store replaces what it matches, password aside.
        .{ .args = &.{"store"}, .input = "protocol=https\nhost=example.com\nusername=ada\npassword=two\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=example.com\nusername=ada\n\n" },
        .{ .args = &.{"erase"}, .input = "host=example.com\n\n" },
        .{ .args = &.{"get"}, .input = "protocol=https\nhost=example.com\n\n" },
        .{ .args = &.{"capability"}, .input = "" },
        .{ .args = &.{"unknown"}, .input = "" },
    };
    for (steps) |step| {
        const git_said = try gitCache(gpa, io, tmp.dir, &env, theirs, step.args, step.input);
        defer gpa.free(git_said);
        const relic_said = try gitCache(gpa, io, tmp.dir, &env, ours, step.args, step.input);
        defer gpa.free(relic_said);
        errdefer std.debug.print("git credential-cache {s}\n{s}", .{ step.args[step.args.len - 1], step.input });
        try testing.expectEqualStrings(git_said, relic_said);
    }

    // `exit` ends the daemon, its socket gone before the client is let go.
    gpa.free(try gitCache(gpa, io, tmp.dir, &env, ours, &.{"exit"}, ""));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, ours, .{}));
    // A daemon's directory is its owner's alone, and refused when looser.
    if (builtin.target.os.tag != .windows) {
        const st = try tmp.dir.statFile(io, "relic", .{});
        try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
        try tmp.dir.createDirPath(io, "open");
        try tmp.dir.setFilePermissions(io, "open", .fromMode(0o755), .{});
        const open_socket = try gpa.print("{s}/open/socket", .{root});
        defer gpa.free(open_socket);
        try testing.expectError(error.SocketDirectoryTooOpen, cache_daemon.Daemon.listen(gpa, io, open_socket));
    }
    try testing.expectError(error.SocketPathNotAbsolute, cache_daemon.Daemon.listen(gpa, io, "relative/socket"));
}

test "credential-cache's daemon lets a credential go when its time is up, and ends thirty seconds after it holds nothing, by the clock it runs on" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(root);
    // A socket path goes into configuration text, where a backslash escapes.
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, root, '\\', '/');
    const socket = try gpa.print("{s}/c/socket", .{root});
    defer gpa.free(socket);
    var clock = shakedown.Clock.init(io, .{});
    const clock_io = clock.io();
    var daemon = try cache_daemon.Daemon.listen(gpa, clock_io, socket);
    defer daemon.deinit();
    var running = try clock_io.concurrent(cache_daemon.Daemon.run, .{&daemon});
    // glint-ignore: Z026 -- the daemon has ended by then, or the test failed already
    defer running.cancel(clock_io) catch {};

    const ask = struct {
        fn ask(a: Allocator, s: []const u8, action: cache.Action, timeout: i32, input: []const u8) !?[]u8 {
            return cache.request(a, testing.io, s, .{ .action = action, .timeout = timeout, .input = input });
        }
    }.ask;
    const held = "protocol=https\nhost=h.example\n\n";
    gpa.free((try ask(gpa, socket, .store, 10, "protocol=https\nhost=h.example\nusername=u\npassword=p\n\n")).?);
    try clock.awaitArmed(1, .none);
    clock.advance(.fromSeconds(9));
    try clock.awaitArmed(1, .none);
    const still = (try ask(gpa, socket, .get, 0, held)).?;
    defer gpa.free(still);
    try testing.expectEqualStrings("capability[]=authtype\nusername=u\npassword=p\n", still);
    try clock.awaitArmed(1, .none);
    clock.advance(.fromSeconds(2));
    try clock.awaitArmed(1, .none);
    const gone = (try ask(gpa, socket, .get, 0, held)).?;
    defer gpa.free(gone);
    try testing.expectEqualStrings("", gone);
    // Holding nothing, it waits thirty seconds from the last that went.
    try clock.awaitArmed(1, .none);
    clock.advance(.fromSeconds(30));
    try running.await(clock_io);
    try testing.expectEqual(null, try ask(gpa, socket, .get, 0, held));
}

test "the cache helper runs in process against git's daemon and relic's, and a store with no daemon starts the caller's, else git's as git does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(root);
    // A socket path goes into configuration text, where a backslash escapes.
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, root, '\\', '/');
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("HOME", root);
    const theirs = try gpa.print("{s}/git/socket", .{root});
    defer gpa.free(theirs);
    const ours = try gpa.print("{s}/relic/socket", .{root});
    defer gpa.free(ours);
    var daemons: cache_daemon.InProcess = .init(gpa, io);
    defer daemons.deinit();
    // git's daemon, started by relic's store with no starter as git's own
    // client starts it.
    defer gpa.free(gitCache(gpa, io, tmp.dir, &env, theirs, &.{"exit"}, "") catch &.{});

    for ([_][]const u8{ theirs, ours }) |socket| {
        const text = try gpa.print("[credential]\n\thelper = cache --timeout=60 --socket '{s}'\n", .{socket});
        defer gpa.free(text);
        var config = try config_mod.Config.parseText(gpa, text, .global);
        defer config.deinit();
        const url = try url_mod.Url.parse("https://ada@example.com/r");
        // The password the URL brings is what a store hands on.
        const with_password = try url_mod.Url.parse("https://ada:pw@example.com/r");
        {
            var session: credential.Session = .{ .gpa = gpa, .url = with_password };
            defer session.deinit();
            var opts: credential.Options = .{ .config = &config, .programs = .{ .environ = &env } };
            if (socket.ptr == ours.ptr) opts.cache_daemon = daemons.starter();
            _ = try session.fill(io, opts);
            try session.approve(io, opts);
        }
        // git's client finds what relic's stored.
        const found = try gitCache(gpa, io, tmp.dir, &env, socket, &.{"get"}, "protocol=https\nhost=example.com\nusername=ada\n\n");
        defer gpa.free(found);
        try testing.expectEqualStrings("capability[]=authtype\nusername=ada\npassword=pw\n", found);
        // relic's fill finds it, and its reject erases it.
        var again: credential.Session = .{ .gpa = gpa, .url = url };
        defer again.deinit();
        try testing.expect(try again.fill(io, .{ .config = &config, .programs = .{ .environ = &env } }));
        try testing.expectEqualStrings("pw", again.password.?.expose());
        try again.reject(io, .{ .config = &config, .programs = .{ .environ = &env } });
        const erased = try gitCache(gpa, io, tmp.dir, &env, socket, &.{"get"}, "protocol=https\nhost=example.com\nusername=ada\n\n");
        defer gpa.free(erased);
        try testing.expectEqualStrings("", erased);
    }
}
