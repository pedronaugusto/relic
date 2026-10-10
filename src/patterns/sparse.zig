//! Sparse checkout: which tracked paths belong in the working tree.
//!
//! The patterns in `info/sparse-checkout` are gitignore syntax read the
//! other way round — a path that matches is *included* — with the last
//! matching pattern deciding and nothing included by default. Cone mode is
//! the same file with only directory patterns in it, which is a restriction
//! on what is written rather than a different language.
//!
//! Cone mode is also a faster question. With `core.sparseCheckoutCone` set,
//! a file that has the cone's shape is read as two sets of directories --
//! the ones included with everything under them, and their parents, whose
//! own files are in and whose other subdirectories are out -- and a path is
//! answered by a few set lookups rather than by every pattern in turn. A
//! file that does not have the shape is read the other way, as git does
//! after warning about it. The sets are also what a sparse index is built
//! from: a directory the cone leaves out is what collapses into one entry.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const shakedown_mod = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sets = @import("set.zig");
const ignore = @import("ignore.zig");
const glob_mod = @import("../text.zig").glob;
const fs = @import("../fs/fs.zig");

/// Errors from loading sparse patterns.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError;

/// The patterns that decide what is in the working tree.
pub const Patterns = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    items: std.ArrayList(ignore.Pattern),
    case_fold: bool,
    /// Private compiled non-cone patterns.
    _matcher: ?*anyopaque = null,
    /// The cone the patterns describe, when they were read in cone mode and
    /// have its shape. `null` means every pattern is consulted in turn.
    cone: ?Cone = null,

    /// Empty patterns, which include nothing.
    pub const InitOptions = struct { case_fold: bool = false };

    pub fn init(gpa: Allocator, options: InitOptions) Allocator.Error!Patterns {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        return .{ .gpa = gpa, .arena = arena, .items = .empty, .case_fold = options.case_fold };
    }

    /// Release everything.
    pub fn deinit(p: *Patterns) void {
        if (p.cone) |*c| c.deinit(p.gpa);
        if (p._matcher) |m| matcher(m).deinit();
        p.arena.deinit();
        p.gpa.destroy(p.arena);
        p.items.deinit(p.gpa);
        p.* = undefined;
    }

    /// How `load` reads the file.
    pub const LoadOptions = struct {
        /// Whether the filesystem folds case, from `core.ignoreCase`.
        case_fold: bool = false,
        /// Whether to read the file as a cone, which is what
        /// `core.sparseCheckoutCone` asks for.
        cone: bool = false,
    };

    /// Read `info/sparse-checkout` the way the configuration says to, or
    /// `null` when there is none.
    ///
    /// In cone mode a file without the cone's shape is read as plain
    /// patterns, which is git's own fallback; `cone` on the result says
    /// which happened.
    pub fn load(gpa: Allocator, io: Io, git_dir: Io.Dir, options: LoadOptions) Self.Error!?Patterns {
        var patterns = try init(gpa, .{ .case_fold = options.case_fold });
        errdefer patterns.deinit();
        const bytes = (try fs.readFileAlloc(patterns.arena.allocator(), io, git_dir, "info/sparse-checkout", 1 << 24)) orelse {
            patterns.deinit();
            return null;
        };
        try patterns.addText(bytes);
        if (options.cone) patterns.cone = try Cone.parse(gpa, bytes, .{ .arena = patterns.arena.allocator(), .case_fold = options.case_fold });
        return patterns;
    }

    /// Patterns from text alone, read as a cone when `cone` is set and the
    /// text has the shape. The text is copied.
    pub fn fromText(gpa: Allocator, text: []const u8, options: LoadOptions) Allocator.Error!Patterns {
        var patterns = try init(gpa, .{ .case_fold = options.case_fold });
        errdefer patterns.deinit();
        const owned = try patterns.arena.allocator().dupe(u8, text);
        try patterns.addText(owned);
        if (options.cone) patterns.cone = try Cone.parse(gpa, owned, .{ .arena = patterns.arena.allocator(), .case_fold = options.case_fold });
        return patterns;
    }

    /// Add patterns from text, which must outlive the set.
    pub fn addText(p: *Patterns, text: []const u8) Allocator.Error!void {
        // Build a replacement first, so allocation failure leaves the old
        // decisions intact. Metadata commits only once compilation succeeds.
        var builder: sets.Builder = try .init(p.gpa);
        defer builder.deinit();
        for (p.items.items) |item| _ = try sets.add(&builder, item.glob, item.anchored, item.dir_only, p.case_fold);
        var added: std.ArrayList(ignore.Pattern) = .empty;
        defer added.deinit(p.gpa);
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_number += 1;
            const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            const pattern = ignore.parseLine(line, .{ .source = "info/sparse-checkout", .line = line_number }) orelse continue;
            if (!try sets.add(&builder, pattern.glob, pattern.anchored, pattern.dir_only, p.case_fold)) continue;
            try added.append(p.gpa, pattern);
        }
        const compiled = try sets.Matcher.build(&builder);
        errdefer compiled.deinit();
        try p.items.appendSlice(p.gpa, added.items);
        if (p._matcher) |m| matcher(m).deinit();
        p._matcher = compiled;
    }

    /// Whether `path` belongs in the working tree.
    ///
    /// Nothing is included unless a pattern says so, and the last matching
    /// pattern decides. Each directory on the way down is decided first and
    /// carries its answer to what is inside it, which is how git evaluates
    /// the same file: `/*` includes every top-level entry, and everything
    /// under an included directory comes with it unless a deeper pattern
    /// says otherwise.
    pub fn includes(p: *const Patterns, path: []const u8, is_dir: bool) bool {
        if (p.cone) |*c| return c.match(path, is_dir) != .outside;
        const m = matcher(p._matcher orelse return false);
        m.lock();
        defer m.unlock();
        m.begin(path, is_dir);
        var included = false;
        while (m.walking.?.next()) |step| {
            if (step.last) |i| included = !p.items.items[i.raw()].negated;
        }
        return included;
    }
};

