//! `git format-patch`: commits written as email patches, one mail per
//! commit, byte for byte the mail git writes for the same commits and the
//! same options.
//!
//! A mail is the `From <commit> Mon Sep 17 00:00:00 2001` line, the
//! author as `From:` and the author date as `Date:` (RFC 2047 encoded words
//! for a name that is not ASCII, RFC 822 quoting for one with specials),
//! `Subject:` with its `[PATCH n/m]` prefix, the message, `---`, the
//! diffstat and summary at git's 72 columns, the patch with renames found
//! as git's `-M` finds them, and the signature. Each file's patch is
//! `diff.unified`'s, binary files as `GIT binary patch` hunks. A cover letter, the base tree information, threading and
//! MIME attachments are git's too.
//!
//! What git reads from the clock or the person's identity — a cover
//! letter's date and sender, a thread's message ids, a sign-off — is the
//! caller's to hand in.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const ctype = @import("../text.zig").ctype;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const diff = @import("../diff/diff.zig");
const patch_id = @import("../diff/patch_id.zig");
const rev_walk = @import("../walk/walk.zig");
const abbrev = @import("../odb/abbrev.zig");
const c_quote = @import("../text.zig").c_quote;
const mailfmt = @import("../mail/format.zig");
const unicode_width = @import("../text.zig").unicode_width;
const message = @import("../object/message.zig");
const pretty = @import("../pretty/pretty.zig");
const shortlog = @import("../pretty/shortlog.zig");
const mailmap_mod = @import("../rev_walk/mailmap.zig");
const attributes = @import("../patterns.zig").attributes;

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from formatting patches.
pub const Error = error{
    /// A `diff.<name>.binary` that is neither a boolean nor `auto`, which
    /// git dies on.
    InvalidDriverBinary,
    /// `core.commentChar` or `core.commentString` is one git dies on: no
    /// value, empty, or holding a line break.
    InvalidCommentString,
    /// A name in the range is not a commit.
    NotACommit,
    /// `keep_subject` with `numbered`, which git refuses.
    KeepSubjectWithNumbered,
    /// `keep_subject` with a subject prefix or `rfc`, which git refuses.
    KeepSubjectWithPrefix,
    /// `base` does not reach the commits being formatted, as git requires.
    BaseNotAncestor,
    /// `base` is one of the commits being formatted.
    BaseInRange,
    /// A commit's `encoding` header, or `i18n.logOutputEncoding`, names a
    /// character set `text.encoding.Charset` does not convert, where git
    /// converts it with iconv.
    UnsupportedEncoding,
    /// `i18n.logOutputEncoding` or `i18n.commitEncoding` set with no value,
    /// which git dies on.
    InvalidEncodingSetting,
} || shortlog.Error || rev_walk.Error || diff.Error || diff.ConfigError || diff.Order.ConfiguredError || patch_id.Error || odb_mod.Error || repo_mod.Error || attributes.Error || Allocator.Error ||
    Io.Dir.ReadFileAllocError;

/// A name and an address.
pub const Ident = struct {
    name: []const u8,
    email: []const u8,
};

/// The commits to format.
pub const Range = struct {
    /// Left out, with everything it reaches: `<upstream>` in
    /// `<upstream>..<tip>`. `null` formats from the root, or the last
    /// `max_count` commits.
    upstream: ?Oid = null,
    tip: Oid,
    /// `-<n>`: at most this many, the newest.
    max_count: ?usize = null,
};

/// What the cover letter lists the commits as.
pub const CoverFormat = enum {
    /// `Author (n):` and each subject under it, wrapped: git's default.
    shortlog,
    /// `[n/m] subject` for each, wrapped at 72.
    modern,
};

/// A cover letter: `--cover-letter`.
pub const Cover = struct {
    /// Who sends it and when: git's committer identity and the clock.
    sender: object.Signature,
    format: CoverFormat = .shortlog,
    /// The branch description (`branch.<name>.description`) the subject
    /// and blurb come from; `null` writes git's `*** SUBJECT HERE ***` and
    /// `*** BLURB HERE ***`.
    description: ?[]const u8 = null,
    /// `--cover-from-description`: how the description is used.
    from_description: FromDescription = .message,

    pub const FromDescription = enum {
        /// The whole description is the blurb: git's default.
        message,
        /// Its first paragraph is the subject, the rest the blurb.
        subject,
        /// `subject` unless the first paragraph is over 100 bytes.
        auto,
        /// Not used.
        none,
    };
};

/// How mails are threaded.
pub const Thread = struct {
    style: enum { shallow, deep } = .shallow,
    /// The time git's message ids carry.
    now: std.Io.Timestamp,
    /// The address they end in: git's committer email.
    email: []const u8,
};

/// `--attach` or `--inline`.
pub const Attach = struct {
    boundary: []const u8,
    /// `--inline` rather than `--attach`.
    @"inline": bool = false,
};

/// Rename detection, git's `-M`: by default what `diff.renames` says,
/// which is on when it says nothing.
pub const Renames = union(enum) {
    configured,
    off,
    on: diff.RenameOptions,
};

/// How patches are formatted.
pub const Options = struct {
    /// `-O`: the order the files come in; `null` reads `diff.orderFile`.
    order: ?diff.Order = null,
    /// Where in the working tree the caller stands, `/`-separated and
    /// ending in `/`, empty for the top: git's prefix, which `relative`
    /// takes.
    directory: []const u8 = "",
    /// `--relative`: only the changes under `directory`, named from it;
    /// `null` reads `diff.relative`.
    relative: ?bool = null,
    /// `-n` or `-N`; `null` numbers when there is more than one mail.
    numbered: ?bool = null,
    /// `--start-number`.
    start_number: usize = 1,
    /// `--subject-prefix`.
    subject_prefix: []const u8 = "PATCH",
    /// `--rfc[=<rfc>]`: put before the prefix, or after it when it starts
    /// with `-`.
    rfc: ?[]const u8 = null,
    /// `-v <n>`.
    reroll_count: ?[]const u8 = null,
    /// `-k`: the subject as it is, with no prefix.
    keep_subject: bool = false,
    /// `-s`: a `Signed-off-by:` trailer for this identity.
    signoff: ?Ident = null,
    /// `--cover-letter`.
    cover_letter: ?Cover = null,
    /// `--base=<commit>`: base tree information in the first mail.
    base: ?Oid = null,
    /// The signature after `-- `; `null` is `--no-signature`. git's
    /// default is its own version, which is not this package's to claim.
    signature: ?[]const u8 = null,
    /// `false` is `-p`: the patch with no diffstat.
    stat: bool = true,
    /// `false` is `--no-binary`: `Binary files ... differ`.
    binary: bool = true,
    /// `--zero-commit`.
    zero_commit: bool = false,
    /// `--from=<ident>`: the sender; a different author moves into the
    /// body as an in-body `From:`.
    from: ?Ident = null,
    /// `--force-in-body-from`.
    force_in_body_from: bool = false,
    /// `--to`, `--cc`, `--add-header`.
    to: []const []const u8 = &.{},
    cc: []const []const u8 = &.{},
    headers: []const []const u8 = &.{},
    /// `--in-reply-to`.
    in_reply_to: ?[]const u8 = null,
    /// `--thread`.
    thread: ?Thread = null,
    attach: ?Attach = null,
    /// `--[no-]encode-email-headers`.
    encode_email_headers: bool = true,
    /// `--pretty=mboxrd` with `--stdout`: `From ` lines in the body get a
    /// `>`.
    mboxrd: bool = false,
    /// `--ignore-if-in-upstream`.
    ignore_if_in_upstream: bool = false,
    renames: Renames = .configured,
    /// Context, algorithm and whitespace for the patches. `null` takes
    /// `diff.algorithm` and `diff.context`.
    diff: ?diff.Options = null,
    /// `--suffix`.
    suffix: []const u8 = ".patch",
    /// `--filename-max-length`.
    filename_max_length: usize = 64,
    /// `--numbered-files`.
    numbered_files: bool = false,
    /// `core.quotePath`; `null` reads it.
    quote_path: ?bool = null,
};

