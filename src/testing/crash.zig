//! Crashes during the writes a repository lives by (design §12c), on
//! shakedown's simulated disk: a ref update, a received pack and the ref
//! that publishes it, an index write, a checkout, `pack-refs`,
//! `reflog expire`, `prune` and `repack` (`-a -d`, `--cruft -d` and
//! `--geometric=2 -d --write-midx`), the commit graph `gc` writes and
//! `maintenance`'s loose-objects and incremental-repack tasks,
//! each stopped before
//! every `Io` call it makes and every state the disk could come back in
//! after that tried. airlock's syncs and renames reach the simulated disk
//! through its seam, at the strength each one has.
//!
//! What every state must be: a repository relic opens, whose index reads
//! whole and whose status never calls a changed file clean (git's racy
//! rule, with the disk's clock at one second, so every file written in the
//! second the index is written is racily clean); and, copied out of the
//! simulation, a repository `git fsck --full` passes, with every ref the
//! run changes at its old value or its new one and no commit lost. The
//! repository asks for every sync git has (`core.fsync=all`), and the
//! checkout syncs what it writes, so what git promises under that
//! configuration is what is held.
//!
//! Each distinct state is checked by git once, after the simulation, so a
//! state reached from many crash points costs one `git fsck`.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const checkout = @import("../checkout/checkout.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const refs = @import("../refs/refs.zig");
const gc = @import("../maintenance/gc.zig");
const prune = @import("../maintenance/prune.zig");
const repack = @import("../maintenance/repack.zig");
const maintenance = @import("../maintenance/maintenance.zig");
const maintenance_run = @import("../maintenance/run.zig");
const date = @import("../text.zig").date;
const Oid = hash.Oid;

const os = builtin.target.os.tag;

/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

/// git's racy-git granularity: a file system that keeps whole seconds.
const granularity: Io.Duration = .fromSeconds(1);

const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

const Kind = enum { ref_update, pack_receive, index_write, checkout, pack_refs, reflog_expire, prune, repack, repack_cruft, repack_geometric, commit_graph, loose_objects, incremental_repack };

