//! Received-pack retention. Git honours the marker while relic's tokens
//! share it under the marker's lock. A foreign marker is never removed.
const ErrorNamespace = @This();
const std = @import("std");
const aegis = @import("aegis");
const shakedown_mod = @import("shakedown");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const warning = @import("../report.zig").warning;

pub const Error = fs.LockError || fs.CommitError || Io.Dir.OpenError || aegis.own.ReadFileError || Io.Dir.DeleteFileError || Allocator.Error;

pub const Token = struct {
    pub const Error = ErrorNamespace.Error;

    dir: fs.OwnedDir,
    /// This token's entry in a marker relic shares; null over a foreign
    /// marker, which relic never changes, so a token over one has nothing to
    /// release.
    listing: ?Listing,

    /// A token's line in a shared marker, and how to take it out again.
    pub const Listing = struct {
        gpa: Allocator,
        /// The marker's file name, `pack-<name>.keep`: as long as `kind`'s
        /// names and the affixes.
        name: [hash.max_hex_len + affixes.len]u8,
        kind: hash.Kind,
        id: [24]u8,

        /// The marker's file name.
        pub fn fileName(l: *const Listing) []const u8 {
            return l.name[0 .. l.kind.hexLen() + affixes.len];
        }

        /// This entry out of the marker, under its lock; the marker goes with
        /// its last entry.
        fn release(l: *const Listing, io: Io, dir: Io.Dir) ErrorNamespace.Error!void {
            const name = l.fileName();
            var buffer: [4096]u8 = undefined;
            var lock = try fs.LockFile.open(l.gpa, io, dir, .{ .sub_path = name, .buffer = &buffer }, .{ .sync = .none, .on_contention = .{ .wait = .fromMilliseconds(1000) } });
            defer lock.deinit(io);
            const previous = try aegis.own.readFile(io, dir, name, l.gpa, aegis.units.Bytes(u64).fromRaw(1 << 20));
            defer l.gpa.free(previous);
            if (!std.mem.startsWith(u8, previous, header)) return;
            var lines = std.mem.splitScalar(u8, previous[header.len..], '\n');
            var remaining: usize = 0;
            try lock.writeAll(header);
            while (lines.next()) |line| {
                if (line.len == 0 or std.mem.eql(u8, line, &l.id)) continue;
                remaining += 1;
                try lock.print("{s}\n", .{line});
            }
            if (remaining == 0) {
                // The lock excludes new token acquisition through this deletion.
                try dir.deleteFile(io, name);
            } else try lock.commit(io);
        }
    };

    const header = "relic keep tokens v1\n";
    const affixes = "pack-.keep";

    /// The directory handle is owned by this token, independent of the
    /// receiver's handle. Acquiring precedes publication of the pack index.
    pub fn open(gpa: Allocator, io: Io, pack_dir: Io.Dir, oid: hash.Oid) ErrorNamespace.Error!Token {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const dir = try pack_dir.openDir(io, ".", .{});
        errdefer dir.close(io);
        var listing: Listing = .{ .gpa = gpa, .name = undefined, .kind = oid.kind, .id = undefined };
        var hex: [hash.max_hex_len]u8 = undefined;
        // unreachable: the buffer holds the maximum hex name and the fixed pack/keep affixes.
        const name = std.mem.print(&listing.name, "pack-{s}.keep", .{oid.hex(&hex)}) catch unreachable;
        var random: [12]u8 = undefined;
        io.random(&random);
        listing.id = std.fmt.bytesToHex(random, .lower);
        var buffer: [4096]u8 = undefined;
        var lock = try fs.LockFile.open(gpa, io, dir, .{ .sub_path = name, .buffer = &buffer }, .{ .sync = .none, .on_contention = .{ .wait = .fromMilliseconds(1000) } });
        defer lock.deinit(io);
        const previous = aegis.own.readFile(io, dir, name, gpa, aegis.units.Bytes(u64).fromRaw(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, header),
            else => return err,
        };
        defer gpa.free(previous);
        if (!std.mem.startsWith(u8, previous, header)) return .{ .dir = fs.OwnedDir.init(dir), .listing = null };
        try lock.writeAll(previous);
        try lock.print("{s}\n", .{listing.id});
        try lock.commit(io);
        return .{ .dir = fs.OwnedDir.init(dir), .listing = listing };
    }

    /// Once the refs name what this token held: its entry leaves the marker,
    /// which goes with the last entry. A release that fails leaves the marker,
    /// still protecting the objects, and is a warning in `warnings`, as git's
    /// `unlink_or_warn` is: the operation itself is done. The token holds
    /// nothing afterwards either way, so `deinit` releases nothing twice.
    pub fn finish(t: *Token, io: Io, warnings: ?*warning.Warnings) Allocator.Error!void {
        const listing = t.listing orelse return;
        t.listing = null;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        listing.release(io, t.dir.borrow().*) catch |err|
            try warning.note(warnings, .{ .keep_left = .{ .path = listing.fileName(), .reason = @errorName(err) } });
    }

    /// Release on unwind or controlled rollback (after `finish` it holds
    /// nothing). Cleanup cannot be canceled. If cleanup fails, retain the
    /// protective marker on disk.
    pub fn deinit(t: *Token, io: Io) void {
        defer t.* = undefined;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        defer t.dir.deinit(io);
        // glint-ignore: Z026 -- on unwind the operation's own error is the one returned; a marker left keeps the objects protected
        if (t.listing) |*listing| listing.release(io, t.dir.borrow().*) catch {};
    }
};

