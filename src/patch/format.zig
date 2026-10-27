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
const aegis = @import("aegis");
const ctype = @import("../text.zig").ctype;
const gitdate = @import("../text.zig").date;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const diff = @import("../diff/diff.zig");
const diff_stat = @import("../diff/stat.zig");
const driver = @import("../diff/driver.zig");
const patch_id = @import("../diff/patch_id.zig");
const rev_walk = @import("../walk/walk.zig");
const rev_parse = @import("../repo/rev_parse.zig");
const abbrev = @import("../odb/abbrev.zig");
const mailfmt = @import("../mail/format.zig");
const message = @import("../object/message.zig");
const notes_mod = @import("../commit/notes.zig");
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
    /// A `format.*` value git dies on: `format.headers`, `to`, `cc` or a
    /// setting holding text with no value, a boolean setting that is no
    /// boolean, a `filenameMaxLength` that is no number, a `from` that is
    /// no identity, an unknown `coverFromDescription`, or a
    /// `commitListFormat` that is no format when a cover letter is
    /// written.
    InvalidFormatSetting,
    /// A sign-off, a cover letter, threading or `format.from=true` asked
    /// for the committer with no `Options.who`.
    NoIdentity,
    /// `--base=auto` or `format.useAutoBase=true` found no base: the
    /// current branch has no upstream, or the series and it have no one
    /// merge base, as git dies.
    NoAutoBase,
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
} || notes_mod.FormatNoteError || shortlog.Error || rev_walk.Error || diff.Error || diff.UnifiedError || diff.ConfigError || diff.Order.ConfiguredError || patch_id.Error || rev_parse.Error || odb_mod.Error || repo_mod.Error || attributes.Error || Allocator.Error ||
    aegis.own.ReadFileError;

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
    /// `^<commit>`: more commits left out, with everything they reach.
    exclude: []const Oid = &.{},
};

/// What the cover letter lists the commits as: `--commit-list-format`
/// and `format.commitListFormat`.
pub const CoverFormat = union(enum) {
    /// `Author (n):` and each subject under it, wrapped: git's default.
    shortlog,
    /// `[n/m] subject` for each, wrapped at 72.
    modern,
    /// A line per commit in a pretty format, `%(count)` and `%(total)`
    /// numbering them: `log:<format>`, or any value holding a `%`.
    log: []const u8,

    /// The value as git reads it, or null for one git refuses ("not a
    /// valid format string").
    pub fn parse(value: []const u8) ?CoverFormat {
        if (std.mem.startsWith(u8, value, "log:")) return .{ .log = value["log:".len..] };
        if (std.mem.eql(u8, value, "shortlog")) return .shortlog;
        if (std.mem.eql(u8, value, "modern")) return .modern;
        if (std.mem.findScalar(u8, value, '%') != null) return .{ .log = value };
        return null;
    }
};

/// Whether a cover letter is written; `Options.cover` says how.
pub const CoverLetter = enum {
    /// What `format.coverLetter` says: `true`, `false` or `auto`; none
    /// when it says nothing.
    configured,
    /// `--no-cover-letter`.
    off,
    /// `--cover-letter`.
    on,
    /// Only when there is more than one patch.
    auto,
};

/// How a cover letter is written.
pub const Cover = struct {
    /// Who sends it and when; `null` is `Options.who`: git's committer
    /// identity and the clock.
    sender: ?object.Signature = null,
    /// `--commit-list-format`; `null` takes `format.commitListFormat`,
    /// `shortlog` when it says nothing.
    format: ?CoverFormat = null,
    /// The branch description (`branch.<name>.description`) the subject
    /// and blurb come from; `null` writes git's `*** SUBJECT HERE ***` and
    /// `*** BLURB HERE ***`.
    description: ?[]const u8 = null,
    /// `--cover-from-description`: how the description is used; `null`
    /// takes `format.coverFromDescription`, `message` when it says nothing.
    from_description: ?FromDescription = null,

    pub const FromDescription = enum {
        /// The whole description is the blurb: git's default.
        message,
        /// Its first paragraph is the subject, the rest the blurb.
        subject,
        /// `subject` unless the first paragraph is over 100 bytes.
        auto,
        /// Not used.
        none,

        /// The value as git's `parse_cover_from_description` reads it,
        /// or null where it dies.
        pub fn parse(value: ?[]const u8) ?FromDescription {
            const v = value orelse return .message;
            if (std.mem.eql(u8, v, "default") or std.mem.eql(u8, v, "message")) return .message;
            if (std.mem.eql(u8, v, "subject")) return .subject;
            if (std.mem.eql(u8, v, "auto")) return .auto;
            if (std.mem.eql(u8, v, "none")) return .none;
            return null;
        }
    };
};

/// How mails are threaded; the message ids carry `Options.who`'s time and
/// address.
pub const Thread = enum {
    /// What `format.thread` says: `shallow`, `deep` or a boolean (`true`
    /// is shallow); none when it says nothing.
    configured,
    /// `--no-thread`.
    off,
    /// `--thread`: every mail a reply to the first.
    shallow,
    /// `--thread=deep`: each a reply to the one before.
    deep,
};

