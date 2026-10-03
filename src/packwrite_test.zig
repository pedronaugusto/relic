//! Pack writing on the caller's executor: every worker count and every kind
//! of `std.Io` writes the bytes the serial writer writes.

const std = @import("std");
const Io = std.Io;
const hash = @import("hash.zig");
const odb_mod = @import("odb_core.zig");

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
            const hint = try std.fmt.allocPrint(gpa, "src/file{d}.txt", .{f});
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
    }

    /// Write the corpus as one pack through `io` and say what was written.
    fn write(c: *Corpus, gpa: std.mem.Allocator, io: Io, options: odb_mod.PackOptions) !@import("pack.zig").WriteReport {
        var db = try odb_mod.Odb.openAt(gpa, io, c.objects, .sha1, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        var pack_dir = try c.objects.openDir(io, "pack", .{ .iterate = true });
        defer pack_dir.close(io);
        return db.writePack(io, pack_dir, c.entries.items, options);
    }
};

/// Which threads opened a loose object.
const Openers = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var ids: [64]std.Thread.Id = undefined;
    var count: usize = 0;
    /// While set, the first open on the thread that set it waits, for a
    /// while, until some other thread has opened one too: a serial writer
    /// never gets one, and a parallel writer has its other tasks take the
    /// next objects meanwhile.
    var waiting_for_other: ?std.Thread.Id = null;

    fn reset(wait_from: ?std.Thread.Id) void {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        count = 0;
        waiting_for_other = wait_from;
    }

    fn distinct() usize {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        return count;
    }

    /// Whether this is the first open on the waiting thread, which then
    /// waits no more.
    fn takeWait() bool {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        if (waiting_for_other != std.Thread.getCurrentId()) return false;
        waiting_for_other = null;
        return true;
    }

    fn note() bool {
        const me = std.Thread.getCurrentId();
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        for (ids[0..count]) |id| if (id == me) return false;
        if (count < ids.len) {
            ids[count] = me;
            count += 1;
        }
        return true;
    }

    fn open(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
        // Only loose objects, `xx/` and the rest of the name: opening the
        // database reads other files first, on the calling thread.
        const loose = sub_path.len == 41 and sub_path[2] == '/';
        if (!loose) return std.testing.io.vtable.dirOpenFile(userdata, dir, sub_path, options);
        if (note() and takeWait()) {
            var waited: usize = 0;
            while (waited < 5000) : (waited += 1) {
                {
                    while (!mutex.tryLock()) {}
                    defer mutex.unlock();
                    if (count > 1) break;
                }
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch break;
            }
        }
        return std.testing.io.vtable.dirOpenFile(userdata, dir, sub_path, options);
    }
};

test "a pack is built by several tasks of a threaded Io by default, by one when asked, and is the same pack" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, io, 8, 6, 24);
    defer corpus.deinit(gpa, io);

    var vtable = io.vtable.*;
    vtable.dirOpenFile = Openers.open;
    const watched: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    // The default: the caller's threaded Io carries the work, on more than
    // the calling thread.
    Openers.reset(std.Thread.getCurrentId());
    const parallel = try corpus.write(gpa, watched, .{});
    if (Openers.distinct() < 2) {
        std.debug.print("the default pack write opened its objects on {d} thread\n", .{Openers.distinct()});
        return error.TestUnexpectedResult;
    }

    // One task: the serial writer, on the calling thread alone.
    Openers.reset(null);
    const serial = try corpus.write(gpa, watched, .{ .threads = 1 });
    try std.testing.expectEqual(@as(usize, 1), Openers.distinct());

    // An Io that runs every task inline runs them one after another.
    var single: Io.Threaded = .init_single_threaded;
    var single_vtable = single.io().vtable.*;
    single_vtable.dirOpenFile = Openers.open;
    const single_watched: Io = .{ .userdata = single.io().userdata, .vtable = &single_vtable };
    Openers.reset(null);
    const inline_tasks = try corpus.write(gpa, single_watched, .{});
    try std.testing.expectEqual(@as(usize, 1), Openers.distinct());

    try std.testing.expect(parallel.name.eql(serial.name));
    try std.testing.expect(inline_tasks.name.eql(serial.name));
    try std.testing.expect(serial.deltas > 0);
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
        const o: *OneThread = @ptrCast(@alignCast(ctx));
        if (!o.mine()) return null;
        const p = o.child.rawAlloc(len, alignment, ret) orelse return null;
        o.live += len;
        o.peak = @max(o.peak, o.live);
        return p;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const o: *OneThread = @ptrCast(@alignCast(ctx));
        if (!o.mine()) return false;
        if (!o.child.rawResize(memory, alignment, new_len, ret)) return false;
        o.live = o.live - memory.len + new_len;
        o.peak = @max(o.peak, o.live);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const o: *OneThread = @ptrCast(@alignCast(ctx));
        if (!o.mine()) return null;
        const p = o.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        o.live = o.live - memory.len + new_len;
        o.peak = @max(o.peak, o.live);
        return p;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const o: *OneThread = @ptrCast(@alignCast(ctx));
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
            try entries.append(gpa, .{ .oid = try db.write(io, .blob, try std.fmt.bufPrint(&text, "small {d}\n", .{i})) });
        }
    }

    const workers = 4;
    const Run = struct { name: @import("hash.zig").Oid, peak: usize };
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
    const one_object = 64 * 1024 + @import("pack.zig").Deflater.room(64 * 1024);
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

