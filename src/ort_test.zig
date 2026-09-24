//! The merge against git's own: every result compared with what
//! `git merge-tree --write-tree -z --messages` prints for the same two
//! commits -- the tree, each conflicted path's stages, and every message
//! with its paths and its kind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const ort = @import("ort.zig");
const testgit = @import("testgit.zig");

const Oid = hash.Oid;

/// What `merge-tree -z --messages` prints, made from a result.
fn render(gpa: Allocator, result: *const ort.Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var hex: [hash.max_hex_len]u8 = undefined;
    try w.print("{s}\x00", .{result.tree.hex(&hex)});
    for (result.conflicted) |c| {
        for (c.stages, 1..) |stage, n| {
            const entry = stage orelse continue;
            try w.print("{o:0>6} {s} {d}\t{s}\x00", .{ entry.mode, entry.oid.hex(&hex), n, c.path });
        }
    }
    try w.writeByte(0);
    for (result.messages) |msg| {
        try w.print("{d}\x00", .{msg.paths.len});
        for (msg.paths) |p| try w.print("{s}\x00", .{p});
        try w.print("{s}\x00{s}\n\x00", .{ msg.kind.description(), msg.text });
    }
    return out.toOwnedSlice();
}

fn visible(gpa: Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, bytes);
    for (out) |*c| {
        if (c.* == 0) c.* = '|';
        if (c.* == '\n') c.* = '~';
    }
    return out;
}

fn revParse(gpa: Allocator, io: Io, repo: *testgit.Repo, rev: []const u8) !Oid {
    const text = try repo.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

/// The submodule at `sub/`, opened the way a caller would open it.
const SubOpener = struct {
    gpa: Allocator,
    io: Io,
    repo: *testgit.Repo,
    db: ?odb_mod.Odb = null,
    git_dir: ?Io.Dir = null,
    tips: std.ArrayList(Oid) = .empty,

    fn deinit(o: *SubOpener) void {
        if (o.db) |*db| db.deinit(o.io);
        if (o.git_dir) |d| d.close(o.io);
        o.tips.deinit(o.gpa);
    }

    fn open(context: *anyopaque, path: []const u8) ?ort.SubmoduleHistory {
        const o: *SubOpener = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, "sub")) return null;
        if (o.db) |*db| return .{ .db = db, .tips = o.tips.items };
        const git_dir = o.repo.dir.openDir(o.io, "sub/.git", .{}) catch return null;
        o.git_dir = git_dir;
        o.db = odb_mod.Odb.open(o.gpa, o.io, git_dir, .sha1, .{}) catch return null;
        const refs = o.repo.run(o.io, &.{ "-C", "sub", "for-each-ref", "--format=%(objectname)" }) catch return null;
        defer o.gpa.free(refs);
        var it = std.mem.tokenizeScalar(u8, refs, '\n');
        while (it.next()) |line| o.tips.append(o.gpa, Oid.parse(.sha1, line) catch continue) catch return null;
        return .{ .db = &o.db.?, .tips = o.tips.items };
    }
};

/// The merge of `ours` into `theirs` both ways, against git's.
fn expectSameMerge(gpa: Allocator, io: Io, repo: *testgit.Repo, ours: []const u8, theirs: []const u8, options: ort.Options) !void {
    var git = try repo.capture(io, &.{ "merge-tree", "--write-tree", "-z", "--messages", ours, theirs });
    defer git.deinit(gpa);
    const expected = git.stdout;

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var opts = options;
    opts.labels.ours = ours;
    opts.labels.theirs = theirs;
    const merged = ort.mergeCommits(gpa, io, &db, try revParse(gpa, io, repo, ours), try revParse(gpa, io, repo, theirs), null, opts);
    // On a few histories git's merge stops on one of its own assertions and
    // prints nothing. There the merge has to stop the same way, on the same
    // checks, and nowhere else.
    if (expected.len == 0 and git.code > 1) {
        const known = std.mem.indexOf(u8, git.stderr, "function handle_content_merge") != null or
            std.mem.indexOf(u8, git.stderr, "function process_entry") != null;
        if (merged) |r| {
            var result = r;
            result.deinit();
        } else |_| {}
        if (!known) {
            std.debug.print("git's merge-tree of {s} and {s} failed: {s}\n", .{ ours, theirs, git.stderr });
            return error.GitFailed;
        }
        try std.testing.expectError(error.DirectoryRenameLostStage, merged);
        return;
    }
    var result = try merged;
    defer result.deinit();
    const got = try render(gpa, &result);
    defer gpa.free(got);
    if (!std.mem.eql(u8, expected, got)) {
        const e = try visible(gpa, expected);
        defer gpa.free(e);
        const g = try visible(gpa, got);
        defer gpa.free(g);
        std.debug.print("merge of {s} and {s} differs\ngit:  {s}\nours: {s}\n", .{ ours, theirs, e, g });
        return error.TestExpectedEqual;
    }
}

