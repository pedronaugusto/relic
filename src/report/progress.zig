//! What a long operation says while it runs.
//!
//! A fetch or a push can take minutes, and the caller — a terminal, a
//! daemon with a status line, an editor with a progress bar — decides what
//! to show. relic hands it events and prints nothing itself. A caller that
//! passes no `Progress` hears nothing and loses nothing.

const std = @import("std");

/// Something worth telling the caller.
pub const Event = union(enum) {
    /// Text the other side sent on the side-band's progress channel:
    /// `Counting objects: 100% (5/5), done.\r` and the like. It is the
    /// remote's text, with its control characters made visible as
    /// `Progress.remote_control` says, so that it cannot move a terminal's
    /// cursor, retitle its window or hide what is above it; a long line
    /// may arrive in more than one event.
    remote: []const u8,
    /// Bytes of a pack received so far.
    received: u64,
    /// Objects of a received pack read and named, of how many.
    indexed: Count,
    /// Delta objects resolved, of how many.
    resolved: Count,
    /// Objects written into a pack being sent, of how many.
    written: Count,
    /// LFS objects transferred, of how many: downloaded or uploaded,
    /// whichever the operation does.
    lfs_objects: Count,
    /// Bytes of LFS objects transferred, of how many.
    lfs_bytes: Count,
};

/// How far along: `done` of `total`.
pub const Count = struct {
    done: u64,
    total: u64,
};

/// Where events go.
pub const Progress = struct {
    context: ?*anyopaque = null,
    /// Called on the caller's own task, between two steps of the
    /// operation; whatever it does delays the operation by that much.
    report: *const fn (context: ?*anyopaque, event: Event) void,
    /// What the remote's text may keep of its control characters: git's
    /// `sideband.allowControlCharacters` (`transport.side_band.Allowed`
    /// reads it), whose default keeps colour.
    remote_control: Control = .{},
    /// The colours a keyword at the start of a line of the remote's text
    /// is written in, as git's `maybe_colorize_sideband` writes them;
    /// `null` writes none. `transport.side_band.RemoteColors` gives git's.
    remote_keywords: ?Keywords = null,

    /// Hand `event` to the caller, when there is one to hand it to.
    pub fn emit(progress: ?Progress, event: Event) void {
        const p = progress orelse return;
        p.report(p.context, event);
    }
};

/// The escape sequences a remote's keywords are written in, each ended by
/// a reset; empty writes the keyword as it is.
pub const Keywords = struct {
    hint: []const u8 = "",
    warning: []const u8 = "",
    success: []const u8 = "",
    @"error": []const u8 = "",
};

/// Which control characters a remote's text keeps, as git 2.55's
/// `sideband.allowControlCharacters` says. Each one it does not keep is
/// shown as `^` and a letter, `ESC` as `^[`, `DEL` as `^?`. The default
/// keeps colour.
pub const Control = packed struct(u4) {
    /// ANSI colour, `ESC [ <n>;... m`.
    color: bool = true,
    /// The cursor moved: `ESC [ <n>;... ` and one of `ABCDEFGHf`.
    cursor: bool = false,
    /// Characters erased: `ESC [ <n>;... ` and one of `JKMPX`.
    erase: bool = false,
    /// Every control character, as the remote sent it.
    all: bool = false,

    /// None of them.
    pub const none: Control = .{ .color = false };
    /// All of them.
    pub const everything: Control = .{ .color = false, .all = true };
};

/// How much of `text` one `sanitize` took, and how much it wrote.
pub const Sanitized = struct { read: usize, written: usize };

