//! `git grep`: lines matching patterns in the tracked files of the working
//! tree, in the index, or in a tree or commit, written as git writes them.
//!
//! Patterns are fixed strings, POSIX basic expressions (git's default) or
//! extended ones (`ere.zig`), back-references included, with `-i`, `-w`
//! and `-v` as git applies them: `-w` retries past a match that is not a
//! whole word, exactly where git's does. Several patterns match when any
//! does, or as `--and`, `--not` and parentheses combine them, and
//! `--all-match` keeps the files where every one of them matched. A file
//! is binary by its `diff` and `binary` attributes, else by a NUL in its
//! first 8000 bytes, and is then reported as `Binary file <name> matches`.
//! Output is git's to the byte: names, `-n` and `--column` numbers,
//! `-A`/`-B`/`-C` context with `--` between hunks, `-p` and `-W` with the
//! function lines git's `diff` drivers find, `-o`, `-c`, `-l`, `-L`, `-z`.
//! The files are searched on tasks of the caller's `std.Io`, and written
//! in path order.
//!
//! `-P` (PCRE) is the caller's to bring, as a `Matcher`; without one it is
//! refused by name, as are submodule recursion and `--no-index`.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("hash/hash.zig");
const object = @import("object/object.zig");
const repo_mod = @import("repo/repo.zig");
const index_mod = @import("index/index.zig");
const odb_mod = @import("odb/odb.zig");
const attributes = @import("patterns.zig").attributes;
const ere = @import("text.zig").ere;
const pathspec_mod = @import("patterns.zig").pathspec;
const fs = @import("fs.zig");
const userdiff = @import("diff/userdiff.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a grep.
pub const Error = error{
    /// `-P` with no `Matcher`: Perl-compatible expressions, which git
    /// builds with PCRE and this does not have.
    UnsupportedPerlRegex,
    /// A pattern that does not compile.
    InvalidPattern,
    /// A pattern whose program would be too large, or whose search took
    /// more work than the budget allows.
    PatternTooComplex,
    /// The `Matcher` failed.
    PerlMatchFailed,
    /// `--and`, `--not` or a parenthesis where git's expression grammar
    /// has no place for it.
    InvalidExpression,
    /// A `diff` driver's `funcname` or `xfuncname` that does not compile.
    InvalidFunctionPattern,
    /// No pattern was given.
    NoPattern,
    /// A pattern with a NUL in it, which git takes only under `-P`.
    NulInPattern,
    /// The working tree was asked of a bare repository.
    BareRepository,
    /// The object to search is not a commit or a tree.
    NotATree,
    /// The tree nests deeper than `object.max_tree_depth`.
    TreeTooDeep,
} || pathspec_mod.Error || index_mod.ReadError || repo_mod.Error || attributes.Error || Io.Writer.Error ||
    odb_mod.Error || object.TreeParseError;

/// How patterns are read: `-G`, `-E`, `-F`, `-P`.
pub const Syntax = enum { basic, extended, fixed, perl };

/// Where a match is in a line: `line[start..end]`.
pub const Match = struct { start: usize, end: usize };

/// The matcher a caller brings for `-P`. `find` answers the leftmost
/// match of one pattern — `index` counts the patterns in the order they
/// are given — in `line`, which holds no newline; `not_bol` says the
/// start of `line` is not the start of a line, as when a search resumes
/// after a match. `-i` is the matcher's to apply. It is called from
/// several tasks at once.
pub const Matcher = struct {
    context: *anyopaque,
    find: *const fn (context: *anyopaque, index: usize, line: []const u8, not_bol: bool) error{MatchFailed}!?Match,
};

/// One word of a pattern expression, as git's command line has them.
pub const Term = union(enum) {
    /// `-e <pattern>`.
    pattern: []const u8,
    /// `--and`, which binds tighter than the either-or of terms side by
    /// side.
    @"and",
    /// `--or`, which git takes and ignores: terms side by side already
    /// match when either does.
    @"or",
    /// `--not`.
    not,
    /// `(`.
    open,
    /// `)`.
    close,
};

/// Where the files come from.
pub const Source = union(enum) {
    /// The tracked files of the working tree: `git grep`.
    worktree,
    /// The index: `git grep --cached`.
    index,
    /// A tree, or a commit's: `git grep <tree-ish>`. `name` is what each
    /// path is printed after, with a `:`, as git prints the name given on
    /// its command line; empty prints the paths alone.
    tree: struct { oid: Oid, name: []const u8 = "" },
};

/// What a binary file does: git's default, `-a`, or `-I`.
pub const Binary = enum { match, text, skip };

/// What is printed for each file.
pub const Show = enum {
    /// The matching lines.
    lines,
    /// `-l`: the names of files with a match.
    files_with_matches,
    /// `-L`: the names of files with none.
    files_without_match,
    /// `-c`: each matching file's name and how many lines matched.
    count,
    /// `-q`: nothing; only whether anything matched.
    quiet,
};

/// How a grep runs.
pub const Options = struct {
    /// `-e`: a line matches when any of these does.
    patterns: []const []const u8 = &.{},
    /// The patterns with `--and`, `--or`, `--not` and parentheses, read
    /// instead of `patterns` when given.
    expression: ?[]const Term = null,
    /// `--all-match`: only files where each pattern of the top-level
    /// either-or matched some line.
    all_match: bool = false,
    /// `null` reads `grep.patternType` and `grep.extendedRegexp`, and is
    /// basic without them.
    syntax: ?Syntax = null,
    /// What matches under `-P`.
    perl: ?Matcher = null,
    ignore_case: bool = false,
    /// `-w`.
    word: bool = false,
    /// `-v`.
    invert: bool = false,
    /// `-n`; `null` reads `grep.lineNumber`.
    line_number: ?bool = null,
    /// `--column`; `null` reads `grep.column`.
    column: ?bool = null,
    show: Show = .lines,
    /// `-o`.
    only_matching: bool = false,
    /// `false` is `-h`.
    with_filename: bool = true,
    /// `-B` and `-A`; `-C` is both.
    before: usize = 0,
    after: usize = 0,
    /// `-p`: the function line above each match.
    show_function: bool = false,
    /// `-W`: the whole function around each match.
    function_context: bool = false,
    /// `-m`.
    max_count: ?usize = null,
    /// `-z`.
    null_separator: bool = false,
    binary: Binary = .match,
    pathspecs: []const []const u8 = &.{},
    source: Source = .worktree,
    /// Tasks to search on: zero is one per processor.
    threads: u16 = 0,
};

/// What a grep found.
pub const Outcome = struct {
    /// Whether anything matched: git's exit status zero.
    matched: bool,
    /// Files searched.
    files: usize,
};

//=========================================================================
// Patterns
//=========================================================================

const Pat = struct {
    kind: union(enum) { fixed: []const u8, regex: ere.Regex, perl: usize },
};

/// git's pattern expression: a flat either-or of the patterns when no
/// operator was given.
const Expr = union(enum) {
    atom: usize,
    not: *const Expr,
    @"and": [2]*const Expr,
    @"or": [2]*const Expr,
};

const MatchError = error{ PatternTooComplex, PerlMatchFailed };
const SearchError = Io.Writer.Error || MatchError;

const Searcher = struct {
    pats: []Pat,
    expr: *const Expr,
    /// The terms of the top-level either-or, which `--all-match` asks to
    /// have each matched somewhere in a file.
    top: []const *const Expr,
    all_match: bool,
    icase: bool,
    word: bool,
    invert: bool,
    /// `--column`, under which git evaluates every term, for the earliest
    /// column.
    column: bool,
    perl: ?Matcher,

    fn deinit(s: *Searcher) void {
        for (s.pats) |*p| switch (p.kind) {
            .regex => |*r| r.deinit(),
            .fixed, .perl => {},
        };
        s.* = undefined;
    }
};

fn isRegexSpecial(c: u8) bool {
    return switch (c) {
        '*', '?', '[', '\\', '$', '(', ')', '+', '.', '^', '{', '|' => true,
        else => false,
    };
}

/// git's `compile_pattern_or` and the rules under it, over the terms with
/// `--or` dropped.
const ExprParser = struct {
    a: Allocator,
    terms: []const Term,
    at: usize = 0,
    atoms: usize = 0,

    fn new(p: *ExprParser, e: Expr) Allocator.Error!*const Expr {
        const out = try p.a.create(Expr);
        out.* = e;
        return out;
    }

    fn orExpr(p: *ExprParser) Error!?*const Expr {
        const x = try p.andExpr() orelse return null;
        if (p.at < p.terms.len and p.terms[p.at] != .close) {
            const y = try p.orExpr() orelse return error.InvalidExpression;
            const expr = try p.new(.{ .@"or" = .{ x, y } });
            return expr;
        }
        return x;
    }

    fn andExpr(p: *ExprParser) Error!?*const Expr {
        const x = try p.notExpr();
        if (p.at < p.terms.len and p.terms[p.at] == .@"and") {
            const left = x orelse return error.InvalidExpression;
            p.at += 1;
            if (p.at >= p.terms.len) return error.InvalidExpression;
            const y = try p.andExpr() orelse return error.InvalidExpression;
            const expr = try p.new(.{ .@"and" = .{ left, y } });
            return expr;
        }
        return x;
    }

    fn notExpr(p: *ExprParser) Error!?*const Expr {
        if (p.at < p.terms.len and p.terms[p.at] == .not) {
            p.at += 1;
            if (p.at >= p.terms.len) return error.InvalidExpression;
            const x = try p.notExpr() orelse return error.InvalidExpression;
            const expr = try p.new(.{ .not = x });
            return expr;
        }
        return p.atom();
    }

    fn atom(p: *ExprParser) Error!?*const Expr {
        if (p.at >= p.terms.len) return null;
        switch (p.terms[p.at]) {
            .pattern => {
                p.at += 1;
                p.atoms += 1;
                return try p.new(.{ .atom = p.atoms - 1 });
            },
            .open => {
                p.at += 1;
                const x = try p.orExpr();
                if (p.at >= p.terms.len or p.terms[p.at] != .close) return error.InvalidExpression;
                p.at += 1;
                return x;
            },
            else => return null,
        }
    }
};

/// The expression and its patterns' texts, in order.
fn parseExpression(a: Allocator, options: Options) Error!struct { expr: *const Expr, texts: []const []const u8 } {
    var texts: std.ArrayList([]const u8) = .empty;
    const given = options.expression orelse {
        if (options.patterns.len == 0) return error.NoPattern;
        // right-nested, as git's grammar nests them
        var expr = try a.create(Expr);
        expr.* = .{ .atom = options.patterns.len - 1 };
        var i = options.patterns.len - 1;
        while (i > 0) {
            i -= 1;
            const left = try a.create(Expr);
            left.* = .{ .atom = i };
            const both = try a.create(Expr);
            both.* = .{ .@"or" = .{ left, expr } };
            expr = both;
        }
        return .{ .expr = expr, .texts = options.patterns };
    };
    var terms: std.ArrayList(Term) = .empty;
    for (given) |t| switch (t) {
        .@"or" => {},
        .pattern => |text| {
            try texts.append(a, text);
            try terms.append(a, t);
        },
        else => try terms.append(a, t),
    };
    if (texts.items.len == 0) return error.NoPattern;
    var p: ExprParser = .{ .a = a, .terms = terms.items };
    const expr = try p.orExpr() orelse return error.InvalidExpression;
    if (p.at != terms.items.len) return error.InvalidExpression;
    return .{ .expr = expr, .texts = texts.items };
}

fn compile(a: Allocator, gpa: Allocator, options: Options, syntax: Syntax, column: bool) Error!Searcher {
    const parsed = try parseExpression(a, options);
    if (syntax == .perl and options.perl == null) return error.UnsupportedPerlRegex;
    var pats: std.ArrayList(Pat) = .empty;
    errdefer for (pats.items) |*p| switch (p.kind) {
        .regex => |*r| r.deinit(),
        .fixed, .perl => {},
    };
    for (parsed.texts, 0..) |text, index| {
        if (syntax == .perl) {
            // everything under `-P` is the matcher's, fixed text included
            try pats.append(a, .{ .kind = .{ .perl = index } });
            continue;
        }
        if (std.mem.findScalar(u8, text, 0) != null) return error.NulInPattern;
        var fixed = syntax == .fixed;
        if (!fixed) {
            fixed = true;
            for (text) |c| if (isRegexSpecial(c)) {
                fixed = false;
            };
        }
        if (fixed) {
            try pats.append(a, .{ .kind = .{ .fixed = text } });
        } else {
            const re = ere.Regex.compile(gpa, text, .{ .syntax = if (syntax == .extended) .extended else .basic, .icase = options.ignore_case }) catch |err| switch (err) {
                error.InvalidPattern => return error.InvalidPattern,
                error.PatternTooComplex => return error.PatternTooComplex,
                error.OutOfMemory => return error.OutOfMemory,
            };
            try pats.append(a, .{ .kind = .{ .regex = re } });
        }
    }
    var top: std.ArrayList(*const Expr) = .empty;
    var x = parsed.expr;
    while (x.* == .@"or") {
        try top.append(a, x.@"or"[0]);
        x = x.@"or"[1];
    }
    try top.append(a, x);
    return .{
        .pats = pats.items,
        .expr = parsed.expr,
        .top = top.items,
        .all_match = options.all_match,
        .icase = options.ignore_case,
        .word = options.word,
        .invert = options.invert,
        .column = column,
        .perl = options.perl,
    };
}

fn findFixed(needle: []const u8, hay: []const u8, icase: bool) ?Match {
    if (needle.len == 0) return .{ .start = 0, .end = 0 };
    if (!icase) {
        const at = std.mem.find(u8, hay, needle) orelse return null;
        return .{ .start = at, .end = at + needle.len };
    }
    const at = std.ascii.findIgnoreCase(hay, needle) orelse return null;
    return .{ .start = at, .end = at + needle.len };
}

/// Scratch a task matches with: one regex machine per pattern, one for
/// the function lines, and `--all-match`'s hits.
const Scratch = struct {
    vms: []?ere.Vm,
    func_vm: ?ere.Vm,
    hits: []bool,

    fn init(gpa: Allocator, s: *const Searcher, func_program: usize) Allocator.Error!Scratch {
        const vms = try gpa.alloc(?ere.Vm, s.pats.len);
        for (vms) |*vm| vm.* = null;
        var sc: Scratch = .{ .vms = vms, .func_vm = null, .hits = &.{} };
        errdefer sc.deinit(gpa);
        for (s.pats, vms) |p, *vm| vm.* = switch (p.kind) {
            .regex => |r| try ere.Vm.init(gpa, r.program.len),
            .fixed, .perl => null,
        };
        if (func_program != 0) sc.func_vm = try ere.Vm.init(gpa, func_program);
        sc.hits = try gpa.alloc(bool, s.top.len);
        return sc;
    }

    fn deinit(sc: *Scratch, gpa: Allocator) void {
        for (sc.vms) |*vm| if (vm.*) |*v| v.deinit(gpa);
        gpa.free(sc.vms);
        if (sc.func_vm) |*v| v.deinit(gpa);
        gpa.free(sc.hits);
        sc.* = undefined;
    }
};

fn patmatch(s: *const Searcher, p: *const Pat, vm: ?*ere.Vm, line: []const u8, not_bol: bool) MatchError!?Match {
    switch (p.kind) {
        .fixed => |text| return findFixed(text, line, s.icase),
        .regex => |*r| {
            const m = try r.findWith(vm.?, line, not_bol) orelse return null;
            return .{ .start = m.start, .end = m.end };
        },
        .perl => |index| {
            const m = s.perl.?.find(s.perl.?.context, index, line, not_bol) catch return error.PerlMatchFailed;
            return m;
        },
    }
}

fn wordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// git's `headerless_match_one_pattern`: a match, with `-w` retried until
/// it is a whole word.
fn matchOne(s: *const Searcher, i: usize, sc: *Scratch, line: []const u8, not_bol_in: bool) MatchError!?Match {
    const p = &s.pats[i];
    const vm: ?*ere.Vm = if (sc.vms[i]) |*v| v else null;
    var bol: usize = 0;
    var not_bol = not_bol_in;
    while (true) {
        const m = try patmatch(s, p, vm, line[bol..], not_bol) orelse return null;
        if (!s.word) return .{ .start = m.start + bol, .end = m.end + bol };
        const so = bol + m.start;
        const eo = bol + m.end;
        var hit = (so == 0 or !wordChar(line[so - 1])) and (eo == line.len or !wordChar(line[eo]));
        if (so == eo) hit = false;
        if (hit) return .{ .start = so, .end = eo };
        if (so + 1 >= line.len) return null;
        bol = so + 1;
        while (wordChar(line[bol - 1]) and bol < line.len) bol += 1;
        not_bol = true;
        if (bol >= line.len) return null;
    }
}

/// git's `match_expr_eval`: whether the line satisfies `x`, with `col`
/// the earliest column a pattern matched at and `icol` the same under an
/// odd number of `--not`s.
fn evalExpr(s: *const Searcher, sc: *Scratch, x: *const Expr, line: []const u8, col: *?usize, icol: *?usize) MatchError!bool {
    switch (x.*) {
        .atom => |i| {
            const m = try matchOne(s, i, sc, line, false) orelse return false;
            if (col.* == null or m.start < col.*.?) col.* = m.start;
            return true;
        },
        .not => |inner| return !try evalExpr(s, sc, inner, line, icol, col),
        .@"and" => |pair| {
            const left = try evalExpr(s, sc, pair[0], line, col, icol);
            // a `--not` above may make this an either-or, so `--column`
            // asks both sides
            if (!left and !s.column) return false;
            const right = try evalExpr(s, sc, pair[1], line, col, icol);
            return left and right;
        },
        .@"or" => |pair| {
            const left = try evalExpr(s, sc, pair[0], line, col, icol);
            if (left and !s.column) return true;
            const right = try evalExpr(s, sc, pair[1], line, col, icol);
            return left or right;
        },
    }
}

/// `--all-match`'s first pass: which top-level terms some line matched.
fn collectHits(s: *const Searcher, sc: *Scratch, content: []const u8) MatchError!bool {
    @memset(sc.hits, false);
    var bol: usize = 0;
    while (bol < content.len) {
        const eol = std.mem.findScalarPos(u8, content, bol, '\n') orelse content.len;
        for (s.top, sc.hits) |term, *hit| {
            var col: ?usize = null;
            var icol: ?usize = null;
            if (try evalExpr(s, sc, term, content[bol..eol], &col, &icol)) hit.* = true;
        }
        bol = eol + 1;
    }
    for (sc.hits) |hit| if (!hit) return false;
    return true;
}

/// git's `grep_next_match`: the earliest match of any pattern, the longest
/// of those.
fn nextMatch(s: *const Searcher, sc: *Scratch, line: []const u8, not_bol: bool) MatchError!?Match {
    if (line.len == 0) return null;
    var best: ?Match = null;
    for (s.pats, 0..) |_, i| {
        const m = try matchOne(s, i, sc, line, not_bol) orelse continue;
        if (best) |b| {
            if (m.start > b.start) continue;
            if (m.start == b.start and m.end < b.end) continue;
        }
        best = m;
    }
    return best;
}

//=========================================================================
// One file
//=========================================================================

const Format = struct {
    show: Show,
    line_number: bool,
    column: bool,
    only_matching: bool,
    pathname: bool,
    before: usize,
    after: usize,
    funcname: bool,
    funcbody: bool,
    max_count: ?usize,
    null_sep: bool,
    binary: Binary,
};

const FileState = struct {
    w: *Io.Writer,
    fmt: *const Format,
    s: *const Searcher,
    sc: *Scratch,
    name: []const u8,
    content: []const u8,
    /// How function lines are found, under `-p` or `-W`.
    rule: ?*const userdiff.Rule,
    last_shown: usize = 0,

    /// The line from `bol` to `eol`, which ends it or the content.
    fn line(st: *const FileState, bol: usize, eol: usize) []const u8 {
        return st.content[bol..eol];
    }

    /// git's `match_funcname`.
    fn isFunction(st: *FileState, text: []const u8) MatchError!bool {
        const rule = st.rule orelse return false;
        return rule.matches(&st.sc.func_vm.?, text);
    }
};

/// The end of the line starting at `bol`: its newline, or the end.
fn endOfLine(content: []const u8, bol: usize) usize {
    return std.mem.findScalarPos(u8, content, bol, '\n') orelse content.len;
}

/// The start of the line before the one starting at `bol`, which is not
/// the first.
fn startOfLineBefore(content: []const u8, bol: usize) usize {
    var b = bol - 1;
    while (b > 0 and content[b - 1] != '\n') b -= 1;
    return b;
}

/// git's `is_empty_line`, with git's own `isspace`.
fn isEmptyLine(text: []const u8) bool {
    for (text) |c| switch (c) {
        ' ', '\t', '\n', '\r' => {},
        else => return false,
    };
    return true;
}

fn outputSep(st: *FileState, sign: u8) Io.Writer.Error!void {
    if (st.fmt.null_sep) try st.w.writeByte(0) else try st.w.writeByte(sign);
}

fn showLineHeader(st: *FileState, lno: usize, cno: usize, sign: u8) Io.Writer.Error!void {
    st.last_shown = lno;
    if (st.fmt.pathname) {
        try st.w.writeAll(st.name);
        try outputSep(st, sign);
    }
    if (st.fmt.line_number) {
        try st.w.print("{d}", .{lno});
        try outputSep(st, sign);
    }
    if (st.fmt.column and cno != 0) {
        try st.w.print("{d}", .{cno});
        try outputSep(st, sign);
    }
}

fn showLine(st: *FileState, line: []const u8, lno: usize, cno_in: usize, sign: u8) SearchError!void {
    const context = st.fmt.before != 0 or st.fmt.after != 0 or st.fmt.funcbody;
    if (context) {
        if (st.last_shown == 0) {
            // every file's first hunk is marked; the writer drops the very
            // first mark, as git's threaded output does
            try st.w.writeAll("--\n");
        } else if (lno > st.last_shown + 1) {
            try st.w.writeAll("--\n");
        }
    }
    var cno = cno_in;
    if (!st.fmt.only_matching) try showLineHeader(st, lno, cno, sign);
    if (st.fmt.only_matching) {
        var bol: usize = 0;
        var not_bol = false;
        while (try nextMatch(st.s, st.sc, line[bol..], not_bol)) |m| {
            if (m.start == m.end) break;
            cno = bol + m.start + 1;
            try showLineHeader(st, lno, cno, sign);
            try st.w.writeAll(line[bol + m.start .. bol + m.end]);
            try st.w.writeByte('\n');
            bol += m.end;
            not_bol = true;
        }
        return;
    }
    try st.w.writeAll(line);
    try st.w.writeByte('\n');
}

fn showName(st: *FileState) Io.Writer.Error!void {
    try st.w.writeAll(st.name);
    try st.w.writeByte(if (st.fmt.null_sep) 0 else '\n');
}

/// git's `show_funcname_line`: the nearest function line above the one
/// starting at `bol`, unless it was shown already.
fn showFuncnameLine(st: *FileState, bol_in: usize, lno_in: usize) SearchError!void {
    var bol = bol_in;
    var lno = lno_in;
    while (bol > 0) {
        const eol = bol - 1;
        bol = startOfLineBefore(st.content, bol);
        lno -= 1;
        if (lno <= st.last_shown) break;
        if (try st.isFunction(st.line(bol, eol))) {
            try showLine(st, st.line(bol, eol), lno, 0, '=');
            break;
        }
    }
}

/// git's `show_pre_context`: the lines before a hit at `lno`, back to the
/// context asked for, the function line for `-p`, or for `-W` the start
/// of the function with the comment above it.
fn showPreContext(st: *FileState, bol_in: usize, eol_in: usize, lno: usize) SearchError!void {
    const fmt = st.fmt;
    var bol = bol_in;
    var cur = lno;
    var from: usize = 1;
    var funcname_lno: usize = 0;
    var funcname_needed = fmt.funcname;
    var comment_needed = false;
    if (fmt.before < lno) from = lno - fmt.before;
    if (from <= st.last_shown) from = st.last_shown + 1;
    const orig_from = from;
    if (fmt.funcbody) {
        if (try st.isFunction(st.line(bol, eol_in))) comment_needed = true else funcname_needed = true;
        from = st.last_shown + 1;
    }
    // rewind
    while (bol > 0 and cur > from) {
        const next_bol = bol;
        const eol = bol - 1;
        bol = startOfLineBefore(st.content, bol);
        cur -= 1;
        if (comment_needed and (isEmptyLine(st.line(bol, eol)) or try st.isFunction(st.line(bol, eol)))) {
            comment_needed = false;
            from = orig_from;
            if (cur < from) {
                cur += 1;
                bol = next_bol;
                break;
            }
        }
        if (funcname_needed and try st.isFunction(st.line(bol, eol))) {
            funcname_lno = cur;
            funcname_needed = false;
            if (fmt.funcbody) comment_needed = true else from = orig_from;
        }
    }
    // the function line may be further back still
    if (fmt.funcname and funcname_needed) try showFuncnameLine(st, bol, cur);
    // and forward again
    while (cur < lno) {
        const eol = endOfLine(st.content, bol);
        try showLine(st, st.line(bol, eol), cur, 0, if (cur == funcname_lno) '=' else '-');
        bol = eol + 1;
        cur += 1;
    }
}

/// Whether the function a `-W` hit is in ends before the line from `bol`
/// to `eol`: trailing empty lines belong to it only when no function line
/// follows them. `at` is the first line that is not empty.
fn peekFunction(st: *FileState, bol: usize, eol: usize) MatchError!struct { ends: bool, at: usize } {
    var pb = bol;
    var pe = eol;
    while (isEmptyLine(st.line(pb, pe))) {
        if (pe >= st.content.len) return .{ .ends = true, .at = st.content.len };
        pb = pe + 1;
        pe = endOfLine(st.content, pb);
    }
    return .{ .ends = pb >= st.content.len or try st.isFunction(st.line(pb, pe)), .at = pb };
}

/// git's `grep_source_1` over one file's bytes. Returns whether it hit.
fn searchFile(s: *const Searcher, sc: *Scratch, fmt: *const Format, item: *const Item, content: []const u8, is_binary: bool, w: *Io.Writer) SearchError!bool {
    var st: FileState = .{ .w = w, .fmt = fmt, .s = s, .sc = sc, .name = item.name, .content = content, .rule = item.rule };
    var binary_match_only = false;
    switch (fmt.binary) {
        .match => if (is_binary) {
            binary_match_only = true;
        },
        .skip => if (is_binary) return false,
        .text => {},
    }
    if (s.all_match and !try collectHits(s, sc, content)) return false;
    var lno: usize = 1;
    var last_hit: usize = 0;
    var count: usize = 0;
    var bol: usize = 0;
    var show_function = false;
    // where the look past a function's trailing empty lines got to
    var peek_bol: ?usize = null;
    while (bol < content.len) {
        const eol = endOfLine(content, bol);
        const line = content[bol..eol];
        var col: ?usize = null;
        var icol: ?usize = null;
        var hit = try evalExpr(s, sc, s.expr, line, &col, &icol);
        if (s.invert) hit = !hit;
        if (fmt.show == .files_without_match) {
            if (hit) return false;
        } else if (hit and (fmt.max_count == null or count < fmt.max_count.?)) {
            count += 1;
            if (fmt.show == .quiet) return true;
            if (fmt.show == .files_with_matches) {
                try showName(&st);
                return true;
            }
            if (fmt.show != .count) {
                if (binary_match_only) {
                    try w.print("Binary file {s} matches\n", .{item.name});
                    return true;
                }
                if (fmt.before > 0 or fmt.funcbody) {
                    try showPreContext(&st, bol, eol, lno);
                } else if (fmt.funcname) try showFuncnameLine(&st, bol, lno);
                const cno = if (s.invert) icol else col;
                try showLine(&st, line, lno, if (cno) |c| c + 1 else 1, ':');
                last_hit = lno;
                if (fmt.funcbody) show_function = true;
            }
        } else if (fmt.show == .lines) {
            if (show_function and (peek_bol == null or peek_bol.? < bol)) {
                const peek = try peekFunction(&st, bol, eol);
                peek_bol = peek.at;
                if (peek.ends) show_function = false;
            }
            if (show_function or (last_hit != 0 and lno <= last_hit + fmt.after)) {
                try showLine(&st, line, lno, if (col) |c| c + 1 else 0, '-');
            }
        }
        if (eol >= content.len) break;
        bol = eol + 1;
        lno += 1;
    }
    if (fmt.show == .quiet) return false;
    if (fmt.show == .files_without_match) {
        try showName(&st);
        return true;
    }
    if (fmt.show == .count and count > 0) {
        if (fmt.pathname) {
            try w.writeAll(item.name);
            try outputSep(&st, ':');
        }
        try w.print("{d}\n", .{count});
        return true;
    }
    return last_hit != 0;
}

//=========================================================================
// The files
//=========================================================================

const Item = struct {
    /// What the output calls it.
    name: []const u8,
    /// The path in the repository, for attributes.
    path: []const u8,
    source: union(enum) { file, blob: Oid },
    /// What the `diff` attribute says of it being binary, if anything.
    binary: ?bool = null,
    /// How its function lines are found, under `-p` or `-W`.
    rule: ?*const userdiff.Rule = null,
};

fn collectIndex(a: Allocator, io: Io, repo: *Repository, spec: *const pathspec_mod.Pathspec, cached: bool, items: *std.ArrayList(Item)) Error!void {
    var index = try repo.openIndex(io);
    defer index.deinit();
    const entries = index.items();
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        const e = entries[i];
        if (!cached and e.skip_worktree) continue;
        if ((e.mode == .file or e.mode == .exec) and spec.matches(e.path)) {
            const path = try a.dupe(u8, e.path);
            if (cached or e.assume_valid) {
                if (e.stage == 0 and !e.intent_to_add) try items.append(a, .{ .name = path, .path = path, .source = .{ .blob = e.oid } });
            } else try items.append(a, .{ .name = path, .path = path, .source = .file });
        }
        if (e.stage != 0) {
            while (i + 1 < entries.len and std.mem.eql(u8, entries[i + 1].path, e.path)) i += 1;
        }
    }
}

