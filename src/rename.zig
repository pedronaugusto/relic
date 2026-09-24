//! Pairing deleted paths with added ones: git's `diffcore-rename`, for
//! `git diff -M` and `-C` and for the merge.
//!
//! Which deletion an addition is paired with decides what a diff says and
//! what a merge does, and git's answer comes from a particular sequence:
//! identical objects first, the most similar source by basename breaking
//! ties among them; then, for renames only, a file with the same basename
//! as a single deleted one, or the one a moved directory suggests, at a
//! higher bar; then every remaining pair scored, the best four per
//! destination kept, and all of them taken from the best down. Each step
//! is here as git takes it, in git's order, with git's similarity score
//! (`similarity.zig`) and its limit on how many pairs are scored at all.
//!
//! A merge asks for less than a diff: only the sources it names as
//! relevant, with the directories removed on its side so that a directory
//! that moved can be recognised, and a count of where each one's files
//! went. Those inputs are optional; a diff leaves them out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const similarity = @import("similarity.zig");

const Oid = hash.Oid;

/// Errors from pairing.
pub const Error = error{
    /// A path's object is not a blob.
    NotABlob,
} || Allocator.Error || odb_mod.Error;

/// A mode as git keeps it, 0 for none.
pub const Mode = u32;

/// Whether a raw mode is a regular file.
pub fn isReg(mode: Mode) bool {
    return mode & 0o170000 == 0o100000;
}

/// One side of a pair: a path, and what was there.
pub const Spec = struct {
    path: []const u8,
    /// 0 when the side is absent.
    mode: Mode = 0,
    oid: Oid,
    /// How many destinations took this as their source.
    rename_used: u32 = 0,

    /// Whether the side is there.
    pub fn valid(s: *const Spec) bool {
        return s.mode != 0;
    }
};

/// A change: `one` before, `two` after.
pub const Pair = struct {
    one: *Spec,
    two: *Spec,
    /// The status letter, once the caller decides it.
    status: u8 = 0,
    /// The similarity, out of `similarity.max_score`, for a pair found
    /// here; a caller may reuse it.
    score: u32 = 0,
    /// Whether `one` was swapped in by the search.
    renamed: bool = false,
};

/// Why a directory matters: `dirs_removed`'s values.
pub const DirRelevance = struct {
    pub const not_relevant: i64 = 0;
    pub const for_ancestor: i64 = 1;
    pub const for_self: i64 = 2;
};

/// Why a source matters: `relevant_sources`' values.
pub const SourceRelevance = struct {
    pub const no_more: i64 = 0;
    pub const content: i64 = 1;
    pub const location: i64 = 2;
};

/// What the pairing is asked to do.
pub const Options = struct {
    /// `-C`: a modified file may be the source of a copy too.
    copies: bool = false,
    /// The least similarity a pair needs, out of `similarity.max_score`;
    /// zero is git's default of half.
    minimum_score: u32 = 0,
    /// The most sources times destinations scored, squared: git's
    /// `diff.renameLimit`. Zero or less is no limit.
    rename_limit: i64 = 1000,
    /// Whether an empty file can be the source or destination of a rename;
    /// a diff says yes and a merge no.
    rename_empty: bool = true,
    /// The only sources worth pairing, when the caller knows which.
    relevant_sources: ?*std.StringHashMapUnmanaged(i64) = null,
    /// The directories removed on this side, and why each matters.
    dirs_removed: ?*std.StringHashMapUnmanaged(i64) = null,
    /// Where the files of each removed directory went: old directory to
    /// new directory to count, filled here.
    dir_rename_count: ?*GitMap(*GitMap(i64)) = null,
    /// Renames found before, source to destination or to nothing for a
    /// deletion, counted towards the directories' moves.
    cached_pairs: ?*const GitMap(?[]const u8) = null,
};

/// What the pairing reports back.
pub const Outcome = struct {
    /// When the scoring was skipped for want of a higher limit, the limit
    /// that would have run it; otherwise 0.
    needed_limit: u64 = 0,
};

