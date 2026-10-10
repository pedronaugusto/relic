//! Git basic and extended regular expressions. Boolean revision-message
//! searches and leftmost-longest grep searches share the parser and matcher.
//! Each adapter selects its newline policy; GNU character classes, word
//! boundaries and backreferences have the same meaning in both. Backreference
//! searches have bounded work and recursion and fail explicitly at the limit.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const shakedown_mod = @import("shakedown");
const Allocator = std.mem.Allocator;

/// Errors from compiling or searching.
pub const Error = error{
    /// A pattern POSIX does not allow: an unclosed group or bracket, a
    /// quantifier with nothing before it, a bad interval.
    InvalidPattern,
    /// A search that took more work than the budget allows.
    PatternTooComplex,
} || Allocator.Error;

/// Boolean commit-message adapter over the same git ERE core as `Regex`.
/// Git compiles revision message searches without REG_NEWLINE.
pub const Pattern = struct {
    pub const Error = ErrorNamespace.Error;

    regex: Regex,

    pub fn compile(gpa: Allocator, text: []const u8) ErrorNamespace.Error!Pattern {
        return .{ .regex = try Regex.compile(gpa, text, .{ .newline = false }) };
    }

    pub fn deinit(p: *Pattern) void {
        p.regex.deinit();
        p.* = undefined;
    }

    pub fn search(p: *const Pattern, gpa: Allocator, text: []const u8) ErrorNamespace.Error!bool {
        return (try p.regex.findMode(gpa, text, false, true)) != null;
    }
};

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
    for ([_][]const u8{ "(ab", "[abc", "a{3,2}", "\\" }) |bad| {
        try testing.expectError(error.InvalidPattern, Pattern.compile(testing.allocator, bad));
    }
}

test "fuzz: any pattern compiles or is refused, and any search ends" {
    try shakedown_mod.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown_mod.Case) anyerror!void {
            var buf: [64]u8 = undefined;
            const all = buf[0..shakedown_mod.gen.intRange(case.source, usize, 0, buf.len)];
            case.source.bytes(all);
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
    }.one, .{});
}

//=========================================================================
// Regex: basic and extended, with where the match is
//=========================================================================

/// Which grammar a `Regex` is written in.
pub const Syntax = enum {
    /// POSIX basic expressions with GNU's `\+`, `\?` and `\|`: `regcomp`
    /// without `REG_EXTENDED`, what `git grep` uses by default.
    basic,
    /// POSIX extended expressions: `REG_EXTENDED`, `git grep -E`.
    extended,
};

/// How a `Regex` is compiled.
pub const Flags = struct {
    syntax: Syntax = .extended,
    /// `REG_ICASE`, for ASCII letters.
    icase: bool = false,
    /// REG_NEWLINE: dot and negated brackets exclude LF; anchors see lines.
    newline: bool = true,
};

/// Where a match is: `text[start..end]`.
pub const Match = struct { start: usize, end: usize };

const Inst = union(enum) {
    byte: u8,
    set: *const [256]bool,
    any,
    split: struct { x: u32, y: u32 },
    jmp: u32,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    word_start,
    word_end,
    match,
};

/// The most instructions a pattern may compile to, so a nest of intervals
/// cannot blow up.
const max_program = 1 << 16;

/// A compiled pattern, matched one line at a time as `regexec` with
/// `REG_NEWLINE` matches: the leftmost match, and of those the longest.
/// GNU's `\w`, `\W`, `\s`, `\S`, `\b`, `\B`, `\<` and `\>` are understood.
/// A pattern with a back-reference, `\1` to `\9`, is matched as glibc
/// matches it: of every way through the pattern whose references repeat
/// what their groups took, the one ending furthest; a search past a budget
/// of work is refused as `error.PatternTooComplex`.
pub const Regex = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    program: []const Inst,
    /// The pattern itself, for one with a back-reference, which the
    /// program cannot match; `null` for the rest.
    tree: ?*const RNode = null,
    icase: bool = false,
    newline: bool = true,
    first_bytes: [4]u64 = @splat(std.math.maxInt(u64)),
    nullable: bool = true,

    pub const CompileError = ErrorNamespace.Error;
    pub const FindWithError = error{PatternTooComplex};
    pub const FindError = Allocator.Error || FindWithError;

    /// Compile `text` under `flags`.
    pub fn compile(gpa: Allocator, text: []const u8, flags: Flags) CompileError!Regex {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var p: RParser = .{ .a = a, .text = text, .flags = flags };
        const tree = try p.parseAlt(0);
        if (p.at != text.len) return error.InvalidPattern;
        if (p.backrefs) {
            const program = try a.dupe(Inst, &.{.match});
            return .{ .arena = arena, .program = program, .tree = tree, .icase = flags.icase, .newline = flags.newline };
        }
        var c: Compiler = .{ .a = a, .icase = flags.icase };
        try c.prog.ensureTotalCapacity(a, @min(text.len + 1, max_program));
        try c.emit(tree);
        try c.push(.match);
        const first = firstOf(tree);
        return .{ .arena = arena, .program = c.prog.items, .newline = flags.newline, .first_bytes = if (flags.icase) @splat(std.math.maxInt(u64)) else first.bytes, .nullable = first.empty };
    }

    pub fn deinit(r: *Regex) void {
        r.arena.deinit();
        r.* = undefined;
    }

    /// The leftmost-longest match in `line`, or `null`. `not_bol` is
    /// `REG_NOTBOL`: the start of `line` is not the start of a line, as
    /// when a search resumes after an earlier match.
    pub fn find(r: *const Regex, gpa: Allocator, line: []const u8, not_bol: bool) FindError!?Match {
        return r.findMode(gpa, line, not_bol, false);
    }

    fn findMode(r: *const Regex, gpa: Allocator, line: []const u8, not_bol: bool, boolean: bool) FindError!?Match {
        if (r.tree) |tree| return Backtrack.find(tree, line, not_bol, r.icase, r.newline);
        if (r.program.len <= Vm.Scratch.capacity) {
            var scratch: Vm.Scratch = undefined;
            var vm = scratch.vm(r.program.len);
            vm.boolean = boolean;
            return r.findWith(&vm, line, not_bol);
        }
        var vm: Vm = try .init(gpa, r.program.len);
        vm.boolean = boolean;
        defer vm.deinit(gpa);
        return r.findWith(&vm, line, not_bol);
    }

    /// `find` with scratch space the caller keeps between calls.
    pub fn findWith(r: *const Regex, vm: *Vm, line: []const u8, not_bol: bool) FindWithError!?Match {
        if (r.tree) |tree| return Backtrack.find(tree, line, not_bol, r.icase, r.newline);
        vm.newline = r.newline;
        vm.first_bytes = r.first_bytes;
        vm.nullable = r.nullable;
        return vm.run(r.program, line, not_bol);
    }
};

