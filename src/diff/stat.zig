//! git's `--stat` and `--summary`: the diffstat `show_stats` writes, its
//! counts as `builtin_diffstat` makes them, the widths `git diff` and `git
//! log` take from `diff.statNameWidth` and `diff.statGraphWidth`, and the
//! lines `diff_summary` writes for a created, deleted, renamed, copied or
//! re-moded file.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const c_quote = @import("../text.zig").c_quote;
const unicode_width = @import("../text.zig").unicode_width;
const config_mod = @import("../config/config.zig");
const color = @import("../config/color.zig");
const object = @import("../object/object.zig");
const paint = @import("paint.zig");
const diff = @import("diff.zig");

/// One file of a diffstat.
pub const File = struct {
    /// Where a rename or copy came from, which the stat names as
    /// `pfx{old => new}sfx`.
    from: ?[]const u8 = null,
    name: []const u8,
    /// Lines added and deleted; for a binary file, its size after and
    /// before, in bytes.
    added: usize = 0,
    deleted: usize = 0,
    kind: Kind = .text,

    pub const Kind = enum {
        text,
        /// `Bin <before> -> <after> bytes`.
        binary,
        /// `Unmerged`, counted in no total.
        unmerged,
    };
};

/// The columns a diffstat may take.
pub const Widths = struct {
    /// The whole line: git's `--stat-width`, else the terminal's columns.
    width: usize = 80,
    /// The most the names may take: `--stat-name-width`,
    /// `diff.statNameWidth`. `null` lets them have what they need.
    name: ?usize = null,
    /// The most the `+-` graph may take: `--stat-graph-width`,
    /// `diff.statGraphWidth`. `null` lets it have what it needs.
    graph: ?usize = null,
    /// How many files are listed before `...`: `--stat-count`.
    count: ?usize = null,

    /// `widths` with `diff.statNameWidth` and `diff.statGraphWidth` where
    /// it gives none, as `git diff` and `git log` take them
    /// (`init_diffstat_widths`); zero sets no limit. A negative one sets
    /// none either, where git compares it unsigned and neither scales nor
    /// fits the graph.
    /// `git format-patch` reads neither.
    pub fn configured(config: *const config_mod.Config, widths: Widths) config_mod.ValueError!Widths {
        var out = widths;
        if (out.name == null) out.name = limit(try config.getInt("diff.statnamewidth", 0));
        if (out.graph == null) out.graph = limit(try config.getInt("diff.statgraphwidth", 0));
        return out;
    }

    fn limit(value: i64) ?usize {
        return if (value > 0) @intCast(value) else null;
    }
};

/// How a diffstat is written.
pub const WriteOptions = struct {
    widths: Widths = .{},
    /// `core.quotePath`: names with bytes past ASCII quoted too.
    quote_path: bool = true,
    /// The `new` and `old` colours paint the graph and the byte counts,
    /// as `--color` does. `null` writes no colour.
    colors: ?*const paint.Colors = null,
};

pub const Error = diff.NumstatError;

/// The diffstat of `inputs.changes`, in their order, as git's
/// `builtin_diffstat` counts it: lines added and deleted, a gitlink as its
/// `Subproject commit` line; for a file either side of which is binary,
/// its sizes, none where the two sides are one object. Names are the
/// changes' paths. The result is `a`'s.
pub fn files(a: Allocator, io: Io, inputs: diff.NumstatInputs, options: diff.Options) Error![]File {
    const counts = try diff.numstat(a, io, inputs, options);
    defer a.free(counts);
    const out = try a.alloc(File, counts.len);
    for (inputs.changes, counts, out) |c, n, *f| {
        f.* = .{
            .from = if (c.status == .renamed or c.status == .copied) c.old.?.path else null,
            .name = c.path(),
            .added = n.plus,
            .deleted = n.minus,
        };
        if (!n.binary) continue;
        f.kind = .binary;
        f.added = 0;
        f.deleted = 0;
        if (c.old != null and c.new != null and c.old.?.oid.eql(c.new.?.oid)) continue;
        if (c.new) |e| f.added = (try inputs.db.readHeader(io, e.oid)).size;
        if (c.old) |e| f.deleted = (try inputs.db.readHeader(io, e.oid)).size;
    }
    return out;
}

