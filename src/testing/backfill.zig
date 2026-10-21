//! `backfill` against git 2.55's `git backfill`: two blobless clones of
//! one server, git backfilling one and this package the other, then hold
//! the same objects, promised the same ones, and got them in the same
//! batches -- each promisor pack holds the same objects as one of git's.
//!
//! The history is `t5620-backfill.sh`'s: four files at the root and in
//! `a`, `a/b`, `a/b/c`, `d` and `d/f`, two versions each over eight
//! commits; a side branch merged with files in `s`, and a branch never
//! merged with files in `o` and a `sparse:oid=` cone. The last commit of
//! `main` before the merge adds a submodule, which the walk passes by, and
//! a copy of `d/f` at `z/dup`, whose tree and blobs the walk takes at
//! `d/f` alone -- unless a cone takes in `z` and not `d`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const repo_mod = @import("../repo/repo.zig");
const pathspec = @import("../patterns.zig").pathspec;
const backfill = @import("../transport/backfill.zig");

const Server = struct {
    tmp: testing.TmpDir,
    url: []u8,
    env: std.process.Environ.Map,

    fn deinit(s: *Server, gpa: Allocator) void {
        gpa.free(s.url);
        s.env.deinit();
        s.tmp.cleanup();
        s.* = undefined;
    }
};

fn served(gpa: Allocator, io: Io) !Server {
    var src = try testgit.Repo.init(gpa, io, &.{});
    defer src.deinit();
    for ([_][]const u8{ "a/b/c", "d/f" }) |dir| try src.dir.createDirPath(io, dir);
    for (1..3) |i| for (1..5) |n| {
        for ([_][]const u8{ "", "a/", "a/b/", "a/b/c/", "d/", "d/f/" }) |dir| {
            const path = try gpa.print("{s}file.{d}.txt", .{ dir, n });
            defer gpa.free(path);
            const text = try gpa.print("Version {d} of file {s}{d}\n", .{ i, dir, n });
            defer gpa.free(text);
            try src.writeFile(io, path, text);
        }
        try src.exec(io, &.{ "add", "." });
        if (i == 2 and n == 4) {
            const tree = try src.line(io, &.{ "rev-parse", "HEAD:d/f" });
            defer gpa.free(tree);
            try src.exec(io, &.{ "read-tree", "--prefix=z/dup/", tree });
            const head = try src.line(io, &.{ "rev-parse", "HEAD" });
            defer gpa.free(head);
            const info = try gpa.print("160000,{s},sub", .{head});
            defer gpa.free(info);
            try src.exec(io, &.{ "update-index", "--add", "--cacheinfo", info });
        }
        const message = try gpa.print("Iteration {d}", .{n});
        defer gpa.free(message);
        try src.exec(io, &.{ "commit", "-q", "-m", message });
    };
    try src.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try src.dir.createDirPath(io, "s");
    for (1..3) |v| {
        for (1..3) |n| {
            const path = try gpa.print("s/file.{d}.txt", .{n});
            defer gpa.free(path);
            const text = try gpa.print("Side version {d} of file {d}\n", .{ v, n });
            defer gpa.free(text);
            try src.writeFile(io, path, text);
        }
        try src.exec(io, &.{ "add", "." });
        try src.exec(io, &.{ "commit", "-q", "-m", "Side commit" });
    }
    try src.exec(io, &.{ "checkout", "-q", "main" });
    try src.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "Merge side branch", "side" });
    try src.exec(io, &.{ "checkout", "-q", "-b", "other", "main~1" });
    try src.dir.createDirPath(io, "o");
    try src.writeFile(io, "o/file.1.txt", "Other content 1\n");
    try src.writeFile(io, "o/file.2.txt", "Other content 2\n");
    try src.writeFile(io, "cone", "/*\n!/*/\n/a/\n!/a/*/\n/a/b/\n/z/\n");
    try src.exec(io, &.{ "add", "." });
    try src.exec(io, &.{ "commit", "-q", "-m", "Other commit" });
    try src.exec(io, &.{ "checkout", "-q", "main" });

    var tmp = testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    const root = try testremote.absolutePath(gpa, io, tmp.dir);
    defer gpa.free(root);
    const source = try testremote.absolutePath(gpa, io, src.dir);
    defer gpa.free(source);
    const bare = try gpa.print("{s}/srv.git", .{root});
    defer gpa.free(bare);
    try src.exec(io, &.{ "clone", "-q", "--bare", source, bare });
    try src.exec(io, &.{ "--git-dir", bare, "config", "uploadpack.allowFilter", "true" });
    try src.exec(io, &.{ "--git-dir", bare, "config", "uploadpack.allowAnySHA1InWant", "true" });
    var env = try testremote.environ(gpa);
    errdefer env.deinit();
    return .{ .tmp = tmp, .url = try gpa.print("file://{s}", .{bare}), .env = env };
}

