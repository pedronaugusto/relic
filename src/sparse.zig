//! Sparse checkout: which tracked paths belong in the working tree.
//!
//! The patterns in `info/sparse-checkout` are gitignore syntax read the
//! other way round — a path that matches is *included* — with the last
//! matching pattern deciding and nothing included by default. Cone mode is
//! the same file with only directory patterns in it, which is a restriction
//! on what is written rather than a different language.
//!
//! This is about `skip-worktree`, not about the sparse *index*. A sparse
//! index collapses an out-of-cone directory into one entry and is a
//! mandatory index extension; that one is refused by name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ignore = @import("ignore.zig");
const wildmatch = @import("wildmatch.zig");
const fs = @import("fs.zig");

/// Errors from loading sparse patterns.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError;

/// The patterns that decide what is in the working tree.
pub const Patterns = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    items: std.ArrayList(ignore.Pattern),
    case_fold: bool,

    /// Empty patterns, which include nothing.
    pub fn init(gpa: Allocator, case_fold: bool) Allocator.Error!Patterns {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        return .{ .gpa = gpa, .arena = arena, .items = .empty, .case_fold = case_fold };
    }

    /// Release everything.
    pub fn deinit(p: *Patterns) void {
        p.arena.deinit();
        p.gpa.destroy(p.arena);
        p.items.deinit(p.gpa);
        p.* = undefined;
    }

    /// Read `info/sparse-checkout` from the git directory, or `null` when
    /// there is none.
    pub fn load(gpa: Allocator, io: Io, git_dir: Io.Dir, case_fold: bool) Error!?Patterns {
        var patterns = try init(gpa, case_fold);
        errdefer patterns.deinit();
        const bytes = (try fs.readFileAlloc(patterns.arena.allocator(), io, git_dir, "info/sparse-checkout", 1 << 24)) orelse {
            patterns.deinit();
            return null;
        };
        try patterns.addText(bytes);
        return patterns;
    }

    /// Add patterns from text, which must outlive the set.
    pub fn addText(p: *Patterns, text: []const u8) Allocator.Error!void {
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_number += 1;
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const pattern = ignore.parseLine(line, "", "info/sparse-checkout", line_number) orelse continue;
            try p.items.append(p.gpa, pattern);
        }
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
        var included = false;
        var at: usize = 0;
        while (true) {
            const slash = std.mem.indexOfScalarPos(u8, path, at, '/');
            const end = slash orelse path.len;
            const prefix = path[0..end];
            const level_is_dir = slash != null or is_dir;
            if (p.decide(prefix, level_is_dir)) |decision| included = decision;
            if (slash) |s2| at = s2 + 1 else break;
        }
        return included;
    }

    /// The last pattern that matches `path`, as an inclusion, or `null`
    /// when none does.
    fn decide(p: *const Patterns, path: []const u8, is_dir: bool) ?bool {
        var decision: ?bool = null;
        for (p.items.items) |pattern| {
            if (pattern.dir_only and !is_dir) continue;
            const subject = if (pattern.anchored) path else basename(path);
            const matched = wildmatch.match(pattern.glob, subject, .{
                .pathname = pattern.anchored,
                .case_fold = p.case_fold,
            }) catch false;
            if (!matched) continue;
            decision = !pattern.negated;
        }
        return decision;
    }
};

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
    return path;
}

test "the last matching pattern decides, and nothing is in by default" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.init(gpa, false);
    defer patterns.deinit();
    try patterns.addText("/*\n!/secret/\n");

    try std.testing.expect(patterns.includes("README.md", false));
    try std.testing.expect(patterns.includes("src/main.zig", false));
    try std.testing.expect(!patterns.includes("secret", true));
}

test "a cone-shaped file includes a directory and everything under it" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.init(gpa, false);
    defer patterns.deinit();
    try patterns.addText("/*\n!/*/\n/src/\n");

    try std.testing.expect(patterns.includes("top.txt", false));
    try std.testing.expect(patterns.includes("src/main.zig", false));
    try std.testing.expect(patterns.includes("src/deep/inner.zig", false));
    try std.testing.expect(!patterns.includes("docs/page.md", false));
}

test "empty patterns include nothing" {
    const gpa = std.testing.allocator;
    var patterns = try Patterns.init(gpa, false);
    defer patterns.deinit();
    try std.testing.expect(!patterns.includes("anything", false));
}
