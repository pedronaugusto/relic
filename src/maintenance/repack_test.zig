//! `repack` held to git 2.55's: the same repository repacked by each, and
//! what each object directory then holds compared -- which objects each
//! pack holds and what kind of pack it is, a cruft pack's times, the loose
//! objects and their times, the packs a multi-pack index lists and the
//! one it prefers, `.git/shallow` and the dumb HTTP files. The
//! packs' bytes differ (relic's delta search is its own), never what they
//! hold.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const fs = @import("../fs/fs.zig");
const repack_mod = @import("repack.zig");
const repo_mod = @import("../repo/repo.zig");
const pack_mod = @import("../odb/pack.zig");
const mtimes = @import("../odb/mtimes.zig");
const midx = @import("../odb/midx.zig");
const hash = @import("../hash/hash.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

pub const day = std.time.s_per_day;

pub fn at(repo: *testgit.Repo, secs: i64) !void {
    var buffer: [32]u8 = undefined;
    const value = try std.mem.print(&buffer, "@{d} +0000", .{secs});
    try repo.isolated.?.put("GIT_AUTHOR_DATE", value);
    try repo.isolated.?.put("GIT_COMMITTER_DATE", value);
}

pub fn commitAt(repo: *testgit.Repo, secs: i64, message: []const u8) !void {
    try at(repo, secs);
    try repo.writeFile(io, "file.txt", message);
    try repo.exec(io, &.{ "add", "file.txt" });
    try repo.exec(io, &.{ "commit", "-q", "-m", message });
}

fn setTime(dir: Io.Dir, name: []const u8, secs: i64) !void {
    try fs.setTimestamps(io, dir, name, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, secs) * std.time.ns_per_s) } });
}

/// Every loose file's time, and every pack file's, set to `secs`.
pub fn ageAll(repo: *testgit.Repo, secs: i64) !void {
    var objects = try repo.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var it = objects.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2 and !std.mem.eql(u8, entry.name, "pack")) continue;
        var sub = try objects.openDir(io, entry.name, .{ .iterate = true });
        defer sub.close(io);
        var files = sub.iterate();
        while (try files.next(io)) |file| if (file.kind == .file) try setTime(sub, file.name, secs);
    }
}

pub fn touchObject(repo: *testgit.Repo, hex: []const u8, secs: i64) !void {
    var buffer: [128]u8 = undefined;
    const path = try std.mem.print(&buffer, ".git/objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    try setTime(repo.dir, path, secs);
}

pub fn blob(repo: *testgit.Repo, bytes: []const u8) ![]u8 {
    const out = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, bytes);
    defer gpa.free(out);
    return gpa.dupe(u8, std.mem.trim(u8, out, "\n"));
}

/// A commit nothing names, on a tree of its own holding one new blob.
pub fn dangling(repo: *testgit.Repo, contents: []const u8, parent: ?[]const u8, message: []const u8) ![]u8 {
    const b = try blob(repo, contents);
    defer gpa.free(b);
    var listing: [256]u8 = undefined;
    const tree = try repo.runInput(io, &.{"mktree"}, try std.mem.print(&listing, "100644 blob {s}\tf.txt\n", .{b}));
    defer gpa.free(tree);
    const t = std.mem.trim(u8, tree, "\n");
    if (parent) |p| return repo.line(io, &.{ "commit-tree", t, "-p", p, "-m", message });
    return repo.line(io, &.{ "commit-tree", t, "-m", message });
}

/// A repository with what each mode of repack sorts: history on two
/// branches and an annotated tag, a reflog-only commit, an index-only
/// blob, objects nothing reaches -- old and recent, loose and packed, one
/// recent commit reaching old ones -- and a kept pack.
pub fn fixture(format: testgit.RefFormat, now: i64) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, format.initArgs());
    errdefer repo.deinit();
    try commitAt(&repo, now - 100 * day, "one");
    try commitAt(&repo, now - 95 * day, "two");
    try at(&repo, now - 95 * day);
    try repo.exec(io, &.{ "tag", "-a", "-m", "the first", "v1" });
    try repo.exec(io, &.{ "repack", "-q", "-d" });
    try repo.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try commitAt(&repo, now - 90 * day, "side");
    try repo.exec(io, &.{ "checkout", "-q", "-" });
    try commitAt(&repo, now - 85 * day, "three");
    try repo.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try repo.writeFile(io, "staged.txt", "only in the index\n");
    try repo.exec(io, &.{ "add", "staged.txt" });

    // Unreachable objects in a pack of their own, which `-a -d` takes away.
    try at(&repo, now - 80 * day);
    const packed_old = try dangling(&repo, "packed and unreachable\n", null, "packed, old");
    defer gpa.free(packed_old);
    const listed = try repo.run(io, &.{ "rev-list", "--objects", packed_old });
    defer gpa.free(listed);
    gpa.free(try repo.runInput(io, &.{ "pack-objects", "-q", ".git/objects/pack/pack" }, listed));
    try repo.exec(io, &.{"prune-packed"});

    // A kept pack of one blob nothing names.
    const kept = try blob(&repo, "in a kept pack\n");
    defer gpa.free(kept);
    const kept_name = try repo.runInput(io, &.{ "pack-objects", "-q", ".git/objects/pack/pack" }, kept);
    defer gpa.free(kept_name);
    var keep_path: [256]u8 = undefined;
    try repo.writeFile(io, try std.mem.print(&keep_path, ".git/objects/pack/pack-{s}.keep", .{std.mem.trim(u8, kept_name, "\n")}), "");
    try repo.exec(io, &.{"prune-packed"});

    // Loose and unreachable: an old commit below a recent one, and blobs.
    try at(&repo, now - 70 * day);
    const base = try dangling(&repo, "below the recent one\n", null, "old, below a recent one");
    defer gpa.free(base);
    const recent = try dangling(&repo, "the recent one's own\n", base, "recent and unreachable");
    defer gpa.free(recent);
    gpa.free(try blob(&repo, "an old blob\n"));
    const fresh = try blob(&repo, "a recent blob\n");
    defer gpa.free(fresh);

    try ageAll(&repo, now - 30 * day);
    try touchObject(&repo, recent, now - day);
    try touchObject(&repo, fresh, now - day);
    return repo;
}

