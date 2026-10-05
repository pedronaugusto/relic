//! `git apply`: a patch carried into the working tree, the index, or both.
//!
//! Every file the patch touches is checked and patched in memory first;
//! nothing is written until every one of them applies, so a patch that does
//! not apply leaves everything as it was, which is git's own rule. With
//! `reject` the files that apply are written and each rejected hunk goes
//! into `<file>.rej`; with `three_way` a file whose hunks do not apply is
//! merged from the blobs its `index` line names, its conflicts left in the
//! index and the file as a merge leaves them.
//!
//! A hunk is placed as git places one: at its own line first, then a line
//! further away on alternate sides until it fits, its context trimmed only
//! as far as `min_context` allows; a hunk at the start or the end of a file
//! must stay there unless its context is gone. Whitespace is checked and,
//! under `.fix`, corrected with git's rules, `core.whitespace` and the
//! `whitespace` attribute; `ignore_space_change` matches context lines
//! regardless of their whitespace, and corrects the context to the file's.
//! This is git's `apply.c` from `apply_one_fragment` down, decision for
//! decision. One check differs: with the index as a target, a file whose
//! stat no longer matches its entry is compared by content, and taken as
//! matching when the content does, where git says "does not match index"
//! until the index is refreshed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const patchparse = @import("../patch.zig");
const whitespace = @import("whitespace.zig");
const binarypatch = @import("binary.zig");
const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");
const index_mod = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const worktree = @import("../worktree.zig");
const attributes = @import("../worktree/attributes.zig");
const convert = @import("../worktree/convert.zig");
const blobmerge = @import("../merge/blobmerge.zig");
const delta = @import("../odb/delta.zig");
const fs = @import("../repo/fs.zig");
const safepath = @import("../worktree/safepath.zig");
const wildmatch = @import("../worktree/wildmatch.zig");
const rerere = @import("../merge/rerere.zig");
const program = @import("../repo/program.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const Index = index_mod.Index;
const FilePatch = patchparse.FilePatch;
const Mode = patchparse.Mode;

/// Errors from applying a patch.
pub const Error = error{
    /// At least one file did not apply and `reject` was not asked for.
    /// Nothing was written; `Diagnostic.failures` says which and why.
    PatchDoesNotApply,
    /// The input holds no patch, and `allow_empty` was not asked for.
    NoValidPatches,
    /// `whitespace` is `.@"error"` or `.error_all` and an added line has a
    /// whitespace error. Nothing was written.
    WhitespaceErrors,
    /// `--index`, `--cached` or `--3way` in a repository with no working
    /// tree for the first, or the working tree asked of a bare repository.
    BareRepository,
    /// `reject` and `three_way` together, which git refuses.
    RejectWithThreeWay,
    /// A favour for conflicts without `three_way`.
    FavorWithoutThreeWay,
    /// `core.whitespace` or a `whitespace` attribute names both
    /// `tab-in-indent` and `indent-with-non-tab`.
    ConflictingWhitespaceRules,
} || patchparse.Error || worktree.Error || index_mod.ReadError || index_mod.WriteError || odb_mod.Error ||
    convert.Error || attributes.Error || rerere.Error || repo_mod.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.ReadLinkError || fs.StatError || Io.Dir.DeleteFileError || Io.Dir.CreateDirPathError ||
    Io.Dir.WriteFileError;

/// What `apply` does with whitespace errors in the lines a patch adds:
/// git's `--whitespace`.
pub const Whitespace = enum {
    /// Say nothing.
    nowarn,
    /// Report them and apply.
    warn,
    /// Correct them, in added lines and in the context they match.
    fix,
    /// Refuse the patch when there are any, reporting the first five.
    @"error",
    /// Refuse it, reporting all of them.
    error_all,

    /// The action a `--whitespace` or `apply.whitespace` word names;
    /// `strip` is `fix`'s old name.
    pub fn parse(text: []const u8) ?Whitespace {
        if (std.mem.eql(u8, text, "nowarn")) return .nowarn;
        if (std.mem.eql(u8, text, "warn")) return .warn;
        if (std.mem.eql(u8, text, "fix") or std.mem.eql(u8, text, "strip")) return .fix;
        if (std.mem.eql(u8, text, "error")) return .@"error";
        if (std.mem.eql(u8, text, "error-all")) return .error_all;
        return null;
    }
};

/// Where the patch goes.
pub const Target = enum {
    /// The working tree only: `git apply`.
    worktree,
    /// The working tree and the index, which must agree for every file
    /// the patch touches: `git apply --index`.
    index,
    /// The index only: `git apply --cached`.
    cached,
};

/// One `--include` or `--exclude`, in the order given; the first that
/// matches a path decides it.
pub const Limit = struct {
    pattern: []const u8,
    include: bool,
};

/// How a patch is applied.
pub const Options = struct {
    target: Target = .worktree,
    /// `--check`: see whether it applies, and write nothing.
    check: bool = false,
    /// `-R`.
    reverse: bool = false,
    /// `--reject`: write what applies, and the rest into `.rej` files.
    reject: bool = false,
    /// `--3way`: fall back to a three-way merge from the blobs the patch
    /// names. Implies the index.
    three_way: bool = false,
    /// `--ours`, `--theirs`, `--union` for the three-way merge's
    /// conflicts.
    favor: blobmerge.Favor = .none,
    /// `--whitespace`; `null` reads `apply.whitespace` and falls back to
    /// `.warn` (`.nowarn` under `check`).
    whitespace: ?Whitespace = null,
    /// `--ignore-space-change`; `null` reads `apply.ignoreWhitespace`.
    ignore_space_change: ?bool = null,
    /// `-C<n>`: at least this many lines of context must match; `null`
    /// trims as far as needed.
    min_context: ?usize = null,
    /// `-p<n>`; `null` is one, guessed for traditional patches.
    strip: ?usize = null,
    /// `--directory`: prepended to every path, without a trailing slash.
    directory: []const u8 = "",
    /// `--unidiff-zero`.
    unidiff_zero: bool = false,
    /// `--allow-overlap`.
    allow_overlap: bool = false,
    /// `--inaccurate-eof`.
    inaccurate_eof: bool = false,
    /// `--recount`.
    recount: bool = false,
    /// `--no-add`: removals only.
    no_add: bool = false,
    /// `--allow-empty`: an input with no patch is not an error.
    allow_empty: bool = false,
    /// `--unsafe-paths`: a path outside the working tree is written. Only
    /// honoured for `.worktree`, as in git.
    unsafe_paths: bool = false,
    /// `-N`: a file the patch creates is added to the index as intent to
    /// add. Only for `.worktree`, as in git.
    intent_to_add: bool = false,
    /// `--include` and `--exclude`.
    limits: []const Limit = &.{},
    /// The rules files are read and written by: attributes for the
    /// `whitespace` rule and line endings, filters. `null` asks the
    /// repository with no attributes loaded.
    rules: ?worktree.Rules = null,
    /// The programs a filter runs through.
    programs: ?program.Programs = null,
    /// Where a refusal is described.
    diagnostic: ?*Diagnostic = null,
    /// An index of the caller's to apply to in place of the repository's:
    /// read and changed here, and written by the caller. `git am` applies
    /// to such an index when it builds a three-way merge's sides.
    index: ?*index_mod.Index = null,
};

/// Why a file did not apply: git's message for it.
pub const Reason = enum {
    /// "patch does not apply": a hunk found no place.
    does_not_apply,
    /// The file the patch changes is not there.
    does_not_exist,
    /// "does not exist in index".
    not_in_index,
    /// "does not match index".
    does_not_match_index,
    /// "already exists in index".
    already_in_index,
    /// "already exists in working directory".
    already_in_worktree,
    /// "wrong type": a file where the patch expects a symlink, or the
    /// other way round.
    wrong_type,
    /// "has been renamed/deleted" by an earlier file of the same patch.
    renamed_or_deleted,
    /// "affected file is beyond a symbolic link".
    beyond_symlink,
    /// "invalid path".
    invalid_path,
    /// "new mode does not match old mode": a type change in one patch.
    mode_mismatch,
    /// "removal patch leaves file contents".
    removal_leaves_contents,
    /// "cannot apply binary patch without full index line".
    binary_needs_full_index,
    /// "the patch applies to ... which does not match the current
    /// contents".
    binary_preimage_mismatch,
    /// "the patch applies to an empty ... but it is not empty".
    binary_not_empty,
    /// "cannot reverse-apply a binary patch without the reverse hunk".
    binary_not_reversible,
    /// "binary patch to ... creates incorrect result".
    binary_wrong_result,
    /// "missing binary patch data": `Binary files ... differ` with no
    /// data, and no postimage in the repository.
    binary_missing_data,
    /// "corrupt patch for submodule".
    corrupt_submodule_patch,
};

/// One file that did not apply.
pub const Failure = struct {
    /// The old name where there is one, as git names it.
    path: []const u8,
    reason: Reason,
};

/// Where a refusal is described. Caller-owned; `apply` clears it.
pub const Diagnostic = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State = .{},
    failures: std.ArrayList(Failure) = .empty,
    /// The patch line a parse refusal is about.
    line: usize = 0,

    pub fn init(gpa: Allocator) Diagnostic {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Diagnostic) void {
        d.failures.deinit(d.gpa);
        var arena = d.arena.promote(d.gpa);
        arena.deinit();
        d.* = undefined;
    }

    fn reset(d: *Diagnostic) void {
        d.failures.clearRetainingCapacity();
        var arena = d.arena.promote(d.gpa);
        _ = arena.reset(.free_all);
        d.arena = arena.state;
        d.line = 0;
    }

    fn add(d: *Diagnostic, path: []const u8, reason: Reason) Allocator.Error!void {
        var arena = d.arena.promote(d.gpa);
        defer d.arena = arena.state;
        const copy = try arena.allocator().dupe(u8, path);
        try d.failures.append(d.gpa, .{ .path = copy, .reason = reason });
    }
};

