//! git's word diff: `--word-diff`, `--word-diff-regex` and `--color-words`
//! (git 2.55's `diff_words_*` in `diff.c`). The removed and added lines of
//! a run are gathered until a context line, a hunk or the end, cut into
//! words -- what the word regex matches, cut at a newline, or else the runs
//! of bytes that are no space -- and the two lists of words diffed with no
//! context. The words both sides keep are written as the new side has them,
//! with what lies between them; the removed and added ones in the style's
//! marks: `[-...-]{+...+}` (plain), a line each after `-`, `+` or ` ` with
//! `~` for a newline (porcelain), or colour alone (color). Context lines
//! are written without their sign.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const parallax = @import("parallax");

const ere = @import("../text.zig").ere;
const ctype = @import("../text.zig").ctype;
const color = @import("../config/color.zig");
const paint_mod = @import("paint.zig");

/// Errors from a word diff.
pub const Error = error{
    /// The word regex's search took more work than the matcher's budget.
    PatternTooComplex,
} || parallax.Differ.Error || Allocator.Error || Io.Writer.Error;

/// How changed words are shown: `--word-diff=<mode>`.
pub const Style = enum { none, plain, porcelain, color };

/// One kind of text in a style: what goes before and after it, and its
/// colour.
const Mark = struct { prefix: []const u8, suffix: []const u8, color: []const u8 = "" };

/// git's `diff_words_styles`.
const Marks = struct { new: Mark, old: Mark, context: Mark, newline: []const u8 };

fn marksOf(style: Style, colors: ?*const paint_mod.Colors) Marks {
    var marks: Marks = switch (style) {
        .porcelain => .{ .new = .{ .prefix = "+", .suffix = "\n" }, .old = .{ .prefix = "-", .suffix = "\n" }, .context = .{ .prefix = " ", .suffix = "\n" }, .newline = "~\n" },
        .plain => .{ .new = .{ .prefix = "{+", .suffix = "+}" }, .old = .{ .prefix = "[-", .suffix = "-]" }, .context = .{ .prefix = "", .suffix = "" }, .newline = "\n" },
        .color, .none => .{ .new = .{ .prefix = "", .suffix = "" }, .old = .{ .prefix = "", .suffix = "" }, .context = .{ .prefix = "", .suffix = "" }, .newline = "\n" },
    };
    if (colors) |c| {
        marks.old.color = c.old.bytes();
        marks.new.color = c.new.bytes();
        marks.context.color = c.context.bytes();
    }
    return marks;
}