/// One mail.
pub const Mail = struct {
    /// The file `format-patch -o` writes it to.
    name: []const u8,
    text: []const u8,
    /// The commit, or `null` for the cover letter.
    commit: ?Oid,
};

/// The mails, in order: the cover letter first when there is one.
pub const Series = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    mails: []const Mail,

    pub fn deinit(s: *Series) void {
        var arena = s.arena.promote(s.gpa);
        arena.deinit();
        s.* = undefined;
    }

    /// Every mail as `format-patch --stdout` writes them: one after
    /// another, a blank line before each patch after the first.
    pub fn writeMbox(s: *const Series, w: *Io.Writer) Io.Writer.Error!void {
        var shown_one = false;
        for (s.mails) |m| {
            if (m.commit != null) {
                if (shown_one) try w.writeByte('\n');
                shown_one = true;
            }
            try w.writeAll(m.text);
        }
    }
};

const Ctx = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    db: *odb_mod.Odb,
    options: Options,
    diff_options: diff.Options,
    renames: ?diff.RenameOptions,
    order: diff.Order,
    /// The directory the changes are limited to and named from, or empty.
    relative_to: []const u8,
    quote_path: bool,
    attrs: ?*attributes.Attrs,
    prefix: []const u8,
    total: i64,
    nr: usize = 0,
    message_id: ?[]const u8 = null,
    ref_ids: std.ArrayList([]const u8) = .empty,
    /// What the mails are written in: `i18n.logOutputEncoding`, as git's
    /// `get_log_output_encoding` gives it.
    encoding: []const u8,

    /// Which files are binary, as git's `diff_filespec_is_binary` says.
    fn binaryRule(ctx: *const Ctx) diff.BinaryRule {
        return .{ .attrs = ctx.attrs, .work_dir = ctx.repo.workDirectory(), .config = ctx.repo.configuration() };
    }
};

/// Format `range` as `git format-patch` would.
pub fn format(gpa: Allocator, io: Io, repo: *Repository, range: Range, options: Options) Self.Error!Series {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const a = arena_instance.allocator();
    const config = repo.configuration();
    const db = repo.objectDatabase();

    if (options.keep_subject and options.numbered == true) return error.KeepSubjectWithNumbered;
    if (options.keep_subject and (options.rfc != null or !std.mem.eql(u8, options.subject_prefix, "PATCH"))) return error.KeepSubjectWithPrefix;

    var diff_options = options.diff orelse try diff.configured(config, .{});
    const renames: ?diff.RenameOptions = switch (options.renames) {
        .off => null,
        .on => |r| r,
        .configured => (try diff.RenameSettings.read(config)).options(),
    };

    const prefix = try subjectPrefix(a, options);

    var own_attrs: ?attributes.Attrs = null;
    defer if (own_attrs) |*x| x.deinit();
    if (repo.workDirectory() != null) own_attrs = try repo.loadAttrs(io);
    defer if (own_attrs) |*x| x.leave();
    const binary: diff.BinaryRule = .{ .attrs = if (own_attrs) |*x| x else null, .work_dir = repo.workDirectory(), .config = config };

    const selected = try selectCommits(gpa, a, io, db, range, options, binary) orelse return emptySeries(gpa, &arena_instance);
    const list = selected.list;

    // the boundary: the one commit outside the range the range grew from
    const origin = try findOrigin(gpa, io, db, selected.in_list, selected.walked);

    var total = list.len;
    var start_number = options.start_number;
    const numbered = if (options.keep_subject) false else options.numbered orelse (total > 1 or options.cover_letter != null);

    var quote_path = true;
    if (options.quote_path) |q| quote_path = q else if (config.get("core.quotepath")) |v| quote_path = config_mod.parseBool(v) catch true;

    const relative_to = if (options.relative orelse try diff.configuredRelative(config)) options.directory else "";
    diff_options.quote_path = quote_path;
    diff_options.abbrev = abbrev.defaultLength(config, db);
    diff_options.relative_to = relative_to;
    diff_options.binary_patches = options.binary;

    var ctx: Ctx = .{
        .gpa = gpa,
        .a = a,
        .io = io,
        .repo = repo,
        .db = db,
        .options = options,
        .encoding = try message.logOutputEncoding(config),
        .diff_options = diff_options,
        .renames = renames,
        .order = options.order orelse try diff.Order.configured(a, io, repo.topDirectory(), config),
        .relative_to = relative_to,
        .quote_path = quote_path,
        .attrs = if (own_attrs) |*x| x else null,
        .prefix = prefix,
        .total = if (options.keep_subject) -1 else if (numbered) @intCast(total + start_number - 1) else 0,
    };

    if (options.in_reply_to) |r| try ctx.ref_ids.append(a, try cleanMessageId(a, r));

    // base tree information
    var bases: ?Bases = null;
    if (options.base) |base| bases = try prepareBases(&ctx, base, list);

    var mails: std.ArrayList(Mail) = .empty;
    if (options.cover_letter) |cover| {
        if (options.thread) |t| ctx.message_id = try genMessageId(a, "cover", t);
        var text: std.ArrayList(u8) = .empty;
        ctx.nr = 0;
        try coverLetter(&ctx, &text, cover, origin, list);
        if (bases) |*b| try printBases(&ctx, &text, b);
        try printSignature(a, &text, options.signature);
        try mails.append(a, .{ .name = try fileName(&ctx, null, "cover-letter"), .text = text.items, .commit = null });
        total += 1;
        start_number -= 1;
    }

    var idx = list.len;
    while (idx > 0) {
        idx -= 1;
        const commit = list[idx];
        ctx.nr = total + start_number - 1 - idx;
        if (options.thread) |t| {
            if (ctx.message_id) |prev| {
                if (t.style == .shallow and ctx.ref_ids.items.len > 0 and (options.cover_letter == null or ctx.nr > 1)) {
                    // replies go to the first mail only
                } else try ctx.ref_ids.append(a, prev);
            }
            var hex: [hash.max_hex_len]u8 = undefined;
            ctx.message_id = try genMessageId(a, commit.hex(&hex), t);
        }
        var text: std.ArrayList(u8) = .empty;
        try formatOne(&ctx, &text, commit);
        if (bases) |*b| try printBases(&ctx, &text, b);
        if (options.attach) |att| {
            try text.print(a, "\n--{s}{s}--\n\n\n", .{ mime_boundary_leader, att.boundary });
        } else try printSignature(a, &text, options.signature);
        try mails.append(a, .{ .name = try fileName(&ctx, commit, null), .text = text.items, .commit = commit });
    }
    return .{ .gpa = gpa, .arena = arena_instance.state, .mails = mails.items };
}

