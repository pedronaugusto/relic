//! The commit-graph, read and encoded as an accelerator.
//!
//! Correctness never depends on it: everything it answers can be answered by
//! reading the commit objects, and a repository that has one must read the
//! same either way. It is here so a history walk over a large repository
//! does not inflate a commit object per step.
//!
//! Generation numbers are read only in their second form — the corrected
//! commit dates in `GDA2`. Version one stores topological levels, which are
//! far more conservative as a cutoff and are a different quantity with the
//! same name; a graph that carries only those is read for its parents and
//! reports no generations rather than pretending the two are the same.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const fs = @import("../repo/fs.zig");

const Oid = hash.Oid;
const format = @import("accelerators/chunks.zig");
pub const bloom = @import("commitgraph/bloom.zig");

/// The four bytes a commit-graph begins with.
pub const magic = "CGPH";

/// Errors from reading a commit-graph.
pub const Error = error{
    /// The file did not begin `CGPH`.
    NotACommitGraph,
    /// A version this release does not read.
    UnsupportedGraphVersion,
    /// The hash the graph was built with is not the repository's.
    ObjectFormatMismatch,
    /// A chunk ran off the end, or a required chunk is missing.
    CorruptCommitGraph,
    /// A detached split layer passed to parse without its base graphs.
    SplitGraphUnsupported,
} || Allocator.Error || Io.Dir.ReadFileAllocError;

/// One commit, as the graph stores it.
pub const Commit = struct {
    oid: Oid,
    /// The root tree.
    tree: Oid,
    /// Up to two parents by position in the graph; an octopus merge's third
    /// and later parents come from `extraParents`.
    parents: [2]?u32,
    /// Whether this commit has more than two parents.
    has_extra_parents: bool,
    /// Committer time in seconds.
    time: i64,
    /// The corrected commit date, when the graph carries `GDA2`.
    generation: ?u64,
};

