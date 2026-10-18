//! One directory's entries, and what a stat says about each, as git reads
//! them.
//!
//! A walk over a working tree asks two things of every entry: its name, and
//! the stat git's index compares. airlock's scan (`airlock.scan`) reads
//! both, on macOS a batch of entries per `getattrlistbulk(2)` call with the
//! `dev`, `ino`, `uid` and `gid` that `std.Io.File.Stat` does not carry,
//! elsewhere a directory read and a stat per entry. What is git's here is
//! how each is taken: the name composed under `core.precomposeUnicode`
//! (`fs.readName`), the stat in git's view (`fs.scannedEntry`: on Windows
//! git for Windows' `mingw_lstat`).
//!
//! A directory's size is zero: a batch reports none. Nothing in this
//! package asks a directory how long it is: a walk uses a directory's stat
//! to decide nothing, and the index holds no entry for one.

const ErrorNamespace = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const airlock = @import("airlock");

const fs = @import("../fs/fs.zig");

/// One directory entry.
///
/// `name` is the name git reads (`fs.readName`): on macOS under
/// `core.precomposeUnicode`, composed. It points into the scan's own buffer
/// and is valid until the next call to `next`. Copy it to keep it.
pub const Item = struct {
    name: []const u8,
    entry: fs.Entry,
};

/// Errors from reading a directory.
pub const Error = airlock.Scan.Error || fs.StatError || Allocator.Error;

/// Reads `dir`, giving each entry with its stat.
///
/// `.` and `..` are never given. The order is the filesystem's, which is not
/// sorted on either arm; a caller that needs an order imposes it.
pub const Scan = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    buffer: []align(@alignOf(usize)) u8,
    scan: airlock.Scan,
    precompose: bool,
    /// Where a composed name is written.
    name_buffer: [fs.name_max]u8 = undefined,

    /// How a scan reads names.
    pub const Options = struct {
        /// `core.precomposeUnicode` on macOS: give a decomposed name
        /// composed, as git's `readdir` does (`fs.readName`).
        precompose: bool = false,
    };

    /// How many bytes one batch is read into: several hundred entries, so
    /// a directory of any ordinary size is one call.
    const batch_bytes = 64 * 1024;

    comptime {
        std.debug.assert(batch_bytes >= airlock.Scan.min_buffer_len);
    }

    /// Begin reading `dir`, in batches where the platform and the volume
    /// have them.
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) Allocator.Error!Scan {
        const buffer = try gpa.alignedAlloc(u8, .of(usize), batch_bytes);
        return .{ .gpa = gpa, .io = io, .dir = dir, .buffer = buffer, .scan = airlock.scan(dir, buffer), .precompose = options.precompose };
    }

    /// Begin reading `dir` the ordinary way, whatever the platform has: what
    /// a caller uses to reproduce a result on a machine whose volume takes
    /// the other arm.
    pub fn initPlain(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) Allocator.Error!Scan {
        var s = try init(gpa, io, dir, options);
        s.scan = .initPlain(dir, s.buffer);
        return s;
    }

    /// Release the scan's buffer.
    pub fn deinit(s: *Scan) void {
        s.gpa.free(s.buffer);
        s.* = undefined;
    }

    /// Whether this scan is reading batches rather than one entry at a time,
    /// once `next` has been called. A caller that measures asks here;
    /// nothing in the package branches on it.
    pub fn isBulk(s: *const Scan) bool {
        return s.scan.isBatched();
    }

    /// The next entry, or `null` at the end of the directory.
    pub fn next(s: *Scan) Scan.Error!?Item {
        while (try s.scan.next(s.io)) |found| {
            const entry = (try fs.scannedEntry(s.io, s.dir, found.name, found.stat)) orelse continue;
            return .{ .name = fs.readName(found.name, s.precompose, &s.name_buffer), .entry = entry };
        }
        return null;
    }
};

/// Which arm a walk over this directory takes. A benchmark says so in its
/// output; nothing in the package branches on it.
pub fn armFor(gpa: Allocator, io: Io, dir: Io.Dir) []const u8 {
    var scan = Scan.init(gpa, io, dir, .{}) catch return "unknown";
    defer scan.deinit();
    _ = scan.next() catch return "unknown";
    return if (scan.isBulk()) "getattrlistbulk" else "one stat per entry";
}

test "a scan describes every entry as a stat of its name does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "some bytes\n" });
    try dir.writeFile(io, .{ .sub_path = ".hidden", .data = "dot\n" });
    try dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try dir.createDir(io, "sub", .default_dir);
    try dir.writeFile(io, .{ .sub_path = "runnable", .data = "#!/bin/sh\n" });
    if (Io.File.Permissions.has_executable_bit) {
        const runnable = try dir.openFile(io, "runnable", .{});
        defer runnable.close(io);
        try runnable.setPermissions(io, @fromBackingInt(@intCast(@as(std.posix.mode_t, 0o755))));
    }
    var has_link = true;
    dir.symLink(io, "plain.txt", "link", .{}) catch {
        has_link = false;
    };

    for ([_]bool{ false, true }) |plain| {
        var scan = if (plain) try Scan.initPlain(gpa, io, dir, .{}) else try Scan.init(gpa, io, dir, .{});
        defer scan.deinit();
        var seen: usize = 0;
        while (try scan.next()) |item| {
            const want = (try fs.statAt(io, dir, item.name)).?;
            try std.testing.expectEqual(want.kind, item.entry.kind);
            try std.testing.expectEqual(want.executable, item.entry.executable);
            try std.testing.expectEqual(want.stat.mtime_sec, item.entry.stat.mtime_sec);
            try std.testing.expectEqual(want.stat.mtime_nsec, item.entry.stat.mtime_nsec);
            try std.testing.expectEqual(want.stat.ctime_sec, item.entry.stat.ctime_sec);
            try std.testing.expectEqual(want.stat.ctime_nsec, item.entry.stat.ctime_nsec);
            try std.testing.expectEqual(want.stat.ino, item.entry.stat.ino);
            try std.testing.expectEqual(want.stat.dev, item.entry.stat.dev);
            try std.testing.expectEqual(want.stat.uid, item.entry.stat.uid);
            try std.testing.expectEqual(want.stat.gid, item.entry.stat.gid);
            if (want.kind != .directory) try std.testing.expectEqual(want.stat.size, item.entry.stat.size);
            seen += 1;
        }
        try std.testing.expectEqual(@as(usize, if (has_link) 6 else 5), seen);
        if (plain) try std.testing.expect(!scan.isBulk());
    }
}

test "a scan of an empty directory gives nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var scan = try Scan.init(gpa, io, tmp.dir, .{});
    defer scan.deinit();
    try std.testing.expect((try scan.next()) == null);
    try std.testing.expect((try scan.next()) == null);
}

test "both arms give a decomposed name composed when asked, and as spelled when not" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "cafe\u{301}", .data = "x" });
    for ([_]bool{ false, true }) |precompose| {
        for ([_]bool{ false, true }) |plain| {
            var scan = if (plain) try Scan.initPlain(gpa, io, tmp.dir, .{ .precompose = precompose }) else try Scan.init(gpa, io, tmp.dir, .{ .precompose = precompose });
            defer scan.deinit();
            const item = (try scan.next()) orelse return error.TestUnexpectedResult;
            // the composition is what was asked for; the stat is the file's
            try std.testing.expectEqualStrings(if (precompose) "caf\u{e9}" else "cafe\u{301}", item.name);
            try std.testing.expectEqual(@as(u32, 1), item.entry.stat.size);
            try std.testing.expectEqual(null, try scan.next());
        }
    }
}