/// A directory tree held in memory: what is put on the simulated disk
/// before a run, and what a crash state holds.
const Image = struct {
    /// Directories, parents first.
    dirs: std.ArrayList([]u8) = .empty,
    files: std.ArrayList(File) = .empty,

    const File = struct { path: []u8, bytes: []u8, mtime: i96 = 0 };

    fn deinit(image: *Image, gpa: std.mem.Allocator) void {
        for (image.dirs.items) |d| gpa.free(d);
        image.dirs.deinit(gpa);
        for (image.files.items) |f| {
            gpa.free(f.path);
            gpa.free(f.bytes);
        }
        image.files.deinit(gpa);
    }

    /// Everything under `dir`, read through `io`; `.git/hooks` left out.
    fn read(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !Image {
        var image: Image = .{};
        errdefer image.deinit(gpa);
        try image.readInto(gpa, io, dir, "");
        std.mem.sortUnstable(File, image.files.items, {}, struct {
            fn less(_: void, a: File, b: File) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
        return image;
    }

    fn readInto(image: *Image, gpa: std.mem.Allocator, io: Io, dir: Io.Dir, prefix: []const u8) !void {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const path = if (prefix.len == 0) try gpa.dupe(u8, entry.name) else try std.Io.Dir.path.join(gpa, &.{ prefix, entry.name });
            var kept = false;
            defer if (!kept) gpa.free(path);
            switch (entry.kind) {
                .directory => {
                    if (std.mem.eql(u8, path, ".git/hooks")) continue;
                    try image.dirs.append(gpa, path);
                    kept = true;
                    var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                    defer sub.close(io);
                    try image.readInto(gpa, io, sub, path);
                },
                .file => {
                    const bytes = try dir.readFileAlloc(io, entry.name, gpa, .limited(16 << 20));
                    errdefer gpa.free(bytes);
                    const stat = try dir.statFile(io, entry.name, .{});
                    try image.files.append(gpa, .{ .path = path, .bytes = bytes, .mtime = stat.mtime.nanoseconds });
                    kept = true;
                },
                else => return error.UnexpectedEntry,
            }
        }
    }

    /// The image's identity: every path and its bytes, in order.
    fn digest(image: *const Image) [32]u8 {
        var h: std.crypto.hash.sha2.Sha256 = .init(.{});
        for (image.files.items) |f| {
            h.update(f.path);
            h.update(&std.mem.toBytes(@as(u64, f.bytes.len)));
            h.update(f.bytes);
            h.update(&std.mem.toBytes(f.mtime));
        }
        for (image.dirs.items) |d| {
            h.update(d);
            h.update("/");
        }
        return h.finalResult();
    }

    /// Write the image into `dir` through `io`.
    fn write(image: *const Image, io: Io, dir: Io.Dir) !void {
        for (image.dirs.items) |d| try dir.createDirPath(io, d);
        for (image.files.items) |f| try dir.writeFile(io, .{ .sub_path = f.path, .data = f.bytes });
    }
};

/// The repositories every case starts from, made by git.
const Seeds = struct {
    /// `main` at the first commit, its objects loose.
    before: Image,
    /// `main` at the first commit, checked out; `next` at the second; packed.
    after: Image,
    /// `after` with what `prune` takes away: an unreachable blob and
    /// commit, loose copies of packed objects, a stale temporary file.
    pruning: Image,
    /// Every object `pruning` holds, one name a line, sorted: what a
    /// repack keeps at every crash.
    pruning_objects: []u8,
    /// The second commit's objects that the first lacks.
    pack: []u8,
    first: [40]u8,
    second: [40]u8,

    fn make(gpa: std.mem.Allocator, io: Io, format: testgit.RefFormat) !Seeds {
        var git = try testgit.Repo.init(gpa, io, format.initArgs());
        defer git.deinit();
        try git.exec(io, &.{ "config", "core.fsync", "all" });
        try git.exec(io, &.{ "config", "core.fsyncMethod", "fsync" });
        try git.writeFile(io, "a", "one\n");
        try git.writeFile(io, "dir/b", "bee\n");
        try git.exec(io, &.{ "add", "." });
        try git.exec(io, &.{ "commit", "-qm", "first" });
        var seeds: Seeds = undefined;
        seeds.before = try Image.read(gpa, io, git.dir);
        errdefer seeds.before.deinit(gpa);

        try git.exec(io, &.{ "checkout", "-qb", "next" });
        try git.writeFile(io, "a", "two\n");
        try git.writeFile(io, "dir/c", "sea\n");
        try git.exec(io, &.{ "add", "." });
        try git.exec(io, &.{ "commit", "-qm", "second" });
        try git.exec(io, &.{ "checkout", "-q", "main" });
        seeds.pack = try git.runInput(io, &.{ "pack-objects", "--revs", "--stdout", "-q" }, "next\n^main\n");
        errdefer gpa.free(seeds.pack);
        try git.exec(io, &.{ "repack", "-adq" });
        seeds.after = try Image.read(gpa, io, git.dir);
        errdefer seeds.after.deinit(gpa);

        const dangling = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "nothing reaches this\n");
        gpa.free(dangling);
        const tree = try git.line(io, &.{ "rev-parse", "main^{tree}" });
        defer gpa.free(tree);
        gpa.free(try git.line(io, &.{ "commit-tree", tree, "-m", "nothing reaches this either" }));
        try git.writeFile(io, ".git/objects/pack/tmp_pack_stale", "x");
        seeds.pruning = try Image.read(gpa, io, git.dir);
        errdefer seeds.pruning.deinit(gpa);
        seeds.pruning_objects = try allObjects(&git, io);
        errdefer gpa.free(seeds.pruning_objects);
        // Loose copies of packed objects: the first commit's, as they were
        // before the repack. git writes none of an object a pack holds.
        for (seeds.before.files.items) |f| {
            if (!std.mem.startsWith(u8, f.path, ".git/objects/") or f.path.len != ".git/objects/".len + 41) continue;
            const path = try gpa.dupe(u8, f.path);
            errdefer gpa.free(path);
            const bytes = try gpa.dupe(u8, f.bytes);
            errdefer gpa.free(bytes);
            try seeds.pruning.files.append(gpa, .{ .path = path, .bytes = bytes, .mtime = f.mtime });
        }
        for (seeds.before.dirs.items) |d| {
            if (!std.mem.startsWith(u8, d, ".git/objects/") or d.len != ".git/objects/".len + 2) continue;
            for (seeds.pruning.dirs.items) |have| {
                if (std.mem.eql(u8, have, d)) break;
            } else {
                const dir = try gpa.dupe(u8, d);
                errdefer gpa.free(dir);
                try seeds.pruning.dirs.append(gpa, dir);
            }
        }

        const first = try git.line(io, &.{ "rev-parse", "main" });
        defer gpa.free(first);
        const second = try git.line(io, &.{ "rev-parse", "next" });
        defer gpa.free(second);
        @memcpy(&seeds.first, first);
        @memcpy(&seeds.second, second);
        return seeds;
    }

    fn deinit(seeds: *Seeds, gpa: std.mem.Allocator) void {
        seeds.before.deinit(gpa);
        seeds.after.deinit(gpa);
        seeds.pruning.deinit(gpa);
        gpa.free(seeds.pruning_objects);
        gpa.free(seeds.pack);
    }
};

/// One operation, run by `shakedown.everyCrash`.
pub const Case = struct {
    kind: Kind,
    /// What the exploration allocates from: `everyCrash`'s.
    gpa: std.mem.Allocator,
    seeds: *const Seeds,
    /// Every state the crashes left, by digest: git checks each once.
    states: std.array_hash_map.Auto([32]u8, Image) = .empty,
    /// What relic allocates in a run: a crash abandons the run's task
    /// without its defers, so the run's memory is freed with this.
    arena: std.heap.ArenaAllocator,
    h: ?*seam.Seam = null,

    fn deinit(c: *Case) void {
        for (c.states.values()) |*image| image.deinit(c.gpa);
        c.states.deinit(c.gpa);
        c.arena.deinit();
    }

    fn seed(c: *const Case) *const Image {
        return switch (c.kind) {
            .pack_receive => &c.seeds.before,
            .prune, .repack, .repack_cruft, .repack_geometric, .commit_graph, .loose_objects, .incremental_repack => &c.seeds.pruning,
            else => &c.seeds.after,
        };
    }

    pub fn setUp(c: *Case, sim: *shakedown.Sim) !void {
        const fs = sim.fs();
        const image = c.seed();
        for (image.dirs.items) |d| try fs.mkdir(d);
        for (image.files.items) |f| try fs.write(f.path, f.bytes);
        if (c.kind == .index_write) {
            try fs.write("a", "thr\n");
            try fs.write("dir/d", "dee\n");
        }
        c.h = try seam.Seam.create(c.gpa, sim.io(), .{ .trace = .off });
    }

    pub fn tearDown(c: *Case) void {
        if (c.h) |h| h.destroy();
        c.h = null;
        _ = c.arena.reset(.free_all);
    }

    /// The repository at the simulated disk's root. Its clock keeps whole
    /// seconds, which is what relic's probe would measure: the probe's
    /// own file, made and removed at every open, is not what is under test.
    fn open(c: *Case, io: Io) !repo_mod.Repository {
        var repo = try repo_mod.Repository.open(c.arena.allocator(), io, Io.Dir.cwd(), .{
            .discover = false,
            .ownership = .trust,
            .odb = .{ .probe_timestamp_resolution = false },
        });
        repo.objectDatabase().timestamp_resolution = .second;
        return repo;
    }

    pub fn run(c: *Case, base: Io) !void {
        _ = base;
        const io = c.h.?.io();
        const gpa = c.arena.allocator();
        var repo = try c.open(io);
        switch (c.kind) {
            .ref_update => try c.moveRef(io, &repo, "refs/heads/main", .{ .direct = try Oid.parse(.sha1, &c.seeds.second) }),
            .pack_receive => {
                var reader: Io.Reader = .fixed(c.seeds.pack);
                var received = try repo.objectDatabase().receivePack(io, &reader, .{});
                try c.moveRef(io, &repo, "refs/heads/next", .{ .direct = try Oid.parse(.sha1, &c.seeds.second) });
                received.deinit(io);
            },
            .index_write => {
                var locked = try repo.lockIndex(io);
                _ = try checkout.addAll(gpa, io, repo.workDirectory().?, .{ .index = &locked.index, .db = repo.objectDatabase() }, .{ .rules = try repo.worktreeRules() });
                try locked.commit(io);
                locked.deinit(io);
                // The same size in the same second: only the content
                // tells it from what the index holds.
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = "a", .data = "fou\n" });
            },
            .checkout => {
                var locked = try repo.lockIndex(io);
                const tree = try repo.commitTree(io, try Oid.parse(.sha1, &c.seeds.second));
                _ = try checkout.checkout(gpa, io, repo.workDirectory().?, .{ .index = &locked.index, .db = repo.objectDatabase(), .tree = tree }, .{
                    .durability = .durable,
                    .rules = try repo.worktreeRules(),
                });
                try locked.commit(io);
                locked.deinit(io);
                try c.moveRef(io, &repo, "HEAD", .{ .symbolic = "refs/heads/next" });
            },
            .pack_refs => try gc.packRefs(io, &repo, .{ .include = &.{"*"} }),
            .reflog_expire => try gc.expireReflogs(gpa, io, &repo, .{ .clock = .{ .now = date.timestamp(testgit.fixture_date) }, .expire = gc.expire_all }),
            .prune => _ = try prune.prune(gpa, io, &repo, .{}),
            .repack => _ = try repack.repack(gpa, io, &repo, .{ .mode = .all, .delete = true, .update_server_info = false, .pack = .{ .threads = 1 } }),
            .repack_cruft => _ = try repack.repack(gpa, io, &repo, .{ .mode = .cruft, .delete = true, .update_server_info = false, .pack = .{ .threads = 1 } }),
            .repack_geometric => _ = try repack.repack(gpa, io, &repo, .{ .geometric = 2, .delete = true, .write_midx = true, .update_server_info = false, .pack = .{ .threads = 1 } }),
            .commit_graph => _ = try maintenance.writeConfiguredCommitGraph(gpa, io, &repo, .gc),
            .loose_objects, .incremental_repack => {
                const report = try maintenance_run.run(gpa, io, &repo, .{ .clock = .{ .now = date.timestamp(testgit.fixture_date) }, .tasks = &.{if (c.kind == .loose_objects) .loose_objects else .incremental_repack}, .pack = .{ .threads = 1 } });
                for (std.enums.values(maintenance_run.Task)) |task| switch (report.outcomes.get(task)) {
                    .failed => |err| return err,
                    else => {},
                };
            },
        }
        repo.deinit(io);
    }

    fn moveRef(c: *Case, io: Io, repo: *repo_mod.Repository, name: []const u8, new: refs.Ref) !void {
        _ = c;
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.change(name, new, .any, .{ .no_deref = true });
        try tx.prepare(io);
        try tx.commit(io, .{ .who = who, .message = "crash" });
    }

    /// What a person does after a crash before git runs again: removes the
    /// locks the crashed run held.
    pub fn recover(c: *Case, io: Io) !void {
        _ = c;
        try removeLocks(io, Io.Dir.cwd());
    }

    pub fn check(c: *Case, io: Io) !void {
        // A state is its files, their bytes and their times: one seen
        // before is checked already.
        var image = try Image.read(c.gpa, io, Io.Dir.cwd());
        const slot = try c.states.getOrPut(c.gpa, image.digest());
        if (slot.found_existing) return image.deinit(c.gpa);
        slot.value_ptr.* = image;
        try c.honest(io);
    }

    /// relic reads the state whole, and its status calls no changed file
    /// clean.
    fn honest(c: *Case, base: Io) !void {
        defer _ = c.arena.reset(.free_all);
        // airlock's calls reach the recovered disk through a seam of its own.
        const h = try seam.Seam.create(c.gpa, base, .{ .trace = .off });
        defer h.destroy();
        const io = h.io();
        const gpa = c.arena.allocator();
        var repo = try c.open(io);
        defer repo.deinit(io);
        var index = try repo.openIndex(io);
        defer index.deinit();
        const wt = repo.workDirectory().?;
        var status = try checkout.status(gpa, io, wt, .{ .index = &index, .db = repo.objectDatabase() }, .{
            .rules = try repo.worktreeRules(),
            .head_tree = try repo.headTree(io),
        });
        defer status.deinit();
        for (index.entries.items) |entry| {
            const bytes = wt.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            if (hash.Hasher.object(.sha1, "blob", bytes).eql(entry.oid)) continue;
            const reported = status.find(entry.path) orelse return c.lied(entry.path);
            if (reported.unstaged == .unmodified) return c.lied(entry.path);
        }
    }

    fn lied(c: *Case, path: []const u8) error{RacilyClean} {
        std.debug.print("crash {t}: status calls {s} clean, its content changed\n", .{ c.kind, path });
        return error.RacilyClean;
    }

    /// Every state through git: `git fsck --full`, and each ref the run
    /// changes at its old value or its new one.
    fn checkStates(c: *Case, gpa: std.mem.Allocator, io: Io, format: testgit.RefFormat) !void {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        for (c.states.values(), 0..) |*image, i| {
            try clear(io, git.dir);
            try image.write(io, git.dir);
            checkState(c, io, &git) catch |err| {
                std.debug.print("crash {t} ({t} refs), state {d} of {d}:\n", .{ c.kind, format, i + 1, c.states.count() });
                for (image.files.items) |f| std.debug.print("  {s} ({d} bytes)\n", .{ f.path, f.bytes.len });
                return err;
            };
        }
    }

    fn checkState(c: *Case, io: Io, git: *testgit.Repo) !void {
        var fsck = try git.capture(io, &.{ "fsck", "--full", "--no-progress", "--no-dangling" });
        defer fsck.deinit(git.gpa);
        if (fsck.code != 0) {
            std.debug.print("git fsck ({d}):\n{s}{s}\n", .{ fsck.code, fsck.stdout, fsck.stderr });
            return error.FsckFailed;
        }
        // No commit lost: both are where they were, or where the run put them.
        const first: []const u8 = &c.seeds.first;
        const second: []const u8 = &c.seeds.second;
        switch (c.kind) {
            .pack_receive => {
                try expectRef(io, git, "refs/heads/main", &.{first});
                try expectRef(io, git, "refs/heads/next", &.{ "", second });
            },
            .ref_update => {
                try expectRef(io, git, "refs/heads/main", &.{ first, second });
                try expectRef(io, git, "refs/heads/next", &.{second});
            },
            // Packing moves no ref, and expiring and pruning move none:
            // each is where it was at every crash.
            .pack_refs, .reflog_expire, .prune, .commit_graph => {
                try expectRef(io, git, "refs/heads/main", &.{first});
                try expectRef(io, git, "refs/heads/next", &.{second});
            },
            // A repack moves no ref and loses no object: the unreachable
            // ones stay loose, or go into the cruft pack before the loose
            // copies go.
            .repack, .repack_cruft, .repack_geometric, .loose_objects, .incremental_repack => {
                try expectRef(io, git, "refs/heads/main", &.{first});
                try expectRef(io, git, "refs/heads/next", &.{second});
                const held = try allObjects(git, io);
                defer git.gpa.free(held);
                if (!std.mem.eql(u8, held, c.seeds.pruning_objects)) {
                    std.debug.print("objects before:\n{s}after:\n{s}", .{ c.seeds.pruning_objects, held });
                    return error.ObjectLost;
                }
            },
            .index_write, .checkout => {
                try expectRef(io, git, "refs/heads/main", &.{first});
                try expectRef(io, git, "refs/heads/next", &.{second});
                const head = try git.line(io, &.{ "symbolic-ref", "HEAD" });
                defer git.gpa.free(head);
                const heads: []const []const u8 = if (c.kind == .checkout) &.{ "refs/heads/main", "refs/heads/next" } else &.{"refs/heads/main"};
                try expectOneOf(head, heads);
                // The index reads whole.
                git.gpa.free(try git.run(io, &.{ "ls-files", "-s" }));
            },
        }
    }
};

