//! `git bisect`: finding the commit that changed something by halving the
//! history between one that has it and some that do not.
//!
//! The state is git's, file for file, so either tool carries on a bisection
//! the other started: `BISECT_START`, `BISECT_TERMS`, `BISECT_NAMES`,
//! `BISECT_LOG`, `BISECT_ANCESTORS_OK`, `BISECT_FIRST_PARENT`, `BISECT_RUN`,
//! the pseudo-refs `BISECT_EXPECTED_REV` and `BISECT_HEAD`, and
//! `refs/bisect/<bad>`, `refs/bisect/<good>-<name>` and
//! `refs/bisect/skip-<name>`. The commit to test next is the one git picks:
//! the walk from the bad commit less the good ones, in `git rev-list`'s
//! order, each commit weighed by how many of the others it reaches, the
//! first found within a hair of halfway taken as git takes it; with skipped
//! commits every weight is computed and git's pseudo-random step away from
//! a skipped one is taken. Good commits that are not ancestors of the bad
//! one have their merge bases checked first, as git checks them.
//!
//! A step checks the commit out as `git checkout` does, `HEAD` detached
//! with git's `checkout: moving from … to …` line in its log, or, after
//! `--no-checkout`, moves `BISECT_HEAD`; with `--reset-when-found`, the
//! command that finds the first bad commit goes back as `reset` would. The
//! behaviour is git 2.56's, the newest release. What git prints is returned as
//! `Report.text`, the same lines; where git then runs `git show` on the
//! commit it found, the commit is in `Report.step` for the caller to show,
//! and `BISECT_RUN` holds the lines before it. Pathspecs limit the walk
//! as git's do: `BISECT_NAMES` holds them as git writes them, the walk is
//! simplified to the commits that change them, and a commit that does not
//! is neither counted nor tested.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const revparse = @import("revparse.zig");
const revwalk = @import("../walk.zig");
const message = @import("../object/message.zig");
const head_mod = @import("../repo/head.zig");
const threeway = @import("../merge/threeway.zig");
const hooks = @import("../hooks/hooks.zig");
const program = @import("../process.zig").program;
const ref_names = @import("../names.zig").ref;
const pathspec = @import("../patterns.zig").pathspec;

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from bisecting.
pub const Error = error{
    /// No bisection is in progress: `You need to start by "git bisect
    /// start"`.
    NotBisecting,
    /// `git bisect start` with an option it does not know.
    UnrecognizedOption,
    /// A revision that names no commit.
    BadRevision,
    /// More than one revision for the bad term.
    TooManyBadRevisions,
    /// A term git refuses: not a ref name, a subcommand's name, the two
    /// the same, or `good`/`bad` given each other's meaning.
    InvalidTerm,
    /// `BISECT_TERMS` names other terms than the one used.
    InvalidCommand,
    /// No terms are recorded.
    NoTermsDefined,
    /// `BISECT_NAMES` holds a line that does not unquote: git's "Badly
    /// quoted content".
    MalformedNames,
    /// `HEAD` names no commit to start from.
    BadHead,
    /// No bad commit is known.
    BadRevisionNeeded,
    /// A merge base of the good and bad commits is bad: the change is
    /// older than the good ones.
    BadMergeBase,
    /// Some good commits are not ancestors of the bad one.
    GoodNotAncestorOfBad,
    /// The bad commit was also given as good.
    BothGoodAndBad,
    /// Nothing between good and bad to test.
    NoTestableCommit,
    /// Both a good and a bad commit are needed to go on.
    NeedGoodAndBad,
    /// `run` with no command.
    NoCommand,
    /// The command exited with 128 or more, or could not be run on the
    /// good commit either.
    RunFailed,
    /// `bisect run` was left with only skipped commits.
    RunCannotContinue,
    /// `git bisect log` with no bisection.
    NoLog,
    /// A `replay` line git does not know.
    InvalidReplayLine,
    /// `--reset-when-found=` neither `original` nor `found`.
    InvalidResetWhenFound,
    /// `--reset-when-found` with `--no-checkout`, which git refuses
    /// together.
    ResetWhenFoundWithoutCheckout,
} || Allocator.Error || pathspec.Error || refs_mod.TransactionError || refs_mod.ReadError || repo_mod.Error || revparse.Error ||
    revwalk.Error || head_mod.Error || threeway.Error || hooks.Error || program.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.DeleteFileError || Io.File.OpenError;

/// What a bisection command needs from the caller.
pub const Options = struct {
    /// Who moves `HEAD`, for its log, and when.
    who: object.Signature,
    /// `post-checkout` and `reference-transaction`, or `null` for none.
    hooks: ?*hooks.Runner = null,
    /// Where a checkout that would lose a change writes the path.
    blocked: ?*threeway.Blocked = null,
};

/// Where `--reset-when-found` goes once the first bad commit is found:
/// back to where the bisection started, or to the commit found.
pub const ResetWhenFound = enum {
    original,
    found,

    pub fn parse(text: []const u8) ?ResetWhenFound {
        if (std.mem.eql(u8, text, "original")) return .original;
        if (std.mem.eql(u8, text, "found")) return .found;
        return null;
    }
};

/// The two words a bisection is in, `bad` and `good` or the caller's.
pub const Terms = struct {
    bad: []const u8 = "bad",
    good: []const u8 = "good",
};

/// Where a command left the bisection.
pub const Step = union(enum) {
    /// Waiting for a good or a bad commit: git's `status:` line.
    waiting,
    /// The commit now checked out to be tested.
    testing: Oid,
    /// A merge base of the good and bad commits, checked out to be tested
    /// first.
    merge_base: Oid,
    /// The first bad commit, found.
    first_bad: Oid,
    /// Only skipped commits are left; the first bad one is among them.
    only_skipped: []const Oid,
};

/// What a command did: the step it left the bisection at, and what git
/// prints on its standard output for it.
pub const Report = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    step: Step,
    /// git's standard output, line for line, less the `git show` of a
    /// first bad commit, which `step` names.
    text: []const u8,

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    a: Allocator,
    options: Options,
    out: *std.ArrayList(u8),

    fn print(c: *Ctx, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try c.out.print(c.a, fmt, args);
    }

    fn dir(c: *Ctx) Io.Dir {
        return c.repo.gitDirectory();
    }

    fn readState(c: *Ctx, name: []const u8) Error!?[]u8 {
        return c.dir().readFileAlloc(c.io, name, c.a, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
    }

    fn emptyOrMissing(c: *Ctx, name: []const u8) Error!bool {
        const text = (try c.readState(name)) orelse return true;
        return text.len == 0;
    }

    fn exists(c: *Ctx, name: []const u8) bool {
        _ = c.dir().statFile(c.io, name, .{}) catch return false;
        return true;
    }

    fn writeState(c: *Ctx, name: []const u8, bytes: []const u8) Error!void {
        try head_mod.writeState(c.io, c.dir(), name, bytes);
    }

    fn appendState(c: *Ctx, name: []const u8, bytes: []const u8) Error!void {
        const before = (try c.readState(name)) orelse "";
        try c.writeState(name, try std.mem.concat(c.a, u8, &.{ before, bytes }));
    }

    fn removeState(c: *Ctx, name: []const u8) Error!void {
        c.dir().deleteFile(c.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    fn hex(c: *Ctx, oid: Oid) Allocator.Error![]const u8 {
        var buf: [hash.max_hex_len]u8 = undefined;
        return c.a.dupe(u8, oid.hex(&buf));
    }

    /// `%s` of a commit.
    fn subject(c: *Ctx, oid: Oid) Error![]const u8 {
        const found = try c.repo.objectDatabase().read(c.io, oid);
        defer c.repo.objectDatabase().allocator().free(found.bytes);
        var commit = try object.Commit.parse(c.gpa, c.repo.objectFormat(), found.bytes);
        defer commit.deinit();
        return message.onelineSubject(c.a, commit.message);
    }

    /// The commit `rev` names, peeled.
    fn commitOf(c: *Ctx, rev: []const u8) Error!Oid {
        const oid = revparse.resolve(c.gpa, c.io, c.repo, rev) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadRevision,
        };
        const peeled = c.repo.peel(c.io, oid) catch return error.BadRevision;
        const header = c.repo.objectDatabase().readHeader(c.io, peeled) catch return error.BadRevision;
        if (header.type != .commit) return error.BadRevision;
        return peeled;
    }

    fn readRef(c: *Ctx, name: []const u8) Error!?Oid {
        return c.repo.refStore().readOid(c.a, c.io, name);
    }

    fn updateRef(c: *Ctx, name: []const u8, oid: Oid) Error!void {
        var tx = c.repo.beginRefs();
        defer tx.deinit(c.io);
        tx.hooks = c.options.hooks;
        try tx.update(name, .{ .direct = oid }, .any);
        try tx.commit(c.io, null);
    }

    /// The root refs, written and removed with the caller's hooks told,
    /// as each of git's ref updates tells `reference-transaction`.
    fn roots(c: *Ctx) refs_mod.RootRefs {
        var r = c.repo.refStore().root();
        r.hooks = c.options.hooks;
        return r;
    }
};

fn begin(gpa: Allocator, io: Io, repo: *Repository, options: Options, arena: *std.heap.ArenaAllocator, out: *std.ArrayList(u8)) Ctx {
    return .{ .gpa = gpa, .io = io, .repo = repo, .a = arena.allocator(), .options = options, .out = out };
}

fn finish(arena: std.heap.ArenaAllocator, out: std.ArrayList(u8), step: Step) Report {
    return .{ .arena = arena, .step = step, .text = out.items };
}

/// What git does after any command that found the first bad commit: with
/// `BISECT_RESET_WHEN_FOUND`, go back where it says and end the bisection.
fn resetWhenFound(c: *Ctx, step: Step) Error!void {
    if (step != .first_bad) return;
    const text = (try c.readState("BISECT_RESET_WHEN_FOUND")) orelse return;
    if (text.len == 0) return;
    const mode = ResetWhenFound.parse(std.mem.trim(u8, text, " \t\n\r")) orelse return error.InvalidResetWhenFound;
    const target: ?[]const u8 = switch (mode) {
        .original => null,
        .found => try c.a.print("refs/bisect/{s}", .{(try readTerms(c)).bad}),
    };
    try resetTo(c, target);
}

// ---------------------------------------------------------------------------
// Terms.

fn isBuiltin(term: []const u8) bool {
    for ([_][]const u8{ "help", "start", "skip", "next", "reset", "visualize", "view", "replay", "log", "run", "terms" }) |w| {
        if (std.mem.eql(u8, term, w)) return true;
    }
    return false;
}

fn oneOf(term: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, term, w)) return true;
    return false;
}

