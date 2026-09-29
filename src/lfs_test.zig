//! relic's own LFS against git-lfs: the pointers, the store and the files
//! checked out, in both directions.
//!
//! Every test here wants git-lfs as well as git, and stands aside without
//! it. None of them hands relic a `Programs` except the one that runs
//! git-lfs as relic's filter process, because relic's own LFS runs none.

const std = @import("std");
const Io = std.Io;

const testgit = @import("testgit.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const filter = @import("filter.zig");
const lfs = @import("lfs.zig");
const ft = @import("filter_test.zig");

const testing = std.testing;

var lfs_checked = false;
var lfs_present = false;

/// `error.SkipZigTest` unless `git lfs` runs.
fn requireGitLfs(gpa: std.mem.Allocator, io: Io) !void {
    try testgit.requireGit(gpa, io);
    if (!lfs_checked) {
        lfs_checked = true;
        var environ = try testgit.isolatedEnviron(gpa, testgit.no_home);
        defer environ.deinit();
        const result = std.process.run(gpa, io, .{ .argv = &.{ "git", "lfs", "version" }, .environ_map = &environ }) catch return error.SkipZigTest;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        lfs_present = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
    if (!lfs_present) return error.SkipZigTest;
}

const attributes_line = "*.bin filter=lfs diff=lfs merge=lfs -text\n";

/// Two hundred kilobytes that do not compress to nothing.
fn bigContent(gpa: std.mem.Allocator) ![]u8 {
    const bytes = try gpa.alloc(u8, 200 * 1024);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    prng.random().bytes(bytes);
    return bytes;
}

const small_pointer = "version https://git-lfs.github.com/spec/v1\n" ++
    "oid sha256:5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\nsize 6\n";

/// Two repositories set up by `git lfs install`, holding the same files.
fn lfsTwin(gpa: std.mem.Allocator, io: Io, big: []const u8, extra_config: []const [2][]const u8) !ft.Twin {
    var twin = try ft.Twin.init(gpa, io, extra_config, &.{
        .{ ".gitattributes", attributes_line },
        .{ "big.bin", big },
        .{ "small.bin", "hello\n" },
        .{ "empty.bin", "" },
        // A pointer checked in as a file is stored as it is.
        .{ "dir/already.bin", small_pointer },
        .{ "plain.txt", "not large\n" },
    });
    errdefer twin.deinit();
    for ([_]*testgit.Repo{ &twin.ours, &twin.theirs }) |r| {
        try r.exec(io, &.{ "lfs", "install", "--local", "--skip-repo" });
    }
    return twin;
}

fn objectPath(buf: []u8, root: []const u8, oid: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".git/{s}/objects/{s}/{s}/{s}", .{ root, oid[0..2], oid[2..4], oid }) catch unreachable;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;
    return out;
}

test "relic's own LFS stores what git-lfs stores, and git-lfs reads it back" {
    const gpa = testing.allocator;
    const io = testing.io;
    try requireGitLfs(gpa, io);
    const big = try bigContent(gpa);
    defer gpa.free(big);
    var twin = try lfsTwin(gpa, io, big, &.{});
    defer twin.deinit();

    try twin.theirs.exec(io, &.{ "add", "-A" });
    const theirs_tree = try ft.treeOf(gpa, io, &twin.theirs);
    const ours_tree = try ft.relicAdd(gpa, io, twin.ours.dir, .{});
    try testing.expect(ours_tree.eql(theirs_tree));

    // The pointer is the one git-lfs writes for the file, byte for byte.
    const stored = try twin.ours.run(io, &.{ "cat-file", "blob", ":big.bin" });
    defer gpa.free(stored);
    const pointer = try twin.ours.run(io, &.{ "lfs", "pointer", "--file=big.bin" });
    defer gpa.free(pointer);
    try testing.expectEqualStrings(pointer, stored);
    const empty = try twin.ours.run(io, &.{ "cat-file", "blob", ":empty.bin" });
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
    const already = try twin.ours.run(io, &.{ "cat-file", "blob", ":dir/already.bin" });
    defer gpa.free(already);
    try testing.expectEqualStrings(small_pointer, already);

    // The object is where git-lfs keeps it.
    var path_buf: [256]u8 = undefined;
    const oid = sha256Hex(big);
    const object = try twin.ours.readFile(io, objectPath(&path_buf, "lfs", &oid));
    defer gpa.free(object);
    try testing.expectEqualSlices(u8, big, object);

    // git-lfs finds everything it needs in relic's store.
    for ([_]*testgit.Repo{ &twin.ours, &twin.theirs }) |r| try r.exec(io, &.{ "commit", "-q", "-m", "one" });
    try twin.ours.exec(io, &.{ "lfs", "fsck" });
    const ours_listed = try twin.ours.run(io, &.{ "lfs", "ls-files", "--long" });
    defer gpa.free(ours_listed);
    const theirs_listed = try twin.theirs.run(io, &.{ "lfs", "ls-files", "--long" });
    defer gpa.free(theirs_listed);
    try testing.expectEqualStrings(theirs_listed, ours_listed);

    // And a checkout by git smudges relic's object.
    try twin.ours.dir.deleteFile(io, "big.bin");
    try twin.ours.exec(io, &.{ "checkout", "--", "big.bin" });
    const back = try twin.ours.readFile(io, "big.bin");
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, big, back);
}

