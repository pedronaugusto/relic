//! The side-band: several streams over one, a pkt-line at a time.
//!
//! Once a pack starts, the server multiplexes it with its progress messages
//! and, if it fails, its last words. Each pkt-line's first byte says which:
//! 1 is data, 2 is progress text for a person, 3 is a fatal error. A flush
//! ends the whole. `Demux` reads the lines and hands out only the data as a
//! stream of its own, so the pack reader underneath never sees the framing;
//! progress goes to the caller's `Progress`, and an error ends the stream
//! with the server's message kept.

const std = @import("std");
const Io = std.Io;

const pktline = @import("pktline.zig");
const progress_mod = @import("progress.zig");

/// Why a side-band stream stopped.
pub const Error = error{
    /// Channel 3: the server stopped, and `Demux.message` says why.
    RemoteError,
    /// A line on no channel, or a length that is not a pkt-line.
    BadSideband,
    /// The stream ended before the flush that ends a side-band.
    RemoteHungUp,
    /// The stream underneath failed.
    ReadFailed,
};

/// Channel 1 of a side-band, as a reader.
pub const Demux = struct {
    in: *Io.Reader,
    progress: ?progress_mod.Progress,
    interface: Io.Reader,
    /// Channel 1 bytes of the current line not yet handed out. They are a
    /// view of `in`'s buffer, which holds until the next line is read.
    pending: []const u8 = "",
    ended: bool = false,
    /// Set when the reader said `ReadFailed`: why.
    err: ?Error = null,
    /// The server's channel 3 text, when there was one.
    message_buffer: [256]u8 = undefined,
    message_len: usize = 0,

    /// A demultiplexer over `in`, whose buffer must hold a whole pkt-line.
    /// `buffer` is the data stream's own, and may be empty.
    pub fn init(in: *Io.Reader, buffer: []u8, progress: ?progress_mod.Progress) Demux {
        return .{
            .in = in,
            .progress = progress,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// What the server said on channel 3, trimmed.
    pub fn message(d: *const Demux) []const u8 {
        return std.mem.trim(u8, d.message_buffer[0..d.message_len], " \t\r\n");
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const d: *Demux = @alignCast(@fieldParentPtr("interface", r));
        while (true) {
            if (d.pending.len != 0) {
                const n = limit.minInt(d.pending.len);
                if (n == 0) return 0;
                const written = try w.write(d.pending[0..n]);
                d.pending = d.pending[written..];
                return written;
            }
            if (d.ended) return error.EndOfStream;
            const packet = pktline.read(d.in) catch |err| {
                d.err = switch (err) {
                    error.BadPacket => error.BadSideband,
                    error.EndOfStream => error.RemoteHungUp,
                    error.ReadFailed => error.ReadFailed,
                };
                return error.ReadFailed;
            };
            switch (packet) {
                .flush => {
                    d.ended = true;
                    return error.EndOfStream;
                },
                .delim, .response_end => {
                    d.err = error.BadSideband;
                    return error.ReadFailed;
                },
                .data => |data| {
                    if (data.len == 0) {
                        d.err = error.BadSideband;
                        return error.ReadFailed;
                    }
                    switch (data[0]) {
                        1 => d.pending = data[1..],
                        2 => progress_mod.Progress.emit(d.progress, .{ .remote = data[1..] }),
                        3 => {
                            const text = data[1..];
                            d.message_len = @min(text.len, d.message_buffer.len);
                            @memcpy(d.message_buffer[0..d.message_len], text[0..d.message_len]);
                            d.err = error.RemoteError;
                            return error.ReadFailed;
                        },
                        else => {
                            d.err = error.BadSideband;
                            return error.ReadFailed;
                        },
                    }
                },
            }
        }
    }
};

const testing = std.testing;

fn band(w: *Io.Writer, channel: u8, text: []const u8) !void {
    var line: [256]u8 = undefined;
    line[0] = channel;
    @memcpy(line[1..][0..text.len], text);
    try pktline.write(w, line[0 .. text.len + 1]);
}

test "data comes through, progress goes to the caller, a flush ends it" {
    var wire: Io.Writer.Allocating = .init(testing.allocator);
    defer wire.deinit();
    try band(&wire.writer, 1, "PACK");
    try band(&wire.writer, 2, "Counting objects: 1\r");
    try band(&wire.writer, 1, "data");
    try pktline.flush(&wire.writer);

    var heard: std.ArrayList(u8) = .empty;
    defer heard.deinit(testing.allocator);
    const Ctx = struct {
        fn report(context: ?*anyopaque, event: progress_mod.Event) void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(context.?));
            list.appendSlice(testing.allocator, event.remote) catch {};
        }
    };
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    var demux: Demux = .init(&in.interface, &.{}, .{ .context = &heard, .report = Ctx.report });
    var out: [64]u8 = undefined;
    const n = try demux.interface.readSliceShort(&out);
    try testing.expectEqualStrings("PACKdata", out[0..n]);
    try testing.expectEqualStrings("Counting objects: 1\r", heard.items);
}

test "the server's fatal error ends the stream and is kept" {
    var wire: Io.Writer.Allocating = .init(testing.allocator);
    defer wire.deinit();
    try band(&wire.writer, 1, "PA");
    try band(&wire.writer, 3, "upload-pack: not our ref\n");
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    var demux: Demux = .init(&in.interface, &.{}, null);
    var out: [64]u8 = undefined;
    try testing.expectError(error.ReadFailed, demux.interface.readSliceShort(&out));
    try testing.expectEqual(Error.RemoteError, demux.err.?);
    try testing.expectEqualStrings("upload-pack: not our ref", demux.message());
}

test "fuzz: any bytes are data or a named failure" {
    try testing.fuzz({}, fuzzDemux, .{});
}

fn fuzzDemux(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(input);
    var in = fixed.limited(.unlimited, &buffer);
    var demux: Demux = .init(&in.interface, &.{}, null);
    var out: [4096]u8 = undefined;
    _ = demux.interface.readSliceShort(&out) catch {
        try testing.expect(demux.err != null);
    };
}
