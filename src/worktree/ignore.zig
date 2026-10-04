//! `.gitignore`, in git's precedence order.
//!
//! Four levels, lowest first: `core.excludesFile`, `$GIT_COMMON_DIR/info/exclude`,
//! and then one level per directory from the root of the working tree down, so
//! a deeper file overrides a shallower one. Within a level the last matching
//! pattern wins, which is what makes a negation work at all.
//!
//! Three cases the field has had to fix and which are tests here before they
//! are code: a pattern in a subdirectory beating one above it, a directory
//! excluded by `dir/*` that must still be entered so a later negation can
//! re-include something inside it, and a bare `!` line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wildmatch = @import("wildmatch.zig");
const fs = @import("../repo/fs.zig");

/// Errors from loading ignore rules.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError;

/// One line of one ignore file.
pub const Pattern = struct {
    /// The line as written, without its newline. Borrowed from the rules.
    text: []const u8,
    /// The glob the line reduces to, with `!`, a leading `/` and a trailing
    /// `/` removed.
    glob: []const u8,
    /// The directory the pattern is relative to, `/`-separated and without a
    /// trailing slash. Empty at the root of the working tree.
    base: []const u8,
    /// Where the pattern came from, for a caller that wants to say which
    /// line decided.
    source: []const u8,
    /// One-based.
    line: u32,
    /// A `!` line: a match re-includes rather than excludes.
    negated: bool,
    /// A trailing `/`: the pattern matches directories only.
    dir_only: bool,
    /// The pattern held a `/` other than a trailing one, so it is matched
    /// against the whole path below `base` rather than against the name.
    anchored: bool,
};

/// What decided, and how.
pub const Match = struct {
    /// Whether the path is excluded. `false` with a pattern means a negation
    /// re-included it; `false` with no pattern means nothing matched.
    excluded: bool,
    /// The pattern that decided, or `null` when none did.
    by: ?Pattern,
};

/// One file's worth of patterns, at one level of precedence.
pub const Level = struct {
    /// The directory this level's patterns are relative to.
    base: []const u8,
    patterns: []Pattern,
    /// How this level compares to the others: a higher number wins.
    depth: u32,
};