/// What cone mode says of a path.
pub const ConeMatch = enum {
    /// Left out of the working tree.
    outside,
    /// In, as a file at the root or directly in a parent of the cone.
    inside,
    /// In, because a directory above it is in with everything under it.
    recursive,
};

/// The cone a cone-mode file describes: the directories included whole,
/// and the directories above them, whose own files are included and whose
/// other subdirectories are not. Files at the root are always included.
///
/// Directories are named without a leading or trailing slash. Under
/// `core.ignoreCase` they are compared without case, as git compares them.
pub const Cone = struct {
    pub const Error = ErrorNamespace.Error;

    /// Included with everything under them.
    recursive: DirSet = .empty,
    /// Their ancestors: own files in, subdirectories out.
    parents: DirSet = .empty,
    /// `/*` with no `!/*/` after it: everything is in.
    full: bool = false,
    /// Whether names are compared without case.
    fold: bool,

    /// A set of directory names, compared with or without case.
    pub const DirSet = std.HashMapUnmanaged([]const u8, void, DirContext, std.hash_map.default_max_load_percentage);

    /// How a `DirSet` hashes and compares a name.
    pub const DirContext = struct {
        fold: bool,

        /// The name's hash, folded when the set folds case.
        pub fn hash(c: Cone.DirContext, key: []const u8) u64 {
            if (!c.fold) return std.hash.Wyhash.hash(0, key);
            var h: std.hash.Wyhash = .init(0);
            for (key) |byte| h.update(&.{std.ascii.toLower(byte)});
            return h.final();
        }

        /// Whether two names are the same name.
        pub fn eql(c: Cone.DirContext, a: []const u8, b: []const u8) bool {
            return if (c.fold) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
        }
    };

    /// Release the sets. The names belong to whoever made them.
    pub fn deinit(c: *Cone, gpa: Allocator) void {
        c.recursive.deinit(gpa);
        c.parents.deinit(gpa);
        c.* = undefined;
    }

    fn ctx(c: *const Cone) DirContext {
        return .{ .fold = c.fold };
    }

    /// Whether `dir` is included with everything under it.
    pub fn isRecursive(c: *const Cone, dir: []const u8) bool {
        return c.recursive.containsContext(dir, c.ctx());
    }

    /// Whether `dir` is a parent of the cone.
    pub fn isParent(c: *const Cone, dir: []const u8) bool {
        return c.parents.containsContext(dir, c.ctx());
    }

    /// Include `dir` with everything under it, and make each directory above
    /// it a parent, which is what naming a directory to `sparse-checkout set`
    /// means. `dir` is copied into `arena`.
    pub const AddOptions = struct { arena: Allocator };

    pub fn addRecursive(c: *Cone, gpa: Allocator, dir: []const u8, options: AddOptions) Allocator.Error!void {
        const arena = options.arena;
        const owned = try arena.dupe(u8, dir);
        try c.recursive.putContext(gpa, owned, {}, c.ctx());
        var end = owned.len;
        while (std.mem.findScalarLast(u8, owned[0..end], '/')) |slash| {
            end = slash;
            try c.parents.putContext(gpa, owned[0..end], {}, c.ctx());
        }
    }

    /// Read `text` as a cone, or `null` when it does not have the shape.
    ///
    /// The rules are git's: `/*` and `!/*/` set the root, `/A/` includes a
    /// directory whole, and `!/A/*/` after it demotes that directory to a
    /// parent. Anything else -- a glob, `**`, a pattern that is not a
    /// directory, a negation without the inclusion before it, a directory
    /// named twice -- is not a cone. Names are copied into `arena` without
    /// their escapes.
    pub const ParseOptions = struct { arena: Allocator, case_fold: bool = false };

    pub fn parse(gpa: Allocator, text: []const u8, options: ParseOptions) Allocator.Error!?Cone {
        const arena = options.arena;
        const fold = options.case_fold;
        var cone: Cone = .{ .fold = fold };
        errdefer cone.deinit(gpa);
        const c = cone.ctx();

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = trimPattern(raw);
            if (line.len == 0 or line[0] == '#') continue;
            var pattern = line;
            const negative = pattern[0] == '!';
            if (negative) pattern = pattern[1..];
            const must_be_dir = pattern.len > 0 and pattern[pattern.len - 1] == '/';
            if (must_be_dir) pattern = pattern[0 .. pattern.len - 1];

            if (negative and must_be_dir and std.mem.eql(u8, pattern, "/*")) {
                cone.full = false;
                continue;
            }
            if (!negative and !must_be_dir and std.mem.eql(u8, pattern, "/*")) {
                cone.full = true;
                continue;
            }
            if (pattern.len < 2 or pattern[0] != '/' or std.mem.find(u8, pattern, "**") != null) break;
            if (!must_be_dir and !std.mem.eql(u8, pattern, "/*")) break;
            if (!onlyEscapedGlobs(pattern)) break;

            if (pattern.len > 2 and std.mem.endsWith(u8, pattern, "/*")) {
                if (!negative) break;
                const name = try unescape(arena, pattern[1 .. pattern.len - 2]);
                if (!cone.recursive.containsContext(name, c)) break;
                _ = cone.recursive.removeContext(name, c);
                try cone.parents.putContext(gpa, name, {}, c);
                continue;
            }
            if (negative) break;
            const name = try unescape(arena, pattern[1..]);
            try cone.recursive.putContext(gpa, name, {}, c);
            if (cone.parents.containsContext(name, c)) break;
        } else return cone;

        cone.deinit(gpa);
        return null;
    }

    /// Where `path` stands. A directory is answered for the files directly
    /// inside it, which is how git asks: a parent of the cone is `inside`
    /// even though most of what is under it is not.
    pub fn match(c: *const Cone, path: []const u8, is_dir: bool) ConeMatch {
        if (c.full) return .inside;
        // A file named like an included directory, which only a pattern
        // written by hand can produce.
        if (!is_dir and c.isRecursive(path)) return .recursive;

        const parent: []const u8 = if (is_dir)
            path
        else if (std.mem.findScalarLast(u8, path, '/')) |slash|
            path[0..slash]
        else
            return .inside;
        if (parent.len == 0) return .inside;
        if (c.isParent(parent)) return .inside;

        // A directory is its own first ancestor here, a file is not.
        var end = parent.len;
        while (true) {
            if (c.isRecursive(parent[0..end])) return .recursive;
            end = std.mem.findScalarLast(u8, parent[0..end], '/') orelse break;
        }
        return .outside;
    }
};