/// A commit-graph file, held in memory.
pub const Graph = struct {
    gpa: Allocator,
    kind: hash.Kind,
    bytes: []const u8,
    count: u32,
    fanout_at: usize,
    names_at: usize,
    data_at: usize,
    edges_at: ?usize,
    generation_at: ?usize,
    generation_overflow_at: ?usize,
    base: ?*Graph = null,
    base_count: u32 = 0,
    local_count: u32,
    bloom_index: ?[]const u8 = null,
    bloom_data: ?[]const u8 = null,
    bloom_settings: bloom.Settings = .{},

    /// Read `objects/info/commit-graph`, or `null` when there is none.
    pub fn open(gpa: Allocator, io: Io, objects_dir: Io.Dir, kind: hash.Kind) Error!?Graph {
        // Keep discovery failures distinct from an absent optional accelerator.
        objects_dir.access(io, "info/commit-graphs/commit-graph-chain", .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (try fs.readFileAlloc(gpa, io, objects_dir, "info/commit-graphs/commit-graph-chain", 255 * (kind.hexLen() + 1))) |chain| {
            defer gpa.free(chain);
            var base: ?*Graph = null;
            errdefer if (base) |g| {
                g.deinit();
                gpa.destroy(g);
            };
            var names = std.mem.tokenizeScalar(u8, chain, '\n');
            var depth: usize = 0;
            while (names.next()) |name| {
                const chain_checksum = Oid.parse(kind, name) catch return error.CorruptCommitGraph;
                const path = try std.fmt.allocPrint(gpa, "info/commit-graphs/graph-{s}.graph", .{name});
                defer gpa.free(path);
                const content = (try fs.readFileAlloc(gpa, io, objects_dir, path, 1 << 30)) orelse return error.CorruptCommitGraph;
                const next = gpa.create(Graph) catch |err| {
                    gpa.free(content);
                    return err;
                };
                next.* = parseBase(gpa, kind, content, base) catch |err| {
                    gpa.destroy(next);
                    return err;
                };
                if (content[7] != depth or !std.mem.eql(u8, next.checksum().raw(), chain_checksum.raw())) {
                    // Ownership of the old chain has passed to next.
                    base = next;
                    return error.CorruptCommitGraph;
                }
                base = next;
                depth += 1;
            }
            const top = base orelse return error.CorruptCommitGraph;
            const result = top.*;
            gpa.destroy(top);
            base = null;
            return result;
        }
        const bytes = (try fs.readFileAlloc(gpa, io, objects_dir, "info/commit-graph", 1 << 30)) orelse
            return null;
        // parse takes ownership on success and failure.
        return try parse(gpa, kind, bytes);
    }

    /// Read a commit-graph from bytes this takes ownership of.
    pub fn parse(gpa: Allocator, kind: hash.Kind, bytes: []const u8) Error!Graph {
        return parseBase(gpa, kind, bytes, null);
    }

    fn parseBase(gpa: Allocator, kind: hash.Kind, bytes: []const u8, base: ?*Graph) Error!Graph {
        errdefer gpa.free(bytes);
        if (bytes.len < 8) return error.NotACommitGraph;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotACommitGraph;
        if (bytes[4] != 1) return error.UnsupportedGraphVersion;
        const hash_version = bytes[5];
        const graph_kind: hash.Kind = switch (hash_version) {
            1 => .sha1,
            2 => .sha256,
            else => return error.UnsupportedGraphVersion,
        };
        if (graph_kind != kind) return error.ObjectFormatMismatch;
        const chunk_count = bytes[6];
        if (bytes[7] != 0 and base == null) return error.SplitGraphUnsupported;
        format.validate(kind, bytes, 8, chunk_count) catch return error.CorruptCommitGraph;
        const base_count = if (base) |g| g.count else 0;

        const table_at: usize = 8;
        const table_len = (@as(usize, chunk_count) + 1) * 12;
        if (bytes.len < table_at + table_len) return error.CorruptCommitGraph;

        var fanout_at: ?usize = null;
        var names_at: ?usize = null;
        var data_at: ?usize = null;
        var edges_at: ?usize = null;
        var generation_at: ?usize = null;
        var generation_overflow_at: ?usize = null;

        var i: usize = 0;
        while (i < chunk_count) : (i += 1) {
            const row = bytes[table_at + i * 12 ..];
            const id = row[0..4];
            const offset = std.mem.readInt(u64, row[4..12], .big);
            if (offset > bytes.len) return error.CorruptCommitGraph;
            const at: usize = @intCast(offset);
            if (std.mem.eql(u8, id, "OIDF")) fanout_at = at;
            if (std.mem.eql(u8, id, "OIDL")) names_at = at;
            if (std.mem.eql(u8, id, "CDAT")) data_at = at;
            if (std.mem.eql(u8, id, "EDGE")) edges_at = at;
            if (std.mem.eql(u8, id, "GDA2")) generation_at = at;
            if (std.mem.eql(u8, id, "GDO2")) generation_overflow_at = at;
        }

        const fanout = fanout_at orelse return error.CorruptCommitGraph;
        if (fanout + 1024 > bytes.len) return error.CorruptCommitGraph;
        const count = std.mem.readInt(u32, bytes[fanout + 255 * 4 ..][0..4], .big);

        const raw_len = kind.rawLen();
        const names = names_at orelse return error.CorruptCommitGraph;
        const data = data_at orelse return error.CorruptCommitGraph;
        if (names + @as(usize, count) * raw_len > bytes.len) return error.CorruptCommitGraph;
        if (data + @as(usize, count) * (raw_len + 16) > bytes.len) return error.CorruptCommitGraph;

        var names_seen: u32 = 0;
        var previous_name: ?[]const u8 = null;
        for (0..256) |bucket| {
            while (names_seen < count) : (names_seen += 1) {
                const at = names + @as(usize, names_seen) * raw_len;
                const name = bytes[at..][0..raw_len];
                if (previous_name) |previous| {
                    if (std.mem.order(u8, previous, name) != .lt) return error.CorruptCommitGraph;
                }
                if (name[0] > bucket) break;
                if (name[0] < bucket) return error.CorruptCommitGraph;
                previous_name = name;
            }
            const fanout_count = std.mem.readInt(u32, bytes[fanout + bucket * 4 ..][0..4], .big);
            if (fanout_count != names_seen) return error.CorruptCommitGraph;
        }
        if (generation_at) |at| {
            if (at + @as(usize, count) * 4 > bytes.len) return error.CorruptCommitGraph;
        }

        if ((format.get(bytes, 8, chunk_count, "OIDF") orelse return error.CorruptCommitGraph).len != 1024 or
            (format.get(bytes, 8, chunk_count, "OIDL") orelse return error.CorruptCommitGraph).len != @as(usize, count) * raw_len or
            (format.get(bytes, 8, chunk_count, "CDAT") orelse return error.CorruptCommitGraph).len != @as(usize, count) * (raw_len + 16)) return error.CorruptCommitGraph;
        if (format.get(bytes, 8, chunk_count, "GDA2")) |chunk| if (chunk.len != @as(usize, count) * 4) return error.CorruptCommitGraph;
        if (bytes[7] != 0) {
            const bases = format.get(bytes, 8, chunk_count, "BASE") orelse return error.CorruptCommitGraph;
            if (bases.len != @as(usize, bytes[7]) * raw_len) return error.CorruptCommitGraph;
            var g = base;
            var i_base: usize = bytes[7];
            while (g) |parent| : (g = parent.base) {
                if (i_base == 0) return error.CorruptCommitGraph;
                i_base -= 1;
                if (!std.mem.eql(u8, bases[i_base * raw_len ..][0..raw_len], parent.checksum().raw())) return error.CorruptCommitGraph;
            }
            if (i_base != 0) return error.CorruptCommitGraph;
        }
        return .{
            .gpa = gpa,
            .kind = kind,
            .bytes = bytes,
            .count = std.math.add(u32, count, base_count) catch return error.CorruptCommitGraph,
            .local_count = count,
            .base_count = base_count,
            .base = base,
            .bloom_index = format.get(bytes, 8, chunk_count, "BIDX"),
            .bloom_data = format.get(bytes, 8, chunk_count, "BDAT"),
            .fanout_at = fanout,
            .names_at = names,
            .data_at = data,
            .edges_at = edges_at,
            .generation_at = generation_at,
            .generation_overflow_at = generation_overflow_at,
        };
    }

    /// The trailing digest, checked when the graph is parsed.
    pub fn checksum(graph: *const Graph) Oid {
        return Oid.fromRaw(graph.kind, graph.bytes[graph.bytes.len - graph.kind.rawLen() ..]) catch unreachable;
    }

    /// The changed-path filter at a global graph position, or null.
    pub fn changedPaths(graph: *const Graph, position: u32) Error!?struct { bytes: []const u8, settings: bloom.Settings } {
        if (position >= graph.count) return error.CorruptCommitGraph;
        if (position < graph.base_count) return graph.base.?.changedPaths(position);
        const index = graph.bloom_index orelse return null;
        const data = graph.bloom_data orelse return error.CorruptCommitGraph;
        if (index.len != @as(usize, graph.local_count) * 4 or data.len < 12) return error.CorruptCommitGraph;
        const local = position - graph.base_count;
        const start = if (local == 0) 0 else std.mem.readInt(u32, index[@as(usize, local - 1) * 4 ..][0..4], .big);
        const end = std.mem.readInt(u32, index[@as(usize, local) * 4 ..][0..4], .big);
        if (start > end or end > data.len - 12) return error.CorruptCommitGraph;
        return .{ .bytes = data[12 + start .. 12 + end], .settings = .{
            .version = std.mem.readInt(u32, data[0..4], .big),
            .hashes = std.mem.readInt(u32, data[4..8], .big),
            .bits_per_entry = std.mem.readInt(u32, data[8..12], .big),
        } };
    }

    /// Verify parents, generation offsets and changed-path indexes.
    pub fn verify(graph: *const Graph) Error!void {
        for (0..graph.count) |i| {
            const commit_value = try graph.commitAt(@intCast(i));
            const parents = try graph.parentsOf(graph.gpa, @intCast(i));
            defer graph.gpa.free(parents);
            for (parents) |oid| {
                const parent = (try graph.commit(oid)).?;
                if (commit_value.generation) |generation| if (parent.generation) |p| if (generation <= p) return error.CorruptCommitGraph;
            }
            _ = try graph.changedPaths(@intCast(i));
        }
    }

    /// Release the graph.
    pub fn deinit(graph: *Graph) void {
        if (graph.base) |base| {
            base.deinit();
            graph.gpa.destroy(base);
        }
        graph.gpa.free(graph.bytes);
        graph.* = undefined;
    }

    /// Whether the graph carries corrected commit dates.
    pub fn hasGenerations(graph: *const Graph) bool {
        return graph.generation_at != null and (if (graph.base) |base| base.hasGenerations() else true);
    }

    /// The name of the commit at `position`.
    pub fn nameAt(graph: *const Graph, position: u32) Oid {
        if (position < graph.base_count) return graph.base.?.nameAt(position);
        const local = position - graph.base_count;
        const raw_len = graph.kind.rawLen();
        return Oid.fromRaw(graph.kind, graph.bytes[graph.names_at + @as(usize, local) * raw_len ..][0..raw_len]) catch unreachable;
    }

    /// Where `oid` is in the graph, or `null`.
    pub fn find(graph: *const Graph, oid: Oid) ?u32 {
        if (oid.kind != graph.kind) return null;
        const raw = oid.raw();
        var lo: u32 = if (raw[0] == 0)
            0
        else
            std.mem.readInt(u32, graph.bytes[graph.fanout_at + (@as(usize, raw[0]) - 1) * 4 ..][0..4], .big);
        var hi: u32 = std.mem.readInt(u32, graph.bytes[graph.fanout_at + @as(usize, raw[0]) * 4 ..][0..4], .big);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const name = graph.nameAt(mid + graph.base_count);
            switch (std.mem.order(u8, name.raw(), raw)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid + graph.base_count,
            }
        }
        return if (graph.base) |base| base.find(oid) else null;
    }

    /// The commit at `position`.
    pub fn commitAt(graph: *const Graph, position: u32) Error!Commit {
        if (position >= graph.count) return error.CorruptCommitGraph;
        if (position < graph.base_count) return graph.base.?.commitAt(position);
        const local = position - graph.base_count;
        const raw_len = graph.kind.rawLen();
        const row = graph.bytes[graph.data_at + @as(usize, local) * (raw_len + 16) ..];
        const tree = Oid.fromRaw(graph.kind, row[0..raw_len]) catch unreachable;
        const first = std.mem.readInt(u32, row[raw_len..][0..4], .big);
        const second = std.mem.readInt(u32, row[raw_len + 4 ..][0..4], .big);
        const packed_time = std.mem.readInt(u64, row[raw_len + 8 ..][0..8], .big);

        // The low 34 bits are the committer time; the 30 above them are the
        // version one generation, which this deliberately does not read.
        const time: i64 = @intCast(packed_time & ((@as(u64, 1) << 34) - 1));

        // `0x70000000` is the format's "no parent", not `0x7fffffff`; the
        // latter is the mask an edge index is taken under.
        const no_parent: u32 = 0x7000_0000;
        const extra_bit: u32 = 0x8000_0000;
        var parents: [2]?u32 = .{ null, null };
        var has_extra = false;
        if (first != no_parent) {
            if (first >= graph.count) return error.CorruptCommitGraph;
            parents[0] = first;
        }
        if (second != no_parent) {
            if (second & extra_bit != 0) {
                has_extra = true;
                parents[1] = second & ~extra_bit;
            } else {
                if (second >= graph.count) return error.CorruptCommitGraph;
                parents[1] = second;
            }
        }

        var generation: ?u64 = null;
        if (graph.generation_at) |at| {
            const offset = std.mem.readInt(u32, graph.bytes[at + @as(usize, local) * 4 ..][0..4], .big);
            if (offset & 0x8000_0000 == 0) {
                generation = @as(u64, @intCast(time)) + offset;
            } else if (graph.generation_overflow_at) |overflow_at| {
                const row_at = overflow_at + @as(usize, offset & 0x7fff_ffff) * 8;
                const overflow = format.get(graph.bytes, 8, graph.bytes[6], "GDO2") orelse return error.CorruptCommitGraph;
                if (row_at + 8 > overflow_at + overflow.len) return error.CorruptCommitGraph;
                const wide = std.mem.readInt(u64, graph.bytes[row_at..][0..8], .big);
                generation = std.math.add(u64, @intCast(time), wide) catch return error.CorruptCommitGraph;
            } else return error.CorruptCommitGraph;
        }

        return .{
            .oid = graph.nameAt(position),
            .tree = tree,
            .parents = parents,
            .has_extra_parents = has_extra,
            .time = time,
            .generation = generation,
        };
    }

    /// The commit named `oid`, or `null` when the graph does not hold it.
    pub fn commit(graph: *const Graph, oid: Oid) Error!?Commit {
        const position = graph.find(oid) orelse return null;
        return try graph.commitAt(position);
    }

    /// The parents of the commit at `position`, as object names.
    ///
    /// The result is the caller's. An octopus merge's third and later
    /// parents come out of the `EDGE` chunk.
    pub fn parentsOf(graph: *const Graph, gpa: Allocator, position: u32) Error![]Oid {
        if (position < graph.base_count) return graph.base.?.parentsOf(gpa, position);
        const found = try graph.commitAt(position);
        var out: std.ArrayList(Oid) = .empty;
        errdefer out.deinit(gpa);
        if (found.parents[0]) |at| {
            if (at >= graph.count) return error.CorruptCommitGraph;
            try out.append(gpa, graph.nameAt(at));
        }
        if (!found.has_extra_parents) {
            if (found.parents[1]) |at| {
                if (at >= graph.count) return error.CorruptCommitGraph;
                try out.append(gpa, graph.nameAt(at));
            }
            return out.toOwnedSlice(gpa);
        }
        const edges_at = graph.edges_at orelse return error.CorruptCommitGraph;
        const edge_chunk = format.get(graph.bytes, 8, graph.bytes[6], "EDGE") orelse return error.CorruptCommitGraph;
        var edge = edges_at + @as(usize, found.parents[1].?) * 4;
        while (true) {
            if (edge + 4 > edges_at + edge_chunk.len) return error.CorruptCommitGraph;
            const value = std.mem.readInt(u32, graph.bytes[edge..][0..4], .big);
            const last = value & 0x8000_0000 != 0;
            const at = value & 0x7fff_ffff;
            if (at >= graph.count) return error.CorruptCommitGraph;
            try out.append(gpa, graph.nameAt(at));
            if (last) break;
            edge += 4;
        }
        return out.toOwnedSlice(gpa);
    }
};