/// `check_term_format`.
fn checkTerm(c: *Ctx, term: []const u8, orig: []const u8) Error!void {
    const ref = try std.mem.concat(c.a, u8, &.{ "refs/bisect/", term });
    if (!ref_names.checkFormat(ref, .{})) return error.InvalidTerm;
    if (isBuiltin(term)) return error.InvalidTerm;
    if ((!std.mem.eql(u8, orig, "bad") and oneOf(term, &.{ "bad", "new" })) or
        (!std.mem.eql(u8, orig, "good") and oneOf(term, &.{ "good", "old" }))) return error.InvalidTerm;
}

/// `write_terms`.
fn writeTerms(c: *Ctx, bad: []const u8, good: []const u8) Error!void {
    if (std.mem.eql(u8, bad, good)) return error.InvalidTerm;
    try checkTerm(c, bad, "bad");
    try checkTerm(c, good, "good");
    try c.writeState("BISECT_TERMS", try c.a.print("{s}\n{s}\n", .{ bad, good }));
}

/// `get_terms`: the terms `BISECT_TERMS` records, or `null` when there is
/// no such file.
fn getTerms(c: *Ctx) Error!?Terms {
    const text = (try c.readState("BISECT_TERMS")) orelse return null;
    // `strbuf_getline_lf` twice; a line missing is no terms at all.
    var at: usize = 0;
    var lines: [2][]const u8 = .{ "", "" };
    for (&lines) |*line| {
        if (at >= text.len) return error.NoTermsDefined;
        const end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
        line.* = text[at..end];
        at = end + 1;
    }
    return .{ .bad = lines[0], .good = lines[1] };
}

/// `read_bisect_terms`: `bad` and `good` when nothing is recorded.
fn readTerms(c: *Ctx) Error!Terms {
    return (try getTerms(c)) orelse .{};
}

/// `check_and_set_terms`.
fn checkAndSetTerms(c: *Ctx, t: *Terms, cmd: []const u8) Error!void {
    if (oneOf(cmd, &.{ "skip", "start", "terms" })) return;
    const has_file = !try c.emptyOrMissing("BISECT_TERMS");
    if (has_file and !std.mem.eql(u8, cmd, t.bad) and !std.mem.eql(u8, cmd, t.good)) return error.InvalidCommand;
    if (!has_file) {
        if (oneOf(cmd, &.{ "bad", "good" })) {
            t.* = .{ .bad = "bad", .good = "good" };
            return writeTerms(c, t.bad, t.good);
        }
        if (oneOf(cmd, &.{ "new", "old" })) {
            t.* = .{ .bad = "new", .good = "old" };
            return writeTerms(c, t.bad, t.good);
        }
    }
}

/// The terms of the bisection in progress, from `BISECT_TERMS`, or `null`
/// when none are recorded: `git bisect terms`.
pub fn terms(gpa: Allocator, io: Io, repo: *Repository) Self.Error!?struct { bad: []u8, good: []u8 } {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, .{ .who = undefined }, &arena, &out);
    const t = (try getTerms(&c)) orelse return null;
    const bad = try gpa.dupe(u8, t.bad);
    errdefer gpa.free(bad);
    return .{ .bad = bad, .good = try gpa.dupe(u8, t.good) };
}

// ---------------------------------------------------------------------------
// State.

/// `bisect_clean_state`: every ref and file a bisection keeps, removed;
/// `BISECT_START` last.
fn cleanState(c: *Ctx) Error!void {
    const store = c.repo.refStore();
    var listing = try store.list(c.gpa, c.io, "refs/bisect/");
    defer listing.deinit();
    if (listing.entries.len != 0) {
        var tx = c.repo.beginRefs();
        defer tx.deinit(c.io);
        tx.hooks = c.options.hooks;
        for (listing.entries) |e| try tx.change(e.name, null, .any, .{ .no_deref = true });
        try tx.commit(c.io, null);
    }
    try c.roots().delete(c.gpa, c.io, .bisect_head);
    try c.roots().delete(c.gpa, c.io, .bisect_expected_rev);
    for ([_][]const u8{ "BISECT_ANCESTORS_OK", "BISECT_LOG", "BISECT_NAMES", "BISECT_RUN", "BISECT_TERMS", "BISECT_FIRST_PARENT", "BISECT_RESET_WHEN_FOUND", "BISECT_START" }) |name| {
        try c.removeState(name);
    }
}

/// `bisect_write`: the ref for `state` at `rev`, and its lines in
/// `BISECT_LOG`.
fn bisectWrite(c: *Ctx, state: []const u8, rev: []const u8, t: Terms, nolog: bool) Error!void {
    const tag = if (std.mem.eql(u8, state, t.bad))
        try c.a.print("refs/bisect/{s}", .{state})
    else if (oneOf(state, &.{ t.good, "skip" }))
        try c.a.print("refs/bisect/{s}-{s}", .{ state, rev })
    else
        return error.InvalidCommand;
    const oid = revparse.resolve(c.gpa, c.io, c.repo, rev) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadRevision,
    };
    try c.updateRef(tag, oid);
    const commit = c.repo.peel(c.io, oid) catch return error.BadRevision;
    var line: std.ArrayList(u8) = .empty;
    try line.print(c.a, "# {s}: [{s}] {s}\n", .{ state, try c.hex(commit), try c.subject(commit) });
    if (!nolog) try line.print(c.a, "git bisect {s} {s}\n", .{ state, rev });
    try c.appendState("BISECT_LOG", line.items);
}

const Known = struct { good: usize = 0, bad: bool = false };

/// `bisect_status`.
fn status(c: *Ctx, t: Terms) Error!Known {
    var known: Known = .{};
    const bad_ref = try c.a.print("refs/bisect/{s}", .{t.bad});
    if (try c.readRef(bad_ref) != null) known.bad = true;
    const good_prefix = try c.a.print("refs/bisect/{s}-", .{t.good});
    var listing = try c.repo.refStore().list(c.gpa, c.io, "refs/bisect/");
    defer listing.deinit();
    for (listing.entries) |e| {
        if (std.mem.startsWith(u8, e.name, good_prefix)) known.good += 1;
    }
    return known;
}

/// `bisect_log_printf`: printed, and kept in the log behind `# `.
fn logPrint(c: *Ctx, comptime fmt: []const u8, args: anytype) Error!void {
    const text = try c.a.print(fmt, args);
    try c.out.appendSlice(c.a, text);
    try c.appendState("BISECT_LOG", try std.mem.concat(c.a, u8, &.{ "# ", text }));
}

/// `bisect_print_status`.
fn printStatus(c: *Ctx, t: Terms) Error!void {
    const known = try status(c, t);
    if (known.good != 0 and known.bad) return;
    if (known.good == 0 and !known.bad) {
        try logPrint(c, "status: waiting for both '{s}' and '{s}' commits\n", .{ t.good, t.bad });
    } else if (known.good != 0) {
        try logPrint(c, "status: waiting for '{s}' commit, {d} '{s}' {s} known\n", .{ t.bad, known.good, t.good, if (known.good == 1) "commit" else "commits" });
    } else {
        try logPrint(c, "status: waiting for '{s}' commit(s), '{s}' commit known\n", .{ t.good, t.bad });
    }
}

/// `bisect_next_check` and `decide_next`: whether to go on, with a
/// missing good commit allowed when the command was the good term, as git
/// allows it off a terminal.
fn nextCheck(c: *Ctx, t: Terms, current_term: ?[]const u8) Error!bool {
    const known = try status(c, t);
    if (known.good != 0 and known.bad) return true;
    const term = current_term orelse return false;
    if (known.good == 0 and known.bad and std.mem.eql(u8, term, t.good)) return true;
    return error.NeedGoodAndBad;
}

/// `bisect_auto_next`.
fn autoNext(c: *Ctx, t: Terms) Error!Step {
    if (!try nextCheck(c, t, null)) {
        try printStatus(c, t);
        return .waiting;
    }
    return next(c, t);
}

/// `bisect_next`.
fn next(c: *Ctx, t: Terms) Error!Step {
    if (try c.emptyOrMissing("BISECT_START")) return error.NotBisecting;
    _ = try nextCheck(c, t, t.good);
    const step = try nextAll(c, t);
    switch (step) {
        .first_bad => |oid| try c.appendState("BISECT_LOG", try c.a.print("# first '{s}' commit: [{s}] {s}\n", .{ t.bad, try c.hex(oid), try c.subject(oid) })),
        .only_skipped => try skippedCommits(c, t),
        else => {},
    }
    return step;
}

