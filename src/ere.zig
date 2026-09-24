//! POSIX extended regular expressions, as far as asking whether one matches
//! somewhere in a text: what git's `:/<text>` and `^{/<text>}` ask of a
//! commit message, which git compiles with `regcomp(REG_EXTENDED)`.
//!
//! Literals, `.`, bracket expressions with ranges, negation and the
//! `[:class:]` names, `^` and `$` at the ends of the text (no `REG_NEWLINE`:
//! `.` matches a newline too), groups, `|`, and `*`, `+`, `?`, `{m}`,
//! `{m,}`, `{m,n}`. A backslash makes the next character literal. A search
//! carries the set of places each part can leave off at, so no pattern can
//! make it run away; one past a budget of work is still refused, as
//! `error.PatternTooComplex`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from compiling or searching.
pub const Error = error{
    /// A pattern POSIX does not allow: an unclosed group or bracket, a
    /// quantifier with nothing before it, a bad interval.
    InvalidPattern,
    /// A search that took more work than the budget allows.
    PatternTooComplex,
} || Allocator.Error;

const Node = union(enum) {
    /// Any character.
    any,
    literal: u8,
    /// A bracket expression: which of the 256 bytes it takes.
    set: *const [256]bool,
    start,
    end,
    group: *const Alt,
    repeat: struct { node: *const Node, min: u32, max: ?u32 },
};

/// Alternatives, each a sequence.
const Alt = struct { branches: []const []const Node };

/// A compiled pattern.
pub const Pattern = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Alt,

    /// Compile `text`.
    pub fn compile(gpa: Allocator, text: []const u8) Error!Pattern {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var p: Parser = .{ .a = arena.allocator(), .text = text };
        const root = try p.alt();
        if (p.at != text.len) return error.InvalidPattern;
        return .{ .arena = arena, .root = root };
    }

    /// Release it.
    pub fn deinit(p: *Pattern) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// Whether the pattern matches somewhere in `text`. Every start is
    /// tried at once: the places each node can leave off at are carried as
    /// a set, so a pattern costs its length times the text's, not the
    /// number of ways it can match.
    pub fn search(p: *const Pattern, gpa: Allocator, text: []const u8) Error!bool {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var m: Matcher = .{ .a = arena.allocator(), .text = text, .budget = 1 << 24 };
        var from = try m.empty();
        from.setRangeValue(.{ .start = 0, .end = text.len + 1 }, true);
        const ends = try m.alt(p.root, from);
        return ends.count() != 0;
    }
};