/// A painter that writes a patch's content lines as a word diff, handing
/// the file and hunk lines to `inner`. `finish` writes what is gathered at
/// the end and reports what went wrong on the way. It must not move once
/// painting.
pub const Painter = struct {
    gpa: Allocator,
    style: Style,
    /// `null` cuts words at spaces.
    regex: ?*const ere.Regex,
    colors: ?*const paint_mod.Colors,
    inner: parallax.Paint,
    minus: std.ArrayList(u8) = .empty,
    plus: std.ArrayList(u8) = .empty,
    failed: ?Self.Error = null,

    pub fn deinit(p: *Painter) void {
        p.minus.deinit(p.gpa);
        p.plus.deinit(p.gpa);
        p.* = undefined;
    }

    pub fn paint(p: *Painter) parallax.Paint {
        return .{ .context = p, .write = write };
    }

    /// Write what is still gathered, as git's `free_diff_words_data` does.
    pub fn finish(p: *Painter, w: *Io.Writer) Self.Error!void {
        if (p.failed) |err| return err;
        try p.show(w);
    }

    fn write(context: ?*const anyopaque, w: *Io.Writer, line: parallax.Paint.Line) Io.Writer.Error!void {
        const p: *Painter = @ptrCast(@alignCast(@constCast(context.?))); // safe: `paint` hands its own *Painter
        if (p.failed != null) return error.WriteFailed;
        p.take(w, line) catch |err| {
            p.failed = err;
            return error.WriteFailed;
        };
    }

    /// git's `fn_out_consume` under a word diff. xdiff hands each content
    /// line on with a newline, the last line of a file without one too,
    /// its marker after it.
    fn take(p: *Painter, w: *Io.Writer, line: parallax.Paint.Line) Self.Error!void {
        const ended = line.text.len != 0 and line.text[line.text.len - 1] == '\n';
        switch (line.kind) {
            .old_file, .new_file => try p.inner.write(p.inner.context, w, line),
            .hunk => {
                try p.show(w);
                try p.inner.write(p.inner.context, w, line);
            },
            .old, .new => {
                const side = if (line.kind == .old) &p.minus else &p.plus;
                try side.appendSlice(p.gpa, line.text);
                if (!ended) try side.append(p.gpa, '\n');
            },
            // Eaten as a line with nothing on it: more added lines may follow.
            .incomplete => {},
            .context => {
                try p.show(w);
                // The line as git has it: its sign (none for a blank line
                // under `suppress_blank_empty`), its text, its newline.
                var buf: [1]u8 = .{line.sign};
                const sign: []const u8 = if (line.sign != 0) &buf else "";
                const whole = try std.mem.concat(p.gpa, u8, &.{ sign, line.text, if (ended) "" else "\n" });
                defer p.gpa.free(whole);
                if (p.style == .porcelain) {
                    try writeLine(w, p.colors, whole);
                    try w.writeAll("~\n");
                } else {
                    // `DIFF_SYMBOL_WORDS` skips the line's first byte.
                    try writeLine(w, p.colors, whole[1..]);
                }
            },
        }
    }

    /// git's `diff_words_show`: the gathered lines as a word diff.
    fn show(p: *Painter, w: *Io.Writer) Self.Error!void {
        if (p.minus.items.len == 0 and p.plus.items.len == 0) return;
        defer p.minus.clearRetainingCapacity();
        defer p.plus.clearRetainingCapacity();
        const marks = marksOf(p.style, p.colors);
        const minus = p.minus.items;
        const plus = p.plus.items;
        if (plus.len == 0) return writeMarked(w, marks.old, marks.newline, minus);

        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const old = try Words.fill(a, minus, p.regex);
        const new = try Words.fill(a, plus, p.regex);
        var old_list = old.list;
        var new_list = new.list;
        trimCommonTail(&old_list, &new_list);

        var differ: parallax.Differ = .init(p.gpa);
        defer differ.deinit();
        const diff = try differ.lines(old_list, new_list, .{ .algorithm = .myers, .indent_heuristic = false });
        var hunks = diff.hunks(.{ .context = 0, .inter_hunk_context = 0 });
        var current: usize = 0;
        while (hunks.next()) |h| {
            // git's `fn_out_diff_words_aux`, the words numbered from one
            // after the empty word at zero.
            const minus_at = old.span(h.old_start, h.old_len);
            const plus_at = new.span(h.new_start, h.new_len);
            if (current != plus_at.start) try writeMarked(w, marks.context, marks.newline, plus[current..plus_at.start]);
            if (minus_at.start != minus_at.end) try writeMarked(w, marks.old, marks.newline, minus[minus_at.start..minus_at.end]);
            if (plus_at.start != plus_at.end) try writeMarked(w, marks.new, marks.newline, plus[plus_at.start..plus_at.end]);
            current = plus_at.end;
        }
        if (current != plus.len) try writeMarked(w, marks.context, marks.newline, plus[current..]);
    }
};

/// A side's words: where each is in the text, the empty word at zero
/// first, and the words one to a line, as xdiff is handed them.
const Words = struct {
    spans: []const ere.Match,
    list: []const u8,

    /// git's `diff_words_fill`.
    fn fill(a: Allocator, text: []const u8, regex: ?*const ere.Regex) Self.Error!Words {
        var spans: std.ArrayList(ere.Match) = .empty;
        var list: std.ArrayList(u8) = .empty;
        try spans.append(a, .{ .start = 0, .end = 0 });
        var at: usize = 0;
        while (at < text.len) {
            const word = (try nextWord(text, regex, at)) orelse break;
            try spans.append(a, word);
            try list.appendSlice(a, text[word.start..word.end]);
            try list.append(a, '\n');
            at = word.end;
        }
        return .{ .spans = spans.items, .list = list.items };
    }

    /// Where the `len` words from zero-based `start` lie, or for none the
    /// point after the word before.
    fn span(words: Words, start: u32, len: u32) ere.Match {
        if (len == 0) {
            const end = words.spans[start].end;
            return .{ .start = end, .end = end };
        }
        return .{ .start = words.spans[start + 1].start, .end = words.spans[start + len].end };
    }
};