/// `bisect_skipped_commits`: the commits left, in the log.
fn skippedCommits(c: *Ctx, t: Terms) Error!void {
    var walk: revwalk.Walk = .init(c.gpa, c.repo.objectDatabase());
    defer walk.deinit();
    var listing = try c.repo.refStore().list(c.gpa, c.io, "refs/bisect/");
    defer listing.deinit();
    const bad_prefix = try c.a.print("refs/bisect/{s}", .{t.bad});
    const good_prefix = try c.a.print("refs/bisect/{s}-", .{t.good});
    for (listing.entries) |e| if (std.mem.startsWith(u8, e.name, bad_prefix)) {
        if (e.target == .direct) try walk.push(e.target.direct);
    };
    for (listing.entries) |e| if (std.mem.startsWith(u8, e.name, good_prefix)) {
        if (e.target == .direct) try walk.hide(e.target.direct);
    };
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(c.a, "# only skipped commits left to test\n");
    while (try walk.next(c.io)) |commit| {
        try text.print(c.a, "# possible first '{s}' commit: [{s}] {s}\n", .{ t.bad, try c.hex(commit.oid), try c.subject(commit.oid) });
    }
    try c.appendState("BISECT_LOG", text.items);
}

// ---------------------------------------------------------------------------
// git's bisect.c.

const Revs = struct {
    bad: ?Oid = null,
    good: std.ArrayList(Oid) = .empty,
    skipped: std.ArrayList(Oid) = .empty,

    fn isSkipped(r: *const Revs, oid: Oid) bool {
        for (r.skipped.items) |s| if (s.eql(oid)) return true;
        return false;
    }
    fn isGood(r: *const Revs, oid: Oid) bool {
        for (r.good.items) |s| if (s.eql(oid)) return true;
        return false;
    }
};

/// `read_bisect_refs`.
fn readRefs(c: *Ctx, t: Terms) Error!Revs {
    var revs: Revs = .{};
    var listing = try c.repo.refStore().list(c.gpa, c.io, "refs/bisect/");
    defer listing.deinit();
    const good_prefix = try c.a.print("{s}-", .{t.good});
    for (listing.entries) |e| {
        const name = e.name["refs/bisect/".len..];
        const oid = switch (e.target) {
            .direct => |o| o,
            .symbolic => continue,
        };
        if (std.mem.eql(u8, name, t.bad)) {
            revs.bad = oid;
        } else if (std.mem.startsWith(u8, name, good_prefix)) {
            try revs.good.append(c.a, oid);
        } else if (std.mem.startsWith(u8, name, "skip-")) {
            try revs.skipped.append(c.a, oid);
        }
    }
    return revs;
}

/// The commits `bisect_rev_setup` walks, git's `revs.commits`: from the bad
/// commit, less the good ones, `git rev-list` order.
const Listed = struct {
    commits: []const Oid,
    parents: Oid.Map([]const Oid),
    hidden: Oid.Set,
    /// With pathspecs, the commits that change none of the paths.
    treesame: Oid.Set,
};

/// `read_bisect_paths`: the pathspecs in `BISECT_NAMES`, each line
/// unquoted as git unquotes it.
fn readPaths(c: *Ctx) Error![]const []const u8 {
    const text = (try c.readState("BISECT_NAMES")) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        const words = (try sqDequote(c.a, std.mem.trim(u8, line, " \t\r\x0b\x0c"))) orelse return error.MalformedNames;
        try out.appendSlice(c.a, words);
    }
    return out.items;
}

fn listCommits(c: *Ctx, revs: *const Revs, first_parent: bool) Error!Listed {
    var walk: revwalk.Walk = .init(c.gpa, c.repo.objectDatabase());
    defer walk.deinit();
    walk.first_parent = first_parent;
    const specs = try readPaths(c);
    var paths = try pathspec.parse(c.gpa, specs);
    defer paths.deinit();
    if (specs.len != 0) walk.paths = &paths;
    try walk.push(revs.bad.?);
    for (revs.good.items) |g| try walk.hide(g);
    var listed: Listed = .{ .commits = &.{}, .parents = .empty, .hidden = .empty, .treesame = .empty };
    var commits: std.ArrayList(Oid) = .empty;
    while (try walk.next(c.io)) |commit| {
        try commits.append(c.a, commit.oid);
        if (commit.treesame) try listed.treesame.put(c.a, commit.oid, {});
        try listed.parents.put(c.a, commit.oid, try c.a.dupe(Oid, commit.parents));
    }
    // What the walk marked as reached from a good commit, among the
    // parents of what it listed: git's `UNINTERESTING`.
    for (commits.items) |oid| for (listed.parents.get(oid).?) |p| {
        if (walk.isHidden(p)) try listed.hidden.put(c.a, p, {});
    };
    listed.commits = commits.items;
    return listed;
}

/// `find_bisection`'s result.
const Bisection = struct {
    /// The best first; every candidate, best first, with skipped commits.
    list: []const Oid,
    reaches: i64,
    all: i64,
};

/// `find_bisection`. A TREESAME commit, one that changes none of the
/// pathspecs, is on the list but not counted, and is never the answer
/// unless nothing else is on it.
fn findBisection(c: *Ctx, listed: *const Listed, first_parent: bool, find_all: bool) Error!Bisection {
    // The list reversed, oldest first.
    const n = listed.commits.len;
    const list = try c.a.alloc(Oid, n);
    for (listed.commits, 0..) |oid, i| list[n - 1 - i] = oid;
    var nr: i64 = 0;
    for (list) |oid| {
        if (!listed.treesame.contains(oid)) nr += 1;
    }
    if (n == 0) return .{ .list = &.{}, .reaches = 0, .all = 0 };

    var weight: Oid.Map(i64) = .empty;
    const interesting = struct {
        fn f(l: *const Listed, p: Oid) bool {
            return !l.hidden.contains(p);
        }
    }.f;
    var counted: i64 = 0;
    for (list) |oid| {
        var count: usize = 0;
        for (listed.parents.get(oid).?) |p| {
            if (interesting(listed, p)) count += 1;
            if (first_parent) break;
        }
        switch (count) {
            0 => if (!listed.treesame.contains(oid)) {
                try weight.put(c.a, oid, 1);
                counted += 1;
            } else {
                // It reaches no commit that changes the paths.
                try weight.put(c.a, oid, 0);
            },
            1 => try weight.put(c.a, oid, -1),
            else => try weight.put(c.a, oid, -2),
        }
    }

    const halfway = struct {
        fn f(l: *const Listed, oid: Oid, w: i64, all: i64) bool {
            if (l.treesame.contains(oid)) return false;
            const diff = 2 * w - all;
            if (diff >= -1 and diff <= 1) return true;
            return @abs(diff) < @divTrunc(all, 1024);
        }
    }.f;

    // Merges first, the expensive way: everything they reach.
    for (list) |oid| {
        if (weight.get(oid).? != -2) continue;
        const w = try countDistance(c, listed, oid);
        try weight.put(c.a, oid, w);
        if (!find_all and halfway(listed, oid, w, nr)) return single(c, oid, w, nr);
        counted += 1;
    }
    // Then a strand of pearls one more than the commit below it.
    while (counted < nr) {
        for (list) |oid| {
            if (weight.get(oid).? >= 0) continue;
            var below: ?i64 = null;
            for (listed.parents.get(oid).?) |p| {
                if (!interesting(listed, p)) {
                    if (first_parent) break;
                    continue;
                }
                const wq = weight.get(p) orelse -1;
                if (wq >= 0) {
                    below = wq;
                    break;
                }
                if (first_parent) break;
            }
            const wq = below orelse continue;
            // One for the commit itself when it is counted; a TREESAME one
            // reaches what its parent reaches.
            const w = if (listed.treesame.contains(oid)) wq else wq + 1;
            try weight.put(c.a, oid, w);
            if (w != wq) counted += 1;
            if (!find_all and halfway(listed, oid, w, nr)) return single(c, oid, w, nr);
        }
    }

    if (!find_all) {
        // `best_bisection`.
        var best = list[0];
        var best_distance: i64 = -1;
        for (list) |oid| {
            if (listed.treesame.contains(oid)) continue;
            var distance = weight.get(oid).?;
            if (nr - distance < distance) distance = nr - distance;
            if (distance > best_distance) {
                best = oid;
                best_distance = distance;
            }
        }
        return single(c, best, weight.get(best).?, nr);
    }
    // `best_bisection_sorted`.
    const Dist = struct { oid: Oid, distance: i64 };
    var dists: std.ArrayList(Dist) = .empty;
    for (list) |oid| {
        if (listed.treesame.contains(oid)) continue;
        var distance = weight.get(oid).?;
        if (nr - distance < distance) distance = nr - distance;
        try dists.append(c.a, .{ .oid = oid, .distance = distance });
    }
    const sorted = dists.items;
    std.mem.sort(Dist, sorted, {}, struct {
        fn lessThan(_: void, x: Dist, y: Dist) bool {
            if (x.distance != y.distance) return x.distance > y.distance;
            return x.oid.order(y.oid) == .lt;
        }
    }.lessThan);
    // With nothing counted git keeps the head of the list.
    if (sorted.len == 0) return single(c, list[0], weight.get(list[0]).?, nr);
    const out = try c.a.alloc(Oid, sorted.len);
    for (sorted, out) |d, *o| o.* = d.oid;
    return .{ .list = out, .reaches = weight.get(out[0]).?, .all = nr };
}

fn single(c: *Ctx, oid: Oid, w: i64, nr: i64) Error!Bisection {
    const one = try c.a.alloc(Oid, 1);
    one[0] = oid;
    return .{ .list = one, .reaches = w, .all = nr };
}

/// `count_distance`: the commits on the list `start` reaches, itself
/// included.
fn countDistance(c: *Ctx, listed: *const Listed, from: Oid) Error!i64 {
    var seen: Oid.Set = .empty;
    defer seen.deinit(c.gpa);
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(c.gpa);
    try stack.append(c.gpa, from);
    var count: i64 = 0;
    while (stack.pop()) |oid| {
        if (listed.hidden.contains(oid)) continue;
        if ((try seen.getOrPut(c.gpa, oid)).found_existing) continue;
        const parents = listed.parents.get(oid) orelse continue;
        if (!listed.treesame.contains(oid)) count += 1;
        for (parents) |p| try stack.append(c.gpa, p);
    }
    return count;
}

const prn_modulo: u32 = 32768;