fn collectTree(a: Allocator, io: Io, repo: *Repository, spec: *const pathspec_mod.Pathspec, tree_oid: Oid, prefix: []const u8, name_prefix: []const u8, items: *std.ArrayList(Item), depth: u32) Error!void {
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    const db = repo.objectDatabase();
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const tree = object.Tree.parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0) try a.dupe(u8, entry.name) else try a.print("{s}/{s}", .{ prefix, entry.name });
        switch (entry.mode) {
            .file, .exec => if (spec.matches(path)) {
                const name = try std.mem.concat(a, u8, &.{ name_prefix, path });
                try items.append(a, .{ .name = name, .path = path, .source = .{ .blob = entry.oid } });
            },
            .tree => if (spec.couldMatchUnder(path)) try collectTree(a, io, repo, spec, entry.oid, path, name_prefix, items, depth + 1),
            else => {},
        }
    }
}

fn peelToTree(io: Io, repo: *Repository, oid: Oid) Error!Oid {
    var current = oid;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const header = try repo.objectDatabase().readHeader(io, current);
        switch (header.type) {
            .tree => return current,
            .commit => return repo.commitTree(io, current),
            .tag => {
                const found = try repo.objectDatabase().read(io, current);
                defer repo.objectDatabase().allocator().free(found.bytes);
                var tag = object.Tag.parse(repo.allocator(), repo.objectFormat(), found.bytes) catch return error.NotATree;
                defer tag.deinit();
                current = tag.target;
            },
            else => return error.NotATree,
        }
    }
    return error.NotATree;
}