fn writeWith(corpus: *Corpus, gpa: std.mem.Allocator, io: Io, options: odb_mod.PackOptions) anyerror!@import("pack.zig").WriteReport {
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

/// How many tasks a write asked its Io for.
const Spawns = struct {
    var count: std.atomic.Value(usize) = .init(0);

    fn groupAsync(
        userdata: ?*anyopaque,
        group: *Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void {
        _ = count.fetchAdd(1, .monotonic);
        std.testing.io.vtable.groupAsync(userdata, group, context, context_alignment, start);
    }
};

test "a pack of fewer objects than tasks asks for no more tasks than it has objects" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var vtable = io.vtable.*;
    vtable.groupAsync = Spawns.groupAsync;
    const counted: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    for ([_]usize{ 1, 2, 3 }) |objects| {
        var corpus = try Corpus.init(gpa, io, 1, objects, 0);
        defer corpus.deinit(gpa, io);
        const serial = try corpus.write(gpa, io, .{ .threads = 1 });
        Spawns.count.store(0, .monotonic);
        const report = try corpus.write(gpa, counted, .{ .threads = 8 });
        try std.testing.expect(report.name.eql(serial.name));
        // Each of the write's stages — headers, bodies, deflating — shares
        // its objects among the calling task and at most one task for each
        // other object.
        const spawned = Spawns.count.load(.monotonic);
        if (spawned > 3 * (objects - 1)) {
            std.debug.print("{d} objects: {d} tasks\n", .{ objects, spawned });
            return error.TestUnexpectedResult;
        }
    }
}

/// Which threads read a file positionally: in a repository whose objects
/// are all packed, after it is opened, the pack.
const Readers = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var ids: [64]std.Thread.Id = undefined;
    var count: usize = 0;
    var waiting_for_other: ?std.Thread.Id = null;

    fn reset(wait_from: ?std.Thread.Id) void {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        count = 0;
        waiting_for_other = wait_from;
    }

    fn distinct() usize {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        return count;
    }

    /// Note this thread; true for its first read while the calling thread
    /// waits for another, which then waits no more.
    fn note() bool {
        const me = std.Thread.getCurrentId();
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        for (ids[0..count]) |id| if (id == me) return false;
        if (count < ids.len) {
            ids[count] = me;
            count += 1;
        }
        if (waiting_for_other != me) return false;
        waiting_for_other = null;
        return true;
    }

    fn read(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        // The calling thread's first read waits, for a while, until some
        // other thread has read too: a serial reader never gets one.
        if (note()) {
            var waited: usize = 0;
            while (waited < 5000) : (waited += 1) {
                if (distinct() > 1) break;
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch break;
            }
        }
        return std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
    }
};

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

    var vtable = io.vtable.*;
    vtable.fileReadPositional = Readers.read;
    const watched: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const Repack = struct {
        fn write(c: *Corpus, a: std.mem.Allocator, opened: Io, read: Io, threads: u16) !@import("pack.zig").WriteReport {
            // One block cached, so that reading is reading the file.
            var db = try odb_mod.Odb.openAt(a, opened, c.objects, .sha1, .{ .probe_timestamp_resolution = false, .pack_read_cache_bytes = 0 });
            defer db.deinit(opened);
            var collected = try db.collectAll(opened, .{});
            defer collected.deinit();
            for (collected.entries) |entry| try std.testing.expect(entry.in_pack);
            try c.tmp.dir.createDirPath(opened, "out");
            var out = try c.tmp.dir.openDir(opened, "out", .{ .iterate = true });
            defer out.close(opened);
            Readers.reset(if (threads == 1) null else std.Thread.getCurrentId());
            return db.writePack(read, out, collected.entries, .{ .threads = threads });
        }
    };
    const serial = try Repack.write(&corpus, gpa, io, watched, 1);
    try std.testing.expectEqual(@as(usize, 1), Readers.distinct());
    const parallel = try Repack.write(&corpus, gpa, io, watched, 4);
    if (Readers.distinct() < 2) {
        std.debug.print("the packed objects were read on {d} thread\n", .{Readers.distinct()});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(parallel.name.eql(serial.name));
    try std.testing.expect(serial.deltas > 0);
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
            const s: *Spy = @ptrCast(@alignCast(ctx));
            if (len >= 16 * 1024) event(.search_alloc);
            return s.child.rawAlloc(len, alignment, ret);
        }
        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
            const s: *Spy = @ptrCast(@alignCast(ctx));
            return s.child.rawResize(memory, alignment, new_len, ret);
        }
        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
            const s: *Spy = @ptrCast(@alignCast(ctx));
            return s.child.rawRemap(memory, alignment, new_len, ret);
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const s: *Spy = @ptrCast(@alignCast(ctx));
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

test "the tasks read the next batch while this task searches one, and the pack is the serial writer's" {
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
