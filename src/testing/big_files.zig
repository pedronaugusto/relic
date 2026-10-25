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
const fs = @import("../fs/fs.zig");
const stash = @import("../commit/stash.zig");
const sparse = @import("../patterns.zig").sparse;
const Counting = @import("shakedown").alloc.Counting;

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
    // Every delta kept, its base written ahead of it whatever the order,
    // as git's `write_one` writes it.
    try std.testing.expectEqual(before, try deltaCount(gpa, io, &ours));
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
    // The same big blob twice in one add: written once, the second copy
    // taken back out of the pack.
    try git.writeFile(io, "twin.bin", repeat("\x00\x01\x02 binary ", 20));
    try git.writeFile(io, "big.txt", repeat("a line of text\n", 10));
    // A conversion applies: stored as any other, loose.
    try git.writeFile(io, "conv.txt", repeat("a converted line\n", 10));
    try git.writeFile(io, "small.txt", "small\n");
}

test "git add streams a file past core.bigFileThreshold that nothing converts into a pack, as git's does" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
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
    const outcome = try worktree.addAll(gpa, io, repo.workDirectory().?.get(), .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
    try std.testing.expect(outcome.streamed_pack != null);
    try index.write(io, repo.gitDirectory().get(), "index", .{});

    const their_layout = try objectLayout(gpa, io, &theirs);
    defer gpa.free(their_layout);
    const our_layout = try objectLayout(gpa, io, &ours);
    defer gpa.free(our_layout);
    try std.testing.expectEqualStrings(their_layout, our_layout);

    // A big file whose blob is stored already makes no pack.
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| try r.writeFile(io, "copy.bin", repeat("\x00\x01\x02 binary ", 20));
    try theirs.exec(io, &.{ "add", "-A" });
    const again = try worktree.addAll(gpa, io, repo.workDirectory().?.get(), .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
    try std.testing.expectEqual(null, again.streamed_pack);
    try index.write(io, repo.gitDirectory().get(), "index", .{});
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

test "git add holds no more of a file past core.bigFileThreshold than the pieces it reads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "1024" });
    const big = try gpa.alloc(u8, 3 * 1024 * 1024);
    defer gpa.free(big);
    var x: u64 = 7;
    for (big) |*b| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        b.* = @truncate(x >> 33);
    }
    try git.writeFile(io, "big.bin", big);

    var counting: @import("shakedown").alloc.Counting = .init(gpa);
    const counted = counting.allocator();
    var repo = try repo_mod.Repository.open(counted, io, git.dir, .{});
    defer repo.deinit(io);
    var index = try repo.openIndex(io);
    defer index.deinit();
    const rules = try repo.worktreeRules();
    counting.resetPeak();
    const before = counting.live_bytes;
    const outcome = try worktree.addAll(counted, io, repo.workDirectory().?.get(), .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
    try std.testing.expect(outcome.streamed_pack != null);
    std.testing.expect(counting.peak_bytes - before < big.len / 4) catch |err| {
        std.debug.print("{d} bytes held\n", .{counting.peak_bytes - before});
        return err;
    };
    try index.write(io, repo.gitDirectory().get(), "index", .{});
    const listed = try git.line(io, &.{ "ls-files", "-s" });
    defer gpa.free(listed);
    const named = try git.line(io, &.{ "hash-object", "big.bin" });
    defer gpa.free(named);
    try std.testing.expect(std.mem.find(u8, listed, named) != null);
    const content = try git.run(io, &.{ "cat-file", "blob", named });
    defer gpa.free(content);
    try std.testing.expectEqualSlices(u8, big, content);
}

/// Text past the threshold whose lines and `$Id`s each conversion meets:
/// a `$$Id$` the stream's `ident` keeps and the in-core one expands, an
/// expansion of another blob's, a foreign `$Id: … $`, one a newline cuts,
/// a `$Id` cut short and one at the very end, a lone CR, CRLFs.
const ident_text = "first $Id$ line\n$$Id$ doubled\nstale $Id: 0123abcd $ here\nforeign $Id: kept as it is $\n" ++
    "spanning $Id: cut\nby a newline $Id$\nnear $Idx miss\ncr\ralone\ncrlf\r\ncr cr\r\r\n" ++
    repeat("padding line to pass the threshold and the cap\n", 48) ++ "end $Id";

const Checkout = struct {
    attributes: []const u8,
    files: []const []const u8,
    /// `odb.Options.max_object_bytes`: below the files', what streams is
    /// never read whole.
    max_object_bytes: ?usize = null,
    config: []const []const u8 = &.{},
    text: []const u8 = ident_text,
};

/// git checks the files out (`git checkout -- .`), then relic does, by
/// `reset --hard` and by a forced checkout of the tree, each over the
/// files taken away; every file is git's byte for byte.
fn checkoutAsGit(gpa: Allocator, io: Io, case: Checkout) !void {
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    // `core.autocrlf` as the repository sets it, where relic reads it.
    git.defaults = &testgit.settings_without_autocrlf;
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "64" });
    for (case.config) |setting| {
        const eq = std.mem.findScalar(u8, setting, '=').?;
        try git.exec(io, &.{ "config", setting[0..eq], setting[eq + 1 ..] });
    }
    // The files stored as written, before any attribute converts them on
    // the way in: their CRLFs and expanded `$Id`s are the blobs'.
    for (case.files) |path| try git.writeFile(io, path, case.text);
    try git.writeFile(io, "small.txt", "small $$Id$ and $Id$ and $Id: stale$\r\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "files" });
    try git.writeFile(io, ".gitattributes", case.attributes);
    try git.exec(io, &.{ "add", ".gitattributes" });
    try git.exec(io, &.{ "commit", "-q", "-m", "attributes" });
    for (case.files) |path| try git.dir.deleteFile(io, path);
    try git.dir.deleteFile(io, "small.txt");
    try git.exec(io, &.{ "checkout", "--", "." });
    var expected: std.ArrayList([]u8) = .empty;
    defer {
        for (expected.items) |bytes| gpa.free(bytes);
        expected.deinit(gpa);
    }
    const all = try std.mem.concat(gpa, []const u8, &.{ case.files, &.{"small.txt"} });
    defer gpa.free(all);
    for (all) |path| try expected.append(gpa, try git.readFile(io, path));

    var odb_options: @import("../odb/odb.zig").Options = .{};
    if (case.max_object_bytes) |max| odb_options.max_object_bytes = .fromRaw(max);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{ .odb = odb_options });
    defer repo.deinit(io);
    const tree = try repo.commitTree(io, try oidOf(gpa, io, &git, "HEAD"));
    for ([_]bool{ false, true }) |by_checkout| {
        for (all) |path| try git.dir.deleteFile(io, path);
        var locked = try repo.lockIndex(io);
        defer locked.deinit(io);
        if (by_checkout) {
            var attrs = try repo.loadAttrs(io);
            defer attrs.deinit();
            var rules = try repo.worktreeRules();
            rules.attrs = &attrs;
            _ = try worktree.checkout(gpa, io, git.dir, .{ .index = &locked.index, .db = repo.objectDatabase(), .tree = tree }, .{ .force = true, .rules = rules });
        } else {
            try @import("../commit/reset.zig").toTree(gpa, io, &repo, .{ .index = &locked.index, .tree = tree, .mode = .hard });
        }
        for (all, expected.items) |path, want| {
            const got = try git.readFile(io, path);
            defer gpa.free(got);
            std.testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("{s}, {s}\n", .{ path, if (by_checkout) "checkout" else "reset --hard" });
                return err;
            };
        }
    }
}