/// Append the diffstat of `list` to `out`, as git's `show_stats` writes
/// it: a line for each file, at most `count` of them and then ` ...`,
/// then the totals. Nothing for no files.
pub fn write(a: Allocator, out: *std.ArrayList(u8), list: []const File, options: WriteOptions) Allocator.Error!void {
    if (list.len == 0) return;
    const widths = options.widths;
    const shown = @min(widths.count orelse list.len, list.len);
    const names = try a.alloc([]const u8, shown);
    defer a.free(names);
    var max_change: usize = 0;
    var max_len: usize = 0;
    var number_width: usize = 0;
    var bin_width: usize = 0;
    for (list[0..shown], names) |f, *name| {
        name.* = try printName(a, f.from, f.name, options.quote_path);
        max_len = @max(max_len, unicode_width.strWidth(name.*));
        switch (f.kind) {
            // "Unmerged" is 8 columns.
            .unmerged => bin_width = @max(bin_width, 8),
            .binary => {
                bin_width = @max(bin_width, 14 + decimalWidth(f.added) + decimalWidth(f.deleted));
                number_width = 3;
            },
            .text => max_change = @max(max_change, f.added + f.deleted),
        }
    }
    number_width = @max(decimalWidth(max_change), number_width);
    const width = @max(widths.width, 16 + 6 + number_width);
    var graph_width: usize = if (max_change + 4 > bin_width) max_change else bin_width - 4;
    if (widths.graph) |g| graph_width = @min(graph_width, g);
    var name_width: usize = if (widths.name) |n| @min(n, max_len) else max_len;
    if (name_width + number_width + 6 + graph_width > width) {
        const limit: i64 = @as(i64, @intCast(width * 3 / 8)) - @as(i64, @intCast(number_width)) - 6;
        if (@as(i64, @intCast(graph_width)) > limit) graph_width = if (limit < 6) 6 else @intCast(limit);
        if (widths.graph) |g| graph_width = @min(graph_width, g);
        if (name_width > width - number_width - 6 - graph_width) {
            name_width = width - number_width - 6 - graph_width;
        } else graph_width = width - number_width - 6 - name_width;
    }
    const reset: []const u8 = if (options.colors != null) color.reset else "";
    const add_c: []const u8 = if (options.colors) |c| c.new.bytes() else "";
    const del_c: []const u8 = if (options.colors) |c| c.old.bytes() else "";
    for (list[0..shown], names) |f, full| {
        try writeName(a, out, full, name_width);
        switch (f.kind) {
            .binary => {
                try out.appendNTimes(a, ' ', number_width -| 3);
                try out.appendSlice(a, "Bin");
                if (f.added == 0 and f.deleted == 0) {
                    try out.append(a, '\n');
                    continue;
                }
                try out.print(a, " {s}{d}{s} -> {s}{d}{s} bytes\n", .{ del_c, f.deleted, reset, add_c, f.added, reset });
            },
            .unmerged => {
                try out.appendNTimes(a, ' ', number_width -| 8);
                try out.appendSlice(a, "Unmerged\n");
            },
            .text => {
                var add = f.added;
                var del = f.deleted;
                if (graph_width <= max_change) {
                    var total = scaleLinear(add + del, graph_width, max_change);
                    if (total < 2 and add != 0 and del != 0) total = 2;
                    if (add < del) {
                        add = scaleLinear(add, graph_width, max_change);
                        del = total - add;
                    } else {
                        del = scaleLinear(del, graph_width, max_change);
                        add = total - del;
                    }
                }
                const changed = f.added + f.deleted;
                try out.appendNTimes(a, ' ', number_width -| decimalWidth(changed));
                try out.print(a, "{d}{s}", .{ changed, if (changed != 0) " " else "" });
                try graph(a, out, '+', add, add_c, reset);
                try graph(a, out, '-', del, del_c, reset);
                try out.append(a, '\n');
            },
        }
    }
    var counted: usize = 0;
    var insertions: usize = 0;
    var deletions: usize = 0;
    for (list) |f| switch (f.kind) {
        .unmerged => {},
        .binary => counted += 1,
        .text => {
            counted += 1;
            insertions += f.added;
            deletions += f.deleted;
        },
    };
    if (shown < list.len) try out.appendSlice(a, " ...\n");
    try writeTotals(a, out, counted, insertions, deletions);
}