/// A cone name with each escaping backslash taken out, in `arena`.
fn unescape(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, text, '\\') == null) return arena.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            if (i == text.len) break;
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

/// A pattern line with git's trimming: trailing spaces go, unless the
/// last of them is escaped with a backslash.
pub fn trimPattern(line: []const u8) []const u8 {
    var last_space: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ' ' => {
                if (last_space == null) last_space = i;
            },
            '\\' => {
                i += 1;
                if (i == line.len) return line;
                last_space = null;
            },
            else => last_space = null,
        }
    }
    return line[0 .. last_space orelse line.len];
}

/// git's test that a cone pattern names a directory rather than a glob:
/// every special character is escaped, except a `*` that ends the pattern
/// after a slash.
fn onlyEscapedGlobs(pattern: []const u8) bool {
    var i: usize = 1;
    while (i < pattern.len) : (i += 1) {
        const cur = pattern[i];
        const prev = pattern[i - 1];
        const next: u8 = if (i + 1 < pattern.len) pattern[i + 1] else 0;
        if (!glob_mod.isSpecial(cur)) continue;
        if (prev == '\\') continue;
        if (cur == '\\' and glob_mod.isSpecial(next)) continue;
        if (prev == '/' and cur == '*' and next == 0) continue;
        return false;
    }
    return true;
}

