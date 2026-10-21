//! Blame against the real git: the same histories in, every line given to
//! the same commit, at the same line of the same path there, as
//! `git blame --line-porcelain` says.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("../testing/git.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const blame = @import("blame.zig");
const textconv = @import("textconv.zig");
const driver = @import("driver.zig");
const attributes = @import("../patterns.zig").attributes;
const suite = @import("../testing/helpers.zig");

const Oid = hash.Oid;

/// Compare relic's blame of `path` at `commit` with git's, line by line.
fn expectSameAsGit(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *repo_mod.Repository, commit: Oid, path: []const u8, options: blame.Options) !void {
    var hex: [hash.max_hex_len]u8 = undefined;
    const commit_hex = commit.hex(&hex);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "-c", "blame.markIgnoredLines=true", "-c", "blame.markUnblamableLines=true", "blame", "--line-porcelain" });
    if (!options.follow_renames) try args.append(gpa, "--no-follow");
    var ignore_hex: std.ArrayList([hash.max_hex_len]u8) = .empty;
    defer ignore_hex.deinit(gpa);
    try ignore_hex.resize(gpa, options.ignore.len);
    for (options.ignore, ignore_hex.items) |oid, *buf| try args.appendSlice(gpa, &.{ "--ignore-rev", oid.hex(buf) });
    try args.appendSlice(gpa, &.{ commit_hex, "--", path });
    const porcelain = try git.run(io, args.items);
    defer gpa.free(porcelain);

    // `<commit> <orig> <final>` then the headers, `filename <path>` last.
    var expected: std.Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    var head: ?[]const u8 = null;
    var marks: [2]bool = .{ false, false };
    var filename: []const u8 = "";
    while (lines.next()) |line| {
        if (line.len > 40 and std.ascii.isHex(line[0]) and line[40] == ' ' and head == null) {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const sha = fields.next().?;
            const orig = fields.next().?;
            const final = fields.next().?;
            try expected.writer.print("{s} {s} {s}", .{ final, sha, orig });
            head = line;
            marks = .{ false, false };
        } else if (head != null and std.mem.eql(u8, line, "ignored")) {
            marks[0] = true;
        } else if (head != null and std.mem.eql(u8, line, "unblamable")) {
            marks[1] = true;
        } else if (head != null and std.mem.startsWith(u8, line, "filename ")) {
            filename = line["filename ".len..];
        } else if (head != null and line.len != 0 and line[0] == '\t') {
            // The line itself, after the headers and the marks.
            try expected.writer.print(" {s}{s}{s}\n", .{ filename, if (marks[0]) " ignored" else "", if (marks[1]) " unblamable" else "" });
            head = null;
        }
    }

    var got = try blame.file(gpa, io, repo.objectDatabase(), .{ .commit = commit, .path = path }, options);
    defer got.deinit();
    var actual: std.Io.Writer.Allocating = .init(gpa);
    defer actual.deinit();
    var next: u32 = 1;
    for (got.hunks) |h| {
        try std.testing.expectEqual(next, h.final_start);
        for (0..h.count) |i| {
            const n: u32 = @intCast(i);
            try actual.writer.print("{d} {s} {d} {s}{s}{s}\n", .{ h.final_start + n, h.commit.hex(&hex), h.orig_start + n, h.path, if (h.ignored) " ignored" else "", if (h.unblamable) " unblamable" else "" });
        }
        next += h.count;
    }
    std.testing.expectEqualStrings(expected.written(), actual.written()) catch |err| {
        std.debug.print("blame of {s} at {s}\n", .{ path, commit_hex });
        return err;
    };
}

/// A history built straight into the object database: each commit's files
/// by path, its parents and its time.
const History = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    repo: *repo_mod.Repository,
    io: Io,

    const Files = std.array_hash_map.String([]const u8);

    fn commit(h: *History, files: *const Files, parents: []const Oid, when: i64) !Oid {
        // `dir/name` one level down at most.
        var top: object.Tree.Builder = .init(h.gpa, .sha1);
        defer top.deinit();
        var sub: object.Tree.Builder = .init(h.gpa, .sha1);
        defer sub.deinit();
        for (files.keys(), files.values()) |path, bytes| {
            const blob = try h.repo.objectDatabase().write(h.io, .blob, bytes);
            if (std.mem.findScalar(u8, path, '/')) |slash| {
                try sub.add(.file, path[slash + 1 ..], blob);
            } else try top.add(.file, path, blob);
        }
        if (sub.count() != 0) {
            const bytes = try sub.build();
            defer h.gpa.free(bytes);
            try top.add(.tree, "dir", try h.repo.objectDatabase().write(h.io, .tree, bytes));
        }
        const tree_bytes = try top.build();
        defer h.gpa.free(tree_bytes);
        const tree = try h.repo.objectDatabase().write(h.io, .tree, tree_bytes);
        const who: object.Signature = .{ .name = "T", .email = "t@example.invalid", .when_secs = when, .offset_minutes = 0 };
        return h.repo.writeCommit(h.io, .{ .tree = tree, .parents = parents, .author = who, .committer = who, .message = "c\n" }, .{});
    }
};

