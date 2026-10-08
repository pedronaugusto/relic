//! Pack writing on the caller's executor: every worker count and every kind
//! of `std.Io` writes the bytes the serial writer writes.

const std = @import("std");
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const pack_mod = @import("../odb/pack.zig");
const testgit = @import("git.zig");
const Tasks = @import("io.zig");

const Oid = hash.Oid;

/// A scratch object directory holding versions of a few files, which delta
/// against each other, and some unrelated blobs, which do not.
const Corpus = struct {
    tmp: std.testing.TmpDir,
    objects: Io.Dir,
    entries: std.ArrayList(odb_mod.PackEntry) = .empty,
    hints: std.ArrayList([]u8) = .empty,

    fn init(gpa: std.mem.Allocator, io: Io, files: usize, versions: usize, unrelated: usize) !Corpus {
        var c: Corpus = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }), .objects = undefined };
        errdefer c.tmp.cleanup();
        try c.tmp.dir.createDirPath(io, "objects/pack");
        c.objects = try c.tmp.dir.openDir(io, "objects", .{ .iterate = true });
        errdefer c.deinit(gpa, io);

        var db = try odb_mod.Odb.openAt(gpa, io, c.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var prng: std.Random.DefaultPrng = .init(0x9ac4);
        const random = prng.random();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        for (0..files) |f| {
            body.clearRetainingCapacity();
            const hint = try gpa.print("src/file{d}.txt", .{f});
            try c.hints.append(gpa, hint);
            for (0..versions) |v| {
                for (0..20 + random.uintLessThan(usize, 40)) |line| {
                    try body.print(gpa, "file {d} version {d} line {d}: {d}\n", .{ f, v, line, random.int(u32) });
                }
                const oid = try db.write(io, .blob, body.items);
                try c.entries.append(gpa, .{ .oid = oid, .hint = hint });
            }
        }
        for (0..unrelated) |_| {
            body.clearRetainingCapacity();
            for (0..random.intRangeAtMost(usize, 1, 6000)) |_| try body.append(gpa, random.int(u8));
            const oid = try db.write(io, .blob, body.items);
            try c.entries.append(gpa, .{ .oid = oid });
        }
        return c;
    }

    fn deinit(c: *Corpus, gpa: std.mem.Allocator, io: Io) void {
        for (c.hints.items) |hint| gpa.free(hint);
        c.hints.deinit(gpa);
        c.entries.deinit(gpa);
        c.objects.close(io);
        c.tmp.cleanup();
        c.* = undefined;
    }

    /// Write the corpus as one pack through `io` and say what was written.
    fn write(c: *Corpus, gpa: std.mem.Allocator, io: Io, options: odb_mod.PackOptions) !pack_mod.WriteReport {
        var db = try odb_mod.Odb.openAt(gpa, io, c.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var pack_dir = try c.objects.openDir(io, "pack", .{ .iterate = true });
        defer pack_dir.close(io);
        return db.writePack(io, pack_dir, c.entries.items, options);
    }
};

test "a pack submits several tasks to the caller's Io by default, none when asked for one, and is the same pack" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, io, 8, 6, 8);
    defer corpus.deinit(gpa, io);
    var single: Io.Threaded = .init_single_threaded;

    const serial = try corpus.write(gpa, Tasks.wrap(io), .{ .threads = 1 });
    try Tasks.expect(0, 0);
    try std.testing.expect(serial.deltas > 0);
    const workers = @min(std.Thread.getCpuCount() catch 1, corpus.entries.items.len);
    // One batch: headers and bodies on at most six tasks, one search group
    // on the caller, then deflation on all tasks. The caller is a worker.
    const readers: usize = @min(workers, 6);
    const spawned = if (workers == 1) 0 else 2 * (readers - 1) + workers - 1;
    for ([_]Io{ io, single.io() }) |each_io| {
        const parallel = try corpus.write(gpa, Tasks.wrap(each_io), .{});
        try Tasks.expect(spawned, 0);
        try std.testing.expect(parallel.name.eql(serial.name));
        try std.testing.expectEqual(serial.deltas, parallel.deltas);
    }
}

