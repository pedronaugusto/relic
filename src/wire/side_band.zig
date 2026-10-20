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
const shakedown = @import("shakedown");
const Io = std.Io;
const assert = std.debug.assert;

const pkt_line = @import("../codec.zig").pkt_line;
const progress_mod = @import("../report.zig").progress;
const color = @import("../config/color.zig");
const config_mod = @import("../config/config.zig");
const ctype = @import("../text.zig").ctype;

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
        // `pending` is a view of `in`'s buffer: a whole line must fit.
        assert(in.buffer.len >= pkt_line.max_line);
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
        const d: *Demux = @alignCast(@fieldParentPtr("interface", r)); // safe: this function is installed only on a Demux's interface
        while (true) {
            if (d.pending.len != 0) {
                const n = limit.minInt(d.pending.len);
                if (n == 0) return 0;
                const written = try w.write(d.pending[0..n]);
                d.pending = d.pending[written..];
                return written;
            }
            if (d.ended) return error.EndOfStream;
            const packet = pkt_line.read(d.in) catch |err| {
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
                        2 => if (d.progress) |p| emitRemote(p, data[1..]),
                        3 => {
                            const control: progress_mod.Control = if (d.progress) |p| p.remote_control else .color;
                            d.message_len = progress_mod.sanitize(data[1..], control, &d.message_buffer).written;
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

/// The colours git writes a remote's keywords in: git's defaults under
/// `color.remote.<keyword>`.
pub const RemoteColors = struct {
    hint: color.Color = color.yellow,
    warning: color.Color = color.bold_yellow,
    success: color.Color = color.bold_green,
    @"error": color.Color = color.bold_red,

    /// The colours `output` asks for, as git's `use_sideband_colors`
    /// reads them: `color.remote`, else `color.ui`, else `auto`, each by
    /// its last value, one with no value passed over; `null` where git
    /// writes the remote's text without colour. A keyword's colour is its
    /// last value, one that does not parse or has none leaving git's
    /// default, as git's does after saying so.
    pub fn configured(config: ?*const config_mod.Config, output: color.Output) color.Error!?RemoteColors {
        const when: color.When = output.asked orelse when: {
            const c = config orelse break :when .auto;
            for ([_][]const u8{ "color.remote", "color.ui" }) |name| {
                const entry = c.find(name) orelse continue;
                break :when try color.parseWhen(entry.value orelse continue);
            }
            break :when .auto;
        };
        const want = switch (when) {
            .never => false,
            .always => true,
            .auto => output.terminal,
        };
        if (!want) return null;
        var out: RemoteColors = .{};
        const c = config orelse return out;
        inline for (@typeInfo(RemoteColors).@"struct".field_names) |name| {
            if (c.find("color.remote." ++ name)) |entry| if (entry.value) |value| {
                @field(out, name) = color.parse(value) catch @field(out, name);
            };
        }
        return out;
    }

    /// The sequences a `Progress` carries, borrowed from `c`.
    pub fn keywords(c: *const RemoteColors) progress_mod.Keywords {
        return .{ .hint = c.hint.bytes(), .warning = c.warning.bytes(), .success = c.success.bytes(), .@"error" = c.@"error".bytes() };
    }
};

/// The remote's text as the caller is handed it: gathered into a buffer
/// and reported when it fills or the text ends.
const Shown = struct {
    p: progress_mod.Progress,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn flush(s: *Shown) void {
        if (s.len != 0) s.p.report(s.p.context, .{ .remote = s.buf[0..s.len] });
        s.len = 0;
    }

    /// Bytes as they are; fewer than the buffer holds.
    fn put(s: *Shown, bytes: []const u8) void {
        if (s.len + bytes.len > s.buf.len) s.flush();
        @memcpy(s.buf[s.len..][0..bytes.len], bytes);
        s.len += bytes.len;
    }

    /// Text with its control characters made visible.
    fn sanitized(s: *Shown, text: []const u8) void {
        var rest = text;
        while (rest.len != 0) {
            const part = progress_mod.sanitize(rest, s.p.remote_control, s.buf[s.len..]);
            s.len += part.written;
            rest = rest[part.read..];
            if (part.read == 0 or rest.len != 0) s.flush();
        }
    }
};

/// Hand the caller the remote's progress text with its control characters
/// made visible, in as many events as the shown text takes; in colour, a
/// keyword at the start of each line in its colour, as git's
/// `demultiplex_sideband` writes it: each line of the packet, and what
/// follows the last line ending, is such a start.
fn emitRemote(p: progress_mod.Progress, text: []const u8) void {
    var s: Shown = .{ .p = p };
    defer s.flush();
    const keywords = p.remote_keywords orelse return s.sanitized(text);
    // git reads the packet as a C string
    var rest = text[0 .. std.mem.findScalar(u8, text, 0) orelse text.len];
    while (rest.len != 0) {
        const brk = std.mem.findAny(u8, rest, "\n\r") orelse rest.len;
        if (brk != 0) colorize(&s, keywords, rest[0..brk]);
        if (brk == rest.len) break;
        s.put(rest[brk..][0..1]);
        rest = rest[brk + 1 ..];
    }
}

/// git's `maybe_colorize_sideband` for one line: its leading spaces, then
/// a keyword git knows, matched without regard to case and not followed by
/// a letter or digit, in its colour; the rest made visible.
fn colorize(s: *Shown, keywords: progress_mod.Keywords, line_in: []const u8) void {
    var line = line_in;
    var lead: usize = 0;
    while (lead < line.len and ctype.isSpace(line[lead])) lead += 1;
    s.put(line[0..lead]);
    line = line[lead..];
    inline for (.{ "hint", "warning", "success", "error" }) |word| {
        if (line.len >= word.len and std.ascii.eqlIgnoreCase(line[0..word.len], word) and
            (line.len == word.len or !std.ascii.isAlphanumeric(line[word.len])))
        {
            s.put(@field(keywords, word));
            s.put(line[0..word.len]);
            s.put(color.reset);
            return s.sanitized(line[word.len..]);
        }
    }
    s.sanitized(line);
}

const testing = std.testing;

fn band(w: *Io.Writer, channel: u8, text: []const u8) !void {
    var line: [256]u8 = undefined;
    line[0] = channel;
    @memcpy(line[1..][0..text.len], text);
    try pkt_line.write(w, line[0 .. text.len + 1]);
}

test "data comes through, progress goes to the caller, a flush ends it" {
    var wire: Io.Writer.Allocating = .init(testing.allocator);
    defer wire.deinit();
    try band(&wire.writer, 1, "PACK");
    try band(&wire.writer, 2, "Counting objects: 1\r");
    try band(&wire.writer, 1, "data");
    try pkt_line.flush(&wire.writer);

    var heard: std.ArrayList(u8) = .empty;
    defer heard.deinit(testing.allocator);
    const Ctx = struct {
        fn report(context: ?*anyopaque, event: progress_mod.Event) void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(context.?));
            list.appendSlice(testing.allocator, event.remote) catch @panic("OOM");
        }
    };
    var buffer: [pkt_line.max_line]u8 = undefined;
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
    var buffer: [pkt_line.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    var demux: Demux = .init(&in.interface, &.{}, null);
    var out: [64]u8 = undefined;
    try testing.expectError(error.ReadFailed, demux.interface.readSliceShort(&out));
    try testing.expectEqual(Error.RemoteError, demux.err.?);
    try testing.expectEqualStrings("upload-pack: not our ref", demux.message());
}

test "fuzz: any bytes are data or a named failure" {
    try shakedown.check(testing.allocator, {}, fuzzDemux, .{});
}

fn fuzzDemux(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    var buffer: [pkt_line.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(input);
    var in = fixed.limited(.unlimited, &buffer);
    var demux: Demux = .init(&in.interface, &.{}, null);
    var out: [4096]u8 = undefined;
    _ = demux.interface.readSliceShort(&out) catch {
        try testing.expect(demux.err != null);
    };
}