/// ` <name><padding> | `, the name cut from the left to `name_width`
/// columns behind `...` and then to its first `/`, as git's `show_stats`
/// scales it.
fn writeName(a: Allocator, out: *std.ArrayList(u8), full: []const u8, name_width: usize) Allocator.Error!void {
    var prefix: []const u8 = "";
    var name = full;
    var len: isize = @intCast(name_width);
    var name_len = unicode_width.strWidth(name);
    if (name_width < name_len) {
        prefix = "...";
        len = @max(len - 3, 0);
        while (name_len > len and name.len > 0) {
            const decoded = unicode_width.decode(name);
            const step: usize = if (decoded) |cp| cp.len else 1;
            const cp_width: usize = if (decoded) |cp| @intCast(@max(unicode_width.width(cp.char), 0)) else 1;
            name_len -= cp_width;
            name = name[step..];
        }
        if (std.mem.findScalar(u8, name, '/')) |slash| name = name[slash..];
    }
    const name_w: isize = @intCast(unicode_width.strWidth(name));
    try out.print(a, " {s}{s}", .{ prefix, name });
    try out.appendNTimes(a, ' ', if (len - name_w < 0) 0 else @intCast(len - name_w));
    try out.appendSlice(a, " | ");
}

fn graph(a: Allocator, out: *std.ArrayList(u8), ch: u8, n: usize, set: []const u8, reset: []const u8) Allocator.Error!void {
    if (n == 0) return;
    try out.appendSlice(a, set);
    try out.appendNTimes(a, ch, n);
    try out.appendSlice(a, reset);
}

/// git's `print_stat_summary`: ` N files changed, N insertions(+), N
/// deletions(-)`, the insertions or deletions left out where they are none
/// and the other is not.
pub fn writeTotals(a: Allocator, out: *std.ArrayList(u8), changed: usize, insertions: usize, deletions: usize) Allocator.Error!void {
    if (changed == 0) {
        try out.appendSlice(a, " 0 files changed\n");
        return;
    }
    try out.print(a, " {d} file{s} changed", .{ changed, if (changed == 1) "" else "s" });
    if (insertions != 0 or deletions == 0) try out.print(a, ", {d} insertion{s}(+)", .{ insertions, if (insertions == 1) "" else "s" });
    if (deletions != 0 or insertions == 0) try out.print(a, ", {d} deletion{s}(-)", .{ deletions, if (deletions == 1) "" else "s" });
    try out.append(a, '\n');
}

/// The name a diffstat shows, as git's `fill_print_name`: quoted where it
/// needs it, a rename or copy as `pprint_rename` writes it.
pub fn printName(a: Allocator, from: ?[]const u8, name: []const u8, quote_path: bool) Allocator.Error![]const u8 {
    const old = from orelse return c_quote.alloc(a, name, quote_path);
    return renamed(a, old, name, quote_path);
}