/// What git prints along the way, as values.
pub const Note = union(enum) {
    /// "Hunk #n succeeded at <line> (offset <k> lines)."
    offset: struct { path: []const u8, hunk: usize, at: usize, offset: isize },
    /// "Context reduced to (<leading>/<trailing>) to apply fragment at
    /// <line>".
    context_reduced: struct { path: []const u8, leading: usize, trailing: usize, at: usize },
    /// A whitespace error, at the patch line the added line is on, with
    /// git's description and the line's text. Only the first five are
    /// noted unless `.error_all`.
    whitespace: struct { line: usize, kinds: whitespace.Rule, text: []const u8 },
    /// "<path> has type <mode>, expected <mode>".
    mode_differs: struct { path: []const u8, has: Mode, expected: Mode },
    /// "file <path> becomes empty but is not deleted".
    becomes_empty: struct { path: []const u8 },
};

/// One file's result.
pub const File = struct {
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    status: Status,
    /// The hunks, counting from one, that went to the `.rej` file.
    rejected_hunks: []const usize = &.{},

    pub const Status = enum {
        /// Every hunk applied.
        applied,
        /// Some hunks were rejected; the rest were written.
        partly_rejected,
        /// The whole file was rejected: it did not apply at all.
        rejected,
        /// Merged with conflicts by the three-way fallback.
        conflicted,
        /// Merged cleanly by the three-way fallback.
        merged,
    };
};

/// What `apply` did.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// Every file of the patch the limits kept, in the order applied.
    files: []const File,
    /// The paths left with conflicts, sorted: git's `U <path>` lines.
    conflicted: []const []const u8,
    notes: []const Note,
    /// Lines that added whitespace errors.
    whitespace_errors: usize,
    /// Lines whose whitespace errors were corrected under `.fix`.
    whitespace_fixed: usize,
    /// Whether anything was written: false under `check`.
    written: bool,

    /// Whether everything applied with no rejected hunk and no conflict:
    /// git's exit status zero.
    pub fn clean(o: *const Outcome) bool {
        if (o.conflicted.len != 0) return false;
        for (o.files) |f| switch (f.status) {
            .applied, .merged => {},
            else => return false,
        };
        return true;
    }

    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

//=========================================================================
// Images: a file as lines, each with a hash that ignores whitespace
//=========================================================================

const line_common: u8 = 1;
const line_patched: u8 = 2;

const Line = struct {
    len: usize,
    hash: u24,
    flag: u8,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn hashLine(bytes: []const u8) u24 {
    var h: u32 = 0;
    for (bytes) |c| {
        if (!isSpace(c)) h = h *% 3 +% c;
    }
    return @truncate(h);
}

const Image = struct {
    buf: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Line) = .empty,

    fn deinit(img: *Image, gpa: Allocator) void {
        img.buf.deinit(gpa);
        img.lines.deinit(gpa);
        img.* = undefined;
    }

    fn clear(img: *Image) void {
        img.buf.clearRetainingCapacity();
        img.lines.clearRetainingCapacity();
    }

    fn addLine(img: *Image, gpa: Allocator, bytes: []const u8, flag: u8) Allocator.Error!void {
        try img.lines.append(gpa, .{ .len = bytes.len, .hash = hashLine(bytes), .flag = flag });
    }

    /// Take `bytes` as the image, with a line table unless `lines` is false.
    fn prepare(img: *Image, gpa: Allocator, bytes: []const u8, lines: bool) Allocator.Error!void {
        img.clear();
        try img.buf.appendSlice(gpa, bytes);
        if (!lines) return;
        var at: usize = 0;
        while (at < bytes.len) {
            var next = std.mem.indexOfScalarPos(u8, bytes, at, '\n') orelse bytes.len;
            if (next < bytes.len) next += 1;
            try img.addLine(gpa, bytes[at..next], 0);
            at = next;
        }
    }

    fn removeFirstLine(img: *Image) void {
        const n = img.lines.items[0].len;
        std.mem.copyForwards(u8, img.buf.items, img.buf.items[n..]);
        img.buf.shrinkRetainingCapacity(img.buf.items.len - n);
        _ = img.lines.orderedRemove(0);
    }

    fn removeLastLine(img: *Image) void {
        const n = img.lines.items[img.lines.items.len - 1].len;
        img.buf.shrinkRetainingCapacity(img.buf.items.len - n);
        _ = img.lines.pop();
    }
};

//=========================================================================
// The state of one call
//=========================================================================

/// A file of the patch, with what applying it found.
const Entry = struct {
    p: FilePatch,
    ws_rule: whitespace.Rule = 0,
    result: ?[]u8 = null,
    rejected: bool = false,
    frag_rejected: []bool = &.{},
    conflicted_threeway: bool = false,
    direct_to_threeway: bool = false,
    merged_threeway: bool = false,
    threeway_stage: [3]?Oid = .{ null, null, null },
};

const PathState = union(enum) {
    patched: *Entry,
    was_deleted,
    to_be_deleted,
};

const WsAction = enum { nowarn, warn, die, correct };

const State = struct {
    gpa: Allocator,
    io: Io,
    a: Allocator,
    repo: *Repository,
    options: Options,
    wt: ?Io.Dir,
    rules: worktree.Rules,
    conv: convert.Session,
    ws_action: WsAction,
    ws_ignore_change: bool,
    squelch: usize,
    whitespace_error: usize = 0,
    applied_after_fixing_ws: usize = 0,
    apply: bool,
    check_index: bool,
    cached: bool,
    update_index: bool = false,
    /// The index applied to: the caller's, or `owned_index`.
    index: ?*Index = null,
    owned_index: ?Index = null,
    fn_table: std.StringHashMapUnmanaged(PathState) = .empty,
    removed_symlinks: std.StringHashMapUnmanaged(void) = .empty,
    kept_symlinks: std.StringHashMapUnmanaged(void) = .empty,
    notes: std.ArrayList(Note) = .empty,
    p_context: usize,

    fn note(st: *State, n: Note) Allocator.Error!void {
        try st.notes.append(st.a, n);
    }

    fn fail(st: *State, entry: *Entry, reason: Reason) Error!bool {
        _ = entry.p;
        if (st.options.diagnostic) |d| try d.add(entry.p.name(), reason);
        return false;
    }
};

//=========================================================================
// The entry point
//=========================================================================

