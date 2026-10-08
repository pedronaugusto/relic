//! `git am`: a mailbox of patches applied as commits, one per mail.
//!
//! The mailbox is cut and each mail taken apart as `git mailsplit` and
//! `git mailinfo` do (`mailinfo.zig`), applied to the index and the working
//! tree as `git apply --index` applies it (`apply.zig`), and committed with
//! the mail's author and date, the caller's committer, and `am: <subject>`
//! in the reflog. With `three_way` a patch that does not apply is merged
//! instead: a base is built from the blobs its `index` lines name, the patch
//! is applied to that, and the result merged into `HEAD` as git's
//! merge-ort merges it, with git's labels.
//!
//! Everything a session keeps is where git keeps it, `.git/rebase-apply/`
//! with git's files in git's format — the cut mails, `next`, `last`, `info`,
//! `msg`, `patch`, `author-script`, `final-commit`, the options — so a
//! session this stopped is continued, skipped or aborted by `git am`, and
//! one git stopped is finished here. A stop is a value naming the patch and
//! why; nothing is printed. The hooks are git's: `applypatch-msg`,
//! `pre-applypatch`, `post-applypatch`.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const index_mod = @import("../index/index.zig");
const worktree = @import("../checkout/checkout.zig");
const head_mod = @import("../repo/head.zig");
const message = @import("../object/message.zig");
const mailinfo = @import("../mail/mail.zig");
const apply_mod = @import("apply.zig");
const patchparse = @import("patch.zig");
const threeway = @import("../merge/threeway.zig");
const reset = @import("../commit/reset.zig");
const rerere = @import("../merge/rerere.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const signing = @import("../object/signing.zig");
const gitdate = @import("../text/date.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const Index = index_mod.Index;

const state_dir = "rebase-apply";

/// Errors from `am`.
pub const Error = error{
    /// A session is already in progress.
    AmInProgress,
    /// `rebase-apply` is there with no session in it: git's "Stray
    /// rebase-apply directory found", which `abort` and `quit` remove.
    RebaseInProgress,
    /// `proceed`, `skip`, `abort` or `quit` with no session.
    NoAmInProgress,
    /// The input is none of the formats `am` reads: git's "Patch format
    /// detection failed".
    PatchFormatUnknown,
    /// StGit or Mercurial patches, which git converts and this refuses by
    /// name.
    UnsupportedPatchFormat,
    /// The index has changes from `HEAD`: git's "Dirty index".
    DirtyIndex,
    /// The repository has no working tree.
    BareRepository,
    /// A state file does not say what git writes in it.
    MalformedState,
    /// `apply-opt` holds an option this package does not pass to
    /// `apply`.
    UnsupportedApplyOption,
    /// A mail's `Date:` is not a date git reads.
    InvalidDate,
    /// The author or committer name or address is empty.
    EmptyIdent,
    /// `proceed` with nothing staged and nothing to record.
    NothingToCommit,
    /// `proceed` with conflicts still in the index.
    UnmergedIndex,
    /// `abort` would lose changes made since the session stopped.
    LocalChangesWouldBeOverwritten,
} || mailinfo.Error || apply_mod.Error || threeway.Error || rerere.Error || hooks_mod.Error ||
    repo_mod.WriteError || head_mod.Error || index_mod.ReadError || index_mod.WriteError || worktree.Error ||
    Io.Dir.ReadFileAllocError || Io.Dir.DeleteTreeError || Io.Dir.RealPathError;

/// `-k` and `--keep-non-patch`.
pub const Keep = enum { no, subject, non_patch };

/// `--empty`: what a mail with no patch does.
pub const Empty = enum { stop, drop, keep };

/// The options `am` passes to `apply`, as `git am` takes them.
pub const ApplyOptions = struct {
    whitespace: ?apply_mod.Whitespace = null,
    strip: ?usize = null,
    min_context: ?usize = null,
    directory: []const u8 = "",
    ignore_space_change: bool = false,
    reject: bool = false,
    limits: []const apply_mod.Limit = &.{},
};

/// How a session runs.
pub const Options = struct {
    /// Who commits, and when: git's committer identity and clock.
    committer: object.Signature,
    /// `--3way`; `null` reads `am.threeway`.
    three_way: ?bool = null,
    keep: Keep = .no,
    /// `--message-id`; `null` reads `am.messageid`.
    message_id: ?bool = null,
    /// `--scissors` / `--no-scissors`; `null` reads `mailinfo.scissors`.
    scissors: ?bool = null,
    /// `--quoted-cr`; `null` reads `mailinfo.quotedCr`.
    quoted_cr: ?mailinfo.QuotedCr = null,
    /// `-s`.
    signoff: bool = false,
    /// `--no-utf8` is `false`.
    utf8: bool = true,
    /// `--keep-cr`; `null` reads `am.keepcr`.
    keep_cr: ?bool = null,
    empty: Empty = .stop,
    /// `--ignore-date`: the committer's time is the author's.
    ignore_date: bool = false,
    /// `--committer-date-is-author-date`.
    committer_date_is_author_date: bool = false,
    /// `--patch-format=mboxrd`.
    mboxrd: bool = false,
    /// `--quiet`, which is only recorded, since nothing is printed.
    quiet: bool = false,
    /// What is passed to `apply`.
    apply: ApplyOptions = .{},
    /// The hooks; `null` runs none.
    hooks: ?*hooks_mod.Runner = null,
    /// `--no-verify`: `applypatch-msg` and `pre-applypatch` are not run.
    verify: bool = true,
    /// Signing, `commit.gpgSign` deciding by default.
    signing: signing.Request = .{},
    /// For `proceed`: `--allow-empty`, an empty patch committed as it is.
    allow_empty: bool = false,
};

/// Why a session stopped.
pub const StopReason = enum {
    /// The patch did not apply, and there was no three-way fallback or it
    /// failed.
    does_not_apply,
    /// The three-way fallback left conflicts.
    conflicts,
    /// The mail had no patch, and `empty` is `.stop`.
    empty_patch,
};

/// Where a session stopped.
pub const Stop = struct {
    /// The mail's number, as its file in `rebase-apply` is named.
    number: usize,
    reason: StopReason,
    /// The commit message's first line.
    subject: []const u8,
    /// The paths left conflicted.
    conflicted: []const []const u8 = &.{},
};

/// What a run did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// The commits made, in order.
    commits: []const Oid,
    /// Mails passed over: dropped empties, mailer folder data, patches
    /// already applied.
    skipped: usize,
    /// Where the session stopped; `null` when it finished.
    stopped: ?Stop,

    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// Whether an `am` session is in progress: `rebase-apply` with `next` and
/// `last` in it.
pub fn inProgress(io: Io, repo: *Repository) bool {
    return head_mod.stateExists(io, repo.gitDirectory(), state_dir ++ "/next") and head_mod.stateExists(io, repo.gitDirectory(), state_dir ++ "/last");
}

const Session = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,
    dir: Io.Dir,
    cur: usize = 1,
    last: usize = 0,
    prec: usize = 4,
    threeway: bool = false,
    quiet: bool = false,
    signoff: bool = false,
    utf8: bool = true,
    keep: Keep = .no,
    message_id: bool = false,
    scissors: ?bool = null,
    quoted_cr: ?mailinfo.QuotedCr = null,
    apply_opt: []const []const u8 = &.{},
    author_name: ?[]const u8 = null,
    author_email: ?[]const u8 = null,
    author_date: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    commits: std.ArrayList(Oid) = .empty,
    skipped: usize = 0,

    fn path(s: *Session, name: []const u8) Allocator.Error![]const u8 {
        return s.a.print(state_dir ++ "/{s}", .{name});
    }

    fn write(s: *Session, name: []const u8, bytes: []const u8) Error!void {
        try head_mod.writeState(s.io, s.repo.gitDirectory(), try s.path(name), bytes);
    }

    /// git's `write_file`: the text with its line completed.
    fn writeText(s: *Session, name: []const u8, text: []const u8) Error!void {
        if (text.len == 0 or text[text.len - 1] == '\n') return s.write(name, text);
        try s.write(name, try std.mem.concat(s.a, u8, &.{ text, "\n" }));
    }

    fn writeBool(s: *Session, name: []const u8, value: bool) Error!void {
        try s.writeText(name, if (value) "t" else "f");
    }

    fn read(s: *Session, name: []const u8) Error!?[]const u8 {
        const bytes = (try head_mod.readState(s.a, s.io, s.repo.gitDirectory(), try s.path(name))) orelse return null;
        return bytes;
    }

    fn readTrim(s: *Session, name: []const u8) Error![]const u8 {
        const bytes = (try s.read(name)) orelse return "";
        return std.mem.trim(u8, bytes, " \t\r\n");
    }

    fn remove(s: *Session, name: []const u8) Error!void {
        try head_mod.removeState(s.io, s.repo.gitDirectory(), try s.path(name));
    }

    fn exists(s: *Session, name: []const u8) Error!bool {
        return head_mod.stateExists(s.io, s.repo.gitDirectory(), try s.path(name));
    }

    fn msgnum(s: *Session) Allocator.Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const digits = std.fmt.count("{d}", .{s.cur});
        if (digits < s.prec) try buf.appendNTimes(s.a, '0', s.prec - digits);
        try buf.print(s.a, "{d}", .{s.cur});
        return buf.items;
    }
};