/// Pair the additions and deletions in `queue`, as `diffcore_rename`
/// does, and write the queue back as git does: a rename or copy stands
/// where its destination stood, and a deletion whose file went somewhere is
/// gone. Everything allocated is `arena`'s.
pub fn detect(arena: Allocator, io: Io, db: *odb_mod.Odb, queue: *std.ArrayList(*Pair), options: Options) Error!Outcome {
    var r: Run = .{ .arena = arena, .io = io, .db = db, .options = options };
    const empty = hash.Hasher.object(db.kind, "blob", "");
    for (queue.items) |p| {
        if (!p.one.valid()) {
            if (!p.two.valid()) continue;
            if (!options.rename_empty and p.two.oid.eql(empty)) continue;
            try r.dst.append(arena, .{ .p = p });
        } else if (!options.rename_empty and p.one.oid.eql(empty)) {
            continue;
        } else if (!p.two.valid()) {
            try r.src.append(arena, .{ .p = p, .score = p.score });
        } else if (options.copies) {
            p.one.rename_used += 1;
            try r.src.append(arena, .{ .p = p, .score = p.score });
        }
    }
    var minimum = options.minimum_score;
    if (minimum == 0) minimum = similarity.default_minimum;
    if (r.dst.items.len != 0 and r.src.items.len != 0) try r.run(minimum);
    if (r.setup) try r.cleanupDirRenameInfo();

    var out: std.ArrayList(*Pair) = .empty;
    for (queue.items) |p| {
        if (!p.one.valid() and p.two.valid()) {
            try out.append(arena, p);
        } else if (p.one.valid() and !p.two.valid()) {
            if (p.one.rename_used == 0) try out.append(arena, p);
        } else if (!unmodified(p)) {
            try out.append(arena, p);
        }
    }
    queue.* = out;
    return .{ .needed_limit = r.needed_limit };
}

/// `diff_unmodified_pair`: the same file at the same path.
pub fn unmodified(p: *const Pair) bool {
    if (p.one.valid() != p.two.valid()) return false;
    if (p.one.mode != p.two.mode) return false;
    if (!std.mem.eql(u8, p.one.path, p.two.path)) return false;
    return p.one.oid.eql(p.two.oid);
}

/// `basename_same`.
pub fn basenameSame(src: []const u8, dst: []const u8) bool {
    var src_len = src.len;
    var dst_len = dst.len;
    while (src_len != 0 and dst_len != 0) {
        src_len -= 1;
        dst_len -= 1;
        const c1 = src[src_len];
        const c2 = dst[dst_len];
        if (c1 != c2) return false;
        if (c1 == '/') return true;
    }
    return (src_len == 0 or src[src_len - 1] == '/') and (dst_len == 0 or dst[dst_len - 1] == '/');
}

const unknown_dir = "/";

const Src = struct { p: *Pair, score: u32 };
const Dst = struct { p: *Pair, is_rename: bool = false };
const Score = struct { src: i32 = -1, dst: i32 = -1, score: u32 = 0, name_score: i32 = 0 };