/// The loaded ignore rules for a working tree.
///
/// Levels are held in precedence order, lowest first. A directory walk pushes
/// a level as it enters a directory holding a `.gitignore` and pops it on the
/// way out, which is how a deeper file comes to override a shallower one
/// without re-reading anything.
pub const Rules = struct {
    gpa: Allocator,
    /// Everything the rules hold — the text of every file read and the
    /// patterns parsed out of it — comes from here and goes at once.
    arena: *std.heap.ArenaAllocator,
    levels: std.ArrayList(Level),
    /// Whether the filesystem folds case, from `core.ignoreCase`.
    case_fold: bool,

    /// Empty rules, which exclude nothing.
    pub fn init(gpa: Allocator, case_fold: bool) Allocator.Error!Rules {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        return .{
            .gpa = gpa,
            .arena = arena,
            .levels = .empty,
            .case_fold = case_fold,
        };
    }

    /// Release everything.
    pub fn deinit(rules: *Rules) void {
        rules.arena.deinit();
        rules.gpa.destroy(rules.arena);
        rules.levels.deinit(rules.gpa);
        rules.* = undefined;
    }

    /// Load the two levels that come before any `.gitignore`: the file
    /// `core.excludesFile` names, and `info/exclude` in the common
    /// directory.
    ///
    /// Either being absent is not an error; most repositories have neither.
    pub fn loadGlobal(
        rules: *Rules,
        io: Io,
        common_dir: Io.Dir,
        excludes_file: ?[]const u8,
        excludes_dir: ?Io.Dir,
    ) Error!void {
        if (excludes_file) |path| {
            if (excludes_dir) |dir| {
                try rules.addFileIfPresent(io, dir, path, "", path, 0);
            }
        }
        try rules.addFileIfPresent(io, common_dir, "info/exclude", "", "info/exclude", 1);
    }

    /// Load `<base>/.gitignore`, if it is there, as a level relative to
    /// `base`.
    ///
    /// `depth` decides precedence; the walker passes the directory's depth
    /// below the working tree's root, offset past the two global levels.
    pub fn addDirectory(rules: *Rules, io: Io, wt: Io.Dir, base: []const u8, depth: u32) Error!void {
        var path_buf: [4096]u8 = undefined;
        const path = if (base.len == 0)
            ".gitignore"
        else
            std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{base}) catch return;
        try rules.addFileIfPresent(io, wt, path, base, path, depth + 2);
    }

    fn addFileIfPresent(
        rules: *Rules,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        base: []const u8,
        source: []const u8,
        depth: u32,
    ) Error!void {
        const a = rules.arena.allocator();
        const bytes = (try fs.readFileAlloc(a, io, dir, path, 1 << 24)) orelse return;
        try rules.addText(bytes, base, source, depth);
    }

    /// Add a level from text already in memory.
    ///
    /// `text`, `base` and `source` must outlive the rules; text read by
    /// `addDirectory` is held in the rules' own arena.
    pub fn addText(rules: *Rules, text: []const u8, base: []const u8, source: []const u8, depth: u32) Error!void {
        const a = rules.arena.allocator();
        var patterns: std.ArrayList(Pattern) = .empty;
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            line_number += 1;
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const pattern = parseLine(line, base, source, line_number) orelse continue;
            try patterns.append(a, pattern);
        }
        if (patterns.items.len == 0) return;
        try rules.levels.append(rules.gpa, .{
            .base = base,
            .patterns = patterns.items,
            .depth = depth,
        });
    }

    /// Drop every level at or below `depth`, which is what a walk does on
    /// its way back out of a directory.
    pub fn popTo(rules: *Rules, depth: u32) void {
        while (rules.levels.items.len != 0 and
            rules.levels.items[rules.levels.items.len - 1].depth >= depth)
        {
            _ = rules.levels.pop();
        }
    }

    /// Whether `path` is excluded, and by which pattern.
    ///
    /// `path` is `/`-separated and relative to the working tree's root.
    /// Only the path itself is considered: a caller walking a tree does not
    /// descend into an excluded directory, so the parents have already been
    /// decided. `matchPath` is the call that considers them.
    pub fn match(rules: *const Rules, path: []const u8, is_dir: bool) Match {
        var result: Match = .{ .excluded = false, .by = null };
        for (rules.levels.items) |level| {
            const relative = relativeTo(level.base, path) orelse continue;
            const name = basename(relative);
            // Within one file the last matching line wins, which is the
            // whole mechanism a negation depends on.
            for (level.patterns) |pattern| {
                if (pattern.dir_only and !is_dir) continue;
                const subject = if (pattern.anchored) relative else name;
                // git matches a name pattern with `WM_PATHNAME` off and an
                // anchored one with it on, which is what decides whether a
                // `*` in the pattern may cross a slash.
                const matched = wildmatch.match(pattern.glob, subject, .{
                    .pathname = pattern.anchored,
                    .case_fold = rules.case_fold,
                }) catch false;
                if (!matched) continue;
                result = .{ .excluded = !pattern.negated, .by = pattern };
            }
        }
        return result;
    }

    /// Whether `path` is excluded, considering its parent directories.
    ///
    /// A file under an excluded directory is excluded even when no pattern
    /// names the file, and a negation inside an excluded directory does not
    /// bring it back — which is git's rule and the one that surprises
    /// people. The exception, and the case the field had to fix, is a
    /// directory excluded by a pattern that only names its *contents*, such
    /// as `dir/*`: the directory itself is not excluded, so the walk enters
    /// it and a later negation applies.
    pub fn matchPath(rules: *const Rules, path: []const u8, is_dir: bool) Match {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, at, '/')) |slash| {
            const parent = path[0..slash];
            const parent_match = rules.match(parent, true);
            if (parent_match.excluded) return parent_match;
            at = slash + 1;
        }
        return rules.match(path, is_dir);
    }
};

