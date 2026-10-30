//! git's colours, as `color.c` has them: a colour value read into the
//! escape sequence it writes, the `never`/`always`/`auto` settings with
//! `color.ui` beneath them, and the slots each writer reads from
//! `color.<writer>.<slot>`. Every writer that colours reads its colours
//! here; what it paints with them is the writer's.

const std = @import("std");
const config_mod = @import("config.zig");
const decimal = @import("../text.zig").decimal;

/// The sequence that ends every colour, git's `GIT_COLOR_RESET`.
pub const reset = "\x1b[m";

/// The longest sequence `parse` writes: git's `COLOR_MAXLEN` less its NUL.
pub const max_len = 74;

/// One colour as git writes it: an escape sequence, or nothing for
/// `normal` and an empty value.
pub const Color = struct {
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    /// The colour that writes nothing.
    pub const none: Color = .{};

    /// A sequence written out, as git's defaults are.
    pub fn of(comptime sequence: []const u8) Color {
        comptime std.debug.assert(sequence.len <= max_len);
        var c: Color = .{ .len = sequence.len };
        @memcpy(c.buf[0..sequence.len], sequence);
        return c;
    }

    pub fn bytes(c: *const Color) []const u8 {
        return c.buf[0..c.len];
    }

    /// Whether it writes nothing.
    pub fn isNone(c: Color) bool {
        return c.len == 0;
    }
};

/// git's named defaults.
pub const bold: Color = .of("\x1b[1m");
pub const red: Color = .of("\x1b[31m");
pub const green: Color = .of("\x1b[32m");
pub const yellow: Color = .of("\x1b[33m");
pub const blue: Color = .of("\x1b[34m");
pub const magenta: Color = .of("\x1b[35m");
pub const cyan: Color = .of("\x1b[36m");
pub const bold_red: Color = .of("\x1b[1;31m");
pub const bold_green: Color = .of("\x1b[1;32m");
pub const bold_yellow: Color = .of("\x1b[1;33m");
pub const bold_blue: Color = .of("\x1b[1;34m");
pub const bold_magenta: Color = .of("\x1b[1;35m");
pub const bold_cyan: Color = .of("\x1b[1;36m");
pub const faint: Color = .of("\x1b[2m");
pub const faint_italic: Color = .of("\x1b[2;3m");
pub const faint_red: Color = .of("\x1b[2;31m");
pub const faint_green: Color = .of("\x1b[2;32m");
pub const bg_red: Color = .of("\x1b[41m");
pub const reverse: Color = .of("\x1b[7m");

/// Errors from reading colours out of a configuration.
pub const Error = error{
    /// A colour value git's `color_parse` refuses: a word that is neither
    /// a colour nor an attribute, or a third colour. git dies on it.
    InvalidColor,
    /// A colour slot set as a bare name, which git dies on as having no
    /// value.
    MissingColorValue,
    /// A `color.ui`, `color.<writer>` or `--color` value that is neither
    /// `never`, `always`, `auto` nor a boolean: git dies on it.
    InvalidColorSetting,
    /// A slot the writer does not have, where the writer refuses one as
    /// git's grep does.
    UnknownColorSlot,
};

/// A colour value as git's `color_parse` reads it: `[reset] [fg [bg]]
/// [attr]...`, words split on whitespace. A colour is `normal`, `default`,
/// one of the eight names with `bright` before it or not, `-1` to 255, or
/// `#rgb` and `#rrggbb`; an attribute is `bold`, `dim`, `italic`, `ul`,
/// `blink`, `reverse` or `strike`, with `no` or `no-` before it to turn it
/// off. Names are matched without regard to case, attributes exactly.
pub fn parse(value: []const u8) error{InvalidColor}!Color {
    var reset_asked = false;
    var attrs: u32 = 0;
    var fg: Single = .unspecified;
    var bg: Single = .unspecified;
    var words = std.mem.tokenizeAny(u8, value, " \t\n\x0b\x0c\r");
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "reset")) {
            reset_asked = true;
            continue;
        }
        if (parseSingle(word)) |c| {
            if (fg == .unspecified) {
                fg = c;
            } else if (bg == .unspecified) {
                bg = c;
            } else return error.InvalidColor;
            continue;
        }
        const bit = parseAttr(word) orelse return error.InvalidColor;
        attrs |= @as(u32, 1) << bit;
    }
    var out: Color = .{};
    if (!reset_asked and attrs == 0 and fg.empty() and bg.empty()) return out;
    var w: std.Io.Writer = .fixed(&out.buf);
    // git's buffer is sized for two colours and every attribute, and so is this
    // unreachable: the longest sequence fits in `max_len`
    writeSequence(&w, reset_asked, attrs, fg, bg) catch unreachable;
    out.len = @intCast(w.end);
    return out;
}