fn commitAll(io: Io, repo: *testgit.Repo, msg: []const u8) !void {
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", msg });
}

fn lines(gpa: Allocator, prefix: []const u8, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..n) |i| try out.print(gpa, "{s} line {d}\n", .{ prefix, i });
    return out.toOwnedSlice(gpa);
}

test "renames, exact and edited, merge with the other side's changes as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    const body = try lines(gpa, "body", 20);
    defer gpa.free(body);
    try repo.writeFile(io, "a.txt", body);
    try repo.writeFile(io, "dir/b.txt", body[0 .. body.len / 2]);
    try repo.writeFile(io, "gone.txt", "short\n");
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    // main edits in place; topic renames, one with an edit.
    const edited = try std.mem.replaceOwned(u8, gpa, body, "body line 3\n", "body line three\n");
    defer gpa.free(edited);
    try repo.writeFile(io, "a.txt", edited);
    try repo.writeFile(io, "dir/b.txt", "changed wholly\n");
    try commitAll(io, &repo, "main edits");
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    try repo.exec(io, &.{ "mv", "a.txt", "renamed.txt" });
    const tail = try std.mem.replaceOwned(u8, gpa, body, "body line 19\n", "body line nineteen\n");
    defer gpa.free(tail);
    try repo.writeFile(io, "renamed.txt", tail);
    try repo.exec(io, &.{ "mv", "dir/b.txt", "moved-b.txt" });
    try repo.exec(io, &.{ "rm", "-q", "gone.txt" });
    try commitAll(io, &repo, "topic renames");

    try expectSameMerge(gpa, io, &repo, "main", "topic", .{});
    try expectSameMerge(gpa, io, &repo, "topic", "main", .{});
}

test "rename/rename, rename/delete and rename/add conflicts are git's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    const one = try lines(gpa, "one", 12);
    defer gpa.free(one);
    const two = try lines(gpa, "two", 12);
    defer gpa.free(two);
    const three = try lines(gpa, "three", 12);
    defer gpa.free(three);
    try repo.writeFile(io, "one", one);
    try repo.writeFile(io, "two", two);
    try repo.writeFile(io, "three", three);
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    try repo.exec(io, &.{ "mv", "one", "one-main" });
    try repo.exec(io, &.{ "mv", "two", "two-moved" });
    try repo.writeFile(io, "added", three);
    try commitAll(io, &repo, "main");
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    try repo.exec(io, &.{ "mv", "one", "one-topic" });
    try repo.exec(io, &.{ "rm", "-q", "two" });
    try repo.exec(io, &.{ "mv", "three", "added" });
    const more = try std.mem.concat(gpa, u8, &.{ three, "more\n" });
    defer gpa.free(more);
    try repo.writeFile(io, "added", more);
    try commitAll(io, &repo, "topic");

    try expectSameMerge(gpa, io, &repo, "main", "topic", .{});
    try expectSameMerge(gpa, io, &repo, "topic", "main", .{});
}