/// Apply `text`, a patch or an email or anything else holding patches, to
/// `repo` as `options.target` says.
///
/// Returns what was done. A patch that does not apply is
/// `error.PatchDoesNotApply` with nothing written, unless `reject` or
/// `three_way` says otherwise, in which case `Outcome.clean` says whether
/// everything went in.
pub fn apply(gpa: Allocator, io: Io, repo: *Repository, text: []const u8, options: Options) Error!Outcome {
    if (options.diagnostic) |d| d.reset();
    if (options.reject and options.three_way) return error.RejectWithThreeWay;
    if (options.favor != .none and !options.three_way) return error.FavorWithoutThreeWay;

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const a = arena_instance.allocator();

    const config = repo.configuration();
    const ws_option: ?Whitespace = options.whitespace orelse if (config.get("apply.whitespace")) |v| Whitespace.parse(v) else null;
    const ignore_change = options.ignore_space_change orelse blk: {
        const v = config.get("apply.ignorewhitespace") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "change");
    };
    const check_index = options.target != .worktree or options.three_way;
    const cached = options.target == .cached;
    const writes = !options.check;
    var ws_action: WsAction = .warn;
    var squelch: usize = 5;
    if (ws_option) |w| switch (w) {
        .nowarn => ws_action = .nowarn,
        .warn => ws_action = .warn,
        .fix => ws_action = .correct,
        .@"error" => ws_action = .die,
        .error_all => {
            ws_action = .die;
            squelch = 0;
        },
    } else {
        ws_action = if (writes) .warn else .nowarn;
    }

    const wt: ?Io.Dir = repo.work_dir;
    if (!cached and wt == null) return error.BareRepository;

    // the repository's attributes unless the caller brings rules of its
    // own, since git reads them for the whitespace rule and line endings
    var own_attrs: ?attributes.Attrs = null;
    defer if (own_attrs) |*x| x.deinit();
    var rules = options.rules orelse blk: {
        var r = try repo.worktreeRules();
        if (wt != null) {
            own_attrs = try repo.loadAttrs(io);
            r.attrs = &own_attrs.?;
        }
        break :blk r;
    };
    const configured_ws = if (config.get("core.whitespace")) |v|
        whitespace.parse(v) catch return error.ConflictingWhitespaceRules
    else
        whitespace.default_rule;

    var st: State = .{
        .gpa = gpa,
        .io = io,
        .a = a,
        .repo = repo,
        .options = options,
        .wt = wt,
        .rules = rules,
        .conv = .init(gpa, io, .{
            .wt = wt orelse repo.git_dir,
            .kind = repo.objectFormat(),
            .core = rules.core,
            .required_filters = rules.required_filters,
            .drivers = rules.filters,
            .programs = options.programs,
        }),
        .ws_action = ws_action,
        .ws_ignore_change = ignore_change,
        .squelch = squelch,
        .apply = writes,
        .check_index = check_index,
        .cached = cached,
        .p_context = options.min_context orelse std.math.maxInt(usize),
    };
    defer st.conv.deinit();
    defer if (st.owned_index) |*ix| ix.deinit();
    defer if (rules.attrs) |attrs| attrs.leave();
    _ = &rules;

    var parse_diag: patchparse.Diagnostic = .{};
    var parsed = patchparse.parse(gpa, text, .{
        .strip = options.strip,
        .root = if (options.directory.len == 0) "" else try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, options.directory, "/"), "/" }),
        .recount = options.recount,
        .inaccurate_eof = options.inaccurate_eof,
        .reverse = options.reverse,
        .diagnostic = &parse_diag,
    }) catch |err| {
        if (options.diagnostic) |d| d.line = parse_diag.line;
        return err;
    };
    defer parsed.deinit();

    // the files the limits keep, reversed and in reverse order under -R
    var list: std.ArrayList(*Entry) = .empty;
    var skipped: usize = 0;
    for (parsed.files) |file| {
        var entry = try a.create(Entry);
        entry.* = .{ .p = file };
        if (options.reverse) reversePatch(&entry.p);
        if (!usePatch(&st, &entry.p)) {
            skipped += 1;
            continue;
        }
        entry.ws_rule = try wsRuleFor(&st, entry.p.new_name orelse entry.p.old_name.?, configured_ws);
        entry.frag_rejected = try a.alloc(bool, entry.p.fragments.len);
        @memset(entry.frag_rejected, false);
        if (options.reverse) try list.insert(a, 0, entry) else try list.append(a, entry);
    }
    if (list.items.len == 0 and skipped == 0) {
        if (!options.allow_empty) return error.NoValidPatches;
    }

    // whitespace, as git checks it while reading the hunks
    for (list.items) |entry| try checkPatchWhitespace(&st, entry);
    if (st.whitespace_error != 0 and st.ws_action == .die) st.apply = false;

    st.update_index = (st.check_index or options.intent_to_add) and st.apply;
    if (st.check_index or st.update_index) {
        if (options.index) |ix| {
            st.index = ix;
        } else {
            st.owned_index = try repo.openIndex(io);
            st.index = &st.owned_index.?;
        }
    }

    var any_failed = false;
    if (!options.check and !st.apply and st.ws_action == .die) {
        // refused for whitespace: nothing is checked or written
    } else if (st.apply or options.check) {
        try prepareSymlinkChanges(&st, list.items);
        try prepareFnTable(&st, list.items);
        for (list.items) |entry| {
            if (!try checkPatch(&st, entry)) any_failed = true;
        }
    }

    if (st.whitespace_error != 0 and st.ws_action == .die) {
        if (options.diagnostic) |d| d.line = 0;
        return error.WhitespaceErrors;
    }
    if (any_failed and !options.reject) return error.PatchDoesNotApply;

    var conflicted: std.ArrayList([]const u8) = .empty;
    if (st.apply) {
        try writeOutResults(&st, list.items, &conflicted);
        std.mem.sort([]const u8, conflicted.items, {}, lessPath);
        if (conflicted.items.len != 0 and !st.cached) {
            if (st.index) |ix| _ = try rerere.afterStop(gpa, io, repo, ix, a, null);
        }
        if (st.update_index and options.index == null) try repo.writeIndex(io, st.index.?);
    }

    var files: std.ArrayList(File) = .empty;
    for (list.items) |entry| {
        var rejected_hunks: std.ArrayList(usize) = .empty;
        for (entry.frag_rejected, 0..) |r, i| if (r) try rejected_hunks.append(a, i + 1);
        const status: File.Status = if (entry.rejected)
            .rejected
        else if (entry.conflicted_threeway)
            .conflicted
        else if (rejected_hunks.items.len != 0)
            .partly_rejected
        else if (entry.merged_threeway)
            .merged
        else
            .applied;
        try files.append(a, .{
            .old_path = entry.p.old_name,
            .new_path = entry.p.new_name,
            .status = status,
            .rejected_hunks = rejected_hunks.items,
        });
    }
    // names in the outcome must outlive the parsed patch
    for (files.items) |*f| {
        if (f.old_path) |p| f.old_path = try a.dupe(u8, p);
        if (f.new_path) |p| f.new_path = try a.dupe(u8, p);
    }
    for (st.notes.items) |*n| switch (n.*) {
        .offset => |*x| x.path = try a.dupe(u8, x.path),
        .context_reduced => |*x| x.path = try a.dupe(u8, x.path),
        .whitespace => |*x| x.text = try a.dupe(u8, x.text),
        .mode_differs => |*x| x.path = try a.dupe(u8, x.path),
        .becomes_empty => |*x| x.path = try a.dupe(u8, x.path),
    };
    for (conflicted.items) |*c| c.* = try a.dupe(u8, c.*);
    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .files = files.items,
        .conflicted = conflicted.items,
        .notes = st.notes.items,
        .whitespace_errors = st.whitespace_error,
        .whitespace_fixed = st.applied_after_fixing_ws,
        .written = st.apply,
    };
}