test "every worker count, Io and delta encoding writes the serial writer's bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, io, 8, 8, 16);
    defer corpus.deinit(gpa, io);
    var single: Io.Threaded = .init_single_threaded;

    for ([_]odb_mod.DeltaEncoding{ .offset, .reference, .none }) |encoding| {
        const serial = try corpus.write(gpa, io, .{ .threads = 1, .delta = encoding });
        if (encoding != .none) try std.testing.expect(serial.deltas > 0);
        for ([_]Io{ io, single.io() }) |each_io| {
            for ([_]u16{ 0, 2, 3, 8 }) |threads| {
                const report = try corpus.write(gpa, each_io, .{ .threads = threads, .delta = encoding });
                try std.testing.expect(report.name.eql(serial.name));
                try std.testing.expectEqual(serial.pack_bytes, report.pack_bytes);
                try std.testing.expectEqual(serial.deltas, report.deltas);
            }
        }
    }
}

/// An allocator that serves one thread only, and counts the most bytes it
/// had out at once: a task allocating from it fails the test.
const OneThread = struct {
    child: std.mem.Allocator,
    owner: std.Thread.Id,
    live: usize = 0,
    peak: usize = 0,
    foreign: bool = false,

    fn allocator(o: *OneThread) std.mem.Allocator {
        return .{ .ptr = o, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn mine(o: *OneThread) bool {
        if (std.Thread.getCurrentId() == o.owner) return true;
        o.foreign = true;
        return false;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const o: *OneThread = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        if (!o.mine()) return null;
        const p = o.child.rawAlloc(len, alignment, ret) orelse return null;
        o.live += len;
        o.peak = @max(o.peak, o.live);
        return p;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const o: *OneThread = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        if (!o.mine()) return false;
        if (!o.child.rawResize(memory, alignment, new_len, ret)) return false;
        o.live = o.live - memory.len + new_len;
        o.peak = @max(o.peak, o.live);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const o: *OneThread = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        if (!o.mine()) return null;
        const p = o.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        o.live = o.live - memory.len + new_len;
        o.peak = @max(o.peak, o.live);
        return p;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const o: *OneThread = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        _ = o.mine();
        o.child.rawFree(memory, alignment, ret);
        o.live -= memory.len;
    }
};

test "the tasks allocate nothing, and a batch holds no more than its budget" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);

    // Forty-eight objects of 64 KiB that do not compress, and some small
    // ones, all loose.
    var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
    defer entries.deinit(gpa);
    {
        var db = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var prng: std.Random.DefaultPrng = .init(0xb0d9);
        const noise = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(noise);
        for (0..48) |_| {
            prng.random().bytes(noise);
            try entries.append(gpa, .{ .oid = try db.write(io, .blob, noise) });
        }
        for (0..32) |i| {
            var text: [32]u8 = undefined;
            try entries.append(gpa, .{ .oid = try db.write(io, .blob, try std.mem.print(&text, "small {d}\n", .{i})) });
        }
    }

    const workers = 4;
    const Run = struct { name: hash.Oid, peak: usize };
    var runs: [2]Run = undefined;
    for ([_]usize{ 256 * 1024, 64 << 20 }, &runs) |budget, *run| {
        var counting: OneThread = .{ .child = gpa, .owner = std.Thread.getCurrentId() };
        const counted = counting.allocator();
        var db = try odb_mod.Odb.openAt(counted, io, objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var pack_dir = try objects.openDir(io, "pack", .{ .iterate = true });
        defer pack_dir.close(io);
        const before = counting.live;
        counting.peak = before;
        const report = try db.writePack(io, pack_dir, entries.items, .{ .threads = workers, .delta = .none, .batch_bytes = budget });
        try std.testing.expect(!counting.foreign);
        run.* = .{ .name = report.name, .peak = counting.peak - before };
    }
    try std.testing.expect(runs[0].name.eql(runs[1].name));

    // What a write holds besides its batches: a deflate state for each task
    // and for the writer, the writer's file buffer, and a few words per
    // object. The small budget fits one 64 KiB object at a time, so its
    // batches hold at most twice that; the large one takes everything at
    // once.
    const deflater = @sizeOf(std.compress.flate.Compress) + std.compress.flate.max_window_len;
    const fixed = (workers + 1) * deflater + 64 * 1024 + 64 * 1024;
    const one_object = 64 * 1024 + pack_mod.Deflater.room(64 * 1024);
    if (runs[0].peak > fixed + 2 * one_object) {
        std.debug.print("small budget: peak {d} bytes, bound {d}\n", .{ runs[0].peak, fixed + 2 * one_object });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(runs[1].peak > fixed + 48 * 64 * 1024);
}

/// A loose-object open that, once armed, parks on its `at`-th call until
/// the task it runs on is canceled, or fails with `failure`.
const Interrupt = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var opens: usize = 0;
    var at: usize = std.math.maxInt(usize);
    var failure: ?Io.File.OpenError = null;
    var parked: std.atomic.Value(bool) = .init(false);
    var base: Io = undefined;

    fn arm(n: usize, err: ?Io.File.OpenError) void {
        opens = 0;
        at = n;
        failure = err;
        parked.store(false, .release);
    }

    fn open(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
        const n = blk: {
            while (!mutex.tryLock()) {}
            defer mutex.unlock();
            opens += 1;
            break :blk opens;
        };
        if (n == at) {
            if (failure) |err| return err;
            parked.store(true, .release);
            // Until canceled, a short sleep at a time, since a sleep may
            // also end early; a minute is a hang, not a pass.
            for (0..6000) |_| try base.sleep(.fromMilliseconds(10), .awake);
            return error.Unexpected;
        }
        return base.vtable.dirOpenFile(userdata, dir, sub_path, options);
    }
};

fn writeWith(corpus: *Corpus, gpa: std.mem.Allocator, io: Io, options: odb_mod.PackOptions) anyerror!pack_mod.WriteReport {
    return corpus.write(gpa, io, options);
}

fn leftovers(corpus: *Corpus, io: Io) !usize {
    var pack_dir = try corpus.objects.openDir(io, "pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var n: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "tmp_")) n += 1;
    }
    return n;
}

test "a pack write canceled or failed part way leaves nothing behind" {
    const gpa = std.testing.allocator;
    // Two tasks besides the calling one, whatever the machine: the rest of
    // the write's tasks run inline, on the task that is canceled.
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    Interrupt.base = io;
    var corpus = try Corpus.init(gpa, io, 6, 6, 40);
    defer corpus.deinit(gpa, io);

    var vtable = io.vtable.*;
    vtable.dirOpenFile = Interrupt.open;
    const interrupted: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    for ([_]u16{ 4, 3, 1 }) |threads| {
        // Canceled while a read waits: the write returns `Canceled`.
        Interrupt.arm(30, null);
        var future = try io.concurrent(writeWith, .{ &corpus, gpa, interrupted, .{ .threads = threads } });
        while (!Interrupt.parked.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
        try std.testing.expectError(error.Canceled, future.cancel(io));
        try std.testing.expectEqual(@as(usize, 0), try leftovers(&corpus, io));

        // A read that fails: the write returns why.
        Interrupt.arm(30, error.AccessDenied);
        try std.testing.expectError(error.AccessDenied, corpus.write(gpa, interrupted, .{ .threads = threads }));
        try std.testing.expectEqual(@as(usize, 0), try leftovers(&corpus, io));
    }
    Interrupt.arm(std.math.maxInt(usize), null);
    _ = try corpus.write(gpa, interrupted, .{});
}

test "a pack of fewer objects than tasks asks for no more tasks than it has objects" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    for ([_]usize{ 1, 2, 3 }) |objects| {
        var corpus = try Corpus.init(gpa, io, 1, objects, 0);
        defer corpus.deinit(gpa, io);
        const serial = try corpus.write(gpa, io, .{ .threads = 1 });
        const report = try corpus.write(gpa, Tasks.wrap(io), .{ .threads = 8 });
        try std.testing.expect(report.name.eql(serial.name));
        // Each of the write's stages — headers, bodies, deflating — shares
        // its objects among the calling task and at most one task for each
        // other object.
        const spawned = Tasks.group_async.load(.monotonic);
        if (spawned > 3 * (objects - 1)) {
            std.debug.print("{d} objects: {d} tasks\n", .{ objects, spawned });
            return error.TestUnexpectedResult;
        }
    }
}

test "objects repacked from packs are read by several tasks, and the pack is the serial writer's" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, io, 8, 6, 24);
    defer corpus.deinit(gpa, io);
    {
        // Everything into one pack, and nothing left loose.
        var db = try odb_mod.Odb.openAt(gpa, io, corpus.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        _ = try db.packLoose(io, .{});
    }

    var single: Io.Threaded = .init_single_threaded;
    const Repack = struct {
        fn write(c: *Corpus, a: std.mem.Allocator, opened: Io, read: Io, threads: u16) !pack_mod.WriteReport {
            // One block cached, so that reading is reading the file.
            var db = try odb_mod.Odb.openAt(a, opened, c.objects, .sha1, .{ .probe_timestamp_resolution = false, .pack_read_cache_bytes = 0 });
            defer db.deinit(opened);
            var collected = try db.collectAll(opened, .{});
            defer collected.deinit();
            for (collected.entries) |entry| try std.testing.expect(entry.in_pack);
            try c.tmp.dir.createDirPath(opened, "out");
            var out = try c.tmp.dir.openDir(opened, "out", .{ .iterate = true });
            defer out.close(opened);
            return db.writePack(read, out, collected.entries, .{ .threads = threads });
        }
    };
    const serial = try Repack.write(&corpus, gpa, io, Tasks.wrap(io), 1);
    try Tasks.expect(0, 0);
    try std.testing.expect(serial.deltas > 0);
    for ([_]Io{ io, single.io() }) |each_io| {
        const parallel = try Repack.write(&corpus, gpa, io, Tasks.wrap(each_io), 4);
        // Headers, packed bodies and deflation, three submissions each,
        // plus one submission for the second search group.
        try Tasks.expect(10, 0);
        try std.testing.expect(parallel.name.eql(serial.name));
        try std.testing.expectEqual(serial.deltas, parallel.deltas);
    }
}