/// What a series formats: its commits, newest first, those of them a
/// merge does not leave out, and every commit the walk met, for finding
/// where the range grew from.
const Selected = struct { list: []const Oid, in_list: []const Oid, walked: []const Oid };

/// The commits of `range`, newest first, as `git format-patch` takes them:
/// merges left out, at most `max_count`, and under `ignore_if_in_upstream`
/// those whose patch id upstream has. `null` when there are none.
fn selectCommits(gpa: Allocator, a: Allocator, io: Io, db: *odb_mod.Odb, range: Range, options: Options, binary: diff.BinaryRule) Error!?Selected {
    var list: std.ArrayList(Oid) = .empty;
    var walk = rev_walk.Walk.init(gpa, db);
    defer walk.deinit();
    try walk.push(range.tip);
    if (range.upstream) |u| try walk.hide(u);
    var upstream_ids: std.ArrayList(Oid) = .empty;
    if (options.ignore_if_in_upstream and range.upstream != null) {
        if (range.upstream.?.eql(range.tip)) return null;
        try upstreamPatchIds(gpa, a, io, db, range, binary, &upstream_ids);
    }
    var in_list: std.ArrayList(Oid) = .empty;
    var walked: std.ArrayList(Oid) = .empty;
    while (try walk.next(io)) |c| {
        if (range.max_count) |n| if (in_list.items.len >= n) break;
        try walked.append(a, c.oid);
        if (c.parents.len > 1) continue;
        try in_list.append(a, c.oid);
        if (upstream_ids.items.len != 0) {
            if (try patch_id.ofCommit(gpa, io, db, c.oid, binary)) |id| {
                if (containsOid(upstream_ids.items, id)) continue;
            }
        }
        try list.append(a, c.oid);
    }
    if (list.items.len == 0) return null;
    return .{ .list = list.items, .in_list = in_list.items, .walked = walked.items };
}

/// The subject prefix, as git builds it: `PATCH` or the caller's, with the
/// RFC word before it (after it for `-word`) and the reroll count.
fn subjectPrefix(a: Allocator, options: Options) Allocator.Error![]const u8 {
    var prefix: std.ArrayList(u8) = .empty;
    try prefix.appendSlice(a, options.subject_prefix);
    if (options.rfc) |rfc| {
        if (rfc.len > 0) {
            if (rfc[0] == '-') {
                try prefix.print(a, " {s}", .{rfc[1..]});
            } else {
                const old = try a.dupe(u8, prefix.items);
                prefix.clearRetainingCapacity();
                try prefix.print(a, "{s} {s}", .{ rfc, old });
            }
        }
    }
    if (options.reroll_count) |v| try prefix.print(a, " v{s}", .{v});
    return prefix.items;
}

/// The patch ids of the upstream's own commits, which
/// `--ignore-if-in-upstream` leaves out of the series.
fn upstreamPatchIds(gpa: Allocator, a: Allocator, io: Io, db: *odb_mod.Odb, range: Range, binary: diff.BinaryRule, out: *std.ArrayList(Oid)) Error!void {
    var back = rev_walk.Walk.init(gpa, db);
    defer back.deinit();
    // Asked only of a range with an upstream.
    try back.push(range.upstream.?);
    try back.hide(range.tip);
    while (try back.next(io)) |c| {
        if (c.parents.len > 1) continue;
        if (try patch_id.ofCommit(gpa, io, db, c.oid, binary)) |id| try out.append(a, id);
    }
}

fn containsOid(oids: []const Oid, oid: Oid) bool {
    for (oids) |o| if (o.eql(oid)) return true;
    return false;
}

fn emptySeries(gpa: Allocator, arena: *std.heap.ArenaAllocator) Series {
    return .{ .gpa = gpa, .arena = arena.state, .mails = &.{} };
}

const mime_boundary_leader = "------------";

fn findOrigin(gpa: Allocator, io: Io, db: *odb_mod.Odb, commits: []const Oid, walked: []const Oid) Error!?Oid {
    var boundary: ?Oid = null;
    var count: usize = 0;
    for (commits) |c| {
        const parents = try commitParents(gpa, io, db, c);
        defer gpa.free(parents);
        for (parents) |p| {
            var inside = false;
            for (walked) |o| {
                if (o.eql(p)) inside = true;
            }
            if (inside) continue;
            if (boundary) |b| {
                if (b.eql(p)) continue;
            }
            count += 1;
            if (boundary == null) boundary = p;
        }
    }
    return if (count == 1) boundary else null;
}

fn commitParents(gpa: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid) Error![]Oid {
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    var c = try object.Commit.parse(gpa, db.objectFormat(), found.bytes);
    defer c.deinit();
    return gpa.dupe(Oid, c.parents);
}

fn genMessageId(a: Allocator, base: []const u8, t: Thread) Allocator.Error![]const u8 {
    return a.print("{s}.{d}.git.{s}", .{ base, t.now.toSeconds(), t.email });
}

fn cleanMessageId(a: Allocator, id: []const u8) Allocator.Error![]const u8 {
    var m: usize = 0;
    while (m < id.len and (ctype.isSpace(id[m]) or id[m] == '<')) m += 1;
    const start = m;
    var end: ?usize = null;
    while (m < id.len) : (m += 1) {
        if (!ctype.isSpace(id[m]) and id[m] != '>') end = m;
    }
    const e = end orelse return a.dupe(u8, id[start..start]);
    return a.dupe(u8, id[start .. e + 1]);
}

fn printSignature(a: Allocator, out: *std.ArrayList(u8), signature: ?[]const u8) Allocator.Error!void {
    const sig = signature orelse return;
    if (sig.len == 0) return;
    try out.print(a, "-- \n{s}", .{sig});
    if (sig[sig.len - 1] != '\n') try out.append(a, '\n');
    try out.append(a, '\n');
}

//=========================================================================
// Base tree information
//=========================================================================

const Bases = struct {
    base: Oid,
    patch_ids: []const Oid,
    printed: bool = false,
};

fn prepareBases(ctx: *Ctx, base: Oid, list: []const Oid) Error!Bases {
    const gpa = ctx.gpa;
    // the base must reach every commit's merge base, and not be one of them
    for (list) |c| if (c.eql(base)) return error.BaseInRange;
    var common: Oid = list[0];
    for (list[1..]) |c| {
        common = (try rev_walk.mergeBase(gpa, ctx.io, ctx.db, common, c)) orelse return error.BaseNotAncestor;
    }
    if (!try rev_walk.isAncestor(gpa, ctx.io, ctx.db, .{ .ancestor = base, .descendant = common }, .{})) return error.BaseNotAncestor;
    var walk = rev_walk.Walk.init(gpa, ctx.db);
    defer walk.deinit();
    walk.sort = .topological;
    for (list) |c| try walk.push(c);
    try walk.hide(base);
    var ids: std.ArrayList(Oid) = .empty;
    while (try walk.next(ctx.io)) |c| {
        if (c.parents.len > 1) continue;
        var listed = false;
        for (list) |l| {
            if (l.eql(c.oid)) listed = true;
        }
        if (listed) continue;
        const id = (try patch_id.ofCommit(gpa, ctx.io, ctx.db, c.oid, ctx.binaryRule())) orelse continue;
        try ids.append(ctx.a, id);
    }
    return .{ .base = base, .patch_ids = ids.items };
}