/// git's `get_prn`: `man 3 rand`'s generator, seeded with the count.
fn getPrn(count: u32) u32 {
    const next_value = count *% 1103515245 +% 12345;
    return (next_value / 65536) % prn_modulo;
}

/// git's `sqrti`, in `float` as git computes it.
fn sqrti(val: i32) i32 {
    if (val == 0) return 0;
    var x: f32 = @floatFromInt(val);
    const v: f32 = @floatFromInt(val);
    while (true) {
        const y: f32 = (x + v / x) / 2;
        const d: f32 = if (y > x) y - x else x - y;
        x = y;
        if (!(d >= 0.5)) break;
    }
    return @intFromFloat(x);
}

/// `managed_skipped`: the commit to test when some are skipped.
fn managedSkipped(revs: *const Revs, a: Allocator, list: []const Oid, tried: *std.ArrayList(Oid)) Allocator.Error![]const Oid {
    if (revs.skipped.items.len == 0) return list;
    // `filter_skipped` with `show_all` off.
    var filtered: std.ArrayList(Oid) = .empty;
    var skipped_first = false;
    var decided_first = false;
    for (list, 0..) |oid, i| {
        if (revs.isSkipped(oid)) {
            if (!decided_first) {
                skipped_first = true;
                decided_first = true;
            }
            try tried.append(a, oid);
            continue;
        }
        if (!decided_first) {
            // The first is not skipped: it is the one, and the rest are
            // not looked at.
            _ = i;
            const one = try a.alloc(Oid, 1);
            one[0] = oid;
            return one;
        }
        try filtered.append(a, oid);
    }
    if (!skipped_first) return filtered.items;
    return skipAway(revs, filtered.items);
}

/// `skip_away`: a commit some way from the skipped ones, chosen by git's
/// pseudo-random number, not the bad one.
fn skipAway(revs: *const Revs, list: []const Oid) []const Oid {
    const count: u32 = @intCast(list.len);
    const prn = getPrn(count);
    const index: i64 = @divTrunc(@as(i64, @divTrunc(@as(i64, count) * prn, prn_modulo)) * sqrti(@intCast(prn)), sqrti(@intCast(prn_modulo)));
    var previous: ?usize = null;
    for (list, 0..) |oid, i| {
        if (@as(i64, @intCast(i)) == index) {
            if (!oid.eql(revs.bad.?)) return list[i..];
            if (previous) |p| return list[p..];
            return list;
        }
        previous = i;
    }
    return list;
}

/// `estimate_bisect_steps`.
fn estimateSteps(all: i64) i64 {
    if (all < 3) return 0;
    const n: u6 = @intCast(63 - @clz(@as(u64, @intCast(all))));
    const e: i64 = @as(i64, 1) << n;
    const x = all - e;
    return if (e < 3 * x) n else @as(i64, n) - 1;
}

/// `bisect_next_all`.
fn nextAll(c: *Ctx, t: Terms) Error!Step {
    const no_checkout = try c.roots().read(c.a, c.io, .bisect_head) != null;
    var revs = try readRefs(c, t);
    const first_parent = c.exists("BISECT_FIRST_PARENT");
    const find_all = revs.skipped.items.len != 0;

    if (try checkGoodAncestors(c, t, &revs, no_checkout)) |step| return step;

    const listed = try listCommits(c, &revs, first_parent);
    const bisection = try findBisection(c, &listed, first_parent, find_all);
    var tried: std.ArrayList(Oid) = .empty;
    const left = try managedSkipped(&revs, c.a, bisection.list, &tried);

    if (left.len == 0) {
        if (tried.items.len != 0) return onlySkipped(c, t, tried.items, null);
        try c.print("{s} was both '{s}' and '{s}'\n", .{ try c.hex(revs.bad.?), t.good, t.bad });
        return error.BothGoodAndBad;
    }
    if (bisection.all == 0) return error.NoTestableCommit;
    const rev = left[0];
    if (rev.eql(revs.bad.?)) {
        if (tried.items.len != 0) return onlySkipped(c, t, tried.items, revs.bad.?);
        try c.print("{s} is the first '{s}' commit\n", .{ try c.hex(rev), t.bad });
        return .{ .first_bad = rev };
    }
    const nr = bisection.all - bisection.reaches - 1;
    const steps = estimateSteps(bisection.all);
    try c.print("Bisecting: {d} {s} left to test after this (roughly {d} {s})\n", .{
        nr,    if (nr == 1) "revision" else "revisions",
        steps, if (steps == 1) "step" else "steps",
    });
    try checkout(c, rev, no_checkout);
    return .{ .testing = rev };
}

/// `error_if_skipped_commits`, when there are some.
fn onlySkipped(c: *Ctx, t: Terms, tried: []const Oid, bad: ?Oid) Error!Step {
    try c.print("There are only 'skip'ped commits left to test.\nThe first '{s}' commit could be any of:\n", .{t.bad});
    var all: std.ArrayList(Oid) = .empty;
    for (tried) |oid| {
        try c.print("{s}\n", .{try c.hex(oid)});
        try all.append(c.a, oid);
    }
    if (bad) |b| {
        try c.print("{s}\n", .{try c.hex(b)});
        try all.append(c.a, b);
    }
    try c.print("We cannot bisect more!\n", .{});
    return .{ .only_skipped = all.items };
}

/// `check_good_are_ancestors_of_bad`, with its merge-base check: a step
/// when a merge base was checked out to be tested.
fn checkGoodAncestors(c: *Ctx, t: Terms, revs: *const Revs, no_checkout: bool) Error!?Step {
    const bad = revs.bad orelse return error.BadRevisionNeeded;
    if (c.exists("BISECT_ANCESTORS_OK")) return null;
    if (revs.good.items.len == 0) return null;

    // `check_ancestors`: is any good commit not reached from the bad one?
    var walk: revwalk.Walk = .init(c.gpa, c.repo.objectDatabase());
    defer walk.deinit();
    try walk.hide(bad);
    for (revs.good.items) |g| try walk.push(g);
    if (try walk.count(c.io) != 0) {
        const bases = try revwalk.mergeBasesMany(c.gpa, c.io, c.repo.objectDatabase(), .{ .one = bad, .others = revs.good.items }, .{});
        defer c.gpa.free(bases);
        for (bases) |mb| {
            if (mb.eql(bad)) return badMergeBase(c, t, revs);
            if (revs.isGood(mb)) continue;
            if (revs.isSkipped(mb)) continue;
            try c.print("Bisecting: a merge base must be tested\n", .{});
            try checkout(c, mb, no_checkout);
            return .{ .merge_base = mb };
        }
    }
    try c.writeState("BISECT_ANCESTORS_OK", "");
    return null;
}

fn badMergeBase(c: *Ctx, t: Terms, revs: *const Revs) Error {
    _ = t;
    const expected = try c.roots().read(c.a, c.io, .bisect_expected_rev);
    if (expected != null and expected.?.eql(revs.bad.?)) return error.BadMergeBase;
    return error.GoodNotAncestorOfBad;
}

/// `bisect_checkout`: `BISECT_EXPECTED_REV`, then the commit checked out
/// (or `BISECT_HEAD` moved), and its line printed.
fn checkout(c: *Ctx, rev: Oid, no_checkout: bool) Error!void {
    try c.roots().write(c.gpa, c.io, .bisect_expected_rev, rev);
    const hex = try c.hex(rev);
    if (no_checkout) {
        try c.roots().write(c.gpa, c.io, .bisect_head, rev);
    } else {
        try switchTo(c, rev, null, hex);
    }
    try c.print("[{s}] {s}\n", .{ hex, try c.subject(rev) });
}

/// `git checkout <target> --`: the tree switched to as a checkout switches
/// it, keeping what is changed locally, and `HEAD` detached at `target`, or
/// made to name `branch`, with git's log line.
fn switchTo(c: *Ctx, target: Oid, branch: ?[]const u8, given: []const u8) Error!void {
    var h = try head_mod.read(c.gpa, c.io, c.repo);
    defer h.deinit(c.gpa);
    const old_desc: []const u8 = if (h.branch) |b|
        (if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else b)
    else if (h.oid) |o|
        try c.hex(o)
    else
        "(invalid)";
    var index = try c.repo.openIndex(c.io);
    defer index.deinit();
    const from_tree = if (h.oid) |oid| try c.repo.commitTree(c.io, oid) else try c.repo.objectDatabase().write(c.io, .tree, "");
    var outcome = try threeway.apply(c.gpa, c.io, c.repo, .{ .index = &index, .base = from_tree, .ours = from_tree, .theirs = try c.repo.commitTree(c.io, target) }, .{ .blocked = c.options.blocked });
    outcome.deinit();
    try c.repo.writeIndex(c.io, &index);
    const msg = try c.a.print("checkout: moving from {s} to {s}", .{ old_desc, given });
    const line: head_mod.Log = .{ .who = c.options.who, .message = msg };
    if (branch) |b| {
        try head_mod.attach(c.io, c.repo, b, h.oid, line);
    } else if (h.branch != null or h.oid == null or !h.oid.?.eql(target)) {
        // A detached `HEAD` that stays where it is changes no ref, and git
        // logs no move.
        try head_mod.detach(c.io, c.repo, h.oid, target, line);
    }
    if (c.options.hooks) |runner| _ = try runner.postCheckout(c.io, h.oid orelse Oid.zero(c.repo.objectFormat()), target, .branch);
}

/// `git checkout <name> --` for a name `BISECT_START` holds: a branch is
/// checked out, anything else is detached at.
fn checkoutName(c: *Ctx, name: []const u8) Error!void {
    const ref = try std.mem.concat(c.a, u8, &.{ "refs/heads/", name });
    if (ref_names.checkFormat(ref, .{})) {
        if (try c.readRef(ref)) |oid| return switchTo(c, oid, ref, name);
    }
    return switchTo(c, try c.commitOf(name), null, name);
}