/// git's `find_word_boundaries`: the next word at or after `begin`, `null`
/// when there is none.
fn nextWord(text: []const u8, regex: ?*const ere.Regex, from: usize) Self.Error!?ere.Match {
    var begin = from;
    if (regex) |re| {
        while (begin < text.len) {
            var groups: [ere.Regex.max_groups]?ere.Match = undefined;
            const found = (try re.findGroups(text[begin..], &groups)) orelse return null;
            const start = begin + found.start;
            var end = begin + found.end;
            if (std.mem.findScalar(u8, text[start..end], '\n')) |nl| end = start + nl;
            if (start == end) {
                // An empty match: try again a byte on.
                begin = start + 1;
                continue;
            }
            return .{ .start = start, .end = end };
        }
        return null;
    }
    while (begin < text.len and ctype.isSpace(text[begin])) begin += 1;
    if (begin >= text.len) return null;
    var end = begin + 1;
    while (end < text.len and !ctype.isSpace(text[end])) end += 1;
    return .{ .start = begin, .end = end };
}

/// xdiff's `trim_common_tail`, which a diff with no context makes first:
/// whole blocks of 1024 bytes the two ends share, given back to the last
/// line ending in them.
fn trimCommonTail(a: *[]const u8, b: *[]const u8) void {
    const block = 1024;
    var trimmed: usize = 0;
    const smaller = @min(a.len, b.len);
    while (block + trimmed <= smaller and std.mem.eql(u8, a.*[a.len - trimmed - block .. a.len - trimmed], b.*[b.len - trimmed - block .. b.len - trimmed])) trimmed += block;
    var recovered: usize = 0;
    const tail = a.*[a.len - trimmed ..];
    while (recovered < trimmed) {
        recovered += 1;
        if (tail[recovered - 1] == '\n') break;
    }
    a.* = a.*[0 .. a.len - (trimmed - recovered)];
    b.* = b.*[0 .. b.len - (trimmed - recovered)];
}

/// git's `fn_out_diff_words_write_helper`: `text` in `mark`, a line at a
/// time, each newline written as the style's.
fn writeMarked(w: *Io.Writer, mark: Mark, newline: []const u8, text: []const u8) Io.Writer.Error!void {
    var rest = text;
    while (rest.len != 0) {
        const nl = std.mem.findScalar(u8, rest, '\n');
        const part = rest[0 .. nl orelse rest.len];
        if (part.len != 0) {
            try w.writeAll(mark.color);
            try w.writeAll(mark.prefix);
            try w.writeAll(part);
            try w.writeAll(mark.suffix);
            if (mark.color.len != 0) try w.writeAll(color.reset);
        }
        const at = nl orelse return;
        try w.writeAll(newline);
        rest = rest[at + 1 ..];
    }
}

/// git's `emit_line` of a context line in the context colour: its ending
/// kept outside the colour, a line with nothing before it written bare.
fn writeLine(w: *Io.Writer, colors: ?*const paint_mod.Colors, text: []const u8) Io.Writer.Error!void {
    var body = text;
    const newline = body.len != 0 and body[body.len - 1] == '\n';
    if (newline) body = body[0 .. body.len - 1];
    const cr = body.len != 0 and body[body.len - 1] == '\r';
    if (cr) body = body[0 .. body.len - 1];
    if (body.len != 0) {
        if (colors) |c| try w.writeAll(c.context.bytes());
        try w.writeAll(body);
        if (colors != null) try w.writeAll(color.reset);
    }
    if (cr) try w.writeByte('\r');
    if (newline) try w.writeByte('\n');
}

test "words are cut at spaces, or where a regex says, cut again at a newline" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const spaced = try Words.fill(arena.allocator(), "one  two\nthree\n", null);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", spaced.list);
    var re = try ere.Regex.compile(gpa, "[a-z]+|.", .{});
    defer re.deinit();
    const by_regex = try Words.fill(arena.allocator(), "ab,c d", &re);
    try std.testing.expectEqualStrings("ab\n,\nc\n \nd\n", by_regex.list);
}
