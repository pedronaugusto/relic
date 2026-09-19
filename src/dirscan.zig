//! One directory's entries, and what a stat says about each.
//!
//! A walk over a working tree asks two things of every entry: its name, and
//! the stat git's index compares. The ordinary way to get both is a directory
//! read and then one `lstat` per name, which is one syscall per file; macOS
//! has `getattrlistbulk(2)`, which answers both for a whole batch of entries
//! in a single call, including the `dev`, `ino`, `uid` and `gid` that
//! `std.Io.File.Stat` does not carry.
//!
//! Both arms are here and both give the same answer, which is the property
//! the suite checks rather than assumes. The bulk arm is taken when the
//! volume supports it and the ordinary arm when it does not: a volume that
//! answers `ENOTSUP` is not an error, it is the other path.
//!
//! One thing the bulk arm does not report is the data length of a
//! *directory*, which is a file attribute and directories have none. It is
//! zero there. Nothing in this package asks a directory how long it is: a
//! walk uses a directory's stat to decide nothing, and the index holds no
//! entry for one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const fs = @import("fs.zig");
const platstat = @import("platstat.zig");

/// Whether this platform has a call that reads a batch of entries with their
/// stats. A run-time `ENOTSUP` from the volume is still possible, and is a
/// fallback rather than a failure.
pub const bulk_supported = builtin.os.tag == .macos and builtin.link_libc;

/// One directory entry.
///
/// `name` points into the scan's own buffer and is valid until the next call
/// to `next`. Copy it to keep it.
pub const Item = struct {
    name: []const u8,
    entry: fs.Entry,
};

/// Errors from reading a directory.
pub const Error = Io.Dir.Iterator.Error || fs.StatError || Allocator.Error;

/// Reads `dir`, giving each entry with its stat.
///
/// `.` and `..` are never given. The order is the filesystem's, which is not
/// sorted on either arm; a caller that needs an order imposes it.
pub const Scan = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    arm: Arm,

    const Arm = union(enum) {
        /// `getattrlistbulk(2)`: `count` entries left in `buffer` from
        /// `cursor` on, and another call when they run out.
        bulk: struct {
            buffer: []u8,
            cursor: usize,
            count: u32,
            done: bool,
        },
        /// A directory read and one stat per name.
        plain: Io.Dir.Iterator,
    };

    /// How many bytes one batch is read into.
    ///
    /// Sixty-four kilobytes holds several hundred entries of the attributes
    /// asked for here, so a directory of any ordinary size is one call.
    const batch_bytes = 64 * 1024;

    /// Begin reading `dir`.
    ///
    /// The bulk arm is tried first where the platform has one; a volume that
    /// refuses it leaves the scan on the ordinary arm, with nothing consumed.
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir) Allocator.Error!Scan {
        if (bulk_supported) {
            const buffer = try gpa.alloc(u8, batch_bytes);
            // A batch read walks the descriptor's own offset forward, so a
            // scan starts by putting it back. The handle belongs to the
            // caller and may be scanned again; where it is the working tree's
            // own directory it certainly will be.
            rewind(dir);
            if (bulkFirst(dir, buffer)) |count| {
                return .{
                    .gpa = gpa,
                    .io = io,
                    .dir = dir,
                    .arm = .{ .bulk = .{
                        .buffer = buffer,
                        .cursor = 0,
                        .count = count,
                        .done = count == 0,
                    } },
                };
            }
            gpa.free(buffer);
            // Nothing was read, but the descriptor's own offset is what the
            // ordinary read starts from, so put it back at the beginning.
            rewind(dir);
        }
        return .{ .gpa = gpa, .io = io, .dir = dir, .arm = .{ .plain = dir.iterate() } };
    }

    /// Begin reading `dir` the ordinary way, whatever the platform has.
    ///
    /// This is what the suite compares the batch arm against, and what a
    /// caller uses to reproduce a result on a machine whose volume takes the
    /// other path.
    pub fn initPlain(gpa: Allocator, io: Io, dir: Io.Dir) Scan {
        return .{ .gpa = gpa, .io = io, .dir = dir, .arm = .{ .plain = dir.iterate() } };
    }

    /// Release the scan's buffer.
    pub fn deinit(s: *Scan) void {
        switch (s.arm) {
            .bulk => |b| s.gpa.free(b.buffer),
            .plain => {},
        }
        s.* = undefined;
    }

    /// Whether this scan is reading batches rather than one entry at a time.
    /// A caller that measures asks here; nothing in the package branches on
    /// it.
    pub fn isBulk(s: *const Scan) bool {
        return s.arm == .bulk;
    }

    /// The next entry, or `null` at the end of the directory.
    pub fn next(s: *Scan) Error!?Item {
        switch (s.arm) {
            .bulk => |*b| {
                while (true) {
                    if (b.count == 0) {
                        if (b.done) return null;
                        const count = bulkNext(s.dir, b.buffer) orelse return error.Unexpected;
                        if (count == 0) {
                            b.done = true;
                            return null;
                        }
                        b.count = count;
                        b.cursor = 0;
                    }
                    if (b.cursor >= b.buffer.len) return error.Unexpected;
                    const parsed = parseEntry(b.buffer[b.cursor..]) orelse return error.Unexpected;
                    b.cursor += parsed.length;
                    b.count -= 1;
                    if (std.mem.eql(u8, parsed.name, ".") or std.mem.eql(u8, parsed.name, "..")) continue;
                    if (parsed.item) |item| return item;
                    // The volume answered this one entry short. Stat it the
                    // ordinary way rather than making up what it did not say.
                    const found = (try fs.statAt(s.io, s.dir, parsed.name)) orelse continue;
                    return .{ .name = parsed.name, .entry = found };
                }
            },
            .plain => |*it| {
                while (try it.next(s.io)) |entry| {
                    const found = (try fs.statAt(s.io, s.dir, entry.name)) orelse continue;
                    return .{ .name = entry.name, .entry = found };
                }
                return null;
            },
        }
    }
};