fn text(a: Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.items;
}

test "blame gives each line the commit git gives it, across edits, a rename and a merge" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var h: History = .{ .gpa = gpa, .arena = .init(gpa), .repo = &repo, .io = io };
    defer h.arena.deinit();
    const a = h.arena.allocator();

    var files: History.Files = .empty;
    try files.put(a, "a.txt", try text(a, &.{ "one", "two", "three", "four", "five", "six" }));
    try files.put(a, "other", try text(a, &.{ "unrelated", "lines" }));
    const root = try h.commit(&files, &.{}, 1000);

    try files.put(a, "a.txt", try text(a, &.{ "one", "TWO", "three", "four", "five", "six", "seven" }));
    const edit = try h.commit(&files, &.{root}, 2000);

    // Renamed, with a line changed on the way.
    _ = files.orderedRemove("a.txt");
    try files.put(a, "dir/b.txt", try text(a, &.{ "zero", "one", "TWO", "three", "four", "five", "six", "seven" }));
    const moved = try h.commit(&files, &.{edit}, 3000);

    // A side branch from the edit that changes the end, merged back.
    var side_files: History.Files = .empty;
    try side_files.put(a, "a.txt", try text(a, &.{ "one", "TWO", "three", "four", "FIVE", "six", "seven" }));
    try side_files.put(a, "other", try text(a, &.{ "unrelated", "lines" }));
    const side = try h.commit(&side_files, &.{edit}, 2500);
    try files.put(a, "dir/b.txt", try text(a, &.{ "zero", "one", "TWO", "three", "four", "FIVE", "six", "seven", "eight" }));
    const merged = try h.commit(&files, &.{ moved, side }, 4000);

    try expectSameAsGit(gpa, io, &git, &repo, merged, "dir/b.txt", .{});
    try expectSameAsGit(gpa, io, &git, &repo, merged, "dir/b.txt", .{ .follow_renames = false });
    try expectSameAsGit(gpa, io, &git, &repo, merged, "other", .{});
    try expectSameAsGit(gpa, io, &git, &repo, edit, "a.txt", .{});
    try std.testing.expectError(error.PathNotFound, blame.file(gpa, io, repo.objectDatabase(), .{ .commit = merged, .path = "a.txt" }, .{}));
}

