//! The strategy options that change what a merge compares, against git's:
//! the whitespace options `ignore-space-change`, `ignore-all-space`,
//! `ignore-space-at-eol` and `ignore-cr-at-eol`, and `subtree` with and
//! without a path. Each merge is made by `git merge-tree --write-tree` and
//! by `ort.mergeCommits` with the same words, and the trees and the
//! conflicted stages have to be the same.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const ort = @import("ort.zig");
const strategy = @import("strategy.zig");
const blobmerge = @import("blobmerge.zig");
const testgit = @import("testgit.zig");

const Oid = hash.Oid;

/// One merge to make: the two sides by name, and the words.
const Case = struct { ours: []const u8, theirs: []const u8 };

/// What `merge-tree --stdin -z --no-messages` prints for one merge,
/// made from a result: the tree, then each stage of each conflicted path.
fn render(gpa: Allocator, result: *const ort.Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var hex: [hash.max_hex_len]u8 = undefined;
    try w.print("{s}\x00", .{result.tree.hex(&hex)});
    for (result.conflicted) |c| {
        for (c.stages, 1..) |stage, n| {
            const entry = stage orelse continue;
            try w.print("{o:0>6} {s} {d}\t{s}\x00", .{ entry.mode, entry.oid.hex(&hex), n, c.path });
        }
    }
    return out.toOwnedSlice();
}

/// Split `merge-tree --stdin -z --no-messages` output into one piece per
/// merge, each without its status and final separator: `<tree>\0` and its
/// stages.
fn splitMerges(arena: Allocator, out: []const u8) ![]const []const u8 {
    var pieces: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < out.len) {
        // The status, 0 or 1.
        const status_end = std.mem.indexOfScalarPos(u8, out, at, 0) orelse return error.MalformedOutput;
        const start = status_end + 1;
        var end = start;
        while (true) {
            const nul = std.mem.indexOfScalarPos(u8, out, end, 0) orelse return error.MalformedOutput;
            if (nul == end) break;
            end = nul + 1;
        }
        try pieces.append(arena, out[start..end]);
        at = end + 1;
    }
    return pieces.items;
}

fn visible(gpa: Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, bytes);
    for (out) |*c| {
        if (c.* == 0) c.* = '|';
    }
    return out;
}

/// Each case merged by git and here under `words`, `style` the conflict
/// style both are told.
fn expectSameMerges(
    gpa: Allocator,
    io: Io,
    repo: *testgit.Repo,
    cases: []const Case,
    words: []const []const u8,
    style: blobmerge.ConflictStyle,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "-c", try std.fmt.allocPrint(arena, "merge.conflictStyle={t}", .{style}), "merge-tree", "--stdin", "-z", "--no-messages" });
    for (words) |word| try args.appendSlice(arena, &.{ "-X", word });
    var input: std.ArrayList(u8) = .empty;
    for (cases) |c| try input.print(arena, "{s} {s}\n", .{ c.ours, c.theirs });
    const out = try repo.runInput(io, args.items, input.items);
    defer gpa.free(out);
    const expected = try splitMerges(arena, out);
    try std.testing.expectEqual(cases.len, expected.len);

    var settings: strategy.Settings = .{};
    for (words) |word| try settings.apply(word);

    // Every branch's commit, read once.
    var tips: std.StringHashMapUnmanaged(Oid) = .empty;
    const listing = try repo.run(io, &.{ "for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads/" });
    defer gpa.free(listing);
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedOutput;
        try tips.put(arena, line[0..space], try Oid.parse(.sha1, line[space + 1 ..]));
    }

    const git_dir = try repo.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    for (cases, expected) |c, want| {
        const ours = tips.get(c.ours) orelse return error.MissingBranch;
        const theirs = tips.get(c.theirs) orelse return error.MissingBranch;
        var result = try ort.mergeCommits(gpa, io, &db, ours, theirs, null, .{
            .labels = .{ .ours = c.ours, .theirs = c.theirs },
            .conflict_style = style,
            .favor = settings.favor,
            .algorithm = settings.algorithm,
            .minimal = settings.minimal,
            .whitespace = settings.whitespace,
            .subtree_shift = settings.subtree_shift,
        });
        defer result.deinit();
        const got = try render(gpa, &result);
        defer gpa.free(got);
        if (!std.mem.eql(u8, want, got)) {
            const e = try visible(gpa, want);
            defer gpa.free(e);
            const g = try visible(gpa, got);
            defer gpa.free(g);
            std.debug.print("merge of {s} and {s} with {f} ({t}) differs\ngit:  {s}\nours: {s}\n", .{ c.ours, c.theirs, Words{ .words = words }, style, e, g });
            return error.TestExpectedEqual;
        }
    }
}