//=========================================================================
// Starting
//=========================================================================

const Format = enum { mbox, mboxrd };

fn firstLines(text: []const u8) [3][]const u8 {
    var out: [3][]const u8 = .{ "", "", "" };
    var at: usize = 0;
    // the first line that is not empty, then the two after it
    var n: usize = 0;
    var found_first = false;
    while (at < text.len and n < 3) {
        const end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
        var line = text[at..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        at = end + 1;
        if (!found_first and line.len == 0) continue;
        found_first = true;
        out[n] = line;
        n += 1;
    }
    return out;
}

/// git's `is_mail`: every unindented line of the header matches a field
/// name and a colon.
fn isMail(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        if (line[0] == '\t' or line[0] == ' ') continue;
        var i: usize = 0;
        while (i < line.len and line[i] >= '!' and line[i] <= '~' and line[i] != ':') i += 1;
        if (i == 0 or i >= line.len or line[i] != ':') return false;
    }
    return true;
}

fn detectFormat(input: []const u8) Error!Format {
    const lines = firstLines(input);
    const l1 = lines[0];
    if (std.mem.startsWith(u8, l1, "From ") or std.mem.startsWith(u8, l1, "From: ")) return .mbox;
    if (std.mem.startsWith(u8, l1, "# This series applies on GIT commit")) return error.UnsupportedPatchFormat;
    if (std.mem.eql(u8, l1, "# HG changeset patch")) return error.UnsupportedPatchFormat;
    if (l1.len > 0 and lines[1].len == 0 and (std.mem.startsWith(u8, lines[2], "From:") or
        std.mem.startsWith(u8, lines[2], "Author:") or std.mem.startsWith(u8, lines[2], "Date:"))) return error.UnsupportedPatchFormat;
    if (l1.len > 0 and isMail(input)) return .mbox;
    return error.PatchFormatUnknown;
}