/// Every object `git` holds, one name a line, sorted.
fn allObjects(git: *testgit.Repo, io: Io) ![]u8 {
    return git.run(io, &.{ "cat-file", "--batch-all-objects", "--batch-check=%(objectname)" });
}

fn expectRef(io: Io, git: *testgit.Repo, name: []const u8, allowed: []const []const u8) !void {
    var got = try git.capture(io, &.{ "rev-parse", "-q", "--verify", name });
    defer got.deinit(git.gpa);
    const value = std.mem.trimEnd(u8, got.stdout, "\n");
    expectOneOf(value, allowed) catch |err| {
        std.debug.print("{s} is '{s}'\n", .{ name, value });
        return err;
    };
}

fn expectOneOf(value: []const u8, allowed: []const []const u8) !void {
    for (allowed) |a| if (std.mem.eql(u8, value, a)) return;
    return error.UnexpectedValue;
}

/// Remove every `*.lock` file under `dir`.
fn removeLocks(io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| switch (entry.kind) {
        .directory => {
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try removeLocks(io, sub);
        },
        else => if (std.mem.endsWith(u8, entry.name, ".lock")) try dir.deleteFile(io, entry.name),
    };
}

/// Empty `dir`.
fn clear(io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| try dir.deleteTree(io, entry.name);
}