fn matcher(ptr: *anyopaque) *sets.Matcher {
    return @ptrCast(@alignCast(ptr)); // safe: the pointer stored in a pattern set is always a sets.Matcher
}

test "the last matching pattern decides, and nothing is in by default" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.init(gpa, .{ .case_fold = false });
    defer patterns.deinit();
    try patterns.addText("/*\n!/secret/\n");

    try std.testing.expect(patterns.includes("README.md", false));
    try std.testing.expect(patterns.includes("src/main.zig", false));
    try std.testing.expect(!patterns.includes("secret", true));
}

test "a cone-shaped file includes a directory and everything under it" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.init(gpa, .{ .case_fold = false });
    defer patterns.deinit();
    try patterns.addText("/*\n!/*/\n/src/\n");

    try std.testing.expect(patterns.includes("top.txt", false));
    try std.testing.expect(patterns.includes("src/main.zig", false));
    try std.testing.expect(patterns.includes("src/deep/inner.zig", false));
    try std.testing.expect(!patterns.includes("docs/page.md", false));
}

test "empty patterns include nothing" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.init(gpa, .{ .case_fold = false });
    defer patterns.deinit();
    try std.testing.expect(!patterns.includes("anything", false));
}

test "a cone file reads as its directories, and a path is answered by lookups" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cone = (try Cone.parse(gpa, "/*\n!/*/\n/A/\n!/A/*/\n/A/B/\n/g\\[1]/\n", .{ .arena = arena.allocator(), .case_fold = false })).?;
    defer cone.deinit(gpa);

    try std.testing.expect(cone.isParent("A"));
    try std.testing.expect(cone.isRecursive("A/B"));
    try std.testing.expect(cone.isRecursive("g[1]"));
    try std.testing.expectEqual(ConeMatch.inside, cone.match("top.txt", false));
    try std.testing.expectEqual(ConeMatch.inside, cone.match("A/a.txt", false));
    try std.testing.expectEqual(ConeMatch.recursive, cone.match("A/B/C/c.txt", false));
    try std.testing.expectEqual(ConeMatch.outside, cone.match("A/X/x.txt", false));
    try std.testing.expectEqual(ConeMatch.outside, cone.match("D/d.txt", false));
    // A directory is answered for the files directly in it.
    try std.testing.expectEqual(ConeMatch.inside, cone.match("A", true));
    try std.testing.expectEqual(ConeMatch.recursive, cone.match("A/B", true));
    try std.testing.expectEqual(ConeMatch.outside, cone.match("D", true));
}

