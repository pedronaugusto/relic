//! pkt-line: the framing under git's wire protocol and its long-running
//! filter processes.
//!
//! A line is four hexadecimal digits giving its length, the four included,
//! then that many bytes less four. Three lengths below four carry no data and
//! mean something instead: `0000` ends a message (flush), `0001` separates a
//! command's sections in protocol v2 (delim), `0002` ends a stateless
//! response in protocol v2 (response end). `0003` is no line at all. A line
//! is at most 65520 bytes, so its data is at most 65516.
//!
//! What a line's data means — a trailing newline, a side-band byte, a
//! capability list after a NUL — belongs to whoever reads it. This file only
//! frames.

const std = @import("std");
const Io = std.Io;

/// The longest line, its four length digits included.
pub const max_line: usize = 65520;
/// The most data one line carries.
pub const max_data: usize = max_line - 4;

pub const Packet = union(enum) {
    /// `0000`: the end of a message.
    flush,
    /// `0001`: the end of a section inside a protocol v2 message.
    delim,
    /// `0002`: the end of a stateless protocol v2 response.
    response_end,
    /// A line's data. It lives in the reader's buffer until the next read.
    data: []const u8,
};

pub const ReadError = error{
    /// The length is not four hexadecimal digits, is `0003`, or is past
    /// `max_line`.
    BadPacket,
} || Io.Reader.Error;

/// Read one line. The reader's buffer must hold `max_line` bytes, because
/// the returned data is a view of it; a smaller buffer is a caller's error
/// and asserts. The end of the stream before a whole line is
/// `error.EndOfStream`.
pub fn read(r: *Io.Reader) ReadError!Packet {
    std.debug.assert(r.buffer.len >= max_line);
    const head = try r.takeArray(4);
    const len = parseLength(head) orelse return error.BadPacket;
    return switch (len) {
        0 => .flush,
        1 => .delim,
        2 => .response_end,
        3 => error.BadPacket,
        else => .{ .data = try r.take(len - 4) },
    };
}

/// The length four digits say, or null when they are not hexadecimal or
/// say more than `max_line`. Either case of digit is read, as git reads.
pub fn parseLength(head: *const [4]u8) ?usize {
    var len: usize = 0;
    for (head) |c| {
        const digit: usize = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        len = len * 16 + digit;
    }
    if (len > max_line) return null;
    return len;
}

pub const WriteError = error{
    /// The data is longer than `max_data`; the caller splits it.
    PacketTooLong,
} || Io.Writer.Error;

/// Write `data` as one line. Nothing is flushed.
pub fn write(w: *Io.Writer, data: []const u8) WriteError!void {
    if (data.len > max_data) return error.PacketTooLong;
    try writeLength(w, data.len + 4);
    try w.writeAll(data);
}

/// Write a line formatted in place, as git's `packet_write_fmt` does.
pub fn print(w: *Io.Writer, comptime fmt: []const u8, args: anytype) WriteError!void {
    const len = std.fmt.count(fmt, args);
    if (len > max_data) return error.PacketTooLong;
    try writeLength(w, len + 4);
    try w.print(fmt, args);
}

/// Write `0000`.
pub fn flush(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("0000");
}

/// Write `0001`.
pub fn delim(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("0001");
}

/// Write `0002`.
pub fn responseEnd(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("0002");
}

fn writeLength(w: *Io.Writer, len: usize) Io.Writer.Error!void {
    const digits = "0123456789abcdef";
    const head = [4]u8{
        digits[(len >> 12) & 0xf],
        digits[(len >> 8) & 0xf],
        digits[(len >> 4) & 0xf],
        digits[len & 0xf],
    };
    try w.writeAll(&head);
}

const testing = std.testing;
const testgit = @import("testgit.zig");

test "a message written is the message read" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, "command=ls-refs\n");
    try delim(&out.writer);
    try print(&out.writer, "ref-prefix {s}\n", .{"refs/heads/"});
    try write(&out.writer, "");
    try flush(&out.writer);
    try responseEnd(&out.writer);
    try testing.expectEqualStrings(
        "0014command=ls-refs\n0001001bref-prefix refs/heads/\n000400000002",
        out.written(),
    );

    var buffer: [max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(out.written());
    var in = fixed.limited(.unlimited, &buffer);
    try testing.expectEqualStrings("command=ls-refs\n", (try read(&in.interface)).data);
    try testing.expectEqual(Packet.delim, try read(&in.interface));
    try testing.expectEqualStrings("ref-prefix refs/heads/\n", (try read(&in.interface)).data);
    try testing.expectEqualStrings("", (try read(&in.interface)).data);
    try testing.expectEqual(Packet.flush, try read(&in.interface));
    try testing.expectEqual(Packet.response_end, try read(&in.interface));
    try testing.expectError(error.EndOfStream, read(&in.interface));
}

test "a length that is not a line is refused by name" {
    for ([_][]const u8{ "0003", "zzzz", "fff1", "12 4" }) |bytes| {
        var padded: [max_line]u8 = @splat('x');
        @memcpy(padded[0..4], bytes);
        var in: Io.Reader = .fixed(&padded);
        try testing.expectError(error.BadPacket, read(&in));
    }
    try testing.expectEqual(@as(?usize, 0xfff0), parseLength("FFF0"));
    try testing.expectEqual(@as(?usize, max_line), parseLength("fff0"));
}

test "data past the longest line is refused before a byte is written" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const long = try testing.allocator.alloc(u8, max_data + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(error.PacketTooLong, write(&out.writer, long));
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try write(&out.writer, long[0..max_data]);
    try testing.expectEqualStrings("fff0", out.written()[0..4]);
}

test "git's own advertisement reads as lines, then a flush" {
    const io = testing.io;
    const gpa = testing.allocator;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "hello\n");
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
    try repo.exec(io, &.{ "tag", "v1" });
    const head = try repo.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);

    const advertised = try repo.run(io, &.{ "upload-pack", "--advertise-refs", "." });
    defer gpa.free(advertised);

    var buffer: [max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(advertised);
    var in = fixed.limited(.unlimited, &buffer);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    while (true) {
        switch (try read(&in.interface)) {
            .flush => break,
            .data => |data| {
                // `<oid> <name>`, the first with its capabilities after a NUL
                const line = std.mem.trimEnd(u8, data, "\n");
                const end = std.mem.indexOfScalar(u8, line, 0) orelse line.len;
                try testing.expectEqualStrings(head, line[0..40]);
                try names.append(gpa, try gpa.dupe(u8, line[41..end]));
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectError(error.EndOfStream, read(&in.interface));
    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("HEAD", names.items[0]);
    try testing.expectEqualStrings("refs/heads/main", names.items[1]);
    try testing.expectEqualStrings("refs/tags/v1", names.items[2]);
}

test "fuzz: any bytes are lines or a named error" {
    try testing.fuzz({}, fuzzRead, .{});
}

fn fuzzRead(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [4096]u8 = undefined;
    const n = smith.slice(&scratch);
    var buffer: [max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(scratch[0..n]);
    var in = fixed.limited(.unlimited, &buffer);
    var count: usize = 0;
    while (count < 4096) : (count += 1) {
        const packet = read(&in.interface) catch |err| switch (err) {
            error.BadPacket, error.EndOfStream => return,
            else => return err,
        };
        if (packet == .data) try testing.expect(packet.data.len <= max_data);
    }
}