fn lessPath(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn reversePatch(p: *FilePatch) void {
    std.mem.swap(?[]const u8, &p.new_name, &p.old_name);
    if (p.new_mode != 0 or p.is_delete == .yes) std.mem.swap(Mode, &p.new_mode, &p.old_mode);
    std.mem.swap(patchparse.Tri, &p.is_new, &p.is_delete);
    std.mem.swap(usize, &p.lines_added, &p.lines_deleted);
    std.mem.swap([]const u8, &p.old_oid_prefix, &p.new_oid_prefix);
    for (p.fragments) |*f| {
        std.mem.swap(usize, &f.new_pos, &f.old_pos);
        std.mem.swap(usize, &f.new_lines, &f.old_lines);
    }
}

fn usePatch(st: *State, p: *const FilePatch) bool {
    const pathname = p.new_name orelse p.old_name.?;
    var has_include = false;
    for (st.options.limits) |limit| {
        if (limit.include) has_include = true;
    }
    for (st.options.limits) |limit| {
        if (wildmatch.match(limit.pattern, pathname, .{ .pathname = false }) catch false) return limit.include;
    }
    return !has_include;
}

fn wsRuleFor(st: *State, path: []const u8, configured: whitespace.Rule) Error!whitespace.Rule {
    const attrs = st.rules.attrs orelse return configured;
    if (st.wt) |wt| try attrs.enter(st.io, wt, path);
    const applied = try attrs.lookup(st.a, path, false);
    const attribute: whitespace.Attribute = if (applied.get("whitespace")) |state| switch (state) {
        .set => .set,
        .unset => .unset,
        .unspecified => .unspecified,
        .value => |v| .{ .value = v },
    } else .unspecified;
    return whitespace.forAttribute(attribute, configured) catch error.ConflictingWhitespaceRules;
}

fn linelen(buf: []const u8) usize {
    if (std.mem.indexOfScalar(u8, buf, '\n')) |i| return i + 1;
    return buf.len;
}

/// The whitespace checks `parse_fragment` makes, with the patch lines
/// they are on.
fn checkPatchWhitespace(st: *State, entry: *Entry) Error!void {
    var rule = entry.ws_rule;
    if (rule & whitespace.incomplete_line != 0) {
        const p = &entry.p;
        const mode = if (st.options.reverse) p.old_mode else if (p.new_mode != 0) p.new_mode else p.old_mode;
        if (mode != 0 and patchparse.isSymlink(mode)) rule &= ~whitespace.incomplete_line;
    }
    entry.ws_rule = rule;
    for (entry.p.fragments) |frag| {
        var rest = frag.text[linelen(frag.text)..];
        var linenr = frag.line + 1;
        while (rest.len > 0) {
            var len = linelen(rest);
            const full = len;
            var incomplete = false;
            if (len < rest.len and rest[len] == '\\' and (rest[0] == ' ' or rest[0] == '+' or rest[0] == '-' or rest[0] == '\n')) {
                incomplete = true;
                len -= 1;
            }
            const first = rest[0];
            switch (first) {
                ' ', '\n' => if (!st.options.reverse and st.ws_action == .correct) {
                    const line: []const u8 = if (first == '\n') " \n" else rest[0..len];
                    try recordWs(st, whitespace.check(line[1..], rule), line[1..], linenr);
                },
                '-' => if (st.options.reverse and st.ws_action != .nowarn) {
                    try recordWs(st, whitespace.check(rest[1..len], rule), rest[1..len], linenr);
                },
                '+' => if (!st.options.reverse and st.ws_action != .nowarn) {
                    try recordWs(st, whitespace.check(rest[1..len], rule), rest[1..len], linenr);
                },
                else => {},
            }
            rest = rest[full..];
            linenr += 1;
            if (incomplete) {
                rest = rest[linelen(rest)..];
                linenr += 1;
            }
        }
    }
}

fn recordWs(st: *State, result: whitespace.Rule, text: []const u8, linenr: usize) Allocator.Error!void {
    if (result == 0) return;
    st.whitespace_error += 1;
    if (st.squelch != 0 and st.squelch < st.whitespace_error) return;
    const shown = std.mem.trimEnd(u8, text, "\n");
    try st.note(.{ .whitespace = .{ .line = linenr, .kinds = result, .text = shown } });
}

//=========================================================================
// Matching and placing a hunk
//=========================================================================

/// Compare two lines regardless of the amount of whitespace in them, but
/// not of its presence.
fn fuzzyMatchLines(s1_in: []const u8, s2_in: []const u8) bool {
    var e1 = s1_in.len;
    var e2 = s2_in.len;
    while (e1 > 0 and (s1_in[e1 - 1] == '\r' or s1_in[e1 - 1] == '\n')) e1 -= 1;
    while (e2 > 0 and (s2_in[e2 - 1] == '\r' or s2_in[e2 - 1] == '\n')) e2 -= 1;
    const s1 = s1_in[0..e1];
    const s2 = s2_in[0..e2];
    var i: usize = 0;
    var j: usize = 0;
    while (i < s1.len and j < s2.len) {
        if (isSpace(s1[i])) {
            if (!isSpace(s2[j])) return false;
            while (i < s1.len and isSpace(s1[i])) i += 1;
            while (j < s2.len and isSpace(s2[j])) j += 1;
        } else {
            if (s1[i] != s2[j]) return false;
            i += 1;
            j += 1;
        }
    }
    return i == s1.len and j == s2.len;
}

/// Replace the preimage with `fixed`, and the context lines of the
/// postimage with the matching lines of it.
fn updatePrePostImages(gpa: Allocator, preimage: *Image, postimage: *Image, fixed: []const u8) Allocator.Error!void {
    var fixed_pre: Image = .{};
    errdefer fixed_pre.deinit(gpa);
    try fixed_pre.prepare(gpa, fixed, true);
    for (fixed_pre.lines.items, 0..) |*l, i| {
        if (i < preimage.lines.items.len) l.flag = preimage.lines.items[i].flag;
    }
    preimage.deinit(gpa);
    preimage.* = fixed_pre;

    var insert_pos: usize = 0;
    var ctx: usize = 0;
    var reduced: usize = 0;
    var fixed_at: usize = 0;
    var i: usize = 0;
    while (i < postimage.lines.items.len) : (i += 1) {
        const pl = &postimage.lines.items[i];
        if (pl.flag & line_common == 0) {
            insert_pos += pl.len;
            continue;
        }
        while (ctx < preimage.lines.items.len and preimage.lines.items[ctx].flag & line_common == 0) {
            fixed_at += preimage.lines.items[ctx].len;
            ctx += 1;
        }
        if (preimage.lines.items.len <= ctx) {
            reduced += 1;
            continue;
        }
        const l_len = preimage.lines.items[ctx].len;
        try postimage.buf.replaceRange(gpa, insert_pos, pl.len, preimage.buf.items[fixed_at .. fixed_at + l_len]);
        insert_pos += l_len;
        fixed_at += l_len;
        pl.len = l_len;
        ctx += 1;
    }
    postimage.lines.shrinkRetainingCapacity(postimage.lines.items.len - reduced);
}

fn lineByLineFuzzyMatch(gpa: Allocator, img: *const Image, preimage: *Image, postimage: *Image, current: usize, current_lno: usize, preimage_limit: usize) Allocator.Error!bool {
    var imgoff: usize = 0;
    var preoff: usize = 0;
    var i: usize = 0;
    while (i < preimage_limit) : (i += 1) {
        const prelen = preimage.lines.items[i].len;
        const imglen = img.lines.items[current_lno + i].len;
        if (!fuzzyMatchLines(img.buf.items[current + imgoff ..][0..imglen], preimage.buf.items[preoff..][0..prelen])) return false;
        imgoff += imglen;
        preoff += prelen;
    }
    const preimage_eof = preoff;
    while (i < preimage.lines.items.len) : (i += 1) preoff += preimage.lines.items[i].len;
    for (preimage.buf.items[preimage_eof..preoff]) |c| if (!isSpace(c)) return false;
    var fixed: std.ArrayList(u8) = .empty;
    defer fixed.deinit(gpa);
    try fixed.appendSlice(gpa, img.buf.items[current .. current + imgoff]);
    try fixed.appendSlice(gpa, preimage.buf.items[preimage_eof..preoff]);
    try updatePrePostImages(gpa, preimage, postimage, fixed.items);
    return true;
}

fn matchFragment(
    st: *State,
    img: *const Image,
    preimage: *Image,
    postimage: *Image,
    current: usize,
    current_lno: usize,
    ws_rule: whitespace.Rule,
    match_beginning: bool,
    match_end: bool,
) Allocator.Error!bool {
    const gpa = st.gpa;
    var preimage_limit: usize = undefined;
    if (preimage.lines.items.len + current_lno <= img.lines.items.len) {
        preimage_limit = preimage.lines.items.len;
        if (match_end and preimage.lines.items.len + current_lno != img.lines.items.len) return false;
    } else if (st.ws_action == .correct and ws_rule & whitespace.blank_at_eof != 0) {
        preimage_limit = img.lines.items.len - current_lno;
    } else return false;

    if (match_beginning and current_lno != 0) return false;

    var i: usize = 0;
    while (i < preimage_limit) : (i += 1) {
        const il = img.lines.items[current_lno + i];
        if (il.flag & line_patched != 0 or preimage.lines.items[i].hash != il.hash) return false;
    }

    if (preimage_limit == preimage.lines.items.len) {
        const fits = if (match_end) current + preimage.buf.items.len == img.buf.items.len else current + preimage.buf.items.len <= img.buf.items.len;
        if (fits and std.mem.eql(u8, img.buf.items[current .. current + preimage.buf.items.len], preimage.buf.items)) return true;
    } else {
        var end: usize = 0;
        i = 0;
        while (i < preimage_limit) : (i += 1) end += preimage.lines.items[i].len;
        var all_space = true;
        for (preimage.buf.items[0..end]) |c| {
            if (!isSpace(c)) {
                all_space = false;
                break;
            }
        }
        if (all_space) return false;
    }

    if (st.ws_ignore_change) return lineByLineFuzzyMatch(gpa, img, preimage, postimage, current, current_lno, preimage_limit);
    if (st.ws_action != .correct) return false;

    var fixed: std.ArrayList(u8) = .empty;
    defer fixed.deinit(gpa);
    var orig: usize = 0;
    var target: usize = current;
    i = 0;
    while (i < preimage_limit) : (i += 1) {
        const oldlen = preimage.lines.items[i].len;
        const tgtlen = img.lines.items[current_lno + i].len;
        const fixstart = fixed.items.len;
        _ = try whitespace.fixCopy(gpa, &fixed, preimage.buf.items[orig .. orig + oldlen], ws_rule);
        var tgtfix: std.ArrayList(u8) = .empty;
        defer tgtfix.deinit(gpa);
        _ = try whitespace.fixCopy(gpa, &tgtfix, img.buf.items[target .. target + tgtlen], ws_rule);
        if (!std.mem.eql(u8, tgtfix.items, fixed.items[fixstart..])) return false;
        orig += oldlen;
        target += tgtlen;
    }
    while (i < preimage.lines.items.len) : (i += 1) {
        const fixstart = fixed.items.len;
        const oldlen = preimage.lines.items[i].len;
        _ = try whitespace.fixCopy(gpa, &fixed, preimage.buf.items[orig .. orig + oldlen], ws_rule);
        for (fixed.items[fixstart..]) |c| if (!isSpace(c)) return false;
        orig += oldlen;
    }
    try updatePrePostImages(gpa, preimage, postimage, fixed.items);
    return true;
}

fn findPos(
    st: *State,
    img: *const Image,
    preimage: *Image,
    postimage: *Image,
    line_in: isize,
    ws_rule: whitespace.Rule,
    match_beginning_in: bool,
    match_end: bool,
) Allocator.Error!?usize {
    var match_beginning = match_beginning_in;
    const img_lines = img.lines.items.len;
    if (st.options.allow_overlap and match_beginning and match_end and img_lines != preimage.lines.items.len) match_beginning = false;
    var line: isize = line_in;
    if (match_beginning) {
        line = 0;
    } else if (match_end) {
        line = @as(isize, @intCast(img_lines)) - @as(isize, @intCast(preimage.lines.items.len));
    }
    // a negative line from the end compares as a huge unsigned one in git
    var start: usize = if (line < 0) img_lines else @intCast(line);
    if (start > img_lines) start = img_lines;

    var current: usize = 0;
    for (img.lines.items[0..start]) |l| current += l.len;

    var backwards = current;
    var backwards_lno = start;
    var forwards = current;
    var forwards_lno = start;
    var current_lno = start;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (try matchFragment(st, img, preimage, postimage, current, current_lno, ws_rule, match_beginning, match_end)) return current_lno;
        while (true) {
            if (backwards_lno == 0 and forwards_lno == img_lines) return null;
            if (i & 1 != 0) {
                if (backwards_lno == 0) {
                    i += 1;
                    continue;
                }
                backwards_lno -= 1;
                backwards -= img.lines.items[backwards_lno].len;
                current = backwards;
                current_lno = backwards_lno;
            } else {
                if (forwards_lno == img_lines) {
                    i += 1;
                    continue;
                }
                forwards += img.lines.items[forwards_lno].len;
                forwards_lno += 1;
                current = forwards;
                current_lno = forwards_lno;
            }
            break;
        }
    }
}

