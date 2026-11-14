//! pkt-line's documented guarantees as properties, each checked against a
//! definition written from the doc, not only "no crash": a length is four
//! hexadecimal digits of either case up to `max_line`; a stream framed by
//! hand, git's way, reads back line for line, and cut anywhere it gives the
//! whole lines before the cut and then `EndOfStream`; and `write` frames
//! data so it reads back, refusing data past `max_data` before a byte.

const std = @import("std");
const shakedown = @import("shakedown");
const pkt_line = @import("pkt_line.zig");
const testing = std.testing;
const gen = shakedown.gen;
const Io = std.Io;

const hex_bytes = "0123456789abcdefABCDEF" ++ "gG xX-+\x00\xff";

fn anyLength(_: void, case: *shakedown.Case) !void {
    var head: [4]u8 = undefined;
    for (&head) |*c| c.* = if (gen.boolean(case.source)) gen.oneOf(case.source, u8, hex_bytes) else gen.int(case.source, u8);
    // "four hexadecimal digits ... Either case of digit is read", "null
    // when they are not hexadecimal or say more than max_line".
    var value: usize = 0;
    var hex = true;
    for (head) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch {
            hex = false;
            break;
        };
        value = value * 16 + digit;
    }
    const want: ?usize = if (hex and value <= pkt_line.max_line) value else null;
    try testing.expectEqual(want, pkt_line.parseLength(&head));
}

test "property: a pkt-line length is four hexadecimal digits of either case, up to max_line" {
    try shakedown.check(testing.allocator, {}, anyLength, .{ .cases = 20000, .seed = 0x9c1 });
}

const Sent = union(enum) { flush, delim, response_end, data: []const u8 };

/// `len` as four hex digits, in the case drawn: git writes lower case and
/// reads either.
fn hexLength(s: *shakedown.Source, len: usize, out: *[4]u8) void {
    _ = if (gen.boolean(s)) std.fmt.bufPrint(out, "{x:0>4}", .{len}) catch unreachable else std.fmt.bufPrint(out, "{X:0>4}", .{len}) catch unreachable; // four digits hold every line's length
}

fn anyStream(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    var sent: [8]Sent = undefined;
    var ends: [8]usize = undefined;
    var payloads: [8][]u8 = undefined;
    var owned: usize = 0;
    defer for (payloads[0..owned]) |p| gpa.free(p);
    const n = gen.intRange(case.source, usize, 0, sent.len);
    for (sent[0..n], ends[0..n]) |*packet, *end| {
        var head: [4]u8 = undefined;
        switch (gen.intRange(case.source, u8, 0, 5)) {
            0 => {
                packet.* = .flush;
                try wire.appendSlice(gpa, "0000");
            },
            1 => {
                packet.* = .delim;
                try wire.appendSlice(gpa, "0001");
            },
            2 => {
                packet.* = .response_end;
                try wire.appendSlice(gpa, "0002");
            },
            else => {
                // Mostly short; now and then the longest a line carries.
                const len = if (gen.intRange(case.source, u8, 0, 15) == 0) pkt_line.max_data else gen.intRange(case.source, usize, 0, 48);
                const data = try gpa.alloc(u8, len);
                payloads[owned] = data;
                owned += 1;
                case.source.bytes(data);
                packet.* = .{ .data = data };
                hexLength(case.source, len + 4, &head);
                try wire.appendSlice(gpa, &head);
                try wire.appendSlice(gpa, data);
            },
        }
        end.* = wire.items.len;
    }
    const cut = if (gen.boolean(case.source)) wire.items.len else gen.intRange(case.source, usize, 0, wire.items.len);
    const buffer = try gpa.alloc(u8, pkt_line.max_line);
    defer gpa.free(buffer);
    var fixed: Io.Reader = .fixed(wire.items[0..cut]);
    var in = fixed.limited(.unlimited, buffer);
    for (sent[0..n], ends[0..n]) |packet, end| {
        // "The end of the stream before a whole line is error.EndOfStream."
        if (end > cut) return testing.expectError(error.EndOfStream, pkt_line.read(&in.interface));
        const got = try pkt_line.read(&in.interface);
        switch (packet) {
            .data => |data| try testing.expectEqualSlices(u8, data, got.data.readForParse()),
            else => try testing.expectEqualStrings(@tagName(packet), @tagName(got)),
        }
    }
    try testing.expectError(error.EndOfStream, pkt_line.read(&in.interface));
}

test "property: a stream framed git's way reads back line for line, and cut anywhere ends after its whole lines" {
    try shakedown.check(testing.allocator, {}, anyStream, .{ .cases = 4000, .seed = 0x9c2 });
}

fn anyWrite(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    const len = switch (gen.intRange(case.source, u8, 0, 7)) {
        0 => pkt_line.max_data + gen.intRange(case.source, usize, 0, 2),
        1 => pkt_line.max_data - gen.intRange(case.source, usize, 0, 2),
        else => gen.intRange(case.source, usize, 0, 64),
    };
    const data = try gpa.alloc(u8, len);
    defer gpa.free(data);
    case.source.bytes(data);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    pkt_line.write(&out.writer, data) catch |err| {
        // Refused past max_data, and nothing written.
        try testing.expectEqual(error.PacketTooLong, err);
        try testing.expect(len > pkt_line.max_data);
        try testing.expectEqual(@as(usize, 0), out.written().len);
        return;
    };
    try testing.expect(len <= pkt_line.max_data);
    // Four hex digits giving the length, the four included, then the data.
    const written = out.written();
    try testing.expectEqual(len + 4, try std.fmt.parseUnsigned(usize, written[0..4], 16));
    try testing.expectEqualSlices(u8, data, written[4..]);
}

test "property: write frames data as a line of its length, and refuses data past max_data before a byte" {
    try shakedown.check(testing.allocator, {}, anyWrite, .{ .cases = 2000, .seed = 0x9c3 });
}