test "relic checks out what git-lfs stored, from the store, running nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    try requireGitLfs(gpa, io);
    const big = try bigContent(gpa);
    defer gpa.free(big);
    var twin = try lfsTwin(gpa, io, big, &.{});
    defer twin.deinit();
    for ([_]*testgit.Repo{ &twin.ours, &twin.theirs }) |r| {
        try r.exec(io, &.{ "add", "-A" });
        try r.exec(io, &.{ "commit", "-q", "-m", "one" });
    }
    const tree = try ft.treeOf(gpa, io, &twin.theirs);

    // git-lfs wrote the store in theirs; relic reads it.
    try ft.emptyWorktree(io, twin.theirs.dir);
    var report: filter.Report = .init(gpa);
    defer report.deinit();
    const outcome = try ft.relicCheckout(gpa, io, twin.theirs.dir, tree, .{ .report = &report });
    try testing.expectEqual(@as(u32, 0), outcome.lfs_pointers);
    try testing.expectEqual(@as(usize, 0), report.lfs_missing.items.len);

    try ft.emptyWorktree(io, twin.ours.dir);
    try twin.ours.exec(io, &.{ "checkout", "--", "." });
    for ([_][]const u8{ "big.bin", "small.bin", "empty.bin", "dir/already.bin", "plain.txt", ".gitattributes" }) |path| {
        try ft.expectSameFile(gpa, io, &twin.theirs, &twin.ours, path);
    }
    const back = try twin.theirs.readFile(io, "big.bin");
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, big, back);
    const already = try twin.theirs.readFile(io, "dir/already.bin");
    defer gpa.free(already);
    try testing.expectEqualStrings("hello\n", already);

    // git calls relic's working tree and index clean. (git-lfs lays down a
    // hooks directory where the fixture points `core.hooksPath`, which is
    // why untracked files are not asked about.)
    const status = try twin.theirs.run(io, &.{ "status", "--porcelain", "--untracked-files=no" });
    defer gpa.free(status);
    try testing.expectEqualStrings("", status);
}

/// A fetcher that has the objects in memory.
const MemoryFetcher = struct {
    content: []const u8,
    calls: u32 = 0,
    asked: usize = 0,

    fn fetcher(m: *MemoryFetcher) lfs.Fetcher {
        return .{ .context = m, .fetchFn = fetch };
    }

    fn fetch(
        context: *anyopaque,
        io: Io,
        store: *const lfs.Store,
        settings: *const lfs.Settings,
        wanted: []const lfs.Wanted,
    ) lfs.FetchError!void {
        _ = settings;
        const m: *MemoryFetcher = @ptrCast(@alignCast(context));
        m.calls += 1;
        m.asked += wanted.len;
        for (wanted) |w| {
            var source: Io.Reader = .fixed(m.content);
            _ = store.install(io, &source, &w.pointer) catch return error.LfsFetchFailed;
        }
    }
};