fn isBinaryContent(bytes: []const u8) bool {
    const n = @min(bytes.len, 8000);
    return std.mem.findScalar(u8, bytes[0..n], 0) != null;
}

/// What the attributes say of each item: binary or not by `diff`, and
/// under `-p` or `-W` the driver `diff` names, whose rules are compiled
/// once each into `rules`.
fn applyAttributes(a: Allocator, gpa: Allocator, io: Io, repo: *Repository, attrs: ?*attributes.Attrs, items: []Item, functions: bool, rules: *std.array_hash_map.String(*userdiff.Rule)) Error!void {
    const config = repo.configuration();
    for (items) |*item| {
        var driver: ?[]const u8 = null;
        if (attrs) |at| {
            if (repo.workDirectory()) |w| try at.enter(io, w, item.path);
            const applied = try at.lookup(a, item.path, false);
            if (applied.get("diff")) |state| switch (state) {
                .unset => item.binary = true,
                .set => item.binary = false,
                .value => |v| driver = v,
                .unspecified => {},
            };
        }
        if (!functions) continue;
        // a name no driver has, and none at all, are git's default
        const key = driver orelse "";
        item.rule = rules.get(key) orelse blk: {
            const rule = try a.create(userdiff.Rule);
            rule.* = try userdiff.Rule.init(gpa, config, driver);
            errdefer rule.deinit();
            try rules.put(a, try a.dupe(u8, key), rule);
            break :blk rule;
        };
    }
}
//=========================================================================
// Running
//=========================================================================