/// git's `sq_quote_buf`.
fn sqQuote(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(a, '\'');
    for (text) |c| {
        if (c == '\'' or c == '!') {
            try out.appendSlice(a, "'\\");
            try out.append(a, c);
            try out.append(a, '\'');
        } else try out.append(a, c);
    }
    try out.append(a, '\'');
}

/// git's `sq_dequote_step` over a whole string: the words, or `null`.
fn sqDequoteWords(a: Allocator, text: []const u8) Allocator.Error!?[]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return words.items;
    var at: usize = 0;
    while (true) {
        if (at >= text.len or text[at] != '\'') return null;
        var word: std.ArrayList(u8) = .empty;
        var i = at + 1;
        var after: ?usize = null;
        while (true) {
            if (i >= text.len) return null;
            const c = text[i];
            if (c != '\'') {
                try word.append(a, c);
                i += 1;
                continue;
            }
            // out of the quotes
            i += 1;
            if (i >= text.len) break;
            if (text[i] == '\\' and i + 2 < text.len and (text[i + 1] == '\'' or text[i + 1] == '!') and text[i + 2] == '\'') {
                try word.append(a, text[i + 1]);
                i += 3;
                continue;
            }
            after = i;
            break;
        }
        try words.append(a, word.items);
        const n = after orelse break;
        if (!std.ascii.isWhitespace(text[n])) return null;
        at = n;
        while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
        if (at >= text.len) return null;
    }
    return words.items;
}

/// The `git apply` words `options` stand for, in the order `git am`
/// collects them.
fn applyWords(a: Allocator, o: ApplyOptions) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    if (o.whitespace) |w| try words.append(a, try a.print("--whitespace={s}", .{switch (w) {
        .nowarn => "nowarn",
        .warn => "warn",
        .fix => "fix",
        .@"error" => "error",
        .error_all => "error-all",
    }}));
    if (o.ignore_space_change) try words.append(a, "--ignore-space-change");
    if (o.directory.len > 0) try words.append(a, try a.print("--directory={s}", .{o.directory}));
    for (o.limits) |l| try words.append(a, try a.print("--{s}={s}", .{ if (l.include) "include" else "exclude", l.pattern }));
    if (o.min_context) |c| try words.append(a, try a.print("-C{d}", .{c}));
    if (o.strip) |p| try words.append(a, try a.print("-p{d}", .{p}));
    if (o.reject) try words.append(a, "--reject");
    return words.items;
}

/// `apply` options from `git apply` words, as `am` passes them.
fn applyOptionsFrom(a: Allocator, words: []const []const u8) Error!apply_mod.Options {
    var o: apply_mod.Options = .{ .target = .index };
    var limits: std.ArrayList(apply_mod.Limit) = .empty;
    for (words) |w| {
        if (std.mem.startsWith(u8, w, "--whitespace=")) {
            o.whitespace = apply_mod.Whitespace.parse(w["--whitespace=".len..]) orelse return error.UnsupportedApplyOption;
        } else if (std.mem.eql(u8, w, "--ignore-space-change") or std.mem.eql(u8, w, "--ignore-whitespace")) {
            o.ignore_space_change = true;
        } else if (std.mem.startsWith(u8, w, "--directory=")) {
            o.directory = w["--directory=".len..];
        } else if (std.mem.startsWith(u8, w, "--include=")) {
            try limits.append(a, .{ .pattern = w["--include=".len..], .include = true });
        } else if (std.mem.startsWith(u8, w, "--exclude=")) {
            try limits.append(a, .{ .pattern = w["--exclude=".len..], .include = false });
        } else if (std.mem.startsWith(u8, w, "-C")) {
            o.min_context = std.fmt.parseInt(usize, w[2..], 10) catch return error.UnsupportedApplyOption;
        } else if (std.mem.startsWith(u8, w, "-p")) {
            o.strip = std.fmt.parseInt(usize, w[2..], 10) catch return error.UnsupportedApplyOption;
        } else if (std.mem.eql(u8, w, "--reject")) {
            o.reject = true;
        } else return error.UnsupportedApplyOption;
    }
    o.limits = limits.items;
    return o;
}