/// An option a setting gives when the caller leaves it: `configured` takes
/// the setting, `off` is the command line's `--no-<option>` and `on` its
/// `--<option>`.
pub fn Choice(comptime T: type) type {
    return union(enum) { configured, off, on: T };
}

/// `--base`: the base tree information in the first mail.
pub const Base = union(enum) {
    /// What `format.useAutoBase` says: `true` is `auto`, `whenAble` is
    /// `auto` where an upstream is there to find it, `false` or nothing
    /// none.
    configured,
    /// `--no-base`.
    off,
    /// `--base=auto`: the merge base of the series and the current
    /// branch's upstream.
    auto,
    /// `--base=<commit>`.
    commit: Oid,
};

/// `--to`, `--cc` and `--add-header`: what the setting lists
/// (`format.to`, `format.cc`, `format.headers`) unless `settings` is
/// false, as `--no-to` clears it, then `given`. A header that starts `To: `
/// or `Cc: ` in any case is an address, as git's `add_header` takes it,
/// and `--no-add-header` clears all three.
pub const Listed = struct {
    settings: bool = true,
    given: []const []const u8 = &.{},
};

/// One of `--notes`, `--notes=<ref>` and `--no-notes`, as given.
pub const NotesArg = union(enum) {
    /// `--notes`: the standard notes, the default ref and
    /// `notes.displayRef`'s.
    standard,
    /// `--notes=<ref>`: that ref's too, a glob for every ref it matches.
    ref: []const u8,
    /// `--no-notes`: none of what came before.
    off,
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
    /// `-n` or `-N`; `null` takes `format.numbered`, which numbers when
    /// there is more than one mail unless it says `false`. With
    /// `keep_subject` a setting's numbering is dropped, where `-n` is
    /// refused.
    numbered: ?bool = null,
    /// `--start-number`.
    start_number: usize = 1,
    /// `--subject-prefix`; `null` takes `format.subjectPrefix`, `PATCH`
    /// when it says nothing. Only a given one is refused with
    /// `keep_subject`.
    subject_prefix: ?[]const u8 = null,
    /// `--rfc[=<rfc>]`: put before the prefix, or after it when it starts
    /// with `-`.
    rfc: ?[]const u8 = null,
    /// `-v <n>`.
    reroll_count: ?[]const u8 = null,
    /// `-k`: the subject as it is, with no prefix.
    keep_subject: bool = false,
    /// `-s`: a `Signed-off-by:` trailer for `who`; `null` takes
    /// `format.signOff`.
    signoff: ?bool = null,
    /// `--cover-letter`, and how one is written.
    cover_letter: CoverLetter = .configured,
    cover: Cover = .{},
    /// `--base`.
    base: Base = .configured,
    /// The signature after `-- `: `--signature` or `--signature-file`'s
    /// text, `--no-signature`, or `format.signature`, else
    /// `format.signatureFile`'s text. git's default when none says is its
    /// own version, which is not this package's to claim: none.
    signature: Choice([]const u8) = .configured,
    /// `false` is `-p`: the patch with no diffstat.
    stat: bool = true,
    /// `false` is `--no-binary`: `Binary files ... differ`.
    binary: bool = true,
    /// `--zero-commit`.
    zero_commit: bool = false,
    /// `--from=<ident>`: the sender; a different author moves into the
    /// body as an in-body `From:`. `configured` takes `format.from`: an
    /// identity, or `true` for `who`'s.
    from: Choice(Ident) = .configured,
    /// `--force-in-body-from`; `null` takes `format.forceInBodyFrom`.
    force_in_body_from: ?bool = null,
    /// `--to`, `--cc`, `--add-header`.
    to: Listed = .{},
    cc: Listed = .{},
    headers: Listed = .{},
    /// `--in-reply-to`.
    in_reply_to: ?[]const u8 = null,
    /// `--thread`.
    thread: Thread = .configured,
    /// `--attach`, `--inline`, `--no-attach`; `configured` takes
    /// `format.attach`: its value is the boundary, an empty one none, and
    /// one with no value `version`.
    attach: Choice(Attach) = .configured,
    /// `--[no-]encode-email-headers`; `null` takes
    /// `format.encodeEmailHeaders`, on when it says nothing.
    encode_email_headers: ?bool = null,
    /// `--pretty=mboxrd` with `--stdout`: `From ` lines in the body get a
    /// `>`. `null` takes `format.mboxrd`.
    mboxrd: ?bool = null,
    /// `--notes`, `--notes=<ref>` and `--no-notes` in the order given,
    /// each applied over what `format.notes` set up, as git applies them.
    /// The notes go after the message, below a `---`, as git's
    /// `next_commentary_block` places them.
    notes: []const NotesArg = &.{},
    /// `--ignore-if-in-upstream`.
    ignore_if_in_upstream: bool = false,
    renames: Renames = .configured,
    /// Context, algorithm, whitespace and prefixes for the patches. `null`
    /// takes `diff.algorithm`, `diff.context` and the prefixes git's
    /// format-patch reads (`diff.Prefixes.configured` with `.patches`).
    diff: ?diff.Options = null,
    /// `--topo-order`: the commits in the order of `git rev-list
    /// --topo-order`, reversed, rather than by date.
    topo_order: bool = false,
    /// `--suffix`; `null` takes `format.suffix`, `.patch` when it says
    /// nothing.
    suffix: ?[]const u8 = null,
    /// `--filename-max-length`; `null` takes `format.filenameMaxLength`,
    /// 64 when it says nothing.
    filename_max_length: ?usize = null,
    /// `-o`: where the mails' files go (`Series.directory`); `null` takes
    /// `format.outputDirectory`, the current directory when it says
    /// nothing.
    output_directory: ?[]const u8 = null,
    /// `--numbered-files`.
    numbered_files: bool = false,
    /// `core.quotePath`; `null` reads it.
    quote_path: ?bool = null,
    /// The committer and the time: what a sign-off, a cover letter's
    /// sender, the message ids and `format.from=true` name, and the time
    /// the message ids carry. One of them wanted with none given is
    /// `error.NoIdentity`, where git asks for the committer's.
    who: ?object.Signature = null,
    /// What git writes as its own version: a `format.attach` with no
    /// value is that boundary. A program gives its own.
    version: []const u8 = "relic",
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
    /// Where the mails' files go: `Options.output_directory` or
    /// `format.outputDirectory`; empty for the current directory. A mail's
    /// `name` is under it.
    directory: []const u8 = "",

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
    options: Plan,
    /// The notes trees shown under each message.
    display_notes: ?*notes_mod.DisplayNotes = null,
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

    /// The drivers the files take, which say which are binary.
    fn drivers(ctx: *const Ctx) driver.Drivers {
        return .{ .attrs = ctx.attrs, .work_dir = if (ctx.repo.workDirectory()) |work| work.get() else null, .config = ctx.repo.configuration() };
    }
};

