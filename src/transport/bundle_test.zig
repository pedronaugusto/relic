//! Bundles against git's, in both directions: what this writes git reads,
//! unbundles and verifies, header byte for byte and pack object for
//! object; what git writes this reads, verifies, lists and fetches from as
//! git does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bundle = @import("bundle.zig");
const repo_mod = @import("../repo.zig");

const Repository = repo_mod.Repository;
const CreateRequest = bundle.CreateRequest;
const create = bundle.create;
const File = bundle.File;
const unbundle = bundle.unbundle;

const testgit = @import("../testing/git.zig");
const fetch_mod = @import("fetch.zig");

/// A history with a merge, a side branch, an annotated and a lightweight
/// tag, made by git at fixed dates.
fn history(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !testgit.Repo {
    var r = try testgit.Repo.init(gpa, io, &.{});
    errdefer r.deinit();
    r.environ = env;
    var when: i64 = 1_700_000_000;
    for (0..4) |i| {
        when += 100;
        try testgit.setDate(env, when);
        const name = try std.fmt.allocPrint(gpa, "f{d}", .{i});
        defer gpa.free(name);
        try r.writeFile(io, name, name);
        try r.exec(io, &.{ "add", name });
        try r.exec(io, &.{ "commit", "-q", "-m", name });
    }
    try r.exec(io, &.{ "tag", "-a", "-m", "one", "v1", "HEAD~2" });
    try r.exec(io, &.{ "checkout", "-q", "-b", "topic", "HEAD~1" });
    for (0..2) |i| {
        when += 100;
        try testgit.setDate(env, when);
        const name = try std.fmt.allocPrint(gpa, "t{d}", .{i});
        defer gpa.free(name);
        try r.writeFile(io, name, name);
        try r.exec(io, &.{ "add", name });
        try r.exec(io, &.{ "commit", "-q", "-m", name });
    }
    try r.exec(io, &.{ "checkout", "-q", "main" });
    when += 100;
    try testgit.setDate(env, when);
    try r.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "merge topic\n\nwith a body", "topic" });
    try r.exec(io, &.{ "tag", "lw", "HEAD~1" });
    return r;
}

fn headerOf(bytes: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, bytes, "\n\n").? + 2;
    return bytes[0..end];
}

/// Every object a repository has, one name to a line, sorted.
fn objectList(io: Io, r: *testgit.Repo) ![]u8 {
    return r.run(io, &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)" });
}

test "a bundle's header is git's byte for byte, and its pack unbundles in git to git's objects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var src = try history(gpa, io, &env);
    defer src.deinit();
    const src_path = try src.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(src_path);
    var repo = try Repository.open(gpa, io, src.dir, .{});
    defer repo.deinit(io);

    const Case = struct { args: []const []const u8, request: CreateRequest };
    const cases = [_]Case{
        .{ .args = &.{"main"}, .request = .{ .include = &.{"main"} } },
        .{ .args = &.{ "main", "v1", "lw", "HEAD", "topic" }, .request = .{ .include = &.{ "main", "v1", "lw", "HEAD", "topic" } } },
        .{ .args = &.{ "main", "^v1" }, .request = .{ .include = &.{"main"}, .exclude = &.{"v1"} } },
        .{ .args = &.{ "main", "topic", "^main~3" }, .request = .{ .include = &.{ "main", "topic" }, .exclude = &.{"main~3"} } },
        .{ .args = &.{ "main", "^topic", "^main~2" }, .request = .{ .include = &.{"main"}, .exclude = &.{ "topic", "main~2" } } },
        .{ .args = &.{ "--version=3", "main", "^main~1" }, .request = .{ .include = &.{"main"}, .exclude = &.{"main~1"}, .version = .v3 } },
        .{ .args = &.{ "--filter=blob:limit=1k", "main" }, .request = .{ .include = &.{"main"}, .filter = "blob:limit=1k" } },
        .{ .args = &.{ "v1", "^main" }, .request = .{ .include = &.{"v1"}, .exclude = &.{"main"} } },
    };
    // Filtered bundles are git 2.36's.
    const filters = try testgit.gitAtLeast(gpa, io, 2, 36);
    for (cases, 0..) |case, n| {
        if (case.request.filter != null and !filters) continue;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(tmp_path);
        const theirs = try std.fmt.allocPrint(gpa, "{s}/git.bundle", .{tmp_path});
        defer gpa.free(theirs);
        const ours = try std.fmt.allocPrint(gpa, "{s}/relic.bundle", .{tmp_path});
        defer gpa.free(ours);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "bundle", "create", "-q" });
        for (case.args) |arg| if (std.mem.startsWith(u8, arg, "--version")) try args.append(gpa, arg);
        try args.append(gpa, theirs);
        for (case.args) |arg| if (!std.mem.startsWith(u8, arg, "--version")) try args.append(gpa, arg);
        try src.exec(io, args.items);
        try create(gpa, io, &repo, tmp.dir, "relic.bundle", case.request);

        const a = try tmp.dir.readFileAlloc(io, "git.bundle", gpa, .unlimited);
        defer gpa.free(a);
        const b = try tmp.dir.readFileAlloc(io, "relic.bundle", gpa, .unlimited);
        defer gpa.free(b);
        std.testing.expectEqualStrings(headerOf(a), headerOf(b)) catch |err| {
            std.debug.print("bundle case {d} differs\n", .{n});
            return err;
        };

        // Both unbundled by git into a repository holding what is
        // excluded: the same objects arrive.
        var lists: [2][]u8 = undefined;
        for ([_][]const u8{ theirs, ours }, 0..) |path, k| {
            var target = try testgit.Repo.init(gpa, io, &.{});
            defer target.deinit();
            for (case.request.exclude) |ex| {
                const hex = try src.line(io, &.{ "rev-parse", ex });
                defer gpa.free(hex);
                try target.exec(io, &.{ "fetch", "-q", src_path, hex });
            }
            try target.exec(io, &.{ "bundle", "verify", "-q", path });
            if (case.request.filter == null) {
                try target.exec(io, &.{ "bundle", "unbundle", path });
                lists[k] = try objectList(io, &target);
            } else {
                lists[k] = try target.run(io, &.{ "bundle", "list-heads", path });
            }
        }
        defer for (lists) |l| gpa.free(l);
        try std.testing.expectEqualStrings(lists[0], lists[1]);
    }

    // Nothing to write is refused by name, where git refuses it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.EmptyBundle, create(gpa, io, &repo, tmp.dir, "x.bundle", .{ .include = &.{"main"}, .exclude = &.{"main"} }));
    try std.testing.expectError(error.EmptyBundle, create(gpa, io, &repo, tmp.dir, "x.bundle", .{ .include = &.{"main~1"} }));
    try std.testing.expectError(error.VersionTooLow, create(gpa, io, &repo, tmp.dir, "x.bundle", .{ .include = &.{"main"}, .filter = "blob:none", .version = .v2 }));
}