/// `git am <mailboxes>`: start a session over the mails in `mailboxes`,
/// each a mailbox's whole contents, and run it until it finishes or stops.
pub fn start(gpa: Allocator, io: Io, repo: *Repository, mailboxes: []const []const u8, options: Options) Self.Error!Outcome {
    if (repo.workDirectory() == null) return error.BareRepository;
    if (inProgress(io, repo)) return error.AmInProgress;
    if (head_mod.stateExists(io, repo.gitDirectory(), state_dir)) return error.RebaseInProgress;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const a = arena_instance.allocator();
    const config = repo.configuration();
    var s: Session = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options, .dir = repo.gitDirectory() };

    const format: Format = if (options.mboxrd) .mboxrd else if (mailboxes.len == 0) .mbox else try detectFormat(mailboxes[0]);

    try repo.gitDirectory().createDirPath(io, state_dir);
    try repo.refStore().root().delete(repo.allocator(), io, .rebase_head);

    // the mails, cut as `git mailsplit -d4 -b` cuts them
    const keep_cr = options.keep_cr orelse (config.getBool("am.keepcr", false) catch false);
    var count: usize = 0;
    for (mailboxes) |box| {
        var cut = mailinfo.split(gpa, box, .{ .keep_cr = keep_cr, .mboxrd = format == .mboxrd, .allow_bare = true }) catch |err| {
            // ziglint-ignore: Z026 the split's error is the one to report; a state directory left behind is what `am --abort` removes
            destroy(io, repo) catch {};
            return err;
        };
        defer cut.deinit();
        for (cut.messages) |m| {
            count += 1;
            s.cur = count;
            try s.write(try s.msgnum(), m);
        }
    }
    s.cur = 1;
    s.last = count;

    s.threeway = options.three_way orelse (config.getBool("am.threeway", false) catch false);
    s.quiet = options.quiet;
    s.signoff = options.signoff;
    s.utf8 = options.utf8;
    s.keep = options.keep;
    s.message_id = options.message_id orelse (config.getBool("am.messageid", false) catch false);
    s.scissors = options.scissors;
    s.quoted_cr = options.quoted_cr;
    s.apply_opt = try applyWords(a, options.apply);

    try s.writeBool("threeway", s.threeway);
    try s.writeBool("quiet", s.quiet);
    try s.writeBool("sign", s.signoff);
    try s.writeBool("utf8", s.utf8);
    try s.writeText("keep", switch (s.keep) {
        .no => "f",
        .subject => "t",
        .non_patch => "b",
    });
    try s.writeBool("messageid", s.message_id);
    try s.writeText("scissors", if (s.scissors) |v| (if (v) "t" else "f") else "");
    try s.writeText("quoted-cr", if (s.quoted_cr) |q| @tagName(q) else "");
    var opt_text: std.ArrayList(u8) = .empty;
    for (s.apply_opt) |w| {
        try opt_text.append(a, ' ');
        try sqQuote(a, &opt_text, w);
    }
    try s.writeText("apply-opt", opt_text.items);
    try s.writeText("applying", "");

    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    if (head.oid) |oid| {
        var hex: [hash.max_hex_len]u8 = undefined;
        try s.writeText("abort-safety", oid.hex(&hex));
        try repo.refStore().root().write(repo.allocator(), io, .orig_head, oid);
    } else {
        try s.writeText("abort-safety", "");
        try repo.refStore().root().delete(repo.allocator(), io, .orig_head);
    }
    try s.writeText("next", try a.print("{d}", .{s.cur}));
    try s.writeText("last", try a.print("{d}", .{s.last}));

    return run(&s, &arena_instance, false);
}

fn destroy(io: Io, repo: *Repository) Error!void {
    try repo.gitDirectory().deleteTree(io, state_dir);
}

//=========================================================================
// Loading a session
//=========================================================================

fn load(gpa: Allocator, a: Allocator, io: Io, repo: *Repository, options: Options) Error!Session {
    if (!inProgress(io, repo)) return error.NoAmInProgress;
    var s: Session = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = options, .dir = repo.gitDirectory() };
    try reload(&s);
    return s;
}

fn reload(s: *Session) Error!void {
    s.cur = std.fmt.parseInt(usize, try s.readTrim("next"), 10) catch return error.MalformedState;
    s.last = std.fmt.parseInt(usize, try s.readTrim("last"), 10) catch return error.MalformedState;
    s.author_name = null;
    s.author_email = null;
    s.author_date = null;
    if (try s.read("author-script")) |script| {
        const parsed = try parseAuthorScript(s.a, script);
        s.author_name = parsed[0];
        s.author_email = parsed[1];
        s.author_date = parsed[2];
    }
    s.msg = try s.read("final-commit");
    s.threeway = std.mem.eql(u8, try s.readTrim("threeway"), "t");
    s.quiet = std.mem.eql(u8, try s.readTrim("quiet"), "t");
    s.signoff = std.mem.eql(u8, try s.readTrim("sign"), "t");
    s.utf8 = std.mem.eql(u8, try s.readTrim("utf8"), "t");
    const keep = try s.readTrim("keep");
    s.keep = if (std.mem.eql(u8, keep, "t")) .subject else if (std.mem.eql(u8, keep, "b")) .non_patch else .no;
    s.message_id = std.mem.eql(u8, try s.readTrim("messageid"), "t");
    const scissors = try s.readTrim("scissors");
    s.scissors = if (std.mem.eql(u8, scissors, "t")) true else if (std.mem.eql(u8, scissors, "f")) false else null;
    const qcr = try s.readTrim("quoted-cr");
    s.quoted_cr = if (qcr.len == 0) null else std.meta.stringToEnum(mailinfo.QuotedCr, qcr) orelse return error.MalformedState;
    s.apply_opt = (try sqDequoteWords(s.a, try s.readTrim("apply-opt"))) orelse return error.MalformedState;
}