/// `Options` with the settings read: what formatting goes by.
const Plan = struct {
    order: ?diff.Order,
    directory: []const u8,
    relative: ?bool,
    numbered: ?bool,
    start_number: usize,
    subject_prefix: []const u8,
    rfc: ?[]const u8,
    reroll_count: ?[]const u8,
    keep_subject: bool,
    signoff: ?Ident,
    cover_letter: ?CoverPlan,
    base: BasePlan,
    signature: ?[]const u8,
    stat: bool,
    binary: bool,
    zero_commit: bool,
    from: ?Ident,
    force_in_body_from: bool,
    to: []const []const u8,
    cc: []const []const u8,
    headers: []const []const u8,
    in_reply_to: ?[]const u8,
    thread: ?MessageIds,
    attach: ?Attach,
    encode_email_headers: bool,
    mboxrd: bool,
    /// `format.noPrefix`: the patches with no `a/` and `b/`.
    no_prefix: bool,
    /// The notes shown under each message, or `null` for none.
    notes: ?notes_mod.Display,
    ignore_if_in_upstream: bool,
    renames: Renames,
    diff: ?diff.Options,
    topo_order: bool,
    suffix: []const u8,
    filename_max_length: usize,
    output_directory: []const u8,
    numbered_files: bool,
    quote_path: ?bool,
};

/// A cover letter as it is written.
const CoverPlan = struct {
    sender: object.Signature,
    format: []const u8,
    description: ?[]const u8,
    from_description: Cover.FromDescription,
    /// Only when there is more than one patch.
    auto: bool,
};

/// Message ids: their threading, time and address.
const MessageIds = struct {
    style: enum { shallow, deep },
    now: std.Io.Timestamp,
    email: []const u8,
};

const BasePlan = union(enum) {
    none,
    /// `strict` dies where no base is found; otherwise there is none.
    auto: struct { strict: bool },
    commit: Oid,
};

