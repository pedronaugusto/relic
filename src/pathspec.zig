//! Pathspecs, as git's commands take them: which paths a `grep`, a `clean`
//! or an `add` is about.
//!
//! A pathspec is a path prefix (`src` takes `src/main.zig`) or a glob
//! matched against the whole path with git's wildmatch, a `*` crossing `/`
//! unless `:(glob)` asks otherwise. Magic is git's, long and short:
//! `:(top)`/`:/`, `:(exclude)`/`:!`/`:^`, `:(icase)`, `:(literal)`,
//! `:(glob)`. Paths are from the top of the working tree: there is no
//! current directory to be relative to. `:(attr:...)` is refused by name.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const glob_mod = @import("text/glob.zig");

/// Errors from reading a pathspec.
pub const Error = error{
    /// Magic git does not know, or a long form without its `)`.
    InvalidPathspecMagic,
    /// `:(attr:...)`, which needs attributes this does not consult.
    UnsupportedPathspecMagic,
    /// `literal` and `glob` together, which git refuses.
    IncompatiblePathspecMagic,
    /// A `..` that climbs above the top of the working tree.
    PathspecOutsideRepository,
} || Allocator.Error;

const Item = struct {
    match: []const u8,
    nowildcard_len: usize,
    exclude: bool,
    icase: bool,
    glob: bool,
    literal: bool,
    onestar: bool,
    /// What follows the literal prefix, compiled, when it holds a wildcard
    /// a plain comparison cannot answer.
    matcher: ?glob_mod.Glob,
};

/// A parsed pathspec.
pub const Pathspec = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Item,
    has_exclude: bool,

    pub fn deinit(p: *Pathspec) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// Whether `path` is one the pathspec names, a path under a named
    /// directory included. An empty pathspec names every path.
    pub fn matches(p: *const Pathspec, path: []const u8) bool {
        return p.matchesAs(path, false);
    }

    /// `matches` for a directory, which `dir/` also names.
    pub fn matchesDir(p: *const Pathspec, path: []const u8) bool {
        return p.matchesAs(path, true);
    }

    fn matchesAs(p: *const Pathspec, path: []const u8, is_dir: bool) bool {
        if (p.items.len == 0) return true;
        var positive = false;
        for (p.items) |item| {
            if (item.exclude) continue;
            if (matchItem(item, path, is_dir)) {
                positive = true;
                break;
            }
        }
        if (!positive or !p.has_exclude) return positive;
        for (p.items) |item| {
            if (!item.exclude) continue;
            if (matchItem(item, path, is_dir)) return false;
        }
        return true;
    }

    /// How `path` is named, the strongest of the items that name it, or
    /// `none` when an exclusion takes it back: git's
    /// `match_pathspec_with_flags`. An empty pathspec names every path
    /// `recursively`.
    pub fn how(p: *const Pathspec, path: []const u8, flags: Flags) How {
        if (p.items.len == 0) return .recursively;
        var best: How = .none;
        for (p.items) |item| {
            if (item.exclude) continue;
            const h = howItem(item, path, flags, false);
            if (@backingInt(h) > @backingInt(best)) best = h;
        }
        if (best == .none or !p.has_exclude) return best;
        for (p.items) |item| {
            if (!item.exclude) continue;
            if (howItem(item, path, flags, true) != .none) return .none;
        }
        return best;
    }

    /// Whether no item's literal part agrees with `path` as far as both
    /// go: a walk passes such a path by without looking at it. git's
    /// `simplify_away`.
    pub fn simplifyAway(p: *const Pathspec, path: []const u8) bool {
        if (p.items.len == 0) return false;
        for (p.items) |item| {
            const n = @min(item.nowildcard_len, path.len);
            if (eqlIcase(item.match[0..n], path[0..n], item.icase)) return false;
        }
        return true;
    }

    /// Whether a path under `dir` could be named: a directory a walk must
    /// enter.
    pub fn couldMatchUnder(p: *const Pathspec, dir: []const u8) bool {
        if (p.items.len == 0) return true;
        for (p.items) |item| {
            if (item.exclude) continue;
            const m = item.match;
            if (m.len == 0) return true;
            // the directory is under the item's literal part, or the item
            // reaches into the directory
            const lit = m[0..item.nowildcard_len];
            if (std.mem.startsWith(u8, dir, lit) and (lit.len == 0 or lit[lit.len - 1] == '/' or dir.len == lit.len or dir[lit.len] == '/')) return true;
            if (lit.len > dir.len and std.mem.startsWith(u8, lit, dir) and lit[dir.len] == '/') return true;
            if (item.nowildcard_len < m.len and std.mem.startsWith(u8, dir, lit[0..@min(lit.len, dir.len)])) return true;
            if (item.nowildcard_len < m.len and std.mem.startsWith(u8, lit, dir)) return true;
        }
        return false;
    }
};