test "a graph that is not one is refused by name" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, "not a graph at all");
    try std.testing.expectError(error.NotACommitGraph, Graph.parse(gpa, .sha1, bytes));
}

test "a non-monotonic commit-graph fanout is corrupt" {
    const gpa = std.testing.allocator;
    const fanout_at: usize = 56;
    const names_at = fanout_at + 1024;
    const data_at = names_at + 20;
    const bytes = try gpa.alloc(u8, data_at + 36);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    bytes[4] = 1;
    bytes[5] = 1;
    bytes[6] = 3;
    @memcpy(bytes[8..12], "OIDF");
    std.mem.writeInt(u64, bytes[12..20], fanout_at, .big);
    @memcpy(bytes[20..24], "OIDL");
    std.mem.writeInt(u64, bytes[24..32], names_at, .big);
    @memcpy(bytes[32..36], "CDAT");
    std.mem.writeInt(u64, bytes[36..44], data_at, .big);
    std.mem.writeInt(u64, bytes[48..56], bytes.len, .big);
    std.mem.writeInt(u32, bytes[fanout_at..][0..4], std.math.maxInt(u32), .big);
    std.mem.writeInt(u32, bytes[fanout_at + 255 * 4 ..][0..4], 1, .big);

    var graph = Graph.parse(gpa, .sha1, bytes) catch |err| {
        try std.testing.expectEqual(error.CorruptCommitGraph, err);
        return;
    };
    graph.deinit();
    return error.TestExpectedError;
}

