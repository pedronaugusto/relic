//! git's diff in colour: the slots `color.diff.<slot>` sets, and each line
//! of a patch painted as git's `diff.c` paints it — the headers in `meta`,
//! the `@@` line in `frag` and `func`, removed and added lines in `old` and
//! `new`, and whitespace errors marked as `core.whitespace` and
//! `diff.wsErrorHighlight` say.

const std = @import("std");
const Io = std.Io;
const parallax = @import("parallax");
const color = @import("../config/color.zig");
const config_mod = @import("../config/config.zig");
const whitespace = @import("../text.zig").whitespace;
const decimal = @import("../text.zig").decimal;

const Color = color.Color;

/// The colours a patch is written in: git's defaults, and what
/// `color.diff.<slot>` (or its old name `diff.color.<slot>`) sets.
pub const Colors = struct {
    context: Color = .none,
    meta: Color = color.bold,
    frag: Color = color.cyan,
    old: Color = color.red,
    new: Color = color.green,
    commit: Color = color.yellow,
    whitespace: Color = color.bg_red,
    func: Color = .none,
    old_moved: Color = color.bold_magenta,
    old_moved_alternative: Color = color.bold_blue,
    old_moved_dimmed: Color = color.faint,
    old_moved_alternative_dimmed: Color = color.faint_italic,
    new_moved: Color = color.bold_cyan,
    new_moved_alternative: Color = color.bold_yellow,
    new_moved_dimmed: Color = color.faint,
    new_moved_alternative_dimmed: Color = color.faint_italic,
    context_dimmed: Color = color.faint,
    old_dimmed: Color = color.faint_red,
    new_dimmed: Color = color.faint_green,
    context_bold: Color = color.bold,
    old_bold: Color = color.bold_red,
    new_bold: Color = color.bold_green,

    const Field = std.meta.FieldEnum(Colors);

    /// git's slot names, `plain` being `context`'s old name.
    const names = [_]struct { []const u8, Field }{
        .{ "context", .context },                                        .{ "plain", .context },
        .{ "meta", .meta },                                              .{ "frag", .frag },
        .{ "old", .old },                                                .{ "new", .new },
        .{ "commit", .commit },                                          .{ "whitespace", .whitespace },
        .{ "func", .func },                                              .{ "oldMoved", .old_moved },
        .{ "oldMovedAlternative", .old_moved_alternative },              .{ "oldMovedDimmed", .old_moved_dimmed },
        .{ "oldMovedAlternativeDimmed", .old_moved_alternative_dimmed }, .{ "newMoved", .new_moved },
        .{ "newMovedAlternative", .new_moved_alternative },              .{ "newMovedDimmed", .new_moved_dimmed },
        .{ "newMovedAlternativeDimmed", .new_moved_alternative_dimmed }, .{ "contextDimmed", .context_dimmed },
        .{ "oldDimmed", .old_dimmed },                                   .{ "newDimmed", .new_dimmed },
        .{ "contextBold", .context_bold },                               .{ "oldBold", .old_bold },
        .{ "newBold", .new_bold },
    };

    /// git's defaults under what `color.diff.<slot>` and `diff.color.<slot>`
    /// set, read in order as git's diff reads them.
    pub fn read(config: *const config_mod.Config) color.Error!Colors {
        var out: Colors = .{};
        try color.readSlots(Colors, &out, config, &names, .{ .sections = &.{
            .{ .section = "color", .subsection = "diff" },
            .{ .section = "diff", .subsection = "color" },
        } });
        return out;
    }

    /// The colours `output` asks for: `null` where git writes a patch
    /// without colour, as `color.diff` (or `diff.color`) and `color.ui`
    /// decide; otherwise git's defaults under `color.diff.<slot>`.
    pub fn configured(config: ?*const config_mod.Config, output: color.Output) color.Error!?Colors {
        if (!try color.wanted(config, &.{ "color.diff", "diff.color" }, output)) return null;
        return if (config) |c| try read(c) else .{};
    }
};