/// What the object directory holds, as text: each pack's kind and objects
/// (a cruft pack's with their times, `midx` when the multi-pack index
/// lists it, `preferred` when it is the index's preferred pack), the loose
/// objects with their times, whether the index has a bitmap, then
/// `.git/shallow` and the dumb HTTP files.
pub fn state(repo: *testgit.Repo) ![]u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var index_of_packs = try midx.Index.open(gpa, io, pack_dir, .sha1);
    defer if (index_of_packs) |*m| m.deinit();
    const preferred: ?u32 = if (index_of_packs) |*m| (if (try m.reverseAt(0)) |first| (try m.locate(first)).pack else null) else null;
    var pack_count: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        pack_count += 1;
        const base = entry.name[0 .. entry.name.len - 4];
        var index = try pack_mod.Index.open(gpa, io, pack_dir, entry.name, .{ .kind = .sha1, .max_bytes = 1 << 30 });
        defer index.deinit();
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(arena, "pack");
        for ([_][]const u8{ ".keep", ".mtimes", ".promisor", ".bitmap", ".rev" }) |ext| {
            const name = try arena.print("{s}{s}", .{ base, ext });
            pack_dir.access(io, name, .{}) catch continue;
            try line.appendSlice(arena, ext);
        }
        if (index_of_packs) |*m| for (0..m.pack_count) |i| if (std.mem.eql(u8, m.packName(@intCast(i)).?, base)) {
            try line.appendSlice(arena, if (preferred == @as(u32, @intCast(i))) " midx preferred" else " midx");
        };
        const times: ?[]u32 = mtimes.read(arena, io, pack_dir, try arena.print("{s}.mtimes", .{base}), index.count) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        for (0..index.count) |i| {
            var hex: [hash.max_hex_len]u8 = undefined;
            try line.print(arena, " {s}", .{index.nameAt(@intCast(i)).hex(&hex)});
            if (times) |t| try line.print(arena, "@{d}", .{t[i]});
        }
        try lines.append(arena, line.items);
    }
    var objects = try repo.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var fans = objects.iterate();
    while (try fans.next(io)) |fan| {
        if (fan.kind != .directory or fan.name.len != 2) continue;
        var sub = try objects.openDir(io, fan.name, .{ .iterate = true });
        defer sub.close(io);
        var files = sub.iterate();
        while (try files.next(io)) |file| {
            const stat = try sub.statFile(io, file.name, .{});
            try lines.append(arena, try arena.print("loose {s}{s}@{d}", .{ fan.name, file.name, stat.mtime.toSeconds() }));
        }
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines.items) |l| try out.print(gpa, "{s}\n", .{l});
    var midx_bitmaps: usize = 0;
    var files = pack_dir.iterate();
    while (try files.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "multi-pack-index-") and std.mem.endsWith(u8, entry.name, ".bitmap")) midx_bitmaps += 1;
    }
    try out.print(gpa, "multi-pack-index bitmaps: {d}\n", .{midx_bitmaps});
    for ([_][]const u8{ ".git/shallow", ".git/info/refs" }) |path| {
        const bytes = repo.readFile(io, path) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, "(none)\n"),
            else => |e| return e,
        };
        defer gpa.free(bytes);
        try out.print(gpa, "{s}:\n{s}", .{ path, bytes });
    }
    // `objects/info/packs` names every pack, by names that differ between
    // the two.
    const packs = repo.readFile(io, ".git/objects/info/packs") catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => |e| return e,
    };
    defer gpa.free(packs);
    var listed: usize = 0;
    var pack_lines = std.mem.splitScalar(u8, packs, '\n');
    while (pack_lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "P ")) continue;
        pack_dir.access(io, l[2..], .{}) catch return error.ListedPackMissing;
        listed += 1;
    }
    try out.print(gpa, "info/packs lists {d} of {d} packs\n", .{ listed, if (packs.len == 0) 0 else pack_count });
    return out.toOwnedSlice(gpa);
}

const Case = struct { args: []const []const u8, options: repack_mod.Options };

fn compare(format: testgit.RefFormat, cases: []const Case, configure: ?*const fn (*testgit.Repo, i64) anyerror!void) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    for (cases, 0..) |case, n| {
        var theirs = try fixture(format, now);
        defer theirs.deinit();
        var ours = try fixture(format, now);
        defer ours.deinit();
        if (configure) |c| {
            try c(&theirs, now);
            try c(&ours, now);
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "repack", "-q" });
        try args.appendSlice(gpa, case.args);
        try theirs.exec(io, args.items);
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var options = case.options;
        options.programs = .{ .environ = &ours.isolated.? };
        var pack_options = options.pack orelse native.objectDatabase().packOptions();
        pack_options.threads = 1;
        options.pack = pack_options;
        _ = try repack_mod.repack(gpa, io, &native, options);
        const expected = try state(&theirs);
        defer gpa.free(expected);
        const actual = try state(&ours);
        defer gpa.free(actual);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("repack case {d}\n", .{n});
            return err;
        };
        try ours.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
        if (options.write_midx) try ours.exec(io, &.{ "multi-pack-index", "verify", "--no-progress" });
        if (options.write_midx and options.write_bitmaps == true) try ours.exec(io, &.{ "rev-list", "--test-bitmap", "HEAD" });
    }
}

/// `--unpack-unreachable` and `--cruft-expiration` two weeks before the
/// test began, by the seconds both sides read alike.
fn dates(now: i64, buf: *[2][48]u8) ![2][]const u8 {
    return .{
        try std.mem.print(&buf[0], "--unpack-unreachable=@{d}", .{now - 14 * day}),
        try std.mem.print(&buf[1], "--cruft-expiration=@{d}", .{now - 14 * day}),
    };
}

fn modesInFormat(format: testgit.RefFormat) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var buf: [2][48]u8 = undefined;
    const unpack_arg, const expiration_arg = try dates(now, &buf);
    try compare(format, &.{
        .{ .args = &.{}, .options = .{} },
        .{ .args = &.{"-d"}, .options = .{ .delete = true } },
        .{ .args = &.{ "-a", "-d" }, .options = .{ .mode = .all, .delete = true } },
        .{ .args = &.{"-a"}, .options = .{ .mode = .all } },
        .{ .args = &.{ "-a", "-d", "-k" }, .options = .{ .mode = .all, .delete = true, .keep_unreachable = true } },
        .{ .args = &.{ "-A", "-d" }, .options = .{ .mode = .all_loosen, .delete = true } },
        .{ .args = &.{ "-A", "-d", unpack_arg }, .options = .{ .mode = .all_loosen, .delete = true, .unpack_unreachable = .fromRaw(now - 14 * day) } },
        .{ .args = &.{ "--cruft", "-d" }, .options = .{ .mode = .cruft, .delete = true } },
        .{ .args = &.{ "--cruft", "-d", expiration_arg }, .options = .{ .mode = .cruft, .delete = true, .cruft_expiration = .fromRaw(now - 14 * day) } },
        .{ .args = &.{ "-a", "-d", "-l" }, .options = .{ .mode = .all, .delete = true, .local = true } },
    }, null);
}

test "repack keeps, loosens, packs and drops what git's does, in every mode and both ref formats" {
    try testgit.eachRefFormat(modesInFormat);
}