/// The order of three kinds of event in a pack write: a loose object
/// opened, an allocation as large as a delta encoder's index, which only
/// the delta search makes once the bodies are being read, and pack bytes
/// handed to the output.
const Phases = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    /// 0 before the first body is opened, 1 once one is, 2 once the
    /// search has begun, 3 once an entry is written after that.
    var phase: u8 = 0;
    /// Whether an object was opened in phase 2: while a batch was being
    /// searched or before the batch before it was written.
    var opened_while_searching: bool = false;

    fn reset() void {
        phase = 0;
        opened_while_searching = false;
    }

    fn event(kind: enum { open, search_alloc, write }) void {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        switch (kind) {
            .open => switch (phase) {
                0 => phase = 1,
                2 => opened_while_searching = true,
                else => {},
            },
            .search_alloc => if (phase == 1) {
                phase = 2;
            },
            .write => if (phase == 2) {
                phase = 3;
            },
        }
    }

    fn open(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
        if (sub_path.len == 41 and sub_path[2] == '/') event(.open);
        return std.testing.io.vtable.dirOpenFile(userdata, dir, sub_path, options);
    }

    const Spy = struct {
        child: std.mem.Allocator,
        fn allocator(s: *Spy) std.mem.Allocator {
            return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const s: *Spy = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
            if (len >= 16 * 1024) event(.search_alloc);
            return s.child.rawAlloc(len, alignment, ret);
        }
        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
            const s: *Spy = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
            return s.child.rawResize(memory, alignment, new_len, ret);
        }
        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
            const s: *Spy = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
            return s.child.rawRemap(memory, alignment, new_len, ret);
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const s: *Spy = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
            s.child.rawFree(memory, alignment, ret);
        }
    };

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        _ = w;
        event(.write);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |slice| n += slice.len;
        return n + data[data.len - 1].len * splat;
    }
};