const Run = struct {
    arena: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    options: Options,
    src: std.ArrayList(Src) = .empty,
    dst: std.ArrayList(Dst) = .empty,
    idx_map: std.StringHashMapUnmanaged(i64) = .empty,
    dir_rename_guess: std.StringHashMapUnmanaged([]const u8) = .empty,
    blobs: std.AutoHashMapUnmanaged(Oid, []const u8) = .empty,
    /// `dir_rename_info.setup`: whether directory renames are tracked.
    setup: bool = false,
    needed_limit: u64 = 0,

    fn blob(r: *Run, oid: Oid) Error![]const u8 {
        if (r.blobs.get(oid)) |bytes| return bytes;
        const found = try r.db.read(r.io, oid);
        defer r.db.gpa.free(found.bytes);
        if (found.type != .blob) return error.NotABlob;
        const bytes = try r.arena.dupe(u8, found.bytes);
        try r.blobs.put(r.arena, oid, bytes);
        return bytes;
    }

    /// `estimate_similarity`.
    fn estimate(r: *Run, one: *const Spec, two: *const Spec, minimum: u32) Error!u32 {
        if (!isReg(one.mode) or !isReg(two.mode)) return 0;
        return similarity.score(r.arena, try r.blob(one.oid), try r.blob(two.oid), minimum);
    }

    fn recordRenamePair(r: *Run, dst_index: usize, src_index: usize, score: u32) void {
        const src = r.src.items[src_index].p;
        const dst = r.dst.items[dst_index].p;
        src.one.rename_used += 1;
        r.dst.items[dst_index].is_rename = true;
        dst.one = src.one;
        dst.renamed = true;
        dst.score = if (std.mem.eql(u8, dst.one.path, dst.two.path)) r.src.items[src_index].score else score;
    }

    fn dirsRemoved(r: *Run) ?*std.StringHashMapUnmanaged(i64) {
        return r.options.dirs_removed;
    }

    fn countIncrement(r: *Run, old_dir: []const u8, new_dir: []const u8) Allocator.Error!void {
        const counts_map = r.options.dir_rename_count orelse return;
        const counts = counts_map.get(old_dir) orelse blk: {
            const created = try r.arena.create(GitMap(i64));
            created.* = .{};
            try counts_map.put(r.arena, old_dir, created);
            break :blk created;
        };
        if (counts.getPtr(new_dir)) |c| {
            c.* += 1;
        } else try counts.put(r.arena, new_dir, 1);
    }

    /// `update_dir_rename_counts`.
    fn updateDirRenameCounts(r: *Run, oldname: []const u8, newname: []const u8) Allocator.Error!void {
        if (!r.setup) return;
        const dirs_removed = r.dirsRemoved();
        var old_dir = oldname;
        var new_dir = newname;
        var first = true;
        while (true) {
            const old_split = splitLast(old_dir);
            old_dir = old_split.parent;
            if (dirs_removed) |d| {
                if (!d.contains(old_dir)) break;
            }
            const new_split = splitLast(new_dir);
            new_dir = new_split.parent;
            if (!first and !std.mem.eql(u8, old_split.component, new_split.component)) break;
            const drd_flag = if (dirs_removed) |d| d.get(old_dir) orelse DirRelevance.not_relevant else DirRelevance.not_relevant;
            if (drd_flag == DirRelevance.for_self or first) try r.countIncrement(old_dir, new_dir);
            first = false;
            if (drd_flag == DirRelevance.not_relevant) break;
            if (old_dir.len == 0 or new_dir.len == 0) break;
        }
    }

    fn splitLast(path: []const u8) struct { parent: []const u8, component: []const u8 } {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return .{ .parent = path[0..slash], .component = path[slash + 1 ..] };
        return .{ .parent = "", .component = path };
    }

    fn dirname(path: []const u8) []const u8 {
        return splitLast(path).parent;
    }

    fn basename(path: []const u8) []const u8 {
        return splitLast(path).component;
    }

    /// `find_exact_renames`.
    fn findExactRenames(r: *Run) usize {
        var renames: usize = 0;
        for (r.dst.items, 0..) |d, dst_index| {
            const target = d.p.two;
            var best: ?usize = null;
            var best_score: i32 = -1;
            var tries: u32 = 100;
            for (r.src.items, 0..) |s, src_index| {
                const source = s.p.one;
                if (!source.oid.eql(target.oid)) continue;
                if (!isReg(source.mode) or !isReg(target.mode)) {
                    if (source.mode != target.mode) continue;
                }
                var score: i32 = if (source.rename_used == 0) 1 else 0;
                if (source.rename_used != 0 and !r.options.copies) continue;
                score += if (basenameSame(source.path, target.path)) 1 else 0;
                if (score > best_score) {
                    best = src_index;
                    best_score = score;
                    if (score == 2) break;
                }
                tries -= 1;
                if (tries == 0) break;
            }
            if (best) |src_index| {
                r.recordRenamePair(dst_index, src_index, similarity.max_score);
                renames += 1;
            }
        }
        return renames;
    }

    /// `remove_unneeded_paths_from_src`.
    fn removeUnneededPathsFromSrc(r: *Run, interesting: ?*std.StringHashMapUnmanaged(i64)) void {
        if (r.options.copies and interesting == null) return;
        var kept: usize = 0;
        for (r.src.items) |s| {
            if (!r.options.copies and s.p.one.rename_used != 0) continue;
            if (interesting) |set| {
                if (!set.contains(s.p.one.path)) continue;
            }
            r.src.items[kept] = s;
            kept += 1;
        }
        r.src.shrinkRetainingCapacity(kept);
    }

    /// `initialize_dir_rename_info`.
    fn initializeDirRenameInfo(r: *Run) Allocator.Error!void {
        if (r.options.dirs_removed == null and r.options.relevant_sources == null) return;
        r.setup = true;
        for (r.dst.items, 0..) |d, i| {
            if (!d.is_rename) {
                try r.idx_map.put(r.arena, d.p.two.path, @intCast(i));
                continue;
            }
            try r.updateDirRenameCounts(d.p.one.path, d.p.two.path);
        }
        if (r.options.cached_pairs) |cached| {
            var it = cached.iterator();
            while (it.next()) |node| {
                const new_name = node.value orelse continue;
                try r.updateDirRenameCounts(node.key, new_name);
            }
        }
        const counts_map = r.options.dir_rename_count orelse return;
        var it = counts_map.iterator();
        while (it.next()) |entry| {
            // `get_highest_rename_path`, in git's order.
            var highest: i64 = 0;
            var best: ?[]const u8 = null;
            var count_it = entry.value.iterator();
            while (count_it.next()) |c| {
                if (c.value > highest) {
                    highest = c.value;
                    best = c.key;
                }
            }
            try r.dir_rename_guess.put(r.arena, entry.key, best orelse "");
        }
    }

    fn idxPossibleRename(r: *Run, filename: []const u8) Allocator.Error!i64 {
        if (!r.setup) return -1;
        const new_dir = r.dir_rename_guess.get(dirname(filename)) orelse return -1;
        const new_path = try std.mem.concat(r.arena, u8, &.{ new_dir, "/", basename(filename) });
        return r.idx_map.get(new_path) orelse -1;
    }

    /// `find_basename_matches`.
    fn findBasenameMatches(r: *Run, minimum_score: u32) Error!usize {
        var renames: usize = 0;
        var sources: std.StringHashMapUnmanaged(i64) = .empty;
        var dests: std.StringHashMapUnmanaged(i64) = .empty;
        for (r.src.items, 0..) |s, i| {
            const base = basename(s.p.one.path);
            if (sources.contains(base)) try sources.put(r.arena, base, -1) else try sources.put(r.arena, base, @intCast(i));
        }
        for (r.dst.items, 0..) |d, i| {
            if (d.is_rename) continue;
            const base = basename(d.p.two.path);
            if (dests.contains(base)) try dests.put(r.arena, base, -1) else try dests.put(r.arena, base, @intCast(i));
        }
        for (r.src.items, 0..) |s, i| {
            const filename = s.p.one.path;
            if (r.options.relevant_sources) |relevant| {
                if (!relevant.contains(filename)) continue;
            }
            const base = basename(filename);
            var src_index: i64 = sources.get(base) orelse -1;
            if (dests.get(base)) |dest_value| {
                var dst_index = dest_value;
                if (src_index == -1 or dst_index == -1) {
                    src_index = @intCast(i);
                    dst_index = try r.idxPossibleRename(filename);
                }
                if (dst_index == -1) continue;
                const di: usize = @intCast(dst_index);
                if (r.dst.items[di].is_rename) continue;
                const si: usize = @intCast(src_index);
                const one = r.src.items[si].p.one;
                const two = r.dst.items[di].p.two;
                const score = try r.estimate(one, two, minimum_score);
                if (score < minimum_score) continue;
                r.recordRenamePair(di, si, score);
                renames += 1;
                try r.updateDirRenameCounts(one.path, two.path);
            }
        }
        return renames;
    }

    fn dirRenameAlreadyDeterminable(counts: *const GitMap(i64)) bool {
        var first: i64 = 0;
        var second: i64 = 0;
        var unknown: i64 = 0;
        var it = counts.iterator();
        while (it.next()) |c| {
            if (std.mem.eql(u8, c.key, unknown_dir)) {
                unknown = c.value;
            } else if (c.value >= first) {
                second = first;
                first = c.value;
            } else if (c.value >= second) {
                second = c.value;
            }
        }
        return first > second + unknown;
    }

    /// `handle_early_known_dir_renames`.
    fn handleEarlyKnownDirRenames(r: *Run) Allocator.Error!void {
        const dirs_removed = r.options.dirs_removed orelse return;
        const relevant = r.options.relevant_sources orelse return;
        for (r.src.items) |s| {
            var old_dir = dirname(s.p.one.path);
            while (old_dir.len != 0 and (dirs_removed.get(old_dir) orelse DirRelevance.not_relevant) != DirRelevance.not_relevant) {
                try r.countIncrement(old_dir, unknown_dir);
                old_dir = dirname(old_dir);
            }
        }
        if (r.options.dir_rename_count) |counts_map| {
            var it = counts_map.iterator();
            while (it.next()) |entry| {
                if ((dirs_removed.get(entry.key) orelse DirRelevance.not_relevant) == DirRelevance.for_self and dirRenameAlreadyDeterminable(entry.value)) {
                    try dirs_removed.put(r.arena, entry.key, DirRelevance.for_ancestor);
                }
            }
        }
        var kept: usize = 0;
        for (r.src.items) |s| {
            const val = relevant.get(s.p.one.path).?;
            if (val == SourceRelevance.location) {
                var removable = true;
                var dir = dirname(s.p.one.path);
                while (true) {
                    const res = dirs_removed.get(dir) orelse DirRelevance.not_relevant;
                    if (res == DirRelevance.not_relevant) break;
                    if (res == DirRelevance.for_self) {
                        removable = false;
                        break;
                    }
                    dir = dirname(dir);
                }
                if (removable) {
                    try relevant.put(r.arena, s.p.one.path, SourceRelevance.no_more);
                    continue;
                }
            }
            r.src.items[kept] = s;
            kept += 1;
        }
        r.src.shrinkRetainingCapacity(kept);
    }

    fn scoreCompare(a: Score, b: Score) i64 {
        if (a.dst < 0) return if (0 <= b.dst) 1 else 0;
        if (b.dst < 0) return -1;
        if (a.score == b.score) return @as(i64, b.name_score) - a.name_score;
        return @as(i64, b.score) - @as(i64, a.score);
    }

    fn recordIfBetter(m4: *[4]Score, o: Score) void {
        var worst: usize = 0;
        for (1..4) |i| {
            if (scoreCompare(m4[i], m4[worst]) > 0) worst = i;
        }
        if (scoreCompare(m4[worst], o) > 0) m4[worst] = o;
    }

    fn lessThanScore(_: void, a: Score, b: Score) bool {
        return scoreCompare(a, b) < 0;
    }

    /// `find_renames`.
    fn findRenames(r: *Run, mx: []const Score, minimum_score: u32, copies: bool) Allocator.Error!usize {
        var count: usize = 0;
        for (mx) |candidate| {
            if (candidate.dst < 0 or candidate.score < minimum_score) break;
            const di: usize = @intCast(candidate.dst);
            const si: usize = @intCast(candidate.src);
            if (r.dst.items[di].is_rename) continue;
            if (!copies and r.src.items[si].p.one.rename_used != 0) continue;
            r.recordRenamePair(di, si, candidate.score);
            count += 1;
            try r.updateDirRenameCounts(r.src.items[si].p.one.path, r.dst.items[di].p.two.path);
        }
        return count;
    }

    fn run(r: *Run, minimum_score: u32) Error!void {
        var rename_count = r.findExactRenames();
        if (minimum_score == similarity.max_score) return;

        if (r.options.copies) {
            r.removeUnneededPathsFromSrc(r.options.relevant_sources);
        } else {
            const min_basename_score: u32 = minimum_score + @as(u32, @intFromFloat(0.5 * @as(f64, @floatFromInt(similarity.max_score - minimum_score))));
            r.removeUnneededPathsFromSrc(null);
            try r.initializeDirRenameInfo();
            rename_count += try r.findBasenameMatches(min_basename_score);
            r.removeUnneededPathsFromSrc(r.options.relevant_sources);
            try r.handleEarlyKnownDirRenames();
        }

        const num_destinations = r.dst.items.len - rename_count;
        const num_sources = r.src.items.len;
        if (num_destinations == 0 or num_sources == 0) return;

        // `too_many_rename_candidates`.
        if (r.options.rename_limit > 0) {
            const limit: u64 = @intCast(r.options.rename_limit);
            if (@as(u128, num_destinations) * num_sources > @as(u128, limit) * limit) {
                r.needed_limit = @max(num_sources, num_destinations);
                return;
            }
        }

        var mx: std.ArrayList(Score) = .empty;
        for (r.dst.items, 0..) |d, i| {
            if (d.is_rename) continue;
            var m4: [4]Score = .{ .{}, .{}, .{}, .{} };
            for (r.src.items, 0..) |s, j| {
                const one = s.p.one;
                const two = d.p.two;
                const this: Score = .{
                    .score = try r.estimate(one, two, minimum_score),
                    .name_score = if (basenameSame(one.path, two.path)) 1 else 0,
                    .dst = @intCast(i),
                    .src = @intCast(j),
                };
                recordIfBetter(&m4, this);
            }
            try mx.appendSlice(r.arena, &m4);
        }
        std.mem.sort(Score, mx.items, {}, lessThanScore);
        _ = try r.findRenames(mx.items, minimum_score, false);
        if (r.options.copies) _ = try r.findRenames(mx.items, minimum_score, true);
    }

    /// `cleanup_dir_rename_info`, keeping the counts: a directory that was
    /// not removed has no rename, and the unknown destinations go.
    fn cleanupDirRenameInfo(r: *Run) Allocator.Error!void {
        const counts_map = r.options.dir_rename_count orelse return;
        const dirs_removed = r.options.dirs_removed orelse return;
        var to_remove: std.ArrayList([]const u8) = .empty;
        var it = counts_map.iterator();
        while (it.next()) |entry| {
            if ((dirs_removed.get(entry.key) orelse DirRelevance.not_relevant) == DirRelevance.not_relevant) {
                try to_remove.append(r.arena, entry.key);
                continue;
            }
            if (entry.value.contains(unknown_dir)) try entry.value.remove(r.arena, unknown_dir);
        }
        for (to_remove.items) |key| try counts_map.remove(r.arena, key);
    }
};