/// git's `strbuf_add_sanitized`: as much of `text` as fits in `out`, with
/// every control character but a tab and a line feed made visible unless
/// `control` keeps it. A NUL ends the text, as it ends
/// git's. Call again with what is left; each call takes at least one byte
/// when `out` holds two.
pub fn sanitize(text: []const u8, control: Control, out: []u8) Sanitized {
    if (control.all) {
        const n = @min(text.len, out.len);
        @memcpy(out[0..n], text[0..n]);
        return .{ .read = n, .written = n };
    }
    var r: usize = 0;
    var w: usize = 0;
    while (r < text.len) {
        const c = text[r];
        if (c == 0) return .{ .read = text.len, .written = w };
        if (c >= 0x20 and c != 0x7f or c == '\t' or c == '\n') {
            if (w == out.len) break;
            out[w] = c;
            w += 1;
            r += 1;
            continue;
        }
        if (control != Control.none) if (sequence(text[r..], control)) |len| {
            if (w + len <= out.len) {
                @memcpy(out[w..][0..len], text[r..][0..len]);
                w += len;
                r += len;
                continue;
            }
            // Whole in the next call; one longer than any buffer is shown.
            if (len <= out.len) break;
        };
        if (w + 2 > out.len) break;
        out[w] = '^';
        out[w + 1] = if (c == 0x7f) '?' else 0x40 + c;
        w += 2;
        r += 1;
    }
    return .{ .read = r, .written = w };
}

/// The length of the ANSI sequence `control` keeps that `text` starts
/// with, `ESC [`, then digits and `;`, then the letter that ends it, as
/// git's `handle_ansi_sequence` reads one; `null` when it starts with none.
fn sequence(text: []const u8, control: Control) ?usize {
    if (text.len < 3 or text[0] != 0x1b or text[1] != '[') return null;
    for (text[2..], 2..) |c, i| {
        if ((control.color and c == 'm') or
            (control.cursor and std.mem.findScalar(u8, "ABCDEFGHf", c) != null) or
            (control.erase and std.mem.findScalar(u8, "JKMPX", c) != null)) return i + 1;
        if (!std.ascii.isDigit(c) and c != ';') return null;
    }
    return null;
}

test "a remote's control characters are shown, colour kept by default, as git 2.55 shows them" {
    var buf: [64]u8 = undefined;
    const text = "\x1b[31mred\x1b[m \x1b]0;title\x07 \x1b[2J\x1b[3G\x7f\tok\r\n";
    var got = sanitize(text, .{}, &buf);
    try std.testing.expectEqual(text.len, got.read);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[m ^[]0;title^G ^[[2J^[[3G^?\tok^M\n", buf[0..got.written]);
    got = sanitize(text, .none, &buf);
    try std.testing.expectEqualStrings("^[[31mred^[[m ^[]0;title^G ^[[2J^[[3G^?\tok^M\n", buf[0..got.written]);
    got = sanitize(text, .{ .color = false, .cursor = true, .erase = true }, &buf);
    try std.testing.expectEqualStrings("^[[31mred^[[m ^[]0;title^G \x1b[2J\x1b[3G^?\tok^M\n", buf[0..got.written]);
    got = sanitize(text, .everything, &buf);
    try std.testing.expectEqualStrings(text, buf[0..got.written]);
    got = sanitize("a\x00hidden", .{}, &buf);
    try std.testing.expectEqualStrings("a", buf[0..got.written]);
    // A buffer too small for the rest takes what fits, and moves on.
    var small: [2]u8 = undefined;
    var rest: []const u8 = "\x1b[31mx";
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(std.testing.allocator);
    while (rest.len != 0) {
        const part = sanitize(rest, .{}, &small);
        try std.testing.expect(part.read != 0);
        try shown.appendSlice(std.testing.allocator, small[0..part.written]);
        rest = rest[part.read..];
    }
    try std.testing.expectEqualStrings("^[[31mx", shown.items);
}

test "no progress is heard and nothing breaks" {
    Progress.emit(null, .{ .received = 1 });
    var seen: u64 = 0;
    const p: Progress = .{ .context = &seen, .report = struct {
        fn report(context: ?*anyopaque, event: Event) void {
            const count: *u64 = @ptrCast(@alignCast(context.?));
            count.* += event.received;
        }
    }.report };
    Progress.emit(p, .{ .received = 41 });
    Progress.emit(p, .{ .received = 1 });
    try std.testing.expectEqual(@as(u64, 42), seen);
}

/// All errors reported by this namespace.
pub const Error = error{};