test "the tasks read the next batch while one is searched, and the pack is the serial writer's" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, io, 8, 6, 24);
    defer corpus.deinit(gpa, io);
    // Headers given, as `collectLoose` gives them, so that the only loose
    // opens are the bodies'.
    {
        var db = try odb_mod.Odb.openAt(gpa, io, corpus.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        for (corpus.entries.items) |*entry| entry.header = try db.readHeader(io, entry.oid);
    }
    const options: odb_mod.PackOptions = .{ .threads = 4, .batch_bytes = 96 * 1024 };
    const serial = try corpus.write(gpa, io, .{ .threads = 1 });

    var vtable = io.vtable.*;
    vtable.dirOpenFile = Phases.open;
    const watched: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var single: Io.Threaded = .init_single_threaded;
    var single_vtable = single.io().vtable.*;
    single_vtable.dirOpenFile = Phases.open;
    const single_watched: Io = .{ .userdata = single.io().userdata, .vtable = &single_vtable };
    for ([_]Io{ watched, single_watched }) |each_io| {
        var spy: Phases.Spy = .{ .child = gpa };
        var db = try odb_mod.Odb.openAt(spy.allocator(), io, corpus.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var out: Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = Phases.drain } };
        Phases.reset();
        const report = try db.writePackTo(each_io, &out, corpus.entries.items, options);
        try std.testing.expect(report.name.eql(serial.name));
        if (!Phases.opened_while_searching) {
            std.debug.print("no object was read between the start of the delta search and the first entry written\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

test "collecting loose objects reads their trees on several tasks and hints as one task does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, io, 8, 6, 0);
    defer corpus.deinit(gpa, io);
    {
        // Trees naming the blobs, each version of each file in one of them.
        var db = try odb_mod.Odb.openAt(gpa, io, corpus.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        for (0..6) |v| {
            body.clearRetainingCapacity();
            for (0..8) |f| {
                const blob = corpus.entries.items[f * 6 + v].oid;
                try body.print(gpa, "100644 file{d}.txt\x00", .{f});
                try body.appendSlice(gpa, blob.raw());
            }
            _ = try db.write(io, .tree, body.items);
        }
    }

    var single: Io.Threaded = .init_single_threaded;
    var db = try odb_mod.Odb.openAt(gpa, io, corpus.objects, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    var serial = try db.collectLoose(Tasks.wrap(io), .{ .threads = 1 });
    defer serial.deinit();
    try Tasks.expect(0, 0);
    for ([_]Io{ io, single.io() }) |each_io| {
        var parallel = try db.collectLoose(Tasks.wrap(each_io), .{ .threads = 4 });
        defer parallel.deinit();
        // Headers and the six tree bodies, each on four tasks including
        // the caller, even when the executor runs every submission inline.
        try Tasks.expect(6, 0);
        try std.testing.expectEqual(serial.entries.len, parallel.entries.len);
        var hinted: usize = 0;
        for (serial.entries, parallel.entries) |a, b| {
            try std.testing.expect(a.oid.eql(b.oid));
            try std.testing.expectEqualStrings(a.hint, b.hint);
            if (a.hint.len != 0) hinted += 1;
        }
        try std.testing.expectEqual(@as(usize, 48), hinted);
    }
}

/// Versions of enough files for several search groups.
fn groupedCorpus(gpa: std.mem.Allocator, io: Io) !Corpus {
    const versions = 8;
    const files = 3 * odb_mod.search_group_objects / versions + 4;
    return Corpus.init(gpa, io, files, versions, 0);
}

test "the delta search runs on several tasks, a group on each, and the pack is the serial writer's" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try groupedCorpus(gpa, io);
    defer corpus.deinit(gpa, io);
    const serial = try corpus.write(gpa, Tasks.wrap(io), .{ .threads = 1 });
    try Tasks.expect(0, 0);
    try std.testing.expect(serial.deltas > 0);

    var single: Io.Threaded = .init_single_threaded;
    for ([_]Io{ io, single.io() }) |each_io| {
        const parallel = try corpus.write(gpa, Tasks.wrap(each_io), .{ .threads = 4 });
        // Headers, bodies, four search groups and deflation: four stages
        // with three submissions each, in addition to the calling task.
        try Tasks.expect(12, 0);
        try std.testing.expect(parallel.name.eql(serial.name));
        try std.testing.expectEqual(serial.deltas, parallel.deltas);
    }
}

test "a pack with several search groups is the same on 1, 2, 7 and 16 tasks, any Io, and any batch budget" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try groupedCorpus(gpa, io);
    defer corpus.deinit(gpa, io);
    var single: Io.Threaded = .init_single_threaded;

    const Case = struct { encoding: odb_mod.DeltaEncoding, io: Io, threads: u16, budget: usize };
    // A budget of a few dozen objects a batch cuts groups across batches,
    // which carry the window of the group they end inside.
    const small = 128 * 1024;
    const cases = [_]Case{
        .{ .encoding = .offset, .io = io, .threads = 2, .budget = 64 << 20 },
        .{ .encoding = .offset, .io = io, .threads = 7, .budget = 64 << 20 },
        .{ .encoding = .offset, .io = io, .threads = 16, .budget = 64 << 20 },
        .{ .encoding = .offset, .io = io, .threads = 2, .budget = small },
        .{ .encoding = .offset, .io = io, .threads = 7, .budget = small },
        .{ .encoding = .offset, .io = io, .threads = 16, .budget = small },
        .{ .encoding = .offset, .io = single.io(), .threads = 7, .budget = small },
        .{ .encoding = .reference, .io = io, .threads = 7, .budget = small },
    };
    var serial: [2]pack_mod.WriteReport = undefined;
    for ([_]odb_mod.DeltaEncoding{ .offset, .reference }, &serial) |encoding, *report| {
        report.* = try corpus.write(gpa, io, .{ .threads = 1, .delta = encoding });
        try std.testing.expect(report.deltas > 0);
    }
    for (cases) |c| {
        const want = serial[@backingInt(c.encoding)];
        const report = try corpus.write(gpa, c.io, .{ .threads = c.threads, .delta = c.encoding, .batch_bytes = c.budget });
        if (!report.name.eql(want.name)) {
            std.debug.print("{t}, {d} tasks, batch {d}: {d} deltas, {d} bytes; serial {d}, {d}\n", .{ c.encoding, c.threads, c.budget, report.deltas, report.pack_bytes, want.deltas, want.pack_bytes });
            return error.TestUnexpectedResult;
        }
    }
}

/// An allocator that notes whether two threads were ever inside it at once.
const OneAtATime = struct {
    child: std.mem.Allocator,
    inside: std.atomic.Value(u32) = .init(0),
    overlapped: std.atomic.Value(bool) = .init(false),

    fn allocator(o: *OneAtATime) std.mem.Allocator {
        return .{ .ptr = o, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn enter(o: *OneAtATime) void {
        if (o.inside.fetchAdd(1, .acquire) != 0) o.overlapped.store(true, .monotonic);
        // Long enough inside for another thread to arrive, were it let in.
        for (0..200) |_| std.atomic.spinLoopHint();
    }
    fn leave(o: *OneAtATime) void {
        _ = o.inside.fetchSub(1, .release);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const o: *OneAtATime = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        o.enter();
        defer o.leave();
        return o.child.rawAlloc(len, alignment, ret);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const o: *OneAtATime = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        o.enter();
        defer o.leave();
        return o.child.rawResize(memory, alignment, new_len, ret);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const o: *OneAtATime = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        o.enter();
        defer o.leave();
        return o.child.rawRemap(memory, alignment, new_len, ret);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const o: *OneAtATime = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned owner pointer as its callback context.
        o.enter();
        defer o.leave();
        o.child.rawFree(memory, alignment, ret);
    }
};

test "the searching tasks enter the database's allocator one at a time" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try groupedCorpus(gpa, io);
    defer corpus.deinit(gpa, io);
    var one: OneAtATime = .{ .child = gpa };
    var db = try odb_mod.Odb.openAt(one.allocator(), io, corpus.objects, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    var pack_dir = try corpus.objects.openDir(io, "pack", .{ .iterate = true });
    defer pack_dir.close(io);
    const report = try db.writePack(io, pack_dir, corpus.entries.items, .{ .threads = 16 });
    try std.testing.expect(report.deltas > 0);
    try std.testing.expect(!one.overlapped.load(.monotonic));
}

/// A repository git packed: versions of a few files over forty commits,
/// in one pack with git's deltas, chains of up to `depth`.
fn gitPacked(gpa: std.mem.Allocator, io: Io, depth: []const u8) !testgit.Repo {
    var repo = try testgit.Repo.init(gpa, io, &.{});
    errdefer repo.deinit();
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x9e05e);
    const random = prng.random();
    var lines: [6][60]u32 = undefined;
    for (&lines) |*file| for (file) |*line| {
        line.* = random.int(u32);
    };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..40) |c| {
        try script.print(gpa, "commit refs/heads/main\ncommitter F <f@example.com> {d} +0000\ndata 2\nc\n", .{1700000000 + c});
        for (&lines, 0..) |*file, f| {
            file[random.uintLessThan(usize, file.len)] = random.int(u32);
            body.clearRetainingCapacity();
            for (file, 0..) |line, l| try body.print(gpa, "file {d} line {d}: {d}\n", .{ f, l, line });
            try script.print(gpa, "M 100644 inline src/file{d}.txt\ndata {d}\n", .{ f, body.items.len });
            try script.appendSlice(gpa, body.items);
            try script.append(gpa, '\n');
        }
    }
    gpa.free(try repo.runInput(io, &.{ "fast-import", "--quiet" }, script.items));
    var depth_arg: [32]u8 = undefined;
    gpa.free(try repo.run(io, &.{ "repack", "-a", "-d", "-q", "-f", "--window=10", try std.mem.print(&depth_arg, "--depth={s}", .{depth}) }));
    return repo;
}

/// Each entry of a pack file: whether it is a delta, its zlib stream, and,
/// for an offset delta, how deep its chain is.
const Entries = struct {
    const Entry = struct { delta: bool, stream: []const u8, depth: u32 };
    bytes: []u8,
    map: hash.Oid.Map(Entry) = .empty,

    fn read(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, base: []const u8) !Entries {
        var p = try pack_mod.Pack.open(gpa, io, dir, base, .sha1, .{});
        defer p.deinit(io);
        var name: [128]u8 = undefined;
        var e: Entries = .{ .bytes = try dir.readFileAlloc(io, try std.mem.print(&name, "{s}.pack", .{base}), gpa, .unlimited) };
        errdefer e.deinit(gpa);
        const At = struct { offset: u64, oid: Oid };
        var all: std.ArrayList(At) = .empty;
        defer all.deinit(gpa);
        var it = p.index.iterate();
        while (try it.next()) |found| try all.append(gpa, .{ .offset = found.located.offset, .oid = found.oid });
        std.mem.sort(At, all.items, {}, struct {
            fn less(_: void, a: At, b: At) bool {
                return a.offset < b.offset;
            }
        }.less);
        var depths: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer depths.deinit(gpa);
        for (all.items, 0..) |at, i| {
            const header = try p.entryHeaderAt(io, at.offset);
            const end = if (i + 1 < all.items.len) all.items[i + 1].offset else e.bytes.len - 20;
            const depth: u32 = switch (header.kind) {
                .object => 0,
                .ofs_delta => |back| (depths.get(at.offset - back) orelse return error.TestUnexpectedResult) + 1,
                .ref_delta => return error.TestUnexpectedResult,
            };
            try depths.put(gpa, at.offset, depth);
            try e.map.put(gpa, at.oid, .{ .delta = header.kind != .object, .stream = e.bytes[@intCast(header.data_at)..@intCast(end)], .depth = depth });
        }
        return e;
    }

    fn deinit(e: *Entries, gpa: std.mem.Allocator) void {
        e.map.deinit(gpa);
        gpa.free(e.bytes);
        e.* = undefined;
    }
};

fn onlyPack(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) ![]u8 {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) return gpa.dupe(u8, entry.name[0 .. entry.name.len - 5]);
    }
    return error.FileNotFound;
}

