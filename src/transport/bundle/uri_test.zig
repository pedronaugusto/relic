//! Bundle URIs against git 2.55: a clone's `--bundle-uri`, a list under
//! the `creationToken` heuristic, and the fetches after it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const bundle_uri = @import("uri.zig");
const clone_mod = @import("../clone.zig");
const fetch_mod = @import("../fetch.zig");
const repo_mod = @import("../../repo/repo.zig");
const object = @import("../../object/object.zig");
const testgit = @import("../../testing/git.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

test "a bundle list's keys as git's bundle_list_update reads them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var list: bundle_uri.List = .{ .arena = arena_state.allocator() };
    try list.parseConfig("https://example.com/lists/all.list",
        \\[bundle]
        \\    version = 1
        \\    mode = any
        \\    heuristic = creationToken
        \\    future = kept out
        \\[bundle "one"]
        \\    uri = one.bundle
        \\    creationToken = 7x
        \\[bundle "two"]
        \\    uri = ../two.bundle
        \\[bundle "three"]
        \\    uri = file:///srv/three.bundle
        \\
    );
    try testing.expectEqual(bundle_uri.Mode.any, list.mode);
    try testing.expectEqual(bundle_uri.Heuristic.creation_token, list.heuristic);
    try testing.expectEqualStrings("https://example.com/lists/one.bundle", list.bundles.items[0].uri.?);
    try testing.expectEqual(@as(u64, 7), list.bundles.items[0].creation_token);
    try testing.expectEqualStrings("https://example.com/two.bundle", list.bundles.items[1].uri.?);
    try testing.expectEqualStrings("file:///srv/three.bundle", list.bundles.items[2].uri.?);

    for ([_][]const u8{ "[bundle]\n\tversion = 2\n", "[bundle]\n\tmode = some\n", "[core]\n\tbare = true\n", "[bundle \"a\"]\n\turi = x\n\turi = y\n", "[bundle \"a\"]\n\tcreationToken = 1\n" }) |text| {
        var bad: bundle_uri.List = .{ .arena = arena_state.allocator() };
        try testing.expectError(error.InvalidBundleList, bad.parseConfig("/srv/list", text));
    }
    var line: bundle_uri.List = .{ .arena = arena_state.allocator() };
    try line.parseLine("bundle.version=1");
    try testing.expectError(error.InvalidBundleList, line.parseLine("bundle.mode="));
    try testing.expectError(error.InvalidBundleList, line.parseLine("=all"));
}

/// What git says of a clone's refs and its settings for bundles.
fn describe(src: *testgit.Repo, io: Io, path: []const u8) ![]u8 {
    const refs = try src.run(io, &.{ "-C", path, "for-each-ref", "--format=%(refname) %(objectname)" });
    defer src.gpa.free(refs);
    const config = src.run(io, &.{ "-C", path, "config", "--get-regexp", "^fetch\\.bundle" }) catch try src.gpa.dupe(u8, "");
    defer src.gpa.free(config);
    return std.mem.concat(src.gpa, u8, &.{ refs, config });
}

test "clone --bundle-uri and fetch.bundleURI take bundles before the server as git 2.55 does: a bundle, a list by creationToken, the fetch after" {
    const gpa = testing.allocator;
    const io = testing.io;
    var src = try testgit.Repo.init(gpa, io, &.{});
    defer src.deinit();
    src.report_failures = false;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top = try src.dir.realPathFileAlloc(io, ".", arena);
    var out = testing.tmpDir(.{});
    defer out.cleanup();
    const outside = try out.dir.realPathFileAlloc(io, ".", arena);

    // Three commits, a bundle for each step, and a list of the first two.
    var bundles: [3][]const u8 = undefined;
    for (0..3) |i| {
        try src.writeFile(io, "f", try arena.print("{d}\n", .{i}));
        try src.exec(io, &.{ "add", "f" });
        try src.exec(io, &.{ "commit", "-q", "-m", try arena.print("c{d}", .{i}) });
        bundles[i] = try std.Io.Dir.path.join(arena, &.{ outside, try arena.print("b{d}.bundle", .{i}) });
        const range = if (i == 0) "main" else "main~1..main";
        try src.exec(io, &.{ "bundle", "create", "-q", bundles[i], range });
    }
    try src.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    const list = try std.Io.Dir.path.join(arena, &.{ outside, "bundles.list" });
    const listed = "[bundle]\n\tversion = 1\n\tmode = all\n\theuristic = creationToken\n[bundle \"b0\"]\n\turi = b0.bundle\n\tcreationToken = 1\n[bundle \"b1\"]\n\turi = b1.bundle\n\tcreationToken = 2\n";
    try out.dir.writeFile(io, .{ .sub_path = "bundles.list", .data = listed });
    const url = try arena.print("file://{s}", .{top});

    const Case = struct { uri: []const u8, name: []const u8 };
    for ([_]Case{ .{ .uri = bundles[0], .name = "one" }, .{ .uri = list, .name = "list" }, .{ .uri = "/nowhere/at/all.bundle", .name = "missing" } }) |case| {
        const by_git = try std.Io.Dir.path.join(arena, &.{ outside, try arena.print("git-{s}", .{case.name}) });
        const by_relic = try std.Io.Dir.path.join(arena, &.{ outside, try arena.print("relic-{s}", .{case.name}) });
        const said = src.run(io, &.{ "clone", "-q", try arena.print("--bundle-uri={s}", .{case.uri}), url, by_git }) catch |err| return err;
        gpa.free(said);
        try out.dir.createDirPath(io, std.Io.Dir.path.basename(by_relic));
        var dir = try out.dir.openDir(io, std.Io.Dir.path.basename(by_relic), .{});
        defer dir.close(io);
        var cloned = try clone_mod.clone(gpa, io, url, dir, .{ .who = test_who, .programs = .{ .environ = src.environMap() }, .bundle_uri = case.uri });
        cloned.deinit(io);
        const want = try describe(&src, io, by_git);
        defer gpa.free(want);
        const got = try describe(&src, io, by_relic);
        defer gpa.free(got);
        errdefer std.debug.print("case {s}\n", .{case.name});
        try testing.expectEqualStrings(want, got);
    }

    // The newer bundle joins the list; the fetch reads fetch.bundleURI.
    try src.exec(io, &.{ "reset", "-q", "--hard", "ORIG_HEAD" });
    const longer = try std.mem.concat(arena, u8, &.{ listed, "[bundle \"b2\"]\n\turi = b2.bundle\n\tcreationToken = 3\n" });
    try out.dir.writeFile(io, .{ .sub_path = "bundles.list", .data = longer });
    const by_git = try std.Io.Dir.path.join(arena, &.{ outside, "git-list" });
    gpa.free(try src.run(io, &.{ "-C", by_git, "fetch", "-q", "origin" }));
    var relic_dir = try out.dir.openDir(io, "relic-list", .{});
    defer relic_dir.close(io);
    var repo = try repo_mod.Repository.open(gpa, io, relic_dir, .{});
    defer repo.deinit(io);
    var outcome = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = src.environMap() } });
    outcome.deinit();
    const want = try describe(&src, io, by_git);
    defer gpa.free(want);
    const got = try describe(&src, io, try std.Io.Dir.path.join(arena, &.{ outside, "relic-list" }));
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}