//=========================================================================
// git's hashmap, for iteration order
//=========================================================================

/// A map that hands its entries back in the order git's `strmap` would:
/// FNV-1 over the key, a table of 64 buckets growing fourfold past 80%
/// full and shrinking when a fifth of that, each bucket a list with the
/// newest entry first, and the table read from the first bucket to the
/// last. Where git iterates one of its maps and the order decides an
/// answer, this decides it the same way.
pub fn GitMap(comptime V: type) type {
    return struct {
        const Self = @This();

        /// One entry.
        pub const Node = struct { key: []const u8, hash: u32, value: V, next: ?u32 };

        nodes: std.ArrayList(Node) = .empty,
        table: []?u32 = &.{},
        size: u32 = 0,
        grow_at: u32 = 0,
        shrink_at: u32 = 0,
        index: std.StringHashMapUnmanaged(u32) = .empty,

        fn strhash(key: []const u8) u32 {
            var h: u32 = 0x811c9dc5;
            for (key) |c| h = (h *% 0x01000193) ^ c;
            return h;
        }

        fn allocTable(self: *Self, arena: Allocator, size: u32) Allocator.Error!void {
            self.table = try arena.alloc(?u32, size);
            @memset(self.table, null);
            self.grow_at = @intCast(@as(u64, size) * 80 / 100);
            self.shrink_at = if (size <= 64) 0 else self.grow_at / 5;
        }

        fn rehash(self: *Self, arena: Allocator, new_size: u32) Allocator.Error!void {
            const old = self.table;
            try self.allocTable(arena, new_size);
            for (old) |head| {
                var at = head;
                while (at) |i| {
                    const next = self.nodes.items[i].next;
                    const b = self.nodes.items[i].hash & (new_size - 1);
                    self.nodes.items[i].next = self.table[b];
                    self.table[b] = i;
                    at = next;
                }
            }
        }

        /// The value at `key`, or `null`.
        pub fn get(self: *const Self, key: []const u8) ?V {
            const i = self.index.get(key) orelse return null;
            return self.nodes.items[i].value;
        }

        /// A pointer to the value at `key`, or `null`.
        pub fn getPtr(self: *Self, key: []const u8) ?*V {
            const i = self.index.get(key) orelse return null;
            return &self.nodes.items[i].value;
        }

        /// Whether `key` is in the map.
        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.index.contains(key);
        }

        /// `strmap_put`: a new key goes into its bucket; an old one keeps
        /// its place and takes the new value.
        pub fn put(self: *Self, arena: Allocator, key: []const u8, value: V) Allocator.Error!void {
            if (self.index.get(key)) |i| {
                self.nodes.items[i].value = value;
                return;
            }
            if (self.table.len == 0) try self.allocTable(arena, 64);
            const owned = try arena.dupe(u8, key);
            const h = strhash(owned);
            const i: u32 = @intCast(self.nodes.items.len);
            const b = h & @as(u32, @intCast(self.table.len - 1));
            try self.nodes.append(arena, .{ .key = owned, .hash = h, .value = value, .next = self.table[b] });
            self.table[b] = i;
            try self.index.put(arena, owned, i);
            self.size += 1;
            if (self.size > self.grow_at) try self.rehash(arena, @intCast(self.table.len << 2));
        }

        /// `strmap_remove`.
        pub fn remove(self: *Self, arena: Allocator, key: []const u8) Allocator.Error!void {
            const i = self.index.get(key) orelse return;
            _ = self.index.remove(key);
            const b = self.nodes.items[i].hash & @as(u32, @intCast(self.table.len - 1));
            var link: *?u32 = &self.table[b];
            while (link.*) |at| {
                if (at == i) {
                    link.* = self.nodes.items[at].next;
                    break;
                }
                link = &self.nodes.items[at].next;
            }
            self.size -= 1;
            if (self.size < self.shrink_at) try self.rehash(arena, @intCast(self.table.len >> 2));
        }

        /// A walk in git's order.
        pub const Iterator = struct {
            map: *const Self,
            bucket: usize = 0,
            at: ?u32 = null,

            /// The next entry, or `null`.
            pub fn next(it: *Iterator) ?*const Node {
                while (true) {
                    if (it.at) |i| {
                        it.at = it.map.nodes.items[i].next;
                        return &it.map.nodes.items[i];
                    }
                    if (it.bucket >= it.map.table.len) return null;
                    it.at = it.map.table[it.bucket];
                    it.bucket += 1;
                }
            }
        };

        /// Every entry, in git's order.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .map = self };
        }
    };
}