/// A working tree's ignore rules asked one path at a time, outside a walk:
/// a file watcher deciding what to register, a list of changed paths, a
/// checkout looking at an untracked file in its way.
///
/// The `.gitignore` of every folder above a path is read the first time a
/// path below that folder is asked about, the shallowest first, so a deeper
/// file still overrides a shallower one; what was read is kept for the next
/// question. A folder is marked read only once its file has been read or
/// found absent, so a question that failed asks again rather than answering
/// from rules with a level missing. The checker owns its rules: start it
/// with the two global levels, as `Repository.loadIgnore` returns them.
pub const Checker = struct {
    rules: Rules,
    /// The working tree the paths are relative to. Borrowed.
    wt: Io.Dir,
    unreadable: Unreadable,
    /// The folders whose `.gitignore` is in `rules`, or was found absent,
    /// `""` the root. The keys live in the rules' arena.
    read: std.StringHashMapUnmanaged(void) = .empty,

    /// What a `.gitignore` that is there but cannot be read does.
    pub const Unreadable = enum {
        /// The question fails with the error, and the next one reads the
        /// file again: a caller that would rather not answer than answer
        /// without a level.
        fail,
        /// The file counts as absent, as git warns and goes on.
        skip,
    };

    pub const Options = struct {
        unreadable: Unreadable = .fail,
    };

    /// A checker over `rules`, which it now owns, for the working tree `wt`.
    pub fn init(rules: Rules, wt: Io.Dir, options: Options) Checker {
        return .{ .rules = rules, .wt = wt, .unreadable = options.unreadable };
    }

    /// Release the rules and what was read into them.
    pub fn deinit(checker: *Checker) void {
        checker.read.deinit(checker.rules.gpa);
        checker.rules.deinit();
        checker.* = undefined;
    }

    /// The rules with every level read so far, handed back; the checker is
    /// finished, and needs no `deinit`.
    pub fn release(checker: *Checker) Rules {
        checker.read.deinit(checker.rules.gpa);
        const rules = checker.rules;
        checker.* = undefined;
        return rules;
    }

    /// Whether `path` is excluded, its parent folders considered
    /// (`Rules.matchPath`). `path` is `/`-separated and relative to the
    /// working tree's root. A tracked path is the caller's to keep: git
    /// reports it whatever the rules say.
    pub fn excluded(checker: *Checker, io: Io, path: []const u8, is_dir: bool) Error!bool {
        return (try checker.match(io, path, is_dir)).excluded;
    }

    /// What decided `path`, and how, as `excluded` decides it.
    pub fn match(checker: *Checker, io: Io, path: []const u8, is_dir: bool) Error!Match {
        try checker.readAbove(io, path);
        return checker.rules.matchPath(path, is_dir);
    }

    fn readAbove(checker: *Checker, io: Io, path: []const u8) Error!void {
        const gpa = checker.rules.gpa;
        var end: usize = 0;
        var depth: u32 = 0;
        while (true) : (depth += 1) {
            const dir = path[0..end];
            if (!checker.read.contains(dir)) {
                try checker.read.ensureUnusedCapacity(gpa, 1);
                const key = try checker.rules.arena.allocator().dupe(u8, dir);
                checker.rules.addDirectory(io, checker.wt, key, depth) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => if (checker.unreadable == .fail) return err,
                };
                checker.read.putAssumeCapacity(key, {});
            }
            if (end + 1 >= path.len) return;
            end = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse return;
        }
    }
};

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
    return path;
}

fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (!std.mem.startsWith(u8, path, base)) return null;
    if (path.len <= base.len or path[base.len] != '/') return null;
    return path[base.len + 1 ..];
}

/// Read one line of an ignore file, or `null` when it is blank or a comment.
pub fn parseLine(line: []const u8, base: []const u8, source: []const u8, line_number: u32) ?Pattern {
    if (line.len == 0) return null;
    if (line[0] == '#') return null;

    var text = line;
    // Trailing spaces are not part of a pattern unless the last one is
    // escaped.
    var end = text.len;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t')) {
        if (end >= 2 and text[end - 2] == '\\') break;
        end -= 1;
    }
    text = text[0..end];
    if (text.len == 0) return null;

    var negated = false;
    if (text[0] == '!') {
        negated = true;
        text = text[1..];
        // A bare `!` is not a pattern. git skips it rather than treating it
        // as a negation of everything.
        if (text.len == 0) return null;
    } else if (text.len >= 2 and text[0] == '\\' and (text[1] == '!' or text[1] == '#')) {
        text = text[1..];
    }

    var dir_only = false;
    if (text.len > 0 and text[text.len - 1] == '/') {
        dir_only = true;
        text = text[0 .. text.len - 1];
        if (text.len == 0) return null;
    }

    var anchored = false;
    if (text.len > 0 and text[0] == '/') {
        anchored = true;
        text = text[1..];
        if (text.len == 0) return null;
    } else if (std.mem.indexOfScalar(u8, text, '/') != null) {
        // A pattern holding a slash anywhere but at its end is relative to
        // the file's own directory rather than matched against a name.
        anchored = true;
    }

    return .{
        .text = line,
        .glob = text,
        .base = base,
        .source = source,
        .line = line_number,
        .negated = negated,
        .dir_only = dir_only,
        .anchored = anchored,
    };
}

