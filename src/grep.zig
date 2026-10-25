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
//! refused by name, as is `--no-index`. Under `--recurse-submodules` each
//! active submodule is searched in its gitlink's place.

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
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
const fs = @import("fs/fs.zig");
const driver_mod = @import("diff/driver.zig");
const textconv_mod = @import("diff/textconv.zig");
const color = @import("config/color.zig");
const config_mod = @import("config/config.zig");
const gitmodules_mod = @import("config/gitmodules.zig");
const submodule_mod = @import("submodule/submodule.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a grep.
pub const Error = error{
    /// A `diff.<name>.binary` that is neither a boolean nor `auto`, which
    /// git dies on.
    InvalidDriverBinary,
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
    /// The tree nests deeper than `core.maxTreeDepth`.
    TreeTooDeep,
} || pathspec_mod.Error || index_mod.ReadError || repo_mod.Error || attributes.Error || Io.Writer.Error ||
    odb_mod.Error || object.TreeParseError || textconv_mod.Error || driver_mod.Error || submodule_mod.Error;

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
    /// `--textconv`: a file whose driver has a `textconv` is searched as
    /// the program's text, which is never binary. `null`, git's default,
    /// searches the bytes.
    textconv: ?*const textconv_mod.Textconv = null,
    pathspecs: []const []const u8 = &.{},
    source: Source = .worktree,
    /// Tasks to search on: zero is one per processor.
    threads: u16 = 0,
    /// The colours the output is written in, `null` for none:
    /// `Colors.configured` gives git's.
    colors: ?*const Colors = null,
    /// `--recurse-submodules`: each active submodule the pathspecs reach
    /// is searched too, in its gitlink's place, its files named from the
    /// top -- from its index and working tree, or, in a tree, at the
    /// commit its gitlink records, its repository found in `modules` when
    /// it is not checked out. `null` reads `submodule.recurse`.
    recurse_submodules: ?bool = null,
};

/// `git grep`'s colours: git's defaults under `color.grep.<slot>`.
pub const Colors = struct {
    context: color.Color = .none,
    filename: color.Color = color.magenta,
    function: color.Color = .none,
    line_number: color.Color = color.green,
    column: color.Color = color.green,
    match_context: color.Color = color.bold_red,
    match_selected: color.Color = color.bold_red,
    selected: color.Color = .none,
    separator: color.Color = color.cyan,

    /// git's `color_grep_slots`, and `match` for both match slots.
    const names = [_]struct { []const u8, std.meta.FieldEnum(Colors) }{
        .{ "context", .context },              .{ "filename", .filename },    .{ "function", .function },
        .{ "lineNumber", .line_number },       .{ "column", .column },        .{ "matchContext", .match_context },
        .{ "matchSelected", .match_selected }, .{ "selected", .selected },    .{ "separator", .separator },
        .{ "match", .match_context },          .{ "match", .match_selected },
    };

    /// git's defaults under what `color.grep.<slot>` sets, read in order
    /// as git's `grep_config` reads them: a slot grep does not have is
    /// refused, where git dies.
    pub fn read(config: *const config_mod.Config) color.Error!Colors {
        var out: Colors = .{};
        try color.readSlots(Colors, &out, config, &names, .{ .sections = &.{.{ .section = "color", .subsection = "grep" }}, .unknown = .refuse });
        return out;
    }

    /// The colours `output` asks for: `null` where git greps without
    /// colour, as `color.grep` and `color.ui` decide.
    pub fn configured(config: ?*const config_mod.Config, output: color.Output) color.Error!?Colors {
        if (!try color.wanted(config, &.{"color.grep"}, output)) return null;
        return if (config) |c| try read(c) else .{};
    }
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
    colors: ?*const Colors,

    /// What a context hunk is marked with: `--`, in `separator`.
    fn mark(fmt: *const Format, buf: []u8) []const u8 {
        const sep: []const u8 = if (fmt.colors) |c| c.separator.bytes() else "";
        if (sep.len == 0) return "--\n";
        // unreachable: the buffer holds the longest colour, the mark and a reset
        return std.mem.print(buf, "{s}--{s}\n", .{ sep, color.reset }) catch unreachable;
    }
};

/// The buffer `Format.mark` writes into.
const mark_max = color.max_len + "--".len + color.reset.len + 1;