fn printBases(ctx: *Ctx, out: *std.ArrayList(u8), b: *Bases) Allocator.Error!void {
    if (b.printed) return;
    b.printed = true;
    var hex: [hash.max_hex_len]u8 = undefined;
    try out.print(ctx.a, "\nbase-commit: {s}\n", .{b.base.hex(&hex)});
    var i = b.patch_ids.len;
    while (i > 0) {
        i -= 1;
        try out.print(ctx.a, "prerequisite-patch-id: {s}\n", .{b.patch_ids[i].hex(&hex)});
    }
}

//=========================================================================
// One mail
//=========================================================================

/// A commit, parsed in the call's arena, with the bytes its fields borrow
/// kept there too.
fn readCommit(ctx: *Ctx, oid: Oid) Error!object.Commit {
    return parseIn(ctx, oid, null);
}

/// `readCommit`, its message and people in the mails' encoding, as git's
/// `logmsg_reencode` gives them for a mail.
fn shownCommit(ctx: *Ctx, oid: Oid) Error!object.Commit {
    return parseIn(ctx, oid, ctx.encoding);
}

fn parseIn(ctx: *Ctx, oid: Oid, output: ?[]const u8) Error!object.Commit {
    const found = try ctx.db.read(ctx.io, oid);
    defer ctx.db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const converted = try pretty.reencodeCommit(ctx.a, try ctx.a.dupe(u8, found.bytes), output);
    return object.Commit.parse(ctx.a, ctx.db.objectFormat(), converted.bytes);
}

fn getOneLine(msg: []const u8) usize {
    var i: usize = 0;
    while (i < msg.len) {
        const c = msg[i];
        if (c == 0) break;
        i += 1;
        if (c == '\n') break;
    }
    return i;
}

/// The length without trailing whitespace; zero means blank.
fn trimmedLen(line: []const u8) usize {
    var len = line.len;
    while (len > 0 and ctype.isSpace(line[len - 1])) len -= 1;
    return len;
}

fn skipBlankLines(msg: []const u8) []const u8 {
    var rest = msg;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0) break;
        if (trimmedLen(rest[0..len]) != 0) break;
        rest = rest[len..];
    }
    return rest;
}

/// git's `format_subject`: the first paragraph's lines joined by
/// `separator`. Returns what follows it.
fn formatSubject(a: Allocator, out: ?*std.ArrayList(u8), msg_in: []const u8, separator: []const u8) Allocator.Error![]const u8 {
    var msg = msg_in;
    var first = true;
    while (true) {
        const len = getOneLine(msg);
        const line = msg[0..len];
        msg = msg[len..];
        if (len == 0) break;
        const t = trimmedLen(line);
        if (t == 0) break;
        if (out) |o| {
            if (!first) try o.appendSlice(a, separator);
            try o.appendSlice(a, line[0..t]);
        }
        first = false;
    }
    return msg;
}

fn emailSubjectLead(ctx: *Ctx, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (ctx.total > 0) {
        const width = std.fmt.count("{d}", .{ctx.total});
        try out.print(ctx.a, "Subject: [{s}{s}", .{ ctx.prefix, if (ctx.prefix.len > 0) " " else "" });
        const digits = std.fmt.count("{d}", .{ctx.nr});
        if (digits < width) try out.appendNTimes(ctx.a, '0', width - digits);
        try out.print(ctx.a, "{d}/{d}] ", .{ ctx.nr, ctx.total });
    } else if (ctx.total == 0 and ctx.prefix.len > 0) {
        try out.print(ctx.a, "Subject: [{s}] ", .{ctx.prefix});
    } else try out.appendSlice(ctx.a, "Subject: ");
}

fn lastLineLength(buf: []const u8) usize {
    const nl = std.mem.findScalarLast(u8, buf, '\n') orelse return buf.len;
    return buf.len - (nl + 1);
}

/// git's `pp_user_info` for the mail formats: `From:` and `Date:`.
fn userInfo(ctx: *Ctx, out: *std.ArrayList(u8), name: []const u8, email: []const u8, date: ?struct { secs: i64, offset: i32 }, encoding: []const u8) Allocator.Error!void {
    const a = ctx.a;
    var max_length: usize = 78;
    try out.appendSlice(a, "From: ");
    if (ctx.options.encode_email_headers and mailfmt.needsRfc2047(name)) {
        try mailfmt.appendRfc2047(a, out, name, encoding, .address);
        max_length = 76;
    } else if (mailfmt.needsRfc822Quoting(name)) {
        var q: std.ArrayList(u8) = .empty;
        try mailfmt.appendRfc822Quoted(a, &q, name);
        try mailfmt.appendWrapped(a, out, q.items, -6, 1, @intCast(max_length));
    } else {
        try mailfmt.appendWrapped(a, out, name, -6, 1, @intCast(max_length));
    }
    if (max_length < lastLineLength(out.items) + 2 + email.len + 1) try out.append(a, '\n');
    try out.print(a, " <{s}>\n", .{email});
    if (date) |d| {
        try out.appendSlice(a, "Date: ");
        var w: Io.Writer.Allocating = .fromArrayList(a, out);
        mailfmt.writeRfc2822(&w.writer, d.secs, d.offset) catch return error.OutOfMemory;
        out.* = w.toArrayList();
        try out.append(a, '\n');
    }
}

/// git's `pp_email_subject`: `Subject:`, the MIME headers when wanted,
/// the extra headers, a blank line and any in-body headers.
fn emailSubject(ctx: *Ctx, out: *std.ArrayList(u8), msg: []const u8, need_8bit_cte_in: bool, after_subject: []const u8, in_body: []const []const u8, encoding: []const u8) Allocator.Error![]const u8 {
    const a = ctx.a;
    var title: std.ArrayList(u8) = .empty;
    const rest = try formatSubject(a, &title, msg, if (ctx.options.keep_subject) "\n" else " ");
    try emailSubjectLead(ctx, out);
    if (ctx.options.encode_email_headers and mailfmt.needsRfc2047(title.items)) {
        try mailfmt.appendRfc2047(a, out, title.items, encoding, .subject);
    } else {
        try mailfmt.appendWrapped(a, out, title.items, -@as(i32, @intCast(lastLineLength(out.items))), 1, 78);
    }
    try out.append(a, '\n');
    var need_8bit_cte = need_8bit_cte_in;
    if (!need_8bit_cte) {
        for (in_body) |h| {
            if (mailfmt.hasNonAscii(h)) need_8bit_cte = true;
        }
    }
    if (need_8bit_cte and ctx.options.attach == null) {
        try out.print(a, "MIME-Version: 1.0\nContent-Type: text/plain; charset={s}\nContent-Transfer-Encoding: 8bit\n", .{encoding});
    }
    try out.appendSlice(a, after_subject);
    try out.append(a, '\n');
    if (in_body.len > 0) {
        for (in_body) |h| try out.appendSlice(a, h);
        try out.append(a, '\n');
    }
    return rest;
}