/// One backfill each way, from clones made and set up alike.
const Case = struct {
    /// What `git clone` is given besides the filter.
    clone: []const []const u8 = &.{"--no-checkout"},
    /// git commands run in both clones before the backfill.
    setup: []const []const []const u8 = &.{},
    /// `git backfill`'s arguments.
    args: []const []const u8 = &.{},
    inputs: backfill.Inputs = .{},
    paths: []const []const u8 = &.{},
    options: backfill.Options = .{},
};

const Twins = struct {
    tmp: testing.TmpDir,
    by_git: Io.Dir,
    by_relic: Io.Dir,

    fn init(gpa: Allocator, io: Io, server: *Server, format: testgit.RefFormat, case: Case) !Twins {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for ([_][]const u8{ "by-git", "by-relic" }) |name| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.appendSlice(gpa, &.{ "clone", "-q", "--filter=blob:none" });
            try argv.appendSlice(gpa, format.initArgs());
            try argv.appendSlice(gpa, case.clone);
            try argv.appendSlice(gpa, &.{ server.url, name });
            gpa.free(try testremote.gitInputEnv(gpa, io, tmp.dir, &server.env, argv.items, "", true));
        }
        const twins: Twins = .{
            .tmp = tmp,
            .by_git = try tmp.dir.openDir(io, "by-git", .{ .iterate = true }),
            .by_relic = try tmp.dir.openDir(io, "by-relic", .{ .iterate = true }),
        };
        for (case.setup) |args| {
            for ([_]Io.Dir{ twins.by_git, twins.by_relic }) |dir| gpa.free(try testremote.gitInputEnv(gpa, io, dir, &server.env, args, "", true));
        }
        return twins;
    }

    fn deinit(t: *Twins, io: Io) void {
        t.by_git.close(io);
        t.by_relic.close(io);
        t.tmp.cleanup();
        t.* = undefined;
    }
};

