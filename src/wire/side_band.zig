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
const urlmatch = @import("../text.zig").urlmatch;
const Allocator = std.mem.Allocator;

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

    /// What the server said on channel 3, trimmed: its control characters
    /// made visible and, in colour, its keyword in its colour, as git's
    /// `demultiplex_sideband` writes it.
    pub fn message(d: *const Demux) []const u8 {
        return std.mem.trim(u8, d.message_buffer[0..d.message_len], " \t\r\n");
    }

    /// The server's last words, as much of them as `message_buffer` holds.
    fn keepMessage(d: *Demux, text: []const u8) void {
        const control: progress_mod.Control = if (d.progress) |p| p.remote_control else .{};
        const keywords: ?progress_mod.Keywords = if (d.progress) |p| p.remote_keywords else null;
        var s: Shown = .{ .control = control, .buf = &d.message_buffer };
        // git reads the packet as a C string, and the message as one line
        const line = text[0 .. std.mem.findScalar(u8, text, 0) orelse text.len];
        if (keywords) |k| colorize(&s, k, line) else s.sanitized(line);
        d.message_len = s.len;
    }

    /// What one packet on the side band carries, as git's
    /// `demultiplex_sideband` takes it: channel 1's bytes, or `null` once
    /// channel 2's progress has gone to `progress`. Channel 3 is
    /// `error.RemoteError`, its text kept for `message`. A response read
    /// under `sideband-all` takes every line before its pack through it.
    pub fn band(d: *Demux, data: []const u8) error{ RemoteError, BadSideband }!?[]const u8 {
        if (data.len == 0) return error.BadSideband;
        switch (data[0]) {
            1 => return data[1..],
            2 => {
                if (d.progress) |p| emitRemote(p, data[1..]);
                return null;
            },
            3 => {
                d.keepMessage(data[1..]);
                return error.RemoteError;
            },
            else => return error.BadSideband,
        }
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
                .data => |unparsed| {
                    const data = d.band(unparsed.readForParse()) catch |err| {
                        d.err = err;
                        return error.ReadFailed;
                    };
                    d.pending = data orelse "";
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

/// The remote's text as it is shown: gathered into a buffer and, for its
/// progress text, reported when it fills or the text ends; for its last
/// words kept until the buffer is full.
const Shown = struct {
    control: progress_mod.Control,
    /// Where it is reported; `null` keeps what fits in `buf`.
    p: ?progress_mod.Progress = null,
    buf: []u8,
    len: usize = 0,
    full: bool = false,

    fn flush(s: *Shown) void {
        const p = s.p orelse {
            s.full = true;
            return;
        };
        if (s.len != 0) p.report(p.context, .{ .remote = s.buf[0..s.len] });
        s.len = 0;
    }

    /// Bytes as they are; fewer than the buffer holds.
    fn put(s: *Shown, bytes: []const u8) void {
        if (s.full) return;
        if (s.len + bytes.len > s.buf.len) {
            s.flush();
            if (s.full) return;
        }
        @memcpy(s.buf[s.len..][0..bytes.len], bytes);
        s.len += bytes.len;
    }

    /// Text with its control characters made visible.
    fn sanitized(s: *Shown, text: []const u8) void {
        var rest = text;
        while (rest.len != 0 and !s.full) {
            const part = progress_mod.sanitize(rest, s.control, s.buf[s.len..]);
            s.len += part.written;
            rest = rest[part.read..];
            if (part.read == 0 or rest.len != 0) s.flush();
        }
    }
};

/// Hand the caller the remote's progress text with its control characters
/// made visible, in as many events as the shown text takes, as git's
/// `demultiplex_sideband` writes it: line by line, each line ending as the
/// remote sent it; in colour, a keyword at the start of each line in its
/// colour, what follows the last line ending being such a start.
fn emitRemote(p: progress_mod.Progress, text: []const u8) void {
    var buf: [1024]u8 = undefined;
    var s: Shown = .{ .control = p.remote_control, .p = p, .buf = &buf };
    defer s.flush();
    // git reads the packet as a C string
    var rest = text[0 .. std.mem.findScalar(u8, text, 0) orelse text.len];
    while (rest.len != 0) {
        const brk = std.mem.findAny(u8, rest, "\n\r") orelse rest.len;
        if (brk != 0) if (p.remote_keywords) |keywords| colorize(&s, keywords, rest[0..brk]) else s.sanitized(rest[0..brk]);
        if (brk == rest.len) break;
        s.put(rest[brk..][0..1]);
        rest = rest[brk + 1 ..];
    }
}

/// Errors from reading `sideband.allowControlCharacters`.
pub const ControlError = Allocator.Error || error{
    /// A value with a word git does not know, on which git warns without
    /// end.
    InvalidControlSetting,
};

/// What a remote's text keeps of its control characters for `url`: git's
/// `sideband.allowControlCharacters`, the value under the
/// `sideband.<url>` section that matches `url` best deciding, as git's
/// `sideband_apply_url_config` reads it; the plain setting alone where
/// `url` is `null` or does not normalize. Allocates only while matching.
pub fn allowedControl(gpa: Allocator, config: *const config_mod.Config, url: ?[]const u8) ControlError!progress_mod.Control {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const normalized: ?urlmatch.Info = if (url) |u| urlmatch.normalize(arena, u, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    } else null;
    var out: progress_mod.Control = .{};
    var best: ?urlmatch.Match = null;
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "sideband") or !std.ascii.eqlIgnoreCase(entry.name, "allowcontrolcharacters")) continue;
        const matched: urlmatch.Match = if (entry.subsection.len == 0) .any else blk: {
            const have = normalized orelse continue;
            const pattern = urlmatch.normalize(arena, entry.subsection, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            break :blk urlmatch.match(have, pattern) orelse continue;
        };
        if (best) |b| if (matched.order(b) == .lt) continue;
        best = matched;
        out = parseControl(entry.value) orelse return error.InvalidControlSetting;
    }
    return out;
}

