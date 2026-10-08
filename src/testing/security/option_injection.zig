//! Option injection: a host, a path or a URL a repository chose, beginning
//! with `-`, handed to a program as an option (`-oProxyCommand=...`), or an
//! argument that a wrong quoting splits into two on Windows. The owners are
//! `transport/ssh.zig` (the architecture's `wire/ssh`) for what reaches
//! `ssh`, `submodule/gitmodules.zig` (`config/`) for what `.gitmodules`
//! names, and `repo/program.zig` over conduit (`process/`) for the command
//! line itself.

const transport = @import("../../transport/transport.zig");
const std = @import("std");
const suite = @import("../helpers.zig");
const builtin = @import("builtin");

const gitmodules = @import("../../config/gitmodules.zig");
const fsck = @import("../../object/fsck.zig");
const program = @import("../../process/program.zig");
const testgit = @import("../git.zig");

test "CVE-2017-1000117, t5813-proto-disable-ssh 'hostnames starting with dash are rejected' and 'repo names starting with dash are rejected': ssh never sees an option a URL wrote" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, dir, '\\', '/');
    const args = try gpa.print("record '{s}/ran'", .{dir});
    defer gpa.free(args);
    const ssh = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), args);
    defer gpa.free(ssh);
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    try env.put("GIT_SSH_COMMAND", ssh);

    const Case = struct { url: []const u8, refused: anyerror };
    for ([_]Case{
        .{ .url = "ssh://-remote/repo.git", .refused = error.SuspiciousHostname },
        .{ .url = "ssh://-oProxyCommand=touch%20pwned/repo.git", .refused = error.SuspiciousHostname },
        .{ .url = "-oProxyCommand=touch pwned:repo.git", .refused = error.SuspiciousHostname },
        .{ .url = "ssh://-user@remote/repo.git", .refused = error.SuspiciousHostname },
        .{ .url = "remote:-repo.git", .refused = error.SuspiciousPathname },
    }) |case| {
        try std.testing.expectError(case.refused, transport.Session.open(gpa, io, case.url, .upload_pack, .sha1, .{
            .programs = .{ .environ = &env },
        }));
    }
    // t5532-fetch-proxy 'funny hostnames are rejected before running
    // proxy': relic has no git:// client, so no proxy runs at all.
    try std.testing.expectError(error.UnsupportedTransport, transport.Session.open(gpa, io, "git://-remote/repo.git", .upload_pack, .sha1, .{
        .programs = .{ .environ = &env },
    }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "ran", .{}));
}

test "CVE-2018-17456, t7416-submodule-dash-url and t7417-submodule-path-url: a .gitmodules url or path beginning with a dash is dropped and fsck names it" {
    const gpa = std.testing.allocator;
    const text = "[submodule \"url\"]\n\tpath = sub\n\turl = -oProxyCommand=touch pwned\n" ++
        "[submodule \"path\"]\n\tpath = -sub\n\turl = https://example.com/r.git\n" ++
        "[submodule \"fine\"]\n\tpath = ok\n\turl = \" --should-not-be-an-option\"\n";
    var parsed = try gitmodules.Gitmodules.parse(gpa, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.refused.len);
    for (parsed.refused) |r| try std.testing.expectEqual(gitmodules.Reason.option_like_value, r.reason);
    try std.testing.expectEqual(null, parsed.byName("url").?.url);
    try std.testing.expectEqual(null, parsed.byName("path").?.path);

    for ([_]struct { text: []const u8, problem: fsck.Problem }{
        .{ .text = "[submodule \"x\"]\n\tpath = sub\n\turl = -oProxyCommand=touch pwned\n", .problem = .gitmodules_url },
        .{ .text = "[submodule \"x\"]\n\tpath = -sub\n\turl = https://example.com/r.git\n", .problem = .gitmodules_path },
    }) |case| {
        const finding = (try fsck.checkBlob(gpa, &fsck.baseline, .zero(.sha1), .modules, case.text, null)).?;
        try std.testing.expectEqual(case.problem, finding.problem.?);
    }
}

test "CVE-2019-1350, t7416-submodule-dash-url 'trailing backslash is handled correctly': every argument reaches a program whole, directly and through the shell" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    const tricky = [_][]const u8{
        "trailing\\",                 "two\\\\",                "a \"quoted\" word", "\\\"",          "space ",
        " --should-not-be-an-option", "x\\\" -oProxyCommand=y", "",                  "back\\slash\\", "tab\there",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (tricky) |arg| {
        try expected.appendSlice(gpa, arg);
        try expected.append(gpa, 0);
    }
    // Directly, as a hook or a helper named by path runs.
    try argv.appendSlice(gpa, &.{ suite.path(.process_fixture), "args" });
    try argv.appendSlice(gpa, &tricky);
    var direct = try program.run(gpa, io, .{ .environ = &env }, .{ .argv = argv.items }, .{});
    defer direct.deinit(gpa);
    try std.testing.expect(direct.succeeded());
    try std.testing.expectEqualStrings(expected.items, direct.stdout);
    // Through the shell, as a configured command line runs.
    const line = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "args");
    defer gpa.free(line);
    argv.clearRetainingCapacity();
    try argv.append(gpa, line);
    try argv.appendSlice(gpa, &tricky);
    var shelled = try program.run(gpa, io, .{ .environ = &env }, .{ .argv = argv.items, .shell = true }, .{});
    defer shelled.deinit(gpa);
    try std.testing.expect(shelled.succeeded());
    try std.testing.expectEqualStrings(expected.items, shelled.stdout);
}
