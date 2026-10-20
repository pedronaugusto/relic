//! Moved lines in colour: git's `--color-moved` and `diff.colorMoved`.
//!
//! git finds lines that moved over the whole of a diff, every file of it:
//! the painter records the diff (`paint.Recorder`), this marks the removed
//! and added lines that moved, and the painter replays the record with the
//! `*Moved*` slots, as git's `diff_flush_patch_all_file_pairs` does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parallax = @import("parallax");
const config_mod = @import("../config/config.zig");

const isSpace = parallax.compare.isSpace;

/// How moved lines are shown: git's `--color-moved` modes.
pub const ColorMoved = enum {
    /// Not at all, git's default.
    no,
    /// Every moved line, however short its block.
    plain,
    /// Blocks of at least twenty alphanumeric characters.
    blocks,
    /// As `blocks`, the second of two adjacent blocks in the alternative
    /// colours: git's `default`.
    zebra,
    /// As `zebra`, the lines inside a block dimmed.
    dimmed_zebra,

    /// A value as git's `parse_color_moved` reads it: one of git's
    /// boolean spellings (true is `zebra`), a bare name included, or a
    /// mode by its name. `null` for a value git refuses.
    pub fn parse(value: ?[]const u8) ?ColorMoved {
        const text = value orelse return .zebra;
        if (config_mod.parseBool(text)) |on| return if (on) .zebra else .no else |_| {}
        const names = [_]struct { []const u8, ColorMoved }{
            .{ "no", .no },                     .{ "plain", .plain },
            .{ "blocks", .blocks },             .{ "zebra", .zebra },
            .{ "default", .zebra },             .{ "dimmed-zebra", .dimmed_zebra },
            .{ "dimmed_zebra", .dimmed_zebra },
        };
        for (names) |entry| if (std.mem.eql(u8, text, entry[0])) return entry[1];
        return null;
    }
};

/// Which whitespace two lines may differ in and still be the same moved
/// line: git's `--color-moved-ws` and `diff.colorMovedWS`.
pub const ColorMovedWs = struct {
    ignore_space_change: bool = false,
    ignore_space_at_eol: bool = false,
    ignore_all_space: bool = false,
    /// Lines that differ only in their indentation, by the same amount
    /// over a whole block.
    allow_indentation_change: bool = false,

    /// A value as git's `parse_color_moved_ws` reads it: modes split at
    /// commas and trimmed, `no` clearing what came before;
    /// `allow-indentation-change` alone. `null` for a value git refuses.
    pub fn parse(text: []const u8) ?ColorMovedWs {
        var out: ColorMovedWs = .{};
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |raw| {
            const mode = std.mem.trim(u8, raw, " \t\n\r");
            if (std.mem.eql(u8, mode, "no")) {
                out = .{};
            } else if (std.mem.eql(u8, mode, "ignore-space-change")) {
                out.ignore_space_change = true;
            } else if (std.mem.eql(u8, mode, "ignore-space-at-eol")) {
                out.ignore_space_at_eol = true;
            } else if (std.mem.eql(u8, mode, "ignore-all-space")) {
                out.ignore_all_space = true;
            } else if (std.mem.eql(u8, mode, "allow-indentation-change")) {
                out.allow_indentation_change = true;
            } else return null;
        }
        if (out.allow_indentation_change and out.compare().whitespace.any()) return null;
        return out;
    }

    /// What counts as the same line.
    fn compare(ws: ColorMovedWs) parallax.Compare {
        return .{ .whitespace = .{ .all = ws.ignore_all_space, .change = ws.ignore_space_change, .at_eol = ws.ignore_space_at_eol } };
    }
};

/// git's `COLOR_MOVED_MIN_ALNUM_COUNT`.
const min_alnum_count = 20;

/// git's `INDENT_BLANKLINE`.
const blank_line = std.math.minInt(i32);