test "keep tokens retain shared and foreign markers" {
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

test "keep acquisition allocation failures abandon no lock or marker" {
    var no_resize = shakedown_mod.alloc.NoResize.init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(gpa: Allocator) !void {
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
            var token = try Token.open(gpa, io, tmp.dir, oid);
            // Isolate acquisition failures; cleanup has its own conservative-failure contract.
            token.listing.?.gpa = std.testing.allocator;
            token.deinit(io);
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep", .{}));
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep.lock", .{}));
        }
    }.exercise, .{});
}

test "keep cleanup survives cancellation of its owner" {
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
    // glint-ignore: Z026 -- the worker is canceled to stop it; its outcome is checked through the events
    defer _ = worker.cancel(io) catch {};
    try ready.wait(io);
    try tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep", .{});
    try std.testing.expectError(error.Canceled, worker.cancel(io));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pack-1111111111111111111111111111111111111111.keep.lock", .{}));
}

test "keep cleanup failure preserves the marker rather than exposing objects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    var token = try Token.open(gpa, io, tmp.dir, oid);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    token.listing.?.gpa = failing.allocator();
    token.deinit(io);
    const marker = "pack-1111111111111111111111111111111111111111.keep";
    try tmp.dir.access(io, marker, .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, marker ++ ".lock", .{}));
    const bytes = try tmp.dir.readFileAlloc(io, marker, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, Token.header));
}

test "a token over a foreign marker holds no entry, and finishing it changes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const marker = "pack-1111111111111111111111111111111111111111.keep";
    try tmp.dir.writeFile(io, .{ .sub_path = marker, .data = "external keep\n" });
    var token = try Token.open(gpa, io, tmp.dir, oid);
    try std.testing.expect(token.listing == null);
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    try token.finish(io, &warnings);
    token.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.items.len);
    const bytes = try tmp.dir.readFileAlloc(io, marker, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("external keep\n", bytes);
}

test "a finished token releases its entry once: deinit after it leaves another token's entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const marker = "pack-1111111111111111111111111111111111111111.keep";
    var a = try Token.open(gpa, io, tmp.dir, oid);
    var b = try Token.open(gpa, io, tmp.dir, oid);
    defer b.deinit(io);
    try a.finish(io, null);
    try std.testing.expect(a.listing == null);
    a.deinit(io);
    // b's entry is the one left: the marker stands, with b's line and not a's.
    const bytes = try tmp.dir.readFileAlloc(io, marker, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(Token.header ++ b.listing.?.id ++ "\n", bytes);
}

test "a finish whose release fails keeps the marker and records a warning, the operation going on" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const oid = try hash.Oid.parse(.sha1, "1111111111111111111111111111111111111111");
    const marker = "pack-1111111111111111111111111111111111111111.keep";
    var token = try Token.open(gpa, io, tmp.dir, oid);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    token.listing.?.gpa = failing.allocator();
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    try token.finish(io, &warnings);
    token.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.items.len);
    try std.testing.expectEqualStrings(marker, warnings.items.items[0].keep_left.path);
    try tmp.dir.access(io, marker, .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, marker ++ ".lock", .{}));
}