/// The names of the objects in the pack after a bundle's header, sorted,
/// as git's `index-pack` and `verify-pack` read them.
fn packObjects(gpa: Allocator, io: Io, r: *testgit.Repo, dir: Io.Dir, dir_path: []const u8, name: []const u8) ![]u8 {
    const bytes = try dir.readFileAlloc(io, name, gpa, .unlimited);
    defer gpa.free(bytes);
    const pack_name = try std.fmt.allocPrint(gpa, "{s}.pack", .{name});
    defer gpa.free(pack_name);
    try dir.writeFile(io, .{ .sub_path = pack_name, .data = bytes[headerOf(bytes).len..] });
    const pack_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, pack_name });
    defer gpa.free(pack_path);
    try r.exec(io, &.{ "index-pack", pack_path });
    const idx_path = try std.fmt.allocPrint(gpa, "{s}/{s}.idx", .{ dir_path, name });
    defer gpa.free(idx_path);
    const listing = try r.run(io, &.{ "verify-pack", "-v", idx_path });
    defer gpa.free(listing);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len < 41 or line[40] != ' ') continue;
        try names.append(gpa, line[0..40]);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return std.mem.join(gpa, "\n", names.items);
}

test "a bundle filtered by sparse:oid= holds the objects git's holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!try testgit.gitAtLeast(gpa, io, 2, 36)) return error.SkipZigTest;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var src = try history(gpa, io, &env);
    defer src.deinit();
    try src.writeFile(io, "spec", "/f1\n/t*\n!/t1\n");
    const blob = try src.line(io, &.{ "hash-object", "-w", "spec" });
    defer gpa.free(blob);
    var repo = try Repository.open(gpa, io, src.dir, .{});
    defer repo.deinit(io);

    const by_hex = try std.fmt.allocPrint(gpa, "sparse:oid={s}", .{blob});
    defer gpa.free(by_hex);
    const combined = try std.fmt.allocPrint(gpa, "combine:sparse:oid={s}+blob:limit=1", .{blob});
    defer gpa.free(combined);
    for ([_][]const u8{ by_hex, combined }) |spec| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(tmp_path);
        const theirs = try std.fmt.allocPrint(gpa, "{s}/git.bundle", .{tmp_path});
        defer gpa.free(theirs);
        const filter_arg = try std.fmt.allocPrint(gpa, "--filter={s}", .{spec});
        defer gpa.free(filter_arg);
        try src.exec(io, &.{ "bundle", "create", "-q", theirs, filter_arg, "main", "topic" });
        try create(gpa, io, &repo, tmp.dir, "relic.bundle", .{ .include = &.{ "main", "topic" }, .filter = spec });

        const a = try tmp.dir.readFileAlloc(io, "git.bundle", gpa, .unlimited);
        defer gpa.free(a);
        const b = try tmp.dir.readFileAlloc(io, "relic.bundle", gpa, .unlimited);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(headerOf(a), headerOf(b));
        const want = try packObjects(gpa, io, &src, tmp.dir, tmp_path, "git.bundle");
        defer gpa.free(want);
        const got = try packObjects(gpa, io, &src, tmp.dir, tmp_path, "relic.bundle");
        defer gpa.free(got);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("with --filter={s}\n", .{spec});
            return err;
        };
    }

    // A name that is no blob is refused, where git refuses it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    src.report_failures = false;
    try std.testing.expectError(error.GitFailed, src.run(io, &.{ "bundle", "create", "-q", "x.bundle", "--filter=sparse:oid=main:nothing", "main" }));
    try std.testing.expectError(error.SparseBlobMissing, create(gpa, io, &repo, tmp.dir, "x.bundle", .{ .include = &.{"main"}, .filter = "sparse:oid=main:nothing" }));
}

