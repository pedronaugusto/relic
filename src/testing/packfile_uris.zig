//! Packfile URIs against git 2.56: git's upload-pack, behind git's
//! http-backend, hands blobs `uploadpack.blobPackfileUri` names over as
//! URIs of packs a web server holds, under `sideband-all`, to a client
//! whose `fetch.uriProtocols` takes `http`. git's clone and fetch and this
//! package's take the same packs, the named ones byte for byte; a
//! `.gitmodules` that comes by URI is checked once it is in, as git's
//! `fsck_finish` checks it; a pack that is not the one named is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const testgit = @import("git.zig");
const testremote = @import("remote.zig");
const object = @import("../object/object.zig");
const config_mod = @import("../config/config.zig");
const repo_mod = @import("../repo/repo.zig");
const clone_mod = @import("../transport/clone.zig");
const fetch_mod = @import("../transport/fetch.zig");
const partial = @import("../transport/partial.zig");
const hash_mod = @import("../hash/hash.zig");

const who: object.Signature = .{ .name = "T", .email = "t@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// The packs `path` holds, by name, sorted, one per line; and whether a
/// `.keep`, a `.promisor` or a temporary file is left beside them.
fn packsOf(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const pack_path = try std.Io.Dir.path.join(gpa, &.{ path, ".git", "objects", "pack" });
    defer gpa.free(pack_path);
    var dir = try Io.Dir.cwd().openDir(io, pack_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".keep") or std.mem.endsWith(u8, entry.name, ".promisor") or std.mem.startsWith(u8, entry.name, "tmp_")) {
            try names.append(gpa, try gpa.dupe(u8, entry.name));
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |n| try out.print(gpa, "{s}\n", .{n});
    return out.toOwnedSlice(gpa);
}

/// `oid`'s blob alone, packed into `<root>/<prefix>-<hash>.pack`, and
/// offered by `bare` as that URI. The pack's hash, the caller's.
fn offerByUri(gpa: Allocator, io: Io, src: *testgit.Repo, bare: []const u8, root: []const u8, server: *testremote.HttpServer, path: []const u8, prefix: []const u8, named_hash: ?[]const u8) ![]u8 {
    const spec = try std.mem.concat(gpa, u8, &.{ "HEAD:", path });
    defer gpa.free(spec);
    const oid = try src.line(io, &.{ "rev-parse", spec });
    defer gpa.free(oid);
    const base = try std.Io.Dir.path.join(gpa, &.{ root, prefix });
    defer gpa.free(base);
    const input = try std.mem.concat(gpa, u8, &.{ oid, "\n" });
    defer gpa.free(input);
    const out = try src.runInput(io, &.{ "-C", bare, "pack-objects", "-q", base }, input);
    defer gpa.free(out);
    const hash = std.mem.trimEnd(u8, out, "\n");
    const file = try std.mem.concat(gpa, u8, &.{ "files/", prefix, "-", hash, ".pack" });
    defer gpa.free(file);
    const uri = try server.url(gpa, file);
    defer gpa.free(uri);
    const value = try std.mem.concat(gpa, u8, &.{ oid, " ", named_hash orelse hash, " ", uri });
    defer gpa.free(value);
    try src.exec(io, &.{ "-C", bare, "config", "--add", "uploadpack.blobPackfileUri", value });
    return gpa.dupe(u8, hash);
}

/// Each `.promisor` file `path`'s packs have, by name, with what it says.
fn promisorsOf(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const listing = try packsOf(gpa, io, path);
    defer gpa.free(listing);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |name| {
        if (!std.mem.endsWith(u8, name, ".promisor")) continue;
        const file = try std.Io.Dir.path.join(gpa, &.{ path, ".git", "objects", "pack", name });
        defer gpa.free(file);
        const text = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited);
        defer gpa.free(text);
        try out.print(gpa, "{s}:\n{s}", .{ name, text });
    }
    return out.toOwnedSlice(gpa);
}

/// The pack git 2.56's fetch left a `.keep` beside in `path`, by name,
/// the `.keep` removed. When packs come by URI, `get_pack` has index-pack
/// keep the fetch's pack but records the lock for removal only under
/// `do_keep`, which a fetch leaves off, so the pack would never be
/// repacked; this package removes it as it does every other fetch's.
fn dropLeftKeep(arena: Allocator, gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const listing = try packsOf(gpa, io, path);
    defer gpa.free(listing);
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| if (std.mem.endsWith(u8, line, ".keep")) {
        const name = line[0 .. line.len - ".keep".len];
        const keep = try std.Io.Dir.path.join(gpa, &.{ path, ".git", "objects", "pack", line });
        defer gpa.free(keep);
        try Io.Dir.cwd().deleteFile(io, keep);
        return arena.dupe(u8, name);
    };
    return error.TestUnexpectedResult;
}