/// Every way through a pattern with back-references, one start at a time:
/// glibc's answer, the leftmost start and of its ways the furthest end.
const Backtrack = struct {
    line: []const u8,
    not_bol: bool,
    icase: bool,
    newline: bool,
    /// What groups one to nine last took on the way being tried.
    caps: [10]?Match = @splat(null),
    end: ?usize = null,
    steps: usize = 0,
    depth: usize = 0,
    over: bool = false,

    /// The work a whole search may take, and how deep the way may nest, so a
    /// pattern cannot run away or run the stack out.
    const max_steps = 1 << 18;
    const max_depth = 1 << 9;

    /// What is left to match after the node in hand.
    const Cont = struct {
        item: union(enum) {
            seq: []const *const RNode,
            close: struct { index: u32, start: usize },
            rep: struct { node: *const RNode, min: u32, max: ?u32, count: u32, start: usize },
        },
        next: ?*const Cont,
    };

    fn find(tree: *const RNode, line: []const u8, not_bol: bool, icase: bool, newline: bool) Regex.FindWithError!?Match {
        var b: Backtrack = .{ .line = line, .not_bol = not_bol, .icase = icase, .newline = newline };
        var start: usize = 0;
        while (start <= line.len) : (start += 1) {
            b.end = null;
            b.caps = @splat(null);
            b.step(tree, start, null);
            if (b.over) return error.PatternTooComplex;
            if (b.end) |end| return .{ .start = start, .end = end };
        }
        return null;
    }

    fn step(b: *Backtrack, n: *const RNode, at: usize, k: ?*const Cont) void {
        if (b.over) return;
        b.steps += 1;
        b.depth += 1;
        defer b.depth -= 1;
        if (b.steps > max_steps or b.depth > max_depth) {
            b.over = true;
            return;
        }
        const line = b.line;
        const pw = at > 0 and Vm.isWord(line[at - 1]);
        const nw = at < line.len and Vm.isWord(line[at]);
        switch (n.*) {
            .empty => b.cont(at, k),
            .byte => |c| if (at < line.len and line[at] == c) b.cont(at + 1, k),
            .set => |s| if (at < line.len and s[line[at]]) b.cont(at + 1, k),
            .any => if (at < line.len and (!b.newline or line[at] != '\n')) b.cont(at + 1, k),
            .bol => if ((at == 0 and !b.not_bol) or (b.newline and at > 0 and line[at - 1] == '\n')) b.cont(at, k),
            .eol => if (at == line.len or (b.newline and line[at] == '\n')) b.cont(at, k),
            .word_boundary => if (pw != nw) b.cont(at, k),
            .not_word_boundary => if (pw == nw) b.cont(at, k),
            .word_start => if (!pw and nw) b.cont(at, k),
            .word_end => if (pw and !nw) b.cont(at, k),
            .concat => |items| {
                const rest: Cont = .{ .item = .{ .seq = items[1..] }, .next = k };
                b.step(items[0], at, &rest);
            },
            .alt => |branches| for (branches) |branch| b.step(branch, at, k),
            .group => |g| {
                const close: Cont = .{ .item = .{ .close = .{ .index = g.index, .start = at } }, .next = k };
                b.step(g.node, at, &close);
            },
            .backref => |i| {
                // a group that took nothing on this way matches nothing
                const cap = b.caps[i] orelse return;
                const text = line[cap.start..cap.end];
                if (line.len - at < text.len) return;
                const here = line[at..][0..text.len];
                const same = if (b.icase) std.ascii.eqlIgnoreCase(here, text) else std.mem.eql(u8, here, text);
                if (same) b.cont(at + text.len, k);
            },
            .repeat => |r| b.rep(r.node, r.min, r.max, 0, at, k),
        }
    }

    fn rep(b: *Backtrack, node: *const RNode, min: u32, max: ?u32, count: u32, at: usize, k: ?*const Cont) void {
        if (max == null or count < max.?) {
            const again: Cont = .{ .item = .{ .rep = .{ .node = node, .min = min, .max = max, .count = count + 1, .start = at } }, .next = k };
            b.step(node, at, &again);
        }
        if (count >= min) b.cont(at, k);
    }

    fn cont(b: *Backtrack, at: usize, k: ?*const Cont) void {
        const c = k orelse {
            if (b.end == null or at > b.end.?) b.end = at;
            return;
        };
        switch (c.item) {
            .seq => |items| {
                if (items.len == 1) return b.step(items[0], at, c.next);
                const rest: Cont = .{ .item = .{ .seq = items[1..] }, .next = c.next };
                b.step(items[0], at, &rest);
            },
            .close => |cl| {
                if (cl.index >= b.caps.len) return b.cont(at, c.next);
                const old = b.caps[cl.index];
                b.caps[cl.index] = .{ .start = cl.start, .end = at };
                b.cont(at, c.next);
                b.caps[cl.index] = old;
            },
            .rep => |r| {
                // a pass that took nothing may set its groups, but another
                // after it would take nothing again
                if (at == r.start and r.count >= r.min) return b.cont(at, c.next);
                b.rep(r.node, r.min, r.max, r.count, at, c.next);
            },
        }
    }
};