/// git's `color_output` for each part, `ESC [` before and `m` after.
fn writeSequence(w: *std.Io.Writer, reset_asked: bool, attrs_in: u32, fg: Single, bg: Single) std.Io.Writer.Error!void {
    var attrs = attrs_in;
    try w.writeAll("\x1b[");
    var sep = reset_asked;
    var bit: u5 = 0;
    while (attrs != 0) : (bit += 1) {
        const mask = @as(u32, 1) << bit;
        if (attrs & mask == 0) continue;
        attrs &= ~mask;
        if (sep) try w.writeByte(';');
        sep = true;
        try w.print("{d}", .{bit});
    }
    for ([_]Single{ fg, bg }, [_]u8{ 0, 10 }) |c, offset| {
        if (c.empty()) continue;
        if (sep) try w.writeByte(';');
        sep = true;
        switch (c) {
            .unspecified, .normal => unreachable, // `empty` above
            .ansi => |n| try w.print("{d}", .{@as(u32, n) + offset}),
            .@"256" => |n| try w.print("{d};5;{d}", .{ 38 + @as(u32, offset), n }),
            .rgb => |rgb| try w.print("{d};2;{d};{d};{d}", .{ 38 + @as(u32, offset), rgb[0], rgb[1], rgb[2] }),
        }
    }
    try w.writeByte('m');
}

/// One foreground or background colour.
const Single = union(enum) {
    unspecified,
    normal,
    /// The foreground code: 30-37, 39 or 90-97.
    ansi: u8,
    @"256": u8,
    rgb: [3]u8,

    fn empty(c: Single) bool {
        return c == .unspecified or c == .normal;
    }
};

fn parseSingle(word: []const u8) ?Single {
    if (std.ascii.eqlIgnoreCase(word, "normal")) return .normal;
    if ((word.len == 7 or word.len == 4) and word[0] == '#') {
        const width: usize = if (word.len == 7) 2 else 1;
        var rgb: [3]u8 = undefined;
        for (&rgb, 0..) |*part, i| {
            const at = 1 + i * width;
            // git reads `#rgb` as each digit twice
            const hi = std.fmt.charToDigit(word[at], 16) catch break;
            const lo = std.fmt.charToDigit(word[at + width - 1], 16) catch break;
            part.* = (hi << 4) | lo;
        } else return .{ .rgb = rgb };
    }
    if (std.ascii.eqlIgnoreCase(word, "default")) return .{ .ansi = 39 };
    const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
    const bright = word.len >= 6 and std.ascii.eqlIgnoreCase(word[0..6], "bright");
    const name = if (bright) word[6..] else word;
    for (names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(name, n)) return .{ .ansi = @as(u8, @intCast(i)) + @as(u8, if (bright) 90 else 30) };
    }
    // git's `strtol` over the whole word: a sign, then digits.
    const read = decimal.strtol(word, 10, 64);
    if (read.end != word.len) return null;
    const n = read.value;
    if (n < -1) return null;
    if (n < 0) return .normal;
    if (n < 8) return .{ .ansi = @as(u8, @intCast(n)) + 30 };
    if (n < 16) return .{ .ansi = @as(u8, @intCast(n)) - 8 + 90 };
    if (n < 256) return .{ .@"256" = @intCast(n) };
    return null;
}