const Work = struct {
    searcher: *const Searcher,
    fmt: *const Format,
    items: []const Item,
    contents: []?[]const u8,
    binaries: []bool,
    /// Each item's output, in its task's buffer, or `null` when it did
    /// not fit and is redone on the calling task.
    outputs: []?[]const u8,
    hits: []bool,
    buffers: [][]u8,
    used: []usize,
    scratch: []Scratch,
    next: std.atomic.Value(usize) = .init(0),
};

fn runWorker(work: *Work, worker: usize) void {
    while (true) {
        const i = work.next.fetchAdd(1, .monotonic);
        if (i >= work.items.len) return;
        const content = work.contents[i] orelse continue;
        const buf = work.buffers[worker];
        var w: Io.Writer = .fixed(buf[work.used[worker]..]);
        const hit = searchFile(work.searcher, &work.scratch[worker], work.fmt, &work.items[i], content, work.binaries[i], &w) catch {
            work.outputs[i] = null;
            continue;
        };
        const n = w.buffered().len;
        work.outputs[i] = buf[work.used[worker]..][0..n];
        work.used[worker] += n;
        work.hits[i] = hit;
    }
}

fn taskCount(threads: u16) usize {
    if (builtin.single_threaded) return 1;
    if (threads != 0) return threads;
    return std.Thread.getCpuCount() catch 1;
}