/// git's `DIFF_SYMBOL_MOVED_LINE*` flags.
pub const Flags = packed struct(u3) {
    moved: bool = false,
    alternative: bool = false,
    uninteresting: bool = false,

    fn zebra(f: Flags) Flags {
        return .{ .moved = f.moved, .alternative = f.alternative };
    }
};

/// A removed or added line of a diff, as moved lines are found among them.
pub const Line = struct {
    kind: Kind,
    /// With its ending: one is added where the line has none, as git's
    /// xdiff hands every line on.
    text: []const u8,
    /// The tab width of its file's whitespace rule, for
    /// `allow-indentation-change`.
    tab_width: u32 = 8,
    /// What the marking finds.
    flags: Flags = .{},
    id: u32 = 0,
    indent_off: usize = 0,
    indent_width: i32 = 0,

    pub const Kind = enum { old, new };
};

/// Mark the lines that moved, as git's `add_lines_to_move_detection`,
/// `mark_color_as_moved` and, for `dimmed_zebra`, `dim_moved_lines` mark
/// them. `symbols` is the diff in order: a line by its index in `lines`,
/// `null` for anything else written between two of them.
pub fn mark(gpa: Allocator, mode: ColorMoved, ws: ColorMovedWs, lines: []Line, symbols: []const ?u32) Allocator.Error!void {
    if (mode == .no or lines.len == 0) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Marker = .{ .mode = mode, .ws = ws, .lines = lines, .symbols = symbols, .next_line = try arena.alloc(?u32, lines.len), .next_match = try arena.alloc(?u32, lines.len) };
    try m.build(arena);
    try m.markMoved(arena);
    if (mode == .dimmed_zebra) m.dim();
}