/// Scratch space for matching, sized for one program and reused from line
/// to line.
pub const Vm = struct {
    pub const Error = ErrorNamespace.Error;

    boolean: bool = false,
    first_bytes: [4]u64 = @splat(std.math.maxInt(u64)),
    nullable: bool = true,
    newline: bool = true,
    cur: Threads,
    next: Threads,
    stack: []u32,

    const Threads = struct {
        pcs: []u32,
        starts: []usize,
        len: usize = 0,
        /// `mark[pc]` is the generation `pc` was last added in.
        mark: []u64,
    };

    const Scratch = struct {
        const capacity = 128;
        cur_pcs: [capacity]u32,
        cur_starts: [capacity]usize,
        cur_marks: [capacity]u64,
        next_pcs: [capacity]u32,
        next_starts: [capacity]usize,
        next_marks: [capacity]u64,
        stack: [capacity * 2 + 2]u32,

        fn vm(s: *Scratch, n: usize) Vm {
            return .{
                .cur = .{ .pcs = s.cur_pcs[0..n], .starts = s.cur_starts[0..n], .mark = s.cur_marks[0..n] },
                .next = .{ .pcs = s.next_pcs[0..n], .starts = s.next_starts[0..n], .mark = s.next_marks[0..n] },
                .stack = s.stack[0 .. n * 2 + 2],
            };
        }
    };

    pub fn init(gpa: Allocator, n: usize) Allocator.Error!Vm {
        var vm: Vm = .{ .cur = undefined, .next = undefined, .stack = undefined };
        vm.cur.pcs = try gpa.alloc(u32, n);
        errdefer gpa.free(vm.cur.pcs);
        vm.cur.starts = try gpa.alloc(usize, n);
        errdefer gpa.free(vm.cur.starts);
        vm.cur.mark = try gpa.alloc(u64, n);
        errdefer gpa.free(vm.cur.mark);
        vm.next.pcs = try gpa.alloc(u32, n);
        errdefer gpa.free(vm.next.pcs);
        vm.next.starts = try gpa.alloc(usize, n);
        errdefer gpa.free(vm.next.starts);
        vm.next.mark = try gpa.alloc(u64, n);
        errdefer gpa.free(vm.next.mark);
        vm.cur.len = 0;
        vm.next.len = 0;
        vm.stack = try gpa.alloc(u32, n * 2 + 2);
        return vm;
    }

    pub fn deinit(vm: *Vm, gpa: Allocator) void {
        inline for (.{ &vm.cur, &vm.next }) |t| {
            gpa.free(t.pcs);
            gpa.free(t.starts);
            gpa.free(t.mark);
        }
        gpa.free(vm.stack);
        vm.* = undefined;
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Add `pc` and everything it reaches without reading, for a thread
    /// that started at `start`, the earliest start winning a state.
    fn add(vm: *Vm, t: *Threads, gen: u64, prog: []const Inst, pc0: u32, start: usize, line: []const u8, at: usize, not_bol: bool) void {
        var sp: usize = 0;
        vm.stack[sp] = pc0;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = vm.stack[sp];
            if (t.mark[pc] == gen) continue;
            t.mark[pc] = gen;
            const prev: ?u8 = if (at > 0) line[at - 1] else null;
            const nextc: ?u8 = if (at < line.len) line[at] else null;
            const pw = if (prev) |c| isWord(c) else false;
            const nw = if (nextc) |c| isWord(c) else false;
            switch (prog[pc]) {
                .jmp => |x| {
                    vm.stack[sp] = x;
                    sp += 1;
                },
                .split => |s| {
                    // y pushed first so x is taken first
                    vm.stack[sp] = s.y;
                    vm.stack[sp + 1] = s.x;
                    sp += 2;
                },
                .bol => if ((at == 0 and !not_bol) or (vm.newline and at > 0 and line[at - 1] == '\n')) {
                    vm.stack[sp] = pc + 1;
                    sp += 1;
                },
                .eol => if (at == line.len or (vm.newline and line[at] == '\n')) {
                    vm.stack[sp] = pc + 1;
                    sp += 1;
                },
                .word_boundary => if (pw != nw) {
                    vm.stack[sp] = pc + 1;
                    sp += 1;
                },
                .not_word_boundary => if (pw == nw) {
                    vm.stack[sp] = pc + 1;
                    sp += 1;
                },
                .word_start => if (!pw and nw) {
                    vm.stack[sp] = pc + 1;
                    sp += 1;
                },
                .word_end => if (pw and !nw) {
                    vm.stack[sp] = pc + 1;
                    sp += 1;
                },
                else => {
                    t.pcs[t.len] = pc;
                    t.starts[t.len] = start;
                    t.len += 1;
                },
            }
        }
    }

    fn run(vm: *Vm, prog: []const Inst, line: []const u8, not_bol: bool) ?Match {
        var best: ?Match = null;
        var gen: u64 = 0;
        vm.cur.len = 0;
        @memset(vm.cur.mark, std.math.maxInt(u64));
        @memset(vm.next.mark, std.math.maxInt(u64));
        var at: usize = 0;
        while (true) : (at += 1) {
            // a new thread from here, unless a match already started earlier
            if (best == null and (vm.nullable or (at < line.len and vm.first_bytes[line[at] >> 6] & (@as(u64, 1) << @intCast(line[at] & 63)) != 0))) vm.add(&vm.cur, gen, prog, 0, at, line, at, not_bol);
            if (vm.cur.len == 0 and (best != null or at >= line.len)) break;
            gen += 1;
            vm.next.len = 0;
            var i: usize = 0;
            while (i < vm.cur.len) : (i += 1) {
                const pc = vm.cur.pcs[i];
                const start = vm.cur.starts[i];
                if (best) |b| if (start > b.start) continue;
                switch (prog[pc]) {
                    .match => {
                        if (vm.boolean) return .{ .start = start, .end = at };
                        if (best == null or start < best.?.start or (start == best.?.start and at > best.?.end)) best = .{ .start = start, .end = at };
                    },
                    .byte => |c| if (at < line.len and line[at] == c) vm.add(&vm.next, gen, prog, pc + 1, start, line, at + 1, not_bol),
                    .set => |s| if (at < line.len and s[line[at]]) vm.add(&vm.next, gen, prog, pc + 1, start, line, at + 1, not_bol),
                    .any => if (at < line.len and (!vm.newline or line[at] != '\n')) vm.add(&vm.next, gen, prog, pc + 1, start, line, at + 1, not_bol),
                    else => {},
                }
            }
            std.mem.swap(Threads, &vm.cur, &vm.next);
            if (at >= line.len) {
                // the threads that read past the end are gone; what is
                // left can only be a match at the very end
                gen += 1;
                var j: usize = 0;
                while (j < vm.cur.len) : (j += 1) {
                    if (prog[vm.cur.pcs[j]] == .match) {
                        const start = vm.cur.starts[j];
                        if (best == null or start < best.?.start or (start == best.?.start and line.len > best.?.end)) best = .{ .start = start, .end = line.len };
                    }
                }
                break;
            }
        }
        return best;
    }
};