fn sortedLines(gpa: Allocator, text: []const u8, column: ?usize) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (column) |c| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            for (0..c) |_| _ = words.next();
            try lines.append(gpa, words.next().?);
        } else try lines.append(gpa, line);
    }
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    return std.mem.join(gpa, "\n", lines.items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Each pack's objects, a pack to a paragraph, the packs sorted.
fn packs(gpa: Allocator, io: Io, server: *Server, dir: Io.Dir) ![]u8 {
    var pack_dir = try dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var each: std.ArrayList([]u8) = .empty;
    defer {
        for (each.items) |p| gpa.free(p);
        each.deinit(gpa);
    }
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const idx = try pack_dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        defer gpa.free(idx);
        const listed = try testremote.gitInputEnv(gpa, io, dir, &server.env, &.{"show-index"}, idx, true);
        defer gpa.free(listed);
        try each.append(gpa, try sortedLines(gpa, listed, 1));
    }
    std.mem.sort([]u8, each.items, {}, struct {
        fn f(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f);
    return std.mem.join(gpa, "\n--\n", each.items);
}

fn expectSame(gpa: Allocator, io: Io, server: *Server, twins: *Twins) !void {
    var outputs: [2][2][]u8 = undefined;
    for ([_]Io.Dir{ twins.by_git, twins.by_relic }, 0..) |dir, i| {
        const listed = try testremote.gitInputEnv(gpa, io, dir, &server.env, &.{ "rev-list", "--objects", "--missing=print", "--all" }, "", true);
        defer gpa.free(listed);
        outputs[i][0] = try sortedLines(gpa, listed, null);
        outputs[i][1] = try packs(gpa, io, server, dir);
    }
    defer for (outputs) |pair| for (pair) |o| gpa.free(o);
    try testing.expectEqualStrings(outputs[0][0], outputs[1][0]);
    try testing.expectEqualStrings(outputs[0][1], outputs[1][1]);
}

fn run(gpa: Allocator, io: Io, server: *Server, format: testgit.RefFormat, case: Case) !void {
    var twins = try Twins.init(gpa, io, server, format, case);
    defer twins.deinit(io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "backfill");
    try argv.appendSlice(gpa, case.args);
    gpa.free(try testremote.gitInputEnv(gpa, io, twins.by_git, &server.env, argv.items, "", true));

    var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
    defer repo.deinit(io);
    var paths = try pathspec.parse(gpa, case.paths);
    defer paths.deinit();
    var inputs = case.inputs;
    if (case.paths.len != 0) inputs.paths = &paths;
    var options = case.options;
    options.lazy.programs = .{ .environ = &server.env };
    const said = try std.mem.join(gpa, " ", argv.items);
    defer gpa.free(said);
    _ = backfill.backfill(gpa, io, &repo, inputs, options) catch |err| {
        std.debug.print("{s}: {t}\n", .{ said, err });
        return err;
    };
    expectSame(gpa, io, server, &twins) catch |err| {
        std.debug.print("{s} differs\n", .{said});
        return err;
    };
}

fn requireBackfill(io: Io) !void {
    try testgit.requireGitVersion(testing.allocator, io, 2, 55);
}

test "backfill fetches what git's does, in git's batches: HEAD, ranges with and without their edges, all branches, the first parent" {
    try requireBackfill(testing.io);
    try testgit.eachRefFormat(struct {
        fn f(format: testgit.RefFormat) !void {
            const gpa = testing.allocator;
            const io = testing.io;
            var server = try served(gpa, io);
            defer server.deinit(gpa);
            for ([_]Case{
                .{},
                .{ .args = &.{"--min-batch-size=5"}, .options = .{ .min_batch_size = 5 } },
                .{ .args = &.{ "--min-batch-size=1", "main~3..main" }, .inputs = .{ .include = &.{"main"}, .exclude = &.{"main~3"} }, .options = .{ .min_batch_size = 1 } },
                .{ .args = &.{ "--no-include-edges", "main~3..main" }, .inputs = .{ .include = &.{"main"}, .exclude = &.{"main~3"} }, .options = .{ .include_edges = false } },
                .{ .args = &.{ "--min-batch-size=1", "origin/other", "^main" }, .inputs = .{ .include = &.{"origin/other"}, .exclude = &.{"main"} }, .options = .{ .min_batch_size = 1 } },
                .{ .args = &.{ "--min-batch-size=1", "main", "^origin/side" }, .inputs = .{ .include = &.{"main"}, .exclude = &.{"origin/side"} }, .options = .{ .min_batch_size = 1 } },
                .{ .args = &.{ "--min-batch-size=3", "main", "origin/side", "origin/other" }, .inputs = .{ .include = &.{ "main", "origin/side", "origin/other" } }, .options = .{ .min_batch_size = 3 } },
                .{ .args = &.{ "--first-parent", "--min-batch-size=1", "main" }, .inputs = .{ .include = &.{"main"} }, .options = .{ .first_parent = true, .min_batch_size = 1 } },
                .{ .args = &.{ "--first-parent", "--min-batch-size=1", "main", "^main~4" }, .inputs = .{ .include = &.{"main"}, .exclude = &.{"main~4"} }, .options = .{ .first_parent = true, .min_batch_size = 1 } },
            }) |case| try run(gpa, io, &server, format, case);
        }
    }.f);
}

test "backfill under a pathspec walks the commits and the paths git's does, plain paths compared as git compares them" {
    try requireBackfill(testing.io);
    const gpa = testing.allocator;
    const io = testing.io;
    var server = try served(gpa, io);
    defer server.deinit(gpa);
    for ([_]Case{
        .{ .args = &.{ "--min-batch-size=1", "--", "d/f" }, .paths = &.{"d/f"}, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--min-batch-size=1", "--", "d/f", "a" }, .paths = &.{ "d/f", "a" }, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--min-batch-size=1", "--", "d/file.*.txt" }, .paths = &.{"d/file.*.txt"}, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--min-batch-size=1", "--", "a/b/file.1.txt", "z/dup" }, .paths = &.{ "a/b/file.1.txt", "z/dup" }, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--", "d/" }, .paths = &.{"d/"} },
        .{ .args = &.{ "--", "." }, .paths = &.{"."} },
        .{ .args = &.{ "--min-batch-size=1", "--", ":/a/b" }, .paths = &.{":/a/b"}, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--min-batch-size=1", "--", ":!a" }, .paths = &.{":!a"}, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--min-batch-size=1", "main~2..main", "--", "s" }, .inputs = .{ .include = &.{"main"}, .exclude = &.{"main~2"} }, .paths = &.{"s"}, .options = .{ .min_batch_size = 1 } },
    }) |case| try run(gpa, io, &server, .files, case);
}