/// The words as `-X` would take them, for a failure's message.
const Words = struct {
    words: []const []const u8,

    pub fn format(w: Words, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (w.words) |word| try writer.print(" -X {s}", .{word});
    }
};

//=========================================================================
// Whitespace
//=========================================================================

/// Lines that differ from each other in whitespace every way git tells
/// apart: inside, before, after, a carriage return, a missing newline.
const Texts = struct {
    random: std.Random,
    arena: Allocator,

    const words = [_][]const u8{ "alpha", "beta", "gamma beta", "delta\tepsilon", "zeta  eta" };
    const leads = [_][]const u8{ "", "", " ", "\t" };
    const tails = [_][]const u8{ "", "", "", " ", "\t", "\r", " \r" };

    fn line(t: Texts, word: []const u8) ![]const u8 {
        return std.fmt.allocPrint(t.arena, "{s}{s}{s}\n", .{ t.pick(&leads), word, t.pick(&tails) });
    }

    fn pick(t: Texts, from: []const []const u8) []const u8 {
        return from[t.random.uintLessThan(usize, from.len)];
    }

    /// `line` with its whitespace changed and its word kept.
    fn respaced(t: Texts, old: []const u8) ![]const u8 {
        var body = std.mem.trimEnd(u8, old, "\n");
        body = std.mem.trim(u8, body, " \t\r");
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(t.arena, t.pick(&leads));
        for (body) |c| {
            if (c == ' ' or c == '\t') {
                try out.appendSlice(t.arena, t.pick(&.{ " ", "  ", "\t" }));
            } else try out.append(t.arena, c);
        }
        try out.appendSlice(t.arena, t.pick(&tails));
        try out.append(t.arena, '\n');
        return out.items;
    }

    fn base(t: Texts) ![]const []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        const n = 4 + t.random.uintLessThan(usize, 9);
        for (0..n) |_| try lines.append(t.arena, try t.line(t.pick(&words)));
        return lines.items;
    }

    /// A side: a few edits of `from`, some only to whitespace.
    fn side(t: Texts, from: []const []const u8) ![]const []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        try lines.appendSlice(t.arena, from);
        const edits = 1 + t.random.uintLessThan(usize, 4);
        for (0..edits) |_| {
            const at = t.random.uintLessThan(usize, lines.items.len + 1);
            switch (t.random.uintLessThan(u8, 6)) {
                0, 1, 2 => if (at < lines.items.len) {
                    lines.items[at] = try t.respaced(lines.items[at]);
                },
                3 => try lines.insert(t.arena, at, try t.line(t.pick(&words))),
                4 => if (at < lines.items.len and lines.items.len > 1) {
                    _ = lines.orderedRemove(at);
                },
                5 => if (at < lines.items.len) {
                    lines.items[at] = try t.line("changed");
                },
                else => unreachable,
            }
        }
        return lines.items;
    }

    /// The lines as a file, its last newline dropped now and then.
    fn join(t: Texts, lines: []const []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (lines) |l| try out.appendSlice(t.arena, l);
        if (out.items.len != 0 and t.random.uintLessThan(u8, 5) == 0) out.items.len -= 1;
        return out.items;
    }
};

/// A `fast-import` commit on `branch` holding `files`, after `from` when
/// given.
fn importCommit(arena: Allocator, stream: *std.ArrayList(u8), branch: []const u8, from: ?[]const u8, files: []const [2][]const u8) !void {
    try stream.print(arena, "commit refs/heads/{s}\ncommitter t <t@example.com> 0 +0000\ndata 0\n", .{branch});
    if (from) |f| try stream.print(arena, "from refs/heads/{s}\n", .{f});
    try stream.appendSlice(arena, "deleteall\n");
    for (files) |f| {
        try stream.print(arena, "M 100644 inline {s}\ndata {d}\n", .{ f[0], f[1].len });
        try stream.appendSlice(arena, f[1]);
        try stream.append(arena, '\n');
    }
    try stream.append(arena, '\n');
}