/// A value as git's `sideband_allow_control_characters_config` reads it:
/// a boolean, a bare name being true, or `color`, `cursor`, `erase`,
/// `true` and `false` separated by commas.
fn parseControl(value: ?[]const u8) ?progress_mod.Control {
    const text = value orelse return .everything;
    if (config_mod.parseBool(text)) |on| return if (on) .everything else .none else |_| {}
    var out: progress_mod.Control = .none;
    var rest = text;
    next: while (rest.len != 0) {
        inline for (.{ "color", "cursor", "erase", "true", "false" }) |word| {
            if (std.mem.startsWith(u8, rest, word) and (rest.len == word.len or rest[word.len] == ',')) {
                if (comptime std.mem.eql(u8, word, "true")) {
                    out = .everything;
                } else if (comptime std.mem.eql(u8, word, "false")) {
                    out = .none;
                } else @field(out, word) = true;
                rest = rest[@min(rest.len, word.len + 1)..];
                continue :next;
            }
        }
        return null;
    }
    return out;
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

/// How a pack goes over the wire: as it is, on git's `side-band` in
/// packets of 1000 bytes, or on `side-band-64k`.
pub const Band = enum { none, small, large };

/// The writer a server sends a pack or a report through: on a side-band,
/// what is written goes out on channel one in packets as long as the band
/// allows, and `end` writes what is left and the flush; with no band the
/// bytes go as they are.
pub const Mux = struct {
    out: *Io.Writer,
    band: Band,
    buffer: [pkt_line.max_data - 1]u8 = undefined,
    w: Io.Writer = undefined,

    pub fn init(out: *Io.Writer, framing: Band) Mux {
        return .{ .out = out, .band = framing };
    }

    /// Where the channel's bytes are written. The `Mux` must not move.
    pub fn writer(sb: *Mux) *Io.Writer {
        if (sb.band == .none) return sb.out;
        sb.w = .{ .buffer = sb.buffer[0..bandLength(sb.band)], .vtable = &.{ .drain = drain } };
        return &sb.w;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sb: *Mux = @alignCast(@fieldParentPtr("w", w));
        try sb.emit(w.buffered());
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try sb.emitAll(slice);
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try sb.emitAll(pattern);
        return consumed + pattern.len * splat;
    }

    fn emitAll(sb: *Mux, bytes: []const u8) Io.Writer.Error!void {
        try send(sb.out, sb.band, 1, bytes);
    }

    fn emit(sb: *Mux, bytes: []const u8) Io.Writer.Error!void {
        try send(sb.out, sb.band, 1, bytes);
    }

    /// What is buffered, then the flush that ends the band.
    pub fn end(sb: *Mux) Io.Writer.Error!void {
        if (sb.band == .none) return;
        try sb.emit(sb.w.buffered());
        sb.w.end = 0;
        try sb.out.writeAll("0000");
    }
};

/// A server's lines as git's `packet_writer` writes them: as they are, or,
/// once a v2 client asked for `sideband-all`, each on channel one and an
/// error on channel three where it is otherwise an `ERR` line. A flush or
/// a delimiter goes as it is either way.
pub const Lines = struct {
    out: *Io.Writer,
    /// `sideband-all`.
    banded: bool = false,

    /// One line, its newline in `data`.
    pub fn write(l: *const Lines, data: []const u8) pkt_line.WriteError!void {
        if (!l.banded) return pkt_line.write(l.out, data);
        return pkt_line.print(l.out, "\x01{s}", .{data});
    }

    /// One line formatted in place.
    pub fn print(l: *const Lines, comptime fmt: []const u8, args: anytype) pkt_line.WriteError!void {
        if (!l.banded) return pkt_line.print(l.out, fmt, args);
        return pkt_line.print(l.out, "\x01" ++ fmt, args);
    }

    /// git's `packet_writer_error`.
    pub fn err(l: *const Lines, comptime fmt: []const u8, args: anytype) pkt_line.WriteError!void {
        if (!l.banded) return pkt_line.print(l.out, "ERR " ++ fmt, args);
        return pkt_line.print(l.out, "\x03" ++ fmt, args);
    }

    /// `0001`.
    pub fn delim(l: *const Lines) Io.Writer.Error!void {
        return pkt_line.delim(l.out);
    }

    /// `0000`.
    pub fn flush(l: *const Lines) Io.Writer.Error!void {
        return pkt_line.flush(l.out);
    }
};

/// The most data one packet of `band` carries after its channel byte.
fn bandLength(of: Band) usize {
    return switch (of) {
        .none, .large => pkt_line.max_data - 1,
        .small => 999 - 4,
    };
}

/// `bytes` on `channel` of `band`, in as many packets as it takes, as
/// git's `send_sideband` cuts them: channel one carries data, two progress
/// and messages, three a fatal error. Nothing is written for no bytes.
pub fn send(out: *Io.Writer, framing: Band, channel: u8, bytes: []const u8) Io.Writer.Error!void {
    assert(framing != .none);
    var rest = bytes;
    while (rest.len != 0) {
        const n = @min(rest.len, bandLength(framing));
        var head: [5]u8 = undefined;
        // unreachable: a packet of the band's length fits four hex digits
        _ = std.mem.print(head[0..4], "{x:0>4}", .{n + 5}) catch unreachable;
        head[4] = channel;
        try out.writeAll(&head);
        try out.writeAll(rest[0..n]);
        rest = rest[n..];
    }
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

test "the server's last words in colour: the keyword they start with, as git's maybe_colorize_sideband paints the whole message" {
    var wire: Io.Writer.Allocating = .init(testing.allocator);
    defer wire.deinit();
    try band(&wire.writer, 3, "  Error: no such ref\x07\n");
    var buffer: [pkt_line.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    const colors: RemoteColors = .{};
    const Ignore = struct {
        fn report(_: ?*anyopaque, _: progress_mod.Event) void {}
    };
    var demux: Demux = .init(&in.interface, &.{}, .{ .report = Ignore.report, .remote_keywords = colors.keywords() });
    var out: [8]u8 = undefined;
    try testing.expectError(error.ReadFailed, demux.interface.readSliceShort(&out));
    try testing.expectEqualStrings("\x1b[1;31mError\x1b[m: no such ref^G", demux.message());
}