test "blame of random histories with merges, renames and repeated lines agrees with git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var h: History = .{ .gpa = gpa, .arena = .init(gpa), .repo = &repo, .io = io };
    defer h.arena.deinit();
    const a = h.arena.allocator();

    // Few distinct lines, so that the diffs have choices to make.
    const vocabulary = [_][]const u8{ "{", "}", "", "x = 1;", "y = 2;", "return x;", "// note", "if (x) {", "    call();" };
    var prng: std.Random.DefaultPrng = .init(0xb1a3e);
    const random = prng.random();

    const State = struct { oid: Oid, files: History.Files };
    for (0..testgit.corpusCases(12)) |round| {
        var commits: std.ArrayList(State) = .empty;
        var files: History.Files = .empty;
        for ([_][]const u8{ "f0", "f1", "dir/f2" }) |path| {
            var lines: std.ArrayList([]const u8) = .empty;
            for (0..4 + random.uintLessThan(usize, 12)) |_| try lines.append(a, vocabulary[random.uintLessThan(usize, vocabulary.len)]);
            try files.put(a, path, try text(a, lines.items));
        }
        try commits.append(a, .{ .oid = try h.commit(&files, &.{}, 1_000_000), .files = files });

        for (0..14) |n| {
            const first = commits.items[commits.items.len - 1 - random.uintLessThan(usize, @min(3, commits.items.len))];
            var next = try first.files.clone(a);
            var parents: std.ArrayList(Oid) = .empty;
            try parents.append(a, first.oid);
            if (commits.items.len > 2 and random.uintLessThan(u8, 4) == 0) {
                // A merge: some of the other parent's lines come in.
                const second = commits.items[random.uintLessThan(usize, commits.items.len)];
                if (!second.oid.eql(first.oid)) {
                    try parents.append(a, second.oid);
                    for (next.keys(), next.values()) |path, *bytes| {
                        const theirs = second.files.get(path) orelse continue;
                        if (random.boolean()) bytes.* = theirs else {
                            const ours_lines = try splitText(a, bytes.*);
                            const their_lines = try splitText(a, theirs);
                            const cut = random.uintLessThan(usize, ours_lines.len + 1);
                            const from = random.uintLessThan(usize, their_lines.len + 1);
                            var mixed: std.ArrayList([]const u8) = .empty;
                            try mixed.appendSlice(a, ours_lines[0..cut]);
                            try mixed.appendSlice(a, their_lines[from..]);
                            bytes.* = try text(a, mixed.items);
                        }
                    }
                }
            }
            // Edits to a file or two.
            for (0..1 + random.uintLessThan(usize, 2)) |_| {
                const which = random.uintLessThan(usize, next.count());
                var lines: std.ArrayList([]const u8) = .empty;
                try lines.appendSlice(a, try splitText(a, next.values()[which]));
                for (0..1 + random.uintLessThan(usize, 3)) |_| {
                    const at = random.uintLessThan(usize, lines.items.len + 1);
                    switch (random.uintLessThan(u8, 3)) {
                        0 => try lines.insert(a, at, vocabulary[random.uintLessThan(usize, vocabulary.len)]),
                        1 => if (at < lines.items.len) {
                            _ = lines.orderedRemove(at);
                        },
                        else => if (at < lines.items.len) {
                            lines.items[at] = vocabulary[random.uintLessThan(usize, vocabulary.len)];
                        },
                    }
                }
                next.values()[which] = try text(a, lines.items);
            }
            // Now and then a file moves, under a name of its own.
            if (random.uintLessThan(u8, 5) == 0) {
                const which = random.uintLessThan(usize, next.count());
                const bytes = next.values()[which];
                next.orderedRemoveAt(which);
                const name = try a.print("{s}m{d}", .{ if (random.boolean()) "dir/" else "", n });
                try next.put(a, name, bytes);
            }
            // Committer dates out of order now and then, as clocks are.
            const when: i64 = 1_000_000 + @as(i64, @intCast(n)) * 100 - @as(i64, random.uintLessThan(u8, 3)) * 250;
            try commits.append(a, .{ .oid = try h.commit(&next, parents.items, when), .files = next });
        }

        // The tip, and one commit along the way.
        const tip = commits.items[commits.items.len - 1];
        const middle = commits.items[commits.items.len / 2 + random.uintLessThan(usize, commits.items.len / 2)];
        for ([_]State{ tip, middle }) |at| {
            for (at.files.keys()) |path| {
                expectSameAsGit(gpa, io, &git, &repo, at.oid, path, .{}) catch |err| {
                    std.debug.print("round {d}\n", .{round});
                    return err;
                };
            }
        }
        // The tip again with commits along the way ignored, the tip itself
        // and back-to-back ones among them now and then.
        for (0..3) |_| {
            var ignore: std.ArrayList(Oid) = .empty;
            for (0..1 + random.uintLessThan(usize, 4)) |_| try ignore.append(a, commits.items[random.uintLessThan(usize, commits.items.len)].oid);
            for (tip.files.keys()) |path| {
                expectSameAsGit(gpa, io, &git, &repo, tip.oid, path, .{ .ignore = ignore.items }) catch |err| {
                    std.debug.print("round {d}, ignoring {d}\n", .{ round, ignore.items.len });
                    return err;
                };
            }
        }
    }
}