test "packfile URIs: a clone and a fetch take the blobs a server names by URI as git 2.56 does, a .gitmodules among them checked once it is in, and a pack not the one named refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 56);
    var src = try testgit.Repo.init(gpa, io, &.{});
    defer src.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const served = try testremote.absolutePath(arena, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .files = true });
    defer server.stop();

    var big: std.ArrayList(u8) = .empty;
    for (0..2000) |i| try big.print(arena, "line {d} of a blob handed over by URI\n", .{i});
    try src.writeFile(io, "big.bin", big.items);
    try src.writeFile(io, "small.txt", "small\n");
    try src.exec(io, &.{ "add", "." });
    try src.exec(io, &.{ "commit", "-q", "-m", "first" });
    const bare = try std.Io.Dir.path.join(arena, &.{ served, "repo.git" });
    try src.exec(io, &.{ "clone", "-q", "--bare", ".", bare });
    try src.exec(io, &.{ "-C", bare, "config", "uploadpack.allowSidebandAll", "true" });
    const first_pack = try offerByUri(gpa, io, &src, bare, served, server, "big.bin", "big", null);
    defer gpa.free(first_pack);
    const url = try server.url(arena, "repo.git");

    var out = testing.tmpDir(.{ .iterate = true });
    defer out.cleanup();
    const outside = try testremote.absolutePath(arena, io, out.dir);
    const by_git = try std.Io.Dir.path.join(arena, &.{ outside, "by-git" });
    const settings = [_][]const u8{ "-c", "fetch.uriProtocols=http", "-c", "transfer.fsckObjects=true" };
    gpa.free(try testremote.gitInputEnv(gpa, io, out.dir, &env, &(settings ++ [_][]const u8{ "clone", "-q", "--no-checkout", url, by_git }), "", true));
    var config = try config_mod.Config.parseText(gpa, "[fetch]\n\turiProtocols = http\n[transfer]\n\tfsckObjects = true\n", .command);
    defer config.deinit();
    try out.dir.createDirPath(io, "by-relic");
    const by_relic = try std.Io.Dir.path.join(arena, &.{ outside, "by-relic" });
    var dir = try out.dir.openDir(io, "by-relic", .{});
    defer dir.close(io);
    var cloned = try clone_mod.clone(gpa, io, url, dir, .{ .who = who, .checkout = false, .programs = .{ .environ = &env }, .config = &config });
    cloned.deinit(io);

    // The same packs, the named one among them, and nothing kept.
    {
        const theirs = try packsOf(gpa, io, by_git);
        defer gpa.free(theirs);
        const ours = try packsOf(gpa, io, by_relic);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        try testing.expect(std.mem.find(u8, ours, first_pack) != null);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ours, "\n"));
        try src.exec(io, &.{ "-C", by_relic, "fsck", "--no-progress" });
    }

    // A commit whose `.gitmodules` comes by URI, fetched by each.
    try src.writeFile(io, ".gitmodules", "[submodule \"x\"]\n\tpath = x\n\turl = https://example.com/x\n");
    try src.exec(io, &.{ "add", ".gitmodules" });
    try src.exec(io, &.{ "commit", "-q", "-m", "second" });
    try src.exec(io, &.{ "push", "-q", bare, "HEAD:main" });
    const second_pack = try offerByUri(gpa, io, &src, bare, served, server, ".gitmodules", "modules", null);
    defer gpa.free(second_pack);
    gpa.free(try testremote.gitInputEnv(gpa, io, out.dir, &env, &(settings ++ [_][]const u8{ "-C", by_git, "fetch", "-q", "origin" }), "", true));
    const fetched_main = try dropLeftKeep(arena, gpa, io, by_git);
    try src.exec(io, &.{ "-C", by_relic, "config", "fetch.uriProtocols", "http" });
    try src.exec(io, &.{ "-C", by_relic, "config", "transfer.fsckObjects", "true" });
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = who, .programs = .{ .environ = &env } });
    fetched.deinit();
    {
        const theirs = try packsOf(gpa, io, by_git);
        defer gpa.free(theirs);
        const ours = try packsOf(gpa, io, by_relic);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        try testing.expect(std.mem.find(u8, ours, second_pack) != null);
        try testing.expect(std.mem.find(u8, fetched_main, second_pack) == null and std.mem.find(u8, fetched_main, first_pack) == null);
        try testing.expect(std.mem.find(u8, ours, fetched_main) != null);
        try testing.expectEqual(@as(usize, 4), std.mem.count(u8, ours, "\n"));
        const refs_theirs = try src.run(io, &.{ "-C", by_git, "for-each-ref", "--format=%(refname) %(objectname)" });
        defer gpa.free(refs_theirs);
        const refs_ours = try src.run(io, &.{ "-C", by_relic, "for-each-ref", "--format=%(refname) %(objectname)" });
        defer gpa.free(refs_ours);
        try testing.expectEqualStrings(refs_theirs, refs_ours);
        try src.exec(io, &.{ "-C", by_relic, "fsck", "--no-progress" });
    }
    const seen = try server.requests(gpa);
    defer gpa.free(seen);
    for ([_][]const u8{ first_pack, second_pack }) |pack_hash| {
        const get = try std.mem.concat(arena, u8, &.{ "-", pack_hash, ".pack" });
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, seen, get));
    }

    // A pack named by a checksum it does not have: git's clone dies, and
    // this package's refuses it.
    try src.writeFile(io, "third.bin", "a third blob\n");
    try src.exec(io, &.{ "add", "third.bin" });
    try src.exec(io, &.{ "commit", "-q", "-m", "third" });
    try src.exec(io, &.{ "push", "-q", bare, "HEAD:main" });
    const third_pack = try offerByUri(gpa, io, &src, bare, served, server, "third.bin", "third", first_pack);
    defer gpa.free(third_pack);
    const refused_by_git = try std.Io.Dir.path.join(arena, &.{ outside, "refused-by-git" });
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, out.dir, &env, &(settings ++ [_][]const u8{ "clone", "-q", "--no-checkout", url, refused_by_git }), "", false));
    try out.dir.createDirPath(io, "refused");
    var refused = try out.dir.openDir(io, "refused", .{});
    defer refused.close(io);
    try testing.expectError(error.PackfileUriMismatch, clone_mod.clone(gpa, io, url, refused, .{ .who = who, .checkout = false, .programs = .{ .environ = &env }, .config = &config }));
}