test "a rename both ways that a directory rename lands on a directory stops where git's merge stops" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "lib/a.txt", "one\ntwo\nthree\n");
    try repo.writeFile(io, "lib/util/f5.txt", "x\ny\nz\n");
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    // main moves the whole of lib/, so lib/util/f5.txt goes with it.
    try repo.exec(io, &.{ "mv", "lib", "moved" });
    try commitAll(io, &repo, "main");
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    // topic renames lib/util/f5.txt to lib/util, a file where its
    // directory was, which main's move then carries to moved/util -- a
    // directory on main's side.
    try repo.exec(io, &.{ "rm", "-q", "lib/util/f5.txt" });
    try repo.writeFile(io, "lib/util", "x\ny\nz\n");
    try commitAll(io, &repo, "topic");

    // Merged into topic, git stops on its assertion and so does this.
    var git = try repo.capture(io, &.{ "merge-tree", "--write-tree", "topic", "main" });
    defer git.deinit(gpa);
    try std.testing.expectEqualStrings("", git.stdout);
    try std.testing.expect(std.mem.indexOf(u8, git.stderr, "handle_content_merge") != null);
    try expectSameMerge(gpa, io, &repo, "topic", "main", .{});
    // Merged into main the file is on the other side, and both finish.
    try expectSameMerge(gpa, io, &repo, "main", "topic", .{});
}

test "a rename a directory rename lands on a directory, whose source is also moved aside, stops where git's merge stops" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "docs", "x\ny\nz\n");
    try repo.writeFile(io, "src/core/f5.txt/inner.txt", "x\ny\nz\n");
    try repo.writeFile(io, "src/other.txt", "y\n");
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    // main renames docs to src/core/f5.txt, where a directory was, and
    // makes docs a directory.
    try repo.exec(io, &.{ "rm", "-rq", "docs", "src/core" });
    try repo.writeFile(io, "docs/f1.txt", "x\ny\nz\n");
    try repo.writeFile(io, "docs/f3.txt", "w\n");
    try repo.writeFile(io, "src/core/f5.txt", "x\ny\nz\n");
    try commitAll(io, &repo, "main");
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    // topic moves src/ to moved1/, which carries main's rename onto its
    // directory moved1/core/f5.txt.
    try repo.exec(io, &.{ "mv", "src", "moved1" });
    try commitAll(io, &repo, "topic");

    var git = try repo.capture(io, &.{ "merge-tree", "--write-tree", "main", "topic" });
    defer git.deinit(gpa);
    try std.testing.expectEqualStrings("", git.stdout);
    try std.testing.expect(std.mem.indexOf(u8, git.stderr, "function process_entry") != null);
    try expectSameMerge(gpa, io, &repo, "main", "topic", .{});
    try expectSameMerge(gpa, io, &repo, "topic", "main", .{});
}