test "an object the store lacks is left as its pointer and named, and a fetcher can bring it" {
    const gpa = testing.allocator;
    const io = testing.io;
    try requireGitLfs(gpa, io);
    const big = try bigContent(gpa);
    defer gpa.free(big);
    var twin = try lfsTwin(gpa, io, big, &.{});
    defer twin.deinit();
    const r = &twin.theirs;
    try r.exec(io, &.{ "add", "-A" });
    const tree = try ft.treeOf(gpa, io, r);
    const pointer = try r.run(io, &.{ "cat-file", "blob", ":big.bin" });
    defer gpa.free(pointer);

    var path_buf: [256]u8 = undefined;
    const oid = sha256Hex(big);
    try r.dir.deleteFile(io, objectPath(&path_buf, "lfs", &oid));

    {
        try ft.emptyWorktree(io, r.dir);
        var report: filter.Report = .init(gpa);
        defer report.deinit();
        const outcome = try ft.relicCheckout(gpa, io, r.dir, tree, .{ .report = &report });
        try testing.expectEqual(@as(u32, 1), outcome.lfs_pointers);
        const left = try r.readFile(io, "big.bin");
        defer gpa.free(left);
        try testing.expectEqualStrings(pointer, left);
        try testing.expectEqual(@as(usize, 1), report.lfs_missing.items.len);
        const missing = report.lfs_missing.items[0];
        try testing.expectEqualStrings("big.bin", missing.path);
        try testing.expectEqualStrings(&oid, &missing.pointer.oid);
        try testing.expect(!missing.declined);
        // A file that is its own pointer compares clean, so git does not
        // call a file relic could not smudge modified.
        const diff = try r.run(io, &.{ "diff", "--stat", "--", "big.bin" });
        defer gpa.free(diff);
        try testing.expectEqualStrings("", diff);
    }
    {
        try ft.emptyWorktree(io, r.dir);
        var memory: MemoryFetcher = .{ .content = big };
        const outcome = try ft.relicCheckout(gpa, io, r.dir, tree, .{ .fetch = memory.fetcher() });
        try testing.expectEqual(@as(u32, 0), outcome.lfs_pointers);
        try testing.expectEqual(@as(u32, 1), memory.calls);
        try testing.expectEqual(@as(usize, 1), memory.asked);
        const back = try r.readFile(io, "big.bin");
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, big, back);
    }
    {
        // Excluded from fetching: not asked for, and named as declined.
        try r.dir.deleteFile(io, objectPath(&path_buf, "lfs", &oid));
        try r.exec(io, &.{ "config", "lfs.fetchexclude", "big*" });
        try ft.emptyWorktree(io, r.dir);
        var memory: MemoryFetcher = .{ .content = big };
        var report: filter.Report = .init(gpa);
        defer report.deinit();
        _ = try ft.relicCheckout(gpa, io, r.dir, tree, .{ .fetch = memory.fetcher(), .report = &report });
        try testing.expectEqual(@as(u32, 0), memory.calls);
        try testing.expect(report.lfs_missing.items[0].declined);
    }
}

test "lfs.storage is honoured, and git-lfs finds the objects there" {
    const gpa = testing.allocator;
    const io = testing.io;
    try requireGitLfs(gpa, io);
    const big = try bigContent(gpa);
    defer gpa.free(big);
    var twin = try lfsTwin(gpa, io, big, &.{.{ "lfs.storage", "elsewhere" }});
    defer twin.deinit();
    try twin.theirs.exec(io, &.{ "add", "-A" });
    const ours_tree = try ft.relicAdd(gpa, io, twin.ours.dir, .{});
    try testing.expect(ours_tree.eql(try ft.treeOf(gpa, io, &twin.theirs)));

    var path_buf: [256]u8 = undefined;
    const oid = sha256Hex(big);
    for ([_]*testgit.Repo{ &twin.ours, &twin.theirs }) |r| {
        const object = try r.readFile(io, objectPath(&path_buf, "elsewhere", &oid));
        defer gpa.free(object);
        try testing.expectEqualSlices(u8, big, object);
    }
    try twin.ours.exec(io, &.{ "commit", "-q", "-m", "one" });
    try twin.ours.exec(io, &.{ "lfs", "fsck" });
}