fn updateImage(st: *State, img: *Image, applied_pos: usize, preimage: *const Image, postimage: *const Image) Allocator.Error!void {
    const gpa = st.gpa;
    var preimage_limit = preimage.lines.items.len;
    if (preimage_limit > img.lines.items.len - applied_pos) preimage_limit = img.lines.items.len - applied_pos;
    var applied_at: usize = 0;
    for (img.lines.items[0..applied_pos]) |l| applied_at += l.len;
    var remove_count: usize = 0;
    for (img.lines.items[applied_pos .. applied_pos + preimage_limit]) |l| remove_count += l.len;
    try img.buf.replaceRange(gpa, applied_at, remove_count, postimage.buf.items);
    try img.lines.replaceRange(gpa, applied_pos, preimage_limit, postimage.lines.items);
    if (!st.options.allow_overlap) {
        for (img.lines.items[applied_pos .. applied_pos + postimage.lines.items.len]) |*l| l.flag |= line_patched;
    }
}

/// Place one hunk in `img`. Returns whether it applied.
fn applyOneFragment(st: *State, img: *Image, frag: patchparse.Fragment, inaccurate_eof: bool, ws_rule: whitespace.Rule, nth: usize, path: []const u8) Error!bool {
    const gpa = st.gpa;
    var preimage: Image = .{};
    defer preimage.deinit(gpa);
    var postimage: Image = .{};
    defer postimage.deinit(gpa);
    var new_blank_lines_at_end: usize = 0;
    var found_new_blank_lines_at_end: usize = 0;
    var hunk_linenr = frag.line;

    var text = frag.text;
    while (text.len > 0) {
        const len = linelen(text);
        if (len == 0) break;
        // the patch data: without the leading character, and without the
        // newline when a "\ No newline" line follows
        var plen: isize = @as(isize, @intCast(len)) - 1;
        if (len < text.len and text[len] == '\\') plen -= 1;
        var first = text[0];
        if (st.options.reverse) {
            if (first == '-') first = '+' else if (first == '+') first = '-';
        }
        var added_blank_line = false;
        var is_blank_context = false;
        const data: []const u8 = if (plen > 0) text[1..][0..@intCast(plen)] else "";
        switch (first) {
            '\n' => {
                if (plen >= 0) {
                    try preimage.buf.append(gpa, '\n');
                    try postimage.buf.append(gpa, '\n');
                    try preimage.addLine(gpa, "\n", line_common);
                    try postimage.addLine(gpa, "\n", line_common);
                    is_blank_context = true;
                }
            },
            ' ', '-' => {
                if (first == ' ' and plen > 0 and ws_rule & whitespace.blank_at_eof != 0 and whitespace.blankLine(data)) is_blank_context = true;
                try preimage.buf.appendSlice(gpa, data);
                try preimage.addLine(gpa, data, if (first == ' ') line_common else 0);
                if (first == ' ') {
                    try postimage.buf.appendSlice(gpa, data);
                    try postimage.addLine(gpa, data, line_common);
                }
            },
            '+' => {
                if (!st.options.no_add) {
                    const start = postimage.buf.items.len;
                    if (st.whitespace_error == 0 or st.ws_action != .correct) {
                        try postimage.buf.appendSlice(gpa, data);
                    } else {
                        if (try whitespace.fixCopy(gpa, &postimage.buf, data, ws_rule)) st.applied_after_fixing_ws += 1;
                    }
                    try postimage.addLine(gpa, postimage.buf.items[start..], 0);
                    if (ws_rule & whitespace.blank_at_eof != 0 and whitespace.blankLine(data)) added_blank_line = true;
                }
            },
            '@', '\\' => {},
            else => return false,
        }
        if (added_blank_line) {
            if (new_blank_lines_at_end == 0) found_new_blank_lines_at_end = hunk_linenr;
            new_blank_lines_at_end += 1;
        } else if (!is_blank_context) {
            new_blank_lines_at_end = 0;
        }
        text = text[len..];
        hunk_linenr += 1;
    }
    if (inaccurate_eof and preimage.buf.items.len > 0 and preimage.buf.items[preimage.buf.items.len - 1] == '\n' and
        postimage.buf.items.len > 0 and postimage.buf.items[postimage.buf.items.len - 1] == '\n')
    {
        _ = preimage.buf.pop();
        _ = postimage.buf.pop();
        preimage.lines.items[preimage.lines.items.len - 1].len -= 1;
        postimage.lines.items[postimage.lines.items.len - 1].len -= 1;
    }

    var leading = frag.leading;
    var trailing = frag.trailing;
    var match_beginning = frag.old_pos == 0 or (frag.old_pos == 1 and !st.options.unidiff_zero);
    var match_end = !st.options.unidiff_zero and trailing == 0;
    var pos: isize = if (frag.new_pos != 0) @as(isize, @intCast(frag.new_pos)) - 1 else 0;

    var applied_pos: ?usize = null;
    while (true) {
        applied_pos = try findPos(st, img, &preimage, &postimage, pos, ws_rule, match_beginning, match_end);
        if (applied_pos != null) break;
        if (leading <= st.p_context and trailing <= st.p_context) break;
        if (match_beginning or match_end) {
            match_beginning = false;
            match_end = false;
            continue;
        }
        if (leading >= trailing) {
            preimage.removeFirstLine();
            postimage.removeFirstLine();
            pos -= 1;
            leading -= 1;
        }
        if (trailing > leading) {
            preimage.removeLastLine();
            postimage.removeLastLine();
            trailing -= 1;
        }
    }
    const at = applied_pos orelse return false;

    if (new_blank_lines_at_end != 0 and preimage.lines.items.len + at >= img.lines.items.len and
        ws_rule & whitespace.blank_at_eof != 0 and st.ws_action != .nowarn)
    {
        try recordWs(st, whitespace.blank_at_eof, "", found_new_blank_lines_at_end);
        if (st.ws_action == .correct) {
            while (new_blank_lines_at_end > 0) : (new_blank_lines_at_end -= 1) postimage.removeLastLine();
        }
        if (st.ws_action == .die) st.apply = false;
    }
    const want: isize = pos;
    if (@as(isize, @intCast(at)) != want) {
        var offset: isize = @as(isize, @intCast(at)) - want;
        if (st.options.reverse) offset = -offset;
        try st.note(.{ .offset = .{ .path = path, .hunk = nth, .at = at + 1, .offset = offset } });
    }
    if (leading != frag.leading or trailing != frag.trailing) {
        try st.note(.{ .context_reduced = .{ .path = path, .leading = leading, .trailing = trailing, .at = at + 1 } });
    }
    try updateImage(st, img, at, &preimage, &postimage);
    return true;
}

//=========================================================================
// Binary patches
//=========================================================================

fn hashBlob(st: *State, bytes: []const u8) Oid {
    return hash.Hasher.object(st.repo.objectFormat(), "blob", bytes);
}

fn parseFullOid(st: *State, hex: []const u8) ?Oid {
    return Oid.parse(st.repo.objectFormat(), hex) catch null;
}

fn applyBinary(st: *State, img: *Image, entry: *Entry) Error!?Reason {
    const p = &entry.p;
    const old_oid = parseFullOid(st, p.old_oid_prefix);
    const new_oid = parseFullOid(st, p.new_oid_prefix);
    if (old_oid == null or new_oid == null) return .binary_needs_full_index;
    if (p.old_name != null) {
        if (!hashBlob(st, img.buf.items).eql(old_oid.?)) return .binary_preimage_mismatch;
    } else if (img.buf.items.len != 0) return .binary_not_empty;
    if (new_oid.?.isZero()) {
        img.clear();
        return null;
    }
    if (try st.repo.odb.exists(st.io, new_oid.?)) {
        const found = try st.repo.odb.read(st.io, new_oid.?);
        defer st.repo.odb.allocator().free(found.bytes);
        try img.prepare(st.gpa, found.bytes, false);
        return null;
    }
    const bin = p.binary orelse return .binary_missing_data;
    const hunk = if (st.options.reverse) (bin.reverse orelse return .binary_not_reversible) else bin.forward;
    const result = binarypatch.applyHunk(st.gpa, img.buf.items, hunk.method, hunk.data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .binary_wrong_result,
    };
    defer st.gpa.free(result);
    if (!hashBlob(st, result).eql(new_oid.?)) return .binary_wrong_result;
    try img.prepare(st.gpa, result, false);
    return null;
}

/// Apply every hunk of `entry` to `img`. Returns the reason it failed, or
/// `null`; under `reject` a hunk that does not apply is marked and the
/// rest go on.
fn applyFragments(st: *State, img: *Image, entry: *Entry) Error!?Reason {
    if (entry.p.is_binary) return applyBinary(st, img, entry);
    const name = entry.p.name();
    for (entry.p.fragments, 0..) |frag, i| {
        if (!try applyOneFragment(st, img, frag, entry.p.inaccurate_eof, entry.ws_rule, i + 1, name)) {
            if (!st.options.reject) return .does_not_apply;
            entry.frag_rejected[i] = true;
        }
    }
    return null;
}

//=========================================================================
// Reading what a patch applies to
//=========================================================================