/// A random history for the merge to meet: files in a few directories,
/// then each side renaming, moving whole directories, editing, deleting,
/// adding, changing modes and types, and putting files where directories
/// were and the other way round.
const Scenario = struct {
    gpa: Allocator,
    io: Io,
    repo: *testgit.Repo,
    random: std.Random,
    files: std.StringArrayHashMapUnmanaged(void) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Fewer names and more duplication: renames that tie, basenames
    /// shared across directories, identical files, empty ones.
    crowded: bool = false,

    const dirs = [_][]const u8{ "", "src", "src/core", "docs", "lib", "lib/util", "assets" };
    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa" };

    fn text(s: *Scenario, n_in: usize) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = s.arena.allocator();
        var n = n_in;
        if (s.crowded) switch (s.random.uintLessThan(u8, 8)) {
            0 => return "",
            1 => return "same content\nin several files\n",
            2 => return "binary\x00data\n",
            3 => n *= 4,
            else => {},
        };
        for (0..n) |_| {
            try out.print(a, "{s} {s} {d}\n", .{ words[s.random.uintLessThan(usize, words.len)], words[s.random.uintLessThan(usize, words.len)], s.random.uintLessThan(u32, 40) });
        }
        return out.items;
    }

    fn pathIn(s: *Scenario, dir: []const u8) ![]const u8 {
        const a = s.arena.allocator();
        const name = try std.fmt.allocPrint(a, "f{d}.txt", .{s.random.uintLessThan(u32, if (s.crowded) 6 else 30)});
        if (dir.len == 0) return name;
        return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    }

    fn refresh(s: *Scenario) !void {
        s.files.clearRetainingCapacity();
        try s.repo.exec(s.io, &.{ "add", "-A" });
        const listing = try s.repo.run(s.io, &.{ "ls-files", "-z" });
        defer s.gpa.free(listing);
        var it = std.mem.splitScalar(u8, listing, 0);
        while (it.next()) |p| {
            if (p.len == 0) continue;
            try s.files.put(s.arena.allocator(), try s.arena.allocator().dupe(u8, p), {});
        }
    }

    fn pick(s: *Scenario) ?[]const u8 {
        if (s.files.count() == 0) return null;
        return s.files.keys()[s.random.uintLessThan(usize, s.files.count())];
    }

    fn remove(s: *Scenario, path: []const u8) !void {
        s.repo.dir.deleteFile(s.io, path) catch {};
    }

    fn write(s: *Scenario, path: []const u8, bytes: []const u8) !void {
        // A file where a directory stands takes its place, and the other
        // way round.
        if (try isDirectory(s, path)) try s.repo.dir.deleteTree(s.io, path);
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, at, '/')) |slash| {
            const prefix = path[0..slash];
            if (!try isDirectory(s, prefix)) s.repo.dir.deleteFile(s.io, prefix) catch {};
            at = slash + 1;
        }
        s.repo.dir.deleteFile(s.io, path) catch {};
        try s.repo.writeFile(s.io, path, bytes);
    }

    fn isDirectory(s: *Scenario, path: []const u8) !bool {
        var d = s.repo.dir.openDir(s.io, path, .{}) catch return false;
        d.close(s.io);
        return true;
    }

    fn read(s: *Scenario, path: []const u8) ![]u8 {
        return s.repo.dir.readFileAlloc(s.io, path, s.arena.allocator(), .limited(1 << 20)) catch "";
    }

    fn edit(s: *Scenario, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = s.arena.allocator();
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            switch (s.random.uintLessThan(u8, 10)) {
                0 => {},
                1 => try out.print(a, "{s} edited\n", .{line}),
                2 => try out.print(a, "{s}\ninserted {d}\n", .{ line, s.random.uintLessThan(u32, 9) }),
                else => try out.print(a, "{s}\n", .{line}),
            }
        }
        return out.items;
    }

    fn operate(s: *Scenario, count: usize) !void {
        for (0..count) |_| {
            try s.refresh();
            const path = s.pick() orelse return;
            switch (s.random.uintLessThan(u8, 12)) {
                0, 1 => try s.write(path, try s.edit(try s.read(path))),
                2 => try s.remove(path),
                3, 4 => {
                    // A rename, perhaps with an edit.
                    const target = try s.pathIn(dirs[s.random.uintLessThan(usize, dirs.len)]);
                    var bytes = try s.read(path);
                    if (s.random.boolean()) bytes = try s.edit(bytes);
                    try s.remove(path);
                    try s.write(target, bytes);
                },
                5 => {
                    // A whole directory moved.
                    const dir = std.fs.path.dirnamePosix(path) orelse continue;
                    const a = s.arena.allocator();
                    const to = try std.fmt.allocPrint(a, "moved{d}/{s}", .{ s.random.uintLessThan(u32, 3), std.fs.path.basenamePosix(dir) });
                    for (s.files.keys()) |f| {
                        if (!std.mem.startsWith(u8, f, dir) or f.len <= dir.len or f[dir.len] != '/') continue;
                        const bytes = try s.read(f);
                        try s.remove(f);
                        try s.write(try std.fmt.allocPrint(a, "{s}{s}", .{ to, f[dir.len..] }), bytes);
                    }
                },
                6, 7 => try s.write(try s.pathIn(dirs[s.random.uintLessThan(usize, dirs.len)]), try s.text(4 + s.random.uintLessThan(usize, 8))),
                8 => {
                    if (@import("builtin").os.tag == .windows) continue;
                    // A symlink has no executable bit to set.
                    s.repo.report_failures = false;
                    defer s.repo.report_failures = true;
                    s.repo.exec(s.io, &.{ "update-index", "--chmod=+x", path }) catch continue;
                    try s.repo.exec(s.io, &.{ "checkout", "--", path });
                },
                9 => {
                    if (@import("builtin").os.tag == .windows) continue;
                    try s.remove(path);
                    s.repo.dir.symLink(s.io, "target", path, .{}) catch {};
                },
                10 => {
                    // A directory where a file was.
                    const a = s.arena.allocator();
                    try s.remove(path);
                    try s.write(try std.fmt.allocPrint(a, "{s}/inner.txt", .{path}), try s.text(3));
                },
                11 => {
                    // A file where a directory was.
                    const dir = std.fs.path.dirnamePosix(path) orelse continue;
                    try s.write(dir, try s.text(3));
                },
                else => unreachable,
            }
        }
        try s.repo.exec(s.io, &.{ "add", "-A" });
    }
};