test "git-lfs run by relic as its filter process does what relic's own LFS does" {
    try ft.skipWithoutSh();
    const gpa = testing.allocator;
    const io = testing.io;
    try requireGitLfs(gpa, io);
    var env = try ft.environ(gpa);
    defer env.deinit();
    const big = try bigContent(gpa);
    defer gpa.free(big);
    var twin = try lfsTwin(gpa, io, big, &.{});
    defer twin.deinit();

    // Ours through git-lfs over the process protocol, theirs in process.
    const through_git_lfs: ft.Run = .{ .programs = .{ .environ = &env }, .drivers = .{ .native_lfs = false } };
    const ours_tree = try ft.relicAdd(gpa, io, twin.ours.dir, through_git_lfs);
    const theirs_tree = try ft.relicAdd(gpa, io, twin.theirs.dir, .{});
    try testing.expect(ours_tree.eql(theirs_tree));

    try ft.emptyWorktree(io, twin.ours.dir);
    _ = try ft.relicCheckout(gpa, io, twin.ours.dir, ours_tree, through_git_lfs);
    try ft.emptyWorktree(io, twin.theirs.dir);
    _ = try ft.relicCheckout(gpa, io, twin.theirs.dir, theirs_tree, .{});
    for ([_][]const u8{ "big.bin", "small.bin", "empty.bin", "dir/already.bin", "plain.txt" }) |path| {
        try ft.expectSameFile(gpa, io, &twin.ours, &twin.theirs, path);
    }
}

test "status names an LFS file by hashing it, and stores nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    try requireGitLfs(gpa, io);
    const big = try bigContent(gpa);
    defer gpa.free(big);
    var twin = try lfsTwin(gpa, io, big, &.{});
    defer twin.deinit();
    const r = &twin.ours;
    _ = try ft.relicAdd(gpa, io, r.dir, .{});
    try r.exec(io, &.{ "commit", "-q", "-m", "one" });

    // The same bytes again, so only the content can say; and a change,
    // whose object must not appear in the store.
    try r.dir.deleteFile(io, "big.bin");
    try r.writeFile(io, "big.bin", big);
    try r.writeFile(io, "small.bin", "changed\n");

    var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, .{});
    defer drivers.deinit();
    var rules = repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    var result = try worktree.status(gpa, io, r.dir, &index, &repo.odb, .{
        .rules = rules,
        .head_tree = try repo.headTree(io),
    });
    defer result.deinit();
    try testing.expect(result.find("big.bin") == null);
    try testing.expectEqual(worktree.Change.modified, result.find("small.bin").?.unstaged);

    var path_buf: [256]u8 = undefined;
    const changed = sha256Hex("changed\n");
    try testing.expectError(error.FileNotFound, r.dir.access(io, objectPath(&path_buf, "lfs", &changed), .{}));
}

test "an LFS extension is refused by name rather than skipped" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.writeFile(io, ".gitattributes", attributes_line);
    try r.writeFile(io, "x.bin", "version https://git-lfs.github.com/spec/v1\n" ++
        "ext-0-foo sha256:0000000000000000000000000000000000000000000000000000000000000001\n" ++
        "oid sha256:5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\nsize 6\n");
    try r.exec(io, &.{ "-c", "filter.lfs.clean=", "add", "-A" });
    const tree = try ft.treeOf(gpa, io, &r);
    try ft.emptyWorktree(io, r.dir);
    try testing.expectError(error.LfsExtensionUnsupported, ft.relicCheckout(gpa, io, r.dir, tree, .{}));

    // A configured extension would change the pointer git-lfs writes, so
    // a clean is refused too.
    try r.exec(io, &.{ "config", "lfs.extension.foo.clean", "foo clean %f" });
    try r.writeFile(io, "y.bin", "large\n");
    try testing.expectError(error.LfsExtensionUnsupported, ft.relicAdd(gpa, io, r.dir, .{}));
}