test "the last matching line in a file wins" {
    const gpa = std.testing.allocator;
    var rules: Rules = try .init(gpa, false);
    defer rules.deinit();
    try rules.addText("*.log\n!keep.log\n", "", ".gitignore", 2);

    try std.testing.expect(rules.match("a.log", false).excluded);
    try std.testing.expect(!rules.match("keep.log", false).excluded);
    try std.testing.expect(rules.match("keep.log", false).by != null);
    try std.testing.expect(!rules.match("a.txt", false).excluded);
    try std.testing.expect(rules.match("a.txt", false).by == null);
}

test "a deeper file overrides a shallower one" {
    const gpa = std.testing.allocator;
    var rules: Rules = try .init(gpa, false);
    defer rules.deinit();
    try rules.addText("*.log\n", "", ".gitignore", 2);
    try rules.addText("!important.log\n", "sub", "sub/.gitignore", 3);

    try std.testing.expect(rules.match("a.log", false).excluded);
    try std.testing.expect(rules.match("sub/a.log", false).excluded);
    try std.testing.expect(!rules.match("sub/important.log", false).excluded);
    // The deeper file only applies below its own directory.
    try std.testing.expect(rules.match("important.log", false).excluded);
}

test "a directory excluded by its contents is still entered" {
    const gpa = std.testing.allocator;
    var rules: Rules = try .init(gpa, false);
    defer rules.deinit();
    // `dir/*` names the contents, not the directory, so a negation inside
    // still applies. `other/` names the directory and nothing inside comes
    // back.
    try rules.addText("dir/*\n!dir/keep\nother/\n!other/keep\n", "", ".gitignore", 2);

    try std.testing.expect(!rules.match("dir", true).excluded);
    try std.testing.expect(rules.matchPath("dir/drop", false).excluded);
    try std.testing.expect(!rules.matchPath("dir/keep", false).excluded);
    try std.testing.expect(rules.match("other", true).excluded);
    try std.testing.expect(rules.matchPath("other/keep", false).excluded);
}

test "a bare negation line is not a pattern" {
    try std.testing.expect(parseLine("!", "", "x", 1) == null);
    try std.testing.expect(parseLine("#comment", "", "x", 1) == null);
    try std.testing.expect(parseLine("", "", "x", 1) == null);
    try std.testing.expect(parseLine("   ", "", "x", 1) == null);
    const escaped = parseLine("\\#notacomment", "", "x", 1).?;
    try std.testing.expectEqualStrings("#notacomment", escaped.glob);
}

test "anchoring, directory-only and name matching" {
    const gpa = std.testing.allocator;
    var rules: Rules = try .init(gpa, false);
    defer rules.deinit();
    try rules.addText("/root-only\nbuild/\ndoc/*.txt\nanywhere\n", "", ".gitignore", 2);

    try std.testing.expect(rules.match("root-only", false).excluded);
    try std.testing.expect(!rules.match("sub/root-only", false).excluded);
    try std.testing.expect(rules.match("build", true).excluded);
    try std.testing.expect(!rules.match("build", false).excluded);
    try std.testing.expect(rules.match("doc/a.txt", false).excluded);
    try std.testing.expect(!rules.match("other/doc/a.txt", false).excluded);
    try std.testing.expect(rules.match("anywhere", false).excluded);
    try std.testing.expect(rules.match("deep/nest/anywhere", false).excluded);
}

test "the deciding pattern is reported" {
    const gpa = std.testing.allocator;
    var rules: Rules = try .init(gpa, false);
    defer rules.deinit();
    try rules.addText("*.o\n*.tmp\n", "", ".gitignore", 2);
    const decided = rules.match("a.tmp", false);
    try std.testing.expect(decided.excluded);
    try std.testing.expectEqualStrings("*.tmp", decided.by.?.glob);
    try std.testing.expectEqual(@as(u32, 2), decided.by.?.line);
    try std.testing.expectEqualStrings(".gitignore", decided.by.?.source);
}