fn isMboxrdFrom(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and line[i] == '>') i += 1;
    return line.len > 4 and std.mem.startsWith(u8, line[i..], "From ");
}

/// git's `pp_remainder` with no indent: the body's lines without their
/// trailing whitespace, blank lines at its start left out.
fn remainder(ctx: *Ctx, out: *std.ArrayList(u8), msg_in: []const u8) Allocator.Error!void {
    var msg = msg_in;
    var first = true;
    while (true) {
        const len = getOneLine(msg);
        const line = msg[0..len];
        msg = msg[len..];
        if (len == 0) break;
        const t = trimmedLen(line);
        if (t == 0 and first) continue;
        first = false;
        if (ctx.options.mboxrd and isMboxrdFrom(line[0..t])) try out.append(ctx.a, '>');
        try out.appendSlice(ctx.a, line[0..t]);
        try out.append(ctx.a, '\n');
    }
}

fn rtrim(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and ctype.isSpace(out.items[out.items.len - 1])) _ = out.pop();
}

fn extraHeaders(ctx: *Ctx) Allocator.Error![]const u8 {
    const a = ctx.a;
    var buf: std.ArrayList(u8) = .empty;
    for (ctx.options.headers) |h| try buf.print(a, "{s}\n", .{h});
    for ([_][]const []const u8{ ctx.options.to, ctx.options.cc }, [_][]const u8{ "To: ", "Cc: " }) |list, lead| {
        if (list.len > 0) try buf.appendSlice(a, lead);
        for (list, 0..) |item, i| {
            if (i > 0) try buf.appendSlice(a, "    ");
            try buf.appendSlice(a, item);
            if (i + 1 < list.len) try buf.append(a, ',');
            try buf.append(a, '\n');
        }
    }
    return buf.items;
}

/// git's `log_write_email_headers`: the `From ` line, the message ids,
/// and what goes after the subject.
fn emailHeaders(ctx: *Ctx, out: *std.ArrayList(u8), commit: Oid, subject_for_attach: ?[]const u8) Allocator.Error!struct { after_subject: []const u8, stat_sep: ?[]const u8 } {
    const a = ctx.a;
    var headers: std.ArrayList(u8) = .empty;
    try headers.appendSlice(a, try extraHeaders(ctx));
    var hex: [hash.max_hex_len]u8 = undefined;
    const name = if (ctx.options.zero_commit) Oid.zero(ctx.db.objectFormat()).hex(&hex) else commit.hex(&hex);
    try out.print(a, "From {s} Mon Sep 17 00:00:00 2001\n", .{name});
    if (ctx.message_id) |id| try out.print(a, "Message-ID: <{s}>\n", .{id});
    if (ctx.ref_ids.items.len > 0) {
        const n = ctx.ref_ids.items.len;
        try out.print(a, "In-Reply-To: <{s}>\n", .{ctx.ref_ids.items[n - 1]});
        for (ctx.ref_ids.items, 0..) |id, i| try out.print(a, "{s}<{s}>\n", .{ if (i > 0) "\t" else "References: ", id });
    }
    var stat_sep: ?[]const u8 = null;
    if (ctx.options.attach) |att| {
        if (subject_for_attach) |subject| {
            try headers.print(a, "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"{s}{s}\"\n\nThis is a multi-part message in MIME format.\n--{s}{s}\nContent-Type: text/plain; charset=UTF-8; format=fixed\nContent-Transfer-Encoding: 8bit\n\n", .{ mime_boundary_leader, att.boundary, mime_boundary_leader, att.boundary });
            const filename = if (ctx.options.numbered_files) try a.print("{d}", .{ctx.nr}) else try fileNameFor(ctx, subject);
            stat_sep = try a.print("\n--{s}{s}\nContent-Type: text/x-patch; name=\"{s}\"\nContent-Transfer-Encoding: 8bit\nContent-Disposition: {s}; filename=\"{s}\"\n\n", .{ mime_boundary_leader, att.boundary, filename, if (att.@"inline") "inline" else "attachment", filename });
        }
    }
    return .{ .after_subject = headers.items, .stat_sep = stat_sep };
}

fn identEql(a: Ident, b: Ident) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.email, b.email);
}

/// One commit's mail, up to its signature.
fn formatOne(ctx: *Ctx, out: *std.ArrayList(u8), oid: Oid) Error!void {
    const a = ctx.a;
    const commit = try shownCommit(ctx, oid);
    const msg = commit.message;
    const author = commit.author;

    // the subject as %f, for an attachment's file name
    const sanitized = try sanitizedSubject(a, rawSubject(skipBlankLines(msg)));
    const headers = try emailHeaders(ctx, out, oid, sanitized);

    // is the body 8-bit? With a sign-off, its name decides first, as in git
    var need_8bit_cte = false;
    if (ctx.options.signoff) |who| need_8bit_cte = mailfmt.hasNonAscii(who.name) or mailfmt.hasNonAscii(who.email);
    if (ctx.options.attach == null and !need_8bit_cte) {
        for (msg) |c| {
            if (c == 0) break;
            if (mailfmt.nonAscii(c)) {
                need_8bit_cte = true;
                break;
            }
        }
    }

    var in_body: std.ArrayList([]const u8) = .empty;
    var from_name = author.name;
    var from_email = author.email;
    if (ctx.options.from) |sender| {
        if (ctx.options.force_in_body_from or !identEql(sender, .{ .name = author.name, .email = author.email })) {
            try in_body.append(a, try a.print("From: {s} <{s}>\n", .{ author.name, author.email }));
            from_name = sender.name;
            from_email = sender.email;
        }
    }
    try userInfo(ctx, out, from_name, from_email, .{ .secs = author.when_secs, .offset = author.offset_minutes }, ctx.encoding);

    const body_start = skipBlankLines(msg);
    const rest = try emailSubject(ctx, out, body_start, need_8bit_cte, headers.after_subject, in_body.items, ctx.encoding);
    const beginning_of_body = out.items.len;
    try remainder(ctx, out, rest);
    rtrim(out);
    try out.append(a, '\n');
    if (out.items.len <= beginning_of_body) try out.append(a, '\n');
    if (ctx.options.signoff) |who| {
        const line = try a.print("Signed-off-by: {s} <{s}>\n", .{ who.name, who.email });
        const trailers = try message.trailerSettings(a, ctx.repo.configuration());
        const footer: message.Footer = if (std.mem.eql(u8, out.items, line)) .ends_with_line else try message.conformingFooter(a, out.items, line, trailers);
        if (footer != .has_line) {
            const sig: object.Signature = .{ .name = who.name, .email = who.email, .when_secs = 0, .offset_minutes = 0 };
            try message.appendSignoff(a, out, sig, trailers);
        }
    }

    // the diff
    const parent_tree: ?Oid = if (commit.parents.len == 0) null else blk: {
        var parent = try readCommit(ctx, commit.parents[0]);
        defer parent.deinit();
        break :blk parent.tree;
    };
    var changes = try diff.tree(ctx.gpa, ctx.io, ctx.db, .{ .old = parent_tree, .new = commit.tree }, .{ .renames = ctx.renames, .order = ctx.order, .prefix = ctx.relative_to });
    defer changes.deinit();
    if (changes.items.len == 0) return;
    if (ctx.options.stat) try out.appendSlice(a, "---");
    try out.append(a, '\n');
    try writeDiff(ctx, out, changes.items, headers.stat_sep);
}