fn runScenario(gpa: Allocator, io: Io, seed: u64, crowded: bool) !void {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    var s: Scenario = .{ .gpa = gpa, .io = io, .repo = &repo, .random = prng.random(), .arena = .init(gpa), .crowded = crowded };
    defer s.arena.deinit();

    for (0..12) |_| try s.write(try s.pathIn(Scenario.dirs[s.random.uintLessThan(usize, Scenario.dirs.len)]), try s.text(6 + s.random.uintLessThan(usize, 10)));
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    try s.operate(1 + s.random.uintLessThan(usize, 5));
    try commitAll(io, &repo, "main");
    try repo.exec(io, &.{ "checkout", "-q", "-f", "topic" });
    try repo.exec(io, &.{ "clean", "-q", "-fdx" });
    try s.operate(1 + s.random.uintLessThan(usize, 5));
    try commitAll(io, &repo, "topic");

    expectSameMerge(gpa, io, &repo, "main", "topic", .{}) catch |err| {
        std.debug.print("seed {d}\n", .{seed});
        {
            const human = try repo.runInput(io, &.{ "merge-tree", "--write-tree", "--messages", "main", "topic" }, "");
            defer gpa.free(human);
            std.debug.print("human:\n{s}\n", .{human});
            const ver = try repo.run(io, &.{"version"});
            defer gpa.free(ver);
            std.debug.print("{s}\n", .{ver});
        }
        for ([_][]const u8{ "main~1", "main", "topic" }) |rev| {
            const t = try repo.run(io, &.{ "ls-tree", "-r", rev });
            defer gpa.free(t);
            std.debug.print("== {s}\n{s}", .{ rev, t });
        }
        return err;
    };
    expectSameMerge(gpa, io, &repo, "topic", "main", .{}) catch |err| {
        std.debug.print("seed {d} reversed\n", .{seed});
        for ([_][]const u8{ "main~1", "main", "topic" }) |rev| {
            const t = try repo.run(io, &.{ "ls-tree", "-r", rev });
            defer gpa.free(t);
            std.debug.print("== {s}\n{s}", .{ rev, t });
        }
        return err;
    };
    try repo.exec(io, &.{ "config", "merge.directoryRenames", "true" });
    expectSameMerge(gpa, io, &repo, "main", "topic", .{ .directory_renames = .on }) catch |err| {
        std.debug.print("seed {d}, directory renames on\n", .{seed});
        return err;
    };
}

test "random histories merge to git's trees, stages and messages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    for (0..scenario_count) |seed| try runScenario(gpa, io, seed, false);
    for (0..scenario_count) |seed| try runScenario(gpa, io, seed, true);
}

const scenario_count = testgit.corpusCases(40);

/// Two branches that each merged the other once, with more changes after,
/// so the merge has two bases to merge first.
fn runCrissCross(gpa: Allocator, io: Io, seed: u64) !void {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    var s: Scenario = .{ .gpa = gpa, .io = io, .repo = &repo, .random = prng.random(), .arena = .init(gpa), .crowded = seed % 2 == 1 };
    defer s.arena.deinit();

    for (0..12) |_| try s.write(try s.pathIn(Scenario.dirs[s.random.uintLessThan(usize, Scenario.dirs.len)]), try s.text(6 + s.random.uintLessThan(usize, 10)));
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    try s.operate(1 + s.random.uintLessThan(usize, 4));
    try commitAll(io, &repo, "main one");
    try repo.exec(io, &.{ "branch", "main-one" });
    try repo.exec(io, &.{ "checkout", "-q", "-f", "topic" });
    try repo.exec(io, &.{ "clean", "-q", "-fdx" });
    try s.operate(1 + s.random.uintLessThan(usize, 4));
    try commitAll(io, &repo, "topic one");
    try repo.exec(io, &.{ "merge", "-q", "-s", "ours", "--no-edit", "main-one" });
    try s.operate(1 + s.random.uintLessThan(usize, 3));
    try commitAll(io, &repo, "topic two");
    try repo.exec(io, &.{ "checkout", "-q", "-f", "main" });
    try repo.exec(io, &.{ "clean", "-q", "-fdx" });
    try repo.exec(io, &.{ "merge", "-q", "-s", "ours", "--no-edit", "topic~1" });
    try s.operate(1 + s.random.uintLessThan(usize, 3));
    try commitAll(io, &repo, "main two");

    expectSameMerge(gpa, io, &repo, "main", "topic", .{}) catch |err| {
        std.debug.print("criss-cross seed {d}\n", .{seed});
        return err;
    };
    expectSameMerge(gpa, io, &repo, "topic", "main", .{}) catch |err| {
        std.debug.print("criss-cross seed {d} reversed\n", .{seed});
        return err;
    };
    // At verbosity 5 git keeps the inner merges' messages too.
    try repo.isolated.?.put("GIT_MERGE_VERBOSITY", "5");
    expectSameMerge(gpa, io, &repo, "main", "topic", .{ .inner_messages = true }) catch |err| {
        std.debug.print("criss-cross seed {d} with the inner merges' messages\n", .{seed});
        return err;
    };
}