// ---------------------------------------------------------------------------
// The commands: git's `builtin/bisect.c`.

/// `sq_quote_buf`.
fn sqQuote(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(a, '\'');
    for (text) |ch| {
        if (ch == '\'' or ch == '!') {
            try out.appendSlice(a, "'\\");
            try out.append(a, ch);
            try out.append(a, '\'');
        } else try out.append(a, ch);
    }
    try out.append(a, '\'');
}

/// `sq_dequote_to_strvec`: `null` for text that does not dequote.
fn sqDequote(a: Allocator, text: []const u8) Allocator.Error!?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return out.items;
    var at: usize = 0;
    while (true) {
        if (at >= text.len or text[at] != '\'') return null;
        var word: std.ArrayList(u8) = .empty;
        at += 1;
        var ended = false;
        while (true) {
            if (at >= text.len) return null;
            const ch = text[at];
            at += 1;
            if (ch != '\'') {
                try word.append(a, ch);
                continue;
            }
            if (at >= text.len) {
                ended = true;
                break;
            }
            if (text[at] == '\\' and at + 2 < text.len and (text[at + 1] == '\'' or text[at + 1] == '!') and text[at + 2] == '\'') {
                try word.append(a, text[at + 1]);
                at += 3;
                continue;
            }
            break;
        }
        try out.append(a, word.items);
        if (ended) return out.items;
        if (!isSpace(text[at])) return null;
        while (at < text.len and isSpace(text[at])) at += 1;
    }
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// `git bisect start [--term-{bad,new}=<term> --term-{good,old}=<term>]
/// [--no-checkout] [--first-parent] [--reset-when-found[=<where>]] [<bad>
/// [<good>...]] [--] [<pathspec>...]`, `args` as git is given them: they
/// are what the log records.
pub fn start(gpa: Allocator, io: Io, repo: *Repository, args: []const []const u8, options: Options) Self.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, options, &arena, &out);
    var t: Terms = .{};
    const step = try startWith(&c, &t, args);
    try resetWhenFound(&c, step);
    return finish(arena, out, step);
}

fn startWith(c: *Ctx, t: *Terms, args: []const []const u8) Error!Step {
    var no_checkout = c.repo.isBare();
    var first_parent = false;
    var reset_when_found: ?ResetWhenFound = null;
    var must_write_terms = false;
    var has_double_dash = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) has_double_dash = true;
    }
    var revs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--no-checkout")) {
            no_checkout = true;
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            first_parent = true;
        } else if (std.mem.eql(u8, arg, "--reset-when-found")) {
            reset_when_found = .original;
        } else if (std.mem.startsWith(u8, arg, "--reset-when-found=")) {
            reset_when_found = ResetWhenFound.parse(arg["--reset-when-found=".len..]) orelse return error.InvalidResetWhenFound;
        } else if (std.mem.eql(u8, arg, "--term-good") or std.mem.eql(u8, arg, "--term-old")) {
            i += 1;
            if (i >= args.len) return error.InvalidTerm;
            must_write_terms = true;
            t.good = args[i];
        } else if (std.mem.startsWith(u8, arg, "--term-good=") or std.mem.startsWith(u8, arg, "--term-old=")) {
            must_write_terms = true;
            t.good = arg[std.mem.findScalar(u8, arg, '=').? + 1 ..];
        } else if (std.mem.eql(u8, arg, "--term-bad") or std.mem.eql(u8, arg, "--term-new")) {
            i += 1;
            if (i >= args.len) return error.InvalidTerm;
            must_write_terms = true;
            t.bad = args[i];
        } else if (std.mem.startsWith(u8, arg, "--term-bad=") or std.mem.startsWith(u8, arg, "--term-new=")) {
            must_write_terms = true;
            t.bad = arg[std.mem.findScalar(u8, arg, '=').? + 1 ..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnrecognizedOption;
        } else if (c.commitOf(arg)) |oid| {
            try revs.append(c.a, try c.hex(oid));
        } else |err| switch (err) {
            error.BadRevision => {
                if (has_double_dash) return error.BadRevision;
                break;
            },
            else => |e| return e,
        }
    }
    if (reset_when_found != null and no_checkout) return error.ResetWhenFoundWithoutCheckout;
    const pathspec_pos = i;
    // git's `sq_quote_argv` of what follows the revisions, the `--` among
    // it, and only from two arguments on (`argc - 1`).
    var names: std.ArrayList(u8) = .empty;
    if (args.len > 0 and pathspec_pos < args.len - 1) {
        for (args[pathspec_pos..]) |arg| {
            try names.append(c.a, ' ');
            try sqQuote(c.a, &names, arg);
        }
    }

    if (revs.items.len != 0) must_write_terms = true;

    // Where `HEAD` is, to come back to.
    var start_head: []const u8 = undefined;
    var h = try head_mod.read(c.gpa, c.io, c.repo);
    defer h.deinit(c.gpa);
    const head_oid = h.oid orelse return error.BadHead;
    if (!try c.emptyOrMissing("BISECT_START")) {
        const text = (try c.readState("BISECT_START")).?;
        start_head = std.mem.trim(u8, text, " \t\n\r");
        if (!no_checkout) try checkoutName(c, start_head);
    } else if (h.branch != null and std.mem.startsWith(u8, h.branch.?, "refs/heads/")) {
        start_head = try c.a.dupe(u8, h.branch.?["refs/heads/".len..]);
    } else {
        start_head = try c.hex(head_oid);
    }

    try cleanState(c);
    try c.writeState("BISECT_START", try std.mem.concat(c.a, u8, &.{ start_head, "\n" }));
    if (first_parent) try c.writeState("BISECT_FIRST_PARENT", "\n");
    if (reset_when_found) |mode| try c.writeState("BISECT_RESET_WHEN_FOUND", try std.mem.concat(c.a, u8, &.{ @tagName(mode), "\n" }));
    if (no_checkout) {
        const oid = revparse.resolve(c.gpa, c.io, c.repo, start_head) catch return error.BadHead;
        try c.roots().write(c.gpa, c.io, .bisect_head, oid);
    }
    try names.append(c.a, '\n');
    try c.writeState("BISECT_NAMES", names.items);

    for (revs.items, 0..) |rev, k| {
        try bisectWrite(c, if (k == 0) t.bad else t.good, rev, t.*, true);
    }
    if (must_write_terms) try writeTerms(c, t.bad, t.good);
    var log_line: std.ArrayList(u8) = .empty;
    try log_line.appendSlice(c.a, "git bisect start");
    for (args) |arg| {
        try log_line.append(c.a, ' ');
        try sqQuote(c.a, &log_line, arg);
    }
    try log_line.append(c.a, '\n');
    try c.appendState("BISECT_LOG", log_line.items);
    // A bisection that cannot go on is not left half started.
    return autoNext(c, t.*) catch |err| {
        // ziglint-ignore: Z026 the step's error is the one to report; a state left behind is what `git bisect reset` removes
        cleanState(c) catch {};
        return err;
    };
}

/// `git bisect <term> [<rev>...]`, `git bisect skip [<rev>...]`: `state`
/// is the bad or the good term or `skip`, and `revs` empty means
/// `BISECT_HEAD` or `HEAD`. A `skip` of `<a>..<b>` skips the range.
pub const MarkInputs = struct { state: []const u8, revs: []const []const u8 };

pub fn mark(gpa: Allocator, io: Io, repo: *Repository, inputs: MarkInputs, options: Options) Self.Error!Report {
    const state = inputs.state;
    const revs = inputs.revs;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, options, &arena, &out);
    var t = try readTerms(&c);
    var expanded: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, state, "skip")) {
        // `bisect_skip`: a range is every commit in it.
        for (revs) |rev| {
            if (std.mem.find(u8, rev, "..")) |dots| {
                var walk: revwalk.Walk = .init(c.gpa, c.repo.objectDatabase());
                defer walk.deinit();
                try walk.hide(try c.commitOf(rev[0..dots]));
                try walk.push(try c.commitOf(rev[dots + 2 ..]));
                while (try walk.next(c.io)) |commit| try expanded.append(c.a, try c.hex(commit.oid));
            } else try expanded.append(c.a, rev);
        }
    } else try expanded.appendSlice(c.a, revs);
    const step = try applyState(&c, &t, state, expanded.items);
    try resetWhenFound(&c, step);
    return finish(arena, out, step);
}

/// `bisect_state`.
fn applyState(c: *Ctx, t: *Terms, state: []const u8, revs: []const []const u8) Error!Step {
    if (try c.emptyOrMissing("BISECT_START")) return error.NotBisecting;
    try checkAndSetTerms(c, t, state);
    if (!oneOf(state, &.{ t.good, t.bad, "skip" })) return error.InvalidCommand;
    if (revs.len > 1 and std.mem.eql(u8, state, t.bad)) return error.TooManyBadRevisions;
    var oids: std.ArrayList(Oid) = .empty;
    if (revs.len == 0) {
        const oid = (try c.roots().read(c.a, c.io, .bisect_head)) orelse (try c.commitOf("HEAD"));
        try oids.append(c.a, oid);
    }
    for (revs) |rev| try oids.append(c.a, try c.commitOf(rev));
    var verify_expected = true;
    const expected = try c.roots().read(c.a, c.io, .bisect_expected_rev);
    if (expected == null) verify_expected = false;
    for (oids.items) |oid| {
        try bisectWrite(c, state, try c.hex(oid), t.*, false);
        if (verify_expected and !oid.eql(expected.?)) {
            try c.removeState("BISECT_ANCESTORS_OK");
            try c.roots().delete(c.gpa, c.io, .bisect_expected_rev);
            verify_expected = false;
        }
    }
    return autoNext(c, t.*);
}

/// `git bisect next`.
pub fn nextStep(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, options, &arena, &out);
    const t = try readTerms(&c);
    const step = try next(&c, t);
    try resetWhenFound(&c, step);
    return finish(arena, out, step);
}

