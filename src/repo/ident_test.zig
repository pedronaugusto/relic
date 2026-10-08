//! `ident.signature` against `git var GIT_AUTHOR_IDENT` and
//! `GIT_COMMITTER_IDENT`: the same configuration, the same environment,
//! the same identity or the same refusal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ident = @import("ident.zig");
const config_mod = @import("../config/config.zig");
const testgit = @import("../testing/git.zig");

const Case = struct {
    config: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
};

fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, case: Case) !void {
    var env = try testgit.isolatedEnviron(gpa, testgit.no_home);
    defer env.deinit();
    for (case.env) |pair| try env.put(pair[0], pair[1]);
    git.environ = &env;
    defer git.environ = null;
    var config = try config_mod.Config.open(gpa, io, .{ .command = case.config }, .{});
    defer config.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]ident.Role{ .author, .committer }) |role| {
        var args: std.ArrayList([]const u8) = .empty;
        for (case.config) |c| try args.appendSlice(arena, &.{ "-c", c });
        try args.appendSlice(arena, &.{ "var", if (role == .author) "GIT_AUTHOR_IDENT" else "GIT_COMMITTER_IDENT" });
        git.report_failures = false;
        var theirs = try git.capture(io, args.items);
        defer theirs.deinit(gpa);
        const ours = ident.signature(arena, &config, &env, .{ .role = role, .machine = .{}, .now = .{ .secs = testgit.fixture_date } });
        if (theirs.code != 0) {
            if (ours) |sig| {
                std.debug.print("{s}: git refused ({s}), relic gave {s} <{s}>\n", .{ @tagName(role), theirs.stderr, sig.name, sig.email });
                return error.TestUnexpectedResult;
            } else |_| {}
            continue;
        }
        const sig = ours catch |err| {
            std.debug.print("{s}: git gave {s}, relic refused: {t}\n", .{ @tagName(role), theirs.stdout, err });
            return err;
        };
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        try sig.write(&line.writer);
        try line.writer.writeByte('\n');
        try std.testing.expectEqualStrings(theirs.stdout, line.written());
    }
}

test "an identity comes from the environment and the configuration as git's var says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    // the harness's own `-c user.*` would decide every case
    git.defaults = &.{};
    const cases = [_]Case{
        .{ .config = &.{ "user.name=Ada Lovelace", "user.email=ada@example.com" } },
        .{ .config = &.{ "user.name=Ada", "user.email=ada@example.com" }, .env = &.{ .{ "GIT_AUTHOR_NAME", "Env Author" }, .{ "GIT_COMMITTER_EMAIL", "env@example.com" } } },
        .{ .config = &.{ "user.name=Ada", "user.email=ada@example.com", "author.name=Writer", "committer.email=commit@example.com" } },
        .{ .config = &.{ "user.name=  <Odd> Name;", "user.email=<  odd@example.com>;" } },
        .{ .config = &.{"user.name=Ada"}, .env = &.{.{ "EMAIL", "from-env@example.com" }} },
        .{ .config = &.{ "user.name=Ada", "user.useConfigOnly=true" }, .env = &.{.{ "EMAIL", "from-env@example.com" }} },
        .{ .config = &.{ "user.email=ada@example.com", "user.useConfigOnly=true" } },
        .{ .config = &.{ "user.useConfigOnly=true", "user.name=Ada", "committer.email=c@example.com" } },
        .{ .config = &.{ "user.useConfigOnly=true", "committer.name=Cy", "author.email=a@example.com", "committer.email=c@example.com" } },
        .{ .config = &.{ "user.name=", "user.email=ada@example.com" } },
        .{ .config = &.{ "user.name=;;", "user.email=ada@example.com" } },
        .{ .config = &.{ "user.name=Ada", "user.email=ada@example.com" }, .env = &.{ .{ "GIT_AUTHOR_DATE", "@1700000123 +0130" }, .{ "GIT_COMMITTER_DATE", "2005-04-07T22:13:13 -0700" } } },
        .{ .config = &.{ "user.name=Ada", "user.email=ada@example.com" }, .env = &.{.{ "GIT_AUTHOR_DATE", "not a date" }} },
    };
    for (cases) |case| compare(gpa, io, &git, case) catch |err| {
        for (case.config) |c| std.debug.print("-c {s} ", .{c});
        for (case.env) |e| std.debug.print("{s}={s} ", .{ e[0], e[1] });
        std.debug.print("\n", .{});
        return err;
    };
}