fn previousPatch(st: *State, entry: *Entry, gone: *bool) ?PathState {
    gone.* = false;
    if (entry.p.is_copy or entry.p.is_rename) return null;
    const old = entry.p.old_name orelse return null;
    const previous = st.fn_table.get(old) orelse return null;
    switch (previous) {
        .to_be_deleted => return null,
        .was_deleted => gone.* = true,
        .patched => {},
    }
    return previous;
}

fn readBlobFor(st: *State, oid: Oid, mode: Mode, out: *std.ArrayList(u8)) Error!void {
    if (patchparse.isGitlink(mode)) {
        var hex: [hash.max_hex_len]u8 = undefined;
        try out.print(st.gpa, "Subproject commit {s}\n", .{oid.hex(&hex)});
        return;
    }
    const found = try st.repo.odb.read(st.io, oid);
    defer st.repo.odb.allocator().free(found.bytes);
    try out.appendSlice(st.gpa, found.bytes);
}

/// Read the working tree's copy of `path` as the repository would store
/// it: a symlink's target, or a file through the clean filters and line
/// endings, which `crlf_in_old` keeps.
fn readOldData(st: *State, path: []const u8, found: fs.Entry, crlf_in_old: bool, out: *std.ArrayList(u8)) Error!void {
    const wt = st.wt.?;
    switch (found.kind) {
        .sym_link => {
            var buf: [4096]u8 = undefined;
            const n = try wt.readLink(st.io, path, &buf);
            try out.appendSlice(st.gpa, buf[0..n]);
        },
        .file => {
            const bytes = try wt.readFileAlloc(st.io, path, st.gpa, .unlimited);
            defer st.gpa.free(bytes);
            if (crlf_in_old or st.rules.attrs == null) {
                try out.appendSlice(st.gpa, bytes);
                return;
            }
            var scratch: std.heap.ArenaAllocator = .init(st.gpa);
            defer scratch.deinit();
            const attrs = st.rules.attrs.?;
            try attrs.enter(st.io, wt, path);
            const applied = try attrs.lookup(scratch.allocator(), path, false);
            const converted = try st.conv.toGit(scratch.allocator(), path, bytes, applied, .hash_only);
            try out.appendSlice(st.gpa, converted.bytes);
        },
        else => return error.UnsupportedEntry,
    }
}

const Loaded = enum { ok, submodule_without_index };

fn loadPatchTarget(st: *State, out: *std.ArrayList(u8), ce: ?index_mod.Entry, found: ?fs.Entry, entry: *Entry, name: ?[]const u8, expected_mode: Mode) Error!Loaded {
    if (st.cached or st.check_index) {
        if (ce) |e| try readBlobFor(st, e.oid, @intFromEnum(e.mode), out);
    } else if (name) |n| {
        if (patchparse.isGitlink(expected_mode)) {
            if (ce) |e| {
                try readBlobFor(st, e.oid, @intFromEnum(e.mode), out);
                return .ok;
            }
            return .submodule_without_index;
        }
        try readOldData(st, n, found orelse return error.FileNotFound, entry.p.crlf_in_old, out);
    }
    return .ok;
}

fn loadPreimage(st: *State, img: *Image, entry: *Entry, found: ?fs.Entry, ce: ?index_mod.Entry) Error!?Reason {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(st.gpa);
    var gone = false;
    const previous = previousPatch(st, entry, &gone);
    if (gone) return .renamed_or_deleted;
    if (previous) |prev| {
        try buf.appendSlice(st.gpa, prev.patched.result.?);
    } else {
        switch (try loadPatchTarget(st, &buf, ce, found, entry, entry.p.old_name, entry.p.old_mode)) {
            .ok => {},
            .submodule_without_index => entry.p.fragments = &.{},
        }
    }
    try img.prepare(st.gpa, buf.items, !entry.p.is_binary);
    return null;
}

fn writeBlob(st: *State, bytes: []const u8) Error!Oid {
    return st.repo.odb.write(st.io, .blob, bytes);
}

fn threeWayMerge(st: *State, img: *Image, path: []const u8, base: Oid, ours: Oid, theirs: Oid) Error!bool {
    const db = &st.repo.odb;
    if (base.eql(ours)) {
        try resolveTo(st, img, theirs);
        return false;
    }
    if (base.eql(theirs) or ours.eql(theirs)) {
        try resolveTo(st, img, ours);
        return false;
    }
    const b = try db.read(st.io, base);
    defer db.allocator().free(b.bytes);
    const o = try db.read(st.io, ours);
    defer db.allocator().free(o.bytes);
    const t = try db.read(st.io, theirs);
    defer db.allocator().free(t.bytes);
    const style = if (st.repo.configuration().get("merge.conflictstyle")) |v| blobmerge.ConflictStyle.parse(v) orelse .merge else .merge;
    _ = path;
    var result = blobmerge.blobs(st.gpa, b.bytes, o.bytes, t.bytes, .{
        .conflict_style = style,
        .favor = st.options.favor,
    }) catch |err| switch (err) {
        error.BinaryBlob => {
            // ll_merge's binary driver: ours, or the favoured side, with a
            // conflict unless a side was favoured
            const chosen = if (st.options.favor == .theirs) t.bytes else o.bytes;
            try img.prepare(st.gpa, chosen, false);
            return st.options.favor == .none or st.options.favor == .union_;
        },
        else => |e| return e,
    };
    defer result.deinit();
    try img.prepare(st.gpa, result.bytes, false);
    return !result.isClean();
}

fn resolveTo(st: *State, img: *Image, oid: Oid) Error!void {
    const found = try st.repo.odb.read(st.io, oid);
    defer st.repo.odb.allocator().free(found.bytes);
    try img.prepare(st.gpa, found.bytes, false);
}

fn loadCurrent(st: *State, img: *Image, entry: *Entry) Error!bool {
    const name = entry.p.new_name.?;
    const ix = st.index.?;
    const ce = (ix.find(name) orelse return false).*;
    const wt = st.wt.?;
    var found = try fs.statAt(st.io, wt, name);
    if (found == null) {
        found = try checkoutTarget(st, ce);
    }
    if (try worktree.differsFromIndex(st.gpa, st.io, wt, ix, ce, st.rules)) return false;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(st.gpa);
    switch (try loadPatchTarget(st, &buf, ce, found, entry, name, entry.p.new_mode)) {
        .ok => {},
        .submodule_without_index => return false,
    }
    try img.prepare(st.gpa, buf.items, !entry.p.is_binary);
    return true;
}

/// git's `try_threeway`: `true` when the merge was made, conflicts or not.
fn tryThreeway(st: *State, img: *Image, entry: *Entry, found: ?fs.Entry, ce: ?index_mod.Entry) Error!bool {
    const p = &entry.p;
    if (p.is_delete == .yes or patchparse.isGitlink(p.old_mode) or patchparse.isGitlink(p.new_mode) or
        (p.is_new == .yes and !entry.direct_to_threeway) or
        (p.is_rename and p.lines_added == 0 and p.lines_deleted == 0)) return false;

    var pre_oid: Oid = undefined;
    var tmp: Image = .{};
    defer tmp.deinit(st.gpa);
    if (p.is_new == .yes) {
        pre_oid = try writeBlob(st, "");
        try tmp.prepare(st.gpa, "", true);
    } else {
        pre_oid = st.repo.odb.findPrefix(st.io, p.old_oid_prefix) catch return false;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(st.gpa);
        readBlobFor(st, pre_oid, p.old_mode, &buf) catch return false;
        try tmp.prepare(st.gpa, buf.items, true);
    }
    // the postimage the patch was made to give
    const saved_reject = st.options.reject;
    st.options.reject = false;
    const reason = try applyFragments(st, &tmp, entry);
    st.options.reject = saved_reject;
    if (reason != null) return false;
    const post_oid = try writeBlob(st, tmp.buf.items);

    var ours: Image = .{};
    defer ours.deinit(st.gpa);
    if (p.is_new == .yes) {
        if (!try loadCurrent(st, &ours, entry)) return false;
    } else {
        if (try loadPreimage(st, &ours, entry, found, ce) != null) return false;
    }
    const our_oid = try writeBlob(st, ours.buf.items);
    const conflicted = try threeWayMerge(st, img, p.new_name.?, pre_oid, our_oid, post_oid);
    if (conflicted) {
        entry.conflicted_threeway = true;
        entry.threeway_stage = .{ if (p.is_new == .yes) null else pre_oid, our_oid, post_oid };
    } else {
        entry.merged_threeway = true;
    }
    return true;
}

fn applyData(st: *State, entry: *Entry, found: ?fs.Entry, ce: ?index_mod.Entry) Error!?Reason {
    var img: Image = .{};
    defer img.deinit(st.gpa);
    if (try loadPreimage(st, &img, entry, found, ce)) |reason| return reason;
    var merged = false;
    if (st.options.three_way) {
        var merged_img: Image = .{};
        defer merged_img.deinit(st.gpa);
        if (try tryThreeway(st, &merged_img, entry, found, ce)) {
            merged = true;
            std.mem.swap(Image, &img, &merged_img);
        }
    }
    if (!merged) {
        if (entry.direct_to_threeway) return .does_not_apply;
        if (try applyFragments(st, &img, entry)) |reason| return reason;
    }
    entry.result = try st.a.dupe(u8, img.buf.items);
    try addToFnTable(st, entry);
    if (entry.p.is_delete == .yes and entry.result.?.len != 0) return .removal_leaves_contents;
    if (entry.p.is_delete != .yes and entry.result.?.len == 0 and entry.p.fragments.len != 0 and
        entry.p.lines_added == 0 and entry.p.is_new != .yes)
    {
        try st.note(.{ .becomes_empty = .{ .path = entry.p.new_name orelse entry.p.name() } });
    }
    return null;
}