test "the whitespace strategy options merge as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const t: Texts = .{ .random = prng.random(), .arena = arena };
    var stream: std.ArrayList(u8) = .empty;
    var cases: std.ArrayList(Case) = .empty;
    const count = testgit.corpusCases(150);
    for (0..count) |n| {
        const base = try t.base();
        const b = try std.fmt.allocPrint(arena, "b{d}", .{n});
        const o = try std.fmt.allocPrint(arena, "o{d}", .{n});
        const th = try std.fmt.allocPrint(arena, "t{d}", .{n});
        try importCommit(arena, &stream, b, null, &.{.{ "f", try t.join(base) }});
        try importCommit(arena, &stream, o, b, &.{.{ "f", try t.join(try t.side(base)) }});
        try importCommit(arena, &stream, th, b, &.{.{ "f", try t.join(try t.side(base)) }});
        try cases.append(arena, .{ .ours = o, .theirs = th });
    }
    // Where git's line comparison and its line classes part: a carriage
    // return that ends a file is kept, one before a newline is not, yet
    // the two sides' runs compare the same when both changed a line.
    const edges = [_][3][]const u8{
        .{ "a\nb\n", "a\nx\r", "a\nx\r\n" },
        .{ "a\nb\n", "a\nx\r\n", "a\nx\r" },
        .{ "a\nb\n", "a\nx", "a\nx\n" },
        .{ "a\nb\nc\n", "a\nx \nc", "a\nx\nc\n" },
        .{ "a\nb", "a\nb\n", "a \nb" },
        .{ "a\nb\nc\n", "a\nb\r\nc\n", "a\nb\nc\r" },
    };
    for (edges, 0..) |edge, n| {
        const b = try std.fmt.allocPrint(arena, "eb{d}", .{n});
        const o = try std.fmt.allocPrint(arena, "eo{d}", .{n});
        const th = try std.fmt.allocPrint(arena, "et{d}", .{n});
        try importCommit(arena, &stream, b, null, &.{.{ "f", edge[0] }});
        try importCommit(arena, &stream, o, b, &.{.{ "f", edge[1] }});
        try importCommit(arena, &stream, th, b, &.{.{ "f", edge[2] }});
        try cases.append(arena, .{ .ours = o, .theirs = th });
        try cases.append(arena, .{ .ours = th, .theirs = o });
    }
    gpa.free(try repo.runInput(io, &.{ "fast-import", "--quiet" }, stream.items));

    const word_sets = [_][]const []const u8{
        &.{},
        &.{"ignore-space-change"},
        &.{"ignore-all-space"},
        &.{"ignore-space-at-eol"},
        &.{"ignore-cr-at-eol"},
        &.{ "ignore-cr-at-eol", "ignore-space-at-eol" },
        &.{ "ignore-space-change", "diff-algorithm=myers" },
        &.{ "ignore-all-space", "patience" },
        &.{ "ignore-space-change", "theirs" },
    };
    for (word_sets) |words| {
        for ([_]blobmerge.ConflictStyle{ .merge, .diff3, .zdiff3 }) |style| {
            try expectSameMerges(gpa, io, &repo, cases.items, words, style);
        }
    }
}

//=========================================================================
// Subtree
//=========================================================================