/// What git's `git_format_config` reads, the last value of each deciding.
const Settings = struct {
    numbered: ?bool = null,
    subject_prefix: ?[]const u8 = null,
    signoff: bool = false,
    cover_letter: CoverLetter = .off,
    commit_list_format: ?[]const u8 = null,
    from_description: Cover.FromDescription = .message,
    auto_base: ?bool = null,
    signature: ?[]const u8 = null,
    signature_file: ?[]const u8 = null,
    from: ?FromSetting = null,
    force_in_body_from: bool = false,
    to: std.ArrayList([]const u8) = .empty,
    cc: std.ArrayList([]const u8) = .empty,
    headers: std.ArrayList([]const u8) = .empty,
    thread: ?@FieldType(MessageIds, "style") = null,
    attach: ?[]const u8 = null,
    encode_email_headers: bool = true,
    mboxrd: bool = false,
    no_prefix: bool = false,
    notes: std.ArrayList(NotesArg) = .empty,
    suffix: []const u8 = ".patch",
    filename_max_length: usize = 64,
    output_directory: []const u8 = "",

    const FromSetting = union(enum) { committer, ident: []const u8 };

    fn read(a: Allocator, config: *const config_mod.Config, version: []const u8) Error!Settings {
        var st: Settings = .{};
        var it = config.iterate(&.{
            "format.headers",              "format.suffix",        "format.to",            "format.cc",
            "format.numbered",             "format.attach",        "format.thread",        "format.signoff",
            "format.signature",            "format.signaturefile", "format.coverletter",   "format.commitlistformat",
            "format.outputdirectory",      "format.useautobase",   "format.from",          "format.forceinbodyfrom",
            "format.coverfromdescription", "format.mboxrd",        "format.subjectprefix", "format.filenamemaxlength",
            "format.encodeemailheaders",   "format.noprefix",      "format.notes",
        });
        while (it.next()) |e| {
            const v = e.value;
            const name = e.name;
            if (std.mem.eql(u8, name, "headers")) {
                try addHeader(a, &st.headers, &st.to, &st.cc, v orelse return error.InvalidFormatSetting);
            } else if (std.mem.eql(u8, name, "to")) {
                try st.to.append(a, v orelse return error.InvalidFormatSetting);
            } else if (std.mem.eql(u8, name, "cc")) {
                try st.cc.append(a, v orelse return error.InvalidFormatSetting);
            } else if (std.mem.eql(u8, name, "suffix")) {
                st.suffix = v orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "numbered")) {
                st.numbered = if (v != null and std.ascii.eqlIgnoreCase(v.?, "auto")) null else try boolSetting(v);
            } else if (std.mem.eql(u8, name, "attach")) {
                st.attach = if (v) |text| (if (text.len == 0) null else text) else version;
            } else if (std.mem.eql(u8, name, "thread")) {
                st.thread = if (v != null and std.ascii.eqlIgnoreCase(v.?, "deep")) .deep else if (v != null and std.ascii.eqlIgnoreCase(v.?, "shallow")) .shallow else if (try boolSetting(v)) .shallow else null;
            } else if (std.mem.eql(u8, name, "signoff")) {
                st.signoff = try boolSetting(v);
            } else if (std.mem.eql(u8, name, "signature")) {
                st.signature = v orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "signaturefile")) {
                st.signature_file = v orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "coverletter")) {
                st.cover_letter = if (v != null and std.ascii.eqlIgnoreCase(v.?, "auto")) .auto else if (try boolSetting(v)) .on else .off;
            } else if (std.mem.eql(u8, name, "commitlistformat")) {
                st.commit_list_format = v orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "outputdirectory")) {
                st.output_directory = v orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "useautobase")) {
                st.auto_base = if (v != null and std.ascii.eqlIgnoreCase(v.?, "whenable")) false else if (try boolSetting(v)) true else null;
            } else if (std.mem.eql(u8, name, "from")) {
                st.from = if (maybeBool(v)) |b| (if (b) .committer else null) else .{ .ident = v.? };
            } else if (std.mem.eql(u8, name, "forceinbodyfrom")) {
                st.force_in_body_from = try boolSetting(v);
            } else if (std.mem.eql(u8, name, "coverfromdescription")) {
                st.from_description = Cover.FromDescription.parse(v) orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "mboxrd")) {
                st.mboxrd = try boolSetting(v);
            } else if (std.mem.eql(u8, name, "notes")) {
                // git's `enable_default_display_notes`, `disable_display_notes`
                // and `enable_ref_display_notes`, as each value comes
                try st.notes.append(a, if (maybeBool(v)) |on| (if (on) .standard else .off) else .{ .ref = v.? });
            } else if (std.mem.eql(u8, name, "noprefix")) {
                // git dies on a value that is no boolean, which it once
                // took as true
                st.no_prefix = maybeBool(v) orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "subjectprefix")) {
                st.subject_prefix = v orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "filenamemaxlength")) {
                const n = config_mod.parseInteger(c_int, v orelse return error.InvalidFormatSetting) catch return error.InvalidFormatSetting;
                st.filename_max_length = std.math.cast(@TypeOf(st.filename_max_length), @max(n, 0)) orelse return error.InvalidFormatSetting;
            } else if (std.mem.eql(u8, name, "encodeemailheaders")) {
                st.encode_email_headers = try boolSetting(v);
            }
        }
        return st;
    }
};

/// git's `git_config_bool`: a bare name is true; no boolean dies.
fn boolSetting(value: ?[]const u8) Error!bool {
    return config_mod.parseBool(value orelse return true) catch error.InvalidFormatSetting;
}

/// git's `git_parse_maybe_bool`: a boolean, or null for anything else.
fn maybeBool(value: ?[]const u8) ?bool {
    const v = value orelse return true;
    if (v.len == 0) return false;
    return config_mod.parseBool(v) catch null;
}

/// git's `add_header`: trailing newlines dropped, and a `To: ` or `Cc: `
/// header, in any case, an address.
fn addHeader(a: Allocator, headers: *std.ArrayList([]const u8), to: *std.ArrayList([]const u8), cc: *std.ArrayList([]const u8), value: []const u8) Allocator.Error!void {
    const text = std.mem.trimEnd(u8, value, "\n");
    if (text.len >= 4 and std.ascii.eqlIgnoreCase(text[0..4], "to: ")) return to.append(a, text[4..]);
    if (text.len >= 4 and std.ascii.eqlIgnoreCase(text[0..4], "cc: ")) return cc.append(a, text[4..]);
    try headers.append(a, text);
}

/// `split_ident_line`'s name and address, or null where it fails.
fn parseIdent(text: []const u8) ?Ident {
    const lt = std.mem.findScalar(u8, text, '<') orelse return null;
    const gt = std.mem.findScalarPos(u8, text, lt, '>') orelse return null;
    return .{ .name = std.mem.trim(u8, text[0..lt], " \t"), .email = text[lt + 1 .. gt] };
}