const RNode = union(enum) {
    empty,
    byte: u8,
    set: *const [256]bool,
    any,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    word_start,
    word_end,
    concat: []const *const RNode,
    alt: []const *const RNode,
    repeat: struct { node: *const RNode, min: u32, max: ?u32 },
    /// A group, numbered from one in the order it opens.
    group: struct { node: *const RNode, index: u32 },
    /// `\1` to `\9`: what that group took.
    backref: u32,
};

const First = struct { bytes: [4]u64 = @splat(0), empty: bool = false };

// An impossible first byte cannot start a thread. This is only a pruning
// hint over the same program, never another expression matcher.
fn firstOf(n: *const RNode) First {
    switch (n.*) {
        .byte => |c| {
            var f: First = .{};
            f.bytes[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
            return f;
        },
        .set => |set| {
            var f: First = .{};
            for (set, 0..) |allowed, c| if (allowed) {
                f.bytes[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
            };
            return f;
        },
        .any => return .{ .bytes = @splat(std.math.maxInt(u64)) },
        .backref => return .{ .bytes = @splat(std.math.maxInt(u64)), .empty = true },
        .group => |g| return firstOf(g.node),
        .repeat => |r| {
            if (r.max == 0) return .{ .empty = true };
            var f = firstOf(r.node);
            if (r.min == 0) f.empty = true;
            return f;
        },
        .concat, .alt => |children| {
            var f: First = .{ .empty = n.* == .concat };
            for (children) |child| {
                const one = firstOf(child);
                for (&f.bytes, one.bytes) |*word, bits| word.* |= bits;
                if (n.* == .concat) {
                    if (!one.empty) {
                        f.empty = false;
                        break;
                    }
                } else f.empty = f.empty or one.empty;
            }
            return f;
        },
        else => return .{ .empty = true },
    }
}

const RParser = struct {
    a: Allocator,
    text: []const u8,
    flags: Flags,
    at: usize = 0,
    /// Groups opened so far, and which of one to nine have closed.
    groups: u32 = 0,
    closed: u16 = 0,
    backrefs: bool = false,
    // Allocate nodes in stable blocks instead of growing the arena for each
    // individual node. Pointers remain valid through compilation and matching.
    nodes: []RNode = &.{},

    fn node(p: *RParser, n: RNode) Allocator.Error!*const RNode {
        if (p.nodes.len == 0) p.nodes = try p.a.alloc(RNode, 16);
        const out = &p.nodes[0];
        p.nodes = p.nodes[1..];
        out.* = n;
        return out;
    }

    fn openGroup(p: *RParser) u32 {
        p.groups += 1;
        return p.groups;
    }

    fn closeGroup(p: *RParser, inner: *const RNode, index: u32) Allocator.Error!*const RNode {
        if (index <= 9) p.closed |= @as(u16, 1) << @intCast(index); // safe: index is at most nine
        return p.node(.{ .group = .{ .node = inner, .index = index } });
    }

    fn isBasic(p: *const RParser) bool {
        return p.flags.syntax == .basic;
    }

    fn peek(p: *const RParser, off: usize) ?u8 {
        return if (p.at + off < p.text.len) p.text[p.at + off] else null;
    }

    /// At an alternation bar: `|`, or `\|` in a basic expression.
    fn atBar(p: *const RParser) bool {
        if (p.isBasic()) return p.peek(0) == '\\' and p.peek(1) == '|';
        return p.peek(0) == '|';
    }

    fn atClose(p: *const RParser, depth: u32) bool {
        if (depth == 0) return false;
        if (p.isBasic()) return p.peek(0) == '\\' and p.peek(1) == ')';
        return p.peek(0) == ')';
    }

    fn parseAlt(p: *RParser, depth: u32) Regex.CompileError!*const RNode {
        const first = try p.parseConcat(depth);
        if (!p.atBar()) return first;
        var branches: std.ArrayList(*const RNode) = .empty;
        try branches.append(p.a, first);
        while (p.atBar()) {
            p.at += if (p.isBasic()) 2 else 1;
            try branches.append(p.a, try p.parseConcat(depth));
        }
        return p.node(.{ .alt = branches.items });
    }

    fn parseConcat(p: *RParser, depth: u32) Regex.CompileError!*const RNode {
        var items: std.ArrayList(*const RNode) = .empty;
        const branch_start = p.at;
        while (p.at < p.text.len) {
            if (p.atBar() or p.atClose(depth)) break;
            const atom_start = p.at;
            var atom = try p.parseAtom(depth, p.at == branch_start);
            // quantifiers
            while (p.at < p.text.len) {
                var min: u32 = undefined;
                var max: ?u32 = undefined;
                const c = p.text[p.at];
                if (c == '*') {
                    // a basic expression's leading star is itself
                    min = 0;
                    max = null;
                    p.at += 1;
                } else if (!p.isBasic() and (c == '+' or c == '?')) {
                    min = if (c == '+') 1 else 0;
                    max = if (c == '+') null else 1;
                    p.at += 1;
                } else if (p.isBasic() and c == '\\' and (p.peek(1) == '+' or p.peek(1) == '?')) {
                    min = if (p.peek(1) == '+') 1 else 0;
                    max = if (p.peek(1) == '+') null else 1;
                    p.at += 2;
                } else if ((!p.isBasic() and c == '{') or (p.isBasic() and c == '\\' and p.peek(1) == '{')) {
                    const save = p.at;
                    p.at += if (p.isBasic()) 2 else 1;
                    const interval = p.parseInterval() catch |err| {
                        if (!p.isBasic() and err == error.NotInterval) {
                            // an extended `{` that is no interval is itself
                            p.at = save;
                            break;
                        }
                        return switch (err) {
                            error.NotInterval => error.InvalidPattern,
                            else => |e| e,
                        };
                    };
                    min = interval.min;
                    max = interval.max;
                } else break;
                atom = try p.node(.{ .repeat = .{ .node = atom, .min = min, .max = max } });
            }
            _ = atom_start;
            try items.append(p.a, atom);
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .concat = items.items });
    }

    const IntervalError = Error || error{NotInterval};

    fn parseInterval(p: *RParser) IntervalError!struct { min: u32, max: ?u32 } {
        const close_text: []const u8 = if (p.isBasic()) "\\}" else "}";
        const close = std.mem.findPos(u8, p.text, p.at, close_text) orelse return error.NotInterval;
        const inside = p.text[p.at..close];
        var min: u32 = undefined;
        var max: ?u32 = undefined;
        if (std.mem.findScalar(u8, inside, ',')) |comma| {
            for (inside[0..comma]) |digit| if (!std.ascii.isDigit(digit)) return error.NotInterval;
            for (inside[comma + 1 ..]) |digit| if (!std.ascii.isDigit(digit)) return error.NotInterval;
            min = if (comma == 0) 0 else std.fmt.parseUnsigned(u32, inside[0..comma], 10) catch return error.InvalidPattern;
            max = if (comma + 1 == inside.len) null else std.fmt.parseUnsigned(u32, inside[comma + 1 ..], 10) catch return error.InvalidPattern;
        } else {
            if (inside.len == 0) return error.NotInterval;
            for (inside) |digit| if (!std.ascii.isDigit(digit)) return error.NotInterval;
            min = std.fmt.parseUnsigned(u32, inside, 10) catch return error.InvalidPattern;
            max = min;
        }
        if (max) |m| if (m < min) return error.InvalidPattern;
        if (min > 0x7fff or (max orelse 0) > 0x7fff) return error.InvalidPattern;
        p.at = close + close_text.len;
        return .{ .min = min, .max = max };
    }

    fn literal(p: *RParser, c: u8) Allocator.Error!*const RNode {
        if (p.flags.icase and std.ascii.isAlphabetic(c)) {
            const set = try p.a.create([256]bool);
            set.* = @splat(false);
            set[std.ascii.toLower(c)] = true;
            set[std.ascii.toUpper(c)] = true;
            return p.node(.{ .set = set });
        }
        return p.node(.{ .byte = c });
    }

    fn classOf(p: *RParser, comptime f: fn (u8) bool, negate: bool) Allocator.Error!*const RNode {
        const set = try p.a.create([256]bool);
        for (set, 0..) |*b, i| b.* = f(@intCast(i)) != negate;
        return p.node(.{ .set = set });
    }

    fn wordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn spaceChar(c: u8) bool {
        return std.ascii.isWhitespace(c);
    }

    fn parseAtom(p: *RParser, depth: u32, branch_start: bool) Regex.CompileError!*const RNode {
        const c = p.text[p.at];
        const basic = p.isBasic();
        switch (c) {
            '.' => {
                p.at += 1;
                return p.node(.any);
            },
            '[' => return p.node(.{ .set = try p.bracket() }),
            '^' => {
                p.at += 1;
                // a basic expression's `^` anchors only where a branch starts
                if (basic and !branch_start) return p.literal('^');
                return p.node(.bol);
            },
            '$' => {
                p.at += 1;
                if (basic) {
                    const at_end = p.at == p.text.len or
                        (p.peek(0) == '\\' and (p.peek(1) == ')' or p.peek(1) == '|'));
                    if (!at_end) return p.literal('$');
                }
                return p.node(.eol);
            },
            '*' => {
                if (basic and branch_start) {
                    p.at += 1;
                    return p.literal('*');
                }
                return error.InvalidPattern;
            },
            '(' => if (!basic) {
                p.at += 1;
                const index = p.openGroup();
                const inner = try p.parseAlt(depth + 1);
                if (p.peek(0) != ')') return error.InvalidPattern;
                p.at += 1;
                return p.closeGroup(inner, index);
            } else {
                p.at += 1;
                return p.literal('(');
            },
            ')' => {
                if (!basic) {
                    if (depth == 0) {
                        p.at += 1;
                        return p.literal(')');
                    }
                    return error.InvalidPattern;
                }
                p.at += 1;
                return p.literal(')');
            },
            '+', '?' => if (!basic) {
                return error.InvalidPattern;
            } else {
                p.at += 1;
                return p.literal(c);
            },
            '{' => {
                p.at += 1;
                return p.literal('{');
            },
            '\\' => {
                if (p.at + 1 >= p.text.len) return error.InvalidPattern;
                const e = p.text[p.at + 1];
                p.at += 2;
                switch (e) {
                    '(' => if (basic) {
                        const index = p.openGroup();
                        const inner = try p.parseAlt(depth + 1);
                        if (!(p.peek(0) == '\\' and p.peek(1) == ')')) return error.InvalidPattern;
                        p.at += 2;
                        return p.closeGroup(inner, index);
                    },
                    ')' => if (basic) return error.InvalidPattern,
                    '{' => if (basic) return error.InvalidPattern,
                    '1'...'9' => {
                        // only a group already closed may be referred to
                        const index = e - '0';
                        if (p.closed & (@as(u16, 1) << @intCast(index)) == 0) return error.InvalidPattern; // safe: index is one to nine
                        p.backrefs = true;
                        return p.node(.{ .backref = index });
                    },
                    'w' => return p.classOf(wordChar, false),
                    'W' => return p.classOf(wordChar, true),
                    's' => return p.classOf(spaceChar, false),
                    'S' => return p.classOf(spaceChar, true),
                    'b' => return p.node(.word_boundary),
                    'B' => return p.node(.not_word_boundary),
                    '<' => return p.node(.word_start),
                    '>' => return p.node(.word_end),
                    '`' => return p.node(.bol),
                    '\'' => return p.node(.eol),
                    else => {},
                }
                return p.literal(e);
            },
            else => {
                p.at += 1;
                return p.literal(c);
            },
        }
    }

    fn bracket(p: *RParser) Error!*const [256]bool {
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
            if (c == '[' and p.at + 1 < p.text.len and (p.text[p.at + 1] == ':' or p.text[p.at + 1] == '=' or p.text[p.at + 1] == '.')) {
                const kind = p.text[p.at + 1];
                const closing = [2]u8{ kind, ']' };
                const close = std.mem.findPos(u8, p.text, p.at + 2, &closing) orelse return error.InvalidPattern;
                const name = p.text[p.at + 2 .. close];
                if (kind == ':') {
                    for (0..256) |b| {
                        if (inClass(name, @intCast(b)) orelse return error.InvalidPattern) set[b] = true;
                    }
                } else {
                    // an equivalence class or a collating symbol of one
                    // byte is that byte
                    if (name.len != 1) return error.InvalidPattern;
                    set[name[0]] = true;
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
        if (p.flags.icase) {
            for (0..256) |b| {
                if (set[b] and std.ascii.isAlphabetic(@intCast(b))) {
                    set[std.ascii.toLower(@intCast(b))] = true;
                    set[std.ascii.toUpper(@intCast(b))] = true;
                }
            }
        }
        if (negate) {
            for (set) |*b| b.* = !b.*;
            // with REG_NEWLINE a negated bracket never takes a newline
            if (p.flags.newline) set['\n'] = false;
        }
        return set;
    }
};

const Compiler = struct {
    a: Allocator,
    icase: bool,
    prog: std.ArrayList(Inst) = .empty,
    depth: u32 = 0,

    fn push(c: *Compiler, i: Inst) Error!void {
        if (c.prog.items.len >= max_program) return error.PatternTooComplex;
        try c.prog.append(c.a, i);
    }

    fn pc(c: *const Compiler) u32 {
        return @intCast(c.prog.items.len);
    }

    fn emit(c: *Compiler, n: *const RNode) Error!void {
        if (c.depth >= 256) return error.PatternTooComplex;
        c.depth += 1;
        defer c.depth -= 1;
        switch (n.*) {
            .empty => {},
            .byte => |b| try c.push(.{ .byte = b }),
            .set => |s| try c.push(.{ .set = s }),
            .any => try c.push(.any),
            .bol => try c.push(.bol),
            .eol => try c.push(.eol),
            .word_boundary => try c.push(.word_boundary),
            .not_word_boundary => try c.push(.not_word_boundary),
            .word_start => try c.push(.word_start),
            .word_end => try c.push(.word_end),
            .concat => |items| for (items) |item| try c.emit(item),
            .group => |g| try c.emit(g.node),
            // a pattern with one is matched by `Backtrack`, never compiled
            .backref => unreachable,
            .alt => |branches| {
                // split L1, next; L1: branch; jmp end; ...
                var jumps: u32 = std.math.maxInt(u32);
                for (branches, 0..) |branch, i| {
                    if (i + 1 < branches.len) {
                        const split_at = c.pc();
                        try c.push(.{ .split = .{ .x = split_at + 1, .y = 0 } });
                        try c.emit(branch);
                        const jump = c.pc();
                        try c.push(.{ .jmp = jumps });
                        jumps = jump;
                        c.prog.items[split_at].split.y = c.pc();
                    } else try c.emit(branch);
                }
                const end = c.pc();
                // The unfinished instructions themselves hold the patch list.
                // No second allocation is needed for branch destinations.
                while (jumps != std.math.maxInt(u32)) {
                    const next = c.prog.items[jumps].jmp;
                    c.prog.items[jumps] = .{ .jmp = end };
                    jumps = next;
                }
            },
            .repeat => |r| {
                // A required unbounded repetition loops back to its last
                // required body instead of compiling that body twice.
                if (r.max == null and r.min > 0) {
                    var i: u32 = 1;
                    while (i < r.min) : (i += 1) try c.emit(r.node);
                    const loop = c.pc();
                    try c.emit(r.node);
                    try c.push(.{ .split = .{ .x = loop, .y = c.pc() + 1 } });
                    return;
                }
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try c.emit(r.node);
                if (r.max) |mx| {
                    var holes: u32 = std.math.maxInt(u32);
                    var k = r.min;
                    while (k < mx) : (k += 1) {
                        const hole = c.pc();
                        try c.push(.{ .split = .{ .x = hole + 1, .y = holes } });
                        holes = hole;
                        try c.emit(r.node);
                    }
                    const end = c.pc();
                    while (holes != std.math.maxInt(u32)) {
                        const next = c.prog.items[holes].split.y;
                        c.prog.items[holes].split.y = end;
                        holes = next;
                    }
                } else {
                    const loop = c.pc();
                    try c.push(.{ .split = .{ .x = loop + 1, .y = 0 } });
                    try c.emit(r.node);
                    try c.push(.{ .jmp = loop });
                    c.prog.items[loop].split.y = c.pc();
                }
            },
        }
    }
};

test "a regex finds the leftmost, longest match, in basic and extended syntax" {
    const Case = struct { pattern: []const u8, syntax: Syntax = .extended, icase: bool = false, text: []const u8, want: ?Match };
    for ([_]Case{
        .{ .pattern = "b+", .text = "abbbc", .want = .{ .start = 1, .end = 4 } },
        .{ .pattern = "a|ab|abc", .text = "xabcd", .want = .{ .start = 1, .end = 4 } },
        .{ .pattern = "x*", .text = "abc", .want = .{ .start = 0, .end = 0 } },
        .{ .pattern = "c$", .text = "abc", .want = .{ .start = 2, .end = 3 } },
        .{ .pattern = "\\(ab\\)*c", .syntax = .basic, .text = "zababc", .want = .{ .start = 1, .end = 6 } },
        .{ .pattern = "a+b", .syntax = .basic, .text = "aa+b", .want = .{ .start = 1, .end = 4 } },
        .{ .pattern = "a\\+b", .syntax = .basic, .text = "aaab", .want = .{ .start = 0, .end = 4 } },
        .{ .pattern = "a\\|b", .syntax = .basic, .text = "xb", .want = .{ .start = 1, .end = 2 } },
        .{ .pattern = "*a", .syntax = .basic, .text = "x*a", .want = .{ .start = 1, .end = 3 } },
        .{ .pattern = "a^b", .syntax = .basic, .text = "a^b", .want = .{ .start = 0, .end = 3 } },
        .{ .pattern = "HELLO", .icase = true, .text = "say hello", .want = .{ .start = 4, .end = 9 } },
        .{ .pattern = "\\<is\\>", .text = "this is", .want = .{ .start = 5, .end = 7 } },
        .{ .pattern = "[^a]", .text = "aab", .want = .{ .start = 2, .end = 3 } },
        .{ .pattern = "a{2}", .text = "aaa", .want = .{ .start = 0, .end = 2 } },
        .{ .pattern = "q", .text = "abc", .want = null },
    }) |case| {
        var r = try Regex.compile(testing.allocator, case.pattern, .{ .syntax = case.syntax, .icase = case.icase });
        defer r.deinit();
        const got = try r.find(testing.allocator, case.text, false);
        testing.expectEqual(case.want, got) catch |err| {
            std.debug.print("{s} on {s}\n", .{ case.pattern, case.text });
            return err;
        };
    }
}

test "a back-reference takes the way glibc takes: the furthest end any assignment of the groups reaches" {
    // each answer is glibc's regexec, the matcher git uses on Linux and
    // builds in for Windows
    const Case = struct { pattern: []const u8, syntax: Syntax = .basic, icase: bool = false, text: []const u8, want: ?Match };
    for ([_]Case{
        .{ .pattern = "\\(ab\\)\\1", .text = "xabab", .want = .{ .start = 1, .end = 5 } },
        .{ .pattern = "(z)\\1", .syntax = .extended, .text = "xyzzy", .want = .{ .start = 2, .end = 4 } },
        .{ .pattern = "\\(ab\\)\\1", .icase = true, .text = "AbAB", .want = .{ .start = 0, .end = 4 } },
        .{ .pattern = "(a|ab)(c|bcd)?\\1", .syntax = .extended, .text = "abcda", .want = .{ .start = 0, .end = 5 } },
        .{ .pattern = "(a|ab)(c|bcd)?\\1", .syntax = .extended, .text = "abab", .want = .{ .start = 0, .end = 4 } },
        .{ .pattern = "\\(a\\)*\\1", .text = "a", .want = null },
        .{ .pattern = "\\(a\\)*\\1", .text = "aa", .want = .{ .start = 0, .end = 2 } },
        .{ .pattern = "\\(a\\)\\|\\1b", .text = "b", .want = null },
        .{ .pattern = "x\\(a*\\)*y\\1", .text = "xaay", .want = .{ .start = 0, .end = 4 } },
        .{ .pattern = "x\\(a*\\)*y\\1", .text = "xy", .want = .{ .start = 0, .end = 2 } },
    }) |case| {
        var r = try Regex.compile(testing.allocator, case.pattern, .{ .syntax = case.syntax, .icase = case.icase });
        defer r.deinit();
        const got = try r.find(testing.allocator, case.text, false);
        testing.expectEqual(case.want, got) catch |err| {
            std.debug.print("{s} on {s}\n", .{ case.pattern, case.text });
            return err;
        };
    }
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "\\1(a)", .{}));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "\\(a\\1\\)", .{ .syntax = .basic }));
}