fn splitText(a: Allocator, bytes: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| try out.append(a, line);
    // The text ends in a newline, which leaves one empty piece after it.
    if (out.items.len != 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

test "an ignored commit's changed lines go where git's guess sends them, marked ignored, or stay unblamable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var h: History = .{ .gpa = gpa, .arena = .init(gpa), .repo = &repo, .io = io };
    defer h.arena.deinit();
    const a = h.arena.allocator();

    var files: History.Files = .empty;
    try files.put(a, "code.c", try text(a, &.{ "int main(void)", "{", "    int count = 0;", "    for (int i = 0; i < 10; i++)", "        count += i;", "    return count;", "}" }));
    const root = try h.commit(&files, &.{}, 1000);
    try files.put(a, "code.c", try text(a, &.{ "int main(void)", "{", "    int total = 0;", "    for (int i = 0; i < 10; i++)", "        total += i;", "    printf(\"%d\\n\", total);", "    return total;", "}" }));
    const rename = try h.commit(&files, &.{root}, 2000);
    // A reformat: the same words with other spacing and case, a brace
    // moved, and a line no parent has.
    try files.put(a, "code.c", try text(a, &.{ "int main(void) {", "\tint TOTAL = 0;", "\tfor (int i = 0; i < 10; i++) TOTAL += i;", "\t/* a brand new remark xyzzy */", "\tprintf(\"%d\\n\", TOTAL);", "\treturn TOTAL;", "}" }));
    const reformat = try h.commit(&files, &.{rename}, 3000);
    try files.put(a, "code.c", try text(a, &.{ "int main(void) {", "\tint TOTAL = 0;", "\tfor (int i = 0; i < 20; i++) TOTAL += i;", "\t/* a brand new remark xyzzy */", "\tprintf(\"%d\\n\", TOTAL);", "\treturn TOTAL;", "}" }));
    const tip = try h.commit(&files, &.{reformat}, 4000);

    try expectSameAsGit(gpa, io, &git, &repo, tip, "code.c", .{ .ignore = &.{reformat} });
    try expectSameAsGit(gpa, io, &git, &repo, tip, "code.c", .{ .ignore = &.{ reformat, rename } });
    try expectSameAsGit(gpa, io, &git, &repo, tip, "code.c", .{ .ignore = &.{ tip, root } });

    // The same commits named in files, as `--ignore-revs-file` and
    // `blame.ignoreRevsFile` name them: comments, blank lines, a name that
    // is no commit passed over, and an empty file name forgetting.
    var hex: [3][hash.max_hex_len]u8 = undefined;
    const listed = try a.print("# reformatting\n  {s}  # the big one\n\n{s}\n", .{ reformat.hex(&hex[0]), rename.hex(&hex[1]) });
    try git.writeFile(io, "ignore-a", listed);
    try git.writeFile(io, "ignore-b", try a.print("{s}\n", .{root.hex(&hex[2])}));
    try git.writeFile(io, "bad", "not-an-object-name\n");
    try git.exec(io, &.{ "config", "blame.ignoreRevsFile", "ignore-b" });
    try git.exec(io, &.{ "config", "--add", "blame.ignoreRevsFile", "ignore-a" });
    var config_repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer config_repo.deinit(io);
    const both = try blame.ignoredRevisions(a, io, config_repo.objectDatabase(), .{ .config = config_repo.configuration(), .base = git.dir });
    try std.testing.expectEqual(@as(usize, 3), both.len);
    const reset = try blame.ignoredRevisions(a, io, config_repo.objectDatabase(), .{ .config = config_repo.configuration(), .base = git.dir, .files = &.{ "", "ignore-a" } });
    try std.testing.expectEqual(@as(usize, 2), reset.len);
    try std.testing.expectError(error.InvalidIgnoreRev, blame.ignoredRevisions(a, io, config_repo.objectDatabase(), .{ .config = config_repo.configuration(), .base = git.dir, .files = &.{"bad"} }));
    try std.testing.expectError(error.IgnoreRevsFileMissing, blame.ignoredRevisions(a, io, config_repo.objectDatabase(), .{ .config = config_repo.configuration(), .base = git.dir, .files = &.{"missing"} }));
}

test "blame ignoring random reformats, lines changed a little and moved about, agrees with git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var h: History = .{ .gpa = gpa, .arena = .init(gpa), .repo = &repo, .io = io };
    defer h.arena.deinit();
    const a = h.arena.allocator();

    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "count", "total", "index", "value", "parse", "print" };
    var prng: std.Random.DefaultPrng = .init(0xf1a9e7);
    const random = prng.random();
    for (0..testgit.corpusCases(64)) |round| {
        var lines: std.ArrayList([]const u8) = .empty;
        for (0..6 + random.uintLessThan(usize, 18)) |_| {
            try lines.append(a, try a.print("{s} = {s}({s});", .{ words[random.uintLessThan(usize, words.len)], words[random.uintLessThan(usize, words.len)], words[random.uintLessThan(usize, words.len)] }));
        }
        var files: History.Files = .empty;
        try files.put(a, "f", try text(a, lines.items));
        var commits: std.ArrayList(Oid) = .empty;
        try commits.append(a, try h.commit(&files, &.{}, 1_000_000));
        for (0..6) |n| {
            for (0..1 + random.uintLessThan(usize, 5)) |_| {
                const at = random.uintLessThan(usize, lines.items.len + 1);
                switch (random.uintLessThan(u8, 5)) {
                    // A line touched: its case, its spacing, a word.
                    0, 1 => if (at < lines.items.len) {
                        const old = lines.items[at];
                        lines.items[at] = switch (random.uintLessThan(u8, 3)) {
                            0 => try std.ascii.allocUpperString(a, old),
                            1 => try a.print("  {s} ", .{old}),
                            else => try a.print("{s} {s}", .{ old, words[random.uintLessThan(usize, words.len)] }),
                        };
                    },
                    // Two lines joined, or one split.
                    2 => if (at + 1 < lines.items.len) {
                        lines.items[at] = try a.print("{s} {s}", .{ lines.items[at], lines.items[at + 1] });
                        _ = lines.orderedRemove(at + 1);
                    },
                    3 => if (at < lines.items.len) {
                        const old = lines.items[at];
                        const cut = old.len / 2;
                        lines.items[at] = old[0..cut];
                        try lines.insert(a, at + 1, old[cut..]);
                    },
                    else => try lines.insert(a, at, try a.print("{s}();", .{words[random.uintLessThan(usize, words.len)]})),
                }
            }
            try files.put(a, "f", try text(a, lines.items));
            try commits.append(a, try h.commit(&files, &.{commits.items[commits.items.len - 1]}, 1_000_000 + @as(i64, @intCast(n + 1)) * 100));
        }
        const tip = commits.items[commits.items.len - 1];
        for (0..4) |_| {
            var ignore: std.ArrayList(Oid) = .empty;
            for (0..1 + random.uintLessThan(usize, 3)) |_| try ignore.append(a, commits.items[1 + random.uintLessThan(usize, commits.items.len - 1)]);
            expectSameAsGit(gpa, io, &git, &repo, tip, "f", .{ .ignore = ignore.items }) catch |err| {
                std.debug.print("round {d}\n", .{round});
                return err;
            };
        }
    }
}