test "a checkout writes a file past core.bigFileThreshold through git's stream filters, read as it is written" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const streamed = [_][]const u8{ "plain.txt", "crlf.txt", "ident.txt", "both.txt", "lf.txt", "binary.txt" };
    const attributes =
        \\crlf.txt text eol=crlf
        \\ident.txt ident
        \\both.txt ident text eol=crlf
        \\lf.txt text eol=lf
        \\binary.txt -text
        \\small.txt ident
        \\
    ;
    // Under a cap below every file's length: nothing streamed is read
    // whole.
    try checkoutAsGit(gpa, io, .{ .attributes = attributes, .files = &streamed, .max_object_bytes = 1024 });
    // A CR held at the very end is written.
    try checkoutAsGit(gpa, io, .{ .attributes = "*.txt ident eol=crlf\n", .files = &.{"tail.txt"}, .text = ident_text ++ "\nlast\r", .max_object_bytes = 1024 });
    // core.autocrlf=input streams as LF; core.eol=crlf makes `text` CRLF.
    try checkoutAsGit(gpa, io, .{ .attributes = "*.txt text\n", .files = &.{"text.txt"}, .config = &.{"core.eol=crlf"}, .max_object_bytes = 1024 });
    try checkoutAsGit(gpa, io, .{ .attributes = "", .files = &.{"plain.txt"}, .config = &.{"core.autocrlf=input"}, .max_object_bytes = 1024 });
}