test "criss-cross histories merge their bases first, as git's recursive merge does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    for (0..criss_cross_count) |seed| try runCrissCross(gpa, io, seed);
}

const criss_cross_count = testgit.corpusCases(30);

test "submodules merge by fast-forward, or say which merge would join them, as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    try repo.writeFile(io, "top", "top\n");
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "init", "-q", "-b", "main", "sub" });
    try repo.writeFile(io, "sub/s", "s1\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "s1" });
    try repo.exec(io, &.{ "submodule", "add", "-q", "./sub", "sub" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "add sub" });
    // In the submodule: `left` and `right` from `main`, `ahead` after
    // `left`, and `joined`, a merge of the two.
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "left", "main" });
    try repo.writeFile(io, "sub/left", "l\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "left" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "ahead" });
    try repo.writeFile(io, "sub/ahead", "a\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "ahead" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "right", "main" });
    try repo.writeFile(io, "sub/right", "r\n");
    try repo.exec(io, &.{ "-C", "sub", "add", "-A" });
    try repo.exec(io, &.{ "-C", "sub", "commit", "-q", "-m", "right" });
    try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", "-b", "joined" });
    try repo.exec(io, &.{ "-C", "sub", "merge", "-q", "--no-edit", "left" });
    // In the superproject: one branch per submodule commit.
    for ([_][]const u8{ "left", "ahead", "right" }) |name| {
        try repo.exec(io, &.{ "-C", "sub", "checkout", "-q", name });
        try repo.exec(io, &.{ "checkout", "-q", "-b", name, "main" });
        try repo.exec(io, &.{ "add", "sub" });
        try repo.exec(io, &.{ "commit", "-q", "-m", name });
    }
    try repo.exec(io, &.{ "checkout", "-q", "main" });

    var opener: SubOpener = .{ .gpa = gpa, .io = io, .repo = &repo };
    defer opener.deinit();
    const subs: ort.Submodules = .{ .context = &opener, .openFn = SubOpener.open };
    try expectSameMerge(gpa, io, &repo, "left", "ahead", .{ .submodules = subs });
    try expectSameMerge(gpa, io, &repo, "left", "right", .{ .submodules = subs });
    // Without the submodule's history, git calls it not checked out.
    try repo.dir.rename("sub/.git", repo.dir, "sub/.git-away", io);
    try expectSameMerge(gpa, io, &repo, "ahead", "right", .{});
    try repo.dir.rename("sub/.git-away", repo.dir, "sub/.git", io);
}

test "a rename search too big for merge.renameLimit is skipped as git skips it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();

    var names: [4][]u8 = undefined;
    for (&names, 0..) |*name, i| name.* = try std.fmt.allocPrint(gpa, "file{d}", .{i});
    defer for (names) |name| gpa.free(name);
    for (names) |name| {
        const body = try lines(gpa, name, 10);
        defer gpa.free(body);
        try repo.writeFile(io, name, body);
    }
    try commitAll(io, &repo, "base");
    try repo.exec(io, &.{ "branch", "topic" });
    for (names) |name| {
        const body = try lines(gpa, name, 11);
        defer gpa.free(body);
        try repo.writeFile(io, name, body);
    }
    try commitAll(io, &repo, "main edits");
    try repo.exec(io, &.{ "checkout", "-q", "topic" });
    for (names) |name| {
        const body = try lines(gpa, name, 10);
        defer gpa.free(body);
        const edited = try std.mem.concat(gpa, u8, &.{ "first\n", body });
        defer gpa.free(edited);
        try repo.dir.deleteFile(io, name);
        const moved = try std.fmt.allocPrint(gpa, "moved-{s}", .{name});
        defer gpa.free(moved);
        try repo.writeFile(io, moved, edited);
    }
    try commitAll(io, &repo, "topic renames");

    try repo.exec(io, &.{ "config", "merge.renameLimit", "2" });
    try expectSameMerge(gpa, io, &repo, "main", "topic", .{ .rename_limit = 2 });
    try repo.exec(io, &.{ "config", "merge.renameLimit", "4" });
    try expectSameMerge(gpa, io, &repo, "main", "topic", .{ .rename_limit = 4 });
}