fn hook(repo: *testgit.Repo, now: i64) !void {
    _ = now;
    const old = try repo.line(io, &.{ "rev-parse", "--verify", "HEAD" });
    defer gpa.free(old);
    // A name for the hook: the old blob nothing names.
    const named = try repo.runInput(io, &.{ "hash-object", "--stdin" }, "an old blob\n");
    defer gpa.free(named);
    var command: [256]u8 = undefined;
    try repo.exec(io, &.{ "config", "gc.recentObjectsHook", try std.mem.print(&command, "echo {s}", .{std.mem.trim(u8, named, "\n")}) });
}

fn hookInFormat(format: testgit.RefFormat) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var buf: [2][48]u8 = undefined;
    const unpack_arg, const expiration_arg = try dates(now, &buf);
    try compare(format, &.{
        .{ .args = &.{ "--cruft", "-d", expiration_arg }, .options = .{ .mode = .cruft, .delete = true, .cruft_expiration = .fromRaw(now - 14 * day) } },
        .{ .args = &.{ "-A", "-d", unpack_arg }, .options = .{ .mode = .all_loosen, .delete = true, .unpack_unreachable = .fromRaw(now - 14 * day) } },
    }, hook);
}

test "gc.recentObjectsHook keeps what it names in a cruft pack and loose, as git's repack" {
    try testgit.eachRefFormat(hookInFormat);
}

/// A second cruft pack beside the first, and a second repack: what the
/// older one holds is combined, or not, as git combines it.
fn twoCruftPacks(repo: *testgit.Repo, now: i64) !void {
    try repo.exec(io, &.{ "repack", "-q", "-d", "--cruft" });
    gpa.free(try blob(repo, "a blob after the first cruft pack\n"));
    // Every time fixed, so the two repositories, made seconds apart, agree.
    try ageAll(repo, now - 20 * day);
    try repo.exec(io, &.{ "reflog", "expire", "--expire=all", "--all" });
}

fn combineInFormat(format: testgit.RefFormat) !void {
    try compare(format, &.{
        .{ .args = &.{ "--cruft", "-d" }, .options = .{ .mode = .cruft, .delete = true } },
        .{ .args = &.{ "--cruft", "-d", "--combine-cruft-below-size=1" }, .options = .{ .mode = .cruft, .delete = true, .combine_cruft_below = 1 } },
        .{ .args = &.{ "--cruft", "-d", "--combine-cruft-below-size=1m" }, .options = .{ .mode = .cruft, .delete = true, .combine_cruft_below = 1 << 20 } },
    }, twoCruftPacks);
}

test "a repack over a cruft pack combines it as git's does, --combine-cruft-below-size included" {
    try testgit.eachRefFormat(combineInFormat);
}

/// The largest pack's file name, the one the fixture's history is in.
fn largestPack(repo: *testgit.Repo, buf: []u8) ![]const u8 {
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var it = pack_dir.iterate();
    var largest: u64 = 0;
    var found: []const u8 = "";
    while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".pack")) {
        const stat = try pack_dir.statFile(io, entry.name, .{});
        if (stat.size > largest) {
            largest = stat.size;
            found = try std.mem.print(buf, "{s}", .{entry.name});
        }
    };
    return found;
}

fn keepPack() !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var theirs = try fixture(.files, now);
    defer theirs.deinit();
    var ours = try fixture(.files, now);
    defer ours.deinit();
    var name_buf: [128]u8 = undefined;
    const arg = try std.mem.concat(gpa, u8, &.{ "--keep-pack=", try largestPack(&theirs, &name_buf) });
    defer gpa.free(arg);
    try theirs.exec(io, &.{ "repack", "-q", "-a", "-d", arg });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .keep_packs = &.{try largestPack(&ours, &name_buf)}, .pack = .{ .threads = 1 } });
    const expected = try state(&theirs);
    defer gpa.free(expected);
    const actual = try state(&ours);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "--keep-pack leaves a pack and what it holds, as git's repack" {
    try keepPack();
}

test "--max-pack-size and --max-cruft-size cut the packs at the size, each whole, holding what git's do" {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var repos: [2]testgit.Repo = undefined;
    for (&repos, 0..) |*r, side| {
        r.* = try testgit.Repo.init(gpa, io, &.{});
        // Blobs that do not compress, about 400 KiB each, five reachable
        // and four not.
        var prng: std.Random.DefaultPrng = .init(7);
        const bytes = try gpa.alloc(u8, 400 << 10);
        defer gpa.free(bytes);
        for (0..9) |n| {
            prng.random().bytes(bytes);
            var name: [16]u8 = undefined;
            const path = try std.mem.print(&name, "big{d}", .{n});
            try r.writeFile(io, path, bytes);
            if (n < 5) {
                try r.exec(io, &.{ "add", path });
            } else {
                gpa.free(try r.run(io, &.{ "hash-object", "-w", path }));
            }
        }
        try commitAt(r, now - 100 * day, "big");
        try ageAll(r, now - 30 * day);
        if (side == 0) try r.exec(io, &.{ "repack", "-q", "-d", "--cruft", "--max-pack-size=1m", "--max-cruft-size=1m" });
    }
    defer for (&repos) |*r| r.deinit();
    var native = try repo_mod.Repository.open(gpa, io, repos[1].dir, .{});
    defer native.deinit(io);
    _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .cruft, .delete = true, .max_pack_bytes = 1 << 20, .max_cruft_bytes = 1 << 20, .pack = .{ .threads = 1 } });
    for (&repos) |*r| {
        var pack_dir = try r.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
        defer pack_dir.close(io);
        var it = pack_dir.iterate();
        var packs: usize = 0;
        while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".pack")) {
            packs += 1;
            try std.testing.expect((try pack_dir.statFile(io, entry.name, .{})).size <= 1 << 20);
        };
        try std.testing.expect(packs >= 5);
    }
    // Every object where git's put it: reachable in regular packs, the
    // rest in cruft packs, with their times.
    const expected = try objectsByKind(&repos[0]);
    defer gpa.free(expected);
    const actual = try objectsByKind(&repos[1]);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try repos[1].exec(io, &.{ "fsck", "--no-progress" });
}

/// Each packed object with whether its pack is a cruft pack, sorted.
fn objectsByKind(repo: *testgit.Repo) ![]u8 {
    const text = try state(repo);
    defer gpa.free(text);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pack")) continue;
        var words = std.mem.splitScalar(u8, line, ' ');
        const kind = words.next().?;
        const cruft = std.mem.find(u8, kind, ".mtimes") != null;
        while (words.next()) |w| try lines.append(gpa, try arena_instance.allocator().print("{s} {s}", .{ w, if (cruft) "cruft" else "pack" }));
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (lines.items) |l| try out.print(gpa, "{s}\n", .{l});
    return out.toOwnedSlice(gpa);
}