test "a checkout reads a file past core.bigFileThreshold whole where its conversion needs all of it, as git's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // text=auto and core.autocrlf=true decide by the whole file: git's
    // in-core conversions, `$$Id$` expanded.
    try checkoutAsGit(gpa, io, .{ .attributes = "auto.txt text=auto eol=crlf ident\n", .files = &.{"auto.txt"} });
    try checkoutAsGit(gpa, io, .{ .attributes = "plain.txt ident\n", .files = &.{"plain.txt"}, .config = &.{"core.autocrlf=true"} });
    // Past the cap, such a file is refused.
    try std.testing.expectError(error.ObjectTooLarge, checkoutAsGit(gpa, io, .{ .attributes = "auto.txt text=auto ident\n", .files = &.{"auto.txt"}, .config = &.{"core.autocrlf=true"}, .max_object_bytes = 1024 }));
}

/// How long the tracked file past the threshold is: hashed as git's
/// `index_fd` hashes it, in pieces, it is never held, and the bound below
/// half of it is above what a deflater, an inflater and a pack writer hold
/// whatever the length.
const tracked_len = 4 << 20;

/// `tracked_len` bytes of lines, `changed` altering one byte; the caller's.
fn trackedText(gpa: Allocator, changed: bool) ![]u8 {
    const line = "a line of a tracked file past the threshold\n";
    const text = try gpa.alloc(u8, tracked_len);
    for (text, 0..) |*byte, i| byte.* = line[i % line.len];
    if (changed) text[100] = 'X';
    return text;
}

/// `big.txt` committed past a 1 KiB `core.bigFileThreshold`.
fn trackedBig(gpa: Allocator, io: Io, git: *testgit.Repo) !void {
    try git.exec(io, &.{ "config", "core.bigFileThreshold", "1k" });
    const text = try trackedText(gpa, false);
    defer gpa.free(text);
    try git.writeFile(io, "big.txt", text);
    try git.writeFile(io, "small.txt", "small\n");
    try git.exec(io, &.{ "add", "big.txt", "small.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "big" });
}

/// `big.txt` written again, one line changed or not, its time set to
/// `secs`: the stat no longer vouches for it.
fn rewriteBig(gpa: Allocator, io: Io, git: *testgit.Repo, changed: bool, secs: i64) !void {
    const text = try trackedText(gpa, changed);
    defer gpa.free(text);
    try git.writeFile(io, "big.txt", text);
    try fs.setTimestamps(io, git.dir, "big.txt", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, secs) * std.time.ns_per_s } } });
}

test "status and a working-tree comparison name a tracked file past core.bigFileThreshold as git's index_fd does, reading it in pieces" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try trackedBig(gpa, io, &git);

    // On one task, so the peak is counted.
    var single: Io.Threaded = .init_single_threaded;
    const one = single.io();
    var counting: Counting = .init(gpa);
    const counted = counting.allocator();
    var repo = try repo_mod.Repository.open(counted, one, git.dir, .{});
    defer repo.deinit(one);
    var index = try repo.openIndex(one);
    defer index.deinit();
    const rules = try repo.worktreeRules();
    const entry = index.find("big.txt").?.*;

    for ([_]bool{ false, true }, 0..) |changed, i| {
        try rewriteBig(gpa, io, &git, changed, 1_000_000_000 + @as(i64, @intCast(i)));
        counting.resetPeak();
        const before = counting.live_bytes;
        const differs = try worktree.differsFromIndex(counted, one, git.dir, .{ .index = &index, .entry = entry }, rules);
        var status = try worktree.status(counted, one, git.dir, .{ .index = &index, .db = repo.objectDatabase() }, .{ .rules = rules });
        defer status.deinit();
        try std.testing.expect(counting.peak_bytes - before < tracked_len / 2);
        try std.testing.expectEqual(changed, differs);
        var ours: worktree.Change = .unmodified;
        for (status.entries) |e| {
            if (std.mem.eql(u8, e.path, "big.txt")) ours = e.unstaged;
        }
        try std.testing.expectEqual(if (changed) worktree.Change.modified else .unmodified, ours);
        const theirs = try git.run(io, &.{ "status", "--porcelain" });
        defer gpa.free(theirs);
        try std.testing.expectEqualStrings(if (changed) " M big.txt\n" else "", theirs);
    }
}

