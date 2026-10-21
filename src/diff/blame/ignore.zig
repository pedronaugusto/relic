//! Where an ignored commit's lines came from in its parent: git 2.55's
//! guess in `blame.c` (`guess_line_blames`), which `blame` asks for the
//! lines a change of an ignored commit touched.
//!
//! Each line has a fingerprint, the multiset of its lowercased byte pairs
//! with whitespace taken as one space and pairs of whitespace left out;
//! two lines are as similar as the size of their fingerprints' common
//! part. In each changed region the target line matched most surely -- its
//! best match much better than its second best -- is matched first, its
//! fingerprint taken out of the parent line it matched, and the lines
//! before and after it are matched within the parent lines before and
//! after, so the matches keep their order; each target line is compared
//! with the ten parent lines nearest where it would fall by position, the
//! nearer winning a tie. A line no part of the region matches is looked
//! for in the whole parent file, where it must share ten pairs or more.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ctype = @import("../../text.zig").ctype;

/// A line's byte pairs, each with how many times it occurs.
pub const Fingerprint = std.array_hash_map.Auto(u16, u32);

/// git's `get_fingerprint` of each line of `text`.
pub fn fingerprints(arena: Allocator, text: []const u8) Allocator.Error![]Fingerprint {
    var out: std.ArrayList(Fingerprint) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.findScalarPos(u8, text, start, '\n')) |nl| nl + 1 else text.len;
        try out.append(arena, try fingerprint(arena, text[start..end]));
        start = end;
    }
    return out.items;
}

fn fingerprint(arena: Allocator, line: []const u8) Allocator.Error!Fingerprint {
    var f: Fingerprint = .empty;
    var c0: u16 = 0;
    var p: usize = 0;
    // The line's end counts as whitespace.
    while (p <= line.len) : (p += 1) {
        const c1: u16 = if (p == line.len or ctype.isSpace(line[p])) 0 else std.ascii.toLower(line[p]);
        const pair = c0 | (c1 << 8);
        c0 = c1;
        if (pair == 0) continue;
        const slot = try f.getOrPut(arena, pair);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    }
    return f;
}

/// git's `fingerprint_similarity`.
fn similarity(a: *const Fingerprint, b: *const Fingerprint) i32 {
    var common: u32 = 0;
    var it = b.iterator();
    while (it.next()) |e| {
        if (a.get(e.key_ptr.*)) |count| common += @min(count, e.value_ptr.*);
    }
    return @intCast(common);
}

/// git's `fingerprint_subtract`: `b`'s pairs taken out of `a`.
fn subtract(a: *Fingerprint, b: *const Fingerprint) void {
    var it = b.iterator();
    while (it.next()) |e| {
        const slot = a.getPtr(e.key_ptr.*) orelse continue;
        if (slot.* <= e.value_ptr.*) {
            _ = a.swapRemove(e.key_ptr.*);
        } else slot.* -= e.value_ptr.*;
    }
}

/// Where each target line of a changed region is in the parent: its line
/// there, or `null` where it is the target's own.
pub const Guess = ?u32;

/// One changed region: the target's lines `target_start` up to
/// `target_end`, the parent's `parent_len` lines from `parent_start`.
pub const Region = struct {
    target_start: u32,
    target_end: u32,
    parent_start: u32,
    parent_len: u32,
};

/// git's `guess_line_blames` for one region. `parent` is changed: a match
/// takes its pairs out of the parent line, for the rest of this parent's
/// regions. The result is `arena`'s.
pub fn guess(arena: Allocator, parent: []Fingerprint, target: []const Fingerprint, region: Region) Allocator.Error![]Guess {
    const length_b: usize = region.target_end - region.target_start;
    const out = try arena.alloc(Guess, length_b);
    const fuzzy = try fuzzyMatch(arena, parent, target, region);
    for (out, 0..) |*g, i| {
        const target_idx = region.target_start + i;
        if (fuzzy) |m| if (m[i] >= 0) {
            g.* = @intCast(m[i]);
            continue;
        };
        g.* = scanParent(parent, target, target_idx);
    }
    return out;
}