/// `pfx{old => new}sfx`, git's `pprint_rename`: the leading and trailing
/// directories the two names share written once; both quoted in full
/// where either needs it.
pub fn renamed(a: Allocator, a_name: []const u8, b_name: []const u8, quote_path: bool) Allocator.Error![]const u8 {
    if (c_quote.needsQuote(a_name, quote_path) or c_quote.needsQuote(b_name, quote_path)) {
        return std.mem.concat(a, u8, &.{ try c_quote.alloc(a, a_name, quote_path), " => ", try c_quote.alloc(a, b_name, quote_path) });
    }
    var pfx_length: usize = 0;
    var i: usize = 0;
    while (i < a_name.len and i < b_name.len and a_name[i] == b_name[i]) : (i += 1) {
        if (a_name[i] == '/') pfx_length = i + 1;
    }
    // the common suffix, which must start at a slash; with a prefix the
    // scan may run onto the prefix's own slash
    var sfx_length: usize = 0;
    const adjust: usize = if (pfx_length != 0) 1 else 0;
    var oi: isize = @intCast(a_name.len);
    var ni: isize = @intCast(b_name.len);
    const floor: isize = @as(isize, @intCast(pfx_length)) - @as(isize, @intCast(adjust));
    while (oi >= floor and ni >= floor) {
        const oc: u8 = if (oi < a_name.len) a_name[@intCast(oi)] else 0;
        const nc: u8 = if (ni < b_name.len) b_name[@intCast(ni)] else 0;
        if (oc != nc) break;
        if (oc == '/') sfx_length = a_name.len - @as(usize, @intCast(oi));
        oi -= 1;
        ni -= 1;
    }
    const a_mid: usize = if (a_name.len >= pfx_length + sfx_length) a_name.len - pfx_length - sfx_length else 0;
    const b_mid: usize = if (b_name.len >= pfx_length + sfx_length) b_name.len - pfx_length - sfx_length else 0;
    var out: std.ArrayList(u8) = .empty;
    if (pfx_length + sfx_length > 0) {
        try out.appendSlice(a, a_name[0..pfx_length]);
        try out.append(a, '{');
    }
    try out.appendSlice(a, a_name[pfx_length..][0..a_mid]);
    try out.appendSlice(a, " => ");
    try out.appendSlice(a, b_name[pfx_length..][0..b_mid]);
    if (pfx_length + sfx_length > 0) {
        try out.append(a, '}');
        try out.appendSlice(a, a_name[a_name.len - sfx_length ..]);
    }
    return out.items;
}

/// Append the `--summary` lines of `changes`, as git's `diff_summary`
/// writes each: ` create mode`, ` delete mode`, ` rename`, ` copy` and `
/// mode change`. Nothing where none of them has one.
pub fn writeSummary(a: Allocator, out: *std.ArrayList(u8), changes: []const diff.Change, quote_path: bool) Allocator.Error!void {
    for (changes) |c| switch (c.status) {
        .added, .deleted, .renamed, .copied => break,
        else => if (c.old.?.mode != c.new.?.mode) break,
    } else return;
    for (changes) |c| switch (c.status) {
        .deleted => try out.print(a, " delete mode {o:0>6} {s}\n", .{ modeNum(c.old.?.mode), try c_quote.alloc(a, c.old.?.path, quote_path) }),
        .added => try out.print(a, " create mode {o:0>6} {s}\n", .{ modeNum(c.new.?.mode), try c_quote.alloc(a, c.new.?.path, quote_path) }),
        .renamed, .copied => {
            try out.print(a, " {s} {s} ({d}%)\n", .{ if (c.status == .copied) "copy" else "rename", try renamed(a, c.old.?.path, c.new.?.path, quote_path), c.similarity });
            if (c.old.?.mode != c.new.?.mode) try out.print(a, " mode change {o:0>6} => {o:0>6}\n", .{ modeNum(c.old.?.mode), modeNum(c.new.?.mode) });
        },
        else => if (c.old.?.mode != c.new.?.mode) {
            try out.print(a, " mode change {o:0>6} => {o:0>6} {s}\n", .{ modeNum(c.old.?.mode), modeNum(c.new.?.mode), try c_quote.alloc(a, c.new.?.path, quote_path) });
        },
    };
}

fn modeNum(m: object.Mode) u32 {
    return @backingInt(m);
}

fn decimalWidth(n: usize) usize {
    return std.fmt.count("{d}", .{n});
}

fn scaleLinear(it: usize, width: usize, max_change: usize) usize {
    if (it == 0) return 0;
    return 1 + (it * (width - 1) / max_change);
}