const Parser = struct {
    a: Allocator,
    text: []const u8,
    at: usize = 0,

    fn alt(p: *Parser) Error!*const Alt {
        var branches: std.ArrayList([]const Node) = .empty;
        while (true) {
            try branches.append(p.a, try p.sequence());
            if (p.at < p.text.len and p.text[p.at] == '|') {
                p.at += 1;
                continue;
            }
            break;
        }
        const out = try p.a.create(Alt);
        out.* = .{ .branches = branches.items };
        return out;
    }

    fn sequence(p: *Parser) Error![]const Node {
        var nodes: std.ArrayList(Node) = .empty;
        while (p.at < p.text.len) {
            const c = p.text[p.at];
            if (c == '|' or c == ')') break;
            var node: Node = switch (c) {
                '.' => blk: {
                    p.at += 1;
                    break :blk .any;
                },
                '^' => blk: {
                    p.at += 1;
                    break :blk .start;
                },
                '$' => blk: {
                    p.at += 1;
                    break :blk .end;
                },
                '(' => blk: {
                    p.at += 1;
                    const inner = try p.alt();
                    if (p.at >= p.text.len or p.text[p.at] != ')') return error.InvalidPattern;
                    p.at += 1;
                    break :blk .{ .group = inner };
                },
                '[' => .{ .set = try p.bracket() },
                '\\' => blk: {
                    if (p.at + 1 >= p.text.len) return error.InvalidPattern;
                    p.at += 2;
                    break :blk .{ .literal = p.text[p.at - 1] };
                },
                '*', '+', '?' => return error.InvalidPattern,
                '{' => blk: {
                    // A brace that does not start an interval is itself.
                    if (nodes.items.len == 0) {
                        p.at += 1;
                        break :blk .{ .literal = '{' };
                    }
                    return error.InvalidPattern;
                },
                else => blk: {
                    p.at += 1;
                    break :blk .{ .literal = c };
                },
            };
            // Quantifiers after it.
            while (p.at < p.text.len) {
                const q = p.text[p.at];
                var min: u32 = undefined;
                var max: ?u32 = undefined;
                switch (q) {
                    '*' => {
                        min = 0;
                        max = null;
                        p.at += 1;
                    },
                    '+' => {
                        min = 1;
                        max = null;
                        p.at += 1;
                    },
                    '?' => {
                        min = 0;
                        max = 1;
                        p.at += 1;
                    },
                    '{' => {
                        const close = std.mem.indexOfScalarPos(u8, p.text, p.at, '}') orelse return error.InvalidPattern;
                        const inside = p.text[p.at + 1 .. close];
                        if (std.mem.indexOfScalar(u8, inside, ',')) |comma| {
                            min = std.fmt.parseUnsigned(u32, inside[0..comma], 10) catch return error.InvalidPattern;
                            max = if (comma + 1 == inside.len) null else std.fmt.parseUnsigned(u32, inside[comma + 1 ..], 10) catch return error.InvalidPattern;
                        } else {
                            min = std.fmt.parseUnsigned(u32, inside, 10) catch return error.InvalidPattern;
                            max = min;
                        }
                        if (max) |m| if (m < min) return error.InvalidPattern;
                        if (min > 255 or (max orelse 0) > 255) return error.InvalidPattern;
                        p.at = close + 1;
                    },
                    else => break,
                }
                if (node == .start or node == .end) return error.InvalidPattern;
                const inner = try p.a.create(Node);
                inner.* = node;
                node = .{ .repeat = .{ .node = inner, .min = min, .max = max } };
            }
            try nodes.append(p.a, node);
        }
        return nodes.items;
    }

    fn bracket(p: *Parser) Error!*const [256]bool {
        const set = try p.a.create([256]bool);
        set.* = @splat(false);
        p.at += 1;
        var negate = false;
        if (p.at < p.text.len and p.text[p.at] == '^') {
            negate = true;
            p.at += 1;
        }
        var first = true;
        while (true) {
            if (p.at >= p.text.len) return error.InvalidPattern;
            const c = p.text[p.at];
            if (c == ']' and !first) {
                p.at += 1;
                break;
            }
            first = false;
            if (c == '[' and p.at + 1 < p.text.len and p.text[p.at + 1] == ':') {
                const close = std.mem.indexOfPos(u8, p.text, p.at + 2, ":]") orelse return error.InvalidPattern;
                const name = p.text[p.at + 2 .. close];
                for (0..256) |b| {
                    if (inClass(name, @intCast(b)) orelse return error.InvalidPattern) set[b] = true;
                }
                p.at = close + 2;
                continue;
            }
            p.at += 1;
            if (p.at + 1 < p.text.len and p.text[p.at] == '-' and p.text[p.at + 1] != ']') {
                const hi = p.text[p.at + 1];
                if (hi < c) return error.InvalidPattern;
                for (c..@as(usize, hi) + 1) |b| set[b] = true;
                p.at += 2;
            } else set[c] = true;
        }
        if (negate) {
            for (set) |*b| b.* = !b.*;
        }
        return set;
    }

    fn inClass(name: []const u8, c: u8) ?bool {
        const map = .{
            .{ "alpha", std.ascii.isAlphabetic },   .{ "digit", std.ascii.isDigit },
            .{ "alnum", std.ascii.isAlphanumeric }, .{ "upper", std.ascii.isUpper },
            .{ "lower", std.ascii.isLower },        .{ "space", std.ascii.isWhitespace },
            .{ "xdigit", std.ascii.isHex },         .{ "print", std.ascii.isPrint },
            .{ "cntrl", std.ascii.isControl },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1](c);
        }
        if (std.mem.eql(u8, name, "punct")) return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
        if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
        if (std.mem.eql(u8, name, "graph")) return std.ascii.isPrint(c) and c != ' ';
        return null;
    }
};

const Set = std.DynamicBitSetUnmanaged;