/// `git bisect reset [<commit>]`: back to where the bisection started, or
/// to `commit`, and every trace of it removed.
pub fn reset(gpa: Allocator, io: Io, repo: *Repository, commit: ?[]const u8, options: Options) Self.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, options, &arena, &out);
    try resetTo(&c, commit);
    return finish(arena, out, .waiting);
}

/// `bisect_reset`, then the state cleaned, as `git bisect reset` does. git
/// says it is not bisecting only for an empty `BISECT_START`; a missing one
/// it passes over.
fn resetTo(c: *Ctx, commit: ?[]const u8) Error!void {
    var branch: []const u8 = "";
    if (commit) |given| {
        _ = try c.commitOf(given);
        branch = given;
    } else if (try c.readState("BISECT_START")) |text| {
        if (text.len == 0) try c.print("We are not bisecting.\n", .{});
        branch = std.mem.trimEnd(u8, text, " \t\n\r");
    }
    if (branch.len != 0 and try c.roots().read(c.a, c.io, .bisect_head) == null) try checkoutName(c, branch);
    try cleanState(c);
}

/// `git bisect log`: what `BISECT_LOG` holds. The result is the caller's.
pub fn log(gpa: Allocator, io: Io, repo: *Repository) Self.Error![]u8 {
    const text = repo.gitDirectory().readFileAlloc(io, "BISECT_LOG", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.NoLog,
        else => |e| return e,
    };
    if (text.len == 0) {
        gpa.free(text);
        return error.NoLog;
    }
    return text;
}

/// `git bisect replay`: the state of the bisection in progress cleaned,
/// with nothing checked out, then the one a log records done again, nothing
/// checked out but by its `start` and its end.
pub fn replay(gpa: Allocator, io: Io, repo: *Repository, log_text: []const u8, options: Options) Self.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, options, &arena, &out);
    if (log_text.len == 0) return error.NoLog;
    try cleanState(&c);
    var t: Terms = .{};
    var lines = std.mem.splitScalar(u8, log_text, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var p = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, p, "git bisect")) {
            p = p["git bisect".len..];
        } else if (std.mem.startsWith(u8, p, "git-bisect")) {
            p = p["git-bisect".len..];
        } else continue;
        if (p.len == 0 or !isSpace(p[0])) continue;
        p = std.mem.trimStart(u8, p, " \t");
        const word_end = std.mem.findAny(u8, p, " \t") orelse p.len;
        const word = p[0..word_end];
        const rev = std.mem.trimStart(u8, p[word_end..], " \t");
        if (try getTerms(&c)) |recorded| t = recorded;
        try checkAndSetTerms(&c, &t, word);
        if (std.mem.eql(u8, word, "start")) {
            const argv = (try sqDequote(c.a, rev)) orelse &.{};
            const step = try startWith(&c, &t, argv);
            switch (step) {
                .waiting, .testing => continue,
                // git stops the replay at a start that does more than
                // check out a commit to test, and exits with a failure.
                else => {
                    try resetWhenFound(&c, step);
                    return finish(arena, out, step);
                },
            }
        }
        if (oneOf(word, &.{ t.good, t.bad, "skip" })) {
            try bisectWrite(&c, word, rev, t, false);
            continue;
        }
        if (std.mem.eql(u8, word, "terms")) {
            // `bisect_terms`, as git prints it.
            const recorded = (try getTerms(&c)) orelse return error.NoTermsDefined;
            const argv = (try sqDequote(c.a, rev)) orelse &.{};
            if (argv.len == 1) {
                if (oneOf(argv[0], &.{ "--term-good", "--term-old" })) {
                    try c.print("{s}\n", .{recorded.good});
                } else if (oneOf(argv[0], &.{ "--term-bad", "--term-new" })) {
                    try c.print("{s}\n", .{recorded.bad});
                } else return error.InvalidReplayLine;
            } else {
                try c.print("Your current terms are '{s}' for the old state\nand '{s}' for the new state.\n", .{ recorded.good, recorded.bad });
            }
            continue;
        }
        return error.InvalidReplayLine;
    }
    const step = try autoNext(&c, t);
    try resetWhenFound(&c, step);
    return finish(arena, out, step);
}

/// How `run` runs the test command.
pub const RunOptions = struct {
    who: object.Signature,
    hooks: ?*hooks.Runner = null,
    blocked: ?*threeway.Blocked = null,
    /// The permission to run it, through the shell, as git runs it.
    programs: program.Programs,
};

/// `git bisect run <cmd> [<arg>...]`: the command run on each commit to
/// test, its exit status the verdict -- 0 good, 125 skip, 1 to 127 bad --
/// until the first bad commit is found or only skipped ones are left.
pub fn run(gpa: Allocator, io: Io, repo: *Repository, argv_in: []const []const u8, options: RunOptions) Self.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    var c = begin(gpa, io, repo, .{ .who = options.who, .hooks = options.hooks, .blocked = options.blocked }, &arena, &out);
    var t = try readTerms(&c);
    if (!try nextCheck(&c, t, null)) return error.NeedGoodAndBad;
    var argv = argv_in;
    if (argv.len != 0 and std.mem.startsWith(u8, argv[0], "--reset-when-found")) {
        const mode: ResetWhenFound = if (std.mem.eql(u8, argv[0], "--reset-when-found"))
            .original
        else if (std.mem.startsWith(u8, argv[0], "--reset-when-found="))
            ResetWhenFound.parse(argv[0]["--reset-when-found=".len..]) orelse return error.InvalidResetWhenFound
        else
            return error.InvalidResetWhenFound;
        if (try c.roots().read(c.a, c.io, .bisect_head) != null) return error.ResetWhenFoundWithoutCheckout;
        try c.writeState("BISECT_RESET_WHEN_FOUND", try std.mem.concat(c.a, u8, &.{ @tagName(mode), "\n" }));
        argv = argv[1..];
    }
    if (argv.len == 0) return error.NoCommand;
    var command: std.ArrayList(u8) = .empty;
    for (argv) |arg| {
        try command.append(c.a, ' ');
        try sqQuote(c.a, &command, arg);
    }
    const line = std.mem.trimStart(u8, command.items, " \t\n\r");
    var first = true;
    while (true) {
        const code = try runCommand(&c, line, options);
        if (first and (code == 126 or code == 127)) {
            // The shell's own codes for a command it could not run: tried
            // on a good commit before they are believed.
            const verified = try verifyGood(&c, t, line, options);
            if (verified < 0 or verified >= 128 or verified == code) return error.RunFailed;
        }
        first = false;
        if (code < 0 or code >= 128) return error.RunFailed;
        const new_state = if (code == 125) "skip" else if (code == 0) t.good else t.bad;
        const before = c.out.items.len;
        const step = try applyState(&c, &t, new_state, &.{});
        try c.writeState("BISECT_RUN", c.out.items[before..]);
        switch (step) {
            .only_skipped => return error.RunCannotContinue,
            .merge_base => {
                try c.print("bisect run success\n", .{});
                try resetWhenFound(&c, step);
                return finish(arena, out, step);
            },
            .first_bad => {
                try c.print("bisect found first '{s}' commit\n", .{t.bad});
                try resetWhenFound(&c, step);
                return finish(arena, out, step);
            },
            else => {},
        }
    }
}

/// `do_bisect_run`: `running <cmd>`, and its exit status.
fn runCommand(c: *Ctx, line: []const u8, run_options: RunOptions) Error!i32 {
    try c.print("running {s}\n", .{line});
    var outcome = try program.run(c.gpa, c.io, run_options.programs, .{
        .argv = &.{line},
        .shell = true,
        .cwd = if (c.repo.workDirectory()) |wt| .{ .dir = wt } else .inherit,
    }, .{});
    defer outcome.deinit(c.gpa);
    return switch (outcome.term) {
        .exited => |code| std.math.cast(i32, code) orelse 128,
        else => 128,
    };
}

/// `verify_good`: the command run on the first good commit, then the
/// commit being tested put back.
fn verifyGood(c: *Ctx, t: Terms, line: []const u8, run_options: RunOptions) Error!i32 {
    const no_checkout = try c.roots().read(c.a, c.io, .bisect_head) != null;
    const good_prefix = try c.a.print("refs/bisect/{s}-", .{t.good});
    var listing = try c.repo.refStore().list(c.gpa, c.io, "refs/bisect/");
    defer listing.deinit();
    var good: ?Oid = null;
    for (listing.entries) |e| if (std.mem.startsWith(u8, e.name, good_prefix)) {
        if (good == null and e.target == .direct) good = e.target.direct;
    };
    const at = if (no_checkout) try c.roots().read(c.a, c.io, .bisect_head) else try c.readRef("HEAD");
    const current = at orelse (c.commitOf("HEAD") catch return -1);
    try checkout(c, good orelse return -1, no_checkout);
    const code = try runCommand(c, line, run_options);
    try checkout(c, current, no_checkout);
    return code;
}

test "git's pseudo-random step and integer square root" {
    try std.testing.expectEqual(@as(i32, 181), sqrti(32768));
    try std.testing.expectEqual(@as(i32, 0), sqrti(0));
    try std.testing.expectEqual(@as(i32, 3), sqrti(9));
    try std.testing.expectEqual(@as(i64, 0), estimateSteps(2));
    try std.testing.expectEqual(@as(i64, 2), estimateSteps(7));
    try std.testing.expectEqual(@as(i64, 2), estimateSteps(9));
    try std.testing.expectEqual(@as(i64, 3), estimateSteps(12));
}

test "fuzz: any log text replays to a value or a named error, and quoting round-trips" {
    try std.testing.fuzz({}, fuzzQuote, .{});
}