fn needWho(options: Options) Error!object.Signature {
    return options.who orelse error.NoIdentity;
}

/// `options` with what the repository's settings say where it leaves them.
fn resolve(a: Allocator, io: Io, repo: *Repository, options: Options) Error!Plan {
    const config = repo.configuration();
    const st = try Settings.read(a, config, options.version);

    var to: std.ArrayList([]const u8) = .empty;
    var cc: std.ArrayList([]const u8) = .empty;
    var headers: std.ArrayList([]const u8) = .empty;
    if (options.headers.settings) try headers.appendSlice(a, st.headers.items);
    if (options.to.settings and options.headers.settings) try to.appendSlice(a, st.to.items);
    if (options.cc.settings and options.headers.settings) try cc.appendSlice(a, st.cc.items);
    for (options.to.given) |x| try to.append(a, x);
    for (options.cc.given) |x| try cc.append(a, x);
    for (options.headers.given) |h| try addHeader(a, &headers, &to, &cc, h);

    const thread: ?@FieldType(MessageIds, "style") = switch (options.thread) {
        .configured => st.thread,
        .off => null,
        .shallow => .shallow,
        .deep => .deep,
    };
    const want_cover: CoverLetter = switch (options.cover_letter) {
        .configured => st.cover_letter,
        else => |c| c,
    };
    const signature: ?[]const u8 = switch (options.signature) {
        .off => null,
        .on => |text| text,
        .configured => if (st.signature) |text| text else if (st.signature_file) |path| sig: {
            const full = config_mod.interpolatePath(a, path, config.context.home) catch return error.InvalidFormatSetting;
            break :sig try aegis.own.readFile(io, Io.Dir.cwd(), full, a, aegis.units.Bytes(u64).fromRaw(std.math.maxInt(u64)));
        } else null,
    };
    const from: ?Ident = switch (options.from) {
        .off => null,
        .on => |ident| ident,
        .configured => if (st.from) |f| switch (f) {
            .committer => w: {
                const who = try needWho(options);
                break :w Ident{ .name = who.name, .email = who.email };
            },
            .ident => |text| parseIdent(text) orelse return error.InvalidFormatSetting,
        } else null,
    };
    const signoff: ?Ident = if (options.signoff orelse st.signoff) s: {
        const who = try needWho(options);
        break :s Ident{ .name = who.name, .email = who.email };
    } else null;
    const message_ids: ?MessageIds = if (thread) |style| m: {
        const who = try needWho(options);
        break :m .{ .style = style, .now = gitdate.timestamp(who.when_secs), .email = who.email };
    } else null;
    const cover: ?CoverPlan = if (want_cover == .on or want_cover == .auto) .{
        .sender = options.cover.sender orelse try needWho(options),
        .format = if (options.cover.format) |f| switch (f) {
            .shortlog => "shortlog",
            .modern => "modern",
            .log => |text| try a.print("log:{s}", .{text}),
        } else st.commit_list_format orelse "shortlog",
        .description = options.cover.description,
        .from_description = options.cover.from_description orelse st.from_description,
        .auto = want_cover == .auto,
    } else null;
    const base: BasePlan = switch (options.base) {
        .off => .none,
        .auto => .{ .auto = .{ .strict = true } },
        .commit => |oid| .{ .commit = oid },
        .configured => if (st.auto_base) |strict| .{ .auto = .{ .strict = strict } } else .none,
    };
    const attach: ?Attach = switch (options.attach) {
        .off => null,
        .on => |att| att,
        .configured => if (st.attach) |boundary| .{ .boundary = boundary } else null,
    };
    return .{
        .order = options.order,
        .directory = options.directory,
        .relative = options.relative,
        .numbered = options.numbered orelse (if (options.keep_subject) null else st.numbered),
        .start_number = options.start_number,
        .subject_prefix = options.subject_prefix orelse st.subject_prefix orelse "PATCH",
        .rfc = options.rfc,
        .reroll_count = options.reroll_count,
        .keep_subject = options.keep_subject,
        .signoff = signoff,
        .cover_letter = cover,
        .base = base,
        .signature = signature,
        .stat = options.stat,
        .binary = options.binary,
        .zero_commit = options.zero_commit,
        .from = from,
        .force_in_body_from = options.force_in_body_from orelse st.force_in_body_from,
        .to = to.items,
        .cc = cc.items,
        .headers = headers.items,
        .in_reply_to = options.in_reply_to,
        .thread = message_ids,
        .attach = attach,
        .encode_email_headers = options.encode_email_headers orelse st.encode_email_headers,
        .mboxrd = options.mboxrd orelse st.mboxrd,
        .no_prefix = st.no_prefix,
        .notes = try notesShown(a, st.notes.items, options.notes),
        .ignore_if_in_upstream = options.ignore_if_in_upstream,
        .renames = options.renames,
        .diff = options.diff,
        .topo_order = options.topo_order,
        .suffix = options.suffix orelse st.suffix,
        .filename_max_length = options.filename_max_length orelse st.filename_max_length,
        .output_directory = options.output_directory orelse st.output_directory,
        .numbered_files = options.numbered_files,
        .quote_path = options.quote_path,
    };
}