fn addToFnTable(st: *State, entry: *Entry) Allocator.Error!void {
    if (entry.p.new_name) |n| try st.fn_table.put(st.a, n, .{ .patched = entry });
    if (entry.p.new_name == null or entry.p.is_rename) try st.fn_table.put(st.a, entry.p.old_name.?, .was_deleted);
}

fn prepareFnTable(st: *State, list: []const *Entry) Allocator.Error!void {
    for (list) |entry| {
        if (entry.p.new_name == null or entry.p.is_rename) try st.fn_table.put(st.a, entry.p.old_name.?, .to_be_deleted);
    }
}

fn prepareSymlinkChanges(st: *State, list: []const *Entry) Allocator.Error!void {
    for (list) |entry| {
        const p = &entry.p;
        if (p.old_name != null and patchparse.isSymlink(p.old_mode) and (p.is_rename or p.is_delete == .yes)) {
            try st.removed_symlinks.put(st.a, p.old_name.?, {});
        }
        if (p.new_name != null and patchparse.isSymlink(p.new_mode)) try st.kept_symlinks.put(st.a, p.new_name.?, {});
    }
}

fn pathIsBeyondSymlink(st: *State, name: []const u8) Error!bool {
    var len = name.len;
    while (true) {
        while (len > 0) {
            len -= 1;
            if (name[len] == '/') break;
        }
        if (len == 0) return false;
        const dir = name[0..len];
        if (st.kept_symlinks.contains(dir)) return true;
        if (st.removed_symlinks.contains(dir)) continue;
        if (st.check_index) {
            if (st.index.?.find(dir)) |e| {
                if (e.mode == .symlink) return true;
            }
        } else if (st.wt) |wt| {
            if (try fs.statAt(st.io, wt, dir)) |found| {
                if (found.kind == .sym_link) return true;
            }
        }
    }
}

fn modeOf(m: object.Mode) Mode {
    return @intFromEnum(m);
}

/// The mode a file on the disk stands for, as git's `ce_mode_from_stat`
/// decides it.
fn modeFromStat(st: *State, found: fs.Entry, ce: ?index_mod.Entry) Mode {
    switch (found.kind) {
        .sym_link => return patchparse.mode_symlink,
        .directory => return patchparse.mode_gitlink,
        else => {},
    }
    if (!st.rules.symlinks) if (ce) |e| if (e.mode == .symlink) return patchparse.mode_symlink;
    if (!st.rules.file_mode) {
        if (ce) |e| if (e.mode == .file or e.mode == .exec) return modeOf(e.mode);
        return patchparse.mode_file;
    }
    return if (found.executable) patchparse.mode_exec else patchparse.mode_file;
}

fn checkoutTarget(st: *State, ce: index_mod.Entry) Error!?fs.Entry {
    const wt = st.wt.?;
    var written = try worktree.writeEntry(st.gpa, st.io, wt, &st.repo.odb, &st.conv, ce.path, ce.mode, ce.oid, st.rules);
    if (st.index.?.find(ce.path)) |e| e.stat = written.stat;
    _ = &written;
    return fs.statAt(st.io, wt, ce.path);
}

const PreimageCheck = struct { reason: ?Reason = null, found: ?fs.Entry = null, ce: ?index_mod.Entry = null };

/// git's `check_preimage`: what the patch changes must be there, of the
/// right type, and, with the index, unchanged from it.
fn checkPreimage(st: *State, entry: *Entry) Error!PreimageCheck {
    var out: PreimageCheck = .{};
    const p = &entry.p;
    const old_name = p.old_name orelse return out;
    var gone = false;
    const previous = previousPatch(st, entry, &gone);
    if (gone) return .{ .reason = .renamed_or_deleted };
    var st_mode: Mode = 0;
    var stat_missing = false;
    if (previous) |prev| {
        st_mode = prev.patched.p.new_mode;
    } else if (!st.cached) {
        out.found = try fs.statAt(st.io, st.wt.?, old_name);
        stat_missing = out.found == null;
    }
    if (st.check_index and previous == null) {
        const e = st.index.?.find(old_name) orelse {
            if (p.is_new == .unknown) return isNew(p, out);
            return .{ .reason = .not_in_index };
        };
        out.ce = e.*;
        if (stat_missing) out.found = try checkoutTarget(st, e.*);
        if (!st.cached) {
            if (out.found) |f| {
                if (e.mode == .gitlink) {
                    if (f.kind != .directory) return .{ .reason = .does_not_match_index };
                } else if (try worktree.differsFromIndex(st.gpa, st.io, st.wt.?, st.index.?, e.*, st.rules)) {
                    return .{ .reason = .does_not_match_index };
                }
            }
        }
        if (st.cached) st_mode = modeOf(e.mode);
    } else if (stat_missing) {
        if (p.is_new == .unknown) return isNew(p, out);
        return .{ .reason = .does_not_exist };
    }
    if (!st.cached and previous == null) {
        st_mode = modeFromStat(st, out.found.?, out.ce);
    }
    if (p.is_new == .unknown) p.is_new = .no;
    if (p.old_mode == 0) p.old_mode = st_mode;
    if (patchparse.kind(st_mode) != patchparse.kind(p.old_mode)) return .{ .reason = .wrong_type };
    if (st_mode != p.old_mode) try st.note(.{ .mode_differs = .{ .path = old_name, .has = st_mode, .expected = p.old_mode } });
    if (p.new_mode == 0 and p.is_delete != .yes) p.new_mode = st_mode;
    return out;
}

fn isNew(p: *FilePatch, out: PreimageCheck) PreimageCheck {
    p.is_new = .yes;
    p.is_delete = .no;
    p.old_name = null;
    return out;
}

const CreateCheck = enum { ok, in_index, in_index_as_ita, in_worktree };

fn checkToCreate(st: *State, new_name: []const u8, ok_if_exists: bool) Error!CreateCheck {
    if (st.check_index and (!ok_if_exists or !st.cached)) {
        if (st.index.?.find(new_name)) |e| {
            if (!ok_if_exists and !e.intent_to_add) return .in_index;
            if (!st.cached and e.intent_to_add) return .in_index_as_ita;
        }
    }
    if (st.cached) return .ok;
    if (try fs.statAt(st.io, st.wt.?, new_name)) |found| {
        if (found.kind == .directory or ok_if_exists) return .ok;
        if (try hasSymlinkLeadingPath(st, new_name)) return .ok;
        return .in_worktree;
    }
    return .ok;
}

fn hasSymlinkLeadingPath(st: *State, name: []const u8) Error!bool {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, at, '/')) |slash| {
        if (try fs.statAt(st.io, st.wt.?, name[0..slash])) |f| {
            if (f.kind == .sym_link) return true;
        }
        at = slash + 1;
    }
    return false;
}

fn checkUnsafePath(p: *const FilePatch) bool {
    var old_name: ?[]const u8 = null;
    var new_name: ?[]const u8 = null;
    if (p.is_delete == .yes) {
        old_name = p.old_name;
    } else if (p.is_new != .yes and !p.is_copy) old_name = p.old_name;
    if (p.is_delete != .yes) new_name = p.new_name;
    if (old_name) |n| if (safepath.check(n, .worktree) != null) return false;
    if (new_name) |n| if (safepath.check(n, .worktree) != null) return false;
    return true;
}

/// git's `check_patch`. Returns whether the file applies.
fn checkPatch(st: *State, entry: *Entry) Error!bool {
    entry.rejected = true;
    const pre = try checkPreimage(st, entry);
    if (pre.reason) |r| return st.fail(entry, r);
    const p = &entry.p;
    const old_name = p.old_name;
    const new_name = p.new_name;
    var ok_if_exists = false;
    if (new_name) |n| {
        if (st.fn_table.get(n)) |t| switch (t) {
            .was_deleted, .to_be_deleted => ok_if_exists = true,
            .patched => {},
        };
    }
    if (new_name) |n| {
        if (p.is_new == .yes or p.is_rename or p.is_copy) {
            const err = try checkToCreate(st, n, ok_if_exists);
            if (err != .ok and st.options.three_way) {
                entry.direct_to_threeway = true;
            } else switch (err) {
                .ok => {},
                .in_index => return st.fail(entry, .already_in_index),
                .in_index_as_ita => return st.fail(entry, .does_not_match_index),
                .in_worktree => return st.fail(entry, .already_in_worktree),
            }
            if (p.new_mode == 0) p.new_mode = if (p.is_new == .yes) patchparse.mode_file else p.old_mode;
        }
    }
    if (new_name != null and old_name != null) {
        if (p.new_mode == 0) p.new_mode = p.old_mode;
        if (patchparse.kind(p.old_mode) != patchparse.kind(p.new_mode)) return st.fail(entry, .mode_mismatch);
    }
    const unsafe_ok = st.options.unsafe_paths and !st.check_index;
    if (!unsafe_ok and !checkUnsafePath(p)) return st.fail(entry, .invalid_path);
    if (p.is_delete != .yes) {
        if (try pathIsBeyondSymlink(st, p.new_name.?)) return st.fail(entry, .beyond_symlink);
    }
    if (try applyData(st, entry, pre.found, pre.ce)) |reason| return st.fail(entry, reason);
    entry.rejected = false;
    return true;
}