/// The bytes the tasks may hold of files and of output at once.
const batch_bytes: usize = 16 << 20;
const task_output_bytes: usize = 1 << 20;

/// The pattern syntax asked for, else the one `grep.patternType` (or the
/// older `grep.extendedRegexp`) names, else basic.
fn patternSyntax(repo: *Repository, options: Options) Syntax {
    if (options.syntax) |syntax| return syntax;
    const config = repo.configuration();
    var syntax: Syntax = .basic;
    if (config.getBool("grep.extendedregexp", false) catch false) syntax = .extended;
    if (config.get("grep.patterntype")) |v| {
        if (std.mem.eql(u8, v, "basic")) syntax = .basic else if (std.mem.eql(u8, v, "extended")) syntax = .extended else if (std.mem.eql(u8, v, "fixed")) syntax = .fixed else if (std.mem.eql(u8, v, "perl")) syntax = .perl;
    }
    return syntax;
}

/// The files `source` names under `spec`, in the order git searches them.
fn collect(a: Allocator, io: Io, repo: *Repository, spec: *const pathspec_mod.Pathspec, source: Source, items: *std.ArrayList(Item)) Error!void {
    switch (source) {
        .worktree => {
            if (repo.workDirectory() == null) return error.BareRepository;
            try collectIndex(a, io, repo, spec, false, items);
        },
        .index => try collectIndex(a, io, repo, spec, true, items),
        .tree => |t| {
            const tree = try peelToTree(io, repo, t.oid);
            const prefix = if (t.name.len == 0) "" else try std.mem.concat(a, u8, &.{ t.name, ":" });
            try collectTree(a, io, repo, spec, tree, "", prefix, items, 0);
        },
    }
}