test "fuzz: any regex compiles or is refused, and any match is within the line" {
    try shakedown_mod.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown_mod.Case) anyerror!void {
            var buf: [64]u8 = undefined;
            const all = buf[0..shakedown_mod.gen.intRange(case.source, usize, 0, buf.len)];
            case.source.bytes(all);
            const cut = all.len / 2;
            for ([_]Syntax{ .basic, .extended }) |syntax| {
                var r = Regex.compile(testing.allocator, all[0..cut], .{ .syntax = syntax }) catch |err| switch (err) {
                    error.InvalidPattern, error.PatternTooComplex => continue,
                    else => return err,
                };
                defer r.deinit();
                const found = r.find(testing.allocator, all[cut..], false) catch |err| switch (err) {
                    error.PatternTooComplex => continue,
                    else => return err,
                };
                if (found) |m| {
                    try testing.expect(m.start <= m.end and m.end <= all.len - cut);
                }
            }
        }
    }.one, .{});
}

test "boolean ERE uses git extensions and captures" {
    for ([_]struct { []const u8, []const u8, bool }{
        .{ "\\w+", "word", true },
        .{ "\\bcat\\b", "a cat!", true },
        .{ "(ab)\\1", "abab", true },
        .{ "(ab)\\1", "ab1", false },
        .{ "a{256}", &(@as([256]u8, @splat('a'))), true },
    }) |case| {
        var p = try Pattern.compile(testing.allocator, case[0]);
        defer p.deinit();
        try testing.expectEqual(case[2], try p.search(testing.allocator, case[1]));
    }
}

