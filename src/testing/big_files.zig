//! `core.bigFileThreshold` against git 2.55: a file past it is binary to
//! `git diff` unless its driver says text; a repack never deltifies a blob
//! past it, though it reuses a delta a pack holds for one; and `git add`
//! streams such a file into a pack of its own where nothing would convert
//! it, every other file going loose.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repeat = @import("shakedown").corpus.repeat;
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const driver = @import("../diff/driver.zig");
const repack_mod = @import("../maintenance/repack.zig");
const worktree = @import("../checkout/checkout.zig");
const hash = @import("../hash/hash.zig");

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !hash.Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return hash.Oid.parse(.sha1, text);
}

test "a file past core.bigFileThreshold is binary to git diff, unless its driver says text" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "100" });
    try git.writeFile(io, ".gitattributes", "forced.txt diff\n");
    // Exactly the threshold is not past it.
    try git.writeFile(io, "edge.txt", repeat("012345678\n", 10));
    try git.writeFile(io, "big.txt", repeat("a line of text\n", 10));
    try git.writeFile(io, "forced.txt", repeat("a line of text\n", 10));
    try git.writeFile(io, "small.txt", "one\ntwo\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.writeFile(io, "edge.txt", repeat("012345678\n", 9) ++ "ABCDEFGH\n\n");
    try git.writeFile(io, "big.txt", repeat("a line of text\n", 9) ++ "the last line\n");
    try git.writeFile(io, "forced.txt", repeat("a line of text\n", 9) ++ "the last line\n");
    try git.writeFile(io, "small.txt", "one\nTWO\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    const db = repo.objectDatabase();
    const old = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD~1"));
    const new = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD"));
    var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = new }, .{});
    defer changes.deinit();
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = git.dir, .config = repo.configuration() };
    // `--binary` reads both sides for the `index` line before it asks, so
    // the size decides nothing -- unless a stat asked first.
    const Case = struct { args: []const []const u8, options: diff.Options };
    const cases = [_]Case{
        .{ .args = &.{ "diff", "--no-color", "HEAD~1", "HEAD" }, .options = .{} },
        .{ .args = &.{ "diff", "--no-color", "--binary", "HEAD~1", "HEAD" }, .options = .{ .binary_patches = true } },
        .{ .args = &.{ "diff", "--no-color", "--stat", "-p", "--binary", "HEAD~1", "HEAD" }, .options = .{ .binary_patches = true, .after_stat = true } },
    };
    for (cases) |case| {
        const output = try git.run(io, case.args);
        defer gpa.free(output);
        // The patch, past any stat.
        const theirs = output[std.mem.find(u8, output, "diff --git").?..];
        var mine: Io.Writer.Allocating = .init(gpa);
        defer mine.deinit();
        try diff.unified(gpa, io, &mine.writer, .{ .db = db, .changes = changes.items, .drivers = drivers }, case.options);
        // A binary patch's hunks are relic's encoder's, not git's (see
        // `diff/binary.zig`): which files are binary patches is compared.
        const their_shape = try withoutBinaryHunks(gpa, theirs);
        defer gpa.free(their_shape);
        const our_shape = try withoutBinaryHunks(gpa, mine.written());
        defer gpa.free(our_shape);
        std.testing.expectEqualStrings(their_shape, our_shape) catch |err| {
            std.debug.print("git {any}\n", .{case.args});
            return err;
        };
    }
}

/// `patch` with each `GIT binary patch` line's hunks left out, to the next
/// file's `diff --git` line.
fn withoutBinaryHunks(gpa: Allocator, patch: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_hunks = false;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git")) in_hunks = false;
        if (in_hunks) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
        if (std.mem.eql(u8, line, "GIT binary patch")) in_hunks = true;
    }
    return out.toOwnedSlice(gpa);
}

/// How many objects `git verify-pack -v` lists as deltas, over every pack.
fn deltaCount(gpa: Allocator, io: Io, git: *testgit.Repo) !usize {
    var pack_dir = try git.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var count: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const path = try std.mem.concat(gpa, u8, &.{ ".git/objects/pack/", entry.name });
        defer gpa.free(path);
        const listed = try git.run(io, &.{ "verify-pack", "-v", path });
        defer gpa.free(listed);
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        // A delta's line has seven fields: its depth and base last.
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            var n: usize = 0;
            while (fields.next()) |_| n += 1;
            if (n == 7) count += 1;
        }
    }
    return count;
}

/// Twelve versions of one file, each `size` bytes, a commit each.
fn versions(io: Io, git: *testgit.Repo, size: usize) !void {
    const gpa = git.gpa;
    for (0..12) |i| {
        const text = try gpa.alloc(u8, size);
        defer gpa.free(text);
        @memset(text, 'x');
        for (0..size / 10) |line| text[line * 10 + 9] = '\n';
        text[3] = '0' + @as(u8, @intCast(i % 10));
        text[size - 1] = '\n';
        try git.writeFile(io, "f", text);
        try git.exec(io, &.{ "add", "f" });
        try git.exec(io, &.{ "commit", "-q", "-m", "version" });
    }
}