test "with a driver's textconv each line goes where git blame sends it, by the text the program writes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const command = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), "upper-file");
    defer gpa.free(command);
    try git.exec(io, &.{ "config", "diff.up.textconv", command });
    try git.writeFile(io, ".gitattributes", "*.txt diff=up\n");
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var h: History = .{ .gpa = gpa, .arena = .init(gpa), .repo = &repo, .io = io };
    defer h.arena.deinit();
    const a = h.arena.allocator();

    // Changes of case the program's text does not see, beside real ones.
    var files: History.Files = .empty;
    try files.put(a, "notes.txt", try text(a, &.{ "first", "second", "third" }));
    try files.put(a, "notes.dat", try text(a, &.{ "first", "second", "third" }));
    const root = try h.commit(&files, &.{}, 1000);
    try files.put(a, "notes.txt", try text(a, &.{ "FIRST", "second", "third", "fourth" }));
    try files.put(a, "notes.dat", try text(a, &.{ "FIRST", "second", "third", "fourth" }));
    const grow = try h.commit(&files, &.{root}, 2000);
    try files.put(a, "notes.txt", try text(a, &.{ "FIRST", "Second", "THIRD", "fourth", "fifth" }));
    try files.put(a, "notes.dat", try text(a, &.{ "FIRST", "Second", "THIRD", "fourth", "fifth" }));
    const tip = try h.commit(&files, &.{grow}, 3000);

    var env = try testgit.datedEnv(gpa, 0);
    defer env.deinit();
    var attrs = try attributes.Attrs.init(gpa, .{});
    defer attrs.deinit();
    const tc: textconv.Textconv = .{ .programs = .{ .environ = &env } };
    const drivers: driver.Drivers = .{ .attrs = &attrs, .work_dir = git.dir, .config = repo.configuration() };
    try expectSameAsGit(gpa, io, &git, &repo, tip, "notes.txt", .{ .textconv = &tc, .drivers = drivers });
    try expectSameAsGit(gpa, io, &git, &repo, tip, "notes.dat", .{ .textconv = &tc, .drivers = drivers });
}