test "regex allocation failures release compile and search state" {
    var no_resize = shakedown_mod.alloc.NoResize.init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(gpa: Allocator) !void {
            var p = try Pattern.compile(gpa, "(ab|a)+c");
            defer p.deinit();
            try std.testing.expect(try p.search(gpa, "ababac"));
            var backref = try Pattern.compile(gpa, "(ab)\\1");
            defer backref.deinit();
            try std.testing.expect(try backref.search(gpa, "abab"));
            var large = try Pattern.compile(gpa, "a{140}");
            defer large.deinit();
            try std.testing.expect(try large.search(gpa, &(@as([140]u8, @splat('a')))));
        }
    }.exercise, .{});
}

test "regex adapters share newline policy and bounded backreferences" {
    const gpa = std.testing.allocator;
    var whole = try Pattern.compile(gpa, "one.two");
    defer whole.deinit();
    try std.testing.expect(try whole.search(gpa, "one\ntwo"));
    var lines = try Regex.compile(gpa, "one.two", .{});
    defer lines.deinit();
    try std.testing.expectEqual(@as(?Match, null), try lines.find(gpa, "one\ntwo", false));
    var anchors = try Regex.compile(gpa, "^two$", .{});
    defer anchors.deinit();
    try std.testing.expect((try anchors.find(gpa, "one\ntwo", true)) != null);
    var backref = try Pattern.compile(gpa, "(a*)*\\1b");
    defer backref.deinit();
    const text: [1024]u8 = @splat('a');
    try std.testing.expectError(error.PatternTooComplex, backref.search(gpa, &text));
}

