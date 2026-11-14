//! The side band's documented guarantees as properties, each checked
//! against a definition written from the doc, not only "no crash": `Demux`
//! hands out channel 1's bytes as they were sent and nothing else, a flush
//! ends it, channel 3 is `RemoteError` with its text kept, a line on no
//! channel is `BadSideband`, and a stream that ends before its flush is
//! `RemoteHungUp`; `send` cuts bytes into packets of the band's length, on
//! the channel asked, that join back to the bytes, and writes nothing for
//! no bytes.

const std = @import("std");
const shakedown = @import("shakedown");
const side_band = @import("side_band.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const testing = std.testing;
const gen = shakedown.gen;
const Io = std.Io;

fn line(gpa: std.mem.Allocator, wire: *std.ArrayList(u8), payload: []const u8) !void {
    var head: [4]u8 = undefined;
    _ = try std.fmt.bufPrint(&head, "{x:0>4}", .{payload.len + 4});
    try wire.appendSlice(gpa, &head);
    try wire.appendSlice(gpa, payload);
}

fn anyBand(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    // What the stream must end as, decided as it is written: the first
    // packet that is not channel 1 or 2 decides it, else its flush or the
    // lack of one.
    var outcome: ?side_band.Error = null;
    var ended = false;
    var message: [40]u8 = undefined;
    var message_len: usize = 0;
    for (0..gen.intRange(case.source, usize, 0, 6)) |_| {
        var payload: [48]u8 = undefined;
        const kind = gen.intRange(case.source, u8, 0, 9);
        const body = payload[1..][0..gen.intRange(case.source, usize, 0, 40)];
        switch (kind) {
            0...3 => {
                payload[0] = 1;
                case.source.bytes(body);
                try line(gpa, &wire, payload[0 .. body.len + 1]);
                if (outcome == null and !ended) try data.appendSlice(gpa, body);
            },
            4, 5 => {
                payload[0] = 2;
                case.source.bytes(body);
                try line(gpa, &wire, payload[0 .. body.len + 1]);
            },
            6 => {
                // Last words of letters and spaces, which are shown as they are.
                payload[0] = 3;
                for (body) |*c| c.* = gen.oneOf(case.source, u8, "abc xyz:");
                try line(gpa, &wire, payload[0 .. body.len + 1]);
                if (outcome == null and !ended) {
                    outcome = error.RemoteError;
                    const kept = std.mem.trim(u8, body, " \t\r\n");
                    @memcpy(message[0..kept.len], kept);
                    message_len = kept.len;
                }
            },
            7 => {
                // No channel: 0, past 3, or an empty line with no byte at all.
                const channel = gen.oneOf(case.source, ?u8, &[_]?u8{ null, 0, 4, 255 });
                if (channel) |c| {
                    payload[0] = c;
                    case.source.bytes(body);
                    try line(gpa, &wire, payload[0 .. body.len + 1]);
                } else try line(gpa, &wire, "");
                if (outcome == null and !ended) outcome = error.BadSideband;
            },
            8 => {
                try wire.appendSlice(gpa, gen.oneOf(case.source, []const u8, &.{ "0001", "0002" }));
                if (outcome == null and !ended) outcome = error.BadSideband;
            },
            else => {
                try wire.appendSlice(gpa, "0000");
                if (outcome == null) ended = true;
            },
        }
    }
    if (outcome == null and !ended) outcome = error.RemoteHungUp;

    const buffer = try gpa.alloc(u8, pkt_line.max_line);
    defer gpa.free(buffer);
    var fixed: Io.Reader = .fixed(wire.items);
    var in = fixed.limited(.unlimited, buffer);
    var demux: side_band.Demux = .init(&in.interface, &.{}, null);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const result = demux.interface.streamRemaining(&out.writer);
    // Channel 1's bytes, as sent, up to what ends the stream.
    try testing.expectEqualSlices(u8, data.items, out.written());
    if (outcome) |err| {
        try testing.expectError(error.ReadFailed, result);
        try testing.expectEqual(err, demux.err.?);
        if (err == error.RemoteError) try testing.expectEqualStrings(message[0..message_len], demux.message());
    } else {
        _ = try result;
        try testing.expectEqual(null, demux.err);
    }
}

test "property: a side band hands out channel 1 as sent, ends at its flush, and names what else stops it" {
    try shakedown.check(testing.allocator, {}, anyBand, .{ .cases = 20000, .seed = 0x5b1 });
}

fn anySend(_: void, case: *shakedown.Case) !void {
    const gpa = testing.allocator;
    const framing = gen.oneOf(case.source, side_band.Band, &.{ .small, .large });
    const room: usize = switch (framing) {
        .small => 1000 - 5,
        .large => pkt_line.max_data - 1,
        .none => unreachable,
    };
    const channel = gen.intRange(case.source, u8, 1, 3);
    const len = switch (gen.intRange(case.source, u8, 0, 7)) {
        0 => room * gen.intRange(case.source, usize, 1, 2) + gen.intRange(case.source, usize, 0, 2),
        1 => room - gen.intRange(case.source, usize, 0, 1),
        else => gen.intRange(case.source, usize, 0, 2500),
    };
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    case.source.bytes(bytes);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try side_band.send(&out.writer, framing, channel, bytes);
    // Read back by hand: each packet four hex digits, the channel, then up
    // to the band's room; all but the last full; together the bytes.
    var rest = out.written();
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    while (rest.len != 0) {
        const size = try std.fmt.parseUnsigned(usize, rest[0..4], 16);
        try testing.expect(size >= 6 and size - 5 <= room);
        try testing.expectEqual(channel, rest[4]);
        try joined.appendSlice(gpa, rest[5..size]);
        rest = rest[size..];
        if (rest.len != 0) try testing.expectEqual(room, size - 5);
    }
    try testing.expectEqualSlices(u8, bytes, joined.items);
}

test "property: send cuts bytes into packets of the band's length on the channel asked, and writes nothing for none" {
    try shakedown.check(testing.allocator, {}, anySend, .{ .cases = 4000, .seed = 0x5b2 });
}