/// The attribute's code, or its `no` form's.
fn parseAttr(word_in: []const u8) ?u5 {
    const attrs = [_]struct { []const u8, u5, u5 }{
        .{ "bold", 1, 22 },  .{ "dim", 2, 22 },     .{ "italic", 3, 23 }, .{ "ul", 4, 24 },
        .{ "blink", 5, 25 }, .{ "reverse", 7, 27 }, .{ "strike", 9, 29 },
    };
    var word = word_in;
    var negate = false;
    if (std.mem.startsWith(u8, word, "no")) {
        word = word[2..];
        if (std.mem.startsWith(u8, word, "-")) word = word[1..];
        negate = true;
    }
    for (attrs) |a| {
        if (std.mem.eql(u8, word, a[0])) return if (negate) a[2] else a[1];
    }
    return null;
}

/// When a writer colours: git's colour setting, from `color.ui`,
/// `color.<writer>` or `--color=<when>`.
pub const When = enum {
    never,
    always,
    /// When the output is a terminal.
    auto,
};

/// A colour setting as git's `git_config_colorbool` reads it: `never`,
/// `always` and `auto` without regard to case, a bare name `auto`, and
/// any boolean, true being `auto`.
pub fn parseWhen(value: ?[]const u8) error{InvalidColorSetting}!When {
    const text = value orelse return .auto;
    if (std.ascii.eqlIgnoreCase(text, "never")) return .never;
    if (std.ascii.eqlIgnoreCase(text, "always")) return .always;
    if (std.ascii.eqlIgnoreCase(text, "auto")) return .auto;
    const on = config_mod.parseBool(text) catch return error.InvalidColorSetting;
    return if (on) .auto else .never;
}

/// Where a writer's text goes, as its caller knows it, and what the caller
/// asked for.
pub const Output = struct {
    /// `--color=<when>`, which decides over the configuration; `null`
    /// leaves it to `color.<writer>` and `color.ui`.
    asked: ?When = null,
    /// What `auto` means here: git colours when the output is a terminal
    /// and `TERM` is not `dumb`, or goes to a pager it colours for
    /// (`color.pager`). relic does not see the output, so its caller says.
    terminal: bool = false,

    /// `--no-color`.
    pub const plain: Output = .{ .asked = .never };
    /// `--color=always`.
    pub const always: Output = .{ .asked = .always };
};

/// Whether a writer colours, as git's `want_color` decides it: what the
/// caller asked, else the last `writer_key` (`color.diff`, `color.grep`,
/// ...; `null` for a writer with none), else `color.ui`, which is `auto`
/// when it is not set. Each value is read as git's callback reads it: one
/// git dies on is refused wherever it stands.
pub fn wanted(config: ?*const config_mod.Config, writer_keys: []const []const u8, output: Output) error{InvalidColorSetting}!bool {
    var ui: When = .auto;
    var own: ?When = null;
    if (config) |c| {
        var it = c.iterate(&.{"color.ui"});
        while (it.next()) |entry| ui = try parseWhen(entry.value);
        it = c.iterate(writer_keys);
        while (it.next()) |entry| own = try parseWhen(entry.value);
    }
    return switch (output.asked orelse own orelse ui) {
        .never => false,
        .always => true,
        .auto => output.terminal,
    };
}

/// Where a writer's slots are set: `color.<writer>.<slot>` is section
/// `color`, subsection `<writer>`; git reads some under an old name too,
/// such as `diff.color.<slot>`.
pub const SlotSection = struct { section: []const u8, subsection: []const u8 };

/// What a writer does with a slot it does not have: pass it over, as
/// most of git's writers do, or refuse it, as git's grep dies on it.
pub const UnknownSlot = enum { pass_over, refuse };

/// Where a writer's slots are read, and what it does with one it does not
/// have.
pub const SlotRead = struct {
    sections: []const SlotSection,
    unknown: UnknownSlot = .pass_over,
};

