//! The commit-graph, read as an accelerator.
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

const hash = @import("hash.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;

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
    /// A split commit-graph chain. The chain file names several graphs and
    /// this release reads one; a caller gets no accelerator rather than a
    /// wrong answer.
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

    /// Read `objects/info/commit-graph`, or `null` when there is none.
    pub fn open(gpa: Allocator, io: Io, objects_dir: Io.Dir, kind: hash.Kind) Error!?Graph {
        if (objects_dir.access(io, "info/commit-graphs/commit-graph-chain", .{})) |_| {
            return error.SplitGraphUnsupported;
        } else |_| {}
        const bytes = (try fs.readFileAlloc(gpa, io, objects_dir, "info/commit-graph", 1 << 30)) orelse
            return null;
        errdefer gpa.free(bytes);
        return try parse(gpa, kind, bytes);
    }

    /// Read a commit-graph from bytes this takes ownership of.
    pub fn parse(gpa: Allocator, kind: hash.Kind, bytes: []const u8) Error!Graph {
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
        if (bytes[7] != 0) return error.SplitGraphUnsupported;

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
        if (generation_at) |at| {
            if (at + @as(usize, count) * 4 > bytes.len) return error.CorruptCommitGraph;
        }

        return .{
            .gpa = gpa,
            .kind = kind,
            .bytes = bytes,
            .count = count,
            .fanout_at = fanout,
            .names_at = names,
            .data_at = data,
            .edges_at = edges_at,
            .generation_at = generation_at,
            .generation_overflow_at = generation_overflow_at,
        };
    }

    /// Release the graph.
    pub fn deinit(graph: *Graph) void {
        graph.gpa.free(graph.bytes);
        graph.* = undefined;
    }

    /// Whether the graph carries corrected commit dates.
    pub fn hasGenerations(graph: *const Graph) bool {
        return graph.generation_at != null;
    }

    /// The name of the commit at `position`.
    pub fn nameAt(graph: *const Graph, position: u32) Oid {
        const raw_len = graph.kind.rawLen();
        return Oid.fromRaw(graph.kind, graph.bytes[graph.names_at + @as(usize, position) * raw_len ..][0..raw_len]) catch unreachable;
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
            const name = graph.nameAt(mid);
            switch (std.mem.order(u8, name.raw(), raw)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// The commit at `position`.
    pub fn commitAt(graph: *const Graph, position: u32) Error!Commit {
        if (position >= graph.count) return error.CorruptCommitGraph;
        const raw_len = graph.kind.rawLen();
        const row = graph.bytes[graph.data_at + @as(usize, position) * (raw_len + 16) ..];
        const tree = Oid.fromRaw(graph.kind, row[0..raw_len]) catch unreachable;
        const first = std.mem.readInt(u32, row[raw_len..][0..4], .big);
        const second = std.mem.readInt(u32, row[raw_len + 4 ..][0..4], .big);
        const packed_time = std.mem.readInt(u64, row[raw_len + 8 ..][0..8], .big);

        // The low 34 bits are the committer time; the 30 above them are the
        // version one generation, which this deliberately does not read.
        const time: i64 = @intCast(packed_time & ((@as(u64, 1) << 34) - 1));

        const no_parent: u32 = 0x7fff_ffff;
        const extra_bit: u32 = 0x8000_0000;
        var parents: [2]?u32 = .{ null, null };
        var has_extra = false;
        if (first != no_parent) parents[0] = first;
        if (second != no_parent) {
            if (second & extra_bit != 0) {
                has_extra = true;
                parents[1] = second & ~extra_bit;
            } else {
                parents[1] = second;
            }
        }

        var generation: ?u64 = null;
        if (graph.generation_at) |at| {
            const offset = std.mem.readInt(u32, graph.bytes[at + @as(usize, position) * 4 ..][0..4], .big);
            if (offset & 0x8000_0000 == 0) {
                generation = @as(u64, @intCast(time)) + offset;
            } else if (graph.generation_overflow_at) |overflow_at| {
                const row_at = overflow_at + @as(usize, offset & 0x7fff_ffff) * 8;
                if (row_at + 8 > graph.bytes.len) return error.CorruptCommitGraph;
                const wide = std.mem.readInt(u64, graph.bytes[row_at..][0..8], .big);
                generation = @as(u64, @intCast(time)) + wide;
            }
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
        const found = try graph.commitAt(position);
        var out: std.ArrayList(Oid) = .empty;
        errdefer out.deinit(gpa);
        if (found.parents[0]) |at| try out.append(gpa, graph.nameAt(at));
        if (!found.has_extra_parents) {
            if (found.parents[1]) |at| try out.append(gpa, graph.nameAt(at));
            return out.toOwnedSlice(gpa);
        }
        const edges_at = graph.edges_at orelse return error.CorruptCommitGraph;
        var edge = edges_at + @as(usize, found.parents[1].?) * 4;
        while (true) {
            if (edge + 4 > graph.bytes.len) return error.CorruptCommitGraph;
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
        _ = graph.commitAt(i) catch {};
        const parents = graph.parentsOf(gpa, i) catch continue;
        gpa.free(parents);
    }
}