//=====================================================================
// getattrlistbulk(2)
//
// The attributes come back packed in the order the bits are numbered, each
// aligned to four bytes -- including the eight-byte ones, which is why every
// field here is read with a copy rather than a cast. `ATTR_CMN_RETURNED_ATTRS`
// comes first and says which of them the volume actually answered, so a
// volume that is short of one is noticed rather than silently misread.
//=====================================================================

const attr = struct {
    const bit_map_count: u16 = 5;

    const cmn_name: u32 = 0x0000_0001;
    const cmn_devid: u32 = 0x0000_0002;
    const cmn_objtype: u32 = 0x0000_0008;
    const cmn_modtime: u32 = 0x0000_0400;
    const cmn_chgtime: u32 = 0x0000_0800;
    const cmn_ownerid: u32 = 0x0000_8000;
    const cmn_grpid: u32 = 0x0001_0000;
    const cmn_accessmask: u32 = 0x0002_0000;
    const cmn_fileid: u32 = 0x0200_0000;
    const cmn_returned_attrs: u32 = 0x8000_0000;

    const file_datalength: u32 = 0x0000_0200;

    const common = cmn_returned_attrs | cmn_name | cmn_devid | cmn_objtype |
        cmn_modtime | cmn_chgtime | cmn_ownerid | cmn_grpid |
        cmn_accessmask | cmn_fileid;

    /// Everything but the data length, which only a file has.
    const common_required = common & ~cmn_returned_attrs;

    const List = extern struct {
        bitmapcount: u16,
        reserved: u16,
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    };

    const list: List = .{
        .bitmapcount = bit_map_count,
        .reserved = 0,
        .commonattr = common,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = file_datalength,
        .forkattr = 0,
    };
};

extern "c" fn getattrlistbulk(
    dirfd: c_int,
    alist: *const anyopaque,
    attr_buf: [*]u8,
    attr_buf_size: usize,
    options: u64,
) c_int;

/// The first batch, or `null` when this volume has no such call.
///
/// Only the first call may answer `null`: a volume that refuses does so
/// before it has given anything out, which is what makes the ordinary arm a
/// clean fallback rather than a resumption.
fn bulkFirst(dir: Io.Dir, buffer: []u8) ?u32 {
    if (!bulk_supported) return null;
    var list = attr.list;
    const rc = getattrlistbulk(dir.handle, &list, buffer.ptr, buffer.len, 0);
    if (rc < 0) return null;
    return @intCast(rc);
}

/// A later batch. `null` is a failure partway through a directory, which is
/// an error and not a reason to start again.
fn bulkNext(dir: Io.Dir, buffer: []u8) ?u32 {
    if (!bulk_supported) return null;
    var list = attr.list;
    const rc = getattrlistbulk(dir.handle, &list, buffer.ptr, buffer.len, 0);
    if (rc < 0) return null;
    return @intCast(rc);
}

fn rewind(dir: Io.Dir) void {
    if (!bulk_supported) return;
    _ = std.c.lseek(dir.handle, 0, std.c.SEEK.SET);
}