const Matcher = struct {
    a: Allocator,
    text: []const u8,
    budget: u32,

    fn empty(m: *Matcher) Error!Set {
        return Set.initEmpty(m.a, m.text.len + 1);
    }

    fn spend(m: *Matcher) Error!void {
        const cost: u32 = @intCast(@min(m.text.len + 1, std.math.maxInt(u32)));
        if (m.budget < cost) return error.PatternTooComplex;
        m.budget -= cost;
    }

    fn alt(m: *Matcher, a: *const Alt, from: Set) Error!Set {
        var out = try m.empty();
        for (a.branches) |branch| out.setUnion(try m.seq(branch, from));
        return out;
    }

    fn seq(m: *Matcher, nodes: []const Node, from: Set) Error!Set {
        var cur = from;
        for (nodes) |*node| {
            if (cur.count() == 0) break;
            cur = try m.one(node, cur);
        }
        return cur;
    }

    /// Where `node` can leave off, started anywhere in `from`.
    fn one(m: *Matcher, node: *const Node, from: Set) Error!Set {
        try m.spend();
        var out = try m.empty();
        const n = m.text.len;
        switch (node.*) {
            .any, .literal, .set => {
                var it = from.iterator(.{});
                while (it.next()) |at| {
                    if (at >= n) continue;
                    const c = m.text[at];
                    const ok = switch (node.*) {
                        .any => true,
                        .literal => |l| l == c,
                        .set => |s| s[c],
                        else => unreachable,
                    };
                    if (ok) out.set(at + 1);
                }
            },
            .start => if (from.isSet(0)) out.set(0),
            .end => if (from.isSet(n)) out.set(n),
            .group => |g| out = try m.alt(g, from),
            .repeat => |r| {
                var frontier = try from.clone(m.a);
                var seen = try m.empty();
                var count: u32 = 0;
                while (true) {
                    if (count >= r.min) {
                        out.setUnion(frontier);
                        // Past the minimum, a place already reached adds
                        // nothing new.
                        frontier.setIntersection(blk: {
                            var fresh = try seen.clone(m.a);
                            fresh.toggleAll();
                            break :blk fresh;
                        });
                        seen.setUnion(frontier);
                    }
                    if (r.max) |mx| if (count >= mx) break;
                    if (frontier.count() == 0) break;
                    frontier = try m.one(r.node, frontier);
                    count += 1;
                }
            },
        }
        return out;
    }
};

const testing = std.testing;

test "a pattern matches where POSIX extended expressions match" {
    const Case = struct { pattern: []const u8, text: []const u8, match: bool };
    for ([_]Case{
        .{ .pattern = "fix", .text = "a fix for it", .match = true },
        .{ .pattern = "^fix", .text = "a fix", .match = false },
        .{ .pattern = "^a f", .text = "a fix", .match = true },
        .{ .pattern = "it$", .text = "for it", .match = true },
        .{ .pattern = "f.x", .text = "fox", .match = true },
        .{ .pattern = "colou?r", .text = "color", .match = true },
        .{ .pattern = "ab+c", .text = "ac", .match = false },
        .{ .pattern = "ab*c", .text = "ac", .match = true },
        .{ .pattern = "(ab)+c", .text = "xababc", .match = true },
        .{ .pattern = "a{2,3}b", .text = "aab", .match = true },
        .{ .pattern = "^a{3}$", .text = "aa", .match = false },
        .{ .pattern = "(cat|dog)s", .text = "hot dogs", .match = true },
        .{ .pattern = "[0-9]+\\.[0-9]", .text = "v1.2", .match = true },
        .{ .pattern = "[^a-z]", .text = "abc", .match = false },
        .{ .pattern = "[[:digit:]]", .text = "r2", .match = true },
        .{ .pattern = "(a*)*b", .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac", .match = false },
        .{ .pattern = "one.two", .text = "one\ntwo", .match = true },
    }) |case| {
        var p = try Pattern.compile(testing.allocator, case.pattern);
        defer p.deinit();
        testing.expectEqual(case.match, try p.search(testing.allocator, case.text)) catch |err| {
            std.debug.print("{s} on {s}\n", .{ case.pattern, case.text });
            return err;
        };
    }
    for ([_][]const u8{ "(ab", "a)", "*a", "[abc", "a{3,2}", "\\" }) |bad| {
        try testing.expectError(error.InvalidPattern, Pattern.compile(testing.allocator, bad));
    }
}

test "fuzz: any pattern compiles or is refused, and any search ends" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const all = buf[0..smith.slice(&buf)];
            const cut = all.len / 2;
            var p = Pattern.compile(testing.allocator, all[0..cut]) catch |err| switch (err) {
                error.InvalidPattern => return,
                else => return err,
            };
            defer p.deinit();
            _ = p.search(testing.allocator, all[cut..]) catch |err| switch (err) {
                error.PatternTooComplex => return,
                else => return err,
            };
        }
    }.one, .{ .corpus = &.{ "(ab)+c|d*xababc", "[[:alpha:]]{2,}x9" } });
}