/// How a path was named, git's `MATCHED_*` in its order: a caller that
/// keeps the strongest compares them.
pub const How = enum(u3) {
    none = 0,
    /// A prefix of the path was named: `src` for `src/main.zig`.
    recursively = 1,
    /// The path is a directory the pathspec reaches below: `src/` for
    /// `src/main.zig`. Asked only with `Flags.leading`.
    leading = 2,
    /// A glob matched.
    fnmatch = 3,
    /// The path itself was named.
    exactly = 4,
};

/// What `how` is asked about.
pub const Flags = struct {
    /// The path is a directory, which `dir/` names too.
    directory: bool = false,
    /// Report a directory a pathspec reaches below as `leading`, which is
    /// how a walk decides to enter it.
    leading: bool = false,
};

fn howItem(item: Item, name: []const u8, flags: Flags, exclude: bool) How {
    const m = item.match;
    if (m.len == 0) return .recursively;
    if (m.len <= name.len and eqlIcase(m, name[0..m.len], item.icase)) {
        if (m.len == name.len) return .exactly;
        if (m[m.len - 1] == '/' or name[m.len] == '/') return .recursively;
    } else if (flags.directory and m[m.len - 1] == '/' and name.len == m.len - 1 and eqlIcase(name, m[0..name.len], item.icase)) {
        return .exactly;
    }
    if (item.nowildcard_len < m.len and fnmatchItem(item, name)) return .fnmatch;
    if (flags.leading and !exclude and name.len > 0) {
        const offset: usize = if (name[name.len - 1] == '/') 1 else 0;
        if (name.len < m.len and m[name.len - offset] == '/' and eqlIcase(m[0..name.len], name, item.icase)) return .leading;
        // the name must agree with everything before the first wildcard,
        // which a name shorter than that cannot
        const nw = item.nowildcard_len;
        if (nw < m.len and (name.len < nw or !eqlIcase(m[0..nw], name[0..nw], item.icase))) return .none;
        if (item.nowildcard_len == m.len) return .none;
        return .leading;
    }
    return .none;
}

fn fnmatchItem(item: Item, name: []const u8) bool {
    const m = item.match;
    const prefix = item.nowildcard_len;
    if (name.len < prefix or !eqlIcase(m[0..prefix], name[0..prefix], item.icase)) return false;
    const pat = m[prefix..];
    const str = name[prefix..];
    if (item.onestar) {
        const tail = pat[1..];
        return str.len >= tail.len and eqlIcase(tail, str[str.len - tail.len ..], item.icase);
    }
    return item.matcher.?.matches(str);
}

fn eqlIcase(a: []const u8, b: []const u8, icase: bool) bool {
    if (icase) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

fn matchItem(item: Item, name: []const u8, is_dir: bool) bool {
    const m = item.match;
    if (m.len == 0) return true;
    if (m.len <= name.len and eqlIcase(m, name[0..m.len], item.icase)) {
        if (m.len == name.len) return true;
        if (m[m.len - 1] == '/' or name[m.len] == '/') return true;
    } else if (is_dir and m[m.len - 1] == '/' and name.len == m.len - 1 and eqlIcase(name, m[0..name.len], item.icase)) {
        return true;
    }
    return item.nowildcard_len < m.len and fnmatchItem(item, name);
}

/// The path with `.` and empty components gone and `..` taken back, a
/// trailing `/` kept: git's `normalize_path_copy`, so `.` names the whole
/// tree and `./src/` names `src/`.
fn normalize(a: Allocator, path: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (out.items.len == 0) return error.PathspecOutsideRepository;
            const cut = std.mem.findScalarLast(u8, out.items[0 .. out.items.len - 1], '/');
            out.shrinkRetainingCapacity(if (cut) |c| c + 1 else 0);
            continue;
        }
        try out.appendSlice(a, part);
        try out.append(a, '/');
    }
    // the slash after the last component stays only if the path had one
    const had_slash = path.len > 0 and path[path.len - 1] == '/' or
        std.mem.endsWith(u8, path, "/.") or std.mem.endsWith(u8, path, "/..");
    if (out.items.len > 0 and !had_slash) out.shrinkRetainingCapacity(out.items.len - 1);
    return out.toOwnedSlice(a);
}