test "packfile URIs in a partial clone: the packs named by URI are promisor packs, as git 2.56 marks them, in a clone, a fetch and a lazy fetch" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 56);
    var src = try testgit.Repo.init(gpa, io, &.{});
    defer src.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const served = try testremote.absolutePath(arena, io, root.dir);
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{ .files = true });
    defer server.stop();

    var big: std.ArrayList(u8) = .empty;
    for (0..2000) |i| try big.print(arena, "line {d} of a blob handed over by URI\n", .{i});
    try src.writeFile(io, "big.bin", big.items);
    try src.writeFile(io, "small.txt", "small\n");
    try src.exec(io, &.{ "add", "." });
    try src.exec(io, &.{ "commit", "-q", "-m", "first" });
    const bare = try std.Io.Dir.path.join(arena, &.{ served, "repo.git" });
    try src.exec(io, &.{ "clone", "-q", "--bare", ".", bare });
    try src.exec(io, &.{ "-C", bare, "config", "uploadpack.allowSidebandAll", "true" });
    try src.exec(io, &.{ "-C", bare, "config", "uploadpack.allowFilter", "true" });
    try src.exec(io, &.{ "-C", bare, "config", "uploadpack.allowAnySHA1InWant", "true" });
    const first_pack = try offerByUri(gpa, io, &src, bare, served, server, "big.bin", "big", null);
    defer gpa.free(first_pack);
    const url = try server.url(arena, "repo.git");

    var out = testing.tmpDir(.{ .iterate = true });
    defer out.cleanup();
    const outside = try testremote.absolutePath(arena, io, out.dir);
    const settings = [_][]const u8{ "-c", "fetch.uriProtocols=http" };
    var config = try config_mod.Config.parseText(gpa, "[fetch]\n\turiProtocols = http\n", .command);
    defer config.deinit();

    // A clone whose filter leaves every blob in: the main pack lists the
    // refs it came for, the pack named by URI nothing.
    const by_git = try std.Io.Dir.path.join(arena, &.{ outside, "by-git" });
    gpa.free(try testremote.gitInputEnv(gpa, io, out.dir, &env, &(settings ++ [_][]const u8{ "clone", "-q", "--no-checkout", "--filter=blob:limit=1m", url, by_git }), "", true));
    try out.dir.createDirPath(io, "by-relic");
    const by_relic = try std.Io.Dir.path.join(arena, &.{ outside, "by-relic" });
    var dir = try out.dir.openDir(io, "by-relic", .{});
    defer dir.close(io);
    var cloned = try clone_mod.clone(gpa, io, url, dir, .{ .who = who, .checkout = false, .filter = "blob:limit=1m", .programs = .{ .environ = &env }, .config = &config });
    cloned.deinit(io);
    try expectSamePacks(gpa, io, &src, by_git, by_relic, &.{first_pack}, 4);

    // A fetch into it: every pack a promisor pack, none naming refs.
    try src.writeFile(io, "other.bin", big.items[0 .. big.items.len / 2]);
    try src.exec(io, &.{ "add", "other.bin" });
    try src.exec(io, &.{ "commit", "-q", "-m", "second" });
    try src.exec(io, &.{ "push", "-q", bare, "HEAD:main" });
    const second_pack = try offerByUri(gpa, io, &src, bare, served, server, "other.bin", "other", null);
    defer gpa.free(second_pack);
    for ([_][]const u8{ by_git, by_relic }) |path| try src.exec(io, &.{ "-C", path, "config", "fetch.uriProtocols", "http" });
    gpa.free(try testremote.gitInputEnv(gpa, io, out.dir, &env, &.{ "-C", by_git, "fetch", "-q", "origin" }, "", true));
    _ = try dropLeftKeep(arena, gpa, io, by_git);
    {
        var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var fetched = try fetch_mod.fetch(gpa, io, &repo, "origin", .{ .who = who, .programs = .{ .environ = &env } });
        fetched.deinit();
    }
    try expectSamePacks(gpa, io, &src, by_git, by_relic, &.{ first_pack, second_pack }, 8);

    // A clone that leaves the blobs behind, then reads one the server
    // names by URI: the lazy fetch's packs are promisor packs too.
    const lazy_git = try std.Io.Dir.path.join(arena, &.{ outside, "lazy-git" });
    gpa.free(try testremote.gitInputEnv(gpa, io, out.dir, &env, &.{ "clone", "-q", "--no-checkout", "--filter=blob:none", url, lazy_git }, "", true));
    try out.dir.createDirPath(io, "lazy-relic");
    const lazy_relic = try std.Io.Dir.path.join(arena, &.{ outside, "lazy-relic" });
    var lazy_dir = try out.dir.openDir(io, "lazy-relic", .{});
    defer lazy_dir.close(io);
    var none = try clone_mod.clone(gpa, io, url, lazy_dir, .{ .who = who, .checkout = false, .filter = "blob:none", .programs = .{ .environ = &env } });
    none.deinit(io);
    for ([_][]const u8{ lazy_git, lazy_relic }) |path| try src.exec(io, &.{ "-C", path, "config", "fetch.uriProtocols", "http" });
    const blob_text = try src.line(io, &.{ "rev-parse", "HEAD:big.bin" });
    defer gpa.free(blob_text);
    gpa.free(try testremote.gitInputEnv(gpa, io, out.dir, &env, &.{ "-C", lazy_git, "cat-file", "-e", blob_text }, "", true));
    // git keeps the lazy fetch's own pack, which holds nothing, every
    // object it asked for having come by URI; this package keeps no pack
    // of no objects.
    {
        const empty = try dropLeftKeep(arena, gpa, io, lazy_git);
        const base = try std.Io.Dir.path.join(arena, &.{ lazy_git, ".git", "objects", "pack", empty });
        const pack = try Io.Dir.cwd().readFileAlloc(io, try std.mem.concat(arena, u8, &.{ base, ".pack" }), arena, .unlimited);
        try testing.expectEqualStrings("PACK", pack[0..4]);
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, pack[8..12], .big));
        for ([_][]const u8{ ".pack", ".idx", ".rev", ".promisor" }) |ext| {
            Io.Dir.cwd().deleteFile(io, try std.mem.concat(arena, u8, &.{ base, ext })) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
    {
        var repo = try repo_mod.Repository.open(gpa, io, lazy_dir, .{});
        defer repo.deinit(io);
        var lazy: partial.Lazy = .init(gpa, &repo, .{ .programs = .{ .environ = &env } });
        defer lazy.deinit();
        lazy.install();
        const found = try repo.objectDatabase().read(io, try hash_mod.Oid.parse(repo.objectFormat(), blob_text));
        gpa.free(found.bytes);
        try testing.expectEqual(@as(u32, 1), lazy.fetches);
    }
    try expectSamePacks(gpa, io, &src, lazy_git, lazy_relic, &.{first_pack}, 4);
}

/// `ours` holds the packs and promisor files `theirs` does, the URI packs
/// `named` among them, `lines` names in all.
fn expectSamePacks(gpa: Allocator, io: Io, src: *testgit.Repo, theirs: []const u8, ours: []const u8, named: []const []const u8, lines: usize) !void {
    const packs_theirs = try packsOf(gpa, io, theirs);
    defer gpa.free(packs_theirs);
    const packs_ours = try packsOf(gpa, io, ours);
    defer gpa.free(packs_ours);
    try testing.expectEqualStrings(packs_theirs, packs_ours);
    for (named) |n| try testing.expect(std.mem.find(u8, packs_ours, n) != null);
    try testing.expectEqual(lines, std.mem.count(u8, packs_ours, "\n"));
    const marks_theirs = try promisorsOf(gpa, io, theirs);
    defer gpa.free(marks_theirs);
    const marks_ours = try promisorsOf(gpa, io, ours);
    defer gpa.free(marks_ours);
    try testing.expectEqualStrings(marks_theirs, marks_ours);
    try src.exec(io, &.{ "-C", ours, "fsck", "--no-progress" });
}