const FileState = struct {
    w: *Io.Writer,
    fmt: *const Format,
    s: *const Searcher,
    sc: *Scratch,
    name: []const u8,
    content: []const u8,
    /// How function lines are found, under `-p` or `-W`.
    rule: ?*const driver_mod.Rule,
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

/// git's `output_color`: `text` in the colour of `slot`, where there are
/// colours and that one writes something.
fn outputColor(st: *FileState, text: []const u8, comptime slot: std.meta.FieldEnum(Colors)) Io.Writer.Error!void {
    const c: []const u8 = if (st.fmt.colors) |colors| @field(colors, @tagName(slot)).bytes() else "";
    if (c.len == 0) return st.w.writeAll(text);
    try st.w.print("{s}{s}{s}", .{ c, text, color.reset });
}

fn outputSep(st: *FileState, sign: u8) Io.Writer.Error!void {
    if (st.fmt.null_sep) try st.w.writeByte(0) else try outputColor(st, &.{sign}, .separator);
}

fn showLineHeader(st: *FileState, lno: usize, cno: usize, sign: u8) Io.Writer.Error!void {
    st.last_shown = lno;
    var buf: [32]u8 = undefined;
    if (st.fmt.pathname) {
        try outputColor(st, st.name, .filename);
        try outputSep(st, sign);
    }
    if (st.fmt.line_number) {
        // unreachable: a line number fits
        try outputColor(st, std.mem.print(&buf, "{d}", .{lno}) catch unreachable, .line_number);
        try outputSep(st, sign);
    }
    if (st.fmt.column and cno != 0) {
        // unreachable: a column fits
        try outputColor(st, std.mem.print(&buf, "{d}", .{cno}) catch unreachable, .column);
        try outputSep(st, sign);
    }
}

fn showLine(st: *FileState, line: []const u8, lno: usize, cno_in: usize, sign: u8) SearchError!void {
    const context = st.fmt.before != 0 or st.fmt.after != 0 or st.fmt.funcbody;
    if (context) {
        // every file's first hunk is marked; the writer drops the very
        // first mark, as git's threaded output does
        if (st.last_shown == 0 or lno > st.last_shown + 1) {
            var buf: [mark_max]u8 = undefined;
            try st.w.writeAll(st.fmt.mark(&buf));
        }
    }
    var cno = cno_in;
    if (!st.fmt.only_matching) try showLineHeader(st, lno, cno, sign);
    var bol: usize = 0;
    if (st.fmt.colors != null or st.fmt.only_matching) {
        // git's `show_line`: each match in its colour, the text between in
        // the line's
        var not_bol = false;
        while (try nextMatch(st.s, st.sc, line[bol..], not_bol)) |m| {
            if (m.start == m.end) break;
            cno = bol + m.start + 1;
            if (st.fmt.only_matching) {
                try showLineHeader(st, lno, cno, sign);
            } else try outputLinePart(st, line[bol..][0..m.start], sign);
            const match = line[bol + m.start .. bol + m.end];
            if (sign == ':') try outputColor(st, match, .match_selected) else try outputColor(st, match, .match_context);
            if (st.fmt.only_matching) try st.w.writeByte('\n');
            bol += m.end;
            not_bol = true;
        }
        if (st.fmt.only_matching) return;
    }
    try outputLinePart(st, line[bol..], sign);
    try st.w.writeByte('\n');
}

/// Text of a line outside its matches, in the colour of the line's kind:
/// `selected`, `context` or `function`.
fn outputLinePart(st: *FileState, text: []const u8, sign: u8) Io.Writer.Error!void {
    switch (sign) {
        ':' => try outputColor(st, text, .selected),
        '-' => try outputColor(st, text, .context),
        '=' => try outputColor(st, text, .function),
        else => try st.w.writeAll(text),
    }
}

fn showName(st: *FileState) Io.Writer.Error!void {
    try outputColor(st, st.name, .filename);
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
                    try w.writeAll("Binary file ");
                    try outputColor(&st, item.name, .filename);
                    try w.writeAll(" matches\n");
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
            try outputColor(&st, item.name, .filename);
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
    rule: ?*const driver_mod.Rule = null,
    /// Its driver's `textconv`, under `--textconv`.
    conversion: ?driver_mod.Conversion = null,
    /// The repository it is in, by its place in `Repos`.
    owner: u16 = 0,
};

/// The repositories a grep reads: the one asked first, then each
/// submodule it recurses into, with the attributes of each.
const Repos = struct {
    list: std.ArrayList(*Repository) = .empty,
    attrs: std.ArrayList(?attributes.Attrs) = .empty,

    /// Each repository's attributes, where it has a working tree.
    fn loadAttrs(r: *Repos, a: Allocator, io: Io) Error!void {
        for (r.list.items) |repo| {
            try r.attrs.append(a, if (repo.workDirectory() != null) try repo.loadAttrs(io) else null);
        }
    }

    fn deinit(r: *Repos, io: Io) void {
        for (r.attrs.items) |*maybe| if (maybe.*) |*x| {
            x.leave();
            x.deinit();
        };
        if (r.list.items.len > 1) for (r.list.items[1..]) |sub| sub.deinit(io);
    }
};

/// What gathers the files a grep searches, in the order git searches
/// them: a submodule's, under `--recurse-submodules`, in its gitlink's
/// place, named from the top.
const Collector = struct {
    a: Allocator,
    gpa: Allocator,
    io: Io,
    spec: *const pathspec_mod.Pathspec,
    recurse: bool,
    repos: *Repos,
    items: *std.ArrayList(Item),

    /// One repository's place: which it is, the path the names of its
    /// files start with, `/`-terminated, and how deep in submodules.
    const At = struct { owner: u16 = 0, prefix: []const u8 = "", depth: u32 = 0 };

    /// One tree's place in its repository: `base` its path, `name_prefix`
    /// what each name is printed after, `root` the repository's top tree,
    /// whose `.gitmodules` names its submodules.
    const TreeAt = struct { oid: Oid, base: []const u8 = "", name_prefix: []const u8, root: Oid, depth: u32 = 0 };

    /// The files `from` names, in the repository grepped.
    fn source(c: *const Collector, from: Source) Error!void {
        switch (from) {
            .worktree => {
                if (c.repos.list.items[0].workDirectory() == null) return error.BareRepository;
                try c.index(.{}, false);
            },
            .index => try c.index(.{}, true),
            .tree => |t| {
                const root = try peelToTree(c.io, c.repos.list.items[0], t.oid);
                const prefix = if (t.name.len == 0) "" else try std.mem.concat(c.a, u8, &.{ t.name, ":" });
                try c.tree(.{}, .{ .oid = root, .name_prefix = prefix, .root = root });
            },
        }
    }

    fn repo(c: *const Collector, at: At) *Repository {
        return c.repos.list.items[at.owner];
    }

    /// Whether the pathspecs reach the submodule an index has at `full`,
    /// or into it: git's `submodule_path_match`.
    fn reaches(c: *const Collector, full: []const u8) bool {
        return c.spec.matches(full) or c.spec.couldMatchUnder(full);
    }

    fn index(c: *const Collector, at: At, cached: bool) Error!void {
        var idx = try c.repo(at).openIndex(c.io);
        defer idx.deinit();
        var modules: ?gitmodules_mod.Gitmodules = null;
        defer if (modules) |*m| m.deinit();
        const entries = idx.items();
        var i: usize = 0;
        while (i < entries.len) : (i += 1) {
            const e = entries[i];
            if (!cached and e.skip_worktree) continue;
            const full = try std.mem.concat(c.a, u8, &.{ at.prefix, e.path });
            if ((e.mode == .file or e.mode == .exec) and c.spec.matches(full)) {
                const path = try c.a.dupe(u8, e.path);
                if (cached or e.assume_valid) {
                    if (e.stage == 0 and !e.intent_to_add) try c.items.append(c.a, .{ .name = full, .path = path, .source = .{ .blob = e.oid }, .owner = at.owner });
                } else try c.items.append(c.a, .{ .name = full, .path = path, .source = .file, .owner = at.owner });
            } else if (c.recurse and e.mode == .gitlink and c.reaches(full)) {
                if (modules == null) modules = try submodule_mod.loadGitmodules(c.gpa, c.io, c.repo(at), &idx);
                try c.submodule(at, &modules.?, .{ .path = e.path, .full = full }, .{ .cached = cached });
            }
            if (e.stage != 0) {
                while (i + 1 < entries.len and std.mem.eql(u8, entries[i + 1].path, e.path)) i += 1;
            }
        }
    }

    fn tree(c: *const Collector, at: At, t: TreeAt) Error!void {
        const r = c.repo(at);
        if (t.depth > r.settings().max_tree_depth) return error.TreeTooDeep;
        const db = r.objectDatabase();
        const found = try db.read(c.io, t.oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .tree) return error.NotATree;
        const parsed = object.Tree.parse(db.objectFormat(), found.bytes);
        var it = parsed.iterate();
        while (try it.next()) |entry| {
            const path = if (t.base.len == 0) try c.a.dupe(u8, entry.name) else try c.a.print("{s}/{s}", .{ t.base, entry.name });
            const full = try std.mem.concat(c.a, u8, &.{ at.prefix, path });
            switch (entry.mode) {
                .file, .exec => if (c.spec.matches(full)) {
                    const name = try std.mem.concat(c.a, u8, &.{ t.name_prefix, full });
                    try c.items.append(c.a, .{ .name = name, .path = path, .source = .{ .blob = entry.oid }, .owner = at.owner });
                },
                .tree => if (c.spec.couldMatchUnder(full)) {
                    var inner = t;
                    inner.oid = entry.oid;
                    inner.base = path;
                    inner.depth += 1;
                    try c.tree(at, inner);
                },
                // git's `tree_entry_interesting` takes a gitlink only where
                // a pathspec matches it, not one that names a path in it.
                .gitlink => if (c.recurse and c.spec.matches(full)) {
                    var modules = try submodule_mod.gitmodulesOfTree(c.gpa, c.io, r, t.root);
                    defer modules.deinit();
                    try c.submodule(at, &modules, .{ .path = path, .full = full }, .{ .commit = entry.oid, .name_prefix = t.name_prefix });
                },
                else => {},
            }
        }
    }

    const Gitlink = struct { path: []const u8, full: []const u8 };
    const Into = struct { commit: ?Oid = null, cached: bool = false, name_prefix: []const u8 = "" };

    /// git's `grep_submodule`: an active submodule's files, from its index
    /// and working tree, or under a tree from the commit its gitlink
    /// records. One whose repository is nowhere is passed over.
    fn submodule(c: *const Collector, at: At, modules: *const gitmodules_mod.Gitmodules, link: Gitlink, into: Into) Error!void {
        if (at.depth >= submodule_mod.max_depth) return error.NestingTooDeep;
        const r = c.repo(at);
        const module = modules.byPath(link.path) orelse return;
        if (!try submodule_mod.isActive(c.a, r, module.name, link.path)) return;
        const opened = (try submodule_mod.openRepository(c.gpa, c.io, r, .{ .path = link.path, .name = module.name }, .{})) orelse return;
        const sub = try c.a.create(Repository);
        sub.* = opened;
        try c.repos.list.append(c.a, sub);
        const inner: At = .{
            .owner = @intCast(c.repos.list.items.len - 1),
            .prefix = try std.mem.concat(c.a, u8, &.{ link.full, "/" }),
            .depth = at.depth + 1,
        };
        if (into.commit) |commit| {
            const root = try peelToTree(c.io, sub, commit);
            return c.tree(inner, .{ .oid = root, .name_prefix = into.name_prefix, .root = root });
        }
        return c.index(inner, into.cached);
    }
};

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

/// What the attributes say of each item: binary or not by `diff`, and
/// under `-p` or `-W` the driver `diff` names, whose rules are compiled
/// once each into `rules`.
/// What the drivers are asked for besides whether a file is binary.
const Wanted = struct { functions: bool, conversions: bool };

fn applyAttributes(a: Allocator, gpa: Allocator, io: Io, repos: *Repos, items: []Item, wanted: Wanted, rules: *std.array_hash_map.String(*driver_mod.Rule)) Error!void {
    const config = repos.list.items[0].configuration();
    for (items) |*item| {
        var state: ?attributes.State = null;
        const repo = repos.list.items[item.owner];
        if (repos.attrs.items[item.owner]) |*at| {
            if (repo.workDirectory()) |w| try at.enter(io, w.get(), item.path);
            state = (try at.lookup(a, item.path, .file)).get("diff");
        }
        const driver = driver_mod.Driver.of(config, state);
        item.binary = try driver.says(config);
        if (wanted.conversions) item.conversion = try driver.conversion(config);
        if (!wanted.functions) continue;
        const key = driver.name() orelse "";
        item.rule = rules.get(key) orelse blk: {
            const rule = try a.create(driver_mod.Rule);
            rule.* = try driver_mod.Rule.init(gpa, config, driver.name());
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
    /// How many items the workers have claimed: each takes the next by
    /// its index until none is left.
    next: Claimed = Claimed.init(Claims.fromRaw(0)),

    const Claims = aegis.units.Count(Item, usize);
    const Claimed = aegis.Atomic(Claims);
};

/// Search files until none is left; a step is one file, held in memory
/// already, so the check is explicit.
fn runWorker(work: *Work, io: Io, worker: usize) Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        const i = work.next.fetchAddWrapping(Work.Claims.fromRaw(1), .monotonic).raw();
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

/// `tasks` workers over the batch, the first on the calling task. A
/// cancellation that stops the first cancels the others before it returns;
/// one that reaches the group while the first works ends the group's wait.
fn searchAll(work: *Work, io: Io, tasks: usize) Io.Cancelable!void {
    var group: Io.Group = .init;
    for (1..tasks) |t| group.async(io, runWorker, .{ work, io, t });
    runWorker(work, io, 0) catch |err| {
        group.cancel(io);
        return err;
    };
    try group.await(io);
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

/// One batch of files read for the tasks: as many as fit the byte budget,
/// each with its bytes (`null` for a file that could not be read) and
/// whether it is binary.
const Batch = struct {
    /// Where a batch starts, and what converts its files.
    const Place = struct { start: usize, textconv: ?*const textconv_mod.Textconv };

    contents: std.ArrayList(?[]const u8) = .empty,
    binaries: std.ArrayList(bool) = .empty,
    /// The bytes read, each the allocator's of the object database of the
    /// repository it came from.
    owned: std.ArrayList(struct { bytes: []u8, owner: u16 }) = .empty,

    /// Read the files from `start` on until the budget is spent, at least
    /// one; returns where the batch ends.
    fn load(batch: *Batch, a: Allocator, gpa: Allocator, io: Io, repos: *const Repos, items: []const Item, at: Place) Error!usize {
        const start = at.start;
        var end = start;
        var bytes: usize = 0;
        while (end < items.len and (end == start or bytes < batch_bytes)) : (end += 1) {
            const item = items[end];
            const repo = repos.list.items[item.owner];
            const content: ?[]u8 = switch (item.source) {
                .blob => |oid| blk: {
                    const found = try repo.objectDatabase().read(io, oid);
                    break :blk found.bytes;
                },
                .file => (fs.readFileAlloc(repo.objectDatabase().allocator(), io, repo.workDirectory().?.get(), item.path, 1 << 31) catch null) orelse null,
            };
            if (content) |c| {
                try batch.owned.append(gpa, .{ .bytes = c, .owner = item.owner });
                bytes += c.len;
            }
            var searched: ?[]const u8 = content;
            var bin = false;
            if (content) |c| {
                bin = item.binary orelse attributes.isBinaryForDiff(c);
                // `fill_textconv_grep`: the driver's text, which is text.
                if (at.textconv) |tc| if (item.conversion) |conversion| {
                    const blob: ?Oid = switch (item.source) {
                        .blob => |oid| oid,
                        .file => null,
                    };
                    searched = try tc.convert(a, io, .{ .conversion = conversion, .path = item.path, .blob = blob, .bytes = c });
                    bin = false;
                };
            }
            try batch.contents.append(a, searched);
            try batch.binaries.append(a, bin);
        }
        // The tasks index both by a file's place in the batch.
        assert(end > start);
        assert(batch.contents.items.len == end - start);
        assert(batch.binaries.items.len == end - start);
        return end;
    }

    fn deinit(batch: *Batch, gpa: Allocator, repos: *const Repos) void {
        for (batch.owned.items) |b| repos.list.items[b.owner].objectDatabase().allocator().free(b.bytes);
        batch.owned.deinit(gpa);
        batch.* = undefined;
    }
};

/// `git grep`: write to `w` what git writes, and say whether anything
/// matched.
pub fn grep(gpa: Allocator, io: Io, w: *Io.Writer, repo: *Repository, options: Options) Self.Error!Outcome {
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
        .colors = options.colors,
    };

    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();
    var items: std.ArrayList(Item) = .empty;
    var repos: Repos = .{};
    defer repos.deinit(io);
    try repos.list.append(a, repo);
    var collector: Collector = .{
        .a = a,
        .gpa = gpa,
        .io = io,
        .spec = &spec,
        .recurse = options.recurse_submodules orelse (config.getBool("submodule.recurse", false) catch false),
        .repos = &repos,
        .items = &items,
    };
    try collector.source(options.source);

    try repos.loadAttrs(a, io);
    var rules: std.array_hash_map.String(*driver_mod.Rule) = .empty;
    defer for (rules.values()) |rule| rule.deinit();
    const functions = fmt.funcname or fmt.funcbody;
    try applyAttributes(a, gpa, io, &repos, items.items, .{ .functions = functions, .conversions = options.textconv != null }, &rules);
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
        defer batch.deinit(gpa, &repos);
        const end = try batch.load(a, gpa, io, &repos, items.items, .{ .start = start, .textconv = options.textconv });
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
        try searchAll(&work, io, @min(workers, n));
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
            var mark_buf: [mark_max]u8 = undefined;
            const mark = fmt.mark(&mark_buf);
            if (first_mark and std.mem.startsWith(u8, out, mark)) {
                out = out[mark.len..];
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