fn sanitizedSubject(a: Allocator, subject: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space: u2 = 2;
    var i: usize = 0;
    while (i < subject.len) : (i += 1) {
        const c = subject[i];
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_') {
            if (space == 1) try out.append(a, '-');
            space = 0;
            try out.append(a, c);
            if (c == '.') {
                while (i + 1 < subject.len and subject[i + 1] == '.') i += 1;
            }
        } else space |= 1;
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == '.' or out.items[out.items.len - 1] == '-')) _ = out.pop();
    return out.items;
}

fn fileNameFor(ctx: *Ctx, subject: []const u8) Allocator.Error![]const u8 {
    const a = ctx.a;
    var name: std.ArrayList(u8) = .empty;
    const max_len_signed: i64 = @as(i64, @intCast(ctx.options.filename_max_length)) - @as(i64, @intCast(ctx.options.suffix.len + 1));
    var max_len: usize = if (max_len_signed < 0) 0 else @intCast(max_len_signed);
    const min_len = "0000-".len + ctx.options.suffix.len;
    if (ctx.options.filename_max_length <= min_len) max_len = min_len - ctx.options.suffix.len - 1;
    if (ctx.options.reroll_count) |v| {
        const tmp = try a.print("v{s}", .{v});
        try name.appendSlice(a, try sanitizedSubject(a, tmp));
        try name.append(a, '-');
    }
    try name.print(a, "{d:0>4}-{s}", .{ ctx.nr, subject });
    if (max_len < name.items.len) name.shrinkRetainingCapacity(max_len);
    try name.appendSlice(a, ctx.options.suffix);
    return name.items;
}

fn fileName(ctx: *Ctx, commit: ?Oid, subject: ?[]const u8) Error![]const u8 {
    if (ctx.options.numbered_files) return ctx.a.print("{d}", .{ctx.nr});
    if (commit) |oid| {
        const c = try shownCommit(ctx, oid);
        const msg = c.message;
        // %f is the raw first paragraph sanitized, newlines and all
        return fileNameFor(ctx, try sanitizedSubject(ctx.a, rawSubject(skipBlankLines(msg))));
    }
    return fileNameFor(ctx, subject.?);
}

fn rawSubject(msg: []const u8) []const u8 {
    var end: usize = 0;
    var rest = msg;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0 or trimmedLen(rest[0..len]) == 0) break;
        end += len;
        rest = rest[len..];
    }
    return msg[0..end];
}

//=========================================================================
// The diff: stat, summary and patch
//=========================================================================

const Side = struct {
    path: []const u8,
    mode: object.Mode,
    oid: Oid,
    bytes: []const u8,
    binary: bool,
};

fn modeNum(m: object.Mode) u32 {
    return @backingInt(m);
}

fn loadSide(ctx: *Ctx, e: diff.Entry) Error!Side {
    var bytes: []const u8 = undefined;
    if (e.mode == .gitlink) {
        var hex: [hash.max_hex_len]u8 = undefined;
        bytes = try ctx.a.print("Subproject commit {s}\n", .{e.oid.hex(&hex)});
    } else {
        const found = try ctx.db.read(ctx.io, e.oid);
        defer ctx.db.allocator().free(found.bytes);
        bytes = try ctx.a.dupe(u8, found.bytes);
    }
    return .{ .path = e.path, .mode = e.mode, .oid = e.oid, .bytes = bytes, .binary = try isBinaryPath(ctx, e.path, bytes) };
}

fn isBinaryPath(ctx: *Ctx, path: []const u8, bytes: []const u8) Error!bool {
    return ctx.binaryRule().isBinary(ctx.a, ctx.io, path, bytes);
}

const StatFile = struct {
    from_name: ?[]const u8,
    name: []const u8,
    added: usize,
    deleted: usize,
    binary: bool,
    print_name: []const u8 = "",
};

fn writeDiff(ctx: *Ctx, out: *std.ArrayList(u8), changes: []const diff.Change, stat_sep: ?[]const u8) Error!void {
    const a = ctx.a;
    var separator = false;
    if (ctx.options.stat) {
        var files: std.ArrayList(StatFile) = .empty;
        for (changes) |c| {
            const old = if (c.old) |e| try loadSide(ctx, e) else null;
            const new = if (c.new) |e| try loadSide(ctx, e) else null;
            var f: StatFile = .{
                .from_name = if (c.status == .renamed or c.status == .copied) shown(ctx, c.old.?.path) else null,
                .name = shown(ctx, c.path()),
                .added = 0,
                .deleted = 0,
                .binary = false,
            };
            const one: []const u8 = if (old) |o| o.bytes else "";
            const two: []const u8 = if (new) |n| n.bytes else "";
            const one_bin = if (old) |o| o.binary else false;
            const two_bin = if (new) |n| n.binary else false;
            if (one_bin or two_bin) {
                f.binary = true;
                const same = old != null and new != null and old.?.oid.eql(new.?.oid);
                if (!same) {
                    f.added = two.len;
                    f.deleted = one.len;
                }
            } else if (!(old != null and new != null and old.?.oid.eql(new.?.oid))) {
                const counts = try diff.blobNumStat(ctx.gpa, one, two, ctx.diff_options);
                f.added = counts.plus;
                f.deleted = counts.minus;
            }
            try files.append(a, f);
        }
        try showStats(ctx, out, files.items);
        separator = true;
    }
    if (ctx.options.stat) {
        var any = false;
        for (changes) |c| {
            switch (c.status) {
                .added, .deleted, .renamed, .copied => any = true,
                else => if (c.old.?.mode != c.new.?.mode) {
                    any = true;
                },
            }
        }
        if (any) {
            for (changes) |c| try summary(ctx, out, c);
        }
    }
    if (separator) {
        try out.append(a, '\n');
        if (stat_sep) |s| try out.appendSlice(a, s);
    }
    var w: Io.Writer.Allocating = .fromArrayList(a, out);
    defer out.* = w.toArrayList();
    for (changes) |c| {
        diff.unified(ctx.gpa, ctx.io, .{ .db = ctx.db, .change = c, .binary = ctx.binaryRule() }, &w.writer, ctx.diff_options) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
    }
}

fn quoted(ctx: *Ctx, path: []const u8) Allocator.Error![]const u8 {
    return c_quote.alloc(ctx.a, path, ctx.quote_path);
}

/// A path as a patch's headers and diffstat name it: under `--relative`,
/// from the directory, as git's `strip_prefix` names it. The summary lines
/// keep the whole path, as git's do.
fn shown(ctx: *const Ctx, path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, ctx.relative_to)) path[ctx.relative_to.len..] else path;
}