fn everyCrash(kind: Kind, format: testgit.RefFormat) !void {
    // Every crash point is a simulation, and every state it can leave is
    // another, each allocating: tens of thousands of runs. They allocate
    // from an allocator that checks for leaks as `testing.allocator` does
    // but records no stack trace per allocation (on macOS a DWARF unwind,
    // which was most of a run's time) and does not scan freed memory for
    // late writes (the simulated disk frees every state it leaves behind,
    // and the scan was half of what was left).
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0, .check_write_after_free = false });
    defer if (safe.deinit() != 0) std.debug.panic("the crash exploration leaked", .{});
    const gpa = safe.allocator();
    const io = testing.io;
    var seeds = try Seeds.make(gpa, io, format);
    defer seeds.deinit(gpa);
    var case: Case = .{ .kind = kind, .gpa = gpa, .seeds = &seeds, .arena = .init(gpa) };
    defer case.deinit();
    const started = Io.Clock.awake.now(io);
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyCrash(gpa, &case, .{
        .sim = .{
            .fs = .{ .names = names, .timestamp_granularity = granularity },
            .stack_size = .fromRaw(512 << 10),
            .watchdog = null,
        },
        .max_states = 256,
        .max_steps = 1_000_000,
        .diagnostics = &report,
    });
    const done = result catch |err| {
        if (report.failure) |f| std.debug.print("every crash {t} ({t} refs): {t} at {any}\n{s}\n", .{ kind, format, f.err, f.injected, f.trace });
        return err;
    };
    std.debug.print("crash {t} ({t} refs): {d} points, {d} recoveries, {d} distinct states, {d} bounded\n", .{ kind, format, done.steps + 1, done.runs, case.states.count(), done.bounded });
    try case.checkStates(gpa, io, format);
    std.debug.print("  {d} ms\n", .{@divTrunc(started.durationTo(Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms)});
}