test "fuzz: any bytes are a graph or a named error" {
    try std.testing.fuzz({}, fuzzGraph, .{});
}

fn fuzzGraph(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [2048]u8 = undefined;
    const n = smith.slice(&scratch);
    const bytes = try gpa.dupe(u8, scratch[0..n]);
    var graph = Graph.parse(gpa, .sha1, bytes) catch return;
    defer graph.deinit();
    var i: u32 = 0;
    while (i < @min(graph.count, 64)) : (i += 1) {
        // ziglint-ignore: Z026 refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
        _ = graph.commitAt(i) catch {};
        const parents = graph.parentsOf(gpa, i) catch continue;
        gpa.free(parents);
    }
}

test "a refused on-disk commit graph releases its bytes once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "info");
    try tmp.dir.writeFile(io, .{ .sub_path = "info/commit-graph", .data = "nope" });
    try std.testing.expectError(error.NotACommitGraph, Graph.open(gpa, io, tmp.dir, .sha1));
}

test "commit graph chain discovery preserves filesystem refusals" {
    const Probe = struct {
        var refusal: Io.Dir.AccessError = error.AccessDenied;
        fn access(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
            return refusal;
        }
    };
    const base = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var vtable = base.vtable.*;
    vtable.dirAccess = Probe.access;
    const io: Io = .{ .userdata = base.userdata, .vtable = &vtable };
    for ([_]Io.Dir.AccessError{ error.AccessDenied, error.InputOutput, error.Canceled }) |err| {
        Probe.refusal = err;
        try std.testing.expectError(err, Graph.open(std.testing.allocator, io, tmp.dir, .sha1));
    }
}