/// Read `specs`, each as git reads a pathspec argument at the top of the
/// working tree.
pub fn parse(gpa: Allocator, specs: []const []const u8) Self.Error!Pathspec {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(Item) = .empty;
    var has_exclude = false;
    var all_exclude = specs.len > 0;
    for (specs) |spec| {
        var exclude = false;
        var icase = false;
        var glob = false;
        var literal = false;
        var rest = spec;
        if (rest.len > 0 and rest[0] == ':') {
            if (rest.len > 1 and rest[1] == '(') {
                const close = std.mem.findScalar(u8, rest, ')') orelse return error.InvalidPathspecMagic;
                var words = std.mem.splitScalar(u8, rest[2..close], ',');
                while (words.next()) |w| {
                    if (w.len == 0) continue;
                    if (std.mem.eql(u8, w, "top")) {} else if (std.mem.eql(u8, w, "exclude")) {
                        exclude = true;
                    } else if (std.mem.eql(u8, w, "icase")) {
                        icase = true;
                    } else if (std.mem.eql(u8, w, "glob")) {
                        glob = true;
                    } else if (std.mem.eql(u8, w, "literal")) {
                        literal = true;
                    } else if (std.mem.startsWith(u8, w, "attr:")) {
                        return error.UnsupportedPathspecMagic;
                    } else if (std.mem.startsWith(u8, w, "prefix:")) {} else return error.InvalidPathspecMagic;
                }
                rest = rest[close + 1 ..];
            } else {
                var i: usize = 1;
                while (i < rest.len and rest[i] != ':') : (i += 1) {
                    switch (rest[i]) {
                        '/' => {},
                        '!', '^' => exclude = true,
                        else => break,
                    }
                }
                if (i < rest.len and rest[i] == ':') i += 1;
                rest = rest[i..];
            }
        }
        if (literal and glob) return error.IncompatiblePathspecMagic;
        if (exclude) has_exclude = true else all_exclude = false;
        const match = try normalize(a, rest);
        const nowildcard_len = if (literal) match.len else glob_mod.literalPrefix(match);
        var onestar = false;
        if (!glob and nowildcard_len < match.len and match[nowildcard_len] == '*') {
            const tail = match[nowildcard_len + 1 ..];
            onestar = glob_mod.literalPrefix(tail) == tail.len;
        }
        // git's `git_fnmatch` matches what follows the literal prefix as a
        // pattern of its own, so a `**` right after a prefix that ends
        // inside a component starts that pattern and spans components.
        const matcher: ?glob_mod.Glob = if (nowildcard_len < match.len and !onestar)
            try .compile(a, match[nowildcard_len..], .{ .pathname = glob, .case_fold = icase })
        else
            null;
        try items.append(a, .{ .match = match, .nowildcard_len = nowildcard_len, .exclude = exclude, .icase = icase, .glob = glob, .literal = literal, .onestar = onestar, .matcher = matcher });
    }
    // only exclusions: everything else is named, as git adds `:/`
    if (all_exclude) try items.append(a, .{ .match = "", .nowildcard_len = 0, .exclude = false, .icase = false, .glob = false, .literal = false, .onestar = false, .matcher = null });
    return .{ .arena = arena, .items = items.items, .has_exclude = has_exclude };
}

test "pathspecs name prefixes, globs and exclusions as git's do" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, &.{ "src", "*.md", ":!src/gen", ":(icase)DOCS/" });
    defer p.deinit();
    try std.testing.expect(p.matches("src/main.zig"));
    try std.testing.expect(p.matches("src"));
    try std.testing.expect(!p.matches("srcs/x"));
    try std.testing.expect(p.matches("a/b/README.md"));
    try std.testing.expect(!p.matches("src/gen/out.zig"));
    try std.testing.expect(p.matches("docs/x"));
    var only = try parse(gpa, &.{":(exclude)*.o"});
    defer only.deinit();
    try std.testing.expect(only.matches("a.c"));
    try std.testing.expect(!only.matches("a.o"));
    var g = try parse(gpa, &.{":(glob)*.c"});
    defer g.deinit();
    try std.testing.expect(!g.matches("dir/a.c"));
    try std.testing.expect(g.matches("a.c"));
}

test "fuzz: any pathspec parses or is refused by name, and any path is asked of it" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var spec_buf: [128]u8 = undefined;
            var path_buf: [128]u8 = undefined;
            const spec_text = spec_buf[0..smith.slice(&spec_buf)];
            const path = path_buf[0..smith.slice(&path_buf)];
            var p = parse(std.testing.allocator, &.{spec_text}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            defer p.deinit();
            _ = p.matches(path);
            _ = p.matchesDir(path);
            _ = p.couldMatchUnder(path);
            _ = p.simplifyAway(path);
            _ = p.how(path, .{ .leading = true });
            _ = p.how(path, .{ .directory = true });
        }
    }.one, .{});
}