fn inFormat(kind: Kind, format: testgit.RefFormat) !void {
    if (os == .windows) return error.SkipZigTest;
    for (try testgit.refFormats(testing.allocator, testing.io)) |found| {
        if (found == format) return everyCrash(kind, format);
    }
    return error.SkipZigTest;
}

test "every crash: a ref update, files" {
    try inFormat(.ref_update, .files);
}

test "every crash: a ref update, reftable" {
    try inFormat(.ref_update, .reftable);
}

test "every crash: a received pack and the ref that publishes it, files" {
    try inFormat(.pack_receive, .files);
}

test "every crash: a received pack and the ref that publishes it, reftable" {
    try inFormat(.pack_receive, .reftable);
}

test "every crash: an index write, racily clean files included" {
    // The index is the same file whatever the refs are kept in.
    try inFormat(.index_write, .files);
}

test "every crash: a checkout of another branch, files" {
    try inFormat(.checkout, .files);
}

test "every crash: a checkout of another branch, reftable" {
    try inFormat(.checkout, .reftable);
}

test "every crash: pack-refs, files" {
    try inFormat(.pack_refs, .files);
}

test "every crash: pack-refs, reftable" {
    try inFormat(.pack_refs, .reftable);
}

test "every crash: reflog expire, files" {
    try inFormat(.reflog_expire, .files);
}