fn repackInto(gpa: std.mem.Allocator, io: Io, repo: *testgit.Repo, out_name: []const u8, options: odb_mod.PackOptions) !pack_mod.WriteReport {
    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    var db = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    var collected = try db.collectAll(io, .{});
    defer collected.deinit();
    try repo.dir.createDirPath(io, out_name);
    var out = try repo.dir.openDir(io, out_name, .{ .iterate = true });
    defer out.close(io);
    return db.writePack(io, out, collected.entries, options);
}

test "a repack writes what git's pack stores as git stored it, deltas included, the same on 1, 2, 7 and 16 tasks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try gitPacked(gpa, io, "50");
    defer repo.deinit();

    const serial = try repackInto(gpa, io, &repo, "out1", .{ .threads = 1 });
    for ([_]u16{ 2, 7, 16 }) |threads| {
        var name: [16]u8 = undefined;
        const report = try repackInto(gpa, io, &repo, try std.mem.print(&name, "out{d}", .{threads}), .{ .threads = threads });
        try std.testing.expect(report.name.eql(serial.name));
    }

    var git_pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer git_pack_dir.close(io);
    const git_base = try onlyPack(gpa, io, git_pack_dir);
    defer gpa.free(git_base);
    var theirs = try Entries.read(gpa, io, git_pack_dir, git_base);
    defer theirs.deinit(gpa);
    var out_dir = try repo.dir.openDir(io, "out1", .{ .iterate = true });
    defer out_dir.close(io);
    const out_base = try onlyPack(gpa, io, out_dir);
    defer gpa.free(out_base);
    var ours = try Entries.read(gpa, io, out_dir, out_base);
    defer ours.deinit(gpa);

    // Every entry git stored that relic wrote the same way is git's bytes.
    var same_deltas: usize = 0;
    var same_whole: usize = 0;
    var it = ours.map.iterator();
    while (it.next()) |entry| {
        const theirs_entry = theirs.map.get(entry.key_ptr.*).?;
        if (theirs_entry.delta != entry.value_ptr.delta) continue;
        const same = std.mem.eql(u8, theirs_entry.stream, entry.value_ptr.stream);
        if (entry.value_ptr.delta) {
            if (same) same_deltas += 1;
        } else {
            if (!same) {
                std.debug.print("an object git stored whole was deflated again\n", .{});
                return error.TestUnexpectedResult;
            }
            same_whole += 1;
        }
    }
    if (same_deltas == 0 or same_deltas * 2 < serial.deltas) {
        std.debug.print("{d} of {d} deltas are git's\n", .{ same_deltas, serial.deltas });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(same_whole > 0);
}