test "git's bundles are read, verified, listed, unbundled and fetched from as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try testgit.datedEnv(gpa, 1_700_000_000);
    defer env.deinit();
    var src = try history(gpa, io, &env);
    defer src.deinit();
    const src_path = try src.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(src_path);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_path);
    const path = try std.fmt.allocPrint(gpa, "{s}/inc.bundle", .{tmp_path});
    defer gpa.free(path);
    try src.exec(io, &.{ "bundle", "create", "-q", path, "main", "topic", "lw", "^v1" });

    // Two repositories holding the prerequisites: git works in one and
    // this in the other.
    var twins: [2]testgit.Repo = undefined;
    for (&twins) |*t| {
        t.* = try testgit.Repo.init(gpa, io, &.{});
        t.environ = &env;
        try t.exec(io, &.{ "fetch", "-q", src_path, "refs/tags/v1:refs/tags/v1" });
    }
    defer for (&twins) |*t| t.deinit();
    var repo = try Repository.open(gpa, io, twins[1].dir, .{});
    defer repo.deinit(io);

    {
        var f = try File.open(gpa, io, tmp.dir, "inc.bundle");
        defer f.close(gpa, io);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try f.header.listHeads(&out.writer, &.{});
        const heads = try twins[0].run(io, &.{ "bundle", "list-heads", path });
        defer gpa.free(heads);
        try std.testing.expectEqualStrings(heads, out.written());
        // The summary as a recent git prints it, with the hash algorithm.
        if (try testgit.gitAtLeast(gpa, io, 2, 40)) {
            out.clearRetainingCapacity();
            try f.header.writeSummary(&out.writer);
            const summary = try twins[0].run(io, &.{ "bundle", "verify", path });
            defer gpa.free(summary);
            try std.testing.expectEqualStrings(summary, out.written());
        }
    }

    // An empty repository lacks the prerequisites, as git says.
    {
        var empty = try testgit.Repo.init(gpa, io, &.{});
        defer empty.deinit();
        var empty_repo = try Repository.open(gpa, io, empty.dir, .{});
        defer empty_repo.deinit(io);
        var f = try File.open(gpa, io, tmp.dir, "inc.bundle");
        defer f.close(gpa, io);
        try std.testing.expectError(error.MissingPrerequisites, unbundle(gpa, io, &empty_repo, f, .{}));
        empty.report_failures = false;
        try std.testing.expectError(error.GitFailed, empty.exec(io, &.{ "bundle", "verify", "-q", path }));
    }

    // Fetched from, as a path: refs, FETCH_HEAD and logs as git's.
    try twins[0].exec(io, &.{ "fetch", path, "refs/heads/*:refs/remotes/b/*", "lw" });
    var outcome = try fetch_mod.fetch(gpa, io, &repo, path, .{
        .who = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
        .refspecs = &.{ "refs/heads/*:refs/remotes/b/*", "lw" },
    });
    outcome.deinit();
    for ([_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
        &.{ "reflog", "show", "--format=%H %gs", "refs/remotes/b/main" },
        &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname)" },
    }) |args| {
        const a = try twins[0].run(io, args);
        defer gpa.free(a);
        const b = try twins[1].run(io, args);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
    const fa = try twins[0].readFile(io, ".git/FETCH_HEAD");
    defer gpa.free(fa);
    const fb = try twins[1].readFile(io, ".git/FETCH_HEAD");
    defer gpa.free(fb);
    try std.testing.expectEqualStrings(fa, fb);
}