const diff = @import("diff.zig");

fn renderNameStatus(gpa: Allocator, changes: *const diff.Changes) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    for (changes.items) |c| {
        switch (c.status) {
            .renamed, .copied => try w.print("{c}{d:0>3}\x00{s}\x00{s}\x00", .{ c.letter(), c.similarity, c.old.?.path, c.new.?.path }),
            else => try w.print("{c}\x00{s}\x00", .{ c.letter(), c.path() }),
        }
    }
    return out.toOwnedSlice();
}

fn expectSameDiff(gpa: Allocator, io: Io, repo: *testgit.Repo, flags: []const []const u8, options: diff.RenameOptions) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "diff-tree", "-r", "-z", "--name-status" });
    try argv.appendSlice(gpa, flags);
    try argv.appendSlice(gpa, &.{ "main~1", "main" });
    const expected = try repo.run(io, argv.items);
    defer gpa.free(expected);

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    const old_tree = try revParse(gpa, io, repo, "main~1^{tree}");
    const new_tree = try revParse(gpa, io, repo, "main^{tree}");
    var changes = try diff.tree(gpa, io, &db, old_tree, new_tree, .{ .renames = options });
    defer changes.deinit();
    const got = try renderNameStatus(gpa, &changes);
    defer gpa.free(got);
    if (!std.mem.eql(u8, expected, got)) {
        const e = try visible(gpa, expected);
        defer gpa.free(e);
        const g = try visible(gpa, got);
        defer gpa.free(g);
        std.debug.print("diff {s} differs\ngit:  {s}\nours: {s}\n", .{ flags[flags.len - 1], e, g });
        return error.TestExpectedEqual;
    }
}

fn runDiffScenario(gpa: Allocator, io: Io, seed: u64) !void {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    var s: Scenario = .{ .gpa = gpa, .io = io, .repo = &repo, .random = prng.random(), .arena = .init(gpa), .crowded = seed % 2 == 1 };
    defer s.arena.deinit();
    for (0..14) |_| try s.write(try s.pathIn(Scenario.dirs[s.random.uintLessThan(usize, Scenario.dirs.len)]), try s.text(6 + s.random.uintLessThan(usize, 10)));
    try commitAll(io, &repo, "base");
    try s.operate(2 + s.random.uintLessThan(usize, 6));
    try commitAll(io, &repo, "changes");

    errdefer std.debug.print("diff seed {d}\n", .{seed});
    try expectSameDiff(gpa, io, &repo, &.{"-M"}, .{});
    try expectSameDiff(gpa, io, &repo, &.{"-M30%"}, .{ .threshold = 30 });
    try expectSameDiff(gpa, io, &repo, &.{"-C"}, .{ .detect_copies = true });
    try expectSameDiff(gpa, io, &repo, &.{ "-C", "--find-copies-harder" }, .{ .detect_copies = true, .find_copies_harder = true });
}

test "diff -M, -M30%, -C and --find-copies-harder pair what git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    for (0..diff_scenario_count) |seed| try runDiffScenario(gpa, io, seed);
}

const diff_scenario_count = testgit.corpusCases(60);