test "deltas a repack reuses keep their chains within the depth asked for" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try gitPacked(gpa, io, "50");
    defer repo.deinit();
    for ([_]u32{ 1, 3 }) |depth| {
        var name: [16]u8 = undefined;
        const dir_name = try std.mem.print(&name, "depth{d}", .{depth});
        const report = try repackInto(gpa, io, &repo, dir_name, .{ .depth = depth });
        try std.testing.expect(report.deltas > 0);
        var out_dir = try repo.dir.openDir(io, dir_name, .{ .iterate = true });
        defer out_dir.close(io);
        const base = try onlyPack(gpa, io, out_dir);
        defer gpa.free(base);
        var ours = try Entries.read(gpa, io, out_dir, base);
        defer ours.deinit(gpa);
        var it = ours.map.valueIterator();
        while (it.next()) |entry| try std.testing.expect(entry.depth <= depth);
    }
}

test "a stored delta whose bytes no longer match the pack index's CRC is refused, not copied" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try gitPacked(gpa, io, "50");
    defer repo.deinit();
    _ = try repackInto(gpa, io, &repo, "before", .{});

    var git_pack_dir = try repo.dir.openDir(io, ".git/objects/pack", .{ .iterate = true });
    defer git_pack_dir.close(io);
    const git_base = try onlyPack(gpa, io, git_pack_dir);
    defer gpa.free(git_base);
    var theirs = try Entries.read(gpa, io, git_pack_dir, git_base);
    defer theirs.deinit(gpa);
    var out_dir = try repo.dir.openDir(io, "before", .{ .iterate = true });
    defer out_dir.close(io);
    const out_base = try onlyPack(gpa, io, out_dir);
    defer gpa.free(out_base);
    var ours = try Entries.read(gpa, io, out_dir, out_base);
    defer ours.deinit(gpa);

    // A delta relic copied: one bit of its stream flipped in git's pack.
    var it = ours.map.iterator();
    const at = while (it.next()) |entry| {
        const t = theirs.map.get(entry.key_ptr.*).?;
        if (t.delta and entry.value_ptr.delta and std.mem.eql(u8, t.stream, entry.value_ptr.stream))
            break @intFromPtr(t.stream.ptr) - @intFromPtr(theirs.bytes.ptr) + t.stream.len / 2;
    } else return error.TestUnexpectedResult;
    theirs.bytes[at] ^= 0x10;
    var name: [128]u8 = undefined;
    const pack_name = try std.mem.print(&name, "{s}.pack", .{git_base});
    try git_pack_dir.deleteFile(io, pack_name);
    try git_pack_dir.writeFile(io, .{ .sub_path = pack_name, .data = theirs.bytes });

    for ([_]u16{ 1, 4 }) |threads| {
        var dir_name: [16]u8 = undefined;
        try std.testing.expectError(error.CorruptPackEntry, repackInto(gpa, io, &repo, try std.mem.print(&dir_name, "after{d}", .{threads}), .{ .threads = threads }));
    }
}