/// A commit to encode, with generations already computed from its parents.
/// Parent positions use the whole split chain's order, bases first.
pub const WriteCommit = struct {
    oid: Oid,
    tree: Oid,
    parents: []const u32,
    time: u64,
    level: u32,
    generation: u64,
    changed_paths: []const u8 = &.{},
};

/// Options for the format writer; the repository writer gathers its own inputs.
pub const WriteOptions = struct {
    generations: bool = true,
    changed_paths: ?bloom.Settings = null,
    bases: []const Oid = &.{},
};

/// Encode one graph, byte for byte git's chunk order. Commits must be sorted by name.
/// The returned file is the caller's. No worker count changes this order.
pub fn encode(gpa: Allocator, kind: hash.Kind, commits: []const WriteCommit, options: WriteOptions) (Allocator.Error || error{InvalidGraphInput})![]u8 {
    if (commits.len > 0x7000_0000 or options.bases.len > 255) return error.InvalidGraphInput;
    var buffers: [9]format.Buffer = undefined;
    for (&buffers) |*buffer| buffer.* = .{ .gpa = gpa };
    defer for (&buffers) |*buffer| buffer.deinit();
    var fanout: [256]u32 = @splat(0);
    var edge_index: u32 = 0;
    var overflow_index: u32 = 0;
    var changed_index: u32 = 0;
    if (options.changed_paths) |settings| {
        try buffers[7].int(u32, settings.version);
        try buffers[7].int(u32, settings.hashes);
        try buffers[7].int(u32, settings.bits_per_entry);
    }
    for (commits, 0..) |commit_value, i| {
        if (commit_value.oid.kind != kind or commit_value.tree.kind != kind or commit_value.level > 0x3fff_ffff or
            (i != 0 and commits[i - 1].oid.order(commit_value.oid) != .lt)) return error.InvalidGraphInput;
        fanout[commit_value.oid.raw()[0]] += 1;
        try buffers[1].add(commit_value.oid.raw());
        try buffers[2].add(commit_value.tree.raw());
        try buffers[2].int(u32, if (commit_value.parents.len == 0) 0x7000_0000 else commit_value.parents[0]);
        try buffers[2].int(u32, if (commit_value.parents.len < 2) 0x7000_0000 else if (commit_value.parents.len == 2) commit_value.parents[1] else 0x8000_0000 | edge_index);
        try buffers[2].int(u64, (@as(u64, commit_value.level) << 34) | (commit_value.time & 0x3_ffff_ffff));
        if (options.generations) {
            const masked_time = commit_value.time & 0x3_ffff_ffff;
            if (commit_value.generation < masked_time) return error.InvalidGraphInput;
            const offset = commit_value.generation - masked_time;
            try buffers[3].int(u32, if (offset > 0x7fff_ffff) 0x8000_0000 | overflow_index else @intCast(offset));
            if (offset > 0x7fff_ffff) {
                try buffers[4].int(u64, offset);
                overflow_index += 1;
            }
        }
        if (commit_value.parents.len > 2) for (commit_value.parents[1..], 1..) |parent, n| {
            try buffers[5].int(u32, parent | (if (n == commit_value.parents.len - 1) @as(u32, 0x8000_0000) else 0));
            edge_index += 1;
        };
        if (options.changed_paths != null) {
            if (commit_value.changed_paths.len > std.math.maxInt(u32) - changed_index) return error.InvalidGraphInput;
            changed_index += @intCast(commit_value.changed_paths.len);
            try buffers[6].int(u32, changed_index);
            try buffers[7].add(commit_value.changed_paths);
        }
    }
    var total: u32 = 0;
    for (fanout) |n| {
        total += n;
        try buffers[0].int(u32, total);
    }
    for (options.bases) |base| {
        if (base.kind != kind) return error.InvalidGraphInput;
        try buffers[8].add(base.raw());
    }
    var chunks: std.ArrayList(format.Chunk) = .empty;
    defer chunks.deinit(gpa);
    const ids = [_]*const [4]u8{ "OIDF", "OIDL", "CDAT", "GDA2", "GDO2", "EDGE", "BIDX", "BDAT", "BASE" };
    for (&buffers, ids, 0..) |*buffer, id, i| {
        const present = switch (i) {
            0, 1, 2 => true,
            3 => options.generations,
            4 => overflow_index > 0,
            5 => edge_index > 0,
            6, 7 => options.changed_paths != null,
            8 => options.bases.len != 0,
            else => unreachable,
        };
        if (present) try chunks.append(gpa, .{ .id = id, .bytes = buffer.bytes.items });
    }
    const header = [_]u8{ 'C', 'G', 'P', 'H', 1, if (kind == .sha1) 1 else 2, @intCast(chunks.items.len), @intCast(options.bases.len) };
    return format.encode(gpa, kind, &header, chunks.items);
}