/// Which lines a coloured patch marks whitespace errors on: git's
/// `--ws-error-highlight` and `diff.wsErrorHighlight`, `new` by default.
pub const WsErrorHighlight = packed struct {
    old: bool = false,
    new: bool = true,
    context: bool = false,

    /// A value as git's `parse_ws_error_highlight` reads it: `none`,
    /// `default`, `all`, `old`, `new` and `context`, comma separated, the
    /// first three replacing what came before. `null` for a value git
    /// refuses.
    pub fn parse(text: []const u8) ?WsErrorHighlight {
        var out: WsErrorHighlight = .{ .new = false };
        var rest = text;
        while (rest.len != 0) {
            const end = std.mem.findScalar(u8, rest, ',') orelse rest.len;
            const token = rest[0..end];
            if (std.mem.eql(u8, token, "none")) {
                out = .{ .new = false };
            } else if (std.mem.eql(u8, token, "default")) {
                out = .{};
            } else if (std.mem.eql(u8, token, "all")) {
                out = .{ .old = true, .new = true, .context = true };
            } else if (std.mem.eql(u8, token, "new")) {
                out.new = true;
            } else if (std.mem.eql(u8, token, "old")) {
                out.old = true;
            } else if (std.mem.eql(u8, token, "context")) {
                out.context = true;
            } else return null;
            rest = if (end < rest.len) rest[end + 1 ..] else "";
        }
        return out;
    }
};

/// A header line, `diff --git`, `index` and the rest, as git colours it:
/// the whole line in `meta`.
pub fn writeMeta(w: *Io.Writer, colors: ?*const Colors, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
    const c = colors orelse return w.print(fmt ++ "\n", args);
    try w.writeAll(c.meta.bytes());
    try w.print(fmt, args);
    try w.writeAll(color.reset);
    try w.writeByte('\n');
}

/// range-diff's diff of two patches, as git writes it (`output_prefix`,
/// `suppress_hunk_header_line_count`, `dual_color_diffed_diffs`): every
/// line indented four spaces, each `@@` line without its ranges, and in
/// colour under `dual_color` each line painted by both its signs, the outer
/// one reversed.
pub const DiffOfPatches = struct {
    dual_color: bool = true,

    const prefix = "    ";
};

/// The colours of a patch written without colour: none, which a painter
/// writes as git writes its empty colours.
const plain: Colors = blk: {
    var c: Colors = .{};
    for (@typeInfo(Colors).@"struct".field_names) |name| @field(c, name) = .none;
    break :blk c;
};