test "a sparse checkout compares a racy file past core.bigFileThreshold as it reads it before it removes it, as git's verify_uptodate" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |changed| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try trackedBig(gpa, io, &git);
        // The stat compared by its size and whole-second time alone, so a
        // file changed in place keeps a stat that matches.
        try git.exec(io, &.{ "config", "core.checkStat", "minimal" });
        try git.exec(io, &.{ "config", "core.trustCtime", "false" });

        var single: Io.Threaded = .init_single_threaded;
        const one = single.io();
        var counting: Counting = .init(gpa);
        const counted = counting.allocator();
        var repo = try repo_mod.Repository.open(counted, one, git.dir, .{});
        defer repo.deinit(one);
        var index = try repo.openIndex(one);
        defer index.deinit();
        const entry = index.find("big.txt").?.*;
        if (changed) {
            try rewriteBig(gpa, io, &git, true, entry.stat.mtime_sec);
        }
        // Every entry racy: only the content can say the file is the index's.
        index.racy_cutoff_sec = 1;
        index.racy_cutoff_nsec = 0;
        var patterns = try sparse.Patterns.fromText(counted, "/*\n!/big.txt\n", .{ .case_fold = false });
        defer patterns.deinit();
        counting.resetPeak();
        const before = counting.live_bytes;
        const outcome = try worktree.applySparse(counted, one, git.dir, .{ .index = &index, .db = repo.objectDatabase(), .patterns = &patterns }, .{ .rules = try repo.worktreeRules() });
        try std.testing.expect(counting.peak_bytes - before < tracked_len / 2);
        // Unchanged, it goes; changed, it stays, the work in it kept.
        try std.testing.expectEqual(@as(u32, if (changed) 1 else 0), outcome.kept_dirty);
        try std.testing.expectEqual(@as(u32, if (changed) 0 else 1), outcome.skipped);
        try std.testing.expectEqual(changed, if (git.dir.access(io, "big.txt", .{})) |_| true else |_| false);
    }
}

test "stash writes a file past core.bigFileThreshold that nothing converts into a pack as it reads it, as git's stash adds it" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    var ours = try testgit.Repo.init(gpa, io, &.{});
    defer ours.deinit();
    const untracked = try trackedText(gpa, true);
    defer gpa.free(untracked);
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
        try trackedBig(gpa, io, r);
        try rewriteBig(gpa, io, r, true, 1_000_000_000);
        try r.writeFile(io, "new.txt", untracked);
    }
    try theirs.exec(io, &.{ "stash", "push", "-q", "-u" });

    var single: Io.Threaded = .init_single_threaded;
    const one = single.io();
    var counting: Counting = .init(gpa);
    const counted = counting.allocator();
    var repo = try repo_mod.Repository.open(counted, one, ours.dir, .{});
    defer repo.deinit(one);
    const who: @import("../object/object.zig").Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };
    counting.resetPeak();
    const before = counting.live_bytes;
    _ = (try stash.push(one, &repo, .{ .who = who, .untracked = .include })).?;
    try std.testing.expect(counting.peak_bytes - before < tracked_len / 2);

    // The working tree's and the untracked files' trees are git's.
    for ([_][]const u8{ "stash^{tree}", "stash^3^{tree}" }) |rev| {
        const want = try theirs.line(io, &.{ "rev-parse", rev });
        defer gpa.free(want);
        const got = try ours.line(io, &.{ "rev-parse", rev });
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
    const checked = try ours.run(io, &.{ "fsck", "--full", "--strict", "--no-dangling" });
    gpa.free(checked);
    // Written into a pack, as git's are.
    const counted_objects = try ours.run(io, &.{ "count-objects", "-v" });
    defer gpa.free(counted_objects);
    try std.testing.expect(std.mem.find(u8, counted_objects, "packs: 0\n") == null);
}