/// `parse_key_value_squoted` over `author-script`.
fn parseAuthorScript(a: Allocator, text: []const u8) Error![3][]const u8 {
    var out: [3]?[]const u8 = .{ null, null, null };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse return error.MalformedState;
        const key = line[0..eq];
        const words = (try sqDequoteWords(a, line[eq + 1 ..])) orelse return error.MalformedState;
        if (words.len != 1) return error.MalformedState;
        const slot: usize = if (std.mem.eql(u8, key, "GIT_AUTHOR_NAME")) 0 else if (std.mem.eql(u8, key, "GIT_AUTHOR_EMAIL")) 1 else if (std.mem.eql(u8, key, "GIT_AUTHOR_DATE")) 2 else return error.MalformedState;
        if (out[slot] != null) return error.MalformedState;
        out[slot] = words[0];
    }
    return .{ out[0] orelse return error.MalformedState, out[1] orelse return error.MalformedState, out[2] orelse return error.MalformedState };
}

//=========================================================================
// Running
//=========================================================================

fn writeAuthorScript(s: *Session) Error!void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(s.a, "GIT_AUTHOR_NAME=");
    try sqQuote(s.a, &out, s.author_name.?);
    try out.appendSlice(s.a, "\nGIT_AUTHOR_EMAIL=");
    try sqQuote(s.a, &out, s.author_email.?);
    try out.appendSlice(s.a, "\nGIT_AUTHOR_DATE=");
    try sqQuote(s.a, &out, s.author_date.?);
    try out.append(s.a, '\n');
    try s.writeText("author-script", out.items);
}

/// `parse_mail`: take mail `name` apart into `info`, `msg` and `patch`,
/// and set the author and the message. `false` for a mail to pass over.
fn parseMail(s: *Session, name: []const u8) Error!bool {
    const config = s.repo.configuration();
    const mail = (try s.read(name)).?;
    var options: mailinfo.InfoOptions = .{
        .utf8 = s.utf8,
        .keep_subject = s.keep == .subject,
        .keep_non_patch_brackets = s.keep == .non_patch,
        .add_message_id = s.message_id,
        .scissors = s.scissors orelse (config.getBool("mailinfo.scissors", false) catch false),
    };
    if (s.quoted_cr) |q| {
        options.quoted_cr = q;
    } else if (config.get("mailinfo.quotedcr")) |v| {
        options.quoted_cr = std.meta.stringToEnum(mailinfo.QuotedCr, v) orelse .warn;
    }
    var parsed = try mailinfo.info(s.gpa, mail, options);
    defer parsed.deinit();
    try s.write("msg", parsed.message);
    try s.write("patch", parsed.patch);
    try s.write("info", parsed.info);

    // the message: every Subject line, a blank line and the body, cleaned
    var msg: std.ArrayList(u8) = .empty;
    var author_name: []const u8 = "";
    var author_email: []const u8 = "";
    var author_date: []const u8 = "";
    var lines = std.mem.splitScalar(u8, parsed.info, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Subject: ")) {
            if (msg.items.len > 0) try msg.append(s.a, '\n');
            try msg.appendSlice(s.a, line["Subject: ".len..]);
        } else if (std.mem.startsWith(u8, line, "Author: ")) {
            author_name = try s.a.dupe(u8, line["Author: ".len..]);
        } else if (std.mem.startsWith(u8, line, "Email: ")) {
            author_email = try s.a.dupe(u8, line["Email: ".len..]);
        } else if (std.mem.startsWith(u8, line, "Date: ")) {
            author_date = try s.a.dupe(u8, line["Date: ".len..]);
        }
    }
    if (std.mem.eql(u8, author_name, "Mail System Internal Data")) return false;
    try msg.appendSlice(s.a, "\n\n");
    try msg.appendSlice(s.a, parsed.message);
    s.msg = try message.stripSpace(s.a, msg.items, null);
    s.author_name = author_name;
    s.author_email = author_email;
    s.author_date = author_date;
    return true;
}

fn subjectOf(msg: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, msg, '\n') orelse msg.len;
    return msg[0..end];
}

/// The index against `HEAD`'s tree, or the empty tree on an unborn
/// branch: whether anything is staged.
fn indexHasChanges(s: *Session, index: *const Index) Error!bool {
    var head = try head_mod.read(s.gpa, s.io, s.repo);
    defer head.deinit(s.gpa);
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const entries = if (head.oid) |oid| try worktree.flatten(scratch.allocator(), s.io, s.repo.objectDatabase(), try s.repo.commitTree(s.io, oid)) else std.StringHashMapUnmanaged(worktree.TreeEntry).empty;
    var count: usize = 0;
    for (index.entries.items) |e| {
        if (e.stage != 0) return true;
        const want = entries.get(e.path) orelse return true;
        if (want.mode != e.mode or !want.oid.eql(e.oid) or e.intent_to_add) return true;
        count += 1;
    }
    return count != entries.count();
}