test "a checker reads each folder's rules the first time a path below it is asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nbuild/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.gitignore", .data = "!keep.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep/.gitignore", .data = "*.tmp\n" });
    var rules: Rules = try .init(gpa, false);
    try rules.addText("*.secret\n", "", "info/exclude", 1);
    var checker: Checker = .init(rules, tmp.dir, .{});
    defer checker.deinit();

    try std.testing.expect(try checker.excluded(io, "a.log", false));
    try std.testing.expect(try checker.excluded(io, "x.secret", false));
    try std.testing.expect(!try checker.excluded(io, "a.txt", false));
    // a deeper file beats a shallower one, and applies only below itself
    try std.testing.expect(!try checker.excluded(io, "sub/keep.log", false));
    try std.testing.expect(try checker.excluded(io, "sub/other.log", false));
    try std.testing.expect(try checker.excluded(io, "sub/deep/x.tmp", false));
    try std.testing.expect(!try checker.excluded(io, "x.tmp", false));
    // a folder-only rule decides by what the path is, and covers below it
    try std.testing.expect(try checker.excluded(io, "build", true));
    try std.testing.expect(!try checker.excluded(io, "build", false));
    try std.testing.expect(try checker.excluded(io, "build/out.o", false));
    try std.testing.expectEqualStrings("*.tmp", (try checker.match(io, "sub/deep/y.tmp", false)).by.?.glob);
    // each folder read once: four levels of files and one of text
    try std.testing.expectEqual(@as(usize, 4), checker.rules.levels.items.len);
}

test "a checker asks an unreadable folder's rules again, or skips them when told" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.gitignore", .data = "*.log\n" });
    // larger than any ignore file is read: present, and unreadable
    var big = try tmp.dir.createFile(io, ".gitignore", .{});
    try big.setLength(io, (1 << 24) + 1);
    big.close(io);

    var failing: Checker = .init(try .init(gpa, false), tmp.dir, .{});
    defer failing.deinit();
    try std.testing.expect(std.meta.isError(failing.excluded(io, "sub/a.log", false)));
    try std.testing.expect(!failing.read.contains(""));
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "!sub/a.log\n*.txt\n" });
    try std.testing.expect(try failing.excluded(io, "b.txt", false));
    try std.testing.expect(try failing.excluded(io, "sub/a.log", false));

    var big_again = try tmp.dir.createFile(io, ".gitignore", .{});
    try big_again.setLength(io, (1 << 24) + 1);
    big_again.close(io);
    var skipping: Checker = .init(try .init(gpa, false), tmp.dir, .{ .unreadable = .skip });
    defer skipping.deinit();
    try std.testing.expect(try skipping.excluded(io, "sub/a.log", false));
    try std.testing.expect(!try skipping.excluded(io, "b.txt", false));
}

test "a checker marks no folder read when reading it runs out of memory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    var failures: usize = 0;
    for (0..6) |offset| {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var checker: Checker = .init(try .init(fa.allocator(), false), tmp.dir, .{});
        defer checker.deinit();
        fa.fail_index = fa.alloc_index + offset;
        _ = checker.excluded(io, "keep.log", false) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expect(!checker.read.contains(""));
            fa.fail_index = std.math.maxInt(usize);
            try std.testing.expect(try checker.excluded(io, "keep.log", false));
            continue;
        };
    }
    try std.testing.expect(failures >= 2);
}

test "a checker hands back its rules with every level it read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.o\n" });
    var checker: Checker = .init(try .init(gpa, false), tmp.dir, .{});
    try std.testing.expect(try checker.excluded(io, "a.o", false));
    var rules = checker.release();
    defer rules.deinit();
    try std.testing.expect(rules.match("b.o", false).excluded);
}

test "fuzz: any ignore file answers without a crash" {
    try std.testing.fuzz({}, fuzzIgnore, .{});
}

fn fuzzIgnore(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var text_buf: [1024]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const text = text_buf[0..smith.slice(&text_buf)];
    const path = path_buf[0..smith.slice(&path_buf)];
    var rules: Rules = try .init(gpa, false);
    defer rules.deinit();
    rules.addText(text, "", "fuzz", 2) catch return;
    _ = rules.match(path, false);
    _ = rules.matchPath(path, true);
}