fn fuzzQuote(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    _ = try sqDequote(a, input);
    var words = std.mem.splitScalar(u8, input, 0);
    var quoted: std.ArrayList(u8) = .empty;
    var expected: std.ArrayList([]const u8) = .empty;
    while (words.next()) |w| {
        if (quoted.items.len != 0) try quoted.append(a, ' ');
        try sqQuote(a, &quoted, w);
        try expected.append(a, w);
    }
    const back = (try sqDequote(a, quoted.items)).?;
    try std.testing.expectEqual(expected.items.len, back.len);
    for (expected.items, back) |x, y| try std.testing.expectEqualStrings(x, y);
}

const testgit = @import("../testing/git.zig");

const test_who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// Two repositories with the same history: git bisects one, this the other,
/// and everything either leaves is compared after each command.
const Twin = struct {
    env: std.process.Environ.Map,
    git: testgit.Repo,
    ours: testgit.Repo,
    repo: Repository,
    format: testgit.RefFormat,

    /// `shape` 0 is a line of commits; 1 has merges; 2 is a line in which
    /// every third commit also changes `p/x`. Both keep their refs in
    /// `format`.
    fn init(gpa: Allocator, io: Io, t: *Twin, format: testgit.RefFormat, shape: u8) !void {
        t.format = format;
        t.env = try testgit.datedEnv(gpa, 1_700_000_000);
        errdefer t.env.deinit();
        t.git = try testgit.Repo.init(gpa, io, format.initArgs());
        errdefer t.git.deinit();
        t.ours = try testgit.Repo.init(gpa, io, format.initArgs());
        errdefer t.ours.deinit();
        for ([_]*testgit.Repo{ &t.git, &t.ours }) |r| {
            r.environ = &t.env;
            var when: i64 = 1_700_000_000;
            var n: usize = 0;
            const commit = struct {
                fn f(i: Io, rr: *testgit.Repo, env: *std.process.Environ.Map, w: *i64, k: *usize, extra: []const u8) !void {
                    w.* += 60;
                    k.* += 1;
                    try testgit.setDate(env, w.*);
                    var buf: [32]u8 = undefined;
                    try rr.writeFile(i, "n", try std.mem.print(&buf, "{d}\n", .{k.*}));
                    if (extra.len != 0) try rr.writeFile(i, extra, extra);
                    try rr.exec(i, &.{ "add", "-A" });
                    var msg: [32]u8 = undefined;
                    try rr.exec(i, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "commit {d}", .{k.*}) });
                }
            }.f;
            for (0..6) |_| try commit(io, r, &t.env, &when, &n, "");
            if (shape == 2) {
                for (0..12) |k| {
                    if (k % 3 == 0) {
                        var buf: [16]u8 = undefined;
                        try r.writeFile(io, "p/x", try std.mem.print(&buf, "{d}\n", .{k}));
                    }
                    try commit(io, r, &t.env, &when, &n, "");
                }
            }
            if (shape == 1) {
                // The side branch leaves `n` as it found it, so the merge
                // is clean and each commit there tests as its fork point.
                try r.exec(io, &.{ "checkout", "-q", "-b", "side", "HEAD~3" });
                for (0..4) |k| {
                    when += 60;
                    try testgit.setDate(&t.env, when);
                    var buf: [32]u8 = undefined;
                    try r.writeFile(io, "side", try std.mem.print(&buf, "{d}\n", .{k}));
                    try r.exec(io, &.{ "add", "side" });
                    try r.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&buf, "side {d}", .{k}) });
                }
                try r.exec(io, &.{ "checkout", "-q", "main" });
                for (0..3) |_| try commit(io, r, &t.env, &when, &n, "");
                when += 60;
                try testgit.setDate(&t.env, when);
                try r.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });
            }
            for (0..10) |_| try commit(io, r, &t.env, &when, &n, "");
        }
        t.repo = try Repository.open(gpa, io, t.ours.dir, .{});
    }

    fn deinit(t: *Twin, io: Io) void {
        t.repo.deinit(io);
        t.ours.deinit();
        t.git.deinit();
        t.env.deinit();
        t.* = undefined;
    }

    /// git's standard output for `bisect <args>`, up to and including a
    /// first bad commit's line.
    fn gitBisect(t: *Twin, io: Io, args: []const []const u8) ![]u8 {
        const gpa = t.git.gpa;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "bisect");
        try argv.appendSlice(gpa, args);
        var cap = try t.git.capture(io, argv.items);
        defer gpa.free(cap.stderr);
        // The `git show` after a first bad commit's line is left out, and
        // what `bisect run` prints after it kept.
        if (std.mem.find(u8, cap.stdout, " commit\ncommit ")) |at| {
            const end = at + " commit\n".len;
            const tail = if (std.mem.findPos(u8, cap.stdout, end, "\nbisect found first")) |t_at| cap.stdout[t_at + 1 ..] else "";
            const cut = try std.mem.concat(gpa, u8, &.{ cap.stdout[0..end], tail });
            gpa.free(cap.stdout);
            return cut;
        }
        return cap.stdout;
    }

    fn expectSameState(t: *Twin, io: Io) !void {
        const gpa = t.git.gpa;
        for ([_][]const u8{ "BISECT_START", "BISECT_TERMS", "BISECT_NAMES", "BISECT_LOG", "BISECT_ANCESTORS_OK", "BISECT_FIRST_PARENT", ref_names.Root.bisect_expected_rev.name(), ref_names.Root.bisect_head.name(), "BISECT_RUN" }) |name| {
            // A root ref is a record in a reftable, and what git reads of
            // it is what both must agree on.
            if (t.format == .reftable and ref_names.isRootRef(name)) {
                const a = try gitOrFailed(io, &t.git, &.{ "rev-parse", "--verify", "-q", name });
                defer gpa.free(a);
                const b = try gitOrFailed(io, &t.ours, &.{ "rev-parse", "--verify", "-q", name });
                defer gpa.free(b);
                std.testing.expectEqualStrings(a, b) catch |err| {
                    std.log.err("{s} differs", .{name});
                    return err;
                };
                continue;
            }
            const path = try gpa.print(".git/{s}", .{name});
            defer gpa.free(path);
            const a = t.git.readFile(io, path) catch |err| switch (err) {
                error.FileNotFound => try gpa.dupe(u8, "<missing>"),
                else => |e| return e,
            };
            defer gpa.free(a);
            const b = t.ours.readFile(io, path) catch |err| switch (err) {
                error.FileNotFound => try gpa.dupe(u8, "<missing>"),
                else => |e| return e,
            };
            defer gpa.free(b);
            if (std.mem.eql(u8, name, "BISECT_RUN")) {
                // git's ends with the `git show` of a first bad commit.
                const cut = std.mem.find(u8, a, " commit\ncommit ");
                try std.testing.expectEqualStrings(if (cut) |at| a[0 .. at + " commit\n".len] else a, b);
                continue;
            }
            std.testing.expectEqualStrings(a, b) catch |err| {
                std.log.err("{s} differs", .{name});
                return err;
            };
        }
        for ([_][]const []const u8{
            &.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/bisect/" },
            &.{ "rev-parse", "HEAD" },
            &.{ "symbolic-ref", "-q", "HEAD" },
            &.{ "reflog", "show", "--format=%H %gs", "HEAD" },
            &.{ "status", "--porcelain" },
            &.{ "ls-files", "-s" },
        }) |args| {
            const a = try gitOrFailed(io, &t.git, args);
            defer gpa.free(a);
            const b = try gitOrFailed(io, &t.ours, args);
            defer gpa.free(b);
            std.testing.expectEqualStrings(a, b) catch |err| {
                std.log.err("git {any} differs", .{args});
                return err;
            };
        }
    }

    /// Whether git's side is still bisecting: it has a commit it expects
    /// tested, in either ref format.
    fn gitExpects(t: *Twin, io: Io) !bool {
        const seen = try gitOrFailed(io, &t.git, &.{ "rev-parse", "--verify", "-q", ref_names.Root.bisect_expected_rev.name() });
        defer t.git.gpa.free(seen);
        return !std.mem.eql(u8, seen, "<failed>");
    }

    /// Which word the commit under test earns: bad from `first_bad` on.
    fn verdict(t: *Twin, io: Io, first_bad: usize, skip: []const usize, no_checkout: bool) ![]const u8 {
        const text = if (no_checkout) try t.git.run(io, &.{ "show", "BISECT_HEAD:n" }) else try t.git.readFile(io, "n");
        defer t.git.gpa.free(text);
        const n = try std.fmt.parseInt(usize, std.mem.trim(u8, text, "\n"), 10);
        for (skip) |s| if (s == n) return "skip";
        return if (n >= first_bad) "bad" else "good";
    }
};

fn gitOrFailed(io: Io, r: *testgit.Repo, args: []const []const u8) ![]u8 {
    r.report_failures = false;
    defer r.report_failures = true;
    return r.run(io, args) catch |err| switch (err) {
        error.GitFailed => r.gpa.dupe(u8, "<failed>"),
        else => |e| e,
    };
}

fn expectReport(t: *Twin, io: Io, git_args: []const []const u8, report: anytype) !void {
    const expected = try t.gitBisect(io, git_args);
    defer t.git.gpa.free(expected);
    var r = report catch |err| {
        std.log.err("bisect {any}: {t}; git said:\n{s}", .{ git_args, err, expected });
        return err;
    };
    defer r.deinit();
    std.testing.expectEqualStrings(expected, r.text) catch |err| {
        std.log.err("bisect {any} differs", .{git_args});
        return err;
    };
    try t.expectSameState(io);
}

const Case = struct { shape: u8, first_bad: usize, skip: []const usize = &.{}, start: []const []const u8 };

test "a bisection steps through the commits git steps through, with git's state, logs and checkouts" {
    try bisectLikeGit(.{ .shape = 0, .first_bad = 7, .start = &.{ "HEAD", "HEAD~15" } });
}

test "a bisection with skipped commits steps away from them as git does" {
    try bisectLikeGit(.{ .shape = 0, .first_bad = 12, .skip = &.{ 8, 9, 12, 13 }, .start = &.{ "HEAD", "HEAD~15" } });
}

