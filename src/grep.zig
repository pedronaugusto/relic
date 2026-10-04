//! `git grep`: lines matching patterns in the tracked files of the working
//! tree, in the index, or in a tree or commit, written as git writes them.
//!
//! Patterns are fixed strings, POSIX basic expressions (git's default) or
//! extended ones (`ere.zig`), any of several matching, with `-i`, `-w` and
//! `-v` as git applies them: `-w` retries past a match that is not a whole
//! word, exactly where git's does. A file is binary by its `diff` and
//! `binary` attributes, else by a NUL in its first 8000 bytes, and is then
//! reported as `Binary file <name> matches`. Output is git's to the byte:
//! names, `-n` and `--column` numbers, `-A`/`-B`/`-C` context with `--`
//! between hunks, `-o`, `-c`, `-l`, `-L`, `-z`. The files are searched on
//! tasks of the caller's `std.Io`, and written in path order.
//!
//! What git does that this refuses by name: `-P` (PCRE),
//! back-references, `-p`/`-W` (function context), `--and`/`--or`/`--not`
//! expressions, submodule recursion and `--no-index`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const index_mod = @import("index.zig");
const attributes = @import("worktree/attributes.zig");
const ere = @import("ere.zig");
const pathspec_mod = @import("pathspec.zig");
const fs = @import("repo/fs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a grep.
pub const Error = error{
    /// `-P`: Perl-compatible expressions, which git builds with PCRE and
    /// this does not have.
    UnsupportedPerlRegex,
    /// A pattern that does not compile.
    InvalidPattern,
    /// A pattern whose program would be too large.
    PatternTooComplex,
    /// A back-reference, `\1`, which this matcher does not support.
    UnsupportedBackreference,
    /// No pattern was given.
    NoPattern,
    /// A pattern with a NUL in it, which git takes only under `-P`.
    NulInPattern,
    /// The working tree was asked of a bare repository.
    BareRepository,
    /// The object to search is not a commit or a tree.
    NotATree,
} || pathspec_mod.Error || index_mod.ReadError || repo_mod.Error || attributes.Error || Io.Writer.Error ||
    @import("odb.zig").Error || object.TreeParseError;

/// How patterns are read: `-G`, `-E`, `-F`, `-P`.
pub const Syntax = enum { basic, extended, fixed, perl };

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
    patterns: []const []const u8,
    /// `null` reads `grep.patternType` and `grep.extendedRegexp`, and is
    /// basic without them.
    syntax: ?Syntax = null,
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
    kind: union(enum) { fixed: []const u8, regex: ere.Regex },
};

const Searcher = struct {
    pats: []Pat,
    icase: bool,
    word: bool,
    invert: bool,

    fn deinit(s: *Searcher) void {
        for (s.pats) |*p| switch (p.kind) {
            .regex => |*r| r.deinit(),
            .fixed => {},
        };
    }
};

fn isRegexSpecial(c: u8) bool {
    return switch (c) {
        '*', '?', '[', '\\', '$', '(', ')', '+', '.', '^', '{', '|' => true,
        else => false,
    };
}

fn compile(a: Allocator, gpa: Allocator, options: Options, syntax: Syntax) Error!Searcher {
    if (options.patterns.len == 0) return error.NoPattern;
    if (syntax == .perl) return error.UnsupportedPerlRegex;
    var pats: std.ArrayList(Pat) = .empty;
    for (options.patterns) |text| {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NulInPattern;
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
                error.UnsupportedBackreference => return error.UnsupportedBackreference,
                error.OutOfMemory => return error.OutOfMemory,
            };
            try pats.append(a, .{ .kind = .{ .regex = re } });
        }
    }
    return .{ .pats = pats.items, .icase = options.ignore_case, .word = options.word, .invert = options.invert };
}

fn findFixed(needle: []const u8, hay: []const u8, icase: bool) ?ere.Match {
    if (needle.len == 0) return .{ .start = 0, .end = 0 };
    if (!icase) {
        const at = std.mem.indexOf(u8, hay, needle) orelse return null;
        return .{ .start = at, .end = at + needle.len };
    }
    const at = std.ascii.indexOfIgnoreCase(hay, needle) orelse return null;
    return .{ .start = at, .end = at + needle.len };
}