fn hasUnmerged(index: *const Index) bool {
    for (index.entries.items) |e| if (e.stage != 0) return true;
    return false;
}

fn absolutePath(s: *Session, name: []const u8) Error![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try s.repo.gitDirectory().realPath(s.io, &buf);
    return std.Io.Dir.path.join(s.a, &.{ buf[0..len], state_dir, name });
}

fn runHook(s: *Session, event: []const u8, args: []const []const u8) Error!bool {
    const runner = s.options.hooks orelse return true;
    const ran = try runner.run(s.io, event, .{ .args = args });
    return ran.failure == null;
}

fn finalCommitDeleted(s: *Session) Error!void {
    s.msg = (try s.read("final-commit")) orelse return error.MalformedState;
}

const Applied = enum { applied, failed, conflicts, no_changes };

/// Whether `apply` refused the patch itself, rather than failed to read or
/// write: what `git am` stops at.
fn patchFailure(err: anyerror) bool {
    inline for (@typeInfo(patchparse.Error).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name) and err != error.OutOfMemory) return true;
    }
    return switch (err) {
        error.PatchDoesNotApply, error.NoValidPatches, error.WhitespaceErrors, error.ConflictingWhitespaceRules, error.PatchTooLarge => true,
        else => false,
    };
}

/// `run_apply` with the index, then `fall_back_threeway` when allowed.
fn applyPatch(s: *Session, outcome_conflicts: *[]const []const u8) Error!Applied {
    const patch = (try s.read("patch")) orelse "";
    var options = try applyOptionsFrom(s.a, s.apply_opt);
    options.whitespace = options.whitespace orelse blk: {
        // apply's default under am is warn, as git apply's is
        break :blk null;
    };
    if (apply_mod.apply(s.gpa, s.io, s.repo, patch, options)) |result| {
        var r = result;
        defer r.deinit();
        if (r.clean()) return .applied;
        return .failed;
    } else |err| {
        if (!patchFailure(err)) return err;
    }
    if (!s.threeway) return .failed;
    return fallBackThreeway(s, patch, options, outcome_conflicts);
}

/// git's `fall_back_threeway`: a base built from the blobs the patch's
/// `index` lines name, the patch applied to it, and the two merged into
/// `HEAD`.
fn fallBackThreeway(s: *Session, patch: []const u8, apply_options: apply_mod.Options, conflicts: *[]const []const u8) Error!Applied {
    const gpa = s.gpa;
    const io = s.io;
    const repo = s.repo;
    const db = repo.objectDatabase();
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);

    // the fake ancestor: every file the patch changes, at its old blob
    // Read as the apply that failed read it, its directory and limits too.
    var parsed = apply_mod.keptFiles(gpa, patch, apply_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .failed,
    };
    defer parsed.deinit();
    var current = try repo.openIndex(io);
    defer current.deinit();
    var fake: Index = .initEmpty(gpa, repo.objectFormat());
    defer fake.deinit();
    for (parsed.files) |f| {
        if (f.is_new == .yes) continue;
        const name = f.old_name orelse f.new_name.?;
        var oid: Oid = undefined;
        if (patchparse.isGitlink(f.old_mode)) return .failed;
        if (db.findPrefix(io, f.old_oid_prefix)) |found| {
            oid = found;
        } else |_| {
            if (f.lines_added == 0 and f.lines_deleted == 0) {
                const e = current.find(name) orelse return .failed;
                oid = e.oid;
            } else return .failed;
        }
        const mode: object.Mode = switch (patchparse.kind(f.old_mode)) {
            0o120000 => .symlink,
            0o160000 => .gitlink,
            else => if (f.old_mode & 0o100 != 0) .exec else .file,
        };
        try fake.add(.{ .path = name, .oid = oid, .mode = mode });
    }
    const base_tree = worktree.writeTree(gpa, io, &fake, db) catch return .failed;
    // the patch applied to it
    var cached = apply_options;
    cached.target = .cached;
    cached.index = &fake;
    if (apply_mod.apply(gpa, io, repo, patch, cached)) |result| {
        var r = result;
        r.deinit();
    } else |err| {
        if (patchFailure(err)) return .failed;
        return err;
    }
    const their_tree = try worktree.writeTree(gpa, io, &fake, db);
    try fake.write(io, repo.gitDirectory(), state_dir ++ "/patch-merge-index", .{});

    const our_tree = if (head.oid) |oid| try repo.commitTree(io, oid) else try emptyTree(s);
    const label = try s.a.print("{s}", .{subjectOf(s.msg.?)});
    var outcome = try threeway.apply(gpa, io, repo, .{ .index = &current, .base = base_tree, .ours = our_tree, .theirs = their_tree }, .{
        .blob = .{ .algorithm = .histogram, .labels = .{ .ours = "HEAD", .base = "constructed fake ancestor", .theirs = label } },
        .directory_renames = .off,
    });
    defer outcome.deinit();
    try repo.writeIndex(io, &current);
    if (!outcome.isClean()) {
        _ = try rerere.afterStop(gpa, io, repo, &current, .{ .arena = s.a, .autoupdate = null });
        var paths: std.ArrayList([]const u8) = .empty;
        for (outcome.conflicts) |c| try paths.append(s.a, try s.a.dupe(u8, c.path));
        conflicts.* = paths.items;
        return .conflicts;
    }
    if (!try indexHasChanges(s, &current)) return .no_changes;
    return .applied;
}