/// Format `range` as `git format-patch` would.
pub fn format(gpa: Allocator, io: Io, repo: *Repository, range: Range, given: Options) Self.Error!Series {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const a = arena_instance.allocator();
    const config = repo.configuration();
    const db = repo.objectDatabase();

    if (given.keep_subject and given.numbered == true) return error.KeepSubjectWithNumbered;
    if (given.keep_subject and (given.rfc != null or given.subject_prefix != null)) return error.KeepSubjectWithPrefix;
    var options = try resolve(a, io, repo, given);
    options.output_directory = try a.dupe(u8, options.output_directory);

    var diff_options = try patchDiffOptions(config, options);
    const renames = try renameOptions(config, options.renames);

    const prefix = try subjectPrefix(a, options);

    var own_attrs: ?attributes.Attrs = null;
    defer if (own_attrs) |*x| x.deinit();
    if (repo.workDirectory() != null) own_attrs = try repo.loadAttrs(io);
    defer if (own_attrs) |*x| x.leave();
    const drivers: driver.Drivers = .{ .attrs = if (own_attrs) |*x| x else null, .work_dir = if (repo.workDirectory()) |work| work.get() else null, .config = config };

    const selected = try selectCommits(gpa, a, io, db, range, options, drivers) orelse return emptySeries(gpa, &arena_instance, options.output_directory);
    const list = selected.list;
    if (options.cover_letter) |c| if (c.auto and list.len <= 1) {
        options.cover_letter = null;
    };

    // the boundary: the one commit outside the range the range grew from
    const origin = try findOrigin(gpa, io, db, selected.in_list, selected.walked);

    var total = list.len;
    var start_number = options.start_number;
    const numbered = if (options.keep_subject) false else options.numbered orelse (total > 1 or options.cover_letter != null);

    const quote_path = options.quote_path orelse configuredQuotePath(config);

    const relative_to = if (options.relative orelse try diff.configuredRelative(config)) options.directory else "";
    diff_options.quote_path = quote_path;
    diff_options.abbrev = abbrev.defaultLength(config, db);
    diff_options.relative_to = relative_to;
    diff_options.binary_patches = options.binary;
    diff_options.after_stat = options.stat;

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
        .order = options.order orelse try diff.Order.configured(a, io, repo.topDirectory().get(), config),
        .relative_to = relative_to,
        .quote_path = quote_path,
        .attrs = if (own_attrs) |*x| x else null,
        .prefix = prefix,
        .total = if (options.keep_subject) -1 else if (numbered) @intCast(total + start_number - 1) else 0,
    };

    var display: ?notes_mod.DisplayNotes = if (options.notes) |which| try .load(gpa, io, repo, which) else null;
    defer if (display) |*d| d.deinit();
    if (display) |*d| ctx.display_notes = d;
    if (options.in_reply_to) |r| try ctx.ref_ids.append(a, try cleanMessageId(a, r));

    // base tree information
    var bases: ?Bases = null;
    switch (options.base) {
        .none => {},
        .commit => |base| bases = try prepareBases(&ctx, base, list),
        .auto => |auto| if (try autoBase(&ctx, list, auto.strict)) |base| {
            bases = prepareBases(&ctx, base, list) catch |err| switch (err) {
                error.BaseInRange, error.BaseNotAncestor => if (auto.strict) return err else null,
                else => |e| return e,
            };
        },
    }

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
    return .{ .gpa = gpa, .arena = arena_instance.state, .mails = mails.items, .directory = options.output_directory };
}

/// What a series formats: its commits, newest first, those of them a
/// merge does not leave out, and every commit the walk met, for finding
/// where the range grew from.
const Selected = struct { list: []const Oid, in_list: []const Oid, walked: []const Oid };

/// The commits of `range`, newest first, as `git format-patch` takes them:
/// merges left out, at most `max_count`, and under `ignore_if_in_upstream`
/// those whose patch id upstream has. `null` when there are none.
/// How renames are found: as asked, or as `diff.renames` says.
fn renameOptions(config: *const config_mod.Config, renames: Renames) Error!?diff.RenameOptions {
    return switch (renames) {
        .off => null,
        .on => |r| r,
        .configured => (try diff.RenameSettings.read(config)).options(),
    };
}

/// `core.quotePath`, on when it says nothing or nothing git reads.
fn configuredQuotePath(config: *const config_mod.Config) bool {
    const value = config.get("core.quotepath") orelse return true;
    return config_mod.parseBool(value) catch true;
}

/// git's `display_notes_opt` after `format.notes` and the command line,
/// one argument after another: what shows, or `null` for nothing.
fn notesShown(a: Allocator, settings: []const NotesArg, given: []const NotesArg) Allocator.Error!?notes_mod.Display {
    var show = false;
    var standard: ?bool = null;
    var refs: std.ArrayList([]const u8) = .empty;
    for ([_][]const NotesArg{ settings, given }) |args| for (args) |arg| switch (arg) {
        .standard => {
            standard = true;
            show = true;
        },
        .ref => |ref| {
            try refs.append(a, ref);
            show = true;
        },
        .off => {
            standard = null;
            refs.clearRetainingCapacity();
            show = false;
        },
    };
    if (!show) return null;
    return .{ .standard = standard, .refs = refs.items };
}