/// What paints one file's patch: parallax hands it each line.
pub const Painter = struct {
    colors: *const Colors,
    /// What ends a colour: nothing without colours, as git's empty
    /// `DIFF_RESET` is.
    reset: []const u8,
    rule: whitespace.Rule,
    highlight: WsErrorHighlight,
    of_patches: ?DiffOfPatches = null,
    /// git's `blank_at_eof_in_preimage` and `_postimage`: where the blank
    /// lines the new side adds at its end begin, one-based, or zero.
    blank_at_eof_old: u32 = 0,
    blank_at_eof_new: u32 = 0,
    /// git's line counters, one past the line being written.
    old_line: u32 = 0,
    new_line: u32 = 0,

    /// A painter for one pair of texts; `null` colours write none.
    pub fn init(colors: ?*const Colors, rule: whitespace.Rule, highlight: WsErrorHighlight, of_patches: ?DiffOfPatches, old: []const u8, new: []const u8) Painter {
        var p: Painter = .{ .colors = colors orelse &plain, .reset = if (colors != null) color.reset else "", .rule = rule, .highlight = highlight, .of_patches = of_patches };
        if (rule & whitespace.blank_at_eof != 0) {
            const l1 = trailingBlank(old);
            const l2 = trailingBlank(new);
            if (l2 > l1) {
                p.blank_at_eof_old = countLines(old) - l1 + 1;
                p.blank_at_eof_new = countLines(new) - l2 + 1;
            }
        }
        return p;
    }

    pub fn paint(p: *Painter) parallax.Paint {
        return .{ .context = p, .write = write };
    }

    fn prefix(p: *const Painter) []const u8 {
        return if (p.of_patches != null) DiffOfPatches.prefix else "";
    }

    /// Whether lines are painted by both their signs.
    fn dual(p: *const Painter) bool {
        return if (p.of_patches) |o| o.dual_color else false;
    }

    fn write(context: ?*const anyopaque, w: *Io.Writer, line: parallax.Paint.Line) Io.Writer.Error!void {
        const p: *Painter = @ptrCast(@alignCast(@constCast(context.?))); // safe: `paint` hands its own *Painter
        const c = p.colors;
        const reset = p.reset;
        try w.writeAll(p.prefix());
        switch (line.kind) {
            .old_file, .new_file => {
                try w.writeAll(c.meta.bytes());
                try w.writeAll(if (line.kind == .old_file) "--- " else "+++ ");
                try w.writeAll(line.text);
                try w.writeAll(reset);
                if (std.mem.findScalar(u8, line.text, ' ') != null) try w.writeByte('\t');
                try w.writeByte('\n');
            },
            .hunk => {
                // git's `emit_hunk_header`
                p.old_line = start(line.text, '-');
                p.new_line = start(line.text, '+');
                if (p.dual() and reset.len != 0) try w.writeAll(color.reverse.bytes());
                try w.writeAll(c.frag.bytes());
                try w.writeAll(if (p.of_patches != null) "@@" else line.text);
                try w.writeAll(reset);
                if (line.heading.len != 0) {
                    try w.writeAll(c.context.bytes());
                    try w.writeByte(' ');
                    try w.writeAll(reset);
                    try w.writeAll(c.func.bytes());
                    try w.writeAll(line.heading);
                    try w.writeAll(reset);
                }
                try w.writeByte('\n');
            },
            // git's `emit_diff_symbol_from_struct`: under dual colour a line
            // of a diff of patches is painted by its own sign and by the
            // patch's sign it begins with
            .context => {
                p.old_line += 1;
                p.new_line += 1;
                var set = c.context.bytes();
                if (p.dual()) switch (first(line.text)) {
                    '+' => set = c.new.bytes(),
                    '@' => set = c.frag.bytes(),
                    '-' => set = c.old.bytes(),
                    else => {},
                };
                try p.markup(w, null, set, line, p.highlight.context, false);
            },
            .old => {
                p.old_line += 1;
                if (!p.dual()) return p.markup(w, null, c.old.bytes(), line, p.highlight.old, false);
                const set = switch (first(line.text)) {
                    '+' => c.new_dimmed.bytes(),
                    '@' => c.frag.bytes(),
                    '-' => c.old_dimmed.bytes(),
                    else => c.context_dimmed.bytes(),
                };
                try p.markup(w, c.old.bytes(), set, line, p.highlight.old, false);
            },
            .new => {
                p.new_line += 1;
                if (!p.dual()) return p.markup(w, null, c.new.bytes(), line, p.highlight.new, p.blankAtEof(line.text));
                const set = switch (first(line.text)) {
                    '-' => c.old_bold.bytes(),
                    '@' => c.frag.bytes(),
                    '+' => c.new_bold.bytes(),
                    else => c.context_bold.bytes(),
                };
                // git marks no whitespace on these
                try p.markup(w, c.new.bytes(), set, line, false, false);
            },
            .incomplete => {
                const after = switch (line.sign) {
                    '-' => p.highlight.old,
                    '+' => p.highlight.new,
                    else => p.highlight.context,
                };
                const set = if (p.rule & whitespace.incomplete_line != 0 and after) c.whitespace.bytes() else c.context.bytes();
                try emitLine(w, set, null, false, reset, 0, line.text);
            },
        }
    }

    /// git's `emit_line_ws_markup`: the sign in `set_sign`, reversed, where
    /// a line has two colours, else all in `set`; whitespace errors marked
    /// where `highlighted`.
    fn markup(p: *Painter, w: *Io.Writer, set_sign: ?[]const u8, set: []const u8, line: parallax.Paint.Line, highlighted: bool, blank_at_eof: bool) Io.Writer.Error!void {
        const ws: ?[]const u8 = if (highlighted and !p.colors.whitespace.isNone()) p.colors.whitespace.bytes() else null;
        const text = line.text;
        // reverse is written only where there are colours, as git's
        // `want_color` decides
        const reverse = set_sign != null and p.reset.len != 0;
        // A last line without its ending is written with one, as git's
        // xdiff hands it on.
        const complete = text.len != 0 and text[text.len - 1] == '\n';
        if (ws == null) {
            if (set_sign) |sign_set| {
                try emitLine(w, sign_set, set, reverse, p.reset, line.sign, text);
            } else try emitLine(w, set, null, false, p.reset, line.sign, text);
        } else if (blank_at_eof) {
            try emitLine(w, ws.?, null, false, p.reset, line.sign, text);
        } else {
            try emitLine(w, set_sign orelse set, null, reverse, p.reset, line.sign, "");
            _ = try whitespace.checkEmit(text, p.rule, .{ .w = w, .set = set, .reset = p.reset, .ws = ws.? });
        }
        if (!complete) try w.writeByte('\n');
    }

    /// git's `new_blank_line_at_eof`.
    fn blankAtEof(p: *const Painter, text: []const u8) bool {
        if (!(p.rule & whitespace.blank_at_eof != 0 and p.blank_at_eof_old != 0 and p.blank_at_eof_new != 0 and
            p.blank_at_eof_old <= p.old_line and p.blank_at_eof_new <= p.new_line)) return false;
        return whitespace.blankLine(text);
    }
};