test "a bare repository's -a carries a bitmap, as git's" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    for (0..4) |n| {
        var message: [16]u8 = undefined;
        try commitAt(&repo, testgit.fixture_date + @as(i64, @intCast(n)), try std.mem.print(&message, "c{d}", .{n}));
    }
    try repo.exec(io, &.{ "config", "core.bare", "true" });
    var native = try repo_mod.Repository.open(gpa, io, try repo.gitDir(io), .{});
    defer native.deinit(io);
    _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .pack = .{ .threads = 1 } });
    try repo.exec(io, &.{ "--git-dir=.git", "rev-list", "--test-bitmap", "HEAD" });
}

fn geometricInFormat(format: testgit.RefFormat) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var buf: [2][48]u8 = undefined;
    _, const expiration_arg = try dates(now, &buf);
    // The fixture's packs hold 1 (kept), 3 and 7 objects: a factor of 2
    // rolls up only the loose objects, 3 every pack.
    try compare(format, &.{
        .{ .args = &.{"--geometric=2"}, .options = .{ .geometric = 2 } },
        .{ .args = &.{ "--geometric=2", "-d" }, .options = .{ .geometric = 2, .delete = true } },
        .{ .args = &.{ "--geometric=3", "-d" }, .options = .{ .geometric = 3, .delete = true } },
        .{ .args = &.{ "--geometric=3", "-d", "--pack-kept-objects" }, .options = .{ .geometric = 3, .delete = true, .pack_kept_objects = true } },
        .{ .args = &.{ "--geometric=2", "-d", "--write-midx" }, .options = .{ .geometric = 2, .delete = true, .write_midx = true } },
        .{ .args = &.{ "--geometric=3", "-d", "--write-midx", "-b" }, .options = .{ .geometric = 3, .delete = true, .write_midx = true, .write_bitmaps = true } },
        .{ .args = &.{ "-d", "--write-midx" }, .options = .{ .delete = true, .write_midx = true } },
        .{ .args = &.{ "-a", "-d", "--write-midx", "-b" }, .options = .{ .mode = .all, .delete = true, .write_midx = true, .write_bitmaps = true } },
        .{ .args = &.{ "--cruft", "-d", "--write-midx", expiration_arg }, .options = .{ .mode = .cruft, .delete = true, .write_midx = true, .cruft_expiration = .fromRaw(now - 14 * day) } },
    }, null);
}

test "--geometric rolls up the packs git's does, and --write-midx indexes the packs git's does" {
    try testgit.eachRefFormat(geometricInFormat);
}

/// The fixture's pack of 3 unreachable objects a promisor pack, and a
/// second promisor pack of one blob.
fn promisorPacks(repo: *testgit.Repo, now: i64) !void {
    _ = now;
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        var index = try pack_mod.Index.open(gpa, io, pack_dir, entry.name, .{ .kind = .sha1, .max_bytes = 1 << 30 });
        defer index.deinit();
        if (index.count != 3) continue;
        var name: [128]u8 = undefined;
        try pack_dir.writeFile(io, .{ .sub_path = try std.mem.print(&name, "{s}.promisor", .{entry.name[0 .. entry.name.len - 4]}), .data = "" });
        break;
    }
    const b = try blob(repo, "in a second promisor pack\n");
    defer gpa.free(b);
    const made = try repo.runInput(io, &.{ "pack-objects", "-q", ".git/objects/pack/pack" }, b);
    defer gpa.free(made);
    var promisor: [256]u8 = undefined;
    try repo.writeFile(io, try std.mem.print(&promisor, ".git/objects/pack/pack-{s}.promisor", .{std.mem.trim(u8, made, "\n")}), "");
    try repo.exec(io, &.{"prune-packed"});
}

fn promisorInFormat(format: testgit.RefFormat) !void {
    try compare(format, &.{
        .{ .args = &.{ "--geometric=2", "-d" }, .options = .{ .geometric = 2, .delete = true } },
        .{ .args = &.{ "--geometric=4", "-d", "--write-midx" }, .options = .{ .geometric = 4, .delete = true, .write_midx = true } },
    }, promisorPacks);
}

test "--geometric rolls the promisor packs up into a promisor pack, as git's" {
    try testgit.eachRefFormat(promisorInFormat);
}

test "repack refuses what git refuses" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try commitAt(&repo, testgit.fixture_date, "one");
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectError(error.IncompatibleOptions, repack_mod.repack(gpa, io, &native, .{ .mode = .cruft, .keep_unreachable = true }));
    try std.testing.expectError(error.IncompatibleOptions, repack_mod.repack(gpa, io, &native, .{ .mode = .all_loosen, .keep_unreachable = true }));
    try std.testing.expectError(error.IncrementalBitmaps, repack_mod.repack(gpa, io, &native, .{ .write_bitmaps = true }));
    try std.testing.expectError(error.IncrementalBitmaps, repack_mod.repack(gpa, io, &native, .{ .geometric = 2, .write_bitmaps = true }));
    try std.testing.expectError(error.IncompatibleOptions, repack_mod.repack(gpa, io, &native, .{ .mode = .all, .geometric = 2 }));
    try repo.exec(io, &.{ "config", "extensions.preciousObjects", "true" });
    _ = try native.refreshConfig(io, .{});
    try std.testing.expectError(error.PreciousObjects, repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true }));
}

/// Each pack's entries as `git verify-pack -v` reads them: whether the
/// whole objects' zlib streams carry the level `want` says, and the
/// deepest delta chain.
const PackShape = struct { levels_ok: bool, max_depth: u32, whole: usize };

fn packShape(repo: *testgit.Repo, want_header: u8) !PackShape {
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var shape: PackShape = .{ .levels_ok = true, .max_depth = 0, .whole = 0 };
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        var path_buf: [256]u8 = undefined;
        // A kept pack stays as it was written.
        const kept = if (pack_dir.access(io, try std.mem.print(&path_buf, "{s}.keep", .{entry.name[0 .. entry.name.len - 4]}), .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => |e| return e,
        };
        if (kept) continue;
        const listing = try repo.run(io, &.{ "verify-pack", "-v", try std.mem.print(&path_buf, ".git/objects/pack/{s}", .{entry.name}) });
        defer gpa.free(listing);
        const pack_name = try std.mem.print(&path_buf, "{s}.pack", .{entry.name[0 .. entry.name.len - 4]});
        const bytes = try fs.readWhole(pack_dir, io, pack_name, gpa, .limited(1 << 26));
        defer gpa.free(bytes);
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            var fields: [7][]const u8 = undefined;
            var n: usize = 0;
            while (words.next()) |w| : (n += 1) if (n < fields.len) {
                fields[n] = w;
            };
            if (n < 5 or fields[0].len < 40) continue;
            if (n >= 7) {
                shape.max_depth = @max(shape.max_depth, try std.fmt.parseInt(u32, fields[5], 10));
                continue;
            }
            // A whole object: past its type-and-size header, the zlib
            // stream's first byte and its level's.
            var pos = try std.fmt.parseInt(usize, fields[4], 10);
            while (bytes[pos] & 0x80 != 0) pos += 1;
            pos += 1;
            shape.whole += 1;
            if (bytes[pos] != 0x78 or bytes[pos + 1] != want_header) shape.levels_ok = false;
        }
    }
    return shape;
}