const Parsed = struct {
    /// How many bytes this entry occupies, which is how the next one is
    /// reached.
    length: usize,
    name: []const u8,
    /// `null` when the volume did not answer every attribute asked for, in
    /// which case the caller stats the name the ordinary way.
    item: ?Item,
};

/// A field read out of the packed group.
///
/// Every value in the buffer is aligned to four bytes, the eight-byte ones
/// included, so each is copied out rather than pointed at. A group shorter
/// than the field it claims to hold gives zero, and the length checks around
/// each call are what turn that into a refusal.
fn read(comptime T: type, bytes: []const u8) T {
    if (bytes.len < @sizeOf(T)) return 0;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

fn parseEntry(bytes: []const u8) ?Parsed {
    if (bytes.len < 4) return null;
    const length = read(u32, bytes);
    if (length < 24 or length > bytes.len) return null;
    const group = bytes[0..length];
    var at: usize = 4;

    // Which attributes this entry actually carries.
    if (at + 20 > length) return null;
    const returned_common = read(u32, group[at..]);
    const returned_file = read(u32, group[at + 12 ..]);
    at += 20;

    var name: []const u8 = &.{};
    var devid: u32 = 0;
    var objtype: u32 = 0;
    var mtime_sec: i64 = 0;
    var mtime_nsec: i64 = 0;
    var ctime_sec: i64 = 0;
    var ctime_nsec: i64 = 0;
    var uid: u32 = 0;
    var gid: u32 = 0;
    var mode: u32 = 0;
    var fileid: u64 = 0;
    var size: u64 = 0;

    if (returned_common & attr.cmn_name != 0) {
        if (at + 8 > length) return null;
        const data_offset = read(i32, group[at..]);
        const data_length = read(u32, group[at + 4 ..]);
        if (data_offset < 0 or data_length == 0) return null;
        const start = at + @as(usize, @intCast(data_offset));
        const end = start + data_length - 1; // the length counts the terminator
        if (end > group.len) return null;
        name = group[start..end];
        at += 8;
    } else return null;

    if (returned_common & attr.cmn_devid != 0) {
        if (at + 4 > length) return null;
        devid = read(u32, group[at..]);
        at += 4;
    }
    if (returned_common & attr.cmn_objtype != 0) {
        if (at + 4 > length) return null;
        objtype = read(u32, group[at..]);
        at += 4;
    }
    if (returned_common & attr.cmn_modtime != 0) {
        if (at + 16 > length) return null;
        mtime_sec = read(i64, group[at..]);
        mtime_nsec = read(i64, group[at + 8 ..]);
        at += 16;
    }
    if (returned_common & attr.cmn_chgtime != 0) {
        if (at + 16 > length) return null;
        ctime_sec = read(i64, group[at..]);
        ctime_nsec = read(i64, group[at + 8 ..]);
        at += 16;
    }
    if (returned_common & attr.cmn_ownerid != 0) {
        if (at + 4 > length) return null;
        uid = read(u32, group[at..]);
        at += 4;
    }
    if (returned_common & attr.cmn_grpid != 0) {
        if (at + 4 > length) return null;
        gid = read(u32, group[at..]);
        at += 4;
    }
    if (returned_common & attr.cmn_accessmask != 0) {
        if (at + 4 > length) return null;
        mode = read(u32, group[at..]);
        at += 4;
    }
    if (returned_common & attr.cmn_fileid != 0) {
        if (at + 8 > length) return null;
        fileid = read(u64, group[at..]);
        at += 8;
    }
    if (returned_file & attr.file_datalength != 0) {
        if (at + 8 > length) return null;
        size = read(u64, group[at..]);
        at += 8;
    }

    // Short of something asked for: the name is still good, and the caller
    // stats it rather than filling a field in from nothing. A directory is
    // the one expected case, because a data length is a file's attribute.
    const kind = vnodeKind(objtype);
    const short = returned_common & attr.common_required != attr.common_required or
        (kind != .directory and returned_file & attr.file_datalength == 0);
    if (short) return .{ .length = length, .name = name, .item = null };

    return .{
        .length = length,
        .name = name,
        .item = .{
            .name = name,
            .entry = .{
                .stat = .fromFull(.{
                    .mtime_ns = @as(i128, mtime_sec) * std.time.ns_per_s + mtime_nsec,
                    .ctime_ns = @as(i128, ctime_sec) * std.time.ns_per_s + ctime_nsec,
                    .size = size,
                    .inode = fileid,
                    .mode = mode,
                    .kind = kind,
                    .extra = .{ .dev = devid, .uid = uid, .gid = gid },
                }),
                .kind = kind,
                .executable = mode & 0o100 != 0,
            },
        },
    };
}

/// The vnode types, which is how macOS names a file's kind.
fn vnodeKind(objtype: u32) Io.File.Kind {
    return switch (objtype) {
        1 => .file,
        2 => .directory,
        3 => .block_device,
        4 => .character_device,
        5 => .sym_link,
        6 => .unix_domain_socket,
        7 => .named_pipe,
        else => .unknown,
    };
}

/// Which arm a walk over this directory would take. A benchmark says so in
/// its output; nothing in the package branches on it.
pub fn armFor(gpa: Allocator, io: Io, dir: Io.Dir) []const u8 {
    var scan = Scan.init(gpa, io, dir) catch return "unknown";
    defer scan.deinit();
    return if (scan.isBulk()) "getattrlistbulk" else "one stat per entry";
}

test "both arms describe a directory the same way" {
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
        try runnable.setPermissions(io, @enumFromInt(@as(std.posix.mode_t, 0o755)));
    }
    var has_link = true;
    dir.symLink(io, "plain.txt", "link", .{}) catch {
        has_link = false;
    };
    // A name long enough that the attribute reference points well past the
    // fixed part of its own entry.
    const long = "a-name-that-is-considerably-longer-than-the-others-in-this-directory";
    try dir.writeFile(io, .{ .sub_path = long, .data = "long\n" });

    // What the ordinary arm says, keyed by name.
    var expected: std.StringArrayHashMapUnmanaged(fs.Entry) = .empty;
    defer {
        for (expected.keys()) |k| gpa.free(k);
        expected.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const found = (try fs.statAt(io, dir, entry.name)).?;
        try expected.put(gpa, try gpa.dupe(u8, entry.name), found);
    }
    try std.testing.expect(expected.count() >= 6);

    var scan = try Scan.init(gpa, io, dir);
    defer scan.deinit();
    // Nothing is proved by comparing the ordinary arm with itself, so a
    // volume that refuses the batch call skips this rather than passing it.
    if (!scan.isBulk()) return error.SkipZigTest;
    var seen: usize = 0;
    while (try scan.next()) |item| {
        const want = expected.get(item.name) orelse {
            std.debug.print("the scan gave a name the ordinary read did not: {s}\n", .{item.name});
            return error.TestUnexpectedResult;
        };
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
        // A directory's data length is a file attribute and a directory has
        // none, so the batch reports zero there and nothing asks.
        if (want.kind != .directory) {
            try std.testing.expectEqual(want.stat.size, item.entry.stat.size);
        }
        seen += 1;
    }
    try std.testing.expectEqual(expected.count(), seen);
    if (has_link) try std.testing.expect(expected.contains("link"));
}