const Marker = struct {
    mode: ColorMoved,
    ws: ColorMovedWs,
    lines: []Line,
    symbols: []const ?u32,
    /// The lines of each class, git's `moved_entry_list`, and each line's
    /// successor of its own kind, `next_line`.
    heads: std.ArrayList(Head) = .empty,
    next_line: []?u32,
    next_match: []?u32,

    const Head = struct { add: ?u32 = null, del: ?u32 = null };

    pub const KeyContext = struct {
        compare: parallax.Compare,

        pub fn hash(c: KeyContext, key: []const u8) u64 {
            return parallax.compare.hash(key, c.compare);
        }

        pub fn eql(c: KeyContext, a: []const u8, b: []const u8) bool {
            return parallax.compare.sameForm(a, b, c.compare);
        }
    };

    /// git's `moved_block`.
    const Block = struct { match: ?u32, wsd: i32 };

    /// git's `add_lines_to_move_detection`.
    fn build(m: *Marker, arena: Allocator) Allocator.Error!void {
        @memset(m.next_line, null);
        @memset(m.next_match, null);
        const context: KeyContext = .{ .compare = m.ws.compare() };
        var interned: std.HashMapUnmanaged([]const u8, u32, KeyContext, std.hash_map.default_max_load_percentage) = .empty;
        var prev: ?u32 = null;
        for (m.symbols) |sym| {
            const i = sym orelse {
                prev = null;
                continue;
            };
            const l = &m.lines[i];
            if (m.ws.allow_indentation_change) fillIndent(l);
            const gop = try interned.getOrPutContext(arena, l.text[l.indent_off..], context);
            if (gop.found_existing) {
                l.id = gop.value_ptr.*;
            } else {
                l.id = @intCast(m.heads.items.len);
                gop.value_ptr.* = l.id;
                try m.heads.append(arena, .{});
            }
            if (prev) |p| if (m.lines[p].kind == l.kind) {
                m.next_line[p] = i;
            };
            prev = i;
            const head = &m.heads.items[l.id];
            if (l.kind == .new) {
                m.next_match[i] = head.add;
                head.add = i;
            } else {
                m.next_match[i] = head.del;
                head.del = i;
            }
        }
    }

    /// git's `mark_color_as_moved`, with its rewinds.
    fn markMoved(m: *Marker, arena: Allocator) Allocator.Error!void {
        const syms = m.symbols;
        var pmb: std.ArrayList(Block) = .empty;
        var flipped = false;
        var block_length: usize = 0;
        var moved_symbol: ?Line.Kind = null;
        var n: usize = 0;
        while (n < syms.len) : (n += 1) {
            var match: ?u32 = null;
            const kind: ?Line.Kind = if (syms[n]) |i| m.lines[i].kind else null;
            if (syms[n]) |i| {
                const head = m.heads.items[m.lines[i].id];
                match = if (m.lines[i].kind == .new) head.del else head.add;
            } else flipped = false;

            if (pmb.items.len != 0 and (match == null or kind != moved_symbol)) {
                if (!m.adjustLastBlock(n, block_length) and block_length > 1) {
                    // Rewind in case another match starts at the block's
                    // second line.
                    match = null;
                    n -= block_length;
                }
                pmb.clearRetainingCapacity();
                block_length = 0;
                flipped = false;
            }
            const first = match orelse {
                moved_symbol = null;
                continue;
            };
            const l = &m.lines[syms[n].?];
            if (m.mode == .plain) {
                l.flags.moved = true;
                continue;
            }
            m.advance(l, &pmb);
            if (pmb.items.len == 0) {
                const contiguous = m.adjustLastBlock(n, block_length);
                if (!contiguous and block_length > 1) {
                    n -= block_length;
                } else {
                    var at: ?u32 = first;
                    while (at) |a| : (at = m.next_match[a]) {
                        const wsd: i32 = if (m.ws.allow_indentation_change) wsDelta(l, &m.lines[a]) else 0;
                        try pmb.append(arena, .{ .match = a, .wsd = wsd });
                    }
                }
                flipped = if (contiguous and pmb.items.len != 0 and moved_symbol == l.kind) !flipped else false;
                moved_symbol = if (pmb.items.len != 0) l.kind else null;
                block_length = 0;
            }
            if (pmb.items.len != 0) {
                block_length += 1;
                l.flags.moved = true;
                if (flipped and m.mode != .blocks) l.flags.alternative = true;
            }
        }
        _ = m.adjustLastBlock(syms.len, block_length);
    }

    /// git's `pmb_advance_or_null`: the blocks that go on to `l`.
    fn advance(m: *Marker, l: *const Line, pmb: *std.ArrayList(Block)) void {
        var j: usize = 0;
        for (pmb.items) |*block| {
            const cur: ?u32 = if (block.match) |prev| m.next_line[prev] else null;
            const matched = if (cur) |c|
                (if (m.ws.allow_indentation_change) sameInBlock(&m.lines[c], l, block) else m.lines[c].id == l.id)
            else
                false;
            if (matched) {
                pmb.items[j] = block.*;
                pmb.items[j].match = cur;
                j += 1;
            }
        }
        pmb.items.len = j;
    }

    /// git's `adjust_last_block`: whether the block of `length` lines
    /// before `n` holds twenty alphanumeric characters; when it does not,
    /// its lines are not moved.
    fn adjustLastBlock(m: *Marker, n: usize, length: usize) bool {
        if (m.mode == .plain) return length != 0;
        var count: usize = 0;
        for (1..length + 1) |i| {
            // git counts up to the first NUL of its copy
            for (m.lines[m.symbols[n - i].?].text) |c| {
                if (c == 0) break;
                if (!std.ascii.isAlphanumeric(c)) continue;
                count += 1;
                if (count >= min_alnum_count) return true;
            }
        }
        for (1..length + 1) |i| {
            const flags = &m.lines[m.symbols[n - i].?].flags;
            flags.moved = false;
            flags.alternative = false;
        }
        return false;
    }

    /// git's `dim_moved_lines`.
    fn dim(m: *Marker) void {
        const syms = m.symbols;
        for (syms, 0..) |sym, n| {
            const l = &m.lines[sym orelse continue];
            if (!l.flags.moved) continue;
            const prev: ?*const Line = if (n != 0) if (syms[n - 1]) |i| &m.lines[i] else null else null;
            const next: ?*const Line = if (n + 1 < syms.len) if (syms[n + 1]) |i| &m.lines[i] else null else null;
            if (prev != null and prev.?.flags.zebra() == l.flags.zebra() and
                next != null and next.?.flags.zebra() == l.flags.zebra())
            {
                l.flags.uninteresting = true;
                continue;
            }
            if (prev) |p| if (p.flags.moved and p.flags.alternative != l.flags.alternative) continue;
            if (next) |x| if (x.flags.moved and x.flags.alternative != l.flags.alternative) continue;
            l.flags.uninteresting = true;
        }
    }
};