test "pack.window, pack.depth, pack.compression and pack.indexVersion shape the packs as git's settings shape git's" {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const Setting = struct { config: []const [2][]const u8, header: u8, depth: u32, index_v1: bool };
    const settings = [_]Setting{
        .{ .config = &.{ .{ "pack.window", "0" }, .{ "pack.compression", "9" } }, .header = 0xDA, .depth = 0, .index_v1 = false },
        .{ .config = &.{ .{ "pack.window", "0" }, .{ "core.compression", "1" } }, .header = 0x01, .depth = 0, .index_v1 = false },
        .{ .config = &.{ .{ "pack.window", "0" }, .{ "pack.compression", "-1" }, .{ "pack.indexVersion", "1" } }, .header = 0x9C, .depth = 0, .index_v1 = true },
        .{ .config = &.{.{ "pack.depth", "1" }}, .header = 0x9C, .depth = 1, .index_v1 = false },
    };
    for (settings, 0..) |setting, n| {
        var theirs = try fixture(.files, now);
        defer theirs.deinit();
        var ours = try fixture(.files, now);
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            // Many versions of one file, for deltas to be found.
            for (0..12) |i| {
                var text: [64]u8 = undefined;
                try commitAt(r, now - 50 * day + @as(i64, @intCast(i)), try std.mem.print(&text, "line\nline {d}\nline\nline\nline\nline\n", .{i}));
            }
            for (setting.config) |kv| try r.exec(io, &.{ "config", kv[0], kv[1] });
        }
        // `-F`: every object deflated again, at the setting, none copied.
        try theirs.exec(io, &.{ "repack", "-q", "-a", "-d", "-F" });
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var pack_options = native.objectDatabase().packOptions();
        pack_options.threads = 1;
        pack_options.reuse_packed = false;
        _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .pack = pack_options });
        for ([_]*testgit.Repo{ &theirs, &ours }, 0..) |r, side| {
            const shape = try packShape(r, setting.header);
            std.testing.expect(shape.levels_ok and shape.max_depth <= setting.depth and shape.whole != 0) catch |err| {
                std.debug.print("setting {d}, side {d}: {any}\n", .{ n, side, shape });
                return err;
            };
            var pack_dir = try r.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
            defer pack_dir.close(io);
            var it = pack_dir.iterate();
            while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".idx")) {
                // The kept pack stays as the fixture wrote it.
                var keep_buf: [128]u8 = undefined;
                const keep = try std.mem.print(&keep_buf, "{s}.keep", .{entry.name[0 .. entry.name.len - 4]});
                if (pack_dir.access(io, keep, .{})) |_| continue else |_| {}
                var head: [4]u8 = undefined;
                _ = try pack_dir.readFile(io, entry.name, &head);
                try std.testing.expectEqual(setting.index_v1, !std.mem.eql(u8, &head, "\xfftOc"));
            };
        }
        try ours.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
    }
}

test "core.looseCompression and core.compression set a loose object's level as git's" {
    for ([_]struct { []const u8, []const u8, u8 }{ .{ "core.looseCompression", "9", 0xDA }, .{ "core.compression", "0", 0x01 }, .{ "core.compression", "-1", 0x9C } }) |case| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try git.exec(io, &.{ "config", case[0], case[1] });
        var native = try repo_mod.Repository.open(gpa, io, git.dir, .{});
        defer native.deinit(io);
        const oid = try native.objectDatabase().write(io, .blob, "a blob of its own level\n");
        var hex: [hash.max_hex_len]u8 = undefined;
        const name = oid.hex(&hex);
        var path_buf: [128]u8 = undefined;
        var head: [2]u8 = undefined;
        _ = try git.dir.readFile(io, try std.mem.print(&path_buf, ".git/objects/{s}/{s}", .{ name[0..2], name[2..] }), &head);
        // git's own, for the same setting.
        const theirs = try blob(&git, "a blob git wrote at its level\n");
        defer gpa.free(theirs);
        var their_head: [2]u8 = undefined;
        _ = try git.dir.readFile(io, try std.mem.print(&path_buf, ".git/objects/{s}/{s}", .{ theirs[0..2], theirs[2..] }), &their_head);
        try std.testing.expectEqualSlices(u8, &their_head, &head);
        try std.testing.expectEqual(case[2], head[1]);
    }
}

test "core.multiPackIndex=false leaves the multi-pack index unread, as git's" {
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try commitAt(&git, testgit.fixture_date, "one");
    try git.exec(io, &.{ "repack", "-q", "-d", "--write-midx" });
    try git.exec(io, &.{ "config", "core.multiPackIndex", "false" });
    var native = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer native.deinit(io);
    var listed = try native.objectDatabase().listPacks(gpa, io, .own);
    defer gpa.free(listed);
    for (listed) |p| try std.testing.expect(!p.in_midx);
    try git.exec(io, &.{ "config", "core.multiPackIndex", "true" });
    _ = try native.refreshConfig(io, .{});
    try native.objectDatabase().refresh(io);
    gpa.free(listed);
    listed = try native.objectDatabase().listPacks(gpa, io, .own);
    for (listed) |p| try std.testing.expect(p.in_midx);
}

/// Two islands that share a base: `refs/virtual/1/` and `refs/virtual/2/`,
/// each with its own version of one large file over the base's.
fn islandFixture(repo: *testgit.Repo) !void {
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(gpa);
    for (0..400) |i| try base.print(gpa, "line {d} of the shared text\n", .{i});
    try repo.writeFile(io, "big.txt", base.items);
    try commitAt(repo, testgit.fixture_date, "base");
    for ([_][]const u8{ "1", "2" }) |island| {
        try repo.exec(io, &.{ "checkout", "-q", "--detach", "HEAD" });
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.appendSlice(gpa, base.items);
        try text.print(gpa, "island {s}'s own line\n", .{island});
        try repo.writeFile(io, "big.txt", text.items);
        try commitAt(repo, testgit.fixture_date + 60, island);
        var ref: [64]u8 = undefined;
        try repo.exec(io, &.{ "update-ref", try std.mem.print(&ref, "refs/virtual/{s}/heads/main", .{island}), "HEAD" });
        try repo.exec(io, &.{ "checkout", "-q", "main" });
    }
    try repo.exec(io, &.{ "config", "pack.island", "refs/virtual/([0-9]+)/" });
}