//=========================================================================
// Writing the results
//=========================================================================

fn objectMode(mode: Mode) object.Mode {
    return switch (patchparse.kind(mode)) {
        0o120000 => .symlink,
        0o160000 => .gitlink,
        else => if (mode & 0o100 != 0) .exec else .file,
    };
}

fn removeFile(st: *State, entry: *Entry, rmdir_empty: bool) Error!void {
    const old = entry.p.old_name.?;
    if (st.update_index and !st.options.intent_to_add) {
        const ix = st.index.?;
        (try ix.cacheTree()).invalidate(old);
        _ = ix.remove(old);
    }
    if (!st.cached) {
        const wt = st.wt.?;
        if (patchparse.isGitlink(entry.p.old_mode)) {
            wt.deleteDir(st.io, old) catch |err| switch (err) {
                error.DirNotEmpty, error.FileNotFound, error.NotDir => {},
                else => return err,
            };
        } else {
            wt.deleteFile(st.io, old) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => |e| return e,
            };
        }
        if (rmdir_empty) {
            if (std.fs.path.dirnamePosix(old)) |parent| removeEmptyDirectories(st.io, wt, parent);
        }
    }
}

fn removeEmptyDirectories(io: Io, wt: Io.Dir, path: []const u8) void {
    var current = path;
    while (current.len != 0) {
        wt.deleteDir(io, current) catch return;
        current = std.fs.path.dirnamePosix(current) orelse return;
    }
}

fn addIndexFile(st: *State, path: []const u8, mode: Mode, buf: []const u8, stat: fs.Stat) Error!void {
    const ix = st.index.?;
    var e: index_mod.Entry = .{ .path = path, .oid = undefined, .mode = objectMode(mode) };
    if (st.options.intent_to_add) {
        e.intent_to_add = true;
        e.oid = try writeBlob(st, "");
    } else if (patchparse.isGitlink(mode)) {
        const prefix = "Subproject commit ";
        if (!std.mem.startsWith(u8, buf, prefix)) return error.UnsupportedEntry;
        const hex_len = st.repo.objectFormat().hexLen();
        if (buf.len < prefix.len + hex_len) return error.UnsupportedEntry;
        e.oid = Oid.parse(st.repo.objectFormat(), buf[prefix.len..][0..hex_len]) catch return error.UnsupportedEntry;
    } else {
        if (!st.cached) e.stat = stat;
        e.oid = try writeBlob(st, buf);
    }
    (try ix.cacheTree()).invalidate(path);
    _ = ix.remove(path);
    try ix.add(e);
}

fn addConflictedStages(st: *State, entry: *Entry) Error!void {
    if (!st.update_index) return;
    const ix = st.index.?;
    const name = entry.p.new_name.?;
    const mode = if (entry.p.new_mode != 0) entry.p.new_mode else patchparse.mode_file;
    (try ix.cacheTree()).invalidate(name);
    _ = ix.remove(name);
    for (entry.threeway_stage, 0..) |maybe, i| {
        const oid = maybe orelse continue;
        try ix.add(.{ .path = name, .oid = oid, .mode = objectMode(mode), .stage = @intCast(i + 1) });
    }
}

fn createFile(st: *State, entry: *Entry) Error!void {
    const path = entry.p.new_name.?;
    var mode = entry.p.new_mode;
    if (mode == 0) mode = patchparse.mode_file;
    const buf = entry.result.?;
    var stat: fs.Stat = .none;
    if (!st.cached) {
        if (try pathIsBeyondSymlink(st, path)) return error.UnsafePath;
        const written = try worktree.writeBytes(st.gpa, st.io, st.wt.?, &st.conv, path, objectMode(mode), buf, st.rules);
        stat = written.stat;
    }
    if (entry.conflicted_threeway) return addConflictedStages(st, entry);
    if (st.check_index or (st.options.intent_to_add and entry.p.is_new == .yes)) {
        if (st.update_index) try addIndexFile(st, path, mode, buf, stat);
    }
}

fn writeOutOneResult(st: *State, entry: *Entry, phase: u1) Error!void {
    const p = &entry.p;
    if (p.is_delete == .yes) {
        if (phase == 0) try removeFile(st, entry, true);
        return;
    }
    if (p.is_new == .yes or p.is_copy) {
        if (phase == 1) try createFile(st, entry);
        return;
    }
    if (phase == 0) try removeFile(st, entry, p.is_rename);
    if (phase == 1) try createFile(st, entry);
}

fn writeOutOneReject(st: *State, entry: *Entry) Error!void {
    var count: usize = 0;
    for (entry.frag_rejected) |r| count += @intFromBool(r);
    if (count == 0) return;
    const name = entry.p.new_name.?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(st.gpa);
    try out.print(st.gpa, "diff a/{s} b/{s}\t(rejected hunks)\n", .{ name, name });
    for (entry.p.fragments, entry.frag_rejected) |frag, rejected| {
        if (!rejected) continue;
        try out.appendSlice(st.gpa, frag.text);
        if (frag.text.len == 0 or frag.text[frag.text.len - 1] != '\n') try out.append(st.gpa, '\n');
    }
    const rej = try std.fmt.allocPrint(st.a, "{s}.rej", .{name});
    st.wt.?.deleteFile(st.io, rej) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try st.wt.?.writeFile(st.io, .{ .sub_path = rej, .data = out.items, .flags = .{ .exclusive = true } });
}

fn writeOutResults(st: *State, list: []const *Entry, conflicted: *std.ArrayList([]const u8)) Error!void {
    for ([_]u1{ 0, 1 }) |phase| {
        for (list) |entry| {
            if (entry.rejected) continue;
            try writeOutOneResult(st, entry, phase);
            if (phase == 1) {
                if (st.options.reject and !st.cached) try writeOutOneReject(st, entry);
                if (entry.conflicted_threeway) try conflicted.append(st.a, entry.p.new_name.?);
            }
        }
    }
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("../testing/git.zig");

const Fixture = struct {
    git: testgit.Repo,
    repo: Repository,

    fn init(gpa: Allocator, io: Io) !Fixture {
        var git = try testgit.Repo.init(gpa, io, &.{});
        errdefer git.deinit();
        const repo = try Repository.open(gpa, io, git.dir, .{});
        return .{ .git = git, .repo = repo };
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.repo.deinit(io);
        f.git.deinit();
    }

    fn reopen(f: *Fixture, gpa: Allocator, io: Io) !void {
        f.repo.deinit(io);
        f.repo = try Repository.open(gpa, io, f.git.dir, .{});
    }
};

fn writeFiles(io: Io, dir: Io.Dir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirnamePosix(f[0])) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
}

test "a patch git made applies here to the bytes git apply leaves, and a stale one leaves everything as it was" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit(io);
    const base = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n";
    try writeFiles(io, f.git.dir, &.{ .{ "a.txt", base }, .{ "gone.txt", "bye\n" }, .{ "dir/old.txt", "moved\n" } });
    try f.git.exec(io, &.{ "add", "-A" });
    try f.git.exec(io, &.{ "commit", "-q", "-m", "base" });
    try writeFiles(io, f.git.dir, &.{
        .{ "a.txt", "zero\none\ntwo\nthree\nFOUR\nfive\nsix\nseven\neight\nnine\nten\neleven\n" },
        .{ "new.txt", "fresh\n" },
    });
    try f.git.dir.deleteFile(io, "gone.txt");
    try f.git.exec(io, &.{ "mv", "dir/old.txt", "dir/new.txt" });
    try f.git.exec(io, &.{ "add", "-A" });
    const patch = try f.git.run(io, &.{ "diff", "--cached", "-M", "HEAD" });
    defer gpa.free(patch);
    try f.git.exec(io, &.{ "commit", "-q", "-m", "change" });
    const expected = try f.git.run(io, &.{ "ls-tree", "-r", "HEAD" });
    defer gpa.free(expected);
    try f.git.exec(io, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try f.reopen(gpa, io);

    var outcome = try apply(gpa, io, &f.repo, patch, .{ .target = .index });
    defer outcome.deinit();
    try std.testing.expect(outcome.clean());
    try std.testing.expectEqual(@as(usize, 4), outcome.files.len);
    const tree = try f.git.run(io, &.{"write-tree"});
    defer gpa.free(tree);
    const listed = try f.git.run(io, &.{ "ls-tree", "-r", std.mem.trimEnd(u8, tree, "\n") });
    defer gpa.free(listed);
    try std.testing.expectEqualStrings(expected, listed);
    const status = try f.git.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try std.testing.expectEqualStrings("M  a.txt\nR  dir/old.txt -> dir/new.txt\nD  gone.txt\nA  new.txt\n", status);

    // the same patch again does not apply, and nothing moves
    var diag = Diagnostic.init(gpa);
    defer diag.deinit();
    try std.testing.expectError(error.PatchDoesNotApply, apply(gpa, io, &f.repo, patch, .{ .diagnostic = &diag }));
    try std.testing.expect(diag.failures.items.len >= 1);
    const after = try f.git.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(after);
    try std.testing.expectEqualStrings(status, after);
}
