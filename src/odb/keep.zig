//! Received-pack retention. Git honours the marker while relic's tokens
//! share it under the marker's lock. A foreign marker is never removed.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");

pub const Error = fs.LockError || fs.CommitError || Io.Dir.OpenError || Io.Dir.ReadFileAllocError || Io.Dir.DeleteFileError || Allocator.Error;

pub const Token = struct {
    gpa: Allocator,
    dir: Io.Dir,
    name: [hash.max_hex_len + 10]u8,
    name_len: usize,
    id: [24]u8,
    managed: bool,

    const header = "relic keep tokens v1\n";

    /// The directory handle is owned by this token, independent of the
    /// receiver's handle. Acquiring precedes publication of the pack index.
    pub fn open(gpa: Allocator, io: Io, pack_dir: Io.Dir, oid: hash.Oid) Error!Token {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const dir = try pack_dir.openDir(io, ".", .{});
        errdefer dir.close(io);
        var t: Token = .{ .gpa = gpa, .dir = dir, .name = undefined, .name_len = 0, .id = undefined, .managed = true };
        var hex: [hash.max_hex_len]u8 = undefined;
        const name = std.mem.print(&t.name, "pack-{s}.keep", .{oid.hex(&hex)}) catch unreachable;
        t.name_len = name.len;
        var random: [12]u8 = undefined;
        io.random(&random);
        t.id = std.fmt.bytesToHex(random, .lower);
        var buffer: [4096]u8 = undefined;
        var lock = try fs.LockFile.open(gpa, io, dir, name, &buffer, .{ .sync = .none, .on_contention = .{ .wait_ms = 1000 } });
        defer lock.deinit(io);
        const previous = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, header),
            else => return err,
        };
        defer gpa.free(previous);
        if (!std.mem.startsWith(u8, previous, header)) {
            t.managed = false;
            return t;
        }
        try lock.writer().writeAll(previous);
        try lock.writer().print("{s}\n", .{t.id});
        try lock.commit(io);
        return t;
    }

    /// Release after ref commit or controlled rollback. Cleanup cannot be
    /// canceled. If cleanup fails, retain the protective marker on disk.
    pub fn deinit(t: *Token, io: Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        defer t.dir.close(io);
        // ziglint-ignore: Z026 failed cleanup retains the marker, keeping unreferenced objects protected
        if (t.managed) t.release(io) catch {};
    }

    fn release(t: *Token, io: Io) Error!void {
        const name = t.name[0..t.name_len];
        var buffer: [4096]u8 = undefined;
        var lock = try fs.LockFile.open(t.gpa, io, t.dir, name, &buffer, .{ .sync = .none, .on_contention = .{ .wait_ms = 1000 } });
        defer lock.deinit(io);
        const previous = try t.dir.readFileAlloc(io, name, t.gpa, .limited(1 << 20));
        defer t.gpa.free(previous);
        if (!std.mem.startsWith(u8, previous, header)) return;
        var lines = std.mem.splitScalar(u8, previous[header.len..], '\n');
        var remaining: usize = 0;
        try lock.writer().writeAll(header);
        while (lines.next()) |line| {
            if (line.len == 0 or std.mem.eql(u8, line, &t.id)) continue;
            remaining += 1;
            try lock.writer().print("{s}\n", .{line});
        }
        if (remaining == 0) {
            // The lock excludes new token acquisition through this deletion.
            try t.dir.deleteFile(io, name);
        } else try lock.commit(io);
    }
};

test "phase2 keep tokens retain shared and foreign markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const name = "pack-1111111111111111111111111111111111111111.keep";
    var a = try Token.open(gpa, io, tmp.dir, oid);
    var b = try Token.open(gpa, io, tmp.dir, oid);
    a.deinit(io);
    try tmp.dir.access(io, name, .{});
    b.deinit(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, name, .{}));
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "external keep\n" });
    var c = try Token.open(gpa, io, tmp.dir, oid);
    c.deinit(io);
    const bytes = try tmp.dir.readFileAlloc(io, name, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("external keep\n", bytes);
}

test "phase2 keep acquisition allocation failures abandon no lock or marker" {
    var no_resize = @import("shakedown").alloc.NoResize.init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(gpa: Allocator) !void {
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
            var token = try Token.open(gpa, io, tmp.dir, oid);
            // Isolate acquisition failures; cleanup has its own conservative-failure contract.
            token.gpa = std.testing.allocator;
            token.deinit(io);
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep", .{}));
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep.lock", .{}));
        }
    }.exercise, .{});
}

test "phase2 keep cleanup survives cancellation of its owner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const Worker = struct {
        fn run(gpa: Allocator, worker_io: Io, dir: Io.Dir, name: hash.Oid, ready: *Io.Event, parked: *Io.Event) !void {
            errdefer ready.set(worker_io);
            var token = try Token.open(gpa, worker_io, dir, name);
            defer token.deinit(worker_io);
            ready.set(worker_io);
            try parked.wait(worker_io);
        }
    };
    var ready: Io.Event = .unset;
    var parked: Io.Event = .unset;
    var worker = try io.concurrent(Worker.run, .{ std.testing.allocator, io, tmp.dir, oid, &ready, &parked });
    defer _ = worker.cancel(io) catch {};
    try ready.wait(io);
    try tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep", .{});
    try std.testing.expectError(error.Canceled, worker.cancel(io));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep.lock", .{}));
}

test "phase2 keep cleanup failure preserves the marker rather than exposing objects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    var token = try Token.open(gpa, io, tmp.dir, oid);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    token.gpa = failing.allocator();
    token.deinit(io);
    const marker = "pack-1111111111111111111111111111111111111111.keep";
    try tmp.dir.access(io, marker, .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, marker ++ ".lock", .{}));
    const bytes = try tmp.dir.readFileAlloc(io, marker, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, Token.header));
}