test "a repack deltifies no blob past core.bigFileThreshold and reuses a delta a pack holds for one, as git's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Past the threshold, nothing; at it, deltas.
    for ([_]struct { []const u8, bool }{ .{ "199", false }, .{ "200", true } }) |case| {
        var theirs = try testgit.Repo.init(gpa, io, &.{});
        defer theirs.deinit();
        var ours = try testgit.Repo.init(gpa, io, &.{});
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            try versions(io, r, 200);
            try r.exec(io, &.{ "config", "core.bigFileThreshold", case[0] });
        }
        try theirs.exec(io, &.{ "repack", "-q", "-a", "-d", "-f" });
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var pack_options = native.objectDatabase().packOptions();
        pack_options.threads = 1;
        pack_options.reuse_packed = false;
        _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .pack = pack_options });
        const their_deltas = try deltaCount(gpa, io, &theirs);
        const our_deltas = try deltaCount(gpa, io, &ours);
        try std.testing.expectEqual(case[1], their_deltas != 0);
        try std.testing.expectEqual(case[1], our_deltas != 0);
    }

    // Deltified first, then past the threshold: the deltas stay.
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    var ours = try testgit.Repo.init(gpa, io, &.{});
    defer ours.deinit();
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
        try versions(io, r, 200);
        try r.exec(io, &.{ "repack", "-q", "-a", "-d", "-f" });
        try r.exec(io, &.{ "config", "core.bigFileThreshold", "100" });
    }
    const before = try deltaCount(gpa, io, &theirs);
    try std.testing.expect(before != 0);
    try theirs.exec(io, &.{ "repack", "-q", "-a", "-d" });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    var pack_options = native.objectDatabase().packOptions();
    pack_options.threads = 1;
    _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .pack = pack_options });
    try std.testing.expectEqual(before, try deltaCount(gpa, io, &theirs));
    // relic reuses a delta whose base its write order puts first; git
    // writes a base ahead of its delta whatever the order, and keeps all.
    const kept = try deltaCount(gpa, io, &ours);
    try std.testing.expect(kept != 0 and kept <= before);
}

/// Where the objects are, sorted, one a line: each loose object's path,
/// each pack's files by their kind (relic deflates with its own encoder,
/// so a pack's name, its checksum, is not git's), and each pack's objects
/// in its order as `git verify-pack -v` lists them, name, type and size.
fn objectLayout(gpa: Allocator, io: Io, git: *testgit.Repo) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var objects = try git.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var walker = try objects.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "pack" ++ std.Io.Dir.path.sep_str)) {
            try names.append(gpa, try gpa.dupe(u8, entry.path));
            continue;
        }
        const ext = std.Io.Dir.path.extension(entry.path);
        try names.append(gpa, try std.mem.concat(gpa, u8, &.{ "pack/*", ext }));
        if (!std.mem.eql(u8, ext, ".idx")) continue;
        const idx = try std.mem.concat(gpa, u8, &.{ ".git/objects/", entry.path });
        defer gpa.free(idx);
        const listed = try git.run(io, &.{ "verify-pack", "-v", idx });
        defer gpa.free(listed);
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const name = fields.next() orelse continue;
            if (name.len != 40) continue;
            const kind = fields.next().?;
            const size = fields.next().?;
            try names.append(gpa, try gpa.print("pack object {d}: {s} {s} {s}", .{ n, name, kind, size }));
            n += 1;
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (names.items) |n| {
        try out.appendSlice(gpa, n);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn bigFiles(io: Io, git: *testgit.Repo) !void {
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "100" });
    try git.writeFile(io, ".gitattributes", "conv.txt text\n");
    try git.writeFile(io, "big.bin", repeat("\x00\x01\x02 binary ", 20));
    try git.writeFile(io, "big.txt", repeat("a line of text\n", 10));
    // A conversion applies: stored as any other, loose.
    try git.writeFile(io, "conv.txt", repeat("a converted line\n", 10));
    try git.writeFile(io, "small.txt", "small\n");
}

test "git add streams a file past core.bigFileThreshold that nothing converts into a pack, as git's does" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    var ours = try testgit.Repo.init(gpa, io, &.{});
    defer ours.deinit();
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| try bigFiles(io, r);
    try theirs.exec(io, &.{ "add", "-A" });

    var repo = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    const outcome = try worktree.addAll(gpa, io, repo.workDirectory().?, .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
    try std.testing.expect(outcome.streamed_pack != null);
    try index.write(io, repo.gitDirectory(), "index", .{});

    const their_layout = try objectLayout(gpa, io, &theirs);
    defer gpa.free(their_layout);
    const our_layout = try objectLayout(gpa, io, &ours);
    defer gpa.free(our_layout);
    try std.testing.expectEqualStrings(their_layout, our_layout);

    // A big file whose blob is stored already makes no pack.
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| try r.writeFile(io, "copy.bin", repeat("\x00\x01\x02 binary ", 20));
    try theirs.exec(io, &.{ "add", "-A" });
    const again = try worktree.addAll(gpa, io, repo.workDirectory().?, .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
    try std.testing.expectEqual(null, again.streamed_pack);
    try index.write(io, repo.gitDirectory(), "index", .{});
    const their_again = try objectLayout(gpa, io, &theirs);
    defer gpa.free(their_again);
    const our_again = try objectLayout(gpa, io, &ours);
    defer gpa.free(our_again);
    try std.testing.expectEqualStrings(their_again, our_again);
    const their_index = try theirs.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(their_index);
    const our_index = try ours.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(our_index);
    try std.testing.expectEqualStrings(their_index, our_index);
}