/// A library and a project that keeps it under a directory: the files of
/// each, some edits on both sides, and a history git's subtree merges
/// run on.
const Trees = struct {
    random: std.Random,
    arena: Allocator,

    const dirs = [_][]const u8{ "", "", "src/", "doc/", "src/core/" };
    const names = [_][]const u8{ "a", "b", "README", "main.c", "x.h" };

    fn files(t: Trees, n: usize) ![]const [2][]const u8 {
        var out: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (0..n) |i| {
            const path = try std.fmt.allocPrint(t.arena, "{s}{s}", .{ dirs[t.random.uintLessThan(usize, dirs.len)], names[t.random.uintLessThan(usize, names.len)] });
            try out.put(t.arena, path, try std.fmt.allocPrint(t.arena, "{s}\nline {d}\nend\n", .{ path, i % 3 }));
        }
        return pairs(t.arena, out);
    }

    fn pairs(arena: Allocator, map: std.StringArrayHashMapUnmanaged([]const u8)) ![]const [2][]const u8 {
        const out = try arena.alloc([2][]const u8, map.count());
        for (map.keys(), map.values(), out) |k, v, *p| p.* = .{ k, v };
        return out;
    }

    /// `from` with a line of some files changed, a file added, a file
    /// dropped.
    fn edit(t: Trees, from: []const [2][]const u8, tag: []const u8) ![]const [2][]const u8 {
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (from) |f| try map.put(t.arena, f[0], f[1]);
        for (map.values()) |*v| {
            if (t.random.uintLessThan(u8, 3) == 0) v.* = try std.fmt.allocPrint(t.arena, "{s}{s} edit\n", .{ v.*, tag });
        }
        if (t.random.boolean()) try map.put(t.arena, try std.fmt.allocPrint(t.arena, "new-{s}", .{tag}), "new\n");
        if (map.count() > 1 and t.random.boolean()) map.orderedRemoveAt(t.random.uintLessThan(usize, map.count()));
        return pairs(t.arena, map);
    }

    /// `inner` under `prefix`, beside `outer`.
    fn nest(t: Trees, outer: []const [2][]const u8, prefix: []const u8, inner: []const [2][]const u8) ![]const [2][]const u8 {
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (outer) |f| {
            if (std.mem.startsWith(u8, f[0], prefix)) continue;
            try map.put(t.arena, f[0], f[1]);
        }
        for (inner) |f| try map.put(t.arena, try std.fmt.allocPrint(t.arena, "{s}{s}", .{ prefix, f[0] }), f[1]);
        return pairs(t.arena, map);
    }
};

test "the subtree strategy options line the trees up as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prng: std.Random.DefaultPrng = .init(0x7a11);
    const t: Trees = .{ .random = prng.random(), .arena = arena };
    var stream: std.ArrayList(u8) = .empty;
    var cases: std.ArrayList(Case) = .empty;
    const prefixes = [_][]const u8{ "lib/", "vendor/lib/", "third/party/lib/", "src/" };
    const count = testgit.corpusCases(60);
    for (0..count) |n| {
        const prefix = prefixes[n % prefixes.len];
        const lib1 = try t.files(3 + t.random.uintLessThan(usize, 6));
        const project = try t.files(2 + t.random.uintLessThan(usize, 6));
        const l1 = try std.fmt.allocPrint(arena, "l1-{d}", .{n});
        const l2 = try std.fmt.allocPrint(arena, "l2-{d}", .{n});
        const p = try std.fmt.allocPrint(arena, "p-{d}", .{n});
        // The library's history, then the project that took it in at its
        // first version, both going on from there.
        try importCommit(arena, &stream, l1, null, lib1);
        try importCommit(arena, &stream, l2, l1, try t.edit(lib1, "lib"));
        const nested = try t.nest(project, prefix, lib1);
        // The project's own edits, to its files and to its copy of the
        // library, on top of the commit that took the library in.
        const edited = try t.nest(try t.edit(project, "proj"), prefix, try t.edit(lib1, "copy"));
        try importCommit(arena, &stream, p, l1, nested);
        // With no `from` the commit goes on from the branch's tip.
        try importCommit(arena, &stream, p, null, edited);
        try cases.append(arena, .{ .ours = p, .theirs = l2 });
        try cases.append(arena, .{ .ours = l2, .theirs = p });
    }
    gpa.free(try repo.runInput(io, &.{ "fast-import", "--quiet" }, stream.items));

    for ([_][]const []const u8{
        &.{"subtree"},
        &.{"subtree="},
        &.{"subtree=lib"},
        &.{"subtree=vendor/lib/"},
        &.{"subtree=third/party/lib"},
        &.{"subtree=src"},
        &.{"subtree=nowhere"},
        &.{ "subtree", "ignore-space-change" },
    }) |words| {
        try expectSameMerges(gpa, io, &repo, cases.items, words, .merge);
    }
}