/// The deltas of the repository's packs whose base is in fewer of the
/// islands than the object, each island's objects by `git rev-list`.
fn crossIslandDeltas(repo: *testgit.Repo) !usize {
    var marks: std.StringHashMapUnmanaged(u2) = .empty;
    defer {
        var keys = marks.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        marks.deinit(gpa);
    }
    for ([_][]const u8{ "refs/virtual/1/heads/main", "refs/virtual/2/heads/main" }, 0..) |tip, island| {
        const listed = try repo.run(io, &.{ "rev-list", "--objects", tip });
        defer gpa.free(listed);
        var lines = std.mem.splitScalar(u8, listed, '\n');
        while (lines.next()) |line| {
            if (line.len < 40) continue;
            const slot = try marks.getOrPut(gpa, line[0..40]);
            if (!slot.found_existing) {
                slot.key_ptr.* = try gpa.dupe(u8, line[0..40]);
                slot.value_ptr.* = 0;
            }
            slot.value_ptr.* |= @as(u2, 1) << @intCast(island);
        }
    }
    var crossing: usize = 0;
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        var path_buf: [256]u8 = undefined;
        const listing = try repo.run(io, &.{ "verify-pack", "-v", try std.mem.print(&path_buf, ".git/objects/pack/{s}", .{entry.name}) });
        defer gpa.free(listing);
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            var fields: [8][]const u8 = undefined;
            var n: usize = 0;
            while (words.next()) |w| : (n += 1) if (n < fields.len) {
                fields[n] = w;
            };
            if (n < 7 or fields[0].len != 40) continue;
            const target = marks.get(fields[0]) orelse continue;
            const base = marks.get(fields[6]) orelse 0;
            if (target & ~base != 0) crossing += 1;
        }
    }
    return crossing;
}

test "repack -i keeps every delta within its object's islands, as git's" {
    for ([_]bool{ false, true }) |islands| {
        var theirs = try testgit.Repo.init(gpa, io, &.{});
        defer theirs.deinit();
        var ours = try testgit.Repo.init(gpa, io, &.{});
        defer ours.deinit();
        try islandFixture(&theirs);
        try islandFixture(&ours);
        try theirs.exec(io, if (islands) &.{ "repack", "-q", "-a", "-d", "-f", "-i" } else &.{ "repack", "-q", "-a", "-d", "-f" });
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var pack_options = native.objectDatabase().packOptions();
        pack_options.threads = 1;
        pack_options.reuse_packed = false;
        _ = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .delta_islands = islands, .pack = pack_options });
        const theirs_crossing = try crossIslandDeltas(&theirs);
        const ours_crossing = try crossIslandDeltas(&ours);
        if (islands) {
            try std.testing.expectEqual(@as(usize, 0), theirs_crossing);
            try std.testing.expectEqual(@as(usize, 0), ours_crossing);
        } else {
            // Without islands each makes a delta across them, so the
            // islands are what keeps them apart above.
            try std.testing.expect(theirs_crossing != 0);
            try std.testing.expect(ours_crossing != 0);
        }
        try ours.exec(io, &.{ "fsck", "--no-progress" });
    }
}

/// The packs in `dir`, each as its objects with their `.mtimes` times.
fn expiredPacks(repo: *testgit.Repo, sub: []const u8) ![]u8 {
    var dir = try repo.dir.openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        var index = try pack_mod.Index.open(gpa, io, dir, entry.name, .{ .kind = .sha1, .max_bytes = 1 << 30 });
        defer index.deinit();
        var name_buf: [128]u8 = undefined;
        // A pack with no `.mtimes` is no cruft pack.
        const times = mtimes.read(gpa, io, dir, try std.mem.print(&name_buf, "{s}.mtimes", .{entry.name[0 .. entry.name.len - 4]}), index.count) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer gpa.free(times);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        try line.appendSlice(gpa, "cruft");
        for (0..index.count) |i| {
            var hex: [hash.max_hex_len]u8 = undefined;
            try line.print(gpa, " {s}@{d}", .{ index.nameAt(@intCast(i)).hex(&hex), times[i] });
        }
        try lines.append(gpa, try line.toOwnedSlice(gpa));
    }
    var out: std.ArrayList(u8) = .empty;
    for (lines.items) |l| try out.print(gpa, "{s}\n", .{l});
    return out.toOwnedSlice(gpa);
}

test "repack --cruft -d --expire-to writes what goes into a cruft pack of its own, as git's" {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var theirs = try fixture(.files, now);
    defer theirs.deinit();
    var ours = try fixture(.files, now);
    defer ours.deinit();
    for ([_]*testgit.Repo{ &theirs, &ours }) |r| try r.dir.createDirPath(io, "expired");
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try theirs.dir.realPath(io, &root_buf)];
    var arg_buf: [Io.Dir.max_path_bytes + 32]u8 = undefined;
    var date_buf: [48]u8 = undefined;
    try theirs.exec(io, &.{ "repack", "-q", "-d", "--cruft", try std.mem.print(&date_buf, "--cruft-expiration=@{d}", .{now - 14 * day}), try std.mem.print(&arg_buf, "--expire-to={s}/expired/pack", .{root}) });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    var expired = try ours.dir.openDir(io, "expired", .{});
    defer expired.close(io);
    var pack_options = native.objectDatabase().packOptions();
    pack_options.threads = 1;
    const report = try repack_mod.repack(gpa, io, &native, .{ .mode = .cruft, .delete = true, .cruft_expiration = .fromRaw(now - 14 * day), .expire_to = .{ .dir = expired }, .pack = pack_options });
    try std.testing.expectEqual(@as(u32, 1), report.expired_written);
    const expected_expired = try expiredPacks(&theirs, "expired");
    defer gpa.free(expected_expired);
    const actual_expired = try expiredPacks(&ours, "expired");
    defer gpa.free(actual_expired);
    try std.testing.expect(expected_expired.len != 0);
    // git 2.55's `want_cruft_object_mtime` reads a cruft pack's `.mtimes`
    // by pack position where the file is in index order, so it may write a
    // second copy of an object its own cruft pack holds; relic compares
    // the object's own time. Those copies aside, the two are the same.
    const own_cruft = try expiredPacks(&theirs, ".git/objects/pack");
    defer gpa.free(own_cruft);
    var expected_set: std.ArrayList(u8) = .empty;
    defer expected_set.deinit(gpa);
    var words = std.mem.tokenizeAny(u8, expected_expired, " \n");
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "cruft")) continue;
        if (std.mem.find(u8, own_cruft, w[0..40]) != null) continue;
        try expected_set.print(gpa, "{s}\n", .{w});
    }
    var actual_set: std.ArrayList(u8) = .empty;
    defer actual_set.deinit(gpa);
    words = std.mem.tokenizeAny(u8, actual_expired, " \n");
    while (words.next()) |w| if (!std.mem.eql(u8, w, "cruft")) try actual_set.print(gpa, "{s}\n", .{w});
    try std.testing.expectEqualStrings(expected_set.items, actual_set.items);
    const expected = try state(&theirs);
    defer gpa.free(expected);
    const actual = try state(&ours);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "repack --filter puts what the filter leaves out into a pack of its own, as git's, --filter-to included" {
    const now = std.Io.Clock.real.now(io).toSeconds();
    for ([_]bool{ false, true }) |elsewhere| {
        var theirs = try fixture(.files, now);
        defer theirs.deinit();
        var ours = try fixture(.files, now);
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |r| try r.dir.createDirPath(io, "filtered");
        var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try theirs.dir.realPath(io, &root_buf)];
        var arg_buf: [Io.Dir.max_path_bytes + 32]u8 = undefined;
        if (elsewhere) {
            try theirs.exec(io, &.{ "repack", "-q", "-a", "-d", "--filter=blob:none", try std.mem.print(&arg_buf, "--filter-to={s}/filtered/pack", .{root}) });
        } else try theirs.exec(io, &.{ "repack", "-q", "-a", "-d", "--filter=blob:none" });
        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var filtered = try ours.dir.openDir(io, "filtered", .{});
        defer filtered.close(io);
        var pack_options = native.objectDatabase().packOptions();
        pack_options.threads = 1;
        const report = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true, .filter = .blob_none, .filter_to = if (elsewhere) .{ .dir = filtered } else null, .pack = pack_options });
        try std.testing.expectEqual(@as(u32, 1), report.filtered_written);
        const expected = try state(&theirs);
        defer gpa.free(expected);
        const actual = try state(&ours);
        defer gpa.free(actual);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("filter-to: {}\n", .{elsewhere});
            return err;
        };
    }
}