fn summary(ctx: *Ctx, out: *std.ArrayList(u8), c: diff.Change) Allocator.Error!void {
    const a = ctx.a;
    switch (c.status) {
        .deleted => try out.print(a, " delete mode {o:0>6} {s}\n", .{ modeNum(c.old.?.mode), try quoted(ctx, c.old.?.path) }),
        .added => try out.print(a, " create mode {o:0>6} {s}\n", .{ modeNum(c.new.?.mode), try quoted(ctx, c.new.?.path) }),
        .renamed, .copied => {
            try out.print(a, " {s} {s} ({d}%)\n", .{ if (c.status == .copied) "copy" else "rename", try pprintRename(ctx, c.old.?.path, c.new.?.path), c.similarity });
            if (c.old.?.mode != c.new.?.mode) try out.print(a, " mode change {o:0>6} => {o:0>6}\n", .{ modeNum(c.old.?.mode), modeNum(c.new.?.mode) });
        },
        else => if (c.old.?.mode != c.new.?.mode) {
            try out.print(a, " mode change {o:0>6} => {o:0>6} {s}\n", .{ modeNum(c.old.?.mode), modeNum(c.new.?.mode), try quoted(ctx, c.new.?.path) });
        },
    }
}

/// `pfx{old => new}sfx`, git's `pprint_rename`.
fn pprintRename(ctx: *Ctx, a_name: []const u8, b_name: []const u8) Allocator.Error![]const u8 {
    const a = ctx.a;
    if (c_quote.needsQuote(a_name, ctx.quote_path) or c_quote.needsQuote(b_name, ctx.quote_path)) {
        return std.mem.concat(a, u8, &.{ try quoted(ctx, a_name), " => ", try quoted(ctx, b_name) });
    }
    var pfx_length: usize = 0;
    var i: usize = 0;
    while (i < a_name.len and i < b_name.len and a_name[i] == b_name[i]) : (i += 1) {
        if (a_name[i] == '/') pfx_length = i + 1;
    }
    // the common suffix, which must start at a slash; with a prefix the
    // scan may run onto the prefix's own slash
    var sfx_length: usize = 0;
    const adjust: usize = if (pfx_length != 0) 1 else 0;
    var oi: isize = @intCast(a_name.len);
    var ni: isize = @intCast(b_name.len);
    const floor: isize = @as(isize, @intCast(pfx_length)) - @as(isize, @intCast(adjust));
    while (oi >= floor and ni >= floor) {
        const oc: u8 = if (oi < a_name.len) a_name[@intCast(oi)] else 0;
        const nc: u8 = if (ni < b_name.len) b_name[@intCast(ni)] else 0;
        if (oc != nc) break;
        if (oc == '/') sfx_length = a_name.len - @as(usize, @intCast(oi));
        oi -= 1;
        ni -= 1;
    }
    const a_mid: usize = if (a_name.len >= pfx_length + sfx_length) a_name.len - pfx_length - sfx_length else 0;
    const b_mid: usize = if (b_name.len >= pfx_length + sfx_length) b_name.len - pfx_length - sfx_length else 0;
    var out: std.ArrayList(u8) = .empty;
    if (pfx_length + sfx_length > 0) {
        try out.appendSlice(a, a_name[0..pfx_length]);
        try out.append(a, '{');
    }
    try out.appendSlice(a, a_name[pfx_length..][0..a_mid]);
    try out.appendSlice(a, " => ");
    try out.appendSlice(a, b_name[pfx_length..][0..b_mid]);
    if (pfx_length + sfx_length > 0) {
        try out.append(a, '}');
        try out.appendSlice(a, a_name[a_name.len - sfx_length ..]);
    }
    return out.items;
}

fn decimalWidth(n: usize) usize {
    return std.fmt.count("{d}", .{n});
}

fn scaleLinear(it: usize, width: usize, max_change: usize) usize {
    if (it == 0) return 0;
    return 1 + (it * (width - 1) / max_change);
}

/// git's `show_stats` at `format-patch`'s 72 columns.
fn showStats(ctx: *Ctx, out: *std.ArrayList(u8), files: []StatFile) Allocator.Error!void {
    const a = ctx.a;
    if (files.len == 0) return;
    var max_change: usize = 0;
    var max_len: usize = 0;
    var number_width: usize = 0;
    var bin_width: usize = 0;
    for (files) |*f| {
        f.print_name = if (f.from_name) |from| try pprintRename(ctx, from, f.name) else try quoted(ctx, f.name);
        const len = unicode_width.strWidth(f.print_name);
        if (max_len < len) max_len = len;
        if (f.binary) {
            const w = 14 + decimalWidth(f.added) + decimalWidth(f.deleted);
            if (bin_width < w) bin_width = w;
            number_width = 3;
            continue;
        }
        const change = f.added + f.deleted;
        if (max_change < change) max_change = change;
    }
    var width: usize = 72;
    number_width = @max(decimalWidth(max_change), number_width);
    if (width < 16 + 6 + number_width) width = 16 + 6 + number_width;
    var graph_width: usize = if (max_change + 4 > bin_width) max_change else bin_width - 4;
    var name_width: usize = max_len;
    if (name_width + number_width + 6 + graph_width > width) {
        const limit_signed: i64 = @as(i64, @intCast(width * 3 / 8)) - @as(i64, @intCast(number_width)) - 6;
        if (@as(i64, @intCast(graph_width)) > limit_signed) {
            graph_width = if (limit_signed < 6) 6 else @intCast(limit_signed);
        }
        if (name_width > width - number_width - 6 - graph_width) {
            name_width = width - number_width - 6 - graph_width;
        } else graph_width = width - number_width - 6 - name_width;
    }
    for (files) |f| {
        var prefix: []const u8 = "";
        var name = f.print_name;
        var len: isize = @intCast(name_width);
        var name_len = unicode_width.strWidth(name);
        if (name_width < name_len) {
            prefix = "...";
            len -= 3;
            if (len < 0) len = 0;
            while (name_len > len and name.len > 0) {
                const decoded = unicode_width.decode(name);
                const step: usize = if (decoded) |cp| cp.len else 1;
                const cp_width: usize = if (decoded) |cp| @intCast(@max(unicode_width.width(cp.char), 0)) else 1;
                name_len -= cp_width;
                name = name[step..];
            }
            if (std.mem.findScalar(u8, name, '/')) |slash| name = name[slash..];
        }
        const name_w: isize = @intCast(unicode_width.strWidth(name));
        const padding: usize = if (len - name_w < 0) 0 else @intCast(len - name_w);
        if (f.binary) {
            try out.print(a, " {s}{s}", .{ prefix, name });
            try out.appendNTimes(a, ' ', padding);
            try out.appendSlice(a, " | ");
            try out.appendNTimes(a, ' ', number_width -| 3);
            try out.appendSlice(a, "Bin");
            if (f.added == 0 and f.deleted == 0) {
                try out.append(a, '\n');
                continue;
            }
            try out.print(a, " {d} -> {d} bytes\n", .{ f.deleted, f.added });
            continue;
        }
        var add = f.added;
        var del = f.deleted;
        if (graph_width <= max_change) {
            var total = scaleLinear(add + del, graph_width, max_change);
            if (total < 2 and add != 0 and del != 0) total = 2;
            if (add < del) {
                add = scaleLinear(add, graph_width, max_change);
                del = total - add;
            } else {
                del = scaleLinear(del, graph_width, max_change);
                add = total - del;
            }
        }
        try out.print(a, " {s}{s}", .{ prefix, name });
        try out.appendNTimes(a, ' ', padding);
        try out.appendSlice(a, " | ");
        const count = f.added + f.deleted;
        const cw = decimalWidth(count);
        try out.appendNTimes(a, ' ', number_width -| cw);
        try out.print(a, "{d}{s}", .{ count, if (count != 0) " " else "" });
        try out.appendNTimes(a, '+', add);
        try out.appendNTimes(a, '-', del);
        try out.append(a, '\n');
    }
    var adds: usize = 0;
    var dels: usize = 0;
    for (files) |f| {
        if (!f.binary) {
            adds += f.added;
            dels += f.deleted;
        }
    }
    try statSummary(a, out, files.len, adds, dels);
}