test "verifying a database checks its packs' entries on several tasks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var repo = try gitPacked(gpa, io, "50");
    defer repo.deinit();
    var git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var objects = try git_dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);

    var db = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{ .probe_timestamp_resolution = false });
    defer db.deinit(io);
    var pack_dir = try objects.openDir(io, "pack", .{ .iterate = true });
    defer pack_dir.close(io);
    const base = try onlyPack(gpa, io, pack_dir);
    defer gpa.free(base);
    var p = try pack_mod.Pack.open(gpa, io, pack_dir, base, .sha1, .{});
    defer p.deinit(io);
    const serial = try p.verify(Tasks.wrap(io), null, 0);
    try Tasks.expect(0, 0);
    var single: Io.Threaded = .init_single_threaded;
    for ([_]Io{ io, single.io() }) |each_io| {
        const report = try db.verify(Tasks.wrap(each_io));
        try std.testing.expect(report.packed_objects > 100);
        try std.testing.expectEqual(@as(u32, 1), report.packs);
        try std.testing.expectEqual(@as(u32, 0), report.loose);
        try std.testing.expectEqual(serial.objects, report.packed_objects);
        try std.testing.expectEqual(serial.bytes, report.bytes);
        // One batch's entries and checksum, shared with the caller.
        try Tasks.expect(@min(std.Thread.getCpuCount() catch 1, report.packed_objects + 1) - 1, 0);
    }
}