/// git's `scan_parent_range` over the whole parent: the line sharing the
/// most pairs, ten at least, the nearest to the target's line on a tie.
fn scanParent(parent: []const Fingerprint, target: []const Fingerprint, t_idx: usize) ?u32 {
    var best_val: i32 = 10;
    var best_idx: ?usize = null;
    for (parent, 0..) |*p, p_idx| {
        const sim = similarity(&target[t_idx], p);
        if (sim < best_val) continue;
        if (sim == best_val) if (best_idx) |b| {
            if (absDiff(b, t_idx) < absDiff(p_idx, t_idx)) continue;
        };
        best_val = sim;
        best_idx = p_idx;
    }
    return if (best_idx) |b| @intCast(b) else null;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

const certain_nothing_matches: i32 = -2;
const certainty_not_calculated: i32 = -1;

const Mapping = struct { destination_start: i32, destination_length: i32, source_start: i32, source_length: i32 };

/// git's `map_line_number`.
fn mapLine(line: i32, m: Mapping) i32 {
    return @divTrunc(((line - m.source_start) * 2 + 1) * m.destination_length, m.source_length * 2) + m.destination_start;
}

const Matching = struct {
    parent: []Fingerprint,
    target: []const Fingerprint,
    similarities: []i32,
    certainties: []i32,
    second_best: []i32,
    result: []i32,
    max_a: i32,
    max_b: i32,
    map: Mapping,

    fn similarityAt(m: *Matching, base: usize, line_a: i32, local_b: i32, closest_a: i32) *i32 {
        return &m.similarities[base + @as(usize, @intCast(line_a - closest_a + m.max_a + local_b * (m.max_a * 2 + 1)))];
    }
};

/// git's `fuzzy_find_matching_lines`: the parent line each target line of
/// the region matches, `-1` for none; `null` for an empty parent side.
fn fuzzyMatch(arena: Allocator, parent: []Fingerprint, target: []const Fingerprint, region: Region) Allocator.Error!?[]i32 {
    const start_a: i32 = @intCast(region.parent_start);
    const length_a: i32 = @intCast(region.parent_len);
    const start_b: i32 = @intCast(region.target_start);
    const length_b: i32 = @intCast(region.target_end - region.target_start);
    if (length_a <= 0) return null;
    var max_a: i32 = 10;
    if (max_a >= length_a) max_a = length_a - 1;
    const max_b = @divTrunc((2 * max_a + 1) * length_b - 1, length_a);
    const n_b: usize = @intCast(length_b);
    var m: Matching = .{
        .parent = parent,
        .target = target,
        .similarities = try arena.alloc(i32, n_b * @as(usize, @intCast(max_a * 2 + 1))),
        .certainties = try arena.alloc(i32, n_b),
        .second_best = try arena.alloc(i32, n_b),
        .result = try arena.alloc(i32, n_b),
        .max_a = max_a,
        .max_b = max_b,
        .map = .{ .destination_start = start_a, .destination_length = length_a, .source_start = start_b, .source_length = length_b },
    };
    @memset(m.similarities, -1);
    @memset(m.certainties, certainty_not_calculated);
    @memset(m.second_best, -1);
    @memset(m.result, -1);
    recurse(&m, .{ .start_a = start_a, .start_b = start_b, .length_a = length_a, .length_b = length_b, .off_b = 0 });
    return m.result;
}

/// A part of the region: lines of A and B, and where B's part starts in
/// the region's arrays.
const Part = struct { start_a: i32, start_b: i32, length_a: i32, length_b: i32, off_b: usize };

/// git's `find_best_line_matches` for the part's line `local_b`.
fn bestMatch(m: *Matching, part: Part, local_b: i32) void {
    const at = part.off_b + @as(usize, @intCast(local_b));
    if (m.certainties[at] != certainty_not_calculated) return;
    const closest_a = mapLine(local_b + part.start_b, m.map) - part.start_a;
    const search_start = @max(closest_a - m.max_a, 0);
    const search_end = @min(closest_a + m.max_a + 1, part.length_a);
    var best: i32 = 0;
    var second: i32 = 0;
    var best_idx: i32 = 0;
    var second_idx: i32 = 0;
    const base = part.off_b * @as(usize, @intCast(m.max_a * 2 + 1));
    var i = search_start;
    while (i < search_end) : (i += 1) {
        const sim = m.similarityAt(base, i, local_b, closest_a);
        if (sim.* == -1) {
            sim.* = similarity(&m.target[@intCast(part.start_b + local_b)], &m.parent[@intCast(part.start_a + i)]) *
                (1000 - @as(i32, @intCast(@abs(i - closest_a))));
        }
        if (sim.* > best) {
            second = best;
            second_idx = best_idx;
            best = sim.*;
            best_idx = i;
        } else if (sim.* > second) {
            second = sim.*;
            second_idx = i;
        }
    }
    if (best == 0) {
        m.certainties[at] = certain_nothing_matches;
        m.result[at] = -1;
    } else {
        m.certainties[at] = best * 2 - second;
        m.result[at] = part.start_a + best_idx;
        m.second_best[at] = part.start_a + second_idx;
    }
}

/// git's `fuzzy_find_matching_lines_recurse`.
fn recurse(m: *Matching, part: Part) void {
    var most_b: i32 = -1;
    var most_certainty: i32 = -1;
    var i: i32 = 0;
    while (i < part.length_b) : (i += 1) {
        bestMatch(m, part, i);
        const c = m.certainties[part.off_b + @as(usize, @intCast(i))];
        if (c > most_certainty) {
            most_certainty = c;
            most_b = i;
        }
    }
    if (most_b == -1) return;
    const at = part.off_b + @as(usize, @intCast(most_b));
    const most_a = m.result[at];
    subtract(&m.parent[@intCast(most_a)], &m.target[@intCast(part.start_b + most_b)]);

    const invalidate_min = @max(most_b - m.max_b, 0);
    const invalidate_max = @min(most_b + m.max_b + 1, part.length_b);
    const base = part.off_b * @as(usize, @intCast(m.max_a * 2 + 1));
    i = invalidate_min;
    while (i < invalidate_max) : (i += 1) {
        const closest_a = mapLine(i + part.start_b, m.map) - part.start_a;
        if (@as(i32, @intCast(@abs(most_a - part.start_a - closest_a))) > m.max_a) continue;
        m.similarityAt(base, most_a - part.start_a, i, closest_a).* = -1;
    }
    i = most_b - 1;
    while (i >= invalidate_min) : (i -= 1) {
        const k = part.off_b + @as(usize, @intCast(i));
        if (m.certainties[k] >= 0 and (m.result[k] >= most_a or m.second_best[k] >= most_a)) m.certainties[k] = certainty_not_calculated;
    }
    i = most_b + 1;
    while (i < invalidate_max) : (i += 1) {
        const k = part.off_b + @as(usize, @intCast(i));
        if (m.certainties[k] >= 0 and (m.result[k] <= most_a or m.second_best[k] <= most_a)) m.certainties[k] = certainty_not_calculated;
    }
    if (most_b > 0) {
        recurse(m, .{ .start_a = part.start_a, .start_b = part.start_b, .length_a = most_a + 1 - part.start_a, .length_b = most_b, .off_b = part.off_b });
    }
    if (most_b + 1 < part.length_b) {
        const offset_b = most_b + 1;
        recurse(m, .{
            .start_a = most_a,
            .start_b = part.start_b + offset_b,
            .length_a = part.length_a + part.start_a - most_a,
            .length_b = part.length_b - offset_b,
            .off_b = part.off_b + @as(usize, @intCast(offset_b)),
        });
    }
}

test "a fingerprint is the line's lowercased byte pairs, and similarity their common part" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cat = try fingerprint(a, "cat mat");
    const father = try fingerprint(a, "father rather");
    try std.testing.expectEqual(@as(i32, 2), similarity(&cat, &father));
    const tim = try fingerprint(a, "tim");
    const mit = try fingerprint(a, "mit");
    try std.testing.expectEqual(@as(i32, 0), similarity(&tim, &mit));
}