test "a file without the cone's shape is not a cone" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{
        "/*\n!/*/\n*.txt\n",
        "/*\n!/*/\n/A/**/\n",
        "/*\n!/*/\n!/A/*/\n",
        "/*\n!/*/\n/A\n",
        "/*\n!/*/\n/A/\n!/A/*/\n/A/\n",
    }) |text| {
        try std.testing.expect(try Cone.parse(gpa, text, .{ .arena = arena.allocator(), .case_fold = false }) == null);
    }
    var empty = (try Cone.parse(gpa, "", .{ .arena = arena.allocator(), .case_fold = false })).?;
    defer empty.deinit(gpa);
    // Files at the root are in whatever the cone says.
    try std.testing.expectEqual(ConeMatch.inside, empty.match("README", false));
    try std.testing.expectEqual(ConeMatch.outside, empty.match("src/main.zig", false));
}

test "a cone compares without case when the filesystem folds it" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.fromText(gpa, "/*\n!/*/\n/Docs/\n", .{ .cone = true, .case_fold = true });
    defer patterns.deinit();
    try std.testing.expect(patterns.cone != null);
    try std.testing.expect(patterns.includes("docs/page.md", false));
    try std.testing.expect(!patterns.includes("src/main.zig", false));
}

test "git's trimming keeps an escaped trailing space" {
    try std.testing.expectEqualStrings("a", trimPattern("a  "));
    try std.testing.expectEqualStrings("a\\ ", trimPattern("a\\ "));
    try std.testing.expectEqualStrings("a\\ ", trimPattern("a\\  "));
    try std.testing.expectEqualStrings("", trimPattern("   "));
}

test "fuzz: any pattern file is a cone or not, and any path is answered" {
    try std.testing.fuzz({}, fuzzCone, .{});
}

fn fuzzCone(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var text_buf: [512]u8 = undefined;
    const text = text_buf[0..smith.slice(&text_buf)];
    var path_buf: [64]u8 = undefined;
    const path = path_buf[0..smith.slice(&path_buf)];
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_]bool{ false, true }) |fold| {
        var cone = (try Cone.parse(gpa, text, .{ .arena = arena.allocator(), .case_fold = fold })) orelse continue;
        defer cone.deinit(gpa);
        _ = cone.match(path, false);
        _ = cone.match(path, true);
    }
    var patterns = try Patterns.fromText(gpa, text, .{ .cone = true });
    defer patterns.deinit();
    _ = patterns.includes(path, false);
}

test "sparse set rebuilding survives every allocation failure" {
    var no_resize = shakedown_mod.alloc.NoResize.init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(gpa: Allocator) !void {
            var patterns = try Patterns.init(gpa, .{ .case_fold = true });
            defer patterns.deinit();
            try patterns.addText("/src/\n");
            try patterns.addText("!/src/generated/\n/src/generated/keep.zig\n");
            try std.testing.expect(patterns.includes("SRC/main.zig", false));
            try std.testing.expect(!patterns.includes("src/generated/drop.zig", false));
            try std.testing.expect(patterns.includes("src/generated/keep.zig", false));
            try std.testing.expect(!patterns.includes("docs/a", false));
        }
    }.exercise, .{});
}