test "every crash: reflog expire, reftable" {
    try inFormat(.reflog_expire, .reftable);
}

test "every crash: prune, files" {
    try inFormat(.prune, .files);
}

test "every crash: prune, reftable" {
    try inFormat(.prune, .reftable);
}

test "every crash: repack -a -d, files" {
    try inFormat(.repack, .files);
}

test "every crash: repack -a -d, reftable" {
    try inFormat(.repack, .reftable);
}

test "every crash: repack --cruft -d, files" {
    try inFormat(.repack_cruft, .files);
}

test "every crash: repack --cruft -d, reftable" {
    try inFormat(.repack_cruft, .reftable);
}

test "every crash: repack --geometric=2 -d --write-midx, files" {
    try inFormat(.repack_geometric, .files);
}

test "every crash: repack --geometric=2 -d --write-midx, reftable" {
    try inFormat(.repack_geometric, .reftable);
}

test "every crash: the commit graph gc writes, files" {
    try inFormat(.commit_graph, .files);
}

test "every crash: the commit graph gc writes, reftable" {
    try inFormat(.commit_graph, .reftable);
}

test "every crash: maintenance's loose-objects task, files" {
    try inFormat(.loose_objects, .files);
}

test "every crash: maintenance's loose-objects task, reftable" {
    try inFormat(.loose_objects, .reftable);
}

test "every crash: maintenance's incremental-repack task, files" {
    try inFormat(.incremental_repack, .files);
}

test "every crash: maintenance's incremental-repack task, reftable" {
    try inFormat(.incremental_repack, .reftable);
}