/// git's `fill_es_indent_data`: where a line's indentation ends and how
/// wide it is, tabs to `tab_width`; a blank line's text is empty.
fn fillIndent(l: *Line) void {
    const line = l.text;
    const tab_width = @max(l.tab_width, 1);
    const at = struct {
        fn byte(s: []const u8, i: usize) u8 {
            return if (i < s.len) s[i] else 0;
        }
    }.byte;
    var off: usize = 0;
    while (at(line, off) == '\x0c' or at(line, off) == '\x0b' or (off + 1 < line.len and line[off] == '\r')) off += 1;
    var width: u32 = 0;
    while (true) {
        if (at(line, off) == ' ') {
            width += 1;
            off += 1;
        } else if (at(line, off) == '\t') {
            width += tab_width - (width % tab_width);
            off += 1;
            while (at(line, off) == '\t') : (off += 1) width += tab_width;
        } else break;
    }
    var i = off;
    while (i < line.len and isSpace(line[i])) i += 1;
    if (i >= line.len) {
        l.indent_width = blank_line;
        l.indent_off = line.len;
    } else {
        l.indent_off = off;
        l.indent_width = @bitCast(width);
    }
}

/// git's `compute_ws_delta`.
fn wsDelta(a: *const Line, b: *const Line) i32 {
    if (a.indent_width == blank_line and b.indent_width == blank_line) return blank_line;
    return a.indent_width -% b.indent_width;
}

/// git's `cmp_in_block_with_wsd`, true where git's gives zero: the same
/// text, its indentation moved by the block's delta.
fn sameInBlock(cur: *const Line, l: *const Line, block: *Marker.Block) bool {
    if (cur.id != l.id) return false;
    if (cur.indent_width == blank_line) return true;
    const delta = l.indent_width -% cur.indent_width;
    if (block.wsd == blank_line) block.wsd = delta;
    return delta == block.wsd;
}

test "colorMoved and colorMovedWS read as git reads them" {
    try std.testing.expectEqual(ColorMoved.zebra, ColorMoved.parse(null).?);
    try std.testing.expectEqual(ColorMoved.no, ColorMoved.parse("").?);
    try std.testing.expectEqual(ColorMoved.zebra, ColorMoved.parse("YES").?);
    try std.testing.expectEqual(ColorMoved.no, ColorMoved.parse("0").?);
    try std.testing.expectEqual(ColorMoved.zebra, ColorMoved.parse("1k").?);
    try std.testing.expectEqual(ColorMoved.dimmed_zebra, ColorMoved.parse("dimmed_zebra").?);
    try std.testing.expectEqual(ColorMoved.zebra, ColorMoved.parse("default").?);
    try std.testing.expect(ColorMoved.parse("Zebra") == null);

    try std.testing.expectEqual(ColorMovedWs{ .ignore_space_change = true, .ignore_space_at_eol = true }, ColorMovedWs.parse(" ignore-space-change ,ignore-space-at-eol").?);
    try std.testing.expectEqual(ColorMovedWs{ .allow_indentation_change = true }, ColorMovedWs.parse("ignore-all-space,no,allow-indentation-change").?);
    try std.testing.expect(ColorMovedWs.parse("allow-indentation-change,ignore-all-space") == null);
    try std.testing.expect(ColorMovedWs.parse("") == null);
    try std.testing.expect(ColorMovedWs.parse("no,,no") == null);
    try std.testing.expectEqual(ColorMovedWs{}, ColorMovedWs.parse("no").?);
}