test "a bisection without a checkout moves BISECT_HEAD as git does" {
    try bisectLikeGit(.{ .shape = 0, .first_bad = 3, .start = &.{ "--no-checkout", "HEAD", "HEAD~15" } });
}

test "a bisection in terms of its own speaks them as git does" {
    try bisectLikeGit(.{ .shape = 0, .first_bad = 9, .start = &.{ "--term-new=broken", "--term-old=fine", "HEAD", "HEAD~15" } });
}

test "a bisection through merges weighs every commit as git does" {
    try bisectLikeGit(.{ .shape = 1, .first_bad = 14, .start = &.{ "HEAD", "HEAD~12" } });
}

test "a good commit off the bad one's history has its merge base tested first, as git does" {
    try bisectLikeGit(.{ .shape = 1, .first_bad = 5, .start = &.{ "HEAD", "side~2" } });
}

test "a first-parent bisection with skips steps as git's does" {
    try bisectLikeGit(.{ .shape = 1, .first_bad = 14, .skip = &.{ 15, 16 }, .start = &.{ "--first-parent", "HEAD", "HEAD~12" } });
}

test "a bisection from two good commits steps as git's does" {
    try bisectLikeGit(.{ .shape = 1, .first_bad = 8, .start = &.{ "HEAD", "side", "HEAD~14" } });
}

/// One bisection, run by git in one twin and by this in the other, every
/// step compared, then its log replayed and the whole reset.
fn bisectLikeGit(case: Case) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // The builtin bisect of git 2.40, whose messages and log are these.
    try testgit.requireGitVersion(gpa, io, 2, 40);
    const newest = try testgit.gitAtLeast(gpa, io, 2, 56);
    for (try testgit.refFormats(gpa, io)) |format| {
        errdefer std.log.err("in the {t} ref format", .{format});
        var t: Twin = undefined;
        try Twin.init(gpa, io, &t, format, case.shape);
        defer t.deinit(io);
        var start_args: std.ArrayList([]const u8) = .empty;
        defer start_args.deinit(gpa);
        var revisions: std.heap.ArenaAllocator = .init(gpa);
        defer revisions.deinit();
        try start_args.append(gpa, "start");
        for (case.start) |arg| {
            // HEAD moves while bisect runs; the replay log needs stable names.
            if (std.mem.eql(u8, arg, "HEAD") or std.mem.startsWith(u8, arg, "HEAD~")) {
                const oid = try t.git.line(io, &.{ "rev-parse", arg });
                defer gpa.free(oid);
                try start_args.append(gpa, try revisions.allocator().dupe(u8, oid));
            } else try start_args.append(gpa, arg);
        }
        try expectReport(&t, io, start_args.items, start(gpa, io, &t.repo, start_args.items[1..], .{ .who = test_who }));
        const no_checkout = case.start[0][2] == 'n';
        const renamed = std.mem.startsWith(u8, case.start[0], "--term");
        var steps: usize = 0;
        while (steps < 20) : (steps += 1) {
            if (!try t.gitExpects(io)) break;
            const log_text = try t.git.readFile(io, ".git/BISECT_LOG");
            defer gpa.free(log_text);
            if (std.mem.find(u8, log_text, "first '") != null or std.mem.find(u8, log_text, "only skipped") != null) break;
            var word = try t.verdict(io, case.first_bad, case.skip, no_checkout);
            if (renamed) word = if (std.mem.eql(u8, word, "bad")) "broken" else if (std.mem.eql(u8, word, "good")) "fine" else word;
            try expectReport(&t, io, &.{word}, mark(gpa, io, &t.repo, .{ .state = word, .revs = &.{} }, .{ .who = test_who }));
        }
        // Replay from the completed bisection, as git 2.56 does without
        // first restoring the original HEAD, then reset both twins.
        if (newest) {
            const recorded = try log(gpa, io, &t.repo);
            defer gpa.free(recorded);
            try t.git.writeFile(io, ".git/replay.log", recorded);
            try expectReport(&t, io, &.{ "replay", ".git/replay.log" }, replay(gpa, io, &t.repo, recorded, .{ .who = test_who }));
        }
        try expectReport(&t, io, &.{"reset"}, reset(gpa, io, &t.repo, null, .{ .who = test_who }));
    }
}

test "a bisection limited by a pathspec tests only the commits that change it, as git's does" {
    try bisectLikeGit(.{ .shape = 2, .first_bad = 14, .start = &.{ "HEAD", "HEAD~25", "--", "p" } });
}

test "pathspecs without a double dash are recorded from two on, as git records them" {
    try bisectLikeGit(.{ .shape = 2, .first_bad = 11, .start = &.{ "HEAD", "HEAD~25", "p", "n" } });
    try bisectLikeGit(.{ .shape = 2, .first_bad = 11, .start = &.{ "HEAD", "HEAD~25", "p" } });
}

test "a pathspec bisection through a merge follows the side that changed the path, as git's does" {
    try bisectLikeGit(.{ .shape = 1, .first_bad = 1, .start = &.{ "HEAD", "HEAD~14", "--", "side" } });
    try bisectLikeGit(.{ .shape = 1, .first_bad = 14, .skip = &.{15}, .start = &.{ "--first-parent", "HEAD", "HEAD~14", "--", "n" } });
}

test "bisect run tests each commit with the command, as git's does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            // The builtin bisect of git 2.40, whose messages and log are these.
            try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 40);
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var t: Twin = undefined;
            try Twin.init(gpa, io, &t, format, 1);
            defer t.deinit(io);
            var env = try testgit.programEnviron(gpa);
            defer env.deinit();
            const script = "n=$(cat n); if [ $n -eq 13 ]; then exit 125; fi; [ $n -lt 12 ]";
            try expectReport(&t, io, &.{ "start", "HEAD", "HEAD~16" }, start(gpa, io, &t.repo, &.{ "HEAD", "HEAD~16" }, .{ .who = test_who }));
            try expectReport(&t, io, &.{ "run", "sh", "-c", script }, run(gpa, io, &t.repo, &.{ "sh", "-c", script }, .{ .who = test_who, .programs = .{ .environ = &env } }));
        }
    }.inFormat);
}

test "bisect refuses what git refuses" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var u: Twin = undefined;
            try Twin.init(gpa, io, &u, format, 0);
            defer u.deinit(io);
            try std.testing.expectError(error.NotBisecting, mark(gpa, io, &u.repo, .{ .state = "good", .revs = &.{} }, .{ .who = test_who }));
            try std.testing.expectError(error.UnrecognizedOption, start(gpa, io, &u.repo, &.{"--bogus"}, .{ .who = test_who }));
            try std.testing.expectError(error.InvalidTerm, start(gpa, io, &u.repo, &.{ "--term-new=skip", "HEAD" }, .{ .who = test_who }));
        }
    }.inFormat);
}

test "bisect waits for good and bad commits, and skips a range, as git does" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            // The builtin bisect of git 2.40, whose messages and log are these.
            try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 40);
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var t: Twin = undefined;
            try Twin.init(gpa, io, &t, format, 0);
            defer t.deinit(io);
            // Waiting for both, then for a good commit.
            try expectReport(&t, io, &.{"start"}, start(gpa, io, &t.repo, &.{}, .{ .who = test_who }));
            try expectReport(&t, io, &.{ "bad", "HEAD" }, mark(gpa, io, &t.repo, .{ .state = "bad", .revs = &.{"HEAD"} }, .{ .who = test_who }));
            try std.testing.expectError(error.TooManyBadRevisions, mark(gpa, io, &t.repo, .{ .state = "bad", .revs = &.{ "HEAD", "HEAD~1" } }, .{ .who = test_who }));
            try expectReport(&t, io, &.{ "good", "HEAD~4", "HEAD~6" }, mark(gpa, io, &t.repo, .{ .state = "good", .revs = &.{ "HEAD~4", "HEAD~6" } }, .{ .who = test_who }));
            try expectReport(&t, io, &.{ "skip", "HEAD~3..HEAD~1" }, mark(gpa, io, &t.repo, .{ .state = "skip", .revs = &.{"HEAD~3..HEAD~1"} }, .{ .who = test_who }));
        }
    }.inFormat);
}

test "a bisection told to reset when it finds the commit goes back as git 2.56's does" {
    try resetWhenFoundLikeGit("--reset-when-found");
}

test "a bisection told to reset to what it found goes there as git 2.56's does" {
    try resetWhenFoundLikeGit("--reset-when-found=found");
}

test "a reset when found is refused without a checkout and to nowhere" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var t: Twin = undefined;
            try Twin.init(gpa, io, &t, format, 0);
            defer t.deinit(io);
            try std.testing.expectError(error.ResetWhenFoundWithoutCheckout, start(gpa, io, &t.repo, &.{ "--reset-when-found", "--no-checkout", "HEAD" }, .{ .who = test_who }));
            try std.testing.expectError(error.InvalidResetWhenFound, start(gpa, io, &t.repo, &.{"--reset-when-found=elsewhere"}, .{ .who = test_who }));
        }
    }.inFormat);
}

fn resetWhenFoundLikeGit(option: []const u8) !void {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 56);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for (try testgit.refFormats(gpa, io)) |format| {
        errdefer std.log.err("in the {t} ref format", .{format});
        var t: Twin = undefined;
        try Twin.init(gpa, io, &t, format, 0);
        defer t.deinit(io);
        try expectReport(&t, io, &.{ "start", option, "HEAD", "HEAD~3" }, start(gpa, io, &t.repo, &.{ option, "HEAD", "HEAD~3" }, .{ .who = test_who }));
        for (0..3) |_| {
            if (!try t.gitExpects(io)) break;
            const word = try t.verdict(io, 14, &.{}, false);
            try expectReport(&t, io, &.{word}, mark(gpa, io, &t.repo, .{ .state = word, .revs = &.{} }, .{ .who = test_who }));
        }
    }
}