/// Scratch a task matches with: one regex machine per pattern.
const Scratch = struct {
    vms: []?ere.Vm,

    fn init(gpa: Allocator, s: *const Searcher) Allocator.Error!Scratch {
        const vms = try gpa.alloc(?ere.Vm, s.pats.len);
        for (s.pats, vms) |p, *vm| vm.* = switch (p.kind) {
            .regex => |r| try ere.Vm.init(gpa, r.program.len),
            .fixed => null,
        };
        return .{ .vms = vms };
    }

    fn deinit(sc: *Scratch, gpa: Allocator) void {
        for (sc.vms) |*vm| if (vm.*) |*v| v.deinit(gpa);
        gpa.free(sc.vms);
    }
};

fn patmatch(p: *const Pat, vm: ?*ere.Vm, icase: bool, line: []const u8, not_bol: bool) ?ere.Match {
    return switch (p.kind) {
        .fixed => |text| findFixed(text, line, icase),
        .regex => |*r| r.findWith(vm.?, line, not_bol),
    };
}

fn wordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// git's `headerless_match_one_pattern`: a match, with `-w` retried until
/// it is a whole word.
fn matchOne(s: *const Searcher, i: usize, sc: *Scratch, line: []const u8, not_bol_in: bool) ?ere.Match {
    const p = &s.pats[i];
    const vm: ?*ere.Vm = if (sc.vms[i]) |*v| v else null;
    var bol: usize = 0;
    var not_bol = not_bol_in;
    while (true) {
        const m = patmatch(p, vm, s.icase, line[bol..], not_bol) orelse return null;
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

/// Whether the line matches any pattern, and with `col` where the earliest
/// match starts.
fn matchLine(s: *const Searcher, sc: *Scratch, line: []const u8, col: ?*?usize) bool {
    var hit = false;
    for (s.pats, 0..) |_, i| {
        if (matchOne(s, i, sc, line, false)) |m| {
            hit = true;
            const c = col orelse break;
            if (c.* == null or m.start < c.*.?) c.* = m.start;
        }
    }
    return hit;
}

/// git's `grep_next_match`: the earliest match of any pattern, the longest
/// of those.
fn nextMatch(s: *const Searcher, sc: *Scratch, line: []const u8, not_bol: bool) ?ere.Match {
    if (line.len == 0) return null;
    var best: ?ere.Match = null;
    for (s.pats, 0..) |_, i| {
        const m = matchOne(s, i, sc, line, not_bol) orelse continue;
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
    max_count: ?usize,
    null_sep: bool,
    binary: Binary,
};

const FileState = struct {
    w: *Io.Writer,
    fmt: *const Format,
    name: []const u8,
    last_shown: usize = 0,
};

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

fn showLine(st: *FileState, s: *const Searcher, sc: *Scratch, line: []const u8, lno: usize, cno_in: usize, sign: u8) Io.Writer.Error!void {
    const context = st.fmt.before != 0 or st.fmt.after != 0;
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
        while (nextMatch(s, sc, line[bol..], not_bol)) |m| {
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

/// git's `grep_source_1` over one file's bytes. Returns whether it hit.
fn searchFile(s: *const Searcher, sc: *Scratch, fmt: *const Format, name: []const u8, content: []const u8, is_binary: bool, w: *Io.Writer) Io.Writer.Error!bool {
    var st: FileState = .{ .w = w, .fmt = fmt, .name = name };
    var binary_match_only = false;
    switch (fmt.binary) {
        .match => if (is_binary) {
            binary_match_only = true;
        },
        .skip => if (is_binary) return false,
        .text => {},
    }
    var lno: usize = 1;
    var last_hit: usize = 0;
    var count: usize = 0;
    var bol: usize = 0;
    // the line starts, for pre-context
    while (bol < content.len) {
        const eol = std.mem.indexOfScalarPos(u8, content, bol, '\n') orelse content.len;
        const line = content[bol..eol];
        var col: ?usize = null;
        var hit = matchLine(s, sc, line, if (fmt.column) &col else null);
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
                    try w.print("Binary file {s} matches\n", .{name});
                    return true;
                }
                if (fmt.before > 0) try showPreContext(&st, s, sc, content, bol, lno);
                const cno: usize = if (col) |c| c + 1 else 1;
                try showLine(&st, s, sc, line, lno, if (s.invert) 1 else cno, ':');
                last_hit = lno;
            }
        } else if (last_hit != 0 and lno <= last_hit + fmt.after and fmt.show == .lines) {
            try showLine(&st, s, sc, line, lno, if (col) |c| c + 1 else 0, '-');
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
            try w.writeAll(name);
            try outputSep(&st, ':');
        }
        try w.print("{d}\n", .{count});
        return true;
    }
    return last_hit != 0;
}

fn showPreContext(st: *FileState, s: *const Searcher, sc: *Scratch, content: []const u8, bol_in: usize, lno: usize) Io.Writer.Error!void {
    var from: usize = 1;
    if (st.fmt.before < lno) from = lno - st.fmt.before;
    if (from <= st.last_shown) from = st.last_shown + 1;
    var bol = bol_in;
    var cur = lno;
    while (bol > 0 and cur > from) {
        var b = bol - 1; // the newline ending the line before
        while (b > 0 and content[b - 1] != '\n') b -= 1;
        bol = b;
        cur -= 1;
    }
    while (cur < lno) {
        const eol = std.mem.indexOfScalarPos(u8, content, bol, '\n') orelse content.len;
        try showLine(st, s, sc, content[bol..eol], cur, 0, '-');
        bol = eol + 1;
        cur += 1;
    }
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

fn collectTree(a: Allocator, io: Io, repo: *Repository, spec: *const pathspec_mod.Pathspec, tree_oid: Oid, prefix: []const u8, name_prefix: []const u8, items: *std.ArrayList(Item)) Error!void {
    const db = &repo.odb;
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.NotATree;
    const tree = object.Tree.parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = if (prefix.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.mode) {
            .file, .exec => if (spec.matches(path)) {
                const name = try std.mem.concat(a, u8, &.{ name_prefix, path });
                try items.append(a, .{ .name = name, .path = path, .source = .{ .blob = entry.oid } });
            },
            .tree => if (spec.couldMatchUnder(path)) try collectTree(a, io, repo, spec, entry.oid, path, name_prefix, items),
            else => {},
        }
    }
}

fn peelToTree(io: Io, repo: *Repository, oid: Oid) Error!Oid {
    var current = oid;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const header = try repo.odb.readHeader(io, current);
        switch (header.type) {
            .tree => return current,
            .commit => return repo.commitTree(io, current),
            .tag => {
                const found = try repo.odb.read(io, current);
                defer repo.odb.allocator().free(found.bytes);
                var tag = object.Tag.parse(repo.gpa, repo.objectFormat(), found.bytes) catch return error.NotATree;
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
    return std.mem.indexOfScalar(u8, bytes[0..n], 0) != null;
}

/// The `diff` attribute's say on whether `path` is binary, or `null`.
fn binaryByAttributes(a: Allocator, io: Io, attrs: ?*attributes.Attrs, wt: ?Io.Dir, path: []const u8) Error!?bool {
    const at = attrs orelse return null;
    if (wt) |w| try at.enter(io, w, path);
    const applied = try at.lookup(a, path, false);
    if (applied.get("diff")) |state| switch (state) {
        .unset => return true,
        .set => return false,
        else => {},
    };
    return null;
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
        const hit = searchFile(work.searcher, &work.scratch[worker], work.fmt, work.items[i].name, content, work.binaries[i], &w) catch {
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

/// `git grep`: write to `w` what git writes, and say whether anything
/// matched.
pub fn grep(gpa: Allocator, io: Io, repo: *Repository, options: Options, w: *Io.Writer) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();
    const config = repo.configuration();

    var syntax: Syntax = options.syntax orelse .basic;
    if (options.syntax == null) {
        if (config.getBool("grep.extendedregexp", false) catch false) syntax = .extended;
        if (config.get("grep.patterntype")) |v| {
            if (std.mem.eql(u8, v, "basic")) syntax = .basic else if (std.mem.eql(u8, v, "extended")) syntax = .extended else if (std.mem.eql(u8, v, "fixed")) syntax = .fixed else if (std.mem.eql(u8, v, "perl")) syntax = .perl;
        }
    }
    var searcher = try compile(a, gpa, options, syntax);
    defer searcher.deinit();
    const fmt: Format = .{
        .show = options.show,
        .line_number = options.line_number orelse (config.getBool("grep.linenumber", false) catch false),
        .column = options.column orelse (config.getBool("grep.column", false) catch false),
        .only_matching = options.only_matching,
        .pathname = options.with_filename,
        .before = options.before,
        .after = options.after,
        .max_count = options.max_count,
        .null_sep = options.null_separator,
        .binary = options.binary,
    };

    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();
    var items: std.ArrayList(Item) = .empty;
    switch (options.source) {
        .worktree => {
            if (repo.work_dir == null) return error.BareRepository;
            try collectIndex(a, io, repo, &spec, false, &items);
        },
        .index => try collectIndex(a, io, repo, &spec, true, &items),
        .tree => |t| {
            const tree = try peelToTree(io, repo, t.oid);
            const prefix = if (t.name.len == 0) "" else try std.mem.concat(a, u8, &.{ t.name, ":" });
            try collectTree(a, io, repo, &spec, tree, "", prefix, &items);
        },
    }

    var attrs: ?attributes.Attrs = null;
    defer if (attrs) |*x| x.deinit();
    if (repo.work_dir != null) attrs = try repo.loadAttrs(io);
    defer if (attrs) |*x| x.leave();

    const workers = @max(1, @min(taskCount(options.threads), items.items.len));
    const scratch = try a.alloc(Scratch, workers);
    var made: usize = 0;
    defer for (scratch[0..made]) |*sc| sc.deinit(gpa);
    for (scratch) |*sc| {
        sc.* = try Scratch.init(gpa, &searcher);
        made += 1;
    }
    const buffers = try a.alloc([]u8, workers);
    for (buffers) |*b| b.* = try a.alloc(u8, task_output_bytes);

    var matched = false;
    var first_mark = fmt.before != 0 or fmt.after != 0;
    var start: usize = 0;
    while (start < items.items.len) {
        // a batch: as many files as fit the byte budget
        var end = start;
        var bytes: usize = 0;
        var contents: std.ArrayList(?[]const u8) = .empty;
        var binaries: std.ArrayList(bool) = .empty;
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |b| repo.odb.allocator().free(b);
            owned.deinit(gpa);
        }
        while (end < items.items.len and (end == start or bytes < batch_bytes)) : (end += 1) {
            const item = items.items[end];
            const content: ?[]u8 = switch (item.source) {
                .blob => |oid| blk: {
                    const found = try repo.odb.read(io, oid);
                    break :blk found.bytes;
                },
                .file => (fs.readFileAlloc(repo.odb.allocator(), io, repo.work_dir.?, item.path, 1 << 31) catch null) orelse null,
            };
            if (content) |c| {
                try owned.append(gpa, c);
                bytes += c.len;
            }
            try contents.append(a, content);
            var bin = false;
            if (content) |c| {
                bin = (try binaryByAttributes(a, io, if (attrs) |*x| x else null, repo.work_dir, item.path)) orelse isBinaryContent(c);
            }
            try binaries.append(a, bin);
        }
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
            .contents = contents.items,
            .binaries = binaries.items,
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
                work.hits[i] = try searchFile(&searcher, &scratch[0], &fmt, work.items[i].name, content, work.binaries[i], &redo.writer);
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
    var s = try compile(arena.allocator(), gpa, .{ .patterns = &.{"foo"}, .word = true }, .basic);
    defer s.deinit();
    var sc = try Scratch.init(gpa, &s);
    defer sc.deinit(gpa);
    try std.testing.expect(matchLine(&s, &sc, "foobar foo", null));
    try std.testing.expect(!matchLine(&s, &sc, "foobar xfoo", null));
}