test "a scan of an empty directory gives nothing on either arm" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var scan = try Scan.init(gpa, io, tmp.dir);
    defer scan.deinit();
    try std.testing.expect((try scan.next()) == null);
    // And stays finished.
    try std.testing.expect((try scan.next()) == null);
}

test "a scan reads a directory larger than one batch" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Enough entries, with long enough names, that one sixty-four kilobyte
    // batch cannot hold them all, so the second call is exercised.
    const count = 900;
    for (0..count) |i| {
        var name: [128]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "entry-{d:0>4}-with-a-name-long-enough-to-fill-the-batch-buffer", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = n, .data = "x" });
    }

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var keys = names.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        names.deinit(gpa);
    }
    var scan = try Scan.init(gpa, io, tmp.dir);
    defer scan.deinit();
    while (try scan.next()) |item| {
        try std.testing.expectEqual(@as(u32, 1), item.entry.stat.size);
        try names.put(gpa, try gpa.dupe(u8, item.name), {});
    }
    try std.testing.expectEqual(@as(usize, count), names.count());

    // And the ordinary arm reads the same directory, name for name.
    var plain = Scan.initPlain(gpa, io, tmp.dir);
    defer plain.deinit();
    var plain_count: usize = 0;
    while (try plain.next()) |item| {
        try std.testing.expect(names.contains(item.name));
        plain_count += 1;
    }
    try std.testing.expectEqual(@as(usize, count), plain_count);
}

test "a scan can be taken twice over the same handle" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (0..5) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d}", .{i}), .data = "x" });
    }
    // A batch read walks the handle's own offset forward, so a second scan
    // over the same handle would see an empty directory if it did not put
    // the offset back. A working tree's root is scanned once per `addAll`.
    for (0..3) |_| {
        var scan = try Scan.init(gpa, io, tmp.dir);
        defer scan.deinit();
        var n: usize = 0;
        while (try scan.next()) |_| n += 1;
        try std.testing.expectEqual(@as(usize, 5), n);
    }
}