test "ERE adapters refuse repetition operators with no operand" {
    for ([_][]const u8{ "*a", "+a", "?a", "a|*b", "(*a)" }) |pattern| {
        if (Pattern.compile(testing.allocator, pattern)) |compiled| {
            var p = compiled;
            defer p.deinit();
            try testing.expect(false);
        } else |err| try testing.expectEqual(error.InvalidPattern, err);
        if (Regex.compile(testing.allocator, pattern, .{})) |compiled| {
            var r = compiled;
            defer r.deinit();
            try testing.expect(false);
        } else |err| try testing.expectEqual(error.InvalidPattern, err);
    }
    var literal = try Regex.compile(testing.allocator, "*a", .{ .syntax = .basic });
    defer literal.deinit();
    try testing.expect((try literal.find(testing.allocator, "x*a", false)) != null);
}

test "ERE adapters reject reversed and oversized intervals" {
    for ([_][]const u8{ "a{3,2}", "a{32768}", "a{1,32768}", "a{4294967296}", "a{1,4294967296}" }) |pattern| {
        if (Pattern.compile(testing.allocator, pattern)) |compiled| {
            var p = compiled;
            defer p.deinit();
            try testing.expect(false);
        } else |err| try testing.expectEqual(error.InvalidPattern, err);
        if (Regex.compile(testing.allocator, pattern, .{})) |compiled| {
            var r = compiled;
            defer r.deinit();
            try testing.expect(false);
        } else |err| try testing.expectEqual(error.InvalidPattern, err);
    }
    for ([_][]const u8{ "a{word}", "a{2", "a{1,2,3}" }) |literal| {
        var p = try Pattern.compile(testing.allocator, literal);
        defer p.deinit();
        try testing.expect(try p.search(testing.allocator, literal));
        var r = try Regex.compile(testing.allocator, literal, .{});
        defer r.deinit();
        const found = (try r.find(testing.allocator, literal, false)).?;
        try testing.expectEqual(@as(usize, 0), found.start);
        try testing.expectEqual(literal.len, found.end);
    }
}