/// A line's first byte, zero for an empty one.
fn first(text: []const u8) u8 {
    return if (text.len != 0) text[0] else 0;
}

/// git's `emit_line_0`, after its prefix: the sign in `set_sign`, or with
/// `set_sign` null in `set`; the text after it, its ending kept outside
/// the colour.
fn emitLine(w: *Io.Writer, set_sign: ?[]const u8, set: ?[]const u8, reverse: bool, reset: []const u8, sign: u8, line: []const u8) Io.Writer.Error!void {
    var len = line.len;
    const newline = len > 0 and line[len - 1] == '\n';
    if (newline) len -= 1;
    const carriage_return = len > 0 and line[len - 1] == '\r';
    if (carriage_return) len -= 1;
    var needs_reset = false;
    if (len != 0 or sign != 0) {
        if (reverse) {
            try w.writeAll(color.reverse.bytes());
            needs_reset = true;
        }
        if (set_sign) |s| {
            try w.writeAll(s);
            needs_reset = true;
        }
        if (sign != 0) try w.writeByte(sign);
        if (len != 0) {
            if (set) |s| {
                if (set_sign != null and set_sign.?.ptr != s.ptr) try w.writeAll(reset);
                try w.writeAll(s);
            }
            try w.writeAll(line[0..len]);
            needs_reset = true;
        }
    }
    if (needs_reset) try w.writeAll(reset);
    if (carriage_return) try w.writeByte('\r');
    if (newline) try w.writeByte('\n');
}

/// The number after `sign` in a `@@` line, as git's `strtol` reads it.
fn start(header: []const u8, sign: u8) u32 {
    const at = std.mem.findScalar(u8, header, sign) orelse return 0;
    return std.math.cast(u32, decimal.strtol(header[at + 1 ..], 10, 64).value) orelse 0;
}

/// git's `count_trailing_blank`: the blank lines a text ends with. As
/// git's, it never looks at a first line of one byte or none.
fn trailingBlank(text: []const u8) u32 {
    if (text.len == 0) return 0;
    // `ptr`, one past the byte git points at, so that it stays unsigned.
    var ptr: usize = text.len;
    if (text[ptr - 1] == '\n') ptr -= 1;
    var count: u32 = 0;
    while (ptr > 1) {
        const eol = std.mem.findScalarLast(u8, text[0..ptr], '\n');
        const line_start = if (eol) |e| e + 1 else 0;
        if (!whitespace.blankLine(text[line_start..ptr])) break;
        count += 1;
        ptr = eol orelse break;
    }
    return count;
}

/// git's `count_lines`: a last line without its ending counts.
fn countLines(text: []const u8) u32 {
    var n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    if (text.len != 0 and text[text.len - 1] != '\n') n += 1;
    return n;
}