/// One batch of files read for the tasks: as many as fit the byte budget,
/// each with its bytes (`null` for a file that could not be read) and
/// whether it is binary.
const Batch = struct {
    contents: std.ArrayList(?[]const u8) = .empty,
    binaries: std.ArrayList(bool) = .empty,
    /// The bytes read, the object database allocator's to free.
    owned: std.ArrayList([]u8) = .empty,

    /// Read the files from `start` on until the budget is spent, at least
    /// one; returns where the batch ends.
    fn load(batch: *Batch, a: Allocator, gpa: Allocator, io: Io, repo: *Repository, items: []const Item, start: usize) Error!usize {
        var end = start;
        var bytes: usize = 0;
        while (end < items.len and (end == start or bytes < batch_bytes)) : (end += 1) {
            const item = items[end];
            const content: ?[]u8 = switch (item.source) {
                .blob => |oid| blk: {
                    const found = try repo.objectDatabase().read(io, oid);
                    break :blk found.bytes;
                },
                .file => (fs.readFileAlloc(repo.objectDatabase().allocator(), io, repo.workDirectory().?, item.path, 1 << 31) catch null) orelse null,
            };
            if (content) |c| {
                try batch.owned.append(gpa, c);
                bytes += c.len;
            }
            try batch.contents.append(a, content);
            var bin = false;
            if (content) |c| {
                bin = item.binary orelse isBinaryContent(c);
            }
            try batch.binaries.append(a, bin);
        }
        // The tasks index both by a file's place in the batch.
        assert(end > start);
        assert(batch.contents.items.len == end - start);
        assert(batch.binaries.items.len == end - start);
        return end;
    }

    fn deinit(batch: *Batch, gpa: Allocator, repo: *Repository) void {
        for (batch.owned.items) |b| repo.objectDatabase().allocator().free(b);
        batch.owned.deinit(gpa);
        batch.* = undefined;
    }
};