fn emptyTree(s: *Session) Error!Oid {
    return s.repo.objectDatabase().write(s.io, .tree, "");
}

/// `do_commit`.
fn doCommit(s: *Session) Error!void {
    const gpa = s.gpa;
    const io = s.io;
    const repo = s.repo;
    if (s.options.verify) {
        if (!try runHook(s, "pre-applypatch", &.{})) return error.HookRejected;
    }
    var index = try repo.openIndex(io);
    defer index.deinit();
    const tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());
    try repo.writeIndex(io, &index);
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);

    if (s.author_name.?.len == 0 or s.author_email.?.len == 0) return error.EmptyIdent;
    const committer = s.options.committer;
    var author: object.Signature = .{ .name = s.author_name.?, .email = s.author_email.?, .when_secs = committer.when_secs, .offset_minutes = committer.offset_minutes };
    if (!s.options.ignore_date and s.author_date.?.len > 0) {
        const parsed = gitdate.parse(s.author_date.?, .{ .now = committer.when_secs, .local_offset_minutes = committer.offset_minutes }) orelse return error.InvalidDate;
        author.when_secs = parsed.secs;
        author.offset_minutes = @intCast(parsed.offset_minutes);
    }
    var commit_who = committer;
    if (s.options.committer_date_is_author_date) {
        commit_who.when_secs = author.when_secs;
        commit_who.offset_minutes = author.offset_minutes;
    }
    const parents: []const Oid = if (head.oid) |oid| &.{oid} else &.{};
    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = parents,
        .author = author,
        .committer = commit_who,
        .message = s.msg.?,
        .signing = s.options.signing,
    }, null);
    const log_message = try s.a.print("am: {s}", .{subjectOf(s.msg.?)});
    try head_mod.advance(io, repo, head, commit, .{ .who = committer, .message = log_message });
    try s.commits.append(s.a, commit);
    _ = try runHook(s, "post-applypatch", &.{});
}

/// `am_next`.
fn next(s: *Session) Error!void {
    s.author_name = null;
    s.author_email = null;
    s.author_date = null;
    s.msg = null;
    try s.remove("author-script");
    try s.remove("final-commit");
    try s.remove("original-commit");
    try s.repo.refStore().root().delete(s.repo.allocator(), s.io, .rebase_head);
    var head = try head_mod.read(s.gpa, s.io, s.repo);
    defer head.deinit(s.gpa);
    if (head.oid) |oid| {
        var hex: [hash.max_hex_len]u8 = undefined;
        try s.writeText("abort-safety", oid.hex(&hex));
    } else try s.writeText("abort-safety", "");
    s.cur += 1;
    try s.writeText("next", try s.a.print("{d}", .{s.cur}));
}

fn isEmptyOrMissing(s: *Session, name: []const u8) Error!bool {
    const bytes = (try s.read(name)) orelse return true;
    return bytes.len == 0;
}

fn finish(s: *Session, arena: *std.heap.ArenaAllocator, stopped: ?Stop) Outcome {
    return .{ .gpa = s.gpa, .arena = arena.state, .commits = s.commits.items, .skipped = s.skipped, .stopped = stopped };
}

/// `am_run`.
fn run(s: *Session, arena: *std.heap.ArenaAllocator, resume_in: bool) Error!Outcome {
    var resuming = resume_in;
    try s.remove("dirtyindex");
    {
        var index = try s.repo.openIndex(s.io);
        defer index.deinit();
        if (try indexHasChanges(s, &index)) {
            try s.writeBool("dirtyindex", true);
            return error.DirtyIndex;
        }
    }
    while (s.cur <= s.last) {
        const name = try s.msgnum();
        if (!try s.exists(name)) {
            try next(s);
            if (resuming) try reload(s);
            resuming = false;
            continue;
        }
        var pass = false;
        if (resuming) {
            if (s.msg == null or s.author_name == null) return error.MalformedState;
        } else {
            pass = !try parseMail(s, name);
            if (!pass) {
                if (s.signoff) {
                    var msg: std.ArrayList(u8) = .empty;
                    try msg.appendSlice(s.a, s.msg.?);
                    try message.appendSignoff(s.a, &msg, s.options.committer, try message.trailerSettings(s.a, s.repo.configuration()));
                    s.msg = msg.items;
                }
                try writeAuthorScript(s);
                try s.write("final-commit", s.msg.?);
            }
        }
        var commit_now = false;
        if (!pass) {
            if (try isEmptyOrMissing(s, "patch")) {
                switch (s.options.empty) {
                    .drop => pass = true,
                    .keep => commit_now = true,
                    .stop => return finish(s, arena, .{ .number = s.cur, .reason = .empty_patch, .subject = subjectOf(s.msg.?) }),
                }
            }
        }
        if (!pass) {
            if (s.options.verify) {
                const final_path = try absolutePath(s, "final-commit");
                if (!try runHook(s, "applypatch-msg", &.{final_path})) return error.HookRejected;
                try finalCommitDeleted(s);
            }
            if (!commit_now) {
                var conflicts: []const []const u8 = &.{};
                switch (try applyPatch(s, &conflicts)) {
                    .applied => commit_now = true,
                    .no_changes => pass = true,
                    .failed => return finish(s, arena, .{ .number = s.cur, .reason = .does_not_apply, .subject = subjectOf(s.msg.?) }),
                    .conflicts => return finish(s, arena, .{ .number = s.cur, .reason = .conflicts, .subject = subjectOf(s.msg.?), .conflicted = conflicts }),
                }
            }
            if (commit_now) try doCommit(s);
        }
        if (pass) s.skipped += 1;
        try next(s);
        if (resuming) try reload(s);
        resuming = false;
    }
    try destroy(s.io, s.repo);
    return finish(s, arena, null);
}

