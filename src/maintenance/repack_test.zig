//! `repack` held to git 2.55's: the same repository repacked by each, and
//! what each object directory then holds compared -- which objects each
//! pack holds and what kind of pack it is, a cruft pack's times, the loose
//! objects and their times, `.git/shallow` and the dumb HTTP files. The
//! packs' bytes differ (relic's delta search is its own), never what they
//! hold.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const repack_mod = @import("repack.zig");
const repo_mod = @import("../repo/repo.zig");
const pack_mod = @import("../odb/pack.zig");
const mtimes = @import("../odb/mtimes.zig");
const hash = @import("../hash/hash.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;

const day = std.time.s_per_day;

fn at(repo: *testgit.Repo, secs: i64) !void {
    var buffer: [32]u8 = undefined;
    const value = try std.mem.print(&buffer, "@{d} +0000", .{secs});
    try repo.isolated.?.put("GIT_AUTHOR_DATE", value);
    try repo.isolated.?.put("GIT_COMMITTER_DATE", value);
}

fn commitAt(repo: *testgit.Repo, secs: i64, message: []const u8) !void {
    try at(repo, secs);
    try repo.writeFile(io, "file.txt", message);
    try repo.exec(io, &.{ "add", "file.txt" });
    try repo.exec(io, &.{ "commit", "-q", "-m", message });
}

fn setTime(dir: Io.Dir, name: []const u8, secs: i64) !void {
    try dir.setTimestamps(io, name, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, secs) * std.time.ns_per_s) } });
}

/// Every loose file's time, and every pack file's, set to `secs`.
fn ageAll(repo: *testgit.Repo, secs: i64) !void {
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

fn touchObject(repo: *testgit.Repo, hex: []const u8, secs: i64) !void {
    var buffer: [128]u8 = undefined;
    const path = try std.mem.print(&buffer, ".git/objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    try setTime(repo.dir, path, secs);
}

fn blob(repo: *testgit.Repo, bytes: []const u8) ![]u8 {
    const out = try repo.runInput(io, &.{ "hash-object", "-w", "--stdin" }, bytes);
    defer gpa.free(out);
    return gpa.dupe(u8, std.mem.trim(u8, out, "\n"));
}

/// A commit nothing names, on a tree of its own holding one new blob.
fn dangling(repo: *testgit.Repo, contents: []const u8, parent: ?[]const u8, message: []const u8) ![]u8 {
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
fn fixture(format: testgit.RefFormat, now: i64) !testgit.Repo {
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
/// (a cruft pack's with their times), the loose objects with their times,
/// then `.git/shallow` and the dumb HTTP files.
fn state(repo: *testgit.Repo) ![]u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
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
        options.pack.threads = 1;
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
        .{ .args = &.{ "-A", "-d", unpack_arg }, .options = .{ .mode = .all_loosen, .delete = true, .unpack_unreachable = now - 14 * day } },
        .{ .args = &.{ "--cruft", "-d" }, .options = .{ .mode = .cruft, .delete = true } },
        .{ .args = &.{ "--cruft", "-d", expiration_arg }, .options = .{ .mode = .cruft, .delete = true, .cruft_expiration = now - 14 * day } },
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
        .{ .args = &.{ "--cruft", "-d", expiration_arg }, .options = .{ .mode = .cruft, .delete = true, .cruft_expiration = now - 14 * day } },
        .{ .args = &.{ "-A", "-d", unpack_arg }, .options = .{ .mode = .all_loosen, .delete = true, .unpack_unreachable = now - 14 * day } },
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

test "repack refuses what git refuses" {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try commitAt(&repo, testgit.fixture_date, "one");
    var native = try repo_mod.Repository.open(gpa, io, repo.dir, .{});
    defer native.deinit(io);
    try std.testing.expectError(error.IncompatibleOptions, repack_mod.repack(gpa, io, &native, .{ .mode = .cruft, .keep_unreachable = true }));
    try std.testing.expectError(error.IncompatibleOptions, repack_mod.repack(gpa, io, &native, .{ .mode = .all_loosen, .keep_unreachable = true }));
    try std.testing.expectError(error.IncrementalBitmaps, repack_mod.repack(gpa, io, &native, .{ .write_bitmaps = true }));
    try repo.exec(io, &.{ "config", "extensions.preciousObjects", "true" });
    _ = try native.refreshConfig(io, .{});
    try std.testing.expectError(error.PreciousObjects, repack_mod.repack(gpa, io, &native, .{ .mode = .all, .delete = true }));
}