fn statSummary(a: Allocator, out: *std.ArrayList(u8), files: usize, insertions: usize, deletions: usize) Allocator.Error!void {
    if (files == 0) {
        try out.appendSlice(a, " 0 files changed\n");
        return;
    }
    try out.print(a, " {d} file{s} changed", .{ files, if (files == 1) "" else "s" });
    if (insertions != 0 or deletions == 0) try out.print(a, ", {d} insertion{s}(+)", .{ insertions, if (insertions == 1) "" else "s" });
    if (deletions != 0 or insertions == 0) try out.print(a, ", {d} deletion{s}(-)", .{ deletions, if (deletions == 1) "" else "s" });
    try out.append(a, '\n');
}

//=========================================================================
// The cover letter
//=========================================================================

fn coverLetter(ctx: *Ctx, out_list: *std.ArrayList(u8), cover: Cover, origin: ?Oid, list: []const Oid) Error!void {
    const a = ctx.a;
    const out = out_list;
    ctx.nr = 0;
    const headers = try emailHeaders(ctx, out, list[0], null);
    var need_8bit_cte = false;
    for (list) |oid| {
        const found = try ctx.db.read(ctx.io, oid);
        defer ctx.db.allocator().free(found.bytes);
        for (found.bytes) |c| {
            if (c == 0) break;
            if (mailfmt.nonAscii(c)) need_8bit_cte = true;
        }
    }
    // `--from` names a sender with no date, which git prints as the epoch
    if (ctx.options.from) |from| {
        try userInfo(ctx, out, from.name, from.email, .{ .secs = 0, .offset = 0 }, "UTF-8");
    } else try userInfo(ctx, out, cover.sender.name, cover.sender.email, .{ .secs = cover.sender.when_secs, .offset = cover.sender.offset_minutes }, "UTF-8");

    var subject: []const u8 = "*** SUBJECT HERE ***";
    var blurb: []const u8 = "*** BLURB HERE ***";
    if (cover.description) |desc| if (desc.len > 0 and cover.from_description != .none) {
        var subject_sb: std.ArrayList(u8) = .empty;
        const mode = cover.from_description;
        if (mode == .subject or mode == .auto) blurb = try formatSubject(a, &subject_sb, desc, " ");
        if (mode == .message or (mode == .auto and subject_sb.items.len > 100)) {
            blurb = desc;
        } else subject = subject_sb.items;
    };
    _ = try emailSubject(ctx, out, subject, need_8bit_cte, headers.after_subject, &.{}, "UTF-8");
    try remainder(ctx, out, blurb);
    try out.append(a, '\n');

    switch (cover.format) {
        .shortlog => try coverShortlog(ctx, out, list),
        .modern => {
            const n = list.len;
            // git's `%w(72)[%(count)/%(total)] %s` with no output encoding:
            // formatted in UTF-8, written in each commit's own encoding
            for (1..n + 1) |i| {
                const found = try ctx.db.read(ctx.io, list[n - i]);
                defer ctx.db.allocator().free(found.bytes);
                const utf8 = try pretty.reencodeCommit(a, try a.dupe(u8, found.bytes), "UTF-8");
                const c = try object.Commit.parse(a, ctx.db.objectFormat(), utf8.bytes);
                var line: std.ArrayList(u8) = .empty;
                try line.print(a, "[{d}/{d}] ", .{ i, n });
                _ = try formatSubject(a, &line, skipBlankLines(c.message), " ");
                var wrapped: std.ArrayList(u8) = .empty;
                try mailfmt.appendWrapped(a, &wrapped, line.items, 0, 0, 72);
                try out.appendSlice(a, try pretty.toOutput(a, wrapped.items, pretty.outputEncoding(null, utf8.encoding)));
                try out.append(a, '\n');
            }
            try out.append(a, '\n');
        },
    }
    if (origin) |o| {
        const origin_commit = try readCommit(ctx, o);
        const head_commit = try readCommit(ctx, list[0]);
        var changes = try diff.tree(ctx.gpa, ctx.io, ctx.db, .{ .old = origin_commit.tree, .new = head_commit.tree }, .{ .renames = ctx.renames, .order = ctx.order, .prefix = ctx.relative_to });
        defer changes.deinit();
        const saved = ctx.options.stat;
        ctx.options.stat = true;
        try writeStatOnly(ctx, out, changes.items);
        ctx.options.stat = saved;
        try out.append(a, '\n');
    }
}

fn writeStatOnly(ctx: *Ctx, out: *std.ArrayList(u8), changes: []const diff.Change) Error!void {
    const a = ctx.a;
    var files: std.ArrayList(StatFile) = .empty;
    for (changes) |c| {
        const old = if (c.old) |e| try loadSide(ctx, e) else null;
        const new = if (c.new) |e| try loadSide(ctx, e) else null;
        var f: StatFile = .{ .from_name = if (c.status == .renamed or c.status == .copied) shown(ctx, c.old.?.path) else null, .name = shown(ctx, c.path()), .added = 0, .deleted = 0, .binary = false };
        const one: []const u8 = if (old) |o| o.bytes else "";
        const two: []const u8 = if (new) |n| n.bytes else "";
        if ((old != null and old.?.binary) or (new != null and new.?.binary)) {
            f.binary = true;
            if (!(old != null and new != null and old.?.oid.eql(new.?.oid))) {
                f.added = two.len;
                f.deleted = one.len;
            }
        } else {
            const counts = try diff.blobNumStat(ctx.gpa, one, two, ctx.diff_options);
            f.added = counts.plus;
            f.deleted = counts.minus;
        }
        try files.append(a, f);
    }
    try showStats(ctx, out, files.items);
    var any = false;
    for (changes) |c| switch (c.status) {
        .added, .deleted, .renamed, .copied => any = true,
        else => if (c.old.?.mode != c.new.?.mode) {
            any = true;
        },
    };
    if (any) for (changes) |c| try summary(ctx, out, c);
}

/// git's `generate_shortlog_cover_letter`: the commits by author, the
/// mailmap applied, subjects folded at 72 columns, in the log's encoding.
fn coverShortlog(ctx: *Ctx, out: *std.ArrayList(u8), list: []const Oid) Error!void {
    const a = ctx.a;
    var mailmap = try mailmap_mod.Mailmap.load(ctx.gpa, ctx.io, ctx.repo);
    defer mailmap.deinit();
    const options = try shortlog.configured(a, ctx.repo.configuration(), .{ .wrap = .{ .width = 72, .indent1 = 2, .indent2 = 4 }, .mailmap = &mailmap });
    var log = try shortlog.Shortlog.init(ctx.gpa, options);
    defer log.deinit();
    for (list) |oid| try log.add(ctx.io, ctx.db, oid);
    var w: Io.Writer.Allocating = .fromArrayList(a, out);
    log.write(&w.writer) catch return error.OutOfMemory;
    out.* = w.toArrayList();
}