/// `git grep`: write to `w` what git writes, and say whether anything
/// matched.
pub fn grep(gpa: Allocator, io: Io, repo: *Repository, options: Options, w: *Io.Writer) Self.Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();
    const config = repo.configuration();

    const column = options.column orelse (config.getBool("grep.column", false) catch false);
    var searcher = try compile(a, gpa, options, patternSyntax(repo, options), column);
    defer searcher.deinit();
    const fmt: Format = .{
        .show = options.show,
        .line_number = options.line_number orelse (config.getBool("grep.linenumber", false) catch false),
        .column = column,
        .only_matching = options.only_matching,
        .pathname = options.with_filename,
        .before = options.before,
        .after = options.after,
        .funcname = options.show_function,
        .funcbody = options.function_context,
        .max_count = options.max_count,
        .null_sep = options.null_separator,
        .binary = options.binary,
    };

    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();
    var items: std.ArrayList(Item) = .empty;
    try collect(a, io, repo, &spec, options.source, &items);

    var attrs: ?attributes.Attrs = null;
    defer if (attrs) |*x| x.deinit();
    if (repo.workDirectory() != null) attrs = try repo.loadAttrs(io);
    defer if (attrs) |*x| x.leave();
    var rules: std.array_hash_map.String(*userdiff.Rule) = .empty;
    defer for (rules.values()) |rule| rule.deinit();
    const functions = fmt.funcname or fmt.funcbody;
    try applyAttributes(a, gpa, io, repo, if (attrs) |*x| x else null, items.items, functions, &rules);
    var func_program: usize = 0;
    for (rules.values()) |rule| func_program = @max(func_program, rule.programLen());

    const workers = @max(1, @min(taskCount(options.threads), items.items.len));
    const scratch = try a.alloc(Scratch, workers);
    var made: usize = 0;
    defer for (scratch[0..made]) |*sc| sc.deinit(gpa);
    for (scratch) |*sc| {
        sc.* = try Scratch.init(gpa, &searcher, func_program);
        made += 1;
    }
    const buffers = try a.alloc([]u8, workers);
    for (buffers) |*b| b.* = try a.alloc(u8, task_output_bytes);

    var matched = false;
    var first_mark = fmt.before != 0 or fmt.after != 0 or fmt.funcbody;
    var start: usize = 0;
    while (start < items.items.len) {
        var batch: Batch = .{};
        defer batch.deinit(gpa, repo);
        const end = try batch.load(a, gpa, io, repo, items.items, start);
        const n = end - start;
        const outputs = try a.alloc(?[]const u8, n);
        @memset(outputs, null);
        const hits = try a.alloc(bool, n);
        @memset(hits, false);
        const used = try a.alloc(usize, workers);
        @memset(used, 0);
        var work: Work = .{
            .searcher = &searcher,
            .fmt = &fmt,
            .items = items.items[start..end],
            .contents = batch.contents.items,
            .binaries = batch.binaries.items,
            .outputs = outputs,
            .hits = hits,
            .buffers = buffers,
            .used = used,
            .scratch = scratch,
        };
        var group: Io.Group = .init;
        for (1..@min(workers, n)) |t| group.async(io, runWorker, .{ &work, t });
        runWorker(&work, 0);
        group.await(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        // in order; what did not fit a task's buffer is searched again here
        for (0..n) |i| {
            const content = work.contents[i] orelse continue;
            var out: []const u8 = undefined;
            var redo: Io.Writer.Allocating = .init(a);
            if (work.outputs[i]) |o| {
                out = o;
            } else {
                work.hits[i] = try searchFile(&searcher, &scratch[0], &fmt, &work.items[i], content, work.binaries[i], &redo.writer);
                out = redo.written();
            }
            if (work.hits[i]) matched = true;
            if (out.len == 0) continue;
            if (first_mark and std.mem.startsWith(u8, out, "--\n")) {
                out = out[3..];
            }
            first_mark = false;
            if (fmt.show != .quiet) try w.writeAll(out);
        }
        if (matched and fmt.show == .quiet) break;
        start = end;
    }
    return .{ .matched = matched, .files = items.items.len };
}

test "the leftmost match decides a word match as git's retry does" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s = try compile(arena.allocator(), gpa, .{ .patterns = &.{"foo"}, .word = true }, .basic, false);
    defer s.deinit();
    var sc = try Scratch.init(gpa, &s, 0);
    defer sc.deinit(gpa);
    var col: ?usize = null;
    var icol: ?usize = null;
    try std.testing.expect(try evalExpr(&s, &sc, s.expr, "foobar foo", &col, &icol));
    try std.testing.expect(!try evalExpr(&s, &sc, s.expr, "foobar xfoo", &col, &icol));
}