test "backfill within the sparse checkout, in cone mode and not, or a sparse:oid filter's cone" {
    try requireBackfill(testing.io);
    const gpa = testing.allocator;
    const io = testing.io;
    var server = try served(gpa, io);
    defer server.deinit(gpa);
    for ([_]Case{
        .{ .clone = &.{"--sparse"}, .args = &.{"--min-batch-size=1"}, .options = .{ .min_batch_size = 1 } },
        .{ .clone = &.{"--sparse"}, .setup = &.{&.{ "sparse-checkout", "set", "d" }}, .args = &.{"--min-batch-size=1"}, .options = .{ .min_batch_size = 1 } },
        .{ .clone = &.{"--sparse"}, .setup = &.{&.{ "sparse-checkout", "set", "a/b", "z" }}, .args = &.{ "--sparse", "--min-batch-size=1" }, .options = .{ .sparse = true, .min_batch_size = 1 } },
        .{ .clone = &.{"--sparse"}, .setup = &.{&.{ "sparse-checkout", "set", "d" }}, .args = &.{"--no-sparse"}, .options = .{ .sparse = false } },
        .{ .setup = &.{ &.{ "sparse-checkout", "set", "--no-cone", "**/file.1.txt" }, &.{ "checkout", "-q", "main" } }, .args = &.{"--min-batch-size=1"}, .options = .{ .min_batch_size = 1 } },
        .{ .setup = &.{ &.{ "sparse-checkout", "set", "--no-cone", "**/file*", "!**/file.1.txt", "/d/" }, &.{ "checkout", "-q", "main" } }, .args = &.{"--min-batch-size=1"}, .options = .{ .min_batch_size = 1 } },
        .{ .setup = &.{ &.{ "sparse-checkout", "set", "--no-cone", "/a/", "/file.2.txt" }, &.{ "checkout", "-q", "main" } }, .args = &.{"--min-batch-size=1"}, .options = .{ .min_batch_size = 1 } },
        .{ .args = &.{ "--min-batch-size=1", "--filter=sparse:oid=origin/other:cone", "--objects" }, .options = .{ .min_batch_size = 1, .filter = "sparse:oid=origin/other:cone" } },
        .{ .args = &.{ "--min-batch-size=1", "--filter=blob:none", "--objects" }, .options = .{ .min_batch_size = 1, .filter = "blob:none" } },
        .{ .args = &.{ "--min-batch-size=1", "--objects", "--filter=combine:tree:0+object:type=blob" }, .options = .{ .min_batch_size = 1, .filter = "combine:tree:0+object:type=blob" } },
    }) |case| try run(gpa, io, &server, .files, case);
}

test "backfill refuses what git refuses: a blob size limit, a filter the path walk lacks, sparse checkout with no patterns, two sets of sparse patterns" {
    try requireBackfill(testing.io);
    const gpa = testing.allocator;
    const io = testing.io;
    var server = try served(gpa, io);
    defer server.deinit(gpa);
    const cases = [_]struct { Case, anyerror }{
        .{ .{ .args = &.{ "--objects", "--filter=blob:limit=10m" }, .options = .{ .filter = "blob:limit=10m" } }, error.BlobSizeLimit },
        .{ .{ .args = &.{ "--objects", "--filter=tree:1" }, .options = .{ .filter = "tree:1" } }, error.FilterNotSupported },
        .{ .{ .args = &.{"--sparse"}, .options = .{ .sparse = true } }, error.NoSparseCheckout },
        .{ .{ .setup = &.{&.{ "config", "core.sparseCheckout", "true" }} }, error.NoSparseCheckout },
        .{ .{ .clone = &.{"--sparse"}, .args = &.{ "--objects", "--filter=sparse:oid=origin/other:cone" }, .options = .{ .filter = "sparse:oid=origin/other:cone" } }, error.SparseFilterWithPatterns },
        .{ .{ .args = &.{ "--objects", "--filter=sparse:oid=main:file.1.txt" }, .options = .{ .filter = "sparse:oid=main:file.1.txt" } }, error.SparseFilterNotCone },
    };
    for (cases) |case| {
        var twins = try Twins.init(gpa, io, &server, .files, case[0]);
        defer twins.deinit(io);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "backfill");
        try argv.appendSlice(gpa, case[0].args);
        try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, twins.by_git, &server.env, argv.items, "", false));
        var repo = try repo_mod.Repository.open(gpa, io, twins.by_relic, .{});
        defer repo.deinit(io);
        var options = case[0].options;
        options.lazy.programs = .{ .environ = &server.env };
        try testing.expectError(case[1], backfill.backfill(gpa, io, &repo, case[0].inputs, options));
        try expectSame(gpa, io, &server, &twins);
    }
}