/// t7706's: a partial clone of `origin` with a commit, a blob of `big`
/// bytes and one of `small` that its promisor remote sent, each in a
/// promisor pack of its own and nowhere else.
fn dropFixture(now: i64) !struct { repo: testgit.Repo, big: [64]u8, small: [64]u8, hex_len: usize } {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    try commitAt(&repo, now - 10 * day, "base");
    for ([_][2][]const u8{
        .{ "core.repositoryformatversion", "1" },
        .{ "extensions.partialclone", "origin" },
        .{ "remote.origin.promisor", "true" },
        .{ "remote.origin.url", "." },
    }) |kv| try repo.exec(io, &.{ "config", kv[0], kv[1] });
    var big: [64]u8 = undefined;
    var small: [64]u8 = undefined;
    var len: usize = 0;
    for ([_]struct { size: usize, into: *[64]u8 }{ .{ .size = 3072, .into = &big }, .{ .size = 512, .into = &small } }, 0..) |wanted, n| {
        const oid = try promisorBlob(&repo, wanted.size, @intCast(n + 1));
        defer gpa.free(oid);
        @memcpy(wanted.into[0..oid.len], oid);
        len = oid.len;
    }
    return .{ .repo = repo, .big = big, .small = small, .hex_len = len };
}

/// Bytes no delta or compression makes small: the same for the same seed.
fn noise(buf: []u8, seed: u64) void {
    var state_value: u64 = seed *% 0x9e3779b97f4a7c15 +% 1;
    for (buf) |*b| {
        state_value ^= state_value << 13;
        state_value ^= state_value >> 7;
        state_value ^= state_value << 17;
        b.* = @truncate(state_value);
    }
}

/// A blob of `size` bytes in a promisor pack of its own, its loose copy
/// gone: t7706's `promisor_blob`. Its name, the caller's.
fn promisorBlob(repo: *testgit.Repo, size: usize, seed: u64) ![]u8 {
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    noise(bytes, seed);
    const oid = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, bytes);
    errdefer gpa.free(oid);
    const name = std.mem.trimEnd(u8, oid, "\n");
    const line = try std.mem.concat(gpa, u8, &.{ name, "\n" });
    defer gpa.free(line);
    const packed_name = try repo.runInput(io, &.{ "pack-objects", "-q", ".git/objects/pack/pack" }, line);
    defer gpa.free(packed_name);
    var path_buf: [128]u8 = undefined;
    try repo.dir.writeFile(io, .{ .sub_path = try std.mem.print(&path_buf, ".git/objects/pack/pack-{s}.promisor", .{std.mem.trimEnd(u8, packed_name, "\n")}), .data = "" });
    try repo.dir.deleteFile(io, try std.mem.print(&path_buf, ".git/objects/{s}/{s}", .{ name[0..2], name[2..] }));
    return gpa.realloc(oid, name.len);
}

test "repack --drop-filtered drops the promisor blobs git 2.56's does, and lists them as its --dry-run does" {
    try testgit.requireGitVersion(gpa, io, 2, 56);
    const now = std.Io.Clock.real.now(io).toSeconds();
    var theirs = try dropFixture(now);
    defer theirs.repo.deinit();
    var ours = try dropFixture(now);
    defer ours.repo.deinit();
    // a blob made here, which no promisor remote has, is never one
    for ([_]*testgit.Repo{ &theirs.repo, &ours.repo }) |r| {
        const bytes = try gpa.alloc(u8, 4096);
        defer gpa.free(bytes);
        noise(bytes, 9);
        gpa.free(try r.runInput(io, &.{ "hash-object", "-w", "--stdin" }, bytes));
    }
    const listed = try theirs.repo.run(io, &.{ "-c", "repack.writeBitmaps=false", "repack", "--drop-filtered", "--filter=blob:limit=1k", "--dry-run", "-a" });
    defer gpa.free(listed);
    var native = try repo_mod.Repository.open(gpa, io, ours.repo.dir, .{});
    defer native.deinit(io);
    const filter: @FieldType(repack_mod.Options, "filter") = .{ .blob_limit = .fromRaw(1024) };
    const candidates = try repack_mod.dropCandidates(gpa, io, &native, filter);
    defer gpa.free(candidates);
    var ours_listed: std.ArrayList(u8) = .empty;
    defer ours_listed.deinit(gpa);
    for (candidates) |oid| {
        var hex_buf: [64]u8 = undefined;
        try ours_listed.appendSlice(gpa, oid.hex(&hex_buf));
        try ours_listed.append(gpa, '\n');
    }
    try std.testing.expectEqualStrings(listed, ours_listed.items);
    try std.testing.expectEqualStrings(theirs.big[0..theirs.hex_len], ours_listed.items[0..ours.hex_len]);

    try theirs.repo.exec(io, &.{ "-c", "repack.writeBitmaps=false", "repack", "-q", "--drop-filtered", "--filter=blob:limit=1k", "-a" });
    var pack_options = native.objectDatabase().packOptions();
    pack_options.threads = 1;
    const report = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .filter = filter, .drop_filtered = true, .pack = pack_options });
    try std.testing.expectEqual(@as(u32, 1), report.dropped);
    const expected = try state(&theirs.repo);
    defer gpa.free(expected);
    const actual = try state(&ours.repo);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    ours.repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, ours.repo.exec(io, &.{ "cat-file", "-e", ours.big[0..ours.hex_len] }));
    try ours.repo.exec(io, &.{ "cat-file", "-e", ours.small[0..ours.hex_len] });
}