/// Read a writer's colour slots into `slots`, a struct of `Color` fields
/// holding git's defaults. `names` gives git's name for each slot (a field
/// may have more than one, as `color.diff.plain` is `context`, and a name
/// may set more than one field, as `color.grep.match` sets both match
/// slots); a name is matched without regard to case. Values are read in
/// order, the last deciding; one git dies on is refused wherever it
/// stands.
pub fn readSlots(
    comptime Slots: type,
    slots: *Slots,
    config: *const config_mod.Config,
    comptime names: []const struct { []const u8, std.meta.FieldEnum(Slots) },
    read: SlotRead,
) Error!void {
    for (config.entries.items) |entry| {
        if (!entry.has_subsection) continue;
        for (read.sections) |s| {
            if (std.mem.eql(u8, entry.section, s.section) and std.mem.eql(u8, entry.subsection, s.subsection)) break;
        } else continue;
        var known = false;
        for (names) |n| {
            if (!std.ascii.eqlIgnoreCase(entry.name, n[0])) continue;
            known = true;
            const color = try parse(entry.value orelse return error.MissingColorValue);
            switch (n[1]) {
                inline else => |f| @field(slots, @tagName(f)) = color,
            }
        }
        if (!known and read.unknown == .refuse) return error.UnknownColorSlot;
    }
}

test "colour values are the sequences git's color_parse writes" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "normal", "" },
        .{ "red", "\x1b[31m" },
        .{ "bold red", "\x1b[1;31m" },
        .{ "red bold", "\x1b[1;31m" },
        .{ "Red Blue", "\x1b[31;44m" },
        .{ "brightred", "\x1b[91m" },
        .{ "default", "\x1b[39m" },
        .{ "normal default", "\x1b[49m" },
        .{ "reset", "\x1b[m" },
        .{ "reset green", "\x1b[;32m" },
        .{ "-1 2", "\x1b[42m" },
        .{ "9", "\x1b[91m" },
        .{ "100 255", "\x1b[38;5;100;48;5;255m" },
        .{ "#ff0ab3", "\x1b[38;2;255;10;179m" },
        .{ "#f0b", "\x1b[38;2;255;0;187m" },
        .{ "bold dim italic ul blink reverse strike", "\x1b[1;2;3;4;5;7;9m" },
        .{ "nobold no-ul", "\x1b[22;24m" },
        .{ "nodim nobold", "\x1b[22m" },
        .{ "  ul  ", "\x1b[4m" },
        .{ "+5", "\x1b[35m" },
        .{ "07", "\x1b[37m" },
        .{ "BRIGHTRED", "\x1b[91m" },
    };
    for (cases) |case| {
        const got = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], got.bytes());
    }
    for ([_][]const u8{ "red blue green", "Bold", "-2", "256", "1_0", "#ggg", "#ff00", "nope" }) |bad| {
        try std.testing.expectError(error.InvalidColor, parse(bad));
    }
}

test "colour settings as git_config_colorbool reads them, color.ui beneath the writer's own" {
    try std.testing.expectEqual(When.auto, try parseWhen(null));
    try std.testing.expectEqual(When.always, try parseWhen("Always"));
    try std.testing.expectEqual(When.never, try parseWhen("false"));
    try std.testing.expectEqual(When.auto, try parseWhen("1"));
    try std.testing.expectError(error.InvalidColorSetting, parseWhen("sometimes"));

    const gpa = std.testing.allocator;
    var config = try config_mod.Config.parseText(gpa, "[color]\n\tui = always\n\tdiff = auto\n", .local);
    defer config.deinit();
    try std.testing.expect(!try wanted(&config, &.{"color.diff"}, .{}));
    try std.testing.expect(try wanted(&config, &.{"color.diff"}, .{ .terminal = true }));
    try std.testing.expect(try wanted(&config, &.{"color.grep"}, .{}));
    try std.testing.expect(!try wanted(&config, &.{"color.grep"}, .plain));
    try std.testing.expect(!try wanted(null, &.{}, .{}));
}