/// `git am --continue`: commit what the index holds for the patch the
/// session stopped at, and go on.
pub fn proceed(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    var s = try load(gpa, arena_instance.allocator(), io, repo, options);
    if (s.msg == null or s.author_name == null) return error.MalformedState;
    var index = try repo.openIndex(io);
    defer index.deinit();
    if (!try indexHasChanges(&s, &index)) {
        if (!(options.allow_empty and try isEmptyOrMissing(&s, "patch"))) return error.NothingToCommit;
    }
    if (hasUnmerged(&index)) return error.UnmergedIndex;
    var rr = try rerere.run(gpa, io, repo, &index, .{});
    rr.deinit();
    try doCommit(&s);
    try next(&s);
    try reload(&s);
    return run(&s, &arena_instance, false);
}

/// `git am --skip`: drop the patch the session stopped at, putting the
/// index and the working tree back to `HEAD`, and go on.
pub fn skip(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    var s = try load(gpa, arena_instance.allocator(), io, repo, options);
    try rerere.clear(gpa, io, repo);
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const tree = if (head.oid) |oid| try repo.commitTree(io, oid) else try emptyTree(&s);
    var index = try repo.openIndex(io);
    defer index.deinit();
    try reset.toTree(gpa, io, repo, .{ .index = &index, .tree = tree, .mode = .merge, .blocked = null });
    try repo.writeIndex(io, &index);
    try next(&s);
    try reload(&s);
    return run(&s, &arena_instance, false);
}

/// `git am --abort`: put `HEAD`, the index and the working tree back where
/// the session started, unless `HEAD` moved since it stopped, and end it.
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, who: object.Signature) Self.Error!void {
    if (!inProgress(io, repo)) return destroyStray(io, repo);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();
    var s: Session = .{ .gpa = gpa, .a = a, .io = io, .repo = repo, .options = .{ .committer = who }, .dir = repo.gitDirectory() };
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    // safe to abort only when the index was clean and HEAD has not moved
    var safe = !try s.exists("dirtyindex");
    if (safe) {
        const recorded = try s.readTrim("abort-safety");
        if (recorded.len == 0) {
            safe = head.oid == null;
        } else {
            const expected = Oid.parse(repo.objectFormat(), recorded) catch return error.MalformedState;
            safe = head.oid != null and head.oid.?.eql(expected);
        }
    }
    if (!safe) return destroy(io, repo);
    try rerere.clear(gpa, io, repo);
    const orig = try repo.refStore().root().read(gpa, io, .orig_head);
    const target_tree = if (orig) |o| try repo.commitTree(io, o) else try emptyTree(&s);
    var index = try repo.openIndex(io);
    defer index.deinit();
    reset.toTree(gpa, io, repo, .{ .index = &index, .tree = target_tree, .mode = .merge, .blocked = null }) catch |err| switch (err) {
        error.LocalChangesWouldBeOverwritten => return error.LocalChangesWouldBeOverwritten,
        else => |e| return e,
    };
    try repo.writeIndex(io, &index);
    if (orig) |o| {
        try head_mod.advance(io, repo, head, o, .{ .who = who, .message = "am --abort" });
    } else if (head.branch) |branch| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.delete(branch, .any);
        try tx.commit(io, null);
    }
    try destroy(io, repo);
}

/// `git am --quit`: end the session and leave everything as it is.
pub fn quit(io: Io, repo: *Repository) Self.Error!void {
    if (!inProgress(io, repo)) return destroyStray(io, repo);
    try destroy(io, repo);
}

/// With no session, a `rebase-apply` left behind goes, as git's `--abort`
/// and `--quit` remove a stray one; with none there either, there is
/// nothing to end.
fn destroyStray(io: Io, repo: *Repository) Self.Error!void {
    if (!head_mod.stateExists(io, repo.gitDirectory(), state_dir)) return error.NoAmInProgress;
    try destroy(io, repo);
}