test "repack --drop-filtered refuses what git 2.56's refuses: no blob:limit filter, no -a, -b, no promisor remote, an operation under way, a blob the index names" {
    try testgit.requireGitVersion(gpa, io, 2, 56);
    const now = std.Io.Clock.real.now(io).toSeconds();
    var f = try dropFixture(now);
    defer f.repo.deinit();
    const repo = &f.repo;
    const filter: @FieldType(repack_mod.Options, "filter") = .{ .blob_limit = .fromRaw(1024) };
    const Refusal = struct { args: []const []const u8, options: repack_mod.Options, err: anyerror };
    const refusals = [_]Refusal{
        .{ .args = &.{ "--drop-filtered", "-a" }, .options = .{ .mode = .all, .drop_filtered = true }, .err = error.DropNeedsBlobLimit },
        .{ .args = &.{ "--drop-filtered", "--filter=blob:limit=1k" }, .options = .{ .filter = filter, .drop_filtered = true }, .err = error.DropIncompatible },
        .{ .args = &.{ "--drop-filtered", "--filter=blob:none", "-a" }, .options = .{ .mode = .all, .filter = .blob_none, .drop_filtered = true }, .err = error.DropNeedsBlobLimit },
        .{ .args = &.{ "--drop-filtered", "--filter=blob:limit=1k", "-a", "-b" }, .options = .{ .mode = .all, .filter = filter, .drop_filtered = true, .write_bitmaps = true }, .err = error.DropIncompatible },
    };
    const Check = struct {
        fn refused(r: *testgit.Repo, args: []const []const u8, options: repack_mod.Options, want: anyerror) !void {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.appendSlice(gpa, &.{ "repack", "-q" });
            try argv.appendSlice(gpa, args);
            r.report_failures = false;
            defer r.report_failures = true;
            std.testing.expectError(error.GitFailed, r.exec(io, argv.items)) catch |err| {
                for (args) |arg| std.debug.print("{s} ", .{arg});
                std.debug.print(": git took it\n", .{});
                return err;
            };
            var native = try repo_mod.Repository.open(gpa, io, r.dir, .{});
            defer native.deinit(io);
            try std.testing.expectError(want, repack_mod.repack(gpa, io, &native, options));
        }
    };
    for (refusals) |refusal| try Check.refused(repo, refusal.args, refusal.options, refusal.err);
    const dropping: repack_mod.Options = .{ .mode = .all, .filter = filter, .drop_filtered = true };
    const args: []const []const u8 = &.{ "--drop-filtered", "--filter=blob:limit=1k", "-a", "--dry-run" };

    // a merge under way
    const head = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try repo.dir.writeFile(io, .{ .sub_path = ".git/MERGE_HEAD", .data = head });
    try Check.refused(repo, args, dropping, error.OperationInProgress);
    try repo.dir.deleteFile(io, ".git/MERGE_HEAD");

    // a blob the index names that only the promisor pack holds
    const bytes = try gpa.alloc(u8, 4096);
    defer gpa.free(bytes);
    noise(bytes, 7);
    try repo.writeFile(io, "tracked-big.bin", bytes);
    try repo.exec(io, &.{ "add", "tracked-big.bin" });
    const tracked = try repo.line(io, &.{ "rev-parse", ":tracked-big.bin" });
    defer gpa.free(tracked);
    const line = try std.mem.concat(gpa, u8, &.{ tracked, "\n" });
    defer gpa.free(line);
    const packed_name = try repo.runInput(io, &.{ "pack-objects", "-q", ".git/objects/pack/pack" }, line);
    defer gpa.free(packed_name);
    var path_buf: [128]u8 = undefined;
    try repo.dir.writeFile(io, .{ .sub_path = try std.mem.print(&path_buf, ".git/objects/pack/pack-{s}.promisor", .{std.mem.trimEnd(u8, packed_name, "\n")}), .data = "" });
    try repo.dir.deleteFile(io, try std.mem.print(&path_buf, ".git/objects/{s}/{s}", .{ tracked[0..2], tracked[2..] }));
    try Check.refused(repo, args, dropping, error.DroppedBlobInIndex);
    try repo.exec(io, &.{ "rm", "-q", "--cached", "tracked-big.bin" });

    // no promisor remote
    try repo.exec(io, &.{ "config", "--unset", "extensions.partialclone" });
    try repo.exec(io, &.{ "config", "--unset", "remote.origin.promisor" });
    try Check.refused(repo, args, dropping, error.NoPromisorRemote);
}

test "repack --drop-filtered keeps a large blob made here, which no promisor remote can send again" {
    // git 2.56's loses it: its `--filter` leaves the blob out of the pack
    // of what is reachable, and `--drop-filtered` writes no pack of what
    // the filter left out before the old packs go.
    const now = std.Io.Clock.real.now(io).toSeconds();
    var f = try dropFixture(now);
    defer f.repo.deinit();
    const repo = &f.repo;
    const bytes = try gpa.alloc(u8, 4096);
    defer gpa.free(bytes);
    noise(bytes, 11);
    try repo.writeFile(io, "big.bin", bytes);
    try repo.exec(io, &.{ "add", "big.bin" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "big" });
    const local = try repo.line(io, &.{ "rev-parse", "HEAD:big.bin" });
    defer gpa.free(local);
    try repo.exec(io, &.{ "rm", "-q", "--cached", "big.bin" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "gone" });
    try repo.exec(io, &.{ "repack", "-q", "-a", "-d" });

    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    var pack_options = native.objectDatabase().packOptions();
    pack_options.threads = 1;
    const report = try repack_mod.repack(gpa, io, &native, .{ .mode = .all, .filter = .{ .blob_limit = .fromRaw(1024) }, .drop_filtered = true, .pack = pack_options });
    try std.testing.expectEqual(@as(u32, 1), report.dropped);
    try repo.exec(io, &.{ "cat-file", "-e", local });
    try repo.exec(io, &.{ "fsck", "--no-progress", "--connectivity-only" });
    repo.report_failures = false;
    try std.testing.expectError(error.GitFailed, repo.exec(io, &.{ "cat-file", "-e", f.big[0..f.hex_len] }));
}
