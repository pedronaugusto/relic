//! The file layer's input seam: where bytes from outside enter relic
//! through the file layer. A file's contents (a whole file, one a stat has
//! measured, one holding a secret), a lock's pid record and a link's target
//! are read here and nowhere else in `fs`; each read is held to a limit,
//! the one its caller names or the one named here, and what reads the
//! bytes these hand back parses them as the input they are.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");

/// The most of a lock's pid file git reads (`read_lock_pid`'s 32 bytes):
/// `pid <n>` and a newline.
pub const pid_record_max = 32;

/// `name` in `dir`, a lock's pid record, at most `pid_record_max` bytes,
/// in `buffer`.
pub fn pidRecord(io: Io, dir: Io.Dir, name: []const u8, buffer: *[pid_record_max]u8) Io.Dir.ReadFileError![]u8 {
    return dir.readFile(io, name, buffer);
}

/// The target of the link `sub_path` in `dir`, at most a path's length, in
/// `buffer`.
pub fn linkTarget(io: Io, dir: Io.Dir, sub_path: []const u8, buffer: *[Io.Dir.max_path_bytes]u8) Io.Dir.ReadLinkError![]u8 {
    return buffer[0..try dir.readLink(io, sub_path, buffer)];
}

/// Errors from reading a file whose length is already known.
pub const ReadSizedError = Io.File.OpenError || Io.File.ReadPositionalError ||
    aegis.own.ReadFileError || Allocator.Error;

pub const ReadSizedOptions = struct { size: u64, max_bytes: usize };

/// Read a file a stat has already measured.
///
/// The walk that found the file already knows how long it is, so the `fstat`
/// a general read does to find that out is one syscall per file that a cold
/// pass over a working tree pays for nothing. The size is a hint and not a
/// promise: a file that shrank gives back what is there, and a file that grew
/// is read again the general way.
///
/// The bytes are the caller's.
pub fn readFileSized(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    options: ReadSizedOptions,
) ReadSizedError![]u8 {
    const size = options.size;
    const max_bytes = options.max_bytes;
    if (size > max_bytes) return error.StreamTooLong;
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, @intCast(size));
    {
        errdefer gpa.free(buf);
        const n = try file.readPositionalAll(io, buf, 0);
        if (n < buf.len) return gpa.realloc(buf, n);
        // The file is at least as long as the stat said. One byte past the end
        // says whether it is longer, which is the only case this cannot finish.
        var probe: [1]u8 = undefined;
        if (try file.readPositional(io, &.{&probe}, size) == 0) return buf;
    }
    gpa.free(buf);
    return aegis.own.readFile(io, dir, sub_path, gpa, aegis.units.Bytes(u64).fromRaw(max_bytes));
}

/// Read a whole file, or `null` if it is not there.
///
/// The returned bytes are the caller's. `max_bytes` bounds the allocation, so
/// a hostile or corrupt path cannot ask for the address space.
pub fn readFileAlloc(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
) (aegis.own.ReadFileError)!?[]u8 {
    return aegis.own.readFile(io, dir, sub_path, gpa, aegis.units.Bytes(u64).fromRaw(max_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => |e| return e,
    };
}

/// `readFileAlloc` for a file that holds a secret (`.netrc`, a private
/// key): read into an owner that wipes its bytes when let go, growing
/// through `reserve`, which wipes what it leaves, so no copy is freed
/// unwiped on the way as a growing buffer's would be.
pub fn readSecretFile(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
) (aegis.own.ReadFileError)!?aegis.SecretBytes {
    var file = dir.openFile(io, sub_path, .{ .allow_directory = builtin.os.tag != .windows }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => |e| return e,
    };
    defer file.close(io);
    // The length is a first guess: the file may change as it is read.
    const length = file.length(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => 0,
    };
    const guess = std.math.cast(usize, length) orelse max_bytes;
    var secret = try aegis.SecretBytes.init(gpa, @min(guess, max_bytes) + 1);
    errdefer secret.deinit(gpa);
    var at: Reading = .offset;
    while (true) {
        const have = secret.len();
        if (have == secret.capacity()) {
            if (have > max_bytes) return error.StreamTooLong;
            try secret.reserve(gpa, @min(have *| 2, max_bytes + 1));
        }
        secret.resizeWithinCapacity(secret.capacity()) catch
            aegis.assert.never("a length of the capacity itself is within it");
        const read = at.read(io, file, secret.exposeMut()[have..], have) catch |err| switch (err) {
            error.IsDir => {
                secret.deinit(gpa);
                return null;
            },
            else => |e| return e,
        };
        secret.resizeWithinCapacity(have + (read orelse 0)) catch
            aegis.assert.never("a read fills no more than the room it was given, which ends at the capacity");
        if (read == null) break;
    }
    if (secret.len() > max_bytes) return error.StreamTooLong;
    return secret;
}

/// How a whole-file read reads: at an offset, as `readFileAlloc` (aegis's
/// `own.readFile`) reads, so the file's shared position is no part of it;
/// a file with no offsets (a pipe) as a stream.
const Reading = enum {
    offset,
    stream,

    /// Bytes read into `dest` at `pos`, or null at the end. At an offset a
    /// read of no bytes is the end; a streamed read may give none short of
    /// it (std allows "including 0", and reactor's io_uring answers so for
    /// an interrupted read), and only `EndOfStream` ends it.
    fn read(at: *Reading, io: Io, file: Io.File, dest: []u8, pos: usize) aegis.own.ReadFileError!?usize {
        while (true) switch (at.*) {
            .offset => {
                const n = file.readPositional(io, &.{dest}, pos) catch |err| switch (err) {
                    error.Unseekable => {
                        at.* = .stream;
                        continue;
                    },
                    else => |e| return e,
                };
                return if (n == 0) null else n;
            },
            .stream => return file.readStreaming(io, &.{dest}) catch |err| switch (err) {
                error.EndOfStream => null,
                else => |e| e,
            },
        };
    }
};

test "a sized read gives the whole file whatever the size said" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "f", .data = "twelve bytes" });

    // The size a stat reported.
    const exact = try readFileSized(gpa, io, dir, "f", .{ .size = 12, .max_bytes = 1 << 20 });
    defer gpa.free(exact);
    try std.testing.expectEqualStrings("twelve bytes", exact);

    // A file that grew after the stat: the read is started again rather than
    // cut short at the length the stat gave.
    const grown = try readFileSized(gpa, io, dir, "f", .{ .size = 4, .max_bytes = 1 << 20 });
    defer gpa.free(grown);
    try std.testing.expectEqualStrings("twelve bytes", grown);

    // A file that shrank: what is there is what comes back.
    const shrunk = try readFileSized(gpa, io, dir, "f", .{ .size = 64, .max_bytes = 1 << 20 });
    defer gpa.free(shrunk);
    try std.testing.expectEqualStrings("twelve bytes", shrunk);

    const empty = try readFileSized(gpa, io, dir, "f", .{ .size = 0, .max_bytes = 1 << 20 });
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("twelve bytes", empty);

    try std.testing.expectError(error.StreamTooLong, readFileSized(gpa, io, dir, "f", .{ .size = 12, .max_bytes = 4 }));
}