/// What the patches are diffed with: the caller's own options, which are
/// its command line and have the last word over `format.noPrefix` as
/// `--default-prefix` has, or the configuration's.
fn patchDiffOptions(config: *const config_mod.Config, options: Plan) Error!diff.Options {
    if (options.diff) |given| return given;
    return diff.configured(config, .{
        .prefixes = if (options.no_prefix) .{ .src = "", .dst = "" } else try diff.Prefixes.configured(config, .patches),
    });
}

fn selectCommits(gpa: Allocator, a: Allocator, io: Io, db: *odb_mod.Odb, range: Range, options: Plan, drivers: driver.Drivers) Error!?Selected {
    var list: std.ArrayList(Oid) = .empty;
    var walk = rev_walk.Walk.init(gpa, db);
    defer walk.deinit();
    try walk.push(range.tip);
    if (range.upstream) |u| try walk.hide(u);
    for (range.exclude) |x| try walk.hide(x);
    if (options.topo_order) walk.sort = .topological;
    var upstream_ids: std.ArrayList(Oid) = .empty;
    if (options.ignore_if_in_upstream and range.upstream != null) {
        if (range.upstream.?.eql(range.tip)) return null;
        try upstreamPatchIds(gpa, a, io, db, range, drivers, &upstream_ids);
    }
    var in_list: std.ArrayList(Oid) = .empty;
    var walked: std.ArrayList(Oid) = .empty;
    while (try walk.next(io)) |c| {
        if (range.max_count) |n| if (in_list.items.len >= n) break;
        try walked.append(a, c.oid);
        if (c.parents.len > 1) continue;
        try in_list.append(a, c.oid);
        if (upstream_ids.items.len != 0) {
            if (try patch_id.ofCommit(gpa, io, db, c.oid, drivers)) |id| {
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
fn subjectPrefix(a: Allocator, options: Plan) Allocator.Error![]const u8 {
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
fn upstreamPatchIds(gpa: Allocator, a: Allocator, io: Io, db: *odb_mod.Odb, range: Range, drivers: driver.Drivers, out: *std.ArrayList(Oid)) Error!void {
    var back = rev_walk.Walk.init(gpa, db);
    defer back.deinit();
    // Asked only of a range with an upstream.
    try back.push(range.upstream.?);
    try back.hide(range.tip);
    while (try back.next(io)) |c| {
        if (c.parents.len > 1) continue;
        if (try patch_id.ofCommit(gpa, io, db, c.oid, drivers)) |id| try out.append(a, id);
    }
}

fn containsOid(oids: []const Oid, oid: Oid) bool {
    for (oids) |o| if (o.eql(oid)) return true;
    return false;
}

fn emptySeries(gpa: Allocator, arena: *std.heap.ArenaAllocator, directory: []const u8) Series {
    return .{ .gpa = gpa, .arena = arena.state, .mails = &.{}, .directory = directory };
}

/// git's `get_base_commit` for `--base=auto`: the merge base of the
/// current branch's upstream and the series, which must reach the series'
/// own merge base and not be in it. Where it is not found, `strict` is
/// `error.NoAutoBase` (or the base's own errors) and otherwise none.
fn autoBase(ctx: *Ctx, list: []const Oid, strict: bool) Error!?Oid {
    const upstream = rev_parse.resolve(ctx.gpa, ctx.io, ctx.repo.revisionSource(), "@{upstream}") catch |err| switch (err) {
        error.BadRevision, error.AmbiguousRevision => return if (strict) error.NoAutoBase else null,
        else => |e| return e,
    };
    const bases = try rev_walk.mergeBasesMany(ctx.gpa, ctx.io, ctx.db, .{ .one = upstream, .others = list }, .{});
    defer ctx.gpa.free(bases);
    if (bases.len != 1) return if (strict) error.NoAutoBase else null;
    return bases[0];
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

fn genMessageId(a: Allocator, base: []const u8, t: MessageIds) Allocator.Error![]const u8 {
    return a.print("{s}.{d}.git.{s}", .{ base, gitdate.seconds(t.now), t.email });
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
        const id = (try patch_id.ofCommit(gpa, ctx.io, ctx.db, c.oid, ctx.drivers())) orelse continue;
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
    {
        var w: Io.Writer.Allocating = .fromArrayList(a, out);
        defer out.* = w.toArrayList();
        if (ctx.options.encode_email_headers and mailfmt.needsRfc2047(name)) {
            mailfmt.writeRfc2047(&w.writer, name, encoding, .address, "From: ".len) catch return error.OutOfMemory;
            max_length = 76;
        } else if (mailfmt.needsRfc822Quoting(name)) {
            var q: Io.Writer.Allocating = .init(a);
            mailfmt.writeRfc822Quoted(&q.writer, name) catch return error.OutOfMemory;
            mailfmt.writeWrapped(&w.writer, q.written(), -6, 1, @intCast(max_length)) catch return error.OutOfMemory;
        } else {
            mailfmt.writeWrapped(&w.writer, name, -6, 1, @intCast(max_length)) catch return error.OutOfMemory;
        }
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
    {
        const column = lastLineLength(out.items);
        var w: Io.Writer.Allocating = .fromArrayList(a, out);
        defer out.* = w.toArrayList();
        if (ctx.options.encode_email_headers and mailfmt.needsRfc2047(title.items)) {
            mailfmt.writeRfc2047(&w.writer, title.items, encoding, .subject, column) catch return error.OutOfMemory;
        } else {
            mailfmt.writeWrapped(&w.writer, title.items, -@as(i32, @intCast(column)), 1, 78) catch return error.OutOfMemory;
        }
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

    // the notes, below a `---` the diffstat then goes without, as git's
    // `next_commentary_block` writes it
    var shown_dashes = false;
    if (ctx.display_notes) |d| {
        var note_text: Io.Writer.Allocating = .init(a);
        try d.format(ctx.io, oid, &note_text.writer, .{});
        if (note_text.written().len != 0) {
            try out.appendSlice(a, "---\n");
            try out.appendSlice(a, note_text.written());
            shown_dashes = true;
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
    if (ctx.options.stat and !shown_dashes) try out.appendSlice(a, "---");
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

fn writeDiff(ctx: *Ctx, out: *std.ArrayList(u8), changes: []const diff.Change, stat_sep: ?[]const u8) Error!void {
    const a = ctx.a;
    if (ctx.options.stat) {
        try writeStat(ctx, out, changes);
        try out.append(a, '\n');
        if (stat_sep) |s| try out.appendSlice(a, s);
    }
    var w: Io.Writer.Allocating = .fromArrayList(a, out);
    defer out.* = w.toArrayList();
    diff.unified(ctx.gpa, ctx.io, &w.writer, .{ .db = ctx.db, .changes = changes, .drivers = ctx.drivers() }, ctx.diff_options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
}

/// The diffstat and summary at `format-patch`'s 72 columns: its widths
/// are its own, git's never reading `diff.statNameWidth` or
/// `diff.statGraphWidth` for it. The names are as `shown` gives them.
fn writeStat(ctx: *Ctx, out: *std.ArrayList(u8), changes: []const diff.Change) Error!void {
    const files = try diff_stat.files(ctx.a, ctx.io, .{ .db = ctx.db, .changes = changes, .drivers = ctx.drivers() }, ctx.diff_options);
    for (files) |*f| {
        f.name = shown(ctx, f.name);
        if (f.from) |from| f.from = shown(ctx, from);
    }
    var w: Io.Writer.Allocating = .fromArrayList(ctx.a, out);
    defer out.* = w.toArrayList();
    diff_stat.write(ctx.a, &w.writer, files, .{ .widths = .{ .width = 72 }, .quote_path = ctx.quote_path }) catch return error.OutOfMemory;
    diff_stat.writeSummary(ctx.a, &w.writer, changes, ctx.quote_path) catch return error.OutOfMemory;
}

/// A path as a patch's headers and diffstat name it: under `--relative`,
/// from the directory, as git's `strip_prefix` names it. The summary lines
/// keep the whole path, as git's do.
fn shown(ctx: *const Ctx, path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, ctx.relative_to)) path[ctx.relative_to.len..] else path;
}

//=========================================================================
// The cover letter
//=========================================================================

fn coverLetter(ctx: *Ctx, out_list: *std.ArrayList(u8), cover: CoverPlan, origin: ?Oid, list: []const Oid) Error!void {
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

    switch (CoverFormat.parse(cover.format) orelse return error.InvalidFormatSetting) {
        .shortlog => try coverShortlog(ctx, out, list),
        .log => |fmt| try coverList(ctx, out, list, fmt),
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
                var wrapped: Io.Writer.Allocating = .init(a);
                mailfmt.writeWrapped(&wrapped.writer, line.items, 0, 0, 72) catch return error.OutOfMemory;
                try out.appendSlice(a, try pretty.toOutput(a, wrapped.written(), pretty.outputEncoding(null, utf8.encoding)));
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
        try writeStat(ctx, out, changes.items);
        ctx.options.stat = saved;
        try out.append(a, '\n');
    }
}

/// git's `generate_commit_list_cover`: a line per commit in `fmt`,
/// oldest first, `%(count)` and `%(total)` numbering them, then a blank
/// line. As git's, the format has no output encoding: each line is written
/// in its commit's own.
fn coverList(ctx: *Ctx, out: *std.ArrayList(u8), list: []const Oid, fmt: []const u8) Error!void {
    const a = ctx.a;
    var map = try mailmap_mod.Mailmap.load(ctx.gpa, ctx.io, ctx.repo);
    defer map.deinit();
    const n = list.len;
    for (1..n + 1) |i| {
        var line: std.ArrayList(u8) = .empty;
        try pretty.formatCommit(a, ctx.io, .{ .db = ctx.db, .oid = list[n - i], .format = fmt }, &line, .{
            // git's `generate_commit_list_cover` formats with a zeroed
            // context, whose abbreviation of 0 is the whole name.
            .abbrev_len = ctx.db.objectFormat().hexLen(),
            .mailmap = &map,
            .numbered = .{ .nr = i, .total = n },
        });
        try out.appendSlice(a, line.items);
        try out.append(a, '\n');
    }
    try out.append(a, '\n');
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