test "a secret file is read whole into its owner, and refused past its limit as readFileAlloc refuses it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "f", .data = "twelve bytes" });
    try dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try dir.createDirPath(io, "d");

    var whole = (try readSecretFile(gpa, io, dir, "f", 1 << 20)).?;
    defer whole.deinit(gpa);
    try std.testing.expectEqualStrings("twelve bytes", whole.expose());

    var at_limit = (try readSecretFile(gpa, io, dir, "f", 12)).?;
    defer at_limit.deinit(gpa);
    try std.testing.expectEqualStrings("twelve bytes", at_limit.expose());

    var empty = (try readSecretFile(gpa, io, dir, "empty", 1 << 20)).?;
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.len());

    try std.testing.expectError(error.StreamTooLong, readSecretFile(gpa, io, dir, "f", 4));
    try std.testing.expect(try readSecretFile(gpa, io, dir, "missing", 1 << 20) == null);
    try std.testing.expect(try readSecretFile(gpa, io, dir, "d", 1 << 20) == null);
}

/// An `Io` with no offsets to read at, as a pipe has, whose first streaming
/// read gives five bytes and whose second gives none, short of the end: what
/// reactor's io_uring backend answers for an interrupted read, and what
/// `readStreaming` allows ("including 0").
const ZeroMidStream = @import("shakedown").Layer(struct { reads: u32 = 0 }, .{ .operate = ZeroMidStreamOps.operate, .fileReadPositional = ZeroMidStreamOps.unseekable });
const ZeroMidStreamOps = struct {
    fn unseekable(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        _ = .{ userdata, file, data, offset };
        return error.Unseekable;
    }

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const l = ZeroMidStream.of(userdata);
        if (operation == .file_read_streaming) {
            l.state.reads += 1;
            switch (l.state.reads) {
                1 => {
                    var short = operation;
                    const first = operation.file_read_streaming.data[0];
                    short.file_read_streaming.data = &.{first[0..@min(first.len, 5)]};
                    return l.base.vtable.operate(l.base.userdata, short);
                },
                2 => return .{ .file_read_streaming = 0 },
                else => {},
            }
        }
        return l.base.vtable.operate(l.base.userdata, operation);
    }
};

test "a secret file is read on past a streamed read that gives no bytes short of the end" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "twelve bytes" });

    var secret: ZeroMidStream = .init(std.testing.io, .{});
    var kept = (try readSecretFile(gpa, secret.io(), tmp.dir, "f", 1 << 20)).?;
    defer kept.deinit(gpa);
    try std.testing.expectEqualStrings("twelve bytes", kept.expose());
    try std.testing.expect(secret.state.reads > 2);
}

test "sized read releases its hint allocation when a grown file exceeds the limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "grown", .data = "twelve bytes" });
    try std.testing.expectError(error.StreamTooLong, readFileSized(std.testing.allocator, std.testing.io, tmp.dir, "grown", .{ .size = 1, .max_bytes = 4 }));
}
